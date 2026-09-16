#!/usr/bin/env bash
#
# restore.sh - pull .insv files back out of the Telegram archive.
#
# THIS IS THE HALF THAT MATTERS IN A YEAR. Everything else in this directory
# writes to the archive; this is the only thing that reads from it. An archive
# nobody has restored from is a hypothesis, not a backup.
#
#   restore.sh --list                        what is in the channel
#   restore.sh --dry-run --into ~/recovered  what would be restored
#   restore.sh --into ~/recovered            restore everything
#   restore.sh --into ~/recovered VID_001.insv VID_002.insv
#
# DESIGNED TO RUN ON A MACHINE THAT IS NOT THE VM.
# The point of a restore is that the VM is gone. So this does not require
# /etc/personal-vault/tg-archive.env, does not assume /mnt/media exists, and
# does not need Syncthing, Immich or systemd. It needs Python with
# telegram-download, a telegram-upload config JSON, and the channel id.
#
# WHAT IT WILL NOT DO
#   - delete anything, ever
#   - overwrite an existing file (it refuses and moves on)
#   - report success for a file it could not verify
#
# ON VERIFICATION. The manifest is what makes a restore trustworthy: it is the
# sha256 of every file as it was ON THE CARD, before anything moved. If you
# have it, every restored file is checked against it. If you do not, the files
# still come back but the result is reported as UNVERIFIED - a deliberately
# distinct word, the same way ops/RESTORE-LOG.md says PASS (DB-ONLY) rather
# than PASS. A partial result must never be mistakable for a full one.
#
# A copy of the manifest is uploaded to the channel by tg-upload.sh after each
# batch, named manifest-<timestamp>.sha256, so it is usually recoverable from
# the archive itself. --list will show them.

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
DRY_RUN=0
LIST_ONLY=0
KEEP_PARTS=0
declare -a WANTED=()

log()  { echo "[$(date -Is)] $*"; }
err()  { echo "[$(date -Is)] ERROR: $*" >&2; }
note() { echo "                      $*"; }

usage() {
  cat <<'USAGE'
restore.sh - pull .insv files back out of the Telegram archive

  --into DIR          where to write recovered files (required unless --list)
  --manifest FILE     sha256 manifest to verify against (strongly recommended)
  --channel ID        Telegram channel (default: $TG_CHANNEL)
  --config FILE       telegram-upload config JSON (default: $TG_CONFIG)
  --list              show what is in the channel, restore nothing
  --dry-run           show what would be restored, write nothing
  --keep-parts        keep the raw split parts after rejoining them
  -h, --help          this

  Any remaining arguments are filenames to restore. With none, everything
  found in the channel is restored.

Examples
  restore.sh --list
  restore.sh --into ~/recovered --manifest ~/card.sha256
  restore.sh --into ~/recovered VID_20260914_001.insv
USAGE
}

while (( $# )); do
  case "$1" in
    --into)     DEST="${2:?--into needs a directory}"; shift 2 ;;
    --manifest) MANIFEST_ARG="${2:?--manifest needs a file}"; shift 2 ;;
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

[[ -n "$TG_CHANNEL" ]] || { err "no channel: pass --channel or set TG_CHANNEL"; exit 2; }
[[ -n "$TG_CONFIG"  ]] || { err "no config: pass --config or set TG_CONFIG"; exit 2; }
[[ -r "$TG_CONFIG"  ]] || { err "config not readable: $TG_CONFIG"; exit 2; }

command -v telegram-download >/dev/null || {
  err "telegram-download not found"
  note "install with: pipx install telegram-upload"
  note "on Python 3.12 see docs/RUNBOOK.md - distutils was removed and the"
  note "package needs a patch. NEVER run 'pipx upgrade telegram-upload'."
  exit 2
}

if (( ! LIST_ONLY )); then
  [[ -n "$DEST" ]] || { err "no destination: pass --into DIR"; exit 2; }
fi

# --- fetch -----------------------------------------------------------------
#
# telegram-download has no filename filter - it takes the whole chat. That is
# the same limitation that makes tg-upload.sh's Check #2 expensive, and it is
# why filtering happens locally, after the fetch. For a restore this is a fair
# trade: it happens once, and completeness matters more than bandwidth.

WORK="$(mktemp -d "${TMPDIR:-/tmp}/restore.XXXXXX")"
cleanup() {
  if (( KEEP_PARTS )); then
    log "raw download kept at: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

log "fetching from channel $TG_CHANNEL"
log "this pulls the whole channel; it can take a long time"

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

# --- rejoin split parts ----------------------------------------------------
#
# telegram-upload splits large files into NAME.00, NAME.01, ... Rejoining in
# numeric order is the same logic Check #2 uses; lexical order would corrupt
# anything with more than ten parts (.10 sorting before .2).

declare -A BASES=()
for f in "${downloaded[@]}"; do
  b="$(basename "$f")"
  if [[ "$b" =~ ^(.+)\.[0-9]{2,}$ ]]; then
    BASES["${BASH_REMATCH[1]}"]=1
  else
    BASES["$b"]=1
  fi
done

if (( LIST_ONLY )); then
  log "in the channel:"
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
      err "not in the channel: $w"
    fi
  done
  (( ${#TARGETS[@]} )) || { err "none of the requested files are in the channel"; exit 1; }
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
    err "the channel holds only manifest copies - no .insv files to restore"
    note "name one explicitly to recover it: restore.sh --into DIR manifest-....sha256"
    exit 1
  fi
fi

if (( DRY_RUN )); then
  log "dry run - would restore ${#TARGETS[@]} file(s) into $DEST:"
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
else
  err "NO MANIFEST - files will be restored but NOT verified"
  note "pass --manifest, or recover one from the channel (--list shows them)"
fi

for base in "${TARGETS[@]}"; do
  out="$DEST/$base"

  # Never clobber. A restore that silently overwrites a file someone already
  # recovered is worse than one that stops and says so.
  if [[ -e "$out" ]]; then
    err "exists already, skipping: $out"
    skipped=$(( skipped + 1 ))
    continue
  fi

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
    err "$base: neither a whole file nor any parts were found"
    failed=$(( failed + 1 ))
    continue
  fi

  restored=$(( restored + 1 ))

  if (( have_manifest )); then
    expected="$(awk -v want="$base" '
      { n = $NF; sub(/^\*/, "", n); sub(/.*\//, "", n)
        if (n == want) { print $1; exit } }' "$MANIFEST")"

    if [[ -z "$expected" ]]; then
      err "$base: not listed in the manifest - cannot verify"
      unverified=$(( unverified + 1 ))
      continue
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
  else
    unverified=$(( unverified + 1 ))
  fi
done

# --- result ----------------------------------------------------------------

echo
log "restored to: $DEST"
log "  files written : $restored"
(( verified ))   && log "  verified      : $verified"
(( unverified )) && log "  UNVERIFIED    : $unverified"
(( skipped ))    && log "  skipped       : $skipped (already existed)"
(( failed ))     && err "  FAILED        : $failed"

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

if (( ! have_manifest )) || (( unverified )); then
  log "RESULT: RESTORED (UNVERIFIED)"
  log "  $verified file(s) verified, $unverified NOT checked against a manifest."
  log "  A partial result, deliberately not called a pass. Recover a manifest"
  log "  and re-run to turn this into a real one."
  exit 0
fi

log "RESULT: PASS - $verified file(s) restored and byte-identical to the card"
