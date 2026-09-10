<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Booting the board into Linux

How the Arty Z7-20 gets from power-on to a Linux prompt with the CADR's memory
reserved, what is on which machine, and the steps in the order they are done.
`docs/linux.md` has the reasoning behind every choice here and the evidence
for it; this file is the procedure. Where the two disagree, `linux.md` was
read out of the binaries and wins.

## The pieces, and where each one lives

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

## What happens at power-on

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

## What to look for on the console

The console decides which boot happened, in its first seconds:

    the boot          `Filename 'uEnv.net'` ... `Filename 'system.dtb'` ...
                      `Bytes transferred = 26265`, `reading image.ub`, then
                      `Kernel command line: ... mem=384M cma=32M`
    no server         `TFTP server died; starting again`, `resetting ...`,
                      and U-Boot's banner again ten seconds later; never
                      `reading image.ub` before a `uEnv.net` was fetched

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

## The steps, in order

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

## What this does not do yet

- **Anything with the reserved memory.** Linux leaves it alone; nothing yet
  puts a disk pack in it or reads a display out of it.
- **Boot without the TFTP server.** A card holding `uEnv.net`'s command and
  `system.dtb` itself would, at the cost of a card write per change.
