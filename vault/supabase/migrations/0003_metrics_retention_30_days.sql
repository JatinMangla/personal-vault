-- Metrics retention: 90 days -> 30 days.
--
-- The collector moved from one sample every 15 minutes to one every minute
-- (ops/systemd/metrics-push.timer), a 15x increase in row rate:
--
--   measured row size          1,889 bytes
--   at 1/minute                ~2.7 MB/day, ~245 MB/year
--   Supabase free tier          500 MB, shared with files and user_keys
--
-- 90 days of minute samples is ~130,000 rows and ~245 MB — approaching half the
-- tier on its own. 30 days is ~43,000 rows and ~82 MB, which leaves room for
-- the vault's actual data. The dashboard's growth projection reads the last 30
-- days, so nothing on /status loses history it was using.
--
-- 0001_initial_schema.sql is already applied and must not be edited. This
-- redefines the function in place; `create or replace` keeps the existing
-- grants, so the `revoke all ... from public` there still stands and the
-- function remains callable only with the service-role key.

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
  where collected_at < now() - interval '30 days';
  get diagnostics deleted = row_count;
  return deleted;
end;
$$;

-- Invoked nightly by .github/workflows/prune-metrics.yml. That workflow is the
-- other half of this change: until it existed, retention was unbounded no
-- matter what interval this function named — nothing ever called it.
