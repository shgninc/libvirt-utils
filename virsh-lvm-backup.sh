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

readonly NAME="${0##*/}"
readonly VERSION="@VERSION@"
readonly USAGE="Backup QEMU/KVM domains

Usage:
  $NAME [OPTIONS] [--] DOMAIN...

Options:
  -l, --list     List all defined domains
  -u, --update   Auto-update the script to the latest version

  -h, --help     Print this help message and exit
  -V, --version  Print script version and exit

"
readonly HOSTNAME="${HOSTNAME:-"`uname -n`"}"

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LVM_SNAPSHOT_SIZE='1G'
OUTPUT_DIR="$PWD"
LVM_SNAPSHOT_DEV=
BACKUP_DIR=



# Log a message on STDOUT
log() {
	echo "`date '+[%F %T]'` $NAME: $*"
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

# List block devices for domain $1
virsh_domblklist() {
	# virsh --quiet still prints headers
	virsh domblklist "${1?}" \
		| awk 'NR == 1 && $1 == "Target" && $2 == "Source" { getline; getline; } { print }'
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
	log "save domain XML configuration"
	virsh dumpxml --security-info "$dom" > "$dir/$dom.xml"
}

save_blkdev() {
	local src="${1?}" dst="${2?}" sha="${3?}"
	log "save \`$src' -> \`${dst##*/}' + \`${sha##*/}'"
	ionice pv "$src" \
		| nice gzip -c \
		| ionice tee "$dst" \
		| nice shasum > "$sha"
	sed -i "s|-|${dst##*/}|" "$sha"
}

# Save block disks of domain $1 to directory $2
save_domdisks() {
	local dom="${1?}" dir="${2?}"
	local sha_file= out_file= snap_name= snap_dev= target= source=
	virsh_domblklist "$dom" \
		| while read target source
			do
				out_file="$dir/$target.raw.gz"
				sha_file="$dir/$target.sha"
				if [ -b "$source" ]
				then
					snap_name="${dom}_${target}"
					snap_dev="`dirname "$source"`/$snap_name"
					virsh suspend "$dom"
					lvcreate -L"$LVM_SNAPSHOT_SIZE" -s -n "$snap_name" "$source"
					virsh resume "$dom"
					save_blkdev "$snap_dev" "$out_file" "$sha_file"
 					lvremove -f "$snap_dev"
				elif [ -f "$source" ]
				then
					virsh suspend "$DOMAIN"
					save_blkdev "$source" "$out_file" "$sha_file"
					virsh resume "$DOMAIN"
				else
					log "WARNING: skipped disk \`$source'"
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


# Interactive removal of $BACKUP_DIR and $LVM_SNAPSHOT_DEV
exit_handler() {
	log "interrupted"
	if [ -d "$BACKUP_DIR" ]
	then
		rm -I -- "$BACKUP_DIR"
	fi
	if [ -b "$LVM_SNAPSHOT_DEV" ]
	then
		lvremove "$LVM_SNAPSHOT_DEV"
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
	-l|--list)
		exec virsh --quiet list --all
	;;
	-u|--update)
		exec wget -O "$0" https://raw.github.com/swaeku/virsh-tools/master/virsh-lvm-backup.sh
	;;
	--)
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

trap exit_handler EXIT

while [ $# -gt 0 ]
do
	domname=`virsh domname "$1"` \
		|| die "domain \`$1' not found"	

	log "$domname: STARTED"
	virsh dominfo "$domname"

	BACKUP_DIR="$OUTPUT_DIR/`date -u '+%F.%H%M%S'`.$NAME.$HOSTNAME.$domname"
	mkdir -v "$BACKUP_DIR" \
		|| die "can't create backup directory \`$BACKUP_DIR'"

	save_domxml "$domname" "$BACKUP_DIR"
	save_domdisks "$domname" "$BACKUP_DIR"
	#gen_restore_script "$domname" "$BACKUP_DIR"

	ls -1sh -- "$BACKUP_DIR"
	BACKUP_DIR=
	LVM_SNAPSHOT_DEV=
	log "$domname: FINISHED"

	shift
done


exit 0

