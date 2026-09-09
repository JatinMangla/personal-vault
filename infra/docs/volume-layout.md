# Volume layout

Two volumes, 200 GB total, which is the entire Always Free block-storage
allowance. There is no headroom for a third.

| Volume | Size | Tier | Mount | Contents |
|---|---|---|---|---|
| Boot | 50 GB | Balanced (default) | `/` | OS, Docker images, `DB_DATA_LOCATION` |
| Block | 150 GB | **Lower Cost (0 VPU)** | `/mnt/media` | `UPLOAD_LOCATION` — all Immich media |

## Why Postgres lives on the boot volume

Postgres wants low-latency random I/O. The block volume is deliberately
provisioned at 0 VPU, which is tuned for large sequential reads — the right
choice for streaming video and the wrong one for a database's random access
pattern. Splitting them puts each workload on the storage that suits it and
costs nothing extra.

It also means the media volume can be detached, resized or restored without
touching the database, and the two never compete for the same I/O queue.

## Why the block volume stays at 0 VPU

VPUs bill separately from capacity, at roughly **$0.0017 per VPU per GB-month**.

| Tier | VPU | Monthly cost for 150 GB |
|---|---|---|
| Lower Cost | 0 | $0.00 |
| Balanced | 10 | ~$2.55 |
| High Performance | 20 | ~$5.10 |

The annual budget is $1.00. A single click raising the tier to Balanced costs
about $3/month — thirty-six times the entire yearly allowance. This is the most
expensive mistake available in the console, and it is two clicks away from the
volume detail page.

## Directory layout under `/mnt/media`

```
/mnt/media/
├── upload/          originals from mobile and browser      BACKED UP
├── library/         originals under the storage template   BACKED UP
├── profile/         avatars, negligible size               BACKED UP
├── backups/         Immich's own Postgres dumps            BACKED UP  ← critical
├── thumbs/          previews and face thumbnails           excluded
└── encoded-video/   transcoded copies                      excluded
```

`thumbs/` and `encoded-video/` are excluded from backup because they are derived
data that Immich regenerates on demand, and they are a large fraction of total
bytes. Immich's own template backup script excludes exactly these two. This
exclusion is the entire reason the backup fits inside Gozunga's 100 GB free
tier: the repository only ever holds originals.

`backups/` is **not** optional. Immich stores every file path, album, face
cluster and piece of user metadata in Postgres and does not scan the library
folder to rediscover them. Restoring media without the database yields a heap of
undifferentiated files with no organisation. Because Immich writes its dumps
into `UPLOAD_LOCATION/backups`, one restic snapshot of `/mnt/media` captures both
halves atomically.

### The restore trap

A fresh Immich instance checks for a `.immich` marker file in each of these
directories and can fail to start if one is missing. Since `thumbs/` and
`encoded-video/` are excluded from the backup, they will not exist after a
restore. `ops/backup/restore-test.sh` recreates them:

```bash
mkdir -p thumbs encoded-video
touch thumbs/.immich encoded-video/.immich
```

Immich then regenerates the derivatives through its job queue. On 2 ARM cores
over roughly 100 GB this takes one to two days. That is expected, not a failure.

## Capacity expectations

Roughly **120–130 GB** of originals fit in the 150 GB volume once thumbnails
(3–5%) and encoded video are accounted for.

Storage is the binding constraint of this entire system, which is why:

- video transcoding is set to "not browser-compatible only", never "all" —
  transcoding everything can add 40%+ on top of the originals
- HEIC is never converted to JPEG — HEIC is about half the size at equivalent
  quality, and originals should never be re-encoded

The `/status` dashboard projects days-until-full from a linear fit over the last
30 days of samples, so this stops being a surprise.

## Mount options

```
LABEL=immich-media /mnt/media ext4 defaults,noatime,nofail 0 2
```

- `noatime` — without it every read writes back an access time, which is pure
  waste on a media library and consumes block-volume write bandwidth
- `nofail` — a missing or slow-attaching volume must not stop the host from
  booting, or a bad attach leaves the box unreachable with no console access
- mounted by `LABEL`, not by device path — iSCSI device ordering is not
  guaranteed stable across reboots
