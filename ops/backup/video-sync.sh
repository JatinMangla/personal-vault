#!/usr/bin/env bash
#
# Monthly video sync: Oracle -> home external drive, over Tailscale.
#
# Videos are excluded from the restic/Gozunga repository because they are the
# bulk of the gigabytes and will not fit any free tier. They go to a drive at
# home instead.
#
# KNOWN GAP, STATED HONESTLY: videos are unprotected between monthly drive
# connections. If the Oracle box dies three weeks after the last sync, up to
# three weeks of video is gone. The paid alternative is roughly $8/year on
# Backblaze B2. This is a deliberate trade-off to hold the $1/year ceiling, not
# an oversight. It is documented in the README for the same reason.
#
# Runs FROM the home machine (pull), not from the Oracle box (push), because:
#   - the home drive is not always connected, and a push would fail on a timer
#   - the home machine has no inbound ports either
#   - pulling means the Oracle box needs no credentials for the home machine
#
# Usage, on the home machine with the drive mounted:
#   ops/backup/video-sync.sh /media/external/immich-videos

set -euo pipefail

DEST="${1:-}"
REMOTE="${IMMICH_HOST:-immich-mumbai}"
REMOTE_USER="${IMMICH_USER:-ubuntu}"
REMOTE_MEDIA="${REMOTE_MEDIA:-/mnt/media}"

if [[ -z "$DEST" ]]; then
  echo "Usage: $0 <destination-directory>" >&2
  echo "Example: $0 /media/external/immich-videos" >&2
  exit 1
fi

# Refuse to run against a path that is not a mounted drive. Without this check,
# an unmounted drive means syncing onto the root filesystem and quietly filling
# it, while appearing to succeed.
if ! mountpoint -q "$(dirname "$DEST")" && ! mountpoint -q "$DEST"; then
  echo "ERROR: neither $DEST nor its parent is a mountpoint." >&2
  echo "Connect the external drive before running. Refusing to write to the system disk." >&2
  exit 1
fi

mkdir -p "$DEST"

echo "Syncing videos from $REMOTE:$REMOTE_MEDIA -> $DEST"
echo "Started: $(date -Is)"

# --partial --append-verify so an interrupted transfer resumes rather than
# restarting, which matters for multi-gigabyte files over a home connection.
# No --delete: this is an archive. A file removed from Immich should not vanish
# from the only other copy without a deliberate decision.
rsync -avh \
  --progress \
  --partial \
  --append-verify \
  --human-readable \
  --include='*/' \
  --include='*.mp4' --include='*.MP4' \
  --include='*.mov' --include='*.MOV' \
  --include='*.avi' --include='*.AVI' \
  --include='*.mkv' --include='*.MKV' \
  --include='*.webm' --include='*.WEBM' \
  --include='*.m4v' --include='*.M4V' \
  --include='*.3gp' --include='*.3GP' \
  --exclude='*' \
  "${REMOTE_USER}@${REMOTE}:${REMOTE_MEDIA}/upload/" \
  "${REMOTE_USER}@${REMOTE}:${REMOTE_MEDIA}/library/" \
  "$DEST/" 2>&1 | tee -a "$DEST/.sync.log"

echo "Finished: $(date -Is)"
echo
echo "Videos on the external drive: $(find "$DEST" -type f \
  \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.mkv' \) | wc -l)"
echo "Total size: $(du -sh "$DEST" | cut -f1)"
echo
echo "Record this sync date. The dashboard cannot see this drive, so the gap"
echo "between syncs is only visible to you."

# Optional healthcheck ping, if a check is configured for the monthly sync.
if [[ -n "${HEALTHCHECK_VIDEO_UUID:-}" ]]; then
  curl -fsS -m 10 "https://hc-ping.com/${HEALTHCHECK_VIDEO_UUID}" >/dev/null || true
fi
