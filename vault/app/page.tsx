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

  // --- Session -------------------------------------------------------------

  useEffect(() => {
    const supabase = browserClient();
    void (async () => {
      const {
        data: { user },
      } = await supabase.auth.getUser();

      if (user) {
        setUserId(user.id);
        const { data } = await supabase
          .from('user_keys')
          .select('kdf_salt, kdf_iterations, passphrase_verifier')
          .eq('user_id', user.id)
          .maybeSingle();
        setKeyMaterial((data as KeyMaterial | null) ?? null);
      }
      setCheckingSession(false);
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
        <p className="muted">Sign in to access your documents.</p>
        <a className="btn btn-primary" href="/login">
          Sign in
        </a>
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
          <button type="submit" className="btn-primary" disabled={isDeriving || !keyMaterial}>
            {isDeriving ? 'Deriving key…' : 'Unlock'}
          </button>
          {keyError && (
            <div className="banner banner-red" role="alert">
              {keyError}
            </div>
          )}
          {!keyMaterial && (
            <p className="faint">
              No vault has been set up for this account yet. Visit{' '}
              <a href="/login">setup</a> to create one.
            </p>
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
