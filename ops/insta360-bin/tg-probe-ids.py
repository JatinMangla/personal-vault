#!/usr/bin/env python3
"""Probe: can we map filenames in the channel to message ids, and how fast?

READ-ONLY. Downloads nothing, deletes nothing, uploads nothing. It walks the
channel's message METADATA and prints what it finds.

WHY THIS EXISTS. Check #2 currently re-downloads the entire channel to verify
one batch, which cost a real drain ~5 hours on 2026-09-16. The intended fix was
`telegram-upload --print-file-id`, but that flag emits a Bot API file_id
(e.g. BQADBQADmiMAAss5WVXcwHLblCIghQI), NOT a message id - and Telethon's
resolve_bot_file_id() has open issues returning None for valid ids. Neither is
a foundation for a check that gates deleting originals.

This probes the documented alternative: message.file.name gives the filename,
message.id gives the id to fetch back later. If that mapping is reliable and
quick, Check #2 can fetch only this batch's messages.

    tg-probe-ids.py --config <json> --channel <id> [--limit N]

Exit codes: 0 probe completed, 2 bad invocation or Telethon unavailable.
"""

import argparse
import json
import sys
import time


def fail(msg, code=2):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--channel", required=True)
    ap.add_argument("--limit", type=int, default=0,
                    help="stop after N messages (0 = walk the whole channel)")
    args = ap.parse_args()

    try:
        from telethon.sync import TelegramClient
    except ImportError:
        fail("telethon is not importable. Run with the pipx interpreter: "
             "~/.local/share/pipx/venvs/telegram-upload/bin/python")

    try:
        with open(args.config) as fh:
            cfg = json.load(fh)
    except OSError as e:
        fail(f"cannot read config {args.config}: {e}")
    except json.JSONDecodeError as e:
        fail(f"config is not valid JSON: {e}")

    session = cfg["session"]
    if session.endswith(".session"):
        session = session[: -len(".session")]

    channel = args.channel
    try:
        channel = int(channel)
    except ValueError:
        pass

    started = time.time()
    seen = 0
    with_file = 0
    rows = []

    with TelegramClient(session, int(cfg["api_id"]), cfg["api_hash"]) as client:
        entity = client.get_entity(channel)
        for msg in client.iter_messages(entity, limit=args.limit or None):
            seen += 1
            if msg.file and msg.file.name:
                with_file += 1
                rows.append((msg.id, msg.file.name, msg.file.size or 0))

    elapsed = time.time() - started

    print(f"messages walked : {seen}")
    print(f"with a filename : {with_file}")
    print(f"elapsed         : {elapsed:.1f} s")
    if seen:
        print(f"rate            : {seen/max(elapsed,0.001):.0f} messages/s")
    print()
    print("message_id  size_bytes  filename")
    for mid, name, size in rows[:40]:
        print(f"{mid:>10}  {size:>10}  {name}")
    if len(rows) > 40:
        print(f"... and {len(rows)-40} more")

    # The question this probe exists to answer.
    print()
    names = [r[1] for r in rows]
    dupes = {n for n in names if names.count(n) > 1}
    if dupes:
        print(f"NOTE: {len(dupes)} filename(s) appear more than once:")
        for d in sorted(dupes)[:10]:
            print(f"  {d}")
        print("A filename is therefore NOT a unique key - the newest match must win,")
        print("or the mapping has to be built at upload time instead.")
    else:
        print("Every filename in the channel is unique, so filename -> message id")
        print("is an unambiguous mapping for this archive.")


if __name__ == "__main__":
    main()
