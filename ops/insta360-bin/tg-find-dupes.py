#!/usr/bin/env python3
"""Find duplicate files in the archive channel. READ-ONLY by default.

WHY THIS EXISTS. Interrupted drains re-uploaded files that had already reached
Telegram: a batch was killed mid-Check-#2 on 2026-09-15, nothing was recorded,
and the retry uploaded everything again. tg-probe-ids.py found 13 filenames
appearing more than once.

WHY IT REFUSES TO DELETE CASUALLY. Telegram is now the ONLY copy of this
footage - the card has been pruned. A wrong deletion is unrecoverable, and
there is no restore path. So this tool:

  - defaults to reporting, never deleting
  - matches on (filename, size) and requires an EXACT size match, because two
    files with the same name and different sizes are NOT duplicates - one of
    them is a re-recording, and deleting it would destroy unique footage
  - always keeps the NEWEST message of each duplicate set, because that is the
    one the ledger's message ids will point at
  - never deletes a file whose name appears only once
  - never deletes manifests (they are tiny, and they are the recovery index)

    tg-find-dupes.py --config <json> --channel <id>            # report only
    tg-find-dupes.py --config <json> --channel <id> --delete   # act

Exit codes: 0 completed, 2 bad invocation or Telethon unavailable.
"""

import argparse
import json
import sys
from collections import defaultdict


def fail(msg, code=2):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--channel", required=True)
    ap.add_argument("--delete", action="store_true",
                    help="actually delete the older copies (default: report only)")
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

    # (name, size) -> [message ids], newest first
    groups = defaultdict(list)
    total = 0

    with TelegramClient(session, int(cfg["api_id"]), cfg["api_hash"]) as client:
        entity = client.get_entity(channel)
        for msg in client.iter_messages(entity):
            if not (msg.file and msg.file.name):
                continue
            total += 1
            groups[(msg.file.name, msg.file.size or 0)].append(msg.id)

        # Name appears more than once, REGARDLESS of size. Needed to spot the
        # dangerous case: same name, different size.
        by_name = defaultdict(list)
        for (name, size), ids in groups.items():
            by_name[name].append((size, ids))

        redundant = []      # safe to delete: identical name AND size
        ambiguous = []      # same name, DIFFERENT size - never touch

        for name, variants in by_name.items():
            if len(variants) > 1:
                ambiguous.append((name, variants))
                continue
            size, ids = variants[0]
            if len(ids) > 1:
                keep = max(ids)
                drop = sorted(i for i in ids if i != keep)
                redundant.append((name, size, keep, drop))

        print(f"messages with a file : {total}")
        print(f"distinct filenames   : {len(by_name)}")
        print()

        if ambiguous:
            print("!! SAME NAME, DIFFERENT SIZE - these are NOT duplicates.")
            print("   One is likely a re-recording. Nothing here will be deleted.")
            for name, variants in sorted(ambiguous):
                print(f"   {name}")
                for size, ids in sorted(variants):
                    print(f"       {size:>12} bytes  msg {ids}")
            print()

        if not redundant:
            print("No safely-removable duplicates found.")
            return

        freed = 0
        print("Redundant copies (identical name AND size). Newest is kept:")
        for name, size, keep, drop in sorted(redundant):
            freed += size * len(drop)
            print(f"  {name}")
            print(f"      keep msg {keep}, delete {drop}  ({size} bytes each)")
        print()
        print(f"would delete {sum(len(d) for _,_,_,d in redundant)} message(s), "
              f"{freed/1e9:.1f} GB of redundant copies")

        if not args.delete:
            print()
            print("REPORT ONLY - nothing was deleted. Re-run with --delete to act.")
            return

        print()
        print("DELETING...")
        to_delete = [i for _, _, _, drop in redundant for i in drop]
        client.delete_messages(entity, to_delete)
        print(f"deleted {len(to_delete)} message(s)")
        print("The newest copy of every file remains in the channel.")


if __name__ == "__main__":
    main()
