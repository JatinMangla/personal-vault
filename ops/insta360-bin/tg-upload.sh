#!/usr/bin/env bash
# Upload one staged batch to Telegram, prove it round-trips, then delete it.
# Files leave staging ONLY after being downloaded back and hashed.
set -euo pipefail

ENV_FILE="${TG_ENV_FILE:-/etc/personal-vault/tg-archive.env}"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "FATAL: cannot read $ENV_FILE" >&2
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

STAGING_DIR="${STAGING_DIR:?STAGING_DIR not set}"
MANIFEST="${MANIFEST:?MANIFEST not set}"
WORK_DIR="${WORK_DIR:-/var/lib/insta360-archive/work}"
TG_CHANNEL="${TG_CHANNEL:?TG_CHANNEL not set}"
TG_CONFIG="${TG_CONFIG:-/var/lib/insta360-archive/telegram-upload.json}"
GUARD_MARGIN_GB="${GUARD_MARGIN_GB:-10}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" >&2; }

hc() {
  local endpoint="${1:-}"
  [[ -n "${HEALTHCHECK_TGUPLOAD_UUID:-}" ]] || return 0
  curl -fsS -m 10 --retry 3 "https://hc-ping.com/${HEALTHCHECK_TGUPLOAD_UUID}${endpoint}" >/dev/null || true
}

on_error() {
  local code=$?
  err "upload failed with exit code $code"
  hc "/${code}"
  exit "$code"
}
trap on_error ERR

hc "/start"

[[ -d "$STAGING_DIR" ]] || { err "staging missing: $STAGING_DIR"; exit 1; }
[[ -r "$MANIFEST" ]] || { err "manifest not readable: $MANIFEST"; exit 1; }
[[ -r "$TG_CONFIG" ]] || { err "tg config not readable: $TG_CONFIG"; exit 1; }

command -v telegram-upload >/dev/null || { err "telegram-upload missing"; exit 1; }
command -v telegram-download >/dev/null || { err "telegram-download missing"; exit 1; }

mkdir -p "$WORK_DIR"

# Guard only when flock exists. `command -v` first, because a missing flock
# makes `if ! flock -n 9` true and the run aborts claiming another upload is in
# progress - a confusing lie that sends you hunting a process that was never
# there. Ubuntu ships flock in util-linux so this holds on the VM; it is the
# honest reporting that matters, and it lets the script be tested anywhere.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$WORK_DIR/.session.lock"
  if ! flock -n 9; then
    err "another run holds the session lock"
    exit 1
  fi
else
  err "flock unavailable - running without a session lock"
fi

shopt -s nullglob
staged=("$STAGING_DIR"/*.insv)
shopt -u nullglob

if (( ${#staged[@]} == 0 )); then
  log "staging is empty - nothing to do"
  hc ""
  exit 0
fi

# Drop anything already in the archive.
#
# Syncthing re-delivers whatever is in the phone's tg-batch folder, so a file
# that was uploaded and verified last week arrives again the moment the card is
# reconnected. Without this it would be archived a second time: a duplicate in
# the channel, and the transfer paid for twice.
#
# Matched by HASH, not filename. The name is only a cheap first filter - the
# hash is what uploaded.sha256 records, and it is what makes this self-healing.
# A file reusing an old name with new content must still upload, and comparing
# content is the only way to know the difference.
#
# A skipped file is REMOVED from staging. Leaving it would make the drain loop
# see a permanently non-empty staging directory and spin forever on a file it
# refuses to upload.
UPLOADED_LOG="$WORK_DIR/uploaded.sha256"
batch=()
skipped=0

for f in "${staged[@]}"; do
  base="$(basename "$f")"

  if [[ -r "$UPLOADED_LOG" ]] && grep -qF " $base" "$UPLOADED_LOG"; then
    recorded="$(awk -v want="$base" '$2 == want { print $1; exit }' "$UPLOADED_LOG")"
    actual="$(sha256sum "$f" | cut -d' ' -f1)"

    if [[ -n "$recorded" && "$recorded" == "$actual" ]]; then
      log "already archived, removing from staging: $base"
      rm -f "$f"
      skipped=$(( skipped + 1 ))
      continue
    fi

    err "$base is recorded as archived but the content differs - uploading it"
    err "  recorded $recorded"
    err "  on disk  $actual"
  fi

  batch+=("$f")
done

if (( ${#batch[@]} == 0 )); then
  log "all ${skipped} staged file(s) were already archived - nothing to upload"
  log "SAFE TO CLEAR THIS BATCH FROM THE CARD"
  hc ""
  exit 0
fi

(( skipped )) && log "skipped $skipped file(s) already in the archive"
log "batch of ${#batch[@]} file(s)"

avail_kb="$(df -P "$STAGING_DIR" | awk 'NR==2{print $4}')"
avail_gb=$(( avail_kb / 1024 / 1024 ))

largest_bytes=0
for f in "${batch[@]}"; do
  sz="$(stat -c %s "$f")"
  (( sz > largest_bytes )) && largest_bytes="$sz"
done
largest_gb=$(( largest_bytes / 1024 / 1024 / 1024 + 1 ))

log "free: ${avail_gb} GiB (margin ${GUARD_MARGIN_GB}, round-trip ~${largest_gb})"

if (( avail_gb - largest_gb < GUARD_MARGIN_GB )); then
  err "would breach the ${GUARD_MARGIN_GB} GiB margin - refusing"
  exit 1
fi

log "Check #1 - verifying staged batch"
"$HERE/verify-batch.sh" "$STAGING_DIR"

upload_one() {
  local file="$1" attempt=0 max=8 out rc wait_s

  while (( attempt < max )); do
    attempt=$((attempt + 1))
    set +e
    out="$(telegram-upload --to "$TG_CHANNEL" --config "$TG_CONFIG" --large-files split --no-thumbnail "$file" 2>&1)"
    rc=$?
    set -e

    if (( rc == 0 )); then
      (( attempt > 1 )) && log "  succeeded on attempt $attempt"
      return 0
    fi

    wait_s="$(printf '%s' "$out" | grep -oE 'FLOOD(_PREMIUM)?_WAIT_([0-9]+)' | grep -oE '[0-9]+$' | head -1)"
    if [[ -z "$wait_s" ]]; then
      wait_s="$(printf '%s' "$out" | grep -oiE 'wait of ([0-9]+) seconds' | grep -oE '[0-9]+' | head -1)"
    fi

    if [[ -n "$wait_s" ]]; then
      wait_s=$(( wait_s + 15 ))
      log "  throttled (attempt $attempt/$max) - sleeping ${wait_s}s"
      sleep "$wait_s"
      continue
    fi

    err "upload failed for $(basename "$file") (attempt $attempt/$max, rc=$rc)"
    printf '%s\n' "$out" | tail -5 >&2
    sleep $(( attempt * 30 ))
  done

  err "giving up on $(basename "$file")"
  return 1
}

for f in "${batch[@]}"; do
  log "uploading $(basename "$f") ($(numfmt --to=iec "$(stat -c %s "$f")"))"
  upload_one "$f"
done

manifest_copy="$WORK_DIR/manifest-$(date -u +%Y%m%dT%H%M%SZ).sha256"
cp "$MANIFEST" "$manifest_copy"
log "uploading manifest copy"
upload_one "$manifest_copy" || err "manifest upload failed - not fatal"
rm -f "$manifest_copy"

log "Check #2 - downloading the channel back"

rt_dir="$WORK_DIR/roundtrip.$$"
mkdir -p "$rt_dir"
cleanup() { [[ -n "${rt_dir:-}" ]] && rm -rf "$rt_dir"; }
trap cleanup EXIT

roundtrip_ok=1

if ! ( cd "$rt_dir" && telegram-download --from "$TG_CHANNEL" --config "$TG_CONFIG" -m keep >/dev/null 2>&1 ); then
  err "could not download the channel back"
  roundtrip_ok=0
fi

if (( roundtrip_ok )); then
  for f in "${batch[@]}"; do
    base="$(basename "$f")"

    shopt -s nullglob
    parts=("$rt_dir/$base".[0-9][0-9]*)
    shopt -u nullglob

    joined="$rt_dir/$base"
    if (( ${#parts[@]} > 0 )); then
      mapfile -t sorted < <(
        for p in "${parts[@]}"; do printf '%s\t%s\n' "${p##*.}" "$p"; done | sort -n -k1,1 | cut -f2
      )
      cat "${sorted[@]}" > "$joined"
      log "  rejoined ${#sorted[@]} part(s) for $base"
    fi

    if [[ ! -f "$joined" ]]; then
      err "$base did not come back - nothing to verify"
      roundtrip_ok=0
      break
    fi

    expected="$(awk -v want="$base" '{ n = $NF; sub(/^\*/, "", n); sub(/.*\//, "", n); if (n == want) { print $1; exit } }' "$MANIFEST")"
    actual="$(sha256sum "$joined" | cut -d' ' -f1)"

    if [[ "$actual" != "$expected" ]]; then
      err "ROUND-TRIP MISMATCH: $base"
      err "  expected $expected"
      err "  actual   $actual"
      roundtrip_ok=0
      break
    fi

    log "  round trip verified: $base"
  done
fi

if (( ! roundtrip_ok )); then
  err "Check #2 FAILED - staging NOT deleted, do NOT clear the card"
  exit 1
fi

log "Check #2 passed for all ${#batch[@]} file(s) - clearing staging"

# Record what is now in the archive, BEFORE deleting it.
#
# This has to happen here rather than in a wrapper. tg-upload.sh is the only
# thing that knows a file survived the round trip, and it is a supported entry
# point on its own - run it directly and, until now, nothing was recorded at
# all. The ledger then under-reported the archive forever: tg-prune would
# re-send files already in Telegram, and tg-archive status would under-count.
# That is exactly how the first uploaded file came to be invisible.
#
# Hash the verified file rather than copying the manifest's entry. The manifest
# says what SHOULD be there; this file just proved what IS there, having gone
# to Telegram and come back byte-identical. Recording the stronger fact costs
# one read of a file already in page cache.
for f in "${batch[@]}"; do
  base="$(basename "$f")"
  if ! grep -qF " $base" "$UPLOADED_LOG" 2>/dev/null; then
    printf '%s %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$base" >> "$UPLOADED_LOG"
  fi
done
log "recorded ${#batch[@]} file(s) in $(basename "$UPLOADED_LOG")"

for f in "${batch[@]}"; do
  rm -f "$f"
done

log "staging cleared"
log "SAFE TO CLEAR THIS BATCH FROM THE CARD"
hc ""
