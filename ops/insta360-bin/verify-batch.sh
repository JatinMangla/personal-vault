#!/usr/bin/env bash
# Verify a staged batch against the manifest — Check #1.
# The manifest was generated ON THE PHONE, before any file moved.
set -euo pipefail

ENV_FILE="${TG_ENV_FILE:-/etc/personal-vault/tg-archive.env}"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "FATAL: cannot read $ENV_FILE" >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

MANIFEST="${MANIFEST:?MANIFEST not set}"

log() { echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" >&2; }

[[ -r "$MANIFEST" ]] ||  { err "manifest not readable: $MANIFEST"; exit 1; }

# Accept either a DIRECTORY (verify everything staged) or an explicit LIST OF
# FILES (verify exactly these).
#
# The list form exists because tg-upload.sh now splits a large staging
# directory into batches that fit the disk, leaving the remainder staged. With
# only the directory form, Check #1 would re-hash every deferred file on every
# pass - minutes of wasted reads - and, worse, a deferred file that is not yet
# in the manifest would fail the check and abort a batch that was otherwise
# perfectly fine.
#
# One argument that is a directory keeps the old behaviour, so running this by
# hand against STAGING_DIR still works exactly as documented.
files=()
if (( $# == 0 )); then
  DIR="${STAGING_DIR:?STAGING_DIR not set}"
  [[ -d "$DIR" ]] || { err "no such directory: $DIR"; exit 1; }
  shopt -s nullglob
  files=("$DIR"/*.insv)
  shopt -u nullglob
elif (( $# == 1 )) && [[ -d "$1" ]]; then
  DIR="$1"
  shopt -s nullglob
  files=("$DIR"/*.insv)
  shopt -u nullglob
else
  for arg in "$@"; do
    [[ -f "$arg" ]] || { err "no such file: $arg"; exit 1; }
    files+=("$arg")
  done
fi

if (( ${#files[@]} == 0 )); then
  log "no .insv files to verify"
  exit 0
fi

log "verifying ${#files[@]} file(s) against $(basename "$MANIFEST")"

# Publish the hashes computed here, so the ledger write at the end of
# tg-upload.sh does not have to read every file a second time. Same format as
# the manifest ("<sha256>  <basename>"), so the same awk reads both.
#
# Opt-in: only written when the caller sets HASH_FILE. Running this script by
# hand is unaffected. A write failure is NOT fatal - the consumer falls back to
# hashing, so losing this file costs time, never correctness.
hash_out=""
if [[ -n "${HASH_FILE:-}" ]]; then
  if : > "$HASH_FILE" 2>/dev/null; then
    hash_out="$HASH_FILE"
  else
    err "cannot write HASH_FILE=$HASH_FILE - the ledger will re-hash instead"
  fi
fi

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
    # Only VERIFIED hashes are published. A mismatched file must never leave
    # a hash behind for the ledger to trust.
    #
    # `if`, not `[[ ... ]] && printf`: under `set -e` that form makes the loop
    # body exit non-zero on the last iteration whenever hash_out is empty,
    # which would fail a verification that had in fact passed.
    if [[ -n "$hash_out" ]]; then
      printf '%s  %s\n' "$actual" "$base" >> "$hash_out"
    fi
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
