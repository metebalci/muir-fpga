# Cora Z7-07S

The Digilent Cora Z7 is a small Zynq-7000 board. This directory is for the
XC7Z007S variant of it, which is the one this project targets.

**The machine fits on it and closes timing.** That was a ratio out of a part
database until this directory was built, and it is a placed and routed figure
now. **And the machine runs on it.** The section "On silicon" below has what
the board has been made to do and what it has not.

## What the board is

Every fact below comes from a file Digilent publishes. The part is
`xc7z007sclg400-1`, named in `board.xml` in Digilent's `vivado-boards`
repository, and it has 14,400 LUTs, 28,800 flip-flops, 50 block RAMs and 66
DSP slices against the XC7Z020's 53,200, 106,400, 140 and 220.

The processing system is configured as Digilent's own board preset configures
it. That preset is `preset.xml` beside `board.xml`, and it is what
`vivado/ps7_config.tcl` in this directory transcribes. Read off it, the board
has:

| | |
|---|---|
| UART 0 | MIO 14 to 15, 115200 baud, the console |
| Ethernet 0 | MIO 16 to 27, MDIO on MIO 52 to 53, PHY reset on MIO 9 |
| USB 0 | MIO 28 to 39, PHY reset on MIO 46, a host port |
| SD 0 | MIO 40 to 45, card detect on MIO 47, the microSD slot |
| Quad SPI | disabled |
| DDR3 | one MT41K256M16 RE-125 on a 16-bit bus at 525 MHz, 512 MB |
| crystal | 50 MHz, with the processor at 650 MHz |

**That MIO map is the Arty Z7-20's, peripheral for peripheral and pin for
pin.** The two presets were compared property by property. The same four
peripherals sit on the same MIO ranges with the same three reset pins, and
both boards carry the same DDR3 device at the same width and the same speed.
Quad SPI is the one peripheral the two do not share. So a device tree written
for one board describes the peripherals of the other.

Digilent's Ethernet PHY is a Realtek RTL8211E-VL at MDIO address 1. That comes
from their own device tree for this board, which names the part in a comment.

The programmable logic side is Digilent's master pin file,
`Cora-Z7-07S-Master.xdc` in this directory. It gives the board a 125 MHz system
clock on pin H16, two RGB LEDs, two push buttons, two Pmod headers named JA and
JB, a shield connector and the analogue inputs. There are no plain LEDs, no
slide switches, and **no HDMI section at all**, where the Arty Z7-20's master
file has both a receiver and a transmitter.

**Most of the pins this design uses are the same pins on both boards.** They
were compared one at a time against `boards/arty-z7-20/cadr_arty.xdc` and
against both master files. The system clock, all six RGB LED pins and all
sixteen Pmod pins are identical, both boards being the same `clg400` package
laid out alike. The two buttons are the Arty's first two with their indices
exchanged: the Arty's `btn[0]` is D19 and this board's is D20. So the one pin a
reader would get right from memory is the one that is wrong, which is why every
pin here comes from the file.

## What is here

| | |
|---|---|
| `cadr_cora.sv` | the top level: the clock generator, the machine, the fold, the lamps |
| `cadr_cora.xdc` | the pins the design uses, and the board clock |
| `cadr_probe.xdc` | the debug probe's own constraints |
| `cadr_ps7.sv` | the generated processing-system wrapper |
| `vivado/` | the board flow, the processing system's configuration and the start-up routine |
| `linux/` | the device tree, the U-Boot environment and the Buildroot configuration |
| `Cora-Z7-07S-Master.xdc` | Digilent's published pin file, byte for byte |

**Nothing in `rtl/` changes between the two boards.** A second Zynq board is a
top level, a pin file, a processing-system configuration and a device tree. The
machine does not know what part it is on.

## The fit

Measured at commit `86d787b` with `DDR=1`, which is the machine with the
processing system and DDR3 behind its memory port. The Arty Z7-20's figures
beside it are from the same commit with the same switch, so the two are the
same design placed on two parts.

| | Cora Z7-07S | Arty Z7-20 |
|---|---|---|
| worst slack | **+0.495 ns, met** | +0.236 ns, met |
| failing endpoints | 0 of 48,104 | 0 of 47,935 |
| hold | +0.019 ns, met | +0.036 ns, met |
| slice LUTs | 12,352 of 14,400, **85.78%** | 12,130 of 53,200, 22.80% |
| of which logic | 9,999 | 9,773 |
| of which memory | 2,353 | 2,357 |
| slice registers | 9,106 of 28,800, 31.62% | 9,041 of 106,400, 8.50% |
| block RAM tiles | 41.5 of 50, **83.00%** | 41.5 of 140, 29.64% |
| DSP slices | 4 of 66, 6.06% | 4 of 220, 1.82% |
| bonded pins | 25 of 100 | 25 of 125 |
| timing exceptions | 8 | 8 |

**The two block RAM figures are the same number, and that is the useful
reading.** The design spends 41.5 tiles on either part, so what changes between
the boards is the denominator and nothing else. The LUT counts are within two
per cent of each other for the same reason.

**The exception count is what says the constraints reached the design.**
`rtl/plumbing/xilinx7/cadr_machine.xdc` relaxes every register it does not
name, so a new module joins that relaxed set in silence and its paths are then
timed at a deadline nobody wrote for them. Eight exceptions on both boards is
the same constraint file reaching the same design twice.

**Read the slack figures with their commit and not as precision.** A
bit-identical netlist has moved worst slack by a quarter of a nanosecond in
this project before, which is placement and not design.

**And the out-of-context flow agrees.** `cadr_machine` alone, with no top
level, no output fold and no MMCM, placed and routed for this part reads
+0.668 ns met, 9,720 slice LUTs and 40.5 block RAM tiles. That flow and the
board flow measure different designs and are meant to.

## What is left out, and why

**There is no display output and no `S_AXI_HP3`.** The board has no HDMI
connector, so there is nothing for the display block to drive. `cadr_cora.sv`
has no `HDMI` parameter, the port list has no differential pairs, and
`cadr_ps7.sv` here does not bring that port out. The CADR's screen on this
board is `cadr-terminal`'s RFB server over the network, which is how it is
served on the other board as well.

**There is no USB input.** The `cadr-usb-input` package is not installed, nor
is `evtest`, nor the init script that tells the USB PHY to drive VBUS. A
keyboard and mouse reach the machine from a viewer over the network, through
`cadr-terminal`, which is the one program that writes the input face's
registers on either board. The device tree still declares the USB port as a
host, because the port exists and Digilent's own tree declares it; a board that
later wants USB input takes the package and the VBUS script together and
nothing in the fabric changes.

**There is no `no_auto_boot` switch.** On the Arty Z7-20 a slide switch holds
the machine at power-on as a CADR is held when its power comes on with nobody
at it. This board has no switches, so `no_auto_boot` is tied low and the hold
is the card's `fpgarc` flag alone. That flag works here exactly as it does
there, the console being on `M_AXI_GP1` on both boards. What is lost is the
hold on a board whose Linux is not up yet, which is a bring-up convenience.

## The lamps and the buttons

The board has two RGB LEDs and nothing else, so what they show is a decision
and not a translation of the other board's six. The CADR's own light panel
carried a run lamp and an error lamp beside the boot button, and BTN0 is that
button here, so the two lamps are the two the panel had.

| | |
|---|---|
| LD0 | `MACHRUN`, green, as a level. Lit means the machine should be running. |
| LD1 | red for `ERRHALT`, blue for `-PROMDISABLE`, otherwise green blinking with the microcycles. |

Red wins over blue and blue over green. The three read in the order a boot goes
through them. Blue is the machine running its microcode out of the boot PROM,
and it goes out when the machine has loaded microcode off the disk. Green
blinking is the machine executing, and it freezes when the machine stops. Red
is the machine halting itself under ERRSTOP, latched and cleared by any boot
press. So blue then green is a boot, green gone still is a machine somebody
halted, and red is a machine that fell over.

LD0's brightness is the fraction of time the machine computes rather than
waits, because `MACHRUN` drops during every memory stall. Dim means it is
thrashing.

**`-PROMDISABLE` is the mode register's own bit and not `PROMENABLE`.** Those
are different nets. `PROMENABLE` is the PROM's select and follows the program
counter, so it changes many times a boot; what reaches the pin is the bit the
machine sets once, when it has finished loading its microcode.

**Two lamps cannot carry six meanings and what is missing is said rather than
left to be found.** The fabric's own heartbeat has no lamp here, so a board
that was never programmed, a board whose clock generator never locked and a
machine that has stopped all look the same. Disk activity has no lamp either,
so a pause cannot be told from the disk by looking. Both signals are still
outputs of the machine and still in the fold that keeps the datapath alive;
what is missing is a pin and not a wire.

BTN0 is the boot button and BTN1 resets the whole fabric. There are only two
buttons, so the control that throws the machine's state away sits next to the
one that restarts it politely. On the Arty Z7-20 the reset is at the far end of
a row of four, where it is hard to press by accident. That is the cost of a
two-button board.

## The debug cable

The decision is one connector, JA, carrying the whole link both ways, with JB
unassigned. A board is a debugger or a debuggee by configuration and never both
at once. The sixteen pins in `cadr_cora.xdc` are the earlier two-connector
arrangement, which is what is built today; they are the same sixteen pins the
Arty Z7-20 uses, so a cable between the two boards needs nothing said about it.

## The processing system

`vivado/ps7_config.tcl` is Digilent's own board preset for this board,
transcribed verbatim, with nine properties of ours merged over it: `S_AXI_HP0`
and `S_AXI_HP2` at 64 bits, `M_AXI_GP1`, and the fabric interrupt. Its header
records the repository, the commit and the sha256 of the file it came from, and
gives the command that checks the pointer has not rotted.

**The Arty Z7-20's routine was derived from Digilent's own Vivado project for
that board. That route is not available for this one.** Digilent's
`Cora-Z7-HW` repository has per-board branches and the ones for this board are
empty root commits, which is the same rot the Arty's own superproject has
already been through. So this comes from the board files instead, which are the
artefact Vivado itself consumes and are maintained rather than archived.

**The Arty's routine also has an independent control and this one does not.**
That board's is compared operation for operation against the one in Digilent's
PetaLinux BSP for it, a different tool eight releases apart, and the two agree
character for character. No such artefact was found for the Cora Z7-07S. What
holds this one is the provenance of the preset and the committed `.ops` file.

### How the two routines differ

Generated and compared under Vivado 2026.1. The routine is 668 operations in 25
procedures against the Arty's 673 in 24.

**The DDR3 initialisation is byte-identical**, every operation of it, on all
three silicon revisions. Both boards carry the same memory device at the same
width and the same speed.

**`ps7_post_config` is byte-identical too**, which is the pair of writes that
brings the PS-PL level shifters up. That is the measurement the other board's
notes predict: at 64 bits, enabling an HP port changes the routine by nothing.

**This board's routine has a procedure the other's does not: `ps7_apu_reset`.**
It is one write to SLCR `A9_CPU_RST_CTRL` at `0xF8000244`, mask and value
`0x00000022`, and Vivado emits it for a single-core part and calls it before
anything else. That register's name is Xilinx's own, from the register
description shipped with Vivado.

The rest of the difference is the clock tree and the pin multiplexing, and
every piece of it is explained by the two boards' own configurations. This
board has no CAN and no Quad SPI, so those clocks are not enabled; it asks for
one fabric clock where the other asks for two; its UART divisor differs; and
its MIO pull-ups differ on the pins Quad SPI would have used.

## Linux

The Buildroot tree here holds the board and nothing else. **The packages are
the Arty Z7-20's and there is one copy of them**, so a build is given both
external trees:

    BR2_EXTERNAL=boards/arty-z7-20/linux/buildroot:boards/cora-z7-07s/linux/buildroot

`make buildroot-cora` does that, into an output directory of its own. The
kernel configuration and the post-build script are the other board's files,
named by path from this board's defconfig, because both describe a Zynq-7000
with the same peripherals and a second copy is a second thing to keep current.

The device tree is this board's. It is the Arty Z7-20's with three differences:
`cpu1` is disabled, because this is a single-core part; there is no Quad SPI
node, because this board's processing system has that peripheral disabled; and
the model and compatible strings are Digilent's own for this board. The
reserved-memory node is the other board's file included from here, because the
CADR's 128 MB at `0x18000000` is a property of the machine and not of the
board.

The U-Boot environment file is `cadr_cora.env` rather than `cadr.env`. Both
trees' hooks run on every build of this tree, and two hooks writing one
destination would be a race decided by which was appended last.

The card is staged by `boards/arty-z7-20/linux/mksd-buildroot.sh`, which now
takes the board in two variables:

    BOARD_DIR=boards/cora-z7-07s BOARD_DTB=zynq-cora-z7-07s.dtb \
        BIT=build/cora-ddr/cadr_cora.bit boards/arty-z7-20/linux/mksd-buildroot.sh

Both default to the Arty Z7-20's, so a run that sets neither is the run that
script has always been. The private values, which are the server address, the
MAC and the Chaosnet numbers, come from `linux/local.conf` in this directory,
which is gitignored as the other board's is. Two boards on one network need
different Chaosnet addresses, and the development allocation reserves a second
pair for exactly that.

## On silicon

**The start-up routine is right and the memory controller answers.**
`vivado/ddr_check.tcl` was run over JTAG with no bitstream and no
`ps7_post_config`. It read `PSS_IDCODE` as `0x13723093`, whose device identity
is the `0x03723093` this part must carry, and `PCAP_PS_VERSION` as 3, which is
silicon 3.1 and takes `ps7_init`'s else branch onto the 3.0 tables exactly as
the other board does. Then DDR answered: the proving word and its complement at
`0x18A72EE4` with its neighbour untouched, 26 walking-one addresses across the
machine's region, and a word and its complement sixteen bytes below the top of
the 512 MB.

**Uninitialised DDR reads in half-word bands on this board.** Before anything
was written, the words at `0x18000000` read `0x0000FFFF` and the words at
`0x19000000` read `0xFFFF0000`, with a scatter of single flipped bits and no
change between two reads. So an unwritten word here is neither zero nor all
ones, and anything that would take one of those halves as evidence a write
happened is testing nothing. That is the same trap the other board's own bands
carry, in a different shape.

**The machine runs MIT's boot PROM out of real DDR3.** The bitstream was
programmed after `ps7_init` and `ps7_post_config`, the part asserted DONE, and
the level shifters stayed up across the download. The console answered `CONS` at
`0x80000000` over `M_AXI_GP1`, read through the debugger, and the machine
retired 4,000,388 microcycles in 2.01 seconds. Its program counter sat in the
boot PROM's no-drive loop, `0o541` to `0o553`, with `MD` holding `0x2321`, which
is the disk controller's own no-drive status. `FLAG-1` read `0xE900`: running,
no error, every parity bit clean, and `PROMDISABLE` clear.

**And the memory tally witnessed the traffic from outside the design.** The two
EMIO GPIO words both read `0x01008100`: 256 reads and 256 writes asked, and 256
reads and 256 writes answered, which is the boot PROM's identity copy of page 0
and the whole of its main-memory traffic. Page 0 read back afterwards holds
exactly what the debugger had written into it. That is the other board's step
four, on this one.

**What a person at the board sees is LD0 green and LD1 steady blue.** LD0 is
`MACHRUN` and the machine is running. LD1 is blue because the machine is still
in its boot PROM, and there is no green blink under it: the blink is gated
behind `PROMDISABLE`, so it only appears once the machine has loaded microcode
off a disk. With no drive that never happens, so LD1 stays blue and nothing on
this board moves. Two lamps cannot say everything, and this is the case where
what they cannot say is whether the fabric is still clocked.

## What has not been done

No image has been built from this Buildroot configuration and no card has been
written, so nothing on this board has run Linux or served the machine a disk.

Three Vivado flows the Arty Z7-20 has are not ported here: the probe readout,
the two proving scripts and the memory tally's run script. The parameters they
build are in `cadr_cora.sv` and the bitstream flow, so what is missing is the
script that programs a board and reads it back. The proving boards, `PROVE=1`
and `PROVE=2`, were the other board's way of proving the memory path before the
machine was put behind it; here the tally above witnessed the machine's own
cycles directly, so what they would add is the two directions taken apart.

**Two scripts are read out of the other board's directory on purpose.**
`vivado/tick.tcl` parses the clock generator's four parameters out of whatever
file it is given, and `vivado/constraints_check.tcl` asks a design what setup
requirement its paths carry. Neither knows anything about a part. They live in
the first board's directory because that is where they were written, and a copy
here would be a second description of one rule. When a directory shared between
boards exists, those two move into it.

**And `vivado/ddr_check.tcl` here is a front end of eight lines and a page of
reasons.** It sets the six facts that differ between the boards and sources the
other board's file, which is where the check itself lives. That is the shape
`vivado/gen_ps7.py` and `vivado/ps7_ops.py` in this directory already use.

**Every script that reaches a board names it by its cable serial.** Several
boards hang off one hub here, and a filter that names a part or a target number
can reach the wrong one. The serial comes from `JTAG_SERIAL` in the environment
or from `linux/local.conf`, which is gitignored: a cable serial identifies one
physical board the way its MAC address does. With more than one Zynq attached
and no serial given, the check refuses to run.

## Why the pin file is vendored

Pins come from Digilent's published file and never from memory. A wrong pin is
a light that does not come on, and that reads as a design fault in the machine.

`Cora-Z7-07S-Master.xdc` is that file, byte for byte as published, under
Digilent's own filename. The name is kept so that "is this the published file"
is answerable by eye and by one `sha256sum`.

| | |
|---|---|
| repository | `github.com/Digilent/digilent-xdc` |
| commit | `00a3404901f35aa9567b01ecb3f2c233b6efe9f4` |
| commit date | 2024-11-12 |
| original filename | `Cora-Z7-07S-Master.xdc` |
| size | 14,113 bytes |
| sha256 | `7d689e023461834428a4f3b2b803ac94c66efb8d6994947d583bc4f5095c6eb5` |
| board revision it names | Cora Z7-07S Rev. B |

Every pin in it is commented out, which is how Digilent publishes it.
`cadr_cora.xdc` copies out the pins the design uses and cites this file in its
header.

`Digilent-License.txt` is the MIT licence text from the same repository and the
same commit, 1,064 bytes, sha256
`fbdfae05e542ea6ad7e11e3818076b46d2b6bd81dac49c59bc9ac78025ba5339`. Digilent
publishes it as `License.txt` and it is renamed here so that nobody reads it as
the licence of this directory. Everything else here is AGPL.

## The Z7-10 is not the answer

The same Cora board exists with an XC7Z010. Vivado's database gives that part as
17,600 LUTs, 35,200 flip-flops, 60 block RAMs and 80 DSP slices, which would
turn 85.8% and 83.0% into 70.2% and 69.2% and bring a second Cortex-A9 with it.

**It is ruled out because it is no longer sold.** A project meant to be
reproducible by somebody else cannot target a part they cannot buy. Nobody
should rediscover the Z7-10 and think it solves this.

## One core, not two

The XC7Z007S has one Cortex-A9 where the XC7Z020 has two. muir on the other
board was measured to cost the fabric machine nothing with both cores
saturated. On one core it shares that core with the disk pack program, which is
on the machine's critical path, and nobody has measured what that costs.

The device tree disables `cpu1` and the start-up routine holds it in reset, so
Linux does not spend its boot looking for a core that is not there.

## What the tight figures mean

At 85.8% of the lookup tables and 83.0% of the block RAM, this is by a wide
margin the tightest of the boards in this repository. Three things make that
less comfortable than it reads.

Removing the display output and USB input saves nothing, because neither is
built here. Those figures are the floor and not a starting point to trim from.

The display output block is a scan-out path and is memory-hungry. It is exactly
what a board with no HDMI does not need, which is why this board was worth
settling before that work started.

And the honest lever, if it ever comes to it, is the block store. Dropping the
debug cable, the second general-purpose port and muir frees lookup tables, and
lookup tables are not what binds. The memory is the control store, the
scratchpads, the disk's block store and the Chaosnet's packet buffers, and the
block store is the one measured in whole block RAMs.
