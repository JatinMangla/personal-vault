# Session findings — 2026-09-18 to 09-19

The optimisation session: Stages A, 2b, 3 and 4 of `docs/OPTIMISATION-PLAN.md`,
plus the duplicate purge and the prune fast path.

`OPTIMISATION-PLAN.md` records **what** was decided and the final numbers. This
file records **how** those conclusions were reached, which of my predictions
were wrong, and the diagnostic methods that worked — so a later session can
judge the reasoning rather than inherit the conclusions on faith.

**Read `docs/HARD-WON.md` and `docs/REVIEW-2026-09-24.md` first.** This adds to
them; it replaces nothing.

---

## SUPERSEDED IN PART — see `8c4a829` (2026-09-24/25)

A later incident revised two things this file records. Kept rather than edited
away, because the way each was wrong is the useful part.

**1. `TimeoutError (GetFileRequest)` is NOT reliably benign.**

This file reports one timeout in the parallel run against dozens sequentially,
and reads that as "when a connection stalls the other three keep working". On
2026-09-24 the by-id fetch hit **twelve** timeouts on a file uploaded *seconds
earlier*, then fell through to the whole-channel fallback: **162 GB onto ~111 GB
free, at 0.55 MB/s**, for 6+ hours with 50 GB of scratch. It could never have
finished.

The single timeout on 2026-09-19 was a lucky sample, not a property. Telegram
`GetFileRequest` timeouts are transient but can arrive in bursts, and the
fallback I treated as a safety net became the trap: it was never checked
against free space.

Fixed in `8c4a829` — by-id retries after 120 s and 300 s
(`TG_FETCH_RETRY_DELAYS`), each from an empty scratch directory, and
`full_channel_fits()` so the whole-channel path runs only when
archive + batch + margin actually fit. Otherwise Check #2 fails with staging
kept and the drain retries. Fixtures: `test-channel-fallback.sh`.

**2. The Syncthing scan rate was not 5.3 MB/s.**

The "Syncthing slow scan" section below concludes the fix was pruning rather
than tuning. **The pruning conclusion stands** — 49 GB of already-archived
footage on the card was real, and removing it was right. But the 5.3 MB/s figure
behind it was wrong: on 2026-09-24 the phone measured **15 MB/s whenever
connected**, and the apparent slowness was the phone being *disconnected*
21:10–23:30 IST by Android battery settings.

So this file added a fourth wrong rate figure to a project whose recurring bug
is exactly that — a number measured in one context reused in another. The 2.5
hours was disconnection plus redundant work, not a slow scanner. **`hashers`
tuning remains correctly unpursued**, for a better reason than the one given
below.

Also found then: `.roundtrip` sits inside the receive-only Syncthing folder, so
the VM hashes gigabytes it never needs. Add `/.roundtrip` to the VM
`.stignore`.


---

## Headline: the drain went from hours to ~28 minutes

Measured end to end on 2026-09-19, 6.6 GB:

| Leg | Time | Rate |
|---|---|---|
| Upload | 9 min | 12.2 MB/s |
| Check #2 fetch (parallel) | 12 min 33 s | 8.9 MB/s |
| Hash + verify | 4.5 min | — |
| Idle tail | 1.8 min | — |

The same work on 2026-09-18 took **162 minutes in Check #2 alone**.

---

## What shipped

| Commit | What |
|---|---|
| `c6bc4b6` | Resolver keeps the ids it did resolve (Stage A) |
| `60ce95d` | Ledger reuses Check #1's hash instead of re-reading every file |
| `3a00439` | Drain ends when Syncthing is idle, not after a blind 300 s |
| `9a60c8e` | Check #1 runs per file, so uploading starts immediately |
| `a97e110` | Bind the shellcheck directives the new fixtures needed |
| `11152d7` | Close Stages 1 and 2 by measurement; correct the modelling |
| `72e88c2` | `tg-prune --trust-size` |
| `d1ce88b` | Stop predicting hashing time in `--trust-size` mode |
| `a7e6add` | `tg-fetch-par.py` — parallel Check #2 fetch, opt-in |
| `b39352f` | Record the 14× production result |

Fixtures went 21 → 87 assertions across six suites, all wired into CI.

---

## Measurements taken, and what each killed

All from the live system. These supersede any conflicting figure elsewhere.

| Thing | Value | How |
|---|---|---|
| `cryptg` installed? | **YES** | `import cryptg` succeeded on the VM |
| CPU throttling | **NONE** | `nr_periods 0`, `nr_throttled 0`, `throttled_usec 0` |
| Upload under load | 2.3 MB/s, later 12.2 | `/proc/<pid>/io` delta over 30 s |
| Check #2 sequential | **0.64 MB/s** | 6.2 GB in 162 min, journal timestamps |
| Check #2 parallel (4) | **8.9 MB/s** | 6.55 GB in 12 min 33 s |
| Prune, 51 GB | **4 seconds** | `--trust-size`, wall clock |
| Syncthing scan, 49 GB | ~2.5 h (5.3 MB/s) | operator report |

**The two that mattered most were negative results.** `cryptg` already
installed and zero throttling killed Stages 1 and 2 outright — two stages the
plan had costed at 2–4× — before a line of either was run. That is Stage 0
doing exactly its job.

---

## Predictions I got wrong

Recorded because the *pattern* is the lesson, not the individual errors.

**1. I recommended against building the parallel fetcher.** My reasoning: Stage
0 showed upload was network-bound and irreducible, so upload dominated and
Check #2 was the smaller leg — not worth ~150 lines against the only copy of
the footage.

Then Check #2 measured **162 minutes against a 25-minute upload**. The download
was 85% of the drain, not the smaller leg. The plan's original instinct —
"parallel DOWNLOAD first, upload second" — was right, and my revision of it was
wrong. Built it, got 14×.

**2. I predicted parallelism might make the timeouts worse.** The sequential run
logged a storm of `TimeoutError ... GetFileRequest`; I read that as Telegram
straining on one connection and warned four might be worse. The opposite: **one**
timeout in the parallel run. When a connection stalls, the other three keep
working.

> **Revised 2026-09-24 (`8c4a829`).** One timeout was a lucky sample, not a
> property: a later by-id fetch hit **twelve** on a just-uploaded file and fell
> through to a whole-channel download that could not fit. See the supersession
> note at the top.

**3. I estimated prune's fast path at 5–10 seconds.** It was 4 — on 51 GB, not
the 46 GB I costed. Right shape, and the arithmetic was replaced with the real
figure in the script header.

**4. I claimed "ALL SIX CI STEPS PASS LOCALLY" when the job has seven.** I
reproduced the steps I had *added* and skipped the shellcheck step above them —
and shellcheck was not installed locally, so nothing objected. CI caught SC2034
on my own new fixture. See `memory/ci-gates-local.md`.

**The pattern:** each error came from reasoning forward from a model instead of
measuring the leg in question. Every one was corrected by a number, and none
would have been caught by thinking harder.

---

## Bugs found, and what each teaches

### The resolver bug was ACTIVE, not latent

`OPTIMISATION-PLAN` flagged its severity as unconfirmed — it fires only when a
name is unresolved, and on a healthy batch every `.insv` should resolve.

The journal settled it: **every file** logged `no message id captured`, then
`using a full-channel download`, on **every batch**. Six full-channel downloads
in the journal's history.

`tg-resolve-ids.py` printed the ids it resolved, then exited 1 if *any* name was
unresolved. `tg-upload.sh` captured it as `if resolved_out="$(...)"`, so the
non-zero status skipped the parse loop entirely and discarded ids that *had*
resolved. Both halves are now fixed independently, so neither depends on the
other.

**Lesson: "may be latent" is a hypothesis. The journal is the test.**

### A data-corruption path in my own parallel fetcher, caught by a fixture

The temp file was first named `NAME + ".part"`. The rejoin glob is
`NAME.[0-9][0-9]*` — and its trailing `*` matches `.part`. So
`VID_x.insv.00.part` **matched the rejoin glob**, and a crashed fetch would have
had its half-written temp concatenated into the rejoined file.

Caught by `test-fetch-par.py` before it ever ran, then confirmed against the
real shell glob. Temp files are now dot-prefixed, outside the glob entirely, and
the fixture asserts the naive naming *would* have matched so it cannot regress.

**Lesson: a trailing `*` in a glob matches more than the suffix you had in
mind.** The same reasoning that put `.roundtrip` outside `*.insv`.

### HASH_FILE truncation — an optimisation that silently undid itself

Stage 2b had Check #1 publish its hashes for the ledger to reuse. Stage 3 then
made Check #1 run **per file** — and `verify-batch.sh` truncated `HASH_FILE` on
every call, so only the last file's hash survived and the ledger re-read
everything else.

No symptom. The batch still worked; it was just slow again. Caught by a fixture
asserting three per-file runs leave three hashes, and verified to fail against
the truncating version.

**Lesson: when two changes touch the same file, the second can revert the first
with no visible failure.** Test the interaction, not just each change.

---

## The Syncthing "slow scan" — a workload problem, not a scan problem

The operator reported **2.5 hours to scan 48 GB (5.3 MB/s)** and asked for
scanning to be made faster. It was the right question with the wrong target.

What the evidence showed:

- prune hashes the *same files off the same card* at 13–16 MB/s — 3× faster
- `RUNBOOK.md:316` notes a ~3.7 GB/min figure that an earlier session had
  quoted for hashing and later corrected — it was Syncthing's *scan* rate,
  measured on this same setup. So a scan far faster than 5.3 MB/s has been
  seen here before
- the VM folder is `receiveonly`, so **the VM never scans to decide what to
  send** — there is no VM-side scan to tune
- `du` on the card: **49 GB across 42 files**, while the dashboard said
  `remaining: 0`

So Syncthing spent 2.5 hours re-hashing 49 GB of footage **already verified in
Telegram**. After `tg-prune --trust-size --apply` cleared it in 3 seconds, the
next run went almost straight to transferring — no long scan at all.

> **Revised 2026-09-24 (`8c4a829`).** The pruning conclusion below stands, but
> the 5.3 MB/s that motivated it was wrong — the phone measured **15 MB/s when
> connected**, and the apparent slowness was it being disconnected for over two
> hours by Android battery settings.

**Conclusion: the fix was removing the work, not speeding it up.** `hashers`
tuning was deliberately not pursued: even tripling the scan rate leaves ~50
minutes for 49 GB, versus ~0 if those files are not on the card. If a *clean*
batch of new footage ever scans slowly, that is the time to chase `hashers` —
against an uncontaminated baseline.

**Lesson: measure the workload before tuning the machine.** Three wrong rate
figures already exist in this project from exactly this confusion.

---

## Facts worth carrying forward

**`globalBytes` counts deleted files as tombstones.** After pruning 42 files the
VM reported `globalFiles: 46, globalBytes: 61 GB` while only ~14 GB of new
footage existed. That is how the deletion propagates, not a fault. **`needBytes`
is the only number that reflects what is left to move.**

**`state: idle` appears mid-transfer** between files. Seen at 9.0 GB remaining,
`syncing` again on the next poll. It is not a stall.

**A `Type=oneshot` unit sits in `activating` for its whole run** — hours or
days. `activating` means *running*, not *starting*. Never deploy while it says
that.

**The VM is unreachable from the Windows machine.** Both `100.88.183.74`
(Tailscale, not installed here) and `152.67.1.135` (public, zero open TCP ports
by design) time out. That is P1 working. Every VM step needs the operator in
Termux — tested, not assumed.

**Telethon's `iter_download` signature was verified on the VM before any code
was written against it**: `request_size` defaults to 524288, which is also
`MAX_CHUNK_SIZE` and Telegram's documented recommendation. Four of five flags
assumed from memory in this project turned out not to exist; this one was
checked first.

**82.8 GB of duplicates were removed** (60 messages) after cross-checking every
one of the ledger's 30 message ids against the deletion list — **zero overlap**,
verified before acting. The channel went 133 messages → 73, one per file.

---

## Still open

**Parallel upload: recommended AGAINST.** It writes to the archive rather than
reading from it, so a bug costs footage instead of time, and the remaining gain
is minutes on a ~28-minute drain. Also listed as dropped in
`REVIEW-2026-09-24.md`.

**Real overlap of hashing and uploading is unbuilt.** Stage 3 made Check #1
per-file, which changes *when the first byte leaves* — it does **not** make
hashing concurrent with uploading, as the plan originally claimed. Genuine
overlap needs the next hash backgrounded against the current upload, and its own
reasoning about a background hash failing mid-upload. Worth ~6% of a batch.

**`--trust-size` is safe only while drains end `remaining 0`.** It matches on
name + size without reading the file, so a re-recording landing on an identical
byte count would be deleted while Telegram holds different footage. Use the
default hash mode after any drain that ends `incomplete`.

---

## Process notes

**What caught real bugs:** fixtures written before deployment (two genuine
corruption paths, neither of which ever ran), reading the live journal instead
of trusting a comment, cross-checking ledger ids before a destructive delete,
and running CI's *exact* command locally rather than an approximation of it.

**What did not:** my own reasoning about which leg dominated, twice.

**A measurement habit that worked:** `/proc/<pid>/io` read twice 30 seconds
apart proves a transfer is moving without waiting for the next log line. It
settled a "is this stuck?" question in 30 seconds that would otherwise have been
a guess.

**The date trap:** I read this Windows machine's local date against the VM's UTC
clock and declared a healthy drain "many hours stale". It was 20 minutes old.
Check `date -u` on the VM before concluding anything from a timestamp.
