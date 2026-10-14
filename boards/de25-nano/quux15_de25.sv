// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15 ON THE DE25-NANO** (contract G3 revision 15, §12.3):
// `rtl/machine/quux15_core.sv`, the pipelined machine, on this board's
// processor system, at the period its fit closes.  Revisions 13 and 14 and
// the CADR stay `cadr_de25.sv`'s; this machine has another face to the
// board, so it has its own top level, as `boards/kria-kr260/quux15_kr260.sv`
// has beside `cadr_kr260.sv`, with the same core and the same modules around
// it, and `cadr_de25.sv`'s facts of the board and the part kept as they are.
// It is always the whole board: the processor, its LPDDR4 and the display,
// what `cadr_de25.sv` builds with `CADR_DE25_DDR` and `CADR_DE25_HDMI`, which
// this file does not read.
//
//   - **THE CLOCK IS THE BOARD'S 50 MHz, ON `CLOCK0_50`, THROUGH AN I/O
//     PLL** that `boards/de25-nano/quartus/build.sh` generates from Altera's
//     IP at every build, as for `cadr_de25.sv`, here at the period: `PERIOD`,
//     in units of 0.5 ns, which the machine is told (`period`, A15b.12) and
//     the console face reports, and from which `build.sh` asks the PLL for
//     2,000 / `PERIOD` MHz.  The flow reads the period back out of the timing
//     analyzer and refuses a build whose machine clock is not the one asked.
//     The Reset Release holds the PLL in reset until the device is in user
//     mode (`cadr_de25.sv` has why it is the IP and not the primitive).
//   - **THE PROCESSOR SYSTEM IS `cadr_de25_hps`**, as `hps.tcl` describes it
//     and `build.sh` generates it, every bridge clocked by the machine's
//     clock and reset by the processor's `h2f_reset`.
//   - **THE CACHE IS 16,384 WORDS** (Q-MP6): 1,024 sets of two eight-word
//     lines.
//   - **MAIN MEMORY IS ON THE FPGA-TO-SDRAM BRIDGE**, 32M words of packed
//     storage at `cadr_ddr_map.sv`'s revision-13 base (`QUUX13_MAIN_BASE`,
//     0xA000_0000), where revisions 13 and 14 keep theirs and the board's
//     revision-13 device tree reserves it, the frame buffer at the display
//     base: the machine's own 64-bit master (`quux15_axi_master.sv`, inside
//     the core's port) on the share's port 0, through
//     `rtl/plumbing/quux15_f2sdram_port.sv`, the gate in front of it.  Its
//     writes carry one AXI ID, the share's 0, so the bridge answers them in
//     order.
//   - **THE MACHINE WAITS FOR ITS MEMORY**, as `cadr_de25.sv`'s does: the
//     core is held in reset from the fabric's reset until the port has been
//     live once (`cadr_f2sdram_gate.sv`'s `may_start`), a request.  And a
//     reset the board asks for --- KEY1, the console's RESET key --- is a
//     request too, which the core takes once its memory port has drained, so
//     it never cuts a transaction of the core's master in half
//     (`quux15_core.sv`'s `rq_*`).  **THE PROCESSOR'S RESET AND THE PLL'S
//     LOCK RESET THE MACHINE AT ONCE**, as the Zynq boards' revision 15 is
//     reset with its port: the bridge forgets what it had of the machine's
//     transactions, and the core's port would wait for their answers for
//     ever.
//   - **THE DISK PACKS ON THE HPS-TO-FPGA BRIDGE AND THE SHARE'S PORT 1**, as
//     `cadr_de25.sv` has them: block-disk's block store (the core's
//     `quux15_block_walk.sv`) served by `cadr_disk_pack.sv`, its registers at
//     the bridge's +0x0000, its bursts on the share.
//   - **THE KEYBOARD AND THE MOUSE** at the bridge's +0x3000:
//     `cadr_input_cables.sv`, its mouse's step from the period, its word and
//     the mouse's seven lines to the core's register page.
//   - **THE FILE DEVICE'S PAGE AND THE REAL-TIME CLOCK'S SETTER** at the
//     bridge's +0x4000 (`quux_fd_face.sv`, IDENT "QF13" as revisions 13 and 14
//     have it), onto the core's host side.
//   - **THE CONSOLE FACE ON THE LIGHTWEIGHT BRIDGE** at its +0x0000
//     (`rtl/plumbing/quux15_face.sv`), where `cadr_de25.sv` has the console;
//     the debug cable's page at +0x1000 and every other address answered with
//     a constant (`cadr_gp0_default.sv`).  The build stamp reads all ones,
//     "this fabric cannot say", as on `cadr_de25.sv`: the stamp is the
//     bitstream's USERCODE.
//   - **THE DISPLAY OUTPUT ON THE SHARE'S PORT 2 AND THE ADV7513**, as
//     `cadr_de25.sv` has it: `cadr_display_out.sv` reading the video
//     controller's frame buffer at the display base, VESA's 1280 by 1024 at
//     60 Hz on the fabric's pixel PLL, the transmitter written over its two
//     wires by `cadr_adv7513.sv`.  The video controller is the board's 1280
//     by 1024 (contract HD); word 210's black-on-white reaches the picture;
//     the console face's words 33 to 36 drive the display and its word 42
//     reads and clears its two sticky bits.
//   - **NO NETWORK**: QUUX has no Chaosnet cable.  The core's interface
//     (`quux15_chaos.sv`) is built and its cable tied off as the Kria
//     KR260's is: a frame sent is away at once, nothing arrives, and the
//     address switches read 0.  The bridge's network and serial line pages
//     are answered with a constant.  No debug cable either (contract Q5):
//     JP1's eight pads undriven, held low by the project's pull-downs.
//   - **THE KEYS, THE SWITCH AND THE LAMPS KEEP `cadr_de25.sv`'s MEANINGS
//     WHERE REVISION 15 HAS THE SIGNAL**:
//       KEY1   the fabric's reset, and the machine's once its memory port
//              has drained (the resets, below).
//       KEY0   unused: revision 15 has no `-BOOT2`; the console's mode
//              register and the keyboard's boot word boot it.
//       SW0    unused: revision 15 has no no-auto-boot; it comes out of reset
//              running, and the console's word 1 says so.  SW1 to SW3 unused.
//       LEDR0  the machine is running, not halted (`obs_halted` clear):
//              revision 15 has no `MACHRUN`.
//       LEDR1  the fabric is clocked: the slow blink, or the PLL's lock.
//       LEDR2  microcycles retiring: the fast blink, or held after each.
//       LEDR3  the disk: lit while block-disk moves a block, stretched.
//       LEDR4  an error halt (`obs_errhalt`).
//       LEDR5  dark: revision 15 has no PROM select to show.
//       LEDR6  the memory port open.
//       LEDR7  dark.
//     The eight are lit when driven low (`cadr_de25.sv`), so the row is
//     inverted at the pins.
//   - **THE TALLY ON THE GPI**: `cadr_mem_count.sv` at the bridge's
//     handshakes carrying the machine's ID, on `h2f_gp_in` by the halves
//     `h2f_gp_out[1]` selects, as `cadr_de25.sv`'s.
//   - **EVERY TIME IN CLOCKS IS THE PERIOD'S** (the MP5a review's R9): the
//     mouse's step, the display's second, the lamp's hold and the disk lamp's
//     stretch, each turned into clocks here from `PERIOD`.
//
// What holds this file: `build/quux15_de25.pass` lints it as the flow builds
// it and simulates it around the shells of `tb/cadr_de25_sim_stubs.sv` and
// `tb/quux15_core_shell.sv` (`tb/quux15_de25_top_tb.cpp`);
// `build/quux15_de25_param.pass` reads its figures at the instances; and
// `tools/de25_faces_check.py --quux15` reads its faces' places, shapes and
// resets.

`default_nettype none

module quux15_de25 #(
    parameter string PROM_HEX = "build/quux15_transfer_prom.hex",
    // **THE PERIOD**, in units of 0.5 ns: the one place it is decided on
    // this board, which `build.sh` sets from `PERIOD_NS` and asks the PLL
    // for.  27 ns, the board's provisional period in the goldens, until its
    // binding fit sets it.
    parameter int unsigned PERIOD = 54
) (
    // `CLOCK0_50`, 50 MHz, on the 1.1 V bank with the switches and the LEDs.
    input  var logic       clock50_0,
    // `KEY[1:0]`, debounced on the board and low while pressed.
    input  var logic [1:0] btn,
    // `SW[3:0]`, which revision 15 gives no meaning.
    input  var logic [3:0] sw,
    // `LEDR[7:0]`, lit when driven low.
    output var logic [7:0] led,
    // JP1 pins 31 to 38, the CADR's debug cable, which QUUX has not got.
    inout  wire  logic     jp1_pin31,
    inout  wire  logic     jp1_pin32,
    inout  wire  logic     jp1_pin33,
    inout  wire  logic     jp1_pin34,
    inout  wire  logic     jp1_pin35,
    inout  wire  logic     jp1_pin36,
    inout  wire  logic     jp1_pin37,
    inout  wire  logic     jp1_pin38,
    // The processor's LPDDR4 bank, as `cadr_de25.sv` names it.
    output var logic [5:0]  lpddr4a_ca,
    output var logic        lpddr4a_cs_n,
    output var logic        lpddr4a_cke,
    output var logic        lpddr4a_ck,
    output var logic        lpddr4a_ck_n,
    inout  wire  logic [31:0] lpddr4a_dq,
    inout  wire  logic [3:0]  lpddr4a_dqs,
    inout  wire  logic [3:0]  lpddr4a_dqs_n,
    inout  wire  logic [3:0]  lpddr4a_dm,
    output var logic        lpddr4a_reset_n,
    input  var logic        lpddr4a_rzq,
    input  var logic        lpddr4a_refclk_p,
    // The processor's own pins, as `hps.tcl` muxes them.
    input  var logic        hps_clk_25,
    inout  wire  logic      hps_key,
    inout  wire  logic      hps_led,
    output var logic        hps_enet_tx_clk,
    output var logic        hps_enet_tx_ctl,
    output var logic [3:0]  hps_enet_tx_data,
    input  var logic        hps_enet_rx_clk,
    input  var logic        hps_enet_rx_ctl,
    input  var logic [3:0]  hps_enet_rx_data,
    inout  wire  logic      hps_enet_mdio,
    output var logic        hps_enet_mdc,
    output var logic        hps_uart_tx,
    input  var logic        hps_uart_rx,
    output var logic        hps_sd_clk,
    inout  wire  logic      hps_sd_cmd,
    inout  wire  logic [3:0] hps_sd_data,
    input  var logic        hps_usb_clk,
    output var logic        hps_usb_stp,
    input  var logic        hps_usb_dir,
    input  var logic        hps_usb_nxt,
    inout  wire  logic [7:0] hps_usb_data,
    inout  wire  logic      hps_gsensor_int,
    inout  wire  logic      hps_i2c_scl,
    inout  wire  logic      hps_i2c_sda,
    // The ADV7513's side, as `cadr_de25.sv` has it, and the same five pins
    // the board has that this design leaves out (the interrupt and audio).
    output var logic [23:0] hdmi_d,
    output var logic        hdmi_pclk,
    output var logic        hdmi_de,
    output var logic        hdmi_hsync,
    output var logic        hdmi_vsync,
    inout  wire  logic      hdmi_scl,
    inout  wire  logic      hdmi_sda
);

  // The machine's period in 0.5 ns, seven bits at the core (`period`).
  if (PERIOD < 20 || PERIOD > 127) begin : g_period
    $error("PERIOD is %0d half-nanoseconds; the core takes 10 to 63.5 ns", PERIOD);
  end

  // **THE BOARD'S MAP**: `cadr_ddr_map.sv` with `CADR_DDR_MAP_DE25_NANO`, which
  // every DE25-Nano flow defines.  Elaboration stops if the package gives
  // another board's bases.
  localparam logic [31:0] MAIN_BASE    = 32'hA000_0000;
  localparam logic [31:0] DISPLAY_BASE = 32'hB400_0000;
  if (cadr_ddr_map::QUUX13_MAIN_BASE != MAIN_BASE || cadr_ddr_map::DISPLAY_BASE != DISPLAY_BASE) begin : g_map
    $error("cadr_ddr_map's bases are %h and %h, and the DE25-Nano's are %h and %h: define CADR_DDR_MAP_DE25_NANO",
           cadr_ddr_map::QUUX13_MAIN_BASE, cadr_ddr_map::DISPLAY_BASE, MAIN_BASE, DISPLAY_BASE);
  end
  // **MAIN MEMORY: 32M WORDS**, 512 units of 64K, packed storage from
  // `MAIN_BASE` (contract G2 §3), inside the board's reservation of 64M; the
  // console's word 37 says it.
  localparam int unsigned MAIN_WORDS = 32'h0200_0000;
  if (MAIN_WORDS > cadr_ddr_map::QUUX13_MAIN_WORDS_MAX) begin : g_main_words
    $error("the DE25-Nano's main memory is %0d words, and its reservation holds %0d",
           MAIN_WORDS, cadr_ddr_map::QUUX13_MAIN_WORDS_MAX);
  end

  // **THE CACHE: 16,384 WORDS** (Q-MP6), 1,024 sets.
  localparam int unsigned CACHE_WORDS = 16384;

  // **THE VIDEO CONTROLLER: 1280 BY 1024**, the board's raster (contract
  // HD): 40 words a line, 40,960 words of frame buffer.
  localparam int unsigned VIDEO_W = 1280;
  localparam int unsigned VIDEO_H = 1024;
  if (VIDEO_W / 32 * VIDEO_H > cadr_ddr_map::VIDEO_WORDS_MAX) begin : g_video_words
    $error("the DE25-Nano's video controller is %0d words, and the display's reservation holds %0d",
           VIDEO_W / 32 * VIDEO_H, cadr_ddr_map::VIDEO_WORDS_MAX);
  end

  // **THE BOARD NAME** (contract HD): feature words 20-24, "Machine Type
  // QUUX on DE25-Nano"; `cadr_de25.sv`'s for revision 13.
  localparam logic [8*64-1:0] BOARD = "DE25-Nano";

  // **THE TIMES IN CLOCKS, AT THE PERIOD** (R9), the period in 0.5 ns: the
  // display's second, rounded to the nearest clock; the lamp's hold and the
  // disk lamp's stretch, 2^22 ticks of 10 ns, rounded up; the mouse's step,
  // muir's 16,000 ns, rounded up.
  localparam int unsigned SECOND_T     = (2_000_000_000 + PERIOD / 2) / PERIOD;
  localparam int unsigned HOLD_T       = (83_886_080 + PERIOD - 1) / PERIOD;
  localparam int unsigned DISK_LIT_T   = (83_886_080 + PERIOD - 1) / PERIOD;
  localparam int unsigned MOUSE_STEP_T = (32_000 + PERIOD - 1) / PERIOD;

  // **WHICH BUILD THIS FABRIC IS**, the console face's word: all ones, "this
  // fabric cannot say", as `cadr_de25.sv` gives it.
  localparam logic [31:0] NO_BUILD_STAMP = 32'hFFFF_FFFF;

  // ------------------------------------------------------------ the clock
  logic ninit_done;
  cadr_de25_reset_release u_reset_release (
      .ninit_done(ninit_done)
  );

  // 50 MHz in, 2,000 / `PERIOD` MHz out: `build.sh` asks the IP for it.
  logic clk, pll_locked;
  cadr_de25_pll u_pll (
      .refclk  (clock50_0),
      .rst     (ninit_done),
      .outclk_0(clk),
      .locked  (pll_locked)
  );

  // ------------------------------------------------------------ the resets
  //
  // The fabric's: the PLL's lock and KEY1 (low while pressed), synchronized,
  // as `cadr_de25.sv`'s `rst`.  The bridges': `h2f_reset`, synchronized,
  // for the faces and the splitters, which take it alone (`cadr_de25.sv`
  // has why).  The PLL's lock alone, and KEY1 alone, for the machine's two
  // resets (below).
  logic [3:0] rst_sync, lock_sync, key_sync;
  logic       rst, lock_rst, key_req;
  always_ff @(posedge clk) begin
    rst_sync  <= {rst_sync[2:0], !pll_locked || !btn[1]};
    lock_sync <= {lock_sync[2:0], !pll_locked};
    key_sync  <= {key_sync[2:0], !btn[1]};
  end
  assign rst      = rst_sync[3];
  assign lock_rst = lock_sync[3];
  assign key_req  = key_sync[3];


  // ------------------------------------------- the processor, its memory
  //
  // As `hps.tcl` generates it and `cadr_de25.sv` wires it.
  logic        h2f_reset;
  logic [31:0] gp_out, gp_in;
  logic        warm_req_n, warm_ack_n;

  // `hps2fpga` and `lwhps2fpga`: AXI4, 32 bits, four bits of ID.
  logic [3:0]  h2f_awid, h2f_arid, h2f_bid, h2f_rid;
  logic [29:0] h2f_awaddr, h2f_araddr;
  logic [7:0]  h2f_awlen, h2f_arlen;
  logic [2:0]  h2f_awsize, h2f_arsize, h2f_awprot, h2f_arprot;
  logic [1:0]  h2f_awburst, h2f_arburst, h2f_bresp, h2f_rresp;
  logic        h2f_awlock, h2f_arlock;
  logic [3:0]  h2f_awcache, h2f_arcache, h2f_wstrb;
  logic [31:0] h2f_wdata, h2f_rdata;
  logic        h2f_awvalid, h2f_awready, h2f_wlast, h2f_wvalid, h2f_wready;
  logic        h2f_bvalid, h2f_bready, h2f_arvalid, h2f_arready;
  logic        h2f_rlast, h2f_rvalid, h2f_rready;
  logic [3:0]  lw_awid, lw_arid, lw_bid, lw_rid;
  logic [28:0] lw_awaddr, lw_araddr;
  logic [7:0]  lw_awlen, lw_arlen;
  logic [2:0]  lw_awsize, lw_arsize, lw_awprot, lw_arprot;
  logic [1:0]  lw_awburst, lw_arburst, lw_bresp, lw_rresp;
  logic        lw_awlock, lw_arlock;
  logic [3:0]  lw_awcache, lw_arcache, lw_wstrb;
  logic [31:0] lw_wdata, lw_rdata;
  logic        lw_awvalid, lw_awready, lw_wlast, lw_wvalid, lw_wready;
  logic        lw_bvalid, lw_bready, lw_arvalid, lw_arready;
  logic        lw_rlast, lw_rvalid, lw_rready;

  // `f2sdram`: AXI4, 64 bits, five bits of ID.
  logic [4:0]  f2s_awid, f2s_arid, f2s_bid, f2s_rid;
  logic [31:0] f2s_awaddr, f2s_araddr;
  logic [7:0]  f2s_awlen, f2s_arlen, f2s_awuser, f2s_aruser, f2s_wuser;
  logic [7:0]  f2s_buser, f2s_ruser, f2s_wstrb;
  logic [2:0]  f2s_awsize, f2s_arsize, f2s_awprot, f2s_arprot;
  logic [1:0]  f2s_awburst, f2s_arburst, f2s_bresp, f2s_rresp;
  logic        f2s_awlock, f2s_arlock;
  logic [3:0]  f2s_awcache, f2s_arcache, f2s_awqos, f2s_arqos;
  logic [3:0]  f2s_awregion, f2s_arregion;
  logic [63:0] f2s_wdata, f2s_rdata;
  logic        f2s_awvalid, f2s_awready, f2s_wlast, f2s_wvalid, f2s_wready;
  logic        f2s_bvalid, f2s_bready, f2s_arvalid, f2s_arready;
  logic        f2s_rlast, f2s_rvalid, f2s_rready;

  cadr_de25_hps u_hps (
      // LPDDR4A, by the controller's names.
      .emif_mem_0_mem_cs(lpddr4a_cs_n), .emif_mem_0_mem_ca(lpddr4a_ca),
      .emif_mem_0_mem_cke(lpddr4a_cke), .emif_mem_0_mem_dq(lpddr4a_dq),
      .emif_mem_0_mem_dqs_t(lpddr4a_dqs), .emif_mem_0_mem_dqs_c(lpddr4a_dqs_n),
      .emif_mem_0_mem_dmi(lpddr4a_dm),
      .emif_mem_ck_0_mem_ck_t(lpddr4a_ck), .emif_mem_ck_0_mem_ck_c(lpddr4a_ck_n),
      .emif_mem_reset_n_mem_reset_n(lpddr4a_reset_n),
      .emif_oct_0_oct_rzqin(lpddr4a_rzq), .emif_ref_clk_clk(lpddr4a_refclk_p),
      // The processor's pins.
      .hps_hps_io_hps_osc_clk(hps_clk_25),
      .hps_hps_io_sdmmc_data0(hps_sd_data[0]), .hps_hps_io_sdmmc_data1(hps_sd_data[1]),
      .hps_hps_io_sdmmc_cclk(hps_sd_clk),
      .hps_hps_io_sdmmc_data2(hps_sd_data[2]), .hps_hps_io_sdmmc_data3(hps_sd_data[3]),
      .hps_hps_io_sdmmc_cmd(hps_sd_cmd),
      .hps_hps_io_usb0_clk(hps_usb_clk), .hps_hps_io_usb0_stp(hps_usb_stp),
      .hps_hps_io_usb0_dir(hps_usb_dir),
      .hps_hps_io_usb0_data0(hps_usb_data[0]), .hps_hps_io_usb0_data1(hps_usb_data[1]),
      .hps_hps_io_usb0_nxt(hps_usb_nxt),
      .hps_hps_io_usb0_data2(hps_usb_data[2]), .hps_hps_io_usb0_data3(hps_usb_data[3]),
      .hps_hps_io_usb0_data4(hps_usb_data[4]), .hps_hps_io_usb0_data5(hps_usb_data[5]),
      .hps_hps_io_usb0_data6(hps_usb_data[6]), .hps_hps_io_usb0_data7(hps_usb_data[7]),
      .hps_hps_io_emac0_tx_clk(hps_enet_tx_clk), .hps_hps_io_emac0_tx_ctl(hps_enet_tx_ctl),
      .hps_hps_io_emac0_rx_clk(hps_enet_rx_clk), .hps_hps_io_emac0_rx_ctl(hps_enet_rx_ctl),
      .hps_hps_io_emac0_txd0(hps_enet_tx_data[0]), .hps_hps_io_emac0_txd1(hps_enet_tx_data[1]),
      .hps_hps_io_emac0_rxd0(hps_enet_rx_data[0]), .hps_hps_io_emac0_rxd1(hps_enet_rx_data[1]),
      .hps_hps_io_emac0_txd2(hps_enet_tx_data[2]), .hps_hps_io_emac0_txd3(hps_enet_tx_data[3]),
      .hps_hps_io_emac0_rxd2(hps_enet_rx_data[2]), .hps_hps_io_emac0_rxd3(hps_enet_rx_data[3]),
      .hps_hps_io_mdio0_mdio(hps_enet_mdio), .hps_hps_io_mdio0_mdc(hps_enet_mdc),
      .hps_hps_io_uart1_tx(hps_uart_tx), .hps_hps_io_uart1_rx(hps_uart_rx),
      .hps_hps_io_i2c1_sda(hps_i2c_sda), .hps_hps_io_i2c1_scl(hps_i2c_scl),
      .hps_hps_io_gpio28(hps_gsensor_int), .hps_hps_io_gpio40(hps_key),
      .hps_hps_io_gpio41(hps_led),
      // Resets and the two general-purpose words.
      .hps_h2f_reset_reset(h2f_reset),
      .hps_hps_gp_gp_in(gp_in), .hps_hps_gp_gp_out(gp_out),
      .hps_h2f_warm_reset_handshake_reset_req(warm_req_n),
      .hps_h2f_warm_reset_handshake_reset_ack(warm_ack_n),
      // The processor-to-fabric bridge.
      .hps_hps2fpga_axi_clock_clk(clk), .hps_hps2fpga_axi_reset_reset(h2f_reset),
      .hps_hps2fpga_awid(h2f_awid), .hps_hps2fpga_awaddr(h2f_awaddr),
      .hps_hps2fpga_awlen(h2f_awlen), .hps_hps2fpga_awsize(h2f_awsize),
      .hps_hps2fpga_awburst(h2f_awburst), .hps_hps2fpga_awlock(h2f_awlock),
      .hps_hps2fpga_awcache(h2f_awcache), .hps_hps2fpga_awprot(h2f_awprot),
      .hps_hps2fpga_awvalid(h2f_awvalid), .hps_hps2fpga_awready(h2f_awready),
      .hps_hps2fpga_wdata(h2f_wdata), .hps_hps2fpga_wstrb(h2f_wstrb),
      .hps_hps2fpga_wlast(h2f_wlast), .hps_hps2fpga_wvalid(h2f_wvalid),
      .hps_hps2fpga_wready(h2f_wready),
      .hps_hps2fpga_bid(h2f_bid), .hps_hps2fpga_bresp(h2f_bresp),
      .hps_hps2fpga_bvalid(h2f_bvalid), .hps_hps2fpga_bready(h2f_bready),
      .hps_hps2fpga_arid(h2f_arid), .hps_hps2fpga_araddr(h2f_araddr),
      .hps_hps2fpga_arlen(h2f_arlen), .hps_hps2fpga_arsize(h2f_arsize),
      .hps_hps2fpga_arburst(h2f_arburst), .hps_hps2fpga_arlock(h2f_arlock),
      .hps_hps2fpga_arcache(h2f_arcache), .hps_hps2fpga_arprot(h2f_arprot),
      .hps_hps2fpga_arvalid(h2f_arvalid), .hps_hps2fpga_arready(h2f_arready),
      .hps_hps2fpga_rid(h2f_rid), .hps_hps2fpga_rdata(h2f_rdata),
      .hps_hps2fpga_rresp(h2f_rresp), .hps_hps2fpga_rlast(h2f_rlast),
      .hps_hps2fpga_rvalid(h2f_rvalid), .hps_hps2fpga_rready(h2f_rready),
      // The lightweight bridge.
      .hps_lwhps2fpga_axi_clock_clk(clk), .hps_lwhps2fpga_axi_reset_reset(h2f_reset),
      .hps_lwhps2fpga_awid(lw_awid), .hps_lwhps2fpga_awaddr(lw_awaddr),
      .hps_lwhps2fpga_awlen(lw_awlen), .hps_lwhps2fpga_awsize(lw_awsize),
      .hps_lwhps2fpga_awburst(lw_awburst), .hps_lwhps2fpga_awlock(lw_awlock),
      .hps_lwhps2fpga_awcache(lw_awcache), .hps_lwhps2fpga_awprot(lw_awprot),
      .hps_lwhps2fpga_awvalid(lw_awvalid), .hps_lwhps2fpga_awready(lw_awready),
      .hps_lwhps2fpga_wdata(lw_wdata), .hps_lwhps2fpga_wstrb(lw_wstrb),
      .hps_lwhps2fpga_wlast(lw_wlast), .hps_lwhps2fpga_wvalid(lw_wvalid),
      .hps_lwhps2fpga_wready(lw_wready),
      .hps_lwhps2fpga_bid(lw_bid), .hps_lwhps2fpga_bresp(lw_bresp),
      .hps_lwhps2fpga_bvalid(lw_bvalid), .hps_lwhps2fpga_bready(lw_bready),
      .hps_lwhps2fpga_arid(lw_arid), .hps_lwhps2fpga_araddr(lw_araddr),
      .hps_lwhps2fpga_arlen(lw_arlen), .hps_lwhps2fpga_arsize(lw_arsize),
      .hps_lwhps2fpga_arburst(lw_arburst), .hps_lwhps2fpga_arlock(lw_arlock),
      .hps_lwhps2fpga_arcache(lw_arcache), .hps_lwhps2fpga_arprot(lw_arprot),
      .hps_lwhps2fpga_arvalid(lw_arvalid), .hps_lwhps2fpga_arready(lw_arready),
      .hps_lwhps2fpga_rid(lw_rid), .hps_lwhps2fpga_rdata(lw_rdata),
      .hps_lwhps2fpga_rresp(lw_rresp), .hps_lwhps2fpga_rlast(lw_rlast),
      .hps_lwhps2fpga_rvalid(lw_rvalid), .hps_lwhps2fpga_rready(lw_rready),
      // The fabric-to-SDRAM bridge.
      .hps_f2sdram_axi_clock_clk(clk), .hps_f2sdram_axi_reset_reset(h2f_reset),
      .hps_f2sdram_awid(f2s_awid), .hps_f2sdram_awaddr(f2s_awaddr),
      .hps_f2sdram_awlen(f2s_awlen), .hps_f2sdram_awsize(f2s_awsize),
      .hps_f2sdram_awburst(f2s_awburst), .hps_f2sdram_awlock(f2s_awlock),
      .hps_f2sdram_awcache(f2s_awcache), .hps_f2sdram_awprot(f2s_awprot),
      .hps_f2sdram_awqos(f2s_awqos), .hps_f2sdram_awregion(f2s_awregion),
      .hps_f2sdram_awuser(f2s_awuser),
      .hps_f2sdram_awvalid(f2s_awvalid), .hps_f2sdram_awready(f2s_awready),
      .hps_f2sdram_wdata(f2s_wdata), .hps_f2sdram_wstrb(f2s_wstrb),
      .hps_f2sdram_wlast(f2s_wlast), .hps_f2sdram_wuser(f2s_wuser),
      .hps_f2sdram_wvalid(f2s_wvalid), .hps_f2sdram_wready(f2s_wready),
      .hps_f2sdram_bid(f2s_bid), .hps_f2sdram_bresp(f2s_bresp),
      .hps_f2sdram_buser(f2s_buser),
      .hps_f2sdram_bvalid(f2s_bvalid), .hps_f2sdram_bready(f2s_bready),
      .hps_f2sdram_arid(f2s_arid), .hps_f2sdram_araddr(f2s_araddr),
      .hps_f2sdram_arlen(f2s_arlen), .hps_f2sdram_arsize(f2s_arsize),
      .hps_f2sdram_arburst(f2s_arburst), .hps_f2sdram_arlock(f2s_arlock),
      .hps_f2sdram_arcache(f2s_arcache), .hps_f2sdram_arprot(f2s_arprot),
      .hps_f2sdram_arqos(f2s_arqos), .hps_f2sdram_arregion(f2s_arregion),
      .hps_f2sdram_aruser(f2s_aruser),
      .hps_f2sdram_arvalid(f2s_arvalid), .hps_f2sdram_arready(f2s_arready),
      .hps_f2sdram_rid(f2s_rid), .hps_f2sdram_rdata(f2s_rdata),
      .hps_f2sdram_rresp(f2s_rresp), .hps_f2sdram_rlast(f2s_rlast),
      .hps_f2sdram_ruser(f2s_ruser),
      .hps_f2sdram_rvalid(f2s_rvalid), .hps_f2sdram_rready(f2s_rready)
  );

  // The bridges' reset, synchronized in, and the machine's two resets (the
  // reset section above): the HARD reset, the processor's and the PLL's
  // lock, taken by the core at once; the REQUEST, KEY1, the console's RESET
  // key and the port not yet live, taken once its memory port has drained.
  // `mach_rst` is the core's reset as it is, for the lamps and the input
  // page.
  logic [2:0] h2f_rst_s;
  logic       h2f_rst;
  always_ff @(posedge clk) begin
    h2f_rst_s <= {h2f_rst_s[1:0], h2f_reset};
    h2f_rst   <= h2f_rst_s[2];
  end

  logic face_req, hard_rst, mach_req, mach_rst, may_start;
  logic core_rst_pend, core_rst_on, core_rst_cut;
  always_ff @(posedge clk) begin
    hard_rst <= lock_rst || h2f_rst;
    mach_req <= key_req || face_req || !may_start;
    mach_rst <= core_rst_on;
  end

  // ---------------------------------------------------------- the machine
  logic [15:0] obs_cs, obs_rd, obs_ex, obs_wb, obs_commit;
  logic [13:0] obs_pdlptr, obs_pdlidx;
  logic [4:0]  obs_spcptr;
  logic [39:0] obs_q, obs_vma, obs_md, obs_ea, obs_em, obs_ob, obs_mdword;
  logic [40:0] obs_lc;
  logic [31:0] obs_ic, obs_gaddr, obs_raddr;
  logic        obs_opnd, obs_mdl, obs_reg, obs_halted;
  logic [25:0] obs_oalow;
  logic [21:0] obs_oahigh;
  logic [1:0]  obs_grant, obs_errhalt;
  logic [3:0]  obs_queue;
  logic [4:0]  obs_inflight;
  logic        fd_doorbell, fd_enabled, axi_one_write_id;
  logic        kbd_strobe, kbd_busy;
  logic [23:0] kbd_code;
  logic [6:0]  mouse_lines;
  // The Chaosnet interface's cable, tied off: a frame sent is away at once.
  logic        chaos_tx_go, chaos_tx_valid, chaos_tx_clear, chaos_reset;
  logic [8:0]  chaos_tx_len;
  logic [15:0] chaos_tx_word, chaos_csr;
  logic [11:0] chaos_bits;
  logic [15:0] fd_prod;
  // The host's side of the file device and the clock (`quux_fd_face.sv`).
  logic        host_we;
  logic [3:0]  host_widx, host_ridx;
  logic [31:0] host_wdata, host_rdata;
  logic [3:0]  axi_read_clocks, axi_write_clocks;
  logic        spy_we;
  logic [3:0]  spy_eadr, spy_raddr;
  logic [15:0] spy_wdata, spy_rdata;
  logic [63:0] ro_word, rm_word, obs_committed;
  logic [47:0] obs_clocks;
  logic        rm_en, rm_snap;
  logic [3:0]  rm_sel;
  logic [13:0] rm_addr;
  logic [31:0] rtc_start;
  logic        video_bow;

  // Block-disk's seam to the pack side (`cadr_disk_pack.sv`).
  logic        store_we, store_miss, req_valid, req_post, ch_waiting, store_deny;
  logic        ch_wrote, ch_hit, ch_active, store_busy, obs_transfer;
  logic [4:0]  store_slot, ch_slot, store_busy_slot;
  logic [8:0]  store_addr;
  logic [31:0] store_wdata, store_rdata;
  logic [30:0] req_tag;
  logic [7:0]  drive_present, drive_read_only;
  logic        drive_timed;

  // The machine's 64-bit AXI4 master.
  logic [3:0]  qm_awid;
  logic [31:0] qm_awaddr, qm_araddr;
  logic [7:0]  qm_awlen, qm_arlen;
  logic [2:0]  qm_awsize, qm_arsize;
  logic [1:0]  qm_awburst, qm_arburst;
  logic        qm_awvalid, qm_awready, qm_wlast, qm_wvalid, qm_wready;
  logic        qm_bvalid, qm_bready, qm_arvalid, qm_arready, qm_rlast, qm_rvalid, qm_rready;
  logic [63:0] qm_wdata, qm_rdata;
  logic [7:0]  qm_wstrb;
  logic [1:0]  qm_bresp, qm_rresp;

  quux15_core #(
      .PROM_HEX(PROM_HEX),
      .MAIN_WORDS(MAIN_WORDS), .CACHE_WORDS(CACHE_WORDS),
      .VIDEO_W(VIDEO_W), .VIDEO_H(VIDEO_H), .BOARD_NAME(BOARD),
      .MAIN_BASE(MAIN_BASE),
      .DISPLAY_BASE(DISPLAY_BASE)
  ) u_core (
      .clk(clk), .rst(hard_rst), .rst_req(mach_req),
      .rst_pend(core_rst_pend), .rst_on(core_rst_on), .rst_cut(core_rst_cut),
      .obs_cs(obs_cs), .obs_rd(obs_rd), .obs_ex(obs_ex), .obs_wb(obs_wb), .obs_commit(obs_commit),
      .obs_pdlptr(obs_pdlptr), .obs_pdlidx(obs_pdlidx), .obs_spcptr(obs_spcptr),
      .obs_q(obs_q), .obs_vma(obs_vma), .obs_md(obs_md), .obs_lc(obs_lc), .obs_ic(obs_ic),
      .obs_opnd(obs_opnd), .obs_ea(obs_ea), .obs_em(obs_em), .obs_ob(obs_ob),
      .obs_oalow(obs_oalow), .obs_oahigh(obs_oahigh), .obs_grant(obs_grant), .obs_gaddr(obs_gaddr),
      .obs_mdl(obs_mdl), .obs_mdword(obs_mdword), .obs_reg(obs_reg), .obs_raddr(obs_raddr),
      .obs_queue(obs_queue), .obs_inflight(obs_inflight), .obs_halted(obs_halted),
      .obs_errhalt(obs_errhalt),
      .m_awid(qm_awid), .m_awaddr(qm_awaddr), .m_awlen(qm_awlen), .m_awsize(qm_awsize),
      .m_awburst(qm_awburst), .m_awvalid(qm_awvalid), .m_awready(qm_awready),
      .m_wdata(qm_wdata), .m_wstrb(qm_wstrb), .m_wlast(qm_wlast), .m_wvalid(qm_wvalid),
      .m_wready(qm_wready), .m_bid(4'd0), .m_bresp(qm_bresp), .m_bvalid(qm_bvalid),
      .m_bready(qm_bready),
      .m_araddr(qm_araddr), .m_arlen(qm_arlen), .m_arsize(qm_arsize), .m_arburst(qm_arburst),
      .m_arvalid(qm_arvalid), .m_arready(qm_arready), .m_rdata(qm_rdata), .m_rresp(qm_rresp),
      .m_rlast(qm_rlast), .m_rvalid(qm_rvalid), .m_rready(qm_rready),
      .period(7'(PERIOD)), .rtc_start(rtc_start),
      .fd_doorbell(fd_doorbell), .fd_prod(fd_prod), .fd_enabled(fd_enabled),
      .host_we(host_we), .host_widx(host_widx), .host_wdata(host_wdata),
      .host_ridx(host_ridx), .host_rdata(host_rdata),
      .kbd_strobe(kbd_strobe), .kbd_code(kbd_code), .mouse_lines(mouse_lines), .kbd_busy(kbd_busy),
      .chaos_address(16'd0), .chaos_tx_go(chaos_tx_go), .chaos_tx_len(chaos_tx_len),
      .chaos_tx_valid(chaos_tx_valid), .chaos_tx_word(chaos_tx_word), .chaos_tx_clear(chaos_tx_clear),
      .chaos_reset(chaos_reset), .chaos_csr(chaos_csr),
      .chaos_rx_valid(1'b0), .chaos_rx_word(16'd0), .chaos_rx_done(1'b0), .chaos_rx_bits(13'd0),
      .chaos_rx_crc(1'b0), .chaos_rx_lost(1'b0), .chaos_tx_done(chaos_tx_go), .chaos_tx_abort(1'b0),
      .chaos_cbl_busy(1'b0), .chaos_bits(chaos_bits),
      .axi_one_write_id(axi_one_write_id), .axi_read_clocks(axi_read_clocks),
      .axi_write_clocks(axi_write_clocks),
      .spy_we(spy_we), .spy_eadr(spy_eadr), .spy_wdata(spy_wdata),
      .spy_raddr(spy_raddr), .spy_rdata(spy_rdata),
      .ro_sel(5'd0), .ro_word(ro_word),
      .rm_en(rm_en), .rm_snap(rm_snap), .rm_sel(rm_sel), .rm_addr(rm_addr), .rm_word(rm_word),
      .obs_committed(obs_committed), .obs_clocks(obs_clocks),
      .drive_present(drive_present[0]),
      .store_we(store_we), .store_slot(store_slot), .store_addr(store_addr),
      .store_wdata(store_wdata), .store_rdata(store_rdata), .store_miss(store_miss),
      .req_valid(req_valid), .req_tag(req_tag), .req_post(req_post), .ch_waiting(ch_waiting),
      .store_deny(store_deny), .ch_slot(ch_slot), .ch_wrote(ch_wrote), .ch_hit(ch_hit),
      .ch_active(ch_active), .store_busy(store_busy), .store_busy_slot(store_busy_slot),
      .obs_transfer(obs_transfer), .bow(video_bow)
  );

  // ------------------------------------------- main memory: the share
  //
  // Port 0 the machine, port 1 the pack side, port 2 the display, each in
  // the AXI3 shape the share takes; the gate, the tally and the machine's
  // reset with them (`quux15_f2sdram_port.sv`).
  logic [31:0] dm_araddr;
  logic [3:0]  dm_arlen;
  logic [1:0]  dm_arsize, dm_arburst;
  logic        dm_arvalid, dm_arready;
  logic [63:0] dm_rdata;
  logic [1:0]  dm_rresp;
  logic        dm_rlast, dm_rvalid, dm_rready;

  logic [31:0] pm_awaddr, pm_araddr;
  logic [3:0]  pm_awlen, pm_arlen;
  logic [1:0]  pm_awsize, pm_arsize, pm_awburst, pm_arburst;
  logic        pm_awvalid, pm_awready, pm_wlast, pm_wvalid, pm_wready;
  logic        pm_bvalid, pm_bready, pm_arvalid, pm_arready;
  logic        pm_rlast, pm_rvalid, pm_rready;
  logic [63:0] pm_wdata, pm_rdata;
  logic [7:0]  pm_wstrb;
  logic [1:0]  pm_bresp, pm_rresp;

  logic port_live;

  quux15_f2sdram_port u_memory (
      .clk(clk), .rst(rst), .lock_rst(lock_rst),
      .s_awaddr(qm_awaddr), .s_awlen(qm_awlen), .s_awsize(qm_awsize), .s_awburst(qm_awburst),
      .s_awvalid(qm_awvalid), .s_awready(qm_awready),
      .s_wdata(qm_wdata), .s_wstrb(qm_wstrb), .s_wlast(qm_wlast),
      .s_wvalid(qm_wvalid), .s_wready(qm_wready),
      .s_bresp(qm_bresp), .s_bvalid(qm_bvalid), .s_bready(qm_bready),
      .s_araddr(qm_araddr), .s_arlen(qm_arlen), .s_arsize(qm_arsize), .s_arburst(qm_arburst),
      .s_arvalid(qm_arvalid), .s_arready(qm_arready),
      .s_rdata(qm_rdata), .s_rresp(qm_rresp), .s_rlast(qm_rlast), .s_rvalid(qm_rvalid),
      .s_rready(qm_rready),
      .h2f_reset(h2f_reset), .gp_open(gp_out[0]), .gp_half(gp_out[1]),
      .warm_req_n(warm_req_n), .warm_ack_n(warm_ack_n),
      .gp_in(gp_in), .live(port_live), .may_start(may_start),
      .p_awaddr(pm_awaddr), .p_awlen(pm_awlen), .p_awsize(pm_awsize),
      .p_awburst(pm_awburst), .p_awvalid(pm_awvalid), .p_awready(pm_awready),
      .p_wdata(pm_wdata), .p_wstrb(pm_wstrb), .p_wlast(pm_wlast),
      .p_wvalid(pm_wvalid), .p_wready(pm_wready),
      .p_bresp(pm_bresp), .p_bvalid(pm_bvalid), .p_bready(pm_bready),
      .p_araddr(pm_araddr), .p_arlen(pm_arlen), .p_arsize(pm_arsize),
      .p_arburst(pm_arburst), .p_arvalid(pm_arvalid), .p_arready(pm_arready),
      .p_rdata(pm_rdata), .p_rresp(pm_rresp), .p_rlast(pm_rlast),
      .p_rvalid(pm_rvalid), .p_rready(pm_rready),
      .d_araddr(dm_araddr), .d_arlen(dm_arlen), .d_arsize(dm_arsize),
      .d_arburst(dm_arburst), .d_arvalid(dm_arvalid), .d_arready(dm_arready),
      .d_rdata(dm_rdata), .d_rresp(dm_rresp), .d_rlast(dm_rlast),
      .d_rvalid(dm_rvalid), .d_rready(dm_rready),
      .f2s_awid(f2s_awid), .f2s_awaddr(f2s_awaddr), .f2s_awlen(f2s_awlen),
      .f2s_awsize(f2s_awsize), .f2s_awburst(f2s_awburst),
      .f2s_awlock(f2s_awlock), .f2s_awcache(f2s_awcache),
      .f2s_awprot(f2s_awprot), .f2s_awqos(f2s_awqos),
      .f2s_awregion(f2s_awregion), .f2s_awuser(f2s_awuser),
      .f2s_awvalid(f2s_awvalid), .f2s_awready(f2s_awready),
      .f2s_wdata(f2s_wdata), .f2s_wstrb(f2s_wstrb), .f2s_wlast(f2s_wlast),
      .f2s_wuser(f2s_wuser), .f2s_wvalid(f2s_wvalid), .f2s_wready(f2s_wready),
      .f2s_bid(f2s_bid), .f2s_bresp(f2s_bresp), .f2s_bvalid(f2s_bvalid),
      .f2s_bready(f2s_bready),
      .f2s_arid(f2s_arid), .f2s_araddr(f2s_araddr), .f2s_arlen(f2s_arlen),
      .f2s_arsize(f2s_arsize), .f2s_arburst(f2s_arburst),
      .f2s_arlock(f2s_arlock), .f2s_arcache(f2s_arcache),
      .f2s_arprot(f2s_arprot), .f2s_arqos(f2s_arqos),
      .f2s_arregion(f2s_arregion), .f2s_aruser(f2s_aruser),
      .f2s_arvalid(f2s_arvalid), .f2s_arready(f2s_arready),
      .f2s_rid(f2s_rid), .f2s_rdata(f2s_rdata), .f2s_rresp(f2s_rresp),
      .f2s_rlast(f2s_rlast), .f2s_rvalid(f2s_rvalid), .f2s_rready(f2s_rready)
  );

  // ------------------------------------- the HPS-to-FPGA bridge, five pages
  logic [31:0] h2fp_awaddr, h2fp_araddr, h2fp_wdata, h2fp_rdata;
  logic [7:0]  h2fp_awlen, h2fp_arlen;
  logic [3:0]  h2fp_wstrb, h2fp_awid, h2fp_arid, h2fp_bid, h2fp_rid;
  logic        h2fp_awvalid, h2fp_awready, h2fp_wlast, h2fp_wvalid, h2fp_wready;
  logic        h2fp_bvalid, h2fp_bready, h2fp_arvalid, h2fp_arready;
  logic        h2fp_rlast, h2fp_rvalid, h2fp_rready;
  logic [1:0]  h2fp_bresp, h2fp_rresp;
  logic [11:0] h2fc_awaddr, h2fc_araddr;
  logic [31:0] h2fc_wdata, h2fc_rdata;
  logic [7:0]  h2fc_awlen, h2fc_arlen;
  logic [3:0]  h2fc_wstrb, h2fc_awid, h2fc_arid, h2fc_bid, h2fc_rid;
  logic        h2fc_awvalid, h2fc_awready, h2fc_wlast, h2fc_wvalid, h2fc_wready;
  logic        h2fc_bvalid, h2fc_bready, h2fc_arvalid, h2fc_arready;
  logic        h2fc_rlast, h2fc_rvalid, h2fc_rready;
  logic [1:0]  h2fc_bresp, h2fc_rresp;
  logic [11:0] h2fs_awaddr, h2fs_araddr;
  logic [31:0] h2fs_wdata, h2fs_rdata;
  logic [7:0]  h2fs_awlen, h2fs_arlen;
  logic [3:0]  h2fs_wstrb, h2fs_awid, h2fs_arid, h2fs_bid, h2fs_rid;
  logic        h2fs_awvalid, h2fs_awready, h2fs_wlast, h2fs_wvalid, h2fs_wready;
  logic        h2fs_bvalid, h2fs_bready, h2fs_arvalid, h2fs_arready;
  logic        h2fs_rlast, h2fs_rvalid, h2fs_rready;
  logic [1:0]  h2fs_bresp, h2fs_rresp;
  logic [11:0] h2fi_awaddr, h2fi_araddr;
  logic [31:0] h2fi_wdata, h2fi_rdata;
  logic [7:0]  h2fi_awlen, h2fi_arlen;
  logic [3:0]  h2fi_wstrb, h2fi_awid, h2fi_arid, h2fi_bid, h2fi_rid;
  logic        h2fi_awvalid, h2fi_awready, h2fi_wlast, h2fi_wvalid, h2fi_wready;
  logic        h2fi_bvalid, h2fi_bready, h2fi_arvalid, h2fi_arready;
  logic        h2fi_rlast, h2fi_rvalid, h2fi_rready;
  logic [1:0]  h2fi_bresp, h2fi_rresp;
  logic [11:0] h2ff_awaddr, h2ff_araddr;
  logic [31:0] h2ff_wdata, h2ff_rdata;
  logic [7:0]  h2ff_awlen, h2ff_arlen;
  logic [3:0]  h2ff_wstrb, h2ff_awid, h2ff_arid, h2ff_bid, h2ff_rid;
  logic        h2ff_awvalid, h2ff_awready, h2ff_wlast, h2ff_wvalid, h2ff_wready;
  logic        h2ff_bvalid, h2ff_bready, h2ff_arvalid, h2ff_arready;
  logic        h2ff_rlast, h2ff_rvalid, h2ff_rready;
  logic [1:0]  h2ff_bresp, h2ff_rresp;
  logic [31:0] h2fd_rdata;
  logic [7:0]  h2fd_arlen;
  logic [3:0]  h2fd_awid, h2fd_arid, h2fd_bid, h2fd_rid;
  logic        h2fd_awvalid, h2fd_awready, h2fd_wlast, h2fd_wvalid, h2fd_wready;
  logic        h2fd_bvalid, h2fd_bready, h2fd_arvalid, h2fd_arready;
  logic        h2fd_rlast, h2fd_rvalid, h2fd_rready;
  logic [1:0]  h2fd_bresp, h2fd_rresp;

  cadr_gp0_split #(
      .PACK_BASE (32'h0000_0000),
      .CHAOS_BASE(32'h0000_1000),
      .SER_BASE  (32'h0000_2000),
      .INPUT_BASE(32'h0000_3000),
      // QUUX's fifth page, the clock and the file device.
      .FD_BASE   (32'h0000_4000),
      .HAS_FD    (1'b1),
      .ID_W(4), .LEN_W(8)
  ) u_h2f_split (
      .clk(clk), .rst(h2f_rst),
      .s_awaddr({2'b00, h2f_awaddr}), .s_awlen(h2f_awlen), .s_awid(h2f_awid),
      .s_awvalid(h2f_awvalid), .s_awready(h2f_awready),
      .s_wdata(h2f_wdata), .s_wstrb(h2f_wstrb), .s_wlast(h2f_wlast),
      .s_wvalid(h2f_wvalid), .s_wready(h2f_wready),
      .s_bresp(h2f_bresp), .s_bid(h2f_bid), .s_bvalid(h2f_bvalid),
      .s_bready(h2f_bready),
      .s_araddr({2'b00, h2f_araddr}), .s_arlen(h2f_arlen), .s_arid(h2f_arid),
      .s_arvalid(h2f_arvalid), .s_arready(h2f_arready),
      .s_rdata(h2f_rdata), .s_rresp(h2f_rresp), .s_rid(h2f_rid),
      .s_rlast(h2f_rlast), .s_rvalid(h2f_rvalid), .s_rready(h2f_rready),
      .pack_awaddr(h2fp_awaddr), .pack_awlen(h2fp_awlen), .pack_awid(h2fp_awid),
      .pack_awvalid(h2fp_awvalid), .pack_awready(h2fp_awready),
      .pack_wdata(h2fp_wdata), .pack_wstrb(h2fp_wstrb), .pack_wlast(h2fp_wlast),
      .pack_wvalid(h2fp_wvalid), .pack_wready(h2fp_wready),
      .pack_bresp(h2fp_bresp), .pack_bid(h2fp_bid), .pack_bvalid(h2fp_bvalid),
      .pack_bready(h2fp_bready),
      .pack_araddr(h2fp_araddr), .pack_arlen(h2fp_arlen), .pack_arid(h2fp_arid),
      .pack_arvalid(h2fp_arvalid), .pack_arready(h2fp_arready),
      .pack_rdata(h2fp_rdata), .pack_rresp(h2fp_rresp), .pack_rid(h2fp_rid),
      .pack_rlast(h2fp_rlast), .pack_rvalid(h2fp_rvalid),
      .pack_rready(h2fp_rready),
      .chaos_awaddr(h2fc_awaddr), .chaos_awlen(h2fc_awlen),
      .chaos_awid(h2fc_awid),
      .chaos_awvalid(h2fc_awvalid), .chaos_awready(h2fc_awready),
      .chaos_wdata(h2fc_wdata), .chaos_wstrb(h2fc_wstrb),
      .chaos_wlast(h2fc_wlast),
      .chaos_wvalid(h2fc_wvalid), .chaos_wready(h2fc_wready),
      .chaos_bresp(h2fc_bresp), .chaos_bid(h2fc_bid),
      .chaos_bvalid(h2fc_bvalid), .chaos_bready(h2fc_bready),
      .chaos_araddr(h2fc_araddr), .chaos_arlen(h2fc_arlen),
      .chaos_arid(h2fc_arid),
      .chaos_arvalid(h2fc_arvalid), .chaos_arready(h2fc_arready),
      .chaos_rdata(h2fc_rdata), .chaos_rresp(h2fc_rresp), .chaos_rid(h2fc_rid),
      .chaos_rlast(h2fc_rlast), .chaos_rvalid(h2fc_rvalid),
      .chaos_rready(h2fc_rready),
      .ser_awaddr(h2fs_awaddr), .ser_awlen(h2fs_awlen), .ser_awid(h2fs_awid),
      .ser_awvalid(h2fs_awvalid), .ser_awready(h2fs_awready),
      .ser_wdata(h2fs_wdata), .ser_wstrb(h2fs_wstrb), .ser_wlast(h2fs_wlast),
      .ser_wvalid(h2fs_wvalid), .ser_wready(h2fs_wready),
      .ser_bresp(h2fs_bresp), .ser_bid(h2fs_bid), .ser_bvalid(h2fs_bvalid),
      .ser_bready(h2fs_bready),
      .ser_araddr(h2fs_araddr), .ser_arlen(h2fs_arlen), .ser_arid(h2fs_arid),
      .ser_arvalid(h2fs_arvalid), .ser_arready(h2fs_arready),
      .ser_rdata(h2fs_rdata), .ser_rresp(h2fs_rresp), .ser_rid(h2fs_rid),
      .ser_rlast(h2fs_rlast), .ser_rvalid(h2fs_rvalid), .ser_rready(h2fs_rready),
      .in_awaddr(h2fi_awaddr), .in_awlen(h2fi_awlen), .in_awid(h2fi_awid),
      .in_awvalid(h2fi_awvalid), .in_awready(h2fi_awready),
      .in_wdata(h2fi_wdata), .in_wstrb(h2fi_wstrb), .in_wlast(h2fi_wlast),
      .in_wvalid(h2fi_wvalid), .in_wready(h2fi_wready),
      .in_bresp(h2fi_bresp), .in_bid(h2fi_bid), .in_bvalid(h2fi_bvalid),
      .in_bready(h2fi_bready),
      .in_araddr(h2fi_araddr), .in_arlen(h2fi_arlen), .in_arid(h2fi_arid),
      .in_arvalid(h2fi_arvalid), .in_arready(h2fi_arready),
      .in_rdata(h2fi_rdata), .in_rresp(h2fi_rresp), .in_rid(h2fi_rid),
      .in_rlast(h2fi_rlast), .in_rvalid(h2fi_rvalid), .in_rready(h2fi_rready),
      .fd_awaddr(h2ff_awaddr), .fd_awlen(h2ff_awlen), .fd_awid(h2ff_awid),
      .fd_awvalid(h2ff_awvalid), .fd_awready(h2ff_awready),
      .fd_wdata(h2ff_wdata), .fd_wstrb(h2ff_wstrb), .fd_wlast(h2ff_wlast),
      .fd_wvalid(h2ff_wvalid), .fd_wready(h2ff_wready),
      .fd_bresp(h2ff_bresp), .fd_bid(h2ff_bid), .fd_bvalid(h2ff_bvalid),
      .fd_bready(h2ff_bready),
      .fd_araddr(h2ff_araddr), .fd_arlen(h2ff_arlen), .fd_arid(h2ff_arid),
      .fd_arvalid(h2ff_arvalid), .fd_arready(h2ff_arready),
      .fd_rdata(h2ff_rdata), .fd_rresp(h2ff_rresp), .fd_rid(h2ff_rid),
      .fd_rlast(h2ff_rlast), .fd_rvalid(h2ff_rvalid), .fd_rready(h2ff_rready),
      .dflt_awid(h2fd_awid), .dflt_awvalid(h2fd_awvalid),
      .dflt_awready(h2fd_awready),
      .dflt_wlast(h2fd_wlast), .dflt_wvalid(h2fd_wvalid),
      .dflt_wready(h2fd_wready),
      .dflt_bresp(h2fd_bresp), .dflt_bid(h2fd_bid), .dflt_bvalid(h2fd_bvalid),
      .dflt_bready(h2fd_bready),
      .dflt_arlen(h2fd_arlen), .dflt_arid(h2fd_arid),
      .dflt_arvalid(h2fd_arvalid), .dflt_arready(h2fd_arready),
      .dflt_rdata(h2fd_rdata), .dflt_rresp(h2fd_rresp), .dflt_rid(h2fd_rid),
      .dflt_rlast(h2fd_rlast), .dflt_rvalid(h2fd_rvalid),
      .dflt_rready(h2fd_rready)
  );

  // **THE PACK SIDE**, its face on this bridge and its master on the share's
  // port 1.  Its reset is the bridge's alone, KEY1 at `fabric_rst`, and the
  // port's liveness a signal, for the reasons `cadr_de25.sv` gives.
  logic pack_irq;
  cadr_disk_pack #(
      .REG_BASE(32'h0000_0000), .ID_W(4), .LEN_W(8)
  ) u_pack (
      .clk(clk), .rst(h2f_rst), .fabric_rst(rst), .port_live(port_live),
      .s_awaddr(h2fp_awaddr), .s_awlen(h2fp_awlen), .s_awid(h2fp_awid),
      .s_awvalid(h2fp_awvalid), .s_awready(h2fp_awready),
      .s_wdata(h2fp_wdata), .s_wstrb(h2fp_wstrb), .s_wlast(h2fp_wlast),
      .s_wvalid(h2fp_wvalid), .s_wready(h2fp_wready),
      .s_bresp(h2fp_bresp), .s_bid(h2fp_bid), .s_bvalid(h2fp_bvalid),
      .s_bready(h2fp_bready),
      .s_araddr(h2fp_araddr), .s_arlen(h2fp_arlen), .s_arid(h2fp_arid),
      .s_arvalid(h2fp_arvalid), .s_arready(h2fp_arready),
      .s_rdata(h2fp_rdata), .s_rresp(h2fp_rresp), .s_rid(h2fp_rid),
      .s_rlast(h2fp_rlast), .s_rvalid(h2fp_rvalid), .s_rready(h2fp_rready),
      .m_awaddr(pm_awaddr), .m_awlen(pm_awlen), .m_awsize(pm_awsize),
      .m_awburst(pm_awburst), .m_awvalid(pm_awvalid), .m_awready(pm_awready),
      .m_wdata(pm_wdata), .m_wstrb(pm_wstrb), .m_wlast(pm_wlast),
      .m_wvalid(pm_wvalid), .m_wready(pm_wready),
      .m_bresp(pm_bresp), .m_bvalid(pm_bvalid), .m_bready(pm_bready),
      .m_araddr(pm_araddr), .m_arlen(pm_arlen), .m_arsize(pm_arsize),
      .m_arburst(pm_arburst), .m_arvalid(pm_arvalid), .m_arready(pm_arready),
      .m_rdata(pm_rdata), .m_rresp(pm_rresp), .m_rlast(pm_rlast),
      .m_rvalid(pm_rvalid), .m_rready(pm_rready),
      .store_we(store_we), .store_slot(store_slot),
      .store_addr(store_addr), .store_wdata(store_wdata),
      .store_rdata(store_rdata), .store_miss(store_miss),
      .ch_active(ch_active), .moving(store_busy),
      .moving_slot(store_busy_slot),
      .req_valid(req_valid), .req_tag(req_tag), .req_post(req_post),
      .ch_waiting(ch_waiting), .ch_slot(ch_slot), .ch_wrote(ch_wrote),
      .ch_hit(ch_hit), .deny(store_deny), .irq(pack_irq),
      .drive_present(drive_present), .drive_read_only(drive_read_only),
      .drive_timed(drive_timed)
  );

  // The network's page and the serial line's, which QUUX has not got.
  cadr_gp0_default #(.ID_W(4), .LEN_W(8)) u_h2f_chaos (
      .clk(clk), .rst(h2f_rst),
      .s_awvalid(h2fc_awvalid), .s_awid(h2fc_awid), .s_awready(h2fc_awready),
      .s_wlast(h2fc_wlast), .s_wvalid(h2fc_wvalid), .s_wready(h2fc_wready),
      .s_bresp(h2fc_bresp), .s_bid(h2fc_bid), .s_bvalid(h2fc_bvalid),
      .s_bready(h2fc_bready),
      .s_arlen(h2fc_arlen), .s_arid(h2fc_arid), .s_arvalid(h2fc_arvalid),
      .s_arready(h2fc_arready),
      .s_rdata(h2fc_rdata), .s_rresp(h2fc_rresp), .s_rid(h2fc_rid),
      .s_rlast(h2fc_rlast), .s_rvalid(h2fc_rvalid), .s_rready(h2fc_rready)
  );
  cadr_gp0_default #(.ID_W(4), .LEN_W(8)) u_h2f_ser (
      .clk(clk), .rst(h2f_rst),
      .s_awvalid(h2fs_awvalid), .s_awid(h2fs_awid), .s_awready(h2fs_awready),
      .s_wlast(h2fs_wlast), .s_wvalid(h2fs_wvalid), .s_wready(h2fs_wready),
      .s_bresp(h2fs_bresp), .s_bid(h2fs_bid), .s_bvalid(h2fs_bvalid),
      .s_bready(h2fs_bready),
      .s_arlen(h2fs_arlen), .s_arid(h2fs_arid), .s_arvalid(h2fs_arvalid),
      .s_arready(h2fs_arready),
      .s_rdata(h2fs_rdata), .s_rresp(h2fs_rresp), .s_rid(h2fs_rid),
      .s_rlast(h2fs_rlast), .s_rvalid(h2fs_rvalid), .s_rready(h2fs_rready)
  );

  // **THE KEYBOARD AND THE MOUSE**: the input page, its queue flushed by the
  // machine's reset, its face reset by the bridge's.
  cadr_input_cables #(.ID_W(4), .LEN_W(8), .MOUSE_STEP_T(MOUSE_STEP_T)) u_input (
      .clk(clk), .rst(h2f_rst), .fabric_rst(rst), .mach_rst(mach_rst),
      .s_awaddr(h2fi_awaddr), .s_awlen(h2fi_awlen), .s_awid(h2fi_awid),
      .s_awvalid(h2fi_awvalid), .s_awready(h2fi_awready),
      .s_wdata(h2fi_wdata), .s_wstrb(h2fi_wstrb), .s_wlast(h2fi_wlast),
      .s_wvalid(h2fi_wvalid), .s_wready(h2fi_wready),
      .s_bresp(h2fi_bresp), .s_bid(h2fi_bid), .s_bvalid(h2fi_bvalid),
      .s_bready(h2fi_bready),
      .s_araddr(h2fi_araddr), .s_arlen(h2fi_arlen), .s_arid(h2fi_arid),
      .s_arvalid(h2fi_arvalid), .s_arready(h2fi_arready),
      .s_rdata(h2fi_rdata), .s_rresp(h2fi_rresp), .s_rid(h2fi_rid),
      .s_rlast(h2fi_rlast), .s_rvalid(h2fi_rvalid), .s_rready(h2fi_rready),
      .kbd_strobe(kbd_strobe), .kbd_code(kbd_code),
      .mouse_lines(mouse_lines),
      // `KBD READY` from the register page's FIFO; no `MOUSE READY`.
      .card_csr({2'b00, kbd_busy, 5'b00000})
  );

  // The file device's page and the clock's setter: revision 13's page,
  // "QF13", as `cadr_de25.sv` gives revisions 13 and 14.
  quux_fd_face #(.ID_W(4), .LEN_W(8), .IDENT(32'h5146_3133)) u_fd_face (
      .clk(clk), .rst(h2f_rst),
      .s_awaddr(h2ff_awaddr), .s_awlen(h2ff_awlen), .s_awid(h2ff_awid),
      .s_awvalid(h2ff_awvalid), .s_awready(h2ff_awready),
      .s_wdata(h2ff_wdata), .s_wstrb(h2ff_wstrb), .s_wlast(h2ff_wlast),
      .s_wvalid(h2ff_wvalid), .s_wready(h2ff_wready),
      .s_bresp(h2ff_bresp), .s_bid(h2ff_bid), .s_bvalid(h2ff_bvalid),
      .s_bready(h2ff_bready),
      .s_araddr(h2ff_araddr), .s_arlen(h2ff_arlen), .s_arid(h2ff_arid),
      .s_arvalid(h2ff_arvalid), .s_arready(h2ff_arready),
      .s_rdata(h2ff_rdata), .s_rresp(h2ff_rresp), .s_rid(h2ff_rid),
      .s_rlast(h2ff_rlast), .s_rvalid(h2ff_rvalid), .s_rready(h2ff_rready),
      .host_we(host_we), .host_widx(host_widx), .host_wdata(host_wdata),
      .host_ridx(host_ridx), .host_rdata(host_rdata)
  );

  cadr_gp0_default #(.ID_W(4), .LEN_W(8)) u_h2f_rest (
      .clk(clk), .rst(h2f_rst),
      .s_awvalid(h2fd_awvalid), .s_awid(h2fd_awid), .s_awready(h2fd_awready),
      .s_wlast(h2fd_wlast), .s_wvalid(h2fd_wvalid), .s_wready(h2fd_wready),
      .s_bresp(h2fd_bresp), .s_bid(h2fd_bid), .s_bvalid(h2fd_bvalid),
      .s_bready(h2fd_bready),
      .s_arlen(h2fd_arlen), .s_arid(h2fd_arid), .s_arvalid(h2fd_arvalid),
      .s_arready(h2fd_arready),
      .s_rdata(h2fd_rdata), .s_rresp(h2fd_rresp), .s_rid(h2fd_rid),
      .s_rlast(h2fd_rlast), .s_rvalid(h2fd_rvalid), .s_rready(h2fd_rready)
  );

  // -------------------------------- the lightweight bridge: the console face
  logic [31:0] lwc_awaddr, lwc_araddr, lwc_wdata, lwc_rdata;
  logic [7:0]  lwc_awlen, lwc_arlen;
  logic [3:0]  lwc_wstrb, lwc_awid, lwc_arid, lwc_bid, lwc_rid;
  logic        lwc_awvalid, lwc_awready, lwc_wlast, lwc_wvalid, lwc_wready;
  logic        lwc_bvalid, lwc_bready, lwc_arvalid, lwc_arready;
  logic        lwc_rlast, lwc_rvalid, lwc_rready;
  logic [1:0]  lwc_bresp, lwc_rresp;
  logic [31:0] lwd_awaddr, lwd_araddr, lwd_wdata, lwd_rdata;
  logic [7:0]  lwd_awlen, lwd_arlen;
  logic [3:0]  lwd_wstrb, lwd_awid, lwd_arid, lwd_bid, lwd_rid;
  logic        lwd_awvalid, lwd_awready, lwd_wlast, lwd_wvalid, lwd_wready;
  logic        lwd_bvalid, lwd_bready, lwd_arvalid, lwd_arready;
  logic        lwd_rlast, lwd_rvalid, lwd_rready;
  logic [1:0]  lwd_bresp, lwd_rresp;
  logic [31:0] lwx_rdata;
  logic [7:0]  lwx_arlen;
  logic [3:0]  lwx_awid, lwx_arid, lwx_bid, lwx_rid;
  logic        lwx_awvalid, lwx_awready, lwx_wlast, lwx_wvalid, lwx_wready;
  logic        lwx_bvalid, lwx_bready, lwx_arvalid, lwx_arready;
  logic        lwx_rlast, lwx_rvalid, lwx_rready;
  logic [1:0]  lwx_bresp, lwx_rresp;

  cadr_gp1_split #(
      .CON_BASE(32'h0000_0000),
      .DBG_BASE(32'h0000_1000),
      .ID_W(4), .LEN_W(8)
  ) u_lw_split (
      .clk(clk), .rst(h2f_rst),
      .s_awaddr({3'b000, lw_awaddr}), .s_awlen(lw_awlen), .s_awid(lw_awid),
      .s_awvalid(lw_awvalid), .s_awready(lw_awready),
      .s_wdata(lw_wdata), .s_wstrb(lw_wstrb), .s_wlast(lw_wlast),
      .s_wvalid(lw_wvalid), .s_wready(lw_wready),
      .s_bresp(lw_bresp), .s_bid(lw_bid), .s_bvalid(lw_bvalid),
      .s_bready(lw_bready),
      .s_araddr({3'b000, lw_araddr}), .s_arlen(lw_arlen), .s_arid(lw_arid),
      .s_arvalid(lw_arvalid), .s_arready(lw_arready),
      .s_rdata(lw_rdata), .s_rresp(lw_rresp), .s_rid(lw_rid),
      .s_rlast(lw_rlast), .s_rvalid(lw_rvalid), .s_rready(lw_rready),
      .con_awaddr(lwc_awaddr), .con_awlen(lwc_awlen), .con_awid(lwc_awid),
      .con_awvalid(lwc_awvalid), .con_awready(lwc_awready),
      .con_wdata(lwc_wdata), .con_wstrb(lwc_wstrb), .con_wlast(lwc_wlast),
      .con_wvalid(lwc_wvalid), .con_wready(lwc_wready),
      .con_bresp(lwc_bresp), .con_bid(lwc_bid), .con_bvalid(lwc_bvalid),
      .con_bready(lwc_bready),
      .con_araddr(lwc_araddr), .con_arlen(lwc_arlen), .con_arid(lwc_arid),
      .con_arvalid(lwc_arvalid), .con_arready(lwc_arready),
      .con_rdata(lwc_rdata), .con_rresp(lwc_rresp), .con_rid(lwc_rid),
      .con_rlast(lwc_rlast), .con_rvalid(lwc_rvalid), .con_rready(lwc_rready),
      .dbg_awaddr(lwd_awaddr), .dbg_awlen(lwd_awlen), .dbg_awid(lwd_awid),
      .dbg_awvalid(lwd_awvalid), .dbg_awready(lwd_awready),
      .dbg_wdata(lwd_wdata), .dbg_wstrb(lwd_wstrb), .dbg_wlast(lwd_wlast),
      .dbg_wvalid(lwd_wvalid), .dbg_wready(lwd_wready),
      .dbg_bresp(lwd_bresp), .dbg_bid(lwd_bid), .dbg_bvalid(lwd_bvalid),
      .dbg_bready(lwd_bready),
      .dbg_araddr(lwd_araddr), .dbg_arlen(lwd_arlen), .dbg_arid(lwd_arid),
      .dbg_arvalid(lwd_arvalid), .dbg_arready(lwd_arready),
      .dbg_rdata(lwd_rdata), .dbg_rresp(lwd_rresp), .dbg_rid(lwd_rid),
      .dbg_rlast(lwd_rlast), .dbg_rvalid(lwd_rvalid), .dbg_rready(lwd_rready),
      .dflt_awid(lwx_awid), .dflt_awvalid(lwx_awvalid),
      .dflt_awready(lwx_awready),
      .dflt_wlast(lwx_wlast), .dflt_wvalid(lwx_wvalid),
      .dflt_wready(lwx_wready),
      .dflt_bresp(lwx_bresp), .dflt_bid(lwx_bid), .dflt_bvalid(lwx_bvalid),
      .dflt_bready(lwx_bready),
      .dflt_arlen(lwx_arlen), .dflt_arid(lwx_arid),
      .dflt_arvalid(lwx_arvalid), .dflt_arready(lwx_arready),
      .dflt_rdata(lwx_rdata), .dflt_rresp(lwx_rresp), .dflt_rid(lwx_rid),
      .dflt_rlast(lwx_rlast), .dflt_rvalid(lwx_rvalid),
      .dflt_rready(lwx_rready)
  );

  // The display output's settings and answers, words 34, 36 and 42, and
  // the lamps', word 35.
  logic [1:0]  con_disp_out, con_disp_rotate;
  logic        con_sleep_set, con_wake, con_err_clear, con_steady_lamps;
  logic [14:0] con_sleep_secs, disp_sleep_setting;
  logic        disp_asleep, disp_underrun_s2, disp_rd_error;

  quux15_face #(
      .ID_W(4), .LEN_W(8), .PERIOD(32'(PERIOD)), .MAIN_UNITS(MAIN_WORDS >> 16),
      .VIDEO_W(VIDEO_W), .VIDEO_H(VIDEO_H)
  ) u_face (
      .clk(clk), .rst(h2f_rst),
      .s_awaddr(lwc_awaddr[11:0]), .s_awlen(lwc_awlen), .s_awid(lwc_awid),
      .s_awvalid(lwc_awvalid), .s_awready(lwc_awready),
      .s_wdata(lwc_wdata), .s_wstrb(lwc_wstrb), .s_wlast(lwc_wlast),
      .s_wvalid(lwc_wvalid), .s_wready(lwc_wready),
      .s_bresp(lwc_bresp), .s_bid(lwc_bid), .s_bvalid(lwc_bvalid), .s_bready(lwc_bready),
      .s_araddr(lwc_araddr[11:0]), .s_arlen(lwc_arlen), .s_arid(lwc_arid),
      .s_arvalid(lwc_arvalid), .s_arready(lwc_arready),
      .s_rdata(lwc_rdata), .s_rresp(lwc_rresp), .s_rid(lwc_rid),
      .s_rlast(lwc_rlast), .s_rvalid(lwc_rvalid), .s_rready(lwc_rready),
      .build(NO_BUILD_STAMP),
      .mach_req(face_req), .mach_pend(core_rst_pend), .mach_on(core_rst_on), .mach_cut(core_rst_cut),
      .rtc_start(rtc_start),
      .committed(obs_committed), .clocks(obs_clocks),
      .vma(obs_vma), .q(obs_q), .md(obs_md),
      .spy_we(spy_we), .spy_eadr(spy_eadr), .spy_wdata(spy_wdata),
      .spy_raddr(spy_raddr), .spy_rdata(spy_rdata),
      .rm_en(rm_en), .rm_snap(rm_snap), .rm_sel(rm_sel), .rm_addr(rm_addr), .rm_word(rm_word),
      .disp_out(con_disp_out), .disp_rotate(con_disp_rotate),
      .sleep_set(con_sleep_set), .sleep_secs(con_sleep_secs), .wake(con_wake),
      .disp_fitted(1'b1), .sleep_q(disp_sleep_setting), .asleep(disp_asleep),
      .underrun(disp_underrun_s2), .rd_error(disp_rd_error), .err_clear(con_err_clear),
      .steady_lamps(con_steady_lamps)
  );

  // The debug cable's page, which QUUX has not got, and every other address.
  cadr_gp0_default #(.ID_W(4), .LEN_W(8)) u_lw_dbg_rest (
      .clk(clk), .rst(h2f_rst),
      .s_awvalid(lwd_awvalid), .s_awid(lwd_awid), .s_awready(lwd_awready),
      .s_wlast(lwd_wlast), .s_wvalid(lwd_wvalid), .s_wready(lwd_wready),
      .s_bresp(lwd_bresp), .s_bid(lwd_bid), .s_bvalid(lwd_bvalid),
      .s_bready(lwd_bready),
      .s_arlen(lwd_arlen), .s_arid(lwd_arid), .s_arvalid(lwd_arvalid),
      .s_arready(lwd_arready),
      .s_rdata(lwd_rdata), .s_rresp(lwd_rresp), .s_rid(lwd_rid),
      .s_rlast(lwd_rlast), .s_rvalid(lwd_rvalid), .s_rready(lwd_rready)
  );
  cadr_gp0_default #(.ID_W(4), .LEN_W(8)) u_lw_rest (
      .clk(clk), .rst(h2f_rst),
      .s_awvalid(lwx_awvalid), .s_awid(lwx_awid), .s_awready(lwx_awready),
      .s_wlast(lwx_wlast), .s_wvalid(lwx_wvalid), .s_wready(lwx_wready),
      .s_bresp(lwx_bresp), .s_bid(lwx_bid), .s_bvalid(lwx_bvalid),
      .s_bready(lwx_bready),
      .s_arlen(lwx_arlen), .s_arid(lwx_arid), .s_arvalid(lwx_arvalid),
      .s_arready(lwx_arready),
      .s_rdata(lwx_rdata), .s_rresp(lwx_rresp), .s_rid(lwx_rid),
      .s_rlast(lwx_rlast), .s_rvalid(lwx_rvalid), .s_rready(lwx_rready)
  );

  // ------------------------------------------------- the display output
  //
  // `cadr_de25.sv`'s, with this machine's picture: the video controller's
  // frame buffer at the display base, `VIDEO_W` by `VIDEO_H` at a bit a
  // pixel, filling VESA's 1280 by 1024 raster; no color board, so the map
  // reads zero; word 210's black-on-white at `bow`.  Its reset is the
  // memory port's own (`!port_live`, `cadr_de25.sv` has why) and its
  // `fabric_rst` tied low.  **ITS SECOND IS THE PERIOD'S**, `SECOND_T`.
  logic        pixel_locked;
  logic        pclk;                    // the mode's pixel clock, in fabric
  logic [3:0]  prst_sync;
  logic        prst;
  logic        disp_de, disp_hsync, disp_vsync, disp_mute, disp_sleep_due;
  logic [7:0]  disp_red, disp_green, disp_blue;
  logic        disp_underrun;
  logic [3:0]  disp_map_a;
  logic        disp_rst;
  always_ff @(posedge clk) disp_rst <= !port_live;

  cadr_de25_pixel_pll u_pixel_clock (
      .refclk  (clock50_0),
      .rst     (ninit_done),
      .outclk_0(pclk),
      .locked  (pixel_locked)
  );
  always_ff @(posedge pclk) prst_sync <= {prst_sync[2:0], rst || !pixel_locked};
  assign prst = prst_sync[3];

  cadr_display_out #(
      .BASE(DISPLAY_BASE),
      .COLOR_BASE(cadr_ddr_map::COLOR_DISPLAY_BASE),
      .PIC_W(VIDEO_W), .PIC_H(VIDEO_H), .WORDS_PER_LINE(VIDEO_W / 32),
      .SECOND_T(SECOND_T)
  ) u_display (
      .clk(clk), .rst(disp_rst), .fabric_rst(1'b0),
      .m_araddr(dm_araddr), .m_arlen(dm_arlen), .m_arsize(dm_arsize),
      .m_arburst(dm_arburst), .m_arvalid(dm_arvalid), .m_arready(dm_arready),
      .m_rdata(dm_rdata), .m_rresp(dm_rresp), .m_rlast(dm_rlast),
      .m_rvalid(dm_rvalid), .m_rready(dm_rready),
      .out_sel(con_disp_out), .rotate(con_disp_rotate),
      .bow(video_bow), .err_clear(con_err_clear),
      .sleep_set(con_sleep_set), .sleep_secs(con_sleep_secs),
      .wake(con_wake), .sleep_setting(disp_sleep_setting),
      .sleep_due(disp_sleep_due), .asleep(disp_asleep),
      .pclk(pclk), .prst(prst),
      .map_a(disp_map_a), .map_q(24'd0),
      .mute(disp_mute),
      .de(disp_de), .hsync(disp_hsync), .vsync(disp_vsync),
      .red(disp_red), .green(disp_green), .blue(disp_blue),
      .underrun(disp_underrun), .rd_error(disp_rd_error)
  );

  // The underrun is the pixel domain's: two flops into this one for the
  // console's word 42.  Not reset, following their source alone.
  logic disp_underrun_s1;
  always_ff @(posedge clk) begin
    disp_underrun_s1 <= disp_underrun;
    disp_underrun_s2 <= disp_underrun_s1;
  end

  // The video bus, registered on the pixel clock; red in the top byte.
  logic [23:0] vid_d;
  logic        vid_de, vid_hs, vid_vs;
  always_ff @(posedge pclk) begin
    vid_d  <= {disp_red, disp_green, disp_blue};
    vid_de <= disp_de;
    vid_hs <= disp_hsync;
    vid_vs <= disp_vsync;
  end
  assign hdmi_d     = vid_d;
  assign hdmi_de    = vid_de;
  assign hdmi_hsync = vid_hs;
  assign hdmi_vsync = vid_vs;

  // The forwarded clock and its gate, the enable taken while it is low.
  logic pclk_on;
  always_ff @(negedge pclk) pclk_on <= !disp_mute;
  assign hdmi_pclk = pclk && pclk_on;

  // The transmitter's registers: once out of the fabric's reset, and again
  // at every wake.
  logic asleep_q, hdmi_wake_edge;
  always_ff @(posedge clk) asleep_q <= rst ? 1'b0 : disp_asleep;
  assign hdmi_wake_edge = asleep_q && !disp_asleep;

  logic hdmi_scl_oe, hdmi_sda_oe, hdmi_configured, hdmi_failed;
  logic [5:0] hdmi_writes;
  cadr_adv7513 u_adv7513 (
      .clk(clk), .rst(rst),
      .restart(hdmi_wake_edge),
      .configured(hdmi_configured), .failed(hdmi_failed), .writes(hdmi_writes),
      .scl_i(hdmi_scl), .scl_oe(hdmi_scl_oe),
      .sda_i(hdmi_sda), .sda_oe(hdmi_sda_oe)
  );
  assign hdmi_scl = hdmi_scl_oe ? 1'b0 : 1'bz;
  assign hdmi_sda = hdmi_sda_oe ? 1'b0 : 1'bz;

  // ------------------------------------------------------------ the lamps
  //
  // The clock lamp counts the machine's clock and is not reset; the others
  // are registered on the way to the pad.
  logic [25:0] tick;
  always_ff @(posedge clk) tick <= tick + 26'd1;

  logic clock_lamp, cycle_lamp;
  cadr_lamp_clock u_lamp_clock (
      .steady(con_steady_lamps), .locked(pll_locked), .blink(tick[25]),
      .lit(clock_lamp)
  );
  cadr_lamp_microcycle #(.HOLD_T(HOLD_T)) u_lamp_microcycle (
      .clk(clk), .rst(mach_rst), .steady(con_steady_lamps),
      .retired(obs_commit[15]), .lit(cycle_lamp)
  );

  // The disk lamp: lit for `DISK_LIT_T` clocks, about 42 ms, re-armed by
  // every block.
  logic        run_lamp, disk_lit, errhalt_lamp;
  logic [$clog2(DISK_LIT_T + 1)-1:0] disk_lit_t;
  always_ff @(posedge clk) begin
    if (mach_rst) begin
      run_lamp     <= 1'b0;
      disk_lit     <= 1'b0;
      disk_lit_t   <= '0;
      errhalt_lamp <= 1'b0;
    end else begin
      run_lamp     <= !obs_halted;
      errhalt_lamp <= obs_errhalt != 2'd0;
      if (disk_lit_t != '0) disk_lit_t <= disk_lit_t - 1'b1;
      else disk_lit <= 1'b0;
      if (ch_active) begin
        disk_lit   <= 1'b1;
        disk_lit_t <= ($clog2(DISK_LIT_T + 1))'(DISK_LIT_T - 1);
      end
    end
  end

  // Lit low: LEDR0 running, LEDR1 the clock, LEDR2 microcycles, LEDR3 the
  // disk, LEDR4 an error halt, LEDR5 dark, LEDR6 the memory port, LEDR7 dark.
  assign led = ~{1'b0, port_live, 1'b0, errhalt_lamp, disk_lit, cycle_lamp, clock_lamp, run_lamp};

  // JP1's eight pads, which QUUX has not got: undriven, pulled down by the
  // project.
  assign jp1_pin31 = 1'bz;
  assign jp1_pin32 = 1'bz;
  assign jp1_pin33 = 1'bz;
  assign jp1_pin34 = 1'bz;
  assign jp1_pin35 = 1'bz;
  assign jp1_pin36 = 1'bz;
  assign jp1_pin37 = 1'bz;
  assign jp1_pin38 = 1'bz;

  // What nothing on this board reads: the core's observations, the tied-off
  // cable, KEY0 and the switches, the faces' interrupts, and what neither
  // splitter reads of a transaction (`cadr_de25.sv` has why each is read
  // here).
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{obs_cs, obs_rd, obs_ex, obs_wb, obs_commit[14:0], obs_pdlptr, obs_pdlidx,
                    obs_spcptr, obs_q, obs_vma, obs_md, obs_lc, obs_ic, obs_opnd, obs_ea, obs_em,
                    obs_ob, obs_oalow, obs_oahigh, obs_grant, obs_gaddr, obs_mdl, obs_mdword,
                    obs_reg, obs_raddr, obs_queue, obs_inflight, ro_word,
                    fd_doorbell, fd_prod, fd_enabled,
                    chaos_tx_len, chaos_tx_valid, chaos_tx_word, chaos_tx_clear, chaos_reset, chaos_csr,
                    chaos_bits,
                    axi_one_write_id, axi_read_clocks, axi_write_clocks, qm_awid,
                    h2fc_awaddr, h2fc_araddr, h2fc_awlen, h2fc_wdata, h2fc_wstrb,
                    h2fs_awaddr, h2fs_araddr, h2fs_awlen, h2fs_wdata, h2fs_wstrb,
                    drive_read_only[7:0], drive_present[7:1], drive_timed, obs_transfer,
                    lwc_awaddr[31:12], lwc_araddr[31:12],
                    lwd_awaddr, lwd_araddr, lwd_awlen, lwd_wdata, lwd_wstrb,
                    disp_sleep_due, disp_map_a, pack_irq,
                    hdmi_configured, hdmi_failed, hdmi_writes,
                    btn[0], sw,
                    f2s_buser, f2s_ruser, gp_out[31:2],
                    h2f_awsize, h2f_arsize, h2f_awprot, h2f_arprot,
                    h2f_awburst, h2f_arburst, h2f_awlock, h2f_arlock,
                    h2f_awcache, h2f_arcache,
                    lw_awsize, lw_arsize, lw_awprot, lw_arprot,
                    lw_awburst, lw_arburst, lw_awlock, lw_arlock,
                    lw_awcache, lw_arcache};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
