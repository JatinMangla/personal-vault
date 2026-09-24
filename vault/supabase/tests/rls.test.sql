-- Row-level security and privilege assertions, run in CI against a local
-- Supabase with every migration applied (.github/workflows/rls.yml).
--
-- WHY. The 2026-09-10 sign-off checked cross-user isolation once, by hand,
-- against the live project. Migrations 0005-0007 then removed policies and
-- grants on purpose. A mistake in either direction - a grant left open, or one
-- removed that the app needs - must fail a build, not be found in production.
--
-- Each check acts as a real client would: `set local role authenticated` plus
-- JWT claims, which is exactly what PostgREST does per request, so auth.uid()
-- and every policy behave as they do live. Everything runs in one transaction
-- and is rolled back.
--
-- Run: psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/rls.test.sql

begin;

-- --- Fixtures (as the superuser) ------------------------------------------

insert into auth.users (id, email) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'a@example.test'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'b@example.test');

insert into public.user_keys
  (user_id, kdf_salt, recovery_wrapped_key, passphrase_verifier, passphrase_salt, passphrase_wrapped_key)
values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'salt-a', 'rec-a', 'ver-a', 'psalt-a', 'pwrap-a'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', 'salt-b', 'rec-b', 'ver-b', 'psalt-b', 'pwrap-b');

-- A DECLARES 100 bytes but actually stored 1234: the quota must see 1234.
insert into public.files (user_id, object_key, encrypted_metadata, encrypted_manifest, size_bytes)
values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/obj1', 'm', 'x', 100);

insert into storage.objects (bucket_id, name, metadata) values
  ('vault-files', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/obj1', '{"size": 1234}'),
  ('vault-files', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/orphan', '{"size": 66}'),
  ('vault-files', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb/obj2', '{"size": 999}');

-- --- Schema-level facts (as the superuser) ----------------------------------

do $$ begin
  if exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
             and policyname in ('users read own objects', 'users insert own objects',
                                'users update own objects', 'users delete own objects')) then
    raise exception 'FAIL: vault-files storage policies still exist (0005 should drop them)';
  end if;
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'files' and column_name = 'filename_hash') then
    raise exception 'FAIL: files.filename_hash still exists (0007 should drop it)';
  end if;
  raise notice 'PASS schema: no storage policies, no filename_hash';
end $$;

-- --- As user A ---------------------------------------------------------------

set local role authenticated;
set local request.jwt.claims = '{"sub": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "role": "authenticated"}';

do $$
declare n integer;
begin
  if (select count(*) from public.files) <> 1 then
    raise exception 'FAIL: A should see exactly its own 1 file';
  end if;
  if (select count(*) from public.user_keys) <> 1 then
    raise exception 'FAIL: A should see exactly its own key row';
  end if;

  -- Quota counts REAL stored bytes, orphans included, and only A's.
  if public.user_storage_bytes() <> 1234 + 66 then
    raise exception 'FAIL: A quota is %, expected 1300 (stored, not declared)', public.user_storage_bytes();
  end if;

  -- The two passphrase columns are writable on A's own row.
  update public.user_keys set passphrase_salt = 'psalt-a2', passphrase_wrapped_key = 'pwrap-a2';
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL: A could not update its own passphrase wrapping'; end if;

  -- ...but not B's row: RLS makes it invisible, so zero rows change.
  update public.user_keys set passphrase_wrapped_key = 'hijack'
   where user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL: A changed B''s passphrase wrapping'; end if;

  raise notice 'PASS A: own rows only, real quota, passphrase columns writable';
end $$;

-- Every column that would brick the vault is immutable to the client.
do $$ begin
  begin
    update public.user_keys set kdf_salt = 'evil';
    raise exception 'FAIL: kdf_salt was updatable';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.user_keys set recovery_wrapped_key = 'evil';
    raise exception 'FAIL: recovery_wrapped_key was updatable';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.user_keys set passphrase_verifier = 'evil';
    raise exception 'FAIL: passphrase_verifier was updatable';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.files set size_bytes = 0;
    raise exception 'FAIL: files was updatable';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS A: kdf_salt, recovery_wrapped_key, verifier and files are not updatable';
end $$;

-- Storage is reachable ONLY through service-role signed URLs.
do $$ begin
  if (select count(*) from storage.objects where bucket_id = 'vault-files') <> 0 then
    raise exception 'FAIL: a user session can list storage objects directly';
  end if;
  begin
    insert into storage.objects (bucket_id, name, metadata)
    values ('vault-files', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa/direct', '{"size": 1}');
    raise exception 'FAIL: a user session can upload directly, skipping presign and quota';
  exception when insufficient_privilege then null;
  end;
  raise notice 'PASS A: no direct storage read or write';
end $$;

-- --- As user B ---------------------------------------------------------------

set local request.jwt.claims = '{"sub": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "role": "authenticated"}';

do $$ begin
  if (select count(*) from public.files) <> 0 then
    raise exception 'FAIL: B can see A''s files';
  end if;
  if (select count(*) from public.user_keys where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') <> 0 then
    raise exception 'FAIL: B can see A''s key material';
  end if;
  if public.user_storage_bytes() <> 999 then
    raise exception 'FAIL: B quota is %, expected 999', public.user_storage_bytes();
  end if;
  raise notice 'PASS B: isolated from A';
end $$;

-- --- As anon -------------------------------------------------------------------

reset role;
set local role anon;
set local request.jwt.claims = '{"role": "anon"}';

do $$ begin
  if (select count(*) from public.files) <> 0 or (select count(*) from public.user_keys) <> 0 then
    raise exception 'FAIL: anon can read vault rows';
  end if;
  raise notice 'PASS anon: sees nothing';
end $$;

-- --- And the change A made really landed ---------------------------------------

reset role;
do $$ begin
  if (select passphrase_wrapped_key from public.user_keys
       where user_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') <> 'pwrap-a2' then
    raise exception 'FAIL: A''s passphrase update did not persist';
  end if;
  if (select passphrase_wrapped_key from public.user_keys
       where user_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') <> 'pwrap-b' then
    raise exception 'FAIL: B''s passphrase wrapping was altered';
  end if;
  raise notice 'PASS: all RLS and privilege assertions';
end $$;

rollback;
