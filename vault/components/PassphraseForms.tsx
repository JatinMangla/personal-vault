'use client';

/**
 * The two forms that rewrap the vault's data key: recovering with the recovery
 * code, and changing the passphrase. Presentation only - the key work is in
 * lib/vault-keys.ts and the saving is in app/page.tsx.
 *
 * Both ask for the new passphrase twice. A typo here is not fatal (the
 * recovery code still opens the vault) but it is an avoidable trip back to it.
 */

import { useState } from 'react';
import { MIN_PASSPHRASE_LENGTH } from '@/lib/vault-keys';

function NewPassphraseFields({
  value,
  confirm,
  onChange,
  onConfirm,
}: {
  value: string;
  confirm: string;
  onChange: (v: string) => void;
  onConfirm: (v: string) => void;
}) {
  return (
    <>
      <div>
        <label htmlFor="new-passphrase">New passphrase</label>
        <input
          id="new-passphrase"
          type="password"
          autoComplete="new-password"
          value={value}
          onChange={(e) => onChange(e.target.value)}
          required
          minLength={MIN_PASSPHRASE_LENGTH}
        />
        <p className="faint">
          At least {MIN_PASSPHRASE_LENGTH} characters. Four random words works well and
          is easier to type on a phone than one long string.
        </p>
      </div>
      <div>
        <label htmlFor="confirm-passphrase">New passphrase again</label>
        <input
          id="confirm-passphrase"
          type="password"
          autoComplete="new-password"
          value={confirm}
          onChange={(e) => onConfirm(e.target.value)}
          required
        />
      </div>
    </>
  );
}

export function RecoverForm({
  busy,
  error,
  onSubmit,
  onCancel,
}: {
  busy: boolean;
  /** Set by the key provider when opening fails. */
  error: string | null;
  onSubmit: (code: string, newPassphrase: string) => Promise<void>;
  onCancel: () => void;
}) {
  const [code, setCode] = useState('');
  const [next, setNext] = useState('');
  const [confirm, setConfirm] = useState('');
  const [mismatch, setMismatch] = useState(false);

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    if (next !== confirm) {
      setMismatch(true);
      return;
    }
    setMismatch(false);
    try {
      await onSubmit(code, next);
    } catch {
      // Shown through `error`.
    } finally {
      setNext('');
      setConfirm('');
    }
  };

  return (
    <form onSubmit={submit} className="stack w-full-form">
      <div>
        <label htmlFor="recovery-code">Recovery code</label>
        <input
          id="recovery-code"
          className="mono"
          autoComplete="off"
          autoCapitalize="characters"
          spellCheck={false}
          placeholder="XXXXX-XXXXX-XXXXX-XXXXX"
          value={code}
          onChange={(e) => setCode(e.target.value)}
          required
        />
      </div>
      <NewPassphraseFields
        value={next}
        confirm={confirm}
        onChange={setNext}
        onConfirm={setConfirm}
      />
      <button type="submit" className="btn-primary" disabled={busy}>
        {busy ? 'Recovering…' : 'Recover and set passphrase'}
      </button>
      {(mismatch || error) && (
        <div className="banner banner-red" role="alert">
          {mismatch ? 'The two new passphrases do not match.' : error}
        </div>
      )}
      <button type="button" onClick={onCancel}>
        Back to unlock
      </button>
    </form>
  );
}

export function ChangePassphraseForm({
  onSubmit,
  onCancel,
}: {
  onSubmit: (current: string, next: string) => Promise<void>;
  onCancel: () => void;
}) {
  const [current, setCurrent] = useState('');
  const [next, setNext] = useState('');
  const [confirm, setConfirm] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async (event: React.FormEvent) => {
    event.preventDefault();
    if (next !== confirm) {
      setError('The two new passphrases do not match.');
      return;
    }
    setBusy(true);
    setError(null);
    try {
      await onSubmit(current, next);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Could not change the passphrase.');
    } finally {
      setBusy(false);
      setCurrent('');
      setNext('');
      setConfirm('');
    }
  };

  return (
    <form onSubmit={submit} className="stack w-full-form card my-1">
      <div>
        <label htmlFor="current-passphrase">Current passphrase</label>
        <input
          id="current-passphrase"
          type="password"
          autoComplete="current-password"
          value={current}
          onChange={(e) => setCurrent(e.target.value)}
          required
        />
      </div>
      <NewPassphraseFields
        value={next}
        confirm={confirm}
        onChange={setNext}
        onConfirm={setConfirm}
      />
      <button type="submit" className="btn-primary" disabled={busy}>
        {busy ? 'Changing…' : 'Change passphrase'}
      </button>
      {error && (
        <div className="banner banner-red" role="alert">
          {error}
        </div>
      )}
      <button type="button" onClick={onCancel}>
        Cancel
      </button>
    </form>
  );
}
