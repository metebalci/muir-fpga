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
# This program borrows twice: /dev/mem, the EMIO tally guard and the logging
# are cadr-common's, and the console's readout window is cadr-readout's.
# Buildroot's `local` site method rsyncs only THIS directory into the build
# tree, so neither sibling's files are there at target-build time and a
# relative include of them would build here and fail under Buildroot. Both
# packages therefore install a static library and their headers into the
# staging tree, and this links against them. So:
#
#   the target build (`all`)   -lcadr-common -lcadr-readout, and the headers
#                              out of the staging tree
#   the host build (`check`)   the same .c files compiled straight from the
#                              sibling directories, where `..` is real
#
# `make all COMMON=host READOUT=host` builds the program itself the host way,
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

HOSTCC ?= cc
HOSTCFLAGS ?= -O2 -Wall -Wextra -std=gnu11
WORK   ?= $(HOME)/.cache/muir-fpga-checkpoint

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

cadr-checkpoint: cadr-checkpoint.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(READOUT_INC) $(LDFLAGS) -o $@ \
	    cadr-checkpoint.c $(CORE) $(READOUT_LINK) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

# The check. Its own object directory, so a target build and a host build
# never share a binary --- and a build artefact that outlived a move would
# name a home directory that no longer exists.
#
# `CHK` names a file for it to write, which is how `build/checkpoint.pass`
# gets something for muir to open.
check: $(WORK)/checkpoint_test
	$(WORK)/checkpoint_test $(WORK) $(CHK)

$(WORK)/checkpoint_test: checkpoint_test.c $(CORE) $(HEADERS) \
                         $(READOUT_DIR)/readout.c $(READOUT_DIR)/readout.h \
                         $(READOUT_DIR)/cadr_image.h
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -I$(READOUT_DIR) -o $@ checkpoint_test.c \
	    $(CORE) $(READOUT_SRC)

# The mutants. **A ROUND TRIP THAT CANNOT FAIL IS NOT EVIDENCE**, so the same
# check is built again with each value of `CHK_MUTATE` and `build/checkpoint
# .pass` requires muir to refuse or to disagree with every one of them.
# `CHK_MUTATE` is never defined in the program installed on the board.
MUTANTS := 1 2 3
mutants: $(foreach m,$(MUTANTS),$(WORK)/checkpoint_test-$(m))

$(WORK)/checkpoint_test-%: checkpoint_test.c $(CORE) $(HEADERS) \
                           $(READOUT_DIR)/readout.c $(READOUT_DIR)/readout.h \
                           $(READOUT_DIR)/cadr_image.h
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -DCHK_MUTATE=$* -I$(READOUT_DIR) -o $@ \
	    checkpoint_test.c $(CORE) $(READOUT_SRC)

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check mutants clean
