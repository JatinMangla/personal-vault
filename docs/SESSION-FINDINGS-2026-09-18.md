# Session findings — 2026-09-16 to 09-18

Everything learned, built and broken across this session. Companion to
`docs/OPTIMISATION-PLAN.md`, which says what to do next; this says how those
conclusions were reached and which of them are shaky.

**Read `docs/HARD-WON.md` and `docs/SESSION-HANDOVER.md` first.** This file adds
to them; it does not replace them.

---

## What shipped, in order

| Commit | What |
|---|---|
| `ed452b3` | Split `/status` into two archive cards; collector cadence 15 min → 1 min |
| `4a56150` | Revoke `prune_metrics_samples` from `anon` and `authenticated` |
| `a12c326` | Say WHICH prune-metrics secret is missing |
| `894eff9` | Tolerate a trailing slash in `SUPABASE_URL` |
| `4167fa5` | Render file counts as counts, not bytes (`3 B / 11 B` bug) |
| `0920b45` | First verify-by-message-id attempt — **did not work, see below** |
| `540fa61` | Fix `supabase-keepalive`, which had never once succeeded |
| `df94ea0` | Make the shellcheck directive bind; scan `ops/insta360-bin` for the first time |
| `6d95253` | Never let one unreadable file abort or hang the prune |
| `ebc8937` | Size the prune timeout from a measured OTG read |
| `a3963ad` | Let the dry run continue to the delete — 31 min → 15 |
| `dbb4318` | Size the prune estimate from a real multi-file run |
| `d002ea1` | Read-only probe for filename → message-id mapping |
| `42355f2` | Split oversized batches; fix the guard; break the infinite retry |
| `0989b65` | Duplicate finder, report-only by default |
| `f8b5267` | Drop an unused variable that failed the shellcheck just enabled |
| `bcfb496` | Resolve message ids by asking Telegram, not parsing CLI output |
| `30641da` | Clean up round-trip scratch on SIGTERM; watchdog on Check #2 |

---

## Measurements taken this session

All from the live system. Supersede any conflicting figure elsewhere.

| Thing | Value | How |
|---|---|---|
| Telegram upload | **3.0–3.7 MB/s** | Four files, log timestamps, consistent across days |
| Card → VM (OTG), single file | 20.4 MB/s | `dd bs=1M count=200` |
| Card → VM, **real multi-file prune** | **15.9 MB/s** | 19,951,255,552 bytes in 1255 s |
| Channel metadata walk | **62 messages/s** | `tg-probe-ids.py`, whole channel in 0.8 s |
| Check #1 hashing | ~35 MB/s | 14 files / 27 GiB in 13 min |
| Effective end-to-end | **0.195 MB/s** | 20.38 GB archived in 29 h — **6% of the link** |
| `metrics_samples` row | 1,900 bytes | `pg_total_relation_size` ÷ rows |

**The 6% figure is the headline.** ~94% of elapsed time was not uploading.

### Rate figures corrected this session

Three, all the same mistake — a number measured in one context reused in
another:

- `3.7 GB/min` was a **Syncthing scan** rate, used for OTG reads in
  `RUNBOOK.md:312`. Real OTG is ~1.2 GB/min, so "170x faster than transferring"
  was actually **under 2x**.
- `20.4 MB/s` was a **single-file sequential** `dd`, applied to a multi-file
  walk. Real is 15.9 MB/s.
- `1.3 MB/s` was a **DERP relay** rate treated as a card limit (recorded
  previously, noted here for the pattern).

---

## Bugs found, and what each teaches

### Mine, shipped this session

**`--print-file-id` emits a file_id, not a message id.** Captured with `cat -A`
on the VM:

```
Uploaded successfully "tgtest.txt" (file_id BQADBQADmiMAAss5WVXcwHLblCIghQI)
```

The parser searched `[0-9]{5,}` and matched nothing, so every Check #2 fell back
to a full-channel download. **This cost a real 22-hour drain.** I verified the
flag existed, then guessed its output format, then wrote fixtures that tested
the guess against itself. Converting a file_id needs
`resolve_bot_file_id()`, which has open upstream issues returning `None`.

**EXIT trap did not survive SIGTERM.** `systemctl stop` left **93 GB** of
orphaned scratch on a 147 GB volume, taking it to 91% full. The operator found
and removed it by hand. This matters because "systemctl stop tg-archive (safe at
any point)" is advice this project prints in its own logs.

**`3 B / 11 B` on the dashboard.** `LimitMeter` formatted file counts through
`formatBytes`. Four green CI gates passed; the operator caught it by reading the
deployed page.

**An unused variable** failed the shellcheck I had enabled in the same commit.

**A stray `> `** nearly shipped into `immich-backup.sh`, which would have broken
the backup script at parse time. Caught on re-read before commit.

### Pre-existing, found by investigation

**`anon` and `authenticated` held EXECUTE on `prune_metrics_samples`** — a
`SECURITY DEFINER` function that deletes rows. The anon key ships in the browser
bundle. `revoke ... from public` never removed it, because Supabase grants to
those roles **by name**. Found by reading the live ACL rather than trusting
`0001`'s comment.

**`supabase-keepalive` had never succeeded.** Failing on a missing secret since
creation, so the 7-day pause protection was never active.

**`prune_metrics_samples()` had never been called.** Its own comment claimed a
nightly Action invoked it; no such Action existed. Retention was unbounded.

**No batch splitting existed.** `tg-upload.sh` globbed every `.insv` as one
batch and refused outright if it would not fit. With 100 GB staged:
guard refuses → `tg-archive.sh` retries the identical directory every 60 s →
**forever**, since staging cannot shrink.

**The disk guard undercounted.** It compared `archive + batch` to free space,
forgetting the batch is *already on disk* and copied again into `.roundtrip`.
Each file costs its size **twice**. A 60 GB batch passed the check and would
have filled a 147 GB volume.

**Check #2 was unwatched.** A full-channel download of a 41 GB archive produced
93 GB — restarting rather than resuming. The disk guard ran once *before* the
download and never looked again.

---

## Still open

### The resolver partial-resolution bug (highest value)

`tg-resolve-ids.py` prints resolved names, then exits **1** if any name was
unresolved. `tg-upload.sh:365` captures it as `if resolved_out="$(...)"`, so a
non-zero exit **discards ids that were successfully resolved**.

**Severity unconfirmed.** It fires only when a name is unresolved, and on a
healthy batch every uploaded `.insv` should resolve — the manifest copy is
uploaded *after* resolution runs, so it is not in the list. May be latent.
Check whether the log says `by message id` or `whole channel`.

### 13 duplicate filenames in the channel

From interrupted drains that uploaded, were killed before recording, and
re-uploaded. `tg-find-dupes.py --delete` will remove 18 redundant messages
(29.6 GB), keeping the newest of each. **Report was clean — no "same name,
different size" entries.** Not run: a drain was in progress and the session lock
would conflict.

Left deliberately: they cost nothing, and Telegram is now the only copy.

### Unexplained

A batch reached `phase: downloading` only ~43 minutes after uploads began at
20:10 on 2026-09-17 — far too soon for 27 GB. Something ended it early. Not
diagnosed.

---

## Facts worth carrying forward

**Telegram's protocol is designed for parallel transfer.**
`upload.saveBigFilePart(file_id, file_part, file_total_parts, bytes)` and
`upload.getFile(location, offset, limit)` both carry explicit positions, so the
server reassembles by index. Out-of-order delivery is expected. Telethon is
sequential by choice, not by protocol constraint. Recommended `part_size` is
**512 KB**; `saveBigFilePart` above 10 MB.

**`cryptg` is Telethon's own FAQ recommendation** — without it, AES-256-IGE runs
in pure Python. On 2 ARM cores at `CPUQuota=75%` that is a plausible explanation
for the 3.5 MB/s ceiling. **Not yet checked whether it is installed.**

**Telethon's FAQ warns** parallel transfers make `FloodWaitError` occur sooner.

**The ledger's 4th column** is message ids, space-separated, `-` when unknown.
Appended, never inserted: `tg-archive.sh` reads `$2`/`$3` positionally and
`tg-prune.sh` matches `$1`, so a trailing field is invisible to both. Verified
against 2-, 3- and 4-column rows.

**A file is hashed four times** on its first batch: manifest fingerprint, Check
#1, Check #2 on the downloaded copy, ledger write. Hashes 2 and 4 read the same
unchanged file.

**`systemctl start tg-archive` blocks for hours** — `Type=oneshot` with
`TimeoutStartSec=0`. Use `--no-block`. Ctrl+C on the client does not stop the
service.

---

## Process notes

**What caught real bugs:** fixture tests (one rejected my own parser before it
touched the archive), reading live state instead of trusting comments, and the
operator reading the deployed page.

**What did not:** four green CI gates passed the `3 B / 11 B` bug and the
message-id failure.

**Wrong calls I made, stated plainly:**

- Declared the collector dead from a misread timestamp — it was 7 minutes old.
- Declared a running drain stopped from a stale state file — uploads were
  succeeding.
- Declared a healthy SD card failing, from one I/O error plus an apparent hang —
  one `dd` disproved it at 20.4 MB/s.
- Told the operator to stop a drain based on `archived` being frozen, without
  reading the log first. The log showed uploads succeeding. They pushed back and
  were right.

The pattern each time: **inferring from one observation and stating it as
fact** — which `docs/SESSION-HANDOVER.md:240` already warns about. Weight
anything asserted without a measurement behind it accordingly.

**Four VM commands were run on the phone** during this session. The prompts look
nearly identical in Termux. Labelling every command `[VM]` or `[PHONE]` fixed
it. A reliable tell: `/opt/`, `/mnt/media/`, `/etc/personal-vault/`,
`journalctl`, `systemctl` are VM; `~/bin/`, `/storage/` are phone.

**Dangling references after deletion** — this project's recurring bug, hit again
when removing the parser. Three survivors in `tg-upload.sh` plus a stale CI
step. **Grep for survivors after every deletion.**
