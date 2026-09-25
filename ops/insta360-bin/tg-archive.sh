#!/usr/bin/env bash
#
# tg-archive - drain the camera card into Telegram, unattended.
#
# This is a WRAPPER. It does not upload anything itself: tg-upload.sh already
# does the hard part (disk guard, flood-wait backoff, Check #1 against the
# manifest, Check #2 round-trip, delete-only-after-verify). This adds the
# three things that were missing:
#
#   the outer loop   - keep draining until the card is done, not one batch
#   status           - how far through the card are we
#
#   tg-archive start    begin draining; runs until the card is empty
#   tg-archive status   done / remaining / staged / running
#
# Normally started by tg-archive.path when files land in staging, so neither
# command needs typing in the usual case.
#
# WHY ONE BATCH AT A TIME, NOT ONE FILE.
# tg-upload.sh already treats whatever is in staging as a batch and refuses to
# start one that would breach the disk margin. Re-implementing a per-file loop
# here would duplicate that guard and fight it. The loop simply calls it again
# whenever staging refills, so Syncthing's delivery rate sets the pace and
# staging never holds more than Syncthing has moved.
#
# WHY THERE IS NO PAUSE COMMAND.
# It was built for pulling the cable mid-drain, but that case never needed it:
# Syncthing writes partial transfers as `.syncthing.NAME.insv.tmp`, and
# tg-upload.sh globs `*.insv`, which does not match them. A half-synced file is
# invisible to the uploader, stays in staging, and Syncthing resumes it on
# reconnect. To stop a running drain, `systemctl stop tg-archive` or Ctrl+C -
# both safe, because tg-upload.sh never deletes what it has not verified, so
# the next run simply retries whatever was in flight.

set -euo pipefail

ENV_FILE="${TG_ENV_FILE:-/etc/personal-vault/tg-archive.env}"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "FATAL: cannot read $ENV_FILE" >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

STAGING_DIR="${STAGING_DIR:?STAGING_DIR not set}"
MANIFEST="${MANIFEST:?MANIFEST not set}"
WORK_DIR="${WORK_DIR:-/var/lib/insta360-archive/work}"

# readlink -f FIRST. Installed as /usr/local/bin/tg-archive -> the real script,
# dirname of BASH_SOURCE gives /usr/local/bin, and the sibling lookup below
# then hunts for /usr/local/bin/tg-upload.sh, which does not exist. Resolving
# the symlink puts HERE in the directory that actually holds the scripts.
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UPLOADER="$HERE/tg-upload.sh"

# State lives beside the work directory, not in /tmp: a reboot must not look
# like "nothing uploaded yet".
UPLOADED_LOG="$WORK_DIR/uploaded.sha256"
LOOP_LOCK="$WORK_DIR/.loop.lock"

# How long to wait for staging to refill before concluding the card is done.
# Syncthing moves ~10-16 MB/s on a direct link, so a large file still takes
# minutes to
# appear. Two consecutive empty passes this far apart means no more is coming.
IDLE_WAIT_SECONDS="${IDLE_WAIT_SECONDS:-300}"

# Parts fallback (added 2026-09-25). Some files can never pass Check #2 as one
# upload: Telegram stores a few 1 MiB blocks it then never serves, and an
# identical re-upload lands on the same blocks (docs/REVIEW-2026-09-24.md).
# tg-upload.sh records every Check #2 failure in CHECK2_FAILS; a staged file
# that has failed PARTS_AFTER times is archived by tg-upload-parts.sh instead,
# which reshapes the parts that fail. One that fails even that is moved to
# HOLD_DIR - inside staging, so the unit may write there, and dot-prefixed, so
# no *.insv glob sees it - and the drain carries on with everything else.
PARTS_UPLOADER="${TG_PARTS_UPLOADER:-$HERE/tg-upload-parts.sh}"
PARTS_AFTER="${PARTS_AFTER:-2}"
CHECK2_FAILS="$WORK_DIR/check2-failures"
HOLD_DIR="$STAGING_DIR/.hold"

log() { echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" >&2; }

# Syncthing must not scan the VM's own scratch inside the staging folder:
# Check #2 downloads, part scratch and held files are never sent to the phone
# (the folder is receive-only) but would still be hashed, on the drain's disk.
# Idempotent; appends only what is missing.
ensure_stignore() {
  local f="$STAGING_DIR/.stignore" p
  for p in '/.roundtrip' '/.parts.*' '/.hold'; do
    if ! grep -qxF -- "$p" "$f" 2>/dev/null; then
      printf '%s\n' "$p" >> "$f" 2>/dev/null || true
    fi
  done
}

# Hand each staged file that keeps failing Check #2 to the parts uploader.
# On success the file stays staged, and tg-upload.sh's next pass removes it as
# already archived - by hash against the ledger, the normal path. On failure it
# is held. Either way its failure count starts again.
parts_fallback() {
  local f name n
  [[ -r "$CHECK2_FAILS" ]] || return 0
  for f in "$@"; do
    name="$(basename "$f")"
    n="$(grep -cxF -- "$name" "$CHECK2_FAILS" 2>/dev/null || true)"
    if (( ${n:-0} < PARTS_AFTER )); then
      continue
    fi
    log "$name failed Check #2 $n time(s) - archiving it as verified parts"
    if "$PARTS_UPLOADER" "$f"; then
      log "$name archived as parts; the next pass clears it from staging"
    else
      err "$name failed as parts too - moving it to $HOLD_DIR so the drain continues"
      err "  it is NOT archived: keep it on the card (see docs/REVIEW-2026-09-24.md)"
      mkdir -p "$HOLD_DIR" && mv -- "$f" "$HOLD_DIR/"
    fi
    grep -vxF -- "$name" "$CHECK2_FAILS" > "$CHECK2_FAILS.tmp" 2>/dev/null || true
    mv -f "$CHECK2_FAILS.tmp" "$CHECK2_FAILS"
  done
}

# --- Syncthing-aware idle wait --------------------------------------------
#
# The loop below ends a drain after two consecutive empty passes, and each pass
# slept IDLE_WAIT_SECONDS (300) unconditionally. So every drain finished with up
# to 10 minutes of pure waiting, whether or not anything was still coming.
#
# Syncthing already knows the answer. tg-go.sh reads it before starting a drain;
# this reads the same endpoint at the same two decision points, so the loop can
# stop as soon as the phone has nothing left to send.
#
# Kept deliberately conservative: this only ever SHORTENS the wait when
# Syncthing positively reports idle with nothing pending. Unreachable, unparsable
# or still-transferring all fall through to the full sleep, because a drain that
# ends early leaves files unarchived, while one that waits too long only costs
# minutes. The manifest check after the loop is what actually decides whether
# the drain was complete, and it is unchanged.
SYNCTHING_CONFIG="${SYNCTHING_CONFIG:-/home/ubuntu/.local/state/syncthing/config.xml}"
SYNCTHING_URL="${SYNCTHING_URL:-http://127.0.0.1:8384}"
SYNC_FOLDER="${SYNC_FOLDER:-dub20-7j8sw}"

sync_key() {
  [[ -r "$SYNCTHING_CONFIG" ]] || return 0
  grep -o '<apikey>[^<]*</apikey>' "$SYNCTHING_CONFIG" 2>/dev/null |
    sed 's/<[^>]*>//g' | head -1
}

# "needBytes state", or empty when Syncthing cannot be reached. Same shape as
# tg-go.sh's sync_status(), deliberately - two readers of one endpoint that must
# not disagree about what "idle" means.
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

# 0 = Syncthing says there is nothing left to deliver.
# Anything else - unreachable, mid-transfer, unexpected output - is "not sure",
# and the caller waits out the full sleep.
sync_is_done() {
  local line need state
  line="$(sync_status)"
  [[ -n "$line" ]] || return 1
  read -r need state <<< "$line"
  [[ "$need" =~ ^[0-9]+$ ]] || return 1
  [[ "$need" == "0" && "$state" == "idle" ]]
}

# Sleep, but wake early once Syncthing reports it has nothing in flight.
#
# Polls rather than sleeping blind, so a drain ends promptly after the last
# file lands instead of up to five minutes later. The poll is a single local
# HTTP call against 127.0.0.1.
idle_wait() {
  local waited=0 step="${IDLE_POLL_SECONDS:-15}"
  while (( waited < IDLE_WAIT_SECONDS )); do
    if sync_is_done; then
      log "Syncthing idle with nothing pending - not waiting out the remaining $(( IDLE_WAIT_SECONDS - waited ))s"
      return 0
    fi
    sleep "$step"
    waited=$(( waited + step ))
  done
}

# Drain progress is written to a state file rather than pushed anywhere.
#
# The metrics collector reads it every 15 minutes and the /status dashboard
# renders it, so progress is visible on a phone without SSH and without a
# notification service. A file is the right interface here: this loop runs for
# days, the collector is a separate process on its own timer, and neither
# should have to know the other exists.
STATE_FILE="$WORK_DIR/drain-state"

# tg-upload.sh writes the step it is on here; this loop folds it into
# drain-state so the collector has one file to read rather than two.
PHASE_FILE="$WORK_DIR/phase"

# Read as key=value, never sourced - another process writes this file, and
# sourcing it would execute whatever it contained. Same rule the collector
# follows for drain-state.
read_phase() {
  PHASE=""
  PHASE_NAME_FILE=""
  PHASE_INDEX=0
  PHASE_TOTAL=0
  [[ -r "$PHASE_FILE" ]] || return 0
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      phase)       PHASE="$v" ;;
      phase_file)  PHASE_NAME_FILE="$v" ;;
      phase_index) PHASE_INDEX="$v" ;;
      phase_total) PHASE_TOTAL="$v" ;;
    esac
  done < "$PHASE_FILE"
}

write_state() {
  local status="$1" total_n done_n remaining_n
  total_n=$(manifest_names | sort -u | wc -l)
  done_n=$(uploaded_names | sort -u | wc -l)
  remaining_n=$(( total_n - done_n ))
  (( remaining_n < 0 )) && remaining_n=0

  local bytes_n unknown_n
  read -r bytes_n unknown_n < <(uploaded_bytes)

  read_phase

  # Written atomically. The collector may read this at any moment, and a
  # half-written file would surface as a wrong number on the dashboard.
  {
    printf 'status=%s\n' "$status"
    printf 'total=%s\n' "$total_n"
    printf 'done=%s\n' "$done_n"
    printf 'remaining=%s\n' "$remaining_n"
    printf 'bytes=%s\n' "${bytes_n:-0}"
    printf 'bytes_unknown=%s\n' "${unknown_n:-0}"
    printf 'updated=%s\n' "$(date +%s)"
    printf 'phase=%s\n' "${PHASE:-}"
    printf 'phase_file=%s\n' "${PHASE_NAME_FILE:-}"
    printf 'phase_index=%s\n' "${PHASE_INDEX:-0}"
    printf 'phase_total=%s\n' "${PHASE_TOTAL:-0}"
  } > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

mkdir -p "$WORK_DIR"
touch "$UPLOADED_LOG"

# --- helpers ---------------------------------------------------------------

staged_count() {
  local n
  shopt -s nullglob
  local files=("$STAGING_DIR"/*.insv)
  shopt -u nullglob
  n=${#files[@]}
  echo "$n"
}

# Every filename the phone fingerprinted, one per line. Same last-field parse
# verify-batch.sh uses, so the two can never disagree about what a manifest
# line means.
manifest_names() {
  [[ -r "$MANIFEST" ]] || return 0
  awk '{ n = $NF; sub(/^\*/, "", n); sub(/.*\//, "", n); if (n != "") print n }' "$MANIFEST"
}

uploaded_names() {
  [[ -r "$UPLOADED_LOG" ]] || return 0
  # Field 2 exactly, not "everything after field 1". The ledger gained a size
  # column on 2026-09-15, and `cut -f2-` would return "NAME SIZE" as the name.
  awk 'NF >= 2 { print $2 }' "$UPLOADED_LOG" 2>/dev/null
}

# Bytes archived, and how many rows could not contribute.
#
# Rows written before the size column exists have two fields. Counting those as
# zero would silently under-report the total, so they are counted separately
# and the dashboard says how many are unknown rather than quietly guessing.
uploaded_bytes() {
  [[ -r "$UPLOADED_LOG" ]] || { echo "0 0"; return; }
  awk '
    NF >= 3 && $3 ~ /^[0-9]+$/ { sum += $3; next }
    NF >= 2                    { unknown++ }
    END { printf "%d %d\n", sum + 0, unknown + 0 }
  ' "$UPLOADED_LOG" 2>/dev/null || echo "0 0"
}

# Record what a completed batch contained. tg-upload.sh deletes staging on
# success and keeps no record of its own, so without this nothing on the VM
# knows how far through the card we are - status could only ever report "what
# is in staging right now".
# NOTE: recording into uploaded.sha256 deliberately lives in tg-upload.sh, not
# here. That script is the one that knows a file survived the round trip, and
# it is a supported entry point on its own - recording in this wrapper meant a
# direct tg-upload.sh run archived files that were never written down. Keeping
# the logic in one place also stops the two copies drifting apart.

# --- commands --------------------------------------------------------------

cmd_status() {
  local total done_n staged remaining running="no"

  total=$(manifest_names | sort -u | wc -l)
  done_n=$(uploaded_names | sort -u | wc -l)
  staged=$(staged_count)
  remaining=$(( total - done_n ))
  (( remaining < 0 )) && remaining=0

  # A held lock means a loop is live. Ask whether the lock can be ACQUIRED, not
  # whether the lock file exists: the file is never deleted, so testing for its
  # existence reports "running" forever after the first run. If flock itself is
  # unavailable the honest answer is "unknown", not "yes" - claiming a loop is
  # running when none is would stop the operator starting one.
  if command -v flock >/dev/null 2>&1; then
    if [[ -e "$LOOP_LOCK" ]] && ! ( exec 9>"$LOOP_LOCK"; flock -n 9 ) 2>/dev/null; then
      running="yes"
    fi
  else
    running="unknown (flock unavailable)"
  fi

  echo "card total (fingerprinted on the phone) : $total"
  echo "uploaded and round-trip verified        : $done_n"
  echo "remaining                               : $remaining"
  echo "currently in staging                    : $staged"
  echo "loop running                            : $running"

  if (( total == 0 )); then
    echo
    echo "No manifest entries. MANIFEST=$MANIFEST"
    echo "Generate it on the CARD, before anything moves (stronger - it"
    echo "fingerprints the originals, not a copy of them):"
    echo "  cd /storage/9C33-6BBD/DCIM/tg-batch && sha256sum *.insv > ~/manifest-card.sha256"
    echo "then scp it to \$MANIFEST on this VM."
    echo
    echo "Or on the VM, from what Syncthing delivered:"
    echo "  cd $STAGING_DIR && sha256sum *.insv > $MANIFEST"
  fi
}

cmd_start() {
  # One loop at a time. tg-upload.sh has its own session lock for the upload
  # itself; this one stops two loops from both waiting on it.
  #
  # Guard only when flock exists. A missing flock must not be reported as
  # "another loop is running" - that reads as a deliberate refusal and would
  # leave the operator hunting a loop that was never there. tg-upload.sh holds
  # its own lock regardless, so concurrent uploads are still impossible; what
  # is lost without flock is only the friendlier early warning.
  if command -v flock >/dev/null 2>&1; then
    exec 8>"$LOOP_LOCK"
    if ! flock -n 8; then
      err "another tg-archive loop is already running"
      exit 1
    fi
  else
    err "flock unavailable - relying on tg-upload.sh's own session lock"
  fi

  # Fall back to the install path before giving up. Symlink resolution above
  # handles the normal case, but if readlink is missing or the layout changes,
  # a bare "not executable" naming a path the operator never typed is a
  # confusing way to fail - it sent one real session hunting the wrong problem.
  if [[ ! -x "$UPLOADER" ]]; then
    for candidate in \
      "${TG_UPLOADER:-}" \
      /opt/insta360-archive/bin/tg-upload.sh
    do
      [[ -n "$candidate" && -x "$candidate" ]] || continue
      log "using uploader at $candidate"
      UPLOADER="$candidate"
      break
    done
  fi

  if [[ ! -x "$UPLOADER" ]]; then
    err "cannot find an executable tg-upload.sh"
    err "  looked beside this script: $HERE/tg-upload.sh"
    err "  and at: /opt/insta360-archive/bin/tg-upload.sh"
    err "set TG_UPLOADER=/path/to/tg-upload.sh to override"
    exit 1
  fi

  log "draining - staging: $STAGING_DIR"
  log "stop with: systemctl stop tg-archive (safe at any point)"
  write_state running
  ensure_stignore

  # A transient failure is worth retrying; an endless run of them is not. Ten
  # attempts at 60 s apart is ten minutes of patience, which covers a flood-wait
  # or a brief network outage, and then reports rather than hiding the fault.
  local MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-10}"
  local consecutive_failures=0

  local pass=0 idle_passes=0 batch

  while true; do
    shopt -s nullglob
    batch=("$STAGING_DIR"/*.insv)
    shopt -u nullglob

    if (( ${#batch[@]} == 0 )); then
      idle_passes=$(( idle_passes + 1 ))
      if (( idle_passes >= 2 )); then
        log "staging empty for two passes - the card appears drained"
        log "run 'tg-archive status' to confirm against the manifest"

        # Report against the manifest, not just "the loop ended". A drain that
        # stopped early because Syncthing stalled looks identical from inside
        # the loop; the remaining count is what distinguishes them.
        local total_n done_n remaining_n
        total_n=$(manifest_names | sort -u | wc -l)
        done_n=$(uploaded_names | sort -u | wc -l)
        remaining_n=$(( total_n - done_n ))
        (( remaining_n < 0 )) && remaining_n=0

        if (( remaining_n == 0 )); then
          log "all $total_n file(s) in the manifest are archived"
          write_state complete
        else
          err "drain ended with $remaining_n file(s) still unarchived"
          err "Syncthing may have stalled, or the card was disconnected early"
          write_state incomplete
        fi

        return 0
      fi
      log "staging empty - waiting up to ${IDLE_WAIT_SECONDS}s for Syncthing to deliver more"
      idle_wait
      continue
    fi

    idle_passes=0
    pass=$(( pass + 1 ))
    log "--- batch $pass: ${#batch[@]} file(s) ---"

    # Fingerprint anything new BEFORE Check #1 sees it.
    #
    # This has to happen per batch, not once at startup. Syncthing delivers
    # while the loop runs, so a manifest built at the start covers only what
    # had arrived by then and every later file fails Check #1 as "NOT IN
    # MANIFEST" - correctly, since it genuinely was never fingerprinted. On the
    # first real multi-file batch that retried the same failure 21 times.
    #
    # Same matching rule as verify-batch.sh (last field, strip * and any
    # directory) and the same bare-filename hash, so the two can never disagree
    # about whether a file is listed.
    # The manifest is often created by hand with `sudo tee`, which leaves it
    # root-owned. This runs as ubuntu under systemd, so the append would fail
    # with permission denied and take the drain down with it under `set -e`.
    # Say so plainly instead - the fix is one chown, and a cryptic abort here
    # would look like a Check #1 fault rather than a file-mode one.
    if [[ ! -w "$MANIFEST" ]]; then
      err "manifest is not writable by $(id -un): $MANIFEST"
      err "  sudo chown ubuntu:ubuntu $MANIFEST"
      err "new files cannot be fingerprinted, so Check #1 will reject them"
      sleep 60
      continue
    fi

    manifest_new=0
    for f in "${batch[@]}"; do
      base="$(basename "$f")"
      if awk -v want="$base" '
           { n = $NF; sub(/^\*/, "", n); sub(/.*\//, "", n)
             if (n == want) { found = 1; exit } }
           END { exit !found }' "$MANIFEST" 2>/dev/null; then
        continue
      fi
      ( cd "$STAGING_DIR" && sha256sum "$base" ) >> "$MANIFEST"
      manifest_new=$(( manifest_new + 1 ))
    done
    (( manifest_new )) && log "fingerprinted $manifest_new new file(s)"

    # Do NOT let a failed batch kill the loop. tg-upload.sh already refuses to
    # delete anything it could not verify, so a failure leaves staging intact
    # and retrying is safe. Stopping the whole drain because one batch hit a
    # flood-wait ceiling would mean babysitting it again, which is the thing
    # this script exists to avoid.
    #
    # First, any file that has already failed Check #2 PARTS_AFTER times goes
    # to the parts uploader instead of being uploaded whole yet again.
    parts_fallback "${batch[@]}"

    upload_rc=0
    "$UPLOADER" || upload_rc=$?

    if (( upload_rc == 0 )); then
      # tg-upload.sh records the batch in uploaded.sha256 itself, before it
      # clears staging - see the note near the top of this file.
      log "batch $pass verified and recorded"
      write_state running
      consecutive_failures=0

    elif (( upload_rc == 2 )); then
      # PERMANENT. The uploader cannot fit even one file in the space available,
      # so retrying changes nothing: staging does not shrink, free space does
      # not grow, and the next pass hits the identical arithmetic.
      #
      # This used to be indistinguishable from a flood-wait, so the loop slept
      # 60 s and tried the same directory again - forever, with one error line
      # repeating and nothing to say it would never succeed. A 100 GB staging
      # directory spun silently until someone ran `systemctl stop`.
      err "batch $pass cannot fit in the available space - stopping the drain"
      err "this will NOT resolve by retrying; see the uploader's output above"
      write_state incomplete
      return 1

    else
      # Transient: flood-wait ceiling, a network drop, a round-trip mismatch.
      # tg-upload.sh never deletes what it could not verify, so retrying is
      # safe. But do not retry forever either - a fault that survives this many
      # attempts needs a human, and an endless loop hides that.
      consecutive_failures=$(( consecutive_failures + 1 ))
      err "batch $pass failed (rc=$upload_rc, attempt $consecutive_failures/$MAX_CONSECUTIVE_FAILURES)"
      err "staging left intact, will retry"

      if (( consecutive_failures >= MAX_CONSECUTIVE_FAILURES )); then
        err "giving up after $consecutive_failures consecutive failures"
        err "run tg-upload.sh by hand to see the full output"
        write_state incomplete
        return 1
      fi

      sleep 60
    fi
  done
}

case "${1:-}" in
  start)  cmd_start  ;;
  status) cmd_status ;;
  *)
    cat <<USAGE
tg-archive - drain the camera card into Telegram

  tg-archive start     begin draining; runs until the card is empty
  tg-archive status    done / remaining / staged / running

Normally started automatically by tg-archive.path when files land in staging.
To stop a running drain: systemctl stop tg-archive (safe - nothing unverified
is ever deleted, so the next run retries it).

Files are uploaded, downloaded back and hashed before staging is cleared.
Nothing is deleted from the card by this script - it prints when a batch is
safe to clear.
USAGE
    exit 1
    ;;
esac
