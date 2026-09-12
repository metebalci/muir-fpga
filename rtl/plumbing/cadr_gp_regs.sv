// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The AXI3 slave face a register block on a general purpose port presents:
// one 4 KB page, 1,024 words, every one of them answered.
//
// **WHY THIS IS A MODULE AND NOT A FOURTH COPY.**  There are three of these
// in the tree already --- `cadr_disk_pack.sv`'s, `cadr_console.sv`'s and
// `cadr_gp0_default.sv`'s --- each written out by hand, and the two faces
// behind `cadr_gp0_split.sv` would have made five.  The protocol is the
// thing that must be right (a read nothing answers hangs both Arm cores at
// one PC each, measured on the board), so it is written once, checked once,
// and instantiated by the Chaosnet cable and the serial line.  The three
// that came first are not disturbed: they are checked where they are, and a
// refactor of a checked module buys nothing this does not.
//
// **WHAT IT ANSWERS.**  Every address in the page, read and written, with
// OKAY.  Not SLVERR for the words the block leaves undefined: a read there
// gives whatever the block puts on `rd_data`, which for an undefined word is
// zero, and a write there is dropped.  `cadr_gp0_default.sv`'s header has
// the argument --- an error response to a Cortex-A9's posted write arrives as
// an imprecise external abort the kernel cannot attribute to a process, so a
// constant a program can recognise is the safer failure --- and the pack
// side's SLVERR outside its sixteen words is the older, narrower decision,
// left where it is.
//
// **THE PAGE IS THE SPLITTER'S AND THE OFFSET IS THIS FACE'S.**  The address
// in is twelve bits, the offset within the page, so a face reached through
// `cadr_gp0_split.sv` cannot answer outside the page it was given whatever
// its own arithmetic does.  AXI forbids a burst that crosses a 4 KB
// boundary, so a legal burst stays inside the page and the twelve-bit
// counter's wrap is unreachable; it is left to wrap rather than error,
// because an address that cannot arrive needs no answer and a wrap still
// terminates.
//
// **THE SEAM: TWO SELECTORS, ONE EACH WAY.**  `w_word` and `r_word` are two
// registers off two channels, never one shared, for the reason
// `cadr_gp0_split.sv` gives at more length: AXI's write and read channels
// are independent and the interconnect drives them independently, so a
// block sharing one selector would answer a read at whichever word a write
// in flight had reached.
//
// **AND THE READ IS TWO TICKS BEHIND THE SELECTOR, DELIBERATELY.**
// `cadr_disk_pack.sv` measured what a read mux hung straight off the AXI
// address does: `r_at_reg[8]/C -> u_ps7/MAXIGP0RDATA[14]`, four logic levels
// and -0.164 ns on the DDR=1 board, the hard block's setup being most of the
// tick.  So the address is a register (`r_word`), `rd` is high for the tick
// after it settles, `rd_data` is sampled the tick after THAT, and the
// registered word is what RVALID offers.  Two ticks and not one so that a
// block may answer either way: a combinational mux off `r_word` is stable
// through both ticks, and a synchronous RAM addressed by `r_word` --- which
// is what the Chaosnet cable's two 256-word buffers are --- has its word out
// on the second.  A block that CONSUMES on a read (the serial line's RDATA)
// registers its answer at `rd` and holds it, which the second tick also
// catches.
//
// `rd` is one tick per BEAT, not per transaction, so a consuming read inside
// a burst consumes once a beat.  `wr` is one tick per beat too, with
// `wr_data` and `wr_mask` beside it: the mask is the byte strobes expanded,
// so a block merges with `(old & ~wr_mask) | (wr_data & wr_mask)` and a
// `writeb` does what it says.
//
// NO muir REFERENCE EXISTS, as none exists for `cadr_axi_master.sv` or the
// pack side: nothing in MIT's drawings is an AXI slave.  It is held to the
// protocol --- exactly one handshake per channel per transaction, the payload
// stable under valid, WLAST taken from the data channel and RLAST where
// ARLEN says --- and to read-back through the two faces that use it.
// `tb/cadr_gp0_split_tb.cpp` drives it through the splitter with lengths,
// IDs, strobes and delays that vary, and counts every handshake.

`default_nettype none

module cadr_gp_regs (
    input  var logic        clk,
    input  var logic        rst,

    // --- the port's side: 32 bits, AXI3, twelve bits of address ----------
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

    // --- the register block's seam ---------------------------------------
    // The word a write beat lands on, and the beat itself.
    output var logic [9:0]  w_word,
    output var logic        wr,
    output var logic [31:0] wr_data,
    output var logic [31:0] wr_mask,
    // The word a read beat is owed, one tick before `rd_data` is sampled.
    output var logic [9:0]  r_word,
    output var logic        rd,
    input  var logic [31:0] rd_data
);

  localparam logic [1:0] OKAY = 2'b00;

  typedef enum logic [1:0] { W_ADDR, W_DATA, W_RESP } wstate_e;
  // `R_PREP` is the tick the block sees `r_word` and `rd`; `R_PREP2` is the
  // tick its answer is sampled.  See the header.
  typedef enum logic [1:0] { R_ADDR, R_PREP, R_PREP2, R_DATA } rstate_e;
  wstate_e wst;
  rstate_e rst_r;

  logic [11:0] w_id, r_id;
  logic [3:0]  r_left;     // beats still owed after this one
  logic [31:0] rdata_q;

  assign s_awready = (wst == W_ADDR);
  assign s_wready  = (wst == W_DATA);
  assign s_bvalid  = (wst == W_RESP);
  assign s_bresp   = OKAY;
  assign s_bid     = w_id;

  assign s_arready = (rst_r == R_ADDR);
  assign s_rvalid  = (rst_r == R_DATA);
  assign s_rdata   = rdata_q;
  assign s_rresp   = OKAY;
  assign s_rid     = r_id;
  assign s_rlast   = (r_left == 4'd0);

  // A beat lands this tick.
  assign wr      = s_wvalid && s_wready;
  assign wr_data = s_wdata;
  assign wr_mask = {{8{s_wstrb[3]}}, {8{s_wstrb[2]}}, {8{s_wstrb[1]}}, {8{s_wstrb[0]}}};
  assign rd      = (rst_r == R_PREP);

  always_ff @(posedge clk) begin
    if (rst) begin
      wst     <= W_ADDR;
      rst_r   <= R_ADDR;
      w_word  <= 10'd0;
      r_word  <= 10'd0;
      w_id    <= 12'd0;
      r_id    <= 12'd0;
      r_left  <= 4'd0;
      rdata_q <= 32'd0;
    end else begin
      unique case (wst)
        W_ADDR: if (s_awvalid) begin
          w_word <= s_awaddr[11:2];
          w_id   <= s_awid;
          wst    <= W_DATA;
        end
        W_DATA: begin
          // The address walks up a word a beat, so a burst writes
          // consecutive words; the data channel says where it ends.
          if (s_wvalid) begin
            w_word <= w_word + 10'd1;
            if (s_wlast) wst <= W_RESP;
          end
        end
        W_RESP: if (s_bready) wst <= W_ADDR;
        default: wst <= W_ADDR;
      endcase
      unique case (rst_r)
        R_ADDR: if (s_arvalid) begin
          r_word <= s_araddr[11:2];
          r_id   <= s_arid;
          r_left <= s_arlen;
          rst_r  <= R_PREP;
        end
        R_PREP: rst_r <= R_PREP2;
        R_PREP2: begin
          rdata_q <= rd_data;
          rst_r   <= R_DATA;
        end
        R_DATA: if (s_rready) begin
          if (r_left == 4'd0) rst_r <= R_ADDR;
          else begin
            r_left <= r_left - 4'd1;
            r_word <= r_word + 10'd1;
            rst_r  <= R_PREP;
          end
        end
        default: rst_r <= R_ADDR;
      endcase
    end
  end

  // AWLEN is not read: the write data channel's WLAST is what says where a
  // write ends, and a master whose AWLEN and WLAST disagree is broken in a
  // way no slave can mend.  `cadr_disk_pack.sv` says the same at its own
  // face and folds it the same way.
  //
  // Nor are the two byte bits of either address: every register here is a
  // whole word, a beat walks up a word at a time, and WHICH BYTES a beat
  // carries is the strobes' business and not the address's.  A sub-word
  // access therefore lands on the word it is inside, with the strobes
  // saying which byte --- which is what a `writeb` is.
  logic unused_s;
  assign unused_s = ^{s_awlen, s_awaddr[1:0], s_araddr[1:0]};

endmodule

`default_nettype wire
