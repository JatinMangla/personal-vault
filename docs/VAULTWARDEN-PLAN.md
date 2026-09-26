# Vaultwarden for the family — plan + adversarial review (handoff)

> **For the next Claude Code session.** This document is self-contained. Before acting, read
> the repo's `CLAUDE.md` → `docs/BUILD-STATE.md` → `docs/REVIEW-2026-09-24.md` →
> `docs/HARD-WON.md` (Telegram drain), then this file. Written 2026-09-26. Every fact
> marked *verified* was checked against the source on that date; re-check versions before
> deploying.
>
> **Status 2026-09-26: Phases 0–6 are built and tested in the repository; nothing is
> deployed yet.** What was built, and every place the build differs from §6, is in §9.
> The owner's deployment steps, in order, are in `docs/VAULTWARDEN-RUNBOOK.md`.

---

## 1. Goal and constraints

A self-hosted, Bitwarden-compatible password manager for the owner's family, running
on the existing Oracle VM.

Owner's goals, in priority order as stated:
1. **Security**
2. **Fast**
3. **Efficient**
4. **Effective**, meaning the family actually uses it
5. **Free**, within the $0–1/year budget

Hard rules from `CLAUDE.md` that apply here:
- $0–1/yr, with a ledger entry for every service.
- No secrets in git.
- Never weaken encryption.
- Never `:latest`; pin versions.
- arm64 images only.
- **Speed first**: no change may slow uploads or any other feature. Tag every change
  Faster / Neutral / One-off, and measure it.

## 2. Decisions the owner has already made

| Question | Decision |
|---|---|
| Fork Vaultwarden, or deploy upstream? | **Deploy the upstream pinned image.** Improvements go into the deployment, not the code |
| How the family connects | **Invite them into the owner's tailnet**, with an access rule limiting them to the vault |
| Phone push sync | **Enable Bitwarden's push relay** |
| Where it lives | **This repo**, `infra/vaultwarden/`, as a separate compose project from Immich. Not a new repo |

Why no fork: Vaultwarden is already Rust with a tiny footprint. All the encryption runs
in the official Bitwarden apps; the server only stores ciphertext. What users feel as
slowness is the key derivation on their own device, not the server. A fork would mean
merging every security advisory by hand: 1.37.0 alone had 8, and 2026 has had
CVE-2026-26012, GHSA-c5rv-q295-7w4g, GHSA-hxqh-ff5p-wfr3, GHSA-937x-3j8m-7w7p and
GHSA-pfp2-jhgq-6hg5.

## 3. Facts this rests on

**Repo and VM, as of 2026-09-26**
- **VM:** `VM.Standard.A1.Flex` with 2 OCPU / 12 GB, arm64, Ubuntu 24.04, ap-mumbai-1.
  Hostname `immich-mumbai`.
  - Boot volume: 50 GB Balanced, holding the OS, Docker and Postgres. It was last
    recorded at 24.8%, but once jumped from 25% to 79% during a drain bug.
  - Block volume: 150 GB at 0 VPU, mounted at `/mnt/media`.
- **What runs on it:**
  - Docker: Immich (server, ML capped at 1.5 CPU / 4 GB, Postgres with
    `shared_buffers=3GB`, Valkey).
  - systemd: Syncthing, the Telegram drain (`tg-archive`, capped at 75% CPU / 1 GB),
    the nightly scrub, the metrics push every minute, and restic at 03:00.
  - **No measured RAM or CPU figures exist in the docs.** The live numbers are in
    Supabase `metrics_samples`.
- **Network:**
  - Tailscale-only. ufw allows all traffic on `tailscale0`, plus UDP 41641.
  - Zero open TCP ports from the internet.
  - No reverse proxy and no TLS. Immich is plain HTTP on the Tailscale IP, port 2283.
- **Backups:**
  - restic goes to Oracle Object Storage, bucket `immich-backup`. The free-tier guard
    refuses runs above 85% of 10 GiB.
  - ~~The repo was last recorded at 71,128 MiB, so backups are being refused.~~
    **Superseded 2026-09-26 by the live metrics (see §6 Phase 0 results):** the repo
    was shrunk on 2026-09-24 and every nightly run since is green, at 312 MiB.
  - Oracle warns that objects are **deleted if over the limit at trial end**.
- **Circular dependency:** `ops/README.md:11` said the restic password must live in "a
  password manager that syncs off this machine". *Fixed in Phase 0: it now points to
  the paper kit and the document vault.*
- **Budget ledger is stale:** it still lists Tailscale as "3 users".

**External, verified 2026-09-26**
- **Tailscale Personal (free):** "Up to 6 users", "Unlimited user devices", "Up to 3 ACL
  groups". Sharees reach shared machines only by `<host>.<tailnet>.ts.net`.
- **Bitwarden cloud:**
  - Free: always free, but sharing is limited to **one other user** through the free
    organization.
  - Premium: $19.80/yr.
  - Families: $47.88/yr for 6 users, which breaks the budget.
- **Vaultwarden:**
  - Current release is 1.37.3 (2026-09-13).
  - The web vault **requires HTTPS**.
  - The wiki says Rocket's built-in TLS "is not considered ready for production".
  - SQLite must be backed up with `.backup` or `/vaultwarden backup`, and any
    `-wal` file deleted before a restore.
  - `config.json` holds the admin token and SMTP credentials in plaintext.
  - Push needs an installation ID and key from bitwarden.com/host, and does not work
    on F-Droid builds.
- **Oracle Always Free idle reclaim:** an A1 instance counts as idle if, over 7 days,
  its 95th-percentile CPU, network **and** memory are all below 20%.

---

## 4. Adversarial review

This section argues against the plan. Each finding names the goal it threatens and the
fix. The revised plan in §6 already includes every fix.

### Critical: no-go until fixed

**C1. There are no working backups.** *(Threatens: security and effectiveness.)*
**RESOLVED before Phase 0 ran:** green nightly runs 2026-09-24 20:44, 09-25 03:03 and
09-26 03:00 UTC, with the repo at 312 MiB of 10,240. See §6 Phase 0 results.
- The restic repo is about 71 GiB against a 10 GiB tier, so the guard refuses every
  nightly run.
- If the trial ends while the repo is over the limit, Oracle deletes all objects.
- A family password vault must not go live on an unbacked-up host.
- **Fix:**
  - Shrink the repo per `docs/RUNBOOK.md:473-504`.
  - Get one green nightly run, confirmed in healthchecks.io.
  - Record the new repo size in the ledger.
- *One-off.*

**C2. Every server-side copy sits in one Oracle account.** *(Threatens: security and
effectiveness.)*
- The VM and Object Storage belong to the same account. Free-tier account suspension
  or termination loses both at once.
- The first plan's fallback was quarterly exports done by each family member. They
  will not happen.
- **Fix:** a daily off-Oracle copy of the Vaultwarden backup, which is only a few MB.
  - Encrypt it before it leaves the VM, with restic or `age`.
  - Put it in a second free location. Google Drive via rclone with the `drive.file`
    scope is already an open decision in `docs/REVIEW-2026-09-24.md` §5.
  - Run `/verify-free-tier` first.
  - The rclone token is a new secret on the VM: keep it mode 0600 in
    `/etc/personal-vault/ops.env`.
- *Neutral: MBs per day, run outside drain windows.*

**C3. Moving Tailscale to access rules can break the Telegram drain and Immich.**
*(Threatens: speed first and effectiveness.)*
- The tailnet presumably uses the default allow-all policy today.
- Writing a restrictive policy for `group:family` changes the rules for **every** flow:
  - phone → VM Syncthing, which feeds the drain;
  - SSH;
  - Immich on port 2283;
  - owner devices talking to each other.
- The first plan also said to *tag* the VM. A tagged node loses user ownership, which
  silently changes which rules match it.
- **Fix:**
  - **Do not tag the VM.** Use a `hosts` alias in the policy instead.
  - Write the policy as: the owner reaches everything (explicit owner rule), and
    `group:family` reaches only `vm:443`.
  - Before applying it, list every existing flow (Syncthing 22000/tcp+udp, 22, 2283,
    8384 is localhost so unaffected) and check each one in "Preview rules".
  - Apply it while no drain is running.
  - Measure the next drain against the 28-minute baseline.
- *Neutral if done this way.*

**C4. The restic password would be locked inside the thing it protects.** *(Threatens:
security.)*
- If Vaultwarden on this VM holds the restic password, one VM loss locks out both.
- **Fix:**
  - Keep the restic password, the Vaultwarden admin token and the rclone passphrase on
    a paper emergency kit, plus the existing E2EE `vault/`.
  - They must never live **only** in Vaultwarden.
  - Update `ops/README.md:11`.
- *One-off.*

### High

**H1. A stolen database lets an attacker guess family master passwords offline.**
*(Threatens: security.)*
- `db.sqlite3` and its backups hold each user's KDF settings and their protected
  symmetric key.
- An attacker with a copy can guess master passwords offline at the speed of the client
  KDF. **2FA does not help against this**, and weak family passwords are the realistic
  way this system gets broken.
- **Fix:**
  - Add an org Master Password Requirements policy: at least 14 characters, or a
    4+ word passphrase.
  - Switch every account to the **Argon2id** KDF.
  - Keep backups encrypted (restic, plus C2 encryption before upload).
  - Require 2FA through an org policy for online attacks.
- *Neutral. Argon2id unlock is under a second on current phones; measure on the
  oldest family phone.*

**H2. The family will stop using it if saving fails when Tailscale is off.**
*(Threatens: effectiveness.)*
- Bitwarden apps autofill from their offline cache, but **cannot save or edit items**
  while the server is unreachable.
- A non-technical user with Tailscale switched off hits a save error and gives up.
- iOS allows only one VPN at a time, so it clashes with work VPNs.
- **Fix:**
  - Android: Settings → VPN → Tailscale → *Always-on VPN*.
  - iOS: enable Tailscale *VPN On Demand*.
  - A one-page family guide.
  - Acceptance test: "save a new login on mobile data" on every family phone.
- *Neutral.*

**H3. Security patches depend on one person noticing.** *(Threatens: security.)*
- Advisories arrive every few months. The plan's 72-hour patch target depends on the
  owner seeing them.
- **Fix:**
  - Use GitHub → Watch → Custom → **Releases + Security alerts** on
    dani-garcia/vaultwarden. This costs nothing and needs no code; it replaces the
    earlier idea of a GitHub Action.
  - Write a 3-command update runbook: bump the pinned tag and digest, `compose pull`,
    `compose up -d`.
  - Being reachable only over Tailscale buys time, but is no excuse to skip patches.
- *Neutral, and less code than the first plan.*

**H4. The container would run as root.** *(Threatens: security.)*
- The first plan did not set a user. The hardening guide recommends uid 1000.
- **Fix:**
  - `user: "1000:1000"`
  - `ROCKET_PORT=8080`, because a non-root process cannot bind port 80.
  - `read_only: true` with a tmpfs `/tmp`
  - `cap_drop: [ALL]` and `no-new-privileges`
  - `chown` `/var/lib/vaultwarden` to 1000.
- *Neutral.*

**H5. Admin Password Reset clashes with CLAUDE.md rule 3.** *(Threatens: security.)*
- That org policy lets the owner reset any member's master password. It weakens
  end-to-end encryption for members.
- It also means that compromising the owner's account compromises every family
  account.
- **Fix:**
  - Default **OFF**.
  - Use **Emergency Access** instead: it's time-delayed, the user approves it, and it
    doesn't weaken E2EE.
  - If the owner still wants reset for elderly relatives, record it as an explicit rule-3
    trade-off in `docs/BUILD-STATE.md`.
- *Neutral.*

**H6. Only one person can run it.** *(Threatens: effectiveness.)*
- If the owner is unavailable, nobody can patch, restore or add a device.
- **Fix:**
  - A sealed paper "if I'm unavailable" note: where the offline copy is, how to restore
    it, and the emergency kit.
  - Existing devices keep working from their offline caches in the meantime.
- *One-off.*

### Medium

**M1. The push relay sees metadata, not just push tokens.** *(Security/privacy.)*
- The first plan said only device push tokens reach Bitwarden. That was wrong.
- Per Vaultwarden's push code, the relay also receives user, device and item UUIDs and
  change timestamps. It never sees names or contents.
- The owner chose push for speed. Keep it, but record the metadata leak honestly in the
  ledger and in `SECURITY-NOTES`.

**M2. `config.json` silently overrides Ansible.** *(Efficiency and security.)*
- Pressing Save on `/admin` writes `config.json`, which takes precedence over `.env`.
  Ansible changes then quietly do nothing.
- The file also holds the admin token in plaintext.
- **Fix:**
  - Never save settings in the admin page.
  - The deploy task fails if `config.json` exists.
  - Remove `ADMIN_TOKEN` after the initial invites, which disables `/admin`.

**M3. A full boot volume would stop the password manager saving.** *(Effectiveness.)*
- A drain bug has filled the boot volume from 25% to 79% before. When it is full,
  SQLite writes fail and the vault cannot save.
- **Fix:** add a free-space check to the Vaultwarden health ping, failing below 15%
  free. Keep the data on the boot volume; its Balanced tier is faster than the 0-VPU
  block volume.

**M4. A digest pin can lock in the wrong architecture.** *(Security.)*
- **Fix:** pin the **multi-arch index** digest, and check that
  `docker buildx imagetools inspect vaultwarden/server:1.37.3` lists `linux/arm64`.
  Never pin a single-architecture manifest digest by accident.

**M5. The CPU cap may slow logins.** *(Speed.)*
- The server hashes each login with PBKDF2 at 600,000 iterations
  (`PASSWORD_ITERATIONS`). A 0.5-CPU cap may make login slow.
- Unlocking is local and unaffected; only logins are.
- **Fix:** time a login with the cap at 0.5 and at 1.0. Pick the lowest cap under
  about 1 second.
- *Tag once measured.*

**M6. HTTPS certificates publish the machine name.** *(Privacy.)*
- Issuing a `ts.net` certificate records the hostname in public Certificate Transparency
  logs. "immich-mumbai" advertises what the machine runs.
- The machine stays unreachable from the internet, so the impact is low.
- **Fix, optional:** rename the node to something neutral before enabling HTTPS. This
  also changes Immich's MagicDNS name, so check Syncthing and any bookmarks.

**M7. Brute-force protection.** *(Security.)*
- Use the built-in limits: `LOGIN_RATELIMIT_SECONDS=60`,
  `LOGIN_RATELIMIT_MAX_BURST=10`, `ADMIN_RATELIMIT_*`. They cost less than fail2ban.
- A compromised family phone is inside the tailnet, so this still matters.

**M8. Oracle idle reclaim.** *(Effectiveness.)*
- Reclaim needs CPU, network **and** memory below 20% at the 95th percentile for 7
  days. ~~Postgres alone reserves 3 of 12 GB, so the VM is probably safe.~~
  **Measured 2026-09-26: wrong.** `shared_buffers` is reserved, not used. Memory in
  use is **10.5% at p95**, so on this project's own figures the VM looks idle on all
  three measures. Numbers and next steps are in §6 Phase 0 results. Vaultwarden
  (under 100 MB) changes nothing either way.
- **Verify** the 7-day 95th-percentile memory from `metrics_samples`, and check whether
  the account is Pay-As-You-Go (reportedly exempt; see Phase 0 results for what the
  sources actually say).

### Low / efficiency cuts

- **L1.** Drop the planned metrics-collector change. The healthchecks `/alive` ping
  covers it, and it avoids extra work every minute on the drain VM. *Faster than the
  first plan.*
- **L2.** Replace the planned GitHub Action with GitHub Watch (see H3).
- **L3.** Replace "quarterly family exports" with the owner's automated daily off-site
  copy (C2), plus the owner's own yearly export.
- **L4.** Capacity: 6 users including the owner means **at most 5 family members**. The
  free plan allows only 3 ACL groups; this uses 1.
- **L5.** No SMTP, which keeps it at $0:
  - Invitations work without email, *to verify at deploy*: the invitee registers with the
    invited address.
  - There is no email 2FA or email verification; use TOTP or passkeys.
  - Gmail SMTP can be added later, but it is another secret.

### Alternatives considered

| Option | Security | Speed | Effort | Cost | Family sharing |
|---|---|---|---|---|---|
| **Vaultwarden on the VM (this plan)** | Good if C1–C4 are fixed and patches are applied promptly | Fast; sync payloads are KB | Medium, ongoing | $0 | Up to 5 family, unlimited collections |
| Bitwarden cloud Free, one account each | Best: audited, professionally run, no host to lose | Fast | None | $0 | **Only 1 other person** per account |
| Bitwarden Families | Best | Fast | None | $47.88/yr | 6 users. **Breaks the budget** |
| KeePassXC + Syncthing (already on VM) | Good; no server to attack | Offline-first | Low | $0 | Shared `.kdbx`; merge conflicts; weak iOS experience |

**Verdict: conditional GO.** Self-hosting is justified only by shared family collections
at $0. It beats Bitwarden cloud Free only if C1–C4 are fixed first and the owner accepts
patching within 72 hours. If the owner can't commit to that, Bitwarden cloud Free per
person, with a 2-person free org for owner and spouse, is the safer choice.

---

## 5. Go / no-go gates

Do not invite any family member until all of these hold:
1. restic is green again, with the repo under 85% of the tier. (C1) **Met
   2026-09-26** per `metrics_samples`; confirm the check is green on healthchecks.io.
2. The off-Oracle encrypted copy has run successfully at least once. (C2)
3. Every existing Tailscale flow has been previewed and allowed, and the next drain
   time is within noise of the baseline. (C3)
4. The emergency kit exists on paper, holding both restic passwords (A1, A4), and its
   tests print `PAPER OK`. (C4)
5. The Vaultwarden restore drill logs **PASS**.

## 6. Revised implementation plan

### Phase 0: prerequisites (one-off)
1. Shrink the restic repo (`docs/RUNBOOK.md:473-504`) and confirm a green nightly run.
2. Create the paper emergency kit, and update `ops/README.md:11`.
3. Pull 7 days of `metrics_samples` and record the RAM/CPU headroom and 95th-percentile
   memory. (M8)

#### Phase 0 results (2026-09-26)

All three steps are *One-off*: no change to any running service, so no speed effect.

**Step 1: restic. Already done.** Read from `metrics_samples` (`payload->'backup'`),
one row per day:

| Days (UTC) | Status | Last successful run | Snapshots | `repo_bytes` shown |
|---|---|---|---|---|
| 09-17 → 09-23 | failed | 09-17 04:14 | 6 | 291 MiB (stale, see below) |
| 09-24 | failed → **ok** | 09-24 20:44 | 8 | 291 → 310 MiB |
| 09-25 | ok | 09-25 03:03 | 9 | 310 MiB |
| 09-26 | ok | 09-26 03:00 | 10 | 312 MiB |

The guard refuses above 8,704 MiB, so every green run proves the repository was under
it at the time. The shrink ran on 09-24 but wasn't written down anywhere; this table
is the record. **Still to confirm by eye:** the backup check is green on
healthchecks.io.

*Found along the way (dashboard, not fixed):* `repo_bytes` comes from
`repo-stats.json`, which `immich-backup.sh` writes only on success. For all eight
failed days `/status` showed 291 MiB while the real repository was ~71 GB. It's a
one-line fix: have the guard write its fresh `size-check.json` over
`repo-stats.json` before refusing. *Neutral.* Left for the owner to approve.

**Step 2: paper kit. Template written, owner action pending.**
- `docs/EMERGENCY-KIT.md` is a printable template with blank lines only. It covers
  the restic password, vault recovery code, Telegram 2FA password, the Phase 1–2
  secrets, the accounts needed to rebuild, and the H6 "if I'm unavailable" note.
- It ends with a test that checks the handwritten restic password against the real
  repository. The test is read-only and takes no lock.
- `ops/README.md` and `infra/docs/WINDOWS-DEPLOY.md` now point to the kit, not to "a
  password manager". That resolves C4 in the docs.
- Gate 4 closes when the paper exists and its test prints `PAPER OK`.

**Step 3: headroom (M8).** 7 days, 9,954 one-minute samples, 2026-09-19 → 09-26:

| Measure | p50 | p95 | Max |
|---|---|---|---|
| Memory in use, (total − available) / total, of 11.65 GiB | 9.9% | **10.5%** | 13.0% |
| Memory available | | min 10.13 GiB | |
| load1 (2 cores) | 0.03 | **0.25** | load5 max 1.98 |
| Boot volume used | | | 28.7% (min 24.9%) |
| Swap used | | | 1,084 MiB |

The drain ran for 692 of the 9,954 minutes, about 7%.

- **Headroom for Vaultwarden is ample.** It needs ~256 MB with more than 10 GB
  available, and CPU is almost entirely idle outside drains. `mem_limit: 256m`
  stands.
- **Idle reclaim is a real risk to the whole VM, not only to Vaultwarden.** Memory
  (10.5%) and CPU (load 0.25 on 2 cores, roughly 12% at most) are both under
  Oracle's 20% line at p95. Network isn't collected, but at 7% drain duty cycle its
  p95 is surely low. On our own figures, all three idle conditions look met.
- Two things aren't known, so this stays a risk rather than a certainty:
  - how Oracle's own agent defines memory utilisation; page cache may count, where
    ours excludes it;
  - whether reclaim applies while the account is still in the Free Trial. The trial
    end date isn't recorded anywhere in this repo.
- **Owner check:**
  - OCI console → Compute → the instance → Metrics, 7-day view of CPU Utilization and
    Memory Utilization. If either p95 is under 20%, Oracle's own numbers agree.
  - Billing → note the trial end date and whether the account is Free Trial or
    Pay-As-You-Go.
- **What reclaim does (checked 2026-09-26):**
  - The Always Free docs page gives the three criteria. It does **not** say what
    "reclaimed" means, and it doesn't mention a Pay-As-You-Go exemption. The plan's
    "PAYG is exempt" was not backed by that page.
  - Oracle's Free Tier FAQ is the source for the rest, read through search summaries
    because the page returns 403 to a direct fetch. It says reclaim applies to
    "Always Free customers only". A stopped idle instance can be restarted "as long
    as the associated compute shape is available in your region".
  - That last condition matters here: A1 capacity in Mumbai is routinely "Out of
    host capacity" (`docs/BUILD-STATE.md`). **A stop could therefore become a long
    outage** for Immich, the drain and Vaultwarden alike.
- **Options, owner's decision** (see §8 Q5):
  - (a) Upgrade to Pay-As-You-Go. By the FAQ wording it's outside "Always Free
    customers", and it costs $0 while usage stays inside the Always Free limits. But
    it puts a card on file with no hard cap. The project refused Cloudflare R2 for
    exactly that reason (`docs/BUILD-STATE.md`). Run `/verify-free-tier` first.
  - (b) Accept the risk, and know that a restart may wait on capacity.
  - Not proposed: synthetic load to game the metric. It burns the CPU the drain uses
    (speed first) and works against Oracle's intent.

### Phase 1: deploy
- **`infra/vaultwarden/docker-compose.yml`**, compose name `vaultwarden`:
  - Image `vaultwarden/server:1.37.3@sha256:<multi-arch index digest>`. (M4)
  - `user: "1000:1000"`, `read_only: true`, tmpfs `/tmp`, `cap_drop: [ALL]`,
    `security_opt: [no-new-privileges:true]`. (H4)
  - `mem_limit: 256m`, `cpus` chosen by the M5 measurement, `restart: always`, the
    image's own healthcheck.
  - Ports: `127.0.0.1:8222:8080` only.
  - Volume: `/var/lib/vaultwarden:/data`, owned by 1000:1000.
- **Ansible role `roles/vaultwarden/`**, mirroring `roles/immich/`:
  - Template `vaultwarden.env.j2` renders to `/opt/vaultwarden/.env`, mode 0600,
    `no_log`.
  - A task asserts that `/var/lib/vaultwarden/config.json` does not exist. (M2)
  - Commit `infra/vaultwarden/.env.example` with variable names only.
- **Environment variables:**
  - `DOMAIN=https://<node>.<tailnet>.ts.net`, `ROCKET_PORT=8080`
  - `SIGNUPS_ALLOWED=false`, `INVITATIONS_ALLOWED=true`,
    `ORG_CREATION_USERS=<owner email>`
  - `ADMIN_TOKEN=<argon2 PHC from 'vaultwarden hash'>`. Remove it after the invites.
    (M2)
  - `PASSWORD_HINTS_ALLOWED=false`, `SHOW_PASSWORD_HINT=false`
  - `DISABLE_ICON_DOWNLOAD=true`. This removes the SSRF-via-icon advisory class and
    leaks no domains.
  - `SSO_ENABLED=false`, `LOG_LEVEL=warn`
  - `LOGIN_RATELIMIT_SECONDS=60`, `LOGIN_RATELIMIT_MAX_BURST=10` (M7)
  - `PUSH_ENABLED=true`, with `PUSH_INSTALLATION_ID` and `PUSH_INSTALLATION_KEY` from
    env only. (M1)
- **HTTPS:**
  - Optionally rename the node first. (M6)
  - Enable HTTPS certificates in the tailnet admin.
  - Run `tailscale serve --bg --https=443 http://127.0.0.1:8222`.
  - No ufw or OCI changes.
- **Tailscale policy (C3):**
  - Add a `hosts` alias for the VM; do not tag it.
  - Add an explicit owner rule for everything, and `group:family` → `vm:443` only.
  - Preview every existing flow, and apply with no drain running.
- **Organization:**
  - Create a "Family" org with collections.
  - Policies: master-password requirements, required 2FA (H1), Admin Password Reset
    **off** (H5).
  - Set up Emergency Access between the adults.
  - Every account switches to the Argon2id KDF.

### Phase 2: backup
- **New `ops/systemd/vaultwarden-dump.{service,timer}` at 02:30:**
  - `docker exec vaultwarden /vaultwarden backup` into `/data/backups/`; keep 7.
  - Afterwards, encrypt and upload the newest dump off-Oracle with rclone + restic or
    `age`. (C2)
  - Ping healthchecks.io.
- **`ops/backup/immich-backup.sh`:**
  - Add a dedicated `VAULTWARDEN_PATHS` variable: `backups/`, `attachments/`, `sends/`,
    `rsa_key*`.
  - Exclude the live `db.sqlite3*` and `icon_cache`.
  - Don't reuse `ARCHIVE_LEDGER_FILES`, which replaces its defaults.
  - Add the path to `ReadOnlyPaths` in `ops/systemd/immich-backup.service`.

### Phase 3: restore drill
**New `ops/backup/vaultwarden-restore-test.sh`**, modelled on `ops/backup/restore-test.sh`:
1. Restore into `mktemp`, from **both** restic and the off-Oracle copy.
2. Delete any `-wal` file.
3. Run `PRAGMA integrity_check`.
4. Compare the counts of users, ciphers and users_organizations against live.
5. Start a throwaway container on an isolated network and curl `/alive`.
6. Log to `ops/VAULTWARDEN-RESTORE-LOG.md`, and add it to the `restore-drill` skill.

### Phase 4: monitoring and updates
- **healthchecks.io:** add a check for the dump and one for alive + disk space (M3).
  That makes about 6 of the 20 free checks.
- **GitHub Watch** on dani-garcia/vaultwarden: Releases + Security alerts. (H3)
- **Update runbook:** add it to `docs/RUNBOOK.md`, with a 72-hour target for security
  releases.
- **No change to the metrics collector.** (L1)

### Phase 5: family onboarding
- Write a one-page guide covering:
  - installing Tailscale + Bitwarden;
  - Always-on VPN (Android) or On-Demand (iOS);
  - the server URL;
  - Argon2id;
  - 2FA;
  - emergency kit awareness.
- Acceptance test on every phone: save a new login over mobile data, and check it
  appears on another device within seconds.

### Phase 6: docs, ledger, gates
- **`README.md` ledger:**
  - Add a Vaultwarden row: $0, self-hosted.
  - Correct the Tailscale row to **6 users**, 1/3 ACL groups.
  - Update the healthchecks count.
  - Add a Bitwarden push relay row: free, metadata only.
  - Add the off-Oracle copy target.
- **`CLAUDE.md`:** change the `infra/` line to "DEPLOY Immich and Vaultwarden".
- **`docs/BUILD-STATE.md`:** add phase P9 with the §5 gates.
- **`vault/SECURITY-NOTES.md`** (or new `infra/vaultwarden/SECURITY-NOTES.md`): record
  the push metadata leak and the H5 decision.
- Run `/verify-free-tier` and `/security-review`, and both must come back clean.

### Critical files
- **New:**
  - `infra/vaultwarden/docker-compose.yml`
  - `infra/vaultwarden/.env.example`
  - `infra/ansible/roles/vaultwarden/`, mirroring `roles/immich/`
  - `ops/systemd/vaultwarden-dump.*`
  - `ops/backup/vaultwarden-restore-test.sh`
  - `ops/VAULTWARDEN-RESTORE-LOG.md`
- **Edited:**
  - `ops/backup/immich-backup.sh`, `ops/systemd/immich-backup.service`
  - `ops/README.md`, `README.md`, `CLAUDE.md`
  - `docs/BUILD-STATE.md`, `docs/RUNBOOK.md`
  - `.claude/skills/restore-drill/SKILL.md`

## 7. Verification
1. `docker buildx imagetools inspect` shows `linux/arm64` in the pinned index.
2. `tailscale serve status` shows 443, and the web vault loads on a phone (secure
   context).
3. Tailscale policy:
   - From a family device, `https://<node>.ts.net` works, while 22 and 2283 are
     unreachable.
   - The owner's Syncthing, SSH and Immich all still work.
4. Every Bitwarden client works (Android, iOS, browser extension, desktop), and push
   delivers a new item to the other devices within seconds.
5. `docker stats` shows under 100 MB idle. Login time is recorded at the chosen CPU cap.
6. **Speed-first proof:** the next drain is within noise of the 28-minute baseline.
7. The dump timer fires, the restic snapshot contains the Vaultwarden backups, the
   off-Oracle copy exists and is encrypted, and healthchecks is green.
8. The restore drill logs PASS from both backup sources.
9. `/security-review` and `/verify-free-tier` are clean.

## 8. Owner decisions

Answered 2026-09-26:

| # | Question | Decision |
|---|---|---|
| 1 | Admin Password Reset for elderly relatives | **OFF**, as recommended. Emergency Access instead (but see Q7) |
| 2 | Off-Oracle copy target | **Google Drive via rclone** (`drive.file` scope). The owner asked why; the reasons are in `docs/VAULTWARDEN-RUNBOOK.md` step 4 and the ledger |
| 3 | Rename `immich-mumbai` before HTTPS | **Keep the name** for now; may rename later (M6 accepted) |
| 4 | How many family members | **5 people including the owner**: 5 of Tailscale's 6 users; devices are unlimited |
| 6 | Fix the stale `repo_bytes` on `/status` | **Done**, `immich-backup.sh` + fixtures |

Still open:

5. *(Phase 0.)* Idle reclaim: after checking Oracle's own 7-day CPU and
   memory p95 and the trial end date, upgrade to Pay-As-You-Go (card on file), or
   accept the risk? This affects the whole VM, not just Vaultwarden.
7. *(Found while building.)* **SMTP for Emergency Access.** Without email, an
   Emergency Access request is never announced to the person whose vault it is,
   and is granted automatically when the wait ends (`src/api/core/emergency_access.rs`).
   Add free Gmail SMTP (`sudo vw-secrets smtp`, one more secret) before anyone sets
   up Emergency Access, or accept silent requests between adults who already trust
   each other? Details: `infra/vaultwarden/SECURITY-NOTES.md`.

## 9. Build status and where the build differs from this plan

**Built and tested in the repository, 2026-09-26** (branch `feat/vaultwarden`).
Nothing is deployed: every VM, browser and Tailscale step is the owner's, in
order, in `docs/VAULTWARDEN-RUNBOOK.md`.

| Phase | In the repo | Owner still to do |
|---|---|---|
| 0 | Kit template, `ops/README` fix, metrics findings, stale-size fix | Print + fill + test the kit; Q5 |
| 1 | `infra/vaultwarden/`, `roles/vaultwarden`, `vaultwarden.yml`, `vw-secrets`, `infra/tailscale/policy.hujson` | Runbook steps 1–3, 7, 8 |
| 2 | `ops/vaultwarden/vaultwarden-backup.sh` + timer; `immich-backup.sh` carries the dumps | Steps 4–6 |
| 3 | `ops/vaultwarden/vaultwarden-restore-test.sh`, `ops/VAULTWARDEN-RESTORE-LOG.md`, restore-drill skill | Step 10 → gate 5 |
| 4 | `vaultwarden-alive.sh` + timer, healthcheck docs, update runbook | Step 5; GitHub Watch; step 11 (M5 timing) |
| 5 | `docs/FAMILY-GUIDE.md`, onboarding steps | Step 9, after all gates |
| 6 | README ledger, CLAUDE.md, BUILD-STATE P9, SECURITY-NOTES, CI | — |

Tests added, all passing locally: `test-immich-backup.sh` 24, `test-vaultwarden-backup.sh`
32, `test-vaultwarden-alive.sh` 17, `test-vaultwarden-drill.sh` 8, `test-vw-secrets.sh`
32; shellcheck 0.9.0 clean; all YAML parses. The new immich-backup checks fail 8 of 24
against the previous script (negative control).

**Differences from §6, each deliberate:**

- **Separate playbook** `infra/ansible/vaultwarden.yml`. The main playbook restarts
  Immich's Postgres on every run; a password-manager change must not.
- **The admin page is off except for one invite** (the owner's). The source shows
  organisation invites work without SMTP, so the plan's "keep `ADMIN_TOKEN` until
  the invites are done" was unnecessary exposure. `vw-secrets admin-on/off`.
- **`IP_HEADER=X-Forwarded-For`**, not in the plan. Without it every request comes
  from the Docker gateway and the family shares one rate-limit bucket (M7).
  `tailscale serve` overwrites the header, so it cannot be forged.
- **`ICON_CACHE_TTL=0`** beside `DISABLE_ICON_DOWNLOAD=true`, as the 1.37.3 template
  requires.
- **Secrets in a separate `secrets.env`** written only by `vw-secrets` (prompted, never
  argv), so Ansible never sees or logs them. The deploy refuses a plaintext token.
- **Script locations:** `ops/vaultwarden/` (not `ops/backup/`), unit
  `vaultwarden-backup` (not `vaultwarden-dump`: it also makes the off-Oracle copy),
  runbook `docs/VAULTWARDEN-RUNBOOK.md` (not appended to the Telegram RUNBOOK),
  SECURITY-NOTES in `infra/vaultwarden/`.
- **The off-Oracle copy also carries the Insta360 ledger** (a few KB), closing the
  second half of `docs/REVIEW-2026-09-24.md` open item 5.
- **The drill uses `--network none`**, not an isolated bridge network, and checks
  `/alive` from inside the container: stricter isolation, same proof.
- **The alive check also fetches the HTTPS tailnet name**, so an expired or broken
  `tailscale serve` certificate alerts before the family notices.
- **The `backup` command writes `/data/db_<UTC>.sqlite3` via `VACUUM INTO`** (not into
  `/data/backups/`); the script integrity-checks it and moves it there.

## 10. Sources
- Vaultwarden: [repo](https://github.com/dani-garcia/vaultwarden) ·
  [releases](https://github.com/dani-garcia/vaultwarden/releases) ·
  [security advisories](https://github.com/dani-garcia/vaultwarden/security/advisories) ·
  [backup wiki](https://github.com/dani-garcia/vaultwarden/wiki/Backing-up-your-vault) ·
  [hardening guide](https://github.com/dani-garcia/vaultwarden/wiki/Hardening-Guide) ·
  [push notifications](https://github.com/dani-garcia/vaultwarden/wiki/Enabling-Mobile-Client-push-notification)
- [CVE-2026-26012](https://www.sentinelone.com/vulnerability-database/cve-2026-26012/) ·
  [GHSA-c5rv-q295-7w4g](https://github.com/dani-garcia/vaultwarden/security/advisories/GHSA-c5rv-q295-7w4g)
- Tailscale: [pricing](https://tailscale.com/pricing) ·
  [free plans](https://tailscale.com/docs/account/manage-plans/free-plans-discounts) ·
  [sharing](https://tailscale.com/kb/1084/sharing)
- [Bitwarden pricing](https://bitwarden.com/pricing/)
- Oracle: [Always Free resources and idle reclaim](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm) ·
  [Free Tier FAQ](https://www.oracle.com/cloud/free/faq/)
