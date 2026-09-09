# Personal Media & Document Vault

A personal photo, video and document archive that costs **$0.00/year** and keeps
every original in at least two places.

Four components, one monorepo:

| | Component | What it is | Where it runs |
|---|---|---|---|
| **A** | Media engine | Immich, **deployed** not rebuilt | Oracle Cloud Always Free (Mumbai) |
| **B** | Document vault | End-to-end encrypted, **built here** | Vercel + Supabase (DB + Storage) |
| **C** | Backup & ops | restic, systemd, restore drills | Oracle VM → Gozunga |
| **D** | Health dashboard | Push-based metrics at `/status` | Oracle collector → Vercel → Supabase |

---

## Two things to read before trusting this with your data

### 1. Losing your passphrase **and** recovery code means permanent data loss

The document vault is end-to-end encrypted. Files are encrypted in your browser
with AES-256-GCM before upload; the storage provider holds only ciphertext and
Vercel never sees the key. Nobody — not Supabase, not Vercel, not the author of
this repository — can decrypt your files without your passphrase.

The recovery code shown once at setup is the only backstop. **Write it down and
store it somewhere physical.** If you lose both, the files are unrecoverable.

That is the correct behaviour of an encrypted system, not a bug. It is the same
property that makes the encryption meaningful.

### 2. Videos are unprotected between monthly drive connections

Photos and documents are backed up nightly to Gozunga. **Videos are not.** They
are the bulk of the gigabytes and will not fit any free tier, so they are copied
to an external drive at home, manually, monthly.

If the Oracle box dies three weeks after your last sync, **up to three weeks of
video is gone.**

The paid alternative is roughly **$8/year on Backblaze B2**. This gap is a
deliberate trade-off to hold the $1/year ceiling, not an oversight. If your video
archive is worth more than $8/year to you, take the B2 option.

---

## Why the media half is not on Vercel

The original brief said "deploy everything with Vercel + GitHub". For the photo
engine that is not possible, and attempting it would waste weeks.

Immich needs PostgreSQL with pgvector, a Valkey queue, a persistent filesystem
and long-running ML workers. Vercel Hobby functions cap at 60 seconds with no
persistent disk and no GPU. That is a category mismatch, not a tuning problem.

Immich also does not need to be built. It is a mature AGPL-3.0 project that
already implements CLIP semantic search, face recognition, background mobile
backup, albums and sharing. So `infra/` **deploys** it and this repository
contains no photo-management code.

## Mobile: no app store fees, and none needed

| Need | Client | Cost |
|---|---|---|
| Photos, video, search, faces | Immich's official app (Play Store / App Store) | Free |
| Automatic camera-roll backup | Immich's official app — **native only** | Free |
| Documents | This PWA | Free |
| Storage & health monitoring | This PWA (`/status`) | Free |

Background camera-roll upload is **only** possible in a native app — iOS does not
grant a browser that permission. If photos were a PWA, automatic backup would
silently stop, which defeats the point of a personal archive. Documents are a
deliberate user action, so the PWA costs nothing there.

No developer account is needed. Nothing is submitted or reviewed.

---

## Free-tier budget ledger

| Service | Free allowance | Projected usage | Overage risk | Guard |
|---|---|---|---|---|
| Oracle compute | 2 OCPU / 12 GB ARM | 2 / 12 | Terminated if exceeded | Never resize up |
| Oracle block storage | 200 GB | 200 GB (50 boot + 150 block) | VPU tier is billable | Keep block volume at **0 VPU** |
| Oracle egress | 10 TB/mo | < 50 GB | None | — |
| Supabase Storage | 1 GB files, 5 GB/mo egress | < 1 GB | Low — no card on file | Soft limit refuses uploads at 90% |
| Vercel Hobby | 100 GB transfer | < 1 GB | Very low — files bypass Vercel | Presigned URLs only |
| Supabase | 500 MB Postgres | < 50 MB | Low | Metadata only, no blobs |
| Gozunga | 100 GB storage | 60–90 GB | Egress $5/TB on restore | Photos and docs only, no video |
| Tailscale | 3 users / 100 devices | 1 / ~4 | None | — |
| GitHub Actions | 2,000 min/mo | < 100 min | None | — |
| healthchecks.io | 20 checks | 2 | None | — |
| **Total** | | | | **$0.00/year** |

**The single most expensive mistake available** is raising the block volume's VPU
tier. VPUs bill separately from capacity at ~$0.0017 per VPU per GB-month;
150 GB at Balanced is about **$3/month**, or 36× the entire annual budget. It is
two clicks away in the OCI console. Don't.

Re-verify with `/verify-free-tier` before any release. Free tiers change without
notice — Oracle halved its ARM allowance in June 2026.

---

## Repository layout

```
personal-vault/
├── CLAUDE.md              Project constitution — read first, every session
├── .claude/               Subagents, skills, and a tested secret-blocking hook
├── infra/                 COMPONENT A — deploy Immich (Ansible + compose)
├── vault/                 COMPONENTS B + D — Next.js E2EE vault + dashboard
├── ops/                   COMPONENTS C + D — backup, restore drill, collector
└── .github/workflows/     CI, weekly security scan, Supabase keepalive
```

Each directory has its own README with the detail: `infra/README.md`,
`ops/README.md`, `vault/SECURITY-NOTES.md`.

## Build status

| Phase | Deliverable | Status |
|---|---|---|
| P0 | Repo, CLAUDE.md, agents, skills, hooks | **Done** — hook verified 14/14 |
| P1 | Oracle VM, volumes, Tailscale | Automation written; needs your tenancy |
| P2 | Immich running, hardened, tuned | Automation written; needs P1 |
| P3 | **Backup + verified restore** (gate) | Scripts written; **drill not yet run** |
| P4 | **Crypto core + tests** (gate) | **Passed** — 46/46 |
| P5 | Presign API + auth | **Done** — build clean, bundle scan clean |
| P6 | **Responsive UI + PWA** (gate) | **Passed** — 130/130 across 5 viewports |
| P7 | Collector + `/status` dashboard | **Done** — needs a live VM to feed it |
| P8 | Monitoring + final audit | Workflows written; needs live services |

Everything that can be built and verified without cloud accounts is done and
tested. What remains needs your Oracle, Vercel, Supabase and Gozunga
accounts — see `docs/BUILD-STATE.md` for exactly what to do next.

## Verifying locally

```bash
cd vault
npm ci
npm run typecheck        # zero errors
npm test                 # 46 crypto tests — blocking
npm run build
npm run check:bundle     # no server-only credentials in client chunks
npm run test:e2e         # 130 responsive tests across 5 viewports — blocking

# repo-wide
bash .claude/hooks/__tests__/test-block-secrets.sh
```

Note for this machine: `npm` works from PowerShell but fails under Git Bash
(`EPERM` resolving through `C:\Users\Administrator`). See `CLAUDE.md`.

## Security posture

- **No inbound ports** on the media server. Access is via Tailscale only, which
  makes outbound connections and negotiates a direct WireGuard tunnel.
- **Client-side encryption** for documents: AES-256-GCM in 4 MB chunks with a
  fresh random IV per chunk, keys derived with PBKDF2-SHA256 at 600,000
  iterations, held in memory only and marked non-extractable.
- **File bytes never transit Vercel.** The function authenticates the user and
  mints a short-lived signed URL; the browser talks to storage directly.
- **Row Level Security** on every Supabase table, with policies scoped to
  `auth.uid()`.
- **No secrets in the repository.** A PreToolUse hook blocks writes containing
  credential-shaped content, gitleaks scans the full history weekly, and CI
  scans the built client bundle for server-only env access.

## Known limitations, stated rather than hidden

- Videos are unprotected between monthly drive syncs (see above).
- Server-side full-text search over document contents is impossible by design —
  the server only ever holds ciphertext. Search runs client-side over the
  decrypted index of filenames, tags and notes. Do not "fix" this with
  server-side OCR; it would require plaintext and defeat the encryption.
- No background sync on iOS for the PWA. Uploads run only while the app is open.
  Acceptable for documents; it is exactly why photos use Immich's native app.
- The API rate limiter is per-instance and in-memory, so it is not a global
  guarantee. The real protections are session auth, 60-second URL expiry and the
  server-side quota check. See the note in `vault/lib/rate-limit.ts`.
- Two moderate, development-only npm advisories are accepted and documented with
  their reachability in `vault/SECURITY-NOTES.md` rather than silenced.

## Licence and attribution

Immich is AGPL-3.0 and is deployed here unmodified. restic, Tailscale, Valkey and
PostgreSQL are used under their respective licences. This repository is personal,
non-commercial use only — note that Vercel counts accepting donations as
commercial usage, so do not add donations, payments or ads to a Hobby project.
