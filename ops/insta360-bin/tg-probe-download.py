#!/usr/bin/env python3
"""Probe: WHERE does a Telegram download fail, and was a re-upload a new copy?

READ-ONLY. Uploads nothing, deletes nothing, edits nothing, and writes no file:
the sampled bytes are read into memory and discarded.

WHY THIS EXISTS. On 2026-09-24/25 one file (message 244,
VID_20250221_145946_00_058.insv, 1.32 GB) could not be downloaded back for
Check #2 - every attempt ended in "Timeout while fetching data (caused by
GetFileRequest)", across 15+ hours and two separate uploads - while
tg-probe-hashes.py proved Telegram stores all of it intact, and older files
downloaded fine at the same moment. Two facts decide the fix:

  1. Did the second upload create a NEW stored document, or did Telegram
     de-duplicate it onto the same one? If the same, re-uploading can never
     help; uploading different bytes (e.g. split parts) is the way out.
  2. Does the download fail everywhere, or in one region of the file? The
     journal shows ~2 minutes of successful transfer before the timeouts,
     which suggests one bad region.

Part 1 lists every message carrying the filename, with its document id.
Part 2 fetches ONE 512 KiB request every --step MiB across the file and times
each, so the output is a map of good and bad regions.

    tg-probe-download.py --config <json> --channel <id> --name FILE
                         [--id N] [--step 64] [--timeout 45]

Run with the pipx interpreter that has Telethon, and ONLY while no drain is
active - a Telethon session admits one process at a time:
    ~/.local/share/pipx/venvs/telegram-upload/bin/python tg-probe-download.py ...

Exit codes: 0 probe completed (whatever it found), 2 bad invocation or
Telethon unavailable.
"""

import argparse
import asyncio
import json
import sys
import time

MIB = 1024 * 1024
REQUEST = 512 * 1024   # Telethon's default request size; divides 1 MiB evenly


def fail(msg, code=2):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


async def sample(client, msg, offset, timeout):
    """Fetch one request at `offset`. Returns (ok, seconds, detail)."""
    started = time.monotonic()
    try:
        async def one():
            got = 0
            async for chunk in client.iter_download(
                msg, offset=offset, limit=1, request_size=REQUEST
            ):
                got += len(chunk)
            return got

        got = await asyncio.wait_for(one(), timeout=timeout)
        return True, time.monotonic() - started, f"{got} bytes"
    except asyncio.TimeoutError:
        return False, time.monotonic() - started, f"no answer within {timeout}s"
    except Exception as e:  # noqa: BLE001 - a probe reports, it does not judge
        return False, time.monotonic() - started, f"{type(e).__name__}: {e}"


async def run(args, cfg):
    from telethon import TelegramClient

    session = cfg["session"]
    if session.endswith(".session"):
        session = session[: -len(".session")]
    channel = args.channel
    try:
        channel = int(channel)
    except ValueError:
        pass

    # Fewer internal retries than the default 5, so a bad region costs seconds
    # per sample rather than the ~45 s the pipeline sees per attempt.
    client = TelegramClient(session, int(cfg["api_id"]), cfg["api_hash"],
                            request_retries=1)
    async with client:
        entity = await client.get_entity(channel)

        # --- Part 1: every copy of this filename -----------------------------
        print(f"== messages named {args.name}")
        copies = []
        async for m in client.iter_messages(entity):
            if m.file and m.file.name == args.name and getattr(m, "document", None):
                d = m.document
                copies.append(m)
                print(f"  message {m.id:>6}  document {d.id}  {d.size} bytes  "
                      f"dc {d.dc_id}  {m.date:%Y-%m-%d %H:%M}")
        if not copies:
            fail(f"no message named {args.name} in the channel", 2)
        doc_ids = {m.document.id for m in copies}
        if len(copies) > 1:
            if len(doc_ids) == 1:
                print("  -> ALL copies share ONE document: Telegram de-duplicated the")
                print("     re-upload. Re-uploading identical bytes can never fix this.")
            else:
                print(f"  -> {len(doc_ids)} distinct documents: re-uploads made new copies.")

        msg = next((m for m in copies if m.id == args.id), None) if args.id else copies[0]
        if msg is None:
            fail(f"message {args.id} is not one of those listed", 2)
        size = int(msg.document.size)

        # --- Part 2: map good and bad regions ---------------------------------
        step = args.step * MIB
        offsets = list(range(0, size, step))
        last = (size - 1) // REQUEST * REQUEST        # the file's final request
        if offsets[-1] != last:
            offsets.append(last)

        print(f"\n== sampling message {msg.id}: {len(offsets)} points, one "
              f"{REQUEST // 1024} KiB request every {args.step} MiB")
        bad = []
        for off in offsets:
            ok, secs, detail = await sample(client, msg, off, args.timeout)
            mark = "ok  " if ok else "FAIL"
            print(f"  {mark} {off / MIB:>8.1f} MiB  {secs:5.1f} s  {detail}")
            if not ok:
                bad.append(off)

        print()
        if not bad:
            print("RESULT: every sampled region downloaded. The failure is not a fixed")
            print("region - try the full fetch again, or it depends on request pattern.")
        elif len(bad) == len(offsets):
            print("RESULT: EVERY sampled region failed - the whole document is unservable.")
        else:
            print(f"RESULT: {len(bad)} of {len(offsets)} regions failed, first at "
                  f"{bad[0] / MIB:.1f} MiB, last at {bad[-1] / MIB:.1f} MiB. The rest")
            print("downloads - the stored document has a bad region.")
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--channel", required=True)
    ap.add_argument("--name", required=True, help="filename as stored in the channel")
    ap.add_argument("--id", type=int, help="which copy to sample (default: newest)")
    ap.add_argument("--step", type=int, default=64, help="MiB between samples")
    ap.add_argument("--timeout", type=int, default=45, help="seconds per sample")
    args = ap.parse_args()
    if args.step < 1:
        fail("--step must be at least 1 MiB")

    try:
        import telethon  # noqa: F401
    except ImportError:
        fail("telethon is not importable. Run with the pipx interpreter: "
             "~/.local/share/pipx/venvs/telegram-upload/bin/python")
    try:
        with open(args.config) as fh:
            cfg = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        fail(f"cannot read config {args.config}: {e}")

    sys.exit(asyncio.run(run(args, cfg)))


if __name__ == "__main__":
    main()
