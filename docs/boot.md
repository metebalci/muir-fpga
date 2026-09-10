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
    the TFTP server         muirhost, /srv/tftp   uEnv.net, system.dtb
    the serial console      muirhost, /dev/ttyUSB1
    the card writer         the laptop (t490s)    muirhost has no card reader

The card is written **once**. Its `uEnv.txt` is one line that fetches
`uEnv.net` from muirhost and runs the command in it, so the boot command and
the device tree both live in `/srv/tftp`: a change to either is a `cp` there
and a reset, and the card is never touched again. The kernel and the root
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
   fetch `uEnv.net` from `192.168.80.54` by TFTP and run the `netcmd` it
   defines. That command fetches `system.dtb`, reads `image.ub` off the card,
   and boots the kernel and root filesystem inside it under our tree with
   `mem=384M cma=32M` on the kernel's command line. The board's own address
   comes from DHCP (Mete has reserved `192.168.80.31` for its MAC,
   `00:18:3e:02:a0:ad`); the server's address is in the card's file and a
   DHCP reply cannot overwrite it (`linux.md` says why).

3. **If the fetches succeed**, Linux comes up seeing **384 MB**: `mem=384M`
   is what keeps it off the CADR's region, and the tree's `reserved-memory`
   node names the same region so `/proc/device-tree` says whose it is.
   `linux/uEnv.net` explains why it is the command line and not the node
   that does the work on this kernel.

4. **If the first fetch fails** --- server down, cable out, wrong network ---
   U-Boot falls through to the stock path: `image.ub` from the card, with
   Digilent's own device tree. Linux then sees **512 MB**. This is not an
   error path; it is **the control**. One card, nothing changed on it, and the
   two boots differ only in whether muirhost answered. Stopping the server is
   how the control is run on purpose:

       sudo systemctl stop tftpd-hpa      # control boot, 512 MB
       sudo systemctl start tftpd-hpa     # reserved boot, 384 MB

   Both were seen on 10 September: the control boot reaches a login with
   `Memory: 335116K/524288K`, the reserved boot with `303564K/393216K`.

5. **The kernel's root filesystem is built into `zImage`** (an initramfs), so
   there is no second partition and nothing on the card is mounted by Linux.
   It boots to a shell on the serial console.

## What to look for on the console

The console decides which boot happened, in its first seconds:

    reserved boot     `Filename 'uEnv.net'` ... `Filename 'system.dtb'` ...
                      `Bytes transferred = 26265`, `reading image.ub`, then
                      `Kernel command line: ... mem=384M cma=32M`
    control boot      the `uEnv.net` fetch fails, then `reading image.ub`
                      and a command line without `mem=`

Then, at the prompt, three things say the reservation is real:

    cat /proc/device-tree/model                       Zynq Arty Z7 Development Board
    ls /proc/device-tree/reserved-memory/             cadr@18000000 (reserved boot only)
    grep "System RAM" /proc/iomem                     00000000-17ffffff
    grep MemTotal /proc/meminfo                       380320 kB, against 512 MB in the control

Those four lines are what the board printed on 10 September; the third is the
one that matters, since it says the kernel does not have the region at all.

## The steps, in order

Everything up to the power-on has been done once (10 September) and is
recorded in `linux.md`; the steps are here so it can be done again.

**On muirhost, once.**

    sudo apt install tftpd-hpa                       # serves /srv/tftp on UDP 69
    sudo chown hansolo:hansolo /srv/tftp             # so the files can be refreshed without root
    sudo usermod -aG dialout hansolo                 # so the console can be read

`linux/mksd.sh` stages `build/sd/`. Then:

    cp build/sd/server/* /srv/tftp/
    curl -o /dev/null tftp://192.168.80.54/system.dtb   # the server answers

**On the laptop, once.** Copy `build/sd/reserved/{BOOT.BIN,image.ub,uEnv.txt}`
there, insert the card, and identify it by `lsblk` --- the line that says
`usb`, never from memory: it is `/dev/sda` on the laptop and `/dev/sda` is
the system disk on muirhost. Then, with `D` set to that device:

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
Ethernet to the same subnet as muirhost. USB to muirhost (that cable is both
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

- **Run the CADR at the same time.** The bitstream in the card's `BOOT.BIN`
  is Digilent's. Our own `BOOT.BIN`, with our bitstream and a first-stage
  loader whose `ps7_init` we already possess, is the step after this one.
- **Anything with the reserved memory.** Linux leaves it alone; nothing yet
  puts a disk pack in it or reads a display out of it.
- **Boot without muirhost.** A card holding `uEnv.net`'s command and
  `system.dtb` itself would, at the cost of a card write per change.
