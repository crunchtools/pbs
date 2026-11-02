#!/usr/bin/env python3
"""Apply _host/srv-metadata.gz from a Servers backup to a restored /srv tree.

Creates missing directories and symlinks, then sets owners and modes. Runs on
the restored host as root. Exits nonzero if any entry could not be applied.

Usage: restore_metadata.py <srv-metadata.gz> <restored-srv-dir>
"""

import gzip
import os
import stat
import sys


def entries(manifest):
    with gzip.open(manifest, "rb") as stream:
        records = stream.read().split(b"\0")
    if records.pop() != b"":
        raise ValueError("manifest is truncated")
    for record in records:
        fields = record.split(b"\t", 6)
        if len(fields) != 7:
            raise ValueError(f"malformed manifest record: {record!r}")
        yield fields


def safe_parent(root, path, checked):
    """Return the parent of path under root, refusing to leave root."""
    parts = path.split(b"/")
    if path.startswith(b"/") or any(p in (b"", b".", b"..") for p in parts):
        raise ValueError("unsafe path")
    parent = root
    for part in parts[:-1]:
        parent = os.path.join(parent, part)
        if parent not in checked:
            if not stat.S_ISDIR(os.lstat(parent).st_mode):
                raise ValueError("parent is not a real directory")
            checked.add(parent)
    return parent


def apply_entry(root, fields, checked):
    """Apply one record. Returns False for a file the backup did not restore."""
    kind, mode, uid, gid, _context, path, target = fields
    if kind not in (b"d", b"f", b"l"):
        return True
    dest = os.path.join(safe_parent(root, path, checked), path.rsplit(b"/", 1)[-1])
    if kind == b"d":
        if not os.path.isdir(dest) or os.path.islink(dest):
            os.mkdir(dest)
    elif kind == b"l":
        if os.path.islink(dest):
            os.unlink(dest)
        os.symlink(target, dest)
    elif not os.path.lexists(dest):
        return False
    elif not stat.S_ISREG(os.lstat(dest).st_mode):
        raise ValueError("expected a regular file")
    os.chown(dest, int(uid), int(gid), follow_symlinks=False)
    if kind != b"l":
        os.chmod(dest, int(mode, 8))
    return True


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    root = os.path.realpath(os.fsencode(sys.argv[2]))
    checked = set()
    missing = failed = 0
    for fields in entries(sys.argv[1]):
        try:
            if not apply_entry(root, fields, checked):
                missing += 1
        except (OSError, ValueError) as error:
            failed += 1
            print(f"{fields[5]!r}: {error}", file=sys.stderr)
    print(f"Files in the manifest but not restored: {missing}")
    print(f"Entries that could not be applied: {failed}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
