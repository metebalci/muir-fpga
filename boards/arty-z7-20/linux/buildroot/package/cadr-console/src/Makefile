# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Two builds from one directory.
#
# The target build: Buildroot passes CC, CFLAGS and LDFLAGS for the ARM and
# DESTDIR for install, and `all` makes the program that goes on the board.
#
# The host build, `make check`: the console program's core linked against a
# model of the slave, with a modeled machine behind the diagnostic bus, on
# the build host --- no board, no fabric, nothing but a C compiler.  Scratch
# goes under ~/.cache, never /tmp, which is a RAM disk on the build host.
#
# **TWO SOURCE LISTS FOR THE SHARED CODE, AND WHICH IS FOR WHICH BUILD.**
# /dev/mem, the EMIO tally guard and the logging are cadr-common's.
# Buildroot's `local` site method rsyncs only THIS directory into the build
# tree, so the sibling package's files are not there at target-build time and
# a relative include of them would build here and fail under Buildroot.  So:
#
#   the target build (`all`)   -lcadr-common, the static library cadr-common
#                              installs into the staging tree.
#                              $(TARGET_CONFIGURE_OPTS) carries --sysroot, so
#                              neither -I nor -L is needed
#   the host build (`check`)   the same .c files compiled straight from
#                              $(COMMON_DIR), where `..` is a real directory
#
# `make all COMMON=host` builds the program itself the host way, which is how
# it is compiled here without Buildroot.

PROGRAMS := cadr-console
# **TWO SOURCE FILES AND THE LINE BETWEEN THEM IS LOAD-BEARING.**  `CORE` is
# the register face, and the top-level Makefile compiles that same file for
# the Arty A7-100's bare-metal firmware, where there is no operating system.
# `HOST` is what needs one --- a pid file read, a signal sent --- and only the
# two builds here compile it.  Putting a host-only word in `CORE` does not
# merely waste space on the firmware: it stops the firmware LINKING, which is
# what happened when `trace-keys` first landed, and what `make build/soc.pass`
# is the check for.  `console_host.h` has the whole argument.
CORE     := console_face.c
HOST     := console_host.c
HEADERS  := console_face.h console_host.h

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
# **AND IT IS KEYED BY THE CHECKOUT, BECAUSE TWO OF THEM SHARE THIS HOME.**
# The path was `~/.cache/muir-fpga-console` for every tree at once, so a
# worktree whose sources were older than the last build done in another one
# found the binary up to date and RAN THE OTHER TREE'S CHECK --- measured:
# `make check` here printed a count from a console_test.c this directory does
# not have.  A check that can report on somebody else's sources is the stale
# artifact this project keeps meeting, and the cure is the one
# `cadr-terminal` and `cadr-chaosnet` already use: the directory's own path,
# hashed.
WORK   ?= $(HOME)/.cache/muir-fpga-console-$(shell printf '%s' '$(CURDIR)' | sha256sum | cut -c1-12)

CFLAGS += -Wall -Wextra -std=gnu11

# --- WHICH BUILD THE PROGRAM IS, which is a different question from which
# --- build the FABRIC is
#
# `cadr-console --version` names the commit this program was compiled from,
# in muir's own spelling: `muir 0.1.0-<commit>-release`, the commit dropped
# when there is none.  muir's build.rs asks git and stamps the answer in
# through the compile-time environment; this does the same with a `-D`.
#
# **BUILDROOT'S BUILD IS NOT IN A GIT TREE**, because the `local` site method
# rsyncs this directory into `output/build` and compiles there, so a `git`
# here would answer nothing under Buildroot and the truth would be lost
# exactly where it matters.  `cadr-console.mk` therefore passes `BUILD_GIT`
# from the repository, and this default is for the host build, which does run
# in the tree.  Unset in both, the program says what muir says with no
# `MUIR_GIT`: the version and the build kind and no commit, which is true.
#
# **AND THE STAMP IS TAKEN WHEN THE PACKAGE IS BUILT AND NOT WHEN THE IMAGE
# IS**, so a Buildroot output directory carried across a commit that changed
# no source of this package keeps the older number.  `make buildroot-rebuild`
# is what forces it, which is what the image procedure already does; a
# program that claimed otherwise would be the stale-artifact failure in its
# own version string.
BUILD_GIT ?= $(shell git rev-parse --short=7 HEAD 2>/dev/null)$(shell \
	git status --porcelain 2>/dev/null | head -c 1 | sed 's/.\+/-dirty/')
PKG_VERSION ?= 0
VERSION_CFLAGS := -DCADR_PKG_VERSION='"$(PKG_VERSION)"'
ifneq ($(BUILD_GIT),)
VERSION_CFLAGS += -DCADR_BUILD_GIT='"$(BUILD_GIT)"'
endif

all: $(PROGRAMS)

cadr-console: cadr-console.c $(CORE) $(HOST) $(HEADERS)
	$(CC) $(CFLAGS) $(COMMON_CFLAGS) $(VERSION_CFLAGS) $(LDFLAGS) -o $@ cadr-console.c $(CORE) $(HOST) $(COMMON_LINK)

install: all
	install -d $(DESTDIR)/usr/bin
	install -m 0755 $(PROGRAMS) $(DESTDIR)/usr/bin/

# The check, and the mutations that say it can fail.  Its own object
# directory, so a target build and a host build never share a binary --- and a
# build artifact that outlived a move would name a home directory that no
# longer exists.
#
# **THE MUTATIONS REACH `cadr-common/src/cadr_log.c` AS WELL AS THIS
# DIRECTORY**, because this check builds it: the logging is shared by all six
# programs and the package it lives in has a shell check and no C one.
# `serial_mutations.txt` already aims at the endpoint grammar the same way.
check: $(WORK)/console_test
	$(WORK)/console_test
	@python3 mutate.py --list console_mutations.txt --work $(WORK)/mutants \
	    --cc "$(HOSTCC)" --cflags "$(HOSTCFLAGS)"

# The check alone, without the mutations: what a failing mutant runs.
check-only: $(WORK)/console_test
	$(WORK)/console_test

$(WORK)/console_test: console_test.c $(CORE) $(HOST) $(HEADERS) $(COMMON_SRC)
	@mkdir -p $(WORK)
	$(HOSTCC) $(HOSTCFLAGS) -I$(COMMON_DIR) -o $@ console_test.c $(CORE) $(HOST) $(COMMON_SRC)

clean:
	rm -f $(PROGRAMS)

.PHONY: all install check check-only clean
