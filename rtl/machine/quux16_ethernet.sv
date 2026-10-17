// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 16'S ETHERNET DEVICE, THE MACHINE'S SIDE** (QUUX's Ethernet
// contract, §2.1-§2.3, §2.5, §2.7): words 240-257 of the register page, its
// interrupt word 100's `<8>`, and the host's side of it that Linux's
// `quux-ethernet-device` drives on a board through
// `rtl/plumbing/quux_ed_face.sv`.  muir's `ethernet_device::EthernetDevice`
// is the reference for the machine's side: its `read` and `write`, `disable`
// and `reset`, `interrupt` and `waiting`.  What muir's device does with an
// Ethernet frame --- the entries read, the frames sent, the buffers written,
// the checks of §2.4 --- is the program's on a board, which reads and writes
// main memory itself, and only the indexes it moves come back here.
//
//     240  control: <0> enable, <8> interrupt enable
//     241  status, read only: <0> enabled, <1> quiet, <2> configuration
//          refused, <3> index fault, <7:4> type-filter drops, <8> an Ethernet
//          frame waiting (251 != 252), <15:9> IPv4-check drops, <23:16>
//          receive drops, <31:24> transmit entries refused
//     242, 243  the transmit ring's base, <27:0>, and its log2 size
//     244  transmit producer, the processor's; 245 transmit consumer
//     246, 247  the receive ring's base and log2 size
//     250  receive producer, the processor's; 251 receive consumer;
//          252 receive taken, the processor's
//     253-257  the MAC address, the IPv4 address, the netmask and the
//          gateway, the host's, read only to the machine
//
// **muir's RULES, EACH AS muir HAS IT** (`EthernetDevice::write`): 242, 243,
// 246 and 247 are written only while disabled, the bases to 28 bits and the
// sizes to 4; the enable checks both rings (a base off an 8-word line, a size
// over 8, or a ring past main memory is refused, `<2>`, the device staying
// disabled); a write of 240 clears `<2>` and `<3>`; while disabled writes of
// 244, 250 and 252 go nowhere and the five indexes read 0 --- every disable
// puts them at 0 and nothing moves them until the enable, so the words read
// the registers; a write of 244 making 244 - 245 more than the ring's size or
// less than the entries waiting, of 250 making 250 - 252 more than the ring's
// size or less than the buffers given, or of 252 past 251, is ignored and
// sets `<3>`.  **DISABLE IS THE RESET**: the indexes and the interrupt enable
// to 0, the bases, the sizes and 253-257 kept; RESET-DEVICES (word 104) is
// the disable and clears `<2>` and `<3>`; a reset of the machine is
// power-on's state.  **WORD 100's `<8>`** is the interrupt enable and an
// Ethernet frame waiting, a level: `irq` as this clock's write leaves it,
// `irq_state` as the clock began, which word 100's read gives.
//
// **A REGISTER IS READ AT THE CLOCK AFTER ITS GRANT** (`quux15_devices.sv`'s
// rule): `rd_word` is the word as the registers stand in that clock, and no
// read here changes anything.  **A WRITE IS TAKEN IN ITS CLOCK**, and in
// muir's order within it: the host's index move landing first (the device's
// own `advance`), then the held write of 244 or 250 (`port_events`), then the
// register write (`register_write_now`), RESET-DEVICES being one.  **244 AND
// 250 ARE HELD BY THE CORE** until every write before them is answered
// (§2.5; muir's `waits_for_writes`), so the program on a board never reads an
// entry still in the posted writes: `held` is that write landing.
//
// **THE HOST'S SIDE**, by index, `quux_ed_face.sv` multiplying by four from
// 0x100 (17 is MEM_WORDS, at 0x004):
//
//     0   STATE, read: <0> enabled, <1> the interrupt enable, <2> busy,
//         <3> quiet, <31:16> EPOCH, one more at every disable
//     1   CLAIM: written {EPOCH, <0> 1} sets busy if enabled in that epoch;
//         written <0> 0 clears it in any; read <0> busy
//     2-5 242, 243, 246 and 247
//     6   244, once the processor's writes before it are answered
//     7   TX_CONS: read 245; written {EPOCH, <15:0> index}, 245 moved to the
//         index, the entries before it sent or refused
//     8   250, as 6
//     9   RX_CONS: read 251; written {EPOCH, <15:0> index}, the cache made
//         coherent and 251 moved to the index
//     10  252
//     11  COUNTS: 241's four counters in their places, <7:4>, <15:9>,
//         <23:16> and <31:24>; written, all four at once
//     12-16 253-257
//     17  MEM_WORDS: main memory's words
//
// **QUIET IS "NOT ENABLED AND NOT BUSY"**, busy the host's claim, held while
// it reads an entry and its frame or writes a buffer, so a disable in the
// middle does not read quiet and the machine does not reuse that memory.
// **A MOVE CARRYING AN EPOCH NOT THE CURRENT ONE IS IGNORED**, so a delivery
// a disable overtook never moves 251.  Busy and the epoch outlast every
// reset, as the file device's do: the host may be writing across one.  **A
// MOVE IS ACCEPTED** when the device is enabled, the EPOCH is the current
// one, and it moves the index forward no further than its producer (251 by
// at least one); otherwise nothing changes.  **IT LANDS THE CLOCK AFTER ITS
// WRITE**, as the file device's completion does, so that a move written at
// clock k - 1 is muir's at clock k; a disable in the clock between drops it.
//
// **THE CACHE IS MADE COHERENT AT RX_CONS's LANDING, BEFORE THE MACHINE SEES
// 251 MOVE** (§2.5): `sweep` is the whole-cache sweep the file device's
// completion takes (`quux15_port.sv`'s `sweep_go`), whose lookups wait until
// it is done (§2.5 (i)).  It is made at one place below, `coherence`, so
// that line clearing (§2.5 (ii)) can take its place if M-refill chooses it.
//
// **THE FOUR COUNTERS AND 253-257 ARE THE HOST'S TO SET AND THIS DEVICE'S TO
// KEEP** (§2.4.1, §2.7): only the program sees a frame dropped, and only the
// host knows its flags.  The counters come up 0 and 253-257 at muir's
// defaults, `02:00:00:00:00:01` and 169.254.100.2/30 by 169.254.100.1, from
// the fabric's configuration, and no reset reaches them.  A COUNTS write is
// taken at its edge, so one written at clock k is read from clock k + 1, as a
// move written at k - 1 is.
//
// What holds it: `build/quux16_ethernet_module.quux.pass`, this module against
// muir's `EthernetDevice` over `golden/src/quux16_ethernet.rs`'s scripts,
// the host's moves played as muir's device made them, every register read
// after every step; `build/quux_ed_face.pass`, the host's side through the
// face over AXI; and `build/quux16_ethernet.quux.pass`, the core's
// `ethernet` group, clock for clock on muir's pipeline at revision 16.

`default_nettype none

module quux16_ethernet #(
    // Main memory's words: a ring must fit below them.
    parameter int unsigned MAIN_WORDS = 32'h0020_0000
) (
    input  var logic        clk,
    // A reset of the machine: power-on's state, but for what outlasts it.
    input  var logic        rst,
    // RESET-DEVICES, taken this clock.
    input  var logic        dev_reset,

    // A read at the clock after its grant, of word 240 + `rd_k`; its word.
    input  var logic        rd,
    input  var logic [3:0]  rd_k,
    output var logic [31:0] rd_word,
    // A register write taken this clock, of word 240 + `wr_k`.
    input  var logic        wr,
    input  var logic [3:0]  wr_k,
    input  var logic [31:0] wdata,
    // The held write landing this clock: 244, or 250 with `held_rx`.
    input  var logic        held,
    input  var logic        held_rx,
    input  var logic [15:0] held_data,

    // Word 100's <8>: as this clock's write leaves it, and as it began.
    output var logic        irq,
    output var logic        irq_state,
    // 244 and 250 as this clock leaves them, which the host's side reads.
    output var logic [15:0] tx_prod_now,
    output var logic [15:0] rx_prod_now,
    // An RX_CONS move landing this clock: the cache made coherent.
    output var logic        sweep,

    // The host's side, by index (above): one write and one read a clock, a
    // read's word the clock after its index.
    input  var logic        host_we,
    input  var logic [4:0]  host_widx,
    input  var logic [31:0] host_wdata,
    input  var logic [4:0]  host_ridx,
    output var logic [31:0] host_rdata
);

  localparam logic [3:0] R_CONTROL = 4'o00;
  localparam logic [3:0] R_TX_BASE = 4'o02;
  localparam logic [3:0] R_TX_SIZE = 4'o03;
  localparam logic [3:0] R_RX_BASE = 4'o06;
  localparam logic [3:0] R_RX_SIZE = 4'o07;
  localparam logic [3:0] R_RX_TAKEN = 4'o12;

  localparam logic [4:0] H_STATE     = 5'd0;
  localparam logic [4:0] H_CLAIM     = 5'd1;
  localparam logic [4:0] H_TX_BASE   = 5'd2;
  localparam logic [4:0] H_TX_LOG2   = 5'd3;
  localparam logic [4:0] H_RX_BASE   = 5'd4;
  localparam logic [4:0] H_RX_LOG2   = 5'd5;
  localparam logic [4:0] H_TX_PROD   = 5'd6;
  localparam logic [4:0] H_TX_CONS   = 5'd7;
  localparam logic [4:0] H_RX_PROD   = 5'd8;
  localparam logic [4:0] H_RX_CONS   = 5'd9;
  localparam logic [4:0] H_RX_TAKEN  = 5'd10;
  localparam logic [4:0] H_COUNTS    = 5'd11;
  localparam logic [4:0] H_MAC_HIGH  = 5'd12;
  localparam logic [4:0] H_MAC_LOW   = 5'd13;
  localparam logic [4:0] H_IP        = 5'd14;
  localparam logic [4:0] H_NETMASK   = 5'd15;
  localparam logic [4:0] H_GATEWAY   = 5'd16;
  localparam logic [4:0] H_MEM_WORDS = 5'd17;

  // 241's counters' places.
  localparam logic [31:0] COUNTS_MASK = 32'hFFFF_FEF0;

  // The registers (muir's `EthernetDevice`).
  logic        on, ie, refused, fault;
  logic [27:0] tx_base, rx_base;
  logic [3:0]  tx_log2, rx_log2;
  logic [15:0] tx_prod, tx_cons, rx_prod, rx_cons, rx_taken;

  // The host's: the counters and 253-257 from the configuration, which no
  // reset reaches; the claim and the epoch likewise.
  logic [31:0] counts   = 32'd0;
  logic [15:0] mac_high = 16'h0200;
  logic [31:0] mac_low  = 32'h0000_0001;
  logic [31:0] ip       = {8'd169, 8'd254, 8'd100, 8'd2};
  logic [31:0] netmask  = 32'hFFFF_FFFC;
  logic [31:0] gateway  = {8'd169, 8'd254, 8'd100, 8'd1};
  logic        busy     = 1'b0;
  logic [15:0] epoch    = 16'd0;

  // A move accepted last clock, landing now.
  logic        tx_pub, rx_pub;
  logic [15:0] tx_pub_to, rx_pub_to;
  logic        tx_land, rx_land;
  assign tx_land = tx_pub && on;
  assign rx_land = rx_pub && on;

  // A ring fits: on a line, at most 2^8 entries, below main memory's end.
  function automatic logic fits(input logic [27:0] base, input logic [3:0] log2);
    return base[2:0] == 3'd0 && log2 <= 4'd8
        && 32'(base) + (32'd8 << log2) <= 32'(MAIN_WORDS);
  endfunction

  // The device as this clock's landing and writes leave it.
  logic        on_w, ie_w, refused_w, fault_w;
  logic [27:0] tx_base_w, rx_base_w;
  logic [3:0]  tx_log2_w, rx_log2_w;
  logic [15:0] tx_prod_w, tx_cons_w, rx_prod_w, rx_cons_w, rx_taken_w;
  always_comb begin
    on_w = on; ie_w = ie; refused_w = refused; fault_w = fault;
    tx_base_w = tx_base; rx_base_w = rx_base; tx_log2_w = tx_log2; rx_log2_w = rx_log2;
    tx_prod_w = tx_prod; tx_cons_w = tx_cons; rx_prod_w = rx_prod; rx_cons_w = rx_cons;
    rx_taken_w = rx_taken;
    // The host's move, in this clock's `advance`.
    if (tx_land) tx_cons_w = tx_pub_to;
    if (rx_land) rx_cons_w = rx_pub_to;
    // 244 or 250, held until the port was empty (`port_events`).
    if (held && on_w && !held_rx) begin
      if (held_data - tx_cons_w > 16'd1 << tx_log2_w || held_data - tx_cons_w < tx_prod_w - tx_cons_w)
        fault_w = 1'b1;
      else
        tx_prod_w = held_data;
    end
    if (held && on_w && held_rx) begin
      if (held_data - rx_taken_w > 16'd1 << rx_log2_w || held_data - rx_taken_w < rx_prod_w - rx_taken_w)
        fault_w = 1'b1;
      else
        rx_prod_w = held_data;
    end
    // The register write (`register_write_now`).
    if (wr && wr_k == R_CONTROL) begin
      refused_w = 1'b0;
      fault_w   = 1'b0;
      if (!on_w && wdata[0]) begin
        if (fits(tx_base_w, tx_log2_w) && fits(rx_base_w, rx_log2_w)) begin
          on_w = 1'b1; ie_w = wdata[8];
        end else begin
          refused_w = 1'b1;
        end
      end else if (on_w && !wdata[0]) begin
        on_w = 1'b0; ie_w = 1'b0;
        tx_prod_w = '0; tx_cons_w = '0; rx_prod_w = '0; rx_cons_w = '0; rx_taken_w = '0;
      end else if (on_w) begin
        ie_w = wdata[8];
      end
    end
    if (wr && !on_w) begin
      if (wr_k == R_TX_BASE) tx_base_w = wdata[27:0];
      if (wr_k == R_TX_SIZE) tx_log2_w = wdata[3:0];
      if (wr_k == R_RX_BASE) rx_base_w = wdata[27:0];
      if (wr_k == R_RX_SIZE) rx_log2_w = wdata[3:0];
    end
    if (wr && on_w && wr_k == R_RX_TAKEN) begin
      if (wdata[15:0] - rx_taken_w > rx_cons_w - rx_taken_w) fault_w = 1'b1;
      else rx_taken_w = wdata[15:0];
    end
    // RESET-DEVICES: disabled, the faults cleared; the rings stay.
    if (dev_reset) begin
      on_w = 1'b0; ie_w = 1'b0; refused_w = 1'b0; fault_w = 1'b0;
      tx_prod_w = '0; tx_cons_w = '0; rx_prod_w = '0; rx_cons_w = '0; rx_taken_w = '0;
    end
  end
  assign tx_prod_now = tx_prod_w;
  assign rx_prod_now = rx_prod_w;
  assign irq       = ie_w && rx_cons_w != rx_taken_w;
  assign irq_state = ie && rx_cons != rx_taken;

  // **THE COHERENCE STEP** (§2.5): the whole-cache sweep at RX_CONS's
  // landing, the mechanism M-refill decides.
  always_comb begin : coherence
    sweep = rx_land;
  end

  // ================================================================ the host

  // The host sees its own move at once.
  logic [15:0] tx_chost, rx_chost, h_index;
  logic        in_epoch, h_tx, h_rx, tx_ok, rx_ok, h_claim;
  assign tx_chost = tx_land ? tx_pub_to : tx_cons;
  assign rx_chost = rx_land ? rx_pub_to : rx_cons;
  assign h_index  = host_wdata[15:0];
  assign in_epoch = on && host_wdata[31:16] == epoch;
  assign h_tx     = host_we && host_widx == H_TX_CONS;
  assign h_rx     = host_we && host_widx == H_RX_CONS;
  assign h_claim  = host_we && host_widx == H_CLAIM;
  assign tx_ok    = in_epoch && h_index - tx_chost <= tx_prod - tx_chost;
  assign rx_ok    = in_epoch && h_index != rx_chost && h_index - rx_chost <= rx_prod - rx_chost;

  always_ff @(posedge clk) begin
    if (rst) begin
      on <= 1'b0; ie <= 1'b0; refused <= 1'b0; fault <= 1'b0;
      tx_base <= '0; rx_base <= '0; tx_log2 <= '0; rx_log2 <= '0;
      tx_prod <= '0; tx_cons <= '0; rx_prod <= '0; rx_cons <= '0; rx_taken <= '0;
      tx_pub <= 1'b0; rx_pub <= 1'b0; tx_pub_to <= '0; rx_pub_to <= '0;
    end else begin
      on <= on_w; ie <= ie_w; refused <= refused_w; fault <= fault_w;
      tx_base <= tx_base_w; rx_base <= rx_base_w; tx_log2 <= tx_log2_w; rx_log2 <= rx_log2_w;
      tx_prod <= tx_prod_w; tx_cons <= tx_cons_w; rx_prod <= rx_prod_w; rx_cons <= rx_cons_w;
      rx_taken <= rx_taken_w;
      tx_pub <= h_tx && tx_ok;
      rx_pub <= h_rx && rx_ok;
      if (h_tx && tx_ok) tx_pub_to <= h_index;
      if (h_rx && rx_ok) rx_pub_to <= h_index;
    end
  end

  // The epoch counts every disable: the machine's write of 240, its
  // RESET-DEVICES, and a reset of the machine that finds the device enabled.
  // The claim, the counters and 253-257 are the host's.  No reset reaches
  // any of them.
  always_ff @(posedge clk) begin
    if (rst ? on : on && !on_w) epoch <= epoch + 16'd1;
    if (h_claim) begin
      if (!host_wdata[0]) busy <= 1'b0;
      else if (in_epoch && !rst) busy <= 1'b1;
    end
    if (host_we && host_widx == H_COUNTS)   counts   <= host_wdata & COUNTS_MASK;
    if (host_we && host_widx == H_MAC_HIGH) mac_high <= host_wdata[15:0];
    if (host_we && host_widx == H_MAC_LOW)  mac_low  <= host_wdata;
    if (host_we && host_widx == H_IP)       ip       <= host_wdata;
    if (host_we && host_widx == H_NETMASK)  netmask  <= host_wdata;
    if (host_we && host_widx == H_GATEWAY)  gateway  <= host_wdata;
  end

  // The host's reads, a clock after the index.
  always_ff @(posedge clk) begin
    unique case (host_ridx)
      H_STATE:     host_rdata <= {epoch, 12'd0, !on && !busy, busy, ie, on};
      H_CLAIM:     host_rdata <= {31'd0, busy};
      H_TX_BASE:   host_rdata <= {4'd0, tx_base};
      H_TX_LOG2:   host_rdata <= {28'd0, tx_log2};
      H_RX_BASE:   host_rdata <= {4'd0, rx_base};
      H_RX_LOG2:   host_rdata <= {28'd0, rx_log2};
      H_TX_PROD:   host_rdata <= {16'd0, tx_prod};
      H_TX_CONS:   host_rdata <= {16'd0, tx_chost};
      H_RX_PROD:   host_rdata <= {16'd0, rx_prod};
      H_RX_CONS:   host_rdata <= {16'd0, rx_chost};
      H_RX_TAKEN:  host_rdata <= {16'd0, rx_taken};
      H_COUNTS:    host_rdata <= counts;
      H_MAC_HIGH:  host_rdata <= {16'd0, mac_high};
      H_MAC_LOW:   host_rdata <= mac_low;
      H_IP:        host_rdata <= ip;
      H_NETMASK:   host_rdata <= netmask;
      H_GATEWAY:   host_rdata <= gateway;
      H_MEM_WORDS: host_rdata <= 32'(MAIN_WORDS);
      default:     host_rdata <= 32'd0;
    endcase
  end

  // ================================================================ the read

  // The word the read gives, as the registers stand in its clock.
  always_comb begin
    unique case (rd_k)
      4'o00: rd_word = {23'd0, ie, 7'd0, on};
      4'o01: rd_word = {counts[31:9], rx_cons != rx_taken, counts[7:4], fault, refused, !on && !busy, on};
      4'o02: rd_word = {4'd0, tx_base};
      4'o03: rd_word = {28'd0, tx_log2};
      4'o04: rd_word = {16'd0, tx_prod};
      4'o05: rd_word = {16'd0, tx_cons};
      4'o06: rd_word = {4'd0, rx_base};
      4'o07: rd_word = {28'd0, rx_log2};
      4'o10: rd_word = {16'd0, rx_prod};
      4'o11: rd_word = {16'd0, rx_cons};
      4'o12: rd_word = {16'd0, rx_taken};
      4'o13: rd_word = {16'd0, mac_high};
      4'o14: rd_word = mac_low;
      4'o15: rd_word = ip;
      4'o16: rd_word = netmask;
      default: rd_word = gateway;
    endcase
  end

  logic unused;
  assign unused = ^{rd, counts[8], counts[3:0], wdata[31:28]};

endmodule

`default_nettype wire
