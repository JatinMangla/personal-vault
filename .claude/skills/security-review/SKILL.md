---
name: security-review
description: Full security audit of the repository. Auto-invoke before any commit that touches vault/, .github/, or any file containing auth or crypto logic.
agent: security-auditor
---
Run a complete security review:

1. `gitleaks detect --no-git -v` (install if absent)
2. Grep all of vault/ for: NEXT_PUBLIC_.*(KEY|SECRET|TOKEN|PASSWORD)
3. Grep for localStorage/sessionStorage near key, crypto, secret, token
4. Verify every crypto.subtle.encrypt call uses a freshly generated IV
5. Verify PBKDF2 iterations >= 600000
6. List every Supabase table and confirm RLS is enabled with a real policy
7. Confirm presigned URL TTL <= 60 seconds
8. `npm audit --audit-level=high`
9. Confirm .gitignore covers .env*, *.pem, *.key, secrets/

Also run the hook's own regression suite, since a silently broken hook is the
same as no hook:

10. `bash .claude/hooks/__tests__/test-block-secrets.sh`

Output: table of BLOCKER / WARNING / NOTE with file:line references.
