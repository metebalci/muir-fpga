// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's file device (contract Q9, revision 9): the machine's side of muir's
// `file_device::FileDevice`, and the host's side of it that Linux's server
// drives on a board.  The commands themselves --- OPEN, READ and the rest,
// run against the host's folders --- are the server's, which reads the
// command ring and writes buffers and the response ring in main memory
// directly.  What is here is everything the machine and the server share:
// the registers, the rings' indexes, the interrupt, the disable, and the two
// orderings between the processor's memory and the server's.
//
// The machine's registers, words of the register page (`Machine::bus_read`
// and `bus_write`, `FileDevice::read` and `write`):
//
//     160  control, read and written: <0> enable, <8> interrupt enable
//     161  status, read only: <0> enabled, <1> quiet, <2> configuration
//          refused, <3> index fault, <8> a response waiting, <23:16> handles
//     162  command ring base, <23:0>; 163 its size, the log2 of its entries
//     164  command producer, the processor's; 165 command consumer, the device's
//     166  response ring base; 167 its size
//     170  response producer, the device's; 171 response consumer, the processor's
//
// muir's rules, each ported as muir has it: 162, 163, 166 and 167 are
// written only while disabled; the enable checks them (a base off a 4-word
// line, a size over 8, or a ring reaching past main memory is refused,
// <2>); while disabled the four indexes read 0 and writes of 164 and 171 go
// nowhere; the enable starts them at 0; a write of 164 claiming more commands
// than the ring holds or fewer than are waiting, and a write of 171 past 170,
// are ignored and set <3>; a write of 160 clears <2> and <3>.  One response
// a command, in order, so 165 and 170 are one register here as in muir.
// **Disable is the reset**: the queue dropped, the handles closed, the
// indexes and the interrupt enable 0, the bases and sizes kept.  **Every
// machine reset disables it**, `-XBUS INIT` (`xbus_init`): the power-on
// reset, and since revision 10 `RESET-DEVICES`, the register page's word 104 <0>
// (contract Q11 and its Q9 amendment), and not `PROG.UNIBUS.RESET`, which
// reaches nothing on QUUX; and clears <2> and <3> besides.  Word 100's <7>
// (contract Q13) is `irq`: the interrupt enable and a response waiting, a
// level.
//
// **THE HOST'S SIDE** (`docs/file-device.md` has it for the server's author,
// and `rtl/plumbing/quux_fd_face.sv` puts it on a page of the processor's
// port).  Registers by index, the face multiplying by four:
//
//     2   STATE, read: <0> enabled, <1> the interrupt enable, <2> busy,
//         <3> quiet, <4> work waiting, <5> the last completion refused,
//         <31:16> EPOCH, one more at every disable
//     3   CLAIM: written {EPOCH, <0> 1} sets busy if enabled in that epoch;
//         written <0> 0 clears it in any; read <0> busy
//     4-7 the command ring's base and size, the response ring's
//     8   the command producer as the host may see it
//     9   RESP_PROD: read 165 = 170; written {EPOCH, <15:0> index} completes
//         the commands up to the index
//     10  171
//     11  HANDLES: written {EPOCH, <7:0> count}, the handles open once
//         the next completion lands; read, the count the machine sees
//     12  MEM_WORDS: main memory's words, the boards' count times 64K
//
// Indexes 0 and 1 are the real-time clock's (`quux_rtc.sv`), which the page
// joins.  A write carrying an EPOCH that is not the current one is ignored,
// so a command the server was running when the machine disabled the device
// never publishes, and its handle count never lands in the new epoch.
//
// **THE TWO ORDERINGS, WHICH ARE WHY THIS IS FABRIC AND NOT A REGISTER FILE.**
//
// 1. A command producer written by the machine is shown to the host (index
//    8) only once the processor's write buffer has drained behind it
//    (`drained`, `quux_mem_port.sv`'s): every word of the command entry and
//    its buffers that the processor wrote before 164 is then in main memory
//    where the server reads it.  muir's device takes a new 164 from the same
//    instant (`Machine::write_buffer_empty_at`).
//
// 2. A completion the host writes invalidates the machine's whole cache
//    first: `invalidate` and word 100's <7> go up in the tick after the
//    write lands, and 165, 170 and 161's <8> and <23:16> show it in the tick
//    after that.  The port drops the cache at the
//    next grant after the pulse (`quux_mem_port.sv`'s `inval_owed`), and any
//    grant that can follow the machine seeing the index is later than that.
//    muir invalidates the whole cache when its device has written main
//    memory, before the processor's next memory cycle (`dma_written`).
//
// **THE HANDLES OPEN CHANGE WITH A COMMAND'S COMPLETION AND NEVER BETWEEN**,
// as muir's do: the count the host writes is staged and lands with the next
// accepted completion, so 161's <23:16> and 170 move in one tick.
//
// A completion is accepted when the device is enabled, the EPOCH is the
// current one, it moves 170 forward by one to the commands shown (index 8),
// and it leaves the response ring no fuller than its size; otherwise nothing
// changes and STATE's <5> goes up until the next accepted completion or
// CLAIM.  A completion and the machine's own register write landing in one
// tick are taken in either order muir could have them in: the machine's
// write sees the index as it stood.
//
// **REVISION 13** (contract G1 §4.4, G2 §4.3, appendix A1.10; `WORD_BITS`
// 40; muir's `FileDevice` with `revision_13`): 162 and 166 hold 28-bit
// physical word addresses, `<27:0>`, and a ring must start on an 8-word line,
// `<2:0>` 0, so that it is whole lines of packed storage; main memory's size
// is 28 bits.  The rest is revision 12's: the entries' words 2 and 4 and the
// tag `005` on every word the device writes are the server's, which writes
// main memory itself (`docs/file-device.md`).  The readout gives each base
// a word of its own there (`ro_bases`, `ro_resp_base`).
//
// What holds it: `build/quux_files.quux.k4.pass`, a program driving every
// register on the whole machine against muir's device, with the testbench
// playing the server at muir's instants through this side; and
// `build/quux_fd_face.pass`, the face and this module driven over AXI as
// Linux drives them, stale epochs, refused completions and the claim
// included.

`default_nettype none

module quux_file_device #(
    // 32, QUUX to revision 12; 40, revision 13 (above).
    parameter int unsigned WORD_BITS = 32,
    localparam bit          WIDE      = WORD_BITS > 32,
    // A ring's base, its line and main memory's size, in bits.
    localparam int unsigned BASE_BITS = WIDE ? 28 : 24,
    localparam int unsigned LINE_BITS = WIDE ? 3 : 2,
    localparam int unsigned MEM_BITS  = WIDE ? 28 : 23,
    localparam int unsigned SUM_BITS  = BASE_BITS + 1
) (
    input  var logic        clk,
    input  var logic        rst,
    // `-XBUS INIT`: the power-on reset and `RESET-DEVICES`, the register
    // page's word 104 (`cadr_machine.sv`'s `bus_init`).
    input  var logic        xbus_init,

    // The machine's side, from `quux_feature_page.sv` at the instant the
    // page answers: a read or a write of word `which`.
    input  var logic        wr,
    input  var logic [7:0]  which,
    // `<31:24>` carry nothing any of the ten registers takes.
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [31:0] wdata,
    /* verilator lint_on UNUSEDSIGNAL */
    output var logic        mine,
    output var logic [31:0] rdata,
    output var logic        irq,

    // Main memory's words, and the port's write buffer empty.
    input  var logic [MEM_BITS-1:0] mem_words,
    input  var logic        drained,
    // The whole cache dropped at the next grant.
    output var logic        invalidate,

    // The host's side, by index: one write and one read a tick.
    input  var logic        host_we,
    input  var logic [3:0]  host_widx,
    input  var logic [31:0] host_wdata,
    input  var logic [3:0]  host_ridx,
    output var logic [31:0] host_rdata,

    // The readout's view, for a checkpoint: muir's `FileDevice::save`.
    // Revision 12's two bases in one word, `<47:24>` the command ring's; on
    // revision 13 the command ring's alone, and the response ring's in
    // `ro_resp_base`, which revision 12 does not read.
    output var logic [47:0] ro_bases,
    output var logic [47:0] ro_resp_base,
    output var logic [47:0] ro_indexes,
    output var logic [47:0] ro_flags
);

  localparam logic [3:0] H_STATE     = 4'd2;
  localparam logic [3:0] H_CLAIM     = 4'd3;
  localparam logic [3:0] H_CMD_BASE  = 4'd4;
  localparam logic [3:0] H_CMD_LOG2  = 4'd5;
  localparam logic [3:0] H_RESP_BASE = 4'd6;
  localparam logic [3:0] H_RESP_LOG2 = 4'd7;
  localparam logic [3:0] H_CMD_PROD  = 4'd8;
  localparam logic [3:0] H_RESP_PROD = 4'd9;
  localparam logic [3:0] H_RESP_CONS = 4'd10;
  localparam logic [3:0] H_HANDLES   = 4'd11;
  localparam logic [3:0] H_MEM_WORDS = 4'd12;

  logic        enabled, ie, refused, fault;
  logic [BASE_BITS-1:0] cmd_base, resp_base;
  logic [3:0]  cmd_log2, resp_log2;
  logic [15:0] prod, cons, resp_cons;
  // The host's.
  // Busy and the epoch are the host's and outlast a reset of the machine:
  // the server may be copying across one, and a reset that put the epoch
  // back would let a completion from before it land after it.  From the
  // fabric's configuration, 0.
  logic        busy = 1'b0;
  logic [15:0] epoch = 16'd0;
  logic        cons_refused;
  logic [7:0]  handles, handles_next;
  logic [15:0] shown;
  // A completion accepted and not yet shown to the machine's reads.
  logic        pub;
  logic [15:0] pub_to;

  // The rings' entries, 1 to 256.
  logic [8:0] cmd_n, resp_n;
  assign cmd_n  = 9'd1 << cmd_log2[3:0];
  assign resp_n = 9'd1 << resp_log2[3:0];

  // --- the machine's register, at the instant the page answers ------------
  assign mine = which >= 8'o160 && which <= 8'o171;

  logic [15:0] queued, claimed, waiting_resp, past;
  assign queued       = prod - cons;
  assign claimed      = wdata[15:0] - cons;
  assign waiting_resp = cons - resp_cons;
  assign past         = wdata[15:0] - resp_cons;

  // A ring fits: on a line, 256 entries at most, inside main memory.
  function automatic logic fits(input logic [BASE_BITS-1:0] base, input logic [3:0] log2,
                                input logic [MEM_BITS-1:0] words);
    return base[LINE_BITS-1:0] == '0 && log2 <= 4'd8
        && ({1'b0, base} + (SUM_BITS'(8) << log2)) <= SUM_BITS'(words);
  endfunction

  always_comb begin
    rdata = 32'd0;
    unique case (which)
      8'o160: rdata = {23'd0, ie, 7'd0, enabled};
      8'o161: rdata = {8'd0, handles, 7'd0, cons != resp_cons,
                       4'd0, fault, refused, !enabled && !busy, enabled};
      8'o162: rdata = 32'(cmd_base);
      8'o163: rdata = {28'd0, cmd_log2};
      8'o164: rdata = enabled ? {16'd0, prod} : 32'd0;
      8'o165, 8'o170: rdata = enabled ? {16'd0, cons} : 32'd0;
      8'o166: rdata = 32'(resp_base);
      8'o167: rdata = {28'd0, resp_log2};
      8'o171: rdata = enabled ? {16'd0, resp_cons} : 32'd0;
      default: rdata = 32'd0;
    endcase
  end


  // --- the host's writes ---------------------------------------------------
  logic in_epoch;
  assign in_epoch = enabled && host_wdata[31:16] == epoch;

  // The host sees a completion it wrote at once.
  logic [15:0] cons_host;
  assign cons_host = pub ? pub_to : cons;

  logic complete_ok;
  logic [15:0] c_step, c_room;
  assign c_step = host_wdata[15:0] - cons_host;
  assign c_room = host_wdata[15:0] - resp_cons;
  assign complete_ok = in_epoch && c_step != 16'd0 && c_step <= (shown - cons_host)
                    && c_room <= {7'd0, resp_n};

  logic h_complete;
  assign h_complete = host_we && host_widx == H_RESP_PROD;
  // The cache dropped in the tick after the completion lands, from a
  // register: the comparisons above are carry chains, and the cache's valid
  // bits are a thousand registers.
  assign invalidate = pub;

  // Word 100's <7>: a response waiting under the interrupt enable.  It is
  // up a tick before a register read shows the new index: the processor
  // takes its interrupt at a master clock edge from the tick before it, and
  // a register a tick after the grant, so a completion at one instant is
  // seen by both at the same instant only if the interrupt leads by that
  // tick (muir's `interrupt_at` and `read`, both at the instant, the due
  // time on or before it).
  assign irq = ie && (cons != resp_cons || pub);

  // --- the disable, from either side of the machine -----------------------
  logic m_wr_control, m_disable, m_enable;
  assign m_wr_control = wr && which == 8'o160;
  assign m_enable  = m_wr_control && !enabled && wdata[0];
  assign m_disable = (m_wr_control && enabled && !wdata[0]) || (xbus_init && enabled);

  always_ff @(posedge clk) begin
    if (rst) begin
      enabled   <= 1'b0;
      ie        <= 1'b0;
      refused   <= 1'b0;
      fault     <= 1'b0;
      cmd_base  <= '0;
      cmd_log2  <= 4'd0;
      resp_base <= '0;
      resp_log2 <= 4'd0;
      prod      <= 16'd0;
      cons      <= 16'd0;
      resp_cons <= 16'd0;
      cons_refused <= 1'b0;
      handles   <= 8'd0;
      handles_next <= 8'd0;
      shown     <= 16'd0;
      pub       <= 1'b0;
      pub_to    <= 16'd0;
    end else begin
      // The host's completion: the cache dropped and the interrupt up in
      // the tick after it lands (`pub`), and the index and the handles open
      // standing from the one after that.
      pub <= 1'b0;
      if (h_complete) begin
        cons_refused <= !complete_ok;
        if (complete_ok) begin
          pub    <= 1'b1;
          pub_to <= host_wdata[15:0];
        end
      end
      if (pub) begin
        cons    <= pub_to;
        handles <= handles_next;
      end
      if (host_we && host_widx == H_CLAIM) cons_refused <= 1'b0;
      if (host_we && host_widx == H_HANDLES && in_epoch) handles_next <= host_wdata[7:0];

      // The command producer shown to the host, once the write buffer has
      // drained behind it.
      if (!enabled) shown <= 16'd0;
      else if (drained) shown <= prod;

      // The machine's writes.
      if (wr) begin
        unique case (which)
          8'o160: begin
            refused <= 1'b0;
            fault   <= 1'b0;
            if (m_enable) begin
              if (fits(cmd_base, cmd_log2, mem_words) && fits(resp_base, resp_log2, mem_words)) begin
                enabled   <= 1'b1;
                ie        <= wdata[8];
                prod      <= 16'd0;
                cons      <= 16'd0;
                resp_cons <= 16'd0;
              end else begin
                refused <= 1'b1;
              end
            end else if (enabled && wdata[0]) begin
              ie <= wdata[8];
            end
          end
          8'o162: if (!enabled) cmd_base  <= wdata[BASE_BITS-1:0];
          8'o163: if (!enabled) cmd_log2  <= wdata[3:0];
          8'o166: if (!enabled) resp_base <= wdata[BASE_BITS-1:0];
          8'o167: if (!enabled) resp_log2 <= wdata[3:0];
          8'o164: if (enabled) begin
            if (claimed > {7'd0, cmd_n} || claimed < queued) fault <= 1'b1;
            else prod <= wdata[15:0];
          end
          8'o171: if (enabled) begin
            if (past > waiting_resp) fault <= 1'b1;
            else resp_cons <= wdata[15:0];
          end
          default: ;
        endcase
      end

      // The disable, which is the reset: last, over everything above.
      if (m_disable) begin
        enabled   <= 1'b0;
        ie        <= 1'b0;
        prod      <= 16'd0;
        cons      <= 16'd0;
        resp_cons <= 16'd0;
        handles   <= 8'd0;
        handles_next <= 8'd0;
        shown     <= 16'd0;
        pub       <= 1'b0;
      end
      if (xbus_init) begin
        refused <= 1'b0;
        fault   <= 1'b0;
      end
    end
  end

  // --- the host's claim and the epoch, which no reset reaches -------------
  //
  // The epoch counts every disable: the machine's write of 160, its
  // `-XBUS INIT`, and a reset of the machine that finds the device enabled.
  always_ff @(posedge clk) begin
    if ((m_disable || rst) && enabled) epoch <= epoch + 16'd1;
    if (host_we && host_widx == H_CLAIM) begin
      if (!host_wdata[0]) busy <= 1'b0;
      else if (in_epoch && !rst) busy <= 1'b1;
    end
  end

  // --- the host's reads, a tick after the index ---------------------------
  logic work;
  assign work = enabled && shown != cons_host && (cons_host - resp_cons) < {7'd0, resp_n};

  always_ff @(posedge clk) begin
    unique case (host_ridx)
      H_STATE:     host_rdata <= {epoch, 10'd0, cons_refused, work, !enabled && !busy,
                                  busy, ie, enabled};
      H_CLAIM:     host_rdata <= {31'd0, busy};
      H_CMD_BASE:  host_rdata <= 32'(cmd_base);
      H_CMD_LOG2:  host_rdata <= {28'd0, cmd_log2};
      H_RESP_BASE: host_rdata <= 32'(resp_base);
      H_RESP_LOG2: host_rdata <= {28'd0, resp_log2};
      H_CMD_PROD:  host_rdata <= {16'd0, shown};
      H_RESP_PROD: host_rdata <= {16'd0, cons_host};
      H_RESP_CONS: host_rdata <= {16'd0, resp_cons};
      H_HANDLES:   host_rdata <= {24'd0, handles};
      H_MEM_WORDS: host_rdata <= 32'(mem_words);
      default:     host_rdata <= 32'd0;
    endcase
  end

  // --- the readout ----------------------------------------------------------
  if (WIDE) begin : g_ro13
    assign ro_bases = 48'(cmd_base);
  end else begin : g_ro12
    assign ro_bases = {cmd_base, resp_base};
  end
  assign ro_resp_base = 48'(resp_base);
  assign ro_indexes = {prod, cons, resp_cons};
  assign ro_flags   = {11'd0, busy, handles, cmd_log2, resp_log2, 16'd0,
                       fault, refused, ie, enabled};

endmodule

`default_nettype wire
