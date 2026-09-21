# Boards

A board directory holds everything that is true of one particular piece of
hardware and of nothing else. That is the pins, the processing system if the
part has one, the vendor tool's flow for that part, and the operating system
that runs beside the machine on it.

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
| `cora-z7-07s/` | Digilent Cora Z7-07S | XC7Z007S | Runs on silicon, without display output or USB input. |
| `de25-nano/` | Terasic DE25-Nano | A5EB013BB23BE4SCS | Built by Quartus. Runs on silicon with its memory, its band and its display, and boots from power alone. |

**The two Zynq boards run the machine on silicon, and they carry two different
amounts.** `arty-z7-20/` is the board and is complete. `cora-z7-07s/` has a
top level, a pin file, a processing-system configuration, a device tree and a
Vivado flow. The board has no HDMI connector, so it has no display output, and
its image leaves USB input out; `cora-z7-07s/README.md` says why. On the board
it boots Linux from its card. Its machine is halted today, with no drive. Over
the Pmod cable it has debugged the Arty Z7-20 and been debugged by it, which
`docs/board.md` records.

**`de25-nano/` holds the whole board.** It has a top level, a Quartus flow, a
pin file transcribed from Terasic's user manual, the processor's
configuration, a device tree, a Buildroot image and a README that says what
the board is and how the port is made. The machine runs there with the
processor's LPDDR4 behind its memory port, and it meets timing with the Zynq
boards' exceptions written again for Quartus. On the board it boots Linux
from its card, loads a band and puts the machine's screen on a monitor, and
its QSPI flash carries this project's phase-1 bitstream, so it comes up from
power with nothing else attached.

**Every board here has a processing system beside its fabric, and that is
deliberate.** What a board has to bring is main memory, a card the machine's
disk can be a file on, a network the time host and the file host are reached
over, and video. A board whose part has hard processor cores brings all four
through them and the Linux running on them. A part without one has to answer
every one of them in fabric, which is a different project rather than a port,
and the section below says what the list is.

**The Arty Z7-20 and the Cora Z7-07S are Zynq-7000 parts, and the DE25-Nano is
an SoC of another family.** Its part is an Altera Agilex 5, with Cortex-A76 and
Cortex-A55 cores beside the fabric and a bridge from the fabric into their
memory, so it brings the same four things in the same way. What differs is the
vendor. Its flows are Quartus's rather than Vivado's, nothing in
`rtl/plumbing/xilinx7/` carries over, its cores are 64-bit, and it boots
differently. `de25-nano/README.md` has the list.

**There is no Spartan-7 directory, because the Digilent Arty S7-50 has no
Ethernet.** This machine finds its time host and its file host over Chaosnet,
and Chaosnet reaches them across the network. The remote viewer serves the
screen over the network as well, and on a board with no video pins that is the
only way to see the machine at all. A board nothing can reach is a board the
CADR cannot be used on, so the Arty S7-50 is not a target.

**And there is no Artix-7 directory.** The Digilent Arty A7-100T had one and it
was removed: that board takes a microSD card only as a module bolted onto a
Pmod header, its Ethernet is 10/100 where the Zynq boards are gigabit, and it
has no video connector at all, so the screen would have had nowhere to go.
Supporting it beside the Zynq boards bought nothing that the Zynq boards do not
already show. `README.md` names the commit it was removed at.

## The card

**Every board's card is one FAT32 partition in an MBR with the same layout**,
so that a person who has learned one card has learned all of them. The user
formats the card and unpacks the board's zip onto it. There is no disk image.

    /            BOOT.BIN, u-boot.img and uEnv.txt, whose names the loader
                 fixes, and README.TXT, fpgarc and muirrc, which are the files
                 a person edits
    <board>/     a folder named as the board's directory here is ---
                 `arty-z7-20/`, `cora-z7-07s/`, `de25-nano/` --- holding that
                 board's fabric image, device tree, kernel and root filesystem
    packs/       the disk packs, and muir-cc.img where a debugger runs
    sys/ site/   the band's Lisp sources and its site configuration

**The card mirrors the TFTP server.** One server serves more than one board
here, every board's files carry the same names, and a flat root would hand one
board another's bitstream. So a board's served set lives in a directory named
for it, and the card holds the same four files under the same name. A card
belongs to one board, so the folder is not what keeps two boards apart on it;
what it buys is that the card and the server hold the same thing in the same
place, and that a card made from the wrong board's zip says so --- the loader
asks for its own folder by name and never finds it.

**Some files stay at the root because their names are not ours to move.** The
boot ROM reads `BOOT.BIN` from the root of the first FAT partition and nowhere
else, the SPL asks for `u-boot.img` by that name at the root, and `uEnv.txt` is
imported before any board name is known.

**Those names are the Zynq boards' and not a rule for every part.** The
DE25-Nano's first-stage loader is in the QSPI flash rather than in a file on
the card, so its root carries `u-boot.itb` and no `BOOT.BIN` at all. Everything
else about the card is the machine's and is the same on all three.

**`packs/`, `sys/` and `site/` are on every card even when they are empty**,
because an empty folder with a name on it is what tells somebody where a band
goes. A release ships all three empty, since the band is the user's own.

**One staging script writes every board's card and one command builds the
release**, `make release`, which makes all three boards' zips together so that
one board cannot be left at an older build. `docs/boot.md` has the recipes, the
sizes, how to format a card and what a release carries.

## The order

The Arty Z7-20 is the board and stays the board. The Cora was added after it,
which was not a stated priority and should not be read as one. The DE25-Nano's
directory came after both.

The Cora was worth settling before the display output block started, because a
board with no HDMI pulls against exactly that work. And it is the tighter of
the two by a long way, as the next section shows, so it is the one that would
say something about the design.

**It did say something: the machine fits on the small part and closes timing
there.** That was the open question and it is answered.

## Does the machine fit

**On the Cora Z7-07S this is measured now and is not a ratio.** Both Zynq
boards were placed and routed at commit `86d787b` with `DDR=1`, which is the
machine with the processing system and DDR3 behind its memory port, so the two
columns are the same design on two parts.

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

**What follows is a ratio and not a fit.** Today's
memory-on design, placed and routed for the Arty Z7-20 at commit `95cbb84`, was
**10,909 slice LUTs, 7,390 slice registers, 41.5 block RAM tiles and 4 DSP
slices**. Vivado's own part database at 2026.1 gives the two parts as
follows. Those four counts are properties of the die, so the package and the
speed grade do not change them.

| Part | LUTs | flip-flops | block RAM tiles | DSP |
|---|---|---|---|---|
| XC7Z020 Arty Z7-20 | 53,200 | 106,400 | 140 | 220 |
| XC7Z007S Cora Z7-07S | 14,400 | 28,800 | 50 | 66 |

Put the design beside each of them and the percentages read:

| Board | LUTs | flip-flops | block RAM | DSP |
|---|---|---|---|---|
| Arty Z7-20 | 20.5% | 6.9% | 29.6% | 1.8% |
| Cora Z7-07S | 75.8% | 25.7% | **83.0%** | 6.1% |

**The Cora is the tight board.** The small Zynq is the hard one, and a
percentage against it is close to honest, because a Cora runs this same design
with the same Linux programs beside it. Against a part with no processing
system it would not be, because on such a part this is not the design: every
one of the answers the next section lists costs logic and block RAM these
numbers do not include.

**On the DE25-Nano the fits are in the part's own units.** The machine with
nothing behind its memory port takes 5,162 of the part's 46,800 adaptive
logic modules and 95 of its 358 M20K blocks, and with the processor's memory
behind it and the faces on both bridges it takes 15,028 and 129. That part is
counted in adaptive logic modules and M20K rather than in LUTs and block RAM
tiles, so it has no row in either table. `de25-nano/README.md` has the
figures.

## Three kinds of new board

**The Cora is a variant.** It is another Zynq-7000, so a port is a top level, a
pin file, a processing-system configuration and a device tree. Nothing in
`rtl/` changed. The question there was whether the machine fits, because the
XC7Z007S is a much smaller part than the XC7Z020, and it does.

**An SoC of another family is a port with a second toolchain.** The DE25-Nano
brings main memory, a card, a network and video through its hard processor
system as a Zynq board does, and nothing in `rtl/machine/` changes for it. But its top
level, its pins, its constraints, its processor configuration and its flows are
all for Quartus, its Linux is 64-bit, and the vendor primitives in
`rtl/plumbing/xilinx7/` need counterparts or go without.

**A part with no processing system is a different project.** The fabric may be
the same seven-series fabric, so `rtl/machine/` and the vendor primitives carry
over unchanged. What does not carry over is everything the processing system
does today.

## What a board with no processing system has to answer

No board here is such a part. This list is kept because it is what any future
one would have to answer, and it is what `boards/arty-z7-20/` uses the Zynq's
processing system for, read off that directory.

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

`cora-z7-07s/` therefore holds Digilent's master `.xdc` byte for byte as
published, under Digilent's own filename, with its provenance recorded in that
directory's `README.md`. Digilent publishes them under the MIT license, so that
directory also holds a copy of that license text as `Digilent-License.txt`.

Each directory's own constraint file then copies out the handful of pins that
board's design actually uses and cites the master file in its header ---
`arty-z7-20/cadr_arty.xdc` and `cora-z7-07s/cadr_cora.xdc`. A constraint file
that is mostly commented-out pins is a constraint file nobody reads.

**Both Zynq boards call the clock port `sysclk`**, whatever Digilent's own
schematic name for it is, so that the debug probe's own constraint file ---
which groups the JTAG readout's clock apart from `sysclk` and everything
generated from it --- says the same thing on both.

**The DE25-Nano's pin file is this project's own.** It is transcribed from
Terasic's user manual, because Terasic grants no redistribution of its golden
top. `tools/de25_pins_check.py` compares the two where Terasic's package is
present. `de25-nano/README.md` records where the golden top is, its sha256 and
the terms that keep it out.
