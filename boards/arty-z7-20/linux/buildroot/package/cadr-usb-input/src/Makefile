# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS for the ARM and
# DESTDIR for install, and `all` makes the program that goes on the board.
# It is this package and cadr-common and nothing else --- the program reads a
# device node and writes a socket.
#
# The host check, `make check`: a USB keyboard and mouse made out of socket
# pairs, the real link over a real Unix socket, the screen's own server at the
# far end, a model of the input face behind its two function pointers and a
# model of the machine reading a word only so often.  No board, no fabric and
# no keyboard.  Then every record in usb_mutations.txt applied to a copy of the
# sources, each of which the check must FAIL on; a mutation that survives is
# reported and the run is red.  Scratch goes under ~/.cache, never /tmp, which
# is a RAM disk on the build host.
#
# **TWO SOURCE LISTS FOR THE SHARED CODE, AND WHICH IS FOR WHICH BUILD.**
# /dev/mem, the logging and the input link are cadr-common's.  Buildroot's
# `local` site method rsyncs only THIS directory into the build tree, so the
# sibling package's files are not there at target-build time and a relative
# include of them would build here and fail under Buildroot.  So the target
# build links the static library cadr-common installs to staging ---
# $(TARGET_CONFIGURE_OPTS) carries --sysroot, so neither -I nor -L is needed
# --- and the host build compiles the same .c files from `..`, which is a real
# directory here.  `make all COMMON=host` builds the program itself that way,
# which is how it is compiled here without Buildroot.
#
# **AND THE CHECK REACHES INTO THE SCREEN'S PACKAGE, WHICH THE PROGRAM DOES
# NOT.**  What is being checked is the whole road from a key code to a word at
# the machine, and the far half of it --- muir's key mapping, the queue, the
# pacer, the register face --- is cadr-terminal's.  A check that stopped at the
# socket would assert what this program sends and nothing about what the
# machine is given.  So TERMINAL_SRC is compiled into the check and into
# nothing else: `cadr-usb-input` itself links none of it, and Buildroot never
# sees these paths.
#
# **usb_keymap.h IS GENERATED AND NO BUILD RUNS THE GENERATOR.**
# `usbkeymap_from_xkb.py` reads the X keyboard database on the build host and
# writes out what keysym each key code produces.  It is not a build step
# because that database is not in this repository and neither Buildroot nor CI
# has it: the output is committed, its header names the files it came from, and
# that file says how to write it again.  The same arrangement as the screen's
# `input_keymap.h`, and for the same reason --- a table of this size typed out
# by hand has a wrong key in it somewhere.

PROGRAMS := cadr-usb-input
CORE     := usb_keys.c usb_devices.c
HEADERS  := usb_keys.h usb_devices.h usb_keymap.h

COMMON      ?= staging
COMMON_DIR  := ../../cadr-common/src
COMMON_SRC  := $(COMMON_DIR)/cadr_log.c $(COMMON_DIR)/cadr_mem.c \
               $(COMMON_DIR)/cadr_input_link.c
ifeq ($(COMMON),host)
COMMON_CFLAGS := -I$(COMMON_DIR)
COMMON_LINK   := $(COMMON_SRC)
else
COMMON_CFLAGS :=
COMMON_LINK   := -lcadr-common
endif

# The check's other half.  Never in the target build.
TERMINAL_DIR := ../../cadr-terminal/src
TERMINAL_SRC := $(TERMINAL_DIR)/input_face.c $(TERMINAL_DIR)/input_keys.c \
                $(TERMINAL_DIR)/input_mapping.c $(TERMINAL_DIR)/screen_server.c \
                $(TERMINAL_DIR)/screen_frame.c $(TERMINAL_DIR)/screen_rfb.c

HOSTCC ?= cc
HOSTCFLAGS ?= -O2 -Wall -Wextra -std=gnu11
# **THE PATH CARRIES THE CHECKOUT, because this tree is worked in several at
# once.**  A fixed `~/.cache/<name>` is shared by the main checkout and every
# `git worktree`, so two of them building at the same time overwrite each
# other's test binary --- and `make` then sees a binary newer than its sources
# and does not rebuild.  The stale-artifact scar, met in the serial line's own
# Makefile first.
WORK ?= $(HOME)/.cache/muir-fpga-usb-input-$(shell printf '%s' '$(CURDIR)' | sha256sum | cut -c1-12)

CFLAGS += -Wall -Wextra -std=gnu11

all: $(PROGRAMS)

cadr-usb-input: cadr-usb-input.c $(CORE) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(LDFLAGS) -o $@ cadr-usb-input.c $(CORE) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

# The check.  Its own object directory, so a target build and a host build
# never share a binary --- and a build artifact that outlived a machine move
# would name a home directory that no longer exists.
check: $(WORK)/usb_test
	$(WORK)/usb_test --work $(WORK)
	@python3 mutate.py --list usb_mutations.txt --work $(WORK)/mutants \
	    --cc "$(HOSTCC)" --cflags "$(HOSTCFLAGS)"

# The check alone, without the mutations: what a failing mutant runs.
check-only: $(WORK)/usb_test
	$(WORK)/usb_test --work $(WORK)

$(WORK)/usb_test: usb_test.c $(CORE) $(HEADERS) $(COMMON_SRC) $(TERMINAL_SRC)
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -I$(COMMON_DIR) -I$(TERMINAL_DIR) -o $@ usb_test.c \
	    $(CORE) $(TERMINAL_SRC) $(COMMON_SRC)

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check check-only clean
