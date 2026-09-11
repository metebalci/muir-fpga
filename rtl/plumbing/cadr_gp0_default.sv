// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The default slave on `M_AXI_GP0`: an answer for every address on a board
// that brings the port out and has nothing else on it.
//
// **A READ NOTHING ANSWERS ON GP0 DOES NOT FAULT THE ARM; IT HANGS IT.**
// Measured on the board: the pack feeder read the pack side's IDENT register
// at 0x4000_0000 on a bitstream without the pack side, nothing in the fabric
// drove ARREADY, and BOTH Arm cores froze at one PC each.  No software guard
// can catch a load that never completes, so the fabric that owns the port
// must complete every transaction on it.  `rtl/plumbing/cadr_disk_pack.sv` does, in
// its window and out of it; this is for the boards that have GP0 and not
// that module --- `boards/arty-z7-20/cadr_arty.sv`'s two proving boards --- so that a
// program reading the register face on the wrong bitstream gets an answer
// and not a frozen processor.
//
// WHAT IT ANSWERS.  Every read completes with OKAY and `WORD` in every beat
// --- "NONE", so that the pack feeder's own check, IDENT reading "PACK",
// says "something answers and it is not this face" --- and every write
// completes with OKAY and is dropped.  OKAY and not DECERR or SLVERR on
// purpose: an error response to a Cortex-A9's write is a posted write's
// error, which arrives as an imprecise external abort that the kernel cannot
// attribute to a process, and a constant a program can recognise is the
// safer failure.  A read's response could be an error and be attributed,
// but one rule for both halves is one rule.
//
// THE PROTOCOL, WHICH IS ALL THIS IS HELD TO.  AXI3, one write and one read
// in flight at once, the two halves independent as the interconnect will
// drive them.  A write is the address, then data beats until WLAST, then one
// response carrying the address's ID; a read is the address, then ARLEN+1
// beats carrying the ID with RLAST on the last and on no other.  AWLEN is
// not read: the data channel says where a write ends.  `tb/cadr_gp0_default
// _tb.cpp` drives both halves with lengths and delays that vary and counts
// every handshake, so a beat too many or too few, a response without a
// request or RLAST on the wrong beat is a failure and not a stall.
//
// WHAT THIS CANNOT DO.  A board without a `PS7` in it --- `cadr_arty.sv`'s
// default, `DDR=0` --- has no GP0 to answer on, and a program that touches
// the window there hangs the processor whatever the fabric does.  The EMIO
// tally is readable without GP0 and reads all ones on that board, which is
// the one guard a program has before its first GP0 read.

`default_nettype none

module cadr_gp0_default #(
    parameter logic [31:0] WORD = 32'h4E4F_4E45   // "NONE"
) (
    input  var logic        clk,
    input  var logic        rst,

    input  var logic        s_awvalid,
    input  var logic [11:0] s_awid,
    output var logic        s_awready,
    input  var logic        s_wlast,
    input  var logic        s_wvalid,
    output var logic        s_wready,
    output var logic [1:0]  s_bresp,
    output var logic [11:0] s_bid,
    output var logic        s_bvalid,
    input  var logic        s_bready,
    input  var logic [3:0]  s_arlen,
    input  var logic [11:0] s_arid,
    input  var logic        s_arvalid,
    output var logic        s_arready,
    output var logic [31:0] s_rdata,
    output var logic [1:0]  s_rresp,
    output var logic [11:0] s_rid,
    output var logic        s_rlast,
    output var logic        s_rvalid,
    input  var logic        s_rready
);

  typedef enum logic [1:0] { W_ADDR, W_DATA, W_RESP } wstate_e;
  typedef enum logic [0:0] { R_ADDR, R_DATA } rstate_e;
  wstate_e wst;
  rstate_e rst_r;
  logic [11:0] w_id, r_id;
  logic [3:0]  r_left;   // beats still owed on the read

  assign s_awready = (wst == W_ADDR);
  assign s_wready  = (wst == W_DATA);
  assign s_bvalid  = (wst == W_RESP);
  assign s_bresp   = 2'b00;
  assign s_bid     = w_id;

  assign s_arready = (rst_r == R_ADDR);
  assign s_rvalid  = (rst_r == R_DATA);
  assign s_rdata   = WORD;
  assign s_rresp   = 2'b00;
  assign s_rid     = r_id;
  assign s_rlast   = (r_left == 4'd0);

  always_ff @(posedge clk) begin
    if (rst) begin
      wst    <= W_ADDR;
      rst_r  <= R_ADDR;
      w_id   <= 12'd0;
      r_id   <= 12'd0;
      r_left <= 4'd0;
    end else begin
      unique case (wst)
        W_ADDR: if (s_awvalid) begin
          w_id <= s_awid;
          wst  <= W_DATA;
        end
        W_DATA: if (s_wvalid && s_wlast) wst <= W_RESP;
        W_RESP: if (s_bready) wst <= W_ADDR;
        default: wst <= W_ADDR;
      endcase
      unique case (rst_r)
        R_ADDR: if (s_arvalid) begin
          r_id   <= s_arid;
          r_left <= s_arlen;
          rst_r  <= R_DATA;
        end
        R_DATA: if (s_rready) begin
          if (r_left == 4'd0) rst_r <= R_ADDR;
          else r_left <= r_left - 4'd1;
        end
        default: rst_r <= R_ADDR;
      endcase
    end
  end

endmodule

`default_nettype wire
