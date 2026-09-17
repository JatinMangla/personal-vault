#!/usr/bin/env python3
"""Download specific Telegram messages by id, instead of a whole channel.

WHY THIS EXISTS
---------------
`telegram-download` can only fetch an ENTIRE chat - it has no filename filter,
no glob and no message-id selector (docs/HARD-WON.md). Check #2 therefore
re-downloaded everything ever archived on every batch:

    batch 1     ~20 GB downloaded to verify ~20 GB
    batch 5    ~200 GB downloaded to verify ~20 GB
    batch 10   ~400 GB downloaded to verify ~20 GB

On 2026-09-15 that cost a real drain more than three hours, filled the boot
volume once, and made an interrupted batch re-upload 18.8 GB from scratch.

Message ids come from tg-resolve-ids.py, which asks Telegram directly after an
upload. An earlier design scraped `telegram-upload --print-file-id`, but that
flag emits a Bot API file_id rather than a message id - see tg-resolve-ids.py.
This
script fetches back only those ids, so Check #2 costs the size of the BATCH
rather than the size of the ARCHIVE, and stops growing forever.

USAGE
-----
    tg-fetch-ids.py --config <json> --channel <id> --into <dir> ID [ID...]

Exit codes:
    0  every requested id was downloaded
    1  a fetch failed, or an id was missing from the channel
    2  bad invocation, or Telethon is unavailable

WHAT IT DELIBERATELY DOES NOT DO
--------------------------------
No hashing, no rejoining, no deleting. tg-upload.sh owns the integrity chain;
this is only the transport it was missing. Keeping the verification logic in
one place is what stops the two copies drifting apart - the same reasoning that
keeps ledger writes in tg-upload.sh rather than in its wrapper.
"""

import argparse
import json
import os
import sys


def fail(msg, code=1):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--config", required=True,
                    help="telegram-upload JSON config (api_id, api_hash, session)")
    ap.add_argument("--channel", required=True,
                    help="channel id or @username, as passed to telegram-upload --to")
    ap.add_argument("--into", required=True, help="destination directory")
    ap.add_argument("ids", nargs="+", help="message ids to fetch")
    args = ap.parse_args()

    try:
        ids = [int(i) for i in args.ids]
    except ValueError:
        fail("message ids must be integers", 2)

    # Imported here, not at module scope: a missing Telethon must exit 2 with a
    # message the caller can act on, not a bare ImportError traceback. Telethon
    # ships as a telegram-upload dependency, so this normally succeeds.
    try:
        from telethon.sync import TelegramClient
    except ImportError:
        fail("telethon is not importable. It ships with telegram-upload; "
             "run this with the same interpreter, e.g. "
             "~/.local/share/pipx/venvs/telegram-upload/bin/python", 2)

    try:
        with open(args.config) as fh:
            cfg = json.load(fh)
    except OSError as e:
        fail(f"cannot read config {args.config}: {e}", 2)
    except json.JSONDecodeError as e:
        fail(f"config is not valid JSON: {e}", 2)

    for key in ("api_id", "api_hash", "session"):
        if key not in cfg:
            fail(f"config is missing '{key}'", 2)

    os.makedirs(args.into, exist_ok=True)

    # The session value carries NO .session extension - Telethon appends it.
    # Passing the file with the extension creates a SECOND session file and the
    # run then prompts for a login code, which cannot be answered from systemd.
    session = cfg["session"]
    if session.endswith(".session"):
        session = session[: -len(".session")]

    # A channel id may be numeric (-1004430700436) or an @username. int() first,
    # because Telethon resolves a numeric string as a phone-like entity and
    # raises rather than finding the channel.
    channel = args.channel
    try:
        channel = int(channel)
    except ValueError:
        pass

    failures = 0
    try:
        with TelegramClient(session, int(cfg["api_id"]), cfg["api_hash"]) as client:
            # Only one process may use a session at a time - a second gets
            # "database is locked". tg-upload.sh holds a flock around the whole
            # batch, so this inherits that serialisation.
            try:
                entity = client.get_entity(channel)
            except Exception as e:
                fail(f"cannot resolve channel {args.channel}: {e}")

            messages = client.get_messages(entity, ids=ids)

            # get_messages with ids= returns a list positionally aligned with
            # the request, using None for anything the account cannot see or
            # that has been deleted. Zipping against the request is what lets a
            # missing id name itself rather than surfacing as an off-by-one.
            for requested, msg in zip(ids, messages):
                if msg is None:
                    print(f"ERROR: message {requested} not found in the channel",
                          file=sys.stderr)
                    failures += 1
                    continue
                if not msg.file:
                    print(f"ERROR: message {requested} carries no file",
                          file=sys.stderr)
                    failures += 1
                    continue

                # Let Telethon name the file from the message itself, so a split
                # part keeps its NAME.00 / NAME.01 suffix and tg-upload.sh's
                # existing numeric rejoin still matches.
                path = client.download_media(msg, file=args.into)
                if not path:
                    print(f"ERROR: message {requested} downloaded nothing",
                          file=sys.stderr)
                    failures += 1
                    continue

                print(os.path.basename(path))
    except SystemExit:
        raise
    except Exception as e:
        fail(f"telegram fetch failed: {e}")

    if failures:
        fail(f"{failures} of {len(ids)} message(s) could not be fetched")


if __name__ == "__main__":
    main()
