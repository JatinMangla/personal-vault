-- Restore the intended grants on prune_metrics_samples().
--
-- 0001_initial_schema.sql ends with:
--
--   revoke all on function public.prune_metrics_samples() from public;
--
-- but the LIVE ACL, read from pg_proc on 2026-09-16, was:
--
--   postgres=X/postgres, anon=X/postgres, authenticated=X/postgres, ...
--
-- anon and authenticated both held EXECUTE.
--
-- WHY THIS MATTERS. The function is SECURITY DEFINER and deletes rows. The anon
-- key ships in the browser bundle and is public by design, so any holder of it
-- could call the RPC and delete metrics samples. Observability data rather than
-- vault contents, so not catastrophic - but it is a public delete primitive
-- that was never intended to exist, and it silently contradicted the line in
-- 0001 that was supposed to prevent exactly this.
--
-- WHY THE ORIGINAL REVOKE DID NOT HOLD. `revoke ... from public` removes only
-- the PUBLIC pseudo-role's grant; it does not touch privileges held directly by
-- named roles. Supabase's default configuration grants execute on functions in
-- schema public to the anon and authenticated roles BY NAME, so they survive
-- the revoke in 0001 and are re-applied to new functions. They must therefore
-- be revoked by name, which is what this does.
--
-- `create or replace` PRESERVES existing grants, so 0003 carried this forward
-- unchanged. A comment in 0003 claiming the revoke "still stands" was wrong;
-- this migration is the correction.
--
-- Nothing legitimate breaks. The only intended caller is the nightly
-- .github/workflows/prune-metrics.yml, which authenticates as the privileged
-- backend role - and that role's existing EXECUTE grant is untouched by the
-- revokes below, so no new grant is needed here.
--
-- NOT changed: user_storage_bytes() carries the same broad ACL, but that one is
-- correct. It is scoped internally by auth.uid() and is MEANT to be callable by
-- a signed-in user. Only this function was wrong.

revoke all on function public.prune_metrics_samples() from public;
revoke all on function public.prune_metrics_samples() from anon;
revoke all on function public.prune_metrics_samples() from authenticated;

-- Verify after applying - anon and authenticated must be absent:
--
--   select coalesce(array_to_string(proacl, ', '), '(none)')
--   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--   where n.nspname = 'public' and p.proname = 'prune_metrics_samples';
