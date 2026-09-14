#!/usr/bin/env bash
#
# tg-prune - run on the PHONE, before connecting the card.
#
# Removes files from tg-batch that are already in the Telegram archive, so
# Syncthing never transfers them again.
#
# WHY THIS EXISTS. tg-upload.sh already refuses to upload a duplicate, but by
# then the file has crossed the cable: ~1.3 MB/s over OTG, with the phone
# tethered and the battery draining at 1% per 3.3 minutes. Skipping at the VM
# saves Telegram bandwidth; skipping HERE saves the expensive half.
#
# Hashing locally reads at roughly 3.7 GB/min, about 170x faster than sending
# the same bytes. So checking is always cheaper than transferring.
#
#   tg-prune              show what would be removed, remove nothing
#   tg-prune --apply      actually remove them
#
# SAFETY. This only ever deletes from tg-batch, which holds COPIES. Your
# originals live wherever you copied them from and are never touched. Even so
# it refuses to run unless the directory looks like a batch folder, and
# --apply is required for anything to be deleted.

set -euo pipefail

# UPPERCASE, and DCIM not dcim. Android mounts FAT volumes with an uppercase
# id, so the lowercase path that appears in the Syncthing config does not exist
# from Termux. Verified 2026-09-15: /storage/9C33-6BBD/DCIM/tg-batch lists.
BATCH_DIR="${TG_BATCH_DIR:-/storage/9C33-6BBD/DCIM/tg-batch}"
VM_HOST="${VM_HOST:-ubuntu@100.88.183.74}"
VM_LEDGER="${VM_LEDGER:-/var/lib/insta360-archive/work/uploaded.sha256}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/immich_phone}"

APPLY=0
[[ "${1:-}" == "--apply" ]] && APPLY=1
[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && {
  echo "tg-prune            dry run - show what is already archived"
  echo "tg-prune --apply    remove those files from tg-batch"
  exit 0
}

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

for f in "${files[@]}"; do
  base="$(basename "$f")"

  recorded="$(awk -v want="$base" '$2 == want { print $1; exit }' "$LEDGER")"
  if [[ -z "$recorded" ]]; then
    fresh+=("$f")
    continue
  fi

  actual="$(sha256sum "$f" | cut -d' ' -f1)"
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

if (( ${#archived[@]} == 0 )); then
  log "nothing to prune - connect the card and sync"
  exit 0
fi

bytes=0
for f in "${archived[@]}"; do
  sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  bytes=$(( bytes + sz ))
done
mb=$(( bytes / 1024 / 1024 ))
mins=$(( bytes / 1300000 / 60 ))

echo
log "pruning would save ${mb} MB of transfer (~${mins} min at 1.3 MB/s)"

if (( ! APPLY )); then
  echo
  log "DRY RUN - nothing removed. These are already in Telegram:"
  for f in "${archived[@]}"; do echo "    $(basename "$f")"; done
  echo
  log "run 'tg-prune --apply' to remove them"
  exit 0
fi

echo
for f in "${archived[@]}"; do
  rm -f "$f" && log "removed $(basename "$f")"
done

log "done - ${#fresh[@]} file(s) left to sync"
log "these are COPIES; your originals were never touched"
