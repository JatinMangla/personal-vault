'use client';

/**
 * Holds the derived encryption key for the session.
 *
 * THE KEY LIVES IN MEMORY ONLY. Never localStorage, never sessionStorage, never
 * IndexedDB, never a cookie. Web storage survives tab close and is readable by
 * any script that achieves XSS on this origin; a key sitting there converts a
 * scripting bug into total disclosure of the archive.
 *
 * The consequence to accept: a page refresh loses the key and the user
 * re-enters their passphrase. That is the correct trade-off for an E2EE vault,
 * and it is why the CryptoKey is also non-extractable — even code holding a
 * reference cannot serialise it back out.
 */

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { deriveKey, base64ToBytes, encryptMetadata, decryptMetadata } from '@/lib/crypto';

interface VaultKeyState {
  key: CryptoKey | null;
  isUnlocked: boolean;
  unlock: (passphrase: string, saltB64: string, iterations: number, verifier: string | null) => Promise<void>;
  lock: () => void;
  /** True while PBKDF2 is running — 600k iterations takes a noticeable moment. */
  isDeriving: boolean;
  error: string | null;
}

const VaultKeyContext = createContext<VaultKeyState | null>(null);

/** Constant encrypted under the derived key, to verify a passphrase locally. */
const VERIFIER_PLAINTEXT = 'personal-vault-verifier-v1';

/** Auto-lock after this long without interaction. */
const IDLE_LOCK_MS = 30 * 60 * 1000;

export function VaultKeyProvider({ children }: { children: React.ReactNode }) {
  // A ref rather than only state, so the key is not captured in stale closures
  // and can be cleared synchronously on logout.
  const keyRef = useRef<CryptoKey | null>(null);
  const [isUnlocked, setIsUnlocked] = useState(false);
  const [isDeriving, setIsDeriving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const lock = useCallback(() => {
    keyRef.current = null;
    setIsUnlocked(false);
    setError(null);
  }, []);

  const unlock = useCallback(
    async (passphrase: string, saltB64: string, iterations: number, verifier: string | null) => {
      setIsDeriving(true);
      setError(null);
      try {
        const salt = base64ToBytes(saltB64);
        const derived = await deriveKey(passphrase, salt, iterations);

        // If a verifier exists, check the passphrase now rather than letting the
        // user discover it was wrong after downloading a file that fails to
        // decrypt.
        if (verifier) {
          try {
            const value = await decryptMetadata<string>(verifier, derived);
            if (value !== VERIFIER_PLAINTEXT) throw new Error('mismatch');
          } catch {
            throw new Error('Incorrect passphrase');
          }
        }

        keyRef.current = derived;
        setIsUnlocked(true);
      } catch (err) {
        keyRef.current = null;
        setIsUnlocked(false);
        setError(err instanceof Error ? err.message : 'Could not unlock the vault');
        throw err;
      } finally {
        setIsDeriving(false);
      }
    },
    [],
  );

  // Idle auto-lock. A vault left unlocked on a phone on a table is the most
  // likely real-world exposure, well ahead of any remote attack.
  useEffect(() => {
    if (!isUnlocked) return;

    let timer: ReturnType<typeof setTimeout>;
    const reset = () => {
      clearTimeout(timer);
      timer = setTimeout(lock, IDLE_LOCK_MS);
    };

    const windowEvents: Array<keyof WindowEventMap> = ['pointerdown', 'keydown'];
    for (const e of windowEvents) window.addEventListener(e, reset, { passive: true });
    // visibilitychange fires on document, not window. It matters here: returning
    // to a backgrounded tab should restart the idle countdown.
    document.addEventListener('visibilitychange', reset, { passive: true });
    reset();

    return () => {
      clearTimeout(timer);
      for (const e of windowEvents) window.removeEventListener(e, reset);
      document.removeEventListener('visibilitychange', reset);
    };
  }, [isUnlocked, lock]);

  const value = useMemo<VaultKeyState>(
    () => ({
      get key() {
        return keyRef.current;
      },
      isUnlocked,
      unlock,
      lock,
      isDeriving,
      error,
    }),
    [isUnlocked, unlock, lock, isDeriving, error],
  );

  return <VaultKeyContext.Provider value={value}>{children}</VaultKeyContext.Provider>;
}

export function useVaultKey(): VaultKeyState {
  const ctx = useContext(VaultKeyContext);
  if (!ctx) throw new Error('useVaultKey must be used inside a VaultKeyProvider');
  return ctx;
}

/** Build the verifier blob at setup time. */
export async function createVerifier(key: CryptoKey): Promise<string> {
  return encryptMetadata(VERIFIER_PLAINTEXT, key);
}
