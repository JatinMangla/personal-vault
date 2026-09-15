#!/usr/bin/env bash
#
# Metrics collector — Component D.
#
# Runs every minute on a systemd timer, gathers local metrics, and POSTs
# them OUTBOUND to the Vercel ingest endpoint.
#
# WHY PUSH, NEVER PULL. The Oracle box has no inbound ports and must keep it
# that way, so the dashboard cannot query it. Instead the box pushes outbound to
# Vercel, which writes to Supabase, and the dashboard reads from Supabase. This
# makes storage and health visible from any device anywhere without opening a
# single port or needing Tailscale connected on the viewing device.
#
# Authentication is HMAC-SHA256 over the exact JSON body, with a timestamp
# inside the signed payload so a captured request cannot be replayed later.
#
# This script only ever READS local state and WRITES to stdout and the network.
# It must never mutate Immich, the database or the backup repository.

set -euo pipefail

ENV_FILE="${OPS_ENV_FILE:-/etc/personal-vault/ops.env}"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "FATAL: cannot read $ENV_FILE" >&2
  exit 1
fi
# shellcheck source=/dev/null
set -a; source "$ENV_FILE"; set +a

MEDIA_DIR="${UPLOAD_LOCATION:-/mnt/media}"
STATE_DIR="${STATE_DIR:-/var/lib/personal-vault}"
IMMICH_URL="${IMMICH_BASE_URL:-http://127.0.0.1:2283}"

# Syncthing, for the card -> VM half of the archive pipeline. Defaults match
# ops/insta360-bin/tg-go.sh; the folder id changes if the phone folder is ever
# recreated, which mints a new one (docs/HARD-WON.md).
SYNCTHING_CONFIG="${SYNCTHING_CONFIG:-/home/ubuntu/.local/state/syncthing/config.xml}"
SYNCTHING_URL="${SYNCTHING_URL:-http://127.0.0.1:8384}"
SYNC_FOLDER="${SYNC_FOLDER:-dub20-7j8sw}"
SYNC_DEVICE="${SYNC_DEVICE:-OJKKRMK-ZT2LZBV-E7PJ7WF-X4KQNPT-XKVYLXV-5IQY26R-6T3S5ZF-HAAHYAA}"

for required in METRICS_INGEST_URL METRICS_INGEST_SECRET; do
  if [[ -z "${!required:-}" ]]; then
    echo "FATAL: $required is not set in $ENV_FILE" >&2
    exit 1
  fi
done

# --- Helpers --------------------------------------------------------------

# du -sb on a directory that does not exist should report 0, not fail the run.
dir_bytes() {
  local d="$1" out
  [[ -d "$d" ]] || { echo 0; return; }

  # Capture, then validate. NOT `du ... | cut -f1 || echo 0`.
  #
  # This script runs with `set -o pipefail`, so the pipeline's status is du's,
  # not cut's. On a directory this user cannot fully read, du prints a partial
  # total AND exits non-zero: cut emits a number, then the `||` fires and emits
  # a second one. The variable then holds "0\n0", and the next arithmetic
  # expansion dies with `syntax error in expression`.
  #
  # Invisible while the collector ran as root, because du never failed. It
  # surfaced the first time it ran as ubuntu.
  out="$(du -sb "$d" 2>/dev/null | cut -f1 | head -1)"
  [[ "$out" =~ ^[0-9]+$ ]] && echo "$out" || echo 0
}

# Immich API call with a read-only key. Failure returns empty rather than
# aborting: a metrics push with partial data beats no push at all, because a
# missing push is indistinguishable from the collector being dead.
immich_api() {
  local path="$1"
  [[ -n "${IMMICH_API_KEY:-}" ]] || { echo ''; return; }
  curl -fsS -m 10 -H "x-api-key: ${IMMICH_API_KEY}" \
    "${IMMICH_URL}/api${path}" 2>/dev/null || echo ''
}

# Exactly three integers, always. Same pipefail trap as dir_bytes: `df | tail -1
# || echo "0 0 0"` can emit a real line AND the fallback, and `read -r A B C`
# then silently takes the wrong one - wrong numbers rather than a loud error,
# which is worse.
df_line() {
  local out a b c
  out="$(df -B1 --output=size,used,avail "$1" 2>/dev/null | tail -1 | head -1)"
  read -r a b c <<< "$out"
  if [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ ]]; then
    echo "$a $b $c"
  else
    echo "0 0 0"
  fi
}

json_num() { [[ -n "${1:-}" ]] && echo "$1" || echo 0; }

# --- Syncthing ------------------------------------------------------------
#
# The card -> VM half of the archive. Every call here is best-effort: a
# collector that dies because Syncthing is stopped takes the WHOLE dashboard
# down, including the storage and backup figures that were working. Each helper
# returns empty on any failure and the caller substitutes zeros.
#
# Reading the key needs ProtectHome=read-only in metrics-push.service. Under
# ProtectHome=true the config file is invisible and sync_state stays "unknown" -
# the same wall the restic job hit (docs/HARD-WON.md).

sync_key() {
  [[ -r "$SYNCTHING_CONFIG" ]] || return 0
  grep -o '<apikey>[^<]*</apikey>' "$SYNCTHING_CONFIG" 2>/dev/null |
    sed 's/<[^>]*>//g' | head -1
}

# "state needBytes needFiles globalFiles localFiles", or empty.
#
# Parsed in python rather than grep: the API pretty-prints with a space after
# the colon, so `grep -o '"state":[a-z]*'` returns the key and nothing else.
# That exact truncation already cost this project two debugging sessions.
sync_folder_status() {
  local k="$1"
  [[ -n "$k" ]] || return 0
  curl -s -m 5 -H "X-API-Key: $k" \
    "$SYNCTHING_URL/rest/db/status?folder=$SYNC_FOLDER" 2>/dev/null |
    python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get("state","unknown"), int(d.get("needBytes",0) or 0),
      int(d.get("needFiles",0) or 0), int(d.get("globalFiles",0) or 0),
      int(d.get("localFiles",0) or 0))
' 2>/dev/null || true
}

# "true" / "false" for the phone. Empty when Syncthing cannot be reached, which
# the caller renders as false - unknown and disconnected look the same from the
# dashboard, and claiming "connected" without evidence is the worse error.
sync_connected() {
  local k="$1"
  [[ -n "$k" ]] || return 0
  curl -s -m 5 -H "X-API-Key: $k" \
    "$SYNCTHING_URL/rest/system/connections" 2>/dev/null |
    python3 -c '
import json,sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
dev = d.get("connections",{}).get(sys.argv[1],{})
print("true" if dev.get("connected") else "false")
' "$SYNC_DEVICE" 2>/dev/null || true
}

SYNC_STATE="unknown"
SYNC_NEED_BYTES=0
SYNC_NEED_FILES=0
SYNC_GLOBAL_FILES=0
SYNC_LOCAL_FILES=0
SYNC_CONNECTED=false

_sync_key="$(sync_key)"
if [[ -n "$_sync_key" ]]; then
  _sync_line="$(sync_folder_status "$_sync_key")"
  if [[ -n "$_sync_line" ]]; then
    read -r _st _nb _nf _gf _lf <<< "$_sync_line"
    # Validate every field before it reaches the payload. A non-numeric value
    # interpolated into JSON produces a body that parses as invalid on the
    # server and fails the push with a 400 - losing the storage and backup
    # figures too, for a number nobody needed.
    [[ -n "$_st" ]] && SYNC_STATE="$_st"
    [[ "$_nb" =~ ^[0-9]+$ ]] && SYNC_NEED_BYTES="$_nb"
    [[ "$_nf" =~ ^[0-9]+$ ]] && SYNC_NEED_FILES="$_nf"
    [[ "$_gf" =~ ^[0-9]+$ ]] && SYNC_GLOBAL_FILES="$_gf"
    [[ "$_lf" =~ ^[0-9]+$ ]] && SYNC_LOCAL_FILES="$_lf"
  fi

  _sync_conn="$(sync_connected "$_sync_key")"
  [[ "$_sync_conn" == "true" ]] && SYNC_CONNECTED=true
fi

# --- Storage --------------------------------------------------------------

# Block volume (media). df -B1 gives bytes.
read -r BLOCK_TOTAL BLOCK_USED BLOCK_AVAIL < <(
  df_line "$MEDIA_DIR"
)

# Boot volume.
read -r BOOT_TOTAL BOOT_USED BOOT_AVAIL < <(
  df_line /
)

# Per-directory breakdown.
#
# NOTE: Immich's server storage endpoint reports the whole underlying disk
# rather than Immich's own consumption, and there are open issues about that
# conflation. So the breakdown is computed here with du and the API figure is
# treated as whole-disk only. The dashboard must never label the API number
# "Immich usage".
UPLOAD_BYTES=$(dir_bytes "$MEDIA_DIR/upload")
LIBRARY_BYTES=$(dir_bytes "$MEDIA_DIR/library")
THUMBS_BYTES=$(dir_bytes "$MEDIA_DIR/thumbs")
ENCODED_BYTES=$(dir_bytes "$MEDIA_DIR/encoded-video")
PROFILE_BYTES=$(dir_bytes "$MEDIA_DIR/profile")
BACKUPS_BYTES=$(dir_bytes "$MEDIA_DIR/backups")
# Insta360 drain staging. Not an Immich directory: it holds one file in flight
# between the camera card and Telegram. Without it on the dashboard, a transfer
# in progress inflates the block-volume gauge with nothing to account for it.
STAGING_BYTES=$(dir_bytes "$MEDIA_DIR/tg-staging")

# Insta360 drain progress, written by tg-archive. Absent until a drain has run,
# so every field defaults to zero rather than failing the push - a collector
# that dies because an optional file is missing takes the whole dashboard with
# it, including the parts that were working.
DRAIN_STATE="${INSTA360_WORK_DIR:-/var/lib/insta360-archive/work}/drain-state"
DRAIN_STATUS="idle"
DRAIN_TOTAL=0
DRAIN_DONE=0
DRAIN_REMAINING=0
DRAIN_BYTES=0
DRAIN_BYTES_UNKNOWN=0
DRAIN_UPDATED=0
# Which step of a batch is running right now. `status` only distinguishes
# idle/running/complete/incomplete, so a drain that spends 20 minutes in Check
# #2 looks identical to one uploading. Absent until tg-upload.sh writes one.
DRAIN_PHASE=""
DRAIN_PHASE_FILE=""
DRAIN_PHASE_INDEX=0
DRAIN_PHASE_TOTAL=0
if [[ -r "$DRAIN_STATE" ]]; then
  # Read as key=value rather than sourcing it: this file is written by another
  # process, and sourcing would execute whatever it contains.
  while IFS='=' read -r k v; do
    case "$k" in
      status)        DRAIN_STATUS="$v" ;;
      total)         DRAIN_TOTAL="$v" ;;
      done)          DRAIN_DONE="$v" ;;
      remaining)     DRAIN_REMAINING="$v" ;;
      bytes)         DRAIN_BYTES="$v" ;;
      bytes_unknown) DRAIN_BYTES_UNKNOWN="$v" ;;
      updated)       DRAIN_UPDATED="$v" ;;
      phase)         DRAIN_PHASE="$v" ;;
      phase_file)    DRAIN_PHASE_FILE="$v" ;;
      phase_index)   DRAIN_PHASE_INDEX="$v" ;;
      phase_total)   DRAIN_PHASE_TOTAL="$v" ;;
    esac
  done < "$DRAIN_STATE"
fi

# A filename reaches the payload as a JSON string, and `.insv` names come from
# the camera rather than from us. Strip the two characters that would break the
# body - a stray quote or backslash makes the whole push fail with a 400 and
# takes every other figure with it.
DRAIN_PHASE_FILE="${DRAIN_PHASE_FILE//\\/}"
DRAIN_PHASE_FILE="${DRAIN_PHASE_FILE//\"/}"
[[ "$DRAIN_PHASE_INDEX" =~ ^[0-9]+$ ]] || DRAIN_PHASE_INDEX=0
[[ "$DRAIN_PHASE_TOTAL" =~ ^[0-9]+$ ]] || DRAIN_PHASE_TOTAL=0
ORIGINALS_BYTES=$((UPLOAD_BYTES + LIBRARY_BYTES))

# --- Immich statistics ----------------------------------------------------

# API_OK distinguishes "the API answered and reported zero" from "the API could
# not be reached or its field names changed". Without it, both look like zero
# photos on the dashboard, which is the same silent-wrongness the staleness
# banner exists to prevent. Immich changed several API shapes at v3.0.0, so
# this is a live risk, not a hypothetical one.
STATS_JSON="$(immich_api '/server/statistics')"
API_OK=false
STATS_WARNING=""

if [[ -z "$STATS_JSON" ]]; then
  STATS_WARNING="immich api unreachable or key rejected"
elif ! command -v jq >/dev/null 2>&1; then
  STATS_WARNING="jq not installed on the collector host"
elif ! echo "$STATS_JSON" | jq -e 'has("photos")' >/dev/null 2>&1; then
  # The endpoint answered but does not look like the schema we expect.
  STATS_WARNING="unexpected /server/statistics schema - check for an Immich API change"
else
  API_OK=true
fi

if $API_OK; then
  PHOTO_COUNT=$(echo "$STATS_JSON" | jq -r '.photos // 0')
  VIDEO_COUNT=$(echo "$STATS_JSON" | jq -r '.videos // 0')
  IMMICH_USAGE=$(echo "$STATS_JSON" | jq -r '.usage // 0')
  USAGE_PHOTOS=$(echo "$STATS_JSON" | jq -r '.usagePhotos // 0')
  USAGE_VIDEOS=$(echo "$STATS_JSON" | jq -r '.usageVideos // 0')
else
  echo "[$(date -Is)] WARNING: $STATS_WARNING" >&2
  PHOTO_COUNT=0; VIDEO_COUNT=0; IMMICH_USAGE=0; USAGE_PHOTOS=0; USAGE_VIDEOS=0
fi

# Failed job count across all queues.
JOBS_JSON="$(immich_api '/jobs')"
if [[ -n "$JOBS_JSON" ]] && command -v jq >/dev/null 2>&1; then
  FAILED_JOBS=$(echo "$JOBS_JSON" | jq '[.[].jobCounts.failed // 0] | add // 0')
else
  FAILED_JOBS=0
fi

# --- Backup health --------------------------------------------------------
#
# Read from state files written by immich-backup.sh rather than invoking restic
# here. A 15-minute timer must be fast and must not contend for the repository
# lock with the nightly job.

LAST_BACKUP_TS=0
LAST_BACKUP_STATUS="unknown"
if [[ -r "$STATE_DIR/last-backup-status" ]]; then
  LAST_BACKUP_STATUS="$(cut -d' ' -f1 < "$STATE_DIR/last-backup-status")"
  ts="$(cut -d' ' -f2 < "$STATE_DIR/last-backup-status" 2>/dev/null || echo '')"
  [[ -n "$ts" ]] && LAST_BACKUP_TS="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
fi

SNAPSHOT_COUNT=0
REPO_BYTES=0
if [[ -r "$STATE_DIR/repo-stats.json" ]] && command -v jq >/dev/null 2>&1; then
  REPO_BYTES=$(jq -r '.total_size // 0' < "$STATE_DIR/repo-stats.json" 2>/dev/null || echo 0)
  SNAPSHOT_COUNT=$(jq -r '.snapshots_count // 0' < "$STATE_DIR/repo-stats.json" 2>/dev/null || echo 0)
fi

LAST_CHECK_STATUS="unknown"
[[ -r "$STATE_DIR/last-check-status" ]] && \
  LAST_CHECK_STATUS="$(cut -d' ' -f1 < "$STATE_DIR/last-check-status")"

LAST_DRILL_TS=0
LAST_DRILL_RESULT="never"
if [[ -r "$STATE_DIR/last-restore-drill" ]]; then
  LAST_DRILL_RESULT="$(cut -d' ' -f1 < "$STATE_DIR/last-restore-drill")"
  ts="$(cut -d' ' -f2 < "$STATE_DIR/last-restore-drill" 2>/dev/null || echo '')"
  [[ -n "$ts" ]] && LAST_DRILL_TS="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
fi

# --- Containers -----------------------------------------------------------

container_health() {
  local name="$1"
  docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null \
    || docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null \
    || echo 'missing'
}

HEALTH_SERVER=$(container_health immich_server)
HEALTH_ML=$(container_health immich_machine_learning)
HEALTH_REDIS=$(container_health immich_redis)
HEALTH_DB=$(container_health immich_postgres)

# --- System ---------------------------------------------------------------

read -r MEM_TOTAL MEM_USED MEM_AVAIL < <(
  free -b | awk '/^Mem:/ {print $2, $3, $7}'
)
read -r SWAP_TOTAL SWAP_USED < <(free -b | awk '/^Swap:/ {print $2, $3}')
read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
UPTIME_SECONDS=$(cut -d. -f1 /proc/uptime)

# --- Assemble the payload -------------------------------------------------

TIMESTAMP=$(date +%s)
COLLECTED_AT=$(date -Is)

read -r -d '' PAYLOAD <<JSON || true
{
  "timestamp": $TIMESTAMP,
  "collected_at": "$COLLECTED_AT",
  "host": "$(hostname)",
  "storage": {
    "block_total": ${BLOCK_TOTAL:-0},
    "block_used": ${BLOCK_USED:-0},
    "block_avail": ${BLOCK_AVAIL:-0},
    "boot_total": ${BOOT_TOTAL:-0},
    "boot_used": ${BOOT_USED:-0},
    "boot_avail": ${BOOT_AVAIL:-0},
    "originals_bytes": ${ORIGINALS_BYTES:-0},
    "upload_bytes": ${UPLOAD_BYTES:-0},
    "library_bytes": ${LIBRARY_BYTES:-0},
    "thumbs_bytes": ${THUMBS_BYTES:-0},
    "encoded_video_bytes": ${ENCODED_BYTES:-0},
    "profile_bytes": ${PROFILE_BYTES:-0},
    "staging_bytes": ${STAGING_BYTES:-0},
    "backups_bytes": ${BACKUPS_BYTES:-0}
  },
  "sync": {
    "state": "${SYNC_STATE}",
    "need_bytes": ${SYNC_NEED_BYTES:-0},
    "need_files": ${SYNC_NEED_FILES:-0},
    "global_files": ${SYNC_GLOBAL_FILES:-0},
    "local_files": ${SYNC_LOCAL_FILES:-0},
    "connected": ${SYNC_CONNECTED}
  },
  "archive": {
    "status": "${DRAIN_STATUS}",
    "phase": "${DRAIN_PHASE}",
    "phase_file": "${DRAIN_PHASE_FILE}",
    "phase_index": $(json_num "$DRAIN_PHASE_INDEX"),
    "phase_total": $(json_num "$DRAIN_PHASE_TOTAL"),
    "total": $(json_num "$DRAIN_TOTAL"),
    "done": $(json_num "$DRAIN_DONE"),
    "remaining": $(json_num "$DRAIN_REMAINING"),
    "bytes": $(json_num "$DRAIN_BYTES"),
    "bytes_unknown": $(json_num "$DRAIN_BYTES_UNKNOWN"),
    "updated": $(json_num "$DRAIN_UPDATED")
  },
  "immich": {
    "photo_count": $(json_num "$PHOTO_COUNT"),
    "video_count": $(json_num "$VIDEO_COUNT"),
    "usage_photos": $(json_num "$USAGE_PHOTOS"),
    "usage_videos": $(json_num "$USAGE_VIDEOS"),
    "api_disk_figure": $(json_num "$IMMICH_USAGE"),
    "failed_jobs": $(json_num "$FAILED_JOBS"),
    "api_ok": ${API_OK},
    "api_warning": "${STATS_WARNING}"
  },
  "backup": {
    "last_backup_ts": ${LAST_BACKUP_TS:-0},
    "last_backup_status": "${LAST_BACKUP_STATUS}",
    "snapshot_count": ${SNAPSHOT_COUNT:-0},
    "repo_bytes": ${REPO_BYTES:-0},
    "last_check_status": "${LAST_CHECK_STATUS}",
    "last_drill_ts": ${LAST_DRILL_TS:-0},
    "last_drill_result": "${LAST_DRILL_RESULT}"
  },
  "containers": {
    "server": "${HEALTH_SERVER}",
    "machine_learning": "${HEALTH_ML}",
    "redis": "${HEALTH_REDIS}",
    "database": "${HEALTH_DB}"
  },
  "system": {
    "mem_total": ${MEM_TOTAL:-0},
    "mem_used": ${MEM_USED:-0},
    "mem_available": ${MEM_AVAIL:-0},
    "swap_total": ${SWAP_TOTAL:-0},
    "swap_used": ${SWAP_USED:-0},
    "load1": ${LOAD1:-0},
    "load5": ${LOAD5:-0},
    "load15": ${LOAD15:-0},
    "uptime_seconds": ${UPTIME_SECONDS:-0}
  }
}
JSON

# Collapse to a single line. The HMAC is computed over EXACTLY the bytes that
# are transmitted, so the body must not be reformatted after signing.
BODY="$(echo "$PAYLOAD" | tr -d '\n' | tr -s ' ')"

# --- Sign and send --------------------------------------------------------

SIGNATURE="$(printf '%s' "$BODY" \
  | openssl dgst -sha256 -hmac "$METRICS_INGEST_SECRET" -hex \
  | sed 's/^.* //')"

HTTP_CODE="$(curl -fsS -m 30 -o /tmp/metrics-response.json -w '%{http_code}' \
  -X POST "$METRICS_INGEST_URL" \
  -H 'Content-Type: application/json' \
  -H "X-Signature: sha256=$SIGNATURE" \
  -H "X-Timestamp: $TIMESTAMP" \
  --data-raw "$BODY" 2>/dev/null | tail -1 | head -1)"
# Same pipefail trap, and it was visibly biting: a successful push printed 200,
# the `|| echo '000'` appended a second line, and the log reported "HTTP
# 400000" for a request the server had accepted. Validate rather than append.
[[ "$HTTP_CODE" =~ ^[0-9]{3}$ ]] || HTTP_CODE='000'

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "201" || "$HTTP_CODE" == "204" ]]; then
  echo "[$(date -Is)] metrics pushed (HTTP $HTTP_CODE)"
  [[ -n "${HEALTHCHECK_METRICS_UUID:-}" ]] && \
    curl -fsS -m 10 "https://hc-ping.com/${HEALTHCHECK_METRICS_UUID}" >/dev/null || true
  exit 0
else
  echo "[$(date -Is)] ERROR: metrics push failed (HTTP $HTTP_CODE)" >&2
  [[ -r /tmp/metrics-response.json ]] && head -c 500 /tmp/metrics-response.json >&2
  exit 1
fi
