#!/usr/bin/env python3
"""Fixtures for the matching rules in tg-resolve-ids.py.

WHY. These two rules decide which Telegram message Check #2 verifies against,
and both failure modes are silent:

  - wrong id  -> fetches the wrong bytes, and a verification that should have
                 passed fails (or worse, one that should fail passes)
  - missed id -> falls back to a full-channel download, which cost an 11-hour
                 drain on 2026-09-17

The live channel really does contain 13 duplicated filenames, from drains that
were interrupted after uploading but before recording. So newest-wins is not a
hypothetical nicety - it is load-bearing against data already in the archive.

Pure functions, no network. Run: python3 test-resolve-ids.py
"""

import sys


def belongs_to(fname, wanted):
    """Which requested name does this channel filename belong to, if any?"""
    if fname in wanted:
        return fname
    if "." in fname:
        stem, _, suffix = fname.rpartition(".")
        if suffix.isdigit() and stem in wanted:
            return stem
    return None


def resolve(messages, names):
    """messages: [(msg_id, filename)] NEWEST FIRST, as iter_messages yields."""
    wanted = set(names)
    found = {}
    for msg_id, fname in messages:
        owner = belongs_to(fname, wanted)
        if owner is None:
            continue
        found.setdefault(owner, {})
        if fname not in found[owner]:
            found[owner][fname] = msg_id
    return {n: sorted(v.values()) for n, v in found.items()}


PASS = FAIL = 0


def check(name, got, want):
    global PASS, FAIL
    if got == want:
        print(f"  PASS  {name}")
        PASS += 1
    else:
        print(f"  FAIL  {name}")
        print(f"        want {want}")
        print(f"        got  {got}")
        FAIL += 1


print("belongs_to:")
check("exact match", belongs_to("A.insv", {"A.insv"}), "A.insv")
check("split part .00", belongs_to("A.insv.00", {"A.insv"}), "A.insv")
check("split part .12", belongs_to("A.insv.12", {"A.insv"}), "A.insv")
check("unrelated file", belongs_to("B.insv", {"A.insv"}), None)
# A manifest must never be mistaken for a part of a video.
check("manifest ignored", belongs_to("manifest-2026.sha256", {"A.insv"}), None)
# ".bak" is not a part: the suffix must be digits.
check("non-numeric suffix", belongs_to("A.insv.bak", {"A.insv"}), None)

print("resolve - newest wins:")
# iter_messages yields newest first. The duplicate at id 10 is an older upload
# of the same file and must be ignored in favour of id 29.
check(
    "duplicate filename takes the newest",
    resolve([(29, "A.insv"), (10, "A.insv")], ["A.insv"]),
    {"A.insv": [29]},
)
check(
    "three copies, newest only",
    resolve([(33, "A.insv"), (19, "A.insv"), (14, "A.insv")], ["A.insv"]),
    {"A.insv": [33]},
)

print("resolve - split files:")
check(
    "all parts collected, sorted",
    resolve([(32, "A.insv.02"), (31, "A.insv.01"), (30, "A.insv.00")], ["A.insv"]),
    {"A.insv": [30, 31, 32]},
)
# THE case that matters: a re-uploaded split file. Parts from the newer upload
# (30-32) must not be mixed with parts from the older one (16-18), or Check #2
# would rejoin fragments of two different uploads.
check(
    "duplicated split takes newest of EACH part",
    resolve(
        [(32, "A.insv.02"), (31, "A.insv.01"), (30, "A.insv.00"),
         (18, "A.insv.02"), (17, "A.insv.01"), (16, "A.insv.00")],
        ["A.insv"],
    ),
    {"A.insv": [30, 31, 32]},
)

print("resolve - misc:")
check("missing name absent from result", resolve([(5, "B.insv")], ["A.insv"]), {})
check(
    "two names resolved independently",
    resolve([(9, "B.insv"), (8, "A.insv")], ["A.insv", "B.insv"]),
    {"A.insv": [8], "B.insv": [9]},
)
check("empty channel", resolve([], ["A.insv"]), {})

print()
print(f"passed={PASS} failed={FAIL}")
sys.exit(1 if FAIL else 0)
