// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15 ON THE AMD KRIA KR260** (contract G3 revision 15,
// §12.3): `rtl/machine/quux15_core.sv`, the pipelined machine, on this
// board's processing system, at the period its fit closes.  Revisions 13 and
// 14 and the CADR stay `cadr_kr260.sv`'s; this machine has another face to
// the board, so it has its own top level, with that file's facts of the
// board and the part kept as they are:
//
//   - **THE CLOCK IS THE CARRIER'S 25 MHz, ON C3, THROUGH AN `MMCME4_BASE`**,
//     25 x 40 = 1000 MHz at the VCO, divided by `CLKOUT0_DIVIDE_F`: the
//     period in nanoseconds, `PERIOD_NS`, which the machine is told in its
//     units of 0.5 ns (`period`, A15b.12) and the console face reports.
//   - **THE PROCESSING SYSTEM IS `cadr_ps8.sv`'s `PS8`**, every port clocked
//     by the machine's clock and live while `pl_resetn0` is high.
//   - **MAIN MEMORY IS ON `S_AXI_HP0_FPD`**, 32M words of packed storage at
//     `CADR_DDR_MAP_KR260`'s revision-13 base (`QUUX13_MAIN_BASE`), where
//     revisions 13 and 14 keep theirs and the board's revision-13 device
//     tree reserves it, the frame buffer at the display base: the machine's
//     own 64-bit master
//     (`quux15_axi_master.sv`, inside the core's port) behind
//     `quux_axi_narrow128.sv` on the 128-bit port.  Its writes carry one
//     AXI ID (A15b.5), so the port's one ID answers them in order.
//   - **THE CONSOLE FACE IS ON `M_AXI_HPM1_FPD` AT 0xB000_0000**
//     (`rtl/plumbing/quux15_face.sv`), the console's words: the machine's
//     counts, its reset, the diagnostic registers, the readout of the
//     halted machine a checkpoint takes, the build stamp, main memory's
//     size, the video controller's, the period and the real-time clock's
//     start.  The machine comes out of reset running from its PROM, as
//     revisions 13 and 14 do on this board.  Every
//     other address on both master ports is answered with a constant
//     (`cadr_gp0_default.sv`), since a read nothing answers hangs both Arm
//     cores.
//   - **THE LATENCY PROBE ON THE FACE'S PAGE 3**
//     (`rtl/plumbing/quux15_mem_probe.sv`), at HP0's own handshakes as the
//     DE25-Nano's is at its bridge's: a read from the port taking its
//     address to its last beat, a write from the port taking its address to
//     its response, in clocks of the machine's clock
//     (`tb/quux15_kr260_probe_tb.cpp` holds it).
//   - **THE DISK PACKS ON `M_AXI_HPM0_FPD` AND `S_AXI_HP2_FPD`**, as
//     `cadr_kr260.sv` has them: block-disk's block store (the core's
//     `quux15_block_walk.sv`) served by `cadr_disk_pack.sv`, its registers at
//     0xA000_0000 through `cadr_gp0_split.sv`, its bursts on HP2 through
//     `cadr_axi_burst128.sv`, its interrupt on `pl_ps_irq0`<0>, and
//     `cadr-disk-packs --machine quux` the drive.  The split's network and
//     serial line pages are answered with a constant.
//   - **THE KEYBOARD AND THE MOUSE ON `M_AXI_HPM0_FPD`**, the split's input
//     page at 0xA000_3000, as `cadr_kr260.sv` has it: `cadr_input_cables.sv`,
//     unchanged but for its mouse's step, which comes from the period, so
//     that `cadr-usb-input` and `cadr-terminal` drive it as on revision 14.
//     Its word and the mouse's seven lines go to the core's register page
//     (`quux15_input.sv`), whose busy stands in for the card's `KBD READY`;
//     there is no I/O board, and so no `MOUSE READY`.
//   - **THE FILE DEVICE'S PAGE AND THE REAL-TIME CLOCK'S SETTER ON
//     `M_AXI_HPM0_FPD` AT 0xA000_4000** (`rtl/plumbing/quux_fd_face.sv`,
//     IDENT "QF13" as revisions 13 and 14 have it: main memory packed
//     storage at the same base, the rings' bases 28 bits), the map onto the
//     core's host side (`quux15_devices.sv`), so `quux-file-device` serves
//     HOST: and sets the clock as it does on revisions 13 and 14.
//   - **THE DISPLAY OUTPUT ON `S_AXI_HP3_FPD` AND THE DISPLAYPORT'S LIVE
//     VIDEO**, as `cadr_kr260.sv` has it: `rtl/plumbing/cadr_display_out.sv`
//     reading the video controller's frame buffer out of DDR at the display
//     base through `cadr_axi_rd128.sv`, at CEA-861's 1920x1080 at 60 Hz on
//     `cadr_kr260_pixel_clock.sv`'s pixel clock, into the PS8's live video,
//     which `cadr-displayport` brings up.  The cache is write-through, so DDR
//     holds every word the machine has written to the frame buffer once its
//     write is answered (A15b.5).  The video controller is the board's
//     1920 by 1080 (contract HD), `VIDEO_W` by `VIDEO_H` below, which the
//     core's feature words 11 and 12 and its frame buffer, the console's
//     word 39 and the display's picture all take; word 210's black-on-white
//     reaches the picture.  The console face's words 33 to 36 drive it, as
//     `cadr_console.sv`'s do, and its word 42 reads and clears its two
//     sticky bits.
//   - **NO NETWORK**: QUUX has no Chaosnet cable.  The core's interface
//     (`quux15_chaos.sv`) is built and its cable tied off as a cable with
//     nothing on it: a frame sent goes nowhere and is away at once, nothing
//     arrives, and the address switches read 0.  No serial line, which
//     QUUX drops with the I/O board, and no debug cable either (contract
//     Q5): PMOD1's pads undriven.
//   - **TWO LAMPS**: UF1 the microcycle lamp (`cadr_lamp_microcycle.sv`),
//     blinking with the committed microcycles, so it flickers while the
//     machine runs and freezes when it stops, or steady at the console's
//     word 35; UF2 lit at an error halt.  **THE FAN IS DRIVEN ON**,
//     `fan_en_b` low, as every KR260 bitstream holds it.
//   - **EVERY TIME IN CLOCKS IS THE PERIOD'S** (the MP5a review's R9): the
//     mouse's step, the display's second and the lamp's hold are durations,
//     each turned into clocks here from `PERIOD_NS`, where the
//     modules' own defaults are counts of the 10 ns tick.

`default_nettype none

module quux15_kr260 #(
    parameter string PROM_HEX = "build/quux15_transfer_prom.hex",
    // **THE PERIOD**, in nanoseconds: the MMCM's divide below, the one place
    // it is decided on this board.
    parameter int unsigned PERIOD_NS = 13
) (
    input  var logic       clk25,      // the carrier's 25 MHz, pin C3
    output var logic       uf1,
    output var logic       uf2,
    output var logic       fan_en_b,
    inout  wire  [7:0]     pmod1
);

  localparam logic [31:0] MAIN_BASE    = 32'h5A00_0000;
  localparam logic [31:0] DISPLAY_BASE = 32'h6400_0000;
  if (cadr_ddr_map::QUUX13_MAIN_BASE != MAIN_BASE || cadr_ddr_map::DISPLAY_BASE != DISPLAY_BASE) begin : g_map
    $error("cadr_ddr_map's bases are %h and %h, and the Kria KR260's are %h and %h: define CADR_DDR_MAP_KR260",
           cadr_ddr_map::QUUX13_MAIN_BASE, cadr_ddr_map::DISPLAY_BASE, MAIN_BASE, DISPLAY_BASE);
  end
  // **MAIN MEMORY: 32M WORDS**, 512 units of 64K, packed storage filling
  // the board's reservation from `MAIN_BASE` to the display (contract G2 §3;
  // `cadr_ddr_map.sv`'s `QUUX13_MAIN_WORDS_MAX`), as revisions 13 and 14
  // have it on this board.  The console's word 37 says it.
  localparam int unsigned MAIN_WORDS = 32'h0200_0000;
  if (MAIN_WORDS != cadr_ddr_map::QUUX13_MAIN_WORDS_MAX) begin : g_main_words
    $error("the Kria KR260's main memory is %0d words, and its reservation holds %0d",
           MAIN_WORDS, cadr_ddr_map::QUUX13_MAIN_WORDS_MAX);
  end

  // **THE VIDEO CONTROLLER: 1920 BY 1080**, the board's raster (contract HD;
  // muir's `--video-size 1920x1080`, its `VIDEO_MAX_SIZE`): 60 words a line,
  // 64,800 words of frame buffer, inside the display's reservation.
  localparam int unsigned VIDEO_W = 1920;
  localparam int unsigned VIDEO_H = 1080;
  if (VIDEO_W / 32 * VIDEO_H > cadr_ddr_map::VIDEO_WORDS_MAX) begin : g_video_words
    $error("the Kria KR260's video controller is %0d words, and the display's reservation holds %0d",
           VIDEO_W / 32 * VIDEO_H, cadr_ddr_map::VIDEO_WORDS_MAX);
  end

  // **THE BOARD NAME** (contract HD): feature words 20-24, which the band's
  // herald prints, "Machine Type QUUX on Kria KR260"; `cadr_kr260.sv`'s for
  // revision 13.
  localparam logic [8*64-1:0] BOARD = "Kria KR260";

  // **THE TIMES IN CLOCKS, AT THE PERIOD** (R9): each a duration the module
  // states at the 10 ns tick, here at `PERIOD_NS`.  The display's second,
  // rounded to the nearest clock; the lamp's hold, 2^22 ticks of 10 ns,
  // rounded up; the mouse's step below.
  localparam int unsigned SECOND_T = (1_000_000_000 + PERIOD_NS / 2) / PERIOD_NS;
  localparam int unsigned HOLD_T   = (41_943_040 + PERIOD_NS - 1) / PERIOD_NS;

  // ------------------------------------------------------------ the clock
  logic clk_fb, clk_raw, clk, mmcm_locked;

  /* verilator lint_off PINCONNECTEMPTY */
  MMCME4_BASE #(
      .CLKIN1_PERIOD  (40.000),          // 25 MHz
      .DIVCLK_DIVIDE  (1),
      .CLKFBOUT_MULT_F(40.000),          // 1000 MHz at the VCO
      .CLKOUT0_DIVIDE_F(real'(PERIOD_NS)) // the period, in nanoseconds
  ) u_mmcm (
      .CLKIN1  (clk25),
      .CLKFBIN (clk_fb),
      .CLKFBOUT(clk_fb),
      .CLKOUT0 (clk_raw),
      .LOCKED  (mmcm_locked),
      .PWRDWN  (1'b0),
      .RST     (1'b0),
      .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
      .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
      .CLKFBOUTB()
  );
  /* verilator lint_on PINCONNECTEMPTY */

  BUFG u_bufg (.I(clk_raw), .O(clk));

  // ------------------------------------------------------------- the reset
  //
  // The MMCM's lock, synchronized; the ports' `pl_resetn0` (EMIO GPIO 95),
  // synchronized; and the console face's reset, RESET's key's pulse.  The
  // first two are the core's hard reset, taken at once; the third is a
  // request, which the core takes once its memory port has drained, the
  // master's writes landed and its reads in (`quux15_core.sv`'s `rq_*`).
  // `mach_rst` is the core's reset as it is, for the lamps and the input
  // page.
  logic [3:0] rst_sync;
  logic       rst;
  always_ff @(posedge clk) rst_sync <= {rst_sync[2:0], !mmcm_locked};
  assign rst = rst_sync[3];

  logic [95:0] gpio_o;
  logic [2:0]  port_rst_sync;
  always_ff @(posedge clk) port_rst_sync <= {port_rst_sync[1:0], gpio_o[95]};
  logic axi_rst;
  assign axi_rst = !port_rst_sync[2];

  logic face_req, hard_rst, mach_req, mach_rst;
  logic core_rst_pend, core_rst_on, core_rst_cut;
  always_ff @(posedge clk) begin
    hard_rst <= rst || axi_rst;
    mach_req <= face_req;
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

  // The machine's 64-bit AXI master.
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
      .MAIN_WORDS(MAIN_WORDS),
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
      .period(7'(2 * PERIOD_NS)), .rtc_start(rtc_start),
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

  // ------------------------------------------------------- main memory, HP0
  logic [31:0]  hp0_awaddr, hp0_araddr;
  logic [7:0]   hp0_awlen, hp0_arlen;
  logic [2:0]   hp0_awsize, hp0_arsize;
  logic [127:0] hp0_wdata, hp0_rdata;
  logic [15:0]  hp0_wstrb;
  logic         hp0_awvalid, hp0_awready, hp0_wlast, hp0_wvalid, hp0_wready;
  logic         hp0_arvalid, hp0_arready, hp0_rlast, hp0_rvalid;

  // The machine's bursts are at most five beats of eight bytes: AXI3's
  // four bits of length and two of size hold them.
  quux_axi_narrow128 u_narrow (
      .clk(clk), .rst(axi_rst),
      .s_awaddr(qm_awaddr), .s_awlen(qm_awlen[3:0]), .s_awsize(qm_awsize[1:0]),
      .s_awvalid(qm_awvalid), .s_awready(qm_awready),
      .s_wdata(qm_wdata), .s_wstrb(qm_wstrb), .s_wlast(qm_wlast),
      .s_wvalid(qm_wvalid), .s_wready(qm_wready),
      .s_araddr(qm_araddr), .s_arlen(qm_arlen[3:0]), .s_arsize(qm_arsize[1:0]),
      .s_arvalid(qm_arvalid), .s_arready(qm_arready),
      .s_rdata(qm_rdata), .s_rready(qm_rready),
      .m_awaddr(hp0_awaddr), .m_awlen(hp0_awlen), .m_awsize(hp0_awsize),
      .m_awvalid(hp0_awvalid), .m_awready(hp0_awready),
      .m_wdata(hp0_wdata), .m_wstrb(hp0_wstrb), .m_wlast(hp0_wlast),
      .m_wvalid(hp0_wvalid), .m_wready(hp0_wready),
      .m_araddr(hp0_araddr), .m_arlen(hp0_arlen), .m_arsize(hp0_arsize),
      .m_arvalid(hp0_arvalid), .m_arready(hp0_arready),
      .m_rdata(hp0_rdata), .m_rlast(hp0_rlast), .m_rvalid(hp0_rvalid)
  );
  assign qm_rlast  = hp0_rlast;
  assign qm_rvalid = hp0_rvalid;

  // ------------------------------------------------ the port's own tally
  //
  // What the machine asked its memory port for and what the processing system
  // answered, `rtl/plumbing/cadr_mem_count.sv`, on EMIO banks 3 and 4, as
  // `cadr_kr260.sv` has it: the board's programs read its marker bits before
  // they touch a master port (`cadr_mem.c`'s guard).  An ask is a read or a
  // write address taken, counted at its rise, so that addresses taken on
  // consecutive clocks count once; an answer is the processing system's own
  // handshake, B or the last R, and is exact.  And the machine's clock,
  // counted and Gray coded, on bank 5's EMIO 94:64; EMIO 95 is `pl_resetn0`'s
  // own bit, left low on the way in.
  logic [63:0] tally;
  logic        count_req, count_write, count_bvalid, count_bready;
  logic        count_rvalid, count_rready, count_rlast;
  always_ff @(posedge clk) begin
    count_req    <= (qm_arvalid && qm_arready) || (qm_awvalid && qm_awready);
    count_write  <= qm_awvalid && qm_awready;
    count_bvalid <= qm_bvalid;
    count_bready <= qm_bready;
    count_rvalid <= hp0_rvalid;
    count_rready <= qm_rready;
    count_rlast  <= hp0_rlast;
  end
  cadr_mem_count u_count (
      .clk(clk), .rst(rst),
      .req(count_req), .req_write(count_write),
      .bvalid(count_bvalid), .bready(count_bready),
      .rvalid(count_rvalid), .rready(count_rready), .rlast(count_rlast),
      .gpio(tally)
  );
  logic [30:0] clk_count, clk_gray;
  always_ff @(posedge clk) begin
    clk_count <= clk_count + 31'd1;
    clk_gray  <= clk_count ^ (clk_count >> 1);
  end
  logic [95:0] gpio_i;
  assign gpio_i = {1'b0, clk_gray, tally};

  // ------------------------------------------------- the latency probe
  //
  // `rtl/plumbing/quux15_mem_probe.sv` at HP0's own handshakes, as the
  // DE25-Nano's port times its bridge's: a read from the port taking its
  // address to the port's last beat of it, a write from the port taking its
  // address to its response, in clocks of the machine's clock, read on the
  // console face's page 3.  The machine is alone on HP0, so no ID is
  // compared.  Each handshake is copied on one edge, so that an address and
  // its answer are both a clock late and the latency is the port's.  The
  // queues are as deep as the master's bursts in flight: a line's two
  // reads, and its sixteen posted writes each split in two at most.  They
  // are forgotten with the port's reset; the figures are the fabric's.
  logic probe_run, probe_stop;
  logic pr_ar, pr_r, pr_aw, pr_b;
  always_ff @(posedge clk) begin
    pr_ar <= hp0_arvalid && hp0_arready;
    pr_r  <= hp0_rvalid && qm_rready && hp0_rlast;
    pr_aw <= hp0_awvalid && hp0_awready;
    pr_b  <= qm_bvalid && qm_bready;
  end
  logic             pr_running, pr_lost, pr_sat;
  logic [31:0]      pr_rd_count, pr_wr_count;
  logic [47:0]      pr_rd_sum, pr_wr_sum;
  logic [19:0]      pr_rd_max, pr_wr_max;
  logic [2:0]       probe_state;
  logic [7:0][31:0] probe_words;
  quux15_mem_probe #(.T_W(20), .RD_DEPTH(4), .WR_DEPTH(32)) u_probe (
      .clk(clk), .rst(rst), .port_rst(axi_rst),
      .run(probe_run), .stop(probe_stop),
      .ar_take(pr_ar), .r_last(pr_r), .aw_take(pr_aw), .b_take(pr_b),
      .running(pr_running), .lost(pr_lost), .saturated(pr_sat),
      .rd_count(pr_rd_count), .rd_sum(pr_rd_sum), .rd_max(pr_rd_max),
      .wr_count(pr_wr_count), .wr_sum(pr_wr_sum), .wr_max(pr_wr_max)
  );
  assign probe_state = {pr_lost, pr_sat, pr_running};
  assign probe_words = {{12'd0, pr_wr_max}, {16'd0, pr_wr_sum[47:32]}, pr_wr_sum[31:0], pr_wr_count,
                        {12'd0, pr_rd_max}, {16'd0, pr_rd_sum[47:32]}, pr_rd_sum[31:0], pr_rd_count};

  // ------------------------------------- the master ports: HPM0 and HPM1
  logic [39:0]  hpm0_awaddr, hpm0_araddr, hpm1_awaddr, hpm1_araddr;
  logic [7:0]   hpm0_awlen, hpm0_arlen, hpm1_awlen, hpm1_arlen;
  logic [15:0]  hpm0_awid, hpm0_arid, hpm0_bid, hpm0_rid;
  logic [15:0]  hpm1_awid, hpm1_arid, hpm1_bid, hpm1_rid;
  logic [127:0] hpm0_wdata, hpm0_rdata, hpm1_wdata, hpm1_rdata;
  logic [15:0]  hpm0_wstrb, hpm1_wstrb;
  logic [1:0]   hpm0_bresp, hpm0_rresp, hpm1_bresp, hpm1_rresp;
  logic         hpm0_awvalid, hpm0_awready, hpm0_wlast, hpm0_wvalid, hpm0_wready;
  logic         hpm0_bvalid, hpm0_bready, hpm0_arvalid, hpm0_arready;
  logic         hpm0_rlast, hpm0_rvalid, hpm0_rready;
  logic         hpm1_awvalid, hpm1_awready, hpm1_wlast, hpm1_wvalid, hpm1_wready;
  logic         hpm1_bvalid, hpm1_bready, hpm1_arvalid, hpm1_arready;
  logic         hpm1_rlast, hpm1_rvalid, hpm1_rready;

  // HPM0: `cadr_gp0_split.sv`'s pages at 0xA000_0000, as `cadr_kr260.sv`
  // has them: the disk packs' registers, the input's page, the file
  // device's page, and the pages of the network and the serial line,
  // which QUUX has not got, answered with a constant; and every other
  // address.
  logic [31:0] gp0_rdata, gp0_wdata;
  logic [3:0]  gp0_wstrb;
  cadr_axi_lanes128 u_hpm0_lanes (
      .s_wdata(hpm0_wdata), .s_wstrb(hpm0_wstrb), .s_rdata(hpm0_rdata),
      .m_wdata(gp0_wdata), .m_wstrb(gp0_wstrb), .m_rdata(gp0_rdata)
  );
  // The splitter and the faces take the port's reset alone, the faces the
  // fabric's at `fabric_rst`, as `cadr_kr260.sv`'s.
  logic gp0_rst_s;
  always_ff @(posedge clk) gp0_rst_s <= !port_rst_sync[2];

  logic [31:0] gp0p_awaddr, gp0p_araddr;
  logic [31:0] gp0p_wdata, gp0p_rdata;
  logic [7:0]  gp0p_awlen, gp0p_arlen;
  logic [3:0]  gp0p_wstrb;
  logic [15:0] gp0p_awid, gp0p_arid, gp0p_bid, gp0p_rid;
  logic        gp0p_awvalid, gp0p_awready, gp0p_wlast, gp0p_wvalid, gp0p_wready;
  logic        gp0p_bvalid, gp0p_bready, gp0p_arvalid, gp0p_arready;
  logic        gp0p_rlast, gp0p_rvalid, gp0p_rready;
  logic [1:0]  gp0p_bresp, gp0p_rresp;
  logic [11:0] gp0c_awaddr, gp0c_araddr;
  logic [31:0] gp0c_wdata, gp0c_rdata;
  logic [7:0]  gp0c_awlen, gp0c_arlen;
  logic [3:0]  gp0c_wstrb;
  logic [15:0] gp0c_awid, gp0c_arid, gp0c_bid, gp0c_rid;
  logic        gp0c_awvalid, gp0c_awready, gp0c_wlast, gp0c_wvalid, gp0c_wready;
  logic        gp0c_bvalid, gp0c_bready, gp0c_arvalid, gp0c_arready;
  logic        gp0c_rlast, gp0c_rvalid, gp0c_rready;
  logic [1:0]  gp0c_bresp, gp0c_rresp;
  logic [11:0] gp0s_awaddr, gp0s_araddr;
  logic [31:0] gp0s_wdata, gp0s_rdata;
  logic [7:0]  gp0s_awlen, gp0s_arlen;
  logic [3:0]  gp0s_wstrb;
  logic [15:0] gp0s_awid, gp0s_arid, gp0s_bid, gp0s_rid;
  logic        gp0s_awvalid, gp0s_awready, gp0s_wlast, gp0s_wvalid, gp0s_wready;
  logic        gp0s_bvalid, gp0s_bready, gp0s_arvalid, gp0s_arready;
  logic        gp0s_rlast, gp0s_rvalid, gp0s_rready;
  logic [1:0]  gp0s_bresp, gp0s_rresp;
  logic [11:0] gp0i_awaddr, gp0i_araddr;
  logic [31:0] gp0i_wdata, gp0i_rdata;
  logic [7:0]  gp0i_awlen, gp0i_arlen;
  logic [3:0]  gp0i_wstrb;
  logic [15:0] gp0i_awid, gp0i_arid, gp0i_bid, gp0i_rid;
  logic        gp0i_awvalid, gp0i_awready, gp0i_wlast, gp0i_wvalid, gp0i_wready;
  logic        gp0i_bvalid, gp0i_bready, gp0i_arvalid, gp0i_arready;
  logic        gp0i_rlast, gp0i_rvalid, gp0i_rready;
  logic [1:0]  gp0i_bresp, gp0i_rresp;
  logic [11:0] gp0f_awaddr, gp0f_araddr;
  logic [31:0] gp0f_wdata, gp0f_rdata;
  logic [7:0]  gp0f_awlen, gp0f_arlen;
  logic [3:0]  gp0f_wstrb;
  logic [15:0] gp0f_awid, gp0f_arid, gp0f_bid, gp0f_rid;
  logic        gp0f_awvalid, gp0f_awready, gp0f_wlast, gp0f_wvalid, gp0f_wready;
  logic        gp0f_bvalid, gp0f_bready, gp0f_arvalid, gp0f_arready;
  logic        gp0f_rlast, gp0f_rvalid, gp0f_rready;
  logic [1:0]  gp0f_bresp, gp0f_rresp;
  logic [31:0] gp0d_rdata;
  logic [7:0]  gp0d_arlen;
  logic [15:0] gp0d_awid, gp0d_arid, gp0d_bid, gp0d_rid;
  logic        gp0d_awvalid, gp0d_awready, gp0d_wlast, gp0d_wvalid, gp0d_wready;
  logic        gp0d_bvalid, gp0d_bready, gp0d_arvalid, gp0d_arready;
  logic        gp0d_rlast, gp0d_rvalid, gp0d_rready;
  logic [1:0]  gp0d_bresp, gp0d_rresp;

  cadr_gp0_split #(
      .PACK_BASE(32'hA000_0000), .CHAOS_BASE(32'hA000_1000),
      .SER_BASE(32'hA000_2000), .INPUT_BASE(32'hA000_3000),
      .FD_BASE(32'hA000_4000), .HAS_FD(1'b1),
      .ID_W(16), .LEN_W(8)
  ) u_gp0_split (
      .clk(clk), .rst(gp0_rst_s),
      .s_awaddr(hpm0_awaddr[31:0]), .s_awlen(hpm0_awlen), .s_awid(hpm0_awid),
      .s_awvalid(hpm0_awvalid), .s_awready(hpm0_awready),
      .s_wdata(gp0_wdata), .s_wstrb(gp0_wstrb), .s_wlast(hpm0_wlast),
      .s_wvalid(hpm0_wvalid), .s_wready(hpm0_wready),
      .s_bresp(hpm0_bresp), .s_bid(hpm0_bid), .s_bvalid(hpm0_bvalid), .s_bready(hpm0_bready),
      .s_araddr(hpm0_araddr[31:0]), .s_arlen(hpm0_arlen), .s_arid(hpm0_arid),
      .s_arvalid(hpm0_arvalid), .s_arready(hpm0_arready),
      .s_rdata(gp0_rdata), .s_rresp(hpm0_rresp), .s_rid(hpm0_rid),
      .s_rlast(hpm0_rlast), .s_rvalid(hpm0_rvalid), .s_rready(hpm0_rready),
      .pack_awaddr(gp0p_awaddr), .pack_awlen(gp0p_awlen), .pack_awid(gp0p_awid),
      .pack_awvalid(gp0p_awvalid), .pack_awready(gp0p_awready), .pack_wdata(gp0p_wdata),
      .pack_wstrb(gp0p_wstrb), .pack_wlast(gp0p_wlast), .pack_wvalid(gp0p_wvalid),
      .pack_wready(gp0p_wready), .pack_bresp(gp0p_bresp), .pack_bid(gp0p_bid),
      .pack_bvalid(gp0p_bvalid), .pack_bready(gp0p_bready), .pack_araddr(gp0p_araddr),
      .pack_arlen(gp0p_arlen), .pack_arid(gp0p_arid), .pack_arvalid(gp0p_arvalid),
      .pack_arready(gp0p_arready), .pack_rdata(gp0p_rdata), .pack_rresp(gp0p_rresp),
      .pack_rid(gp0p_rid), .pack_rlast(gp0p_rlast), .pack_rvalid(gp0p_rvalid),
      .pack_rready(gp0p_rready), 
      .chaos_awaddr(gp0c_awaddr), .chaos_awlen(gp0c_awlen), .chaos_awid(gp0c_awid),
      .chaos_awvalid(gp0c_awvalid), .chaos_awready(gp0c_awready), .chaos_wdata(gp0c_wdata),
      .chaos_wstrb(gp0c_wstrb), .chaos_wlast(gp0c_wlast), .chaos_wvalid(gp0c_wvalid),
      .chaos_wready(gp0c_wready), .chaos_bresp(gp0c_bresp), .chaos_bid(gp0c_bid),
      .chaos_bvalid(gp0c_bvalid), .chaos_bready(gp0c_bready), .chaos_araddr(gp0c_araddr),
      .chaos_arlen(gp0c_arlen), .chaos_arid(gp0c_arid), .chaos_arvalid(gp0c_arvalid),
      .chaos_arready(gp0c_arready), .chaos_rdata(gp0c_rdata), .chaos_rresp(gp0c_rresp),
      .chaos_rid(gp0c_rid), .chaos_rlast(gp0c_rlast), .chaos_rvalid(gp0c_rvalid),
      .chaos_rready(gp0c_rready), 
      .ser_awaddr(gp0s_awaddr), .ser_awlen(gp0s_awlen), .ser_awid(gp0s_awid),
      .ser_awvalid(gp0s_awvalid), .ser_awready(gp0s_awready), .ser_wdata(gp0s_wdata),
      .ser_wstrb(gp0s_wstrb), .ser_wlast(gp0s_wlast), .ser_wvalid(gp0s_wvalid),
      .ser_wready(gp0s_wready), .ser_bresp(gp0s_bresp), .ser_bid(gp0s_bid), .ser_bvalid(gp0s_bvalid),
      .ser_bready(gp0s_bready), .ser_araddr(gp0s_araddr), .ser_arlen(gp0s_arlen), .ser_arid(gp0s_arid),
      .ser_arvalid(gp0s_arvalid), .ser_arready(gp0s_arready), .ser_rdata(gp0s_rdata),
      .ser_rresp(gp0s_rresp), .ser_rid(gp0s_rid), .ser_rlast(gp0s_rlast), .ser_rvalid(gp0s_rvalid),
      .ser_rready(gp0s_rready), 
      .in_awaddr(gp0i_awaddr), .in_awlen(gp0i_awlen), .in_awid(gp0i_awid), .in_awvalid(gp0i_awvalid),
      .in_awready(gp0i_awready), .in_wdata(gp0i_wdata), .in_wstrb(gp0i_wstrb), .in_wlast(gp0i_wlast),
      .in_wvalid(gp0i_wvalid), .in_wready(gp0i_wready), .in_bresp(gp0i_bresp), .in_bid(gp0i_bid),
      .in_bvalid(gp0i_bvalid), .in_bready(gp0i_bready), .in_araddr(gp0i_araddr), .in_arlen(gp0i_arlen),
      .in_arid(gp0i_arid), .in_arvalid(gp0i_arvalid), .in_arready(gp0i_arready), .in_rdata(gp0i_rdata),
      .in_rresp(gp0i_rresp), .in_rid(gp0i_rid), .in_rlast(gp0i_rlast), .in_rvalid(gp0i_rvalid),
      .in_rready(gp0i_rready), 
      .fd_awaddr(gp0f_awaddr), .fd_awlen(gp0f_awlen), .fd_awid(gp0f_awid), .fd_awvalid(gp0f_awvalid),
      .fd_awready(gp0f_awready), .fd_wdata(gp0f_wdata), .fd_wstrb(gp0f_wstrb), .fd_wlast(gp0f_wlast),
      .fd_wvalid(gp0f_wvalid), .fd_wready(gp0f_wready), .fd_bresp(gp0f_bresp), .fd_bid(gp0f_bid),
      .fd_bvalid(gp0f_bvalid), .fd_bready(gp0f_bready), .fd_araddr(gp0f_araddr), .fd_arlen(gp0f_arlen),
      .fd_arid(gp0f_arid), .fd_arvalid(gp0f_arvalid), .fd_arready(gp0f_arready), .fd_rdata(gp0f_rdata),
      .fd_rresp(gp0f_rresp), .fd_rid(gp0f_rid), .fd_rlast(gp0f_rlast), .fd_rvalid(gp0f_rvalid),
      .fd_rready(gp0f_rready), 
      .dflt_awid(gp0d_awid), .dflt_awvalid(gp0d_awvalid), .dflt_awready(gp0d_awready),
      .dflt_wlast(gp0d_wlast), .dflt_wvalid(gp0d_wvalid), .dflt_wready(gp0d_wready),
      .dflt_bresp(gp0d_bresp), .dflt_bid(gp0d_bid), .dflt_bvalid(gp0d_bvalid),
      .dflt_bready(gp0d_bready),
      .dflt_arlen(gp0d_arlen), .dflt_arid(gp0d_arid),
      .dflt_arvalid(gp0d_arvalid), .dflt_arready(gp0d_arready),
      .dflt_rdata(gp0d_rdata), .dflt_rresp(gp0d_rresp), .dflt_rid(gp0d_rid),
      .dflt_rlast(gp0d_rlast), .dflt_rvalid(gp0d_rvalid), .dflt_rready(gp0d_rready)
  );

  // The pages not on this board yet, and every other address.
  cadr_gp0_default #(.ID_W(16), .LEN_W(8)) u_gp0_chaos (
      .clk(clk), .rst(gp0_rst_s),
      .s_awvalid(gp0c_awvalid), .s_awid(gp0c_awid), .s_awready(gp0c_awready),
      .s_wlast(gp0c_wlast), .s_wvalid(gp0c_wvalid), .s_wready(gp0c_wready),
      .s_bresp(gp0c_bresp), .s_bid(gp0c_bid), .s_bvalid(gp0c_bvalid), .s_bready(gp0c_bready),
      .s_arlen(gp0c_arlen), .s_arid(gp0c_arid), .s_arvalid(gp0c_arvalid),
      .s_arready(gp0c_arready), .s_rdata(gp0c_rdata), .s_rresp(gp0c_rresp),
      .s_rid(gp0c_rid), .s_rlast(gp0c_rlast), .s_rvalid(gp0c_rvalid), .s_rready(gp0c_rready)
  );
  cadr_gp0_default #(.ID_W(16), .LEN_W(8)) u_gp0_ser (
      .clk(clk), .rst(gp0_rst_s),
      .s_awvalid(gp0s_awvalid), .s_awid(gp0s_awid), .s_awready(gp0s_awready),
      .s_wlast(gp0s_wlast), .s_wvalid(gp0s_wvalid), .s_wready(gp0s_wready),
      .s_bresp(gp0s_bresp), .s_bid(gp0s_bid), .s_bvalid(gp0s_bvalid), .s_bready(gp0s_bready),
      .s_arlen(gp0s_arlen), .s_arid(gp0s_arid), .s_arvalid(gp0s_arvalid),
      .s_arready(gp0s_arready), .s_rdata(gp0s_rdata), .s_rresp(gp0s_rresp),
      .s_rid(gp0s_rid), .s_rlast(gp0s_rlast), .s_rvalid(gp0s_rvalid), .s_rready(gp0s_rready)
  );
  // **THE KEYBOARD AND THE MOUSE**: the input page, its queue flushed by
  // the machine's reset as on revision 14.  The mouse's step is muir's
  // 16,000 ns at this board's period, rounded up.
  localparam int unsigned MOUSE_STEP_T = (16_000 + PERIOD_NS - 1) / PERIOD_NS;
  cadr_input_cables #(.ID_W(16), .LEN_W(8), .MOUSE_STEP_T(MOUSE_STEP_T)) u_input (
      .clk(clk), .rst(gp0_rst_s), .fabric_rst(rst), .mach_rst(mach_rst),
      .s_awaddr(gp0i_awaddr), .s_awlen(gp0i_awlen), .s_awid(gp0i_awid),
      .s_awvalid(gp0i_awvalid), .s_awready(gp0i_awready),
      .s_wdata(gp0i_wdata), .s_wstrb(gp0i_wstrb), .s_wlast(gp0i_wlast),
      .s_wvalid(gp0i_wvalid), .s_wready(gp0i_wready),
      .s_bresp(gp0i_bresp), .s_bid(gp0i_bid), .s_bvalid(gp0i_bvalid),
      .s_bready(gp0i_bready),
      .s_araddr(gp0i_araddr), .s_arlen(gp0i_arlen), .s_arid(gp0i_arid),
      .s_arvalid(gp0i_arvalid), .s_arready(gp0i_arready),
      .s_rdata(gp0i_rdata), .s_rresp(gp0i_rresp), .s_rid(gp0i_rid),
      .s_rlast(gp0i_rlast), .s_rvalid(gp0i_rvalid), .s_rready(gp0i_rready),
      .kbd_strobe(kbd_strobe), .kbd_code(kbd_code),
      .mouse_lines(mouse_lines),
      // `KBD READY` from the register page's FIFO; no `MOUSE READY`.
      .card_csr({2'b00, kbd_busy, 5'b00000})
  );
  // The file device's page and the clock's setter, for Linux's server:
  // revision 13's page, "QF13", as `cadr_kr260.sv` gives revisions 13 and
  // 14, onto the core's host side.
  quux_fd_face #(.IDENT(32'h5146_3133), .ID_W(16), .LEN_W(8)) u_fd_face (
      .clk(clk), .rst(gp0_rst_s),
      .s_awaddr(gp0f_awaddr), .s_awlen(gp0f_awlen), .s_awid(gp0f_awid),
      .s_awvalid(gp0f_awvalid), .s_awready(gp0f_awready),
      .s_wdata(gp0f_wdata), .s_wstrb(gp0f_wstrb), .s_wlast(gp0f_wlast),
      .s_wvalid(gp0f_wvalid), .s_wready(gp0f_wready),
      .s_bresp(gp0f_bresp), .s_bid(gp0f_bid), .s_bvalid(gp0f_bvalid), .s_bready(gp0f_bready),
      .s_araddr(gp0f_araddr), .s_arlen(gp0f_arlen), .s_arid(gp0f_arid),
      .s_arvalid(gp0f_arvalid), .s_arready(gp0f_arready),
      .s_rdata(gp0f_rdata), .s_rresp(gp0f_rresp), .s_rid(gp0f_rid),
      .s_rlast(gp0f_rlast), .s_rvalid(gp0f_rvalid), .s_rready(gp0f_rready),
      .host_we(host_we), .host_widx(host_widx), .host_wdata(host_wdata),
      .host_ridx(host_ridx), .host_rdata(host_rdata)
  );
  cadr_gp0_default #(.ID_W(16), .LEN_W(8)) u_gp0_rest (
      .clk(clk), .rst(gp0_rst_s),
      .s_awvalid(gp0d_awvalid), .s_awid(gp0d_awid), .s_awready(gp0d_awready),
      .s_wlast(gp0d_wlast), .s_wvalid(gp0d_wvalid), .s_wready(gp0d_wready),
      .s_bresp(gp0d_bresp), .s_bid(gp0d_bid), .s_bvalid(gp0d_bvalid), .s_bready(gp0d_bready),
      .s_arlen(gp0d_arlen), .s_arid(gp0d_arid), .s_arvalid(gp0d_arvalid),
      .s_arready(gp0d_arready), .s_rdata(gp0d_rdata), .s_rresp(gp0d_rresp),
      .s_rid(gp0d_rid), .s_rlast(gp0d_rlast), .s_rvalid(gp0d_rvalid), .s_rready(gp0d_rready)
  );

  // ---------------------------------------- the disk packs, HPM0 and HP2
  //
  // `cadr_disk_pack.sv` against block-disk's block store in the core, its
  // bursts on the 128-bit HP2 through `cadr_axi_burst128.sv`, as
  // `cadr_kr260.sv` has it.
  logic [31:0]  hp2_awaddr, hp2_araddr;
  logic [3:0]   hp2_awlen, hp2_arlen;
  logic [1:0]   hp2_awsize, hp2_arsize, hp2_awburst, hp2_arburst;
  logic         hp2_awvalid, hp2_awready, hp2_wlast, hp2_wvalid, hp2_wready;
  logic         hp2_bvalid, hp2_bready, hp2_arvalid, hp2_arready;
  logic         hp2_rlast, hp2_rvalid, hp2_rready;
  logic [63:0]  hp2_wdata, hp2_rdata;
  logic [7:0]   hp2_wstrb;
  logic [1:0]   hp2_bresp, hp2_rresp;
  logic [31:0]  hp2w_awaddr, hp2w_araddr;
  logic [7:0]   hp2w_awlen, hp2w_arlen;
  logic [2:0]   hp2w_awsize, hp2w_arsize;
  logic [127:0] hp2w_wdata, hp2w_rdata;
  logic [15:0]  hp2w_wstrb;
  logic         pack_rst, pack_irq;
  always_ff @(posedge clk) pack_rst <= !port_rst_sync[2];

  cadr_disk_pack #(
      .REG_BASE(32'hA000_0000), .ID_W(16), .LEN_W(8)
  ) u_pack (
      .clk(clk), .rst(pack_rst), .fabric_rst(rst),
      .port_live(port_rst_sync[2]),
      .s_awaddr(gp0p_awaddr), .s_awlen(gp0p_awlen), .s_awid(gp0p_awid),
      .s_awvalid(gp0p_awvalid), .s_awready(gp0p_awready),
      .s_wdata(gp0p_wdata), .s_wstrb(gp0p_wstrb), .s_wlast(gp0p_wlast),
      .s_wvalid(gp0p_wvalid), .s_wready(gp0p_wready),
      .s_bresp(gp0p_bresp), .s_bid(gp0p_bid), .s_bvalid(gp0p_bvalid), .s_bready(gp0p_bready),
      .s_araddr(gp0p_araddr), .s_arlen(gp0p_arlen), .s_arid(gp0p_arid),
      .s_arvalid(gp0p_arvalid), .s_arready(gp0p_arready),
      .s_rdata(gp0p_rdata), .s_rresp(gp0p_rresp), .s_rid(gp0p_rid),
      .s_rlast(gp0p_rlast), .s_rvalid(gp0p_rvalid), .s_rready(gp0p_rready),
      .m_awaddr(hp2_awaddr), .m_awlen(hp2_awlen), .m_awsize(hp2_awsize),
      .m_awburst(hp2_awburst), .m_awvalid(hp2_awvalid), .m_awready(hp2_awready),
      .m_wdata(hp2_wdata), .m_wstrb(hp2_wstrb), .m_wlast(hp2_wlast),
      .m_wvalid(hp2_wvalid), .m_wready(hp2_wready),
      .m_bresp(hp2_bresp), .m_bvalid(hp2_bvalid), .m_bready(hp2_bready),
      .m_araddr(hp2_araddr), .m_arlen(hp2_arlen), .m_arsize(hp2_arsize),
      .m_arburst(hp2_arburst), .m_arvalid(hp2_arvalid), .m_arready(hp2_arready),
      .m_rdata(hp2_rdata), .m_rresp(hp2_rresp), .m_rlast(hp2_rlast),
      .m_rvalid(hp2_rvalid), .m_rready(hp2_rready),
      .store_we(store_we), .store_slot(store_slot),
      .store_addr(store_addr), .store_wdata(store_wdata),
      .store_rdata(store_rdata), .store_miss(store_miss),
      .ch_active(ch_active), .moving(store_busy), .moving_slot(store_busy_slot),
      .req_valid(req_valid), .req_tag(req_tag), .req_post(req_post),
      .ch_waiting(ch_waiting), .ch_slot(ch_slot), .ch_wrote(ch_wrote),
      .ch_hit(ch_hit), .deny(store_deny), .irq(pack_irq),
      .drive_present(drive_present), .drive_read_only(drive_read_only),
      .drive_timed(drive_timed)
  );

  cadr_axi_burst128 u_burst (
      .clk(clk), .rst(pack_rst),
      .s_awaddr(hp2_awaddr), .s_awlen(hp2_awlen), .s_awsize(hp2_awsize),
      .s_wdata(hp2_wdata), .s_wstrb(hp2_wstrb), .s_wlast(hp2_wlast),
      .s_wvalid(hp2_wvalid), .s_wready(hp2_wready),
      .s_araddr(hp2_araddr), .s_arlen(hp2_arlen), .s_arsize(hp2_arsize),
      .s_rdata(hp2_rdata), .s_rlast(hp2_rlast), .s_rvalid(hp2_rvalid),
      .s_rready(hp2_rready),
      .m_awaddr(hp2w_awaddr), .m_awlen(hp2w_awlen), .m_awsize(hp2w_awsize),
      .m_wdata(hp2w_wdata), .m_wstrb(hp2w_wstrb),
      .m_araddr(hp2w_araddr), .m_arlen(hp2w_arlen), .m_arsize(hp2w_arsize),
      .m_rdata(hp2w_rdata)
  );

  // HPM1: the console face's page at 0xB000_0000; the next page and every
  // other address answered.
  logic [31:0] gp1_wdata, gp1_rdata;
  logic [3:0]  gp1_wstrb;
  cadr_axi_lanes128 u_hpm1_lanes (
      .s_wdata(hpm1_wdata), .s_wstrb(hpm1_wstrb), .s_rdata(hpm1_rdata),
      .m_wdata(gp1_wdata), .m_wstrb(gp1_wstrb), .m_rdata(gp1_rdata)
  );

  logic [31:0] gp1c_awaddr, gp1c_araddr, gp1c_wdata, gp1c_rdata;
  logic [7:0]  gp1c_awlen, gp1c_arlen;
  logic [3:0]  gp1c_wstrb;
  logic [15:0] gp1c_awid, gp1c_arid, gp1c_bid, gp1c_rid;
  logic        gp1c_awvalid, gp1c_awready, gp1c_wlast, gp1c_wvalid, gp1c_wready;
  logic        gp1c_bvalid, gp1c_bready, gp1c_arvalid, gp1c_arready;
  logic        gp1c_rlast, gp1c_rvalid, gp1c_rready;
  logic [1:0]  gp1c_bresp, gp1c_rresp;
  logic [31:0] gp1d_awaddr, gp1d_araddr, gp1d_wdata, gp1d_rdata;
  logic [7:0]  gp1d_awlen, gp1d_arlen;
  logic [3:0]  gp1d_wstrb;
  logic [15:0] gp1d_awid, gp1d_arid, gp1d_bid, gp1d_rid;
  logic        gp1d_awvalid, gp1d_awready, gp1d_wlast, gp1d_wvalid, gp1d_wready;
  logic        gp1d_bvalid, gp1d_bready, gp1d_arvalid, gp1d_arready;
  logic        gp1d_rlast, gp1d_rvalid, gp1d_rready;
  logic [1:0]  gp1d_bresp, gp1d_rresp;
  logic [31:0] gp1x_rdata;
  logic [7:0]  gp1x_arlen;
  logic [15:0] gp1x_awid, gp1x_arid, gp1x_bid, gp1x_rid;
  logic        gp1x_awvalid, gp1x_awready, gp1x_wlast, gp1x_wvalid, gp1x_wready;
  logic        gp1x_bvalid, gp1x_bready, gp1x_arvalid, gp1x_arready;
  logic        gp1x_rlast, gp1x_rvalid, gp1x_rready;
  logic [1:0]  gp1x_bresp, gp1x_rresp;

  cadr_gp1_split #(
      .CON_BASE(32'hB000_0000), .DBG_BASE(32'hB000_1000),
      .ID_W(16), .LEN_W(8)
  ) u_gp1_split (
      .clk(clk), .rst(axi_rst),
      .s_awaddr(hpm1_awaddr[31:0]), .s_awlen(hpm1_awlen), .s_awid(hpm1_awid),
      .s_awvalid(hpm1_awvalid), .s_awready(hpm1_awready),
      .s_wdata(gp1_wdata), .s_wstrb(gp1_wstrb), .s_wlast(hpm1_wlast),
      .s_wvalid(hpm1_wvalid), .s_wready(hpm1_wready),
      .s_bresp(hpm1_bresp), .s_bid(hpm1_bid), .s_bvalid(hpm1_bvalid), .s_bready(hpm1_bready),
      .s_araddr(hpm1_araddr[31:0]), .s_arlen(hpm1_arlen), .s_arid(hpm1_arid),
      .s_arvalid(hpm1_arvalid), .s_arready(hpm1_arready),
      .s_rdata(gp1_rdata), .s_rresp(hpm1_rresp), .s_rid(hpm1_rid),
      .s_rlast(hpm1_rlast), .s_rvalid(hpm1_rvalid), .s_rready(hpm1_rready),
      .con_awaddr(gp1c_awaddr), .con_awlen(gp1c_awlen), .con_awid(gp1c_awid),
      .con_awvalid(gp1c_awvalid), .con_awready(gp1c_awready),
      .con_wdata(gp1c_wdata), .con_wstrb(gp1c_wstrb), .con_wlast(gp1c_wlast),
      .con_wvalid(gp1c_wvalid), .con_wready(gp1c_wready),
      .con_bresp(gp1c_bresp), .con_bid(gp1c_bid), .con_bvalid(gp1c_bvalid),
      .con_bready(gp1c_bready),
      .con_araddr(gp1c_araddr), .con_arlen(gp1c_arlen), .con_arid(gp1c_arid),
      .con_arvalid(gp1c_arvalid), .con_arready(gp1c_arready),
      .con_rdata(gp1c_rdata), .con_rresp(gp1c_rresp), .con_rid(gp1c_rid),
      .con_rlast(gp1c_rlast), .con_rvalid(gp1c_rvalid), .con_rready(gp1c_rready),
      .dbg_awaddr(gp1d_awaddr), .dbg_awlen(gp1d_awlen), .dbg_awid(gp1d_awid),
      .dbg_awvalid(gp1d_awvalid), .dbg_awready(gp1d_awready),
      .dbg_wdata(gp1d_wdata), .dbg_wstrb(gp1d_wstrb), .dbg_wlast(gp1d_wlast),
      .dbg_wvalid(gp1d_wvalid), .dbg_wready(gp1d_wready),
      .dbg_bresp(gp1d_bresp), .dbg_bid(gp1d_bid), .dbg_bvalid(gp1d_bvalid),
      .dbg_bready(gp1d_bready),
      .dbg_araddr(gp1d_araddr), .dbg_arlen(gp1d_arlen), .dbg_arid(gp1d_arid),
      .dbg_arvalid(gp1d_arvalid), .dbg_arready(gp1d_arready),
      .dbg_rdata(gp1d_rdata), .dbg_rresp(gp1d_rresp), .dbg_rid(gp1d_rid),
      .dbg_rlast(gp1d_rlast), .dbg_rvalid(gp1d_rvalid), .dbg_rready(gp1d_rready),
      .dflt_awid(gp1x_awid), .dflt_awvalid(gp1x_awvalid), .dflt_awready(gp1x_awready),
      .dflt_wlast(gp1x_wlast), .dflt_wvalid(gp1x_wvalid), .dflt_wready(gp1x_wready),
      .dflt_bresp(gp1x_bresp), .dflt_bid(gp1x_bid), .dflt_bvalid(gp1x_bvalid),
      .dflt_bready(gp1x_bready),
      .dflt_arlen(gp1x_arlen), .dflt_arid(gp1x_arid),
      .dflt_arvalid(gp1x_arvalid), .dflt_arready(gp1x_arready),
      .dflt_rdata(gp1x_rdata), .dflt_rresp(gp1x_rresp), .dflt_rid(gp1x_rid),
      .dflt_rlast(gp1x_rlast), .dflt_rvalid(gp1x_rvalid), .dflt_rready(gp1x_rready)
  );

  logic [31:0] build;
  cadr_usr_access u_usr_access (.build(build));

  // The display output's settings and answers, words 34, 36 and 42, and
  // the lamp's, word 35.
  logic [1:0]  con_disp_out, con_disp_rotate;
  logic        con_sleep_set, con_wake, con_err_clear, con_steady_lamps;
  logic [14:0] con_sleep_secs, disp_sleep_setting;
  logic        disp_asleep, disp_underrun_s2, disp_rd_error;

  quux15_face #(
      .ID_W(16), .LEN_W(8), .PERIOD(32'(2 * PERIOD_NS)), .MAIN_UNITS(MAIN_WORDS >> 16),
      .VIDEO_W(VIDEO_W), .VIDEO_H(VIDEO_H)
  ) u_face (
      .clk(clk), .rst(axi_rst),
      .s_awaddr(gp1c_awaddr[11:0]), .s_awlen(gp1c_awlen), .s_awid(gp1c_awid),
      .s_awvalid(gp1c_awvalid), .s_awready(gp1c_awready),
      .s_wdata(gp1c_wdata), .s_wstrb(gp1c_wstrb), .s_wlast(gp1c_wlast),
      .s_wvalid(gp1c_wvalid), .s_wready(gp1c_wready),
      .s_bresp(gp1c_bresp), .s_bid(gp1c_bid), .s_bvalid(gp1c_bvalid), .s_bready(gp1c_bready),
      .s_araddr(gp1c_araddr[11:0]), .s_arlen(gp1c_arlen), .s_arid(gp1c_arid),
      .s_arvalid(gp1c_arvalid), .s_arready(gp1c_arready),
      .s_rdata(gp1c_rdata), .s_rresp(gp1c_rresp), .s_rid(gp1c_rid),
      .s_rlast(gp1c_rlast), .s_rvalid(gp1c_rvalid), .s_rready(gp1c_rready),
      .build(build),
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
      .steady_lamps(con_steady_lamps),
      // The latency probe at HP0, page 3.
      .probe_fitted(1'b1), .probe_state(probe_state), .probe_words(probe_words),
      .probe_run(probe_run), .probe_stop(probe_stop)
  );

  cadr_gp0_default #(.ID_W(16), .LEN_W(8)) u_gp1_dbg_rest (
      .clk(clk), .rst(axi_rst),
      .s_awvalid(gp1d_awvalid), .s_awid(gp1d_awid), .s_awready(gp1d_awready),
      .s_wlast(gp1d_wlast), .s_wvalid(gp1d_wvalid), .s_wready(gp1d_wready),
      .s_bresp(gp1d_bresp), .s_bid(gp1d_bid), .s_bvalid(gp1d_bvalid), .s_bready(gp1d_bready),
      .s_arlen(gp1d_arlen), .s_arid(gp1d_arid), .s_arvalid(gp1d_arvalid),
      .s_arready(gp1d_arready), .s_rdata(gp1d_rdata), .s_rresp(gp1d_rresp),
      .s_rid(gp1d_rid), .s_rlast(gp1d_rlast), .s_rvalid(gp1d_rvalid), .s_rready(gp1d_rready)
  );
  cadr_gp0_default #(.ID_W(16), .LEN_W(8)) u_gp1_rest (
      .clk(clk), .rst(axi_rst),
      .s_awvalid(gp1x_awvalid), .s_awid(gp1x_awid), .s_awready(gp1x_awready),
      .s_wlast(gp1x_wlast), .s_wvalid(gp1x_wvalid), .s_wready(gp1x_wready),
      .s_bresp(gp1x_bresp), .s_bid(gp1x_bid), .s_bvalid(gp1x_bvalid), .s_bready(gp1x_bready),
      .s_arlen(gp1x_arlen), .s_arid(gp1x_arid), .s_arvalid(gp1x_arvalid),
      .s_arready(gp1x_arready), .s_rdata(gp1x_rdata), .s_rresp(gp1x_rresp),
      .s_rid(gp1x_rid), .s_rlast(gp1x_rlast), .s_rvalid(gp1x_rvalid), .s_rready(gp1x_rready)
  );

  // ------------------------------------------------- the display output
  //
  // `cadr_kr260.sv`'s, with this machine's picture: the video controller's
  // frame buffer at the display base, `VIDEO_W` by `VIDEO_H` at a bit a
  // pixel, filling the raster; no color board, so the map reads zero; word
  // 210's black-on-white at `bow`.  Its reset is the port's, and the
  // fabric's at `fabric_rst`, as there.  **ITS SECOND IS THE PERIOD'S**,
  // `SECOND_T` above, so the sleep's minutes are minutes at any period.
  logic disp_rst;
  always_ff @(posedge clk) disp_rst <= !port_rst_sync[2];

  logic        pclk, prst;
  cadr_kr260_pixel_clock u_pixel_clock (
      .clk25(clk25), .rst(rst), .pclk(pclk), .prst(prst)
  );

  logic [31:0] dm_araddr;
  logic [3:0]  dm_arlen;
  logic [1:0]  dm_arsize, dm_arburst, dm_rresp;
  logic        dm_arvalid, dm_arready, dm_rvalid, dm_rready, dm_rlast;
  logic [63:0] dm_rdata;
  logic        disp_de, disp_hsync, disp_vsync, disp_mute, disp_sleep_due;
  logic [7:0]  disp_red, disp_green, disp_blue;
  logic        disp_underrun;
  logic [3:0]  disp_map_a;

  cadr_display_out #(
      .BASE(DISPLAY_BASE),
      .COLOR_BASE(cadr_ddr_map::COLOR_DISPLAY_BASE),
      // The board's raster: CEA-861's 1920x1080 at 60 Hz.
      .H_ACTIVE(1920), .H_FRONT(88), .H_SYNC(44), .H_BACK(148),
      .V_ACTIVE(1080), .V_FRONT(4),  .V_SYNC(5),  .V_BACK(36),
      .SPREAD(0),
      .PIC_W(VIDEO_W), .PIC_H(VIDEO_H), .WORDS_PER_LINE(VIDEO_W / 32),
      .SECOND_T(SECOND_T)
  ) u_display (
      .clk(clk), .rst(disp_rst), .fabric_rst(rst),
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

  // The port's read side, as narrow bursts on its 128 bits.
  logic [31:0]  hp3_araddr;
  logic [7:0]   hp3_arlen;
  logic [2:0]   hp3_arsize;
  logic         hp3_arvalid, hp3_arready, hp3_rvalid, hp3_rready, hp3_rlast;
  logic [127:0] hp3_rdata;
  logic [1:0]   hp3_rresp;
  // The write side's answers, which nothing asks for.
  logic         hp3_awready, hp3_wready, hp3_bvalid;
  logic [1:0]   hp3_bresp;
  cadr_axi_rd128 #(.DEPTH(8)) u_disp_rd128 (
      .clk(clk), .rst(disp_rst),
      .s_araddr(dm_araddr), .s_arlen(dm_arlen), .s_arsize(dm_arsize),
      .s_arvalid(dm_arvalid), .s_arready(dm_arready),
      .s_rdata(dm_rdata), .s_rvalid(dm_rvalid), .s_rready(dm_rready),
      .s_rlast(dm_rlast),
      .m_araddr(hp3_araddr), .m_arlen(hp3_arlen), .m_arsize(hp3_arsize),
      .m_arvalid(hp3_arvalid), .m_arready(hp3_arready),
      .m_rdata(hp3_rdata), .m_rvalid(hp3_rvalid), .m_rready(hp3_rready),
      .m_rlast(hp3_rlast)
  );
  assign dm_rresp = hp3_rresp;

  // The live video input: registered on the pixel clock, pixel 1 at eight
  // bits a component in UG1085 table 33-3's places, as `cadr_kr260.sv`'s.
  logic [35:0] live_pixel;
  logic        live_de, live_hsync, live_vsync;
  always_ff @(posedge pclk) begin
    live_pixel <= {disp_red, 4'd0, disp_green, 4'd0, disp_blue, 4'd0};
    live_de    <= disp_de;
    live_hsync <= disp_hsync;
    live_vsync <= disp_vsync;
  end

  // ------------------------------------------- the processing system

  cadr_ps8 u_ps8 (
      .hpm0_aclk(clk),
      .hpm0_awaddr(hpm0_awaddr), .hpm0_awlen(hpm0_awlen), .hpm0_awid(hpm0_awid),
      .hpm0_awvalid(hpm0_awvalid), .hpm0_awready(hpm0_awready),
      .hpm0_wdata(hpm0_wdata), .hpm0_wstrb(hpm0_wstrb), .hpm0_wlast(hpm0_wlast),
      .hpm0_wvalid(hpm0_wvalid), .hpm0_wready(hpm0_wready),
      .hpm0_bresp(hpm0_bresp), .hpm0_bid(hpm0_bid), .hpm0_bvalid(hpm0_bvalid),
      .hpm0_bready(hpm0_bready),
      .hpm0_araddr(hpm0_araddr), .hpm0_arlen(hpm0_arlen), .hpm0_arid(hpm0_arid),
      .hpm0_arvalid(hpm0_arvalid), .hpm0_arready(hpm0_arready),
      .hpm0_rdata(hpm0_rdata), .hpm0_rresp(hpm0_rresp), .hpm0_rid(hpm0_rid),
      .hpm0_rlast(hpm0_rlast), .hpm0_rvalid(hpm0_rvalid), .hpm0_rready(hpm0_rready),
      .hpm1_aclk(clk),
      .hpm1_awaddr(hpm1_awaddr), .hpm1_awlen(hpm1_awlen), .hpm1_awid(hpm1_awid),
      .hpm1_awvalid(hpm1_awvalid), .hpm1_awready(hpm1_awready),
      .hpm1_wdata(hpm1_wdata), .hpm1_wstrb(hpm1_wstrb), .hpm1_wlast(hpm1_wlast),
      .hpm1_wvalid(hpm1_wvalid), .hpm1_wready(hpm1_wready),
      .hpm1_bresp(hpm1_bresp), .hpm1_bid(hpm1_bid), .hpm1_bvalid(hpm1_bvalid),
      .hpm1_bready(hpm1_bready),
      .hpm1_araddr(hpm1_araddr), .hpm1_arlen(hpm1_arlen), .hpm1_arid(hpm1_arid),
      .hpm1_arvalid(hpm1_arvalid), .hpm1_arready(hpm1_arready),
      .hpm1_rdata(hpm1_rdata), .hpm1_rresp(hpm1_rresp), .hpm1_rid(hpm1_rid),
      .hpm1_rlast(hpm1_rlast), .hpm1_rvalid(hpm1_rvalid), .hpm1_rready(hpm1_rready),
      // Main memory: the port's 49 address bits, of which the region needs
      // 31.
      .hp0_rclk(clk), .hp0_wclk(clk),
      .hp0_awaddr({17'd0, hp0_awaddr}), .hp0_awlen(hp0_awlen),
      .hp0_awsize(hp0_awsize), .hp0_awburst(qm_awburst),
      .hp0_awvalid(hp0_awvalid), .hp0_awready(hp0_awready),
      .hp0_wdata(hp0_wdata), .hp0_wstrb(hp0_wstrb),
      .hp0_wlast(hp0_wlast), .hp0_wvalid(hp0_wvalid), .hp0_wready(hp0_wready),
      .hp0_bresp(qm_bresp), .hp0_bvalid(qm_bvalid), .hp0_bready(qm_bready),
      .hp0_araddr({17'd0, hp0_araddr}), .hp0_arlen(hp0_arlen),
      .hp0_arsize(hp0_arsize), .hp0_arburst(qm_arburst),
      .hp0_arvalid(hp0_arvalid), .hp0_arready(hp0_arready),
      .hp0_rdata(hp0_rdata), .hp0_rresp(qm_rresp), .hp0_rlast(hp0_rlast),
      .hp0_rvalid(hp0_rvalid), .hp0_rready(qm_rready),
      // The disk packs' bursts (`cadr_disk_pack.sv`).
      .hp2_rclk(clk), .hp2_wclk(clk),
      .hp2_awaddr({17'd0, hp2w_awaddr}), .hp2_awlen(hp2w_awlen),
      .hp2_awsize(hp2w_awsize), .hp2_awburst(hp2_awburst),
      .hp2_awvalid(hp2_awvalid), .hp2_awready(hp2_awready),
      .hp2_wdata(hp2w_wdata), .hp2_wstrb(hp2w_wstrb), .hp2_wlast(hp2_wlast),
      .hp2_wvalid(hp2_wvalid), .hp2_wready(hp2_wready),
      .hp2_bresp(hp2_bresp), .hp2_bvalid(hp2_bvalid), .hp2_bready(hp2_bready),
      .hp2_araddr({17'd0, hp2w_araddr}), .hp2_arlen(hp2w_arlen),
      .hp2_arsize(hp2w_arsize), .hp2_arburst(hp2_arburst),
      .hp2_arvalid(hp2_arvalid), .hp2_arready(hp2_arready),
      .hp2_rdata(hp2w_rdata), .hp2_rresp(hp2_rresp), .hp2_rlast(hp2_rlast),
      .hp2_rvalid(hp2_rvalid), .hp2_rready(hp2_rready),
      .gpio_i(gpio_i), .gpio_o(gpio_o),
      // The display output's reads: the read side only, the write side
      // tied off, since the display never writes.
      .hp3_rclk(clk), .hp3_wclk(clk),
      .hp3_awaddr(49'd0), .hp3_awlen(8'd0), .hp3_awsize(3'd3), .hp3_awburst(2'b01),
      .hp3_awvalid(1'b0), .hp3_awready(hp3_awready),
      .hp3_wdata(128'd0), .hp3_wstrb(16'd0), .hp3_wlast(1'b0), .hp3_wvalid(1'b0),
      .hp3_wready(hp3_wready), .hp3_bresp(hp3_bresp), .hp3_bvalid(hp3_bvalid),
      .hp3_bready(1'b1),
      .hp3_araddr({17'd0, hp3_araddr}), .hp3_arlen(hp3_arlen),
      .hp3_arsize(hp3_arsize), .hp3_arburst(2'b01),
      .hp3_arvalid(hp3_arvalid), .hp3_arready(hp3_arready),
      .hp3_rdata(hp3_rdata), .hp3_rresp(hp3_rresp), .hp3_rlast(hp3_rlast),
      .hp3_rvalid(hp3_rvalid), .hp3_rready(hp3_rready),
      // The display's raster into the DisplayPort controller.
      .dp_videoinclk(pclk), .dp_livevideoinvsync(live_vsync),
      .dp_livevideoinhsync(live_hsync), .dp_livevideoinde(live_de),
      .dp_livevideoinpixel1(live_pixel),
      .irq0({7'd0, pack_irq})
  );

  // ------------------------------------------------------------ the lamps
  //
  // UF1: the microcycle lamp, a committed microcycle its `retired`: blinking,
  // bit 19 of their count, so it flickers while the machine runs and freezes
  // when it stops; or steady at the console's word 35, lit for `HOLD_T`
  // clocks after each.  UF2: lit while the machine is stopped at an error.
  // Registered on the way to the pad.
  logic cycle_lamp;
  cadr_lamp_microcycle #(.HOLD_T(HOLD_T)) u_lamp_microcycle (
      .clk(clk), .rst(mach_rst), .steady(con_steady_lamps),
      .retired(obs_commit[15]), .lit(cycle_lamp)
  );
  always_ff @(posedge clk) begin
    uf1 <= cycle_lamp;
    uf2 <= obs_errhalt != 2'd0;
  end

  // ---------------------------------------------------------------- the fan
  //
  // Low runs it.  Every KR260 bitstream holds it so.
  assign fan_en_b = 1'b0;

  // PMOD1 is the debug cable's connector, which QUUX has not got: its pads
  // undriven, held low by the pin file's pull-downs.
  for (genvar i = 0; i < 8; i = i + 1) begin : g_pmod1
    assign pmod1[i] = 1'bz;
  end

  // What nothing on this board reads yet.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{obs_cs, obs_rd, obs_ex, obs_wb, obs_commit[14:0], obs_pdlptr, obs_pdlidx,
                    obs_spcptr, obs_q, obs_vma, obs_md, obs_lc, obs_ic, obs_opnd, obs_ea, obs_em,
                    obs_ob, obs_oalow, obs_oahigh, obs_grant, obs_gaddr, obs_mdl, obs_mdword,
                    obs_reg, obs_raddr, obs_queue, obs_inflight, obs_halted, ro_word,
                    fd_doorbell, fd_prod, fd_enabled,
                    chaos_tx_len, chaos_tx_valid, chaos_tx_word, chaos_tx_clear, chaos_reset, chaos_csr,
                    chaos_bits,
                    axi_one_write_id, axi_read_clocks, axi_write_clocks, qm_awid,
                    qm_awlen[7:4], qm_arlen[7:4], qm_awsize[2], qm_arsize[2],
                    hpm0_awaddr[39:32], hpm0_araddr[39:32], hpm1_awaddr[39:32], hpm1_araddr[39:32],
                    gp0c_awaddr, gp0c_araddr, gp0c_awlen, gp0c_wdata, gp0c_wstrb,
                    gp0s_awaddr, gp0s_araddr, gp0s_awlen, gp0s_wdata, gp0s_wstrb,
                    gp0i_awaddr, gp0i_araddr, gp0i_awlen, gp0i_wdata, gp0i_wstrb,
                    drive_read_only[7:0], drive_present[7:1], drive_timed, obs_transfer,
                    gpio_o[94:0], gp1c_awaddr[31:12], gp1c_araddr[31:12],
                    gp1d_awaddr, gp1d_araddr, gp1d_awlen, gp1d_wdata, gp1d_wstrb,
                    hp3_awready, hp3_wready, hp3_bvalid, hp3_bresp,
                    disp_sleep_due, disp_mute, dm_arburst, disp_map_a};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
