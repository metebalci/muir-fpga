<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The display controller

The TV --- MIT's name for the CADR's black-and-white display controller, the
SIMPLE TV of `cadrtv/`, what the window system asks for by `'(:VIDEO
:BLACK-AND-WHITE :CONTROLLER :SIMPLE)` --- as an Xbus device in the fabric,
checked against muir. Written at the slice, muir at `dad7249`, so read that
on anything below which says what does or does not exist. Same shape as
`docs/disk-controller.md`: what muir says the board is, what the two
reference programs actually ask of it, the decisions, what the check holds
to and cannot, and what is deliberately not built.

## What muir says the TV is

`src/simpletv.rs`, whose header names three sources and says they agree:
`sys/window/shwarm.lisp` in the System 100 release (the software that writes
to this device), `cadrtv/lmtv.order` (MIT's programming specification for
the board), and `data/SIMPLETV.netlist` through `tools/simpletv-netlist.sh`
(the board itself, all 29 SUDS pages). What follows is that file, line by
line.

- **A frame buffer of 32,768 words at `0o17000000`** (`BUFFER`, line 39;
  `BUFFER_WORDS`, line 43): `MAIN-SCREEN-BUFFER-ADDRESS` is
  `IO-SPACE-VIRTUAL-ADDRESS`, the base of Xbus I/O space, and
  `MAIN-SCREEN-BUFFER-LENGTH` is `#o100000`. One bit a pixel, 768 across, 24
  words to a line, 963 lines (`WIDTH`, `HEIGHT`, `WORDS_PER_LINE`, lines
  65--73): the screen uses 23,112 of the 32,768 words.
- **Eight control words at `0o17377760`** (`CONTROL`, line 49;
  `CONTROL_WORDS`, line 62): `MAIN-SCREEN-CONTROL-ADDRESS #o377760` as an
  I/O offset, physical being that plus `BUFFER`. `lmtv.order` runs them
  `173777x0` to `x7`; the 74S138 at NXBCTL 0F13 decodes eight and its top
  three outputs go nowhere, so words 4 to 7 "respond but don't do
  anything". The four words above them, `0o17377770`--`3`, are between the
  display's registers and the disk controller's and answer to nothing.
- **Register 0 is the mode register**, four writable bits (`mode::WRITABLE`,
  line 106): `CLOCK MODE<1:0>` (line 95), `MODE BOW` (line 100, "display one
  bits as black and zeros as white") and `MODE INTR ENB` (line 102). They
  are the Am25LS2519 at NXBCTL 0F12 --- muir's note at `mod mode` says MIT
  drew this page twice, a 74S174 in 1979 and the 2519 in 1980, and the
  netlist is the newer sheet. Bits 5 to 7 (`VSYNC`, `HSYNC`, `SYNC PROM
  ENB`, lines 120--133) are read-only and, on this board, read zero: ECO 2
  of `lmtv.eco` grounds bit 7's buffer input so the window system can tell
  old boards from new, and muir models no sync generator.
- **Bit 4 is the vertical flag, a flop of its own** (`mode::VERT`, line 118):
  the 74LS74 at NXBCTL 0E14, **preset by `-TVMA CLR`**, the sync program's
  start of frame --- "this is set by TVMA CLR, not by the start of Vertical
  Sync" --- **and clocked by `-LOAD MODE` with `XDI 4` as its data**, so a
  write of the register puts the written bit 4 into it. Microcode 323's
  `INTRX0` takes the interrupt by reading the register, testing this bit and
  writing it back with the bit cleared. `vert_flag(ns)` (line 328) is
  `flag_written || ns / FRAME_NS > written_at / FRAME_NS`: what the last
  write put in, or set if a frame has started *strictly* since.
- **`SEND INTR` is the flag with the enable**, the 74S08 at 0D10, onto
  `-XBUS.INTR` (`interrupt`, line 335). `machine.rs:429` ORs it with the
  disk's request as `XBUS INTR IN`, and `rtl.rs:1928` registers that as
  `SINTR` at the microcycle edge --- the `sintr` column of both processor
  traces.
- **The frame is `FRAME_NS` = 15,456,000 ns** (line 145): 966 lines of
  16.000 us, measured on the netlist board in `tests/simpletv_netlist.rs`
  and `tests/monitor.rs`, 64.7 Hz, "the roughly-60-cycle clock". muir
  keeps the flag "on a frame clock rather than a raster", frames counted
  from power-on, and says so as a knowing departure from the machine.
- **Registers 1 to 3 are the sync program RAM** (`SyncRam`, line 183): the
  eight 2147s at NSYRAM, 4K by 1 each, addressed by a twelve-bit pointer.
  Register 1 is the data at the pointer, read and written; 2 the pointer,
  write only; 3 the enable in bit 7 over the vertical spacing in 6--0, write
  only. With the enable clear the 74S472 PROM is selected instead and a
  read of register 1 is the PROM's word, zero on this path. **The program
  in the RAM is stored and read back, never run** --- `SI:SETUP-CPT` loads
  it at every `LISP-REINITIALIZE` and reads it back, and that is what is
  modelled.
- **`-XBUS INIT` clears the flag and nothing else** (`xbus_init`, line 398,
  and its long note): `-RESET` reaches pin 13 of the 74LS74 alone. The mode
  register and the sync enable clear on `-POWER RESET`, a backplane wire
  the processor raises only at power-on; where `lmtv.order` has the enable
  "cleared by Xbus reset" the drawing has it on the power reset, and muir
  follows the drawing.
- **The device answers in no time of its own**: `busint::decode` calls both
  ranges `Responder::Device` and `IDEAL_DEVICE_NS` is 0, so a read
  acknowledges 140 ns after the grant (80 of setup and the 60 ns deskew tap
  of the TD100 at REQLM 0C09) and a write at 80 --- exactly as the disk
  controller's registers do.

That is a reference with time in it at exactly one place, the frame, and
with a structure the fabric can mirror: three registers, a RAM, a flop with
three sources, a counter. It was traceable, and it was traced.

## What the two reference programs ask of it

Measured with a throwaway probe against muir's `rtl` engine, the
`simpletv` fields read after the run.

**MIT's boot PROM, 600,000 microcycles: nothing.** No cycle reaches either
range; the mode register is 0, the sync RAM empty, the buffer all zero,
and `SimpleTv::interrupt` is false on every row.

**The System 100 band, 2,200,000 microcycles: the frame buffer and nothing
else.** The mode register stays 0 and the sync RAM empty for the whole run
--- `tests/vertical.rs` says why: the cold boot's `(LISP-REINITIALIZE NIL)`
skips the `SETUP-CPT` block, so the interrupt is never enabled and the
microcode's `60CYC` never runs until somebody types `(si:setup-cpt)`. But
from microcycle 1,422,272 the band **does write the frame buffer**: the
microcode's run lights, words `0o51763` and `0o51765` at the bottom of the
screen, written all ones and cleared again around every disk transfer ---
917 changes of those two words over the run. The `sintr` column's 17,185
rows are all the disk's, as CLAUDE.md records.

So the band reaches a handful of words of one value in the window and
nothing of the register face, the flag or the interrupt. **A check driven by
either program would test nothing**, and the generated program is the only
reference --- the same conclusion `docs/disk-controller.md` reached for the
disk, for the same reason.

## The decisions

**The frame buffer is DDR, through main memory's bridge at a second base.**
`rtl/plumbing/cadr_ddr_map.sv` has reserved 8 MB at `0x1C00_0000` for the display
since before anything filled it; the machine's 32,768 words are the first
128 KB of it, `display_byte_address(offset) = DISPLAY_BASE + 4 * offset`.
`rtl/machine/cadr_tv.sv` decodes the window as the board's MAPADR switch does and
says so on `fb_sel`, held; `cadr_memory_path.sv` selects `cadr_xbus_ddr`
on it beside `is_memory`, and the bridge takes a `display` input that picks
the base --- a mux on the address alone, in the 80 ns the bus gives the
address. **One bridge and not a second master**, argued from the timing:
muir's TV answers a buffer word in 0 ns of its own and the bridge answers
when DDR answers, so the composed machine waits on the frame buffer exactly
as it already waits on main memory, and a second master on the same port
would wait the same and add an arbiter. The Xbus has one master a cycle;
the disk's channel reaches main memory alone and never the window, so the
bridge is idle whenever the window is asked. In `build/tv.pass` the
modelled DDR answers at once and the acknowledgement lands where muir's
does, tick for tick. On the board it lands when DDR does, which is the
parting main memory already has and the display inherits.

**The register face lives inside `cadr_memory_path.sv`, not beside the disk
in `cadr_machine.sv`.** Half of the board is that module's business ---
the select into the bridge is made there --- and putting the other half
with it makes the display one module with one held decode, and makes the
check's DUT the path itself rather than a harness of it: `tb/cadr_tv_tb.cpp`
drives `cadr_memory_path` and the wiring under test is the wiring on the
board. It hangs on the same seam the disk does, `sel` being the held
`device`, and decodes its own two ranges out of `phys` as a board on the
backplane does; the decode module is untouched and still checked over all
4,194,304 addresses.

**The store lands one tick after `-XBUS.RQ` rises, and the reference says
so.** muir's `Rtl` hands a written word to the slave at `answered_at`, the
request's own instant; a register in fabric takes it at the edge after the
request is first seen, and on the board the 2519 clocks on `-LOAD MODE`, a
gate or two behind `XBUS RQ`. `golden/src/tv.rs` therefore writes muir's
model at `answered_at + 5` and the testbench compares `-XBUS.INTR` at every
tick to it, so the tick is a stated instant rather than a tolerance. It is
the disk's `STORE_HOLD_NS`, one tick instead of two because nothing here
decodes a START: the store's decision is one AND of the held match,
`-XBUS.RQ`, the direction and the cycle's latch.

**A read is made at `answered_at`, and the trace refuses one the fabric
would answer differently.** The fabric's MD takes the lines at the deskew
tap twelve ticks after the request, where muir reads the register at the
request; the one thing that can move in between is the flag at a frame
boundary. The board reads the flop live through the 74LS244 at 0F11, so
where the two differ the fabric is the board and muir samples early ---
the generator asserts no mode-register read straddles a boundary, and
none does. Recorded here so nobody widens a tolerance for it.

**Priority at one clock edge: `-XBUS INIT`, then the write, then the
preset.** A write landing on the very tick a frame begins keeps the written
bit, because `vert_flag` asks for a frame *strictly* since `written_at`.
Reaching that tick needs the grant edge, the 80 ns setup and the landing
tick to sum to a frame boundary; a frame is 3,091,200 ticks, which is 3 mod
29, so the first boundary a store can land on is frame 25's --- **which is
why the trace is twenty-five frames and 77 million ticks long**. Frames 6
and 15 put the landing one tick either side. `-XBUS INIT` is not tied to
the master clock and is put on a boundary and a tick either side of one
directly. Init over everything, because the 74LS74's clear is a pin.

**`-XBUS.INTR` is whole in the fabric, since `f8c6d25`.** The display's
`SEND INTR` leaves `cadr_memory_path` as `tv_intr`, the disk's request
leaves `cadr_disk_controller` as `intr`, and `cadr_machine.sv` ORs the two
into the processor as muir does in one expression, one gate before the
74S175 at LCC 3E12. **`sintr` is an output of `cadr_machine` now and not
an input** --- renamed `sintr_o` deliberately, so that a testbench line
left driving it fails to compile rather than silently working. What was
written here before, that the disk's half was computed and kept inside the
controller and that a board outside the fabric supplied the line, was true
until the board spun for ever in `AWAIT-DISK` waiting for an interrupt
that had nowhere to go. The disk's half is exercised by `disk.pass` on all
380 rows and by `machine.pass` over 600,000 microcycles; **the display's
half is still a claim nothing exercises**, since neither reference program
enables the display's interrupt, and this paragraph is where that is
written down.

**The vertical spacing has no register.** Register 3's bits 6--0 are the
74LS273's spacing for a sync generator this board does not have; muir
stores them and nothing reads them back, so lint and the fitter agree they
are not there. The enable bit is.

## What the check holds to

`build/tv.pass`: `tb/cadr_tv_tb.cpp` drives `cadr_memory_path` from
`build/tv.golden`, one row a tick wherever anything moves and every gap
stepped a tick at a time with the inputs held and every output required to
hold. 77,290,001 ticks, twenty-five frames, 247 bus cycles:

- **-MEMGRANT, -MEMACK, -LOADMD and NXM TIMEOUT against `Busint`** at every
  tick --- a control-word read acknowledged 140 ns after the grant, a write
  at 80, the dead words on the NXM timer;
- **MD at -MEMACK's rise on every answered read** against muir's model:
  the mode register with the flag in bit 4, the sync RAM's byte or its
  absence, the frame buffer's word, main memory's; 102 of them, and zero on
  the seven cycles nothing answered;
- **-XBUS.INTR against `SimpleTv::interrupt` at every tick**, sixteen
  rises and sixteen falls, from writes, from frame boundaries with the
  enable on and off, from four `-XBUS INIT` pulses, with ten boundaries
  presetting a flag already set and moving nothing;
- **the memory port**: every frame-buffer cycle at `DISPLAY_BASE` plus four
  times the offset and every main-memory cycle at `MAIN_BASE` plus four
  times the address, with the trace's word, asserted at the port on the
  tick and read back through a modelled DDR keyed by the stimulus's address
  and filled from the stimulus's word --- never the DUT's --- and poisoned
  injectively where nothing wrote;
- **the counts**: the run sees exactly the cycles of each kind, the
  interrupt edges and the inits the generator's header says it made.

The program: the face at power-on; the mode register's four bits and its
flag written and read back, with everything above bit 4 dropped; the
preset with the enable off and then on; INTRX0 at four offsets into four
frames; a frame nobody clears; the sync RAM through 31 pointers spread
over twelve bits, read back in another order, with the enable off and on
and the write-only registers reading zero; the frame buffer at eighteen
offsets across the window and its edges, one word rewritten with its
neighbours checked, and the words just outside the window timing out;
`-XBUS INIT` off a boundary, on one and a tick either side; the flag
toggled by writes alone with the enable off; a write landing a tick before,
a tick after and exactly on a boundary. Three main-memory words, so the
bridge's other base is in the same trace.

**What it cannot hold to.** The frame buffer's timing on the board, where
DDR answers in its own time --- main memory's parting, inherited. The gate
between `tv_intr` and the processor's `sintr_o`, for want of a program
that enables the DISPLAY's interrupt --- the disk's half of the same gate
is held by `disk.pass` and `machine.pass` since `f8c6d25`. And what the boot PROM and the band would show:
`build/machine.pass` is unchanged, the PROM never addressing the display;
`microcycle_sys` drives the processor alone from its trace and is
unaffected by the band's run-light writes.

## The mutations

Twenty records aimed at `tv` in `mutations/list.txt`, each caught on a
line of its own: the frame a tick long and a tick short (caught at the
first frame boundary the enable is up for), the enable ignored (the first
frame, whose preset comes with the enable off), the window's base a word
off and the window's select dropped in the path (the first frame-buffer
write, at the port), a bit lane of the bitmap swapped (the same write, the
word), the acknowledgement a tick late (the first write, -MEMACK), the
frame not presetting while enabled, the write unable to clear the flag,
**the preset beating the write (frame 25 and nowhere earlier --- the
yardstick for the trace's length)**, init not clearing the flag, init
clearing the mode register, the clock-mode bits crossed, the sync RAM
reading back without its enable, the sync RAM read from the wrong half
(the read alone, because a bijection on both is an equivalence), the
control words answering their dead neighbours, the window half its size,
the store repeating while the request stands (visible only at frame 6,
where a repeated store overrides the preset one tick later), frame-buffer
reads taken from the main base, and the register word not selected in the
path.

One of the twenty was an equivalence first and a finding second.
`tv-answers-its-neighbours` was written as a wider match *gated by `sel`*
and survived: `sel` is the decode's `device`, exhaustively checked false at
the four dead words, so a slave that honours it cannot answer an empty
address however wide its own match --- the decode masks the bug by
construction on the NXM side, and the only other thing inside `device` is
the disk's four registers, which this DUT does not have. What a slave on
the seam *can* do is ignore `sel`, as a board on the real backplane has no
such wire, and `cadr_machine.sv` already says nothing can enforce that
discipline for a slave it cannot see; the record is that slave now, and is
caught on the first dead-word read. The measurement is in the record's note
so that nobody files the gated form as a hole.

Five existing records moved when the bridge took a second base and were
re-aimed with a note saying so: `bridge-writes-the-address-instead-of-the-data`,
`bridge-drops-an-address-bit`, `bridge-answers-at-an-address-nothing-is-at`,
`the-read-address-is-rotated`, `the-write-carries-the-address-mixed-into-the-word`.

## The fit

Board flow, `boards/arty-z7-20/vivado/bitstream.tcl`, Vivado 2026.1, both configurations,
in isolated copies of two trees: HEAD at `15975ae` --- whose RTL is
`a899799`'s, and whose figures reproduce that commit message's exactly, so
the flow is deterministic --- and this slice on top of it.

                            memory off (DDR=0)          memory on (DDR=1)
                            15975ae     +display        15975ae     +display
    worst negative slack    -0.019      -0.006          -0.133      -0.462 ns
    failing endpoints       2 / 16,186  1 / 16,311      42 / 26,124 278 / 26,209
    total negative slack    -0.020      -0.006          -3.466      -35.278 ns
    hold                    met         met             met         met
    LUTs (cells)            3,043       3,097           6,617       6,693
    registers               1,503       1,547           4,600       4,618
    block RAM tiles         37          38              37          38

The display costs 54 LUTs, 44 registers and one block RAM tile --- the sync
program RAM, 4K by 8, a RAMB36 --- on either board.

**The memory-off board is where it was**: its one failing endpoint is the
same family as before, the phase generator's TPCLK into the control
store's write address (`tpclk_reg/C -> imem_reg_23/ADDRBWRADDR[5]`, 4.24 ns
over three LUTs, 80% of it routing), six picoseconds short where it was
nineteen. In plain words: the write pulse for the control store has to
cross the chip to forty-some memory blocks inside one tick, and it arrives
a hair late to one of them, as it did before.

**The memory-on board came out worse, and not by the display's doing.**
Asked of the routed checkpoint, the 278 failing endpoints are: 107 the same
control-store write address, 17 the disk's access-time adder
(`acc_d20/CLK -> acc_d2_reg[*]/D`, eight levels of carry, **3.75 ns of the
5 ns spent in logic before any routing**, +0.233 ns at HEAD and -0.462 here),
21 and 13 the disk channel's `ps_w` and `blk_w` clock enables, 31 the pack
side's resets, 9 the boot PROM's address, 6 the disk's status word into
`md_held`, and the rest of the same kind. **None is in the display and none
passes through anything this slice changed**: every path out of the
display's registers meets, the worst by +0.095 ns (`fb_reg` through the
bridge's select and -MEMACK into the processor's countdowns); every path
into them meets by +0.260; the interrupt reaches the processor's `sintr`
register with 3.27 ns to spare; the `md_held` paths are the disk's status
word through the same four or five LUT levels they had at HEAD, 78% routing.
Meanwhile the family that WAS the memory-on board's worst --- the memory
adapter's state into MD's clock enable, -0.133 on 42 --- meets at +0.007.

So the placer found a different solution for a design 54 LUTs and a block
RAM larger, and a board that has never closed --- and has several families
with next to no margin by construction, an adder whose logic alone takes
three quarters of the tick among them --- came out a third of a nanosecond
worse where it had been within noise. **That is more than the quarter of a
nanosecond CLAUDE.md calls placement noise, and it is reported as such
rather than as noise.** What it is not is a path the display made or
lengthened: the checkpoint says so, and the numbers above are the
measurement. Whether the disk's adder should be given a tick of its own is
a question for the disk's owner; a display that is right cannot be made
wrong by a placer, and the checks say it is right.

**The constraint applied as written.** Both boards count their multicycle
exceptions (2 and 4) and pass `assert_multicycle_applied`; from the
checkpoint, every path OUT of the display's three held decodes asks for
5.000 ns, paths INTO them ask for 5.000 and 75.000 (the map arriving,
relaxed), and every path into the frame counter, the flag, the mode
register and the cycle's latch asks for 5.000 --- `rtl/plumbing/xilinx7/cadr_machine.xdc`'s
new clause did exactly what its comment says.

## What is not built

- **The display output.** Nothing drives a monitor: no raster, no HDMI,
  no reading of the buffer out of DDR. That block is last and is not this
  slice's; what this slice leaves it is a bitmap at a known place in DDR,
  one bit a pixel, 24 words a line, 963 lines, `BOW` in the mode register
  saying which way up the bits are, and a frame clock it can take its
  period from.
- **Video timing.** `VSYNC` and `HSYNC` never rise, as in muir; the frame
  is a counter. A display output block that runs a raster of its own would
  want the flag preset from its vertical retrace rather than from this
  counter, which is one wire's move.
- **The sync program is not run.** Registers 1 to 3 store and read back
  what `SETUP-CPT` writes, and that is all `lmtv.order` asks of a program
  on this board; the PROM's program is not loaded either, so a read of
  register 1 with the enable clear is zero, as in muir.
- **The disk's interrupt joined `-XBUS.INTR` at `f8c6d25`**, after the board
  spun for ever in `AWAIT-DISK` waiting for it, and the machine's `sintr`
  became an output rather than something a board outside the fabric
  supplies; see the paragraph above.
- **The I/O board**, which is the other slave on the seam and the Unibus's
  business.
