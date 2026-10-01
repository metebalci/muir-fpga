# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The Kria KR260 beside the CADR: the script the factory U-Boot runs from the
# card.  post-image.sh makes boot.scr of it with mkimage, and boot.scr is the
# one file at the root of the card that the loader asks for by name.
#
# THE LOADER IS NOT OURS.  The QSPI flash holds the boot firmware AMD ships
# with the board, U-Boot 2023.01 included, and nothing here writes the flash
# or the environment of that U-Boot: no saveenv, no sf.  Its distro boot
# scans the USB disks first, the card being one of them, and runs boot.scr
# from the first FAT partition that has one.  Every setenv below lasts for
# this boot only.
#
# WHAT IT DOES, the Arty Z7-20 environment (cadr.env) in a script:
#
#     serverip set     the network path: dhcp, fetch kria-kr260/uEnv.net,
#                      run its netcmd
#     serverip unset   the card path: the tree, Image and the root
#                      filesystem from kria-kr260/ on the card, then
#                      cadr.bit, then booti
#
# The card uEnv.txt decides, by whether it names a server.  Both paths end
# in cadr_booti, and both load the fabric LAST, just before booti: a loaded
# bitstream starts the machine at once, and the factory U-Boot knows nothing
# of the region the machine uses, so the time U-Boot runs beside a live
# machine is kept to the one command that starts the kernel.  If cadr.bit
# will not load, fault.bit beside it is loaded instead, as on every board.
#
# THE BOARD NEVER BOOTS ANYTHING ELSE.  cadr_boot loops: one attempt, and on
# any failure a message, ten seconds, and another, for ever.  It never
# returns to the distro scan, whose next targets are PXE and DHCP, which
# load whatever a network offers.
#
# ADDRESSES.  Everything below 0x5A00_0000, where QUUX revision 13 region
# begins (the CADR region is 0x6000_0000 to 0x67FF_FFFF), and clear of the
# two 256 KB regions the SOM tree reserves for the real-time cores at
# 0x3ED0_0000 and 0x3EF0_0000.  fdt_high and initrd_high are set so that
# booti leaves the tree and the ramdisk where they were loaded instead of
# placing them itself.  The loader own script address, 0x2000_0000, is where
# this script runs from, and nothing is loaded over it.
#
#     cadr_uenv_addr     0x21000000   uEnv.txt, then uEnv.net
#     cadr_kernel_addr   0x18000000   Image
#     cadr_ramdisk_addr  0x30000000   rootfs.cpio.uboot
#     cadr_fdt_addr      0x40000000   the tree
#     cadr_bit_addr      0x44000000   cadr.bit or fault.bit
#
# THIS FILE IS RUN BY U-BOOT HUSH, so its comments carry no quote marks of
# any kind and each setenv is one line.

setenv cadr_uenv_addr 0x21000000
setenv cadr_kernel_addr 0x18000000
setenv cadr_ramdisk_addr 0x30000000
setenv cadr_fdt_addr 0x40000000
setenv cadr_bit_addr 0x44000000
setenv fdt_high 0xffffffffffffffff
setenv initrd_high 0xffffffffffffffff
setenv cadr_bootargs 'console=ttyPS1,115200 earlycon'

# The network port is GEM1, the J10C jack.  GEM0, which the factory
# environment makes the active port, is not connected here, and every network
# command would first wait out its auto-negotiation.
setenv ethact ethernet@ff0c0000

# The device this script came from, which the distro scan names.  Run by hand
# from the prompt, it is whatever the last scan left behind, or the first USB
# disk when no scan has run.
if test -n "${devtype}"; then setenv cadr_devtype ${devtype}; setenv cadr_devpart ${devnum}:${distro_bootpart}; else usb start; setenv cadr_devtype usb; setenv cadr_devpart 0:1; fi

# The card uEnv.txt, if there is one; its absence is not a failure.
setenv cadr_uenv 'if load ${cadr_devtype} ${cadr_devpart} ${cadr_uenv_addr} uEnv.txt; then env import -t ${cadr_uenv_addr} ${filesize}; else echo "cadr: no uEnv.txt on the card; booting from the card"; fi'

# The last step of both paths: the tree, the kernel and the root filesystem
# are in memory, and the CADR is in the fabric.
setenv cadr_booti 'setenv bootargs ${cadr_bootargs} && booti ${cadr_kernel_addr} ${cadr_ramdisk_addr} ${cadr_fdt_addr}'

# The fabric, and the fault bitstream when the CADR bitstream cannot be
# loaded.  If fault.bit cannot be loaded either, this fails, and cadr_boot
# tries again in ten seconds.
setenv cadr_fabric_card 'if load ${cadr_devtype} ${cadr_devpart} ${cadr_bit_addr} kria-kr260/cadr.bit && fpga loadb 0 ${cadr_bit_addr} ${filesize}; then echo "cadr: the CADR bitstream is loaded"; else run cadr_fault_card; fi'
setenv cadr_fault_card 'echo "cadr: THE CADR BITSTREAM DID NOT LOAD; loading the fault bitstream, whose lamps blink together"; load ${cadr_devtype} ${cadr_devpart} ${cadr_bit_addr} kria-kr260/fault.bit && fpga loadb 0 ${cadr_bit_addr} ${filesize}'

# The card path.  The board files are in the folder on the card named as its
# directory under boards/ is, the same name and the same files the TFTP
# server directory has.  Each load names its file when it fails.
setenv cadr_card 'load ${cadr_devtype} ${cadr_devpart} ${cadr_fdt_addr} kria-kr260/zynqmp-smk-k26-revA-sck-kr-g-revB-cadr.dtb && load ${cadr_devtype} ${cadr_devpart} ${cadr_kernel_addr} kria-kr260/Image && load ${cadr_devtype} ${cadr_devpart} ${cadr_ramdisk_addr} kria-kr260/rootfs.cpio.uboot && run cadr_fabric_card && run cadr_booti'

# The network path: the served uEnv.net carries netcmd, which fetches the
# same files and ends in run cadr_booti.  DHCP here names no server, so the
# card uEnv.txt does, and it is imported again after dhcp in case a reply
# ever does name one.
setenv cadr_net 'setenv autoload no; dhcp && run cadr_uenv && tftpboot ${cadr_uenv_addr} kria-kr260/uEnv.net && env import -t ${cadr_uenv_addr} ${filesize} && run netcmd'

setenv cadr_try 'run cadr_uenv; if test -n "${serverip}"; then echo "cadr: uEnv.txt names a server; fetching over TFTP"; run cadr_net; else run cadr_card; fi'
setenv cadr_boot 'while true; do run cadr_try; echo "cadr: the boot did not happen; trying again in 10 s"; sleep 10; done'

run cadr_boot
