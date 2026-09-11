# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS for the ARM and
# DESTDIR for install, and `all` makes the program that goes on the board.
#
# The host build, `make check`: the console program's core linked against a
# model of the slave, with a modelled machine behind the diagnostic bus, on
# the build host --- no board, no fabric, nothing but a C compiler.  Scratch
# goes under ~/.cache, never /tmp, which is a RAM disk on the build host.
#
# **TWO SOURCE LISTS FOR THE SHARED CODE, AND WHICH IS FOR WHICH BUILD.**
# /dev/mem, the EMIO tally guard and the logging are cadr-common's.
# Buildroot's `local` site method rsyncs only THIS directory into the build
# tree, so the sibling package's files are not there at target-build time and
# a relative include of them would build here and fail under Buildroot.  So:
#
#   the target build (`all`)   -lcadr-common, the static library cadr-common
#                              installs into the staging tree.
#                              $(TARGET_CONFIGURE_OPTS) carries --sysroot, so
#                              neither -I nor -L is needed
#   the host build (`check`)   the same .c files compiled straight from
#                              $(COMMON_DIR), where `..` is a real directory
#
# `make all COMMON=host` builds the program itself the host way, which is how
# it is compiled here without Buildroot.

PROGRAMS := cadr-console
CORE     := console_face.c
HEADERS  := console_face.h

COMMON      ?= staging
COMMON_DIR  := ../../cadr-common/src
COMMON_SRC  := $(COMMON_DIR)/cadr_log.c $(COMMON_DIR)/cadr_mem.c
ifeq ($(COMMON),host)
COMMON_CFLAGS := -I$(COMMON_DIR)
COMMON_LINK   := $(COMMON_SRC)
else
COMMON_CFLAGS :=
COMMON_LINK   := -lcadr-common
endif

HOSTCC ?= cc
HOSTCFLAGS ?= -O2 -Wall -Wextra -std=gnu11
WORK   ?= $(HOME)/.cache/muir-fpga-console

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

cadr-console: cadr-console.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(LDFLAGS) -o $@ cadr-console.c $(CORE) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

# The check.  Its own object directory, so a target build and a host build
# never share a binary --- and a build artefact that outlived a move would
# name a home directory that no longer exists.
check: $(WORK)/console_test
	$(WORK)/console_test

$(WORK)/console_test: console_test.c $(CORE) $(HEADERS) $(COMMON_SRC)
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -I$(COMMON_DIR) -o $@ console_test.c $(CORE) $(COMMON_SRC)

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check clean
