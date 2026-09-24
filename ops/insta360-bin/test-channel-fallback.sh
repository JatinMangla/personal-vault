#!/usr/bin/env bash
# Fixtures for full_channel_fits() in tg-upload.sh.
#
# WHY. On 2026-09-24 a transient Telegram timeout sent Check #2 into
# downloading the whole 162 GB channel onto a volume with ~111 GB free. That
# download could never finish. full_channel_fits() is the guard that now
# refuses such a fallback, so the property under test is simple and must hold
# exactly: allow the fallback only when archive + this batch + the margin fit
# in the free space, and refuse on anything unparsable.
#
# The function is EXTRACTED FROM THE SHIPPED SCRIPT, not copied. df is stubbed,
# so every case is deterministic on any machine.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
eval "$(sed -n '/^full_channel_fits() {/,/^}/p' "$HERE/tg-upload.sh")"
declare -f full_channel_fits >/dev/null || { echo "FATAL: could not extract full_channel_fits()" >&2; exit 1; }

GIB=$(( 1024 * 1024 * 1024 ))

AVAIL_KB=0
df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/dev/sdb 0 0 %s 0%% /mnt/media\n' "$AVAIL_KB"; }

pass=0; fail=0
ck() {
  local label="$1" want="$2" got
  if full_channel_fits; then got=allow; else got=refuse; fi
  if [[ "$got" == "$want" ]]; then
    echo "  PASS  $label"; pass=$((pass + 1))
  else
    echo "  FAIL  $label (want $want, got $got)"; fail=$((fail + 1))
  fi
}

# Every variable below is read by the eval-extracted full_channel_fits(), which
# the linter cannot see - so SC2034 is disabled for this one function only.
# shellcheck disable=SC2034
run_cases() {
  rt_dir=/fake/roundtrip
  margin_bytes=$(( 10 * GIB ))

  # The 2026-09-24 case: 162 GB channel, 1.3 GB batch (counted twice), 111 GB free.
  archive_bytes=$(( 162 * GIB )); batch_bytes=$(( 2 * 13 * GIB / 10 )); AVAIL_KB=$(( 111 * 1024 * 1024 ))
  ck "162 GB channel on 111 GB free is refused" refuse

  # A small archive easily fits.
  archive_bytes=$(( 5 * GIB )); batch_bytes=$(( 2 * GIB )); AVAIL_KB=$(( 100 * 1024 * 1024 ))
  ck "5 GB channel on 100 GB free is allowed" allow

  # The margin is honoured: fits without it, not with it.
  archive_bytes=$(( 90 * GIB )); batch_bytes=0; AVAIL_KB=$(( 95 * 1024 * 1024 ))
  ck "fits only by eating into the margin is refused" refuse

  # Exactly at the boundary is refused (strictly less than required).
  archive_bytes=$(( 85 * GIB )); batch_bytes=0; AVAIL_KB=$(( 95 * 1024 * 1024 ))
  ck "exactly at the boundary is refused" refuse

  archive_bytes=$(( 84 * GIB )); batch_bytes=0; AVAIL_KB=$(( 95 * 1024 * 1024 ))
  ck "one GiB under the boundary is allowed" allow

  # The batch counts once (batch_bytes is sizes x2, the channel holds it once).
  archive_bytes=$(( 70 * GIB )); batch_bytes=$(( 2 * 10 * GIB )); AVAIL_KB=$(( 95 * 1024 * 1024 ))
  ck "batch counted once, not twice" allow

  # Unparsable df output must refuse, never allow.
  AVAIL_KB="n/a"; archive_bytes=0; batch_bytes=0
  ck "unparsable free space is refused" refuse
}
run_cases

echo
echo "passed=$pass failed=$fail"
(( fail == 0 ))
