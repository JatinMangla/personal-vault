# Vaultwarden — security notes

The decisions behind the family password manager, and the trade-offs taken
knowingly. Plan and adversarial review: `docs/VAULTWARDEN-PLAN.md`. Operations:
`docs/RUNBOOK.md` → "Vaultwarden". Facts below were checked against the
Vaultwarden 1.37.3 source on 2026-09-26 unless marked otherwise.

## What the server can and cannot see

Every item is encrypted and decrypted **in the Bitwarden apps**, with a key
derived from each person's master password. The server stores ciphertext, the
KDF settings, and each user's *protected* symmetric key. It cannot decrypt a
vault, and neither can anyone who steals the server or a backup, **except by
guessing a master password offline** (next section). No change to this
deployment may put plaintext on the server (CLAUDE.md rule 3).

## The realistic attack: offline guessing (plan H1)

A copy of `db.sqlite3` or any backup of it lets an attacker guess master
passwords at the speed of the client KDF. 2FA does not help against this.
Weak family passwords are the way this system actually gets broken. Defences:

| Defence | Where |
|---|---|
| Organisation policy: master password ≥ 14 characters, or a 4+ word passphrase | Web vault → Organisation → Policies (RUNBOOK) |
| Every account on **Argon2id**, not PBKDF2 | Each user: Account settings → Security → Keys (`docs/FAMILY-GUIDE.md`) |
| Backups encrypted twice over: restic to Oracle, restic again before Google Drive | `ops/vaultwarden/vaultwarden-backup.sh` |
| Organisation policy: two-step login required (online attacks) | Policies |
| Login rate limit 10 per burst, 1 per 60 s, **per client IP** | `vaultwarden.env.j2` |

**The per-IP part needed a fix the plan missed.** Behind `tailscale serve`,
every request reaches the container from the Docker gateway, so without a
client-IP header the whole family would share one rate-limit bucket, and one
attacker could lock everyone out. `tailscale serve` *sets* (overwrites)
`X-Forwarded-For` to the caller's tailnet address (`ipn/ipnlocal/serve.go`,
`addProxyForwardedHeaders`), so `IP_HEADER=X-Forwarded-For` is both correct and
unspoofable by a client. `IP_HEADER_TRUSTED_PROXIES=local` accepts it only from
non-global addresses.

## Reachability

- Tailnet only. `tailscale serve` on 443 of the VM's `*.ts.net` name, proxying
  to `127.0.0.1:8222`. No public listener, no ufw or OCI change.
- Family devices reach **only** `vm:443` (`infra/tailscale/policy.hujson`).
  A compromised family phone is still inside the tailnet, hence the rate
  limits above.
- The `*.ts.net` certificate is published in Certificate Transparency logs,
  which reveals the hostname `immich-mumbai` (plan M6). Accepted by the owner
  2026-09-26: the machine stays unreachable from the internet. May be renamed
  later.

## Container hardening (plan H4)

`user: 1000:1000`, `read_only: true` with a tmpfs `/tmp`, `cap_drop: [ALL]`,
`no-new-privileges`, `mem_limit: 256m`, `cpus: 1.0`, `pids_limit: 256`. The
image is pinned to the **multi-arch index** digest (plan M4), and the role
checks on the host that the running image is arm64.

## The admin page is OFF by default (plan M2, stronger than planned)

The plan kept `ADMIN_TOKEN` until all the family invites were done. The source
shows it is needed for **one** invite only, the owner's own. With no SMTP
configured, an **organisation invite** records an invitation
(`src/api/core/organizations.rs`), so an invited address can register even
with `SIGNUPS_ALLOWED=false`, and joins as *Accepted* for the owner to confirm.
Only the owner's first account, before any organisation exists, needs the
admin page's *Invite user* (`src/api/admin.rs`, same no-SMTP path).

So `/admin` is off except for those few minutes (`docs/VAULTWARDEN-RUNBOOK.md`
step 7) and for rare tasks later (delete a user, clear a lost 2FA). `sudo
vw-secrets admin-on` stores only an Argon2id hash; `admin-off` removes it, and
`vw-secrets show` warns while it is on.

**Never press Save on `/admin`.** It writes `/data/config.json`, which silently
overrides the Ansible-managed settings and stores the token in plaintext. The
deploy refuses to run while that file exists, and the 5-minute alive check
alerts on it.

## Admin Password Reset: OFF (plan H5, owner decision 2026-09-26)

The organisation policy that lets an admin reset a member's master password
is **off**. It would weaken end-to-end encryption for members, and a
compromise of the owner's account would become a compromise of every family
account. Emergency Access is the alternative. Do not turn the policy on without
recording it as a rule-3 trade-off in `docs/BUILD-STATE.md`.

## Emergency Access without email: requests are SILENT (found 2026-09-26)

Emergency Access lets a trusted adult request access to your vault; you have a
waiting period to reject it. **The rejection window only protects you if you
learn about the request.** In 1.37.3 the "recovery initiated" notice, the daily
reminder and the "timed out, access granted" notice are all emails
(`src/api/core/emergency_access.rs`, `CONFIG.mail_enabled()` guards each). With
no SMTP, none is sent, and the request is **approved automatically** when the
wait ends.

Options, **owner decision pending** (plan §8):

- **Add Gmail SMTP** (`sudo vw-secrets smtp`): free, a Gmail App Password
  stored only in `secrets.env`. It also enables login and 2FA notices.
  Recommended before anyone sets up Emergency Access.
- **Stay without SMTP**: set Emergency Access only between adults who trust
  each other with the vault anyway, with the longest wait, and check
  Account → Emergency access → *Trusted emergency contacts* now and then.

## Push relay metadata (plan M1)

Mobile push goes through Bitwarden's relay (`push.bitwarden.com`), chosen by
the owner for speed. The first plan said only device tokens reach it. That was
wrong: the relay also receives **user, device and item UUIDs and change
timestamps**. It never receives names, URLs or contents, which stay
encrypted. Recorded in the budget ledger. Removable with `sudo vw-secrets
push-off`; clients then sync on open and every few minutes instead.

## No outbound fetches

`DISABLE_ICON_DOWNLOAD=true` with `ICON_CACHE_TTL=0`: the server never
fetches website icons. That removes the icon-endpoint SSRF class (for example
GHSA-72vh-x5jq-m82g) and never reveals which sites the family uses. The only
outbound connections are the push relay and, if configured, Gmail SMTP.

## Where every secret lives

| Secret | Location | Also on the paper kit |
|---|---|---|
| Push installation key | `/opt/vaultwarden/secrets.env` (0600) | no — re-issue at bitwarden.com/host |
| Admin token (only while on) | `secrets.env`, Argon2id hash only | the password, while on (C1) |
| Gmail App Password (optional) | `secrets.env` | no — revoke and re-issue in Google |
| restic password, Oracle copy | `/root/.restic-pass` | **yes (A1)** |
| restic password, off-Oracle copy | `/root/.restic-offsite-pass` | **yes (A4)** |
| Google Drive token (`drive.file` scope) | `/var/lib/personal-vault/rclone/rclone.conf` (0600) | no — re-authorise |
| Each person's master password | their head | their own paper (`docs/FAMILY-GUIDE.md`) |

None of these is ever the only copy of what it protects, and none lives only in
Vaultwarden (plan C4).

`secrets.env` reaches the container as environment variables, so anyone who can
run `docker inspect vaultwarden` can read them. That is root and the `docker`
group, which already includes the `immich` service account
(`roles/docker/tasks/main.yml`). Docker-group membership is root-equivalent
anyway (it can mount `/opt/vaultwarden` into any container), so this adds no
new exposure. Keep the group that small. The `drive.file` scope means the VM's Google token can
see only files rclone itself created, not the rest of the owner's Drive.

## Patching (plan H3)

Target: **security releases within 72 hours.** 1.37.0 alone fixed 8 advisories.
Notifications: GitHub → dani-garcia/vaultwarden → Watch → Custom → Releases
and Security alerts. Procedure: `docs/RUNBOOK.md` → "Vaultwarden: security
updates". Being tailnet-only buys time; it is not a reason to skip a patch.
