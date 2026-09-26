# Emergency kit — print, fill in by hand, never type the values here

Phase 0 of `docs/VAULTWARDEN-PLAN.md` (finding C4). This is a **template**.
Print it, write the values on the paper with a pen, and keep the filled-in copy
off every computer. The blank lines stay blank in this repository.

## Why paper

Every secret below unlocks something that lives on the Oracle VM or in the
Oracle tenancy. If that one account is lost, whatever was stored only there is
lost with it, and that includes a password manager running on the VM. Paper
doesn't depend on any of these systems.

## Rules

1. **Two filled-in copies, two buildings.** One at home, one with someone you
   trust. Record where below.
2. **Never photograph it.** The Immich app uploads the camera roll to the very VM
   this kit exists to survive, and the Telegram app syncs to the cloud.
3. **Never only in Vaultwarden.** Once Vaultwarden is running, it may hold a
   copy, but the paper stays the source. Vaultwarden runs on the VM this kit
   protects against losing.
4. **A second encrypted copy goes in the document vault** (`vault/`, on Vercel +
   Supabase, not Oracle): one file, uploaded from the browser. It protects
   against losing the paper; the paper protects against losing the vault
   passphrase.
5. **Test the kit after writing it** (bottom of this page). A kit with one wrong
   character is worth nothing, and you only find out on the worst day.

---

## A. Secrets that cannot be regenerated

Lose one of these and the data it protects is gone. There is no reset.

| # | Secret | Where it lives on the system | What it unlocks | Value (handwrite) |
|---|---|---|---|---|
| A1 | restic repository password | `/root/.restic-pass` on the VM | Every Oracle Object Storage backup (Immich DB dumps, archive ledger) | ______________________ |
| A2 | Document vault recovery code | Shown once at vault setup | The document vault if the passphrase is forgotten | ______________________ |
| A3 | Telegram two-step verification (cloud) password | Telegram account | The account that holds the **only copy** of the Insta360 footage | ______________________ |
| A4 | Off-Oracle restic password | `/root/.restic-offsite-pass` on the VM | The encrypted copy on Google Drive: the only backup that survives losing the Oracle account | ______________________ |
| A5 | Your own Vaultwarden master password | Your head | Your password vault. Each family member keeps their own on their own paper (`docs/FAMILY-GUIDE.md`) | ______________________ |

## B. Accounts needed to rebuild

Every API key and access token in `/etc/personal-vault/ops.env` can be
regenerated from one of these accounts, so the logins are what matter. Write
each login email and where its 2FA recovery codes are kept.

| # | Account | Why it matters | Login email / where its 2FA recovery codes are |
|---|---|---|---|
| B1 | Oracle Cloud (tenancy, home region `ap-mumbai-1`) | The VM console, and new Customer Secret Keys for the restic S3 access | ______________________ |
| B2 | Tailscale (which identity provider account) | Re-adding devices; the VM is reachable only through it | ______________________ |
| B3 | GitHub (personal account that owns this repo) | Every script, runbook and this kit's template | ______________________ |
| B4 | Supabase and Vercel | The document vault and `/status` | ______________________ |
| B5 | Telegram phone number | Where the SIM lives; see RUNBOOK "Protect the Telegram account" | ______________________ |
| B6 | healthchecks.io | Backup, drain and vault alerts | ______________________ |
| B7 | Google account holding the off-Oracle copy | Folder `personal-vault-offsite` in its Drive; without this login the A4 copy cannot be reached | ______________________ |

## C. Regenerable, but useful to have

| # | Item | Notes | Value (handwrite) |
|---|---|---|---|
| C1 | Vaultwarden admin password | Only while the admin page is on (`sudo vw-secrets admin-on`); off again afterwards. Anyone with root on the VM can set a new one | ______________________ |
| C2 | Oracle Object Storage namespace | Needed to point restic at the bucket. Bucket `immich-backup`, region `ap-mumbai-1` | ______________________ |

## D. Where the copies are

| Copy | Location | Last checked |
|---|---|---|
| Paper copy 1 | ______________________ | __________ |
| Paper copy 2 | ______________________ | __________ |
| Document vault file name | ______________________ | __________ |
| Off-Oracle copy | Google Drive of account B7, folder `personal-vault-offsite` | __________ |

---

## E. If the owner is unavailable (plan H6)

For the person holding the second copy. Nothing here needs to happen quickly.
Every phone and browser that already uses the family password vault keeps
working from its own offline copy, and can read and autofill, for weeks.

1. **Nothing is broken yet?** Do nothing. Apps keep working; the VM runs itself.
2. **The VM is gone or unreachable for good?** The backups survive in two
   places: Oracle Object Storage (bucket `immich-backup`) and the encrypted
   copy on Google Drive (section D). Each is unlocked by its own password
   (A1, A4). Restoring needs someone technical with this kit. The steps are
   in the GitHub repo (account B3): `docs/VAULTWARDEN-RUNBOOK.md` ("Disaster"),
   `docs/RUNBOOK.md` and `ops/README.md`.
3. **The Insta360 footage** is in the Telegram archive channel. Keep the
   Telegram account (A3, B5) alive: log in at least once every few months, or
   Telegram's inactivity rule can delete it along with the channel.

---

## Test the kit (do this after filling it in, and after any change)

Type the restic password **from the paper**, not by copy-paste, and check that it
opens the real repository. This reads one small object from Object Storage.
It takes no lock, so it is safe while the drain or the backup runs. Nothing is
written to disk except a RAM-backed temp file that is removed at the end.

```bash
# [VM] over Tailscale SSH (Termux is fine)
install -m 0600 /dev/null /dev/shm/kit-test
read -rs -p 'restic password, typed from the paper: ' p; printf '%s' "$p" > /dev/shm/kit-test; unset p; echo
sudo bash -c 'set -a; . /etc/personal-vault/ops.env; set +a
  export RESTIC_REPOSITORY="s3:https://${OCI_NAMESPACE}.compat.objectstorage.${OCI_REGION}.oraclecloud.com/${OCI_BUCKET}"
  export AWS_ACCESS_KEY_ID="$OCI_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$OCI_SECRET_KEY" AWS_DEFAULT_REGION="$OCI_REGION"
  export RESTIC_CACHE_DIR=/var/lib/personal-vault/restic-cache
  restic --no-lock --password-file /dev/shm/kit-test cat config >/dev/null \
    && echo "PAPER OK" || echo "PAPER WRONG - correct the paper, then test again"'
shred -u /dev/shm/kit-test
```

**The off-Oracle password (A4)** is tested the same way, once the Google
Drive copy exists (`docs/VAULTWARDEN-RUNBOOK.md` step 4). Use the same first
two lines, then:

```bash
sudo bash -c 'export RESTIC_REPOSITORY=rclone:gdrive:personal-vault-offsite
  export RCLONE_CONFIG=/var/lib/personal-vault/rclone/rclone.conf
  restic --no-lock --password-file /dev/shm/kit-test cat config >/dev/null \
    && echo "PAPER OK" || echo "PAPER WRONG - correct the paper, then test again"'
shred -u /dev/shm/kit-test
```

The recovery code (A2) is exercised by step 4 of the deploy order in
`docs/BUILD-STATE.md` ("Forgot passphrase?").

| Test | Date | Result |
|---|---|---|
| restic password from paper (A1) | __________ | __________ |
| off-Oracle password from paper (A4) | __________ | __________ |
| Vault recovery code | __________ | __________ |
