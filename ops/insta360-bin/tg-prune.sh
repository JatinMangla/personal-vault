#!/usr/bin/env bash
#
# tg-prune - run on the PHONE, before connecting the card.
#
# Removes files from tg-batch that are already in the Telegram archive, so
# Syncthing never transfers them again.
#
# WHY THIS EXISTS. tg-upload.sh already refuses to upload a duplicate, but by
# then the file has crossed the link, with the phone tethered and the battery
# draining at 1% per 3.3 minutes. Skipping at the VM saves Telegram bandwidth;
# skipping HERE saves the transfer as well.
#
# Hashing locally reads at roughly 3.7 GB/min, several times faster than
# sending the same bytes even on a direct link. So checking still costs less
# than transferring - though by a smaller margin than when the connection
# relayed at 1.3 MB/s, which is when this script was written.
#
#   tg-prune              show what would be removed, remove nothing
#   tg-prune --apply      actually remove them
#
# SAFETY. --apply DELETES archived files from tg-batch. That is deliberate, and
# it is the safer of the two options in practice.
#
# The alternative is the operator clearing tg-batch by hand, and a human has no
# hash to check against - deleting footage that was never uploaded is a real
# mistake and an unrecoverable one. This script deletes a file only when its
# SHA-256 appears in uploaded.sha256, which is written only after that file went
# to Telegram, came back, and matched. A file it cannot verify is never touched:
# a name match with different content is reported and KEPT.
#
# `--apply --keep` moves to a tg-archived/ sibling instead of deleting, for a
# batch you want to hold on the card a while longer.
#
# It refuses to run against any directory not named tg-batch, and the dry run
# is the default.

set -euo pipefail

# UPPERCASE, and DCIM not dcim. Android mounts FAT volumes with an uppercase
# id, so the lowercase path that appears in the Syncthing config does not exist
# from Termux. Verified 2026-09-15: /storage/9C33-6BBD/DCIM/tg-batch lists.
BATCH_DIR="${TG_BATCH_DIR:-/storage/9C33-6BBD/DCIM/tg-batch}"
VM_HOST="${VM_HOST:-ubuntu@100.88.183.74}"
VM_LEDGER="${VM_LEDGER:-/var/lib/insta360-archive/work/uploaded.sha256}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/immich_phone}"

APPLY=0
KEEP=0
for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=1 ;;
    --keep)  KEEP=1 ;;
    -h|--help)
      echo "tg-prune                  dry run - show what is already archived"
      echo "tg-prune --apply          DELETE archived files from tg-batch"
      echo "tg-prune --apply --keep   move them to ../tg-archived instead"
      exit 0
      ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; }

# Find tg-batch wherever the card mounted this time.
#
# Android gives a removable card a different mount point per session, so a
# hardcoded path is wrong as often as it is right. Search for the folder
# instead, and say plainly when the card simply is not plugged in - that is the
# normal state between transfers, not a fault.
if [[ ! -d "$BATCH_DIR" ]]; then
  # `|| true` is load-bearing. find exits non-zero when a search root is
  # missing or unreadable - /storage does not exist on every device, and in
  # Termux it is full of permission-denied subdirectories - and under `set -e`
  # a failing command substitution kills the script mid-assignment, before any
  # of the guidance below can print. A guard that dies silently is worse than
  # no guard. Search only roots that actually exist, and never let the search
  # itself be fatal.
  # Searching /storage itself is useless: Android denies LISTING it, so find
  # sees nothing there. But the card's own subdirectory IS readable once named
  # explicitly - /storage/ denied says nothing about /storage/9C33-6BBD/. That
  # distinction cost a whole detour and a wrongly-deleted script.
  #
  # So glob the card-id directories directly rather than descending from
  # /storage, and search the Termux symlinks too in case they are populated.
  roots=()
  for d in /storage/[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]-*; do
    [[ -d "$d" ]] && roots+=("$d")
  done
  [[ -d "$HOME/storage" ]] && roots+=("$HOME/storage")

  found=""
  if (( ${#roots[@]} )); then
    found="$(find "${roots[@]}" -maxdepth 3 -iname 'tg-batch' -type d 2>/dev/null | head -1 || true)"
  fi

  if [[ -n "$found" ]]; then
    log "found tg-batch at: $found"
    BATCH_DIR="$found"
  else
    err "cannot find tg-batch anywhere"
    err ""
    err "If the X4 or the SD card is not plugged in, that is expected -"
    err "tg-batch lives on the card. Connect it and run this again."
    err ""
    err "If it IS connected, find the folder and pass it directly:"
    err "  ls /storage/"
    err "  TG_BATCH_DIR=/storage/XXXX-XXXX/DCIM/tg-batch tg-prune"
    exit 1
  fi
fi

# Refuse to operate on something that is not a batch folder. Deleting from the
# wrong directory on a phone is not recoverable.
case "$BATCH_DIR" in
  *tg-batch*) : ;;
  *) err "refusing: $BATCH_DIR is not a tg-batch folder"; exit 1 ;;
esac

# `timeout` bounds the hash of a file on a failing card. It ships in the same
# coreutils package as sha256sum, so this normally passes - but without it the
# hash below would fail for EVERY file rather than only unreadable ones, which
# would look like a totally broken script rather than a missing package.
command -v timeout >/dev/null || {
  err "timeout missing - run: pkg install coreutils"
  exit 1
}

command -v sha256sum >/dev/null || {
  err "sha256sum missing - run: pkg install coreutils"
  exit 1
}

shopt -s nullglob
files=("$BATCH_DIR"/*.insv "$BATCH_DIR"/*.INSV)
shopt -u nullglob

if (( ${#files[@]} == 0 )); then
  log "tg-batch is empty - nothing to do"
  exit 0
fi

log "${#files[@]} file(s) in tg-batch"

# Say that hashing is about to take minutes, and roughly how many.
#
# Without this the script prints nothing between fetching the ledger and its
# summary, so a large batch looks hung. On 2026-09-16 that silence led to a
# five-minute wait being reported as a crash, and then to a healthy card being
# diagnosed as failing. Measured OTG read: 20.4 MB/s.
hash_bytes=0
for f in "${files[@]}"; do
  sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  hash_bytes=$(( hash_bytes + sz ))
done
if (( hash_bytes > 2000000000 )); then
  log "hashing up to $(( hash_bytes / 1000000000 )) GB - expect ~$(( hash_bytes / 20000000 / 60 )) min at 20 MB/s over OTG"
  log "  (it is reading the card, not stuck; Ctrl+C is safe - nothing is deleted until every file is checked)"
fi

LEDGER="$(mktemp "${TMPDIR:-/data/data/com.termux/files/usr/tmp}/ledger.XXXXXX")"
trap 'rm -f "$LEDGER"' EXIT

log "fetching the archive ledger from the VM"
if ! scp -q -i "$SSH_KEY" "$VM_HOST:$VM_LEDGER" "$LEDGER" 2>/dev/null; then
  err "could not fetch $VM_LEDGER"
  err "is Tailscale up? try: ssh -i $SSH_KEY $VM_HOST true"
  err "nothing was changed"
  exit 1
fi

ledger_lines="$(wc -l < "$LEDGER" | tr -d ' ')"
log "ledger holds $ledger_lines archived file(s)"

if (( ledger_lines == 0 )); then
  log "nothing archived yet - every file here still needs uploading"
  exit 0
fi

# Name first, hash second.
#
# Hashing every file would read the whole batch - minutes for 20 GB. The name
# is a free first filter: if it is not in the ledger at all, the file cannot be
# archived and no hash is needed. Only when a name matches do we spend the read
# to confirm the CONTENT matches too, so a reused filename with new footage is
# never mistaken for an upload that already happened.
archived=()
fresh=()
renamed=0
unreadable=0

# How long to allow a single hash before giving up on that file.
#
# MEASURED, not assumed. `dd` over OTG on 2026-09-16 read 200 MiB in 10.3 s =
# 20.4 MB/s, so a 5.9 GB file needs ~5 minutes and an 8 GB file ~6.5.
#
# The earlier "~3.7 GB/min" figure in this project is a SCAN rate quoted from
# Syncthing, not an OTG read rate; using it here would have set a timeout that
# aborts precisely the large files this guard exists to handle. A 5.9 GB file
# would have landed within seconds of a 300 s limit.
#
# 30 minutes is deliberately far above any healthy read: at 20 MB/s it covers a
# 36 GB file, which is larger than the card produces. The point is to bound an
# infinite retry storm on genuinely bad sectors, NOT to second-guess a slow
# link - a file that is merely slow must be allowed to finish, because timing
# it out would mean keeping a file that is safely archived and could have been
# pruned. Override for an unusually slow reader:
#   HASH_TIMEOUT=3600 tg-prune --apply
HASH_TIMEOUT="${HASH_TIMEOUT:-1800}"

for f in "${files[@]}"; do
  base="$(basename "$f")"

  recorded="$(awk -v want="$base" '$2 == want { print $1; exit }' "$LEDGER")"
  if [[ -z "$recorded" ]]; then
    fresh+=("$f")
    continue
  fi

  # An unreadable file must not abort the run, and must never be deleted.
  #
  # The original was a bare `sha256sum "$f"`: under `set -euo pipefail` an I/O
  # error killed the whole prune mid-loop, and a retrying kernel hung it
  # indefinitely. Either way the remaining files were never examined, so one
  # bad sector blocked pruning everything else - including files that are
  # perfectly readable and safely archived.
  #
  # `timeout` bounds the retry storm. Both failures land in the same place: the
  # file is UNVERIFIED, so it is kept. Deleting a file whose content could not
  # be read would be deleting on the strength of a filename alone, which is the
  # exact mistake this script exists to prevent.
  hash_rc=0
  actual="$(timeout "$HASH_TIMEOUT" sha256sum "$f" 2>/dev/null | cut -d' ' -f1)" || hash_rc=$?

  if (( hash_rc != 0 )) || [[ -z "$actual" ]]; then
    if (( hash_rc == 124 )); then
      err "UNREADABLE (timed out after ${HASH_TIMEOUT}s) - keeping: $base"
      err "  the card may be failing in this region; the kernel is retrying"
    else
      err "UNREADABLE (I/O error) - keeping: $base"
    fi
    err "  this file is NOT deleted. If it is in the ledger it is already in"
    err "  Telegram, verified; recover it with restore.sh"
    unreadable=$(( unreadable + 1 ))
    fresh+=("$f")
    continue
  fi

  if [[ "$actual" == "$recorded" ]]; then
    archived+=("$f")
  else
    log "same name, different content - keeping: $base"
    renamed=$(( renamed + 1 ))
    fresh+=("$f")
  fi
done

echo
log "already archived : ${#archived[@]}"
log "still to upload  : ${#fresh[@]}"
(( renamed )) && log "name reused      : $renamed (kept - content differs)"

if (( unreadable )); then
  log "unreadable       : $unreadable (kept - could not be verified)"
  echo
  err "$unreadable file(s) could not be read from the card."
  err "That is a HARDWARE signal, not a script fault. Check the cable first,"
  err "then test one file directly:"
  err "  dd if=<path> of=/dev/null bs=1M count=200"
  err "If reads keep failing, stop recording to this card and copy what you"
  err "can off it. Anything already in the ledger is safe in Telegram."
fi

if (( ${#archived[@]} == 0 )); then
  log "nothing to prune - connect the card and sync"
  exit 0
fi

bytes=0
for f in "${archived[@]}"; do
  sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  bytes=$(( bytes + sz ))
done
# Midpoint of the 10-16 MB/s measured on a DIRECT Tailscale link (2026-09-15).
# It was 1.3 MB/s while the connection relayed through DERP, so this estimate is
# roughly 10x shorter than it used to be. Override if the link changes:
#   TRANSFER_RATE_MB_S=1.3 tg-prune
RATE_MB_S="${TRANSFER_RATE_MB_S:-12}"
RATE_BYTES_S=$(( ${RATE_MB_S%%.*} * 1000000 ))
if (( RATE_BYTES_S <= 0 )); then
  # Correct the LABEL too, not just the divisor. Guarding the arithmetic while
  # still printing the rejected value reports a number that was not used, which
  # is the quiet kind of wrong this project keeps finding.
  RATE_BYTES_S=1000000
  RATE_MB_S=1
fi

mb=$(( bytes / 1024 / 1024 ))
mins=$(( bytes / RATE_BYTES_S / 60 ))

echo
log "pruning would save ${mb} MB of transfer (~${mins} min at ${RATE_MB_S} MB/s)"

DONE_DIR="$(dirname "$BATCH_DIR")/tg-archived"

if (( ! APPLY )); then
  echo
  log "DRY RUN - nothing changed. These are already in Telegram:"
  for f in "${archived[@]}"; do echo "    $(basename "$f")"; done
  echo

  # Offer to continue rather than throwing the work away.
  #
  # The dry run and --apply do IDENTICAL work up to this point: both hash every
  # name-matched file to build "archived". Exiting here meant the operator ran
  # the whole thing twice for one prune - 31 minutes instead of 15 on an 18.8 GB
  # batch, because the card reads at 20.4 MB/s and nothing about that is going
  # to change. The hashing IS the safety; doing it twice is not twice as safe.
  #
  # The preview still happens first, which is the point of the dry run. The only
  # thing removed is the second read of the same bytes.
  #
  # `[[ -t 0 ]]` is load-bearing: a piped or scripted invocation has no human to
  # answer, and must never delete on a default. Those keep the old behaviour of
  # printing the list and exiting. `read` is given an explicit </dev/tty so the
  # prompt still works when stdout is redirected to a log.
  if [[ -t 0 ]]; then
    if (( KEEP )); then
      printf '  move these %d file(s) to tg-archived now? [y/N] ' "${#archived[@]}"
    else
      printf '  delete these %d file(s) from tg-batch now? [y/N] ' "${#archived[@]}"
    fi

    reply=""
    read -r reply </dev/tty || reply=""

    case "$reply" in
      y|Y|yes|YES)
        log "proceeding - the files above are already verified, not re-hashing"
        APPLY=1
        ;;
      *)
        echo
        log "nothing changed."
        if (( KEEP )); then
          log "run 'tg-prune --apply --keep' to move them to $DONE_DIR"
        else
          log "run 'tg-prune --apply' to delete them from tg-batch"
          log "  each one is verified present in Telegram before it is removed"
        fi
        exit 0
        ;;
    esac
  else
    if (( KEEP )); then
      log "run 'tg-prune --apply --keep' to move them to $DONE_DIR"
    else
      log "run 'tg-prune --apply' to delete them from tg-batch"
      log "  each one is verified present in Telegram before it is removed"
    fi
    exit 0
  fi
fi

echo

if (( ! KEEP )); then
  # Every file here has been hash-matched against uploaded.sha256, which is
  # written only after a successful Telegram round trip. Anything unverified
  # was filtered out long before this point.
  for f in "${archived[@]}"; do
    rm -f "$f" && log "deleted $(basename "$f")"
  done
  log "done - deleted ${#archived[@]} file(s) already in Telegram"
  log "${#fresh[@]} file(s) left in tg-batch to sync"
  log "these were verified in the archive first; recover with restore.sh"
else
  # Out of tg-batch, not out of existence. Syncthing watches tg-batch alone, so
  # a sibling directory is invisible to it - the transfer stops either way, and
  # the footage is still on the card if the archive ever has to be questioned.
  if ! mkdir -p "$DONE_DIR" 2>/dev/null; then
    err "cannot create $DONE_DIR - nothing was moved"
    err "the card may be read-only, or full"
    exit 1
  fi

  moved=0
  for f in "${archived[@]}"; do
    base="$(basename "$f")"
    if [[ -e "$DONE_DIR/$base" ]]; then
      err "already in tg-archived, leaving in place: $base"
      continue
    fi
    if mv "$f" "$DONE_DIR/"; then
      log "moved $base"
      moved=$(( moved + 1 ))
    else
      err "could not move $base - left where it is"
    fi
  done

  log "done - moved $moved file(s) to $DONE_DIR"
  log "${#fresh[@]} file(s) left in tg-batch to sync"
  log "NOTHING WAS DELETED - the footage is still on the card"
fi
