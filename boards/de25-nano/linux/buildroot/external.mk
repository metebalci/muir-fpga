# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's BR2_EXTERNAL tree: no packages, and the hooks that put this
# board's files where Buildroot's own options cannot.
#
# NO `include $(wildcard .../package/*/*.mk)` HERE, for the Cora Z7-07S's
# reason: the packages are the Arty Z7-20's tree's, that tree includes them,
# and this build is given both trees.
#
# THE RESERVED-MEMORY NODE IS THIS BOARD'S OWN FILE, boards/de25-nano/linux/
# cadr-reserved.dtsi, and not the Zynq boards' one.  The machine's 128 MB is
# the same size on every board and laid out the same way inside, but where it
# starts is the board's: 0x1800_0000 at the top of a Zynq board's 512 MB, and
# 0xB000_0000 here, below the top of 1 GB, because U-Boot on this part
# relocates to the very top of memory without regard to a reserved-memory
# node.  The file says so at length.  The kernel gets it by the first hook,
# copied beside our tree in arch/arm64/boot/dts/intel/, for the reason the
# Zynq trees' external.mk gives (BR2_LINUX_KERNEL_CUSTOM_DTS_DIR rsyncs a
# directory, and a relative symlink breaks on arrival); U-Boot gets it by
# being listed in BR2_TARGET_UBOOT_CUSTOM_DTS_PATH.
#
# THE DEFAULT ENVIRONMENT IS A TEXT FILE U-Boot expects at
# board/<vendor>/<board>/<CONFIG_ENV_SOURCE_FILE>.env (env/Kconfig).  Altera's
# DE25-Nano configuration builds the Agilex 5 development kit's board code
# (TARGET_SOCFPGA_AGILEX5_SOCDK, whose SYS_VENDOR and SYS_BOARD are `intel`
# and `agilex5-socdk` in arch/arm/mach-socfpga/Kconfig), so the file goes in
# board/intel/agilex5-socdk/.
#
# **THE HOOKS HAVE NAMES OF THEIR OWN, CADR_DE25_*, AND SO DOES THE
# ENVIRONMENT FILE**, for the reason the Cora Z7-07S's external.mk gives: every
# tree's external.mk is included into one make, so the Arty Z7-20's hooks run
# on this build too.  They are harmless here --- they copy the Zynq boards'
# reservation into arch/arm64/boot/dts/xilinx/, which our tree does not
# include, and the Zynq boards' environment into board/xilinx/zynq/, which this
# U-Boot does not build --- and a hook of ours under their name would replace
# theirs on THEIR builds.
#
# **AND THE KERNEL'S LOADABLE MODULES ARE BUILT AND NOT SHIPPED.**  Altera's
# arm64 `defconfig` builds some nine hundred drivers as modules, and
# Buildroot installs every one into the root filesystem, which is a RAM disk
# unpacked at every boot.  Nothing on this board loads a module: every driver
# the CADR's programs need is built in (linux/linux.fragment names them, and
# `make buildroot-de25` asserts every line of that fragment against the
# kernel's own .config).  So board/de25-nano/post-build.sh removes
# /lib/modules before the image is written.  Building them is the cost of
# keeping Altera's configuration as Altera ships it rather than guessing a
# smaller one.

CADR_DE25_BOARD_DIR = $(BR2_EXTERNAL_CADR_DE25_PATH)/board/de25-nano
CADR_DE25_RESERVED_DTSI = $(BR2_EXTERNAL_CADR_DE25_PATH)/../cadr-reserved.dtsi

define CADR_DE25_LINUX_COPY_RESERVED_DTSI
	mkdir -p $(LINUX_ARCH_PATH)/boot/dts/intel
	cp -f $(CADR_DE25_RESERVED_DTSI) $(LINUX_ARCH_PATH)/boot/dts/intel/
endef
LINUX_PRE_BUILD_HOOKS += CADR_DE25_LINUX_COPY_RESERVED_DTSI

define CADR_DE25_UBOOT_COPY_ENV
	cp -f $(CADR_DE25_BOARD_DIR)/uboot/cadr_de25.env $(@D)/board/intel/agilex5-socdk/
endef
UBOOT_PRE_BUILD_HOOKS += CADR_DE25_UBOOT_COPY_ENV
