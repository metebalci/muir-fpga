<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Booting the board into Linux

How the Arty Z7-20 gets from power-on to a Linux prompt beside the running
CADR with the CADR's memory reserved, what is on the card and what on the
build host, and the steps in the order they are done. The board boots from
the card alone; for development the card's one-line file names a TFTP server
and the same files come from there instead.
`docs/linux.md` has the reasoning behind every choice here and the evidence
for it; this file is the procedure. Where the two disagree, `linux.md` was
read out of the binaries and wins.

## The image

The board runs a Buildroot image built entirely on the build host from a
pinned Buildroot, so that the board is reproducible from the repository and
a machine move. **It has booted the board** over the network path on 10
September --- U-Boot's first stage, U-Boot, the CADR into the fabric, Linux
6.19 with the reservation honoured by the tree alone, a login 15 s after the
reset --- and the card path, which is how anyone else's board boots, ran the
same day from U-Boot's prompt: the four files read off the card in under a
second, Linux up with the reservation, the CADR's counters at 256 and 256.

## What it is

    Buildroot   2026.02.3, the LTS   vendor/buildroot-2026.02.3.tar.xz, sha256 5a59e750...c6fc7fb
    U-Boot      2026.01, mainline    SPL is the first-stage loader: BOOT.BIN 127,456 B;
                                     u-boot.img 1,076,532 B (a FIT: U-Boot proper and its tree)
    Linux       6.19.14, mainline    zImage 3,256,232 B; zynq-arty-z7-20.dtb 11,404 B
    rootfs      BusyBox + Dropbear   rootfs.cpio.uboot 2,792,240 B (6.2 MB unpacked), an
                + evtest             initramfs, unpacked into RAM on both paths
    the card    one FAT32 partition  sdcard.img, 537,919,488 B (512 MiB + 1 MiB); seven files
                                     today, 11.3 MB of them; pack.img when there is one

Sizes are of the first build, 10 September, on the build host; the whole
thing --- toolchain download, host tools, U-Boot, kernel, root filesystem ---
took 25 minutes of wall clock on 16 cores, and `make buildroot` after a
change minutes. **Buildroot does not watch our files**: after editing
anything under `linux/buildroot/` run `make buildroot-rebuild`, which
reconfigures U-Boot, the kernel and `cadr-tools` and finishes the image.

`linux/buildroot/` is the Buildroot external tree; `make buildroot` builds
the whole thing from the tarball (several gigabytes under
`~/.cache/muir-fpga-buildroot`, never `/tmp`, never `build/`);
`linux/mksd-buildroot.sh` stages the card and the server directory under
`build/sd/buildroot/`. Every file under `linux/buildroot/` carries the reason
for what it holds; the ones worth knowing exist:

    configs/arty_z7_20_defconfig               the whole image, pinned
    board/arty-z7-20/dts/xilinx/zynq-arty-z7-20.dts   the board, for Linux AND U-Boot
    board/arty-z7-20/uboot/ps7_init_gpl.c      the start-up routine, GENERATED from vivado/ps7_init.ops
    board/arty-z7-20/uboot/gen_ps7_init_gpl.py the generator; --check, and --compare against Vivado's
    board/arty-z7-20/uboot/cadr.env            U-Boot's default environment: both paths, the retry loop
    board/arty-z7-20/uboot/uboot.fragment      what changes in xilinx_zynq_virt_defconfig
    board/arty-z7-20/linux/linux.config        the kernel: what the board has and nothing more
    board/arty-z7-20/uEnv.txt.in, uEnv.net     the card's optional file and the served boot command
    board/arty-z7-20/genimage.cfg              the card as one image, sdcard.img
    package/cadr-tools/                        where our own programs go; one placeholder today

**The start-up routine is the same one, proved rather than assumed.** U-Boot's
SPL runs `ps7_init()` and `ps7_post_config()` from a `ps7_init_gpl.c`, as
Digilent's FSBL did. Ours is generated from `vivado/ps7_init.ops` --- the
committed, `make current`-checked list of the 673 register operations of
Digilent's routine --- so that a checkout without Vivado can build the
loader. `gen_ps7_init_gpl.py --compare build/ps7/ps7_init_gpl.c` reads the
file Vivado itself writes and requires the same operations in the same
tables in the same order: 660 in 18 tables, identical, measured at the commit
that added it. The 13 the generated file does not carry are the three
`ps7_debug` tables nothing runs and the SCU-timer helpers U-Boot has its own
copy of. `make buildroot-check` (which `make buildroot` runs first) fails if
the C ever stops being what the `.ops` say.

**One device tree for both.** Mainline has no Arty Z7 tree; ours is written
like `zynq-zybo-z7.dts` from Digilent's own BSP tree and `vivado/ps7_config.tcl`,
and it differs from every mainline Zynq board in three things the files
settle: the console is **UART 0**, the PS clock is **50 MHz**, the PHY is at
MDIO address **1**. It includes `linux/cadr-reserved.dtsi` --- the same node
the stepping stone appended --- and is compiled twice, by the kernel and by
U-Boot. U-Boot reading it matters: mainline U-Boot honours a `reserved-memory`
node in its *own* tree for its own relocation (`common/memtop.c`) and for
where it puts the fdt and the ramdisk (`lib/lmb.c`), and does not rewrite the
kernel's memory node (`ARCH_FIXUP_FDT_MEMORY` is off in `xilinx_zynq_virt`).
So the loader stays out of the CADR's region by the same node that keeps the
kernel out, which closes the hazard `linux.md` recorded --- "the
reserved-memory node binds the kernel, and not the loader" --- for this
U-Boot.

## The card, and the two ways it boots

    the card    BOOT.BIN (U-Boot's SPL), u-boot.img, uEnv.txt (optional),
                cadr.bit, zynq-arty-z7-20.dtb, zImage, rootfs.cpio.uboot,
                pack.img (the disk pack as a file; nothing writes it yet)
    /srv/tftp   uEnv.net, cadr.bit, zynq-arty-z7-20.dtb, zImage, rootfs.cpio.uboot
                --- this project's convenience, the same five files

U-Boot's built-in environment (`cadr.env`) boots **from the card by
default**: `cadr.bit` loaded and `fpga loadb`'d, then the tree, `zImage` and
`rootfs.cpio.uboot` off the FAT partition, then `bootz`. No network is used
and none is needed; DHCP is not attempted; a board with no cable boots. If
the card's `uEnv.txt` sets `serverip`, the loader takes **the network path**
instead: `dhcp`, fetch `uEnv.net` from that server, run the `netcmd` it
defines, which fetches the same five files over TFTP and ends in the same
`bootz`. That is this project's own card: the five files live in `/srv/tftp`
and a change to any of them is a copy and a reset; the card is never
rewritten. On either path a failure loops --- a message, ten seconds, another
attempt, for ever; the network path does not fall back to the card's own
copies, because a card that names a server is this project's and booting
stale files silently is the thing this project decided against. Nothing
else is ever booted.

The root filesystem is the initramfs on both paths, unpacked into RAM, so
nothing on the board drifts: the card is read and never written by anything
here. **Small persistent state, if it is ever wanted --- an SSH host key is the
obvious case, since Dropbear makes a new one at every boot --- would be a file
on the card that the image reads at start**, not a partition and not a
writable root; it is not built now.

**Three files were two.** Mainline U-Boot's SPL is the first stage and loads
U-Boot proper as a second file, `u-boot.img`, from the FAT partition;
Digilent's `BOOT.BIN` carried both because Xilinx's FSBL reads partitions out
of the boot image. `u-boot.img` is a FIT --- U-Boot proper and its device tree
in one flattened-tree container, which is what the generic Zynq SPL loads
(`CONFIG_SPL_LOAD_FIT`) --- so `mkimage -l` prints nothing for it and `fdtget
-l u-boot.img /images` is how to look inside; `mksd-buildroot.sh` checks it
that way, and checks that the U-Boot inside carries `bootcmd=run cadr_boot`
and the `cadr_card` path. Buildroot writes the SPL as `boot.bin`; the card
has it as `BOOT.BIN`, the name the boot ROM looks for.

## Staging, and what to copy where

    echo SERVERIP=<the TFTP server's address> >  linux/local.conf   # this project's card; omit for a standalone one
    echo ETHADDR=<the board's MAC>            >> linux/local.conf   # optional; the console printed it
    make buildroot                                                  # once; ~25 min the first time
    BIT=<the memory-on board's .bit> linux/mksd-buildroot.sh        # stages build/sd/buildroot/
    cp build/sd/buildroot/server/* /srv/tftp/                       # the network path's files

**`BIT` is mandatory and names the bitstream explicitly.** An earlier version
took `build/ddr/cadr_arty.bit` if it was there, and what was there was a
build a day older than the one being served; the script now refuses to run
without `BIT`, refuses a path that does not exist, and prints the
bitstream's own header --- design name, part, date, time, as Vivado wrote
them into the `.bit` --- so the provenance of every staging is in its log:

    mksd-buildroot: bitstream /srv/tftp/cadr.bit
    mksd-buildroot:   design cadr_arty;UserID=0XFFFFFFFF;Version=2026.1;...  part 7z020clg400  date 2026/09/10  time 07:38:09  4045564 bytes of configuration

`PACK=<file>` puts a disk pack on the card as `pack.img`; without it the
card has none, and the script says so. `STANDALONE=1` writes `uEnv.txt`
without the server even when `local.conf` names one, for testing the card
path from this host; with no `local.conf` at all the card is standalone.
The script says which path the card it staged will take.

**`ETHADDR`.** Digilent's U-Boot read the board's MAC out of the QSPI flash's
OTP area; mainline has no such code, so without a MAC in the card's file
U-Boot makes up a random one (`NET_RANDOM_ETHADDR`, and it says so on the
console) --- harmless on the card path, and on the network path it means the
DHCP lease pinned to the board's real address is not the one it gets. The
card's `ethaddr` is imported before `dhcp`, U-Boot writes it into the
kernel's tree at boot (`fdt_fixup_ethernet`, on the `ethernet0` alias), and
Linux asks DHCP with the same address. Like `SERVERIP` it lives in
`linux/local.conf` and in no committed file.

`build/sd/buildroot/sdcard.img` is the card as one image --- the same
one-partition FAT32 layout as the recipe above, 512 MiB, made by genimage
from the whole `card/` directory and read back file by file --- so on the
laptop either

    D=/dev/sdX   # the line that says usb, never from memory
    sudo dd if=sdcard.img of=$D bs=4M conv=fsync

or the sfdisk/mkfs.vfat/cp recipe above with everything in `card/`. Both
are the same card. **For this project's board the card is written once**
(new `BOOT.BIN`, `u-boot.img` and `uEnv.txt` against the stepping stone's);
after that, `cp build/sd/buildroot/server/* /srv/tftp/` and a reset is the
whole procedure for any change. For the card path, a change is a new card.

## What happens at power-on, and what the console must show

1. **The boot ROM loads `BOOT.BIN`**: U-Boot's SPL. It runs `ps7_init()` ---
   MIO, PLLs, clocks, DDR, peripheral resets, the 660 operations --- prints
   its banner, loads `u-boot.img` from the FAT partition, runs
   `ps7_post_config()` (the level shifters and the fabric resets, which is
   what makes `S_AXI_HP0` live), and jumps to U-Boot.

       U-Boot SPL 2026.01 (...)
       Silicon version:	3
       Trying to boot from MMC1

   `Silicon version: 3` is this board (3.1; `linux.md` says why the `else`
   branch is the right one). The SPL says nothing more when the load
   succeeds; `spl: error reading image u-boot.img` is the card without the
   second file. No banner at all, or the ROM parking (`0x200A` over JTAG),
   is the card not latched.

2. **U-Boot proper** prints `U-Boot 2026.01`, `CPU: Zynq 7z020`,
   `Silicon: v3.1`, `DRAM: ECC disabled 512 MiB`, and --- unless `uEnv.txt`
   carries `ethaddr` ---

       Warning: ethernet@e000b000 (eth0) using random MAC address - xx:xx:...

   Two seconds of `Hit any key to stop autoboot`, then `bootcmd` runs
   `cadr_boot`, which loads and imports `uEnv.txt` if there is one (`cadr:
   no uEnv.txt on the card; booting from the card` if not) and looks at
   `serverip`.

3. **The card path** (no `serverip`): seven `N bytes read in M ms` lines from
   the FAT partition --- `cadr.bit` with `fpga loadb`'s header (`design
   filename = "..."`, `part number = "7z020clg400"`) and U-Boot's fixed
   `INFO:post config was not run, please run manually if needed`, which is
   not a fault (the driver has just written the level shifters and the
   fabric resets itself); the CADR starts here --- then the tree, `zImage`,
   `rootfs.cpio.uboot`, and

       ## Loading init Ramdisk from Legacy Image at 04000000 ...
       ## Flattened Device Tree blob at 01f00000
       Starting kernel ...

   No `DHCP`, no `TFTP`, no `Filename` line anywhere.

   **The network path** (`serverip` set): `cadr: uEnv.txt names a server;
   fetching over TFTP`, `DHCP client bound to address ...`, then `Filename
   'uEnv.net'` and the same five files as `Filename '...'` / `Bytes
   transferred = N` pairs, the `fpga loadb` lines after `cadr.bit`, and the
   same three lines into the kernel.

4. **If anything fails** --- a file missing on the card, the server down, the
   cable out --- the line `cadr: the boot did not happen; trying again in
   10 s` and another attempt ten seconds later, for as long as it takes;
   U-Boot's banner does **not** reappear, because this is a loop and not the
   stepping stone's `reset`. A missing card file is named by `load` ("`**
   Unable to read file zImage **`") just before the message.

5. **Linux**, and the two things the first boot established are in its
   first lines and at its prompt:

       OF: reserved mem: 0x18000000..0x1fffffff (131072 KiB) nomap non-reusable cadr@18000000

   is the tree reserving the CADR's memory **with `no-map` and without
   `mem=384M`** --- the thing the 4.9 kernel died on, and this kernel does
   not (measured 10 September). Reading 6.19.14: `drivers/of/of_reserved_mem.c`
   marks the region `MEMBLOCK_NOMAP`; `arch/arm/mm/mmu.c`'s `map_lowmem` and
   `arch/arm/kernel/setup.c`'s `request_standard_resources` both walk
   `for_each_mem_range`, which skips it, so it is neither mapped nor "System
   RAM".

   Then the login: `cadr login:` on the console, `root` / `root` (the
   stepping stone's password, kept because the board is on a private LAN;
   set in the defconfig, `BR2_TARGET_GENERIC_ROOT_PASSWD`), and over SSH from
   the address DHCP gave it, without the `ssh-rsa` incantation the 2018
   Dropbear needed. On the card path Linux still asks DHCP for an address
   (`BR2_SYSTEM_DHCP="eth0"`); with no cable it waits its 15 s and goes on
   to the prompt without one.

At the prompt, the same four lines as above, and what they said on 10
September under this image:

    cat /proc/device-tree/model                  Zynq Arty Z7 Development Board  (kept on purpose)
    ls /proc/device-tree/reserved-memory/        cadr@18000000
    grep "System RAM" /proc/iomem                00000000-17ffffff   -- from the node alone, no mem=
    grep MemTotal /proc/meminfo                  381472 kB
    cat /proc/cmdline                            console=ttyPS0,115200 earlycon   -- and nothing about memory
    devmem 0xE000A068; devmem 0xE000A06C         0x01008100 twice, WITHOUT the APER_CLK_CTRL line first

**The `APER_CLK_CTRL` line is gone because this kernel has no power
management.** `drivers/gpio/gpio-zynq.c` gates the block's clock through
runtime PM --- `zynq_gpio_runtime_suspend()` is `clk_disable_unprepare()`, and
the driver drops its reference after probe, so with `CONFIG_PM` the block is
unclocked whenever no GPIO line is in use and the EMIO registers read zero,
which is what 4.9 did. `linux.config` builds without `PM` (nothing on this
board sleeps), the runtime-PM calls are stubs, and the clock the driver takes
at probe stays on --- measured: the counters read from Linux with no clock
trick. The alternative kept in `linux.config`'s header is to read the lines
through the driver (gpiochip lines 54..117 are EMIO 0..63).

**Verified on the built images**: the kernel's final `.config` has `PM`,
`SUSPEND`, `CPU_IDLE` and `STRICT_DEVMEM` off and `DEVMEM`, `GPIO_ZYNQ`,
`INPUT_EVDEV`, `USB_HID`, `USB_CHIPIDEA_HOST`, `MACB`, `REALTEK_PHY`,
`MMC_SDHCI_OF_ARASAN`, `SERIAL_XILINX_PS_UART_CONSOLE` and
`FPGA_MGR_ZYNQ_FPGA` on, and no `DRM` or `FB`; the tree, decompiled, carries
`cadr@18000000 { reg = <0x18000000 0x8000000>; no-map; }`, five devices
enabled (uart0, gem0, sdhci0, qspi, usb0 as host), `serial0` on
`serial@e0000000`, `ps-clk-frequency` 50,000,000, the PHY at address 1 and
no `amba_pl`; U-Boot's own tree carries the same reservation; the SPL is
125,216 bytes against its 196,608-byte ceiling and links `ps_init_gpl.o`
from the generated routine; and the SPL's cut-down tree holds exactly the
serial, QSPI, MMC, SLCR and timer nodes. The kernel also kept `CONFIG_VT`
on: it is not user-selectable without `EXPERT` and defaults to yes, and with
no framebuffer it is a dummy console nobody sees; `console=ttyPS0` is what
decides where the messages go.

**And one thing to know about `/dev/mem` on the reserved region**, from the
code: `mmap` works and, opened `O_SYNC` as BusyBox's `devmem` does, gives an
uncached mapping (`arch/arm/mm/mmu.c`, `phys_mem_access_prot`); `read()` and
`write()` on `/dev/mem` over `0x18000000..0x1fffffff` are expected to fail
with `EFAULT`, because the kernel reaches them through the linear map and a
`no-map` region has none (`drivers/char/mem.c` copies with
`copy_from_kernel_nofault`, so it fails rather than oopses). Programs that
read the CADR's memory from Linux mmap it; `dd if=/dev/mem` does not work
there. The board confirms or corrects this.

## The USB port: a keyboard and a mouse

The Arty Z7-20's USB is the processing system's, not the fabric's:
Digilent's tree has `usb0` --- the Zynq ChipIdea controller at `0xe0002000`,
`compatible = "xlnx,zynq-usb-2.20a", "chipidea,usb2"`, `phy_type = "ulpi"`
--- enabled as a host (`dr_mode = "host"`) with its PHY's reset on MIO 46
(`pcw.dtsi`'s `usb-reset = <&gpio0 46 0>`; `vivado/ps7_config.tcl`'s
`PCW_USB0_RESET_IO {MIO 46}`, `PCW_USB_RESET_POLARITY {Active Low}`, the
controller's twelve ULPI lines on MIO 28..39). Digilent's reference manual
could not be read --- their site answers automated fetches with 403, as
`linux.md` already records --- so the PHY's part number is not asserted here.
Our tree writes the same port the way mainline's `zynq-zybo-z7.dts` writes
the same part: `usb0` as host, `usb-phy` a `usb-nop-xceiv` with
`reset-gpios = <&gpio0 46 GPIO_ACTIVE_LOW>`. The kernel has the controller in
host mode over EHCI, HID over USB, and evdev; the root filesystem has
`evtest`. No display and no DRM: HDMI on this board is a fabric matter.

**What it costs**, measured on the built objects with `arm-linux-size`: the
USB host stack itself --- core, EHCI, the ChipIdea glue, the nop PHY, and
USB mass storage --- is 229,947 bytes of text and data in `vmlinux`; the
keyboard-and-mouse addition on top --- HID core, the generic and quirk HID
drivers, the USB HID transport, the input core and evdev --- is 129,569 bytes;
`vmlinux` compresses 2.03:1 into this `zImage`, so together about 175 KB of
the 3.26 MB `zImage`. `evtest` is 34,144 bytes in the root filesystem, about
15 KB in the compressed initramfs.

To prove it on the board, plug a keyboard in and watch the console:

    usb 1-1: new low-speed USB device number 2 using ci_hdrc
    usb 1-1: New USB device found, idVendor=xxxx, idProduct=xxxx ...
    input: ... as /devices/soc0/axi/e0002000.usb/ci_hdrc.0/usb1/1-1/.../input/input0
    hid-generic 0003:XXXX:XXXX.0001: input: USB HID v1.11 Keyboard [...] on usb-ci_hdrc.0-1/input0

then `ls /dev/input/` (an `event0`, and `event1` for a mouse), and

    evtest /dev/input/event0

which lists the device's capabilities and then prints one `Event: time ...,
type 1 (EV_KEY), code 30 (KEY_A), value 1` per key press and release. Without
`evtest`, `hexdump -C /dev/input/event0` shows the same 16-byte records. The
first of those console lines is the port working at all; if nothing appears
when a device is plugged in, the first suspects are the PHY's reset (MIO 46)
and VBUS to the connector, neither of which this image can see from the code.

## What is deliberately not in this image

- **No `mem=384M`, no `cma=32M`, no `uio_pdrv_genirq.of_id`** on the command
  line: the first is now measured unnecessary, the second was for Digilent's
  42 MB ramdisk against a 128 MB CMA pool, the third was for PL peripherals
  the tree no longer has.
- **No saved environment.** U-Boot's environment is built in and lives
  nowhere (`ENV_IS_NOWHERE`; the generic configuration's `uboot.env` on the
  card is off), as the 2017 build's was: a boot decided from a file nothing
  in the repository sees was the thing to avoid. `uEnv.txt` decides only
  which of the two paths, and supplies two addresses.
- **No fallback from the network path to the card**, for the reason above.
- **No `fdt_high`/`initrd_high`**, for the reason in `uEnv.net`.
- **No I2C, no SPI0, no FCLK**: off in `vivado/ps7_config.tcl`, off here.
- **No display, no DRM, no framebuffer**: HDMI on this board is the fabric's.
- **No writable storage from Linux**: the card is read by U-Boot and never
  mounted; `pack.img` is a place, not yet a pack.
- **No Vivado, no Xilinx tool of any kind** is needed to build the image;
  the one Xilinx-derived input is `vivado/ps7_init.ops`, committed.

## The stepping stone: Digilent's image, superseded

Everything from here to the end describes the boot as it ran for the first
day, on Digilent's 2017.4 PetaLinux image with a hand-edited device tree, and
is kept as the record of what was learned on it. It is not how the board
boots now.

### The pieces, and where each one lives

    the microSD card        in the board          BOOT.BIN, image.ub, uEnv.txt
    the TFTP server         the build host, /srv/tftp   uEnv.net, cadr.bit, system.dtb
    the serial console      the build host, over the board's USB cable
    the card writer         the laptop                  the build host has no card reader

The card is written **once**. Its `uEnv.txt` is one line that fetches
`uEnv.net` from the TFTP server and runs the command in it, so the boot
command, the CADR's bitstream and the device tree all live in `/srv/tftp`: a
change to any of them is a `cp` there and a reset, and the card is never
touched again. The kernel and the root
filesystem are Digilent's, read out of the `image.ub` already on the card.

### What happens at power-on

1. **The boot ROM reads the boot-mode jumper**, sees SD, and loads
   `BOOT.BIN` from the card's first FAT partition. That file is Digilent's:
   the first-stage boot loader (which runs `ps7_init`, so DDR comes up), a
   bitstream for the fabric, and U-Boot. **The bitstream inside it is
   Digilent's stock design, not the CADR** --- an SD boot displaces whatever
   was loaded over JTAG, and until our own `BOOT.BIN` exists, booting Linux
   and running the CADR are two different sessions on the board.

2. **U-Boot reads `uEnv.txt` from the card** and runs the one command in it:
   fetch `uEnv.net` from the TFTP server and run the `netcmd` it
   defines. That command fetches `cadr.bit` and **loads it into the fabric**
   (`fpga loadb`), displacing Digilent's design; fetches `system.dtb`; reads
   `image.ub` off the card; and boots the kernel and root filesystem inside
   it under our tree with `mem=384M cma=32M` on the kernel's command line.
   The CADR starts the moment the fabric is configured and is running its
   boot PROM out of DDR3 before Linux has finished uncompressing. The board's own address
   comes from DHCP, pinned on the DHCP server to the board's MAC, which the
   console prints; the TFTP server's address is in the card's file and a
   DHCP reply cannot overwrite it (`linux.md` says why).

3. **If the fetches succeed**, Linux comes up seeing **384 MB** beside the
   running CADR: `mem=384M` is what keeps it off the CADR's region, and the
   tree's `reserved-memory` node names the same region so `/proc/device-tree`
   says whose it is. The served tree has Digilent's `amba_pl` --- the
   peripherals of the design `cadr.bit` displaced --- removed, so Linux probes
   nothing that is no longer there.
   `linux/uEnv.net` explains why it is the command line and not the node
   that does the work on this kernel.

4. **If the fetch fails** --- server down, cable out, wrong network --- the
   board waits, and never boots anything else. Left to itself U-Boot would
   fall through to `image.ub` with Digilent's own device tree and 512 MB, a
   Linux that owns the CADR's memory; Mete decided the board must never do
   that. The card's file sets `cp_kernel2ram=reset`, replacing the copy step
   the fallback itself would run, so a fetch that fails ends in `resetting
   ...` and another attempt ten seconds later, for as long as the server is
   away. Measured 10 September on the real boot path, server stopped; a
   `|| reset` on the end of the fetch line had been tried first and did not
   fire on that path (`linux/uEnv.txt.in` says why).

   Digilent's stock boot was run once for comparison before that decision,
   from the first card: a login with `Memory: 335116K/524288K`, against
   `303564K/393216K` on the reserved boot.

5. **The kernel's root filesystem is built into `zImage`** (an initramfs), so
   there is no second partition and nothing on the card is mounted by Linux.
   It boots to a shell on the serial console.

### What to look for on the console

The console decides which boot happened, in its first seconds:

    the boot          `Filename 'uEnv.net'` ... `Filename 'system.dtb'` ...
                      `Bytes transferred = 26265`, `reading image.ub`, then
                      `Kernel command line: ... mem=384M cma=32M`
    no server         `TFTP server died; starting again`, `resetting ...`,
                      and U-Boot's banner again ten seconds later; never
                      `reading image.ub` before a `uEnv.net` was fetched

Linux takes the address the DHCP server gives it and starts Dropbear, so the
board can be reached by SSH as `root` with Digilent's default password `root`
(PetaLinux 2017.4; verified 10 September). That Dropbear offers only an RSA
host key, which current clients refuse by default:

    ssh -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa root@<IP>

The root filesystem is in RAM, so anything changed there is gone at the next
reset --- keys and passwords included.

Then, at the prompt, four things say the reservation is real and the CADR ran:

    cat /proc/device-tree/model                       Zynq Arty Z7 Development Board
    ls /proc/device-tree/reserved-memory/             cadr@18000000 (reserved boot only)
    grep "System RAM" /proc/iomem                     00000000-17ffffff
    grep MemTotal /proc/meminfo                       380360 kB, against 512 MB under Digilent's tree
    devmem 0xF800012C 32 $(( $(devmem 0xF800012C) | 0x400000 ))   # this kernel gates the GPIO block's clock; turn it on
    devmem 0xE000A068; devmem 0xE000A06C               0x01008100 twice: 256 reads and 256 writes,
                                                       asked and answered, at the PS7's boundary

Those four lines are what the board printed on 10 September; the third is the
one that matters, since it says the kernel does not have the region at all.

### The steps, in order

Everything up to the power-on has been done once (10 September) and is
recorded in `linux.md`; the steps are here so it can be done again.

**On the build host, once.** The bitstream is the memory-on board,
`DDR=1 OUTDIR=build/ddr vivado -mode batch -source vivado/bitstream.tcl`,
copied to `/srv/tftp/cadr.bit`; the one served on 10 September was built at
`1446bf6`.

    sudo apt install tftpd-hpa                       # serves /srv/tftp on UDP 69
    sudo chown $USER /srv/tftp                       # so the files can be refreshed without root
    sudo usermod -aG dialout $USER                   # so the console can be read
    echo SERVERIP=<the TFTP server's address> > linux/local.conf   # gitignored; mksd.sh fills it into uEnv.txt

`linux/mksd.sh` stages `build/sd/`. Then:

    cp build/sd/server/* /srv/tftp/ && cp build/ddr/cadr_arty.bit /srv/tftp/cadr.bit
    curl -o /dev/null tftp://<the TFTP server's address>/system.dtb   # the server answers

**On the laptop, once.** Copy `build/sd/reserved/{BOOT.BIN,image.ub,uEnv.txt}`
there, insert the card, and identify it by `lsblk` --- the line that says
`usb`, never from memory: it is `/dev/sda` on the laptop and `/dev/sda` is
the system disk on the build host. Then, with `D` set to that device:

    sudo umount ${D}?* 2>/dev/null
    sudo sfdisk --wipe always $D <<'EOF'
    label: dos
    start=2048, type=c, bootable
    EOF
    sudo mkfs.vfat -F 32 -n BOOT ${D}1
    M=$(mktemp -d) && sudo mount ${D}1 $M
    sudo cp BOOT.BIN image.ub uEnv.txt $M/
    sudo sync && sudo umount $M && rmdir $M

One FAT32 primary partition, MBR, type `0x0c`, marked bootable. That is what
the boot ROM looks for and what U-Boot's `fatload mmc 0` resolves to. The
tree and the boot command do **not** go on the card. **Push the card in until
it clicks**: a card that is in the slot but not latched reads as no card, and
the chip then parks in its boot ROM with error code `0x200A` --- seen over
JTAG on the first try.

**At the board.** Card in the microSD slot. Boot-mode jumper to SD --- read
the designator off the silkscreen, it is deliberately not written here.
Ethernet on the TFTP server's subnet. USB to the build host (that cable is both
JTAG and the console).

**Every boot.** Keep the console log running --- it survives the board being
power-cycled, and the port is named by its USB identity rather than by a
`ttyUSB` number, which changes when the board is replugged while something
still holds the old one:

    linux/console.py /dev/serial/by-id/usb-Digilent_Digilent_Adept_USB_Device_003017A6FFE5-if01-port0 build/console.log &

Then reset the board. **Nobody has to be at it**: `rst -srst` from `xsdb`
over JTAG restarts the boot ROM exactly as the SRST button does, and the
USB link stays up, so the log is continuous:

    ~/Xilinx/2026.1/Vivado/bin/xsdb -eval 'connect; targets -set -filter {name =~ "APU*"}; rst -srst'

From reset to a login shell is about two and a half minutes, most of it the
SSH key generation waiting for entropy. The tree fetch is instantaneous; the
47 MB kernel fetch the first card did took 6 s at 7--8 MB/s, and is not done
any more.

### What this does not do yet

- **Anything with the reserved memory.** Linux leaves it alone; nothing yet
  puts a disk pack in it or reads a display out of it.
- **Boot without the TFTP server.** A card holding `uEnv.net`'s command and
  `system.dtb` itself would, at the cost of a card write per change.
