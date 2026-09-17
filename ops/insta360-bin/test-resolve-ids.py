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

# ---------------------------------------------------------------------------
# PARTIAL RESOLUTION - the bug that cost the batch its ids
#
# The resolver prints what it resolved, then reports what it could not. It used
# to exit 1 in that case, and tg-upload.sh captured it as
# `if resolved_out="$(...)"` - so a non-zero status skipped the parse loop and
# discarded ids that HAD resolved. One unresolvable name sent the whole batch
# down the full-channel download path.
#
# The contract these fixtures pin:
#   stdout        - one line per RESOLVED name, always, even when some fail
#   exit status   - 0 when the resolver ran, whether or not every name resolved
#                   (non-zero is reserved for "could not reach Telegram at all")
#   completeness  - the CALLER's job, judged from the ids actually printed
print("resolve - partial resolution:")

# B.insv is not in the channel. A.insv must still be returned.
check(
    "resolved names survive an unresolved sibling",
    resolve([(8, "A.insv")], ["A.insv", "B.insv"]),
    {"A.insv": [8]},
)
check(
    "one resolved out of three",
    resolve([(12, "B.insv")], ["A.insv", "B.insv", "C.insv"]),
    {"B.insv": [12]},
)
# A split file whose parts landed while a plain sibling did not.
check(
    "split resolves while sibling is missing",
    resolve([(21, "A.insv.01"), (20, "A.insv.00")], ["A.insv", "Z.insv"]),
    {"A.insv": [20, 21]},
)


def caller_ids(resolved, requested):
    """What tg-upload.sh ends up with: BATCH_IDS, and ids_complete.

    Mirrors the shell - parse every printed line into BATCH_IDS, THEN judge
    completeness per file. The old shell threw `resolved` away entirely when
    the resolver exited non-zero; this asserts the ids survive.
    """
    batch_ids = {n: ids for n, ids in resolved.items()}
    complete = 1 if all(n in batch_ids for n in requested) else 0
    return batch_ids, complete


ids, complete = caller_ids(resolve([(8, "A.insv")], ["A.insv", "B.insv"]),
                           ["A.insv", "B.insv"])
check("caller keeps the resolved id on a partial batch", ids, {"A.insv": [8]})
check("caller marks the batch incomplete", complete, 0)

ids, complete = caller_ids(
    resolve([(9, "B.insv"), (8, "A.insv")], ["A.insv", "B.insv"]),
    ["A.insv", "B.insv"],
)
check("caller marks a full batch complete", complete, 1)

print()
print(f"passed={PASS} failed={FAIL}")
sys.exit(1 if FAIL else 0)
