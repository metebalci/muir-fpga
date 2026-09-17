<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The debug cable, both of its ends

A CADR is debugged by another CADR. The debugger's `DBGOUT` connector goes to
the debuggee's `DBGIN` connector over the twenty-one wires of MIT's debug
cable. This project's fabric carries both ends. Every board is a debuggee, and
a board told to connect is the debugger for a second board on a ribbon between
two Pmod headers.

muir is a debugger too. It runs on a board's own Arm cores and reaches that
board's debuggee end through a window of memory-mapped registers, with ordinary
loads and stores, selected by `--debug-cable-connect 0x<address>`. muir's half
is `src/fabric.rs` on muir's main at `e4d8aeb`, and the specification it was
built to is muir issue #95.

Both ways in have run on a board. The section on what two boards have shown
says what each carried.

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
signals towards the machine and reads nineteen back, and every one of them is
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
to `CTL` puts the levels on the cable at once and asserts the request ten
ticks later, `LEAD_T` in `rtl/plumbing/cadr_debug_window.sv`.

A debugger must therefore hold a request for at least those ten ticks. A
request lifted inside its own lead makes no strobe at all, which is what the
real cable does too. `-DEBUG OUT REQ` is low only while `SELECT DEBUG` and its
delayed copy are both high, so a select shorter than one section never brings
the request down either. muir cannot reach that, because an AXI round trip
through the interconnect is many times 100 nanoseconds. The check's own first
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

This is what answers the hazards the cable has no defense against. A late
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

`STS` reports the acknowledgment and the word as they were latched at the
instant `DEBUG IN ACK` first rose, not as they stand at the load. By the time
the Arm gets round to reading, the fabric has run for however long the core
took, and the word the debuggee drove may be long gone.

The latch is in the carrier and not on the board, and that is a decision. A
read cycle's word is driven live by `cadr_dbgin.sv`, as the transceivers drive
it from `UDI` while the cycle runs. MIT's own note about the diagnostic
registers is that read and write at the same address are uncorrelated: the
74LS244s drive `SPY<15:0>` asynchronously, so a running machine moves the lines
under a standing acknowledgment. Whoever is watching is the one that has to
latch, which is what `cable::DebugIn::observe` does on the simulated side. Two
latches in one path would be two places a mutation could be made and neither
caught.

A four-bit sequence number crosses in `CTL` and comes back in `STS`. An
acknowledgment left standing from a previous transaction reads exactly like
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
`sts_dbd` register to six ticks, and the argument it gives is the debug
CYCLE's: the diagnostic register block answers `busint::DIAGNOSTIC_NS` after
`-UB MSYN`, so the word has had twenty-five ticks to settle by the time
`DEBUG IN ACK` rises. A `-DB READ STATUS` strobe is not like that. It is
acknowledged the instant it is made, the 74S10 at DBGIN 0A14, so the carrier
captures one tick after `-DEBUG IN REQ` falls and the byte has had exactly one.
While the byte was a constant zero nothing could move inside that tick. Four of
its bits are flip-flops now.

Measured on the routed memory-on board while the exception was four ticks, with
every one of these paths carrying the 40 ns requirement it gave them:

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
a mapped page nothing answers, are not modeled, because the debuggee CC works
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
| `0x8000_0000` | `cadr_console.sv` | ninety-six words, `CONS`, its own `UNMAPPED` in the rest of its page |
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

- the levels stand ten ticks before the request and at least one past the
  lift, and no level ever moves on the tick the request does. At the 5 ns grid
  the lead was twenty and the margin past the lift measured seven, over
  thirty-one lifts;
- `DEBUG ACK` rises on the tick the request falls for each of the three
  register strobes, and for a cycle no sooner than the grant and the slave
  take together, thirty-six ticks;
- the grant to `-UB MSYN` is ten ticks, `-UB MSYN` to the register block's
  `-UB SSYN` is twenty-six, and the lift to `DBUB MASTER` clearing is ten;
- a cycle at an address nothing answers is never acknowledged over two
  thousand ticks, which is 20 microseconds: longer than the debugger's own
  11.05 microsecond timeout and more than four times the bus's 4.25;
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

## The cable on one Pmod connector

The register window is one transport. A second board is the other.
`rtl/plumbing/cadr_dbg_tx.sv` and `rtl/plumbing/cadr_dbg_rx.sv` are the
carrier: one direction of MIT's cable on four Pmod pins, a sender and a
receiver. `rtl/plumbing/cadr_dbg_cable.sv` puts one sender and two receivers
on ONE Pmod header and decides which four of its eight pins this board drives.
`rtl/plumbing/cadr_dbg_join.sv` lets that connector and the window share one
DBGIN page.

**One connector a board, and the other headers carry nothing.** A board is a
debugger or a debuggee on this cable and never both at once, so a second
header would buy only the case of a board debugging one machine while another
debugs it. On the two Zynq boards the register window already covers that
case: muir on those boards' own Arm cores reaches the DBGIN page whatever the
connector is doing.

**Which connector is the board's own decision, and both boards say JA.** Each
has two headers and nothing in its pin file tells one header from the other. JA
is the connector because a board needs one. A part whose headers are not alike
would want the question asked again --- this link rests on a strobe at the far
end of a ribbon, so a high-speed header would be the one to take.

### What actually crosses, counted off the netlist

MIT's debug cable is twenty-one wires. Four of them go one way: `-DEBUG OUT
REQ`, `DEBUG OUT WR` and `DEBUG OUT A<1:0>`, which the 74S241 at DBGOUT 0A17
drives from the debugger's own Unibus address bits. Sixteen are `DBD<15:0>`,
an open-collector bus that either end may drive. One comes back, `DEBUG OUT
ACK`.

**The bus enable and its direction do not cross.** `-DBD ENB` and `-DEBUG >
UD` are pins 9 and 11 of the two Am8304s at DBGOUT 0B21 and 0B22, and
`data/BUSINT.netlist` shows them driven by the 74S02 at 0B12 and the 74S51 at
0B11 out of `DEBUG ACTIVE`, `DBUB MASTER` and the write line. They are the
debugger's own transceiver controls on the debugger's own board. An earlier
count of twenty-two outgoing signals included them and was wrong.

A serialized carrier has no shared bus, so the sixteen data lines are sent in
each direction separately. Outgoing is therefore twenty: the four control
signals and the sixteen data values. Coming back is nineteen: the
acknowledgment, the sixteen data values, and **two bits saying which bytes of
them this end is driving**. The two extra bits are needed because `-DB READ
STATUS` drives only `DBD<7:0>` and MIT's cable carries the byte above it on
pull-ups that a Pmod ribbon does not have. A count of seventeen coming back
counts the acknowledgment and the data and misses them.

The carrier's payload is twenty-one bits in each direction: MIT's twenty, with
the return's one spare bit going out as zero, and a twenty-first that says
whether the board that sent this frame is the debugger.

**ONE CONNECTOR CARRIES THE WHOLE LINK, IN BOTH DIRECTIONS, four pins each
way.** Each direction is one strobe, one data line and two guards, twenty-four
beats a frame, and neither group is ever driven from both ends. A frame is 162
ticks against the 1,105 the debugger's own interface allows a cycle, so the
beats have room. The section on the budget below spends them.

**A board is a debugger or a debuggee by configuration and never both at
once.** That is what makes one connector enough. Two connectors bought exactly
one thing a single one cannot: a chain of three machines, where a board is
somebody's debuggee and somebody else's debugger at the same time. Nobody needs
that.

**The count written down before anything was built was one clock and seven data
pins, and that is superseded.** The next section but one has the argument: a
clocked receiver is a second clock domain across the whole carrier, and a
shared group turned around is two sets of drivers that must agree on the
instant with no back channel to agree on. The eighth wire is a strobe and
nothing is clocked by it.

**Every other header is unassigned.** They are headers the boards have and
this design has no opinion about.

### Four pins each way, of which two carry signals

The eight pins are split four and four. Each direction is one strobe and one
data line, with a guard beside each of them, driven by one end and sampled by
the other with its own clock. Nothing is shared and nothing is turned around.
The section on the coupled pairs below says why a group of four carries two
signals rather than four.

The alternative was one clock and seven data lines shared and turned around
under it. That is MIT's own arrangement, where the Am8304s face whichever way
`-DEBUG > UD` says. Two things argue against it here. Two sets of drivers
sharing seven wires must agree on the instant one stops and the other starts,
and they have no back channel to agree on; a turnaround that misses does not
corrupt a word, it puts two drivers on one wire. And a receiver clocked from
the cable is a second clock domain across the whole carrier, where the two
boards already have a tick of the same length. What a forwarded clock would
buy is a smaller delay, and delay is the one thing this cable has room for. A
frame here is 162 ticks and the debugger's own interface waits 1,105 for an
answer. The section on the budget below has the arithmetic.

The eighth wire is therefore a strobe and not a clock. Nothing on either side
is clocked by it. It is sampled through two flops like any other asynchronous
input.

Digilent's master file marks exactly one clock-capable pair on the two headers
of each Zynq board, JA3_P and JA3_N, and it is on JA. That pair is in the
debuggee's group here and is of no use to anybody. It is recorded so that
nobody reads the choice of JA as being about it: JA is the connector on these
boards because a board needs one, and the pair is a coincidence.

### Which four pins are this board's

A Pmod ribbon joins pin one to pin one. A cable between two boards' connectors
therefore maps each pin to the same pin at the far end, and which end drives it
has to follow the role.

The four low pins are the debugger's. It drives them and the debuggee listens.
The four high pins are the debuggee's. Neither group is ever driven from both
ends while the two boards hold different roles, which is what makes this full
duplex with no shared pin.

Two of each four carry signals and two are guards. The header's rows are
coupled pairs, so each pair takes one signal and the other line of it is held
at zero. The section on the coupled pairs below has the reason.

**The pads are bidirectional and they have to be**, because the role is not
fixed at synthesis. `cadr_dbg_cable.sv` hands out a tri-state enable a pad, so
the group this board does not own is high-impedance and the far end has it.
Every pad carries a pull-down: an unplugged connector must read zero and not
float, and either group can be the one this board is listening to.

**The pins, per board, from Digilent's own published files.** The index is the
carrier's and the header pin is the one on the connector. **The header is JA on
both boards**, for the reason the section above gives.

| index | header pin | pair | role | Arty Z7-20 JA | Cora Z7-07S JA |
|---|---|---|---|---|---|
| 0 | 1 | first | debugger strobe | Y18 | Y18 |
| 1 | 2 | first | guard, driven low | Y19 | Y19 |
| 2 | 3 | second | debugger data | Y16 | Y16 |
| 3 | 4 | second | guard, driven low | Y17 | Y17 |
| 4 | 7 | third | debuggee strobe | U18 | U18 |
| 5 | 8 | third | guard, driven low | U19 | U19 |
| 6 | 9 | fourth | debuggee data | W18 | W18 |
| 7 | 10 | fourth | guard, driven low | W19 | W19 |

The signal is on the odd header pin of each pair and the guard on the even one.
A guard is driven low by whichever board drives that group, and a board
listening to a group drives no pin of it, guard included. So a group of four
pads is enabled whole or not at all, and `build/dbg_cable.pass` asserts exactly
that on every tick of every phase.

Both files index a header's eight signals in the same order, which is header
pins 1, 2, 3, 4, 7, 8, 9, 10 --- the two signal rows of a twelve-pin Pmod, the
other four being ground and supply. So index `k` is the same header pin on both
boards, and a straight ribbon between them maps every signal to its
counterpart, whichever headers the two ends are. The two boards use the same
package pins as each other. The files are `Arty-Z7-20-Master.xdc` and
`Cora-Z7-07S-Master.xdc` from `github.com/Digilent/digilent-xdc` at commit
`00a3404901f35aa9567b01ecb3f2c233b6efe9f4`. Each board's own `.xdc` keeps
Digilent's schematic names in its comments, so the mapping can be checked
against the board rather than against memory.

### The ribbon can be made the wrong way round, and one was

A Pmod header is two rows. Pins 1 to 6 are one row and 7 to 12 the other. A
ribbon whose connector was pressed on the other way up joins each board's pins
1 to 4 to the other board's pins 7 to 10, in order, and its 7 to 10 to the
other's 1 to 4.

**Two boards were found on exactly such a cable on 14 September.** The board
told to connect drove four pins the far board never listens to and reported
that nothing was answering. The far board heard nothing at all. Then the role
was given back, and each board ended up hearing the other's answers, calling
them a debugger, and refusing to take the role. Neither could be the debugger
until one of them was reset. The cable was a manufactured extension and could
not be re-crimped.

So the wiring is a setting on the console's word 14, with three values.

| setting | what a DEBUGGER does |
|---|---|
| `auto` | drives nothing while it listens on both groups, then finds out |
| `straight` | drives the low four, listens on the high four |
| `crossover` | drives the high four, listens on the low four |

**Only the debugger applies it.** A debuggee always drives the high four and
listens on the low four, whatever the setting says. One end compensating is
what straightens a mirrored ribbon, and two ends compensating would cross it
again.

**The setting is taken when the role is taken.** The console refuses a write
while this board is the debugger, and the connector latches the setting at the
take besides. The two are independent on purpose: the refusal is what a person
is told, and the latch is what the fabric does whatever it is told. The wiring
decides which four pins the board drives, so moving it inside a session would
take the pins out from under a standing cycle.

### Finding the wiring, and what it can and cannot hear

Under `auto` a board that has just taken the role drives nothing at all for one
frame and the carrier's loss interval, and listens on both groups at once. It
can, because there are two receivers and each is nailed to its own four pins.

Idle frames on the high four mean a straight cable, because a debuggee drives
the high four and a straight ribbon lands them on the high four here. The same
frames on the low four mean a crossover. Frames from a debugger on either group
are the two-debuggers case, which the take's own guard refuses.

**Silence names no wiring, and silence is the common case.** A debuggee sends
nothing until it hears a debugger, so two boards freshly reset are two silent
debuggees whatever the cable is. A board that listened, heard nothing and stood
on `straight` for ever would never bring a mirrored ribbon up.

So the fallback moves. The board assumes straight, drives, and waits one probe
interval for an answer. With none it goes quiet for long enough that both its
receivers are telling the truth again, flips the assumption, and drives the
other group. An answer settles the wiring and the alternation stops. The cost
of being wrong is one probe interval; the cost of not alternating is a cable
that never comes up without somebody setting the wiring by hand.

**The quiet interval before each flip is not tidiness.** A receiver whose group
this board is driving is held in reset, so the moment the board lets that group
go it knows nothing about it. Without the quiet interval the next flip but one
would drive that group again on the strength of a counter that had not run, and
the far end's answer would arrive on it. That was measured: 580 pad-ticks
driven from both ends of one cable.

### And a board never drives a group somebody else is driving

Every pad enable is gated on that group's receiver saying nothing is on it.
That one rule keeps one connector with two roles safe in the arrangements the
role rules do not reach: two boards told to connect inside one listening
interval, a probe that lands on a group the far end is still answering on, or a
debuggee whose debugger has not compensated for a mirrored ribbon.

A group being driven with nothing sensible under it is still somebody else's
driver, so the gate is the receiver's activity and not its frames. Activity
decays in two frames rather than in the loss interval, because a sender
free-runs and a gap of a whole frame already means nobody is there.

### What a crossed cable looks like from each end

From the debugger: `cadr-console debug-cable` says `crossover, detected` once
`auto` has found it. With the setting forced the wrong way it says nothing is
answering, and a status read over the cable comes back all ones, which is
exactly what an unplugged connector reads as.

From the debuggee: the console says the connector's frames are arriving on the
four pins this board answers on. That can only happen on a mirrored ribbon,
because on a straight cable nothing but this board ever drives those four pins.
It is bit 8 of word 14.

**The lock-out the bench found cannot happen now.** A debuggee drives only when
it hears a frame whose role bit is set, and an idle board's frames do not have
it, so two idle boards never answer each other. The take refuses for a debugger
and not for activity, so an idle board on the connector blocks nothing.

### The pins of a row are coupled pairs, so each pair carries one signal

The high-speed Pmod headers on these boards route their pins as coupled
differential pairs. Pins 1 and 2 are a pair, 3 and 4, 7 and 8, and 9 and 10,
with 0-ohm shunts where a differential termination would go.

A link that drove all four pins of a row single-ended would have an edge on one
line coupling into the other. The other may be the strobe, and the strobe is
the one thing on this cable a false edge can hurt: a false beat misaligns the
frame it lands in.

**So no pair carries two signals.** The strobe has the first pair of a group to
itself and the one data line has the second. The other line of each pair is a
guard, driven low by whichever board drives that group. The odd header pin of
each pair carries the signal and the even one is the guard, which is the table
in the section on the pins above.

**A guard is driven and not merely left out of the enable.** A quiet line
beside a switching one is only quiet if something holds it, and a floating line
is a capacitor its neighbor charges. So a group of four pads goes out whole,
and a board listening to a group drives no pin of it.

**What it costs is the frame's length and nothing else.** One data line a
direction where there were three makes the frame twenty-four beats where it was
eight, which is 162 ticks against 66. The section on the budget below spends
that against the debugger's own timeout and finds room.

**The counters are kept.** Page 0's word 15 of the console's face carries two:
frames heard, whatever their checks said, and frames refused. Both saturate, at
65,535 and 255, and only a reset of the fabric clears them. `cadr-console
debug-cable` prints both. A guarded pair is an argument and not a measurement,
a ribbon has crosstalk between pairs as well as within one, and a false beat
costs the same whatever made it, so the instrument stays.

**What a false beat costs is bounded and is not a wrong word.** A misaligned
frame fails its marker or its parity, moves nothing, and the levels stand until
the next frame carries them again one frame later. So a bad cable shows as lost
frames and never as wrong values, unless it is frequent.

**The pairing is read off the schematic and the cost is arithmetic. What has
been measured on a board is one asymmetry, and it does not prove coupling.**
Two boards on a real crossed ribbon brought the link up on 15 September with
all four pins of a row driven. The counters then said this: as the debugger,
the Arty Z7-20 refused frames on both of its connects, 163 on one and 185 on
the other. They arrived in bursts rather than at a rate --- 185 inside a single
ten-millisecond window, then about 257,000 frames with none, then the counter
saturating 300 milliseconds after the connect. As the debuggee it refused none
over nineteen seconds with the far board driving, and the Cora Z7-07S as the
debugger refused none over sixteen. So it belongs to one configuration rather
than to one board or one role, and under `crossover` both ends drive the same
group, which means the wiring does not explain it.

That is a reason to take the coupling out of the design and not a measurement
of it. One signal a pair removes the suspect. The two boards have since run the
guarded carrier over that same ribbon, and the bursts are gone: the section on
what two boards have shown carries the counters, and the two frames they do not
account for.

### The budget a frame is spent out of

A debug cycle over the cable is three things: the request frame crossing, the
far machine's own bus cycle, and the answer frame crossing back. Frames run
free, so a level put on the cable waits for the next frame to start.

The worst case each way is therefore a whole frame of waiting plus the frame
itself, which is 162 + 138 ticks with the receiver moving its outputs at the
last beat. The far machine's own bus cycle is at least 36 ticks for a
diagnostic register, and was 74 at the 5 ns grid, and longer for a cycle
through the map. If nothing at the far end
answers at all there is no answer to wait for: the debuggee runs no timer for
this master, which the section on the timeout above says, so the debugger's own
counter is the whole of it.

**What it is spent against is 1,105 ticks.** The debugger's interface gives up
at `busint::DEBUG_TIMEOUT_NS`, the REQTIM PROM's second table, which
`rtl/machine/cadr_busint_xbus.sv` counts as thirteen periods of 85 ticks. That
is 11.05 microseconds, which at the 10 ns grid is both the machine's time and
real time. At the 5 ns grid it was 2,210 ticks.

**Neither figure is left to the arithmetic.** `build/dbg_cable.pass` reports
the slowest debug cycle of its whole run and fails above half the timeout;
`build/dbg_pmod.pass` does the same for the round trips it measures. The
slowest measured was 644 ticks, at the 5 ns grid. Both checks still write the
timeout as 2,210 and hold a round trip to half of it, 1,105 (`kDebugTimeoutT`
in `tb/cadr_dbg_cable_tb.cpp` and `tb/cadr_dbg_pmod_tb.cpp`), so at the 10 ns
grid that bound is the whole deadline rather than half of it. A cycle at an
address nothing answers is a leg of its own in the two-board check: it must
come back with no word at all over more ticks than that table allows, and the
cable must carry the cycle after it.

### Making the frame longer found three numbers that were right by coincidence

None of the three was wrong before. Each was a figure derived from the frame
once and then left standing as a literal, and the frame growing is what told
them apart. They are recorded because the shape recurs.

**The connector's phase counter was sized from the listening interval alone.**
It is loaded with three different intervals: the listen, the probe and the
quiet before a flip. `$clog2(DETECT_T + 1)` covered all three while the probe
was the shorter, and at twenty-four beats the probe is 1,296 ticks against a
listen of 674 with the check's own shrunken loss interval. The load truncated
and a probe ended after 272 ticks. The board's own numbers still fitted, so
only the check saw it. A width derived from one of three loads is a width that
is right by coincidence, and it is the longest of the three now.

**The two-board check held a request's lift for a constant twenty-four ticks.**
Over MIT's cable a lift is seen at the far end within nanoseconds; over this
one it is a level like any other and has to cross a frame. Twenty-four ticks
was enough at sixty-six and is not at 162, and the check said so by failing.
It is written as frames now.

**And the carrier check's board-reset sweep ran seventy-one lengths.** That
sweep is what asks whether the gap realigns an end that came back while the far
one kept running, so it has to cover every offset in a frame, and seventy-one
was a frame and a beat when a frame was sixty-six. Left alone it would have
covered fewer than half of them while the check went on passing, which is the
only one of the three that would have been silent.

**A ribbon between two boards joins their supplies, and that is worth saying
before anybody makes one.** A twelve-pin Pmod header carries ground on pins 5
and 11 and 3.3 V on 6 and 12, and a straight ribbon joins both. The grounds
must be joined. The supplies must not: two boards' regulators tied together is
not something either of them is built for. A cable for this link joins pins 1
to 4, pins 7 to 10 and the grounds, and leaves the supply pins open. **A cable
of this shape exists and the link has run over it.** The one on the bench is a
manufactured extension, which is why the ribbon is mirrored; the section above
says what the fabric does about that, and the section on what two boards have
shown says what the ribbon carried.

### The roles must differ, and the fabric enforces it

Two boards cabled together with nothing set are two debuggees. Neither may
drive the return group, or both would. **A debuggee therefore drives nothing
until it hears a debugger**, which is a strobe transition on the forward group
within the carrier's own loss interval. A board with no cable in it drives
nothing at all, for ever. The cost is one frame of silence at the start of a
session.

Two boards both told to connect are two debuggers. **The second may not take
the role**, and it cannot: a board that can see the forward group being driven
holds its own engagement down and the console has the bit that says why. The
first board told is the one that has it, which is the only rule enforceable
from one end.

**A role may not change under a cycle**, at either end. A debug cycle is a
level held for its whole length at both ends, so a role changing inside one
would leave the far end waiting on a cable that had stopped answering.

**And a board in reset drives nothing.** The activity timer comes out of reset
saying nothing has been heard, and a pad enabled before that value is loaded
is a board claiming a pin group on the strength of a counter that has not run.

### Every board is a debuggee, and one is told to be the debugger

A board with a cable in it and nothing said is a debuggee. It answers a
debugger on the connector exactly as MIT's board answers one on its DBGIN.
This is the power-on state and nothing has to be set to reach it.

A board becomes the debugger by `--debug-cable-connect` in `fpgarc`, which
`S80cadr-disk-packs` applies at boot through the console, or by `cadr-console
debug-cable-connect` at any time. `--debug-cable-wiring auto|straight|crossover`
sets which way round the ribbon was made, and the init script applies it
BEFORE the role, because the fabric refuses a wiring that moves under a board
that already has it. `cadr-console debug-cable-disconnect` returns
it and `cadr-console debug-cable` says which role this board has. The flag
takes no argument because the connector is fixed in the bitstream. There is no
listen flag, here or in muir, because listening is what a CADR always does.

**The role is page 0's word 14 of the console's face.** A write of
`DEBUG_KEY` --- "DBGR" --- asks for the role and a write of its COMPLEMENT
gives it back; every other value is dropped, which is the guard the machine's
reset and the light panel's button already carry and is there for the same
reason. The two keys are a value and its complement rather than two spellings,
so that no partial write of either can be the other, which matters because they
are opposite operations.

**The word reports what this board HAS beside what it was TOLD, and they are
two facts.** Bit 0 is the role, bit 1 the ask, bit 2 whether somebody else is
driving the connector, and bits 3 and 4 whether the far end is driving it at
all and whether what arrives is good frames. Bits 7 to 5 say what came of the
wiring, one value a meaning, and bit 8 says that what is arriving is on the
four pins this board answers on. Bits 15 to 9 count the connects. A board that can see a debugger
already on the connector refuses, so a console that reported the ask alone
would say this board was the debugger when the far one is. The write completes
at once and does not wait for the role: a role is a level and not a pulse, and
a write that waited for a condition that may never come would hang the store
that made it, which is the one failure this project has already had on a
general-purpose port. A program writes and then reads.

The DBGIN page is never switched off. Only the connector changes hands, so a
debugger board stays debuggable through its register window while it debugs
somebody else. A real CADR has both connectors live for the same reason.

### Twenty-four beats each way

Twenty-one signals cross in each direction: MIT's twenty and the one bit that
says whether the board that sent this frame is the debugger. A frame must also
say that it is a frame, because a connector with nothing on it reads as a
constant, and a constant is indistinguishable from levels that happen to be all
ones or all zeros. The answer is the two-bit marker this document already
describes in `STS`: all zeros reads `00`, all ones reads `11`, and a frame is
taken only on `01`.

Twenty-one payload bits, two marker bits and one parity bit is twenty-four, and
twenty-four over one line is twenty-four beats with no slot left over. The beat
count is twenty-four each way, and a frame is 162 ticks at the default beat of
six and gap of eighteen.

**The parity bit catches what the marker cannot.** The marker says a frame is
a frame and says nothing about the bits under it. One line shorted, one beat
sampled at the wrong instant or one bit flipped in the cable would otherwise
arrive as a level and be taken. The parity is over the payload alone, so any
odd number of bits wrong in it moves nothing at this end and the previous
levels stand. That is the same refusal a bad marker gets. Neither is a code
that can correct anything, and neither should be: the far end sends the levels
again one frame later, so refusing a frame costs one frame.

**It was eight beats over three data lines a group.** That frame had a slot to
spare, which went out as zero fill. One signal a coupled pair took the two
spare data lines of each group away, so the same twenty-four slots are now
twenty-four beats.

The count written down before anything was built was four out and three back.
That was right for its own premise: twenty signals over seven data lines is
three beats. What does not hold is the premise, because one connector has to
carry both directions and the pairs leave one data line a group.

### The gap is the frame marker

A receiver with no clock has to know which beat is beat zero. It is told by
the silence. The sender emits its twenty-four beats six ticks apart and then
leaves the lines alone for eighteen. Any interval longer than twelve ticks with
no transition is between frames, so the next transition is beat zero. That
costs no wire and no slot.

The marker and the gap answer different questions and both are kept. The gap
says where a frame begins. The marker says whether what arrived was a frame at
all.

### What the carrier promises

A level put in at one end stands at the other until it is replaced. Nothing is
ever cleared and nothing is a pulse, because the debuggee's latches take
`DBD<15:0>` at the trailing edge of their own strobe.

A frame is presented whole or not at all. That is the promise that matters
most. This document already names three hazards the cable has no defense
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

### This board as the debugger: the DBGOUT page

`0o766100` to `0o766137` is the debug block, and it is the four registers CC
writes. `rtl/machine/cadr_busint_regs.sv` holds them now. The decode is Y2 of
the same 74S139 at UBCYC 0E07 that splits the other three blocks off address
bits 6 and 5, and address bits 3 and 2 choose which of the four strobes goes
out: the cycle at `0o766100`, the status at `0o766104`, the modifier at
`0o766110` and the address at `0o766114`. Bits 4 and 1 are not decoded, so the
four repeat through `0o766137`.

`-DEBUG OUT REQ` follows `-UB MSYN` by a delay-line section, which is
`busint::DEBUG_OUT_REQUEST_NS`. The levels under it are held from that instant
and stand past the master's lift, because the far end's latches clock on the
trailing edge of their own strobe.

**With no cable the pull-up answers.** muir's own arm for a machine with
nothing plugged in is `-UB SSYN` at `-UB MSYN` itself, and the sixteen lines
read as ones. So a CADR with a bare connector reads ones from its debug
registers and carries on, which is what MIT's board does. This closes a
divergence the fabric carried until the cable's end was built: those four
addresses used to time out.

**A debug master's own cycle at the debug block is not answered.**
`Busint::debug_set_master` gives `Responder::Debug` no answer at all. On MIT's
board the decode knows nothing of who the master is and such a cycle would go
out on this board's cable to a third machine. muir does not model a chain of
debuggers and neither does this.

### The acknowledgment must belong to this cycle

`DEBUG OUT ACK` is a level. On MIT's cable it falls within nanoseconds of the
request it belongs to being lifted, because the far end's gate is a NAND of
the three register strobes and they go with the request.

A carrier that serializes the cable does not give that for free. The fall
takes a frame to cross, so the acknowledgment of the cycle just finished is
still standing when the next one starts. A page that took it would answer its
own machine in no time with a word nobody drove. So the acknowledgment is
taken only after it has been seen down with this cycle's strobe already up.
This was a defect, and the two-board check below is what found it.

### The REQTIM PROM has two tables and both are built

The interface gives up on a cycle nothing answers after `busint::TIMEOUT_NS`,
4.25 microseconds. A debug cycle gets `busint::DEBUG_TIMEOUT_NS` instead,
11.05 microseconds, because the other machine is allowed that long. It is the
same counter and the same free-running oscillator; the PROM's second table
raises `NXM TIMEOUT` at count 13 where the first raises it at count 5, and
`DEBUG REQUEST ACTIVE` is what selects it.

**In ticks those are 425 and 1,105**, because the oscillator keeps its half
period of 425 nanoseconds in an accumulator and `TICK_NS` is 10. So a debug
cycle has 1,105 ticks of this fabric to finish in, which is 11.05 microseconds
of real time. At the 5 ns grid they were 850 and 2,210. The 1,105 is the
number the carrier's frames are spent against, and the section on the budget
says what the two checks hold them to.

`rtl/machine/cadr_busint_regs.sv` therefore brings `SELECT DEBUG` out and
`rtl/machine/cadr_memory_path.sv` joins it to `rtl/machine/cadr_busint_xbus.sv`,
which is where the counter is. Without it a debugger would give up at 4.25
microseconds on answers that were on their way.

**One parting from muir comes with it.** A debug cycle the far end never
answers ends on `NXM TIMEOUT` here and sets the Unibus NXM bit, because the
counter cannot tell what kind of cycle it is counting. muir sets its two NXM
bits at the decode instead, where `Responder::Debug` gets no error at all. It
is the same family as the timeout race `cadr_busint_xbus.sv` already records:
the model decides at the grant what the board can only discover by counting.

### The checks

`build/dbg_pmod.pass` holds the carrier to its one property: what goes in one
end comes out the other, unchanged, whole and in bounded time. The testbench
is the cable, so every wire is delayed, skewed, shorted, crossed or unplugged
by the check rather than assumed to be perfect. What crosses is poison: every
value sent has its low ten bits the complement of its high ten, no two values
in a run are the same, and none is zero. Crossed now means the strobe and the
data line arriving in each other's place, since a direction has one of each;
the check also shorts each of the two to each rail, and reports the round trips
against the debugger's timeout.

The board reset sweep in that check runs a frame and a beat of reset lengths,
so every offset in a frame is covered. It was seventy-one, which was a frame
and a beat when a frame was sixty-six ticks and would have been less than half
of one afterwards.

`build/dbg_cable.pass` holds what the carrier is for. The DUT is two boards.
One runs the DBGOUT page and the other answers through
`rtl/machine/cadr_dbgin.sv` on the arbiter and the diagnostic registers, which
is CC's whole vocabulary. All sixteen pads are harness ports with their
tri-state enables beside them, so the testbench is the cable and can see
contention: a pad driven from both ends is counted on every tick of every
phase, and a run that counts one has failed.

What it shows rather than argues, on its own output:

- all sixteen of the debuggee's diagnostic registers read through a cycle on
  that board's own Unibus, each coming back with the word that board drove;
- the address latch at the far end holding what CC wrote into it;
- the status read coming back with the debuggee's byte below and all ones
  above, which is the one place a byte nobody drives has to arrive as ones;
- cycles over three ticks of wire each way, and cycles with the one data line
  inverted for five ticks inside the request, both of which cost a frame and
  never a word;
- the same five ticks on a GUARD pin instead, which costs nothing at all ---
  not the word and not the far board's count of refused frames, which is what
  "nothing reads a guard" means as a check rather than as a claim;
- every group a board drove going out whole, all four pads and never a subset,
  with both of its guards at zero, asserted on every tick of every phase;
- a cycle at an address nothing answers coming back with no word at all over
  more ticks than the debugger's own timeout allows, with the cable carrying
  the cycle after it;
- the slowest debug cycle of the whole run reported and held under half the
  debugger's timeout;
- a cable pulled under a standing request answered at once with all ones
  rather than waited on, and the far board heard again when it is plugged back
  in;
- two boards cabled together with neither told anything and no pad driven at
  all;
- a second board told to connect while the first has the role, refusing it;
- a role dropped inside a cycle, held until the cycle has gone;
- **the role taken by the second board, and its own DBGIN page still answering
  its own window while it holds the connector** --- which is what "only the
  connector changes hands" means, asserted rather than argued;
- and that board told to disconnect, going quiet with not one pad driven at
  either end, its window still answering.

**That last leg found a defect and it is worth recording.** The activity timer
is held saying nothing while a board is the debugger, because a debugger
listens to the return group and would otherwise be reset by its own debuggee's
answers. Holding the timer alone is not enough: `rx_stb` is one pin while
engaged and another after, so the role changing moves the synchronizer from one
pin to the other, and with its two flops left running the comparison one tick
later reads as a transition on the forward group. The board then believes a
debugger has appeared and drives the return group on top of the debuggee still
answering it. Measured: 2,048 pad-ticks driven from both ends --- four pads for
the whole of `LOSS_T` --- at the tick the second board was told to disconnect.
The synchronizer is held with the timer now.

`build/busint_regs.pass` sweeps the debug block over all 262,144 Unibus
addresses against `busint::debug_register`, with nothing plugged in and again
with a board at the far end. `build/unibus.pass` runs the block in the
composed memory path, where the REQTIM counter is: it measures the fabric's
own convention on an ordinary cycle nothing answers and then requires a debug
cycle to sit the same way against the other table, so what is compared is the
count and not a constant transcribed into the check.

### The attachment, which is built

**Both boards carry the connector, in every configuration.**
`boards/arty-z7-20/cadr_arty.sv` and `boards/cora-z7-07s/cadr_cora.sv` bring JA
out as eight bidirectional pads, and each instantiates
`cadr_dbg_cable.sv` on them, outside the generate
block that holds the processing system. That is not tidiness: **a board is
always a debuggee**, so the connector has to exist on a board with no console
and no window at all, and a top-level pin nothing drives is a PINMISSING
besides. Every unassigned header carries nothing and has no constraints.

The machine's own DBGOUT page leaves `cadr_machine` for it. Those seven ports
used to be tied off inside that module with a note saying the wrapper change
and its wiring were one commit; this is that commit. A board with no connector
at all would tie `dbgout_live` low and `dbgout_dbd_in` to all ones, which is
muir's `debug_cable` false.

**The timing exception is read in every configuration too, and it used not to
be.** `rtl/plumbing/xilinx7/cadr_debug_pmod.xdc` was gated on a general-purpose
port being brought out, on the argument that with no window the sender folds to
constants. The connector made that false: the machine's diagnostic mux reaches
the carrier's frame registers on every board. Measured while the gate was still
there, the memory-off Arty Z7-20 came out at -9.600 ns on 596 endpoints with
the file read by nothing. Each board's flow reads it unconditionally now and
asserts with `assert_instance_timing` that it reached a path.

What holds the attachment in simulation is `build/dbg_cable.pass`, where the
testbench is the cable and both boards are real. What holds it on silicon is
the section below.

## What two boards have shown

The carrier and a debug cycle over it have both run on real boards. The boards
are an Arty Z7-20 and a Cora Z7-07S, the cable is a ribbon between their two
Pmod JA connectors, and each board was running Lisp throughout.

### The carrier

Each board took the debugger's role in turn and gave it back. The board that
took it found the ribbon's wiring for itself: the cable on the bench is the
mirrored one the section above describes, and under `auto` the console read
`crossover, detected` rather than `crossover, assumed`, while the far board
reported a debugger on the connector and not that the two ends disagreed.

Forced to `straight`, which is the wrong setting for that ribbon, the debugger
said nothing was answering and the far board said the two ends disagreed about
the cable. That is the fault the detection exists to remove, and it was shown
once on purpose as the control for the paragraph above.

Neither machine noticed any of it. Both ran at the rate they run at with no
cable in them while the role was taken, swapped and given back, and neither
Lisp world lost its place.

### The carrier with one signal to a pair

Both carriers have run on these two boards and this ribbon. Three data lines a
group is what CC crossed, and the guarded carrier the section above describes,
one signal to a pair with the other pin of the pair driven low, has since run
on both boards with the cable untouched.

**Two resting boards drive nothing.** Both consoles read a debuggee with the
wiring `auto` and nothing on the connector. That is the lock-out gone. On the
earlier carrier each board heard the other's idle frames on this same mirrored
ribbon, called them a debugger's, and would not take the role until it was
reset. The role bit in the frame's fill slot is what removed it, and this is
the measurement of that rather than the argument for it.

**The wiring is found on this carrier too.** Each board took the role in turn
and read `crossover, detected`, while the far board reported a debugger on the
connector and not a disagreement. Forced to `straight` from a disconnected
board, the debugger read that nothing was answering and the far board read that
what is on the connector is arriving on the four pins it answers on. Set back
to `auto` after the role had been given back, the detection found the crossover
again and the far board's disagreement was gone. A wiring written while the
board holds the role changes nothing, so giving the role back before setting it
is the recovery order.

**The refused frames are gone.** As the debugger the Arty Z7-20 read 0 refused
against a saturated 65,535 heard on every one of twenty-four readings, taken
ten seconds apart from fifty-seven seconds after the connect to four minutes
and forty-eight seconds after it, and on the first reading after the connect as
well. On the earlier carrier the same board in the same role refused 163 frames
on one connect and 185 on the other, in bursts, with the counter at its ceiling
of 255 within 300 milliseconds. So the guards removed the asymmetry the section
on coupled pairs measured, which is what they were put there for. The bursts
stopped when each pair carried one signal with its partner driven low as a
guard, which is consistent with coupling between the two unrelated signals a
pair carried on the earlier carrier; nothing was measured on the lines
themselves, so the coupling is inferred from the change and not seen.

**Two frames are not accounted for.** The Cora Z7-07S read 0 refused as the
debugger over two minutes, as it had before, and ended the session at 2 against
a saturated 65,535 heard. Five disconnect and reconnect cycles of the far end
added none, a repeat of the forced `straight` control added none, and 5,020
debug cycles added none. The two arrived at moments nobody caught. Two
candidates, named as candidates and not measured: a partial frame caught as a
driver starts or stops at a role change, and the tail of the forced `straight`
control, where the four pins one board drives sit on four the other is driving.
Neither has been reproduced on demand and no cause is claimed. Against the
earlier carrier's bursts it is a different quantity, and it is not zero.

### A debug cycle over the ribbon, without CC

The cheapest statement that this carrier carries a cycle needs no CC at all. A
Unibus read of `0o766104` is `-DB READ STATUS`, the strobe the section on the
status byte is about, and it can be made from the debugger board's own Lisp
Listener:

    (format t "~&STATUS ~O~%" (si:%unibus-read #o766104))

| the debugger | connected | disconnected |
|---|---|---|
| the Arty Z7-20 | `0o177400` | `0o177777` |
| the Cora Z7-07S | `0o177400` | `0o177777` |

`0o177400` is `0xff00 | status` with every live bit clear, which is what a far
end that answers gives. `0o177777` is the debugger's own timeout, which is what
an unplugged connector gives. Reconnecting put the first value back. So the
strobe crosses the ribbon, the far board decodes it, drives its status byte on
the return group and acknowledges, and the debugger's own Unibus cycle
completes with that word, in both directions.

**And the byte is the far board's.** Sixteen reads in one form gave `0o177400`
thirteen times and `0o177500` three times. The bit that moves is bit 6, the far
bus interface's own `-FREE`, and the far machine is running Lisp and making bus
cycles all the while, so a strobe lands on a busy interface some of the time.
The section on the status byte says the debugger's strobe is not a cycle of the
interface's own, so it finds the bus as it stands. A pull-up, a stuck wire or a
constant cannot vary, and this byte varies with the far machine's work.

**What this does not show is a register of the far machine.** No word of the
far machine's state crossed on this carrier, and no `-DB NEED UB` cycle, which
is the one that runs a cycle on the debuggee's own Unibus, was made. It is the
carrier answering a strobe rather than a debugging session. The 5,020 cycles it
took to watch the counters cost no refused frame on either board.

### CC halting the far machine, and the readings compared

MIT's own CC, running in the Lisp world of the CADR in one board's fabric,
halted the CADR in the other board's fabric over the ribbon, read its registers
and its scratchpads, and started it again. It was done both ways round. Every
value CC read over the cable is what the far board's own console and readout
program give for the same word at the same halt, and the two paths share
nothing but the register itself.

The far machine was halted from its own console first, so that no instruction
had been forced and both ends look at the same instant. CC prints octal and the
console prints each register as the halves it reads it in, so a row below is
one word written two ways. CC's status word is one word of 32 bits whose halves
are `FLAG-1` and `FLAG-2`, and the last two rows of each table are those
halves.

The Arty Z7-20 as the debugger, reading the Cora Z7-07S:

| word | CC over the cable | the Cora's own console |
|---|---|---|
| `PC` | `0o1370` | `0o1370` |
| `IR` | `0o600626060011100` | `0x180c_b0c0_1240` |
| `OB` | `0o11200003116` | `0x4a00_064e` |
| `FLAG-1` | `0xf800` | `0xf800` |
| `FLAG-2` | `0xc0c7` | `0xc0c3` |

The Cora Z7-07S as the debugger, reading the Arty Z7-20:

| word | CC over the cable | the Arty's own console |
|---|---|---|
| `PC` | `0o17700` | `0o17700` |
| `IR` | `0o600125000511640` | `0x1802_a802_93a0` |
| `OB` | `0o2202007153` | `0x1208_0e6b` |
| `FLAG-1` | `0xf800` | `0xf800` |
| `FLAG-2` | `0xc1d7` | `0xc1d7` |

All 48 bits of the instruction register and all 32 of the output bus are equal
in both directions. The one row that differs is CC's own correction and the
section below is about it.

The scratchpads were read at each direction's own halt. Each figure below is
two readings that were equal: CC's over the cable, and the far board's readout
program on the same word while the machine stood still.

| word | the Cora, read by the Arty's CC | the Arty, read by the Cora's CC |
|---|---|---|
| `amem[1]` | `0o56` | `0o72` |
| `amem[7]` | `0o1240005413` | `0o2` |
| `mmem[1]` | `0o56` | `0o72` |
| `mmem[7]` | `0o1240005413` | `0o2` |

Addresses 1 and 7 read the same in octal and in decimal, so nothing in the
comparison turns on which base either side used.

**Every microcycle is accounted for.** A scratchpad read is one forced
microinstruction, which is what `CC-EXECUTE` is, and the far machine's cycle
counter moved by exactly one for each of them: five for five reads one way and
four for four the other. CC's own `PC=` is what the console reads after the
entry, less five, which is the five instructions `CC-FULL-SAVE` forces on the
way in.

**None of it went through the window.** The Cora Z7-07S's own register window,
read while it was the debuggee, reported no requests and no faults at all. So
what carried the halt, the reads and the start was the ribbon and nothing
else.

### CC corrects the status word, and the bit it corrects is JC-TRUE

`FLAG-2` differed by one bit in one direction and by none in the other, and
that is MIT's software rather than the cable. `CC-READ-STATUS` in
`sys/cc/lcadrd.lisp` reads the two flag words and inverts bit 2 of the second
when bit `0o100` of `IR-LOW` is set, under its own comment saying the hardware
reads JC-TRUE incorrectly.

In the first direction above `IR-LOW` is `0x1240`, that bit is set, and CC
prints `0xc0c3` exclusive-ored with 4, which is `0xc0c7`. In the second
`IR-LOW` is `0x93a0`, the bit is clear, the correction does not apply and CC
prints the register verbatim. So the second direction is the control for the
first: the same two readers agree exactly where CC is not correcting anything.
The console's own reading was taken three times with the machine still halted
and did not move, so the difference is between the two readers rather than
over time.

### Getting CC into a Lisp world that has no compiled CC

A person repeating this needs the recipe, because the obvious form does not
work on these bands. `(make-system 'cc :noconfirm :nowarn)` fails with `File
not found for SYS: CC; LQFMAC QFASL`. The file host serving `SYS:` carries
CC's sources and no compiled files at all, and this band's own release does
not ship CC compiled. Compiling it is about twenty-seven minutes of the
machine's time and writes sixteen compiled files onto the file host, which is
a change to the file host and was not made.

CC was loaded from source instead, interpreted, file by file, in the order
`SYS: SYS; SYSDCL LISP` gives for its CADR-DEBUGGER system. Eleven of the
sixteen files were enough: `LQFMAC`, `LCADMC`, `CADREG`, `CC`, `CCGSYL`,
`LCADRD`, `LDBG`, `QF`, `ZERO`, `CADLD`, `CHPLOC` and `CCWHY`. Nothing asked
for the other five, which are the diagnostics, the disk and the salvager, so
those commands are not available in a world loaded this way.

**Two things an interpreted load needs that a compiled one does not.**

First, `cadreg.lisp` must be read into package `CADR`. Its own attribute line
says `Package: SYSTEM-INTERNALS`, and `load` honors the file's package where
`make-system` reads a file in the system's. Package `CADR` uses `GLOBAL` and
`SYSTEM` and not `SYSTEM-INTERNALS`, so `SI:RARSET` and `CADR:RARSET` are two
symbols and the rest of CC cannot see the first. The form that works is

    (load "SYS: CC; CADREG LISP" :package "CADR")

Second, a `DEFCONSTANT` is not special to the interpreter, and CC evaluates
those constants as variables: `lcadrd.lisp` calls `CC-INITIALIZE-SYMBOL-TABLE`
at load time, which evaluates each symbol of `CC-INITIAL-SYMS`, and the
interpreter answers `RARSET is referenced as a free variable but not declared
special`. The compiler never meets this. Declaring all 67 of `cadreg`'s
constants special is one form, with the reader's package bound so that the
symbols it makes are the ones CC will look for:

    (let ((package (pkg-find-package "CADR")))
      (with-open-file (s "SYS: CC; CADREG LISP")
        (do ((f (read s nil) (read s nil)) (n 0)) ((null f) n)
          (and (listp f) (eq (car f) (quote defconstant))
               (progn (eval (list (quote defvar) (cadr f))) (setq n (1+ n)))))))

It answers 67, which is the number of `DEFCONSTANT`s in the file. Run at a
Listener without binding the package it reads the symbols into `USER` and is a
no-op, and the load then fails in exactly the same place. Two redefinition
queries arrive and are answered `P`.

The load took an hour and a half the first time, while the recipe was being
found, and seventeen minutes the second time, when it was known. It is
interpreted and lives in the machine's own world, so it is lost when that
machine is rebooted.

### What the boards have not shown

**Nothing has been written to the far machine over the cable.** What has run is
the halt, the reads and the start. CC can write a scratchpad, main memory and
the machine's own registers, and none of that has crossed a ribbon.

**The frame counters cannot give a rate.** Page 0's word 15 carries frames
heard and frames refused, and only a fabric reset clears either. The first
saturates at 65,535 within a tenth of a second of a connect, so it was already
saturated before the first debug cycle and said the same thing after the last.
The second reached its own ceiling of 255 within about a third of a second on
the earlier carrier; on the guarded one it stands at nought or two, which is a
total and still not a rate. A counter that can be cleared without a reset, or a
wider one, is what would measure this.

**Nothing has been measured about the cable's timing.** No beat rate, no round
trip, and no comparison against the 11.05 microseconds the debugger's own
interface allows a cycle. The figures in the section on the budget are still
arithmetic and the check's own measurements.

**One start did not take, once.** `CC-START-MACH` answered as it does when it
works and the far machine's own program counter moved, and the machine stayed
halted until a second call started it. Taken again the same sequence started
the machine on the first call, so it is not reproduced. The one difference in
the failing case is that reads had been made before CC had done a full save.
No mechanism is claimed and it is written down because somebody will meet it.

**Two refused frames are unexplained.** The asymmetry that made the earlier
carrier refuse frames in bursts is gone with the guards, and what is left is
two frames on one board in half an hour, at moments nobody caught. The
subsection above says what was measured and names the two candidates, neither
of which is a measurement. It stopped nothing: every cycle was answered and
every word was right.

**CC has not crossed the guarded carrier.** The halt, the reads and the start
were made on the carrier with three data lines a group, which is not the one
either board carries now. What has crossed the guarded one is a status strobe,
which is the carrier and not the debugger.

## What is not built

**The composition onto the board is done, and so is the connector.**
`rtl/machine/cadr_dbgin.sv` is instantiated in
`rtl/machine/cadr_memory_path.sv` beside the three Unibus slaves,
`cadr_machine.sv` passes both ends of the cable up as ports, and both boards
put `cadr_dbg_cable.sv` on Pmod JA, with `cadr_dbg_join.sv` between it and the
page. Both put `cadr_debug_window.sv` behind a general-purpose port as well, so
the join has two arms on each. The window is how a program plays the far end of
this cable. Two boards and a ribbon are no
longer what is left: the section above says what they have shown. The lines are
the lines `tb/cadr_dbgin_harness.sv` was written with, which is what that
harness is for: it was the attachment before the attachment landed, and the arbiter it
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

