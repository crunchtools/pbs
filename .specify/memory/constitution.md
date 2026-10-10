# pbs Constitution

> **Version:** 1.3.0
> **Ratified:** 2026-03-23
> **Amended:** 2026-10-06
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.22.0
> **Profile:** Container Image

This file holds what is specific to pbs (Personal Backup System). The fleet
rules and the Container Image profile apply at the inherited version and are
checked against this repo's files by `constitution.yml`. They are not restated
here.

## Purpose

Containerized backup system that runs rclone-based backups of pCloud
directories and home directories. Triggered by systemd timers on bootc hosts
via `podman run`. A personal infrastructure tool, not a public service.

## Image Contents

- **Base:** `registry.access.redhat.com/ubi10/ubi-minimal`, packages via
  `microdnf`.
- **EPEL:** `etc/epel.repo` and `etc/RPM-GPG-KEY-EPEL-10` are copied into the
  image to get `rclone`, so no RHSM secrets are needed at build time.
- **Packages:** `rclone`, `sqlite`, `file`, `findutils`, `hostname`,
  `openssh-clients`, `gnupg2`, `podman-remote`.
- **Entrypoint:** `pbs.sh` (Bash). Default command is a `Weekly-1` backup of
  the `Files` and `HomeDirectories` modules.

## Rotations and Host Units

The `systemd/` units are the host side of the contract. Each runs the image
once with `--network=host`, a tmpfs `/tmp`, `/etc/rclone.conf` read-only and
`/home` and `/var/home` read-only.

The `systemd/lotor/` units are the exception: they run the `Files` module only,
which syncs pCloud to pCloud and reads nothing from the host, so they mount
`/etc/rclone.conf` and nothing else. They keep the same schedule.

| Rotation | Timer schedule |
|----------|----------------|
| `Weekly-1` | Fridays 06:00 |
| `Monthly-1` | 1st of odd months, 04:00 |
| `Monthly-2` | 1st of even months, 04:00 |

## Rotation Markers

After each sync the `Files` module writes one line to
`pcloud:/Backups/Rotations/Files.<directory>.<rotation>`:

```
Files|<directory>|<rotation>|<start epoch>|<end epoch>|<rclone exit>
```

The marker is written whether the sync succeeded or not. Its only consumer is
`check_personal_backup_freshness.sh` in `crunchtools/nagios-agent`, which reads
the whole folder in one call. The file name and the field order are an
interface: changing either is a MAJOR release, made together with that check.

## History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-03-23 | Initial constitution |
| 1.1.0 | 2026-10-02 | Manifest under constitution v1.18.0: fleet and profile restatement removed; image contents and rotation units kept |
| 1.2.0 | 2026-10-04 | `systemd/lotor/` units added: Files module only, no host mounts beyond `rclone.conf` (RT #1503) |
| 1.3.0 | 2026-10-06 | Rotation markers added as an interface to the nagios-agent check (#16) |
