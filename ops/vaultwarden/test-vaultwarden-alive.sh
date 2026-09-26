#!/usr/bin/env bash
# Fixtures for vaultwarden-alive.sh, the 5-minute dead-man's switch.
#
# Each of its four conditions must turn the ping into /fail WITH the reason in
# the body, and only the all-clear may ping success. curl and df are stubs.
set -euo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SCRIPT="$HERE/vaultwarden-alive.sh"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/bin"
# curl: /alive on loopback or HTTPS succeeds unless told otherwise; hc pings
# are recorded as "URL | body".
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
url="" body=""
while (( $# )); do
  case "$1" in
    --data-raw) body="$2"; shift ;;
    http://*|https://*) url="$1" ;;
  esac
  shift
done
case "$url" in
  https://hc-ping.com/*) echo "$url | $body" >> "$PINGS"; exit 0 ;;
  http://127.0.0.1:*/alive) [[ -z "${FAKE_LOOPBACK_DOWN:-}" ]] ;;
  https://*/alive) [[ -z "${FAKE_HTTPS_DOWN:-}" ]] ;;
  *) exit 1 ;;
esac
STUB
cat > "$T/bin/df" <<'STUB'
#!/usr/bin/env bash
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/sda1 1000 $(( 1000 - FAKE_AVAIL )) ${FAKE_AVAIL} 0% /"
STUB
chmod +x "$T/bin/"*

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

W="$T/w"
setup() {
  rm -rf "$W"; mkdir -p "$W/vw"
  echo "DOMAIN=https://immich-mumbai.tail0000.ts.net" > "$W/vaultwarden.env"
  { echo "VAULTWARDEN_DATA=$W/vw"; echo "VAULTWARDEN_ENV=$W/vaultwarden.env"; echo "HEALTHCHECK_VW_ALIVE_UUID=hc-alive"; } > "$W/ops.env"
  : > "$W/pings"
}
run() {
  local rc=0
  env PATH="$T/bin:$PATH" OPS_ENV_FILE="$W/ops.env" PINGS="$W/pings" FAKE_AVAIL="${AVAIL:-500}" "$@" \
    bash "$SCRIPT" > "$W/out" 2>&1 || rc=$?
  echo "$rc"
}
ping_line() { cat "$W/pings"; }

echo "== all clear =="
setup; rc="$(run)"
check "exits 0" '[[ "$rc" == 0 ]]'
check "pings success, not /fail" '[[ "$(ping_line)" == "https://hc-ping.com/hc-alive | ok:"* ]]'
check "reports the free space" '[[ "$(ping_line)" == *"50% free"* ]]'
check "success ping carries no vault URL" '! grep -q "ts.net" "$W/pings"'

echo "== loopback down =="
setup; rc="$(run FAKE_LOOPBACK_DOWN=1)"
check "exits non-zero" '[[ "$rc" != 0 ]]'
check "/fail with the reason" '[[ "$(ping_line)" == "https://hc-ping.com/hc-alive/fail | "*"loopback"* ]]'

echo "== HTTPS through tailscale serve down (e.g. certificate) =="
setup; rc="$(run FAKE_HTTPS_DOWN=1)"
check "exits non-zero" '[[ "$rc" != 0 ]]'
check "/fail naming the HTTPS path" '[[ "$(ping_line)" == *"/fail | "*"HTTPS on the tailnet name failed"* ]]'
check "the vault URL never goes to the third party" '! grep -q "ts.net" "$W/pings"'

echo "== config.json appeared =="
setup; touch "$W/vw/config.json"; rc="$(run)"
check "exits non-zero" '[[ "$rc" != 0 ]]'
check "/fail naming config.json" '[[ "$(ping_line)" == *"/fail | "*"config.json exists"* ]]'

echo "== boot volume nearly full =="
setup; rc="$(AVAIL=100 run)"
check "exits non-zero at 10% free" '[[ "$rc" != 0 ]]'
check "/fail with the percentage" '[[ "$(ping_line)" == *"/fail | "*"only 10% free"* ]]'
setup; rc="$(AVAIL=150 run)"
check "15% free is enough" '[[ "$rc" == 0 ]]'

echo "== no DOMAIN rendered =="
setup; : > "$W/vaultwarden.env"; rc="$(run)"
check "exits non-zero" '[[ "$rc" != 0 ]]'
check "/fail says why" '[[ "$(ping_line)" == *"/fail | "*"no DOMAIN"* ]]'

echo "== two problems at once are both reported =="
setup; touch "$W/vw/config.json"; rc="$(run FAKE_LOOPBACK_DOWN=1)"
check "both reasons in one ping" '[[ "$(ping_line)" == *"loopback"*"config.json"* ]]'

echo
echo "passed=$pass failed=$fail"
(( fail == 0 ))
