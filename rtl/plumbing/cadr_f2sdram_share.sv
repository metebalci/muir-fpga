// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// One FPGA-to-SDRAM port, shared by burst, with the machine first.
//
// On the Zynq boards the machine, the disk pack side and the display each have
// a port of their own into the processing system's memory: `S_AXI_HP0`,
// `S_AXI_HP2` and `S_AXI_HP3`.  The Agilex 5's processor has one: the
// FPGA-to-SDRAM bridge, AXI4 at 64, 128 or 256 bits.  So on the DE25-Nano the
// three share it, and this is where they meet.  All three drive it on the
// board: the machine, the disk pack side, and the display on a build that
// carries one, whose port is tied idle on a build that does not.  The check
// that holds this module drives all three, because the property that matters
// is what the other two cost the machine when they are not idle.
//
// **WHAT THE THREE MASTERS SPEAK IS WHAT THE ZYNQ'S PORTS SPOKE**, AXI3 at 64
// bits with four bits of burst length and a two-bit beat size, because that is
// what `cadr_axi_widen.sv`, `cadr_disk_pack.sv` and `cadr_display_out.sv`
// already put out.  The bridge speaks AXI4.  At a burst of sixteen beats or
// fewer the two are the same transactions: the length and the size are
// zero-extended, and AXI4 has no write ID, which the next paragraph deals
// with.  So the conversion is done here, once, for all three, rather than
// three times upstream.
//
// **THE RULES THE BRIDGE PUTS ON A TRANSACTION**, from the Agilex 5 HPS
// Technical Reference Manual (document 814346), section 11.8.3.1, tables 336
// and 337, and from the bridge's properties in its table 333:
//
//   AxSIZE     "The number of bytes in a transfer must be equal to the data
//              bus width": eight at 64 bits.  Passed through and not forced,
//              so that a master that said anything else is seen saying it.
//   AxBURST    "Must be INCR or WRAP".  Passed through, for the same reason.
//   AxUSER     `0xE0`, "SDRAM direct", the convention the manual's section
//              10.8 gives.
//   AxCACHE    `0b0010` is one of the two values the table allows.
//   AxPROT     `0b011`, privileged and non-secure, which is what Altera's own
//              F2SDRAM adapters drive.  The table's example is `0b001`; the
//              choice between them is recorded as a decision to confirm.
//   AxID       five bits, and fixed per master: the machine is 0, the pack
//              side 1 and the display 2.  The responses are routed by it.
//   AxLOCK, AxQOS, AxREGION, WUSER    zero.
//
// **BY BURST, AND AT MOST ONE BURST'S WORTH IN FLIGHT PER MASTER AND
// DIRECTION.**  A master is granted a whole transaction.  Its writes are one at
// a time: no second write is granted until the first has its response.  Its
// reads are counted in BEATS: a read is granted only while the beats of that
// master's reads still to come, with this one's added, are no more than
// sixteen, `CAP`, which is one full burst.  So a master streaming sixteen-beat
// bursts --- the pack side, and the display upright --- still has one in
// flight, and a master asking for single beats --- the display's rotated band
// fetch, one word out of each source row --- may have as many as it has asked
// for, up to sixteen.  That is the whole of the bound this module keeps, and
// the arithmetic is the same as with one burst: when the machine asks, what
// stands between it and its answer is at most one burst's worth of beats that
// each other master already has in flight, in each direction, and the
// presentation of one address already on the bus.  The machine's own cycles
// are single beats, one at a time, so it never has more than one in flight
// anyway.
//
// **WHY BEATS AND NOT BURSTS.**  With one read in flight per master, the
// display's rotated fetch waits a whole round trip of the memory for every
// word, and a band of 963 words does not arrive in the 32 raster lines it has:
// `docs/display-output.md` says one at a time does not finish in time, and
// `build/display_share.pass` measures it, the rotated pictures going black at
// a round trip of 40 clocks behind a share that let one through.  Counting
// beats gives the display what its own `OUTSTANDING` asks for without letting
// any master put more in front of the machine than one burst did.
//
// **THE MACHINE IS FIRST, AND WHILE IT IS ASKING NOTHING NEW IS GRANTED TO
// ANYBODY ELSE.**  Priority by port alone is not enough, and that was
// measured rather than argued: with one burst in flight per master, a master
// that is waiting for its answer is not asking for a grant, so the machine
// almost never meets another at the same tick and the priority decides
// nothing.  `mutations/list.txt`'s `the-machine-is-not-first` reversed the
// priority and not one number of the check moved.
//
// So what makes the bound the machine's is a hold: from the tick the machine
// asks for a word until the tick its answer comes back, the other masters
// are granted nothing new.  What the machine waits for is then exactly what
// was already in flight when it asked, which is the bound below, and the
// same record now moves it.  A burst already granted runs to its end ---
// nothing may withdraw a valid address --- so the others lose no transaction,
// only the next one's start; and the machine asks for a word every hundred
// and fifty nanoseconds at its very busiest, so what it costs them is a
// fraction of a port they have in hand.
//
// Priority by port is still the tie-break among the rest: the pack side is 1
// and the display 2, and the cap on beats in flight is what keeps that from
// starving the display, since the pack side's sixteen-beat bursts fill it and
// it cannot be granted again until its burst is answered.
//
// **A GRANT IS A REGISTER AND NOT A WIRE.**  A master that is granted keeps the
// bus until its address has been taken, because AXI does not allow a valid
// address to be withdrawn or changed, and a combinational choice would change
// owner under a higher priority's arrival.  It costs one tick a transaction.
//
// **A WRITE IS PRESENTED WHOLE.**  The bridge is AXI4 and AXI4 has no write
// ID, so write data must arrive in the order of the write addresses.  So a
// write is granted as a pair: its address and its data are both put to the
// bridge, the data not waiting for the address to be taken, because a slave
// is allowed to wait for write data before it takes the address.  The next
// write is granted only when both have been taken, and the last data beat.
//
// **`hold` STOPS GRANTS AND NOTHING ELSE.**  `rtl/plumbing/cadr_f2sdram_gate.sv`
// raises it while the port is shut or while the processor has asked the
// fabric to be quiet; whatever is already granted runs to its end, because a
// valid cannot be withdrawn.  `idle` is what the gate waits for: nothing
// granted, and nothing outstanding in either direction.
//
// There is no muir reference for any of this, as there is none for the AXI
// adapter.  `tb/cadr_f2sdram_tb.cpp` holds it: the machine's boot PROM through
// it against a model of the bridge, the rules above on every transaction, what
// each of the three masters is handed against what the bridge gave, and how
// much a machine cycle may grow with the other two ports streaming --- 29
// ticks, measured, against a ceiling of 35 that the one-burst's-worth rule and
// the hold put on it.  `tb/cadr_display_out_tb.cpp`, built behind this module
// as `build/display_share.pass`, holds the display's several reads in flight.

`default_nettype none

module cadr_f2sdram_share #(
    // The masters.  Port 0 is the machine and is first; the port number is
    // the transaction ID, so there can be at most thirty-two.
    parameter int unsigned N = 3
) (
    input  var logic clk,
    input  var logic rst,

    // No new grant.  Whatever is granted finishes.
    input  var logic hold,
    // Nothing granted and nothing outstanding.
    output var logic idle,

    // --- the masters: AXI3 at 64 bits, one port each ----------------------
    input  var logic [N-1:0][31:0] s_awaddr,
    input  var logic [N-1:0][3:0]  s_awlen,
    input  var logic [N-1:0][1:0]  s_awsize,
    input  var logic [N-1:0][1:0]  s_awburst,
    input  var logic [N-1:0]       s_awvalid,
    output var logic [N-1:0]       s_awready,
    input  var logic [N-1:0][63:0] s_wdata,
    input  var logic [N-1:0][7:0]  s_wstrb,
    input  var logic [N-1:0]       s_wlast,
    input  var logic [N-1:0]       s_wvalid,
    output var logic [N-1:0]       s_wready,
    output var logic [N-1:0][1:0]  s_bresp,
    output var logic [N-1:0]       s_bvalid,
    input  var logic [N-1:0]       s_bready,
    input  var logic [N-1:0][31:0] s_araddr,
    input  var logic [N-1:0][3:0]  s_arlen,
    input  var logic [N-1:0][1:0]  s_arsize,
    input  var logic [N-1:0][1:0]  s_arburst,
    input  var logic [N-1:0]       s_arvalid,
    output var logic [N-1:0]       s_arready,
    output var logic [N-1:0][63:0] s_rdata,
    output var logic [N-1:0][1:0]  s_rresp,
    output var logic [N-1:0]       s_rlast,
    output var logic [N-1:0]       s_rvalid,
    input  var logic [N-1:0]       s_rready,

    // --- the FPGA-to-SDRAM bridge: AXI4 at 64 bits ------------------------
    output var logic [4:0]  m_awid,
    output var logic [31:0] m_awaddr,
    output var logic [7:0]  m_awlen,
    output var logic [2:0]  m_awsize,
    output var logic [1:0]  m_awburst,
    output var logic        m_awlock,
    output var logic [3:0]  m_awcache,
    output var logic [2:0]  m_awprot,
    output var logic [3:0]  m_awqos,
    output var logic [3:0]  m_awregion,
    output var logic [7:0]  m_awuser,
    output var logic        m_awvalid,
    input  var logic        m_awready,
    output var logic [63:0] m_wdata,
    output var logic [7:0]  m_wstrb,
    output var logic        m_wlast,
    output var logic [7:0]  m_wuser,
    output var logic        m_wvalid,
    input  var logic        m_wready,
    input  var logic [4:0]  m_bid,
    input  var logic [1:0]  m_bresp,
    input  var logic        m_bvalid,
    output var logic        m_bready,
    output var logic [4:0]  m_arid,
    output var logic [31:0] m_araddr,
    output var logic [7:0]  m_arlen,
    output var logic [2:0]  m_arsize,
    output var logic [1:0]  m_arburst,
    output var logic        m_arlock,
    output var logic [3:0]  m_arcache,
    output var logic [2:0]  m_arprot,
    output var logic [3:0]  m_arqos,
    output var logic [3:0]  m_arregion,
    output var logic [7:0]  m_aruser,
    output var logic        m_arvalid,
    input  var logic        m_arready,
    input  var logic [4:0]  m_rid,
    input  var logic [63:0] m_rdata,
    input  var logic [1:0]  m_rresp,
    input  var logic        m_rlast,
    input  var logic        m_rvalid,
    output var logic        m_rready
);

  // The decoration: see the header for the source of each.
  localparam logic [7:0] USER_SDRAM   = 8'hE0;
  localparam logic [3:0] CACHE_BUFFER = 4'b0010;
  localparam logic [2:0] PROT_NS      = 3'b011;

  // A port number, wide enough for N of them.
  localparam int unsigned IW = (N > 1) ? $clog2(N) : 1;

  // The first port asking, lowest first.  Only called with at least one bit
  // set, so the value for none does not matter.
  function automatic logic [IW-1:0] first(input logic [N-1:0] asking);
    first = '0;
    for (int i = N - 1; i >= 0; i--) begin
      if (asking[i]) first = IW'(i);
    end
  endfunction

  // ------------------------------------------------- who may be granted
  //
  // The machine while it is asking or waiting, and everybody while it is
  // not: see the header.  Port 0 is the machine's.
  //
  // **AND A WRITE OF THE MACHINE'S IS WAITED FOR FROM ITS GRANT, NOT FROM ITS
  // LAST BEAT.**  Its address valid falls when the bridge takes the address,
  // and it is not outstanding until the bridge has taken its data too; in the
  // tick between, the machine is neither asking nor, by `wr_out`, waiting.
  // Measured without the `w_on` term: over BUSY, 116 reads of the other
  // masters were granted in that one tick.  With it the hold is what the
  // header says, from the tick the machine asks to the tick its answer is back.
  logic          machine_busy;
  logic [N-1:0]  eligible;
  assign machine_busy = s_arvalid[0] || s_awvalid[0] ||
                        (w_on && (w_who == '0)) || rd_out[0] || wr_out[0];
  assign eligible = machine_busy ? {{(N-1){1'b0}}, 1'b1} : {N{1'b1}};

  // --------------------------------------------------------------- reads
  //
  // The most beats of reads one master may have in flight: one full burst.
  // See the header.
  localparam int unsigned CAP = 16;

  logic          ar_on;        // an address is being put to the bridge
  logic [IW-1:0] ar_who;
  logic [N-1:0][4:0] rd_beats; // beats of this master's reads still to come
  logic [N-1:0]  rd_out;       // a read of this master's is outstanding
  logic [N-1:0]  ar_fits;      // its next read keeps it within `CAP`
  logic [N-1:0]  ar_can;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      rd_out[i]  = (rd_beats[i] != 5'd0);
      ar_fits[i] = (6'(rd_beats[i]) + 6'(s_arlen[i]) + 6'd1) <= 6'(CAP);
    end
  end
  assign ar_can = (s_arvalid & ar_fits) & eligible;

  assign m_arvalid  = ar_on;
  assign m_arid     = 5'(ar_who);
  assign m_araddr   = s_araddr[ar_who];
  assign m_arlen    = {4'd0, s_arlen[ar_who]};
  assign m_arsize   = {1'b0, s_arsize[ar_who]};
  assign m_arburst  = s_arburst[ar_who];
  assign m_arlock   = 1'b0;
  assign m_arcache  = CACHE_BUFFER;
  assign m_arprot   = PROT_NS;
  assign m_arqos    = 4'd0;
  assign m_arregion = 4'd0;
  assign m_aruser   = USER_SDRAM;

  // --------------------------------------------------------------- writes
  logic          w_on;         // a write's address and data are being put
  logic [IW-1:0] w_who;
  logic          aw_done;      // its address has been taken
  logic          w_done;       // its last data beat has been taken
  logic [N-1:0]  wr_out;       // a write of this master's awaits its response
  logic [N-1:0]  aw_can;
  assign aw_can = (s_awvalid & ~wr_out) & eligible;

  assign m_awvalid  = w_on && !aw_done;
  assign m_awid     = 5'(w_who);
  assign m_awaddr   = s_awaddr[w_who];
  assign m_awlen    = {4'd0, s_awlen[w_who]};
  assign m_awsize   = {1'b0, s_awsize[w_who]};
  assign m_awburst  = s_awburst[w_who];
  assign m_awlock   = 1'b0;
  assign m_awcache  = CACHE_BUFFER;
  assign m_awprot   = PROT_NS;
  assign m_awqos    = 4'd0;
  assign m_awregion = 4'd0;
  assign m_awuser   = USER_SDRAM;

  assign m_wvalid = w_on && !w_done && s_wvalid[w_who];
  assign m_wdata  = s_wdata[w_who];
  assign m_wstrb  = s_wstrb[w_who];
  assign m_wlast  = s_wlast[w_who];
  assign m_wuser  = 8'd0;

  logic aw_take, w_take;
  assign aw_take = m_awvalid && m_awready;
  assign w_take  = m_wvalid && m_wready && m_wlast;

  // -------------------------------------------------- the masters' side
  logic [N-1:0] b_mine, r_mine;
  always_comb begin
    for (int i = 0; i < N; i++) begin
      s_arready[i] = ar_on && (ar_who == IW'(i)) && m_arready;
      s_awready[i] = w_on && !aw_done && (w_who == IW'(i)) && m_awready;
      s_wready[i]  = w_on && !w_done && (w_who == IW'(i)) && m_wready;
      b_mine[i]    = (m_bid == 5'(i));
      r_mine[i]    = (m_rid == 5'(i));
      s_bvalid[i]  = m_bvalid && b_mine[i];
      s_bresp[i]   = m_bresp;
      s_rvalid[i]  = m_rvalid && r_mine[i];
      s_rdata[i]   = m_rdata;
      s_rresp[i]   = m_rresp;
      s_rlast[i]   = m_rlast;
    end
  end
  assign m_bready = |(s_bready & b_mine);
  assign m_rready = |(s_rready & r_mine);

  assign idle = !ar_on && !w_on && (rd_out == '0) && (wr_out == '0);

  always_ff @(posedge clk) begin
    if (rst) begin
      ar_on   <= 1'b0;
      ar_who  <= '0;
      rd_beats <= '0;
      w_on    <= 1'b0;
      w_who   <= '0;
      aw_done <= 1'b0;
      w_done  <= 1'b0;
      wr_out  <= '0;
    end else begin
      // The read address: granted, presented, taken.
      if (!ar_on) begin
        if (!hold && (ar_can != '0)) begin
          ar_on  <= 1'b1;
          ar_who <= first(ar_can);
        end
      end else if (m_arready) begin
        ar_on <= 1'b0;
      end

      // The write: granted, its address and its data presented together,
      // and let go when both have been taken.
      if (!w_on) begin
        if (!hold && (aw_can != '0)) begin
          w_on    <= 1'b1;
          w_who   <= first(aw_can);
          aw_done <= 1'b0;
          w_done  <= 1'b0;
        end
      end else begin
        if (aw_take) aw_done <= 1'b1;
        if (w_take)  w_done  <= 1'b1;
        if ((aw_done || aw_take) && (w_done || w_take)) begin
          w_on          <= 1'b0;
          wr_out[w_who] <= 1'b1;
        end
      end

      // The reads' beats: the burst's length added when its address is
      // taken, and one taken away for every beat that comes back for that
      // master, both in one tick when they meet --- which they do, a master
      // with a read streaming back being granted its next.
      for (int i = 0; i < N; i++) begin
        rd_beats[i] <= rd_beats[i]
                       + ((ar_on && m_arready && (ar_who == IW'(i)))
                              ? 5'(s_arlen[i]) + 5'd1 : 5'd0)
                       - ((m_rvalid && m_rready && r_mine[i]) ? 5'd1 : 5'd0);
      end

      // The write answers.  A response cannot arrive in the tick its
      // transaction was taken, so this never meets the setting above for the
      // same master.
      for (int i = 0; i < N; i++) begin
        if (m_bvalid && m_bready && b_mine[i]) wr_out[i] <= 1'b0;
      end
    end
  end

endmodule

`default_nettype wire
