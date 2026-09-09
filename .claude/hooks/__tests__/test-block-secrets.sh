#!/usr/bin/env bash
# Regression suite for block-secrets.sh.
# Run from the repo root: bash .claude/hooks/__tests__/test-block-secrets.sh
# Exits non-zero if any case regresses, so CI can gate on it.
set -uo pipefail

HOOK=".claude/hooks/block-secrets.sh"
[ -f "$HOOK" ] || { echo "hook not found at $HOOK (run from repo root)"; exit 1; }

pass=0; fail=0
check() {
  local name="$1" want="$2" body="$3"
  printf '%s' "$body" | bash "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  PASS  $name"; pass=$((pass+1))
  else
    echo "  FAIL  $name (want exit $want, got $got)"; fail=$((fail+1))
  fi
}

echo "--- must BLOCK (exit 2) ---"
check "AWS access key ID"      2 '{"file_path":"vault/lib/r2.ts","content":"const id = \"AKIAIOSFODNN7EXAMPLE\";"}'
check "PEM private key"        2 '{"file_path":"infra/key.txt","content":"-----BEGIN RSA PRIVATE KEY-----\nMIIE"}'
check "GitHub PAT"             2 '{"file_path":"a.ts","content":"ghp_aBcDeFgHiJkLmNoPqRsTuVwXyZ0123456789"}'
check "Supabase service_role"  2 '{"file_path":"vault/lib/supabase.ts","content":"const k = service_role_key"}'
check "JWT literal"            2 '{"file_path":"a.ts","content":"eyJhbGciOiJIUzI1NiJ9.eyJyb2xlIjoiYW5vbiJ9.abcdefghijklmno"}'
check "pg conn w/ password"    2 '{"file_path":"a.ts","content":"postgres://user:hunter2secret@db.host:5432/x"}'
check "Tailscale auth key"     2 '{"file_path":"infra/x.yml","content":"tskey-auth-kABC123DEF456ghijkl"}'
check "Stripe live key"        2 '{"file_path":"a.ts","content":"sk_live_51ABCdefGHIjklMNOpqrST"}'
check "secret var assignment"  2 '{"file_path":"vault/.env","content":"METRICS_INGEST_SECRET=9f8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c"}'

echo "--- must ALLOW (exit 0) ---"
check ".env.example names"     0 '{"file_path":"vault/.env.example","content":"METRICS_INGEST_SECRET=\nR2_SECRET_ACCESS_KEY="}'
check "env var reference"      0 '{"file_path":"vault/lib/r2.ts","content":"const key = process.env.R2_SECRET_ACCESS_KEY;"}'
check "placeholder value"      0 '{"file_path":"README.md","content":"API_KEY=your-api-key-goes-here-replace-me"}'
check "ordinary code"          0 '{"file_path":"vault/lib/crypto.ts","content":"export async function deriveKey(p: string) { return 1; }"}'
check "prose about secrets"    0 '{"file_path":"docs/x.md","content":"Store the restic password off-machine. Never commit it."}'

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ] || exit 1
echo "HOOK VERIFIED"
