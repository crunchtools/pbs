"""Round trip for scripts/restore_metadata.py. Run: python3 tests/test_restore_metadata.py"""

import gzip
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).parent.parent / "scripts" / "restore_metadata.py"
UID, GID = os.getuid(), os.getgid()


def record(kind, mode, path, target=""):
    return f"{kind}\t{mode}\t{UID}\t{GID}\t?\t{path}\t{target}\0"


class RestoreMetadata(unittest.TestCase):
    def run_manifest(self, *records, selinux=None):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = pathlib.Path(self.tmp.name)
        self.root = self.base / "root"
        self.root.mkdir()
        (self.root / "file").write_text("x")
        manifest = self.base / "manifest.gz"
        with gzip.open(manifest, "wb") as stream:
            stream.write("".join(records).encode())
        flags = selinux if selinux is not None else ["--no-selinux"]
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(manifest), str(self.root), *flags],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_restores_directories_links_and_modes(self):
        result = self.run_manifest(
            record("d", "750", "empty dir"),
            record("f", "755", "file"),
            record("l", "777", "link", "file"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "empty dir").stat().st_mode & 0o777, 0o750)
        self.assertEqual((self.root / "file").stat().st_mode & 0o777, 0o755)
        self.assertEqual(os.readlink(self.root / "link"), "file")

    def selinux_stubs(self, live="same", import_rc=0, restorecon_rc=0):
        """Stub semanage and restorecon that log their arguments."""
        self.log = self.base / "calls"
        stub = self.base / "stub"
        stub.write_text(
            "#!/bin/sh\n"
            f'echo "$0 $*" >> {self.log}\n'
            f'case "$1" in export) printf %s "$EXPORT";; import) exit {import_rc};; esac\n'
            f'case "$0" in *restorecon) exit {restorecon_rc};; esac\n'
        )
        stub.chmod(0o755)
        os.symlink(stub, self.base / "restorecon")
        os.environ["EXPORT"] = "boolean -m -1 x\n" if live == "same" else "boolean -m -0 x\n"
        self.addCleanup(os.environ.pop, "EXPORT", None)
        return ["--semanage", str(stub), "--restorecon", str(self.base / "restorecon")]

    def write_export(self):
        config = self.root / "selinux-local" / "config"
        config.mkdir(parents=True)
        (config / "local.semanage").write_text("boolean -m -1 x\n")

    def run_selinux(self, **stub):
        self.run_manifest()  # creates the tree
        self.write_export()
        manifest = self.base / "manifest.gz"
        with gzip.open(manifest, "wb") as stream:
            stream.write(b"")
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(manifest),
                str(self.root),
                *self.selinux_stubs(**stub),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_selinux_relabels_and_skips_matching_import(self):
        result = self.run_selinux(live="same")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text()
        self.assertNotIn(" import ", calls)
        self.assertIn(f"restorecon -R {self.root}", calls)

    def test_selinux_imports_when_live_differs(self):
        result = self.run_selinux(live="differs")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("import -f", self.log.read_text())

    def test_failed_import_fails_the_restore(self):
        self.assertEqual(self.run_selinux(live="differs", import_rc=1).returncode, 1)

    def test_failed_relabel_fails_the_restore(self):
        self.assertEqual(self.run_selinux(restorecon_rc=1).returncode, 1)

    def test_counts_missing_files(self):
        result = self.run_manifest(record("f", "644", "gone"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("not restored: 1", result.stdout)

    def test_refuses_traversal(self):
        result = self.run_manifest(record("d", "755", "../escaped"))
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.base / "escaped").exists())

    def test_refuses_symlinked_parent(self):
        outside = "../outside"
        result = self.run_manifest(
            record("l", "777", "link", outside), record("d", "755", "link/escaped")
        )
        self.assertEqual(result.returncode, 1)
        self.assertFalse((self.base / "outside" / "escaped").exists())

    def test_truncated_manifest_fails(self):
        result = self.run_manifest(record("d", "755", "a")[:-1])
        self.assertNotEqual(result.returncode, 0)

    def test_malformed_record_fails(self):
        result = self.run_manifest("d\t755\0")
        self.assertNotEqual(result.returncode, 0)

    def test_continues_after_failed_entry(self):
        result = self.run_manifest(record("d", "755", "../escaped"), record("d", "755", "later"))
        self.assertEqual(result.returncode, 1)
        self.assertTrue((self.root / "later").is_dir())
        self.assertIn("could not be applied: 1", result.stdout)

    def test_replaces_existing_symlink(self):
        result = self.run_manifest(
            record("l", "777", "link", "old"), record("l", "777", "link", "file")
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(os.readlink(self.root / "link"), "file")


if __name__ == "__main__":
    unittest.main()
