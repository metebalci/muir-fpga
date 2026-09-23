// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `cadr_de25_hps` for a simulation: the Agilex 5's processor as far as the
// fabric sees it.  The two processor-to-fabric bridges are driven by the
// processor and the FPGA-to-SDRAM bridge is answered by memory, with the
// behavior of both in `tb/cadr_board_reset_tb.cpp` through
// `tb/cadr_sim_axi.sv`; the processor's reset, `h2f_gp_out` and the
// warm-reset request are levels the C++ sets.  The port list is
// `tb/cadr_de25_stubs.sv`'s, which is the one Platform Designer writes, and
// that stub steps aside when `CADR_DE25_HPS_SIM` is defined.

`default_nettype none

// A model's ports are the hard block's, and it reads what it needs of them.
/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */

module cadr_de25_hps (
    output var logic [0:0] emif_mem_0_mem_cs,
    output var logic [5:0] emif_mem_0_mem_ca,
    output var logic [0:0] emif_mem_0_mem_cke,
    inout  wire  logic [31:0] emif_mem_0_mem_dq,
    inout  wire  logic [3:0] emif_mem_0_mem_dqs_t,
    inout  wire  logic [3:0] emif_mem_0_mem_dqs_c,
    inout  wire  logic [3:0] emif_mem_0_mem_dmi,
    output var logic [0:0] emif_mem_ck_0_mem_ck_t,
    output var logic [0:0] emif_mem_ck_0_mem_ck_c,
    output var logic emif_mem_reset_n_mem_reset_n,
    input  var logic emif_oct_0_oct_rzqin,
    input  var logic emif_ref_clk_clk,
    output var logic hps_h2f_reset_reset,
    input  var logic [31:0] hps_hps_gp_gp_in,
    output var logic [31:0] hps_hps_gp_gp_out,
    input  var logic hps_hps2fpga_axi_clock_clk,
    input  var logic hps_hps2fpga_axi_reset_reset,
    output var logic [3:0] hps_hps2fpga_awid,
    output var logic [29:0] hps_hps2fpga_awaddr,
    output var logic [7:0] hps_hps2fpga_awlen,
    output var logic [2:0] hps_hps2fpga_awsize,
    output var logic [1:0] hps_hps2fpga_awburst,
    output var logic hps_hps2fpga_awlock,
    output var logic [3:0] hps_hps2fpga_awcache,
    output var logic [2:0] hps_hps2fpga_awprot,
    output var logic hps_hps2fpga_awvalid,
    input  var logic hps_hps2fpga_awready,
    output var logic [31:0] hps_hps2fpga_wdata,
    output var logic [3:0] hps_hps2fpga_wstrb,
    output var logic hps_hps2fpga_wlast,
    output var logic hps_hps2fpga_wvalid,
    input  var logic hps_hps2fpga_wready,
    input  var logic [3:0] hps_hps2fpga_bid,
    input  var logic [1:0] hps_hps2fpga_bresp,
    input  var logic hps_hps2fpga_bvalid,
    output var logic hps_hps2fpga_bready,
    output var logic [3:0] hps_hps2fpga_arid,
    output var logic [29:0] hps_hps2fpga_araddr,
    output var logic [7:0] hps_hps2fpga_arlen,
    output var logic [2:0] hps_hps2fpga_arsize,
    output var logic [1:0] hps_hps2fpga_arburst,
    output var logic hps_hps2fpga_arlock,
    output var logic [3:0] hps_hps2fpga_arcache,
    output var logic [2:0] hps_hps2fpga_arprot,
    output var logic hps_hps2fpga_arvalid,
    input  var logic hps_hps2fpga_arready,
    input  var logic [3:0] hps_hps2fpga_rid,
    input  var logic [31:0] hps_hps2fpga_rdata,
    input  var logic [1:0] hps_hps2fpga_rresp,
    input  var logic hps_hps2fpga_rlast,
    input  var logic hps_hps2fpga_rvalid,
    output var logic hps_hps2fpga_rready,
    input  var logic hps_lwhps2fpga_axi_clock_clk,
    input  var logic hps_lwhps2fpga_axi_reset_reset,
    output var logic [3:0] hps_lwhps2fpga_awid,
    output var logic [28:0] hps_lwhps2fpga_awaddr,
    output var logic [7:0] hps_lwhps2fpga_awlen,
    output var logic [2:0] hps_lwhps2fpga_awsize,
    output var logic [1:0] hps_lwhps2fpga_awburst,
    output var logic hps_lwhps2fpga_awlock,
    output var logic [3:0] hps_lwhps2fpga_awcache,
    output var logic [2:0] hps_lwhps2fpga_awprot,
    output var logic hps_lwhps2fpga_awvalid,
    input  var logic hps_lwhps2fpga_awready,
    output var logic [31:0] hps_lwhps2fpga_wdata,
    output var logic [3:0] hps_lwhps2fpga_wstrb,
    output var logic hps_lwhps2fpga_wlast,
    output var logic hps_lwhps2fpga_wvalid,
    input  var logic hps_lwhps2fpga_wready,
    input  var logic [3:0] hps_lwhps2fpga_bid,
    input  var logic [1:0] hps_lwhps2fpga_bresp,
    input  var logic hps_lwhps2fpga_bvalid,
    output var logic hps_lwhps2fpga_bready,
    output var logic [3:0] hps_lwhps2fpga_arid,
    output var logic [28:0] hps_lwhps2fpga_araddr,
    output var logic [7:0] hps_lwhps2fpga_arlen,
    output var logic [2:0] hps_lwhps2fpga_arsize,
    output var logic [1:0] hps_lwhps2fpga_arburst,
    output var logic hps_lwhps2fpga_arlock,
    output var logic [3:0] hps_lwhps2fpga_arcache,
    output var logic [2:0] hps_lwhps2fpga_arprot,
    output var logic hps_lwhps2fpga_arvalid,
    input  var logic hps_lwhps2fpga_arready,
    input  var logic [3:0] hps_lwhps2fpga_rid,
    input  var logic [31:0] hps_lwhps2fpga_rdata,
    input  var logic [1:0] hps_lwhps2fpga_rresp,
    input  var logic hps_lwhps2fpga_rlast,
    input  var logic hps_lwhps2fpga_rvalid,
    output var logic hps_lwhps2fpga_rready,
    output var logic hps_h2f_warm_reset_handshake_reset_req,
    input  var logic hps_h2f_warm_reset_handshake_reset_ack,
    input  var logic hps_hps_io_hps_osc_clk,
    inout  wire  logic hps_hps_io_sdmmc_data0,
    inout  wire  logic hps_hps_io_sdmmc_data1,
    output var logic hps_hps_io_sdmmc_cclk,
    inout  wire  logic hps_hps_io_sdmmc_data2,
    inout  wire  logic hps_hps_io_sdmmc_data3,
    inout  wire  logic hps_hps_io_sdmmc_cmd,
    input  var logic hps_hps_io_usb0_clk,
    output var logic hps_hps_io_usb0_stp,
    input  var logic hps_hps_io_usb0_dir,
    inout  wire  logic hps_hps_io_usb0_data0,
    inout  wire  logic hps_hps_io_usb0_data1,
    input  var logic hps_hps_io_usb0_nxt,
    inout  wire  logic hps_hps_io_usb0_data2,
    inout  wire  logic hps_hps_io_usb0_data3,
    inout  wire  logic hps_hps_io_usb0_data4,
    inout  wire  logic hps_hps_io_usb0_data5,
    inout  wire  logic hps_hps_io_usb0_data6,
    inout  wire  logic hps_hps_io_usb0_data7,
    output var logic hps_hps_io_emac0_tx_clk,
    output var logic hps_hps_io_emac0_tx_ctl,
    input  var logic hps_hps_io_emac0_rx_clk,
    input  var logic hps_hps_io_emac0_rx_ctl,
    output var logic hps_hps_io_emac0_txd0,
    output var logic hps_hps_io_emac0_txd1,
    input  var logic hps_hps_io_emac0_rxd0,
    input  var logic hps_hps_io_emac0_rxd1,
    output var logic hps_hps_io_emac0_txd2,
    output var logic hps_hps_io_emac0_txd3,
    input  var logic hps_hps_io_emac0_rxd2,
    input  var logic hps_hps_io_emac0_rxd3,
    inout  wire  logic hps_hps_io_mdio0_mdio,
    output var logic hps_hps_io_mdio0_mdc,
    output var logic hps_hps_io_uart1_tx,
    input  var logic hps_hps_io_uart1_rx,
    inout  wire  logic hps_hps_io_i2c1_sda,
    inout  wire  logic hps_hps_io_i2c1_scl,
    inout  wire  logic hps_hps_io_gpio28,
    inout  wire  logic hps_hps_io_gpio40,
    inout  wire  logic hps_hps_io_gpio41,
    input  var logic hps_f2sdram_axi_clock_clk,
    input  var logic hps_f2sdram_axi_reset_reset,
    input  var logic [31:0] hps_f2sdram_araddr,
    input  var logic [1:0] hps_f2sdram_arburst,
    input  var logic [3:0] hps_f2sdram_arcache,
    input  var logic [4:0] hps_f2sdram_arid,
    input  var logic [7:0] hps_f2sdram_arlen,
    input  var logic hps_f2sdram_arlock,
    input  var logic [2:0] hps_f2sdram_arprot,
    input  var logic [3:0] hps_f2sdram_arqos,
    output var logic hps_f2sdram_arready,
    input  var logic [2:0] hps_f2sdram_arsize,
    input  var logic hps_f2sdram_arvalid,
    input  var logic [31:0] hps_f2sdram_awaddr,
    input  var logic [1:0] hps_f2sdram_awburst,
    input  var logic [3:0] hps_f2sdram_awcache,
    input  var logic [4:0] hps_f2sdram_awid,
    input  var logic [7:0] hps_f2sdram_awlen,
    input  var logic hps_f2sdram_awlock,
    input  var logic [2:0] hps_f2sdram_awprot,
    input  var logic [3:0] hps_f2sdram_awqos,
    output var logic hps_f2sdram_awready,
    input  var logic [2:0] hps_f2sdram_awsize,
    input  var logic hps_f2sdram_awvalid,
    output var logic [4:0] hps_f2sdram_bid,
    input  var logic hps_f2sdram_bready,
    output var logic [1:0] hps_f2sdram_bresp,
    output var logic hps_f2sdram_bvalid,
    output var logic [63:0] hps_f2sdram_rdata,
    output var logic [4:0] hps_f2sdram_rid,
    output var logic hps_f2sdram_rlast,
    input  var logic hps_f2sdram_rready,
    output var logic [1:0] hps_f2sdram_rresp,
    output var logic hps_f2sdram_rvalid,
    input  var logic [63:0] hps_f2sdram_wdata,
    input  var logic hps_f2sdram_wlast,
    output var logic hps_f2sdram_wready,
    input  var logic [7:0] hps_f2sdram_wstrb,
    input  var logic hps_f2sdram_wvalid,
    input  var logic [7:0] hps_f2sdram_aruser,
    input  var logic [7:0] hps_f2sdram_awuser,
    input  var logic [7:0] hps_f2sdram_wuser,
    output var logic [7:0] hps_f2sdram_buser,
    input  var logic [3:0] hps_f2sdram_arregion,
    output var logic [7:0] hps_f2sdram_ruser,
    input  var logic [3:0] hps_f2sdram_awregion
);

  /* verilator lint_off UNUSEDSIGNAL */
  import cadr_sim_axi_dpi::*;

  // The levels the processor drives, off the C++: 1 its reset, high while
  // it is in reset, which resets all three bridges; 2 `h2f_gp_out`; 3 the
  // warm-reset handshake's request, low when asserted.
  logic        h2f_reset_q, req_n_q;
  logic [31:0] gp_out_q;
  always_ff @(posedge hps_hps2fpga_axi_clock_clk) begin
    h2f_reset_q <= cadr_sim_level(1) != 0;
    gp_out_q    <= cadr_sim_level(2);
    req_n_q     <= cadr_sim_level(3) != 0;
  end
  assign hps_h2f_reset_reset = h2f_reset_q;
  assign hps_hps_gp_gp_out   = gp_out_q;
  assign hps_h2f_warm_reset_handshake_reset_req = req_n_q;

  // The two processor-to-fabric bridges, AXI4 with four bits of ID and eight
  // of length: ports 0 and 1, as the Zynq's two general-purpose ports are.
  cadr_sim_gp_master #(.PORT(0), .AW(30), .ID_W(4), .LEN_W(8)) u_h2f (
      .clk(hps_hps2fpga_axi_clock_clk),
      .awaddr(hps_hps2fpga_awaddr), .awlen(hps_hps2fpga_awlen), .awid(hps_hps2fpga_awid),
      .awvalid(hps_hps2fpga_awvalid), .awready(hps_hps2fpga_awready),
      .wdata(hps_hps2fpga_wdata), .wstrb(hps_hps2fpga_wstrb), .wlast(hps_hps2fpga_wlast),
      .wvalid(hps_hps2fpga_wvalid), .wready(hps_hps2fpga_wready),
      .bresp(hps_hps2fpga_bresp), .bid(hps_hps2fpga_bid), .bvalid(hps_hps2fpga_bvalid),
      .bready(hps_hps2fpga_bready),
      .araddr(hps_hps2fpga_araddr), .arlen(hps_hps2fpga_arlen), .arid(hps_hps2fpga_arid),
      .arvalid(hps_hps2fpga_arvalid), .arready(hps_hps2fpga_arready),
      .rdata(hps_hps2fpga_rdata), .rresp(hps_hps2fpga_rresp), .rid(hps_hps2fpga_rid),
      .rlast(hps_hps2fpga_rlast), .rvalid(hps_hps2fpga_rvalid), .rready(hps_hps2fpga_rready));
  cadr_sim_gp_master #(.PORT(1), .AW(29), .ID_W(4), .LEN_W(8)) u_lw (
      .clk(hps_lwhps2fpga_axi_clock_clk),
      .awaddr(hps_lwhps2fpga_awaddr), .awlen(hps_lwhps2fpga_awlen), .awid(hps_lwhps2fpga_awid),
      .awvalid(hps_lwhps2fpga_awvalid), .awready(hps_lwhps2fpga_awready),
      .wdata(hps_lwhps2fpga_wdata), .wstrb(hps_lwhps2fpga_wstrb), .wlast(hps_lwhps2fpga_wlast),
      .wvalid(hps_lwhps2fpga_wvalid), .wready(hps_lwhps2fpga_wready),
      .bresp(hps_lwhps2fpga_bresp), .bid(hps_lwhps2fpga_bid), .bvalid(hps_lwhps2fpga_bvalid),
      .bready(hps_lwhps2fpga_bready),
      .araddr(hps_lwhps2fpga_araddr), .arlen(hps_lwhps2fpga_arlen), .arid(hps_lwhps2fpga_arid),
      .arvalid(hps_lwhps2fpga_arvalid), .arready(hps_lwhps2fpga_arready),
      .rdata(hps_lwhps2fpga_rdata), .rresp(hps_lwhps2fpga_rresp), .rid(hps_lwhps2fpga_rid),
      .rlast(hps_lwhps2fpga_rlast), .rvalid(hps_lwhps2fpga_rvalid), .rready(hps_lwhps2fpga_rready));
  assign {hps_hps2fpga_awsize, hps_hps2fpga_awburst, hps_hps2fpga_awlock,
          hps_hps2fpga_awcache, hps_hps2fpga_awprot} = {3'd2, 2'd1, 1'b0, 4'd0, 3'd0};
  assign {hps_hps2fpga_arsize, hps_hps2fpga_arburst, hps_hps2fpga_arlock,
          hps_hps2fpga_arcache, hps_hps2fpga_arprot} = {3'd2, 2'd1, 1'b0, 4'd0, 3'd0};
  assign {hps_lwhps2fpga_awsize, hps_lwhps2fpga_awburst, hps_lwhps2fpga_awlock,
          hps_lwhps2fpga_awcache, hps_lwhps2fpga_awprot} = {3'd2, 2'd1, 1'b0, 4'd0, 3'd0};
  assign {hps_lwhps2fpga_arsize, hps_lwhps2fpga_arburst, hps_lwhps2fpga_arlock,
          hps_lwhps2fpga_arcache, hps_lwhps2fpga_arprot} = {3'd2, 2'd1, 1'b0, 4'd0, 3'd0};

  // The FPGA-to-SDRAM bridge, the fabric the master: memory slave 4, reset
  // with the processor as the real bridge is.
  cadr_sim_mem_slave #(.PORT(4), .ID_W(5), .LEN_W(8)) u_f2s (
      .clk(hps_f2sdram_axi_clock_clk), .rst(h2f_reset_q),
      .awaddr(hps_f2sdram_awaddr), .awlen(hps_f2sdram_awlen), .awid(hps_f2sdram_awid),
      .awvalid(hps_f2sdram_awvalid), .awready(hps_f2sdram_awready),
      .wdata(hps_f2sdram_wdata), .wstrb(hps_f2sdram_wstrb), .wlast(hps_f2sdram_wlast),
      .wvalid(hps_f2sdram_wvalid), .wready(hps_f2sdram_wready),
      .bresp(hps_f2sdram_bresp), .bid(hps_f2sdram_bid), .bvalid(hps_f2sdram_bvalid),
      .bready(hps_f2sdram_bready),
      .araddr(hps_f2sdram_araddr), .arlen(hps_f2sdram_arlen), .arid(hps_f2sdram_arid),
      .arvalid(hps_f2sdram_arvalid), .arready(hps_f2sdram_arready),
      .rdata(hps_f2sdram_rdata), .rresp(hps_f2sdram_rresp), .rid(hps_f2sdram_rid),
      .rlast(hps_f2sdram_rlast), .rvalid(hps_f2sdram_rvalid), .rready(hps_f2sdram_rready));
  assign hps_f2sdram_buser = 8'd0;
  assign hps_f2sdram_ruser = 8'd0;

  // Nothing of the processor's own pins is modelled.
  assign {emif_mem_0_mem_cs, emif_mem_0_mem_ca, emif_mem_0_mem_cke,
          emif_mem_ck_0_mem_ck_t, emif_mem_ck_0_mem_ck_c,
          emif_mem_reset_n_mem_reset_n} = '0;
  assign {hps_hps_io_sdmmc_cclk, hps_hps_io_usb0_stp, hps_hps_io_emac0_tx_clk,
          hps_hps_io_emac0_tx_ctl, hps_hps_io_emac0_txd0, hps_hps_io_emac0_txd1,
          hps_hps_io_emac0_txd2, hps_hps_io_emac0_txd3, hps_hps_io_mdio0_mdc,
          hps_hps_io_uart1_tx} = '0;
  /* verilator lint_on UNUSEDSIGNAL */
endmodule

`default_nettype wire
