# Makefile
#
SHELL = /bin/sh

SH_FILES = $(wildcard *.sh)
SCRIPTS = $(SH_FILES:.sh=)

build: $(SCRIPTS)

clean::
	rm -f $(SCRIPTS)

%: %.sh
	sh -n $<
	install -m 0755 $< $@
