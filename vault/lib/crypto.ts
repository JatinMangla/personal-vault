/**
 * Client-side encryption core for the document vault.
 *
 * Threat model: the hosting platform and the storage provider are both treated
 * as hostile. They see ciphertext and nothing else. The passphrase never leaves the browser, the
 * derived key is non-extractable and memory-only, and losing both passphrase
 * and recovery code means the data is gone. That last property is the point
 * of the system, not a defect.
 *
 * Everything here runs in the browser against the Web Crypto API. There are no
 * dependencies, deliberately: per CLAUDE.md, anything touching crypto uses the
 * platform primitive rather than a library.
 *
 * WHY CHUNKED. `crypto.subtle.encrypt` has no streaming interface - it consumes
 * an entire ArrayBuffer and returns another. Encrypting a 400 MB PDF in one call
 * needs the plaintext and the ciphertext resident at once, which exceeds the
 * per-tab memory ceiling on iOS Safari and kills the tab. Fixed 4 MB chunks give
 * a real progress signal, and bound memory ONLY if the caller also streams:
 * `encryptBlob` reads the source one chunk at a time and `decryptStream`
 * decrypts as bytes arrive, so neither holds the whole plaintext. The
 * whole-buffer `encryptFile`/`decryptFile` are kept for tests and small inputs;
 * the transfer path must not use them.
 *
 * WHY A FRESH IV PER CHUNK. AES-GCM is a counter mode. Reusing a (key, nonce)
 * pair across two different plaintexts leaks their XOR and enables forgery of
 * the authentication tag. Reuse is catastrophic and unrecoverable, so every
 * chunk draws 96 fresh bits from the CSPRNG. Never a counter, never
 * Math.random(). This module never derives an IV from anything.
 */

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

/** Plaintext bytes per chunk. Bounds peak memory on mobile Safari. */
export const CHUNK_SIZE = 4 * 1024 * 1024;

/**
 * PBKDF2 iterations. The spec floor is 600,000, matching OWASP guidance for
 * PBKDF2-HMAC-SHA256. Raising this later is safe for new files but would
 * invalidate existing ones, so it is recorded in the manifest instead.
 */
export const PBKDF2_ITERATIONS = 600_000;

/** AES-GCM nonce length in bytes. 96 bits is the size GCM is defined for. */
export const IV_LENGTH = 12;

/** GCM authentication tag length in bits. */
export const TAG_LENGTH = 128;

/** Bytes each chunk's ciphertext exceeds its plaintext by: the GCM tag. */
const TAG_BYTES = TAG_LENGTH / 8;

/** Salt length for key derivation, in bytes. */
export const SALT_LENGTH = 16;

/** Bumped only if the wire format changes incompatibly. */
export const MANIFEST_VERSION = 1 as const;

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export interface ChunkDescriptor {
  /** Zero-based position of this chunk in the file. */
  index: number;
  /** Base64 of the 12-byte IV used for this chunk. Unique per chunk. */
  iv: string;
  /** Byte length of the ciphertext, including the 16-byte GCM tag. */
  ciphertextLength: number;
}

export interface EncryptionManifest {
  version: typeof MANIFEST_VERSION;
  algorithm: 'AES-GCM';
  kdf: 'PBKDF2-SHA256';
  iterations: number;
  chunkSize: number;
  /** Plaintext size in bytes. Needed to preallocate on download. */
  plaintextSize: number;
  chunks: ChunkDescriptor[];
}

export interface EncryptedFile {
  /** Concatenated ciphertext chunks, in index order. This is what is uploaded. */
  ciphertext: Uint8Array;
  manifest: EncryptionManifest;
}

/** Progress callback: fraction in [0,1]. Used to drive the upload bar. */
export type ProgressFn = (fraction: number) => void;

// ---------------------------------------------------------------------------
// Encoding helpers
// ---------------------------------------------------------------------------

export function bytesToBase64(bytes: Uint8Array): string {
  // Chunked to avoid exceeding the argument limit of String.fromCharCode on
  // large inputs. Only ever applied to IVs and salts in practice, but the
  // guard costs nothing and prevents a surprise if that changes.
  let binary = '';
  const step = 0x8000;
  for (let i = 0; i < bytes.length; i += step) {
    binary += String.fromCharCode(...bytes.subarray(i, i + step));
  }
  return btoa(binary);
}

export function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

// ---------------------------------------------------------------------------
// Key derivation
// ---------------------------------------------------------------------------

/** Fresh random salt for a new user. Store alongside the user row in Supabase. */
export function generateSalt(): Uint8Array {
  return crypto.getRandomValues(new Uint8Array(SALT_LENGTH));
}

/**
 * Derive the file-encryption key from a passphrase.
 *
 * `extractable` is false so the key cannot be read back out of the CryptoKey
 * and accidentally serialised into storage or a log. It is held in a React
 * context or module-scoped variable for the session and dropped on logout.
 */
export async function deriveKey(
  passphrase: string,
  salt: Uint8Array,
  iterations: number = PBKDF2_ITERATIONS,
): Promise<CryptoKey> {
  if (iterations < 600_000) {
    // Guard rather than trust the caller: a low iteration count silently
    // weakens every file encrypted with the resulting key.
    throw new Error(`PBKDF2 iterations must be >= 600000, got ${iterations}`);
  }

  const material = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(passphrase),
    'PBKDF2',
    false,
    ['deriveKey'],
  );

  return crypto.subtle.deriveKey(
    {
      name: 'PBKDF2',
      salt: salt as BufferSource,
      iterations,
      hash: 'SHA-256',
    },
    material,
    { name: 'AES-GCM', length: 256 },
    /* extractable */ false,
    ['encrypt', 'decrypt'],
  );
}

/**
 * Derive a key and allow it to be exported.
 *
 * Used only where the key must be wrapped: upgrading a pre-envelope account,
 * whose data key IS this derived key. Never hold its result as the session key.
 */
export async function deriveExtractableKey(
  passphrase: string,
  salt: Uint8Array,
  iterations: number = PBKDF2_ITERATIONS,
): Promise<CryptoKey> {
  if (iterations < 600_000) {
    throw new Error(`PBKDF2 iterations must be >= 600000, got ${iterations}`);
  }
  const material = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(passphrase),
    'PBKDF2',
    false,
    ['deriveKey'],
  );
  return crypto.subtle.deriveKey(
    { name: 'PBKDF2', salt: salt as BufferSource, iterations, hash: 'SHA-256' },
    material,
    { name: 'AES-GCM', length: 256 },
    true,
    ['encrypt', 'decrypt'],
  );
}

// ---------------------------------------------------------------------------
// Encryption
// ---------------------------------------------------------------------------

/**
 * Encrypt a file in fixed-size chunks, one fresh IV each.
 *
 * Returns the concatenated ciphertext plus the manifest needed to reverse it.
 * The manifest holds no key material - it is safe to store in Supabase, though
 * in practice it is itself encrypted as part of the file metadata.
 */
export async function encryptFile(
  plaintext: Uint8Array,
  key: CryptoKey,
  onProgress?: ProgressFn,
): Promise<EncryptedFile> {
  // A zero-byte file still produces one chunk, so an empty upload round-trips
  // rather than producing a manifest with no chunks that cannot be verified.
  const chunkCount = Math.max(1, Math.ceil(plaintext.length / CHUNK_SIZE));
  const chunks: ChunkDescriptor[] = [];
  const ciphertexts: Uint8Array[] = [];
  let totalCiphertext = 0;

  for (let index = 0; index < chunkCount; index++) {
    const start = index * CHUNK_SIZE;
    const slice = plaintext.subarray(start, Math.min(start + CHUNK_SIZE, plaintext.length));

    // Fresh 96 bits from the CSPRNG for every single chunk. See module header.
    const iv = crypto.getRandomValues(new Uint8Array(IV_LENGTH));

    const encrypted = new Uint8Array(
      await crypto.subtle.encrypt(
        { name: 'AES-GCM', iv: iv as BufferSource, tagLength: TAG_LENGTH },
        key,
        slice as BufferSource,
      ),
    );

    chunks.push({
      index,
      iv: bytesToBase64(iv),
      ciphertextLength: encrypted.length,
    });
    ciphertexts.push(encrypted);
    totalCiphertext += encrypted.length;

    onProgress?.((index + 1) / chunkCount);
  }

  const ciphertext = new Uint8Array(totalCiphertext);
  let offset = 0;
  for (const c of ciphertexts) {
    ciphertext.set(c, offset);
    offset += c.length;
  }

  return {
    ciphertext,
    manifest: {
      version: MANIFEST_VERSION,
      algorithm: 'AES-GCM',
      kdf: 'PBKDF2-SHA256',
      iterations: PBKDF2_ITERATIONS,
      chunkSize: CHUNK_SIZE,
      plaintextSize: plaintext.length,
      chunks,
    },
  };
}

/**
 * Exact ciphertext size for a plaintext of `plaintextSize` bytes.
 *
 * Deterministic - one GCM tag per chunk, and a zero-byte file is still one
 * chunk - so the upload URL can be requested BEFORE encryption finishes, taking
 * that round trip off the critical path.
 */
export function ciphertextSizeFor(plaintextSize: number): number {
  return plaintextSize + TAG_BYTES * Math.max(1, Math.ceil(plaintextSize / CHUNK_SIZE));
}

/**
 * Encrypt a Blob (or File) without ever holding its whole plaintext.
 *
 * Produces exactly the wire format of `encryptFile` - same chunking, same
 * manifest, one fresh IV per chunk - so either decrypt path reads its output.
 * Differences are only in memory and time:
 *
 *   - the source is read one chunk at a time via `Blob.slice`, never whole
 *   - the result is a Blob of the ciphertext chunks, never concatenated into
 *     one buffer (browsers may spill large Blobs to disk)
 *   - the NEXT chunk is read while the current one encrypts, so the read and
 *     the cipher overlap instead of taking turns
 *
 * `signal` stops the loop early - used when the upload URL request fails while
 * encryption is still running, so no CPU is spent on a doomed upload.
 */
export async function encryptBlob(
  source: Blob,
  key: CryptoKey,
  onProgress?: ProgressFn,
  signal?: AbortSignal,
): Promise<{ body: Blob; manifest: EncryptionManifest }> {
  const chunkCount = Math.max(1, Math.ceil(source.size / CHUNK_SIZE));
  const chunks: ChunkDescriptor[] = [];
  const parts: Uint8Array[] = [];

  const read = (index: number): Promise<ArrayBuffer> => {
    const start = index * CHUNK_SIZE;
    return source.slice(start, Math.min(start + CHUNK_SIZE, source.size)).arrayBuffer();
  };

  let pending = read(0);
  for (let index = 0; index < chunkCount; index++) {
    signal?.throwIfAborted();
    const slice = await pending;
    if (index + 1 < chunkCount) pending = read(index + 1);

    // Fresh 96 bits from the CSPRNG for every single chunk. See module header.
    const iv = crypto.getRandomValues(new Uint8Array(IV_LENGTH));
    const encrypted = new Uint8Array(
      await crypto.subtle.encrypt(
        { name: 'AES-GCM', iv: iv as BufferSource, tagLength: TAG_LENGTH },
        key,
        slice,
      ),
    );

    chunks.push({ index, iv: bytesToBase64(iv), ciphertextLength: encrypted.length });
    parts.push(encrypted);
    onProgress?.((index + 1) / chunkCount);
  }

  return {
    body: new Blob(parts as BlobPart[], { type: 'application/octet-stream' }),
    manifest: {
      version: MANIFEST_VERSION,
      algorithm: 'AES-GCM',
      kdf: 'PBKDF2-SHA256',
      iterations: PBKDF2_ITERATIONS,
      chunkSize: CHUNK_SIZE,
      plaintextSize: source.size,
      chunks,
    },
  };
}

// ---------------------------------------------------------------------------
// Decryption
// ---------------------------------------------------------------------------

/**
 * Reverse `encryptFile`.
 *
 * Throws if the key is wrong or any byte has been altered: GCM verifies the
 * authentication tag before releasing plaintext, so a tampered chunk fails
 * loudly instead of yielding corrupted output. Callers must treat any throw as
 * "wrong passphrase or damaged file" and must not fall back to partial data.
 */
export async function decryptFile(
  ciphertext: Uint8Array,
  manifest: EncryptionManifest,
  key: CryptoKey,
  onProgress?: ProgressFn,
): Promise<Uint8Array> {
  checkManifest(manifest);

  const out = new Uint8Array(manifest.plaintextSize);
  let readOffset = 0;
  let writeOffset = 0;
  const total = manifest.chunks.length;

  // Iterate in explicit index order. Never trust array order from the wire.
  const ordered = [...manifest.chunks].sort((a, b) => a.index - b.index);

  for (let i = 0; i < ordered.length; i++) {
    const chunk = ordered[i]!;
    const slice = ciphertext.subarray(readOffset, readOffset + chunk.ciphertextLength);
    if (slice.length !== chunk.ciphertextLength) {
      throw new Error(
        `Ciphertext truncated at chunk ${chunk.index}: expected ` +
          `${chunk.ciphertextLength} bytes, got ${slice.length}`,
      );
    }

    // Throws OperationError on a wrong key or a tampered byte. Deliberately
    // not caught here - a caller that swallows this would hand the user
    // silently wrong data, which is worse than an error.
    const decrypted = new Uint8Array(
      await crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: base64ToBytes(chunk.iv) as BufferSource, tagLength: TAG_LENGTH },
        key,
        slice as BufferSource,
      ),
    );

    out.set(decrypted, writeOffset);
    writeOffset += decrypted.length;
    readOffset += chunk.ciphertextLength;

    onProgress?.((i + 1) / total);
  }

  if (writeOffset !== manifest.plaintextSize) {
    throw new Error(
      `Decrypted size mismatch: expected ${manifest.plaintextSize}, got ${writeOffset}`,
    );
  }

  return out;
}

function checkManifest(manifest: EncryptionManifest): void {
  if (manifest.version !== MANIFEST_VERSION) {
    throw new Error(`Unsupported manifest version: ${manifest.version}`);
  }
  if (manifest.algorithm !== 'AES-GCM') {
    throw new Error(`Unsupported algorithm: ${manifest.algorithm}`);
  }
}

/**
 * Decrypt ciphertext AS IT ARRIVES, chunk by chunk, into a Blob.
 *
 * Same guarantees as `decryptFile` - explicit index order, a length check per
 * chunk, GCM authentication per chunk, a total-size check - but decryption of
 * chunk N overlaps the network delivering chunk N+1, and neither the whole
 * ciphertext nor a preallocated whole plaintext is ever resident.
 *
 * A throw means wrong key, tampering or truncation. Callers must discard the
 * partial result: nothing is returned until every chunk has authenticated.
 */
export async function decryptStream(
  stream: ReadableStream<Uint8Array>,
  manifest: EncryptionManifest,
  key: CryptoKey,
  onProgress?: ProgressFn,
  type = 'application/octet-stream',
): Promise<Blob> {
  checkManifest(manifest);

  const ordered = [...manifest.chunks].sort((a, b) => a.index - b.index);
  const reader = stream.getReader();
  const pending: Uint8Array[] = [];
  let buffered = 0;
  const parts: Uint8Array[] = [];
  let written = 0;

  // Pull exactly `length` bytes off the stream, or fewer if it ends first.
  const take = async (length: number): Promise<Uint8Array> => {
    while (buffered < length) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value.length === 0) continue;
      pending.push(value);
      buffered += value.length;
    }
    const size = Math.min(length, buffered);
    const first = pending[0];
    if (first && first.length >= size) {
      // Common case: one network read already holds the whole chunk.
      const out = first.subarray(0, size);
      if (first.length === size) pending.shift();
      else pending[0] = first.subarray(size);
      buffered -= size;
      return out;
    }
    const out = new Uint8Array(size);
    let filled = 0;
    while (filled < size) {
      const piece = pending[0]!;
      const n = Math.min(piece.length, size - filled);
      out.set(piece.subarray(0, n), filled);
      filled += n;
      if (n === piece.length) pending.shift();
      else pending[0] = piece.subarray(n);
    }
    buffered -= size;
    return out;
  };

  try {
    for (let i = 0; i < ordered.length; i++) {
      const chunk = ordered[i]!;
      const slice = await take(chunk.ciphertextLength);
      if (slice.length !== chunk.ciphertextLength) {
        throw new Error(
          `Ciphertext truncated at chunk ${chunk.index}: expected ` +
            `${chunk.ciphertextLength} bytes, got ${slice.length}`,
        );
      }

      // Throws OperationError on a wrong key or a tampered byte - see
      // decryptFile for why this is deliberately not caught.
      const decrypted = new Uint8Array(
        await crypto.subtle.decrypt(
          { name: 'AES-GCM', iv: base64ToBytes(chunk.iv) as BufferSource, tagLength: TAG_LENGTH },
          key,
          slice as BufferSource,
        ),
      );
      parts.push(decrypted);
      written += decrypted.length;
      onProgress?.((i + 1) / ordered.length);
    }
  } finally {
    // Release the connection whether we finished, failed or stopped early.
    await reader.cancel().catch(() => undefined);
  }

  if (written !== manifest.plaintextSize) {
    throw new Error(`Decrypted size mismatch: expected ${manifest.plaintextSize}, got ${written}`);
  }

  return new Blob(parts as BlobPart[], { type });
}

// ---------------------------------------------------------------------------
// Metadata encryption
// ---------------------------------------------------------------------------

/**
 * Encrypt a small JSON value (filename, tags, notes, the manifest itself).
 *
 * Metadata is encrypted separately from file bytes because the client needs to
 * decrypt the whole index to search it, without fetching any file blob.
 * Self-contained: the IV is prefixed to the ciphertext.
 */
export async function encryptMetadata(value: unknown, key: CryptoKey): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(IV_LENGTH));
  const encoded = new TextEncoder().encode(JSON.stringify(value));
  const encrypted = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: iv as BufferSource, tagLength: TAG_LENGTH },
      key,
      encoded as BufferSource,
    ),
  );
  const combined = new Uint8Array(iv.length + encrypted.length);
  combined.set(iv, 0);
  combined.set(encrypted, iv.length);
  return bytesToBase64(combined);
}

export async function decryptMetadata<T = unknown>(
  payload: string,
  key: CryptoKey,
): Promise<T> {
  const combined = base64ToBytes(payload);
  if (combined.length <= IV_LENGTH) {
    throw new Error('Metadata payload too short to contain an IV and ciphertext');
  }
  const iv = combined.subarray(0, IV_LENGTH);
  const body = combined.subarray(IV_LENGTH);
  const decrypted = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: iv as BufferSource, tagLength: TAG_LENGTH },
    key,
    body as BufferSource,
  );
  return JSON.parse(new TextDecoder().decode(decrypted)) as T;
}

// ---------------------------------------------------------------------------
// Object keys
// ---------------------------------------------------------------------------

/**
 * Opaque storage object key.
 *
 * Random rather than derived from the filename: an object key is visible to
 * the storage provider, so deriving it from the name would leak the name.
 * 32 hex chars of CSPRNG output, namespaced by user id.
 */
export function generateObjectKey(userId: string): string {
  const random = crypto.getRandomValues(new Uint8Array(16));
  const hex = Array.from(random, (b) => b.toString(16).padStart(2, '0')).join('');
  return `${userId}/${hex}`;
}

// There is deliberately NO filename blind index. One existed (SHA-256 of the
// per-user KDF salt + name), but that salt is stored server-side, so a hostile
// server could test "passport.pdf" at the cost of one hash per guess - and no
// feature ever read the digest. Removed rather than repaired.

// ---------------------------------------------------------------------------
// Recovery code
// ---------------------------------------------------------------------------

/**
 * Generate a recovery code, shown exactly once at setup.
 *
 * Crockford base32 (no I, L, O, U) so it can be read aloud or written down
 * without transcription errors. 20 characters is roughly 100 bits of entropy.
 */
export function generateRecoveryCode(): string {
  const alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  const bytes = crypto.getRandomValues(new Uint8Array(20));
  const chars = Array.from(bytes, (b) => alphabet[b % alphabet.length]!);
  return (
    chars.slice(0, 5).join('') +
    '-' +
    chars.slice(5, 10).join('') +
    '-' +
    chars.slice(10, 15).join('') +
    '-' +
    chars.slice(15, 20).join('')
  );
}

/**
 * Wrap the raw file key under a recovery code so passphrase loss is survivable.
 *
 * The wrapped blob is stored server-side. It is useless without the recovery
 * code, which is never transmitted. Losing the passphrase AND the recovery code
 * means the files are unrecoverable - correct behaviour for E2EE, and it must
 * be stated loudly in the UI.
 */
export async function wrapKeyWithRecoveryCode(
  key: CryptoKey,
  recoveryCode: string,
  salt: Uint8Array,
): Promise<string> {
  return wrapKeyWithSecret(key, recoveryCode.replace(/-/g, ''), salt);
}

export async function unwrapKeyWithRecoveryCode(
  wrappedPayload: string,
  recoveryCode: string,
  salt: Uint8Array,
  extractable = false,
): Promise<CryptoKey> {
  return unwrapKeyWithSecret(
    wrappedPayload,
    recoveryCode.replace(/-/g, ''),
    salt,
    PBKDF2_ITERATIONS,
    extractable,
  );
}

// ---------------------------------------------------------------------------
// Envelope keys
// ---------------------------------------------------------------------------
//
// The data key encrypts files. It is wrapped - never stored bare - under a key
// derived from each secret that may open the vault: the passphrase, and the
// recovery code. Changing a secret rewraps the data key and touches no file.

/** A fresh random data key for a new vault. Extractable so it can be wrapped. */
export async function generateDataKey(): Promise<CryptoKey> {
  return crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, true, [
    'encrypt',
    'decrypt',
  ]);
}

/**
 * Wrap `key` under PBKDF2(secret, salt).
 *
 * Output: base64(iv || AES-GCM ciphertext of the raw key). `key` must be
 * extractable; the wrapping key never is.
 */
export async function wrapKeyWithSecret(
  key: CryptoKey,
  secret: string,
  salt: Uint8Array,
  iterations: number = PBKDF2_ITERATIONS,
): Promise<string> {
  const wrappingKey = await deriveKey(secret, salt, iterations);
  const raw = await crypto.subtle.exportKey('raw', key);
  const iv = crypto.getRandomValues(new Uint8Array(IV_LENGTH));
  const wrapped = new Uint8Array(
    await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: iv as BufferSource, tagLength: TAG_LENGTH },
      wrappingKey,
      raw,
    ),
  );
  const combined = new Uint8Array(iv.length + wrapped.length);
  combined.set(iv, 0);
  combined.set(wrapped, iv.length);
  return bytesToBase64(combined);
}

/**
 * Reverse `wrapKeyWithSecret`. Throws on a wrong secret: GCM authenticates the
 * wrapped key, so a bad passphrase can never yield a plausible-looking key.
 *
 * `extractable` is true only when the caller must rewrap the key (changing the
 * passphrase, finishing a recovery). The session key stays non-extractable.
 */
export async function unwrapKeyWithSecret(
  wrappedPayload: string,
  secret: string,
  salt: Uint8Array,
  iterations: number = PBKDF2_ITERATIONS,
  extractable = false,
): Promise<CryptoKey> {
  const wrappingKey = await deriveKey(secret, salt, iterations);
  const combined = base64ToBytes(wrappedPayload);
  if (combined.length <= IV_LENGTH) {
    throw new Error('Wrapped key too short to contain an IV and ciphertext');
  }
  const iv = combined.subarray(0, IV_LENGTH);
  const body = combined.subarray(IV_LENGTH);
  const raw = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: iv as BufferSource, tagLength: TAG_LENGTH },
    wrappingKey,
    body as BufferSource,
  );
  return crypto.subtle.importKey('raw', raw, { name: 'AES-GCM', length: 256 }, extractable, [
    'encrypt',
    'decrypt',
  ]);
}

/**
 * A non-extractable copy of an extractable key, for holding in the session.
 * Used after a rewrap, so the key kept in memory cannot be serialised out.
 */
export async function toSessionKey(key: CryptoKey): Promise<CryptoKey> {
  const raw = await crypto.subtle.exportKey('raw', key);
  return crypto.subtle.importKey('raw', raw, { name: 'AES-GCM', length: 256 }, false, [
    'encrypt',
    'decrypt',
  ]);
}
