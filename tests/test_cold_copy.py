"""Run the host-unit and CLI guard suite under pytest, so CI actually runs it.

`[tool.pytest.ini_options] testpaths = ["tests"]` is what `sdlc ci` drives, and
pytest does not collect bare shell scripts. Without this wrapper
`test-cold-copy.sh` would sit in the repo unrun, which is worse than having no
test at all: the guards it pins are the ones that stop a backup that copied
nothing from reporting success, and a test nobody runs cannot notice when they
regress.

The checks live in a shell script because what they pin are unit files and a
shell entrypoint; restating them in Python would test a reimplementation.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

SUITE = Path(__file__).parent / "test-cold-copy.sh"


def test_cold_copy_guards() -> None:
    """The host units' guards (mount, container, inhibitor, attic pruning) and
    pbs.sh's CLI exit contract. The script prints one line per case and exits nonzero if
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
