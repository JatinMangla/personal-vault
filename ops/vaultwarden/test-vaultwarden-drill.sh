#!/usr/bin/env bash
# Fixtures for the restore drill's two decisions: which dump it restores, and
# what result it records. Both functions are EXTRACTED FROM THE SHIPPED
# SCRIPT, not copied.
#
#   newest_dump  must pick by the UTC timestamp in the name, not by mtime -
#                a restore resets mtimes, so mtime order would be arbitrary.
#   verdict      PASS only when BOTH copies restored; PASS (ORACLE-ONLY) while
#                the off-Oracle copy is unconfigured (honest partial, gate 5
#                stays open); FAIL whenever a configured copy failed.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
eval "$(sed -n '/^newest_dump() {/,/^}/p; /^verdict() {/,/^}/p' "$HERE/vaultwarden-restore-test.sh")"
declare -f newest_dump >/dev/null && declare -f verdict >/dev/null \
  || { echo "FATAL: could not extract the drill's functions" >&2; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ck() {
  if [[ "$2" == "$3" ]]; then echo "  PASS  $1"; pass=$((pass + 1))
  else echo "  FAIL  $1 (want '$3', got '$2')"; fail=$((fail + 1)); fi
}

echo "== newest_dump =="
mkdir -p "$T/b"
echo x > "$T/b/db_20260926_023000.sqlite3"
echo x > "$T/b/db_20260920_023000.sqlite3"
echo x > "$T/b/db_20261001_023000.sqlite3"
echo x > "$T/b/notes.txt"
# Make the OLDEST name the newest file on disk: mtime must not win.
touch -d '2030-01-01' "$T/b/db_20260920_023000.sqlite3"
ck "picks the newest timestamp in the name, not the newest mtime" "$(newest_dump "$T/b")" "db_20261001_023000.sqlite3"
mkdir -p "$T/empty"
ck "an empty directory yields nothing" "$(newest_dump "$T/empty")" ""
ck "a missing directory yields nothing" "$(newest_dump "$T/absent")" ""

echo "== verdict =="
ck "both restored"                     "$(verdict ok ok)"         "PASS"
ck "off-Oracle not configured yet"     "$(verdict ok absent)"     "PASS (ORACLE-ONLY)"
ck "off-Oracle configured but failed"  "$(verdict ok fail)"       "FAIL"
ck "Oracle failed, off-Oracle fine"    "$(verdict fail ok)"       "FAIL"
ck "Oracle failed, off-Oracle absent"  "$(verdict fail absent)"   "FAIL"

echo
echo "passed=$pass failed=$fail"
(( fail == 0 ))
