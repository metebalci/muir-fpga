<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The I/O board

The I/O BOARD --- MIT's own name for the card, `iob.wls` its section census
--- is the keyboard, the mouse, the two clocks and the status register they
share, on the Unibus. It also carries the serial port and the Chaosnet
interface, and those are two other slices; this document is the first three.

**`IOB` in this repository is not this card.** `IOB<47:0>` on IREG is the bus
that merges `I` with `OB` into the instruction register, and stays that.
muir's `src/ioboard.rs` makes the same distinction in its own header and this
follows it.

Written at slice one, muir at `dad7249`, so read that on anything below which
says what does or does not exist. Same shape as `docs/tv.md`: what muir says
the card is, what the two reference programs actually ask of it, the
decisions, what the check will hold to and cannot, and what is deliberately
not built.

**Slice one is the reference and the model; slice two is the card.**
`golden/src/iob.rs` writes `build/iob.golden`, `make iob-golden` makes it, and
a throwaway Python model was run against it until the two agreed row for row.
What that model found is near the end, because it is the part of slice one
worth reading before anything else. `rtl/machine/cadr_io_board.sv` and
`tb/cadr_io_board_tb.cpp` are slice two, and `make build/iob.pass` is the
check; what it holds to and what it cannot is the last section but one.

## What muir says the card is

`src/ioboard.rs`, whose header names four sources and says they agree:
`sys/ucadr/uc-cadr.lisp` in the System 100 release (the microcode that reads
it), `sys/ucadr/uc-interrupt.lisp` and `sys/io1/time.lisp` (the clocks and
their Unibus addresses), and `cadrio/iobcsr.drw`, `cadrio/iobmse.drw` and
`cadrio/iobms2.drw` in `mit/` --- the status register's and the mouse
interface's own sheets, from which `data/CADRIO.netlist` is made. What follows
is that file.

- **The block is `0o764000`--`0o764176` on the Unibus**, selected by the
  DM8136s at IOBADR 0F08 and 0F09 on `A<17:7>` and split into eight groups by
  the 74LS138 at 0E20 on `A<6:4>`, each group decoding `A<3:1>` its own way
  (`answers`). The first four groups go nowhere. `764100`--`764116` is the
  keyboard and mouse, every address answered read or written, with `764114`
  and `764116` having nothing behind them. `764120`--`764136` is the clocks
  and the GPIO, on `A<2:1>` alone --- **`A3` is not decoded, so `76413x` is
  `76412x`** --- and the microsecond counter's two halves take no write.
  `764140`--`764156` is the Chaosnet interface and `764160`--`764176` the
  serial port.
- **The keyboard is `764100` and `764102`**, the low and high halves of a
  twenty-four-bit scan code shifted in by the three 74LS164s at IOBKBD. A word
  arriving sets `KBD READY`; **a read of the LOW half clears it and a read of
  the high half does not**, the 74LS74 at IOBKBD 0B30 having `-READ.KBD.LOW`
  on its clear pin and nothing else. Microcode 323's Unibus channel reads the
  high half first (`uc-interrupt.lisp`, "needs to read the high-order word
  first"), which is why that is the way round it is. A word landing on one not
  yet read replaces it. The high half's upper byte floats.
- **The mouse is `764104` and `764106`**, Y with the three switches above it
  and X with the raw quadrature above it, twelve bits of count each off the
  74LS569s at IOBMS2 0B24--0B29. The seven lines from the mouse come through
  the 74LS14s at IOBMSE 0A25 and 0A27, are latched on `KB CLK^` into `NEW` by
  the 74LS374 at 0A24 and into `OLD` by the one at 0A22, and the 25LS2521 at
  0A21 compares them: any difference is `MOUSE STATUS CHANGE`, which sets
  `MOUSE READY`. **A read of Y clears `MOUSE READY` and a read of X does
  not**, the 74LS109 at IOBCSR 0C26 having `-READ.MOUSE.Y` on its clear.
  IOBMS2 makes each axis's step from four bits in the 74LS86s: the direction
  is `OLD A xor NEW B` and the count is enabled when exactly one line of the
  pair moved, so both moving or neither counts nothing and a mouse faster than
  the clock loses counts. `KB CLK^` is 8 us, `QC` of the 74LS163 at IOBCLK
  0D24 counting `1 USEC CLK`.
- **The beep is `764110` and has no value in it.** `-CLICK.AUDIO` is `Y4` of
  the 74LS138 at IOBKBD 0C22 and is **not gated by `-WRITE`**, so a read
  clicks as a write does; it clocks the 74LS74 at 0C27 wired as a toggle, and
  one reference is one edge of a square wave whose pitch is the rate the
  microcode references it at.
- **The status register is `764112`**, the address `uc-cadr.lisp` calls "KBD
  CSR". The 74LS244 at IOBCSR 0D29 puts eight bits on `UBO0`--`UBO7`:
  `REMOTE MOUSE ENABLE`, `MOUSE INT ENABLE`, `KBD INT ENABLE`, `CLOCK INT
  ENABLE`, `MOUSE READY`, `KBD READY`, `CLOCK READY`, `SER INT ENABLE`.
  Nothing drives `UBO8`--`UBO15`, so **the upper byte reads as ones**,
  `0o177400`. **A write can reach five bits, `0o217`**: the four flip-flops of
  the 74LS175 at 0D27 and the serial enable, which is the second half of the
  74LS74 at IOBSER 0D21. Microcode 323 tests `KBD READY` as `(BYTE-FIELD 1 5)`
  and that bit is MIT's own.
- **The microsecond clock is `764120` and `764122`**, and MIT latches it: "the
  hardware synchronizes if you read this one first". A read of the low half
  latches the whole thirty-two bits **as the counter stood at `-UB MSYN`**,
  before the edge that answers the read has counted, and the high half is that
  latch and not the counter. The counter is the 74S163 at IOBCLK 0C21 dividing
  the 32 MHz crystal; its first rising edge is 890 ns after power-on and they
  are 1,000 ns apart from there, **and no Unibus reset moves them.**
- **`764124` is two different registers.** Written it is the interval timer,
  `INTERVAL-TIMER-UNIBUS-ADDRESS`: four 74LS193s at CLKTIM loaded from
  `UBI0`--`UBI15` and counting **down** on `16 USEC CLK`, whose borrow sets
  `CLOCK READY` in the 74LS279 at 0D09; loading a new interval clears it, and
  before any load it reads set. Read it is the sixty-cycle clock, two 74393s
  at CLKTOD counting mains cycles since power-on with their clears on ground,
  through the 74LS244s under `-READ SCL`.
- **The interval timer counts down, and microcode 323 believes it counts up.**
  muir's `csr::CLOCK_READY` carries this as discrepancy 74: `iob.wlr` puts
  `16 USEC CLK` on `F21-04 CNT DW` with `F21-05 CNT UP` on `HI3` and takes
  `BORROW` up the chain, and MIT's own `doc/iob.text` agrees --- storing `n`
  "turns off clock ready CSR<6>, delays 16 x `n` microseconds, then turns
  clock ready back on" --- while `uc-interrupt.lisp` writes the two's
  complement under the comment ";Timer counts up, not down". The wire list is
  followed, which costs nothing on System 100 because that microcode is
  `INTR-OUTDEV` and nothing in the release sets `CLOCK INT ENABLE` at all.
- **`764126` is the GPIO and nothing is wired to it.** It answers and reads as
  ones.
- **Four interrupt vectors on one card, and their order is a pair of
  equations.** Page IOBINT's 74S175 at 0F14 latches `KBD/MOUSE.IREQ`,
  `SER.IREQ`, `CHAOS.IREQ` and `CLOCK.IREQ` on the grant, and the 74LS00s at
  0E12 make `V2 = (SER AND NOT CHAOS) OR CLOCK` and `V3 = CLOCK OR CHAOS`.
  So `0o260` for the keyboard and mouse, which share one, `0o264` for the
  serial port, `0o270` for the Chaosnet and `0o274` for the clock --- **and
  with more than one latched the clock is named before the Chaosnet before the
  serial port before the keyboard.** Each request is a ready bit ANDed with
  its enable, the 74LS08s at IOBKBD 0D26, and the first two are ORed by the
  74LS32 at 0D25.
- **`-UB INIT` reaches five flip-flops and the 2651, and nothing else.**
  `-INIT*` into the 8837 at IOBXCV 0F06 is `RESET`, the 2651's own reset pin,
  and `-RESET` off the 74S37 at 0E07 clears the 74LS175's four enables and the
  74LS74's serial enable. **`KBD READY`, `MOUSE READY`, the mouse counters,
  the interval timer and the microsecond counter have no pin on it and count
  on.**
- **The card answers `-UB MSYN` in its own time, and it is not one number.**
  `busint::IoBoardTiming`, a behavioural twin measured on the netlist board:
  the clocks, the GPIO and the counter's high half answer 250 ns after
  `-MSYN` through the TD250 at IOBADR 0E09; the keyboard, mouse, status and
  beep registers select through **two** stages of the microsecond clock and
  answer 250 ns after the second edge strictly past `-MSYN`, so between 1,250
  and 2,250 ns depending on where the request fell; and the counter's low
  half takes one edge and 313 ns.

## What is simulated time rather than the machine's

muir's own header says it: *"Where this is knowingly not the machine: the
clocks are driven from simulated time rather than the computer's, which makes
a run reproducible."* Concretely, four things on this card are functions of
`Machine::ns` and not of any crystal:

- the microsecond counter, `usec_at(ns)`, edges at 890 + 1,000k from power-on;
- the sixty-cycle counter, `ns / SIXTY_CYCLE_NS` with `SIXTY_CYCLE_NS` =
  1,000,000,000/60 = 16,666,666 ns, counting from power-on;
- `CLOCK READY`, which is `ns - loaded >= interval * 16,000`;
- the mouse's `KB CLK^` sampling, every 8,000 ns from power-on, and the
  mouse's own step, one quadrature phase every 16,000 ns.

**None of them is derived from the CADR's clock generator**, and on `micro`,
the engine with no clock at all, `ns` is microcycles multiplied by 145 and
these keep worse time than the board would. On `rtl` --- which is the engine
this trace is taken from, and the one the fabric is held to --- `ns` is the
machine's own nanoseconds, so a fabric counting its 200 MHz ticks agrees.

That is a reference with time in it in four places, and each of them lands on
the fabric's grid or is shown not to; the next section is that.

## What the two reference programs ask of it

Measured with a throwaway probe against muir's `rtl` engine, every microcycle
whose `VMA` translates onto this card counted.

**MIT's boot PROM, 600,000 microcycles and 17,466 bus cycles: the card is
never addressed, not once.** Its single Unibus cycle is the diagnostic block
--- the mode-register write that turns the PROM off.

**A System 100 band, 2,200,000 microcycles and 141,849 bus cycles: 271 bus
cycles on three registers and nothing else.**

    microcycle 1,410,551   read  764112   the status register, uc-cadr.lisp's (LOC 6)
    from     2,087,405     read  764120   the microsecond counter, low half   x135
    from     2,087,409     read  764122   ...and its high half, MIT's order    x135
    microcycle 2,168,062   write 764112 = 0o4   KBD INT ENABLE

That is the whole of it. The status-register read at 1,410,551 comes five
hundred microcycles after the machine leaves the boot PROM at 1,410,035 and is
the decision between a warm and a cold boot: `uc-cadr.lisp` enters at `(LOC
6)`, reads the register, and cold-boots unless the keyboard is ready and
holding something other than RUBOUT. **With nothing answering there the read
is an NXM and the machine cold-boots by accident rather than by decision** ---
which is what it does today, and is the first thing this card changes.

No mouse register, no keyboard data register, no interval timer, no beep, no
GPIO. Not one interrupt is taken: nothing types, so `KBD READY` never comes
up, and `CLOCK INT ENABLE` is never set by anything in the release.

**So a check driven by either program would test the decode, two reads and one
write.** That is the control-store-writes-zero-to-all-16,384-words shape
again, and `golden/src/iob.rs` is the only reference this card can have --- the
same conclusion `docs/tv.md` and `docs/disk-controller.md` reached, for the
same reason.

## The decisions

**The seam is the Unibus, not `-MEMRQ`.** `cadr_busint_xbus.sv` is already
held to `busint::Busint` tick for tick and already drives `-UB MSYN`,
`ub_write` and `ub_addr` and takes `-UB SSYN` back; `cadr_memory_path.sv`
computes `ub_addr` as `busint::unibus_address` and holds it beside the decode;
`cadr_spy_registers.sv` is the slave that answers today, at `0o766000`. The
I/O board is the **second slave on that seam** and its check belongs there ---
one module, one testbench, a Unibus master in the testbench replaying the
trace --- exactly as the disk controller's check lives at its four registers.
Composing it under `cadr_memory_path` is a later slice and
`busint_xbus.golden` is the trace for that.

**A slave on that seam must hold its address match and not compute it.**
CLAUDE.md records this as the disk controller's -6.195 ns: a combinational
match on `phys` carries the map's ripple into `-MEMACK`/`-LOADMD` and so into
the countdowns' clock enables. Here the address is `ub_addr`, which
`cadr_memory_path.sv` already registers with the decode, so the ripple is
already cut --- but the same rule applies to whatever this card computes from
it, and `cadr_spy_registers.sv`'s shape (a `selected` term off the registered
`ub_addr`, an `elapsed` counter from `-UB MSYN`) is the one to copy.

**The 5 ns grid, and the one place this card is not on it.** Every instant the
fabric can act at is a multiple of five nanoseconds. The microsecond clock's
edges are at 890 + 1,000k; the keyboard-and-mouse group answers 1,250 ns after
the second edge past `-MSYN`; the clocks and the GPIO answer 250 ns after
`-MSYN`; `KB CLK^` is 8,000 ns and the mouse's step 16,000; the interval
timer's count is 16,000. All multiples of five. **The microsecond counter's
low half is not**: `busint::IOB_USEC_LOW_NS` is 313 ns, measured on the
netlist, so muir answers at 1,203 + 1,000k and the fabric can only answer at
1,205. The trace carries a `slip` column saying so on every such row rather
than hiding two nanoseconds in a tolerance, and **nothing downstream sees it**:
`-LMACK` is 150 ns and the MD strobe 100 ns past `-UB SSYN`, both multiples of
five, so a bus interface counting from the tick it *sees* `-SSYN` lands where
muir's does. 208 rows of the trace carry it and no other register ever does;
the generator asserts that.

**The sixty-cycle counter is off the grid too, and it costs nothing.**
`SIXTY_CYCLE_NS` is 16,666,666, which is 1 mod 5, so the k'th mains edge is on
the grid only for k a multiple of five. A fabric that accumulates nanoseconds
by five and subtracts the period --- `disk_unit`'s spindle trick, which
CLAUDE.md already records as being exactly `now mod REVOLUTION_NS` ---
increments at the first tick at or after each edge, and the window in which it
disagrees with `ns / SIXTY_CYCLE_NS` is `[B, B + (5 - B mod 5))`, **which
contains no multiple of five at all**. So the two agree at every instant the
fabric can be looked at. A fabric that instead reloads a down-counter with
3,333,333 ticks loses a nanosecond a period, and the trace reads the register
at fourteen boundaries on alternating sides to catch it.

**Where a write lands: at `-UB SSYN`, because that is where muir puts it.**
`busint.rs`'s `Responder::Unibus` arm makes `answered` equal to `ssyn` for
every register of this card, where `Responder::Interface` --- the diagnostic
block --- lands at `REGISTER_STROBE_NS` past `-MSYN`. On the card the pulses
are earlier than that: `-LOAD INTERVAL` is `Y2` of the 74LS138 at CLK60H 0B21,
gated by `-WRITE` while `-MSYN` is up. **Nothing on the card can see the
difference** --- the only state a write starts is the interval timer, whose
counts are 16 us apart, and a status-register write preserves both ready bits
--- but the instant is a choice, and a fabric that loads the interval timer at
its own write pulse brings `CLOCK READY` up by up to 2,250 ns early against
this trace. Written here, not left to be found.

**The counter's low half is read at `-UB MSYN`, not at `-UB SSYN`.** muir's
`busint.rs` says why: "the board latches it on the way to answering, before
the edge that answers has counted", and the band's first read of it took one
less on the netlist than a count taken at the answer. Every other register is
read or written at `-SSYN`. The trace carries both instants on every row so
this is a column and not a convention.

**The serial port's ready line is an input to this card, not a 2651.** The
priority encoder on page IOBINT takes four requests and only one of them is
made here; `SER.IREQ` is the 2651's `-RxRDY` and, by ECO 10 of
`cadrio/iob.eco`, its `-TxRDY` on the same net, through the 74LS02 at IOBSER
0E11 with `SER INT ENABLE`. So `cadr_io_board.sv` takes `ser_ready` as a port,
the trace drives it with a `SER` row, and the 2651 itself is the serial
slice's. **`-UB INIT` must reach it**, because `-INIT*` is the chip's own
`RESET` pin; the trace shows `serrdy` falling at every init.

**THE MOUSE'S SEAM IS DECIDED AND IT IS MIT'S CARD: the card takes the seven
lines.** Slice one posed it as an open question and slice two answered it, at
Mete's session's direction: this project reproduces the machine and is held to
muir, and a module taking ready-made deltas is a different card --- one that
cannot lose counts, whose `NEW`/`OLD` latches and comparator disappear, and
against which this trace stops being a reference for the mouse half. So
`rtl/machine/cadr_io_board.sv` takes `mouse_lines<6:0>` and the encoder that turns
Linux's deltas into quadrature phases is fabric beside it; on this slice that
encoder is in `tb/cadr_io_board_tb.cpp`. The two shapes as they were posed,
and why the second was declined:

muir puts the encoders in `terminal::mouse` --- the far end, not the card
--- and what crosses the card's edge is seven lines: four quadrature and three
switches. A USB mouse gives deltas, and turning a delta into quadrature phases
16 us apart in software over `M_AXI_GP0` is 62,500 writes a second, so the
phase generator cannot be in `cadr-usb-input`. Two shapes, and the trace
supports either:

- **the card takes the seven lines** and something in fabric beside it turns
  Linux's deltas into phases. This is the card MIT built, and the trace's
  `MOVE` rows then belong to the testbench, which runs the encoder model;
- **the card takes deltas** and adds them to the counters directly, setting
  `MOUSE READY` on a change.

The first was taken. The encoder's contract is Gray phases in the order 00,
01, 11, 10, a step every `MOUSE_STEP_NS` = 16,000 ns, both lines of each pair
high at power-on, and **muir's snap** --- see the model's findings below,
which is where that word is explained and where the cost of getting it wrong
is measured. **A mutation cannot reach it**, because on this slice the encoder
is in the testbench; `mutations/list.txt` says so where the card's records
begin, and the two records that stand nearest it break the card's half of the
same agreement --- its 8 us clock's rate and its phase.

**The interrupt leaves the card as a vector and a request.** `-UB INTR` and
`-UB BR5` on the backplane; `machine.rs:455` ORs `interrupt_request` with
`UB_INT` into what the processor reads. Nothing in `rtl/` has a Unibus
interrupt path yet, so the card's output is a port with nothing on the other
end until somebody builds one --- which is honest, and is the same shape the
display's `tv_intr` had before `f8c6d25`.

## What the trace is

`build/iob.golden`, 100 KB, 1,532 event rows and 94 decode rows over 404.7 ms
= 80,949,318 ticks. `make iob-golden` writes it in 0.85 s, and two runs are
byte-identical: there is no wall-clock time in it and no randomness.

    DECNONE  first last                    answers() is None over this run
    DEC      uaddr write reg               answers(uaddr, write)
    CYC      n msyn ssyn slip off uaddr reg write wdata rdata  <face>
    KEY      n ns scancode                 <face>
    MOVE     n ns dx dy                    <face>
    BTN      n ns mask                     <face>
    SER      n ns ready                    <face>
    INIT     n ns                          <face>
    FACE     n ns                          <face>

    <face> = csr x y held clkrdy interval intr audio serrdy

Every row ends with the same face, sampled after whatever the row did: the
status register's flip-flops before the floating byte and `CLOCK READY` are
made up on a read, the two mouse counters, the switches as the mouse holds
them, `CLOCK READY`, the interval last loaded, the vector the card is asking
for, `AUDIO`, and the serial port's ready line. **Each is a register or a wire
on the card**, so none is a column invented for the trace.

The decode is exhaustive over all 262,144 addresses an eighteen-bit `ub_addr`
can carry, both directions: 32 runs where nothing answers and 31 addresses
that do, one row each per direction. That is 16,514 comparisons in the model's
run and it is the whole decoder.

What the program does, in order: the face at power-on and every register read
once before anything is written; eleven cycles the card does not answer, below
the block, above it, at an odd address inside it, and the two writes the clock
group refuses; the keyboard, fifteen presses whose scan codes are injective
and between them cover all twenty-four bits, with the high half read while
`KBD READY` stands and the low half clearing it; the mouse, seventeen moves in
both directions on both axes, the twelve-bit counters wrapped either way by a
single count from zero, the counters read in six successive clocks each while
they run, and all eight switch masks each read inside the very clock the latch
takes it on; the status register with all sixteen bits written, each writable
bit alone, and both ready bits standing through a write of zero; **all two
hundred phases of `-UB MSYN` inside the card's microsecond**, at a register
that waits two edges, one that waits one and one that waits none; the
microsecond counter's carry into its high half read from both sides; ten
intervals on the timer including the longest there is, held for 200 ms and
never allowed to expire; fourteen boundaries of the sixty-cycle clock;
the interrupt, every reachable vector and the priority chain taken apart one
enable at a time; three `-UB INIT` pulses; and the beep, clicked by reads and
writes alike at MIT's own half-wavelength.

## What no trace against this model can reach

Said here rather than given a column, per CLAUDE.md's rule.

- **The Chaosnet's vector, `0o270`.** `interrupt_request` consults
  `self.chaos`, which is `None` unless an interface is plugged in, and
  plugging one in drags the whole Chaosnet board into this trace. The
  priority chain is exercised clock over serial over keyboard-and-mouse; the
  Chaosnet's place in it, between the first two, is the Chaosnet slice's to
  check. **The fabric's priority encoder needs the input regardless**, and a
  card built without it will pass this check.
- **The Chaosnet and serial register groups.** `DEC` carries what the decode
  makes of them, because the decode is one sheet; no `CYC` goes near them,
  because the parts behind them are two other slices. A card that answers
  `0o764140`--`0o764176` with nothing behind it would fail on the real
  machine and passes here. **Slice two therefore made this an exemption with
  a number on it**: `rtl/machine/cadr_io_board.sv` decodes the whole block and
  answers only the two groups it implements, the check requires that it does
  not answer the other fifteen addresses, and it prints how many answering
  directions that covers --- twenty-seven of the fifty-five the decode names.
  Whoever builds either slice makes the card answer its group, with
  `busint::IOB_CHAOS_BUFFER_NS`, `IOB_RBUF_SETUP_NS` and `IOB_SERIAL_NS` for
  the instants, and moves that line.
- **The latch on the mouse's seven lines, from the lines themselves.**
  Measured at slice two, as a mutation on both mouse registers: reading
  `lines` where the card reads `NEW` survives. muir's snap puts every step of
  a move onto a `KB CLK^` edge, which is the edge the 74LS374 at IOBMSE 0A24
  takes them on, so the lines and the latch change at one instant and never
  differ where anything reads; the switches change at a `BTN` row and the
  program reads them back inside the clock the latch takes them on, which is
  after that edge. What the trace CAN tell from `NEW` is a value one clock
  **late** --- `OLD`, the 74LS374 at 0A22 --- and the module has no register
  for that: `OLD` is `NEW` a clock ago and the edge that makes it is the edge
  that uses it, so the count and the comparator are written in terms of `NEW`
  and the lines and the second latch would be a copy nothing reads. Recorded
  rather than filed as a hole, and the live records on that wiring are the
  two that cross which four of the seven lines reach which register.
- **`take_beep` and `AUDIO_QUIET_NS`.** muir's own comment says they are the
  far end's arithmetic and not the board's; the card has the 74LS74 at
  IOBKBD 0C27 and nothing else, so `AUDIO` is the column and the beep is not.
- **A cycle whose master drops `-UB MSYN` before the card answers.** The bus
  interface never does it and muir's model has no state for it.
- **`REMOTE MOUSE ENABLE`'s effect.** It is the first of the 74LS175's four
  and muir models it as a bit that reads back and does nothing; the trace
  holds it to that, which is a check that it reaches no interrupt gate and
  nothing more.
- **The keyboard's own cable.** `terminal::cable` and the 75118 at IOBKBD
  0E30 are the far end; what crosses here is a twenty-four-bit word arriving,
  which is the `KEY` row.
- **`-BOOT*`, the keyboard's boot key.** muir's `unibus.rs` says it runs to
  the processor board past the interface, which has no net for it, and
  nothing presses it.

## What the Python model found

The model is under the session's scratchpad and is thrown away; what it bought
is here. It was written the way the fabric will be --- edge driven, one
register a register, the decode from the sheets rather than from muir --- and
run against `build/iob.golden` until it agreed row for row, which it does:
1,532 event rows and 16,514 decode comparisons, no disagreement.

**It agreed on the first run, which is why the next paragraph exists.** A
model that agrees first time is either right or blind, and only a mutation
tells them apart. Twenty-nine wrong beliefs were planted in it one at a time,
each a mistake somebody could make in fabric, and **all twenty-nine are caught
by the trace**, most of them in the first hundred rows:

    kbd-ready-cleared-by-either-half              CYC row 30, csr 0 for 0o40
    mouse-ready-cleared-by-the-status-register    row 70, 177500 for 177520
    the-clock-group-decodes-a3                    row 15, 764130 for 764120
    the-keyboard-group-answers-one-edge-early     row 1, ssyn 1140 for 2140
    the-counters-low-half-is-read-at-ssyn         row 8, 15 for 14
    the-high-half-comes-from-the-counter          row 1412, 1 for 0
    the-mains-counter-reloads-not-accumulates     row 1466, 13 for 12
    the-interval-timer-is-a-tick-short            FACE row 1426, clkrdy
    the-interval-timer-counts-16-us-in-16-ns      CYC row 1423, clkrdy
    init-clears-the-keyboard                      INIT row 1515, csr
    init-reloads-the-interval-timer               INIT row 1480, clkrdy
    init-clears-the-mouse-counters                INIT row 1480, x and y
    init-leaves-the-serial-port-alone             INIT row 1515, serrdy
    the-serial-enable-is-not-writable             CYC row 789, csr 17 for 217
    the-upper-byte-does-not-float                 row 1, 100 for 177500
    the-serial-port-outranks-the-clock            CYC row 1497, 264 for 274
    the-remote-mouse-enable-reaches-a-gate        FACE row 1508, 260 for 0
    the-mouse-turns-the-other-way                 FACE row 65, x 1 for 7777
    the-mouse-counts-on-every-edge                row 5, 7777 for 0
    the-y-register-reads-the-switches-late        row 753, 6173 for 16173
    the-x-register-reads-the-lines-late           row 254, 170063 for 110063
    a-read-of-the-beep-does-not-click             CYC row 14, audio
    the-microsecond-clock-starts-a-tick-late      row 1, ssyn 2145 for 2140
    the-counters-low-half-answers-on-the-grid     row 8, slip 0 for 2
    a-write-of-the-csr-clears-the-ready-bits      CYC row 805, csr 0 for 0o60
    the-mouse-samples-at-16-us                    FACE row 65, csr and x
    the-counters-are-eleven-bits                  FACE row 65, x 3777 for 7777
    a-write-of-the-counter-is-answered            row 25, decode
    the-block-select-reaches-a-page-lower         row 24, decode

Three findings came out of that, and they are the reason the slice was worth
doing before any SystemVerilog.

**A read of the mouse's registers taken at rest cannot tell `NEW` from
`OLD`.** The first draft of the program read `764104` and `764106` only after
motion had stopped and two clocks after a switch changed, and both latches
then hold the same seven bits --- so a card putting `OLD` on `UBO12`--`UBO15`
agreed with muir on every row. The fix is to read them **while they are
moving**: six reads of the X register in six successive clocks and then six of
the Y register in six more, each placed so that `-UB SSYN` falls inside the
clock the latch last moved on. **Six of each and not six alternating**, and
that difference was measured: the mouse holds a phase for two of the card's
clocks, so the clocks the latch moves on are every other one, and an
alternating burst puts every read of a given register on one parity --- which
can be the parity where nothing moved. With the alternating burst the mistake
survived; with six in a row it is caught at row 254. The switches take the
same treatment, each mask read inside the very clock the latch takes it on,
and that one is caught at row 753.

**muir snaps the mouse's step train onto the card's clock, and a fabric that
does not is one count behind for the whole of every move.** `MouseInterface::
sample` computes each step's instant as `max(encoders.next, the previous
edge)` and steps there --- so a step whose due time has fallen behind the last
edge is dragged forward to it, and because the previous edge is a multiple of
8,000 and the step is 16,000, **every subsequent step lands exactly on an
edge.** The first two steps of a move therefore land on *consecutive* edges
and everything after on every other one. A model that instead starts the train
where the motion arrived and keeps its own phase was written and measured:
**307 face rows and 27 read-backs disagree**, the counters one behind muir's
for the length of each move and converging only at its end. That is not a
tolerance to widen; it is a contract, and whoever writes the encoder --- in
the testbench or in fabric --- reproduces it or the check is red for a reason
that has nothing to do with the card.

**One measured equivalence, recorded so nobody files it as a hole.** Widening
the block select's top from `0o764176` to `0o764200` **survives, and is
equivalent**: `(0o764200 >> 4) & 7` is 0, and the 74LS138 at IOBADR 0E20 sends
group 0 nowhere, so an address one word past the block answers nothing however
wide the DM8136s' match is. The live form of that mutation is the other
direction --- reaching a page lower, `0o763000` --- which puts `0o763776` into
group 7 and is caught at row 24 on the first cycle the card is not supposed to
answer. Same family as the equivalences CLAUDE.md already catalogues.

## What slice two built

1. **`rtl/machine/cadr_io_board.sv`**, a Unibus slave in `cadr_spy_registers.sv`'s
   shape: `clk`, `rst`, `ub_msyn`, `ub_write`, `ub_addr`, `ub_wdata` in;
   `ub_ssyn`, `ub_rdata` out; plus `ub_init`, `ser_ready`, `chaos_intr` and
   the mouse's seven lines and the keyboard's word in, and `ser_reset`, the
   interrupt request and its vector, `AUDIO` and the card's own state out.
   Inside: the decode, the answer machine off a free-running microsecond
   clock, the keyboard's word and its ready flop, the mouse's latch,
   comparator and two counters, the microsecond counter with its
   thirty-two-bit latch, the mains counter as an accumulator, the interval
   timer, the status register and the priority encoder.
2. **`tb/cadr_io_board_tb.cpp`**, a Unibus master replaying `iob.golden` tick
   for tick, and the mouse's encoders with muir's snap in them, since the
   card takes the lines and not deltas.
3. **The Makefile's `iob.pass`**, in `check`.
4. **Twenty-five mutation records** and the runner's `iob` entry.

**Two things the card's own state made the module say out loud.**

**The match is held and not computed**, which is the disk controller's
-6.195 ns lesson at the second slave on this seam. It costs nothing here and
the module says why at the register: the earliest answer the card can give is
fifty ticks after `-UB MSYN`, so a match a tick behind the strobe is a match
forty-nine ticks early. The reference trace is a master with **no address
setup at all** --- `-UB MSYN` and the address arrive on the same nanosecond,
and two cycles running back to back have the next `-MSYN` at the instant the
last one dropped --- so a card that needed the address at the strobe would
have had to compute it.

**And the sixty-cycle accumulator was the module's only timing problem.**
Written the obvious way --- `mains_acc + 5 >= SIXTY_CYCLE_NS`, and then that
sum less the period --- it puts an adder, a 24-bit compare and a subtraction
in series on the accumulator's own data pins: eleven logic levels and
**-0.702 ns** out of context, measured, the worst path in the module by a
mile and the only one that missed. The remedy is the one
`cadr_disk_controller.sv` already uses for its spindle and
`cadr_phase_gen.sv` for its taps: compare a tick early into a register, and
make the two candidates adders in parallel with the mux after them. The check
passes byte-identically either way, which is what says the transformation is
exact.

**Two placement rules, because a zero-time trace does not replay on a clocked
fabric.** 177 pairs of rows share an instant. `-UB MSYN` drops one tick early,
at `off - 5`, so the bus is idle for a tick before the next cycle; and a row
whose action changes something the face shows --- a press, the serial port's
ready line, `-UB INIT` --- is pushed one tick when it would otherwise land on
the tick the previous row's face is compared at, with every row at that
instant after it pushed with it. Seven rows are pushed and the check prints
the count. A move or a switch changes nothing the card shows until its next
`KB CLK^`, and a cycle changes nothing on the tick its `-MSYN` rises, so
those share a tick and are not pushed.

Then, and separately: the composition under `cadr_memory_path.sv` beside
`cadr_spy_registers`, which needs the address decode in front of both slaves
and is where `busint_xbus.golden` becomes the reference again; and the Linux
side, `cadr-usb-input`, which is last in the agreed order of work.

## What is not built

- **The serial port.** `0o764160`--`0o764176`, the 2651 at IOBSER 0A12, its
  own slice and its own Linux program (`cadr-serial`). What this slice leaves
  it is a ready line into the priority encoder and a vector, `0o264`.
- **The Chaosnet interface.** `0o764140`--`0o764156`, `0o270`, its own slice.
- **The keyboard's and mouse's far end.** `cadr-usb-input`, last in the order
  of work; the kernel side is done and `evtest` printed Mete's name off a USB
  keyboard on the board on 10 Sep.
- **The Unibus interrupt cycle.** Nothing in `rtl/` puts a vector on the bus
  or arbitrates `BR5`; the card's request is a port until somebody does.
- **`-BOOT*`.** The keyboard's boot key runs to the processor board past the
  bus interface and nothing presses it, in muir or here.
