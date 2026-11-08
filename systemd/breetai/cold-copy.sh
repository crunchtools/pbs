#!/usr/bin/bash
# cold-copy.sh -- run pbs's ColdCopy module when the backup drive is unlocked.
#
# WHY THIS IS UNLOCK-DRIVEN AND NOT ON A TIMER.
#
# breetai is a Red Hat CSB. falcon-sensor (CrowdStrike EDR, kernel-level file
# visibility), fleet-osquery with redhat-internal-osquery-xfti-yara-rules
# (remote-queryable, content-scans files off disk) and csb-cron (Red Hat IT
# Ansible playbooks) all run as root. LUKS protects a drive that has been
# stolen; it does nothing against root on the machine that mounts it. So while
# the drive is mounted, its plaintext is readable by those agents.
#
# The unlock mode cannot change whether that is true, only how long the window
# stays open. A keyfile in /etc/crypttab would hold it open for the whole dock
# session. Requiring the passphrase holds it open for the length of one sync --
# but only if the sync starts by itself, because a backup that waits for someone
# to remember is the backup that just got retired: the 512 GB micro-SD rotted
# from 2026-11-02 and nobody noticed for months (RT#1547).
#
# So: unlocking the drive IS the trigger. Scott plugs in, types the passphrase,
# this runs, and the drive re-locks itself. No timer -- a timer would fire on a
# locked drive, find nothing to do, and succeed, which is a check that passes by
# accident.
#
# Consequence worth knowing: do NOT let GNOME remember the passphrase. Saving it
# to the keyring is keyfile auto-unlock with extra steps, and it silently
# reverts the decision above.
#
# THE DRIVE IS STILL THE WEAK LINK, NOT THE STRONG ONE. It is the only
# independent copy. The pCloud-to-pCloud rotations stay, because they defend
# against accidental deletion of the live tree, which a mirror cannot.
#
# Staleness is caught by check_cold_copy_freshness.sh on gloval, which reads the
# marker this run writes to pcloud:/Backups/Rotations/. That check is the whole
# reason this is safe to depend on a human plugging a cable in, so do not remove
# it when the drive eventually moves to a dedicated host.

set -uo pipefail

LUKS_UUID=e692da8c-d6fe-4809-9f01-8f686ace1149
DM=/dev/mapper/luks-$LUKS_UUID
BACKING=/dev/disk/by-uuid/$LUKS_UUID
IMAGE=${PBS_IMAGE:-quay.io/crunchtools/pbs:latest}
RCLONE_CONF=${RCLONE_CONF:-$HOME/.config/rclone/rclone.conf}
# Set KEEP_MOUNTED=1 to browse the drive after the sync instead of re-locking.
KEEP_MOUNTED=${KEEP_MOUNTED:-0}

log() { echo "cold-copy: $*"; }

mount_point() {
    findmnt -n -o TARGET --source "$DM" 2>/dev/null | head -1
}

release_drive() {
    local mp
    if [ "$KEEP_MOUNTED" = "1" ]; then
        log "KEEP_MOUNTED=1, leaving the drive mounted"
        return 0
    fi

    mp=$(mount_point)
    if [ -n "$mp" ]; then
        log "unmounting $mp"
        udisksctl unmount -b "$DM" --no-user-interaction \
            || log "WARNING: unmount failed; the plaintext window is still open"
    fi

    if [ -e "$DM" ]; then
        log "locking $BACKING"
        udisksctl lock -b "$BACKING" --no-user-interaction \
            || log "WARNING: lock failed; the drive is still decrypted"
    fi
}

# ColdCopy.service's ExecStopPost backstop calls back in here rather than
# inlining udisksctl, so KEEP_MOUNTED has exactly one implementation. Inlined,
# the backstop locked the drive even when KEEP_MOUNTED=1 and the documented
# escape hatch silently did nothing through systemd.
if [ "${1:-}" = "--release-only" ]; then
    release_drive
    exit 0
fi

if [ ! -e "$DM" ]; then
    log "$DM does not exist -- drive locked or unplugged, nothing to do"
    exit 0
fi

MOUNT=$(mount_point)
if [ -z "$MOUNT" ]; then
    log "$DM is unlocked but not mounted; nothing to do"
    exit 0
fi
log "drive mounted at $MOUNT"

# Records a COMPLETED run, as an epoch. Its only job is to stop a .path re-fire
# from restarting a sync that just finished, and a re-fire happens within
# seconds, so the window is an hour rather than a day.
#
# It held a date until pbs 2.6.1, which was too coarse in both directions: it
# blocked every deliberate re-run for the rest of the day, and when a bad run
# stamped it (see the marker check at the end) the drive was shut out until
# midnight. A non-epoch value now reads as absent, so an old date-stamped file
# self-heals into a run rather than a skip.
STAMP="$MOUNT/.cold-copy-last-success"
SKIP_WINDOW=${SKIP_WINDOW:-3600}
last=$(cat "$STAMP" 2>/dev/null)
case $last in
    ''|*[!0-9]*) last=0 ;;
esac
if [ "$last" -gt 0 ] && [ $(( $(date +%s) - last )) -lt "$SKIP_WINDOW" ]; then
    log "completed $(( ($(date +%s) - last) / 60 ))m ago, inside the ${SKIP_WINDOW}s re-fire window; releasing the drive"
    release_drive
    exit 0
fi

trap release_drive EXIT

if [ ! -r "$RCLONE_CONF" ]; then
    log "FATAL: no rclone config at $RCLONE_CONF"
    exit 1
fi

# Pull every run. podman reuses a local image by tag without checking the
# registry, and on 2026-11-08 that meant a :latest from 2026-10-06 ran instead
# of 2.6.0 -- an image with no ColdCopy module at all. A stale image is the one
# failure that looks most like a working backup.
log "pulling $IMAGE"
podman pull -q "$IMAGE" || log "WARNING: pull failed, running whatever is local"

# --security-opt label=disable, not :Z. udisks mounts with seclabel, so every
# file on the drive carries a real SELinux label; :Z would relabel all ~762k of
# them on every run. udisks 2.11.2 does not allow context= in its mount options,
# so a whole-filesystem context mount is not available while udisks owns the
# mount. Scott's own data on Scott's own drive: disabling the label check for
# this one job is the cheaper trade.
log "starting pbs ColdCopy"
started=$(date +%s)
podman run --rm \
    --name pbs-cold-copy \
    --security-opt label=disable \
    -v "$RCLONE_CONF:/etc/rclone.conf:ro" \
    -v "$MOUNT:/data" \
    --tmpfs /tmp:rw \
    --network=host \
    "$IMAGE" \
    -B -m ColdCopy -d /data
status=$?

if [ $status -ne 0 ]; then
    log "ColdCopy exited $status"
    exit $status
fi

# AN EXIT CODE IS NOT EVIDENCE. This checks the outcome instead: ColdCopy
# rewrites its marker after every item, so a marker older than this run means
# no item completed, whatever the container's exit code claimed.
#
# This guard exists because the unguarded version was wrong on its first real
# run. A stale pbs:latest did not recognise ColdCopy's -d, printed usage, exited
# 0 -- usage() did that until pbs 2.6.1 -- and this script wrote the success
# stamp and logged "ColdCopy finished clean" over a run that copied nothing.
# That is the same failure backup_ColdCopy refuses three ways internally, and it
# does no good there if the wrapper around it still reports a clean backup.
marker="Backups/Rotations/ColdCopy.$(hostname -f)"
marker_epoch=$(rclone lsjson --config "$RCLONE_CONF" "pcloud:$marker" 2>/dev/null \
    | sed -n 's/.*"ModTime":"\([^"]*\)".*/\1/p' | head -1)
marker_epoch=$([ -n "$marker_epoch" ] && date -d "$marker_epoch" +%s 2>/dev/null)

if [ -z "$marker_epoch" ]; then
    log "FATAL: ColdCopy exited 0 but wrote no marker at pcloud:$marker."
    log "       Not recording this run. Check the image really carries the"
    log "       ColdCopy module: podman inspect $IMAGE --format '{{.Config.Labels.version}}'"
    exit 1
fi
# 120s of slack for clock skew between here and pCloud, not for a stale marker:
# a marker from a previous run is minutes to weeks old, nowhere near this.
if [ "$marker_epoch" -lt $((started - 120)) ]; then
    log "FATAL: ColdCopy exited 0 but its marker is from $(date -d "@$marker_epoch")"
    log "       and this run started $(date -d "@$started"). No item completed."
    exit 1
fi

date +%s > "$STAMP"
log "ColdCopy finished clean, marker confirmed at $(date -d "@$marker_epoch")"
exit 0
