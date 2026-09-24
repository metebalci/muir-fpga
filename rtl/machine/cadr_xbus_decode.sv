// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Which side of the bus a physical address is on, and whether anything lives
// there.  muir's `busint::decode`, ported.
//
// The Xbus carries 22 address bits --- `-XADDR0` to `-XADDR21` on the
// connectors --- so the whole space is 4,194,304 words, and every one of them
// is checked against the reference rather than sampled.
//
// A word address, not a byte address: the CADR addresses 32-bit words, so the
// DDR byte address behind `memory` is this shifted left by two.
//
// `boards` is how many 64K-word memory boards are fitted, muir's
// `--main-memory-boards`, and it is the only thing here meant to change.
// Growing main memory from two million words to the ceiling is this input and
// no extra fabric, main memory being in DDR rather than here.  The ceiling is 60:
// the memory board's address switch has six bits, so the space is 64 slots of
// 64K words, and the top four are taken by the display, the disk controller
// and the Unibus.
//
// **QUUX DECODES ITS OWN XBUS I/O SPACE.**  With `MACHINE` "quux" the
// feature page, physical `17377000`-`17377377` (page 36776), is a device:
// muir's `Geometry::feature_word` answers it as `Responder::Device` ahead of
// `busint::decode_for`, and `Rtl::start_bus_cycle` does the same.  And the
// main display's buffer is MONO TV's, `MONO_TV_WORDS` from `17000000`
// (`busint::decode_for` with `Tv::buffer_words`), 40,960 words at the
// bitstreams' 1280 by 1024, where the CADR's two boards have 32,768.  The
// CADR's decode is the text below `g_cadr`, unchanged, and nothing on the
// CADR answers that page.  What holds each: `build/xbus_decode.pass` the
// CADR's over all 4,194,304 addresses, and `build/xbus_decode.quux.pass`
// QUUX's, against a golden that asks muir the same question on QUUX.

`default_nettype none

module cadr_xbus_decode #(
    // "cadr" or "quux"; `cadr_machine.sv` refuses anything else.
    parameter string MACHINE = "cadr",
    // MONO TV's buffer, in words, on QUUX: `cadr_machine.sv` decides it.
    parameter int unsigned MONO_TV_WORDS = 40960
) (
    // The bottom two bits pick a register *inside* a device rather than which
    // device: every region in Xbus I/O space is aligned to at least four
    // words, and the display's eight control registers to eight. So the decode
    // does not read them, and Verilator is right to say so.
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [21:0] phys,    // physical word address
    /* verilator lint_on UNUSEDSIGNAL */
    input  var logic [6:0]  boards,  // 64K-word memory boards fitted, 1 to 60

    // Whether the second display board --- the color TV, `tv::COLOR_TV` ---
    // is on the backplane.  muir's `busint::decode_with` takes the same fact
    // and `busint::decode` is it with none, so this input at zero is the
    // machine every check before this one was written against.
    //
    // **THE COLOR RANGES MUST NOT ANSWER WITHOUT IT, AND THE BAND DEPENDS ON
    // THAT.**  `COLOR-EXISTS-P` in `sys/window/color.lisp` is how System 100
    // finds out whether a machine has the board: it writes one into the first
    // buffer word with the error stop off and reads it back, and a machine
    // with no board there has to give it the NXM.  A fabric that answered
    // regardless would be walked into `COLOR:SETUP` on every cold boot.
    input  var logic        color_tv,

    output var logic        memory,  // main memory: the DDR bridge answers
    output var logic        device,  // Xbus I/O with something built there
    output var logic        nxm,     // Xbus space with nothing there
    output var logic        unibus   // on the Unibus; not this slice
);

  // `let page = (phys >> 8) & 0o37777`, and the two boundaries off it.
  logic [13:0] page;
  assign page = phys[21:8];

  // "the diagnostic bus's sixteen registers ... and the I/O board with its
  // Chaosnet interface" --- the Unibus half, which is its own slice.
  assign unibus = page >= 14'o37000;

  // Xbus I/O space, the two slots below the Unibus.
  logic xbus_io;
  assign xbus_io = !unibus && page >= 14'o36000;

  // What is built in Xbus I/O space.  Every one of these is aligned to its own
  // size, so each is a comparison on a slice of the address rather than a pair
  // of bounds:
  //
  //   the display's frame buffer, tv::BUFFER 0o17000000 for
  //   BUFFER_WORDS 0o100000 --- 3,932,160 is 120 * 32,768;
  //   its control registers, tv::CONTROL 0o17377760 for 8;
  //   the disk controller's, disk_controller::REGS 0o17377774 for 4.
  //
  // The four words between the display's registers and the disk's answer to
  // nothing, and the reference says so too.
  logic tv_buffer, tv_control, disk_regs;
  assign tv_buffer  = phys[21:15] == 7'd120;      // 0o17000000, 32768 words
  assign tv_control = phys[21:3]  == 19'd507902;  // 0o17377760, 8 words
  assign disk_regs  = phys[21:2]  == 20'd1015807; // 0o17377774, 4 words

  // And the color TV's two ranges, the same board at the other strap:
  // `lmtv.order`'s "For the normal TV, x is 6.  For the color TV, x is 5",
  // which is `tv::COLOR_TV` --- the buffer at 0o17200000 for the same
  // 0o100000 words, 3,997,696 being 122 * 32,768, and the eight control
  // registers at 0o17377750, the eight below the normal TV's.
  logic color_buffer, color_control;
  assign color_buffer  = phys[21:15] == 7'd122;      // 0o17200000, 32768 words
  assign color_control = phys[21:3]  == 19'd507901;  // 0o17377750, 8 words

  if (MACHINE == "quux") begin : g_quux
    // The feature page, `Geometry::FEATURE_PAGE`, 256 words, and MONO TV's
    // buffer in place of the CADR boards' 32K words.
    logic feature_page, mono_buffer;
    assign feature_page = page == 14'o36776;
    assign mono_buffer  = (phys - 22'o17000000) < 22'(MONO_TV_WORDS);
    logic color;
    assign color  = color_tv && (color_buffer || color_control);
    // MONO TV answers two of the eight registers the CADR's boards do: 0,
    // the mode register, and 4, the color map's write kept for a color
    // display to come.  1 to 3 and 5 to 7 are not there, and time out with
    // the Xbus NXM bit (`Tv::control_registers`, `busint::decode_for`).
    logic mono_control;
    assign mono_control = tv_control && (phys[1:0] == 2'd0);
    assign device = xbus_io && (mono_buffer || mono_control || disk_regs || feature_page || color);
    // `tv_buffer` is the CADR boards' window and has no reader here.
    logic unused_tv_buffer;
    assign unused_tv_buffer = tv_buffer;
  end else begin : g_cadr
  assign device = xbus_io && (tv_buffer || tv_control || disk_regs
                              || (color_tv && (color_buffer || color_control)));
  end

  // A board is 64K words and they start at zero, so the whole comparison is on
  // the slot number.
  assign memory = !unibus && !xbus_io && ({1'b0, phys[21:16]} < boards);

  assign nxm = !unibus && !memory && !device;

endmodule

`default_nettype wire
