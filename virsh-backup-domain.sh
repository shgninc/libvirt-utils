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

readonly NAME="`basename "$0"`"
readonly VERSION="@VERSION@"
readonly HOSTNAME="${HOSTNAME:-"`uname -n`"}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LVM_SNAPSHOT_SIZE='1G'
OUTPUT_DIR="$PWD"
LVM_SNAPSHOT_DEV=
BACKUP_DIR=
RATE_LIMIT="10m"
PAUSE_METHOD="suspend"

readonly USAGE="Backup virsh guest domains

Usage:
  $NAME [OPTIONS] [--] DOMAIN...

Options:
  -d, --directory DIR
                 Write backups in directory DIR (default is \".\")
  -l, --list     List all defined domains
  -L, --limit RATE
                 Limit the IO transfer to a maximum of RATE bytes per
                 second. A suffix of \"k\", \"m\", \"g\", or \"t\" can be
                 added to denote kilobytes (*1024), megabytes, and so on.
                 (default is $RATE_LIMIT)
  -p, --pause METHOD
                 Specifies what to do if the guest domain to backup is
                 already running. If METHOD is \"none\", then nothing is
                 done and backuped data may be inconsistent. Other self-
                 explanatory values for METHOD are \"suspend\" and
                 \"shutdown\". (default is $PAUSE_METHOD)

  -h, --help     Print this help message and exit
  -V, --version  Print script version and exit
"



# Log a message on STDOUT
log() {
	echo "$NAME: $*"
}
info() {
	log "INFO: $*"
}
warn() {
	log "WARNING: $*" >&2
}
# Print a message on STDERR and quit
die() {
	log "ERROR: $*" >&2
	exit 1
}


# Command wrappers
virsh() {
	command virsh --quiet "$@"
}
nice() {
	command nice -19 "$@"
}
ionice() {
	command ionice -c 3 -t "$@"
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
			virsh list --all \
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
	info "saving block device \`$src'..."
	ionice pv --rate-limit "$RATE_LIMIT" -- "$src" \
		| nice gzip -c \
		| ionice tee "$dst" \
		| nice shasum > "$sha"
	info "wrote compressed file \`$dst'"
	sed -i "s|-|${file}|" "$sha"
	info "wrote checksum file \`$sha'"
}

# Wait until domain $1 is in state $2
wait_until_domstate() {
	local dom="${1?}" state="${2?}" i=0
	info "waiting for domain \`$dom' to be in $state state..."
	while [ "`virsh domstate "$dom"`" != "$state" ]
	do
		i=`expr $i + 1`
		sleep 1
	done
	info "domain \`$dom' is in $state state (${i}s elapsed)"
}

# Ensures domain $1 is paused (according to PAUSE_METHOD) when running $@
run_dompaused() {
	local dom="${1?}"
	local state=`virsh domstate "$dom"`
	shift
	if [ $# -gt 0 ]
	then
		if [ "$state" = "running" ]
		then
			case "$PAUSE_METHOD" in
				shutdown)
					virsh shutdown "$dom"
					wait_until_domstate "$dom" "shut off"
					"$@"
					virsh start "$dom"
					wait_until_domstate "$dom" "running"
					;;
				suspend)
					virsh suspend "$dom"
					wait_until_domstate "$dom" "paused"
					"$@"
					virsh resume "$dom"
					wait_until_domstate "$dom" "running"
					;;
				none)
					warn "domain \`$dom' is still running during the backup"
					"$@"
					;;
				*)
					die "invalid pause method \`$PAUSE_METHOD'"
			esac
		else
			"$@"
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
			run_dompaused "$dom" \
				lvcreate -L"$LVM_SNAPSHOT_SIZE" -s -n "$snap" "$src"
			save_blkdev "$LVM_SNAPSHOT_DEV" "$out" "$sha"
			lvremove -f "$LVM_SNAPSHOT_DEV"
			LVM_SNAPSHOT_DEV=
		elif [ -f "$src" ]
		then
			run_dompaused "$dom" \
				save_blkdev "$src" "$out" "$sha"
		else
			warn "skipped block device \`$s'"
		fi
	done
}

# TODO: restore multiple disks
gen_restore_script() {
	local script="$OUTDIR/restore_$DOMAIN.sh"

	log "generate shell script \`${script##*/}"
	{
		echo "#!/bin/sh
#
#                Restore domain $DOMAIN 
#
# Author: $USER
# Origin: `hostname`
# Date  : $(date -R)
#
set -e

if [ \`id -u\` -ne 0 ]
then
	echo 'error: need root permissions' >&2
	exit 2
fi

pvscan
echo -n 'Target Volume Group? '
read VG

lvs
echo -n 'Target Logical Volume? '
read LV

echo -n 'Size? '
read SZ

echo -n 'Restore domain $DOMAIN to \$VG/\$LV with size \$SZ? [y/N] '
read ANS
if [ \"\$ANS\" != y ]
then
	echo 'Canceled by user.'
	exit 3
fi

cd \"\`dirname \"\$0\"\`\"
echo 'Verifying SHA checksums...'
ionice -c 3 sha1sum -c *.sha

for f in *.raw.gz
do
	echo \"Creating volume \$VG/\$LV with size \$SZ...\"
	lvcreate -L\$SZ -n \$LV \$VG
	nice -19 gzip -dc \"\$f\" | ionice -c 3 dd of=\"/dev/\$VG/\$LV\"
	break
done

echo 'Defining domain $DOMAIN'
virsh define $DOMAIN.xml
virsh dominfo $DOMAIN
exit 0
"
	} > "$script"
	chmod 0755 "$script"
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
		OUTPUT_DIR="$2"
		shift
		;;
	-l|--list)
		exec virsh list --all
		;;
	-L|--limit)
		RATE_LIMIT="$2"
		shift
		;;
	-p|--pause)
		PAUSE_METHOD="$2"
		shift
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
else
	info "virsh version `virsh --version`"
fi

trap '
	cleanup
	die "interrupted"
' TERM KILL QUIT INT HUP

info "start: `date`"
trap '
	info "terminate: `date`"
' EXIT

while [ $# -gt 0 ]
do
	domname=`virsh_domname "$1"` \
		|| die "domain \`$1' not found"	

	info "backup domain \`$domname'"
	virsh dominfo "$domname"

	BACKUP_DIR="$OUTPUT_DIR/`date -u '+%F.%H%M%S'`.$NAME.$HOSTNAME.$domname"
	mkdir -v "$BACKUP_DIR" \
		|| die "can't create backup directory \`$BACKUP_DIR'"

	save_domxml "$domname" "$BACKUP_DIR"
	save_domdisks "$domname" "$BACKUP_DIR"
	#gen_restore_script "$domname" "$BACKUP_DIR"

	info "wrote backup \`$BACKUP_DIR' (`du -sh "$BACKUP_DIR" | cut -f 1`)"
	BACKUP_DIR=

	shift
done

exit 0

