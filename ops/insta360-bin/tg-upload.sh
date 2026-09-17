#!/usr/bin/env bash
# Upload one staged batch to Telegram, prove it round-trips, then delete it.
# Files leave staging ONLY after being downloaded back and hashed.
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

STAGING_DIR="${STAGING_DIR:?STAGING_DIR not set}"
MANIFEST="${MANIFEST:?MANIFEST not set}"
WORK_DIR="${WORK_DIR:-/var/lib/insta360-archive/work}"
TG_CHANNEL="${TG_CHANNEL:?TG_CHANNEL not set}"
TG_CONFIG="${TG_CONFIG:-/var/lib/insta360-archive/telegram-upload.json}"
GUARD_MARGIN_GB="${GUARD_MARGIN_GB:-10}"

# readlink -f first, so a symlinked install still finds verify-batch.sh beside
# the real script rather than beside the link. Same bug as tg-archive hit when
# run through /usr/local/bin.
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

log() { echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" >&2; }

# Publish the current step for the dashboard.
#
# `status` in drain-state is only idle/running/complete/incomplete, so the 20
# minutes Check #2 spends downloading the channel back are indistinguishable
# from uploading. This script already LOGS all six transitions; writing them to
# a file costs nothing and makes /status able to say which one is happening.
#
# Written to a .tmp then mv'd, the way tg-archive.sh's write_state does: mv
# within a filesystem is atomic, so the collector - which reads this on its own
# timer, every minute - can never catch a half-written file.
#
# Never fatal. The trailing `|| true` matters under `set -e` with an ERR trap:
# a read-only or full WORK_DIR must not abort an upload that is otherwise fine.
# Progress reporting is not worth losing a verified batch over.
PHASE_FILE="$WORK_DIR/phase"

write_phase() {
  local phase="$1" file="${2:-}" index="${3:-0}" total="${4:-0}"
  {
    printf 'phase=%s\n' "$phase"
    printf 'phase_file=%s\n' "$file"
    printf 'phase_index=%s\n' "$index"
    printf 'phase_total=%s\n' "$total"
    printf 'phase_updated=%s\n' "$(date +%s)"
  } > "$PHASE_FILE.tmp" 2>/dev/null && mv "$PHASE_FILE.tmp" "$PHASE_FILE" || true
}

hc() {
  local endpoint="${1:-}"
  [[ -n "${HEALTHCHECK_TGUPLOAD_UUID:-}" ]] || return 0
  curl -fsS -m 10 --retry 3 "https://hc-ping.com/${HEALTHCHECK_TGUPLOAD_UUID}${endpoint}" >/dev/null || true
}

on_error() {
  local code=$?
  err "upload failed with exit code $code"
  hc "/${code}"
  exit "$code"
}
trap on_error ERR

hc "/start"

[[ -d "$STAGING_DIR" ]] || { err "staging missing: $STAGING_DIR"; exit 1; }
[[ -r "$MANIFEST" ]] || { err "manifest not readable: $MANIFEST"; exit 1; }
[[ -r "$TG_CONFIG" ]] || { err "tg config not readable: $TG_CONFIG"; exit 1; }

command -v telegram-upload >/dev/null || { err "telegram-upload missing"; exit 1; }
command -v telegram-download >/dev/null || { err "telegram-download missing"; exit 1; }

mkdir -p "$WORK_DIR"

# Guard only when flock exists. `command -v` first, because a missing flock
# makes `if ! flock -n 9` true and the run aborts claiming another upload is in
# progress - a confusing lie that sends you hunting a process that was never
# there. Ubuntu ships flock in util-linux so this holds on the VM; it is the
# honest reporting that matters, and it lets the script be tested anywhere.
if command -v flock >/dev/null 2>&1; then
  exec 9>"$WORK_DIR/.session.lock"
  if ! flock -n 9; then
    err "another run holds the session lock"
    exit 1
  fi
else
  err "flock unavailable - running without a session lock"
fi

shopt -s nullglob
staged=("$STAGING_DIR"/*.insv)
shopt -u nullglob

if (( ${#staged[@]} == 0 )); then
  log "staging is empty - nothing to do"
  hc ""
  exit 0
fi

# Drop anything already in the archive.
#
# Syncthing re-delivers whatever is in the phone's tg-batch folder, so a file
# that was uploaded and verified last week arrives again the moment the card is
# reconnected. Without this it would be archived a second time: a duplicate in
# the channel, and the transfer paid for twice.
#
# Matched by HASH, not filename. The name is only a cheap first filter - the
# hash is what uploaded.sha256 records, and it is what makes this self-healing.
# A file reusing an old name with new content must still upload, and comparing
# content is the only way to know the difference.
#
# A skipped file is REMOVED from staging. Leaving it would make the drain loop
# see a permanently non-empty staging directory and spin forever on a file it
# refuses to upload.
UPLOADED_LOG="$WORK_DIR/uploaded.sha256"
batch=()
skipped=0

for f in "${staged[@]}"; do
  base="$(basename "$f")"

  if [[ -r "$UPLOADED_LOG" ]] && grep -qF " $base" "$UPLOADED_LOG"; then
    recorded="$(awk -v want="$base" '$2 == want { print $1; exit }' "$UPLOADED_LOG")"
    actual="$(sha256sum "$f" | cut -d' ' -f1)"

    if [[ -n "$recorded" && "$recorded" == "$actual" ]]; then
      log "already archived, removing from staging: $base"
      rm -f "$f"
      skipped=$(( skipped + 1 ))
      continue
    fi

    err "$base is recorded as archived but the content differs - uploading it"
    err "  recorded $recorded"
    err "  on disk  $actual"
  fi

  batch+=("$f")
done

if (( ${#batch[@]} == 0 )); then
  log "all ${skipped} staged file(s) were already archived - nothing to upload"
  log "SAFE TO CLEAR THIS BATCH FROM THE CARD"
  hc ""
  exit 0
fi

(( skipped )) && log "skipped $skipped file(s) already in the archive"

avail_kb="$(df -P "$STAGING_DIR" | awk 'NR==2{print $4}')"
avail_gb=$(( avail_kb / 1024 / 1024 ))

# The archive size comes from the ledger's third column, written at upload time
# precisely because Telegram cannot be asked how big a channel is without
# downloading all of it. Rows predating that column contribute nothing, so this
# can UNDER-estimate on an old archive - hence the margin on top.
archive_bytes=0
if [[ -r "$UPLOADED_LOG" ]]; then
  archive_bytes="$(awk '$3 ~ /^[0-9]+$/ { s += $3 } END { printf "%d", s + 0 }' \
    "$UPLOADED_LOG" 2>/dev/null || echo 0)"
fi

GIB=$(( 1024 * 1024 * 1024 ))
avail_bytes=$(( avail_kb * 1024 ))

# TAKE ONLY WHAT FITS. Previously this globbed every .insv in staging as one
# batch and refused outright if the round trip would not fit - so 100 GB in
# staging meant the guard refused, tg-archive.sh retried the identical
# directory every 60 seconds, and nothing ever uploaded. Staging could not
# shrink, because the refusal happens before any file is touched.
#
# Now the batch is filled file by file until the next one would breach the
# margin, and whatever does not fit STAYS IN STAGING for the next pass. The
# drain loop then makes progress on every iteration instead of spinning.
#
# THE PEAK, which the old arithmetic got wrong:
#
#   staged .insv        the batch, already on disk
#   + .roundtrip        what Check #2 downloads back
#   + margin            headroom for Immich
#
# The old guard computed `archive + batch` and compared it to free space,
# forgetting the batch is ALREADY on disk and is therefore counted twice during
# Check #2. A 60 GB batch against a 31 GB archive passed that check and would
# then have filled a 147 GB volume outright.
#
# What Check #2 actually downloads depends on which path it takes:
#   - by message id (normal)  -> just this batch
#   - full channel (fallback) -> the whole archive plus this batch
# Size for the FALLBACK, because that is the one that can fill the disk, and a
# guard that is only correct on the happy path is not a guard.
margin_bytes=$(( GUARD_MARGIN_GB * GIB ))
budget=$(( avail_bytes - margin_bytes - archive_bytes ))

fitted=()
deferred=0
deferred_bytes=0
batch_bytes=0

for f in "${batch[@]}"; do
  sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"

  # Each file costs its size TWICE: it already occupies staging, and Check #2
  # writes a second copy into .roundtrip.
  if (( ${#fitted[@]} > 0 && batch_bytes + sz * 2 > budget )); then
    deferred=$(( deferred + 1 ))
    deferred_bytes=$(( deferred_bytes + sz ))
    continue
  fi

  fitted+=("$f")
  batch_bytes=$(( batch_bytes + sz * 2 ))
done

# A single file larger than the whole budget cannot be split any further. Say so
# plainly and exit non-zero rather than looping: no amount of retrying will make
# it fit, and the drain loop must not spin on it forever.
if (( ${#fitted[@]} == 0 )); then
  first_sz="$(stat -c %s "${batch[0]}" 2>/dev/null || echo 0)"
  err "not enough space for even one file - refusing"
  err "  free ${avail_gb} GiB, margin ${GUARD_MARGIN_GB} GiB, archive $(( archive_bytes / GIB )) GiB"
  err "  smallest candidate needs $(( first_sz * 2 / GIB )) GiB (itself plus the Check #2 copy)"
  err "  THIS WILL NOT RESOLVE ON RETRY. Free space on $STAGING_DIR, or"
  err "  verify by message id so Check #2 stops re-downloading the archive."
  exit 2
fi

batch=("${fitted[@]}")

log "batch of ${#batch[@]} file(s), $(( batch_bytes / 2 / GIB )) GiB"
log "free: ${avail_gb} GiB (margin ${GUARD_MARGIN_GB}, archive $(( archive_bytes / GIB )) GiB)"

if (( deferred )); then
  log "deferring $deferred file(s), $(( deferred_bytes / GIB )) GiB - they stay staged for the next pass"
fi

# Install the phase-clearing trap BEFORE the first write_phase, not beside the
# round-trip directory a hundred lines below.
#
# Everything between here and there can exit: Check #1 rejecting a file, the
# disk-margin guard, a flood-wait ceiling during upload. With the trap installed
# only at the round trip, every one of those failures left the last phase
# written - "uploading GS010042.insv" - on the dashboard forever, which is the
# exact stale-phase failure this trap exists to prevent. rt_dir is unset until
# later and the guard below tolerates that.
cleanup() {
  [[ -n "${rt_dir:-}" ]] && rm -rf "$rt_dir"
  [[ -n "${BATCH_HASHES:-}" ]] && rm -f "$BATCH_HASHES"
  write_phase "" "" 0 0
}
trap cleanup EXIT

# EXIT alone does not cover a killed run.
#
# `systemctl stop tg-archive` sends SIGTERM to the whole cgroup. bash running a
# foreground child does not run its EXIT trap until that child reaps, and if
# the shell itself is killed the trap never fires at all - so the round-trip
# directory is orphaned. On 2026-09-17 that left 93 GB of scratch behind on a
# 147 GB volume, taking it to 91% full, and the operator had to find and remove
# it by hand.
#
# This matters more than it looks: "systemctl stop tg-archive (safe at any
# point)" is advice this project prints in its own logs and documentation. It
# must not mean "and then go hunting for tens of gigabytes".
#
# Trapping these re-raises through the EXIT handler, which removes rt_dir.
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 129' HUP

# Pass the BATCH explicitly, not the directory.
#
# Staging may now hold files this pass deliberately deferred for lack of space,
# and re-hashing those would waste minutes per pass. A deferred file that has
# not been fingerprinted yet would also fail Check #1 and abort a batch that is
# otherwise fine.
# Capture the hashes Check #1 computes, so the ledger write at the end of this
# script does not read every file a second time. PID-scoped, on the work
# volume, and removed by cleanup() on every exit path including SIGTERM.
#
# Check #1 is authoritative here: it is the pass that compares against the
# manifest, and a file that fails it never reaches the ledger at all.
BATCH_HASHES="$WORK_DIR/batch-hashes.$$"
: > "$BATCH_HASHES"

# Check #1 runs PER FILE, immediately before that file uploads.
#
# It used to hash the ENTIRE batch up front - 13 minutes for 27 GiB with the
# network completely idle - and only then start uploading.
#
# BE PRECISE ABOUT THE WIN, because it is easy to overstate. This loop is
# sequential: hashing file N+1 does NOT run concurrently with uploading file N.
# Total CPU and total bytes read are unchanged. What changes is WHEN the first
# byte reaches Telegram: after one file's hash rather than after the whole
# batch's. On a 27 GiB batch the upload now starts within seconds instead of 13
# minutes, so a drain interrupted part-way has real files in the archive rather
# than none, and the dashboard shows progress immediately.
#
# Genuine overlap would need the hash of N+1 backgrounded against the upload of
# N. That is worth doing and is deliberately NOT done here: it needs its own
# reasoning about failure ordering - a background hash failing while an upload
# is in flight - and this change is meant to be the contained one.
#
# WHAT DOES NOT CHANGE. Every file is still hashed against the manifest before
# a single byte of it is uploaded, and a file that fails is never uploaded at
# all. The guarantee "nothing reaches Telegram unverified" is per file, and it
# is exactly as strong as it was.
#
# WHAT DOES CHANGE, stated plainly: a batch that fails on its Nth file will
# already have uploaded files 1..N-1, where before it would have uploaded
# nothing. That is not a weakening of the integrity chain - those files were
# each verified before being sent - but it does mean a failed batch can leave
# files in Telegram. That is already true of any interrupted drain, and it is
# what the duplicate handling exists for: tg-resolve-ids.py takes the NEWEST
# message id per name, so a re-run that re-uploads them verifies against the
# new copies. Staging is still cleared only after Check #2, so nothing is
# deleted on the strength of a partial batch.
verify_one() {
  local file="$1"
  HASH_FILE="$BATCH_HASHES" "$HERE/verify-batch.sh" "$file"
}

upload_one() {
  local file="$1" attempt=0 max=8 out rc wait_s

  while (( attempt < max )); do
    attempt=$((attempt + 1))
    set +e
    # No --print-file-id. It emits a Bot API file_id, not a message id, so it
    # bought nothing; ids are resolved after the batch by asking Telegram.
    out="$(telegram-upload --to "$TG_CHANNEL" --config "$TG_CONFIG" --large-files split --no-thumbnail "$file" 2>&1)"
    rc=$?
    set -e

    if (( rc == 0 )); then
      (( attempt > 1 )) && log "  succeeded on attempt $attempt"
      return 0
    fi

    wait_s="$(printf '%s' "$out" | grep -oE 'FLOOD(_PREMIUM)?_WAIT_([0-9]+)' | grep -oE '[0-9]+$' | head -1)"
    if [[ -z "$wait_s" ]]; then
      wait_s="$(printf '%s' "$out" | grep -oiE 'wait of ([0-9]+) seconds' | grep -oE '[0-9]+' | head -1)"
    fi

    if [[ -n "$wait_s" ]]; then
      wait_s=$(( wait_s + 15 ))
      log "  throttled (attempt $attempt/$max) - sleeping ${wait_s}s"
      sleep "$wait_s"
      continue
    fi

    err "upload failed for $(basename "$file") (attempt $attempt/$max, rc=$rc)"
    printf '%s\n' "$out" | tail -5 >&2
    sleep $(( attempt * 30 ))
  done

  err "giving up on $(basename "$file")"
  return 1
}

# Message ids per file, collected as the batch uploads.
#
# Space-separated, keyed by basename. Bash 4 associative arrays are fine here -
# the VM runs Ubuntu 24.04 - and this never outlives the process: it is written
# to the ledger below, which is the durable record.
declare -A BATCH_IDS=()
ids_complete=1

upload_index=0
for f in "${batch[@]}"; do
  upload_index=$(( upload_index + 1 ))

  # Verify THIS file, then upload it. A failure aborts under `set -e` with the
  # file unsent, so nothing unverified ever reaches Telegram.
  log "Check #1 - verifying $(basename "$f") ($upload_index/${#batch[@]})"
  write_phase hashing "$(basename "$f")" "$upload_index" "${#batch[@]}"
  verify_one "$f"

  log "uploading $(basename "$f") ($(numfmt --to=iec "$(stat -c %s "$f")"))"
  write_phase uploading "$(basename "$f")" "$upload_index" "${#batch[@]}"
  upload_one "$f"

done

# Resolve message ids by ASKING TELEGRAM, not by parsing CLI output.
#
# The previous approach scraped `--print-file-id`, which emits a Bot API
# file_id (BQADBQADmiMAAss5WVXcwHLblCIghQI) rather than a message id. The
# parser matched nothing, every file logged "no message id captured", and every
# Check #2 fell back to a full-channel download - which cost an 11-hour drain
# on 2026-09-17. See tg-resolve-ids.py for why a file_id cannot substitute.
#
# Done once for the whole batch rather than per file: one channel walk instead
# of N, and the resolver takes the newest id per name, which is what makes it
# correct in the presence of the 13 duplicate filenames already in the channel.
RESOLVER="$HERE/tg-resolve-ids.py"
PIPX_PY="${PIPX_PY:-$HOME/.local/share/pipx/venvs/telegram-upload/bin/python}"
[[ -x "$PIPX_PY" ]] || PIPX_PY="$(command -v python3 || true)"

if [[ -r "$RESOLVER" && -n "$PIPX_PY" ]]; then
  batch_names=()
  for f in "${batch[@]}"; do batch_names+=("$(basename "$f")"); done

  log "resolving message ids for ${#batch_names[@]} file(s)"
  #
  # CONSUME STDOUT REGARDLESS OF EXIT STATUS.
  #
  # This was `if resolved_out="$(...)"`, which skipped the parse loop whenever
  # the resolver exited non-zero - and the resolver used to exit 1 on PARTIAL
  # resolution, after printing the ids it had already found. So a single
  # unresolvable name discarded every id in the batch and sent Check #2 down
  # the full-channel download path. The resolver now exits 0 on partial
  # success, but this side no longer depends on that: it parses what was
  # printed either way, and the completeness check below judges per-file from
  # BATCH_IDS, which is the only thing that can be acted on per-file.
  #
  # The resolver's stderr is NOT discarded: it names each unresolved file,
  # and that is the difference between "Check #2 was slow" and knowing which
  # file made it slow. Only stdout is captured, so the two cannot mix.
  resolved_out=""
  resolved_out="$("$PIPX_PY" "$RESOLVER" --config "$TG_CONFIG" \
                    --channel "$TG_CHANNEL" "${batch_names[@]}")" \
    || err "id resolver exited non-zero - using whatever ids it did print"

  while IFS=$'\t' read -r rname rids; do
    [[ -n "$rname" && -n "$rids" ]] || continue
    BATCH_IDS["$rname"]="$rids"
    log "  $rname -> $rids"
  done <<< "$resolved_out"

  for bn in "${batch_names[@]}"; do
    if [[ -z "${BATCH_IDS[$bn]:-}" ]]; then
      err "could not resolve a message id for $bn"
      ids_complete=0
    fi
  done
else
  err "tg-resolve-ids.py not usable - Check #2 will download the whole channel"
  ids_complete=0
fi

manifest_copy="$WORK_DIR/manifest-$(date -u +%Y%m%dT%H%M%SZ).sha256"
cp "$MANIFEST" "$manifest_copy"
log "uploading manifest copy"
upload_one "$manifest_copy" || err "manifest upload failed - not fatal"
rm -f "$manifest_copy"

log "Check #2 - downloading the channel back"
write_phase downloading "" 0 "${#batch[@]}"

# On the MEDIA volume, not WORK_DIR.
#
# Check #2 downloads the ENTIRE channel back to verify, so this directory grows
# to the size of the whole archive on every batch - not the size of the batch.
# WORK_DIR is /var/lib/insta360-archive/work, which sits on the 50 GB boot
# volume shared with Immich and the OS. On 2026-09-15 a 20 GB batch drove boot
# usage from 24.7% to 68.9% in 45 minutes, and it would have filled outright
# once the channel passed ~35 GB.
#
# A dot-directory inside staging: the media volume has 147 GB, the unit already
# permits writing there, and `"$STAGING_DIR"/*.insv` does not match dotfiles or
# recurse, so the uploader can never mistake a round-trip copy for a new file.
ROUNDTRIP_BASE="${ROUNDTRIP_BASE:-$STAGING_DIR/.roundtrip}"
mkdir -p "$ROUNDTRIP_BASE"

# Sweep scratch left by a run that was killed before its trap could fire.
#
# Belt and braces with the signal traps above: a SIGKILL, an OOM kill or a
# power loss leaves a directory behind regardless of what this script traps.
# Without this sweep that space is never reclaimed, and the next run's disk
# guard sees a volume that looks full for no visible reason.
#
# Each round trip lives in a directory named for its PID, so anything here
# whose PID is not running is finished with. Checked with kill -0 rather than
# by age: a long Check #2 legitimately runs for hours, and a time-based sweep
# would delete the scratch of a healthy concurrent run.
shopt -s nullglob
for stale in "$ROUNDTRIP_BASE"/*; do
  [[ -d "$stale" ]] || continue
  stale_pid="$(basename "$stale")"
  [[ "$stale_pid" =~ ^[0-9]+$ ]] || continue
  if ! kill -0 "$stale_pid" 2>/dev/null; then
    stale_size="$(du -sh "$stale" 2>/dev/null | cut -f1)"
    log "removing stale round-trip scratch from PID $stale_pid (${stale_size:-unknown})"
    rm -rf "$stale"
  fi
done

# Same sweep for the Check #1 hash files, for the same reason: cleanup() removes
# them on every trapped exit, but SIGKILL and OOM run no traps. These are a few
# hundred bytes rather than gigabytes, so this is tidiness rather than a disk
# guard - but an unswept work directory is where stale state accumulates
# unnoticed, and the PID test is already written.
for stale in "$WORK_DIR"/batch-hashes.*; do
  [[ -f "$stale" ]] || continue
  stale_pid="${stale##*.}"
  [[ "$stale_pid" =~ ^[0-9]+$ ]] || continue
  if ! kill -0 "$stale_pid" 2>/dev/null; then
    log "removing stale batch hashes from PID $stale_pid"
    rm -f "$stale"
  fi
done
shopt -u nullglob

# HARD GUARD: refuse to run if the round trip would land on the root
# filesystem.
#
# Relocating the directory is a convention; this makes it a rule. If STAGING_DIR
# or ROUNDTRIP_BASE is ever overridden badly, or /mnt/media fails to mount and
# the path silently resolves under /, this stops the drain instead of filling
# the 50 GB boot disk that Immich and the OS share. That is exactly what
# happened on 2026-09-15, and a comment would not have prevented it.
rt_fs="$(df -P "$ROUNDTRIP_BASE" | awk 'NR==2{print $6}')"
root_fs="$(df -P / | awk 'NR==2{print $6}')"
if [[ "$rt_fs" == "$root_fs" ]]; then
  err "REFUSING: the round-trip directory is on the root filesystem"
  err "  $ROUNDTRIP_BASE resolves to $rt_fs"
  err "Check #2 downloads the WHOLE channel, so this would fill the boot"
  err "volume and take Immich down with it. Is /mnt/media mounted?"
  err "  findmnt /mnt/media"
  exit 1
fi

# rt_dir is now set, so the EXIT trap installed above starts removing it too.
# The trap fires on success, on failure via the ERR trap's explicit exit, and on
# SIGTERM from `systemctl stop`.
rt_dir="$ROUNDTRIP_BASE/$$"
mkdir -p "$rt_dir"

roundtrip_ok=1

# Abort Check #2 if the scratch directory outgrows what it could legitimately
# need, and watch the volume while it runs.
#
# On 2026-09-17 a full-channel download of a 41 GB archive produced 93 GB of
# scratch and drove a 147 GB volume to 91% full - almost certainly because an
# interrupted fetch restarted rather than resumed, accumulating duplicate
# copies. Nothing noticed: the disk guard runs once BEFORE the download and
# never looks again, so a runaway inside Check #2 was invisible until the
# volume was nearly full.
#
# Immich shares this disk. A full volume is a worse outcome than a failed
# verification, and a failed verification is safe - staging is never cleared
# unless Check #2 passes.
roundtrip_watch() {
  local ceiling_bytes="$1" pid="$2" used
  while kill -0 "$pid" 2>/dev/null; do
    sleep 60
    used="$(du -sb "$rt_dir" 2>/dev/null | cut -f1)"
    [[ "$used" =~ ^[0-9]+$ ]] || continue

    if (( used > ceiling_bytes )); then
      err "Check #2 scratch has reached $(( used / 1024 / 1024 / 1024 )) GiB,"
      err "  past the $(( ceiling_bytes / 1024 / 1024 / 1024 )) GiB it should ever need - aborting the download"
      kill "$pid" 2>/dev/null
      return 1
    fi

    # Independent of the ceiling: never let the volume itself run out.
    local avail
    avail="$(df -P "$rt_dir" | awk 'NR==2{print $4}')"
    if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail / 1024 / 1024 < 5 )); then
      err "media volume below 5 GiB free - aborting Check #2 before it fills"
      kill "$pid" 2>/dev/null
      return 1
    fi
  done
}

# Twice the archive plus this batch, with a floor so a small archive still has
# room. Generous: a correct full-channel download needs archive+batch once, so
# reaching double means something is re-fetching rather than resuming.
rt_ceiling=$(( (archive_bytes + batch_bytes / 2) * 2 ))
(( rt_ceiling < 20 * GIB )) && rt_ceiling=$(( 20 * GIB ))

# Run telegram-download under the watchdog. Returns non-zero if the download
# failed OR the watchdog aborted it.
full_channel_download() {
  local dl_pid watch_rc=0
  ( cd "$rt_dir" && telegram-download --from "$TG_CHANNEL" --config "$TG_CONFIG" -m keep >/dev/null 2>&1 ) &
  dl_pid=$!

  roundtrip_watch "$rt_ceiling" "$dl_pid" || watch_rc=1

  wait "$dl_pid" 2>/dev/null || true
  if (( watch_rc )); then
    err "Check #2 aborted - staging is NOT cleared and nothing is deleted"
    return 1
  fi
  return 0
}

# Fetch back ONLY this batch's messages, when every file in it reported ids.
#
# This is the change that stops Check #2 growing without bound. Downloading the
# whole channel cost the size of the ARCHIVE on every batch - ~20 GB at batch 1,
# ~400 GB by batch 10 - and on 2026-09-15 it ran longer than the upload itself,
# filled the boot volume once, and made an interrupted batch re-upload 18.8 GB
# from scratch. Fetching by id costs the size of the BATCH, forever.
#
# The fallback is not a nicety. Files archived before ids were recorded have
# none, and a build whose --print-file-id output this script failed to parse
# would have none either. In both cases the old whole-channel path runs and the
# guarantee is identical - slower, never weaker. Check #2 is the property that
# makes this archive trustworthy, so it degrades rather than skips.
FETCHER="$HERE/tg-fetch-ids.py"
fetch_ids=""

if (( ids_complete )) && [[ -x "$FETCHER" || -r "$FETCHER" ]]; then
  for f in "${batch[@]}"; do
    base="$(basename "$f")"
    fetch_ids+=" ${BATCH_IDS[$base]:-}"
  done
fi

# Run the fetcher with the interpreter that owns Telethon. telegram-upload is
# installed by pipx into its own venv, so the system python3 usually cannot
# import telethon at all - the failure is an ImportError at the wrong moment,
# during verification, after the upload has already been paid for.
PIPX_PY="${PIPX_PY:-$HOME/.local/share/pipx/venvs/telegram-upload/bin/python}"
[[ -x "$PIPX_PY" ]] || PIPX_PY="$(command -v python3 || true)"

if [[ -n "${fetch_ids// /}" ]]; then
  # shellcheck disable=SC2086
  log "Check #2 - fetching ${#batch[@]} file(s) by message id (not the whole channel)"
  if ! ( cd "$rt_dir" && "$PIPX_PY" "$FETCHER" \
           --config "$TG_CONFIG" --channel "$TG_CHANNEL" --into "$rt_dir" \
           $fetch_ids >/dev/null ); then
    err "fetch by message id failed - falling back to a full-channel download"
    full_channel_download || roundtrip_ok=0
  fi
else
  (( ids_complete )) || err "some files reported no message id - using a full-channel download"
  [[ -r "$FETCHER" ]] || err "tg-fetch-ids.py not found beside this script - using a full-channel download"
  log "Check #2 - downloading the whole channel back (slower; grows with the archive)"
  log "  watching scratch, ceiling $(( rt_ceiling / GIB )) GiB"
  full_channel_download || roundtrip_ok=0
fi

if (( roundtrip_ok )); then
  for f in "${batch[@]}"; do
    base="$(basename "$f")"

    shopt -s nullglob
    parts=("$rt_dir/$base".[0-9][0-9]*)
    shopt -u nullglob

    joined="$rt_dir/$base"
    if (( ${#parts[@]} > 0 )); then
      write_phase rejoining "$base" 0 "${#batch[@]}"
      mapfile -t sorted < <(
        for p in "${parts[@]}"; do printf '%s\t%s\n' "${p##*.}" "$p"; done | sort -n -k1,1 | cut -f2
      )
      cat "${sorted[@]}" > "$joined"
      log "  rejoined ${#sorted[@]} part(s) for $base"
    fi

    if [[ ! -f "$joined" ]]; then
      err "$base did not come back - nothing to verify"
      roundtrip_ok=0
      break
    fi

    write_phase verifying "$base" 0 "${#batch[@]}"
    expected="$(awk -v want="$base" '{ n = $NF; sub(/^\*/, "", n); sub(/.*\//, "", n); if (n == want) { print $1; exit } }' "$MANIFEST")"
    actual="$(sha256sum "$joined" | cut -d' ' -f1)"

    if [[ "$actual" != "$expected" ]]; then
      err "ROUND-TRIP MISMATCH: $base"
      err "  expected $expected"
      err "  actual   $actual"
      roundtrip_ok=0
      break
    fi

    log "  round trip verified: $base"
  done
fi

if (( ! roundtrip_ok )); then
  err "Check #2 FAILED - staging NOT deleted, do NOT clear the card"
  exit 1
fi

log "Check #2 passed for all ${#batch[@]} file(s) - clearing staging"
write_phase clearing "" 0 "${#batch[@]}"

# Record what is now in the archive, BEFORE deleting it.
#
# This has to happen here rather than in a wrapper. tg-upload.sh is the only
# thing that knows a file survived the round trip, and it is a supported entry
# point on its own - run it directly and, until now, nothing was recorded at
# all. The ledger then under-reported the archive forever: tg-prune would
# re-send files already in Telegram, and tg-archive status would under-count.
# That is exactly how the first uploaded file came to be invisible.
#
# Reuse Check #1's hash rather than reading every file again.
#
# Check #1 hashed each of these files against the manifest, and nothing can
# have changed since: this script holds the flock for its whole run, and
# staging is cleared a few lines below. The previous comment here argued the
# re-read was free because the file was "already in page cache" - but Check
# #2's multi-gigabyte download sits between the two, and will have evicted it.
# The read is real, and costs a full pass over the batch (~13 min per 27 GiB).
#
# Falls back to hashing when the entry is missing or malformed. A lost
# optimisation must never become a lost or wrong ledger row - the ledger is
# what tg-prune.sh consults before deleting originals from the card.
ledger_hash() {
  local file="$1" base="$2" h=""
  if [[ -n "${BATCH_HASHES:-}" && -r "${BATCH_HASHES:-}" ]]; then
    h="$(awk -v want="$base" '
      { n = $NF; sub(/^\*/, "", n); sub(/.*\//, "", n)
        if (n == want) { print $1; exit } }
    ' "$BATCH_HASHES")"
  fi
  if [[ "$h" =~ ^[0-9a-f]{64}$ ]]; then
    printf '%s' "$h"
  else
    err "no Check #1 hash for $base - re-hashing"
    sha256sum "$file" | cut -d' ' -f1
  fi
}

# Hash the verified file rather than copying the manifest's entry. The manifest
# says what SHOULD be there; this file just proved what IS there, having gone
# to Telegram and come back byte-identical.
for f in "${batch[@]}"; do
  base="$(basename "$f")"
  if ! grep -qF " $base" "$UPLOADED_LOG" 2>/dev/null; then
    # Third column is the size in bytes. Recorded HERE because this is the last
    # moment the file exists - staging is cleared two lines below, and nothing
    # else on the VM keeps a copy. Without it, "how much have I archived" can
    # only be answered by downloading the whole channel back.
    #
    # Rows written before 2026-09-15 have two columns and no size. Every reader
    # must treat a missing third field as unknown rather than zero, or the
    # total silently under-reports.
    #
    # FOURTH column, from 2026-09-16: the Telegram message id(s), space-
    # separated because a split file occupies several messages. This is what
    # lets a later Check #2 - or a future tool - fetch one file back without
    # downloading the entire channel.
    #
    # APPENDED, never inserted. tg-archive.sh reads $2 and $3 positionally and
    # tg-prune.sh matches on $1, so a trailing field is invisible to both;
    # reordering would silently corrupt every one of them. Rows predating this
    # have three fields and no ids, which readers must treat as "unknown", the
    # same rule the size column already established.
    printf '%s %s %s %s\n' \
      "$(ledger_hash "$f" "$base")" "$base" "$(stat -c %s "$f")" \
      "${BATCH_IDS[$base]:--}" \
      >> "$UPLOADED_LOG"
  fi
done
log "recorded ${#batch[@]} file(s) in $(basename "$UPLOADED_LOG")"

for f in "${batch[@]}"; do
  rm -f "$f"
done

log "staging cleared"
log "SAFE TO CLEAR THIS BATCH FROM THE CARD"
hc ""
