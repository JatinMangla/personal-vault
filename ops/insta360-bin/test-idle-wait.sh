#!/usr/bin/env bash
# Fixtures for the Syncthing-aware idle wait in tg-archive.sh.
#
# WHY. The drain loop ends after two consecutive empty passes, and each one used
# to sleep IDLE_WAIT_SECONDS (300) unconditionally - so every drain finished with
# up to 10 minutes of pure waiting. idle_wait() ends that wait early when
# Syncthing reports it has nothing left to deliver.
#
# The risk runs one way. Waiting too long costs minutes; stopping too early ends
# a drain with files still on the card, and the loop cannot tell that apart from
# a healthy finish. So the ONLY condition that shortens the wait is a positive
# "needBytes == 0 and state == idle". Unreachable, mid-transfer, unknown state
# and unparsable output must all wait the full window, and these fixtures pin
# exactly that.
#
# Helpers are EXTRACTED FROM tg-archive.sh, not copied, so this cannot pass
# against a stale duplicate. sync_status() is the seam and is stubbed here, so
# no network and no Syncthing are involved.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SRC="$HERE/tg-archive.sh"

log() { echo "  [log] $*"; }
err() { echo "  [err] $*" >&2; }

eval "$(sed -n '/^sync_is_done() {/,/^}/p' "$SRC")"
eval "$(sed -n '/^idle_wait() {/,/^}/p' "$SRC")"

if ! declare -f sync_is_done >/dev/null || ! declare -f idle_wait >/dev/null; then
  echo "FATAL: could not extract the idle-wait helpers from tg-archive.sh" >&2
  exit 1
fi

pass=0; fail=0
ck() {
  if [[ "$2" == "$3" ]]; then
    echo "  PASS  $1"; pass=$((pass + 1))
  else
    echo "  FAIL  $1"; echo "        want $3"; echo "        got  $2"; fail=$((fail + 1))
  fi
}

# The seam: every case below is just a different Syncthing reply.
STUB=""
sync_status() { printf '%s\n' "$STUB"; }

echo "sync_is_done - only a positive idle counts (0 = done):"
STUB="0 idle";          sync_is_done; ck "idle with nothing pending"   "$?" "0"
STUB="0 scanning";      sync_is_done; ck "scanning is not done"        "$?" "1"
STUB="1048576 syncing"; sync_is_done; ck "bytes still pending"         "$?" "1"
STUB="0 unknown";       sync_is_done; ck "unknown state"               "$?" "1"
STUB="";                sync_is_done; ck "Syncthing unreachable"       "$?" "1"
STUB="garbage";         sync_is_done; ck "unparsable output"           "$?" "1"
STUB="notanumber idle"; sync_is_done; ck "non-numeric needBytes"       "$?" "1"
# ProtectHome=true hid the API key from a sibling unit three times; an empty
# key yields an empty status, which must read as "not sure", never as "done".
STUB="0";               sync_is_done; ck "truncated reply"             "$?" "1"

echo "idle_wait - shortens ONLY on a positive idle:"
IDLE_WAIT_SECONDS=6
IDLE_POLL_SECONDS=1

STUB="0 idle"
t0=$SECONDS; idle_wait >/dev/null; d=$(( SECONDS - t0 ))
ck "returns promptly when idle" "$(( d <= 2 ))" "1"

STUB="500 syncing"
t0=$SECONDS; idle_wait >/dev/null; d=$(( SECONDS - t0 ))
ck "waits the full window while syncing" "$(( d >= 5 ))" "1"

STUB=""
t0=$SECONDS; idle_wait >/dev/null; d=$(( SECONDS - t0 ))
ck "waits the full window when unreachable" "$(( d >= 5 ))" "1"

# tg-go.sh and tg-archive.sh each carry their own copy of sync_key() and
# sync_status(). That is deliberate - both are standalone entry points on the
# VM and neither sources the other - but two readers of one endpoint must not
# drift apart about what "idle" means, so the copies are pinned equal here.
echo "sync helpers - the two copies must not drift:"
for fn in sync_key sync_status; do
  a="$(sed -n "/^$fn() {/,/^}/p" "$HERE/tg-go.sh")"
  b="$(sed -n "/^$fn() {/,/^}/p" "$HERE/tg-archive.sh")"
  if [[ -n "$a" && "$a" == "$b" ]]; then
    ck "$fn is identical in tg-go.sh and tg-archive.sh" "same" "same"
  else
    ck "$fn is identical in tg-go.sh and tg-archive.sh" "differs" "same"
  fi
done

echo
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
