# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Buildroot passes CC, CFLAGS and LDFLAGS for the target; DESTDIR for install.

PROGRAMS := cadr-hello

all: $(PROGRAMS)

cadr-hello: cadr-hello.c
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

clean:
	rm -f $(PROGRAMS)

.PHONY: all install clean
