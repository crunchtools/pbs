# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.6.0] - 2026-11-08

### Added

- `ColdCopy` module: copies pCloud to a local drive, which is the first copy of
  any of this that lives outside the pCloud account.

  **What was actually broken.** The personal "backup" was pCloud to pCloud —
  `backup_Files` syncs `pcloud:/Documents` into
  `pcloud:/Backups/Documents/<rotation>`. Same account, same provider, same
  failure domain. It defends against deleting the live tree by accident and
  nothing else, so **627.5 GiB of Documents had zero copies outside pCloud**,
  and so did 11 of 15 server databases — `mcp-memory`, the memory graph, and
  `trentina`, the gateway, among them. A 3-2-1 violation where much of the data
  was at one copy on one provider. The 512 GB micro-SD that was supposed to be
  the independent medium had been broken since at least 2026-11-02 and was
  retired on 2026-11-07; it had no monitoring, which is why months passed
  unnoticed (RT#1547).

  **The item list is discovered, not declared.** `cold_discover` lists the
  account and `cold_skip` drops what is a copy of something else already in it
  (the rotation copies, the orphaned `Backups/Projects`, the marker folder,
  trash). Everything else is copied. An include list would have been shorter and
  wrong in the one way that matters: it silently drops whatever nobody
  remembered to add, and that is by definition what nobody was thinking about.
  The comment block in nagios-agent's `check_personal_backup_freshness.sh`
  records the same lesson from the other direction — a hand-kept list that
  drifted from `pbs.sh` left a marker that could never be refreshed and a
  CRITICAL nobody could clear. `cold_priority` orders the known names
  worst-loss-first and anything new is appended, so drift costs ordering, never
  coverage. 733 GiB in ~762k files across 11 items today.

  **`--backup-dir`, so this is a backup and not a mirror.** `rclone sync`
  propagates deletions, so without it a bad delete or a ransomware pass in
  pCloud would be reproduced faithfully onto the only independent copy. Changed
  and deleted files move to a dated attic instead, and the module warns below
  10% free so the attic gets pruned before a sync fails for want of space.

  **It refuses to run on a directory that is not a mount point.** A bind mount
  that did not happen is indistinguishable from an empty directory, so the
  failure mode without this check is writing 733 GiB into the container's own
  filesystem and reporting success.

  **One marker, rewritten after every item**, to
  `pcloud:/Backups/Rotations/ColdCopy.<fqdn>`, one line per item in the existing
  `Files|` format. Rewritten rather than written once at the end because
  Documents alone runs for hours: a run killed part way should show what it
  managed, not look like it never ran. nagios-agent 8.6.0 reads these as **Cold
  Copy Freshness**.

  No `--fast-list` on `Backups/Servers`: ~603k files, and fast-list holds every
  entry in memory at once. Same reason `backup_Servers` omits it (2.5.0/2.5.2).

- `verify_ColdCopy`, using `rclone check --checksum`. pCloud serves sha1, so
  both sides are compared by hash without downloading anything. This is the
  check that would have caught the micro-SD going bad.

- `-d <path>` for the ColdCopy destination inside the container (default
  `/data`).

- `systemd/breetai/`: `ColdCopy.path`, `ColdCopy.service` and `cold-copy.sh`,
  as **user** units.

  **Unlocking the drive is the trigger, and there is no timer.** breetai is a
  Red Hat CSB: `falcon-sensor`, `fleet-osquery` with the XFTI YARA
  content-scanning rules, and `csb-cron` all run as root. LUKS protects a drive
  that has been stolen; it does nothing against root on the host that mounts it.
  So the unlock mode cannot change *whether* that plaintext is readable, only
  how long the window stays open — and a keyfile in `/etc/crypttab` would hold
  it open for the whole dock session. Requiring the passphrase holds it open for
  one sync, but only if the sync starts on its own, because a backup that waits
  for someone to remember is the backup that was just retired. `ColdCopy.path`
  watches the dm node, so it fires on unlock wherever udisks mounts it, and
  re-arms when the service re-locks the drive. A timer was rejected: it would
  fire on a locked drive, find nothing to do, and succeed — a check that passes
  by accident.

  `--security-opt label=disable` rather than `:Z`, because udisks mounts with
  `seclabel` and `:Z` would relabel all ~762k files on every run; udisks 2.11.2
  does not allow `context=` in its mount options, so a whole-filesystem context
  mount is not available while udisks owns the mount.

  The drive re-locks from an `EXIT` trap, with `ExecStopPost` as a backstop for
  the script being killed outright. `KEEP_MOUNTED=1` leaves it mounted for
  browsing. A stamp file records a *completed* run, so a `.path` re-fire does
  not restart a sync that just finished while an interrupted one still resumes.

### Note

The pCloud-to-pCloud rotations stay. They defend against accidental deletion of
the live tree, which a mirror cannot, and `--backup-dir` gives the cold copy its
own cheaper version of that defence. Two mechanisms, two different threats.

## [2.5.2] - 2026-11-08

### Fixed

- Correct the stated reason `*/data/containers/` was excluded in 2.5.0. That
  release said the sync "went backwards ... because the runner builds while
  rclone walks it". The exclusion is right and the measurements are right, but
  the mechanism was not: this sync passes no `--fast-list`, so rclone
  enumerates as it walks and the `total` in its stats line rises for as long as
  discovery continues. A falling percentage is progressive discovery, not the
  source outrunning the copy. The run after 2.5.1 showed the same shape at a
  sixth of the scale — total 506 MiB to 1.7 GiB and 2,358 to 20,831 files in 24
  minutes, while `/srv` grew about 1 MB/min, which would make those 18,473
  files average 160 bytes each.

  What stands unchanged: the run was still going after ten hours and was killed
  twice before finishing, `*/data/containers/` really is 1,190,137 files and
  49.5 GiB of regenerable podman store, excluding it cut the work by about six
  times, and the live-write races are real — `error reading source directory`
  on a vanished uv build tempdir, `source file is being updated` on files that
  grew mid-upload. Only the explanation of the rising total was wrong, and it
  was wrong in a code comment, where it would have sent the next reader after a
  problem that is not there.


## [2.5.1] - 2026-11-08

### Fixed

- `backup_sqlite_databases` skips `*/data/containers/*`. Its `-not -path` list
  was written for home directories, so the `Servers` scan walked into the
  sandboxes' nested podman storage and staged **337 of its 465 files**, 1,307 MB
  of 5,945, out of the mypy caches in `crunchtools-hook-cache` — the very tree
  2.5.0 had just excluded from the sync. Because the overlay copy runs *after*
  the sync, those files would have been written straight back into `Weekly-1`,
  making the 2.5.0 exclude a lie and undoing the one-off destination purge.
  Caught before the first 2.5.0 run reached its overlay copy.
- The function now carries the invariant it violated: this scan must skip every
  tree the caller's sync excludes, because the overlay copy is the last word at
  the destination. Add a sync exclude, add it here too.

## [2.5.0] - 2026-11-08

### Fixed

- The `Servers` sync no longer walks `*/data/containers/`. It did not converge:
  on the 2026-11-08 run it went backwards, 93% to 92% over five hours, moving
  0.61 GiB while the target grew 0.79 GiB, ETA swinging between 20m and 2h44m.
  That directory is podman's blob cache and local image store for the CI runner
  and the dev sandboxes, and it is written while rclone walks it, so the same
  run logged `error reading source directory: directory not found` on a uv build
  tempdir and `source file is being updated` on files that changed mid-upload.
  A run that cannot finish is not a backup, and every extra hour is another
  hour a reboot can land on it, which is what caused the 2.4.0 incident.

### Removed from the backup

- `*/data/containers/` — **1,190,137 files and 49.5 GiB** on gloval, across
  `developer1-3` and `gha-runner-cached`, the only services that have one. It
  holds `cache` and `storage`: overlay layers, overlay images, `db.sql`, locks,
  and one named volume, `crunchtools-hook-cache`, a mypy/uv pre-commit cache.
  All of it comes back by pulling the images again; none of it is state a
  restore needs. The real state of those sandboxes is `data/state`
  (developer1: 81,597 files, 3,138 MB), which is still backed up.
- `*/data/state/.config/josui/matrix-sync` — a five-byte Matrix sync cursor,
  rewritten constantly, and the only source of
  `corrupted on transfer: md5 hashes differ`: it changes between rclone's read
  and its verify. A restored client re-syncs.

Because 2.4.0 dropped `--delete-excluded`, neither is pruned from the
destination automatically. `Weekly-1` held 68,597 objects / 4.721 GiB of
container storage for `gha-runner-cached` alone and was purged by hand once;
`Monthly-1` and `Monthly-2` never had any.

### Changed

- `Servers` reports the sync's rclone exit status instead of discarding it, as
  a warning rather than a failure. `data/audit/bridge-transcript-*.jsonl` is
  append-only, so a session that is live while the backup runs makes rclone
  exit nonzero on a run where nothing is wrong; failing there would cry wolf
  every week. Discarding it was worse — a wholesale sync failure left no trace.
  Those transcripts are audit records and are deliberately still backed up.

## [2.4.0] - 2026-11-08

### Fixed

- `Servers` uploads the database dumps, the stopped-container archives and
  `_host/*` **before** the `/srv` sync instead of after it. They exist only in
  the staging directory, so the sync deleted the previous run's copies on its
  way through and only the final copy put new ones back: for the ten hours a
  run takes, `Weekly-1` held no database dumps at all, and a run that died in
  between left none until the next successful run. A bootc update rebooted
  gloval through the Sunday run and Backup Freshness went CRITICAL on five
  missing dumps with nothing wrong at either end.
- Staging is split in two by whether the artifact also exists under `/srv`.
  `/tmp/staging-srv-dest` holds what the destination alone carries and is
  copied first; `/tmp/staging-srv` holds the clean SQLite copies, which share
  their paths with real `/srv` files and so are still copied last, after the
  sync, to be the surviving version.

### Changed

- The `Servers` sync excludes `/*/backups/all-databases.sql`,
  `/*/backups/*-stopped.tar.gz` and `/_host/**`, and no longer passes
  `--delete-excluded`. Both are needed to leave the early upload alone: plain
  sync deletes a destination file with no source counterpart, and
  `--delete-excluded` deletes exactly what the new excludes name. Nothing at
  the destination matched the pre-existing excludes when this was checked, so
  nothing is lost, but a new exclude from here on needs a deliberate one-off
  prune rather than the sync. `Files` and `HomeDirectories` keep
  `--delete-excluded`; neither has destination-only artifacts.
- The `*-stopped.tar.gz` exclude also stops the sync re-uploading the copies the
  gloval restore left under `/srv/*/backups/` (~605 MB, 2026-11-02, gitignored).
  They are stale snapshots of databases that are dumped properly every run, and
  the sync would otherwise overwrite the fresh archive uploaded above with one
  of them. The residue in `/srv` is worth deleting separately.

## [2.3.1] - 2026-11-06

### Fixed

- `Files` no longer rotates `pcloud:/Projects`. It moved to
  `pcloud:/Backups/Servers/breetai.dc2.crunchtools.com/Projects` on 2026-11-04
  as a one-way backup, so the root folder is gone and Weekly-1 failed with
  "directory not found". Existing `pcloud:/Backups/Projects` rotations are left
  in place.

## [2.3.0] - 2026-11-03

### Changed

- `Servers` backs up `.git` directories under `/srv`. `/srv` is itself a
  repository, and checkouts under it hold history and remotes a restore cannot
  rebuild; on the gloval restore they had to be copied from lotor by hand.
- `scripts/restore_metadata.py` finishes with SELinux: it imports the tree's
  `selinux-local/config/local.semanage` (booleans, ports, file-context rules)
  when it differs from the live host, then runs `restorecon -R` over the tree.
  Labels now come from those rules, not from what each file carried on the old
  host; `container_file_t` is kept by restorecon. `--no-selinux` skips the step.

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
