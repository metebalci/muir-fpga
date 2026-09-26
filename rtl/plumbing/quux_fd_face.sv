// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's real-time clock and file device as Linux reaches them (revision 9,
// contract Q9): one 4 KB page of the processor-to-fabric port the other
// faces share, `cadr_gp0_split.sv`'s fifth, at `0x4000_4000`.  Linux's server
// `quux-file-device` and the init script that sets the clock are its users;
// `docs/file-device.md` is their manual.
//
//     0x000  IDENT, read only: "QFD9", 0x5146_4439
//     0x010  RTC_SECONDS: read, what word 103 reads now; written, the seconds,
//            from the fraction staged at 0x014 (0 if none), at once
//     0x014  RTC_FRACTION: read, nanoseconds into the second; written, the
//            fraction the next write of 0x010 starts from
//     0x100  STATE, read only: <0> enabled, <1> the interrupt enable, <2>
//            busy, <3> quiet, <4> work waiting, <5> the last completion
//            refused, <31:16> EPOCH
//     0x104  CLAIM: written {EPOCH, <0> 1} to hold quiet low, <0> 0 to let
//            it go; read <0> busy
//     0x108  the command ring's base, 162; 0x10C its size, 163
//     0x110  the response ring's base, 166; 0x114 its size, 167
//     0x118  the command producer, 164, once the machine's writes before it
//            are in main memory
//     0x11C  RESP_PROD: read 165 and 170; written {EPOCH, index}, the
//            commands up to the index complete
//     0x120  171
//     0x124  HANDLES: written {EPOCH, count}, landing with the next
//            completion; read, the count the machine sees
//     0x128  MEM_WORDS, read only: main memory's words
//
// Every other word reads 0 and takes no write.  **WORDS ONLY**: a write of
// fewer than four bytes goes nowhere, since every register here is a word
// whose halves mean nothing apart and a byte merged into one of them would
// write a value nobody chose.
//
// **THIS MODULE IS A MAP AND NOTHING ELSE.**  The registers, their rules and
// both orderings with the machine's memory are `rtl/machine/quux_file_device.sv`
// and `rtl/machine/quux_rtc.sv`, inside the machine, which this face reaches
// through the machine's host side by index (0x010 is index 0, 0x014 index 1,
// 0x100 + 4k index k + 2).  The AXI protocol is `cadr_gp_regs.sv`'s, which
// reads two ticks after the address settles; the machine's host side answers
// a tick after its index, so the word is there.  A write is handed on a tick
// after the port takes it, registered, so that nothing of the machine's side
// hangs off the processing system's pins.
//
// **NOT ON THE CADR.**  A CADR build has no revision 9: its split leaves
// this page to the default (`cadr_gp0_split.sv`'s `HAS_FD`), and this module
// is not built there.
//
// What holds it: `build/quux_fd_face.pass`, this face with the machine's
// register page behind it, driven over AXI in the order Linux's server
// drives it and on the machine's side as the processor does, every rule of
// the host's side checked against what the processor then reads.

`default_nettype none

module quux_fd_face #(
    // "QFD9": QUUX's file device, revision 9.
    parameter logic [31:0] IDENT = 32'h5146_4439,
    parameter int unsigned ID_W  = 12,
    parameter int unsigned LEN_W = 4
) (
    input  var logic        clk,
    // The port's reset, which resets the AXI state and nothing of the
    // machine's (`docs/board.md`).
    input  var logic        rst,

    input  var logic [11:0] s_awaddr,
    input  var logic [LEN_W-1:0] s_awlen,
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
    input  var logic [11:0] s_araddr,
    input  var logic [LEN_W-1:0] s_arlen,
    input  var logic [ID_W-1:0] s_arid,
    input  var logic        s_arvalid,
    output var logic        s_arready,
    output var logic [31:0] s_rdata,
    output var logic [1:0]  s_rresp,
    output var logic [ID_W-1:0] s_rid,
    output var logic        s_rlast,
    output var logic        s_rvalid,
    input  var logic        s_rready,

    // The machine's host side (`cadr_machine.sv`'s `host_*`).
    output var logic        host_we,
    output var logic [3:0]  host_widx,
    output var logic [31:0] host_wdata,
    output var logic [3:0]  host_ridx,
    input  var logic [31:0] host_rdata
);

  logic [9:0]  w_word, r_word;
  logic        wr, rd;
  logic [31:0] wr_data, wr_mask, rd_data;

  cadr_gp_regs #(.ID_W(ID_W), .LEN_W(LEN_W)) u_regs (
      .clk(clk), .rst(rst),
      .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awid(s_awid),
      .s_awvalid(s_awvalid), .s_awready(s_awready),
      .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
      .s_wvalid(s_wvalid), .s_wready(s_wready),
      .s_bresp(s_bresp), .s_bid(s_bid), .s_bvalid(s_bvalid), .s_bready(s_bready),
      .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arid(s_arid),
      .s_arvalid(s_arvalid), .s_arready(s_arready),
      .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rid(s_rid),
      .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
      .w_word(w_word), .wr(wr), .wr_data(wr_data), .wr_mask(wr_mask),
      .r_word(r_word), .rd(rd), .rd_data(rd_data)
  );

  // A word's index on the host side, if it has one: 0x010 and 0x014 the
  // clock's, 0x100 to 0x128 the file device's.
  function automatic logic [4:0] index_of(input logic [9:0] word);
    if (word == 10'h004) return 5'h10;
    if (word == 10'h005) return 5'h11;
    if (word >= 10'h040 && word <= 10'h04A) return 5'h10 | 5'(word - 10'h040 + 10'd2);
    return 5'h00;
  endfunction

  logic [4:0] w_idx, r_idx;
  assign w_idx = index_of(w_word);
  assign r_idx = index_of(r_word);

  // **A WRITE REACHES THE MACHINE A TICK AFTER THE PORT HANDS IT OVER**:
  // the word comes straight off the processing system's pins, which are
  // most of a tick away already, and the machine's side compares it with
  // its indexes and drops its cache on it.  Registered here, every path
  // from the pins ends at a register one level in.
  always_ff @(posedge clk) begin
    if (rst) begin
      host_we <= 1'b0;
    end else begin
      host_we <= wr && w_idx[4] && wr_mask == 32'hFFFF_FFFF;
    end
    host_widx  <= w_idx[3:0];
    host_wdata <= wr_data;
  end
  assign host_ridx  = r_idx[3:0];

  // The word's kind a tick behind the index, beside the host's answer.
  logic r_ident, r_host;
  always_ff @(posedge clk) begin
    r_ident <= r_word == 10'd0;
    r_host  <= r_idx[4];
  end
  assign rd_data = r_ident ? IDENT : r_host ? host_rdata : 32'd0;

  // Nothing here consumes on a read.
  logic unused;
  assign unused = rd;

endmodule

`default_nettype wire
