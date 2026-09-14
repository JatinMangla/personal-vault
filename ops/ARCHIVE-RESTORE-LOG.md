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
manifest generated on the phone before the file ever moved.

### What it does NOT prove — read before trusting the archive

1. **Split-part rejoining is still untested against a real upload.** This file
   arrived as a single object, with no `.00`/`.01` parts. `telegram-upload`
   splits anything over the per-file limit, and rejoining those parts in
   numeric order is the path most likely to corrupt a large file silently.
   Fixtures cover it (a 12-part rejoin, proving numeric rather than lexical
   order); the real channel has not.

2. **Nobody has opened the restored file.** A matching sha256 proves the bytes
   survived, not that Insta360 Studio will read it. Open `/tmp/drill/VID_*.insv`
   in a player or in Studio before relying on this.

3. **It ran on the VM, not on a recovery machine.** The realistic scenario is
   the VM being gone. `restore.sh` is written to need nothing from it — no env
   file, no `/mnt/media`, no Syncthing or systemd — but that independence has
   not been exercised on a different machine.

Re-run and append here after the next batch that contains a multi-gigabyte
file, which is what closes point 1.
