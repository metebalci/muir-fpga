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

## The four directories

| Directory | Board | Part | State |
|---|---|---|---|
| `arty-z7-20/` | Digilent Arty Z7-20 | XC7Z020 | The board. Complete and running. |
| `cora-z7-07s/` | Digilent Cora Z7-07S | XC7Z007S | Preliminary. A pin file and a note. |
| `arty-a7-100/` | Digilent Arty A7-100T | XC7A100T | Preliminary. A pin file and a note. |
| `arty-s7-50/` | Digilent Arty S7-50 | XC7S50 | Preliminary. A pin file and a note. |

**Only `arty-z7-20/` builds anything.** The other three hold Digilent's
published master pin file and a `README.md` saying what would have to be built.
There is no top level, no constraint file of ours, no Vivado script and no
device tree in any of them. That is deliberate. A skeleton that looks like it
works is worse than an empty directory, because somebody will run it.

## The order

The Arty Z7-20 is the board and stays the board. The other three are in the
order Mete named them on 13 September 2026, asking for "preliminary files for
cora-z7-07s and arty-a7-100 and arty-s7-50". That was the order of his sentence
rather than a stated priority, and it is recorded here as such.

The Cora being first is a priority he has stated separately. His words were
"pynq is not that important cora z7-07s more", and he wants to look at the Cora
before the display output block starts. A board with no HDMI pulls against
exactly that work. The Cora is also the tightest of the four by a long way, as
the next section shows.

None of the three is urgent. Mete's words about the Cora were "nothing urgent
but we can also support this board", and it waits behind the three blocks he
asked to have finalised first.

## Does the machine fit

Today's memory-on design, placed and routed for the Arty Z7-20 at commit
`95cbb84`, is **10,909 slice LUTs, 7,390 slice registers, 41.5 block RAM tiles
and 4 DSP slices**. Vivado's own part database at 2026.1 gives the four parts
as follows. Those four counts are properties of the die, so the package and the
speed grade do not change them.

| Part | LUTs | flip-flops | block RAM tiles | DSP |
|---|---|---|---|---|
| XC7Z020 Arty Z7-20 | 53,200 | 106,400 | 140 | 220 |
| XC7Z007S Cora Z7-07S | 14,400 | 28,800 | 50 | 66 |
| XC7A100T Arty A7-100 | 63,400 | 126,800 | 135 | 240 |
| XC7S50 Arty S7-50 | 32,600 | 65,200 | 75 | 120 |

Put the design beside each of them and the percentages read:

| Board | LUTs | flip-flops | block RAM | DSP |
|---|---|---|---|---|
| Arty Z7-20 | 20.5% | 6.9% | 29.6% | 1.8% |
| Cora Z7-07S | 75.8% | 25.7% | **83.0%** | 6.1% |
| Arty A7-100 | 17.2% | 5.8% | 30.7% | 1.7% |
| Arty S7-50 | 33.5% | 11.3% | 55.3% | 3.3% |

**The Cora is the tight board and the Artix and the Spartan are not.** That
inverts the obvious expectation. The XC7A100T has more logic than the part this
project runs on today and almost the same block RAM, and the XC7S50 has room to
spare. The small Zynq is the hard one.

**Read those two columns differently on the two kinds of board.** For the Cora
the percentage is close to honest, because a Cora runs this same design with
the same Linux programs beside it. For the Artix and the Spartan it is not,
because on those parts this is not the design. Main memory needs a controller
in the fabric, the disk needs a way to read a card, and the screen, the console,
Chaosnet, the serial line and the debugger all lose the programs that implement
them today. Every one of those costs logic and block RAM that these numbers do
not include. **The part is not the obstacle on those two boards. The work is.**

**And none of this is a fit.** These are percentages computed from a part
database. No design in this repository has ever been through synthesis, place
and route for an XC7A100T or an XC7S50, and until one has, nothing here says
whether the machine closes timing on either.

## Two kinds of new board

**The Cora is a variant.** It is another Zynq-7000, so a port is a top level, a
pin file, a processing-system configuration and a device tree. Nothing in
`rtl/` changes. The question there is whether the machine fits, because the
XC7Z007S is a much smaller part than the XC7Z020.

**The Artix and the Spartan are a different project.** Neither part has a
processing system at all. The fabric is the same seven-series fabric, so
`rtl/machine/` and the vendor primitives carry over unchanged. What does not
carry over is everything the processing system does today.

## What a board with no processing system has to answer

This list is here rather than in the two board notes so that there is one copy
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

Each of the three preliminary directories therefore holds Digilent's master
`.xdc` byte for byte as published, under Digilent's own filename, with its
provenance recorded in that directory's `README.md`. Digilent publishes them
under the MIT licence, so each directory also holds a copy of that licence text
as `Digilent-License.txt`.

The finished board does it differently, and that is the convention to follow
once a top level exists. `arty-z7-20/cadr_arty.xdc` copies out the handful of
pins the design actually uses and cites the master file in its header. A
constraint file that is mostly commented-out pins is a constraint file nobody
reads.
