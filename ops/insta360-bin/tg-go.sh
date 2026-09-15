#!/usr/bin/env bash
#
# tg-go - archive a batch, start to finish, in one command.
#
# Replaces the eight-step sequence: wait for Syncthing, build the manifest,
# drain, push metrics. Each of those exists separately for when something needs
# inspecting; this is the one to run when nothing does.
#
#   tg-go            wait for the sync, archive everything, report
#   tg-go --now      skip the wait (staging is already full)
#   tg-go --status   what is the state right now, change nothing
#
# From the phone this is a single line, no interactive session:
#   ssh immich tg-go
#
# WHY THE MANIFEST IS APPENDED, NEVER OVERWRITTEN.
# The manifest is the record of everything that has ever been on the card, and
# `tg-archive status` counts against it. Overwriting it with just the current
# batch makes total collapse to the batch size, remaining go to zero, and the
# drain conclude there is nothing to do. That exact mistake cost a real session
# on 2026-09-15.

set -euo pipefail

ENV_FILE="${TG_ENV_FILE:-/etc/personal-vault/tg-archive.env}"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "FATAL: cannot read $ENV_FILE" >&2
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

STAGING_DIR="${STAGING_DIR:?STAGING_DIR not set}"
MANIFEST="${MANIFEST:?MANIFEST not set}"

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
COLLECTOR="${METRICS_COLLECTOR:-/opt/personal-vault/ops/metrics/collect-and-push.sh}"

SYNCTHING_CONFIG="${SYNCTHING_CONFIG:-/home/ubuntu/.local/state/syncthing/config.xml}"
SYNCTHING_URL="${SYNCTHING_URL:-http://127.0.0.1:8384}"
SYNC_FOLDER="${SYNC_FOLDER:-dub20-7j8sw}"
SYNC_TIMEOUT="${SYNC_TIMEOUT:-7200}"

WAIT=1
STATUS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --now)    WAIT=0 ;;
    --status) STATUS_ONLY=1 ;;
    -h|--help)
      echo "tg-go            wait for Syncthing, archive everything, report"
      echo "tg-go --now      skip the wait - staging is already full"
      echo "tg-go --status   show the current state, change nothing"
      exit 0
      ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

log()  { echo "[$(date +%H:%M:%S)] $*"; }
err()  { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }
step() { echo; echo "=== $* ==="; }

# --- Syncthing ------------------------------------------------------------

sync_key() {
  [[ -r "$SYNCTHING_CONFIG" ]] || return 0
  grep -o '<apikey>[^<]*</apikey>' "$SYNCTHING_CONFIG" 2>/dev/null |
    sed 's/<[^>]*>//g' | head -1
}

# Returns "needBytes state" or empty when Syncthing cannot be reached.
sync_status() {
  local k; k="$(sync_key)"
  [[ -n "$k" ]] || return 0
  curl -s -m 10 -H "X-API-Key: $k" \
    "$SYNCTHING_URL/rest/db/status?folder=$SYNC_FOLDER" 2>/dev/null |
    python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get("needBytes", 0), d.get("state", "unknown"))
' 2>/dev/null || true
}

# Integer arithmetic only. bc is not installed on this VM by default - it
# shipped without restic, rsync and nano too - and a size display is not worth
# a new dependency, still less one that would abort the run under `set -e`.
human() {
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || { printf '%s B' "0"; return; }
  if (( b >= 1073741824 )); then
    printf '%d.%d GB' $(( b / 1073741824 )) $(( (b % 1073741824) * 10 / 1073741824 ))
  elif (( b >= 1048576 )); then
    printf '%d MB' $(( b / 1048576 ))
  else
    printf '%d B' "$b"
  fi
}

wait_for_sync() {
  local waited=0 need state line

  line="$(sync_status)"
  if [[ -z "$line" ]]; then
    err "cannot reach Syncthing - continuing with whatever is in staging"
    err "  (check: systemctl status syncthing@ubuntu)"
    return 0
  fi

  read -r need state <<< "$line"

  if [[ "$need" == "0" && "$state" == "idle" ]]; then
    log "Syncthing is idle - nothing in flight"
    return 0
  fi

  log "waiting for Syncthing: $(human "$need") still to arrive"
  log "  (Ctrl+C is safe - nothing is uploaded until this finishes)"

  while (( waited < SYNC_TIMEOUT )); do
    sleep 20
    waited=$(( waited + 20 ))

    line="$(sync_status)"
    [[ -n "$line" ]] || continue
    read -r need state <<< "$line"

    if [[ "$need" == "0" && "$state" == "idle" ]]; then
      log "sync complete"
      return 0
    fi

    # Only report every couple of minutes; this runs for hours.
    if (( waited % 120 == 0 )); then
      log "  $(human "$need") remaining, state=$state"
    fi
  done

  err "Syncthing still busy after ${SYNC_TIMEOUT}s - archiving what arrived"
  err "  the rest stays on the card and syncs next time"
}

# --- manifest -------------------------------------------------------------

update_manifest() {
  shopt -s nullglob
  local staged=("$STAGING_DIR"/*.insv)
  shopt -u nullglob

  if (( ${#staged[@]} == 0 )); then
    log "staging is empty - manifest unchanged"
    return 0
  fi

  touch "$MANIFEST"

  local added=0 f base
  for f in "${staged[@]}"; do
    base="$(basename "$f")"

    # Already fingerprinted? Leave it. Re-hashing a 700 MB file to write a line
    # that already exists is minutes of disk for nothing.
    #
    # Match on the last field, the way verify-batch.sh reads the manifest, so
    # the two can never disagree about whether a file is listed.
    if awk -v want="$base" '
         { n = $NF; sub(/^\*/, "", n); sub(/.*\//, "", n)
           if (n == want) { found = 1; exit } }
         END { exit !found }' "$MANIFEST" 2>/dev/null; then
      continue
    fi

    # Hash from inside the directory so the manifest records a BARE FILENAME.
    # `sha256sum /full/path/x.insv` writes the full path, which made the dedupe
    # above never match and left every line carrying staging-directory noise
    # that verify-batch.sh then has to strip.
    ( cd "$STAGING_DIR" && sha256sum "$base" ) >> "$MANIFEST"
    added=$(( added + 1 ))
  done

  if (( added )); then
    log "fingerprinted $added new file(s) into $(basename "$MANIFEST")"
  else
    log "all staged files were already in the manifest"
  fi
}

# --- state ----------------------------------------------------------------

show_state() {
  local staged
  shopt -s nullglob
  local f=("$STAGING_DIR"/*.insv)
  shopt -u nullglob
  staged=${#f[@]}

  local line need state
  line="$(sync_status)"
  if [[ -n "$line" ]]; then
    read -r need state <<< "$line"
    echo "  Syncthing     : $state, $(human "$need") to arrive"
  else
    echo "  Syncthing     : unreachable"
  fi
  echo "  In staging    : $staged file(s)"

  if [[ -x "$HERE/tg-archive.sh" ]]; then
    "$HERE/tg-archive.sh" status 2>/dev/null | sed 's/^/  /'
  fi
}

if (( STATUS_ONLY )); then
  step "current state"
  show_state
  exit 0
fi

# --- run ------------------------------------------------------------------

step "1/4  waiting for the card to finish syncing"
if (( WAIT )); then
  wait_for_sync
else
  log "skipped (--now)"
fi

step "2/4  fingerprinting what arrived"
update_manifest

step "3/4  archiving to Telegram"
if [[ -x "$HERE/tg-archive.sh" ]]; then
  "$HERE/tg-archive.sh" start
else
  err "tg-archive.sh not found beside $HERE"
  exit 1
fi

step "4/4  updating the dashboard"
if [[ -x "$COLLECTOR" ]]; then
  # Capture the reason rather than discarding it. '>/dev/null 2>&1' here threw
  # away the one line that said WHY, leaving "metrics push failed" and nothing
  # to act on - the failure is not fatal, but it should never be mute.
  collector_out="$("$COLLECTOR" 2>&1)" && collector_rc=0 || collector_rc=$?

  if (( collector_rc == 0 )); then
    log "metrics pushed"
  else
    err "metrics push failed (not fatal - the 15-minute timer will retry)"
    printf '%s\n' "$collector_out" | tail -3 | sed 's/^/           /' >&2

    # The likeliest cause by far, and it has bitten this project before: the
    # collector reads /etc/personal-vault/ops.env, tg-go runs as the ubuntu
    # user, and that file is installed 0600 root:root. tg-archive.env needed
    # exactly this fix on the first real run.
    if [[ -e /etc/personal-vault/ops.env && ! -r /etc/personal-vault/ops.env ]]; then
      err "ops.env is not readable by $(id -un) - that is almost certainly why:"
      err "  sudo chown root:ubuntu /etc/personal-vault/ops.env"
      err "  sudo chmod 640 /etc/personal-vault/ops.env"
    fi
  fi
else
  err "collector not found at $COLLECTOR - dashboard will lag until its timer runs"
fi

step "done"
show_state
echo
log "if that reports 0 remaining, the batch is safe to clear from the card:"
log "  tg-prune --apply        (run this in Termux, on the phone)"
