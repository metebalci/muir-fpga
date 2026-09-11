<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Linux on the PS

**The procedure is `docs/boot.md`.** That covers the card, the server, the
jumper, the console and what to expect. This file is the reasoning and the
evidence behind it.

The fabric is the CADR. The PS runs Linux and serves it. Eventually that means
the disk pack on microSD, blocks fed to the disk controller, and an RFB server
reading the display out of DDR. **None of that exists.** This file is the
ground under the first step of it, which is Linux booting at all with a device
tree the fabric can live alongside. It was written before the board could be
tried, because the session doing it was cut short. **It has run on hardware
now, as the next section says, and three of the conclusions below did not
survive the board.**

Everything below was read out of a binary, a source tree or a config file. The
rest was measured on this machine by running `mksd.sh` and by walking the
images it stages. Where a reason has been replaced since it was first written,
the file names what was read and the revision it was read at, because the
numbers rot loudly and the reasoning rots silently. The U-Boot source cited
throughout is u-boot-xlnx commit `a2911a99e4`. That is not a guess at a
version. It is the commit whose build path is compiled into this `u-boot.elf`.

## What the board said, 10 September

The first boot corrected this file in three places. Each correction was
measured on the console, with the board reset over JTAG between attempts.
`docs/boot.md` has the procedure, and
`boards/arty-z7-20/linux/uEnv.net` carries the reasoning next to the command.

1. **The loose `zImage` in the BSP is not the kernel in `image.ub`.** It is
   build `#2` (`Tue Mar 27 23:13:26`), where the FIT's `kernel@0` is build `#1`
   (`23:12:30`). Build #2 dies silently after `Memory policy: Data cache
   writealloc`, under Digilent's own tree as well as ours. Everything below
   that says "a loose `zImage`" was reasoning about a file nobody had booted.
   The boot uses the FIT's kernel and ramdisk under a raw tree:
   `bootm <fit>:kernel@0 <fit>:ramdisk@0 <fdt>`.

2. **Loading a zImage at `0x10000000` makes the kernel forget the memory
   below it.** The kernel says `OF: fdt:Ignoring memory range 0x0 -
   0x10000000`. So the first card left Linux 128 MB between the kernel and the
   reservation, and it died unpacking its root filesystem. The FIT's kernel
   loads at `0x8000`, and the problem does not arise.

3. **`no-map` kills this 4.9 kernel** when the region is inside the memory
   the kernel owns. The console goes silent after `Memory policy`, three times
   out of three. The same node without `no-map` boots and reserves the region
   (`189172K reserved`), but it leaves the region in the cached linear map,
   which is the hazard the section below was written to avoid. **What works is
   `mem=384M` on the command line.** `/proc/iomem` then says System RAM ends at
   `0x17ffffff`. The node is kept, and it is harmless and true.
   `/proc/device-tree/reserved-memory/cadr@18000000` reads `18000000
   08000000`. Shrinking the tree's `memory` node does nothing, because U-Boot
   rewrites it from its own DRAM size on every boot. That was measured: the
   tree said 384 MB and the kernel saw 512.

   And `cma=32M` goes with it. The kernel's default 128 MB pool out of 384
   left too little ordinary memory to unpack the 42 MB root filesystem. The
   kernel said `rootfs image is not initramfs (write error)`, then `VFS: Unable
   to mount root fs`. With 32 MB it reaches `Memory: 303564K/393216K
   available`, a login shell, and `MemTotal: 380320 kB`.

4. **The card carries one line now.** It fetches `uEnv.net` from the TFTP
   server and runs the command in it, so the two corrections above cost one
   card write between them and the next will cost none. `fdt_high` and
   `initrd_high` are no longer set anywhere. The `bootm` path relocates both
   below 128 MB as the stock boot does, and the FIT-in-place hazard the
   section below describes cannot arise when the tree is not the FIT's.

5. **The fallback is gone.** Digilent's stock boot was run once for
   comparison, with the server stopped and the board reset, and it reaches a
   login with `Memory: 335116K/524288K`. Then Mete decided the board must never
   boot it, because a Linux with 512 MB owns the CADR's memory. The card's file
   sets `cp_kernel2ram=reset`, so the fallback's own copy step reboots the
   board to try again. (`|| reset` on the fetch line was tried first and did
   not fire on the real boot path.) The sections below that
   call the fallback "the control" describe the first card. They are kept as
   the record of why the network loop was built the way it was.

6. **No private addresses in this repository.** It is public. The TFTP
   server's address lives in `boards/arty-z7-20/linux/local.conf`, which is
   gitignored, and `mksd.sh` fills it into `uEnv.txt` from
   `boards/arty-z7-20/linux/uEnv.txt.in`. Machines are named by their role
   here: the build host, the laptop, the TFTP server.

## The premise that is wrong

**There is no current prebuilt Digilent Linux image for the Arty Z7-20.** The
obvious plan is to take Digilent's image and edit its device tree. That plan
starts from a thing that does not exist. It takes a while to establish that,
because it is an absence.

- Digilent's live releases under `Digilent/Arty-Z7` (August 2025) are Vivado
  hardware projects and bare-metal software. They carry no image.
- `Digilent/Arty-Z7-OS` is a README reading "This is a simple Petalinux base
  project", and nothing else.
- **PYNQ does not cover this board.** `Xilinx/PYNQ` has board support for
  `Pynq-Z1`, `Pynq-Z2` and `ZCU104` only. The Arty Z7-20 resembles the Pynq-Z1
  and is not it.
- **Mainline Linux has no Arty Z7 device tree.** There are seventeen `zynq-*`
  files in `arch/arm/boot/dts/xilinx`. The nearest is `zynq-zybo-z7.dts`, a
  different Digilent board with 1 GB of DDR against this one's 512 MB.

So the choice is the 2017.4 PetaLinux BSP, Buildroot, or building the whole
boot chain by hand.

## What rescues it

**A `.bsp` is a tarball, and PetaLinux BSPs ship prebuilt images.** No
PetaLinux install is needed to get at them. `tar xzf` is enough.

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

The tree is board-exact. Its model is `Zynq Arty Z7 Development Board` and its
compatible is `digilent,zynq-artyz7`, `xlnx,zynq-7000`. The console is already
`ttyPS0` at 115200 with `stdout-path = "serial0:115200n8"`, which is the
`/dev/ttyUSB1` in `board.md`. The bootargs already carry
`uio_pdrv_genirq.of_id=generic-uio`. The tree also has
`fpga-full { compatible = "fpga-region" }`, so Linux can program the PL.

**The cost is age.** It ships U-Boot 2017.01, a 4.9-era kernel and a 2018
rootfs. That is enough to answer "does the reservation hold", which is all
steps 1 and 2 ask. **It should not be carried past step 3.** Buildroot is the
decision for the real thing. Nothing here forecloses it, and the device tree
work, the reservation and `fdt_high` all transfer.

**The rootfs needs no partition.** The BSP sets
`CONFIG_SUBSYSTEM_ROOTFS_INITRAMFS=y`. The FIT holds kernel 3,751,672, device
tree 26,262 and ramdisk 43,991,305. `conf@1` (kernel + fdt + ramdisk) is the
default, and `conf@2` (kernel + fdt) is also present. One FAT32 partition boots
to a shell.

## The three that would have cost days

**Editing `/memory` is futile.** The tree says `reg = <0x00 0x20000000>`, and
shrinking it does nothing. U-Boot's `arch_fixup_fdt`, in
`arch/arm/lib/bootm-fdt.c`, calls `fdt_fixup_memory_banks` unconditionally from
its own DRAM detection and puts 512 MB back. The symptom is not an error. It
reads as "the device tree edit did not take". A `reserved-memory` node is not
on that path. That is the mechanism to use, and it is also the word
`cadr_ddr_map.sv` already uses for it.

**The reserved-memory node binds the kernel, and not the loader.** Two things
are inside the 128 MB before Linux starts. No node in the tree U-Boot is
carrying stops either of them.

`loadbootenv_addr` is `0x1EE00000`. Preboot sets it, and it is 115 MiB
into the reservation, in the spare 56 MB past the display. U-Boot writes
`uEnv.txt` there on every boot. Only the *second* write can be moved.
`uEnv.txt` is imported twice, and the first import happens before
`uenvboot`'s `load` runs, so a `loadbootenv_addr` set in the file is obeyed by
the second. The first lands at `0x1EE00000` whatever the card says.

**And U-Boot relocates itself to the top of DDR.** `CONFIG_VERY_BIG_RAM` is
defined in neither BSP config header. So `get_effective_memsize()`
(`common/memsize.c`) returns the whole 512 MB, `gd->relocaddr = gd->ram_top`,
and U-Boot's text, stack and malloc arena sit just under `0x2000_0000`, inside
the reservation. That is derived from the source at u-boot-xlnx `a2911a99e4`.
It has not yet been seen in a boot log.

Both are free today, because the fabric at that moment is Digilent's base
design and the CADR is not running. **They stop being free at step 3**, when
our own `BOOT.BIN` boots a card with our own bitstream already in the fabric. A
CADR running out of DDR then has its spare region and its top megabyte written
under it by the loader that is about to start Linux.

**What is *not* a hazard, against the obvious reading.** `boot_relocate_fdt`
in `common/image-fdt.c`, with `fdt_high` unset, and it is unset in this
build, falls through to

    lmb_alloc_base(lmb, of_len, 0x1000,
                   getenv_bootm_mapsize() + getenv_bootm_low())

It is tempting to read that as the **top** of RAM, which would be the CADR's
128 MB, and this file said so for a while. It is not. Here
`getenv_bootm_mapsize()` returns `CONFIG_SYS_BOOTMAPSZ`, which
`project-spec/meta-plnx-generated/recipes-bsp/u-boot/configs/platform-auto.h`
line 141 sets to **`0x08000000`**. And `getenv_bootm_low()` returns 0.
`CONFIG_SYS_SDRAM_BASE` is not defined either, which is also why `dram_init`
comes from `fdtdec_setup_memory_size`, so it falls to
`gd->bd->bi_dram[0].start`. The ceiling is **128 MB: a quarter of DDR, and
256 MB below `0x1800_0000`.** The device tree cannot be relocated into the
reservation on this board, and the ramdisk uses the same ceiling.

So **`fdt_high=0xffffffff` stays, and it is tidiness.** It takes the branch
that leaves the blob where it was loaded and calls `lmb_reserve` on it. That
avoids a `fdt_open_into` copy and keeps the tree at the address `uEnv.txt`
chose. It is not the thing standing between the plan and a corrupted region.
The two paragraphs above are. `initrd_high=0xffffffff` is the same. It is moot
for the `bootz` path anyway, because the rootfs is the initramfs inside
`zImage` and there is no separate ramdisk to place.

All of the above was read at u-boot-xlnx commit `a2911a99e4`, which is the
commit this `u-boot.elf` was built from. Its build path is compiled into the
binary, as `v2017.01-xilinx-v2017.4+gitAUTOINC+a2911a99e4-r0`.

**`BOOT.BIN` contains a bitstream.** It is Digilent's and not ours. The `.bit`
payload from `Arty_Z7_20_wrapper.hdf` is inside it, word-swapped, at offset
106304, and the boot header declares an FSBL of 0x18008 bytes. **So the moment
the board boots from SD, whatever the CADR bitstream was doing stops.** A
JTAG-programmed fabric is displaced by the base design. Anyone expecting a
JTAG-loaded CADR to survive a reboot is wrong. It also means step 3 needs *our*
`BOOT.BIN`, with an FSBL whose `ps7_init` matches our own PS block rather than
Digilent's base design. That is the real reason step 3 waits.

## The hook that makes a hand-edited tree cheap

U-Boot's `preboot` loads `uEnv.txt` from the card's FAT partition and imports
it, then `uenvboot` runs `uenvcmd`:

    preboot=... setenv bootenv uEnv.txt; setenv loadbootenv_addr 0x1EE00000;
        if test $modeboot = sdboot && env run sd_uEnvtxt_existence_test; then
        if env run loadbootenv; then env run importbootenv; fi; fi; dhcp
    sd_uEnvtxt_existence_test=test -e mmc $sdbootdev:$partid /uEnv.txt
    uenvboot=if run sd_uEnvtxt_existence_test; then run loadbootenv; ...
        if test -n $uenvcmd; then echo Running uenvcmd ...; run uenvcmd; fi

So the FIT never has to be repacked. A loose `zImage`, a loose `system.dtb` and
`bootz` are all reachable from a text file. `himport_r` in `lib/hashtable.c`
skips lines beginning with `#`, so the file can carry comments and an SPDX
header. A blank line is safe too, though for a stranger reason. It parses as an
empty name, takes the delete branch, and fails silently to delete a variable
that was never there. `boards/arty-z7-20/linux/uEnv.txt` leans on both, being
mostly prose.

**`$partid` is empty, always, and empty means partition 1.** It is used by both
of those commands and defined by neither. The earlier reading of that was that
it might work, or might not, and that someone would have to find out at the
console. That reading is settled. Three things say so, and they agree:

- The whole default environment was dumped from the binary rather than grepped.
  It is the `default_environment` object at vaddr `0x04047fd2`, 3,014 bytes,
  with 47 variables enumerated. It holds no `partid`. The same list is
  `CONFIG_EXTRA_ENV_SETTINGS` in `platform-auto.h`, which the BSP ships.
- Nothing can define it later. `platform-top.h` forces `CONFIG_ENV_IS_NOWHERE`
  when there is no SPI-flash environment, so there is no saved environment at
  all. The built-in default is what runs on every boot.
- Empty resolves to partition 1. U-Boot's hush joins the substituted words and
  re-parses them (`common/cli_hush.c`, `make_string()`), so the empty word
  vanishes and `blk_get_device_part_str` sees `"0:"`. In `disk/part.c` the
  colon with nothing after it gives `part = PART_UNSPECIFIED` (-2, line 389).
  A card with a partition table then takes the `part = 1` branch. A card
  with no table takes the whole device, because `fs_set_blk_dev` passes
  `allow_whole_dev = 1`. Both are what is wanted.

So `partid` exists only to let someone override a default of 1, and there is
nothing to recover at the console.

**`$modeboot` is unset in this build, and the guard that reads it succeeds by
accident.** `u-boot.elf` has no `board_late_init` symbol and no
`zynq_slcr_get_boot_mode`. The strings `"modeboot"`, `"sdboot"`,
`"qspiboot"`, `"norboot"`, `"nandboot"` and `"jtagboot"` occur **zero** times
each as standalone NUL-delimited strings. Their only appearance is inside the
text of `preboot` itself. `CONFIG_BOARD_LATE_INIT` was not enabled, and
`--gc-sections` took the function that would have called
`setenv("modeboot", "sdboot")`, along with its string constants.

The guard therefore evaluates `test = sdboot`, in which no operator matches
`ap[1]`. So `cmd/test.c` falls to `expr = 1; break;` and then `expr = !expr;
return expr;`, returning 0, which is success. This is the same branch that
makes `test STRING` true for a bare non-empty word.

**It does not matter today**, because the import that the plan relies on is
`uenvboot`'s, and `uenvboot` has no `modeboot` test. `default_bootcmd` is
`run uenvboot; run cp_kernel2ram && bootm ${netstart}`, and `uenvboot` runs
`sd_uEnvtxt_existence_test` directly. **It would matter if
`CONFIG_BOARD_LATE_INIT` were ever turned on in a rebuild.** `modeboot` would
then be set, the guard would start comparing two real strings, and preboot's
import would begin *failing* on a QSPI or JTAG boot where today it passes.
A rebuild of U-Boot is not on the plan, but it is on the road to Buildroot.

Other addresses were read from the same environment. `netstart=0x10000000` is
where the stock flow loads `image.ub`. The rest are
`cp_kernel2ram=mmcinfo && fatload mmc 0 ${netstart} ${kernel_img}`,
`kernel_img=image.ub` and `sdbootdev=0`.

The command set is 85 entries, enumerated from `.u_boot_list` rather than
guessed. `load`, `fatload`, `mmcinfo`, `bootz`, `bootm`, `tftpboot`, `dhcp`,
`test`, `run`, `source`, `env`, `sf` and `fpga` are all present. **`fdt` and
`setexpr` are not.** So the device tree cannot be inspected or patched from the
U-Boot prompt, which is worth knowing before planning a debugging session
around it.

## The plan, and why step 2's check is shaped the way it is

Stated as `step -> verify`, and step 3 is not started.

**1. Any Linux at all, from the stock image, unmodified.** The card gets
`BOOT.BIN`, `image.ub` and `uEnv.txt`, and the TFTP server on the build host is
not running. So the fetch fails, `uenvcmd`'s `&&` chain stops, and U-Boot falls
through to its own `default_bootcmd`. *Verify:* a shell on `/dev/ttyUSB1` at
115200; `uname -a`; and `/proc/device-tree/model` reading `Zynq Arty Z7
Development Board`. Changing nothing of ours here is the point. It isolates
card, jumper, console and boot chain, and **it is also the control that step 2
needs**, because it is the boot that shows 512 MB.

**2. The reserved-memory node.** The card is the same, and it is untouched. The
server comes up holding `system.dtb` and `zImage`. U-Boot fetches them and
boots them instead. Stopping the server returns the board to step 1.

*Verify*, and this is the part worth keeping:

**`/proc/meminfo` showing about 384 MB is necessary and not sufficient.** A
`reserved-memory` node, a `mem=384M` on the command line, and a DDR that only
enumerated 384 MB all produce that same number. Only one of them is the thing
being claimed. So the check is

  a. `dmesg` carrying an `OF: reserved mem:` line naming the node at
     `0x18000000`, 128 MiB;
  b. `/proc/device-tree/reserved-memory/` present --- which is what proves the
     node survived U-Boot's fixup, rather than that it was written;
  c. `MemTotal` about 384 MB;
  d. the region absent from `/proc/iomem`'s System RAM;
  e. **the control: step 1's stock boot, showing about 512 MB.**

**Without (e), 384 proves nothing.** The failure this is built against is the
one that has cost this project most. That failure is a number that is right for
a reason nobody checked.

**3. The PS talking to the fabric.** This is held until the PS block lands.
There is no AXI path today.

## The network loop, and why the fallback was the control (first card; superseded above)

**The card is written once and everything after it arrives over Ethernet.**
U-Boot fetches `system.dtb` and `zImage` from the build host by TFTP. The
bitstream is loaded from Linux, later. That is Mete's decision, and it turns
out to buy more than convenience.

**`default_bootcmd` is `run uenvboot; run cp_kernel2ram && bootm ${netstart}`,
with a semicolon and not an `&&`.** So a failed fetch is not a failed boot. The
`&&` chain inside `uenvcmd` stops at the first `tftpboot`, `uenvboot` returns,
and the card boots the stock `image.ub` with the BSP's own device tree. With
`netretry` unset that is one attempt and not a loop (`net/net.c`, 669-685).

**Server off is step 1, server on is step 2, one card, and nothing is touched
between them.** The two boots then differ in exactly one 26 KB file sitting on
the build host. That is a sharper control than the old plan's "rename
`uEnv.txt` on the card". The old plan required unplugging the board, finding a
reader, and trusting that nothing else changed in the handling.

**It is a real control only because `fdt_high` is set late.**
`boards/arty-z7-20/linux/uEnv.txt` sets `fdt_high` and `initrd_high` inside
`uenvcmd`, *after* both fetches, and not as imported variables. Imported, they
would also apply to the fallback `bootm image.ub`, where `fdt_high=~0` makes
`boot_relocate_fdt` call `fdt_set_totalsize(fdt, size + CONFIG_SYS_FDT_PAD)` on
the tree **inside the FIT**. That was measured on this `image.ub` by walking
its own structure. The `fdt@0` data ends at file offset 3,778,390 and
`ramdisk@0`'s data begins at 3,778,568, 178 bytes later, while
`CONFIG_SYS_FDT_PAD` is `0x3000` (`common/image-fdt.c` lines 20-21, and neither
BSP header overrides it). A blob declared 26,262 + 12,288 bytes long therefore
overlaps the ramdisk by 12,110, and the memory-bank and bootargs fixups are
written into it. The control would have been quietly booting a damaged ramdisk.
Setting the two late costs one thing, and it is named in the file. If both
fetches succeed and `bootz` then fails, the fallback runs with them set. That
means a corrupt `zImage` on the server, and a console session either way.

**What has to exist on the build host.** There are two things. `tftpd-hpa` is
installed and serving `/srv/tftp` on `:69` with `--secure` (installed 10 Sep).
The directory is owned by the ordinary user, so the files can be refreshed
without root. `system.dtb` and `zImage` were in it, copied from
`build/sd/reserved/`. They were fetched back over TFTP from this host with
`curl`, at the same 1,468-byte block size `uEnv.txt` asks for. Both came back
byte-identical to the staged copies, and the 47.4 MB kernel took 1.4 s on the
loopback. What that measures is the server and the files, not the board's link.
The board's fetch time is still unmeasured.

- **A TFTP server on UDP 69.** Port 69 is privileged and this U-Boot has no
  `tftpdstp`, so the port cannot be moved from the board side. This needs root
  once. `tftpd-hpa` and `dnsmasq --enable-tftp` are both in the archive.
- **A served directory.** It holds `system.dtb` and `zImage`, 95 MB copied out
  of `build/sd/reserved/`.

`serverip` is the TFTP server's address, from
`boards/arty-z7-20/linux/local.conf`, which the router fixes. `ipaddr` is
deliberately absent. Preboot ends in an unconditional `dhcp` whatever the card
says, there is a DHCP server on this LAN, and `CONFIG_BOOTP_SERVERIP` means a
DHCP reply cannot overwrite `serverip`.

**There are two unknowns, and they are the reason not to write a card before
asking.**

- **the build host is a virtual machine.** It has one virtio disk, a QEMU
  tablet on the USB bus, no card reader and no board. Whether the Arty can
  reach it at all depends on that VM being bridged rather than NAT'd, and that
  cannot be established from inside the guest. Settle it before the card is
  written.
- **The MAC comes from QSPI flash.** `ethaddr` is empty in the default
  environment. `zynq_board_read_rom_ethaddr` reads six bytes by
  `CMD_OTPREAD_ARRAY_FAST` at `ZYNQ_GEM_SPI_MAC_OFFSET` (`0x20`), which
  `platform-top.h` sets. The code is compiled in, and its failure message
  (`SPI MAC address read failed`) is in the binary. Whether the read succeeds
  on this board is a thing only a boot log says.

**And the cost is not measured.** The boot fetches 47.4 MB of `zImage` over
TFTP every time. `tftpblocksize=1468` is set, which normally makes that seconds
rather than a minute, but no figure here is worth quoting until one is timed.
If it proves painful, the cheap variant is to keep `zImage` on the card and
fetch only the 26 KB tree, because the kernel does not change while the device
tree does: `tftpboot 0x0f000000 system.dtb && fatload mmc 0 0x10000000 zImage
&& bootz`. That keeps the card written once and keeps the fallback intact.

## The two decisions

**`no-map`, yes.** `S_AXI_HP` does not snoop the A9 caches. So a cacheable
kernel mapping of memory the fabric writes would go stale in a way that reads
as a fabric fault. Such a bug is intermittent and data-dependent, and it is the
worst class available here. `no-map` keeps the region out of the kernel's
linear map entirely. It also makes a later userspace mapping uncached by
construction, which is a bonus and not the argument.

The kernel binary actually being booted supports it. `System.map.linux` exports
`early_init_fdt_scan_reserved_mem`, `fdt_init_reserved_mem` and
`memblock_mark_nomap`. That was checked against the image, not against a kernel
version assumed from a release number.

**One node covers the whole 128 MB**, rather than three for main memory, the
display and the spare. `0x1800_0000` and 128 MB are exactly `RESERVED_BASE` and
`RESERVED_MB` in `cadr_ddr_map.sv`. Sub-dividing is a change to make when
something claims a sub-region by phandle, and not before.

## What is in `boards/arty-z7-20/linux/`

    cadr-reserved.dtsi   the reserved-memory node, appended to the BSP's tree
    uEnv.txt             the TFTP boot, with fdt_high and initrd_high pinned
    mksd.sh              stages build/sd/{stock,reserved} from the BSP

`mksd.sh` sums the BSP before use, for the same reason the band's archive is
summed. The BSP itself is gitignored and belongs in `vendor/`.

**`mksd.sh` has now been run end to end on the build host**, against the
recorded sha256, with `DTC` resolving to `~/Xilinx/2026.1/Vivado/bin/dtc` on
the path. It took 0.79 s wall. This is what it stages:

    build/sd/stock/     BOOT.BIN  2,809,456   image.ub  47,770,884
    build/sd/reserved/  BOOT.BIN  2,809,456   image.ub  47,770,884
                        zImage   47,451,456   uEnv.txt       4,099
                        system.dtb   26,265
    tree diff: 11 lines added, 0 removed

Every one of those matches the BSP table above byte for byte, and the rebuilt
`system.dtb` is byte-identical to the tree that was built by hand before the
script existed. The script as a script is exercised. The claim is a claim.

**The device tree is built by appending, never by editing in place.** `dtc`
merges two root definitions, so the fragment stays a fragment and the BSP's
tree is untouched. `-p 0x1000` reproduces the BSP's own padding, and both trees
carry exactly 4096 bytes of slack after the string table. That is a
fidelity choice and not a functional one. U-Boot's own fixup room is
`CONFIG_SYS_FDT_PAD`, and on the `fdt_high=~0` path `boot_relocate_fdt` adds it
by calling `fdt_set_totalsize(of_start, of_size + CONFIG_SYS_FDT_PAD)` and
writing *past* the blob it loaded, not into the slack inside it. Matching the
BSP is still right. It is just not what the padding is for.

**And the check on the edit is a diff.** Decompile what was built, decompile
the BSP's own tree through the same `dtc`, and require that only the added node
differs. Run against `dtc` 1.6.1, the diff is eleven added lines and zero
removed, the struct block grows from 17,332 bytes to 17,456, and nothing else
moves. A column-by-column diff is what makes a generated-file change
believable, and a device tree is no different.

## Physical, and one known unknown

- **Vivado is on the build host, and the card is written on the laptop.** The
  build host is a virtual machine with one 256 GB virtio disk, a
  QEMU tablet on the USB bus, no card reader and nothing removable. So
  `build/sd/` is staged here and copied there, 95 MB for `reserved/` alone.
  Every `dd`, `sfdisk` and `mount` below happens on the laptop.
  `dtc` is on the build host at `~/Xilinx/2026.1/Vivado/bin/dtc`, version
  1.6.1, and it is on the path there, which is what `mksd.sh` now runs with. On
  the laptop, `device-tree-compiler` and `u-boot-tools` are both in the Ubuntu
  archive and neither is installed. Neither needs to be, because the tree is
  built where `dtc` already is.
- **The microSD card is free to use.** It is `/dev/sda`, 29.7 GB over USB. It
  came carrying Raspberry Pi OS: `sda1` 512 MB vfat labelled `bootfs`, and
  `sda2` 29.2 GB ext4 labelled `rootfs`. That was inspected read-only, and Mete
  has since confirmed the card can be reformatted. **Check the device node
  before writing anything.** It is `/dev/sda` on this laptop today, and it is
  `/dev/sda` on the build host too, where that is the system disk. `mksd.sh`
  never touches a device for exactly this reason. The naming is done by a
  human, once, here:

      lsblk -o NAME,SIZE,TRAN,TYPE,LABEL,MOUNTPOINT
      D=/dev/sdX                      # the line that says usb, not from memory
      sudo umount ${D}?* 2>/dev/null

      sudo sfdisk --wipe always $D <<'EOF'
      label: dos
      start=2048, type=c, bootable
      EOF
      sudo mkfs.vfat -F 32 -n BOOT ${D}1

      M=$(mktemp -d) && sudo mount ${D}1 $M
      sudo cp build/sd/reserved/BOOT.BIN build/sd/reserved/image.ub $M/
      sudo cp boards/arty-z7-20/linux/uEnv.txt $M/
      sudo sync && sudo umount $M && rmdir $M

  That makes one FAT32 primary partition, MBR, type `0x0c`, bootable. That is
  what `$partid` empty resolves to and what `fatload mmc 0` resolves to
  independently, so the two agree by construction rather than by luck. With the
  network loop, `system.dtb` and `zImage` do not go on the card at all, and
  `build/sd/stock/` is unused, because the fallback boot is the control.
- **The card is written**, on 10 Sep, from the build host over ssh to the
  laptop, with the recipe above against `/dev/sda` (29.7 GB, usb, guarded by
  `lsblk` before the wipe). It has one partition, `2048..62333951`, type
  `0x0c`, bootable, `vfat` labelled `BOOT`. The three files read back with the
  staged sha256s. Nothing else is on it.
- **The boot-mode jumper has to be set to SD**, and **its designator is
  deliberately not asserted here.** Digilent's site returns 403 to automated
  fetches, so it could not be read from a primary source. It should be read
  off the board's silkscreen rather than recalled. A known unknown is worth
  more than an assumed one.
