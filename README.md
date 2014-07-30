# libvirt-utils

Utilities for managing [virsh][virsh] domains

## Usage

### virsh-backup

	Backup virsh domains

	Usage:
	  virsh-backup [OPTIONS] [--] DOMAIN...

	Options:
	  -d, --directory DIR
					 Write backups in directory DIR (default is ".").
	  -f, --filter
					 List existing backups for the current host.
	  -l, --list     List all defined domains.
	  -L, --limit RATE
					 Limit the IO transfer to a maximum of RATE bytes per
					 second. A suffix of "k", "m", "g", or "t" can be
					 added to denote kilobytes (*1024), megabytes, and so on.
					 The transfer rate is not limited if the value is 0 (zero).
					 (default is 0).
	  -p, --pause METHOD
					 Specifies what to do if the domain to backup is already
					 running. If METHOD is "none", then nothing is
					 done and backuped data may be inconsistent. Other self-
					 explanatory values for METHOD are "suspend" and
					 "shutdown". (default is shutdown).
	  -q, --quiet    Do not print the progress bar. This option is activated
					 automatically if standard output is not a terminal.
	  -v, --verbose  Print informative messages on standard output.

	  -h, --help     Print this help message and exit.
	  -V, --version  Print script version and exit.


## See Also

- [libvirt virtualization API](http://libvirt.org/index.html)

## License

[Apache 2.0](http://opensource.org/licenses/Apache-2.0)


[virsh]: http://libvirt.org/sources/virshcmdref/html-single/

