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
the fabric, Linux 6.19 with the reservation honored by the tree alone, and a
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
    the card    one FAT32 partition  cadr-arty-z7-20.zip, about 8.1 MB, 12,500,992 B
                                     on the card.  The user formats the card and unpacks
                                     the zip onto it.  There is no disk image

The kernel's, the loader's and the root filesystem's sizes are of the 10
September builds on the build host, and the zip's are of the current one. The whole
thing --- toolchain download, host tools, U-Boot, kernel, root filesystem ---
took 25 minutes of wall clock on 16 cores. `make buildroot` after a change
takes minutes. **Buildroot does not watch our files.** After editing anything
under `boards/arty-z7-20/linux/buildroot/`, run `make buildroot-rebuild`. It
reconfigures U-Boot, the kernel and every package of ours the board's
configuration selects, and finishes the image.

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
reading it matters. Mainline U-Boot honors a `reserved-memory` node in its
*own* tree for its own relocation (`common/memtop.c`) and for where it puts
the fdt and the ramdisk (`lib/lmb.c`). It does not rewrite the kernel's
memory node, because `ARCH_FIXUP_FDT_MEMORY` is off in `xilinx_zynq_virt`.
So the loader stays out of the CADR's region by the same node that keeps the
kernel out. That closes the hazard `linux.md` recorded for this U-Boot ---
"the reserved-memory node binds the kernel, and not the loader".

## SPL or FSBL, and why the drawing still says U-Boot

These three names get used for overlapping things, so this is the one place
that says which is which.

**SPL** is Secondary Program Loader. It is U-Boot's own name for its first
stage: a cut-down U-Boot small enough to run out of on-chip memory, whose job
is to bring the DDR up and then load the full loader.

**FSBL** is First Stage Boot Loader. That is Xilinx's name for the same job on
a Zynq, and for the program Xilinx ships to do it.

**On this board they are the same thing, and the thing is an SPL.** We use
U-Boot's SPL as the first stage, so the SPL plays the FSBL's role. We do not
use Xilinx's FSBL, and Digilent's was the stepping stone and is gone. So an
SPL is what is actually in `BOOT.BIN`, and calling it an FSBL would send
somebody looking for Xilinx FSBL sources that this project does not have.

Use SPL when you mean the first stage. Use FSBL only when you mean Xilinx's
program, which is not here.

### What is ours inside the loader

The loader is mainline U-Boot and this project does not write it. Four files
in it are ours, and they are the reason this project carries a licensing
note about GPL compatibility:

    ps7_init_gpl.c                  the start-up routine: 660 operations,
                                    generated here and byte-identical to the
                                    one Vivado writes
    cadr.env                        the environment
    zynq-arty-z7-20.dts             the device tree
    zynq-arty-z7-20-u-boot.dtsi     the loader's own additions to it

The first of those is the board bring-up. Without it the chip has no memory
and nothing runs at all.

### The drawing says both, in two boxes

This was settled with no change to the label, and with a change of shape that
resolves it instead. The drawing carries it now: an orange box for U-Boot with
a small green box inside it saying SPL.

The worry was that a color beside the word "U-Boot" reads as a claim that this
project wrote U-Boot. It does not. On that drawing a block's color answers
whose work it is, and nothing else.

Three single-word replacements were considered first and each failed for its
own reason. "boot: SPL, ps7_init" does not fit a narrow rotated strip. "boot
loader" and "loader" name a category rather than this component. "SPL" alone is
specific but names only the first stage, where the block covers both.

The label is stacked one letter to a line rather than rotated. The strip is 54
pixels wide and 93 tall below the first-stage box, and six lines fill 84 of it.
A rotated label makes the reader tilt their head and a stacked one does not.

Two boxes say what one word could not. Orange is the drawing's marker for
another project's program carried onto the board, which is what muir and ozd
already carry, so the loader is marked as upstream. The green box inside it is
the first stage, and it is green because the start-up routine that stage runs
is generated here.

**The split is a little kind to us and it is worth knowing why.** Only one of
the four files above lives in the first stage. `ps7_init_gpl.c` is compiled
into the SPL, and `cadr.env` and the two device trees are read by U-Boot
proper, which is the orange box. So the green box understates what is ours by
three files, and no arrangement of two boxes on a strip 54 pixels wide will
say that. This paragraph is where it is said instead.

## The card, and the two ways it boots

**The card is one FAT32 partition in an MBR, and everything is on it.**

    /           BOOT.BIN (U-Boot's SPL), u-boot.img, uEnv.txt (optional),
                README.TXT, fpgarc, muirrc, and `clock` once the board has
                shut down cleanly once
    arty-z7-20/ cadr.bit, zynq-arty-z7-20.dtb, zImage, rootfs.cpio.uboot
    packs/      disk-pack-0.img .. disk-pack-7.img, whichever exist, and
                muir-cc.img where a debugger runs; neither the boot ROM nor
                U-Boot ever looks here
    sys/        the band's Lisp sources, served read-only
    site/       the band's site configuration, served read-write
    /srv/tftp/arty-z7-20
                uEnv.net, cadr.bit, zynq-arty-z7-20.dtb, zImage,
                rootfs.cpio.uboot --- this project's convenience, the same
                five files, in a directory named for the board

`sys/`, `site/` and `packs/` are on every card even when they are empty,
because an empty folder with a name on it is what tells somebody where a band
goes.

U-Boot's built-in environment (`cadr.env`) boots **from the card by
default**. It loads `arty-z7-20/cadr.bit` and `fpga loadb`'s it, then reads the
tree, `zImage` and `rootfs.cpio.uboot` out of the same folder on the FAT
partition, then runs `bootz`. No
network is used and none is needed. DHCP is not attempted, and a board with
no cable boots. If the card's `uEnv.txt` sets `serverip`, the loader takes
**the network path** instead. It runs `dhcp`, fetches `arty-z7-20/uEnv.net`
from that server, and runs the `netcmd` it defines, which fetches the same
five files over TFTP and ends in the same `bootz`. That is this project's own
card. The five files live in `/srv/tftp/arty-z7-20`, a change to any of them
is a copy and a reset, and the card is never rewritten. On either path a
failure loops: a message, ten seconds, another attempt, for ever. The network
path does not fall back to the card's own copies. A card that names a server
is this project's, and booting stale files silently is the thing this project
decided against. Nothing else is ever booted.

The root filesystem is the initramfs on both paths, unpacked into RAM, so
nothing on the board drifts. **The card is read by the loader and mounted
READ-WRITE by Linux at `/mnt/card`**, and the things the board writes on it
are a disk pack in `packs/`, the band's `site/` tree, and the `clock` file at
the root. **Small persistent state, if it is ever wanted, is a file on the
card that the image reads at start**, not a partition and not a writable root.
`clock` is already that: the board has no clock of its own, so the disk pack
program writes the time there at a clean shutdown and reads it at the next
boot. An SSH host key would be the next case, since Dropbear makes a new one
at every boot. It is not built now.

### One partition, and the protection that was given up for it

**The loader, the kernel and the root filesystem are no longer behind a
read-only mount, and that is a protection given up deliberately rather than
overlooked.** The card used to have two partitions. The first held the loader
and the boot files and Linux mounted it read-only, so that the machine's
constant writing to a disk pack could not damage them; the second held nothing
but packs and was the only thing mounted for writing. With one partition the
machine writes its pack into the same filesystem the boot files are in, and a
power cut in the middle of a write can damage any of them. FAT32 has no
journal, so nothing puts them back.

**What makes that bearable is the remedy, and it is the reason the trade is
worth taking.** A damaged boot file is repaired by unpacking the board's zip
onto the card again, over the top of what is there, from any machine with a
card reader. The two-partition arrangement was an image, and repairing it
meant rewriting the whole card with a tool that destroys the wrong disk if the
device name is wrong. So the failure that is now possible is recovered in a
minute by a copy, and the failure that was possible before was recovered by
the one command in this project that can erase somebody's system disk.

A pack is a working copy whose master is in the archive, and the boot files
are in a zip that is still on the machine that wrote the card. Nothing on the
card is the only copy of itself.

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

### One server, more than one board

**A board's served files live in a directory on the server named as the
board's own directory under `boards/` is.** The Arty Z7-20's are in
`/srv/tftp/arty-z7-20` and the Cora Z7-07S's in `/srv/tftp/cora-z7-07s`. The
reason is that every board's five files carry the same five names. A flat
server root would hand the Cora the Arty's `cadr.bit`, which is a bitstream
for a different part. The part refuses it, the fabric stays empty, and
nothing on the console says which file was wrong.

The rule is carried in two places and both are checked when a card is staged.
The U-Boot compiled for a board fetches `<board>/uEnv.net`, and that served
`uEnv.net` names the other four files the same way. Every path inside
`uEnv.net` is relative to the server's root rather than to the file's own
place, so a copy of it anywhere on that server still fetches the right five
files.

**And the card mirrors the server.** The same four files sit in a folder of
the same name on the card, and the board's U-Boot loads them from there. A
card belongs to one board, so the folder is not what keeps two boards' files
apart on it. What it buys is that the card and the server hold the same thing
in the same place, and that a file copied from one to the other keeps its
path. It is also what makes a card built for the wrong board say so: the
loader asks for its **own** folder, so a Cora handed the Arty's card prints
`** Unable to read file cora-z7-07s/zImage **` within a second of power-on and
goes on saying it every ten seconds.

**Some files stay at the root of the card, because their names are not ours to
move.** `BOOT.BIN` is what the boot ROM reads from the root of the first FAT
partition and nowhere else. `u-boot.img` is what the SPL asks for by that name
at the root. On the DE25-Nano the first-stage loader is in the QSPI flash and
asks for `u-boot.itb` the same way, and there is no `BOOT.BIN` at all.
`uEnv.txt` is imported by U-Boot before any board name is known, on both board
shapes, and it is the file that decides which of the two paths the board
takes, so it cannot be behind a name that path has not chosen yet.

**Three more are at the root because that is where a person looks.**
`README.TXT`, `fpgarc` and `muirrc` are the files somebody edits with the card
in a reader, so they are beside the loader's rather than buried. What differs
between two boards' cards in the two files of flags is the Chaosnet address
and, on the DE25-Nano, the window addresses; the staging writes those from
each board's own `local.conf`.

**The packs keep a folder of their own, `packs/`.** A pack, unlike everything
else on the card, belongs to the machine rather than to the part, and the
folder is what says so. Whichever of `disk-pack-0.img` to `disk-pack-7.img`
are in it are the drives that are present, and nothing looks for a pack
anywhere else.

**A card written before this change does not boot a U-Boot built after it**,
and the staging refuses that pair rather than letting it reach a board. The
card script checks that the U-Boot inside `u-boot.img` loads
`<board>/cadr.bit` and the other three the same way, names the file it wanted,
and says that `make buildroot-rebuild` is what rewrites the loader. The zip is
then read back, file by file, against the directory it was made from, so that
what a user unpacks is what was staged.

**The board this project runs crosses the change in two steps, and neither
needs a card reader.** Its U-Boot predates the rule and fetches `uEnv.net`
from the server's root. The first step is to put its five files under
`arty-z7-20/` and to copy the same `uEnv.net` to the root as well. Its
`netcmd` then names `arty-z7-20/cadr.bit` and the rest, so the running board
follows into the directory on its next reset with no card change at all.
Create the directory and fill it before copying the root's file, or the board
loops saying which file it could not fetch. The second step is the next time
that card's `u-boot.img` is written: the U-Boot on it then fetches
`arty-z7-20/uEnv.net`, the root's copy can go, and no board fetches from the
root any more.
Both steps were taken on 14 September: the card was rewritten with a U-Boot
that fetches `arty-z7-20/uEnv.net`, and the root's copy was removed.

**A change to a board's `cadr.env` reaches a card only after U-Boot has been
rebuilt.** Buildroot does not watch this repository's files, so a plain `make
buildroot` leaves the old environment in place once the package has a build
stamp. `make buildroot-rebuild` forces it. The staging refuses a `u-boot.img`
that still fetches `uEnv.net` from the root and says so by name, so a card
built from a stale U-Boot cannot be handed to a board by accident.

## Staging, and what to copy where

    echo SERVERIP=<the TFTP server's address> >  boards/arty-z7-20/linux/local.conf   # this project's card; omit for a standalone one
    echo ETHADDR=<the board's MAC>            >> boards/arty-z7-20/linux/local.conf   # optional; the console printed it
    make buildroot                                                  # once; ~25 min the first time
    BIT=<the memory-on board's .bit> boards/arty-z7-20/linux/mksd-buildroot.sh        # stages build/sd/buildroot/
    mkdir -p /srv/tftp/arty-z7-20                                   # the board's own directory
    cp build/sd/buildroot/server/arty-z7-20/* /srv/tftp/arty-z7-20/  # the network path's files

**`BIT` is mandatory and names the bitstream explicitly.** An earlier version
took `build/ddr/cadr_arty.bit` if it was there, and what was there was a
build a day older than the one being served. The script now refuses to run
without `BIT`, and refuses a path that does not exist. It prints the
bitstream's own header --- design name, part, date, time, as Vivado wrote
them into the `.bit` --- so the provenance of every staging is in its log:

    mksd-buildroot: bitstream /srv/tftp/cadr.bit
    mksd-buildroot:   design cadr_arty;UserID=0XFFFFFFFF;Version=2026.1;...  part 7z020clg400  date 2026/09/10  time 07:38:09  4045564 bytes of configuration

`PACKS="a.img 5=b.img"` puts disk packs in `packs/`. An entry is `unit=path`,
or a bare path taking the lowest free unit. Without it the bay is empty, and
the script says so and says how to fill it from the running board. A file
whose size is neither a T-300's nor a T-80's is refused here, because on the
board it would simply not be a drive.

`SYS=<a directory>` and `SITE=<a directory>` put the band's own Lisp files on
the card as `sys/` and `site/`. Both are optional, and both folders are on the
card empty when they are not given.

**`CC_PACK` is the debugger's band, and it is not one of the eight.** muir on
the board's own Arm cores is the far end of the debug cable, and the debugger
is CC running on a CADR that muir simulates. So muir needs a band with CC
already loaded in it, which `docs/cc-pack.md` says how to build. Name that
file with `CC_PACK` in `local.conf` and the card carries it as
`/mnt/card/packs/muir-cc.img`, in the bay's folder but not one of the eight,
and `muirrc` gets its `--disk-pack` and `--debug-cable-connect` lines live.
Leave `CC_PACK` unset and those two lines stay commented, with the explanation
of what is missing. The variable is in `local.conf` because the file is 257
MiB and is a path on whoever's build host. It must be exactly a T-300, where
the bay also takes a T-80. `STANDALONE` clears it, so no release card carries
it.

`STANDALONE=1` writes `uEnv.txt` without the server even when `local.conf`
names one, for testing the card path from this host. With no `local.conf` at
all the card is standalone. The script says which path the card it staged will
take.

### How big a card has to be

**It is the band that sizes the card, not the files the board needs.** How big
to format is the user's own decision now, because the user does the
formatting; there is no image whose size has to be settled in advance. What
this project can say is what goes on it.

| what | bytes |
|---|---|
| the Arty Z7-20's zip, unpacked | 12,500,992 |
| the Cora Z7-07S's zip, unpacked | 10,498,048 |
| the DE25-Nano's zip, unpacked | 49,434,624 |
| a T-300 disk pack | 269,562,880 |
| a T-80 disk pack | 70,937,600 |

The DE25-Nano's is four times the Zynq boards' because its kernel `Image` is
not compressed: 41.9 MB of the 49.4. Beside any of them one pack is the
larger number, which is the whole point of the table. **So a 1 GB card is
ample for a board with one drive**, and the size to buy is decided by how many
bands are to be kept on it rather than by the boot files.

**The bay is eight and no more.** A drive is `packs/disk-pack-<unit>.img` and
a unit is 0 to 7. Eight T-300 packs are 2,056 MiB, so a full bay wants 4 GB.
A file in `packs/` under any other name is not a drive, which is where backups
and bands that are not currently mounted live. Nobody runs eight drives.

**A card too small does not warn, it fails while unpacking**, and the file
that did not fit is the one that is missing at the next boot. The unpacking
tool says so; read what it prints.

### Format a card

**One FAT32 partition in an MBR, and then unpack the zip onto it.** That is
the whole of it. The partition needs no particular type byte and need not be
marked bootable: U-Boot accepts any non-zero type that is not an extended one,
and does not look at the boot flag (`disk/part_dos.c`). What it does require
is a partition table. A card formatted as a bare filesystem with no MBR at
all --- a "superfloppy", which some tools produce --- fails with `** No
partition table **`, so the MBR is not optional.

**On Windows**, right-click the drive and choose Format, with FAT32 as the
file system. **Windows' own dialog refuses FAT32 above 32 GB**, and this is
the trap worth knowing: a 64 GB card or larger is formatted exFAT by default,
both by Windows and by the SD Association's own formatter, and **no loader
here reads exFAT**. A card that exFAT was put on looks perfectly healthy in a
reader and does not boot. Use a card of 32 GB or less, which is far more than
this needs, or a third-party tool that will write FAT32 on a larger one.

**On macOS**, Disk Utility with the view set to show all devices: select the
card itself rather than the volume on it, Erase, format **MS-DOS (FAT)**,
scheme **Master Boot Record**. The scheme is the part that is easy to miss and
is the part that matters.

**On Linux**, with `D` set to the card --- read it off `lsblk`, from the line
that says `usb`, never from memory:

    sudo umount ${D}?* 2>/dev/null
    sudo sfdisk --wipe always $D <<'EOF'
    label: dos
    start=2048, type=c
    EOF
    sudo mkfs.vfat -F 32 -n CADR ${D}1

Then mount it and unpack the board's zip into the root of it:

    M=$(mktemp -d) && sudo mount ${D}1 $M
    sudo unzip -o cadr-arty-z7-20.zip -d $M
    sudo sync && sudo umount $M && rmdir $M

**Unpack into the root of the card, not into a folder on it.** `BOOT.BIN` and
`uEnv.txt` are read from the root by name, and a card whose files are one
level down behaves exactly like a card with no files on it.

### What is in the zip

Everything the board needs, laid out as the card is laid out: the loader's
files at the root, the board's own folder, and `packs/`, `sys/` and `site/`
empty. `README.TXT` at the root says which board the zip is for and what each
part is, because a card in a Windows reader otherwise shows a folder named
after a board and a 270 MB `.img` and explains nothing.

**A release is three zips, one for each board.**

    cadr-arty-z7-20.zip     about 8.1 MB     12,500,992 B on the card
    cadr-cora-z7-07s.zip    about 8.1 MB     10,498,048 B on the card
    cadr-de25-nano.zip     about 21.9 MB     49,434,624 B on the card

The download is given to a tenth of a megabyte because it is not the same to
the byte twice: a zip stores each file's own time, so two builds of the same
files differ in a few dozen bytes. What lands on the card does not, and those
are the figures that decide how big a card has to be. The DE25-Nano's is the
large one because its kernel is an uncompressed arm64 `Image` of 41.9 MB.

**A card made from the wrong board's zip does not boot, and says which file it
wanted.** Two files are shared and no others: the Arty's and the Cora's
`fpgarc` and `muirrc` are byte-identical to each other, and the DE25-Nano's
are not, because they name different window addresses. Everything else ---
the loader, the kernel, the device tree, the fabric image, `uEnv.txt` and
`README.TXT` --- differs between all three. So the zips are near enough alike
that a card made from the wrong one looks perfectly ordinary in a reader. The
loader asks for its **own** board folder by name, so within a second of
power-on a board handed the wrong card prints

    ** Unable to read file <this board>/zImage **
    cadr: the boot did not happen; trying again in 10 s

and goes on saying it every ten seconds, for ever. The kernel is `zImage` on
the Zynq boards and `Image` on the DE25-Nano, so the name in that line is the
one the board asking for it uses. Unpack the right zip.

### What has been shown about a card the user formats, and what has not

**The loader reads such a card, measured in a sandbox.** U-Boot 2026.01 was
built for the sandbox from the same source tree the Zynq boards' U-Boot comes
from, and run against six card images made as an ordinary formatter makes
them: one FAT32 partition in an MBR, with partition type `0x0c` and with
`0x0b`, with the boot flag set and with it clear, and with the partition
starting at sector 2048 (1 MiB) and at 8192 (4 MiB), in both the Arty's and
the DE25-Nano's layouts. On every one of the six it found partition 1 and
loaded every file by the exact path the board's `cadr_card` names.

**The control failed as it should.** The same FAT32 filesystem with no
partition table at all --- a bare filesystem written straight onto the device,
which some tools call a superfloppy --- gives `** No partition table **`. So
the MBR is required, and this is the one thing about the format that a user
can get wrong without noticing.

**One sandbox run covers both boards.** `disk/part_dos.c`, `fs/fat/fat.c`,
`common/spl/spl_fat.c` and `spl_mmc_do_fs_boot()` are byte-identical between
mainline U-Boot 2026.01, which is the Zynq boards', and Altera's fork at
commit `e09d6fcc`, which is the DE25-Nano's. Both boards' SPLs are configured
`CONFIG_SYS_MMCSD_FS_BOOT_PARTITION=1`, which is the first partition. Reading
`disk/part_dos.c` says what the acceptance really is: any non-zero partition
type byte that is not an extended type, with no requirement that the bootable
flag be set, but a valid MBR --- the `0x55AA` signature, all four boot
indicators either 0 or `0x80`, and at least one non-empty entry.

**What has NOT been shown is a board booting from one.** No real board has yet
been started from a card made this way. On a Zynq board exactly one step is
silicon this project cannot read: the boot ROM finding `BOOT.BIN` on the first
FAT partition. Everything after it is the U-Boot code the sandbox ran. On the
DE25-Nano even that step is not on the card, because its first stage is in the
QSPI flash, so the whole card path there is U-Boot code and nothing about the
card is unreadable. **The sandbox result is evidence about U-Boot and it does
not stand in for a board.**

**`ETHADDR`.** Digilent's U-Boot read the board's MAC out of the QSPI flash's
OTP area. Mainline has no such code. So without a MAC in the card's file
U-Boot makes up a random one (`NET_RANDOM_ETHADDR`), and it says so on the
console. That is harmless on the card path. On the network path it means the
DHCP lease pinned to the board's real address is not the one it gets. The
card's `ethaddr` is imported before `dhcp`. U-Boot writes it into the
kernel's tree at boot (`fdt_fixup_ethernet`, on the `ethernet0` alias), and
Linux asks DHCP with the same address. Like `SERVERIP` it lives in the
board's own `linux/local.conf` and in no committed file.

### Another board's card, from the same script

**One script stages every board's card, and the board enters it as two
variables.** `BOARD_DIR` is where the board's `linux/` directory is and
`BOARD_DTB` is what its compiled device tree is called. Both default to the
Arty Z7-20's, so a run that sets neither is the run it has always been. The
Cora Z7-07S is

    make buildroot-cora                                        # its own output directory
    IMAGES=$HOME/.cache/muir-fpga-buildroot/out-cora/images \
    BOARD_DIR=boards/cora-z7-07s BOARD_DTB=zynq-cora-z7-07s.dtb \
    BIT=<the Cora's memory-on .bit> PACKS=<a pack> \
        boards/arty-z7-20/linux/mksd-buildroot.sh
    mkdir -p /srv/tftp/cora-z7-07s
    cp build/sd/buildroot/server/cora-z7-07s/* /srv/tftp/cora-z7-07s/

Everything else about the card is the machine's rather than the part's: the
layout, the bay, the `fpgarc` and the `muirrc`, the U-Boot environment and
every warning above. `local.conf` is read out of `$BOARD_DIR/linux/`, so each
board carries its own server address, its own MAC and its own Chaosnet
addresses. Two boards on one network must differ in all three, and the
development allocation reserves a second pair of Chaosnet addresses for
exactly that.

`build/sd/buildroot/card/` is the card's contents as a directory, and
`build/sd/buildroot/cadr-<board>.zip` is that directory zipped, which is what
a user unpacks. The zip is read back afterwards --- unpacked to a scratch
directory and compared against what was staged, every file byte for byte and
the name sets both ways --- because what is published is the zip and not the
directory. **What the image's readback could say and this cannot is that the
filesystem is right**, since there is no filesystem here any more: the user's
own formatter makes it. What that formatter has to produce is above, and it
was measured against U-Boot's own code rather than assumed. **Nothing here
writes a card, and there is no disk image.** The two-partition `sdcard.img`
that genimage used to build is gone, and it is gone rather than kept beside
the zip, because a second way that nothing exercises is a way that quietly
stops working.

**THE CARD IS WRITTEN ONCE AND THEN NEVER LEAVES THE BOARD.** Adding,
replacing or protecting a disk pack is `scp` to the running board and nothing
else, as "The drive bay" below says. For this project's own board, a change to
the loader, kernel or bitstream is `cp
build/sd/buildroot/server/<board>/* /srv/tftp/<board>/` and a reset. For a
standalone card those live on the card itself, and since the card is mounted
read-write they can be replaced from the board with a plain

    cp ... /mnt/card/<board>/ && sync

and no remounting at all. That is the convenience the one-partition card buys,
and the section above says what it costs.

## The release, and the card this project builds for itself

**A release is three zips, one for each board, and one command makes all
three.**

    make release BIT_ARTY=<a .bit> BIT_CORA=<a .bit> BIT_DE25=<a .rbf>

**It is one target rather than three because three zips are three chances for
one to be stale.** A release in which two boards were rebuilt and the third
was not is exactly the sort of thing that ships, so every bitstream is
required by name, a missing one stops the run before anything is built, and
the three zips are printed together at the end with their sizes and digests,
where a missing one is visible. The bitstreams are named on the command line
because they are not in this repository: they are built by Vivado and by
Quartus, which `make check` does not run.

Each board's Buildroot output must exist first, which is `make buildroot`,
`make buildroot-cora` and `make buildroot-de25`. One board on its own is

    BIT=<the released bitstream> boards/arty-z7-20/linux/mksd-release.sh

    IMAGES=$HOME/.cache/muir-fpga-buildroot/out-cora/images \
    BOARD_DIR=boards/cora-z7-07s BOARD_DTB=zynq-cora-z7-07s.dtb \
    BIT=<the Cora's released bitstream> boards/arty-z7-20/linux/mksd-release.sh

and the zip goes in a directory named for the board and carries the board's
name in its own name, so two boards' releases can be built one after the other
without either being overwritten, and a file somebody downloaded a month ago
still says which board it is for.

**What a release zip carries is everything the board needs to come up and no
band at all.** The loader's files and the board's own folder are complete,
with a `uEnv.txt` that names no server and carries no MAC. `packs/`, `sys/`
and `site/` are on the card empty, which is what says where a band goes.
`README.TXT` at the root says which board the zip is for and how to name a
pack, and beside it are the two files of flags: `fpgarc` for the CADR in the
fabric and `muirrc` for the CADR inside muir. Each is the same full menu the
development card gets, every flag the board's programs take written out under
a sentence or two saying what it does.

**The released `fpgarc` has three live lines and the rest of the menu is
commented out.** They are `--chaos-address`, `--terminal` and
`--keyboard-boot`: the Chaosnet address switches, the screen, and the chord
that cold-boots the machine. Those are what a board out of the box needs.

**The Chaosnet cable and the serial line are commented out with everything
else.** `--chaos-udp` is the cable, and a release that plugged one in would put
a station on a network the user has not got, listening on a port nobody named,
with no peer it could reach. `--serial` offers the far end of the CADR's RS-232
cable on TCP, and a release that offered it would open an unauthenticated port
on every interface for a cable hardly anybody wants. Each is one `#` away from
being on and carries the sentence that says so.

The board reads the file the same way from the other side. The Chaosnet program
comes up with its switches set and no cable, says so on the console, and does
not wait for a network it has nothing to reach. The serial program is not
started at all, and its init script says the line is off and how to turn it on.
`docs/fpgarc.md` has the rule and `fpgarc.pass` holds both menus and what a
board does with each.

`RELEASE=1` writes that menu and `mksd-release.sh` sets it. It is a separate
flag from `STANDALONE=1`: one decides which lines are live, the other keeps
anything private off the card.

**It carries no disk pack and no band.** The bay is empty, the program says so
on the console, and the CADR waits for a drive exactly as the real machine did
with no pack loaded. A band is the user's own to supply. It goes in `packs/`
either from a PC with the card in a reader, since the card is plain FAT32, or
over the network to the running board. Either way the drive comes ready within
a quarter second and nothing restarts. **The debugger's band is a band too**,
so a release carries no `muir-cc.img` either, and the `muirrc` that would name
it ships with its last two lines commented and the explanation beside them.
`sys/` and `site/` are empty for the same reason: those are the band's Lisp
files.

`mksd-release.sh` holds those decisions so that a release is a command rather
than a set of variables somebody has to remember. It refuses to run if `PACKS`,
`SYS` or `SITE` is set. It does not trust its own standalone flag either: it
greps the whole staged card afterwards for anything address-shaped --- an IP
or a MAC --- and stops if it finds any, because a flag can be wrong and a
private address on a public artifact cannot be taken back. **Reading the whole
card is what one partition made simple and what the two files of flags made
necessary**: `fpgarc` and `muirrc` can each name a host on somebody's network,
and with two partitions they were on the half this guard did not read. It then
checks that `packs/`, `sys/` and `site/` are empty, and that the four files a
card cannot boot without are there.

**A peer can be a name, which no pattern for an address can see.** A Chaosnet
peer is written `<address>@<host>:<port>` and the host may be a name, which is
as private as the number it resolves to. So the two files of flags are
separately asserted to carry no `--chaos-udp-peer` and no
`--chaos-udp-default-peer` line at all.

**What that guard exempts is the addresses that cannot name a host**, and only
those: `0.0.0.0`, which is every interface on this board; `127.0.0.1`, the
loopback, which the card's own prose names when it says how to keep the screen
to the board; and RFC 5737's documentation ranges, which the two commented
example lines are written in. Anything else stops the release, a MAC included.
**The list grew because the guard stopped a release that was right.** When the
card's file of flags became a full menu it gained the loopback and a
documentation address, the guard exempted `0.0.0.0` alone, and no release had
been built since, so nothing said so. `make build/fpgarc.pass` runs the guard
both ways now: it must pass the file the card script really writes, and it must
still catch a private address and a MAC.

**The download is 8.1 MB for a Zynq board and 21.9 MB for the DE25-Nano**, and
the card has to hold only what is unpacked from it: 12.5 MB, 10.5 MB and 49.4
MB respectively. The released image this replaced was 3.83 GB raw and 7.4 MB
compressed, and it demanded a 4 GB card whatever the user meant to put on it,
because a whole-card image carries the card's own size. The zip demands only
what is actually on the card.

**`STANDALONE=1` matters**: without it the card would carry this project's own
TFTP server address and boot over a network the user has not got.

**The card this project builds for itself is a different one, and it has a
script of its own.**

    BIT=<a bitstream> boards/arty-z7-20/linux/mksd-dev.sh [PACKS="a.img 3=b.img"]

`mksd-dev.sh` names the server, so the loader fetches the bitstream, the
kernel, the tree and the root filesystem over the network and the card is
written once. It carries a band --- packs with `PACKS`, and the band's own
Lisp files with `SYS` and `SITE` --- so the machine boots straight into its
own world. And it stops if `local.conf` is missing, rather than quietly
building a card that boots from itself, because somebody who forgot to write
that file should be told. None of that belongs in a release, which is why
there are two scripts over one staging tool rather than one script with a
mode. Both produce the same thing in the end: a directory and a zip of it, for
a card the user formatted.

## The drive bay

**`packs/` is the drive bay, and the eight names are the whole of the
interface.** `muir-cc.img` beside them is not a drive, and neither is anything
at the root of the card.

    /mnt/card/packs/disk-pack-0.img  ... /mnt/card/packs/disk-pack-7.img

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

    scp band.img root@<the board>:/mnt/card/packs/disk-pack-0.img     # load unit 0
    ssh root@<the board> mv /mnt/card/packs/disk-pack-0.img /mnt/card/packs/kept.img
    ssh root@<the board> chmod -w /mnt/card/packs/disk-pack-1.img     # write-protect unit 1

It can also be done from the board's own prompt, with `tftp -g -r band.img
-l /mnt/card/packs/disk-pack-0.img <the server>`. The read-only mark is FAT's own
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

**FAT32, deliberately.** The card must be readable and writable from Windows,
which cannot write ext4. What it costs is the journal. What makes that
bearable is that a pack is a working copy whose master is in the archive, and
that the loader's files are a copy of what is in the zip, which is still on
the machine that wrote the card. Nothing on the card is the only copy of
itself, so the remedy for anything lost is to put it back.

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
   `load` ("`** Unable to read file arty-z7-20/zImage **`") just before the
   message, and the name it prints carries the board's folder because that is
   the path the loader asked for.

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
- **No writable storage from Linux but the card.** The card's one partition
  is mounted read-write at `/mnt/card`, and what the board writes on it is a
  disk pack in `packs/`, the band's `site/` tree, and the `clock` file. There
  is no writable root: everything else runs out of a RAM disk unpacked at
  every boot, so a file edited there is gone at the next one.
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
   which is a Linux that owns the CADR's memory. It is decided that the board
   must never do that. The card's file sets `cp_kernel2ram=reset`, replacing
   the copy step the fallback itself would run. So a fetch that fails ends in
   `resetting ...`, and another attempt follows ten seconds later, for as
   long as the server is away. This was measured 10 September on the real
   boot path, with the server stopped. A `|| reset` on the end of the fetch
   line had been tried first, and it did not fire on that path
   (`boards/arty-z7-20/linux/uEnv.txt.in` says why).

   Digilent's stock boot was run once for comparison before that decision,
   from the first card. It gave a login with `Memory: 335116K/524288K`,
   against `303564K/393216K` on the reserved boot.

5. **The kernel's root filesystem was built into `zImage`** as an initramfs.
   So that card had one partition and Linux mounted nothing on it at all. It
   booted to a shell on the serial console. The card today is also one
   partition, and Linux does mount it: the section above says so.

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

    boards/arty-z7-20/linux/console.py /dev/serial/by-id/<the board's by-id path> build/console.log &

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
