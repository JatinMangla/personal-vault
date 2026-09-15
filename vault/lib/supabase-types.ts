/**
 * Shared row and payload types.
 *
 * Types only — no runtime code, no imports with side effects. Safe to import
 * from both client and server without dragging server-only modules into the
 * browser bundle.
 */

export interface FileRow {
  id: string;
  user_id: string;
  object_key: string;
  encrypted_metadata: string;
  encrypted_manifest: string;
  filename_hash: string | null;
  size_bytes: number;
  created_at: string;
  updated_at: string;
}

export interface UserKeysRow {
  user_id: string;
  kdf_salt: string;
  kdf_iterations: number;
  recovery_wrapped_key: string | null;
  passphrase_verifier: string | null;
  created_at: string;
  updated_at: string;
}

export interface MetricsSampleRow {
  id: number;
  collected_at: string;
  host: string;
  payload: MetricsPayload;
  created_at: string;
}

/** Shape pushed by ops/metrics/collect-and-push.sh. */
export interface MetricsPayload {
  timestamp: number;
  collected_at: string;
  host: string;
  storage: {
    block_total: number;
    block_used: number;
    block_avail: number;
    boot_total: number;
    boot_used: number;
    boot_avail: number;
    originals_bytes: number;
    upload_bytes: number;
    library_bytes: number;
    thumbs_bytes: number;
    encoded_video_bytes: number;
    profile_bytes: number;
    backups_bytes: number;
    /**
     * Insta360 drain staging, one file in flight. Optional: samples collected
     * before the drain loop existed have no such field, and the dashboard must
     * render those rows without it.
     */
    staging_bytes?: number;
  };
  /**
   * Syncthing, the phone -> VM half of the archive pipeline.
   *
   * Optional: the collector did not query Syncthing at all before 2026-09-16,
   * so every sample older than that lacks the whole object — not merely a
   * field. Guard with `payload.sync?` and coalesce each number.
   */
  sync?: {
    /** Syncthing's own folder state: idle, scanning, syncing, error, unknown. */
    state: string;
    /** Bytes the VM still expects to receive for this transfer. */
    need_bytes: number;
    need_files: number;
    /** Files the phone has announced, and files the VM actually holds. */
    global_files: number;
    local_files: number;
    /**
     * Whether the phone is connected right now. False also means "Syncthing
     * could not be reached" — unknown is reported as disconnected rather than
     * claiming a connection nothing verified.
     */
    connected: boolean;
  };
  /**
   * Insta360 card -> Telegram drain progress, from tg-archive's state file.
   * Optional for the same reason as staging_bytes: older samples predate it,
   * and the collector reports `idle` when no drain has ever run.
   */
  archive?: {
    status: 'idle' | 'running' | 'complete' | 'incomplete';
    /**
     * Which step of the current batch is running. `status` cannot distinguish
     * hashing from uploading from the 20-minute Check #2 download; this can.
     * Empty string between batches, and absent on samples predating it.
     */
    phase?: 'hashing' | 'uploading' | 'downloading' | 'rejoining' | 'verifying' | 'clearing' | '';
    /** The file the current phase is working on, when it applies to one. */
    phase_file?: string;
    /** Position within the batch, e.g. uploading 3 of 8. 0 when not applicable. */
    phase_index?: number;
    phase_total?: number;
    /** Files fingerprinted in the manifest. */
    total: number;
    /** Verified into Telegram. */
    done: number;
    remaining: number;
    /** Unix seconds when tg-archive last wrote its state. */
    updated: number;
    /**
     * Total bytes archived to Telegram, summed from the ledger's size column.
     * Rows written before 2026-09-15 carry no size, so this UNDER-reports on an
     * archive that predates it — `bytes_unknown` says how many such rows exist.
     */
    bytes?: number;
    /** Archived files whose size was never recorded. 0 once the old rows age out. */
    bytes_unknown?: number;
  };
  immich: {
    photo_count: number;
    video_count: number;
    usage_photos: number;
    usage_videos: number;
    /** Whole-disk figure from Immich's API. NEVER display as "Immich usage". */
    api_disk_figure: number;
    failed_jobs: number;
    /**
     * False when the Immich API could not be reached or its response schema
     * did not match. Without this, an API change is indistinguishable from
     * "you have zero photos" - the counts below would simply read 0.
     * Older samples predate this field, hence optional.
     */
    api_ok?: boolean;
    api_warning?: string;
  };
  backup: {
    last_backup_ts: number;
    last_backup_status: string;
    snapshot_count: number;
    repo_bytes: number;
    last_check_status: string;
    last_drill_ts: number;
    last_drill_result: string;
  };
  containers: {
    server: string;
    machine_learning: string;
    redis: string;
    database: string;
  };
  system: {
    mem_total: number;
    mem_used: number;
    mem_available: number;
    swap_total: number;
    swap_used: number;
    load1: number;
    load5: number;
    load15: number;
    uptime_seconds: number;
  };
}
