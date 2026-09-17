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

## READ THIS BEFORE STARTING — all three uncertainties are now RESOLVED

The three weaknesses this plan was written around were each settled on
2026-09-17. Kept rather than deleted, because how they resolved is the point:

1. ~~**Is `cryptg` installed?**~~ **YES.** Measured on the VM. Stages 1–2 are
   closed, and every estimate assuming 7–15 MB/s is void. This was the single
   fact the plan said it hinged on, and it went against the plan.
2. ~~**The resolver bug's severity is unconfirmed.**~~ **It was ACTIVE, not
   latent.** The 2026-09-17 journal shows `no message id captured` for *every*
   file, then `using a full-channel download`, on every batch. Fixed in
   `c6bc4b6`.
3. ~~**The 22-hour baseline may be stale.**~~ **Confirmed stale, and still
   unmeasured.** The run of 2026-09-17 19:57 was killed mid-flight and restarted;
   the drain in progress at the time of writing is the first clean baseline. Do
   not credit any saving to a stage until one post-deploy drain is measured.

**What the measurements changed:** upload is network-bound at ~2.3–3.5 MB/s and
**cannot be reduced by anything in this plan**. It is now the dominant leg. The
remaining work is all on the verification side, and Stage 4 should be re-costed
against a real `by message id` Check #2 before it is built.

**Discipline this plan commits to:** apply one stage, measure, keep it only if
the number moves. A stage that does not move it is reverted, not kept on faith.
Stages 1 and 2 were closed by that rule before a line of them was run.

---

## Stage 0 — MEASURED 2026-09-17, on the VM, mid-drain

Run against a live upload of `VID_20250607_110125_00_091.insv`, so these are
load figures rather than idle ones.

| Question | Answer |
|---|---|
| Is `cryptg` installed? | **YES** — `import cryptg` succeeds |
| Is the upload CPU-throttled? | **NO** — `nr_periods 0`, `nr_throttled 0`, `throttled_usec 0` |
| Upload rate under load | **2.3 MB/s** (69.2 MB in 30 s, from `/proc/<pid>/io`) |
| CPU split | 1,392 s total; 1,345 s at `nice`, 36 s system |

**Stage 1 is CLOSED — do not run `pipx inject telegram-upload cryptg`.** It is
already there, so AES-256-IGE runs in optimised C. The "2–4× for one command"
estimate was based on it being absent; it is not.

**Stage 2 is CLOSED — do not raise `CPUQuota`.** Not "rarely throttled":
`nr_periods 0` means the quota has never been enforced even once. Raising it
would take CPU from Immich and change nothing.

### What this settles about the 3.5 MB/s ceiling

`docs/SESSION-HANDOVER.md:186` claimed this was "Telegram's own ingest limit,
not a local constraint". That was asserted without a measurement, and the
optimisation plan was right to flag it as untested — but it is now **confirmed
correct**. Both local explanations are eliminated: the crypto is compiled, and
the CPU is never throttled. The process is waiting on the network.

**Consequence: upload time is IRREDUCIBLE by anything in this plan.** A 27 GiB
batch costs ~3.5 hours of upload and no local change alters that. Every
remaining lever is on the verification side.

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

## Stage A — Fix the resolver partial-resolution bug — DONE (c6bc4b6)

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

## Stage 1 — `cryptg` — CLOSED, ALREADY INSTALLED

**Do not run this.** Stage 0 measured it present on 2026-09-17. Kept for the
reasoning only; the command below would be a no-op at best.

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

## Stage 2 — Raise `CPUQuota` — CLOSED, NO THROTTLING EXISTS

**Do not run this.** Stage 0 measured `nr_periods 0` / `throttled_usec 0` under
a live upload: the quota has never once been enforced. `CPUQuota=75%` is three-quarters of **one**
core of two; pure-Python AES plus SHA-256 saturates it.

```bash
sudo systemctl set-property --runtime tg-archive.service CPUQuota=125%
```

`--runtime` evaporates on reboot, so it rolls itself back. Watch Immich
responsiveness. Revert with `systemctl revert tg-archive.service`. Only edit
`ops/systemd/tg-archive.service` after it survives a full drain.

---

## Stage 2b — Two free wins — DONE (60ce95d, 3a00439)

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

## Stage 3 — Check #1 per file — DONE (9a60c8e), but see the note on overlap

Already proposed at `docs/SESSION-HANDOVER.md:178`. Check #1 hashed the *entire*
batch before the first byte uploaded — 13 min for 27 GiB, measured again in the
2026-09-17 log (19:57:14 → 20:10:26), with the network idle throughout.

**Implemented in 9a60c8e, but the original claim here was wrong.** This said
hashing each file before uploading it is "genuinely parallel ... reclaims ~25
min per 46 GB". It is not: the loop is sequential, so hashing file N+1 does not
overlap uploading file N, and total CPU and bytes read are unchanged.

What the change actually buys is **when the first byte leaves**: after one
file's hash rather than the whole batch's. A drain interrupted part-way now has
real files in the archive rather than none, and the dashboard shows progress
immediately instead of after 13 idle minutes.

**Real overlap is still available and still unbuilt** — it needs the next hash
backgrounded against the current upload, which needs its own reasoning about a
background hash failing while an upload is in flight. Given Stage 0's finding
that upload is network-bound and irreducible, overlapping ~13 min of hashing
against a ~210 min upload is worth roughly 6% of the batch. Low priority.

---

## Stage 4 — Parallel transfer: DOWNLOAD only

**Corrected twice.** An earlier draft proposed parallelising the upload; the
modelling below showed that was wrong. Stage 0's measurements on 2026-09-17 then
invalidated the model's own assumptions, so the table is restated here with the
dead rows removed:

| After | Check #1 | Upload | Check #2 | Dominant |
|---|---|---|---|---|
| before this session | 13 m blocking | ~210 m | whole archive, hours | Check #2 |
| after A + 2b + 3 (deployed) | ~0 m blocking | ~210 m | batch-sized | **upload** |
| + parallel download | ~0 m blocking | ~210 m | faster still | **upload** |

**The `+ cryptg + CPU` row that predicted a 70 m upload is deleted: it cannot
happen.** `cryptg` is already installed and the service is never CPU-throttled,
so ~210 m for 27 GiB is the real, network-bound floor.

That inverts the conclusion. **Upload now dominates, and nothing in this plan can
reduce it.** Parallel download remains worth doing — it is the only remaining
lever — but it optimises the smaller leg, so measure a real `by message id`
Check #2 before spending ~150 lines of first-party code on it. If that check
already costs minutes rather than hours, Stage 4 may not be worth building at
all.

Verification cannot be cheapened any other way: trusting the upload or sampling
would break the integrity chain (`SESSION-HANDOVER.md:35`), and fetching by id
already removed the per-batch archive re-download.


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
