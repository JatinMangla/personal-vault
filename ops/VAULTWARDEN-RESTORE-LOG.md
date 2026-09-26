# Vaultwarden restore drill log

Appended by `ops/vaultwarden/vaultwarden-restore-test.sh`. Kept separate from
`RESTORE-LOG.md` (the Immich drill) and `ARCHIVE-RESTORE-LOG.md` (Telegram), so
one system's PASS can never stand in for another's.

**A backup that has never been restored is a hypothesis, not a backup.**

## Reading the result line

| Result | Meaning |
|---|---|
| `PASS` | The newest dump restored from **both** the Oracle copy and the off-Oracle copy, passed `integrity_check`, matched the local dump byte for byte (while one exists), held users, and served `/alive` from a throwaway container with no network. |
| `PASS (ORACLE-ONLY)` | The Oracle copy passed; the off-Oracle copy is not configured yet. Honest but partial: go/no-go gate 5 needs a plain `PASS`. |
| `FAIL` | A configured copy did not restore. The failures are listed in the entry. |

**Status: no drill has run yet.** It needs the deployed vault and one 03:00
backup run after it (`docs/VAULTWARDEN-RUNBOOK.md`, step 10).

---
