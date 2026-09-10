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
     6-15        read UNMAPPED; writes dropped

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
`tb/cadr_microcycle_tb.cpp` drives it from. It takes about seven seconds.

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
is not built.

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

Six records in `mutations/list.txt`, all caught, each on its own line ---
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
`con_msyn`, `con_write`, `con_addr`, `con_wdata`, `con_ssyn`, `con_rdata`);
the arbiter, four `assign`s of a mux, and `-UB SSYN` routed back to whoever
asked; and the `cadr_spy_registers` instance's four Unibus inputs and its
`ub_ssyn` moved onto the muxed `sr_*` wires. Nothing else in the file changes,
and with `con_req` low the arbiter folds to a constant and the mux to the
processor's own half --- which is what `build/machine.pass` compares.

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
