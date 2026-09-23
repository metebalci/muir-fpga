// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// What `boards/de25-nano/cadr_de25.sv` is wired to, as shells a testbench can
// drive, so that the top level's own wiring can be SIMULATED and not only
// linted.  `tb/cadr_de25_top_tb.cpp` is the testbench and its header is the
// argument; `build/de25.pass` runs it after the four lints.
//
// **WHAT IS REPLACED, AND WHY EACH IS SAFE TO REPLACE.**
//
//   `cadr_de25_pll`, `cadr_de25_pixel_pll`
//                     pass the board's clock through, as the lint stubs do:
//                     the machine's clock and the pixel clock are then one
//                     clock, which the testbench drives.  The lock is the
//                     testbench's to take away, because losing it is one of
//                     the ways the fabric's reset rises.
//   `cadr_de25_reset_release`
//                     `nINIT_DONE` from the testbench.
//   `cadr_de25_vjtag` idle, as in the lint stubs; the probe is not built here.
//   `cadr_de25_hps`   the processor system as a SHELL: every output a
//                     register the testbench writes and every input a copy it
//                     reads.  The testbench is the processor: it raises and
//                     lowers `h2f_reset`, writes `h2f_gp_out`, asks for quiet,
//                     answers the FPGA-to-SDRAM bridge as its memory, and is
//                     the master on the lightweight bridge that software
//                     would be.
//   `cadr_machine`    **A SHELL TOO, AND ON PURPOSE.**  What this check holds
//                     is the top level's wiring: which line reaches which
//                     port, which way up, on which edge.  The machine is held
//                     to muir by checks of its own, and a real one here would
//                     make every wire it drives depend on MIT's microcode
//                     reaching the state that drives it --- an error halt, a
//                     disk transfer --- where a shell drives each line on its
//                     own, one at a time, which is what tells a crossed pair
//                     from a straight one.  The port list is `cadr_machine`'s
//                     own; a port added there and wired in the top level but
//                     not here is an elaboration error, and one here that
//                     the top level leaves unconnected is a lint error, so
//                     the two cannot drift apart unseen.
//
// **NONE OF THIS MAY MOVE TO `rtl/`**, for the reason `tb/cadr_de25_stubs.sv`
// gives: the board flows glob that tree.  The names `tbo_` (driven by the
// testbench) and `tbi_` (read by it) are this file's only convention.

`default_nettype none

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNDRIVEN */

module cadr_de25_pll (
    input  var logic refclk,
    input  var logic rst,
    output var logic outclk_0,
    output var logic locked
);
  logic tbo_unlock /*verilator public_flat_rw*/;
  assign outclk_0 = refclk;
  assign locked   = !rst && !tbo_unlock;
endmodule

module cadr_de25_pixel_pll (
    input  var logic refclk,
    input  var logic rst,
    output var logic outclk_0,
    output var logic locked
);
  assign outclk_0 = refclk;
  assign locked   = !rst;
endmodule

module cadr_de25_reset_release (
    output var logic ninit_done
);
  logic tbo_ninit_done /*verilator public_flat_rw*/;
  assign ninit_done = tbo_ninit_done;
endmodule

module cadr_de25_vjtag (
    output var logic tck,
    output var logic tdi,
    input  var logic tdo,
    output var logic ir_in,
    input  var logic ir_out,
    output var logic virtual_state_cdr,
    output var logic virtual_state_sdr,
    output var logic virtual_state_e1dr,
    output var logic virtual_state_pdr,
    output var logic virtual_state_e2dr,
    output var logic virtual_state_udr,
    output var logic virtual_state_cir,
    output var logic virtual_state_uir
);
  assign {tck, tdi, ir_in, virtual_state_cdr, virtual_state_sdr,
          virtual_state_e1dr, virtual_state_pdr, virtual_state_e2dr,
          virtual_state_udr, virtual_state_cir, virtual_state_uir} = '0;
endmodule

module cadr_de25_hps (
    output var  logic [0:0]   emif_mem_0_mem_cs,
    output var  logic [5:0]   emif_mem_0_mem_ca,
    output var  logic [0:0]   emif_mem_0_mem_cke,
    inout  wire logic [31:0]  emif_mem_0_mem_dq,
    inout  wire logic [3:0]   emif_mem_0_mem_dqs_t,
    inout  wire logic [3:0]   emif_mem_0_mem_dqs_c,
    inout  wire logic [3:0]   emif_mem_0_mem_dmi,
    output var  logic [0:0]   emif_mem_ck_0_mem_ck_t,
    output var  logic [0:0]   emif_mem_ck_0_mem_ck_c,
    output var  logic         emif_mem_reset_n_mem_reset_n,
    input  var  logic         emif_oct_0_oct_rzqin,
    input  var  logic         emif_ref_clk_clk,
    output var  logic         hps_h2f_reset_reset,
    input  var  logic [31:0]  hps_hps_gp_gp_in,
    output var  logic [31:0]  hps_hps_gp_gp_out,
    input  var  logic         hps_hps2fpga_axi_clock_clk,
    input  var  logic         hps_hps2fpga_axi_reset_reset,
    output var  logic [3:0]   hps_hps2fpga_awid,
    output var  logic [29:0]  hps_hps2fpga_awaddr,
    output var  logic [7:0]   hps_hps2fpga_awlen,
    output var  logic [2:0]   hps_hps2fpga_awsize,
    output var  logic [1:0]   hps_hps2fpga_awburst,
    output var  logic         hps_hps2fpga_awlock,
    output var  logic [3:0]   hps_hps2fpga_awcache,
    output var  logic [2:0]   hps_hps2fpga_awprot,
    output var  logic         hps_hps2fpga_awvalid,
    input  var  logic         hps_hps2fpga_awready,
    output var  logic [31:0]  hps_hps2fpga_wdata,
    output var  logic [3:0]   hps_hps2fpga_wstrb,
    output var  logic         hps_hps2fpga_wlast,
    output var  logic         hps_hps2fpga_wvalid,
    input  var  logic         hps_hps2fpga_wready,
    input  var  logic [3:0]   hps_hps2fpga_bid,
    input  var  logic [1:0]   hps_hps2fpga_bresp,
    input  var  logic         hps_hps2fpga_bvalid,
    output var  logic         hps_hps2fpga_bready,
    output var  logic [3:0]   hps_hps2fpga_arid,
    output var  logic [29:0]  hps_hps2fpga_araddr,
    output var  logic [7:0]   hps_hps2fpga_arlen,
    output var  logic [2:0]   hps_hps2fpga_arsize,
    output var  logic [1:0]   hps_hps2fpga_arburst,
    output var  logic         hps_hps2fpga_arlock,
    output var  logic [3:0]   hps_hps2fpga_arcache,
    output var  logic [2:0]   hps_hps2fpga_arprot,
    output var  logic         hps_hps2fpga_arvalid,
    input  var  logic         hps_hps2fpga_arready,
    input  var  logic [3:0]   hps_hps2fpga_rid,
    input  var  logic [31:0]  hps_hps2fpga_rdata,
    input  var  logic [1:0]   hps_hps2fpga_rresp,
    input  var  logic         hps_hps2fpga_rlast,
    input  var  logic         hps_hps2fpga_rvalid,
    output var  logic         hps_hps2fpga_rready,
    input  var  logic         hps_lwhps2fpga_axi_clock_clk,
    input  var  logic         hps_lwhps2fpga_axi_reset_reset,
    output var  logic [3:0]   hps_lwhps2fpga_awid,
    output var  logic [28:0]  hps_lwhps2fpga_awaddr,
    output var  logic [7:0]   hps_lwhps2fpga_awlen,
    output var  logic [2:0]   hps_lwhps2fpga_awsize,
    output var  logic [1:0]   hps_lwhps2fpga_awburst,
    output var  logic         hps_lwhps2fpga_awlock,
    output var  logic [3:0]   hps_lwhps2fpga_awcache,
    output var  logic [2:0]   hps_lwhps2fpga_awprot,
    output var  logic         hps_lwhps2fpga_awvalid,
    input  var  logic         hps_lwhps2fpga_awready,
    output var  logic [31:0]  hps_lwhps2fpga_wdata,
    output var  logic [3:0]   hps_lwhps2fpga_wstrb,
    output var  logic         hps_lwhps2fpga_wlast,
    output var  logic         hps_lwhps2fpga_wvalid,
    input  var  logic         hps_lwhps2fpga_wready,
    input  var  logic [3:0]   hps_lwhps2fpga_bid,
    input  var  logic [1:0]   hps_lwhps2fpga_bresp,
    input  var  logic         hps_lwhps2fpga_bvalid,
    output var  logic         hps_lwhps2fpga_bready,
    output var  logic [3:0]   hps_lwhps2fpga_arid,
    output var  logic [28:0]  hps_lwhps2fpga_araddr,
    output var  logic [7:0]   hps_lwhps2fpga_arlen,
    output var  logic [2:0]   hps_lwhps2fpga_arsize,
    output var  logic [1:0]   hps_lwhps2fpga_arburst,
    output var  logic         hps_lwhps2fpga_arlock,
    output var  logic [3:0]   hps_lwhps2fpga_arcache,
    output var  logic [2:0]   hps_lwhps2fpga_arprot,
    output var  logic         hps_lwhps2fpga_arvalid,
    input  var  logic         hps_lwhps2fpga_arready,
    input  var  logic [3:0]   hps_lwhps2fpga_rid,
    input  var  logic [31:0]  hps_lwhps2fpga_rdata,
    input  var  logic [1:0]   hps_lwhps2fpga_rresp,
    input  var  logic         hps_lwhps2fpga_rlast,
    input  var  logic         hps_lwhps2fpga_rvalid,
    output var  logic         hps_lwhps2fpga_rready,
    output var  logic         hps_h2f_warm_reset_handshake_reset_req,
    input  var  logic         hps_h2f_warm_reset_handshake_reset_ack,
    input  var  logic         hps_hps_io_hps_osc_clk,
    inout  wire logic         hps_hps_io_sdmmc_data0,
    inout  wire logic         hps_hps_io_sdmmc_data1,
    output var  logic         hps_hps_io_sdmmc_cclk,
    inout  wire logic         hps_hps_io_sdmmc_data2,
    inout  wire logic         hps_hps_io_sdmmc_data3,
    inout  wire logic         hps_hps_io_sdmmc_cmd,
    input  var  logic         hps_hps_io_usb0_clk,
    output var  logic         hps_hps_io_usb0_stp,
    input  var  logic         hps_hps_io_usb0_dir,
    inout  wire logic         hps_hps_io_usb0_data0,
    inout  wire logic         hps_hps_io_usb0_data1,
    input  var  logic         hps_hps_io_usb0_nxt,
    inout  wire logic         hps_hps_io_usb0_data2,
    inout  wire logic         hps_hps_io_usb0_data3,
    inout  wire logic         hps_hps_io_usb0_data4,
    inout  wire logic         hps_hps_io_usb0_data5,
    inout  wire logic         hps_hps_io_usb0_data6,
    inout  wire logic         hps_hps_io_usb0_data7,
    output var  logic         hps_hps_io_emac0_tx_clk,
    output var  logic         hps_hps_io_emac0_tx_ctl,
    input  var  logic         hps_hps_io_emac0_rx_clk,
    input  var  logic         hps_hps_io_emac0_rx_ctl,
    output var  logic         hps_hps_io_emac0_txd0,
    output var  logic         hps_hps_io_emac0_txd1,
    input  var  logic         hps_hps_io_emac0_rxd0,
    input  var  logic         hps_hps_io_emac0_rxd1,
    output var  logic         hps_hps_io_emac0_txd2,
    output var  logic         hps_hps_io_emac0_txd3,
    input  var  logic         hps_hps_io_emac0_rxd2,
    input  var  logic         hps_hps_io_emac0_rxd3,
    inout  wire logic         hps_hps_io_mdio0_mdio,
    output var  logic         hps_hps_io_mdio0_mdc,
    output var  logic         hps_hps_io_uart1_tx,
    input  var  logic         hps_hps_io_uart1_rx,
    inout  wire logic         hps_hps_io_i2c1_sda,
    inout  wire logic         hps_hps_io_i2c1_scl,
    inout  wire logic         hps_hps_io_gpio28,
    inout  wire logic         hps_hps_io_gpio40,
    inout  wire logic         hps_hps_io_gpio41,
    input  var  logic         hps_f2sdram_axi_clock_clk,
    input  var  logic         hps_f2sdram_axi_reset_reset,
    input  var  logic [31:0]  hps_f2sdram_araddr,
    input  var  logic [1:0]   hps_f2sdram_arburst,
    input  var  logic [3:0]   hps_f2sdram_arcache,
    input  var  logic [4:0]   hps_f2sdram_arid,
    input  var  logic [7:0]   hps_f2sdram_arlen,
    input  var  logic         hps_f2sdram_arlock,
    input  var  logic [2:0]   hps_f2sdram_arprot,
    input  var  logic [3:0]   hps_f2sdram_arqos,
    output var  logic         hps_f2sdram_arready,
    input  var  logic [2:0]   hps_f2sdram_arsize,
    input  var  logic         hps_f2sdram_arvalid,
    input  var  logic [31:0]  hps_f2sdram_awaddr,
    input  var  logic [1:0]   hps_f2sdram_awburst,
    input  var  logic [3:0]   hps_f2sdram_awcache,
    input  var  logic [4:0]   hps_f2sdram_awid,
    input  var  logic [7:0]   hps_f2sdram_awlen,
    input  var  logic         hps_f2sdram_awlock,
    input  var  logic [2:0]   hps_f2sdram_awprot,
    input  var  logic [3:0]   hps_f2sdram_awqos,
    output var  logic         hps_f2sdram_awready,
    input  var  logic [2:0]   hps_f2sdram_awsize,
    input  var  logic         hps_f2sdram_awvalid,
    output var  logic [4:0]   hps_f2sdram_bid,
    input  var  logic         hps_f2sdram_bready,
    output var  logic [1:0]   hps_f2sdram_bresp,
    output var  logic         hps_f2sdram_bvalid,
    output var  logic [63:0]  hps_f2sdram_rdata,
    output var  logic [4:0]   hps_f2sdram_rid,
    output var  logic         hps_f2sdram_rlast,
    input  var  logic         hps_f2sdram_rready,
    output var  logic [1:0]   hps_f2sdram_rresp,
    output var  logic         hps_f2sdram_rvalid,
    input  var  logic [63:0]  hps_f2sdram_wdata,
    input  var  logic         hps_f2sdram_wlast,
    output var  logic         hps_f2sdram_wready,
    input  var  logic [7:0]   hps_f2sdram_wstrb,
    input  var  logic         hps_f2sdram_wvalid,
    input  var  logic [7:0]   hps_f2sdram_aruser,
    input  var  logic [7:0]   hps_f2sdram_awuser,
    input  var  logic [7:0]   hps_f2sdram_wuser,
    output var  logic [7:0]   hps_f2sdram_buser,
    input  var  logic [3:0]   hps_f2sdram_arregion,
    output var  logic [7:0]   hps_f2sdram_ruser,
    input  var  logic [3:0]   hps_f2sdram_awregion
);
  logic [0:0]   tbo_emif_mem_0_mem_cs /*verilator public_flat_rw*/;
  assign emif_mem_0_mem_cs = tbo_emif_mem_0_mem_cs;
  logic [5:0]   tbo_emif_mem_0_mem_ca /*verilator public_flat_rw*/;
  assign emif_mem_0_mem_ca = tbo_emif_mem_0_mem_ca;
  logic [0:0]   tbo_emif_mem_0_mem_cke /*verilator public_flat_rw*/;
  assign emif_mem_0_mem_cke = tbo_emif_mem_0_mem_cke;
  logic [0:0]   tbo_emif_mem_ck_0_mem_ck_t /*verilator public_flat_rw*/;
  assign emif_mem_ck_0_mem_ck_t = tbo_emif_mem_ck_0_mem_ck_t;
  logic [0:0]   tbo_emif_mem_ck_0_mem_ck_c /*verilator public_flat_rw*/;
  assign emif_mem_ck_0_mem_ck_c = tbo_emif_mem_ck_0_mem_ck_c;
  logic         tbo_emif_mem_reset_n_mem_reset_n /*verilator public_flat_rw*/;
  assign emif_mem_reset_n_mem_reset_n = tbo_emif_mem_reset_n_mem_reset_n;
  logic         tbi_emif_oct_0_oct_rzqin /*verilator public_flat_rd*/;
  assign tbi_emif_oct_0_oct_rzqin = emif_oct_0_oct_rzqin;
  logic         tbi_emif_ref_clk_clk /*verilator public_flat_rd*/;
  assign tbi_emif_ref_clk_clk = emif_ref_clk_clk;
  logic         tbo_hps_h2f_reset_reset /*verilator public_flat_rw*/;
  assign hps_h2f_reset_reset = tbo_hps_h2f_reset_reset;
  logic [31:0]  tbi_hps_hps_gp_gp_in /*verilator public_flat_rd*/;
  assign tbi_hps_hps_gp_gp_in = hps_hps_gp_gp_in;
  logic [31:0]  tbo_hps_hps_gp_gp_out /*verilator public_flat_rw*/;
  assign hps_hps_gp_gp_out = tbo_hps_hps_gp_gp_out;
  logic         tbi_hps_hps2fpga_axi_clock_clk /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_axi_clock_clk = hps_hps2fpga_axi_clock_clk;
  logic         tbi_hps_hps2fpga_axi_reset_reset /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_axi_reset_reset = hps_hps2fpga_axi_reset_reset;
  logic [3:0]   tbo_hps_hps2fpga_awid /*verilator public_flat_rw*/;
  assign hps_hps2fpga_awid = tbo_hps_hps2fpga_awid;
  logic [29:0]  tbo_hps_hps2fpga_awaddr /*verilator public_flat_rw*/;
  assign hps_hps2fpga_awaddr = tbo_hps_hps2fpga_awaddr;
  logic [7:0]   tbo_hps_hps2fpga_awlen /*verilator public_flat_rw*/;
  assign hps_hps2fpga_awlen = tbo_hps_hps2fpga_awlen;
  logic [2:0]   tbo_hps_hps2fpga_awsize /*verilator public_flat_rw*/;
  assign hps_hps2fpga_awsize = tbo_hps_hps2fpga_awsize;
  logic [1:0]   tbo_hps_hps2fpga_awburst /*verilator public_flat_rw*/;
  assign hps_hps2fpga_awburst = tbo_hps_hps2fpga_awburst;
  logic         tbo_hps_hps2fpga_awlock /*verilator public_flat_rw*/;
  assign hps_hps2fpga_awlock = tbo_hps_hps2fpga_awlock;
  logic [3:0]   tbo_hps_hps2fpga_awcache /*verilator public_flat_rw*/;
  assign hps_hps2fpga_awcache = tbo_hps_hps2fpga_awcache;
  logic [2:0]   tbo_hps_hps2fpga_awprot /*verilator public_flat_rw*/;
  assign hps_hps2fpga_awprot = tbo_hps_hps2fpga_awprot;
  logic         tbo_hps_hps2fpga_awvalid /*verilator public_flat_rw*/;
  assign hps_hps2fpga_awvalid = tbo_hps_hps2fpga_awvalid;
  logic         tbi_hps_hps2fpga_awready /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_awready = hps_hps2fpga_awready;
  logic [31:0]  tbo_hps_hps2fpga_wdata /*verilator public_flat_rw*/;
  assign hps_hps2fpga_wdata = tbo_hps_hps2fpga_wdata;
  logic [3:0]   tbo_hps_hps2fpga_wstrb /*verilator public_flat_rw*/;
  assign hps_hps2fpga_wstrb = tbo_hps_hps2fpga_wstrb;
  logic         tbo_hps_hps2fpga_wlast /*verilator public_flat_rw*/;
  assign hps_hps2fpga_wlast = tbo_hps_hps2fpga_wlast;
  logic         tbo_hps_hps2fpga_wvalid /*verilator public_flat_rw*/;
  assign hps_hps2fpga_wvalid = tbo_hps_hps2fpga_wvalid;
  logic         tbi_hps_hps2fpga_wready /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_wready = hps_hps2fpga_wready;
  logic [3:0]   tbi_hps_hps2fpga_bid /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_bid = hps_hps2fpga_bid;
  logic [1:0]   tbi_hps_hps2fpga_bresp /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_bresp = hps_hps2fpga_bresp;
  logic         tbi_hps_hps2fpga_bvalid /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_bvalid = hps_hps2fpga_bvalid;
  logic         tbo_hps_hps2fpga_bready /*verilator public_flat_rw*/;
  assign hps_hps2fpga_bready = tbo_hps_hps2fpga_bready;
  logic [3:0]   tbo_hps_hps2fpga_arid /*verilator public_flat_rw*/;
  assign hps_hps2fpga_arid = tbo_hps_hps2fpga_arid;
  logic [29:0]  tbo_hps_hps2fpga_araddr /*verilator public_flat_rw*/;
  assign hps_hps2fpga_araddr = tbo_hps_hps2fpga_araddr;
  logic [7:0]   tbo_hps_hps2fpga_arlen /*verilator public_flat_rw*/;
  assign hps_hps2fpga_arlen = tbo_hps_hps2fpga_arlen;
  logic [2:0]   tbo_hps_hps2fpga_arsize /*verilator public_flat_rw*/;
  assign hps_hps2fpga_arsize = tbo_hps_hps2fpga_arsize;
  logic [1:0]   tbo_hps_hps2fpga_arburst /*verilator public_flat_rw*/;
  assign hps_hps2fpga_arburst = tbo_hps_hps2fpga_arburst;
  logic         tbo_hps_hps2fpga_arlock /*verilator public_flat_rw*/;
  assign hps_hps2fpga_arlock = tbo_hps_hps2fpga_arlock;
  logic [3:0]   tbo_hps_hps2fpga_arcache /*verilator public_flat_rw*/;
  assign hps_hps2fpga_arcache = tbo_hps_hps2fpga_arcache;
  logic [2:0]   tbo_hps_hps2fpga_arprot /*verilator public_flat_rw*/;
  assign hps_hps2fpga_arprot = tbo_hps_hps2fpga_arprot;
  logic         tbo_hps_hps2fpga_arvalid /*verilator public_flat_rw*/;
  assign hps_hps2fpga_arvalid = tbo_hps_hps2fpga_arvalid;
  logic         tbi_hps_hps2fpga_arready /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_arready = hps_hps2fpga_arready;
  logic [3:0]   tbi_hps_hps2fpga_rid /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_rid = hps_hps2fpga_rid;
  logic [31:0]  tbi_hps_hps2fpga_rdata /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_rdata = hps_hps2fpga_rdata;
  logic [1:0]   tbi_hps_hps2fpga_rresp /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_rresp = hps_hps2fpga_rresp;
  logic         tbi_hps_hps2fpga_rlast /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_rlast = hps_hps2fpga_rlast;
  logic         tbi_hps_hps2fpga_rvalid /*verilator public_flat_rd*/;
  assign tbi_hps_hps2fpga_rvalid = hps_hps2fpga_rvalid;
  logic         tbo_hps_hps2fpga_rready /*verilator public_flat_rw*/;
  assign hps_hps2fpga_rready = tbo_hps_hps2fpga_rready;
  logic         tbi_hps_lwhps2fpga_axi_clock_clk /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_axi_clock_clk = hps_lwhps2fpga_axi_clock_clk;
  logic         tbi_hps_lwhps2fpga_axi_reset_reset /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_axi_reset_reset = hps_lwhps2fpga_axi_reset_reset;
  logic [3:0]   tbo_hps_lwhps2fpga_awid /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_awid = tbo_hps_lwhps2fpga_awid;
  logic [28:0]  tbo_hps_lwhps2fpga_awaddr /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_awaddr = tbo_hps_lwhps2fpga_awaddr;
  logic [7:0]   tbo_hps_lwhps2fpga_awlen /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_awlen = tbo_hps_lwhps2fpga_awlen;
  logic [2:0]   tbo_hps_lwhps2fpga_awsize /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_awsize = tbo_hps_lwhps2fpga_awsize;
  logic [1:0]   tbo_hps_lwhps2fpga_awburst /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_awburst = tbo_hps_lwhps2fpga_awburst;
  logic         tbo_hps_lwhps2fpga_awlock /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_awlock = tbo_hps_lwhps2fpga_awlock;
  logic [3:0]   tbo_hps_lwhps2fpga_awcache /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_awcache = tbo_hps_lwhps2fpga_awcache;
  logic [2:0]   tbo_hps_lwhps2fpga_awprot /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_awprot = tbo_hps_lwhps2fpga_awprot;
  logic         tbo_hps_lwhps2fpga_awvalid /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_awvalid = tbo_hps_lwhps2fpga_awvalid;
  logic         tbi_hps_lwhps2fpga_awready /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_awready = hps_lwhps2fpga_awready;
  logic [31:0]  tbo_hps_lwhps2fpga_wdata /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_wdata = tbo_hps_lwhps2fpga_wdata;
  logic [3:0]   tbo_hps_lwhps2fpga_wstrb /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_wstrb = tbo_hps_lwhps2fpga_wstrb;
  logic         tbo_hps_lwhps2fpga_wlast /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_wlast = tbo_hps_lwhps2fpga_wlast;
  logic         tbo_hps_lwhps2fpga_wvalid /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_wvalid = tbo_hps_lwhps2fpga_wvalid;
  logic         tbi_hps_lwhps2fpga_wready /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_wready = hps_lwhps2fpga_wready;
  logic [3:0]   tbi_hps_lwhps2fpga_bid /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_bid = hps_lwhps2fpga_bid;
  logic [1:0]   tbi_hps_lwhps2fpga_bresp /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_bresp = hps_lwhps2fpga_bresp;
  logic         tbi_hps_lwhps2fpga_bvalid /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_bvalid = hps_lwhps2fpga_bvalid;
  logic         tbo_hps_lwhps2fpga_bready /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_bready = tbo_hps_lwhps2fpga_bready;
  logic [3:0]   tbo_hps_lwhps2fpga_arid /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_arid = tbo_hps_lwhps2fpga_arid;
  logic [28:0]  tbo_hps_lwhps2fpga_araddr /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_araddr = tbo_hps_lwhps2fpga_araddr;
  logic [7:0]   tbo_hps_lwhps2fpga_arlen /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_arlen = tbo_hps_lwhps2fpga_arlen;
  logic [2:0]   tbo_hps_lwhps2fpga_arsize /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_arsize = tbo_hps_lwhps2fpga_arsize;
  logic [1:0]   tbo_hps_lwhps2fpga_arburst /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_arburst = tbo_hps_lwhps2fpga_arburst;
  logic         tbo_hps_lwhps2fpga_arlock /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_arlock = tbo_hps_lwhps2fpga_arlock;
  logic [3:0]   tbo_hps_lwhps2fpga_arcache /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_arcache = tbo_hps_lwhps2fpga_arcache;
  logic [2:0]   tbo_hps_lwhps2fpga_arprot /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_arprot = tbo_hps_lwhps2fpga_arprot;
  logic         tbo_hps_lwhps2fpga_arvalid /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_arvalid = tbo_hps_lwhps2fpga_arvalid;
  logic         tbi_hps_lwhps2fpga_arready /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_arready = hps_lwhps2fpga_arready;
  logic [3:0]   tbi_hps_lwhps2fpga_rid /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_rid = hps_lwhps2fpga_rid;
  logic [31:0]  tbi_hps_lwhps2fpga_rdata /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_rdata = hps_lwhps2fpga_rdata;
  logic [1:0]   tbi_hps_lwhps2fpga_rresp /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_rresp = hps_lwhps2fpga_rresp;
  logic         tbi_hps_lwhps2fpga_rlast /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_rlast = hps_lwhps2fpga_rlast;
  logic         tbi_hps_lwhps2fpga_rvalid /*verilator public_flat_rd*/;
  assign tbi_hps_lwhps2fpga_rvalid = hps_lwhps2fpga_rvalid;
  logic         tbo_hps_lwhps2fpga_rready /*verilator public_flat_rw*/;
  assign hps_lwhps2fpga_rready = tbo_hps_lwhps2fpga_rready;
  logic         tbo_hps_h2f_warm_reset_handshake_reset_req /*verilator public_flat_rw*/;
  assign hps_h2f_warm_reset_handshake_reset_req = tbo_hps_h2f_warm_reset_handshake_reset_req;
  logic         tbi_hps_h2f_warm_reset_handshake_reset_ack /*verilator public_flat_rd*/;
  assign tbi_hps_h2f_warm_reset_handshake_reset_ack = hps_h2f_warm_reset_handshake_reset_ack;
  logic         tbi_hps_hps_io_hps_osc_clk /*verilator public_flat_rd*/;
  assign tbi_hps_hps_io_hps_osc_clk = hps_hps_io_hps_osc_clk;
  logic         tbo_hps_hps_io_sdmmc_cclk /*verilator public_flat_rw*/;
  assign hps_hps_io_sdmmc_cclk = tbo_hps_hps_io_sdmmc_cclk;
  logic         tbi_hps_hps_io_usb0_clk /*verilator public_flat_rd*/;
  assign tbi_hps_hps_io_usb0_clk = hps_hps_io_usb0_clk;
  logic         tbo_hps_hps_io_usb0_stp /*verilator public_flat_rw*/;
  assign hps_hps_io_usb0_stp = tbo_hps_hps_io_usb0_stp;
  logic         tbi_hps_hps_io_usb0_dir /*verilator public_flat_rd*/;
  assign tbi_hps_hps_io_usb0_dir = hps_hps_io_usb0_dir;
  logic         tbi_hps_hps_io_usb0_nxt /*verilator public_flat_rd*/;
  assign tbi_hps_hps_io_usb0_nxt = hps_hps_io_usb0_nxt;
  logic         tbo_hps_hps_io_emac0_tx_clk /*verilator public_flat_rw*/;
  assign hps_hps_io_emac0_tx_clk = tbo_hps_hps_io_emac0_tx_clk;
  logic         tbo_hps_hps_io_emac0_tx_ctl /*verilator public_flat_rw*/;
  assign hps_hps_io_emac0_tx_ctl = tbo_hps_hps_io_emac0_tx_ctl;
  logic         tbi_hps_hps_io_emac0_rx_clk /*verilator public_flat_rd*/;
  assign tbi_hps_hps_io_emac0_rx_clk = hps_hps_io_emac0_rx_clk;
  logic         tbi_hps_hps_io_emac0_rx_ctl /*verilator public_flat_rd*/;
  assign tbi_hps_hps_io_emac0_rx_ctl = hps_hps_io_emac0_rx_ctl;
  logic         tbo_hps_hps_io_emac0_txd0 /*verilator public_flat_rw*/;
  assign hps_hps_io_emac0_txd0 = tbo_hps_hps_io_emac0_txd0;
  logic         tbo_hps_hps_io_emac0_txd1 /*verilator public_flat_rw*/;
  assign hps_hps_io_emac0_txd1 = tbo_hps_hps_io_emac0_txd1;
  logic         tbi_hps_hps_io_emac0_rxd0 /*verilator public_flat_rd*/;
  assign tbi_hps_hps_io_emac0_rxd0 = hps_hps_io_emac0_rxd0;
  logic         tbi_hps_hps_io_emac0_rxd1 /*verilator public_flat_rd*/;
  assign tbi_hps_hps_io_emac0_rxd1 = hps_hps_io_emac0_rxd1;
  logic         tbo_hps_hps_io_emac0_txd2 /*verilator public_flat_rw*/;
  assign hps_hps_io_emac0_txd2 = tbo_hps_hps_io_emac0_txd2;
  logic         tbo_hps_hps_io_emac0_txd3 /*verilator public_flat_rw*/;
  assign hps_hps_io_emac0_txd3 = tbo_hps_hps_io_emac0_txd3;
  logic         tbi_hps_hps_io_emac0_rxd2 /*verilator public_flat_rd*/;
  assign tbi_hps_hps_io_emac0_rxd2 = hps_hps_io_emac0_rxd2;
  logic         tbi_hps_hps_io_emac0_rxd3 /*verilator public_flat_rd*/;
  assign tbi_hps_hps_io_emac0_rxd3 = hps_hps_io_emac0_rxd3;
  logic         tbo_hps_hps_io_mdio0_mdc /*verilator public_flat_rw*/;
  assign hps_hps_io_mdio0_mdc = tbo_hps_hps_io_mdio0_mdc;
  logic         tbo_hps_hps_io_uart1_tx /*verilator public_flat_rw*/;
  assign hps_hps_io_uart1_tx = tbo_hps_hps_io_uart1_tx;
  logic         tbi_hps_hps_io_uart1_rx /*verilator public_flat_rd*/;
  assign tbi_hps_hps_io_uart1_rx = hps_hps_io_uart1_rx;
  logic         tbi_hps_f2sdram_axi_clock_clk /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_axi_clock_clk = hps_f2sdram_axi_clock_clk;
  logic         tbi_hps_f2sdram_axi_reset_reset /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_axi_reset_reset = hps_f2sdram_axi_reset_reset;
  logic [31:0]  tbi_hps_f2sdram_araddr /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_araddr = hps_f2sdram_araddr;
  logic [1:0]   tbi_hps_f2sdram_arburst /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_arburst = hps_f2sdram_arburst;
  logic [3:0]   tbi_hps_f2sdram_arcache /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_arcache = hps_f2sdram_arcache;
  logic [4:0]   tbi_hps_f2sdram_arid /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_arid = hps_f2sdram_arid;
  logic [7:0]   tbi_hps_f2sdram_arlen /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_arlen = hps_f2sdram_arlen;
  logic         tbi_hps_f2sdram_arlock /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_arlock = hps_f2sdram_arlock;
  logic [2:0]   tbi_hps_f2sdram_arprot /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_arprot = hps_f2sdram_arprot;
  logic [3:0]   tbi_hps_f2sdram_arqos /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_arqos = hps_f2sdram_arqos;
  logic         tbo_hps_f2sdram_arready /*verilator public_flat_rw*/;
  assign hps_f2sdram_arready = tbo_hps_f2sdram_arready;
  logic [2:0]   tbi_hps_f2sdram_arsize /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_arsize = hps_f2sdram_arsize;
  logic         tbi_hps_f2sdram_arvalid /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_arvalid = hps_f2sdram_arvalid;
  logic [31:0]  tbi_hps_f2sdram_awaddr /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_awaddr = hps_f2sdram_awaddr;
  logic [1:0]   tbi_hps_f2sdram_awburst /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_awburst = hps_f2sdram_awburst;
  logic [3:0]   tbi_hps_f2sdram_awcache /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_awcache = hps_f2sdram_awcache;
  logic [4:0]   tbi_hps_f2sdram_awid /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_awid = hps_f2sdram_awid;
  logic [7:0]   tbi_hps_f2sdram_awlen /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_awlen = hps_f2sdram_awlen;
  logic         tbi_hps_f2sdram_awlock /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_awlock = hps_f2sdram_awlock;
  logic [2:0]   tbi_hps_f2sdram_awprot /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_awprot = hps_f2sdram_awprot;
  logic [3:0]   tbi_hps_f2sdram_awqos /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_awqos = hps_f2sdram_awqos;
  logic         tbo_hps_f2sdram_awready /*verilator public_flat_rw*/;
  assign hps_f2sdram_awready = tbo_hps_f2sdram_awready;
  logic [2:0]   tbi_hps_f2sdram_awsize /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_awsize = hps_f2sdram_awsize;
  logic         tbi_hps_f2sdram_awvalid /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_awvalid = hps_f2sdram_awvalid;
  logic [4:0]   tbo_hps_f2sdram_bid /*verilator public_flat_rw*/;
  assign hps_f2sdram_bid = tbo_hps_f2sdram_bid;
  logic         tbi_hps_f2sdram_bready /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_bready = hps_f2sdram_bready;
  logic [1:0]   tbo_hps_f2sdram_bresp /*verilator public_flat_rw*/;
  assign hps_f2sdram_bresp = tbo_hps_f2sdram_bresp;
  logic         tbo_hps_f2sdram_bvalid /*verilator public_flat_rw*/;
  assign hps_f2sdram_bvalid = tbo_hps_f2sdram_bvalid;
  logic [63:0]  tbo_hps_f2sdram_rdata /*verilator public_flat_rw*/;
  assign hps_f2sdram_rdata = tbo_hps_f2sdram_rdata;
  logic [4:0]   tbo_hps_f2sdram_rid /*verilator public_flat_rw*/;
  assign hps_f2sdram_rid = tbo_hps_f2sdram_rid;
  logic         tbo_hps_f2sdram_rlast /*verilator public_flat_rw*/;
  assign hps_f2sdram_rlast = tbo_hps_f2sdram_rlast;
  logic         tbi_hps_f2sdram_rready /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_rready = hps_f2sdram_rready;
  logic [1:0]   tbo_hps_f2sdram_rresp /*verilator public_flat_rw*/;
  assign hps_f2sdram_rresp = tbo_hps_f2sdram_rresp;
  logic         tbo_hps_f2sdram_rvalid /*verilator public_flat_rw*/;
  assign hps_f2sdram_rvalid = tbo_hps_f2sdram_rvalid;
  logic [63:0]  tbi_hps_f2sdram_wdata /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_wdata = hps_f2sdram_wdata;
  logic         tbi_hps_f2sdram_wlast /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_wlast = hps_f2sdram_wlast;
  logic         tbo_hps_f2sdram_wready /*verilator public_flat_rw*/;
  assign hps_f2sdram_wready = tbo_hps_f2sdram_wready;
  logic [7:0]   tbi_hps_f2sdram_wstrb /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_wstrb = hps_f2sdram_wstrb;
  logic         tbi_hps_f2sdram_wvalid /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_wvalid = hps_f2sdram_wvalid;
  logic [7:0]   tbi_hps_f2sdram_aruser /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_aruser = hps_f2sdram_aruser;
  logic [7:0]   tbi_hps_f2sdram_awuser /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_awuser = hps_f2sdram_awuser;
  logic [7:0]   tbi_hps_f2sdram_wuser /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_wuser = hps_f2sdram_wuser;
  logic [7:0]   tbo_hps_f2sdram_buser /*verilator public_flat_rw*/;
  assign hps_f2sdram_buser = tbo_hps_f2sdram_buser;
  logic [3:0]   tbi_hps_f2sdram_arregion /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_arregion = hps_f2sdram_arregion;
  logic [7:0]   tbo_hps_f2sdram_ruser /*verilator public_flat_rw*/;
  assign hps_f2sdram_ruser = tbo_hps_f2sdram_ruser;
  logic [3:0]   tbi_hps_f2sdram_awregion /*verilator public_flat_rd*/;
  assign tbi_hps_f2sdram_awregion = hps_f2sdram_awregion;
endmodule


module cadr_machine #(
    parameter string PROM_HEX = "",
    parameter string SYNC_PROM_HEX = "",
    parameter int LMTV = 1
) (
    input  var logic         clk,
    input  var logic         rst,
    output var logic         sintr_o,
    input  var logic [7:0]   drive_present,
    input  var logic [7:0]   drive_read_only,
    input  var logic         drive_timed,
    input  var logic         store_we,
    input  var logic [4:0]   store_slot,
    input  var logic [8:0]   store_addr,
    input  var logic [31:0]  store_wdata,
    output var logic [31:0]  store_rdata,
    output var logic         store_miss,
    output var logic         ch_active,
    input  var logic         store_busy,
    input  var logic [4:0]   store_busy_slot,
    output var logic         req_valid,
    output var logic [30:0]  req_tag,
    output var logic         req_post,
    output var logic         ch_waiting,
    input  var logic         store_deny,
    output var logic [4:0]   ch_slot,
    output var logic         ch_wrote,
    output var logic         ch_hit,
    input  var logic         kbd_strobe,
    input  var logic [23:0]  kbd_code,
    input  var logic [6:0]   mouse_lines,
    input  var logic         n_boot2,
    input  var logic         no_auto_boot,
    output var logic         ser_reset,
    output var logic [7:0]   ser_mode1,
    output var logic [7:0]   ser_mode2,
    output var logic [7:0]   ser_cmd,
    output var logic         ser_tx_strobe,
    output var logic [7:0]   ser_tx_data,
    input  var logic         ser_tx_take,
    input  var logic         ser_tx_done,
    input  var logic         ser_rx_strobe,
    input  var logic [7:0]   ser_rx_data,
    input  var logic         ser_rx_end,
    input  var logic         ser_rx_parity,
    input  var logic         ser_rx_framing,
    input  var logic         ser_plugged,
    output var logic [7:0]   ser_status,
    output var logic [25:0]  ser_syn_face,
    input  var logic [15:0]  chaos_address,
    output var logic         chaos_tx_go,
    output var logic [8:0]   chaos_tx_len,
    output var logic         chaos_tx_valid,
    output var logic [15:0]  chaos_tx_word,
    output var logic         chaos_tx_clear,
    output var logic         chaos_reset,
    output var logic [15:0]  chaos_csr,
    input  var logic         chaos_rx_valid,
    input  var logic [15:0]  chaos_rx_word,
    input  var logic         chaos_rx_done,
    input  var logic [12:0]  chaos_rx_bits,
    input  var logic         chaos_rx_crc,
    input  var logic         chaos_rx_lost,
    input  var logic         chaos_tx_done,
    input  var logic         chaos_tx_abort,
    input  var logic         chaos_cbl_busy,
    output var logic [11:0]  chaos_bits,
    output var logic         iob_intr,
    output var logic [7:0]   iob_vector,
    output var logic         audio,
    output var logic [7:0]   csr_face,
    output var logic [11:0]  mouse_x,
    output var logic [11:0]  mouse_y,
    output var logic         clock_ready,
    output var logic [15:0]  interval,
    input  var logic [6:0]   boards,
    input  var logic         tv_lispm,
    input  var logic         color_tv,
    input  var logic [3:0]   tv_map_a,
    output var logic [23:0]  tv_map_q,
    output var logic [23:0]  tv_color_map_q,
    input  var logic [3:0]   disp_map_a,
    output var logic [23:0]  disp_color_map_q,
    output var logic [13:0]  pc,
    output var logic [13:0]  lpc,
    output var logic [13:0]  opc,
    output var logic [31:0]  st,
    output var logic [47:0]  ir,
    output var logic [31:0]  a,
    output var logic [31:0]  m,
    output var logic [31:0]  alu,
    output var logic [31:0]  r,
    output var logic [31:0]  ob,
    output var logic [31:0]  q,
    output var logic [9:0]   dc,
    output var logic [25:0]  lc,
    output var logic [31:0]  vma,
    output var logic [31:0]  md,
    output var logic         vmaok,
    output var logic         jcond,
    output var logic         nop,
    output var logic         pcs1,
    output var logic         pcs0,
    output var logic         iwrited,
    output var logic         promenable,
    output var logic         clock_edge,
    output var logic         wrcyc,
    output var logic         device,
    output var logic         dev_rq,
    output var logic         dev_write,
    output var logic [21:0]  phys,
    output var logic [31:0]  dev_wdata,
    input  var logic         device_ack,
    input  var logic [31:0]  device_rdata,
    output var logic         promdisable,
    output var logic         ub_msyn,
    output var logic         ub_ssyn_o,
    output var logic [2:0]   arb_stage,
    output var logic         n_memrq_o,
    output var logic         n_memack_o,
    output var logic         n_memgrant_o,
    output var logic         mbusy_o,
    output var logic         mbusy_sync_o,
    output var logic [17:0]  ub_addr_o,
    output var logic [15:0]  ub_rdata_o,
    output var logic [2:0]   ub_ssyn_by,
    output var logic         n_loadmd_o,
    output var logic         rdcyc_o,
    output var logic         nxm,
    output var logic         unibus,
    output var logic         memstart,
    output var logic         timed_out,
    output var logic         machrun,
    output var logic         errhalt,
    output var logic         stathalt,
    output var logic         n_boot_o,
    input  var logic         con_req,
    output var logic         con_gnt,
    input  var logic         con_msyn,
    input  var logic         con_write,
    input  var logic [17:0]  con_addr,
    input  var logic [15:0]  con_wdata,
    output var logic         con_ssyn,
    output var logic [15:0]  con_rdata,
    input  var logic         dbg_in_req,
    input  var logic         dbg_in_wr,
    input  var logic [1:0]   dbg_in_a,
    input  var logic [15:0]  dbd_in,
    output var logic         dbg_in_ack,
    output var logic [15:0]  dbd_out,
    output var logic [1:0]   dbd_oe,
    output var logic         dbgout_req,
    output var logic         dbgout_wr,
    output var logic [1:0]   dbgout_a,
    output var logic [15:0]  dbgout_dbd,
    input  var logic         dbgout_ack,
    input  var logic [15:0]  dbgout_dbd_in,
    input  var logic         dbgout_live,
    output var logic         debuggee_reset,
    output var logic         timeout_inhibit,
    input  var logic         dbg_rst,
    output var logic [31:0]  con_vma,
    output var logic [31:0]  con_q,
    output var logic [31:0]  con_md,
    input  var logic [17:0]  con_ro_addr,
    output var logic [47:0]  con_ro_data,
    output var logic [17:0]  con_ro_echo,
    output var logic         mem_req,
    output var logic         mem_write,
    output var logic [31:0]  mem_addr,
    output var logic [31:0]  mem_wdata,
    input  var logic         mem_done,
    input  var logic [31:0]  mem_rdata,
    input  var logic         port_read_ack,
    input  var logic         port_write_ack
);
  logic         tbi_rst /*verilator public_flat_rd*/;
  assign tbi_rst = rst;
  logic         tbo_sintr_o /*verilator public_flat_rw*/;
  assign sintr_o = tbo_sintr_o;
  logic [7:0]   tbi_drive_present /*verilator public_flat_rd*/;
  assign tbi_drive_present = drive_present;
  logic [7:0]   tbi_drive_read_only /*verilator public_flat_rd*/;
  assign tbi_drive_read_only = drive_read_only;
  logic         tbi_drive_timed /*verilator public_flat_rd*/;
  assign tbi_drive_timed = drive_timed;
  logic         tbi_store_we /*verilator public_flat_rd*/;
  assign tbi_store_we = store_we;
  logic [4:0]   tbi_store_slot /*verilator public_flat_rd*/;
  assign tbi_store_slot = store_slot;
  logic [8:0]   tbi_store_addr /*verilator public_flat_rd*/;
  assign tbi_store_addr = store_addr;
  logic [31:0]  tbi_store_wdata /*verilator public_flat_rd*/;
  assign tbi_store_wdata = store_wdata;
  logic [31:0]  tbo_store_rdata /*verilator public_flat_rw*/;
  assign store_rdata = tbo_store_rdata;
  logic         tbo_store_miss /*verilator public_flat_rw*/;
  assign store_miss = tbo_store_miss;
  logic         tbo_ch_active /*verilator public_flat_rw*/;
  assign ch_active = tbo_ch_active;
  logic         tbi_store_busy /*verilator public_flat_rd*/;
  assign tbi_store_busy = store_busy;
  logic [4:0]   tbi_store_busy_slot /*verilator public_flat_rd*/;
  assign tbi_store_busy_slot = store_busy_slot;
  logic         tbo_req_valid /*verilator public_flat_rw*/;
  assign req_valid = tbo_req_valid;
  logic [30:0]  tbo_req_tag /*verilator public_flat_rw*/;
  assign req_tag = tbo_req_tag;
  logic         tbo_req_post /*verilator public_flat_rw*/;
  assign req_post = tbo_req_post;
  logic         tbo_ch_waiting /*verilator public_flat_rw*/;
  assign ch_waiting = tbo_ch_waiting;
  logic         tbi_store_deny /*verilator public_flat_rd*/;
  assign tbi_store_deny = store_deny;
  logic [4:0]   tbo_ch_slot /*verilator public_flat_rw*/;
  assign ch_slot = tbo_ch_slot;
  logic         tbo_ch_wrote /*verilator public_flat_rw*/;
  assign ch_wrote = tbo_ch_wrote;
  logic         tbo_ch_hit /*verilator public_flat_rw*/;
  assign ch_hit = tbo_ch_hit;
  logic         tbi_kbd_strobe /*verilator public_flat_rd*/;
  assign tbi_kbd_strobe = kbd_strobe;
  logic [23:0]  tbi_kbd_code /*verilator public_flat_rd*/;
  assign tbi_kbd_code = kbd_code;
  logic [6:0]   tbi_mouse_lines /*verilator public_flat_rd*/;
  assign tbi_mouse_lines = mouse_lines;
  logic         tbi_n_boot2 /*verilator public_flat_rd*/;
  assign tbi_n_boot2 = n_boot2;
  logic         tbi_no_auto_boot /*verilator public_flat_rd*/;
  assign tbi_no_auto_boot = no_auto_boot;
  logic         tbo_ser_reset /*verilator public_flat_rw*/;
  assign ser_reset = tbo_ser_reset;
  logic [7:0]   tbo_ser_mode1 /*verilator public_flat_rw*/;
  assign ser_mode1 = tbo_ser_mode1;
  logic [7:0]   tbo_ser_mode2 /*verilator public_flat_rw*/;
  assign ser_mode2 = tbo_ser_mode2;
  logic [7:0]   tbo_ser_cmd /*verilator public_flat_rw*/;
  assign ser_cmd = tbo_ser_cmd;
  logic         tbo_ser_tx_strobe /*verilator public_flat_rw*/;
  assign ser_tx_strobe = tbo_ser_tx_strobe;
  logic [7:0]   tbo_ser_tx_data /*verilator public_flat_rw*/;
  assign ser_tx_data = tbo_ser_tx_data;
  logic         tbi_ser_tx_take /*verilator public_flat_rd*/;
  assign tbi_ser_tx_take = ser_tx_take;
  logic         tbi_ser_tx_done /*verilator public_flat_rd*/;
  assign tbi_ser_tx_done = ser_tx_done;
  logic         tbi_ser_rx_strobe /*verilator public_flat_rd*/;
  assign tbi_ser_rx_strobe = ser_rx_strobe;
  logic [7:0]   tbi_ser_rx_data /*verilator public_flat_rd*/;
  assign tbi_ser_rx_data = ser_rx_data;
  logic         tbi_ser_rx_end /*verilator public_flat_rd*/;
  assign tbi_ser_rx_end = ser_rx_end;
  logic         tbi_ser_rx_parity /*verilator public_flat_rd*/;
  assign tbi_ser_rx_parity = ser_rx_parity;
  logic         tbi_ser_rx_framing /*verilator public_flat_rd*/;
  assign tbi_ser_rx_framing = ser_rx_framing;
  logic         tbi_ser_plugged /*verilator public_flat_rd*/;
  assign tbi_ser_plugged = ser_plugged;
  logic [7:0]   tbo_ser_status /*verilator public_flat_rw*/;
  assign ser_status = tbo_ser_status;
  logic [25:0]  tbo_ser_syn_face /*verilator public_flat_rw*/;
  assign ser_syn_face = tbo_ser_syn_face;
  logic [15:0]  tbi_chaos_address /*verilator public_flat_rd*/;
  assign tbi_chaos_address = chaos_address;
  logic         tbo_chaos_tx_go /*verilator public_flat_rw*/;
  assign chaos_tx_go = tbo_chaos_tx_go;
  logic [8:0]   tbo_chaos_tx_len /*verilator public_flat_rw*/;
  assign chaos_tx_len = tbo_chaos_tx_len;
  logic         tbo_chaos_tx_valid /*verilator public_flat_rw*/;
  assign chaos_tx_valid = tbo_chaos_tx_valid;
  logic [15:0]  tbo_chaos_tx_word /*verilator public_flat_rw*/;
  assign chaos_tx_word = tbo_chaos_tx_word;
  logic         tbo_chaos_tx_clear /*verilator public_flat_rw*/;
  assign chaos_tx_clear = tbo_chaos_tx_clear;
  logic         tbo_chaos_reset /*verilator public_flat_rw*/;
  assign chaos_reset = tbo_chaos_reset;
  logic [15:0]  tbo_chaos_csr /*verilator public_flat_rw*/;
  assign chaos_csr = tbo_chaos_csr;
  logic         tbi_chaos_rx_valid /*verilator public_flat_rd*/;
  assign tbi_chaos_rx_valid = chaos_rx_valid;
  logic [15:0]  tbi_chaos_rx_word /*verilator public_flat_rd*/;
  assign tbi_chaos_rx_word = chaos_rx_word;
  logic         tbi_chaos_rx_done /*verilator public_flat_rd*/;
  assign tbi_chaos_rx_done = chaos_rx_done;
  logic [12:0]  tbi_chaos_rx_bits /*verilator public_flat_rd*/;
  assign tbi_chaos_rx_bits = chaos_rx_bits;
  logic         tbi_chaos_rx_crc /*verilator public_flat_rd*/;
  assign tbi_chaos_rx_crc = chaos_rx_crc;
  logic         tbi_chaos_rx_lost /*verilator public_flat_rd*/;
  assign tbi_chaos_rx_lost = chaos_rx_lost;
  logic         tbi_chaos_tx_done /*verilator public_flat_rd*/;
  assign tbi_chaos_tx_done = chaos_tx_done;
  logic         tbi_chaos_tx_abort /*verilator public_flat_rd*/;
  assign tbi_chaos_tx_abort = chaos_tx_abort;
  logic         tbi_chaos_cbl_busy /*verilator public_flat_rd*/;
  assign tbi_chaos_cbl_busy = chaos_cbl_busy;
  logic [11:0]  tbo_chaos_bits /*verilator public_flat_rw*/;
  assign chaos_bits = tbo_chaos_bits;
  logic         tbo_iob_intr /*verilator public_flat_rw*/;
  assign iob_intr = tbo_iob_intr;
  logic [7:0]   tbo_iob_vector /*verilator public_flat_rw*/;
  assign iob_vector = tbo_iob_vector;
  logic         tbo_audio /*verilator public_flat_rw*/;
  assign audio = tbo_audio;
  logic [7:0]   tbo_csr_face /*verilator public_flat_rw*/;
  assign csr_face = tbo_csr_face;
  logic [11:0]  tbo_mouse_x /*verilator public_flat_rw*/;
  assign mouse_x = tbo_mouse_x;
  logic [11:0]  tbo_mouse_y /*verilator public_flat_rw*/;
  assign mouse_y = tbo_mouse_y;
  logic         tbo_clock_ready /*verilator public_flat_rw*/;
  assign clock_ready = tbo_clock_ready;
  logic [15:0]  tbo_interval /*verilator public_flat_rw*/;
  assign interval = tbo_interval;
  logic [6:0]   tbi_boards /*verilator public_flat_rd*/;
  assign tbi_boards = boards;
  logic         tbi_tv_lispm /*verilator public_flat_rd*/;
  assign tbi_tv_lispm = tv_lispm;
  logic         tbi_color_tv /*verilator public_flat_rd*/;
  assign tbi_color_tv = color_tv;
  logic [3:0]   tbi_tv_map_a /*verilator public_flat_rd*/;
  assign tbi_tv_map_a = tv_map_a;
  logic [23:0]  tbo_tv_map_q /*verilator public_flat_rw*/;
  assign tv_map_q = tbo_tv_map_q;
  logic [23:0]  tbo_tv_color_map_q /*verilator public_flat_rw*/;
  assign tv_color_map_q = tbo_tv_color_map_q;
  logic [3:0]   tbi_disp_map_a /*verilator public_flat_rd*/;
  assign tbi_disp_map_a = disp_map_a;
  logic [23:0]  tbo_disp_color_map_q /*verilator public_flat_rw*/;
  assign disp_color_map_q = tbo_disp_color_map_q;
  logic [13:0]  tbo_pc /*verilator public_flat_rw*/;
  assign pc = tbo_pc;
  logic [13:0]  tbo_lpc /*verilator public_flat_rw*/;
  assign lpc = tbo_lpc;
  logic [13:0]  tbo_opc /*verilator public_flat_rw*/;
  assign opc = tbo_opc;
  logic [31:0]  tbo_st /*verilator public_flat_rw*/;
  assign st = tbo_st;
  logic [47:0]  tbo_ir /*verilator public_flat_rw*/;
  assign ir = tbo_ir;
  logic [31:0]  tbo_a /*verilator public_flat_rw*/;
  assign a = tbo_a;
  logic [31:0]  tbo_m /*verilator public_flat_rw*/;
  assign m = tbo_m;
  logic [31:0]  tbo_alu /*verilator public_flat_rw*/;
  assign alu = tbo_alu;
  logic [31:0]  tbo_r /*verilator public_flat_rw*/;
  assign r = tbo_r;
  logic [31:0]  tbo_ob /*verilator public_flat_rw*/;
  assign ob = tbo_ob;
  logic [31:0]  tbo_q /*verilator public_flat_rw*/;
  assign q = tbo_q;
  logic [9:0]   tbo_dc /*verilator public_flat_rw*/;
  assign dc = tbo_dc;
  logic [25:0]  tbo_lc /*verilator public_flat_rw*/;
  assign lc = tbo_lc;
  logic [31:0]  tbo_vma /*verilator public_flat_rw*/;
  assign vma = tbo_vma;
  logic [31:0]  tbo_md /*verilator public_flat_rw*/;
  assign md = tbo_md;
  logic         tbo_vmaok /*verilator public_flat_rw*/;
  assign vmaok = tbo_vmaok;
  logic         tbo_jcond /*verilator public_flat_rw*/;
  assign jcond = tbo_jcond;
  logic         tbo_nop /*verilator public_flat_rw*/;
  assign nop = tbo_nop;
  logic         tbo_pcs1 /*verilator public_flat_rw*/;
  assign pcs1 = tbo_pcs1;
  logic         tbo_pcs0 /*verilator public_flat_rw*/;
  assign pcs0 = tbo_pcs0;
  logic         tbo_iwrited /*verilator public_flat_rw*/;
  assign iwrited = tbo_iwrited;
  logic         tbo_promenable /*verilator public_flat_rw*/;
  assign promenable = tbo_promenable;
  logic         tbo_clock_edge /*verilator public_flat_rw*/;
  assign clock_edge = tbo_clock_edge;
  logic         tbo_wrcyc /*verilator public_flat_rw*/;
  assign wrcyc = tbo_wrcyc;
  logic         tbo_device /*verilator public_flat_rw*/;
  assign device = tbo_device;
  logic         tbo_dev_rq /*verilator public_flat_rw*/;
  assign dev_rq = tbo_dev_rq;
  logic         tbo_dev_write /*verilator public_flat_rw*/;
  assign dev_write = tbo_dev_write;
  logic [21:0]  tbo_phys /*verilator public_flat_rw*/;
  assign phys = tbo_phys;
  logic [31:0]  tbo_dev_wdata /*verilator public_flat_rw*/;
  assign dev_wdata = tbo_dev_wdata;
  logic         tbi_device_ack /*verilator public_flat_rd*/;
  assign tbi_device_ack = device_ack;
  logic [31:0]  tbi_device_rdata /*verilator public_flat_rd*/;
  assign tbi_device_rdata = device_rdata;
  logic         tbo_promdisable /*verilator public_flat_rw*/;
  assign promdisable = tbo_promdisable;
  logic         tbo_ub_msyn /*verilator public_flat_rw*/;
  assign ub_msyn = tbo_ub_msyn;
  logic         tbo_ub_ssyn_o /*verilator public_flat_rw*/;
  assign ub_ssyn_o = tbo_ub_ssyn_o;
  logic [2:0]   tbo_arb_stage /*verilator public_flat_rw*/;
  assign arb_stage = tbo_arb_stage;
  logic         tbo_n_memrq_o /*verilator public_flat_rw*/;
  assign n_memrq_o = tbo_n_memrq_o;
  logic         tbo_n_memack_o /*verilator public_flat_rw*/;
  assign n_memack_o = tbo_n_memack_o;
  logic         tbo_n_memgrant_o /*verilator public_flat_rw*/;
  assign n_memgrant_o = tbo_n_memgrant_o;
  logic         tbo_mbusy_o /*verilator public_flat_rw*/;
  assign mbusy_o = tbo_mbusy_o;
  logic         tbo_mbusy_sync_o /*verilator public_flat_rw*/;
  assign mbusy_sync_o = tbo_mbusy_sync_o;
  logic [17:0]  tbo_ub_addr_o /*verilator public_flat_rw*/;
  assign ub_addr_o = tbo_ub_addr_o;
  logic [15:0]  tbo_ub_rdata_o /*verilator public_flat_rw*/;
  assign ub_rdata_o = tbo_ub_rdata_o;
  logic [2:0]   tbo_ub_ssyn_by /*verilator public_flat_rw*/;
  assign ub_ssyn_by = tbo_ub_ssyn_by;
  logic         tbo_n_loadmd_o /*verilator public_flat_rw*/;
  assign n_loadmd_o = tbo_n_loadmd_o;
  logic         tbo_rdcyc_o /*verilator public_flat_rw*/;
  assign rdcyc_o = tbo_rdcyc_o;
  logic         tbo_nxm /*verilator public_flat_rw*/;
  assign nxm = tbo_nxm;
  logic         tbo_unibus /*verilator public_flat_rw*/;
  assign unibus = tbo_unibus;
  logic         tbo_memstart /*verilator public_flat_rw*/;
  assign memstart = tbo_memstart;
  logic         tbo_timed_out /*verilator public_flat_rw*/;
  assign timed_out = tbo_timed_out;
  logic         tbo_machrun /*verilator public_flat_rw*/;
  assign machrun = tbo_machrun;
  logic         tbo_errhalt /*verilator public_flat_rw*/;
  assign errhalt = tbo_errhalt;
  logic         tbo_stathalt /*verilator public_flat_rw*/;
  assign stathalt = tbo_stathalt;
  logic         tbo_n_boot_o /*verilator public_flat_rw*/;
  assign n_boot_o = tbo_n_boot_o;
  logic         tbi_con_req /*verilator public_flat_rd*/;
  assign tbi_con_req = con_req;
  logic         tbo_con_gnt /*verilator public_flat_rw*/;
  assign con_gnt = tbo_con_gnt;
  logic         tbi_con_msyn /*verilator public_flat_rd*/;
  assign tbi_con_msyn = con_msyn;
  logic         tbi_con_write /*verilator public_flat_rd*/;
  assign tbi_con_write = con_write;
  logic [17:0]  tbi_con_addr /*verilator public_flat_rd*/;
  assign tbi_con_addr = con_addr;
  logic [15:0]  tbi_con_wdata /*verilator public_flat_rd*/;
  assign tbi_con_wdata = con_wdata;
  logic         tbo_con_ssyn /*verilator public_flat_rw*/;
  assign con_ssyn = tbo_con_ssyn;
  logic [15:0]  tbo_con_rdata /*verilator public_flat_rw*/;
  assign con_rdata = tbo_con_rdata;
  logic         tbi_dbg_in_req /*verilator public_flat_rd*/;
  assign tbi_dbg_in_req = dbg_in_req;
  logic         tbi_dbg_in_wr /*verilator public_flat_rd*/;
  assign tbi_dbg_in_wr = dbg_in_wr;
  logic [1:0]   tbi_dbg_in_a /*verilator public_flat_rd*/;
  assign tbi_dbg_in_a = dbg_in_a;
  logic [15:0]  tbi_dbd_in /*verilator public_flat_rd*/;
  assign tbi_dbd_in = dbd_in;
  logic         tbo_dbg_in_ack /*verilator public_flat_rw*/;
  assign dbg_in_ack = tbo_dbg_in_ack;
  logic [15:0]  tbo_dbd_out /*verilator public_flat_rw*/;
  assign dbd_out = tbo_dbd_out;
  logic [1:0]   tbo_dbd_oe /*verilator public_flat_rw*/;
  assign dbd_oe = tbo_dbd_oe;
  logic         tbo_dbgout_req /*verilator public_flat_rw*/;
  assign dbgout_req = tbo_dbgout_req;
  logic         tbo_dbgout_wr /*verilator public_flat_rw*/;
  assign dbgout_wr = tbo_dbgout_wr;
  logic [1:0]   tbo_dbgout_a /*verilator public_flat_rw*/;
  assign dbgout_a = tbo_dbgout_a;
  logic [15:0]  tbo_dbgout_dbd /*verilator public_flat_rw*/;
  assign dbgout_dbd = tbo_dbgout_dbd;
  logic         tbi_dbgout_ack /*verilator public_flat_rd*/;
  assign tbi_dbgout_ack = dbgout_ack;
  logic [15:0]  tbi_dbgout_dbd_in /*verilator public_flat_rd*/;
  assign tbi_dbgout_dbd_in = dbgout_dbd_in;
  logic         tbi_dbgout_live /*verilator public_flat_rd*/;
  assign tbi_dbgout_live = dbgout_live;
  logic         tbo_debuggee_reset /*verilator public_flat_rw*/;
  assign debuggee_reset = tbo_debuggee_reset;
  logic         tbo_timeout_inhibit /*verilator public_flat_rw*/;
  assign timeout_inhibit = tbo_timeout_inhibit;
  logic         tbi_dbg_rst /*verilator public_flat_rd*/;
  assign tbi_dbg_rst = dbg_rst;
  logic [31:0]  tbo_con_vma /*verilator public_flat_rw*/;
  assign con_vma = tbo_con_vma;
  logic [31:0]  tbo_con_q /*verilator public_flat_rw*/;
  assign con_q = tbo_con_q;
  logic [31:0]  tbo_con_md /*verilator public_flat_rw*/;
  assign con_md = tbo_con_md;
  logic [17:0]  tbi_con_ro_addr /*verilator public_flat_rd*/;
  assign tbi_con_ro_addr = con_ro_addr;
  logic [47:0]  tbo_con_ro_data /*verilator public_flat_rw*/;
  assign con_ro_data = tbo_con_ro_data;
  logic [17:0]  tbo_con_ro_echo /*verilator public_flat_rw*/;
  assign con_ro_echo = tbo_con_ro_echo;
  logic         tbo_mem_req /*verilator public_flat_rw*/;
  assign mem_req = tbo_mem_req;
  logic         tbo_mem_write /*verilator public_flat_rw*/;
  assign mem_write = tbo_mem_write;
  logic [31:0]  tbo_mem_addr /*verilator public_flat_rw*/;
  assign mem_addr = tbo_mem_addr;
  logic [31:0]  tbo_mem_wdata /*verilator public_flat_rw*/;
  assign mem_wdata = tbo_mem_wdata;
  logic         tbi_mem_done /*verilator public_flat_rd*/;
  assign tbi_mem_done = mem_done;
  logic [31:0]  tbi_mem_rdata /*verilator public_flat_rd*/;
  assign tbi_mem_rdata = mem_rdata;
  logic         tbi_port_read_ack /*verilator public_flat_rd*/;
  assign tbi_port_read_ack = port_read_ack;
  logic         tbi_port_write_ack /*verilator public_flat_rd*/;
  assign tbi_port_write_ack = port_write_ack;
endmodule


/* verilator lint_on UNDRIVEN */
/* verilator lint_on UNUSEDPARAM */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */

`default_nettype wire
