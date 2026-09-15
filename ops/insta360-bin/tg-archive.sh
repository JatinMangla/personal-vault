#!/usr/bin/env bash
#
# tg-archive - drain the camera card into Telegram, unattended.
#
# This is a WRAPPER. It does not upload anything itself: tg-upload.sh already
# does the hard part (disk guard, flood-wait backoff, Check #1 against the
# manifest, Check #2 round-trip, delete-only-after-verify). This adds the
# three things that were missing:
#
#   the outer loop   - keep draining until the card is done, not one batch
#   pause / resume   - stop cleanly between files, restart where it left off
#   status           - how far through the card are we
#
#   tg-archive start    begin draining; runs until done or paused
#   tg-archive pause    stop after the current batch finishes
#   tg-archive resume   clear the pause flag and continue
#   tg-archive status   done / remaining / staged / running
#   tg-archive stop     stop now, after the current batch
#
# WHY ONE BATCH AT A TIME, NOT ONE FILE.
# tg-upload.sh already treats whatever is in staging as a batch and refuses to
# start one that would breach the disk margin. Re-implementing a per-file loop
# here would duplicate that guard and fight it. The loop simply calls it again
# whenever staging refills, so Syncthing's delivery rate sets the pace and
# staging never holds more than Syncthing has moved.
#
# WHY PAUSE IS CHECKED BETWEEN BATCHES, NOT DURING ONE.
# Killing an upload mid-file leaves a partial object in the channel and a file
# still in staging that Check #2 never confirmed. Waiting for the current batch
# to finish means every pause point is a consistent state: staging is empty and
# everything in it was verified before deletion.

set -euo pipefail

ENV_FILE="${TG_ENV_FILE:-/etc/personal-vault/tg-archive.env}"
if [[ ! -r "$ENV_FILE" ]]; then
  echo "FATAL: cannot read $ENV_FILE" >&2
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

STAGING_DIR="${STAGING_DIR:?STAGING_DIR not set}"
MANIFEST="${MANIFEST:?MANIFEST not set}"
WORK_DIR="${WORK_DIR:-/var/lib/insta360-archive/work}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPLOADER="$HERE/tg-upload.sh"

# State lives beside the work directory, not in /tmp: a reboot must not look
# like "never paused" or "nothing uploaded yet".
PAUSE_FLAG="$WORK_DIR/.paused"
UPLOADED_LOG="$WORK_DIR/uploaded.sha256"
LOOP_LOCK="$WORK_DIR/.loop.lock"

# How long to wait for staging to refill before concluding the card is done.
# Syncthing moves ~1.3 MB/s over OTG, so a large file can take many minutes to
# appear. Two consecutive empty passes this far apart means no more is coming.
IDLE_WAIT_SECONDS="${IDLE_WAIT_SECONDS:-300}"

log() { echo "[$(date -Is)] $*"; }
err() { echo "[$(date -Is)] ERROR: $*" >&2; }

# Drain progress is written to a state file rather than pushed anywhere.
#
# The metrics collector reads it every 15 minutes and the /status dashboard
# renders it, so progress is visible on a phone without SSH and without a
# notification service. A file is the right interface here: this loop runs for
# days, the collector is a separate process on its own timer, and neither
# should have to know the other exists.
STATE_FILE="$WORK_DIR/drain-state"

write_state() {
  local status="$1" total_n done_n remaining_n
  total_n=$(manifest_names | sort -u | wc -l)
  done_n=$(uploaded_names | sort -u | wc -l)
  remaining_n=$(( total_n - done_n ))
  (( remaining_n < 0 )) && remaining_n=0

  local bytes_n unknown_n
  read -r bytes_n unknown_n < <(uploaded_bytes)

  # Written atomically. The collector may read this at any moment, and a
  # half-written file would surface as a wrong number on the dashboard.
  {
    printf 'status=%s\n' "$status"
    printf 'total=%s\n' "$total_n"
    printf 'done=%s\n' "$done_n"
    printf 'remaining=%s\n' "$remaining_n"
    printf 'bytes=%s\n' "${bytes_n:-0}"
    printf 'bytes_unknown=%s\n' "${unknown_n:-0}"
    printf 'updated=%s\n' "$(date +%s)"
  } > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

mkdir -p "$WORK_DIR"
touch "$UPLOADED_LOG"

# --- helpers ---------------------------------------------------------------

staged_count() {
  local n
  shopt -s nullglob
  local files=("$STAGING_DIR"/*.insv)
  shopt -u nullglob
  n=${#files[@]}
  echo "$n"
}

# Every filename the phone fingerprinted, one per line. Same last-field parse
# verify-batch.sh uses, so the two can never disagree about what a manifest
# line means.
manifest_names() {
  [[ -r "$MANIFEST" ]] || return 0
  awk '{ n = $NF; sub(/^\*/, "", n); sub(/.*\//, "", n); if (n != "") print n }' "$MANIFEST"
}

uploaded_names() {
  [[ -r "$UPLOADED_LOG" ]] || return 0
  # Field 2 exactly, not "everything after field 1". The ledger gained a size
  # column on 2026-09-15, and `cut -f2-` would return "NAME SIZE" as the name.
  awk 'NF >= 2 { print $2 }' "$UPLOADED_LOG" 2>/dev/null
}

# Bytes archived, and how many rows could not contribute.
#
# Rows written before the size column exists have two fields. Counting those as
# zero would silently under-report the total, so they are counted separately
# and the dashboard says how many are unknown rather than quietly guessing.
uploaded_bytes() {
  [[ -r "$UPLOADED_LOG" ]] || { echo "0 0"; return; }
  awk '
    NF >= 3 && $3 ~ /^[0-9]+$/ { sum += $3; next }
    NF >= 2                    { unknown++ }
    END { printf "%d %d\n", sum + 0, unknown + 0 }
  ' "$UPLOADED_LOG" 2>/dev/null || echo "0 0"
}

# Record what a completed batch contained. tg-upload.sh deletes staging on
# success and keeps no record of its own, so without this nothing on the VM
# knows how far through the card we are - status could only ever report "what
# is in staging right now".
# NOTE: recording into uploaded.sha256 deliberately lives in tg-upload.sh, not
# here. That script is the one that knows a file survived the round trip, and
# it is a supported entry point on its own - recording in this wrapper meant a
# direct tg-upload.sh run archived files that were never written down. Keeping
# the logic in one place also stops the two copies drifting apart.

paused() { [[ -e "$PAUSE_FLAG" ]]; }

# --- commands --------------------------------------------------------------

cmd_pause() {
  : > "$PAUSE_FLAG"
  log "pause requested - the loop will stop after the current batch"
  log "nothing is interrupted mid-file; resume with: tg-archive resume"
}

cmd_resume() {
  if [[ ! -e "$PAUSE_FLAG" ]]; then
    log "not paused - nothing to resume"
    return 0
  fi
  rm -f "$PAUSE_FLAG"
  log "pause cleared - run 'tg-archive start' to continue draining"
}

cmd_status() {
  local total done_n staged remaining running="no"

  total=$(manifest_names | sort -u | wc -l)
  done_n=$(uploaded_names | sort -u | wc -l)
  staged=$(staged_count)
  remaining=$(( total - done_n ))
  (( remaining < 0 )) && remaining=0

  # A held lock means a loop is live. Ask whether the lock can be ACQUIRED, not
  # whether the lock file exists: the file is never deleted, so testing for its
  # existence reports "running" forever after the first run. If flock itself is
  # unavailable the honest answer is "unknown", not "yes" - claiming a loop is
  # running when none is would stop the operator starting one.
  if command -v flock >/dev/null 2>&1; then
    if [[ -e "$LOOP_LOCK" ]] && ! ( exec 9>"$LOOP_LOCK"; flock -n 9 ) 2>/dev/null; then
      running="yes"
    fi
  else
    running="unknown (flock unavailable)"
  fi

  echo "card total (fingerprinted on the phone) : $total"
  echo "uploaded and round-trip verified        : $done_n"
  echo "remaining                               : $remaining"
  echo "currently in staging                    : $staged"
  echo "loop running                            : $running"
  paused && echo "state                                   : PAUSED"

  if (( total == 0 )); then
    echo
    echo "No manifest entries. MANIFEST=$MANIFEST"
    echo "Generate it on the CARD, before anything moves (stronger - it"
    echo "fingerprints the originals, not a copy of them):"
    echo "  cd /storage/9C33-6BBD/DCIM/tg-batch && sha256sum *.insv > ~/manifest-card.sha256"
    echo "then scp it to \$MANIFEST on this VM."
    echo
    echo "Or on the VM, from what Syncthing delivered:"
    echo "  cd $STAGING_DIR && sha256sum *.insv > $MANIFEST"
  fi
}

cmd_start() {
  if paused; then
    err "paused - run 'tg-archive resume' first"
    exit 1
  fi

  # One loop at a time. tg-upload.sh has its own session lock for the upload
  # itself; this one stops two loops from both waiting on it.
  #
  # Guard only when flock exists. A missing flock must not be reported as
  # "another loop is running" - that reads as a deliberate refusal and would
  # leave the operator hunting a loop that was never there. tg-upload.sh holds
  # its own lock regardless, so concurrent uploads are still impossible; what
  # is lost without flock is only the friendlier early warning.
  if command -v flock >/dev/null 2>&1; then
    exec 8>"$LOOP_LOCK"
    if ! flock -n 8; then
      err "another tg-archive loop is already running"
      exit 1
    fi
  else
    err "flock unavailable - relying on tg-upload.sh's own session lock"
  fi

  [[ -x "$UPLOADER" ]] || { err "not executable: $UPLOADER"; exit 1; }

  log "draining - staging: $STAGING_DIR"
  log "pause any time with: tg-archive pause"
  write_state running

  local pass=0 idle_passes=0 batch

  while true; do
    if paused; then
      log "paused after $pass batch(es) - staging is in a consistent state"
      log "resume with: tg-archive resume && tg-archive start"
      write_state paused
      return 0
    fi

    shopt -s nullglob
    batch=("$STAGING_DIR"/*.insv)
    shopt -u nullglob

    if (( ${#batch[@]} == 0 )); then
      idle_passes=$(( idle_passes + 1 ))
      if (( idle_passes >= 2 )); then
        log "staging empty for two passes - the card appears drained"
        log "run 'tg-archive status' to confirm against the manifest"

        # Report against the manifest, not just "the loop ended". A drain that
        # stopped early because Syncthing stalled looks identical from inside
        # the loop; the remaining count is what distinguishes them.
        local total_n done_n remaining_n
        total_n=$(manifest_names | sort -u | wc -l)
        done_n=$(uploaded_names | sort -u | wc -l)
        remaining_n=$(( total_n - done_n ))
        (( remaining_n < 0 )) && remaining_n=0

        if (( remaining_n == 0 )); then
          log "all $total_n file(s) in the manifest are archived"
          write_state complete
        else
          err "drain ended with $remaining_n file(s) still unarchived"
          err "Syncthing may have stalled, or the card was disconnected early"
          write_state incomplete
        fi

        return 0
      fi
      log "staging empty - waiting ${IDLE_WAIT_SECONDS}s for Syncthing to deliver more"
      sleep "$IDLE_WAIT_SECONDS"
      continue
    fi

    idle_passes=0
    pass=$(( pass + 1 ))
    log "--- batch $pass: ${#batch[@]} file(s) ---"

    # Do NOT let a failed batch kill the loop. tg-upload.sh already refuses to
    # delete anything it could not verify, so a failure leaves staging intact
    # and retrying is safe. Stopping the whole drain because one batch hit a
    # flood-wait ceiling would mean babysitting it again, which is the thing
    # this script exists to avoid.
    if "$UPLOADER"; then
      # tg-upload.sh records the batch in uploaded.sha256 itself, before it
      # clears staging - see the note above cmd_pause.
      log "batch $pass verified and recorded"
      write_state running
    else
      err "batch $pass failed - staging left intact, will retry"
      err "if this repeats, run tg-upload.sh by hand to see the full output"
      sleep 60
    fi
  done
}

cmd_stop() { cmd_pause; }

case "${1:-}" in
  start)  cmd_start  ;;
  pause)  cmd_pause  ;;
  resume) cmd_resume ;;
  status) cmd_status ;;
  stop)   cmd_stop   ;;
  *)
    cat <<USAGE
tg-archive - drain the camera card into Telegram

  tg-archive start     begin draining; runs until done or paused
  tg-archive pause     stop after the current batch finishes
  tg-archive resume    clear the pause flag
  tg-archive status    done / remaining / staged / running
  tg-archive stop      same as pause

Files are uploaded, downloaded back and hashed before staging is cleared.
Nothing is deleted from the card by this script - it prints when a batch is
safe to clear.
USAGE
    exit 1
    ;;
esac
