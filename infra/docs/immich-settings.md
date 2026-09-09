# Immich post-install settings

These are configured once in the Immich web UI after the admin account exists.
They are not in `docker-compose.yml` because Immich stores them in its database,
not in environment variables.

Reach the UI at `http://<tailscale-ip>:2283` from a device on the tailnet.

## Mandatory settings

### Video transcoding — "not browser-compatible only"

Administration → Settings → Video Transcoding → **Transcode policy**.

Set to **"Videos higher than target resolution or not in an accepted format"**
(Immich's default). Do **not** set "All videos".

Storage is the binding constraint on this system, not playback smoothness.
Transcoding everything can add 40%+ on top of the originals, taken directly out
of the 150 GB reserved for media. Modern phone video is usually already
browser-compatible, so most files are left untouched.

### Do not convert HEIC to JPEG

Administration → Settings → Image Settings.

Leave the original format untouched. HEIC is roughly half the size of JPEG at
equivalent quality, and re-encoding an original is lossy and irreversible. The
web UI serves generated thumbnails for browsing; the originals stay as shot.

### Enable duplicate detection

Administration → Settings → Machine Learning → **Duplicate Detection** → enable.

Worth it on a personal archive that has accumulated through several phone
migrations and ad-hoc folder copies.

### Enable automatic database backups

Administration → Settings → Backup Settings.

- Enable automatic database dumps
- Schedule: **02:00** daily
- Keep the last 7 dumps

Dumps land in `UPLOAD_LOCATION/backups/`. The restic job runs at **03:00**, one
hour later, so every nightly snapshot contains a database dump that is at most
an hour old and captured atomically alongside the media it describes.

This is the setting that makes a restore produce an actual photo library rather
than a directory of unsorted files.

### Create a read-only API key for the metrics collector

Account Settings → API Keys → New API Key.

Grant **only**:
- `server.statistics`
- `server.storage`
- `server.about`

Do not reuse an admin key. The collector runs unattended on a timer, and its key
only needs to read three numbers. Put the value in `/etc/personal-vault/ops.env`
on the VM (mode 0600), never in the repository.

## Recommended settings

### Machine learning

Leave CLIP semantic search and facial recognition enabled — they are the reason
Immich is worth deploying rather than using a folder of files.

On 2 ARM cores the initial run over an existing library takes a long time
(a day or more for ~100 GB). It runs in the background through the job queue and
does not block uploads. The ML container is CPU-capped in `docker-compose.yml`
so a large smart-search job cannot make the rest of the box unresponsive.

### Storage template

Administration → Settings → Storage Template.

Enabling it moves originals into a readable `library/{{y}}/{{y-MM-dd}}/` layout
rather than opaque UUID paths. Useful if you ever need to find a file without
Immich running — which is exactly the situation a restore drill simulates.

Both `upload/` and `library/` are included in the backup, so this is safe to
enable either way.

### Do not install Watchtower or any auto-updater

Immich ships breaking changes, including irreversible database migrations. An
unattended container upgrade is a plausible way to corrupt a library that has no
second copy of its database. The image tags in `docker-compose.yml` are pinned
for this reason.

Upgrading is a deliberate act:

1. Read the release notes for **every** version between current and target
2. Run a manual backup and confirm it completed
3. Bump `IMMICH_VERSION` in `infra/.env`
4. `docker compose pull && docker compose up -d`
5. Watch the logs until migrations finish

## Verification after setup

The P2 acceptance criteria:

- [ ] Photo uploads from the official Immich app succeed over Tailscale
- [ ] Face recognition returns results (needs the ML job queue to have run)
- [ ] Semantic search returns sensible results for a plain-language query
- [ ] `docker compose ps` shows all four services healthy
- [ ] A database dump exists in `/mnt/media/backups/` after 02:00
