// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's register page: the last page of the physical space, physical
// `17777400`-`17777777` (page 37777), fixed there (revision 11, contract
// Q13), in which the machine lists its sizes and which carries its
// registers (contract Q2: "the QUUX register page is the feature page").
// Words 0-77 are the feature page proper and read only; the registers are
// below.
//
// muir's `Geometry::feature_word` and `Machine::bus_read`, ported.  A read is
// answered as a device register answers, `Responder::Device` in muir's `rtl`
// engine, and a write to a word that takes none is acknowledged and goes
// nowhere.  The words, at muir's pin:
//
//     0    the MACHINE-ID, as functional source 16 gives it
//     1    the level-1 map entry's bits, 6; 7 on revision 13
//     2    the level-2 map's entries, 32 << 6 = 2,048; 4,096 on revision 13
//     3    the PDL buffer's words, 1 << 14 = 16,384
//     4    the control store's words, 16,384
//     5    A memory's words, 1,024
//     6    the dispatch memory's words, 2,048; 4,096 on revision 13
//     7    the multiply and divide, 3: bit 0 MUL, bit 1 DIV
//     10   the processor tick, timer 0, 1
//     11   the main screen's width in 31:16 and height in 15:0
//     12   the main screen's bits a pixel in 31:16 and words a line in 15:0
//     13   the main screen's buffer, its first physical address, `17000000`;
//          on revision 13 the frame buffer window's, `1760000000`
//     14   the microsecond clock, 1
//     15   the optional devices, a bit each: 3, <0> the real-time clock and
//          <1> the file device, a later optional device taking the next bit
//     16   the number of interval timers, 3 (revision 10, contract Q11)
//     17   the MACRO DISPATCH MEMORY's entries, 1,024 (revision 12,
//          contract H8a; `cadr_microcycle.sv`)
//     20-24  on revision 13 the board name (contract HD §6.4): up to 20
//          printable ASCII characters, 4 to a word in <31:0>, the first in
//          <7:0>, zero bytes after the last; each board's top level gives
//          it.  0 below revision 13 and where no name is given
//     25-77  0
//
// And the registers (`Machine::bus_read` and `bus_write`):
//
//     100  interrupt status, read only, in contract Q13's order: <0> timer
//          0, <1> timer 1, <2> timer 2, <3> block-disk's done, <4> the
//          keyboard, <5> the mouse, <6> the network, <7> the file device,
//          each under its own enable
//     101  the error status: <0> NXM, the only bit QUUX sets; <3> and <5>,
//          the CADR's Unibus bits, read 0; a write of any value clears it
//     102  mode: <0> error stop, which the mode register's <2> is too
//     103  the real-time clock, read only: Unix seconds (`quux_rtc.sv`,
//          contract Q9); a write goes nowhere
//     104  <0> `RESET-DEVICES`, write only: a write with <0> set resets every
//          device --- block-disk, the network, the file device and the
//          interval timers, not the keyboard and mouse --- and reads 0
//          (revision 10, contract Q11; `reset_devices` below)
//     110-115  the interval timers, `quux_clocks.sv` (contract Q11): timer
//          k's control and status at 110 + 2k, its period at 111 + 2k
//     120-123  the keyboard and the mouse, `quux_input.sv` (contract Q3)
//     140-145  the Chaosnet interface's five registers, sixteen bits in the
//          bottom of the word (contract Q4; contract Q13): 140 the
//          CSR, read and written; 141 my address when read, the write
//          buffer when written; 142 the read buffer, read only, a read
//          advancing it; 143 the bit count, read only; 145 START, read
//          only, a read starting a transmission.  144, 146 and 147 are
//          reserved, and writes of 142, 143 and 145 go nowhere
//     160-171  the file device's registers, `quux_file_device.sv` (contract
//          Q9)
//     200-203  block-disk's four registers: its own slave,
//          `quux_block_disk.sv`, answers them, and this page does not
//     210  the video controller's mode: its own slave, `quux_video.sv`,
//          answers it, and this page does not
//     the rest reserved: read 0, writes ignored
//
// **A REGISTER IS READ AND WRITTEN AT THE INSTANT THE PAGE ANSWERS**, the
// first tick of the cycle's `-XBUS.RQ` with the page matched, which is muir's
// `answered_at`: a read's word is taken there and held for the strobe, and a
// read that moves something --- the keyboard's FIFO, the mouse's changed bit,
// the Chaosnet's receive pointer --- moves it there, once.  The interrupt
// status is the flags as they stand at that tick, but the timers' bits,
// which are as they stood at the edge that took the cycle
// (`quux_clocks.sv`'s `pending`), as their words are.  The page's own three
// requests, the keyboard's, the mouse's and the network's, also reach the
// processor's interrupt as every word 100 bit does (`irq`; muir's
// `interrupt_at`, `0c10ae9` for the network's); the timers' reach it from
// `quux_clocks.sv`, and block-disk's on the interrupt line it shares with
// the CADR's controller (`cadr_machine.sv`'s `xbus_intr`).
//
// **`RESET-DEVICES` IS REGISTERED ONCE**: `reset_devices` is up in the tick
// after the page takes the write, and the devices clear at the end of it,
// two ticks after the edge that took the cycle.  muir resets them at that
// edge, after its `SINTR`; the next `SINTR` is taken at the acknowledging
// edge, K ticks after it, so at K >= 4 they are cleared a tick before it
// and nothing is held off `SINTR` for them (contract Q11, section 4).
//
// Words 11 to 13 are the display's: the video controller at the board's
// size, `cadr_machine.sv`'s `VIDEO_WIDTH` by `VIDEO_HEIGHT`, a line its width
// in 32-bit words.  The values are parameters that `cadr_machine.sv` sets
// from the one place each is decided, so this page and the thing it
// describes cannot disagree by an edit to one of them.
//
// **ONLY QUUX HAS IT.**  `cadr_machine.sv` builds this module under
// `MACHINE == "quux"` and nowhere else, and on the CADR the page is the
// Unibus window's last page, where nothing answers and an access times out
// with the Unibus NXM bit, which `build/quux_map.pass` holds against muir's
// CADR.
//
// **THE MATCH IS HELD ONE TICK, AS THE DISK CONTROLLER'S IS, AND FOR ITS
// REASON.**  `phys` is the far end of the map, and `dev_ack` must stay a gate
// on a held match: `cadr_disk_controller.sv` has the measurement at `mine_c`.
// `-XBUS.RQ` goes out sixteen ticks after the grant, so a match a tick behind
// the address is settled long before anything reads it.
//
// **EXACTLY ONE SLAVE ANSWERS EACH WORD** (contract Q13): the page's match
// leaves out words 200-203 and 210, which block-disk and the video
// controller answer on the same seam, each matching its own words.  The
// page's own match is not what bounds it: it sees a cycle only when the
// held decode has already called it a device's, and the only other device
// cycles, the video controller's buffer, are far below it.  What bounds the
// page is `cadr_xbus_decode.sv`, which `build/xbus_decode.quux13.pass` holds
// over every address.
//
// What holds it: `build/quux13_registers.quux.k4.pass`, whose program reads
// all 256 words at power-on, writes all ones to every read-only and reserved
// word and reads them all again, 101 after each, against muir's own table
// (`tests/quux_registers.rs`), and finds nothing at the old page, the old
// device registers and the old Unibus window; `build/quux13_features.quux.k4.pass`,
// whose program reads words 0 to 14, 100, 220 and 377 through the map;
// `build/quux13_page.quux.k4.pass`, whose program reads and writes every
// register word with key words pressed on the cable, the flags risen, a bus
// error made and the Chaosnet interface written and read through the page;
// each comparing `MD`, `SINTR` and every microcycle's length on every row
// against muir's QUUX; and the records aimed here in `mutations/list.txt`.

`default_nettype none

module quux_feature_page #(
    // Word 0, the MACHINE-ID: `cadr_machine.sv` gives it, from the one
    // place it is decided; no default, so no instance can carry a stale one.
    parameter logic [31:0] MACHINE_ID,
    parameter int unsigned L1_BITS        = 6,
    parameter int unsigned PDL_BITS       = 14,
    parameter int unsigned IMEM_WORDS     = 16384,
    parameter int unsigned AMEM_WORDS     = 1024,
    parameter int unsigned DMEM_WORDS     = 2048,
    parameter logic [31:0] MULDIV         = 32'd3,
    parameter logic [31:0] TICK           = 32'd1,
    parameter logic [31:0] CLOCKS         = 32'd1,
    // A tick's real length in picoseconds, for the real-time clock
    // (`cadr_machine.sv`).
    parameter int unsigned TICK_PS        = cadr_tick_pkg::TICK_NS * 1000,
    // Word 15: the optional devices, a bit each, <0> the real-time clock and
    // <1> the file device.
    parameter logic [31:0] OPTIONAL_DEVICES = 32'd3,
    // Word 16: the number of interval timers (revision 10).
    parameter logic [31:0] TIMERS         = 32'd3,
    // Word 17: the MACRO DISPATCH MEMORY's entries (revision 12).
    parameter logic [31:0] MACRO_ENTRIES  = 32'd1024,
    parameter int unsigned SCREEN_WIDTH   = 1280,
    parameter int unsigned SCREEN_HEIGHT  = 1024,
    parameter int unsigned SCREEN_WPL     = 40,
    parameter logic [31:0] SCREEN_BUFFER  = 32'o17000000,
    // Words 20-24, revision 13's board name (contract HD §6.4), as
    // `cadr_machine.sv` lays it out: word 20 + k in `<32k+31:32k>`.  Read 0
    // below revision 13.
    parameter logic [159:0] BOARD_NAME_WORDS = '0,
    // 32, QUUX to revision 12; 40, revision 13, whose file device takes
    // 28-bit addresses and main memory's size in 28 bits
    // (`quux_file_device.sv`).  The words above that change with it are
    // `cadr_machine.sv`'s to give.
    parameter int unsigned WORD_BITS      = 32,
    // Revision 14's TLB entries (A14.9: word 2 says them, word 1 is 0, and
    // words 220-227 are the memory system's, `quux_mmu.sv`'s); 0 below
    // revision 14, where word 2 is the level-2 map's entries.
    parameter int unsigned TLB_ENTRIES    = 0,
    localparam int unsigned MEM_BITS      = WORD_BITS > 32 ? 28 : 23
) (
    input  var logic        clk,
    input  var logic        rst,
    // `-XBUS INIT`: the power-on reset and `RESET-DEVICES` (`reset_devices`
    // below, through `cadr_machine.sv`'s `bus_init`), which disables the
    // file device.
    input  var logic        xbus_init,

    // The held decode's `device`, the cycle's address, its direction,
    // `-XBUS.RQ` and the word written.
    input  var logic        sel,
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [21:0] phys,
    /* verilator lint_on UNUSEDSIGNAL */
    input  var logic        dev_write,
    input  var logic        dev_rq,
    input  var logic [31:0] wdata,

    // The acknowledgment and the word, which this page drives only while
    // answering a READ: `cadr_machine.sv` joins both beside block-disk's.
    output var logic        dev_ack,
    output var logic        drives,
    output var logic [31:0] rdata,

    // --- word 100's sources that are not this page's own
    input  var logic [2:0]  timer_pending,   // <0>, <1> and <2>: timers 0, 1 and 2
    input  var logic        disk_irq,        // <3> block-disk's done
    input  var logic        chaos_ireq,      // <6> the network
    // --- words 110-115: the interval timers (`quux_clocks.sv`), a write in
    // the tick the page takes it and a read of the word the page names
    output var logic        tm_we,
    output var logic [2:0]  tm_idx,
    output var logic [23:0] tm_wdata,
    input  var logic [23:0] tm_rdata,
    // --- word 104: `RESET-DEVICES`, the tick after the page takes a write of
    // it with <0> set
    output var logic        reset_devices,
    // --- word 101: the bus errors, and their clear
    input  var logic [2:0]  err,             // 101's <5>, <3> and <0>: {map, Unibus NXM, NXM}
    output var logic        err_clear,
    // --- word 102: error stop, and its write
    input  var logic        errstop,
    output var logic        errstop_we,
    output var logic        errstop_d,
    // --- words 140-145: the Chaosnet interface (`cadr_io_board.sv`'s `qp_`)
    output var logic        ch_land,
    output var logic        ch_wr,
    output var logic [2:0]  ch_which,
    output var logic [15:0] ch_wdata,
    input  var logic [15:0] ch_rdata,
    // --- words 120-123: the keyboard's cable and the mouse's counts
    input  var logic        kbd_strobe,
    input  var logic [23:0] kbd_code,
    input  var logic [11:0] mouse_x,
    input  var logic [11:0] mouse_y,
    input  var logic [2:0]  mouse_buttons,

    // The page's own requests into the processor's interrupt: the keyboard,
    // the mouse and the network.
    output var logic        irq,
    // The keyboard's boot word, and the host's handshake (`quux_input.sv`).
    output var logic        n_boot_kbd,
    output var logic        kbd_busy,

    // The keyboard's and the mouse's registers for the readout, a checkpoint's
    // `QuuxInput` (`quux_input.sv`'s `ro_*`).
    output var logic [13:0] ro_in_state,
    output var logic [6:0]  ro_in_count,
    input  var logic [5:0]  ro_fifo_a,
    output var logic [23:0] ro_fifo_q,

    // --- revision 9: main memory's words and the write buffer empty, for
    // the file device; the whole cache dropped at the next grant
    input  var logic [MEM_BITS-1:0] mem_words,
    input  var logic        drained,
    output var logic        fd_invalidate,
    // The host's side of the real-time clock (indexes 0 and 1) and of the
    // file device (2-12): one write and one read a tick, the word read a tick
    // after its index (`quux_file_device.sv`).
    input  var logic        host_we,
    input  var logic [3:0]  host_widx,
    input  var logic [31:0] host_wdata,
    input  var logic [3:0]  host_ridx,
    output var logic [31:0] host_rdata,
    // The file device for the readout (`quux_file_device.sv`'s `ro_*`).
    output var logic [47:0] ro_fd_bases,
    output var logic [47:0] ro_fd_resp_base,
    output var logic [47:0] ro_fd_indexes,
    output var logic [47:0] ro_fd_flags,
    // --- revision 14's words 220-227: a write in the tick the page takes
    // it, and the word the page names read back (`quux_mmu.sv`)
    output var logic        ms_we,
    output var logic [2:0]  ms_idx,
    output var logic [31:0] ms_wdata,
    input  var logic [31:0] ms_rdata
);
  localparam bit PAGED = TLB_ENTRIES != 0;

  localparam logic [13:0] FEATURE_PAGE = 14'o37777;

  logic       mine, taken;
  logic [7:0] which;

  // **THE INSTANT THE PAGE ANSWERS**: the first tick of `-XBUS.RQ` with the
  // page matched, once a cycle.
  logic take;
  assign take = mine && dev_rq && !taken;

  // Words 140-147 as muir's `network_register` takes them (contract Q13): a
  // read of 140, 141, 142, 143 and 145, and a write of 140 and 141.
  // 144, 146 and 147 are reserved, and a write of 142, 143 or 145 goes
  // nowhere, where the CADR's board takes a write of `764152`, 145, as its
  // write buffer's and answers `764150` and `764156` as aliases.
  // `build/quux13_registers.quux.k4.pass` holds each: all ones written to
  // every one of them and every word read again after.
  logic in_chaos, chaos_answers;
  assign in_chaos = which[7:3] == 5'o14;
  assign chaos_answers = in_chaos && (dev_write ? (which[2:1] == 2'b00)
                                                : (which[2:0] <= 3'd3 || which[2:0] == 3'd5));

  logic [31:0] in_rdata;
  logic [1:0]  in_irq;
  logic        in_mine;

  quux_input input_regs (
      .clk          (clk),
      .rst          (rst),
      .kbd_strobe   (kbd_strobe),
      .kbd_code     (kbd_code),
      .mouse_x      (mouse_x),
      .mouse_y      (mouse_y),
      .mouse_buttons(mouse_buttons),
      .rd           (take && !dev_write),
      .wr           (take && dev_write),
      .which        (which),
      .wdata        (wdata),
      .rdata        (in_rdata),
      .mine         (in_mine),
      .irq          (in_irq),
      .n_boot       (n_boot_kbd),
      .busy         (kbd_busy),
      .ro_state     (ro_in_state),
      .ro_count     (ro_in_count),
      .ro_fifo_a    (ro_fifo_a),
      .ro_fifo_q    (ro_fifo_q)
  );

  // The real-time clock, and the file device (revision 9).
  logic [31:0] rtc_seconds, fd_rdata, fd_host_rdata;
  logic [29:0] rtc_fraction;
  logic        fd_mine, fd_irq;

  quux_rtc #(.TICK_PS(TICK_PS)) rtc (
      .clk        (clk),
      .we_seconds (host_we && host_widx == 4'd0),
      .we_fraction(host_we && host_widx == 4'd1),
      .wdata      (host_wdata),
      .seconds    (rtc_seconds),
      .fraction   (rtc_fraction)
  );

  quux_file_device #(.WORD_BITS(WORD_BITS)) file_device (
      .clk        (clk),
      .rst        (rst),
      .xbus_init  (xbus_init),
      .wr         (take && dev_write),
      .which      (which),
      .wdata      (wdata),
      .mine       (fd_mine),
      .rdata      (fd_rdata),
      .irq        (fd_irq),
      .mem_words  (mem_words),
      .drained    (drained),
      .invalidate (fd_invalidate),
      .host_we    (host_we),
      .host_widx  (host_widx),
      .host_wdata (host_wdata),
      .host_ridx  (host_ridx),
      .host_rdata (fd_host_rdata),
      .ro_bases   (ro_fd_bases),
      .ro_resp_base(ro_fd_resp_base),
      .ro_indexes (ro_fd_indexes),
      .ro_flags   (ro_fd_flags)
  );

  // The host's read: the clock's two words taken a tick after their index,
  // as the file device's are.
  logic [31:0] rtc_host_q;
  logic        rtc_host_sel;
  always_ff @(posedge clk) begin
    rtc_host_q   <= host_ridx[0] ? {2'd0, rtc_fraction} : rtc_seconds;
    rtc_host_sel <= host_ridx[3:1] == 3'd0;
  end
  assign host_rdata = rtc_host_sel ? rtc_host_q : fd_host_rdata;

  logic [31:0] word;
  always_comb begin
    word = 32'd0;
    if (in_mine) begin
      word = in_rdata;
    end else if (fd_mine) begin
      word = fd_rdata;
    end else if (in_chaos) begin
      word = chaos_answers ? {16'd0, ch_rdata} : 32'd0;
    end else begin
      unique case (which)
        8'o0:    word = MACHINE_ID;
        8'o1:    word = 32'(L1_BITS);
        8'o2:    word = PAGED ? 32'(TLB_ENTRIES) : 32'(32 << L1_BITS);
        8'o3:    word = 32'(1 << PDL_BITS);
        8'o4:    word = 32'(IMEM_WORDS);
        8'o5:    word = 32'(AMEM_WORDS);
        8'o6:    word = 32'(DMEM_WORDS);
        8'o7:    word = MULDIV;
        8'o10:   word = TICK;
        8'o11:   word = {16'(SCREEN_WIDTH), 16'(SCREEN_HEIGHT)};
        8'o12:   word = {16'd1, 16'(SCREEN_WPL)};
        8'o13:   word = SCREEN_BUFFER;
        8'o14:   word = CLOCKS;
        8'o15:   word = OPTIONAL_DEVICES;
        8'o16:   word = TIMERS;
        8'o17:   word = MACRO_ENTRIES;
        // The board name, revision 13's (contract HD §6.4).
        8'o20, 8'o21, 8'o22, 8'o23, 8'o24:
                 word = WORD_BITS > 32 ? BOARD_NAME_WORDS[32 * (32'(which) - 32'o20) +: 32] : 32'd0;
        8'o100:  word = {24'd0, fd_irq, chaos_ireq, in_irq, disk_irq, timer_pending};
        8'o101:  word = {26'd0, err[2], 1'b0, err[1], 2'b00, err[0]};
        8'o102:  word = {31'd0, errstop};
        8'o103:  word = rtc_seconds;
        8'o110, 8'o111, 8'o112, 8'o113, 8'o114, 8'o115: word = {8'd0, tm_rdata};
        // Revision 14's memory system's words (A14.9).
        8'o220, 8'o221, 8'o222, 8'o223, 8'o224, 8'o225, 8'o226, 8'o227:
                 word = PAGED ? ms_rdata : 32'd0;
        default: word = 32'd0;
      endcase
    end
  end

  logic [31:0] held;

  always_ff @(posedge clk) begin
    if (rst) begin
      mine  <= 1'b0;
      which <= 8'd0;
      taken <= 1'b0;
      held  <= 32'd0;
      reset_devices <= 1'b0;
    end else begin
      reset_devices <= take && dev_write && which == 8'o104 && wdata[0];
      // Block-disk's 200-203 and the video controller's 210 are theirs.
      mine  <= sel && (phys[21:8] == FEATURE_PAGE) && (phys[7:2] != 6'o40) && (phys[7:0] != 8'o210);
      which <= phys[7:0];
      if (take) begin
        taken <= 1'b1;
        held  <= word;
      end else if (!(mine && dev_rq)) begin
        taken <= 1'b0;
      end
    end
  end

  assign err_clear  = take && dev_write && which == 8'o101;
  assign errstop_we = take && dev_write && which == 8'o102;
  assign errstop_d  = wdata[0];
  assign ch_land    = take && chaos_answers;
  assign ch_wr      = dev_write;
  assign ch_which   = which[2:0];
  assign ch_wdata   = wdata[15:0];
  // The timers' words, 110 to 115: `which<2:0>` is the word less 110.
  assign tm_we      = take && dev_write && which[7:3] == 5'o11 && which[2:1] != 2'b11;
  assign tm_idx     = which[2:0];
  assign tm_wdata   = wdata[23:0];
  // Revision 14's words 220-227, written at the instant the page answers,
  // as muir's `bus_write` writes them.
  assign ms_we      = PAGED && take && dev_write && which[7:3] == 5'o22;
  assign ms_idx     = which[2:0];
  assign ms_wdata   = wdata;

  // No term is held off at `INTERRUPT-CONTROL<28>`'s edge: on QUUX it
  // resets nothing (contract Q11), and `RESET-DEVICES` needs no hold-off.
  assign irq = (|in_irq) || chaos_ireq || fd_irq;

  // The bus interface ANDs the acknowledgment with `-XBUS.RQ` itself
  // (`cadr_disk_controller.sv` has why the slave must not), and the lines are
  // driven only for a read, a write leaving them to the master.  The word is
  // the one taken at the answer, and before it the one being made, which no
  // strobe can take: `-LOADMD` follows the acknowledgment by the deskew.
  assign dev_ack = mine;
  assign drives  = mine && !dev_write;
  assign rdata   = drives ? (taken ? held : word) : 32'd0;

endmodule

`default_nettype wire
