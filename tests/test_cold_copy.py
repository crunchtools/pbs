"""Run the cold-copy guard suite under pytest, so CI actually runs it.

`[tool.pytest.ini_options] testpaths = ["tests"]` is what `sdlc ci` drives, and
pytest does not collect bare shell scripts. Without this wrapper
`test-cold-copy.sh` would sit in the repo unrun, which is worse than having no
test at all: the guards it pins are the ones that stop a backup that copied
nothing from reporting success, and a test nobody runs cannot notice when they
regress.

The logic lives in the shell script because the thing under test is a shell
script, and rewriting its guards in Python would test a reimplementation rather
than what runs on breetai.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

SUITE = Path(__file__).parent / "test-cold-copy.sh"


def test_cold_copy_guards() -> None:
    """cold-copy.sh's marker guard, re-fire stamp and release path, plus pbs.sh's
    CLI exit contract. The script prints one line per case and exits nonzero if
    any failed; its output is attached on failure."""
    assert SUITE.is_file(), f"missing suite: {SUITE}"
    proc = subprocess.run(
        ["bash", str(SUITE)],
        capture_output=True,
        text=True,
        timeout=300,
        check=False,
    )
    assert proc.returncode == 0, (
        f"test-cold-copy.sh failed (exit {proc.returncode})\n"
        f"--- stdout ---\n{proc.stdout}\n--- stderr ---\n{proc.stderr}"
    )
    # A suite that silently stopped collecting cases would otherwise pass.
    assert "passed, 0 failed" in proc.stdout, f"unexpected summary:\n{proc.stdout}"
