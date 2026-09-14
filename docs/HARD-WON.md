# Hard-won facts

Everything in this file was discovered by hitting a wall, not by reading docs.
Each entry cost real time in the sessions of 2026-09-12 to 09-15. A later
session that reads this first will avoid repeating them.

**Read this before touching Syncthing, telegram-upload, or the VM.**

---

## Syncthing

### The config is NOT in ~/.config

```
/home/ubuntu/.local/state/syncthing/config.xml
```

`~/.config/syncthing/config.xml` **does not exist** on this box. Newer Syncthing
moved to `.local/state`. Time lost chasing the old path: ~10 minutes.

Find it generically:
```bash
sudo find / -name config.xml -path '*syncthing*' 2>/dev/null
```

Read the API key (no sudo needed — owned by `ubuntu`):
```bash
grep -o '<apikey>[^<]*</apikey>' ~/.local/state/syncthing/config.xml
```

### Current values

```
Folder id   dub20-7j8sw
Listens on  127.0.0.1:8384      (verified: ss -tlnp | grep 8384)
Service     syncthing@ubuntu.service
Phone id    OJKKRMK-ZT2LZBV-E7PJ7WF-X4KQNPT-XKVYLXV-5IQY26R-6T3S5ZF-HAAHYAA
VM id       3WQ6PHP-4GGA3FY-MMODA7B-DKAHCKD-65CLUOE-XTP7TW7-YMNCQPY-IF7USQ4
```

The API key is deliberately **not** written here — hard rule 2 in `CLAUDE.md`
forbids committing anything key-shaped. Read it from `config.xml` with the
command above. It worked repeatedly: it accepted the device pairing, created
the folder, and returned folder status.

A `CSRF Error` means the header did not arrive, **not** that the key is wrong.
Test with:

```bash
K="$(grep -o '<apikey>[^<]*</apikey>' ~/.local/state/syncthing/config.xml \
     | sed 's/<[^>]*>//g')"
curl -s -H "X-API-Key: $K" http://127.0.0.1:8384/rest/system/version
```

**`ik1hp-qdr83` is dead.** That was the first folder id, deleted when the folder
was recreated to point at `tg-batch` instead of the whole `dcim` directory. Any
document still referencing it is stale.

### The web UI is effectively unreachable from the phone

Syncthing binds to localhost. Tunnelling to it (`ssh -L 8384:127.0.0.1:8384`)
**fails in practice**:

- Port 8384 is already taken on the phone by the Syncthing app itself → use
  8385 locally
- Android suspends Termux when you switch to the browser, killing the tunnel

**Use the REST API instead.** Every operation below was done that way, with no
browser at all.

### REST recipes that work

```bash
K="$(grep -o '<apikey>[^<]*</apikey>' ~/.local/state/syncthing/config.xml \
     | sed 's/<[^>]*>//g')"
F="dub20-7j8sw"

# Folder state — the most useful single call
curl -s -H "X-API-Key: $K" "http://127.0.0.1:8384/rest/db/status?folder=$F" \
  | grep -oE '"(state|needFiles|needBytes|globalFiles|localFiles)":[^,]*'

# Is the phone connected?
curl -s -H "X-API-Key: $K" http://127.0.0.1:8384/rest/system/connections \
  | python3 -m json.tool | grep -A6 'OJKKRMK' | grep -E 'connected|paused'

# Real progress indicator (see gotcha below — do NOT use du)
curl -s -H "X-API-Key: $K" http://127.0.0.1:8384/rest/system/connections \
  | python3 -m json.tool | grep inBytesTotal

# Pause / resume — NOTE: /rest/db/pause does NOT exist, returns 404
curl -s -X PATCH -H "X-API-Key: $K" -H "Content-Type: application/json" \
  -d '{"paused":true}' http://127.0.0.1:8384/rest/config/folders/$F

# Pending device / folder offers
curl -s -H "X-API-Key: $K" http://127.0.0.1:8384/rest/cluster/pending/devices
curl -s -H "X-API-Key: $K" http://127.0.0.1:8384/rest/cluster/pending/folders

# Accept a device
curl -s -X POST -H "X-API-Key: $K" -H "Content-Type: application/json" \
  -d '{"deviceID":"<ID>","name":"oppo-phone"}' \
  http://127.0.0.1:8384/rest/config/devices

# Accept a folder as receive-only
curl -s -X POST -H "X-API-Key: $K" -H "Content-Type: application/json" \
  -d '{"id":"<FID>","label":"tg-batch","path":"/mnt/media/tg-staging","type":"receiveonly","devices":[{"deviceID":"<PHONE-ID>"}]}' \
  http://127.0.0.1:8384/rest/config/folders
```

**A successful POST/PATCH returns an empty body.** Silence is success, not
failure. Verify separately.

### grep against Syncthing JSON silently truncates

The API pretty-prints with a space after the colon, so `grep -o '"paused":[a-z]*'`
prints `"paused":` and nothing more. This wasted time twice, once making a
correctly-created folder look like it had failed.

Use `grep -A1 paused`, or pipe through `python3 -m json.tool`.

### `du` under-reports during transfer

Syncthing preallocates sparse `.syncthing.*.tmp` files. `du -sh` showed 2.8 GB
while the API's `inBytesTotal` showed 3.05 GB, and `du` appeared frozen across
two checks while transfer was in fact progressing.

**Use `inBytesTotal` to judge progress.** `du` is for final sizes only.

### `.stfolder` is mandatory

Without it the folder sits in `state: error` with:

> folder marker missing (this indicates potential data loss...)

```bash
sudo -u ubuntu mkdir -p /mnt/media/tg-staging/.stfolder
```

**The error state is cached** — creating the marker is not enough on its own.
Either force a rescan or `sudo systemctl restart syncthing@ubuntu`. A rescan
alone did not clear it; the restart did.

`rm -rf` on the staging directory removes the marker too. Recreate it.

### Folder paths cannot be edited

The Android app will not let you change an existing folder's path. You must
**delete the folder entry and recreate it** — which mints a **new folder id**,
so the VM side must be deleted and re-accepted as well.

This is how `ik1hp-qdr83` became `dub20-7j8sw`.

### The nesting trap — watch for this signal

Files arriving at `/mnt/media/tg-staging/Camera01/` rather than directly in
`tg-staging` means **the phone's folder root is wrong** — it is set to the parent
directory, not the intended subfolder.

The real root cause here: the folder was pointed at
`/storage/9c33-6bbd/dcim` (the whole card's DCIM) instead of
`/storage/9c33-6bbd/dcim/tg-batch`. Consequences:

- `needFiles` grew without limit — 5 → 24 → 31 files, 13GB → 39GB → 50GB
- Every `.insv` on the card was queued for transfer
- The scripts glob `tg-staging/*.insv` and saw nothing

**Nesting is the symptom; a wrong folder root is the cause.** Do not patch
around it with `mv` — fix the root.

---

## telegram-upload

### It is PATCHED BY HAND. Never upgrade it.

Ubuntu 24.04 ships Python 3.12, which removed `distutils` (PEP 632).
telegram-upload 0.7.1 **and current git master** still import it:

```
ModuleNotFoundError: No module named 'distutils'
```

Python 3.11 is **not** in noble's repos, so `pipx install --python python3.11`
is not an option (`E: Unable to locate package python3.11`).

**The fix that worked:**

```bash
F=~/.local/share/pipx/venvs/telegram-upload/lib/python3.12/site-packages/telegram_upload/client/telegram_manager_client.py
cp "$F" "$F.bak"
sed -i 's/from distutils.version import StrictVersion/from packaging.version import Version as StrictVersion/' "$F"
pipx inject telegram-upload packaging
```

Both steps are required — the sed alone yields
`ModuleNotFoundError: No module named 'packaging'`.

> **NEVER run `pipx upgrade telegram-upload`.** It silently reverts the patch
> and uploads begin failing mid-archive. If reinstalled, reapply both steps.

### There is no `--version` flag

`Error: No such option '--version'` **is a working install** — it proves the
import chain loaded and argument parsing ran. Verify with `--help` instead.

### Flags that do NOT exist

Written from memory in the first draft, all wrong, all caught by research:

| Assumed | Reality |
|---|---|
| `--split-file-size` | **No such flag.** Split size is fixed at the account max: 2000 MiB user / 4000 MiB premium |
| `--directory` (download) | **No such flag.** Output lands in the working directory — `cd` first |
| `--files` (download) | **No such flag.** No filename filter, no glob, no message-id selector |
| `--config` = session file | It is a **JSON config file**, not a session |

### Config shape

No environment variables exist for credentials. Everything lives in JSON:

```json
{
  "api_id": 1234567,
  "api_hash": "...",
  "session": "/var/lib/insta360-archive/tg"
}
```

The `session` value has **no `.session` extension** — Telethon appends it.

**First-run auth cannot be automated.** A human must enter a phone number and a
login code (delivered in the Telegram app, not by SMS) once. After that the
session file carries the auth.

**Only one process may use a session at a time** — a second gets
`database is locked`. `tg-upload.sh` serializes itself behind a `flock`.

### The design consequence that shaped everything

Because `telegram-download` can only fetch a **whole chat**, every verification
and every restore pulls the entire channel. Observed 2026-09-14: three
invocations in a row each re-downloaded the same 19 MB. At 200 GB a single
`--list` becomes an hours-long operation.

**The fix for a future session:** `--print-file-id` on upload, recorded per
file, then fetch back that single message with Telethon. That makes **one
channel work forever** and removes the unbounded cost.

### Do not use `-m join`

Its reassembly sorts parts lexicographically (`.10` before `.2`), hardcodes a
2-digit part width (breaking past 100 parts), and its "integrity check" compares
a file count to the highest suffix then **silently returns**. No checksums
anywhere.

Both scripts use `-m keep` and rejoin numerically against SHA-256 instead.
Verified still true 2026-09-15: `tg-upload.sh:202` and `restore.sh:137`.

---

## systemd

Two failures on the first real run, both now fixed — **keep these if the unit is
ever rewritten**:

**1. The service could not read its own config**

```
FATAL: cannot read /etc/personal-vault/tg-archive.env
```

The file was `0600 root:root` but the unit runs `User=ubuntu`:

```bash
sudo chown root:ubuntu /etc/personal-vault/tg-archive.env
sudo chmod 640 /etc/personal-vault/tg-archive.env
```

**2. `telegram-upload` was not found**

```
ERROR: telegram-upload missing
```

systemd's default PATH excludes `~/.local/bin`, where pipx installs. Add to
`[Service]`:

```
Environment=PATH=/home/ubuntu/.local/bin:/usr/local/bin:/usr/bin:/bin
```

**3. `ProtectHome=read-only`, never `true`** — inherited from the sibling restic
job, which failed claiming a file did not exist while it was plainly readable to
root. The Telethon session file would hit the same wall.

---

## The phone (Oppo Reno 10x Zoom, Android 12, ColorOS)

### Measured, not estimated

| Thing | Value |
|---|---|
| Card → VM throughput | **~1.3 MB/s** (3 GB in ~40 min) |
| Battery drain, X4 attached | **1% / 3.3 min** → ~4.7h usable |
| Scan speed | **~3.7 GB/min** |
| Wifi upload | 125 Mb/s — **not** the bottleneck |

The bottleneck is the OTG read plus Syncthing hashing, **not** the internet.
A 135GB batch would take ~30 hours of connected transfer, not the 2.4 hours line
speed suggests. **Size batches at 10–20GB**, one charge each.

### Termux cannot read the SD card

`~/storage/external-0` and `external-1` are **both empty**. Android's scoped
storage does not expose OTG devices to terminal apps, even after
`termux-setup-storage`. `/storage/` itself is `Permission denied`.

Re-confirmed 2026-09-15 with the X4 physically connected and
`termux-setup-storage` re-run: both symlinks still empty. **This is settled.
Do not write phone-side scripts that touch the card** — a `tg-prune.sh` was
written on that assumption and deleted the same day.

**Consequence: the manifest cannot be generated on the phone.** It is generated
on the VM from what arrives instead:

```bash
cd /mnt/media/tg-staging && sha256sum *.insv > /var/lib/insta360-archive/manifest.sha256
```

Weaker in principle — it proves the VM copy matches itself, not the card. In
practice Syncthing already hashes every block it transfers, so the card→VM leg
has its own integrity check. The manifest's real job is the Telegram round trip,
which is unaffected.

### Things that are impossible, confirmed by research

- **Charging while OTG-hosting.** In host mode the phone asserts power *out* on
  VBUS; a charger asserts power *in*. The ACA workaround needs a kernel flag
  (`aca_enable=Y`) stock Android does not set; SimulCharge adapters are
  Samsung-specific. **Do not buy a cable hoping.**
- **Using the iPad Air M3 to ingest.** iPadOS claims any device exposing `DCIM`
  for Photos rather than mounting it in Files; iOS Syncthing clients cannot
  reach external volumes through the sandbox; Files.app copies stop when
  backgrounded.
- **rclone under Termux reading OTG** — needs root.

### ColorOS specifics

**OTG switches off after ~10 minutes** of perceived inactivity, with no
supported way to disable it without an unlocked bootloader. An active transfer
*should* count as activity — unverified, and the most likely cause of a silently
dead long sync. **Watch the first hour.**

**Five battery settings, all required**, or background sync dies:
allow background running · allow auto start-up · lock in the recents tray ·
enable in Security Center startup manager · accept the doze exemption.
dontkillmyapp confirms there is "no known solution on the dev end" — code cannot
defeat this, only settings.

### SSH from Termux drops constantly

`client_loop: send disconnect: Broken pipe` is routine. Mitigate with
`termux-wake-lock` before long sessions and:

```
Host immich
  HostName 100.88.183.74
  User ubuntu
  IdentityFile ~/.ssh/immich_phone
  ServerAliveInterval 30
  ServerAliveCountMax 6
```

Note the key is `immich_phone` with an **underscore**, and it lives on the
**phone**, not on the VM. Running an `scp -i ~/.ssh/immich_phone ...` command
while already SSH'd into the VM fails with "Identity file not accessible" —
that command belongs in Termux.

---

## Pasting scripts through a phone terminal corrupts them

With Bash and Edit blocked, scripts had to be dictated. **Termux silently ate
`||` operators** — three separate times, in different chunks:

```
[[ -d "$DIR" ]]  { err "..."; exit 1; }      # the || is gone
```

`nano` was worst. `cat > file << 'ENDOFCHUNK'` in ~40-line chunks was far more
reliable, but still lost one operator.

A **fourth** survivor was found on 2026-09-14 in `tg-upload.sh` line 28:
`>/dev/null  true` instead of `>/dev/null || true`. `bash -n` cannot catch that
one — it is valid shell that passes `true` to `curl` as a second URL. Under
`set -e` a failed healthcheck ping would then abort the upload run, so the
dead-man's switch could take down the job it exists to watch.

**Always run `bash -n` after any dictated paste**, then grep for the silent
variant:

```bash
grep -nE ']] +[{]|null +[{]|>/dev/null +[a-z]' /path/to/script.sh
```

Repair:

```bash
sed -i 's/\]\] \+{/]] || {/' file
sed -i 's|>/dev/null \+{|>/dev/null \|\| {|' file
sed -i 's#>/dev/null  true#>/dev/null || true#' file
```

**If a future session has Write available, write the file locally and have the
user `scp` it** — Tailscale is not installed on the Windows machine (office
laptop, no installs permitted), so that path was unavailable here. From
2026-09-14 the working route is: write on the laptop, commit, push, then
`git pull` on the VM.

---

## Current state, as of 2026-09-15

**The pipeline works, and the archive has been restored from twice.**

```
VM              ssh -i ~/.ssh/immich_phone ubuntu@100.88.183.74   (from Termux)
Channel         -1004430700436 (insta-store-backup)   PRIVATE, verified
Card path       /storage/9c33-6bbd/dcim/tg-batch      (copies, not originals)
Staging         /mnt/media/tg-staging                 (145 GB free of 147)
Scripts         /opt/insta360-archive/bin/
Env             /etc/personal-vault/tg-archive.env    (root:ubuntu 640)
TG config       /var/lib/insta360-archive/telegram-upload.json
```

**`restore.sh` now exists and has PASSED twice** against the real channel —
2026-09-14 at 15:35 and 18:10, both byte-identical to the manifest. Logged in
`ops/ARCHIVE-RESTORE-LOG.md`. It had never existed when the note above was
written; "restore.sh has never run" was misread as "exists but untested".

**Still untested:** split-part rejoining against a real multi-gigabyte upload
(both test files arrived whole), and whether a restored file opens in Insta360
Studio — **blocked on hardware, there is no laptop or Mac.**

**Three things the user must not lose**, kept off both the phone and the VM:
each batch's manifest, the channel-id list, and the telegram-upload patch note.
Telegram has no restore path — the manifest catches corruption, nothing catches
loss.
