#!/usr/bin/env python3
"""Fixtures for tg-delete-ids.py's one hard rule: never delete a ledger id.

ledger_ids() decides which message ids are protected. Every id in the fourth
column onwards must be protected, including every part of a split file, and
nothing else may be mistaken for an id: not the hash, name or size, and not
the "-" that marks an unknown id. Imported from the shipped script, not copied.
"""

import importlib.util
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
spec = importlib.util.spec_from_file_location("tgdel", os.path.join(HERE, "tg-delete-ids.py"))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

LEDGER = """\
aaaa1111 VID_a.insv 1000 101
bbbb2222 VID_b.insv 2000 110 111 112
cccc3333 VID_old.insv 3000
dddd4444 VID_unknown.insv 4000 -
eeee5555 VID_c.insv 5000 7
"""

passed = failed = 0


def ck(label, got, want):
    global passed, failed
    if got == want:
        print(f"  PASS  {label}")
        passed += 1
    else:
        print(f"  FAIL  {label}\n        want: {want}\n        got:  {got}")
        failed += 1


with tempfile.NamedTemporaryFile("w", delete=False, suffix=".sha256") as fh:
    fh.write(LEDGER)
    path = fh.name
try:
    ids = mod.ledger_ids(path)
finally:
    os.unlink(path)

ck("single-message file is protected", 101 in ids, True)
ck("EVERY part of a split file is protected", {110, 111, 112} <= ids, True)
ck("a one-digit id is protected", 7 in ids, True)
ck("sizes are not mistaken for ids", {1000, 2000, 3000, 4000, 5000} & ids, set())
ck("nothing else is protected", ids, {7, 101, 110, 111, 112})

print(f"\npassed={passed} failed={failed}")
sys.exit(1 if failed else 0)
