# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS for the ARM and
# DESTDIR for install, and `all` makes the program that goes on the board.
#
# The host build, `make check`: the endpoint driven against a model of the
# 2651's far side, with a real client on a loopback socket, on the build host
# --- no board, no fabric, nothing but a C compiler.  Then every record in
# serial_mutations.txt applied to a copy of the sources, each of which the
# check must FAIL on; a mutation that survives is reported and the run is red.
# Scratch goes under ~/.cache, never /tmp, which is a RAM disk on the build
# host.
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
# **THE CHECK NEEDS A LOOPBACK SOCKET AND NOTHING ELSE.**  It binds port 0 and
# asks the kernel which port it got, so two runs of it never collide, and both
# ends of every connection are in the one process.

PROGRAMS := cadr-serial
CORE     := serial_face.c serial_endpoint.c
HEADERS  := serial_face.h serial_endpoint.h

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
# **THE PATH CARRIES THE CHECKOUT, because this tree is worked in several at
# once.**  A fixed `~/.cache/<name>` is shared by the main checkout and every
# `git worktree`, so two of them building at the same time overwrite each
# other's test binary --- and `make` then sees a binary newer than its sources
# and does not rebuild.  Measured 12 Sep: a gate at one commit ran the OTHER
# tree's `chaos_test` and died on `usage:`, because the flags had changed
# under it.  That is CLAUDE.md's stale-artifact scar, met in a third place
# after the cargo target directory and the compiled-in PROM path.
WORK    ?= $(HOME)/.cache/muir-fpga-serial-$(shell printf '%s' '$(CURDIR)' | sha256sum | cut -c1-12)

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

cadr-serial: cadr-serial.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(LDFLAGS) -o $@ cadr-serial.c $(CORE) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

# The check.  Its own object directory, so a target build and a host build
# never share a binary --- and a build artefact that outlived a machine move
# would name a home directory that no longer exists.
check: $(WORK)/serial_test
	$(WORK)/serial_test
	@python3 mutate.py --list serial_mutations.txt --work $(WORK)/mutants \
	    --cc "$(HOSTCC)" --cflags "$(HOSTCFLAGS)"

# The check alone, without the mutations: what a failing mutant runs.
check-only: $(WORK)/serial_test
	$(WORK)/serial_test

$(WORK)/serial_test: serial_test.c $(CORE) $(HEADERS) $(COMMON_SRC)
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -I$(COMMON_DIR) -o $@ serial_test.c $(CORE) $(COMMON_SRC)

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check check-only clean
