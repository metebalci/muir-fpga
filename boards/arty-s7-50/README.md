# Arty S7-50

The Digilent Arty S7 is a Spartan-7 board. This directory is for the S7-50
variant, whose part is an XC7S50.

**Nothing here builds anything.** This directory holds Digilent's published pin
file and this note. There is no top level, no constraint file of ours, no
Vivado script and no memory controller.

**The part has room and the work does not exist.** Today's design would be 33.5%
of this part's logic and 55.3% of its block RAM, which is comfortable. What is
missing is not fabric. It is everything the Zynq's processing system does, which
on a Spartan-7 there is none of.

## This is not a port

A Spartan-7 has no processing system. That is the whole difference, and it is a
large one. `boards/README.md` lists what the processing system does on the Arty
Z7-20 and what each of those things would have to become here. The short
version is main memory, the disk, the screen, the console, Chaosnet, the serial
line and the debugger, all of which are Linux programs today.

What carries over is the machine. Everything in `rtl/machine/` is plain
SystemVerilog and does not know what part it is on. The Xilinx-specific pieces
in `rtl/plumbing/xilinx7/` are seven-series, so the debug probe's `BSCANE2` and
the constraint syntax carry over as well.

What does not carry over is `boards/arty-z7-20/cadr_ps7.sv`, every `ps7_*`
script in that directory's `vivado/`, and the whole of its `linux/` tree.

## This is the last in the order

This is the last of the three preliminary boards. `boards/README.md` records
that order and what it is worth.

It is also the hardest of the three, and not because of the part. The part has
room, as the table below shows. What makes it hard is that of the two boards
with no processing system, the Arty A7-100 has an Ethernet PHY on fabric pins
and this one has none at all. So this is the board where every one of the
fabric answers has to exist and the network is not one of them.

## The board, read off Digilent's file

There are two clocks. A 12 MHz oscillator on pin F14, and a 100 MHz one on pin
R2 at the SSTL135 standard, which Digilent's own comment names `ddr3_clk[200]`
in the schematic. The Arty Z7-20 and the Cora have one 125 MHz clock each, so
the MMCM recipe in `boards/arty-z7-20/cadr_arty.sv` does not carry over
arithmetically and has to be recomputed for whichever of these two is used.

The tick counts do not change and no check moves. What changes is the
multiplier and the divider that make a 10 ns tick from a different input. The
property worth preserving is the one that board relies on: its VCO is exactly
1000 MHz, so the output divider reads literally as the tick in nanoseconds and
a reader can see the tick in the source without doing arithmetic.

There are four switches, four plain LEDs, two RGB LEDs and four buttons. That
is exactly what the Arty Z7-20 has, so the six-lamp assignment in
`docs/board.md` fits this board without a decision.

There are four Pmod headers, JA through JD, where the Arty Z7-20 has two. The
debug cable adapter's assignment of JA to DBGOUT and JB to DBGIN therefore
carries over by name, and two spare headers remain. Digilent's file notes that
JC and JD share pins with the inner ChipKit digital header and cannot be used
at the same time.

There is a USB-UART bridge on PL pins. The Arty Z7-20's master file constrains
no UART pins at all, so whatever serial port that board has is the processing
system's and its fabric cannot see it. Here it is the fabric's.

**There is no Ethernet of any kind in Digilent's file.** The Arty A7-100's
master file constrains a full PHY interface and this one constrains nothing at
all. So on this board Chaosnet has no wire to reach, and neither does a remote
viewer. Whatever leaves this board leaves over the serial bridge or over a
Pmod.

There is a Quad SPI flash. Digilent's file notes that its clock can be driven
through the `STARTUPE2` primitive.

**There are no memory pins in Digilent's file.** The only mention of memory
anywhere in it is that schematic name on the 100 MHz clock. What memory device
the board carries, and what reaching it from fabric would cost, has to come
from Digilent's documentation and is not established here. It is the first
question to answer, because main memory is 15 MB and cannot live in block RAM.

## The part is not the obstacle. The work is.

**There is room on this part, and that is the opposite of what was expected.**
Vivado's own part database at 2026.1 gives the XC7S50 as **32,600 LUTs, 65,200
flip-flops, 75 block RAM tiles and 120 DSP slices**. Those four counts are
properties of the die, so the package and the speed grade do not change them.

Today's memory-on design, placed and routed for the Arty Z7-20 at commit
`95cbb84`, is 10,909 slice LUTs, 7,390 slice registers, 41.5 block RAM tiles and
4 DSP slices. Beside this part that reads:

| | used | XC7S50 has | |
|---|---|---|---|
| LUTs | 10,909 | 32,600 | 33.5% |
| flip-flops | 7,390 | 65,200 | 11.3% |
| block RAM tiles | 41.5 | 75 | 55.3% |
| DSP | 4 | 120 | 3.3% |

**Block RAM is the column to watch, as it is everywhere in this project, and
55.3% is comfortable.** It is well short of the Cora Z7-07S's 83.0% for the same
design, and this part has three times the logic headroom the Cora has.

**But that number is misleading on its own, and the reason is the section
above.** On this part the design in the table is not the design that would run
here. There is no processing system, so main memory needs a controller in the
fabric and the disk needs a way to read a card, and the screen, the console,
Chaosnet, the serial line and the debugger all lose the Linux programs that
implement them today. Every one of those costs logic and block RAM that the
percentages do not include.

So the honest reading is that the part is not the obstacle on this board. The
work is.

## The smaller variant of this board is not the cheap way in

The same board exists as the Arty S7-25, whose part is an XC7S25. Vivado's
database gives it as 14,600 LUTs and 45 block RAM tiles, so today's design would
already be **74.7% of its logic and 92.2% of its block RAM** before a single one
of the fabric answers above was added.

That is tighter than the Cora Z7-07S, which is the board this repository calls
the hard one. This variant is the right one.

## What is not known, and the fit above all

**None of the above is a fit.** These are percentages computed from a part
database. No design in this repository has ever been through synthesis, place
and route for an XC7S50, so nothing here says whether the machine closes timing
on one. Whether it fits is an open question and the checking has not
happened.

The Arty S7 also exists as an S7-25, so confirm which variant the board in
hand is before spending anything on this directory.

**Nor does the database settle the licence.** `get_parts` listing a part says
the device data is installed. It does not say that the free BASIC tier will
place and route it. That is answered by running a build, and a refusal is an
unmistakable licence error in the tool's own words, the way `create_debug_core`
is refused today.

When somebody does run it, the out-of-context flow takes its part from the
environment:

    make build/boot_prom.hex
    PART=<the Spartan part> vivado -mode batch \
        -source boards/arty-z7-20/vivado/fit.tcl

That flow synthesises `cadr_machine` on its own, with no top level, no output
fold, no MMCM and no package pins. That is exactly the piece which carries over
to this board, so it answers "does the machine fit" before any of the plumbing
above exists.

**Two things in that script are tied to the Arty Z7-20 and may have to be
loosened first.** It reads `boards/arty-z7-20/*.sv` along with `rtl/`, and those
files instantiate a `PS7`, which is not a primitive on this part. And it gets
the clock period by parsing the MMCM parameters out of
`boards/arty-z7-20/cadr_arty.sv`, which is right only while this board also aims
at a 10 ns tick. Neither has been tried, so expect to fix the script rather than
to run it unchanged.

**Read any number it prints with its commit attached.** Slack in this project
has moved a quarter of a nanosecond between two builds of bit-identical logic,
and utilisation answers "does it fit" while slack answers "is this build
finished".


## The pin file

`Arty-S7-50-Master.xdc` is Digilent's published master file, byte for byte as
published, under Digilent's own filename. The name is kept so that "is this the
published file" is answerable by eye and by one `sha256sum`.

| | |
|---|---|
| repository | `github.com/Digilent/digilent-xdc` |
| commit | `00a3404901f35aa9567b01ecb3f2c233b6efe9f4` |
| commit date | 2024-11-12 |
| original filename | `Arty-S7-50-Master.xdc` |
| size | 18,428 bytes |
| sha256 | `26d472164373dff063f3cbdc3c10e958d1e8251d9e3b86776e5ab6889ba53ab5` |
| board revision it names | Arty S7-50 Rev. E |

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
