"""Re-export platform-neutral archive safety helpers for `nspb_qt.win.*` callers."""
from __future__ import annotations

from ..archive_guard import (
    ArchiveQuota,
    ArchiveSafetyError,
    DEFAULT_MAX_BYTES,
    DEFAULT_MAX_ENTRIES,
    clean_archive_relpath,
    extract_zip_safely,
    install_staged_tree,
    is_same_or_within,
    is_within,
    materialize_unix_symlinks,
    rmtree_force,
    win_path,
)

__all__ = [
    'ArchiveQuota',
    'ArchiveSafetyError',
    'DEFAULT_MAX_BYTES',
    'DEFAULT_MAX_ENTRIES',
    'clean_archive_relpath',
    'extract_zip_safely',
    'install_staged_tree',
    'is_same_or_within',
    'is_within',
    'materialize_unix_symlinks',
    'rmtree_force',
    'win_path',
]
