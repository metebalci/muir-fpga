# Boards

A board directory holds everything that is true of one particular piece of
hardware and of nothing else. That is the pins, the processing system if the
part has one, the Vivado flow for that part, and the operating system that runs
beside the machine on it.

Nothing in `rtl/` belongs to a board. The machine is in `rtl/machine/` and is
held to muir tick for tick. The pieces that are held to a protocol or a
property instead are in `rtl/plumbing/`, and the Xilinx-specific ones are in
`rtl/plumbing/xilinx7/`. The repository's own `README.md` explains where that
line is drawn and why the machine has one home rather than one repository per
part family.

## The three directories

| Directory | Board | Part | State |
|---|---|---|---|
| `arty-z7-20/` | Digilent Arty Z7-20 | XC7Z020 | The board. Complete and running. |
| `cora-z7-07s/` | Digilent Cora Z7-07S | XC7Z007S | Builds. Placed, routed and closing timing; never on silicon. |
| `arty-a7-100/` | Digilent Arty A7-100T | XC7A100T | Builds the machine alone. Placed, routed and closing timing; never on silicon. |

**All three build something now, and they build three different amounts.**
`arty-z7-20/` is the board and is complete. `cora-z7-07s/` has a top level, a
pin file, a processing-system configuration, a device tree and a Vivado flow,
and the machine has been placed and routed for that part; nothing in it has
been on silicon.

**`arty-a7-100/` has a top level, a constraint file and a Vivado flow, and it
builds the machine and nothing around it.** That board has no processing
system, so a port to it is a different piece of work from the Cora's and the
next section says what it has to answer. None of those answers exists: there is
no memory behind the machine's port, so every main-memory cycle from microcycle
536,303 onwards ends on the 4.25 microsecond timer instead of on a slave and
the machine runs about a fifth slower. It does not stop. What that board can
show is that the fabric runs, and it can have its first 1,024 microcycles read
back over JTAG and diffed against muir. **Nothing in it has been on silicon
either.**

**There is no Spartan-7 directory, because the Digilent Arty S7-50 has no
Ethernet.** This machine finds its time host and its file host over Chaosnet,
and Chaosnet reaches them across the network. The remote viewer serves the
screen over the network as well, and on a board with no video pins that is the
only way to see the machine at all. A board nothing can reach is a board the
CADR cannot be used on, so the Arty S7-50 is not a target. The Arty A7-100
keeps its place because it has an Ethernet PHY on fabric pins.

## The card

**Every board's card has the same two partitions and the same layout**, so that
a person who has learned one card has learned all of them.

    partition 1  BOOT   BOOT.BIN, u-boot.img and uEnv.txt at the root, and a
                        folder named as the board's directory here is ---
                        `arty-z7-20/`, `cora-z7-07s/` --- holding that board's
                        cadr.bit, device tree, zImage and root filesystem
    partition 2  PACKS  the disk packs, muir-cc.img where a debugger runs,
                        fpgarc, muirrc and a README.TXT, all at the root

**The boot partition mirrors the TFTP server.** One server serves more than one
board here, every board's files carry the same names, and a flat root would
hand one board another's bitstream. So a board's served set lives in a
directory named for it, and the card holds the same four files under the same
name. A card belongs to one board, so the folder is not what keeps two boards
apart on it; what it buys is that the card and the server hold the same thing
in the same place.

**Three files stay at the root because their names are not ours to move.** The
boot ROM reads `BOOT.BIN` from the root of the first FAT partition and nowhere
else, the SPL asks for `u-boot.img` by that name at the root, and `uEnv.txt` is
imported before any board name is known.

**The pack partition is flat on every board.** A pack, the README and the two
files of flags belong to the machine rather than to the part. What differs
between two boards' cards there is the Chaosnet address inside `fpgarc` and
`muirrc`, which each board's own `local.conf` sets.

**One staging script writes every board's card and one release script builds
every board's image**, both taking the board in the same two variables.
`docs/boot.md` has the recipes, the sizes and what a release carries. A board
with no processing system gets the same card image with an empty boot
partition, because the packs are the machine's world and not the part's; the
Arty A7-100 is that case and its own README says what is distributed for it.

## The order

The Arty Z7-20 is the board and stays the board. The other two are listed in the
order they were named when they were added, which was not a stated priority and
should not be read as one.

The Cora came first for two reasons. It was worth settling before the display
output block started, because a board with no HDMI pulls against exactly that
work. And it is the tightest of the three by a long way, as the next section
shows, so it is the one that would say something about the design.

**It did say something: the machine fits on the small part and closes timing
there.** That was the open question and it is answered.

## Does the machine fit

**On the Cora Z7-07S this is measured now and is not a ratio.** Both boards
were placed and routed at commit `86d787b` with `DDR=1`, which is the machine
with the processing system and DDR3 behind its memory port, so the two columns
are the same design on two parts.

| | Cora Z7-07S | Arty Z7-20 |
|---|---|---|
| worst slack | +0.495 ns, met | +0.236 ns, met |
| failing endpoints | 0 of 48,104 | 0 of 47,935 |
| slice LUTs | 12,352 of 14,400, **85.78%** | 12,130 of 53,200, 22.80% |
| slice registers | 9,106 of 28,800, 31.62% | 9,041 of 106,400, 8.50% |
| block RAM tiles | 41.5 of 50, **83.00%** | 41.5 of 140, 29.64% |
| DSP slices | 4 of 66, 6.06% | 4 of 220, 1.82% |

The two block RAM figures are the same number. The design spends 41.5 tiles on
either part, so what changes between the boards is the denominator.
`cora-z7-07s/README.md` has the rest of it and the argument for reading a slack
figure with its commit.

**For the Arty A7-100 what follows is still a ratio and not a fit.** Today's
memory-on design, placed and routed for the Arty Z7-20 at commit `95cbb84`, was
**10,909 slice LUTs, 7,390 slice registers, 41.5 block RAM tiles and 4 DSP
slices**. Vivado's own part database at 2026.1 gives the three parts as
follows. Those four counts are properties of the die, so the package and the
speed grade do not change them.

| Part | LUTs | flip-flops | block RAM tiles | DSP |
|---|---|---|---|---|
| XC7Z020 Arty Z7-20 | 53,200 | 106,400 | 140 | 220 |
| XC7Z007S Cora Z7-07S | 14,400 | 28,800 | 50 | 66 |
| XC7A100T Arty A7-100 | 63,400 | 126,800 | 135 | 240 |

Put the design beside each of them and the percentages read:

| Board | LUTs | flip-flops | block RAM | DSP |
|---|---|---|---|---|
| Arty Z7-20 | 20.5% | 6.9% | 29.6% | 1.8% |
| Cora Z7-07S | 75.8% | 25.7% | **83.0%** | 6.1% |
| Arty A7-100 | 17.2% | 5.8% | 30.7% | 1.7% |

**The Cora is the tight board and the Artix is not.** That inverts the obvious
expectation. The XC7A100T has more logic than the part this project runs on
today and almost the same block RAM. The small Zynq is the hard one.

**Read those two columns differently on the two kinds of board.** For the Cora
the percentage is close to honest, because a Cora runs this same design with
the same Linux programs beside it. For the Artix it is not, because on that part
this is not the design. Main memory needs a controller in the fabric, the disk
needs a way to read a card, and the screen, the console, Chaosnet, the serial
line and the debugger all lose the programs that implement them today. Every one
of those costs logic and block RAM that these numbers do not include. **The part
is not the obstacle on that board. The work is.**

**And the Artix column is a ratio rather than a fit, but the part has now been
through the tools.** The machine WITH EVERY SEAM TIED OFF --- no memory behind
its port and no program at the end of any cable, which is what that board can
build today --- places and routes for the XC7A100T at commit `86d787b` and
closes at **+1.227 nanoseconds with no failing endpoint of 27,148**, costing
6,009 Slice LUTs, 2,403 registers and 38 block RAM tiles.
`boards/arty-a7-100/README.md` has the table. That is a floor and not the
column above: it is a smaller design than the one the percentages are computed
from, because the drive, the serial chip and the mouse all constant-fold when
nothing drives their seams, and it has none of the fabric answers this section
lists. What it does settle is that the part builds and that the free tier will
build it.

## Two kinds of new board

**The Cora is a variant.** It is another Zynq-7000, so a port is a top level, a
pin file, a processing-system configuration and a device tree. Nothing in
`rtl/` changed. The question there was whether the machine fits, because the
XC7Z007S is a much smaller part than the XC7Z020, and it does.

**The Artix is a different project.** That part has no processing system at all.
The fabric is the same seven-series fabric, so `rtl/machine/` and the vendor
primitives carry over unchanged. What does not carry over is everything the
processing system does today.

## What a board with no processing system has to answer

This list is here rather than in the board note itself so that there is one copy
of it. It is what `boards/arty-z7-20/` uses the Zynq's processing system for,
read off that directory.

**Main memory.** The machine reaches 3,932,160 words of main memory and 32,768
words of display, which is 15 MB and 128 KB. That is far more than any part in
these families holds in block RAM, and the whole of today's design already
spends 41.5 of the XC7Z020's 140 block RAM tiles on the control store, the
scratchpads, the disk's block store and the Chaosnet's packet buffers. So main
memory means an external memory device and a controller for it in fabric, where
today it is `S_AXI_HP0` into the processing system's own DDR3 controller.

**The disk.** A pack is a file on the microSD card, and `cadr-disk-packs` puts
a block into DDR for the controller to fetch over `S_AXI_HP2`. With no Linux
there is no file and no program, so reading the card becomes a fabric job. The
disk controller itself does not care. It asks for a block exactly as it does
now and does not care who answers.

**The screen.** `cadr-terminal` serves the frame buffer over RFB to a viewer on
the network. With no Linux the display has to leave the board some other way,
which on a board with video pins means driving them from the fabric.

**The console.** `cadr-console` halts, steps and inspects the machine over
`M_AXI_GP1`. With no processing system there is no `M_AXI_GP1`.

**Chaosnet and the serial line.** Both are Linux programs today, `cadr-chaosnet`
and `cadr-serial`, reaching the I/O board's registers over `M_AXI_GP0`.

**The debugger.** muir runs on the board's own Cortex-A9 cores and plays the
debugger machine at the far end of the debug cable. These parts have no cores
to run it on.

Nearly all of that work lands in `rtl/plumbing/`, where it is reusable, and the
board directory stays thin.

## Why the pin files are vendored

Pins come from Digilent's published file and never from memory. A wrong pin is
a light that does not come on, and that reads as a design fault in the machine.

`cora-z7-07s/` and `arty-a7-100/` therefore each hold Digilent's master `.xdc`
byte for byte as published, under Digilent's own filename, with its provenance
recorded in that directory's `README.md`. Digilent publishes them under the MIT
license, so each directory also holds a copy of that license text as
`Digilent-License.txt`.

Each directory's own constraint file then copies out the handful of pins that
board's design actually uses and cites the master file in its header ---
`arty-z7-20/cadr_arty.xdc`, `cora-z7-07s/cadr_cora.xdc` and
`arty-a7-100/cadr_arty_a7.xdc`. A constraint file that is mostly commented-out
pins is a constraint file nobody reads.

**One of the three renames a pin and says why.** Digilent calls the Arty
A7-100's clock `CLK100MHZ`; that board's constraint file calls the port
`sysclk`, as the other two boards' files do, so that the debug probe's own
constraint file --- which groups the JTAG readout's clock apart from `sysclk`
and everything generated from it --- says the same thing on every board.
