#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# THE DE25-Nano's IMAGE CARRIES NO LOADABLE KERNEL MODULES.
#
# Altera's arm64 `defconfig` builds some nine hundred drivers as modules, for
# every board Altera's kernel knows, and Buildroot installs all of them under
# /lib/modules.  The root filesystem is an initramfs, unpacked into RAM at
# every boot, so those modules would cost memory the board runs in and a
# larger file on the card and on the TFTP server --- and nothing here loads
# one.  Every driver this board's programs need is built into the kernel:
# `linux/linux.fragment` names them, and `make buildroot-de25` asserts every
# line of that fragment against the kernel's own .config, so a driver the
# board needs cannot quietly be a module that this script then throws away.
#
# **A SECOND REASON, AND IT IS WHY THIS IS NOT ONLY ABOUT SIZE.**  The FPGA
# manager, the bridges and the region are modules in that configuration
# (CONFIG_FPGA_BRIDGE, CONFIG_FPGA_REGION and CONFIG_FPGA_MGR_STRATIX10_SOC are
# `m`).  U-Boot configures the fabric and opens the bridges before Linux
# starts, and Linux must not touch either: a bridge driver that probed would
# own a bridge the machine is using.  With no modules on the image none of
# them can be loaded.
#
# Run by Buildroot after the Arty Z7-20's post-build.sh (BR2_ROOTFS_POST_BUILD_
# SCRIPT in configs/de25_nano_defconfig), during target-finalize and BEFORE
# the root filesystem is written, with the target directory as $1.

set -eu

TARGET=${1:?post-build.sh: no target directory}

if [ -d "$TARGET/lib/modules" ]; then
	n=$(find "$TARGET/lib/modules" -name '*.ko*' | wc -l)
	rm -rf "$TARGET/lib/modules"
	echo "the DE25-Nano's image: $n loadable module(s) removed; every driver the board needs is built in"
else
	echo "the DE25-Nano's image: no /lib/modules to remove"
fi
