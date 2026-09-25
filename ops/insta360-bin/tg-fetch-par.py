#!/usr/bin/env python3
"""Fetch Telegram messages by id, several at a time. OPT-IN, OFF BY DEFAULT.

WHY THIS EXISTS
---------------
Measured on the real archive, 2026-09-18:

    upload    6.2 GB in ~25 min   = 4.6 MB/s
    Check #2  6.2 GB in ~162 min  = 0.64 MB/s     <-- 7x slower than upload

Fetching by message id already removed the whole-channel download, so Check #2
now costs the size of the BATCH rather than the ARCHIVE. But the download
itself is sequential, and at 0.64 MB/s it became 85% of the drain. The journal
for that run is full of

    Telegram is having internal issues TimeoutError (caused by GetFileRequest)

which is one connection stalling and retrying while nothing else progresses.

MEASURED IN PRODUCTION, 2026-09-19, first real run with TG_PAR_FETCH=1:

    6.55 GB (4 split parts) fetched in 12m 33s = 8.9 MB/s
    against 6.2 GB in 162 min = 0.64 MB/s sequentially

~14x faster, and ONE TimeoutError in the journal instead of a storm of them:
when a connection stalls the other three keep working, which is the mechanism
this was built for. The whole drain - upload, fetch, hash, verify - came to
~28 minutes.

WHAT IT PARALLELISES, AND WHAT IT DELIBERATELY DOES NOT
------------------------------------------------------
Several FILES at once. NOT one file across several connections.

That is the whole safety argument. Each file is streamed start to finish by a
single task, appending chunks in the order Telethon yields them, so there is no
offset arithmetic anywhere in this script - and "computed an offset wrong",
the main risk in any parallel-transfer design, cannot occur here. A batch is
typically several messages anyway (one split 4.1 GB file was 3 on its own), so
per-file concurrency is where the win is.

request_size is left at Telethon's default of 524288 (512 KB), which is also
MAX_CHUNK_SIZE and Telegram's documented recommendation. Verified against the
installed build on 2026-09-18 rather than assumed - four of five flags assumed
from memory in this project turned out not to exist.

SAFETY
------
This runs INSIDE the integrity chain, between the upload and the SHA-256
comparison that gates deleting originals. It therefore fails loudly rather than
returning something plausible:

  - each file is written to a DOT-PREFIXED temp name and only then
    os.replace()d into place, so an interrupted fetch can never leave a short
    file where tg-upload.sh's rejoin glob would pick it up. The dot matters:
    the glob is NAME.[0-9][0-9]* and its trailing * matches ".part" too
  - bytes written are asserted equal to the size Telegram reports for that
    message; a mismatch fails the run and names the file
  - a SHORT FloodWaitError (<= 30 s) is logged and waited out, and that file
    restarts from byte 0 - up to 3 times. A longer one aborts and exits
    non-zero, which makes tg-upload.sh fall back to the proven sequential
    path. Nothing sleeps without a log line
  - free space is checked before anything is fetched, because tg-upload.sh's
    disk watchdog guards only the full-channel download, not this path
  - concurrency defaults to 4, not FastTelethon's 20, and is capped at 8. The
    timeouts above show Telegram already straining on ONE connection

It does NO hashing, NO rejoining and NO deleting - tg-upload.sh owns all three,
exactly as tg-fetch-ids.py does. This is transport only. Keeping verification
in one place is what stops the two copies drifting apart.

USAGE
-----
    tg-fetch-par.py --config <json> --channel <id> --into <dir> ID [ID...]

Exit codes:
    0  every requested id was downloaded and its length verified
    1  a fetch failed, was short, or an id was missing - caller should fall back
    2  bad invocation, or Telethon is unavailable
"""

import argparse
import asyncio
import json
import os
import shutil
import sys


def fail(msg, code=1):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


def log(msg):
    print(msg, file=sys.stderr)


# A SHORT flood wait is retried, LOUDLY; a long one still aborts.
#
# Aborting on every flood wait was deliberate - a silent sleep once hid a slow
# fetch for 162 minutes - but it made FLOOD_WAIT_1 on one part of a 20-part
# restore (2026-09-25) fail the whole run, and in Check #2 it would push the
# batch onto the 0.64 MB/s sequential path: minutes lost to a one-second pause.
# Waiting a few seconds, with a log line saying so, keeps the "never silent"
# rule and loses nothing. Anything longer still aborts, exactly as before.
FLOOD_RETRY_MAX_SECONDS = int(os.environ.get("TG_FLOOD_RETRY_MAX", "30"))
FLOOD_RETRIES = 3


def flood_should_retry(seconds, attempt):
    """True if a FLOOD_WAIT of `seconds` on retry number `attempt` (0-based)
    should be waited out and retried, rather than abort the run."""
    return 0 <= seconds <= FLOOD_RETRY_MAX_SECONDS and attempt < FLOOD_RETRIES


async def fetch_one(client, msg, into, sem, results):
    """Stream ONE message to disk. Sequential within the file, by design."""
    from telethon.errors import FloodWaitError

    name = msg.file.name or "msg{}".format(msg.id)
    expected = msg.file.size
    final = os.path.join(into, name)
    # DOT-PREFIXED, not "final + .part".
    #
    # tg-upload.sh finds split parts with the glob NAME.[0-9][0-9]*, and the
    # trailing * matches anything - so "NAME.insv.00.part" DOES match it. A
    # crashed fetch would then have its half-written temp file concatenated
    # into the rejoined file alongside the real parts, producing a corrupt
    # whole. Caught by test-fetch-par.py before this ever ran.
    #
    # A leading dot puts it outside that glob entirely, the same way
    # $STAGING_DIR/.roundtrip keeps verification copies away from *.insv.
    tmp = os.path.join(into, "." + name + ".part")

    async with sem:
        attempt = 0
        while True:
            written = 0
            try:
                # Append in yield order. No seek, no offset arithmetic: chunks
                # arrive in sequence for this file and are written in sequence.
                # A retry reopens with "wb", so it always starts from byte 0.
                with open(tmp, "wb") as fh:
                    async for chunk in client.iter_download(msg):
                        fh.write(chunk)
                        written += len(chunk)
                break
            except FloodWaitError as e:
                _unlink(tmp)
                if flood_should_retry(e.seconds, attempt):
                    attempt += 1
                    log("FLOOD_WAIT_{} on {} - waiting {}s, then retrying it from "
                        "the start (retry {}/{})".format(
                            e.seconds, name, e.seconds + 1, attempt, FLOOD_RETRIES))
                    await asyncio.sleep(e.seconds + 1)
                    continue
                results[msg.id] = ("flood", "FLOOD_WAIT_{}".format(e.seconds))
                return
            except Exception as e:
                results[msg.id] = ("error", "{}: {}".format(type(e).__name__, e))
                _unlink(tmp)
                return

        # THE assertion. A short download reaching the rejoin would be hashed,
        # mismatch, and fail Check #2 - safe, but it wastes the whole batch and
        # reports the wrong cause. Catching it here names the real one.
        if expected is not None and written != expected:
            results[msg.id] = (
                "short",
                "{}: wrote {} bytes, expected {}".format(name, written, expected),
            )
            _unlink(tmp)
            return

        # Atomic. Until this line the rejoin glob cannot see a partial file:
        # the temp name starts with a dot, which the glob cannot match.
        os.replace(tmp, final)
        results[msg.id] = ("ok", name)


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


async def run(client, entity, ids, into, concurrency):
    messages = await client.get_messages(entity, ids=ids)

    wanted = []
    missing = 0
    total_bytes = 0
    for requested, msg in zip(ids, messages):
        if msg is None:
            log("ERROR: message {} not found in the channel".format(requested))
            missing += 1
            continue
        if not msg.file:
            log("ERROR: message {} carries no file".format(requested))
            missing += 1
            continue
        wanted.append(msg)
        total_bytes += msg.file.size or 0

    if missing:
        return None, missing

    # Do not start a fetch that cannot finish. This path is batch-sized so it
    # is rarely tight, but tg-upload.sh's watchdog guards only the full-channel
    # download - this one has to check for itself.
    free = shutil.disk_usage(into).free
    if total_bytes and free < total_bytes * 1.1:
        fail(
            "not enough free space: need ~{} MiB plus margin, have {} MiB".format(
                total_bytes // 2 ** 20, free // 2 ** 20
            ),
            1,
        )

    log(
        "fetching {} message(s), {} MiB, {} at a time".format(
            len(wanted), total_bytes // 2 ** 20, concurrency
        )
    )

    sem = asyncio.Semaphore(concurrency)
    results = {}
    await asyncio.gather(
        *(fetch_one(client, m, into, sem, results) for m in wanted)
    )
    return results, 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--config", required=True,
                    help="telegram-upload JSON config (api_id, api_hash, session)")
    ap.add_argument("--channel", required=True,
                    help="channel id or @username, as passed to telegram-upload --to")
    ap.add_argument("--into", required=True, help="destination directory")
    ap.add_argument("--concurrency", type=int,
                    default=int(os.environ.get("TG_FETCH_CONCURRENCY", "4")),
                    help="files in flight at once (default 4, max 8)")
    ap.add_argument("ids", nargs="+", help="message ids to fetch")
    args = ap.parse_args()

    try:
        ids = [int(i) for i in args.ids]
    except ValueError:
        fail("message ids must be integers", 2)

    # Capped deliberately. This is a shared, rate-limited API and the channel is
    # the only copy of this footage; FastTelethon's default of 20 is not a
    # precedent worth following here.
    if args.concurrency < 1 or args.concurrency > 8:
        fail("concurrency must be between 1 and 8", 2)

    try:
        from telethon import TelegramClient
    except ImportError:
        fail("telethon is not importable. It ships with telegram-upload; "
             "run this with the same interpreter, e.g. "
             "~/.local/share/pipx/venvs/telegram-upload/bin/python", 2)

    try:
        with open(args.config) as fh:
            cfg = json.load(fh)
    except OSError as e:
        fail("cannot read config {}: {}".format(args.config, e), 2)
    except json.JSONDecodeError as e:
        fail("config is not valid JSON: {}".format(e), 2)

    for key in ("api_id", "api_hash", "session"):
        if key not in cfg:
            fail("config is missing '{}'".format(key), 2)

    os.makedirs(args.into, exist_ok=True)

    # The session value carries NO .session extension - Telethon appends it.
    # Passing it with the extension creates a SECOND session file, and the run
    # then prompts for a login code that cannot be answered from systemd.
    session = cfg["session"]
    if session.endswith(".session"):
        session = session[: -len(".session")]

    # Numeric first: Telethon resolves a numeric STRING as a phone-like entity
    # and raises rather than finding the channel.
    channel = args.channel
    try:
        channel = int(channel)
    except ValueError:
        pass

    async def main_async():
        client = TelegramClient(session, int(cfg["api_id"]), cfg["api_hash"])
        # Never sleep silently on a flood wait. A slow fetch and a throttled one
        # look identical in the log otherwise - and this script exists because a
        # slow fetch went unexplained for 162 minutes.
        client.flood_sleep_threshold = 0
        await client.connect()
        try:
            if not await client.is_user_authorized():
                fail("session is not authorized - a human must log in once", 2)
            try:
                entity = await client.get_entity(channel)
            except Exception as e:
                fail("cannot resolve channel {}: {}".format(args.channel, e))
            return await run(client, entity, ids, args.into, args.concurrency)
        finally:
            await client.disconnect()

    try:
        results, missing = asyncio.run(main_async())
    except SystemExit:
        raise
    except Exception as e:
        fail("telegram fetch failed: {}: {}".format(type(e).__name__, e))

    if missing:
        fail("{} of {} message(s) could not be fetched".format(missing, len(ids)))

    failures = 0
    for mid in ids:
        state, detail = results.get(mid, ("error", "no result recorded"))
        if state == "ok":
            print(detail)
        else:
            # FLOOD_WAIT_<n> is emitted verbatim so it reads the same way the
            # upload path's throttling already does in the journal.
            log("ERROR: message {}: {}".format(mid, detail))
            failures += 1

    if failures:
        fail("{} of {} message(s) could not be fetched".format(failures, len(ids)))


if __name__ == "__main__":
    main()
