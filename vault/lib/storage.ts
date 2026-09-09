/**
 * Supabase Storage — SERVER ONLY.
 *
 * Replaces the original Cloudflare R2 implementation. The reason is not
 * technical: R2 requires a payment method on file and has no spending cap,
 * which conflicts with the project's hard rule that no card may be attached in
 * a way that permits automatic overage billing. Supabase Storage needs no card
 * and restricts service rather than billing when a free limit is reached.
 *
 * The trade-off accepted: 1 GB free instead of 10 GB. For documents that are
 * mostly PDFs and office files at 100 KB - 2 MB each, that is a few thousand
 * files. `STORAGE_SOFT_LIMIT_BYTES` warns well before the ceiling so it is
 * never a surprise.
 *
 * WHAT DOES NOT CHANGE: files are still encrypted in the browser before upload
 * and the server still only ever holds ciphertext. The crypto core is
 * untouched. Supabase sees opaque bytes under an opaque object key.
 *
 * The `server-only` guard makes importing this from a client component a build
 * error rather than a silent credential leak.
 */

import 'server-only';

import { serviceClient } from './supabase-server';

/** Bucket name. Must be created as a PRIVATE bucket — see supabase/README.md. */
export const STORAGE_BUCKET = 'vault-files';

/**
 * Download URL lifetime, in seconds. The spec caps this at 60 and Supabase
 * honours the value for downloads.
 */
export const SIGNED_DOWNLOAD_TTL_SECONDS = 60;

/**
 * DEVIATION FROM SPEC, stated rather than hidden.
 *
 * Supabase's signed UPLOAD tokens are fixed at 2 hours and the SDK exposes no
 * way to shorten them. The spec asks for 60 seconds.
 *
 * Why this is acceptable here:
 *   - the token authorises writing to ONE object key, which is random and
 *     already recorded against the user's row
 *   - it grants no read access, so it cannot be used to exfiltrate anything
 *   - the bucket is private with RLS, so the object is unreadable without a
 *     separate signed download URL
 *   - the client uses the token immediately; the window is theoretical
 *
 * The residual risk is that a token intercepted in transit could be used to
 * overwrite that one object within two hours. TLS covers transit. Recorded in
 * SECURITY-NOTES.md rather than quietly ignored.
 */
export const SIGNED_UPLOAD_TTL_SECONDS = 7200;

/** Supabase free tier file storage. */
export const STORAGE_QUOTA_BYTES = 1024 * 1024 * 1024;

/**
 * Refuse uploads past 90% of the free tier.
 *
 * Stopping short of the hard limit means the failure is a clear message from
 * this application rather than an opaque error from the platform, and it leaves
 * room to export before anything is restricted.
 */
export const STORAGE_SOFT_LIMIT_BYTES = Math.floor(STORAGE_QUOTA_BYTES * 0.9);

/** Largest single upload accepted, so one file cannot consume the whole quota. */
export const MAX_SINGLE_UPLOAD_BYTES = 100 * 1024 * 1024;

/**
 * Object keys are `<userId>/<random>`.
 *
 * Every call re-checks the prefix, so a forged key cannot address another
 * user's object even if a caller reaches the route.
 */
export function isKeyOwnedBy(objectKey: string, userId: string): boolean {
  if (!objectKey || !userId) return false;
  // Reject traversal and absolute forms outright rather than normalising them.
  if (objectKey.includes('..') || objectKey.startsWith('/')) return false;
  return objectKey.startsWith(`${userId}/`);
}

export interface SignedUpload {
  /** URL the browser PUTs ciphertext to. Never routed through this function. */
  signedUrl: string;
  /** Token the client passes to uploadToSignedUrl. */
  token: string;
  path: string;
}

/**
 * Mint a signed upload URL scoped to one object key.
 *
 * Uses the service-role client because the collector-style storage API needs to
 * sign on the user's behalf; ownership is enforced by `isKeyOwnedBy` above and
 * by the caller having a valid session.
 */
export async function createSignedUpload(
  objectKey: string,
  userId: string,
): Promise<SignedUpload> {
  if (!isKeyOwnedBy(objectKey, userId)) {
    throw new Error('Refusing to sign an object key outside the user namespace');
  }

  const supabase = serviceClient();
  const { data, error } = await supabase.storage
    .from(STORAGE_BUCKET)
    .createSignedUploadUrl(objectKey);

  if (error || !data) {
    throw new Error(`Could not create an upload URL: ${error?.message ?? 'unknown error'}`);
  }

  return { signedUrl: data.signedUrl, token: data.token, path: data.path };
}

/** Mint a 60-second signed download URL scoped to one object key. */
export async function createSignedDownload(
  objectKey: string,
  userId: string,
): Promise<string> {
  if (!isKeyOwnedBy(objectKey, userId)) {
    throw new Error('Refusing to sign an object key outside the user namespace');
  }

  const supabase = serviceClient();
  const { data, error } = await supabase.storage
    .from(STORAGE_BUCKET)
    .createSignedUrl(objectKey, SIGNED_DOWNLOAD_TTL_SECONDS);

  if (error || !data) {
    throw new Error(`Could not create a download URL: ${error?.message ?? 'unknown error'}`);
  }

  return data.signedUrl;
}

/**
 * Delete an object.
 *
 * Called after the metadata row is removed, so a failure here leaves an
 * orphaned blob rather than a row pointing at nothing. An orphan costs a little
 * quota; a dangling row is a broken file in the UI.
 */
export async function deleteObject(objectKey: string, userId: string): Promise<void> {
  if (!isKeyOwnedBy(objectKey, userId)) {
    throw new Error('Refusing to delete an object key outside the user namespace');
  }

  const supabase = serviceClient();
  const { error } = await supabase.storage.from(STORAGE_BUCKET).remove([objectKey]);

  if (error) {
    throw new Error(`Could not delete the stored object: ${error.message}`);
  }
}
