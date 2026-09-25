#!/usr/bin/env python3
"""Fixtures for tg-scrub.py's pure logic. Imported from the shipped script.

WHY. The scrub is the only thing that notices, after upload, that Telegram has
stopped serving part of the archive. Its bookkeeping decides WHAT gets probed
and WHEN a drain is running. A bug there either silently skips parts of the
archive, reports a bad block that has recovered as still bad, or - worst -
fails to notice a drain and keeps the Telegram session from it. Pinned here:

  - every message id of every ledger row is probed, split parts included,
    rows without ids skipped, a re-recorded name taking its LAST row
  - block offsets cover a file exactly, and resume from a saved block
  - a bad block is recorded once, keeps its first-seen time, and is dropped
    when a later pass finds it readable
  - the drain check reads /proc/locks WITHOUT taking the lock, matches only a
    holder of the exact device:inode, and ignores queued waiters ("->")

Run: python3 test-scrub.py
"""

import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.realpath(__file__))
spec = importlib.util.spec_from_file_location("tgscrub", os.path.join(HERE, "tg-scrub.py"))
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

MIB = 1024 * 1024
passed = failed = 0


def check(label, got, want):
    global passed, failed
    if got == want:
        print(f"  PASS  {label}")
        passed += 1
    else:
        print(f"  FAIL  {label}\n        want: {want}\n        got:  {got}")
        failed += 1


print("ledger -> what to probe:")
LEDGER = """\
aaaa A.insv 100 10
bbbb B.insv 200 11 12 13
cccc OLD.insv 300
dddd UNKNOWN.insv 400 -
eeee A.insv 100 20
"""
rows = m.parse_ledger(LEDGER)
check("rows without ids are skipped", [n for n, _ in rows], ["A.insv", "B.insv"])
check("a re-recorded name keeps its LAST row", dict(rows)["A.insv"], [20])
check("every part of a split file is probed",
      m.targets(rows), [("A.insv", 20), ("B.insv", 11), ("B.insv", 12), ("B.insv", 13)])

print("block offsets:")
check("an exact multiple of 1 MiB", m.block_offsets(3 * MIB), [0, MIB, 2 * MIB])
check("a partial last block is included", m.block_offsets(2 * MIB + 1), [0, MIB, 2 * MIB])
check("a tiny file is one block", m.block_offsets(10), [0])
check("resume from a saved block", m.block_offsets(4 * MIB, 2), [2 * MIB, 3 * MIB])
check("resume past the end is nothing", m.block_offsets(2 * MIB, 5), [])

print("bad-block bookkeeping:")
bad = m.merge_bad([], [("A.insv", 20, MIB)], now=100)
bad = m.merge_bad(bad, [("A.insv", 20, MIB), ("B.insv", 12, 0)], now=200)
check("a block is recorded once", len(bad), 2)
check("it keeps its first-seen time", bad[0]["first_seen"], 100)
bad = m.drop_recovered(bad, [(20, MIB)])
check("a block that reads again is dropped", [(b["id"], b["offset"]) for b in bad], [(12, 0)])

print("drain detection from /proc/locks:")
LOCKS = """\
1: FLOCK  ADVISORY  WRITE 4242 fd:01:131077 0 EOF
2: POSIX  ADVISORY  WRITE 777 fd:01:999 0 EOF
2: -> FLOCK  ADVISORY  WRITE 5151 fd:01:555 0 EOF
"""
check("a held lock on the file is seen", m.lock_holder_listed(LOCKS, "fd:01:131077"), True)
check("another inode is not", m.lock_holder_listed(LOCKS, "fd:01:131078"), False)
check("a queued waiter is not a holder", m.lock_holder_listed(LOCKS, "fd:01:555"), False)
check("same inode on another device is not", m.lock_holder_listed(LOCKS, "fd:02:131077"), False)
check("an empty table means no drain", m.lock_holder_listed("", "fd:01:131077"), False)

print(f"\npassed={passed} failed={failed}")
sys.exit(1 if failed else 0)
