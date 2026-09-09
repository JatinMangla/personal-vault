-- Storage bucket for encrypted document blobs.
--
-- Replaces the original Cloudflare R2 bucket. R2 required a payment method with
-- no spending cap, which conflicts with the project's rule that no card may be
-- attached in a way that permits automatic overage billing.
--
-- The bucket holds ONLY ciphertext. Files are encrypted in the browser with
-- AES-256-GCM before upload, so Supabase — like Cloudflare before it — stores
-- opaque bytes under an opaque, random object key.

-- Private bucket. `public = false` means no object is readable without a signed
-- URL, which is the whole point: a public bucket would expose every blob to
-- anyone who could guess a key.
insert into storage.buckets (id, name, public, file_size_limit)
values (
  'vault-files',
  'vault-files',
  false,
  -- 100 MB per object, matching MAX_SINGLE_UPLOAD_BYTES in lib/storage.ts.
  -- Enforced here as well as in the API so a stolen upload token cannot be
  -- used to push an arbitrarily large object and exhaust the free tier.
  104857600
)
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit;

-- ---------------------------------------------------------------------------
-- Row Level Security on storage.objects
-- ---------------------------------------------------------------------------
--
-- Object keys are `<userId>/<random>`, so the first path segment is the owner.
-- storage.foldername() splits the key on '/', and element 1 is that segment.
--
-- These policies are defence in depth: the API routes already sign URLs with
-- the service role after checking ownership. They matter because a signed URL
-- is a bearer credential — if one leaked, these policies still confine what a
-- normal authenticated session can reach.

drop policy if exists "users read own objects" on storage.objects;
create policy "users read own objects"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'vault-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "users insert own objects" on storage.objects;
create policy "users insert own objects"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'vault-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "users update own objects" on storage.objects;
create policy "users update own objects"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'vault-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  )
  with check (
    bucket_id = 'vault-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

drop policy if exists "users delete own objects" on storage.objects;
create policy "users delete own objects"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'vault-files'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

-- Note: there is deliberately no policy granting the `anon` role anything.
-- An unauthenticated caller holding the publishable key can reach nothing here.
