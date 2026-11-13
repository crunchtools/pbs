#!/usr/bin/bash
# Author: Scott McCarty
# Date: 10/13/2020
# Description: Monthly/Weekly backup script to simplify commands
# Containerized: 2026-03-23 — runs inside quay.io/crunchtools/pbs

init() {

	backups="/backups"
	downloads="/downloads"
	updraft="sven.dc3.crunchtools.com/srv/wordpress.crunchtools.com/data/wp-content/updraft"
	main_function=""
	modules="Files HomeDirectories Lastpass RequestTracker MediaWiki"
	verbose=0
	rotations="none"
	directories="Documents Downloads Autosync"
	passphrase="none"
	rclone_checkers=32
	rclone_transfers=16
	# Periodic one-line stats. --progress redraws twice a second, and under
	# systemd every redraw becomes a journal line.
	rclone_stats="--stats 1m --stats-one-line --stats-log-level NOTICE"
	markers="pcloud:/Backups/Rotations"
	# ColdCopy only. The bind-mount point of the external drive inside the
	# container, and the free-space floor below which the attic needs pruning.
	cold_dest="/data"
	cold_min_free_pct=10

        while getopts "d:m:r:BVvh" options
		do
                	case $options in
                		B) main_function=backup;;
                		V) main_function=verify;;
				d) cold_dest="$OPTARG";;
				m) modules="$OPTARG";;
				r) rotations="$OPTARG";;
				v) verbose=1;;
				h) main_function=usage;;
				# An unknown option is an error, not a help request. It
				# used to land here too and usage() exited 0, so an
				# invocation this pbs did not understand -- an older image
				# run with a newer unit's flags -- reported success and
				# anything wrapping it recorded a backup that never ran.
				# Observed 2026-11-08: a stale pbs:latest given ColdCopy's
				# -d printed usage, exited 0, and the caller stamped the run
				# clean.
                		*) main_function=usage_error;;
                	esac
		done

	# check rotation
	if [ "$rotation" = "Weekly-1" ]
        then
                debug "Determined rotation to be: Weekly-1"

	elif [ "$rotation" = "Monthly-1" ]
        then
                debug "Determined rotation to be: Monthly-1"

	elif [ "$rotation" = "Monthly-2" ]
        then
                debug "Determined rotation to be: Monthly-2"

	else
                debug "Could not determine rotation: please select from one of: Weekly-1, Monthly-1, or Monthly-2"

	fi

        # Check which modules to run
        debug "modules: $modules"

        # Finally run the main function
        debug "Main: $main_function"
        $main_function
}

usage() {
	echo    ""
	echo    "USAGE:"
	echo    "    $0 [OPTIONS]"
	echo    "or:"
	echo    "    $0 [OPTIONS] -m [MODULE]"
	echo    "or:"
	echo    "    $0 [OPTIONS] -r [ROTATION]"
	echo    "where standard options are:"
	echo    "    B    - Backup all items"
	echo    "    V    - Verify all items"
	echo    "    d    - ColdCopy destination (default /data)"
	echo    "    v    - Verbose mode: for debugging"
	echo    "    h    - Print this help/usage message"
	echo    ""

exit "${1:-0}"
}

# Same text, nonzero exit. -h asked a question and got an answer; an unknown
# option means the caller and this script disagree about what pbs can do, and
# that must never look like a successful run.
usage_error() {
	echo "Error: unrecognized option. This pbs does not understand the flags it was given."
	usage 2
}

debug() {
        if [ $verbose -eq 1 ]
        then
                echo "Debug: $1";
        fi
}

echo_bold() {
    echo ">>> $1"
}

echo_color() {
    echo "=== $1"
}

setup() {
	echo_color "Setting up"
}

get_passphrase() {
	if [ $passphrase = "none" ]
	then
		echo "Error: passphrase required but not available in container context"
		exit 1
	else
		return
	fi
}

backup() {
	local failed=0

	for i in $modules
	do
		backup_$i || failed=1
	done

	return $failed
}

backup_Files() {
	echo
	debug "Debug: backing up files"
	echo

	local failed=0 started finished status

	if [ $rotations = "Weekly-1" ] || [ $rotations = "Monthly-1" ] || [ $rotations = "Monthly-2" ]
	then
		for rotation in $rotations
		do
			for directory in $directories
			do
				echo "Synchronizing pcloud:$directory to pcloud:/Backups/$directory/$rotation"
				started=$(date +%s)
				/usr/bin/rclone sync --skip-links \
				    	--human-readable \
					--fast-list \
					--checkers $rclone_checkers \
					--transfers $rclone_transfers \
					--delete-excluded \
					$rclone_stats \
					--delete-during \
					--config /etc/rclone.conf \
					--exclude ".venv/" \
					--exclude "node_modules/" \
					--exclude "__pycache__/" \
					--exclude "*.pyc" \
					pcloud:/$directory pcloud:/Backups/$directory/$rotation
				status=$?
				finished=$(date +%s)

				if [ $status -ne 0 ]; then
					echo "Error: rclone exited $status synchronizing $directory to $rotation"
					failed=1
				fi

				# Marker read by check_personal_backup_freshness.sh in nagios-agent.
				# Written on failure too, so a failed run alerts before it goes stale.
				echo "Files|$directory|$rotation|$started|$finished|$status" | \
					/usr/bin/rclone rcat --config /etc/rclone.conf \
					"$markers/Files.$directory.$rotation" || failed=1
			done
		done
	else
		echo "Error: no rotation specied. Please select from one of: Weekly-1, Monthly-1, or Monthly-2"
		failed=1
	fi

	return $failed
}

# Items that are a copy of something else already in pCloud, or state rather
# than data. Everything NOT listed here gets copied to the cold drive.
#
# This is an EXCLUDE list on purpose. An include list drops whatever nobody
# remembered to add, silently, and the thing it drops is by definition the thing
# nobody was thinking about. Here a new pCloud folder is protected by default and
# anything skipped is skipped deliberately, with a reason on the line.
cold_skip() {
	case "$1" in
		# Rotation copies of the live tree, which is itself copied.
		Backups/Documents|Backups/Autosync|Backups/Downloads) return 0;;
		# Orphaned: pcloud:/Projects stopped existing 2026-11-04 when ~/Projects
		# moved to the one-way backup under Backups/Servers/breetai.../Projects,
		# which IS copied. These rotations can never be refreshed.
		Backups/Projects) return 0;;
		# The Nagios freshness markers, including this module's own. State.
		Backups/Rotations) return 0;;
		.Trash*) return 0;;
	esac
	return 1
}

# Known items, worst-loss-first. Tiny and irreplaceable before bulk; Documents
# last because it is the only item with any other copy at all (the pCloud
# rotations), so an interrupted run leaves the least-defended data covered.
# Names here are a priority hint, not the list of what gets copied -- anything
# discovered that is not named here is appended and still copied.
cold_priority="Backups/BitWarden
Backups/Acquacotta
Backups/LucidCharts
Downloads
Backups/Samsung SM-A376B
Backups/Servers
Backups/trove
Backups/HomeDirectories
Autosync
Backups/WordPress
Documents"

# Discover what is in the account right now: top level, plus one level into
# Backups, because Backups mixes real data (Servers, BitWarden, WordPress) with
# the rotation copies that cold_skip drops.
#
# Returns nonzero if either listing failed, and the listings are captured rather
# than piped so that status is visible. A suppressed listing error is
# indistinguishable from an empty account, and the caller would then copy
# nothing and report success -- which is the one outcome a backup must never
# produce. This is not hypothetical: the pCloud token on lotor was found revoked
# on 2026-10-05 after rclone was authorized elsewhere, and every job failed.
cold_discover() {
	local top sub d b

	top=$(/usr/bin/rclone lsf --dirs-only --config /etc/rclone.conf pcloud:) || return 1

	while IFS= read -r d
	do
		d=${d%/}
		[ -z "$d" ] && continue
		if [ "$d" = "Backups" ]
		then
			sub=$(/usr/bin/rclone lsf --dirs-only --config /etc/rclone.conf pcloud:Backups) || return 1
			while IFS= read -r b
			do
				b=${b%/}
				[ -n "$b" ] && echo "Backups/$b"
			done <<< "$sub"
		else
			echo "$d"
		fi
	done <<< "$top"
}

# Discovered items, in priority order, with anything unrecognised at the end.
#
# Two distinct failures, two exit codes, because they call for different
# actions at 2am:
#   1  the listing failed -- go look at the rclone token
#   2  the listing succeeded and the account is empty -- go find out why
# Both must stop the run. A backup source that has suddenly gone empty is never
# good news, and reading it as "no work to do" would report a clean run over a
# vanished account.
cold_items() {
	local found item

	found=$(cold_discover) || return 1
	[ -n "$found" ] || return 2

	printf '%s\n' "$cold_priority" | while IFS= read -r item
	do
		cold_skip "$item" && continue
		printf '%s\n' "$found" | grep -Fxq "$item" && echo "$item"
	done

	printf '%s\n' "$found" | while IFS= read -r item
	do
		[ -z "$item" ] && continue
		cold_skip "$item" && continue
		printf '%s\n' "$cold_priority" | grep -Fxq "$item" && continue
		echo "$item"
	done
}

backup_ColdCopy() {
	echo
	debug "Debug: copying pCloud to the cold drive at $cold_dest"
	echo

	local failed=0 item started finished status marker_body free_pct
	local attic="$cold_dest/attic/$(date +%F)"

	# COLD_HOST names this host in the marker, and must be STABLE, because the
	# marker's name is derived from it: a host that renames itself leaves an
	# orphaned marker that can never be refreshed and a CRITICAL nobody can
	# clear. check_personal_backup_freshness.sh carries the same warning about
	# its directory list.
	#
	# `hostname -f` is not trusted for it: on breetai, the cold copy's first
	# host, it was the CSB name and changed on a reinstall. Exedore's unit sets
	# COLD_HOST=exedore.dc2.crunchtools.com explicitly for the same reason.
	local hostname
	hostname=${COLD_HOST:-$(hostname -f)}

	# A bind mount that did not happen looks exactly like an empty directory, so
	# without this a locked or unplugged drive quietly writes 733 GiB into the
	# container's own filesystem and reports success. Comparing device numbers
	# with the parent needs only coreutils, unlike findmnt or mountpoint.
	if [ ! -d "$cold_dest" ] || [ "$(stat -c %d "$cold_dest" 2>/dev/null)" = "$(stat -c %d "$cold_dest/.." 2>/dev/null)" ]
	then
		echo "Error: $cold_dest is not a mount point -- the drive is locked, unplugged, or not bind-mounted"
		return 1
	fi

	if [ ! -w "$cold_dest" ]
	then
		echo "Error: $cold_dest is not writable"
		return 1
	fi

	# Via a file, not a pipe: item names contain spaces ("Samsung SM-A376B"), and
	# a `while read` on the right of a pipe runs in a subshell, which would throw
	# away $failed and the marker body it accumulates.
	local item_list="/tmp/cold-items.$$" discover_status
	cold_items > "$item_list"
	discover_status=$?
	if [ $discover_status -ne 0 ]
	then
		if [ $discover_status -eq 2 ]
		then
			echo "Error: pCloud answered, and the account has nothing to copy."
			echo "       Not treating that as a clean run -- a backup source that has gone"
			echo "       empty is never good news. Check the account itself, not the token."
		else
			echo "Error: could not list the pCloud account (rclone lsf failed)."
			echo "       Check the rclone token first: it was found revoked on 2026-10-05"
			echo "       after rclone was authorized elsewhere. See the Backups wiki page."
		fi
		rm -f "$item_list"
		return 1
	fi

	marker_body=""
	while IFS= read -r item
	do
		[ -z "$item" ] && continue

		echo "Synchronizing pcloud:$item to $cold_dest/pcloud/$item"
		started=$(date +%s)

		# --backup-dir is the difference between a backup and a mirror. Plain
		# sync propagates deletions, so a bad delete or a ransomware pass in
		# pCloud would be reproduced faithfully onto the only independent copy.
		# Changed and deleted files move to a dated attic instead.
		#
		# No --fast-list on Backups/Servers: it is ~603k files and fast-list
		# holds every entry in memory at once. backup_Servers omits it for the
		# same reason (2.5.2).
		if [ "$item" = "Backups/Servers" ]
		then
			/usr/bin/rclone sync --skip-links \
				--human-readable \
				--checkers $rclone_checkers \
				--transfers $rclone_transfers \
				$rclone_stats \
				--config /etc/rclone.conf \
				--backup-dir "$attic/$item" \
				pcloud:"$item" "$cold_dest/pcloud/$item"
		else
			/usr/bin/rclone sync --skip-links \
				--human-readable \
				--fast-list \
				--checkers $rclone_checkers \
				--transfers $rclone_transfers \
				$rclone_stats \
				--config /etc/rclone.conf \
				--backup-dir "$attic/$item" \
				pcloud:"$item" "$cold_dest/pcloud/$item"
		fi
		status=$?
		finished=$(date +%s)

		if [ $status -ne 0 ]; then
			echo "Error: rclone exited $status synchronizing $item to $cold_dest"
			failed=1
		fi

		# Rewritten after every item, not once at the end: Documents alone runs
		# for hours, and a run that is killed part way should still show what it
		# managed rather than looking like it never ran.
		marker_body="$marker_body
ColdCopy|$item|$hostname|$started|$finished|$status"
		printf '%s\n' "${marker_body#
}" | \
			/usr/bin/rclone rcat --config /etc/rclone.conf \
			"$markers/ColdCopy.$hostname" || failed=1
	done < "$item_list"
	rm -f "$item_list"

	# The attic only grows. Say so while there is still room to act, because the
	# alternative is finding out when a sync fails for want of space.
	free_pct=$(df -P "$cold_dest" | awk 'NR==2 {print 100 - $5 + 0}' | tr -d '%')
	if [ -n "$free_pct" ] && [ "$free_pct" -lt "$cold_min_free_pct" ]
	then
		echo "Warning: $cold_dest is ${free_pct}% free (floor ${cold_min_free_pct}%). Prune $cold_dest/attic."
	fi

	return $failed
}

backup_HomeDirectories() {
	echo
	debug "Debug: backing up home directories"
	echo

	if [ $rotations = "Weekly-1" ] || [ $rotations = "Monthly-1" ] || [ $rotations = "Monthly-2" ]
	then
		hostname=$(hostname -s)
		staging="/tmp/staging"

		# Discover home directories by listing /home and /var/home
		homedirs=""
		for basedir in /home /var/home; do
			if [ -d "$basedir" ]; then
				for d in "$basedir"/*/; do
					[ -d "$d" ] && homedirs="$homedirs $d"
				done
			fi
		done

		for rotation in $rotations
		do
			for homedir in $homedirs
			do
				# Strip trailing slash
				homedir="${homedir%/}"
				username=$(basename "$homedir")

				# Skip if home directory is empty
				if [ -z "$(ls -A "$homedir" 2>/dev/null)" ]; then
					debug "Skipping $username: $homedir is empty"
					continue
				fi

				dest="pcloud:/Backups/HomeDirectories/$rotation/$hostname/$username"
				echo "Backing up $homedir to $dest"

				# Stage SQLite databases for safe backup
				backup_sqlite_databases "$homedir" "$staging/$username"

				# Sync home directory, excluding large regenerable content
				/usr/bin/rclone sync --skip-links \
					--human-readable \
					--checkers $rclone_checkers \
					--transfers $rclone_transfers \
					--delete-excluded \
					$rclone_stats \
					--delete-during \
					--config /etc/rclone.conf \
					--exclude "AutoSync/" \
					--exclude "Desktop/" \
					--exclude "Documents/" \
					--exclude "Downloads/" \
					--exclude "pCloudDrive/" \
					--exclude "Projects/" \
					--exclude ".local/lib/" \
					--exclude ".local/bin/" \
					--exclude ".local/share/Trash/" \
					--exclude ".local/share/containers/" \
					--exclude ".local/share/uv/" \
					--exclude ".local/share/mcp-uploads-downloads/" \
					--exclude ".local/share/claude/" \
					--exclude ".local/share/flatpak/" \
					--exclude ".local/share/notebooklm-mcp/" \
					--exclude ".local/share/virtualenv/" \
					--exclude ".config/google-chrome*/" \
					--exclude ".config/gemini-mcp/" \
					--exclude ".config/pcloud/" \
					--exclude ".cache/" \
					--exclude ".mozilla/" \
					--exclude ".pcloud/" \
					--exclude ".opt/" \
					--exclude ".var/" \
					--exclude ".voicemode/services/" \
					--exclude ".npm/" \
					--exclude ".cargo/" \
					--exclude ".rotv/" \
					--exclude ".notebooklm-mcp-cli/" \
					--exclude ".claude/.git/" \
					--exclude ".claude/cache/" \
					--exclude ".claude/chrome/" \
					--exclude ".claude/debug/" \
					--exclude ".claude/file-history/" \
					--exclude ".claude/ide/" \
					--exclude ".claude/paste-cache/" \
					--exclude ".claude/plans/" \
					--exclude ".claude/projects/" \
					--exclude ".claude/history.jsonl" \
					--exclude ".claude/session-env/" \
					--exclude ".claude/shell-snapshots/" \
					--exclude ".claude/stats-cache.json" \
					--exclude ".claude/statsig/" \
					--exclude ".claude/tasks/" \
					--exclude ".claude/telemetry/" \
					--exclude ".claude/terminal_title/" \
					--exclude ".claude/todos/" \
					--exclude ".claude/plugins/" \
					--exclude "*.db-wal" \
					--exclude "*.db-shm" \
					--exclude "*.db-journal" \
					"$homedir" "$dest"

				# Overlay staged SQLite backups (clean copies without WAL)
				if [ -d "$staging/$username" ]; then
					echo "Copying staged SQLite databases for $username"
					/usr/bin/rclone copy --skip-links \
						--human-readable \
						--checkers $rclone_checkers \
						--transfers $rclone_transfers \
						--quiet \
						--config /etc/rclone.conf \
						"$staging/$username" "$dest"
					rm -rf "$staging/$username"
				fi
			done
		done

		# Clean up staging directory
		rm -rf "$staging"

		# Sync what we could first, then fail so the scheduler sees the gap.
		if [ "$archive_failed" -ne 0 ]; then
			echo "Error: backup is missing an archive, see warnings above"
			exit 1
		fi
	else
		echo "Error: no rotation specified. Please select from one of: Weekly-1, Monthly-1, or Monthly-2"
	fi
}

backup_sqlite_databases() {
	local source_dir="$1"
	local staging_dir="$2"

	# Find all .db files that are SQLite databases, skipping excluded directories.
	#
	# INVARIANT: this scan must skip every tree the callers' rclone sync excludes.
	# The overlay copy runs AFTER the sync, so anything staged from an excluded
	# tree is put straight back at the destination and the exclude is a lie. That
	# is what */data/containers/* is doing here: the list below was written for
	# home directories, so the Servers scan walked into the sandboxes' nested
	# podman storage and staged 337 of its 465 files (1,307 MB of 5,945) out of
	# mypy caches in crunchtools-hook-cache, which 2.5.0 had just excluded from
	# the sync and which had just been purged from Weekly-1 by hand. Add a sync
	# exclude, add it here too.
	find "$source_dir" -name "*.db" -type f \
		-not -path "*/data/containers/*" \
		-not -path "*/AutoSync/*" \
		-not -path "*/Documents/*" \
		-not -path "*/Downloads/*" \
		-not -path "*/pCloudDrive/*" \
		-not -path "*/Projects/*" \
		-not -path "*/.local/lib/*" \
		-not -path "*/.local/bin/*" \
		-not -path "*/.local/share/Trash/*" \
		-not -path "*/.local/share/containers/*" \
		-not -path "*/.local/share/uv/*" \
		-not -path "*/.local/share/mcp-uploads-downloads/*" \
		-not -path "*/.local/share/claude/*" \
		-not -path "*/.local/share/flatpak/*" \
		-not -path "*/.config/google-chrome*/*" \
		-not -path "*/.cache/*" \
		-not -path "*/.mozilla/*" \
		-not -path "*/.pcloud/*" \
		-not -path "*/.opt/*" \
		-not -path "*/.var/*" \
		-not -path "*/.voicemode/services/*" \
		-not -path "*/.npm/*" \
		-not -path "*/.cargo/*" \
		-not -path "*/.rotv/*" \
		-not -path "*/.notebooklm-mcp-cli/*" \
		-not -path "*/.config/gemini-mcp/*" \
		-not -path "*/.local/share/notebooklm-mcp/*" \
		2>/dev/null | while read dbfile
	do
		# Verify it's actually a SQLite database
		if file "$dbfile" | grep -q "SQLite"; then
			# Preserve relative path structure
			relpath="${dbfile#$source_dir/}"
			dest_path="$staging_dir/$relpath"
			dest_dir=$(dirname "$dest_path")

			mkdir -p "$dest_dir"
			debug "Staging SQLite backup: $dbfile -> $dest_path"
			sqlite3 "$dbfile" ".backup '$dest_path'" 2>/dev/null

			if [ $? -ne 0 ]; then
				echo "Warning: sqlite3 .backup failed for $dbfile, copying raw file"
				cp "$dbfile" "$dest_path"
			fi
		fi
	done
}

archive_stopped_database() {
	# A stopped container (dev sites idle out) cannot dump, but its data
	# directory is quiescent, so a raw copy is consistent. Without this the
	# rclone excludes on the data directory leave nothing restorable.
	local dbdir="$1"
	local staging_dir="$2"
	local svcname="$3"
	local archive="$staging_dir/$svcname/backups/$(basename "$dbdir")-stopped.tar.gz"

	mkdir -p "$staging_dir/$svcname/backups"
	echo "Container $svcname not running, archiving $(basename "$dbdir") instead of dumping"
	if ! tar --numeric-owner -C "$(dirname "$dbdir")" -czf "$archive" "$(basename "$dbdir")"; then
		echo "Warning: could not archive $dbdir"
		rm -f "$archive"
		return 1
	fi
}

backup_srv_metadata() {
	# pCloud keeps no owners, modes, symlinks or empty directories, and these
	# syncs exclude some directories outright. Restoring /srv without this
	# leaves services unable to start. scripts/restore_metadata.py applies it.
	# The SELinux column is a record only: the restore relabels from the
	# rules in selinux-local/config/local.semanage instead.
	local staging_dir="$1"

	mkdir -p "$staging_dir/_host"
	echo "Recording /srv metadata"
	find /srv/ -mindepth 1 -printf '%y\t%m\t%U\t%G\t%Z\t%P\t%l\0' \
		| gzip > "$staging_dir/_host/srv-metadata.gz"
	local status=("${PIPESTATUS[@]}")
	if [ "${status[0]}" -ne 0 ] || [ "${status[1]}" -ne 0 ]; then
		echo "Warning: could not record /srv metadata"
		rm -f "$staging_dir/_host/srv-metadata.gz"
		return 1
	fi
}

backup_host_config() {
	# Host state /srv does not hold, mounted under /host by the gloval units.
	# A tarball because rclone would drop owners, modes and the symlinks that
	# record which units are enabled. Password hashes and private keys stay
	# out: a restored host generates new ones.
	local staging_dir="$1"

	[ -d /host ] || return 0

	mkdir -p "$staging_dir/_host"
	echo "Archiving host configuration"
	if ! tar --numeric-owner -C /host -czf "$staging_dir/_host/host-config.tar.gz" \
		--exclude="etc/rclone.conf" \
		--exclude="etc/shadow*" \
		--exclude="etc/gshadow*" \
		--exclude="etc/ssh/ssh_host_*_key" \
		--exclude="etc/cockpit/ws-certs.d/*.key" \
		--exclude="etc/pki/tls/private" \
		--exclude="var/home/*/.ssh/id_*" \
		--exclude="var/home/*/.local" \
		--exclude="var/home/*/.cache" \
		--exclude="var/home/*/work" \
		.; then
		echo "Warning: could not archive host configuration"
		rm -f "$staging_dir/_host/host-config.tar.gz"
		return 1
	fi
}

dump_mariadb_databases() {
	local staging_dir="$1"

	for dbdir in /srv/*/data/mariadb; do
		[ -d "$dbdir" ] || continue
		svcdir=$(dirname "$(dirname "$dbdir")")
		svcname=$(basename "$svcdir")

		if podman-remote --url unix:///run/podman/podman.sock ps --format '{{.Names}}' 2>/dev/null | grep -q "^${svcname}$"; then
			mkdir -p "$staging_dir/$svcname/backups"
			echo "Dumping MariaDB for $svcname"
			podman-remote --url unix:///run/podman/podman.sock exec "$svcname" mysqldump --all-databases \
				> "$staging_dir/$svcname/backups/all-databases.sql" 2>/dev/null
			if [ $? -ne 0 ]; then
				echo "Warning: MariaDB dump failed for $svcname"
				rm -f "$staging_dir/$svcname/backups/all-databases.sql"
			fi
		else
			archive_stopped_database "$dbdir" "$staging_dir" "$svcname" || archive_failed=1
		fi
	done
}

dump_postgresql_databases() {
	local staging_dir="$1"

	for dbdir in /srv/*/data/pgdata /srv/*/data/postgres; do
		[ -d "$dbdir" ] || continue
		svcdir=$(dirname "$(dirname "$dbdir")")
		svcname=$(basename "$svcdir")

		if podman-remote --url unix:///run/podman/podman.sock ps --format '{{.Names}}' 2>/dev/null | grep -q "^${svcname}$"; then
			mkdir -p "$staging_dir/$svcname/backups"
			echo "Dumping PostgreSQL for $svcname"
			podman-remote --url unix:///run/podman/podman.sock exec "$svcname" pg_dumpall -U postgres \
				> "$staging_dir/$svcname/backups/all-databases.sql" 2>/dev/null
			if [ $? -ne 0 ]; then
				echo "Warning: PostgreSQL dump failed for $svcname, trying without -U postgres"
				podman-remote --url unix:///run/podman/podman.sock exec "$svcname" pg_dumpall \
					> "$staging_dir/$svcname/backups/all-databases.sql" 2>/dev/null
				if [ $? -ne 0 ]; then
					echo "Warning: PostgreSQL dump failed for $svcname"
					rm -f "$staging_dir/$svcname/backups/all-databases.sql"
				fi
			fi
		else
			archive_stopped_database "$dbdir" "$staging_dir" "$svcname" || archive_failed=1
		fi
	done
}

backup_Servers() {
	echo
	debug "Debug: backing up servers"
	echo

	if [ $rotations = "Weekly-1" ] || [ $rotations = "Monthly-1" ] || [ $rotations = "Monthly-2" ]
	then
		hostname=$(hostname -f)
		# Two staging directories, split by whether the artifact also exists
		# under /srv, because that decides which side of the sync it goes on.
		#
		#   staging_dest    nothing under /srv corresponds to it: the .sql
		#                   dumps, the stopped-container archives, _host/*.
		#                   Copied BEFORE the sync and excluded from it.
		#   staging_overlay shares its paths with real /srv files: the clean
		#                   SQLite copies. Copied AFTER the sync, so the clean
		#                   copy is the one that survives.
		#
		# The dumps used to go up only after the sync, and the sync deleted the
		# previous run's copies on its way through (--delete-excluded, and they
		# have no source counterpart). So for the ten hours a Servers run takes,
		# Weekly-1 held no database dumps at all, and a run that died in between
		# left none until the next successful run. On 2026-11-08 a bootc update
		# rebooted gloval through the run, which is exactly that, and Backup
		# Freshness went CRITICAL on five missing dumps with nothing wrong at
		# either end. Uploading them first costs a minute and takes the one
		# thing this backup exists for off the critical path.
		staging_dest="/tmp/staging-srv-dest"
		staging_overlay="/tmp/staging-srv"
		mkdir -p "$staging_dest" "$staging_overlay"
		archive_failed=0

		# Dump relational databases before sync
		dump_mariadb_databases "$staging_dest"
		dump_postgresql_databases "$staging_dest"

		# Stage SQLite databases for safe backup
		backup_sqlite_databases "/srv" "$staging_overlay"

		backup_host_config "$staging_dest" || archive_failed=1
		backup_srv_metadata "$staging_dest" || archive_failed=1

		for rotation in $rotations
		do
			dest="pcloud:/Backups/Servers/$hostname/$rotation"

			# First, and on its own: everything a restore cannot rebuild.
			echo "Copying database dumps and host archives to $dest"
			/usr/bin/rclone copy --skip-links \
				--human-readable \
				--checkers $rclone_checkers \
				--transfers $rclone_transfers \
				$rclone_stats \
				--config /etc/rclone.conf \
				"$staging_dest" "$dest"

			echo "Backing up /srv to $dest"

			# .git directories are kept: /srv is itself a repo, and checkouts
			# under it hold history and remotes a restore cannot rebuild
			# (they had to be copied from lotor by hand, RT #1546).
			#
			# The three staging_dest excludes keep the sync away from what the
			# copy above just uploaded; without them plain sync deletes them as
			# destination files with no source. --delete-excluded is gone for
			# the same reason: it deletes precisely what is excluded, which is
			# now the dumps. A NEW exclude from here on needs a deliberate
			# one-off prune; the sync will not do it.
			#
			# OWED PRUNE, as of 2.7.3: data/engine/wal/ under
			# influxdb.crunchtools.com in Weekly-1 holds three WAL directories
			# last written 2026-11-03, and the two new excludes below will never
			# refresh or remove them. This one is not merely untidy: a restore
			# would hand InfluxDB a stale WAL beside newer compacted data, which
			# is worse than handing it none. Prune it by hand, once. Left in
			# place rather than deleted here because removing data from the
			# backup destination is not something a release should do quietly.
			#
			# */data/containers/ is podman's blob cache and local image store for
			# the CI runner and the dev sandboxes: 1,190,137 files and 49.5 GiB on
			# gloval, across developer1-3 and gha-runner-cached, which are the only
			# services that have one. It is the bulk of the run. The 2026-11-08 run
			# was still going after ten hours and was killed twice before it
			# finished; excluding this cut the work by about six times.
			#
			# Do NOT read a falling percentage as the source outrunning the copy.
			# This sync has no --fast-list, so rclone enumerates as it walks and the
			# "total" in its stats line rises for as long as discovery continues:
			# the run after this change went from 506 MiB to 1.7 GiB of total, and
			# 2,358 to 20,831 files, in 24 minutes while /srv itself grew about
			# 1 MB/min. 18,473 files in 24 minutes at that rate would average 160
			# bytes each. It is discovery, not churn, and an earlier version of this
			# comment had it wrong.
			#
			# The live-write races ARE real, just smaller: the same run logged
			# "error reading source directory" on a uv build tempdir that vanished
			# mid-walk, and "source file is being updated" on files that grew during
			# their upload. Nothing in here survives a restore anyway: overlay layers
			# plus one named volume, crunchtools-hook-cache, and both come back by
			# pulling the images again. The real state of those sandboxes is
			# data/state, which stays.
			#
			# matrix-sync is a five-byte Matrix sync cursor rewritten constantly; it
			# was the only source of "corrupted on transfer: md5 hashes differ",
			# because it changes between rclone's read and its verify. A restored
			# client just re-syncs.
			#
			# data/engine/wal/ is InfluxDB's write-ahead log, and it is the same
			# problem one step worse. It is appended to continuously, so rclone
			# reports "source file is being updated (size changed from X to Y)",
			# and ONE such file fails the whole attempt: rclone then re-walks the
			# entire tree for attempt 2. Measured on the 2026-11-09 03:45 run --
			# attempt 1 failed with 4 errors at 01:57 UTC, attempt 2 succeeded at
			# 02:08, so half of a 24-minute run was a re-count that moved no
			# bytes. A failed attempt also suppresses directory deletion ("not
			# deleting directories as there were IO errors"), so the destination
			# keeps what the source dropped and next week's walk is longer.
			# Excluding it is also the more correct answer, not just the cheaper
			# one: a raw copy of a live WAL is torn, and InfluxDB replaying a torn
			# WAL on restore is worse than restoring without one. The compacted
			# data beside it (data/engine/data/) is kept, which is the part a
			# restore actually rebuilds from; the cost is the last unflushed
			# window of metrics.
			#
			# .mypy_cache/ is a type-checker cache under the dev sandboxes' work
			# trees: a build artifact, like __pycache__ next to it. It needed its
			# own line because its contents are .db files, so the *.pyc exclude
			# never covered them, and being .db they were also picked up by the
			# SQLite staging pass, which logged "sqlite3 .backup failed, copying
			# raw file" for every one of them. Nothing in a mypy cache survives a
			# restore in any useful sense; mypy rebuilds it.
			#
			# NOT excluded, on purpose: data/audit/bridge-transcript-*.jsonl. Those
			# are audit records. They are append-only, so rclone reports "source
			# file is being updated" for a session that is live while the backup
			# runs, and copies them cleanly once it ends. That error is expected and
			# self-clearing; it is not a reason to stop backing them up.
			/usr/bin/rclone sync --skip-links \
				--human-readable \
				--create-empty-src-dirs \
				--checkers $rclone_checkers \
				--transfers $rclone_transfers \
				$rclone_stats \
				--delete-during \
				--config /etc/rclone.conf \
				--exclude "/*/backups/all-databases.sql" \
				--exclude "/*/backups/*-stopped.tar.gz" \
				--exclude "/_host/**" \
				--exclude "*/data/containers/" \
				--exclude "*/data/state/.config/josui/matrix-sync" \
				--exclude "*/data/engine/wal/" \
				--exclude "*/.mypy_cache/" \
				--exclude "*/data/mariadb/" \
				--exclude "*/data/pgdata/" \
				--exclude "*/data/postgres/" \
				--exclude "*/data/logs/" \
				--exclude "*/code/cpan/" \
				--exclude "*/slots/" \
				--exclude "*/flask_session/" \
				--exclude "*/__pycache__/" \
				--exclude "*/node_modules/" \
				--exclude "*.pyc" \
				--exclude "*.db-wal" \
				--exclude "*.db-shm" \
				--exclude "*.db-journal" \
				/srv "$dest"
			sync_status=$?

			# Said, not raised: a live session's append-only transcript makes
			# rclone exit nonzero on a run where nothing is wrong, so failing here
			# would cry wolf every week. Discarding it silently was worse -- a
			# wholesale sync failure left no trace at all.
			if [ "$sync_status" -ne 0 ]; then
				echo "Warning: rclone sync exited $sync_status syncing /srv to $dest, see errors above"
			fi

			# Overlay the staged SQLite copies: same paths as the raw files the
			# sync just uploaded, so this has to be the last word.
			if [ -n "$(ls -A "$staging_overlay" 2>/dev/null)" ]; then
				echo "Copying staged SQLite databases to $dest"
				/usr/bin/rclone copy --skip-links \
					--human-readable \
					--checkers $rclone_checkers \
					--transfers $rclone_transfers \
					--quiet \
					--config /etc/rclone.conf \
					"$staging_overlay" "$dest"
			fi
		done

		rm -rf "$staging_dest" "$staging_overlay"
	else
		echo "Error: no rotation specified. Please select from one of: Weekly-1, Monthly-1, or Monthly-2"
	fi
}

backup_Lastpass() {
	echo "Error: Lastpass backup requires interactive mode, not supported in container context"
	exit 1
}

verify() {
	for i in $modules
	do
		verify_$i
	done
}

verify_Files() {
	for rotation in $rotation
	do
		for server in $servers
		do
			echo
			echo_color "Verifying rotation: $rotation on server: $server"
			echo
			echo_bold "ls -lrt $backups/$server/$rotation"
			ls -lrt $backups/$server/$rotation
		done
	done
}

verify_ColdCopy() {
	local item

	if [ ! -d "$cold_dest" ] || [ "$(stat -c %d "$cold_dest" 2>/dev/null)" = "$(stat -c %d "$cold_dest/.." 2>/dev/null)" ]
	then
		echo "Error: $cold_dest is not a mount point -- nothing to verify"
		return 1
	fi

	local item_list="/tmp/cold-verify.$$" failed=0 status

	if ! cold_items > "$item_list"
	then
		echo "Error: could not list the pCloud account -- nothing to verify against"
		rm -f "$item_list"
		return 1
	fi

	# --checksum, not size-and-modtime. pCloud serves sha1, so this compares
	# hashes on both sides without downloading anything, which is the only
	# check that would have caught a drive quietly going bad -- the failure the
	# retired micro-SD had for months.
	#
	# Every exit status is accumulated. A verify that always returns success is
	# worse than no verify at all: it is the micro-SD's green light.
	while IFS= read -r item
	do
		[ -z "$item" ] && continue
		echo
		echo_color "Verifying $item"
		echo
		echo_bold "rclone check --checksum pcloud:$item $cold_dest/pcloud/$item"
		/usr/bin/rclone check --checksum \
			--config /etc/rclone.conf \
			--checkers $rclone_checkers \
			pcloud:"$item" "$cold_dest/pcloud/$item"
		status=$?
		if [ $status -ne 0 ]
		then
			echo "Error: rclone check exited $status for $item -- the cold copy does not match pCloud"
			failed=1
		fi
	done < "$item_list"
	rm -f "$item_list"

	return $failed
}

verify_HomeDirectories() {
	hostname=$(hostname -s)

	homedirs=""
	for basedir in /home /var/home; do
		if [ -d "$basedir" ]; then
			for d in "$basedir"/*/; do
				[ -d "$d" ] && homedirs="$homedirs $d"
			done
		fi
	done

	for homedir in $homedirs
	do
		homedir="${homedir%/}"
		username=$(basename "$homedir")

		echo
		echo_color "Verifying home directory backups for $username ($homedir)"

		for rotation in Weekly-1 Monthly-1 Monthly-2
		do
			echo
			echo_bold "pcloud:/Backups/HomeDirectories/$rotation/$hostname/$username"
			/usr/bin/rclone ls --config /etc/rclone.conf \
				--max-depth 2 \
				"pcloud:/Backups/HomeDirectories/$rotation/$hostname/$username" 2>/dev/null | head -20
			if [ $? -ne 0 ]; then
				echo "  (no backup found)"
			fi
		done
	done
}

verify_Servers() {
	hostname=$(hostname -f)

	for rotation in Weekly-1 Monthly-1 Monthly-2
	do
		echo
		echo_color "Verifying server backups: $rotation"
		echo
		echo_bold "pcloud:/Backups/Servers/$hostname/$rotation"
		/usr/bin/rclone ls --config /etc/rclone.conf \
			--max-depth 2 \
			"pcloud:/Backups/Servers/$hostname/$rotation" 2>/dev/null | head -30
		if [ $? -ne 0 ]; then
			echo "  (no backup found)"
		fi
	done
}

verify_Lastpass() {
	echo
	echo_color "Verify the latest backup"
	echo
	echo_bold "ls -rt $backups/LastPass | tail -n 1"
	ls -rt $backups/LastPass | tail -n 1
	echo

	get_passphrase

	echo
	echo_color "Decrypt the latest backup and verify"
	echo
	echo_bold "gpg --batch --yes --passphrase <passphrase> -d $backups/LastPass/$(ls -rt $backups/LastPass | tail -n 1)"
	gpg --batch --yes --passphrase "$passphrase" -d "$backups/LastPass/$(ls -rt $backups/LastPass | tail -n 1)" | tail
}

verify_RequestTracker() {
	echo
	echo_color "Check Request Tracker backups"
	echo
	echo_bold "ls -alh $backups/sven.dc3.crunchtools.com/srv/rt.fatherlinux.com/data/backups"
	ls -alh $backups/sven.dc3.crunchtools.com/srv/rt.fatherlinux.com/data/backups
}

verify_MediaWiki() {
	echo
	echo_color "Check Media Wiki backups"
	echo
	echo_bold "ls -alh $backups/sven.dc3.crunchtools.com/srv/learn.fatherlinux.com/data/backups"
	ls -alh $backups/sven.dc3.crunchtools.com/srv/learn.fatherlinux.com/data/backups
}

verify_Wordpress() {
	echo
	echo_color "Check Wordpress backups"
	echo
	echo_bold "ls -ltrh $backups/$updraft | grep uploads.zip"
	ls -ltrh $backups/$updraft | grep uploads.zip
}

init "$@"
