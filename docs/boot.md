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
    the TFTP server         muirhost, /srv/tftp   system.dtb, zImage
    the serial console      muirhost, /dev/ttyUSB1
    the card writer         the laptop (t490s)    muirhost has no card reader

The card is written **once**. Everything that changes afterwards --- the
kernel, the device tree --- lives on muirhost and is fetched over Ethernet on
every boot, so a change to the device tree is a `cp` into `/srv/tftp` and a
power cycle, and the card is never touched again.

## What happens at power-on

1. **The boot ROM reads the boot-mode jumper**, sees SD, and loads
   `BOOT.BIN` from the card's first FAT partition. That file is Digilent's:
   the first-stage boot loader (which runs `ps7_init`, so DDR comes up), a
   bitstream for the fabric, and U-Boot. **The bitstream inside it is
   Digilent's stock design, not the CADR** --- an SD boot displaces whatever
   was loaded over JTAG, and until our own `BOOT.BIN` exists, booting Linux
   and running the CADR are two different sessions on the board.

2. **U-Boot reads `uEnv.txt` from the card** and runs the command in it:
   fetch `system.dtb` and `zImage` from `192.168.80.54` by TFTP, then boot
   them. The board's own address comes from DHCP; the server's address is in
   the file and a DHCP reply cannot overwrite it (`linux.md` says why).

3. **If both fetches succeed**, the kernel boots with our device tree, which
   carries a `reserved-memory` node for `0x1800_0000`, 128 MB, `no-map`.
   Linux then sees **384 MB** and never touches the CADR's region.

4. **If the first fetch fails** --- server down, cable out, wrong network ---
   U-Boot falls through to the stock path: `image.ub` from the card, with
   Digilent's own device tree. Linux then sees **512 MB**. This is not an
   error path; it is **the control**. One card, nothing changed on it, and the
   two boots differ only in whether muirhost answered. Stopping the server is
   how the control is run on purpose:

       sudo systemctl stop tftpd-hpa      # control boot, 512 MB
       sudo systemctl start tftpd-hpa     # reserved boot, 384 MB

5. **The kernel's root filesystem is built into `zImage`** (an initramfs), so
   there is no second partition and nothing on the card is mounted by Linux.
   It boots to a shell on the serial console.

## What to look for on the console

The console decides which boot happened, in its first seconds:

    reserved boot     `TFTP from server 192.168.80.54` ... `Bytes transferred = 26265`
                      then `Bytes transferred = 47451456`, then `Starting kernel`
    control boot      `Retry count exceeded` or `TFTP error`, then
                      `reading image.ub` and `Starting kernel`

Then, at the prompt, three things say the reservation is real:

    cat /proc/device-tree/model                       Zynq Arty Z7 Development Board
    ls /proc/device-tree/reserved-memory/             cadr@18000000 (reserved boot only)
    free -m  /  cat /proc/meminfo | head -1           about 384 MB, against about 512 in the control

The exact free figure is not known until a boot is seen; the kernel and
initramfs take some of both. What is asserted is the **difference**: 128 MB
less on the reserved boot, and the node present.

## The steps, in order

Everything up to the power-on has been done once (10 September) and is
recorded in `linux.md`; the steps are here so it can be done again.

**On muirhost, once.**

    sudo apt install tftpd-hpa                       # serves /srv/tftp on UDP 69
    sudo chown hansolo:hansolo /srv/tftp             # so the files can be refreshed without root
    sudo usermod -aG dialout hansolo                 # so the console can be read

`linux/mksd.sh` stages `build/sd/`. Then:

    cp build/sd/reserved/system.dtb build/sd/reserved/zImage /srv/tftp/
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
the boot ROM looks for and what U-Boot's `fatload mmc 0` resolves to.
`system.dtb` and `zImage` do **not** go on the card.

**At the board.** Card in the microSD slot. Boot-mode jumper to SD --- read
the designator off the silkscreen, it is deliberately not written here.
Ethernet to the same subnet as muirhost. USB to muirhost (that cable is both
JTAG and the console).

**Every boot.** Start the console log *before* power, so U-Boot's first line
is in it, then power the board:

    linux/console.py /dev/ttyUSB1 build/console.log &
    # power on
    tail -f build/console.log

The log carries a wall-clock stamp per line, so the fetch time of the 47 MB
kernel --- which `linux.md` calls unmeasured --- is the difference between
two stamps.

## What this does not do yet

- **Run the CADR at the same time.** The bitstream in the card's `BOOT.BIN`
  is Digilent's. Our own `BOOT.BIN`, with our bitstream and a first-stage
  loader whose `ps7_init` we already possess, is the step after this one.
- **Anything with the reserved memory.** Linux leaves it alone; nothing yet
  puts a disk pack in it or reads a display out of it.
- **Boot without muirhost.** A card holding `system.dtb` and `zImage` itself
  would, at the cost of a second card write per device-tree change; `linux.md`
  has the one-line variant.
