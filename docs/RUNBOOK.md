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
| Phone → VM throughput | **10–16 MB/s** | direct Tailscale, since 2026-09-15 |
| — before UDP 41641 was opened | ~1.3 MB/s | DERP relay; see `docs/HARD-WON.md` |
| Card → phone copy | ~71 MB/s | 3.2 GB in 45 s — never the bottleneck |
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
Syncthing API   NOT in tg-archive.env - that file holds seven TG_* variables
                and nothing about Syncthing. The key lives in config.xml, at a
                NON-DEFAULT path (newer Syncthing moved it out of ~/.config):
                  /home/ubuntu/.local/state/syncthing/config.xml
                Read it with (no sudo - the file is owned by ubuntu):
                  grep -o '<apikey>[^<]*</apikey>' \
                    ~/.local/state/syncthing/config.xml
                Service: syncthing@ubuntu.service, listening on 127.0.0.1:8384.
                A `CSRF Error` from the API means no valid key reached it -
                the header was missing or malformed, not that the key is wrong.
Folder id       dub20-7j8sw          (current). The earlier ik1hp-qdr83 was
                deleted when the folder was recreated to point at tg-batch
                specifically, rather than the whole dcim directory - which is
                why only tg-batch syncs, and why files must be copied into it.
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

`restore.sh` pulls `.insv` files back out of the channel. Real restores have
passed (`ops/ARCHIVE-RESTORE-LOG.md`).

**Since 2026-09-25 it restores BY LEDGER ID** whenever the ledger
(`uploaded.sha256`) is available: it fetches only each file's recorded
messages, 4 at a time (~14× the old whole-channel rate), in groups of about
20 GB that are verified and cleared before the next, so scratch space stays
small. Every file is checked against the **card hash in the ledger**, so no
separate manifest is needed. `--list` and `--dry-run` read the ledger and need
no network. Without a ledger, or with `--whole-channel`, it downloads the
entire channel as before.

```bash
restore.sh --list                                          # what is archived
restore.sh --into ~/recovered --dry-run                    # what would come back
restore.sh --into ~/recovered                              # everything (VM: ledger found automatically)
restore.sh --into ~/recovered --ledger ~/uploaded.sha256   # on another machine
restore.sh --into ~/recovered VID_001.insv                 # just one file
```

**Where the ledger is when the VM is gone:** the nightly restic backup holds
it (`restic ls latest | grep uploaded.sha256`, see "The ledger" below), and so
does any copy you scp'd to the phone.

**It runs on any machine with Python** — that is the point, because a real
restore happens when the VM is gone. It needs `telegram-upload` installed with
pipx (which brings Telethon and `telegram-download`), the `telegram-upload`
config JSON, the channel id via `--channel` or `TG_CHANNEL`, and ideally the
ledger. It does not need the VM's env file, `/mnt/media`, Syncthing, Immich or
systemd.

It will never delete anything, never overwrite an existing file, and never
report success for a file it could not verify.

### Reading the result line

| Result | Meaning |
|---|---|
| `PASS` | Every restored file matched its card hash (ledger or manifest) byte for byte. |
| `RESTORED (UNVERIFIED)` | Files came back, but some or all were not checked against a card hash. Not a pass. |
| `NOTHING DONE` | Everything was skipped because it already existed. Nothing was verified. **Not a pass.** |
| `FAIL` | A restored file did not match its manifest hash. The file is left in place for inspection. |

The distinctions are deliberate, and follow `ops/RESTORE-LOG.md`'s
`PASS (DB-ONLY)` convention: a partial result must never be mistakable for a
full one. Three bugs in exactly this accounting were caught by testing —
including a run that printed `PASS` having verified precisely zero files.

### Recovering the manifest itself

Verification needs a manifest, and there are two places to make it.

**On the card — the stronger option.** Termux *can* read the card, provided the
volume is named explicitly (`/storage/` itself is denied, but
`/storage/9C33-6BBD/` is not — see `docs/HARD-WON.md`):

```bash
cd /storage/9C33-6BBD/DCIM/tg-batch && sha256sum *.insv > ~/manifest-card.sha256
```

This fingerprints the files **as they are on the card**, before anything moves,
so every later check proves the archive matches the original.

**On the VM — what the pipeline has used so far:**

```bash
cd /mnt/media/tg-staging && sha256sum *.insv > /var/lib/insta360-archive/manifest.sha256
```

This proves the VM copy matches itself, not that it matches the card — a weaker
claim. Syncthing hashes every block it transfers, so the card→VM leg is not
unprotected either way, and the manifest's primary job is the Telegram round
trip, which is unaffected by the choice.

`tg-upload.sh`
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

## The whole routine: connect, move, walk away

With `tg-archive.path` enabled (see below), archiving a batch takes **no
commands at all**:

1. Connect the X4 to the phone
2. Move footage into `tg-batch`
3. Walk away

`tg-archive.path` watches staging and starts the drain two minutes after the
transfer goes quiet. It uploads, verifies each file by round-trip hash, clears
staging, and updates `/status`. Watch progress there, or with
`journalctl -fu tg-archive` on the VM.

**Nothing to type at disconnect time either.** If you unplug mid-transfer,
Syncthing resumes on reconnect and the drain picks up where it stopped.

To force a run rather than wait for the timer:

```bash
ssh immich tg-go          # waits for the sync, then archives everything
```

Everything below is for when something needs inspecting.

```bash
tg-go            # wait for the sync, then archive everything
tg-go --now      # skip the wait, staging is already full
tg-go --status   # what is the state right now, change nothing
```

`tg-go` **appends** to the manifest, never overwrites it. The manifest records
everything that has ever been on the card and `tg-archive status` counts against
it, so overwriting it with just the current batch collapses `total` to the batch
size and makes the drain conclude there is nothing left to do. That mistake cost
a real session on 2026-09-15.

For the `ssh immich` shorthand, put this in `~/.ssh/config` on the phone:

```
Host immich
  HostName 100.88.183.74
  User ubuntu
  IdentityFile ~/.ssh/immich_phone
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

## Draining the card with `tg-archive`

```bash
tg-archive status     # done / remaining / staged / running
tg-archive start      # drain until the card is empty
systemctl stop tg-archive   # stop a runaway drain (safe: nothing unverified
                            # is ever deleted, so the next run retries it)
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

### Optional: prune the card to save re-transfer

**Not required.** `tg-upload.sh` rejects duplicates by hash regardless, so
skipping this never double-archives anything and never loses a file. It costs
only the card→VM transfer for footage already in Telegram — roughly **9 minutes
and 3% battery per 700 MB file**, growing with however much accumulates.

The cheapest fix is no command at all: **delete already-archived files from
`tg-batch` when you next add footage**, while you are in the file manager
anyway. Check `/status` shows `Remaining 0` first, and everything there is safe
to remove.

For the hash-checked version, run this in Termux with the card attached:

```bash
tg-prune            # dry run - what is already archived
tg-prune --apply    # delete those from tg-batch (verified archived first)
```

It fetches the VM's ledger over Tailscale (a few KB), compares it against
`tg-batch`, and deletes files already in the archive so Syncthing never sends
them again. It prints how much transfer it saved. (`--apply --keep` moves them
to a `tg-archived/` sibling instead of deleting.)

**This is where the real saving is.** The VM-side check below prevents a
duplicate reaching Telegram, but by then the file has already crossed the cable
at ~12 MB/s with the phone tethered and draining. Pruning first means those
bytes never move at all.

**The margin is narrower than it looks.** Hashing reads the card at
**20.4 MB/s** — measured with `dd` over OTG on 2026-09-16 — which is about
1.2 GB/min, not the ~3.7 GB/min this section used to claim. That figure was
Syncthing's *scan* rate, and `ops/insta360-bin/tg-prune.sh` records a real bug
caused by conflating the two: a timeout sized from the scan rate would have
aborted precisely the large files it was meant to protect.

So against a ~12 MB/s transfer, hashing is under **2x** faster, not 170x.
Pruning still wins — it saves the transfer *and* the battery drain of staying
tethered, and a file never sent is a file that cannot fail mid-transfer — but
it wins by a sensible margin rather than a free one.

**Prune after each drain, not when the card fills.** The cost scales with
whatever is sitting in `tg-batch`, so pruning while only the newest batch is
there costs minutes; letting several batches accumulate means re-hashing all of
them. This is the single largest saving available and it needs no flags — just
the habit of running it when a drain finishes.

Since 2026-09-16 the dry run **offers to continue** when run interactively:
it prints the list, asks, and on `y` deletes without re-reading the card. Both
passes did identical hashing before that, so a careful operator paid ~31
minutes for an 18.8 GB batch instead of ~15. A piped or scripted run still
exits without deleting.

It compares by name first and only hashes when a name matches, so a reused
filename with new footage is kept, not mistaken for an upload that already
happened.

**`--apply` deletes from `tg-batch`**, and that is the safer option in practice.

The alternative is clearing `tg-batch` by hand, and a person has no hash to
check against — deleting footage that was never uploaded is a real and
unrecoverable mistake. `tg-prune` removes a file only when its SHA-256 appears
in `uploaded.sha256`, which is written only after that file went to Telegram,
came back, and matched byte for byte. Anything it cannot verify is left alone:
a name match with different content is reported and kept.

`--apply --keep` moves to a `tg-archived/` sibling instead, for a batch you want
to hold on the card a while longer. The dry run is the default, and it refuses
to run against any directory not named `tg-batch`.

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

### What guarantees a file uploaded correctly

Nothing leaves staging until the file has made the full round trip and matched
byte for byte. In order, every batch:

1. **Check #1** — every staged file is hashed and compared against the manifest.
   A file not in the manifest, or whose hash differs, **fails the batch**.
2. **Upload** to Telegram, retrying on flood-wait.
3. **Check #2** — the channel is downloaded back, split parts rejoined in
   numeric order, and each file's SHA-256 compared to the manifest again.
4. **Only then** is staging cleared and the file recorded in `uploaded.sha256`.

A single flipped bit anywhere in that path changes the hash, fails Check #2,
leaves staging untouched and prints `ROUND-TRIP MISMATCH`. There is no quality
loss to worry about: `telegram-upload` sends the file as a document, not as
media, so Telegram never re-encodes it. The bytes that come back are the bytes
that went out, or the check fails.

**What this does not prove:** that the copy in `tg-batch` on the card was
identical to what reached staging. That leg is Syncthing's, which hashes every
block it transfers — solid, but not a checksum you control.

In practice that gap is narrow — Syncthing verifies every block it sends, and
the card copy is never modified by anything here.

**It matters most when you clear `tg-batch` by hand.** Deleting by eye means
deciding without a hash, and removing footage that was never archived is the
one unrecoverable mistake in this system. So check `/status` reads
`Remaining 0` first; everything in `tg-batch` is then provably in Telegram.

`tg-prune --apply` is the same decision made with the hashes: it deletes only
what it has matched against `uploaded.sha256` and keeps anything it cannot
verify, reporting `same name, different content - keeping` when a filename was
reused. Optional, but it is the safer way to empty the folder.

Use `--apply --keep` to move files to a `tg-archived/` sibling instead of
deleting — for a batch you would rather hold on the card until you have
restored something from it and seen the file open.

### The ledger — the only record of what is archived

`uploaded.sha256` is the **sole source of truth** for what has already been
archived. `tg-upload.sh` on the VM reads it on every batch, and the optional
`tg-prune` on the phone reads it too; neither consults anything else.

It lives at `/var/lib/insta360-archive/work/uploaded.sha256`. **Since
2026-09-24 the nightly restic job backs it up** (with `manifest.sha256`) to
Oracle Object Storage, encrypted, at idle I/O priority. Check it landed:

```bash
# [VM] short check - the nightly run logs what it included
journalctl -t immich-backup --since yesterday | grep 'archive ledger'
```

To prove it is in the snapshot itself, not just that the job tried:

```bash
# [VM]
sudo bash -c 'set -a; . /etc/personal-vault/ops.env; set +a
  export RESTIC_REPOSITORY="s3:https://${OCI_NAMESPACE}.compat.objectstorage.${OCI_REGION}.oraclecloud.com/${OCI_BUCKET}"
  export RESTIC_PASSWORD_FILE=/root/.restic-pass AWS_ACCESS_KEY_ID="$OCI_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$OCI_SECRET_KEY"
  restic ls latest' | grep -E '(uploaded|manifest)\.sha256'
```

That copy shares the Oracle tenancy with the VM. A second copy off Oracle is
still worth having; the manual one is:

```bash
# [PHONE] in Termux, occasionally
scp -i ~/.ssh/immich_phone \
  ubuntu@100.88.183.74:/var/lib/insta360-archive/work/uploaded.sha256 \
  ~/ledger-backup.sha256
```

**Losing it costs bandwidth, not footage.** Everything staged would be
re-uploaded: duplicates in the channel, and on a 250 GB archive, days of
transfer at ~12 MB/s. The files themselves stay safe in Telegram.

A wrong line is as bad as a missing file — a bad hash means that file
re-uploads. Keep the backup somewhere that is neither the phone nor the VM.

### If the backup repository passes the free tier

`/status` shows backup **failed**, and the journal says `repository at N MiB of
10240 MiB free tier ... Refusing to grow it`. On 2026-09-17 the nightly job
swept up ~69 GB of drain staging (fixed since: `tg-staging` and `*.insv` are
excluded) and the repository reached **71 GB**. Oracle can delete every object
in the tenancy if it is over the limit when the Free Trial ends, so shrink it.

**Deploy the fixed `immich-backup.sh` first.** Otherwise the next 03:00 UTC
run, now under the limit, backs staging up all over again.

```bash
# [VM] one helper for this shell session - restic with the backup's settings
r() { sudo bash -c 'set -a; . /etc/personal-vault/ops.env; set +a
  export RESTIC_REPOSITORY="s3:https://${OCI_NAMESPACE}.compat.objectstorage.${OCI_REGION}.oraclecloud.com/${OCI_BUCKET}"
  export RESTIC_PASSWORD_FILE=/root/.restic-pass AWS_ACCESS_KEY_ID="$OCI_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$OCI_SECRET_KEY" AWS_DEFAULT_REGION="$OCI_REGION" RESTIC_CACHE_DIR=/var/lib/personal-vault/restic-cache
  exec restic "$@"' restic "$@"; }

r version                  # needs 0.15+ for rewrite (Ubuntu 24.04 ships 0.16)
r unlock                   # clears only stale locks left by a killed run
r rewrite --forget --exclude /mnt/media/tg-staging --exclude '*.insv'
r prune                    # deletes the unreferenced footage - the slow part
r stats --mode raw-data    # expect a few hundred MiB again
```

`rewrite --forget` keeps every snapshot and its database dumps; it removes
only the footage from them. Then trigger a run to confirm, and check `/status`:

```bash
# [VM]
sudo systemctl start immich-backup.service; journalctl -u immich-backup -n 5 --no-pager
```

### Keep Check #2's scratch out of Syncthing

`/mnt/media/tg-staging` is the Syncthing folder (receive-only), and Check #2
downloads into `tg-staging/.roundtrip`. Receive-only means those files are
never *sent* to the phone, but Syncthing still scans and hashes every GB of
them on the drain's disk. One line, once:

```bash
# [VM]
echo '/.roundtrip' > /mnt/media/tg-staging/.stignore
```

This is not the "VM-side .stignore" that HARD-WON warns against: that one
filtered files the phone sends. `.roundtrip` exists only on the VM.

Since 2026-09-25 `tg-archive` maintains this itself at the start of every
drain, adding `/.roundtrip`, `/.parts.*` and `/.hold` when missing.

### When a file will not pass Check #2: the automatic parts fallback

Telegram occasionally stores a few 1 MiB blocks of an upload that it then
never serves back, and an identical re-upload lands on the same blocks
(`docs/REVIEW-2026-09-24.md`). Since 2026-09-25 the drain handles it itself:

1. Check #2 judges **each file on its own**. Files that verify are recorded and
   cleared; a file that fails stays staged and is logged in
   `$WORK_DIR/check2-failures`.
2. After a file has failed **twice**, `tg-archive` hands it to
   `tg-upload-parts.sh`. That uploads 64 MiB parts, verifies each by
   download, shifts any part that keeps failing by 4 KiB, and records the file
   only when every part verified. The next pass clears it from staging as usual.
3. If even that fails, the file moves to `tg-staging/.hold/`, **is not
   archived, and stays on the card** (`tg-prune` never deletes an unrecorded
   file). The drain carries on with everything else. Watch for it:

```bash
# [VM]
ls -la /mnt/media/tg-staging/.hold/ 2>/dev/null; journalctl -u tg-archive | grep -E "parts|hold" | tail
```

Failed upload attempts leave dead copies in the channel. List them from the
journal (`did NOT verify ... safe to delete`) and remove them with
`tg-delete-ids.py`, which refuses any id the ledger uses.

### The archive scrub: is every stored block still readable?

`tg-scrub.py` runs nightly (`tg-scrub.timer`, 21:30 UTC). For 30 minutes it
probes one request per 1 MiB block of the messages the ledger points at,
resuming where it stopped, so the whole archive is re-checked about every two
weeks. It **reads only**, never slows a drain (it skips when one runs, and
steps aside within a second when one starts), and reports to `/status` as
"Archive scrub".

```bash
# [VM] install once, after rsyncing ops/ to /opt:
sudo cp /opt/personal-vault/ops/systemd/tg-scrub.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now tg-scrub.timer
# run one now (30 min), and see what it found:
sudo systemctl start --no-block tg-scrub.service
journalctl -u tg-scrub -n 20 --no-pager
cat /var/lib/insta360-archive/work/scrub-state.json
```

**If it reports unreadable blocks,** the files are named in
`scrub-state.json` (`bad[]`): their ledger rows point at copies that can no
longer be restored in full. Simply re-staging the file does NOT help, because
the drain sees the name in the ledger and discards it as already archived. With
the original in hand (on the card, copied to the VM), re-archive it deliberately:

```bash
# [VM] drain stopped; N = the file's name, F = the original's path
L=/var/lib/insta360-archive/work/uploaded.sha256; B=$L.bak-$(date +%Y%m%d%H%M%S)
cp -p "$L" "$B"                                   # keep the old row, in case
awk -v n="$N" '$2 != n' "$B" > "$L"               # drop just that file's row
/opt/insta360-archive/bin/tg-upload-parts.sh "$F" # re-archive as verified parts
# then delete the old, damaged message ids (listed in the backup's row) with
# tg-delete-ids.py - they are no longer in the ledger, so it will allow it
```

Once the card is wiped, an unreadable block cannot be fixed from this side;
that is why the scrub runs while the originals may still exist.

### ⚠️ Protect the Telegram account — it holds the only copy of the footage

The originals leave the card once archived, so the channel is the footage.
It is lost if the **account** is lost: a SIM-swap takeover, Telegram's
inactivity self-destruct, or a ban. Three settings, all free, none of them
touching the pipeline or its speed. In the Telegram app:

- [ ] **Settings → Privacy and Security → Two-Step Verification → on.** A
      cloud password stops a SIM-swap or a stolen login code from being enough.
- [ ] **Settings → Privacy and Security → "If away for" (delete my account) →
      the longest period offered.** The default can delete a quiet account,
      and its channels, in months.
- [ ] **Add a second account you control as an admin of the archive channel.**
      A channel whose only admin is deleted cannot be administered again.

Also note: the session file on the VM (`/var/lib/insta360-archive/tg.session`)
is a full login to this personal account. Anyone with root on the VM can read
every chat, not just the channel. Tailscale-only access is what protects it.

### Watching the drain from your phone

`tg-archive` writes its progress to `$WORK_DIR/drain-state` as it runs. The
metrics collector picks it up every 15 minutes and `/status` renders it, so a
multi-day drain can be watched from a browser without SSH.

```
status=idle|running|complete|incomplete
total=34              # files fingerprinted in the manifest
done=21               # verified into Telegram
remaining=13
bytes=13421772800     # summed from the ledger's size column
bytes_unknown=1       # archived rows with no recorded size
updated=<unix timestamp>
```

The dashboard card shows files done/remaining, a progress meter, total bytes
archived, and an estimated transfer time for what is left — computed from the
average size actually archived and the measured ~12 MB/s direct-link rate
(10–16 MB/s since UDP 41641 was opened), rather than
a guess. `bytes_unknown` above zero means the byte total is a lower bound, and
the card says so.

`status` distinguishes finishing from giving up. A drain that stopped because
Syncthing stalled or the cable was pulled looks identical from inside the loop —
two empty passes either way — so the remaining count is what separates them.

The dashboard figure is up to 15 minutes old. For the live number, use
`tg-archive status` on the VM.

### State files, under `WORK_DIR`

| File | Meaning |
|---|---|
| `uploaded.sha256` | Every file verified by Check #2. This is what `status` counts, and what both duplicate checks read. |

`uploaded.sha256` has three space-separated columns:

```
<sha256>  <filename>  <bytes>
```

The size column was added 2026-09-15. Rows written before that have **two**
columns and no size — every reader treats a missing third field as *unknown*
rather than zero, so the archived-bytes total on `/status` is reported as a
lower bound (`12.4 GB+`) while any such rows remain. Parse the filename as
field 2 exactly, never as "everything after field 1".
| `drain-state` | Written by `tg-archive` as it runs; the collector reads it for `/status`. |
| `.loop.lock` | Held while a loop runs. The file persists; only the lock matters. |

`uploaded.sha256` exists because `tg-upload.sh` clears staging on success and
keeps no history of its own — without it nothing on the VM knows how far
through the card you are.

### Starting the drain automatically

With these enabled, files landing in staging start a drain on their own — no
command at all on the VM side:

```bash
sudo cp ~/personal-vault/ops/systemd/tg-archive.{path,service} \
       ~/personal-vault/ops/systemd/tg-archive-settle.timer \
       /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now tg-archive.path
```

`tg-archive.path` watches `/mnt/media/tg-staging` and activates
`tg-archive-settle.timer`, which waits **two minutes of quiet** before starting
the drain. The delay matters: `PathChanged` fires on every write, so going
straight to the service would begin uploading on the first byte, while the card
is still copying — both legs then compete for the same connection and the batch
takes longer overall.

Every file that lands re-arms the timer, so a long multi-file transfer keeps
pushing the deadline out and the drain begins only once the card has finished.
Repeated activation is harmless: `tg-archive` holds a `flock`, and a second
invocation exits with "another tg-archive loop is already running".

Check it:

```bash
systemctl status tg-archive.path
journalctl -fu tg-archive          # follow a drain as it happens
```

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
