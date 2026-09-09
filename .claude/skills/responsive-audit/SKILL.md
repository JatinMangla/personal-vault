---
name: responsive-audit
description: Verifies the PWA works on Android phone, iPhone and iPad 13". Auto-invoke after any change to vault/app, vault/components or globals.css.
agent: frontend-engineer
---
Run Playwright against all four target viewports:
360x800 (Android), 430x932 (iPhone Pro Max), 1024x1366 (iPad portrait),
1366x1024 (iPad landscape), plus 507x1366 (iPad Split View).

Assert for each:
1. document.scrollWidth <= viewport width — no horizontal overflow
2. every button, link and input has a bounding box >= 44x44 CSS px
3. no interactive element intersects the safe-area inset region
4. every input/textarea/select has computed font-size >= 16px
5. no element relies on :hover to become reachable (grep for hover-only
   opacity/visibility/display rules on interactive elements)
6. no use of 100vh anywhere in CSS — must be 100dvh
7. the primary flow completes at 360px: login -> list -> upload -> download
8. /status renders with zero overflow at 360px (the ledger table is the
   most likely failure — it must be cards, not a table, on phones)

Report failures with viewport, selector and measured value.
