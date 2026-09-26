#!/usr/bin/env bash
# Fixtures for vaultwarden-backup.sh, run END TO END against stubbed tools.
#
# What must hold, because each is a silent way to lose the family's passwords:
#   - only an integrity-checked dump enters backups/, and retention keeps the
#     newest 7 BY NAME, so a bad dump can never push out a good one
#   - the off-Oracle copy uses its own repository and password, never the
#     Oracle job's credentials
#   - a missing off-Oracle configuration is a visible failure (/fail), not a
#     quiet partial success - and the local dump is still made first
#   - any failure pings /fail and records it
#
# The SHIPPED script runs unmodified; docker, sqlite3, restic, curl, chown and
# systemd-cat are stubs on PATH.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SCRIPT="$HERE/vaultwarden-backup.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
cat > "$T/bin/docker" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == "exec vaultwarden /vaultwarden backup" ]]; then
  [[ -z "${FAKE_DOCKER_FAIL:-}" ]] || { echo "Error: No such container: vaultwarden"; exit 1; }
  [[ -z "${FAKE_GARBLED:-}" ]] || { echo "something unexpected"; exit 0; }
  echo "sqlite bytes" > "$VW/db_${FAKE_TS}.sqlite3"
  echo "Backup to '/data/db_${FAKE_TS}.sqlite3' was successful"
  exit 0
fi
exit 1
STUB
cat > "$T/bin/sqlite3" <<'STUB'
#!/usr/bin/env bash
echo "${FAKE_INTEGRITY:-ok}"
STUB
cat > "$T/bin/restic" <<'STUB'
#!/usr/bin/env bash
echo "$* | repo=$RESTIC_REPOSITORY pass=$RESTIC_PASSWORD_FILE rclone=${RCLONE_CONFIG:-} aws=${AWS_ACCESS_KEY_ID:-}" >> "$CALLS"
if [[ "$1 $2" == "cat config" ]]; then exit "${FAKE_REPO_MISSING:-0}"; fi
exit 0
STUB
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == https://* ]] && echo "$a" >> "$PINGS"; done; exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/chown"
printf '#!/usr/bin/env bash\ncat >/dev/null\n' > "$T/bin/systemd-cat"
chmod +x "$T/bin/"*

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

W="$T/w"
setup() {
  rm -rf "$W"; mkdir -p "$W/vw/backups" "$W/vw/attachments" "$W/state/rclone"
  touch "$W/vw/rsa_key.pem" "$W/pass" "$W/state/rclone/rclone.conf" "$W/ledger.sha256"
  # Nine older dumps: retention must leave the newest six of them plus tonight's.
  local d
  for d in 01 02 03 04 05 06 07 08 09; do echo old > "$W/vw/backups/db_202609${d}_023000.sqlite3"; done
  {
    echo "VAULTWARDEN_DATA=$W/vw"
    echo "STATE_DIR=$W/state"
    echo "HEALTHCHECK_VW_BACKUP_UUID=hc-vw"
    echo "OFFSITE_PASSWORD_FILE=$W/pass"
    echo "OFFSITE_EXTRA_PATHS=$W/ledger.sha256"
    echo "RCLONE_CONFIG=$W/state/rclone/rclone.conf"
    # The Oracle job's credentials, present in the shared ops.env:
    echo "AWS_ACCESS_KEY_ID=oracle-key-must-not-leak"
    for line in "$@"; do echo "$line"; done
  } > "$W/ops.env"
  : > "$W/calls"; : > "$W/pings"
}

run() {
  local rc=0
  PATH="$T/bin:$PATH" OPS_ENV_FILE="$W/ops.env" CALLS="$W/calls" PINGS="$W/pings" VW="$W/vw" \
    FAKE_TS="20260926_023000" bash "$SCRIPT" > "$W/out" 2>&1 || rc=$?
  echo "$rc"
}
dumps() { find "$W/vw/backups" -name 'db_*.sqlite3' -printf '%f\n' | sort | tr '\n' ' '; }

echo "== a green night =="
setup "OFFSITE_REPOSITORY=rclone:gdrive:personal-vault-offsite"
rc="$(run)"
check "succeeds" '[[ "$rc" == 0 ]]'
check "tonight's dump is in backups/" '[[ -f "$W/vw/backups/db_20260926_023000.sqlite3" ]]'
check "...and no longer loose in the data dir" '[[ ! -e "$W/vw/db_20260926_023000.sqlite3" ]]'
check "exactly 7 kept" '[[ "$(dumps | wc -w)" -eq 7 ]]'
check "the oldest three went, by name" '[[ "$(dumps)" != *20260901* && "$(dumps)" != *20260903* && "$(dumps)" == *20260904* ]]'
# shellcheck disable=SC2034  # read inside the eval'd check strings below
b="$(grep '^backup ' "$W/calls" || true)"
check "off-Oracle backup ran against the off-Oracle repo" '[[ "$b" == *"repo=rclone:gdrive:personal-vault-offsite"* ]]'
check "...with its own password file" '[[ "$b" == *"pass=$W/pass"* ]]'
check "...and the rclone config" '[[ "$b" == *"rclone=$W/state/rclone/rclone.conf"* ]]'
check "...never with the Oracle job's credentials" '! grep -q "oracle-key-must-not-leak" "$W/calls"'
check "backups/, attachments/, rsa_key and the ledger all go" \
  '[[ "$b" == *"$W/vw/backups"* && "$b" == *"$W/vw/attachments"* && "$b" == *"$W/vw/rsa_key.pem"* && "$b" == *"$W/ledger.sha256"* ]]'
check "missing sends/ is skipped" '[[ "$b" != *"$W/vw/sends"* ]]'
check "the live database never goes" '[[ "$b" != *"db.sqlite3"* ]]'
check "retention and a data check ran" 'grep -q "^forget " "$W/calls" && grep -q "^check --read-data-subset" "$W/calls"'
check "existing repo is not re-initialised" '! grep -q "^init" "$W/calls"'
check "status ok" 'grep -q "^ok " "$W/state/vaultwarden-backup-status"'
check "healthchecks: start then success" \
  'grep -qx "https://hc-ping.com/hc-vw/start" "$W/pings" && grep -qx "https://hc-ping.com/hc-vw" "$W/pings"'

echo "== first night: repository is created =="
setup "OFFSITE_REPOSITORY=rclone:gdrive:personal-vault-offsite"
rc=0; PATH="$T/bin:$PATH" OPS_ENV_FILE="$W/ops.env" CALLS="$W/calls" PINGS="$W/pings" VW="$W/vw" \
  FAKE_TS="20260926_023000" FAKE_REPO_MISSING=1 bash "$SCRIPT" > "$W/out" 2>&1 || rc=$?
check "succeeds" '[[ "$rc" == 0 ]]'
check "restic init ran" 'grep -q "^init" "$W/calls"'

echo "== off-Oracle copy not configured =="
setup
rc="$(run)"
check "fails" '[[ "$rc" != 0 ]]'
check "...but the local dump was still made" '[[ -f "$W/vw/backups/db_20260926_023000.sqlite3" ]]'
check "healthchecks gets /fail" 'grep -qx "https://hc-ping.com/hc-vw/fail" "$W/pings"'
check "status names the missing setting" 'grep -q "OFFSITE_REPOSITORY" "$W/state/vaultwarden-backup-status"'
check "restic never ran" '[[ ! -s "$W/calls" ]]'

echo "== a corrupt dump never enters backups/ =="
setup "OFFSITE_REPOSITORY=rclone:gdrive:x"
# shellcheck disable=SC2034  # read inside the eval'd check strings below
before="$(dumps)"
rc=0; PATH="$T/bin:$PATH" OPS_ENV_FILE="$W/ops.env" CALLS="$W/calls" PINGS="$W/pings" VW="$W/vw" \
  FAKE_TS="20260926_023000" FAKE_INTEGRITY="*** in database main *** Page 3 is never used" \
  bash "$SCRIPT" > "$W/out" 2>&1 || rc=$?
check "fails" '[[ "$rc" != 0 ]]'
check "backups/ is exactly as before" '[[ "$(dumps)" == "$before" ]]'
check "the bad dump is left out for inspection" '[[ -f "$W/vw/db_20260926_023000.sqlite3" ]]'
check "healthchecks gets /fail" 'grep -qx "https://hc-ping.com/hc-vw/fail" "$W/pings"'
check "nothing uploaded" '[[ ! -s "$W/calls" ]]'

echo "== the container is not running =="
setup "OFFSITE_REPOSITORY=rclone:gdrive:x"
rc=0; PATH="$T/bin:$PATH" OPS_ENV_FILE="$W/ops.env" CALLS="$W/calls" PINGS="$W/pings" VW="$W/vw" \
  FAKE_TS="20260926_023000" FAKE_DOCKER_FAIL=1 bash "$SCRIPT" > "$W/out" 2>&1 || rc=$?
check "fails" '[[ "$rc" != 0 ]]'
check "healthchecks gets /fail" 'grep -qx "https://hc-ping.com/hc-vw/fail" "$W/pings"'
check "status records it" 'grep -q "^failed .*docker exec" "$W/state/vaultwarden-backup-status"'

echo "== unrecognised output from the backup command =="
setup "OFFSITE_REPOSITORY=rclone:gdrive:x"
rc=0; PATH="$T/bin:$PATH" OPS_ENV_FILE="$W/ops.env" CALLS="$W/calls" PINGS="$W/pings" VW="$W/vw" \
  FAKE_TS="20260926_023000" FAKE_GARBLED=1 bash "$SCRIPT" > "$W/out" 2>&1 || rc=$?
check "fails rather than guessing a file" '[[ "$rc" != 0 ]] && grep -q "could not find the dump path" "$W/out"'

echo
echo "passed=$pass failed=$fail"
(( fail == 0 ))
