/**
 * Vault key management: create, open, recover and re-key - browser only.
 *
 * ENVELOPE MODEL. A random data key encrypts every file. It is stored only
 * wrapped, under a key derived from each secret that may open the vault:
 *
 *   passphrase_wrapped_key  under PBKDF2(passphrase,    passphrase_salt)
 *   recovery_wrapped_key    under PBKDF2(recovery code, kdf_salt)
 *
 * So changing the passphrase, or recovering with the code and choosing a new
 * one, rewraps the data key and never touches a file.
 *
 * ACCOUNTS FROM BEFORE THE ENVELOPE have no passphrase_wrapped_key. Their data
 * key is PBKDF2(passphrase, kdf_salt) itself - which is exactly what
 * recovery_wrapped_key already wraps - so opening one derives that key as
 * before and ALSO returns a background upgrade: the same key, wrapped for the
 * passphrase. Once saved, the account is on the envelope for good.
 *
 * SPEED. Opening costs one PBKDF2 on both paths, as it always has. The legacy
 * upgrade's extra PBKDF2 runs in the background after the vault is already
 * open, so the user never waits on it.
 *
 * No Supabase here: this module is pure crypto over plain values, so the
 * callers own the reads and writes and the whole of it is unit-testable.
 */

import {
  PBKDF2_ITERATIONS,
  base64ToBytes,
  bytesToBase64,
  decryptMetadata,
  deriveExtractableKey,
  encryptMetadata,
  generateDataKey,
  generateRecoveryCode,
  generateSalt,
  toSessionKey,
  unwrapKeyWithRecoveryCode,
  unwrapKeyWithSecret,
  wrapKeyWithRecoveryCode,
  wrapKeyWithSecret,
} from './crypto';

/** Constant encrypted under the data key, to verify a key locally. */
const VERIFIER_PLAINTEXT = 'personal-vault-verifier-v1';

/** Minimum passphrase length, enforced here and in every form. */
export const MIN_PASSPHRASE_LENGTH = 12;

/** The user_keys columns this module reads. */
export interface KeyMaterial {
  kdf_salt: string;
  kdf_iterations: number;
  passphrase_verifier: string | null;
  recovery_wrapped_key: string | null;
  passphrase_salt: string | null;
  passphrase_wrapped_key: string | null;
}

/** The select list matching `KeyMaterial`, so callers cannot drift from it. */
export const KEY_MATERIAL_COLUMNS =
  'kdf_salt, kdf_iterations, passphrase_verifier, recovery_wrapped_key, passphrase_salt, passphrase_wrapped_key';

/** The only user_keys columns a client may UPDATE (see migration 0006). */
export interface PassphraseWrap {
  passphrase_salt: string;
  passphrase_wrapped_key: string;
}

function requireLength(passphrase: string): void {
  if (passphrase.length < MIN_PASSPHRASE_LENGTH) {
    throw new Error(`Passphrase must be at least ${MIN_PASSPHRASE_LENGTH} characters.`);
  }
}

async function checkVerifier(key: CryptoKey, verifier: string | null, message: string) {
  if (!verifier) return;
  let value: unknown;
  try {
    value = await decryptMetadata<string>(verifier, key);
  } catch {
    throw new Error(message);
  }
  if (value !== VERIFIER_PLAINTEXT) throw new Error(message);
}

async function wrapForPassphrase(
  dataKey: CryptoKey,
  passphrase: string,
  iterations: number,
): Promise<PassphraseWrap> {
  const salt = generateSalt();
  return {
    passphrase_salt: bytesToBase64(salt),
    passphrase_wrapped_key: await wrapKeyWithSecret(dataKey, passphrase, salt, iterations),
  };
}

/**
 * Key material for a brand-new vault, plus the recovery code to show ONCE.
 *
 * The two wraps are independent PBKDF2 runs, so they go in parallel.
 */
export async function createVaultKeys(passphrase: string): Promise<{
  row: KeyMaterial;
  recoveryCode: string;
  sessionKey: CryptoKey;
}> {
  requireLength(passphrase);
  const dataKey = await generateDataKey();
  const kdfSalt = generateSalt();
  const recoveryCode = generateRecoveryCode();

  const [recoveryWrapped, wrap, verifier, sessionKey] = await Promise.all([
    wrapKeyWithRecoveryCode(dataKey, recoveryCode, kdfSalt),
    wrapForPassphrase(dataKey, passphrase, PBKDF2_ITERATIONS),
    encryptMetadata(VERIFIER_PLAINTEXT, dataKey),
    toSessionKey(dataKey),
  ]);

  return {
    row: {
      kdf_salt: bytesToBase64(kdfSalt),
      kdf_iterations: PBKDF2_ITERATIONS,
      recovery_wrapped_key: recoveryWrapped,
      passphrase_verifier: verifier,
      ...wrap,
    },
    recoveryCode,
    sessionKey,
  };
}

/**
 * Open the vault with the passphrase.
 *
 * `upgrade` is non-null only for a pre-envelope account: a promise of the
 * passphrase wrapping to save. Fire and forget it - the key is usable now.
 * With `extractable` the returned key can be rewrapped (change passphrase).
 */
export async function openVault(
  passphrase: string,
  km: KeyMaterial,
  extractable = false,
): Promise<{ key: CryptoKey; upgrade: Promise<PassphraseWrap> | null }> {
  const wrong = 'Incorrect passphrase';

  if (km.passphrase_wrapped_key && km.passphrase_salt) {
    let key: CryptoKey;
    try {
      key = await unwrapKeyWithSecret(
        km.passphrase_wrapped_key,
        passphrase,
        base64ToBytes(km.passphrase_salt),
        km.kdf_iterations,
        extractable,
      );
    } catch {
      throw new Error(wrong);
    }
    // GCM already proved the passphrase; the verifier additionally proves this
    // is the SAME data key the files were written under.
    await checkVerifier(key, km.passphrase_verifier, wrong);
    return { key, upgrade: null };
  }

  // Legacy account: the data key is PBKDF2(passphrase, kdf_salt).
  const dataKey = await deriveExtractableKey(
    passphrase,
    base64ToBytes(km.kdf_salt),
    km.kdf_iterations,
  );
  await checkVerifier(dataKey, km.passphrase_verifier, wrong);

  // Without a verifier there is no way to tell a right passphrase from a wrong
  // one, and wrapping a wrong key would lock the owner out. Do not upgrade.
  const upgrade = km.passphrase_verifier
    ? wrapForPassphrase(dataKey, passphrase, km.kdf_iterations)
    : null;

  return { key: extractable ? dataKey : await toSessionKey(dataKey), upgrade };
}

/**
 * Normalise a typed recovery code: case, spaces and dashes do not matter, and
 * the Crockford look-alikes O, I and L read as 0, 1 and 1 (the alphabet never
 * contains them, so this can only fix a misreading).
 */
export function normaliseRecoveryCode(input: string): string {
  const code = input
    .toUpperCase()
    .replace(/O/g, '0')
    .replace(/[IL]/g, '1')
    .replace(/[^0-9A-Z]/g, '');
  if (code.length !== 20) throw new Error('A recovery code has 20 characters.');
  return code;
}

/**
 * Open the vault with the recovery code and set a new passphrase.
 * Returns the session key and the new wrapping, which the caller must save.
 */
export async function recoverVault(
  recoveryCode: string,
  newPassphrase: string,
  km: KeyMaterial,
): Promise<{ key: CryptoKey; wrap: PassphraseWrap }> {
  requireLength(newPassphrase);
  if (!km.recovery_wrapped_key) {
    throw new Error('This vault has no recovery code on record.');
  }
  const wrong = 'That recovery code does not open this vault.';

  let dataKey: CryptoKey;
  try {
    dataKey = await unwrapKeyWithRecoveryCode(
      km.recovery_wrapped_key,
      normaliseRecoveryCode(recoveryCode),
      base64ToBytes(km.kdf_salt),
      /* extractable */ true,
    );
  } catch (err) {
    if (err instanceof Error && err.message.startsWith('A recovery code')) throw err;
    throw new Error(wrong);
  }
  await checkVerifier(dataKey, km.passphrase_verifier, wrong);

  const [wrap, key] = await Promise.all([
    wrapForPassphrase(dataKey, newPassphrase, km.kdf_iterations),
    toSessionKey(dataKey),
  ]);
  return { key, wrap };
}

/** Rewrap the data key under a new passphrase. No file is re-encrypted. */
export async function changePassphrase(
  current: string,
  next: string,
  km: KeyMaterial,
): Promise<PassphraseWrap> {
  requireLength(next);
  const { key } = await openVault(current, km, /* extractable */ true);
  return wrapForPassphrase(key, next, km.kdf_iterations);
}
