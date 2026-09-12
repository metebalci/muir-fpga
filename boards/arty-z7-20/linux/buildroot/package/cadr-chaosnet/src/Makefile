# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS for the ARM and
# DESTDIR for install, and `all` makes the program that goes on the board.
#
# The host build, `make check`: the whole Chaosnet stack except the fabric,
# driven on the build host --- the packet and its check word, the transport of
# AIM-628 chapters 3 and 4, the four services against a real scratch
# directory, CHUDP on a loopback socket, and the register face against a model
# of the RTL.  No board, no fabric, nothing but a C compiler and python3.
# Then every record in chaos_mutations.txt applied to a copy of the sources,
# each of which the check must FAIL on; a mutation that survives is reported
# and the run is red.
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
# Scratch goes under ~/.cache, never /tmp, which is a RAM disk on the build
# host.

PROGRAMS := cadr-chaosnet
CORE     := chaos_packet.c chaos_outq.c chaos_ncp.c chaos_services.c \
            chaos_file.c chaos_udp.c chaos_face.c
HEADERS  := chaos_face.h chaos_packet.h chaos_ncp.h chaos_file.h chaos_udp.h
TESTS    := chaos_test.c chaos_test_packet.c chaos_test_ncp.c \
            chaos_test_file.c chaos_test_udp.c chaos_test_face.c

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
WORK   ?= $(HOME)/.cache/muir-fpga-chaosnet

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

cadr-chaosnet: cadr-chaosnet.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(LDFLAGS) -o $@ cadr-chaosnet.c $(CORE) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

# The check.  Its own object directory, so a target build and a host build
# never share a binary --- and a build artefact that outlived a machine move
# would name a home directory that no longer exists.
check: $(WORK)/chaos_test
	$(WORK)/chaos_test --work $(WORK)/scratch
	@python3 mutate.py --list chaos_mutations.txt --work $(WORK)/mutants \
	    --cc "$(HOSTCC)" --cflags "$(HOSTCFLAGS)"

# The check alone, without the mutations: what a failing mutant runs.
check-only: $(WORK)/chaos_test
	$(WORK)/chaos_test --work $(WORK)/scratch

$(WORK)/chaos_test: $(TESTS) $(CORE) $(HEADERS) chaos_test.h $(COMMON_SRC)
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -I$(COMMON_DIR) -o $@ $(TESTS) $(CORE) $(COMMON_SRC)

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check check-only clean
