#!/usr/bin/env python3
"""Rolling, read-only scrub of the Telegram archive: find blocks Telegram
will no longer serve, before a restore needs them.

    tg-scrub.py --config <json> --channel <id> [--ledger FILE] [--state FILE]
                [--minutes 30] [--request-kib 512] [--loop-lock FILE] [--session-lock FILE]

WHY THIS EXISTS. On 2026-09-24/25 a file passed upload but could not be
downloaded: Telegram had stored three 1 MiB blocks it then refused to serve,
at every request size (docs/REVIEW-2026-09-24.md). Check #2 catches that at
upload time. Nothing caught it AFTERWARDS - and an archive is only as good as
its ability to be read back months later, when the card is long wiped.

HOW. One request at the start of every 1 MiB block of every message the
ledger points at. The default request is 512 KiB because that size is PROVEN
both ways on the real channel (2026-09-25): 1,259 of 1,262 healthy blocks
answered at ~0.15 s each, and every dead block failed. Smaller sizes also fail
on dead blocks but were never shown to succeed on healthy ones. A failure is
re-tried once after 5 s before it counts, so a brief Telegram hiccup is not
recorded as damage; dead blocks failed for days. Known bad blocks are re-probed
at the start of every run, so one that recovers clears the next night. Each run
is time-boxed and resumes where the last stopped, so the whole archive is
covered over about two weeks of nights without any single run being long.

IT NEVER SLOWS ANYTHING ELSE. It needs the Telegram session, which admits one
process at a time, so the systemd unit only starts it when the session is free.
Between requests it checks /proc/locks (read-only): the moment a drain runs, or
ANY tool queues for the session - a restore, an upload, tg-upload-parts.sh - it
saves its place and exits, and that tool gets the session within about a second.
A `systemctl stop` does the same.

READ-ONLY: it downloads one request per block into memory and discards it, and
writes only its own state file. Report fields (for the metrics collector):
    updated, last_full_pass, position, blocks_checked, bad[]
Exit codes: 0 no bad block known, 1 at least one bad block known, 2 bad
invocation or Telethon unavailable, 3 stepped aside before doing anything.
"""

import argparse
import asyncio
import json
import os
import signal
import sys
import time

MIB = 1024 * 1024


# --- pure logic (tested by test-scrub.py) ------------------------------------

def parse_ledger(text):
    """[(name, [message ids])] in ledger order; rows without ids are skipped.

    Columns: card sha256, name, size, then message id(s). A name that appears
    twice keeps its LAST row - the most recent record, as restore.sh does.
    """
    rows = {}
    order = []
    for line in text.splitlines():
        f = line.split()
        if len(f) < 4:
            continue
        ids = [int(t) for t in f[3:] if t.isdigit()]
        if not ids:
            continue
        if f[1] not in rows:
            order.append(f[1])
        rows[f[1]] = ids
    return [(n, rows[n]) for n in order]


def targets(rows):
    """Flatten to [(name, message id)] - every part of a split file."""
    return [(name, mid) for name, ids in rows for mid in ids]


def block_offsets(size, start_block=0):
    """Offsets of every 1 MiB block of a `size`-byte file, from start_block."""
    nblocks = (size + MIB - 1) // MIB
    return [b * MIB for b in range(start_block, nblocks)]


def merge_bad(bad, found, now):
    """Add newly found bad blocks, keeping each one's first-seen time."""
    known = {(b["id"], b["offset"]) for b in bad}
    for name, mid, off in found:
        if (mid, off) not in known:
            bad.append({"name": name, "id": mid, "offset": off, "first_seen": now})
            known.add((mid, off))
    return bad


def drop_recovered(bad, recovered):
    """Remove blocks that answered on a later pass - Telegram served them."""
    gone = set(recovered)
    return [b for b in bad if (b["id"], b["offset"]) not in gone]


def lock_holder_listed(proc_locks_text, dev_ino):
    """True if /proc/locks lists a HELD lock on dev_ino ("MAJ:MIN:INODE").

    Lines look like "1: FLOCK  ADVISORY  WRITE 1234 fd:01:5678 0 EOF"; a
    waiter queued behind a lock carries "->" and is not a holder.
    """
    for line in proc_locks_text.splitlines():
        fields = line.split()
        if "->" in fields:
            continue
        if dev_ino in fields:
            return True
    return False


def lock_waiter_listed(proc_locks_text, dev_ino):
    """True if something is QUEUED waiting for the lock on dev_ino.

    The scrub holds the Telegram session lock; a restore, an upload or the
    parts tool that wants it shows up here as a "->" line. Seeing one means:
    step aside now.
    """
    for line in proc_locks_text.splitlines():
        fields = line.split()
        if "->" in fields and dev_ino in fields:
            return True
    return False


# --- I/O ---------------------------------------------------------------------

def _dev_ino(path):
    st = os.stat(path)
    return "{:02x}:{:02x}:{}".format(os.major(st.st_dev), os.minor(st.st_dev), st.st_ino)


def someone_needs_telegram(loop_lock, session_lock):
    """True if a drain is running, or anything is waiting for the session.

    READ-ONLY by design: both are looked up in /proc/locks, never taken. Taking
    the loop lock even for an instant could make a drain that starts in that
    instant see it busy and skip its run.
    """
    try:
        with open("/proc/locks") as fh:
            text = fh.read()
    except OSError:
        return False
    try:
        if lock_holder_listed(text, _dev_ino(loop_lock)):
            return True
    except OSError:
        pass
    try:
        if lock_waiter_listed(text, _dev_ino(session_lock)):
            return True
    except OSError:
        pass
    return False


def load_state(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return {"position": {"target": 0, "block": 0}, "bad": [],
                "blocks_checked": 0, "last_full_pass": None, "updated": None}


def save_state(path, state):
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh, indent=1)
    os.replace(tmp, path)   # atomic: the collector never reads half a file


async def probe(client, msg, offset, request, timeout):
    """True if Telegram serves `request` bytes at `offset`."""
    from telethon.errors import FloodWaitError

    for attempt in range(3):
        try:
            async def one():
                async for _ in client.iter_download(msg, offset=offset, limit=1,
                                                    request_size=request):
                    pass
            await asyncio.wait_for(one(), timeout=timeout)
            return True
        except FloodWaitError as e:
            if e.seconds > 30:
                raise
            print(f"FLOOD_WAIT_{e.seconds} - waiting {e.seconds + 1}s", file=sys.stderr)
            await asyncio.sleep(e.seconds + 1)
        except Exception:  # noqa: BLE001 - any failure to serve counts
            return False
    return False


async def run(args, cfg):
    from telethon import TelegramClient

    # Step aside when a drain runs, when ANY tool is waiting for the Telegram
    # session (a restore, an upload, the parts tool), or when systemd stops the
    # unit - in every case by saving the position and exiting normally, so a
    # `systemctl stop tg-scrub` loses nothing.
    stop = {"now": False}
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, lambda: stop.__setitem__("now", True))

    def must_yield():
        return stop["now"] or someone_needs_telegram(args.loop_lock, args.session_lock)

    with open(args.ledger) as fh:
        tlist = targets(parse_ledger(fh.read()))
    state = load_state(args.state)
    if not tlist:
        print("ledger lists no message ids - nothing to scrub")
        return 0
    if must_yield():
        print("a drain or another Telegram tool needs the session - not scrubbing now")
        return 3

    session = cfg["session"][:-len(".session")] if cfg["session"].endswith(".session") \
        else cfg["session"]
    channel = args.channel
    try:
        channel = int(channel)
    except ValueError:
        pass

    pos = state["position"]
    ti, bi = pos.get("target", 0), pos.get("block", 0)
    if ti >= len(tlist):
        ti, bi = 0, 0
    deadline = time.monotonic() + args.minutes * 60
    request = args.request_kib * 1024
    found, recovered, checked, yielded = [], [], 0, False
    known_bad = {(b["id"], b["offset"]) for b in state["bad"]}

    async def served(msg, off):
        """Probe, and give a failure one more chance after 5 s."""
        if await probe(client, msg, off, request, args.timeout):
            return True
        await asyncio.sleep(5)
        return await probe(client, msg, off, request, args.timeout)

    client = TelegramClient(session, int(cfg["api_id"]), cfg["api_hash"],
                            request_retries=1)
    async with client:
        entity = await client.get_entity(channel)

        # Re-check what is already known bad, first: a block Telegram serves
        # again should clear from /status the next night, not weeks later.
        for b in list(state["bad"]):
            if must_yield():
                yielded = True
                break
            if b["offset"] < 0:
                continue    # a missing message is re-checked in the main pass
            msg = await client.get_messages(entity, ids=b["id"])
            if msg is not None and getattr(msg, "document", None) \
                    and await served(msg, b["offset"]):
                print(f"RECOVERED: {b['name']} (message {b['id']}) block at "
                      f"{b['offset'] // MIB} MiB", file=sys.stderr)
                recovered.append((b["id"], b["offset"]))

        while not yielded and ti < len(tlist) and time.monotonic() < deadline:
            name, mid = tlist[ti]
            msg = await client.get_messages(entity, ids=mid)
            if msg is None or not getattr(msg, "document", None):
                print(f"MISSING: message {mid} ({name}) no longer exists", file=sys.stderr)
                found.append((name, mid, -1))
                ti, bi = ti + 1, 0
                continue
            offsets = block_offsets(int(msg.document.size), bi)
            for off in offsets:
                if time.monotonic() >= deadline:
                    break
                if must_yield():
                    yielded = True
                    break
                ok = await served(msg, off)
                checked += 1
                if not ok:
                    print(f"BAD: {name} (message {mid}) block at {off // MIB} MiB",
                          file=sys.stderr)
                    found.append((name, mid, off))
                elif (mid, off) in known_bad:
                    recovered.append((mid, off))
                bi = off // MIB + 1
            if yielded or time.monotonic() >= deadline:
                break
            ti, bi = ti + 1, 0

    now = int(time.time())
    if ti >= len(tlist):
        state["last_full_pass"] = now
        ti, bi = 0, 0
    state["bad"] = merge_bad(drop_recovered(state["bad"], recovered), found, now)
    state["position"] = {"target": ti, "block": bi}
    state["blocks_checked"] = state.get("blocks_checked", 0) + checked
    state["updated"] = now
    save_state(args.state, state)

    print(f"checked {checked} block(s); {'stepped aside; ' if yielded else ''}"
          f"{len(state['bad'])} bad block(s) known; next: target {ti} of "
          f"{len(tlist)}, block {bi}")
    return 1 if state["bad"] else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--channel", required=True)
    ap.add_argument("--ledger", default="/var/lib/insta360-archive/work/uploaded.sha256")
    ap.add_argument("--state", default="/var/lib/insta360-archive/work/scrub-state.json")
    ap.add_argument("--loop-lock", default="/var/lib/insta360-archive/work/.loop.lock")
    ap.add_argument("--session-lock", default="/var/lib/insta360-archive/work/.session.lock")
    ap.add_argument("--minutes", type=float, default=30)
    ap.add_argument("--request-kib", type=int, default=512)
    ap.add_argument("--timeout", type=int, default=30)
    args = ap.parse_args()
    if args.request_kib < 4 or 1024 % args.request_kib:
        print("ERROR: --request-kib must be 4..1024 and divide 1024", file=sys.stderr)
        sys.exit(2)
    try:
        import telethon  # noqa: F401
    except ImportError:
        print("ERROR: telethon is not importable - run with the pipx interpreter",
              file=sys.stderr)
        sys.exit(2)
    try:
        with open(args.config) as fh:
            cfg = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        print(f"ERROR: cannot read config {args.config}: {e}", file=sys.stderr)
        sys.exit(2)
    sys.exit(asyncio.run(run(args, cfg)))


if __name__ == "__main__":
    main()
