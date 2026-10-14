// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15 ON THE ARTY Z7-20** (contract G3 revision 15, §12.3):
// `rtl/machine/quux15_core.sv`, the pipelined machine, on this board's
// processing system, at the period its fit closes.  Revisions 13 and 14 and
// the CADR stay `cadr_arty.sv`'s; this machine has another face to the
// board, so it has its own top level, as `boards/kria-kr260/quux15_kr260.sv`
// has beside `cadr_kr260.sv`, with the same core and the same modules around
// it, and `cadr_arty.sv`'s facts of the board and the part kept as they are:
//
//   - **THE CLOCK IS THE BOARD'S 125 MHz, ON H16, THROUGH AN `MMCME2_BASE`**,
//     125 x 8 = 1000 MHz at the VCO, divided by `CLKOUT0_DIVIDE_F`: the
//     period in nanoseconds, `PERIOD_NS`, which the machine is told in its
//     units of 0.5 ns (`period`, A15b.12) and the console face reports.
//   - **THE PROCESSING SYSTEM IS `cadr_ps7.sv`'s `PS7`**, every port clocked
//     by the machine's clock and each live while its own reset is high.
//   - **THE CACHE IS 4,096 WORDS** (Q-MP6): 256 sets of two eight-word lines,
//     which is what puts the machine in the part's block RAM.
//   - **MAIN MEMORY IS ON `S_AXI_HP0`**, 32M words of packed storage at
//     `cadr_ddr_map.sv`'s revision-13 base (`QUUX13_MAIN_BASE`), where
//     revisions 13 and 14 keep theirs and the board's revision-13 device
//     tree reserves it, the frame buffer at the display base: the machine's
//     own 64-bit master (`quux15_axi_master.sv`, inside the core's port)
//     through `quux15_axi3.sv` onto the port's AXI3 at the same 64 bits.  Its
//     writes carry one AXI ID (A15b.5), the port's tied zero, so the port
//     answers them in order.  The machine is held in reset until the port is
//     live.
//   - **THE CONSOLE FACE IS ON `M_AXI_GP1` AT 0x8000_0000**
//     (`rtl/plumbing/quux15_face.sv`), where `cadr_arty.sv` has the
//     console: the machine's counts, its reset, the diagnostic registers,
//     the readout of the halted machine a checkpoint takes, the build stamp,
//     main memory's size, the video controller's, the period and the
//     real-time clock's start.  The machine comes out of reset running from
//     its PROM, as revisions 13 and 14 do on this board.  The debug cable's
//     page and every other address of the port are answered with a constant
//     (`cadr_gp0_default.sv`), since a read nothing answers hangs both Arm
//     cores.
//   - **THE DISK PACKS ON `M_AXI_GP0` AND `S_AXI_HP2`**, as `cadr_arty.sv`
//     has them: block-disk's block store (the core's `quux15_block_walk.sv`)
//     served by `cadr_disk_pack.sv`, its registers at 0x4000_0000 through
//     `cadr_gp0_split.sv`, its bursts on HP2 at the port's own 64 bits, its
//     interrupt on `IRQ_F2P`<0>, and `cadr-disk-packs --machine quux` the
//     drive.
//   - **THE KEYBOARD AND THE MOUSE ON `M_AXI_GP0`**, the split's input page
//     at 0x4000_3000: `cadr_input_cables.sv`, its mouse's step from the
//     period, its word and the mouse's seven lines to the core's register
//     page (`quux15_input.sv`), whose busy stands in for the card's `KBD
//     READY`.
//   - **THE FILE DEVICE'S PAGE AND THE REAL-TIME CLOCK'S SETTER ON
//     `M_AXI_GP0` AT 0x4000_4000** (`rtl/plumbing/quux_fd_face.sv`, IDENT
//     "QF13" as revisions 13 and 14 have it), onto the core's host side
//     (`quux15_devices.sv`).
//   - **THE DISPLAY OUTPUT ON `S_AXI_HP3` AND THE HDMI CONNECTOR**, as
//     `cadr_arty.sv` has it: `rtl/plumbing/cadr_display_out.sv` reading the
//     video controller's frame buffer at the display base, at VESA's 1280 by
//     1024 at 60 Hz, encoded by `cadr_hdmi_tx.sv` and serialized by
//     `cadr_hdmi_phy.sv`.  The video controller is the board's 1280 by 1024
//     (contract HD), which the core's feature words 11 and 12, the console's
//     word 39 and the display's picture all take; word 210's black-on-white
//     reaches the picture.  The console face's words 33 to 36 drive it and
//     its word 42 reads and clears its two sticky bits.
//   - **NO NETWORK**: QUUX has no Chaosnet cable.  The core's interface
//     (`quux15_chaos.sv`) is built and its cable tied off as a cable with
//     nothing on it, as the Kria KR260's is: a frame sent goes nowhere and
//     is away at once, nothing arrives, and the address switches read 0.
//     The split's network and serial line pages are answered with a
//     constant.  No debug cable either (contract Q5): JA's pads undriven.
//   - **THE BUTTONS, THE SWITCHES AND THE LAMPS KEEP `cadr_arty.sv`'s
//     MEANINGS WHERE REVISION 15 HAS THE SIGNAL**:
//       BTN1  the fabric's reset, which holds the machine with the rest.
//       BTN0  unused: revision 15 has no `-BOOT2`; the console's mode
//             register and the keyboard's boot word boot it.
//       SW0   unused: revision 15 has no no-auto-boot; it comes out of reset
//             running, and the console's word 1 says so.
//       LD0   the machine is running, not halted (`obs_halted` clear):
//             revision 15 has no `MACHRUN`, so the lamp does not dim while
//             the machine waits on memory.
//       LD1   the fabric is clocked: the slow blink, or the MMCM's lock.
//       LD2   microcycles retiring (a committed microcycle): the fast blink,
//             or held for a moment after each.
//       LD3   the disk: lit while block-disk moves a block, stretched.
//       LD4   red at an error halt (`obs_errhalt`).
//       LD5   dark: revision 15 has no PROM select to show.
//   - **EVERY TIME IN CLOCKS IS THE PERIOD'S** (the MP5a review's R9): the
//     mouse's step, the display's second, the lamp's hold and the disk
//     lamp's stretch are durations, each turned into clocks here from
//     `PERIOD_NS`, where the modules' own defaults are counts of the 10 ns
//     tick.

`default_nettype none

module quux15_arty #(
    parameter string PROM_HEX = "build/quux15_transfer_prom.hex",
    // **THE PERIOD**, in nanoseconds: the MMCM's divide below, the one place
    // it is decided on this board.  The fit closes 48 (MP8 step 0).
    parameter int unsigned PERIOD_NS = 48
) (
    input  var logic       sysclk,   // 125 MHz, pin H16
    input  var logic [3:0] btn,
    input  var logic [1:0] sw,
    output var logic [3:0] led,
    output var logic       led4_r, led4_g, led4_b,
    output var logic       led5_r, led5_g, led5_b,
    // JA, the debug cable's connector on the CADR, which QUUX has not got.
    inout  wire  [7:0]     ja,
    output var logic       hdmi_tx_clk_p,
    output var logic       hdmi_tx_clk_n,
    output var logic [2:0] hdmi_tx_d_p,
    output var logic [2:0] hdmi_tx_d_n
);

  localparam logic [31:0] MAIN_BASE    = 32'h1200_0000;
  localparam logic [31:0] DISPLAY_BASE = 32'h1C00_0000;
  if (cadr_ddr_map::QUUX13_MAIN_BASE != MAIN_BASE || cadr_ddr_map::DISPLAY_BASE != DISPLAY_BASE) begin : g_map
    $error("cadr_ddr_map's bases are %h and %h, and the Arty Z7-20's are %h and %h: define no board",
           cadr_ddr_map::QUUX13_MAIN_BASE, cadr_ddr_map::DISPLAY_BASE, MAIN_BASE, DISPLAY_BASE);
  end
  // **MAIN MEMORY: 32M WORDS**, 512 units of 64K, packed storage filling
  // the board's reservation from `MAIN_BASE` to the display (contract G2 §3;
  // `cadr_ddr_map.sv`'s `QUUX13_MAIN_WORDS_MAX`), as revisions 13 and 14
  // have it on this board.  The console's word 37 says it.
  localparam int unsigned MAIN_WORDS = 32'h0200_0000;
  if (MAIN_WORDS != cadr_ddr_map::QUUX13_MAIN_WORDS_MAX) begin : g_main_words
    $error("the Arty Z7-20's main memory is %0d words, and its reservation holds %0d",
           MAIN_WORDS, cadr_ddr_map::QUUX13_MAIN_WORDS_MAX);
  end

  // **THE CACHE: 4,096 WORDS** (Q-MP6), 256 sets.
  localparam int unsigned CACHE_WORDS = 4096;

  // **THE VIDEO CONTROLLER: 1280 BY 1024**, the board's raster (contract
  // HD): 40 words a line, 40,960 words of frame buffer.
  localparam int unsigned VIDEO_W = 1280;
  localparam int unsigned VIDEO_H = 1024;
  if (VIDEO_W / 32 * VIDEO_H > cadr_ddr_map::VIDEO_WORDS_MAX) begin : g_video_words
    $error("the Arty Z7-20's video controller is %0d words, and the display's reservation holds %0d",
           VIDEO_W / 32 * VIDEO_H, cadr_ddr_map::VIDEO_WORDS_MAX);
  end

  // **THE BOARD NAME** (contract HD): feature words 20-24, which the band's
  // herald prints, "Machine Type QUUX on Arty Z7-20"; `cadr_arty.sv`'s for
  // revision 13.
  localparam logic [8*64-1:0] BOARD = "Arty Z7-20";

  // **THE TIMES IN CLOCKS, AT THE PERIOD** (R9): each a duration the module
  // states at the 10 ns tick, here at `PERIOD_NS`.  The display's second,
  // rounded to the nearest clock; the lamp's hold and the disk lamp's
  // stretch, 2^22 ticks of 10 ns, rounded up; the mouse's step below.
  localparam int unsigned SECOND_T = (1_000_000_000 + PERIOD_NS / 2) / PERIOD_NS;
  localparam int unsigned HOLD_T   = (41_943_040 + PERIOD_NS - 1) / PERIOD_NS;
  localparam int unsigned DISK_LIT_T = (41_943_040 + PERIOD_NS - 1) / PERIOD_NS;

  // ------------------------------------------------------------ the clock
  logic clk_fb, clk_raw, clk, mmcm_locked;

  /* verilator lint_off PINCONNECTEMPTY */
  MMCME2_BASE #(
      .CLKIN1_PERIOD  (8.000),            // 125 MHz
      .DIVCLK_DIVIDE  (1),
      .CLKFBOUT_MULT_F(8.000),            // 1000 MHz at the VCO
      .CLKOUT0_DIVIDE_F(real'(PERIOD_NS)) // the period, in nanoseconds
  ) u_mmcm (
      .CLKIN1  (sysclk),
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

  // ------------------------------------------------------------- the resets
  //
  // The fabric's: the MMCM's lock and BTN1, synchronized (`cadr_arty.sv`'s
  // `rst`).  The ports': each of the processing system's own, synchronized,
  // for the faces and masters on that port, as `cadr_arty.sv` takes them.
  // The machine's: the fabric's, `S_AXI_HP0`'s, and the console face's
  // RESET key, so the machine is held while main memory's port is dead.
  logic [3:0] rst_sync;
  logic       rst;
  always_ff @(posedge clk) rst_sync <= {rst_sync[2:0], !mmcm_locked || btn[1]};
  assign rst = rst_sync[3];

  logic hp0_aresetn, hp2_aresetn, hp3_aresetn, gp0_aresetn, gp1_aresetn;
  logic [2:0] port_rst_sync, gp0_rst_sync, pack_rst_sync, gp1_rst_sync, disp_rst_sync;
  logic axi_rst, gp0_rst_s, pack_rst, gp1_rst, disp_rst;
  always_ff @(posedge clk) begin
    port_rst_sync <= {port_rst_sync[1:0], hp0_aresetn};
    gp0_rst_sync  <= {gp0_rst_sync[1:0], gp0_aresetn};
    gp0_rst_s     <= !gp0_rst_sync[2];
    pack_rst_sync <= {pack_rst_sync[1:0], hp2_aresetn && gp0_aresetn};
    pack_rst      <= !pack_rst_sync[2];
    gp1_rst_sync  <= {gp1_rst_sync[1:0], gp1_aresetn};
    gp1_rst       <= !gp1_rst_sync[2];
    disp_rst_sync <= {disp_rst_sync[1:0], hp3_aresetn};
    disp_rst      <= !disp_rst_sync[2];
  end
  assign axi_rst = !port_rst_sync[2];

  logic face_rst, mach_rst;
  always_ff @(posedge clk) mach_rst <= rst || axi_rst || face_rst;

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
      .clk(clk), .rst(mach_rst),
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
  logic [31:0] hp0_awaddr, hp0_araddr;
  logic [3:0]  hp0_awlen, hp0_arlen;
  logic [1:0]  hp0_awsize, hp0_arsize, hp0_awburst, hp0_arburst, hp0_bresp, hp0_rresp;
  logic [63:0] hp0_wdata, hp0_rdata;
  logic [7:0]  hp0_wstrb;
  logic        hp0_awvalid, hp0_awready, hp0_wlast, hp0_wvalid, hp0_wready;
  logic        hp0_bvalid, hp0_bready, hp0_arvalid, hp0_arready;
  logic        hp0_rlast, hp0_rvalid, hp0_rready;

  // The machine's bursts are at most five beats of eight bytes: AXI3's four
  // bits of length and two of size hold them, at the port's own width.
  quux15_axi3 u_axi3 (
      .s_awaddr(qm_awaddr), .s_awlen(qm_awlen), .s_awsize(qm_awsize), .s_awburst(qm_awburst),
      .s_awvalid(qm_awvalid), .s_awready(qm_awready),
      .s_wdata(qm_wdata), .s_wstrb(qm_wstrb), .s_wlast(qm_wlast),
      .s_wvalid(qm_wvalid), .s_wready(qm_wready),
      .s_bresp(qm_bresp), .s_bvalid(qm_bvalid), .s_bready(qm_bready),
      .s_araddr(qm_araddr), .s_arlen(qm_arlen), .s_arsize(qm_arsize), .s_arburst(qm_arburst),
      .s_arvalid(qm_arvalid), .s_arready(qm_arready),
      .s_rdata(qm_rdata), .s_rresp(qm_rresp), .s_rlast(qm_rlast), .s_rvalid(qm_rvalid),
      .s_rready(qm_rready),
      .m_awaddr(hp0_awaddr), .m_awlen(hp0_awlen), .m_awsize(hp0_awsize), .m_awburst(hp0_awburst),
      .m_awvalid(hp0_awvalid), .m_awready(hp0_awready),
      .m_wdata(hp0_wdata), .m_wstrb(hp0_wstrb), .m_wlast(hp0_wlast),
      .m_wvalid(hp0_wvalid), .m_wready(hp0_wready),
      .m_bresp(hp0_bresp), .m_bvalid(hp0_bvalid), .m_bready(hp0_bready),
      .m_araddr(hp0_araddr), .m_arlen(hp0_arlen), .m_arsize(hp0_arsize), .m_arburst(hp0_arburst),
      .m_arvalid(hp0_arvalid), .m_arready(hp0_arready),
      .m_rdata(hp0_rdata), .m_rresp(hp0_rresp), .m_rlast(hp0_rlast), .m_rvalid(hp0_rvalid),
      .m_rready(hp0_rready)
  );

  // ------------------------------------------------ the port's own tally
  //
  // What the machine asked its memory port for and what the processing system
  // answered, `rtl/plumbing/cadr_mem_count.sv`, on EMIO 63:0, as
  // `cadr_arty.sv` has it: the board's programs read its marker bits before
  // they touch a master port (`cadr_mem.c`'s guard).  An ask is a read or a
  // write address taken, counted at its rise, so that addresses taken on
  // consecutive clocks count once; an answer is the processing system's own
  // handshake, B or the last R, and is exact.
  logic [63:0] tally;
  logic        count_req, count_write, count_bvalid, count_bready;
  logic        count_rvalid, count_rready, count_rlast;
  always_ff @(posedge clk) begin
    count_req    <= (hp0_arvalid && hp0_arready) || (hp0_awvalid && hp0_awready);
    count_write  <= hp0_awvalid && hp0_awready;
    count_bvalid <= hp0_bvalid;
    count_bready <= hp0_bready;
    count_rvalid <= hp0_rvalid;
    count_rready <= hp0_rready;
    count_rlast  <= hp0_rlast;
  end
  cadr_mem_count u_count (
      .clk(clk), .rst(rst),
      .req(count_req), .req_write(count_write),
      .bvalid(count_bvalid), .bready(count_bready),
      .rvalid(count_rvalid), .rready(count_rready), .rlast(count_rlast),
      .gpio(tally)
  );

  // ------------------------------------- the master ports: GP0 and GP1
  logic [31:0] gp0_awaddr, gp0_araddr, gp0_wdata, gp0_rdata;
  logic [3:0]  gp0_awlen, gp0_arlen, gp0_wstrb;
  logic [11:0] gp0_awid, gp0_arid, gp0_bid, gp0_rid;
  logic        gp0_awvalid, gp0_awready, gp0_wlast, gp0_wvalid, gp0_wready;
  logic        gp0_bvalid, gp0_bready, gp0_arvalid, gp0_arready;
  logic        gp0_rlast, gp0_rvalid, gp0_rready;
  logic [1:0]  gp0_bresp, gp0_rresp;
  logic [31:0] gp1_awaddr, gp1_araddr, gp1_wdata, gp1_rdata;
  logic [3:0]  gp1_awlen, gp1_arlen, gp1_wstrb;
  logic [11:0] gp1_awid, gp1_arid, gp1_bid, gp1_rid;
  logic        gp1_awvalid, gp1_awready, gp1_wlast, gp1_wvalid, gp1_wready;
  logic        gp1_bvalid, gp1_bready, gp1_arvalid, gp1_arready;
  logic        gp1_rlast, gp1_rvalid, gp1_rready;
  logic [1:0]  gp1_bresp, gp1_rresp;

  // GP0: `cadr_gp0_split.sv`'s pages at 0x4000_0000, as `cadr_arty.sv` has
  // them: the disk packs' registers, the input's page, the file device's
  // page, and the pages of the network and the serial line, answered with a
  // constant; and every other address.  The splitter and the default slaves
  // take the port's reset alone, the faces the fabric's at `fabric_rst`.
  logic [31:0] gp0p_awaddr, gp0p_araddr, gp0p_wdata, gp0p_rdata;
  logic [3:0]  gp0p_awlen, gp0p_arlen, gp0p_wstrb;
  logic [11:0] gp0p_awid, gp0p_arid, gp0p_bid, gp0p_rid;
  logic        gp0p_awvalid, gp0p_awready, gp0p_wlast, gp0p_wvalid, gp0p_wready;
  logic        gp0p_bvalid, gp0p_bready, gp0p_arvalid, gp0p_arready;
  logic        gp0p_rlast, gp0p_rvalid, gp0p_rready;
  logic [1:0]  gp0p_bresp, gp0p_rresp;
  logic [11:0] gp0c_awaddr, gp0c_araddr;
  logic [31:0] gp0c_wdata, gp0c_rdata;
  logic [3:0]  gp0c_awlen, gp0c_arlen, gp0c_wstrb;
  logic [11:0] gp0c_awid, gp0c_arid, gp0c_bid, gp0c_rid;
  logic        gp0c_awvalid, gp0c_awready, gp0c_wlast, gp0c_wvalid, gp0c_wready;
  logic        gp0c_bvalid, gp0c_bready, gp0c_arvalid, gp0c_arready;
  logic        gp0c_rlast, gp0c_rvalid, gp0c_rready;
  logic [1:0]  gp0c_bresp, gp0c_rresp;
  logic [11:0] gp0s_awaddr, gp0s_araddr;
  logic [31:0] gp0s_wdata, gp0s_rdata;
  logic [3:0]  gp0s_awlen, gp0s_arlen, gp0s_wstrb;
  logic [11:0] gp0s_awid, gp0s_arid, gp0s_bid, gp0s_rid;
  logic        gp0s_awvalid, gp0s_awready, gp0s_wlast, gp0s_wvalid, gp0s_wready;
  logic        gp0s_bvalid, gp0s_bready, gp0s_arvalid, gp0s_arready;
  logic        gp0s_rlast, gp0s_rvalid, gp0s_rready;
  logic [1:0]  gp0s_bresp, gp0s_rresp;
  logic [11:0] gp0i_awaddr, gp0i_araddr;
  logic [31:0] gp0i_wdata, gp0i_rdata;
  logic [3:0]  gp0i_awlen, gp0i_arlen, gp0i_wstrb;
  logic [11:0] gp0i_awid, gp0i_arid, gp0i_bid, gp0i_rid;
  logic        gp0i_awvalid, gp0i_awready, gp0i_wlast, gp0i_wvalid, gp0i_wready;
  logic        gp0i_bvalid, gp0i_bready, gp0i_arvalid, gp0i_arready;
  logic        gp0i_rlast, gp0i_rvalid, gp0i_rready;
  logic [1:0]  gp0i_bresp, gp0i_rresp;
  logic [11:0] gp0f_awaddr, gp0f_araddr;
  logic [31:0] gp0f_wdata, gp0f_rdata;
  logic [3:0]  gp0f_awlen, gp0f_arlen, gp0f_wstrb;
  logic [11:0] gp0f_awid, gp0f_arid, gp0f_bid, gp0f_rid;
  logic        gp0f_awvalid, gp0f_awready, gp0f_wlast, gp0f_wvalid, gp0f_wready;
  logic        gp0f_bvalid, gp0f_bready, gp0f_arvalid, gp0f_arready;
  logic        gp0f_rlast, gp0f_rvalid, gp0f_rready;
  logic [1:0]  gp0f_bresp, gp0f_rresp;
  logic [31:0] gp0d_rdata;
  logic [3:0]  gp0d_arlen;
  logic [11:0] gp0d_awid, gp0d_arid, gp0d_bid, gp0d_rid;
  logic        gp0d_awvalid, gp0d_awready, gp0d_wlast, gp0d_wvalid, gp0d_wready;
  logic        gp0d_bvalid, gp0d_bready, gp0d_arvalid, gp0d_arready;
  logic        gp0d_rlast, gp0d_rvalid, gp0d_rready;
  logic [1:0]  gp0d_bresp, gp0d_rresp;

  cadr_gp0_split #(.HAS_FD(1'b1)) u_gp0_split (
      .clk(clk), .rst(gp0_rst_s),
      .s_awaddr(gp0_awaddr), .s_awlen(gp0_awlen), .s_awid(gp0_awid),
      .s_awvalid(gp0_awvalid), .s_awready(gp0_awready),
      .s_wdata(gp0_wdata), .s_wstrb(gp0_wstrb), .s_wlast(gp0_wlast),
      .s_wvalid(gp0_wvalid), .s_wready(gp0_wready),
      .s_bresp(gp0_bresp), .s_bid(gp0_bid), .s_bvalid(gp0_bvalid), .s_bready(gp0_bready),
      .s_araddr(gp0_araddr), .s_arlen(gp0_arlen), .s_arid(gp0_arid),
      .s_arvalid(gp0_arvalid), .s_arready(gp0_arready),
      .s_rdata(gp0_rdata), .s_rresp(gp0_rresp), .s_rid(gp0_rid),
      .s_rlast(gp0_rlast), .s_rvalid(gp0_rvalid), .s_rready(gp0_rready),
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

  // The network's page and the serial line's, which QUUX has not got, and
  // every other address.
  cadr_gp0_default u_gp0_chaos (
      .clk(clk), .rst(gp0_rst_s),
      .s_awvalid(gp0c_awvalid), .s_awid(gp0c_awid), .s_awready(gp0c_awready),
      .s_wlast(gp0c_wlast), .s_wvalid(gp0c_wvalid), .s_wready(gp0c_wready),
      .s_bresp(gp0c_bresp), .s_bid(gp0c_bid), .s_bvalid(gp0c_bvalid), .s_bready(gp0c_bready),
      .s_arlen(gp0c_arlen), .s_arid(gp0c_arid), .s_arvalid(gp0c_arvalid),
      .s_arready(gp0c_arready), .s_rdata(gp0c_rdata), .s_rresp(gp0c_rresp),
      .s_rid(gp0c_rid), .s_rlast(gp0c_rlast), .s_rvalid(gp0c_rvalid), .s_rready(gp0c_rready)
  );
  cadr_gp0_default u_gp0_ser (
      .clk(clk), .rst(gp0_rst_s),
      .s_awvalid(gp0s_awvalid), .s_awid(gp0s_awid), .s_awready(gp0s_awready),
      .s_wlast(gp0s_wlast), .s_wvalid(gp0s_wvalid), .s_wready(gp0s_wready),
      .s_bresp(gp0s_bresp), .s_bid(gp0s_bid), .s_bvalid(gp0s_bvalid), .s_bready(gp0s_bready),
      .s_arlen(gp0s_arlen), .s_arid(gp0s_arid), .s_arvalid(gp0s_arvalid),
      .s_arready(gp0s_arready), .s_rdata(gp0s_rdata), .s_rresp(gp0s_rresp),
      .s_rid(gp0s_rid), .s_rlast(gp0s_rlast), .s_rvalid(gp0s_rvalid), .s_rready(gp0s_rready)
  );
  // **THE KEYBOARD AND THE MOUSE**: the input page, its queue flushed by
  // the machine's reset.  The mouse's step is muir's 16,000 ns at this
  // board's period, rounded up.
  localparam int unsigned MOUSE_STEP_T = (16_000 + PERIOD_NS - 1) / PERIOD_NS;
  cadr_input_cables #(.MOUSE_STEP_T(MOUSE_STEP_T)) u_input (
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
  // revision 13's page, "QF13", as `cadr_arty.sv` gives revisions 13 and
  // 14, onto the core's host side.
  quux_fd_face #(.IDENT(32'h5146_3133)) u_fd_face (
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
  cadr_gp0_default u_gp0_rest (
      .clk(clk), .rst(gp0_rst_s),
      .s_awvalid(gp0d_awvalid), .s_awid(gp0d_awid), .s_awready(gp0d_awready),
      .s_wlast(gp0d_wlast), .s_wvalid(gp0d_wvalid), .s_wready(gp0d_wready),
      .s_bresp(gp0d_bresp), .s_bid(gp0d_bid), .s_bvalid(gp0d_bvalid), .s_bready(gp0d_bready),
      .s_arlen(gp0d_arlen), .s_arid(gp0d_arid), .s_arvalid(gp0d_arvalid),
      .s_arready(gp0d_arready), .s_rdata(gp0d_rdata), .s_rresp(gp0d_rresp),
      .s_rid(gp0d_rid), .s_rlast(gp0d_rlast), .s_rvalid(gp0d_rvalid), .s_rready(gp0d_rready)
  );

  // ----------------------------------------- the disk packs, GP0 and HP2
  //
  // `cadr_disk_pack.sv` against block-disk's block store in the core, its
  // bursts on HP2 at the port's 64 bits, as `cadr_arty.sv` has it.  Its
  // reset is both ports' (`pack_rst`), and the fabric's at `fabric_rst`;
  // `port_live` is the same two ports' liveness.
  logic [31:0] hp2_awaddr, hp2_araddr;
  logic [3:0]  hp2_awlen, hp2_arlen;
  logic [1:0]  hp2_awsize, hp2_arsize, hp2_awburst, hp2_arburst;
  logic        hp2_awvalid, hp2_awready, hp2_wlast, hp2_wvalid, hp2_wready;
  logic        hp2_bvalid, hp2_bready, hp2_arvalid, hp2_arready;
  logic        hp2_rlast, hp2_rvalid, hp2_rready;
  logic [63:0] hp2_wdata, hp2_rdata;
  logic [7:0]  hp2_wstrb;
  logic [1:0]  hp2_bresp, hp2_rresp;
  logic        pack_irq;

  cadr_disk_pack u_pack (
      .clk(clk), .rst(pack_rst), .fabric_rst(rst),
      .port_live(pack_rst_sync[2]),
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

  // GP1: the console face's page at 0x8000_0000; the debug cable's page and
  // every other address answered.
  logic [31:0] gp1c_awaddr, gp1c_araddr, gp1c_wdata, gp1c_rdata;
  logic [3:0]  gp1c_awlen, gp1c_arlen, gp1c_wstrb;
  logic [11:0] gp1c_awid, gp1c_arid, gp1c_bid, gp1c_rid;
  logic        gp1c_awvalid, gp1c_awready, gp1c_wlast, gp1c_wvalid, gp1c_wready;
  logic        gp1c_bvalid, gp1c_bready, gp1c_arvalid, gp1c_arready;
  logic        gp1c_rlast, gp1c_rvalid, gp1c_rready;
  logic [1:0]  gp1c_bresp, gp1c_rresp;
  logic [31:0] gp1d_awaddr, gp1d_araddr, gp1d_wdata, gp1d_rdata;
  logic [3:0]  gp1d_awlen, gp1d_arlen, gp1d_wstrb;
  logic [11:0] gp1d_awid, gp1d_arid, gp1d_bid, gp1d_rid;
  logic        gp1d_awvalid, gp1d_awready, gp1d_wlast, gp1d_wvalid, gp1d_wready;
  logic        gp1d_bvalid, gp1d_bready, gp1d_arvalid, gp1d_arready;
  logic        gp1d_rlast, gp1d_rvalid, gp1d_rready;
  logic [1:0]  gp1d_bresp, gp1d_rresp;
  logic [31:0] gp1x_rdata;
  logic [3:0]  gp1x_arlen;
  logic [11:0] gp1x_awid, gp1x_arid, gp1x_bid, gp1x_rid;
  logic        gp1x_awvalid, gp1x_awready, gp1x_wlast, gp1x_wvalid, gp1x_wready;
  logic        gp1x_bvalid, gp1x_bready, gp1x_arvalid, gp1x_arready;
  logic        gp1x_rlast, gp1x_rvalid, gp1x_rready;
  logic [1:0]  gp1x_bresp, gp1x_rresp;

  cadr_gp1_split u_gp1_split (
      .clk(clk), .rst(gp1_rst),
      .s_awaddr(gp1_awaddr), .s_awlen(gp1_awlen), .s_awid(gp1_awid),
      .s_awvalid(gp1_awvalid), .s_awready(gp1_awready),
      .s_wdata(gp1_wdata), .s_wstrb(gp1_wstrb), .s_wlast(gp1_wlast),
      .s_wvalid(gp1_wvalid), .s_wready(gp1_wready),
      .s_bresp(gp1_bresp), .s_bid(gp1_bid), .s_bvalid(gp1_bvalid), .s_bready(gp1_bready),
      .s_araddr(gp1_araddr), .s_arlen(gp1_arlen), .s_arid(gp1_arid),
      .s_arvalid(gp1_arvalid), .s_arready(gp1_arready),
      .s_rdata(gp1_rdata), .s_rresp(gp1_rresp), .s_rid(gp1_rid),
      .s_rlast(gp1_rlast), .s_rvalid(gp1_rvalid), .s_rready(gp1_rready),
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
  // the lamps', word 35.
  logic [1:0]  con_disp_out, con_disp_rotate;
  logic        con_sleep_set, con_wake, con_err_clear, con_steady_lamps;
  logic [14:0] con_sleep_secs, disp_sleep_setting;
  logic        disp_asleep, disp_underrun_s2, disp_rd_error;

  quux15_face #(
      .ID_W(12), .LEN_W(4), .PERIOD(32'(2 * PERIOD_NS)), .MAIN_UNITS(MAIN_WORDS >> 16),
      .VIDEO_W(VIDEO_W), .VIDEO_H(VIDEO_H)
  ) u_face (
      .clk(clk), .rst(gp1_rst),
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
      .mach_rst(face_rst), .rtc_start(rtc_start),
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

  cadr_gp0_default u_gp1_dbg_rest (
      .clk(clk), .rst(gp1_rst),
      .s_awvalid(gp1d_awvalid), .s_awid(gp1d_awid), .s_awready(gp1d_awready),
      .s_wlast(gp1d_wlast), .s_wvalid(gp1d_wvalid), .s_wready(gp1d_wready),
      .s_bresp(gp1d_bresp), .s_bid(gp1d_bid), .s_bvalid(gp1d_bvalid), .s_bready(gp1d_bready),
      .s_arlen(gp1d_arlen), .s_arid(gp1d_arid), .s_arvalid(gp1d_arvalid),
      .s_arready(gp1d_arready), .s_rdata(gp1d_rdata), .s_rresp(gp1d_rresp),
      .s_rid(gp1d_rid), .s_rlast(gp1d_rlast), .s_rvalid(gp1d_rvalid), .s_rready(gp1d_rready)
  );
  cadr_gp0_default u_gp1_rest (
      .clk(clk), .rst(gp1_rst),
      .s_awvalid(gp1x_awvalid), .s_awid(gp1x_awid), .s_awready(gp1x_awready),
      .s_wlast(gp1x_wlast), .s_wvalid(gp1x_wvalid), .s_wready(gp1x_wready),
      .s_bresp(gp1x_bresp), .s_bid(gp1x_bid), .s_bvalid(gp1x_bvalid), .s_bready(gp1x_bready),
      .s_arlen(gp1x_arlen), .s_arid(gp1x_arid), .s_arvalid(gp1x_arvalid),
      .s_arready(gp1x_arready), .s_rdata(gp1x_rdata), .s_rresp(gp1x_rresp),
      .s_rid(gp1x_rid), .s_rlast(gp1x_rlast), .s_rvalid(gp1x_rvalid), .s_rready(gp1x_rready)
  );

  // ------------------------------------------------- the display output
  //
  // `cadr_arty.sv`'s, with this machine's picture: the video controller's
  // frame buffer at the display base, `VIDEO_W` by `VIDEO_H` at a bit a
  // pixel, filling VESA's 1280 by 1024 raster (the module's own figures); no
  // color board, so the map reads zero; word 210's black-on-white at `bow`.
  // Its reset is HP3's, and the fabric's at `fabric_rst`, as there.  **ITS
  // SECOND IS THE PERIOD'S**, `SECOND_T` above, so the sleep's minutes are
  // minutes at any period.
  logic [31:0] hp3_araddr;
  logic [3:0]  hp3_arlen;
  logic [1:0]  hp3_arsize, hp3_arburst, hp3_rresp, hp3_bresp;
  logic        hp3_arvalid, hp3_arready, hp3_rvalid, hp3_rready, hp3_rlast;
  logic [63:0] hp3_rdata;
  // The write side's answers, which nothing asks for.
  logic        hp3_awready, hp3_wready, hp3_bvalid;

  logic        pclk, prst;
  logic        disp_de, disp_hsync, disp_vsync, disp_mute, disp_sleep_due;
  logic [7:0]  disp_red, disp_green, disp_blue;
  logic        disp_underrun;
  logic [3:0]  disp_map_a;

  cadr_display_out #(
      .BASE(DISPLAY_BASE),
      .COLOR_BASE(cadr_ddr_map::COLOR_DISPLAY_BASE),
      .PIC_W(VIDEO_W), .PIC_H(VIDEO_H), .WORDS_PER_LINE(VIDEO_W / 32),
      .SECOND_T(SECOND_T)
  ) u_display (
      .clk(clk), .rst(disp_rst), .fabric_rst(rst),
      .m_araddr(hp3_araddr), .m_arlen(hp3_arlen), .m_arsize(hp3_arsize),
      .m_arburst(hp3_arburst), .m_arvalid(hp3_arvalid), .m_arready(hp3_arready),
      .m_rdata(hp3_rdata), .m_rresp(hp3_rresp), .m_rlast(hp3_rlast),
      .m_rvalid(hp3_rvalid), .m_rready(hp3_rready),
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

  // DVI out of the raster, and the pixel clock and the serializers, as
  // `cadr_arty.sv` has them: 125 MHz x 8.625 is a VCO of 1078.125 MHz, the
  // serial clock 539.0625 MHz and the pixel clock 107.8125 MHz
  // (`docs/display-output.md`).
  logic [9:0] tmds0, tmds1, tmds2, tmds_clk;
  logic [3:0] hdmi_ser;
  cadr_hdmi_tx u_tx (
      .pclk(pclk), .prst(prst),
      .red(disp_red), .green(disp_green), .blue(disp_blue),
      .de(disp_de), .hsync(disp_hsync), .vsync(disp_vsync),
      .mute(disp_mute),
      .tmds0(tmds0), .tmds1(tmds1), .tmds2(tmds2), .tmds_clk(tmds_clk)
  );
  cadr_hdmi_phy #(
      .CLKIN_PERIOD_NS(8.000),
      .VCO_DIVIDE     (1),
      .VCO_MULT_F     (8.625),
      .SERIAL_DIVIDE_F(2.000),
      .PIXEL_DIVIDE   (10)
  ) u_phy (
      .sysclk(sysclk), .pclk(pclk), .prst(prst),
      .tmds0(tmds0), .tmds1(tmds1), .tmds2(tmds2), .tmds_clk(tmds_clk),
      .ser(hdmi_ser)
  );
  OBUFDS u_hdmi_d0  (.I(hdmi_ser[0]), .O(hdmi_tx_d_p[0]), .OB(hdmi_tx_d_n[0]));
  OBUFDS u_hdmi_d1  (.I(hdmi_ser[1]), .O(hdmi_tx_d_p[1]), .OB(hdmi_tx_d_n[1]));
  OBUFDS u_hdmi_d2  (.I(hdmi_ser[2]), .O(hdmi_tx_d_p[2]), .OB(hdmi_tx_d_n[2]));
  OBUFDS u_hdmi_clk (.I(hdmi_ser[3]), .O(hdmi_tx_clk_p), .OB(hdmi_tx_clk_n));

  // ------------------------------------------- the processing system

  cadr_ps7 u_ps7 (
      // Main memory, the machine's.
      .hp0_aclk(clk), .hp0_aresetn(hp0_aresetn),
      .hp0_awaddr(hp0_awaddr), .hp0_awlen(hp0_awlen),
      .hp0_awsize(hp0_awsize), .hp0_awburst(hp0_awburst),
      .hp0_awvalid(hp0_awvalid), .hp0_awready(hp0_awready),
      .hp0_wdata(hp0_wdata), .hp0_wstrb(hp0_wstrb),
      .hp0_wlast(hp0_wlast), .hp0_wvalid(hp0_wvalid), .hp0_wready(hp0_wready),
      .hp0_bresp(hp0_bresp), .hp0_bvalid(hp0_bvalid), .hp0_bready(hp0_bready),
      .hp0_araddr(hp0_araddr), .hp0_arlen(hp0_arlen),
      .hp0_arsize(hp0_arsize), .hp0_arburst(hp0_arburst),
      .hp0_arvalid(hp0_arvalid), .hp0_arready(hp0_arready),
      .hp0_rdata(hp0_rdata), .hp0_rresp(hp0_rresp), .hp0_rlast(hp0_rlast),
      .hp0_rvalid(hp0_rvalid), .hp0_rready(hp0_rready),
      .gpio_i(tally),
      // The disk packs' bursts (`cadr_disk_pack.sv`).
      .hp2_aclk(clk), .hp2_aresetn(hp2_aresetn),
      .hp2_awaddr(hp2_awaddr), .hp2_awlen(hp2_awlen),
      .hp2_awsize(hp2_awsize), .hp2_awburst(hp2_awburst),
      .hp2_awvalid(hp2_awvalid), .hp2_awready(hp2_awready),
      .hp2_wdata(hp2_wdata), .hp2_wstrb(hp2_wstrb), .hp2_wlast(hp2_wlast),
      .hp2_wvalid(hp2_wvalid), .hp2_wready(hp2_wready),
      .hp2_bresp(hp2_bresp), .hp2_bvalid(hp2_bvalid), .hp2_bready(hp2_bready),
      .hp2_araddr(hp2_araddr), .hp2_arlen(hp2_arlen),
      .hp2_arsize(hp2_arsize), .hp2_arburst(hp2_arburst),
      .hp2_arvalid(hp2_arvalid), .hp2_arready(hp2_arready),
      .hp2_rdata(hp2_rdata), .hp2_rresp(hp2_rresp), .hp2_rlast(hp2_rlast),
      .hp2_rvalid(hp2_rvalid), .hp2_rready(hp2_rready),
      // The display output's reads: the read side only, the write side
      // tied off, since the display never writes.
      .hp3_aclk(clk), .hp3_aresetn(hp3_aresetn),
      .hp3_awaddr(32'd0), .hp3_awlen(4'd0), .hp3_awsize(2'b11), .hp3_awburst(2'b01),
      .hp3_awvalid(1'b0), .hp3_awready(hp3_awready),
      .hp3_wdata(64'd0), .hp3_wstrb(8'd0), .hp3_wlast(1'b0), .hp3_wvalid(1'b0),
      .hp3_wready(hp3_wready), .hp3_bresp(hp3_bresp), .hp3_bvalid(hp3_bvalid),
      .hp3_bready(1'b1),
      .hp3_araddr(hp3_araddr), .hp3_arlen(hp3_arlen),
      .hp3_arsize(hp3_arsize), .hp3_arburst(hp3_arburst),
      .hp3_arvalid(hp3_arvalid), .hp3_arready(hp3_arready),
      .hp3_rdata(hp3_rdata), .hp3_rresp(hp3_rresp), .hp3_rlast(hp3_rlast),
      .hp3_rvalid(hp3_rvalid), .hp3_rready(hp3_rready),
      .gp1_aclk(clk), .gp1_aresetn(gp1_aresetn),
      .gp1_awaddr(gp1_awaddr), .gp1_awlen(gp1_awlen), .gp1_awid(gp1_awid),
      .gp1_awvalid(gp1_awvalid), .gp1_awready(gp1_awready),
      .gp1_wdata(gp1_wdata), .gp1_wstrb(gp1_wstrb), .gp1_wlast(gp1_wlast),
      .gp1_wvalid(gp1_wvalid), .gp1_wready(gp1_wready),
      .gp1_bresp(gp1_bresp), .gp1_bid(gp1_bid), .gp1_bvalid(gp1_bvalid),
      .gp1_bready(gp1_bready),
      .gp1_araddr(gp1_araddr), .gp1_arlen(gp1_arlen), .gp1_arid(gp1_arid),
      .gp1_arvalid(gp1_arvalid), .gp1_arready(gp1_arready),
      .gp1_rdata(gp1_rdata), .gp1_rresp(gp1_rresp), .gp1_rid(gp1_rid),
      .gp1_rlast(gp1_rlast), .gp1_rvalid(gp1_rvalid), .gp1_rready(gp1_rready),
      .gp0_aclk(clk), .gp0_aresetn(gp0_aresetn),
      .gp0_awaddr(gp0_awaddr), .gp0_awlen(gp0_awlen), .gp0_awid(gp0_awid),
      .gp0_awvalid(gp0_awvalid), .gp0_awready(gp0_awready),
      .gp0_wdata(gp0_wdata), .gp0_wstrb(gp0_wstrb), .gp0_wlast(gp0_wlast),
      .gp0_wvalid(gp0_wvalid), .gp0_wready(gp0_wready),
      .gp0_bresp(gp0_bresp), .gp0_bid(gp0_bid), .gp0_bvalid(gp0_bvalid),
      .gp0_bready(gp0_bready),
      .gp0_araddr(gp0_araddr), .gp0_arlen(gp0_arlen), .gp0_arid(gp0_arid),
      .gp0_arvalid(gp0_arvalid), .gp0_arready(gp0_arready),
      .gp0_rdata(gp0_rdata), .gp0_rresp(gp0_rresp), .gp0_rid(gp0_rid),
      .gp0_rlast(gp0_rlast), .gp0_rvalid(gp0_rvalid), .gp0_rready(gp0_rready),
      // The disk's interrupt on bit 0, the other nineteen lines low.
      .irqf2p({19'b0, pack_irq})
  );

  // ------------------------------------------------------------ the lamps
  //
  // `cadr_arty.sv`'s six, where revision 15 has the signal (the header
  // above).  The clock lamp counts the machine's clock and is not reset, so
  // it blinks whenever the fabric is clocked at all; the others are
  // registered on the way to the pad.
  logic [25:0] tick;
  always_ff @(posedge clk) tick <= tick + 26'd1;

  logic clock_lamp, cycle_lamp;
  cadr_lamp_clock u_lamp_clock (
      .steady(con_steady_lamps), .locked(mmcm_locked), .blink(tick[25]),
      .lit(clock_lamp)
  );
  cadr_lamp_microcycle #(.HOLD_T(HOLD_T)) u_lamp_microcycle (
      .clk(clk), .rst(mach_rst), .steady(con_steady_lamps),
      .retired(obs_commit[15]), .lit(cycle_lamp)
  );

  // The disk lamp: lit for `DISK_LIT_T` clocks, about 42 ms, re-armed by
  // every block, so that a block's few microseconds can be seen.
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

  assign led[0] = run_lamp;      // the machine is running, not halted
  assign led[1] = clock_lamp;    // the fabric is clocked --- the slow blink, or the lock
  assign led[2] = cycle_lamp;    // microcycles retiring --- the fast blink, or a hold
  assign led[3] = disk_lit;      // block-disk is moving a block
  assign {led4_r, led4_g, led4_b} = {errhalt_lamp, 1'b0, 1'b0};
  assign {led5_r, led5_g, led5_b} = 3'b000;

  // JA is the debug cable's connector, which QUUX has not got: its pads
  // undriven, held low by the pin file's pull-downs.
  for (genvar i = 0; i < 8; i = i + 1) begin : g_ja
    assign ja[i] = 1'bz;
  end

  // What nothing on this board reads.
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
                    gp0c_awaddr, gp0c_araddr, gp0c_awlen, gp0c_wdata, gp0c_wstrb,
                    gp0s_awaddr, gp0s_araddr, gp0s_awlen, gp0s_wdata, gp0s_wstrb,
                    drive_read_only[7:0], drive_present[7:1], drive_timed, obs_transfer,
                    gp1c_awaddr[31:12], gp1c_araddr[31:12],
                    gp1d_awaddr, gp1d_araddr, gp1d_awlen, gp1d_wdata, gp1d_wstrb,
                    hp3_awready, hp3_wready, hp3_bvalid, hp3_bresp,
                    disp_sleep_due, disp_map_a, btn[0], btn[3:2], sw};
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
