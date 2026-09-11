# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The BR2_EXTERNAL tree's make logic: the packages under package/, and two
# hooks that put files where Buildroot's own options cannot.
#
# THE RESERVED-MEMORY NODE IS ONE FILE, boards/arty-z7-20/linux/cadr-reserved.dtsi, and both
# trees include it.  The board's device tree lives at
# board/arty-z7-20/dts/xilinx/zynq-arty-z7-20.dts and is compiled twice ---
# by the kernel, from arch/arm/boot/dts/xilinx/, and by U-Boot, from
# arch/arm/dts/ --- with `#include "cadr-reserved.dtsi"` resolved beside it in
# each.  Buildroot's BR2_TARGET_UBOOT_CUSTOM_DTS_PATH copies a list of files
# into U-Boot's dts directory, so the dtsi is simply listed there; the
# kernel's BR2_LINUX_KERNEL_CUSTOM_DTS_DIR rsyncs a directory tree, which
# would mean a second copy of the dtsi in this tree (rsync -a keeps a symlink
# a symlink, and a relative one breaks on arrival).  So the kernel gets it by
# this hook instead, copied next to the dts before the build.
#
# THE DEFAULT ENVIRONMENT IS A TEXT FILE U-Boot expects at
# board/xilinx/zynq/<CONFIG_ENV_SOURCE_FILE>.env (env/Kconfig, and the
# Makefile's ENV_DIR); nothing in Buildroot places a file there, so the second
# hook does.  Hooks appended here take effect because Buildroot expands
# $(PKG)_PRE_BUILD_HOOKS inside the recipe (package/pkg-generic.mk), after
# this file has been included.

include $(sort $(wildcard $(BR2_EXTERNAL_CADR_PATH)/package/*/*.mk))

CADR_BOARD_DIR = $(BR2_EXTERNAL_CADR_PATH)/board/arty-z7-20
CADR_RESERVED_DTSI = $(BR2_EXTERNAL_CADR_PATH)/../cadr-reserved.dtsi

define CADR_LINUX_COPY_RESERVED_DTSI
	mkdir -p $(LINUX_ARCH_PATH)/boot/dts/xilinx
	cp -f $(CADR_RESERVED_DTSI) $(LINUX_ARCH_PATH)/boot/dts/xilinx/
endef
LINUX_PRE_BUILD_HOOKS += CADR_LINUX_COPY_RESERVED_DTSI

define CADR_UBOOT_COPY_ENV
	cp -f $(CADR_BOARD_DIR)/uboot/cadr.env $(@D)/board/xilinx/zynq/
endef
UBOOT_PRE_BUILD_HOOKS += CADR_UBOOT_COPY_ENV
