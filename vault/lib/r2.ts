/**
 * Cloudflare R2 client — SERVER ONLY.
 *
 * This module must never be imported from a client component. It reads
 * R2_ACCESS_KEY_ID and R2_SECRET_ACCESS_KEY, and any import from the client
 * bundle would ship them to the browser.
 *
 * The `server-only` guard below turns that mistake into a build error rather
 * than a silent credential leak.
 *
 * WHAT THIS MODULE DOES: mints short-lived presigned URLs so the browser can
 * talk to R2 directly. File bytes never transit a Vercel function. That is a
 * hard architectural rule, for two reasons:
 *   1. Vercel Hobby allows 100 GB of Fast Data Transfer per month; routing
 *      files through it burns that quota and adds latency.
 *   2. R2 charges zero egress at any volume, so direct downloads are free
 *      forever.
 */

import 'server-only';

import { S3Client, PutObjectCommand, GetObjectCommand, DeleteObjectCommand } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

/** Presigned URL lifetime. The spec caps this at 60 seconds and so do we. */
export const PRESIGN_TTL_SECONDS = 60;

/** R2 free tier. Enforced before minting an upload URL. */
export const R2_QUOTA_BYTES = 10 * 1024 * 1024 * 1024;

/**
 * Largest single upload accepted. Above this, the client must use multipart.
 * Guards against a single request being able to consume the whole quota.
 */
export const MAX_SINGLE_UPLOAD_BYTES = 100 * 1024 * 1024;

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    // Fail loudly at first use rather than producing a client that silently
    // signs with undefined credentials.
    throw new Error(`Missing required server environment variable: ${name}`);
  }
  return value;
}

let cachedClient: S3Client | null = null;

function client(): S3Client {
  if (cachedClient) return cachedClient;

  const accountId = requireEnv('R2_ACCOUNT_ID');

  cachedClient = new S3Client({
    region: 'auto',
    endpoint: `https://${accountId}.r2.cloudflarestorage.com`,
    credentials: {
      accessKeyId: requireEnv('R2_ACCESS_KEY_ID'),
      secretAccessKey: requireEnv('R2_SECRET_ACCESS_KEY'),
    },
  });
  return cachedClient;
}

function bucket(): string {
  return requireEnv('R2_BUCKET_NAME');
}

/**
 * Object keys are `u/<userId>/<random>`. Every presign call re-checks that the
 * key belongs to the calling user, so a caller cannot craft a key pointing at
 * someone else's object even if they can reach the route.
 */
export function isKeyOwnedBy(objectKey: string, userId: string): boolean {
  if (!objectKey || !userId) return false;
  // Reject traversal and absolute forms outright rather than trying to
  // normalise them.
  if (objectKey.includes('..') || objectKey.startsWith('/')) return false;
  return objectKey.startsWith(`u/${userId}/`);
}

/** Presigned PUT, scoped to one object key, valid for 60 seconds. */
export async function presignUpload(
  objectKey: string,
  userId: string,
  contentLength: number,
): Promise<string> {
  if (!isKeyOwnedBy(objectKey, userId)) {
    throw new Error('Refusing to presign an object key outside the user namespace');
  }

  const command = new PutObjectCommand({
    Bucket: bucket(),
    Key: objectKey,
    // Binding the length into the signature means the URL cannot be reused to
    // upload something substantially different from what was authorised.
    ContentLength: contentLength,
    // Always ciphertext; the server never learns the real type.
    ContentType: 'application/octet-stream',
  });

  return getSignedUrl(client(), command, { expiresIn: PRESIGN_TTL_SECONDS });
}

/** Presigned GET, scoped to one object key, valid for 60 seconds. */
export async function presignDownload(objectKey: string, userId: string): Promise<string> {
  if (!isKeyOwnedBy(objectKey, userId)) {
    throw new Error('Refusing to presign an object key outside the user namespace');
  }

  const command = new GetObjectCommand({ Bucket: bucket(), Key: objectKey });
  return getSignedUrl(client(), command, { expiresIn: PRESIGN_TTL_SECONDS });
}

/**
 * Delete an object.
 *
 * Called after the metadata row is removed, so a failure here leaves an
 * orphaned blob rather than a row pointing at nothing. Orphans cost a little
 * quota; a dangling row is a broken file in the UI.
 */
export async function deleteObject(objectKey: string, userId: string): Promise<void> {
  if (!isKeyOwnedBy(objectKey, userId)) {
    throw new Error('Refusing to delete an object key outside the user namespace');
  }
  await client().send(new DeleteObjectCommand({ Bucket: bucket(), Key: objectKey }));
}
