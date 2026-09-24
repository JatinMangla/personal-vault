-- Drop the filename blind index.
--
-- files.filename_hash was a salted SHA-256 of the filename, and the salt was
-- kdf_salt - stored server-side - so the server could dictionary-test names at
-- one hash per guess ("passport.pdf"). Nothing ever read it; it was only
-- written. Removed rather than repaired.
--
-- DEPLOY ORDER: apply this ONLY AFTER the application code that no longer sends
-- filename_hash is live. The old code names the column in its insert, and
-- against a dropped column every upload would fail.

drop index if exists public.files_user_hash_idx;
alter table public.files drop column if exists filename_hash;
