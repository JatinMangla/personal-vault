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

## Content-Security-Policy: the `style-src-attr` exception

The deployed CSP is:

```
default-src 'self'; script-src 'self'; style-src 'self'; style-src-attr 'unsafe-inline'; ...
```

`script-src` is `'self'` with **no** `unsafe-inline` and **no** `unsafe-eval`,
which is what the spec requires and what actually matters for XSS.

`style-src` is also `'self'` with no `unsafe-inline`, so no attacker-supplied
`<style>` block or stylesheet can load.

The one narrow exception is `style-src-attr 'unsafe-inline'`, which permits
inline `style` **attributes** only. Four values in this app are genuinely
dynamic and cannot be precomputed into a class:

- meter fill width (`--fill`) — the upload progress bar and every limit meter
- storage breakdown segment width and colour (`--seg-width`, `--seg-color`)

React renders these through the `style` prop, which emits a style attribute.
Everything else was moved into utility classes in `globals.css` specifically so
this exception could be kept to attributes rather than applying to stylesheets.

What this does and does not permit:

- **Does not** allow script execution, `<style>` injection, or loading external
  stylesheets.
- **Does** allow an attacker who already has HTML injection to set a style
  attribute. Given HTML injection they already have far worse options, and
  `script-src 'self'` is what stops those.

To remove the exception entirely, the dynamic widths would need to be quantised
into a fixed set of classes (say, 100 `.w-N` rules). That trades a real loss of
precision in the gauges for a marginal security gain, so it has not been done.
Revisit if the app ever renders untrusted HTML — at present it renders none.

## Why Supabase Storage rather than Cloudflare R2

The original design used R2 for document blobs: 10 GB free, zero egress, and an
S3-compatible API. It was replaced before any data was stored.

**Reason:** Cloudflare requires a payment method on file before R2 can be
enabled at all, even on the free tier, and provides **no spending cap**.
Exceeding the free tier bills the card automatically. The project's hard rule
(spec 1.1) is that no credit card may be attached in a way that permits
automatic overage billing without an alert first. R2 could not satisfy that.

Supabase Storage requires no card and restricts service rather than billing when
a free limit is reached, which is the safety property the rule was protecting.

**What was given up:** 1 GB of free storage instead of 10 GB, and 5 GB/month of
egress instead of unlimited. Accepted because the documents in scope are
predominantly PDFs and office files at roughly 100 KB - 2 MB each, so a few
thousand files fit comfortably. `STORAGE_SOFT_LIMIT_BYTES` refuses uploads at
90% of the ceiling so the limit surfaces as a clear message with room to export,
rather than as an opaque platform error.

**What did not change:** the crypto core is untouched. Files are still encrypted
in the browser with AES-256-GCM before upload, and the storage provider holds
only ciphertext under a random object key.

### Deviation: signed upload URL lifetime

The spec caps presigned URL TTL at 60 seconds. Supabase honours that for
downloads (`createSignedUrl(path, 60)`) but its signed **upload** tokens are
fixed at 2 hours with no way to shorten them.

Assessed as acceptable, and recorded rather than quietly ignored:

- the token authorises writing to exactly ONE random object key, already
  recorded against the user's row
- it grants no read access, so it cannot be used to exfiltrate anything
- the bucket is private with RLS, so the object stays unreadable without a
  separate signed download URL
- the client uses the token immediately; the window is theoretical

Residual risk: a token intercepted in transit could overwrite that single object
within two hours. TLS covers transit.

### Storage RLS

`supabase/migrations/0002_storage_bucket.sql` creates a **private** bucket and
policies scoped to `(storage.foldername(name))[1] = auth.uid()::text`, matching
the `<userId>/<random>` object-key format. These are defence in depth: the API
routes already check ownership before signing. They matter because a signed URL
is a bearer credential, and if one leaked the policies still confine what a
normal authenticated session can reach. The `anon` role is granted nothing.

## CSP: why a per-request nonce

The deployed CSP is generated in `proxy.ts`, not `vercel.json`, because it
contains a value that changes on every request.

**The bug this fixes.** Next.js emits two inline `<script>` blocks on every
page — the React Flight payload that hydration reads. A static
`script-src 'self'` blocks them, React never hydrates, and every page sits at
"Loading…" forever with React error #412 in the console. This shipped to
production and was caught by the user, not by the test suite.

**Why the obvious fixes do not work:**

| Approach | Why not |
|---|---|
| `'unsafe-inline'` | Re-opens the XSS hole the CSP exists to close; spec forbids it |
| Script hashes | The Flight payload differs per page and per build |
| Subresource Integrity | Tested: Next adds `integrity` only to *external* scripts, never the inline payload |

**The fix.** `proxy.ts` generates a CSPRNG nonce per request, puts it in the CSP
header, and Next stamps the same value onto the scripts it emits. An injected
script cannot guess it. Verified: header nonce and script nonce match, rotate
per request, and `script-src` still contains neither `unsafe-inline` nor
`unsafe-eval`.

**The cost, accepted.** Nonces require dynamic rendering — a statically
prerendered page is built with no request, so no nonce can be applied. The root
layout therefore calls `connection()`, which opts every page into dynamic
rendering. Static caching is lost. For a single-user vault of tiny pages this is
irrelevant: Vercel's free tier allows 1M invocations a month against an expected
handful per day.

### `upgrade-insecure-requests` is skipped on localhost

That directive rewrites `http://` subresource URLs to `https://`. Correct in
production, but against a local test server with no TLS it makes every asset
fail with an SSL error. WebKit applies it to `127.0.0.1`; Chromium exempts
localhost. The symptom was baffling — pages rendered completely unstyled because
the stylesheet never loaded, and 21 WebKit tests failed while Chromium passed.

Production is HTTPS-only on Vercel, so skipping it locally costs nothing.

### Test gap that let this reach production

The responsive suite passed throughout, because it measured geometry and never
asked whether the application actually ran. Five regression tests now cover it:
no CSP violations in console, the app hydrates rather than showing "Loading…",
every inline script carries the matching nonce, the nonce is unique per request,
and `script-src` still forbids `unsafe-inline`/`unsafe-eval`.

**Lesson worth keeping: a layout test that passes on a dead page is not a test.**
