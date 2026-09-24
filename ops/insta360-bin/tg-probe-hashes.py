#!/usr/bin/env python3
"""Probe: can Telegram verify an upload WITHOUT downloading it back?

READ-ONLY with respect to the archive. Uploads nothing, deletes nothing,
edits nothing. At most it downloads ONE file, into a temporary directory that
it removes, and only when no local copy is supplied.

WHY THIS EXISTS. Check #2 proves an upload landed intact by downloading it
back and hashing it. On the 2026-09-19 drain that was 12.5 of ~28 minutes -
the largest leg, larger than the upload itself (docs/OPTIMISATION-PLAN.md).

MTProto has `upload.getFileHashes(location, offset)`, which returns SHA-256
digests of fixed-size ranges of a stored file, computed by Telegram. If they
cover the whole file and match the local bytes, the upload is proven intact
at the cost of a few small requests instead of the file's size in download.

Nothing depends on this yet. It answers three questions, with measurements:

  1. Does the method work for documents in this channel, from this account?
  2. Do the ranges cover the file completely, and match the real bytes?
  3. How long does it take, against downloading the same file?

Only if all three come back well does an opt-in TG_HASH_VERIFY path get built,
and even then the full download stays the default until drains measure faster.

    tg-probe-hashes.py --config <json> --channel <id> (--id N | --name FILE)
                       [--file LOCAL_COPY] [--max-download-mb 2048]

Run it with the pipx interpreter that has Telethon:
    ~/.local/share/pipx/venvs/telegram-upload/bin/python tg-probe-hashes.py ...

Run it only while NO drain is active (`tg-archive status` says idle): a
Telethon session file admits one process at a time, and a second gets
`database is locked`. The probe never slows a drain because it never runs
beside one.

Exit codes:
    0  hashes cover the file and every range matches
    1  a range did NOT match, or coverage is incomplete - do not use this method
    2  bad invocation, or Telethon unavailable
    3  Telegram refused or does not support the request for this file
"""

import argparse
import asyncio
import hashlib
import json
import os
import shutil
import sys
import tempfile
import time


def fail(msg, code=2):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


async def call_on_dc(client, dc_id, request):
    """Send `request` to the DC that stores the file.

    Documents live on a specific data centre. Telethon routes downloads there
    itself, but a raw request goes to the home DC, which may refuse it. The
    borrowed-sender helpers are Telethon internals (stable across 1.x); if they
    are missing, fall back to the home DC and let any error speak for itself.
    """
    home = getattr(client.session, "dc_id", None)
    borrow = getattr(client, "_borrow_exported_sender", None)
    if dc_id == home or borrow is None:
        return await client(request)
    sender = await borrow(dc_id)
    try:
        return await client._call(sender, request)
    finally:
        await client._return_exported_sender(sender)


def range_matches(path, offset, limit, digest):
    with open(path, "rb") as fh:
        fh.seek(offset)
        return hashlib.sha256(fh.read(limit)).digest() == bytes(digest)


async def run(args, cfg):
    from telethon import TelegramClient, errors, functions, types

    session = cfg["session"]
    if session.endswith(".session"):
        session = session[: -len(".session")]
    channel = args.channel
    try:
        channel = int(channel)
    except ValueError:
        pass

    async with TelegramClient(session, int(cfg["api_id"]), cfg["api_hash"]) as client:
        entity = await client.get_entity(channel)

        msg = None
        if args.id:
            msg = await client.get_messages(entity, ids=args.id)
        else:
            # Newest first, so a re-uploaded name resolves to its newest copy,
            # the same rule tg-resolve-ids.py uses.
            async for m in client.iter_messages(entity):
                if m.file and m.file.name == args.name:
                    msg = m
                    break
        if msg is None or not getattr(msg, "document", None):
            fail("no document message found for that id/name", 2)

        doc = msg.document
        size = int(doc.size)
        name = msg.file.name if msg.file else "?"
        print(f"message   : {msg.id}  {name}  {size} bytes  (dc {doc.dc_id})")

        location = types.InputDocumentFileLocation(
            id=doc.id,
            access_hash=doc.access_hash,
            file_reference=doc.file_reference,
            thumb_size="",
        )

        # --- 1. Ask Telegram for its hashes ----------------------------------
        hashes = []
        offset = 0
        requests = 0
        started = time.monotonic()
        while offset < size:
            try:
                batch = await call_on_dc(
                    client, doc.dc_id,
                    functions.upload.GetFileHashesRequest(location=location, offset=offset),
                )
            except errors.FloodWaitError as e:
                print(f"UNSUPPORTED IN PRACTICE: flood wait of {e.seconds}s after "
                      f"{requests} request(s) - too slow to replace a download")
                return 3
            except errors.RPCError as e:
                print(f"UNSUPPORTED: getFileHashes refused at offset {offset}: "
                      f"{type(e).__name__}: {e}")
                return 3
            requests += 1
            if not batch:
                print(f"UNSUPPORTED: empty answer at offset {offset}")
                return 3
            hashes.extend(batch)
            nxt = batch[-1].offset + batch[-1].limit
            if nxt <= offset:
                print(f"UNSUPPORTED: no progress past offset {offset}")
                return 3
            offset = nxt
        hash_secs = time.monotonic() - started
        print(f"hashes    : {len(hashes)} range(s) of {hashes[0].limit} bytes, "
              f"{requests} request(s), {hash_secs:.2f} s")

        # Coverage: contiguous from 0, reaching the end of the file.
        expected = 0
        for h in hashes:
            if h.offset != expected:
                print(f"FAIL: gap or overlap at offset {expected} (next range starts {h.offset})")
                return 1
            expected = h.offset + h.limit
        if expected < size:
            print(f"FAIL: ranges stop at {expected}, file is {size}")
            return 1

        # --- 2. The real bytes to compare against ----------------------------
        tmp = None
        download_secs = None
        path = args.file
        try:
            if path:
                if os.path.getsize(path) != size:
                    print(f"FAIL: local file is {os.path.getsize(path)} bytes, Telegram has {size}")
                    return 1
            else:
                if size > args.max_download_mb * 1024 * 1024:
                    fail(f"file is {size // (1024 * 1024)} MB; pass --file or raise "
                         f"--max-download-mb (this probe would download it once)", 2)
                tmp = tempfile.mkdtemp(prefix="tg-probe-hashes.")
                started = time.monotonic()
                path = await client.download_media(msg, file=tmp)
                download_secs = time.monotonic() - started
                print(f"download  : {download_secs:.2f} s (single connection, for comparison)")

            # --- 3. Compare every range ---------------------------------------
            bad = [h.offset for h in hashes
                   if not range_matches(path, h.offset, h.limit, h.hash)]
        finally:
            if tmp:
                shutil.rmtree(tmp, ignore_errors=True)

        if bad:
            print(f"FAIL: {len(bad)} of {len(hashes)} range(s) did not match, "
                  f"first at offset {bad[0]}")
            return 1

        print(f"MATCH     : all {len(hashes)} range(s) cover the file and match its bytes")
        if download_secs:
            print(f"speed     : {hash_secs:.2f} s by hashes vs {download_secs:.2f} s by "
                  f"download ({download_secs / max(hash_secs, 0.001):.0f}x)")
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    ap.add_argument("--channel", required=True)
    who = ap.add_mutually_exclusive_group(required=True)
    who.add_argument("--id", type=int, help="message id (4th ledger column)")
    who.add_argument("--name", help="filename; the newest message with it is used")
    ap.add_argument("--file", help="local copy of the same bytes; skips the download")
    ap.add_argument("--max-download-mb", type=int, default=2048)
    args = ap.parse_args()

    try:
        import telethon  # noqa: F401
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

    sys.exit(asyncio.run(run(args, cfg)))


if __name__ == "__main__":
    main()
