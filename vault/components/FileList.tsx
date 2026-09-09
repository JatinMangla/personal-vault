'use client';

/**
 * File list.
 *
 * Single-column cards on phones, wider rows from 768px. Every action is a real
 * button with a 44px target — nothing is revealed on hover, because a
 * hover-only control is unreachable on touch.
 */

import { formatBytes, formatRelative } from '@/lib/thresholds';
import type { DecryptedFile } from '@/lib/transfer';

interface FileListProps {
  files: DecryptedFile[];
  busyKey: string | null;
  onDownload: (file: DecryptedFile) => void;
  onDelete: (file: DecryptedFile) => void;
}

export function FileList({ files, busyKey, onDownload, onDelete }: FileListProps) {
  if (files.length === 0) {
    return <p className="muted">No documents yet.</p>;
  }

  return (
    <ul className="file-list">
      {files.map((file) => {
        const busy = busyKey === file.object_key;
        return (
          <li key={file.id} className="card file-item">
            <div className="min-w-0">
              <div className="truncate bold">
                {file.metadata.filename}
              </div>
              <div className="faint">
                {formatBytes(file.metadata.plaintextSize || file.size_bytes)} ·{' '}
                {formatRelative(new Date(file.created_at).getTime())}
              </div>
              {file.metadata.tags.length > 0 && (
                <div className="faint truncate">{file.metadata.tags.join(', ')}</div>
              )}
            </div>

            {/* Actions are always visible. Wraps to its own line at 360px. */}
            <div className="actions">
              <button
                type="button"
                onClick={() => onDownload(file)}
                disabled={busy}
                aria-label={`Download ${file.metadata.filename}`}
              >
                {busy ? 'Working…' : 'Download'}
              </button>
              <button
                type="button"
                className="btn-danger"
                onClick={() => onDelete(file)}
                disabled={busy}
                aria-label={`Delete ${file.metadata.filename}`}
              >
                Delete
              </button>
            </div>
          </li>
        );
      })}
    </ul>
  );
}
