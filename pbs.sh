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
	for i in $modules
	do
		backup_$i
	done
}

backup_Files() {
	echo
	debug "Debug: backing up files"
	echo

	if [ $rotations = "Weekly-1" ] || [ $rotations = "Monthly-1" ] || [ $rotations = "Monthly-2" ]
	then
		for rotation in $rotations
		do
			for directory in $directories
			do
				echo "Synchronizing pcloud:$directory to pcloud:/Backups/$directory/$rotation"
				/usr/bin/rclone sync --skip-links \
				    	--human-readable \
					--size-only \
					--checkers 8 \
					--transfers 4 \
					--progress \
					--progress-terminal-title \
					--delete-during \
					--quiet \
					--config /etc/rclone.conf \
					pcloud:/$directory pcloud:/Backups/$directory/$rotation
			done
		done
	else
		echo "Error: no rotation specied. Please select from one of: Weekly-1, Monthly-1, or Monthly-2"
	fi
}

backup_HomeDirectories() {
	echo
	debug "Debug: backing up home directories"
	echo

	if [ $rotations = "Weekly-1" ] || [ $rotations = "Monthly-1" ] || [ $rotations = "Monthly-2" ]
	then
		hostname=$(hostname -s)
		staging="/tmp/staging"

		# Discover users: root + UID >= 1000 with real login shells
		users=$(awk -F: '($3 == 0 || $3 >= 1000) && $7 !~ /(nologin|false)/ {print $1 ":" $6}' /host-etc/passwd)

		for rotation in $rotations
		do
			for user_entry in $users
			do
				username=$(echo "$user_entry" | cut -d: -f1)
				homedir=$(echo "$user_entry" | cut -d: -f2)

				# Skip if home directory doesn't exist
				if [ ! -d "$homedir" ]; then
					debug "Skipping $username: $homedir does not exist"
					continue
				fi

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
					--size-only \
					--checkers 8 \
					--transfers 4 \
					--progress \
					--progress-terminal-title \
					--delete-during \
					--quiet \
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
						--checkers 4 \
						--transfers 2 \
						--quiet \
						--config /etc/rclone.conf \
						"$staging/$username" "$dest"
					rm -rf "$staging/$username"
				fi
			done
		done

		# Clean up staging directory
		rm -rf "$staging"
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
				debug "Warning: sqlite3 .backup failed for $dbfile, copying raw file"
				cp "$dbfile" "$dest_path"
			fi
		fi
	done
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
	users=$(awk -F: '($3 == 0 || $3 >= 1000) && $7 !~ /(nologin|false)/ {print $1 ":" $6}' /host-etc/passwd)

	for user_entry in $users
	do
		username=$(echo "$user_entry" | cut -d: -f1)
		homedir=$(echo "$user_entry" | cut -d: -f2)

		if [ ! -d "$homedir" ]; then
			continue
		fi

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

init $*
