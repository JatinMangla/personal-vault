#!/usr/bin/env bash
# Archive ONE file as small parts, each verified by downloading it back, and
# re-upload only the parts that fail. Records the file in the ledger only when
# every part has round-tripped.
#
#   tg-upload-parts.sh /path/to/FILE.insv
#
# WHY THIS EXISTS. On 2026-09-24/25 one 1.32 GB file could not pass Check #2:
# every whole-file upload of it landed with 2-3 dead 1 MiB blocks on Telegram's
# DC 5 - stored intact (upload.getFileHashes matched every range) but never
# served back, at any request size. Different uploads died at different
# blocks, so re-uploading the whole file had roughly an 8% chance of coming
# back clean. A 64 MiB part has roughly 88%, and a bad part is cheap to redo.
# Details: docs/REVIEW-2026-09-24.md.
#
# THE RESULT IS AN ORDINARY SPLIT FILE: parts NAME.00, NAME.01, ... exactly
# like telegram-upload's own split of a >2 GB file, and one ledger row whose
# fourth column lists the part ids in order. Check #2 and restore.sh already
# rejoin that shape in numeric order, so nothing downstream changes.
#
# SAFETY, in the order it is enforced:
#   - the file must match its card fingerprint in the manifest, so the ledger
#     row this writes is true of the original on the card
#   - the parts are rejoined and hashed BEFORE any upload
#   - takes the drain's session lock, so it cannot run beside a drain
#   - a part counts only when its downloaded copy hashes equal to the local part
#   - the ledger row is written only when ALL parts are good; a partial run
#     records nothing, so tg-prune never deletes a file that is half-archived
#   - never deletes the source file, and never deletes anything from Telegram:
#     failed uploads are LISTED for you to remove
set -euo pipefail

ENV_FILE="${TG_ENV_FILE:-/etc/personal-vault/tg-archive.env}"
[[ -r "$ENV_FILE" ]] || { echo "FATAL: cannot read $ENV_FILE" >&2; exit 2; }
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

TG_CHANNEL="${TG_CHANNEL:?TG_CHANNEL not set}"
MANIFEST="${MANIFEST:?MANIFEST not set}"
WORK_DIR="${WORK_DIR:-/var/lib/insta360-archive/work}"
TG_CONFIG="${TG_CONFIG:-/var/lib/insta360-archive/telegram-upload.json}"
PART_MIB="${PART_MIB:-64}"
MAX_ROUNDS="${MAX_ROUNDS:-6}"

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PIPX_PY="${PIPX_PY:-$HOME/.local/share/pipx/venvs/telegram-upload/bin/python}"
RESOLVER="${TG_RESOLVER:-$HERE/tg-resolve-ids.py}"
FETCHER="${TG_FETCHER:-$HERE/tg-fetch-ids.py}"
UPLOAD_CMD="${TG_UPLOAD_CMD:-telegram-upload}"
UPLOADED_LOG="$WORK_DIR/uploaded.sha256"

log() { echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" >&2; }
die() { err "$*"; exit 1; }

FILE="${1:-}"
[[ -n "$FILE" && -f "$FILE" ]] || die "usage: $(basename "$0") /path/to/FILE.insv"
base="$(basename "$FILE")"
size="$(stat -c %s "$FILE")"

# --- the file must be what the card holds ----------------------------------

if [[ -r "$UPLOADED_LOG" ]] && awk -v n="$base" '$2 == n { found = 1 } END { exit !found }' "$UPLOADED_LOG"; then
  die "$base is already in the ledger - nothing to do"
fi

expected="$(awk -v want="$base" '{ n = $NF; sub(/^\*/, "", n); sub(/.*\//, "", n)
                                   if (n == want) { print $1; exit } }' "$MANIFEST")"
[[ -n "$expected" ]] || die "$base is not in the manifest - it was never fingerprinted from the card"

log "hashing $base ($(( size / 1048576 )) MiB) against its card fingerprint"
actual="$(sha256sum "$FILE" | cut -d' ' -f1)"
[[ "$actual" == "$expected" ]] || die "$base does not match its fingerprint (manifest $expected, file $actual)"

# --- one Telegram session at a time -----------------------------------------

mkdir -p "$WORK_DIR"
# Same lock and same rule as tg-upload.sh: guard only where flock exists
# (Ubuntu ships it), and say so plainly where it does not.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$WORK_DIR/.session.lock"
  flock -n 9 || die "a drain holds the Telegram session - stop it first (systemctl stop tg-archive)"
else
  err "flock unavailable - running without the session lock"
fi

# --- split, and prove the parts rejoin to the original -----------------------

parts_dir="$(dirname "$FILE")/.parts.$base"
fetch_dir="$parts_dir/.fetch"
cleanup() { rm -rf "$parts_dir"; }
trap cleanup EXIT
rm -rf "$parts_dir"
mkdir -p "$fetch_dir"

part_bytes=$(( PART_MIB * 1048576 ))
(( (size + part_bytes - 1) / part_bytes <= 100 )) \
  || die "more than 100 parts at ${PART_MIB} MiB - raise PART_MIB"
split -b "$part_bytes" -d -a 2 "$FILE" "$parts_dir/$base."

# Suffixes are always exactly two digits (split -a 2), so plain sorting IS
# numeric order: .09 before .10. No numeric sort to get wrong.
mapfile -t parts < <(cd "$parts_dir" && ls -1 -- "$base".[0-9][0-9] | LC_ALL=C sort)
rejoined="$(cd "$parts_dir" && cat "${parts[@]}" | sha256sum | cut -d' ' -f1)"
[[ "$rejoined" == "$expected" ]] || die "split parts do not rejoin to the original - refusing"
log "split into ${#parts[@]} part(s) of up to ${PART_MIB} MiB; rejoin verified"

declare -A PART_HASH GOOD_ID
for p in "${parts[@]}"; do
  PART_HASH["$p"]="$(sha256sum "$parts_dir/$p" | cut -d' ' -f1)"
done
BAD_IDS=()

# --- upload, fetch back, verify; redo only the parts that fail ---------------

for (( round = 1; round <= MAX_ROUNDS; round++ )); do
  pending=()
  for p in "${parts[@]}"; do
    [[ -n "${GOOD_ID[$p]:-}" ]] || pending+=("$p")
  done
  (( ${#pending[@]} )) || break
  log "round $round: ${#pending[@]} part(s) to upload"

  for p in "${pending[@]}"; do
    "$UPLOAD_CMD" --to "$TG_CHANNEL" --config "$TG_CONFIG" --no-thumbnail \
      "$parts_dir/$p" >/dev/null 2>&1 || err "upload of $p failed - will retry"
  done

  resolved="$("$PIPX_PY" "$RESOLVER" --config "$TG_CONFIG" --channel "$TG_CHANNEL" \
               "${pending[@]}")" || err "resolver exited non-zero - using what it printed"

  declare -A NEW_ID=()
  while IFS=$'\t' read -r rname rid; do
    if [[ -n "$rname" && -n "$rid" ]]; then
      NEW_ID["$rname"]="${rid%% *}"
    fi
  done <<< "$resolved"

  for p in "${pending[@]}"; do
    id="${NEW_ID[$p]:-}"
    if [[ -z "$id" ]]; then
      err "  $p: no message id found - will retry"
      continue
    fi
    find "$fetch_dir" -mindepth 1 -delete
    if "$PIPX_PY" "$FETCHER" --config "$TG_CONFIG" --channel "$TG_CHANNEL" \
         --into "$fetch_dir" "$id" >/dev/null 2>&1 \
       && [[ -f "$fetch_dir/$p" ]] \
       && [[ "$(sha256sum "$fetch_dir/$p" | cut -d' ' -f1)" == "${PART_HASH[$p]}" ]]; then
      GOOD_ID["$p"]="$id"
      log "  $p -> message $id verified"
    else
      BAD_IDS+=("$id")
      err "  $p -> message $id did not come back intact - will re-upload"
    fi
  done
  unset NEW_ID
done

missing=()
for p in "${parts[@]}"; do
  [[ -n "${GOOD_ID[$p]:-}" ]] || missing+=("$p")
done

if (( ${#BAD_IDS[@]} )); then
  log "messages that did NOT verify (safe to delete from the channel): ${BAD_IDS[*]}"
fi

if (( ${#missing[@]} )); then
  err "${#missing[@]} part(s) never verified after $MAX_ROUNDS round(s): ${missing[*]}"
  err "NOTHING recorded in the ledger. $base stays unarchived; keep it on the card."
  exit 1
fi

# --- every part verified: record the file, ids in part order ----------------

ids=()
for p in "${parts[@]}"; do ids+=("${GOOD_ID[$p]}"); done
printf '%s %s %s %s\n' "$expected" "$base" "$size" "${ids[*]}" >> "$UPLOADED_LOG"
log "ALL ${#parts[@]} part(s) verified. Recorded $base in the ledger: ${ids[*]}"
log "The original is untouched; it may now be removed like any archived file."
