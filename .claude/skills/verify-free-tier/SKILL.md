---
name: verify-free-tier
description: Confirms every external service remains within a permanent free tier and refreshes the budget ledger. Auto-invoke when a new service or dependency is proposed.
agent: cost-guardian
---
1. Enumerate every external service referenced in the repo (docker-compose,
   package.json, env examples, workflows, scripts).
2. For each, fetch the provider's current pricing page and record the free limit.
3. Compare against projected usage for this project.
4. Rewrite the budget ledger table in README.md.
5. Flag anything lacking a permanent free tier as a BLOCKER.

Do not rely on memory for free-tier limits. They change without notice.
