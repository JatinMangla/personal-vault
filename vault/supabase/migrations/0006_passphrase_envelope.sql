-- Envelope keys: make "change passphrase" and "recover with the recovery code"
-- possible without re-encrypting a single file.
--
-- BEFORE: the file key WAS PBKDF2(passphrase, kdf_salt). Changing the
-- passphrase would change the key and orphan every file, and although the
-- recovery code wrapped that key, there was no way to set a new passphrase
-- after using it - the next unlock would derive the old key from nothing.
--
-- AFTER: the file key (the data key) is wrapped under a key derived from the
-- passphrase, with its own salt:
--
--   passphrase_wrapped_key = AES-GCM( PBKDF2(passphrase, passphrase_salt), data key )
--   recovery_wrapped_key   = AES-GCM( PBKDF2(recovery code, kdf_salt),     data key )   (unchanged)
--
-- Changing the passphrase rewrites only these two columns. Existing accounts
-- keep their current key as the data key - the browser wraps it on the first
-- unlock after deploy - so no file is touched.
--
-- Unlock cost is unchanged: one PBKDF2 plus a microsecond unwrap.

alter table public.user_keys
  add column if not exists passphrase_salt text,
  add column if not exists passphrase_wrapped_key text;

comment on column public.user_keys.passphrase_wrapped_key is
  'Data key wrapped under PBKDF2(passphrase, passphrase_salt). Inert without the passphrase.';

-- Column-level UPDATE for the owner, on these two columns ONLY, so kdf_salt,
-- recovery_wrapped_key and passphrase_verifier stay immutable to clients: at
-- worst a stolen session can replace the passphrase wrapping, and the recovery
-- code still opens the vault.
--
-- Before this, Supabase's default grants gave anon and authenticated UPDATE on
-- the WHOLE table, and 0001's policy let the owner rewrite any column - so a
-- stolen session could overwrite kdf_salt or recovery_wrapped_key and make
-- every file permanently undecryptable. 0001 refused a DELETE policy for
-- exactly that reason and then allowed UPDATE.
--
-- Revoke then grant, in this one file and nowhere else: in Postgres, revoking
-- a TABLE privilege also revokes every COLUMN grant of it, so a table-level
-- revoke in any other migration could silently undo the grant below.
revoke update on public.user_keys from anon, authenticated;
grant update (passphrase_salt, passphrase_wrapped_key) on public.user_keys to authenticated;

-- The row-level policy "users update own key material" from 0001 still applies
-- on top, so the owner can update only their own row.

-- Verify after applying (expect exactly the two columns, for authenticated):
--
--   select grantee, column_name from information_schema.column_privileges
--   where table_schema = 'public' and table_name = 'user_keys'
--     and privilege_type = 'UPDATE' and grantee in ('anon', 'authenticated');
