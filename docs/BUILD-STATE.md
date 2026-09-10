# Build state and next actions

Last updated: **2026-09-11**

Everything buildable without cloud accounts is complete and verified. What
remains requires provisioning, which needs your credentials.

---

## Verified in this repository

These were run, not assumed:

| Check | Result |
|---|---|
| Crypto test suite (`npm test`) | **46/46 passing** |
| Responsive + hydration (`npm run test:e2e`) | **140/140** across 5 viewports, Chromium + WebKit |
| TypeScript (`npm run typecheck`) | zero errors |
| Production build (`npm run build`) | succeeds; 5 API routes, 3 pages |
| Client bundle scan (`npm run check:bundle`) | clean across 12 chunks |
| Secret-blocking hook | **14/14** — blocks 9 credential shapes, allows 5 legitimate patterns |
| Shell scripts (`bash -n`) | all parse |
| YAML (15 files) | all parse |
| `npm audit` | no high or critical; 2 moderate dev-only, documented |

## Part 1 COMPLETE - verified with real data (2026-09-10)

The document vault is live, in use, and confirmed working end to end:
a real file was encrypted in the browser, uploaded, and downloaded back.

| Verified against the live project | Result |
|---|---|
| Account + vault key material | 1 user, 1 `user_keys` row |
| File uploaded | 1 row in `files`, 1 blob in `vault-files` |
| Byte counts match | 8,810 in both the row and the blob |
| Filename in the database | **ciphertext** - unreadable even with admin access |
| Object key | random, leaks nothing about the file |
| Stored MIME type | `application/octet-stream` |
| Blind index for duplicates | present |
| **RLS cross-user isolation** | **a different user sees 0 rows** |

That last line is the spec sign-off item "a second Supabase user cannot read the
first user's file rows (RLS verified by test, not by inspection)."

### Bugs found by real use, not by the test suite

Four, all in the account-setup path, all now fixed:

1. CSP blocked Next's inline hydration scripts - every page hung at "Loading..."
2. The session check had no error handling - an unreachable Supabase hung the
   page identically, with no message
3. `signUp()` returns no session when email confirmation is on, so key material
   was never written - the account could sign in but never unlock
4. The unlock screen then offered "visit /login to create one", which does
   nothing when already signed in - a loop with no exit

Root cause common to 3 and 4: the flow assumed a session always exists at
signup. Automated coverage there remains thin because it needs a live Supabase
auth flow; the CSP regression is now covered by 5 tests.

## Deployed and verified live (2026-09-10)

Component B (document vault) is **deployed and working** at
`https://vault-amber-five.vercel.app`.

| Check | Result |
|---|---|
| Supabase tables + RLS | `files`, `user_keys`, `metrics_samples`, all RLS on |
| Table policies | 4 / 3 / 1, scoped to `auth.uid()` |
| Bucket `vault-files` | private, 100 MB per-object limit |
| Storage policies | 4, granted to `authenticated` only |
| Functions | `user_storage_bytes`, `prune_metrics_samples`, `touch_updated_at` |
| All pages | 200 |
| `/api/files`, `/api/metrics/latest` | 401 without a session |
| `/api/metrics/ingest` | 405 on GET; 401 on unsigned or forged POST |

Supabase project is `bpbsfpzowzxcrhscjfwk` in **ap-northeast-1 (Tokyo)**, not
Mumbai. Functionally identical on the free tier; adds roughly 50 ms of latency
from Pune. Not worth recreating unless it becomes noticeable.

Note: the Supabase MCP connector authorises **one organisation at a time**, so
seeing this project required switching the connector away from the org holding
the unrelated `stock-inventory` app.

## Part 2 (Immich) — DEPLOYED AND VERIFIED (2026-09-11)

Running on Oracle `immich-mumbai`, Tailscale `100.88.183.74`, public
`152.67.1.135`.

| Check | Result |
|---|---|
| Containers | server, postgres, ML, redis — **all healthy** |
| Immich API | answers on the Tailscale address only |
| Metrics collector | `api_ok: true`, 0 failed jobs, pushing every 15 min |
| Dashboard | renders real storage, RAM, uptime, container dots |
| healthchecks.io ping | succeeds (no `curl: (22)`) |
| **P1: zero open ports** | **VERIFIED from outside** — 22, 80, 443, 2283, 111, 3000, 5432, 8080 all closed/filtered |

Admin access is Tailscale-only, from an Android phone via Termux. There is no
laptop dependency: the office laptop's key was deliberately not relied on, and
a phone-generated key (`immich-phone`) is installed instead.

### Ingress rules kept, deliberately

The `0.0.0.0/0` TCP/22 rule was removed. Two ICMP rules were KEPT:

- `0.0.0.0/0` ICMP 3,4 — Path MTU Discovery. Removing this causes a nasty
  failure mode where small requests succeed but large transfers hang, which
  would break photo uploads in a way that is very hard to diagnose.
- `10.0.0.0/16` ICMP 3 — internal to the VCN only.

Neither opens a service or carries data.

## STILL OUTSTANDING — the backup half

**Gozunga is unusable: it accepts online signups only from the US and Canada.**
That was a specification error — the provider was chosen without checking
regional availability, and the user reached the signup wall before it surfaced.

No card-free provider offers 100 GB free in India, so the spec's $1/year ceiling
and its "every original in two physically separate locations" rule are now in
direct conflict. Pending a decision between:

| | Cost | Offsite copy | Holds ~90 GB |
|---|---|---|---|
| Backblaze B2 | ~$6/year | yes | yes |
| Home external drive only | $0 | no | manual, and the owner travels |
| Oracle Object Storage | $0 | yes | no — 20 GB |

Until this is resolved, `immich-backup.sh` has no target, **the restore drill
has never run**, and photos exist on exactly one disk. The dashboard and
`thresholds.ts` still say "Gozunga" and 100 GB; those labels change once the
provider is chosen.

## Not yet verified — requires live infrastructure

| Gate | Blocked on |
|---|---|
| **P3 restore drill** | An Oracle VM with Immich running and at least one backup |
| P1 `nmap` zero-open-ports | A provisioned VM with a public IP |
| P2 face recognition / semantic search | Immich running with a photo library |
| P7 metrics arriving every 15 min | The collector running on the VM |
| P8 free-tier ledger at $0.00 | Live accounts to check against |

**The restore drill is the one that matters most.** A backup that has never been
restored is a hypothesis. `ops/backup/restore-test.sh` is written and ready, but
until it has run and appended a PASS to `ops/RESTORE-LOG.md`, the durability
claim in the README is untested.

---

## What to do next, in order

### 1. Oracle Cloud (the long pole)

**Once the VM exists, one command does the rest:**

```bash
git clone https://github.com/JatinMangla/personal-vault.git
bash ~/personal-vault/infra/setup-on-vm.sh
```

**On Windows, follow `infra/docs/WINDOWS-DEPLOY.md`** — Ansible cannot run from
a Windows laptop, so that guide runs it on the VM itself. Use
`infra/docs/oracle-setup.md` for the console steps it references. Two irreversible decisions:

- **Home region must be `ap-mumbai-1` or `ap-hyderabad-1`** — it cannot be
  changed after account creation.
- **Provision 2 OCPU / 12 GB, never 4/24** — Oracle terminates instances that
  exceed the Always Free entitlement.

Set the **$1 budget alert before provisioning anything**, and keep the 150 GB
block volume at **Lower Cost / 0 VPU**.

Expect "Out of host capacity" on ARM in Indian regions. Retry over hours or
days; this is normal.

```bash
cd infra/ansible
cp inventory.example.ini inventory.ini      # edit it
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory.ini playbook.yml \
  --extra-vars "tailscale_auth_key=$TS_AUTHKEY" \
  --extra-vars "immich_db_password=$(openssl rand -base64 32)"
```

Then delete every ingress rule in the OCI security list and verify from outside:

```bash
nmap -Pn -p- <public-ip>     # expect zero open ports
```

### 2. Immich settings

`infra/docs/immich-settings.md`. The ones that matter:

- Video transcoding: **"not browser-compatible only"**, never "all"
- **Do not** convert HEIC to JPEG
- Enable automatic database backups at **02:00** (the restic job runs at 03:00)
- Create a **read-only** API key for the metrics collector

### 3. Backup, then the restore drill

```bash
sudo rsync -a ops/ /opt/personal-vault/ops/
sudo install -m 0600 /dev/null /etc/personal-vault/ops.env   # then fill it in
sudo install -m 0600 /dev/null /root/.restic-pass            # then fill it in
sudo cp ops/systemd/*.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now immich-backup.timer metrics-push.timer
```

**Store the restic password somewhere that is not this machine.** Losing it is
identical to losing the backup.

Let the nightly job run, then:

```bash
sudo /opt/personal-vault/ops/backup/restore-test.sh
```

This is a **blocking gate**. Do not consider the project complete until it
appends a PASS to `ops/RESTORE-LOG.md`.

### 4. Supabase (database AND file storage)

Create a project, then apply BOTH migrations in the SQL Editor, in order:

```
vault/supabase/migrations/0001_initial_schema.sql     tables, RLS, quota function
vault/supabase/migrations/0002_storage_bucket.sql     private bucket + storage RLS
```

Or from a terminal:

```bash
psql "$SUPABASE_DB_URL" -f vault/supabase/migrations/0001_initial_schema.sql
psql "$SUPABASE_DB_URL" -f vault/supabase/migrations/0002_storage_bucket.sql
```

Confirm the bucket exists and is **private**: Storage -> Buckets -> `vault-files`
should show a padlock / "Private". A public bucket would expose every blob to
anyone who could guess a key.

Verify RLS is actually on — the migration enables it, but check rather than
trust, because a table without RLS is world-readable to anyone with the anon key:

```sql
select tablename, rowsecurity from pg_tables where schemaname = 'public';
```

Then add `SUPABASE_URL` and `SUPABASE_ANON_KEY` as repository secrets so
`supabase-keepalive.yml` can run. Free projects pause after 7 days idle, and a
paused project breaks the vault silently.

### 5. Cloudflare — NOT NEEDED

Cloudflare R2 was the original blob store and has been removed. It required a
payment method with no spending cap, which conflicted with the no-automatic-
billing rule. Document blobs now live in Supabase Storage (step 4).

**Do not create a Cloudflare account or enter a card.** No CORS configuration is
needed either — Supabase Storage accepts the signed upload URL directly.

### 6. Vercel

The repository must be under a **personal GitHub account, not an organisation** —
Hobby projects cannot connect to org-owned repos.

Set every variable from `vault/.env.example` in the dashboard — there are now
**four**, not eight:

| Variable | Source |
|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | Supabase -> Settings -> API -> Project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | Supabase -> Settings -> API -> anon key |
| `SUPABASE_SERVICE_ROLE_KEY` | Supabase -> Settings -> API -> service_role key |
| `METRICS_INGEST_SECRET` | `openssl rand -hex 32` |

`SUPABASE_SERVICE_ROLE_KEY` and `METRICS_INGEST_SECRET` are **server-only**:
never prefix them `NEXT_PUBLIC_`. Set **Root Directory = `vault`** in
Settings -> General, or the build fails.

Set `METRICS_INGEST_SECRET` to the same value as in `/etc/personal-vault/ops.env`
on the VM, or the collector's pushes will be rejected as unsigned.

### 7. Monitoring

`ops/monitoring/healthcheck-setup.md`. Create the two checks, then **deliberately
fail one run** to confirm the alert actually arrives. An untested alerting path
is an assumption, not an alert.

### 8. Final sign-off

Work through the checklist at the end of `PROJECT_SPEC.md`. The items needing
live services: `nmap`, face recognition, three consecutive nightly backups, the
restore drill, RLS cross-user isolation, a 200 MB+ file on an iPhone, PWA install
on all three devices, the staleness banner going red after stopping the
collector, and gitleaks over the full history.

---

## Decisions taken during the build worth knowing about

- **Next 16.3.4, not 15.x.** npm flagged the originally-pinned 14.2.15 as
  carrying a security vulnerability. 16.3.4 clears the high-severity postcss
  advisories and supports Node ≥ 20.9.0.
- **Supabase pinned to 2.100.0 / ssr 0.7.0.** Newer releases require Node 22;
  this machine runs Node 20.16.0.
- **vitest 3.2.7, not 4 or 5.** npm 10.8.1's arborist crashes resolving
  vitest 4's optional peer graph, and vitest 5 wants `@types/node` ≥ 22. Both
  documented in `vault/SECURITY-NOTES.md`.
- **`lib/supabase.ts` was split** into browser/server/types modules. As one
  module it pulled `next/headers` into the client bundle and the build failed —
  which was the client/server boundary doing its job.
- **Storage moved from Cloudflare R2 to Supabase Storage.** R2 needs a card on
  file and has no spending cap, breaking spec rule 1.1. Cost: 1 GB free instead
  of 10 GB, accepted because documents here are mostly PDFs and office files.
  The crypto core was untouched. See `vault/SECURITY-NOTES.md`.
- **CSP tightened.** `style-src` is `'self'` with no `unsafe-inline`; only the
  narrow `style-src-attr` exception remains, for four genuinely dynamic values.
  Rationale in `vault/SECURITY-NOTES.md`.

## Deferred, deliberately (v2)

Recorded so they are not forgotten and not attempted prematurely:

- OCR over photos (PaddleOCR batch on the VM) — the highest-value future addition
- Whisper transcripts for video
- Frame-level video semantic search
- Paperless-ngx, only if the E2EE trade-off is consciously reversed for documents
- A natural-language query layer over embeddings, faces, EXIF and OCR
