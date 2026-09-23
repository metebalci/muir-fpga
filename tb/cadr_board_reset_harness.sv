// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A whole board's top level, simulated, for `tb/cadr_board_reset_tb.cpp`.
// One of `CADR_BOARD_ARTY`, `CADR_BOARD_CORA` or `CADR_BOARD_DE25` says
// which.  The processing system is `tb/cadr_ps7_sim.sv` or
// `tb/cadr_de25_hps_sim.sv`, the clock generators are the lint stubs, which
// pass the board's oscillator through, and everything else is the board's
// own file unchanged.  So what this holds is the top level's wiring, which
// nothing else simulates: which reset reaches which module.
//
// Two of the top level's own signals come out by name, because what they
// say is not on any pin: the machine's reset, and on the DE25-Nano whether
// the memory port is live.

`default_nettype none

module cadr_board_reset_harness #(
    parameter string PROM_HEX = "build/boot_prom.hex",
    parameter string SYNC_PROM_HEX = "build/sync_prom.hex"
) (
    input  var logic       clk,
    // The board's buttons as its pins carry them: BTN1 high while pressed
    // on the Zynq boards, KEY1 LOW while pressed on the DE25-Nano.
    input  var logic [1:0] btn,
    output var logic       mach_rst,
    output var logic       port_live
);

  /* verilator lint_off PINCONNECTEMPTY */
`ifdef CADR_BOARD_ARTY
  cadr_arty #(
      .PROM_HEX(PROM_HEX), .SYNC_PROM_HEX(SYNC_PROM_HEX), .DDR(1)
  ) u_top (
      .sysclk(clk), .btn({2'b00, btn}), .sw(2'b00),
      .led(), .led4_r(), .led4_g(), .led4_b(), .led5_r(), .led5_g(), .led5_b(),
      .ja(),
      .hdmi_tx_clk_p(), .hdmi_tx_clk_n(), .hdmi_tx_d_p(), .hdmi_tx_d_n()
  );
  assign port_live = 1'b1;
`elsif CADR_BOARD_CORA
  cadr_cora #(
      .PROM_HEX(PROM_HEX), .SYNC_PROM_HEX(SYNC_PROM_HEX), .DDR(1)
  ) u_top (
      .sysclk(clk), .btn(btn),
      .led0_r(), .led0_g(), .led0_b(), .led1_r(), .led1_g(), .led1_b(),
      .ja()
  );
  assign port_live = 1'b1;
`elsif CADR_BOARD_DE25
  cadr_de25 #(
      .PROM_HEX(PROM_HEX), .SYNC_PROM_HEX(SYNC_PROM_HEX)
  ) u_top (
      .clock50_0(clk), .btn(btn), .sw(4'b0000), .led(),
      .jp1_pin31(), .jp1_pin32(), .jp1_pin33(), .jp1_pin34(),
      .jp1_pin35(), .jp1_pin36(), .jp1_pin37(), .jp1_pin38(),
      .lpddr4a_ca(), .lpddr4a_cs_n(), .lpddr4a_cke(), .lpddr4a_ck(),
      .lpddr4a_ck_n(), .lpddr4a_dq(), .lpddr4a_dqs(), .lpddr4a_dqs_n(),
      .lpddr4a_dm(), .lpddr4a_reset_n(), .lpddr4a_rzq(1'b0),
      .lpddr4a_refclk_p(1'b0), .hps_clk_25(1'b0), .hps_key(), .hps_led(),
      .hps_enet_tx_clk(), .hps_enet_tx_ctl(), .hps_enet_tx_data(),
      .hps_enet_rx_clk(1'b0), .hps_enet_rx_ctl(1'b0), .hps_enet_rx_data(4'd0),
      .hps_enet_mdio(), .hps_enet_mdc(), .hps_uart_tx(), .hps_uart_rx(1'b1),
      .hps_sd_clk(), .hps_sd_cmd(), .hps_sd_data(), .hps_usb_clk(1'b0),
      .hps_usb_stp(), .hps_usb_dir(1'b0), .hps_usb_nxt(1'b0), .hps_usb_data(),
      .hps_gsensor_int(), .hps_i2c_scl(), .hps_i2c_sda()
`ifdef CADR_DE25_HDMI
      ,
      .hdmi_d(), .hdmi_pclk(), .hdmi_de(), .hdmi_hsync(), .hdmi_vsync(),
      .hdmi_scl(), .hdmi_sda()
`endif
  );
  assign port_live = u_top.port_live;
`endif
  /* verilator lint_on PINCONNECTEMPTY */

  assign mach_rst = u_top.mach_rst;

endmodule

`default_nettype wire
