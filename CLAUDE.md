# Personal Vault — Project Constitution

Read this at the start of every session. It overrides default behaviour.

## What this project is
A personal media and document archive. Three components:
- `infra/`  — DEPLOY Immich and Vaultwarden on Oracle. Do not write photo-app
  or password-manager code; both are upstream images, pinned.
- `vault/`  — BUILD a Next.js E2EE document vault on Vercel + R2 + Supabase.
- `ops/`    — BUILD backup and monitoring automation.

## Hard rules
1. Total cost must stay at $0–1/year. Before adding ANY service, verify a
   permanent free tier exists and record it in the budget ledger in README.md.
2. Never commit a secret. If you are about to write a value that looks like a
   key, token, password or connection string into any tracked file, stop and
   use an environment variable instead.
3. Never weaken encryption to make a feature work. If a feature requires
   plaintext on the server, do not build the feature — raise the trade-off.
4. Never use `:latest` for a Docker image. Pin explicit versions.
5. Never put encryption keys in localStorage or sessionStorage.
6. Never route file bytes through a Vercel function. Presigned URLs only.

## Before writing code
- Check whether the thing already exists. Immich, restic, Tailscale and
  Supabase Auth already solve most of this. Integrating beats rebuilding.
- For anything touching crypto or auth, prefer the platform primitive
  (Web Crypto, Supabase Auth) over a library, and a library over hand-rolling.

## Definition of done for any phase
- Tests pass
- `/security-review` returns clean
- `/verify-free-tier` returns clean
- Budget ledger in README.md is current

## Environment
- Target VM is ARM64 (aarch64). All Docker images must have arm64 variants.
- Oracle home region: ap-mumbai-1. Cannot be changed after account creation.
- GitHub repo must be under a personal account, not an org (Vercel Hobby limit).

## Local development notes (this machine)
- Windows 11. The `npm`/`npx` shims are broken (module resolution walks
  through `C:\Users\Administrator` and raises EPERM). npm itself works from
  Bash when the standalone copy is run through node directly:
  `"/c/Program Files/nodejs/node.exe" "$LOCALAPPDATA/npm-standalone/node_modules/npm/bin/npm-cli.js" <args>`.
  Project binaries (tsc, vitest, next, playwright) run the same way from
  `vault/node_modules`. npx does not work; download CLI binaries instead.
- Shell scripts under `ops/` and `infra/` target the Ubuntu 24.04 aarch64 VM,
  not this machine. They are authored here and executed there.
- Keep LF line endings for everything under `ops/` and `infra/` — CRLF breaks
  shebangs on Linux. `.gitattributes` enforces this.

## Speed first
The owner's top priority: no change may slow uploads or any other feature.
Tag every proposal Faster / Neutral / One-off, measure speed claims, and ship
pipeline changes as opt-in flags that stay off until a real drain is faster.
Ideas already rejected on speed grounds are listed in `docs/REVIEW-2026-09-24.md`.

## Build state
See `docs/BUILD-STATE.md` for which phases (P0–P8) are complete and what the
next action is. Update it at the end of any session that advances a phase.

Reading order for a new session: this file → `docs/BUILD-STATE.md` →
`docs/REVIEW-2026-09-24.md` (latest review, open items, deploy order) →
`docs/HARD-WON.md` before touching the Telegram pipeline, and
`docs/VAULTWARDEN-PLAN.md` + `infra/vaultwarden/SECURITY-NOTES.md` before
touching the family password manager. For the drain's
speed work specifically, `docs/SESSION-FINDINGS-2026-09-19.md` records how the
current timings were reached and which predictions the measurements falsified.
