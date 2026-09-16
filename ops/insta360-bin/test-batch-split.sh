#!/usr/bin/env bash
#
# Fixture test for the batch-fitting loop in tg-upload.sh.
#
# WHY. Before 2026-09-17 the uploader took every .insv in staging as one batch
# and refused outright if the round trip would not fit. With 100 GB staged that
# meant: guard refuses, tg-archive.sh retries the identical directory every
# 60 s, staging never shrinks, nothing ever uploads. A true infinite spin.
#
# It also got the arithmetic wrong. The old guard compared `archive + batch`
# against free space, forgetting the batch is ALREADY on disk and is copied
# again into .roundtrip during Check #2. A 60 GB batch against a 31 GB archive
# passed that check and would have filled a 147 GB volume.
#
# Each file therefore costs its size TWICE. These fixtures pin that.
#
# KEEP IN SYNC with the fitting loop in tg-upload.sh. If they drift, this
# passes while the real selection is wrong - worse than no test.
#
# Run:  bash ops/insta360-bin/test-batch-split.sh
set -uo pipefail
set -uo pipefail
GIB=1

fit() {
  local avail=$1 margin=$2 archive=$3; shift 3
  local -a sizes=("$@")
  local budget=$(( avail - margin - archive ))
  local -a fitted=(); local batch_bytes=0 deferred=0
  for sz in "${sizes[@]}"; do
    if (( ${#fitted[@]} > 0 && batch_bytes + sz*2 > budget )); then
      deferred=$(( deferred + 1 )); continue
    fi
    fitted+=("$sz"); batch_bytes=$(( batch_bytes + sz*2 ))
  done
  echo "${#fitted[@]} $deferred $(( batch_bytes / 2 ))"
}

pass=0; fail=0
check() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then echo "  PASS  $name"; pass=$((pass+1))
  else echo "  FAIL  $name"; echo "        want [$want] got [$got]"; fail=$((fail+1)); fi
}
echo "fit() => 'fitted deferred batch_gb'   [avail margin archive | sizes...]"

# Today's real numbers: 145 free, 10 margin, 31 archive => budget 104
check "5x 2GB batch all fits"        "$(fit 145 10 31 2 2 2 2 2)"      "5 0 10"
check "100GB staging, splits"        "$(fit 145 10 31 20 20 20 20 20)" "2 3 40"
check "60GB single batch refused"    "$(fit 145 10 31 60)"             "1 0 60"
echo "  -- the bug the old guard had --"
# Old guard: archive+batch <= avail-margin => 31+60=91 <= 135 PASSED.
# Real peak was 60 + 91 = 151 > 147. New: 60*2=120 > 104 budget, so deferred.
check "60GB with others defers it"   "$(fit 145 10 31 60 5)"           "1 1 60"
echo "  -- edge cases --"
check "empty budget, one file"       "$(fit 45 10 31 5)"               "1 0 5"
check "exactly at budget"            "$(fit 145 10 31 52)"             "1 0 52"
check "one byte over budget"         "$(fit 145 10 31 53 1)"           "1 1 53"
check "huge archive shrinks batch"   "$(fit 145 10 100 20 20)"         "1 1 20"
echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
