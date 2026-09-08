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
// no extra fabric, because main memory is not a netlist.  The ceiling is 60:
// the memory board's address switch has six bits, so the space is 64 slots of
// 64K words, and the top four are taken by the display, the disk controller
// and the Unibus.

`default_nettype none

module cadr_xbus_decode (
    // The bottom two bits pick a register *inside* a device rather than which
    // device: every region in Xbus I/O space is aligned to at least four
    // words, and the display's eight control registers to eight. So the decode
    // does not read them, and Verilator is right to say so.
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [21:0] phys,    // physical word address
    /* verilator lint_on UNUSEDSIGNAL */
    input  var logic [6:0]  boards,  // 64K-word memory boards fitted, 1 to 60

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
  //   the display's frame buffer, simpletv::BUFFER 0o17000000 for
  //   BUFFER_WORDS 0o100000 --- 3,932,160 is 120 * 32,768;
  //   its control registers, simpletv::CONTROL 0o17377760 for 8;
  //   the disk controller's, disk_controller::REGS 0o17377774 for 4.
  //
  // The four words between the display's registers and the disk's answer to
  // nothing, and the reference says so too.
  logic tv_buffer, tv_control, disk_regs;
  assign tv_buffer  = phys[21:15] == 7'd120;      // 0o17000000, 32768 words
  assign tv_control = phys[21:3]  == 19'd507902;  // 0o17377760, 8 words
  assign disk_regs  = phys[21:2]  == 20'd1015807; // 0o17377774, 4 words

  assign device = xbus_io && (tv_buffer || tv_control || disk_regs);

  // A board is 64K words and they start at zero, so the whole comparison is on
  // the slot number.
  assign memory = !unibus && !xbus_io && ({1'b0, phys[21:16]} < boards);

  assign nxm = !unibus && !memory && !device;

endmodule

`default_nettype wire
