#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# THE KRIA KR260's IMAGE CARRIES NO LOADABLE KERNEL MODULES, for the
# DE25-Nano's reasons (boards/de25-nano/linux/buildroot/board/de25-nano/
# post-build.sh says them at length).  Mainline's arm64 `defconfig` builds
# several hundred drivers as modules, for every arm64 board the kernel knows,
# and the root filesystem is an initramfs unpacked into RAM at every boot.
# Every driver this board's programs need is built in: `linux/linux.fragment`
# names them, and `make buildroot-kr260` asserts every line of it against the
# kernel's own .config, so a driver the board needs cannot quietly be a
# module that this script throws away.
#
# **AND THE SECOND REASON**: the FPGA manager is a module in that
# configuration (CONFIG_FPGA_MGR_ZYNQMP_FPGA is `m`).  U-Boot configures the
# fabric before Linux starts, and Linux must not configure it again.  With no
# modules on the image the manager cannot be loaded.
#
# Run by Buildroot after the Arty Z7-20's post-build.sh (BR2_ROOTFS_POST_BUILD_
# SCRIPT in configs/kria_kr260_defconfig), during target-finalize and BEFORE
# the root filesystem is written, with the target directory as $1.

set -eu

TARGET=${1:?post-build.sh: no target directory}

if [ -d "$TARGET/lib/modules" ]; then
	n=$(find "$TARGET/lib/modules" -name '*.ko*' | wc -l)
	rm -rf "$TARGET/lib/modules"
	echo "the Kria KR260's image: $n loadable module(s) removed; every driver the board needs is built in"
else
	echo "the Kria KR260's image: no /lib/modules to remove"
fi
