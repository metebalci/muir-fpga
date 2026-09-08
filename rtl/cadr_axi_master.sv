// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The AXI adapter behind the DDR bridge: one 32-bit word a transaction.
//
// `cadr_xbus_ddr` asks for a word at a byte address and waits; this is what
// turns that into AXI4 and back.  The CADR does one word at a time and hangs
// until it has it, so every transaction is a single beat --- `awlen`/`arlen`
// zero --- and there is never more than one in flight.  Bursts would buy
// nothing: the machine has no way to ask for the next word before it has this
// one.
//
// AXI4 here, AXI3 at the far end.  The Zynq-7000 PS-PL ports --- `S_AXI_HP0`
// among them --- speak AXI3, whose burst length caps at 16 against AXI4's 256,
// and Vivado's protocol converter bridges the two.  At a burst of one the
// distinction does not arise, which is one more reason single beats are the
// right shape here.
//
// There is no muir reference for any of this, as there is none for the bridge:
// nothing in MIT's drawings is an AXI master.  So it is held to the protocol
// and to the property --- every request answered exactly once, a read returning
// what a write put there, address and data carried through unchanged.
//
// Timing is not a fidelity question here.  Whatever the adapter and the memory
// controller take, the bus interface waits for it, exactly as it waits for any
// slow slave; the Xbus is asynchronous and hangs the machine until `-XBUS.ACK`.
// That is why this can be written for clarity rather than for a tick count.

`default_nettype none

module cadr_axi_master (
    input  var logic        clk,
    input  var logic        rst,

    // The bridge's side.
    input  var logic        mem_req,     // a level, held until mem_done
    input  var logic        mem_write,
    input  var logic [31:0] mem_addr,    // byte address, word-aligned
    input  var logic [31:0] mem_wdata,
    output var logic        mem_done,    // held once the word is done
    output var logic [31:0] mem_rdata,
    output var logic        mem_error,   // SLVERR or DECERR came back

    // AXI4 write address
    output var logic [31:0] m_axi_awaddr,
    output var logic [7:0]  m_axi_awlen,
    output var logic [2:0]  m_axi_awsize,
    output var logic [1:0]  m_axi_awburst,
    output var logic        m_axi_awvalid,
    input  var logic        m_axi_awready,

    // AXI4 write data
    output var logic [31:0] m_axi_wdata,
    output var logic [3:0]  m_axi_wstrb,
    output var logic        m_axi_wlast,
    output var logic        m_axi_wvalid,
    input  var logic        m_axi_wready,

    // AXI4 write response
    input  var logic [1:0]  m_axi_bresp,
    input  var logic        m_axi_bvalid,
    output var logic        m_axi_bready,

    // AXI4 read address
    output var logic [31:0] m_axi_araddr,
    output var logic [7:0]  m_axi_arlen,
    output var logic [2:0]  m_axi_arsize,
    output var logic [1:0]  m_axi_arburst,
    output var logic        m_axi_arvalid,
    input  var logic        m_axi_arready,

    // AXI4 read data
    input  var logic [31:0] m_axi_rdata,
    input  var logic [1:0]  m_axi_rresp,
    input  var logic        m_axi_rlast,
    input  var logic        m_axi_rvalid,
    output var logic        m_axi_rready
);

  // One beat, four bytes, incrementing --- which for a single beat is only a
  // matter of saying something legal.
  localparam logic [7:0] LEN_ONE   = 8'd0;
  localparam logic [2:0] SIZE_WORD = 3'b010;  // 2^2 = 4 bytes
  localparam logic [1:0] BURST_INCR = 2'b01;

  typedef enum logic [2:0] {
    IDLE,
    WRITE,   // AW and W outstanding, either order
    WRESP,   // waiting for B
    READ,    // AR outstanding
    RDATA,   // waiting for R
    DONE     // the answer stands until the bridge lets go
  } state_e;

  state_e state;

  // AXI requires valid to stay asserted until ready, and the payload to stay
  // put with it, so these are registers and not functions of `mem_req`.
  logic aw_sent, w_sent;

  assign m_axi_awlen   = LEN_ONE;
  assign m_axi_awsize  = SIZE_WORD;
  assign m_axi_awburst = BURST_INCR;
  assign m_axi_arlen   = LEN_ONE;
  assign m_axi_arsize  = SIZE_WORD;
  assign m_axi_arburst = BURST_INCR;

  // A whole word, every time: the CADR has no byte writes on this path.
  assign m_axi_wstrb = 4'b1111;
  assign m_axi_wlast = 1'b1;

  // Nothing is ever refused, and there is only one transaction outstanding, so
  // the response channels are always ready.
  assign m_axi_bready = (state == WRESP);
  assign m_axi_rready = (state == RDATA);

  assign m_axi_awvalid = (state == WRITE) && !aw_sent;
  assign m_axi_wvalid  = (state == WRITE) && !w_sent;
  assign m_axi_arvalid = (state == READ);

  assign mem_done = (state == DONE);

  always_ff @(posedge clk) begin
    if (rst) begin
      state         <= IDLE;
      aw_sent       <= 1'b0;
      w_sent        <= 1'b0;
      mem_rdata     <= 32'd0;
      mem_error     <= 1'b0;
      m_axi_awaddr  <= 32'd0;
      m_axi_araddr  <= 32'd0;
      m_axi_wdata   <= 32'd0;
    end else begin
      unique case (state)
        IDLE: begin
          if (mem_req) begin
            // Latched here and held for the whole transaction: AXI wants the
            // payload stable from valid until ready.
            mem_error <= 1'b0;
            if (mem_write) begin
              m_axi_awaddr <= mem_addr;
              m_axi_wdata  <= mem_wdata;
              aw_sent      <= 1'b0;
              w_sent       <= 1'b0;
              state        <= WRITE;
            end else begin
              m_axi_araddr <= mem_addr;
              state        <= READ;
            end
          end
        end

        // The two channels are independent: either can be taken first, or
        // both in the same tick.
        WRITE: begin
          if (m_axi_awvalid && m_axi_awready) aw_sent <= 1'b1;
          if (m_axi_wvalid && m_axi_wready) w_sent <= 1'b1;
          if ((aw_sent || (m_axi_awvalid && m_axi_awready))
              && (w_sent || (m_axi_wvalid && m_axi_wready))) begin
            state <= WRESP;
          end
        end

        WRESP: begin
          if (m_axi_bvalid) begin
            // OKAY is 00 and EXOKAY 01; SLVERR and DECERR have bit 1 set.
            if (m_axi_bresp[1]) mem_error <= 1'b1;
            state <= DONE;
          end
        end

        READ: begin
          if (m_axi_arready) state <= RDATA;
        end

        RDATA: begin
          if (m_axi_rvalid) begin
            mem_rdata <= m_axi_rdata;
            if (m_axi_rresp[1]) mem_error <= 1'b1;
            state <= DONE;
          end
        end

        // The answer stands until the bridge drops its request. It holds
        // `mem_req` up until it has taken the word, so going straight back to
        // IDLE would start the same transaction over again.
        DONE: begin
          if (!mem_req) state <= IDLE;
        end

        default: state <= IDLE;
      endcase
    end
  end

  // Deliberately unread. `rlast` because at a burst of one every beat is the
  // last, and a slave that said otherwise would be the one at fault; bit 0 of
  // the two responses because OKAY is 00 and EXOKAY 01 --- only bit 1
  // distinguishes SLVERR and DECERR, and an exclusive access never happens
  // here.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = m_axi_rlast | m_axi_bresp[0] | m_axi_rresp[0];
  /* verilator lint_on UNUSEDSIGNAL */

endmodule

`default_nettype wire
