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

        while getopts "m:r:BVvh" options
		do
                	case $options in
                		B) main_function=backup;;
                		V) main_function=verify;;
				m) modules="$OPTARG";;
				r) rotations="$OPTARG";;
				v) verbose=1;;
                		h|*) main_function=usage;;
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
	echo    "    v    - Verbose mode: for debugging"
	echo    "    h    - Print this help/usage message"
	echo    ""

exit 0
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

	# Find all .db files that are SQLite databases, skipping excluded directories
	find "$source_dir" -name "*.db" -type f \
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
	# Host state /srv does not hold, mounted under /host by the lotor units.
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
			# now the dumps. Nothing else at the destination matches the
			# excludes below (checked 2026-11-08), but a NEW exclude from here
			# on needs a deliberate one-off prune; the sync will not do it.
			#
			# */data/containers/ is podman's blob cache and local image store for
			# the CI runner and the dev sandboxes: 1,190,137 files and 49.5 GiB on
			# gloval, across developer1-3 and gha-runner-cached, which are the only
			# services that have one. It is why this run did not converge -- it went
			# BACKWARDS, 93% to 92% over five hours, moving 0.61 GiB while the
			# target grew 0.79 GiB, because the runner builds while rclone walks it.
			# The same run logged "error reading source directory" on a uv build
			# tempdir that vanished mid-walk. Nothing in there survives a restore
			# anyway: it is overlay layers plus one named volume,
			# crunchtools-hook-cache, and both come back by pulling the images
			# again. The real state of those sandboxes is data/state, which stays.
			#
			# matrix-sync is a five-byte Matrix sync cursor rewritten constantly; it
			# was the only source of "corrupted on transfer: md5 hashes differ",
			# because it changes between rclone's read and its verify. A restored
			# client just re-syncs.
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
