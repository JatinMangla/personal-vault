#!/usr/bin/env python3
"""Delete specific channel messages by id - never one the ledger relies on.

    tg-delete-ids.py --config <json> --channel <id> ID [ID...]            # report
    tg-delete-ids.py --config <json> --channel <id> --delete ID [ID...]   # act

WHY THIS EXISTS. Uploads that fail Check #2 stay in the channel. On
2026-09-24/25 three whole-file copies of one video (messages 244, 246, 248)
could not be downloaded back, and tg-upload-parts.sh reports any part copy
that failed the same way. They are useless, and worse than useless for a
whole-channel restore, which would stall on their dead blocks.

THE ONE HARD RULE: an id listed in the ledger's fourth column is refused,
always, with or without --delete. The ledger is what says "this message IS
the archived copy"; deleting one of those would destroy footage whose
original may already be gone from the card. A typo in an id cannot get past
this.

Also refused: an id that does not exist, and any message whose file is a
manifest copy (tiny, and the recovery index). Report-only unless --delete.

Exit codes: 0 done (or report printed), 1 something was refused, 2 bad
invocation or Telethon unavailable.
"""

import argparse
import json
import sys


def fail(msg, code=2):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def ledger_ids(path):
    """Every message id the ledger's fourth column points at."""
    ids = set()
    with open(path) as fh:
        for line in fh:
            fields = line.split()
            for tok in fields[3:]:
                if tok.isdigit():
                    ids.add(int(tok))
    return ids


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--channel", required=True)
    ap.add_argument("--ledger", default="/var/lib/insta360-archive/work/uploaded.sha256")
    ap.add_argument("--delete", action="store_true", help="act (default: report only)")
    ap.add_argument("ids", nargs="+", type=int)
    args = ap.parse_args()

    try:
        protected = ledger_ids(args.ledger)
    except OSError as e:
        fail(f"cannot read the ledger {args.ledger}: {e} - refusing to delete blind")

    try:
        from telethon.sync import TelegramClient
    except ImportError:
        fail("telethon is not importable. Run with the pipx interpreter: "
             "~/.local/share/pipx/venvs/telegram-upload/bin/python")
    try:
        with open(args.config) as fh:
            cfg = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        fail(f"cannot read config {args.config}: {e}")

    session = cfg["session"]
    if session.endswith(".session"):
        session = session[: -len(".session")]
    channel = args.channel
    try:
        channel = int(channel)
    except ValueError:
        pass

    refused = 0
    deletable = []
    with TelegramClient(session, int(cfg["api_id"]), cfg["api_hash"]) as client:
        entity = client.get_entity(channel)
        msgs = client.get_messages(entity, ids=args.ids)
        for want, msg in zip(args.ids, msgs):
            if msg is None:
                print(f"  REFUSE {want}: no such message")
                refused += 1
                continue
            name = msg.file.name if msg.file else "(no file)"
            size = msg.file.size if msg.file else 0
            if want in protected:
                print(f"  REFUSE {want}: {name} - the LEDGER points at this message")
                refused += 1
            elif name.startswith("manifest-"):
                print(f"  REFUSE {want}: {name} - manifest copies are kept")
                refused += 1
            else:
                print(f"  delete {want}: {name}  ({size} bytes)")
                deletable.append(want)

        if not args.delete:
            print(f"\nREPORT ONLY - {len(deletable)} would be deleted. "
                  f"Re-run with --delete to act.")
        elif deletable:
            client.delete_messages(entity, deletable)
            print(f"\ndeleted {len(deletable)} message(s): {' '.join(map(str, deletable))}")

    sys.exit(1 if refused else 0)


if __name__ == "__main__":
    main()
