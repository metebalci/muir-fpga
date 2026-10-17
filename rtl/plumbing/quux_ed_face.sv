// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX revision 16's Ethernet device as Linux reaches it (QUUX's Ethernet
// contract, §2): one 4 KB page of the processor-to-fabric port the other
// faces share, `cadr_gp0_split.sv`'s sixth, at the pack side's base +
// `0x5000`.  Linux's `quux-ethernet-device` is its user, and its
// `src/qed_face_fabric.c` is the one file of it that knows this layout;
// `docs/ethernet-device.md` is its manual.
//
//     0x000  IDENT, read only: "QE16", 0x5145_3136
//     0x004  MEM_WORDS, read only: main memory's words
//     0x100  STATE, read only: <0> enabled, <1> the interrupt enable, <2>
//            busy, <3> quiet, <31:16> EPOCH
//     0x104  CLAIM: written {EPOCH, <0> 1} to hold quiet low, <0> 0 to let
//            it go; read <0> busy
//     0x108  242 <27:0>; 0x10C 243
//     0x110  246 <27:0>; 0x114 247
//     0x118  244, once the machine's writes before it are answered
//     0x11C  TX_CONS: read 245; written {EPOCH, index}, 245 moved
//     0x120  250, as 0x118
//     0x124  RX_CONS: read 251; written {EPOCH, index}, the cache made
//            coherent and 251 moved
//     0x128  252
//     0x12C  COUNTS: 241's four counters in their places; written, all four
//     0x130  253, 0x134 254, 0x138 255, 0x13C 256, 0x140 257: the host's
//
// Every other word reads 0 and takes no write.  **WORDS ONLY**, as the file
// device's face: a write of fewer than four bytes goes nowhere.
//
// **THIS MODULE IS A MAP AND NOTHING ELSE**, as `quux_fd_face.sv` is: the
// registers and their rules are `rtl/machine/quux16_ethernet.sv`'s, inside
// the machine, which this face reaches through the machine's Ethernet host
// side by index (0x100 + 4k is index k, 0x004 index 17).  The AXI protocol
// is `cadr_gp_regs.sv`'s, which reads two ticks after the address settles;
// the host side answers a tick after its index, so the word is there.  A
// write is handed on a tick after the port takes it, registered, so that
// nothing of the machine's side hangs off the processing system's pins.
//
// **REVISION 16's ALONE.**  A CADR build and an older revision's leave this
// page to the default (`cadr_gp0_split.sv`'s `HAS_ED`), which reads "NONE",
// and this module is not built there.
//
// What holds it: `build/quux16_ethernet_module.quux.pass`, this face with the
// register page's devices behind it, driven by `quux-ethernet-device`'s own
// `qed_face_fabric.c` over AXI, muir's device's moves played through it, and
// every rule of the host's side held against what the processor then reads.

`default_nettype none

module quux_ed_face #(
    parameter logic [31:0] IDENT = 32'h5145_3136,
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

    // The machine's Ethernet host side (`quux15_core.sv`'s `eth_*`).
    output var logic        host_we,
    output var logic [4:0]  host_widx,
    output var logic [31:0] host_wdata,
    output var logic [4:0]  host_ridx,
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

  // A word's index on the host side, if it has one: 0x004 MEM_WORDS, 0x100
  // to 0x140 the device's.
  function automatic logic [5:0] index_of(input logic [9:0] word);
    if (word == 10'h001) return 6'h31;
    if (word >= 10'h040 && word <= 10'h050) return 6'h20 | 6'(word - 10'h040);
    return 6'h00;
  endfunction

  logic [5:0] w_idx, r_idx;
  assign w_idx = index_of(w_word);
  assign r_idx = index_of(r_word);

  // **A WRITE REACHES THE MACHINE A TICK AFTER THE PORT HANDS IT OVER**, as
  // the file device's face has it.
  always_ff @(posedge clk) begin
    if (rst) begin
      host_we <= 1'b0;
    end else begin
      host_we <= wr && w_idx[5] && wr_mask == 32'hFFFF_FFFF;
    end
    host_widx  <= w_idx[4:0];
    host_wdata <= wr_data;
  end
  assign host_ridx = r_idx[4:0];

  // The word's kind a tick behind the index, beside the host's answer.
  logic r_ident, r_host;
  always_ff @(posedge clk) begin
    r_ident <= r_word == 10'd0;
    r_host  <= r_idx[5];
  end
  assign rd_data = r_ident ? IDENT : r_host ? host_rdata : 32'd0;

  // Nothing here consumes on a read.
  logic unused;
  assign unused = rd;

endmodule

`default_nettype wire
