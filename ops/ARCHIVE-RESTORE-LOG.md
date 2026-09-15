# Telegram archive restore log

Restores of the Insta360 → Telegram archive, run with
`ops/insta360-bin/restore.sh`.

**An archive that has never been restored is a hypothesis, not an archive.**

This is a **separate log from `ops/RESTORE-LOG.md`**, which records the
restic/Immich drill and is what `/status` ages for the P3 gate. The two systems
back up different things to different places; one log must never stand in for
the other.

## Reading the result line

| Result | Meaning |
|---|---|
| `PASS` | Every restored file was byte-identical to what left the card. |
| `RESTORED (UNVERIFIED)` | Files came back, but some or all were not checked against a manifest. Not a pass. |
| `NOTHING DONE` | Everything was skipped because it already existed. Nothing was verified. **Not a pass.** |
| `FAIL` | A restored file did not match its manifest hash. |

---

## 2026-09-15T13:17:58+00:00 — PASS (split file, 2 parts)

**The last untested path in the system.** Every previous batch was a single
object under Telegram's 2000 MiB limit, so `telegram-upload`'s splitting and the
numeric rejoin had only ever run against fixtures.

- File: `VID_20260206_155947_00_126.insv`, 2.4 GB
- Split into **2 parts** by telegram-upload
- Upload: 3m18s | Check #2 round trip: 4m18s
- `rejoined 2 part(s)` → `round trip verified` → staging cleared

The rejoin is `sort -n -k1,1` on the numeric suffix, identical in
`tg-upload.sh` and `restore.sh` so Check #2 and a later restore cannot
disagree. At two parts numeric and lexical ordering coincide, so **this run did
not stress the ordering itself** — the `.10`-before-`.2` hazard still has only
fixture coverage. A file large enough to split into eleven parts (~22 GB) would
close that, and is unlikely to occur in practice.

What it did prove: splitting, reassembly and hash verification all work on real
footage of a size that actually occurs.

## 2026-09-14T15:35:48+00:00 — PASS

First restore from the real channel. Until this run, the archive had only ever
been written to.

- Channel: `-1004430700436`
- Restored: `VID_20250219_155539_00_032.insv`
- Verified against: `manifest.sha256`
- Files written: 1 | Verified: 1 | Failed: 0
- Run from: the Oracle VM
- Elapsed: ~16 s to fetch and verify

**What this proves.** A file uploaded to Telegram can be downloaded back and is
byte-identical to what left the card. The credentials work, the channel is
readable, `telegram-download` retrieves the object, and the sha256 matches the
manifest generated on the VM from what Syncthing delivered. That proves the
restored file matches the VM's copy; it does not by itself prove the VM's copy
matched the card, because this run's manifest was built after the transfer.

(An earlier note here claimed a card-side manifest was impossible because
Termux cannot read the OTG card. That was wrong — `/storage/` is denied but
`/storage/9C33-6BBD/` is readable, so future batches can be fingerprinted on
the card for the stronger guarantee. See `docs/HARD-WON.md`. Syncthing also
hashes every block it transfers, so the card→VM leg was never unprotected.)

### What it does NOT prove — read before trusting the archive

1. **Split-part rejoining is still untested against a real upload.** This file
   arrived as a single object, with no `.00`/`.01` parts. `telegram-upload`
   splits anything over the per-file limit, and rejoining those parts in
   numeric order is the path most likely to corrupt a large file silently.
   Fixtures cover it (a 12-part rejoin, proving numeric rather than lexical
   order); the real channel has not.

2. **Nobody has opened the restored file — and nobody can yet.** A matching
   sha256 proves the bytes survived, not that Insta360 Studio will read them.
   **Blocked on hardware: there is no laptop or Mac.** This is not an oversight
   to chase; it waits for a machine that can run Studio.

   Partial check available meanwhile: copy a restored file to the phone and
   open it in the Insta360 app. The app is more forgiving than Studio, so a
   success there is evidence rather than proof — but a *failure* would be
   conclusive and worth knowing immediately.

3. **It ran on the VM, not on a recovery machine.** The realistic scenario is
   the VM being gone. `restore.sh` is written to need nothing from it — no env
   file, no `/mnt/media`, no Syncthing or systemd — but that independence has
   not been exercised on a different machine.

Re-run and append here after the next batch that contains a multi-gigabyte
file, which is what closes point 1.

---

## 2026-09-14T18:10:19+00:00 — PASS

Second restore, run on demand rather than as a drill, to confirm the recovery
recipe works as a routine operation and not just once.

- Restored: `VID_20250219_155539_00_032.insv` into `~/recovered`
- Files written: 1 | Verified: 1 | Failed: 0
- Elapsed: ~15 s

The recipe, for when the card is long wiped:

```bash
source /etc/personal-vault/tg-archive.env
mkdir -p ~/recovered
/opt/insta360-archive/bin/restore.sh --into ~/recovered --manifest "$MANIFEST"
```

**Observed cost, and why it matters later.** Three invocations in a row
(`--list`, `--dry-run`, then the restore) each downloaded the entire channel —
the same 19 MB, three times. `telegram-download` cannot fetch metadata alone or
filter by name. At two objects that is 15 seconds each; at 200 GB, `--list`
alone becomes hours, and the archive gets painful to use at exactly the moment
it is needed. Recording each file's message id at upload time is the fix.
