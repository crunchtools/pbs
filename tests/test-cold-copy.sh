#!/bin/bash
# Offline tests for cold-copy.sh's guards and pbs.sh's CLI exit contract.
#
# WHY THESE EXIST. Every case below is a way for a backup that copied nothing to
# report success, and one of them actually happened on ColdCopy's first real run
# (2026-11-08): a stale pbs:latest did not recognise `-d`, printed usage, exited
# 0 -- usage() did that until 2.6.1 -- and the wrapper stamped the run clean. The
# guards that now catch it are only worth having if they stay, so they are
# pinned here.
#
# podman, rclone, udisksctl, findmnt and hostname are stubbed, so this runs
# anywhere with bash and GNU date. Nothing touches pCloud, a real drive or a
# container.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../systemd/breetai/cold-copy.sh"
PBS="$HERE/../pbs.sh"
PASS=0
FAIL=0

STUBS="$(mktemp -d)"
FAKE_MOUNT="$(mktemp -d)"
trap 'rm -rf "$STUBS" "$FAKE_MOUNT"' EXIT

# --- stubs -----------------------------------------------------------------
# rclone: STUB_MARKER_MTIME (an ISO time) is what lsjson reports; empty means the
# marker does not exist. STUB_MARKER_MTIME_AFTER, if set, is reported from the
# second call onward, which is how "the run moved the marker" is simulated.
cat > "$STUBS/rclone" <<'STUB'
#!/bin/bash
n=$(( $(cat "$STUB_CALLS" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STUB_CALLS"
t="${STUB_MARKER_MTIME:-}"
if [ "$n" -ge 2 ] && [ -n "${STUB_MARKER_MTIME_AFTER:-}" ]; then
    t="$STUB_MARKER_MTIME_AFTER"
fi
[ -z "$t" ] && exit 0
printf '[{"Path":"ColdCopy.test.host","ModTime":"%s"}]\n' "$t"
STUB

# podman: pull is a no-op; run exits STUB_PBS_RC, which is the container's status.
cat > "$STUBS/podman" <<'STUB'
#!/bin/bash
[ "${1:-}" = "pull" ] && exit 0
echo "ran" > "$STUB_RAN"
exit "${STUB_PBS_RC:-0}"
STUB

cat > "$STUBS/udisksctl" <<'STUB'
#!/bin/bash
echo "udisksctl $1" >> "$STUB_RELEASE"
exit 0
STUB

# findmnt: answers with FAKE_MOUNT unless STUB_UNMOUNTED is set. With
# STUB_MOUNT_AFTER_N set, it reports nothing for that many calls and then
# answers -- which is udisks mounting a second or two after the unlock.
cat > "$STUBS/findmnt" <<'STUB'
#!/bin/bash
[ -n "${STUB_UNMOUNTED:-}" ] && exit 1
if [ -n "${STUB_MOUNT_AFTER_N:-}" ]; then
    n=$(( $(cat "$STUB_MNT_CALLS" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$STUB_MNT_CALLS"
    [ "$n" -le "$STUB_MOUNT_AFTER_N" ] && exit 1
fi
printf '%s\n' "$STUB_MOUNT"
STUB

cat > "$STUBS/hostname" <<'STUB'
#!/bin/bash
echo "test.host"
STUB

chmod +x "$STUBS"/*
export STUB_MOUNT="$FAKE_MOUNT"

# --- harness ---------------------------------------------------------------
# run <desc> <want_rc> <want_output_regex>
run() {
    local desc="$1" want_rc="$2" want_out="$3" out rc
    # Every case starts from the same state, including the claim file. A suite
    # whose result depends on the order its cases ran in is not evidence of
    # anything, and one run of this file did come back 30/1 unreproducibly
    # before this line existed.
    : > "$STUB_RELEASE"; rm -f "$STUB_RAN" "$STUB_CALLS" "$STUB_MNT_CALLS" "$CLAIM"
    # The dm node must appear to exist, so point the script at a real path.
    out=$(PATH="$STUBS:$PATH" \
          RCLONE_CONF="$STUBS/rclone" \
          bash "$SCRIPT" 2>&1); rc=$?
    if [ "$rc" = "$want_rc" ] && [[ "$out" =~ $want_out ]]; then
        echo "  PASS: $desc"; PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (rc=$rc want=$want_rc)"; echo "$out" | sed 's/^/        /'
        FAIL=$((FAIL + 1))
    fi
}
export STUB_RELEASE="$STUBS/release.log"
export STUB_RAN="$STUBS/ran"
export STUB_CALLS="$STUBS/calls"
export STUB_MNT_CALLS="$STUBS/mnt-calls"
# The claim file decides who may release the drive; keep it out of the real one.
export XDG_RUNTIME_DIR="$STUBS"
CLAIM="$STUBS/cold-copy.claimed"

# cold-copy.sh guards the dm node's existence before anything else, and the real
# UUID is baked in. Point it at a file that exists so the rest of the script runs.
DM_STUB="$STUBS/dm"
: > "$DM_STUB"
sed -e "s#^DM=.*#DM=$DM_STUB#" \
    -e "s#^BACKING=.*#BACKING=$DM_STUB#" \
    "$SCRIPT" > "$STUBS/cold-copy.sh"
SCRIPT="$STUBS/cold-copy.sh"

iso() { date -u -d "@$(( $(date +%s) + $1 ))" +%Y-%m-%dT%H:%M:%SZ; }

echo "=== cold-copy.sh: the marker guard ==="

# The failure that actually happened: container exits 0, marker never written.
STUB_PBS_RC=0 STUB_MARKER_MTIME="" \
    run "exit 0 with no marker at all is FATAL, not a success" 1 "wrote no marker"
[ -f "$FAKE_MOUNT/.cold-copy-last-success" ] \
    && { echo "  FAIL: it stamped a run with no marker"; FAIL=$((FAIL + 1)); } \
    || { echo "  PASS: no stamp written when the marker is missing"; PASS=$((PASS + 1)); }

# The Gatehouse #54 finding: a marker that exists but did not move. Under the old
# local-time comparison with 120s of slack, a marker written seconds ago by a
# PREVIOUS run passed. Comparing pCloud's own before/after closes that.
STUB_PBS_RC=0 STUB_MARKER_MTIME="$(iso -5)" \
    run "exit 0 with a marker that did not move is FATAL" 1 "marker did not move"

STUB_PBS_RC=0 STUB_MARKER_MTIME="$(iso -86400)" \
    run "a marker a day old that did not move is FATAL" 1 "marker did not move"

# The honest success: the run moved the marker forward.
STUB_PBS_RC=0 STUB_MARKER_MTIME="$(iso -86400)" STUB_MARKER_MTIME_AFTER="$(iso 0)" \
    run "a marker that moved forward is a real success" 0 "marker moved to"
[ -f "$FAKE_MOUNT/.cold-copy-last-success" ] \
    && { echo "  PASS: a verified run is stamped"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: a verified run was not stamped"; FAIL=$((FAIL + 1)); }

# First-ever run: no marker before, one after.
rm -f "$FAKE_MOUNT/.cold-copy-last-success"
STUB_PBS_RC=0 STUB_MARKER_MTIME="" STUB_MARKER_MTIME_AFTER="$(iso 0)" \
    run "a first-ever run with no prior marker succeeds" 0 "marker moved to"

# A nonzero container status is passed straight through, and never stamped.
rm -f "$FAKE_MOUNT/.cold-copy-last-success"
STUB_PBS_RC=7 STUB_MARKER_MTIME="$(iso -5)" \
    run "a nonzero container status is reported, not swallowed" 7 "ColdCopy exited 7"
[ -f "$FAKE_MOUNT/.cold-copy-last-success" ] \
    && { echo "  FAIL: it stamped a failed run"; FAIL=$((FAIL + 1)); } \
    || { echo "  PASS: a failed run is not stamped"; PASS=$((PASS + 1)); }

echo "=== cold-copy.sh: the re-fire stamp ==="

# A fresh stamp is a skip -- that is what stops a .path re-fire restarting a sync.
date +%s > "$FAKE_MOUNT/.cold-copy-last-success"
STUB_PBS_RC=0 run "a stamp from seconds ago skips the run" 0 "re-fire window"
[ -f "$STUB_RAN" ] && { echo "  FAIL: it ran pbs despite skipping"; FAIL=$((FAIL + 1)); } \
    || { echo "  PASS: a skip does not start the container"; PASS=$((PASS + 1)); }

# Just outside the window: it must run.
echo $(( $(date +%s) - 3700 )) > "$FAKE_MOUNT/.cold-copy-last-success"
STUB_PBS_RC=0 STUB_MARKER_MTIME="$(iso -86400)" STUB_MARKER_MTIME_AFTER="$(iso 0)" \
    run "a stamp older than the window runs" 0 "marker moved to"

# Boundary: inside by a second is a skip.
echo $(( $(date +%s) - 3599 )) > "$FAKE_MOUNT/.cold-copy-last-success"
STUB_PBS_RC=0 run "one second inside the window still skips" 0 "re-fire window"

# A legacy date-valued stamp (pre-2.6.1) must read as absent, not block the day.
echo "2026-11-08" > "$FAKE_MOUNT/.cold-copy-last-success"
STUB_PBS_RC=0 STUB_MARKER_MTIME="$(iso -86400)" STUB_MARKER_MTIME_AFTER="$(iso 0)" \
    run "a legacy date-valued stamp self-heals into a run" 0 "marker moved to"

# Garbage likewise.
echo "not-a-number" > "$FAKE_MOUNT/.cold-copy-last-success"
STUB_PBS_RC=0 STUB_MARKER_MTIME="$(iso -86400)" STUB_MARKER_MTIME_AFTER="$(iso 0)" \
    run "a malformed stamp reads as absent" 0 "marker moved to"

rm -f "$FAKE_MOUNT/.cold-copy-last-success"

echo "=== cold-copy.sh: the udisks race (2026-11-08, on real hardware) ==="
# ColdCopy.path fires on the LUKS device node, which appears BEFORE udisks has
# mounted the filesystem. The script used to exit 0 here and the unconditional
# ExecStopPost backstop then locked the drive out from under GNOME's in-flight
# mount, so every manual unlock undid itself about a second later and looked
# like a failing passphrase. These four cases are that bug.
rm -f "$CLAIM" "$FAKE_MOUNT/.cold-copy-last-success"
STUB_MOUNT_AFTER_N=3 MOUNT_WAIT=10 STUB_PBS_RC=0 \
    STUB_MARKER_MTIME="$(iso -86400)" STUB_MARKER_MTIME_AFTER="$(iso 0)" \
    run "it waits for udisks to mount rather than giving up" 0 "marker moved to"

# Nothing ever mounts it: leave the drive exactly as found, and above all do not
# lock it -- a human may be mid-unlock.
rm -f "$CLAIM"
STUB_UNMOUNTED=1 MOUNT_WAIT=2 \
    run "an unlocked-but-never-mounted drive is left alone" 0 "never took responsibility"
grep -q 'udisksctl' "$STUB_RELEASE" \
    && { echo "  FAIL: it locked a drive it never mounted"; FAIL=$((FAIL + 1)); } \
    || { echo "  PASS: it does not lock a drive it never mounted"; PASS=$((PASS + 1)); }
[ -f "$CLAIM" ] \
    && { echo "  FAIL: it claimed a drive it never mounted"; FAIL=$((FAIL + 1)); } \
    || { echo "  PASS: no claim taken without a mount"; PASS=$((PASS + 1)); }

# The backstop on an unclaimed drive: this is the exact call ExecStopPost makes.
rm -f "$CLAIM"; : > "$STUB_RELEASE"
PATH="$STUBS:$PATH" bash "$SCRIPT" --release-only >/dev/null 2>&1
grep -q 'udisksctl' "$STUB_RELEASE" \
    && { echo "  FAIL: --release-only locked an unclaimed drive"; FAIL=$((FAIL + 1)); } \
    || { echo "  PASS: --release-only leaves an unclaimed drive alone"; PASS=$((PASS + 1)); }

# ...but it must still release one the run DID claim, or the plaintext window
# stays open when the script is killed outright.
: > "$CLAIM"; : > "$STUB_RELEASE"
PATH="$STUBS:$PATH" bash "$SCRIPT" --release-only >/dev/null 2>&1
grep -q 'udisksctl lock' "$STUB_RELEASE" \
    && { echo "  PASS: --release-only still locks a claimed drive"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: --release-only left a claimed drive unlocked"; FAIL=$((FAIL + 1)); }

# A skip must not lock the drive either: the previous run already locked it, so
# the only way this sees it mounted is a human unlocking it on purpose.
rm -f "$CLAIM"; : > "$STUB_RELEASE"
date +%s > "$FAKE_MOUNT/.cold-copy-last-success"
STUB_PBS_RC=0 run "a re-fire skip leaves the drive mounted" 0 "leaving the drive mounted"
grep -q 'udisksctl' "$STUB_RELEASE" \
    && { echo "  FAIL: a skip locked the drive on the user"; FAIL=$((FAIL + 1)); } \
    || { echo "  PASS: a skip does not lock the drive on the user"; PASS=$((PASS + 1)); }
rm -f "$FAKE_MOUNT/.cold-copy-last-success" "$CLAIM"

echo "=== cold-copy.sh: the drive is always released ==="
STUB_PBS_RC=0 STUB_MARKER_MTIME="" run "a FATAL run still releases the drive" 1 "wrote no marker"
grep -q 'udisksctl lock' "$STUB_RELEASE" \
    && { echo "  PASS: the drive is locked even when the run fails"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: a failed run left the drive unlocked"; FAIL=$((FAIL + 1)); }

: > "$STUB_RELEASE"
KEEP_MOUNTED=1 STUB_PBS_RC=0 STUB_MARKER_MTIME="" \
    PATH="$STUBS:$PATH" RCLONE_CONF="$STUBS/rclone" bash "$SCRIPT" >/dev/null 2>&1
grep -q 'udisksctl' "$STUB_RELEASE" \
    && { echo "  FAIL: KEEP_MOUNTED=1 still released the drive"; FAIL=$((FAIL + 1)); } \
    || { echo "  PASS: KEEP_MOUNTED=1 leaves the drive mounted"; PASS=$((PASS + 1)); }

: > "$STUB_RELEASE"; rm -f "$STUB_RAN"
PATH="$STUBS:$PATH" bash "$SCRIPT" --release-only >/dev/null 2>&1
grep -q 'udisksctl lock' "$STUB_RELEASE" \
    && { echo "  PASS: --release-only locks the drive and nothing else"; PASS=$((PASS + 1)); } \
    || { echo "  FAIL: --release-only did not lock the drive"; FAIL=$((FAIL + 1)); }
[ -f "$STUB_RAN" ] && { echo "  FAIL: --release-only started a sync"; FAIL=$((FAIL + 1)); } \
    || { echo "  PASS: --release-only starts no sync"; PASS=$((PASS + 1)); }

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

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
