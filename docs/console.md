<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->
# The console

Written at the console slice, 2026-09-10, against `rtl/cadr_console.sv` as it
stands at this slice. Numbers and line ranges below are measured at that
point; read the date on anything that looks like a fact about the fabric.

**The machine goes quiet and nothing built can say why.** On the board the
CADR loads its microcode from its pack, does a fixed amount of disk work and
stops moving. The lamps say a beat is running and the probe sees only the
first 1,024 microcycles, which is 0.17% of the boot PROM and structurally
cannot be moved (`rtl/cadr_probe.sv`: it fills from the first microcycle after
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

`rtl/cadr_console.sv` is a **master on the diagnostic bus with an AXI slave
face on `M_AXI_GP1`**. It is not a second copy of the register block:
`rtl/cadr_spy_registers.sv` is the register block, it is not touched by this
slice, and the console drives its Unibus port exactly as `cadr_busint_xbus`
does. Its timing --- `-UB SSYN` at `DIAGNOSTIC_NS` after the strobe, the write
pulse's leading edge `REGISTER_PULSE_NS` before the register loads, and the
rule that a write lands at the machine's next look rather than at the strobe
--- is the board's, is already checked against muir by `build/machine.pass`,
and is what this module drives. A console that reached around it would be a
second description of one thing, and the two would drift.

### The register map

**Thirty-two words at `REG_BASE`, two pages of sixteen**, in
`rtl/cadr_console.sv`'s header (lines 32-77 at this slice) and its read mux
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
     4  TICKS    200 MHz ticks since reset, bits 31:0 --- `Rtl::ns()` / 5
     5  TICKSH   bits 63:32, latched when TICKS was read
     6  RESET    **the one word of page 0 that is written.**  A write of
                 `RESET_KEY` and of nothing else pulses the machine's reset
                 for `RESET_T` ticks.  It reads
                   bits 31:16  `RESET_KEY`'s own top half, `0x5253`, a marker
                   bits 15:8   console resets since the CONSOLE came up,
                               saturating at 255
                   bit 0       a pulse is up now
     7-15        read UNMAPPED; writes dropped

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
measured on the board and set out at length in `rtl/cadr_gp0_default.sv`. So a
read outside the thirty-two words completes with `UNMAPPED` and a write
outside them completes and is dropped, over the whole gigabyte GP1 decodes.
OKAY and not SLVERR, which is where this differs from `rtl/cadr_disk_pack.sv`:
an error response to a Cortex-A9's posted write arrives as an imprecise
external abort the kernel cannot attribute to a process. The pack side can
afford SLVERR because a board with GP0 and no pack side has
`cadr_gp0_default.sv` under it; GP1 has only this.

`UNMAPPED` is the complement of `IDENT` and is neither zero nor all ones ---
zero is what a dead bus reads and all ones what an undriven one reads,
measured on this board's own EMIO pins. **A value that means nothing must not
be a value the instrument can mean.**

### The reset

**`rtl/cadr_arty.sv`'s reset was MMCM lock or BTN0 and nothing else**, so
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

**What takes the pulse on the board, and the rule.** `rtl/cadr_arty.sv`
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
effect. `rtl/cadr_probe.sv`'s own words are that it fills from the first
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

### The bound

`LOST_T` (line 167) is 4,096 ticks, 20.48 us. That much after the request the
engine gives up, drops `dbg_req`, sets STAT's `lost` and answers the read
with bit 16 set. A grant that never comes, or a register block that never
answers, therefore costs the Arm 20 us and not its uptime. `LOST_T` is
checked as a *number* and not merely as "the read came back": the mutation
`console-bound-is-not-a-bound` stretches it to 8,000 and is caught at "a lost
read took longer than the bound". That is `RD_FINISH_T`'s lesson one file
along.

### The arbiter, which is the attachment

`0o766000` is Unibus space and the CADR reaches it itself --- the boot PROM
writes the mode register there --- so the register block has two masters.
`cadr_console` asks with `dbg_req` and waits for `dbg_gnt`; the arbiter is
outside the module because the thing it must see, whether the processor's own
Unibus cycle is running, is `rtl/cadr_memory_path.sv`'s.

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
`rtl/cadr_probe.sv:103-104`, which lists exactly these five among the columns
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
(`../muir/src/rtl.rs:1119-1128`). `rtl/cadr_microcycle.sv` has neither and
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
`cadr_spy_registers` and are folded into `unused` at `rtl/cadr_machine.sv:425`
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
`../muir/tests/lashup.rs:712-769`). **That Unibus map is not in the fabric.**
`rtl/cadr_memory_path.sv` says so at its own fold: "Above the register block
there is nothing on this Unibus yet, so the top of the page number goes
nowhere: only `0o766xxx` is answered." So `cadr-console` examines and deposits
through `/dev/mem` on the machine's reserved DDR region instead, at
`rtl/cadr_ddr_map.sv`'s own address arithmetic, and says in its own output
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

`vivado/ps7_config.tcl` turns `PCW_USE_M_AXI_GP1` on, merged over Digilent's
verbatim block at the bottom beside `S_AXI_HP2`; the sha256 the header quotes
of that block is unchanged, so its claim still holds. `vivado/gen_ps7.py`
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
this slice under Vivado 2026.1: `vivado/ps7_init.ops` regenerated with GP1 on
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

**`rtl/cadr_console.sv` is not wired into `rtl/cadr_arty.sv` by this slice.**
Another session is in `cadr_machine.sv`, `cadr_memory_path.sv` and
`cadr_arty.sv`, so the wiring is a written patch and not an edit:

    ~/.cache/muir-fpga-console-attachment.patch

against `d77cdae`, `patch -p1` from the repository root. It touches **eight**
files and no others: `rtl/cadr_memory_path.sv`, `rtl/cadr_machine.sv`,
`rtl/cadr_arty.sv`, `Makefile`, `mutations/run.py`, and the three that carry
`M_AXI_GP1` --- `vivado/ps7_config.tcl`, `vivado/gen_ps7.py` and the
generated `rtl/cadr_ps7.sv`. `make current` passes immediately after it,
because the generated file is in the patch beside the generator; `make ps7`
regenerates it identically.

**It is verified and not merely written.** `tb/cadr_console_harness.sv` is the
same arbiter and the same mux, so `build/console.pass` holds them; and the
patch was applied to a clean export of `d77cdae` (with this slice's
`rtl/cadr_ps7.sv` and `rtl/cadr_console.sv` beside it) and **all five board
configurations lint clean** --- default, `PROBE_DEPTH=1024`, `DDR=1`,
`PROVE=1`, `PROVE=2`. Two faults were found that way and fixed before this
was written: the console's three outputs from `cadr_machine` were unread on
the board with no PS7, and the fix is the one `cadr_arty.sv` already
prescribes --- they go into the `witness` fold with the other fifty-nine, whose
comment says in as many words that "a fold with exceptions in it is not a
rule anybody can check".

What the patch does, file by file:

**`rtl/cadr_memory_path.sv`** --- eight new ports (`con_req`, `con_gnt`,
`con_msyn`, `con_write`, `con_addr`, `con_wdata`, `con_ssyn`, `con_rdata`),
and an instance of `rtl/cadr_console_bus.sv` between them and the register
block: the arbiter began as four `assign`s inline here and is a module of its
own now, for the reason the timing section below gives. Nothing else in the
file changes, and with `con_req` low the arbiter folds to a constant and the
mux to the processor's own half --- which is what `build/machine.pass`
compares, byte for byte before and after.

**`rtl/cadr_machine.sv`** --- the same eight ports, passed straight through to
the `memory` instance.

**`rtl/cadr_arty.sv`** --- the eight signals declared at module scope, added to
the `u_machine` instantiation, tied off on the board with no PS7 and folded
into `witness`; and inside `g_ddr`, the `gp1_*` wires, a reset synchroniser on
`gp1_aresetn`, the `cadr_console` instance and the PS7's twenty-seven GP1
pins. The console sits **outside** `g_pack`: every board with a processing
system has one, because the console is what says whether the machine is
running and a board that can only be watched through its lamps cannot answer
that. The machine is deliberately **not** reset with the port: a console that
reset the machine when Linux came up could never be attached to a running
machine, which is the only time it is wanted.

**`Makefile`** --- `rtl/cadr_console.sv` added to `arty.pass`'s prerequisites
and to its three PS7 command lines.

**`mutations/run.py`** --- the same file added to `arty_check`'s three PS7
board tuples.

### The two hunks that would give the console a step

Not in the patch, because they are in two files this slice does not own and
because each needs a check of its own. Named here so that the next person does
not have to find them:

**`rtl/cadr_spy_registers.sv`**, at the CLK register's write. It is

    REG_CLK: run <= held[0];

and the board's clock control register is five bits: `RUN`, `STEP`, `NOP11`,
`IDEBUG`, `LDSTAT` (`../muir/src/spy.rs:266-281`). `STEP` at least has to
leave the module.

**`rtl/cadr_microcycle.sv`**, at `MACHRUN`. It is

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

**The console's first bitstream missed 200 MHz by two and a half ticks**, and
the way it did is worth more than the fix. At `37711fe`, `DDR=1`, board flow:

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

**What was wrong was the deadline, not the depth.** `rtl/cadr_machine.xdc`
already relaxes `-from $slow -to $slow` to fifteen ticks, and `md_reg` is in
`slow`; the console's register was not, **because that file is read
`read_xdc -ref cadr_machine` and the console is a level above it**, in
`cadr_arty.sv` beside the PS7. It is the same wall `mem_addr` met --- a scoped
file cannot name what is outside its scope, and that is why `rtl/cadr_ddr.xdc`
exists at all. So the arc was slow-to-fast, which the exception does not match
and must not.

**The remedy is a register in the right module, and no new exception at all.**
`rtl/cadr_console_bus.sv` is the arbiter, the mux and the read-back register,
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
git history. Nothing under `rtl/` or `vivado/` in that copy was uncommitted
except `cadr_arty.sv` and `cadr_console.sv`, both of them this change, so it
is HEAD plus exactly this and nothing else --- checked file by file against
`git show HEAD:` before the run, and the copy is why a module another session
added to `rtl/` afterwards cannot have reached it. Board
flow, `vivado/bitstream.tcl`, both configurations, zero critical warnings:

                            HEAD 1d3a9bc      + the reset
    DDR=1  worst slack      -0.049 ns         -0.209 ns
           failing          1 of 27,044       101 of 27,142
           total negative   -0.049 ns         -6.650 ns
           hold             +0.051 ns         +0.048 ns
           LUTs / regs      6,923 / 5,036     6,978 / 5,067
    DDR=0  worst slack      +0.132 ns, MET    +0.084 ns, MET
           failing          0 of 16,028       0 of 16,028
           LUTs / regs      3,025 / 1,566     3,032 / 1,566

**The memory-on board did not close before this change and does not close
after it, and the 0.16 ns between them is not the reset.** `grep -c mach_rst`
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
flow, `vivado/bitstream.tcl`, both configurations, zero critical warnings and
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

`linux/buildroot/package/cadr-console/` is the program `cadr-console`, and
`linux/buildroot/package/cadr-common/` is what it and the disk pack program
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
count. It is deliberately not written here: `linux/` is another session's and
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

**The host check** is `make -C linux/buildroot/package/cadr-console/src
check`, on the build host, needing nothing but a C compiler; scratch under
`~/.cache/muir-fpga-console`. It runs the program's core against a model of
the slave --- the two pages, the latch, the lost bit, `UNMAPPED`, and a
modelled machine whose CYCLES advances only while RUN is set --- and holds 149
checks. The model is a model and not the RTL, and says so at its head, as
`feeder_test.c` does; the RTL is held to the same contract by
`tb/cadr_console_tb.cpp`.

**The mutation runner cannot reach a C program** --- it copies `rtl/`, `tb/`
and `vivado/` by pathspec and has no check for one, and a record naming a
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

`make -C linux/buildroot/package/cadr-disk-pack/src check` is byte-for-byte
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
- The Unibus map, and with it examine and deposit *through the machine*.
- The debug cable, which is a different instrument on a different port and
  has a section of its own in `README.md`.
