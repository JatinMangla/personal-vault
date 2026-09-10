# Restore drill log

Appended automatically by `ops/backup/restore-test.sh`.

**A backup that has never been restored is a hypothesis, not a backup.**

The `/status` dashboard reads the most recent entry here and ages it: green
under 90 days, amber 90–180, red beyond 180.

## Reading the result line

| Result | Meaning |
|---|---|
| `PASS` | Full drill. Media restored, checksums matched, the database restored and Immich served the library. |
| `PASS (DB-ONLY)` | The live library was **empty**, so only the database path was exercised. Honest but partial — see below. |
| `FAIL` | Something the drill asserts did not hold. The failures are listed in the entry. |

`PASS (DB-ONLY)` is not the finish line. It records that restic, the credentials,
the repository and the Postgres dump all work, which is genuinely worth knowing
before any photos exist. It proves nothing about restoring originals, because
there were none. **Re-run the drill once the library has photos in it.**

**Status: one `PASS (DB-ONLY)` recorded.** The database path is proven. The
media path has not been exercised, because no photos had been uploaded at the
time. The project is not complete until an entry below reads a plain `PASS`.

---
## 2026-09-10T21:43:08+00:00 — PASS (DB-ONLY)

- Snapshot: `latest`
- Assets: 0 | Albums: 0 | Faces: 0 | People: 0
- Checksums verified: 0/0
- **Scope: database only.** The live library held no originals, so the
  media restore path was not exercised. Re-run after uploading photos.
- Finished: 2026-09-10T21:43:46+00:00

What this run did prove, end to end in 38 seconds:

- Oracle Object Storage credentials authenticate and the repository opens
- restic restored snapshot `577327ab` — 12 files, 17.919 MiB
- The 18 MB dump `immich-db-backup-20260911T020000-v3.1.0-pg14.19.sql.gz`
  restored into a clean Postgres 14 under `ON_ERROR_STOP=1` with no errors
- Immich v3.1.0 started against that restored database and answered its API

The remaining unknown is whether originals restore intact, which needs
originals to exist.

