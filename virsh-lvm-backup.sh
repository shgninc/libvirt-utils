#!/bin/sh
#
set -e
set -u

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

# Print a message on STDERR and quit
die() {
	log "ERROR: $*" >&2
	exit 1
}

# Log a message on STDOUT
log() {
	echo "$NAME: $*"
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
				lvcreate -L"$LVM_SNAPSHOT_SIZE" -s -n "${DOMAIN}_${target}" "$source"
			done
	virsh resume "$DOMAIN"
}

remove_snapshots() {
	local source= target= blk_dev=
	virsh_domblklist "$DOMAIN" \
                | while read target source
                        do
				blk_dev="$(dirname "$source")/${DOMAIN}_${target}"
				log "remove LVM snapshot \`$blk_dev'"
 				lvremove -f "$blk_dev"
			done
}


save_domxml() {
	local xml_file="$OUTDIR/$DOMAIN.xml"
	log "write domain definition \`${xml_file##*/}'"
	virsh dumpxml --security-info "$DOMAIN" > "$xml_file"
}

save_domdisks() {
	local sha_file= blk_file= blk_dev= target= source=
	virsh_domblklist "$DOMAIN" \
		| while read target source
			do
				blk_dev="$(dirname "$source")/${DOMAIN}_${target}"
				sha_file="$OUTDIR/$target.sha"
				blk_file="$OUTDIR/$target.raw.gz"
				log "compress \`$blk_dev' -> \`${blk_file##*/}'"
				touch "$sha_file"
				ionice -c 3 -t dd if="$blk_dev" \
					| pv -s `get_lvm_size "$source"` \
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

echo 'restore domain $DOMAIN'
"
		echo 'cd "`dirname "$0"`"'
		virsh_domblklist "$DOMAIN" \
			| while read target source
			do
				blk_file="$target.raw.gz"
				lvm_name=`basename "$source"`
				lvm_group=`get_lvm_group "$source"`
				lvm_size=`get_lvm_size "$source"`
				echo "echo 'restore virtual disk $target...'
ionice -c 3 shasum '$blk_file'
lvcreate -L'${lvm_size}b' -n '$lvm_name' '$lvm_group'
nice -19 gzip -dc '$blk_file' | pv -s $lvm_size | ionice -c 3 dd of='$source'"
			done

		echo "virsh define $DOMAIN.xml
virsh dominfo $DOMAIN
echo done
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

