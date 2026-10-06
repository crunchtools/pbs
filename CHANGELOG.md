# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.0.0] - 2026-10-06

### Added

- `Files` module writes a one-line marker to
  `pcloud:/Backups/Rotations/Files.<directory>.<rotation>` after each sync:
  `Files|<directory>|<rotation>|<start epoch>|<end epoch>|<rclone exit>`. It is
  written on failure too. `check_personal_backup_freshness.sh` in
  `crunchtools/nagios-agent` reads the folder, so a stalled or failed personal
  rotation raises a Nagios alert (#16).
- `systemd/lotor/`: PersonalBackups units for lotor that run the `Files` module
  only (pcloud to pcloud). The personal rotations moved off the laptop when it
  became a managed endpoint (RT #1503).
- `Files` module rotates `pcloud:/Projects`. Projects moved out of
  `Documents/Professional` to the top level on 2026-10-05, which dropped it
  from every rotation.

### Changed

- **Breaking:** `Files` module excludes `.venv/`, `node_modules/`,
  `__pycache__/` and `*.pyc`, with `--delete-excluded`: the first run of each
  rotation removes those trees from it (#17). `.git/` is still backed up. On
  2026-10-06 only 9 of 149,277 files matched, so this guards against the trees
  coming back and does not change run time. That run spent 16 of its 17
  minutes on 16,673 server-side copies, and listing all four trees took 13
  seconds, so pCloud's `copyfolder` was not benchmarked: it would copy every
  file on every rotation.
- **Breaking:** a backup exits non-zero when a `Files` sync or its marker
  fails, or when no rotation is given, so the systemd unit fails with it. It
  used to exit 0.
- Sync calls log one stats line a minute (`--stats 1m --stats-one-line`)
  instead of `--progress`, which wrote two journal lines a second: 636,849
  lines from the lotor Weekly-1 unit in two days.
- `Files` module passes `--fast-list`: one recursive pCloud listing per tree
  instead of one request per directory. Measured on lotor with a dry run:
  Documents (108,000 files) 1m16s to 9s, Projects (40,000 files) 2m39s to 4s.
  Peak memory rises from about 60 MB to about 510 MB on Documents.
- Constitution is now a v1.18.0 manifest: it holds only what is specific to
  this repo; fleet and profile rules apply by reference.
- Constitution validation is pinned to the inherited release via
  `.github/workflows/constitution.yml`.
- Dependabot auto-merges GitHub Actions minor and patch updates.

## [1.0.0] - 2026-09-20

First tagged release. This image has been running in production since before
it had version control; this release marks the current state as the baseline
going forward.
