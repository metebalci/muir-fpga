# Arty A7-100

The Digilent Arty A7 is an Artix-7 board. This directory is for the A7-100
variant, whose part is an XC7A100T in a CSG324 package at speed grade -1.

**This is the first board in this repository with no processing system.** The
Arty Z7-20 reaches main memory, the disk, the screen, the console, Chaosnet,
the serial line and the debugger through a Zynq's ARM cores and the Linux
running on them. There is none of that here. What is here is the machine and
the pins it can reach by itself.

**And the machine builds and closes timing on the part.** That was an open
question when this directory held only a pin file. It is measured now and the
figures are below.

## What runs on this board today

**This section is about the default configuration, which is the machine
alone.** `DDR`, `SOC`, `PROVE` and `PROBE_DEPTH` are switches and every one of
them is off unless a build sets it. Main memory and the soft processing system
have sections of their own below, and both have run on silicon.

With no switch set the CADR runs its boot PROM. There is nothing behind its
memory port, so nothing answers the main-memory cycles. That is not a fault of
this board. It is the Arty Z7-20's own memory-off configuration, which is the
one this project has built and measured from the beginning.

**The machine does not stop when it reaches memory, and that is worth knowing
before reading the lamps.** An unanswered cycle is not a stall. It ends on the
4.25 microsecond non-existent-memory timer and the machine goes on. `make nomem`
runs this exact configuration and measures it, and at commit `86d787b` it
reports 852,515 microcycles in 200 milliseconds of the machine's own time, the
first `mem_req` at microcycle 536,303, 514 timeouts in the 82 milliseconds after
it, and 0.26 microseconds a microcycle against 0.22 when nothing is waiting.

So the board runs about a fifth slower once it reaches main memory and keeps
going. The 514 timeouts are the boot PROM's parity loop, which reads and writes
each of page 0's 256 words, plus two cycles to empty Xbus space. The disk
controller's own registers answer the PROM's 16,951 disk polls in 140
nanoseconds, so those do not time out.

**That paragraph is here because the prediction was wrong once.** The other
board's top level said the machine "stalls there for ever", the board said
otherwise by blinking, and `tb/cadr_nomem_tb.cpp` was written to measure it
rather than to reason again.

Two things can watch it. The lamps say whether the fabric is clocked, whether
the machine is executing and how much of its time it spends waiting. The debug probe records one
sample a microcycle of the first 1,024 microcycles into block RAM and shifts
them out over JTAG, and `tools/probe_check.py` diffs that capture against
muir's own trace column for column. That is the same instrument the Arty Z7-20
used for its first evidence from silicon.

**Both have been run on this board.** The probe's capture of the first 1,024
microcycles agrees with muir's own trace column for column, and the lamps read
at the board as this section says they should. "The recipe, and its first run
on silicon" below has that run's account.

## The lamps, and the one thing about them that traps a reader

This project assigns six lamps by meaning. This board numbers its lamps the
other way round from the Arty Z7-20, which numbers four plain green LEDs LD0
to LD3 and two tricolour ones LD4 and LD5. Here the four tricolour LEDs are
LD0 to LD3 and the four green ones are LD4 to LD7.

| meaning | this project | port | this board's silkscreen |
|---|---|---|---|
| `MACHRUN`, as a level | LD0 | `led[0]` | LD4 |
| the fabric is clocked | LD1 | `led[1]` | LD5 |
| microcycles retiring | LD2 | `led[2]` | LD6 |
| disk activity | LD3 | `led[3]` | LD7 |
| `ERRHALT`, red only | LD4 | `led0_*` | LD0 |
| `PROMENABLE`, blue only | LD5 | `led1_*` | LD1 |
| nothing, dark | --- | `led2_*`, `led3_*` | LD2, LD3 |

The port names are Digilent's, so that a pin can be checked against the master
file by eye. This board has eight lamps where the assignment wants six, so two
tricolour ones are dark.

On a memory-off board the lamps read as follows, in this board's own
silkscreen numbers. LD5 blinks at about 1.5 Hz for ever, because it counts the
fabric's own clock and nothing else. LD6 blinks with the microcycles and keeps
blinking, every 0.28 seconds at the board's 10 nanosecond tick. LD4 is
`MACHRUN` and dims from microcycle 536,303 onwards, because every main-memory
cycle from then on spends 4.25 microseconds on the timer rather than 140
nanoseconds on a slave. LD7 is dark, there being no drive. The tricolour LD1 is
blue for ever, because the machine never leaves its boot PROM.

**And the tricolour LD0 stays dark, which is the point of what it now means.**
It lights for the machine's own error halt and for nothing else. The lamp used
to light for a bus timeout as well, and on this board every main-memory cycle is
a timeout --- so it would be red within a second of every power-on, on a fabric
doing exactly what this board is built to do. A lamp whose normal state is red
says nothing.

BTN0 boots the machine and is `-BOOT2`, the button MIT put on the CADR's light
panel. BTN1 resets the fabric. Those two are the same buttons on every board in
this repository. SW0 is the no-auto-boot switch: with it on, the machine comes
out of reset with `RUN` and `SRUN` clear and stands as a CADR does when the
power comes on with nobody at it, and any `-BOOT` source starts it. BTN2, BTN3
and SW1 to SW3 have no meaning here.

On this board the fabric reset is the only reset there is. It resets the logic
in the fabric, which is the machine, the register faces and the lamps, and it
does not reload the bitstream. On the Zynq boards that distinction matters,
because the processing system and Linux keep running across it and the programs
under Linux are then out of step with the fabric until they are restarted.
There `rst -srst` over JTAG is the reset to reach for. Here there is no
processing system and nothing else can reset the fabric.

## What is absent, and the shape of each answer

Every item below is a seam whose far end is a program on the Arty Z7-20's ARM
cores or a port of its processing system. `boards/arty-a7-100/cadr_arty_a7.sv`
ties each one off at the value a cable with nothing on the end of it presents,
and names it there. **None of these is started and none of them should be
started from this note alone.** Where a decision is needed, this says so and
does not take it.

**Main memory is built. It has its own section below.** The decision this
paragraph used to leave open has been taken: the controller is Xilinx's Memory
Interface Generator, and it is this repository's one generated IP.

**The disk.** On the Arty Z7-20 a Linux program reads a pack file off the SD
card and fills the block store over `S_AXI_HP2`. The card there is wired only to
the processing system, and Digilent's master file for this board constrains no
card pins at all. So the answer is an SD host in fabric, reading a card through
one of the Pmod headers, with the pack at a raw offset rather than as a file.
The board has no card slot of its own, so the card is a microSD Pmod on
connector JD, and the SD host this plan owes in fabric will drive JD's pins.
That reopens a question this project settled once for a board that has Linux,
which is who computes the block headers and checkwords.

**The screen.** The display block already writes the picture into its own
region of memory, so a screen needs something to read that region and drive a
monitor. This board has no HDMI connector, so the answer is either HDMI off a
Pmod adapter or nothing. `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv` and the two
encoders beside it carry over, and the mode and the pins would be a decision.

**Chaosnet.** Digilent's master file constrains nineteen pins to the board's
Ethernet PHY, which is an MII interface: `eth_txd[3:0]` and `eth_rxd[3:0]`,
`eth_tx_clk`, `eth_rx_clk` and `eth_ref_clk`, `eth_tx_en`, `eth_rx_dv`,
`eth_rxerr`, `eth_crs`, `eth_col`, `eth_rstn` and an `eth_mdc`/`eth_mdio`
pair. On the Arty Z7-20 the Ethernet is the processing system's and the fabric
cannot see it. **So this is the first
board where Chaosnet could reach a wire from fabric directly**, and the answer
is a MAC in fabric with the CHUDP encapsulation above it. That is an
observation about the pins and not a design.

**The serial line.** The board has a USB-UART bridge on two fabric pins,
`uart_rxd_out` on D10 and `uart_txd_in` on A9. **Those two pins are used now,
and not for this.** With `SOC=1` they are the soft processing system's own
console: the firmware's words to whoever is at the board, at 115,200 baud.
That is a different thing from the CADR's serial port, which is the 2651 on the
I/O board and whose far end is a TCP socket on the other boards. A board that
wanted both would need a second UART on a Pmod, and nothing here takes that
decision. The Arty Z7-20's master file
constrains no UART pins at all, so that board's serial port is the processing
system's. Here it is the fabric's, and the answer is a transmitter and a
receiver beside `rtl/plumbing/cadr_serial_line.sv`, which already does the
2651's framing and its baud-rate generator against a socket.

**The console. THIS PARAGRAPH IS SUPERSEDED AND IS KEPT BECAUSE IT SAYS WHAT
THE QUESTION WAS.** It read: the console and the debugger are both Linux
programs on the other board, neither has a fabric shape yet, and this note does
not invent one. The console has one now. `rtl/plumbing/cadr_console.sv` is in
the design with `SOC=1`, unchanged, at the address it has on the Zynq, and what
masters it is a RISC-V core in the fabric. The section below is the whole of
it.

**The debugger, and here the answer went the other way.** On the two Zynq
boards it is a register window, `rtl/plumbing/cadr_debug_window.sv`, behind a
general-purpose port, with muir on those boards' own ARM cores playing
the far end of MIT's debug cable in software. **That window is not on this
board and is in none of its configurations.** There is no muir here and no
processor to run one on: the soft system is the console and not a debugger.
What this board has instead is the cable itself --- a SECOND BOARD at the other
end of a Pmod ribbon, reaching the machine's DBGIN page through
`rtl/plumbing/cadr_dbg_cable.sv`, which is pure fabric and needs no processing
system at all.

So `0x8000_1000`, which is the window's page on a Zynq, is an address nothing
implements here, and the bridge's catch-all answers it "NONE" like any other.
The firmware reads it and holds it to that, and `build/soc.pass` asserts the
line. `rtl/plumbing/cadr_dbg_join.sv` is what lets a window and a connector
share one DBGIN page. It is still in the design here, with the window's arm
tied idle, and the same check watches every tick to say that arm never asks.
Two mutation records hold the pair.

**And the connector is JB on this board where it is JA on the other two.**
This is the only board here with four Pmod headers and the only one whose
headers are not alike. Digilent publishes JB and JC as this board's high-speed
Pmod ports and JA and JD as standard ones, which is a series resistor in line
with every signal. That half is the vendor's own description of the board and
is not measured here.

**What is checkable is in the pin file, and it agrees twice over.** The file
names JB's and JC's pins `jb_p[1]`..`jb_n[4]` and `jc_p[1]`..`jc_n[4]`, which
is how it names a coupled pair, and names JA's and JD's plain
`ja[1]`..`ja[10]` and `jd[1]`..`jd[10]`. The pin types bear it out as well. All
four of JB's header rows --- pins 1 and 2, 3 and 4, 7 and 8, 9 and 10 --- are
true differential pairs of bank 15, and two of them are clock-capable. Not one
of JA's four rows is a pair at all: its differential pairs straddle the rows
instead.

**Those four rows are what the link uses, one signal to a pair.** A group of
four pads carries a strobe on one line of the first pair and one data line on
one line of the second, and the other line of each pair is driven low as a
guard by whichever board drives that group. So the coupled line beside a signal
does not switch, and the crosstalk a pair is built to carry is the thing the
guard removes.

This link's timing rests on a strobe at the far end of a ribbon, so it goes on
a high-speed port. **The card stays on JD**, the other standard port, and is
right there. A microSD module plugs straight into that header with no ribbon
between it and the part, and SPI at tens of megahertz over an inch of board
does not care about a series resistor. Every board indexes a header's eight
signals in the same order, so a straight ribbon from this board's JB to a Zynq
board's JA maps every signal to its counterpart. `docs/debug-cable.md` has the
pins for all three boards. The carrier is in the design here in every
configuration, because a board is always a debuggee.

**The boot.** The Arty Z7-20 comes up because the processing system reads a
card. Here the part reads its own 16 MB QSPI flash at power-on, and that
carries the bitstream and nothing else. `vivado/qspi.tcl` is the recipe and it
has never been run. "The card, and what is distributed" below says what is
published for a board that boots this way.

**The keyboard and the mouse.** The other board's USB host is the processing
system's own controller. This board has no USB host at all, so these would be a
host in fabric. They are last in this project's order of work on any board.

## The card, and what is distributed

**Nothing here is built yet; this is the plan.** This board has no processing
system, so it has no boot ROM, no card controller and no Linux. A 7-series FPGA
configures from QSPI flash or from JTAG, and this one reads its own 16 MB flash
at power-on. So a card cannot be what boots it.

**What is distributed for this board is two things.** The first is a **flash
image**: what `write_cfgmem` makes out of the bitstream and the firmware beside
it, written into the board's QSPI flash once. `vivado/qspi.tcl` is the recipe
and it has never been run. The second is **the same card image every other
board gets**, with its boot partition empty but for a README saying that this
board boots from its flash and that nothing on that partition is read, and with
the pack partition exactly as the other boards have it: a `README.TXT`, the two
files of flags, and room for the packs the user copies in.

**The card is worth shipping for a board that does not boot from it.** The disk
packs are the machine's world and not the part's: a card carrying a band is a
CADR's disk whichever board reads it, and one layout on every board means a
card can be moved between boards and the world moves with it. Here the firmware
reads the pack partition with a FAT library exactly as Linux does on the
others, which is what makes the disk step's own card the same card. The disk
step is where this board's card is first written.

`boards/README.md` has the layout every board shares and `docs/boot.md` has the
recipes.
## Main memory

The board carries 256 MB of DDR3L on the fabric's own pins, where the Arty
Z7-20's DDR3 belongs to its processing system. So this board needs a memory
controller in the fabric, and it has one.

### The controller is generated, and it is the only thing here that is

Everything else Xilinx offers as a directory of generated XML has been declined
in this repository and hand-built instead. A DDR3 controller is not that kind
of thing: it is a calibration sequence, a physical layer with per-bit deskew, a
write levelling procedure and a bank manager, and nothing here could hold a
hand-written one to anything.

`mig/README.md` is the whole argument, the provenance of the project file it is
generated from, the four changes made to that file, and how `make current`
checks that what is committed is what the generator writes today.

### What is between the machine and it

The machine is unchanged. `rtl/plumbing/cadr_xbus_ddr.sv` asks for a 32-bit
word at a byte address and waits, exactly as it does on the other board, and
`rtl/plumbing/cadr_ddr_map.sv`'s constants have not moved. Three modules are
new and each has a testbench.

| | |
|---|---|
| `rtl/plumbing/cadr_mem_cross.sv` | the memory port across two clocks |
| `rtl/plumbing/cadr_mig_ui.sv` | that port onto the controller's native user interface |
| `rtl/plumbing/cadr_jtag_mem.sv` | the debugger's own way into memory, in front of the port |
| `cadr_a7_memory.sv` | the four of those and the generated controller, wired together |

`make build/a7_mem.pass` is the check. It runs the first three against a model
of the controller's user interface, at two clock ratios, and it holds them to
the things this family of module gets wrong: which sixteen-byte block, which of
its four 32-bit lanes, which bytes to write, and the rules a crossing between
two unrelated clocks has to keep. Seven mutation records are aimed at it.

### The machine's clock and the controller's, and how they coexist

The board has one 100 MHz oscillator and this design has one clock manager in
its top level, which is what the shared `tick.tcl` requires and what makes the
tick a number the fabric and the constraints cannot disagree about. That
manager's oscillator runs at 1000 MHz and it divides it three ways: by ten for
the machine's 10 nanosecond tick, by five for the 200 MHz reference the
controller calibrates its input delays against, and by twenty for the soft
processing system's own 50 MHz. The third has a section of its own below; the
rest of this one is about the first two.

The controller is given the machine's own 100 MHz as its system clock, and it
makes its own clocks from it: 1300 MHz at its phase-locked loop, over four for
a 325 MHz memory clock, over four again for an 81.25 MHz user clock.

**So the machine's tick and the controller's user clock have no fixed
relationship**, and the design crosses between them at exactly one place:
`cadr_mem_cross`, on the `mem_*` handshake, which was already a four-phase
handshake with one transaction in flight. The payload never needs a
synchroniser and the argument for that is made good by construction rather than
assumed: the address is registered on the near side and the level that
announces it goes out a clock later, so it has stopped moving before anything
on the far side looks at it.

**That argument is told to the fitter as a maximum delay and not as a clock
group**, which is a distinction with a reason. A grouped path is not timed at
all, and a payload that is not timed at all is a payload the fitter may route
through a swamp. `boards/arty-a7-100/cadr_a7_ddr.xdc` and the flow beside it
say why, and the flow asserts that the bound reached the design rather than
trusting it.

### Where the machine's memory lands

`rtl/plumbing/cadr_ddr_map.sv` reserves 128 MB at `0x1800_0000`, which is a
Zynq layout where the bottom 384 MB belongs to Linux. This board has 256 MB and
no Linux, so the same reservation goes at the top of the chip, which is where it
is on the other board too.

| | |
|---|---|
| main memory | DDR byte `0x0800_0000`, 64 MB reserved, 15 MB reachable |
| the display's window | DDR byte `0x0C00_0000`, 8 MB reserved, 128 KB reachable |
| the bottom 128 MB | nobody's yet |

The translation is one constant bit rather than a subtraction, and the map's
constants do not move. An address outside the reservation is refused with a
zero word and a flag, not wrapped: wrapping it would put a wild write in DDR
and let the machine carry on.

### The observer, which is the hard part on a board with no processing system

Every claim this project has made about a memory path on silicon rests on an
observer outside the design under test. On the Arty Z7-20 that observer is the
JTAG debugger reading DDR through the processing system, on a controller port
the fabric never touches.

**There is no such door here.** An Artix-7 has no debug access port onto memory
and no second master anywhere: the DDR3L is on the fabric's pins and the only
thing that can reach it is the fabric. So the debugger is given a path ---
`rtl/plumbing/cadr_jtag_mem.sv`, one register on a second `BSCANE2` user chain,
in front of the memory port, taking it when the machine is not using it.

That module's header says plainly what is lost by the debugger's words
travelling the machine's own path, and what recovers it. The three things that
do are all the host's and not the fabric's: a poison injective in the address,
all four lanes of a sixteen-byte block written differently and read back, and a
tally that is not on this path at all. The tally counts what the controller's
own user interface accepted and returned, which a fabric that issued nothing
cannot fabricate.

### The three scripts

| | |
|---|---|
| `vivado/ddr_check.tcl` | can the debugger reach memory, and does what it writes come back |
| `vivado/prove.tcl` | does the fabric write real memory (`PROVE=1`), and does it read it (`PROVE=2`) |
| `vivado/ddr_run.tcl` | the machine running MIT's boot PROM out of real DDR3L |

Every one names the JTAG cable by its serial number and none has a default, for
the reason the recipe below gives.

The last of those is the Arty Z7-20's step four. The boot PROM's only
main-memory traffic is an identity copy of page 0 --- 256 reads and 256 writes,
and it never looks at the data --- so against zero-filled memory not one word
changes and a run compared against zero would test nothing. The poison is the
script's, injective in the address, and the machine is held in reset while it
is written, because the machine reaches its first main-memory cycle 118
milliseconds after its own reset and poisoning a thousand words through a JTAG
register takes seconds. The window holds the MACHINE and not the controller, so
what is in DDR survives being let go.

## The soft processing system

**This board has a processor beside the CADR now, and it is in the fabric.**
The Arty Z7-20 and the Cora Z7-07S reach the machine's register faces from
Linux on a Zynq's ARM cores. There is no Zynq here, so a RISC-V core in the
fabric masters the same faces, at the same addresses, through the same drivers.

It is off by default. `SOC=1` puts it in the design:

    make build/boot_prom.hex build/soc_firmware.hex
    SOC=1 OUTDIR=build/a7-soc \
        vivado -mode batch -source boards/arty-a7-100/vivado/bitstream.tcl

...and `SOC=1 DDR=1` is the whole board: the machine with its memory behind it
and the soft processing system in front of the faces.

Everything in the sections above was measured without it and is still true of
the default board.

**And it runs on a clock of its own, which is the one structural thing to know
before reading the rest.** The core computes a load or a store's address in the
cycle it uses it, and that does not settle in the machine's 10 nanosecond tick.
The machine's tick cannot move. So the soft system takes a third output of the
same clock manager at 50 MHz, the AXI bridge in front of the three faces stays
on the machine's clock where the faces are, and one request and one answer
cross between the two. There are sections on the clock and on the seam below.

### The core

The core is Ibex, lowRISC's, vendored at a pinned commit under
`third_party/ibex/` with its own Apache-2.0 licence. That directory's
`README.md` says which commit, which files, why six of them are not in Ibex's
own file list, and what each file's digest is.

The configuration is **RV32IMC, two stages, no caches**. In Ibex's own
parameters: `BaseIsaRV32I`, `RV32MFast`, `RV32BNone`, `RV32Zca`, `ICache` 0,
`WritebackStage` 0, `PMPEnable` 0, `SecureIbex` 0, `BranchPredictor` 0.
`rtl/plumbing/cadr_soc.sv`'s header gives the reason for each. The short
version: the multiplier is free because the machine uses no DSP slices; a
cache is the answer to a slow memory and this memory is one block RAM at one
cycle; and every one of the hardening options answers a threat model a board
on a bench does not have.

**The core was chosen and not invented.** A processor written here would be a
second machine to be wrong about, in a repository whose whole method is
holding one machine to a reference. MicroBlaze arrives as an IP directory with
an encrypted netlist; VexRiscv's Verilog is generated from Scala; picorv32
takes four or five cycles an instruction. Ibex is SystemVerilog, about one
instruction a cycle, a few thousand LUTs, and it is the core OpenTitan ships.

### The map

The faces keep the addresses the Linux programs use. That is the point of the
exercise: `console_face.h` says `0x8000_0000` and `pack_side.h` says
`0x4000_0000`, and both are true of this board.

| | |
|---|---|
| `0x0000_0000` | 32 KB of block RAM, the firmware in it |
| `0x1000_0000` | this system's own UART |
| `0x1000_1000` | its own timer |
| `0x4000_0000` | the disk pack face, `cadr_disk_pack.sv` |
| `0x8000_0000` | the console, `cadr_console.sv` |
| everything else | `cadr_gp0_default.sv`, which answers "NONE" |

**AND `0x8000_1000` IS NOT IN THAT TABLE, WHERE ON THE TWO ZYNQ BOARDS IT IS
THE DEBUG CABLE'S REGISTER WINDOW.** The section above says why: that window is
how a program plays the far end of MIT's cable, and this board has no such
program. It is one more address nothing implements, so the catch-all answers
it. The firmware reads it and holds it to "NONE", which is what makes the
catch-all's coverage of a page a face used to hold a checked claim rather than
an assumption.

The two pages at `0x1000_0000` are the system's own, and they are deliberately
not at the Zynq's peripheral addresses. Nothing in this repository has ever
named `0xE000_1000`, and a UART pretending to be the processing system's would
be a lie a program could act on.

**Every address is answered.** On the Zynq a read nothing answers inside a
general-purpose window does not fault the ARM. It hangs both cores at one PC
each, measured on the board, and no software guard can catch a load that never
completes. A soft core is worse off, because it has no interconnect to give it
an error response at all. So the bridge's last port is a catch-all and the
default slave sits behind it: a load from an address nothing implements
completes with "NONE".

**And that rule has a cost worth knowing before reading a board.** A default
slave that answers every address with a word which is not zero turns a wild
pointer into an infinite string. The first firmware built here had no global
pointer set up, so its log prefix was read from the catch-all, and the board
said NONENONENONE for ever. `boards/arty-a7-100/firmware/start.S` carries that
account at the instruction that fixes it.

### The bridge

`rtl/plumbing/cadr_soc_axi.sv` turns one of the core's loads or stores into one
AXI transaction at one of three slaves. Single beat always, which is AXI4-Lite's
shape wearing AXI3's signal list, and that is exactly what the faces were
written for.

It holds one selection where `rtl/plumbing/cadr_gp0_split.sv` holds two. The
splitter needs two because the thing in front of it drives the read and the
write channels independently. The thing in front of this takes one request and
answers it before it takes another, so there is never a read and a write in
flight together.

The identifier is a counter and not a constant, so that a face which dropped it
would not look exactly like one that did not.

### The firmware

`boards/arty-a7-100/firmware/` is bare-metal C. It is `cadr-console` with the
operating system taken out: `console_face.c` and `pack_side.c` are the Arty
Z7-20's files, compiled here unchanged, and what this board supplies is the two
things they need from their surroundings --- an access layer that is a load and
a store where Linux has an `mmap`, and a `say()` that is a UART where Linux has
a `FILE *`.

**Those two files are compiled where they live, under the other board's Linux
tree.** A copy here would be a second description of one register face. They
belong somewhere neutral and they are not there yet; this is the same debt this
document already records for three Vivado scripts.

The toolchain is `riscv64-unknown-elf-gcc` with picolibc. On Debian and Ubuntu:

    sudo apt-get install gcc-riscv64-unknown-elf picolibc-riscv64-unknown-elf

picolibc is not optional. It is the only C library on that toolchain which
ships headers, and the shared drivers include `<string.h>` and `<stdio.h>`. The
Makefile names the compiler and stops with that message when it is absent.

What the first firmware does, and every step of it is an assertion and not a
print:

  - says what it is, over the UART;
  - reads its own UART's and timer's identifiers;
  - reads the console's identifier and holds it to "CONS";
  - measures whether the machine is running, by reading CYCLES twice with a
    wait between them;
  - halts it, and reads PC and FLAG-1 off the diagnostic bus;
  - steps it once, and checks CYCLES moved by exactly one;
  - starts it again;
  - reads the disk pack face's identifier and holds it to "PACK" --- which is
    register 7 and not register 0;
  - reads the default slave, which must answer "NONE";
  - reads `0x8000_1000`, the page the debug cable's register window holds on a
    Zynq board, which must answer "NONE" here --- there is no window on this
    board and that page is the catch-all's like any other;
  - prints how many of those failed, and then idles taking four commands from
    the wire: `s` status, `h` halt, `c` continue, `.` step.

The four commands are `cadr-console`'s and muir's prompt's, for the reason that
program gives: somebody who knows one should know the other. It is a crude
machine control thing and it is meant to stay one. The debugger is CC over the
debug cable, which on this board is another board at the far end of Pmod JB
rather than anything this firmware can reach.

### What checks it

`make build/soc.pass` runs `tb/cadr_soc_harness.sv`, which is this board's top
level below the clock: the soft system with Ibex in it, `cadr_machine` with
MIT's boot PROM and nothing behind its memory port, and the three faces. The
firmware is the one the board runs, the same hex.

It asserts every line the firmware says, in order --- **the build line among
them, against the number the harness drove into the console's page 2, so that
the whole road from the port to the sentence is one comparison and not a
confirmation** --- and then three things the
firmware cannot say about itself.

**That the machine really halted and really stepped.** `clock_edge` is the
machine's own microcycle boundary and the check counts it every tick, so the
halt is a stretch with no microcycles in it and the step is exactly one
microcycle inside that stretch. A firmware that printed "CYCLES moved 1" while
the machine ran on would pass a check that read its output and fail this one.

**That the bridge is serial.** The check watches which slaves see a VALID every
tick and how many transactions are outstanding on each channel.

**That the baud divisor is what the fabric was built for.** The narrowest level
the transmitter ever holds is one bit time, so the minimum pulse width over the
whole run is the divisor. A decoder samples in the middle of a bit and tolerates
a few per cent, so decoding correctly is not evidence about the number.

The check builds the UART at a divisor of 32 rather than the board's 868, so
that the same firmware says the same words in a fraction of the time. Nothing in
the firmware knows the rate; it polls a ready bit.

Fourteen mutation records are aimed at the seam, in `mutations/list.txt` under
`soc`. Seven are the bridge's and the soft system's own two faces: an address
bit dropped, a write answered before it lands, the console's page sent to the
catch-all, the baud divisor doubled, the UART and the timer swapped as answer
sources, the memory read one word along, and the timer saying the wrong
microsecond. Two are this board's not having the debug cable's register window:
a decode given back to the page that window holds on a Zynq, and the arm of the
join it used to drive left asking for the machine's DBGIN page. Five more are
the crossing's, and they are described in the section on it below. All fourteen
are caught, and each record quotes the line that catches it.

Others were written and are recorded there as measured equivalences rather than
holes. The first weakened the seam's guard against granting a second request
while one is in flight, and it survived: Ibex's load-store unit drops its
request at the grant and does not raise it again until the answer, so the seam
is never offered a second one and the guard it lost was never what kept it
serial. The guard stays, because it makes the bridge's single held selection a
property of that file rather than of the core in front of it.

### And it ran on the board

Programmed over JTAG, the board's USB-UART at 115,200 baud, the lines the
firmware said, verbatim, with the soft system on its own 50 MHz clock. **This
capture is of that session and has not been retaken**, so it predates two
changes: the debug window came out of this board, and its `DBUG` line reads
`NONE` now; and the banner has since gained two lines naming which build the
fabric is, straight after the console answers.

    cadr-soc: the soft processing system on an Arty A7-100: ibex rv32imc in fabric
    cadr-soc: UART UART, timer TIME, 50 ticks a microsecond
    cadr-soc: the console at 0x80000000 answers CONS
    cadr-soc: the machine was RUNNING, 4551 microcycles in 2000 us
    cadr-soc: halted at PC 0o245, 0 microcycles in 1000 us
    cadr-soc: halted: FLAG-1 0xe800 SRUN 0 ERR 0 -WAIT 0 PROMDISABLE 0 STATHALT 0
    cadr-soc: stepped 1, CYCLES moved 1, SSDONE 1
    cadr-soc: started: RUNNING, 4552 microcycles in 2000 us
    cadr-soc: the disk pack face at 0x40000000 answers PACK (register 7)
    cadr-soc: the default slave at 0x40001000 answers NONE
    cadr-soc: the debug window at 0x80001000 answers DBUG
    cadr-soc: 0 of 16 rounds of four back-to-back loads, one at each face, came back wrong
    cadr-soc: 0 failure(s); idling --- s status, h halt, c continue, . step

**THAT CAPTURE IS KEPT VERBATIM AND TWO OF ITS LINES NO LONGER READ THAT WAY.**
It was taken on a board whose bitstream still had the debug cable's register
window in it, and the window is not on this board any more. The section above
has the argument. So the eleventh line now says `the window's page at
0x80001000 answers NONE`, and the twelfth says `three back-to-back loads` where
it said four. The fourth of those loads was the window's, and its answer is now
the same word the default slave gives. Nothing else in the capture moves and it
is not rewritten: a measurement is worth its provenance, and what a board said
is what a board said. **It has not been run on the board since**, this slice
having had no board access.

**AND THE SECOND LINE IS WHAT SAYS THE PART TOOK THIS BITSTREAM.** Programming
this board is not reliably one shot, and `vivado/program.tcl`'s DONE check
cannot tell a part that took a file from one configured a minute ago --- the
memory window was what settled that for the `DDR=1` runs, and there is no
window in this configuration. The firmware's own words are the identity here:
a soft system on the machine's tick says one hundred ticks a microsecond and
one on its own clock says fifty, and a part still holding the previous
bitstream would say the wrong one.

**The machine's rate is unchanged, which is the point.** 4,551 microcycles in
2,000 microseconds against the 4,548 measured before the soft system had a
clock of its own: the machine's tick did not move and nothing about it was
meant to.

So on silicon: a RISC-V core in the fabric read four register faces, each of
which answered with its own identifier --- the fourth of them being the debug
window, which is not in this board's design any more; it halted the CADR, read
its program counter and its first flag word off MIT's diagnostic bus, stepped
it exactly one microcycle, and started it again. **This is the first time
anything on this board has done more than blink.**

The four commands answer too. Typed at the wire, one at a time:

    cadr-soc: RUNNING, 3990 microcycles in 2000 us, PC 0o552
    cadr-soc: running: FLAG-1 0xe900 SRUN 1 ERR 0 -WAIT 0 PROMDISABLE 0 STATHALT 0
    cadr-soc: halted
    cadr-soc: stepped 1, CYCLES moved 1, SSDONE 1
    cadr-soc: started
    cadr-soc: RUNNING, 3990 microcycles in 2000 us, PC 0o550
    cadr-soc: running: FLAG-1 0xe900 SRUN 1 ERR 0 -WAIT 0 PROMDISABLE 0 STATHALT 0

**The program counters say the machine is where it should be.** `0o541` to
`0o553` is the boot PROM's no-drive loop --- two status reads and one disk
address write, eleven microcycles --- and every reading above is inside it.
There is no drive on this board, so that is the whole of what the PROM does
after its control-store pass, and it is what `machine.pass` compares against
muir.

**Two readers on one serial device split the bytes between them**, which is
worth knowing before believing a capture: the first attempt at the commands
above produced a line cut off in the middle of a word, and the cause was a
capture left running from an earlier test rather than anything on the board.

**The step still moves the machine by exactly one microcycle with SSDONE up**,
and that is the reading to watch when the soft clock moves. `cons_step` waits
one microsecond between raising STEP and reading SSDONE, and the two master
clocks it is waiting for are 880 nanoseconds at extra slow. The wait comes out
of the timer, so it is a microsecond whatever the soft clock is; what would
break it is a machine tick longer than 11.36 nanoseconds, not a slower core.

**And this run is of a design that closes.** The section below has the figures.
An earlier run of the same firmware, on a design that did not close, is not
evidence about logic --- that one showed the flow, the composition and the
firmware were right and nothing more.

### The timing, and it is met

**The design with the soft processing system in it closes, and the soft system
runs on a clock of its own to do it.** At `xc7a100tcsg324-1`, `SOC=1`, the
machine's tick at 10 ns and the soft system at 50 MHz, built at the commit that
took the debug cable's register window off this board:

| | |
|---|---|
| worst slack | **+0.123 ns, MET** |
| failing endpoints | 0 of 46,476 |
| hold | +0.043 ns, met, 0 of 46,371 |
| pulse width | +3.000 ns, met |
| Slice LUTs | 13,465 of 63,400 (21.24%) |
| Slices | 4,787 of 15,850 (30.20%) |
| Slice registers | 8,565 of 126,800 (6.75%) |
| block RAM tiles | 48.5 of 135 (35.93%) |
| DSP | 5 of 240 |
| multicycle exceptions | 4, over 5 clocks |
| bitstream | 3,825,990 bytes, no critical warnings |

The worst path is `mach_rst_reg` into a reset pin of the bus interface's own
registers: no logic levels at all and 95 per cent of it routing, which is a
high-fanout reset net finding a long wire and not a chain of gates. It is met.

**THE PREVIOUS BUILD OF THIS CONFIGURATION READ +0.720 ns AND ITS WORST PATH
IS NOT IN THIS DESIGN.** That one was the bridge's byte-enable register into
the debug cable window's watchdog counter, eight and a half nanoseconds of it
with four fifths in routing. The window is gone. The figures above are of a
different netlist and the two should not be read as one number moving: what
they share is that both are met.

**AND THE UTILISATION WENT UP BY A LITTLE, WHICH IS NOT WHAT REMOVING A FACE
PREDICTS AND IS NOT EXPLAINED HERE.** 13,465 Slice LUTs against 13,325 and
8,565 registers against 8,541: 140 more and 24 more, about one per cent, after
a module came out of the design. Block RAM, DSP and the bitstream's size are
unchanged. Nothing was added on purpose, and a fitter given a netlist that
changed is free to pack and replicate differently --- the reset net that is now
the worst path is exactly the kind of thing that gets replicated. It is
recorded as measured rather than reasoned about; what would settle it is
`report_utilization -hierarchical` on both, and nobody has run it.

**AND THE WHOLE BOARD CLOSES TOO.** `SOC=1 DDR=1` is the machine with its
memory controller behind it and the soft processing system in front of its
register faces, which is the configuration this board is for. It reads **+0.148
ns, MET, on 0 of 60,287 endpoints**, with hold at +0.026 and pulse width at
+0.206. It costs 18,186 Slice LUTs (28.68%), 6,184 slices (39.02%), 12,880
registers (10.16%), 48.5 block RAM tiles and 5 DSPs, at 10 multicycle
exceptions over 26 clocks. The drawing on the site carries the two figures it
shows from this build.

**And the exception count fell from six to four, which is the constraint
leaving with the module it named.** `rtl/plumbing/xilinx7/cadr_debug.xdc` gives
four ticks to one register inside the window and is a setup and a hold ---
two of the `cycles=` entries `report_exceptions` prints. This board's flow
does not read it any more, because a constraint naming a module that is not in
the design applies to nothing and reads exactly like one that applied. What is
left is two entries for `cadr_machine.xdc`'s fifteen-tick set and two for the
Pmod carrier's four, and both are asserted to have reached a path.

**What it used to be, and why that mattered.** Before the soft system had a
clock of its own the same design read **-3.216 ns, NOT met, on 1,616 of 46,004
endpoints**. The ten worst paths all ran from Ibex's instruction register in
the decode stage, through twenty-one logic levels and six carry chains, to the
address pin of the block RAM a load or a store reaches. That is a load-store
address computed in the cycle it is used, which is what Ibex does. It is about
12.9 nanoseconds on this part, and it is not a path a constraint may relax: it
is one cycle of a processor and it is meant to be.

Two things were tried then and neither was the answer. Reading
`rtl/plumbing/xilinx7/cadr_debug.xdc` on this board moved the figure from
-9.236 to -3.216, which was a real fix at the time. **That file is not read on
this board any more and it is not a fix that was undone.** The register it
relaxes is inside the debug cable's window, and the window is not on this board
at all now. What carries the other end of the same cone is the Pmod carrier,
whose own file `rtl/plumbing/xilinx7/cadr_debug_pmod.xdc` is read in every
configuration and always was. Turning on Ibex's `BranchTargetALU` and
`WritebackStage`, which lowRISC's own guidance recommends to a design short of
frequency, made it **worse** at -3.694 ns. They are off because the measurement
said so.

### The soft system's own clock

**The machine's tick cannot move and the core's cycle will not fit in it, so
they are two clocks.** Every instant in `rtl/machine/` is a count of ticks, and
the shared `tick.tcl` reads the divider that sets one out of the fabric so that
the constraints and the design cannot describe two different machines. What
changed is that the same manager now has a third output. `CLKOUT2` is the
1000 MHz oscillator divided by twenty, which is 50 MHz. `SOC_CLK_DIVIDE`
beside the manager in `cadr_arty_a7.sv` is the one place that number is
decided, and the Makefile reads it out of that file for the check's own baud
divisor and microsecond rather than keeping a copy.

**Which divider, and both were placed and routed.** The oscillator is
1000 MHz, so only whole dividers exist: twenty is 50 MHz and sixteen is
62.5 MHz, and there is nothing between them. Both close.

| | 50 MHz, the one built | 62.5 MHz |
|---|---|---|
| worst slack | +0.720 ns, met, 0 of 46,445 | +0.846 ns, met, 0 of 46,441 |
| hold | +0.032 ns | +0.021 ns |
| the MACHINE's own clock | +1.115 ns equivalent | +1.115 ns on 42,126 |
| **the soft clock's own paths** | **+2.976 ns of 20, on 3,585** | **+0.846 ns of 16, on 3,591** |
| the crossing, out / back | +6.610 / +8.344 ns | +6.161 / +4.690 ns |
| Slice LUTs | 13,325 | 13,347 |

**The overall figures are a tie and the interesting column is the third.** At
50 MHz the design's critical path is the machine's, and the soft system has
fifteen per cent of its period in hand; at 62.5 MHz the soft system IS the
critical path and has five. The two worst-slack numbers differ by 0.126 ns,
which this repository's own rule puts inside placement noise --- a
bit-identical netlist has moved a figure by a quarter of a nanosecond here
before --- so they say nothing about which is the better clock. The third row
does.

**So the routed arc inside the core is about 17 nanoseconds at 50 MHz and
about 15 at 62.5**, against the 12.9 the unrelaxed build reported. That is not
a contradiction: a router that has met its constraint stops, and a slack figure
is a statement about a deadline rather than a measurement of how fast a thing
could go.

**And the second thing that settles it is not slack at all.** A whole number of
the soft system's ticks in a microsecond is what makes the timer's
`TICKS_PER_US` exact. At 62.5 MHz it reads 62, and every delay the firmware
makes is eight tenths of a per cent short, on the one register whose whole
purpose is that the firmware does not keep its own copy of the board's clock.
Fifty megahertz, and the margin where the design needs it.

**THE 62.5 MHz BUILD ALSO EXPOSED A CHECK THAT CANNOT EXPRESS TWO CLOCKS, AND
THAT IS THE MORE USEFUL FINDING.** Run through the board flow as it stands, it
does not finish: `assert_constraints_scoped` stops it, naming one register
outside the machine at a 16.000 ns requirement. The figures above come from the
same build with that one assertion made to print instead of exit, which changes
no constraint and no logic. What it printed:

    DIAG: endpoint   rdata_q_reg[31]_i_4/D
    DIAG:   startpoint g_soc.u_soc/u_cpu/if_stage_i/...instr_rdata_id_o_reg[29]/C
    DIAG:   start clock clk_soc_raw    end clock clk_soc_raw
    DIAG:   requirement 16.000   slack 5.922

Both ends are on the soft clock and 16.000 ns is one period of it, so the path
is healthy. `rdata_q` is Ibex's own load-store unit
(`ibex_load_store_unit.sv:91`); synthesis flattened the cell's name out of the
hierarchy, past the `NAME !~ g_soc.u_soc/*` filter that keeps the soft system
out of that assertion, and the assertion then judged a 16 nanosecond
requirement against the MACHINE's 10 nanosecond tick and called it a microcycle
exception. **That is the false accusation `constraints_check.tcl`'s own header
warns about, arriving by a route nobody had met: a design with two clocks in
it.**

**And the 50 MHz build passes that assertion partly by luck, which has to be
said.** `relaxed_outside` asks for the worst 400 paths by slack. At 50 MHz the
same flattened path has about ten nanoseconds of slack and does not make that
cut; at 62.5 MHz it has 5.922 and does. So the pass is the query's limit and
not evidence that no such path exists. The fix belongs in the shared proc:
hold each path to ITS OWN capture clock's period, and stop taking only the
worst 400. That file is read by three boards' flows and the change is not this
directory's to make; `vivado/bitstream.tcl` says so at the call.

**And the ratio is not free, which is worth knowing before anyone moves it.**
`cons_step` raises STEP and waits one microsecond before reading SSDONE.
SSDONE is STEP registered twice on the machine's master clock and rises two of
them later, which is 88 of the machine's ticks at extra slow --- the speed the
boot PROM runs at. So the wait is 880 nanoseconds against 1,000, and it holds
whatever the soft clock is doing, because the wait comes out of the timer and
the timer counts its own clock.

In simulation there is no real time, so the same bound appears as a bound on
the ratio: the soft clock's period must be at least 88/50 = 1.76 of the
machine's. The board's is 2.0 and the check runs at 2.0, 2.33 and 2.5. A ratio
the other way round, with the soft clock faster than the machine, reports
`SSDONE 0` on a step whose CYCLES moved by exactly one. That is the firmware's
own race and not a crossing that came apart. It was tried at 7:3 and is written
down here so that nobody rediscovers it.

### The seam between the machine's clock and the core's

**The crossing is at the narrowest place in the design and not at the AXI
ports.** The bridge speaks to three faces over five AXI channels, which is
about a hundred wires and ten handshakes. The seam in front of it is one
request and one answer. So `rtl/plumbing/cadr_soc_axi.sv` runs on the machine's
clock, where the three faces already are, and `rtl/plumbing/cadr_soc_cross.sv`
carries the request with its payload out and the answer back. **Nothing in
`rtl/plumbing/` or `rtl/machine/` changed for it, and the faces do not know
there are two clocks at all.**

Its shape is `cadr_mem_cross`'s, which carries the machine's memory port to the
controller's user clock one seam along. A four-phase handshake, a payload
registered on the asking side so that it has stopped moving before the level
that points at it arrives, and two flip-flops on each level.

One thing it does that the memory's crossing does not have to: **the answer is
not handed back until the handshake has closed.** A four-phase handshake is not
finished when the acknowledgement arrives. The request has still to be dropped,
the far side has still to see it go, and its acknowledgement has still to come
back. The requester in front of this one may ask again one clock after it is
answered, which is inside that window. The memory's crossing escapes the
question because `cadr_xbus_ddr` holds its request up until it has taken the
word.

**How close that is to mattering was measured rather than reasoned about.**
With the wait deleted, of 273 requests **129 arrive while the acknowledgement
still stands at the second flip-flop of the synchroniser, and none while it
stands at the first**. So the guard is one clock of the synchroniser away from
handing a requester the previous answer, and what keeps the defect benign is
that `cadr_soc.sv` takes a clock to clear its own busy flag.
`mutations/list.txt` records that with the measurement, rather than leaving a
reader to delete the wait and find every check green.

**The bound is told to the fitter as a maximum delay and never as a clock
group.** `rtl/plumbing/xilinx7/cadr_soc.xdc` bounds everything that crosses at
one of the machine's ticks, which is the shorter of the two periods and
therefore the conservative choice in both directions. Its header says why a
clock group would be wrong: a grouped path is not timed at all, and a payload
that is not timed at all is a payload the fitter may route through a swamp.

**And the flow asks the design whether that worked** rather than trusting it.
At the `SOC=1` build above, **71 paths cross for the request and its payload
and 36 for the answer coming back, every one of them bounded at 10.000 ns**,
and the machine's own fifteen-tick exception still reaches 19,886 of 46,430
setup paths. A constraint that reached nothing would print a plausible worse
number and finish, which is the failure this repository has met four times.

**The soft system is asked a different question rather than not asked.**
`assert_constraints_scoped` holds every register outside the machine to one
period of the clock it is handed, and the clock it is handed is the machine's
tick. A register on the slower clock reports its own longer period and would
fail an assertion about a clock it does not run on. Excluding it and leaving it
there would be an exemption too wide, which is the failure this repository
records more often than any other. So the flow asks the same question of those
registers against their own period instead: **1,395 registers under
`g_soc.u_soc`, and not one asking for more than its own 20.000 ns**.

**What the check holds.** `build/soc.pass` runs the whole firmware at three
clock ratios in one process, the board's own 2:1 and two that share no factor
with it or with each other, and asserts the same fifteen lines at every one.
The thirteenth is new with the second clock. It is sixteen rounds of three
back-to-back loads, one at each face the board has, with nothing between them
for the compiler to put an instruction into, because **a race check needs the
stimulus that loses the race** and every other line in that firmware is one load
with a `say()` behind it.

Five mutation records are aimed at the crossing and all five are caught.
**What no record there can reach is the depth of a synchroniser.** Nothing
models metastability, so one flip-flop behaves exactly as two, and shortening
either one in a single hunk leaves a bit unread and Verilator catches it at bit
granularity rather than the check doing so. That is said once in
`mutations/list.txt`, with three measured equivalences beside it, rather than
being left to be filed as a hole.

### What is still absent

The disk pack face answers its registers and cannot move a block. **This board
has a memory controller and the pack face is not joined to it.**

The machine's own memory port is joined to it. `mem_*` leaves `cadr_machine`,
passes `cadr_jtag_mem`, crosses to the controller's user clock in
`cadr_mem_cross`, becomes a user-interface command in `cadr_mig_ui` and reaches
the generated controller, all of it inside
`boards/arty-a7-100/cadr_a7_memory.sv`, and that path has run MIT's boot PROM
out of real DDR3L on silicon.

The pack face's own memory master is not. It is `S_AXI_HP2` on the Zynq, and in
`boards/arty-a7-100/cadr_arty_a7.sv` its `m_awready`, `m_wready` and
`m_arready` are tied low with `m_bvalid` and `m_rvalid` beside them, so a block
fetch would stand for ever; what it drives goes nowhere but the fold that keeps
those wires from being trimmed. That is said plainly rather than answered with a
plausible completion: a port that accepted an address and returned a word of
nothing would let the pack face report a block it had not moved. Nothing asks it
for a block.

**What joining them needs is a second master in front of the controller.**
`cadr_mig_ui.sv` takes one `mem_*` port and one request in flight, which is what
the machine's port is, so a block moving beside the machine's own cycles wants
an arbiter there --- and the machine's 4.25 microsecond timer is what bounds how
long the disk may hold the controller, exactly as it bounds the channel's
arbiter on the other board.

The firmware is not mutated by `mutations/run.py`, and that is a limit rather
than a choice: its hex is built with a RISC-V compiler and read at elaboration,
and that runner verilates SystemVerilog. The same shape as the Linux programs,
which carry mutation lists of their own.

## The fit, measured

**This board has five configurations and no one commit has routed all of
them.** Each was built by the slice that put it there, so the table below names
the commit every figure was routed at. Slack in this project has moved a
quarter of a nanosecond between two builds of bit-identical logic, so anything
inside that is placement rather than a finding, and rows from different commits
are not a series.

| configuration | commit | worst slack | failing endpoints | slices | Slice LUTs | registers | block RAM tiles |
|---|---|---|---|---|---|---|---|
| memory-off, the default | `2e01ab8` | **+1.181 ns**, met | 0 of 28,643 | 2,108 (13.30%) | 6,367 (10.04%) | 2,923 (2.31%) | 38 (28.15%) |
| with the probe, `PROBE_DEPTH=1024` | `b6edbe6` | **+1.069 ns**, met | 0 of 28,948 | 2,173 (13.71%) | 6,253 (9.86%) | 3,351 (2.64%) | 51 (37.78%) |
| `DDR=1` | `be01ca0` | **+0.232 ns**, met | 0 of 40,343 | --- | 10,400 (16.40%) | 6,541 (5.16%) | 38 (28.15%) |
| `SOC=1` | `27624ed` | **+0.123 ns**, met | 0 of 46,476 | 4,787 (30.20%) | 13,465 (21.24%) | 8,565 (6.75%) | 48.5 (35.93%) |
| `SOC=1 DDR=1` | `782e3a9` | **+0.608 ns**, met | --- | 6,185 (39.02%) | 18,184 (28.68%) | 12,901 (10.17%) | --- |

Every row is a routed run of `boards/arty-a7-100/vivado/bitstream.tcl` for
`xc7a100tcsg324-1`, and every one met.

**Three of the five rows were read out of a routed report and two were not,
which is a difference worth carrying.** The memory-off row is the debug cable
slice's own build, the probe row is the first silicon run's, and the `SOC=1`
row is the window slice's; each has a `timing.rpt` and a `utilisation.rpt`
kept beside its bitstream. The `DDR=1` row is what the run that built main
memory reported and its reports were not kept, so those figures are quoted and
not read. The `SOC=1 DDR=1` row is the one-signal-per-pair slice's own record
of its build, which kept no report for this board either; that slice counted
its block RAM in cells and gave 51, where the build before it had 51 cells in
48.5 tiles, so the column is left empty rather than converted.

**Only the last row is of the fabric this board builds today.** The debug
cable moved to Pmod JB and the debug window came off at `27624ed`, and the
cable went to one signal a coupled pair at `782e3a9`, so every row above the
last is of a design whose cable is not this one. What those rows still answer
is whether the machine fits, which is a question about shape and barely moves.

**And two of the rows were routed from a slice's worktree rather than from the
commit itself**, which is the same sources and not the same words: the `SOC=1`
row is the window slice's build of what landed as `27624ed`, and the
`SOC=1 DDR=1` row is the cable slice's build of what landed as `782e3a9`.

**The count of relaxed paths is the check that the constraints reached the
design, and it is the first thing to read in any of these runs.**
`rtl/plumbing/xilinx7/cadr_machine.xdc` relaxes the machine's datapath
registers to fifteen ticks, and an exception that applied to nothing is listed
by `report_exceptions` exactly as one that reached ten thousand paths. What
separates them is the setup requirement the paths themselves carry. A design
where nothing asks for 150 ns is the unconstrained design, whatever any report
says, and every slack figure from such a run would be of a machine nobody meant
to build. The `SOC=1` build reports 19,886 of 46,430 setup paths at 150.000 ns,
and the `SOC=1 DDR=1` build 19,882 of 60,287, each with the Pmod carrier's own
24 paths at 40.000 ns beside it.

**Read the memory-off row as a floor.** That design is the machine with every
seam tied off, and a tie-off is not free: the drive constant-folds, the serial
chip constant-folds, the Chaosnet interface folds with its address switches at
zero, and the mouse's counters fold because nothing on its seven lines ever
changes. Every fabric answer in "What is absent" above adds logic and block RAM
that row does not include. Utilisation answers "does it fit", which is about
the design's shape; slack answers "is this build finished".

### The memory-off board against the Arty Z7-20's, and why that row is history

The two boards were routed memory-off from one commit once, `86d787b`, by the
same flow, which made them one comparison rather than two quotations. The Arty
A7-100 read **+1.227 ns met on 0 of 27,148 endpoints** with 6,009 Slice LUTs,
2,403 registers and 38 block RAM tiles; the Arty Z7-20 read **-9.600 ns on 596
of 28,959** with 6,330 Slice LUTs, 3,039 registers and 38 tiles.

**THAT SLACK ROW WAS NOT A COMPARISON AND THE OTHER BOARD'S FIGURE WAS NOT ITS
PART'S FAULT.** Every one of the Arty Z7-20's 596 failing endpoints was in the
debug cable's Pmod carrier, and the ten worst paths all ran from
`u_machine/processor/memstart_reg` to that carrier's frame registers ---
twenty-five logic levels of the machine's diagnostic multiplexer reaching a
register outside the machine. `rtl/plumbing/xilinx7/cadr_debug_pmod.xdc` is the
four-tick exception written for exactly that cone, and each board's flow read
it only when the processing system was in the design, while the carrier itself
is instantiated on every board. So the memory-off board was timed without it
and missed by 9.6 nanoseconds. **That gap is closed**: every board's flow reads
the file unconditionally now and asserts that it reached a path.

Both of those figures were measured before it was closed, so neither is of a
design anybody builds today. The memory-off row in the table above is a later
build, with the carrier in it and timed.

### With the memory in it

Placed and routed by the same flow at `be01ca0`, the commit that put main
memory here, `DDR=1` against the same tree with `DDR` off, so the two rows are
one comparison. **Neither run's reports were kept**, so both columns are what
that run reported rather than what a report file says today, and both predate
the debug cable's carrier being timed --- which is why the memory-off column
here is not the memory-off row in the table above.

| | memory-off | memory-on |
|---|---|---|
| worst slack | **+1.103 ns**, met | **+0.232 ns**, met |
| failing endpoints | 0 of 27,156 | 0 of 40,343 |
| hold | +0.093 ns, met | +0.008 ns, met |
| pulse width | +3.000 ns, met | +0.206 ns, met |
| Slice LUTs | 6,032 of 63,400 (9.51%) | 10,400 of 63,400 (16.40%) |
| Slice registers | 2,405 of 126,800 (1.90%) | 6,541 of 126,800 (5.16%) |
| block RAM tiles | 38 of 135 (28.15%) | 38 of 135 (28.15%) |
| DSP | 0 of 240 | 0 of 240 |
| clocks | 4 | 25 |
| paths at the relaxed requirement | 18,862 of 27,274 | 18,860 of 40,505 |
| bitstream | 3,825,992 bytes | 3,825,992 bytes |

So main memory on this board costs **4,368 Slice LUTs and 4,136 registers**,
which is 6.9% and 3.3% of the part, and **not one block RAM tile** --- the
controller's queues and its physical layer's buffers are in the input and
output tiles and in distributed memory, not in block RAM. That last row is
worth having before anyone reaches for a smaller part, because block RAM is
what binds on the Cora Z7-07S.

**The memory-off column moved by 23 LUTs and 2 registers** against the
`86d787b` figures in the section above, which is the DDR3L's own ports arriving
in the port list of both configurations and being driven to their safe state in
one of them. The slack moved 0.124 ns, which is inside this project's own
quarter-nanosecond placement noise and is not a finding.

**Read the memory-on slack with what closed it attached.** Two constraints were
missing from the first build that met every assertion in this flow and still
reported **-5.367 ns**, and each is worth knowing because neither is visible in
a timing report until it is written:

The bus's own 80 nanosecond contract. `u_machine/processor/vma_reg[13]/C ->
u_cross/addr_q_reg[13]/D` is twelve logic levels through the level-1 map and
`main_byte_address`, 10.342 nanoseconds of which seven are routing, and it
reported **-0.499 ns** timed at one tick. The machine's own bus specification
gives it sixteen: "it is the responsibility of the bus master to assert good
address, write, and data lines 80 ns. prior to asserting -XBUS.RQ". The Arty
Z7-20 met the identical wall one module along.

The tally into the debugger's shift register. The tally counts in the
controller's clock and the shift register captures it in the test access port's,
and an unconstrained pair of clocks asks for whatever period they happen to
share --- 1.538 nanoseconds here, and **-5.367 ns**, the worst path in the
design. The Arty Z7-20's debugger reads its tally off pins while the fabric is
still counting and that board's notes call it a count that was true at some
instant; this says the same thing to the fitter.

The two proving boards are the same design with the witness in the machine's
place on the port, so they are a shade smaller and a shade faster: `PROVE=1`
closes at **+1.316 ns** on 0 of 39,961 endpoints with 10,320 Slice LUTs and
6,366 registers, and `PROVE=2` at **+1.161 ns** on 0 of 40,071 with 10,354 and
6,403. **Their multicycle exception count is six where the memory board's is
eight**, and that is the right answer rather than a missing constraint: the two
that are absent are the bus's 80 nanosecond contract, whose exception starts at
the machine's own registers --- and on a proving board the machine does not
drive the port at all, so it reaches no path and is not listed.

The out-of-context flow, `vivado/fit.tcl`, synthesises `cadr_machine` on its
own with no top level, no output fold, no MMCM and no package pins:

| | |
|---|---|
| worst slack | **+0.705 ns**, met |
| Slice LUTs | 9,593 of 63,400 (15.13%) |
| Slice registers | 6,093 of 126,800 (4.81%) |
| block RAM tiles | 40.5 of 135 (30.00%) |

**It costs more than the board flow does, and that is expected.** Out of
context the machine's seams are real ports rather than constants, so nothing
folds: the disk's drive and block store, the I/O board's four cables, the
console's readout and the debug cable's lines all have drivers and loads. On
the board they are tied off and the drive, the serial chip and the mouse
constant-fold away. The two flows answer two questions and were never meant to
agree.

## The part, against the part database

Vivado's own part database at 2026.1 gives the XC7A100T as 63,400 LUTs,
126,800 flip-flops, 135 block RAM tiles and 240 DSP slices. Those four counts
are properties of the die, so the package and the speed grade do not change
them. The XC7Z020 on the Arty Z7-20 has 53,200 LUTs and 140 block RAM tiles,
so this part has more logic than the one this project runs on today and about
the same block RAM.

**The smaller variant of this board is not the cheap way in.** The same board
exists as the Arty A7-35, whose part is an XC7A35T: 20,800 LUTs and 50 block
RAM tiles. The Arty Z7-20's memory-on design would already be 52.4% of its
logic and 83.0% of its block RAM before a single one of the fabric answers
above was added. That is as tight as the Cora Z7-07S or tighter, and the Cora
is the board this repository calls the hard one. This variant is the right one.

**The free tier places and routes this part.** That was an open question too.
`get_parts` listing a part says the device data is installed; it does not say
the licence will build it, and the only way to find out is to run a build,
because a refusal is an unmistakable licence error in the tool's own words. The
fit above is the answer. The log reads `A valid Vivado Design Suite BASIC
license has been detected`, then `Got license for feature 'Vivado_Synthesis'
and/or device 'xc7a100t'` and the same for `Vivado_Implementation`, and the run
goes through to a bitstream with **zero critical warnings and zero errors**.

## What is here

| | |
|---|---|
| `cadr_arty_a7.sv` | the top level: the clock, the machine, the memory, the soft processing system, the tie-offs, the probe, the fold, the lamps |
| `cadr_arty_a7.xdc` | the pins the design uses, the board clock, and the Artix's configuration properties |
| `cadr_a7_memory.sv` | the DDR3L behind the machine's memory port: the generated controller, the crossing into its clock, the driver for its user interface and the tally at its edge |
| `cadr_a7_ddr.xdc` | the memory board's two extra clocks and the three places the design crosses between them |
| `cadr_a7_ddr_off.xdc` | the same for a board with the controller out, generated and held current |
| `mig/` | the generated memory controller, its project file and the argument for generating it |
| `vivado/bitstream.tcl` | synthesis, place and route, the constraint assertions, and the bitstream |
| `vivado/fit.tcl` | the same for `cadr_machine` alone, out of context |
| `vivado/mig.tcl` | generate the controller in batch from the project file |
| `vivado/mig_check.py` | is what is committed what the generator writes today |
| `vivado/program.tcl` | program the part over JTAG, by cable serial |
| `vivado/probe.tcl` | read the capture back over JTAG into a file `tools/probe_check.py` can diff |
| `vivado/mem_window.tcl` | the debugger's side of the memory window, sourced by the three below |
| `vivado/ddr_check.tcl` | can the debugger reach the DDR3L, and does what it writes come back |
| `vivado/prove.tcl` | does the fabric write real memory, and does it read it |
| `vivado/ddr_run.tcl` | the machine running MIT's boot PROM out of the board's own DDR3L |
| `vivado/qspi.tcl` | write the bitstream into the board's flash, never run |
| `firmware/` | the soft processing system's bare-metal C, its linker script and its reset vector |
| `Arty-A7-100-Master.xdc` | Digilent's published pin file, byte for byte |
| `Digilent-License.txt` | the MIT licence that file is published under |

`make build/arty_a7.pass` lints the top level in all seven of its
configurations: the machine, the machine with the probe, the machine with its
memory behind it, the two proving boards, the machine with the soft processing
system, and `SOC=1 DDR=1`, which is the only one of the seven that is the whole
board. A check that lints one configuration says nothing about the others, and
this repository has already had a whole seam with no check of any kind from any
tool while `make check` was green. The design cannot be simulated, Verilator
having no `MMCME2_BASE`, and what lint holds is
that the port list matches, that nothing is undriven, and that the `witness`
fold names every output of `cadr_machine`. **That last is a real check and not
a duplicate of the other board's**: two top levels now instantiate the machine,
and an output added to it and connected in only one of them is a missing pin in
the other.

### Three files this board's flow reads from another board's directory

`boards/arty-z7-20/vivado/tick.tcl`,
`boards/arty-z7-20/vivado/constraints_check.tcl` and
`boards/arty-z7-20/cadr_probe.xdc` are board-independent by construction. The
first takes the file to parse as an argument, the second takes a period and a
list of instance names, and the third names the `BSCANE2` by what it is and the
clock by a name every board's constraint file uses. Copying them here would be
three more copies to go stale, which is the failure this project records more
often than any other, so they are read where they already are.

**The Cora Z7-07S does the same for the first two and takes a copy of the
third.** `boards/cora-z7-07s/cadr_probe.xdc` differs from the Arty Z7-20's in
one comment line, which names the flow that reads it. So the repository now has
two copies of that file and this directory deliberately does not add a third.

**All three belong somewhere neutral.** This repository's layout decision
already puts the vendor-specific pieces that are not a board's in
`rtl/plumbing/xilinx7/`, and that is where these should go: the probe's
constraints sit beside `rtl/plumbing/xilinx7/cadr_probe.sv`, which is the
module they constrain. Moving them is a commit that touches every board
directory and it is owed.

### On silicon

Run on the board with the `DDR=1` bitstream above, twice, the second time to
reproduce the first.

**The debugger reaches this board's DDR3L.** `vivado/ddr_check.tcl` found one
device in the chain, IDCODE `0x13631093`, selected USER2 with the instruction
register capturing `0x35`, and read `0x4d454d57` --- `MEMW` --- out of the
window. The controller reported its calibration finished. Four different words
written one 32-bit lane at a time into one sixteen-byte block came back in
their own lanes, and 64 words poisoned injectively in the address read back as
the poison written at their own address.

**And the machine ran MIT's boot PROM out of it.** `vivado/ddr_run.tcl` held
the machine in reset, poisoned 1,024 words at `0x18000000` upwards, read them
back to establish that the debugger's own path was good, let the machine go,
and waited 400 milliseconds:

    MEM: the machine asked for 256 read(s) and 256 write(s); the controller
    MEM: answered 256 and 256
    MEM: all 1024 words are byte-identical to their poison, page 0 and its
    MEM: margin

256 and 256 is exactly the boot PROM's `PAGE-0-PARITY-FIX`: it reads each of
page 0's 256 words and writes the same word straight back, and it never looks
at the data. **Both halves are needed and neither would do on its own.** The
words say the path did no harm, and cannot say the machine used it, because a
machine whose port was dead times every cycle out and leaves the same words
untouched. The tally says how many transactions the controller itself accepted
and answered, which a fabric that issued nothing cannot fabricate --- and it is
not on the path the debugger's own words travel.

The second run reported the same figures.

**The lamps say almost nothing about any of this, and that is expected.** With
the memory answering, 512 of the boot PROM's 17,466 bus cycles end in about a
hundred and fifty nanoseconds instead of on the 4.25 microsecond timer, and the
other 16,951 are disk polls the disk controller's own registers answer either
way. So LD5 blinks at 1.5 Hz as it always did, LD6 blinks with the microcycles a
hair faster, LD4 is `MACHRUN` at very nearly the brightness it had, LD7 is dark
for want of a drive, the tricolour LD1 is blue because the machine never leaves
its boot PROM without a disk, and the tricolour LD0 is dark. The Arty Z7-20's
own notes reached the same conclusion about its memory and say so: there is no
lamp-visible difference between memory working and memory absent.

What a person at the board WILL see is the scripts holding the machine: LD6
stops blinking and LD4 goes out while the debugger poisons memory, and both
come back when it lets go. All three scripts let go before they exit.

**Both proving steps passed too.** `PROVE=1`: the debugger poisoned 64 words
around the proving address, released the witness, and read back the fabric's
own word at its own address with the three lanes it shares a sixteen-byte block
with untouched. `PROVE=2`: the debugger put the word there itself, released the
witness, and read what the fabric had read and written back, raw, seven blocks
away --- "with no constant in between", which is the difference between this
and a match bit the fabric holds.

**AND PROGRAMMING THIS BOARD IS NOT RELIABLY ONE SHOT, WHICH THE WINDOW FOUND
AND THE DONE CHECK CANNOT.** Three of the six programmings in this session did
not take: `vivado/program.tcl` reported `DONE after programming: 1` and the
window then answered `0x00000000` --- which is what an unselected user scan
chain reads --- on every run until the same file was programmed a second time,
after which it answered `MEMW` and everything passed. Re-running the readout
without re-programming never helped, so it is the configuration that did not
happen and not a settling time.

That script's own note already says its DONE check cannot prove a part took
THIS bitstream, because DONE is already high on a part configured a minute ago.
**The window is the first thing on this board that can**: a register that says
its own name cannot be mistaken for a chain nobody selected. Anything run here
should read `MEMW` before it believes a word of what follows, and all three
scripts do.

## The recipe, and its first run on silicon

The recipe below has been run once on the board, from the probe bitstream
built at this tree. The hardware manager found a chain of one device, the
XC7A100T, with no bypass bits before or behind the sample. The capture of the
first 1,024 microcycles agreed with muir's `rtl` engine on all 23 compared
columns, aligned at microcycle 0 with no gap and no repeat, and eight columns
that stay constant in the boot PROM's opening were checked vacuously and named
as such. Both bitstreams built for the run reproduced the fit figures above.
The board was left running the plain memory-off bitstream, where the machine
runs on through its memory timeouts as `make nomem` says it does. Nothing is
in the flash, so a power cycle clears the part.

Two things the run taught. The programming script's DONE check passes on a
part that was already configured, so it cannot prove that the part took this
bitstream; the probe agreeing with muir is what proves it. And a failed
`cargo run` behind `make build/boot_prom.hex` leaves an empty file that `make`
then calls up to date, which would load a control store of nothing; the rule
wants a temporary file moved into place, or `.DELETE_ON_ERROR`.

Every step names the JTAG cable by its serial number. More than one board can
be on one host's USB, and a target taken by position is whichever the server
enumerated first, which is not a fault anybody sees until the wrong board
changes behaviour. None of these scripts has a default cable, for the same
reason `tick.tcl` has no fallback period.

Build the instrumented bitstream, program it, and read the capture back:

    make build/boot_prom.hex build/rtl.golden
    PROBE_DEPTH=1024 OUTDIR=build/a7-probe \
        vivado -mode batch -source boards/arty-a7-100/vivado/bitstream.tcl
    BIT=build/a7-probe/cadr_arty_a7.bit CABLE=<the cable's serial> \
        vivado -mode batch -source boards/arty-a7-100/vivado/program.tcl
    CABLE=<the cable's serial> PROBE_DEPTH=1024 OUTDIR=build/a7-probe \
        vivado -mode batch -source boards/arty-a7-100/vivado/probe.tcl
    python3 tools/probe_check.py --capture build/a7-probe/capture.csv \
        --golden build/rtl.golden

The last line is what would make this board's first claim about silicon. It
compares what the part computed in its first 1,024 microcycles against what
muir computes, column for column.

**The chain is one device, where the Arty Z7-20's is two.** A Zynq presents the
ARM debug access port beside the part, so a scan there has to place USER1 in
one device and BYPASS in the other. An Artix-7 has no such companion: the part
is the whole chain, its instruction register is six bits, and a data scan is
the sample and nothing else. `vivado/probe.tcl` still computes that padding
from the chain it finds rather than writing zero down, so a chain that is not
this one fails at the check that names it rather than on a sample of zeros.
The numbers it asserts are quoted from Vivado's own BSDL for the part,
`data/parts/xilinx/artix7/public/bsdl/xc7a100t_csg324.bsd`.

For a board that comes up with nothing plugged into it, `vivado/qspi.tcl`
writes the bitstream into the QSPI flash. **It has never been run**, it refuses
to guess which flash the board carries, and its header lists the four parts
Vivado accepts for a 128-Mbit device on an Artix-7 and the three ways to find
out which one is fitted.

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

Every pin in it is commented out, which is how Digilent publishes it.
`cadr_arty_a7.xdc` copies out the pins this design uses and keeps Digilent's
own schematic names in the comments, so that the mapping can be checked against
the board rather than against memory.

**Two things that file does not carry.** It has no `CFGBVS` or `CONFIG_VOLTAGE`
property, and an Artix needs both: without them `write_bitstream` reports a
critical warning and carries on, which is a warning in a log nobody reads.
`cadr_arty_a7.xdc` sets them and says why. And it has no memory pins at all,
which is not an omission either: the DDR3L pins come from Digilent's board
definition in `github.com/Digilent/vivado-boards`, which is the file a memory
controller's generator would read.

`Digilent-License.txt` is the MIT licence text from the same repository and the
same commit, 1,064 bytes, sha256
`fbdfae05e542ea6ad7e11e3818076b46d2b6bd81dac49c59bc9ac78025ba5339`. Digilent
publishes it as `License.txt` and it is renamed here so that nobody reads it as
the licence of this directory. Everything else here is AGPL.

## This is still not a port

An Artix-7 has no processing system, and that is the whole difference. What
carries over is the machine: everything in `rtl/machine/` is plain
SystemVerilog and does not know what part it is on, and the Xilinx-specific
pieces in `rtl/plumbing/xilinx7/` are seven-series, so the probe's `BSCANE2`
and the constraint syntax carry over as well. What does not carry over is
`boards/arty-z7-20/cadr_ps7.sv`, every `ps7_*` script in that directory's
`vivado/`, and the whole of its `linux/` tree.

So the part is not the obstacle on this board. The work is.
