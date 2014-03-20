# Makefile
#
SHELL = /bin/sh

DESTDIR =
BINDIR = /usr/local/bin

VERSION = '2014-03-20'

SH_FILES = $(wildcard *.sh)
SCRIPTS = $(SH_FILES:.sh=)


build: $(SCRIPTS)

install: build
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 -t $(DESTDIR)$(BINDIR) -- $(SCRIPTS)

clean::
	rm -f $(SCRIPTS)


%: %.sh
	sed -e 's|@VERSION@|$(VERSION)|g' $< > $@
	sh -n $@
