// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The splitter on `M_AXI_GP1`: which of three slaves a transaction is for.
//
// **WHY THE PORT HAD TO BE SHARED, AND WHY IT IS THIS PORT.**  The debug
// cable's carrier, `rtl/plumbing/cadr_debug_window.sv`, is a whole-port AXI3
// slave and wants a general-purpose port.  The XC7Z020 has exactly two and
// there is no third: `M_AXI_GP0` carries the disk pack side, the Chaosnet
// cable and the serial line behind `rtl/plumbing/cadr_gp0_split.sv`, and
// `M_AXI_GP1` carries the console.  `docs/debug-cable.md` set out three ways
// to fit the window in and the decision is the second: the window shares GP1
// behind a split of its own.  Moving the console to GP0 would put new logic
// in front of the port that has actually frozen both Arm cores, and putting
// the window behind the console's own decode would place its address match
// downstream of an exhaustively checked guard --- which this project has
// measured tests the guard and not the thing (`tv-answers-its-neighbours`).
//
//     0x8000_0000   the console            `rtl/plumbing/cadr_console.sv`
//     0x8000_1000   the debug cable        `rtl/plumbing/cadr_debug_window.sv`
//     everything else                      `rtl/plumbing/cadr_gp0_default.sv`
//
// The console keeps `0x8000_0000`, its own `REG_BASE` default, so
// `cadr-console` does not move and `build/console.pass` is unchanged.  The
// window takes the next page, so `--debug-cable-connect 0x80001000` is what
// muir is told.
//
// **THIS IS `cadr_gp0_split.sv` ONE PORT ALONG, AND DELIBERATELY SO.**  The
// state machines, the held match, the two independent selections and the
// carried-through responses are that module's, because it is the same
// problem and a second shape would be a second thing to be wrong.  What is
// not shared is the module itself.  One parameterized splitter would be a
// generate loop over a port list, and the two ports have different slaves,
// different page counts and different checks.  Two small modules that read
// alike are cheaper to hold than one that reads for neither.
//
// **THE DEFAULT PORT MUST BE CONNECTED, AND LINT IS WHAT SAYS SO.**  This
// module cannot answer a page nothing is behind --- it has no word of its own
// --- so the promise "every address is answered" is a promise about the
// composition and not about this file.  What keeps it is that an unconnected
// port on the instantiation is a PINMISSING, the same thing that stopped
// `build/arty.pass` when `dev_wdata` was connected to nothing.  The third
// port carries no address, no length and no write data, because what answers
// there answers without looking at one.
//
// **AND THE PROMISE IS NOT DECORATIVE ON THIS PORT EITHER.**  A read on a
// general-purpose port that nothing in the fabric answers does not fault the
// Arm; it hangs both cores at one program counter each, measured on the
// board when the pack feeder read a register face on a bitstream without the
// slave behind it.  No software guard can catch a load that never completes.
// Before this module, `cadr_console.sv` answered the whole gigabyte itself;
// now the console answers its page, the window answers its page, and
// `cadr_gp0_default.sv` answers the other 262,142.
//
// **TWO SELECTIONS, NOT ONE.**  The write channel and the read channel are
// independent in AXI and the interconnect drives them independently, so a
// single held selection would route a read of the window's page to whichever
// slave a write in flight at the same moment had chosen.  `w_sel` and
// `r_sel` are two registers off two instances of `target()`, and the check
// runs a write and a read to different pages at once for exactly that
// reason.  `gp0_split.sv`'s `split-one-selection-for-both-channels` is the
// record on the other port and this one has its own.
//
// **THE MATCH IS HELD, NEVER COMPUTED.**  The page is decoded off the
// address that is about to be loaded and lands in a register beside it, so
// nothing downstream of the selection ever sees an address through a decode
// in its own tick.  It costs one tick a transaction, in `W_ISSUE` and
// `R_ISSUE`, on a port Linux makes a handful of register accesses on.  And
// nothing returns from the PS7's address pins to its ready pins: `s_awready`
// and `s_arready` are state bits and not functions of the address.
//
// **BOTH SLAVES KEEP THE WHOLE ADDRESS**, where `cadr_gp0_split.sv` hands
// its two new faces twelve bits.  The reason is the one that file gives for
// the pack side: a slave whose own window is smaller than its page and which
// compares against its own `REG_BASE` keeps the full address, and the guard
// that stops it answering outside its page is the gated `valid` and not the
// width of the address it is handed.  The console's window is 128 bytes and
// the debug cable's is 64, both inside their page, and both compare against
// `REG_BASE` themselves --- so `REG_BASE` is literally the address a program
// is told, which is what `--debug-cable-connect 0x…` wants.
//
// **AXI FORBIDS A BURST THAT CROSSES A 4 KB BOUNDARY**, so a legal burst
// stays inside the page it started in.  The check drives a burst at the end
// of a page anyway, and requires it to terminate.
//
// WHAT IS NOT HERE.  One transaction a direction: a second address waits
// with `s_awready` low, which is legal and is what the slaves behind this
// already do.  No reordering and no interleaving, so no write-data ID --- the
// PS7's `MAXIGP1WID` is an output nobody reads, here as in `cadr_ps7.sv`.
// The responses are the slave's own, carried through unchanged rather than
// regenerated from the captured ID: a downstream slave that echoed the wrong
// BID would otherwise be invisible at the top.
//
// NO muir REFERENCE EXISTS FOR ANY OF THIS, as none exists for
// `cadr_axi_master.sv`, for the pack side or for the other splitter: nothing
// in MIT's drawings is an AXI interconnect.  It is held to the AXI3 protocol
// --- exactly one handshake per channel per transaction, payload stable under
// valid, WLAST and RLAST where the length says --- and to read-back.
// `tb/cadr_gp1_split_tb.cpp` sweeps the whole gigabyte with the real three
// slaves behind the splitter, each answering with something only it can
// answer, and then reaches the SAME diagnostic register block by both of the
// two roads the port now has: `spy_read` through the console's page, and a
// debug cycle over MIT's own cable through the window's.

//
// **AND THE SAME ARRANGEMENT ON THE AGILEX 5'S BRIDGES, WHICH ARE AXI4.**
// `ID_W` and `LEN_W` are the transaction ID's width and the burst length's:
// twelve and four here, which is a Zynq `M_AXI_GP`'s AXI3 shape, and four and
// eight on the DE25-Nano's two processor-to-fabric bridges, where a read may
// therefore be 256 beats.  The bases are parameters already, and there they
// are OFFSETS into the bridge's own window rather than the processor's
// addresses, the bridge handing the fabric an offset.  So one arrangement
// serves two boards, and the check runs its whole sweep twice rather than
// twice over: `boards/de25-nano/README.md` has that board's map.
//
// The DE25-Nano puts this pair on its lightweight bridge, whose window is
// 512 MB at `0x2000_0000`: the console at offset 0 and the cable's carrier at
// `0x1000`, which is `0x2000_0000` and `0x2000_1000` to a program.

`default_nettype none

module cadr_gp1_split #(
    // The two pages.  `cadr_console.sv`'s own `REG_BASE` default, so the
    // console does not move, and the page above it for the debug cable.
    parameter logic [31:0] CON_BASE = 32'h8000_0000,
    parameter logic [31:0] DBG_BASE = 32'h8000_1000,
    // The transaction ID's width and the burst length's: twelve and four on a
    // Zynq board's `M_AXI_GP`, which is AXI3, and four and eight on the
    // Agilex 5's two processor-to-fabric bridges, which are AXI4 and so may
    // ask for 256 beats.  `cadr_gp0_default.sv`'s header has the argument,
    // and every slave behind this takes the same two.
    parameter int unsigned ID_W  = 12,
    parameter int unsigned LEN_W = 4
) (
    input  var logic        clk,
    input  var logic        rst,

    // --- M_AXI_GP1 as the PS drives it: 32 bits, AXI3, the PS the master ---
    input  var logic [31:0] s_awaddr,
    input  var logic [LEN_W-1:0]  s_awlen,
    input  var logic [ID_W-1:0] s_awid,
    input  var logic        s_awvalid,
    output var logic        s_awready,
    input  var logic [31:0] s_wdata,
    input  var logic [3:0]  s_wstrb,
    input  var logic        s_wlast,
    input  var logic        s_wvalid,
    output var logic        s_wready,
    output var logic [1:0]  s_bresp,
    output var logic [ID_W-1:0] s_bid,
    output var logic        s_bvalid,
    input  var logic        s_bready,
    input  var logic [31:0] s_araddr,
    input  var logic [LEN_W-1:0]  s_arlen,
    input  var logic [ID_W-1:0] s_arid,
    input  var logic        s_arvalid,
    output var logic        s_arready,
    output var logic [31:0] s_rdata,
    output var logic [1:0]  s_rresp,
    output var logic [ID_W-1:0] s_rid,
    output var logic        s_rlast,
    output var logic        s_rvalid,
    input  var logic        s_rready,

    // --- the console, which keeps the whole address ----------------------
    output var logic [31:0] con_awaddr,
    output var logic [LEN_W-1:0]  con_awlen,
    output var logic [ID_W-1:0] con_awid,
    output var logic        con_awvalid,
    input  var logic        con_awready,
    output var logic [31:0] con_wdata,
    output var logic [3:0]  con_wstrb,
    output var logic        con_wlast,
    output var logic        con_wvalid,
    input  var logic        con_wready,
    input  var logic [1:0]  con_bresp,
    input  var logic [ID_W-1:0] con_bid,
    input  var logic        con_bvalid,
    output var logic        con_bready,
    output var logic [31:0] con_araddr,
    output var logic [LEN_W-1:0]  con_arlen,
    output var logic [ID_W-1:0] con_arid,
    output var logic        con_arvalid,
    input  var logic        con_arready,
    input  var logic [31:0] con_rdata,
    input  var logic [1:0]  con_rresp,
    input  var logic [ID_W-1:0] con_rid,
    input  var logic        con_rlast,
    input  var logic        con_rvalid,
    output var logic        con_rready,

    // --- the debug cable's carrier, which keeps the whole address too ----
    output var logic [31:0] dbg_awaddr,
    output var logic [LEN_W-1:0]  dbg_awlen,
    output var logic [ID_W-1:0] dbg_awid,
    output var logic        dbg_awvalid,
    input  var logic        dbg_awready,
    output var logic [31:0] dbg_wdata,
    output var logic [3:0]  dbg_wstrb,
    output var logic        dbg_wlast,
    output var logic        dbg_wvalid,
    input  var logic        dbg_wready,
    input  var logic [1:0]  dbg_bresp,
    input  var logic [ID_W-1:0] dbg_bid,
    input  var logic        dbg_bvalid,
    output var logic        dbg_bready,
    output var logic [31:0] dbg_araddr,
    output var logic [LEN_W-1:0]  dbg_arlen,
    output var logic [ID_W-1:0] dbg_arid,
    output var logic        dbg_arvalid,
    input  var logic        dbg_arready,
    input  var logic [31:0] dbg_rdata,
    input  var logic [1:0]  dbg_rresp,
    input  var logic [ID_W-1:0] dbg_rid,
    input  var logic        dbg_rlast,
    input  var logic        dbg_rvalid,
    output var logic        dbg_rready,

    // --- everything else, which answers without looking at an address ----
    output var logic [ID_W-1:0] dflt_awid,
    output var logic        dflt_awvalid,
    input  var logic        dflt_awready,
    output var logic        dflt_wlast,
    output var logic        dflt_wvalid,
    input  var logic        dflt_wready,
    input  var logic [1:0]  dflt_bresp,
    input  var logic [ID_W-1:0] dflt_bid,
    input  var logic        dflt_bvalid,
    output var logic        dflt_bready,
    output var logic [LEN_W-1:0]  dflt_arlen,
    output var logic [ID_W-1:0] dflt_arid,
    output var logic        dflt_arvalid,
    input  var logic        dflt_arready,
    input  var logic [31:0] dflt_rdata,
    input  var logic [1:0]  dflt_rresp,
    input  var logic [ID_W-1:0] dflt_rid,
    input  var logic        dflt_rlast,
    input  var logic        dflt_rvalid,
    output var logic        dflt_rready
);

  // The three, one hot.  One hot because the selection then muxes in one LUT
  // level a bit, and because "exactly one" is a property a reader can see:
  // `target()` returns exactly one bit on every input, including the inputs
  // nothing names.
  localparam int unsigned T_CON  = 0;
  localparam int unsigned T_DBG  = 1;
  localparam int unsigned T_DFLT = 2;
  localparam logic [2:0] SEL_CON  = 3'b001;
  localparam logic [2:0] SEL_DBG  = 3'b010;
  localparam logic [2:0] SEL_DFLT = 3'b100;

  // Which slave a page belongs to.  Used at two places below --- once on the
  // write address and once on the read --- which is two instances in fabric
  // and is the point: see the header.
  function automatic logic [2:0] target(input logic [31:12] page);
    if (page == CON_BASE[31:12]) return SEL_CON;
    else if (page == DBG_BASE[31:12]) return SEL_DBG;
    else return SEL_DFLT;
  endfunction

  typedef enum logic [1:0] { W_ADDR, W_ISSUE, W_DATA, W_RESP } wstate_e;
  typedef enum logic [1:0] { R_ADDR, R_ISSUE, R_DATA } rstate_e;
  wstate_e wst;
  rstate_e rst_r;

  // The transaction, captured: the address, the length and the ID, with the
  // selection made beside them.
  logic [31:0] w_at, r_at;
  logic [LEN_W-1:0] w_len, r_len;
  logic [ID_W-1:0]  w_id, r_id;
  logic [2:0]  w_sel, r_sel;

  // ------------------------------------------------------------------------
  // What the three see.  The payload is broadcast and only the valid is
  // gated: a slave that is not selected is offered nothing, so it cannot
  // take a beat of somebody else's transaction whatever its own match says.
  // ------------------------------------------------------------------------
  assign con_awaddr  = w_at;
  assign con_awlen   = w_len;
  assign con_awid    = w_id;
  assign con_awvalid = (wst == W_ISSUE) && w_sel[T_CON];
  assign con_wdata   = s_wdata;
  assign con_wstrb   = s_wstrb;
  assign con_wlast   = s_wlast;
  assign con_wvalid  = (wst == W_DATA) && w_sel[T_CON] && s_wvalid;
  assign con_bready  = (wst == W_RESP) && w_sel[T_CON] && s_bready;
  assign con_araddr  = r_at;
  assign con_arlen   = r_len;
  assign con_arid    = r_id;
  assign con_arvalid = (rst_r == R_ISSUE) && r_sel[T_CON];
  assign con_rready  = (rst_r == R_DATA) && r_sel[T_CON] && s_rready;

  assign dbg_awaddr  = w_at;
  assign dbg_awlen   = w_len;
  assign dbg_awid    = w_id;
  assign dbg_awvalid = (wst == W_ISSUE) && w_sel[T_DBG];
  assign dbg_wdata   = s_wdata;
  assign dbg_wstrb   = s_wstrb;
  assign dbg_wlast   = s_wlast;
  assign dbg_wvalid  = (wst == W_DATA) && w_sel[T_DBG] && s_wvalid;
  assign dbg_bready  = (wst == W_RESP) && w_sel[T_DBG] && s_bready;
  assign dbg_araddr  = r_at;
  assign dbg_arlen   = r_len;
  assign dbg_arid    = r_id;
  assign dbg_arvalid = (rst_r == R_ISSUE) && r_sel[T_DBG];
  assign dbg_rready  = (rst_r == R_DATA) && r_sel[T_DBG] && s_rready;

  assign dflt_awid    = w_id;
  assign dflt_awvalid = (wst == W_ISSUE) && w_sel[T_DFLT];
  assign dflt_wlast   = s_wlast;
  assign dflt_wvalid  = (wst == W_DATA) && w_sel[T_DFLT] && s_wvalid;
  assign dflt_bready  = (wst == W_RESP) && w_sel[T_DFLT] && s_bready;
  assign dflt_arlen   = r_len;
  assign dflt_arid    = r_id;
  assign dflt_arvalid = (rst_r == R_ISSUE) && r_sel[T_DFLT];
  assign dflt_rready  = (rst_r == R_DATA) && r_sel[T_DFLT] && s_rready;

  // ------------------------------------------------------------------------
  // And what comes back: the selected slave's, carried through unchanged.
  // ------------------------------------------------------------------------
  logic        sel_awready, sel_wready, sel_bvalid, sel_arready, sel_rvalid;
  logic [1:0]  sel_bresp, sel_rresp;
  logic [ID_W-1:0] sel_bid, sel_rid;
  logic [31:0] sel_rdata;
  logic        sel_rlast;

  always_comb begin
    unique case (w_sel)
      SEL_CON: begin
        sel_awready = con_awready;
        sel_wready  = con_wready;
        sel_bvalid  = con_bvalid;
        sel_bresp   = con_bresp;
        sel_bid     = con_bid;
      end
      SEL_DBG: begin
        sel_awready = dbg_awready;
        sel_wready  = dbg_wready;
        sel_bvalid  = dbg_bvalid;
        sel_bresp   = dbg_bresp;
        sel_bid     = dbg_bid;
      end
      default: begin
        sel_awready = dflt_awready;
        sel_wready  = dflt_wready;
        sel_bvalid  = dflt_bvalid;
        sel_bresp   = dflt_bresp;
        sel_bid     = dflt_bid;
      end
    endcase
    unique case (r_sel)
      SEL_CON: begin
        sel_arready = con_arready;
        sel_rvalid  = con_rvalid;
        sel_rdata   = con_rdata;
        sel_rresp   = con_rresp;
        sel_rid     = con_rid;
        sel_rlast   = con_rlast;
      end
      SEL_DBG: begin
        sel_arready = dbg_arready;
        sel_rvalid  = dbg_rvalid;
        sel_rdata   = dbg_rdata;
        sel_rresp   = dbg_rresp;
        sel_rid     = dbg_rid;
        sel_rlast   = dbg_rlast;
      end
      default: begin
        sel_arready = dflt_arready;
        sel_rvalid  = dflt_rvalid;
        sel_rdata   = dflt_rdata;
        sel_rresp   = dflt_rresp;
        sel_rid     = dflt_rid;
        sel_rlast   = dflt_rlast;
      end
    endcase
  end

  // The PS's side.  Both readies are state bits: nothing crosses from the
  // hard block's address pins back to its ready pins in one tick.
  assign s_awready = (wst == W_ADDR);
  assign s_wready  = (wst == W_DATA) && sel_wready;
  assign s_bvalid  = (wst == W_RESP) && sel_bvalid;
  assign s_bresp   = sel_bresp;
  assign s_bid     = sel_bid;
  assign s_arready = (rst_r == R_ADDR);
  assign s_rvalid  = (rst_r == R_DATA) && sel_rvalid;
  assign s_rdata   = sel_rdata;
  assign s_rresp   = sel_rresp;
  assign s_rid     = sel_rid;
  assign s_rlast   = sel_rlast;

  always_ff @(posedge clk) begin
    if (rst) begin
      wst   <= W_ADDR;
      rst_r <= R_ADDR;
      w_at  <= 32'd0;
      r_at  <= 32'd0;
      w_len <= '0;
      r_len <= '0;
      w_id  <= '0;
      r_id  <= '0;
      // The default port, so that a selection nothing has decoded yet names
      // the slave which answers whatever it is asked.  A one-hot register
      // coming up zero would offer a transaction to nobody, and on this port
      // that is the frozen cores again.
      w_sel <= SEL_DFLT;
      r_sel <= SEL_DFLT;
    end else begin
      unique case (wst)
        W_ADDR: if (s_awvalid) begin
          w_at  <= s_awaddr;
          w_len <= s_awlen;
          w_id  <= s_awid;
          w_sel <= target(s_awaddr[31:12]);
          wst   <= W_ISSUE;
        end
        W_ISSUE: if (sel_awready) wst <= W_DATA;
        W_DATA:  if (s_wvalid && sel_wready && s_wlast) wst <= W_RESP;
        W_RESP:  if (sel_bvalid && s_bready) wst <= W_ADDR;
        default: wst <= W_ADDR;
      endcase
      unique case (rst_r)
        R_ADDR: if (s_arvalid) begin
          r_at  <= s_araddr;
          r_len <= s_arlen;
          r_id  <= s_arid;
          r_sel <= target(s_araddr[31:12]);
          rst_r <= R_ISSUE;
        end
        R_ISSUE: if (sel_arready) rst_r <= R_DATA;
        // The transaction ends where the slave says it does, and the check
        // is what holds the slave to ending it at ARLEN+1 beats.  Counting
        // here and ending on the count would leave the port owing a beat to
        // a slave that sent fewer, which is the frozen cores a third time.
        R_DATA:  if (sel_rvalid && s_rready && sel_rlast) rst_r <= R_ADDR;
        default: rst_r <= R_ADDR;
      endcase
    end
  end

endmodule

`default_nettype wire
