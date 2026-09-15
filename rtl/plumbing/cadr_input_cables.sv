// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The I/O board's other two cables: the KEYBOARD's and the MOUSE's, as one
// page of registers Linux drives over `M_AXI_GP0`.
//
// **WHAT THE SEAM IS, AND WHICH HALF OWNS WHAT.**  The card is
// `rtl/machine/cadr_io_board.sv`'s, and it is held to `muir::ioboard` over a
// scripted trace.  What crosses its edge is what crossed MIT's: a
// twenty-four-bit word arriving off the three 74LS164s at IOBKBD with
// `EOC.KBD^` as its strobe, and the mouse's SEVEN LINES --- four quadrature
// and three switches, which the 74LS14s at IOBMSE 0A25 and 0A27 invert on
// their way to the 74LS374 at 0A24.  This module is the far end of both, the
// way `cadr_serial_line.sv` is the far end of the 2651's line and
// `cadr_chaos_cable.sv` of the Chaosnet's cable.
//
// **SO THE MOUSE'S QUADRATURE ENCODER IS HERE.**  `docs/io-board.md` settled
// that at slice two: the card takes the lines, as MIT's does, and "whatever
// turns a USB mouse's deltas into quadrature phases is fabric beside it".  A
// card taking ready-made deltas would be a different card and
// `build/iob.golden` would stop being a reference for the mouse half.  It cannot be in the program either: a step is
// `muir::terminal::mouse::MOUSE_STEP_NS` = 16,000 ns of the machine's own
// time, 32 real microseconds at this board's tick, so a program making
// phases over `M_AXI_GP0` would be writing fifty thousand times a second.
// The deltas cross, the phases are made here, and the card sees the cable it
// was built for.
//
// **AND THE KEYBOARD'S HANDSHAKE IS muir's OWN.**  The card's rule is MIT's:
// "a word landing on one not yet read replaces it", the 74LS74 at IOBKBD
// 0B30 having only `-READ.KBD.LOW` on its clear.  `muir::terminal::keyboard`
// does not rely on that.  `Keyboard::deliver` is four lines --- `if
// board.keyboard_ready() { return false; }`, else pop a word and press it ---
// so muir hands the board one word at a time and holds the rest in a queue
// of its own, the board's `KBD READY` being the keyboard's `DONE` inverted.
// **This module is that handshake in fabric**, which is the only place it can
// be: the gate is a level on the card that changes 8 us after a Unibus read,
// and a program polling it over AXI would be the one doing the racing.
//
// **THE BACKLOG IS THE PROGRAM'S AND THE BUFFER IS THIS MODULE'S.**  muir
// holds 256 words (`keyboard::BACKLOG`, and `terminal::INPUT_BACKLOG` in
// front of it, which drops the OLDEST WHOLE KEYSTROKE --- its down and its up
// together --- when full).  That belongs where it is, in the program, because
// dropping a keystroke whole is a decision about keystrokes and this module
// has never heard of one; what is here is `DEPTH` words, enough that a
// program need not poll at the card's own rate.  The queue is bounded and
// the overflow is counted, so a machine that really has stopped reading
// still loses words, exactly as the cable does, and `LOST` is the record of
// it rather than a silence.  A program that reads `STAT` before it writes
// never reaches it.
//
// ## THE AUTOBOOT TRAP, AND THE FOUR THINGS THAT KEEP THIS OUT OF IT
//
// **The machine asks whether anybody is typing, four instructions into
// microcode 323**, and MIT's own source is `sys/ucadr/uc-cadr.lisp` at
// `(LOC 6)`:
//
//     (CALL-XCT-NEXT PHYS-MEM-READ)
//    ((VMA) (A-CONSTANT 17772045))        ;Unibus 764112, the KBD CSR
//     (JUMP-IF-BIT-CLEAR (BYTE-FIELD 1 5) MD COLD-BOOT)
//     (CALL-XCT-NEXT PHYS-MEM-READ)
//    ((VMA) (A-CONSTANT 17772040))        ;Unibus 764100, KBD LOW
//    ((MD) (BYTE-FIELD 6 0) MD)
//     (JUMP-EQUAL MD (A-CONSTANT 46) COLD-BOOT)
//
// So `KBD READY` clear is a COLD boot, and ready is a WARM one unless the
// low six bits of the word are `0o46`.  **Any word waiting there at boot
// therefore takes the machine down the warm path**, which is the path for a
// machine being restarted into a band it already has, and is not what a
// board coming up wants.  The only defense is that nothing is waiting, and
// CLAUDE.md names this as the trap aimed at whatever carries keys.  These
// are the four legs that keep it shut.
//
// **AND `0o46` IS THE COLD BOOT WORD'S OWN LOW SIX BITS, NOT A KEY
// POSITION.**  An earlier version of this comment read the test backwards:
// it said that `0o46` is the Status key's position on the new keyboard, so
// no key a viewer could press would make the test true.  That is a
// coincidence of two numbers and not what the microcode is doing.  The word
// at `764100` is not a key position at all when the machine is booting ---
// it is the word the KEYBOARD'S OWN FIRMWARE sent when somebody held both
// Controls and both Metas with Rubout, whose low six bits are `0o46`
// (`sys/io1/ukbd.lisp`'s `check-boot`, and muir's `docs/keyboard-boot.md`).
// So the test at `(LOC 6)` is the far end of the boot chord: the keyboard
// decides cold or warm, the I/O board boots the machine off the word, and
// the microcode reads the same word back to see which was asked for.  What
// takes the machine down the warm path is an ORDINARY word left in the
// register, which is exactly what the four legs below are about.
//
//   1. **THE ONLY SOURCE OF `kbd_strobe` IS AN AXI WRITE.**  Nothing else in
//      this module can make one: the queue is loaded at `KEY` and nowhere
//      else, and it comes up empty at reset.  So from configuration until a
//      program writes a word, the card is offered nothing at all.  This is
//      the leg muir had to build too, and its `unibus.rs` says what happens
//      without it: an un-reset keyboard receiver read the idle-high cable as
//      twenty-four ones, `KBD READY` was up 196 us after power-on, and the
//      microcode took a warm boot nobody asked for.
//   2. **A MACHINE RESET EMPTIES THE QUEUE.**  `mach_rst` is the CADR's own
//      reset --- BTN1, the MMCM's lock, or the console's `RESET_KEY` --- and
//      it is a separate port from `rst` for exactly this: a key typed at the
//      machine that was is not a key typed at the machine that is.  Without
//      it, a console reset of a running board would restart the microcode
//      into a card holding somebody's keystroke, which is the trap arriving
//      by the one route leg 4 does not cover.
//   3. **`CTL`'s FLUSH, which a program writes before it can receive a
//      keystroke.**  `cadr-terminal` writes it after the guard and before it
//      binds its socket, so a program restarted under a running machine
//      starts with the seam empty.  A program that takes keys from a device
//      the KERNEL has been buffering --- `cadr-usb-input`, when it is built
//      --- must drain that device before its first write here, because the
//      buffering happens on the far side of this seam and no register in
//      this module can see it.
//   4. **And the timing, which is why the trap has not bitten and is NOT
//      the guarantee.**  The machine reaches that test about 0.41 s after
//      reset --- microcycle 1,410,551 at 29 ticks of 10 ns --- and Linux
//      takes some fifteen seconds to reach userspace, so on this board the
//      decision is made long before any program could have written a word.
//      That is an accident of two rates and is recorded as one.
//
// ## The registers
//
// Eight words at the base `cadr_gp0_split.sv` gives this page, and
// `input_face.h` is the other half of this table:
//
//    0  IDENT    reads `IDENT`, "INPT", so that the first read can tell the
//                face from a bus that answers zeros or from the default
//                slave's "NONE"
//    1  STAT     bit 0  `KBD READY` on the card: a word is waiting unread
//                bit 1  `MOUSE READY` on the card: a change is waiting unread
//                bit 2  the queue has room for another word
//                bit 3  the mouse still owes steps
//                bits 13:8  how many words the queue holds
//    2  KEY      written: bits 23:0, one word for the card's shift register,
//                queued.  Dropped and counted in `LOST` when the queue is
//                full.  Read: the word last HANDED TO THE CARD, with bit 24
//                set once one ever has been
//    3  MOUSE    written: bits 11:0 `dx` and bits 23:12 `dy`, both two's
//                complement, ADDED to what is owed and saturating.  Positive
//                is RIGHT and DOWN, which is `mouse.rs`'s own "phase up is
//                to the right and down".  Read: what is still owed, in the
//                same two fields
//    4  BUTTONS  bits 2:0, the mouse's three switches as a LEVEL and not an
//                event --- which is what they are on the cable, and what a
//                viewer's `PointerEvent` carries.  Bit 0 is `MOUSE TAILSW`,
//                bit 1 `MOUSE MIDSW`, bit 2 `MOUSE HEADSW`, which is RFB's
//                own left, middle and right in RFB's own order: muir's
//                `mouse.rs` says the two masks need no translation.  Read
//                back
//    5  CTL      bit 0 FLUSH, self-clearing: empty the queue, abandon what
//                the mouse owes, and lift the switches.  See leg 3 above
//    6  LOST     read only, saturating: words dropped for want of room
//    7  LINES    read only, a diagnostic: bits 6:0 the seven lines this
//                module is driving, exactly as the card's connector sees
//                them, and bits 23:16 the card's own `csr_face`.  The whole
//                seam in one word, for a bring-up on the board
//
// Every other word in the page reads zero and ignores writes, and every
// address in it is answered: see `cadr_gp_regs.sv`, which is the AXI3 face
// and is where the protocol lives.
//
// **THERE IS NO INTERRUPT AND THAT IS DELIBERATE.**  The Chaosnet cable and
// the serial line each raise one, because on those seams the MACHINE starts
// things the program has to be told about.  Everything on this seam
// originates in Linux, so there is nothing the fabric knows that Linux did
// not already know; `STAT` says what the card has done with what was handed
// over, and a program that wants to know reads it.  A fourth `IRQ_F2P` line
// for a wire with nothing to say would be symmetry bought with a pin.
//
// NO muir REFERENCE EXISTS FOR THE REGISTER FACE --- nothing in MIT's
// drawings is an AXI slave --- but the CABLES have one, and this is held to
// it: `terminal::mouse::MOUSE_STEP_NS` for the rate, `Encoders::levels` for
// the Gray order, `Encoders::default`'s `x_phase: 2` for where a mouse at
// rest sits, `ioboard::MouseInterface::lines` for which of the seven is
// which and which way round a pressed switch is, and `Keyboard::deliver` for
// the handshake.  `tb/cadr_gp0_split_tb.cpp` drives this face through the
// splitter on one side and reads the CARD's own keyboard and mouse registers
// over the Unibus on the other --- read-back across the whole seam, which is
// the only thing that can hold an encoder to anything.
//
// ## Where the phases fall, and why the card sees every one of them
//
// muir's `MouseInterface::sample` SNAPS each step onto the card's own 8,000
// ns `KB CLK^`: `Encoders::next_change` answers `self.next.max(now)` with
// `now` the LAST EDGE ALREADY TAKEN, so a step whose due time has fallen
// behind is dragged forward to that edge and, the step being 16,000 and the
// edge 8,000, every step after it lands on an edge too.  Its own comment
// says what it is for --- to stop a long-idle encoder firing a burst of
// back-dated steps.  This module has no back-dating to undo, its divider
// running whether or not anything is owed, and so it does not reproduce that
// arrangement and does not need to.
//
// **What the card can observe is one transition per sampling period, and
// that is a property of the RATE alone**: the steps here are 16,000 ns apart
// and the card samples every 8,000, so between two consecutive samples there
// is at most one transition however the two dividers are phased --- which
// matters, because the card's divider is reset with the MACHINE and this one
// with the PORT.  The count the card arrives at is therefore the count that
// was asked for.  The only thing muir's snap buys that this does not is the
// instant of the FIRST step of a move, which it can place one 8,000 ns edge
// earlier; nothing on either side of the seam can see that, and
// `tb/cadr_gp0_split_tb.cpp` compares the card's counters against the deltas
// written rather than against a phase.

`default_nettype none

module cadr_input_cables #(
    // "INPT", so that a read of word 0 can be told from a bus of zeros.
    parameter logic [31:0] IDENT = 32'h494E_5054,
    // How many key words wait here.  Sixteen: the BACKLOG is the program's,
    // muir holding 256 there, and what this buys is that a program need not
    // poll at the card's own 8 us rate.  Each word is 24 bits.
    parameter int unsigned DEPTH = 16
) (
    input  var logic        clk,
    // The PORT's reset: this face's own, released when Linux brings the
    // general purpose port up.
    input  var logic        rst,
    // **THE MACHINE'S reset, which EMPTIES THE QUEUE**: leg 2 of the
    // autoboot trap in the header.  A separate port and not an OR into
    // `rst`, because resetting this face's AXI state machine mid-transaction
    // is how `cadr_arty.sv`'s own note says the console would have frozen
    // both Arm cores.
    input  var logic        mach_rst,

    // --- the face: one 4 KB page of `M_AXI_GP0`, the offset only ---------
    input  var logic [11:0] s_awaddr,
    input  var logic [3:0]  s_awlen,
    input  var logic [11:0] s_awid,
    input  var logic        s_awvalid,
    output var logic        s_awready,
    input  var logic [31:0] s_wdata,
    input  var logic [3:0]  s_wstrb,
    input  var logic        s_wlast,
    input  var logic        s_wvalid,
    output var logic        s_wready,
    output var logic [1:0]  s_bresp,
    output var logic [11:0] s_bid,
    output var logic        s_bvalid,
    input  var logic        s_bready,
    input  var logic [11:0] s_araddr,
    input  var logic [3:0]  s_arlen,
    input  var logic [11:0] s_arid,
    input  var logic        s_arvalid,
    output var logic        s_arready,
    output var logic [31:0] s_rdata,
    output var logic [1:0]  s_rresp,
    output var logic [11:0] s_rid,
    output var logic        s_rlast,
    output var logic        s_rvalid,
    input  var logic        s_rready,

    // --- the two cables, as `cadr_io_board.sv` takes them -----------------
    // `EOC.KBD^` and the word off the three 74LS164s.
    output var logic        kbd_strobe,
    output var logic [23:0] kbd_code,
    // The seven lines as the MOUSE drives them --- bits 0 to 3 `HORA`,
    // `HORB`, `VERA`, `VERB` and bits 4 to 6 `TAILSW`, `MIDSW`, `HEADSW`,
    // each switch pulled to ground when pressed --- which is the cable and
    // not the board: the 74LS14s invert all seven, and the card's own
    // `lines` is `~mouse_lines`.  All ones is a mouse at rest with nothing
    // pressed, which is what the card's `mnew` comes up holding and what
    // muir's `Encoders::default` sits at.
    output var logic [6:0]  mouse_lines,

    // --- what the card says about what it was given -----------------------
    // `csr_face`, the 74LS175's four enables with the two ready flops above
    // them: bit 5 `KBD READY`, bit 4 `MOUSE READY`.  Registered on the way
    // in, so the only thing between the card's flop and this module's is the
    // card's own `assign` --- a module a level above `cadr_machine` gets
    // none of `cadr_machine.xdc`, which CLAUDE.md records at -12.837 ns, and
    // a register at each end is the shape that does not care.
    input  var logic [7:0]  card_csr
);

  // `mouse::MOUSE_STEP_NS` = 16,000, in ticks of MIT's 5 ns grid.  **The
  // five is `TICK_NS` and not the board's clock period**, which is 10 ns:
  // `cadr_phase_gen.sv`'s header names that collision, and the two tens have
  // nothing to do with each other.  So a step is 3,200 ticks, which is 32
  // real microseconds at this board's tick, and the mouse keeps the card's
  // own time.
  localparam int unsigned MOUSE_STEP_T = 16_000 / 5;

  // The count reaches DEPTH and the pointers only DEPTH-1, so they are
  // different widths: a pointer as wide as the count indexes an array with
  // a bit to spare, which Verilator reports as a WIDTHTRUNC.
  localparam int unsigned CNTW = $clog2(DEPTH + 1);
  localparam int unsigned PTRW = $clog2(DEPTH);

  // ------------------------------------------------------------------------
  // The AXI3 face
  // ------------------------------------------------------------------------
  logic [9:0]  w_word, r_word;
  logic        wr, rd;
  logic [31:0] wr_data, wr_mask, rd_data;

  cadr_gp_regs u_regs (
      .clk(clk), .rst(rst),
      .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awid(s_awid),
      .s_awvalid(s_awvalid), .s_awready(s_awready),
      .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast),
      .s_wvalid(s_wvalid), .s_wready(s_wready),
      .s_bresp(s_bresp), .s_bid(s_bid), .s_bvalid(s_bvalid), .s_bready(s_bready),
      .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arid(s_arid),
      .s_arvalid(s_arvalid), .s_arready(s_arready),
      .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rid(s_rid),
      .s_rlast(s_rlast), .s_rvalid(s_rvalid), .s_rready(s_rready),
      .w_word(w_word), .wr(wr), .wr_data(wr_data), .wr_mask(wr_mask),
      .r_word(r_word), .rd(rd), .rd_data(rd_data)
  );

  // Nothing here CONSUMES on a read --- the one register that would, `KEY`'s
  // read side, deliberately reports the word last sent rather than taking
  // one --- so `rd` is not needed and is folded below with the other
  // unread bits.

  // ------------------------------------------------------------------------
  // What this module keeps
  // ------------------------------------------------------------------------
  logic [23:0]      queue [DEPTH];
  logic [PTRW-1:0]  head, tail;
  logic [CNTW-1:0]  count;
  logic [23:0]      last_sent;         // the word last handed to the card
  logic             ever_sent;
  logic [31:0]      lost;              // saturating

  logic signed [11:0] owed_x, owed_y;
  logic [1:0]         cx, cy;          // the two encoders' phases
  logic [2:0]         sw;              // the three switches, 1 = pressed
  logic [11:0]        step_t;          // the step divider

  logic [7:0]         csr_q;           // `card_csr`, registered on the way in
  logic               kbd_ready, mouse_ready;
  assign kbd_ready   = csr_q[5];
  assign mouse_ready = csr_q[4];

  // A word has gone to the card and its `KBD READY` has not been seen yet.
  // **WITHOUT THIS THE GATE LETS THREE WORDS OUT BACK TO BACK**, and it is
  // worth writing down because it is not visible in the gate itself: the
  // card raises `KBD READY` at the edge it sees the strobe, `card_csr` is
  // combinational off that flop, and `csr_q` registers it one edge later ---
  // so `kbd_ready` here is still down for the two ticks after a word left,
  // and a queue with three words in it would strobe all three into a shift
  // register that holds one.  The flag is cleared where the card's own bit
  // is seen, so the handshake is exactly `Keyboard::deliver`'s with the
  // round trip's latency taken out of it.
  logic sent_pending;

  logic room, owes, taking;
  assign room = (count != CNTW'(DEPTH));
  assign owes = (owed_x != 12'sd0) || (owed_y != 12'sd0);
  // A word goes to the card this tick.  Named, because the queue's count is
  // written from two places at once and both have to agree about it.
  assign taking = !kbd_ready && !sent_pending && (count != '0);

  // `Encoders::levels`: `g = phase ^ (phase >> 1)`, `A` is `g & 2` and `B`
  // is `g & 1`, so the pair runs 00, 01, 11, 10 as the phase counts up and
  // ONE LINE moves a step.  For a two-bit phase that is `A = p[1]` and
  // `B = p[1] ^ p[0]`, and the pair as `{HORB, HORA}` is what this returns.
  // **PHASE UP IS RIGHT AND DOWN**, `mouse.rs`'s own words, and the card's
  // `step_count` --- `up = o[0] ^ n[1]` on the INVERTED lines --- agrees:
  // muir's own test walks a rightward move as board-side `00, 10, 11, 01`
  // with counts 0, 1, 2, 3.
  function automatic logic [1:0] cable(input logic [1:0] p);
    return {p[1] ^ p[0], p[1]};
  endfunction

  // The cable: four quadrature levels as the encoders drive them, and three
  // switches each pulled to GROUND when pressed, which is why `sw` is
  // complemented and the quadrature is not.
  assign mouse_lines = {~sw, cable(cy), cable(cx)};

  // ------------------------------------------------------------------------
  // What a read gives
  // ------------------------------------------------------------------------
  logic [31:0] stat_word;
  assign stat_word = {18'd0, 6'(count), 4'd0, owes, room, mouse_ready, kbd_ready};

  always_comb begin
    unique case (r_word)
      10'd0:   rd_data = IDENT;
      10'd1:   rd_data = stat_word;
      10'd2:   rd_data = {7'd0, ever_sent, last_sent};
      10'd3:   rd_data = {8'd0, 12'(owed_y), 12'(owed_x)};
      10'd4:   rd_data = {29'd0, sw};
      // `CTL` is self-clearing, so it always reads zero: a program that
      // wrote FLUSH and read the word back would otherwise be told the
      // flush is still pending, which it never is.
      10'd5:   rd_data = 32'd0;
      10'd6:   rd_data = lost;
      10'd7:   rd_data = {8'd0, csr_q, 9'd0, mouse_lines};
      default: rd_data = 32'd0;
    endcase
  end

  // ------------------------------------------------------------------------
  // The two cables
  // ------------------------------------------------------------------------
  logic flush;
  assign flush = wr && (w_word == 10'd5) && wr_data[0] && wr_mask[0];

  always_ff @(posedge clk) begin
    if (rst) begin
      head       <= '0;
      tail       <= '0;
      count      <= '0;
      last_sent  <= 24'd0;
      ever_sent  <= 1'b0;
      lost       <= 32'd0;
      owed_x     <= 12'sd0;
      owed_y     <= 12'sd0;
      // `Encoders::default`'s `x_phase: 2`, which is both lines of each pair
      // HIGH on the cable --- "what the board's 74LS14s read with nothing
      // plugged in, so a mouse that has not yet moved reads as no mouse".
      // The card's four quadrature bits are then zero at rest.
      cx         <= 2'd2;
      cy         <= 2'd2;
      sw         <= 3'd0;
      step_t     <= 12'(MOUSE_STEP_T - 1);
      csr_q        <= 8'd0;
      sent_pending <= 1'b0;
      kbd_strobe   <= 1'b0;
      kbd_code     <= 24'd0;
    end else begin
      csr_q <= card_csr;

      // `EOC.KBD^` is one tick: the card samples it level-high every tick
      // with no gate of its own, so a level held two ticks is two words.
      kbd_strobe <= 1'b0;

      // --- the step divider, free-running.  See the header: what the card
      // can observe is one transition per sampling period, which is a
      // property of the rate and not of the phase, so this needs no
      // relationship to the card's own 8,000 ns clock.
      if (step_t == 12'd0) step_t <= 12'(MOUSE_STEP_T - 1);
      else step_t <= step_t - 12'd1;

      // --- one step of each axis at the divider's end.  Both axes step on
      // the same tick when both are busy, as `Encoders::step` does.
      if (step_t == 12'd0) begin
        if (owed_x > 12'sd0) begin
          cx     <= cx + 2'd1;
          owed_x <= owed_x - 12'sd1;
        end else if (owed_x < 12'sd0) begin
          cx     <= cx - 2'd1;
          owed_x <= owed_x + 12'sd1;
        end
        if (owed_y > 12'sd0) begin
          cy     <= cy + 2'd1;
          owed_y <= owed_y - 12'sd1;
        end else if (owed_y < 12'sd0) begin
          cy     <= cy - 2'd1;
          owed_y <= owed_y + 12'sd1;
        end
      end

      // --- a word off the queue, while the card has read the last one.
      // **THE GATE IS `KBD READY` AND NOT A TIMER**, which is
      // `Keyboard::deliver` and is what makes this a handshake rather than a
      // second guess at the cable's rate.
      if (kbd_ready) sent_pending <= 1'b0;
      if (taking) begin
        kbd_strobe   <= 1'b1;
        kbd_code     <= queue[head];
        last_sent    <= queue[head];
        ever_sent    <= 1'b1;
        sent_pending <= 1'b1;
        head         <= (head == PTRW'(DEPTH - 1)) ? '0 : head + PTRW'(1);
      end

      // --- what Linux writes
      if (wr) begin
        unique case (w_word)
          10'd2: begin
            if (room) begin
              queue[tail] <= wr_data[23:0] & wr_mask[23:0];
              tail        <= (tail == PTRW'(DEPTH - 1)) ? '0 : tail + PTRW'(1);
            end else if (lost != 32'hFFFF_FFFF) begin
              lost <= lost + 32'd1;
            end
          end
          // Saturating, because a mouse the machine has stopped reading
          // would otherwise wrap what is owed and send it the other way.
          10'd3: begin
            owed_x <= sat12(13'(owed_x) + 13'(signed'(wr_data[11:0] & wr_mask[11:0])));
            owed_y <= sat12(13'(owed_y) + 13'(signed'(wr_data[23:12] & wr_mask[23:12])));
          end
          10'd4: sw <= (sw & ~wr_mask[2:0]) | (wr_data[2:0] & wr_mask[2:0]);
          default: ;
        endcase
      end

      // --- the count, written ONCE from both sides.  A put and a take can
      // land on the same tick, and two statements would have the later one
      // stand and the other event go missing; written as one expression the
      // queue is right whichever pair of things happened.
      count <= count
             - (taking ? CNTW'(1) : CNTW'(0))
             + ((wr && (w_word == 10'd2) && room) ? CNTW'(1) : CNTW'(0));

      // --- `CTL`'s FLUSH, and the machine's own reset, which do the same
      // thing for the two different reasons the header gives.  Last in the
      // block, so that a flush written on the tick a key was queued wins:
      // the point of it is that nothing survives it.
      if (flush || mach_rst) begin
        head       <= '0;
        tail       <= '0;
        count      <= '0;
        owed_x     <= 12'sd0;
        owed_y     <= 12'sd0;
        sw         <= 3'd0;
        kbd_strobe <= 1'b0;
        // **AND THE PENDING FLAG, OR A MACHINE RESET KILLS THE KEYBOARD.**
        // The flag is cleared where the card's `KBD READY` is SEEN, and a
        // reset of the machine clears that flop --- so a word in flight
        // across the reset would leave the flag set with nothing left to
        // raise the bit that clears it, and every key after it would wait
        // for ever.
        sent_pending <= 1'b0;
      end
    end
  end

  // A twelve-bit two's complement sum, held at its ends.  Written as a
  // function so that the two axes are one expression and a mutation of it is
  // one hunk.
  function automatic logic signed [11:0] sat12(input logic signed [12:0] v);
    if (v > 13'sd2047) return 12'sd2047;
    else if (v < -13'sd2048) return -12'sd2048;
    else return 12'(v);
  endfunction

  // The upper byte of a write beat, the read strobe, and the four enables of
  // the card's status register reach no register here.  Read so that lint's
  // bit granularity has nothing to say --- and lint's bit granularity is what
  // catches a mutation that drops a bit, so it is worth keeping sharp.
  logic unused_i;
  assign unused_i = ^{wr_data[31:24], wr_mask[31:24], rd, csr_q[7:6], csr_q[3:0]};

endmodule

`default_nettype wire
