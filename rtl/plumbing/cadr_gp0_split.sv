// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The splitter on `M_AXI_GP0`: which of four slaves a transaction is for.
//
// **WHY THERE WAS ONLY EVER ONE SLAVE ON THIS PORT, AND WHY THAT HAD TO
// CHANGE.**  A read on `M_AXI_GP0` that nothing in the fabric answers does
// not fault the Arm; it hangs both cores at one PC each.  Measured on the
// board: the pack feeder read the pack side's IDENT at `0x4000_0000` on a
// bitstream without the pack side, nothing drove ARREADY, and both cores
// stood at one PC for as long as anyone looked.  No software guard can catch
// a load that never completes.  So the rule this project has held to since
// is that the fabric which owns a general purpose port answers EVERY address
// on it --- which `cadr_disk_pack.sv` does, in its own window and out of it,
// and `cadr_gp0_default.sv` does for a board without the pack side.  One
// slave answering a gigabyte is the cheapest way to keep that rule, and it
// is why the console went to `M_AXI_GP1` rather than share GP0.
//
// Three faces want the port now --- the pack side, the Chaosnet cable and
// the serial line, the last two being the I/O board's two cables and so one
// card --- and a third `M_AXI_GP` does not exist.  This is the decode that
// lets them share it **without any address falling through**: three 4 KB
// pages, and a fourth port for the rest of the gigabyte.
//
//     0x4000_0000   the pack side          `cadr_disk_pack.sv`
//     0x4000_1000   the Chaosnet cable     `cadr_chaos_cable.sv`
//     0x4000_2000   the serial line        `cadr_serial_line.sv`
//     everything else                      `cadr_gp0_default.sv`
//
// The three bases are the ones `chaos_face.h` and `serial_face.h` already
// assume and the one the pack side already has, so no program moves.  Each
// is a parameter: a face that moves moves here and in one `#define`.
//
// **THE DEFAULT PORT MUST BE CONNECTED, AND LINT IS WHAT SAYS SO.**  This
// module cannot answer a page nothing is behind --- it has no word of its own
// --- so the promise "every address is answered" is a promise about the
// composition and not about this file.  What keeps it is that an unconnected
// port on the instantiation is a PINMISSING: the same thing that stopped
// `arty.pass` when `dev_wdata` was connected to nothing.  The fourth port
// carries no address, no length and no write data, because what answers
// there answers without looking at one; that is `cadr_gp0_default.sv`'s own
// property and this is the shape of it.
//
// **TWO SELECTIONS, NOT ONE, AND THIS IS THE MEMORY PATH'S LESSON APPLIED A
// SECOND TIME.**  `cadr_memory_path.sv` learned that one shared decode in
// front of the register puts a channel's page into the wrong responder, and
// that two instances of a decode checked exhaustively cost eleven LUTs.
// Here the two things that must not share are the write channel and the read
// channel: they are independent in AXI and the interconnect drives them
// independently, so a single held selection would route a read of the
// Chaosnet page to whichever slave a write in flight at the same moment had
// chosen.  `w_sel` and `r_sel` are therefore two registers off two instances
// of `target()`, and the check runs a write and a read to DIFFERENT pages at
// once for exactly this reason --- `split-one-selection-for-both-channels`
// is the record, and a stimulus that only ever had one channel busy could
// not see it.
//
// **THE MATCH IS HELD, NEVER COMPUTED.**  The disk controller's first draft
// matched `phys` combinationally and carried the map's ripple into
// `-MEMACK`/`-LOADMD` and so into the countdowns' clock enables: thirteen
// logic levels, -6.195 ns on 1,065 endpoints.  The page is decoded off the
// address that is about to be loaded and lands in a register beside it ---
// `cadr_phase_gen.sv`'s trick of asking the same question a tick early ---
// so nothing downstream of the selection ever sees an address through a
// decode in its own tick.  It costs one tick a transaction, in `W_ISSUE` and
// `R_ISSUE`, on a port Linux makes a handful of register accesses on per
// block.
//
// **AND NOTHING RETURNS FROM THE PS7'S ADDRESS PINS TO ITS READY PINS.**
// `s_awready` and `s_arready` are state bits and not functions of the
// address, so the tick that accepts an address has no decode in it at all.
// That is the other half of the tick this costs, and it is the half worth
// buying: `cadr_disk_pack.sv`'s own header records -0.164 ns on an RDATA
// path that was four logic levels off a register, the hard block's setup
// being most of the tick.
//
// **THE PAGE IS THIS MODULE'S AND THE OFFSET IS THE SLAVE'S.**  The two new
// faces are handed twelve bits of address --- the offset within their page
// --- and not the whole of it, so a face cannot answer outside the page it
// was given however wide its own match is.  That is the shape
// `tv-answers-its-neighbours` failed at: a mutation downstream of a guard
// tests the guard and not the thing, so the guard goes where it cannot be
// bypassed.  The pack side keeps the full address, because its own window is
// 64 bytes inside its page and it compares against `REG_BASE` itself.
//
// **AXI FORBIDS A BURST THAT CROSSES A 4 KB BOUNDARY**, so a legal burst
// stays inside the page it started in and a twelve-bit offset that wraps is
// unreachable.  The check drives a burst at the end of a page anyway, and
// requires it to terminate.
//
// WHAT IS NOT HERE.  One transaction a direction: a second address waits
// with `s_awready` low, which is legal and is what the slaves behind this
// already do.  No reordering and no interleaving, so no write-data ID --- the
// PS7's `MAXIGP0WID` is an output nobody reads, here as in `cadr_ps7.sv`.
// The responses are the slave's own, carried through unchanged rather than
// regenerated from the captured ID: a downstream slave that echoed the wrong
// BID would otherwise be invisible at the top.
//
// NO muir REFERENCE EXISTS FOR ANY OF THIS, as none exists for
// `cadr_axi_master.sv` or the pack side: nothing in MIT's drawings is an AXI
// interconnect.  It is held to the AXI3 protocol --- exactly one handshake
// per channel per transaction, payload stable under valid, WLAST and RLAST
// where the length says --- and to read-back: an address written and read
// again gives back what the slave the map names holds, and no other slave
// saw the transaction at all.  `tb/cadr_gp0_split_tb.cpp` sweeps the whole
// gigabyte with four slaves behind the splitter, each answering with
// something only it can answer, and counts every handshake on every one of
// the five faces.

`default_nettype none

module cadr_gp0_split #(
    // The three pages.  `cadr_disk_pack.sv`'s own `REG_BASE` default, and
    // the two the Linux headers assume.
    parameter logic [31:0] PACK_BASE  = 32'h4000_0000,
    parameter logic [31:0] CHAOS_BASE = 32'h4000_1000,
    parameter logic [31:0] SER_BASE   = 32'h4000_2000
) (
    input  var logic        clk,
    input  var logic        rst,

    // --- M_AXI_GP0 as the PS drives it: 32 bits, AXI3, the PS the master ---
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

    // --- the pack side, which keeps the whole address ---------------------
    output var logic [31:0] pack_awaddr,
    output var logic [3:0]  pack_awlen,
    output var logic [11:0] pack_awid,
    output var logic        pack_awvalid,
    input  var logic        pack_awready,
    output var logic [31:0] pack_wdata,
    output var logic [3:0]  pack_wstrb,
    output var logic        pack_wlast,
    output var logic        pack_wvalid,
    input  var logic        pack_wready,
    input  var logic [1:0]  pack_bresp,
    input  var logic [11:0] pack_bid,
    input  var logic        pack_bvalid,
    output var logic        pack_bready,
    output var logic [31:0] pack_araddr,
    output var logic [3:0]  pack_arlen,
    output var logic [11:0] pack_arid,
    output var logic        pack_arvalid,
    input  var logic        pack_arready,
    input  var logic [31:0] pack_rdata,
    input  var logic [1:0]  pack_rresp,
    input  var logic [11:0] pack_rid,
    input  var logic        pack_rlast,
    input  var logic        pack_rvalid,
    output var logic        pack_rready,

    // --- the Chaosnet cable, the offset in its page -----------------------
    output var logic [11:0] chaos_awaddr,
    output var logic [3:0]  chaos_awlen,
    output var logic [11:0] chaos_awid,
    output var logic        chaos_awvalid,
    input  var logic        chaos_awready,
    output var logic [31:0] chaos_wdata,
    output var logic [3:0]  chaos_wstrb,
    output var logic        chaos_wlast,
    output var logic        chaos_wvalid,
    input  var logic        chaos_wready,
    input  var logic [1:0]  chaos_bresp,
    input  var logic [11:0] chaos_bid,
    input  var logic        chaos_bvalid,
    output var logic        chaos_bready,
    output var logic [11:0] chaos_araddr,
    output var logic [3:0]  chaos_arlen,
    output var logic [11:0] chaos_arid,
    output var logic        chaos_arvalid,
    input  var logic        chaos_arready,
    input  var logic [31:0] chaos_rdata,
    input  var logic [1:0]  chaos_rresp,
    input  var logic [11:0] chaos_rid,
    input  var logic        chaos_rlast,
    input  var logic        chaos_rvalid,
    output var logic        chaos_rready,

    // --- the serial line, the offset in its page --------------------------
    output var logic [11:0] ser_awaddr,
    output var logic [3:0]  ser_awlen,
    output var logic [11:0] ser_awid,
    output var logic        ser_awvalid,
    input  var logic        ser_awready,
    output var logic [31:0] ser_wdata,
    output var logic [3:0]  ser_wstrb,
    output var logic        ser_wlast,
    output var logic        ser_wvalid,
    input  var logic        ser_wready,
    input  var logic [1:0]  ser_bresp,
    input  var logic [11:0] ser_bid,
    input  var logic        ser_bvalid,
    output var logic        ser_bready,
    output var logic [11:0] ser_araddr,
    output var logic [3:0]  ser_arlen,
    output var logic [11:0] ser_arid,
    output var logic        ser_arvalid,
    input  var logic        ser_arready,
    input  var logic [31:0] ser_rdata,
    input  var logic [1:0]  ser_rresp,
    input  var logic [11:0] ser_rid,
    input  var logic        ser_rlast,
    input  var logic        ser_rvalid,
    output var logic        ser_rready,

    // --- everything else, which answers without looking at an address -----
    output var logic [11:0] dflt_awid,
    output var logic        dflt_awvalid,
    input  var logic        dflt_awready,
    output var logic        dflt_wlast,
    output var logic        dflt_wvalid,
    input  var logic        dflt_wready,
    input  var logic [1:0]  dflt_bresp,
    input  var logic [11:0] dflt_bid,
    input  var logic        dflt_bvalid,
    output var logic        dflt_bready,
    output var logic [3:0]  dflt_arlen,
    output var logic [11:0] dflt_arid,
    output var logic        dflt_arvalid,
    input  var logic        dflt_arready,
    input  var logic [31:0] dflt_rdata,
    input  var logic [1:0]  dflt_rresp,
    input  var logic [11:0] dflt_rid,
    input  var logic        dflt_rlast,
    input  var logic        dflt_rvalid,
    output var logic        dflt_rready
);

  // The four, one hot.  One hot because the selection then muxes in one LUT
  // level a bit, and because "exactly one" is a property a reader can see:
  // `target()` returns exactly one bit on every input, including the inputs
  // nothing names.
  localparam int unsigned T_PACK  = 0;
  localparam int unsigned T_CHAOS = 1;
  localparam int unsigned T_SER   = 2;
  localparam int unsigned T_DFLT  = 3;
  localparam logic [3:0] SEL_PACK  = 4'b0001;
  localparam logic [3:0] SEL_CHAOS = 4'b0010;
  localparam logic [3:0] SEL_SER   = 4'b0100;
  localparam logic [3:0] SEL_DFLT  = 4'b1000;

  // Which slave a page belongs to.  Used at two places below --- once on the
  // write address and once on the read --- which is two instances in fabric
  // and is the point: see the header.
  function automatic logic [3:0] target(input logic [31:12] page);
    if (page == PACK_BASE[31:12]) return SEL_PACK;
    else if (page == CHAOS_BASE[31:12]) return SEL_CHAOS;
    else if (page == SER_BASE[31:12]) return SEL_SER;
    else return SEL_DFLT;
  endfunction

  typedef enum logic [1:0] { W_ADDR, W_ISSUE, W_DATA, W_RESP } wstate_e;
  typedef enum logic [1:0] { R_ADDR, R_ISSUE, R_DATA } rstate_e;
  wstate_e wst;
  rstate_e rst_r;

  // The transaction, captured: the address, the length and the ID, with the
  // selection made beside them.
  logic [31:0] w_at, r_at;
  logic [3:0]  w_len, r_len;
  logic [11:0] w_id, r_id;
  logic [3:0]  w_sel, r_sel;

  // ------------------------------------------------------------------------
  // What the four see.  The payload is broadcast and only the valid is
  // gated: a slave that is not selected is offered nothing, so it cannot
  // take a beat of somebody else's transaction whatever its own match says.
  // ------------------------------------------------------------------------
  assign pack_awaddr  = w_at;
  assign pack_awlen   = w_len;
  assign pack_awid    = w_id;
  assign pack_awvalid = (wst == W_ISSUE) && w_sel[T_PACK];
  assign pack_wdata   = s_wdata;
  assign pack_wstrb   = s_wstrb;
  assign pack_wlast   = s_wlast;
  assign pack_wvalid  = (wst == W_DATA) && w_sel[T_PACK] && s_wvalid;
  assign pack_bready  = (wst == W_RESP) && w_sel[T_PACK] && s_bready;
  assign pack_araddr  = r_at;
  assign pack_arlen   = r_len;
  assign pack_arid    = r_id;
  assign pack_arvalid = (rst_r == R_ISSUE) && r_sel[T_PACK];
  assign pack_rready  = (rst_r == R_DATA) && r_sel[T_PACK] && s_rready;

  assign chaos_awaddr  = w_at[11:0];
  assign chaos_awlen   = w_len;
  assign chaos_awid    = w_id;
  assign chaos_awvalid = (wst == W_ISSUE) && w_sel[T_CHAOS];
  assign chaos_wdata   = s_wdata;
  assign chaos_wstrb   = s_wstrb;
  assign chaos_wlast   = s_wlast;
  assign chaos_wvalid  = (wst == W_DATA) && w_sel[T_CHAOS] && s_wvalid;
  assign chaos_bready  = (wst == W_RESP) && w_sel[T_CHAOS] && s_bready;
  assign chaos_araddr  = r_at[11:0];
  assign chaos_arlen   = r_len;
  assign chaos_arid    = r_id;
  assign chaos_arvalid = (rst_r == R_ISSUE) && r_sel[T_CHAOS];
  assign chaos_rready  = (rst_r == R_DATA) && r_sel[T_CHAOS] && s_rready;

  assign ser_awaddr  = w_at[11:0];
  assign ser_awlen   = w_len;
  assign ser_awid    = w_id;
  assign ser_awvalid = (wst == W_ISSUE) && w_sel[T_SER];
  assign ser_wdata   = s_wdata;
  assign ser_wstrb   = s_wstrb;
  assign ser_wlast   = s_wlast;
  assign ser_wvalid  = (wst == W_DATA) && w_sel[T_SER] && s_wvalid;
  assign ser_bready  = (wst == W_RESP) && w_sel[T_SER] && s_bready;
  assign ser_araddr  = r_at[11:0];
  assign ser_arlen   = r_len;
  assign ser_arid    = r_id;
  assign ser_arvalid = (rst_r == R_ISSUE) && r_sel[T_SER];
  assign ser_rready  = (rst_r == R_DATA) && r_sel[T_SER] && s_rready;

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
  logic [11:0] sel_bid, sel_rid;
  logic [31:0] sel_rdata;
  logic        sel_rlast;

  always_comb begin
    unique case (w_sel)
      SEL_PACK: begin
        sel_awready = pack_awready;
        sel_wready  = pack_wready;
        sel_bvalid  = pack_bvalid;
        sel_bresp   = pack_bresp;
        sel_bid     = pack_bid;
      end
      SEL_CHAOS: begin
        sel_awready = chaos_awready;
        sel_wready  = chaos_wready;
        sel_bvalid  = chaos_bvalid;
        sel_bresp   = chaos_bresp;
        sel_bid     = chaos_bid;
      end
      SEL_SER: begin
        sel_awready = ser_awready;
        sel_wready  = ser_wready;
        sel_bvalid  = ser_bvalid;
        sel_bresp   = ser_bresp;
        sel_bid     = ser_bid;
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
      SEL_PACK: begin
        sel_arready = pack_arready;
        sel_rvalid  = pack_rvalid;
        sel_rdata   = pack_rdata;
        sel_rresp   = pack_rresp;
        sel_rid     = pack_rid;
        sel_rlast   = pack_rlast;
      end
      SEL_CHAOS: begin
        sel_arready = chaos_arready;
        sel_rvalid  = chaos_rvalid;
        sel_rdata   = chaos_rdata;
        sel_rresp   = chaos_rresp;
        sel_rid     = chaos_rid;
        sel_rlast   = chaos_rlast;
      end
      SEL_SER: begin
        sel_arready = ser_arready;
        sel_rvalid  = ser_rvalid;
        sel_rdata   = ser_rdata;
        sel_rresp   = ser_rresp;
        sel_rid     = ser_rid;
        sel_rlast   = ser_rlast;
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
      w_len <= 4'd0;
      r_len <= 4'd0;
      w_id  <= 12'd0;
      r_id  <= 12'd0;
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
