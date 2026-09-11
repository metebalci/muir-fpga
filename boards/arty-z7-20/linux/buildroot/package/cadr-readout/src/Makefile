# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory, `cadr-console`'s shape exactly.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS for the ARM and
# DESTDIR for install, and `all` makes the program that goes on the board.
#
# The host build, `make check`: the program's core against a model of the
# console's window, on the build host --- no board, no fabric, nothing but a
# C compiler. Scratch goes under ~/.cache, never /tmp, which is a RAM disk on
# the build host.
#
# **TWO SOURCE LISTS FOR THE SHARED CODE, AND WHICH IS FOR WHICH BUILD.**
# /dev/mem, the EMIO tally guard and the logging are cadr-common's.
# Buildroot's `local` site method rsyncs only THIS directory into the build
# tree, so the sibling package's files are not there at target-build time and
# a relative include of them would build here and fail under Buildroot. So:
#
#   the target build (`all`)   -lcadr-common, the static library cadr-common
#                              installs into the staging tree
#   the host build (`check`)   the same .c files compiled straight from
#                              $(COMMON_DIR), where `..` is a real directory
#
# `make all COMMON=host` builds the program itself the host way, which is how
# it is compiled here without Buildroot.

PROGRAMS := cadr-readout
CORE     := readout.c
HEADERS  := readout.h cadr_image.h

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
WORK   ?= $(HOME)/.cache/muir-fpga-readout

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

cadr-readout: cadr-readout.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(LDFLAGS) -o $@ cadr-readout.c $(CORE) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

# The check. Its own object directory, so a target build and a host build
# never share a binary --- and a build artefact that outlived a move would
# name a home directory that no longer exists.
#
check: $(WORK)/readout_test
	$(WORK)/readout_test

$(WORK)/readout_test: readout_test.c $(CORE) $(HEADERS)
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -o $@ readout_test.c $(CORE)

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check clean
