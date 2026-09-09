---
name: deploy-check
description: Pre-deployment gate for the Vercel document vault.
---
1. `npm run typecheck` — zero errors
2. `npm test` — crypto round-trip suite must pass
3. Invoke /security-review — must return zero BLOCKERs
3b. Invoke /responsive-audit — must return zero failures
4. Confirm every var in .env.example is set in the Vercel dashboard
5. Confirm no NEXT_PUBLIC_ variable holds a secret
6. Confirm the GitHub repo is under a personal account, not an org
7. Confirm vercel.json security headers are present
8. Only then: `vercel --prod`
