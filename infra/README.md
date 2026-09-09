# `infra/` — Component A: the media engine

**Immich is deployed here, never rebuilt.**

Immich is a mature AGPL-3.0 project that already implements everything this
project needs from a photo system: CLIP semantic search, InsightFace face
recognition, background mobile auto-backup, albums, sharing and EXIF handling.
Rebuilding any of that would produce a worse result after months of work.

Nothing in this directory is application code. It is infrastructure automation:
a pinned compose file, four Ansible roles, Postgres tuning, and the console
steps that cannot be scripted.

## Why not Vercel

Immich is a stateful Docker application needing PostgreSQL with pgvector, a
Valkey queue, a persistent filesystem and long-running ML workers. Vercel Hobby
functions cap at 60 seconds with no persistent disk and no GPU. This is a
category mismatch, not a tuning problem.

## Layout

```
infra/
├── docker-compose.yml       Pinned Immich stack. Never :latest.
├── .env.example             Variable names only.
├── ansible/
│   ├── playbook.yml         Entry point; roles run in a deliberate order
│   ├── ansible.cfg
│   ├── requirements.yml     Galaxy collections
│   ├── inventory.example.ini
│   └── roles/
│       ├── hardening/       ufw, fail2ban, sshd, unattended-upgrades, sysctl
│       ├── docker/          Docker Engine from Docker's own apt repo
│       ├── tailscale/       The only way in
│       └── immich/          Block volume, compose project, health wait
├── postgres/
│   └── tuning.conf          Tuned for 12 GB RAM and pgvector
└── docs/
    ├── oracle-setup.md      Manual console steps — read before clicking
    ├── volume-layout.md     Which volume holds what, and why
    └── immich-settings.md   Mandatory post-install configuration
```

## Order of operations

1. **`docs/oracle-setup.md`** — create the account (home region is
   irreversible), set the $1 budget alert, provision 2 OCPU / 12 GB, attach the
   150 GB block volume at **0 VPU**.
2. **Run the playbook** against the public IP. This installs and hardens
   everything, including Tailscale.
3. **Delete every ingress rule** in the OCI security list.
4. **Verify** with `nmap -Pn -p- <public-ip>` from outside — expect zero open
   ports. This is the P1 acceptance criterion.
5. **Re-run the playbook** against the Tailscale address to confirm it still
   applies cleanly with no public path.
6. **`docs/immich-settings.md`** — transcoding policy, HEIC handling, automatic
   database backups, and the read-only API key for the metrics collector.

## Running the playbook

```bash
cd infra/ansible
cp inventory.example.ini inventory.ini      # then edit
ansible-galaxy collection install -r requirements.yml

ansible-playbook -i inventory.ini playbook.yml \
  --extra-vars "tailscale_auth_key=$TS_AUTHKEY" \
  --extra-vars "immich_db_password=$(openssl rand -base64 32)"
```

Secrets are passed at run time and never stored in the repository. Both
variables are deliberately left without defaults so a missing one fails loudly
rather than silently using a shared value.

Useful tags: `--tags hardening`, `--tags immich`, `--tags tailscale`.

Every task is idempotent. Re-running the playbook is expected and safe; a second
run should report no changes.

## Non-negotiables

These are enforced by the code in this directory and by review. Breaking any of
them either costs money or costs data.

| Rule | Consequence of breaking it |
|---|---|
| No inbound ports. Tailscale only. | A publicly reachable photo archive |
| Block volume stays at **0 VPU** | ~$3/month — 36× the annual budget |
| Never provision 4 OCPU / 24 GB | Instance terminated automatically |
| Every image tag pinned; no Watchtower | Breaking migrations corrupt the library |
| Immich binds to the Tailscale IP, not `0.0.0.0` | Firewall becomes the only defence |
| Postgres on the boot volume, media on the block volume | Wrong I/O profile for both |

## Verifying the security posture

```bash
# From outside — the real test
nmap -Pn -p- <public-ip>

# On the box
sudo ufw status verbose            # deny incoming; allow on tailscale0
ss -tlnp                           # nothing bound to 0.0.0.0 except sshd
sudo fail2ban-client status sshd
docker compose ps                  # four services, all healthy
```

The playbook's own post-task reports anything listening on a non-loopback,
non-Tailscale address, so a regression surfaces on the next run.
