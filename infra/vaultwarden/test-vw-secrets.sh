#!/usr/bin/env bash
# Fixtures for vw-secrets.sh, the only writer of Vaultwarden's secrets.env.
#
# What must hold: a secret never appears in the helper's output or in argv of
# anything it runs; the admin token is stored only as an Argon2id PHC string;
# a rejected input changes NOTHING; turning one thing off leaves the others.
#
# The SHIPPED script runs unmodified. argon2 and openssl are stubs on PATH, and
# VW_APPLY=0 skips the container restart.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SCRIPT="$HERE/vw-secrets.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
# argon2 stub: records its argv, and stdin separately, then returns a PHC.
cat > "$T/bin/argon2" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$ARGV_LOG"
cat > "$STDIN_LOG"
echo '$argon2id$v=19$m=19456,t=2,p=1$c2FsdHNhbHQ$aGFzaGhhc2hoYXNo'
STUB
printf '#!/usr/bin/env bash\necho c2FsdHNhbHRzYWx0\n' > "$T/bin/openssl"
chmod +x "$T/bin/"*

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

F="$T/secrets.env"
# run CMD, feeding the remaining arguments as answer lines on stdin.
run() {
  local cmd="$1"; shift
  local rc=0
  printf '%s\n' "$@" | PATH="$T/bin:$PATH" VW_SECRETS_FILE="$F" VW_APPLY=0 \
    ARGV_LOG="$T/argv" STDIN_LOG="$T/stdin" bash "$SCRIPT" "$cmd" > "$T/out" 2>&1 || rc=$?
  echo "$rc"
}

ID=0f8e2b4c-1a2b-4c3d-9e8f-0123456789ab
KEY='Kp9sSecretPushKey-xyz'
ADMINPW='correct horse battery staple admin'
APPPW='abcd efgh ijkl mnop'

: > "$F"; : > "$T/argv"

echo "== push =="
rc="$(run push "$ID" "$KEY")"
check "succeeds" '[[ "$rc" == 0 ]]'
check "PUSH_ENABLED set" 'grep -qx "PUSH_ENABLED='"'"'true'"'"'" "$F"'
check "id and key stored single-quoted" \
  'grep -qx "PUSH_INSTALLATION_ID='"'"'$ID'"'"'" "$F" && grep -qx "PUSH_INSTALLATION_KEY='"'"'$KEY'"'"'" "$F"'
check "the key never appears in output" '! grep -qF "$KEY" "$T/out"'
cp "$F" "$T/before"
rc="$(run push "not-a-uuid" "$KEY")"
check "a malformed id is refused" '[[ "$rc" != 0 ]]'
check "...and changes nothing" 'cmp -s "$F" "$T/before"'

echo "== admin-on =="
rc="$(run admin-on "$ADMINPW" "different password entirely!!")"
check "mismatched entries are refused" '[[ "$rc" != 0 ]] && cmp -s "$F" "$T/before"'
rc="$(run admin-on "short" "short")"
check "a short password is refused" '[[ "$rc" != 0 ]] && cmp -s "$F" "$T/before"'
: > "$T/argv"
rc="$(run admin-on "$ADMINPW" "$ADMINPW")"
check "succeeds" '[[ "$rc" == 0 ]]'
check "stores an Argon2id PHC, single-quoted" \
  'grep -qE "^ADMIN_TOKEN='"'"'\\\$argon2id\\\$v=19\\\$m=19456,t=2,p=1\\\$" "$F"'
check "the password is not in the file" '! grep -qF "$ADMINPW" "$F"'
check "the password is not in the output" '! grep -qF "$ADMINPW" "$T/out"'
check "the password reached argon2 on stdin" '[[ "$(cat "$T/stdin")" == "$ADMINPW" ]]'
check "...and never in its argv" '! grep -qF "$ADMINPW" "$T/argv"'
check "OWASP parameters and Argon2id" 'grep -qE -- "-id -t 2 -k 19456 -p 1 -e" "$T/argv"'
check "push settings survive" 'grep -q "^PUSH_INSTALLATION_KEY=" "$F"'

echo "== show =="
rc="$(run show)"
check "succeeds" '[[ "$rc" == 0 ]]'
check "names keys, reveals no value" \
  'grep -qx "ADMIN_TOKEN: set" "$T/out" && ! grep -qF "$KEY" "$T/out" && ! grep -qF "argon2id" "$T/out"'
check "warns that the admin page is on" 'grep -q "admin page is ON" "$T/out"'

echo "== admin-off =="
rc="$(run admin-off)"
check "succeeds" '[[ "$rc" == 0 ]]'
check "ADMIN_TOKEN removed" '! grep -q "^ADMIN_TOKEN=" "$F"'
check "push settings untouched" 'grep -q "^PUSH_INSTALLATION_ID=" "$F" && grep -q "^PUSH_ENABLED=" "$F"'

echo "== smtp =="
rc="$(run smtp "family.vault@gmail.com" "$APPPW")"
check "succeeds" '[[ "$rc" == 0 ]]'
check "app password stored without Google's spaces" 'grep -qx "SMTP_PASSWORD='"'"'abcdefghijklmnop'"'"'" "$F"'
check "gmail host and STARTTLS" 'grep -qx "SMTP_HOST='"'"'smtp.gmail.com'"'"'" "$F" && grep -qx "SMTP_SECURITY='"'"'starttls'"'"'" "$F"'
check "app password not in output" '! grep -qF "abcdefghijklmnop" "$T/out"'
cp "$F" "$T/before"
rc="$(run smtp "family.vault@gmail.com" "has'quote")"
check "a value with a quote is refused" '[[ "$rc" != 0 ]]'
check "...and the old SMTP settings are intact" 'cmp -s "$F" "$T/before"'
rc="$(run smtp-off)"
check "smtp-off removes every SMTP_ key" '! grep -q "^SMTP_" "$F"'
check "...and nothing else" 'grep -q "^PUSH_ENABLED=" "$F"'

echo "== guards =="
rc=0; PATH="$T/bin:$PATH" VW_SECRETS_FILE="$T/missing.env" VW_APPLY=0 bash "$SCRIPT" show > "$T/out" 2>&1 || rc=$?
check "a missing secrets file is an error" '[[ "$rc" != 0 ]] && grep -q "missing" "$T/out"'
rc="$(run bogus)"
check "an unknown command is an error" '[[ "$rc" != 0 ]]'
if [[ "$(uname -s)" == Linux ]]; then
  check "file stays mode 0600" '[[ "$(stat -c %a "$F")" == 600 ]]'
else
  echo "  SKIP  file mode (not Linux)"
fi

echo
echo "passed=$pass failed=$fail"
(( fail == 0 ))
