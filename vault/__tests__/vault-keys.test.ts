/**
 * Envelope key management - create, open, upgrade, recover, change passphrase.
 *
 * The case that matters most is the LEGACY account: one built exactly the way
 * production accounts were built before the envelope (data key =
 * PBKDF2(passphrase, kdf_salt)). Every path below must still open files that
 * were encrypted under that key, because they are real files, never re-encrypted.
 */

import { describe, it, expect } from 'vitest';
import {
  bytesToBase64,
  decryptMetadata,
  deriveExtractableKey,
  encryptMetadata,
  generateRecoveryCode,
  generateSalt,
  wrapKeyWithRecoveryCode,
  PBKDF2_ITERATIONS,
} from '../lib/crypto';
import {
  changePassphrase,
  createVaultKeys,
  normaliseRecoveryCode,
  openVault,
  recoverVault,
  type KeyMaterial,
} from '../lib/vault-keys';

const PASS = 'correct horse battery staple';
const NEW_PASS = 'purple elephant quiet river';
const SECRET = { note: 'a file encrypted before any of this changed' };

/** A user_keys row as production wrote it before the envelope existed. */
async function legacyAccount(withVerifier = true) {
  const salt = generateSalt();
  const code = generateRecoveryCode();
  const dataKey = await deriveExtractableKey(PASS, salt);
  const km: KeyMaterial = {
    kdf_salt: bytesToBase64(salt),
    kdf_iterations: PBKDF2_ITERATIONS,
    recovery_wrapped_key: await wrapKeyWithRecoveryCode(dataKey, code, salt),
    // The verifier constant is part of the stored format; pinned here on purpose.
    passphrase_verifier: withVerifier
      ? await encryptMetadata('personal-vault-verifier-v1', dataKey)
      : null,
    passphrase_salt: null,
    passphrase_wrapped_key: null,
  };
  const existingFile = await encryptMetadata(SECRET, dataKey);
  return { km, code, existingFile };
}

describe('new vaults', () => {
  it('open with the passphrase and read what the session key wrote', async () => {
    const { row, sessionKey } = await createVaultKeys(PASS);
    const file = await encryptMetadata(SECRET, sessionKey);
    const { key, upgrade } = await openVault(PASS, row);
    expect(upgrade).toBeNull();
    expect(await decryptMetadata(file, key)).toEqual(SECRET);
  });

  it('reject a wrong passphrase with a clear message', async () => {
    const { row } = await createVaultKeys(PASS);
    await expect(openVault(NEW_PASS, row)).rejects.toThrow('Incorrect passphrase');
  });

  it('refuse a short passphrase', async () => {
    await expect(createVaultKeys('too short')).rejects.toThrow(/at least 12/);
  });

  it('keep the session key non-extractable', async () => {
    const { sessionKey } = await createVaultKeys(PASS);
    expect(sessionKey.extractable).toBe(false);
    const { row } = await createVaultKeys(PASS);
    expect((await openVault(PASS, row)).key.extractable).toBe(false);
  });
});

describe('legacy accounts', () => {
  it('still open their existing files, and offer an upgrade', async () => {
    const { km, existingFile } = await legacyAccount();
    const { key, upgrade } = await openVault(PASS, km);
    expect(await decryptMetadata(existingFile, key)).toEqual(SECRET);
    expect(key.extractable).toBe(false);
    expect(upgrade).not.toBeNull();
  });

  it('after the upgrade, open through the envelope and read the same files', async () => {
    const { km, existingFile } = await legacyAccount();
    const wrap = await (await openVault(PASS, km)).upgrade!;
    const upgraded = { ...km, ...wrap };
    const { key, upgrade } = await openVault(PASS, upgraded);
    expect(upgrade).toBeNull();
    expect(await decryptMetadata(existingFile, key)).toEqual(SECRET);
  });

  it('reject a wrong passphrase and offer no upgrade', async () => {
    const { km } = await legacyAccount();
    await expect(openVault(NEW_PASS, km)).rejects.toThrow('Incorrect passphrase');
  });

  it('are never upgraded without a verifier to prove the key', async () => {
    const { km } = await legacyAccount(false);
    expect((await openVault(PASS, km)).upgrade).toBeNull();
  });
});

describe('recovery', () => {
  it('opens a legacy vault with the code and sets a new passphrase', async () => {
    const { km, code, existingFile } = await legacyAccount();
    const { key, wrap } = await recoverVault(code, NEW_PASS, km);
    expect(await decryptMetadata(existingFile, key)).toEqual(SECRET);

    const after = { ...km, ...wrap };
    const reopened = await openVault(NEW_PASS, after);
    expect(await decryptMetadata(existingFile, reopened.key)).toEqual(SECRET);
    await expect(openVault(PASS, after)).rejects.toThrow('Incorrect passphrase');
  });

  it('works for a new vault too, and the code keeps working afterwards', async () => {
    const { row, recoveryCode, sessionKey } = await createVaultKeys(PASS);
    const file = await encryptMetadata(SECRET, sessionKey);
    const { wrap } = await recoverVault(recoveryCode, NEW_PASS, row);
    const after = { ...row, ...wrap };
    const again = await recoverVault(recoveryCode, PASS, after);
    expect(await decryptMetadata(file, again.key)).toEqual(SECRET);
  });

  it('accepts the code typed loosely', async () => {
    const { km, code } = await legacyAccount();
    const sloppy = ` ${code.toLowerCase().replace(/-/g, ' ').replace(/0/g, 'o')} `;
    await expect(recoverVault(sloppy, NEW_PASS, km)).resolves.toBeDefined();
  });

  it('rejects a wrong code with a clear message', async () => {
    const { km } = await legacyAccount();
    await expect(recoverVault(generateRecoveryCode(), NEW_PASS, km)).rejects.toThrow(
      'That recovery code does not open this vault.',
    );
  });

  it('rejects a code of the wrong length before any key work', async () => {
    const { km } = await legacyAccount();
    await expect(recoverVault('ABCDE', NEW_PASS, km)).rejects.toThrow(/20 characters/);
  });
});

describe('changing the passphrase', () => {
  it('swaps which passphrase opens the vault, and touches no file', async () => {
    const { km, code, existingFile } = await legacyAccount();
    const wrap = await changePassphrase(PASS, NEW_PASS, km);
    const after = { ...km, ...wrap };

    expect(await decryptMetadata(existingFile, (await openVault(NEW_PASS, after)).key)).toEqual(
      SECRET,
    );
    await expect(openVault(PASS, after)).rejects.toThrow('Incorrect passphrase');
    // The recovery code is untouched by a passphrase change.
    await expect(recoverVault(code, PASS, after)).resolves.toBeDefined();
  });

  it('requires the current passphrase', async () => {
    const { row } = await createVaultKeys(PASS);
    await expect(changePassphrase(NEW_PASS, 'another long passphrase', row)).rejects.toThrow(
      'Incorrect passphrase',
    );
  });
});

describe('normaliseRecoveryCode', () => {
  it('ignores case, spacing and dashes, and fixes O/I/L look-alikes', () => {
    expect(normaliseRecoveryCode('abcde-fghjk-mnpqr-stvwx')).toBe('ABCDEFGHJKMNPQRSTVWX');
    expect(normaliseRecoveryCode('o1iL0 00000 00000 00000')).toBe('01110000000000000000');
  });
});
