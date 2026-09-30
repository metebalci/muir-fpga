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
// **QUUX DECODES ITS OWN SPACE FROM `17000000` UP**, muir's
// `busint::decode_quux` (contracts Q5, Q7 and Q13), which `Rtl::start_bus_cycle`
// and `Machine::bus_read` both take on QUUX.  With `MACHINE` "quux":
//
//   the register page, physical `17777400`-`17777777` (page 37777), the
//   last page of the physical space, is a device, whatever else the address
//   is: it sits where the CADR's Unibus window ends, and it is decided
//   first.  Block-disk's four words at 200-203 and the video controller's
//   mode at 210 are among its words, each answered by its own slave;
//   the video controller's buffer, `VIDEO_WORDS` from `17000000`
//   (`Tv::buffer_words`), 40,960 words at the bitstreams' 1280 by 1024, where
//   the CADR's two boards have 32,768, is on the memory bus with main memory
//   and is a device here only as the memory path's seam takes it;
//   main memory is below `17000000`, as on the CADR;
//   and nothing else answers: not the old register page at `17377000`, not
//   the CADR's display and disk registers after it, not the rest of the old
//   Unibus window below the page, and not the color TV's ranges, QUUX having
//   no color board.  An access there fails at once with the Xbus NXM bit.
//
// **REVISION 13 DECODES A 28-BIT SPACE** (contract G1 §3.2, G2 §4.1;
// `WORD_BITS` 40 on QUUX), muir's `busint::decode_quux_13`:
//
//   the register page, `1777777400`-`1777777777`, the space's last page, is a
//   device, with revision 12's word offsets;
//   the frame buffer window, `VIDEO_WORDS` from `1760000000`, is on the memory
//   bus with main memory, and is `memory` here: the port tells the two apart
//   by the address (`quux_mem_port.sv`), and no slave needs the cycle;
//   main memory is below main memory's end, the boards' count times 64K
//   words, and below the window;
//   and nothing else answers: not revision 12's register page at
//   `17777400` or its frame buffer at `17000000`, which are main memory when
//   there is that much of it and nothing when there is not, and not the rest
//   of the space.
//
// `build/xbus_decode.quux13.pass` holds it at every one of the 268,435,456
// addresses, for three board counts.
//
// The CADR's decode is the text below `g_cadr`, unchanged; on the CADR the
// register page's addresses are the Unibus window's last page, where
// nothing answers.  What holds each: `build/xbus_decode.pass` the CADR's
// over all 4,194,304 addresses, and `build/xbus_decode.quux.pass` QUUX's,
// against a golden that asks muir the same question on QUUX.

`default_nettype none

module cadr_xbus_decode #(
    // "cadr" or "quux"; `cadr_machine.sv` refuses anything else.
    parameter string MACHINE = "cadr",
    // The video controller's buffer, in words, on QUUX: `cadr_machine.sv`
    // decides it.
    parameter int unsigned VIDEO_WORDS = 40960,
    // 32; or 40 on QUUX, revision 13's 28-bit space.
    parameter int unsigned WORD_BITS = 32,
    localparam bit          REV13     = MACHINE == "quux" && WORD_BITS > 32,
    localparam int unsigned PHYS_BITS = REV13 ? 28 : 22
) (
    // The bottom two bits pick a register *inside* a device rather than which
    // device: every region in Xbus I/O space is aligned to at least four
    // words, and the display's eight control registers to eight. So the decode
    // does not read them, and Verilator is right to say so.
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [PHYS_BITS-1:0] phys,    // physical word address
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
  //
  // **QUUX HAS NO UNIBUS** (contract Q5, `Geometry::unibus`): the window,
  // physical page 37000 and up, answers nothing on QUUX but its last page,
  // the register page (contract Q13), a read or a write failing at once
  // and setting the Xbus NXM bit (`busint::decode_quux`'s
  // `Responder::NoXbus`).  So on QUUX the window is `nxm` and never
  // `unibus`, and no cycle of the processor's reaches the Unibus side of the
  // bus interface at all.
  logic in_window;
  assign in_window = page >= 14'o37000;
  assign unibus    = (MACHINE != "quux") && in_window;

  // Xbus I/O space, the two slots below the Unibus.
  logic xbus_io;
  assign xbus_io = !in_window && page >= 14'o36000;

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

  if (REV13) begin : g_quux13
    // Revision 13's 28-bit space (see the header), in as few levels as it
    // can be: this is the far end of the map, and has two ticks.  The window
    // is the top 4M words, `phys<27:22>` all ones, so its offset is
    // `phys<21:0>`; the register page is in that range too and is decided
    // first.  Main memory's end is the boards' count on `phys<27:16>`, and
    // as seven bits count at most 127 boards, 8M words, main memory never
    // reaches the window, which needs no term of its own here.
    logic register_page, window, main;
    assign register_page = &phys[27:8];
    assign window        = (&phys[27:22]) && (phys[21:0] < 22'(VIDEO_WORDS));
    assign main          = phys[27:16] < 12'(boards);
    assign device = register_page;
    assign memory = window || main;
    assign nxm    = !memory && !device;
    // The CADR's and revision 12's ranges, the Unibus window's and the color
    // board's have no reader on revision 13.
    logic unused_rev12;
    assign unused_rev12 = ^{tv_buffer, tv_control, disk_regs, color_buffer, color_control, color_tv,
                            in_window, xbus_io};
  end else if (MACHINE == "quux") begin : g_quux
    // The register page, `Geometry::FEATURE_PAGE`, 256 words at the last
    // page of the space, not gated by `xbus_io` (contract Q13); and the
    // video controller's buffer in place of the CADR boards' 32K words,
    // which stays inside Xbus I/O space at the bitstreams' size (contract
    // Q13's O7: the DDR map gives it a 16-bit offset).
    logic feature_page, video_buffer;
    assign feature_page = page == 14'o37777;
    assign video_buffer = (phys - 22'o17000000) < 22'(VIDEO_WORDS);
    assign device = feature_page || (xbus_io && video_buffer);
    // The CADR's display and disk registers, the CADR boards' window and the
    // color TV's ranges have no reader here: nothing answers them on QUUX.
    logic unused_cadr;
    assign unused_cadr = ^{tv_buffer, tv_control, disk_regs, color_buffer, color_control, color_tv};
  end else begin : g_cadr
  assign device = xbus_io && (tv_buffer || tv_control || disk_regs
                              || (color_tv && (color_buffer || color_control)));
  end

  // A board is 64K words and they start at zero, so the whole comparison is on
  // the slot number.
  if (!REV13) begin : g_xbus_memory
  assign memory = !unibus && !xbus_io && ({1'b0, phys[21:16]} < boards);

  assign nxm = !unibus && !memory && !device;
  end

endmodule

`default_nettype wire
