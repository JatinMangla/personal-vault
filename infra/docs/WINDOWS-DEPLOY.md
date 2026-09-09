# Deploying from Windows — step-by-step

**Read this instead of running Ansible from your laptop.**

Ansible does not run on Windows. It has no supported Windows control node, and
this machine has no WSL (and being corporate-managed, installing WSL may need IT
approval).

The workaround is simple and is what this guide does: **run Ansible on the VM
itself.** You SSH in with the OpenSSH client that Windows already ships, pull the
repository down, and let the VM configure itself locally. Nothing extra is
installed on your laptop.

Every command below is typed into **PowerShell** unless it says otherwise.

---

## Before you start

You need, in this order:

1. An Oracle Cloud account with the home region set to **Mumbai** or
   **Hyderabad** (this is permanent — see `oracle-setup.md`)
2. A **$1 budget alert** configured *before* you provision anything
3. An SSH key pair (Step 1 below)
4. A Tailscale account (free) — sign up at tailscale.com

Set aside a couple of evenings. The Oracle capacity wait is the slow part and
you cannot rush it.

---

## The short version

Steps 4 through 8 below are automated. Once you can SSH into the VM:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/JatinMangla/personal-vault.git
bash ~/personal-vault/infra/setup-on-vm.sh
```

It checks the machine is the right shape, installs Ansible, runs the playbook,
installs the backup and metrics automation, and prints exactly what to do next.
It asks for one thing: your Tailscale auth key. Safe to re-run if anything
fails partway.

The manual walkthrough below remains accurate if you would rather do it in
steps, or if the script stops and you need to understand where.

---

## Step 1 — Create an SSH key (on Windows)

```powershell
ssh-keygen -t ed25519 -a 100 -f $env:USERPROFILE\.ssh\oracle_immich -C "immich-mumbai"
```

Press Enter twice to skip the passphrase, or set one if you prefer (you will
type it on each connection).

This makes two files. Guard the difference:

| File | What it is |
|---|---|
| `oracle_immich` | **PRIVATE.** Never share, never upload, never paste anywhere. |
| `oracle_immich.pub` | Public. This is the one you paste into Oracle. |

Show the public key to copy it:

```powershell
Get-Content $env:USERPROFILE\.ssh\oracle_immich.pub
```

## Step 2 — Provision the VM

Follow `oracle-setup.md` for the console steps. When it asks for an SSH key,
paste the **`.pub`** contents from Step 1.

The three unforgiving choices, repeated because they are expensive:

- Home region **Mumbai or Hyderabad** — cannot ever be changed
- **2 OCPU / 12 GB**, never 4/24 — Oracle auto-terminates instances that exceed it
- Block volume at **Lower Cost / 0 VPU** — raising it costs ~$3/month, which is
  36x the entire annual budget

Expect **"Out of host capacity"** on ARM in Indian regions. This is normal and
not a mistake on your part. Retry every few hours; people often need a day or
two. Do not retry in a tight loop — it can get an account flagged.

Note the public IP once it is running.

## Step 3 — Connect

```powershell
ssh -i $env:USERPROFILE\.ssh\oracle_immich ubuntu@<PUBLIC-IP>
```

On first connection it asks about authenticity — type `yes`.

If it refuses, the usual causes are: the instance is still booting (wait two
minutes), port 22 is not open in the OCI security list yet, or you pointed it at
the private key's `.pub` file by mistake.

**You are now on the VM.** Everything from here until Step 9 runs there, not on
Windows.

## Step 4 — Get the repository onto the VM

If you have already pushed to GitHub:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/<your-username>/personal-vault.git
cd personal-vault
```

If the repository is private, GitHub will ask for a username and a **personal
access token** (not your password). Create one at
github.com -> Settings -> Developer settings -> Personal access tokens, with
`repo` scope.

## Step 5 — Install Ansible on the VM

```bash
sudo apt update
sudo apt install -y ansible
ansible --version
```

## Step 6 — Point Ansible at the machine it is running on

```bash
cd ~/personal-vault/infra/ansible
cp inventory.example.ini inventory.ini
nano inventory.ini
```

Replace the contents with exactly this. `ansible_connection=local` means
"configure this same machine", so no SSH keys or networking are involved:

```ini
[immich]
localhost ansible_connection=local

[immich:vars]
ansible_python_interpreter=/usr/bin/python3
```

Save with `Ctrl+O`, `Enter`, then `Ctrl+X`.

## Step 7 — Get a Tailscale auth key

In a browser: tailscale.com -> Admin console -> Settings -> Keys -> **Generate
auth key**. Tick **Reusable** and **Pre-approved**. Copy it — it begins with
`tskey` followed by a dash and a long random string.

Treat it like a password. It is single-purpose and can be revoked from the same
page afterwards.

## Step 8 — Run the playbook

```bash
cd ~/personal-vault/infra/ansible
ansible-galaxy collection install -r requirements.yml
```

Put the key in a shell variable first, so it is not baked into your shell
history in a file you might later share:

```bash
read -rs TS_KEY          # paste the key, press Enter (nothing is echoed)

ansible-playbook -i inventory.ini playbook.yml \
  --extra-vars "tailscale_auth_key=$TS_KEY" \
  --extra-vars "immich_db_password=$(openssl rand -base64 32)"
```

This takes 10–20 minutes. It hardens the OS, installs Docker and Tailscale,
mounts the block volume, and starts Immich.

**Save the database password.** Print it and put it in your password manager:

```bash
sudo grep DB_PASSWORD /opt/immich/.env
```

You do not need it for restores (restic captures a SQL dump, not the raw data
directory), but you will want it if you ever open a `psql` session by hand.

The playbook prints the Tailscale IP at the end. Note it — it looks like
`100.x.y.z`.

## Step 9 — Lock the front door

Immich is now reachable **only** over Tailscale, so the public ports are no
longer needed.

First install Tailscale on your laptop (tailscale.com/download), sign in to the
same account, and confirm you can reach the VM over the tailnet:

```powershell
ssh -i $env:USERPROFILE\.ssh\oracle_immich ubuntu@100.x.y.z
```

**Only once that works**, go to the OCI console: Networking -> Virtual Cloud
Networks -> your VCN -> Security Lists -> **delete every ingress rule, including
SSH on port 22.** Doing this before confirming Tailscale works will lock you out.

Then verify from outside, which is the acceptance criterion for this phase:

```powershell
# Install nmap from nmap.org, or use an online port scanner
nmap -Pn -p- <PUBLIC-IP>
```

Expect **zero open ports**.

## Step 10 — Configure Immich

Install Tailscale on your phone (App Store / Play Store), sign in to the same
account, then open `http://100.x.y.z:2283` in the phone's browser.

Create the admin account. Then apply the mandatory settings in
`immich-settings.md` — especially:

- Video transcoding: **"not browser-compatible only"**, never "all"
- **Do not** convert HEIC to JPEG
- Enable automatic database backups at **02:00**
- Create a **read-only** API key for the metrics collector

## Step 11 — Install the Immich app

App Store (iPhone/iPad) or Play Store (Android): search **Immich**, install the
official app.

Server URL: `http://100.x.y.z:2283`

Sign in, then enable **background backup** for your camera roll. Tailscale must
stay connected on the phone for backup to work.

This app is why the project does not build a photo client: background
camera-roll upload is impossible from a browser on iOS, and this one already
exists and is free.

## Step 12 — Backup, then prove it works

```bash
sudo mkdir -p /opt/personal-vault /etc/personal-vault /var/lib/personal-vault
sudo rsync -a ~/personal-vault/ops/ /opt/personal-vault/ops/
sudo chmod +x /opt/personal-vault/ops/backup/*.sh /opt/personal-vault/ops/metrics/*.sh

sudo install -m 0600 /dev/null /etc/personal-vault/ops.env
sudo nano /etc/personal-vault/ops.env       # see the root .env.example for names

sudo install -m 0600 /dev/null /root/.restic-pass
sudo nano /root/.restic-pass                # a long random passphrase

sudo cp /opt/personal-vault/ops/systemd/*.service /etc/systemd/system/
sudo cp /opt/personal-vault/ops/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now immich-backup.timer metrics-push.timer
```

> ### THE RESTIC PASSWORD MUST BE STORED OFF THIS MACHINE
>
> Losing it is identical to losing the backup. There is no reset and no support
> ticket. Put it in your password manager **and** on paper.

Run one backup by hand, then the drill:

```bash
sudo systemctl start immich-backup.service
journalctl -u immich-backup.service -f      # Ctrl+C to stop watching

sudo /opt/personal-vault/ops/backup/restore-test.sh
```

**The restore drill is the point of the whole exercise.** Until it appends a PASS
to `ops/RESTORE-LOG.md`, your backup is a guess rather than a fact.

---

## If something goes wrong

| Symptom | Likely cause |
|---|---|
| `ssh: connect to host ... Connection refused` | Instance still booting, or port 22 closed in the security list |
| `Permission denied (publickey)` | Wrong key file, or the `.pub` was not pasted into Oracle |
| Playbook fails at the block volume | Volume not attached, or the iSCSI commands from the console were not run |
| Immich unreachable at `100.x.y.z:2283` | Tailscale not connected on the device you are testing from |
| `Out of host capacity` | Normal for ARM in India. Retry over hours or days. |
| Backup fails immediately | Check `/etc/personal-vault/ops.env` values and that `/mnt/media` is mounted |

Bring the exact error text back and it can be diagnosed from there.
