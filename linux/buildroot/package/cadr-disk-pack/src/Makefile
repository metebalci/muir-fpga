# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS for the ARM and
# DESTDIR for install, and `all` makes the programs that go on the board.
#
# The host build, `make check`: the disk pack program's core linked against a model
# of the register face, with a scripted disk controller behind it posting
# the requests the reference trace's transfers would and more, on the build
# host --- no board, no fabric, nothing but a C compiler and build/disk.golden
# (`make disk-golden` at the repository root writes it).  Scratch goes under
# ~/.cache, never /tmp, which is a RAM disk on the build host.

PROGRAMS := cadr-disk-pack
CORE     := pack_file.c pack_side.c pack_feeder.c
HEADERS  := pack_ecc.h pack_file.h pack_side.h pack_feeder.h

HOSTCC ?= cc
HOSTCFLAGS ?= -O2 -Wall -Wextra -std=gnu11
GOLDEN ?= $(abspath ../../../../../build/disk.golden)
WORK   ?= $(HOME)/.cache/muir-fpga-disk-pack

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

cadr-disk-pack: cadr-disk-pack.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ cadr-disk-pack.c $(CORE)

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

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check clean
