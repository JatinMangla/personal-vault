/**
 * Crypto core test suite - MANDATORY AND BLOCKING (spec section 5.4).
 *
 * These tests are the reason the vault can be trusted with irreplaceable data.
 * A failure here is a data-loss event in waiting, not a flaky test. Do not skip,
 * do not mark todo, do not weaken an assertion to make a build pass.
 *
 * Runs against Node's Web Crypto implementation, which is the same spec surface
 * the browser exposes, so the code under test is the code that ships.
 */

import { describe, it, expect } from 'vitest';
import {
  CHUNK_SIZE,
  PBKDF2_ITERATIONS,
  IV_LENGTH,
  encryptFile,
  decryptFile,
  deriveKey,
  deriveExtractableKey,
  generateSalt,
  generateObjectKey,
  generateRecoveryCode,
  hashFilename,
  encryptMetadata,
  decryptMetadata,
  wrapKeyWithRecoveryCode,
  unwrapKeyWithRecoveryCode,
  bytesToBase64,
  base64ToBytes,
} from '../lib/crypto';

// Node exposes btoa/atob globally from v16, but be explicit so the suite does
// not depend on ambient globals that differ between runtimes.
if (typeof globalThis.btoa === 'undefined') {
  globalThis.btoa = (s: string) => Buffer.from(s, 'binary').toString('base64');
  globalThis.atob = (s: string) => Buffer.from(s, 'base64').toString('binary');
}

const PASSPHRASE = 'correct horse battery staple';
const OTHER_PASSPHRASE = 'incorrect horse battery staple';

/** Deterministic pseudo-random filler. Avoids allocating from the CSPRNG for
 *  multi-megabyte fixtures, which is slow and pointless for test data. */
function fillPattern(size: number): Uint8Array {
  const out = new Uint8Array(size);
  for (let i = 0; i < size; i++) out[i] = (i * 31 + (i >> 8) * 17) & 0xff;
  return out;
}

async function keyFor(passphrase: string, salt: Uint8Array): Promise<CryptoKey> {
  return deriveKey(passphrase, salt);
}

// ---------------------------------------------------------------------------

describe('round-trip: single chunk', () => {
  it('round-trips UTF-8 text byte-identically', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);
    const plaintext = new TextEncoder().encode(
      'The quick brown fox. Ünïcödé: 日本語 עברית emoji: 🔐📄 done.',
    );

    const { ciphertext, manifest } = await encryptFile(plaintext, key);
    const decrypted = await decryptFile(ciphertext, manifest, key);

    expect(decrypted).toEqual(plaintext);
    expect(new TextDecoder().decode(decrypted)).toBe(new TextDecoder().decode(plaintext));
  });

  it('round-trips arbitrary binary byte-identically', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);
    // Every possible byte value, so a signed/unsigned slip cannot hide.
    const plaintext = new Uint8Array(256);
    for (let i = 0; i < 256; i++) plaintext[i] = i;

    const { ciphertext, manifest } = await encryptFile(plaintext, key);
    const decrypted = await decryptFile(ciphertext, manifest, key);

    expect(decrypted).toEqual(plaintext);
  });

  it('round-trips a zero-byte file', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);
    const plaintext = new Uint8Array(0);

    const { ciphertext, manifest } = await encryptFile(plaintext, key);

    // One chunk holding only the GCM tag, so the file is still authenticated.
    expect(manifest.chunks).toHaveLength(1);
    expect(manifest.plaintextSize).toBe(0);

    const decrypted = await decryptFile(ciphertext, manifest, key);
    expect(decrypted).toEqual(plaintext);
    expect(decrypted.length).toBe(0);
  });

  it('produces different ciphertext for identical plaintext (IV randomisation)', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);
    const plaintext = new TextEncoder().encode('same input every time');

    const a = await encryptFile(plaintext, key);
    const b = await encryptFile(plaintext, key);

    expect(bytesToBase64(a.ciphertext)).not.toBe(bytesToBase64(b.ciphertext));
    expect(a.manifest.chunks[0]!.iv).not.toBe(b.manifest.chunks[0]!.iv);
  });
});

// ---------------------------------------------------------------------------

describe('round-trip: chunk boundaries (spec 5.4)', () => {
  // The spec calls out these three sizes explicitly: an off-by-one in the
  // chunking loop shows up here and nowhere else.
  const cases: Array<[string, number, number]> = [
    ['CHUNK_SIZE - 1', CHUNK_SIZE - 1, 1],
    ['exactly CHUNK_SIZE', CHUNK_SIZE, 1],
    ['CHUNK_SIZE + 1', CHUNK_SIZE + 1, 2],
  ];

  for (const [label, size, expectedChunks] of cases) {
    it(`round-trips ${label} byte-identically`, async () => {
      const salt = generateSalt();
      const key = await keyFor(PASSPHRASE, salt);
      const plaintext = fillPattern(size);

      const { ciphertext, manifest } = await encryptFile(plaintext, key);

      expect(manifest.chunks).toHaveLength(expectedChunks);
      expect(manifest.plaintextSize).toBe(size);

      const decrypted = await decryptFile(ciphertext, manifest, key);

      expect(decrypted.length).toBe(size);
      // Compare via Buffer: a byte-by-byte expect() on 4 MB is unusably slow
      // and produces an unreadable diff on failure.
      expect(Buffer.from(decrypted).equals(Buffer.from(plaintext))).toBe(true);
    });
  }

  it('round-trips a file spanning several chunks', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);
    const size = CHUNK_SIZE * 3 + 12_345;
    const plaintext = fillPattern(size);

    const { ciphertext, manifest } = await encryptFile(plaintext, key);

    expect(manifest.chunks).toHaveLength(4);

    const decrypted = await decryptFile(ciphertext, manifest, key);
    expect(Buffer.from(decrypted).equals(Buffer.from(plaintext))).toBe(true);
  });

  it('preserves chunk order under a shuffled manifest', async () => {
    // Guards the explicit sort in decryptFile: if the wire ever reorders the
    // chunk array, output must still be correct rather than scrambled.
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);
    const plaintext = fillPattern(CHUNK_SIZE * 2 + 500);

    const { ciphertext, manifest } = await encryptFile(plaintext, key);
    const shuffled = { ...manifest, chunks: [...manifest.chunks].reverse() };

    const decrypted = await decryptFile(ciphertext, shuffled, key);
    expect(Buffer.from(decrypted).equals(Buffer.from(plaintext))).toBe(true);
  });
});

// ---------------------------------------------------------------------------

describe('IV uniqueness (spec 5.4: assert over >= 100 chunks)', () => {
  it('gives every chunk of a multi-chunk file a distinct IV', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);
    const plaintext = fillPattern(CHUNK_SIZE * 5 + 1);

    const { manifest } = await encryptFile(plaintext, key);

    const ivs = manifest.chunks.map((c) => c.iv);
    expect(ivs).toHaveLength(6);
    expect(new Set(ivs).size).toBe(ivs.length);
  });

  it('produces 100+ distinct IVs with no collision', async () => {
    // Rather than encrypt 400 MB (slow, and pointless memory pressure), drive
    // the same code path with a small chunk budget by encrypting many small
    // files: each call is an independent draw from the same CSPRNG source.
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);
    const payload = new TextEncoder().encode('x');

    const ivs: string[] = [];
    for (let i = 0; i < 150; i++) {
      const { manifest } = await encryptFile(payload, key);
      ivs.push(manifest.chunks[0]!.iv);
    }

    expect(ivs).toHaveLength(150);
    expect(new Set(ivs).size).toBe(150);
  });

  it('emits IVs of exactly 12 bytes', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);
    const { manifest } = await encryptFile(fillPattern(CHUNK_SIZE + 10), key);

    for (const chunk of manifest.chunks) {
      expect(base64ToBytes(chunk.iv).length).toBe(IV_LENGTH);
    }
  });

  it('never repeats an IV across separate files under the same key', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);

    const a = await encryptFile(fillPattern(CHUNK_SIZE * 2), key);
    const b = await encryptFile(fillPattern(CHUNK_SIZE * 2), key);

    const all = [...a.manifest.chunks, ...b.manifest.chunks].map((c) => c.iv);
    expect(new Set(all).size).toBe(all.length);
  });
});

// ---------------------------------------------------------------------------

describe('wrong passphrase fails cleanly', () => {
  it('throws rather than returning garbage', async () => {
    const salt = generateSalt();
    const goodKey = await keyFor(PASSPHRASE, salt);
    const badKey = await keyFor(OTHER_PASSPHRASE, salt);
    const plaintext = new TextEncoder().encode('sensitive contents');

    const { ciphertext, manifest } = await encryptFile(plaintext, goodKey);

    await expect(decryptFile(ciphertext, manifest, badKey)).rejects.toThrow();
  });

  it('throws on a multi-chunk file with the wrong key', async () => {
    const salt = generateSalt();
    const goodKey = await keyFor(PASSPHRASE, salt);
    const badKey = await keyFor(OTHER_PASSPHRASE, salt);

    const { ciphertext, manifest } = await encryptFile(fillPattern(CHUNK_SIZE + 99), goodKey);

    await expect(decryptFile(ciphertext, manifest, badKey)).rejects.toThrow();
  });

  it('throws when the salt differs, even with the right passphrase', async () => {
    const saltA = generateSalt();
    const saltB = generateSalt();
    const keyA = await keyFor(PASSPHRASE, saltA);
    const keyB = await keyFor(PASSPHRASE, saltB);

    const { ciphertext, manifest } = await encryptFile(
      new TextEncoder().encode('salted'),
      keyA,
    );

    await expect(decryptFile(ciphertext, manifest, keyB)).rejects.toThrow();
  });
});

// ---------------------------------------------------------------------------

describe('tamper detection (GCM authentication)', () => {
  it('rejects a single flipped ciphertext byte', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);
    const plaintext = new TextEncoder().encode('integrity matters');

    const { ciphertext, manifest } = await encryptFile(plaintext, key);

    const tampered = new Uint8Array(ciphertext);
    tampered[0] = tampered[0]! ^ 0x01;

    await expect(decryptFile(tampered, manifest, key)).rejects.toThrow();
  });

  it('rejects tampering in the middle of a multi-chunk file', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);

    const { ciphertext, manifest } = await encryptFile(fillPattern(CHUNK_SIZE * 2), key);

    const tampered = new Uint8Array(ciphertext);
    const mid = Math.floor(tampered.length / 2);
    tampered[mid] = tampered[mid]! ^ 0xff;

    await expect(decryptFile(tampered, manifest, key)).rejects.toThrow();
  });

  it('rejects a flipped bit in the GCM tag', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);

    const { ciphertext, manifest } = await encryptFile(
      new TextEncoder().encode('tag check'),
      key,
    );

    const tampered = new Uint8Array(ciphertext);
    tampered[tampered.length - 1] = tampered[tampered.length - 1]! ^ 0x80;

    await expect(decryptFile(tampered, manifest, key)).rejects.toThrow();
  });

  it('rejects a substituted IV', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);

    const { ciphertext, manifest } = await encryptFile(
      new TextEncoder().encode('iv binding'),
      key,
    );

    const forged = {
      ...manifest,
      chunks: [{ ...manifest.chunks[0]!, iv: bytesToBase64(new Uint8Array(IV_LENGTH)) }],
    };

    await expect(decryptFile(ciphertext, forged, key)).rejects.toThrow();
  });

  it('rejects truncated ciphertext', async () => {
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);

    const { ciphertext, manifest } = await encryptFile(fillPattern(CHUNK_SIZE + 1000), key);

    const truncated = ciphertext.subarray(0, ciphertext.length - 50);

    await expect(decryptFile(truncated, manifest, key)).rejects.toThrow();
  });

  it('rejects two chunks swapped in place', async () => {
    // Reordering ciphertext without touching the manifest must not silently
    // yield rearranged plaintext.
    const salt = generateSalt();
    const key = await keyFor(PASSPHRASE, salt);
    const plaintext = fillPattern(CHUNK_SIZE * 2);

    const { ciphertext, manifest } = await encryptFile(plaintext, key);

    const len = manifest.chunks[0]!.ciphertextLength;
    const swapped = new Uint8Array(ciphertext.length);
    swapped.set(ciphertext.subarray(len, len * 2), 0);
    swapped.set(ciphertext.subarray(0, len), len);

    await expect(decryptFile(swapped, manifest, key)).rejects.toThrow();
  });
});

// ---------------------------------------------------------------------------

describe('key derivation', () => {
  it('is deterministic for the same passphrase and salt', async () => {
    const salt = generateSalt();
    const k1 = await deriveExtractableKey(PASSPHRASE, salt);
    const k2 = await deriveExtractableKey(PASSPHRASE, salt);

    const r1 = new Uint8Array(await crypto.subtle.exportKey('raw', k1));
    const r2 = new Uint8Array(await crypto.subtle.exportKey('raw', k2));

    expect(Buffer.from(r1).equals(Buffer.from(r2))).toBe(true);
    expect(r1.length).toBe(32); // AES-256
  });

  it('differs for different salts', async () => {
    const k1 = await deriveExtractableKey(PASSPHRASE, generateSalt());
    const k2 = await deriveExtractableKey(PASSPHRASE, generateSalt());

    const r1 = new Uint8Array(await crypto.subtle.exportKey('raw', k1));
    const r2 = new Uint8Array(await crypto.subtle.exportKey('raw', k2));

    expect(Buffer.from(r1).equals(Buffer.from(r2))).toBe(false);
  });

  it('differs for different passphrases under the same salt', async () => {
    const salt = generateSalt();
    const k1 = await deriveExtractableKey(PASSPHRASE, salt);
    const k2 = await deriveExtractableKey(OTHER_PASSPHRASE, salt);

    const r1 = new Uint8Array(await crypto.subtle.exportKey('raw', k1));
    const r2 = new Uint8Array(await crypto.subtle.exportKey('raw', k2));

    expect(Buffer.from(r1).equals(Buffer.from(r2))).toBe(false);
  });

  it('uses at least 600k iterations by default', () => {
    expect(PBKDF2_ITERATIONS).toBeGreaterThanOrEqual(600_000);
  });

  it('refuses a weakened iteration count', async () => {
    await expect(deriveKey(PASSPHRASE, generateSalt(), 1000)).rejects.toThrow(
      /600000/,
    );
  });

  it('produces a non-extractable key on the normal path', async () => {
    const key = await deriveKey(PASSPHRASE, generateSalt());
    expect(key.extractable).toBe(false);
    await expect(crypto.subtle.exportKey('raw', key)).rejects.toThrow();
  });

  it('emits a 16-byte salt', () => {
    expect(generateSalt().length).toBe(16);
    expect(bytesToBase64(generateSalt())).not.toBe(bytesToBase64(generateSalt()));
  });
});

// ---------------------------------------------------------------------------

describe('metadata encryption', () => {
  it('round-trips a structured object', async () => {
    const key = await keyFor(PASSPHRASE, generateSalt());
    const meta = {
      filename: 'Tax Return 2025.pdf',
      tags: ['tax', 'finance'],
      notes: 'Filed 2025-07-14. Ünïcödé safe. 🔐',
      size: 482_113,
    };

    const sealed = await encryptMetadata(meta, key);
    expect(sealed).not.toContain('Tax Return');

    expect(await decryptMetadata<typeof meta>(sealed, key)).toEqual(meta);
  });

  it('fails with the wrong key', async () => {
    const salt = generateSalt();
    const good = await keyFor(PASSPHRASE, salt);
    const bad = await keyFor(OTHER_PASSPHRASE, salt);

    const sealed = await encryptMetadata({ filename: 'secret.pdf' }, good);

    await expect(decryptMetadata(sealed, bad)).rejects.toThrow();
  });

  it('rejects a payload too short to hold an IV', async () => {
    const key = await keyFor(PASSPHRASE, generateSalt());
    await expect(decryptMetadata(bytesToBase64(new Uint8Array(4)), key)).rejects.toThrow(
      /too short/,
    );
  });
});

// ---------------------------------------------------------------------------

describe('recovery code', () => {
  it('recovers the key material when the passphrase is lost', async () => {
    const salt = generateSalt();
    const key = await deriveExtractableKey(PASSPHRASE, salt);
    const code = generateRecoveryCode();

    const wrapped = await wrapKeyWithRecoveryCode(key, code, salt);
    const recovered = await unwrapKeyWithRecoveryCode(wrapped, code, salt);

    // The recovered key must decrypt what the original key encrypted.
    const plaintext = new TextEncoder().encode('recovered contents');
    const { ciphertext, manifest } = await encryptFile(plaintext, key);
    expect(await decryptFile(ciphertext, manifest, recovered)).toEqual(plaintext);
  });

  it('rejects a wrong recovery code', async () => {
    const salt = generateSalt();
    const key = await deriveExtractableKey(PASSPHRASE, salt);

    const wrapped = await wrapKeyWithRecoveryCode(key, generateRecoveryCode(), salt);

    await expect(
      unwrapKeyWithRecoveryCode(wrapped, generateRecoveryCode(), salt),
    ).rejects.toThrow();
  });

  it('formats as four groups of five unambiguous characters', () => {
    const code = generateRecoveryCode();
    expect(code).toMatch(/^[0-9A-HJKMNP-TV-Z]{5}(-[0-9A-HJKMNP-TV-Z]{5}){3}$/);
    // I, L, O and U are excluded to survive being written down by hand.
    expect(code).not.toMatch(/[ILOU]/);
  });

  it('is unique across many draws', () => {
    const codes = new Set(Array.from({ length: 200 }, () => generateRecoveryCode()));
    expect(codes.size).toBe(200);
  });
});

// ---------------------------------------------------------------------------

describe('object keys and filename hashing', () => {
  it('scopes object keys to the user and never repeats them', () => {
    const keys = new Set(Array.from({ length: 500 }, () => generateObjectKey('user-123')));
    expect(keys.size).toBe(500);
    for (const k of keys) expect(k.startsWith('u/user-123/')).toBe(true);
  });

  it('does not leak the filename into the object key', () => {
    expect(generateObjectKey('user-123')).not.toContain('pdf');
  });

  it('hashes filenames deterministically per salt', async () => {
    const salt = generateSalt();
    const a = await hashFilename('Passport Scan.pdf', salt);
    const b = await hashFilename('Passport Scan.pdf', salt);
    expect(a).toBe(b);
    expect(a).toHaveLength(64);
    expect(a).not.toContain('Passport');
  });

  it('gives different digests under different salts', async () => {
    const a = await hashFilename('Passport Scan.pdf', generateSalt());
    const b = await hashFilename('Passport Scan.pdf', generateSalt());
    expect(a).not.toBe(b);
  });

  it('gives different digests for different filenames', async () => {
    const salt = generateSalt();
    expect(await hashFilename('a.pdf', salt)).not.toBe(await hashFilename('b.pdf', salt));
  });
});

// ---------------------------------------------------------------------------

describe('base64 helpers', () => {
  it('round-trips every byte value', () => {
    const bytes = new Uint8Array(256);
    for (let i = 0; i < 256; i++) bytes[i] = i;
    expect(base64ToBytes(bytesToBase64(bytes))).toEqual(bytes);
  });

  it('round-trips an empty array', () => {
    expect(base64ToBytes(bytesToBase64(new Uint8Array(0)))).toEqual(new Uint8Array(0));
  });

  it('round-trips a buffer larger than the 0x8000 chunking step', () => {
    const bytes = fillPattern(0x8000 * 2 + 7);
    expect(Buffer.from(base64ToBytes(bytesToBase64(bytes))).equals(Buffer.from(bytes))).toBe(
      true,
    );
  });
});

// ---------------------------------------------------------------------------

describe('progress reporting', () => {
  it('reports monotonically and ends at 1', async () => {
    const key = await keyFor(PASSPHRASE, generateSalt());
    const seen: number[] = [];

    await encryptFile(fillPattern(CHUNK_SIZE * 3), key, (f) => seen.push(f));

    expect(seen).toHaveLength(3);
    expect(seen[seen.length - 1]).toBe(1);
    for (let i = 1; i < seen.length; i++) expect(seen[i]!).toBeGreaterThan(seen[i - 1]!);
  });

  it('reports progress on decryption too', async () => {
    const key = await keyFor(PASSPHRASE, generateSalt());
    const { ciphertext, manifest } = await encryptFile(fillPattern(CHUNK_SIZE * 2), key);

    const seen: number[] = [];
    await decryptFile(ciphertext, manifest, key, (f) => seen.push(f));

    expect(seen).toEqual([0.5, 1]);
  });
});
