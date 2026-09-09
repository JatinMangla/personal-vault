---
name: restore-drill
description: Executes a full backup restore into a throwaway environment and verifies integrity. Run before declaring the project complete, and quarterly thereafter.
agent: backup-engineer
---
1. Spin up a clean Immich stack in an isolated Docker network.
2. `restic restore latest --target /tmp/restore-drill`
3. Create the marker files that the exclusions omitted:
   `mkdir -p thumbs encoded-video && touch thumbs/.immich encoded-video/.immich`
4. Restore the Postgres dump from the restored backups/ directory.
5. Start Immich. Confirm: login works, asset count matches, albums exist,
   at least one face cluster is present.
6. Spot-check three restored originals against source checksums.
7. Tear down. Write the outcome and timestamp to ops/RESTORE-LOG.md.

If any step fails, that is a BLOCKER for the whole project.
