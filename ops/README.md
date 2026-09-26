# `ops/` — Components C and D: backup, restore and monitoring

> ## ⚠️ THE RESTIC PASSWORD MUST BE STORED OFF THIS MACHINE
>
> **Losing the restic password is identical to losing the backup.** restic
> encrypts client-side; there is no recovery path, no support ticket, and no
> reset. Oracle holds ciphertext they cannot decrypt either.
>
> Store it in **at least two** places that are not the Oracle VM:
>
> - the paper emergency kit, `docs/EMERGENCY-KIT.md`, in two buildings
> - an encrypted copy in the document vault (`vault/`), which runs on Vercel +
>   Supabase, not Oracle
>
> **Never keep it only in a password manager hosted on this VM** (the planned
> Vaultwarden, `docs/VAULTWARDEN-PLAN.md` C4). If the VM is lost, that password
> manager and the backup this password unlocks are lost together.
>
> Do not record the value anywhere in this repository, and do not store it only
> in `/root/.restic-pass` on the box being backed up — a machine failure would
> take the password with it.

---

## What lives here

```
ops/
├── backup/
│   ├── immich-backup.sh     Nightly restic -> Oracle OS. Excludes derived data.
│   ├── restore-test.sh      The P3 gate. Proves the backup actually restores.
│   └── video-sync.sh        Monthly pull to a home external drive.
├── metrics/
│   └── collect-and-push.sh  Every 1 min, outbound push to Vercel.
├── monitoring/
│   └── healthcheck-setup.md Dead-man's switch configuration.
├── vaultwarden/             The family password manager's backup, drill and alive check
│   ├── vaultwarden-backup.sh       02:30: consistent dump + encrypted off-Oracle copy
│   ├── vaultwarden-restore-test.sh The Vaultwarden drill: both copies, PASS/FAIL
│   └── vaultwarden-alive.sh        Every 5 min: alive, HTTPS, config.json, free space
├── systemd/                 Services and timers for all of the above.
├── RESTORE-LOG.md           Appended by restore-test.sh. The audit trail.
└── VAULTWARDEN-RESTORE-LOG.md Appended by vaultwarden-restore-test.sh.
```

Vaultwarden itself is deployed from `infra/vaultwarden/`; its operations,
including installing these timers, are in `docs/VAULTWARDEN-RUNBOOK.md`.

## Installation on the VM

```bash
sudo mkdir -p /opt/personal-vault /etc/personal-vault /var/lib/personal-vault
sudo rsync -a ops/ /opt/personal-vault/ops/
sudo chmod +x /opt/personal-vault/ops/backup/*.sh /opt/personal-vault/ops/metrics/*.sh

# Secrets live here, readable only by root, never in the repository.
sudo install -m 0600 /dev/null /etc/personal-vault/ops.env
sudo editor /etc/personal-vault/ops.env    # see .env.example at the repo root

# The restic password, mode 0600. Also store it OFF this machine (see above).
sudo install -m 0600 /dev/null /root/.restic-pass
sudo editor /root/.restic-pass

sudo cp ops/systemd/*.service ops/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now immich-backup.timer metrics-push.timer

systemctl list-timers 'immich-backup*' 'metrics-push*'
```

## What is backed up, and what is deliberately not

| Directory | Backed up | Why |
|---|---|---|
| `upload/` | yes | Originals from mobile and browser — irreplaceable |
| `library/` | yes | Originals under the storage template engine |
| `profile/` | yes | Avatars, negligible size |
| `backups/` | **yes — critical** | Immich's own Postgres dumps |
| `thumbs/` | no | Derived; Immich regenerates on demand |
| `encoded-video/` | no | Derived; the original is never removed |
| `*.mp4`, `*.mov`, … | no | Bulk of the gigabytes; goes to the home drive |

Also in every nightly snapshot, from outside `/mnt/media`:

| Path | Why |
|---|---|
| `uploaded.sha256`, `manifest.sha256` | The Insta360 ledger: the only record of what Telegram holds |
| `/var/lib/vaultwarden/{backups,attachments,sends}`, `rsa_key*` | The password vault's consistent 02:30 dumps. Never the live `db.sqlite3`, whose `-wal` makes a mid-write copy unsafe |

Excluding the two derived directories is the entire reason the repository fits
inside Oracle's ~10 GiB free tier — it only ever holds originals. Immich's own
template backup script excludes exactly these two.

**The database is not optional.** Immich stores every file path, album, face
cluster and piece of metadata in Postgres and does not rescan the library folder
to rediscover them. Restoring media without the database yields a heap of
undifferentiated files. Because Immich writes its dumps into
`UPLOAD_LOCATION/backups`, one snapshot captures both halves atomically — which
is why the backup runs at 03:00, one hour after Immich's 02:00 dump.

## The restore drill

```bash
sudo /opt/personal-vault/ops/backup/restore-test.sh
```

Restores into a throwaway Docker environment on an isolated network, then
verifies:

1. Media files restore and checksums match the live copies
2. The Postgres dump restores without error
3. Immich starts and the library, albums and face clusters are present

**The project is not complete until this has passed at least once.** Re-run it
quarterly. Every run appends to `RESTORE-LOG.md`, and the dashboard turns amber
at 90 days since the last drill and red at 180.

Two things about the drill are worth knowing in advance:

- It recreates the `.immich` marker files in `thumbs/` and `encoded-video/`.
  A fresh Immich checks for these and can refuse to start; since those
  directories are excluded from backup they do not exist after a restore.
- After a real restore, Immich regenerates thumbnails and transcodes through its
  job queue. On 2 ARM cores over ~100 GB this takes **one to two days**. That is
  expected, not a failure.

## The known gap, stated honestly

**Videos are unprotected between monthly drive connections.**

They are excluded from the restic repository because they are the bulk of the
gigabytes and will not fit any free tier. If the Oracle box dies three weeks
after the last sync, up to three weeks of video is gone.

The paid alternative is roughly **$8/year on Backblaze B2**. This is a deliberate
trade-off to hold the $1/year ceiling, not an oversight. If the video archive
ever becomes more valuable than $8/year, take the B2 option.

`video-sync.sh` runs **from the home machine** (a pull), not from the Oracle box,
because the drive is not always connected, the home machine has no inbound ports
either, and pulling means the Oracle box needs no credentials for it.

## Monitoring

`healthchecks.io` is a dead-man's switch on both timers. It catches the failure
mode that otherwise goes unnoticed for months: **the job silently stopping**.
A backup nobody is watching is a backup that is not running.

The backup script pings `/start` before running, the bare URL on success, and
`/<exit-code>` on failure — so an alert says what broke, not merely that
something did.

See `monitoring/healthcheck-setup.md`.

## Metrics collection

`collect-and-push.sh` runs every minute and POSTs **outbound** to the Vercel
ingest endpoint. The Oracle box has no inbound ports and keeps it that way, so
the dashboard can never query it — the box pushes instead. That is also the
ceiling on freshness: `/status` is near-live, never realtime, because Vercel
cannot reach the VM even over Tailscale.

Authentication is HMAC-SHA256 over the exact JSON body, with a timestamp inside
the signed payload; the server rejects anything older than 5 minutes to prevent
replay.

The collector reads backup state from files written by the nightly job rather
than invoking restic itself. A 1-minute timer must be fast and must not contend
for the repository lock.

**Three things move together** and changing one alone breaks the dashboard:

| | |
|---|---|
| `systemd/metrics-push.timer` | `OnUnitActiveSec=1min`, and `AccuracySec=1s` or arrivals are erratic |
| `vault/lib/thresholds.ts` | `stalenessState()` — amber 5 min, red 15 min |
| `.github/workflows/prune-metrics.yml` | nightly, or 1-minute samples fill the 500 MB Supabase tier in ~2 years |

The collector also reports **Syncthing** (`sync` block: folder state, bytes and
files still to arrive, whether the phone is connected) and the drain's current
**phase**, which is what lets `/status` show two separate cards for card → VM
and VM → Telegram. Reading the Syncthing API key needs
`ProtectHome=read-only` in `metrics-push.service`; under `ProtectHome=true` the
key is invisible and the block reports `state: "unknown"` with no error.

### Retention

`metrics_samples` keeps **30 days**, pruned nightly by
`.github/workflows/prune-metrics.yml`, which calls `prune_metrics_samples()`
with the **service-role** key — the function is `security definer` and revoked
from public, so the anon key silently deletes nothing.

Until 2026-09-16 no such workflow existed and retention was unbounded: the
function had never been called once. Invisible at one sample per 15 minutes;
~245 MB/year at one per minute, against a 500 MB tier shared with the vault's
own tables.

**On Immich's storage endpoint:** it reports the whole underlying disk rather
than Immich's own consumption. The collector computes the real breakdown with
`du` and passes the API figure through as `api_disk_figure`. The dashboard must
never display that number as "Immich usage".

## Routine checks

```bash
# Timers active and next run times
systemctl list-timers 'immich-backup*' 'metrics-push*'

# Last backup run
journalctl -u immich-backup.service -n 50

# Snapshots
sudo restic -r "s3:https://$OCI_NAMESPACE.compat.objectstorage.$OCI_REGION.oraclecloud.com/$OCI_BUCKET" snapshots

# Full integrity check (slow; the nightly job reads a 1% subset)
sudo restic -r "s3:https://$OCI_NAMESPACE.compat.objectstorage.$OCI_REGION.oraclecloud.com/$OCI_BUCKET" check --read-data
```
