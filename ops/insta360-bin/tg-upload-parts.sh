#!/usr/bin/env bash
# Archive ONE file as parts, each verified by downloading it back. A part that
# keeps failing is RESHAPED - its start moved by a few KiB - so it is stored as
# different 1 MiB blocks. Records the file in the ledger only when every part
# has round-tripped.
#
#   tg-upload-parts.sh /path/to/FILE.insv
#
# WHY THIS EXISTS. On 2026-09-24/25 one 1.32 GB file could not pass Check #2.
# Measured (docs/REVIEW-2026-09-24.md): Telegram stored every byte - its own
# upload.getFileHashes matched - but three 1 MiB blocks were never served, at
# any request size. Two whole-file uploads died at the SAME three blocks; 64 MiB
# parts starting on 1 MiB boundaries died, six rounds running, in exactly the
# three parts holding them. A scrambled copy died at two OTHER blocks. What fits
# all of it: Telegram stores content-addressed 1 MiB blocks, a few stored blocks
# are broken, and any upload containing those exact bytes is matched to the
# broken block again. Re-uploading can never fix a part; changing which bytes
# fall in each 1 MiB block does. Moving a part's start by 4 KiB changes every
# block inside it.
#
# THE RESULT IS AN ORDINARY SPLIT FILE: parts NAME.00, NAME.01, ... in file
# order (sizes may differ), and one ledger row whose fourth column lists the
# part ids in that order. Check #2 and restore.sh rejoin that shape already.
#
# SAFETY, in the order it is enforced:
#   - the file must match its card fingerprint in the manifest
#   - the parts are rejoined and hashed BEFORE any upload, and again after
#     every reshape
#   - takes the drain's session lock, so it cannot run beside a drain
#   - a part counts only when its downloaded copy hashes equal to the local part
#   - the ledger row is written only when ALL parts are good; a partial run
#     records nothing, so tg-prune never deletes a file that is half-archived
#   - never deletes the source file, and never deletes anything from Telegram:
#     failed uploads are LISTED for you to remove (tg-delete-ids.py)
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
MAX_ROUNDS="${MAX_ROUNDS:-8}"
RESHAPE_AFTER="${RESHAPE_AFTER:-2}"   # failures of one part before its start moves
SHIFT_BYTES="${SHIFT_BYTES:-4096}"     # how far; any non-multiple of 1 MiB works

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PIPX_PY="${PIPX_PY:-$HOME/.local/share/pipx/venvs/telegram-upload/bin/python}"
RESOLVER="${TG_RESOLVER:-$HERE/tg-resolve-ids.py}"
PAR_FETCHER="${TG_PAR_FETCHER:-$HERE/tg-fetch-par.py}"
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
  # Wait briefly: the nightly scrub holds the session but steps aside within
  # about a second once something queues for it. A drain does not step aside.
  flock -w "${SESSION_LOCK_WAIT:-30}" 9 \
    || die "the Telegram session is busy (a drain?) - stop it first (systemctl stop tg-archive)"
else
  err "flock unavailable - running without the session lock"
fi

# --- parts are byte ranges [B[k], B[k+1]) --------------------------------------

parts_dir="$(dirname "$FILE")/.parts.$base"
fetch_dir="$parts_dir/.fetch"
cleanup() { rm -rf "$parts_dir"; }
trap cleanup EXIT
rm -rf "$parts_dir"
mkdir -p "$fetch_dir"

part_bytes=$(( PART_MIB * 1048576 ))
n=$(( (size + part_bytes - 1) / part_bytes ))
(( n <= 100 )) || die "more than 100 parts at ${PART_MIB} MiB - raise PART_MIB"

B=()
for (( k = 0; k < n; k++ )); do B+=( $(( k * part_bytes )) ); done
B+=( "$size" )

name_of() { printf '%s.%02d' "$base" "$1"; }

declare -A PART_HASH GOOD_ID FAILS
write_part() {
  local k="$1" p
  p="$(name_of "$k")"
  dd if="$FILE" of="$parts_dir/$p" bs=1M iflag=skip_bytes,count_bytes \
     skip="${B[$k]}" count=$(( B[k + 1] - B[k] )) status=none
  PART_HASH["$p"]="$(sha256sum "$parts_dir/$p" | cut -d' ' -f1)"
}

# Every part concatenated, in order, must BE the original. Checked before the
# first upload and after every reshape, so a boundary bug can never reach the
# ledger.
verify_rejoin() {
  local k got
  got="$(for (( k = 0; k < n; k++ )); do cat "$parts_dir/$(name_of "$k")"; done | sha256sum | cut -d' ' -f1)"
  [[ "$got" == "$expected" ]] || die "parts do not rejoin to the original - refusing"
}

for (( k = 0; k < n; k++ )); do write_part "$k"; FAILS["$k"]=0; done
verify_rejoin
log "split into $n part(s) of up to ${PART_MIB} MiB; rejoin verified"

BAD_IDS=()

# --- upload, fetch back in parallel, verify; reshape parts that keep failing --

for (( round = 1; round <= MAX_ROUNDS; round++ )); do
  pending=()
  for (( k = 0; k < n; k++ )); do
    [[ -n "${GOOD_ID[$(name_of "$k")]:-}" ]] || pending+=("$k")
  done
  (( ${#pending[@]} )) || break
  log "round $round: ${#pending[@]} part(s) to upload"

  names=()
  for k in "${pending[@]}"; do
    p="$(name_of "$k")"
    names+=("$p")
    "$UPLOAD_CMD" --to "$TG_CHANNEL" --config "$TG_CONFIG" --no-thumbnail \
      "$parts_dir/$p" >/dev/null 2>&1 || err "upload of $p failed - will retry"
  done

  resolved="$("$PIPX_PY" "$RESOLVER" --config "$TG_CONFIG" --channel "$TG_CHANNEL" \
               "${names[@]}")" || err "resolver exited non-zero - using what it printed"

  declare -A NEW_ID=()
  while IFS=$'\t' read -r rname rid; do
    if [[ -n "$rname" && -n "$rid" ]]; then
      NEW_ID["$rname"]="${rid%% *}"
    fi
  done <<< "$resolved"

  # One parallel fetch for the whole round. tg-fetch-par.py moves a file into
  # place only once it is complete, so a part that died on a dead block is
  # simply absent - and every present one is still hashed below.
  ids=()
  for p in "${names[@]}"; do
    if [[ -n "${NEW_ID[$p]:-}" ]]; then ids+=("${NEW_ID[$p]}"); fi
  done
  find "$fetch_dir" -mindepth 1 -delete
  if (( ${#ids[@]} )); then
    "$PIPX_PY" "$PAR_FETCHER" --config "$TG_CONFIG" --channel "$TG_CHANNEL" \
      --into "$fetch_dir" "${ids[@]}" >/dev/null 2>&1 || true
  fi

  for k in "${pending[@]}"; do
    p="$(name_of "$k")"
    id="${NEW_ID[$p]:-}"
    if [[ -n "$id" && -f "$fetch_dir/$p" ]] \
       && [[ "$(sha256sum "$fetch_dir/$p" | cut -d' ' -f1)" == "${PART_HASH[$p]}" ]]; then
      GOOD_ID["$p"]="$id"
      log "  $p -> message $id verified"
      continue
    fi
    if [[ -n "$id" ]]; then BAD_IDS+=("$id"); fi
    FAILS["$k"]=$(( FAILS[$k] + 1 ))
    err "  $p -> ${id:+message $id }did not come back intact (failure ${FAILS[$k]})"
  done
  unset NEW_ID

  # Reshape: a part that failed RESHAPE_AFTER times moves its start forward by
  # SHIFT_BYTES, so every 1 MiB block inside it holds different bytes. Its
  # neighbour before it grows by the same amount; both are rewritten and must
  # verify again. Part 0 cannot move its start - it only gets retried.
  reshaped=0
  for k in "${pending[@]}"; do
    if (( k > 0 && FAILS[$k] >= RESHAPE_AFTER )); then
      B[k]=$(( B[k] + SHIFT_BYTES ))
      (( B[k] < B[k + 1] )) || die "part $(name_of "$k") shrank to nothing - refusing"
      for j in $(( k - 1 )) "$k"; do
        write_part "$j"
        unset "GOOD_ID[$(name_of "$j")]"
      done
      FAILS["$k"]=0
      reshaped=1
      log "  reshaped $(name_of "$k"): now starts at byte ${B[$k]}; $(name_of $(( k - 1 ))) redone too"
    fi
  done
  if (( reshaped )); then verify_rejoin; fi
done

missing=()
for (( k = 0; k < n; k++ )); do
  [[ -n "${GOOD_ID[$(name_of "$k")]:-}" ]] || missing+=("$(name_of "$k")")
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
for (( k = 0; k < n; k++ )); do ids+=("${GOOD_ID[$(name_of "$k")]}"); done
printf '%s %s %s %s\n' "$expected" "$base" "$size" "${ids[*]}" >> "$UPLOADED_LOG"
log "ALL $n part(s) verified. Recorded $base in the ledger: ${ids[*]}"
log "The original is untouched; it may now be removed like any archived file."
