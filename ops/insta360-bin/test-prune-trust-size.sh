#!/usr/bin/env bash
# Fixtures for tg-prune.sh's --trust-size fast path.
#
# WHY. --trust-size deletes footage from the card on the strength of a NAME and
# a SIZE, without reading the file. That is a deliberately weaker check than the
# default SHA-256, and it deletes originals, so the exact boundary of what it
# will and will not act on has to be pinned rather than assumed.
#
# The rules under test:
#   name not in ledger        -> keep (never deleted, either mode)
#   name + size both match    -> prune (the fast path's whole purpose)
#   name matches, size does not -> KEEP, and say so
#   ledger row has no size    -> fall back to hashing, never trust the name
#
# That last one matters: rows written before 2026-09-15 have no size column,
# and treating a missing field as a match would delete on the filename alone -
# the precise mistake this script exists to prevent.
#
# Pure logic, no card and no VM: the decision is reimplemented here against the
# same ledger format. Run: bash test-prune-trust-size.sh
set -uo pipefail

pass=0; fail=0
ck() {
  if [[ "$2" == "$3" ]]; then
    echo "  PASS  $1"; pass=$((pass + 1))
  else
    echo "  FAIL  $1"; echo "        want $3"; echo "        got  $2"; fail=$((fail + 1))
  fi
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Ledger: <sha256> <name> <size> <ids>
# Row 3 deliberately has NO size column, as pre-2026-09-15 rows do.
cat > "$T/ledger" <<'EOF'
aaaa111 A.insv 1000 104
bbbb222 B.insv 2000 105
cccc333 C.insv
EOF

# The decision under test, mirroring tg-prune.sh's --trust-size branch.
decide() {
  local base="$1" actual_size="$2" ledger="$T/ledger"
  local recorded rec_size
  recorded="$(awk -v want="$base" '$2 == want { print $1; exit }' "$ledger")"
  [[ -z "$recorded" ]] && { echo "fresh"; return; }
  rec_size="$(awk -v want="$base" '$2 == want { print $3; exit }' "$ledger")"
  if [[ "$rec_size" =~ ^[0-9]+$ ]] && [[ "$actual_size" =~ ^[0-9]+$ ]]; then
    if [[ "$rec_size" == "$actual_size" ]]; then echo "prune"; else echo "keep-size"; fi
    return
  fi
  echo "hash-fallback"
}

echo "--trust-size decisions:"
ck "name+size match -> prune"          "$(decide A.insv 1000)" "prune"
ck "second file, both match -> prune"  "$(decide B.insv 2000)" "prune"
ck "name absent -> fresh, never touched" "$(decide ZZZ.insv 1000)" "fresh"

# THE hole this flag opens, pinned so it stays narrow: a size mismatch must be
# kept, not deleted. This is the re-recorded-file case.
ck "same name, DIFFERENT size -> keep" "$(decide A.insv 999)"  "keep-size"
ck "same name, much larger    -> keep" "$(decide B.insv 99999)" "keep-size"

# A legacy row with no size must never be trusted on the name alone.
ck "no size in ledger -> hash fallback" "$(decide C.insv 1000)" "hash-fallback"
# An unreadable file yields an empty size; that must not be treated as a match.
ck "unreadable size  -> hash fallback" "$(decide A.insv '')"   "hash-fallback"

echo
echo "what --trust-size CANNOT catch (documented, not a bug):"
# Same name, same size, different content. The hash would catch this; size
# cannot. Recorded here so the limitation is visible in the test output rather
# than only in a comment.
ck "same name+size, different content -> PRUNES (blind spot)" "$(decide A.insv 1000)" "prune"

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
