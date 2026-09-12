// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The diagnostic bus's arbiter, and the seam the console reaches it through.
//
// `0o766000` has three masters: the CADR itself, whose microcode writes the
// mode register there through `cadr_busint_xbus`; `rtl/plumbing/cadr_console.sv`,
// which is an AXI slave on `M_AXI_GP1` outside the machine altogether; and
// `rtl/machine/cadr_dbgin.sv`, the debug cable's debuggee end, which is a
// master of MIT's own.  This keeps them apart, and it does one more thing
// that turns out to matter far more: **it puts the console's side of the bus inside `cadr_machine`, where
// `rtl/plumbing/xilinx7/cadr_machine.xdc` can reach it.**
//
// **THE 12.837 ns THAT MADE THIS A MODULE.**  With the console's read-back
// register in `cadr_console` --- outside `cadr_machine` --- the board flow
// read
//
//     Slack (VIOLATED) : -12.837 ns
//     Source:            u_machine/processor/md_reg[15]/C
//     Destination:       g_ddr.u_console/eng_rdata_reg[1]/D
//     Requirement:       5.000 ns
//     Data Path Delay:   17.703 ns, 24 logic levels
//
// on 5,698 endpoints of 27,144, where the commit before the console read
// -0.148 ns.  The path is MD through the M bus's source mux and then through
// the sixteen-way diagnostic read mux --- the whole of `Engine::spy_read` ---
// and it is not a path anything can shorten from the far end.  What was
// wrong was not the depth but the deadline: `cadr_machine.xdc` relaxes
// `-from $slow -to $slow` to fifteen ticks and `md_reg` is in `slow`, but
// the console's register was not, because that file is read
// `read_xdc -ref cadr_machine` and the console is a level above.  A register
// in `cadr_machine` falls into `slow` on the file's own test and needs no
// naming; a register outside it cannot be named at all.  **So the read-back
// is captured here, and the console is handed a register.**
//
// **AND IT QUALIFIES ON THE FILE'S OWN TEST, WHICH IS NOT "IS IT SLOW" BUT
// "IS ITS INPUT STABLE ACROSS THE MICROCYCLE AND ITS CONSUMER READING IT
// ONLY AT THE END".**  `sr_rdata` is `Engine::spy_read`'s answer, a function
// of `IR`, `PC`, `OPC`, `OB`, the A and M buses, `ST` and the flags --- every
// one of them a register that moves at the microcycle boundary and stands
// still between.  So `con_rdata` is loaded **at the boundary and nowhere
// else**, `mclk` being its whole clock enable: launched at one boundary and
// captured at the next, the mux has a microcycle to settle, which is 29
// ticks at normal speed and 44 at extra slow against the fifteen the
// exception asks for.  Loaded every tick instead it would be a register
// holding whatever a relaxed path had reached, which is the too-wide
// exemption in its purest form.
//
// **WHAT THAT COSTS, SAID PLAINLY: the console reads the machine as of the
// last microcycle boundary, not as of the tick it asked.**  Three things
// make that right rather than merely cheap.
//
//   - **It is muir's own semantics.**  `Engine::spy_read` is called between
//     steps and recomputes the read phase of the instruction standing in
//     `IR`; `Rtl::signals` is "recorded in the read phase, where the sources
//     drive and the ALU result is up but nothing has been written back".  A
//     boundary is where a CADR's state is defined.  A tick in the middle of
//     a microcycle is not a thing muir can be asked about.
//   - **On a halted machine it is exact**, and that is the only way a
//     console is used: CC halts first (`../muir/tests/lashup.rs:152`), and
//     `MCLK` runs whether or not `MACHRUN` does --- "the mode register and
//     the trap follow the console even with the machine halted" --- so this
//     register goes on refreshing from a machine that has stopped moving.
//   - **On a running machine the board is worse.**  The 74LS244s drive
//     `SPY<15:0>` asynchronously and the interface's 8304s sample them
//     whenever `-UB SSYN` says; MIT's own note is that "read and write at
//     the same address are uncorrelated".  A word torn across a microcycle
//     edge is what the hardware gives; a word from a named edge is better.
//
// The lag is one microcycle exactly, `tb/cadr_console_tb.cpp` measures it
// rather than assuming it --- reading `PC` while the machine runs and asking
// which row the answer belongs to --- and
// `console-read-back-is-not-held-to-the-boundary` is the record that holds
// it, caught at "the read-back's lag in microcycles is 0x0, the reference
// says 0x1".
//
// **AND THE ENABLE WAS ASKED ABOUT.**  A relaxed register's clock enable is
// relaxed with it, which is the trap `rtl/plumbing/xilinx7/cadr_machine.xdc` records at
// `elapsed -> md/CE`.  Measured at this slice, the three startpoints into
// `con_rdata_reg[*]/CE` are `u_phase_gen/tpclk` and `tpclk_q` at 5.000 ns ---
// the two that make the edge, and the two that matter --- and `started` at
// 75.000, which goes high at the first boundary out of reset and never
// changes again.
//
// **THE GRANT IS TAKEN ONLY WITH THE PROCESSOR'S OWN STROBE DOWN, AND HELD
// UNTIL THE CONSOLE LETS GO.**  Taken any other way it would truncate a
// Unibus cycle already counting on `elapsed` inside `cadr_spy_registers`:
// that module starts its count at the strobe and clears it when the strobe
// falls, so a strobe masked in the middle is a cycle that never answers, and
// the processor's own NXM timer is what would find it 4,250 ns later.
//
// The other way round is bounded and safe.  While the console has the bus a
// processor strobe is masked, so the processor's cycle simply starts late;
// the console holds the bus for `DIAGNOSTIC_NS` plus the drop, which is
// 260 ns, or 52 ticks, against that same 4,250 ns timer.  Sixteen to one,
// and it is the argument `cadr_memory_path.sv`'s per-word channel arbiter is
// held to, one bus along.
//
// **THE DEBUG MASTER IS THE THIRD, AND IT BEATS THE CONSOLE.**  On MIT's
// board the 74LS74 at UBMAST 0D02 is FIRST on the `NPG1 IN` chain, so the
// debug cable's master is the highest priority master the Unibus has.  The
// console has no counterpart on MIT's board at all --- no CADR had a path
// from a processing system to the diagnostic registers --- so its priority
// against the debug master is a decision and not a reading, and this is the
// way to take it: the debug master is the machine's own, the console is
// ours.
//
// What that costs is bounded on the side that matters and unbounded on the
// side that does not.  A debug master waiting behind the console waits the
// console's own 260 ns.  A console waiting behind the debug master waits as
// long as the debugger holds its request, which is unbounded in real time
// because the debugger's clock and the fabric's are decoupled --- and the
// console already has the only bound on that bus, giving up after `LOST_T`
// ticks and reporting `lost`.  So the console degrades and says so, where a
// debug cycle truncated would be a debugger told the wrong thing.
//
// **AND THE DEBUG MASTER'S HOLD IS NOT BOUNDED AT ALL, WHICH IS FAITHFUL.**
// `-DB NEED UB` down keeps it on the bus with `-UB BBSY` asserted and the
// machine's own cycles waiting, so a debug cycle left standing turns a
// legitimate reference into an NXM 4,250 ns later.  That is what the real
// board does and it is why CC halts the debuggee before it does anything
// else.  `cadr_debug_window.sv`'s watchdog recovers a wedged bus; nothing
// can protect the machine from a debugger that holds its request, and
// nothing should pretend to.
//
// `-UB SSYN` goes back to whoever asked and to nobody else: a slave
// answering a master that is not there is what a shared bus must not do.
//
// **THE CONSOLE'S REQUEST SIDE IS REGISTERED HERE TOO, AND FOR THE SAME
// REASON AS THE ANSWER.**  `sr_addr` is `EADR<3:0>` and so is the select of
// that same sixteen-way mux, so `eng_eadr` in the console reaching
// `con_rdata`'s D would be a second long path with one tick to run in ---
// fast-to-slow, which the exception does not match and must not.  Held here,
// both ends of that arc are registers of `cadr_machine` and it has the
// microcycle.  It costs the console one tick at the start of a cycle it
// holds for fifty-two.

`default_nettype none

module cadr_console_bus (
    input  var logic        clk,          // 100 MHz, one tick = 10 ns
    input  var logic        rst,
    input  var logic        mclk,         // MCLK7, the microcycle boundary

    // --- the processor's own master, `cadr_busint_xbus`'s Unibus cycle
    input  var logic        cpu_msyn,
    input  var logic        cpu_write,
    input  var logic [17:0] cpu_addr,
    input  var logic [15:0] cpu_wdata,
    output var logic        cpu_ssyn,

    // --- the debug cable's master, `rtl/machine/cadr_dbgin.sv`.  First on
    // --- MIT's grant chain, so it beats the console; it waits for the
    // --- processor's own strobe like everything else on this bus.
    input  var logic        dbg_req,
    output var logic        dbg_gnt,
    input  var logic        dbg_msyn,
    input  var logic        dbg_write,
    input  var logic [17:0] dbg_addr,
    input  var logic [15:0] dbg_wdata,
    output var logic        dbg_ssyn,
    output var logic [15:0] dbg_rdata,

    // --- the console, `rtl/plumbing/cadr_console.sv`, a level above this one
    input  var logic        con_req,
    output var logic        con_gnt,
    input  var logic        con_msyn,
    input  var logic        con_write,
    input  var logic [17:0] con_addr,
    input  var logic [15:0] con_wdata,
    output var logic        con_ssyn,
    output var logic [15:0] con_rdata,

    // --- the register block, `rtl/machine/cadr_spy_registers.sv`
    output var logic        sr_msyn,
    output var logic        sr_write,
    output var logic [17:0] sr_addr,
    output var logic [15:0] sr_wdata,
    input  var logic        sr_ssyn,
    input  var logic [15:0] sr_rdata
);

  logic        con_own, dbg_own;
  logic        con_msyn_q, con_write_q;
  logic [17:0] con_addr_q;
  logic [15:0] con_wdata_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      con_own     <= 1'b0;
      dbg_own     <= 1'b0;
      con_msyn_q  <= 1'b0;
      con_write_q <= 1'b0;
      con_addr_q  <= 18'd0;
      con_wdata_q <= 16'd0;
      con_rdata   <= 16'd0;
    end else begin
      // The debug master takes the bus with the processor's strobe down and
      // the console not already on it, and holds it while it asks.
      if (dbg_own) dbg_own <= dbg_req;
      else dbg_own <= dbg_req && !cpu_msyn && !con_own;
      // The console the same, and behind the debug master: first on the
      // grant chain means first here too.
      if (con_own) con_own <= con_req;
      else con_own <= con_req && !cpu_msyn && !dbg_req && !dbg_own;
      con_msyn_q  <= con_msyn;
      con_write_q <= con_write;
      con_addr_q  <= con_addr;
      con_wdata_q <= con_wdata;
      // The answer, taken at the boundary and nowhere else: see the header.
      if (mclk) con_rdata <= sr_rdata;
    end
  end

  // **THE DEBUG MASTER'S REQUEST SIDE IS NOT REGISTERED HERE**, where the
  // console's is, and the difference is where the two masters live.  The
  // console is a level above `cadr_machine`, so `eng_eadr` reaching the
  // sixteen-way mux's select would be a long arc with one tick to run in;
  // `cadr_dbgin.sv` is inside `cadr_machine` and its registers fall into
  // `cadr_machine.xdc`'s relaxed set on that file's own test, so its address
  // arrives with the microcycle to settle that the exception gives it.  A
  // register here would cost the debug master a tick and buy nothing.
  assign dbg_gnt  = dbg_own;
  assign con_gnt  = con_own;
  assign sr_msyn  = dbg_own ? dbg_msyn  : con_own ? con_msyn_q  : cpu_msyn;
  assign sr_write = dbg_own ? dbg_write : con_own ? con_write_q : cpu_write;
  assign sr_addr  = dbg_own ? dbg_addr  : con_own ? con_addr_q  : cpu_addr;
  assign sr_wdata = dbg_own ? dbg_wdata : con_own ? con_wdata_q : cpu_wdata;
  // `-UB SSYN` goes back to whoever asked and to nobody else.
  assign cpu_ssyn = (dbg_own || con_own) ? 1'b0 : sr_ssyn;
  assign con_ssyn = (con_own && !dbg_own) ? sr_ssyn : 1'b0;
  assign dbg_ssyn = dbg_own ? sr_ssyn : 1'b0;
  // The debug master takes the word at `-UB SSYN`, not at the boundary: MIT's
  // `DEBUG ACK` is `DBUB MASTER AND SSYN T0` and the word is "as of that
  // instant".  The mux has had the whole cycle to settle by then --- the
  // address is out at the grant and `-UB SSYN` is 350 ns later --- so this
  // needs none of the boundary capture the console's read-back needs.
  assign dbg_rdata = sr_rdata;

endmodule

`default_nettype wire
