#!/usr/bin/env bash
#
# Vaultwarden restore drill (docs/VAULTWARDEN-PLAN.md, Phase 3; go/no-go gate 5).
#
# A backup nobody has restored is a hypothesis. This restores the newest
# Vaultwarden dump from EACH backup source and proves it is a working vault:
#
#   oracle   the nightly restic repository in Oracle Object Storage (03:00)
#   offsite  the encrypted off-Oracle copy on Google Drive (02:30, plan C2)
#
# For each source:
#   1. restic restore of the Vaultwarden paths only, into a scratch directory
#   2. the newest db_*.sqlite3 by name; any -wal/-shm beside it deleted
#   3. PRAGMA integrity_check = ok
#   4. byte-identical to the local copy of the same dump, while one exists
#   5. users > 0; counts of users, ciphers, organisations and memberships
#      reported beside the live database's
#   6. a throwaway container of the SAME pinned image, with NO network, serves
#      /alive from the restored data (/alive opens a database connection)
#
# Results: PASS (both sources), PASS (ORACLE-ONLY) when the off-Oracle copy is
# not configured yet - honest about scope, like the Immich drill's DB-ONLY -
# or FAIL. Appended to ops/VAULTWARDEN-RESTORE-LOG.md. Gate 5 needs a PASS.
#
# Usage:  sudo /opt/personal-vault/ops/vaultwarden/vaultwarden-restore-test.sh
# Safe on the live host: nothing touches the production container or its data.

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
STATE_DIR="${STATE_DIR:-/var/lib/personal-vault}"
REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
LOG_FILE="$REPO_ROOT/ops/VAULTWARDEN-RESTORE-LOG.md"
STARTED_AT="$(date -Is)"

FAILURES=()
NOTES=()
step() { echo; echo "=== $* ==="; }
ok()   { echo "  PASS  $*"; }
bad()  { echo "  FAIL  $*"; FAILURES+=("$*"); }
note() { echo "  NOTE  $*"; NOTES+=("$*"); }

# Newest dump in DIR by name (the UTC timestamp is in the name).
newest_dump() {
  find "$1" -maxdepth 1 -type f -name 'db_*.sqlite3' -printf '%f\n' 2>/dev/null | sort | tail -1
}

# oracle_result offsite_result -> the drill's verdict. Each is ok|fail|absent.
# The Oracle copy is mandatory; the off-Oracle copy is reported as missing
# scope rather than failure until it has been configured.
verdict() {
  local oracle="$1" offsite="$2"
  if [[ "$oracle" == ok && "$offsite" == ok ]]; then echo "PASS"
  elif [[ "$oracle" == ok && "$offsite" == absent ]]; then echo "PASS (ORACLE-ONLY)"
  else echo "FAIL"
  fi
}

# One line of counts from a database file.
counts() {
  sqlite3 -readonly "$1" \
    "SELECT (SELECT COUNT(*) FROM users) || ' ' || (SELECT COUNT(*) FROM ciphers) || ' ' ||
            (SELECT COUNT(*) FROM organizations) || ' ' || (SELECT COUNT(*) FROM users_organizations);"
}

# restic settings per source, applied inside a subshell so they never mix.
oracle_env() {
  export RESTIC_REPOSITORY="s3:https://${OCI_NAMESPACE}.compat.objectstorage.${OCI_REGION}.oraclecloud.com/${OCI_BUCKET}"
  export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/root/.restic-pass}"
  export AWS_ACCESS_KEY_ID="${OCI_ACCESS_KEY}" AWS_SECRET_ACCESS_KEY="${OCI_SECRET_KEY}" AWS_DEFAULT_REGION="${OCI_REGION}"
}
offsite_env() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
  export RESTIC_REPOSITORY="$OFFSITE_REPOSITORY"
  export RESTIC_PASSWORD_FILE="${OFFSITE_PASSWORD_FILE:-/root/.restic-offsite-pass}"
  export RCLONE_CONFIG="${RCLONE_CONFIG:-$STATE_DIR/rclone/rclone.conf}"
}

# The drill must run the image production runs, or it proves nothing about it.
IMAGE="$(docker inspect --format '{{.Config.Image}}' "$VW_CONTAINER" 2>/dev/null || true)"
if [[ -z "$IMAGE" ]]; then
  echo "FATAL: container '$VW_CONTAINER' not found - the drill uses its pinned image" >&2
  exit 1
fi

DRILL_DIR="$(mktemp -d /tmp/vw-drill.XXXXXX)"
cleanup() {
  docker rm -f vwdrill-oracle vwdrill-offsite >/dev/null 2>&1 || true
  rm -rf "$DRILL_DIR"
}
trap cleanup EXIT

LIVE_COUNTS="$(counts "$VW_DATA/db.sqlite3" 2>/dev/null || echo '? ? ? ?')"
SUMMARY=()

# drill_source NAME ENVFN -> echoes ok|fail as its last line
drill_source() {
  local src="$1" envfn="$2" root data name c
  step "$src: restore"
  local before=${#FAILURES[@]}
  mkdir -p "$DRILL_DIR/$src"
  if ! ( "$envfn"; export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-$STATE_DIR/restic-cache}"
         restic restore latest --target "$DRILL_DIR/$src" --include "$VW_DATA" ); then
    bad "$src: restic restore failed"; return 1
  fi
  root="$DRILL_DIR/$src$VW_DATA"
  name="$(newest_dump "$root/backups")"
  if [[ -z "$name" ]]; then
    bad "$src: no db_*.sqlite3 in the restored backups/"; return 1
  fi
  ok "$src: newest dump $name"

  data="$DRILL_DIR/$src-data"
  mkdir -p "$data"
  cp -- "$root/backups/$name" "$data/db.sqlite3"
  rm -f -- "$data/db.sqlite3-wal" "$data/db.sqlite3-shm"
  for p in attachments sends; do
    if [[ -d "$root/$p" ]]; then cp -a -- "$root/$p" "$data/"; fi
  done
  cp -a -- "$root"/rsa_key* "$data/" 2>/dev/null || note "$src: no rsa_key in the backup - a restore issues a new one and every device must log in again"

  step "$src: verify"
  local integrity
  integrity="$(sqlite3 -readonly "$data/db.sqlite3" 'PRAGMA integrity_check;' 2>&1 || true)"
  if [[ "$integrity" == ok ]]; then ok "$src: integrity_check ok"; else bad "$src: integrity_check: $integrity"; fi

  if [[ -f "$VW_DATA/backups/$name" ]]; then
    if cmp -s -- "$VW_DATA/backups/$name" "$data/db.sqlite3"; then
      ok "$src: byte-identical to the local $name"
    else
      bad "$src: $name differs from the local copy"
    fi
  else
    note "$src: $name has aged out locally, so no byte comparison"
  fi

  c="$(counts "$data/db.sqlite3" 2>/dev/null || echo '0 0 0 0')"
  read -r u ci o m <<< "$c"
  echo "  users $u, ciphers $ci, organisations $o, memberships $m  (live: $LIVE_COUNTS)"
  if (( ${u:-0} > 0 )); then ok "$src: users present"; else bad "$src: no users in the restored database"; fi

  step "$src: serve it"
  chown -R 1000:1000 "$data"
  docker run -d --name "vwdrill-$src" --network none --user 1000:1000 --read-only \
    --tmpfs /tmp:size=64m --cap-drop ALL --security-opt no-new-privileges:true \
    -e ROCKET_PORT=8080 -e DOMAIN=http://localhost -e SIGNUPS_ALLOWED=false \
    -e PUSH_ENABLED=false -e DISABLE_ICON_DOWNLOAD=true -e ICON_CACHE_TTL=0 \
    -v "$data:/data" "$IMAGE" >/dev/null || { bad "$src: drill container did not start"; return 1; }
  local up=false _
  for _ in $(seq 1 30); do
    if docker exec "vwdrill-$src" curl -fsS -m 3 http://localhost:8080/alive >/dev/null 2>&1; then up=true; break; fi
    sleep 2
  done
  if $up; then ok "$src: restored vault serves /alive (no network)"
  else bad "$src: restored vault did not serve /alive"; docker logs --tail 30 "vwdrill-$src" 2>&1 || true
  fi
  docker rm -f "vwdrill-$src" >/dev/null 2>&1 || true

  SUMMARY+=("$src: $name, users $u, ciphers $ci, orgs $o, memberships $m")
  (( ${#FAILURES[@]} == before ))
}

echo "Vaultwarden restore drill, $STARTED_AT"
echo "Image:   $IMAGE"
echo "Scratch: $DRILL_DIR"
echo "Live:    users ciphers orgs memberships = $LIVE_COUNTS"

oracle_result=fail
if drill_source oracle oracle_env; then oracle_result=ok; fi

offsite_result=absent
if [[ -n "${OFFSITE_REPOSITORY:-}" ]]; then
  offsite_result=fail
  if drill_source offsite offsite_env; then offsite_result=ok; fi
else
  note "offsite: OFFSITE_REPOSITORY not set - the off-Oracle copy was not drilled"
fi

RESULT="$(verdict "$oracle_result" "$offsite_result")"
FINISHED_AT="$(date -Is)"
step "Result: $RESULT"
if (( ${#FAILURES[@]} > 0 )); then printf '  - %s\n' "${FAILURES[@]}"; fi

{
  [[ -f "$LOG_FILE" ]] || {
    echo "# Vaultwarden restore drill log"
    echo
    echo "Appended by \`ops/vaultwarden/vaultwarden-restore-test.sh\`."
    echo
  }
  echo "## $STARTED_AT — $RESULT"
  echo
  echo "- Image: \`$IMAGE\`"
  echo "- Oracle: $oracle_result | Off-Oracle: $offsite_result"
  if (( ${#SUMMARY[@]} > 0 )); then printf -- '- %s\n' "${SUMMARY[@]}"; fi
  echo "- Live at drill time (users ciphers orgs memberships): $LIVE_COUNTS"
  if (( ${#NOTES[@]} > 0 )); then printf -- '- Note: %s\n' "${NOTES[@]}"; fi
  if (( ${#FAILURES[@]} > 0 )); then echo "- Failures:"; printf '  - %s\n' "${FAILURES[@]}"; fi
  echo "- Finished: $FINISHED_AT"
  echo
} >> "$LOG_FILE"
echo "Logged to $LOG_FILE"

mkdir -p "$STATE_DIR"
echo "$RESULT $FINISHED_AT" > "$STATE_DIR/last-vaultwarden-drill"
chmod 0644 "$STATE_DIR/last-vaultwarden-drill"

# Like the Immich drill: only a full PASS exits 0. A partial result is logged
# honestly and still tells the caller that gate 5 is not closed.
[[ "$RESULT" == "PASS" ]]
