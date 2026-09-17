# Plan: optimise the VM → Telegram archive transfer

**Written 2026-09-18 for execution by a fresh session.**
Repo: `D:\git\cloud storage` · VM: `ssh -i ~/.ssh/immich_phone ubuntu@100.88.183.74`

Read `docs/HARD-WON.md` and `docs/SESSION-HANDOVER.md` before starting. This
plan assumes the traps recorded there. A companion document,
`SESSION-FINDINGS-2026-09-18.md`, records how these conclusions were reached.

---

## Context

A 46 GB batch took 22+ hours. Measured from `metrics_samples`: **20.38 GB
archived in 29 hours**. The operator asked for the transfer path to be
optimised.

Research established where the time actually goes and corrected two beliefs:

- **The upload was never the dominant cost.** At 3.0–3.7 MB/s, 20.38 GB of
  upload is ~1.7 of those 29 hours. The rest was Check #2 downloading the
  *whole channel* every batch, plus hashing and idle waits.
- **3.1 MB/s is probably not Telegram's cap.** `docs/SESSION-HANDOVER.md:186`
  asserts it is "Telegram's own ingest limit, not a local constraint" — never
  tested. Telethon uploads chunks sequentially on one connection, and without
  `cryptg` it does AES-256-IGE **in pure Python** on 2 ARM cores capped at
  `CPUQuota=75%`.

---

## READ THIS BEFORE STARTING — what is uncertain

Three weaknesses, stated rather than hidden:

1. **The plan hinges on one unmeasured fact: is `cryptg` installed?** If it is,
   Stages 1–2 buy almost nothing and every estimate assuming 7–15 MB/s
   collapses. **Stage 0 runs first**, and the plan is re-costed if the answer is
   "already present".
2. **The resolver bug's severity is unconfirmed.** It fires only when a name is
   unresolved; on a healthy batch every uploaded `.insv` should resolve. It may
   be **latent rather than active**. Still wrong, still worth fixing, but any
   "saves N hours" figure is unproven until measured.
3. **The 22-hour baseline may be stale.** The run on the night of 2026-09-17 was
   the first with batch splitting, the guard fix and the resolver deployed.
   Re-measure before claiming a saving.

**Discipline this plan commits to:** apply one stage, measure, keep it only if
the number moves. A stage that does not move it is reverted, not kept on faith.

---

## Stage 0 — Measure (no changes, ~30 min)

Nothing here writes to the archive. **[VM]**

```bash
PIPX_PY=~/.local/share/pipx/venvs/telegram-upload/bin/python

# THE decisive question.
$PIPX_PY -c "import cryptg; print('cryptg', cryptg.__version__)" 2>&1

# Is the upload CPU-bound? throttled_usec is the tell.
cat /sys/fs/cgroup/system.slice/tg-archive.service/cpu.stat
systemctl show tg-archive.service -p MemoryPeak

# Did the id fix work, or silently fall back?
awk 'NF>=4 && $4 != "-" {i++} NF<4 || $4=="-" {n++} \
  END {print "with ids:", i, " without:", n}' \
  /var/lib/insta360-archive/work/uploaded.sha256
journalctl -u tg-archive --no-pager -o cat | grep -cE 'by message id'
journalctl -u tg-archive --no-pager -o cat | grep -cE 'whole channel'
```

**Decision gates:**
- `throttled_usec` climbing steadily → CPU is the constraint; Stage 2 beats any
  library change.
- Check #2 still says `whole channel` → fix that before any speed work.
- `cryptg` present → skip Stage 1, re-cost everything downstream.

---

## Stage A — Fix the resolver partial-resolution bug

**Do this regardless of Stage 0's outcome.** It is a correctness bug.

`tg-resolve-ids.py` prints resolved names to stdout, then exits **1** if *any*
name was unresolved. `ops/insta360-bin/tg-upload.sh:365` captures it as
`if resolved_out="$(...)"`, so a non-zero exit **skips the entire `while read`
loop**, discarding ids that *were* resolved. Every file then reports missing,
`ids_complete=0`, and Check #2 falls back to the full-channel download.

Changes:

- `tg-upload.sh` — consume stdout **regardless of exit status**. Parse first,
  then judge completeness from `BATCH_IDS`, which the loop below already does
  correctly.
- `tg-resolve-ids.py` — exit 0 on partial success, reporting unresolved names on
  stderr only. Reserve non-zero for "could not reach Telegram at all".
- `test-resolve-ids.py` — add a fixture for partial resolution.

---

## Stage 1 — `cryptg` (~5 min, fully reversible)

Only if Stage 0 shows it missing.

```bash
pipx inject telegram-upload cryptg
```

`pipx inject` adds to the existing venv **without reinstalling**
telegram-upload, so the hand-patched `telegram_manager_client.py` is untouched.
Same mechanism `docs/HARD-WON.md:228` already used for `packaging` — proven safe
on this exact venv. **Never `pipx upgrade telegram-upload`.**

Then verify the patch survived, per HARD-WON's standing rule:

```bash
grep -n 'packaging.version' \
  ~/.local/share/pipx/venvs/telegram-upload/lib/python3.12/site-packages/telegram_upload/client/telegram_manager_client.py
telegram-upload --help >/dev/null && echo "import chain OK"
```

Rollback: `pipx uninject telegram-upload cryptg`.
Expected: 2–4× **if** AES was the bottleneck; ~0% otherwise.
Risk: cryptg may build from source on ARM64 and need `build-essential` +
`python3.12-dev`. A failed build fails cleanly, changing nothing.

---

## Stage 2 — Raise `CPUQuota` (~2 min, self-reverting)

Only if Stage 0 shows throttling. `CPUQuota=75%` is three-quarters of **one**
core of two; pure-Python AES plus SHA-256 saturates it.

```bash
sudo systemctl set-property --runtime tg-archive.service CPUQuota=125%
```

`--runtime` evaporates on reboot, so it rolls itself back. Watch Immich
responsiveness. Revert with `systemctl revert tg-archive.service`. Only edit
`ops/systemd/tg-archive.service` after it survives a full drain.

---

## Stage 2b — Two free wins, no dependencies (~10 min)

**`IDLE_WAIT_SECONDS=300` with two idle passes required.** `tg-archive.sh:67`
and `:292` mean every drain ends with **up to 10 minutes of pure waiting**.
Syncthing state is already available — `tg-go.sh`'s `sync_status()` reads
`needBytes` and `state`. End the drain when Syncthing reports idle with nothing
pending, keeping the sleep as fallback when Syncthing is unreachable.

**The fourth hash.** Every first-time file is hashed four times: manifest
fingerprint (`tg-archive.sh:358`), Check #1 (`verify-batch.sh:78`), Check #2 on
the downloaded copy (`tg-upload.sh:593`), ledger write (`tg-upload.sh:651`).
Hashes 2 and 4 read the **same unchanged staging file**. The code calls this
"already in page cache", but Check #2's multi-GB download sits between them and
will have evicted it. Reusing the Check #1 result for the ledger is safe — the
file cannot change, the flock is held — and saves ~13 min per 27 GiB.

---

## Stage 3 — Overlap Check #1 hashing with uploading

Already proposed at `docs/SESSION-HANDOVER.md:178`. Check #1 currently hashes
the *entire* batch before the first byte uploads — 13 min for 27 GiB with the
network idle throughout.

Hash each file immediately before uploading it. With 2 cores this is genuinely
parallel, adds no dependency, and reclaims ~25 min per 46 GB. Touches
`verify-batch.sh`'s call site at `tg-upload.sh:286`, not the upload library.

---

## Stage 4 — Parallel transfer: DOWNLOAD first, upload second

**Corrected after self-review.** An earlier draft proposed parallelising the
upload. Modelling the legs shows that is wrong:

| After | Check #1 | Upload | Check #2 | Dominant |
|---|---|---|---|---|
| today | 25 m | 220 m | 110 m | upload |
| id fix working | 25 m | 220 m | 78 m | upload |
| + cryptg + CPU | 25 m | **70 m** | **78 m** | **Check #2** |
| + overlap hashing | 0 m | 70 m | **78 m** | **Check #2** |

Once the upload is fixed, **Check #2's download dominates** — and parallel
upload does nothing for it. Telethon downloads are sequential for the same
reason uploads are.

**So: parallel DOWNLOAD in `tg-fetch-ids.py` first. Parallel upload second, and
only if measurement still justifies it.**

Verification cannot be cheapened any other way: trusting the upload or sampling
would break the integrity chain (`SESSION-HANDOVER.md:35`), and fetching by id
already removed the per-batch archive re-download. What remains is irreducible,
so the only lever is doing it faster.

### Why build it ourselves rather than vendor FastTelethon

Telegram's protocol is designed for parallel transfer, with explicit indices:

```
upload.saveBigFilePart(file_id, file_part, file_total_parts, bytes)
upload.getFile(location, offset, limit)
```

**Parts carry their own position.** The server reassembles by index; a download
requests an explicit offset. "Parallelism scrambles the file" is not a failure
mode that exists. The real risks are a part never arriving, or computing an
offset wrong — both cheap to make impossible:

- Sequential reads with an incrementing index; no seek arithmetic to get wrong.
- Assert `parts_sent == file_total_parts` (upload) and
  `bytes_written == file_size` (download) before declaring success.
- `part_size` fixed at **512 KB**, Telegram's documented recommendation.
- Concurrency default **4**, not FastTelethon's 20.

~150 lines of first-party code against documented API beats ~200 lines of an
unmaintained gist, in the one script that touches the only copy of this footage.

### The decisive simplification: do not reimplement splitting

The biggest risk in a vendored-gist plan was hand-writing the 2000 MiB split to
match `tg-upload.sh:571`'s `.00`/`.01` rejoin. **Drop it.** Parallelise only the
part transfer *within* one file; files above the split threshold continue
through `telegram-upload` exactly as today.

### Non-negotiables

1. **`force_document=True`** on `send_file`. `SESSION-HANDOVER.md:36` requires
   documents so Telegram does not re-encode. Without it video is transcoded and
   the round trip fails — Check #2 catches it, so it fails safe, but every batch
   would fail.
2. **Capture the message id from `send_file`'s return**, making the channel walk
   redundant for files on this path.
3. **`flood_sleep_threshold=0`** so Telethon stops silently sleeping short waits;
   otherwise a slow upload and an unlogged throttle look identical.
4. On `FloodWaitError`, print exactly `FLOOD_WAIT_<n>` to stderr and exit
   non-zero, so `upload_one()`'s existing regex at `tg-upload.sh:305` works
   unmodified. **Reuse the proven parser; do not write a second one.**
5. **Ratchet:** count flood-waits per batch; at ≥3, fall back to sequential
   `telegram-upload` for the rest of the batch.

### RAM

4 concurrent parts × 512 KB = 2 MB of buffers; the file is streamed, never
loaded whole. ~150 MB peak with interpreter and sockets, far under
`MemoryMax=1G`. `MemorySwapMax=0` makes any overshoot an instant OOM kill, and
SIGKILL does not run the cleanup traps — but the stale-PID sweep at
`tg-upload.sh:419` reclaims orphaned scratch on the next run, so the failure is
bounded. Verify with `systemctl show tg-archive.service -p MemoryPeak`.

### Wiring and rollback

Modify only `upload_one()` in `tg-upload.sh`:

```
if TG_PAR_UPLOAD=1 and tg-par-upload.py is executable:
    try parallel path; on any non-FloodWait failure, log and fall through
else:
    telegram-upload (today's path, byte-identical)
```

Default **off** in `/etc/personal-vault/tg-archive.env`. Rollback is one
character. The proven path is retained as fallback, not replaced, and Check #2
still gates staging deletion — so a bug here cannot clear staging.

### Fixtures

`test-par-upload.py`, pure functions, no network:

- part indexing over a known byte pattern — every index correct, none skipped
- `file_total_parts` arithmetic at exact 512 KB multiples and one byte over
- the completeness assertion firing when a part is dropped
- flood-wait message formatting matching `upload_one()`'s regex

---

## Constraints that cannot be broken

- **The integrity chain**: Check #1 → upload → Check #2 round trip → only then
  clear staging. `docs/SESSION-HANDOVER.md:35` — "do not weaken this".
  `docs/HARD-WON.md:534` records a `PASTE_HASH_HERE` placeholder caught only by
  the content hash; name-matching alone would have deleted an unarchived
  original.
- **$0–1/year budget.** No paid services.
- **Immich must stay responsive** — it shares 2 cores and the same disk.
- **Never `pipx upgrade telegram-upload`** — it reverts the distutils patch.
- **LF line endings** under `ops/` — CRLF breaks shebangs on the VM.
- Any new path needs a fallback, and a failure must never clear staging.

---

## Verification

After each stage, re-measure rather than assuming:

```bash
# Upload rate from the log's own timestamps
journalctl -u tg-archive --since '1 day ago' --no-pager -o cat \
  | grep -E 'uploading|verification passed'

# Which Check #2 path ran
journalctl -u tg-archive --no-pager -o cat | grep -E 'by message id|whole channel'

# Effective throughput, from metrics_samples archived_bytes delta ÷ elapsed
```

Gates before any commit:

```bash
bash -n ops/insta360-bin/*.sh
grep -rnE ']] +[{]|null +[{]|>/dev/null +[a-z]' ops/insta360-bin/*.sh   # must be empty
bash ops/insta360-bin/test-batch-split.sh      # expect passed=8
python3 ops/insta360-bin/test-resolve-ids.py   # expect passed=13
```

Then `security-scan` green on GitHub Actions.

**End-to-end:** one real batch showing `Check #2 - fetching N file(s) by message
id`, completing in the time the stage predicts.

---

## Deploy procedure (every stage)

```bash
cd ~/personal-vault && git pull && \
sudo rsync -a ops/insta360-bin/ /opt/insta360-archive/bin/ && \
sudo chmod +x /opt/insta360-archive/bin/*.sh /opt/insta360-archive/bin/*.py && \
python3 /opt/insta360-archive/bin/test-resolve-ids.py | tail -1 && \
bash /opt/insta360-archive/bin/test-batch-split.sh | tail -1
```

**Never deploy mid-drain** — it changes scripts under a running process.
Start detached: `sudo systemctl start --no-block tg-archive`
(plain `systemctl start` blocks for hours: the unit is `Type=oneshot` with
`TimeoutStartSec=0`).
