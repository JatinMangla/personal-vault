# Session handover — 2026-09-14 to 09-16

> **Newer:** the latest state, open items and deploy order are in
> `docs/REVIEW-2026-09-24.md`. This file remains the record of the 09-14 to 09-16
> decisions.

Written for the next Claude Code session. **Read `docs/HARD-WON.md` first** —
it holds the technical walls. This file holds the *decisions*, why they were
made, and what state the system is actually in, so none of it gets relitigated.

---

## What the system does now

Three separate pipelines share this repo:

| Component | State |
|---|---|
| **Document vault** (Vercel + Supabase) | Live, in use |
| **Immich** (Oracle VM) | Deployed, library still empty |
| **Insta360 → Telegram archive** | **Working and automatic** — the focus of this session |

### The archive routine, from the operator's side

**Connect the X4 → move files into `tg-batch` → walk away.** Nothing to type.

`tg-archive.path` watches `/mnt/media/tg-staging`; `tg-archive-settle.timer`
waits two minutes of quiet; `tg-archive.service` runs `tg-go.sh`, which
fingerprints what arrived, drains, and pushes metrics. Progress appears on
`/status`.

Optional, on the phone, with the card attached:
`~/bin/tg-prune.sh --apply` — deletes already-archived files from `tg-batch` so
Syncthing does not re-send them. **Not required**; skipping costs transfer time
only, never correctness.

---

## The integrity chain — do not weaken this

Nothing leaves staging until it has made a full round trip:

1. **Check #1** — every staged file hashed against the manifest
2. **Upload** to Telegram (documents, not media, so no re-encoding)
3. **Check #2** — channel downloaded back, split parts rejoined numerically,
   SHA-256 compared again
4. **Only then** staging clears and the file is recorded in `uploaded.sha256`

A failure at any point leaves staging intact and deletes nothing. This is the
property that makes the archive trustworthy; every design decision below
preserves it.

**Proven on real footage:** single files, a 2.4 GB file split into two parts and
rejoined, and two full restores from the live channel (`ops/ARCHIVE-RESTORE-LOG.md`).

---

## Decisions taken, and why — do not reverse without reading these

**Delete-after-verify, not move.** `tg-prune --apply` deletes from `tg-batch`.
The operator argued, correctly, that the alternative — clearing by hand — is
*more* dangerous: a person has no hash to check against. The script deletes only
what it has matched against the ledger and reports `same name, different
content - keeping` otherwise. `--apply --keep` moves to `tg-archived/` instead.

**Pause/resume was removed, not forgotten.** It existed for pulling the cable
mid-drain. That case never needed it: Syncthing writes partials as
`.syncthing.NAME.insv.tmp` and the uploader globs `*.insv`, which does not match
them. Twenty lines for a problem that did not exist. To stop a drain:
`systemctl stop tg-archive`.

**One batch at a time, not one file.** The batch is the verification unit.
Per-file uploading would mean per-file Check #2 — and Check #2 downloads the
*entire channel*, so eight files would mean eight full-channel downloads
(~176 GB instead of ~22). Keep batch-level.

**A batch has no fixed size.** It is whatever `"$STAGING_DIR"/*.insv` matches
when the uploader runs. The settle timer approximates "the transfer finished";
the uploader never needs a total.

**Manifest is APPENDED, never overwritten.** It records everything ever on the
card and `tg-archive status` counts against it. Overwriting collapses `total`
to the batch size and makes the drain conclude there is nothing to do. This
mistake cost a real session.

**The round trip lives on the media volume**, guarded by a hard refusal if it
would land on `/`. See "Boot volume" below.

**UDP 41641 is open by decision.** See "The relay" below.

---

## Bugs found, and the lesson from each

Every one of these was found by running the system, not by reading it.

| Bug | Lesson |
|---|---|
| A fourth eaten `\|\|` (`>/dev/null  true`) | `bash -n` cannot catch it — valid shell, wrong meaning. Grep for `>/dev/null +[a-z]` |
| Ledger written but never read | The dedupe did nothing for months. Check both halves of a mechanism |
| `pipefail` double-emission | `pipeline \|\| fallback` emits BOTH. Hidden behind running as root |
| Symlinked command could not find siblings | `readlink -f` before `dirname` |
| Four scripts committed `100644` | Windows never reports the executable bit. `git update-index --chmod=+x` |
| `sha256sum /full/path` writes the path | Hash from inside the directory |
| Unit ran `tg-archive start`, which skips the manifest | Automation would have failed on every batch, silently |
| Manifest built once, not per batch | Retried the same failure 21 times |
| Check #2 round trip filled the boot volume | 25% → 79% in 45 minutes |
| Margin guard sized by largest file | Check #2 needs archive-sized space, not file-sized |
| `tg-prune` estimates at a hardcoded 1.3 MB/s | Hardcoded measurements go stale |

**The recurring pattern**: a dangling reference after deleting a function
(`record_uploaded`, `notify`, `paused`, `RATE_MB_S` — four times). After
removing anything, grep for survivors rather than trusting the edit.

---

## The relay — the single biggest measurement of the session

Transfer ran at **~1.3 MB/s** for the entire project. `HARD-WON.md` blamed the
OTG read and Syncthing hashing. **That was inferred from one number and written
down as fact.** Three measurements disproved it:

```
copy 3.2 GB card -> phone internal storage    45 s   (~71 MB/s)
Syncthing from the card                              ~1.3 MB/s
Syncthing from internal storage                      ~1.26 MB/s
```

Source made no difference; the card is 55x faster than the transfer achieved.
`tailscale ping` then gave `direct connection not established` after ten tries —
everything relayed through Tailscale's Bangalore DERP server.

**Fixed** by an OCI ingress rule for UDP 41641. Result: `direct
38.254.161.78:45974`, latency halved, **throughput 10–16 MB/s**. 250 GB went
from ~53 hours to ~5.

No `ufw` change was needed —
`infra/ansible/roles/hardening/tasks/main.yml:121` had opened `41641/udp` since
day one, naming this exact failure. Only the OCI rule was missing.

**P1 was narrowed, not broken.** `nmap -Pn -p-` scans TCP only; `nmap -sU` was
never run, so the UDP surface was never verified closed. The claim was always
broader than its evidence. Now "zero open **TCP** ports". Reversible in two
minutes by deleting the rule.

---

## Boot volume — the newest fix

Check #2 downloads the **entire channel** to verify. The scratch directory was
`$WORK_DIR/roundtrip.$$` = `/var/lib/insta360-archive/work`, on the **50 GB boot
disk** shared with Immich, Postgres and the OS. A 20 GB drain took it from 25%
to 79% in 45 minutes and would have filled outright past ~35 GB archived.

Now `$STAGING_DIR/.roundtrip` on the 147 GB media volume. A dot-directory, so
the `*.insv` glob cannot mistake a verification copy for a new file.

**Made a rule, not a convention:** `tg-upload.sh` compares the round-trip mount
point against `/` and refuses to run if they match — catching `/mnt/media`
failing to mount, which would otherwise silently resolve under `/`.

**Resource limits added** at the operator's request, so the archive always
yields to photo and video work: `CPUQuota=75%` (of one core, on two),
`IOWeight=20`, `MemoryMax=1G`, `MemorySwapMax=0`.

---

## THE remaining structural problem — verify by message id

`telegram-download` can only fetch a **whole chat**. So Check #2 re-downloads
everything ever archived, on every batch. This has now caused **four** separate
problems:

1. `--list` takes hours on a large archive
2. The boot volume filled
3. The margin guard will eventually refuse every batch
4. ~20 minutes added to every drain today; hours at 100 GB

**The fix**, flagged since the very first session: record each file's Telegram
message id at upload time with `telegram-upload --print-file-id`, then fetch
back only that message with a small Telethon call. Same guarantee, cost becomes
batch-sized instead of archive-sized.

It is the highest-value change left. Nothing else is close.

**Second, much smaller:** Check #1 hashes the whole batch before the first
upload starts (7 minutes for 18 GB). Hashing each file immediately before
uploading it would overlap that with the network. Does not touch the
verification model.

---

## Live state as of 2026-09-15 19:32 UTC

- Boot volume **24.8%**, flat — the fix is holding
- Media volume 19 GB used, 127 GB free
- A drain is **running**: 8 files, 18.3 GB, uploading at ~3.6 MB/s to Telegram
- Archive holds ~22 GB; ledger `uploaded.sha256` has 11 entries
- Telegram upload rate is **Telegram's own ingest limit**, not a local constraint

---

## Environment traps

**This Windows machine:** npm is unrunnable — Node was installed by nvm under
the `Administrator` account, so `npm-cli.js` is a stub resolving through a
junction into a profile this user cannot read. Every gate works via the direct
binaries:

```bash
cd vault
"/c/Program Files/nodejs/node.exe" node_modules/typescript/bin/tsc --noEmit
"/c/Program Files/nodejs/node.exe" node_modules/vitest/vitest.mjs run
"/c/Program Files/nodejs/node.exe" node_modules/next/dist/bin/next build
"/c/Program Files/nodejs/node.exe" scripts/check-client-bundle.mjs
```

**Git Bash quirks:** `ln -s` creates a regular file, so symlink behaviour cannot
be tested here. `sha256sum` defaults to binary mode and prefixes `*`.

**Commit messages:** backticks inside `-m "..."` are executed. Use `git commit -F -`
with a heredoc.

**The operator has no laptop or Mac** — Android phone plus the VM only. Termux
typing is slow and expensive: prefer one command over several, and always label
which machine a command runs on. The phone's key is `~/.ssh/immich_phone` and
lives on the *phone*; running `scp -i ~/.ssh/immich_phone` while already on the
VM fails, which caught the operator three times.

---

## Still open

| Item | Status |
|---|---|
| ~~Verify by message id~~ | **Done 2026-09-16.** `--print-file-id` → 4th ledger column → `tg-fetch-ids.py`. Check #2 is batch-sized, not archive-sized. **Not yet exercised on a real batch** — the drain running at the time predates it |
| Restored file opens in Insta360 Studio | **Blocked on hardware** — no laptop/Mac. Not chaseable |
| `.10`-before-`.2` part ordering | Fixture-only. Needs a ~22 GB file to surface; will not in practice |
| P3 restore drill (Immich) | Still `PASS (DB-ONLY)` — needs photos in the library |
| Overlap Check #1 hashing with uploading | Small win, contained |

---

## How this session went wrong, and what prevented worse

Three times I stated something as verified fact that was inferred:

- **"Termux cannot read the OTG card"** — written into HARD-WON as settled, a
  working script deleted on the strength of it. The operator's single
  `ls /storage/9C33-6BBD/` disproved it. `/storage/` being denied says nothing
  about a named child.
- **"The OTG read is the bottleneck"** — shaped batch sizing for days. It was
  the relay.
- **"restore.sh has never run"** — misread as "exists but untested". It did not
  exist at all.

The pattern: a single observation generalised into a rule, then written down
with more confidence than the evidence supported. **Test the specific path
before recording an impossibility.**

What caught the real bugs: fixture tests that reproduced the failure first, and
grepping for survivors after every deletion. Both are cheap. Neither is
optional here.
