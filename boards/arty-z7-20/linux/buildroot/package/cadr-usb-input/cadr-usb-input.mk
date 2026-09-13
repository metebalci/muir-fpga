# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The USB keyboard and mouse, one program per package as the rest of them are.
# Buildroot's `local` site method builds straight from the src/ directory
# beside this file --- no tarball, no version, no hash --- and
# `make buildroot-rebuild` at the repository root is what makes Buildroot
# notice a change here.
#
# What is in it:
#
#   cadr-usb-input        reads /dev/input/event* for a keyboard and a mouse
#                         and sends what they say to cadr-terminal over a
#                         local socket, which is the program that writes the
#                         I/O board's registers.  src/cadr-usb-input.c's
#                         header says how, src/usb_keys.h is the one place a
#                         shift level is chosen, and src/usb_keymap.h is the
#                         key table generated from the X keyboard database
#   S88cadr-usb-input     starts it at boot, its log on the console
#
# **IT DEPENDS ON cadr-terminal AND NOT ONLY ON cadr-common.**  Not for a
# header or a library --- it links neither of that package's files --- but
# because the program it sends to must be in the image for this one to have
# anywhere to send.  A board with this and no terminal is a keyboard that
# types into a socket nothing is listening on, and the program would say so
# once a second for ever.
#
# S88, after the terminal's S85: the terminal is what listens on the link, and
# a program started before it spends its first second saying the link is not
# there.  It recovers on its own, so the order is tidiness rather than a
# dependency --- but a console log that reads in the order the machine needs
# things is worth the number.
#
# **AND src/usb_keymap.h IS GENERATED, BY src/usbkeymap_from_xkb.py, WHICH NO
# BUILD RUNS.**  A hundred and more keys transcribed by hand is a table with a
# wrong key in it somewhere, so the generator reads the X keyboard database ---
# the evdev key codes, symbols/pc and symbols/us, and the two keysym headers
# --- and writes them out as C.  It is not a build step because that database
# is on a build host and is not in this repository, which neither Buildroot nor
# CI has: the output is committed, its header names the files it came from, and
# the generator says how to write it again.  The same arrangement as the
# screen's input_keymap.h.
#
# And `make -C src check` on the build host, which needs nothing but a C
# compiler and python3: synthetic evdev events through the whole road --- this
# program, the link, the screen's server, a model of the input face and a model
# of the machine reading a word only so often --- and then every record in
# src/usb_mutations.txt, each of which the check must fail on.

CADR_USB_INPUT_VERSION = 0
CADR_USB_INPUT_SITE = $(BR2_EXTERNAL_CADR_PATH)/package/cadr-usb-input/src
CADR_USB_INPUT_SITE_METHOD = local
CADR_USB_INPUT_LICENSE = AGPL-3.0-or-later
CADR_USB_INPUT_DEPENDENCIES = cadr-common

define CADR_USB_INPUT_BUILD_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) $(TARGET_CONFIGURE_OPTS) -C $(@D)
endef

define CADR_USB_INPUT_INSTALL_TARGET_CMDS
	$(TARGET_MAKE_ENV) $(MAKE) -C $(@D) DESTDIR=$(TARGET_DIR) install
endef

define CADR_USB_INPUT_INSTALL_INIT_SYSV
	$(INSTALL) -D -m 0755 $(CADR_USB_INPUT_PKGDIR)/S88cadr-usb-input \
		$(TARGET_DIR)/etc/init.d/S88cadr-usb-input
endef

$(eval $(generic-package))
