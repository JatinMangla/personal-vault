# Build state and next actions

Last updated: **2026-09-09**

Everything buildable without cloud accounts is complete and verified. What
remains requires provisioning, which needs your credentials.

---

## Verified in this repository

These were run, not assumed:

| Check | Result |
|---|---|
| Crypto test suite (`npm test`) | **46/46 passing** |
| Responsive audit (`npm run test:e2e`) | **130/130** across 5 viewports, Chromium + WebKit |
| TypeScript (`npm run typecheck`) | zero errors |
| Production build (`npm run build`) | succeeds; 5 API routes, 3 pages |
| Client bundle scan (`npm run check:bundle`) | clean across 12 chunks |
| Secret-blocking hook | **14/14** — blocks 9 credential shapes, allows 5 legitimate patterns |
| Shell scripts (`bash -n`) | all parse |
| YAML (15 files) | all parse |
| `npm audit` | no high or critical; 2 moderate dev-only, documented |

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

Follow `infra/docs/oracle-setup.md` exactly. Two irreversible decisions:

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

### 4. Supabase

Create a project, then apply the schema:

```bash
psql "$SUPABASE_DB_URL" -f vault/supabase/migrations/0001_initial_schema.sql
```

Verify RLS is actually on — the migration enables it, but check rather than
trust, because a table without RLS is world-readable to anyone with the anon key:

```sql
select tablename, rowsecurity from pg_tables where schemaname = 'public';
```

Then add `SUPABASE_URL` and `SUPABASE_ANON_KEY` as repository secrets so
`supabase-keepalive.yml` can run. Free projects pause after 7 days idle, and a
paused project breaks the vault silently.

### 5. Cloudflare R2

Create a bucket. Create an API token scoped to **that one bucket**, object
read/write only — never an account-level token.

CORS must allow PUT and GET from your Vercel origin, or direct browser uploads
will fail:

```json
[{
  "AllowedOrigins": ["https://your-app.vercel.app"],
  "AllowedMethods": ["GET", "PUT"],
  "AllowedHeaders": ["*"],
  "MaxAgeSeconds": 3600
}]
```

### 6. Vercel

The repository must be under a **personal GitHub account, not an organisation** —
Hobby projects cannot connect to org-owned repos.

Set every variable from `vault/.env.example` in the dashboard. The four R2
variables and `SUPABASE_SERVICE_ROLE_KEY` are **server-only**: never prefix them
`NEXT_PUBLIC_`.

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
