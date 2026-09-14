#!/usr/bin/env bash
# Verify a staged batch against the manifest — Check #1.
# The manifest was generated ON THE PHONE, before any file moved.
set -euo pipefail

ENV_FILE="${TG_ENV_FILE:-/etc/personal-vault/tg-archive.env}"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "FATAL: cannot read $ENV_FILE" >&2
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

DIR="${1:-${STAGING_DIR:?STAGING_DIR not set}}"
MANIFEST="${MANIFEST:?MANIFEST not set}"

log() { echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" >&2; }

[[ -d "$DIR" ]]     ||  { err "no such directory: $DIR"; exit 1; }
[[ -r "$MANIFEST" ]] ||  { err "manifest not readable: $MANIFEST"; exit 1; }

shopt -s nullglob
files=("$DIR"/*.insv)
shopt -u nullglob

if (( ${#files[@]} == 0 )); then
  log "no .insv files in $DIR — nothing to verify"
  exit 0
fi

log "verifying ${#files[@]} file(s) against $(basename "$MANIFEST")"

fail=0
checked=0

for f in "${files[@]}"; do
  base="$(basename "$f")"
  expected="$(awk -v want="$base" '
    { n = $NF; sub(/^\*/, "", n); sub(/.*\//, "", n)
      if (n == want) { print $1; exit } }
  ' "$MANIFEST")"

  if [[ -z "$expected" ]]; then
    err "NOT IN MANIFEST: $base"
    err "  a file arrived that was never fingerprinted"
    fail=1
    continue
  fi

  actual="$(sha256sum "$f" | cut -d' ' -f1)"

  if [[ "$actual" == "$expected" ]]; then
    checked=$((checked + 1))
  else
    err "MISMATCH: $base"
    err "  expected $expected"
    err "  actual   $actual"
    fail=1
  fi
done

if (( fail )); then
  err "verification FAILED — $checked of ${#files[@]} matched"
  err "Do NOT clear the card. Re-sync this batch."
  exit 1
fi

log "verification passed — $checked/${#files[@]} byte-identical"
