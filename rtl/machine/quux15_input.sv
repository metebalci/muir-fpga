// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **REVISION 15'S KEYBOARD AND MOUSE** (contract Q3; G3 revision 15, A15b.3;
// MP2b rulings Q4 and rulings 2 Q1): muir's `quux_input::QuuxInput` on
// revision 15's register page, at its timing.  `quux_input.sv` is the same
// device on revisions 13 and 14, where the page answers a cycle in one tick
// and the mouse's counts are the I/O board's; this copy differs in the three
// things revision 15 changes, and in nothing else:
//
//     120   keyboard status: <0> a key word is waiting, <1> the FIFO
//           overflowed (a write clears it), <8> the keyboard's interrupt
//           enable (written)
//     121   a read takes the oldest key word, in <23:0>, <31:24> reading 0;
//           0 when none is waiting
//     122   the mouse: <11:0> the X count, <27:16> the Y count, <14:12> the
//           buttons; a read clears 123's <0>
//     123   mouse status: <0> the mouse moved or a button changed since 122
//           was read, <8> the mouse's interrupt enable (written)
//
// **1. A READ IS THE PAGE AS IT STOOD AT THE GRANT, ITS WORD A CLOCK LATER**
// (`quux15_devices.sv`'s rule; muir's `Machine::bus_read` in the grant's
// clock).  `rd` is the clock the core grants the read; the word is taken
// then into `rd_word`, which the devices give the core the clock after, and
// its side effect --- 121's word taken off the FIFO, 122's clear of 123's
// `<0>` --- is made at that clock's edge.  So a key word or a move that
// comes in the grant's own clock is not in the word, as in muir it comes
// after the read.
//
// **2. THE INTERRUPT IS THE PAGE AS THIS CLOCK'S WRITE LEAVES IT**
// (`irq`; A15b.3's row "A device register", rulings 2 Q1): an enable
// written in this clock counts, and a key word or a move coming in this
// clock does not --- it is in the page from the next clock, as muir's comes
// in between two clocks.  **A LEVEL A READ LOWERS IS HELD UNTIL THE READ'S
// RELEASE** (the register read ruling; muir's `QuuxInput::hold`): the read
// takes its word and makes its change at the grant, as in 1, and the
// interrupt bit it lowered --- `<4>` when 121 took the last key word, `<5>`
// when 122 cleared 123's `<0>` --- is kept in `held` and or'd into `irq`
// until the core's release (`rd_release`, `quux15_core.sv`'s `n_rgr_rel`):
// the clock after the word right after the read's start leaves EX, however
// late that word reaches EX, or a halt.  So that word's conditions see the
// level as before the read, and the next word that tests the interrupt sees
// it lowered.  `held` clears at the edge the release is up, the grant's own
// included, so a halted machine holds none.  A key word or a move that comes
// in meanwhile raises its bit as ever.  `irq_state` is the page's interrupt
// bits as the clock began, without `held`, which word 100 reads: no register
// access is granted while a read is held.
//
// **3. THE MOUSE'S COUNTS ARE KEPT HERE** (the MP5a review's finding 4):
// revision 15 has no I/O board, so the mouse's seven lines from
// `cadr_input_cables.sv` --- its quadrature phases and its three switches,
// the seam the CADR's card takes --- are turned into counts at a clock, as
// muir's `QuuxInput` keeps its own: a phase one step up is a count up, one
// step down a count down (`Encoders::levels`' Gray order, `mouse.rs`'s
// "phase up is to the right and down"), and a jump of two, which the face
// never makes, counts nothing, as the CADR's counters do.  The switches are
// the buttons as muir's mask has them, pressed low on the cable.  A count or
// a button changed in a clock sets 123's `<0>` at its edge, after any read
// of 122 in that clock, as muir's move comes after that clock's read.
//
// **THE KEYBOARD'S BOOT WORD** (`QuuxInput::take_boot`; `ioboard::boot_word`,
// `(word >> 6) & 0o377 == 0o360`) asks for a boot: `boot` is up for the
// clock after the word comes in, and the core halts the machine and then
// presses its `-BOOT`, as the console would (`quux15_core.sv`).  The word
// goes into the FIFO too, as on revisions 13 and 14, for the microcode to
// read after the PROM.
//
// **AND THE HOST'S HANDSHAKE**, unchanged: `busy` stands in for the card's
// `KBD READY`, up for one clock after every word taken and while the FIFO is
// full, which `cadr_input_cables.sv` waits on between words.
//
// The FIFO, the counts and the enables are reset by power-on alone: not by
// RESET-DEVICES (muir's `reset_devices`) nor by the console's `-RESET` or
// `-BOOT`, so a warm boot's key word is still there to be read.
//
// What holds it: `build/quux15_input_module.quux.pass`, the module against
// muir's `QuuxInput` over `golden/src/quux_input.rs`'s script, its mouse
// walked a step a clock on its lines; and `build/quux15_input.quux.pass`,
// the core's `input` group (`golden/src/quux15_input.rs`), clock for clock
// on muir's pipeline with key words and moves handed over at clocks; and
// `build/quux15_regread.quux.pass` (`golden/src/quux15_regread.rs`), the
// held levels across a late next word, a move or a key word between a
// read's grant and its release, and a halt at every clock.

`default_nettype none

module quux15_input #(
    parameter int unsigned FIFO_WORDS = 64
) (
    input  var logic        clk,
    input  var logic        rst,

    // The keyboard's cable: a word comes in at this clock's edge.
    input  var logic        kbd_strobe,
    input  var logic [23:0] kbd_code,
    // The mouse's seven lines as `cadr_input_cables.sv` drives them: <1:0>
    // HORA and HORB, <3:2> VERA and VERB, <6:4> the switches, low pressed.
    input  var logic [6:0]  mouse_lines,

    // A read granted this clock, and a write taken this clock, at the
    // word's offset on the page.
    input  var logic        rd,
    input  var logic [7:0]  rd_k,
    // The core's release of the read before: its lowered level counts from
    // the next clock.
    input  var logic        rd_release,
    input  var logic        wr,
    input  var logic [7:0]  wr_k,
    input  var logic [31:0] wdata,
    // The word read, the clock after its grant.
    output var logic [31:0] rd_word,

    // Word 100's <4> and <5>: as this clock's write leaves them, and as the
    // clock began.
    output var logic [1:0]  irq,
    output var logic [1:0]  irq_state,
    // The keyboard's boot word came in: a clock's request.
    output var logic        boot,
    // `KBD READY` for the host's handshake.
    output var logic        busy,

    // **THE READOUT'S VIEW, FOR A CHECKPOINT**: the FIFO's head and count,
    // the four flags, the buttons and the counts in one word, revision 13's
    // layout (`cadr_image.h`'s `IMG_QP_INPUT`):
    //   <43:38> head, <37:31> count, <30> overflowed, <29> kbd_enable,
    //   <28> mouse_changed, <27> mouse_enable, <26:24> the buttons,
    //   <23:12> Y, <11:0> X
    // and any one of the FIFO's words by its index.  The words a checkpoint
    // wants are `count` of them from `head`; a key word arriving while they
    // are read lands at the tail, past them.
    output var logic [47:0] ro_state,
    input  var logic [$clog2(FIFO_WORDS)-1:0] ro_fifo_a,
    output var logic [23:0] ro_fifo_q
);

  localparam logic [7:0] KBD_STATUS   = 8'o120;
  localparam logic [7:0] KBD_DATA     = 8'o121;
  localparam logic [7:0] MOUSE        = 8'o122;
  localparam logic [7:0] MOUSE_STATUS = 8'o123;
  localparam logic [7:0] BOOT_MATCH   = 8'o360;

  localparam int unsigned PTRW = $clog2(FIFO_WORDS);
  localparam int unsigned CNTW = $clog2(FIFO_WORDS + 1);

  logic [23:0]     fifo [FIFO_WORDS];
  logic [PTRW-1:0] head, tail;
  logic [CNTW-1:0] count;
  logic            overflowed, kbd_enable, mouse_enable, mouse_changed;
  logic [11:0]     mx, my;
  logic [2:0]      buttons;
  logic [3:0]      last_lines;
  logic            took;
  // The interrupt bits a read lowered, held until its release; and the
  // bits this clock's read lowers: 121 taking the last key word under 120's
  // enable, 122 clearing 123's `<0>` under 123's (`QuuxInput::hold`'s
  // `before & !levels()`).
  logic [1:0]      held, lowered;

  logic full, empty, pop, push;
  assign full  = count == CNTW'(FIFO_WORDS);
  assign empty = count == '0;
  assign pop   = rd && rd_k == KBD_DATA && !empty;
  assign push  = kbd_strobe && (!full || pop);
  // 122's read clears 123's `<0>`, at the grant as 121's pop is.
  logic clear;
  assign clear   = rd && rd_k == MOUSE;
  assign lowered = {clear && mouse_enable && mouse_changed,
                    pop && kbd_enable && count == CNTW'(1)};

  // The word at the grant: the page as the clock began.
  logic [31:0] word_now;
  always_comb begin
    unique case (rd_k)
      KBD_STATUS:   word_now = {23'd0, kbd_enable, 6'd0, overflowed, !empty};
      KBD_DATA:     word_now = empty ? 32'd0 : {8'd0, fifo[head]};
      MOUSE:        word_now = {4'd0, my, 1'b0, buttons, mx};
      MOUSE_STATUS: word_now = {23'd0, mouse_enable, 7'd0, mouse_changed};
      default:      word_now = 32'd0;
    endcase
  end

  // **THE MOUSE'S LINES TO A STEP**: each pair's phase, `A` its high bit and
  // `A ^ B` its low (`cadr_input_cables.sv`'s `cable`), against the phase the
  // clock before left.
  function automatic logic [1:0] phase(input logic [1:0] ab);
    return {ab[0], ab[0] ^ ab[1]};
  endfunction
  function automatic logic [11:0] stepped(input logic [11:0] c, input logic [1:0] was, input logic [1:0] now);
    unique case (2'(now - was))
      2'd1:    return c + 12'd1;
      2'd3:    return c - 12'd1;
      default: return c;
    endcase
  endfunction
  logic [11:0] mx_n, my_n;
  logic [2:0]  buttons_n;
  logic        moved;
  always_comb begin
    mx_n      = stepped(mx, phase(last_lines[1:0]), phase(mouse_lines[1:0]));
    my_n      = stepped(my, phase(last_lines[3:2]), phase(mouse_lines[3:2]));
    buttons_n = ~mouse_lines[6:4];
    moved     = mx_n != mx || my_n != my || buttons_n != buttons;
  end

  // The interrupt as this clock's write leaves it; this clock's read, key
  // word and move are the next clock's.
  logic kbd_enable_n, mouse_enable_n;
  assign kbd_enable_n   = (wr && wr_k == KBD_STATUS) ? wdata[8] : kbd_enable;
  assign mouse_enable_n = (wr && wr_k == MOUSE_STATUS) ? wdata[8] : mouse_enable;
  assign irq       = {mouse_enable_n && mouse_changed, kbd_enable_n && !empty} | held;
  assign irq_state = {mouse_enable && mouse_changed, kbd_enable && !empty};
  assign busy      = full || took;

  always_ff @(posedge clk) begin
    if (rst) begin
      head          <= '0;
      tail          <= '0;
      count         <= '0;
      overflowed    <= 1'b0;
      kbd_enable    <= 1'b0;
      mouse_enable  <= 1'b0;
      mouse_changed <= 1'b0;
      mx            <= 12'd0;
      my            <= 12'd0;
      buttons       <= 3'd0;
      last_lines    <= mouse_lines[3:0];
      took          <= 1'b0;
      boot          <= 1'b0;
      rd_word       <= 32'd0;
      held          <= 2'b00;
    end else begin
      if (rd) rd_word <= word_now;

      // A write first, then what comes in: a write that clears the
      // overflow in the clock a word is dropped leaves it set.
      if (wr) begin
        unique case (wr_k)
          KBD_STATUS: begin
            overflowed <= 1'b0;
            kbd_enable <= wdata[8];
          end
          MOUSE_STATUS: mouse_enable <= wdata[8];
          default: ;
        endcase
      end

      // A word in: onto the FIFO, or dropped with the overflow set.  A
      // word taken off by this clock's read makes room first.
      took <= kbd_strobe;
      if (kbd_strobe) begin
        if (push) begin
          fifo[tail] <= kbd_code;
          tail       <= (tail == PTRW'(FIFO_WORDS - 1)) ? '0 : tail + PTRW'(1);
        end else begin
          overflowed <= 1'b1;
        end
      end
      if (pop) head <= (head == PTRW'(FIFO_WORDS - 1)) ? '0 : head + PTRW'(1);
      count <= count + CNTW'(push) - CNTW'(pop);
      boot  <= kbd_strobe && kbd_code[13:6] == BOOT_MATCH;

      // The mouse: the read of 122 clears, a change in this clock sets.
      last_lines <= mouse_lines[3:0];
      mx         <= mx_n;
      my         <= my_n;
      buttons    <= buttons_n;
      if (clear) mouse_changed <= 1'b0;
      if (moved) mouse_changed <= 1'b1;

      // The levels the read lowered, held to its release.
      held <= rd_release ? 2'b00 : held | lowered;
    end
  end

  assign ro_state  = {4'd0, 6'(head), 7'(count), overflowed, kbd_enable, mouse_changed, mouse_enable,
                      buttons, my, mx};
  assign ro_fifo_q = fifo[ro_fifo_a];

  // Bits of the word written that no register takes.
  logic unused;
  assign unused = ^{wdata[31:9], wdata[7:0]};

endmodule

`default_nettype wire
