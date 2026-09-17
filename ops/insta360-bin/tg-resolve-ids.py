#!/usr/bin/env python3
"""Map just-uploaded filenames to their Telegram message ids.

    tg-resolve-ids.py --config <json> --channel <id> NAME [NAME...]

Prints one line per resolved name:   <name>\t<id>[ <id>...]
Names that could not be found are reported on stderr and omitted from stdout,
so the caller can tell the difference between "resolved" and "missing".

WHY NOT --print-file-id
-----------------------
telegram-upload's --print-file-id emits a Bot API file_id, verified on the real
VM on 2026-09-17:

    Uploaded successfully "tgtest.txt" (file_id BQADBQADmiMAAss5WVXcwHLblCIghQI)

That is not a message id. get_messages(ids=...) needs integers, and converting
a file_id requires Telethon's resolve_bot_file_id(), which has open upstream
issues returning None for valid ids. Neither is a foundation for the check that
gates deleting originals, so this asks Telegram directly instead.

WHY NEWEST-WINS
---------------
tg-probe-ids.py found 13 filenames appearing more than once in the live
channel: interrupted drains re-uploaded files that had already landed. A
filename is therefore NOT a unique key. This resolver runs IMMEDIATELY after an
upload and takes the HIGHEST message id for each name, which is the copy just
created. Message ids in a channel increase monotonically, so "highest" is
"newest" - it never has to reason about timestamps.

WHY A BOUNDED WALK
------------------
Only the newest messages can belong to the batch just uploaded, so the walk
stops early rather than reading the whole channel. The probe measured 62
messages/s, so even an unbounded walk is seconds - but bounding it keeps the
cost flat as the archive grows, which is the entire point of this change.
"""

import argparse
import json
import sys


def fail(msg, code=2):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--channel", required=True)
    ap.add_argument("--limit", type=int, default=400,
                    help="how many recent messages to scan (default 400)")
    ap.add_argument("names", nargs="+")
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

    # A split file arrives as NAME.00, NAME.01, ... - separate messages, each
    # needed to rebuild the original. Match any message whose filename is the
    # requested name OR starts with "name." followed by digits.
    wanted = set(args.names)

    def belongs_to(fname):
        if fname in wanted:
            return fname
        if "." in fname:
            stem, _, suffix = fname.rpartition(".")
            if suffix.isdigit() and stem in wanted:
                return stem
        return None

    # name -> {msg_id: None}, insertion ordered; highest ids seen first because
    # iter_messages walks newest-first.
    found = {}

    try:
        with TelegramClient(session, int(cfg["api_id"]), cfg["api_hash"]) as client:
            entity = client.get_entity(channel)
            for msg in client.iter_messages(entity, limit=args.limit):
                if not (msg.file and msg.file.name):
                    continue
                owner = belongs_to(msg.file.name)
                if owner is None:
                    continue
                # Keep the first (newest) id seen per PART filename. A part that
                # appears twice - the duplicate case - must contribute only its
                # newest copy, or Check #2 would rejoin a part from an older
                # upload with parts from this one.
                found.setdefault(owner, {})
                if msg.file.name not in found[owner]:
                    found[owner][msg.file.name] = msg.id
    except SystemExit:
        raise
    except Exception as e:
        fail(f"telegram lookup failed: {e}")

    missing = [n for n in args.names if n not in found]
    for name in args.names:
        if name in found:
            ids = sorted(found[name].values())
            print(f"{name}\t{' '.join(str(i) for i in ids)}")

    if missing:
        for n in missing:
            print(f"ERROR: no message found for {n}", file=sys.stderr)
        fail(f"{len(missing)} of {len(args.names)} name(s) unresolved", 1)


if __name__ == "__main__":
    main()
