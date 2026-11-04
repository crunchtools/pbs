#!/usr/bin/env python3
"""Apply _host/srv-metadata.gz from a Servers backup to a restored /srv tree.

Creates missing directories and symlinks, then sets owners and modes. Then
SELinux: imports the tree's selinux-local/config/local.semanage (the host's
booleans, ports and file-context rules) if present, and runs restorecon over
the tree, so labels come from those rules rather than from whatever a file
happened to carry on the old host. restorecon keeps container_file_t, which
podman sets per container. Runs on the restored host as root. Exits nonzero if
any entry or the SELinux step failed.
"""

import argparse
import gzip
import os
import shlex
import stat
import subprocess
import sys

BLOCK_SIZE = 1 << 20


def entries(manifest):
    """Yield (kind, mode, uid, gid, context, path, target) records as bytes.

    The manifest is NUL-terminated records of tab-separated fields, read a
    block at a time. Raises ValueError on a malformed or truncated manifest.
    """
    pending = b""
    with gzip.open(manifest, "rb") as stream:
        while block := stream.read(BLOCK_SIZE):
            records = (pending + block).split(b"\0")
            pending = records.pop()
            for record in records:
                fields = record.split(b"\t", 6)
                if len(fields) != 7:
                    raise ValueError(f"malformed manifest record: {record!r}")
                yield fields
    if pending:
        raise ValueError("manifest is truncated")


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
    match kind:
        case b"d":
            if not os.path.isdir(dest) or os.path.islink(dest):
                os.mkdir(dest)
        case b"l":
            if os.path.islink(dest):
                os.unlink(dest)
            os.symlink(target, dest)
        case _:
            if not os.path.lexists(dest):
                return False
            if not stat.S_ISREG(os.lstat(dest).st_mode):
                raise ValueError("expected a regular file")
    os.chown(dest, int(uid), int(gid), follow_symlinks=False)
    if kind != b"l":
        os.chmod(dest, int(mode, 8))
    return True


def apply_selinux(root, semanage, restorecon):
    """Import the tree's local SELinux export, then relabel the tree.

    Args:
        root: the restored tree, as an absolute bytes path (``os.fsencode``).
        semanage: the semanage command as an argument list, e.g.
            ``["/usr/sbin/semanage"]``.
        restorecon: the restorecon command as an argument list.

    Returns True when both steps succeeded. The import is skipped when the
    live customizations already match the export: it rebuilds the policy.
    """
    export = os.path.join(root, b"selinux-local", b"config", b"local.semanage")
    if os.path.isfile(export):
        with open(export, "rb") as stream:
            wanted = stream.read()
        live = subprocess.run([*semanage, "export"], capture_output=True, check=False)
        if live.returncode != 0 or live.stdout != wanted:
            print(f"Importing {os.fsdecode(export)}")
            if subprocess.run([*semanage, "import", "-f", export], check=False).returncode != 0:
                print("semanage import failed", file=sys.stderr)
                return False
    else:
        print("No selinux-local/config/local.semanage: local SELinux rules not imported")
    print(f"Relabeling {os.fsdecode(root)}")
    if subprocess.run([*restorecon, "-R", root], check=False).returncode != 0:
        print("restorecon failed", file=sys.stderr)
        return False
    return True


def main():
    """Apply the manifest named on the command line. Returns the exit status."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest")
    parser.add_argument("root")
    parser.add_argument(
        "--no-selinux", action="store_true", help="skip the SELinux import and relabel"
    )
    parser.add_argument("--semanage", default="/usr/sbin/semanage", help="semanage command")
    parser.add_argument("--restorecon", default="/usr/sbin/restorecon", help="restorecon command")
    args = parser.parse_args()
    root = os.path.realpath(os.fsencode(args.root))
    checked = set()
    missing = failed = 0
    for fields in entries(args.manifest):
        try:
            if not apply_entry(root, fields, checked):
                missing += 1
        except (OSError, ValueError) as error:
            failed += 1
            print(f"{fields[5]!r}: {error}", file=sys.stderr)
    print(f"Files in the manifest but not restored: {missing}")
    print(f"Entries that could not be applied: {failed}")
    selinux_ok = args.no_selinux or apply_selinux(
        root, shlex.split(args.semanage), shlex.split(args.restorecon)
    )
    return 1 if failed or not selinux_ok else 0


if __name__ == "__main__":
    sys.exit(main())
