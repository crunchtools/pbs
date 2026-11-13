#!/bin/bash
# Offline tests for the host units' safety properties and pbs.sh's CLI exit
# contract.
#
# WHY THESE EXIST. Every case below is a way for a backup that copied nothing to
# report success, or for one run to break another. ColdCopy's first real run
# (2026-11-08) is the example: a stale pbs:latest did not recognise `-d`, printed
# usage, exited 0, and the run was stamped clean. pbs.sh now exits nonzero for an
# unknown option and refuses a destination that is not a mount point; the units
# fail before the container starts if their volume is missing. Those guards are
# only worth having if they stay, so they are pinned here.
#
# Nothing here touches pCloud, a real drive or a container: the unit files are
# checked statically and pbs.sh is only asked about its own options.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PBS="$HERE/../pbs.sh"
PASS=0
FAIL=0

echo "=== the rotation units: the inhibitor and the pre-start cleanup ==="
# These are static assertions on the unit files, not behaviour: podman's own
# semantics (rm refuses a running container, the leading - swallows that) are
# not ours to test offline. What IS ours, and what a copy-paste would break
# silently, is that each unit cleans up ITS OWN container and nobody else's --
# one rotation deleting another's container mid-run would be a far worse bug
# than the wedge this fixes. The inhibitor's --mode is pinned too: block-weak
# is waved through for root and would look identical in review.
#
# A unit directory is named for the host that runs it, so this path moves when
# the rotations move -- as they did from lotor to gloval (RT #1503). The count
# is asserted first because a wrong path is the one way this whole section
# reports nothing interesting: the loop body does fail on a literal glob, but
# only once instead of eighteen times, and a missing unit would not show at all.
UNITS="$HERE/../systemd/gloval"
found=$(ls -1 "$UNITS"/*.service 2>/dev/null | wc -l)
[ "$found" -eq 6 ] \
    && { echo "  PASS: all six rotation units are in $(basename "$UNITS")/"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: expected 6 rotation units in $UNITS, found $found"; FAIL=$((FAIL + 1)); }
for u in "$UNITS"/*.service; do
    n=$(basename "$u" .service)
    name=$(sed -n 's/^ *--name \(.*\) \\$/\1/p' "$u")
    pre=$(sed -n 's/^ExecStartPre=-\/usr\/bin\/podman rm \(.*\)$/\1/p' "$u")
    if [ -n "$name" ] && [ "$pre" = "$name" ]; then
        echo "  PASS: $n cleans up its own container ($name)"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $n cleans up '$pre' but runs '$name'"; FAIL=$((FAIL + 1))
    fi
    grep -q '^ExecStartPre=-/usr/bin/podman rm ' "$u" \
        && { echo "  PASS: $n ignores a failed pre-start removal"; PASS=$((PASS + 1)); } \
        || { echo "  FAIL: $n would fail the unit when rm refuses"; FAIL=$((FAIL + 1)); }
    grep -qE -- '--mode=block([^-]|$)' "$u" \
        && { echo "  PASS: $n holds a strong block inhibitor"; PASS=$((PASS + 1)); } \
        || { echo "  FAIL: $n does not hold --mode=block"; FAIL=$((FAIL + 1)); }
done
# Six rotations, six distinct containers: a duplicate name means two rotations
# share a container and the pre-start rm of one kills the other.
dupes=$(sed -n 's/^ *--name \(.*\) \\$/\1/p' "$UNITS"/*.service | sort | uniq -d)
[ -z "$dupes" ] \
    && { echo "  PASS: every rotation has its own container name"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: duplicate container names: $dupes"; FAIL=$((FAIL + 1)); }

echo "=== exedore: the on-site cold copy unit ==="
# A timer-driven copy is only safe if a missing volume FAILS the run, and the
# guard, the mount dependency and the bind mount must all name the same path --
# a copy-paste that moved one of them would sync into the root filesystem.
EX="$HERE/../systemd/exedore"
unit_has() { # <desc> <grep -E pattern> <file>
    grep -qE -- "$2" "$3" \
        && { echo "  PASS: $1"; PASS=$((PASS + 1)); } \
        || { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
}
mnt=$(sed -n 's/^RequiresMountsFor=//p' "$EX/ColdCopy.service")
[ -n "$mnt" ] && { echo "  PASS: ColdCopy.service requires its mount ($mnt)"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: ColdCopy.service has no RequiresMountsFor"; FAIL=$((FAIL + 1)); }
unit_has "fails the run when $mnt is not mounted" "^ExecStartPre=/usr/bin/mountpoint -q $mnt\$" "$EX/ColdCopy.service"
unit_has "syncs into $mnt and nowhere else"      "-v $mnt:/data " "$EX/ColdCopy.service"
unit_has "cleans up its own container"           '^ExecStartPre=-/usr/bin/podman rm pbs-cold-copy$' "$EX/ColdCopy.service"
unit_has "holds a strong block inhibitor"        '--mode=block([^-]|$)' "$EX/ColdCopy.service"
unit_has "prunes only inside the attic"          "find $mnt/attic -mindepth 1 -maxdepth 1 -type d -mtime \\+[0-9]+ " "$EX/ColdCopy.service"
unit_has "timer catches up after downtime"       '^Persistent=true$' "$EX/ColdCopy.timer"

echo "=== exedore: verify and offline refresh units ==="
# The verify must never be able to write to the copy it judges, must refuse to
# start mid-copy, and must not use Conflicts= (symmetric: a hand-started verify
# would kill an in-flight copy).
unit_has "verify binds the on-site copy read-only" "-v $mnt:/data:ro " "$EX/ColdVerify.service"
unit_has "verify runs pbs -V, not -B"               '-V -m ColdCopy -d /data$' "$EX/ColdVerify.service"
unit_has "verify refuses to start during a copy"    "is-active -q ColdCopy.service" "$EX/ColdVerify.service"
unit_has "verify fails when $mnt is not mounted"    "^ExecStartPre=/usr/bin/mountpoint -q $mnt\$" "$EX/ColdVerify.service"
for u in ColdVerify OfflineCopy; do
    grep -q '^Conflicts=' "$EX/$u.service" \
        && { echo "  FAIL: $u.service uses Conflicts= (would kill a running copy)"; FAIL=$((FAIL + 1)); } \
        || { echo "  PASS: $u.service does not use Conflicts="; PASS=$((PASS + 1)); }
done
# The offline refresh's failure mode was a hand procedure abandoned halfway:
# drive unlocked and mounted, monthly timer stopped. Cleanup must be
# unconditional (ExecStopPost) and in order: unmount, re-lock, timer on.
unit_has "offline refuses without the drive"        '^ExecStartPre=/usr/bin/test -e \$\{SHELF_DEV\}$' "$EX/OfflineCopy.service"
unit_has "offline stops the monthly timer first"    '^ExecStartPre=/usr/bin/systemctl stop ColdCopy.timer$' "$EX/OfflineCopy.service"
unit_has "offline writes to the shelf, not on-site" '-v /var/mnt/shelf:/data ' "$EX/OfflineCopy.service"
stop=$(grep '^ExecStopPost=' "$EX/OfflineCopy.service" | tr '\n' ' ')
case "$stop" in
    *umount\ /var/mnt/shelf*cryptsetup\ close\ shelf*systemctl\ start\ ColdCopy.timer*)
        echo "  PASS: offline always unmounts, re-locks, then restarts the timer"; PASS=$((PASS + 1));;
    *) echo "  FAIL: offline ExecStopPost cleanup missing or out of order"; FAIL=$((FAIL + 1));;
esac
grep -q '^ExecStopPost=.*mount /dev/mapper/shelf' "$EX/OfflineCopy.service" \
    && { echo "  FAIL: offline mounts in ExecStopPost"; FAIL=$((FAIL + 1)); } \
    || { echo "  PASS: offline never mounts on the way out"; PASS=$((PASS + 1)); }

echo "=== the Servers sync: the perpetually-hot trees ==="
# Static assertions on the exclude list, not on rclone's matching -- the depth
# semantics of these patterns are rclone's and were verified against rclone
# 1.75.2 by hand (a bare directory name matches at any depth, so */.mypy_cache/
# catches one nested five levels down). What IS ours is which trees are on the
# list, because a file that is always being written fails the whole attempt and
# costs a full re-walk of /srv: measured 2026-11-09, attempt 1 failed with 4
# errors and attempt 2 succeeded, so half a 24-minute run moved no bytes.
excl() { # <desc> <pattern>
    grep -qF -- "--exclude \"$2\"" "$PBS" \
        && { echo "  PASS: $1"; PASS=$((PASS + 1)); } \
        || { echo "  FAIL: $1 (no --exclude \"$2\")"; FAIL=$((FAIL + 1)); }
}
excl "InfluxDB's write-ahead log is not synced"  '*/data/engine/wal/'
excl "mypy caches are not synced"                '*/.mypy_cache/'
excl "podman's image store is not synced"        '*/data/containers/'
# The guard that matters most: broadening the WAL pattern to the whole engine
# directory would drop the compacted metrics a restore actually rebuilds from,
# and would look like a tidy-up in review.
grep -qF -- '--exclude "*/data/engine/"' "$PBS" \
    && { echo "  FAIL: the whole InfluxDB engine is excluded, not just the WAL"; FAIL=$((FAIL + 1)); } \
    || { echo "  PASS: InfluxDB's compacted data is still synced"; PASS=$((PASS + 1)); }

echo "=== pbs.sh: the CLI exit contract ==="
# This is what let a stale image report success. -h is a question and answers 0;
# an unknown option means the caller and this pbs disagree, and must not be 0.
pbs_rc() { bash "$PBS" "$@" >/dev/null 2>&1; echo $?; }
exp() {
    local desc=$1 want=$2 got=$3
    if [ "$got" = "$want" ]; then echo "  PASS: $desc"; PASS=$((PASS + 1))
    else echo "  FAIL: $desc (got $got, want $want)"; FAIL=$((FAIL + 1)); fi
}
exp "-h exits 0"                      0 "$(pbs_rc -h)"
exp "an unrecognised option exits 2"  2 "$(pbs_rc -Z)"
exp "ColdCopy's own flags are known"  1 "$(pbs_rc -B -m ColdCopy -d /nonexistent-not-a-mount)"

echo "=== pbs.sh: -V counts every module ==="
# ColdVerify.service trusts pbs -V's exit status. A failed early module must not
# be masked by a later one that passes.
eval "$(sed -n '/^verify() {/,/^}/p' "$PBS")"
verify_FailA() { return 1; }
verify_PassB() { return 0; }
modules="FailA PassB"
verify && { echo "  FAIL: a failed module was masked by a later pass"; FAIL=$((FAIL + 1)); } \
       || { echo "  PASS: a failed module fails -V"; PASS=$((PASS + 1)); }
modules="PassB"
verify && { echo "  PASS: all modules passing passes -V"; PASS=$((PASS + 1)); } \
       || { echo "  FAIL: a clean verify reported failure"; FAIL=$((FAIL + 1)); }

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
