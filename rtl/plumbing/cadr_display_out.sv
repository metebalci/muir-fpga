// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The display output: the CADR's bitmap out of DDR and onto a raster.
//
// **NO muir REFERENCE EXISTS AND NONE COULD.**  muir's `tv::Tv`
// is a frame buffer, a mode register and a vertical flag off the sync
// program;
// it has no raster at all, and `rtl/machine/cadr_tv.sv` is held to it tick
// for tick and does not change.  What this module does --- read the bitmap
// at a monitor's rate and put pixels on a wire --- is a thing MIT's SIMPLE
// TV did with a sync program, a shift register and an analog video
// amplifier, into a monitor that no longer exists.  So this is held to a
// SPECIFICATION and to the bitmap, the way `cadr_axi_master.sv` is held to
// AXI: the raster to VESA's own figures for the mode, and every pixel to
// the word in DDR it comes from.
//
// **THIS IS NOT PART OF THE MACHINE AND MUST NOT BECOME PART OF IT.**  It
// reads the display's region of DDR and writes nothing, tells the machine
// nothing and is told nothing by it.  The CADR cannot detect its presence:
// no cycle of the machine's reaches it, `cadr_tv.sv` goes on running the
// board's own sync program and presetting its vertical flag where that
// program's `-TVMA CLR` falls, and a board built without this block is the
// same machine.  **The two frames have nothing to do with each other**: the
// machine's is the sync program's and the monitor's is the video mode's.  That is what lets the raster be asynchronous to everything ---
// see the two clocks below.
//
// ----------------------------------------------------------------------
// THE TWO CLOCK DOMAINS, AND WHY THERE ARE TWO
//
// The memory side runs on the machine's own 100 MHz, because that is the
// clock `S_AXI_HP0` and `S_AXI_HP2` already run at and the third port has
// no reason to be different.  The raster runs on the pixel clock, which is
// the monitor's rate and is a different number --- 107.8125 MHz for the mode
// below --- made by an MMCM of its own in
// `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv`.  The two are unrelated and
// nothing tries to relate them.
//
// **THE CADR'S OWN FRAME RATE IS IRRELEVANT HERE, AND THAT IS WORTH SAYING
// BECAUSE IT LOOKS LIKE IT SHOULD NOT BE.**  The display board's frame is
// 15,456,000 ns of the machine's time, which on this board's 10 ns tick
// arrives every 30.912 real ms --- 32.35 Hz, where the board scanned at
// 64.70.  The monitor here runs at 60 Hz.  Neither number constrains the
// other: MIT's TV had the processor and the raster reading one memory at
// whatever rates each ran at, and so does this.  The vertical flag the
// machine reads is `cadr_tv.sv`'s and is not this module's VSYNC.
//
// **SO THE PICTURE TEARS, AND TEARING IS THE ORIGINAL BEHAVIOR RATHER THAN
// A DEFECT.**  A line fetched while the machine is drawing shows some words
// from before a write and some from after.  On a one-bit black-and-white
// screen that is a character appearing with its top half drawn, for one
// frame of 16 ms, and it is exactly what the real machine did: the SIMPLE
// TV scanned the same 4116s the processor wrote, with no buffering and no
// interlock.  Double buffering would need a second 128 KB region, a copy
// engine and a decision about when to swap, and would show the machine's
// screen LESS faithfully.
//
// ----------------------------------------------------------------------
// HOW THE TWO DOMAINS MEET: THE LINE BUFFER
//
// Two line buffers of 24 words.  The raster reads one while the memory side
// fills the other, and they change places at the start of every raster
// line.  A line is 24 words because that is `tv::WORDS_PER_LINE`, and
// 24 words of 32 bits is 96 bytes, which is twelve beats of the 64-bit
// port.
//
// **TWELVE BEATS IS A LINE, BUT IT IS NOT ALWAYS ONE BURST, BECAUSE 96
// BYTES DOES NOT TILE 4 KB.**  AXI forbids a burst crossing a 4 KB
// boundary and 4096 is not a multiple of 96.  The two meet at 12,288 bytes,
// which is three pages and 128 lines, so exactly two lines in each 128
// begin close enough to a boundary that twelve beats run over it --- 15 of
// the picture's 963, the first at line 42.  A fetch
// is therefore one burst where it fits and two where it does not, split
// exactly at the boundary, and the line buffer is filled by a word pointer
// that runs across the whole line rather than by a beat index inside a
// burst.
//
// This was not foreseen; the check found it, on the first frame the module
// ever drew.  `tb/cadr_display_out_tb.cpp` asserts the rule on every burst
// and counts the lines that take two, so the split cannot become dead code.
//
// **EXACTLY ONE REQUEST PER RASTER LINE, ALWAYS, INCLUDING THE LINES THAT
// SHOW NOTHING.**  The raster asks for a line at the start of every one of
// the mode's 1,066 lines, clamping the number into the picture's 963 when
// it is outside, and throws the answer away for the 103 that are border or
// blanking.  It costs 103 bursts a frame --- 0.6 MB/s of the 6.1 --- and it
// buys an invariant worth much more than that: the memory side has no idea
// where the raster is, does the same thing every line, and can be checked
// against "one burst a line, at the address the line number says".  A
// fetcher that knew about the vertical blanking would have a second mode
// that only runs 103 times a frame, which is the kind of thing that is
// wrong for a year.
//
// THE HANDSHAKE IS A TOGGLE EACH WAY, and the data rides across beside it.
// The raster sets `req_line` and flips `req_tog` on the same pixel-clock
// edge; the memory side sees the flip two of ITS clock edges later at the
// earliest, by which time `req_line` has been stable for two clocks and
// will stay stable for the rest of the line --- 1,688 pixel clocks.  So the
// number is settled long before anything looks at it, and only the toggle
// needs synchronizing.  This is the standard formulation and its safety is
// the ratio between "two clocks" and "a whole line", which is a factor of
// eight hundred.
//
// Coming back, `ack_tog` is set to the value of the request the memory side
// has just finished.  `ack == req` means everything asked for has arrived.
// The raster tests that once, at the start of a line, and if the fill did
// not finish it shows that line BLACK and sets `underrun` --- which is
// sticky, because a fault that happened once and cleared is a fault that
// will be argued about.
//
// **THE BANK IS NEVER CARRIED ACROSS.**  Both sides count requests, one
// counting what it sent and one what it served, and the bank is the low bit
// of that count.  The counts step together because there is exactly one
// request per line and one fill per request, so a signal saying which bank
// is in use would be a second description of something both sides already
// know --- and two descriptions of one fact is how they come to disagree.
//
// ----------------------------------------------------------------------
// WHICH BIT IS WHICH PIXEL
//
// muir `src/tv.rs:599-602`, `Tv::pixel`: a line is 24
// consecutive words, the first line first, and within a line the pixels run
// from the LOW end of the first word --- **bit 0 of a word is the LEFTMOST
// of the 32 pixels it carries**.  The same rule is written out in
// `boards/arty-z7-20/linux/buildroot/package/cadr-terminal/src/screen_geom.h`,
// which is the program that already serves this bitmap over the network and
// has been read against a real screen.  This is the third expression of it
// and the check holds it to the words rather than to the other two.
//
// A LIT BIT SHOWS WHITE UNLESS `MODE BOW`.  That bit is `MODE<2>` of the
// display's mode register, four flops inside `rtl/machine/cadr_tv.sv`, and
// **this module cannot read it**: `cadr_tv` does not bring the mode
// register out, and adding a port to it is a change to `rtl/machine/`,
// which is held to muir.  So `BOW` is a parameter whose default is the
// fabric's own power-on state, zero --- which is also `Tv::default`
// and the mode both reference programs leave the register in for their
// whole run.  `cadr-terminal` made the identical choice for the identical
// reason and calls it `--bow`.  Wiring it properly is one output on
// `cadr_tv` and one wire, the day somebody wants the machine to be able to
// invert its own screen.
//
// **THE BORDER IS BLACK WHATEVER `BOW` SAYS.**  The picture is 768 by 963
// in a raster of 1280 by 1024, so 512 columns and 61 rows are not the
// CADR's screen at all.  They are not zero pixels of the CADR's screen
// either --- they are outside it --- so they do not follow a bit that
// decides how the CADR's zeros are shown.  Blanking is black for the same
// reason and by the specification's rather than ours.
//
// ----------------------------------------------------------------------
// THE MODE
//
// VESA DMT 1280x1024 at 60 Hz.  `docs/display-output.md` has why, with the
// measurements: it is the smallest standard mode that holds 768 by 963
// unscaled, and its 1.078 Gb/s a lane is inside the 1.2 Gb/s an OSERDESE2
// will do on this speed grade.  The figures below are VESA's.  They are
// parameters and not constants so that the check can run a small raster in
// a short simulation, and so that a board that must use another mode can.

`default_nettype none

module cadr_display_out #(
    // Where the bitmap is: `cadr_ddr_map::DISPLAY_BASE`, passed in rather
    // than imported so that the check can put it somewhere else.
    parameter logic [31:0] BASE = 32'h1C00_0000,

    // VESA DMT 1280x1024 @ 60 Hz, 108 MHz.  Active, front porch, sync, back
    // porch, in that order, which is the order the raster walks them.
    parameter int unsigned H_ACTIVE = 1280,
    parameter int unsigned H_FRONT  = 48,
    parameter int unsigned H_SYNC   = 112,
    parameter int unsigned H_BACK   = 248,
    parameter int unsigned V_ACTIVE = 1024,
    parameter int unsigned V_FRONT  = 1,
    parameter int unsigned V_SYNC   = 3,
    parameter int unsigned V_BACK   = 38,
    // DMT gives this mode positive sync on both.  A monitor reads the pair
    // as part of how it identifies the mode, so they are not free.
    parameter bit          HSYNC_POS = 1'b1,
    parameter bit          VSYNC_POS = 1'b1,

    // The CADR's screen: muir's `WIDTH`, `HEIGHT` and `WORDS_PER_LINE`.
    parameter int unsigned PIC_W = 768,
    parameter int unsigned PIC_H = 963,
    parameter int unsigned WORDS_PER_LINE = 24,

    // `MODE BOW`: see the header.
    parameter bit          BOW = 1'b0
) (
    // ------------------------------------------------ the memory domain
    input  var logic        clk,
    input  var logic        rst,

    // `S_AXI_HP3`, read only.  This module never writes memory, so the
    // write channels are not here at all rather than tied off somewhere a
    // reader has to go and check.
    output var logic [31:0] m_araddr,
    output var logic [3:0]  m_arlen,
    output var logic [1:0]  m_arsize,
    output var logic [1:0]  m_arburst,
    output var logic        m_arvalid,
    input  var logic        m_arready,
    input  var logic [63:0] m_rdata,
    input  var logic [1:0]  m_rresp,
    input  var logic        m_rlast,
    input  var logic        m_rvalid,
    output var logic        m_rready,

    // ------------------------------------------------- the pixel domain
    input  var logic        pclk,
    input  var logic        prst,

    output var logic        de,
    output var logic        hsync,
    output var logic        vsync,
    // One bit, because the CADR's screen is one bit.  The transmitter
    // expands it to the three eight-bit channels a monitor takes.
    output var logic        white,

    // A line the raster reached before its words did, and a read the port
    // answered with an error.  Both sticky, in the pixel and memory domains
    // respectively; neither is on the machine's path and neither stops
    // anything.  They exist so that a wrong picture can be told from a
    // picture that never arrived.
    output var logic        underrun,
    output var logic        rd_error
);

  localparam int unsigned H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
  localparam int unsigned V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;

  // The picture, centered.  An odd margin loses its half pixel at the
  // bottom and the right, which is where a reader expects it.
  localparam int unsigned PIC_X0 = (H_ACTIVE - PIC_W) / 2;
  localparam int unsigned PIC_Y0 = (V_ACTIVE - PIC_H) / 2;

  localparam int unsigned BEATS = WORDS_PER_LINE / 2;   // 64 bits a beat
  localparam int unsigned LINE_BYTES = WORDS_PER_LINE * 4;

  localparam int unsigned BEAT_W = $clog2(BEATS);
  localparam int unsigned HC_W   = $clog2(H_TOTAL);
  localparam int unsigned VC_W   = $clog2(V_TOTAL);
  localparam int unsigned LINE_W = $clog2(PIC_H);
  localparam int unsigned WI_W   = $clog2(WORDS_PER_LINE);

  // ====================================================================
  // The line buffers.  Written a beat at a time on `clk`, read a word at a
  // time on `pclk`, so the read is asynchronous and this infers distributed
  // RAM --- 48 words of 32 bits, which is a handful of LUTs.  A block RAM
  // would do as well and the fitter may choose one; nothing here cares.
  // ====================================================================
  // **THE INDEX IS A CONCATENATION, SO THE BANK STRIDE IS A POWER OF TWO
  // AND NOT `WORDS_PER_LINE`.**  `{bank, word}` with a five-bit word is a
  // stride of 32, so the array is 64 entries and 24 of each 32 are used.
  // Sizing it at 2 x 24 and indexing it by the same concatenation puts
  // bank one's last eight words at indices 48 to 55, off the end of the
  // array --- which is what happened, and what the check caught as the
  // right-hand third of every other line coming out black.  The eight
  // wasted words are a few LUTs; a multiply by 24 to pack them is not.
  localparam int unsigned WORD_SLOTS = 1 << WI_W;
  logic [31:0] lbuf [2*WORD_SLOTS];

  // ====================================================================
  // THE MEMORY SIDE
  // ====================================================================

  logic [2:0] req_sync;        // the raster's toggle, brought over
  logic       req_seen;        // the last toggle value acted on
  logic       ack_tog;         // what has been finished
  logic       fill_n;          // the low bit of the number of fills done

  typedef enum logic [1:0] { F_IDLE, F_ADDR, F_AWAIT, F_DATA } fetch_e;
  fetch_e fstate;

  // Where the next beat goes and where it comes from.  The pointer runs
  // across the whole line, so a burst split at a 4 KB boundary resumes
  // where it left off rather than starting the line again.
  logic [BEAT_W-1:0] wptr;
  logic [31:0]       cur;

  // The raster's request, as this side sees it.
  logic [LINE_W-1:0] req_line;
  logic              req_tog;

  always_ff @(posedge clk) begin
    if (rst) begin
      req_sync  <= '0;
      req_seen  <= 1'b0;
      // Different from the raster's `req_tog`, which resets to zero: see
      // the note at that reset.  Nothing has been fetched, and this is how
      // the raster is told so.
      ack_tog   <= 1'b1;
      fill_n    <= 1'b0;
      fstate    <= F_IDLE;
      m_arvalid <= 1'b0;
      m_araddr  <= '0;
      m_arlen   <= '0;
      wptr      <= '0;
      cur       <= '0;
      rd_error  <= 1'b0;
    end else begin
      req_sync <= {req_sync[1:0], req_tog};

      unique case (fstate)
        F_IDLE: begin
          // A request is outstanding whenever the synchronized toggle has
          // moved away from the one last acted on.  Looked at only here,
          // so a request arriving mid-burst waits rather than being lost:
          // the toggle is still different when this comes back round.
          if (req_sync[2] != req_seen) begin
            req_seen <= req_sync[2];
            // `req_line` has been stable since two clocks before the
            // toggle arrived; see the header.
            cur      <= BASE + 32'(req_line) * 32'(LINE_BYTES);
            wptr     <= '0;
            fstate   <= F_ADDR;
          end
        end

        F_ADDR: begin
          m_araddr  <= cur;
          m_arlen   <= blen - 4'd1;
          m_arvalid <= 1'b1;
          fstate    <= F_AWAIT;
        end

        F_AWAIT: begin
          if (m_arready) begin
            m_arvalid <= 1'b0;
            fstate    <= F_DATA;
          end
        end

        F_DATA: begin
          if (m_rvalid) begin
            // SLVERR or DECERR: recorded and the beat taken anyway, because
            // a master that stops taking beats hangs the port.
            if (m_rresp != 2'b00) rd_error <= 1'b1;
            cur <= cur + 32'd8;
            if (m_rlast && (wptr == BEAT_W'(BEATS - 1))) begin
              // The line is complete: hand the raster the toggle it sent,
              // and step the bank.
              ack_tog <= req_seen;
              fill_n  <= ~fill_n;
              fstate  <= F_IDLE;
            end else begin
              wptr <= wptr + 1'b1;
              // A burst that ended before the line did was stopped by a
              // 4 KB boundary; ask again from where it stopped.
              fstate <= m_rlast ? F_ADDR : F_DATA;
            end
          end
        end

        default: fstate <= F_IDLE;
      endcase
    end
  end

  // The two words of a beat, low half first: AXI puts word 2k in the low
  // half and 2k+1 in the high half, which is the same convention
  // `cadr_axi_widen.sv` and the pack side use.
  always_ff @(posedge clk) begin
    if ((fstate == F_DATA) && m_rvalid) begin
      lbuf[{fill_n, WI_W'({wptr, 1'b0})}] <= m_rdata[31:0];
      lbuf[{fill_n, WI_W'({wptr, 1'b1})}] <= m_rdata[63:32];
    end
  end

  // How long this burst may be: what the line still owes, or what fits
  // before the next 4 KB boundary, whichever is less.  `cur` is always
  // eight-byte aligned, so the distance to the boundary is always a whole
  // number of beats and the division is a shift.
  logic [9:0] to_bound;   // 1 .. 512 beats
  logic [4:0] owed;       // 1 .. BEATS
  logic [3:0] blen;
  assign to_bound = 10'((13'd4096 - {1'b0, cur[11:0]}) >> 3);
  assign owed     = 5'(BEATS) - {1'b0, wptr};
  assign blen     = ({5'd0, to_bound} >= {10'd0, owed}) ? 4'(owed) : to_bound[3:0];

  assign m_arsize  = 2'b11;     // 2^3 = 8 bytes
  assign m_arburst = 2'b01;     // INCR
  assign m_rready  = (fstate == F_DATA);

  // ====================================================================
  // THE PIXEL SIDE
  // ====================================================================

  logic [HC_W-1:0] hc;
  logic [VC_W-1:0] vc;
  logic [2:0]      ack_sync;
  logic            primed;
  logic            show_n;      // the bank this line is read from
  logic            line_black;  // the fill did not arrive: show nothing
  // Whether a fill has ever landed.  The first line of all is black because
  // nothing has been fetched yet, and that is not an underrun --- it is
  // what starting up looks like.  Without this the sticky bit would be set
  // on every board at power-on and would mean nothing thereafter.

  // **THE REQUEST AND THE CHANGE OF BANKS BOTH HAPPEN AT `hc == 0`, AND THE
  // ORDER MATTERS.**  At the first pixel of raster line v the raster takes
  // over the bank filled during line v-1 --- which was asked for at the
  // first pixel of line v-1 and is line v's words --- and asks for line
  // v+1 into the bank it has just finished with.  It finished with it at
  // pixel `PIC_X0 + PIC_W - 1` of line v-1, which is before this, so the
  // fill can never overwrite a word still being shown.  Doing both at the
  // END of a line instead is off by one and shows every line one late.
  //
  // The line wanted is clamped into the picture rather than skipped: see
  // the header for why one request a line is worth 103 wasted bursts.
  logic [VC_W-1:0]   next_vc;
  logic [LINE_W-1:0] next_line;
  always_comb begin
    next_vc = (vc == VC_W'(V_TOTAL - 1)) ? '0 : vc + 1'b1;
    if (next_vc < VC_W'(PIC_Y0))                 next_line = '0;
    else if (next_vc >= VC_W'(PIC_Y0 + PIC_H))   next_line = LINE_W'(PIC_H - 1);
    else                                         next_line = LINE_W'(next_vc - VC_W'(PIC_Y0));
  end

  // Where in the picture this pixel is, modulo the 32 pixels a word
  // carries --- which is all the shift register needs to know.  Five bits
  // because the difference is only ever wanted mod 32, and subtracting the
  // low five bits gives that whatever `PIC_X0` is.  Only meaningful under
  // `inpic_c`, which is what stops the wrap below `PIC_X0` mattering.
  logic [4:0] pic_x;
  assign pic_x = hc[4:0] - 5'(PIC_X0);

  // The raster's own signals, computed from the counters as they stand and
  // registered below, so that all four outputs carry the same one-cycle
  // delay and a monitor --- or the check, which behaves like one --- can
  // recover the position from the syncs alone.
  logic de_c, hs_c, vs_c, inpic_c;
  assign de_c = (hc < HC_W'(H_ACTIVE)) && (vc < VC_W'(V_ACTIVE));
  assign hs_c = (hc >= HC_W'(H_ACTIVE + H_FRONT)) &&
                (hc <  HC_W'(H_ACTIVE + H_FRONT + H_SYNC));
  assign vs_c = (vc >= VC_W'(V_ACTIVE + V_FRONT)) &&
                (vc <  VC_W'(V_ACTIVE + V_FRONT + V_SYNC));
  assign inpic_c = de_c && !line_black &&
                   (hc >= HC_W'(PIC_X0)) && (hc < HC_W'(PIC_X0 + PIC_W)) &&
                   (vc >= VC_W'(PIC_Y0)) && (vc < VC_W'(PIC_Y0 + PIC_H));

  // The word being shifted out, and which word comes next.
  logic [31:0]     shreg;
  logic [WI_W-1:0] wi;

  always_ff @(posedge pclk) begin
    if (prst) begin
      hc <= '0; vc <= '0;
      req_tog <= 1'b0; req_line <= '0;
      // **A SYNCHRONIZER MUST COME OUT OF RESET HOLDING WHAT ITS SOURCE
      // COMES OUT OF RESET HOLDING.**  `ack_tog` resets to one; these
      // resetting to zero would make the first line's readiness test true
      // for the two or three clocks before the real value arrives, the
      // first line would take a bank nothing had filled, and every bank
      // after it would be one out --- so the whole picture would be shown
      // one line early, for ever.  Which is exactly what happened, and what
      // `tb/cadr_display_out_tb.cpp` caught by comparing against a memory
      // poisoned injectively in the address: line 30 came out holding line
      // 1's words.  Against a memory of zeros it would have looked perfect.
      ack_sync <= '1;
      // **THE TWO TOGGLES COME OUT OF RESET DIFFERENT, ON PURPOSE.**  Equal
      // would mean "everything asked for has arrived" before anything has
      // been asked for, and the raster would show a line out of a buffer
      // nothing had written --- one line of whatever the RAM powered up
      // holding, once, at the top of the first frame.  Different means the
      // first line is black and the second is the first fill.
      req_tog <= 1'b0;
      show_n <= 1'b1;
      line_black <= 1'b1;    // until a fill has landed, show nothing
      primed <= 1'b0;
      underrun <= 1'b0;
      shreg <= '0; wi <= '0;
      de <= 1'b0; hsync <= !HSYNC_POS; vsync <= !VSYNC_POS; white <= 1'b0;
    end else begin
      ack_sync <= {ack_sync[1:0], ack_tog};

      // ---- the counters
      if (hc == HC_W'(H_TOTAL - 1)) begin
        hc <= '0;
        vc <= (vc == VC_W'(V_TOTAL - 1)) ? '0 : vc + 1'b1;
      end else begin
        hc <= hc + 1'b1;
      end

      // ---- the first pixel of a line: change banks, then ask for the next
      if (hc == '0) begin
        // Everything asked for so far has arrived?  Tested BEFORE the new
        // request goes out, so it is about the fill this line needs.
        if (ack_sync[2] == req_tog) begin
          show_n     <= ~show_n;
          line_black <= 1'b0;
          primed     <= 1'b1;
        end else begin
          line_black <= 1'b1;
          if (primed) underrun <= 1'b1;
        end
        req_line <= next_line;
        req_tog  <= ~req_tog;
      end

      // ---- the shift register
      if (hc == HC_W'(PIC_X0 - 1)) begin
        // Primed one pixel before the picture starts, so that `shreg[0]` is
        // the leftmost pixel at the pixel it belongs to.
        shreg <= lbuf[{show_n, {WI_W{1'b0}}}];
        wi    <= WI_W'(1);
      end else if (inpic_c && (pic_x == 5'd31)) begin
        shreg <= lbuf[{show_n, wi}];
        wi    <= wi + 1'b1;
      end else begin
        shreg <= {1'b0, shreg[31:1]};
      end

      // ---- the outputs
      de    <= de_c;
      hsync <= HSYNC_POS ? hs_c : !hs_c;
      vsync <= VSYNC_POS ? vs_c : !vs_c;
      // Blanking is black by the specification.  The border is black
      // because it is not the CADR's screen --- see the header --- so it
      // does not follow `BOW`.
      white <= inpic_c ? (shreg[0] ^ BOW) : 1'b0;
    end
  end

endmodule

`default_nettype wire
