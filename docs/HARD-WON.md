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

### Ignore patterns cannot stop the transfer from the VM side

Verified 2026-09-15. The endpoint works:

```bash
curl -s -H "X-API-Key: $K" "http://127.0.0.1:8384/rest/db/ignores?folder=dub20-7j8sw"
# {"error":null,"expanded":null,"ignore":null}
```

**But setting it here saves nothing.** The VM's folder is `receiveonly`, so a
`.stignore` on the VM makes the VM *discard* what the phone sent — the bytes
have already crossed the link at ~12 MB/s and the battery is already
spent. The cost being optimised away is the cost already paid.

Only an ignore list on the **phone's** folder prevents transmission, and the
Android app keeps its config in private storage:

```bash
find /data/data/com.nutomic.syncthingandroid \
     /sdcard/Android/data/com.nutomic.syncthingandroid -name config.xml
# returns nothing - unreadable from Termux
```

So phone-side patterns must be typed into the app's folder settings by hand.

**The simpler answer is to delete the files from `tg-batch`.** It holds copies,
never originals, and `tg-upload.sh` prints `SAFE TO CLEAR THIS BATCH FROM THE
CARD` at exactly the moment it is safe. Fewer taps than maintaining a growing
ignore list, and no filename-only failure mode — `.stignore` matches names, so
a reused filename carrying new footage would be silently skipped forever.

Note the phone runs its own Syncthing on 8384 too: a `curl` from Termux to
`127.0.0.1:8384` returns a redirect to the Android app's web UI. That is the
phone's API, not the VM's — running the VM's command in Termux hits the wrong
machine and the config path does not exist there.

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

### The one flag that DOES exist, and was checked

| Flag | Status |
|---|---|
| `--print-file-id` (upload) | **Real.** Verified 2026-09-16 with `telegram-upload --help \| grep -i file-id` on the VM before a line of code was written. Output format is **not** documented — see the anchored-parser note above |

The rule this table exists to enforce: **run `--help` on the VM before writing
against a flag.** Four of the five flags ever assumed here were fictional, and
the fifth was real but shaped differently than expected.

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

**DONE 2026-09-16.** `--print-file-id` on upload, recorded as a fourth column in
`uploaded.sha256`, then fetched back with `tg-fetch-ids.py` (Telethon). Check #2
now costs the size of the **batch** rather than the size of the **archive**, and
one channel works forever.

The flag was **verified before any code was written** —
`telegram-upload --help | grep -i file-id` on the VM — because the table below
records four flags that were assumed from memory and did not exist. It is the
one flag in this document confirmed against the installed build rather than
inferred.

Two properties that must survive any rewrite:

- **The full-channel download is still there, as a fallback.** Files archived
  before 2026-09-16 have no ids, and a build whose output the parser fails to
  recognise yields none either. Both cases take the old slow path. Check #2 is
  what makes this archive trustworthy, so it degrades rather than skips.
- **The id column is APPENDED, never inserted.** `tg-archive.sh` reads `$2` and
  `$3` positionally and `tg-prune.sh` matches on `$1`; a trailing field is
  invisible to both, and reordering would silently corrupt all three readers.

### The parser is anchored, and here is the bug that forced it

`--print-file-id` exists but its output **format is undocumented**, so the first
draft accepted any run of ≥5 digits bounded by non-digits. A fixture test caught
what that does to a real filename:

```
VID_20260210_061658_00_135.insv   ->   20260210
```

An underscore is a non-digit boundary, and `telegram-upload` echoes filenames.
Check #2 would have fetched a message id **harvested from a date** — the
silently-wrong id, which is far worse than a missing one: a missing id only
triggers the slow fallback, while a wrong one fetches the wrong bytes and could
fail a verification that should have passed.

An id must now be the **entire line**, or follow an explicit label. Fixtures
live in `ops/insta360-bin/test-extract-ids.sh` and **must be kept in sync with
`extract_ids()`** — if the two drift, the test passes while the parser is wrong,
which is worse than no test.

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

**This has now bitten three units.** `metrics-push.service` hit it on
2026-09-16: the collector reads the Syncthing API key from
`/home/ubuntu/.local/state/syncthing/config.xml`, and under `ProtectHome=true`
that file is simply invisible. There is no error — `sync_key()` returns empty,
the sync block reports `state: "unknown"` forever, and nothing says why.

**The diagnostic:** if `payload->'sync'->>'state'` is `null` or `unknown` while
Syncthing is plainly running, it is this and not the API key.

**4. `AccuracySec=1s` on any timer under ~5 minutes.** systemd defaults to
`AccuracySec=1min`, which lets it coalesce timers anywhere inside that window to
save wakeups. On the 1-minute `metrics-push.timer` that makes arrivals erratic —
gaps of two minutes, then two pushes seconds apart — and the dashboard's
staleness banner then fires on a collector that is perfectly healthy. Harmless
at 15 minutes, which is why it was never needed before.

---

## The phone (Oppo Reno 10x Zoom, Android 12, ColorOS)

### The 1.3 MB/s is Tailscale RELAYING, not the OTG card

Measured 2026-09-15, and it overturns the earlier assumption in this file that
"the bottleneck is the OTG read plus Syncthing hashing".

Three measurements settle it:

| Test | Result |
|---|---|
| Copy 3.2 GB card → phone internal storage | **45 seconds (~71 MB/s)** |
| Syncthing from the **card** | ~1.3 MB/s |
| Syncthing from **internal storage** | ~1.26 MB/s |

The source makes no difference, and the card itself is **55× faster** than what
Syncthing achieves. So it is neither the card, the reader, nor the cable.

```
$ tailscale status
100.104.203.100  oppo-reno-10x-zoom  android  active; relay "blr", tx 147466604 rx 3775874024

$ tailscale ping 100.104.203.100
pong ... via DERP(blr) in 71ms     (x10)
direct connection not established
```

**Every byte archived before 2026-09-15 went through Tailscale's Bangalore DERP
relay.** DERP is a fallback to keep connections alive when NAT traversal fails;
it is deliberately rate-limited and is not meant for bulk transfer.

The VM was never the problem — `tailscale netcheck` reported `UDP: true`,
`IPv4: yes, 152.67.1.135:36985`, `MappingVariesByDestIP: false`. A public IP
with consistent NAT mapping is the easy side of a handshake. The phone is
behind CGNAT or symmetric NAT (common on Indian consumer ISPs) with no
reachable address to punch back to, and WiFi does not change that.

### FIXED: open UDP 41641 inbound on the VM

One reachable end is enough — the phone dials in to the side that is reachable.
Added as an OCI ingress rule (`0.0.0.0/0`, UDP, port 41641). Result, immediate:

```
$ tailscale status
100.104.203.100  oppo-reno-10x-zoom  android  active; direct 38.254.161.78:45974

$ tailscale ping 100.104.203.100
pong from oppo-reno-10x-zoom (100.104.203.100) via 38.254.161.78:45974 in 39ms
```

Direct on the **first** ping, where the relayed path took ten attempts and then
gave up. Latency halved too: 39 ms against 69-116 ms.

**Measured throughput: 10-16 MB/s, up from ~1.3.** 250 GB goes from ~53 hours
to about 5.

**No `ufw` change was needed.**
`infra/ansible/roles/hardening/tasks/main.yml:121` has opened `41641/udp` since
day one, with a comment naming this exact failure: *"Without this, Tailscale
still works but falls back to a relay (DERP), which adds latency to every photo
and video byte."* The host firewall anticipated it. Only the OCI security list
blocked it — almost certainly collateral from bulk-deleting ingress rules
rather than a decision anyone made.

### What P1 actually proved, and what it did not

The claim was "nmap zero open ports — VERIFIED from outside", against 22, 80,
443, 2283, 111, 3000, 5432, 8080.

**`nmap -Pn -p-` scans TCP only.** `nmap -sU` was never run, so the UDP surface
was never verified closed — it was assumed closed, then written up in wording
broader than the test behind it. Opening 41641 does not falsify a measurement;
it falsifies a sentence that was always wider than its evidence. P1 is now
narrowed to "zero open **TCP** ports", which was owed regardless.

Behind the port is WireGuard: encrypted, authenticated, and it drops packets
without a valid key without replying, so a scan often cannot confirm it is
listening. Reversible in two minutes by deleting the ingress rule, at the cost
of returning to relay speed.

### Measured, not estimated

| Thing | Value |
|---|---|
| Phone → VM, **direct** | **10–16 MB/s** (since 2026-09-15) |
| Phone → VM, relayed | ~1.3 MB/s — what it was before |
| Card → phone copy | **~71 MB/s** (3.2 GB in 45 s) |
| Battery drain, X4 attached | **1% / 3.3 min** → ~4.7h usable |
| Scan speed | **~3.7 GB/min** |
| Wifi line speed | 125 Mb/s (~15 MB/s) — now the actual ceiling |

**An earlier version of this table blamed the OTG read and Syncthing hashing.
That was wrong**, and it was never tested — it was inferred from the one number
available and then written down as fact. The card does 71 MB/s; the relay did
1.3. See the entry above for the three measurements that separated them.

**Batch sizing changed with the direct connection.** At 10-16 MB/s a 135 GB
batch is roughly 2.5-4 hours rather than ~30, so the binding constraint is no
longer transfer time but battery: 1% per 3.3 minutes with the X4 attached,
about 4.7 hours usable. Keep the phone on power for a long run, or size batches
to a charge. The old 10-20 GB guidance was a workaround for the relay and is no
longer the reason.

### tg-prune, verified against the real card 2026-09-15

```
[13:49:03] 1 file(s) in tg-batch
[13:49:05] ledger holds 1 archived file(s)
[13:49:06] already archived : 1
[13:49:06] still to upload  : 0
[13:49:06] pruning would save 184 MB of transfer (~2 min at 1.3 MB/s)
[13:49:06] removed VID_20250219_155539_00_032.insv
```

(`--apply` deletes, and deliberately so: the operator clearing `tg-batch` by
hand has no hash to check against, and deleting footage that was never uploaded
is the unrecoverable mistake. The script removes a file only when its SHA-256 is
in `uploaded.sha256`, written only after a verified Telegram round trip; a name
match with different content is reported and KEPT. `--apply --keep` moves to a
`tg-archived/` sibling instead, for a batch to hold on the card longer.)

Two bugs surfaced on the way, both worth keeping in mind:

**The ledger was empty for a file that was demonstrably archived.** Only
`tg-archive.sh` wrote `uploaded.sha256`; `tg-upload.sh` read it but never wrote
it, and the first upload had been a direct `tg-upload.sh` run. Fixed by moving
the write into `tg-upload.sh` where the knowledge lives. Anything archived
before 2026-09-15 needs backfilling by hand:

```bash
# hash it on the card, in Termux
sha256sum /storage/9C33-6BBD/DCIM/tg-batch/NAME.insv
# then, on the VM
echo "<hash> NAME.insv" | sudo tee -a /var/lib/insta360-archive/work/uploaded.sha256
```

**A placeholder pasted verbatim into the ledger was caught by the hash check.**
The literal string `PASTE_HASH_HERE` went in as a hash; the next prune matched
the filename, found the content did not match, and reported
`same name, different content - keeping` rather than deleting a file it could
not verify. Name-matching alone would have deleted an unarchived original.

### Under `set -o pipefail`, `pipeline || fallback` emits BOTH values

Not a style nit — it produced three separate symptoms in one run:

```
line 119: 0
0: syntax error in expression (error token is "0")
ERROR: metrics push failed (HTTP 400000)
{"accepted":true}
```

`du -sb "$d" | cut -f1 || echo 0`. With `pipefail`, the pipeline's status is the
**first failing command's**, not the last. A `du` that hits an unreadable
subdirectory prints a partial total *and* exits non-zero: `cut` emits a value,
the pipeline is then non-zero, and `|| echo 0` emits a **second**. The variable
holds `"0\n0"` and the next `$(( ))` dies.

The same shape gave `HTTP 400000` — curl printed `200`, the `|| echo '000'`
appended, and the log reported nonsense **for a push the server had accepted**.

**Hidden for months because the collector only ever ran as root**, where `du`
never fails. It surfaced the instant an `ops.env` permissions fix let it run as
`ubuntu`. A permissions change is a plausible way to expose latent bugs in
anything that shells out.

The safe form is capture-then-validate:

```bash
out="$(du -sb "$d" 2>/dev/null | cut -f1 | head -1)"
[[ "$out" =~ ^[0-9]+$ ]] && echo "$out" || echo 0
```

The distinction to apply: `a | b || c` is dangerous; `a < f || c` is not. A
simple command with a redirect fails as one unit, so the seven remaining
`|| echo` sites in that script are safe and were left alone.

### Syncthing partials are `.syncthing.*.tmp` — so interruption needs no handling

`tg-upload.sh` globs `"$STAGING_DIR"/*.insv`, which does **not** match
`.syncthing.NAME.insv.tmp`. A half-transferred file is therefore invisible to
the uploader: it sits in staging as a temp file and Syncthing resumes it when
the card is reconnected.

This is why pulling the cable mid-drain is safe with no cleanup, no state to
record, and nothing to remove. **A pause/resume system was built for this case
and deleted on 2026-09-15** once the behaviour was understood — roughly twenty
lines, two commands, a dashboard state value and two lines of documentation,
all for a problem that never existed.

Worth checking before building recovery machinery: what does the tool already
do when interrupted?

### `sha256sum /full/path` writes the full path into the manifest

Not `sha256sum "$f"` — `( cd "$DIR" && sha256sum "$base" )`.

`sha256sum` records the argument it was given. Hashing by full path writes
`<hash>  /mnt/media/tg-staging/VID_x.insv` into the manifest, and then:

- a dedupe check looking for a bare filename never matches, so every re-run
  appends the same file again
- every reader has to strip the directory (`sub(/.*\//, "", n)`) to compare

Both `verify-batch.sh` and `tg-go` strip it defensively, so a legacy manifest
full of paths still works — but write bare names and the problem does not arise.

Caught by a fixture asserting that a second run adds no lines. The first run
looked perfectly correct on its own.

(Note on Windows: Git Bash's `sha256sum` defaults to binary mode and prefixes
the filename with `*`. Linux does not. Every reader here strips a leading `*`
for that reason.)

### Two bugs only a real install could find (2026-09-15)

The first genuine batch through the finished pipeline — 694 MB, card to Telegram
and verified back — surfaced two faults that every fixture had passed.

**A symlinked command cannot find its siblings.** `tg-archive` installed as
`/usr/local/bin/tg-archive` resolved its own directory with
`dirname "${BASH_SOURCE[0]}"`, got `/usr/local/bin`, and looked there for
`tg-upload.sh`. It failed with `not executable: /usr/local/bin/tg-upload.sh` —
naming a path the operator never typed, for a file they never installed.

```bash
# wrong: resolves to the symlink's directory
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# right: follows the link to where the scripts actually live
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
```

**This cannot be tested on the Windows machine.** Git Bash's `ln -s` creates a
regular file, not a link, so `readlink -f` has nothing to follow and the test
passes for the wrong reason. Confirmed working only on the VM.

**Four ops scripts were committed `100644`.** `rsync -a` faithfully preserved
the non-executable bit, and `collect-and-push.sh` failed with `command not
found` on a file plainly present. Windows does not report the executable bit to
git, so `chmod +x` locally never reaches the index:

```bash
git update-index --chmod=+x path/to/script.sh
git ls-files -s ops/          # verify: 100755, not 100644
```

`ops/README.md` had long instructed a `chmod +x` after every rsync — a manual
step that existed only to paper over this, and which hid it for months.

**The lesson for both:** a fixture runs the script where it sits, with whatever
permissions the working tree happens to have. Neither fault can appear until
something is installed, symlinked and synced the way it really runs.

### Termux CAN read the OTG card — name the volume explicitly

**This entry previously said the opposite, as settled fact. It was wrong, and
the way it was wrong is the lesson.**

What fails:

```bash
ls /storage/                 # Permission denied
ls ~/storage/external-0/     # empty
ls ~/storage/external-1/     # empty
```

What works, with the X4 connected:

```bash
ls /storage/9C33-6BBD/DCIM/tg-batch/    # lists the .insv files
```

**Android denies listing `/storage/` while still permitting access to a named
subdirectory inside it.** "Permission denied" on the parent says nothing about
the child. Three failures were generalised into a platform-wide impossibility
without ever trying the one path that mattered, and a working `tg-prune.sh` was
deleted on the strength of it.

Two details that hid the answer:

- The volume id is **UPPERCASE** (`9C33-6BBD`) and the directory is **`DCIM`**,
  while the Syncthing config records the lowercase `9c33-6bbd/dcim`. That path
  genuinely does not exist from Termux.
- `find /storage ...` is useless for discovery, because the denial is on
  listing the parent. Glob `/storage/XXXX-XXXX` directly instead.

**Consequence: the manifest CAN be generated on the card**, which is the
stronger guarantee — it proves the files match the card, not merely that the
VM's copy matches itself:

```bash
cd /storage/9C33-6BBD/DCIM/tg-batch && sha256sum *.insv > ~/manifest-card.sha256
```

The VM-side alternative remains valid and is what the pipeline used up to
2026-09-15:

```bash
cd /mnt/media/tg-staging && sha256sum *.insv > /var/lib/insta360-archive/manifest.sha256
```

Syncthing hashes every block it transfers, so the card→VM leg is not
unprotected either way; the manifest's primary job is the Telegram round trip.

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

### "Syncthing is not scanning" — `globalFiles: 0` with a healthy connection

Seen for real on 2026-09-15. Files were sitting in `tg-batch` and nothing moved:

```
"globalFiles": 0      "localFiles": 0
"needFiles": 0        "needBytes": 0        "state": "idle"

"connected": true     "paused": false
```

**Read those two blocks together.** The link is fine — the phone and VM are
talking. `globalFiles` is the phone's own count of what it has to offer, and
zero means the phone is claiming the folder is empty. The VM is reporting that
faithfully. So the fault is always phone-side, never the network or the VM.

**Fixed by restarting the Syncthing app on the phone.** ColorOS had suspended
it; it held the connection open while no longer scanning, which is the
confusing part — a dead app that still looks connected.

Diagnosis order, fastest first:

1. `globalFiles: 0` **and** `connected: true` → phone-side, restart the app
2. `connected: false` → app killed outright, or Tailscale down
3. `globalFiles: N`, `needFiles: 0` → VM thinks it has everything; check the
   files are really in `tg-batch` and not internal storage
4. `state: "error"` → folder fault, usually the missing `.stfolder` marker

If restarting works but the files still do not appear, tap the folder in the
app and hit **Rescan**: Android does not reliably fire filesystem events for
files written by another app, so a manual scan is sometimes needed.

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
