# Runbook — Vaultwarden, the family password manager

Operations for `docs/VAULTWARDEN-PLAN.md`. Why each setting exists:
`infra/vaultwarden/SECURITY-NOTES.md`. For family members: `docs/FAMILY-GUIDE.md`.

Every command is labelled with where it runs:
**[VM]** over SSH from Termux · **[PHONE]** in Termux · **[BROWSER]** on the phone.
Nothing here needs a laptop.

Speed: every step is *One-off* or *Neutral*. The only thing that could touch
the drain is the Tailscale policy (step 8), which is why it has its own
procedure and a before/after drain measurement.

---

## First deployment, in order

Do not invite any family member until the **go/no-go gates** at the end hold.

### 1. [BROWSER] Tailscale: MagicDNS and HTTPS certificates

<https://login.tailscale.com/admin/dns> → MagicDNS **on**, then *HTTPS
Certificates* → **Enable**. The certificate names this machine in public
Certificate Transparency logs (`immich-mumbai`); accepted, see SECURITY-NOTES.

### 2. [VM] Get this code onto the VM and deploy

The VM deploys from its clone at `~/personal-vault`, so the branch must be on
GitHub (merged to `main`) first.

```bash
cd ~/personal-vault && git pull
cd infra/ansible
ansible-playbook -i inventory.ini vaultwarden.yml -e vaultwarden_owner_email=YOU@example.com
```

`YOU@example.com` is the email you will log in to Vaultwarden with. Later runs
need no `-e`. The play touches nothing of Immich. It ends by fetching
`https://<tailscale name>.<tailnet>.ts.net/alive` through `tailscale serve`, so a
green run means the whole path works. It fails, with the reason, if MagicDNS or
HTTPS is off, if the node is tagged, or if `/admin` ever saved a `config.json`.

### 3. [BROWSER] + [VM] Push notifications (new items reach phones in seconds)

1. [BROWSER] <https://bitwarden.com/host> → your email, data region **United
   States** → it shows an *Installation ID* and *Installation Key*.
2. [VM] `sudo vw-secrets push` → paste the ID, then the key (hidden).

### 4. [VM] + [PHONE] The encrypted off-Oracle copy (Google Drive)

Plan C2. restic encrypts on the VM; Google only ever holds ciphertext. The
token can see only files rclone creates (`drive.file`), not the rest of your
Drive.

```bash
# [VM] 1. start the Google Drive remote
sudo install -d -m 0700 /var/lib/personal-vault/rclone
sudo rclone config --config /var/lib/personal-vault/rclone/rclone.conf
```

Answer: `n` (new remote) → name **`gdrive`** → storage **`drive`** →
client_id and client_secret **blank** → scope **`drive.file`** ("Access to
files created by rclone only") → service_account_file blank → advanced config
`n` → **"Use web browser to automatically authenticate?" `n`**. It then prints
a line starting `rclone authorize "drive" "eyJ...`. Copy that whole line.

```bash
# [PHONE] 2. authorise in Termux (a browser opens; pick your Google account)
pkg install rclone
rclone authorize "drive" "eyJzY29wZSI6ImRyaXZlLmZpbGUifQ=="   # the line the VM printed
```

Termux prints a token `{...}`. Paste it at the VM's `config_token>` prompt,
answer `n` to "shared drive", then `y` and `q`.

```bash
# [VM] 3. lock it down, and make the off-Oracle restic password
sudo chmod 0600 /var/lib/personal-vault/rclone/rclone.conf
sudo sh -c 'umask 077; openssl rand -base64 33 > /root/.restic-offsite-pass'
sudo cat /root/.restic-offsite-pass    # write it on the emergency kit as A4, then: clear
```

4. [VM] `sudo nano /etc/personal-vault/ops.env` and add:

```bash
OFFSITE_REPOSITORY=rclone:gdrive:personal-vault-offsite
```

### 5. [BROWSER] + [VM] Two new healthchecks

At <https://healthchecks.io>, create (details in
`ops/monitoring/healthcheck-setup.md`):

| Check | Schedule | Grace |
|---|---|---|
| `vaultwarden-backup` | Cron `30 2 * * *`, timezone **UTC** | 1 hour |
| `vaultwarden-alive` | Period 5 minutes | 10 minutes |

Add their UUIDs (the UUID only, not the URL) to `/etc/personal-vault/ops.env`:

```bash
HEALTHCHECK_VW_BACKUP_UUID=
HEALTHCHECK_VW_ALIVE_UUID=
```

### 6. [VM] Install the timers, run the first backup

```bash
sudo rsync -a ~/personal-vault/ops/ /opt/personal-vault/ops/
sudo chmod +x /opt/personal-vault/ops/*/*.sh
sudo cp ~/personal-vault/ops/systemd/vaultwarden-* ~/personal-vault/ops/systemd/immich-backup.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vaultwarden-backup.timer vaultwarden-alive.timer
sudo systemctl start vaultwarden-backup.service; journalctl -u vaultwarden-backup -n 15 --no-pager
```

Want: `vaultwarden backup completed: local dump + off-Oracle copy`, and both
new checks green. `immich-backup.service` is copied again because it now also
reads `/var/lib/vaultwarden`. From the next 03:00 run, the Oracle snapshot
carries the vault's dumps too.

Check the off-Oracle password on the paper opens the repository (same test as
A1 in `docs/EMERGENCY-KIT.md`, with `--password-file` pointed at what you type
and `RESTIC_REPOSITORY=rclone:gdrive:personal-vault-offsite`
`RCLONE_CONFIG=/var/lib/personal-vault/rclone/rclone.conf`).

### 7. [VM] + [BROWSER] Your own account and the Family organisation

Sign-ups are off for everyone, you included, so the admin page is needed
exactly once, to invite yourself:

```bash
# [VM]
sudo vw-secrets admin-on      # choose a 20+ character admin password
```

1. [BROWSER] `https://mangla.tail668f04.ts.net/admin` (the address the playbook printed) → admin password →
   *Users* → **Invite user** → your email. **Do not press Save anywhere.**
2. [VM] `sudo vw-secrets admin-off` — straight away.
3. [BROWSER] `https://mangla.tail668f04.ts.net` → *Create account* with
   that email. Master password: 4+ random words or 14+ characters, and write it
   on your own paper (it is **not** on the shared kit).
4. *Settings → Security → Keys* → KDF algorithm **Argon2id** (defaults) → save.
   You are logged out; log back in.
5. *Settings → Security → Two-step login* → **Authenticator app** (and save the
   recovery code on paper).
6. *New organisation* → name **Family** (allowed only for your email).
7. Organisation → *Settings → Policies*:
   - **Master password requirements**: minimum length 14, minimum complexity
     score *Strong*.
   - **Require two-step login**: on.
   - **Account recovery administration** (admin password reset): **leave OFF**.
     Owner decision 2026-09-26; see SECURITY-NOTES.
8. Organisation → *Collections* → e.g. **Shared** (household logins), plus any
   others you want.

### 8. [BROWSER] The Tailscale access policy for the family (plan C3)

This is the one step that can affect the drain and Immich, because it replaces
today's allow-everything policy for **every** connection.

1. **No drain running.** `/status` shows the archive idle, or `[VM] tg-archive status`.
2. <https://login.tailscale.com/admin/acls> → copy the current policy into a
   note, as the way back.
3. *Users* → **Invite users** → each family member's email, role **Member**.
   Wait until they have joined (Part 1 of `docs/FAMILY-GUIDE.md`).
4. Paste `infra/tailscale/policy.hujson`, add each family login to
   `group:family`, fill in and uncomment the two `tests` blocks with your login
   and one family login.
5. **Preview rules** for your own user: the VM must show 22, 443, 2283 and
   22000 allowed. Then for a family member: only `vm:443`.
6. **Save** (the tests run first and block a bad policy).
7. Straight after, check your own paths still work:
   - [PHONE] Immich app opens the library.
   - [PHONE] Syncthing shows the VM *Connected*.
   - [PHONE] `ssh` to the VM works.
8. **Speed-first proof:** the next drain's total time must be within noise of
   the 28-minute baseline for 6.6 GB (upload 9 / fetch 12.5 / hash+verify 4.5 /
   idle 1.8 min, `docs/REVIEW-2026-09-24.md`). If it is slower, paste back the
   saved policy and investigate.

### 9. Family onboarding

Give each person `docs/FAMILY-GUIDE.md`, printed, with the vault address
filled in. Then, per person:

1. [BROWSER] Organisation → *Members* → **Invite member** → their email, role
   *User*, the collections they should see. Without email configured the
   invite is silent: tell them it is there.
2. They follow the guide: create the account, Argon2id, two-step login.
3. Organisation → *Members* → **Confirm** them. (The two-step policy blocks
   confirming anyone without it, which is the point.)
4. **Acceptance test on their phone:** mobile data on, Wi-Fi off → save a new
   login → it appears on another of their devices within seconds.

**Emergency Access:** see SECURITY-NOTES first. Without SMTP a request is
silent and is granted automatically after the wait. Decide on
`sudo vw-secrets smtp` before setting any up.

### 10. [VM] The restore drill (gate 5)

After the first 03:00 run that includes the vault (check with
`journalctl -t immich-backup --since today | grep vaultwarden`):

```bash
sudo /opt/personal-vault/ops/vaultwarden/vaultwarden-restore-test.sh
```

It restores the newest dump from **both** copies, checks integrity, compares
bytes and counts, and serves each one from a throwaway container with no
network. Want `PASS`. `PASS (ORACLE-ONLY)` means the off-Oracle copy is not
configured yet. Logged in `ops/VAULTWARDEN-RESTORE-LOG.md`; commit that file.
Re-run quarterly, and after every Vaultwarden update.

### 11. Login timing at the CPU cap (plan M5)

Logins do 600,000 PBKDF2 rounds on the server; unlocking does not touch the
server. With a stopwatch, log in on the web vault 3 times at the shipped
`cpus: 1.0`. If every login is under about 1 s, try `0.5`:

```bash
# [VM] temporary, reverted by the next deploy
cd /opt/vaultwarden && sudo sed -i 's/^    cpus: 1.0$/    cpus: 0.5/' docker-compose.yml && sudo docker compose up -d
```

Keep the lowest cap that stays under ~1 s, put it in
`infra/vaultwarden/docker-compose.yml`, and record both timings in
`docs/BUILD-STATE.md`.

### Go / no-go gates (plan §5)

Invite family only when all hold:

1. restic green, repository under 85% of the tier — **met 2026-09-26**.
2. The off-Oracle copy has run once (step 6, `vaultwarden-backup` green).
3. Tailscale policy applied, owner paths checked, next drain within noise of
   the baseline (step 8).
4. The paper emergency kit exists and its tests print `PAPER OK` (A1 and A4).
5. The restore drill logged `PASS` (step 10).

---

## Security updates (72-hour target for security releases)

Watch notifications: GitHub → dani-garcia/vaultwarden → **Watch → Custom →
Releases + Security alerts**. A release note mentioning a GHSA or CVE starts
the 72-hour clock.

1. Read the release notes. Take a fresh dump first:
   `[VM] sudo systemctl start vaultwarden-backup.service` (migrations are one-way).
2. Find the new **multi-arch index** digest and check it has arm64:

   ```bash
   # [VM]
   docker buildx imagetools inspect vaultwarden/server:X.Y.Z | head -20
   ```

   Want `Digest: sha256:...` at the top (the index) and `Platform: linux/arm64`
   in the list. Never pin a per-platform digest.
3. Edit the `image:` line in `infra/vaultwarden/docker-compose.yml` to
   `docker.io/vaultwarden/server:X.Y.Z@sha256:<index digest>`, commit, push.
4. [VM] `cd ~/personal-vault && git pull && cd infra/ansible && ansible-playbook -i inventory.ini vaultwarden.yml`
5. Check: the play is green, and the restore drill passes on the new image.

---

## Disaster: restore the vault from a backup

For a rebuilt VM, or a database that will not start. The drill proves this path
quarterly; the steps are the same by hand.

```bash
# [VM] 1. stop the server
cd /opt/vaultwarden && sudo docker compose down

# 2. restore the Vaultwarden paths from either copy into a scratch directory
#    Oracle:     the r() helper in docs/RUNBOOK.md, then:
#                r restore latest --target /tmp/vw --include /var/lib/vaultwarden
#    off-Oracle: with RESTIC_REPOSITORY=rclone:gdrive:personal-vault-offsite,
#                RESTIC_PASSWORD_FILE=/root/.restic-offsite-pass and
#                RCLONE_CONFIG=/var/lib/personal-vault/rclone/rclone.conf
ls /tmp/vw/var/lib/vaultwarden/backups/     # newest db_*.sqlite3 by name

# 3. put it in place: the dump becomes db.sqlite3; any -wal/-shm must go
sudo cp /tmp/vw/var/lib/vaultwarden/backups/db_YYYYMMDD_HHMMSS.sqlite3 /var/lib/vaultwarden/db.sqlite3
sudo rm -f /var/lib/vaultwarden/db.sqlite3-wal /var/lib/vaultwarden/db.sqlite3-shm
sudo cp -a /tmp/vw/var/lib/vaultwarden/{attachments,sends,rsa_key.pem} /var/lib/vaultwarden/ 2>/dev/null
sudo chown -R 1000:1000 /var/lib/vaultwarden && sudo chown root:root /var/lib/vaultwarden/backups
sudo docker compose up -d && curl -fsS http://127.0.0.1:8222/alive
```

Without `rsa_key.pem`, every device must log in again; with it, they carry on.
Anything saved after that dump is not in it; phones that still hold newer items
in their offline cache can re-save them.

---

## When an alert fires

| `vaultwarden-alive` says | Do |
|---|---|
| `config.json exists` | Someone pressed Save on `/admin`. Note what it changed, move that into `roles/vaultwarden`, then `sudo rm /var/lib/vaultwarden/config.json` and re-run the playbook |
| `only N% free` | The boot volume. `df -h /`, then `docker system df`; the last time this happened it was the drain (`docs/HARD-WON.md`) |
| `https://.../alive failed` | `tailscale serve status`; `sudo tailscale serve --bg --https=443 http://127.0.0.1:8222` |
| `loopback /alive did not answer` | `docker logs --tail 40 vaultwarden`; `cd /opt/vaultwarden && sudo docker compose up -d` |

| `vaultwarden-backup` says | Do |
|---|---|
| `OFFSITE_REPOSITORY is not set` | Step 4 is not done; the local dump was still made |
| `cannot read .../rclone.conf` or rclone auth errors | Re-run step 4's authorisation; Google can revoke tokens after long disuse or a password change |
| `integrity check failed` | The dump was left beside `db.sqlite3` for inspection and was not rotated in. Run the drill; investigate before the next night |

---

## Routine checks

```bash
# [VM]
sudo vw-secrets show                                # which secrets are set; warns if /admin is on
systemctl list-timers 'vaultwarden-*'
journalctl -u vaultwarden-backup -n 5 --no-pager
sudo ls -l /var/lib/vaultwarden/backups/            # 7 newest dumps
docker stats --no-stream vaultwarden                # idle well under 100 MB
```
