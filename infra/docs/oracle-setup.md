# Oracle Cloud setup — manual console steps

These steps cannot be scripted without an existing tenancy, so they are done by
hand once and recorded here. Everything after them is Ansible's job.

Read this whole page before clicking anything. Two of the choices below are
**irreversible** and one of them silently destroys the budget.

---

## 1. Create the Always Free account

**Home region must be `ap-mumbai-1` or `ap-hyderabad-1`.**

This is the single most consequential click in the entire project. Always Free
resources are locked to the home region and the home region **cannot be changed
after the account is created**. Getting it wrong means starting over with a new
account and a different email address.

Mumbai is the better of the two from Pune — roughly 150 km, which is why this
design uses a direct Tailscale tunnel rather than a CDN.

During signup a credit card is required for identity verification. Always Free
resources do not consume it. Do **not** upgrade to Pay As You Go: an upgraded
tenancy will happily bill you for anything that drifts outside the free
allowance, which removes the safety property this whole design relies on.

## 2. Set a budget alert before provisioning anything

Billing → Cost Management → Budgets.

- Scope: the root compartment
- Amount: **1 USD**
- Alert rule: trigger at **100% of forecast** *and* at 100% of actual spend
- Email: an address you actually read

Do this **first**, not last. A budget alert set after a misconfiguration has
already started billing tells you about money you have already spent.

## 3. Provision the compute instance

Compute → Instances → Create Instance.

| Setting | Value | Why |
|---|---|---|
| Shape | `VM.Standard.A1.Flex` | The Ampere ARM shape the free tier covers |
| OCPUs | **2** | See the entitlement warning below |
| Memory | **12 GB** | Same |
| Image | Ubuntu 24.04 **aarch64** minimal | Every pinned image targets arm64 |
| Boot volume | **50 GB**, Balanced (default) | OS, Docker, Postgres data |
| SSH key | Paste your **public** key | Password auth is disabled by Ansible |

**Do not provision 4 OCPU / 24 GB.** Oracle halved the Always Free Ampere
allowance from 4/24 to 2/12, effective 15 June 2026, with enforcement from
18 August 2026. Instances exceeding the entitlement are **terminated
automatically**. A terminated instance takes the boot volume with it.

**Expect "Out of host capacity."** ARM capacity in Indian regions is frequently
exhausted. This is normal and is not a misconfiguration — retry over hours or
days. Retrying in a loop from a script is the usual approach; be aware that
aggressive retries can get an account flagged, so keep the interval sane
(a few minutes, not a few seconds).

Generate the SSH key first if you do not have one:

```bash
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/oracle_immich_ed25519 -C "immich-mumbai"
```

## 4. Create and attach the block volume

Storage → Block Volumes → Create Block Volume.

| Setting | Value |
|---|---|
| Size | **150 GB** |
| Performance | **Lower Cost (0 VPU)** |
| Availability domain | Must match the instance |

**Do not raise the VPU tier on either volume.** VPUs bill separately from
capacity at roughly $0.0017 per VPU per GB-month. Moving 150 GB from Lower Cost
to Balanced costs about **$3/month** — thirty-six times the entire annual
budget. Lower Cost is also the *correct* tier here on the merits: Oracle
recommends it for throughput-intensive workloads with large sequential I/O,
which is exactly what streaming video is.

The free tier covers 200 GB of block storage in total. 50 GB boot + 150 GB
block uses all of it, so there is no headroom for a third volume.

Attach it to the instance (Instance → Attached Block Volumes → Attach), choosing
**iSCSI** and **read/write**. The console then shows the iSCSI commands to run
on the VM. Run them, then confirm the device exists:

```bash
ls -l /dev/oracleoci/oraclevdb
```

The Ansible role expects that path and will fail with guidance if it is absent.
It formats the volume **only** when `blkid` reports no filesystem, so re-running
the playbook can never reformat a volume that already holds media.

## 5. Lock down the security list

Networking → Virtual Cloud Networks → your VCN → Security Lists.

**Remove every ingress rule, including the default SSH rule on 22/tcp.**

Tailscale needs no inbound rule whatsoever: it makes outbound connections and
negotiates a direct peer-to-peer WireGuard tunnel. Leave egress as allow-all.

Do this **after** the first Ansible run, since that run connects over the public
IP to install Tailscale. The sequence is:

1. Provision, note the public IP
2. Run the playbook against the public IP (installs Tailscale, hardens SSH)
3. Confirm you can reach the box over Tailscale
4. **Then** delete the ingress rules
5. Re-run the playbook against the Tailscale address to confirm it still works

Verify from outside afterwards — this is the P1 acceptance criterion:

```bash
nmap -Pn -p- <public-ip>     # expect: zero open ports
```

## 6. Note on the boot volume backup policy

Oracle's automatic boot volume backup policies consume block storage that counts
against the 200 GB free allowance. Leave the boot volume backup policy set to
**None**. Durability comes from restic to Gozunga (see `ops/`), not from Oracle
snapshots, and an accidental snapshot policy is a quiet way to exceed the free
tier.

---

## After the console work

```bash
cd infra/ansible
cp inventory.example.ini inventory.ini   # then edit it
ansible-galaxy collection install -r requirements.yml

ansible-playbook -i inventory.ini playbook.yml \
  --extra-vars "tailscale_auth_key=$TS_AUTHKEY" \
  --extra-vars "immich_db_password=$(openssl rand -base64 32)"
```

> **On a RE-RUN, reuse the existing password — do not generate a new one.**
> Postgres only honours `POSTGRES_PASSWORD` when it initialises an empty data
> directory; on an existing one it is ignored. A fresh password on a second run
> therefore leaves Immich crash-looping with
> `password authentication failed for user "postgres"`. Read the current value
> back instead:
>
> ```bash
> sudo sed -n 's/^DB_PASSWORD=//p' /opt/immich/.env
> ```
>
> `infra/setup-on-vm.sh` does this automatically.


Record the generated database password in your password manager. It never leaves
the VM and is not needed to restore a backup — restic captures Immich's SQL dump
rather than the raw Postgres data directory — but you will want it if you ever
need to open a `psql` session by hand.

Then follow `immich-settings.md` for the mandatory post-install settings.
