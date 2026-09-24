-- Least privilege: remove every grant the application never uses.
--
-- Each item below was found in the 2026-09-24 review by checking what the app
-- actually calls, not what the schema permits:
--
--   1. storage.objects policies for `vault-files` (all four). Every storage
--      operation in the app - signing an upload, signing a download, deleting -
--      goes through lib/storage.ts with the SERVICE ROLE, which bypasses RLS.
--      No browser code touches Storage with a user session. The policies were
--      therefore reachable only by something NOT using the app: a signed-in
--      session calling the Storage API directly, which skips the presign route
--      and with it the quota check and the size check. Removing them makes the
--      presign route the only way in.
--
--   2. UPDATE on public.files. Never issued by the app. Dropped with the
--      policy AND the privilege, since Supabase grants table privileges to
--      anon/authenticated by name (see 0004 for why a policy alone, or a revoke
--      from PUBLIC, is not enough).
--
--   3. UPDATE on public.user_keys is NOT handled here - 0006 owns it. In
--      Postgres a table-level revoke also wipes column-level grants, so if this
--      file revoked it and ran after 0006 it would silently undo 0006. Keeping
--      every user_keys UPDATE statement in one file makes the order irrelevant.
--
--   4. user_storage_bytes() now sums the REAL stored object sizes from
--      storage.objects instead of the client-declared files.size_bytes, so the
--      quota cannot be understated. Still one RPC, still pinned to auth.uid().
--      Orphaned blobs now count too, which is correct: they occupy real quota.
--
-- Safe to apply before or after the new application code: the old code issues
-- no UPDATE and never touches Storage with a user session. The filename_hash
-- column is dropped separately, in 0007, because THAT one needs the new code
-- live first.

-- 1------------------------------------------------------------------------
drop policy if exists "users read own objects"   on storage.objects;
drop policy if exists "users insert own objects" on storage.objects;
drop policy if exists "users update own objects" on storage.objects;
drop policy if exists "users delete own objects" on storage.objects;

-- 2 ------------------------------------------------------------------------
drop policy if exists "users update own files" on public.files;
revoke update on public.files from anon, authenticated;

-- 4------------------------------------------------------------------------
-- `create or replace` keeps the existing grants: executable by authenticated
-- (and anon, for whom auth.uid() is null and the sum is 0).
create or replace function public.user_storage_bytes()
returns bigint
language sql
security definer
set search_path = public, pg_temp
stable
as $$
  select coalesce(sum((o.metadata->>'size')::bigint), 0)::bigint
  from storage.objects o
  where o.bucket_id = 'vault-files'
    and o.name like auth.uid()::text || '/%';
$$;

-- Verify after applying:
--
--   -- no storage policies left for the bucket
--   select policyname from pg_policies
--   where schemaname = 'storage' and tablename = 'objects';
--
--   -- no UPDATE on files for client roles (expect zero rows)
--   select table_name, grantee from information_schema.role_table_grants
--   where table_schema = 'public' and privilege_type = 'UPDATE'
--     and table_name = 'files'
--     and grantee in ('anon', 'authenticated');
--
--   -- old and new quota figures, side by side (run as the SQL editor user)
--   select (select sum(size_bytes) from public.files) as declared,
--          (select sum((metadata->>'size')::bigint) from storage.objects
--            where bucket_id = 'vault-files') as stored;
--
-- Then upload, download and delete one file through the live app. If the
-- upload fails, restore the four policies from 0002 and report it - that would
-- mean signed upload URLs need an insert policy after all.
