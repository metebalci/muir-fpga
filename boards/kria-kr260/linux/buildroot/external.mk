# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The Kria KR260's BR2_EXTERNAL tree: no packages and no hooks.
#
# NO `include $(wildcard .../package/*/*.mk)` HERE, for the Cora Z7-07S's
# reason: the packages are the Arty Z7-20's tree's, that tree includes them,
# and this build is given both trees.
#
# AND NO HOOK, which is where this board differs from the other three.  They
# build a U-Boot of their own, whose tree must carry the machine's reservation,
# and their hooks put that reservation into the kernel's and U-Boot's source
# trees.  This board boots from the factory U-Boot in its QSPI flash, which is
# never rebuilt or written, and the kernel's tree is mainline's own KR260 tree
# with the CADR's additions applied as an overlay after the kernel is built
# (board/kria-kr260/post-image.sh), so nothing has to reach a source tree.
#
# The Arty Z7-20's hooks run on this build too, because every tree's
# external.mk is included into one make.  They are harmless here: they copy
# the Zynq boards' reservation into arch/arm64/boot/dts/xilinx/, which no tree
# this build compiles includes, and the Zynq boards' U-Boot environment into a
# U-Boot this build does not have.
