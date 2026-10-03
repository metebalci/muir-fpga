# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory, as cadr-serial's.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS for the ARM and
# DESTDIR for install, and `all` makes the program, for the Kria KR260 alone
# (`CADR_BOARD_KR260`, which the package passes from the board's defconfig).
#
# The host build, `make check`: `dp_link.c` against `dp_test.c`'s model of
# the board's DisplayPort controller, transceiver lane and monitor, on the
# build host, and then every record in displayport_mutations.txt applied to a
# copy of the sources, each of which the check must FAIL on.  Scratch goes
# under ~/.cache, never /tmp.  `make all COMMON=host` compiles the program
# itself here against cadr-common's sources, which is how the host knows it
# builds.

PROGRAMS := cadr-displayport
CORE     := dp_link.c
HEADERS  := dp_link.h amd_dp_tables.h

COMMON      ?= staging
COMMON_DIR  := ../../cadr-common/src
COMMON_SRC  := $(COMMON_DIR)/cadr_log.c $(COMMON_DIR)/cadr_mem.c
ifeq ($(COMMON),host)
COMMON_CFLAGS := -I$(COMMON_DIR) -DCADR_BOARD_KR260
COMMON_LINK   := $(COMMON_SRC)
else
COMMON_CFLAGS :=
COMMON_LINK   := -lcadr-common
endif

HOSTCC ?= cc
HOSTCFLAGS ?= -O2 -Wall -Wextra -std=gnu11
# The path carries the checkout, as cadr-serial's says why.
WORK    ?= $(HOME)/.cache/muir-fpga-displayport-$(shell printf '%s' '$(CURDIR)' | sha256sum | cut -c1-12)

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

cadr-displayport: cadr-displayport.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(LDFLAGS) -o $@ cadr-displayport.c $(CORE) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

check: $(WORK)/dp_test
	$(WORK)/dp_test
	@python3 mutate.py --list displayport_mutations.txt --work $(WORK)/mutants \
	    --cc "$(HOSTCC)" --cflags "$(HOSTCFLAGS)"

check-only: $(WORK)/dp_test
	$(WORK)/dp_test

$(WORK)/dp_test: dp_test.c $(CORE) $(HEADERS)
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -o $@ dp_test.c $(CORE)

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check check-only clean
