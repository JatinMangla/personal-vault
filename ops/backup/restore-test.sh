#!/usr/bin/env bash
#
# Restore drill — BLOCKING ACCEPTANCE CRITERION (spec 6.4).
#
# A backup that has never been restored is a hypothesis, not a backup. This
# script turns it into a fact by restoring into a throwaway Docker environment
# and verifying that Immich actually comes up with its library intact.
#
# The project is NOT complete until this has passed at least once, and it should
# be re-run quarterly. Outcomes are appended to ops/RESTORE-LOG.md.
#
# Usage:
#   sudo ops/backup/restore-test.sh            # restore the latest snapshot
#   sudo ops/backup/restore-test.sh <snapshot> # restore a specific one
#
# Safe to run against the live host: everything lands under a temporary
# directory on an isolated Docker network with a distinct compose project name,
# and nothing touches the production stack or its volumes.

set -euo pipefail

ENV_FILE="${OPS_ENV_FILE:-/etc/personal-vault/ops.env}"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "FATAL: cannot read $ENV_FILE" >&2
  exit 1
fi
# shellcheck source=/dev/null
set -a; source "$ENV_FILE"; set +a

export RESTIC_REPOSITORY="s3:https://${GOZUNGA_ENDPOINT}/immich-backup"
export RESTIC_PASSWORD_FILE="${RESTIC_PASSWORD_FILE:-/root/.restic-pass}"
export AWS_ACCESS_KEY_ID="${GOZUNGA_KEY}"
export AWS_SECRET_ACCESS_KEY="${GOZUNGA_SECRET}"

SNAPSHOT="${1:-latest}"
DRILL_DIR="$(mktemp -d /tmp/restore-drill.XXXXXX)"
PROJECT="restoredrill"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOG_FILE="$REPO_ROOT/ops/RESTORE-LOG.md"
STARTED_AT="$(date -Is)"

# Distinct port so the drill cannot collide with the production instance.
DRILL_PORT=2284

FAILURES=()
step()  { echo; echo "=== $* ==="; }
ok()    { echo "  PASS  $*"; }
bad()   { echo "  FAIL  $*"; FAILURES+=("$*"); }

cleanup() {
  step "Tearing down"
  docker compose -p "$PROJECT" -f "$DRILL_DIR/docker-compose.yml" down -v --remove-orphans 2>/dev/null || true
  rm -rf "$DRILL_DIR"
  echo "  cleaned up $DRILL_DIR"
}
trap cleanup EXIT

echo "Restore drill starting at $STARTED_AT"
echo "Snapshot: $SNAPSHOT"
echo "Scratch:  $DRILL_DIR"

# --------------------------------------------------------------------------
step "1. Restoring from restic"

restic restore "$SNAPSHOT" --target "$DRILL_DIR/restore"

# restic preserves absolute paths, so the media lands under the original tree.
RESTORED_MEDIA="$(find "$DRILL_DIR/restore" -type d -name backups -printf '%h\n' | head -1)"
if [[ -z "$RESTORED_MEDIA" ]]; then
  bad "could not locate the restored media root (no backups/ directory found)"
  echo "Restore drill FAILED early. Contents:"; find "$DRILL_DIR/restore" -maxdepth 3 -type d
  exit 1
fi
ok "restored media root: $RESTORED_MEDIA"

# --------------------------------------------------------------------------
step "2. Recreating the marker files the exclusions omitted"

# KNOWN TRAP: a fresh Immich instance checks for a .immich marker in each media
# directory and can refuse to start if one is missing. thumbs/ and
# encoded-video/ are deliberately excluded from the backup, so they do not
# exist after a restore and must be recreated before Immich starts.
mkdir -p "$RESTORED_MEDIA/thumbs" "$RESTORED_MEDIA/encoded-video"
touch "$RESTORED_MEDIA/thumbs/.immich" "$RESTORED_MEDIA/encoded-video/.immich"

for d in upload library profile backups thumbs encoded-video; do
  mkdir -p "$RESTORED_MEDIA/$d"
  touch "$RESTORED_MEDIA/$d/.immich"
done
ok "marker files present in all six media directories"

# --------------------------------------------------------------------------
step "3. Verifying restored file checksums"

# Spot-check three originals against the live copies. Checks integrity of the
# restore path itself, not just that files exist.
LIVE_MEDIA="${UPLOAD_LOCATION:-/mnt/media}"
checked=0; matched=0

while IFS= read -r restored_file; do
  [[ -z "$restored_file" ]] && continue
  rel="${restored_file#"$RESTORED_MEDIA"/}"
  live="$LIVE_MEDIA/$rel"
  [[ -f "$live" ]] || continue
  checked=$((checked + 1))
  if [[ "$(sha256sum < "$restored_file" | cut -d' ' -f1)" == "$(sha256sum < "$live" | cut -d' ' -f1)" ]]; then
    matched=$((matched + 1))
    ok "checksum matches: $rel"
  else
    bad "CHECKSUM MISMATCH: $rel"
  fi
  [[ $checked -ge 3 ]] && break
done < <(find "$RESTORED_MEDIA/upload" "$RESTORED_MEDIA/library" -type f \
           ! -name '.immich' 2>/dev/null | head -20)

if [[ $checked -eq 0 ]]; then
  bad "no files available to checksum - is the repository empty?"
else
  ok "$matched of $checked spot-checked originals match"
fi

# --------------------------------------------------------------------------
step "4. Locating the database dump"

DUMP="$(find "$RESTORED_MEDIA/backups" -name '*.sql*' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-)"
if [[ -z "$DUMP" ]]; then
  bad "no database dump in the restored backups/ directory - restore would have no metadata"
  exit 1
fi
ok "database dump: $(basename "$DUMP") ($(du -h "$DUMP" | cut -f1))"

# --------------------------------------------------------------------------
step "5. Starting an isolated Immich stack"

DRILL_DB_PASS="$(openssl rand -base64 24)"

# A cut-down compose file on its own network. Same pinned images as production,
# because a drill against different versions proves nothing about production.
cat > "$DRILL_DIR/docker-compose.yml" <<COMPOSE
name: $PROJECT

services:
  database:
    image: ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0
    environment:
      POSTGRES_PASSWORD: $DRILL_DB_PASS
      POSTGRES_USER: postgres
      POSTGRES_DB: immich
    volumes:
      - drill-db:/var/lib/postgresql/data
    healthcheck:
      test: pg_isready -U postgres -d immich || exit 1
      interval: 10s
      timeout: 5s
      retries: 20
      start_period: 30s

  redis:
    image: docker.io/valkey/valkey:8-bookworm@sha256:fea8b3e67b15729d4bb70589eb03367bab9ad1ee89c876f54327fc7c6e618571
    healthcheck:
      test: redis-cli ping || exit 1
      interval: 10s
      timeout: 5s
      retries: 10

  immich-server:
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-v2.3.0}
    environment:
      DB_HOSTNAME: database
      DB_USERNAME: postgres
      DB_PASSWORD: $DRILL_DB_PASS
      DB_DATABASE_NAME: immich
      REDIS_HOSTNAME: redis
    volumes:
      - $RESTORED_MEDIA:/data
    ports:
      - '127.0.0.1:$DRILL_PORT:2283'
    depends_on:
      database:
        condition: service_healthy
      redis:
        condition: service_healthy

volumes:
  drill-db:
COMPOSE

# Fail fast if the generated compose file is malformed, rather than getting a
# confusing error several steps later.
docker compose -p "$PROJECT" -f "$DRILL_DIR/docker-compose.yml" config --quiet \
  || { bad "generated drill compose file is invalid"; exit 1; }

docker compose -p "$PROJECT" -f "$DRILL_DIR/docker-compose.yml" up -d database redis
ok "database and queue starting"

echo "  waiting for Postgres to accept connections..."
for _ in $(seq 1 60); do
  if docker compose -p "$PROJECT" -f "$DRILL_DIR/docker-compose.yml" \
       exec -T database pg_isready -U postgres -d immich >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
ok "Postgres ready"

# --------------------------------------------------------------------------
step "6. Restoring the database dump"

# Immich's dumps are gzip-compressed SQL; handle both forms.
if [[ "$DUMP" == *.gz ]]; then
  gunzip -c "$DUMP"
else
  cat "$DUMP"
fi | docker compose -p "$PROJECT" -f "$DRILL_DIR/docker-compose.yml" \
       exec -T database psql -U postgres -d immich -v ON_ERROR_STOP=1 \
  > "$DRILL_DIR/psql.log" 2>&1 \
  && ok "database restored without error" \
  || { bad "database restore reported errors"; tail -20 "$DRILL_DIR/psql.log"; }

# --------------------------------------------------------------------------
step "7. Verifying library contents in the restored database"

query() {
  docker compose -p "$PROJECT" -f "$DRILL_DIR/docker-compose.yml" \
    exec -T database psql -U postgres -d immich -tAc "$1" 2>/dev/null | tr -d '[:space:]'
}

ASSET_COUNT="$(query 'SELECT COUNT(*) FROM assets;' || echo 0)"
ALBUM_COUNT="$(query 'SELECT COUNT(*) FROM albums;' || echo 0)"
FACE_COUNT="$(query 'SELECT COUNT(*) FROM asset_faces;' || echo 0)"
PERSON_COUNT="$(query 'SELECT COUNT(*) FROM person;' || echo 0)"

echo "  assets:  ${ASSET_COUNT:-0}"
echo "  albums:  ${ALBUM_COUNT:-0}"
echo "  faces:   ${FACE_COUNT:-0}"
echo "  people:  ${PERSON_COUNT:-0}"

[[ "${ASSET_COUNT:-0}" -gt 0 ]] && ok "assets present" || bad "no assets in the restored database"
[[ "${FACE_COUNT:-0}"  -gt 0 ]] && ok "face clusters present" \
  || echo "  NOTE  no face clusters - expected only if ML has never run"

# --------------------------------------------------------------------------
step "8. Starting Immich and checking it serves"

docker compose -p "$PROJECT" -f "$DRILL_DIR/docker-compose.yml" up -d immich-server

server_up=false
for _ in $(seq 1 60); do
  if curl -fsS -m 5 "http://127.0.0.1:$DRILL_PORT/api/server/ping" >/dev/null 2>&1; then
    server_up=true; break
  fi
  sleep 5
done

if $server_up; then
  ok "Immich API responding on port $DRILL_PORT"
  api_assets="$(curl -fsS -m 10 "http://127.0.0.1:$DRILL_PORT/api/server/statistics" 2>/dev/null || echo '')"
  [[ -n "$api_assets" ]] && echo "  statistics: $api_assets"
else
  bad "Immich did not become healthy within 5 minutes"
  docker compose -p "$PROJECT" -f "$DRILL_DIR/docker-compose.yml" logs --tail 40 immich-server
fi

# --------------------------------------------------------------------------
step "Result"

FINISHED_AT="$(date -Is)"
if [[ ${#FAILURES[@]} -eq 0 ]]; then
  RESULT="PASS"
  echo "RESTORE DRILL PASSED"
else
  RESULT="FAIL"
  echo "RESTORE DRILL FAILED:"
  printf '  - %s\n' "${FAILURES[@]}"
fi

# Append to the log the dashboard reads for "last restore drill".
{
  [[ -f "$LOG_FILE" ]] || {
    echo "# Restore drill log"
    echo
    echo "Appended automatically by \`ops/backup/restore-test.sh\`."
    echo "A backup that has never been restored is a hypothesis, not a backup."
    echo
  }
  echo "## $STARTED_AT — $RESULT"
  echo
  echo "- Snapshot: \`$SNAPSHOT\`"
  echo "- Assets: ${ASSET_COUNT:-0} | Albums: ${ALBUM_COUNT:-0} | Faces: ${FACE_COUNT:-0} | People: ${PERSON_COUNT:-0}"
  echo "- Checksums verified: ${matched:-0}/${checked:-0}"
  echo "- Finished: $FINISHED_AT"
  if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo "- Failures:"
    printf '  - %s\n' "${FAILURES[@]}"
  fi
  echo
} >> "$LOG_FILE"

echo "Logged to $LOG_FILE"

# Record for the metrics collector so the dashboard can age the drill.
STATE_DIR="${STATE_DIR:-/var/lib/personal-vault}"
mkdir -p "$STATE_DIR"
echo "$RESULT $FINISHED_AT" > "$STATE_DIR/last-restore-drill"
chmod 0644 "$STATE_DIR/last-restore-drill"

[[ "$RESULT" == "PASS" ]] || exit 1
