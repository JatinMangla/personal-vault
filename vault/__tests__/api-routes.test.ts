/**
 * API route handlers - authentication, ownership, quota and ingest signing.
 *
 * WHY. All four bugs that reached production were in paths no test touched;
 * the crypto core had 46 tests and the routes had none. These run the real
 * handlers against a recording fake of Supabase, so they prove what a route
 * DID NOT do as well as what it did - e.g. that no URL was ever signed for an
 * object key outside the caller's namespace.
 *
 * RLS itself is tested for real in supabase/tests/rls.test.sql; here the fake
 * returns what RLS would.
 */

import { createHmac } from 'node:crypto';
import { beforeEach, describe, expect, it, vi } from 'vitest';

type Result = { data: unknown; error: unknown };

const USER_A = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const USER_B = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

const state = {
  user: null as { id: string } | null,
  tables: {} as Record<string, Result>,
  rpc: { data: 0, error: null } as Result,
  calls: [] as unknown[][],
  signedUploads: [] as string[],
  signedDownloads: [] as string[],
  removed: [] as string[],
};

/** A chainable, awaitable stand-in for a PostgREST query builder. */
function builder(table: string) {
  const b: Record<string, unknown> = {};
  for (const m of ['select', 'insert', 'delete', 'update', 'eq', 'order', 'limit', 'gte']) {
    b[m] = (...args: unknown[]) => {
      state.calls.push([table, m, ...args]);
      return b;
    };
  }
  const result = () => Promise.resolve(state.tables[table] ?? { data: null, error: null });
  b.maybeSingle = result;
  b.single = result;
  b.then = (ok: (r: Result) => unknown, fail: (e: unknown) => unknown) => result().then(ok, fail);
  return b;
}

vi.mock('@/lib/supabase-server', () => ({
  serverClient: async () => ({
    auth: {
      getUser: async () =>
        state.user
          ? { data: { user: state.user }, error: null }
          : { data: { user: null }, error: { name: 'AuthSessionMissingError' } },
    },
    from: (t: string) => builder(t),
    rpc: async (name: string) => {
      state.calls.push(['rpc', name]);
      return state.rpc;
    },
  }),
  serviceClient: () => ({
    from: (t: string) => builder(`service:${t}`),
    storage: {
      from: () => ({
        createSignedUploadUrl: async (key: string) => {
          state.signedUploads.push(key);
          return { data: { signedUrl: `https://x.supabase.co/up/${key}`, token: 't', path: key }, error: null };
        },
        createSignedUrl: async (key: string) => {
          state.signedDownloads.push(key);
          return { data: { signedUrl: `https://x.supabase.co/down/${key}` }, error: null };
        },
        remove: async (keys: string[]) => {
          state.removed.push(...keys);
          return { error: null };
        },
      }),
    },
  }),
}));

const presignUpload = await import('@/app/api/presign-upload/route');
const presignDownload = await import('@/app/api/presign-download/route');
const files = await import('@/app/api/files/route');
const ingest = await import('@/app/api/metrics/ingest/route');
const { resetRateLimits } = await import('@/lib/rate-limit');
const { MAX_SINGLE_UPLOAD_BYTES, STORAGE_SOFT_LIMIT_BYTES } = await import('@/lib/storage');

function post(body: unknown, headers: Record<string, string> = {}): Request {
  return new Request('http://localhost/api', {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: typeof body === 'string' ? body : JSON.stringify(body),
  });
}

function del(body: unknown): Request {
  return new Request('http://localhost/api', { method: 'DELETE', body: JSON.stringify(body) });
}

beforeEach(() => {
  state.user = { id: USER_A };
  state.tables = {};
  state.rpc = { data: 0, error: null };
  state.calls = [];
  state.signedUploads = [];
  state.signedDownloads = [];
  state.removed = [];
  resetRateLimits();
});

describe('every user route refuses a request with no session', () => {
  it.each([
    ['presign-upload', () => presignUpload.POST(post({ objectKey: `${USER_A}/x`, size: 1 }))],
    ['presign-download', () => presignDownload.POST(post({ objectKey: `${USER_A}/x` }))],
    ['files GET', () => files.GET()],
    ['files POST', () => files.POST(post({}))],
    ['files DELETE', () => files.DELETE(del({ objectKey: `${USER_A}/x` }))],
  ])('%s -> 401', async (_name, call) => {
    state.user = null;
    expect((await call()).status).toBe(401);
    expect(state.signedUploads.concat(state.signedDownloads, state.removed)).toEqual([]);
  });
});

describe('POST /api/presign-upload', () => {
  it('signs a key inside the caller namespace', async () => {
    const res = await presignUpload.POST(post({ objectKey: `${USER_A}/abc`, size: 1000 }));
    expect(res.status).toBe(200);
    expect(state.signedUploads).toEqual([`${USER_A}/abc`]);
  });

  it('refuses another user namespace and signs nothing', async () => {
    const res = await presignUpload.POST(post({ objectKey: `${USER_B}/abc`, size: 1000 }));
    expect(res.status).toBe(403);
    expect(state.signedUploads).toEqual([]);
  });

  it('refuses path traversal and signs nothing', async () => {
    const res = await presignUpload.POST(post({ objectKey: `${USER_A}/../${USER_B}/x`, size: 1 }));
    expect(res.status).toBe(403);
    expect(state.signedUploads).toEqual([]);
  });

  it('refuses an upload over the single-file limit', async () => {
    const res = await presignUpload.POST(
      post({ objectKey: `${USER_A}/abc`, size: MAX_SINGLE_UPLOAD_BYTES + 1 }),
    );
    expect(res.status).toBe(413);
    expect(state.signedUploads).toEqual([]);
  });

  it('refuses at the soft quota, counting what is already stored', async () => {
    state.rpc = { data: STORAGE_SOFT_LIMIT_BYTES - 10, error: null };
    const res = await presignUpload.POST(post({ objectKey: `${USER_A}/abc`, size: 11 }));
    expect(res.status).toBe(507);
    expect(state.signedUploads).toEqual([]);
  });

  it('fails closed when the quota cannot be read', async () => {
    state.rpc = { data: null, error: { message: 'down' } };
    const res = await presignUpload.POST(post({ objectKey: `${USER_A}/abc`, size: 1 }));
    expect(res.status).toBe(500);
    expect(state.signedUploads).toEqual([]);
  });

  it('rejects malformed input', async () => {
    expect((await presignUpload.POST(post('not json'))).status).toBe(400);
    expect((await presignUpload.POST(post({ objectKey: `${USER_A}/a`, size: -1 }))).status).toBe(400);
    expect((await presignUpload.POST(post({ size: 1 }))).status).toBe(400);
  });
});

describe('POST /api/presign-download', () => {
  it('404s a key the caller has no row for (RLS hides it), signing nothing', async () => {
    state.tables.files = { data: null, error: null };
    const res = await presignDownload.POST(post({ objectKey: `${USER_B}/abc` }));
    expect(res.status).toBe(404);
    expect(state.signedDownloads).toEqual([]);
  });

  it('signs the caller own file', async () => {
    state.tables.files = { data: { object_key: `${USER_A}/abc` }, error: null };
    const res = await presignDownload.POST(post({ objectKey: `${USER_A}/abc` }));
    expect(res.status).toBe(200);
    expect(state.signedDownloads).toEqual([`${USER_A}/abc`]);
  });
});

describe('/api/files', () => {
  it('GET returns the list and the quota, querying both', async () => {
    state.tables.files = { data: [{ id: '1' }], error: null };
    state.rpc = { data: 1234, error: null };
    const res = await files.GET();
    expect(res.status).toBe(200);
    const body = (await res.json()) as { files: unknown[]; quota: { used: number } };
    expect(body.files).toHaveLength(1);
    expect(body.quota.used).toBe(1234);
    expect(state.calls).toContainEqual(['rpc', 'user_storage_bytes']);
  });

  it('POST records a file and sends no filename hash', async () => {
    state.tables.files = { data: { id: '1' }, error: null };
    const res = await files.POST(
      post({ objectKey: `${USER_A}/abc`, encryptedMetadata: 'm', encryptedManifest: 'x', sizeBytes: 5 }),
    );
    expect(res.status).toBe(201);
    const insert = state.calls.find((c) => c[0] === 'files' && c[1] === 'insert');
    expect(insert?.[2]).toEqual({
      user_id: USER_A,
      object_key: `${USER_A}/abc`,
      encrypted_metadata: 'm',
      encrypted_manifest: 'x',
      size_bytes: 5,
    });
  });

  it('POST refuses a key outside the caller namespace', async () => {
    const res = await files.POST(
      post({ objectKey: `${USER_B}/abc`, encryptedMetadata: 'm', encryptedManifest: 'x', sizeBytes: 5 }),
    );
    expect(res.status).toBe(403);
    expect(state.calls.some((c) => c[1] === 'insert')).toBe(false);
  });

  it('DELETE of a row the caller does not own is a 404 and removes no blob', async () => {
    state.tables.files = { data: [], error: null };
    const res = await files.DELETE(del({ objectKey: `${USER_B}/abc` }));
    expect(res.status).toBe(404);
    expect(state.removed).toEqual([]);
  });

  it('DELETE removes the row, then the blob', async () => {
    state.tables.files = { data: [{ id: '1' }], error: null };
    const res = await files.DELETE(del({ objectKey: `${USER_A}/abc` }));
    expect(res.status).toBe(200);
    expect(state.removed).toEqual([`${USER_A}/abc`]);
  });
});

describe('POST /api/metrics/ingest', () => {
  const SECRET = 'test-secret-not-real';

  function signed(payload: Record<string, unknown>) {
    const body = JSON.stringify(payload);
    const sig = createHmac('sha256', SECRET).update(body).digest('hex');
    return post(body, { 'x-signature': `sha256=${sig}` });
  }

  const now = () => Math.floor(Date.now() / 1000);
  const good = () => ({ timestamp: now(), storage: {}, system: {} });

  beforeEach(() => {
    vi.stubEnv('METRICS_INGEST_SECRET', SECRET);
  });

  it('accepts a correctly signed, fresh sample', async () => {
    state.tables['service:metrics_samples'] = { data: null, error: null };
    expect((await ingest.POST(signed(good()))).status).toBe(201);
  });

  it('rejects a missing or forged signature', async () => {
    expect((await ingest.POST(post(good()))).status).toBe(401);
    expect((await ingest.POST(post(good(), { 'x-signature': 'sha256=' + '0'.repeat(64) }))).status).toBe(401);
  });

  it('rejects a replay older than five minutes', async () => {
    expect((await ingest.POST(signed({ ...good(), timestamp: now() - 301 }))).status).toBe(401);
  });

  it('refuses everything when no secret is configured', async () => {
    vi.stubEnv('METRICS_INGEST_SECRET', '');
    expect((await ingest.POST(signed(good()))).status).toBe(503);
  });

  it('never answers GET', async () => {
    expect((await ingest.GET()).status).toBe(405);
  });
});
