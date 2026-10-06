# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `systemd/lotor/`: PersonalBackups units for lotor that run the `Files` module
  only (pcloud to pcloud). The personal rotations moved off the laptop when it
  became a managed endpoint (RT #1503).
- `Files` module rotates `pcloud:/Projects`. Projects moved out of
  `Documents/Professional` to the top level on 2026-10-05, which dropped it
  from every rotation.

### Changed

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
