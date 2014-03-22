# libvirt-utils

Utilities for managing [virsh][virsh] guest domains

## Usage

### virsh-lvm-backup

	Backup QEMU/KVM domains
	
	Usage:
	  virsh-lvm-backup [OPTIONS] [--] DOMAIN...
	
	Options:
	  -d, --directory DIR
	                 Write backups in directory DIR (default is ".")
	  -l, --list     List all defined domains
	  -L, --limit RATE
	                 Limit the IO transfer to a maximum of RATE bytes per second.
	                 A suffix of "k", "m", "g", or "t" can be added to denote
	                 kilobytes (*1024), megabytes, and so on. (default is 5m)
	  -u, --update   Auto-update the script to the latest version
	
	  -h, --help     Print this help message and exit
	  -V, --version  Print script version and exit
	

## See Also

- [libvirt virtualization API](http://libvirt.org/index.html)

## License

[Apache 2.0](http://opensource.org/licenses/Apache-2.0)


[virsh]: http://libvirt.org/sources/virshcmdref/html-single/

