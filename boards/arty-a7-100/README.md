# Arty A7-100T

The Digilent Arty A7 is an Artix-7 board. This directory is for the A7-100T
variant, whose part is an XC7A100T.

**Nothing here builds anything.** This directory holds Digilent's published pin
file and this note. There is no top level, no constraint file of ours, no
Vivado script and no memory controller.

**The part has room and the work does not exist.** Today's design would be 17.2%
of this part's logic and 30.7% of its block RAM, against 20.5% and 29.6% on the
board this project runs on today. So this part has more logic headroom and about
the same block RAM headroom as the Arty Z7-20. What is missing is not fabric. It
is everything the Zynq's processing system does, which on an Artix-7 there is
none of.

## This is not a port

An Artix-7 has no processing system. That is the whole difference, and it is a
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

## What a complete board directory holds

Read off `boards/arty-z7-20/`, which is the finished one. It has a top level, a
constraint file, a probe constraint file, a generated processing-system
wrapper, fifteen Vivado scripts and a Buildroot tree, in 142 tracked files.
This directory has three, one of them this note.

## The board, read off Digilent's file

The clock is a single 100 MHz oscillator on pin E3, where the Arty Z7-20 and
the Cora each have one at 125 MHz. So the MMCM recipe in
`boards/arty-z7-20/cadr_arty.sv` has to be recomputed. The tick counts do not
change and no check moves. What changes is the multiplier and the divider that
make a 10 ns tick from a different input. The property worth preserving is the
one that board relies on: its VCO is exactly 1000 MHz, so the output divider
reads literally as the tick in nanoseconds and a reader can see the tick in the
source without doing arithmetic.

There are four switches, four plain LEDs, four RGB LEDs and four buttons. That
is more lamps than the Arty Z7-20 has, so the six-lamp assignment in
`docs/board.md` fits this board with room left over and needs no decision.

There are four Pmod headers, JA through JD, where the Arty Z7-20 has two. The
debug cable adapter's assignment of JA to DBGOUT and JB to DBGIN therefore
carries over by name, and two spare headers remain.

There is a USB-UART bridge on PL pins. The Arty Z7-20's master file constrains
no UART pins at all, so whatever serial port that board has is the processing
system's and its fabric cannot see it. Here it is the fabric's.

**There is an Ethernet PHY on PL pins.** Digilent's file constrains a full
SMSC MII interface: `eth_txd[3:0]`, `eth_rxd[3:0]`, the two clocks, the carrier
and collision signals, and an MDIO pair. On the Arty Z7-20 the Ethernet is the
processing system's and the fabric cannot see it. So a board with no Linux is
also the first board where Chaosnet could reach a wire from fabric directly.
That is an observation about the pins and not a design.

There is a Quad SPI flash.

**There are no memory pins in Digilent's file.** The master file constrains PL
pins for the peripherals above and nothing else. What memory device the board
carries, and what reaching it from fabric would cost, has to come from
Digilent's documentation and is not established here. It is the first question
to answer, because main memory is 15 MB and cannot live in block RAM.

## The part is not the obstacle. The work is.

**There is room on this part, and that is the opposite of what was expected.**
Vivado's own part database at 2026.1 gives the XC7A100T as **63,400 LUTs,
126,800 flip-flops, 135 block RAM tiles and 240 DSP slices**. Those four
counts are properties of the die, so the package and the speed grade do not
change them.

Today's memory-on design, placed and routed for the Arty Z7-20 at commit
`95cbb84`, is 10,909 slice LUTs, 7,390 slice registers, 41.5 block RAM tiles and
4 DSP slices. Beside this part that reads:

| | used | XC7A100T has | |
|---|---|---|---|
| LUTs | 10,909 | 63,400 | 17.2% |
| flip-flops | 7,390 | 126,800 | 5.8% |
| block RAM tiles | 41.5 | 135 | 30.7% |
| DSP | 4 | 240 | 1.7% |

**This part has more logic than the one this project runs on today.** The
XC7Z020 on the Arty Z7-20 has 53,200 LUTs against this part's 63,400, and 140
block RAM tiles against its 135. So the machine is no tighter here than it is on
the board that runs it, and it is far looser than on the Cora Z7-07S, where the
same design would fill 83.0% of the block RAM.

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

The same board exists as the Arty A7-35, whose part is a XC7A35T.
Vivado's database gives it as 20,800 LUTs and 50 block RAM tiles, so
today's design would already be **52.4% of its logic and 83.0% of its block
RAM** before a single one of the fabric answers above was added.

That is as tight as the Cora Z7-07S or tighter, and the Cora is the board this
repository calls the hard one. This variant is the right one.

## What is not known, and the fit above all

**None of the above is a fit.** These are percentages computed from a part
database. No design in this repository has ever been through synthesis, place
and route for a XC7A100T, so nothing here says whether the machine closes
timing on one. Whether it fits is an open question and the checking has not
happened.

**Nor does the database settle the licence.** `get_parts` listing a part says
the device data is installed. It does not say that the free BASIC tier will
place and route it. That is answered by running a build, and a refusal is an
unmistakable licence error in the tool's own words, the way `create_debug_core`
is refused today.

When somebody does run it, the out-of-context flow takes its part from the
environment:

    make build/boot_prom.hex
    PART=<the Artix part> vivado -mode batch \
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

`Arty-A7-100-Master.xdc` is Digilent's published master file, byte for byte as
published, under Digilent's own filename. The name is kept so that "is this the
published file" is answerable by eye and by one `sha256sum`.

| | |
|---|---|
| repository | `github.com/Digilent/digilent-xdc` |
| commit | `00a3404901f35aa9567b01ecb3f2c233b6efe9f4` |
| commit date | 2024-11-12 |
| original filename | `Arty-A7-100-Master.xdc` |
| size | 21,223 bytes |
| sha256 | `5c0c84302cbce49ac85f4812e8f1f7371e686964ec2eb29fd67307da9ed6835f` |
| board revisions it names | Arty A7-100 Rev. D and Rev. E |

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
