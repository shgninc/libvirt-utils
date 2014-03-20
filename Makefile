# Makefile
#
SHELL = /bin/sh

VERSION = '2014-03-20'

SH_FILES = $(wildcard *.sh)
SCRIPTS = $(SH_FILES:.sh=)


build: $(SCRIPTS)

clean::
	rm -f $(SCRIPTS)

%: %.sh
	sed -e 's|@VERSION@|$(VERSION)|g' $< > $@
	sh -n $@
