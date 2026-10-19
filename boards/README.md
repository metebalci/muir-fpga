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
| `de25-nano/` | Terasic DE25-Nano | A5EB013BB23BE4SCS | Built by Quartus. Runs on silicon with its memory, its band and its display, and boots from power alone. |
| `kria-kr260/` | AMD Kria KR260 | XCK26 | Built by Vivado. Runs on silicon with its memory, its band and its display, and boots Linux from its card. |

**`de25-nano/` holds the whole board.** It has a top level, a Quartus flow, a
pin file transcribed from Terasic's user manual, the processor's
configuration, a device tree, a Buildroot image and a README that says what
the board is and how the port is made. The machine runs there with the
processor's LPDDR4 behind its memory port, and it meets timing with the Zynq
boards' exceptions written again for Quartus. On the board it boots Linux
from its card, loads a band and puts the machine's screen on a monitor, and
its QSPI flash carries this project's phase-1 bitstream, so it comes up from
power with nothing else attached.

**`kria-kr260/` holds the whole board, and its part is a Zynq UltraScale+.**
It has two top levels, `cadr_kr260.sv` for the CADR and `quux15_kr260.sv` for
QUUX, their pin files, a generated wrapper for the part's `PS8` processing
system, a Vivado flow, a device tree and a Buildroot image. The machine's
clock is the carrier's 25 MHz through an `MMCME4_BASE`, not one of the
processing system's. The part's memory ports are 128 bits wide, and the fabric
is built at that width. The board's QSPI flash holds the factory U-Boot, which
runs this project's `boot.scr` from the card, so nothing here writes the flash.
Its video leaves through DisplayPort.

**Every board here has a processing system beside its fabric, and that is
deliberate.** What a board has to bring is main memory, a card the machine's
disk can be a file on, a network the time host and the file host are reached
over, and video. A board whose part has hard processor cores brings all four
through them and the Linux running on them. A part without one has to answer
every one of them in fabric, which is a different project rather than a port,
and the section below says what the list is.

**The Arty Z7-20 is a Zynq-7000 part, and the DE25-Nano is an SoC of another
family.** Its part is an Altera Agilex 5, with Cortex-A76 and
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
                 fixes, and README.TXT, fpgarc, cadrrc and quuxrc, which are the files
                 a person edits
    <board>/     a folder named as the board's directory here is ---
                 `arty-z7-20/`, `de25-nano/`, `kria-kr260/` --- holding that
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

**Those names are the Arty Z7-20's and not a rule for every part.** The
DE25-Nano's first-stage loader is in the QSPI flash rather than in a file on
the card, so its root carries `u-boot.itb` and no `BOOT.BIN` at all. The Kria
KR260's whole loader is the factory U-Boot in its QSPI flash, so its root
carries `boot.scr` and neither `BOOT.BIN` nor `u-boot.img`. Everything else
about the card is the machine's and is the same on all three.

**`packs/`, `sys/` and `site/` are on every card even when they are empty**,
because an empty folder with a name on it is what tells somebody where a band
goes. A release ships all three empty, since the band is the user's own.

**One staging script writes every board's card and one command builds the
release**, `make release`, which makes all three boards' zips together so that
one board cannot be left at an older build. `docs/boot.md` has the recipes, the
sizes, how to format a card and what a release carries.

## Does the machine fit

**What follows is a ratio and not a fit.** Today's
memory-on design, placed and routed for the Arty Z7-20 at commit `f276143`, was
**10,909 slice LUTs, 7,390 slice registers, 41.5 block RAM tiles and 4 DSP
slices**. Vivado's own part database at 2026.1 gives the part as
follows. Those four counts are properties of the die, so the package and the
speed grade do not change them.

| Part | LUTs | flip-flops | block RAM tiles | DSP |
|---|---|---|---|---|
| XC7Z020 Arty Z7-20 | 53,200 | 106,400 | 140 | 220 |

Put the design beside it and the percentages read:

| Board | LUTs | flip-flops | block RAM | DSP |
|---|---|---|---|---|
| Arty Z7-20 | 20.5% | 6.9% | 29.6% | 1.8% |

**On the DE25-Nano the fits are in the part's own units.** The machine with
nothing behind its memory port takes 5,162 of the part's 46,800 adaptive
logic modules and 95 of its 358 M20K blocks, and with the processor's memory
behind it and the faces on both bridges it takes 15,028 and 129. That part is
counted in adaptive logic modules and M20K rather than in LUTs and block RAM
tiles, so it has no row in either table. `de25-nano/README.md` has the
figures.

## Three kinds of new board

**Another Zynq-7000 is a variant.** A port is a top level, a pin file, a
processing-system configuration and a device tree, and nothing in `rtl/`
changes. The question there is whether the machine fits the part.

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

## Where the pin files come from

Pins come from the vendor's published file and never from memory. A wrong pin
is a light that does not come on, and that reads as a design fault in the
machine.

`arty-z7-20/cadr_arty.xdc` copies out the handful of pins that board's design
actually uses from Digilent's master file, `Arty-Z7-20-Master.xdc` in
`github.com/Digilent/digilent-xdc`, and cites it in its header. A constraint
file that is mostly commented-out pins is a constraint file nobody reads.

**The Arty Z7-20 calls the clock port `sysclk`**, whatever Digilent's own
schematic name for it is, and the debug probe's own constraint file groups the
JTAG readout's clock apart from `sysclk` and everything generated from it.

**The Kria KR260's pin file takes its package pins and standards from AMD's
own KR260 board files and platform XDCs**, and says in its header that which
LED is which and the fan's sense were seen on the board.

**The DE25-Nano's pin file is this project's own.** It is transcribed from
Terasic's user manual, because Terasic grants no redistribution of its golden
top. `tools/de25_pins_check.py` compares the two where Terasic's package is
present. `de25-nano/README.md` records where the golden top is, its sha256 and
the terms that keep it out.
