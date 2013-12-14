#!/bin/sh
#
#   Copyright 2013 Sebastien Andre <swaeku@gmx.com>
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

# undocumented auto-update hack
if [ "$1" = '-u' ]
then
	exec wget -O "$0" https://raw.github.com/swaeku/virsh-tools/master/virsh-lvm-backup.sh
fi

NAME="${0##*/}"
USAGE="Backup QEMU/KVM domains

Usage:
  $NAME <domain>...

Domains:
`virsh --quiet list --all`
"

LVM_SNAPSHOT_SIZE='1G'
DOMAIN=
OUTDIR=

nice() {
	command nice -19 "$@"
}

ionice() {
	command ionice -c 3 -t "$@"
}

# Print a message on STDERR and quit
die() {
	log "ERROR: $*" >&2
	exit 1
}

# Log a message on STDOUT
log() {
	echo "`date '+[%F %T]'` $NAME: $*"
}

# Run virsh with default options
virsh() {
	command virsh --quiet "$@"
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

create_snapshots() {
	local source= target=
	log "$DOMAIN: create LVM snapshots"
	virsh suspend "$DOMAIN"
	virsh_domblklist "$DOMAIN" \
		| while read target source
			do
				if [ -b "$source" ]
				then
					lvcreate -L"$LVM_SNAPSHOT_SIZE" -s -n "${DOMAIN}_${target}" "$source"
				else
					log "WARNING: ignored non block device \`$source'"
				fi
			done
	virsh resume "$DOMAIN"
}

remove_snapshots() {
	local source= target= blk_dev=
	virsh_domblklist "$DOMAIN" \
                | while read target source
                        do
				if [ -b "$source" ]
				then
					blk_dev="$(dirname "$source")/${DOMAIN}_${target}"
					log "remove LVM snapshot \`$blk_dev'"
 					lvremove -f "$blk_dev"
				fi
			done
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
	local sha_file= blk_file= blk_dev= target= source=
	virsh_domblklist "$DOMAIN" \
		| while read target source
			do
				blk_dev="$(dirname "$source")/${DOMAIN}_${target}"
				[ -b "$blk_dev" ] || continue
				sha_file="$OUTDIR/$target.sha"
				blk_file="$OUTDIR/$target.raw.gz"
				log "compress \`$blk_dev' -> \`${blk_file##*/}'"
				touch "$sha_file"
				ionice -c 3 -t pv "$blk_dev" \
					| nice -19 gzip -c \
					| tee "$blk_file" \
					| nice -19 shasum > "$sha_file"
				log "write checksum file \`${sha_file##*/}'"
				sed -i "s/-/$target.raw.gz/" "$sha_file"
			done
}

gen_restore_script() {
	local blk_file= lvm_name= lvm_group= lvm_size=
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

echo -n 'Restore domain $DOMAIN? [y/N] '
read ANS
if [ \"\$ANS\" != y ]
then
	echo 'Canceled by user.'
	exit 3
fi
echo START
"
		echo 'cd "`dirname "$0"`"'
		virsh_domblklist "$DOMAIN" \
			| while read target source
			do
				blk_file="$target.raw.gz"
				lvm_name=`basename "$source"`
				lvm_group=`get_lvm_group "$source"`
				lvm_size=`get_lvm_size "$source"`
				echo "echo 'Verifying checksum file $blk_file...'
ionice -c 3 shasum '$blk_file'
echo 'Restoring virtual disk $target...'
lvcreate -L'${lvm_size}b' -n '$lvm_name' '$lvm_group'
nice -19 gzip -dc '$blk_file' | pv -s $lvm_size | ionice -c 3 dd of='$source'"
			done

		echo "echo 'Defining domain $DOMAIN'
virsh define $DOMAIN.xml
virsh dominfo $DOMAIN
echo DONE
exit 0
"
	} > "$script"
	chmod 0755 "$script"
}



if [ $# -eq 0 ]
then
	echo "$USAGE" >&2
	exit 2
elif [ `id -u` -ne 0 ]
then
	die "need root permisions"
fi

while [ $# -gt 0 ]
do
	DOMAIN="$1"
	OUTDIR=

	log "$DOMAIN: STARTED"
	virsh dominfo "$DOMAIN"

	create_output_dir
	create_snapshots
	save_domxml
	save_domdisks
	gen_restore_script
	remove_snapshots

	ls -1sh "$OUTDIR"
	log "$DOMAIN: FINISHED"

	shift
done

exit 0

