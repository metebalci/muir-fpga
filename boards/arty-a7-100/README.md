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

The CADR runs its boot PROM. There is nothing behind its memory port, so
nothing answers the main-memory cycles. That is not a fault of this board. It
is the Arty Z7-20's own memory-off configuration, which is the one this project
has built and measured from the beginning, and it is what a board with no
memory controller can do.

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

**Neither has been run on this board.** Everything below the fit figures is a
recipe and not a measurement.

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
| `-PROMDISABLE`, blue only | LD5 | `led1_*` | LD1 |
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
panel. BTN3 resets the fabric. SW0 is the no-auto-boot switch: with it on, the
machine comes out of reset with `RUN` and `SRUN` clear and stands as a CADR
does when the power comes on with nobody at it, and any `-BOOT` source starts
it. BTN1, BTN2 and SW1 to SW3 have no meaning here.

## What is absent, and the shape of each answer

Every item below is a seam whose far end is a program on the Arty Z7-20's ARM
cores or a port of its processing system. `boards/arty-a7-100/cadr_arty_a7.sv`
ties each one off at the value a cable with nothing on the end of it presents,
and names it there. **None of these is started and none of them should be
started from this note alone.** Where a decision is needed, this says so and
does not take it.

**Main memory.** The board carries 256 MB of DDR3L on the fabric's own pins,
where the Arty Z7-20's DDR3 is the processing system's. So this needs a memory
controller in fabric. There are two ways and the choice is a decision: Xilinx's
Memory Interface Generator, which arrives as a directory of generated XML, or a
controller written here. This project has declined generated IP directories
twice already, for the clock generator and for the debug probe, and both times
the hand-built answer was smaller and readable. A DDR3 controller is a much
larger thing than either. **The decision has not been taken and this note does
not take it.** What the machine needs is modest: `rtl/plumbing/cadr_ddr_map.sv`
reserves 128 MB and what is reachable is 3,932,160 words, about 15 MB, so 256 MB
is seventeen times what the CADR can address.

**The disk.** On the Arty Z7-20 a Linux program reads a pack file off the SD
card and fills the block store over `S_AXI_HP2`. The card there is wired only to
the processing system, and Digilent's master file for this board constrains no
card pins at all. So the answer is an SD host in fabric, reading a card through
one of the Pmod headers, with the pack at a raw offset rather than as a file. That reopens a question this project
settled once for a board that has Linux, which is who computes the block
headers and checkwords.

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
`uart_rxd_out` on D10 and `uart_txd_in` on A9. The Arty Z7-20's master file
constrains no UART pins at all, so that board's serial port is the processing
system's. Here it is the fabric's, and the answer is a transmitter and a
receiver beside `rtl/plumbing/cadr_serial_line.sv`, which already does the
2651's framing and its baud-rate generator against a socket.

**The console and the debugger.** Both are Linux programs on the other board:
the console reaches sixteen diagnostic registers over `M_AXI_GP1`, and the
debugger is muir on the ARM cores driving MIT's debug cable through a register
window. Neither has a fabric shape yet and **this note does not invent one.**
What is worth knowing is that the debug cable's Pmod carrier is pure fabric and
carries over unchanged: the debug cable adapter puts its whole link on JA, so
that assignment carries over by name, and this board has four Pmod headers
where the other has two. A second board on the other end of that cable is a
debugger this board could have with no processing system anywhere.

**The boot.** The Arty Z7-20 comes up because the processing system reads a
card. Here the part reads its own 16 MB QSPI flash at power-on, and that
carries the bitstream and nothing else. `vivado/qspi.tcl` is the recipe and it
has never been run.

**The keyboard and the mouse.** The other board's USB host is the processing
system's own controller. This board has no USB host at all, so these would be a
host in fabric. They are last in this project's order of work on any board.

## The fit, measured

Placed and routed for `xc7a100tcsg324-1` at commit `86d787b`, memory-off, with
`boards/arty-a7-100/vivado/bitstream.tcl`. Beside it is the Arty Z7-20's own
memory-off board, built from the same commit by the same flow, so the two are
one comparison and not two quotations. **Nothing under `rtl/` changed between
`86d787b` and the commit these files land at**, so the figures are of the
machine as it stands.

| | Arty A7-100 | Arty Z7-20, memory-off |
|---|---|---|
| part | `xc7a100tcsg324-1` | `xc7z020clg400-1` |
| worst slack | **+1.227 ns**, met | **-9.600 ns**, NOT met |
| failing endpoints | 0 of 27,148 | 596 of 28,959 |
| hold | +0.043 ns, met | +0.040 ns, met |
| Slice LUTs | 6,009 of 63,400 (9.48%) | 6,330 of 53,200 (11.90%) |
| Slice registers | 2,403 of 126,800 (1.90%) | 3,039 of 106,400 (2.86%) |
| block RAM tiles | 38 of 135 (28.15%) | 38 of 140 (27.14%) |
| DSP | 0 of 240 | 0 of 220 |
| paths at the relaxed requirement | 18,861 of 27,266 at 150.000 ns | 18,843 of 28,916 at 150.000 ns |
| bitstream | 3,825,992 bytes | 4,045,764 bytes |

**THE SLACK ROW IS NOT A COMPARISON AND THE OTHER BOARD'S FIGURE IS NOT ITS
PART'S FAULT.** Every one of the Arty Z7-20's 596 failing endpoints is in
`u_dbgin_pmod`, the debug cable's Pmod carrier, and the ten worst paths all run
from `u_machine/processor/memstart_reg` to `u_dbgin_pmod/tx_frame_reg[*]` ---
twenty-five logic levels of the machine's diagnostic multiplexer reaching a
register outside the machine. `rtl/plumbing/xilinx7/cadr_debug_pmod.xdc` is the
four-tick exception written for exactly that cone, and
`boards/arty-z7-20/vivado/bitstream.tcl` reads it only when the processing
system is in the design, while the carrier itself is instantiated on every
board. So the memory-off board is timed without it and misses by 9.6
nanoseconds. That is a gap in one flow's constraints, not a property of the
part, and it has been invisible because that board is not built any more; the
bitstreams that go on silicon are built with the processing system, where the
file is read. **It is reported and it is not fixed here**, this directory not
owning that one.

This board has no such arc at all, because it does not instantiate the Pmod
carrier: its debug cable is tied off and the machine's `DBD` lines reach
nothing but the false-pathed fold. So the two slack figures are of two
different designs, and only the rows below the slack rows compare.

**The count of relaxed paths is the check that the constraints reached the
design, and it is the row to read first.** `rtl/plumbing/xilinx7/cadr_machine.xdc`
relaxes the machine's datapath registers to fifteen ticks, and an exception
that applied to nothing is listed by `report_exceptions` exactly as one that
reached ten thousand paths. What separates them is the setup requirement the
paths themselves carry. A design where nothing asks for 150 ns is the
unconstrained design, whatever any report says, and every slack figure from
such a run would be of a machine nobody meant to build.

With the probe in the design, at `PROBE_DEPTH=1024`:

| | |
|---|---|
| worst slack | **+1.069 ns**, met |
| failing endpoints | 0 of 28,948 |
| Slice LUTs | 6,253 of 63,400 (9.86%) |
| Slice registers | 3,351 of 126,800 (2.64%) |
| block RAM tiles | 51 of 135 (37.78%) |

**Read every number here with its commit attached.** Slack in this project has
moved a quarter of a nanosecond between two builds of bit-identical logic, so
anything inside that is placement and not a finding. Utilisation answers "does
it fit", which is about the design's shape and barely moves; slack answers "is
this build finished".

**And read the whole table as a floor.** The design measured here is the
machine with every seam tied off. A tie-off is not free and that is the point:
the drive constant-folds, the serial chip constant-folds, the Chaosnet
interface folds with its address switches at zero, and the mouse's counters
fold because nothing on its seven lines ever changes. Every fabric answer in
the section above adds logic and block RAM that these figures do not include,
and a DDR3 controller adds a great deal of it.

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
| `cadr_arty_a7.sv` | the top level: the clock, the machine, the tie-offs, the probe, the fold, the lamps |
| `cadr_arty_a7.xdc` | the pins the design uses, the board clock, and the Artix's configuration properties |
| `vivado/bitstream.tcl` | synthesis, place and route, the constraint assertions, and the bitstream |
| `vivado/fit.tcl` | the same for `cadr_machine` alone, out of context |
| `vivado/program.tcl` | program the part over JTAG, by cable serial |
| `vivado/probe.tcl` | read the capture back over JTAG into a file `tools/probe_check.py` can diff |
| `vivado/qspi.tcl` | write the bitstream into the board's flash, never run |
| `Arty-A7-100-Master.xdc` | Digilent's published pin file, byte for byte |
| `Digilent-License.txt` | the MIT licence that file is published under |

`make build/arty_a7.pass` lints the top level in both its configurations. It
cannot be simulated, Verilator having no `MMCME2_BASE`, and what lint holds is
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

## The recipe, which has not been run on silicon

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
