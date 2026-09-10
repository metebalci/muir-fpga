# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS for the ARM and
# DESTDIR for install, and `all` makes the programs that go on the board.
#
# **TWO SOURCE LISTS FOR THE SHARED CODE, AND WHICH IS FOR WHICH BUILD.**
# /dev/mem, the EMIO tally guard and the logging are `cadr-common`'s.
# Buildroot's `local` site method rsyncs only THIS directory into the build
# tree, so the sibling package's files are not there at target-build time and
# a relative include of them would build here and fail under Buildroot.  So
# the target build links the static library cadr-common installs to staging
# --- $(TARGET_CONFIGURE_OPTS) carries --sysroot, so no -I and no -L --- and
# the host build, where `..` is a real directory, compiles the same .c files
# from it.  `make check` is a host build.  `make all COMMON=host` builds the
# program itself that way, which is how the refactor onto cadr-common was
# checked without Buildroot.
#
# The host build, `make check`: the disk pack program's core linked against a model
# of the register face, with a scripted disk controller behind it posting
# the requests the reference trace's transfers would and more, on the build
# host --- no board, no fabric, nothing but a C compiler and build/disk.golden
# (`make disk-golden` at the repository root writes it).  Scratch goes under
# ~/.cache, never /tmp, which is a RAM disk on the build host.  The drive bay
# is checked there too, against a real directory of real files under the same
# work directory: the eight names, a pack appearing and going away, a rename
# and a delete each with blocks the machine had written, the read-only mark
# moving, and two units serving two packs at once.
#
# And `make mutants`, which is what says `make check` can fail: each record
# in pack_mutations.txt is a bug this package's check has to catch, applied
# to a copy of these sources, built in a directory of its own and run.
# mutate.py is the runner and its header says why a build failure is neither
# a survivor nor a catch.  It is not part of `check`, because it builds and
# runs the whole check once per record.

PROGRAMS := cadr-disk-pack
CORE     := pack_file.c pack_bay.c pack_side.c pack_feeder.c
HEADERS  := pack_ecc.h pack_file.h pack_bay.h pack_side.h pack_feeder.h

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
GOLDEN ?= $(abspath ../../../../../build/disk.golden)
WORK   ?= $(HOME)/.cache/muir-fpga-disk-pack

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

cadr-disk-pack: cadr-disk-pack.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(LDFLAGS) -o $@ cadr-disk-pack.c $(CORE) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

# The check.  Its own object directory, so a target build and a host build
# never share a binary.
check: $(WORK)/feeder_test
	@test -f $(GOLDEN) || { echo "no $(GOLDEN): run 'make disk-golden' at the repository root"; exit 1; }
	$(WORK)/feeder_test $(GOLDEN) $(WORK)

$(WORK)/feeder_test: feeder_test.c $(CORE) $(HEADERS)
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -o $@ feeder_test.c $(CORE)

mutants:
	@test -f $(GOLDEN) || { echo "no $(GOLDEN): run 'make disk-golden' at the repository root"; exit 1; }
	python3 mutate.py --list pack_mutations.txt --work $(WORK)/mutants --golden $(GOLDEN) $(MUTANT_ARGS)

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check mutants clean
