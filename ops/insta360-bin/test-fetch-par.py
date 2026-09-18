#!/usr/bin/env python3
"""Fixtures for tg-fetch-par.py. Pure logic, no network, no Telethon.

WHY. This script runs INSIDE the integrity chain: between the upload and the
SHA-256 comparison that gates deleting the only copy of the footage. A bug here
either wastes a batch or, worse, hands the rejoin a file that is subtly wrong.

Three properties are load-bearing and are pinned here:

  1. SHORT DOWNLOADS MUST FAIL. A truncated file that reached the rejoin would
     be hashed, mismatch, and fail Check #2 - safe, but it wastes the whole
     batch and blames the wrong thing. The length assertion catches it at the
     source and names the file.

  2. PARTIAL FILES MUST BE INVISIBLE TO THE REJOIN. tg-upload.sh globs
     NAME.[0-9][0-9]* to find split parts. A download in flight is NAME.part,
     which must NOT match that glob, or an interrupted fetch would be rejoined
     into a corrupt whole.

  3. CONCURRENCY MUST STAY BOUNDED. This is a shared, rate-limited API and the
     channel is the only copy. FastTelethon's default of 20 is not a precedent
     to follow; the cap is 8 and the default is 4.

Run: python3 test-fetch-par.py
"""

import fnmatch
import re
import sys

PASS = 0
FAIL = 0


def check(name, got, want):
    global PASS, FAIL
    if got == want:
        print("  PASS  {}".format(name))
        PASS += 1
    else:
        print("  FAIL  {}".format(name))
        print("        want {!r}".format(want))
        print("        got  {!r}".format(got))
        FAIL += 1


# --- 1. the length assertion ------------------------------------------------
#
# Mirrors the check in fetch_one(): written must equal the size Telegram
# reports, or the file is rejected and removed.
def verdict(written, expected):
    if expected is not None and written != expected:
        return "short"
    return "ok"


print("length assertion:")
check("exact match passes", verdict(1000, 1000), "ok")
check("one byte short fails", verdict(999, 1000), "short")
check("one byte over fails", verdict(1001, 1000), "short")
check("empty download of a real file fails", verdict(0, 1000), "short")
# A zero-length message is legitimate only if Telegram also says zero.
check("zero expected, zero written", verdict(0, 0), "ok")
# Telethon can report size as None; then length cannot be asserted and the
# SHA-256 in tg-upload.sh remains the backstop.
check("unknown size cannot be asserted", verdict(123, None), "ok")


# --- 2. the rejoin glob must not see a partial ------------------------------
#
# tg-upload.sh: parts=("$rt_dir/$base".[0-9][0-9]*)
# Reproduced here as the equivalent fnmatch pattern.
def matches_rejoin_glob(filename, base):
    return fnmatch.fnmatch(filename, base + ".[0-9][0-9]*")


def temp_name(base):
    """What tg-fetch-par.py writes to while a download is in flight.

    Dot-prefixed, NOT base + ".part": the rejoin glob ends in * , so
    "NAME.insv.00.part" matches it and a crashed fetch would be concatenated
    into the rejoined file. This fixture caught that before it ever ran.
    """
    return "." + base + ".part"


BASE = "VID_20250222_203301_00_072.insv"

print("rejoin glob vs in-flight files:")
check("finished part .00 is picked up",
      matches_rejoin_glob(BASE + ".00", BASE), True)
check("finished part .01 is picked up",
      matches_rejoin_glob(BASE + ".01", BASE), True)
check("three-digit part is picked up",
      matches_rejoin_glob(BASE + ".123", BASE), True)
# THE property: an in-flight download must be invisible.
check("in-flight temp for a whole file is NOT picked up",
      matches_rejoin_glob(temp_name(BASE), BASE), False)
# THE case that caught the bug: base + ".part" would have been
# "NAME.insv.00.part", which the trailing * DOES match.
check("in-flight temp for a split part is NOT picked up",
      matches_rejoin_glob(temp_name(BASE + ".00"), BASE), False)
check("the NAIVE naming would have matched (why the dot is required)",
      matches_rejoin_glob(BASE + ".00.part", BASE), True)
check("unrelated file is not picked up",
      matches_rejoin_glob("OTHER.insv.00", BASE), False)


# --- 3. concurrency bounds --------------------------------------------------
def concurrency_ok(n):
    return 1 <= n <= 8


print("concurrency bounds:")
check("default 4 allowed", concurrency_ok(4), True)
check("1 allowed (serial)", concurrency_ok(1), True)
check("8 allowed (cap)", concurrency_ok(8), True)
check("0 rejected", concurrency_ok(0), False)
check("negative rejected", concurrency_ok(-1), False)
# FastTelethon's default, deliberately refused.
check("20 rejected", concurrency_ok(20), False)


# --- 4. flood-wait message shape --------------------------------------------
#
# Emitted as FLOOD_WAIT_<n> so throttling reads the same way in the journal as
# the upload path's already does.
def flood_message(seconds):
    return "FLOOD_WAIT_{}".format(seconds)


FLOOD_RE = re.compile(r"FLOOD_WAIT_(\d+)")

print("flood-wait reporting:")
check("formats as FLOOD_WAIT_n", flood_message(42), "FLOOD_WAIT_42")
m = FLOOD_RE.search(flood_message(42))
check("seconds are recoverable", m.group(1) if m else None, "42")
check("large waits format", flood_message(3600), "FLOOD_WAIT_3600")


# --- 5. free-space guard ----------------------------------------------------
#
# Mirrors run(): refuse to start when free space is under total * 1.1.
def space_ok(total_bytes, free_bytes):
    if total_bytes and free_bytes < total_bytes * 1.1:
        return False
    return True


print("free-space guard:")
check("ample space proceeds", space_ok(1000, 10000), True)
check("exactly 10% margin proceeds", space_ok(1000, 1100), True)
check("under the margin refuses", space_ok(1000, 1050), False)
check("less free than needed refuses", space_ok(1000, 900), False)
check("zero expected bytes proceeds", space_ok(0, 0), True)


print()
print("passed={} failed={}".format(PASS, FAIL))
sys.exit(1 if FAIL else 0)
