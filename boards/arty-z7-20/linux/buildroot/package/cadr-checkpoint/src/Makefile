# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory, `cadr-readout`'s shape exactly.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS for the ARM and
# DESTDIR for install, and `all` makes the program that goes on the board.
#
# The host build, `make check`: the program's core against a model of the
# console's window, on the build host --- no board, no fabric, nothing but a
# C compiler. Scratch goes under ~/.cache, never /tmp, which is a RAM disk on
# the build host.
#
# **TWO SOURCE LISTS FOR EACH BORROWED LIBRARY, AND WHICH IS FOR WHICH BUILD.**
# This program borrows three times: /dev/mem, the EMIO tally guard and the
# logging are cadr-common's, the console's readout window is cadr-readout's,
# and the test that says a file is QUUX's disk is cadr-disk-packs's.
# Buildroot's `local` site method rsyncs only THIS directory into the build
# tree, so no sibling's files are there at target-build time and a
# relative include of them would build here and fail under Buildroot. All
# three packages therefore install a static library and their headers into
# the staging tree, and this links against them. So:
#
#   the target build (`all`)   -lcadr-common -lcadr-readout -lquux-disk, and the headers
#                              out of the staging tree
#   the host build (`check`)   the same .c files compiled straight from the
#                              sibling directories, where `..` is real
#
# `make all COMMON=host READOUT=host DISK=host` builds the program itself the host way,
# which is how it is compiled here without Buildroot.
#
# **NOTHING OF cadr-readout IS COPIED INTO THIS DIRECTORY.**  `readout.c`,
# `readout.h` and `cadr_image.h` have one home in the repository and this
# package borrows them; a second copy would be a second description of the
# console's window, which is the thing the window's own header already warns
# about for the four constants it cannot avoid repeating.

PROGRAMS := cadr-checkpoint
CORE     := chk.c chk_rtl.c pack_bind.c sha256.c
HEADERS  := chk.h chk_rtl.h pack_bind.h sha256.h

COMMON       ?= staging
COMMON_DIR   := ../../cadr-common/src
COMMON_SRC   := $(COMMON_DIR)/cadr_log.c $(COMMON_DIR)/cadr_mem.c
ifeq ($(COMMON),host)
COMMON_CFLAGS := -I$(COMMON_DIR)
COMMON_LINK   := $(COMMON_SRC)
else
COMMON_CFLAGS :=
COMMON_LINK   := -lcadr-common
endif

# The readout, the same way. `READOUT_INC` is where `readout.h` and
# `cadr_image.h` are: the sibling's src/ on the host, and the staging tree's
# `usr/include/cadr` on the target, which `cadr-checkpoint.mk` passes in. The
# includes are quoted rather than angled so that one spelling serves both.
READOUT      ?= staging
READOUT_DIR  := ../../cadr-readout/src
READOUT_SRC  := $(READOUT_DIR)/readout.c
ifeq ($(READOUT),host)
READOUT_INC  ?= -I$(READOUT_DIR)
READOUT_LINK := $(READOUT_SRC)
else
READOUT_INC  ?=
READOUT_LINK := -lcadr-readout
endif

# And QUUX's disk, `cadr-disk-packs`'s `quux_disk.c`, the same way: its
# header beside the readout's in the staging tree's `usr/include/cadr`, which
# `READOUT_INC` already names on the target.
DISK         ?= staging
DISK_DIR     := ../../cadr-disk-packs/src
DISK_SRC     := $(DISK_DIR)/quux_disk.c
ifeq ($(DISK),host)
DISK_INC     := -I$(DISK_DIR)
DISK_LINK    := $(DISK_SRC)
else
DISK_INC     :=
DISK_LINK    := -lquux-disk
endif

HOSTCC ?= cc
HOSTCFLAGS ?= -O2 -Wall -Wextra -std=gnu11
# The work directory is this directory's own, by its path hashed, as
# `cadr-console`'s and `cadr-terminal`'s are: one fixed path for every tree at
# once let one worktree's newer binaries run in place of another's sources.
# The top-level Makefile passes its own, under its `build/`.
WORK   ?= $(HOME)/.cache/muir-fpga-checkpoint-$(shell printf '%s' '$(CURDIR)' | sha256sum | cut -c1-12)

# QUUX's disks (contract Q8), which the binding's check holds a QUUX disk's
# detection to: muir's `data/quux-disk*`, made by qemu, from the muir beside
# this repository as `golden/Cargo.toml` finds it, and held to the digests
# `cadr-disk-packs` records for the same five files before the check reads
# them.  `Q8_DISKS=<dir>` names another directory holding them.
Q8_DISKS ?= $(abspath ../../../../../../../../muir/data)
Q8_SUMS  := ../../cadr-disk-packs/src/q8_disks.sha256
Q8_VERIFY = @for f in $$(awk '{print $$2}' $(Q8_SUMS)); do \
	    test -f $(Q8_DISKS)/$$f || { echo "no $(Q8_DISKS)/$$f: QUUX's disks are muir's data/quux-disk*; or pass Q8_DISKS=<dir>"; exit 1; }; done; \
	sed 's|  |  $(Q8_DISKS)/|' $(Q8_SUMS) | sha256sum -c --quiet - \
	    || { echo "the disks in $(Q8_DISKS) are not the ones this check is held to ($(Q8_SUMS))"; exit 1; }

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

cadr-checkpoint: cadr-checkpoint.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(READOUT_INC) $(DISK_INC) $(LDFLAGS) -o $@ \
	    cadr-checkpoint.c $(CORE) $(READOUT_LINK) $(DISK_LINK) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

# The check. Its own object directory, so a target build and a host build
# never share a binary --- and a build artifact that outlived a move would
# name a home directory that no longer exists.
#
# `CHK` names a file for it to write, which is how `build/checkpoint.pass`
# gets something for muir to open, and `QCHK` the QUUX machine's, which
# `build/checkpoint.quux.pass` compares with muir's own.
check: $(WORK)/checkpoint_test
	$(Q8_VERIFY)
	$(WORK)/checkpoint_test $(WORK) $(Q8_DISKS) $(CHK) $(QCHK)

$(WORK)/checkpoint_test: checkpoint_test.c $(CORE) $(HEADERS) $(wildcard $(COMMON_DIR)/cadr/*.h) \
                         $(READOUT_DIR)/readout.c $(READOUT_DIR)/readout.h \
                         $(READOUT_DIR)/cadr_image.h $(DISK_SRC) $(DISK_DIR)/quux_disk.h
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -I$(READOUT_DIR) -I$(COMMON_DIR) -I$(DISK_DIR) -o $@ checkpoint_test.c \
	    $(CORE) $(READOUT_SRC) $(DISK_SRC)

# The mutants. **A ROUND TRIP THAT CANNOT FAIL IS NOT EVIDENCE**, so the same
# check is built again with each value of `CHK_MUTATE` and `build/checkpoint
# .pass` requires muir to refuse or to disagree with every one of them.
# `CHK_MUTATE` is never defined in the program installed on the board.
#
# The list and the two loops in the repository's own Makefile are two
# statements of one set, and each check runs whatever its loop names: 1 to 8
# are the CADR's, judged by `build/checkpoint.pass`, and 9 to 16 QUUX's,
# judged by `build/checkpoint.quux.pass`.  A mutant added here and not there
# is built and never judged.
MUTANTS := 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17
mutants: $(foreach m,$(MUTANTS),$(WORK)/checkpoint_test-$(m))

$(WORK)/checkpoint_test-%: checkpoint_test.c $(CORE) $(HEADERS) $(wildcard $(COMMON_DIR)/cadr/*.h) \
                           $(READOUT_DIR)/readout.c $(READOUT_DIR)/readout.h \
                           $(READOUT_DIR)/cadr_image.h $(DISK_SRC) $(DISK_DIR)/quux_disk.h
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -DCHK_MUTATE=$* -I$(READOUT_DIR) -I$(COMMON_DIR) -I$(DISK_DIR) -o $@ \
	    checkpoint_test.c $(CORE) $(READOUT_SRC) $(DISK_SRC)

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check mutants clean
