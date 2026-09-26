#!/usr/bin/env bash
# Fixtures for immich-backup.sh, run END TO END against stubbed tools.
#
# WHY. Two properties that failed silently before:
#   1. From 2026-09-17 to 09-24 the free-tier guard refused every night while
#      /status showed a stale 291 MiB, because repo-stats.json was written only
#      on success. The real repository was ~71 GB. A refusal must now publish
#      the size it refused on.
#   2. Vaultwarden's consistent dumps ride in the nightly snapshot
#      (docs/VAULTWARDEN-PLAN.md, Phase 2). The live db.sqlite3 and its -wal
#      must never be the thing backed up, and a ledger override
#      (ARCHIVE_LEDGER_FILES) must not drop the password vault.
#
# The SHIPPED script runs unmodified. restic, jq, curl, mountpoint and
# systemd-cat are stubs on PATH, so every case is deterministic on any machine.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SCRIPT="$HERE/immich-backup.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
# restic: records every invocation; `stats` reports FAKE_SIZE bytes.
cat > "$T/bin/restic" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$1" in
  stats)     printf '{"total_size":%s,"total_file_count":1}\n' "$FAKE_SIZE" ;;
  snapshots) [[ " $* " == *" --json "* ]] && echo '[]' ;;
esac
exit 0
STUB
# jq: only `.total_size // 0` is ever asked of it here.
cat > "$T/bin/jq" <<'STUB'
#!/usr/bin/env bash
v="$(sed -n 's/.*"total_size":\([0-9]*\).*/\1/p')"; echo "${v:-0}"
STUB
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == https://* ]] && echo "$a" >> "$PINGS"; done; exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/mountpoint"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "$T/bin/systemd-cat"
chmod +x "$T/bin/"*

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

MIB=1048576

# One fresh world per case: media dir with a dump, state dir, env file, and an
# optional Vaultwarden data dir. Extra env lines come in as arguments.
setup() {
  rm -rf "$T/w"; mkdir -p "$T/w/media/backups" "$T/w/state" "$T/w/vw"
  touch "$T/w/media/backups/immich-db-backup.sql.gz"
  {
    echo "UPLOAD_LOCATION=$T/w/media"
    echo "STATE_DIR=$T/w/state"
    echo "OCI_NAMESPACE=ns"; echo "OCI_REGION=ap-mumbai-1"; echo "OCI_BUCKET=b"
    echo "OCI_ACCESS_KEY=x"; echo "OCI_SECRET_KEY=y"
    echo "HEALTHCHECK_UUID=hc-backup"
    echo "VAULTWARDEN_DATA=$T/w/vw"
    echo "ARCHIVE_LEDGER_FILES=$T/w/none"
    for line in "$@"; do echo "$line"; done
  } > "$T/w/ops.env"
  : > "$T/w/calls"; : > "$T/w/pings"
}

run() {
  local rc=0
  PATH="$T/bin:$PATH" OPS_ENV_FILE="$T/w/ops.env" CALLS="$T/w/calls" PINGS="$T/w/pings" \
    FAKE_SIZE="$1" bash "$SCRIPT" > "$T/w/out" 2>&1 || rc=$?
  echo "$rc"
}

backup_line() { grep '^backup ' "$T/w/calls" || true; }
# The backup SOURCES only: everything before the first --exclude.
sources() { local b; b="$(backup_line)"; echo "${b%% --exclude*}"; }

echo "== guard refusal publishes the size it refused on =="
setup
echo '{"total_size":1,"note":"stale"}' > "$T/w/state/repo-stats.json"
rc="$(run $(( 71128 * MIB )))"
check "refusal exits non-zero" '[[ "$rc" != 0 ]]'
check "repo-stats.json now holds the real 71,128 MiB" \
  'grep -q "\"total_size\":$(( 71128 * MIB ))" "$T/w/state/repo-stats.json"'
check "last-backup-status records the refusal" 'grep -q "^failed .*refused" "$T/w/state/last-backup-status"'
check "healthchecks gets /fail" 'grep -q "hc-backup/fail" "$T/w/pings"'
check "restic backup never ran" '[[ -z "$(backup_line)" ]]'

echo "== a green run backs up Vaultwarden's dumps, never its live database =="
setup
mkdir -p "$T/w/vw/backups" "$T/w/vw/attachments" "$T/w/vw/icon_cache"
touch "$T/w/vw/backups/db_20260926_023000.sqlite3" "$T/w/vw/rsa_key.pem" \
      "$T/w/vw/db.sqlite3" "$T/w/vw/db.sqlite3-wal"
rc="$(run $(( 312 * MIB )))"
b="$(backup_line)"
check "run succeeds" '[[ "$rc" == 0 ]]'
check "backups/ included" '[[ "$b" == *"$T/w/vw/backups"* ]]'
check "attachments/ included" '[[ "$b" == *"$T/w/vw/attachments"* ]]'
check "rsa_key.pem included via the glob" '[[ "$b" == *"$T/w/vw/rsa_key.pem"* ]]'
check "missing sends/ is skipped, not an error" '[[ "$b" != *"$T/w/vw/sends"* ]]'
check "the live db is not a backup source" '[[ "$(sources)" != *"$T/w/vw/db.sqlite3"* && "$(sources)" != *"$T/w/vw "* ]]'
check "db.sqlite3* is excluded anyway" '[[ "$b" == *"--exclude $T/w/vw/db.sqlite3*"* ]]'
check "icon_cache is excluded" '[[ "$b" == *"--exclude $T/w/vw/icon_cache"* ]]'
check "tg-staging is still excluded" '[[ "$b" == *"--exclude $T/w/media/tg-staging"* ]]'
check "status ok" 'grep -q "^ok " "$T/w/state/last-backup-status"'
check "healthchecks gets success" 'grep -qx "https://hc-ping.com/hc-backup" "$T/w/pings"'
check "repo-stats.json holds 312 MiB" 'grep -q "\"total_size\":$(( 312 * MIB ))" "$T/w/state/repo-stats.json"'

echo "== a ledger override does not drop the password vault =="
setup "ARCHIVE_LEDGER_FILES=$T/w/ledger.sha256"
touch "$T/w/ledger.sha256"; mkdir -p "$T/w/vw/backups"
rc="$(run $(( 312 * MIB )))"
b="$(backup_line)"
check "run succeeds" '[[ "$rc" == 0 ]]'
check "ledger included" '[[ "$b" == *"$T/w/ledger.sha256"* ]]'
check "vaultwarden backups still included" '[[ "$b" == *"$T/w/vw/backups"* ]]'

echo "== a host without Vaultwarden backs up exactly as before =="
setup "VAULTWARDEN_DATA=$T/w/absent"
rc="$(run $(( 312 * MIB )))"
b="$(backup_line)"
check "run succeeds" '[[ "$rc" == 0 ]]'
check "no vaultwarden path in the snapshot" '[[ "$(sources)" != *"$T/w/absent"* ]]'
check "no 'including vaultwarden' log line" '! grep -q "including vaultwarden" "$T/w/out"'

echo "== VAULTWARDEN_PATHS overrides the default set =="
setup "VAULTWARDEN_PATHS=$T/w/vw/backups"
mkdir -p "$T/w/vw/backups" "$T/w/vw/attachments"
rc="$(run $(( 312 * MIB )))"
b="$(backup_line)"
check "override honoured" '[[ "$b" == *"$T/w/vw/backups"* && "$b" != *"$T/w/vw/attachments"* ]]'

echo
echo "passed=$pass failed=$fail"
(( fail == 0 ))
