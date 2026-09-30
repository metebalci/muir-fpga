// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's memory port and register decode (contracts Q6 and Q7, revision
// 8): the processor's cycle on a machine with no bus interface and no
// device bus.  muir's `memory_port::MemoryPort` is the reference, and
// `build/quux_port.quux.pass` holds this module to it tick for tick
// (`golden/src/quux_port.rs`).  The cycle goes one of three ways, by the
// held decode of its physical address:
//
//   THE MEMORY BUS, main memory and the video controller's frame buffer, through the
//   cache (`quux_cache.sv`) to the memory controller below.  A read that
//   hits is answered two ticks after the grant; a miss fills its line and a
//   write goes through, one operation of main memory at a time, at the
//   nominal timing: a line fill in 380 ns, a write in 290, a write
//   acknowledged after the hit time by the write buffer, or when the
//   buffer's last write is done.  `cached` says so to the processor, whose
//   MBUSY and READ IN PROGRESS then fall on the acknowledgment itself
//   (muir's `Ack::cached`).  The frame buffer is DDR at the display's base,
//   where the scanout reads it on its own port; the cache writes through,
//   so every word written reaches it once the write buffer has drained.
//
//   A DEVICE REGISTER, the video controller's, block-disk's or the register page's:
//   taken at the grant and acknowledged a microcycle on, `K` ticks, with no
//   setup and no deskew, never cached.  The register is asked in the one
//   tick after the grant (`dev_rq`), which is the first tick its own held
//   match has the grant's address, and its word is taken in that tick and
//   held for the strobe.  muir takes it at the grant's instant; the tick
//   between is inside the microcycle the grant starts, which reads nothing
//   of the register, and the acknowledgment is muir's to the tick.
//
//   NOTHING: a decode miss, failing at once, `-MEMACK` in the very tick
//   that takes the request, with `NXM TIMEOUT` for word 101's NXM bit and a
//   word of zero.  No timer.  The held decode has had the address since the
//   tick after the map settled, two ticks into the microcycle before the
//   grant (`cadr_machine.xdc`'s split every-tick registers), so it is good
//   in the tick the request is taken.
//
// **THE NOMINAL TIMING IS A FLOOR** (the contract's clarification).  Main
// memory's real answer comes when it comes --- the Arty's HP0 in about 21
// ticks, the DE25's bridge in 35 and a tail to 227 --- and the port answers
// the processor at muir's instant or, when main memory is slower than the
// figure, as soon as the words are there.  Two countdowns carry muir's
// arithmetic: `free_in`, when main memory is nominally free for its next
// operation (`memory_free_at`), and `buf_in`, when the write buffer is
// (`buffer_free_at`); each holds, over the tick after an edge, how many
// ticks after that edge the instant is.  A cycle granted at E starts its
// operation at E + free_in and is done READ_T or WRITE_T later.  A faster
// memory is simply held back to the count, which is what makes the fabric
// muir's in simulation and never faster than it on a board.
//
// **THE MEMORY CONTROLLER IS ONE ORDERED PORT, WITH ONE OPERATION IN
// FLIGHT**: the write buffer's word first, then a line fill, then the
// uncached requester --- block-disk's transfers, by the memory path's
// bridge (`cadr_xbus_ddr.sv`), which carries nothing of the processor's on
// QUUX.  The order is the coherence: a transfer that reads main memory is
// served after the buffered write, so it sees every word the processor
// wrote before START (the contract's first rule); a line filled before a
// transfer's word is written is dropped from the cache when the word lands
// (`quux_cache.sv`'s `snoop`, the second).  The seam out is the machine's
// `mem_*`, a level held until done as `rtl/plumbing/cadr_axi_master.sv`
// takes it, with `mem_line` asking four words, two 64-bit beats, and the
// whole line back on `mem_rline`.
//
// **REVISION 12'S CACHE-ONLY PREFETCH** (contract H8a §3.5, muir's
// `MemoryPort` with `Reach::Line`).  When a macroinstruction fetch's read is
// answered from the memory bus at physical word p, the word at p + 1 is
// taken into a one-word buffer with its virtual and physical addresses, if
// it is in the line the fetch has just read or filled: the cache's RAMs put
// the hit line's four words out together (`quux_cache.sv`'s `next_word`),
// and a miss has its whole line in `line_word`.  No memory cycle, no map
// lookup, no second read of the cache.  The buffer is dropped by a store
// to its word (a tick after the store's grant), a transfer by block-disk or the file
// device (`invalidate` and the invalidation owed), and the processor's
// `pf_drop`: a write of the location counter or a map write at its edge,
// and -RESET.  The processor says at each grant whether the cycle is the
// stream's fetch and its `VMA<23:0>` (`pf_fetch`, `pf_vaddr`), as muir's
// `mark_fetch` does.  Every event is applied in muir's order within a
// tick --- an answer, then the processor's drops, then a grant --- and
// `pf_nx_*` is the buffer as the tick leaves it, which the processor takes
// at each master clock edge for the microcycle that edge begins
// (`cadr_microcycle.sv`, "the prefetch").  What the fused return does with
// it is the processor's.
//
// `drained` is up when no write waits in the buffer and main memory is
// idle: what the host waits for, after a halt, before it reads main memory
// from outside the machine (the contract: "a halt drains the write buffer").
//
// **REVISION 13'S PORT** (contract G2 §3, `WORD_BITS` 40; muir's
// `MemoryPort::for_geometry` on `Geometry::QUUX_13`, `Layout::REVISION_13`):
// 40-bit words and 28-bit physical addresses (G1 §3.2), the cache's 8-word
// lines (`quux_cache.sv`), and main memory in PACKED STORAGE (G1 §4.1): word
// w at byte `MAIN13_BASE + 5w`, `<7:0>` first and the tag last, a line of 8
// words 40 bytes at `MAIN13_BASE + 40L`, five 64-bit beats.  So a fill asks
// five beats (`mem_beats`) and a write five bytes at any byte (`mem_wide`),
// and the memory's side (`rtl/plumbing/quux_axi_master.sv`) puts them on the
// port: strobes, a word across two beats, and a burst split at a 4 KiB
// boundary.  The multiply by five is here on the memory side, from the
// registered address of the write buffer or the miss, never in the
// processor's cycle.  THE FRAME BUFFER WINDOW, `1760000000` up (G1 §4.2),
// keeps 4 bytes a word at the display's base, the field alone: a line of it
// is four beats, a write stores `<31:0>` and drops the tag, and its words
// come into the cache, and so to the processor, with the unboxed tag `005`.
// A fill takes muir's nominal line and a tick for each beat past today's two
// (`MemoryPort::fill_ns`): three in main memory, two in the window.  A device
// register's word is 32 bits and reads `<39:32>` as 0 (G2 §2.5).
//
// **AND THE PREFETCH REACHES THE PAGE** (muir's `Reach::Page`, revision
// 13's): past a fetch's word at p, the word at p + 1 when it is in the
// fetch's 1024-word page and the cache holds it --- in the fetch's line, as
// revision 12's, or in the next line, which the cache looks up beside the
// fetch's at the grant (`next_line_hit`, `next_line_word`).  Never out of the
// window, which is not main memory, and never past a page.  The virtual word
// address is 28 bits, `VMA<27:0>`.
//
// **AND THE UNCACHED REQUESTER'S WORDS ARE PACKED TOO** (revision 13):
// block-disk's channel reaches main memory alone, a word five bytes at
// `MAIN13_BASE + 5w`, read as the one or two beats it lies in and written
// as five bytes, and the cache's `snoop` drops the word's set as it lands.
// `build/quux13_port.quux.k4.pass` holds both, the snoop by a coherence run
// of 40-bit words beside the processor; `build/quux13_disk.quux.k4.pass`
// the transfers on the whole machine.
//
// **WHERE MAIN MEMORY IS IN DDR IS A PARAMETER**, `MAIN13_BASE`, which the
// machine hands down (`cadr_machine.sv`): the Linux side's layout decides it
// and this port only adds to it.  The 4 KiB rule is taken on the byte
// address itself, so the port is right at any base; G1 asks one at a
// multiple of 4 KiB, where a line crosses a boundary 4 times in 512.

`default_nettype none

module quux_mem_port
  import cadr_ddr_map::*;
#(
    // QUUX's nominal main memory, `MemoryTiming::NOMINAL`, in ticks.
    parameter int unsigned READ_T  = cadr_tick_pkg::ticks(380),
    parameter int unsigned WRITE_T = cadr_tick_pkg::ticks(290),
    // QUUX's microcycle in ticks, the machine's `SYNC_K`: a device
    // register is acknowledged this long after the grant, muir's
    // `cycle_ns(Speed::Normal, false)`, whatever `ILONG` does.
    parameter int unsigned K = 4,
    // 32, QUUX to revision 12; 40, revision 13 (`cadr_machine.sv`).
    parameter int unsigned WORD_BITS = 32,
    // Revision 13's main memory in DDR: word w at byte `MAIN13_BASE + 5w`,
    // and 0 the CADR's main memory base, `MAIN_BASE`, until the board's
    // layout gives another.  Unread below revision 13.
    parameter logic [31:0] MAIN13_BASE = 32'd0,
    localparam bit          WIDE       = WORD_BITS > 32,
    localparam int unsigned PHYS_BITS  = WIDE ? 28 : 22,
    localparam int unsigned VADDR_BITS = WIDE ? 28 : 24,
    // A line's beats as the memory's side returns them: two 64-bit beats of
    // four words, or on revision 13 five of packed storage.
    localparam int unsigned RLINE_BITS = WIDE ? 320 : 128
) (
    input  var logic         clk,
    input  var logic         rst,

    // The processor's side, as `cadr_busint_xbus.sv` has it on the CADR.
    input  var logic         mclk,
    input  var logic         n_memrq,
    input  var logic         wrcyc,
    input  var logic [PHYS_BITS-1:0] phys,  // the map's output at the grant
    input  var logic [WORD_BITS-1:0] wdata,
    // The held decode: the memory bus (main memory or the frame buffer),
    // or a device register.  Neither is an address nothing answers.  Their
    // OR is good in the tick that takes the request, which is all an empty
    // address needs; which of the two it is, from the first tick after the
    // grant, which is when the frame buffer's own held match has the
    // grant's address (`cadr_memory_path.sv`).
    input  var logic         is_memory,
    input  var logic         is_device,
    output var logic         n_memgrant,
    output var logic         n_memack,
    output var logic         n_loadmd,
    output var logic         timed_out,
    output var logic         cached,     // the cycle is the memory bus's
    output var logic [WORD_BITS-1:0] word,  // the word a read brings, any read
    output var logic         busy,

    // The register decode: a device register asked, for one tick, and the
    // word it gives in that tick.
    output var logic         dev_rq,
    output var logic         dev_write,
    input  var logic [31:0]  dev_rdata,

    // A block-disk register was written: the whole cache goes at the next
    // grant, muir's `dma_written`.
    input  var logic         invalidate,

    // The uncached requester, `cadr_xbus_ddr.sv`'s seam.  `u_main` says the
    // word is main memory's, and `u_phys` which, for the cache's snoop.  On
    // revision 13 the requester is block-disk's channel and reaches main
    // memory alone: `u_phys` is where, `u_addr` is not read, and the word is
    // the whole word, packed here (below).
    input  var logic         u_req,
    input  var logic         u_write,
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [31:0]  u_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  var logic [WORD_BITS-1:0] u_wdata,
    input  var logic         u_main,
    input  var logic [PHYS_BITS-1:0] u_phys,
    output var logic         u_done,
    output var logic [WORD_BITS-1:0] u_rdata,  // main memory's own, while u_done

    // Main memory: the machine's DDR seam.  A line fill (`mem_line`) asks
    // `mem_beats` 64-bit beats from `mem_addr` and has them back on
    // `mem_rline`, the first in bits 63:0; a write is four bytes of
    // `mem_wdata` at a four-byte address, or on revision 13 with `mem_wide`
    // five at any byte, `<7:0>` first.
    output var logic         mem_req,
    output var logic         mem_write,
    output var logic         mem_line,
    output var logic [2:0]   mem_beats,
    output var logic         mem_wide,
    output var logic [31:0]  mem_addr,
    output var logic [WORD_BITS-1:0] mem_wdata,
    input  var logic         mem_done,
    input  var logic [31:0]  mem_rdata,
    input  var logic [RLINE_BITS-1:0] mem_rline,

    output var logic         drained,
    // The cache's counts of reads, for the host: muir's `hits` and
    // `misses`.
    output var logic [31:0]  hits,
    output var logic [31:0]  misses,

    // The prefetch: the cycle a grant takes is the stream's fetch of
    // `pf_vaddr`; the processor drops the word; and the buffer and a
    // fetch yet to be answered, as this tick leaves them.
    input  var logic         pf_fetch,
    input  var logic [VADDR_BITS-1:0] pf_vaddr,
    input  var logic         pf_drop,
    output var logic         pf_nx_v,
    output var logic [VADDR_BITS-1:0] pf_nx_vaddr,
    output var logic [PHYS_BITS-1:0]  pf_nx_phys,
    output var logic [WORD_BITS-1:0]  pf_nx_word,
    output var logic         pf_nx_fetch_v,
    output var logic [VADDR_BITS-1:0] pf_nx_fetch_vaddr
);

  localparam int unsigned HIT_T = cadr_tick_pkg::ticks(20);
  localparam int unsigned WB = WORD_BITS;
  localparam logic [31:0] BASE13 = (MAIN13_BASE != 32'd0) ? MAIN13_BASE : MAIN_BASE;
  localparam int unsigned LINE_WORDS = WIDE ? 8 : 4;
  localparam int unsigned OFF_BITS = WIDE ? 3 : 2;

  // Revision 13's frame buffer window, `1760000000`-`1777775777`: the top
  // 4M words of the 28-bit space less its last page, the register page,
  // which a memory cycle never has.  So on the memory bus the window is
  // `phys<27:22>` all ones.
  // Its argument's low bits are no part of it.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic window(input logic [PHYS_BITS-1:0] p);
    return WIDE && (&p[PHYS_BITS-1:PHYS_BITS-6]);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // The unboxed tag, `005`, which the window's words read with (G1 §2.6).
  localparam logic [7:0] UNBOXED_TAG = 8'o005;

  // A word as the cache and the processor have it, from what is stored:
  // revision 13's window gives the field with the unboxed tag.
  function automatic logic [WB-1:0] from_window(input logic [31:0] field);
    logic [WB-1:0] v;
    v = WB'(field);
    if (WIDE) v[WB-1:WB-8] = UNBOXED_TAG;
    return v;
  endfunction

  // Where a word or a line is in DDR.  Revision 12: `quux_byte_address`.
  // Revision 13: main memory packed, 5 bytes a word and 40 a line; the
  // window 4 bytes a word and 32 a line, at the display's base.  The
  // window's offset is the low sixteen bits, the video controller's buffer
  // being at most 64K words (`cadr_ddr_map.sv`).
  function automatic logic [31:0] word_address(input logic [PHYS_BITS-1:0] p);
    if (!WIDE) return quux_byte_address(22'(p));
    if (window(p)) return mono_display_byte_address(p[15:0]);
    return BASE13 + (32'(p) << 2) + 32'(p);
  endfunction
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic [31:0] line_address(input logic [PHYS_BITS-1:0] p);
    logic [PHYS_BITS-1:0] l;
    l = {p[PHYS_BITS-1:OFF_BITS], OFF_BITS'(0)};
    return word_address(l);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  // ------------------------------------------------------- the cycle
  typedef enum logic [1:0] {IDLE, REQUESTED, GRANTED, ACKED} state_e;
  state_e state;
  logic       write;
  logic       first;        // the first tick of GRANTED: the lookup's answer
  logic       kmem;         // the cycle is the memory bus's, from its first tick
  logic       kdev;         // the cycle is a device register's, the same
  logic       nxm;          // the cycle was an address nothing answers
  logic [5:0] elapsed;      // ticks since the grant, for a register's: K is
                            // at most 63 (`quux_phase_gen.sv`)
  logic [31:0] dev_word;    // the register's word, taken when it was asked

  logic take;
  assign take = (state == IDLE || state == REQUESTED) && !n_memrq && mclk;

  // An address nothing answers fails in the tick that takes it.
  logic empty;
  assign empty = take && !is_memory && !is_device;

  // `kmem` and `kdev` are taken at the end of the first tick; in it the
  // held decode itself is read.
  logic mem_cycle, dev_cycle;
  assign mem_cycle = first ? is_memory : kmem;
  assign dev_cycle = first ? (is_device && !is_memory) : kdev;

  logic ack_standing;
  assign ack_standing = (state == ACKED) && !n_memrq;

  // The register, asked once, in the first tick after the grant.
  assign dev_rq    = (state == GRANTED) && first && dev_cycle;
  assign dev_write = write;

  // The memory bus's acknowledgment, a register set at the edge before its
  // instant (`ack_in` below).
  logic mack_q;

  logic acked;
  assign acked = ack_standing || empty
              || (state == GRANTED && mem_cycle && mack_q)
              || (state == GRANTED && dev_cycle && elapsed == 6'(K - 1));

  assign n_memgrant = !(state == GRANTED || state == ACKED);
  assign n_memack   = !acked;
  assign n_loadmd   = !acked;
  assign timed_out  = empty || (ack_standing && nxm);
  assign busy       = (state != IDLE);
  assign cached     = (state == GRANTED || state == ACKED) && mem_cycle;

  // ------------------------------------------------------- the cache
  logic c_hit, c_hit_way, c_victim;
  logic [WB-1:0] c_word, c_next_word, c_next_line_word;
  logic c_next_line_hit;
  logic c_touch, c_miss, c_update, c_fill, c_inval, c_snoop;
  logic [PHYS_BITS-1:0] snoop_phys;
  logic inval_owed;

  // The cache reads at every master clock edge the port is idle, so the
  // grant's edge reads the grant's address; `line_phys` is it, held for the
  // cycle, and every address this port uses after the grant is taken from
  // there and not from `phys`, which is the map's ripple while `MEMSTART` is
  // up.  **AT THE MASTER CLOCK EDGES ALONE, AND NOT AT EVERY IDLE TICK**:
  // `phys` is given the microcycle to settle, so on the ticks between edges
  // the RAMs' address is still moving, and a 7-series block RAM whose
  // address misses setup while it is enabled can have its contents corrupted
  // (UG473; `cadr_microcycle.sv` has the control store's account of the
  // same fault).  Only the grant's edge's read is used, so reading at the
  // edges alone is the same cache.
  logic [PHYS_BITS-1:0] line_phys;
  logic idle;
  assign idle = (state == IDLE || state == REQUESTED);

  // A line as the cache takes it: the words of the fill, revision 13's
  // unpacked from its beats, main memory's 5 bytes each and the window's 4.
  logic [LINE_WORDS*WB-1:0] fill_words;
  logic [WB-1:0] update_word;

  quux_cache #(.WORD_BITS(WORD_BITS)) cache (
      .clk        (clk),
      .rst        (rst),
      .look       (idle && mclk),
      .look_phys  (phys),
      .line_phys  (line_phys),
      .hit        (c_hit),
      .hit_way    (c_hit_way),
      .victim     (c_victim),
      .touch      (c_touch),
      .touch_miss (c_miss),
      .update     (c_update),
      .update_word(update_word),
      .word       (c_word),
      .next_word  (c_next_word),
      .next_line_hit (c_next_line_hit),
      .next_line_word(c_next_line_word),
      .fill       (c_fill),
      .fill_line  (fill_words),
      .invalidate (c_inval),
      .snoop      (c_snoop),
      .snoop_phys (snoop_phys)
  );

  // The way and the victim are the cache's business: it keeps them for the
  // word and the fill.  A line's address has no word in it.
  logic unused_cache;
  assign unused_cache = ^{c_hit_way, c_victim, fill_phys[OFF_BITS-1:0]};

  // The whole cache at the grant after a block-disk register was written.
  assign c_inval = take && (inval_owed || invalidate);

  // A read of main memory decides at the end of its first tick.
  logic decide;
  assign decide   = (state == GRANTED) && first && is_memory;
  assign c_touch  = decide && !write;
  assign c_miss   = !c_hit;
  assign c_update = decide && write;
  // A write into a line the cache holds, as a read of it would bring it
  // back: in the window the field with the unboxed tag.
  assign update_word = window(line_phys) ? from_window(wdata[31:0]) : wdata;

  // --------------------------------------------- the nominal countdowns
  //
  // Over the tick after an edge, `free_in` is how many ticks after that
  // edge main memory is nominally free, and `buf_in` the same for the write
  // buffer: muir's `memory_free_at` and `buffer_free_at`, saturating at
  // zero.  `ack_in` is the cycle's own acknowledgment the same way, and
  // `mack_q` is raised at the edge before it.
  localparam int unsigned CW = 8;
  logic [CW-1:0] free_in, buf_in, ack_in;
  logic [CW-1:0] start_in, done_in, ack_e;
  // A line fill's nominal time, muir's `fill_ns`: revision 13's lines are
  // a tick longer for each beat past two, three in main memory and two in
  // the window.
  logic [CW-1:0] fill_t;
  assign fill_t   = CW'(READ_T) + (!WIDE ? CW'(0) : window(line_phys) ? CW'(2) : CW'(3));
  assign start_in = free_in;
  assign done_in  = start_in + (write ? CW'(WRITE_T) : fill_t);
  // A write is answered after the hit time, or when the buffer's last write
  // is done.  A read hit two ticks after the grant, and a miss when its line
  // is done, which the tick after the lookup settles (`settle`).
  assign ack_e = (buf_in > CW'(HIT_T)) ? buf_in : CW'(HIT_T);
  logic          settle, read_hit_q;
  logic [CW-1:0] done_q;

  // What is really in flight, which the counts never overtake: a miss's
  // line not yet in, a write not yet taken by main memory.
  logic fill_owed, fill_have, wb_valid, wb_sent;
  logic [PHYS_BITS-1:0] wb_phys;
  logic [WB-1:0] wb_word;
  logic [WB-1:0] line_word [LINE_WORDS];
  logic        from_line;
  assign word = (empty || nxm) ? '0
              : dev_cycle      ? WB'(dev_word)
              : from_line      ? line_word[line_phys[OFF_BITS-1:0]] : c_word;

  // A write enters the buffer at its acknowledgment, when the one before it
  // has really gone: the count alone is muir's, the flag is the board's.
  logic ready;
  assign ready = !mem_cycle || !write || !wb_valid;

  // ------------------------------------------------------ the prefetch
  //
  // Past a fetch's word, the next: revision 12 in the fetch's line only;
  // revision 13 in its page, in its line or the next one the cache holds,
  // and never from the window.
  logic        pf_v, pf_fetch_v;
  logic [VADDR_BITS-1:0] pf_vaddr_q, pf_fetch_vaddr_q;
  logic [PHYS_BITS-1:0]  pf_phys;
  logic [WB-1:0]         pf_word;
  logic        pf_same_line, pf_next_ok;
  logic [WB-1:0] pf_same_word;
  assign pf_same_line = line_phys[OFF_BITS-1:0] != '1;
  assign pf_same_word = from_line ? line_word[line_phys[OFF_BITS-1:0] + OFF_BITS'(1)] : c_next_word;
  if (WIDE) begin : g_page_reach
    assign pf_next_ok = !window(line_phys) && (line_phys[9:0] != 10'h3FF)
                     && (pf_same_line || c_next_line_hit);
  end else begin : g_line_reach
    assign pf_next_ok = pf_same_line;
    logic unused_next_line;
    assign unused_next_line = c_next_line_hit ^ (^c_next_line_word);
  end
  always_comb begin
    pf_nx_v           = pf_v;
    pf_nx_vaddr       = pf_vaddr_q;
    pf_nx_phys        = pf_phys;
    pf_nx_word        = pf_word;
    pf_nx_fetch_v     = pf_fetch_v;
    pf_nx_fetch_vaddr = pf_fetch_vaddr_q;
    // A read answered, muir's `read_answered`: past a fetch of the memory
    // bus, the next word of its line or page, or nothing.
    if (state == GRANTED && acked && !write && pf_fetch_v) begin
      pf_nx_fetch_v = 1'b0;
      if (mem_cycle) begin
        pf_nx_v     = pf_next_ok;
        pf_nx_vaddr = pf_fetch_vaddr_q + VADDR_BITS'(1);
        pf_nx_phys  = line_phys + PHYS_BITS'(1);
        pf_nx_word  = pf_same_line ? pf_same_word : c_next_line_word;
      end
    end
    // Dropped by the processor, and by a transfer.
    if (pf_drop || invalidate || inval_owed) pf_nx_v = 1'b0;
    // A store to the word drops it, muir's `request_at` at the grant.
    // **HERE A TICK AFTER THE GRANT**, against the address the cache holds
    // for the cycle (`line_phys`): the grant's own `phys` is the far end of
    // the map, which has the microcycle to settle and not a tick.  The
    // processor drops its view of the word at the grant itself, where it
    // has the microcycle (`cadr_microcycle.sv`, "the prefetch"), and
    // nothing reads the buffer in the tick between: a fill is two ticks
    // after a grant at the soonest.
    if (state == GRANTED && first && write && line_phys == pf_nx_phys) pf_nx_v = 1'b0;
    // A grant, muir's `request_at` and `mark_fetch`: the cycle is a fetch or
    // not.  A read nothing answers is answered in the same tick, which takes
    // the mark again.
    if (take) begin
      pf_nx_fetch_v     = pf_fetch && !empty;
      pf_nx_fetch_vaddr = pf_vaddr;
    end
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      pf_v             <= 1'b0;
      pf_fetch_v       <= 1'b0;
      pf_vaddr_q       <= '0;
      pf_fetch_vaddr_q <= '0;
      pf_phys          <= '0;
      pf_word          <= '0;
    end else begin
      pf_v             <= pf_nx_v;
      pf_fetch_v       <= pf_nx_fetch_v;
      pf_vaddr_q       <= pf_nx_vaddr;
      pf_fetch_vaddr_q <= pf_nx_fetch_vaddr;
      pf_phys          <= pf_nx_phys;
      pf_word          <= pf_nx_word;
    end
  end

  // ---------------------------------------------- the memory controller
  //
  // **THE UNCACHED REQUESTER PASSES STRAIGHT THROUGH** when main memory is
  // idle and nothing of the cache's waits: `mem_*` are the bridge's own
  // wires then, and its answer is main memory's, with no register between.
  // Block-disk's contract fixes the outcome of a transfer and not its time,
  // so its words wait behind a cache operation in flight without moving
  // anything muir holds.  The cache's own operations are registered.
  typedef enum logic [1:0] {M_IDLE, M_BUSY, M_LET_GO, M_THROUGH} mstate_e;
  mstate_e mstate;
  typedef enum logic {OP_WRITE, OP_FILL} op_e;
  op_e op;
  logic [PHYS_BITS-1:0] fill_phys;

  logic go_write, go_fill, go_u, through;
  assign go_write = wb_valid && !wb_sent;
  assign go_fill  = fill_owed && !fill_have && !go_write;
  // The order: the buffer's write, then a line, then the uncached word.
  // Decided here once, for the wires and for the state both.
  assign go_u     = u_req && !go_write && !go_fill;
  // An uncached word goes out from an idle controller, and stays out
  // (`M_THROUGH`) until the bridge and main memory have both let go.
  // Main memory has let go of the last answer whenever the controller is
  // idle (`M_LET_GO` and `M_THROUGH` each wait for it), so an answer here
  // is this word's, and may come in the very tick it is asked.
  assign through  = (mstate == M_THROUGH) || ((mstate == M_IDLE) && go_u);

  logic        mreq_q, mwrite_q, mline_q, mwide_q;
  logic [2:0]  mbeats_q;
  logic [31:0] maddr_q;
  logic [WB-1:0] mwdata_q;

  // **REVISION 13'S UNCACHED WORD IS PACKED STORAGE** (G1 §4.1): block-disk's
  // channel reaches main memory alone (`cadr_xbus_decode.sv`'s `CHANNEL`),
  // word w at byte `BASE13 + 5w`.  A write is the word's five bytes, as the
  // write buffer's are (`mem_wide`); a read is the one or two beats the
  // word's bytes are in, asked as a line from the first beat's address, and
  // the word taken from them at its byte.  Revision 12's is the bridge's
  // word, four bytes at `u_addr`.
  logic [31:0] u_addr13;
  logic [2:0]  u_off13;
  logic        u_line13;
  logic [2:0]  u_beats13;
  logic [WB-1:0] u_word13;
  assign u_addr13  = BASE13 + (32'(u_phys) << 2) + 32'(u_phys);
  assign u_off13   = u_addr13[2:0];
  assign u_line13  = WIDE && !u_write;
  assign u_beats13 = !u_line13 ? 3'd0 : (u_off13 > 3'd3) ? 3'd2 : 3'd1;
  if (WIDE) begin : g_u13
    assign u_word13 = WB'(mem_rline[127:0] >> {u_off13, 3'b000});
    // Every read of revision 13's is a line's.
    logic unused_rdata;
    assign unused_rdata = ^mem_rdata;
  end else begin : g_u12
    assign u_word13 = WB'(mem_rdata);
  end

  assign mem_req   = through ? u_req   : mreq_q;
  assign mem_write = through ? u_write : mwrite_q;
  assign mem_line  = through ? u_line13  : mline_q;
  assign mem_beats = through ? u_beats13 : mbeats_q;
  assign mem_wide  = through ? (WIDE && u_write) : mwide_q;
  assign mem_addr  = through ? (!WIDE ? u_addr : u_write ? u_addr13 : {u_addr13[31:3], 3'b000})
                             : maddr_q;
  assign mem_wdata = through ? WB'(u_wdata) : mwdata_q;
  assign u_done    = through && mem_done;
  assign u_rdata   = u_word13;

  assign c_fill  = (mstate == M_BUSY) && mem_done && (op == OP_FILL);
  assign c_snoop = through && mem_done && u_write && u_main;
  assign snoop_phys = u_phys;
  assign drained = !wb_valid && !fill_owed && (mstate == M_IDLE) && !mem_done;

  // The line's words out of its beats, for the fill standing.
  if (WIDE) begin : g_unpack_13
    for (genvar w = 0; w < LINE_WORDS; w++) begin : g_word
      assign fill_words[WB*w +: WB] = window(fill_phys) ? from_window(mem_rline[32*w +: 32])
                                                        : mem_rline[40*w +: 40];
    end
  end else begin : g_unpack_12
    assign fill_words = mem_rline;
  end

  always_ff @(posedge clk) begin
    if (rst) begin
      state       <= IDLE;
      write       <= 1'b0;
      first       <= 1'b0;
      kmem        <= 1'b0;
      kdev        <= 1'b0;
      elapsed     <= 6'd0;
      dev_word    <= 32'd0;
      nxm         <= 1'b0;
      mack_q      <= 1'b0;
      free_in     <= '0;
      buf_in      <= '0;
      ack_in      <= '0;
      settle      <= 1'b0;
      read_hit_q  <= 1'b0;
      done_q      <= '0;
      fill_owed   <= 1'b0;
      fill_have   <= 1'b0;
      from_line   <= 1'b0;
      wb_valid    <= 1'b0;
      wb_sent     <= 1'b0;
      wb_phys     <= '0;
      wb_word     <= '0;
      inval_owed  <= 1'b0;
      mstate      <= M_IDLE;
      op          <= OP_WRITE;
      fill_phys   <= '0;
      mreq_q      <= 1'b0;
      mwrite_q    <= 1'b0;
      mline_q     <= 1'b0;
      mwide_q     <= 1'b0;
      mbeats_q    <= 3'd0;
      maddr_q     <= 32'd0;
      mwdata_q    <= '0;
      hits        <= 32'd0;
      misses      <= 32'd0;
      for (int w = 0; w < LINE_WORDS; w++) line_word[w] <= '0;
    end else begin
      // The countdowns run on their own.
      if (free_in != '0) free_in <= free_in - 1'b1;
      if (buf_in  != '0) buf_in  <= buf_in  - 1'b1;
      if (ack_in  != '0) ack_in  <= ack_in  - 1'b1;
      mack_q   <= 1'b0;

      if (invalidate) inval_owed <= 1'b1;
      if (take) inval_owed <= 1'b0;

      // The register's word, in the tick it is asked.
      if (dev_rq) dev_word <= dev_rdata;

      unique case (state)
        IDLE, REQUESTED: begin
          if (!n_memrq) begin
            write <= wrcyc;
            if (mclk) begin
              // An address nothing answers is acknowledged in this tick and
              // stands acknowledged from the edge.
              state       <= empty ? ACKED : GRANTED;
              first       <= !empty;
              elapsed     <= 6'd0;
              kmem        <= 1'b0;
              kdev        <= 1'b0;
              nxm         <= empty;
              from_line   <= 1'b0;
            end else begin
              state <= REQUESTED;
            end
          end else if (state == REQUESTED && mclk) begin
            state <= IDLE;
          end
        end

        GRANTED: begin
          first <= 1'b0;
          if (elapsed != 6'h3F) elapsed <= elapsed + 6'd1;
          if (first) begin
            kmem <= is_memory;
            kdev <= is_device && !is_memory;
          end
          settle <= 1'b0;
          if (decide) begin
            // muir's `memory_cycle`, at the grant: the start is when main
            // memory is free, the done a timing after it, and the write
            // buffer is free when its write is done.  A write's arithmetic
            // is all here.  Of a read's only the hit is: the lookup's answer
            // reaches as few registers as it can in the one tick it has, and
            // a miss is settled a tick later from the answer held.
            if (write) begin
              free_in <= done_in - 1'b1;
              buf_in  <= done_in - 1'b1;
              if (ack_e == CW'(HIT_T) && ready) mack_q <= 1'b1;
              else ack_in <= ack_e - 1'b1;
            end else begin
              mack_q     <= c_hit;
              read_hit_q <= c_hit;
              done_q     <= done_in;
              settle     <= 1'b1;
            end
          end else if (settle) begin
            // The read the edge before looked up: `done_q` is counted from
            // the grant, two edges back.
            if (read_hit_q) hits <= hits + 32'd1;
            else begin
              misses    <= misses + 32'd1;
              free_in   <= done_q - CW'(2);
              ack_in    <= done_q - CW'(2);
              fill_owed <= 1'b1;
              fill_have <= 1'b0;
              fill_phys <= line_phys;
              from_line <= 1'b1;
            end
          end else if (mem_cycle && !first && !acked && !mack_q) begin
            // Waiting: for the count, for the line, for the buffer.
            if (ack_in <= CW'(HIT_T) && ready
                && (write || fill_have || c_fill)) begin
              mack_q <= 1'b1;
            end
          end
          if (acked) begin
            state <= ACKED;
            if (mem_cycle && write) begin
              // Into the buffer, at the acknowledgment.
              wb_valid <= 1'b1;
              wb_sent  <= 1'b0;
              wb_phys  <= line_phys;
              wb_word  <= wdata;
            end
          end
        end

        ACKED: begin
          if (n_memrq) state <= IDLE;
        end

        default: state <= IDLE;
      endcase

      // The line, when it comes: its words for the read that missed.
      if (c_fill) begin
        fill_have <= 1'b1;
        for (int w = 0; w < LINE_WORDS; w++) line_word[w] <= fill_words[WB*w +: WB];
      end
      if (state == ACKED && fill_have) begin
        fill_owed <= 1'b0;
        fill_have <= 1'b0;
      end

      // The memory controller: one operation, held until main memory has
      // answered and has let go of its answer.
      unique case (mstate)
        M_IDLE: begin
          if (go_u) begin
            mstate <= M_THROUGH;
          end else if (!mem_done) begin
            if (go_write) begin
              op       <= OP_WRITE;
              mreq_q   <= 1'b1;
              mwrite_q <= 1'b1;
              mline_q  <= 1'b0;
              mbeats_q <= 3'd0;
              // Revision 13's main memory takes the whole word, 5 bytes;
              // the window the field, 4.
              mwide_q  <= WIDE && !window(wb_phys);
              maddr_q  <= word_address(wb_phys);
              mwdata_q <= window(wb_phys) ? WB'(wb_word[31:0]) : wb_word;
              wb_sent  <= 1'b1;
              mstate   <= M_BUSY;
            end else if (go_fill) begin
              op       <= OP_FILL;
              mreq_q   <= 1'b1;
              mwrite_q <= 1'b0;
              mline_q  <= 1'b1;
              mwide_q  <= 1'b0;
              // Two beats, and on revision 13 five of packed storage or
              // four of the window's.
              mbeats_q <= !WIDE ? 3'd2 : window(fill_phys) ? 3'd4 : 3'd5;
              maddr_q  <= line_address(fill_phys);
              mstate   <= M_BUSY;
            end
          end
        end
        M_BUSY: begin
          if (mem_done) begin
            mreq_q <= 1'b0;
            mstate <= M_LET_GO;
            if (op == OP_WRITE) wb_valid <= 1'b0;
          end
        end
        M_THROUGH: begin
          if (!u_req && !mem_done) mstate <= M_IDLE;
        end
        default: begin
          if (!mem_done) mstate <= M_IDLE;
        end
      endcase
    end
  end

endmodule

`default_nettype wire
