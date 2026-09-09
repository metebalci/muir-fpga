<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Linux on the PS

The fabric is the CADR; the PS runs Linux and serves it. Eventually that means
the disk pack on microSD, blocks fed to the disk controller, and an RFB server
reading the display out of DDR. **None of that exists.** This is the ground
under the first step of it --- Linux booting at all, with a device tree the
fabric can live alongside --- written before the board could be tried, because
the session doing it was cut short. Nothing here has run on hardware.

Everything below was read out of a binary, a source tree or a config file. The
one thing that was not is marked as such.

## The premise that is wrong

**There is no current prebuilt Digilent Linux image for the Arty Z7-20.** The
obvious plan --- take Digilent's image, edit its device tree --- starts from a
thing that does not exist, and it takes a while to establish that, because it
is an absence.

- Digilent's live releases under `Digilent/Arty-Z7` (August 2025) are Vivado
  hardware projects and bare-metal software. No image.
- `Digilent/Arty-Z7-OS` is a README reading "This is a simple Petalinux base
  project", and nothing else.
- **PYNQ does not cover this board.** `Xilinx/PYNQ` has board support for
  `Pynq-Z1`, `Pynq-Z2` and `ZCU104` only. The Arty Z7-20 resembles the Pynq-Z1
  and is not it.
- **Mainline Linux has no Arty Z7 device tree.** Seventeen `zynq-*` files in
  `arch/arm/boot/dts/xilinx`, the nearest being `zynq-zybo-z7.dts` --- a
  different Digilent board with 1 GB of DDR against this one's 512 MB.

So the choice is the 2017.4 PetaLinux BSP, Buildroot, or building the whole
boot chain by hand.

## What rescues it

**A `.bsp` is a tarball, and PetaLinux BSPs ship prebuilt images.** No
PetaLinux install is needed to get at them --- `tar xzf` is enough.

    Digilent/Petalinux-Arty-Z7-20, release v2017.4-1
    Petalinux-Arty-Z7-20-2017.4-1.bsp, 100 MB
    sha256 a83dbe29e3aa625ffb3d6c454c2e714046353f7dad774e244ac1a3bbbc225bf8

    Arty-Z7-20/pre-built/linux/images/
      BOOT.BIN          2,809,456    FSBL + bitstream + U-Boot
      image.ub         47,770,884    FIT: kernel + device tree + ramdisk
      zImage           47,451,456    kernel with the initramfs built in
      system.dtb           26,262
      u-boot.elf        3,280,904    U-Boot 2017.01 (Mar 27 2018)
      zynq_fsbl.elf       184,916

Board-exact: the tree's model is `Zynq Arty Z7 Development Board` and its
compatible is `digilent,zynq-artyz7`, `xlnx,zynq-7000`. The console is already
`ttyPS0` at 115200 with `stdout-path = "serial0:115200n8"`, which is the
`/dev/ttyUSB1` in `board.md`, and the bootargs already carry
`uio_pdrv_genirq.of_id=generic-uio`. The tree also has
`fpga-full { compatible = "fpga-region" }`, so Linux can program the PL.

**The cost is age.** U-Boot 2017.01, a 4.9-era kernel, a 2018 rootfs. That is
enough to answer "does the reservation hold", which is all steps 1 and 2 ask,
and **it should not be carried past step 3.** Buildroot is the decision for the
real thing; nothing here forecloses it, and the device tree work, the
reservation and `fdt_high` all transfer.

**The rootfs needs no partition.** `CONFIG_SUBSYSTEM_ROOTFS_INITRAMFS=y`, and
the FIT holds kernel 3,751,672, device tree 26,262 and ramdisk 43,991,305, with
`conf@1` (kernel + fdt + ramdisk) the default and `conf@2` (kernel + fdt) also
present. One FAT32 partition boots to a shell.

## The three that would have cost days

**Editing `/memory` is futile.** The tree says `reg = <0x00 0x20000000>` and
shrinking it does nothing: U-Boot's `arch_fixup_fdt`, in
`arch/arm/lib/bootm-fdt.c`, calls `fdt_fixup_memory_banks` unconditionally from
its own DRAM detection and puts 512 MB back. The symptom is not an error ---
it reads as "the device tree edit did not take". A `reserved-memory` node is
not on that path, which is the mechanism to use, and is also the word
`cadr_ddr_map.sv` already uses for it.

**U-Boot relocates the device tree into the region being reserved.** This is
the nasty one, because the reservation looks correct and is overwritten by the
loader that read it, and nothing says so. In `common/image-fdt.c`,
`boot_relocate_fdt` with `fdt_high` unset --- and it is unset in this build ---
falls through to

    lmb_alloc_base(lmb, of_len, 0x1000,
                   getenv_bootm_mapsize() + getenv_bootm_low())

which allocates from the **top** of RAM. The top of RAM is the CADR's 128 MB.
The escape is in the same function: `fdt_high` of `~0` takes the branch that
leaves the blob where it was loaded and calls `lmb_reserve` on it. So
`fdt_high=0xffffffff`, and `initrd_high=0xffffffff` for the 44 MB ramdisk on
the same reasoning. **Reserving the region is necessary and not sufficient;
the loader has to be bounded too.**

**`BOOT.BIN` contains a bitstream.** Digilent's, not ours: the `.bit` payload
from `Arty_Z7_20_wrapper.hdf` is inside it, word-swapped, at offset 106304, and
the boot header declares an FSBL of 0x18008 bytes. **So the moment the board
boots from SD, whatever the CADR bitstream was doing stops** --- a
JTAG-programmed fabric is displaced by the base design. Anyone expecting a
JTAG-loaded CADR to survive a reboot is wrong. It also means step 3 needs *our*
`BOOT.BIN`, with an FSBL whose `ps7_init` matches our own PS block rather than
Digilent's base design, and that is the real reason step 3 waits.

## The hook that makes a hand-edited tree cheap

U-Boot's `preboot` loads `uEnv.txt` from the card's FAT partition and imports
it, then `uenvboot` runs `uenvcmd`:

    preboot=... setenv bootenv uEnv.txt; setenv loadbootenv_addr 0x1EE00000;
        if test $modeboot = sdboot && env run sd_uEnvtxt_existence_test; then
        if env run loadbootenv; then env run importbootenv; fi; fi; dhcp
    sd_uEnvtxt_existence_test=test -e mmc $sdbootdev:$partid /uEnv.txt
    uenvboot=if run sd_uEnvtxt_existence_test; then run loadbootenv; ...
        if test -n $uenvcmd; then echo Running uenvcmd ...; run uenvcmd; fi

So the FIT never has to be repacked: a loose `zImage`, a loose `system.dtb` and
`bootz` are reachable from a text file. `himport_r` in `lib/hashtable.c` skips
lines beginning with `#`, so the file can carry comments and an SPDX header.

**Unresolved, and left unresolved deliberately: `$partid` is used by both of
those commands and is never defined in the default environment.** `strings` on
`u-boot.elf` finds no `partid=`. It may expand empty and still work --- `mmc 0:`
with no partition generally means the first --- or the auto-import may simply
not fire, in which case the console recovers it by hand. An environment
variable that is used and never defined is worth understanding rather than
routing past, and nobody has yet.

Other addresses read from the same environment: `netstart=0x10000000` is where
the stock flow loads `image.ub`, `cp_kernel2ram=mmcinfo && fatload mmc 0
${netstart} ${kernel_img}`, `kernel_img=image.ub`, `sdbootdev=0`.

## The plan, and why step 2's check is shaped the way it is

Stated as `step -> verify`, and step 3 is not started.

**1. Any Linux at all, from the stock image, unmodified.** The card gets
`BOOT.BIN` and `image.ub` and nothing else --- no `uEnv.txt`, so U-Boot runs
its own `default_bootcmd`. *Verify:* a shell on `/dev/ttyUSB1` at 115200;
`uname -a`; and `/proc/device-tree/model` reading `Zynq Arty Z7 Development
Board`. Changing nothing here is the point: it isolates card, jumper, console
and boot chain from anything of ours, and **it is also the control that step 2
needs**, because it is the boot that shows 512 MB.

**2. The reserved-memory node.** Purely additive to the same card: `zImage`,
our `system.dtb`, `uEnv.txt`. Renaming `uEnv.txt` returns it to step 1.

*Verify* --- and this is the part worth keeping:

**`/proc/meminfo` showing about 384 MB is necessary and not sufficient.** A
`reserved-memory` node, a `mem=384M` on the command line, and a DDR that only
enumerated 384 MB all produce that same number, and only one of them is the
thing being claimed. So the check is

  a. `dmesg` carrying an `OF: reserved mem:` line naming the node at
     `0x18000000`, 128 MiB;
  b. `/proc/device-tree/reserved-memory/` present --- which is what proves the
     node survived U-Boot's fixup, rather than that it was written;
  c. `MemTotal` about 384 MB;
  d. the region absent from `/proc/iomem`'s System RAM;
  e. **the control: step 1's stock boot, showing about 512 MB.**

**Without (e), 384 proves nothing.** The failure this is built against is the
one that has cost this project most --- a number that is right for a reason
nobody checked.

**3. The PS talking to the fabric.** Held until the PS block lands; there is no
AXI path today.

## The two decisions

**`no-map`, yes.** `S_AXI_HP` does not snoop the A9 caches, so a cacheable
kernel mapping of memory the fabric writes would go stale in a way that reads
as a fabric fault --- intermittent, data-dependent, and the worst class of bug
available here. `no-map` keeps the region out of the kernel's linear map
entirely. That it also makes a later userspace mapping uncached by construction
is a bonus and not the argument.

The kernel binary actually being booted supports it: `System.map.linux` exports
`early_init_fdt_scan_reserved_mem`, `fdt_init_reserved_mem` and
`memblock_mark_nomap`. Checked against the image, not against a kernel version
assumed from a release number.

**One node for the whole 128 MB**, not three for main memory, the display and
the spare. `0x1800_0000` and 128 MB are exactly `RESERVED_BASE` and
`RESERVED_MB` in `cadr_ddr_map.sv`; sub-dividing is a change to make when
something claims a sub-region by phandle, and not before.

## What is in `linux/`

    cadr-reserved.dtsi   the reserved-memory node, appended to the BSP's tree
    uEnv.txt             fdt_high, initrd_high, and the bootz that takes them
    mksd.sh              stages build/sd/{stock,reserved} from the BSP

`mksd.sh` sums the BSP before use, for the same reason the band's archive is
summed. The BSP itself is gitignored and belongs in `vendor/`.

**The device tree is built by appending, never by editing in place.** `dtc`
merges two root definitions, so the fragment stays a fragment and the BSP's
tree is untouched. `-p 0x1000` reproduces the BSP's own padding --- both trees
carry exactly 4096 bytes of slack after the string table, which is where U-Boot
puts its fixups.

**And the check on the edit is a diff.** Decompile what was built, decompile the
BSP's own tree through the same `dtc`, and require that only the added node
differs. Run against `dtc` 1.6.1: the diff is eleven added lines and zero
removed, the struct block grows from 17,332 bytes to 17,456, and nothing else
moves. A column-by-column diff is what makes a generated-file change
believable, and a device tree is no different.

## Physical, and one known unknown

- **The board is on `t490s`, Vivado is on `muirhost`.** `dtc` is not installed
  on the laptop; there is one at `~/Xilinx/2026.1/Vivado/bin/dtc` on muirhost,
  version 1.6.1, which is what built the tree described above. Locally,
  `device-tree-compiler` and `u-boot-tools` are both in the Ubuntu archive and
  neither was installed --- that is a decision for whoever picks this up.
- **The microSD card is not blank.** `/dev/sda`, 29.7 GB over USB, carrying
  Raspberry Pi OS: `sda1` 512 MB vfat labelled `bootfs`, `sda2` 29.2 GB ext4
  labelled `rootfs`. It was inspected read-only and **nothing was written to
  it**. It must not be overwritten without knowing whose it is.
- **The boot-mode jumper has to be set to SD**, and **its designator is
  deliberately not asserted here.** Digilent's site returns 403 to automated
  fetches, so it could not be read from a primary source, and it should be read
  off the board's silkscreen rather than recalled. A known unknown is worth
  more than an assumed one.
