---
name: restore-drill
description: Executes a full backup restore into a throwaway environment and verifies integrity. Run before declaring the project complete, and quarterly thereafter.
agent: backup-engineer
---
Two drills, each with its own log. One system's PASS never stands in for another's.

## Immich (ops/RESTORE-LOG.md)

1. Spin up a clean Immich stack in an isolated Docker network.
2. `restic restore latest --target /tmp/restore-drill`
3. Create the marker files that the exclusions omitted:
   `mkdir -p thumbs encoded-video && touch thumbs/.immich encoded-video/.immich`
4. Restore the Postgres dump from the restored backups/ directory.
5. Start Immich. Confirm: login works, asset count matches, albums exist,
   at least one face cluster is present.
6. Spot-check three restored originals against source checksums.
7. Tear down. Write the outcome and timestamp to ops/RESTORE-LOG.md.

All of this is `sudo /opt/personal-vault/ops/backup/restore-test.sh`.

## Vaultwarden (ops/VAULTWARDEN-RESTORE-LOG.md)

`sudo /opt/personal-vault/ops/vaultwarden/vaultwarden-restore-test.sh`, which,
for BOTH the Oracle restic repository and the off-Oracle Google Drive copy:

1. Restores the Vaultwarden paths only into a scratch directory.
2. Takes the newest `db_*.sqlite3` by name and deletes any `-wal`/`-shm`.
3. Requires `PRAGMA integrity_check` = ok, users > 0, and a byte match with the
   local dump of the same name while one exists.
4. Serves the restored data from a throwaway container of the production image
   with `--network none`, and requires `/alive`.
5. Appends PASS / PASS (ORACLE-ONLY) / FAIL to ops/VAULTWARDEN-RESTORE-LOG.md.

Only a plain PASS closes Vaultwarden go/no-go gate 5 (docs/VAULTWARDEN-PLAN.md).

If any step of either drill fails, that is a BLOCKER for the whole project.
