<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The I/O board

The I/O BOARD is MIT's own name for the card, and `iob.wls` is its section
census. It is the keyboard, the mouse, the two clocks and the status register
they share, on the Unibus. It also carries the serial port and the Chaosnet
interface, and those are two other slices. This document is the first three.

**`IOB` in this repository is not this card.** `IOB<47:0>` on IREG is the bus
that merges `I` with `OB` into the instruction register, and it stays that.
muir's `src/ioboard.rs` makes the same distinction in its own header, and this
follows it.

This was written at slice one, with muir at `dad7249`, so read that on anything
below which says what does or does not exist. It has the same shape as
`docs/tv.md`: what muir says the card is, what the two reference programs
actually ask of it, the decisions, what the check will hold to and cannot, and
what is deliberately not built.

**Slice one is the reference and the model. Slice two is the card. Slice
three puts the card under the machine. Slice four is the bus interface's own
Unibus registers, which is what let the card's interrupt reach the
processor.**
`golden/src/iob.rs` writes `build/iob.golden`, and `make iob-golden` makes it.
A throwaway Python model was run against it until the two agreed row for row.
What that model found is near the end, because it is the part of slice one
worth reading before anything else. `rtl/machine/cadr_io_board.sv` and
`tb/cadr_io_board_tb.cpp` are slice two, and `make build/iob.pass` is the
check. What it holds to and what it cannot is the last section but one.
Slice three is the composition under `rtl/machine/cadr_memory_path.sv` and
`make build/unibus.pass` is its check; the section "What slice three built"
is near the end. Slice four is `golden/src/busint_regs.rs`,
`rtl/machine/cadr_busint_regs.sv` and `tb/cadr_busint_regs_tb.cpp`, with
`make build/busint_regs.pass` as its check: the interrupt block at
`0o766040`--`0o766076` and the Unibus map at `0o766140`--`0o766176`. Those
thirty-two addresses used to time out where muir answers, and the section
"The third slave, and what the sweep used to show" says what changed.

## What muir says the card is

The reference is `src/ioboard.rs`, whose header names four sources and says
they agree. They are `sys/ucadr/uc-cadr.lisp` in the System 100 release (the
microcode that reads it), `sys/ucadr/uc-interrupt.lisp` and
`sys/io1/time.lisp` (the clocks and their Unibus addresses), and
`cadrio/iobcsr.drw`, `cadrio/iobmse.drw` and `cadrio/iobms2.drw` in `mit/`.
Those last three are the status register's and the mouse interface's own
sheets, from which `data/CADRIO.netlist` is made. What follows is that file.

- **The block is `0o764000`--`0o764176` on the Unibus.** It is selected by the
  DM8136s at IOBADR 0F08 and 0F09 on `A<17:7>`, and split into eight groups by
  the 74LS138 at 0E20 on `A<6:4>`, each group decoding `A<3:1>` its own way
  (`answers`). The first four groups go nowhere. `764100`--`764116` is the
  keyboard and mouse, and every address there is answered read or written,
  with `764114` and `764116` having nothing behind them. `764120`--`764136` is
  the clocks and the GPIO, on `A<2:1>` alone. **`A3` is not decoded, so
  `76413x` is `76412x`**, and the microsecond counter's two halves take no
  write. `764140`--`764156` is the Chaosnet interface and `764160`--`764176`
  the serial port.
- **The keyboard is `764100` and `764102`**, the low and high halves of a
  twenty-four-bit scan code shifted in by the three 74LS164s at IOBKBD. A word
  arriving sets `KBD READY`. **A read of the LOW half clears it and a read of
  the high half does not**, the 74LS74 at IOBKBD 0B30 having `-READ.KBD.LOW`
  on its clear pin and nothing else. Microcode 323's Unibus channel reads the
  high half first (`uc-interrupt.lisp`, "needs to read the high-order word
  first"), which is why that is the way round it is. A word landing on one not
  yet read replaces it. The high half's upper byte floats.
- **The mouse is `764104` and `764106`**, Y with the three switches above it
  and X with the raw quadrature above it, twelve bits of count each off the
  74LS569s at IOBMS2 0B24--0B29. The seven lines from the mouse come through
  the 74LS14s at IOBMSE 0A25 and 0A27. They are latched on `KB CLK^` into
  `NEW` by the 74LS374 at 0A24 and into `OLD` by the one at 0A22, and the
  25LS2521 at 0A21 compares them. Any difference is `MOUSE STATUS CHANGE`,
  which sets `MOUSE READY`. **A read of Y clears `MOUSE READY` and a read of X
  does not**, the 74LS109 at IOBCSR 0C26 having `-READ.MOUSE.Y` on its clear.
  IOBMS2 makes each axis's step from four bits in the 74LS86s. The direction
  is `OLD A xor NEW B`, and the count is enabled when exactly one line of the
  pair moved, so both moving or neither counts nothing and a mouse faster than
  the clock loses counts. `KB CLK^` is 8 us, and it is `QC` of the 74LS163 at
  IOBCLK 0D24 counting `1 USEC CLK`.
- **The beep is `764110` and has no value in it.** `-CLICK.AUDIO` is `Y4` of
  the 74LS138 at IOBKBD 0C22 and is **not gated by `-WRITE`**, so a read
  clicks as a write does. It clocks the 74LS74 at 0C27, which is wired as a
  toggle. One reference is therefore one edge of a square wave, whose pitch is
  the rate the microcode references it at.
- **The status register is `764112`**, the address `uc-cadr.lisp` calls "KBD
  CSR". The 74LS244 at IOBCSR 0D29 puts eight bits on `UBO0`--`UBO7`:
  `REMOTE MOUSE ENABLE`, `MOUSE INT ENABLE`, `KBD INT ENABLE`, `CLOCK INT
  ENABLE`, `MOUSE READY`, `KBD READY`, `CLOCK READY` and `SER INT ENABLE`.
  Nothing drives `UBO8`--`UBO15`, so **the upper byte reads as ones**,
  `0o177400`. **A write can reach five bits, `0o217`.** They are the four
  flip-flops of the 74LS175 at 0D27 and the serial enable, which is the second
  half of the 74LS74 at IOBSER 0D21. Microcode 323 tests `KBD READY` as
  `(BYTE-FIELD 1 5)`, and that bit is MIT's own.
- **The microsecond clock is `764120` and `764122`**, and MIT latches it: "the
  hardware synchronizes if you read this one first". A read of the low half
  latches the whole thirty-two bits **as the counter stood at `-UB MSYN`**,
  before the edge that answers the read has counted, and the high half is that
  latch and not the counter. The counter is the 74S163 at IOBCLK 0C21 dividing
  the 32 MHz crystal. Its first rising edge is 890 ns after power-on and they
  are 1,000 ns apart from there, **and no Unibus reset moves them.**
- **`764124` is two different registers.** Written, it is the interval timer,
  `INTERVAL-TIMER-UNIBUS-ADDRESS`. That is four 74LS193s at CLKTIM loaded from
  `UBI0`--`UBI15` and counting **down** on `16 USEC CLK`, whose borrow sets
  `CLOCK READY` in the 74LS279 at 0D09. Loading a new interval clears it, and
  before any load it reads set. Read, it is the sixty-cycle clock, two 74393s
  at CLKTOD counting mains cycles since power-on with their clears on ground,
  through the 74LS244s under `-READ SCL`.
- **The interval timer counts down, and microcode 323 believes it counts up.**
  muir's `csr::CLOCK_READY` carries this as discrepancy 74. `iob.wlr` puts
  `16 USEC CLK` on `F21-04 CNT DW` with `F21-05 CNT UP` on `HI3` and takes
  `BORROW` up the chain, and MIT's own `doc/iob.text` agrees: storing `n`
  "turns off clock ready CSR<6>, delays 16 x `n` microseconds, then turns
  clock ready back on". But `uc-interrupt.lisp` writes the two's complement
  under the comment ";Timer counts up, not down". The wire list is followed,
  which costs nothing on System 100 because that microcode is `INTR-OUTDEV`
  and nothing in the release sets `CLOCK INT ENABLE` at all.
- **`764126` is the GPIO and nothing is wired to it.** It answers and reads as
  ones.
- **There are four interrupt vectors on one card, and their order is a pair of
  equations.** Page IOBINT's 74S175 at 0F14 latches `KBD/MOUSE.IREQ`,
  `SER.IREQ`, `CHAOS.IREQ` and `CLOCK.IREQ` on the grant, and the 74LS00s at
  0E12 make `V2 = (SER AND NOT CHAOS) OR CLOCK` and `V3 = CLOCK OR CHAOS`.
  So the vectors are `0o260` for the keyboard and mouse, which share one,
  `0o264` for the serial port, `0o270` for the Chaosnet and `0o274` for the
  clock. **With more than one latched the clock is named before the Chaosnet
  before the serial port before the keyboard.** Each request is a ready bit
  ANDed with its enable, the 74LS08s at IOBKBD 0D26, and the first two are
  ORed by the 74LS32 at 0D25.
- **`-UB INIT` reaches five flip-flops and the 2651, and nothing else.**
  `-INIT*` into the 8837 at IOBXCV 0F06 is `RESET`, the 2651's own reset pin.
  `-RESET` off the 74S37 at 0E07 clears the 74LS175's four enables and the
  74LS74's serial enable. **`KBD READY`, `MOUSE READY`, the mouse counters,
  the interval timer and the microsecond counter have no pin on it and count
  on.**
- **The card answers `-UB MSYN` in its own time, and it is not one number.**
  `busint::IoBoardTiming` is a behavioural twin measured on the netlist board.
  The clocks, the GPIO and the counter's high half answer 250 ns after
  `-MSYN` through the TD250 at IOBADR 0E09. The keyboard, mouse, status and
  beep registers select through **two** stages of the microsecond clock and
  answer 250 ns after the second edge strictly past `-MSYN`, so they answer
  between 1,250 and 2,250 ns later depending on where the request fell. The
  counter's low half takes one edge and 313 ns.

## What is simulated time rather than the machine's

muir's own header says it: *"Where this is knowingly not the machine: the
clocks are driven from simulated time rather than the computer's, which makes
a run reproducible."* Concretely, four things on this card are functions of
`Machine::ns` and not of any crystal:

- The microsecond counter, `usec_at(ns)`, edges at 890 + 1,000k from power-on.
- The sixty-cycle counter is `ns / SIXTY_CYCLE_NS`, with `SIXTY_CYCLE_NS` =
  1,000,000,000/60 = 16,666,666 ns, counting from power-on.
- `CLOCK READY` is `ns - loaded >= interval * 16,000`.
- The mouse's `KB CLK^` sampling is every 8,000 ns from power-on, and the
  mouse's own step is one quadrature phase every 16,000 ns.

**None of them is derived from the CADR's clock generator.** On `micro`, the
engine with no clock at all, `ns` is microcycles multiplied by 145, and these
keep worse time than the board would. On `rtl`, `ns` is the machine's own
nanoseconds, so a fabric counting its own ticks agrees. That is the engine
this trace is taken from, and the one the fabric is held to.

That is a reference with time in it in four places. Each of them lands on the
fabric's grid or is shown not to, and the next section is that.

## What the two reference programs ask of it

This was measured with a throwaway probe against muir's `rtl` engine, counting
every microcycle whose `VMA` translates onto this card.

**Over MIT's boot PROM, 600,000 microcycles and 17,466 bus cycles, the card is
never addressed, not once.** Its single Unibus cycle is the diagnostic block,
the mode-register write that turns the PROM off.

**Over a System 100 band, 2,200,000 microcycles and 141,849 bus cycles, it
takes 271 bus cycles on three registers and nothing else.**

    microcycle 1,410,551   read  764112   the status register, uc-cadr.lisp's (LOC 6)
    from     2,087,405     read  764120   the microsecond counter, low half   x135
    from     2,087,409     read  764122   ...and its high half, MIT's order    x135
    microcycle 2,168,062   write 764112 = 0o4   KBD INT ENABLE

That is the whole of it. The status-register read at 1,410,551 comes five
hundred microcycles after the machine leaves the boot PROM at 1,410,035. It is
the decision between a warm and a cold boot: `uc-cadr.lisp` enters at `(LOC
6)`, reads the register, and cold-boots unless the keyboard is ready and
holding something other than RUBOUT. **With nothing answering there the read
is an NXM and the machine cold-boots by accident rather than by decision.**
That is what it does today, and it is the first thing this card changes.

It touches no mouse register, no keyboard data register, no interval timer, no
beep and no GPIO. Not one interrupt is taken. Nothing types, so `KBD READY`
never comes up, and `CLOCK INT ENABLE` is never set by anything in the release.

**So a check driven by either program would test the decode, two reads and one
write.** That is the control-store-writes-zero-to-all-16,384-words shape
again, and `golden/src/iob.rs` is the only reference this card can have.
`docs/tv.md` and `docs/disk-controller.md` reached the same conclusion, for the
same reason.

## The decisions

**The seam is the Unibus, not `-MEMRQ`.** `cadr_busint_xbus.sv` is already
held to `busint::Busint` tick for tick, and it already drives `-UB MSYN`,
`ub_write` and `ub_addr` and takes `-UB SSYN` back. `cadr_memory_path.sv`
computes `ub_addr` as `busint::unibus_address` and holds it beside the decode,
and `cadr_spy_registers.sv` is the slave that answers today, at `0o766000`.
The I/O board is the **second slave on that seam** and its check belongs there:
one module, one testbench, and a Unibus master in the testbench replaying the
trace. That is exactly where the disk controller's check lives, at its four
registers. Composing it under `cadr_memory_path` is a later slice, and
`busint_xbus.golden` is the trace for that.

**A slave on that seam must hold its address match and not compute it.**
CLAUDE.md records this as the disk controller's -6.195 ns. A combinational
match on `phys` carries the map's ripple into `-MEMACK`/`-LOADMD` and so into
the countdowns' clock enables. Here the address is `ub_addr`, which
`cadr_memory_path.sv` already registers with the decode, so the ripple is
already cut. But the same rule applies to whatever this card computes from it,
and `cadr_spy_registers.sv`'s shape (a `selected` term off the registered
`ub_addr`, an `elapsed` counter from `-UB MSYN`) is the one to copy.

**This is the 5 ns grid, and the one place this card is not on it.** Every
instant the fabric can act at is a multiple of five nanoseconds. The
microsecond clock's edges are at 890 + 1,000k. The keyboard-and-mouse group
answers 1,250 ns after the second edge past `-MSYN`, and the clocks and the
GPIO answer 250 ns after `-MSYN`. `KB CLK^` is 8,000 ns and the mouse's step
16,000, and the interval timer's count is 16,000. All of those are multiples
of five. **The microsecond counter's low half is not.**
`busint::IOB_USEC_LOW_NS` is 313 ns, measured on the netlist, so muir answers
at 1,203 + 1,000k and the fabric can only answer at 1,205. The trace carries a
`slip` column saying so on every such row, rather than hiding two nanoseconds
in a tolerance. And **nothing downstream sees it**: `-LMACK` is 150 ns and the
MD strobe 100 ns past `-UB SSYN`, both multiples of five, so a bus interface
counting from the tick it *sees* `-SSYN` lands where muir's does. 208 rows of
the trace carry it and no other register ever does, and the generator asserts
that.

**The sixty-cycle counter is off the grid too, and it costs nothing.**
`SIXTY_CYCLE_NS` is 16,666,666, which is 1 mod 5, so the k'th mains edge is on
the grid only for k a multiple of five. Take a fabric that accumulates
nanoseconds by five and subtracts the period, which is `disk_unit`'s spindle
trick, and which CLAUDE.md already records as being exactly
`now mod REVOLUTION_NS`. It increments at the first tick at or after each
edge, and the window in which it disagrees with `ns / SIXTY_CYCLE_NS` is
`[B, B + (5 - B mod 5))`, **which contains no multiple of five at all**. So
the two agree at every instant the fabric can be looked at. A fabric that
instead reloads a down-counter with 3,333,333 ticks loses a nanosecond a
period, and the trace reads the register at fourteen boundaries on alternating
sides to catch it.

**A tick is 10 ns, so this card's two clocks no longer agree with the wall.**
Everything above is the machine's own time, where a tick is five nanoseconds
because that is what MIT's drawings are drawn on, and every tick count in the
design is unchanged. What changed on 2026-09-11 is how long a tick lasts: the
fabric runs at 100 MHz, so the machine runs at 50% of the speed the hardware
ran. `USEC_PERIOD_T` is 200 ticks, which is now 2.0 real microseconds, and a
CADR wall clock run off this counter loses half a day in a day. The
sixty-cycle counter is the same family and slows in the same proportion, its
mains edges arriving at 30 Hz. **Mete's decision is that both keep agreeing
with muir for now**, because the checks are the backbone of this project and
nothing built yet needs the time of day --- this card is not composed into
`cadr_machine` at all, so nothing on the board reads either of them. **And
undoing it is still one constant, which is part of why the tick is a number
that divides a thousand.** A real microsecond is exactly 100 ticks, a whole
number, so restoring real time here means changing `USEC_PERIOD_T` and nothing
else, rather than a rewrite or a second clock domain. Doing it would put this
module out of agreement with muir, which is why it has not been done.

**A write lands at `-UB SSYN`, because that is where muir puts it.**
`busint.rs`'s `Responder::Unibus` arm makes `answered` equal to `ssyn` for
every register of this card. `Responder::Interface`, the diagnostic block,
lands at `REGISTER_STROBE_NS` past `-MSYN` instead. On the card the pulses
are earlier than that: `-LOAD INTERVAL` is `Y2` of the 74LS138 at CLK60H 0B21,
gated by `-WRITE` while `-MSYN` is up. **Nothing on the card can see the
difference.** The only state a write starts is the interval timer, whose
counts are 16 us apart, and a status-register write preserves both ready bits.
But the instant is a choice, and a fabric that loads the interval timer at
its own write pulse brings `CLOCK READY` up by up to 2,250 ns early against
this trace. That is written here, not left to be found.

**The counter's low half is read at `-UB MSYN`, not at `-UB SSYN`.** muir's
`busint.rs` says why: "the board latches it on the way to answering, before
the edge that answers has counted". The band's first read of it took one less
on the netlist than a count taken at the answer. Every other register is read
or written at `-SSYN`. The trace carries both instants on every row, so this is
a column and not a convention.

**The serial port's ready line is an input to this card, not a 2651.** The
priority encoder on page IOBINT takes four requests and only one of them is
made here. `SER.IREQ` is the 2651's `-RxRDY` and, by ECO 10 of
`cadrio/iob.eco`, its `-TxRDY` on the same net, through the 74LS02 at IOBSER
0E11 with `SER INT ENABLE`. So `cadr_io_board.sv` takes `ser_ready` as a port,
the trace drives it with a `SER` row, and the 2651 itself is the serial
slice's. **`-UB INIT` must reach it**, because `-INIT*` is the chip's own
`RESET` pin. The trace shows `serrdy` falling at every init.

**THE MOUSE'S SEAM IS DECIDED AND IT IS MIT'S CARD: the card takes the seven
lines.** Slice one posed it as an open question and slice two answered it, at
Mete's session's direction. This project reproduces the machine and is held to
muir, and a module taking ready-made deltas is a different card: one that
cannot lose counts, whose `NEW`/`OLD` latches and comparator disappear, and
against which this trace stops being a reference for the mouse half. So
`rtl/machine/cadr_io_board.sv` takes `mouse_lines<6:0>`, and the encoder that turns
Linux's deltas into quadrature phases is fabric beside it. On this slice that
encoder is in `tb/cadr_io_board_tb.cpp`. Here are the two shapes as they were
posed, and why the second was declined.

muir puts the encoders in `terminal::mouse`, the far end rather than the card,
and what crosses the card's edge is seven lines: four quadrature and three
switches. A USB mouse gives deltas, and turning a delta into quadrature phases
16 us apart --- 32 real microseconds, the tick being 10 ns --- in software
over `M_AXI_GP0` is 50,000 writes a second, so the phase generator cannot be in
`cadr-usb-input`. There are two shapes, and the trace supports either:

- **The card takes the seven lines**, and something in fabric beside it turns
  Linux's deltas into phases. This is the card MIT built, and the trace's
  `MOVE` rows then belong to the testbench, which runs the encoder model.
- **The card takes deltas** and adds them to the counters directly, setting
  `MOUSE READY` on a change.

The first was taken. The encoder's contract is Gray phases in the order 00,
01, 11, 10, a step every `MOUSE_STEP_NS` = 16,000 ns, both lines of each pair
high at power-on, and **muir's snap**. See the model's findings below, which is
where that word is explained and where the cost of getting it wrong is
measured. **A mutation cannot reach it**, because on this slice the encoder
is in the testbench. `mutations/list.txt` says so where the card's records
begin, and the two records that stand nearest it break the card's half of the
same agreement, its 8 us clock's rate and its phase.

**The interrupt leaves the card as a vector and a request.** Those are
`-UB INTR` and `-UB BR5` on the backplane, and `machine.rs:455` ORs
`interrupt_request` with `UB_INT` into what the processor reads. Nothing in
`rtl/` has a Unibus interrupt path yet, so the card's output is a port with
nothing on the other end until somebody builds one. That is honest, and it is
the same shape the display's `tv_intr` had before `f8c6d25`.

## What the trace is

`build/iob.golden` is 100 KB, 1,532 event rows and 94 decode rows over 404.7 ms
= 80,949,318 ticks. `make iob-golden` writes it in 0.85 s, and two runs are
byte-identical. There is no wall-clock time in it and no randomness.

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

Every row ends with the same face, sampled after whatever the row did. It
holds the status register's flip-flops before the floating byte and `CLOCK
READY` are made up on a read, the two mouse counters, the switches as the
mouse holds them, `CLOCK READY`, the interval last loaded, the vector the card
is asking for, `AUDIO`, and the serial port's ready line. **Each is a register
or a wire on the card**, so none is a column invented for the trace.

The decode is exhaustive over all 262,144 addresses an eighteen-bit `ub_addr`
can carry, in both directions. There are 32 runs where nothing answers and 31
addresses that do, one row each per direction. That is 16,514 comparisons in
the model's run, and it is the whole decoder.

What the program does, in order, is this. It takes the face at power-on and
reads every register once before anything is written. It runs eleven cycles
the card does not answer, below the block, above it, at an odd address inside
it, and the two writes the clock group refuses. It runs the keyboard, fifteen
presses whose scan codes are injective and between them cover all twenty-four
bits, with the high half read while `KBD READY` stands and the low half
clearing it. It runs the mouse, seventeen moves in both directions on both
axes, the twelve-bit counters wrapped either way by a single count from zero,
the counters read in six successive clocks each while they run, and all eight
switch masks each read inside the very clock the latch takes it on. It writes
the status register with all sixteen bits, each writable bit alone, and both
ready bits standing through a write of zero. It takes **all two hundred phases
of `-UB MSYN` inside the card's microsecond**, at a register that waits two
edges, one that waits one and one that waits none. It reads the microsecond
counter's carry into its high half from both sides. It runs ten intervals on
the timer including the longest there is, held for 200 ms and never allowed to
expire. It reads fourteen boundaries of the sixty-cycle clock. It takes the
interrupt, every reachable vector and the priority chain taken apart one
enable at a time. It sends three `-UB INIT` pulses. And it clicks the beep by
reads and writes alike at MIT's own half-wavelength.

## What no trace against this model can reach

These are said here rather than given a column, per CLAUDE.md's rule.

- **The Chaosnet's vector, `0o270`.** `interrupt_request` consults
  `self.chaos`, which is `None` unless an interface is plugged in, and
  plugging one in drags the whole Chaosnet board into this trace. The
  priority chain is exercised clock over serial over keyboard-and-mouse. The
  Chaosnet's place in it, between the first two, is the Chaosnet slice's to
  check. **The fabric's priority encoder needs the input regardless**, and a
  card built without it will pass this check.
- **The Chaosnet and serial register groups.** `DEC` carries what the decode
  makes of them, because the decode is one sheet. No `CYC` goes near them,
  because the parts behind them are two other slices. A card that answers
  `0o764140`--`0o764176` with nothing behind it would fail on the real
  machine and passes here. **Slice two therefore made this an exemption with
  a number on it.** `rtl/machine/cadr_io_board.sv` decodes the whole block and
  answers only the two groups it implements, the check requires that it does
  not answer the other fifteen addresses, and it prints how many answering
  directions that covers, twenty-seven of the fifty-five the decode names.
  Whoever builds either slice makes the card answer its group, with
  `busint::IOB_CHAOS_BUFFER_NS`, `IOB_RBUF_SETUP_NS` and `IOB_SERIAL_NS` for
  the instants, and moves that line.
- **The latch on the mouse's seven lines, from the lines themselves.** This
  was measured at slice two, as a mutation on both mouse registers: reading
  `lines` where the card reads `NEW` survives. muir's snap puts every step of
  a move onto a `KB CLK^` edge, which is the edge the 74LS374 at IOBMSE 0A24
  takes them on, so the lines and the latch change at one instant and never
  differ where anything reads. The switches change at a `BTN` row and the
  program reads them back inside the clock the latch takes them on, which is
  after that edge. What the trace CAN tell from `NEW` is a value one clock
  **late**, which is `OLD`, the 74LS374 at 0A22, and the module has no
  register for that. `OLD` is `NEW` a clock ago and the edge that makes it is
  the edge that uses it, so the count and the comparator are written in terms
  of `NEW`, and the lines and the second latch would be a copy nothing reads.
  This is recorded rather than filed as a hole, and the live records on that
  wiring are the two that cross which four of the seven lines reach which
  register.
- **`take_beep` and `AUDIO_QUIET_NS`.** muir's own comment says they are the
  far end's arithmetic and not the board's. The card has the 74LS74 at
  IOBKBD 0C27 and nothing else, so `AUDIO` is the column and the beep is not.
- **A cycle whose master drops `-UB MSYN` before the card answers.** The bus
  interface never does it and muir's model has no state for it.
- **`REMOTE MOUSE ENABLE`'s effect.** It is the first of the 74LS175's four,
  and muir models it as a bit that reads back and does nothing. The trace
  holds it to that, which is a check that it reaches no interrupt gate and
  nothing more.
- **The keyboard's own cable.** `terminal::cable` and the 75118 at IOBKBD
  0E30 are the far end. What crosses here is a twenty-four-bit word arriving,
  which is the `KEY` row.
- **`-BOOT*`, the keyboard's boot key.** muir's `unibus.rs` says it runs to
  the processor board past the interface, which has no net for it, and
  nothing presses it.

## What the Python model found

The model is under the session's scratchpad and is thrown away, and what it
bought is here. It was written the way the fabric will be, edge driven, one
register a register, with the decode from the sheets rather than from muir. It
was run against `build/iob.golden` until it agreed row for row, which it does:
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
then hold the same seven bits. So a card putting `OLD` on `UBO12`--`UBO15`
agreed with muir on every row. The fix is to read them **while they are
moving**: six reads of the X register in six successive clocks and then six of
the Y register in six more, each placed so that `-UB SSYN` falls inside the
clock the latch last moved on. **Six of each and not six alternating**, and
that difference was measured. The mouse holds a phase for two of the card's
clocks, so the clocks the latch moves on are every other one, and an
alternating burst puts every read of a given register on one parity, which
can be the parity where nothing moved. With the alternating burst the mistake
survived. With six in a row it is caught at row 254. The switches take the
same treatment, each mask read inside the very clock the latch takes it on,
and that one is caught at row 753.

**muir snaps the mouse's step train onto the card's clock, and a fabric that
does not is one count behind for the whole of every move.** `MouseInterface::
sample` computes each step's instant as `max(encoders.next, the previous
edge)` and steps there. So a step whose due time has fallen behind the last
edge is dragged forward to it, and because the previous edge is a multiple of
8,000 and the step is 16,000, **every subsequent step lands exactly on an
edge.** The first two steps of a move therefore land on *consecutive* edges
and everything after on every other one. A model that instead starts the train
where the motion arrived and keeps its own phase was written and measured.
**307 face rows and 27 read-backs disagree**, the counters one behind muir's
for the length of each move and converging only at its end. That is not a
tolerance to widen. It is a contract, and whoever writes the encoder, in the
testbench or in fabric, reproduces it or the check is red for a reason that
has nothing to do with the card.

**There is one measured equivalence, recorded so nobody files it as a hole.**
Widening the block select's top from `0o764176` to `0o764200` **survives, and
is equivalent**. `(0o764200 >> 4) & 7` is 0, and the 74LS138 at IOBADR 0E20
sends group 0 nowhere, so an address one word past the block answers nothing
however wide the DM8136s' match is. The live form of that mutation is the
other direction, reaching a page lower, `0o763000`. That puts `0o763776` into
group 7 and is caught at row 24, on the first cycle the card is not supposed
to answer. It is the same family as the equivalences CLAUDE.md already
catalogues.

## What slice two built

1. **`rtl/machine/cadr_io_board.sv`** is a Unibus slave in
   `cadr_spy_registers.sv`'s shape. In go `clk`, `rst`, `ub_msyn`,
   `ub_write`, `ub_addr` and `ub_wdata`, and out come `ub_ssyn` and
   `ub_rdata`. In also go `ub_init`, `ser_ready`, `chaos_intr`, the mouse's
   seven lines and the keyboard's word, and out also come `ser_reset`, the
   interrupt request and its vector, `AUDIO` and the card's own state.
   Inside are the decode, the answer machine off a free-running microsecond
   clock, the keyboard's word and its ready flop, the mouse's latch,
   comparator and two counters, the microsecond counter with its
   thirty-two-bit latch, the mains counter as an accumulator, the interval
   timer, the status register and the priority encoder.
2. **`tb/cadr_io_board_tb.cpp`** is a Unibus master replaying `iob.golden`
   tick for tick. It also holds the mouse's encoders with muir's snap in them,
   since the card takes the lines and not deltas.
3. **The Makefile's `iob.pass`** is in `check`.
4. **Twenty-five mutation records** were written, with the runner's `iob`
   entry.

**The card's own state made the module say two things out loud.**

**The match is held and not computed**, which is the disk controller's
-6.195 ns lesson at the second slave on this seam. It costs nothing here and
the module says why at the register. The earliest answer the card can give is
fifty ticks after `-UB MSYN`, so a match a tick behind the strobe is a match
forty-nine ticks early. The reference trace is a master with **no address
setup at all**: `-UB MSYN` and the address arrive on the same nanosecond,
and two cycles running back to back have the next `-MSYN` at the instant the
last one dropped. So a card that needed the address at the strobe would
have had to compute it.

**And the sixty-cycle accumulator was the module's only timing problem.**
Written the obvious way, as `mains_acc + 5 >= SIXTY_CYCLE_NS` and then that
sum less the period, it puts an adder, a 24-bit compare and a subtraction
in series on the accumulator's own data pins. That is eleven logic levels and
**-0.702 ns** out of context, measured at a 5 ns tick, the worst path in the
module by a mile and the only one that missed. The remedy is the one
`cadr_disk_controller.sv` already uses for its spindle and
`cadr_phase_gen.sv` for its taps: compare a tick early into a register, and
make the two candidates adders in parallel with the mux after them. The check
passes byte-identically either way, which is what says the transformation is
exact.

**There are two placement rules, because a zero-time trace does not replay on
a clocked fabric.** 177 pairs of rows share an instant. First, `-UB MSYN`
drops one tick early, at `off - 5`, so the bus is idle for a tick before the
next cycle. Second, a row whose action changes something the face shows, such
as a press, the serial port's ready line or `-UB INIT`, is pushed one tick
when it would otherwise land on the tick the previous row's face is compared
at, and every row at that instant after it is pushed with it. Seven rows are
pushed and the check prints the count. A move or a switch changes nothing the
card shows until its next `KB CLK^`, and a cycle changes nothing on the tick
its `-MSYN` rises, so those share a tick and are not pushed.

Two things followed separately. The first was the composition under
`cadr_memory_path.sv` beside `cadr_spy_registers`, which is slice three below.
The second is the Linux side, `cadr-usb-input`, which is last in the agreed
order of work.

## What slice three built

Slice three put the card on the Unibus inside the machine. It is one
instantiation, a join and a mux in `rtl/machine/cadr_memory_path.sv`, the
cables carried out through `rtl/machine/cadr_machine.sv` to
`boards/arty-z7-20/cadr_arty.sv`, and a check of its own.

1. **`cadr_io_board` is instantiated in `cadr_memory_path.sv`**, beside
   `cadr_spy_registers`. Both hang off the seam `cadr_console_bus.sv`
   presents, `-UB SSYN` is the OR of theirs as the open-collector line on the
   backplane is, and the word is a mux on which of them answered.
2. **`ub_ssyn_by` is a new observation output**, two bits: which slave is
   pulling the line. The line itself cannot tell them apart, and "at most one
   of them answers any address" is the whole claim the composition makes.
3. **The card's four cables cross to the top level and are tied off there**,
   each naming the slice that will drive it: the keyboard and the mouse to
   `cadr-usb-input`, the ready line to the serial slice, the request to the
   Chaosnet slice.
4. **`tb/cadr_unibus_tb.cpp` and `make build/unibus.pass`** are the check. It
   is the twenty-eighth.
5. **`rtl/plumbing/xilinx7/cadr_machine.xdc` takes the card out of its relaxed
   set** but for the five registers of its held match.
6. **Six mutation records**, with the runner's `unibus` entry, and a seventh
   moved here from `machine`: the new check closed issue #13.

### The new check closed a recorded hole

`the-unibus-acknowledgement-and-the-md-strobe-change-places` exchanges the bus
interface's two Unibus instants, so the cycle is acknowledged where the MD
strobe belongs and MD is strobed where the acknowledgement belongs. It had
carried `@hole #13` since it was written.

The hole's own prose said what would close it. "It is not an equivalence:
exchanging the two instants puts `-LOADMD` after `-MEMACK` instead of before,
which is observable wherever a Unibus read's word is used. Nothing here uses
one." Nothing did. `build/unibus.pass` uses one, and the record is caught on
its first cycle at "-MEMACK, in ticks after -UB SSYN is 20, wanting 30". The
record is `@check unibus` now and carries no hole, and issue #13 has no
records holding it open.

### There is no decode in front of the two slaves, and that is deliberate

Slice two expected one. It would make the two mutations that matter
untestable. CLAUDE.md records the shape: the display's
`tv-answers-its-neighbours`, written as a wider address match gated by the
decode's `device`, survived. A slave that honours a guard which is checked
exhaustively elsewhere cannot answer an address the guard refuses, so the
mutation tests the guard and not the slave.

On the backplane each board decodes the whole address for itself and pulls
`-SSYN` if the address is its own. That is what both of these do. A match
widened in either of them is then visible. The record that says so is
`unibus-the-register-block-reaches-down-into-the-cards-page`.

**The collision is only reachable from that side, and the mutation run is
what found it.** Widening the card until it covers the register block cannot
be written at all. The 74LS138 at IOBADR 0E20 splits the card's block on
`A<6:4>` and sends groups 0 to 3 nowhere, and the register block's sixteen
registers are at `A<6:4>` 0 and 1. So a card whose page match reached
`0o766000` would still answer nothing there, however wide the match became.
That is the same equivalence `iob-the-block-select-reaches-a-page-lower`
records at the other end of the block.

**And `cadr_spy_registers.sv` had never been mutated.** It was in no check's
source list, so `check_coverage` --- which unions those lists --- had nothing
to say about it, while every check that builds `cadr_machine` built it through
the include path. It is in `unibus`'s list now, with the record above aimed at
it.

What replaces the decode is an assertion. The check runs a real bus cycle at
every word address of `0o763000`--`0o770776` in both directions and requires
that at most one slave answers each. It also checks the two slaves' sets for
overlap over all 262,144 Unibus addresses with no simulation at all, against
muir's own `ioboard::answers` table and the register block's base.

### No other check runs a Unibus read

This was measured rather than assumed. `build/machine.pass` prints "the Unibus
arbitration of 1 of 17466 bus cycles", and that one cycle is MIT's boot PROM
writing the mode register at `0o766012`. `busint_xbus.golden`'s addresses are
main memory and empty Xbus space, and it runs no Unibus cycle at all. The band
trace runs against `Vcadr_microcycle`, where `-MEMACK` and `-LOADMD` are
muir's stimulus.

So `cadr_busint_xbus.sv`'s MD strobe had never carried a word anybody compared.
That is the one instant on either bus where the word and the acknowledgement
come apart: the word lands `UNIBUS_STROBE_NS` after `-UB SSYN` and the
acknowledgement `UNIBUS_ACK_NS` after it, fifty nanoseconds later, which is why
`n_loadmd` is a port of its own. `build/unibus.pass` compares both instants on
every one of its answered cycles.

### What the check compares, and what it refuses to compare

The card's own answers belong to `build/iob.pass` and are not repeated. What
`build/unibus.pass` compares instead is what its own testbench put in: the
twenty-four-bit scan code it strobed, the seven mouse lines it drove, the
interval and the interrupt enables it wrote. A word that came from the
stimulus cannot move with a bug in the card, in the mux or in the bus
interface.

The register block's word is a poison injective in the register number, driven
from the address the testbench is itself driving and never from `spy_eadr`. So
a mux that returned the other slave's word is caught in both directions.

The microsecond counter is compared as a difference and never as a value. Two
reads whose `-UB MSYN` instants the run measures to be a whole number of the
card's microseconds apart must differ by exactly that many counts. That is the
timebase claim and it needs no model of the counter's phase. The run stands
still for 9.8 million ticks so that the count carries into its high half, which
is what makes that half a live comparison rather than zero against zero.

The mouse's counting is not exercised here and is not meant to be. The lines
are held still, so the two counters stay where reset left them and the two
mouse registers carry the switch and quadrature lines the testbench drove.

### The third slave, and what the sweep used to show

muir's `busint::register` answers `0o766040`--`0o766076`, the bus interface's
own interrupt control and error status registers, and `0o766140`--`0o766176`,
the Unibus map. This fabric built none of them until
`rtl/machine/cadr_busint_regs.sv`, so those thirty-two word addresses timed out
here where muir answers, and the run printed the count. They are answered now.

`build/busint_regs.pass` holds that module to muir at its own seam and sweeps
`busint::register` over all 262,144 addresses. `build/unibus.pass` holds the
composition: three slaves on one bus, `-UB SSYN` the OR of theirs, the word a
mux on which answered, and never two at once.

The decode for all three now comes out of muir as well. This check used to
carry `cadr_spy_registers.sv`'s base as two constants of its own, so the one
block whose address set was nobody's reference was the one the machine cannot
start without. `busint_regs.golden` carries `busint::register` over the same
eighteen bits, the diagnostic block included, and it is the second trace the
check is handed.

**`0o766040` is also the first of the two defects behind the interrupt
storm.** Microcode 323's handler reads it four instructions in and branches on
bit 1, `LOCAL ENABLE`, which is a jumper pulled up on the board. MIT's own
comment on the branch is "jump on no local-enable, ie, PDP11 arbritrating
UNIBUS". Unanswered, that read gave MD zero and the bit read clear, so the
handler took the path written for a machine that does not arbitrate its own
Unibus. That path falls through `INNL0` and `INND0` to `XB-INTR-RET` and never
reaches `INTRX0`, which is the only code that clears an Xbus level. Answered,
the bit reads set and the handler takes the branch MIT wrote for this machine.

### The interrupt request reaches the processor, and what took so long

`LM INT` is `UB INT OR XBUS INTR IN` at UBINTC 0E04, so on the board the card's
interrupt does reach the processor. But muir's `Machine::unibus_interrupt`
takes it only while `ENABLE UB INTS` is set, and that is bit 10 of the bus
interface's own interrupt control register at Unibus `0o766040`. That register
did not exist here.

Joining the request straight into `sintr_o` would therefore have raised the
processor's interrupt where muir raises it only under a bit no program could
set. So the request left the machine as an observation output and the top level
folded it, and the note said what would close it: `0o766040` itself, the
register, `ENABLE UB INTS`, `UB INT` and the vector field a handler reads back.

That is what closed it. `cadr_busint_regs.sv` takes the card's `intr_request`
and `intr_vector`, `Machine::unibus_interrupt` is its `ub_int` output, and
`cadr_machine.sv` makes `sintr_o` the OR of that with the Xbus line.
`iob_intr` and `iob_vector` still leave the machine, where the top level goes
on folding them.

**The wire between the two modules is visible to one check alone.**
`build/iob.pass` compares the card's request where it is an output;
`build/busint_regs.pass` drives it where it is an input; only in
`build/unibus.pass` are they the same wire, so only there can a crossed or
dropped connection show. That is CLAUDE.md's worst case written out --- a
crossing that leaves every signal read is caught by nothing, anywhere, by any
tool --- and two records are aimed at it.

### What the card costs the board

Measured through `boards/arty-z7-20/vivado/bitstream.tcl` on both boards, and
against the same two fits run from a worktree at `74fa921` on the same machine
and the same tool, so the comparison is an A and a B and not two readings.

| | memory-off | `DDR=1` |
|---|---|---|
| worst negative slack | +0.375 to +0.393 ns | +0.362 to +0.153 ns |
| failing endpoints | 0 of 16,316 to 0 of 16,843 | 0 of 27,578 to 0 of 28,166 |
| hold | +0.036 to +0.048 ns | +0.025 to +0.043 ns |
| Slice LUTs | 3,685 to 3,895 | 7,352 to 7,518 |
| Slice Registers | 1,662 to 1,863 | 5,195 to 5,412 |
| block RAM tiles | 37, unchanged | 37, unchanged |

Both boards still meet timing. The memory-on board lost 209 ps, and that is
placement rather than the card. Its worst path moved from the pack side's
`store_wdata` reaching the disk controller's tag to
`disk/rst_q_reg/C -> disk/ch_i_reg[0]/R`, which is zero logic levels and 92%
routing, and no path of the card appears anywhere in that report.

The card's own worst path, on the memory-off board where it is not folded
away, is `memory/iob/t_edge_reg[0]/C -> memory/iob/iv_t_reg[0]/R` at
+0.646 ns.

### The card is out of the relaxed register set, and that was asked of the design

`rtl/plumbing/xilinx7/cadr_machine.xdc` relaxes a set defined as every
register minus a name list, so a module written after it is swallowed whole.
CLAUDE.md records what that cost on the disk controller: 3,904 of its 4,000
internal paths carried the fifteen-cycle exception and three slices' fit
figures were of a design a quarter of which was not being timed.

The card is excluded whole, but for the five registers of its held match:
`sel`, `kbm`, `clkgrp`, `wr` and `which`. Everything else there is a clock or
a cycle's own state. `usec_t`, `kb_t` and `iv_t` count down one a tick,
`mains_acc` adds five nanoseconds a tick with `mains_wrap` comparing it a tick
early, `t_msyn` and `t_edge` count since the strobe and since the last edge,
`usec` is a counter read by a latch at an arbitrary tick, `ub_ssyn` is the
answer itself, and `busy`, `first` and `edges` are one tick deep.

That was measured and not read off the filter expression. Synthesised with the
file read scoped at the 6.25 ns tick of that afternoon, every path out of every
one of those registers asks for 6.250 ns, which is one tick; none asks for
93.750. The two requirements are one tick and fifteen, and at the 10 ns tick
built since they read 10.000 and 150.000. The five held ones do carry
the exception where it is right: 32 of `sel`'s 133 paths, 32 of `kbm`'s 101,
32 of `wr`'s 131 and 32 of `which`'s 133, which are the thirty-two bits of the
read mux reaching MD.

**The fitter does not test the keyboard or the mouse on this board.** With the
cables tied off, `scancode`, `kbd_ready`, `mouse_ready`, `mnew`, the two mouse
counters and `kb_t` all constant-fold and no cell of them survives synthesis.
That is the drive seam's own lesson and it will stop being true the day
`cadr-usb-input` drives them.

### The console's drop discipline is load-bearing, and it was measured

`cadr_console.sv`'s engine drops `-UB MSYN` and then holds its request up until
the slave has let `-UB SSYN` go. Its own comment says why: "dropping the
request while SSYN is still up would hand the next master a bus that is already
answering." The testbench's master model follows it.

That is not decoration. Written the impolite way, with the request dropped
beside the strobe, a processor cycle standing behind the console was
acknowledged by the register block's leftover `-UB SSYN` rather than by the
card. It is the same fact as the bus idling for a tick at every change of owner
in this module's channel arbiter, and the discipline lives in the console
rather than in the arbiter.

## What is not built

- **The serial port.** It is `0o764160`--`0o764176`, the 2651 at IOBSER 0A12,
  and it has its own slice and its own Linux program (`cadr-serial`). What
  this slice leaves it is a ready line into the priority encoder and a vector,
  `0o264`.
- **The Chaosnet interface.** It is `0o764140`--`0o764156` and `0o270`, and it
  has its own slice.
- **The keyboard's and mouse's far end.** That is `cadr-usb-input`, last in
  the order of work. The kernel side is done, and `evtest` printed Mete's name
  off a USB keyboard on the board on 10 Sep.
- **The Unibus interrupt cycle.** Nothing in `rtl/` puts a vector on the bus
  or arbitrates `BR5`. The interrupt itself is built: the card's request
  reaches the bus interface's own register at `0o766040`, is taken under
  `ENABLE UB INTS`, and joins `-XBUS.INTR` into `SINTR`. What is missing is
  the grant cycle the vector would arrive on, so the vector comes to the
  register on a wire. muir does the same and says why: "The model has no grant
  cycle to latch at, so the vector is read off the requesting board at the
  time of the read."
- **The mapped Unibus window, the map's read and write buffers, and
  `UB MAP ERROR`.** The sixteen map registers store and read back. What walks
  them is the debug cable's master, `Machine::mapped_read` and
  `mapped_write`, and the processor's own Unibus cycles are not mapped. So no
  slave answers `0o140000`--`0o177777`, the 29701s at RBUF and WBUF that make
  a word out of two Unibus cycles are not here, and neither is the error bit
  only a mapped cycle can set. That is the half of CC's route to main memory
  that is still missing, and `docs/console.md` says what it costs.
- **The debug block at `0o766100`--`0o766136`.** It is a cycle on the other
  machine's Unibus, answered over the cable. `busint::register` decodes it to
  nothing and so does this fabric; in the composed machine those four
  addresses therefore time out, where muir's `Responder::Debug` with no cable
  answers at `-UB MSYN` off the pull-up. That is a divergence of the cable's
  absence and goes when the cable's side is built.
- **`-BOOT*`.** The keyboard's boot key runs to the processor board past the
  bus interface and nothing presses it, in muir or here.
