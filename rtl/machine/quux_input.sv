// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's keyboard and mouse on the register page (contract Q3): muir's
// `quux_input::QuuxInput`, ported.
//
//     120   keyboard status: <0> a key word is waiting, <1> the FIFO
//           overflowed (a write clears it), <8> the keyboard's interrupt
//           enable (written)
//     121   a read takes the oldest key word; 0 when none is waiting
//     122   the mouse: <11:0> the X count, <27:16> the Y count, <14:12> the
//           buttons as the CADR's Y register has them; a read clears 123's <0>
//     123   mouse status: <0> the mouse moved or a button changed since 122
//           was read, <8> the mouse's interrupt enable (written)
//
// The interrupt status's bits, word 100's <3> and <4>, are `irq`: each
// under its enable, and ORed into the interrupt the processor's jump
// conditions test (`Machine::interrupt_at`).  There is no beeper.
//
// **THE KEYBOARD IS A FIFO OF `FIFO_WORDS` OF THE CADR'S OWN KEY WORDS**,
// the twenty-four bits the keyboard's cable carries, which is what the
// terminal hands muir's (`QuuxInput::press`); a word past the sixty-fourth is
// dropped and <1> set.  On QUUX the cable reaches this module and not the
// I/O board, as muir's terminal delivers to the page on QUUX and to the board
// on the CADR.  **The keyboard's boot word still boots**
// (`QuuxInput::take_boot`): the same eight bits the I/O board's 25LS2521
// compares, `ioboard::boot_word`, and the same 4 us of `-BOOT*` the board
// makes, so the machine is booted and let go as by the button.
//
// **THE MOUSE IS THE CADR'S TWELVE-BIT COUNTS, TO WHICH THE HOST ADDS ITS
// MOTION**: here the I/O board's own quadrature counters and switches
// (`cadr_io_board.sv`), which the host drives through the mouse's seven lines
// as it always has, so no program on the processing system changes.  What
// this module adds is muir's `mouse_changed`: set in any tick the counts or
// the buttons differ from the tick before, cleared by a read of 122.
//
// **AND THE HOST'S HANDSHAKE**: `cadr_input_cables.sv` sends a word when the
// card's `KBD READY` is down and waits to see it rise after each.  On QUUX
// `busy` stands in for it: up for one tick after every word taken, and up
// while the FIFO is full, which is muir's `takes_key` the other way round.
//
// Reads and writes arrive from `quux_feature_page.sv`, one tick each at the
// instant the page answers the cycle (`rd`, `wr`), with the word's offset.
//
// What holds it: `build/quux_input.quux.pass`, the module against muir's
// `QuuxInput` over a script of presses, motion, buttons, reads and writes
// (`golden/src/quux_input.rs`); and `build/quux_page.quux.k4.pass`, a program
// reading the page on the whole machine with key words pressed on the cable.

`default_nettype none

module quux_input #(
    parameter int unsigned FIFO_WORDS = 64
) (
    input  var logic        clk,
    input  var logic        rst,

    // The keyboard's cable: `EOC.KBD^` and the word.
    input  var logic        kbd_strobe,
    input  var logic [23:0] kbd_code,
    // The I/O board's counts and switches, as its Y register has them.
    input  var logic [11:0] mouse_x,
    input  var logic [11:0] mouse_y,
    input  var logic [2:0]  mouse_buttons,

    // The page's access: one tick, at the word's offset.
    input  var logic        rd,
    input  var logic        wr,
    input  var logic [7:0]  which,
    input  var logic [31:0] wdata,
    output var logic [31:0] rdata,
    output var logic        mine,

    // Word 100's <3> and <4>.
    output var logic [1:0]  irq,
    // The keyboard's boot word, as the I/O board's `-BOOT*`: active low.
    output var logic        n_boot,
    // `KBD READY` for the host's handshake (see the header).
    output var logic        busy,

    // **THE READOUT'S VIEW, FOR A CHECKPOINT** (`cadr_machine.sv`'s selector
    // 12): the FIFO's head and count and the four flags in one word, taken in
    // one tick, and any one of the FIFO's words by its index.  The words a
    // checkpoint wants are `count` of them from `head`, and a key word
    // arriving while they are read lands at the tail, past them.
    //   ro_state   <13:8> head, <7:4> nothing, <3> overflowed, <2> kbd_enable,
    //              <1> mouse_changed, <0> mouse_enable; ro_count the count
    output var logic [13:0] ro_state,
    output var logic [$clog2(FIFO_WORDS + 1)-1:0] ro_count,
    input  var logic [$clog2(FIFO_WORDS)-1:0]     ro_fifo_a,
    output var logic [23:0] ro_fifo_q
);

  localparam logic [7:0] KBD_STATUS   = 8'o120;
  localparam logic [7:0] KBD_DATA     = 8'o121;
  localparam logic [7:0] MOUSE        = 8'o122;
  localparam logic [7:0] MOUSE_STATUS = 8'o123;


  // `ioboard::boot_word`, `(word >> 6) & 0o377 == 0o360`, and the board's
  // 4 us pulse (`cadr_io_board.sv`'s `BOOT_T`).
  localparam logic [7:0]  BOOT_MATCH = 8'o360;
  localparam int unsigned BOOT_T     = cadr_tick_pkg::ticks(4_000);

  localparam int unsigned PTRW = $clog2(FIFO_WORDS);
  localparam int unsigned CNTW = $clog2(FIFO_WORDS + 1);

  logic [23:0]     fifo [FIFO_WORDS];
  logic [PTRW-1:0] head, tail;
  logic [CNTW-1:0] count;
  logic            overflowed, kbd_enable, mouse_enable, mouse_changed;
  logic [11:0]     last_x, last_y;
  logic [2:0]      last_b;
  logic            took;
  logic [9:0]      boot_t;

  logic full, empty, pop, moved;
  assign full  = count == CNTW'(FIFO_WORDS);
  assign empty = count == '0;
  assign pop   = rd && which == KBD_DATA && !empty;
  assign moved = (mouse_x != last_x) || (mouse_y != last_y) || (mouse_buttons != last_b);

  assign mine = (which == KBD_STATUS) || (which == KBD_DATA)
             || (which == MOUSE) || (which == MOUSE_STATUS);

  always_comb begin
    unique case (which)
      KBD_STATUS:   rdata = {23'd0, kbd_enable, 6'd0, overflowed, !empty};
      KBD_DATA:     rdata = empty ? 32'd0 : {8'd0, fifo[head]};
      MOUSE:        rdata = {4'd0, mouse_y, 1'b0, mouse_buttons, mouse_x};
      MOUSE_STATUS: rdata = {23'd0, mouse_enable, 7'd0, mouse_changed};
      default:      rdata = 32'd0;
    endcase
  end

  // **THE REQUESTS AS THIS TICK LEAVES THEM**, a write of an enable, a word
  // in and a read taken all counted: the processor registers `SINTR` at the
  // edge that ends its microcycle, and muir counts a change that falls on
  // that edge as before it (`Machine::interrupt_at` after `bus_write` at
  // `answered_at`), so a write the page answers on the edge's own tick is in
  // the interrupt that edge takes.  Measured: taken from the registers, a
  // keyboard enable written on the edge reached `SINTR` a microcycle late.
  logic            kbd_enable_n, mouse_enable_n, changed_n;
  logic [CNTW-1:0] count_n;
  assign kbd_enable_n   = (wr && which == KBD_STATUS) ? wdata[8] : kbd_enable;
  assign mouse_enable_n = (wr && which == MOUSE_STATUS) ? wdata[8] : mouse_enable;
  assign changed_n      = moved || (mouse_changed && !(rd && which == MOUSE));
  assign count_n        = count + CNTW'(kbd_strobe && (!full || pop)) - CNTW'(pop);
  assign irq    = {mouse_enable_n && changed_n, kbd_enable_n && (count_n != '0)};
  assign n_boot = boot_t == 10'd0;
  assign busy   = full || took;

  always_ff @(posedge clk) begin
    if (rst) begin
      head          <= '0;
      tail          <= '0;
      count         <= '0;
      overflowed    <= 1'b0;
      kbd_enable    <= 1'b0;
      mouse_enable  <= 1'b0;
      mouse_changed <= 1'b0;
      last_x        <= 12'd0;
      last_y        <= 12'd0;
      last_b        <= 3'd0;
      took          <= 1'b0;
      boot_t        <= 10'd0;
    end else begin
      took <= 1'b0;
      // A word in: onto the FIFO, or dropped with the overflow set.  A pop
      // in the same tick makes room first, as muir's read and press are one
      // after the other and a full FIFO read by the machine takes the next.
      if (kbd_strobe) begin
        took <= 1'b1;
        if (!full || pop) begin
          fifo[tail] <= kbd_code;
          tail       <= (tail == PTRW'(FIFO_WORDS - 1)) ? '0 : tail + PTRW'(1);
        end else begin
          overflowed <= 1'b1;
        end
      end
      if (pop) head <= (head == PTRW'(FIFO_WORDS - 1)) ? '0 : head + PTRW'(1);
      count <= count_n;

      // The boot word, as the I/O board decodes it: two in a row re-arm.
      if (boot_t != 10'd0) boot_t <= boot_t - 10'd1;
      if (kbd_strobe && kbd_code[13:6] == BOOT_MATCH) boot_t <= 10'(BOOT_T);

      // The mouse: a change of the counts or the buttons since the last
      // tick, and a read of 122 after it, in muir's order --- the motion is
      // added and then the machine reads.
      last_x <= mouse_x;
      last_y <= mouse_y;
      last_b <= mouse_buttons;
      if (rd && which == MOUSE) mouse_changed <= 1'b0;
      if (moved) mouse_changed <= 1'b1;

      if (wr) begin
        unique case (which)
          KBD_STATUS: begin
            overflowed <= 1'b0;
            kbd_enable <= wdata[8];
          end
          MOUSE_STATUS: mouse_enable <= wdata[8];
          default: ;
        endcase
      end
    end
  end

  assign ro_state  = {6'(head), 4'd0, overflowed, kbd_enable, mouse_changed, mouse_enable};
  assign ro_count  = count;
  assign ro_fifo_q = fifo[ro_fifo_a];

  // Bits of the word written that no register takes.
  logic unused;
  assign unused = ^{wdata[31:9], wdata[7:0]};

endmodule

`default_nettype wire
