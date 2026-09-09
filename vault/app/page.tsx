'use client';

/**
 * File browser — the vault's main screen.
 *
 * Handles three states: signed out, locked (session but no key in memory), and
 * unlocked. The locked state exists because the key is deliberately not
 * persisted anywhere, so a refresh always requires the passphrase again.
 */

import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react';
import { browserClient } from '@/lib/supabase-browser';
import { useVaultKey } from '@/components/VaultKeyProvider';
import { FileList } from '@/components/FileList';
import {
  decryptIndex,
  downloadFile,
  saveToDisk,
  searchFiles,
  uploadFile,
  type DecryptedFile,
  type TransferProgress,
  type VaultFile,
} from '@/lib/transfer';
import { formatBytes } from '@/lib/thresholds';
import {
  bytesToBase64,
  deriveExtractableKey,
  generateRecoveryCode,
  generateSalt,
  wrapKeyWithRecoveryCode,
  PBKDF2_ITERATIONS,
} from '@/lib/crypto';
import { createVerifier } from '@/components/VaultKeyProvider';

interface KeyMaterial {
  kdf_salt: string;
  kdf_iterations: number;
  passphrase_verifier: string | null;
}

export default function FilesPage() {
  const { key, isUnlocked, unlock, lock, isDeriving, error: keyError } = useVaultKey();

  const [userId, setUserId] = useState<string | null>(null);
  const [keyMaterial, setKeyMaterial] = useState<KeyMaterial | null>(null);
  const [checkingSession, setCheckingSession] = useState(true);

  const [files, setFiles] = useState<DecryptedFile[]>([]);
  const [quota, setQuota] = useState<{ used: number; limit: number } | null>(null);
  const [query, setQuery] = useState('');
  const [passphrase, setPassphrase] = useState('');
  const [status, setStatus] = useState<string | null>(null);
  const [progress, setProgress] = useState<TransferProgress | null>(null);
  const [busyKey, setBusyKey] = useState<string | null>(null);

  const fileInputRef = useRef<HTMLInputElement>(null);
  const [newRecoveryCode, setNewRecoveryCode] = useState<string | null>(null);

  // --- Session -------------------------------------------------------------

  useEffect(() => {
    void (async () => {
      // Every path through this MUST clear checkingSession. Without the
      // try/finally, an unreachable Supabase (network blip, bad URL, DNS
      // failure) leaves the page showing "Loading..." forever with no
      // explanation, which is indistinguishable from the app being broken.
      try {
        const supabase = browserClient();
        const { data, error } = await supabase.auth.getUser();

        if (error) {
          // A missing session is normal and not worth surfacing; anything else
          // is a real connectivity or configuration problem the user should see.
          if (error.name !== 'AuthSessionMissingError') {
            setStatus(`Could not reach the server: ${error.message}`);
          }
          return;
        }

        const user = data.user;
        if (!user) return;

        setUserId(user.id);

        const { data: keys, error: keyError } = await supabase
          .from('user_keys')
          .select('kdf_salt, kdf_iterations, passphrase_verifier')
          .eq('user_id', user.id)
          .maybeSingle();

        if (keyError) {
          setStatus(`Could not load your vault settings: ${keyError.message}`);
          return;
        }
        setKeyMaterial((keys as KeyMaterial | null) ?? null);
      } catch (err) {
        setStatus(
          err instanceof Error
            ? `Could not reach the server: ${err.message}`
            : 'Could not reach the server.',
        );
      } finally {
        setCheckingSession(false);
      }
    })();
  }, []);

  // --- Load the index once unlocked ---------------------------------------

  const loadFiles = useCallback(async () => {
    if (!key) return;
    const res = await fetch('/api/files', { cache: 'no-store' });
    if (!res.ok) {
      setStatus('Could not load the file list.');
      return;
    }
    const body = (await res.json()) as {
      files: VaultFile[];
      quota: { used: number; limit: number };
    };
    setFiles(await decryptIndex(body.files, key));
    setQuota(body.quota);
  }, [key]);

  useEffect(() => {
    if (isUnlocked) void loadFiles();
  }, [isUnlocked, loadFiles]);

  // --- Actions -------------------------------------------------------------

  /**
   * Create key material for a signed-in account that has none.
   *
   * An account can exist without a vault: with email confirmation enabled,
   * signUp() returns no session, so the RLS-protected insert cannot run at that
   * moment. Such a user lands here already signed in, and previously the only
   * advice was "visit /login to create one" - which does nothing when you are
   * already authenticated. That was a loop with no exit.
   */
  const handleCreateVault = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!userId) return;
    if (passphrase.length < 12) {
      setStatus('Passphrase must be at least 12 characters.');
      return;
    }

    setStatus(null);
    try {
      const supabase = browserClient();

      // Never overwrite an existing row: a new salt would orphan every file
      // already encrypted under the old one.
      const { data: existing } = await supabase
        .from('user_keys')
        .select('user_id')
        .eq('user_id', userId)
        .maybeSingle();
      if (existing) {
        setStatus('A vault already exists for this account. Reload the page.');
        return;
      }

      const salt = generateSalt();
      const code = generateRecoveryCode();
      const extractable = await deriveExtractableKey(passphrase, salt);

      const [wrapped, verifier] = await Promise.all([
        wrapKeyWithRecoveryCode(extractable, code, salt),
        createVerifier(extractable),
      ]);

      const { error: insertError } = await supabase.from('user_keys').insert({
        user_id: userId,
        kdf_salt: bytesToBase64(salt),
        kdf_iterations: PBKDF2_ITERATIONS,
        recovery_wrapped_key: wrapped,
        passphrase_verifier: verifier,
      });
      if (insertError) throw insertError;

      // Shown once. Surface it before unlocking so it cannot be missed.
      setNewRecoveryCode(code);
      setKeyMaterial({
        kdf_salt: bytesToBase64(salt),
        kdf_iterations: PBKDF2_ITERATIONS,
        passphrase_verifier: verifier,
      });
    } catch (err) {
      setStatus(err instanceof Error ? err.message : 'Could not create the vault.');
    } finally {
      setPassphrase('');
    }
  };

  const handleUnlock = async (event: React.FormEvent) => {
    event.preventDefault();
    if (!keyMaterial) return;
    try {
      await unlock(
        passphrase,
        keyMaterial.kdf_salt,
        keyMaterial.kdf_iterations,
        keyMaterial.passphrase_verifier,
      );
    } finally {
      // Clear the passphrase from component state either way. It is never
      // stored, logged or transmitted.
      setPassphrase('');
    }
  };

  const handleUpload = async (event: React.ChangeEvent<HTMLInputElement>) => {
    const selected = event.target.files?.[0];
    if (!selected || !key || !userId || !keyMaterial) return;

    setStatus(null);
    try {
      await uploadFile(selected, key, userId, keyMaterial.kdf_salt, setProgress);
      setStatus(`Uploaded ${selected.name}`);
      await loadFiles();
    } catch (err) {
      setStatus(err instanceof Error ? err.message : 'Upload failed');
    } finally {
      setProgress(null);
      // Reset so selecting the same file again re-fires the change event.
      if (fileInputRef.current) fileInputRef.current.value = '';
    }
  };

  const handleDownload = async (file: DecryptedFile) => {
    if (!key) return;
    setBusyKey(file.object_key);
    setStatus(null);
    try {
      const { bytes, metadata } = await downloadFile(file, key, setProgress);
      saveToDisk(bytes, metadata);
    } catch (err) {
      setStatus(err instanceof Error ? err.message : 'Download failed');
    } finally {
      setBusyKey(null);
      setProgress(null);
    }
  };

  const handleDelete = async (file: DecryptedFile) => {
    if (!confirm(`Delete ${file.metadata.filename}? This cannot be undone.`)) return;
    setBusyKey(file.object_key);
    try {
      const res = await fetch('/api/files', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ objectKey: file.object_key }),
      });
      if (!res.ok) throw new Error('Delete failed');
      await loadFiles();
      setStatus(`Deleted ${file.metadata.filename}`);
    } catch (err) {
      setStatus(err instanceof Error ? err.message : 'Delete failed');
    } finally {
      setBusyKey(null);
    }
  };

  // --- Render --------------------------------------------------------------

  if (checkingSession) {
    return <p className="muted">Loading…</p>;
  }

  if (!userId) {
    return (
      <>
        <h1>Personal Vault</h1>
        {status ? (
          <div className="banner banner-red" role="alert">
            {status}
          </div>
        ) : (
          <p className="muted">Sign in to access your documents.</p>
        )}
        <a className="btn btn-primary" href="/login">
          Sign in
        </a>
      </>
    );
  }

  // Recovery code is shown exactly once, immediately after the vault is created.
  if (newRecoveryCode) {
    return (
      <>
        <h1>Save your recovery code</h1>
        <div className="banner banner-red">
          <strong>This is shown once and cannot be retrieved later.</strong>
        </div>
        <p>Write it down and keep it somewhere safe, away from this device.</p>
        <p className="mono card recovery-code">{newRecoveryCode}</p>
        <div className="banner banner-amber">
          If you lose <strong>both</strong> your passphrase and this code, your files
          cannot be decrypted by anyone — including us. That is how end-to-end
          encryption works, and it is why this warning is here.
        </div>
        <button
          type="button"
          className="btn-primary"
          onClick={() => setNewRecoveryCode(null)}
        >
          I have saved it
        </button>
      </>
    );
  }

  // No key material yet: this account was created but never provisioned. Offer
  // to set it up here rather than sending the user to /login, which does
  // nothing when they are already signed in.
  if (!keyMaterial) {
    return (
      <>
        <h1>Set up your vault</h1>
        <p className="muted">
          Choose the passphrase that will encrypt your files. It never leaves this
          browser, and it is separate from your account password.
        </p>
        <form onSubmit={handleCreateVault} className="stack w-full-form">
          <div>
            <label htmlFor="new-passphrase">Encryption passphrase</label>
            <input
              id="new-passphrase"
              type="password"
              autoComplete="new-password"
              value={passphrase}
              onChange={(e) => setPassphrase(e.target.value)}
              required
              minLength={12}
            />
            <p className="faint">
              At least 12 characters. Four random words works well and is easier to
              type on a phone than one long string.
            </p>
          </div>
          <button type="submit" className="btn-primary">
            Create vault
          </button>
          {status && (
            <div className="banner banner-red" role="alert">
              {status}
            </div>
          )}
        </form>
      </>
    );
  }

  if (!isUnlocked) {
    return (
      <>
        <h1>Unlock</h1>
        <p className="muted">
          Your passphrase decrypts your files in this browser. It is never sent to the
          server.
        </p>
        <form onSubmit={handleUnlock} className="stack w-full-form">
          <div>
            <label htmlFor="passphrase">Passphrase</label>
            <input
              id="passphrase"
              type="password"
              autoComplete="current-password"
              value={passphrase}
              onChange={(e) => setPassphrase(e.target.value)}
              required
            />
          </div>
          <button type="submit" className="btn-primary" disabled={isDeriving}>
            {isDeriving ? 'Deriving key…' : 'Unlock'}
          </button>
          {keyError && (
            <div className="banner banner-red" role="alert">
              {keyError}
            </div>
          )}
        </form>
      </>
    );
  }

  const visible = searchFiles(files, query);

  return (
    <>
      <div className="row between wrap gap-05">
        <h1 className="m-0">Documents</h1>
        <button type="button" onClick={lock}>
          Lock
        </button>
      </div>

      {quota && (
        <p className="faint">
          {formatBytes(quota.used)} of {formatBytes(quota.limit)} used · {files.length} file
          {files.length === 1 ? '' : 's'}
        </p>
      )}

      <div className="stack my-1">
        <div>
          <label htmlFor="search">Search</label>
          <input
            id="search"
            type="search"
            placeholder="Filename, tag or note"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
        </div>

        <div>
          {/* No `accept` filter: iOS surfaces Photos, iCloud Drive and Files
              differently, and a restrictive accept list hides valid sources. */}
          <label htmlFor="upload">Add a document</label>
          <input id="upload" ref={fileInputRef} type="file" onChange={handleUpload} />
        </div>
      </div>

      {progress && (
        <div className="card" role="status">
          <div className="row-between">
            <span className="capitalize">{progress.stage}…</span>
            <span className="faint">{Math.round(progress.fraction * 100)}%</span>
          </div>
          <div className="meter mt-05">
            <div
              className="meter-fill green"
              style={{ '--fill': `${progress.fraction * 100}%` } as CSSProperties}
            />
          </div>
        </div>
      )}

      {status && (
        <div className="banner banner-amber" role="status">
          {status}
        </div>
      )}

      <FileList
        files={visible}
        busyKey={busyKey}
        onDownload={handleDownload}
        onDelete={handleDelete}
      />
    </>
  );
}
