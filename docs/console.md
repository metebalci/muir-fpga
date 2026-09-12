<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# The console

Written at the console slice, 2026-09-10, against `rtl/plumbing/cadr_console.sv` as it
stands at this slice. Numbers and line ranges below are measured at that
point; read the date on anything that looks like a fact about the fabric.

**And every slack figure and every timing requirement in this file was
measured at a 5 ns tick**, which is what the fabric ran at until 2026-09-11.
A requirement printed as `5.000 ns` is one tick and one printed as `75.000 ns`
is fifteen; at the 10 ns tick built since, the same two read 10.000 and
150.000, and the tick counts and logic levels are unchanged. Both boards close
at that tick --- +1.537 ns with memory off and +0.657 ns with `DDR=1`, zero
failing endpoints on either, measured at `822535c` --- so where this file says
a board does not close it is describing the build it names. `docs/tv.md` has the decision and its
reasons.

**The machine goes quiet and nothing built can say why.** On the board the
CADR loads its microcode from its pack, does a fixed amount of disk work and
stops moving. The lamps say a beat is running and the probe sees only the
first 1,024 microcycles, which is 0.17% of the boot PROM and structurally
cannot be moved (`rtl/plumbing/xilinx7/cadr_probe.sv`: it fills from the first microcycle after
reset and freezes, which is what makes it need nobody at the board). So the
question --- is it waiting, or has it halted, and where is its PC --- has had no
instrument at all. **The console is that instrument.**

## What a console is, in muir

muir's console is CC, the program `examples/cc.rs` runs on one CADR to debug
another, and its whole vocabulary is `src/spy.rs`: **sixteen registers at
Unibus `0o766000`, three of them written and all sixteen read.** MIT's own
description of the diagnostic bus is quoted at the top of that file ---
`SPY<15:0>` bidirectional, `EADR<3:0>` selecting one of sixteen, `-DBREAD`
and `-DBWRITE`, and "the EADR<3:0> lines just follow the Unibus address
<4:1>".

`Engine::spy_read` answers a read (`../muir/src/rtl.rs:2679-2721`) and
`Machine::spy_write` takes a write (`../muir/src/machine.rs:630-645`) --- the
latter "as the trailing edge of `-DBWRITE` does, from a Unibus cycle **or
from a console with no bus at all**", which is `src/spy.rs`'s own sentence and
is the licence for this module.

What a console does with them, in CC's own order
(`../muir/tests/lashup.rs:143-179`):

    halt      write 0 to register 3, the clock control register.  RUN down.
    examine   read register 5 for PC, 0/1/2 for IR, 12/13 and 10/11 for the
              A and M buses, 8 and 9 for the two flag words
    step      write 2 then 0 to register 3, CC's `CC-CLOCK`
    start     write 1 to register 3

and the state it reads back is the machine's own, recomputed: "the datapath
is combinational, so a halted machine shows the console the result of the
instruction it has not yet executed, which is what CC's `CC-EXECUTE-R` relies
on" (`../muir/src/rtl.rs:2671-2678`).

**`Halt` is not a hardware concept and a console can never see one.** muir's
`Halt` enum has one variant, `UnknownDest`, constructed only by the
low-fidelity `Micro` engine at `../muir/src/micro.rs:625`; `Rtl::step` never
returns it (`../muir/src/rtl.rs:2652-2659`, "it cannot fail"). What a console
reads instead is `FLAG-1`, and `../muir/src/main.rs:2278-2305` is the
reference decode. Four stopped states, all of them in that one word:

    console halt    SRUN, bit 8, down --- RUN was written zero
    self-halt       ERR, bit 10, up under ERRSTOP --- MIT's HALT-CONS,
                    `(si:%halt)`, which System 100 uses
    statistics      -STATHALT, bit 11, low, under STATHENB
    a bus wait      -WAIT, bit 15, low --- transient, and it comes out of it

`../muir/tests/halt.rs:88-93` states why the run loop must watch that word:
`Engine::step` "goes on returning `Ok` for as long as it is called, advancing
the master clock and running no microcycle, so nothing about the call says
the machine has stopped."

## What is here

`rtl/plumbing/cadr_console.sv` is a **master on the diagnostic bus with an AXI slave
face on `M_AXI_GP1`**. It is not a second copy of the register block:
`rtl/machine/cadr_spy_registers.sv` is the register block, it is not touched by this
slice, and the console drives its Unibus port exactly as `cadr_busint_xbus`
does. Its timing --- `-UB SSYN` at `DIAGNOSTIC_NS` after the strobe, the write
pulse's leading edge `REGISTER_PULSE_NS` before the register loads, and the
rule that a write lands at the machine's next look rather than at the strobe
--- is the board's, is already checked against muir by `build/machine.pass`,
and is what this module drives. A console that reached around it would be a
second description of one thing, and the two would drift.

### The register map

**Thirty-two words at `REG_BASE`, two pages of sixteen**, in
`rtl/plumbing/cadr_console.sv`'s header (lines 32-77 at this slice) and its read mux
(`r_word`, lines 430-446). `REG_BASE` is `0x8000_0000` (line 156), the bottom
of `M_AXI_GP1`'s window; `IDENT` is `"CONS"` (line 158) and `UNMAPPED` its
complement, `0xBCB0_B1AC` (line 160); `LOST_T` is line 167.

    page 0, REG_BASE + 0x00, the console's own, all read-only:

     0  IDENT    "CONS", 0x434F4E53, so that the first read over GP1 can tell
                 this face from a bus that answers zeros or ones
     1  STAT     bit 0  busy      a diagnostic cycle is in flight
                 bit 1  gnt       the diagnostic bus is the console's, live
                 bit 2  answered  the LAST cycle got -UB SSYN
                 bit 3  lost      some cycle since reset did not; sticky
     2  CYCLES   microcycles retired since reset, bits 31:0.  This is muir's
                 `Machine::cycles`
     3  CYCLESH  bits 63:32, LATCHED when CYCLES was read
     4  TICKS    fabric ticks since reset, bits 31:0 --- `Rtl::ns()` / 5.
                 A tick is 10 ns of real time, so `cadr-console.c` divides
                 by `CONS_TICKS_PER_US` = 100 and not by 200
     5  TICKSH   bits 63:32, latched when TICKS was read
     6  RESET    **the one word of page 0 that is written.**  A write of
                 `RESET_KEY` and of nothing else pulses the machine's reset
                 for `RESET_T` ticks.  It reads
                   bits 31:16  `RESET_KEY`'s own top half, `0x5253`, a marker
                   bits 15:8   console resets since the CONSOLE came up,
                               saturating at 255
                   bit 0       a pulse is up now
     7  VMA      the virtual address register, all 32 bits, as of the last
                 microcycle boundary.  **Reading it LATCHES Q AND MD beside
                 it**
     8  Q        the Q register, all 32 bits, latched when VMA was read
     9  MD       the memory data register, all 32 bits, latched when VMA
                 was read
    10  READOUT  **written** with `{sel<3:0>, word<13:0>}`, which names one
                 word of one of the machine's memories; **read** as the echo
                 of the address the word beside it was read at.  Reading it
                 latches the echo and both halves of the word together
    11  READ LO  that word's bits 31:0
    12  READ HI  that word's bits 47:32, in bits 15:0
     13-15       read UNMAPPED; writes dropped

    page 1, REG_BASE + 0x40, the sixteen diagnostic registers, word k
    being EADR k:

     read    a diagnostic READ cycle; SPY<15:0> in bits 15:0, bits 31:16
             zero --- or BIT 16 SET and nothing else, meaning the cycle was
             not answered
     write   a diagnostic WRITE cycle, SPY<15:0> from bits 15:0

So `spy_read(eadr)` is a load from `REG_BASE + 0x40 + 4*eadr` and
`spy_write(eadr, v)` a store to it, and a console program's vocabulary is
muir's with no translation in between. Register 3 has no read select on the
board --- Y3 of the 74S138 at SPY0 1F01 is not connected --- and reads the open
bus, all ones; that is a fact about the machine and it comes back through
here unchanged.

**The high half is latched by the low half's read, and that is not a
convenience.** A 64-bit counter read as two 32-bit loads is wrong across a
carry: the low half wraps between the two loads and the pair names a time
4,294,967,296 ticks in the future. The rule is CYCLES then CYCLESH, TICKS
then TICKSH; a program that reads the high word alone gets whatever the last
low read latched.

**Every address on GP1 is answered, and with OKAY.** A read nothing answers
on a GP port does not fault the Arm, it hangs both cores at one PC each,
measured on the board and set out at length in `rtl/plumbing/cadr_gp0_default.sv`. So a
read outside the thirty-two words completes with `UNMAPPED` and a write
outside them completes and is dropped, over the whole gigabyte GP1 decodes.
OKAY and not SLVERR, which is where this differs from `rtl/plumbing/cadr_disk_pack.sv`:
an error response to a Cortex-A9's posted write arrives as an imprecise
external abort the kernel cannot attribute to a process. The pack side can
afford SLVERR because a board with GP0 and no pack side has
`cadr_gp0_default.sv` under it; GP1 has only this.

`UNMAPPED` is the complement of `IDENT` and is neither zero nor all ones ---
zero is what a dead bus reads and all ones what an undriven one reads,
measured on this board's own EMIO pins. **A value that means nothing must not
be a value the instrument can mean.**

### The reset

**`boards/arty-z7-20/cadr_arty.sv`'s reset was MMCM lock or BTN0 and nothing else**, so
restarting the CADR meant a finger on a board nobody is sitting at, or a fresh
bitstream --- on a board that runs Linux beside the machine and is reached
over the network. Mete asked for a soft reboot from the processing system;
page 0's word 6 is it, and **it joins BTN0 rather than replacing it.**

**It is a pulse of a stated length and not a level.** A level is a bit a
program can set and then be killed, or forget, or crash holding, and a machine
held in reset by a level looks exactly like a machine that will not start with
nothing to say which. A write arms a countdown and software cannot extend it,
shorten it or hold it.

**`RESET_T` is 64 ticks, 320 ns.** Every register in `cadr_machine` takes a
synchronous reset, so one tick would clear them all and the number looks
arbitrary --- which is why it has a floor and the floor is written down. The
machine's own power-on reset is never short (`rst_sync` is four deep and
`!mmcm_locked` holds it for the MMCM's whole lock time), so a machine that had
only ever seen a one-tick reset would be released in a way the board never
performs. The floor is **one whole generator cycle at extra slow, 44 ticks**:
that is the longest interval over which any of the machine's own timing is in
flight --- the phase generator's ring, the seven read taps at 15 to 32, the
write pulses, the two countdowns --- and CLAUDE.md already records that muir's
`chip.rs` goes on deriving `-TPR60` from `phase_ns` at ticks 11 to 18 of a
plain power-on reset, so a reset shorter than the cycle it interrupts lands in
a region the model and the fabric are known to disagree in and nothing
compares. 64 is the smallest power of two above 44, so the countdown ends on a
borrow --- which is why `LOST_T` is 4,096 and not 4,000. **It is a floor with
margin and is stated as one**; nothing derives 64, what is derived is that it
must be more than 44.

**The write does not answer until the pulse is over.** `W_RESET` holds the
write channel through the countdown, so `BVALID` is offered after the machine
has left reset. A program's store therefore returns with the machine running
again and the next read of `FLAG-1` means something. It costs one Arm store
320 ns.

**`RESET_KEY` is `"RSET"`, `0x5253_4554`, and an arbitrary value must not
reset the machine.** Chosen the way `cadr_arty.sv` chooses `PROVE_WORD`: four
distinct bytes, none of them `00` or `FF`, halves that differ and neither a
rotation of the other; not zero, not all ones, not `IDENT`, not `UNMAPPED`,
and not what register 6 itself reads back --- so a program echoing anything it
has read from this face cannot reset the machine by accident. A write's
unstrobed lanes are merged against zero as every other write here is, and
**because no byte of the key is `00`, a write that does not strobe all four
lanes cannot equal it whatever those lanes hold.** That is one rule and not
two; the strobes are not tested separately.

**What it clears of the console's own, and what it must not.** `cycles` and
`ticks` are cleared, because they are not the console's: CYCLES is
`Machine::cycles`, zero at reset, and TICKS is `Rtl::ns()`, zero with it. A
CYCLES that went on counting would name a microcycle no row of any trace has.
STAT's `answered` and `lost` are **not** cleared --- they are the console's own
history on the diagnostic bus, and resetting the machine does not make a cycle
that was lost unlost.

**And the console does not reset itself, which is the decision rather than a
detail.** Three reasons, of which the third is the one that would show on the
board. A console that forgot the reset could not report it, and register 6's
count is what a program reads to know the machine in front of it is the one it
restarted. A console reset by the machine's reset would clear STAT, so the
instrument would erase the evidence it exists to carry. And --- the one that
matters --- **the AXI write that asked for the reset is in flight while the
pulse is up**: a reset reaching `wst` drops it back to `W_ADDR` with no
`BVALID` ever offered, and a GP write nothing answers hangs both Arm cores at
one PC each. The console would freeze the machine it was written to un-freeze,
and only the power cycle it exists to avoid would recover the board.

**What takes the pulse on the board, and the rule.** `boards/arty-z7-20/cadr_arty.sv`
declares `mach_rst` as `rst || con_mach_rst`, **registered** --- a register and
not a gate, for the reason `pack_rst` gives at the same shape: it lands on some
two thousand registers spread across `cadr_machine`, and a LUT between the
countdown and that fanout is a LUT on every one of their reset pins. The rule
for what takes it: **`mach_rst` replaces `rst` wherever `rst` means "since the
MACHINE started", and `rst` stays wherever it means "since the FABRIC was
configured".** So `u_machine`, `u_probe`, `witness`, `beat`, `nxm_count`,
`bus_nxm` and LD4's colours take `mach_rst`; `axi_rst`, `pack_rst`, `gp0_rst`,
`gp1_rst`, the tally `u_count` and `error_seen` keep `rst`.

The tidier alternative --- folding `con_mach_rst` into `rst_sync` beside BTN0
--- is wrong in three places at once, and each is on the record in the top
level:

- it would reset the console itself, through `gp1_rst`: the freeze above;
- it would reset the pack side, through `pack_rst`, and Linux's mounted pack
  with it --- `cadr_disk_pack.sv`'s registers are the disk pack program's
  state, not the machine's;
- it would reset `cadr_axi_master` mid-transaction, through `axi_rst`, which
  is an AXI protocol violation the PS7 cannot recover from. It is also
  unnecessary, and the argument is structural rather than about what a program
  happens to do: the machine drops `mem_req` at reset, `cadr_axi_master`
  finishes its transaction and returns to IDLE when it sees that, and
  `cadr_xbus_ddr`'s `dev_ack` is `asked && (done || mem_done)` with
  `asked = sel && dev_rq` --- so a transaction completing into a machine that
  is no longer asking is ignored by construction.

**And the probe re-arms with it**, which is a capability and not a side
effect. `rtl/plumbing/xilinx7/cadr_probe.sv`'s own words are that it fills from the first
microcycle after reset and freezes, so a machine that has been restarted has
new first microcycles and the probe must be looking at those. Until now
re-arming meant BTN0 or a fresh bitstream; it is a store from Linux now. The
price is that a console reset spoils a readout in progress --- which BTN0
already did.

**WHERE THE PULSE LANDS WAS ASKED OF THE DESIGN.** CLAUDE.md's `elapsed ->
md/CE` entry says a relaxed register's clock enable goes with it, and a signal
reaching a reset that drags a long cone into an enable is invisible in a slack
figure. Synthesised at this slice, `DDR=1`, scoped XDC read, `all_fanout -flat
-endpoints_only` from the two `mach_rst_reg` cells:

    the top level's, into cadr_machine   1,008 R, 24 S, 19 D, 12 block-RAM
                                         address bits, 2 ENARDEN, 3 ports
                                         --- AND NOT ONE CLOCK ENABLE
    cadr_console's own                   153 endpoints, 17 of them clock
                                         enables, every one of them
                                         eng_wdata_reg[*]/CE or
                                         eng_for_w_reg/CE inside that file:
                                         the `!mach_rst` gate on `E_IDLE`

Every one of 400 paths out of `mach_rst_reg` asks for **5.000 ns** --- no
exception touches it and none should --- and the worst is +0.472 ns over two
logic levels. `mach_rst` appears **nowhere** in either board's
`report_timing_summary`: `grep -c mach_rst timing.rpt` is 0 for both.

And the cone that arms it is eighteen startpoints, all registers of
`cadr_console`: `wst`, `w_at<6:2>`, `w_in`, `rst_t<6:0>` and `mach_rst`
itself. **The address match is held and not computed**, which is the rule the
memory path and the disk controller are both held to; there is no map, no
`phys` and no `vma` anywhere near it, and there could not be, the module being
outside `cadr_machine`. Measured all the same.

**A CONSOLE RESET DOES NOT CLEAR MEMORY, AND MUST NOT.** `amem`, `mmem`, `pdl`
and `imem` in `cadr_microcycle.sv` are RAM and no reset this machine has
clears them --- not this one, not BTN0's, and not MIT's own `RESET`, which is a
wire into flip flops and reaches no 93425A. So a machine reset a second time
re-executes the boot PROM's instructions from the top with the scratchpads its
first run left. Measured: `amem` diverges on the **first** microcycle of the
replay, A and M reading `0x1fc` where muir says 0, while PC, IR, LPC and OPC
agree for all 600,000. That is the right behaviour: a console reset that
cleared memory would be a **different** reset from the button's, and then
there would be two resets to reason about instead of one.

**What is not exercised, said rather than left to be assumed.** The engine
holds off starting a diagnostic cycle while the pulse is up --- the register
block is inside the machine and in reset with it, so a cycle begun then would
strobe a block that cannot answer and would end on `LOST_T` with STAT's sticky
`lost` set, a lie since nothing was lost. **`tb/cadr_console_tb.cpp` cannot
reach that guard**, because its AXI master runs one transaction at a time and
the read and write channels never overlap. On the board they do: the two
Cortex-A9s can have a read and a write outstanding on GP1 at once. A testbench
with two independent channel drivers is what would exercise it, and there is
no mutation record aimed at it for that reason.

### The virtual address register and Q, page 0's words 7 and 8

**Why there are any.** `../muir/src/spy.rs` is the whole vocabulary of MIT's
sixteen --- `IR` in three halves, `OPC`, `PC`, `OB`, the two flag words, `M`,
`A` and `ST`, and the open bus at register 3 --- and neither the virtual
address register nor `Q` is among them, so a console on that bus alone cannot
see either and MIT's own never could. On 2026-09-10 the board halted inside
`PDL-BUFFER-REFILL`, where the microcode reads a second-level map entry,
writes it back with read/write access ORed in, and then reads through the
entry it has just hacked; **three faults injected into muir reproduce the
board's readout bit for bit** --- same `PC`, `OPC`, `FLAG-1`, `FLAG-2`, `IR`,
`A`, `M` and `OB` --- and are told apart only by these two: the map-side
faults leave them equal, the wrong-address fault leaves them one page apart.

**Where they went and why.** Page 0, words 7 and 8, beside CYCLES and TICKS,
which are also the machine's and are also not on that bus. Page 1 is MIT's
sixteen and is untouched word for word: `EADR<3:0>` names sixteen things and
all sixteen are theirs, so a seventeenth would mean renumbering
`cadr_spy_registers.sv` out of step with `Engine::spy_read` for ever.

**Neither is split into halves.** The sixteen are sixteen bits because
`SPY<15:0>` is sixteen wires, which is why MIT reads `OB`, `M`, `A` and `ST`
as two registers each. Page 0 is not on that bus and its words are 32 bits,
as IDENT, CYCLES and TICKS already are. Four sixteen-bit words would mean four
reads where two do, four latch rules where one does, and a 32-bit comparison
assembled out of four separately-timed reads.

**The split that is made is between the two words, and it carries a latch.**
The read of word 7 latches BOTH, and word 8 reads that latch: **the rule is
VMA then Q**, as it is CYCLES then CYCLESH and for the same reason --- the
question asked of them is whether they are equal, so a pair read as two
independent loads of a running machine is two instants and the answer would be
an artefact of the gap. A burst of two beats over words 7 and 8 is how a
program should ask.

**MD joined that latch on 2026-09-11 and the rule is now VMA first**, a burst
of three beats over words 7, 8 and 9. The section below has it.

**They arrive already captured**, at the microcycle boundary, by
`rtl/machine/cadr_console_state.sv` inside `cadr_machine` --- the same module
`tb/cadr_console_harness.sv` instantiates, not a copy of it. Inside, because
`rtl/plumbing/xilinx7/cadr_machine.xdc` is read `-ref cadr_machine` and cannot relax a register
outside it: that is the wall the console's own read-back met at -12.837 ns.
`mclk` and not `clock_edge`, because `MCLK` runs whether or not `MACHRUN`
does, so a machine the console has stopped goes on refreshing them and the
console reads the state it actually stopped in.

**What the check holds.** `build/console.pass` reads the pair at all sixteen
halts and compares both against `build/rtl.golden`'s own `vma` and `q` columns
for the row the console says it stopped at. **15 of the 16 carry VMA != Q**
and so can tell one from the other; a halt where they read alike is not
evidence and is counted separately, which is the PC lag sweep's own lesson.
Word 8 is read ALONE first at every halt and must give the `Q` the last read
of word 7 latched --- the previous halt's --- of which 2 of 15 were taken
where that latched `Q` and the live one differ.

**And what it does not hold, said rather than assumed:** that the pair is one
instant rather than two reads a few ticks apart. `Q` is `0xfffffffe` on all
but the first thousand rows of MIT's boot PROM, so a pair taken at two
instants reads exactly like a pair taken at one. Measured rather than
reasoned: capturing every tick instead of at the boundary --- `mclk || !mclk`,
which is what catches the same fault in `cadr_console_bus.sv` --- **survives**,
and it is an equivalence under this reference rather than a hole.

**WHERE THE ARCS LAND WAS ASKED OF THE ROUTED DESIGN, AND THE FIRST ANSWER WAS
A FAULT.** `DDR=1`, board flow, routed:

    into the capture, con_*_reg   64 D pins at 75.000 ns --- the relaxed set,
                                  which is the whole reason it is inside
                                  cadr_machine --- and 128 more at 5.000 ns,
                                  the 64 mclk clock enables and the 64 resets
    out of the capture            64 paths, all 5.000 ns, ZERO logic levels,
                                  worst +2.798 ns: con_vma_reg[14]/C ->
                                  g_ddr.u_console/held_vma_reg[14]/D
    into the console's latch      192 paths, all 5.000 ns, 64 of them clock
                                  enables, worst +0.559 ns

**The middle group is the one that was wrong.** Written first with the latch
armed straight off `r_in` and `r_idx` --- five logic levels off `r_at` --- the
routed board put that cone into **sixty-four clock enables** and read
**-0.145 ns** at `r_at_reg[19]/C -> held_q_reg[0]/CE`. That is CLAUDE.md's
`elapsed -> md/CE` in a new place, and it is exactly what a slack figure
cannot tell you. The remedy is the one this repository already prescribes:
**hold the match, do not compute it.** `held_arm` (it was `vq_arm` until MD
joined it) takes the decision at
`R_START` and registers it, the latch happens a state later at `R_PREP` ---
still before `R_PREP2` takes `r_word` --- and what reaches the sixty-four
enables is one flop and no logic. +0.559 ns after.

Neither `held_*` nor `con_vma`/`con_q` appears among the routed board's worst
paths now; those are the disk controller at -0.242 ns and the console's own
reset counter off `MAXIGP1ACLK` at -0.225 and -0.197, all of which predate
this change. **The memory-off board was not fitted for this**, and its cost is
64 flip flops that fold into `witness` with every other output.

### The readout of the machine's memories, page 0's words 10, 11 and 12

**What it is for.** The sixteen diagnostic registers and the three words
beside them are the whole of what a console can see. The machine's own
memories are not among them. The control store, the boot PROM, the A and M
scratchpads, the pushdown buffer, the micro-stack, the dispatch memory and
both levels of the map are inside `cadr_microcycle.sv`, and until this window
existed not one word of any of them left it. Every investigation of a board
that went wrong was conducted through a keyhole.

**It is not the debugger and is not meant to become one.** The debugger for
this machine is CC over the debug cable, which reads the scratchpads and the
pushdown buffer by forcing a microinstruction into the instruction register.
That is the machine's own answer, and using it tests a piece of the CADR
rather than adding a piece that is not the CADR. This window is the crude
thing beside it: cheap, always there, and needing nothing of the machine but
that it stand still.

**How it is read.** Write word 10 with the selector and the word wanted. Read
word 10, then word 11, then word 12. The read of word 10 latches all three, so
the echo and the two halves name one instant. Compare the echo with the
address you wrote: equal means the word is that address's. This is the same
rule the rest of page 0 obeys, where the high half of a counter is latched by
the low half's read.

**The selectors.** 0 is the control store, 16,384 words of 48 bits. 1 is the
boot PROM, 1,024 of 48. 2 is the A memory and 4 the pushdown buffer, 1,024 of
32 each. 3 is the M memory and 5 the micro-stack, 32 words each. 6 is the
dispatch memory, 2,048 of 17 bits. 7 is the level-1 map, 2,048 of 5 bits, and
8 the level-2 map, 1,024 of 24. 9 is the OPC shift register, 8 of 14 bits. 10
is a table of twenty-one of the processor's own registers, which the
diagnostic bus has no register for. A selector this fabric does not map reads
`0xA5A5_5A5A_A5A5`, and out of reset the echo reads `0x3FFFF`, which names
that reserved selector. Neither is a value a memory can hold or an address a
program may ask for.

**It cannot disturb the machine, and that is by construction.** Every memory
has a second read port of its own. Nothing in the readout drives an address,
an enable or a word that the machine reads. The alternative was to mux the
readout's address onto the address the machine already drives, which would
have cost a few dozen lookup tables instead of the two thousand this costs.
It was refused for two reasons. The dispatch memory and both map levels
are written at an address that is the same expression as the read's, so a mux
there moves the write with the read, and a readout that can corrupt the
dispatch memory is not an instrument. And those three addresses are the
machine's own longest combinational chains, which a mux would lengthen to buy
a debugging aid.

**What it costs, measured either side.** On the `DDR=1` board, against the
same commit without it, the readout adds 2,071 Slice LUTs and 2.5 block RAM
tiles, and 503 registers. The worst path is inside the disk controller either
way, so the window is on nobody's critical path, and both boards still meet
their timing. The memory-off board is not a measurement of a live readout: it
has no console, so the address is tied to the reserved selector and much of
the window folds.

**Where the lookup tables went is the interesting half.** The control store's
second port was free, because its read and write addresses are the same net
and it was using one block RAM port; it is a true dual-port memory now at the
same 24 tiles. The boot PROM took a whole second copy. The A memory, the
pushdown buffer and the M memory left block RAM altogether: each already used
both ports of its block RAM, one writing and one reading at different
addresses, and a third port is one more than a block RAM has. The dispatch
memory, both map levels and the micro-stack were distributed RAM already and
doubled.

**Forcing the three back into block RAM was tried and changes nothing.** With
`ram_style = "block"` on the A memory, the M memory and the pushdown buffer,
the fit is identical to the digit: the same 9,589 lookup tables, the same
5,915 registers, the same 39.5 tiles, the same +0.103 ns, and the same three
memories still absent from the block RAM mapping report. Vivado will not build
a memory with one write port and two independent read addresses as two block
RAMs, and it does not say so. So the lookup tables are the price of the window
and not of a missing directive.

**A read taken while the machine runs is a torn sample.** The word comes from
whatever the array held three ticks earlier, and the register table comes from
three boundaries if three reads straddle them. The intended use is a halted
machine, where every array stands and the readout is exact.

**A halted machine still fires its write pulses, and this was found by the
check being wrong about it.** `build/readout.pass` was written expecting every
word to stand while the machine was halted, and three did not. MACHRUN gates
`-CLK0`, which is what stops microcycles retiring. The write pulses come off
the phase generator, which nothing stops, and the last instruction's
destination is therefore re-written once a generator cycle for ever, with the
same word. At most six words can be standing, one for each pulse. It is
harmless, because the word written is the word that instruction was going to
write. It is not nothing, because anything reading those arrays off a halted
board cannot assume they are inert, and because anything that ever WROTE
through this window would be fighting those pulses.

**What the check holds it to.** `build/readout.pass` runs the machine on MIT's
boot PROM, halts it from the console and reads every word of every memory
back, comparing each against the array itself. It then poisons every array
from outside, injectively in the memory and the address, and reads them all
again. The second phase exists because the first tests almost nothing on its
own: the boot PROM's pass over the control store writes zero to all 16,384
words, so against a readout that returned a constant zero the first phase
would pass on the largest memory in the machine. The check prints how many
distinct words each memory held, so that nobody has to take its coverage on
trust. A third phase watches the window's three wires every tick, because a
word a tick staler than its echo is invisible to anything reached over AXI. A
fourth makes every entry of the register table hold a different word, because
at a boot PROM halt Q, VMA and MD all read zero and a mux that crossed any two
of them would agree with the machine at every one.

### MD, page 0's word 9

**Why there is a third word.** The pair above was read on the board on
2026-09-11 at 05:35, with the halt reproduced. The virtual address register
read `0o2640010` and `Q` read `0o600000000`. That virtual address is exactly
what muir shows for the two map-side injections. The wrong-address injection
puts `0o2640410` there instead. So the machine asked for the page it meant to
ask for. What is left is the map, and MD is where the next evidence is.

**What MD is.** MD is the memory data register. It holds the word a completed
read left there, as of the last microcycle boundary. It is not on the
diagnostic bus. `../muir/src/spy.rs` names MIT's sixteen and MD is not among
them, exactly as the pair is not.

**What its reading means, first answer.** A reference the map refuses starts
no bus cycle at all. The cycle is armed by `MEMSTART` and `VMAOK` together. So
a read that page faulted never strobed `-LOADMD`. What stands in MD is the
word before it. Compare that word against muir's own `md` column for the same
microcycle.

**And MD is itself a map index, which is the sharper answer.**
`cadr_microcycle.sv:1006` makes `MAPI` equal `VMA<23:8>` while `MEMSTART` is
up, and `MD<23:8>` otherwise. Those are the 74S258s at VMAS 1C20, whose select
is `-MEMSTART`. So `MD<23:8>` is the entry a `SRCMAP` read looks at.
`VMA<23:8>` is the entry a memory reference goes through. In
`PDL-BUFFER-REFILL` the microcode does one of each. Those two page numbers are
therefore which entry each of them was, and the program prints both.

**It joined the pair's latch and did not stand alone.** A read of word 7 now
latches all three. Words 8 and 9 read that latch. The rule is VMA first, and a
burst of three beats over words 7, 8 and 9 is how a program should ask.

The argument for standing alone is real and is answered rather than ignored. A
three-word latch is not the same object as a two-word one. The read order
becomes a rule a reader can get wrong, and a rule a reader can get wrong will
be got wrong.

What settles it is that MD read live would be a different microcycle from the
pair. A three-beat burst's third beat is several ticks after its first. MD
really does move from one microcycle to the next, being the memory data
register on a machine that makes 17,466 bus cycles in the boot PROM alone. A
program would then print an MD beside a VMA that never stood beside it. That
is this instrument lying about the thing it exists to decide, because "what
did the read through the hacked entry return" is a question about MD at the
microcycle VMA names and about nothing else.

Joining also keeps page 0 to one rule. A low word's read latches what belongs
with it. CYCLES then CYCLESH, TICKS then TICKSH, VMA then the rest. Standing
alone would put two kinds of word on one page and leave the reader to know
which is which.

The rule is then made unmissable where it can be. `cons_read_machine_words` is
the only reader of the three that the Linux program offers, and there is
deliberately no way to fetch one of them on its own. `tb/cadr_console_tb.cpp`
asserts at every halt that words 8 and 9 read alone give what the last read of
word 7 took.

**What the check holds.** `build/console.pass` reads all three at all sixteen
halts. Each is compared against `build/rtl.golden`'s own column for the row the
console says it stopped at. MD differs from VMA at 14 of the 16 halts and from
Q at 15. A halt where two of the three read alike is not evidence and is
counted separately, which is the PC lag sweep's own lesson.

The latch is asserted in value for MD as it is for Q, and this is where MD
earns its place twice over. Word 9 is read alone at every halt and must give
the MD the last read of word 7 took. 13 of those 15 reads are taken where the
latched MD and the live one differ. The same test for Q is evidence at 2 of
15, because Q is `0xfffffffe` on all but the first thousand rows of MIT's boot
PROM.

**What it does not hold.** That the three are one instant rather than three
reads a few ticks apart. Every read here is made at a halt, where none of the
three is moving, so three instants and one read alike. No arrangement of this
reference can tell them apart.

**The arc the constraints claim, measured rather than derived.** Every
register of `cadr_console_state.sv` falls in `cadr_machine.xdc`'s relaxed set,
so the fabric is told each of these three captures has fifteen ticks. That is
a claim about the machine's own behaviour, and an exemption too wide tests
nothing.

It had to be asked for MD in particular. `vma` and `q` are written inside `if
(mclk_edge)` in `cadr_microcycle.sv` and nowhere else, so they cannot move
between boundaries at all. `md` can. `md_pending && (mclk_edge || hang)` takes
the word `-LOADMD` deskewed, in the middle of a parked generator.

So the check measures it every tick over MIT's whole boot PROM. It records the
shortest distance from a change of each source to the boundary that captures
it. Over 1,215,502 boundaries: **VMA 44 ticks, Q 44, MD 26.** All three are
above the fifteen, and MD is the one that is not 44. The check fails below
fifteen, so a reference that stopped exercising this re-opens it.

**And where the arcs land was asked of the routed design.** `DDR=1`, board
flow, routed from a checkpoint, at the working tree this slice was written in:

    into the capture, con_md_reg    96 paths: 32 D pins at 75.000 ns, which is
                                   the relaxed set, and 64 more at 5.000 ns,
                                   the clock enables and the resets.  Worst
                                   +0.663 ns at mach_rst_reg/C ->
                                   con_md_reg[13]/R.  con_vma and con_q are
                                   96 each in the same shape
    out of the capture             32 paths, all 5.000 ns, ZERO logic levels,
                                   worst +2.806 ns:
                                   con_md_reg[25]/C -> held_md_reg[25]/D
    into the console's latch       96 paths, all 5.000 ns, worst +0.310 ns
    out of held_arm                96 paths, all 5.000 ns, and every one of
                                   them a clock enable.  One logic level,
                                   worst +2.121 ns

**The arm is still one flop, which is the thing the pair's slice got wrong
first.** `held_arm` reaches 96 clock enables and no data pin at all, and its
own fanin is 30 startpoints, every one of them `r_at_reg[*]`. That is the
address register, taken at ARVALID and held. So the match is held and not
computed, which is the rule this repository gives every decode, and the third
word joined that arrangement rather than reopening it.

**No failing path touches the capture or the latch.** The board's worst is
-0.233 ns on 79 endpoints, at
`u_machine/disk/ch_state_reg[1]/C -> u_machine/disk/ch_ra_reg[1]/CE`. That is
the disk controller and it predates this change; the same family is recorded
above at -0.242 ns, nine picoseconds away and well inside the quarter of a
nanosecond this project calls placement noise. The third word costs 64 flip
flops, 32 at the capture and 32 at the latch.

### The bound

`LOST_T` (line 167) is 4,096 ticks --- 20.48 us of the machine's own time, and
40.96 us of real time at the 10 ns tick. That much after the request the
engine gives up, drops `dbg_req`, sets STAT's `lost` and answers the read
with bit 16 set. A grant that never comes, or a register block that never
answers, therefore costs the Arm 41 us and not its uptime. `LOST_T` is
checked as a *number* and not merely as "the read came back": the mutation
`console-bound-is-not-a-bound` stretches it to 8,000 and is caught at "a lost
read took longer than the bound". That is `RD_FINISH_T`'s lesson one file
along.

### The arbiter, which is the attachment

`0o766000` is Unibus space and the CADR reaches it itself --- the boot PROM
writes the mode register there --- so the register block has two masters.
`cadr_console` asks with `dbg_req` and waits for `dbg_gnt`; the arbiter is
outside the module because the thing it must see, whether the processor's own
Unibus cycle is running, is `rtl/machine/cadr_memory_path.sv`'s.

**The grant is taken only with the processor's own strobe down, and held
until the console lets go.** Taken any other way it would truncate a Unibus
cycle already counting on `elapsed` inside `cadr_spy_registers`: that module
starts its count at the strobe and clears it when the strobe falls, so a
strobe masked in the middle is a cycle that never answers, and the
processor's own NXM timer is what would find it 4,250 ns later. The other way
round is bounded and safe: while the console has the bus a processor strobe
is masked, so the processor's cycle starts late, and the console holds the
bus for `DIAGNOSTIC_NS` plus the drop --- 260 ns, 52 ticks, against that same
4,250 ns timer. Sixteen to one, and it is the argument the disk channel's
per-word arbiter is held to, one bus along.

## What the check holds to, operation by operation

`build/console.pass` runs `tb/cadr_console_harness.sv` --- the console, the
register block and **the real processor** with MIT's boot PROM in its control
store --- from `build/rtl.golden`, the same trace and the same stimulus
`tb/cadr_microcycle_tb.cpp` drives it from. It takes about fourteen seconds,
twice what it took before the reset landed: the extra seven are the reset's
replay of the whole reference, and CLAUDE.md's rule about `disk.golden`'s
full-length timeout applies --- that is the price of the check.

| operation | held to | where |
|---|---|---|
| the sixteen reads | muir: `Engine::spy_read` | `../muir/src/rtl.rs:2679-2721`; every one of the sixteen is a column of `rtl.golden`, reconstructed by `SpyWord` in `tb/cadr_console_tb.cpp` |
| `FLAG-1` and `FLAG-2` bit order | muir: `Flag1::word`, `Flag2::word`, `Flag2::OPEN` | `../muir/src/spy.rs:396-421`, `561-576`, `559` |
| register 3 reads all ones | muir: `spy::OPEN_READ` | `../muir/src/spy.rs:488` |
| halt | muir: CC's first act, and what it means | `../muir/tests/lashup.rs:152-157`; `../muir/tests/spy.rs:729-741` --- "the microcycle in flight completes", then nothing moves while the master clock runs on |
| `FLAG-1` halted, `0xe800` | muir: its own `HALTED` constant | `../muir/tests/spy.rs:706` |
| `FLAG-1` running, `0xe900` | muir: its own `RUNNING` constant | `../muir/tests/spy.rs:705`, and `examples/cc.rs`'s own running/halted line reads exactly bit 8 |
| start | muir | `../muir/tests/lashup.rs:311-315` |
| CYCLES | muir: `Machine::cycles`, incremented at one place and only there | `../muir/src/rtl.rs:2386`; a halted master clock cycle returns at 2305 and a stall at 2325 without reaching it |
| the machine across a halt | muir, the strongest claim here: after sixteen halts and starts **all 600,000 microcycles still agree column for column** | the trace |
| the GP1 face | a property: AXI3, no muir reference exists | one handshake a channel a burst, payload stable, RLAST where the length says, the ID echoed |
| every address answered | a property, and the board's own failure | measured: an unanswered GP read hangs both Arm cores |
| `LOST_T` | a property, asserted as a number | the check holds the grant off for ever and requires the read to complete and to say it was lost |
| the arbiter | a property | the console must not take the bus with the processor's strobe up, and must not truncate its cycle |
| the mode register write | muir's bit assignment, and read-back | `../muir/src/spy.rs:203-213` for the register, `353-356` for `FLAG-1` bit 12 |
| the reset's key | a property, and this project's own idiom | twelve writes that are not the key pulse nothing; the key does |
| the reset's length | a property, asserted as a number | the ticks the line is up are counted and compared with `RESET_T` |
| the machine after a reset | muir: `Engine::boot` is reset then run | `run` up and `promdisable` down, and it re-executes all 600,000 microcycles of the boot PROM from zero --- PC, IR, LPC and OPC |
| the console after a reset | a decision, argued in the module | IDENT, STAT's sticky `lost` and the reset count all stand, and the AXI write that asked completes |
| `-PROG.RESET`, `PROG.BOOT` | muir: pulses and not settings | `../muir/src/spy.rs:229-234`, `../muir/src/busint.rs:254-263`; that they are *made* is checked here, what they reach is the machine's |

**Five signals this check compares with muir that nothing else in the
repository ever has.** `Rtl::spy()` names twelve and `cadr_microcycle.sv`
brings out four. `WMAPD`, `DESTSPCD`, `IMODD`, `PDLWRITED` and `SPUSHD` --- the
write-pipeline enables, the 74LS244 inputs on SPY2 3F15 --- are internal to the
processor and appear on no port; grepping `rtl/` and `tb/` for their names
returns `cadr_microcycle.sv`, this check's testbench, and one comment ---
`rtl/plumbing/xilinx7/cadr_probe.sv:103-104`, which lists exactly these five among the columns
it cannot carry "because `cadr_machine` has no port for it". They are `FLAG-2`'s bits 13, 12, 10, 9 and 8, and reading that
register through the console is what compares them. Because which of them a
given microcycle carries is the boot PROM's business and not the check's, the
console also makes a few extra halts in the windows where the reference says
each enable lives --- PDLWRITED on rows 83 to 9,299, DESTSPCD on 9,303 to
9,427 and nowhere else in the run, SPUSHD from 9,303, IWRITED on 410,840 to
525,521 --- and the run **fails** if any of the six was down every time.

**A budget per flag and not one pool.** Three hundred hunts starting at row 80
never reached row 9,300, and DESTSPCD, SPUSHD and IWRITED went unmet while the
run reported itself content. Measured, and fixed.

## What is NOT checked, and why

**Single step.** The board's is `SSTEP` and `SSDONE`, two flip flops of the
74S174 at OLORD1 1A10, and `MACHRUN`'s first term `SSTEP AND -SSDONE`
(`../muir/src/rtl.rs:1119-1128`). `rtl/machine/cadr_microcycle.sv` has neither and
says so at its port list --- "the fabric has no console yet" --- and
`cadr_spy_registers.sv` takes bit 0 of a CLK write and drops bits 4:1. So a
write of 2 to the clock control register goes down the diagnostic bus, lands
in nothing, and the machine does not move. The check **measures and prints**
this rather than asserting muir's answer, because asserting it would leave
`console.pass` red for a defect in two files this slice does not own. It
reads, on the check's own output: *"a write of 2 to the clock control
register moved the machine on 0 of 16 halts (muir: one microcycle each)"*.
The two hunks are named below.

**The write-strobe aliasing.** muir's `spy::write_strobe` is `eadr & 7`
(`../muir/src/spy.rs:126-130`): `EADR3` does not reach the write decoder --- the
74S138 at SPY0 1F03, whose `G1` is `HI1` --- so a write at register 13 loads the
mode register. `cadr_spy_registers.sv` compares all four bits of `held_eadr`
and does not. Measured and printed for the same reason: *"a mode write at
register 13 landed 0 times (muir's `write_strobe` is `eadr & 7`, so: once)"*.
One line, named below.

**The two pulses reach nothing.** `-PROG.RESET` and `PROG.BOOT` leave
`cadr_spy_registers` and are folded into `unused` at `rtl/machine/cadr_machine.sv:425`
at this slice. The harness brings them out and the check sees them made; what
they should *do* --- reset the machine, raise `BOOT.TRAP` --- is the machine's and
is not built. **This is NOT what page 0's word 6 does**, and the two must not
be confused: `-PROG.RESET` is MIT's own, made inside the machine off a mode
write and reaching the machine's own reset tree, and word 6 is the console's,
made outside the machine and ORed with BTN0 in `cadr_arty.sv`. Whoever lands
`-PROG.RESET` should say how the two meet; the obvious answer is that they
meet at `mach_rst`, and it is not taken here.

**Examine and deposit of main memory do not go through the machine, and
cannot.** In muir, CC reaches the debuggee's memory **not** through the spy
registers but through the debuggee's Unibus map: map register 17 at
`0o766176` loaded with the Xbus page, then two half-word Unibus cycles at
`0o140000 + 17*0o2000 + 4*(loc & 0o377)`, low half then high, with a write
buffer on the write side and a read buffer on the read side
(`../muir/src/lashup.rs:262-284`, `../muir/src/machine.rs:518-580`,
`../muir/tests/lashup.rs:712-769`). **Half of that route is in the fabric
now and the other half is not.**
`rtl/machine/cadr_busint_regs.sv` answers `0o766140`--`0o766176`, so the
sixteen map registers store and read back. What no slave answers is the
mapped window at `0o140000`--`0o177777`, and the read and write buffers a
mapped cycle makes a word out of are not built either. Their one master is
the debug cable's and that cable has no side here. A route with registers and
no cycle is still not a route, so `cadr-console` examines and deposits
through `/dev/mem` on the machine's reserved DDR region instead, at
`rtl/plumbing/cadr_ddr_map.sv`'s own address arithmetic, and says in its own output
that it is reading DDR directly and not through the machine. The two are not
the same claim: a word read through the machine passes the map, the decode
and the bus interface, and a word read out of DDR does not.

**The high halves of CYCLES and TICKS are not tested in value.** The boot PROM
is 600,000 microcycles and 27 million ticks, so neither counter comes near its
thirty-second bit. The burst reads both halves as one transaction, which
exercises the latch's shape; nothing here can tell a latched high half from a
live one. Asserted as zero rather than assumed, so that a longer reference
re-opens it, and said on the check's own output.

## The mutations

Seven records in `mutations/list.txt`, all caught, each on its own line ---
measured by applying each by hand and reading the first line of stderr, not
inferred from an exit code:

    console-reads-the-register-after-the-one-asked
        microcycle 3 (PC 45): diagnostic register 2, IR<47:32>, reads ffff,
        the reference says 0000
    console-write-goes-out-as-a-read
        tick 2290: a halted machine ran a microcycle is 0x33, the reference
        says 0x6
    console-ident-is-not-cons
        tick 13: IDENT is 0xbcb0b1ac, the reference says 0x434f4e53
    console-does-not-answer-an-address-it-does-not-map
        an AXI transaction did not complete inside the engine's own bound
    console-bound-is-not-a-bound
        a lost read took longer than the bound is 0x1f49, the reference says
        0x1000
    console-says-a-lost-cycle-was-answered
        STAT's answered bit after a lost cycle is 0xc, the reference says 0x8
    console-read-back-is-not-held-to-the-boundary
        the read-back's lag in microcycles is 0x0, the reference says 0x1

Six more for the reset, in the same shape:

    console-resets-the-machine-on-any-value
        a write of zero pulsed the machine's reset
    console-reset-pulse-a-tick-short
        the ticks the machine's reset was held for is 0x3f, the reference
        says 0x40
    console-answers-the-reset-write-before-the-machine-is-back
        the write answered with the machine still in reset is 0x1, the
        reference says 0x0
    console-resets-itself-with-the-machine
        an AXI transaction did not complete inside the engine's own bound is
        0x3, the reference says 0x0
    console-forgets-that-it-reset-the-machine
        resets counted after one reset is 0x0, the reference says 0x1
    console-counts-microcycles-across-its-own-reset
        CYCLES after a console reset is 0x124f82, the reference says 0x927c0

## The processing system

`boards/arty-z7-20/vivado/ps7_config.tcl` turns `PCW_USE_M_AXI_GP1` on, merged over Digilent's
verbatim block at the bottom beside `S_AXI_HP2`; the sha256 the header quotes
of that block is unchanged, so its claim still holds. `boards/arty-z7-20/vivado/gen_ps7.py`
brings the twenty-seven `MAXIGP1*` pins out under the name rule, `gp1_*`.

**Those three files are in the attachment patch and not in the tree, and the
reason is a finding worth keeping.** A PS7 pin brought out of the wrapper and
connected by nobody is a Verilator `PINMISSING`, and `build/arty.pass` lints
five board configurations: exposing GP1 without wiring it drew **27 warnings
and stopped the check**, on the DDR and both proving boards. That is the same
safety net that found `dev_wdata` connected to nothing. So the wrapper change
and the top level's wiring are one atomic change and travel together; putting
the wrapper in the tree alone would leave `make check` red on a defect nobody
could fix without the other half. Measured at this slice.

**Enabling `M_AXI_GP1` changes the start-up routine by nothing.** Measured at
this slice under Vivado 2026.1: `boards/arty-z7-20/vivado/ps7_init.ops` regenerated with GP1 on
is **byte-identical** to the one committed with it off --- 673 operations, 24
procs, across all three silicon revisions. So the loader does not change and
there is no decision to take. That is the same answer HP0 and HP1 gave at 64
bits, and for the same reason: a GP port is 32 bits, there is no width to
choose, and Digilent's block already gives GP1 the same four read and write
threads and the same `EN_MODIFIABLE_TXN` GP0 has.

**GP1's window is `0x8000_0000`-`0xBFFF_FFFF`**, and the number comes from
Vivado's own words rather than from memory:
`$XILINX_VIVADO/data/ip/xilinx/processing_system7_v5_5/bd/bd.tcl` lines 125
and 135 --- *"Valid range for M_AXI_GP0 is 0x40000000 - 0x7fffffff. Valid range
for M_AXI_GP1 is 0x80000000 - 0xbfffffff"*.

**`README.md` puts the console on GP0 and the debug cable on GP1, and this
slice does the opposite. That is a decision, not an oversight, and it is
not mine to take.** `README.md`'s paragraph is reasoned: the console masters
the machine's own Unibus and so exercises nothing of the debug block, while
muir over GP1 goes through the real debug block and tests it. What argues the
other way is concrete and is why this slice landed on GP1: **the slave that
owns a GP port must answer the whole of it**, and GP0 is already answered end
to end by `cadr_disk_pack.sv` (SLVERR outside its window, anywhere in the
gigabyte) or by `cadr_gp0_default.sv`. Putting the console on GP0 therefore
means an address decode and a mux in front of the pack side, in a file this
slice does not own; putting it on GP1 costs one `PCW_*` property and changes
`ps7_init` by nothing. Moving it back is one parameter at the instantiation
(`REG_BASE`) plus that decode. If the debug cable wants GP1 later, the two can
share it the same way --- with a decode in front --- or the console can move.

## The attachment

**`rtl/plumbing/cadr_console.sv` is not wired into `boards/arty-z7-20/cadr_arty.sv` by this slice.**
Another session is in `cadr_machine.sv`, `cadr_memory_path.sv` and
`cadr_arty.sv`, so the wiring is a written patch and not an edit:

    ~/.cache/muir-fpga-console-attachment.patch

against `d77cdae`, `patch -p1` from the repository root. It touches **eight**
files and no others: `rtl/machine/cadr_memory_path.sv`, `rtl/machine/cadr_machine.sv`,
`boards/arty-z7-20/cadr_arty.sv`, `Makefile`, `mutations/run.py`, and the three that carry
`M_AXI_GP1` --- `boards/arty-z7-20/vivado/ps7_config.tcl`, `boards/arty-z7-20/vivado/gen_ps7.py` and the
generated `boards/arty-z7-20/cadr_ps7.sv`. `make current` passes immediately after it,
because the generated file is in the patch beside the generator; `make ps7`
regenerates it identically.

**It is verified and not merely written.** `tb/cadr_console_harness.sv` is the
same arbiter and the same mux, so `build/console.pass` holds them; and the
patch was applied to a clean export of `d77cdae` (with this slice's
`boards/arty-z7-20/cadr_ps7.sv` and `rtl/plumbing/cadr_console.sv` beside it) and **all five board
configurations lint clean** --- default, `PROBE_DEPTH=1024`, `DDR=1`,
`PROVE=1`, `PROVE=2`. Two faults were found that way and fixed before this
was written: the console's three outputs from `cadr_machine` were unread on
the board with no PS7, and the fix is the one `cadr_arty.sv` already
prescribes --- they go into the `witness` fold with the other fifty-nine, whose
comment says in as many words that "a fold with exceptions in it is not a
rule anybody can check".

What the patch does, file by file:

**`rtl/machine/cadr_memory_path.sv`** --- eight new ports (`con_req`, `con_gnt`,
`con_msyn`, `con_write`, `con_addr`, `con_wdata`, `con_ssyn`, `con_rdata`),
and an instance of `rtl/machine/cadr_console_bus.sv` between them and the register
block: the arbiter began as four `assign`s inline here and is a module of its
own now, for the reason the timing section below gives. Nothing else in the
file changes, and with `con_req` low the arbiter folds to a constant and the
mux to the processor's own half --- which is what `build/machine.pass`
compares, byte for byte before and after.

**`rtl/machine/cadr_machine.sv`** --- the same eight ports, passed straight through to
the `memory` instance.

**`boards/arty-z7-20/cadr_arty.sv`** --- the eight signals declared at module scope, added to
the `u_machine` instantiation, tied off on the board with no PS7 and folded
into `witness`; and inside `g_ddr`, the `gp1_*` wires, a reset synchroniser on
`gp1_aresetn`, the `cadr_console` instance and the PS7's twenty-seven GP1
pins. The console sits **outside** `g_pack`: every board with a processing
system has one, because the console is what says whether the machine is
running and a board that can only be watched through its lamps cannot answer
that. The machine is deliberately **not** reset with the port: a console that
reset the machine when Linux came up could never be attached to a running
machine, which is the only time it is wanted.

**`Makefile`** --- `rtl/plumbing/cadr_console.sv` added to `arty.pass`'s prerequisites
and to its three PS7 command lines.

**`mutations/run.py`** --- the same file added to `arty_check`'s three PS7
board tuples.

### The two hunks that would give the console a step

Not in the patch, because they are in two files this slice does not own and
because each needs a check of its own. Named here so that the next person does
not have to find them:

**`rtl/machine/cadr_spy_registers.sv`**, at the CLK register's write. It is

    REG_CLK: run <= held[0];

and the board's clock control register is five bits: `RUN`, `STEP`, `NOP11`,
`IDEBUG`, `LDSTAT` (`../muir/src/spy.rs:266-281`). `STEP` at least has to
leave the module.

**`rtl/machine/cadr_microcycle.sv`**, at `MACHRUN`. It is

    assign machrun  = srun && !errhalt && !stathalt && !wait_;

and the board's 9S42 at OLORD1 1A15 has six inputs: `SSTEP`, `-SSDONE`,
`SRUN`, `-ERRHALT`, `-WAIT`, `-STATHALT`
(`../muir/tests/halt.rs:145-163`, which reads them off the netlist pin by
pin). `SSTEP` and `SSDONE` are `STEP` registered once and twice on `MCLK5A`
at OLORD1 1A10 (`../muir/src/rtl.rs:1976-1978`), and a single step's
`MACHRUN` deliberately does **not** go through `-WAIT`
(`../muir/src/rtl.rs:2313-2315`), so its microcycle runs with the bus still
busy. `../muir/tests/spy.rs:715-767` is the timing to hold it to, tick by
tick, and it is a check that could be written the day the hunks land.

Whoever lands them should also fix the write-strobe aliasing above at the same
time, since it is the same register block and one line.

## The timing, and the -12.837 ns

**The console's first bitstream missed its own clock by two and a half
ticks**, and the way it did is worth more than the fix. At `37711fe`, `DDR=1`,
board flow, the fabric then at 200 MHz and a tick then 5 ns:

    Slack (VIOLATED) : -12.837 ns
    Source:            u_machine/processor/md_reg[15]/C
    Destination:       g_ddr.u_console/eng_rdata_reg[1]/D
    Requirement:       5.000 ns
    Data Path Delay:   17.703 ns (logic 5.301, route 12.403)
    Logic Levels:      24 (LUT3=1 LUT5=1 LUT6=10 MUXF7=6 MUXF8=4 RAMS64E=2)

on **5,698 failing endpoints of 27,144**, total negative slack -8,309 ns,
where the commit before the console read -0.148 ns on the same board. It was
never fitted before it landed; that is how it got in.

**The path is `Engine::spy_read` itself.** MD into the M bus's source mux and
then into the sixteen-way diagnostic mux --- the whole of what a console read
selects among. Twenty-four levels is what that costs, and **nothing at the far
end can shorten it**: any register that samples the mux inherits the same
cone, so pipelining after it, deskewing it, or capturing it later all leave
the arc exactly where it was. Three of those were tried on paper before the
fourth was seen.

**What was wrong was the deadline, not the depth.** `rtl/plumbing/xilinx7/cadr_machine.xdc`
already relaxes `-from $slow -to $slow` to fifteen ticks, and `md_reg` is in
`slow`; the console's register was not, **because that file is read
`read_xdc -ref cadr_machine` and the console is a level above it**, in
`cadr_arty.sv` beside the PS7. It is the same wall `mem_addr` met --- a scoped
file cannot name what is outside its scope, and that is why `rtl/plumbing/xilinx7/cadr_ddr.xdc`
exists at all. So the arc was slow-to-fast, which the exception does not match
and must not.

**The remedy is a register in the right module, and no new exception at all.**
`rtl/machine/cadr_console_bus.sv` is the arbiter, the mux and the read-back register,
instantiated by `cadr_memory_path.sv` --- inside `cadr_machine`, where the
register falls into `slow` with no naming. `report_exceptions` on the fitted
board lists **the same seven exceptions as before**; nothing was added to be
defended.

**And it earns the set on the file's own test rather than by being in the
right module**, which is the distinction that file's prose insists on. The
test is "is a register's input stable across the microcycle, and does its
consumer read it only at the end". So `con_rdata` is loaded **at the
microcycle boundary and nowhere else** --- `mclk` is its whole clock enable
--- and is therefore launched at one boundary and captured at the next, with
29 ticks to settle at normal speed and 44 at extra slow against the 15 the
exception asks for. Loaded every tick it would be a register holding whatever
a relaxed path had reached, which is the too-wide exemption in its purest
form.

**The price is stated, and it is measured rather than asserted: the console
reads the machine as of the last microcycle boundary.** One microcycle, and
the check measures the number --- 48 reads of `PC` **with the machine
running**, of which 47 were taken where the two candidate rows carry
different PCs and so are evidence at all. A halted read cannot resolve this,
the machine having stopped moving, which is why the sweep exists and why it
is not made where the rest of the check reads.

**A sample where the candidate rows read alike is not evidence, and taking
one as evidence is how this measurement first went wrong.** The search
returns the smallest matching lag, so a PC that did not move between two rows
reads as a lag of nothing whatever the design does: twenty of twenty-one
samples said one and the first said nothing, which is the check reporting the
boot PROM's program rather than the fabric. Only discriminating samples are
counted now, and there is a floor on how many.

`console-read-back-is-not-held-to-the-boundary` is the record that holds the
property the set membership rests on --- `mclk || !mclk`, so that `mclk` stays
read and lint does not catch it instead of the check --- and it is caught at
"the read-back's lag in microcycles is 0x0, the reference says 0x1".

**Why it is right that the console reads a boundary and not a tick**, three
ways: it is muir's own semantics, `Engine::spy_read` being called between
steps and `Rtl::signals` "recorded in the read phase"; it is exact on a
halted machine, which is how a console is used, `MCLK` running whether or not
`MACHRUN` does; and on a running machine the board is worse, the 74LS244s
driving `SPY<15:0>` asynchronously and MIT's own note being that "read and
write at the same address are uncorrelated".

**The request side is registered here too, and for the same reason as the
answer.** `sr_addr` is `EADR<3:0>`, which is that same mux's *select*, so
`eng_eadr` in the console reaching `con_rdata`'s D would have been a second
long path with one tick to run in --- fast-to-slow, which the exception does
not match. Held inside the machine, both ends are `cadr_machine` registers and
it has the microcycle. It costs the console one tick at the start of a cycle
it holds for fifty-two.

**And re-running every record aimed at every file this fix touched found one
that had already rotted.** `the-request-path-reaches-no-pin` anchors on the
last line of `cadr_arty.sv`'s `witness` fold, and the attachment appended the
console's three outputs to exactly that line; the record went UNAPPLIED ---
`@old` matching zero times, which stops the run rather than passing quietly.
It is the anchor rotting loudly, the case that file's format is designed for,
and it is the reason a slice re-runs the records aimed at a file and not only
its own. Fixed, and the record says why it moved. After it: `arty` 7 of 7,
`memory_path` 10 of 10, `tv` 20 of 20, `console` 7 of 7, all caught.

### The reset's own fit, and what it is not

**Measured in an isolated copy of the working tree at HEAD `1d3a9bc` plus this
change --- NOT of a commit**, because the session that made it may not write
git history. Nothing under `rtl/` or `boards/arty-z7-20/vivado/` in that copy was uncommitted
except `cadr_arty.sv` and `cadr_console.sv`, both of them this change, so it
is HEAD plus exactly this and nothing else --- checked file by file against
`git show HEAD:` before the run, and the copy is why a module another session
added to `rtl/` afterwards cannot have reached it. Board
flow, `boards/arty-z7-20/vivado/bitstream.tcl`, both configurations, zero critical warnings:

                            HEAD 1d3a9bc      + the reset
    DDR=1  worst slack      -0.049 ns         -0.209 ns
           failing          1 of 27,044       101 of 27,142
           total negative   -0.049 ns         -6.650 ns
           hold             +0.051 ns         +0.048 ns
           LUTs / regs      6,923 / 5,036     6,978 / 5,067
    DDR=0  worst slack      +0.132 ns, MET    +0.084 ns, MET
           failing          0 of 16,028       0 of 16,028
           LUTs / regs      3,025 / 1,566     3,032 / 1,566

**The memory-on board did not close before this change and did not close
after it --- both at the 5 ns tick they were built at --- and the 0.16 ns
between them is not the reset.** `grep -c mach_rst`
on both `timing.rpt` files is **0**: the reset appears in neither report. Every
failing path in both is the disk controller's, and the three builds name three
different ones ---

    HEAD           -0.049  u_machine/memory/ch_own_reg/C -> disk/ch_state_reg[0]/D
    + the reset    -0.209  disk/ch_state_reg[1]_rep/C -> disk/ch_slot_reg[0]_replica_1/CE
    isolation      -0.247  disk/da_reg[28]/C -> disk/u_cyl_reg[6][0]/CE

--- where **the isolation build is this change with the pulse made and folded
but NOT reaching the machine**, one line at `u_machine`'s instantiation. It is
the WORST of the three. So the reset net is not what moves the number: what
moves is where the placer puts a disk controller that was already sitting at
zero, and CLAUDE.md's own figure for that is a quarter of a nanosecond. Three
builds, three worst nets, 0.198 ns between the best and the worst, and the
build with no reset net at all is the bottom. **Reported as a number and not
as a regression**, and the isolation build is the evidence rather than the
reasoning.

**The numbers, fitted in isolated trees at `3198d8b` plus this slice**, board
flow, `boards/arty-z7-20/vivado/bitstream.tcl`, both configurations, zero critical warnings and
zero errors:

                            before (37711fe)      after
    DDR=1  worst slack      -12.837 ns            -0.159 ns
           failing          5,698 of 27,144       27 of 27,125
           total negative   -8,309.396 ns         -1.175 ns
           hold             +0.031 ns             +0.052 ns
    DDR=0  worst slack      not measured          +0.036 ns, MET
           failing                                0 of 16,031
           hold                                   +0.082 ns

**The console appears nowhere in the fitted report.** `grep -c console` on
`timing.rpt` is 0; all ten worst paths are the disk controller's, from
`trap_step_reg[9]` into `ecc_r_reg[*]/CE` at 4.724 ns over five levels, which
is the same family the commit before the console reported at -0.148 ns. The
board is back where it was, eleven picoseconds apart --- inside the quarter of
a nanosecond CLAUDE.md calls placement noise, and reported as a number rather
than as closure. The memory-off board **meets timing**.

Utilisation, `DDR=1`: 7,318 LUTs (13.76%), 5,080 registers, 37 block RAM
tiles, 4 DSPs. `DDR=0`: 3,712 LUTs, 1,567 registers. These are not comparable
with the 6,887/5,060/38 quoted at `37711fe` --- three commits landed between,
one of them the display --- so they are the shape of this tree and not a
delta.

**AND THE NAMING WAS ASKED OF THE DESIGN RATHER THAN ASSUMED**, which is what
that file's own prose demands and what a slack figure cannot tell you:
synthesised with the scoped XDC read, every one of 400 paths into
`con_rdata_reg[*]/D` asks for **75.000 ns**, worst `vma_reg[14]/C` over 24
logic levels with **57.148 ns of slack**. The register really is in the set.

**And the question caught this slice's own prose being wrong.** A relaxed
register's clock enable is relaxed with it --- CLAUDE.md's `elapsed -> md/CE`
--- so the enable was asked about too. What was written first, in the XDC and
in the module, was that the enable is not relaxed at all, since `mclk` is made
from `tpclk` and `tpclk_q` and both are excluded from `slow`. The design says:

     5.000 ns   u_machine/processor/u_phase_gen/tpclk_reg   x64
     5.000 ns   u_machine/processor/tpclk_q_reg             x64
    75.000 ns   u_machine/processor/started_reg             x64

Right about the half that decides --- the two that make the edge stay at one
tick, and a boundary arriving a microcycle late would put the capture anywhere
--- and wrong about the whole. `started` goes high at the first boundary out
of reset and never changes again, so it is the one register in the design for
which a fifteen-tick relaxation cannot mean anything. Both comments say the
measured thing now. **The reasoning read as true and was not, and only
`get_property REQUIREMENT` told the difference.**

## What Linux does

`boards/arty-z7-20/linux/buildroot/package/cadr-console/` is the program `cadr-console`, and
`boards/arty-z7-20/linux/buildroot/package/cadr-common/` is what it and the disk pack program
now share --- the `/dev/mem` mapping, the EMIO tally's marker-bit guard, the
`"NONE"` word the proving boards answer with, and the logging prefix. The
guards run in order, before anything: the tally's marker bits
(`(w & 0x80008000) == 0x00008000`, which neither an absent instrument's all
ones nor a gated clock's all zeros can produce), then IDENT. A read nothing
answers on a GP port hangs both cores.

**`cadr-common` is a static library in the staging tree and not a header of
`static inline`s, and the reason is `say()`.** It writes to one destination a
program chooses once --- `--log /dev/console` for the disk's init script ---
and that destination is a file-static. Inline in a header it would be one
file-static per translation unit, so a two-file program would have two log
destinations and an init call in one would move only its own. A library has
one definition and cannot do that. `pack_ecc.h` is header-only for the
opposite reason: arithmetic, and no state. Buildroot's `SITE_METHOD = local`
rsyncs only a package's own `src/`, so a relative include of a sibling
package builds on the host and fails on the target; each consumer's
`src/Makefile` therefore names **two source lists and which build each is
for** --- `COMMON=staging` links `-lcadr-common`, `COMMON=host` compiles the
common `.c` files by path, and `make check` is always the host list.

**`cadr-console` has no `reset` command yet**, and adding one is a store of
`0x52534554` to `REG_BASE + 0x18` plus a read of the same word to report the
count. It is deliberately not written here: `boards/arty-z7-20/linux/` is another session's and
`docs/console.md` is where the next person finds the key. The host check in
that package models the slave and would want the register modelled with it.

`cadr-console` offers, from the command line and from a small prompt: `halt`,
`start`, `step N`, `regs`, `status`, `examine` and `deposit`. `status` is the
question of the day and answers it the way `main.rs`'s `machrun_low` does,
plus a positive measurement: CYCLES sampled twice a few milliseconds apart, so
that "running" is something seen rather than inferred. `step N` reports
plainly that the machine did not move and why, naming this file --- a silent
no-op is the failure this project keeps meeting.

**There is no init script**, and `cadr-console.mk` says why: the console is a
person at a prompt, and started at boot it would hold a second master on the
diagnostic bus for as long as the board was up, taking the bus from the
processor's own cycles with nobody reading what it said.

**The host check** is `make -C boards/arty-z7-20/linux/buildroot/package/cadr-console/src
check`, on the build host, needing nothing but a C compiler; scratch under
`~/.cache/muir-fpga-console`. It runs the program's core against a model of
the slave --- the two pages, the latch, the lost bit, `UNMAPPED`, and a
modelled machine whose CYCLES advances only while RUN is set --- and holds 149
checks. The model is a model and not the RTL, and says so at its head, as
`feeder_test.c` does; the RTL is held to the same contract by
`tb/cadr_console_tb.cpp`.

**The mutation runner cannot reach a C program** --- it copies `rtl/`, `tb/`
and `boards/arty-z7-20/vivado/` by pathspec and has no check for one, and a record naming a
check the runner has no entry for kills the whole run at parse, for every
record. So the substitute is eight mutations applied by hand to a scratch
copy and reverted, and this table is the record of them. All eight caught:

    register index off by one              console_test.c:322
    the guard's marker test as `!= 0`      console_test.c:298
    FLAG-1's SRUN read from bit 9          console_test.c:329
    CYCLES's two halves swapped            console_test.c:531
    a lost cycle's bit 16 taken for data   console_test.c:610
    `step` reports nothing                 console_test.c:425
    FLAG-2's four open bits dropped        console_test.c:495
    CYCLESH read before the low word       console_test.c:531

`make -C boards/arty-z7-20/linux/buildroot/package/cadr-disk-pack/src check` is byte-for-byte
what it was before the move --- 76 requests, 72 answered, 4 denied, 67 blocks
--- re-run from a cleared work directory so that it was a build and not a
stale binary.

## What is not built

- Single step, and everything that needs it: `CC-EXECUTE-R` and
  `CC-EXECUTE-W`, which are how a console examines and deposits the
  scratchpads, the stack, the dispatch memory and the statistics counter.
  They load a microinstruction into the debug IR and clock it under `NOP11`
  and `IDEBUG` (`../muir/tests/spy.rs:772-822`), and the debug IR's three
  halves are written through registers 0, 1 and 2 --- which this module already
  carries, and which land in nothing.
- The OPC history, `CC-SAVE-OPCS`: eight `OPCCLK` pulses on a halted machine
  read the eight PCs out oldest first (`../muir/tests/spy.rs:831`). The OPC
  control register is register 4 and `cadr_spy_registers.sv` drops it.
- The mapped Unibus window at `0o140000`--`0o177777` and its read and write
  buffers, and with them examine and deposit *through the machine*. The
  map's sixteen registers themselves are built.
- The debug cable, which is a different instrument on a different port and
  has a section of its own in `README.md`.
- **Writing a memory through the readout window.** The window reads and does
  not write. Writing one would have to fight the write pulses a halted machine
  goes on firing, and nothing has asked for it.

## The program that reads it

**`cadr-readout`, in its own Buildroot package.** It halts the machine, reads
what the window reaches and prints it, and starts the machine again. With no
argument it prints the register table with the flag word's bits named. With
`--dump NAME` it prints a whole memory, a word a line, in a form `diff` will
take against another dump. With `--word NAME:ADDR` it prints one word, and
with `--list` it says what the window reaches. It compares the echo on every
word and refuses any word whose echo is not the address it asked for.

**It is not the debugger and is not meant to become one.** The debugger for
this machine is CC over the debug cable, which reads the scratchpads and the
pushdown buffer by forcing a microinstruction into the instruction register.
That is MIT's own answer and it tests a piece of the CADR rather than adding a
piece that is not the CADR. This is the crude thing beside it.

**What holds it.** `build/readout_face.pass` runs the program's core against a
model of the window on the build host, with a poisoned machine behind it. It
holds the transport: that the address goes where the window takes it, that the
three words are read in the order that latches them together, that the machine
is halted first and started again, and that a word whose echo is not the
address asked for is refused. The fabric is `build/readout.pass`'s to hold.

**A checkpoint is built now, and `docs/checkpoint.md` is it.** This paragraph
used to say it was not, and the reason it gave still stands: the window
reaches the processor's memories and registers and nothing else, so the disk
controller, the I/O board with its microsecond clock, the bus interface's own
registers and the display's control side are all outside it. What changed is
that this turned out not to be a reason to refuse. A netlist checkpoint muir
itself takes is taken "between cycles with nothing in flight", and a machine
the console has halted at a microcycle boundary is such a point, so every
in-flight field is at the value a machine that has never issued a cycle has.
The rest is written at the value the fabric BEHAVES as, and **every field that
is a decision rather than a reading is named** --- on the program's own output
every time it runs, by `cadr-checkpoint --what-it-cannot-read`, and in
`docs/checkpoint.md`'s table with what each costs a resume. The two that
change what a resumed machine does are the disk controller, whole, and the
microsecond clock. Anything CC can read can still be written into that format
later, through a path that is the machine rather than beside it.
