# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory, as every package here has.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS and DESTDIR, and
# `all` makes the programs that go on the board, linking cadr-common's static
# library from staging (`make all COMMON=host` compiles its sources from `..`
# instead, which is how it is built here without Buildroot).
#
# The host build, `make check`, which needs muir: the program's step, face
# and section 2.4 over a model of the Ethernet device's page, run through
# scripts that muir's own device runs too (`golden/src/quux_ethernet_device.rs`,
# built by the top-level Makefile and named here as QED_GOLDEN), with the
# transcripts held to each other byte for byte; the flags' answers held to
# muir's; the checksum vectors from the pinned muir (QED_VECTORS); the unit
# checks; then every record in qed_mutations.txt, each of which the check
# must FAIL on.  The check is built with the address and undefined-behavior
# sanitizers, so a read past a frame's end is a failure and not a guess.
# Scratch goes under ~/.cache, never /tmp, which is a RAM disk on the build
# host.

PROGRAMS := quux-ethernet-device
CORE     := qed_offload.c qed_host.c qed_mem.c qed_ring.c qed_face_fabric.c qed_tap.c
HEADERS  := qed_offload.h qed_host.h qed_mem.h qed_ring.h qed_face.h qed_tap.h

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
HOSTCFLAGS ?= -O1 -g -Wall -Wextra -std=gnu11 -fsanitize=address,undefined -fno-sanitize-recover=all
# The path carries the checkout, because this tree is worked in several at
# once (cadr-terminal's Makefile says why).
WORK ?= $(HOME)/.cache/muir-fpga-qed-$(shell printf '%s' '$(CURDIR)' | sha256sum | cut -c1-12)
QED_GOLDEN ?=
QED_VECTORS ?=

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

quux-ethernet-device: quux-ethernet-device.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(LDFLAGS) -o $@ quux-ethernet-device.c $(CORE) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

$(WORK)/qed_test: qed_test.c $(CORE) $(HEADERS)
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -DQED_TEST_HOOKS -o $@ qed_test.c $(CORE)

# The check alone, without the mutations: what a failing mutant runs.
check-only: $(WORK)/qed_test
	@test -x "$(QED_GOLDEN)" || { echo "quux-ethernet-device: QED_GOLDEN names no program; the top-level" \
	    "Makefile builds golden/src/quux_ethernet_device.rs and passes it"; exit 1; }
	@test -f "$(QED_VECTORS)" || { echo "quux-ethernet-device: QED_VECTORS names no file; the top-level" \
	    "Makefile passes the pinned muir's tests/ethernet_vectors.txt"; exit 1; }
	python3 qed_compare.py --golden $(QED_GOLDEN) --test $(WORK)/qed_test --vectors $(QED_VECTORS) \
	    --flags qed_flags.txt --work $(WORK)/compare --reference $(WORK)/compare/reference

check: check-only
	python3 mutate.py --list qed_mutations.txt --work $(WORK)/mutants --golden $(QED_GOLDEN) \
	    --vectors $(QED_VECTORS) --cc "$(HOSTCC)" --cflags "$(HOSTCFLAGS)" \
	    --reference $(WORK)/compare/reference

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check check-only clean
