# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.2.0] - 2026-11-02

### Fixed

- Remove `--size-only` from every `rclone sync`. A changed file of the same
  size was never uploaded, leaving stale files in the backups: RocksDB
  `CURRENT`, TLS keys, WordPress code.
- `Servers` keeps empty directories.

### Added

- `Servers` records owners, modes, symlinks and SELinux labels for `/srv` in
  `_host/srv-metadata.gz`; `scripts/restore_metadata.py` applies them after a restore.

## [2.1.0] - 2026-11-02

### Added

- `Servers` module archives host state to `_host/host-config.tar.gz` when
  `/host` is mounted: `/etc`, home directories without `.local`, `.cache` and
  `work`, and `/var/lib/trentina-tunnel`. `rclone.conf`, password hashes and
  private keys are left out. A tarball keeps owners, modes and unit enablement
  symlinks. Found by the lotor backup audit (RT #1546).
- `systemd/lotor/ServerBackups-*.service`, with the `/host` mounts.

### Fixed

- A database whose container is stopped is archived as
  `backups/<dir>-stopped.tar.gz` rather than skipped. The data directory is
  excluded from the sync, so an idle dev site had no restorable database. A
  failed archive makes the run exit nonzero after syncing.

### Fixed

- `systemd/lotor/*.service` run with `--pull=newer`. Nothing refreshed
  `pbs:latest` on lotor, so a release never reached its backups; these one-shot
  jobs cannot use auto-update, which could restart one mid-backup. Pull errors
  are suppressed when a local image exists, so a Quay outage does not fail a run.

## [2.0.1] - 2026-10-28

### Fixed

- When `sqlite3 .backup` fails and pbs falls back to a raw `cp` of the
  database, the warning now prints at normal verbosity, like the MariaDB and
  PostgreSQL dump warnings. It used to print only with `-v`, so a fallback
  copy that might be torn never reached the journal (RT #1537).

### Removed

- `systemd/lotor/*.timer`. Hermes jobs have scheduled the lotor rotations
  since 2026-10-16, so redeploying these timers would run every backup
  twice. The `Wants=<unit>.timer` lines in the lotor services, which
  pointed at the deleted timers, are gone too.

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
