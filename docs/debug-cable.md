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

Six of the eight status bits are zero in this fabric and will stay zero until
the bus interface's control and error status registers at `0o766040` to
`0o766076` are built. Bit 6 is `-FREE` and is real. Bit 7 is
`WRITE THROUGH ENB` and is zero because write-through mode is not built.

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
wires bit 1 to the machine's reset the way the fabric will wire it, joined with
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
fabric's Unibus has two slaves: the diagnostic register block at `0o766000`,
`rtl/machine/cadr_spy_registers.sv`, and the I/O board at `0o764100`,
`rtl/machine/cadr_io_board.sv`.

The register block is the one that matters, because it is CC's whole
vocabulary. `spy_write(CLK, 0)` halts the machine and `spy_read(PC)` reads its
program counter, and both are ordinary Unibus cycles at `0o766000` plus twice
the register number. So muir over this cable can do to the machine what muir
over the lashup does to a simulated one.

The Unibus map is not built, so a debug cycle cannot reach main memory. That
is not a limit of the cable; it is the same absence the machine's own Unibus
cycles meet. `cadr_spy_registers.sv` names it in its own header.

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

## Where the window sits: the question, with the numbers

This is not decided and it is not the fabric's to decide. `README.md` once put
the console on `M_AXI_GP0` and the debug cable on `M_AXI_GP1`. The console
took `M_AXI_GP1` instead, and the note left behind said to settle the question
when the adapter was built. It is built.

The constraint that shapes the answer is the GP0 hang. A read that nothing in
the fabric answers inside a general-purpose port's window does not fault the
Arm. It hangs both cores at one program counter each, and no software guard
can catch it. This was measured on the board. So a slave that owns a
general-purpose port must answer the whole of it.

The XC7Z020 has exactly two `M_AXI_GP` ports. There is no third.

What is on them today:

| | today | |
|---|---|---|
| `M_AXI_GP0` | `cadr_disk_pack.sv` | the block's address, the drive registers, `SLVERR` outside its window |
| | `cadr_gp0_default.sv` | on boards without the pack side, `NONE` everywhere |
| `M_AXI_GP1` | `cadr_console.sv` | thirty-two words at `0x8000_0000`, `OKAY` and `UNMAPPED` over the whole gigabyte |

Three ways to fit the window in.

**One: the adapter takes `M_AXI_GP1` and the console moves to `M_AXI_GP0`.**
The adapter is then a whole-port slave, which is what it already is, and its
attachment is one line. The cost is on the console's side, and it is smaller
than it was when this was written. `M_AXI_GP0` already carries three faces
behind `rtl/plumbing/cadr_gp0_split.sv`, so the console would be a fourth
page rather than a decode somebody has to write. Two of the objections this
paragraph used to raise are answered by that module. The decode does carry
the disk's traffic, but it is a held match and a registered selection, and
the exception count says the constraints still reach it. And the `SLVERR`
rule and the `OKAY` rule no longer have to be reconciled: each page answers
in its own way and the splitter's fourth port answers everything neither
claims. What is left of the cost is a page of address space and the console's
own wiring.

**Two: the adapter shares `M_AXI_GP1` behind a split.** A new module owns the
port, routes a transaction to the console or to the adapter by address, and
answers everything else itself. It is a module with a testbench and mutation
records of its own, because it is new logic in front of two faces that are
already proven. Nothing on `M_AXI_GP0` changes. The adapter goes behind it
unchanged, being a whole-port slave already.

**Three: the adapter is a second face behind the console's own AXI front
end.** `cadr_console.sv` already owns the port, already decodes a window and
already answers everything else. Its window is 128 bytes and two pages of
sixteen words. Widening the match by one address bit gives four pages, and
pages 2 and 3 are free. The adapter's registers then sit at `0x8000_0080`,
which is the address muir's issue used as its own example, and the console
forwards the beat to them and muxes the word back. No new AXI logic anywhere.

Neither option's size has been measured, so neither is quoted. What decides is
not size.

The recommendation is **two or three, and not one**. Both leave `M_AXI_GP0`
untouched, and that is worth more than what either costs. The disk's port
carries the machine's own traffic on every boot, 42,967 blocks of it, and it is
the port where an unanswered read has actually frozen this board. Option one
puts new, unproven decode logic in front of that.

Between two and three, the recommendation is **two**, and the reason is a
lesson this project has already paid for. Option three puts the adapter's
address match downstream of the console's, and a mutation aimed at a match
behind an exhaustively checked guard tests the guard and not the thing --- the
display's `tv-answers-its-neighbours` survived for exactly that reason. The
adapter's own window match is checkable today, in `build/dbgin.pass`, because
the adapter owns the whole port there; putting it behind the console's decode
would make that check a claim about the console. Option two keeps the two faces
independent and pays one module for it, and that module's own decode is then
the thing a record is aimed at.

The adapter is built so that either answer is a change at the attachment and
not in the module. `REG_BASE` is a parameter and `cadr_debug_window.sv` is a
whole-port AXI3 slave.

## The check

`build/dbgin.pass` is the falsifiable statement of all of this. It is
`tb/cadr_dbgin_harness.sv` and `tb/cadr_dbgin_tb.cpp`, and the Makefile runs it
with the rest.

The harness is the attachment, written before it lands. It puts the window, the
DBGIN page, the real arbiter, the real register block and the real processor
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

## What is not built

**The composition onto the board.** The window is not instantiated in
`boards/arty-z7-20/cadr_arty.sv` and no bitstream has the DBGIN end in it.
That waits on the port question above. muir's own words for what would settle
its half are "a bitstream with the DBGIN end in it", so this is the thing that
stands between here and that.

What has landed towards it is the arbiter. `rtl/machine/cadr_console_bus.sv`
carries the third master, because the arbiter must be one description of one
thing and `tb/cadr_dbgin_harness.sv` must hold what the board carries rather
than a copy of it. It is tied off at both existing instantiations, in
`rtl/machine/cadr_memory_path.sv` and `tb/cadr_console_harness.sv`, and the
whole arm folds there: `dbg_own` is constant false. That is the shape the
console had before it landed, when `cadr_arty.sv` tied `con_req` off.

What remains is three files and no new logic. `cadr_memory_path.sv`
instantiates `cadr_dbgin` beside the two Unibus slaves and brings the cable out
as ports instead of tying the master off. `cadr_machine.sv` passes those ports
up. `cadr_arty.sv` instantiates `cadr_debug_window` on whichever
general-purpose port is chosen and joins the two. The lines are the lines in
`tb/cadr_dbgin_harness.sv`.

One thing to settle when it is composed. `cadr_dbgin.sv` takes the status byte
as a port, and the composing level has to assemble it: bit 6 is `-FREE`, which
is the bus interface's own busy, and `cadr_busint_xbus.sv` does not bring that
out today. The other seven bits are zero in this fabric.

And one thing to measure rather than assume. `cadr_dbgin`'s registers are
inside `cadr_machine`, so they fall into `rtl/plumbing/xilinx7/cadr_machine
.xdc`'s relaxed set on that file's own test, which relaxes every register the
file does not name. Before any slack figure is quoted for a board with this in
it, ask which set these registers fell into. The arc that wants looking at is
the sixteen-way diagnostic mux reaching the cable, and its clock enable with
it: a relaxed register's enable is relaxed with it, and `elapsed -> md/CE` is
the instance of that this project has already paid for.

**The modifier's two effects.** Bit 1, the debuggee reset, and bit 2, the
timeout inhibit, leave `cadr_dbgin.sv` as ports and nothing consumes them.
Bit 1 wants the machine's reset, which is where `cadr_console.sv`'s own reset
pulse already lands. Bit 2 wants the NXM timeout counter inside
`cadr_busint_xbus.sv`, which is held to muir tick for tick over a trace, so it
is a change that needs a trace with a debug cable in it.

**MIT's own Unibus arbitration for this master.** muir takes the debug master
through `NPR`, `NPG1 IN`, `SACK` and `-UB BBSY`, and
`cadr_busint_xbus.sv` says in its own header that every branch it left out of
its arbitration belongs to the debug cable. This fabric puts the debug master
on the same simple arbiter the console uses. The difference is the one the
console already has and is recorded here rather than hidden: the grant is
taken with the processor's strobe down and held until the master lets go, and
the instants either side of it are not MIT's.

**The physical two-Pmod adapter.** A second real board over two eight-pin
connectors is a different transport with its own serialisation. It is not
needed for any of this and nothing here depends on it.

One correction belongs with it. `README.md` says the enables on `DBD` are
byte-wise, because `DBD` is driven by two octal Am8304s at DBGOUT 0B21 and
0B22. muir read the netlist and found that both transceivers take the same
enable net on pin 9, `-DBD ENB`, and the same direction net on pin 11,
`-DEBUG > UD`. There is one enable and one direction for both bytes. That
changes the count for whoever designs the physical adapter and has no bearing
on the memory-mapped transport, where both signals stay inside the fabric.
