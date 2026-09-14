// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The bridge: one of the soft core's loads or stores becomes one AXI
// transaction at one of the machine's register faces.
//
// **THE WHOLE POINT OF THIS FILE IS THAT NOTHING BEHIND IT CHANGES.**  The
// console, the disk pack face and the default slave were written against the
// Zynq's `M_AXI_GP0` and `M_AXI_GP1`: 32 bits, AXI3, 12-bit identifiers, one
// write and one read in flight at once, the whole address handed in.  A soft
// processing system that could not present exactly that would be a second
// description of every face, and this project's own record of what two
// descriptions of one thing cost fills a page.  So this presents that, and
// `rtl/plumbing/cadr_console.sv`, `rtl/plumbing/cadr_disk_pack.sv` and
// `rtl/plumbing/cadr_gp0_default.sv` are instantiated on this board with the
// same parameters and the same wires they have on the other two, and their
// checks are unchanged.
//
// **AND THE FIRMWARE AND THE LINUX PROGRAMS THEREFORE SHARE ONE MAP.**
// `console_face.h` says the console is at `0x8000_0000` and `pack_side.h`
// says the pack side is at `0x4000_0000`, and both are true of this board,
// where there is no Zynq to decode either.  A header that had to say "except
// on the Artix" would be the beginning of two programs.
//
// WHAT A TRANSACTION LOOKS LIKE.  Single beat, always: `AWLEN` and `ARLEN`
// are zero, `WLAST` is one, and `RLAST` is expected to come back one.  That
// is AXI4-Lite's shape wearing AXI3's signal list, which is exactly what the
// faces were written for --- the processing system never sent them anything
// longer either, and `cadr_disk_pack.sv`'s own header says so.
//
// **ONE TRANSACTION AT A TIME, AND THAT IS WHAT MAKES ONE SELECTION SAFE.**
// `rtl/plumbing/cadr_gp0_split.sv` holds TWO selections, one per channel,
// because the thing in front of it is a processing system that drives the
// read and the write channels independently and a single held selection would
// route a read to whichever slave a write in flight had chosen.  The thing in
// front of THIS is the core's load-store unit through a seam that takes one
// request and answers it before it takes another, so there is never a read
// and a write in flight together and `sel` is one register.  That is a
// property of this file and not an assumption about somebody else's master,
// and `tb/cadr_soc_tb.cpp` asserts it every tick rather than leaving it to be
// believed: `soc-bridge-takes-a-second-request` is the record.
//
// **THE MATCH IS HELD, NEVER COMPUTED**, which is the rule this repository
// learned from the disk controller's first draft and from the mapped window:
// the address is latched at the request and `sel` is a register off it, so no
// address comparison ripples into anything downstream.
//
// **AND EVERY ADDRESS IS ANSWERED, WHICH IS THE GP0-HANG RULE ONE LEVEL IN.**
// On the Zynq a read nothing answers inside a general-purpose window does not
// fault the ARM; it hangs both cores at one PC each, measured, and no software
// guard can catch a load that never completes.  A soft core is in exactly the
// same position and worse, because it has no interconnect to give it a DECERR
// at all.  So the last port here is a catch-all: every address that is none of
// the three windows goes to it, anywhere in the four gigabytes, and
// `cadr_gp0_default.sv` answers it with "NONE" and OKAY.  **A firmware on this
// board cannot hang on a load**, and that is a property of the composition
// rather than of the firmware's care.
//
// **SLVERR COMES BACK AS A RISC-V ACCESS FAULT.**  `cadr_disk_pack.sv`
// answers an address in its window that is not one of its registers with
// SLVERR, deliberately, and a bridge that swallowed that would be hiding the
// one thing the face is saying.  So `err` rises with `done` and the core takes
// a load or store access fault, which the firmware's trap handler prints.
//
// **THE IDENTIFIER IS A COUNTER AND NOT A CONSTANT.**  Every face echoes
// `AWID` on `BID` and `ARID` on `RID`, and an identifier that was always zero
// would make a face that dropped it look exactly like one that did not --- the
// same shape as a memory whose only exercise writes one constant, which this
// project has met twice.  So it counts, and `tb/cadr_soc_tb.cpp` asserts that
// what comes back is what went out.

`default_nettype none

module cadr_soc_axi #(
    // The three windows, at the addresses the Linux programs already use.
    // Each is 4 KB.  `cadr_console.sv`'s `REG_BASE`, `cadr_debug_window.sv`'s
    // and `cadr_disk_pack.sv`'s own defaults.
    parameter logic [31:0] PACK_BASE = 32'h4000_0000,
    parameter logic [31:0] CON_BASE  = 32'h8000_0000,
    parameter logic [31:0] DBG_BASE  = 32'h8000_1000
) (
    input  var logic        clk,
    input  var logic        rst,

    // --- the request seam, as `cadr_soc.sv` drives it from the core's
    // --- load-store unit.  `req` stands until `gnt`; `done` is one tick and
    // --- carries the answer.
    input  var logic        req,
    input  var logic        we,
    input  var logic [3:0]  be,
    input  var logic [31:0] addr,
    input  var logic [31:0] wdata,
    output var logic        gnt,
    output var logic        done,
    output var logic [31:0] rdata,
    output var logic        err,

    // --- the disk pack face ------------------------------------------------
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

    // --- the console -------------------------------------------------------
    output var logic [31:0] con_awaddr,
    output var logic [3:0]  con_awlen,
    output var logic [11:0] con_awid,
    output var logic        con_awvalid,
    input  var logic        con_awready,
    output var logic [31:0] con_wdata,
    output var logic [3:0]  con_wstrb,
    output var logic        con_wlast,
    output var logic        con_wvalid,
    input  var logic        con_wready,
    input  var logic [1:0]  con_bresp,
    input  var logic [11:0] con_bid,
    input  var logic        con_bvalid,
    output var logic        con_bready,
    output var logic [31:0] con_araddr,
    output var logic [3:0]  con_arlen,
    output var logic [11:0] con_arid,
    output var logic        con_arvalid,
    input  var logic        con_arready,
    input  var logic [31:0] con_rdata,
    input  var logic [1:0]  con_rresp,
    input  var logic [11:0] con_rid,
    input  var logic        con_rlast,
    input  var logic        con_rvalid,
    output var logic        con_rready,

    // --- the debug cable's register window ---------------------------------
    output var logic [31:0] dbg_awaddr,
    output var logic [3:0]  dbg_awlen,
    output var logic [11:0] dbg_awid,
    output var logic        dbg_awvalid,
    input  var logic        dbg_awready,
    output var logic [31:0] dbg_wdata,
    output var logic [3:0]  dbg_wstrb,
    output var logic        dbg_wlast,
    output var logic        dbg_wvalid,
    input  var logic        dbg_wready,
    input  var logic [1:0]  dbg_bresp,
    input  var logic [11:0] dbg_bid,
    input  var logic        dbg_bvalid,
    output var logic        dbg_bready,
    output var logic [31:0] dbg_araddr,
    output var logic [3:0]  dbg_arlen,
    output var logic [11:0] dbg_arid,
    output var logic        dbg_arvalid,
    input  var logic        dbg_arready,
    input  var logic [31:0] dbg_rdata,
    input  var logic [1:0]  dbg_rresp,
    input  var logic [11:0] dbg_rid,
    input  var logic        dbg_rlast,
    input  var logic        dbg_rvalid,
    output var logic        dbg_rready,

    // --- everything else, which answers without looking at an address.  The
    // --- port list is `cadr_gp0_default.sv`'s, signal for signal, so that an
    // --- unconnected pin is a PINMISSING rather than a silent hole --- which
    // --- is `cadr_gp1_split.sv`'s own argument one board along.
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

  // Which of the four a transaction is for.  The order matters only in that
  // `S_DFLT` is last and matches whatever the three windows did not.
  typedef enum logic [1:0] { S_PACK = 2'd0, S_CON = 2'd1, S_DBG = 2'd2,
                             S_DFLT = 2'd3 } target_e;

  // **THE WINDOWS ARE 4 KB AND THE COMPARISON IS ON BITS 31:12.**  A face
  // sees the whole address it was handed, as it does behind the Zynq, and
  // answers what is outside its own registers in its own way --- the console
  // with `UNMAPPED` and OKAY, the pack side with SLVERR.  That is their
  // business and not this file's; all this decides is which of them is asked.
  // **THE PAGE AND NOT THE ADDRESS.**  The argument is bits 31:12 alone, so
  // that a low bit which reaches nothing here cannot be read as though it did:
  // a function handed the whole word and using twenty bits of it would leave
  // lint saying nothing and a reader guessing.
  function automatic target_e target(input logic [19:0] page);
    if (page == PACK_BASE[31:12]) return S_PACK;
    else if (page == CON_BASE[31:12]) return S_CON;
    else if (page == DBG_BASE[31:12]) return S_DBG;
    else return S_DFLT;
  endfunction

  typedef enum logic [2:0] { IDLE, W_ADDR_DATA, W_RESP, R_ADDR, R_DATA } state_e;

  state_e            st;
  target_e           sel;
  logic [31:0]       a_hold;
  logic [31:0]       d_hold;
  logic [3:0]        be_hold;
  logic [11:0]       id;
  logic              aw_done, w_done;

  // The four ready lines and the four answers, muxed by the held selection.
  logic awready_sel, wready_sel, bvalid_sel, arready_sel, rvalid_sel;
  logic [1:0]  bresp_sel, rresp_sel;
  logic [31:0] rdata_sel;
  logic [11:0] bid_sel, rid_sel;

  always_comb begin
    case (sel)
      S_PACK: begin
        awready_sel = pack_awready; wready_sel = pack_wready;
        bvalid_sel  = pack_bvalid;  bresp_sel  = pack_bresp; bid_sel = pack_bid;
        arready_sel = pack_arready; rvalid_sel = pack_rvalid;
        rresp_sel   = pack_rresp;   rdata_sel  = pack_rdata; rid_sel = pack_rid;
      end
      S_CON: begin
        awready_sel = con_awready; wready_sel = con_wready;
        bvalid_sel  = con_bvalid;  bresp_sel  = con_bresp; bid_sel = con_bid;
        arready_sel = con_arready; rvalid_sel = con_rvalid;
        rresp_sel   = con_rresp;   rdata_sel  = con_rdata; rid_sel = con_rid;
      end
      S_DBG: begin
        awready_sel = dbg_awready; wready_sel = dbg_wready;
        bvalid_sel  = dbg_bvalid;  bresp_sel  = dbg_bresp; bid_sel = dbg_bid;
        arready_sel = dbg_arready; rvalid_sel = dbg_rvalid;
        rresp_sel   = dbg_rresp;   rdata_sel  = dbg_rdata; rid_sel = dbg_rid;
      end
      default: begin
        awready_sel = dflt_awready; wready_sel = dflt_wready;
        bvalid_sel  = dflt_bvalid;  bresp_sel  = dflt_bresp; bid_sel = dflt_bid;
        arready_sel = dflt_arready; rvalid_sel = dflt_rvalid;
        rresp_sel   = dflt_rresp;   rdata_sel  = dflt_rdata; rid_sel = dflt_rid;
      end
    endcase
  end

  // The valid lines, driven only at the slave the held selection names.  Every
  // other slave sees nothing at all, which is what makes this a demultiplexer
  // and not four slaves listening to one master.
  logic aw_v, w_v, ar_v, b_r, r_r;

  assign aw_v = (st == W_ADDR_DATA) && !aw_done;
  assign w_v  = (st == W_ADDR_DATA) && !w_done;
  assign ar_v = (st == R_ADDR);
  assign b_r  = (st == W_RESP);
  assign r_r  = (st == R_DATA);

  assign pack_awvalid = aw_v && (sel == S_PACK);
  assign con_awvalid  = aw_v && (sel == S_CON);
  assign dbg_awvalid  = aw_v && (sel == S_DBG);
  assign dflt_awvalid = aw_v && (sel == S_DFLT);

  assign pack_wvalid = w_v && (sel == S_PACK);
  assign con_wvalid  = w_v && (sel == S_CON);
  assign dbg_wvalid  = w_v && (sel == S_DBG);
  assign dflt_wvalid = w_v && (sel == S_DFLT);

  assign pack_arvalid = ar_v && (sel == S_PACK);
  assign con_arvalid  = ar_v && (sel == S_CON);
  assign dbg_arvalid  = ar_v && (sel == S_DBG);
  assign dflt_arvalid = ar_v && (sel == S_DFLT);

  assign pack_bready = b_r && (sel == S_PACK);
  assign con_bready  = b_r && (sel == S_CON);
  assign dbg_bready  = b_r && (sel == S_DBG);
  assign dflt_bready = b_r && (sel == S_DFLT);

  assign pack_rready = r_r && (sel == S_PACK);
  assign con_rready  = r_r && (sel == S_CON);
  assign dbg_rready  = r_r && (sel == S_DBG);
  assign dflt_rready = r_r && (sel == S_DFLT);

  // The address, the data and the identifier are broadcast; only the valid
  // lines above choose who is being spoken to.  A slave that looked at an
  // address while its own VALID was low would not be an AXI slave.
  assign pack_awaddr = a_hold;  assign con_awaddr = a_hold;  assign dbg_awaddr = a_hold;
  assign pack_araddr = a_hold;  assign con_araddr = a_hold;  assign dbg_araddr = a_hold;
  assign pack_wdata  = d_hold;  assign con_wdata  = d_hold;  assign dbg_wdata  = d_hold;
  assign pack_wstrb  = be_hold; assign con_wstrb  = be_hold; assign dbg_wstrb  = be_hold;

  // Single beat, always.  See the header.
  assign pack_awlen = 4'd0; assign con_awlen = 4'd0; assign dbg_awlen = 4'd0;
  assign pack_arlen = 4'd0; assign con_arlen = 4'd0; assign dbg_arlen = 4'd0;
  assign dflt_arlen = 4'd0;
  assign pack_wlast = 1'b1; assign con_wlast = 1'b1; assign dbg_wlast = 1'b1;
  assign dflt_wlast = 1'b1;

  assign pack_awid = id; assign con_awid = id; assign dbg_awid = id; assign dflt_awid = id;
  assign pack_arid = id; assign con_arid = id; assign dbg_arid = id; assign dflt_arid = id;

  assign gnt = (st == IDLE) && req;

  always_ff @(posedge clk) begin
    if (rst) begin
      st      <= IDLE;
      sel     <= S_DFLT;
      a_hold  <= 32'd0;
      d_hold  <= 32'd0;
      be_hold <= 4'd0;
      id      <= 12'd0;
      aw_done <= 1'b0;
      w_done  <= 1'b0;
      done    <= 1'b0;
      rdata   <= 32'd0;
      err     <= 1'b0;
    end else begin
      done <= 1'b0;
      case (st)
        IDLE: begin
          if (req) begin
            sel     <= target(addr[31:12]);
            a_hold  <= addr;
            d_hold  <= wdata;
            be_hold <= be;
            aw_done <= 1'b0;
            w_done  <= 1'b0;
            st      <= we ? W_ADDR_DATA : R_ADDR;
          end
        end

        W_ADDR_DATA: begin
          // The two channels are independent and a slave may take them in
          // either order or together; each is held until it is taken.
          if (aw_v && awready_sel) aw_done <= 1'b1;
          if (w_v  && wready_sel)  w_done  <= 1'b1;
          if ((aw_done || (aw_v && awready_sel)) &&
              (w_done  || (w_v  && wready_sel))) st <= W_RESP;
        end

        W_RESP: begin
          if (bvalid_sel) begin
            // **THE WRITE IS NOT DONE UNTIL THE RESPONSE IS HERE**, which is
            // the whole reason this state exists.  A bridge that answered the
            // core at the address handshake would let a store to the
            // console's reset word return while the machine was still in
            // reset, and the very next read of FLAG-1 would mean nothing ---
            // which is exactly what `cadr_console.sv` holds BVALID off for.
            done  <= 1'b1;
            err   <= (bresp_sel != 2'b00) || (bid_sel != id);
            rdata <= 32'd0;
            id    <= id + 12'd1;
            st    <= IDLE;
          end
        end

        R_ADDR: begin
          if (arready_sel) st <= R_DATA;
        end

        R_DATA: begin
          if (rvalid_sel) begin
            done  <= 1'b1;
            rdata <= rdata_sel;
            err   <= (rresp_sel != 2'b00) || (rid_sel != id);
            id    <= id + 12'd1;
            st    <= IDLE;
          end
        end

        default: st <= IDLE;
      endcase
    end
  end

  // The four `RLAST` lines say nothing a single-beat master has to look at ---
  // every transaction here is one beat, so the last beat is the only beat.
  // They are read here so that the port list matches the faces rather than
  // the use, which is the rule the boards' own tie-off blocks keep.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = &{1'b0, pack_rlast, con_rlast, dbg_rlast, dflt_rlast};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
