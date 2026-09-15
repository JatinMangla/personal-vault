#!/usr/bin/env bash
#
# Fixture test for extract_ids() in tg-upload.sh.
#
# WHY THIS FILE EXISTS. `telegram-upload --print-file-id` is confirmed present
# in the installed build, but its exact output FORMAT is undocumented, and the
# installed copy is a hand-patched 0.7.1 that must never be upgraded. The parser
# is therefore the riskiest part of verify-by-message-id, and the failure mode
# is silent: a WRONG id fetches the wrong bytes during Check #2, while a missing
# id merely triggers the slow full-channel fallback.
#
# The first draft of the parser accepted any run of >= 5 digits bounded by
# non-digits. This test immediately caught what that does to a real filename:
#
#     VID_20260210_061658_00_135.insv   ->   20260210
#
# An underscore is a non-digit boundary, telegram-upload echoes filenames, and
# Check #2 would have fetched a message id harvested from a date. The parser is
# now anchored: an id must be the whole line, or follow an explicit label.
#
# KEEP THIS IN SYNC with extract_ids() in tg-upload.sh. If the two drift, this
# test passes while the real parser is wrong - which is worse than no test.
#
# Run:  bash ops/insta360-bin/test-extract-ids.sh
# Exits non-zero on any failure, so it is safe to wire into CI.

set -uo pipefail

# Mirrors extract_ids() in tg-upload.sh, verbatim.
extract_ids() {
  printf '%s\n' "$1" | sed -E '
    s/^[[:space:]]+//; s/[[:space:]]+$//
    s/^([Ff]ile[[:space:]]+)?[Ii][Dd][[:space:]]*[:=][[:space:]]*//
    s/^.*[[:space:]]file[[:space:]]+id[[:space:]]+//
  ' | grep -xE '[0-9]{5,}' || true
}

pass=0
fail=0

check() {
  local name="$1" got="$2" want="$3"
  got="$(printf '%s' "$got" | tr '\n' ' ' | sed 's/ *$//')"
  if [[ "$got" == "$want" ]]; then
    echo "  PASS  $name"
    pass=$((pass + 1))
  else
    echo "  FAIL  $name"
    echo "        want: [$want]"
    echo "        got:  [$got]"
    fail=$((fail + 1))
  fi
}

echo "extract_ids fixtures:"

# --- must match ------------------------------------------------------------
check "bare id on its own line"        "$(extract_ids '12345')" "12345"
check "labelled: File ID: N"           "$(extract_ids 'File ID: 987654')" "987654"
check "labelled: id=N"                 "$(extract_ids 'id=456789')" "456789"
check "trailing 'file id N'"           "$(extract_ids 'Uploaded VID.insv with file id 4430700436')" "4430700436"
check "split file emits several ids"   "$(extract_ids '100001
100002')" "100001 100002"
check "indented id still matches"      "$(extract_ids '    550123  ')" "550123"

# --- must NOT match --------------------------------------------------------
echo "  -- must NOT match --"

# The regression. A .insv name carries a date that looks exactly like an id.
check "REGRESSION: filename with date" "$(extract_ids 'VID_20260210_061658_00_135.insv')" ""
check "filename among real output"     "$(extract_ids 'uploading VID_20260524_122556_00_142.insv
778899')" "778899"
check "percentage"                     "$(extract_ids '100%')" ""
check "progress counter"               "$(extract_ids 'uploading 3 of 8')" ""
check "byte size on a line"            "$(extract_ids '5905580032 bytes')" ""
check "empty input"                    "$(extract_ids '')" ""
check "short number alone"             "$(extract_ids '42')" ""

echo
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
