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
    def run_manifest(self, *records):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = pathlib.Path(self.tmp.name)
        self.root = self.base / "root"
        self.root.mkdir()
        (self.root / "file").write_text("x")
        manifest = self.base / "manifest.gz"
        with gzip.open(manifest, "wb") as stream:
            stream.write("".join(records).encode())
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(manifest), str(self.root)],
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


if __name__ == "__main__":
    unittest.main()
