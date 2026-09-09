# Vault dependency security notes

Reviewed 2026-09-09. Re-check whenever `npm audit` output changes, and at every
`/security-review`.

## Pinned versions and why

All versions are pinned exactly (no `^`, no `~`). A caret range means the tree
can shift under you between a passing CI run and a production deploy, which for
a project whose whole point is custody of irreplaceable data is not a tradeoff
worth taking. Renovate/Dependabot-style bumps should be deliberate and reviewed.

| Package | Pin | Reason |
|---|---|---|
| `next` | 16.3.4 | First line clearing the high-severity `postcss` advisories (GHSA-r28c-9q8g-f849 and related). Requires Node >= 20.9.0, satisfied here. |
| `@supabase/supabase-js` | 2.100.0 | Latest release still supporting Node 20. 2.116.0 requires Node >= 22 via `@supabase/storage-js`. |
| `@supabase/ssr` | 0.7.0 | Peer range `^2.43.4` is compatible with supabase-js 2.100.0. Version 0.12.7 demands supabase-js `^2.114.0`, which forces Node 22. |
| `@aws-sdk/client-s3` | 3.1128.0 | Clears GHSA-6475-r3vj-m8vf in `@smithy/config-resolver`. |
| `vitest` | 3.2.7 | See "Known accepted advisories" below. |

## Known accepted advisories

`npm audit` reports **2 moderate** findings that are deliberately accepted
rather than silenced. Both are development-time only and unreachable from the
deployed application.

### GHSA-82fw-gwwq-j7x9 — path traversal in `@vitest/mocker`

- **Reachability:** none in production. `vitest` is a `devDependency`; it is not
  bundled into the Next build and never runs on Vercel.
- **Exploit precondition:** an attacker must already be able to author or modify
  a mock file in this repository. Anyone who can do that can simply edit the
  source directly, so the advisory grants no additional capability.
- **Why not fixed:** the patched line is `vitest@5`, whose peer
  `@types/node` requires Node `^22 || >=24`. The build machine runs Node 20.16.0.
- **Revisit when:** the toolchain moves to Node 22 LTS. At that point pin
  `vitest@>=5` and re-run `npm audit`.

### `postcss` reached through `next`

- **Reachability:** build-time CSS processing only.
- **Exploit precondition:** attacker-controlled CSS or a hostile
  `sourceMappingURL` comment processed during `next build`. All CSS in this repo
  is first-party and there is no user-supplied CSS anywhere in the product.
- **Status:** the high-severity instances are cleared by Next 16.3.4. What
  remains is transitive and lower severity.

## Toolchain note

`vitest@4.x` cannot be installed on this machine for an unrelated reason: npm
10.8.1's arborist crashes (`Cannot read properties of null (reading 'edgesOut')`)
while walking the optional peer set that `@vitejs/devtools-vitest` introduces via
`vitest@*`. This is an npm bug, not a dependency conflict. npm 11 resolves it but
could not be installed here (EPERM writing to the npm cache, likely endpoint
security software). `vitest@3.2.7` predates that peer and installs cleanly.

## Standing rules

- Never add a dependency to `vault/lib/crypto.ts`. It uses only Web Crypto, and
  that is a deliberate constraint from CLAUDE.md, not an accident.
- Run `npm audit --audit-level=high` in CI. High or critical fails the build;
  moderate is reported and triaged here.
- Any new accepted advisory gets an entry above with reachability, precondition
  and a revisit trigger. "It's only moderate" is not a reason on its own.
