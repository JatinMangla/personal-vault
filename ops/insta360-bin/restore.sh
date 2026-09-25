#!/usr/bin/env bash
#
# restore.sh - pull .insv files back out of the Telegram archive.
#
# THIS IS THE HALF THAT MATTERS IN A YEAR. Everything else in this directory
# writes to the archive; this is the only thing that reads from it. An archive
# nobody has restored from is a hypothesis, not a backup.
#
#   restore.sh --list                        what is in the archive
#   restore.sh --dry-run --into ~/recovered  what would be restored
#   restore.sh --into ~/recovered            restore everything
#   restore.sh --into ~/recovered VID_001.insv VID_002.insv
#
# DESIGNED TO RUN ON A MACHINE THAT IS NOT THE VM.
# The point of a restore is that the VM is gone. So this does not require
# /etc/personal-vault/tg-archive.env, does not assume /mnt/media exists, and
# does not need Syncthing, Immich or systemd. It needs Python with
# telegram-upload (which brings Telethon), a telegram-upload config JSON, the
# channel id - and, ideally, the LEDGER.
#
# TWO WAYS TO FETCH, chosen automatically:
#
#   BY LEDGER ID (default when uploaded.sha256 is available). The ledger records
#   every archived file's card hash, size and message id(s). Only those
#   messages are fetched, 4 at a time with tg-fetch-par.py, in groups of about
#   RESTORE_GROUP_GB so scratch space stays bounded. --list and --dry-run need
#   no network at all. Every file is verified against the card hash in the
#   ledger, so no separate manifest is needed. Rows from before ids were
#   recorded are looked up by name with tg-resolve-ids.py.
#
#   WHOLE CHANNEL (no ledger, or --whole-channel). telegram-download pulls the
#   entire chat and files are picked out locally. It works with nothing but a
#   config and a channel id, but it downloads everything, sequentially, into
#   scratch - and a single message Telegram refuses to serve stalls it.
#
#   Where the ledger lives: /var/lib/insta360-archive/work/uploaded.sha256 on
#   the VM; a copy in the nightly restic backup (since 2026-09-24); and any
#   copy you scp'd off (docs/RUNBOOK.md). Pass it with --ledger.
#
# WHAT IT WILL NOT DO
#   - delete anything, ever
#   - overwrite an existing file (it refuses and moves on)
#   - report success for a file it could not verify
#
# ON VERIFICATION. A restore is trustworthy only against the sha256 each file
# had ON THE CARD, before anything moved. The ledger carries it (column 1);
# so does the manifest, which wins if both are given. With neither, files still
# come back but the result is reported as UNVERIFIED - a deliberately distinct
# word, the same way ops/RESTORE-LOG.md says PASS (DB-ONLY) rather than PASS. A
# partial result must never be mistakable for a full one.
#
# A copy of the manifest is uploaded to the channel by tg-upload.sh after each
# batch, named manifest-<timestamp>.sha256, so it is usually recoverable from
# the archive itself.

set -euo pipefail

# --- configuration ---------------------------------------------------------
#
# Every value can come from a flag, the environment, or the VM env file if it
# happens to be present. Flags win, so a recovery machine needs no files.

ENV_FILE="${TG_ENV_FILE:-/etc/personal-vault/tg-archive.env}"
if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
fi

DEST=""
MANIFEST_ARG=""
LEDGER_ARG=""
DRY_RUN=0
LIST_ONLY=0
KEEP_PARTS=0
WHOLE_CHANNEL=0
declare -a WANTED=()

log()  { echo "[$(date -Is)] $*"; }
err()  { echo "[$(date -Is)] ERROR: $*" >&2; }
note() { echo "                      $*"; }

usage() {
  cat <<'USAGE'
restore.sh - pull .insv files back out of the Telegram archive

  --into DIR          where to write recovered files (required unless --list)
  --ledger FILE       uploaded.sha256: fetch by message id and verify against it
                      (default: the VM's ledger, if present)
  --manifest FILE     sha256 manifest to verify against (wins over the ledger)
  --whole-channel     ignore the ledger and download the entire channel
  --channel ID        Telegram channel (default: $TG_CHANNEL)
  --config FILE       telegram-upload config JSON (default: $TG_CONFIG)
  --list              show what is in the archive, restore nothing
  --dry-run           show what would be restored, write nothing
  --keep-parts        keep the raw split parts after rejoining them
  -h, --help          this

  Any remaining arguments are filenames to restore. With none, everything is
  restored.

Examples
  restore.sh --list
  restore.sh --into ~/recovered --ledger ~/uploaded.sha256
  restore.sh --into ~/recovered VID_20260914_001.insv
USAGE
}

while (( $# )); do
  case "$1" in
    --into)     DEST="${2:?--into needs a directory}"; shift 2 ;;
    --manifest) MANIFEST_ARG="${2:?--manifest needs a file}"; shift 2 ;;
    --ledger)   LEDGER_ARG="${2:?--ledger needs a file}"; shift 2 ;;
    --whole-channel) WHOLE_CHANNEL=1; shift ;;
    --channel)  TG_CHANNEL="${2:?--channel needs an id}"; shift 2 ;;
    --config)   TG_CONFIG="${2:?--config needs a file}"; shift 2 ;;
    --list)     LIST_ONLY=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --keep-parts) KEEP_PARTS=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         err "unknown option: $1"; usage >&2; exit 2 ;;
    *)          WANTED+=("$1"); shift ;;
  esac
done

TG_CHANNEL="${TG_CHANNEL:-}"
TG_CONFIG="${TG_CONFIG:-}"
MANIFEST="${MANIFEST_ARG:-${MANIFEST:-}}"
LEDGER="${LEDGER_ARG:-${TG_LEDGER:-${WORK_DIR:-/var/lib/insta360-archive/work}/uploaded.sha256}}"
GROUP_BYTES="${RESTORE_GROUP_BYTES:-$(( ${RESTORE_GROUP_GB:-20} * 1024 * 1024 * 1024 ))}"

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PIPX_PY="${PIPX_PY:-$HOME/.local/share/pipx/venvs/telegram-upload/bin/python}"
[[ -x "$PIPX_PY" ]] || PIPX_PY="$(command -v python3 || echo python3)"
PAR_FETCHER="${TG_PAR_FETCHER:-$HERE/tg-fetch-par.py}"
RESOLVER="${TG_RESOLVER:-$HERE/tg-resolve-ids.py}"

MODE=channel
if (( ! WHOLE_CHANNEL )) && [[ -r "$LEDGER" ]]; then
  MODE=ledger
elif [[ -n "$LEDGER_ARG" ]] && (( ! WHOLE_CHANNEL )); then
  err "ledger not readable: $LEDGER_ARG"; exit 2
fi

need_telegram() {
  [[ -n "$TG_CHANNEL" ]] || { err "no channel: pass --channel or set TG_CHANNEL"; exit 2; }
  [[ -n "$TG_CONFIG"  ]] || { err "no config: pass --config or set TG_CONFIG"; exit 2; }
  [[ -r "$TG_CONFIG"  ]] || { err "config not readable: $TG_CONFIG"; exit 2; }

  # On the VM the Telegram session is shared, and admits one process at a time
  # ("database is locked" otherwise - hit on 2026-09-25 while the scrub ran).
  # Queue for it like every other tool: the nightly scrub sees the queue in
  # /proc/locks and steps aside within about a second. Elsewhere there is no
  # lock file and nothing to wait for.
  local lk="${WORK_DIR:-/var/lib/insta360-archive/work}/.session.lock"
  if [[ -e "$lk" ]] && command -v flock >/dev/null 2>&1; then
    exec 9>"$lk"
    if ! flock -w "${SESSION_LOCK_WAIT:-60}" 9; then
      err "the Telegram session is busy - a drain or an upload is running"
      note "try again when it finishes: tg-archive status"
      exit 1
    fi
  fi
}

if (( ! LIST_ONLY )); then
  [[ -n "$DEST" ]] || { err "no destination: pass --into DIR"; exit 2; }
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/restore.XXXXXX")"
cleanup() {
  if (( KEEP_PARTS )); then
    log "raw download kept at: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

declare -A BASES=() LEDGER_IDS=() LEDGER_HASH=() LEDGER_SIZE=()

if [[ "$MODE" == ledger ]]; then
  # --- what is archived: read from the ledger, no network --------------------
  #
  # Columns: card sha256, name, size, then message id(s) - "-" or absent when
  # unknown (rows from before 2026-09-16). A name that appears twice keeps its
  # LAST row, the most recent record of it.
  log "archive contents from the ledger: $LEDGER"
  while read -r l_hash l_name l_size l_rest; do
    [[ -n "${l_name:-}" ]] || continue
    BASES["$l_name"]=1
    LEDGER_HASH["$l_name"]="$l_hash"
    LEDGER_SIZE["$l_name"]="${l_size:-0}"
    l_ids=""
    for tok in ${l_rest:-}; do
      if [[ "$tok" =~ ^[0-9]+$ ]]; then l_ids+=" $tok"; fi
    done
    LEDGER_IDS["$l_name"]="${l_ids# }"
  done < "$LEDGER"
  (( ${#BASES[@]} )) || { err "the ledger lists no files: $LEDGER"; exit 1; }
else
  # --- fetch: the whole channel ----------------------------------------------
  #
  # telegram-download has no filename filter - it takes the whole chat, so
  # filtering happens locally, after the fetch. Used only without a ledger.
  need_telegram
  command -v telegram-download >/dev/null || {
    err "telegram-download not found"
    note "install with: pipx install telegram-upload"
    note "on Python 3.12 see docs/RUNBOOK.md - distutils was removed and the"
    note "package needs a patch. NEVER run 'pipx upgrade telegram-upload'."
    exit 2
  }
  log "fetching from channel $TG_CHANNEL"
  log "no ledger - this pulls the WHOLE channel; it can take a long time"
  if ! ( cd "$WORK" && telegram-download --from "$TG_CHANNEL" --config "$TG_CONFIG" -m keep ); then
    err "download failed - nothing was written to the destination"
    exit 1
  fi

  shopt -s nullglob
  downloaded=("$WORK"/*)
  shopt -u nullglob
  if (( ${#downloaded[@]} == 0 )); then
    err "the channel returned no files"
    note "check the channel id, and that this account can read it"
    exit 1
  fi
  log "fetched ${#downloaded[@]} object(s)"

  # telegram-upload splits large files into NAME.00, NAME.01, ...
  for f in "${downloaded[@]}"; do
    b="$(basename "$f")"
    if [[ "$b" =~ ^(.+)\.[0-9]{2,}$ ]]; then
      BASES["${BASH_REMATCH[1]}"]=1
    else
      BASES["$b"]=1
    fi
  done
fi

if (( LIST_ONLY )); then
  log "in the archive ($MODE):"
  for b in "${!BASES[@]}"; do printf '  %s\n' "$b"; done | sort
  exit 0
fi

# Which ones did the caller ask for?
declare -a TARGETS=()
if (( ${#WANTED[@]} )); then
  for w in "${WANTED[@]}"; do
    if [[ -n "${BASES[$w]:-}" ]]; then
      TARGETS+=("$w")
    else
      err "not in the archive: $w"
    fi
  done
  (( ${#TARGETS[@]} )) || { err "none of the requested files are in the archive"; exit 1; }
else
  # Exclude the manifest copies tg-upload.sh posts after each batch. They are
  # archive metadata, not card content: no manifest lists itself, so they can
  # never verify, and counting them as UNVERIFIED would make every otherwise
  # perfect restore report UNVERIFIED. Still restorable by naming one
  # explicitly - which is exactly how you recover a manifest you have lost.
  mapfile -t TARGETS < <(
    printf '%s\n' "${!BASES[@]}" | grep -v '^manifest-.*\.sha256$' | sort
  )
  if (( ${#TARGETS[@]} == 0 )); then
    err "the archive holds only manifest copies - no .insv files to restore"
    note "name one explicitly to recover it: restore.sh --into DIR manifest-....sha256"
    exit 1
  fi
fi

if (( DRY_RUN )); then
  log "dry run - would restore ${#TARGETS[@]} file(s) into $DEST ($MODE):"
  for t in "${TARGETS[@]}"; do printf '  %s\n' "$t"; done
  exit 0
fi

mkdir -p "$DEST"

# --- restore and verify ----------------------------------------------------

restored=0
verified=0
unverified=0
skipped=0
failed=0

have_manifest=0
if [[ -n "$MANIFEST" && -r "$MANIFEST" ]]; then
  have_manifest=1
  log "verifying against $(basename "$MANIFEST")"
elif [[ "$MODE" == ledger ]]; then
  log "verifying against the card hashes in the ledger"
else
  err "NO MANIFEST - files will be restored but NOT verified"
  note "pass --ledger or --manifest, or recover a manifest from the channel"
fi

# The card hash for one file: the manifest wins, then the ledger, else empty.
expected_hash() {
  local base="$1" h=""
  if (( have_manifest )); then
    h="$(awk -v want="$base" '
      { n = $NF; sub(/^\*/, "", n); sub(/.*\//, "", n)
        if (n == want) { print $1; exit } }' "$MANIFEST")"
  fi
  if [[ -z "$h" && "$MODE" == ledger ]]; then h="${LEDGER_HASH[$base]:-}"; fi
  printf '%s' "$h"
}

# Rejoin (or copy) one file out of $WORK into $DEST, then verify it.
restore_one() {
  local base="$1" out="$DEST/$1" parts sorted expected actual

  # Never clobber. A restore that silently overwrites a file someone already
  # recovered is worse than one that stops and says so.
  if [[ -e "$out" ]]; then
    err "exists already, skipping: $out"
    skipped=$(( skipped + 1 ))
    return
  fi

  # Rejoining in numeric order is the same logic Check #2 uses; lexical order
  # would corrupt anything with more than ten parts (.10 sorting before .2).
  shopt -s nullglob
  parts=("$WORK/$base".[0-9][0-9]*)
  shopt -u nullglob

  if (( ${#parts[@]} > 0 )); then
    mapfile -t sorted < <(
      for p in "${parts[@]}"; do printf '%s\t%s\n' "${p##*.}" "$p"; done |
        sort -n -k1,1 | cut -f2
    )
    log "rejoining ${#sorted[@]} part(s) -> $base"
    cat "${sorted[@]}" > "$out"
  elif [[ -f "$WORK/$base" ]]; then
    cp "$WORK/$base" "$out"
  else
    err "$base: neither a whole file nor any parts were fetched"
    failed=$(( failed + 1 ))
    return
  fi

  restored=$(( restored + 1 ))

  expected="$(expected_hash "$base")"
  if [[ -z "$expected" ]]; then
    if (( have_manifest )); then
      err "$base: not listed in the manifest - cannot verify"
    fi
    unverified=$(( unverified + 1 ))
    return
  fi

  actual="$(sha256sum "$out" | cut -d' ' -f1)"
  if [[ "$actual" == "$expected" ]]; then
    log "  verified: $base"
    verified=$(( verified + 1 ))
  else
    err "HASH MISMATCH: $base"
    err "  expected $expected"
    err "  actual   $actual"
    err "  the restored file is at $out - inspect it, do not trust it"
    failed=$(( failed + 1 ))
  fi
}

if [[ "$MODE" == channel ]]; then
  for base in "${TARGETS[@]}"; do restore_one "$base"; done
else
  need_telegram

  # Rows with no recorded ids: ask Telegram by name, newest copy of each part.
  declare -a NO_IDS=()
  for t in "${TARGETS[@]}"; do
    if [[ -z "${LEDGER_IDS[$t]}" ]]; then NO_IDS+=("$t"); fi
  done
  if (( ${#NO_IDS[@]} )); then
    log "looking up ${#NO_IDS[@]} file(s) the ledger has no message id for"
    while IFS=$'\t' read -r rname rids; do
      if [[ -n "$rname" && -n "$rids" ]]; then LEDGER_IDS["$rname"]="$rids"; fi
    done < <("$PIPX_PY" "$RESOLVER" --config "$TG_CONFIG" --channel "$TG_CHANNEL" \
               --limit 100000 "${NO_IDS[@]}" || true)
  fi

  # Groups of about GROUP_BYTES: fetched in parallel, restored, then cleared,
  # so scratch never holds more than one group however large the archive.
  total=${#TARGETS[@]}
  i=0
  while (( i < total )); do
    group=()
    ids=()
    bytes=0
    while (( i < total )); do
      t="${TARGETS[$i]}"
      sz="${LEDGER_SIZE[$t]:-0}"
      if (( ${#group[@]} > 0 && bytes + sz > GROUP_BYTES )); then break; fi
      group+=("$t")
      bytes=$(( bytes + sz ))
      for id in ${LEDGER_IDS[$t]}; do ids+=("$id"); done
      i=$(( i + 1 ))
    done

    if (( ${#ids[@]} )); then
      log "fetching ${#group[@]} file(s), $(( bytes / 1048576 )) MiB, by message id ($i of $total)"
      "$PIPX_PY" "$PAR_FETCHER" --config "$TG_CONFIG" --channel "$TG_CHANNEL" \
        --into "$WORK" "${ids[@]}" \
        || err "some messages could not be fetched - those files are reported below"
    fi

    for t in "${group[@]}"; do
      if [[ -z "${LEDGER_IDS[$t]}" ]]; then
        err "$t: no message found in the channel"
        failed=$(( failed + 1 ))
        continue
      fi
      restore_one "$t"
    done

    if (( ! KEEP_PARTS )); then find "$WORK" -mindepth 1 -delete; fi
  done
fi

# --- result ----------------------------------------------------------------

echo
log "restored to: $DEST"
log "  files written : $restored"
if (( verified ));   then log "  verified      : $verified"; fi
if (( unverified )); then log "  UNVERIFIED    : $unverified"; fi
if (( skipped ));    then log "  skipped       : $skipped (already existed)"; fi
if (( failed ));     then err "  FAILED        : $failed"; fi

if (( failed )); then
  err "RESULT: FAIL - $failed file(s) did not restore intact"
  exit 1
fi

# Nothing written at all. Usually a re-run into a directory that already holds
# the files: everything is skipped, nothing fails, and without this the script
# would print PASS having checked precisely zero bytes. ops/RESTORE-LOG.md
# exists because that class of false result is worse than no result at all.
#
# Note this tests `restored`, NOT `verified`. Keying it on verification would
# report "nothing restored" for every successful restore made without a
# manifest - which is the normal case on a recovery machine, and the exact
# situation this script exists for.
if (( restored == 0 )); then
  if (( skipped )); then
    log "RESULT: NOTHING DONE - all $skipped file(s) already existed"
    log "  Nothing was verified, because nothing was restored. This is not a"
    log "  pass. Restore into an empty directory to actually test the archive."
  else
    log "RESULT: NOTHING RESTORED"
  fi
  exit 0
fi

if (( unverified )); then
  log "RESULT: RESTORED (UNVERIFIED)"
  log "  $verified file(s) verified, $unverified NOT checked against a card hash."
  log "  A partial result, deliberately not called a pass. Pass --ledger or"
  log "  --manifest and re-run to turn this into a real one."
  exit 0
fi

log "RESULT: PASS - $verified file(s) restored and byte-identical to the card"
