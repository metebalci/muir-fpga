// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The diagnostic bus's arbiter, and the seam the console reaches it through.
//
// `0o766000` has two masters: the CADR itself, whose microcode writes the
// mode register there through `cadr_busint_xbus`, and `rtl/plumbing/cadr_console.sv`,
// which is an AXI slave on `M_AXI_GP1` outside the machine altogether.  This
// keeps them apart, and it does one more thing that turns out to matter far
// more: **it puts the console's side of the bus inside `cadr_machine`, where
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
    input  var logic        clk,          // 160 MHz, one tick = 6.25 ns
    input  var logic        rst,
    input  var logic        mclk,         // MCLK7, the microcycle boundary

    // --- the processor's own master, `cadr_busint_xbus`'s Unibus cycle
    input  var logic        cpu_msyn,
    input  var logic        cpu_write,
    input  var logic [17:0] cpu_addr,
    input  var logic [15:0] cpu_wdata,
    output var logic        cpu_ssyn,

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

  logic        con_own;
  logic        con_msyn_q, con_write_q;
  logic [17:0] con_addr_q;
  logic [15:0] con_wdata_q;

  always_ff @(posedge clk) begin
    if (rst) begin
      con_own     <= 1'b0;
      con_msyn_q  <= 1'b0;
      con_write_q <= 1'b0;
      con_addr_q  <= 18'd0;
      con_wdata_q <= 16'd0;
      con_rdata   <= 16'd0;
    end else begin
      if (con_own) con_own <= con_req;
      else con_own <= con_req && !cpu_msyn;
      con_msyn_q  <= con_msyn;
      con_write_q <= con_write;
      con_addr_q  <= con_addr;
      con_wdata_q <= con_wdata;
      // The answer, taken at the boundary and nowhere else: see the header.
      if (mclk) con_rdata <= sr_rdata;
    end
  end

  assign con_gnt  = con_own;
  assign sr_msyn  = con_own ? con_msyn_q  : cpu_msyn;
  assign sr_write = con_own ? con_write_q : cpu_write;
  assign sr_addr  = con_own ? con_addr_q  : cpu_addr;
  assign sr_wdata = con_own ? con_wdata_q : cpu_wdata;
  assign cpu_ssyn = con_own ? 1'b0 : sr_ssyn;
  assign con_ssyn = con_own ? sr_ssyn : 1'b0;

endmodule

`default_nettype wire
