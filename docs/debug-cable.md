<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The debug cable's debuggee end

A CADR is debugged by another CADR. The debugger's `DBGOUT` connector goes to
the debuggee's `DBGIN` connector over the twenty-one wires of MIT's debug
cable. This project's fabric is the debuggee. muir, running on the board's own
Arm cores, is the debugger.

muir's half is built. It is `src/fabric.rs` on muir's main at `e4d8aeb`, and
the specification it was built to is muir issue #95. Nothing is plugged in and
there is no second board. The cable's wires are a window of memory-mapped
registers that muir reaches with ordinary loads and stores, selected by
`--debug-cable-connect 0x<address>`.

This document is the fabric half. It says what is built, what each piece is
held to, and what is not built yet.

## The two pieces, and why they are two

`rtl/machine/cadr_dbgin.sv` is MIT's own logic. It is the 74S139 at DBGIN
0A15, the modifier register at 0A16, the two address latches at 0A18 and 0A19,
the error-status driver at REQERR 0B15, and the debug master's place on the
debuggee's Unibus. It is held to muir, and the muir types are named in its
header.

`rtl/plumbing/cadr_debug_window.sv` is the carrier. It is the register window
muir's `fabric::Fabric` stores into and loads from, and an AXI3 slave on one
of the processing system's general-purpose ports. No muir reference exists for
it, as none exists for `cadr_axi_master.sv`. It is held to the AXI3 protocol,
to read-back, and to the layout muir's `src/fabric.rs` documents.

The boundary between them is the cable itself. The window drives twenty
signals towards the machine and reads eighteen back, and every one of them is
a wire on MIT's connector. That is the same boundary the project already draws
between `rtl/machine/` and `rtl/plumbing/`.

## What crosses the cable

The debugger drives `-DEBUG IN REQ`, `DEBUG IN A<1:0>`, `DEBUG IN WR` and
`DBD<15:0>`. The debuggee drives `DEBUG IN ACK` and, when it has something to
say, `DBD<15:0>`.

The two address bits select one of four strobes. They are address bits 3 and 2
of the debugger's own Unibus cycle into `0o766100` to `0o766137`, and the
debuggee's 74S139 decodes them while `-DEBUG IN REQ` is down.

| `A<1:0>` | debugger's address | strobe | what this fabric does |
|---|---|---|---|
| 0 | `0o766100` | `-DB NEED UB` | a cycle on the debuggee's Unibus at the latched address |
| 1 | `0o766104` | `-DB READ STATUS` | drives the error status onto `DBD<7:0>` |
| 2 | `0o766110` | `-DB ADR1 CLK` | clocks `DBD<2:0>` into the modifier register |
| 3 | `0o766114` | `-DB ADR0 CLK` | clocks `DBD<15:0>` into the address latches |

The three register strobes are acknowledged the instant they are made. That is
combinational on the board, the 74S10 at DBGIN 0A14, and it is combinational
here. A cycle is acknowledged when the slave answers and never otherwise.

The latches take `DBD` at the strobe's trailing edge, which is when the
request lifts. So the levels must still be standing at the lift.

## What crosses is levels, and the hundred nanoseconds

The wires are held for the whole request. Nothing on this cable carries
information by an edge alone. Every decision the debuggee makes is made from a
level that is standing.

The data, the address bits and the write flag are on the cable one hundred
nanoseconds before the request. That is not a convention. `-DEBUG OUT REQ` is
`NAND(SELECT DEBUG, SELECT DEBUG DLYD)` at DBGOUT 0A11 and the delay is the
MTD100 at 0A10, so the request falls one delay-line section after everything
else is already standing. muir calls this `busint::DEBUG_OUT_REQUEST_NS`.

The window reproduces that lead inside the fabric, where it is free. A store
to `CTL` puts the levels on the cable at once and asserts the request twenty
ticks later.

A debugger must therefore hold a request for at least those twenty ticks. A
request lifted inside its own lead makes no strobe at all, which is what the
real cable does too. `-DEBUG OUT REQ` is low only while `SELECT DEBUG` and its
delayed copy are both high, so a select shorter than one section never brings
the request down either. muir cannot reach that, because an AXI round trip
through the interconnect is many times 200 nanoseconds. The check's own first
draft did reach it, twice, and measured nothing until it was fixed.

The levels are held past the lift by never being cleared. The debuggee's
latches take `DBD` at the trailing edge of their strobe, so a carrier that
cleared the lines as part of lifting would write the wrong word into the
debuggee's address or modifier register. `cadr_dbgin.sv` keeps no copy of
`DBD` of its own, which makes that promise load-bearing rather than
decorative.

It is a rule and not a countdown, and that is a correction. The window carried
a trailing section of its own for a while, twenty ticks after the lift during
which no new request would be taken. Nothing could ever reach it.
`cadr_dbgin.sv` latches at the edge after the one that dropped the request, so
the word it takes is the one standing at the end of the lift's own write beat,
and the port cannot deliver a second beat until four ticks later. A twenty-tick
guard in front of a four-tick structural margin is an exemption nothing
exercises. It was removed, and the check measures the margin every run
instead: seven ticks, with the lift and the next request stored back to back.

## The whole request crosses in one store

This is what answers the hazards the cable has no defence against. A late
address bit makes the wrong strobe. A late data line is latched instead of the
intended word. A write flag that moves inside a request inverts the cycle.
None of the three is detected by anything on the cable.

`CTL` is one 32-bit register and a request is one 32-bit store. There is no
ordering for a carrier to get wrong.

A store that does not strobe all four byte lanes is dropped and counts as a
fault. Without that rule a byte store would set `REQ` beside whatever `DBD`
the last store left, which is the split-store hazard arriving by a different
door.

## The window

Sixteen words, sixty-four bytes. Five are used and the rest read `UNMAPPED`.
The layout is muir's `src/fabric.rs`, which documents every field; what
follows is a summary and the fabric's own additions to it.

| word | | |
|---|---|---|
| 0 | `IDENT` | reads `DBUG`, `0x44425547` |
| 1 | `CTL` | the request, whole, in one store |
| 2 | `STS` | the answer, in one load |
| 3 | `CLEAR` | a store of `LIFT`, `0x4C494654`, lifts and clears |
| 4 | `FAULTS` | a count and three sticky faults |
| 5 to 15 | | `UNMAPPED`, `0xBBBDAAB8` |

`IDENT` is `DBUG` with `D` in the most significant byte. These are 32-bit
registers on a 32-bit port, so a load returns the register's value unchanged
and byte order never enters. This is the same convention as `CONS` for the
console, `PACK` for the disk pack side, and `NONE` for a general-purpose port
brought out with nothing of ours behind it.

`STS` carries a two-bit marker reading `01` in bits 15 and 14. A word of all
zeros gives `00` and a word of all ones gives `11`, so neither can be mistaken
for an answer. The marker has to live outside the data field, because all ones
in `DBD` is what an open cable reads and is a legal answer.

`STS` reports the acknowledgement and the word as they were latched at the
instant `DEBUG IN ACK` first rose, not as they stand at the load. By the time
the Arm gets round to reading, the fabric has run for however long the core
took, and the word the debuggee drove may be long gone.

The latch is in the carrier and not on the board, and that is a decision. A
read cycle's word is driven live by `cadr_dbgin.sv`, as the transceivers drive
it from `UDI` while the cycle runs. MIT's own note about the diagnostic
registers is that read and write at the same address are uncorrelated: the
74LS244s drive `SPY<15:0>` asynchronously, so a running machine moves the lines
under a standing acknowledgement. Whoever is watching is the one that has to
latch, which is what `cable::DebugIn::observe` does on the simulated side. Two
latches in one path would be two places a mutation could be made and neither
caught.

A four-bit sequence number crosses in `CTL` and comes back in `STS`. An
acknowledgement left standing from a previous transaction reads exactly like
an answer to the present one, and the sequence is what tells them apart.

## The status read drives only the low byte

`-DB READ STATUS` enables the Am8304 at REQERR 0B15, which drives `DBD<7:0>`
and nothing above it. The high byte is undriven and the cable's pull-ups carry
it, so a status read reads `0xff00 | status`.

The fabric keeps that split where it belongs. `cadr_dbgin.sv` drives the low
byte and says so with a byte-wise enable; `cadr_debug_window.sv` resolves an
undriven byte as ones, because that is what the SIP at DBGIN 0A22 does. muir's
`Rtl::try_debug_request` already writes the answer as `0xff00 | status`, so
the adapter must not zero it.

Five of the eight status bits are live. `Machine::debug_status` is
`bus_error | NOT_FREE | WRITE_THROUGH`, and the eight lines the 8304 takes are
the bus interface's error status register at `0o766044`. Seven of them are
`rtl/machine/cadr_busint_regs.sv`'s, and four of those seven are flops it
holds: the two NXM bits, `UB MAP ERROR` and `WRITE THROUGH ENB`. The eighth is
`-FREE`, which is not a flop of that register at all. It is the interface's own
busy, `Busint::busy`, and here it is `cadr_busint_xbus.sv`'s `busy`.

The seven are one expression in `cadr_busint_regs.sv`, because the 74LS244 at
REQERR 0C16 reads the same seven for `0o766044` and on the board there is one
set of nets. `rtl/machine/cadr_memory_path.sv` joins `-FREE` to them at the
instantiation, which is where REQERR joins them.

The bit positions are the pins. 0B15 pin 1 pairs with pin 19, which is
`XB NXM ERROR` on `DBD0`; pin 8 pairs with pin 12, which is
`WRITE THROUGH ENB` on `DBD7`. The 244 agrees independently, and both give
`machine::bus_error` and `busint::error_status`.

Bits 1, 2 and 4 are zero and always will be. They are `XB PAR ERROR`,
`LM ADR PAR ERROR` and `LM PAR ERROR`. muir says why: the rest of the register
is parity errors, which cannot happen here.

A read of `0o766044` by the processor always finds bit 6 set, because that read
is itself a cycle of the interface's. `Machine::interface_read` writes the bit
as a constant for that reason and this fabric does the same. The debugger's
strobe is not a cycle of the interface's at all, so it finds the bus as it
stands. That is the one bit of the eight the cable and the register read
differently, and it is the same wire on the board.

### The status strobe has one tick where a cycle has twenty-five

This is a hazard worth naming rather than leaving to be found, and it is
measured rather than reasoned.

`rtl/plumbing/xilinx7/cadr_debug.xdc` relaxes every path into the carrier's
`sts_dbd` register to four ticks, and the argument it gives is the debug
CYCLE's: the diagnostic register block answers `busint::DIAGNOSTIC_NS` after
`-UB MSYN`, so the word has had twenty-five ticks to settle by the time
`DEBUG IN ACK` rises. A `-DB READ STATUS` strobe is not like that. It is
acknowledged the instant it is made, the 74S10 at DBGIN 0A14, so the carrier
captures one tick after `-DEBUG IN REQ` falls and the byte has had exactly one.
While the byte was a constant zero nothing could move inside that tick. Four of
its bits are flip-flops now.

Measured on the routed memory-on board, with every one of these paths carrying
the 40 ns requirement the exception gives them:

| path | levels | delay |
|---|---|---|
| the read cycle's word, `vma_reg[14]` through the map | 25 | 28.453 ns |
| the error flops, `err_xbus` and `err_map` | 6 | 6.376 ns |
| the select, the carrier's own `dbg_in_req` | 3 | 6.411 ns |

So the byte's own arcs are inside a single 10 ns tick with about 3.6 ns to
spare, and the exemption is wider than they need rather than wrong for them.
The `-FREE` term was not resolved separately by cell name in that query and is
not quoted; it joins the same expression as the other seven and is bounded
above by the 28.453 ns worst path, which is the read cycle's and not this one.

## The timeout belongs to the debugger

The debuggee runs no timer for this master. A cycle at an address nothing
answers is never acknowledged. The debugger gives up, lifts the request, and
that is the whole of it. muir's own interface does that at
`busint::DEBUG_TIMEOUT_NS`, which is 11.05 microseconds and is the REQTIM
PROM's second table.

That is not the bus's ordinary 4.25 microsecond NXM timeout, and the two are
related in a way worth stating. While a debug cycle stands, the debug master
holds the debuggee's Unibus, and the machine's own Unibus cycles wait. A
machine cycle that waits longer than 4.25 microseconds becomes an NXM. So a
standing debug cycle can turn a legitimate memory reference of the machine's
into a non-existent-memory error.

That is faithful. It is what the real board does, and it is why CC halts the
debuggee before it does anything else. It is also why the watchdog below
cannot protect the machine and is not meant to.

## The watchdog, and why one second is enough

If muir is killed with a request standing, `-DB NEED UB` stays down, the debug
master keeps the Unibus, and the machine's own cycles wait for ever. On a real
lashup unplugging the cable ends that, because the SIP at DBGIN 0A22 pulls
`-DEBUG IN REQ` up. In fabric there is nothing to unplug, so the window lifts
a request that has stood longer than a dead-man interval and sets a bit in
`FAULTS`.

The interval's only job is to be far longer than any legitimate hold. It
cannot be short enough to save the machine from an NXM, because 4.25
microseconds is shorter than any round trip through a mapped load and a
process that may be preempted. Anything under a second would risk lifting a
live transaction on a busy host; anything over it leaves a wedged bus wedged
for longer than a person will wait. One second is a floor with margin and is
not derived from anything.

`WATCHDOG_T` is a parameter for exactly that reason, and the check shrinks it.
A bound nothing exercises is not a bound.

## The modifier register

Three bits, taken from `DBD<2:0>` at the trailing edge of `-DB ADR1 CLK`.

Bit 0 is address bit 17. The eighteen-bit Unibus address is `UAO<16:1>` from
the two 74LS374s, this bit above them, and zero in bit 0.

Bit 1 resets the debuggee's Unibus and bus interface. It crosses the
debuggee's own cables to OLORD2 and is that processor's power-on reset, so it
clears `RUN` and halts the machine. CC's reset of the debuggee goes down the
cable and needs nothing else.

Bit 2 turns off the debuggee's NXM timeout, for all of its cycles and not only
the debugger's.

`cadr_dbgin.sv` brings bits 1 and 2 out as ports. `tb/cadr_dbgin_harness.sv`
wires bit 1 to the machine's reset the way the fabric wires it, joined with
the board's own reset and registered, so the check holds it. Bit 2 has no
consumer yet and is named under "What is not built" below.

The DBGIN page takes the board's reset and not the one it makes. MIT calls bit
1 "Resets the debuggee's Unibus and bus interface", which reads as though this
page should be in it, and it must not be. The bit is a level: "write a 1 here
then write a 0". A modifier register cleared by its own bit 1 clears the bit
that is clearing it, so the reset becomes a one-tick pulse and MIT's own
sequence cannot be written at all. This was measured here before it was
understood.

## What the debug cycle reaches in this fabric

A debug cycle runs on the debuggee's Unibus at the latched address. This
fabric's Unibus has three slaves: the diagnostic register block at `0o766000`,
`rtl/machine/cadr_spy_registers.sv`; the I/O board at `0o764100`,
`rtl/machine/cadr_io_board.sv`; and the bus interface's own registers,
`rtl/machine/cadr_busint_regs.sv`, which are the interrupt block at
`0o766040`-`0o766076` and the Unibus map at `0o766140`-`0o766176`.

The register block is the one that matters, because it is CC's whole
vocabulary. `spy_write(CLK, 0)` halts the machine and `spy_read(PC)` reads its
program counter, and both are ordinary Unibus cycles at `0o766000` plus twice
the register number. So muir over this cable can do to the machine what muir
over the lashup does to a simulated one.

**And a debug cycle reaches main memory.** The Unibus map is built, and so is
the mapped window at `0o140000`-`0o177777` that translates through it: a
foreign master's cycle there is an Xbus cycle at the translated address, which
is `Machine::mapped_read` and `Machine::mapped_write`. The debug cable is the
master those two were written for, `Rtl::try_debug_request` being the only
place in muir that makes a map responder at all. `ub_foreign` in
`rtl/machine/cadr_memory_path.sv` is the arbiter's grant to this master or to
the console, and the machine's own cycle at the same address is not mapped: it
goes through `busint::decode`, which answers `Responder::NoUnibus` over the
whole window.

The window's own limits are its module's and are not the cable's. A mapped page
that is not main memory is never acknowledged, which is muir's own decision:
`Busint::debug_xbus_edge` says the processor asking for the Xbus meanwhile, and
a mapped page nothing answers, are not modelled, because the debuggee CC works
on is halted and its map points at memory. A page whose `MAPVALID` is down, or
whose `WRITEOK` is down on a write, sets `UB MAP ERROR` and is never answered
either. In both cases the debugger's own timeout is what ends the cycle, which
is what happens to any cycle nothing answers.

`-UB TO MD` is built. A write of the odd word through a page whose high five
bits are ones is CC's `CC-WRITE-MD`, and the two halves go into the
processor's `MD` instead of onto the Xbus. MIT's gate is `NAND(UBMA<21:17>,
UBXRQ, -UBRD, MSYN IN)` at REQU 0D12. It holds the Xbus request off at REQLM
0E09, so such a cycle never takes the bus at all, and `UB MD LOAD`,
`NOR(-UB TO MD, -UBX GRANT)` at REQLM 0B17, is a term of `-LOADMD` at 0C10 and
of `-LOADMD ACK` at 0A11, which answers the cycle.

`rtl/machine/cadr_busint_regs.sv` decodes it, puts the request up
`busint::UB_XBUS_REQUEST_NS` after `-UB MSYN` and latches the thirty-two
lines; `rtl/machine/cadr_memory_path.sv` carries them out of the module; and
`rtl/machine/cadr_microcycle.sv` takes the word. `MD` has three writers now:
the instruction's own store, the bus word from `-LOADMD`, and this. The third
is taken only while the other two are quiet, which is muir's own gate written
on this side of the cables, and `-UB SSYN` follows `busint::UB_MD_ACK_NS`
after the load.

A read through such a page is not a read of `MD`. `Rtl::try_debug_request`
tests the direction before it tests the page, so the odd word of a read is the
page's read buffer and the even word is a mapped Xbus cycle at physical page
`0o37000`, which is the Unibus and not main memory. `MD` is write-only through
the map.

## The debug master is the third master on the diagnostic bus

`rtl/machine/cadr_console_bus.sv` is the arbiter. It had two masters: the CADR
itself, whose microcode writes the mode register at `0o766012`, and the
console on `M_AXI_GP1`. The debug master is the third.

The debug master wins against the console. On MIT's board the 74LS74 at UBMAST
0D02 is first on the `NPG1 IN` chain, so the debug master is the highest
priority master there is. The console has no counterpart on MIT's board at
all, so its priority is a decision rather than a reading, and this is the
right way to take it: the debug master is the machine's own, the console is
ours, and the console's own bound already covers what it costs. The console
gives up after `LOST_T` ticks and reports `lost`, which is a bound nothing
else on that bus has.

Neither takes the bus while the processor's own strobe is down. That rule was
already there for the console and the reason is unchanged: a strobe masked in
the middle of a cycle is a cycle that never answers, and the processor's own
NXM timer is what would find it 4.25 microseconds later.

## Where the window sits: decided, and why the second of three

`README.md` once put the console on `M_AXI_GP0` and the debug cable on
`M_AXI_GP1`. The console took `M_AXI_GP1` instead, and the note left behind
said to settle the question when the adapter was built. It is built, and the
answer is the second of the three the question had.

The constraint that shapes the answer is the GP0 hang. A read that nothing in
the fabric answers inside a general-purpose port's window does not fault the
Arm. It hangs both cores at one program counter each, and no software guard
can catch it. This was measured on the board. So a slave that owns a
general-purpose port must answer the whole of it.

The XC7Z020 has exactly two `M_AXI_GP` ports. There is no third.

**One: the adapter takes `M_AXI_GP1` and the console moves to `M_AXI_GP0`.**
Rejected. `M_AXI_GP0` already carries three faces behind
`rtl/plumbing/cadr_gp0_split.sv`, so the console would be a fourth page rather
than a decode somebody has to write, and that answers two of the objections
this paragraph used to raise. What is left is the one that decides it: GP0 is
the port where an unanswered read has actually frozen this board, and it
carries the machine's own disk traffic on every boot, 42,967 blocks of it.
Option one puts new logic in front of that.

**Two: the adapter shares `M_AXI_GP1` behind a split.** Taken.
`rtl/plumbing/cadr_gp1_split.sv` owns the port, routes a transaction to the
console or to the carrier by address, and hands everything else to
`cadr_gp0_default.sv`. Nothing on `M_AXI_GP0` changes at all. The carrier goes
behind it unchanged, being a whole-port slave already, and the console keeps
its own `REG_BASE`, so `cadr-console` does not move and `build/console.pass`
is unchanged.

**Three: the adapter is a second face behind the console's own AXI front
end.** Rejected on checkability. It puts the adapter's address match
downstream of the console's, and a mutation aimed at a match behind an
exhaustively checked guard tests the guard and not the thing. The display's
`tv-answers-its-neighbours` survived for exactly that reason.

Neither option two's cost nor option three's was measured, so neither is
quoted. The decision turns on those two facts and not on lines of code.

The map the port now has:

| | | |
|---|---|---|
| `0x8000_0000` | `cadr_console.sv` | thirty-two words, `CONS`, its own `UNMAPPED` in the rest of its page |
| `0x8000_1000` | `cadr_debug_window.sv` | sixteen words, `DBUG`, its own `UNMAPPED` in the rest of its page |
| everything else | `cadr_gp0_default.sv` | `NONE` to every read, OKAY to every write |

So muir is given `--debug-cable-connect 0x80001000`.

The default slave's name says GP0 and it is used on both ports. It is a
whole-port slave with no address on it at all, so it is the same thing on
either one and a second copy would be two descriptions of one thing. Renaming
it moves that port's check, two Makefile lists and two mutation records, which
is a change worth making on its own rather than inside this one.

`build/gp1_split.pass` is what holds the arrangement. It reads all 262,144
pages of the port. Each page's word must name the slave that answered, so the
routing is read off the reply rather than assumed. It then sweeps every word
of the two pages, runs a write and a read to different pages at once, and
reaches the same sixteen diagnostic registers by both of the two roads the
port now has.

## The check

`build/dbgin.pass` is the falsifiable statement of all of this. It is
`tb/cadr_dbgin_harness.sv` and `tb/cadr_dbgin_tb.cpp`, and the Makefile runs it
with the rest.

The harness was written as the attachment before the attachment landed, and
it is now the same lines the board carries. It puts the window, the DBGIN
page, the real arbiter, the real register block and the real processor
together, and the processor runs MIT's boot PROM out of `build/rtl.golden`. So
the claim is muir's own: a debugger over MIT's own cable halts this machine and
reads a program counter whose value muir wrote down.

What it measures rather than assumes, reported on its own output:

- the levels stand twenty ticks before the request and at least seven past the
  lift, over thirty-one lifts, and no level ever moves on the tick the request
  does;
- `DEBUG ACK` rises on the tick the request falls for each of the three
  register strobes, and seventy-four ticks later for a cycle;
- the grant to `-UB MSYN` is twenty ticks, `-UB MSYN` to the register block's
  `-UB SSYN` is fifty-one, and the lift to `DBUB MASTER` clearing is twenty;
- a cycle at an address nothing answers is never acknowledged over two
  thousand ticks, which is twice the debugger's own timeout and five times the
  bus's;
- the watchdog lifts a request that has stood too long, says so in `FAULTS`,
  and gives the machine its Unibus back;
- all 600,000 microcycles still agree with muir, column for column, after the
  cable has halted the machine, read it and started it again.

Fourteen mutation records are aimed at it in `mutations/list.txt`.

`build/gp1_split.pass` is the second check, and it holds what the first
cannot. `build/dbgin.pass` gives the carrier the whole port, so it says
nothing about a port the carrier shares. This one puts the real splitter, the
real console, the real carrier and the real default slave together, exactly as
`boards/arty-z7-20/cadr_arty.sv` does, and puts MIT's cable between the
carrier and `cadr_dbgin.sv` behind them.

What it measures rather than assumes:

- all 262,144 pages of the port answered, each with a word that says which
  slave answered;
- every word of the two pages and a spread over the rest of the gigabyte,
  read and written, with every address, length and ID poisoned the tick its
  handshake completed;
- thirty-two rounds with a write and a read to different pages in flight at
  once, which is the only stimulus that sees one held selection serving both
  channels;
- all sixteen diagnostic registers read by both roads, giving the word the
  harness supplied;
- the error status read back as `0xff00 | status`;
- MIT's own reset sequence over the cable, with the level standing two hundred
  ticks between the write of a 1 and the write of a 0.

Six mutation records are aimed at the splitter and one at the board's wiring.

`build/unibus.pass` is the third check, and it holds what neither of the first
two can. `build/dbgin.pass` gives the cable its own machine, with one Unibus
slave on it and no map; `build/busint_regs.pass` holds the mapped window at its
own seam, with the Xbus half two ports a testbench drives. Neither has the
cable and the window in one design, and until they are in one design a debug
cycle cannot reach main memory.

That check's DUT is `rtl/machine/cadr_memory_path.sv`, so the master is the
`cadr_dbgin` the board carries and the arbiter is the module the board
instantiates. The testbench stands where the carrier stands and drives the
cable and nothing else.

What it measures rather than assumes:

- all sixteen diagnostic registers read over the cable, each giving a word the
  testbench drove from the address it was driving and never from `spy_eadr`;
- a mode register write over the cable moving `PROMDISABLE`, which is a wire
  out of the machine;
- a map entry written and read back over the cable at `0o766146`, which is
  above `0o400000` and so carries address bit 17 in the modifier register;
- a mapped read, a mapped write and a read back through the map, with the
  cable as the master, reaching the machine's own memory port at the byte
  address `cadr_ddr_map::main_byte_address` gives muir's own translated page;
- the odd word answered out of the read buffer with no memory cycle at all;
- a cycle through a page whose `MAPVALID` is down never acknowledged over two
  thousand ticks, and `UB MAP ERROR` set by it;
- the error status byte read back over the cable eight times, high byte `0o377`
  every time, with each of its five live bits made true by driving the machine
  first and the three parity bits never seen set at all.

Five mutation records are aimed at the join and at the cable's place on the
arbiter.

## The cable on two Pmod connectors

The register window is one transport. A second board is the other, and it is
built. `rtl/plumbing/cadr_dbg_pmod.sv` puts MIT's cable on eight Pmod pins and
`rtl/plumbing/cadr_dbg_join.sv` lets the connector and the window share one
DBGIN page. JA carries DBGOUT and JB carries DBGIN.

### Four pins each way, not one clock and seven data

One Pmod cable joins one board's DBGOUT connector to another's DBGIN. Its
eight wires therefore carry both directions: twenty signals towards the
debuggee and nineteen back. The drawing described that as one clock and seven
data, which is a half-duplex arrangement with the seven data lines shared and
turned around. That is MIT's own arrangement one connector along, where the
Am8304s at DBGOUT 0B21 and 0B22 face whichever way `-DEBUG > UD` says. It is
not available here, for two reasons.

The first is a pin. A receiver clocked by the cable needs a clock-capable
input. Digilent's master file marks exactly one pair on the two headers:
JA3_P and JA3_N, package pins U18 and U19. JB has none at all. The connector
that would have to receive the clock is the one that cannot.

The second is the turnaround. Two sets of drivers sharing seven wires must
agree on the instant one stops and the other starts, and they have no back
channel to agree on. A turnaround that misses does not corrupt a word. It puts
two drivers on one wire.

So the eight pins are split four and four: one strobe and three data lines in
each direction. Nothing is shared and nothing is turned around. The eighth
wire is a strobe rather than a clock, because nothing on either side is
clocked by it. It is sampled through two flops like any other asynchronous
input.

### Eight beats each way

Twenty signals cross in each direction. A frame must also say that it is a
frame, because a connector with nothing on it reads as a constant, and a
constant is indistinguishable from twenty levels that happen to be all ones or
all zeros. The answer is the two-bit marker this document already describes in
`STS`: all zeros reads `00`, all ones reads `11`, and a frame is taken only on
`01`.

Twenty payload bits and two marker bits is twenty-two, and twenty-two over
three lines is eight beats. Eight beats is twenty-four slots, so two are zero
fill, which the receiver checks as well. The beat count is eight each way, and
the reason it is eight rather than seven is the marker.

The count written down before anything was built was four out and three back.
That was right for its own premise: twenty signals over seven data lines is
three beats, and twenty-two is four. What does not hold is the premise,
because a connector has to carry both directions.

### The gap is the frame marker

A receiver with no clock has to know which beat is beat zero. It is told by
the silence. The sender emits its eight beats six ticks apart and then leaves
the lines alone for eighteen. Any interval longer than twelve ticks with no
transition is between frames, so the next transition is beat zero. That costs
no wire and no slot.

The marker and the gap answer different questions and both are kept. The gap
says where a frame begins. The marker says whether what arrived was a frame at
all.

### What the carrier promises

A level put in at one end stands at the other until it is replaced. Nothing is
ever cleared and nothing is a pulse, because the debuggee's latches take
`DBD<15:0>` at the trailing edge of their own strobe.

A frame is presented whole or not at all. That is the promise that matters
most. This document already names three hazards the cable has no defence
against. A late address bit makes the wrong strobe. A late data line is
latched instead of the intended word. A write flag that moves inside a request
inverts the cycle. The window answers all three by making a request one 32-bit
store, and a carrier that delivered a frame beat by beat would hand every one
of them back. So the sender takes its snapshot once, at the first beat, and
the receiver moves its outputs once, at the last.

A connector with nothing on it presents zeros, which is the idle cable:
`-DEBUG IN REQ` up and `DEBUG IN ACK` down. A connector that goes quiet while
a request stands is taken to have been unplugged after `LOSS_T` ticks, and the
levels go back to idle. On a real lashup the SIP at DBGIN 0A22 does that when
somebody pulls the cable.

### What the two connectors carry on this board

JB is a second board's debugger arriving at this machine's DBGIN page. It
joins the window's cable at `cadr_dbg_join.sv`. The rule there is that the
first to assert holds until it lifts, with a tie going to the window. Nothing
pre-empts, because a request that changes hands halfway is a request built
from two debuggers, and a modifier register that takes a stray one in bit 1
resets this machine.

JA carries this board's own debugger outward, so a second board plugged in
there sees the requests the emulator makes. What comes back is carried into
the fabric and folded rather than consumed. That is a decision and not an
oversight. This board's window already has a debuggee, its own machine, and
taking a second one's answer as well would mean deciding which of two
debuggees on one debugger's cable an acknowledgement came from. MIT's
`DBD<15:0>` is an open-collector bus and would give the OR of them, which is a
lashup rather than a design. Consuming it wants a second window at a second
address behind `cadr_gp1_split.sv`, and that is not the carrier's decision to
take.

The pin roles are mirrored between the two headers, so a straight Pmod cable
maps pin one to pin one.

**A cable from one board's JA to its own JB is not a loopback test, and it is
worse than useless.** JA carries what the window is asking, and the window is
already asking it at the join directly, so the returning copy arrives about a
frame late at an arm that is not preferred and contributes nothing. Then the
window lifts, the join sees no request from the near arm, and the echo is
still standing for the rest of a frame: it is taken as a new request from the
far arm and performed a second time. The join is right and the cable is the
problem. Every request would happen twice.

So the carrier's silicon test needs a second board, and until there is one
what stands behind it is the check, where both ends have their own clock and
every wire can be delayed, shorted or crossed.

### The cable's own requirement on a debugger

A lift is a level like any other and has to cross a frame. On the direct cable
the debuggee sees a lift at the next tick and the structural margin is four
ticks. Over eight pins it is a whole frame, so a debugger that lifted and
asked again inside that would have the far end see one request where it made
two. The check sweeps it. The shortest lift that still latches is fifty-six
ticks, against a frame of sixty-six.

### The carrier's own deadline

The word `cadr_dbgin.sv` drives on `DBD<15:0>` now ends at a frame register
outside the machine as well as at the window's latch. It is the same cone
`rtl/plumbing/xilinx7/cadr_debug.xdc` was written for, one module further out,
and it was measured before it was constrained: -9.779 ns on 3,905 endpoints,
the ten worst all in that one register, twenty-five logic levels from
`vma_reg` to `tx_frame_reg`. `rtl/plumbing/xilinx7/cadr_debug_pmod.xdc` gives
it four ticks, the same number and the same argument, and
`boards/arty-z7-20/vivado/bitstream.tcl` asserts that no other register of the
carrier carries it. With that in place the memory-on board closes at
+0.350 ns on 0 of 47,495 endpoints.

### The check

`build/dbg_pmod.pass` is `tb/cadr_dbg_pmod_harness.sv` and
`tb/cadr_dbg_pmod_tb.cpp`. The testbench is the cable. The harness brings the
eight wires of each connector out as ports, so every wire is delayed, skewed,
shorted, crossed or unplugged by the check rather than assumed to be perfect.

What crosses is poison. Every value sent has its low ten bits the complement
of its high ten, no two values in a run are the same, and none is zero. A
frame delivered half-built, a line shorted or two lines crossed then produces
a word that relation refuses.

The two ends are two boards and have two clocks. One phase runs the model at a
twelfth of a tick so that the far end can be given a different period and a
phase of its own, and each wire a delay of its own.

What it measures rather than assumes, on its own output:

- twenty-four levels each way delivered whole over an ideal wire, the worst
  taking fifty-eight ticks against a frame of sixty-six;
- six levels each way delivered with the far end in phase, out of phase, eight
  per cent slow, eight per cent fast, and nine per cent fast over a long wire;
- a cable pulled while a request stands stops being live and puts its levels
  back to the idle cable;
- a frame of all ones and a frame of all zeros both refused by the marker;
- nine shorted or crossed data lines, every one of them visible;
- the strobe sampled correctly two and a half ticks early and three and a half
  late, against a beat of six;
- eight addresses latched and sixteen diagnostic registers read over the
  cable, the worst round trip two hundred and sixty ticks against the one
  thousand one hundred and five a debugger waits before it gives up;
- the machine halted and started again over the cable;
- a cycle at an address nothing answers never acknowledged;
- the page never changing hands inside a request, with a second debugger
  asking for the modifier register with bit 1 set;
- an unplugged DBGIN connector asking for nothing;
- one board reset while the other keeps running, swept over seventy-one reset
  lengths so that the restart lands at every offset inside a frame, the worst
  taking a hundred and six ticks to come back.

Eleven mutation records are aimed at it and at the board's wiring.

## What is not built

**The composition onto the board is done.** `rtl/machine/cadr_dbgin.sv` is
instantiated in `rtl/machine/cadr_memory_path.sv` beside the three Unibus
slaves, `cadr_machine.sv` passes the cable up as ports, and
`boards/arty-z7-20/cadr_arty.sv` puts `cadr_debug_window.sv` behind the GP1
split and joins the two. The lines are the lines
`tb/cadr_dbgin_harness.sv` was written with, which is what that harness is
for: it was the attachment before the attachment landed, and the arbiter it
instantiates is the module `cadr_memory_path.sv` instantiates rather than a
copy of it.

**The status byte is real**, and what is left of it is three bits that cannot
ever be anything but zero. The section above says which and why.

**The modifier's second effect.** Bit 1, the debuggee reset, is wired: it
leaves `cadr_machine` and joins the board's own reset and the console's pulse
in `boards/arty-z7-20/cadr_arty.sv`, which is where the console's already
landed. It is the one output of the cable that is not in that file's `witness`
fold, because it is read by the reset it drives, and
`the-debuggee-reset-reaches-no-pin` is the record that holds it there.

Bit 2, the timeout inhibit, is a port of `cadr_machine` and nothing consumes
it. It wants the NXM timeout counter inside `cadr_busint_xbus.sv`, which is
held to muir tick for tick over a trace, so it is a change that needs a trace
with a debug cable in it. Until then it is in the fold, which is this
project's rule about building the machine whole: a register the fabric does
not have is a way this is not the CADR, whether or not today's seam can
observe it.

**MIT's own Unibus arbitration for this master.** muir takes the debug master
through `NPR`, `NPG1 IN`, `SACK` and `-UB BBSY`, and
`cadr_busint_xbus.sv` says in its own header that every branch it left out of
its arbitration belongs to the debug cable. This fabric puts the debug master
on the same simple arbiter the console uses. The difference is the one the
console already has and is recorded here rather than hidden: the grant is
taken with the processor's strobe down and held until the master lets go, and
the instants either side of it are not MIT's.

