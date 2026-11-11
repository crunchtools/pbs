#!/bin/bash
# Boot gate for the pbs image: IMAGE=<ref> bash tests/image/boot-gate.sh
#
# pbs is a run-to-completion CLI, so "boots" means: the entrypoint runs, every
# tool the units call is present, and the exit contract holds. The last check
# is the one that bit production (2026-11-08): an image that did not know `-d`
# printed usage and exited 0, and ColdCopy stamped the run clean.
set -euo pipefail
: "${IMAGE:?set IMAGE to the image reference}"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Entrypoint loads and answers -h with exit 0, listing every flag the units use.
usage="$(podman run --rm "$IMAGE" -h)" || fail "-h did not exit 0"
for flag in B V d v h; do
    grep -Eq "^ *$flag +- " <<<"$usage" || fail "usage does not list -$flag"
done

# 2. An unknown option is an error, never success.
rc=0
podman run --rm "$IMAGE" -Z >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || fail "unknown option exited $rc, want 2"

# 3. Every tool pbs.sh shells out to is in the image.
podman run --rm --entrypoint sh "$IMAGE" -c '
    for b in rclone sqlite3 file find hostname ssh gpg podman-remote tar gzip; do
        command -v "$b" >/dev/null || { echo "missing: $b" >&2; exit 1; }
    done' || fail "a required tool is missing"

echo "pbs boot gate: PASS"
