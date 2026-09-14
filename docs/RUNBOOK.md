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
                (that key is on the PHONE, not on the VM - from the VM itself
                you are already logged in and need no key)
Syncthing API   NOT in the env file. Verified 2026-09-14: tg-archive.env
                contains no api/sync entry at all. The key lives only in
                Syncthing's own config.xml - find it with:
                  sudo find / -name config.xml -path '*syncthing*' 2>/dev/null
                then read <apikey> from that file.
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

## Restoring from the archive

`restore.sh` pulls `.insv` files back out of the channel. Written 2026-09-14;
**it has still never been run against the real archive.** Until it has, the
recovery half of this system is tested only against fixtures.

```bash
restore.sh --list                                  # what is in the channel
restore.sh --into ~/recovered --dry-run            # what would come back
restore.sh --into ~/recovered --manifest ~/card.sha256
restore.sh --into ~/recovered VID_001.insv         # just one file
```

**It runs on any machine with Python** — that is the point, because a real
restore happens when the VM is gone. It needs `telegram-download`, the
`telegram-upload` config JSON, and the channel id via `--channel` or
`TG_CHANNEL`. It does not need the VM's env file, `/mnt/media`, Syncthing,
Immich or systemd.

It will never delete anything, never overwrite an existing file, and never
report success for a file it could not verify.

### Reading the result line

| Result | Meaning |
|---|---|
| `PASS` | Every restored file matched the manifest byte for byte. |
| `RESTORED (UNVERIFIED)` | Files came back, but some or all were not checked against a manifest. Not a pass. |
| `NOTHING DONE` | Everything was skipped because it already existed. Nothing was verified. **Not a pass.** |
| `FAIL` | A restored file did not match its manifest hash. The file is left in place for inspection. |

The distinctions are deliberate, and follow `ops/RESTORE-LOG.md`'s
`PASS (DB-ONLY)` convention: a partial result must never be mistakable for a
full one. Three bugs in exactly this accounting were caught by testing —
including a run that printed `PASS` having verified precisely zero files.

### Recovering the manifest itself

Verification needs the manifest, which is generated on the phone. `tg-upload.sh`
uploads a copy after each batch as `manifest-<timestamp>.sha256`, so it is
usually recoverable from the archive:

```bash
restore.sh --list                                        # find the newest one
restore.sh --into ~/recovered manifest-20260914T....sha256
restore.sh --into ~/recovered --manifest ~/recovered/manifest-20260914T....sha256
```

Manifest copies are excluded from a bulk restore — no manifest lists itself, so
they can never verify — but they restore normally when named explicitly.

### Tested for real — `PASS` on 2026-09-14

A real file was restored from the real channel and verified byte-identical to
what left the card. Logged in `ops/ARCHIVE-RESTORE-LOG.md`.

**Two things that run did not prove**, both still open: split-part rejoining
against a genuine multi-gigabyte upload (the test file arrived whole, with no
parts), and whether a restored file actually opens in Insta360 Studio. Re-run
after the next batch containing a large file.

Re-run the drill periodically, and after any change to `tg-upload.sh` or
`restore.sh`. Any machine with Python will do — do not wait for the Mac.

```bash
pipx install telegram-upload        # see the distutils warning at the top
restore.sh --list                   # does the channel answer at all?
restore.sh --into /tmp/drill --dry-run

# The real test. Into an EMPTY directory, with a manifest.
restore.sh --into /tmp/drill --manifest /path/to/card.sha256
```

**The result line is the assertion.** Only `PASS` means every restored file was
byte-identical to what left the card; the script has already done the hashing.
Restore into an empty directory — `NOTHING DONE` means everything was skipped
and nothing was checked.

Two things the script cannot tell you, so check them yourself:

1. **Does the file actually open** in a player or Insta360 Studio? A correct
   sha256 proves the bytes survived, not that the format is usable.
2. **Does a multi-gigabyte file survive?** Split-part rejoining is exercised by
   fixtures, but never yet on a real 12-part upload over a real connection.

Then record the outcome with a date, the way `ops/RESTORE-LOG.md` does — and
keep its convention of a distinct string for a partial result. If you verified
a small file but not a large one, say so rather than writing a bare `PASS`.

---

## Draining the card with `tg-archive`

```bash
tg-archive status     # done / remaining / staged / running
tg-archive start      # drain until the card is done, or paused
tg-archive pause      # stop after the current batch finishes
tg-archive resume     # clear the pause flag
```

`start` keeps calling `tg-upload.sh` while staging refills, and exits after two
consecutive empty passes (`IDLE_WAIT_SECONDS`, default 300, between them).
Nothing is deleted from the card by any of this — the uploader prints
`SAFE TO CLEAR THIS BATCH FROM THE CARD` once a batch has round-tripped.

**Pause is checked between batches, never mid-file.** Killing an upload midway
would leave a partial object in the channel and a file in staging that Check #2
never confirmed. Waiting for the current batch means every pause point is a
consistent state.

**A failed batch does not stop the loop.** `tg-upload.sh` never deletes what it
could not verify, so retrying is safe. If a batch keeps failing, run
`tg-upload.sh` by hand to see the full output.

### Re-syncing the same file does not re-upload it

Syncthing re-delivers whatever sits in the phone's `tg-batch` folder, so files
already archived arrive again the moment the card is reconnected. `tg-upload.sh`
drops them before uploading: if a staged file's **hash** is already in
`uploaded.sha256`, it is deleted from staging and skipped.

```
already archived, removing from staging: VID_001.insv
skipped 1 file(s) already in the archive
```

Matched by hash, not filename. A file reusing an old name with new content
still uploads, and says so loudly:

```
ERROR: VID_001.insv is recorded as archived but the content differs - uploading it
```

So you can leave files in `tg-batch` and add new ones alongside them. Only the
new ones cost bandwidth. Clearing the phone folder is a tidiness choice, not a
requirement.

### State files, under `WORK_DIR`

| File | Meaning |
|---|---|
| `uploaded.sha256` | Every file verified by Check #2. This is what `status` counts. |
| `.paused` | Present means paused. `resume` deletes it. |
| `.loop.lock` | Held while a loop runs. The file persists; only the lock matters. |

`uploaded.sha256` exists because `tg-upload.sh` clears staging on success and
keeps no history of its own — without it nothing on the VM knows how far
through the card you are.

### Installing it

```bash
sudo rsync -a ~/personal-vault/ops/insta360-bin/ /opt/insta360-archive/bin/
sudo chmod +x /opt/insta360-archive/bin/*.sh
sudo ln -sf /opt/insta360-archive/bin/tg-archive.sh /usr/local/bin/tg-archive

# Optional: run it as a service instead of in a terminal.
sudo cp ~/personal-vault/ops/systemd/tg-archive.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start tg-archive      # journalctl -fu tg-archive to watch
```

The `chmod` is not optional — `rsync -a` has dropped the executable bit here
before, giving `203/EXEC`.

## Routine checks

```bash
# What staging is holding right now, and real free space on the volume.
df -h /mnt/media && du -sh /mnt/media/tg-staging/

# Both are also on the /status dashboard, but that figure is up to 15 minutes
# old: the collector pushes every 15 min and the page refreshes every 7. Use
# the dashboard to decide what to move; use df when you need the live number.
```
