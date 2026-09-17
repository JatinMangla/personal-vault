#!/usr/bin/env bash
# Fixtures for ledger_hash() in tg-upload.sh.
#
# WHY. The ledger is what tg-prune.sh consults before deleting originals from
# the card, so a wrong hash there is the one mistake with no recovery: a file
# whose recorded hash does not match its bytes either blocks a legitimate prune
# forever, or - if it matched some OTHER file's content - would let an
# unarchived original be deleted. HARD-WON.md records a PASTE_HASH_HERE
# placeholder that only the content check caught.
#
# ledger_hash() reuses the hash Check #1 already computed instead of reading
# every file a second time. That is a pure speed change, so the property under
# test is that it is INDISTINGUISHABLE from hashing: every malformed, missing
# or absent entry must fall back to sha256sum rather than record anything else.
#
# The function is EXTRACTED FROM THE SHIPPED SCRIPT, not copied, so the test
# cannot pass against a stale duplicate of the logic.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
err() { echo "  [err] $*" >&2; }

eval "$(sed -n '/^ledger_hash() {/,/^}/p' "$HERE/tg-upload.sh")"

if ! declare -f ledger_hash >/dev/null; then
  echo "FATAL: could not extract ledger_hash() from tg-upload.sh" >&2
  exit 1
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
cd "$T"

printf 'alpha\n' > A.insv
real="$(sha256sum A.insv | cut -d' ' -f1)"

pass=0; fail=0
ck() {
  if [[ "$2" == "$3" ]]; then
    echo "  PASS  $1"; pass=$((pass + 1))
  else
    echo "  FAIL  $1"; echo "        want $3"; echo "        got  $2"; fail=$((fail + 1))
  fi
}

echo "ledger_hash - reuse:"
BATCH_HASHES="$T/h.txt"
printf '%s  A.insv\n' "$real" > "$BATCH_HASHES"
ck "reuses the Check #1 hash" "$(ledger_hash A.insv A.insv)" "$real"

# Git Bash writes "<hash> *name" in binary mode; Linux does not. Every reader
# in this repo strips a leading asterisk for that reason.
printf '%s *A.insv\n' "$real" > "$BATCH_HASHES"
ck "tolerates the binary-mode asterisk" "$(ledger_hash A.insv A.insv)" "$real"

# A manifest hashed by full path writes the path; readers strip it.
printf '%s  /mnt/media/tg-staging/A.insv\n' "$real" > "$BATCH_HASHES"
ck "tolerates a full path" "$(ledger_hash A.insv A.insv)" "$real"

printf 'aaaa\n' > AB.insv
realab="$(sha256sum AB.insv | cut -d' ' -f1)"
{ printf '%s  A.insv\n' "$real"; printf '%s  AB.insv\n' "$realab"; } > "$BATCH_HASHES"
ck "matches the exact name, not a prefix" "$(ledger_hash AB.insv AB.insv)" "$realab"

echo "ledger_hash - every fallback returns the TRUE hash:"
printf '%s  OTHER.insv\n' "$real" > "$BATCH_HASHES"
ck "name absent from the file" "$(ledger_hash A.insv A.insv 2>/dev/null)" "$real"

printf 'NOTAHASH  A.insv\n' > "$BATCH_HASHES"
ck "malformed hash" "$(ledger_hash A.insv A.insv 2>/dev/null)" "$real"

# A truncated hash must never reach the ledger.
printf 'abc123  A.insv\n' > "$BATCH_HASHES"
ck "truncated hash" "$(ledger_hash A.insv A.insv 2>/dev/null)" "$real"

# Not the format this repo writes - treat as untrusted rather than normalise.
printf '%s  A.insv\n' "$(echo "$real" | tr 'a-f' 'A-F')" > "$BATCH_HASHES"
ck "uppercase hash" "$(ledger_hash A.insv A.insv 2>/dev/null)" "$real"

rm -f "$BATCH_HASHES"
ck "hash file missing" "$(ledger_hash A.insv A.insv 2>/dev/null)" "$real"

unset BATCH_HASHES
ck "BATCH_HASHES unset" "$(ledger_hash A.insv A.insv 2>/dev/null)" "$real"

# tg-upload.sh calls verify-batch.sh once PER FILE so hashing overlaps
# uploading. HASH_FILE must therefore ACCUMULATE. It truncated once, which left
# only the last file's hash and silently sent the ledger back to re-reading
# every other file - the optimisation reverting itself with no visible symptom.
echo "HASH_FILE accumulates across per-file calls:"
acc="$T/acc"
mkdir -p "$acc/staging"
for n in A B C; do printf 'content-%s
' "$n" > "$acc/staging/$n.insv"; done
( cd "$acc/staging" && sha256sum ./*.insv > "$acc/manifest.sha256" )
cat > "$acc/env.sh" <<EOF
STAGING_DIR=$acc/staging
MANIFEST=$acc/manifest.sha256
EOF
: > "$acc/bh.txt"
for n in A B C; do
  TG_ENV_FILE="$acc/env.sh" HASH_FILE="$acc/bh.txt"     bash "$HERE/verify-batch.sh" "$acc/staging/$n.insv" >/dev/null 2>&1
done
ck "three per-file runs leave three hashes" "$(wc -l < "$acc/bh.txt" | tr -d ' ')" "3"

acc_ok=yes
while read -r h nm; do
  nm="${nm#\*}"; nm="${nm##*/}"
  [[ "$h" == "$(sha256sum "$acc/staging/$nm" | cut -d' ' -f1)" ]] || acc_ok=no
done < "$acc/bh.txt"
ck "every accumulated hash matches its file" "$acc_ok" "yes"

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
