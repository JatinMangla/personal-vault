# Runbook — Insta360 card → Telegram archive

Operational notes for the drain pipeline. Written down because they exist
nowhere else: the scripts live on one VM and are in no repository, and the
patch note below was never recorded during the session that produced it.

---

## ⚠️ Never run `pipx upgrade telegram-upload`

**It silently reverts a patch the uploader cannot run without.**

Ubuntu 24.04 ships Python 3.12, which removed `distutils` (PEP 632).
telegram-upload 0.7.1 and git master still import it, and Python 3.11 is not in
noble's repositories. The fix was to rewrite the import to
`packaging.version.Version` and run `pipx inject telegram-upload packaging`.

A backup of the original file is at `<file>.bak`.

An upgrade reinstalls the unpatched source. Nothing warns you; the next upload
simply fails on an import error. If that happens, re-apply the rewrite and
re-inject `packaging`.

---

## Measured facts

From the first successful end-to-end run, 2026-09-14 11:53 UTC — a 185 MB file
went card → phone → VM → Telegram → downloaded back → hash-verified → staging
cleared. These are measurements, not estimates, and they are what the drain
loop is sized against.

| Thing | Value | Source |
|---|---|---|
| Card → VM throughput | ~1.3 MB/s | 3 GB in ~40 min over OTG + Tailscale |
| Battery drain with X4 attached | 1% / 3.3 min (~4.7 h usable) | observed |
| Scan speed | ~3.7 GB/min | 37 GB in ~10 min |
| VM free space | 145 GB of 147 GB | `df -h /mnt/media` |
| Telegram upload | 185 MB in ~23 s | first successful run |
| Total to move | ~250 GB | the card |

Syncthing **resumes scanning correctly** after the cable is pulled and
reattached. Scanning is not the risk.

**The risk is that Syncthing has no transfer size limit.** Pointed at all
250 GB it would fill `/mnt/media` and starve Immich. The disk guard protects
the *upload*, not the *sync*. That is the whole reason a drain loop is needed
rather than just pointing Syncthing at the card.

---

## Live configuration

```
VM              ssh -i ~/.ssh/immich_phone ubuntu@100.88.183.74
Syncthing API   see SYNCTHING_API_KEY in /etc/personal-vault/tg-archive.env
Folder id       dub20-7j8sw          (was ik1hp-qdr83, deleted)
Phone device    OJKKRMK-ZT2LZBV-E7PJ7WF-X4KQNPT-XKVYLXV-5IQY26R-6T3S5ZF-HAAHYAA
Channel         -1004430700436 (insta-store-backup)
Card path       /storage/9c33-6bbd/dcim/tg-batch
Staging         /mnt/media/tg-staging
Scripts         /opt/insta360-archive/bin/
Env             /etc/personal-vault/tg-archive.env   (root:ubuntu 640)
TG config       /var/lib/insta360-archive/telegram-upload.json
```

The Syncthing API key is deliberately **not** recorded here. It is a live
credential, and committing it would break hard rule 2 in `CLAUDE.md`. It lives
in the env file above.

### Two fixes the first run needed

Keep both if the systemd unit is ever rewritten:

- `/etc/personal-vault/tg-archive.env` must be **`root:ubuntu 640`**. The
  service runs as `User=ubuntu` and cannot read a root-only `0600` file.
- The unit needs `Environment=PATH=/home/ubuntu/.local/bin:...`, because
  systemd's default PATH excludes `~/.local/bin` and `telegram-upload` is
  otherwise not found.

---

## Testing `restore.sh` — do this before trusting the archive

**`restore.sh` has never been run.** It is the half that matters in a year: the
script that turns Telegram messages back into editable `.insv` files.

This project already holds its photo backups to the standard that *a backup
that has never been restored is a hypothesis* (see `ops/RESTORE-LOG.md`). The
Telegram archive is under exactly the same rule, and currently fails it.

Test it on any machine with Python. Do not wait for the Mac.

1. **Pick a file whose hash you already have** — one archived during a real
   run, with its fingerprint recorded in the manifest at upload time. A restore
   you cannot check against a known value proves nothing.
2. **Fresh virtualenv**, on any machine with Python and network access.
   Install only what `restore.sh` declares it needs.
3. **Run it against that single message id**, writing into an empty scratch
   directory.
4. **Hash the output and compare.** `sha256sum` the restored file against the
   manifest value. **This is the assertion** — everything else is setup.
5. **Confirm it is a real `.insv`**: the size matches, and it opens in a player
   or in Insta360 Studio.
6. **Record the result with a date**, in the format `ops/RESTORE-LOG.md` uses.

### Use a distinct result string for a partial test

`ops/RESTORE-LOG.md` records `PASS (DB-ONLY)` when only the database half of a
restore was exercised, precisely so a partial drill can never later be mistaken
for a full one. Borrow that convention here. If you verify a small file but not
a multi-gigabyte one, or verify the download but not that the file opens, say
so in the result string rather than writing a bare `PASS`.

---

## Routine checks

```bash
# What staging is holding right now, and real free space on the volume.
df -h /mnt/media && du -sh /mnt/media/tg-staging/

# Both are also on the /status dashboard, but that figure is up to 15 minutes
# old: the collector pushes every 15 min and the page refreshes every 7. Use
# the dashboard to decide what to move; use df when you need the live number.
```
