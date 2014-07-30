#!/bin/sh
#
#   Copyright 2014 Sebastien Andre <swaeku@gmx.com>
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
set -e
set -u

readonly NAME="@NAME@"
readonly VERSION="@VERSION@"
readonly HOSTNAME="${HOSTNAME:-"`uname -n`"}"
LVM_SNAPSHOT_SIZE='1G'
OUTPUT_DIR="$PWD"
LVM_SNAPSHOT_DEV=
BACKUP_DIR=
RATE_LIMIT="0"
PAUSE_METHOD="shutdown"
VERBOSE=
QUIET=
HOST="$HOSTNAME"
ACTION="backup"

readonly USAGE="Backup virsh domains

Usage:
  $NAME [OPTIONS] [--] DOMAIN...

Options:
  -d, --directory DIR
                 Write backups in directory DIR (default is \".\").
  -f, --filter
                 List existing backups for the current host.
  -l, --list     List all defined domains.
  -L, --limit RATE
                 Limit the IO transfer to a maximum of RATE bytes per
                 second. A suffix of \"k\", \"m\", \"g\", or \"t\" can be
                 added to denote kilobytes (*1024), megabytes, and so on.
                 The transfer rate is not limited if the value is 0 (zero).
                 (default is $RATE_LIMIT).
  -p, --pause METHOD
                 Specifies what to do if the domain to backup is already
                 running. If METHOD is \"none\", then nothing is
                 done and backuped data may be inconsistent. Other self-
                 explanatory values for METHOD are \"suspend\" and
                 \"shutdown\". (default is $PAUSE_METHOD).
  -q, --quiet    Do not print the progress bar. This option is activated
                 automatically if standard output is not a terminal.
  -v, --verbose  Print informative messages on standard output.

  -h, --help     Print this help message and exit.
  -V, --version  Print script version and exit.
"



# Log a message
log() {
	echo "$NAME ($$): $*" >&2
}
info() {
	if [ -n "$VERBOSE" ]
	then
		log "$*"
	fi
}
warn() {
	log "WARNING: $*"
}
# Print a message on STDERR and quit
die() {
	log "ERROR: $*"
	exit 1
}


# Remove $BACKUP_DIR and $LVM_SNAPSHOT_DEV if they exist
cleanup() {
	if [ -d "$BACKUP_DIR" ]
	then
		info "remove partial backup \`$BACKUP_DIR'"
		rm -vfr -- "$BACKUP_DIR"
	fi
	if [ -b "$LVM_SNAPSHOT_DEV" ]
	then
		info "remove snapshot partition \`$LVM_SNAPSHOT_DEV'"
		lvremove -f "$LVM_SNAPSHOT_DEV"
	fi
}


# List block devices for domain $1 in format <target>:<source>
# (e.g. vda:/dev/vg1/lv1)
virsh_domblklist() {
	# virsh --quiet still prints headers
	virsh domblklist "${1?}" \
		| awk 'NR == 1 && $1 == "Target" && $2 == "Source" {
				getline
				getline
			}
			$1 && $2 {
				print $1 ":" $2
			}'
}

# Get the name of a domain
virsh_domname() {
	local id="${1?}"
	case "$id" in
		[0-9]*)
			virsh domname "$id"
			;;
		*)
			virsh --quiet list --all \
				| awk -v"name=$id" '$2 == name { print name }' \
				| fgrep "$id"
	esac
}

# Print size in bytes for logical volume $1
get_lvm_size() {
	lvs --nosuffix --units b --noheadings "${1?}" \
		| awk '{ print $4 }'
}

# Print volume group name of logical volume $1
get_lvm_group() {
	lvs --nosuffix --units b --noheadings "${1?}" \
		| awk '{ print $2 }'
}


# Save XML configuration of domain $1 to directory $2
save_domxml() {
	local dom="${1?}" dir="${2?}"
	info "save domain XML configuration"
	virsh dumpxml --security-info "$dom" > "$dir/$dom.xml"
}

# Save the content of block device $1 to GZ file $2 and SHA file $3
save_blkdev() {
	local src="${1?}" dst="${2?}" sha="${3?}"
	local file=`basename "$dst"`
	info "save data from block device \`$src'..."
	ionice -c 3 -t -- pv ${QUIET:+"--quiet"} ${RATE_LIMIT:+"--rate-limit $RATE_LIMIT"} --name "$src" -- "$src" \
		| nice gzip -c \
		| ionice tee "$dst" \
		| nice shasum > "$sha"
	info "wrote archive file \`$dst'"
	sed -i "s|-|${file}|" "$sha"
	info "wrote checksum file \`$sha'"
}

# Wait until domain $1 is in state $2
wait_until_domstate() {
	local dom="${1?}" state="${2?}" i=0
	info "wait for domain \`$dom' to be in $state state..."
	while [ "`virsh domstate "$dom"`" != "$state" ]
	do
		i=`expr $i + 1`
		sleep 1
	done
	info "domain \`$dom' is now in $state state (${i}s elapsed)"
}

# Pause domain $1 according to PAUSE_METHOD
pause_domain() {
	local dom="${1?}"
	local state=`virsh domstate "$dom"`
	if [ "$state" = "running" ]
	then
		if [ "$PAUSE_METHOD" = "shutdown" ]
		then
			virsh shutdown "$dom"
			wait_until_domstate "$dom" "shut off"
		elif [ "$PAUSE_METHOD" = "suspend" ]
		then
			virsh suspend "$dom"
			wait_until_domstate "$dom" "paused"
		fi
	fi
}

# Resume domain $1 according to PAUSE_METHOD
resume_domain() {
	local dom="${1?}"
	local state=`virsh domstate "$dom"`
	if [ "$state" != "running" ]
	then
		if [ "$PAUSE_METHOD" = "shutdown" ]
		then
			virsh start "$dom"
			wait_until_domstate "$dom" "running"
		elif [ "$PAUSE_METHOD" = "suspend" ]
		then
			virsh resume "$dom"
			wait_until_domstate "$dom" "running"
		fi
	fi
}

# Save block disks of domain $1 to directory $2
save_domdisks() {
	local dom="${1?}" dir="${2?}" s= src= dsk= out= sha= snap=
	for s in `virsh_domblklist "$dom"`
	do
		src="`echo "$s" | sed -e 's|.*:||'`"
		dsk="`echo "$s" | sed -e 's|:.*||'`"
		out="$dir/$dsk.raw.gz"
		sha="$dir/$dsk.sha"
		if [ -b "$src" ]
		then
			snap="${dom}_${dsk}"
			LVM_SNAPSHOT_DEV="`dirname "$src"`/$snap"
			pause_domain "$dom"
			info "create snapshot partition \`$snap'"
			lvcreate -L"$LVM_SNAPSHOT_SIZE" -s -n "$snap" "$src" > /dev/null
			resume_domain "$dom"
			save_blkdev "$LVM_SNAPSHOT_DEV" "$out" "$sha"
			info "remove snapshot partition \`$snap'"
			lvremove -f "$LVM_SNAPSHOT_DEV" > /dev/null
			LVM_SNAPSHOT_DEV=
		elif [ -f "$src" ]
		then
			pause_domain "$dom"
			save_blkdev "$src" "$out" "$sha"
			resume_domain "$dom"
		elif [ "$src" != "-" ]
		then	
			warn "skipped block device \`$s'"
		fi
	done
}

# Create a backup directory for domain name $1
open_backup_dir() {
	local domname="${1?}" open_dir="$OUTPUT_DIR/`date -u '+%F.%H%M%S'`.$NAME.$HOSTNAME.$domname.part"
	info "open backup directory \`$open_dir'"
	if [ -d "$BACKUP_DIR" ]
	then
		die "backup directory \`$BACKUP_DIR' already exists"
	elif [ -e "$open_dir" ]
	then
		die "target \`$open_dir' already exists"
	else
		BACKUP_DIR="$open_dir"
	fi
	if ! mkdir -- "$BACKUP_DIR"
	then
		die "can't create backup directory \`$BACKUP_DIR'"
	fi
}
close_backup_dir() {
	local close_dir="${BACKUP_DIR%.part}"
	info "close backup directory \`$BACKUP_DIR'"
	if [ ! -d "$BACKUP_DIR" ]
	then
		die "backup directory \`$BACKUP_DIR' not found"
	elif ! mv "$BACKUP_DIR" "$close_dir"
	then
		die "failed to rename \`$BACKUP_DIR' to \`$close_dir'"
	else
		BACKUP_DIR=
	fi
}



if [ $# -eq 0 ]
then
	echo "$USAGE" >&2
	exit 2
fi

while [ $# -gt 0 ]
do
	case "$1" in
	-h|--help)
		exec echo "$USAGE"
		;;
	-V|--version)
		exec echo "$NAME version $VERSION"
		;;
	-d|--directory)
		OUTPUT_DIR="${2?"output directory"}"
		shift
		;;
	-f|--filter)
		ACTION="filter"
		;;
	-l|--list)
		ACTION="list"
		;;
	-L|--limit)
		RATE_LIMIT="${2?"rate limit"}"
		shift
		;;
	-p|--pause)
		PAUSE_METHOD="${2?"pause method"}"
		shift
		;;
	-q|--quiet)
		QUIET=1
		;;
	-v|--verbose)
		VERBOSE=1
		;;
	--)
		shift
		break
		;;
	-*)
		die "unknown option \`$1'"
		;;
	*)
		break
		;;
	esac
	shift
done

if [ `id -u` -ne 0 ]
then
	die "need root permission"

elif [ ! -d "$OUTPUT_DIR" ]
then
	die "output directory \`$OUTPUT_DIR' not found"

elif echo "$RATE_LIMIT" | grep -vqE '^[0-9]+[kmgt]?$'
then
	die "invalid rate \`$RATE_LIMIT'"

elif echo "$PAUSE_METHOD" | grep -vqE '^(none|suspend|shutdown)$'
then
	die "invalid pause method \`$PAUSE_METHOD'"

elif ! which virsh >/dev/null 2>&1
then
	die "command \`virsh' not found"
fi

case "$ACTION" in
	list)
		info "list all domains defined on host \`$HOSTNAME'"
		virsh list --all
		;;
	filter)
		info "filter backups for host \`$HOSTNAME' in directory \`$OUTPUT_DIR'"
		find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -type d -regextype posix-egrep \
				-regex '.*/[0-9]{4}-[01][0-9]-[0-3][0-9]\.[0-9]{6}\.[^\.]+\.'"$HOSTNAME"'\..*' \
				-exec du -sh {} \; \
			| sort -k2
		;;
	backup)
		info "virsh version is `virsh --version`"
		info "domain pause method is \`$PAUSE_METHOD'"
		if [ "$RATE_LIMIT" = "0" ]
		then
			# normalize rate limit for option substitution
			RATE_LIMIT=
		fi
		trap 'cleanup; die "interrupted"' TERM KILL QUIT INT HUP
		while [ $# -gt 0 ]
		do
			domname=`virsh_domname "$1"`
			if [ -z "$domname" ]
			then
				die "domain \`$1' not found"	
			fi

			echo "Backup domain \`$domname'..."
			open_backup_dir "$domname"
			save_domxml "$domname" "$BACKUP_DIR"
			save_domdisks "$domname" "$BACKUP_DIR"
			dir="${BACKUP_DIR%.part}"
			close_backup_dir
			echo "Wrote backup directory \`$dir'"
			shift
		done
		;;
	*)
		die "unknown action \`$ACTION'"
esac

exit 0

