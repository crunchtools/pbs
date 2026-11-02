#!/bin/bash
# Apply _host/srv-metadata.gz from a Servers backup to a restored tree.
# Creates missing directories and symlinks, then sets owners and modes.
# Usage: restore-metadata.sh <srv-metadata.gz> <restored-srv-dir>
set -u

manifest="$1"
root="$2"
missing=0

while IFS=$'\t' read -r -d '' type mode uid gid _context path target; do
	dest="$root/$path"
	case "$type" in
		d) mkdir -p "$dest" ;;
		l) ln -sfn "$target" "$dest" ;;
		f) if [ ! -e "$dest" ]; then missing=$((missing + 1)); continue; fi ;;
		*) continue ;;
	esac
	chown -h "$uid:$gid" "$dest"
	[ "$type" = "l" ] || chmod "$mode" "$dest"
done < <(gzip -dc "$manifest")

echo "Files in the manifest but not restored: $missing"
