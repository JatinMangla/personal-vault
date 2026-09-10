#!/usr/bin/env bash
#
# One-command setup, run ON the Oracle VM.
#
# Ansible has no Windows control node, so rather than have you drive it from a
# laptop that cannot run it, this script installs Ansible on the VM and points
# it at localhost. You SSH in, run this, answer one prompt.
#
#   bash ~/personal-vault/infra/setup-on-vm.sh
#
# Safe to re-run. Every step is idempotent, and it stops at the first failure
# rather than continuing in a half-configured state.

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/JatinMangla/personal-vault.git}"
REPO_DIR="${REPO_DIR:-$HOME/personal-vault}"

bold()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
info()  { printf '  %s\n' "$*"; }
ok()    { printf '  \033[32mOK\033[0m  %s\n' "$*"; }
warn()  { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
die()   { printf '\n\033[31mFAILED\033[0m  %s\n\n' "$*" >&2; exit 1; }

bold "1/7  Checking this machine"

[[ "$(uname -m)" == "aarch64" ]] \
  || die "Expected ARM64 (aarch64), got $(uname -m). The pinned Docker images are arm64."
ok "architecture: aarch64"

grep -qi ubuntu /etc/os-release 2>/dev/null \
  || die "Expected Ubuntu. Found: $(grep PRETTY_NAME /etc/os-release 2>/dev/null || echo unknown)"
ok "$(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"

cpus=$(nproc)
mem_gb=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 / 1024 ))
info "CPU: ${cpus} | RAM: ~${mem_gb} GB"
if (( cpus > 2 || mem_gb > 13 )); then
  warn "This exceeds the Always Free entitlement (2 OCPU / 12 GB)."
  warn "Oracle TERMINATES instances that exceed it. Resize down before continuing."
  read -rp "  Continue anyway? [y/N] " a
  [[ "${a,,}" == "y" ]] || exit 1
fi

# All media lives on the block volume. Without it, Immich fills the 50 GB boot
# disk and takes the whole host down.
#
# /dev/oracleoci/oraclevdb only exists when the Block Volume Management plugin
# is enabled, which is not always possible from the console. Accept the raw
# device too - the playbook detects whichever is present.
if [[ -e /dev/oracleoci/oraclevdb ]]; then
  ok "block volume present at /dev/oracleoci/oraclevdb"
elif [[ -b /dev/sdb ]]; then
  ok "block volume present at /dev/sdb (Oracle symlink absent - fine)"
else
  die "No block volume found at /dev/oracleoci/oraclevdb or /dev/sdb.
  Attach the 150 GB volume in the OCI console (Lower Cost / 0 VPU), then run the
  iSCSI connect commands the console gives you. See infra/docs/oracle-setup.md."
fi

bold "2/7  Fetching the repository"

sudo apt-get update -qq
# Ubuntu Minimal ships none of these. rsync is needed by step 6; nano is needed
# because the operator has to hand-edit /etc/personal-vault/ops.env afterwards
# and being dropped at a prompt with no editor is a poor place to end a setup.
sudo apt-get install -y -qq git curl jq rsync nano >/dev/null
ok "git, curl, jq, rsync, nano installed"

if [[ -d "$REPO_DIR/.git" ]]; then
  git -C "$REPO_DIR" pull --ff-only || warn "could not fast-forward; using existing checkout"
  ok "repository updated at $REPO_DIR"
else
  git clone --depth 1 "$REPO_URL" "$REPO_DIR"
  ok "repository cloned to $REPO_DIR"
fi

bold "3/7  Installing Ansible"

if command -v ansible-playbook >/dev/null 2>&1; then
  ok "already installed: $(ansible --version | head -1)"
else
  sudo apt-get install -y -qq ansible >/dev/null
  ok "installed: $(ansible --version | head -1)"
fi

cd "$REPO_DIR/infra/ansible"

# Point Ansible at this same machine. No SSH keys or networking involved.
{
  echo "[immich]"
  echo "localhost ansible_connection=local"
  echo ""
  echo "[immich:vars]"
  echo "ansible_python_interpreter=/usr/bin/python3"
} > inventory.ini
ok "inventory configured for local execution"

# --force so a previously-installed, too-new collection is replaced. Without it
# an existing community.general 12.x stays put and the playbook fails with a
# removed-plugin error on Ubuntu 24.04's ansible-core 2.16.
ansible-galaxy collection install --force -r requirements.yml >/dev/null 2>&1 \
  && ok "galaxy collections installed" \
  || warn "collection install reported a problem; continuing"

bold "4/7  Credentials"

echo
echo "  A Tailscale auth key is needed. Get one at:"
echo "    tailscale.com -> Settings -> Keys -> Generate auth key"
echo "    Tick 'Reusable' and 'Pre-approved'."
echo
# -s so the key is never echoed to the terminal or left in scrollback.
read -rsp "  Paste the Tailscale auth key: " ts_input
echo
[[ -n "$ts_input" ]] || die "No auth key entered."
ok "auth key received (not displayed or logged)"

# Written to a root-only temp file rather than passed on a command line, where
# it would be visible in ps output to any user on the box.
vault_tmp="$(mktemp)"
chmod 600 "$vault_tmp"
trap 'rm -f "$vault_tmp"' EXIT

# REUSE the existing credential if one is already in place.
#
# Postgres only honours POSTGRES_PASSWORD when it INITIALISES an empty data
# directory. On an existing directory the variable is ignored entirely. So
# generating a fresh password on every run meant the second run onwards handed
# Immich a password the database had never been given, and immich_server
# crash-looped with:
#
#   PostgresError: password authentication failed for user "postgres"
#
# Re-running this script must be safe, so the credential is generated exactly
# once and reused thereafter.
if sudo test -f /opt/immich/.env && sudo grep -q '^DB_PASSWORD=' /opt/immich/.env; then
  sudo sed -n 's/^DB_PASSWORD=//p' /opt/immich/.env > "$vault_tmp"
  ok "reusing the existing database credential (matches the initialised data directory)"
else
  openssl rand -base64 32 > "$vault_tmp"
  ok "database credential generated"
fi

# A password mismatch here is unrecoverable without wiping the database, so
# check for the specific case where a data directory exists but no .env does -
# that combination means the credential is gone and Postgres cannot be reached.
if [[ ! -s "$vault_tmp" ]]; then
  die "Could not determine the database credential.
  If /var/lib/immich/postgres exists but /opt/immich/.env does not, the password
  the database was initialised with is lost. With no data yet, the fix is:
    cd /opt/immich && sudo docker compose down -v
    sudo rm -rf /var/lib/immich/postgres
  then re-run this script."
fi

bold "5/7  Running the playbook (10-20 minutes)"
info "Hardening the OS, installing Docker and Tailscale, mounting the volume,"
info "and starting Immich. Safe to re-run if it fails partway."
echo

ansible-playbook -i inventory.ini playbook.yml \
  --extra-vars "tailscale_auth_key=$ts_input" \
  --extra-vars "immich_db_password=$(cat "$vault_tmp")" \
  || die "The playbook failed. Read the error above, fix it, and re-run this script."

unset ts_input
ok "playbook completed"

bold "6/7  Installing backup and metrics automation"

sudo mkdir -p /opt/personal-vault /etc/personal-vault /var/lib/personal-vault
sudo rsync -a "$REPO_DIR/ops/" /opt/personal-vault/ops/
sudo chmod +x /opt/personal-vault/ops/backup/*.sh /opt/personal-vault/ops/metrics/*.sh
ok "scripts installed to /opt/personal-vault"

if [[ ! -f /etc/personal-vault/ops.env ]]; then
  sudo install -m 0600 /dev/null /etc/personal-vault/ops.env
  sudo tee /etc/personal-vault/ops.env >/dev/null <<'ENVEOF'
# Fill these in, then: sudo systemctl start immich-backup.service
# Mode 0600. Never commit this file.

# --- Oracle Object Storage, S3-compatible backup target ---
# Namespace: Profile -> Tenancy -> Object Storage Namespace
# Keys:      Profile -> User settings -> Customer secret keys
OCI_NAMESPACE=
OCI_REGION=ap-mumbai-1
OCI_BUCKET=immich-backup
OCI_ACCESS_KEY=
OCI_SECRET_KEY=
# Refuse to grow the repo past this share of the free tier. Oracle deletes
# ALL objects if the tenancy exceeds its limit when the Free Trial ends.
OCI_FREE_TIER_BYTES=10737418240
OCI_GUARD_PCT=85

# --- healthchecks.io dead-man switches ---
# The UUID ONLY - not the full ping URL. The scripts prepend
# https://hc-ping.com/ themselves, so pasting the whole URL gives HTTP 400.
# Format: 8-4-4-4-12 hex, e.g. f1de7580-1448-4f9b-92b7-cba2b76bd4de
HEALTHCHECK_UUID=
HEALTHCHECK_METRICS_UUID=

# --- Metrics push to the vault dashboard ---
# The ingest value below must EXACTLY match what is set in Vercel, or every
# push is rejected with 401 and /status stays empty.
METRICS_INGEST_SECRET=
METRICS_INGEST_URL=https://vault-amber-five.vercel.app/api/metrics/ingest

# --- Immich read-only API key (server.statistics, server.storage, server.about) ---
IMMICH_API_KEY=
# NOT 127.0.0.1. docker-compose.yml binds Immich to the Tailscale address only
# (`${TAILSCALE_IP}:2283:2283`), so nothing listens on loopback - a loopback URL
# here makes every collector run report "immich api unreachable or key
# rejected". Filled in automatically below with this host's Tailscale IP.
IMMICH_BASE_URL=http://TAILSCALE_IP_PLACEHOLDER:2283

# --- Paths ---
UPLOAD_LOCATION=/mnt/media
STATE_DIR=/var/lib/personal-vault
ENVEOF
  # The tailnet is up by this point (the playbook joined it), so resolve the
  # placeholder to this host's actual address.
  ts_now="$(tailscale ip -4 2>/dev/null | head -1 || true)"
  if [[ -n "$ts_now" ]]; then
    sudo sed -i "s|TAILSCALE_IP_PLACEHOLDER|${ts_now}|" /etc/personal-vault/ops.env
    ok "created /etc/personal-vault/ops.env (IMMICH_BASE_URL set to ${ts_now})"
  else
    warn "could not read the Tailscale IP - set IMMICH_BASE_URL in ops.env by hand"
    ok "created /etc/personal-vault/ops.env (needs filling in)"
  fi
else
  ok "ops.env already exists, left untouched"
fi

sudo cp /opt/personal-vault/ops/systemd/*.service /etc/systemd/system/
sudo cp /opt/personal-vault/ops/systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
ok "systemd units installed (timers NOT started - see next steps)"

bold "7/7  Done"

ts_addr="$(tailscale ip -4 2>/dev/null | head -1 || echo 'unknown')"

echo
echo "  Immich:  http://${ts_addr}:2283      (reachable over Tailscale only)"
echo
echo "  Database credential - copy it into your password manager now."
echo "  It never leaves this machine and is NOT needed to restore a backup"
echo "  (restic captures a SQL dump, not the data directory), but you will"
echo "  want it to open a psql session by hand."
echo
echo "    $(cat "$vault_tmp")"
echo
read -rp "  Press Enter once you have stored it... " _
clear
ok "credential no longer on screen"

echo ""
echo "  NEXT STEPS, in order:"
echo ""
echo "  1. Install Tailscale on your phone and laptop, sign in to the same"
echo "     account, then open http://${ts_addr}:2283 and create the Immich"
echo "     admin account."
echo ""
echo "  2. Apply the mandatory Immich settings - transcoding policy, HEIC"
echo "     handling, 02:00 database backups, and a read-only API key:"
echo "       ${REPO_DIR}/infra/docs/immich-settings.md"
echo ""
echo "  3. In the OCI console, DELETE every ingress rule in the security list -"
echo "     but ONLY after confirming you can reach this box over Tailscale."
echo "     Then verify from outside:  nmap -Pn -p- <public-ip>  (expect zero)"
echo ""
echo "  4. Create an Object Storage bucket and Customer secret keys in OCI,"
echo "     then fill in:"
echo "       sudo nano /etc/personal-vault/ops.env"
echo ""
echo "  5. Set the restic password, and STORE IT SOMEWHERE THAT IS NOT THIS"
echo "     MACHINE. Losing it is identical to losing the backup. No reset."
echo "       sudo install -m 0600 /dev/null /root/.restic-pass"
echo "       sudo nano /root/.restic-pass"
echo ""
echo "  6. Start the timers, run one backup, then prove it restores:"
echo "       sudo systemctl enable --now immich-backup.timer metrics-push.timer"
echo "       sudo systemctl start immich-backup.service"
echo "       sudo /opt/personal-vault/ops/backup/restore-test.sh"
echo ""
echo "     The restore drill is the point of the whole exercise. Until it"
echo "     passes, your backup is a hypothesis, not a backup."
echo ""
