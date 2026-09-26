#!/usr/bin/env bash
#
# Vaultwarden dead-man's switch, every 5 minutes (docs/VAULTWARDEN-PLAN.md,
# Phase 4). Pings healthchecks.io when all four hold, /fail with the reason
# when any does not:
#
#   1. /alive answers on loopback             the server and its database
#   2. /alive answers on https://<tailnet name> tailscale serve + its certificate,
#                                             the path every family device uses
#   3. no config.json in the data dir         M2: it silently overrides
#                                             Ansible and holds the admin token
#   4. >= 15% free on the data filesystem     M3: a full boot volume stops
#                                             SQLite writes - nobody can save
#
# The ping body names WHAT failed but never the vault's URL: healthchecks.io
# is a third party and has no need to learn the tailnet name.
#
# Deliberately NOT part of the 1-minute metrics collector (plan L1): two curls,
# a stat and a df every 5 minutes, nothing on the drain's path. Neutral.

set -euo pipefail

ENV_FILE="${OPS_ENV_FILE:-/etc/personal-vault/ops.env}"
if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

VW_DATA="${VAULTWARDEN_DATA:-/var/lib/vaultwarden}"
VW_ENV="${VAULTWARDEN_ENV:-/opt/vaultwarden/vaultwarden.env}"
VW_PORT="${VAULTWARDEN_PORT:-8222}"
MIN_FREE_PCT="${VAULTWARDEN_MIN_FREE_PCT:-15}"

problems=()

# Free space as a whole percentage of the filesystem holding DIR.
free_pct() {
  df -P "$1" 2>/dev/null | awk 'NR == 2 && $2 > 0 { printf "%d\n", ($4 * 100) / $2 }'
}

# The DOMAIN the Ansible role rendered, e.g. https://mangla.tailXXXX.ts.net (the Tailscale machine name, not the Linux hostname)
vault_url() {
  sed -n 's/^DOMAIN=\(https:\/\/[^[:space:]]*\)$/\1/p' "$VW_ENV" 2>/dev/null | tail -1
}

if ! curl -fsS -m 5 "http://127.0.0.1:${VW_PORT}/alive" >/dev/null 2>&1; then
  problems+=("loopback /alive did not answer")
fi

url="$(vault_url)"
if [[ -z "$url" ]]; then
  problems+=("no DOMAIN in $VW_ENV")
elif ! curl -fsS -m 10 "$url/alive" >/dev/null 2>&1; then
  problems+=("HTTPS on the tailnet name failed (tailscale serve or its certificate)")
fi

if [[ -e "$VW_DATA/config.json" ]]; then
  problems+=("$VW_DATA/config.json exists - someone pressed Save on /admin (RUNBOOK: Vaultwarden)")
fi

pct="$(free_pct "$VW_DATA")"
if [[ -z "$pct" ]]; then
  problems+=("could not read free space for $VW_DATA")
elif (( pct < MIN_FREE_PCT )); then
  problems+=("only ${pct}% free on the filesystem holding $VW_DATA (need ${MIN_FREE_PCT}%)")
fi

if (( ${#problems[@]} == 0 )); then
  msg="ok: loopback, tailnet HTTPS, no config.json, ${pct}% free"
  endpoint=""
else
  msg="$(printf '%s; ' "${problems[@]}")"
  endpoint="/fail"
fi
echo "$msg"

if [[ -n "${HEALTHCHECK_VW_ALIVE_UUID:-}" ]]; then
  # The reason travels in the ping body, so the alert says what broke.
  curl -fsS -m 10 --retry 3 --data-raw "$msg" \
    "https://hc-ping.com/${HEALTHCHECK_VW_ALIVE_UUID}${endpoint}" >/dev/null || true
fi

[[ -z "$endpoint" ]]
