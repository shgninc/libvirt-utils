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

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LVM_SNAPSHOT_SIZE='1G'
LVM_SNAPSHOT=
OUTPUT_DIR=


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

# List block devices for $1
virsh_domblklist() {
	# virsh --quiet still prints headers
	virsh domblklist "${1?}" \
		| awk 'NR == 1 && $1 == "Target" && $2 == "Source" { getline; getline; } { print }'
}

get_lvm_size() {
	lvs --nosuffix --units b --noheadings "${1?}" \
		| awk '{ print $4 }'
}

get_lvm_group() {
	lvs --nosuffix --units b --noheadings "${1?}" \
		| awk '{ print $2 }'
}

create_output_dir() {
	OUTDIR="$(date -u '+%F.%H%M%S').$NAME.$(hostname).$DOMAIN"
	log "create backup directory \`$OUTDIR'"
	mkdir "$OUTDIR"
}

save_domxml() {
	local xml_file="$OUTDIR/$DOMAIN.xml"
	log "write domain definition \`${xml_file##*/}'"
	virsh dumpxml --security-info "$DOMAIN" > "$xml_file"
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

save_domdisks() {
	local sha_file= out_file= snap_name= snap_dev= target= source=
	virsh_domblklist "$DOMAIN" \
		| while read target source
			do
				out_file="$OUTDIR/$target.raw.gz"
				sha_file="$OUTDIR/$target.sha"
				if [ -b "$source" ]
				then
					snap_name="${DOMAIN}_${target}"
					snap_dev="`dirname "$source"`/$snap_name"
					virsh suspend "$DOMAIN"
					lvcreate -L"$LVM_SNAPSHOT_SIZE" -s -n "$snap_name" "$source"
					virsh resume "$DOMAIN"
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

exit_handler() {
	log "interrupted"
	if [ -d "$OUTPUT_DIR" ]
	then
		rm -I -- "$OUTPUT_DIR"
	fi
	if [ -n "$LVM_SNAPSHOT" ]
	then
		lvremove "$LVM_SNAPSHOT"
	fi
}
trap exit_handler EXIT

while [ $# -gt 0 ]
do
	name=`virsh domname "$1"` \
	  || die "domain \`$1' not found"	

	DOMAIN="$1"
	OUTDIR=

	log "$DOMAIN: STARTED"
	virsh dominfo "$name"
	create_output_dir
	save_domxml
	save_domdisks
	gen_restore_script

	ls -1sh "$OUTDIR"
	log "$DOMAIN: FINISHED"
	
	OUTPUT_DIR=
	LVM_SNAPSHOT=

	shift
done


exit 0

