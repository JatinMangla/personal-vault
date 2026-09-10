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

No drill has run yet. The project is not complete until at least one entry
below reads PASS.

---
