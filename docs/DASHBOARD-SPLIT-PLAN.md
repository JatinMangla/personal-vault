# Plan: split the Camera archive card, and make /status near-live

**Status: planned, not started.** Written 2026-09-16. Read
`docs/SESSION-HANDOVER.md` and `docs/HARD-WON.md` first — this plan assumes the
decisions and traps recorded there.

## Context

The `/status` **Camera archive** card mixes two unrelated pipelines into one
flat list, so it is hard to tell what is happening. They want them separated:
**phone → VM** (Syncthing) and **VM → Telegram** (the drain), each with its own
counts, sizes and current activity — and the data as fresh as possible.

Investigation found the data mostly does not exist yet:

- **The collector never queries Syncthing at all.** Section 1 is entirely new
  collection. `tg-go.sh`'s `sync_key()` / `sync_status()` already parse
  `needBytes` and `state` and should be reused rather than rewritten.
- **`status` has no phase.** It is only `idle|running|complete|incomplete`, so
  it cannot distinguish hashing from uploading from verifying — though
  `tg-upload.sh` already *logs* all six transitions.
- **Freshness is ~22 minutes worst case** (collector 15 min, page polls 7).

**Realtime is not achievable** and this plan does not pretend otherwise: the VM
has no inbound ports and Vercel cannot reach it over Tailscale, so the page can
only ever read what was last pushed. The cadence drops to **1 minute**, which is
near-live in practice.

### Decisions already taken by the operator

| | |
|---|---|
| Cadence | **1 minute** collector, 30s page poll |
| Phase markers | **Yes** — `tg-upload.sh` writes its current phase |
| Retention | **30 days**, pruned nightly (~43,000 rows, ~82 MB) |
| Staleness banner | Retuned to **amber 5 min, red 15 min** |

---

## Part 1 — Collect what Section 1 needs

**`ops/metrics/collect-and-push.sh`** gains a `sync` block, reusing the logic
from `ops/insta360-bin/tg-go.sh` (`sync_key`, `sync_status`):

```json
"sync": { "state": "...", "need_bytes": N, "need_files": N,
          "global_files": N, "local_files": N, "connected": true }
```

`/rest/db/status?folder=$SYNC_FOLDER` gives the first five;
`/rest/system/connections` gives `connected` for the phone's device id. Both
must degrade to zeros rather than failing the push — a collector that dies on an
unreachable Syncthing takes the whole dashboard down, including the parts that
work.

**Two blockers in `ops/systemd/metrics-push.service`:**

1. `ProtectHome=true` hides `/home/ubuntu/.local/state/syncthing/config.xml`,
   where the API key lives. Must become `ProtectHome=read-only` — the identical
   fix already recorded for the restic job in `docs/HARD-WON.md`.
2. `TimeoutStartSec=5m` assumes a 15-minute interval. At 1 minute, drop it to
   `60s` and correct the comment. The collector normally takes ~2 s; systemd
   will not start a second instance of a running oneshot, so an overrun degrades
   to "as often as it can" rather than piling up.

---

## Part 2 — Phase markers

**`ops/insta360-bin/tg-upload.sh`** writes a phase file at the six points it
already logs:

| Line | Phase |
|---|---|
| 166 | `hashing` (Check #1) |
| 206 | `uploading` + current filename and index |
| 216 | `downloading` (Check #2) |
| 278 | `rejoining` |
| 298 | `verifying` |
| 307 | `clearing` |

Write it the way `write_state()` in `tg-archive.sh` already does — to
`$WORK_DIR/phase.tmp` then `mv`, so the collector can never read a half-written
file. Add a `cleanup` entry to the existing `EXIT` trap so a killed run does not
leave a stale `uploading` showing forever.

`tg-archive.sh`'s `write_state()` then folds `phase`, `phase_file` and
`phase_index` into `drain-state`, and the collector passes them through in the
existing `archive` block.

---

## Part 3 — Two cards on /status

**`vault/app/status/page.tsx`** — replace the single `Camera archive` card with
two, using the existing `HealthCard`, `StatRow` and `LimitMeter` from
`vault/components/HealthCard.tsx`.

**Card 1 — "Card → VM (Syncthing)"**
- Transfer state, and whether the phone is connected
- Files announced vs received; bytes still to arrive
- A `LimitMeter` of delivered / total for this transfer
- Staging size, and **boot volume %** — from the existing `storage.boot_used` /
  `boot_total`, which need no new collection
- Estimated time left at the measured ~12 MB/s

**Card 2 — "VM → Telegram (archive)"**
- **Current phase** in plain words: *Hashing 8 files*, *Uploading 3 of 8*,
  *Downloading the channel to verify*, *Rejoining parts*
- Files in staging, archived total, remaining
- Bytes archived, media-volume usage, round-trip scratch size
- Progress meter, and the existing `incomplete` explanation

Both keyed on optional fields (`payload.sync?`, `payload.archive?`) and guarded
with `?? 0` — every sample collected before today lacks them entirely, which is
the sharper version of the `staging_bytes` `NaN` bug already fixed once.

Types go in `vault/lib/supabase-types.ts` alongside the existing optional
`archive` block.

---

## Part 4 — Cadence, retention, staleness

**`ops/systemd/metrics-push.timer`** — `OnUnitActiveSec=1min`, plus
`AccuracySec=1s` (systemd defaults to 1-minute accuracy, which would make a
60-second timer arrive erratically).

**`vault/app/status/page.tsx:70`** — poll every 30 s instead of 7 min.

**`vault/lib/thresholds.ts`** — `stalenessState()` becomes amber above 5 min,
red above 15 min. The banner exists so a frozen dashboard cannot look healthy;
at 1-minute sampling the current 30 min / 2 h would hide a collector that died
half an hour ago. One consumer, at `page.tsx:109`.

**Retention — this is the part that is currently broken.** Measured: **1,889
bytes/row**, 490 rows, 904 kB. At 1/minute that is ~2.7 MB/day.
`prune_metrics_samples()` exists and retains 90 days, but its own comment says
*"Invoked by the nightly GitHub Action"* — **and no such Action exists**.
Retention is unbounded today. Invisible at 15 minutes (~8,600 rows/year);
~245 MB/year at 1 minute, against a 500 MB tier shared with `files` and
`user_keys`.

Two changes, both needed:

1. `vault/supabase/migrations/` — a new migration changing the interval from
   `90 days` to `30 days`. Do not edit `0001_initial_schema.sql`; it is already
   applied.
2. `.github/workflows/prune-metrics.yml` — nightly, modelled on
   `supabase-keepalive.yml`. **It needs the service-role key, not the anon
   key**: the function is `security definer` with `revoke all ... from public`.
   Add `SUPABASE_SERVICE_ROLE_KEY` as a repository secret, and follow the
   keepalive's pattern of failing loudly when a secret is missing.

---

## Verification

**Shell:**

```bash
bash -n ops/metrics/collect-and-push.sh ops/insta360-bin/tg-upload.sh \
       ops/insta360-bin/tg-archive.sh
```

Then pipe the assembled payload through `python3 -m json.tool` — the `sync`
block sits between `storage` and `archive`, and a missing comma there is the
3 a.m. failure this project has already had once.

**Vault gates** (npm is unusable on the Windows machine — use the node-direct
bypass recorded in `docs/SESSION-HANDOVER.md`): typecheck, tests, build, bundle
scan. Add a case to `vault/__tests__/storage-segments.test.ts` for
`sync: undefined`.

**On the VM:**

```bash
sudo cp ops/systemd/metrics-push.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl restart metrics-push.timer
systemctl list-timers metrics-push --no-pager      # expect ~60s
/opt/personal-vault/ops/metrics/collect-and-push.sh   # as root, expect HTTP 201
```

**Then confirm the new blocks arrive**, via the Supabase MCP tool:

```sql
select collected_at,
       payload->'sync'->>'state'      as sync_state,
       payload->'sync'->>'need_bytes' as need_bytes,
       payload->'archive'->>'phase'   as phase
from public.metrics_samples order by collected_at desc limit 3;
```

`sync_state` must be a real string, not `null` — `null` means
`ProtectHome=read-only` was not applied and the collector cannot read the
Syncthing key.

**End to end:** connect the X4, move a file, and watch both cards fill in
without touching anything. Card 1 should show bytes falling; Card 2 should move
through hashing → uploading → downloading → verifying.

**Retention:** run the new workflow manually via `workflow_dispatch` and confirm
it reports rows deleted, then re-check the row count.
