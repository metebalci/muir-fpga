// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The video controller, QUUX's display, "video" for short: a one-bit frame
// buffer and one register, and nothing else.
//
// muir's `Tv` with `Board::Video` at the pin, ported: `Tv::buffer_offset`,
// `Tv::read_control` and `Tv::write_control`, and `busint::decode_quux` with
// `Tv::buffer_words` for what answers.
//
//   the buffer    `BUFFER_WORDS` words from `17000000`, 40,960 at the
//                 bitstreams' 1280 by 1024, 40 words a line; pixel x of line
//                 y is bit (x mod 32) of word (40 y + x / 32), the low bit
//                 leftmost, as on the CADR's TV.  The buffer is the video
//                 controller's memory, on the memory bus with main memory
//                 (contract Q7): the memory port's cache holds its words and
//                 writes them through to DDR at the display's base, where the
//                 scanout reads them.  This module says only that the cycle
//                 is the buffer's (`fb_sel`), which is how the port tells it
//                 from a register.  One word past the end fails at once with
//                 NXM, because the decode does not select it.
//   the mode      word 210 of the register page, `17777610` (revision 11,
//                 contract Q13): bit 2, black-on-white, is kept and reads
//                 back; every other bit reads 0 and a write of it goes
//                 nowhere.  Words 211-217 are the register page's reserved
//                 words, which the page answers (`quux_feature_page.sv`).
//   no interrupt, no sync program, no color map, no vertical flag: the
//   machine's clock is the processor's tick.
//
// **QUUX HAS NEITHER THE SIMPLE TV NOR THE LISPM TV**, so `cadr_memory_path.sv`
// builds this in the first display board's place under `MACHINE == "quux"`
// and `cadr_tv.sv` there only for the CADR.
//
// **THE MATCHES ARE HELD ONE TICK**, as `cadr_tv.sv`'s and the disk
// controller's are and for their reason: `phys` is the far end of the map
// and `dev_ack` and `fb_sel` must be gates on a held match.  The mode is
// asked in the one tick after the grant (`quux_mem_port.sv`), the first the
// match has the grant's address, and its bit is written then.
//
// What holds it: `build/quux13_tv.quux.pass`, whose program writes and reads
// the buffer's first and last words, reads one past its end and the word past
// the CADR's 32K, and writes and reads the mode and the seven reserved words
// after it, against muir's QUUX row for row; `build/quux_tv.pass` holds the
// CADR's side of the same program; `build/quux13_registers.quux.pass` finds
// nothing at the old registers, `17377760`-`17377767`; and the records aimed
// here in `mutations/list.txt`.

`default_nettype none

module quux_video #(
    // The video controller's buffer in words; `cadr_machine.sv` decides it.
    parameter int unsigned BUFFER_WORDS = 40960
) (
    input  var logic        clk,
    input  var logic        rst,

    input  var logic        sel,        // the held decode's `device`
    input  var logic        dev_rq,     // the register decode's ask, one tick
    input  var logic        dev_write,
    input  var logic [21:0] phys,       // a word address
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [31:0] wdata,      // the word written; bit 2 is kept
    /* verilator lint_on UNUSEDSIGNAL */
    output var logic        dev_ack,    // this module's register is asked
    output var logic [31:0] rdata,
    output var logic        drives,
    // The cycle is the buffer's: the memory path's bridge answers it.
    output var logic        fb_sel,
    // MODE BOW, for whatever shows the picture.
    output var logic        bow
);

  // The buffer at `17000000`, and the mode at word 210 of the register page.
  localparam logic [21:0] BUFFER = 22'o17000000;
  localparam logic [21:0] MODE   = 22'o17777610;

  logic ctl_c, fb_c, ctl, fb;
  assign ctl_c = sel && (phys == MODE);
  assign fb_c  = sel && ((phys - BUFFER) < 22'(BUFFER_WORDS));

  assign fb_sel  = fb;
  assign dev_ack = ctl;
  assign drives  = ctl && !dev_write;

  // ONCE PER CYCLE: the ask stands one tick on QUUX, and the word is taken
  // at the first tick of it, as `cadr_tv.sv` takes it.
  logic taken, store_now;
  assign store_now = ctl && dev_rq && dev_write && !taken;

  assign rdata = drives ? {29'd0, bow, 2'd0} : 32'd0;

  always_ff @(posedge clk) begin
    if (rst) begin
      ctl   <= 1'b0;
      fb    <= 1'b0;
      bow   <= 1'b0;
      taken <= 1'b0;
    end else begin
      ctl   <= ctl_c;
      fb    <= fb_c;
      if (store_now) bow <= wdata[2];
      if (!(ctl && dev_rq)) taken <= 1'b0;
      else if (store_now)   taken <= 1'b1;
    end
  end

endmodule

`default_nettype wire
