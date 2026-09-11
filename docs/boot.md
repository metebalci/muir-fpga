<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Booting the board into Linux

This file describes how the Arty Z7-20 gets from power-on to a Linux prompt
beside the running CADR, with the CADR's memory reserved. It says what is on
the card and what is on the build host. It gives the steps in the order they
are done. The board boots from the card alone. For development the card's
one-line file names a TFTP server, and the same files come from there
instead. `docs/linux.md` has the reasoning behind every choice here and the
evidence for it. This file is the procedure. Where the two disagree,
`linux.md` wins, because it was read out of the binaries.

## The image

The board runs a Buildroot image. It is built entirely on the build host
from a pinned Buildroot, so that the board is reproducible from the
repository and survives a machine move. **It has booted the board.** The
network path ran on 10 September: U-Boot's first stage, U-Boot, the CADR into
the fabric, Linux 6.19 with the reservation honoured by the tree alone, and a
login 15 s after the reset. The card path is how anyone else's board boots,
and it ran the same day from U-Boot's prompt. The four files were read off
the card in under a second, Linux came up with the reservation, and the
CADR's counters read 256 and 256. It ran again that afternoon with the disk
in the fabric and the pack on the card. The drive came present and the
machine loaded its microcode from it. A board with this card and no network
is the whole machine.

## What it is

    Buildroot   2026.02.3, the LTS   vendor/buildroot-2026.02.3.tar.xz, sha256 5a59e750...c6fc7fb
    U-Boot      2026.01, mainline    SPL is the first-stage loader: BOOT.BIN 127,456 B;
                                     u-boot.img 1,076,532 B (a FIT: U-Boot proper and its tree)
    Linux       6.19.14, mainline    zImage 3,337,032 B; zynq-arty-z7-20.dtb 11,401 B
    rootfs      BusyBox + Dropbear   rootfs.cpio.uboot 2,801,388 B (6.2 MB unpacked), an
                + evtest             initramfs, unpacked into RAM on both paths
    the card    two FAT32 partitions sdcard.img, 3,222,274,048 B (1 MiB + 512 MiB + 2,560 MiB
                                     by default, sparse: 277 MB on disk).  Partition 1: the
                                     loader and the boot files, seven of them, 11.3 MB.
                                     Partition 2: the drive bay --- nothing but disk packs

The sizes are of the 10 September builds on the build host. The whole
thing --- toolchain download, host tools, U-Boot, kernel, root filesystem ---
took 25 minutes of wall clock on 16 cores. `make buildroot` after a change
takes minutes. **Buildroot does not watch our files.** After editing anything
under `boards/arty-z7-20/linux/buildroot/`, run `make buildroot-rebuild`. It
reconfigures U-Boot, the kernel and `cadr-disk-packs`, and finishes the
image.

`boards/arty-z7-20/linux/buildroot/` is the Buildroot external tree. `make
buildroot` builds the whole thing from the tarball, which takes several
gigabytes under `~/.cache/muir-fpga-buildroot`, never `/tmp` and never
`build/`. `boards/arty-z7-20/linux/mksd-buildroot.sh` stages the card and the
server directory under `build/sd/buildroot/`. Every file under
`boards/arty-z7-20/linux/buildroot/` carries the reason for what it holds.
These are the ones worth knowing exist:

    configs/arty_z7_20_defconfig               the whole image, pinned
    board/arty-z7-20/dts/xilinx/zynq-arty-z7-20.dts   the board, for Linux AND U-Boot
    board/arty-z7-20/uboot/ps7_init_gpl.c      the start-up routine, GENERATED from boards/arty-z7-20/vivado/ps7_init.ops
    board/arty-z7-20/uboot/gen_ps7_init_gpl.py the generator; --check, and --compare against Vivado's
    board/arty-z7-20/uboot/cadr.env            U-Boot's default environment: both paths, the retry loop
    board/arty-z7-20/uboot/uboot.fragment      what changes in xilinx_zynq_virt_defconfig
    board/arty-z7-20/linux/linux.config        the kernel: what the board has and nothing more
    board/arty-z7-20/uEnv.txt.in, uEnv.net     the card's optional file and the served boot command
    board/arty-z7-20/genimage.cfg              the card as one image, sdcard.img
    board/arty-z7-20/post-build.sh             the image holds only the programs the packages install
    package/                                   our own programs, one package each

**The image holds only the programs the packages install, and the build fails
if it does not.** Buildroot builds `output/target/` up and never removes what
a package stopped installing. Renaming a package therefore leaves its old
program and its old init script in the image beside the new ones. That
happened once. The rename from `cadr-pack-feeder` to `cadr-disk-pack` left
`usr/bin/cadr-pack-feeder` and `etc/init.d/S80cadr-pack-feeder` behind. Every
boot after it started TWO disk pack programs. Each mapped the same registers,
each served blocks, and each wrote blocks back to the same pack file. The
pack did not survive it, and a day went into blaming the disk channel.
`board/arty-z7-20/post-build.sh` is the guard. Buildroot runs it from
`BR2_ROOTFS_POST_BUILD_SCRIPT` during `target-finalize`, so it runs on every
`make buildroot` and every `make buildroot-rebuild`. It also runs BEFORE the
root filesystem image is written, so an image with a ghost in it is never
produced. It costs one `find` over the target. When it fires, it names the
files and prints the `rm` that clears them. **The remedy is to delete them,
not to weaken the check.** Its header says why it is an assertion rather than
a clean target directory: a clean target is a 25-minute rebuild, and a guard
that is skipped is not a guard. The header also says why Buildroot's own
`packages-file-list.txt` cannot be the oracle, which is that it still names
packages deleted a day earlier.

**The start-up routine is the same one, proved rather than assumed.** U-Boot's
SPL runs `ps7_init()` and `ps7_post_config()` from a `ps7_init_gpl.c`, as
Digilent's FSBL did. Ours is generated from
`boards/arty-z7-20/vivado/ps7_init.ops`, the committed, `make
current`-checked list of the 673 register operations of Digilent's routine,
so that a checkout without Vivado can build the loader. `gen_ps7_init_gpl.py
--compare build/ps7/ps7_init_gpl.c` reads the file Vivado itself writes. It
requires the same operations in the same tables in the same order. That is
660 in 18 tables, identical, measured at the commit that added it. The 13 the
generated file does not carry are the three `ps7_debug` tables nothing runs
and the SCU-timer helpers U-Boot has its own copy of. `make buildroot-check`
fails if the C ever stops being what the `.ops` say, and `make buildroot`
runs it first.

**One device tree for both.** Mainline has no Arty Z7 tree. Ours is written
like `zynq-zybo-z7.dts`, from Digilent's own BSP tree and
`boards/arty-z7-20/vivado/ps7_config.tcl`. It differs from every mainline
Zynq board in three things the files settle: the console is **UART 0**, the
PS clock is **50 MHz**, and the PHY is at MDIO address **1**. It includes
`boards/arty-z7-20/linux/cadr-reserved.dtsi`, the same node the stepping
stone appended. It is compiled twice, by the kernel and by U-Boot. U-Boot
reading it matters. Mainline U-Boot honours a `reserved-memory` node in its
*own* tree for its own relocation (`common/memtop.c`) and for where it puts
the fdt and the ramdisk (`lib/lmb.c`). It does not rewrite the kernel's
memory node, because `ARCH_FIXUP_FDT_MEMORY` is off in `xilinx_zynq_virt`.
So the loader stays out of the CADR's region by the same node that keeps the
kernel out. That closes the hazard `linux.md` recorded for this U-Boot ---
"the reserved-memory node binds the kernel, and not the loader".

## The card, and the two ways it boots

    partition 1 BOOT.BIN (U-Boot's SPL), u-boot.img, uEnv.txt (optional),
                cadr.bit, zynq-arty-z7-20.dtb, zImage, rootfs.cpio.uboot
    partition 2 disk-pack-0.img .. disk-pack-7.img, whichever exist, and a
                README.TXT; neither the boot ROM nor U-Boot ever looks here
    /srv/tftp   uEnv.net, cadr.bit, zynq-arty-z7-20.dtb, zImage, rootfs.cpio.uboot
                --- this project's convenience, the same five files

U-Boot's built-in environment (`cadr.env`) boots **from the card by
default**. It loads `cadr.bit` and `fpga loadb`'s it, then reads the tree,
`zImage` and `rootfs.cpio.uboot` off the FAT partition, then runs `bootz`. No
network is used and none is needed. DHCP is not attempted, and a board with
no cable boots. If the card's `uEnv.txt` sets `serverip`, the loader takes
**the network path** instead. It runs `dhcp`, fetches `uEnv.net` from that
server, and runs the `netcmd` it defines, which fetches the same five files
over TFTP and ends in the same `bootz`. That is this project's own card. The
five files live in `/srv/tftp`, a change to any of them is a copy and a
reset, and the card is never rewritten. On either path a failure loops: a
message, ten seconds, another attempt, for ever. The network path does not
fall back to the card's own copies. A card that names a server is this
project's, and booting stale files silently is the thing this project decided
against. Nothing else is ever booted.

The root filesystem is the initramfs on both paths, unpacked into RAM, so
nothing on the board drifts. **Partition 1 is read by the loader and mounted
READ-ONLY by Linux**, and the one thing the board writes is a disk pack on
partition 2. **Small persistent state, if it is ever wanted, would be a file
on the card that the image reads at start**, not a partition and not a
writable root. An SSH host key is the obvious case, since Dropbear makes a
new one at every boot. It is not built now.

**Three files were two.** Mainline U-Boot's SPL is the first stage, and it
loads U-Boot proper as a second file, `u-boot.img`, from the FAT partition.
Digilent's `BOOT.BIN` carried both, because Xilinx's FSBL reads partitions out
of the boot image. `u-boot.img` is a FIT: U-Boot proper and its device tree
in one flattened-tree container, which is what the generic Zynq SPL loads
(`CONFIG_SPL_LOAD_FIT`). So `mkimage -l` prints nothing for it, and `fdtget
-l u-boot.img /images` is how to look inside. `mksd-buildroot.sh` checks it
that way. It also checks that the U-Boot inside carries `bootcmd=run
cadr_boot` and the `cadr_card` path. Buildroot writes the SPL as `boot.bin`.
The card has it as `BOOT.BIN`, the name the boot ROM looks for.

## Staging, and what to copy where

    echo SERVERIP=<the TFTP server's address> >  boards/arty-z7-20/linux/local.conf   # this project's card; omit for a standalone one
    echo ETHADDR=<the board's MAC>            >> boards/arty-z7-20/linux/local.conf   # optional; the console printed it
    make buildroot                                                  # once; ~25 min the first time
    BIT=<the memory-on board's .bit> boards/arty-z7-20/linux/mksd-buildroot.sh        # stages build/sd/buildroot/
    cp build/sd/buildroot/server/* /srv/tftp/                       # the network path's files

**`BIT` is mandatory and names the bitstream explicitly.** An earlier version
took `build/ddr/cadr_arty.bit` if it was there, and what was there was a
build a day older than the one being served. The script now refuses to run
without `BIT`, and refuses a path that does not exist. It prints the
bitstream's own header --- design name, part, date, time, as Vivado wrote
them into the `.bit` --- so the provenance of every staging is in its log:

    mksd-buildroot: bitstream /srv/tftp/cadr.bit
    mksd-buildroot:   design cadr_arty;UserID=0XFFFFFFFF;Version=2026.1;...  part 7z020clg400  date 2026/09/10  time 07:38:09  4045564 bytes of configuration

`PACKS="a.img 5=b.img"` puts disk packs in the bay on partition 2. An entry
is `unit=path`, or a bare path taking the lowest free unit. Without it the
bay is empty, and the script says so and says how to fill it from the running
board. A file whose size is neither a T-300's nor a T-80's is refused here,
because on the board it would simply not be a drive. `BOOT_MB=<n>` and `PACKS_MB=<n>` are
how big the two partitions are made. The defaults are 512 and 2,560, which
is nine T-300 packs and fits any card of 4 GB and up.

How big a card has to be follows from two numbers. The boot partition holds
seven files that come to 11.3 MB. A T-300 pack is 257 MiB and a T-80 is 68.

| card | `BOOT_MB` | `PACKS_MB` | holds |
|---|---|---|---|
| 1 GB | 64 | 832 | three T-300 packs |
| 2 GB | 64 | 1856 | seven |
| 4 GB | 512 | 2560 | nine, the defaults |

So **1 GB is the absolute minimum**, and one pack fits on far less than that.
**4 GB takes a full bay of eight**, which is 2,056 MiB of packs. Nobody runs
eight. The boot partition is a parameter because half a gigabyte of it on a
1 GB card is most of the card. A bigger card leaves the rest of itself
unused, which costs nothing, and `dd` writes every byte of whatever size is
asked for. `STANDALONE=1` writes `uEnv.txt` without the
server even when `local.conf` names one, for testing the card path from this
host. With no `local.conf` at all the card is standalone. The script says
which path the card it staged will take.

**`ETHADDR`.** Digilent's U-Boot read the board's MAC out of the QSPI flash's
OTP area. Mainline has no such code. So without a MAC in the card's file
U-Boot makes up a random one (`NET_RANDOM_ETHADDR`), and it says so on the
console. That is harmless on the card path. On the network path it means the
DHCP lease pinned to the board's real address is not the one it gets. The
card's `ethaddr` is imported before `dhcp`. U-Boot writes it into the
kernel's tree at boot (`fdt_fixup_ethernet`, on the `ethernet0` alias), and
Linux asks DHCP with the same address. Like `SERVERIP` it lives in
`boards/arty-z7-20/linux/local.conf` and in no committed file.

`build/sd/buildroot/sdcard.img` is the card as one image. It has an MBR and
two primary FAT32 partitions of type `0x0c`, aligned to a megabyte. genimage
makes it from the staged `card/` and `packs/` directories, and it is read
back file by file out of each partition. The partition table itself is read
back and checked rather than assumed. So on the laptop, run

    D=/dev/sdX   # the line that says usb, never from memory
    sudo dd if=sdcard.img of=$D bs=4M conv=fsync

The image is sparse on the build host: 277 MB for a 4.1 GB image with no
pack in it. But `dd` writes every byte, so allow a few minutes.

**THE CARD IS WRITTEN ONCE AND THEN NEVER LEAVES THE BOARD.** That is what
the second partition is for. Adding, replacing or protecting a disk pack is
`scp` to the running board and nothing else, as "The drive bay" below says.
For this project's own board, a change to the loader, kernel or bitstream is
`cp build/sd/buildroot/server/* /srv/tftp/` and a reset. For a standalone
card those live on partition 1, and they can be replaced from the board with

    mount -o remount,rw /mnt/card && cp ... && sync && mount -o remount,ro /mnt/card

which is the one reason that partition is mounted at all. It is mounted
read-only by default. A power cut with the loader writable is a board that
needs a card reader again, and this project's whole point is that it does
not.

## The drive bay

**Partition 2 holds disk packs and nothing else, and the eight names are the
whole of the interface.**

    /mnt/packs/disk-pack-0.img  ... /mnt/packs/disk-pack-7.img

Whichever of the eight exist are the drives that are present. The number in
the name is the unit the machine selects with `DA<30:28>`. A pack is a file
in muir's format, and it is a pack only at exactly a T-300's 269,562,880
bytes or a T-80's 70,937,600. That is also what makes a pack still being
copied in not yet a drive, because every intermediate size is the wrong size.
`cadr-disk-packs` looks at the bay every 250 ms while the machine runs. So
none of the three gestures below needs a reboot, a signal, or the card out of
the board. **None of them is applied in the middle of a transfer** either. A
look that finds the channel walking changes nothing, and is retried a quarter
of a millisecond later.

    copy a pack in            that unit's drive comes ready, with its
                              attention raised, at the instant the last byte
                              lands
    rename a pack out         that unit's drive is taken away --- and
                              anything the machine had written is written
                              into the file under its new name FIRST
    chmod -w a pack           that drive's write-protect switch flips; what
                              the machine had written is flushed onto the
                              pack before it does

From another machine, run these:

    scp band.img root@<the board>:/mnt/packs/disk-pack-0.img     # load unit 0
    ssh root@<the board> mv /mnt/packs/disk-pack-0.img /mnt/packs/kept.img
    ssh root@<the board> chmod -w /mnt/packs/disk-pack-1.img     # write-protect unit 1

It can also be done from the board's own prompt, with `tftp -g -r band.img
-l /mnt/packs/disk-pack-0.img <the server>`. The read-only mark is FAT's own
attribute. Windows sets it from a file's properties and `chmod -w` sets it
from Linux, and they are the same bit.

**RENAMING IS THE WAY TO TAKE A PACK OUT, AND DELETING ONE IS NOT.** A
renamed file is still a file. The descriptor the program holds followed it,
so what the machine had written and the program had not yet given back is
flushed into the file under its new name, and nothing is lost. A deleted file
is nameless, and a flush would go into clusters the kernel frees at the last
close. So the program does not pretend. It says which unit and exactly how
many blocks were lost, and it names them.

    cadr-disk-packs: unit 0: LOST 3 block(s) THE MACHINE HAD WRITTEN and this program
      had not yet put on the pack: the name is gone.  The blocks: 2304 2305 2306.
      RENAME a pack to take it out --- a renamed file keeps its blocks, because this
      program's descriptor follows it and the flush lands there; a deleted one cannot.

For the same reason, **do not copy a new pack over one that is in use**.
`scp` onto an existing name writes the new pack over the old one where it
lies, and the old pack's words are then the wrong words to flush into it. The
program sees the size change, takes the drive away, reports the blocks lost,
and says the file was written over where it lies. Rename the old one out
first, then copy the new one in.

**With no pack at all the machine is not stuck.** It is waiting. The boot
PROM polls its drive's status in `AWAIT-DRIVE-READY`, so copying a pack in
should let it go on with no reboot. This is *expected rather than measured*.
The program's own check holds the drive coming present and the attention
being raised, and the board has not yet been asked to do it.

**FAT32 for both partitions, deliberately.** The card must be readable and
writable from Windows, which cannot write ext4. What it costs is the journal.
What makes that bearable is that a pack is a working copy whose master is in
the archive, and that the partition it would hurt to lose --- the loader's ---
is mounted read-only.

## What happens at power-on, and what the console must show

1. **The boot ROM loads `BOOT.BIN`**, which is U-Boot's SPL. It runs
   `ps7_init()` --- MIO, PLLs, clocks, DDR, peripheral resets, the 660
   operations. It prints its banner, loads `u-boot.img` from the FAT
   partition, runs `ps7_post_config()`, and jumps to U-Boot.
   `ps7_post_config()` writes the level shifters and the fabric resets, which
   is what makes `S_AXI_HP0` live.

       U-Boot SPL 2026.01 (...)
       Silicon version:	3
       Trying to boot from MMC1

   `Silicon version: 3` is this board, which is 3.1; `linux.md` says why the
   `else` branch is the right one. The SPL says nothing more when the load
   succeeds. `spl: error reading image u-boot.img` is the card without the
   second file. No banner at all, or the ROM parking (`0x200A` over JTAG), is
   the card not latched.

2. **U-Boot proper** prints `U-Boot 2026.01`, `CPU: Zynq 7z020`,
   `Silicon: v3.1` and `DRAM: ECC disabled 512 MiB`. Unless `uEnv.txt`
   carries `ethaddr`, it also prints

       Warning: ethernet@e000b000 (eth0) using random MAC address - xx:xx:...

   Then come two seconds of `Hit any key to stop autoboot`. Then `bootcmd`
   runs `cadr_boot`. That loads and imports `uEnv.txt` if there is one, and
   prints `cadr: no uEnv.txt on the card; booting from the card` if there is
   not. Then it looks at `serverip`.

3. **The card path** runs when there is no `serverip`. It prints seven
   `N bytes read in M ms` lines from the FAT partition. `cadr.bit` comes with
   `fpga loadb`'s header (`design filename = "..."`, `part number =
   "7z020clg400"`) and U-Boot's fixed `INFO:post config was not run, please
   run manually if needed`. That message is not a fault, because the driver
   has just written the level shifters and the fabric resets itself. The CADR
   starts here. Then come the tree, `zImage`, `rootfs.cpio.uboot`, and

       ## Loading init Ramdisk from Legacy Image at 04000000 ...
       ## Flattened Device Tree blob at 01f00000
       Starting kernel ...

   There is no `DHCP`, no `TFTP` and no `Filename` line anywhere.

   **The network path** runs when `serverip` is set. It prints `cadr:
   uEnv.txt names a server; fetching over TFTP` and `DHCP client bound to
   address ...`, then `Filename 'uEnv.net'`. The same five files follow as
   `Filename '...'` / `Bytes transferred = N` pairs. The `fpga loadb` lines
   come after `cadr.bit`, and the same three lines go into the kernel.

4. **If anything fails** --- a file missing on the card, the server down, the
   cable out --- the board prints the line `cadr: the boot did not happen;
   trying again in 10 s`. Another attempt follows ten seconds later, for as
   long as it takes. U-Boot's banner does **not** reappear, because this is a
   loop and not the stepping stone's `reset`. A missing card file is named by
   `load` ("`** Unable to read file zImage **`") just before the message.

5. **Linux**. The two things the first boot established are in its first
   lines and at its prompt:

       OF: reserved mem: 0x18000000..0x1fffffff (131072 KiB) nomap non-reusable cadr@18000000

   That line is the tree reserving the CADR's memory **with `no-map` and
   without `mem=384M`**. That is the thing the 4.9 kernel died on, and this
   kernel does not (measured 10 September). Reading 6.19.14 says why.
   `drivers/of/of_reserved_mem.c` marks the region `MEMBLOCK_NOMAP`.
   `arch/arm/mm/mmu.c`'s `map_lowmem` and `arch/arm/kernel/setup.c`'s
   `request_standard_resources` both walk `for_each_mem_range`, which skips
   it. So it is neither mapped nor "System RAM".

   Then comes the login. `cadr login:` appears on the console, and the
   account is `root` / `root`. That is the stepping stone's password, kept
   because the board is on a private LAN, and set in the defconfig as
   `BR2_TARGET_GENERIC_ROOT_PASSWD`. SSH works from the address DHCP gave it,
   without the `ssh-rsa` incantation the 2018 Dropbear needed. On the card
   path Linux still asks DHCP for an address (`BR2_SYSTEM_DHCP="eth0"`). With
   no cable it waits its 15 s and goes on to the prompt without one.

At the prompt the same checks are run as above. This is what they said
on 10 September under this image:

    cat /proc/device-tree/model                  Zynq Arty Z7 Development Board  (kept on purpose)
    ls /proc/device-tree/reserved-memory/        cadr@18000000
    grep "System RAM" /proc/iomem                00000000-17ffffff   -- from the node alone, no mem=
    grep MemTotal /proc/meminfo                  381472 kB
    cat /proc/cmdline                            console=ttyPS0,115200 earlycon   -- and nothing about memory
    devmem 0xE000A068; devmem 0xE000A06C         0x01008100 twice, WITHOUT the APER_CLK_CTRL line first

**The `APER_CLK_CTRL` line is gone because this kernel has no power
management.** `drivers/gpio/gpio-zynq.c` gates the block's clock through
runtime PM. `zynq_gpio_runtime_suspend()` is `clk_disable_unprepare()`, and
the driver drops its reference after probe. So with `CONFIG_PM` the block is
unclocked whenever no GPIO line is in use, and the EMIO registers read zero.
That is what 4.9 did. `linux.config` builds without `PM`, because nothing on
this board sleeps. The runtime-PM calls are therefore stubs, and the clock
the driver takes at probe stays on. This is measured: the counters read from
Linux with no clock trick. The alternative kept in `linux.config`'s header is
to read the lines through the driver, where gpiochip lines 54..117 are EMIO
0..63.

**All of this is verified on the built images.** The kernel's final
`.config` has `PM`, `SUSPEND`, `CPU_IDLE` and `STRICT_DEVMEM` off. It has
`DEVMEM`, `GPIO_ZYNQ`, `INPUT_EVDEV`, `USB_HID`, `USB_CHIPIDEA_HOST`,
`MACB`, `REALTEK_PHY`, `MMC_SDHCI_OF_ARASAN`,
`SERIAL_XILINX_PS_UART_CONSOLE` and `FPGA_MGR_ZYNQ_FPGA` on, and no `DRM` or
`FB`. The tree, decompiled, carries `cadr@18000000 { reg = <0x18000000
0x8000000>; no-map; }`, five devices enabled (uart0, gem0, sdhci0, qspi, usb0
as host), `serial0` on `serial@e0000000`, `ps-clk-frequency` 50,000,000, the
PHY at address 1 and no `amba_pl`. U-Boot's own tree carries the same
reservation. The SPL is 125,216 bytes against its 196,608-byte ceiling, and
it links `ps_init_gpl.o` from the generated routine. The SPL's cut-down tree
holds exactly the serial, QSPI, MMC, SLCR and timer nodes. The kernel also
kept `CONFIG_VT` on. It is not user-selectable without `EXPERT` and defaults
to yes, and with no framebuffer it is a dummy console nobody sees.
`console=ttyPS0` is what decides where the messages go.

**And there is one thing to know about `/dev/mem` on the reserved region**,
read out of the code. `mmap` works, and opened `O_SYNC` as BusyBox's `devmem`
does it gives an uncached mapping (`arch/arm/mm/mmu.c`,
`phys_mem_access_prot`). `read()` and `write()` on `/dev/mem` over
`0x18000000..0x1fffffff` are expected to fail with `EFAULT`. The kernel
reaches them through the linear map, and a `no-map` region has none.
`drivers/char/mem.c` copies with `copy_from_kernel_nofault`, so it fails
rather than oopses. Programs that read the CADR's memory from Linux mmap it.
`dd if=/dev/mem` does not work there. The board confirms or corrects this.

## The USB port: a keyboard and a mouse

The Arty Z7-20's USB is the processing system's, not the fabric's.
Digilent's tree has `usb0`: the Zynq ChipIdea controller at `0xe0002000`,
`compatible = "xlnx,zynq-usb-2.20a", "chipidea,usb2"`, `phy_type = "ulpi"`.
It is enabled as a host (`dr_mode = "host"`) with its PHY's reset on MIO 46.
The sources are `pcw.dtsi`'s `usb-reset = <&gpio0 46 0>` and
`boards/arty-z7-20/vivado/ps7_config.tcl`'s `PCW_USB0_RESET_IO {MIO 46}` and
`PCW_USB_RESET_POLARITY {Active Low}`, with the controller's twelve ULPI
lines on MIO 28..39. Digilent's reference manual could not be read, because
their site answers automated fetches with 403, as `linux.md` already records.
So the PHY's part number is not asserted here. Our tree writes the same port
the way mainline's `zynq-zybo-z7.dts` writes the same part: `usb0` as host,
and the PHY a `usb-nop-xceiv` with `reset-gpios = <&gpio0 46
GPIO_ACTIVE_LOW>`. There is **one deliberate difference**. The controller
names its PHY with `phys`, not the deprecated `usb-phy` every mainline Zynq
tree still carries. The kernel has the controller in host mode over EHCI, HID
over USB, and evdev. The root filesystem has `evtest`. There is no display
and no DRM, because HDMI on this board is a fabric matter.

**Why `phys`: the port was dead with `usb-phy`, measured on the board 10
September.** `chipidea-usb2` bound and created `ci_hdrc.0`. `phy0` bound.
`ci_hdrc.0` never did, and dmesg said nothing --- no `ci_hdrc`, no root hub,
no error, no defer. The reason was read out of 6.19.14.
`drivers/usb/phy/phy-generic.c` registers at `subsys_initcall`, and
`drivers/gpio/gpio-zynq.c` at `device_initcall`. So the PHY's first probe
asks for its reset GPIO before gpio0 has a driver, and is deferred. The
ChipIdea core (`drivers/usb/chipidea/core.c`, `ci_hdrc_probe`) then probes
synchronously at `device_initcall` and looks for a PHY three ways: a generic
PHY (`CONFIG_GENERIC_PHY` off, `-ENOSYS`); a **`phys`** phandle (absent with
`usb-phy`, `-ENODEV`); then "any registered USB2 usb_phy". With `phy0` still
deferred, that is `-ENODEV` too, not `-EPROBE_DEFER`. So the probe
takes the one exit with no `dev_err`: `ret = -ENXIO`, permanent. `phy0` binds
later from the deferred-probe workqueue, to no one. Of the three lookups,
only the `phys` phandle answers `-EPROBE_DEFER` for a PHY not yet registered
(`drivers/usb/phy/phy.c`, `__of_usb_find_phy`). So with `phys` the core waits
for `phy0` and binds after it. The binding says the same
(`chipidea,usb2-common.yaml`: `usb-phy` "deprecated: true. Use phys
instead"). Whether mainline's own Zybo trees win or lose this race is not
known here. Ours does not race. `CONFIG_DEBUG_FS` is on now, so that
`/sys/kernel/debug/devices_deferred` and the PHY's ULPI registers can be read
next time. Buildroot's `fstab` does not mount it, so run
`mount -t debugfs none /sys/kernel/debug` first.

**What it costs was measured on the built objects with `arm-linux-size`.**
The USB host stack itself --- core, EHCI, the ChipIdea glue, the nop PHY, and
USB mass storage --- is 229,947 bytes of text and data in `vmlinux`. The
keyboard-and-mouse addition on top --- HID core, the generic and quirk HID
drivers, the USB HID transport, the input core and evdev --- is 129,569
bytes. `vmlinux` compresses 2.03:1 into this `zImage`, so together they are
about 175 KB of the 3.34 MB `zImage`. `CONFIG_DEBUG_FS`, added after the
probe-order finding, cost another 80,800 B of `zImage` (3,256,232 to
3,337,032). `evtest` is 34,144 bytes in the root filesystem, about 15 KB in
the compressed initramfs.

To prove it on the board, look first with nothing plugged in. The root hub
must be in dmesg, in this order (the strings are `ehci-hcd.c`'s, `hcd.c`'s
and `hub.c`'s):

    ci_hdrc ci_hdrc.0: EHCI Host Controller
    ci_hdrc ci_hdrc.0: new USB bus registered, assigned bus number 1
    ci_hdrc ci_hdrc.0: USB 2.0 started, EHCI 1.00
    usb usb1: New USB device found, idVendor=1d6b, idProduct=0002, bcdDevice= 6.19
    usb usb1: Product: EHCI Host Controller
    usb usb1: SerialNumber: ci_hdrc.0
    hub 1-0:1.0: USB hub found
    hub 1-0:1.0: 1 port detected

and `/sys/bus/platform/devices/ci_hdrc.0/driver` points at `ci_hdrc`. Then
plug a keyboard in and watch the console:

    usb 1-1: new low-speed USB device number 2 using ci_hdrc
    usb 1-1: New USB device found, idVendor=xxxx, idProduct=xxxx ...
    input: ... as /devices/soc0/axi/e0002000.usb/ci_hdrc.0/usb1/1-1/.../input/input0
    hid-generic 0003:XXXX:XXXX.0001: input: USB HID v1.11 Keyboard [...] on usb-ci_hdrc.0-1/input0

Then run `ls /dev/input/`, which shows an `event0`, and an `event1` for a
mouse. Then run

    evtest /dev/input/event0

which lists the device's capabilities and then prints one `Event: time ...,
type 1 (EV_KEY), code 30 (KEY_A), value 1` per key press and release. Without
`evtest`, `hexdump -C /dev/input/event0` shows the same 16-byte records. The
root hub appearing is the controller and the PHY working.

**VBUS is the board's own affair, and it was measured.** With the root hub up
and a keyboard in, nothing enumerated. The PHY's ULPI `OTG Control` read
`0x27`. `devmem 0xE0002170 32 0x600B0060` --- DrvVbus and DrvVbusExternal set
through the controller's ULPI viewport --- made it `0x67`, and within a
second the keyboard enumerated with three input devices. The connector's
power switch is driven by the PHY, and Digilent's tree told their PHY driver
`drv-vbus`. Mainline has nothing that sets those bits for a ULPI PHY under
ChipIdea. The core never writes `OTG Control`, the nop PHY's `set_vbus` is a
regulator this board has none of, and the in-tree ULPI-bus PHY drivers are
Qualcomm's and TI's. So the root filesystem carries one init script,
`/etc/init.d/S15usbvbus`, from
`boards/arty-z7-20/linux/buildroot/board/arty-z7-20/rootfs-overlay/`. It
waits for the root hub and does that write once. Then it reads the register
back and prints

    usbvbus: OTG Control 0x67 (DrvVbus set for the host port)

on the console during init, before the network comes up. USB input is at the
very end of the project, so this is the smallest correct fix and stops here.
If it ever moves into the kernel, a ULPI-bus driver for this PHY setting
`OTG Control` at probe is the shape. The register arithmetic is in the
script's header with its sources: the viewport at op base `0x140` + `0x30`,
`0x0B` = OTG Control set, bits 5 and 6.

## What is deliberately not in this image

- **No `mem=384M`, no `cma=32M`, no `uio_pdrv_genirq.of_id`** on the command
  line. The first is now measured unnecessary. The second was for Digilent's
  42 MB ramdisk against a 128 MB CMA pool. The third was for PL peripherals
  the tree no longer has.
- **No saved environment.** U-Boot's environment is built in and lives
  nowhere (`ENV_IS_NOWHERE`, and the generic configuration's `uboot.env` on
  the card is off), as the 2017 build's was. A boot decided from a file
  nothing in the repository sees was the thing to avoid. `uEnv.txt` decides
  only which of the two paths is taken, and supplies two addresses.
- **No fallback from the network path to the card.** The reason is above.
- **No `fdt_high` and no `initrd_high`.** The reason is in `uEnv.net`.
- **No I2C, no SPI0, no FCLK.** They are off in
  `boards/arty-z7-20/vivado/ps7_config.tcl`, and off here.
- **No display, no DRM, no framebuffer.** HDMI on this board is the fabric's.
- **No writable storage from Linux but the drive bay.** Partition 1 is read
  by U-Boot and mounted read-only, and partition 2 holds disk packs and
  nothing else. There is no writable root and no saved state.
- **No Vivado and no Xilinx tool of any kind** is needed to build the image.
  The one Xilinx-derived input is
  `boards/arty-z7-20/vivado/ps7_init.ops`, which is committed.

## The stepping stone: Digilent's image, superseded

Everything from here to the end describes the boot as it ran for the first
day, on Digilent's 2017.4 PetaLinux image with a hand-edited device tree. It
is kept as the record of what was learned on it. It is not how the board
boots now.

### The pieces, and where each one lives

    the microSD card        in the board          BOOT.BIN, image.ub, uEnv.txt
    the TFTP server         the build host, /srv/tftp   uEnv.net, cadr.bit, system.dtb
    the serial console      the build host, over the board's USB cable
    the card writer         the laptop                  the build host has no card reader

The card is written **once**. Its `uEnv.txt` is one line that fetches
`uEnv.net` from the TFTP server and runs the command in it. So the boot
command, the CADR's bitstream and the device tree all live in `/srv/tftp`. A
change to any of them is a `cp` there and a reset, and the card is never
touched again. The kernel and the root filesystem are Digilent's, read out of
the `image.ub` already on the card.

### What happens at power-on

1. **The boot ROM reads the boot-mode jumper**, sees SD, and loads
   `BOOT.BIN` from the card's first FAT partition. That file is Digilent's.
   It holds the first-stage boot loader, which runs `ps7_init` so that DDR
   comes up, a bitstream for the fabric, and U-Boot. **The bitstream inside
   it is Digilent's stock design, not the CADR.** An SD boot displaces
   whatever was loaded over JTAG. So until our own `BOOT.BIN` exists, booting
   Linux and running the CADR are two different sessions on the board.

2. **U-Boot reads `uEnv.txt` from the card** and runs the one command in it,
   which fetches `uEnv.net` from the TFTP server and runs the `netcmd` it
   defines. That command fetches `cadr.bit` and **loads it into the fabric**
   with `fpga loadb`, displacing Digilent's design. It fetches `system.dtb`.
   It reads `image.ub` off the card. It boots the kernel and root filesystem
   inside it under our tree, with `mem=384M cma=32M` on the kernel's command
   line. The CADR starts the moment the fabric is configured, and is running
   its boot PROM out of DDR3 before Linux has finished uncompressing. The
   board's own address comes from DHCP, pinned on the DHCP server to the
   board's MAC, which the console prints. The TFTP server's address is in the
   card's file, and a DHCP reply cannot overwrite it (`linux.md` says why).

3. **If the fetches succeed**, Linux comes up seeing **384 MB** beside the
   running CADR. `mem=384M` is what keeps it off the CADR's region. The
   tree's `reserved-memory` node names the same region, so
   `/proc/device-tree` says whose it is. The served tree has Digilent's
   `amba_pl` removed --- those are the peripherals of the design `cadr.bit`
   displaced --- so Linux probes nothing that is no longer there.
   `boards/arty-z7-20/linux/uEnv.net` explains why it is the command line and
   not the node that does the work on this kernel.

4. **If the fetch fails** --- server down, cable out, wrong network --- the
   board waits, and never boots anything else. Left to itself, U-Boot would
   fall through to `image.ub` with Digilent's own device tree and 512 MB,
   which is a Linux that owns the CADR's memory. Mete decided the board must
   never do that. The card's file sets `cp_kernel2ram=reset`, replacing the
   copy step the fallback itself would run. So a fetch that fails ends in
   `resetting ...`, and another attempt follows ten seconds later, for as
   long as the server is away. This was measured 10 September on the real
   boot path, with the server stopped. A `|| reset` on the end of the fetch
   line had been tried first, and it did not fire on that path
   (`boards/arty-z7-20/linux/uEnv.txt.in` says why).

   Digilent's stock boot was run once for comparison before that decision,
   from the first card. It gave a login with `Memory: 335116K/524288K`,
   against `303564K/393216K` on the reserved boot.

5. **The kernel's root filesystem is built into `zImage`** as an initramfs.
   So there is no second partition, and nothing on the card is mounted by
   Linux. It boots to a shell on the serial console.

### What to look for on the console

The console decides which boot happened, in its first seconds:

    the boot          `Filename 'uEnv.net'` ... `Filename 'system.dtb'` ...
                      `Bytes transferred = 26265`, `reading image.ub`, then
                      `Kernel command line: ... mem=384M cma=32M`
    no server         `TFTP server died; starting again`, `resetting ...`,
                      and U-Boot's banner again ten seconds later; never
                      `reading image.ub` before a `uEnv.net` was fetched

Linux takes the address the DHCP server gives it and starts Dropbear. So the
board can be reached by SSH as `root` with Digilent's default password
`root`, which is PetaLinux 2017.4's and was verified 10 September. That
Dropbear offers only an RSA host key, which current clients refuse by
default:

    ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@<IP>

The root filesystem is in RAM, so anything changed there is gone at the next
reset. That includes keys and passwords.

Then, at the prompt, four things say the reservation is real and the CADR ran:

    cat /proc/device-tree/model                       Zynq Arty Z7 Development Board
    ls /proc/device-tree/reserved-memory/             cadr@18000000 (reserved boot only)
    grep "System RAM" /proc/iomem                     00000000-17ffffff
    grep MemTotal /proc/meminfo                       380360 kB, against 512 MB under Digilent's tree
    devmem 0xF800012C 32 $(( $(devmem 0xF800012C) | 0x400000 ))   # this kernel gates the GPIO block's clock; turn it on
    devmem 0xE000A068; devmem 0xE000A06C               0x01008100 twice: 256 reads and 256 writes,
                                                       asked and answered, at the PS7's boundary

Those four lines are what the board printed on 10 September. The third is
the one that matters, because it says the kernel does not have the region at
all.

### The steps, in order

Everything up to the power-on has been done once, on 10 September, and is
recorded in `linux.md`. The steps are here so it can be done again.

**On the build host, once.** The bitstream is the memory-on board. It is
built with `DDR=1 OUTDIR=build/ddr vivado -mode batch -source
boards/arty-z7-20/vivado/bitstream.tcl` and copied to `/srv/tftp/cadr.bit`.
The one served on 10 September was built at `1446bf6`.

    sudo apt install tftpd-hpa                       # serves /srv/tftp on UDP 69
    sudo chown $USER /srv/tftp                       # so the files can be refreshed without root
    sudo usermod -aG dialout $USER                   # so the console can be read
    echo SERVERIP=<the TFTP server's address> > boards/arty-z7-20/linux/local.conf   # gitignored; mksd.sh fills it into uEnv.txt

`boards/arty-z7-20/linux/mksd.sh` stages `build/sd/`. Then run:

    cp build/sd/server/* /srv/tftp/ && cp build/ddr/cadr_arty.bit /srv/tftp/cadr.bit
    curl -o /dev/null tftp://<the TFTP server's address>/system.dtb   # the server answers

**On the laptop, once.** Copy
`build/sd/reserved/{BOOT.BIN,image.ub,uEnv.txt}` there, insert the card, and
identify it by `lsblk` --- the line that says `usb`, never from memory. It is
`/dev/sda` on the laptop, and `/dev/sda` is the system disk on the build
host. Then, with `D` set to that device:

    sudo umount ${D}?* 2>/dev/null
    sudo sfdisk --wipe always $D <<'EOF'
    label: dos
    start=2048, type=c, bootable
    EOF
    sudo mkfs.vfat -F 32 -n BOOT ${D}1
    M=$(mktemp -d) && sudo mount ${D}1 $M
    sudo cp BOOT.BIN image.ub uEnv.txt $M/
    sudo sync && sudo umount $M && rmdir $M

That makes one FAT32 primary partition, MBR, type `0x0c`, marked bootable.
That is what the boot ROM looks for, and what U-Boot's `fatload mmc 0`
resolves to. The tree and the boot command do **not** go on the card. **Push
the card in until it clicks.** A card that is in the slot but not latched
reads as no card, and the chip then parks in its boot ROM with error code
`0x200A`. That was seen over JTAG on the first try.

**At the board.** Put the card in the microSD slot. Set the boot-mode jumper
to SD, reading the designator off the silkscreen, because it is deliberately
not written here. Put Ethernet on the TFTP server's subnet. Connect USB to
the build host; that cable is both JTAG and the console.

**Every boot.** Keep the console log running. It survives the board being
power-cycled. The port is named by its USB identity rather than by a
`ttyUSB` number, because that number changes when the board is replugged
while something still holds the old one:

    boards/arty-z7-20/linux/console.py /dev/serial/by-id/usb-Digilent_Digilent_Adept_USB_Device_003017A6FFE5-if01-port0 build/console.log &

Then reset the board. **Nobody has to be at it.** `rst -srst` from `xsdb`
over JTAG restarts the boot ROM exactly as the SRST button does, and the USB
link stays up, so the log is continuous:

    ~/Xilinx/2026.1/Vivado/bin/xsdb -eval 'connect; targets -set -filter {name =~ "APU*"}; rst -srst'

From reset to a login shell is about two and a half minutes, most of it the
SSH key generation waiting for entropy. The tree fetch is instantaneous. The
47 MB kernel fetch the first card did took 6 s at 7--8 MB/s, and is not done
any more.

### What this does not do yet

- **Anything with the reserved memory.** Linux leaves it alone. Nothing yet
  puts a disk pack in it or reads a display out of it.
- **Boot without the TFTP server.** A card holding `uEnv.net`'s command and
  `system.dtb` itself would do it, at the cost of a card write per change.
