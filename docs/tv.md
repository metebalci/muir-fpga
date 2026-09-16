<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The display controller

The TV is MIT's name for the CADR's display controller. The first board is
the SIMPLE TV of `cadrtv/`, which is what the window system asks for by
`'(:VIDEO :BLACK-AND-WHITE :CONTROLLER :SIMPLE)`, or the LISPM TV that
replaced it in December 1980. A machine can carry a second board as well: the
color TV, which is a LISPM TV strapped elsewhere and driving a color monitor.
The sections "Which board" and "The second display board" at the end are those
two facts; everything between them is both boards. This document describes it
as an Xbus device in the fabric, checked against muir. It was written at the
slice, with muir at `dad7249`, so read that on anything below which says what
does or does not exist. Its citations into muir were renumbered when the pin
moved to `bfba7f3`, the commit at which muir began running the board's sync
program. The fabric runs that program too, and what it took is said where it
bears. This document has the same shape as `docs/disk-controller.md`:
what muir says the board is, what the two reference programs actually ask of
it, the decisions, what the check holds to and cannot, and what is deliberately
not built.

## What muir says the TV is

The reference is `src/tv.rs`, whose header names three sources and says
they agree. They are `sys/window/shwarm.lisp` in the System 100 release (the
software that writes to this device), `cadrtv/lmtv.order` (MIT's programming
specification for the board), and `data/SIMPLETV.netlist` through
`tools/simpletv-netlist.sh` (the board itself, all 29 SUDS pages). What follows
is that file, line by line.

- **There is a frame buffer of 32,768 words at `0o17000000`** (`BUFFER`, line
  74; `BUFFER_WORDS`, line 78). `MAIN-SCREEN-BUFFER-ADDRESS` is
  `IO-SPACE-VIRTUAL-ADDRESS`, the base of Xbus I/O space, and
  `MAIN-SCREEN-BUFFER-LENGTH` is `#o100000`. The picture is one bit a pixel,
  768 across, 24 words to a line and 963 lines (`WIDTH`, `HEIGHT`,
  `WORDS_PER_LINE`, lines 100--108). The screen uses 23,112 of the 32,768 words.
- **There are eight control words at `0o17377760`** (`CONTROL`, line 84;
  `CONTROL_WORDS`, line 97). `MAIN-SCREEN-CONTROL-ADDRESS #o377760` is an
  I/O offset, and the physical address is that plus `BUFFER`. `lmtv.order` runs
  them `173777x0` to `x7`. The 74S138 at NXBCTL 0F13 decodes eight and its top
  three outputs go nowhere, so words 5 to 7 are the three that `lmtv.order`
  says "respond but don't do anything". **Word 4 is not one of them. It is the
  Color register.** That output of the decoder is `-LOAD COLOR`
  (`data/SIMPLETV.netlist`, page NXBCTL, part 0F13, pin 11), and `lmtv.order`
  gives the register as write only, with the value for the color map in bits
  15 to 8, the channel in bits 7 and 6 and the color in bits 3 to 0. MIT's
  own `WRITE-COLOR-MAP-IMMEDIATE` writes it three times, once a gun
  (`sys/window/color.lisp`, lines 161--163). The map itself is not on this
  board. Page NRACOL carries the interface and no memory at all. `lmtv.order`
  describes the map as a 64 by 9 RAM for each channel with a
  digital-to-analog converter on it. So a write to word 4 reaches nothing on
  the board itself. **The fabric keeps the sixteen entries**, as muir has
  since `bfba7f3` (`Tv::color_map`), because a four-bit pixel of the color
  screen is an address into them and whatever draws that screen has to know
  what a color is. They are kept on both boards, both netlists strobing the
  map with the same circuit, and they are offered to Linux on the console
  face's pages 4 and 5. No bus cycle reads one back on either board, so the
  register stays write only on the Xbus and no trace can check it; the map's
  own port is what `build/color_tv.pass` compares. The four words above the
  eight, `0o17377770`--`3`, sit between the display's registers and the disk
  controller's and answer to nothing.
- **Register 0 is the mode register**, with four writable bits
  (`mode::WRITABLE`, line 266). They are `CLOCK MODE<1:0>` (line 255), `MODE
  BOW` (line 260, "display one bits as black and zeros as white") and `MODE
  INTR ENB` (line 262). They are the Am25LS2519 at NXBCTL 0F12. muir's note at
  `mod mode` says MIT drew this page twice, a 74S174 in 1979 and the 2519 in
  1980, and the netlist is the newer sheet. Bits 5 to 7 (`VSYNC`, `HSYNC`,
  `SYNC PROM ENB`, lines 280--313) are read only. **Bit 7 is the one bit of
  the interface the two display boards differ in**, and it is why `--tv-board`
  is a setting at all: on the SIMPLE TV it is grounded --- ECO 2 of
  `lmtv.eco`, of 18 June 1980, wires `GND` to that input of the read buffer so
  that the window system can tell old boards from new --- and on the LISPM TV
  it reads the sync enable back. The section "Which board" below has it. Bits
  5 and 6 are wired to the sync generator. The 74LS244 at NXBCTL 0F11 takes
  `VSYNC` on pin 4 and `HSYNC` on pin 6, and the 74LS175 at NSYREG 0D02
  registers both of those from the sync program's own bits 0 and 1. **The
  fabric runs that program and reads the two bits off it**, as muir has since
  `bfba7f3`; both read zero up to `4ddaeb2`, and both said so as a departure.
  They change 1,932 times in a frame of MIT's `cpt.prom`.
  The distinction matters to anyone who adds the color board, because MIT's
  `WRITE-COLOR-MAP` spins on bit 5 and its `%XBUS-WRITE-SYNC` waits on bit 6
  (`sys/window/color.lisp`, lines 139--143), which is exactly what muir
  changed in order to make the color board work.
- **Bit 4 is the vertical flag, a flop of its own** (`mode::VERT`, line 278).
  It is the 74LS74 at NXBCTL 0E14. It is **preset by `-TVMA CLR`**, the sync
  program's start of frame: "this is set by TVMA CLR, not by the start of
  Vertical Sync". It is **clocked by `-LOAD MODE` with `XDI 4` as its data**,
  so a write of the register puts the written bit 4 into it. Microcode 323's
  `INTRX0` takes the interrupt by reading the register, testing this bit and
  writing it back with the bit cleared. `vert_flag(ns)` (line 667) is
  what the last write put in, or set if a `-TVMA CLR` has fallen *strictly*
  since. Up to `4ddaeb2` muir counted frame boundaries from power-on instead;
  since `bfba7f3` it counts the sync program's `-TVMA CLR`s, and so does the
  fabric. For `cpt.prom` in clock mode 0 that falls 16,000 ns into the
  program, as the first line's 32nd instruction completes, and once a frame
  of 15,456,000 ns thereafter.
- **`SEND INTR` is the flag with the enable**, the 74S08 at 0D10, onto
  `-XBUS.INTR` (`interrupt`, line 674). `machine.rs:457` ORs it with the
  disk's request as `XBUS INTR IN`, and since `bfba7f3` with a color board's
  own request when one is fitted. `rtl.rs:1950` registers that as `SINTR` at
  the microcycle edge, which is the `sintr` column of both processor traces.
- **The frame is `FRAME_NS` = 15,456,000 ns** (line 331). That is 966 lines of
  16.000 us, or 64.7 Hz, "the roughly-60-cycle clock". It was measured on the
  netlist board in `tests/simpletv_netlist.rs` and `tests/monitor.rs`. muir
  kept the flag "on a frame clock rather than a raster", with frames counted
  from power-on, up to `4ddaeb2`, and said so as a knowing departure from the
  machine. Both run the program now. The figure is still what a frame comes
  to, and it is no longer a counter in either place: the flag's instant is
  where `-TVMA CLR` falls, and the program's start moves.
- **Registers 1 to 3 are the sync program RAM** (`SyncRam`, line 365). It is
  the eight 2147s at NSYRAM, 4K by 1 each, addressed by a twelve-bit pointer.
  Register 1 is the data at the pointer, read and written. Register 2 is the
  pointer, write only. Register 3 is the enable in bit 7 over the vertical
  spacing in 6--0, write only. With the enable clear the 74S472 PROM is
  selected instead, and a read of register 1 is the PROM's word. **The
  program in the RAM is run as well as stored**, as muir has run it since
  `bfba7f3`, and MIT's own `cadrtv/cpt.prom` --- 297 words of the 74S472's
  512 --- is what runs from power-on until the software selects the RAM.
  `SI:SETUP-CPT` loads the RAM at every `LISP-REINITIALIZE` and reads it
  back. The image reaches the fabric as `build/sync_prom.hex`, written by
  `golden/src/sync_prom.rs` out of muir's own copy and never committed, for
  the reason the boot PROM's image is never committed.
- **`-XBUS INIT` clears the flag and nothing else** (`xbus_init`, line 810,
  and its long note). `-RESET` reaches pin 13 of the 74LS74 alone. The mode
  register and the sync enable clear on `-POWER RESET`, a backplane wire the
  processor raises only at power-on. `lmtv.order` has the enable "cleared by
  Xbus reset", where the drawing has it on the power reset, and muir follows
  the drawing.
- **The device answers in no time of its own.** `busint::decode` calls both
  ranges `Responder::Device` and `IDEAL_DEVICE_NS` is 0. So a read
  acknowledges 140 ns after the grant (80 of setup and the 60 ns deskew tap
  of the TD100 at REQLM 0C09) and a write at 80, exactly as the disk
  controller's registers do.

That is a reference with time in it at exactly one place, the frame. Its
structure is one the fabric can mirror: three registers, a RAM, a flop with
three sources, a counter. It was traceable, and it was traced.

## What the two reference programs ask of it

This was measured with a throwaway probe against muir's `rtl` engine, with the
`tv` fields read after the run.

**MIT's boot PROM, over 600,000 microcycles, asks for nothing.** No cycle
reaches either range. The mode register is 0, the sync RAM is empty, the buffer
is all zero, and `Tv::interrupt` is false on every row.

**The System 100 band, over 2,200,000 microcycles, asks for the frame buffer
and nothing else.** The mode register stays 0 and the sync RAM stays empty for
the whole run. `tests/vertical.rs` says why: the cold boot's
`(LISP-REINITIALIZE NIL)` skips the `SETUP-CPT` block, so the interrupt is
never enabled and the microcode's `60CYC` never runs until somebody types
`(si:setup-cpt)`. But from microcycle 1,422,272 the band **does write the frame
buffer**. It writes the microcode's run lights, words `0o51763` and `0o51765`
at the bottom of the screen, all ones and cleared again around every disk
transfer. That is 917 changes of those two words over the run. The `sintr`
column's 17,185 rows are all the disk's.

So the band reaches a handful of words of one value in the window, and nothing
of the register face, the flag or the interrupt. **A check driven by either
program would test nothing.** The generated program is the only reference.
`docs/disk-controller.md` reached the same conclusion for the disk, for the
same reason.

## The decisions

**The sync program is run, and it is what makes the frame.** `lmtv.order`'s
`>Sync Program` gives the whole of it. An instruction is eight bits: two sync
bits, a composite sync bit, a blank bit, a two-bit video cycle type and a
two-bit special function. The program is a series of loops; a loop begins
with a word holding its repeat count, which "is never executed as an
instruction, and does not cause a time delay"; the second-to-last instruction
of a loop carries Special Function 2 or 3, one more instruction is executed,
and control returns to the loop's first instruction until the count runs out.
End of Program then returns to location 0 and End of Loop takes the word
after next as the next count.

**An instruction is 100 or 125 ticks and nothing rounds.** 500 ns in clock
modes 0 and 1 and 625 ns in modes 2 and 3, `sync::INSTRUCTION_NS`, measured
on the netlist LISPM TV --- which on MIT's 5 ns grid is exactly 100 and 125.
muir walks the whole program into a timeline because a model jumps in time;
the fabric executes one instruction every 100 or 125 ticks, which is a
program counter, a repeat counter, a loop's first and last addresses, and the
two sync bits latched an instruction late. It costs a second read port on the
sync RAM and a 512-word ROM beside it.

**MIT's `cadrtv/cpt.prom` is the program from power-on.** 297 words of the
74S472 at NSYRAM, which the enable selects against the 2147s. It reaches the
fabric as `build/sync_prom.hex`, written by `golden/src/sync_prom.rs` out of
muir's own copy and named at elaboration through `SYNC_PROM_HEX` --- exactly
as the boot PROM's image is, and generated rather than committed for the same
reason. The image is the whole chip, 512 words with MIT's 297 at the bottom
and zeros above, so that nothing in it is undefined and a read of register 1
above the program gives zero as muir's does. `$readmemh` on a file that is
not there is a warning and a program of zeros is a display that never
interrupts, so the module checks word 0 and stops, and both Vivado flows
check the file exists before they synthesize.

**A program that makes no frame is found by fetching.** `Timeline::of`
answers None for a program that runs off the end of its store without an End
of Loop, and answers it at the restart, because it has walked the whole
program by then. The fabric cannot look ahead: it fetches, and when the fetch
runs past the program --- 4,096 words for the RAM, 297 for the PROM --- the
generator stops and nothing moves again until a restart. The two agree as
long as no such program stands for as long as one instruction, and the
generator asserts exactly that.


**The frame buffer is DDR, through main memory's bridge at a second base.**
`rtl/plumbing/cadr_ddr_map.sv` has reserved 8 MB at `0x1C00_0000` for the display
since before anything filled it. The machine's 32,768 words are the first
128 KB of it, and `display_byte_address(offset) = DISPLAY_BASE + 4 * offset`.
`rtl/machine/cadr_tv.sv` decodes the window as the board's MAPADR switch does and
says so on `fb_sel`, held. `cadr_memory_path.sv` selects `cadr_xbus_ddr`
on it beside `is_memory`, and the bridge takes a `display` input that picks
the base. That is a mux on the address alone, in the 80 ns the bus gives the
address. **There is one bridge and not a second master**, and the argument is
the timing. muir's TV answers a buffer word in 0 ns of its own and the bridge
answers when DDR answers, so the composed machine waits on the frame buffer
exactly as it already waits on main memory. A second master on the same port
would wait the same and add an arbiter. The Xbus has one master a cycle, and
the disk's channel reaches main memory alone and never the window, so the
bridge is idle whenever the window is asked. In `build/tv.pass` the modeled
DDR answers at once and the acknowledgment lands where muir's does, tick for
tick. On the board it lands when DDR does, which is the parting main memory
already has and the display inherits.

**The register face lives inside `cadr_memory_path.sv`, not beside the disk
in `cadr_machine.sv`.** Half of the board is that module's business already,
because the select into the bridge is made there. Putting the other half with
it makes the display one module with one held decode. It also makes the
check's DUT the path itself rather than a harness of it: `tb/cadr_tv_tb.cpp`
drives `cadr_memory_path`, and the wiring under test is the wiring on the
board. The face hangs on the same seam the disk does, `sel` being the held
`device`. It decodes its own two ranges out of `phys` as a board on the
backplane does. The decode module is untouched and still checked over all
4,194,304 addresses.

**The store lands one tick after `-XBUS.RQ` rises, and the reference says
so.** muir's `Rtl` hands a written word to the slave at `answered_at`, the
request's own instant. A register in fabric takes it at the edge after the
request is first seen, and on the board the 2519 clocks on `-LOAD MODE`, a
gate or two behind `XBUS RQ`. `golden/src/tv.rs` therefore writes muir's
model at `answered_at + 5`, and the testbench compares `-XBUS.INTR` to it at
every tick, so the tick is a stated instant rather than a tolerance. It is
the disk's `STORE_HOLD_NS`, one tick instead of two because nothing here
decodes a START. The store's decision is one AND of the held match,
`-XBUS.RQ`, the direction and the cycle's latch.

**A read is made at `answered_at`, and the trace refuses one the fabric
would answer differently.** The fabric's MD takes the lines at the deskew
tap twelve ticks after the request, where muir reads the register at the
request. Two things can move in between: the vertical flag, at a `-TVMA
CLR`, and the two sync bits, at any instruction boundary. The board reads
both live through the 74LS244 at 0F11, so where they differ the fabric is
the board and muir samples early. The generator asserts that no
mode-register read has either moving inside its deskew, and none does. This
is recorded here so nobody widens a tolerance for it.

**The sync bits and the vertical flag are carried across a restart, in muir
as on the board.** Two parts, and the program's start reaches neither of
them. The bits are the 74LS175 at NSYREG 0D02, whose clear, pin 1, is a
pull-up and nothing else --- `HI`, the PULLUP at XBADR 0F10, on the SIMPLE
TV, and `HI5` at XBADR 0D04 on the LISPM TV --- so the register holds what
the program before it left until the new program's first instruction lands,
and at power-on it holds zero. The flag is the 74LS74 at NXBCTL 0E14,
preset by `-TVMA CLR` and cleared only by `-LOAD MODE` or `-RESET`, so it
stands across a restart. The fabric has done both since it was written.

These were two ways the fabric parted from muir and they are closed:
`Tv::restart` carries the flop's value and the held sync bits over, and
`Timeline::sync_at_since_start` answers the held bits until the first
instruction lands. Two asserts in `golden/src/tv.rs`, and two more in
`golden/src/color_tv.rs`, kept the reference trace out of both regions
while they were open; they are gone.

**What no trace exercises yet.** Removing those asserts does not move a
reference trace, because the script never places a write or a read where
they applied: it clears the flag before every restart and waits a whole
instruction before reading the mode register. So a restart taken with the
flag standing, and a mode-register read inside a run's first instruction,
are now comparable and are still uncompared. Writing them is a section of
the script rather than a deletion from it, and it would move
`tv.golden`, `tv_lispm.golden` and `color_tv.golden`.

**Priority at one clock edge is `-XBUS INIT`, then the write, then the
preset, and a restart over the instruction boundary.** A write landing on
the very tick a `-TVMA CLR` falls keeps the written bit, because
`vert_flag` asks for a field *strictly* since `written_at`. Reaching that
tick needs the grant edge, the 80 ns setup and the landing tick to sum to
the instant the preset falls. A store can land only on a tick congruent to
17 modulo 29, and the presets fall at `27 + 3k` modulo 29, so the three
cases --- one tick before a preset, on one, and one tick after --- are first
reachable at the twenty-sixth, sixteenth and sixth preset and at no earlier
one. **That is why the trace is twenty-seven frames and 83.7 million ticks
long**, and the generator asserts the three congruences rather than leaving
them to be rediscovered. A restart landing on an instruction boundary
suppresses that boundary, because muir's new timeline begins at the restart
and the old one's last instruction is not in it. `-XBUS INIT` is not tied to
the master clock, so it is put on a preset and a tick either side of one
directly. Init comes before everything, because the 74LS74's clear is a pin.

**And the instant the presets fall is pinned rather than found.** They are
the program's start plus 16,000 ns and a frame thereafter, and the start is
where the program was last restarted --- so the trace places frame 1's
clock-mode write at an exact tick with `write_landing_at` and takes that as
the origin. Nothing between there and the sync RAM section at the very end
restarts the program, which is why that section moved to the end: every
write in it moves the origin.

**`-XBUS.INTR` is whole in the fabric, since `f8c6d25`.** The display's
`SEND INTR` leaves `cadr_memory_path` as `tv_intr`, and the disk's request
leaves `cadr_disk_controller` as `intr`. `cadr_machine.sv` ORs the two
into the processor as muir does, in one expression, one gate before the
74S175 at LCC 3E12. **`sintr` is an output of `cadr_machine` now and not
an input.** It was renamed `sintr_o` deliberately, so that a testbench line
left driving it fails to compile rather than silently working. What was
written here before is that the disk's half was computed and kept inside the
controller, and that a board outside the fabric supplied the line. That was
true until the board spun for ever in `AWAIT-DISK` waiting for an interrupt
that had nowhere to go. The disk's half is exercised by `disk.pass` on all
380 rows and by `machine.pass` over 600,000 microcycles. **The display's
half is still a claim nothing exercises**, since neither reference program
enables the display's interrupt, and this paragraph is where that is
written down.

**The frame is 3,091,200 ticks, and since 2026-09-11 that is 30.912 real
milliseconds and not 15.456.** That day the tick was made longer instead of
timing closure being chased: 6.25 ns that morning and 10 ns the same
afternoon, when a one-character change to a multiplexer cost a third of a
nanosecond and the memory-on board stopped closing again. So the fabric runs
at 100 MHz and the machine at 50% of the speed the hardware ran. Every tick
count in the design is unchanged --- this module's 100 and 125 ticks of a
sync instruction among them --- so
the machine's own time is exactly what it was and not one golden trace moved.
What it costs is that the vertical interrupt arrives at **32.35 Hz where the
display board scanned at 64.70**, and MIT's microcode uses that interrupt as
its roughly-sixty-cycle clock for mouse tracking and the scheduler's sequence
break. So the machine's idea of a second is 50% of one. **It is decided that
this keeps agreeing with muir for now**, because the checks are the
backbone of this project and nothing built yet needs the time of day. **And
undoing it is still one constant.** An instruction of the sync program is 100
or 125 ticks, and a real instruction at a 10 ns tick is 50 or 62.5 --- so
restoring real time here is not a change to this module at all but a change
to `TICK_NS`, and 62.5 is not a whole number of ticks. That is the floor this
project has always had: the tick may be stretched and may not be rounded.
Doing it would put this module out of agreement with muir, which is why it has
not been done.
`boards/arty-z7-20/linux/buildroot/package/cadr-terminal/src/screen_geom.h`
carries both numbers for the same reason, `SCREEN_FRAME_NS` and
`SCREEN_FRAME_REAL_NS`.

**The vertical spacing has no register.** Register 3's bits 6--0 are the
74LS273's spacing, which the board adds to `TVMA` on an end-of-line video
cycle. The fabric runs the sync program but makes no video cycles --- there
is no `TVMA` here, the picture being in DDR --- so nothing reads the spacing
back, in muir or here, and lint and the fitter agree it is not there. The
enable bit does have a register, because it chooses the program.

## What the check holds to

**A READ of the window is checked, and has been since the slice.** It is
worth saying outright, because the question was asked again on 2026-09-11 and
the answer was assumed to be no: the frame buffer is the one thing in the
window a program reads *back*, and 23 of the trace's 43 window cycles are
reads, compared against muir's own word at -MEMACK's rise, from a modeled DDR
poisoned injectively in the address so that a read of the wrong word cannot
come back right. The window's first word, its last, the word each side of it
and one offset rewritten are all among them. Configuration B, below, adds the
one thing the trace cannot reach.

In `build/tv.pass`, `tb/cadr_tv_tb.cpp` drives `cadr_memory_path` from
`build/tv.golden`. There is one row a tick wherever anything moves, and every
gap is stepped a tick at a time with the inputs held and every output required
to hold. The run is 83,970,731 ticks, twenty-seven frames and 259 bus cycles:

- **-MEMGRANT, -MEMACK, -LOADMD and NXM TIMEOUT are held against `Busint`** at
  every tick. A control-word read is acknowledged 140 ns after the grant, a
  write at 80, and the dead words go on the NXM timer.
- **MD is compared at -MEMACK's rise on every answered read** against muir's
  model: the mode register with the flag in bit 4 and the sync program's own
  `VSYNC` and `HSYNC` above it, the sync RAM's byte or MIT's PROM's, the
  frame buffer's word, and main memory's. There are 108 of them, and MD is
  zero on the seven cycles nothing answered.
- **-XBUS.INTR is compared against `Tv::interrupt` at every tick.**
  There are twenty rises and nineteen falls, from writes, from the sync
  program's `-TVMA CLR` with the enable on and off, and from five `-XBUS
  INIT` pulses. Three of the rises are there to date a restart: the program
  the enable selects, and the one a RAM word's write starts afresh, each
  reach their first `-TVMA CLR` at an instant only a restart at the right
  tick puts them at.
- **The memory port is checked.** Every frame-buffer cycle is at
  `DISPLAY_BASE` plus four times the offset and every main-memory cycle at
  `MAIN_BASE` plus four times the address, with the trace's word, asserted at
  the port on the tick. The word is read back through a modeled DDR keyed by
  the stimulus's address and filled from the stimulus's word, never the DUT's,
  and poisoned injectively where nothing wrote.
- **The counts are checked.** The run sees exactly the cycles of each kind,
  the interrupt edges and the inits the generator's header says it made.
- **The window's reads are counted and required to carry a word.** Of the 102
  answered reads, 23 are reads of the frame buffer, and the run requires one
  comparison per window read the header says the program made and requires
  every word it compared them against to have a bit set. Without that, a
  reference that started answering zero in the window, or a program that
  stopped reading it, would leave a check a bridge stuck at zero walks
  straight through. It also counts the window cycles that reached the
  display's region of DDR --- all 43 of them --- and requires that none
  reached main memory's.

The program runs the face at power-on. It writes the mode register's four bits
and its flag and reads them back, with everything above bit 4 dropped. It takes
the preset with the enable off and then on. It runs INTRX0 at four offsets into
four frames, and a frame nobody clears. It drives the sync RAM through 31
pointers spread over twelve bits and reads them back in another order, with the
enable off and on and the write-only registers reading zero. It writes the
frame buffer at eighteen offsets across the window and its edges, rewrites one
word with its neighbors checked, and lets the words just outside the window
time out. It pulses `-XBUS INIT` off a boundary, on one and a tick either side.
It toggles the flag by writes alone with the enable off. And it lands a write a
tick before, a tick after and exactly on a boundary. Three main-memory words
are in there too, so the bridge's other base is in the same trace.

## What configuration B holds to

The trace is muir's, and muir's TV answers a buffer word in no time of its
own, so the modeled DDR has to answer in the same tick for the
acknowledgment to land where the reference puts it. That leaves one thing
unexercised: `build/tv.pass` is the only check in the tree that ever puts the
display's base on the memory port, and it was also the only one whose memory
answered at once. `tb/cadr_memory_path_tb.cpp` waits six ticks and
`tb/cadr_ddr_boot_tb.cpp` four to twenty-six, but neither ever addresses the
window. So a bridge that acknowledged a window cycle **before** DDR had
answered it --- which strobes MD before the word is there, and gives a machine
that writes the screen correctly and reads it back black --- had nothing
looking at it, where the same bug at main memory's base is caught twice.

So after the trace the run builds a second machine and drives window cycles at
it directly, with a modeled DDR 37 ticks behind every request. It is held to a
property and not to muir, because muir's TV has no DDR behind it to be late:
**a word written into the window is the word read back out of it, at the
display's base, however long the memory takes.** Twelve cycles to the window:

- a word written and read back at the window's first word, at the last word of
  the picture (23,111 --- 768 x 963 bits at one bit a pixel is 23,112 words of
  the 32,768), at the first word past the picture, and at the last word of the
  window;
- the reads taken in the reverse order of the writes, so a read giving the word
  before it cannot come back right, and every word a read is held to is
  required to be non-zero and different from the word before;
- a word of the window the program never wrote, which must come back as the
  modeled DDR's poison rather than as zero --- a bridge answering out of its
  own idea of an unwritten word passes a check that only ever reads words it
  has written;
- one offset written twice and read back, so a bridge that kept the word it
  gave last time cannot pass;
- one word above the window and one below it, which nothing answers: the NXM
  timer ends both, MD is zero, and neither reaches the port at all;
- and the window's first word once more at the end.

Every window cycle's byte address is asserted at the port against
`DISPLAY_BASE + 4 * offset`, the port is required to hold the address and the
direction still for the whole of the memory's wait, and the run fails if one of
them lands in main memory's region instead.


**What neither configuration can hold to.** They cannot hold the frame
buffer's timing on the board *against muir*, where DDR answers in its own time, which is main memory's
parting, inherited --- configuration B holds the window's read-back against a
memory that takes time, but the instant the answer lands is then the memory's
and not the reference's. It cannot hold the gate between `tv_intr` and the processor's
`sintr_o`, for want of a program that enables the DISPLAY's interrupt. The
disk's half of the same gate is held by `disk.pass` and `machine.pass` since
`f8c6d25`. And it cannot say what the boot PROM and the band would show.
`build/machine.pass` is unchanged, the PROM never addressing the display, and
`microcycle_sys` drives the processor alone from its trace and is unaffected by
the band's run-light writes.

## The mutations

Thirty-four records are aimed at `tv` in `mutations/list.txt`, and each is
caught on a line of its own.

**The register face and the window**, which were the slice's: the enable
ignored (the first preset, which comes with the enable off), the window's
base a word off and the window's select dropped in the path (the first
frame-buffer write, at the port), a bit lane of the bitmap swapped (the same
write, the word), the acknowledgment a tick late (the first write,
-MEMACK), the preset gated on the enable, the write unable to clear the
flag, **the preset beating the write (the sixteenth preset and nowhere
earlier --- the yardstick for the trace's length)**, init not clearing the
flag, init clearing the mode register, the clock-mode bits crossed, register
1 reading the wrong half of the PROM's range, the sync RAM read from the
wrong half (the read alone, because a bijection on both is an equivalence),
the control words answering their dead neighbors, the window half its size,
the store repeating while the request stands (visible only at the write that
lands one tick before a preset, where a repeated store overrides it),
frame-buffer reads taken from the main base, and the register word not
selected in the path.

**And the sync generator**, which is this slice's: an instruction a tick long
and a tick short, the slow clock modes run at the fast rate, the flag preset
at the End of Program rather than at `-TVMA CLR`, `VSYNC` and `HSYNC`
swapped, the clock mode not restarting the program, a RAM write not
restarting it, the enable's restart inverted, the repeat count executed as an
instruction, the loop running one instruction too far, End of Program treated
as End of Loop, and a zero repeat count read as one rather than 256. Each
names a sentence of `lmtv.order`, and between them they hold the whole of
what that document says the program does.

**Five of the thirty-four went from caught to surviving when the reference
moved, and the trace was what had to change.** `tv-preset-beats-the-write`,
`tv-store-repeats-while-the-request-stands` and the two instruction-length
records all rested on the flag being preset at the frame boundary; with the
preset 16,000 ns into a run instead, the stores that used to land on it
landed nowhere in particular and the clock-mode-3 stretch had no interrupt
enabled to show its slower rate.
`tv-a-sync-ram-write-does-not-restart-the-program` survived because the
restart it tests was undone by two more restarts a few cycles later, before
anything looked. **The fix was the stimulus in every case and never the
mutation**, which is this project's own rule: the presets
are computed from a pinned origin now, the mode-3 stretch keeps `MODE INTR
ENB` standing so that its `-TVMA CLR` shows on `-XBUS.INTR`, and the RAM
write is followed by a wait long enough for the restarted program's first
preset to arrive.

**Four of the thirty-four are the window READ**, which is the half of the
display nothing outside this check exercises: a run light is a blind write,
while a character is drawn by `BITBLT-INNER-4` and `XTVCHO3`, which read the
frame-buffer word back, merge the glyph's bits into it and write it again. So a
display that could be written and not read would paint the microcode's run
lights and never a character. The four are `tv-display-answers-a-window-read`
(the display board driving MEM<31:0> for the window as well as for a control
word, so that the mux in `cadr_memory_path.sv` gives a control word where the
screen should be), `tv-window-read-ignores-the-word-ddr-returned` (the bridge
never taking DDR's word for a window read, so the screen reads back black),
`tv-window-base-a-page-off`, and `tv-window-answered-before-ddr-does`. The
first three are caught by the trace: the first two at the first read-back of
the window, which is the last word of the buffer, and the third at the port
on the first window write. (The ticks those fall at were quoted here and are
not any more: the trace's own instants moved when the sync program landed,
and a number nobody has re-measured is worse than none.) **The fourth is
caught by configuration B and by nothing else, measured:** with it applied
the trace prints its own `ok` and configuration B fails on all seven of its
reads, each reading back zero. That is the record that configuration B
exists for.

One of them was an equivalence first and a finding second.
`tv-answers-its-neighbours` was written as a wider match *gated by `sel`* and
it survived. `sel` is the decode's `device`, exhaustively checked false at
the four dead words, so a slave that honors it cannot answer an empty
address however wide its own match. The decode masks the bug by
construction on the NXM side, and the only other thing inside `device` is
the disk's four registers, which this DUT does not have. What a slave on
the seam *can* do is ignore `sel`, as a board on the real backplane has no
such wire, and `cadr_machine.sv` already says nothing can enforce that
discipline for a slave it cannot see. The record is that slave now, and is
caught on the first dead-word read. The measurement is in the record's note
so that nobody files the gated form as a hole.

Five existing records moved when the bridge took a second base and were
re-aimed with a note saying so: `bridge-writes-the-address-instead-of-the-data`,
`bridge-drops-an-address-bit`, `bridge-answers-at-an-address-nothing-is-at`,
`the-read-address-is-rotated`, `the-write-carries-the-address-mixed-into-the-word`.

## The fit

This is the board flow, `boards/arty-z7-20/vivado/bitstream.tcl`, under Vivado 2026.1, in
both configurations and in isolated copies of two trees. The trees are HEAD at
`15975ae` and this slice on top of it. That HEAD's RTL is `a899799`'s, and its
figures reproduce that commit message's exactly, so the flow is deterministic.

**Every figure in this section was measured at a 5 ns tick**, which is what
this fabric ran at until 2026-09-11. The tick is 10 ns now and both boards
close; the last paragraph of the section says so with the numbers. The
analysis is kept as it was taken, because a path's logic levels and its share
of routing do not move when the clock does.

                            memory off (DDR=0)          memory on (DDR=1)
                            15975ae     +display        15975ae     +display
    worst negative slack    -0.019      -0.006          -0.133      -0.462 ns
    failing endpoints       2 / 16,186  1 / 16,311      42 / 26,124 278 / 26,209
    total negative slack    -0.020      -0.006          -3.466      -35.278 ns
    hold                    met         met             met         met
    LUTs (cells)            3,043       3,097           6,617       6,693
    registers               1,503       1,547           4,600       4,618
    block RAM tiles         37          38              37          38

The display cost 54 LUTs, 44 registers and one block RAM tile on either board
at that slice, before the sync generator. That tile is the sync program RAM,
4K by 8, a RAMB36, and it is still one tile with the generator reading it: see
the last paragraph of this section.

**The memory-off board is where it was.** Its one failing endpoint is the
same family as before, the phase generator's TPCLK into the control
store's write address (`tpclk_reg/C -> imem_reg_23/ADDRBWRADDR[5]`, 4.24 ns
over three LUTs, 80% of it routing). It is six picoseconds short where it was
nineteen. In plain words, the write pulse for the control store has to
cross the chip to forty-some memory blocks inside one tick, and it arrives
a hair late to one of them, as it did before.

**The memory-on board came out worse, and not by the display's doing.**
Asked of the routed checkpoint, the 278 failing endpoints are these: 107 the
same control-store write address, 17 the disk's access-time adder
(`acc_d20/CLK -> acc_d2_reg[*]/D`, eight levels of carry, **3.75 ns of the
5 ns spent in logic before any routing**, +0.233 ns at HEAD and -0.462 here),
21 and 13 the disk channel's `ps_w` and `blk_w` clock enables, 31 the pack
side's resets, 9 the boot PROM's address, 6 the disk's status word into
`md_held`, and the rest of the same kind. **None is in the display and none
passes through anything this slice changed.** Every path out of the
display's registers meets, the worst by +0.095 ns (`fb_reg` through the
bridge's select and -MEMACK into the processor's countdowns). Every path
into them meets by +0.260. The interrupt reaches the processor's `sintr`
register with 3.27 ns to spare. The `md_held` paths are the disk's status
word through the same four or five LUT levels they had at HEAD, 78% routing.
Meanwhile the family that WAS the memory-on board's worst, the memory
adapter's state into MD's clock enable at -0.133 on 42, meets at +0.007.

So the placer found a different solution for a design 54 LUTs and a block
RAM larger. This board had never closed at that tick, and it has several
families with next to no margin by construction, an adder whose logic alone
takes three quarters of a 5 ns tick among them. It came out a third of a
nanosecond worse where it had been within noise. **That is more than the
quarter of a nanosecond this project calls placement noise, and it is reported
as such rather than as noise.** What it is not is a path the display made or
lengthened. The checkpoint says so, and the numbers above are the
measurement. Whether the disk's adder should be given
a tick of its own is a question for the disk's owner. A display that is right
cannot be made wrong by a placer, and the checks say it is right.

**The constraint applied as written.** Both boards count their multicycle
exceptions (2 and 4) and pass `assert_multicycle_applied`. From the
checkpoint, every path OUT of the display's three held decodes asks for
5.000 ns, paths INTO them ask for 5.000 and 75.000 (the map arriving,
relaxed), and every path into the frame counter, the flag, the mode
register and the cycle's latch asks for 5.000. Those are one tick and fifteen
ticks, so at the 10 ns tick built today the same requirements read 10.000 and
150.000; the assertion matches the string it is handed by
`boards/arty-z7-20/vivado/tick.tcl` and so moved with the tick.
`rtl/plumbing/xilinx7/cadr_machine.xdc`'s new clause did exactly what its
comment says.

**Both boards close at the 10 ns tick.** On 2026-09-11 timing closure stopped
being something to chase and the MMCM's 1000 MHz VCO was divided by 10 rather
than 5 --- one parameter in
`boards/arty-z7-20/cadr_arty.sv`, nothing under `rtl/`. It went to 6.25 first
and to 10 the same afternoon, when a one-character change to a multiplexer
cost a third of a nanosecond and the memory-on board stopped closing again.
Measured at `822535c`, the whole design reads **+1.537 ns** with memory off
and **+0.657 ns** with `DDR=1`, **zero failing endpoints on either**, which is
the largest margin any build of this design has had. The display's paths were
never the question and they are further from it now; the adder that took three
quarters of a tick takes three eighths of one.

**And the sync generator costs no block RAM at all.** Both halves of this
were measured, `DDR=1 HDMI=1` on the Arty Z7-20 and `DDR=1` on the Cora
Z7-07S. The before column is the same tree with the sync generator taken out
and nothing else changed, so the difference is this one piece of work rather
than a placer's mood:

                        Arty Z7-20            Cora Z7-07S
                        before    after       before    after
    worst slack         +0.484    +0.236 ns   +0.739    +0.452 ns
    Slice LUTs          13,907    14,067      12,411    12,551
    slices               5,582     5,470       4,059     4,110
    slice registers     11,346    11,415       9,129     9,198
    block RAM tiles       41.5      41.5        41.5      41.5

So the generator is 160 Slice LUTs on the Arty and 140 on the Cora, 69
registers on either, and **not one block RAM**. The registers are the
sequencer's own state: the program address, the loop's first and last word,
the repeat count, the instruction timer and the two sync bits. The sync
program RAM was already a RAMB36 and stayed one when it grew a second read
port, which is what a true dual port is; MIT's 512-word PROM went into LUTs.

The slice count fell on the Arty while its LUT count rose, which is packing
and not a saving; read the LUT figure. Both boards still meet timing, and
both slacks moved down by about a quarter of a nanosecond, which is the
placement noise this project has measured twice --- so the direction is
believable and the last digit is not.

**The Cora is the board to watch**: it is at 93.4% of its slices and 83.0%
of its block RAM, and the binding one did not move.

## Which board

`--tv-board` is muir's flag and the fabric takes the same word. muir has one
display model and the flag says which board it is playing; `cadr_tv.sv` is the
same, and `board_lispm` is that flag.

The two boards differ in one bit a bus cycle can see. Mode bit 7 is `SYNC PROM
ENB`. On the LISPM TV the read buffer, the 74LS244 at XBCTL 0F11, takes it
from pin 19 of the 74LS273 at TVINC 0A07, which is register 3's bit 7 and so
the sync enable. On the SIMPLE TV the same pin is ground. ECO 2 of
`cadrtv/lmtv.eco`, 18 June 1980, is why: "new window system not initializing
tv properly at original power-up; on old TV boards the check if TV is in PROM
mode (extant only on new TV boards) reads an unused input". Nothing else on
either board is different where a bus cycle can reach it.

The setting is the console face's page 2 word 33, and the disk pack program's
init script writes it at boot from `fpgarc`'s `--tv-board`, before the drive
comes present. A card that says nothing is a SIMPLE TV, which is muir's own
default and the machine every reference trace here was taken on.

`build/tv.pass` runs the same program twice, once a board: `tv.golden` and
`tv_lispm.golden` are generated from muir with the matching `--tv-board`, and
the testbench straps the fabric from each trace's own header. The two traces
are byte-identical but for 96 rows, which are six reads of the mode register
with the sync RAM selected, and every value that moves moves by `0o200`. Two
mutations hold the strap, one in each direction, because either alone is
caught by one trace and survives the other.

## The second display board

`cadrtv/lmtv.order` says it in one line: "Note: For the normal TV, x is 6.
For the color TV, x is 5." The board is a LISPM TV strapped to `tv::COLOR_TV`
--- the frame buffer at `0o17200000` and the eight control words at
`0o17377750` --- with a color monitor on it. `sys/window/color.lisp`'s
`COLOR:MAKE-SCREEN` draws 576 by 454 at four bits a pixel there, 72 words a
line, each pixel an address into the sixteen colors the color map holds.

It is a second instance of `cadr_tv.sv` at the other strap, and it is a LISPM
TV whatever the first board is, because `Tv::color` is one.

**The picture is four bits a pixel and there is no eight-bit mode.** A pixel
is a four-bit address into sixteen map entries, and each entry holds three
eight-bit channels, so the eight is the depth of a gun and not of a pixel.
MIT's own software settles it: `COLOR:MAKE-SCREEN` declares the screen
`:BITS-PER-PIXEL 4`, `%COLOR-TRANSFORM` in `sys/ucadr/uc-hacks.lisp` accepts
only `ART-4B` arrays and traps on anything else, and `lmtv.order` says of the
map that "we only use a 16x8 subset of it". muir has the same three constants
--- `COLOR_BITS_PER_PIXEL`, `COLORS` and `CHANNELS` --- and nothing on either
side implements a second depth.

**A machine with no color board must give the NXM at those addresses.**
`COLOR-EXISTS-P` is how System 100 finds out whether it has one: it writes
into the first buffer word with the error stop off and reads it back. So the
board is off by default. `--color-tv` in `fpgarc` fits it, through the same
console word and the same init step as `--tv-board`, and `busint::decode_with`
is muir's own name for the same fact. The decode takes it and so does the
instance's own `fitted`, which is two places on purpose: a board on a
backplane decodes its own address and the interface decides for itself whether
anything answered.

**The color map is kept.** Register 4 is write only on the Xbus --- the RAMs
and their converters are off the board --- so no bus cycle can read an entry
back. muir keeps the sixteen entries all the same, because a four-bit pixel is
an address into them and whatever draws the screen has to know what a color
is. The fabric keeps them too, on both boards as muir does and as both boards'
netlists strobe them, and offers them to Linux on the console face's pages 4
and 5, read only. `cadr-terminal --color-terminal` renders the color screen
through page 5 and `cadr-checkpoint` carries page 4 into the checkpoint.

**The second frame buffer is a second window of the display's region of DDR**,
128 KB above the first, which is the first board's own 32,768 words.
`cadr_ddr_map.sv`'s `COLOR_DISPLAY_BASE` is the constant. Nothing on the Linux
side grows for it: the reserved-memory node already reserves the whole 128 MB.

**`-XBUS.INTR` is the OR of the two boards**, which is muir's
`Machine::xbus_interrupt`. Microcode 323's `INTRX0` clears the flag by reading
and writing the first board's register alone, so a color-board interrupt has
nothing to take it and MIT's software never enables one; the line is joined
because the backplane joins it.

`build/color_tv.pass` is the check: `golden/src/color_tv.rs` drives muir's
`Tv::color()` beside its `Tv` through `busint::Busint`, both boards' registers
and both windows on one backplane, and the testbench compares every tick,
reads the fabric's own map port against the map muir holds, and then runs a
second configuration with `color_tv` down where every color address must
give the NXM with MD zero while the first board goes on answering.

**`LMTV` is a top-level parameter and it is one.** It says whether the fabric
carries the slot at all, which is a board's decision taken at synthesis; the
console word says whether a MACHINE has the board. With `LMTV=0` the second
instance is not elaborated and the color addresses give the NXM whatever the
console asks for. It is on by default on all three boards. The Cora Z7-07S is
the one where the question is live: with the board fitted it routes and closes
at +0.411 ns and 97.7% of its slices, built from a clean tree at `d3d6a19`,
which fits and leaves almost nothing.

**What silicon has shown.** On a Zynq board the console fits and unfits the
color board while the machine runs, and MIT's own `COLOR-EXISTS-P` body, typed
at a Lisp Listener out of the four primitives the System 304 band has, answers
`NIL` before and `T` after --- the console's register face and a bus cycle at
`0o17200000` agreeing across a backplane they share and nothing else. The map
reads sixteen black entries for either board and the color screen serves black
over unwritten memory, so nothing has drawn a picture on this board yet.
`docs/board.md` has that session.

## What is not built

- **The display output.** Nothing drives a monitor: there is no raster, no
  HDMI, no reading of the buffer out of DDR. That block is last and is not this
  slice's. What this slice leaves it is a bitmap at a known place in DDR,
  one bit a pixel, 24 words a line, 963 lines, with `BOW` in the mode register
  saying which way up the bits are. Its own frame comes from its video mode
  and not from the machine's sync program; the two are unrelated.
- **Video timing.** There is no raster: no dot is fetched, no shift register
  is loaded and no monitor is driven. What the sync program produces here is
  its two sync bits, its `-TVMA CLR` and its rate, which is everything the
  Xbus face can see. `rtl/plumbing/cadr_display_out.sv` drives a monitor from
  a mode of its own and reads none of this.
- **The video cycles.** An instruction of the sync program names a Video
  Buffer Cycle Type --- processor, refresh, normal video or end-of-line ---
  and a normal video cycle loads 64 bits of the buffer into a shift register
  and advances `TVMA`. There is no `TVMA` here: the picture is in DDR and the
  window is a bridge to it, so the fabric decodes those two bits and acts on
  neither. That is also why register 3's vertical spacing has no register.
- **The disk's interrupt joined `-XBUS.INTR` at `f8c6d25`**, after the board
  spun for ever in `AWAIT-DISK` waiting for it, and the machine's `sintr`
  became an output rather than something a board outside the fabric
  supplies. See the paragraph above.
- **The I/O board.** It is the other slave on the seam and the Unibus's
  business.
- **The color board's picture on HDMI.** `cadr_display_out.sv` scans the
  first board's window and nothing else. The plan on record is both screens
  side by side on the one output, which needs a mode wider than the 1280x1024
  driven today; nothing is built for it.
- **The color board's own sync program is run and its raster is not**, which
  is the first board's position exactly. What a color cycle would fetch, and
  what the off-board map's converters make of a stored byte, are outside the
  Xbus face either way.
