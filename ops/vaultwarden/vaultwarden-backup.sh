#!/usr/bin/env bash
#
# Nightly Vaultwarden backup, 02:30 (docs/VAULTWARDEN-PLAN.md, Phase 2).
#
#   1. A CONSISTENT dump: `/vaultwarden backup` runs SQLite's VACUUM INTO on a
#      read-only connection, producing a self-contained db_<UTC>.sqlite3 with
#      no -wal to lose. Safe while the server is serving. Integrity-checked,
#      then moved to $VAULTWARDEN_DATA/backups/ (root-only), newest 7 kept.
#      The 03:00 restic job picks these up for Oracle Object Storage.
#   2. An ENCRYPTED OFF-ORACLE copy (plan C2): restic over rclone to Google
#      Drive, so losing the Oracle account does not lose the family's
#      passwords. restic encrypts before anything leaves the VM; Google holds
#      ciphertext. The Insta360 ledger rides along (docs/REVIEW-2026-09-24.md
#      open item 5): a few KB, and the only record of what Telegram holds.
#
# Cost: a few MB per night, off the drain's disk and CPU path. Neutral.
#
# Secrets, none in this file: /etc/personal-vault/ops.env (0600),
# /root/.restic-offsite-pass (0600, and on the paper kit as A4), and the rclone
# token in /var/lib/personal-vault/rclone/rclone.conf (0600).

set -euo pipefail

ENV_FILE="${OPS_ENV_FILE:-/etc/personal-vault/ops.env}"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "FATAL: cannot read $ENV_FILE" >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

VW_DATA="${VAULTWARDEN_DATA:-/var/lib/vaultwarden}"
VW_CONTAINER="${VAULTWARDEN_CONTAINER:-vaultwarden}"
KEEP_DUMPS="${VAULTWARDEN_KEEP_DUMPS:-7}"
STATE_DIR="${STATE_DIR:-/var/lib/personal-vault}"
STATUS_FILE="$STATE_DIR/vaultwarden-backup-status"
LOG_TAG="vaultwarden-backup"

log() { echo "[$(date -Is)] $*" | systemd-cat -t "$LOG_TAG" -p info; echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" | systemd-cat -t "$LOG_TAG" -p err; echo "[$(date -Is)] ERROR: $*" >&2; }

hc() {
  local endpoint="${1:-}"
  [[ -n "${HEALTHCHECK_VW_BACKUP_UUID:-}" ]] || return 0
  curl -fsS -m 10 --retry 3 \
    "https://hc-ping.com/${HEALTHCHECK_VW_BACKUP_UUID}${endpoint}" >/dev/null || true
}

# A refusal is a failed backup and must be recorded as one: an explicit exit
# does not fire the ERR trap (the lesson of immich-backup.sh's refuse()).
fail() {
  err "$*"
  echo "failed $(date -Is) $*" > "$STATUS_FILE"
  hc "/fail"
  exit 1
}

on_error() {
  local code=$?
  err "vaultwarden backup failed with exit code $code"
  echo "failed $(date -Is) exit=$code" > "$STATUS_FILE"
  hc "/${code}"
  exit "$code"
}
trap on_error ERR

# `/vaultwarden backup` prints: Backup to 'data/db_20260926_023000.sqlite3' was successful
# The path is RELATIVE in 1.37.3 (DATABASE_URL defaults to data/db.sqlite3,
# resolved from the image's WORKDIR /), which the first real run found on
# 2026-09-26. An absolute /data/... form is accepted too, in case a later
# release or an explicit DATABASE_URL changes it.
# Returns the dump's path relative to the data dir, or nothing if absent.
dump_path_from_output() {
  sed -n "s|^Backup to '/\{0,1\}data/\(db_[0-9]\{8\}_[0-9]\{6\}\.sqlite3\)' was successful.*|\1|p" <<< "$1" | tail -1
}

# Keep the newest N dumps in DIR. The UTC timestamp is in the name, so name
# order is age order - deterministic, unlike mtime after a restore or a copy.
prune_dumps() {
  local dir="$1" keep="$2" f
  local all=()
  while IFS= read -r f; do all+=("$f"); done < <(
    find "$dir" -maxdepth 1 -type f -name 'db_*.sqlite3' -printf '%f\n' | sort -r)
  local i
  for (( i = keep; i < ${#all[@]}; i++ )); do
    rm -f -- "$dir/${all[$i]}"
  done
}

mkdir -p "$STATE_DIR"
hc "/start"
log "starting vaultwarden backup"

# --- 1. Consistent local dump ------------------------------------------------

[[ -d "$VW_DATA" ]] || fail "$VW_DATA does not exist - is Vaultwarden deployed?"
mkdir -p "$VW_DATA/backups"
chmod 0700 "$VW_DATA/backups"

if ! out="$(docker exec "$VW_CONTAINER" /vaultwarden backup 2>&1)"; then
  fail "docker exec $VW_CONTAINER /vaultwarden backup failed: $out"
fi
dump_name="$(dump_path_from_output "$out")"
[[ -n "$dump_name" ]] || fail "could not find the dump path in: $out"
dump="$VW_DATA/$dump_name"
[[ -s "$dump" ]] || fail "dump $dump is missing or empty"

integrity="$(sqlite3 -readonly "$dump" 'PRAGMA integrity_check;' 2>&1 || true)"
if [[ "$integrity" != "ok" ]]; then
  # Left in place, NOT moved into backups/, so a bad dump can never displace a
  # good one in the retention window.
  fail "integrity check failed on $dump: $integrity"
fi

name="$(basename "$dump")"
mv -f -- "$dump" "$VW_DATA/backups/$name"
chown root:root "$VW_DATA/backups/$name"
chmod 0600 "$VW_DATA/backups/$name"
prune_dumps "$VW_DATA/backups" "$KEEP_DUMPS"
log "dump $name ok ($(stat -c %s "$VW_DATA/backups/$name") bytes); keeping newest $KEEP_DUMPS"

# --- 2. Encrypted off-Oracle copy ------------------------------------------

if [[ -z "${OFFSITE_REPOSITORY:-}" ]]; then
  fail "local dump ok, but OFFSITE_REPOSITORY is not set - the off-Oracle copy (plan C2) is not configured. See docs/RUNBOOK.md -> Vaultwarden -> off-Oracle copy."
fi

# Its own repository and password; nothing inherited from the Oracle job.
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION RESTIC_PASSWORD
export RESTIC_REPOSITORY="$OFFSITE_REPOSITORY"
export RESTIC_PASSWORD_FILE="${OFFSITE_PASSWORD_FILE:-/root/.restic-offsite-pass}"
export RCLONE_CONFIG="${RCLONE_CONFIG:-$STATE_DIR/rclone/rclone.conf}"
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-$STATE_DIR/restic-cache}"

[[ -r "$RESTIC_PASSWORD_FILE" ]] || fail "cannot read $RESTIC_PASSWORD_FILE"
[[ -r "$RCLONE_CONFIG" ]] || fail "cannot read $RCLONE_CONFIG"

if ! restic cat config --no-lock >/dev/null 2>&1; then
  log "off-Oracle repository not initialised; running restic init"
  restic init
fi

sources=()
for p in "$VW_DATA/backups" "$VW_DATA/attachments" "$VW_DATA/sends" "$VW_DATA"/rsa_key* \
         ${OFFSITE_EXTRA_PATHS:-/var/lib/insta360-archive/work/uploaded.sha256 /var/lib/insta360-archive/manifest.sha256}; do
  if [[ -e "$p" ]]; then
    sources+=("$p")
  fi
done
log "off-Oracle copy of: ${sources[*]}"

restic backup "${sources[@]}" --tag vaultwarden --host immich-mumbai
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 12 --prune
# The repository is a few MB, so reading a tenth of it nightly is cheap and
# covers the whole of it every few weeks.
restic check --read-data-subset=10%

echo "ok $(date -Is) $name" > "$STATUS_FILE"
chmod 0644 "$STATUS_FILE"
log "vaultwarden backup completed: local dump + off-Oracle copy"
hc ""
