// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack side of the disk: the block's address, written by Linux over
// `M_AXI_GP0`, and the master on `S_AXI_HP2` that moves the block between
// DDR and the controller's block store.
//
// **WHAT THE PACK IS HERE.**  muir's `Unit` is a file and two tables beside
// it: `file_block` reads 1,024 bytes a block out of the image, and `headers`
// and `data_checkwords` hold the sectors a Write All laid down with something
// other than the format's own header and checkwords.  On the board the file
// is in DDR, put there by Linux, and Linux is the drive: it decides which
// block goes in which slot of the store, hands this module the block's
// address, and takes a written block back.  So the seam between the drive
// and the controller is exactly the one `tb/cadr_disk_tb.cpp` drove from
// the trace's `BLK` rows --- 259 words a slot and a tag --- with this module
// on the drive's side of it instead of a testbench.
//
// **THE RECORD IS THE 259 WORDS, AT THE BLOCK'S ADDRESS.**  Word i is at
// address + 4i, low byte first, as `Unit::file_block` reads a block and as
// AXI lays a 64-bit beat out: word 2k in the low half of the beat at
// address + 8k and word 2k+1 in the high half.  The 256 data words come
// first, so the block's address IS the block --- the pack file's own 1,024
// bytes, unchanged --- and the header, the header checkword and the data
// checkword follow at +1024, +1028 and +1032.  They are muir's two tables,
// carried beside the block rather than computed from it: a fabric that
// recomputed them from the address could never disagree with itself, which
// is issue 51's whole point, and the reference trace lays sectors whose
// checkwords do not check.  Linux computes them for a block nothing laid
// (`header_of`, `Ecc::over`, the code over the data) and keeps what a
// write-back hands it.  The word at +1036 is never written: the last beat
// goes out with its low half strobed and its high half not.
//
// **NINE BURSTS: EIGHT OF SIXTEEN BEATS AND ONE OF TWO.**  The PS7's AFI
// ports are AXI3, whose burst caps at sixteen beats, and a 1,024-byte block
// is 128 beats of eight bytes.  The three words after it are two beats.
// **The block's address must be 128-byte aligned**, so that a burst of 128
// bytes never crosses a 4 KB boundary --- AXI forbids one that does, and a
// master that let Linux pick any address would be right on every address
// but the ones where it silently was not.  An unaligned address is REFUSED
// and says so; nothing is masked off.
//
// **THE TAG IS WRITTEN LAST, AND THE SLOT IS TAKEN AWAY FIRST.**  A slot is
// valid only while its tag says which block it holds, and a fetch into a
// slot the store already holds a block in would otherwise leave a valid tag
// over words half from the old block and half from the new for the ~300
// ticks the fill takes --- and the CADR can START a transfer at any tick of
// them.  So a fetch begins by taking the slot's block away (the tag write
// with bit 31 set, which `cadr_disk_controller.sv` reads as "invalid") and
// ends by writing the tag, and a walk that reaches the slot in between misses
// it, which is what the controller already does for a block it does not
// hold.  `tb/cadr_disk_pack_tb.cpp` STARTs a transfer during a fill and
// requires the miss.
//
// **AND THE CHANNEL'S INTERLOCK IS HONOURED, BOTH WAYS.**  `ch_active` is
// the controller's own BUSY for a transfer: while it is up the channel owns
// the slot it is walking and this module must neither fill one nor write one
// back, so a request that arrives then is refused --- not queued, because a
// request queued behind a walk would land at a moment Linux did not choose.
// Linux reads `ch_active` in the status word and asks again.  It is read
// through a register here, for the fitter --- the controller's state reaching
// this module's state enables was -0.530 ns on the DDR=1 board --- and a
// register is a tick behind, so the controller announces a START two ticks
// ahead and, for the tick that still leaves, defers its walk while `moving`
// says a block is in flight.  Neither side alone closes the window; both do.
//
// **WHAT LINUX WRITES AND READS**, sixteen words at `REG_BASE`, which is the
// bottom of `M_AXI_GP0`'s window in the PS address map:
//
//   0  ADDR    the block's address in DDR; bits 6:0 must be zero
//   1  TAG     {cylinder<11:0>, head<7:0>, block<7:0>}, bits 27:0 --- the
//              disk address the block answers to, and what the walk looks a
//              slot up by
//   2  SLOT    which of the store's slots, bits 4:0, below SLOTS
//   3  CTL     written: bit 0 fetch the record at ADDR into SLOT and tag it
//                       bit 1 write SLOT back to the record at ADDR
//                       bit 2 take SLOT's block away (no DDR traffic)
//                       exactly one of the three, or the write is refused
//              read:    bit 0 busy        a move is in progress
//                       bit 1 done        the last request finished
//                       bit 2 error       it met SLVERR or DECERR, or a
//                                         burst that did not end where it
//                                         should
//                       bit 3 refused     the last CTL write was refused:
//                                         busy, the channel active, an
//                                         address not aligned, a slot past
//                                         the store, or not one bit of 2:0
//                       bit 4 ch_active   the controller is walking, live
//                       bit 5 store_miss  the walk asked the store for a
//                                         block it does not hold, sticky
//                                         until the controller's reset
//   4  DRIVE   bits 7:0 a drive is present on that unit, 15:8 its read-only
//              switch, 16 whether the drive's own time is charged
//              (`Controller::timed`).  This is the drive seam
//              `cadr_disk_controller.sv` takes eight units of: on the board
//              a unit is present when Linux says a pack is mounted on it,
//              and it comes up with nothing on any cable
//   7  IDENT   reads `IDENT`, a constant, so that the first read over GP0
//              can tell the registers from a bus that answers zeros
//
// Every other word reads zero and ignores writes.  An access outside the
// sixteen is answered SLVERR: Linux writing past the end of these registers
// is a bug in Linux and gets a bus error rather than a silent nothing.
//
// **THE GP0 FACE IS A SLAVE TO A 32-BIT AXI3 MASTER, AND IT IS SMALL ON
// PURPOSE.**  A register access from the CPU is a single beat on an
// uncached mapping; this accepts a burst of any length and walks the
// address up a word a beat so that it is never surprised, honours the byte
// strobes so a `writeb` does what it says, and answers reads a beat at a
// time with RLAST on the last.  One write and one read may be in flight at
// once, because the two halves of AXI are independent and the CPU's
// interconnect will do that.  IDs are echoed as AXI3 requires.
//
// NO muir REFERENCE EXISTS FOR ANY OF THIS, as none exists for
// `cadr_axi_master.sv`: nothing in MIT's drawings is an AXI master and
// `Unit::read_block` is a memcpy.  It is held to the protocol --- exactly one
// handshake per channel per burst, payload stable under valid, WLAST and
// RLAST where the length says --- and to read-back through the controller
// itself: a block fetched here and moved into main memory by the CADR's own
// transfer must be the record's words, and a block the CADR wrote and this
// wrote back must be the page's.  `tb/cadr_disk_pack_tb.cpp` holds both, and
// `tb/cadr_disk_tb.cpp` holds the whole reference trace with the store
// reachable only this way.

`default_nettype none

module cadr_disk_pack #(
    // How many slots the store has; a SLOT past this is refused.  Must
    // match `cadr_disk_controller`'s.
    parameter int unsigned SLOTS = 24,
    // Where the sixteen registers sit.  0x4000_0000 is the first address
    // `M_AXI_GP0` decodes to the fabric in the Zynq-7000 PS address map.
    parameter logic [31:0] REG_BASE = 32'h4000_0000,
    // "PACK", so that a read of register 7 can be told from a bus of zeros.
    parameter logic [31:0] IDENT = 32'h5041_434B
) (
    input  var logic        clk,
    input  var logic        rst,

    // --- M_AXI_GP0: the PS is the master, 32 bits, AXI3 ------------------
    input  var logic [31:0] s_awaddr,
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
    input  var logic [31:0] s_araddr,
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

    // --- S_AXI_HP2: this is the master, 64 bits, AXI3 --------------------
    output var logic [31:0] m_awaddr,
    output var logic [3:0]  m_awlen,
    output var logic [1:0]  m_awsize,
    output var logic [1:0]  m_awburst,
    output var logic        m_awvalid,
    input  var logic        m_awready,
    output var logic [63:0] m_wdata,
    output var logic [7:0]  m_wstrb,
    output var logic        m_wlast,
    output var logic        m_wvalid,
    input  var logic        m_wready,
    input  var logic [1:0]  m_bresp,
    input  var logic        m_bvalid,
    output var logic        m_bready,
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

    // --- the block store's seam, as `cadr_disk_controller` has it ---------
    output var logic        store_we,
    output var logic [4:0]  store_slot,
    output var logic [8:0]  store_addr,
    output var logic [31:0] store_wdata,
    input  var logic [31:0] store_rdata,   // two ticks behind the address this drives: see the seam below
    input  var logic        store_miss,
    input  var logic        ch_active,
    // A block is in flight through the seam: the controller defers a walk on
    // it.  `busy` by another name, so that the seam says what it means.
    output var logic        moving,

    // --- the drive seam, eight units of it --------------------------------
    output var logic [7:0]  drive_present,
    output var logic [7:0]  drive_read_only,
    output var logic        drive_timed
);

  // The record: 256 data words --- eight bursts of sixteen beats --- then
  // the header, its checkword and the data's, which are beats 128 and 129 of
  // the record, at +1024.
  localparam int unsigned DATA_BURSTS = 8;            // of 16 beats
  localparam logic [3:0]  LEN_DATA    = 4'd15;        // sixteen beats
  localparam logic [3:0]  LEN_META    = 4'd1;         // two
  localparam logic [1:0]  SIZE_BEAT   = 2'b11;        // 2^3 = 8 bytes
  localparam logic [1:0]  BURST_INCR  = 2'b01;
  localparam logic [31:0] META_OFFSET = 32'd1024;

  // The store's places past the block, as the controller's seam numbers
  // them: 256 the header, 257 its checkword, 258 the data's, 259 the tag.
  localparam logic [8:0] ST_HEADER = 9'd256;
  localparam logic [8:0] ST_TAG    = 9'd259;

  // ------------------------------------------------------------------------
  // The registers
  // ------------------------------------------------------------------------
  logic [31:0] r_addr;
  logic [27:0] r_tag;
  logic [4:0]  r_slot;
  logic [24:0] r_drive;   // 7:0 present, 15:8 read-only, 16 timed
  logic        busy, done, error, refused;
  // **THE SEAM IS DRIVEN FROM REGISTERS, AND `moving` COVERS THE LAST WRITE.**
  // The four store lines used to be decoded straight off the state --- which
  // slot, which word, the tag or a beat --- and land on the enable of every
  // tag and header register in the controller: `FSM_onehot_pst_reg/C ->
  // u_machine/disk/s_tag_reg[*]/CE`, 49 of the DDR=1 board's 128 failing
  // endpoints at ef9dee9, three quarters of each path spent crossing from
  // this module to that one.  Registered here, the crossing starts at a
  // register and the controller's own decode is all that is left in the
  // tick.  It costs one tick on every write into the store, and the tick
  // matters exactly once: the tag, written last, lands the tick after
  // `busy` falls, so `moving` stays up for it --- a walk deferring on
  // `store_busy` must not find the slot half-tagged.  The read side pays
  // the same tick going out and one more coming back, which is why the
  // write-back below is six ticks a beat and not four.
  assign moving = busy || store_we;
  // The controller's interlock, a tick behind: see the header.
  logic        ch_active_q;
  // What the state decodes for the seam this tick, registered onto it at the
  // edge.  `seam` is the controller's word for its side of the same port.
  logic        seam_we;
  logic [4:0]  seam_slot;
  logic [8:0]  seam_addr;
  logic [31:0] seam_wdata;

  assign drive_present   = r_drive[7:0];
  assign drive_read_only = r_drive[15:8];
  assign drive_timed     = r_drive[16];

  // What a CTL write asks for, decoded from the strobed low byte.
  logic        go_fetch, go_write, go_take;
  logic        go_any, go_one;

  // ------------------------------------------------------------------------
  // The GP0 slave: a write channel and a read channel, independent
  // ------------------------------------------------------------------------
  typedef enum logic [1:0] { W_ADDR, W_DATA, W_RESP } wstate_e;
  // A read has a tick between the address and the first beat, and between
  // beats, in which the word and the response are made into registers: see
  // `R_PREP` below.
  typedef enum logic [1:0] { R_ADDR, R_PREP, R_PREP2, R_DATA } rstate_e;
  wstate_e wst;
  rstate_e rst_r;

  logic [31:0] w_at, r_at;         // the beat's address, walked up a word a beat
  logic [11:0] w_id, r_id;
  logic [3:0]  r_left;             // beats still owed on the read
  logic        w_bad;              // a beat outside the window: SLVERR

  // Whether the beat's address is one of the sixteen words.
  //
  // **THE WRITE SIDE'S IS A REGISTER, COMPARED A TICK EARLY.**  It is a
  // 26-bit compare against the window, and made where the beat lands it
  // reached the clock enable of every register a beat can write:
  // `w_at_reg[25]/C -> r_drive_reg[*]/CE`, seven logic levels and 4.98 ns on
  // the DDR=1 board at ef9dee9, 72% of it routing.  `w_at` changes at two
  // places only --- taken from AWADDR, and walked up a word a beat --- so the
  // compare is made on the value about to be loaded and lands beside it, and
  // the enable reads one register bit.  This is `cadr_phase_gen.sv`'s trick
  // for its taps: the same question a tick early, the answer on the same
  // tick.  The read side's stays a gate, because what reads it is `R_PREP`'s
  // register and nothing else.
  logic w_in, r_in;
  logic [3:0] w_idx, r_idx;
  function automatic logic in_window(input logic [31:6] page);
    return page == REG_BASE[31:6];
  endfunction
  logic [31:0] w_next;             // the beat after this one
  assign w_next = w_at + 32'd4;
  assign r_in  = (r_at[31:6] == REG_BASE[31:6]);
  assign w_idx = w_at[5:2];
  assign r_idx = r_at[5:2];

  assign s_awready = (wst == W_ADDR);
  assign s_wready  = (wst == W_DATA);
  assign s_bvalid  = (wst == W_RESP);
  assign s_bresp   = w_bad ? 2'b10 : 2'b00;
  assign s_bid     = w_id;

  // **THE WORD AND THE RESPONSE ARE REGISTERS, MADE THE TICK BEFORE RVALID.**
  // Driven straight off `r_at` --- the window compare, then which of the
  // sixteen, then the mux --- they reached the PS7's own RDATA pins four
  // logic levels late: `r_at_reg[8]/C -> u_ps7/MAXIGP0RDATA[14]`, -0.164 ns
  // on the DDR=1 board at ef9dee9, and the hard block's setup is most of the
  // tick.  So `R_PREP` makes both into registers and `R_DATA` offers them;
  // the address walks up at the handshake and the next beat goes through
  // `R_PREP` again.  One tick a beat, on a register read Linux makes a
  // handful of times a block.
  logic [31:0] rdata_q;
  logic [1:0]  rresp_q;
  logic        r_in_q;   // `r_in`, the tick after the address moved
  assign s_arready = (rst_r == R_ADDR);
  assign s_rvalid  = (rst_r == R_DATA);
  assign s_rlast   = (r_left == 4'd0);
  assign s_rresp   = rresp_q;
  assign s_rdata   = rdata_q;
  assign s_rid     = r_id;

  // The word a read returns.  CTL's read face is the six status bits.
  logic [31:0] ctl_word, r_word;
  assign ctl_word = {26'd0, store_miss, ch_active, refused, error, done, busy};
  always_comb begin
    if (!r_in_q) r_word = 32'd0;
    else begin
      unique case (r_idx)
        4'd0:    r_word = r_addr;
        4'd1:    r_word = {4'd0, r_tag};
        4'd2:    r_word = {27'd0, r_slot};
        4'd3:    r_word = ctl_word;
        4'd4:    r_word = {7'd0, r_drive};
        4'd7:    r_word = IDENT;
        default: r_word = 32'd0;
      endcase
    end
  end

  // A write beat lands this tick.
  logic w_beat;
  assign w_beat = s_wvalid && s_wready;

  // The byte lanes a beat carries, merged into the register's current value.
  function automatic logic [31:0] merge(input logic [31:0] old,
                                        input logic [31:0] d,
                                        input logic [3:0] strb);
    logic [31:0] r;
    for (int k = 0; k < 4; k++) r[8*k +: 8] = strb[k] ? d[8*k +: 8] : old[8*k +: 8];
    return r;
  endfunction

  // Only the low three bits of CTL mean anything; the rest of the strobed
  // word is taken so that a `writeb` to it is the same write as a `writel`.
  //
  // **THE REQUEST IS HELD ONE TICK.**  Acted on in the tick the beat lands,
  // the go was a function of the beat's address --- a 26-bit compare against
  // the window, then which word, then the strobed bits --- reaching the
  // enables of everything a move latches: seven logic levels and 6.1 ns on
  // the DDR=1 board.  Registered here, the next tick's decision starts at
  // `go_q` and the registers, and is two levels deep.  Linux reads the
  // outcome tens of ticks later at the soonest.
  logic [2:0] ctl_new, go_q;
  assign ctl_new  = 3'(merge(32'd0, s_wdata, s_wstrb));
  assign go_fetch = go_q[0];
  assign go_write = go_q[1];
  assign go_take  = go_q[2];
  assign go_any   = go_fetch || go_write || go_take;
  assign go_one   = (go_q == 3'b001) || (go_q == 3'b010) || (go_q == 3'b100);

  // What refuses a request.  Written out one term to a name so that a
  // refusal can be read back to its cause in the testbench's failure line.
  // The two that look at a register Linux wrote are registers themselves,
  // made the tick after the write: ADDR and SLOT are earlier beats than the
  // CTL that acts on them, and `go_q` is a tick behind that beat, so they
  // are current when they are read.  Off `r_addr` directly the alignment
  // test was in front of the address register's enable.
  logic bad_align, bad_slot, bad_busy, bad_ch;
  logic bad_align_q, bad_slot_q;
  always_ff @(posedge clk) begin
    bad_align_q <= (r_addr[6:0] != 7'd0);
    bad_slot_q  <= (32'(r_slot) >= SLOTS);
  end
  assign bad_align = bad_align_q && !go_take;
  assign bad_slot  = bad_slot_q;
  assign bad_busy  = busy;
  assign bad_ch    = ch_active_q;
  logic refuse;
  assign refuse = go_any && (!go_one || bad_align || bad_slot || bad_busy || bad_ch);

  always_ff @(posedge clk) begin
    if (rst) begin
      wst   <= W_ADDR;
      rst_r <= R_ADDR;
      w_at  <= 32'd0;
      r_at  <= 32'd0;
      w_id  <= 12'd0;
      r_id  <= 12'd0;
      r_left <= 4'd0;
      w_bad <= 1'b0;
      r_addr  <= 32'd0;
      r_tag   <= 28'd0;
      r_slot  <= 5'd0;
      r_drive <= 25'd0;
      refused <= 1'b0;
      go_q    <= 3'd0;
      ch_active_q <= 1'b0;
      w_in    <= 1'b0;
      rdata_q <= 32'd0;
      rresp_q <= 2'b00;
      r_in_q  <= 1'b0;
    end else begin
      ch_active_q <= ch_active;
      // The request, held: what a CTL write asked for, a tick after the beat.
      go_q <= (w_beat && w_in && (w_idx == 4'd3)) ? ctl_new : 3'd0;
      if (go_any) refused <= refuse;
      // --- writes
      unique case (wst)
        W_ADDR: if (s_awvalid) begin
          w_at  <= s_awaddr;
          w_in  <= in_window(s_awaddr[31:6]);
          w_id  <= s_awid;
          w_bad <= 1'b0;
          wst   <= W_DATA;
        end
        W_DATA: if (w_beat) begin
          if (!w_in) w_bad <= 1'b1;
          else begin
            unique case (w_idx)
              4'd0: r_addr  <= merge(r_addr, s_wdata, s_wstrb);
              4'd1: r_tag   <= 28'(merge({4'd0, r_tag}, s_wdata, s_wstrb));
              4'd2: r_slot  <= 5'(merge({27'd0, r_slot}, s_wdata, s_wstrb));
              4'd3: ;   // acted on next tick, from `go_q`
              4'd4: r_drive <= 25'(merge({7'd0, r_drive}, s_wdata, s_wstrb));
              default: ;
            endcase
          end
          w_at <= w_next;
          w_in <= in_window(w_next[31:6]);
          if (s_wlast) wst <= W_RESP;
        end
        W_RESP: if (s_bready) wst <= W_ADDR;
        default: wst <= W_ADDR;
      endcase

      // --- reads
      unique case (rst_r)
        R_ADDR: if (s_arvalid) begin
          r_at   <= s_araddr;
          r_id   <= s_arid;
          r_left <= s_arlen;
          rst_r  <= R_PREP;
        end
        // The window compare into a register, then the word and the response
        // for the beat `r_at` names into theirs; RVALID follows.  Two ticks,
        // because the compare and the sixteen-way mux together were seven
        // levels into the word.
        R_PREP: begin
          r_in_q <= r_in;
          rst_r  <= R_PREP2;
        end
        R_PREP2: begin
          rdata_q <= r_word;
          rresp_q <= r_in_q ? 2'b00 : 2'b10;
          rst_r   <= R_DATA;
        end
        R_DATA: if (s_rready) begin
          r_at <= r_at + 32'd4;
          if (r_left == 4'd0) rst_r <= R_ADDR;
          else begin
            r_left <= r_left - 4'd1;
            rst_r  <= R_PREP;
          end
        end
        default: rst_r <= R_ADDR;
      endcase
    end
  end

  // The AXI3 length and the write ID are not read here: a register access is
  // walked a beat at a time until WLAST says it is over, and one write is in
  // flight at a time so the response's ID is the address's.
  logic unused_s;
  assign unused_s = ^{s_awlen};

  // ------------------------------------------------------------------------
  // The HP2 master: the block between DDR and the store
  // ------------------------------------------------------------------------
  //
  // One burst in flight at a time, the address channel first and the
  // response waited for before the next, which is `cadr_axi_master.sv`'s
  // shape one burst wide.  A block is nine bursts and ~300 ticks either way;
  // a drive's sector is 968 us, so nothing here is the constraint.
  typedef enum logic [3:0] {
    P_IDLE,
    P_TAKE,     // the slot's block taken away, one tick
    P_AR,       // a read burst's address
    P_R,        // its beats, two words each into the store
    P_TAG,      // the tag, last
    P_AW,       // a write burst's address
    P_W0,       // ask the store for the beat's low word
    P_W1,       // ... and its high word
    P_W2,       // the seam's tick out and the store's tick back
    P_W3,       // the low word arriving
    P_W4,       // the high one arriving
    P_W5,       // both in registers: the beat stands until taken
    P_B         // the burst's response
  } pstate_e;
  pstate_e pst;

  logic        p_write;            // the move in progress is a write-back
  logic [3:0]  p_burst;            // 0..8
  logic [3:0]  p_beat;             // within the burst
  logic [31:0] p_base;             // the block's address, latched at the go
  logic [4:0]  p_slot;
  logic [27:0] p_tag;
  // **A READ BEAT IS REGISTERED BEFORE IT REACHES THE STORE.**  RVALID and
  // RDATA leave the PS7 late in the tick --- the hard block's own output
  // delay is most of the 5 ns --- and written straight into the store they
  // reached the enable of every slot's tag and header in the controller:
  // -0.513 ns on the DDR=1 board, the ten worst paths all from
  // `SAXIHP2ACLK`.  So a beat is taken into `rb_*` and stored from there the
  // tick after, as `cadr_axi_master` registers `m_axi_rdata` before the
  // bridge sees it.  Two ticks a beat still: the low word is stored the tick
  // after the beat is taken, the high word the tick after that, and the next
  // beat is taken in that same tick.
  logic        rb_valid;           // a beat taken last tick, its low word to store now
  logic [63:0] rb_data;
  logic        hi_pending;         // a read beat's high word still to store
  logic [31:0] hi_word;
  // A write beat's two words, from the store, each in a register before the
  // beat is offered: the store's read is the block RAM's own output and a
  // mux, 2.6 ns of the tick before any routing, and offered to the PS7's
  // WDATA pin straight from it the high word was -0.505 ns on the DDR=1
  // board.
  logic [31:0] wlo, whi;

  logic meta;                      // this burst is the two-beat one
  assign meta = (p_burst == 4'(DATA_BURSTS));

  // Where the burst is in DDR, and which word of the record its beat is.
  //
  // **THE ADDRESS IS A REGISTER, MADE WHERE `p_burst` MOVES.**  As an adder
  // off `p_burst` and `p_base` it reached the PS7's address pins a tick short
  // --- `p_burst_reg[*]/C -> u_ps7/SAXIHP2A[RW]ADDR[*]`, -0.013 ns on the
  // DDR=1 board at ef9dee9, the hard block's setup being most of the tick.
  // `p_burst` changes at four places, each of which knows the next value, so
  // the sum is made there and the address channel offers a register.
  logic [31:0] burst_addr;
  function automatic logic [31:0] addr_of(input logic [31:0] base,
                                          input logic [3:0] burst);
    return (burst == 4'(DATA_BURSTS)) ? base + META_OFFSET
                                      : base + {21'd0, burst[2:0], 7'd0};   // + 128 * burst
  endfunction
  // The record's word index of the beat's low half: 2 * (16 * burst + beat)
  // for the data, 256 + 2 * beat for the rest --- which is the store's own
  // numbering of those places.
  logic [8:0] word_lo;
  assign word_lo = meta ? ST_HEADER + {7'd0, p_beat[0], 1'b0}
                        : {1'b0, p_burst[2:0], p_beat[3:0], 1'b0};

  // The last beat of the burst, and of the whole block.
  logic last_beat, last_burst;
  assign last_beat  = meta ? (p_beat == 4'd1) : (p_beat == 4'd15);
  assign last_burst = meta;

  // --- the read side
  assign m_araddr  = burst_addr;
  assign m_arlen   = meta ? LEN_META : LEN_DATA;
  assign m_arsize  = SIZE_BEAT;
  assign m_arburst = BURST_INCR;
  assign m_arvalid = (pst == P_AR);
  // A beat is taken whenever the register that holds one is free: while the
  // last beat's high word is going into the store, the next beat can arrive.
  assign m_rready  = (pst == P_R) && !rb_valid;

  // --- the write side
  assign m_awaddr  = burst_addr;
  assign m_awlen   = meta ? LEN_META : LEN_DATA;
  assign m_awsize  = SIZE_BEAT;
  assign m_awburst = BURST_INCR;
  assign m_awvalid = (pst == P_AW);
  assign m_wvalid  = (pst == P_W5);
  assign m_wdata   = {whi, wlo};
  // The pad after the data checkword is never written: the record's last
  // beat goes out with only its low half strobed.
  assign m_wstrb   = (meta && p_beat[0]) ? 8'h0F : 8'hFF;
  assign m_wlast   = last_beat;
  assign m_bready  = (pst == P_B);

  // --- the seam, driven from the state through a register
  //
  // The seam is registered on the way out and the store's read is registered
  // on the way back, so an address decided here reaches the block RAM a tick
  // later and its word is back two ticks after that.  A write beat's two
  // words are therefore asked for on two ticks and arrive three ticks after
  // each: P_W0 asks for the low word, P_W1 for the high, P_W2 waits, P_W3
  // takes the low one into `wlo`, P_W4 the high one into `whi`, and P_W5
  // offers the beat from the two registers until it is taken.  Six ticks a
  // beat where it was four; a write-back is some 260 ticks longer against a
  // sector's 968 us on the pack, and `tb/cadr_disk_tb.cpp` measures what a
  // write-back costs rather than assuming it.
  logic [8:0] read_word;
  always_comb begin
    unique case (pst)
      P_W0:    read_word = word_lo;
      default: read_word = word_lo | 9'd1;
    endcase
  end

  always_comb begin
    seam_we    = 1'b0;
    seam_slot  = p_slot;
    seam_addr  = read_word;
    seam_wdata = 32'd0;
    unique case (pst)
      P_TAKE: begin
        seam_we    = 1'b1;
        seam_addr  = ST_TAG;
        seam_wdata = {1'b1, 31'd0};
      end
      P_R: begin
        if (hi_pending) begin
          seam_we    = 1'b1;
          seam_addr  = word_lo | 9'd1;
          seam_wdata = hi_word;
        end else if (rb_valid) begin
          seam_we    = 1'b1;
          seam_addr  = word_lo;
          seam_wdata = rb_data[31:0];
        end
      end
      P_TAG: begin
        seam_we    = 1'b1;
        seam_addr  = ST_TAG;
        seam_wdata = {4'd0, p_tag};
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      store_we    <= 1'b0;
      store_slot  <= 5'd0;
      store_addr  <= 9'd0;
      store_wdata <= 32'd0;
    end else begin
      store_we    <= seam_we;
      store_slot  <= seam_slot;
      store_addr  <= seam_addr;
      store_wdata <= seam_wdata;
    end
  end

  // The high word of the last meta beat is the pad and goes nowhere; the
  // store's place 259 is the tag and must not take it.  So the last beat of
  // the last burst stores one word and does not go through `hi_pending`.
  logic pad_beat;
  assign pad_beat = meta && p_beat[0];

  // The beat being TAKEN this tick is the one after `p_beat` while a high
  // word is still going in, and `p_beat` itself otherwise: what RLAST is
  // checked against.
  logic [3:0] take_idx;
  logic       take_last;
  assign take_idx  = hi_pending ? p_beat + 4'd1 : p_beat;
  assign take_last = meta ? (take_idx == 4'd1) : (take_idx == 4'd15);

  always_ff @(posedge clk) begin
    if (rst) begin
      pst        <= P_IDLE;
      p_write    <= 1'b0;
      p_burst    <= 4'd0;
      p_beat     <= 4'd0;
      p_base     <= 32'd0;
      p_slot     <= 5'd0;
      p_tag      <= 28'd0;
      hi_pending <= 1'b0;
      hi_word    <= 32'd0;
      rb_valid   <= 1'b0;
      rb_data    <= 64'd0;
      wlo        <= 32'd0;
      whi        <= 32'd0;
      busy       <= 1'b0;
      done       <= 1'b0;
      error      <= 1'b0;
      burst_addr <= 32'd0;
    end else begin
      unique case (pst)
        P_IDLE: if (go_any && !refuse) begin
          // Latched here and held for the whole move: Linux may rewrite the
          // registers the tick after the go.
          p_base  <= r_addr;
          p_slot  <= r_slot;
          p_tag   <= r_tag;
          p_burst <= 4'd0;
          burst_addr <= addr_of(r_addr, 4'd0);
          p_beat  <= 4'd0;
          busy    <= 1'b1;
          done    <= 1'b0;
          error   <= 1'b0;
          p_write <= go_write;
          hi_pending <= 1'b0;
          rb_valid   <= 1'b0;
          // A write-back leaves the slot as it is: what is in it is what the
          // pack now holds, and the tag stays good.
          pst <= go_write ? P_AW : P_TAKE;
        end
        // One tick: the slot is invalid from here until P_TAG.  A bare
        // take-away is finished by it.
        P_TAKE: begin
          if (take_only) begin
            busy <= 1'b0;
            done <= 1'b1;
            pst  <= P_IDLE;
          end else pst <= P_AR;
        end
        P_AR: if (m_arready) begin
          p_beat <= 4'd0;
          pst    <= P_R;
        end
        P_R: begin
          // The beat arriving, into its register.
          if (m_rvalid && m_rready) begin
            rb_data  <= m_rdata;
            rb_valid <= 1'b1;
            if (m_rresp[1]) error <= 1'b1;
            // RLAST where the length says, and nowhere else: a slave that
            // ended the burst early or late has handed over the wrong
            // number of words, and the block is not to be trusted.
            if (m_rlast != take_last) error <= 1'b1;
          end
          // The words going into the store, one a tick.
          if (hi_pending) begin
            hi_pending <= 1'b0;
            if (last_beat) begin
              p_burst    <= p_burst + 4'd1;
              burst_addr <= addr_of(p_base, p_burst + 4'd1);
              pst        <= last_burst ? P_TAG : P_AR;
            end else begin
              p_beat <= p_beat + 4'd1;
            end
          end else if (rb_valid) begin
            rb_valid <= 1'b0;
            if (pad_beat) begin
              // One word only; the pad is dropped.  This is always the last
              // beat of the last burst.
              p_burst    <= p_burst + 4'd1;
              burst_addr <= addr_of(p_base, p_burst + 4'd1);
              pst        <= P_TAG;
            end else begin
              hi_word    <= rb_data[63:32];
              hi_pending <= 1'b1;
            end
          end
        end
        P_TAG: begin
          busy <= 1'b0;
          done <= 1'b1;
          pst  <= P_IDLE;
        end
        P_AW: if (m_awready) begin
          p_beat <= 4'd0;
          pst    <= P_W0;
        end
        P_W0: pst <= P_W1;
        P_W1: pst <= P_W2;
        P_W2: pst <= P_W3;
        P_W3: begin
          wlo <= store_rdata;
          pst <= P_W4;
        end
        P_W4: begin
          whi <= store_rdata;
          pst <= P_W5;
        end
        P_W5: if (m_wready) begin
          if (last_beat) pst <= P_B;
          else begin
            p_beat <= p_beat + 4'd1;
            pst    <= P_W0;
          end
        end
        P_B: if (m_bvalid) begin
          if (m_bresp[1]) error <= 1'b1;
          p_burst    <= p_burst + 4'd1;
          burst_addr <= addr_of(p_base, p_burst + 4'd1);
          if (last_burst) begin
            busy <= 1'b0;
            done <= 1'b1;
            pst  <= P_IDLE;
          end else begin
            pst <= P_AW;
          end
        end
        default: pst <= P_IDLE;
      endcase
    end
  end

  // Whether the move in progress is a bare take-away, which ends at P_TAKE.
  logic take_only;
  always_ff @(posedge clk) begin
    if (rst) take_only <= 1'b0;
    else if (pst == P_IDLE && go_any && !refuse) take_only <= go_take;
  end

  // Deliberately unread: bit 0 of the two responses, because OKAY is 00 and
  // EXOKAY 01 and only bit 1 tells SLVERR and DECERR from them.
  logic unused_m;
  assign unused_m = ^{m_bresp[0], m_rresp[0], p_write};

endmodule

`default_nettype wire
