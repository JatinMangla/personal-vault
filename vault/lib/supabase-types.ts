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
  };
  immich: {
    photo_count: number;
    video_count: number;
    usage_photos: number;
    usage_videos: number;
    /** Whole-disk figure from Immich's API. NEVER display as "Immich usage". */
    api_disk_figure: number;
    failed_jobs: number;
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
