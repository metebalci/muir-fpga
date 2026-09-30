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
CADR_QUUX13_RESERVED_DTSI = $(BR2_EXTERNAL_CADR_PATH)/../quux13-reserved.dtsi

# **AND QUUX REVISION 13's RESERVATION, beside it**, which revision 13's own
# tree, zynq-arty-z7-20-quux13.dts, includes after the CADR's: the kernel
# builds both trees, as every .dts in the board's dts/ is built, and a card or
# a served set carries the one that goes with its bitstream (docs/linux.md).
define CADR_LINUX_COPY_RESERVED_DTSI
	mkdir -p $(LINUX_ARCH_PATH)/boot/dts/xilinx
	cp -f $(CADR_RESERVED_DTSI) $(CADR_QUUX13_RESERVED_DTSI) $(LINUX_ARCH_PATH)/boot/dts/xilinx/
endef
LINUX_PRE_BUILD_HOOKS += CADR_LINUX_COPY_RESERVED_DTSI

# **REVISION 13's u-boot.img, beside the board's**: U-Boot's own tree carries
# the machine's reservation, so a revision 13 card carries a loader of its
# own, the build's U-Boot with revision 13's tree (`../quux13-loader.sh`, which
# says how, and refuses a recipe that does not reproduce the build's own
# u-boot.img).  The Arty Z7-20's alone: the Cora Z7-07S cannot build QUUX,
# and this file's hooks run on every board's build.
ifeq ($(call qstrip,$(BR2_TARGET_UBOOT_CUSTOM_MAKEOPTS)),DEVICE_TREE=zynq-arty-z7-20)
define CADR_UBOOT_QUUX13_LOADER
	$(TARGET_MAKE_ENV) $(BR2_EXTERNAL_CADR_PATH)/../quux13-loader.sh $(@D) arty-z7-20
endef
UBOOT_POST_BUILD_HOOKS += CADR_UBOOT_QUUX13_LOADER
define CADR_UBOOT_INSTALL_QUUX13_LOADER
	cp -f $(@D)/u-boot-quux13.img $(BINARIES_DIR)/
endef
UBOOT_POST_INSTALL_IMAGES_HOOKS += CADR_UBOOT_INSTALL_QUUX13_LOADER
endif

define CADR_UBOOT_COPY_ENV
	cp -f $(CADR_BOARD_DIR)/uboot/cadr.env $(@D)/board/xilinx/zynq/
endef
UBOOT_PRE_BUILD_HOOKS += CADR_UBOOT_COPY_ENV
