# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed

- **`systemd/lotor/` is now `systemd/gloval/`.** The six rotations have run on
  gloval since the lotor migration (RT #1503); only the directory name still
  said otherwise. A unit directory in this repo is named for the host that runs
  it — that is what `systemd/breetai/` means, and it is the only thing that
  tells a reader where to install a unit. Naming a decommissioned host sends
  whoever next has to restore these rotations to the wrong machine, which is
  the worst possible time to be reading a stale directory name.

  Pure relocation: the six unit files are byte-identical to 2.7.2 and match what
  is deployed on gloval. No image change, no unit behaviour change, so no
  version bump.

- References updated to follow: the unit-path assertions in
  `tests/test-cold-copy.sh`, the `systemd/lotor/` precedent cited in
  `gourmand-exceptions.toml` for shipping `cold-copy.sh` beside its units,
  the `/host` mount comment in `pbs.sh`, and the Purpose and "Rotations and
  Host Units" sections of `.specify/memory/constitution.md` (1.4.0), which now
  state the naming rule rather than leaving it to be inferred from two
  examples.

### Added

- One assertion that all six rotation units are present in the directory the
  tests look in. The existing eighteen assertions do fail when that path is
  wrong, but as a single failure on a literal glob rather than as "the units
  are not there" — and a unit that went missing from a correct directory would
  not have shown up at all. 61 cases total.

## [2.7.3] - 2026-11-09

### Fixed

- **Two perpetually-written trees were costing a full extra walk of `/srv`
  every Servers run.** InfluxDB's write-ahead log is appended to continuously,
  so rclone reports "source file is being updated" on it, and a single such
  error fails the whole attempt — rclone then re-walks the entire tree for
  attempt 2.

  Measured on the 2026-11-09 run started by hand to verify RT #1566: attempt 1
  failed with 4 errors at 01:57 UTC, attempt 2 succeeded at 02:08, and the run
  finished in 24m21s. Roughly half of that was a re-count that moved no bytes.
  A failed attempt also suppresses directory deletion ("not deleting
  directories as there were IO errors"), so the destination keeps what the
  source dropped and the following week's walk is longer still.

  Excluding the WAL is also the more correct answer, not only the cheaper one:
  a raw copy of a live WAL is torn, and InfluxDB replaying a torn WAL on
  restore is worse than restoring without one. The compacted data beside it is
  kept, which is what a restore rebuilds from; the cost is the last unflushed
  window of metrics. Follows the precedent set for the constantly-rewritten
  Matrix sync cursor rather than raising the error tolerance, which would have
  masked real failures too.

- **mypy caches are no longer synced or staged.** They sit under the dev
  sandboxes' work trees and are build artifacts like the `__pycache__`
  directories beside them, but their contents are `.db` files, so the `*.pyc`
  exclude never covered them — and being `.db`, the SQLite staging pass picked
  them up as well and logged "sqlite3 .backup failed, copying raw file" for
  each one.

### Added

- Four static assertions over the Servers exclude list. The one that matters
  most asserts the *absence* of a broadened pattern: excluding the whole
  InfluxDB engine directory instead of just its WAL would silently drop the
  compacted metrics a restore depends on, and would read as a tidy-up in
  review. 64 cases total, all passing. rclone's own pattern-matching depth
  semantics stay untested offline, as podman's do — they were verified against
  rclone 1.75.2 by hand.

### Known issue

- Three InfluxDB WAL directories last written 2026-11-03 remain in Weekly-1 at
  the destination. The new excludes will never refresh or remove them, and
  `--delete-excluded` is deliberately absent, so they need a deliberate one-off
  prune. A restore would otherwise be handed a stale WAL beside newer compacted
  data. Recorded in `pbs.sh` beside the exclude list rather than deleted as
  part of a release.

## [2.7.2] - 2026-11-09

### Fixed

- **The same orphaned-container wedge 2.7.1 fixed for the cold copy, in all six
  rotations.** Each now carries
  `ExecStartPre=-/usr/bin/podman rm <container>`.

  Found by testing 2.7.0's new inhibitor on gloval rather than trusting it:
  starting `PersonalBackups-Monthly-1` registered the lock correctly
  (`pbs / shutdown / block / pCloud rotation Files/Monthly-1 in flight`), and
  then `systemctl stop` left the unit `failed`, released the inhibitor, and
  left the container **still copying**. The name stays taken, so the next run
  would have died on podman's exit 125 until someone removed it by hand.

  `podman rm` without `-f` refuses a running container and the leading `-`
  lets that failure pass, so a dead leftover is cleared and the run proceeds,
  while a rotation genuinely in flight is never killed to redo the same work.
  That case still fails on the name — loud, but self-clearing once the
  container exits, which is the difference between an alert and a wedge.

### Added

- Nineteen static assertions over the six rotation units, from a Gatehouse
  finding on #59: each unit's pre-start `podman rm` names **its own**
  container, the removal is `-`-prefixed so a refusal does not fail the unit,
  the inhibitor is `--mode=block` and not `block-weak` (which reads the same in
  review and is waved through for root), and no two rotations share a container
  name. A copy-paste in those names would have one rotation deleting another's
  container mid-run, which is worse than the wedge this release fixes.
  Behaviour is podman's and stays untested offline. 60 cases total.

### Known limitation

- The inhibitor's lifetime is the podman **client's**, not the container's. In
  the normal path they end together. After a `systemctl stop` that orphans the
  container, the copy carries on with no lock held, so a reboot in that window
  can still kill it. Closing that needs the lock held by something that outlives
  the client, which is a larger change than this one.

## [2.7.1] - 2026-11-08

### Fixed

- **An orphaned container name wedged the cold copy permanently.** `podman run
  --rm` does not clean up when the wrapper is killed mid-run: the container
  carries on, detached, and keeps the `pbs-cold-copy` name. Every run after it
  died on "the container name is already in use" with podman's exit 125 — not a
  transient failure, a permanent one, until someone removed that container by
  hand.

  Found at 00:45 on 2026-11-09 while clearing an acknowledged **Cold Copy
  Freshness CRITICAL** that had been red since 22:56 UTC. A run was killed at
  17:27, its container ran on for three more hours, and each retry failed in
  eight seconds — so the check was right, the copy was stuck at 5 of 11 items,
  and the acknowledgement was hiding it.

  `cold-copy` now looks for that container before starting. A **running** one
  means a cold copy is already in flight: it logs, drops its claim and exits 0,
  leaving both the container and the drive alone. Only a **dead** one is
  removed. Not `--replace`, which would kill live work to start the same work
  over.

  The check sits above `trap release_drive EXIT`, with the other two decisions
  not to work, and it matters: `release_drive` does not consult the claim file —
  only the `--release-only` backstop does — so exiting from below the trap
  would lock the drive out from under the very container being protected. That
  is the 2.6.2 bug from the other direction.

### Added

- Seven cases for the orphan: a dead container is removed and the run proceeds;
  a running one is not killed, not removed, starts no second sync, keeps the
  drive mounted and hands back its claim. The podman stub now answers `ps` and
  records `rm`. 41 cases total.

## [2.7.0] - 2026-11-08

### Added

- **Every rotation now holds a block shutdown inhibitor while it runs.** All six
  units wrap `podman run` in `systemd-inhibit --what=shutdown --mode=block
  --who=pbs`, so a reboot requested while a rotation is in flight is refused
  rather than granted (RT #1594).

  On 2026-11-08 at 03:30, `bootc upgrade --apply` rebooted gloval and SIGKILLed
  `ServerBackups-Weekly-1` at 93%, 36 minutes from the end of a ten-hour
  transfer. Nothing coordinated the two, and the weekly rotation is the only
  copy eight of the fifteen server databases have (RT #1547). The run retried
  on its own and nothing was lost that night, but a ten-hour window against an
  update path that reboots unattended collides again by arithmetic.

  The lock is taken on the host, around the container, not inside it: logind
  lives on the host and the lock has to outlive nothing but the run itself.
  `--mode=block` is load-bearing — logind waves `block-weak` through for root
  unless the caller explicitly asks for the check, and rejects a strong block
  outright whatever the caller's uid or TTY. The guard is deliberately
  caller-agnostic, which is what makes it work against a reboot nobody has yet
  traced to a scheduler.

  Consequence worth knowing before it surprises someone: a deliberate reboot
  during a rotation is now refused too. `systemctl reboot -i` overrides it, and
  `systemd-inhibit --list` names the holder and the rotation.

  The matching half, which turns that refusal into a deferral rather than a
  skipped update, ships in `rhel10-bootc-server` as a drop-in and a retry
  timer; the two are useless apart.

## [2.6.3] - 2026-11-08

### Fixed

- **The marker was named after `hostname -f`, which on breetai is the CSB name**
  — `smccarty-thinkpadx1carbongen12.rmtusoh.csb`. That name changed when the
  laptop was reinstalled on 2026-10-04 and will change again. The marker's
  filename is derived from it, so a rename leaves an orphaned marker that can
  never be refreshed and a **Cold Copy Freshness CRITICAL that nothing can
  clear**.

  This is the exact trap `check_personal_backup_freshness.sh` documents for its
  hard-coded directory list — walked into from the other direction, in the same
  afternoon, after reading that warning.

  `COLD_HOST` now names the host in the marker, defaulting to `hostname -f` so
  gloval and lotor are unchanged (there it *is* the fleet name).
  `systemd/breetai/ColdCopy.service` sets it to `breetai.dc2.crunchtools.com`,
  matching where `pcloud-sync` already writes that host's Projects backup. The
  wrapper passes it into the container, or `pbs.sh` would fall back to the
  container's own hostname.

  **Rolling this out requires deleting the old marker**
  (`pcloud:Backups/Rotations/ColdCopy.<old CSB name>`), or both exist and the
  stale one is the permanent CRITICAL described above. Renaming without that
  cleanup causes the very failure this fixes.

### Added

- Three tests: that `COLD_HOST` names the marker, that `hostname -f` is not
  consulted when it is set, and the unset fallback. 34 cases total.

## [2.6.2] - 2026-11-08

### Fixed

- **The cold copy was locking the drive out from under the person unlocking it**,
  which looked exactly like a rejected passphrase. Found on real hardware, on
  the first unlock after the drive moved to a USB 3 port.

  `ColdCopy.path` triggers on the LUKS device node, which appears *before* udisks
  has mounted the filesystem. The script found the drive unlocked-but-unmounted,
  logged "nothing to do" and exited 0 — and then `ColdCopy.service`'s
  unconditional `ExecStopPost` backstop locked the drive, destroying `dm-1` under
  GNOME's in-flight mount:

  ```
  udisksd:     Unlocked device /dev/sda1 as /dev/dm-1
  cold-copy:   ...is unlocked but not mounted; nothing to do
  udisksd:     Locked device /dev/sda1 (was unlocked as /dev/dm-1)
  gnome-shell: Unable to mount volume data: fsconfig() failed: Can't lookup blockdev
  ```

  Every manual unlock undid itself about a second later. Nothing was wrong with
  the passphrase, the drive or the LUKS header.

  Three changes, and the second is the one that matters:

  - **It waits for the mount** (`MOUNT_WAIT`, 30s) instead of giving up in the
    window udisks needs.
  - **Only a run that claimed the drive may release it.** A claim file is taken
    once a mount is in hand, and `--release-only` leaves an unclaimed drive
    alone. A backstop that locks whatever it finds is not a backstop, it is a
    second actor on the same device. It still releases a claimed drive, so the
    plaintext window still closes when the script is killed outright.
  - **The re-fire skip no longer locks the drive either.** The previous run
    already locked it, so the only way that path sees it mounted is that someone
    just unlocked it deliberately — and locking it back is fighting them.

  This is the second time the `ExecStopPost` backstop has been wrong in the same
  way. 2.6.1 made it respect `KEEP_MOUNTED`; it also needed to respect *whether
  this run did anything at all*.

### Added

- Eight tests for the race, including a `findmnt` stub that reports nothing for
  the first N calls and then answers, which is what udisks actually does. Also
  made the suite order-independent: one run returned 30/1 unreproducibly before
  each case cleared the claim file, and a suite whose result depends on case
  order is not evidence of anything. 31 cases, five consecutive clean runs.

## [2.6.1] - 2026-11-08

### Fixed

- **`usage()` exited 0 on an unrecognised option**, so an invocation pbs did not
  understand reported success. Found on ColdCopy's first real run, in the worst
  possible way: podman reused a local `pbs:latest` from 2026-10-06 instead of
  pulling 2.6.0, that image had no ColdCopy module and did not know `-d`,
  getopts fell through to `h|*`, usage printed, pbs exited 0 — and
  `cold-copy.sh` wrote its success stamp and logged `ColdCopy finished clean`
  over a run that copied nothing.

  An unknown option now goes to `usage_error`, which prints the same text and
  exits 2. `-h` still exits 0, because asking for help is not an error. This is
  the general case, not a ColdCopy quirk: any caller newer than the image it
  runs hit it, silently.

- `cold-copy.sh` **pulls the image every run**. podman reuses a local image by
  tag without consulting the registry, and a stale image is the failure that
  looks most like a working backup.

- `cold-copy.sh` **verifies the marker instead of trusting the exit code.**
  ColdCopy rewrites its marker after every item, so a marker older than the run
  means no item completed, whatever the container claimed. 2.6.0 refused three
  different ways internally to report a success it had not earned, and that does
  no good at all if the wrapper around it reports a clean backup anyway.

- The re-fire stamp holds an **epoch with a one-hour window**, not a date. A
  date was too coarse both ways: it blocked every deliberate re-run for the rest
  of the day, and a bad run that stamped it shut the drive out until midnight. A
  non-epoch value now reads as absent, so an old date-stamped file self-heals.

- The marker check compares **pCloud's own timestamp before the run against its
  own timestamp after**, rather than the marker against local time. The old form
  needed 120s of slack for clock skew, and that slack was itself a hole: a run
  that updated the marker and then died before stamping, retried inside the
  window, passed on the *first* run's marker. There is now no slack, because
  both sides of the comparison come from the same clock. Caught by Gatehouse
  on #54.

### Added

- `tests/test-cold-copy.sh` and the `tests/test_cold_copy.py` wrapper that makes
  `sdlc ci` run it — 23 cases over the guards above, with podman, rclone,
  udisksctl, findmnt and hostname stubbed, so nothing touches pCloud, a real
  drive or a container.

  Every case is a way for a backup that copied nothing to report success, and
  one of them is what actually happened. They were untested until Gatehouse
  asked on #54, which was the right question: these guards are the whole reason
  a human-triggered backup is safe to depend on, and a guard nobody tests is a
  guard that quietly stops working. Pinned: exit 0 with no marker, exit 0 with a
  marker that did not move, a marker a day old that did not move, a nonzero
  container status, a legacy date-valued stamp, a malformed stamp, the window
  boundary at 3599s and 3700s, `KEEP_MOUNTED=1`, `--release-only`, that a failed
  run still locks the drive, and that `-h` exits 0 while an unknown option
  exits 2.

### Verified in passing

The drive's unmount-and-re-lock works from a systemd **user** unit —
`udisksctl unmount` and `udisksctl lock` both succeeded with no polkit prompt,
which was the open question about whether the plaintext window could be closed
without root.

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

  **Three ways it refuses to report a success it did not earn.** Every one of
  these is the same failure in a different costume — a run that copied nothing
  and said it was fine, which is how a backup rots unnoticed.

  - *Not a mount point.* A bind mount that did not happen is indistinguishable
    from an empty directory, so without this check the run writes 733 GiB into
    the container's own filesystem and exits 0.
  - *Discovery failed.* `cold_discover` captures the `rclone lsf` output instead
    of piping it, so a listing error is visible rather than arriving as an empty
    list. Not hypothetical: the pCloud token on lotor was found revoked
    2026-10-05 after rclone was authorized elsewhere, and every job failed.
  - *Discovery succeeded and found nothing.* A backup source that has suddenly
    gone empty is never good news, and "no work to do" is the wrong reading.

  `verify_ColdCopy` likewise accumulates every `rclone check` exit status and
  returns failure if any item mismatched. A verify that always returns success
  is worse than no verify: it is the micro-SD's green light.

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

  The `ExecStopPost` backstop calls `cold-copy --release-only` rather than
  inlining `udisksctl`, so the release path — and `KEEP_MOUNTED` — has one
  implementation. Inlined, it locked the drive even with `KEEP_MOUNTED=1`, which
  made the documented escape hatch silently useless through systemd.

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
