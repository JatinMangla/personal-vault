#!/usr/bin/env bash
#
# Metrics collector — Component D.
#
# Runs every 15 minutes on a systemd timer, gathers local metrics, and POSTs
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

for required in METRICS_INGEST_URL METRICS_INGEST_SECRET; do
  if [[ -z "${!required:-}" ]]; then
    echo "FATAL: $required is not set in $ENV_FILE" >&2
    exit 1
  fi
done

# --- Helpers --------------------------------------------------------------

# du -sb on a directory that does not exist should report 0, not fail the run.
dir_bytes() {
  local d="$1"
  [[ -d "$d" ]] || { echo 0; return; }
  du -sb "$d" 2>/dev/null | cut -f1 || echo 0
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

json_num() { [[ -n "${1:-}" ]] && echo "$1" || echo 0; }

# --- Storage --------------------------------------------------------------

# Block volume (media). df -B1 gives bytes.
read -r BLOCK_TOTAL BLOCK_USED BLOCK_AVAIL < <(
  df -B1 --output=size,used,avail "$MEDIA_DIR" 2>/dev/null | tail -1 || echo "0 0 0"
)

# Boot volume.
read -r BOOT_TOTAL BOOT_USED BOOT_AVAIL < <(
  df -B1 --output=size,used,avail / 2>/dev/null | tail -1 || echo "0 0 0"
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
    "backups_bytes": ${BACKUPS_BYTES:-0}
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
  --data-raw "$BODY" 2>/dev/null || echo '000')"

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
