# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The shared transport code, as a static library.
#
# The target build is the only build of THIS directory: Buildroot passes CC,
# CFLAGS and AR for the ARM, `all` makes libcadr-common.a and
# `install-staging` puts it and the headers in the staging tree, where
# --sysroot finds them.  Nothing is installed on the target: a static library
# has nothing to ship.
#
# The consumers' HOST builds do not come through here.  There `..` is a real
# directory and a consumer compiles SOURCES straight from it --- see the two
# source lists in each consumer's src/Makefile.  Nothing in this file is used
# on the host, so nothing here may assume the ARM either.

LIB     := libcadr-common.a
SOURCES := cadr_log.c cadr_mem.c
HEADERS := cadr/cadr_log.h cadr/cadr_mem.h
OBJECTS := $(SOURCES:.c=.o)

AR ?= ar
CFLAGS += -Wall -Wextra -std=gnu11 -I.

all: $(LIB)

$(LIB): $(OBJECTS)
	$(AR) rcs $@ $(OBJECTS)

$(OBJECTS): $(HEADERS)

# Staging only.  The headers keep their cadr/ directory, so a consumer writes
# `#include <cadr/cadr_mem.h>` in both of its builds and the two differ only
# in where the directory is.
install-staging: all
	install -d $(DESTDIR)/usr/lib $(DESTDIR)/usr/include/cadr
	install -m 0644 $(LIB) $(DESTDIR)/usr/lib/
	install -m 0644 $(HEADERS) $(DESTDIR)/usr/include/cadr/

install:
	@:

clean:
	rm -f $(LIB) $(OBJECTS)

.PHONY: all install install-staging clean
