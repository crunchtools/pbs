# pbs Constitution

> **Version:** 1.0.0
> **Ratified:** 2026-03-23
> **Status:** Active
> **Inherits:** [crunchtools/constitution](https://github.com/crunchtools/constitution) v1.4.0
> **Profile:** Container Image

This constitution establishes the core principles, constraints, and workflows that govern all development on pbs (Personal Backup System).

---

## I. Purpose

Containerized backup system that runs rclone-based backups of pCloud directories and home directories. Triggered by systemd timers on bootc hosts via `podman run`.

---

## II. Technology Stack

| Layer | Technology |
|-------|------------|
| Language | Bash |
| Container Base | UBI 10 Minimal |
| Package Manager | microdnf |
| Backup Tool | rclone |
| Database Tool | SQLite |

---

## III. Distribution

| Channel | Command |
|---------|---------|
| Container | `podman run quay.io/crunchtools/pbs` |

Single distribution channel. This is a personal infrastructure tool, not a public service.

---

## IV. Naming Conventions

| Context | Name |
|---------|------|
| GitHub repo | `crunchtools/pbs` |
| Container image | `quay.io/crunchtools/pbs` |
| License | AGPL-3.0-or-later |

---

## V. Versioning

Follow [Semantic Versioning 2.0.0](https://semver.org/) strictly. MAJOR/MINOR/PATCH.

---

## VI. Container Conventions

- **Containerfile** at the repo root (not `Dockerfile`)
- Base image: `registry.access.redhat.com/ubi10/ubi-minimal`
- Required **LABEL** metadata: `maintainer` and `description` (per the universal constitution)
- Packages installed with `microdnf` (`dnf` family); EPEL repo files copied in (no RHSM secrets needed)
- Registry: Quay.io only (no GHCR)
- Weekly rebuild cron (Monday 6 AM UTC) picks up base image updates
- GHA layer caching (`cache-from: type=gha`, `cache-to: type=gha,mode=max`)

---

## VII. Testing

| Test | What it verifies | Required |
|------|------------------|----------|
| **Build test** | CI builds the image from the Containerfile on every push and PR | Yes |
| **Smoke test** | Container starts and `rclone version` responds | Recommended |
| **Security scan** | Trivy CVE scan on every push | Recommended |

---

## VIII. Quality Gates

Every change must pass before merge or push to registry:

1. **Build** — `podman build -f Containerfile .` succeeds
2. **Smoke test** — container starts without error
3. **Security scan** — Trivy scan completes (`continue-on-error: true`)

---

## IX. Governance

### Amendment Process

1. Create a PR with proposed changes to this constitution
2. Document rationale in PR description
3. Require maintainer approval
4. Update version number upon merge

### Ratification History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-03-23 | Initial constitution |
