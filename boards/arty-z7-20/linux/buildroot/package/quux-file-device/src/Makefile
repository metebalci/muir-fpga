# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory, as every package here has.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS and DESTDIR, and
# `all` makes the program that goes on the board, linking cadr-common's
# static library from staging (`make all COMMON=host` compiles its sources
# from `..` instead, which is how it is built here without Buildroot).
#
# The host build, `make check`, which needs muir: the protocol core, the
# service step and the program's own face over a model of the file device's
# page, run through scripts of rings that muir's own device runs too
# (`golden/src/quux_file_device.rs`, built by the top-level Makefile and
# named here as QFD_GOLDEN), with the transcripts and the folders after held
# to each other byte for byte; then the unit checks; then every record in
# qfd_mutations.txt, each of which the check must FAIL on.  Scratch goes under
# ~/.cache, never /tmp, which is a RAM disk on the build host.

PROGRAMS := quux-file-device
CORE     := qfd.c qfd_ring.c qfd_face_fabric.c
HEADERS  := qfd.h qfd_ring.h qfd_face.h

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
# The path carries the checkout, because this tree is worked in several at
# once (cadr-terminal's Makefile says why).
WORK ?= $(HOME)/.cache/muir-fpga-qfd-$(shell printf '%s' '$(CURDIR)' | sha256sum | cut -c1-12)
QFD_GOLDEN ?=

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

quux-file-device: quux-file-device.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(LDFLAGS) -o $@ quux-file-device.c $(CORE) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

$(WORK)/qfd_test: qfd_test.c $(CORE) $(HEADERS)
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -DQFD_TEST_HOOKS -o $@ qfd_test.c $(CORE)

# The check alone, without the mutations: what a failing mutant runs.
check-only: $(WORK)/qfd_test
	@test -x "$(QFD_GOLDEN)" || { echo "quux-file-device: QFD_GOLDEN names no program; the top-level" \
	    "Makefile builds golden/src/quux_file_device.rs and passes it"; exit 1; }
	python3 qfd_compare.py --golden $(QFD_GOLDEN) --test $(WORK)/qfd_test --work $(WORK)/compare

check: check-only
	python3 mutate.py --list qfd_mutations.txt --work $(WORK)/mutants --golden $(QFD_GOLDEN) \
	    --cc "$(HOSTCC)" --cflags "$(HOSTCFLAGS)" --reference $(WORK)/compare/reference

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check check-only clean
