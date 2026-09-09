-- Personal Vault — initial schema
--
-- Design rule: this database holds NO plaintext of anything the user considers
-- private. Filenames, tags and notes are encrypted client-side and land here as
-- opaque base64. What remains in the clear is what the server genuinely needs
-- to enforce quotas and ownership: a user id, a byte count, a timestamp.
--
-- RLS IS NOT OPTIONAL. A Supabase table without Row Level Security is readable
-- by anyone holding the anon key, and the anon key ships to the browser. Every
-- table below enables RLS and every policy is scoped to auth.uid().

-- ---------------------------------------------------------------------------
-- User key material
-- ---------------------------------------------------------------------------

create table if not exists public.user_keys (
  user_id uuid primary key references auth.users(id) on delete cascade,

  -- Per-user PBKDF2 salt, base64. Not a secret: a salt's job is to make
  -- precomputed dictionary attacks useless, and it must be retrievable before
  -- the user has authenticated their passphrase. It is useless on its own.
  kdf_salt text not null,

  -- Iteration count recorded per user so it can be raised for new accounts
  -- without invalidating existing ones.
  kdf_iterations integer not null default 600000
    constraint kdf_iterations_floor check (kdf_iterations >= 600000),

  -- The file key wrapped under the recovery code, base64. Useless without the
  -- recovery code, which is shown once at setup and never transmitted.
  recovery_wrapped_key text,

  -- A verifier: a known constant encrypted under the derived key. Lets the UI
  -- say "wrong passphrase" immediately instead of after downloading a file and
  -- failing to decrypt it. Reveals nothing — it is ciphertext of a public value.
  passphrase_verifier text,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.user_keys is
  'Per-user key derivation parameters. Contains no key material usable without the passphrase or recovery code.';

alter table public.user_keys enable row level security;

create policy "users read own key material"
  on public.user_keys for select
  using (auth.uid() = user_id);

create policy "users insert own key material"
  on public.user_keys for insert
  with check (auth.uid() = user_id);

create policy "users update own key material"
  on public.user_keys for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- No delete policy: key material is removed only by deleting the account, which
-- cascades from auth.users. A stray delete here would orphan every file.

-- ---------------------------------------------------------------------------
-- Files
-- ---------------------------------------------------------------------------

create table if not exists public.files (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,

  -- R2 object key. Random, never derived from the filename — Cloudflare can see
  -- object keys, so deriving one from a name would leak the name.
  object_key text not null unique,

  -- Encrypted JSON: filename, content type, tags, notes. Opaque to the server.
  encrypted_metadata text not null,

  -- Encrypted chunk manifest: per-chunk IVs and ciphertext lengths.
  encrypted_manifest text not null,

  -- Salted SHA-256 of the filename, for duplicate detection without revealing
  -- it. Salted per-user so it cannot be matched against a precomputed
  -- dictionary of common filenames.
  filename_hash text,

  -- Ciphertext size in bytes. Needed in the clear to enforce the R2 quota
  -- before minting a presigned URL.
  size_bytes bigint not null check (size_bytes >= 0),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on column public.files.size_bytes is
  'Ciphertext byte count. In the clear because quota enforcement needs it server-side.';

alter table public.files enable row level security;

create policy "users read own files"
  on public.files for select
  using (auth.uid() = user_id);

create policy "users insert own files"
  on public.files for insert
  with check (auth.uid() = user_id);

create policy "users update own files"
  on public.files for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "users delete own files"
  on public.files for delete
  using (auth.uid() = user_id);

create index if not exists files_user_created_idx
  on public.files (user_id, created_at desc);

create index if not exists files_user_hash_idx
  on public.files (user_id, filename_hash);

-- ---------------------------------------------------------------------------
-- Metrics samples (Component D)
-- ---------------------------------------------------------------------------

create table if not exists public.metrics_samples (
  id bigserial primary key,

  -- Collector timestamp, not insertion time. Clock skew on the VM is visible
  -- as a gap rather than being silently papered over.
  collected_at timestamptz not null,
  host text not null,

  -- Whole payload, so a new metric can be added to the collector without a
  -- migration. The dashboard reads named paths out of it.
  payload jsonb not null,

  created_at timestamptz not null default now()
);

comment on table public.metrics_samples is
  'Host metrics pushed from the Oracle VM. Written only by the service role via /api/metrics/ingest.';

alter table public.metrics_samples enable row level security;

-- Readable by any authenticated user — this is a single-owner system and the
-- dashboard needs it. Note there is deliberately NO insert/update/delete policy
-- for regular users: writes go through the ingest route using the service role,
-- which bypasses RLS. A browser holding the anon key cannot forge a sample.
create policy "authenticated users read metrics"
  on public.metrics_samples for select
  to authenticated
  using (true);

create index if not exists metrics_collected_idx
  on public.metrics_samples (collected_at desc);

-- ---------------------------------------------------------------------------
-- Quota helper
-- ---------------------------------------------------------------------------

-- security definer so it can aggregate the caller's rows, with the WHERE clause
-- pinned to auth.uid(). search_path is fixed to defeat search-path injection,
-- which is the standard failure mode for definer functions.
create or replace function public.user_storage_bytes()
returns bigint
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(sum(size_bytes), 0)::bigint
  from public.files
  where user_id = auth.uid();
$$;

revoke all on function public.user_storage_bytes() from public;
grant execute on function public.user_storage_bytes() to authenticated;

-- ---------------------------------------------------------------------------
-- Retention: keep 90 days of metrics
-- ---------------------------------------------------------------------------

create or replace function public.prune_metrics_samples()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  deleted integer;
begin
  delete from public.metrics_samples
  where collected_at < now() - interval '90 days';
  get diagnostics deleted = row_count;
  return deleted;
end;
$$;

revoke all on function public.prune_metrics_samples() from public;

-- At one sample per 15 minutes, 90 days is roughly 8,600 rows — trivially
-- inside Supabase's 500 MB. Invoked by the nightly GitHub Action.

-- ---------------------------------------------------------------------------
-- updated_at maintenance
-- ---------------------------------------------------------------------------

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists files_touch_updated_at on public.files;
create trigger files_touch_updated_at
  before update on public.files
  for each row execute function public.touch_updated_at();

drop trigger if exists user_keys_touch_updated_at on public.user_keys;
create trigger user_keys_touch_updated_at
  before update on public.user_keys
  for each row execute function public.touch_updated_at();
