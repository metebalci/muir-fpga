# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS for the ARM and
# DESTDIR for install, and `all` makes the program that goes on the board.
#
# The host build, `make check`: the RFB server's core driven from a screen of
# this machine's own, with a viewer written for the purpose on a real socket,
# on the build host --- no board, no fabric, nothing but a C compiler.  Then
# every record in screen_mutations.txt applied to a copy of the sources, each
# of which the check must FAIL on; a mutation that survives is reported and
# the run is red.  Scratch goes under ~/.cache, never /tmp, which is a RAM
# disk on the build host.
#
# **TWO SOURCE LISTS FOR THE SHARED CODE, AND WHICH IS FOR WHICH BUILD.**
# /dev/mem, the EMIO tally guard and the logging are cadr-common's.
# Buildroot's `local` site method rsyncs only THIS directory into the build
# tree, so the sibling package's files are not there at target-build time and
# a relative include of them would build here and fail under Buildroot.  So
# the target build links the static library cadr-common installs to staging
# --- $(TARGET_CONFIGURE_OPTS) carries --sysroot, so neither -I nor -L is
# needed --- and the host build compiles the same .c files from `..`, which is
# a real directory here.  `make all COMMON=host` builds the program itself
# that way, which is how it is compiled here without Buildroot.
#
# **THE REAL SCREENS ARE OPTIONAL AND THE CHECK SAYS WHICH IT RAN.**  Two
# pictures muir drew of MIT's System 100 band live in vendor/screen/, which is
# gitignored with the rest of vendor/, so a fresh clone has the check's
# hand-computed anchors and its synthetic screen and says the real ones are
# absent --- the same shape as `rtl_sys` skipping when the release archive is
# not there.  docs/terminal.md has the three commands that make them.

PROGRAMS := cadr-terminal
CORE     := screen_frame.c screen_rfb.c screen_server.c
HEADERS  := screen_geom.h screen_frame.h screen_rfb.h screen_server.h

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
WORK    ?= $(HOME)/.cache/muir-fpga-screen
SCREENS ?= $(abspath ../../../../../../../vendor/screen)

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

cadr-terminal: cadr-terminal.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(LDFLAGS) -o $@ cadr-terminal.c $(CORE) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

# The check.  Its own object directory, so a target build and a host build
# never share a binary --- and a build artefact that outlived a machine move
# would name a home directory that no longer exists.
check: $(WORK)/screen_test
	$(WORK)/screen_test --screens $(SCREENS) --server-log $(WORK)/server.log
	@python3 mutate.py --list screen_mutations.txt --work $(WORK)/mutants \
	    --screens $(SCREENS) --cc "$(HOSTCC)" --cflags "$(HOSTCFLAGS)"

# The check alone, without the mutations: what a failing mutant runs.
check-only: $(WORK)/screen_test
	$(WORK)/screen_test --screens $(SCREENS) --server-log $(WORK)/server.log

$(WORK)/screen_test: screen_test.c $(CORE) $(HEADERS) $(COMMON_SRC)
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -I$(COMMON_DIR) -o $@ screen_test.c $(CORE) $(COMMON_SRC)

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check check-only clean
