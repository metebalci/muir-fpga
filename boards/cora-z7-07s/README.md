# Cora Z7-07S

The Digilent Cora Z7 is a small Zynq-7000 board. This directory is for the
XC7Z007S variant of it, which is the one this project targets.

**Nothing here builds anything.** This directory holds Digilent's published pin
file and this note. There is no top level, no constraint file of ours, no
Vivado script and no device tree.

## What a complete board directory holds

Read off `boards/arty-z7-20/`, which is the finished one.

| | |
|---|---|
| `cadr_arty.sv` | the top level: the clock generator, the machine, the fold, the lamps |
| `cadr_arty.xdc` | the pins the design uses, and the board clock |
| `cadr_probe.xdc` | the debug probe's own constraints |
| `cadr_ps7.sv` | the generated processing-system wrapper |
| `vivado/` | fifteen scripts: synthesis, place and route, the bitstream, the `ps7_init` derivation, the proving flows and the probe readout |
| `linux/` | the Buildroot tree, the device tree, the card image and the packages for every program that runs beside the machine |

That is 142 tracked files. This directory has three, one of them this note.

## What carries over unchanged

Everything in `rtl/`. The machine is the machine and does not know what part it
is on.

The clock recipe carries over literally. Digilent's file puts the Cora's PL
system clock on pin H16 at 125 MHz, which is the same pin and the same
frequency as the Arty Z7-20's. So `cadr_arty.sv`'s MMCM arithmetic holds with
nothing changed. It multiplies 125 MHz by 8 to get a 1000 MHz VCO and divides
that by 10, so the divider reads literally as the tick in nanoseconds and the
tick stays 10 ns. No tick count in the design moves and no check moves with it.

The two Pmod headers are named JA and JB here as they are on the Arty Z7-20, so
the debug cable's assignment of JA to DBGOUT and JB to DBGIN carries over by
name. The pins behind those names are different and must be taken from the file
in this directory.

## What has to be built

A top level and a pin file for this board. A processing-system configuration,
because the XC7Z007S is a different part with a different MIO map and a
different DDR device, so `ps7_init` must be derived for this board rather than
copied. A device tree and a Buildroot configuration.

The lamp assignment has to be re-decided, because this board does not have the
lights the assignment was written for. Digilent's file shows **two RGB LEDs and
nothing else**, where the Arty Z7-20 has four plain LEDs and two tricolour ones.
`docs/board.md` spends six lamps on the clock, microcycles, the boot state,
disk activity, whether the last cycle was answered and what the machine is
doing. Two RGB lamps cannot carry six meanings, so what the Cora shows is a
decision and not a translation.

There are two buttons here where the Arty Z7-20 has four, and no switches at
all.

## What is absent by the board's own shape

**There is no HDMI.** Digilent's master file has no HDMI section, where the
Arty Z7-20's has both an RX and a TX one. So the display output block does not
apply to this board, and neither does the plan of driving the CADR's screen
straight from the fabric to a monitor. The screen on a Cora is the RFB server
over the network, which is what `cadr-terminal` already does.

USB input is the same story one step along. The keyboard and mouse reach Linux
over the processing system's own USB host port on the Arty Z7-20, and whether
this board brings that port out is a question for Digilent's documentation and
is not established here.

## The part, and what is known about the fit

Vivado's own part database at 2026.1 gives the XC7Z007S as **14,400 LUTs,
28,800 flip-flops, 50 block RAMs and 66 DSP slices**. The XC7Z020 on the Arty
Z7-20 is 53,200, 106,400, 140 and 220.

Today's memory-on design, placed and routed for the XC7Z020 at commit
`95cbb84`, is **10,909 slice LUTs, 7,390 slice registers, 41.5 block RAM tiles
and 4 DSP slices**, closing timing at +0.914 ns. Put beside the smaller part
those figures read:

| | used | XC7Z007S has | |
|---|---|---|---|
| LUTs | 10,909 | 14,400 | 75.8% |
| flip-flops | 7,390 | 28,800 | 25.7% |
| block RAM tiles | 41.5 | 50 | **83.0%** |
| DSP | 4 | 66 | 6.1% |

**It fits, and block RAM is what binds.** It is also by a wide margin the
tightest of the four boards in this repository. The same design is 30.7% of the
Arty A7-100's block RAM and 55.3% of the Arty S7-50's, and 29.6% of the Arty
Z7-20's. So the small Zynq is the hard board, and the Artix and the Spartan are
not, which is the opposite of what the part numbers suggest.

That 83% also inverts the obvious plan for making room. Dropping the debug
cable adapter, the second general-purpose port, muir and the Pmod debugging
frees lookup tables, and lookup tables are not the problem. The memory is the
control store, the scratchpads, the disk's block store and the Chaosnet's
packet buffers, so the honest lever if it ever comes to it is the block store,
which is measured in whole block RAMs.

Three things make 83% less comfortable than it reads.

Removing HDMI and USB input saves nothing, because neither is built. The 83% is
the floor and not a starting point to trim from.

The display output block is a scan-out path and is memory-hungry. It is exactly
what a board with no HDMI does not need, which is why this board is worth
settling before that work starts.

The XC7Z007S has **one Cortex-A9 where the XC7Z020 has two**. muir on the board
was measured to cost the fabric machine nothing with both cores saturated. On
one core it would contend with `cadr-disk-packs`, which is on the machine's
critical path.

## What is not known

**The table above is an indication and not a fit.** Those are the XC7Z020's
placed-and-routed figures. A different part places and packs differently, and
the only way to know whether this design fits and closes timing on an XC7Z007S
is to build it for one.

**That is possible today and nobody has done it.** The part is in Vivado's
database and the out-of-context flow takes its part from the environment:

    make build/boot_prom.hex
    PART=xc7z007sclg400-1 vivado -mode batch \
        -source boards/arty-z7-20/vivado/fit.tcl

That synthesises `cadr_machine` on its own, with no top level, no output fold,
no MMCM and no package pins, so it answers the LUT and block RAM question
before any of the work above is started.

It is not the whole answer. The out-of-context flow and the board flow measure
different designs and are meant to, and `boards/arty-z7-20/vivado/fit.tcl`'s own
header records both figures and why they differ. And the package and speed
grade of the part Digilent actually fits should be confirmed against the board,
rather than taken from the line above.

Whether the board's own peripherals are where the Arty Z7-20's are is not
established here. Digilent's master file constrains PL pins only, so it says
nothing about the microSD card, the Ethernet port or the USB port, all of which
are on the processing system's own pins on the Arty Z7-20.

## The Z7-10 is not the answer

The same Cora board exists with an XC7Z010. Vivado's database gives that part
as 17,600 LUTs, 35,200 flip-flops, 60 block RAMs and 80 DSP slices, which would
turn 75.8% and 83.0% into 62.0% and 69.2% and bring a second Cortex-A9 with it.

**It is ruled out because it is no longer sold.** A project meant to be
reproducible by somebody else cannot target a part they cannot buy. Nobody should rediscover
the Z7-10 and think it solves this.

## The pin file

`Cora-Z7-07S-Master.xdc` is Digilent's published master file, byte for byte as
published, under Digilent's own filename. The name is kept so that "is this the
published file" is answerable by eye and by one `sha256sum`.

| | |
|---|---|
| repository | `github.com/Digilent/digilent-xdc` |
| commit | `00a3404901f35aa9567b01ecb3f2c233b6efe9f4` |
| commit date | 2024-11-12 |
| original filename | `Cora-Z7-07S-Master.xdc` |
| size | 14,113 bytes |
| sha256 | `7d689e023461834428a4f3b2b803ac94c66efb8d6994947d583bc4f5095c6eb5` |
| board revision it names | Cora Z7-07S Rev. B |

Every pin in it is commented out, which is how Digilent publishes it. Nothing
in this repository reads the file, because every Vivado glob and every
Verilator include path names `boards/arty-z7-20` explicitly. It is a reference.
The convention once a top level exists is the one
`boards/arty-z7-20/cadr_arty.xdc` follows, which is to copy out the pins the
design uses and cite this file in the header.

`Digilent-License.txt` is the MIT licence text from the same repository and the
same commit, 1,064 bytes, sha256
`fbdfae05e542ea6ad7e11e3818076b46d2b6bd81dac49c59bc9ac78025ba5339`. Digilent
publishes it as `License.txt` and it is renamed here so that nobody reads it as
the licence of this directory. Everything else here is AGPL.
