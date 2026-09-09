/**
 * Upload and download orchestration — browser only.
 *
 * Implements the flow from the spec exactly:
 *
 *   1. select file
 *   2. derive key (done once at unlock, held in memory)
 *   3. chunk + encrypt, fresh IV per chunk
 *   4. ask Vercel for a presigned PUT
 *   5. Vercel checks session and quota
 *   6. Vercel mints a 60s presigned URL
 *   7. browser PUTs ciphertext DIRECTLY to R2 — never through Vercel
 *   8. browser records metadata via /api/files
 *
 * Download is the mirror image with a presigned GET and per-chunk decryption.
 */

import {
  encryptFile,
  decryptFile,
  encryptMetadata,
  decryptMetadata,
  generateObjectKey,
  hashFilename,
  base64ToBytes,
  type EncryptionManifest,
} from './crypto';

export interface FileMetadata {
  filename: string;
  contentType: string;
  tags: string[];
  notes: string;
  /** Plaintext size, so the UI can show the real file size. */
  plaintextSize: number;
}

export interface VaultFile {
  id: string;
  object_key: string;
  encrypted_metadata: string;
  encrypted_manifest: string;
  size_bytes: number;
  created_at: string;
}

/** A file row with its metadata decrypted for display and search. */
export interface DecryptedFile extends VaultFile {
  metadata: FileMetadata;
}

export type TransferStage = 'encrypting' | 'uploading' | 'recording' | 'downloading' | 'decrypting';

export interface TransferProgress {
  stage: TransferStage;
  fraction: number;
}

async function readFileBytes(file: File): Promise<Uint8Array> {
  return new Uint8Array(await file.arrayBuffer());
}

/**
 * Encrypt and upload one file.
 *
 * @param userId  Used only to namespace the object key. Not secret.
 */
export async function uploadFile(
  file: File,
  key: CryptoKey,
  userId: string,
  saltB64: string,
  onProgress?: (p: TransferProgress) => void,
): Promise<{ objectKey: string }> {
  // --- 3. Encrypt in chunks -----------------------------------------------
  const plaintext = await readFileBytes(file);
  const { ciphertext, manifest } = await encryptFile(plaintext, key, (fraction) =>
    onProgress?.({ stage: 'encrypting', fraction }),
  );

  const objectKey = generateObjectKey(userId);

  // --- 4/5/6. Ask for a presigned PUT -------------------------------------
  const presignRes = await fetch('/api/presign-upload', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ objectKey, size: ciphertext.byteLength }),
  });

  if (!presignRes.ok) {
    const detail = (await presignRes.json().catch(() => ({}))) as { error?: string };
    throw new Error(detail.error ?? `Could not get an upload URL (${presignRes.status})`);
  }

  const { url } = (await presignRes.json()) as { url: string };

  // --- 7. PUT ciphertext DIRECTLY to R2 -----------------------------------
  // Note this fetch goes to Cloudflare, not to our own origin. File bytes never
  // transit a Vercel function.
  onProgress?.({ stage: 'uploading', fraction: 0 });

  const putRes = await fetch(url, {
    method: 'PUT',
    // Cast: BodyInit accepts a BufferSource, and this avoids copying the
    // ciphertext a second time on a memory-constrained phone.
    body: ciphertext as unknown as BodyInit,
    headers: { 'Content-Type': 'application/octet-stream' },
  });

  if (!putRes.ok) {
    throw new Error(`Upload to storage failed (${putRes.status})`);
  }
  onProgress?.({ stage: 'uploading', fraction: 1 });

  // --- 8. Record encrypted metadata ---------------------------------------
  onProgress?.({ stage: 'recording', fraction: 0 });

  const metadata: FileMetadata = {
    filename: file.name,
    // iOS often reports an empty type for files chosen from Photos or Files,
    // and an extension is not guaranteed to be present either.
    contentType: file.type || 'application/octet-stream',
    tags: [],
    notes: '',
    plaintextSize: plaintext.byteLength,
  };

  const [encryptedMetadata, encryptedManifest, filenameHash] = await Promise.all([
    encryptMetadata(metadata, key),
    encryptMetadata(manifest, key),
    hashFilename(file.name, base64ToBytes(saltB64)),
  ]);

  const recordRes = await fetch('/api/files', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      objectKey,
      encryptedMetadata,
      encryptedManifest,
      filenameHash,
      sizeBytes: ciphertext.byteLength,
    }),
  });

  if (!recordRes.ok) {
    // The blob is uploaded but unrecorded — an orphan. Surfaced rather than
    // swallowed, because silently losing track of an uploaded file is worse
    // than an error the user can retry.
    throw new Error(
      'File uploaded but could not be recorded. It may need to be uploaded again.',
    );
  }

  onProgress?.({ stage: 'recording', fraction: 1 });
  return { objectKey };
}

/** Download, decrypt and return the plaintext bytes plus metadata. */
export async function downloadFile(
  file: VaultFile,
  key: CryptoKey,
  onProgress?: (p: TransferProgress) => void,
): Promise<{ bytes: Uint8Array; metadata: FileMetadata }> {
  const presignRes = await fetch('/api/presign-download', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ objectKey: file.object_key }),
  });

  if (!presignRes.ok) {
    const detail = (await presignRes.json().catch(() => ({}))) as { error?: string };
    throw new Error(detail.error ?? `Could not get a download URL (${presignRes.status})`);
  }

  const { url } = (await presignRes.json()) as { url: string };

  onProgress?.({ stage: 'downloading', fraction: 0 });
  const objectRes = await fetch(url);
  if (!objectRes.ok) throw new Error(`Download failed (${objectRes.status})`);

  const ciphertext = new Uint8Array(await objectRes.arrayBuffer());
  onProgress?.({ stage: 'downloading', fraction: 1 });

  const [metadata, manifest] = await Promise.all([
    decryptMetadata<FileMetadata>(file.encrypted_metadata, key),
    decryptMetadata<EncryptionManifest>(file.encrypted_manifest, key),
  ]);

  const bytes = await decryptFile(ciphertext, manifest, key, (fraction) =>
    onProgress?.({ stage: 'decrypting', fraction }),
  );

  return { bytes, metadata };
}

/**
 * Hand decrypted bytes to the user as a download.
 *
 * The object URL is revoked on the next tick — leaving it live would keep the
 * plaintext resident in memory for the lifetime of the document.
 */
export function saveToDisk(bytes: Uint8Array, metadata: FileMetadata): void {
  const blob = new Blob([bytes as unknown as BlobPart], { type: metadata.contentType });
  const url = URL.createObjectURL(blob);

  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = metadata.filename;
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();

  setTimeout(() => URL.revokeObjectURL(url), 0);
}

/**
 * Decrypt the whole index so it can be searched client-side.
 *
 * Server-side full-text search over document contents is impossible by design:
 * the server only ever holds ciphertext. For a personal vault of a few thousand
 * files the decrypted index is small enough to hold in memory, which is what
 * makes search work at all. Do not "solve" this with server-side OCR — that
 * would require plaintext on the server and defeat the encryption.
 */
export async function decryptIndex(files: VaultFile[], key: CryptoKey): Promise<DecryptedFile[]> {
  const out: DecryptedFile[] = [];
  for (const file of files) {
    try {
      const metadata = await decryptMetadata<FileMetadata>(file.encrypted_metadata, key);
      out.push({ ...file, metadata });
    } catch {
      // One unreadable row must not blank the whole list — it is usually a file
      // encrypted under a previous passphrase.
      out.push({
        ...file,
        metadata: {
          filename: '[cannot decrypt]',
          contentType: 'application/octet-stream',
          tags: [],
          notes: '',
          plaintextSize: file.size_bytes,
        },
      });
    }
  }
  return out;
}

/** Case-insensitive search over filenames, tags and notes. */
export function searchFiles(files: DecryptedFile[], query: string): DecryptedFile[] {
  const q = query.trim().toLowerCase();
  if (!q) return files;
  return files.filter((f) => {
    const haystack = [f.metadata.filename, f.metadata.notes, ...f.metadata.tags]
      .join(' ')
      .toLowerCase();
    return haystack.includes(q);
  });
}
