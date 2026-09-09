# healthchecks.io setup

A dead-man's switch on the scheduled jobs.

The failure mode this exists to catch is not a loud crash — that shows up in the
logs. It is the job **silently stopping**: a timer that got disabled, a
credential that expired, a disk that filled. Without an external watcher,
that goes unnoticed for months, and it is discovered at exactly the worst
moment: when a restore is needed.

The logic is inverted from ordinary monitoring. Rather than alerting when
something reports a failure, healthchecks.io alerts when something **stops
reporting success**. Silence is the alarm.

## Free tier

20 checks, unlimited pings, email notification. This project uses two, so there
is ample headroom. No credit card.

## Checks to create

### 1. `immich-nightly-backup`

| Setting | Value |
|---|---|
| Schedule | Cron: `0 3 * * *` |
| Timezone | `Asia/Kolkata` |
| Grace period | **2 hours** |

Grace has to exceed the longest plausible backup. The first run uploads
everything and can take many hours — start with a wide grace, then tighten it
to about 2 hours once steady-state runs are only uploading the day's changes.

The script signals three states:

- `/start` before beginning — so a run that hangs is distinguishable from one
  that never started
- the bare URL on success
- `/<exit-code>` on failure — so the alert names the failure

### 2. `metrics-collector`

| Setting | Value |
|---|---|
| Schedule | Period: **15 minutes** |
| Grace period | **20 minutes** |

Secondary to the dashboard's own staleness banner, which turns red after 2 hours
without a sample. This check is what tells you when nobody is looking at the
dashboard.

### 3. Optional: `video-sync-monthly`

| Setting | Value |
|---|---|
| Schedule | Period: **35 days** |
| Grace period | **7 days** |

Deliberately loose. The external drive is connected manually, so this is a
nudge rather than an alarm. Set `HEALTHCHECK_VIDEO_UUID` in `ops.env` to enable.

## Configuration

Add the UUIDs to `/etc/personal-vault/ops.env` (mode 0600, never committed):

```bash
HEALTHCHECK_UUID=            # immich-nightly-backup
HEALTHCHECK_METRICS_UUID=    # metrics-collector
HEALTHCHECK_VIDEO_UUID=      # optional
```

A ping URL is a capability: anyone holding it can signal "success" and suppress
your alerts. It cannot read or damage anything, but treat it as a secret.

## Notification

Configure email at minimum. Set **"Notify when a check goes back up"** as well,
so a transient failure that self-resolves is visible rather than leaving you
wondering.

Point alerts at an address you actually read on your phone. An alert nobody
sees is the same as no alert.

## Verify it works — do not skip this

**Deliberately fail one run.** An untested alerting path is not an alerting
path; it is an assumption.

```bash
# Break the credentials temporarily
sudo systemctl stop immich-backup.timer
sudo OPS_ENV_FILE=/dev/null /opt/personal-vault/ops/backup/immich-backup.sh
# expect: script fails, healthchecks.io sends an alert within a minute
```

Confirm the email arrives. Then:

```bash
sudo systemctl start immich-backup.timer
sudo systemctl start immich-backup.service   # a real run, to clear the alert
```

This is on the final sign-off checklist for a reason. Verifying the alert path
after a real failure is too late.

## Optional: Uptime Kuma

Self-hosted, on the Oracle box, reachable over Tailscale only. It gives a nicer
dashboard for container health.

It is genuinely optional and slightly redundant: something running **on** the
box cannot alert you when the box itself is down, which is the failure that
matters most. healthchecks.io is external, so it can. If you add Uptime Kuma,
keep healthchecks.io as the outer watcher — and bind Kuma to the Tailscale
interface, never `0.0.0.0`.
