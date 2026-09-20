# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The shared transport code, as a static library.
#
# The target build is the only build of THIS directory: Buildroot passes CC,
# CFLAGS and AR for the ARM, `all` makes libcadr-common.a and
# `install-staging` puts it and the headers in the staging tree, where
# --sysroot finds them.  Nothing is installed on the target: a static library
# has nothing to ship.
#
# The consumers' HOST builds do not come through here.  There `..` is a real
# directory and a consumer compiles SOURCES straight from it --- see the two
# source lists in each consumer's src/Makefile.  Nothing in this file is used
# on the host, so nothing here may assume the ARM either.
#
# **AND ONE FILE DOES GO ON THE TARGET**: fpgarc.sh, the shell reader every
# init script hands the card's `fpgarc` to.  It is not C, it is not linked
# into anything, and it is read at boot by scripts from five packages, so it
# is installed rather than staged.  Its own header is the contract.

LIB     := libcadr-common.a
SOURCES := cadr_log.c cadr_mem.c cadr_input_link.c cadr_endpoint.c
HEADERS := cadr/cadr_log.h cadr/cadr_mem.h cadr/cadr_input_link.h \
           cadr/cadr_endpoint.h cadr/cadr_board.h
OBJECTS := $(SOURCES:.c=.o)

AR ?= ar
CFLAGS += -Wall -Wextra -std=gnu11 -I.

# **WHICH BOARD'S ADDRESS MAP, AND HOW EVERY PROGRAM GETS IT.**  Named once,
# by the board's defconfig (package/cadr-common/Config.in), and handed here
# by cadr-common.mk as CADR_BOARD.  The library is compiled for it --- the
# guard in cadr_mem.c reads the board's tally --- and the copy of
# cadr/cadr_board.h that `install-staging` puts in the staging tree BEGINS
# with the board's define, so every program that includes it from there is
# built for the same board with no flag of its own and no way to be built for
# another.  A name this file does not know stops the build.  The default is
# the Zynq-7000 boards', which is what a build that says nothing always was.
CADR_BOARD ?= zynq-7000
BOARD_DEFINE_zynq-7000 := CADR_BOARD_ZYNQ7000
BOARD_DEFINE_de25-nano := CADR_BOARD_DE25_NANO
BOARD_DEFINE := $(BOARD_DEFINE_$(CADR_BOARD))
ifeq ($(BOARD_DEFINE),)
$(error CADR_BOARD=$(CADR_BOARD) names no board cadr/cadr_board.h has a map for)
endif
# `override`, because Buildroot hands CFLAGS on the command line
# ($(TARGET_CONFIGURE_OPTS)), and GNU make lets a command-line variable win
# over every assignment in the file, `+=` included --- the `CFLAGS +=` above is
# dropped under Buildroot for exactly that reason.  Dropped here, the library
# would be built for the Zynq boards under a header that says otherwise, and
# every program would guard the wrong block.
override CFLAGS += -D$(BOARD_DEFINE)

all: $(LIB)

$(LIB): $(OBJECTS)
	$(AR) rcs $@ $(OBJECTS)

$(OBJECTS): $(HEADERS)

# Staging only.  The headers keep their cadr/ directory, so a consumer writes
# `#include <cadr/cadr_mem.h>` in both of its builds and the two differ only
# in where the directory is.
install-staging: all
	install -d $(DESTDIR)/usr/lib $(DESTDIR)/usr/include/cadr
	install -m 0644 $(LIB) $(DESTDIR)/usr/lib/
	install -m 0644 $(filter-out cadr/cadr_board.h,$(HEADERS)) $(DESTDIR)/usr/include/cadr/
	{ printf '#define %s 1\n' $(BOARD_DEFINE); cat cadr/cadr_board.h; } \
	    > $(DESTDIR)/usr/include/cadr/cadr_board.h
	chmod 0644 $(DESTDIR)/usr/include/cadr/cadr_board.h

# The target.  Three files, all of them shell that the init scripts source and
# none of them with a build step --- they are read, not compiled --- so `all`
# says nothing about them and this is the whole of their shipping.  `fpgarc.sh`
# decides what a program is given out of the card's one file of flags;
# `daemon.sh` starts it so that a program which will not take what it was given
# says so on the console instead of dying behind an OK; `clock.sh` is what this
# board knows about the date, there being no real-time clock in it.
SHAREDIR := /usr/share/cadr

install:
	install -d $(DESTDIR)$(SHAREDIR)
	install -m 0644 fpgarc.sh $(DESTDIR)$(SHAREDIR)/fpgarc.sh
	install -m 0644 daemon.sh $(DESTDIR)$(SHAREDIR)/daemon.sh
	install -m 0644 clock.sh $(DESTDIR)$(SHAREDIR)/clock.sh

# The reader's own check, on the build host, needing nothing but a POSIX
# shell: one `fpgarc` handed to five init scripts, each getting its own flags
# and no others, the boot button's step under a stubbed console, and the
# clock's arithmetic against the wrong dates as well as the right ones.
check:
	./fpgarc_test.sh

clean:
	rm -f $(LIB) $(OBJECTS)

.PHONY: all install install-staging check clean
