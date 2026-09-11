// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The console: the sixteen diagnostic registers on `M_AXI_GP1`, so that a
// program in Linux can halt the machine, read its state and start it again.
//
// **WHAT A CONSOLE IS.**  muir's own is CC, the program `examples/cc.rs`
// runs on one CADR to debug another over the debug cable, and its whole
// vocabulary is `crate::spy`: sixteen registers at Unibus `0o766000`, three
// of them written and all sixteen read.  `Engine::spy_read` answers a read
// and `Machine::spy_write` takes a write --- "from a Unibus cycle **or from
// a console with no bus at all**", `src/spy.rs`'s own words.  This module is
// the second of those: a master on the diagnostic bus with nothing between
// it and the register block but the arbiter.
//
// `rtl/machine/cadr_spy_registers.sv` is the register block and it is not touched
// here.  Its Unibus timing --- `-UB SSYN` at `DIAGNOSTIC_NS` after the
// strobe, the write pulse's leading edge `REGISTER_PULSE_NS` before the
// register loads, and the rule that a write lands at the machine's next look
// rather than at the strobe --- is the board's, is checked against muir by
// `build/machine.pass`, and is exactly what this module drives.  A console
// that reached around it and wrote the registers directly would be a second
// description of the same thing, and the two would drift.
//
// **THE QUESTION THIS EXISTS TO ANSWER.**  On the board the machine loads
// its microcode from its pack, does a fixed amount of disk work and goes
// quiet, and nothing built could say whether it is waiting or has halted.
// `FLAG-1` says: bit 8 is `SRUN`, bit 15 is `-WAIT`, bit 10 is `ERR`, and
// register 5 is `PC`.  `cc.rs` reads exactly that --- "`if b.spy_read(
// spy::FLAG_1) & 0x100 != 0 { "running" } else { "halted" }`".
//
// **WHAT LINUX SEES**, thirty-two words at `REG_BASE`, two pages of sixteen.
// The window is 128 bytes; `M_AXI_GP1` decodes `0x8000_0000` upward in the
// Zynq-7000 address map and this sits at the bottom of it.
//
//   page 0, `REG_BASE + 0x00`, the console's own, all read-only:
//
//     0  IDENT    reads `IDENT`, "CONS", so that the first read over GP1 can
//                 tell this face from a bus that answers zeros or ones
//     1  STAT     bit 0  busy      a diagnostic cycle is in flight
//                 bit 1  gnt       the diagnostic bus is the console's, live
//                 bit 2  answered  the last cycle got `-UB SSYN`
//                 bit 3  lost      some cycle since reset did not: sticky
//     2  CYCLES   microcycles the machine has retired since reset, bits 31:0.
//                 This is `Machine::cycles`, which `cc.rs` prints of the
//                 machine it is debugging, and it is what says the machine is
//                 running without stopping it to ask
//     3  CYCLESH  bits 63:32, **latched when CYCLES was read**: see below
//     4  TICKS    200 MHz ticks since reset, bits 31:0.  `Rtl::ns()` divided
//                 by five --- the machine's own time, which runs whether or
//                 not the machine does, so CYCLES against TICKS is a rate
//     5  TICKSH   bits 63:32, latched when TICKS was read
//     6  RESET    **the one word of page 0 that is written.**  A write of
//                 `RESET_KEY` and of nothing else pulses the machine's reset
//                 for `RESET_T` ticks; see below.  It reads
//                   bits 31:16  `RESET_KEY`'s own top half, a marker
//                   bits 15:8   how many console resets since the CONSOLE
//                               came up, saturating at 255
//                   bit 0       a pulse is up now
//     7  VMA      the virtual address register, all 32 bits, as of the last
//                 microcycle boundary.  **Reading this word LATCHES `Q`
//                 beside it**, so the two name one microcycle
//     8  Q        the `Q` register, all 32 bits, latched when VMA was read
//     9-15        read `UNMAPPED`; writes dropped
//
//   page 1, `REG_BASE + 0x40`, the sixteen diagnostic registers, word k
//   being `EADR` k:
//
//     read   runs a diagnostic READ cycle and returns `SPY<15:0>` in bits
//            15:0 with bits 31:16 zero, or bit 16 set and nothing else
//            meaning the cycle was not answered
//     write  runs a diagnostic WRITE cycle with `SPY<15:0>` from bits 15:0
//
//   So `spy_read(eadr)` is a load from `REG_BASE + 0x40 + 4*eadr` and
//   `spy_write(eadr, v)` a store to it, and the console program's vocabulary
//   is muir's with no translation in between.  Register 3 has no read select
//   on the board and reads the open bus, all ones; that is a fact about the
//   machine and it comes back through here unchanged.
//
// **THE HIGH HALF IS LATCHED BY THE LOW HALF'S READ, and that is not a
// convenience.**  A 64-bit counter read as two 32-bit loads is wrong across
// a carry: the low half wraps between the two loads and the pair names a
// time 4,294,967,296 ticks in the future.  The rule is read CYCLES then
// CYCLESH, TICKS then TICKSH; the low read latches the high half beside it,
// so the pair is one instant.  A program that reads the high word without
// the low one gets whatever the last low read latched, which is why the
// order is the rule and not the advice.
//
// **WORDS 7 AND 8: THE VIRTUAL ADDRESS REGISTER AND `Q`, AND WHY THEY ARE
// ON THIS PAGE AND NOT THE OTHER.**  On 2026-09-10 the board ran a System 100
// band for 351 million microcycles and halted inside `PDL-BUFFER-REFILL`: the
// microcode reads a second-level map entry, writes it back with read/write
// access ORed in, and then reads through the entry it has just hacked, and
// that read took a page fault where muir on the same pack does not.  Either
// the map write did not take, or the address read is not the page the map was
// hacked for --- and **three different faults injected into muir reproduce
// the board's console readout bit for bit**, same `PC`, same `OPC`, same
// `FLAG-1` and `FLAG-2`, same `IR`, `A`, `M` and `OB`.  Nothing the sixteen
// can say separates them.  What separates them is these two: **the map-side
// faults leave `VMA` and `Q` equal and the wrong-address fault leaves them one
// page apart.**
//
//   - **They are not on page 1 because they are not on the diagnostic bus.**
//     `../muir/src/spy.rs` is the whole vocabulary of MIT's sixteen and
//     neither register is in it; `EADR<3:0>` names sixteen things and all
//     sixteen are MIT's.  A seventeenth would mean renumbering MIT's own
//     register block, which is not this module's to do and would put
//     `cadr_spy_registers.sv` and `Engine::spy_read` out of step for ever.
//     So they come from `cadr_machine`'s observation ports, over wires of
//     their own, and land here beside CYCLES and TICKS --- which are also the
//     machine's and are also not on that bus.
//   - **They sit beside the sixteen and displace nothing.**  Page 0 had words
//     7 to 15 reading `UNMAPPED`; these take the first two, exactly as the
//     reset took word 6.  Page 1 is untouched, word for word.
//   - **Each is ONE 32-bit word and neither is split into halves.**  The
//     sixteen are sixteen bits because `SPY<15:0>` is sixteen wires, which is
//     why MIT reads `OB`, `M`, `A` and `ST` as two registers each.  **Page 0
//     is not on that bus**: its words are 32 bits and CYCLES, TICKS and IDENT
//     already are.  Split into four sixteen-bit words these would need four
//     reads where two do, four latch rules where one does, and --- the reason
//     that settles it --- a comparison of two 32-bit values assembled out of
//     four separately-timed reads, which is this instrument lying in a new
//     way about the one thing it was built to decide.
//   - **THE SPLIT THAT IS MADE IS BETWEEN THE TWO WORDS, AND IT CARRIES A
//     LATCH.**  The question asked of them is whether they are EQUAL or a
//     page apart, so a pair read as two independent loads of a running
//     machine is two instants and the answer would be an artefact of the gap.
//     The read of word 7 therefore latches BOTH, and word 8 reads that latch:
//     the rule is **VMA then Q**, exactly as it is CYCLES then CYCLESH one
//     register along and for the same reason.  A burst of two beats over
//     words 7 and 8 is the way a program should ask, and a program that reads
//     word 8 alone gets whatever the last read of word 7 latched.
//   - **They arrive already captured**, at the microcycle boundary, inside
//     `cadr_machine` --- `rtl/machine/cadr_console_state.sv`, which says why.  What
//     this module latches is therefore a register of `cadr_machine` and not
//     the datapath, and the two halves of the rule are in the two files: the
//     boundary makes them one MICROCYCLE, the latch here makes them one READ.
//
// **EVERY ADDRESS ON GP1 IS ANSWERED, and with OKAY.**  A read nothing
// answers on a GP port does not fault the Arm, it hangs both cores at one PC
// each --- measured on the board, and `rtl/plumbing/cadr_gp0_default.sv` says so at
// length.  So a read outside the thirty-two words completes with `UNMAPPED`
// and a write outside them completes and is dropped, in the window and out
// of it, over the whole gigabyte GP1 decodes.  **OKAY and not SLVERR**, which
// is where this differs from `rtl/plumbing/cadr_disk_pack.sv`'s face: an error
// response to a Cortex-A9's posted write arrives as an imprecise external
// abort the kernel cannot attribute to a process, and a constant a program
// can recognise is the safer failure.  The pack side answers SLVERR outside
// its window because a board with GP0 and no pack side has
// `cadr_gp0_default.sv` under it to answer instead; GP1 has only this.
//
// `UNMAPPED` is the complement of `IDENT` and neither zero nor all ones ---
// zero is what a dead bus reads and all ones is what an undriven one reads,
// measured on this board's own EMIO pins, and **a value that means nothing
// must not be a value the instrument can mean.**
//
// **THE RESET, WHICH IS WHY REGISTER 6 EXISTS.**  `boards/arty-z7-20/cadr_arty.sv`'s reset
// is MMCM lock or BTN0 and nothing else, so restarting the CADR has meant a
// finger on a board or a fresh bitstream.  Mete asked for a soft reboot from
// the processing system and this is where it belongs: the console is already
// the thing that says whether the machine is running.
//
// **IT IS A PULSE OF A STATED LENGTH AND NOT A LEVEL.**  A level is a bit a
// program can set and then be killed, or forget, or crash holding --- and a
// machine held in reset by a level looks exactly like a machine that will not
// start, with nothing to say which.  So a write arms a countdown, the
// countdown is `RESET_T` ticks, and there is no way for software to extend
// it, shorten it or hold it.
//
// **`RESET_T` IS 64 TICKS, 320 ns, AND THE NUMBER HAS A FLOOR AND A REASON.**
// Every register in `cadr_machine` takes a synchronous reset, so one tick
// would clear them all at once and the length looks arbitrary.  It is not:
//
//   - The machine's own power-on reset is never short.  `rst_sync` is four
//     deep and `!mmcm_locked` holds it for the MMCM's whole lock time, so a
//     machine that had only ever seen a one-tick reset would be released in
//     a way the board itself never performs.  A console reset that is not the
//     board's reset is a second reset to reason about.
//   - The floor is one whole generator cycle at extra slow, 44 ticks or
//     220 ns.  That is the longest interval over which any of the machine's
//     own timing is in flight --- `cadr_phase_gen.sv`'s ring, the seven read
//     taps at 15 to 32, the write pulses, and the two countdowns.  muir's
//     reference is not silent inside a reset either: CLAUDE.md records that
//     `chip.rs` goes on deriving `-TPR60` from `phase_ns` at ticks 11 to 18
//     of a plain power-on reset, so a reset shorter than the cycle it
//     interrupts is a region the model and the fabric are known to disagree
//     in and nothing compares.
//   - 64 is the smallest power of two above that floor, so the countdown is
//     six bits and its end is a borrow rather than a comparison --- which is
//     why `LOST_T` is 4,096 and not 4,000, one register along.
//
// It is a floor with margin and it is stated as one.  Nothing here derives 64
// from anything; what is derived is that it must be more than 44.
//
// **AND THE WRITE DOES NOT ANSWER UNTIL THE PULSE IS OVER.**  `W_RESET` holds
// the write channel through the countdown, so `BVALID` is offered after the
// machine has left reset and not before.  A program's store therefore returns
// when the machine is running again, and the very next read of `FLAG-1` means
// something.  The cost is 64 ticks --- 320 ns --- of one Arm store, against
// `LOST_T`'s 4,096 for a diagnostic cycle, so nothing has to be told about it.
//
// **`RESET_KEY` IS "RSET", AND AN ARBITRARY VALUE MUST NOT RESET THE
// MACHINE.**  The rule this project keeps meeting is that a value which means
// nothing must not be a value the instrument can mean: zero is what a dead
// bus reads and all ones what an undriven one reads, measured on this board's
// own EMIO pins.  So the key is chosen the way `cadr_arty.sv` chooses
// `PROVE_WORD`: **four distinct bytes, none of them `00` or `FF`**, halves
// that differ and neither a rotation of the other, and it is not `IDENT`, not
// `UNMAPPED`, and not what register 6 itself reads back --- so a program that
// echoes anything it has read from this face cannot reset the machine by
// accident.  A write's unstrobed lanes are merged against zero as every other
// write here is, and because no byte of the key is `00` **a write that does
// not strobe all four lanes cannot equal it, whatever the lanes hold.**  That
// is one rule and not two: the strobes are not tested separately.
//
// **WHAT THE RESET CLEARS OF THE CONSOLE'S OWN, AND WHAT IT MUST NOT.**
//
//   - `cycles` and `ticks` are cleared, because they are not the console's:
//     CYCLES is `Machine::cycles`, which is zero at reset, and TICKS is
//     `Rtl::ns()`, which is zero with it.  A CYCLES that went on counting
//     across a reset would name a microcycle no row of any trace has.
//   - STAT's `answered` and `lost` are NOT cleared.  They are the console's
//     own history on the diagnostic bus, and resetting the machine does not
//     make a cycle that was lost unlost.
//   - **The console does not reset itself, and this is the decision rather
//     than a detail.**  Three reasons, of which the third is the one that
//     would show on the board.  A console that forgot the reset could not
//     report it, and register 6's count is what a program reads to know the
//     machine it is looking at is the one it restarted.  A console reset by
//     the machine's reset would also clear STAT, so the instrument would
//     erase the evidence it exists to carry.  And --- the one that matters ---
//     the AXI write that asked for the reset is IN FLIGHT while the pulse is
//     up: a reset reaching `wst` would drop it back to `W_ADDR` with no
//     `BVALID` ever offered, and a GP write that never answers hangs both Arm
//     cores at one PC each, which is measured and is exactly what
//     `rtl/plumbing/cadr_gp0_default.sv` exists to prevent.  The console would freeze
//     the machine it was written to un-freeze.
//
// **AND THE ENGINE DOES NOT START A DIAGNOSTIC CYCLE WHILE THE PULSE IS UP.**
// `cadr_spy_registers` is inside the machine and is in reset with it, so a
// cycle begun during the pulse would strobe a block that cannot answer and
// would set STAT's sticky `lost` --- a lie, since nothing was lost.  A cycle
// asked for during the pulse simply waits; 64 ticks against `LOST_T`'s 4,096
// is a sixty-fourth of the bound, and the grant itself cannot come earlier
// anyway, `cadr_console_bus`'s arbiter being in reset too.
//
// **A cycle ALREADY IN FLIGHT when the reset lands is a different case and is
// not guarded**, and it is worth saying which it is rather than leaving it to
// be assumed.  The write channel cannot be in one --- a word-6 write goes
// straight from `W_DATA` to `W_RESET` and never asks the engine --- but the
// read channel can, the two being independent and the processing system
// driving both at once.  What happens then is bounded and honest: the grant
// drops, `-UB SSYN` does not come while the block is held, and the read
// completes with bit 16 set saying it was not answered, which is true.  It
// costs that one read `LOST_T` ticks, 20 us, and it sets STAT's sticky
// `lost`.  **`tb/cadr_console_tb.cpp` cannot reach either case**: its AXI
// master runs one transaction at a time, so a read and a write never overlap
// there.  A testbench with two independent channel drivers is what would
// exercise them, and there is no mutation record aimed at the guard for that
// reason.
//
// **WHERE THE PULSE GOES IS `boards/arty-z7-20/cadr_arty.sv`'s**, and it joins BTN0 rather
// than replacing it.  What leaves here is one register, `mach_rst`, so that
// what reaches the machine's reset pin is a flop and not a countdown's
// comparison.
//
// **AND WHERE IT LANDS WAS ASKED OF THE DESIGN RATHER THAN REASONED ABOUT**,
// which is what CLAUDE.md's `elapsed -> md/CE` entry demands of anything that
// reaches a reset: a relaxed register's clock enable goes with it, and a
// signal that drags a long cone into an enable is invisible in a slack figure.
// Synthesised at this slice, `DDR=1`, with the scoped XDC read, `all_fanout
// -flat -endpoints_only` from the two `mach_rst_reg` cells:
//
//   the top level's, into `cadr_machine`   1,008 R, 24 S, 19 D, 12 block-RAM
//                                          address bits, 2 ENARDEN, 3 ports
//                                          --- **and NOT ONE CLOCK ENABLE**
//   this module's own                      153 endpoints, of which 17 are
//                                          clock enables and every one of
//                                          them is `eng_wdata_reg[*]/CE` or
//                                          `eng_for_w_reg/CE` in this file,
//                                          which is the `!mach_rst` gate on
//                                          `E_IDLE` above and nothing else
//
// Every one of 400 paths out of `mach_rst_reg` asks for 5.000 ns --- no
// exception touches it and none should --- and the worst is +0.472 ns over two
// logic levels.  `mach_rst` appears nowhere in either board's
// `report_timing_summary`.
//
// **And the cone that arms it is eighteen startpoints, all registers of this
// module.**  `all_fanin -flat -startpoints_only` on `mach_rst_reg/D` gives
// `wst`, `w_at<6:2>`, `w_in`, `rst_t<6:0>` and `mach_rst` itself --- so the
// address match really is HELD and not computed, which is the rule
// `cadr_memory_path.sv` and the disk controller are both held to, and there
// is no map, no `phys` and no `vma` anywhere near it.  There could not be:
// this module is outside `cadr_machine`.  Measured rather than assumed all
// the same, because that is what the rule asks for.
//
// **WHY GP1 AND NOT GP0, WHICH IS WHERE `README.md` PUTS THE CONSOLE.**  A
// slave that owns a GP port must answer the whole of it, and GP0 is already
// answered end to end --- `rtl/plumbing/cadr_disk_pack.sv` inside its window and
// SLVERR outside it, anywhere in the port's gigabyte, or
// `rtl/plumbing/cadr_gp0_default.sv` on a board without the pack side.  So a console
// on GP0 needs an address decode and a mux in front of that face, and a
// console on GP1 needs one `PCW_*` property and changes `ps7_init` by
// nothing --- measured, op for op across all three silicon revisions.
// `README.md` puts the debug cable on GP1 and its argument for keeping the
// two apart is a good one; `REG_BASE` is a parameter and moving this back is
// one line at the instantiation plus that decode.  **The decision is not
// this module's** and `docs/console.md` states both sides with the numbers.
//
// **THE CONSOLE IS THE SECOND MASTER ON THE DIAGNOSTIC BUS**, and it asks.
// The first is the CADR itself: `0o766000` is Unibus space, the boot PROM
// writes the mode register there, and `cadr_busint_xbus.sv` runs that cycle.
// So `dbg_req` goes up and the cycle waits for `dbg_gnt`.  The arbiter is
// outside this module for two reasons: what it has to see --- whether the
// processor's own Unibus cycle is running --- belongs to
// `cadr_memory_path.sv`, and what it holds has to be inside `cadr_machine`
// for `cadr_machine.xdc` to reach.  It is `rtl/machine/cadr_console_bus.sv`, one
// module instantiated by that file and by `tb/cadr_console_harness.sv`, so
// that the check holds the thing on the board and not a copy of it.
//
// **AND THE CONSOLE'S HOLD ON THAT BUS IS BOUNDED, because the processor's
// is not.**  A CADR bus cycle that is not answered ends on the NXM timer at
// 4,250 ns from the gated oscillator's first rise.  This module holds the
// diagnostic bus for `DIAGNOSTIC_NS` plus the drop, which is 260 ns --- so a
// Unibus cycle that has to wait for the console behind it waits a sixteenth
// of its own timeout and cannot become an NXM.  That is the same argument
// the disk channel's per-word arbiter is held to, one bus along.
//
// **AND THE AXI TRANSACTION IS BOUNDED WHATEVER THE BUS DOES.**  `LOST_T`
// ticks after the request the engine gives up, drops `dbg_req`, sets STAT's
// `lost` and answers the read with bit 16 set.  A grant that never comes, or
// a register block that never answers, therefore costs the Arm `LOST_T`
// ticks and not the machine's uptime.  A bound nothing exercises is not a
// bound: `tb/cadr_console_tb.cpp` holds the grant off and requires the read
// to complete and to say it was lost.
//
// **WHAT IS NOT HERE.**  `STEP`, `NOP11`, `IDEBUG`, the debug IR, `LPC.HOLD`
// and `OPCCLK` --- the clock control register's bits 4:1 and the whole OPC
// control register --- are *written* through here, because a write of the
// CLK register is a write of the CLK register; but the board's own
// single-step is `SSTEP` and `SSDONE`, two flip flops of the 74S174 at OLORD1
// 1A10, and they are in `cadr_microcycle.sv`, which says at its port list
// that "the fabric has no console yet".  `cadr_spy_registers.sv` takes bit 0
// of a CLK write and drops the rest.  So `HALT` and `START` --- bit 0, `RUN`
// --- are the whole of what a console can make this machine do today, and
// `docs/console.md` names the two hunks that would add the rest.  Examining
// and depositing main memory is CC's `CC-EXECUTE-R`, which loads a
// microinstruction into the debug IR and clocks it: same two hunks.
//
// This module does not know any of that.  It carries `SPY<15:0>` both ways
// and the register block decides.

`default_nettype none

module cadr_console #(
    // Where the thirty-two words sit.  `0x8000_0000` is the first address
    // `M_AXI_GP1` decodes to the fabric in the Zynq-7000 PS address map,
    // as `0x4000_0000` is `M_AXI_GP0`'s.
    parameter logic [31:0] REG_BASE = 32'h8000_0000,
    // "CONS".
    parameter logic [31:0] IDENT    = 32'h434F_4E53,
    // What an address in neither page reads: the complement of IDENT.
    parameter logic [31:0] UNMAPPED = ~IDENT,
    // How long a diagnostic cycle may take before the engine gives up, in
    // 200 MHz ticks.  The cycle itself is `DIAGNOSTIC_NS` = 250 ns = 50
    // ticks; the rest is the wait for the grant, and the processor's own
    // Unibus cycle in front of it is bounded by its NXM timer at 4,250 ns.
    // 4,096 ticks is 20.48 us, four NXM timeouts, and it is a bound on how
    // long the Arm may stall and nothing else.
    parameter int unsigned LOST_T   = 4096,
    // What must be written to page 0's word 6, and to nothing else, for the
    // machine to be reset: "RSET".  Four distinct bytes, none `00` or `FF`,
    // so no partly-strobed write can reach it; not zero, not all ones, not
    // `IDENT`, not `UNMAPPED`, and not what register 6 reads back.  The
    // header has the whole argument.
    parameter logic [31:0] RESET_KEY = 32'h5253_4554,
    // How many 200 MHz ticks the machine's reset is held for.  64 ticks is
    // 320 ns: the floor is one generator cycle at extra slow, 44 ticks, and
    // this is the smallest power of two above it so that the countdown ends
    // on a borrow.  See the header --- it is a floor with margin and is not
    // derived from anything.
    parameter int unsigned RESET_T  = 64
) (
    input  var logic        clk,          // 200 MHz, one tick = 5 ns
    input  var logic        rst,

    // --- `M_AXI_GP1`, on which the processing system is the master.  AXI3,
    // --- 32 bits, 12-bit IDs, one write and one read in flight at once.
    input  var logic [31:0] s_awaddr,
    input  var logic [3:0]  s_awlen,
    input  var logic [11:0] s_awid,
    input  var logic        s_awvalid,
    output var logic        s_awready,
    input  var logic [31:0] s_wdata,
    input  var logic [3:0]  s_wstrb,
    input  var logic        s_wlast,
    input  var logic        s_wvalid,
    output var logic        s_wready,
    output var logic [1:0]  s_bresp,
    output var logic [11:0] s_bid,
    output var logic        s_bvalid,
    input  var logic        s_bready,
    input  var logic [31:0] s_araddr,
    input  var logic [3:0]  s_arlen,
    input  var logic [11:0] s_arid,
    input  var logic        s_arvalid,
    output var logic        s_arready,
    output var logic [31:0] s_rdata,
    output var logic [1:0]  s_rresp,
    output var logic [11:0] s_rid,
    output var logic        s_rlast,
    output var logic        s_rvalid,
    input  var logic        s_rready,

    // --- the diagnostic bus, as a second Unibus master drives it.  The
    // --- names and the polarities are `cadr_spy_registers.sv`'s ports.
    output var logic        dbg_req,      // the console wants the bus
    input  var logic        dbg_gnt,      // and has it
    output var logic        ub_msyn,      // -UB MSYN, this master's strobe
    output var logic        ub_write,
    output var logic [17:0] ub_addr,
    output var logic [15:0] ub_wdata,     // SPY<15:0> out
    input  var logic        ub_ssyn,      // -UB SSYN: the block answers
    // `SPY<15:0>` back.  **It arrives already registered**, and by design:
    // `rtl/machine/cadr_console_bus.sv` captures the sixteen-way diagnostic mux at
    // the microcycle boundary inside `cadr_machine`, where
    // `rtl/plumbing/xilinx7/cadr_machine.xdc` can relax it.  Captured here instead the board
    // read -12.837 ns; that module's header has the whole of it.  What it
    // costs is that this word is the machine as of the last boundary, which
    // is exact on a halted machine and is muir's own read-phase semantics on
    // a running one.
    input  var logic [15:0] ub_rdata,

    // --- the machine's own beat: one tick high for every microcycle the
    // --- processor retired, `cadr_microcycle.sv`'s `clock_edge`.
    input  var logic        clock_edge,

    // --- the virtual address register and `Q`, page 0's words 7 and 8.
    // --- **They arrive already captured at the microcycle boundary**, by
    // --- `rtl/machine/cadr_console_state.sv` inside `cadr_machine`, for the reason
    // --- `ub_rdata` above arrives captured: a register out here sampling the
    // --- machine's datapath is outside `rtl/plumbing/xilinx7/cadr_machine.xdc`'s reach and is
    // --- asked for in one tick.  What this module does with them is latch
    // --- the PAIR at a read of word 7, so that the two name one instant.
    input  var logic [31:0] mach_vma,
    input  var logic [31:0] mach_q,

    // --- the reset the console makes: `RESET_T` ticks after a write of
    // --- `RESET_KEY` to page 0's word 6, and never otherwise.  A register
    // --- and not a countdown's comparison, so that what reaches the
    // --- machine's reset pin has a whole tick of its own.  `cadr_arty.sv`
    // --- ORs it with the board's own reset --- MMCM lock and BTN0 --- and
    // --- gives the machine the result; it joins them and replaces neither.
    output var logic        mach_rst
);

  // spy::BASE, and "the EADR<3:0> lines just follow the Unibus address
  // <4:1>", so register k is at BASE + 2k.
  localparam logic [17:0] SPY_BASE = 18'o766000;

  // ------------------------------------------------------------------------
  // The machine's beat
  // ------------------------------------------------------------------------

  logic [63:0] cycles, ticks;

  // **AND A CONSOLE RESET CLEARS THEM**, because they are not the console's.
  // CYCLES is `Machine::cycles`, which `Engine::boot` leaves at zero, and
  // TICKS is `Rtl::ns()`, which is zero with it.  A CYCLES that went on
  // counting across a reset would name a microcycle no row of any trace has,
  // and every register the console reads back is compared against the row
  // CYCLES names.  They restart when the pulse ends; the machine leaves reset
  // one tick later, `cadr_arty.sv` registering the OR, and that tick is the
  // whole of the skew between the two clocks.
  always_ff @(posedge clk) begin
    if (rst || mach_rst) begin
      cycles <= 64'd0;
      ticks  <= 64'd0;
    end else begin
      ticks <= ticks + 64'd1;
      if (clock_edge) cycles <= cycles + 64'd1;
    end
  end

  // ------------------------------------------------------------------------
  // The GP1 face's state, declared before the engine that reads it
  // ------------------------------------------------------------------------

  typedef enum logic [2:0] { W_ADDR, W_DATA, W_CYCLE, W_RESET,
                             W_RESP } wstate_e;
  typedef enum logic [2:0] { R_ADDR, R_START, R_CYCLE, R_PREP, R_PREP2,
                             R_DATA } rstate_e;
  wstate_e wst;
  rstate_e rst_r;

  logic [31:0] w_at, r_at;      // the beat's address, walked up a word a beat
  logic [11:0] w_id, r_id;
  logic [3:0]  r_left;          // beats still owed on the read
  logic        w_last_q;        // the beat now in hand was WLAST

  // Whether the beat's address is one of the thirty-two words, and which.
  // Two pages of sixteen: bit 4 of the index is the page, bits 3:0 are
  // `EADR<3:0>` on page 1.
  function automatic logic in_window(input logic [31:7] page);
    return page == REG_BASE[31:7];
  endfunction
  logic        w_in, r_in;
  logic [4:0]  w_idx, r_idx;
  logic [31:0] w_next;
  assign w_next = w_at + 32'd4;
  assign r_in   = in_window(r_at[31:7]);
  assign w_idx  = w_at[6:2];
  assign r_idx  = r_at[6:2];

  // The low sixteen bits of a write beat, unstrobed lanes reading zero, as
  // `cadr_disk_pack.sv` merges a beat against zero for its CTL word: a
  // `writeb` of the low byte is then the same write as a `writel` of the
  // same value, and a lane nobody strobed carries nothing of its own.
  logic [15:0] w_spy;
  assign w_spy = {s_wstrb[1] ? s_wdata[15:8] : 8'd0,
                  s_wstrb[0] ? s_wdata[7:0]  : 8'd0};

  // The whole beat, unstrobed lanes reading zero the same way, which is what
  // the reset key is compared against.  Because no byte of `RESET_KEY` is
  // `00`, a beat that does not strobe all four lanes cannot equal it whatever
  // those lanes carried --- so the strobes need no test of their own.
  logic [31:0] w_full;
  assign w_full = {s_wstrb[3] ? s_wdata[31:24] : 8'd0,
                   s_wstrb[2] ? s_wdata[23:16] : 8'd0,
                   s_wstrb[1] ? s_wdata[15:8]  : 8'd0,
                   s_wstrb[0] ? s_wdata[7:0]   : 8'd0};

  // **THE WRITE BEAT'S REGISTER AND WORD ARE LATCHED AT THE BEAT**, because
  // `w_at` walks up in the same tick the beat lands: the cycle that follows
  // would otherwise be aimed at the register after the one written.
  logic [3:0]  w_eadr_q;
  logic [15:0] w_spy_q;

  // ------------------------------------------------------------------------
  // The machine's reset: page 0's word 6, and the only word of that page
  // anything may write
  // ------------------------------------------------------------------------
  //
  // `mach_rst` is the pulse.  `rst_t` counts it out and `resets` counts the
  // pulses, saturating rather than wrapping --- a counter that can read zero
  // again is a counter that can say "no reset has ever happened" when one
  // has, which is the all-ones-and-all-zeros rule in its counting form.

  localparam logic [3:0] R_RESET = 4'd6;

  // Page 0's words 7 and 8: the virtual address register and `Q`.  The read
  // of `R_VMA` latches the pair; `R_Q` reads what it latched.  See the
  // header for why they are here, why neither is split into halves, and why
  // one read arms both.
  localparam logic [3:0] R_VMA = 4'd7;
  localparam logic [3:0] R_Q   = 4'd8;

  logic [7:0] resets;
  logic [6:0] rst_t;

  // Which page-0 word this beat names, and whether it is the key.  The
  // address match is `w_in`, taken at AWVALID and held --- it is not computed
  // here --- for the reason `cadr_memory_path.sv` and the disk controller
  // both give at their own decodes.
  logic w_is_reset;
  assign w_is_reset = w_in && !w_idx[4] && (w_idx[3:0] == R_RESET) &&
                      (w_full == RESET_KEY);

  // ------------------------------------------------------------------------
  // The diagnostic engine: one Unibus cycle at a time
  // ------------------------------------------------------------------------
  //
  // The two halves of AXI are independent and the processing system's
  // interconnect will drive both at once, so the read side and the write
  // side both ask this and it serves one.  **The write side wins a tie**,
  // arbitrarily and stated: a program that reads and writes the same
  // register from two threads has a race of its own making, and one rule is
  // one rule.

  typedef enum logic [2:0] { E_IDLE, E_GRANT, E_ACTIVE, E_DROP } estate_e;
  estate_e est;

  logic        eng_w_req, eng_r_req;   // the two askers, held while waiting
  logic        eng_for_w;              // whose cycle is running
  logic        eng_done;               // one tick, the cycle is over
  logic        eng_lost;               // and it was not answered
  logic [15:0] eng_rdata;
  logic [3:0]  eng_eadr;
  logic        eng_write;
  logic [15:0] eng_wdata;
  logic [12:0] waited;                 // ticks since the request

  assign eng_w_req = (wst == W_CYCLE);
  assign eng_r_req = (rst_r == R_CYCLE);

  assign dbg_req  = (est != E_IDLE);
  assign ub_msyn  = (est == E_ACTIVE);
  assign ub_write = eng_write;
  assign ub_addr  = SPY_BASE | {13'd0, eng_eadr, 1'b0};
  assign ub_wdata = eng_wdata;

  logic answered, lost_ever;

  always_ff @(posedge clk) begin
    if (rst) begin
      est       <= E_IDLE;
      eng_for_w <= 1'b0;
      eng_done  <= 1'b0;
      eng_lost  <= 1'b0;
      eng_rdata <= 16'd0;
      eng_eadr  <= 4'd0;
      eng_write <= 1'b0;
      eng_wdata <= 16'd0;
      waited    <= 13'd0;
      answered  <= 1'b0;
      lost_ever <= 1'b0;
    end else begin
      eng_done <= 1'b0;
      unique case (est)
        // `!eng_done` is what keeps a cycle from being started twice.
        // `eng_done` stands for the tick in which the asking side leaves its
        // wait state, and its request is a level off that state, so without
        // this the engine would see the request still up and run the cycle
        // again --- once for every register a program touched.
        // **AND NOT WHILE THE MACHINE IS IN RESET.**
        // `cadr_spy_registers` is inside the machine and is held in reset
        // with it, so a cycle begun during the pulse would strobe a block
        // that cannot answer and would end on `LOST_T` with STAT's sticky
        // `lost` set --- a lie, since nothing was lost.  A cycle asked for
        // during the pulse waits for it: 64 ticks against the bound's 4,096.
        E_IDLE: begin
          waited <= 13'd0;
          if (!eng_done && !mach_rst && (eng_w_req || eng_r_req)) begin
            eng_for_w <= eng_w_req;
            eng_eadr  <= eng_w_req ? w_eadr_q : r_idx[3:0];
            eng_write <= eng_w_req;
            eng_wdata <= w_spy_q;
            est       <= E_GRANT;
          end
        end
        // `dbg_req` is up from here on.  The arbiter outside gives the bus
        // when the processor's own Unibus cycle is not running and holds the
        // grant until the request drops, so the cycle below cannot have the
        // bus taken away under it.
        E_GRANT: begin
          waited <= waited + 13'd1;
          if (dbg_gnt) begin
            waited <= 13'd0;
            est    <= E_ACTIVE;
          end else if (waited == 13'(LOST_T - 1)) begin
            eng_lost <= 1'b1;
            est      <= E_DROP;
          end
        end
        // -UB MSYN is up.  `cadr_spy_registers.sv` answers with -UB SSYN
        // `DIAGNOSTIC_NS` after the strobe, having taken a write at
        // `REGISTER_STROBE_NS` and put the mode register's two pulses out at
        // `REGISTER_PULSE_NS` on the way; the word on `SPY<15:0>` is the
        // processor's and stands while the block is selected.
        E_ACTIVE: begin
          waited <= waited + 13'd1;
          if (ub_ssyn) begin
            eng_rdata <= ub_rdata;
            eng_lost  <= 1'b0;
            est       <= E_DROP;
          end else if (waited == 13'(LOST_T - 1)) begin
            eng_lost <= 1'b1;
            est      <= E_DROP;
          end
        end
        // MSYN is down; the block clears its own -UB SSYN the tick after,
        // and the bus is given back only once it has.  Dropping the request
        // while SSYN is still up would hand the next master a bus that is
        // already answering.
        E_DROP: if (!ub_ssyn) begin
          eng_done <= 1'b1;
          answered <= !eng_lost;
          if (eng_lost) lost_ever <= 1'b1;
          est      <= E_IDLE;
        end
        default: est <= E_IDLE;
      endcase
    end
  end

  logic eng_done_w, eng_done_r;
  assign eng_done_w = eng_done && eng_for_w;
  assign eng_done_r = eng_done && !eng_for_w;

  // ------------------------------------------------------------------------
  // The GP1 face
  // ------------------------------------------------------------------------

  assign s_awready = (wst == W_ADDR);
  assign s_wready  = (wst == W_DATA);
  assign s_bvalid  = (wst == W_RESP);
  assign s_bresp   = 2'b00;   // OKAY, everywhere: see the header
  assign s_bid     = w_id;

  // A write beat lands this tick.
  logic w_beat;
  assign w_beat = s_wvalid && s_wready;

  // **THE WORD AND THE RESPONSE ARE REGISTERS, MADE THE TICK BEFORE RVALID**,
  // for the reason `cadr_disk_pack.sv` gives at the same place: driven
  // straight off `r_at`, the window compare and the mux reached the PS7's own
  // RDATA pins four logic levels late on the DDR=1 board.  `R_START`
  // registers the compare and the index, `R_PREP2` the word.
  logic [31:0] rdata_q;
  logic        r_in_q;
  logic [4:0]  r_idx_q;
  logic [15:0] r_spy;      // what the cycle brought back
  logic        r_lost;
  assign s_arready = (rst_r == R_ADDR);
  assign s_rvalid  = (rst_r == R_DATA);
  assign s_rlast   = (r_left == 4'd0);
  assign s_rresp   = 2'b00;   // OKAY, everywhere
  assign s_rdata   = rdata_q;
  assign s_rid     = r_id;

  // A page-0 read is a register of this module; a page-1 read is what the
  // cycle brought back, with bit 16 up if it brought nothing.
  logic [31:0] stat_word, r_word;
  assign stat_word = {28'd0, lost_ever, answered, dbg_gnt, (est != E_IDLE)};
  logic [31:0] cycles_hi_q, ticks_hi_q;
  // The pair, latched together by a read of word 7.  **Not cleared by a
  // console reset**, for the same reason `cycles_hi_q` is not: they are the
  // console's copy and not the machine's, the next read of word 7 re-arms
  // them, and a console that forgot what it had read would be a console the
  // machine's reset had reached --- which is the decision the header argues
  // at length.
  logic [31:0] held_vma, held_q;
  // **AND THE ARM IS HELD AND NOT COMPUTED**, which is the rule
  // `cadr_memory_path.sv` and the disk controller are both held to and which
  // this module already obeys at the reset's own address match.  Measured
  // rather than assumed, and it was wrong first: with the latch armed
  // straight off `r_in` and `r_idx` --- five logic levels off `r_at` --- the
  // routed board put that cone into SIXTY-FOUR CLOCK ENABLES and read
  // **-0.145 ns** at `r_at_reg[19]/C -> held_q_reg[0]/CE`.  That is
  // CLAUDE.md's `elapsed -> md/CE` in a new place: a register's enable
  // carries whatever cone drives it, and a slack figure says nothing about
  // which. `vq_arm` is that decision taken at `R_START` and registered, so
  // what reaches the sixty-four enables is one flop and no logic, and the
  // latch itself happens a state later at `R_PREP` --- still before
  // `R_PREP2` takes `r_word`, which is what makes the read of word 7 answer
  // with what it latched.
  logic        vq_arm;
  always_comb begin
    if (!r_in_q) r_word = UNMAPPED;
    else if (r_idx_q[4]) r_word = {15'd0, r_lost, r_spy};
    else begin
      unique case (r_idx_q[3:0])
        4'd0:    r_word = IDENT;
        4'd1:    r_word = stat_word;
        4'd2:    r_word = cycles[31:0];
        4'd3:    r_word = cycles_hi_q;
        4'd4:    r_word = ticks[31:0];
        4'd5:    r_word = ticks_hi_q;
        // The reset register, and it does not read zero when nothing has
        // happened: the key's own top half is the marker, so a virgin read
        // is `0x5253_0000` --- neither what a dead bus reads nor what an
        // undriven one does, and it names the key's own first half to
        // whoever is looking.  Reading it and writing the word straight back
        // cannot reset the machine, which is one of the twelve things
        // `tb/cadr_console_tb.cpp` writes here and requires to do nothing.
        R_RESET: r_word = {RESET_KEY[31:16], resets, 7'd0, mach_rst};
        // The pair, from the latch and never from the wires: a word taken
        // straight off `mach_vma` here would be this beat's instant while
        // word 8 was the beat before's, and the two would name one microcycle
        // only by luck.
        R_VMA:   r_word = held_vma;
        R_Q:     r_word = held_q;
        default: r_word = UNMAPPED;
      endcase
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      wst         <= W_ADDR;
      rst_r       <= R_ADDR;
      w_at        <= 32'd0;
      r_at        <= 32'd0;
      w_id        <= 12'd0;
      r_id        <= 12'd0;
      r_left      <= 4'd0;
      w_in        <= 1'b0;
      w_last_q    <= 1'b0;
      w_eadr_q    <= 4'd0;
      w_spy_q     <= 16'd0;
      rdata_q     <= 32'd0;
      r_in_q      <= 1'b0;
      r_idx_q     <= 5'd0;
      r_spy       <= 16'd0;
      r_lost      <= 1'b0;
      vq_arm      <= 1'b0;
      cycles_hi_q <= 32'd0;
      ticks_hi_q  <= 32'd0;
      held_vma    <= 32'd0;
      held_q      <= 32'd0;
      mach_rst    <= 1'b0;
      rst_t       <= 7'd0;
      resets      <= 8'd0;
    end else begin
      // --- the machine's reset, counted out.  Written first so that the
      // write channel below can arm it in the same tick and win: a pulse
      // armed here is up from the next tick and for `RESET_T` ticks, and
      // `W_RESET` is left the tick after it drops.
      if (mach_rst) begin
        if (rst_t == 7'd0) mach_rst <= 1'b0;
        else rst_t <= rst_t - 7'd1;
      end

      // --- writes
      unique case (wst)
        W_ADDR: if (s_awvalid) begin
          w_at <= s_awaddr;
          w_in <= in_window(s_awaddr[31:7]);
          w_id <= s_awid;
          wst  <= W_DATA;
        end
        W_DATA: if (w_beat) begin
          w_last_q <= s_wlast;
          w_eadr_q <= w_idx[3:0];
          w_spy_q  <= w_spy;
          w_at     <= w_next;
          w_in     <= in_window(w_next[31:7]);
          // Page 1 is a diagnostic write and takes a bus cycle.  Page 0's
          // word 6 with the key on it resets the machine and takes the
          // pulse.  Every other page-0 word is read-only, everything
          // outside the window is dropped, and all of them complete with
          // OKAY and nothing else happens --- **including a write of word 6
          // that is not the key**, which is the whole point of the key.
          if (w_in && w_idx[4]) wst <= W_CYCLE;
          else if (w_is_reset) begin
            mach_rst <= 1'b1;
            rst_t    <= 7'(RESET_T - 1);
            // Saturating: see the declaration.
            if (resets != 8'hFF) resets <= resets + 8'd1;
            wst      <= W_RESET;
          end
          else if (s_wlast) wst <= W_RESP;
        end
        W_CYCLE: if (eng_done_w) wst <= w_last_q ? W_RESP : W_DATA;
        // **THE WRITE DOES NOT ANSWER UNTIL THE PULSE IS OVER**, so a
        // program's store returns with the machine already running again and
        // the next read of `FLAG-1` means something.  It costs one Arm store
        // `RESET_T` ticks --- 320 ns --- and it is what makes "reset then
        // ask" a sequence a program can write without a delay in it.
        W_RESET: if (!mach_rst) wst <= w_last_q ? W_RESP : W_DATA;
        W_RESP: if (s_bready) wst <= W_ADDR;
        default: wst <= W_ADDR;
      endcase

      // --- reads
      unique case (rst_r)
        R_ADDR: if (s_arvalid) begin
          r_at   <= s_araddr;
          r_id   <= s_arid;
          r_left <= s_arlen;
          rst_r  <= R_START;
        end
        // Which word this beat names, and whether it needs the machine
        // asked.  **The high half of each counter is latched here**, by the
        // read of the low half, so that the pair a program reads names one
        // instant across the carry.
        R_START: begin
          r_in_q  <= r_in;
          r_idx_q <= r_idx;
          if (r_in && !r_idx[4] && r_idx[3:0] == 4'd2) cycles_hi_q <= cycles[63:32];
          if (r_in && !r_idx[4] && r_idx[3:0] == 4'd4) ticks_hi_q  <= ticks[63:32];
          // **AND THE PAIR, BY ONE ENABLE.**  A read of word 7 takes the
          // virtual address register AND `Q` in the same tick, so the two
          // words a program reads back are one instant of the machine; word
          // 8 does not arm this, or a read of 7 then 8 would be two.  The
          // decision is taken here and the taking is a state later: see
          // `vq_arm`'s declaration for the -0.145 ns that says why.
          vq_arm <= r_in && !r_idx[4] && (r_idx[3:0] == R_VMA);
          rst_r <= (r_in && r_idx[4]) ? R_CYCLE : R_PREP;
        end
        R_CYCLE: if (eng_done_r) begin
          r_spy  <= eng_rdata;
          r_lost <= eng_lost;
          rst_r  <= R_PREP;
        end
        R_PREP: begin
          if (vq_arm) begin
            held_vma <= mach_vma;
            held_q   <= mach_q;
          end
          rst_r <= R_PREP2;
        end
        R_PREP2: begin
          rdata_q <= r_word;
          rst_r   <= R_DATA;
        end
        R_DATA: if (s_rready) begin
          r_at <= r_at + 32'd4;
          if (r_left == 4'd0) rst_r <= R_ADDR;
          else begin
            r_left <= r_left - 4'd1;
            rst_r  <= R_START;
          end
        end
        default: rst_r <= R_ADDR;
      endcase
    end
  end

  // The AXI3 length on the write channel is not read: a register access is
  // walked a beat at a time until WLAST says it is over, and one write is in
  // flight at a time so the response's ID is the address's.  All four strobes
  // and all thirty-two data bits ARE read --- `w_full`, which the reset key
  // is compared against; only a diagnostic write drops the top half, and it
  // drops it in `w_spy` where the reason is written.
  logic unused_s;
  assign unused_s = ^{s_awlen};

endmodule

`default_nettype wire
