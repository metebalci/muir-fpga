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

PROGRAMS := cadr-disk-packs
CORE     := pack_file.c pack_bay.c pack_side.c pack_feeder.c quux_disk.c
HEADERS  := pack_ecc.h pack_file.h pack_bay.h pack_side.h pack_feeder.h quux_disk.h

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
GOLDEN ?= $(abspath ../../../../../../../build/disk.golden)
# QUUX's disks (contract Q8): one small GPT disk raw, as a fixed and a dynamic
# VHD, and the dynamic one grown by three writes with its raw twin, made by
# qemu-img, qemu-io and sgdisk and never by muir or this program.  They are
# muir's `data/quux-disk*`, from the muir beside this repository as
# `golden/Cargo.toml` finds it, and held to the digests in `q8_disks.sha256`
# before the check reads them: a different muir's regenerated disks are a
# different witness and must not pass for this one.  `Q8_DISKS=<dir>` names
# another directory holding the same five files.
Q8_DISKS ?= $(abspath ../../../../../../../../muir/data)
Q8_VERIFY = @for f in $$(awk '{print $$2}' q8_disks.sha256); do \
	    test -f $(Q8_DISKS)/$$f || { echo "no $(Q8_DISKS)/$$f: QUUX's disks are muir's data/quux-disk*, from muir fdaa423 on; or pass Q8_DISKS=<dir>"; exit 1; }; done; \
	sed 's|  |  $(Q8_DISKS)/|' q8_disks.sha256 | sha256sum -c --quiet - \
	    || { echo "the disks in $(Q8_DISKS) are not the ones this check is held to (q8_disks.sha256)"; exit 1; }
# The work directory is this directory's own, by its path hashed, as
# `cadr-console`'s and `cadr-terminal`'s are: one fixed path for every tree at
# once let one worktree's newer binaries run in place of another's sources.
# The top-level Makefile passes its own, under its `build/`.
WORK   ?= $(HOME)/.cache/muir-fpga-disk-packs-$(shell printf '%s' '$(CURDIR)' | sha256sum | cut -c1-12)

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

cadr-disk-packs: cadr-disk-packs.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(LDFLAGS) -o $@ cadr-disk-packs.c $(CORE) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

# **QUUX'S DISK AS A LIBRARY, STAGING ONLY**, for `cadr-checkpoint`, which
# binds a QUUX disk by the same test the drive bay makes of it and must not
# carry a second copy of that test.  `cadr-readout`'s shape: the header in a
# cadr/ directory of its own, so the consumer writes the same quoted include
# on the host, where the directory is this one.
LIB := libquux-disk.a

$(LIB): quux_disk.o
	$(AR) rcs $@ quux_disk.o

quux_disk.o: quux_disk.c quux_disk.h
	$(CC) $(CFLAGS) -c -o $@ quux_disk.c

install-staging: $(LIB)
	install -d $(DESTDIR)/usr/lib $(DESTDIR)/usr/include/cadr
	install -m 0644 $(LIB) $(DESTDIR)/usr/lib/
	install -m 0644 quux_disk.h $(DESTDIR)/usr/include/cadr/

# The check.  Its own object directory, so a target build and a host build
# never share a binary.
check: $(WORK)/feeder_test
	@test -f $(GOLDEN) || { echo "no $(GOLDEN): run 'make disk-golden' at the repository root"; exit 1; }
	$(Q8_VERIFY)
	$(WORK)/feeder_test $(GOLDEN) $(WORK) $(Q8_DISKS)

$(WORK)/feeder_test: feeder_test.c $(CORE) $(HEADERS) $(wildcard $(COMMON_DIR)/cadr/*.h)
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -I$(COMMON_DIR) -o $@ feeder_test.c $(CORE)

mutants:
	@test -f $(GOLDEN) || { echo "no $(GOLDEN): run 'make disk-golden' at the repository root"; exit 1; }
	$(Q8_VERIFY)
	python3 mutate.py --list pack_mutations.txt --work $(WORK)/mutants --golden $(GOLDEN) --q8-disks $(Q8_DISKS) $(MUTANT_ARGS)

clean:
	rm -f $(PROGRAMS) $(LIB) quux_disk.o

.PHONY: all install install-staging check mutants clean
