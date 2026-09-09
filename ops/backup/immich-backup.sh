#!/usr/bin/env bash
#
# Nightly Immich backup: restic -> Gozunga (S3-compatible, 100 GB free tier).
#
# Runs at 03:00 via systemd timer, one hour after Immich's own 02:00 database
# dump, so every snapshot contains a dump that is at most an hour old and is
# captured atomically alongside the media it describes.
#
# WHAT IS BACKED UP AND WHY:
#   upload/   originals from mobile and browser        - irreplaceable
#   library/  originals under the storage template     - irreplaceable
#   profile/  avatars                                  - tiny
#   backups/  Immich's own Postgres dumps              - REQUIRED, see below
#
# WHAT IS EXCLUDED AND WHY:
#   thumbs/         derived; Immich regenerates on demand
#   encoded-video/  derived; the original is never removed
#   *.mp4/*.mov/... video originals go to the home external drive instead
#
# The exclusions are the entire reason this fits in a 100 GB free tier: the
# repository only ever holds originals, never derived data.
#
# THE DATABASE IS NOT OPTIONAL. Immich stores every file path, album, face
# cluster and piece of metadata in Postgres and does not rescan the library
# folder to rediscover them. Media without the database restores as a heap of
# undifferentiated files.
#
# restic encrypts client-side, so Gozunga only ever holds ciphertext.
#
# THE RESTIC PASSWORD MUST BE STORED SOMEWHERE THAT IS NOT THIS MACHINE.
# Losing it is identical to losing the backup. See ops/README.md.

set -euo pipefail

# --- Configuration --------------------------------------------------------
# Secrets come from an environment file readable only by root (mode 0600).
# Nothing sensitive is ever written into this script or into the repository.
ENV_FILE="${OPS_ENV_FILE:-/etc/personal-vault/ops.env}"

if [[ ! -r "$ENV_FILE" ]]; then
  echo "FATAL: cannot read $ENV_FILE" >&2
  exit 1
fi
# shellcheck source=/dev/null
set -a; source "$ENV_FILE"; set +a

MEDIA_DIR="${UPLOAD_LOCATION:-/mnt/media}"
STATE_DIR="${STATE_DIR:-/var/lib/personal-vault}"
LOG_TAG="immich-backup"

export RESTIC_REPOSITORY="s3:https://${GOZUNGA_ENDPOINT}/immich-backup"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/root/.restic-pass}"
export AWS_ACCESS_KEY_ID="${GOZUNGA_KEY}"
export AWS_SECRET_ACCESS_KEY="${GOZUNGA_SECRET}"

mkdir -p "$STATE_DIR"

log() { echo "[$(date -Is)] $*" | systemd-cat -t "$LOG_TAG" -p info; echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" | systemd-cat -t "$LOG_TAG" -p err; echo "[$(date -Is)] ERROR: $*" >&2; }

# --- Healthcheck signalling ----------------------------------------------
# healthchecks.io is a dead-man's switch. The failure mode it catches is the
# one that otherwise goes unnoticed for months: the job silently stopping.
# A backup nobody is watching is a backup that is not running.
hc() {
  local endpoint="${1:-}"
  [[ -n "${HEALTHCHECK_UUID:-}" ]] || return 0
  curl -fsS -m 10 --retry 3 \
    "https://hc-ping.com/${HEALTHCHECK_UUID}${endpoint}" >/dev/null || true
}

# Report failures to healthchecks.io with the exit code, so an alert says what
# broke rather than merely that something did.
on_error() {
  local code=$?
  err "backup failed with exit code $code"
  echo "failed $(date -Is) exit=$code" > "$STATE_DIR/last-backup-status"
  hc "/${code}"
  exit "$code"
}
trap on_error ERR

hc "/start"
log "starting backup of $MEDIA_DIR"

# --- Preflight ------------------------------------------------------------

if [[ ! -d "$MEDIA_DIR" ]]; then
  err "media directory $MEDIA_DIR does not exist"
  exit 1
fi

# Guard against backing up an unmounted mountpoint. If the block volume failed
# to attach, $MEDIA_DIR is an empty directory on the boot disk, and backing it
# up would let restic's retention policy age out the real snapshots.
if ! mountpoint -q "$MEDIA_DIR"; then
  err "$MEDIA_DIR is not a mountpoint - the block volume may not be attached. Refusing to run."
  exit 1
fi

# Confirm a recent database dump exists. Media without the database is close to
# worthless, so a missing dump is a warning worth surfacing, not a silent pass.
if compgen -G "$MEDIA_DIR/backups/*.sql*" > /dev/null; then
  newest_dump=$(find "$MEDIA_DIR/backups" -name '*.sql*' -printf '%T@ %p\n' \
                | sort -rn | head -1 | cut -d' ' -f2-)
  dump_age_h=$(( ( $(date +%s) - $(stat -c %Y "$newest_dump") ) / 3600 ))
  log "newest database dump: $(basename "$newest_dump") (${dump_age_h}h old)"
  if (( dump_age_h > 26 )); then
    err "WARNING: newest database dump is ${dump_age_h}h old; check Immich's backup setting"
  fi
else
  err "WARNING: no database dump found in $MEDIA_DIR/backups - a restore would have no metadata"
fi

# Initialise the repository on first run. `cat` avoids a non-zero exit from
# `restic snapshots` being swallowed by set -e before we can test it.
if ! restic snapshots --no-lock >/dev/null 2>&1; then
  log "repository not initialised; running restic init"
  restic init
fi

# --- Backup ---------------------------------------------------------------

log "running restic backup"
restic backup "$MEDIA_DIR" \
  --exclude "$MEDIA_DIR/thumbs" \
  --exclude "$MEDIA_DIR/encoded-video" \
  --exclude '*.mp4' \
  --exclude '*.mov' \
  --exclude '*.avi' \
  --exclude '*.mkv' \
  --exclude '*.webm' \
  --exclude '*.tmp' \
  --exclude '*.partial' \
  --tag nightly \
  --host immich-mumbai \
  --verbose

# --- Retention ------------------------------------------------------------
# 7 daily / 4 weekly / 12 monthly. restic deduplicates, so the marginal cost of
# older snapshots is only the blocks that actually changed.

log "applying retention policy"
restic forget \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 12 \
  --prune

# --- Integrity ------------------------------------------------------------
# Reading a 1% subset each night catches silent bit-rot long before a restore
# needs the data. Over a year this reads most of the repository.

log "verifying repository integrity"
if restic check --read-data-subset=1%; then
  echo "ok $(date -Is)" > "$STATE_DIR/last-check-status"
  log "integrity check passed"
else
  echo "failed $(date -Is)" > "$STATE_DIR/last-check-status"
  err "INTEGRITY CHECK FAILED - investigate before trusting this repository"
  exit 1
fi

# --- Record state for the metrics collector -------------------------------
# The /status dashboard reads these files rather than running restic itself,
# which keeps the 15-minute collector fast and avoids hammering the repository.

restic snapshots --json --latest 1 > "$STATE_DIR/last-snapshot.json" 2>/dev/null || true
restic stats --mode raw-data --json > "$STATE_DIR/repo-stats.json" 2>/dev/null || true
echo "ok $(date -Is)" > "$STATE_DIR/last-backup-status"

chmod 0644 "$STATE_DIR"/*.json "$STATE_DIR"/last-*-status 2>/dev/null || true

log "backup completed successfully"
hc ""
