#!/usr/bin/env bash
#
# vw-secrets - the ONLY writer of /opt/vaultwarden/secrets.env.
#
#   sudo vw-secrets push        push relay id + key from bitwarden.com/host (M1)
#   sudo vw-secrets push-off
#   sudo vw-secrets admin-on    turn the /admin page on for one task (M2)
#   sudo vw-secrets admin-off   ...and off again afterwards
#   sudo vw-secrets smtp        optional Gmail SMTP (see SECURITY-NOTES.md)
#   sudo vw-secrets smtp-off
#   sudo vw-secrets show        which keys are set - never their values
#
# Every secret is PROMPTED FOR with echo off, never taken as an argument, so it
# never reaches shell history, `ps`, or Ansible output. The file stays
# root:root 0600 and each change is applied by recreating the container.
#
# The admin page is OFF unless you turn it on: family onboarding works through
# organisation invites alone, so the page is needed only for rare tasks
# (deleting a user, resetting a lost 2FA). Its password is hashed here with
# Argon2id (OWASP preset, as `vaultwarden hash --preset owasp`); only the hash
# is stored.

set -euo pipefail

VW_DIR="${VW_DIR:-/opt/vaultwarden}"
SECRETS="${VW_SECRETS_FILE:-$VW_DIR/secrets.env}"

die() { echo "vw-secrets: $*" >&2; exit 1; }

# Prompt on stderr (read -p writes there), answer on stdout for capture.
ask()        { local v; read -r  -p "$1: " v; printf '%s' "$v"; }
ask_secret() { local v; read -rs -p "$1: " v; echo >&2; printf '%s' "$v"; }

# A value is written as KEY='value', which Docker Compose reads literally: no
# $-interpolation, so an Argon2 PHC string survives intact. That only holds if
# the value itself has no single quote or line break.
valid_value() {
  local v="$1"
  [[ -n "$v" ]] || die "empty value, nothing changed"
  [[ "$v" != *"'"* && "$v" != *$'\n'* && "$v" != *$'\r'* ]] \
    || die "value contains a quote or line break, nothing changed"
}

# Rewrite the file without the given keys. Atomic: a temp file in the same
# directory, mode 0600 before any content is written, then rename.
drop_keys() {
  local tmp re
  re="^($(IFS='|'; echo "$*"))="
  tmp="$(mktemp "$SECRETS.XXXXXX")"
  chmod 0600 "$tmp"
  grep -vE "$re" "$SECRETS" > "$tmp" || true
  mv -f "$tmp" "$SECRETS"
}

# put KEY VALUE [KEY VALUE ...] - replaces those keys, keeps everything else.
# Every value is validated BEFORE the file is touched, so a rejected value
# leaves the previous settings exactly as they were.
put() {
  local keys=() i j
  for (( i = 1; i <= $#; i += 2 )); do
    j=$(( i + 1 ))
    keys+=("${!i}")
    valid_value "${!j}"
  done
  drop_keys "${keys[@]}"
  while (( $# >= 2 )); do
    printf "%s='%s'\n" "$1" "$2" >> "$SECRETS"
    shift 2
  done
}

apply() {
  if [[ "${VW_APPLY:-1}" != 1 ]]; then return 0; fi
  echo "applying: recreating the vaultwarden container (a few seconds)..." >&2
  (cd "$VW_DIR" && docker compose up -d --force-recreate >/dev/null)
  local _
  for _ in $(seq 1 30); do
    if curl -fsS -m 3 http://127.0.0.1:8222/alive >/dev/null 2>&1; then
      echo "vaultwarden is back up." >&2; return 0
    fi
    sleep 2
  done
  die "vaultwarden did not come back within 60 s - check: docker logs --tail 40 vaultwarden"
}

cmd_push() {
  local id key
  echo "From https://bitwarden.com/host (data region: United States)." >&2
  id="$(ask 'Installation ID')"
  [[ "$id" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]] \
    || die "that is not an installation id (expected a UUID), nothing changed"
  key="$(ask_secret 'Installation key (hidden)')"
  valid_value "$key"
  put PUSH_ENABLED true PUSH_INSTALLATION_ID "$id" PUSH_INSTALLATION_KEY "$key"
  echo "push relay: set" >&2
  apply
}

cmd_push_off() { drop_keys PUSH_ENABLED PUSH_INSTALLATION_ID PUSH_INSTALLATION_KEY; echo "push relay: removed" >&2; apply; }

cmd_admin_on() {
  local pw pw2 salt phc
  command -v argon2 >/dev/null || die "argon2 is not installed (the Ansible role installs it)"
  echo "Choose an admin password of 20+ characters. Write it on the emergency kit (C1)." >&2
  pw="$(ask_secret 'Admin password (hidden)')"
  pw2="$(ask_secret 'Again (hidden)')"
  [[ "$pw" == "$pw2" ]] || die "the two entries differ, nothing changed"
  (( ${#pw} >= 20 )) || die "shorter than 20 characters, nothing changed"
  salt="$(openssl rand -base64 24)"
  # The password reaches argon2 on stdin only - never argv.
  phc="$(printf '%s' "$pw" | argon2 "$salt" -id -t 2 -k 19456 -p 1 -e)"
  unset pw pw2
  [[ "$phc" == '$argon2id$'* ]] || die "argon2 did not return an Argon2id PHC string, nothing changed"
  put ADMIN_TOKEN "$phc"
  echo "admin page: ON. Do the task, then: sudo vw-secrets admin-off" >&2
  echo "Never press Save on the admin page (it writes config.json - see RUNBOOK)." >&2
  apply
}

cmd_admin_off() { drop_keys ADMIN_TOKEN; echo "admin page: OFF (/admin is disabled)" >&2; apply; }

cmd_smtp() {
  local addr pw
  echo "Gmail only. Needs 2-Step Verification on the Google account and an" >&2
  echo "App password from https://myaccount.google.com/apppasswords" >&2
  addr="$(ask 'Gmail address')"
  [[ "$addr" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] || die "not an email address, nothing changed"
  pw="$(ask_secret 'App password (hidden)')"
  pw="${pw// /}"   # Google displays it in groups of four
  valid_value "$pw"
  put SMTP_HOST smtp.gmail.com SMTP_PORT 587 SMTP_SECURITY starttls \
      SMTP_FROM "$addr" SMTP_USERNAME "$addr" SMTP_PASSWORD "$pw"
  unset pw
  echo "smtp: set. Test it: web vault -> Account settings -> send a test / invite." >&2
  apply
}

cmd_smtp_off() {
  drop_keys SMTP_HOST SMTP_PORT SMTP_SECURITY SMTP_FROM SMTP_USERNAME SMTP_PASSWORD
  echo "smtp: removed" >&2; apply
}

cmd_show() {
  local k
  for k in PUSH_ENABLED PUSH_INSTALLATION_ID PUSH_INSTALLATION_KEY ADMIN_TOKEN SMTP_HOST SMTP_USERNAME SMTP_PASSWORD; do
    if grep -qE "^$k=" "$SECRETS"; then echo "$k: set"; else echo "$k: -"; fi
  done
  if grep -qE '^ADMIN_TOKEN=' "$SECRETS"; then
    echo "NOTE: the admin page is ON. Turn it off when done: sudo vw-secrets admin-off"
  fi
}

main() {
  [[ $# -eq 1 ]] || die "usage: vw-secrets push|push-off|admin-on|admin-off|smtp|smtp-off|show"
  if [[ -z "${VW_SECRETS_FILE:-}" && $EUID -ne 0 ]]; then die "run with sudo"; fi
  [[ -f "$SECRETS" ]] || die "$SECRETS is missing - run infra/ansible/vaultwarden.yml first"
  umask 077
  case "$1" in
    push)      cmd_push ;;
    push-off)  cmd_push_off ;;
    admin-on)  cmd_admin_on ;;
    admin-off) cmd_admin_off ;;
    smtp)      cmd_smtp ;;
    smtp-off)  cmd_smtp_off ;;
    show)      cmd_show ;;
    *) die "unknown command '$1'" ;;
  esac
}

main "$@"
