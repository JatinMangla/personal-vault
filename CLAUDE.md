# Personal Vault — Project Constitution

Read this at the start of every session. It overrides default behaviour.

## What this project is
A personal media and document archive. Three components:
- `infra/`  — DEPLOY Immich on Oracle. Do not write photo-app code.
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
- Windows 11. `npm` works from the PowerShell tool; it is broken under the
  Bash tool (module resolution walks through `C:\Users\Administrator` and
  raises EPERM). Run all npm/npx commands via PowerShell.
- Shell scripts under `ops/` and `infra/` target the Ubuntu 24.04 aarch64 VM,
  not this machine. They are authored here and executed there.
- Keep LF line endings for everything under `ops/` and `infra/` — CRLF breaks
  shebangs on Linux. `.gitattributes` enforces this.

## Build state
See `docs/BUILD-STATE.md` for which phases (P0–P8) are complete and what the
next action is. Update it at the end of any session that advances a phase.
