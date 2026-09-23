// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A board's fault top level, simulated, for `tb/cadr_fault_tb.cpp`.  One of
// `CADR_BOARD_ARTY`, `CADR_BOARD_CORA` or `CADR_BOARD_DE25` says which.  The
// processing system is `tb/cadr_ps7_sim.sv` or `tb/cadr_de25_hps_sim.sv`, the
// clock generators are the lint stubs, which pass the oscillator through, and
// the top level is the board's own file unchanged.
//
// What comes out is what a person and a program can see: the lamp pins as
// the board carries them, split into the pins that must blink and the pins
// that must stay dark, and the tally the programs read first.  The tally is
// not on a pin, so it is taken by name, as `tb/cadr_board_reset_harness.sv`
// takes the machine's reset; so is the DE25-Nano's warm-reset
// acknowledgment, which goes to the processor and to no pin.

`default_nettype none

module cadr_fault_harness #(
    parameter int unsigned HALF_T = 64
) (
    input  var logic        clk,
    // The pins of every lamp that must blink, as the board drives them:
    // high to light on the Zynq boards, LOW to light on the DE25-Nano.
    output var logic [7:0]  blink,
    // The green and blue pins of the color lamps, which must never light.
    output var logic [3:0]  dark,
    // The tally as the processor reads it: EMIO 31:0 and 63:32 on a Zynq
    // board; on the DE25-Nano `h2f_gp_in` in the low word and zero above.
    output var logic [63:0] tally,
    // The DE25-Nano's warm-reset acknowledgment, low when given; high on the
    // Zynq boards, which have none.
    output var logic        warm_ack_n
);

  /* verilator lint_off PINCONNECTEMPTY */
`ifdef CADR_BOARD_ARTY
  logic [3:0] led;
  logic       led4_r, led4_g, led4_b, led5_r, led5_g, led5_b;
  cadr_arty_fault #(.HALF_T(HALF_T)) u_top (
      .sysclk(clk), .btn(4'b0000), .sw(2'b00),
      .led(led), .led4_r(led4_r), .led4_g(led4_g), .led4_b(led4_b),
      .led5_r(led5_r), .led5_g(led5_g), .led5_b(led5_b),
      .ja(),
      .hdmi_tx_clk_p(), .hdmi_tx_clk_n(), .hdmi_tx_d_p(), .hdmi_tx_d_n()
  );
  assign blink = {2'b00, led5_r, led4_r, led};
  assign dark  = {led5_b, led5_g, led4_b, led4_g};
  assign tally = u_top.gpio_i;
  assign warm_ack_n = 1'b1;
`elsif CADR_BOARD_CORA
  logic led0_r, led0_g, led0_b, led1_r, led1_g, led1_b;
  cadr_cora_fault #(.HALF_T(HALF_T)) u_top (
      .sysclk(clk), .btn(2'b00),
      .led0_r(led0_r), .led0_g(led0_g), .led0_b(led0_b),
      .led1_r(led1_r), .led1_g(led1_g), .led1_b(led1_b),
      .ja()
  );
  assign blink = {6'b000000, led1_r, led0_r};
  assign dark  = {led1_b, led1_g, led0_b, led0_g};
  assign tally = u_top.gpio_i;
  assign warm_ack_n = 1'b1;
`elsif CADR_BOARD_DE25
  logic [7:0] led;
  // KEY1 up: the buttons read high while released.
  cadr_de25_fault #(.HALF_T(HALF_T)) u_top (
      .clock50_0(clk), .btn(2'b11), .sw(4'b0000), .led(led),
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
  );
  assign blink = led;
  assign dark  = 4'b0000;
  assign tally = {32'd0, u_top.gp_in};
  assign warm_ack_n = u_top.warm_ack_n;
`endif
  /* verilator lint_on PINCONNECTEMPTY */

endmodule

`default_nettype wire
