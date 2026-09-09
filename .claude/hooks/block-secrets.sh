#!/usr/bin/env bash
# PreToolUse guard for Write|Edit.
#
# Reads the tool-call JSON on stdin, extracts the content being written, and
# blocks the write (exit 2) if it contains anything resembling a live credential.
#
# Exit codes:
#   0 - allow
#   2 - block; stderr is shown to Claude as the reason
#
# Deliberately zero-dependency: pure bash + grep -E. No jq, no python.
# Rationale: this runs on every write; a missing dependency must never
# silently disable the guard.

set -uo pipefail

payload="$(cat)"

# Allow the example/template files that exist precisely to hold variable NAMES.
# Match the file path field anywhere in the payload.
if printf '%s' "$payload" | grep -qE '"file_path"[[:space:]]*:[[:space:]]*"[^"]*(\.env\.example|\.example\.|\.gitignore|block-secrets\.sh|SECURITY\.md)'; then
  exit 0
fi

fail() {
  echo "BLOCKED by .claude/hooks/block-secrets.sh: $1" >&2
  echo "Use an environment variable instead. Never commit a live credential." >&2
  exit 2
}

# --- Pattern checks -------------------------------------------------------
# Each pattern targets a credential shape that is unambiguous enough that a
# false positive is rare, and a false negative is the expensive failure.

# PEM private key blocks of any flavour (RSA, EC, OPENSSH, PGP).
printf '%s' "$payload" | grep -qE 'BEGIN[ A-Z]*PRIVATE KEY' \
  && fail "PEM private key block"

printf '%s' "$payload" | grep -qE 'BEGIN PGP PRIVATE KEY' \
  && fail "PGP private key block"

# AWS / R2 / S3-compatible access key IDs.
printf '%s' "$payload" | grep -qE '\b(AKIA|ASIA|AGPA|AIDA)[0-9A-Z]{16}\b' \
  && fail "AWS-style access key ID"

# GitHub tokens (classic PAT, fine-grained, OAuth, app, refresh).
printf '%s' "$payload" | grep -qE '\bgh[pousr]_[A-Za-z0-9]{36,}\b' \
  && fail "GitHub token"
printf '%s' "$payload" | grep -qE '\bgithub_pat_[A-Za-z0-9_]{60,}\b' \
  && fail "GitHub fine-grained PAT"

# Slack, Stripe, SendGrid, Google API keys.
printf '%s' "$payload" | grep -qE '\bxox[abposr]-[A-Za-z0-9-]{10,}\b' \
  && fail "Slack token"
printf '%s' "$payload" | grep -qE '\b[sr]k_(live|test)_[A-Za-z0-9]{20,}\b' \
  && fail "Stripe secret key"
printf '%s' "$payload" | grep -qE '\bSG\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\b' \
  && fail "SendGrid API key"
printf '%s' "$payload" | grep -qE '\bAIza[0-9A-Za-z_-]{35}\b' \
  && fail "Google API key"

# JWTs. A Supabase service-role key is a JWT and is catastrophic to leak:
# it bypasses Row Level Security entirely.
printf '%s' "$payload" | grep -qE '\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b' \
  && fail "JWT (possible Supabase service-role key)"
printf '%s' "$payload" | grep -qE 'service_role' \
  && fail "reference to a Supabase service_role credential"

# Tailscale auth keys.
printf '%s' "$payload" | grep -qE '\btskey-(auth|client)-[A-Za-z0-9-]{10,}\b' \
  && fail "Tailscale auth key"

# Database connection strings carrying an inline password.
printf '%s' "$payload" | grep -qE '(postgres(ql)?|mysql|mongodb(\+srv)?|redis|amqp)://[^:@/"[:space:]]+:[^@/"[:space:]]+@' \
  && fail "connection string with an inline password"

# Assignment of a long literal to a secret-shaped variable name.
# Excludes obvious placeholders so templates and docs stay writable.
if printf '%s' "$payload" \
   | grep -qE '(SECRET|PASSWORD|PASSWD|PRIVATE_KEY|ACCESS_KEY|API_KEY|TOKEN|CREDENTIAL)[A-Z_]*[[:space:]]*[:=][[:space:]]*.?[A-Za-z0-9+/_=-]{16,}'; then
  if ! printf '%s' "$payload" \
     | grep -qiE '(SECRET|PASSWORD|PASSWD|PRIVATE_KEY|ACCESS_KEY|API_KEY|TOKEN|CREDENTIAL)[A-Z_]*[[:space:]]*[:=][[:space:]]*.?(your|example|changeme|placeholder|xxx|\.\.\.|<|\$\{|process\.env|REPLACE|TODO|dummy|sample|fake|test)'; then
    fail "assignment of a long literal to a secret-named variable"
  fi
fi

exit 0
