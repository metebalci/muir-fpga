// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// MONO TV, QUUX's display: a one-bit frame buffer and one register, and
// nothing else.
//
// muir's `Tv` with `Board::MonoTv` at the pin, ported: `Tv::buffer_offset`,
// `Tv::read_control` and `Tv::write_control`, and `busint::decode_for` with
// `Tv::buffer_words` for what answers.
//
//   the buffer    `BUFFER_WORDS` words from `17000000`, 40,960 at the
//                 bitstreams' 1280 by 1024, 40 words a line; pixel x of line
//                 y is bit (x mod 32) of word (40 y + x / 32), the low bit
//                 leftmost, as on the CADR's TV.  Every word is acknowledged
//                 as an Xbus device's, and the words themselves are the
//                 memory path's bridge at the display's base, as the CADR's
//                 boards' are: this module says only that the cycle is its
//                 own (`fb_sel`).  One word past the end times out with NXM,
//                 because the decode does not select it.
//   register 0    `17377760`, the mode register: bit 2, black-on-white, is
//                 kept and reads back; every other bit reads 0 and a write of
//                 it goes nowhere.
//   register 4    `17377764`, the color map's write, kept for a color
//                 display to come: it answers, reads 0 and takes no write.
//   registers 1 to 3 and 5 to 7   not there: `cadr_xbus_decode.sv` does
//                 not select them, so this is never asked and an access
//                 times out with the Xbus NXM bit, as muir's
//                 `Tv::control_registers` has it at the pin.
//   no interrupt, no sync program, no color map, no vertical flag: the
//   machine's clock is the processor's tick.
//
// **QUUX HAS NEITHER THE SIMPLE TV NOR THE LISPM TV**, so `cadr_memory_path.sv`
// builds this in the first display board's place under `MACHINE == "quux"`
// and `cadr_tv.sv` there only for the CADR.
//
// **THE MATCHES ARE HELD ONE TICK**, as `cadr_tv.sv`'s and the disk
// controller's are and for their reason: `phys` is the far end of the map
// and `dev_ack` and `fb_sel` must be gates on a held match.
//
// What holds it: `build/quux_tv.quux.pass`, whose program writes and reads
// the buffer's first and last words, reads one past its end and the word past
// the CADR's 32K, and writes and reads all eight registers, the six that are
// not there timing out, against muir's
// QUUX row for row; `build/quux_tv.pass` holds the CADR's side of the same
// program; and the records aimed here in `mutations/list.txt`.

`default_nettype none

module quux_mono_tv #(
    // MONO TV's buffer in words; `cadr_machine.sv` decides it.
    parameter int unsigned BUFFER_WORDS = 40960
) (
    input  var logic        clk,
    input  var logic        rst,

    input  var logic        sel,        // the held decode's `device`
    input  var logic        dev_rq,     // -XBUS.RQ, as a positive level
    input  var logic        dev_write,
    input  var logic [21:0] phys,       // -XADDR21..0, a word address
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [31:0] wdata,      // MEM<31:0> from the cpu; bit 2 is kept
    /* verilator lint_on UNUSEDSIGNAL */
    output var logic        dev_ack,    // -XBUS.ACK, for the eight registers
    output var logic [31:0] rdata,
    output var logic        drives,
    // The cycle is the buffer's: the memory path's bridge answers it.
    output var logic        fb_sel,
    // MODE BOW, for whatever shows the picture.
    output var logic        bow
);

  // `tv::NORMAL_TV`'s strap: the buffer at `17000000`, the eight registers at
  // `17377760`.
  localparam logic [21:0] BUFFER  = 22'o17000000;
  localparam logic [18:0] CONTROL = 19'd507902;

  logic ctl_c, fb_c, ctl, fb;
  logic [2:0] which;
  assign ctl_c = sel && (phys[21:3] == CONTROL);
  assign fb_c  = sel && ((phys - BUFFER) < 22'(BUFFER_WORDS));

  assign fb_sel  = fb;
  assign dev_ack = ctl;
  assign drives  = ctl && !dev_write;

  // ONCE PER BUS CYCLE: -XBUS.RQ stands for tens of ticks and the word is
  // taken at the first of them, as `cadr_tv.sv` takes it.
  logic taken, store_now;
  assign store_now = ctl && dev_rq && dev_write && !taken;

  assign rdata = drives ? ((which == 3'd0) ? {29'd0, bow, 2'd0} : 32'd0) : 32'd0;

  always_ff @(posedge clk) begin
    if (rst) begin
      ctl   <= 1'b0;
      fb    <= 1'b0;
      which <= 3'd0;
      bow   <= 1'b0;
      taken <= 1'b0;
    end else begin
      ctl   <= ctl_c;
      fb    <= fb_c;
      which <= phys[2:0];
      if (store_now && which == 3'd0) bow <= wdata[2];
      if (!(ctl && dev_rq)) taken <= 1'b0;
      else if (store_now)   taken <= 1'b1;
    end
  end

endmodule

`default_nettype wire
