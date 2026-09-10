// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack side, held to the property: a block put in DDR by Linux and
// fetched over `S_AXI_HP2` is the block the CADR's own transfer then moves
// into main memory, and a block the CADR wrote is the record the pack side
// writes back.
//
// NO muir REFERENCE EXISTS FOR ANY OF THIS.  `Unit::read_block` is a memcpy
// and nothing in MIT's drawings is an AXI master, so this is
// `tb/cadr_axi_master_tb.cpp`'s situation: the testbench is the stimulus and
// the slave underneath is the observer.  What the pack side is held to:
//
//   THE RECORD IS READ BACK THROUGH THE CONTROLLER, NOT THROUGH ITSELF.  A
//   fetch followed by a write-back of the same slot would round-trip a lane
//   swap, an address rotation or a dropped beat that the two halves made
//   symmetrically.  So every fetched block is READ BY THE CADR --- a transfer
//   through the controller's own channel into a poisoned page --- and
//   compared word for word against what this file put in DDR; and every
//   written-back block was first WRITTEN BY THE CADR from a page this file
//   filled.  The header, the header checkword and the data checkword are
//   read back the same way: through `STATUS<18>`, `<17>` and `<16>|<15>`,
//   which is what the controller makes of each when it is wrong.
//
//   THE DDR IS POISONED, KEYED BY THE STIMULUS.  Every beat nothing wrote
//   reads as a function of its address, never zero, so a fetch from the
//   wrong address, a write-back that landed one burst over, or a pad word
//   that was written all differ from the answer.  The record's words are a
//   function of the address AND the offset, so a wrong offset is a wrong
//   word.  The address is this file's and never the DUT's.
//
//   EXACTLY ONE HANDSHAKE PER CHANNEL PER BURST, the length's worth of
//   beats, WLAST and RLAST where the length says, nine bursts a block ---
//   eight of sixteen and one of two --- and no burst across 4 KB.  The
//   slave in `tb/cadr_pack_side.h` counts all of it, with ready and valid
//   delays that vary so that a master which assumed one shape of handshake
//   fails.
//
//   A REFUSAL IS A REFUSAL: an unaligned address, a slot past the store,
//   two requests in one word, a request while a move is in flight, and a
//   request while the channel is walking each set the refused bit, issue no
//   burst, and move nothing.  The interlock is the last of those, and it is
//   tested with the channel genuinely busy: a Read of a block whose data
//   checkword fails, which is `Ecc::trap`'s 42,946 shifts.
//
//   A SLOT TAKEN AWAY IS WAITED FOR, AND SO IS A WALK THAT MEETS A FILL.
//   A transfer STARTed the moment a fetch of its block begins finds the slot
//   taken away, asks for the block, and reads it whole once the fill's own
//   tag has answered --- neither a miss nor a block half old and half new.
//   The take-away is a request of its own, and a block taken away is asked
//   for again; only a denial makes a miss, and then `store_miss` says so and
//   the status word says so.
//
//   THE DRIVE IS A REGISTER LINUX WRITES.  With nothing present the status
//   reads `0x2321`, the boot PROM's word; a present bit clears three of its
//   bits, the read-only bit sets `<7>`, and the timed bit is what makes a
//   seek take the drive's own time.
//
//   AND AN ERROR RESPONSE IS REPORTED, ONCE.  A burst answered SLVERR sets
//   the error bit for that move, and the next clean move clears it.
//
//   THE REQUEST PATH, WITH A LINUX SLOWER THAN THE DRIVE.  A transfer of a
//   block the store lacks posts the block's disk address in REQ, raises the
//   interrupt, and WAITS: the drive's time is charged and the fill is
//   withheld for longer than the access time, and at every sample of the
//   wait BUSY is up, not-active and the interrupt request are down, the
//   destination page is still its poison and nothing is dirty.  When the
//   block is fetched the transfer completes as if it had been there, the
//   page compared word for word, and it ends within a stated number of
//   ticks of the tag landing --- the same walk an unstalled Read makes,
//   measured in the same run, plus the lookup's own restart.  A denial
//   ends the wait the other way, with `store_miss` and the page untouched.
//
//   THE NEXT BLOCK IS ASKED FOR BEFORE THE CURRENT ONE MOVES.  A chained
//   list whose second block is absent posts that block while the first
//   block's page is still poison, and the transfer completes when it is
//   given.  THE UNIT IS PART OF THE TAG: one cylinder, head and block on
//   two drives are two blocks, and a Read from each gets its own.  DIRTY
//   and REF say what a transfer did to which slot, and the three interrupt
//   events are set by the fabric and cleared by writing ones.
//
//   THE INTERLOCK IS PER SLOT.  During a walk a move on the walk's slot is
//   refused and a move on any other slot is taken and completes.
//
//   EVERY ADDRESS ON GP0 IS ANSWERED, in the window and out of it: a read
//   nothing answers hangs the Arm rather than faulting it.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <set>
#include <vector>

#include "Vcadr_disk_harness.h"
#include "cadr_pack_side.h"
#include "verilated.h"

using namespace pack_side;

namespace {

const unsigned REGS = 017377774u;   // `disk_controller::REGS`, a word address
const unsigned CLP = 0x1000u;       // where the command lists go, 0o10000
const int SLOTS = 24;
const long WALK_CAP = 1 << 20;

// The geometry, so that tags name blocks the drive has.
const unsigned CYLINDERS = 815, HEADS = 19, BPT = 17;

long tick = 0;
int bad = 0;
const char *phase = "startup";

void Fail(const char *what, unsigned long long got, unsigned long long want) {
  std::fprintf(stderr, "tick %ld [%s]: %s is 0x%llx, expected 0x%llx\n", tick,
               phase, what, got, want);
  ++bad;
}
void Say(const char *what) {
  std::fprintf(stderr, "tick %ld [%s]: %s\n", tick, phase, what);
  ++bad;
}

// A word of a record, a function of the block's address and the offset.
uint32_t rec_word(uint64_t at, int i) {
  const uint32_t a = (uint32_t)(at >> 7);
  return a * 0x9E3779B1u ^ (uint32_t)i * 0x85EBCA6Bu ^ (a ^ (uint32_t)i) * 0xC2B2AE35u ^ 0x3C5A0F96u;
}
// A word of a page, likewise.
uint32_t page_word(unsigned page, int i) {
  return page * 0x27D4EB2Fu ^ (uint32_t)i * 0x165667B1u ^ 0xA5A55A5Au;
}
// Unit 0's tag, which is what most of this file names blocks by; the two-unit
// case below uses `pack_side::tag_of` with the unit.
uint32_t tag_of(unsigned c, unsigned h, unsigned b) {
  return pack_side::tag_of(0, c, h, b);
}
// `header_of`, with the next-block code in <31:30>.  The header carries no
// unit: it is the sector's own, and one pack's sector does not know which
// cable it is on.
uint32_t header_of(unsigned c, unsigned h, unsigned b) {
  unsigned code = (b + 1 < BPT) ? 0 : (h + 1 < HEADS) ? 1 : (c + 1 < CYLINDERS) ? 2 : 3;
  return code << 30 | tag_of(c, h, b);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  auto *dut = new Vcadr_disk_harness;

  Ddr ddr;
  Hp2Slave hp2;
  hp2.ddr = &ddr;
  hp2.vary = true;
  hp2.complain = [](const char *w) { Say(w); };
  Gp0Master gp0;
  gp0.vary = true;
  gp0.complain = [](const char *w) { Say(w); };

  // Main memory, as the CADR's side of the channel: the pack side never
  // touches this.  Two million words, as the trace's machine has.
  std::vector<uint32_t> mem(1u << 21, 0u);

  // ---- the driver ----------------------------------------------------------
  int d_sel = 0, d_rq = 0, d_wr = 0, d_rst = 1;
  unsigned d_phys = 0, d_wdata = 0;
  int live_sel = 0, live_reg = -1;
  long ch_up = -1, ch_serial = 0;
  int ch_served = 0;
  long ch_reads = 0, ch_writes = 0;
  unsigned sampled = 0;
  int miss_now = 0;
  long miss_rises = 0;
  // The request path, watched at the harness's pins tick by tick: when REQ
  // last became valid and last fell, how many ticks the walk stood waiting,
  // how many ticks the interrupt line was up.
  long req_rise_tick = -1, req_fall_tick = -1, req_rises = 0;
  long waiting_ticks = 0, irq_ticks = 0;
  int req_now = 0;

  auto run_tick = [&](bool sample) {
    dut->rst = d_rst;
    dut->xbus_init = 0;
    dut->sel = d_sel;
    dut->dev_rq = d_rq;
    dut->dev_write = d_wr;
    dut->phys = d_phys;
    dut->wdata = d_wdata;
    dut->clk = 0;
    dut->eval();
    if (sample) sampled = dut->rdata;
    // The channel, answered after the request has stood a tick or three.
    dut->ch_done = 0;
    dut->ch_nxm = 0;
    if (!dut->ch_req) {
      ch_up = -1;
      ch_served = 0;
    } else {
      if (ch_up < 0) ch_up = tick;
      const long lat = 1 + (ch_serial % 3);
      if (!ch_served && tick - ch_up >= lat) {
        ch_served = 1;
        ++ch_serial;
        const unsigned a = dut->ch_addr;
        if (a >= mem.size()) dut->ch_nxm = 1;
        else if (dut->ch_write) { mem[a] = dut->ch_wdata; ++ch_writes; }
        else { dut->ch_rdata = mem[a]; ++ch_reads; }
        dut->ch_done = 1;
      }
    }
    if (d_rst) hp2.reset(dut); else hp2.drive(dut);
    dut->eval();
    hp2.sample(dut);
    const int miss_before = dut->store_miss;
    dut->clk = 1;
    dut->eval();
    if (!d_rst) hp2.after_edge(dut);
    if (dut->store_miss && !miss_before) ++miss_rises;
    miss_now = dut->store_miss;
    if (dut->req_valid && !req_now) { req_rise_tick = tick; ++req_rises; }
    if (!dut->req_valid && req_now) req_fall_tick = tick;
    req_now = dut->req_valid;
    if (dut->ch_waiting) ++waiting_ticks;
    if (dut->irq) ++irq_ticks;
    ++tick;
    live_sel = d_sel;
    live_reg = d_sel ? (int)(d_phys & 3u) : -1;
    if (d_sel && (d_phys >> 2) != (REGS >> 2)) live_reg = -1;
  };
  auto tick_fn = [&]() { run_tick(false); };

  gp0.quiet(dut);
  for (int i = 0; i < 8; ++i) run_tick(false);
  d_rst = 0;
  for (int i = 0; i < 4; ++i) run_tick(false);

  // The Xbus face, as `tb/cadr_disk_tb.cpp` drives it.
  auto do_read = [&](int reg) -> unsigned {
    if (!(live_sel && live_reg == reg)) {
      d_sel = 1; d_rq = 1; d_wr = 0; d_phys = REGS | (unsigned)reg;
      run_tick(false);
    }
    d_sel = 1; d_rq = 1; d_wr = 0; d_phys = REGS | (unsigned)reg;
    run_tick(true);
    return sampled;
  };
  // Four ticks: the address a tick ahead, the request, and the two ticks the
  // controller holds the store for --- see `rtl/cadr_disk_controller.sv`.
  auto do_write = [&](int reg, unsigned v) {
    d_sel = 1; d_rq = 0; d_wr = 1; d_phys = REGS | (unsigned)reg; d_wdata = v;
    run_tick(false);
    d_rq = 1;
    run_tick(false);
    run_tick(false);
    run_tick(false);
  };
  auto bus_idle = [&]() { d_rq = 0; run_tick(false); };
  long walk_end = -1;   // the first tick `ch_active` read low in the last settle
  auto settle_walk = [&]() -> bool {
    d_rq = 0;
    const long began = tick;
    while (dut->ch_active) {
      run_tick(false);
      if (tick - began > WALK_CAP) {
        Say("the channel was still walking at the cap");
        std::fprintf(stderr, "  waiting=%d req_valid=%d req_tag=%08x store_miss=%d\n",
                     (int)dut->ch_waiting, (int)dut->req_valid, (unsigned)dut->req_tag, (int)dut->store_miss);
        return false;
      }
    }
    walk_end = tick;
    for (int q = 0; q < 4; ++q) run_tick(false);
    return true;
  };
  // A whole command: the four stores MIT's own sequence makes.
  auto command = [&](unsigned code, unsigned clp, unsigned da) {
    do_write(0, code);
    do_write(1, clp);
    do_write(2, da);
    do_write(3, 0);
    settle_walk();
  };
  auto ccw = [&](unsigned clp, unsigned page) { mem[clp] = (page << 8) & 0x003fff00u; };
  auto fill_page = [&](unsigned page) {
    for (int i = 0; i < 256; ++i) mem[page * 256u + i] = page_word(page, i);
  };
  auto page_is = [&](unsigned page, std::function<uint32_t(int)> want, const char *what) -> bool {
    for (int i = 0; i < 256; ++i)
      if (mem[page * 256u + i] != want(i)) {
        char msg[128];
        std::snprintf(msg, sizeof msg, "%s: page %x word %d", what, page, i);
        Fail(msg, mem[page * 256u + i], want(i));
        return false;
      }
    return true;
  };

  // The pack side's registers.
  auto reg_write = [&](unsigned r, uint32_t v, unsigned strb = 0xF) {
    gp0.write(dut, tick_fn, REG_BASE + 4 * r, v, strb);
  };
  auto reg_read = [&](unsigned r) -> uint32_t { return gp0.read(dut, tick_fn, REG_BASE + 4 * r); };
  // A move is nine bursts of registered beats, some 650 ticks at the slave's
  // slowest, and a poll here is a handful of ticks: the cap is well past a
  // move that is merely slow and well short of one that never ends.
  auto wait_done = [&](const char *what) -> uint32_t {
    uint32_t st = 0;
    for (int n = 0; n < 2000; ++n) {
      st = reg_read(R_CTL);
      if (!(st & ST_BUSY)) return st;
    }
    Say(what);
    Say("the pack side stayed busy");
    return st;
  };
  auto go = [&](uint64_t at, uint32_t tag, unsigned slot, unsigned ctl) -> uint32_t {
    reg_write(R_ADDR, (uint32_t)at);
    reg_write(R_TAG, tag);
    reg_write(R_SLOT, slot);
    reg_write(R_CTL, ctl);
    return reg_read(R_CTL);
  };
  auto fetch = [&](uint64_t at, uint32_t tag, unsigned slot, const char *what) -> uint32_t {
    const long b0 = hp2.bursts;
    uint32_t st = go(at, tag, slot, CTL_FETCH);
    if (st & ST_REFUSED) { Say(what); Say("a fetch was refused"); }
    st = wait_done(what);
    if (!(st & ST_DONE)) { Say(what); Fail("done after a fetch", st, ST_DONE); }
    if (hp2.bursts - b0 != 9) { Say(what); Fail("bursts a fetch made", hp2.bursts - b0, 9); }
    return st;
  };
  auto writeback = [&](uint64_t at, unsigned slot, const char *what) -> uint32_t {
    const long b0 = hp2.bursts;
    uint32_t st = go(at, 0, slot, CTL_WRITE);
    if (st & ST_REFUSED) { Say(what); Say("a write-back was refused"); }
    st = wait_done(what);
    if (!(st & ST_DONE)) { Say(what); Fail("done after a write-back", st, ST_DONE); }
    if (hp2.bursts - b0 != 9) { Say(what); Fail("bursts a write-back made", hp2.bursts - b0, 9); }
    return st;
  };

  uint32_t seed = 0x20260910u;
  std::set<uint64_t> used;
  // A fresh record address: 128-aligned, spread over bits 7..27, never
  // within a record of another.
  auto fresh = [&]() -> uint64_t {
    for (;;) {
      uint64_t at = 0x02000000ull | ((uint64_t)(lcg(seed) & 0x1FFFFFu) << 7);
      bool clash = false;
      for (uint64_t u : used) if (u < at + 1040 && at < u + 1040) clash = true;
      if (!clash) { used.insert(at); return at; }
    }
  };
  auto place = [&](uint64_t at, uint32_t header, uint32_t hck, uint32_t dck) {
    uint32_t w[RECORD_WORDS];
    for (int i = 0; i < 256; ++i) w[i] = rec_word(at, i);
    w[256] = header; w[257] = hck; w[258] = dck;
    ddr.place(at, w);
  };
  auto good_hck = [&](uint32_t header) { return ecc_over_words(&header, 1); };
  auto good_dck = [&](uint64_t at) {
    uint32_t w[256];
    for (int i = 0; i < 256; ++i) w[i] = rec_word(at, i);
    return ecc_over_words(w, 256);
  };

  long fetches = 0, writebacks = 0, reads_compared = 0, meta_errors = 0;
  long refusals = 0, misses_expected = 0, error_moves = 0, waits_expected = 0;
  long fills_beside_a_walk = 0, requests_served = 0, stall_samples = 0;
  long prefetches = 0, denials = 0, unit_reads = 0;
  long stall_ticks_measured = 0, stall_tail = 0, walk_ref = 0;

  // ========================================================================
  phase = "the registers";
  {
    uint32_t id = reg_read(R_IDENT);
    if (id != IDENT) Fail("IDENT", id, IDENT);
    if (gp0.last_resp != 0) Fail("the response to a read in the window", gp0.last_resp, 0);
    (void)gp0.read(dut, tick_fn, REG_BASE + 0x100);
    if (gp0.last_resp != 2) Fail("the response to a read outside the window", gp0.last_resp, 2);
    gp0.write(dut, tick_fn, REG_BASE + 0x200, 0xDEADBEEFu);
    if (gp0.last_resp != 2) Fail("the response to a write outside the window", gp0.last_resp, 2);
    reg_write(R_ADDR, 0x12345680u);
    reg_write(R_TAG, 0x0ABCDEF1u);
    reg_write(R_SLOT, 0x17u);
    if (reg_read(R_ADDR) != 0x12345680u) Fail("ADDR read back", reg_read(R_ADDR), 0x12345680u);
    if (reg_read(R_TAG) != 0x0ABCDEF1u) Fail("TAG read back", reg_read(R_TAG), 0x0ABCDEF1u);
    if (reg_read(R_SLOT) != 0x17u) Fail("SLOT read back", reg_read(R_SLOT), 0x17u);
    // Byte strobes: one lane written, the others kept.
    reg_write(R_DRIVE, 0x00010101u);
    reg_write(R_DRIVE, 0x00000000u, 0x2);
    if (reg_read(R_DRIVE) != 0x00010001u) Fail("DRIVE after a one-lane write", reg_read(R_DRIVE), 0x00010001u);
    reg_write(R_DRIVE, 0);
    uint32_t st = reg_read(R_CTL);
    if (st != 0) Fail("the status word at rest", st, 0);
    // The cache's registers at rest, and the mask read back.
    if (reg_read(R_REQ) != 0) Fail("REQ at rest", reg_read(R_REQ), 0);
    if (reg_read(R_DIRTY) != 0) Fail("DIRTY at rest", reg_read(R_DIRTY), 0);
    if (reg_read(R_REF) != 0) Fail("REF at rest", reg_read(R_REF), 0);
    if (reg_read(R_IRQ) != 0) Fail("IRQ at rest", reg_read(R_IRQ), 0);
    if (reg_read(R_IRQEN) != 0) Fail("IRQEN at rest", reg_read(R_IRQEN), 0);
    reg_write(R_IRQEN, 0x5);
    if (reg_read(R_IRQEN) != 0x5) Fail("IRQEN read back", reg_read(R_IRQEN), 0x5);
    reg_write(R_IRQEN, 0);
    // TAG takes all thirty-one bits, the unit among them, and bit 31 is not
    // a bit of it.
    reg_write(R_TAG, 0xFFFFFFFFu);
    if (reg_read(R_TAG) != 0x7FFFFFFFu) Fail("TAG's width", reg_read(R_TAG), 0x7FFFFFFFu);
    // **EVERY ADDRESS ON GP0 IS ANSWERED.**  Past the window, at the top of
    // the port's gigabyte, and in the middle: each completes, with SLVERR.
    // A read that did not complete would be the master's guard firing,
    // "a register read did not complete", and on the board both Arm cores
    // frozen.
    const uint32_t far[] = {REG_BASE + 0x40, REG_BASE + 0x1000, 0x7FFFFFFCu, 0x5A5A5A58u};
    for (uint32_t a : far) {
      (void)gp0.read(dut, tick_fn, a);
      if (gp0.last_resp != 2) Fail("the response to a read outside the window", gp0.last_resp, 2);
      gp0.write(dut, tick_fn, a, 0xDEADBEEFu);
      if (gp0.last_resp != 2) Fail("the response to a write outside the window", gp0.last_resp, 2);
    }
  }

  // ========================================================================
  phase = "the drive seam";
  {
    unsigned s = do_read(0);
    if (s != 0x2321u) Fail("the status with nothing on the cable", s, 0x2321u);
    reg_write(R_DRIVE, 0x00000001u);          // a drive on unit 0
    // Not on line, not on cylinder and no unit selected all clear;
    // not-active, and --- CMD2 low, no fault, no seek error --- no lossage
    // either.  The block counter in <31:24> is live now that a spindle is
    // turning, and is the drive's business rather than this check's.
    s = do_read(0) & 0x00FFFFFFu;
    if (s != 0x0001u) Fail("the status with a drive on unit 0", s, 0x0001u);
    reg_write(R_DRIVE, 0x00000101u);          // and its read-only switch
    s = do_read(0) & 0x00FFFFFFu;
    if (s != 0x0081u) Fail("the status with the read-only switch on", s, 0x0081u);
    reg_write(R_DRIVE, 0x00010001u);          // time charged
    // A seek of one cylinder: busy for the drive's own time.
    do_write(0, 04);
    do_write(2, tag_of(1, 0, 0));
    do_write(3, 0);
    s = do_read(0);
    if (s & 1u) Fail("not-active right after a timed seek", s, 0);
    do_write(0, 016);                          // Reset stops it
    do_write(0, 0);
    s = do_read(0);
    if (!(s & 1u)) Fail("not-active after the Reset", s, 1);
    reg_write(R_DRIVE, 0x00000001u);          // present, writable, untimed
    do_write(0, 04);
    do_write(2, tag_of(0, 0, 0));
    do_write(3, 0);
    s = do_read(0);
    if (!(s & 1u)) Fail("not-active right after an untimed seek", s, 1);
    do_write(0, 05);                           // at ease, the attention gone
    do_write(3, 0);
    bus_idle();
  }

  // ========================================================================
  phase = "fetch, and the CADR reads it back";
  struct Held { uint64_t at; unsigned c, h, b, slot; };
  std::vector<Held> held;
  {
    std::set<unsigned> slots_used;
    for (int n = 0; n < 12; ++n) {
      unsigned c = lcg(seed) % CYLINDERS, h = lcg(seed) % HEADS, b = lcg(seed) % BPT;
      // No two blocks alike, or a slot lookup has two answers.
      bool dup = false;
      for (const Held &x : held) if (x.c == c && x.h == h && x.b == b) dup = true;
      if (dup) { --n; continue; }
      unsigned slot;
      do slot = lcg(seed) % SLOTS; while (slots_used.count(slot));
      slots_used.insert(slot);
      const uint64_t at = fresh();
      const uint32_t hdr = header_of(c, h, b);
      place(at, hdr, good_hck(hdr), good_dck(at));
      fetch(at, tag_of(c, h, b), slot, "a plain fetch");
      ++fetches;
      held.push_back({at, c, h, b, slot});
    }
    // Every one read back by the CADR into a poisoned page.
    for (size_t n = 0; n < held.size(); ++n) {
      const Held &x = held[n];
      const unsigned page = 0x40u + (unsigned)n;
      fill_page(page);
      ccw(CLP, page);
      command(00, CLP, tag_of(x.c, x.h, x.b));
      unsigned s = do_read(0);
      if (s & 0x007fc000u) Fail("an error bit after a Read of a fetched block", s, 0);
      unsigned da = do_read(2);
      if (da != tag_of(x.c, x.h, x.b)) Fail("the disk address after the Read", da, tag_of(x.c, x.h, x.b));
      if (page_is(page, [&](int i) { return rec_word(x.at, i); }, "a Read of a fetched block"))
        ++reads_compared;
      bus_idle();
    }
  }

  // ========================================================================
  phase = "the three words after the block";
  {
    const unsigned page = 0x60u;
    struct Case { const char *what; unsigned bit; int which; };
    const Case cases[] = {
        {"a header naming another block", 18, 0},
        {"a header checkword that does not check", 17, 1},
        {"a data checkword that does not check", 16, 2},
    };
    for (const Case &k : cases) {
      const unsigned c = 100 + k.bit, h = 3, b = 7;
      const uint64_t at = fresh();
      const uint32_t hdr = header_of(c, h, b);
      uint32_t header = hdr, hck = good_hck(hdr), dck = good_dck(at);
      if (k.which == 0) header = hdr ^ 0x00000010u;       // block 7 says 23
      if (k.which == 1) hck ^= 0x00400000u;
      if (k.which == 2) dck ^= 0x00000001u ^ 0x80000000u ^ 0x00008000u;
      place(at, header, hck, dck);
      fetch(at, tag_of(c, h, b), 20, k.what);
      ++fetches;
      fill_page(page);
      ccw(CLP, page);
      command(00, CLP, tag_of(c, h, b));
      unsigned s = do_read(0);
      const unsigned want = (k.which == 2) ? ((1u << 16) | (1u << 15)) : (1u << k.bit);
      if (!(s & want)) { Say(k.what); Fail("the status bit for it", s & 0x007fc000u, want); }
      else ++meta_errors;
      if (!(s & (1u << 13))) { Say(k.what); Fail("transfer aborted", s, 1u << 13); }
      page_is(page, [&](int i) { return page_word(page, i); }, "a page a stopped transfer must not touch");
      do_write(0, 0);   // -RESET ERR
      bus_idle();
    }
  }

  // ========================================================================
  phase = "the CADR writes, and the pack side writes it back";
  {
    for (size_t n = 0; n < 4; ++n) {
      const Held &x = held[n];
      const unsigned page = 0x80u + (unsigned)n;
      fill_page(page);
      ccw(CLP, page);
      command(011, CLP, tag_of(x.c, x.h, x.b));
      unsigned s = do_read(0);
      if (s & 0x007fc000u) Fail("an error bit after a Write", s, 0);
      bus_idle();
      const uint64_t to = fresh();
      const uint32_t pad_before = ddr.pad(to);
      writeback(to, x.slot, "a write-back");
      ++writebacks;
      uint32_t got[RECORD_WORDS];
      ddr.record(to, got);
      uint32_t pw[256];
      for (int i = 0; i < 256; ++i) pw[i] = page_word(page, i);
      const uint32_t hdr = header_of(x.c, x.h, x.b);
      for (int i = 0; i < 256; ++i)
        if (got[i] != pw[i]) { Fail("a word of the record written back", got[i], pw[i]); std::fprintf(stderr, "  word %d\n", i); break; }
      if (got[256] != hdr) Fail("the header written back", got[256], hdr);
      if (got[257] != good_hck(hdr)) Fail("the header checkword written back", got[257], good_hck(hdr));
      const uint32_t dck = ecc_over_words(pw, 256);
      if (got[258] != dck) Fail("the data checkword written back", got[258], dck);
      if (ddr.pad(to) != pad_before) Fail("the pad after the record", ddr.pad(to), pad_before);
      // And the original record, at the address it was fetched from, is as
      // it was: a write-back goes where it is sent and nowhere else.
      uint32_t orig[RECORD_WORDS];
      ddr.record(x.at, orig);
      for (int i = 0; i < 256; ++i)
        if (orig[i] != rec_word(x.at, i)) { Fail("the record the block was fetched from", orig[i], rec_word(x.at, i)); break; }
    }
    // The strobes: every beat whole but the record's last, whose high half
    // is the pad.
    long whole = 0, half = 0, other = 0;
    for (unsigned s : hp2.strobes) { if (s == 0xFF) ++whole; else if (s == 0x0F) ++half; else ++other; }
    if (half != writebacks) Fail("half-strobed beats, one a write-back", half, writebacks);
    if (whole != writebacks * 129) Fail("whole beats, 129 a write-back", whole, writebacks * 129);
    if (other) Fail("beats with some other strobe", other, 0);
  }

  // ========================================================================
  phase = "an error response";
  {
    const Held &x = held[5];
    hp2.refuse_burst = hp2.bursts + 4;
    uint32_t st = fetch(x.at, tag_of(x.c, x.h, x.b), x.slot, "a fetch the port refuses one burst of");
    if (!(st & ST_ERROR)) Fail("the error bit after SLVERR", st, ST_ERROR);
    else ++error_moves;
    hp2.refuse_burst = -1;
    st = fetch(x.at, tag_of(x.c, x.h, x.b), x.slot, "the fetch after it");
    if (st & ST_ERROR) Fail("the error bit after a clean fetch", st, 0);
    ++fetches;
  }

  // ========================================================================
  phase = "refusals";
  {
    const long b0 = hp2.bursts;
    uint32_t st = go(fresh() + 64, 0x00010203u, 21, CTL_FETCH);
    if (!(st & ST_REFUSED)) Fail("refused, an unaligned address", st, ST_REFUSED); else ++refusals;
    st = go(fresh(), 0x00010203u, SLOTS, CTL_FETCH);
    if (!(st & ST_REFUSED)) Fail("refused, a slot past the store", st, ST_REFUSED); else ++refusals;
    st = go(fresh(), 0x00010203u, 21, CTL_FETCH | CTL_WRITE);
    if (!(st & ST_REFUSED)) Fail("refused, two requests in one word", st, ST_REFUSED); else ++refusals;
    if (hp2.bursts != b0) Fail("bursts a refused request made", hp2.bursts - b0, 0);
    // A request while one is in flight.
    const Held &x = held[6];
    reg_write(R_ADDR, (uint32_t)x.at);
    reg_write(R_TAG, tag_of(x.c, x.h, x.b));
    reg_write(R_SLOT, x.slot);
    reg_write(R_CTL, CTL_FETCH);
    reg_write(R_CTL, CTL_FETCH);
    st = reg_read(R_CTL);
    if (!(st & ST_BUSY)) Fail("busy during a fetch", st, ST_BUSY);
    if (!(st & ST_REFUSED)) Fail("refused, a request while busy", st, ST_REFUSED); else ++refusals;
    st = wait_done("the fetch under the refused request");
    if (hp2.bursts != b0 + 9) Fail("bursts: the one fetch and no more", hp2.bursts - b0, 9);
    ++fetches;
    // And while the channel is walking: a Read of a block whose data
    // checkword fails keeps the channel busy for `Ecc::trap`'s shifts.
    const unsigned c = 200, h = 5, b = 11;
    const uint64_t at = fresh();
    const uint32_t hdr = header_of(c, h, b);
    place(at, hdr, good_hck(hdr), good_dck(at) ^ 0x00010001u);
    fetch(at, tag_of(c, h, b), 22, "the block whose checkword fails");
    ++fetches;
    fill_page(0x90);
    ccw(CLP, 0x90);
    do_write(0, 00);
    do_write(1, CLP);
    do_write(2, tag_of(c, h, b));
    do_write(3, 0);
    d_rq = 0;
    for (int q = 0; q < 2000; ++q) run_tick(false);
    if (!dut->ch_active) Say("the channel was not walking when the interlock was tested");
    // **PER SLOT.**  A fetch into another slot is taken, completes under
    // the walk, and its block reads back afterwards; a fetch into the slot
    // the walk is on --- 22 --- is refused.  Asked in that order so that a
    // refusal compared the wrong way round and a refusal that never comes
    // fail on different lines.
    const long b1 = hp2.bursts;
    st = go(held[7].at, tag_of(held[7].c, held[7].h, held[7].b), held[7].slot, CTL_FETCH);
    if (!(st & ST_CH_ACTIVE)) Fail("ch_active in the status word during a walk", st, ST_CH_ACTIVE);
    if (st & ST_REFUSED) Fail("refused, a request on another slot during a walk", st, 0);
    if (!dut->ch_active) Say("the walk ended before the fetch beside it was asked for");
    st = wait_done("the fetch beside a walk");
    if (!(st & ST_DONE)) Fail("done after a fetch beside a walk", st, ST_DONE);
    if (hp2.bursts != b1 + 9) Fail("bursts of the fetch beside a walk", hp2.bursts - b1, 9);
    ++fetches;
    if (!dut->ch_active) Say("the walk ended before the fetch beside it did");
    ++fills_beside_a_walk;
    st = go(held[7].at, tag_of(held[7].c, held[7].h, held[7].b), 22, CTL_FETCH);
    if (!(st & ST_REFUSED)) Fail("refused, a request on the walk's own slot", st, ST_REFUSED); else ++refusals;
    if (hp2.bursts != b1 + 9) Fail("bursts a refused request on the walk's slot made", hp2.bursts - b1 - 9, 0);
    settle_walk();
    unsigned s = do_read(0);
    if (!(s & ((1u << 16) | (1u << 15)))) Fail("the checkword error the walk was busy with", s, 1u << 16);
    do_write(0, 0);
    bus_idle();
    // And the block fetched beside the walk reads back whole.
    fill_page(0x91);
    ccw(CLP, 0x91);
    command(00, CLP, tag_of(held[7].c, held[7].h, held[7].b));
    if (page_is(0x91, [&](int i) { return rec_word(held[7].at, i); }, "a Read of the block fetched beside a walk"))
      ++reads_compared;
    bus_idle();
  }

  // ========================================================================
  phase = "a walk that meets a fill";
  {
    // Block Y is in slot s; block X is fetched into s and a Read of X is
    // STARTed as the fill begins.  The walk defers while the pack side is
    // moving, then finds X in the slot and reads it whole; a controller that
    // walked anyway would find the slot taken away and miss.
    const Held &y = held[8];
    const unsigned c = 300, h = 2, b = 4;
    const uint64_t at = fresh();
    const uint32_t hdr = header_of(c, h, b);
    place(at, hdr, good_hck(hdr), good_dck(at));
    if (miss_now) Say("store_miss was up before the mid-fill case");
    const unsigned page = 0xA0;
    fill_page(page);
    ccw(CLP, page);
    do_write(0, 00);
    do_write(1, CLP);
    do_write(2, tag_of(c, h, b));
    bus_idle();
    hp2.vary = false;   // a fixed, slow fill, so the START lands inside it
    hp2.fixed_ready = 2;
    reg_write(R_ADDR, (uint32_t)at);
    reg_write(R_TAG, tag_of(c, h, b));
    reg_write(R_SLOT, y.slot);
    reg_write(R_CTL, CTL_FETCH);
    ++fetches;
    const long started = tick;
    do_write(3, 0);                              // START, two ticks later
    settle_walk();
    uint32_t st = reg_read(R_CTL);
    if (st & ST_BUSY) Say("the walk ended before the fill it met");
    if (miss_now) Say("a walk that met a fill missed instead of waiting");
    if (st & ST_STORE_MISS) Fail("store_miss in the status word", st, 0);
    if (page_is(page, [&](int i) { return rec_word(at, i); }, "the Read that met the fill"))
      ++reads_compared;
    // And it waited: a fill is some three hundred ticks and a Read of one
    // block some sixty, so a walk that did not defer ends long before this.
    if (tick - started < 300) Fail("ticks from the go to the walk's end", tick - started, 300);
    ++waits_expected;
    unsigned s = do_read(0);
    if (!(s & 1u)) Fail("not-active after the Read that met the fill", s, 1);
    if (s & 0x007fc000u) Fail("an error bit after the Read that met the fill", s, 0);
    // The walk found the slot taken away and asked for the block, and the
    // fill's own tag answered the request: REQ was valid for a while and is
    // not now, and the walk stood waiting.
    if (req_rise_tick < started) Fail("REQ posted by the walk that met the fill", 0, 1);
    if (req_now) Fail("REQ still valid after the fill answered it", reg_read(R_REQ), 0);
    if (waiting_ticks == 0) Say("the walk that met the fill never stood waiting");
    hp2.vary = true;
    // And Y is gone from the store: a Read of it waits and asks for it, and
    // given back --- into slot 20, not the slot it left --- it reads.
    fill_page(page);
    ccw(CLP, page);
    do_write(0, 00);
    do_write(1, CLP);
    do_write(2, tag_of(y.c, y.h, y.b));
    do_write(3, 0);
    d_rq = 0;
    for (int q = 0; q < 200; ++q) run_tick(false);
    if (!dut->ch_active) Say("the Read of the block the fill displaced did not wait");
    if (reg_read(R_REQ) != (REQ_VALID | tag_of(y.c, y.h, y.b))) Fail("REQ for the block the fill displaced", reg_read(R_REQ), REQ_VALID | tag_of(y.c, y.h, y.b));
    page_is(page, [&](int i) { return page_word(page, i); }, "the page during the wait for the block the fill displaced");
    fetch(y.at, tag_of(y.c, y.h, y.b), 20, "the fetch that gives the displaced block back");
    ++fetches;
    ++requests_served;
    settle_walk();
    if (page_is(page, [&](int i) { return rec_word(y.at, i); }, "a Read of the block the fill displaced, given back")) ++reads_compared;
    do_write(0, 0);
    bus_idle();
  }

  // ========================================================================
  phase = "a slot taken away";
  {
    // The controller is reset --- the miss below is the first this run
    // expects, and it is sticky --- and the drive register comes back with
    // it.
    d_rst = 1;
    for (int i = 0; i < 4; ++i) run_tick(false);
    d_rst = 0;
    for (int i = 0; i < 4; ++i) run_tick(false);
    if (miss_now) Say("store_miss survived the reset");
    reg_write(R_DRIVE, 0x00000001u);
    const Held &x = held[9];
    place(x.at, header_of(x.c, x.h, x.b), good_hck(header_of(x.c, x.h, x.b)), good_dck(x.at));
    fetch(x.at, tag_of(x.c, x.h, x.b), x.slot, "a fetch after the reset");
    ++fetches;
    const unsigned page = 0xB0;
    fill_page(page);
    ccw(CLP, page);
    command(00, CLP, tag_of(x.c, x.h, x.b));
    if (page_is(page, [&](int i) { return rec_word(x.at, i); }, "a Read after the reset")) ++reads_compared;
    const long b0 = hp2.bursts;
    uint32_t st = go(0, 0, x.slot, CTL_TAKE);
    st = wait_done("the take-away");
    if (!(st & ST_DONE)) Fail("done after a take-away", st, ST_DONE);
    if (hp2.bursts != b0) Fail("bursts a take-away made", hp2.bursts - b0, 0);
    // **A READ OF A BLOCK THE STORE LACKS WAITS FOR IT.**  The walk posts
    // the block's address, the interrupt says so, and the transfer stands
    // --- BUSY, nothing moved --- until the block is fetched, into ANY slot:
    // it goes into slot 21 here, not the one it left.
    reg_write(R_IRQEN, IRQ_REQ | IRQ_DIRTY | IRQ_DONE);
    reg_write(R_IRQ, 0x7);
    const long irq0 = irq_ticks;
    fill_page(page);
    ccw(CLP, page);
    do_write(0, 00);
    do_write(1, CLP);
    do_write(2, tag_of(x.c, x.h, x.b));
    do_write(3, 0);
    d_rq = 0;
    for (int q = 0; q < 200; ++q) run_tick(false);
    if (!dut->ch_active) Say("the Read of a block taken away did not wait");
    if (miss_now) Say("the Read of a block taken away missed instead of waiting");
    uint32_t rq = reg_read(R_REQ);
    if (rq != (REQ_VALID | tag_of(x.c, x.h, x.b))) Fail("REQ during the wait", rq, REQ_VALID | tag_of(x.c, x.h, x.b));
    uint32_t ctl = reg_read(R_CTL);
    if (!(ctl & ST_WAITING)) Fail("waiting in the status word during the wait", ctl, ST_WAITING);
    if (!(reg_read(R_IRQ) & IRQ_REQ)) Fail("IRQ's request bit during the wait", reg_read(R_IRQ), IRQ_REQ);
    if (irq_ticks == irq0) Say("the interrupt line stayed low through a posted request");
    unsigned s = do_read(0);
    if (s & 1u) Fail("not-active during the wait for a block", s, 0);
    page_is(page, [&](int i) { return page_word(page, i); }, "the page during the wait for a block");
    fetch(x.at, tag_of(x.c, x.h, x.b), 21, "the fetch that answers a request");
    ++fetches;
    settle_walk();
    if (req_now) Fail("REQ after the block arrived", reg_read(R_REQ), 0);
    if (miss_now) Say("store_miss after a request was answered");
    if (page_is(page, [&](int i) { return rec_word(x.at, i); }, "a Read that waited for its block")) ++reads_compared;
    ++requests_served;
    s = do_read(0);
    if (!(s & 1u)) Fail("not-active after a Read that waited", s, 1);
    if (s & 0x007fc000u) Fail("an error bit after a Read that waited", s, 0);
    // The interrupt line drops when the request bit is cleared and the
    // other two --- a move finished --- are cleared with it.
    reg_write(R_IRQ, 0x7);
    for (int q = 0; q < 4; ++q) run_tick(false);
    if (dut->irq) Say("the interrupt line stayed up after IRQ was cleared");
    do_write(0, 0);
    bus_idle();
  }


  // The slots nothing above put a block in, for the phases below.
  std::vector<unsigned> free_slots;
  {
    std::set<unsigned> used;
    for (const Held &x : held) used.insert(x.slot);
    used.insert(20); used.insert(21); used.insert(22);
    for (unsigned k = 0; k < (unsigned)SLOTS; ++k) if (!used.count(k)) free_slots.push_back(k);
    if (free_slots.size() < 4) { Say("fewer than four free slots for the request path's cases"); }
  }
  // What DIRTY must read: kept from the stimulus --- a Write dirties the
  // slot its block is in, a fetch, a write-back or a take-away cleans it ---
  // and never from the register.
  std::set<unsigned> dirty_want;
  auto slot_of_block = [&](unsigned c, unsigned h, unsigned b, unsigned dflt) -> unsigned {
    for (const Held &x : held) if (x.c == c && x.h == h && x.b == b) return x.slot;
    return dflt;
  };
  (void)slot_of_block;

  // ========================================================================
  phase = "a Linux slower than the drive";
  {
    // **THE STALL, MEASURED.**  First the reference: an unstalled Read of a
    // resident block, the drive's time not charged, from the START's tick to
    // the walk's end.  held[1] is fetched again into its own slot so that it
    // is known to be there whatever the phases above did to slot 20 to 22.
    const Held &r0 = held[1];
    fetch(r0.at, tag_of(r0.c, r0.h, r0.b), r0.slot, "the reference block");
    ++fetches;
    reg_write(R_IRQEN, 0);
    reg_write(R_IRQ, 0x7);
    const unsigned page_ref = 0xC0;
    fill_page(page_ref);
    ccw(CLP, page_ref);
    do_write(0, 00);
    do_write(1, CLP);
    do_write(2, tag_of(r0.c, r0.h, r0.b));
    const long s_ref = tick + 1;   // the START's instant: the request's tick
    do_write(3, 0);
    settle_walk();
    walk_ref = walk_end - s_ref;
    if (page_is(page_ref, [&](int i) { return rec_word(r0.at, i); }, "the reference Read")) ++reads_compared;
    if (miss_now || req_now) Say("the reference Read asked for a block or missed");

    // Then the stall: the drive's time charged, a block on the heads'
    // cylinder --- no seek, so the access time is at most a revolution and
    // a sector, 3,527,024 ticks --- that the store lacks, and a Linux that
    // answers 4,000,000 ticks after the START.
    reg_write(R_DRIVE, 0x00010001u);
    const unsigned zc = r0.c, zh = (r0.h + 1) % HEADS, zb = (r0.b + 5) % BPT;
    const uint64_t zat = fresh();
    const uint32_t zhdr = header_of(zc, zh, zb);
    place(zat, zhdr, good_hck(zhdr), good_dck(zat));
    const unsigned page_z = 0xC1;
    fill_page(page_z);
    ccw(CLP, page_z);
    const uint32_t dirty_before = reg_read(R_DIRTY);
    const long LATENCY = 4000000;
    do_write(0, 00);
    do_write(1, CLP);
    do_write(2, tag_of(zc, zh, zb));
    const long s_z = tick + 1;
    do_write(3, 0);
    d_rq = 0;
    // The wait, sampled every 50,000 ticks: BUSY up, not-active and the
    // interrupt request down, waiting up, REQ the block, the page poison,
    // nothing dirty, no miss.
    long lies = 0;
    while (tick < s_z + LATENCY) {
      for (int q = 0; q < 50000 && tick < s_z + LATENCY; ++q) run_tick(false);
      ++stall_samples;
      if (!dut->ch_active) { Say("the channel went idle during the stall"); break; }
      unsigned st = do_read(0);
      d_rq = 0;
      if (st & 1u) { ++lies; Fail("not-active during the stall", st, 0); }
      if (st & 8u) { ++lies; Fail("interrupt request during the stall", st, 0); }
      uint32_t ctl = reg_read(R_CTL);
      if (!(ctl & ST_WAITING)) { ++lies; Fail("waiting during the stall", ctl, ST_WAITING); }
      if (ctl & ST_STORE_MISS) { ++lies; Fail("store_miss during the stall", ctl, 0); }
      uint32_t rq = reg_read(R_REQ);
      if (rq != (REQ_VALID | tag_of(zc, zh, zb))) { ++lies; Fail("REQ during the stall", rq, REQ_VALID | tag_of(zc, zh, zb)); }
      if (reg_read(R_DIRTY) != dirty_before) { ++lies; Fail("DIRTY during the stall", reg_read(R_DIRTY), dirty_before); }
      if (!page_is(page_z, [&](int i) { return page_word(page_z, i); }, "the page during the stall")) ++lies;
      if (lies > 6) break;
    }
    if (req_rise_tick < s_z) Fail("REQ posted after the START that lacked its block", 0, 1);
    // The answer, into a free slot; the tag landing is what ends the wait.
    fetch(zat, tag_of(zc, zh, zb), free_slots[0], "the fetch that ends the stall");
    ++fetches;
    ++requests_served;
    settle_walk();
    const long stall_end = walk_end;
    if (req_fall_tick < s_z) Fail("REQ fell during the stall", 0, 1);
    stall_ticks_measured = stall_end - s_z;
    stall_tail = stall_end - req_fall_tick;
    if (stall_ticks_measured < LATENCY) Fail("the transfer ended before the block arrived", stall_ticks_measured, LATENCY);
    // **THE BOUND, DERIVED AND MEASURED.**  The tag lands at the store at
    // tick T: `s_valid` shows it at T+1, `hit_q` at T+2, `slot_hit` at T+3,
    // and the walk leaves `C_LOOK` for `C_HDRC` at T+4; REQ falls at T+2
    // (the tag compared in registers, one tick behind the write), which is
    // the tick measured from here.  An unstalled walk STARTed at S reaches
    // `C_HDRC` at S+6+lat, the command-list fetch's bus cycle being the
    // testbench's `lat` of one to three ticks.  So the tail after REQ falls
    // is the reference walk LESS 4+lat: the stalled walk made its
    // command-list fetch before the wait.  Measured 2,589 against 2,595 with
    // lat 2.  The allowance is four ticks, which is the two walks' own
    // variation --- the channel's latency pattern continuing from where the
    // reference left it --- and a walk resuming later than that is caught:
    // `disk-resumes-late-from-a-wait` in `mutations/list.txt`.
    const long STALL_SLACK = 4;
    if (stall_tail > walk_ref + STALL_SLACK) Fail("ticks from the tag landing to the transfer's end", stall_tail, walk_ref + STALL_SLACK);
    if (page_is(page_z, [&](int i) { return rec_word(zat, i); }, "the Read that stalled")) ++reads_compared;
    unsigned st = do_read(0);
    if (!(st & 1u)) Fail("not-active after the stalled Read, its access time long past", st, 1);
    if (st & 0x007fc000u) Fail("an error bit after the stalled Read", st, 0);
    if (reg_read(R_DIRTY) != dirty_before) Fail("DIRTY after a stalled Read", reg_read(R_DIRTY), dirty_before);
    if (req_now) Fail("REQ after the stalled Read", reg_read(R_REQ), 0);
    reg_write(R_DRIVE, 0x00000001u);   // untimed again
    do_write(0, 0);
    bus_idle();
    // **NOTHING MOVED WHILE IT WAITED.**  The slot the walk stood on for
    // the four million ticks --- the reference block's, the last one it had
    // chosen --- written back and compared with what was fetched into it: a
    // walk that touched the store during its wait would show here.
    {
      const uint64_t to = fresh();
      writeback(to, r0.slot, "the write-back of the slot the walk stood on");
      ++writebacks;
      uint32_t got[RECORD_WORDS];
      ddr.record(to, got);
      const uint32_t hdr0 = header_of(r0.c, r0.h, r0.b);
      for (int i = 0; i < 256; ++i)
        if (got[i] != rec_word(r0.at, i)) { Fail("a word of the slot the walk stood on during the stall", got[i], rec_word(r0.at, i)); std::fprintf(stderr, "  word %d\n", i); break; }
      if (got[256] != hdr0) Fail("the header of the slot the walk stood on during the stall", got[256], hdr0);
      if (got[258] != good_dck(r0.at)) Fail("the data checkword of the slot the walk stood on during the stall", got[258], good_dck(r0.at));
    }
    held.push_back({zat, zc, zh, zb, free_slots[0]});
  }

  // ========================================================================
  phase = "a Write that waits writes nothing early";
  {
    // A Write of a block the store lacks: nothing is dirty until the block
    // has arrived and the page has gone into it; then that slot alone is,
    // and what is written back is the page.
    const unsigned wc = 500, wh = 11, wb = 3;
    const uint64_t wat = fresh();
    const uint32_t whdr = header_of(wc, wh, wb);
    place(wat, whdr, good_hck(whdr), good_dck(wat));
    const unsigned page_w = 0xC2;
    fill_page(page_w);
    ccw(CLP, page_w);
    const uint32_t dirty_before = reg_read(R_DIRTY);
    do_write(0, 011);
    do_write(1, CLP);
    do_write(2, tag_of(wc, wh, wb));
    do_write(3, 0);
    d_rq = 0;
    for (int q = 0; q < 20000; ++q) run_tick(false);
    if (!dut->ch_active) Say("the Write of an absent block did not wait");
    if (reg_read(R_DIRTY) != dirty_before) Fail("DIRTY while a Write waits", reg_read(R_DIRTY), dirty_before);
    if (reg_read(R_REQ) != (REQ_VALID | tag_of(wc, wh, wb))) Fail("REQ while a Write waits", reg_read(R_REQ), REQ_VALID | tag_of(wc, wh, wb));
    // Into the slot the walk last stood on --- the stalled Read's --- which
    // a move must be free to take while the walk waits: the walk is on no
    // slot then, whatever `ch_slot` still names.
    const unsigned ws = free_slots[0];
    fetch(wat, tag_of(wc, wh, wb), ws, "the fetch that ends a Write's wait");
    ++fetches;
    ++requests_served;
    settle_walk();
    unsigned s = do_read(0);
    if (s & 0x007fc000u) Fail("an error bit after the Write that waited", s, 0);
    dirty_want.insert(ws);
    uint32_t dm = 0;
    for (unsigned k : dirty_want) dm |= 1u << k;
    if (reg_read(R_DIRTY) != dm) Fail("DIRTY after the Write that waited", reg_read(R_DIRTY), dm);
    bus_idle();
    const uint64_t to = fresh();
    writeback(to, ws, "the write-back of the block a waiting Write wrote");
    ++writebacks;
    dirty_want.erase(ws);
    uint32_t got[RECORD_WORDS];
    ddr.record(to, got);
    for (int i = 0; i < 256; ++i)
      if (got[i] != page_word(page_w, i)) { Fail("a word written back after a waiting Write", got[i], page_word(page_w, i)); break; }
    if (got[256] != whdr) Fail("the header written back after a waiting Write", got[256], whdr);
    if (reg_read(R_DIRTY) != 0) Fail("DIRTY after the write-back", reg_read(R_DIRTY), 0);
    // Z left the store when W took its slot.
    held.pop_back();
    held.push_back({wat, wc, wh, wb, ws});
  }

  // ========================================================================
  phase = "two units";
  {
    // One cylinder, head and block on two drives: two blocks, two slots, two
    // records, and a Read from each gets its own.
    reg_write(R_DRIVE, 0x00000003u);
    const unsigned c = 600, h = 4, b = 12;
    const uint64_t at0 = fresh(), at1 = fresh();
    const uint32_t hdr = header_of(c, h, b);
    place(at0, hdr, good_hck(hdr), good_dck(at0));
    place(at1, hdr, good_hck(hdr), good_dck(at1));
    fetch(at0, pack_side::tag_of(0, c, h, b), free_slots[2], "unit 0's block");
    ++fetches;
    fetch(at1, pack_side::tag_of(1, c, h, b), free_slots[3], "unit 1's block");
    ++fetches;
    const unsigned page0 = 0xC3, page1 = 0xC4;
    fill_page(page1);
    ccw(CLP, page1);
    command(00, CLP, 1u << 28 | tag_of(c, h, b));
    if (page_is(page1, [&](int i) { return rec_word(at1, i); }, "a Read from unit 1")) { ++reads_compared; ++unit_reads; }
    unsigned da = do_read(2);
    if (da != (1u << 28 | tag_of(c, h, b))) Fail("the disk address after unit 1's Read", da, 1u << 28 | tag_of(c, h, b));
    fill_page(page0);
    ccw(CLP, page0);
    command(00, CLP, tag_of(c, h, b));
    if (page_is(page0, [&](int i) { return rec_word(at0, i); }, "a Read from unit 0")) { ++reads_compared; ++unit_reads; }
    if (req_now || miss_now) Say("a two-unit Read asked for a block or missed");
    reg_write(R_DRIVE, 0x00000001u);
    bus_idle();
    held.push_back({at0, c, h, b, free_slots[2]});
  }

  // ========================================================================
  phase = "the next block is asked for before the current one moves";
  {
    // A list of two: the first block resident, the second --- the next by
    // the format's rule --- absent.  REQ names the second while the first's
    // page is still poison, and the walk is not waiting when it does.
    const unsigned c = 700, h = 2, b = 5;
    const unsigned c2 = c, h2 = h, b2 = b + 1;
    const uint64_t at1 = fresh(), at2 = fresh();
    const uint32_t hdr1 = header_of(c, h, b), hdr2 = header_of(c2, h2, b2);
    place(at1, hdr1, good_hck(hdr1), good_dck(at1));
    place(at2, hdr2, good_hck(hdr2), good_dck(at2));
    fetch(at1, tag_of(c, h, b), free_slots[2], "the first block of a chained list");
    ++fetches;
    const unsigned pA = 0xC5, pB = 0xC6;
    fill_page(pA);
    fill_page(pB);
    mem[CLP] = (pA << 8) | 1u;
    mem[CLP + 1] = (pB << 8);
    do_write(0, 00);
    do_write(1, CLP);
    do_write(2, tag_of(c, h, b));
    do_write(3, 0);
    d_rq = 0;
    const long began = tick;
    while (!req_now && tick - began < 10000) run_tick(false);
    if (!req_now) Say("no request was posted for the second block of a chained list");
    else {
      uint32_t rq = reg_read(R_REQ);
      if (rq != (REQ_VALID | tag_of(c2, h2, b2))) Fail("REQ for the next block", rq, REQ_VALID | tag_of(c2, h2, b2));
      // Posted before the first block moved, and not from a wait.
      if (mem[pA * 256u] != page_word(pA, 0)) Say("the first block had begun to move when the next was asked for");
      if (reg_read(R_CTL) & ST_WAITING) Say("the walk was waiting when it asked for the next block");
      ++prefetches;
    }
    fetch(at2, tag_of(c2, h2, b2), free_slots[3], "the second block, given while the first moves");
    ++fetches;
    settle_walk();
    if (page_is(pA, [&](int i) { return rec_word(at1, i); }, "the first page of a chained list")) ++reads_compared;
    if (page_is(pB, [&](int i) { return rec_word(at2, i); }, "the second page of a chained list")) ++reads_compared;
    unsigned s = do_read(0);
    if (s & 0x007fc000u) Fail("an error bit after the chained list", s, 0);
    if (req_now) Fail("REQ after the chained list", reg_read(R_REQ), 0);
    bus_idle();
  }

  // ========================================================================
  phase = "REF, DIRTY and the three events";
  {
    // Two blocks known to be resident, fetched again into their own slots
    // --- the phases above may have put something else in either.
    const Held &x = held[1];
    const Held &y = held[2];
    fetch(x.at, tag_of(x.c, x.h, x.b), x.slot, "the first block of the bookkeeping case");
    ++fetches;
    fetch(y.at, tag_of(y.c, y.h, y.b), y.slot, "the second block of the bookkeeping case");
    ++fetches;
    reg_write(R_REF, 0xFFFFFFFFu);
    reg_write(R_IRQ, 0x7);
    if (reg_read(R_REF) != 0) Fail("REF after clearing it", reg_read(R_REF), 0);
    if (reg_read(R_IRQ) != 0) Fail("IRQ after clearing it", reg_read(R_IRQ), 0);
    const unsigned page = 0xC7;
    fill_page(page);
    ccw(CLP, page);
    command(00, CLP, tag_of(x.c, x.h, x.b));
    if (reg_read(R_REF) != (1u << x.slot)) Fail("REF after one Read", reg_read(R_REF), 1u << x.slot);
    if (reg_read(R_IRQ) != 0) Fail("IRQ after a Read: no event", reg_read(R_IRQ), 0);
    // A Write: the slot dirty, the dirty event, and REF up for it too.
    fill_page(page);
    ccw(CLP, page);
    command(011, CLP, tag_of(y.c, y.h, y.b));
    dirty_want.insert(y.slot);
    if (reg_read(R_DIRTY) != (1u << y.slot)) Fail("DIRTY after one Write", reg_read(R_DIRTY), 1u << y.slot);
    if (reg_read(R_REF) != ((1u << x.slot) | (1u << y.slot))) Fail("REF after a Read and a Write", reg_read(R_REF), (1u << x.slot) | (1u << y.slot));
    if (reg_read(R_IRQ) != IRQ_DIRTY) Fail("IRQ after a Write: the dirty event", reg_read(R_IRQ), IRQ_DIRTY);
    // A second Write of the same block: dirty already, so no second event.
    reg_write(R_IRQ, IRQ_DIRTY);
    fill_page(page);
    ccw(CLP, page);
    command(011, CLP, tag_of(y.c, y.h, y.b));
    if (reg_read(R_IRQ) != 0) Fail("IRQ after a Write of a slot already dirty", reg_read(R_IRQ), 0);
    // Clearing one REF bit leaves the other.
    reg_write(R_REF, 1u << x.slot);
    if (reg_read(R_REF) != (1u << y.slot)) Fail("REF after clearing one bit", reg_read(R_REF), 1u << y.slot);
    // The write-back: the done event, and the slot clean.
    const uint64_t to = fresh();
    writeback(to, y.slot, "the write-back that cleans a slot");
    ++writebacks;
    dirty_want.erase(y.slot);
    if (reg_read(R_DIRTY) != 0) Fail("DIRTY after the write-back", reg_read(R_DIRTY), 0);
    if (!(reg_read(R_IRQ) & IRQ_DONE)) Fail("IRQ after a move: the done event", reg_read(R_IRQ), IRQ_DONE);
    // A fetch into y's slot clears its REF bit.
    fetch(y.at, tag_of(y.c, y.h, y.b), y.slot, "the fetch that clears a REF bit");
    ++fetches;
    if (reg_read(R_REF) != 0) Fail("REF after a fetch into the slot", reg_read(R_REF), 0);
    // **THE MASK.**  Events stand in IRQ; the line follows IRQ under IRQEN.
    reg_write(R_IRQEN, 0);
    for (int q = 0; q < 8; ++q) run_tick(false);
    const long i0 = irq_ticks;
    for (int q = 0; q < 8; ++q) run_tick(false);
    if (irq_ticks != i0) Say("the interrupt line was up with IRQEN zero");
    if (!(reg_read(R_IRQ) & IRQ_DONE)) Fail("the done event still standing under a zero mask", reg_read(R_IRQ), IRQ_DONE);
    reg_write(R_IRQEN, IRQ_DONE);
    for (int q = 0; q < 8; ++q) run_tick(false);
    if (!dut->irq) Say("the interrupt line stayed low with the done event under its enable");
    reg_write(R_IRQEN, IRQ_REQ);
    for (int q = 0; q < 8; ++q) run_tick(false);
    if (dut->irq) Say("the interrupt line was up with only the request bit enabled and no request");
    reg_write(R_IRQEN, IRQ_DONE);
    reg_write(R_IRQ, IRQ_DONE);
    for (int q = 0; q < 8; ++q) run_tick(false);
    if (dut->irq) Say("the interrupt line stayed up after the done event was cleared");
    reg_write(R_IRQEN, 0);
    do_write(0, 0);
    bus_idle();
  }

  // ========================================================================
  phase = "a Write that meets a write-back of its own slot";
  {
    // **THE CONTROLLER'S HALF OF THE PER-SLOT INTERLOCK.**  A write-back of
    // slot s begins --- accepted, the channel idle --- and in the same
    // breath a Write of the block in s is STARTed.  The walk finds s valid
    // and chooses it; `C_HDRCK` finds a move on it and sends the walk back
    // to look again, until the write-back is over.  So the record written
    // back is the OLD block, whole, and the page lands afterwards; a walk
    // that wrote under the write-back would leave the record half old and
    // half new.  **A SLAVE FORTY TICKS A BEAT**, so that the write-back's
    // reader --- two words a beat --- is slower than the walk's writer, six
    // to eight ticks a word: a walk that wrote under the write-back would
    // overtake it partway and the record would be old at the front and new
    // at the back.  At the slave's usual speed the reader stays ahead and an
    // unprotected walk leaves the record whole, which is how the record
    // `disk-walks-onto-a-slot-a-move-is-on` first survived this phase.
    const Held &x = held[1];
    const unsigned page = 0xC9;
    fill_page(page);
    ccw(CLP, page);
    do_write(0, 011);
    do_write(1, CLP);
    do_write(2, tag_of(x.c, x.h, x.b));
    bus_idle();
    hp2.vary = false;
    hp2.fixed_ready = 40;
    const uint64_t to = fresh();
    const uint32_t pad_before = ddr.pad(to);
    reg_write(R_ADDR, (uint32_t)to);
    reg_write(R_SLOT, x.slot);
    reg_write(R_CTL, CTL_WRITE);
    ++writebacks;
    const long started = tick;
    do_write(3, 0);                              // START, as the write-back begins
    d_rq = 0;
    uint32_t st = 0;
    for (int n = 0; n < 20000; ++n) { st = reg_read(R_CTL); if (!(st & ST_BUSY)) break; }
    if (st & ST_BUSY) Say("the write-back a Write met never ended");
    if (st & ST_REFUSED) Say("the write-back a Write met was refused");
    settle_walk();
    if (walk_end - started < 300) Fail("ticks from the START to the end of the Write that met a write-back", walk_end - started, 300);
    uint32_t got[RECORD_WORDS];
    ddr.record(to, got);
    const uint32_t hdr = header_of(x.c, x.h, x.b);
    for (int i = 0; i < 256; ++i)
      if (got[i] != rec_word(x.at, i)) { Fail("a word of the record written back under a Write that met it", got[i], rec_word(x.at, i)); std::fprintf(stderr, "  word %d\n", i); break; }
    if (got[256] != hdr) Fail("the header written back under a Write that met it", got[256], hdr);
    if (got[258] != good_dck(x.at)) Fail("the data checkword written back under a Write that met it", got[258], good_dck(x.at));
    if (ddr.pad(to) != pad_before) Fail("the pad after the record written back under a Write", ddr.pad(to), pad_before);
    unsigned s = do_read(0);
    if (s & 0x007fc000u) Fail("an error bit after the Write that met a write-back", s, 0);
    if (!(reg_read(R_DIRTY) & (1u << x.slot))) Fail("DIRTY after the Write that met a write-back", reg_read(R_DIRTY), 1u << x.slot);
    hp2.vary = true;
    // And written back now, the slot holds the page.
    const uint64_t to2 = fresh();
    writeback(to2, x.slot, "the write-back after the Write that met one");
    ++writebacks;
    ddr.record(to2, got);
    for (int i = 0; i < 256; ++i)
      if (got[i] != page_word(page, i)) { Fail("a word of the page written back after the Write that met a write-back", got[i], page_word(page, i)); break; }
    if (reg_read(R_DIRTY) & (1u << x.slot)) Fail("DIRTY after the second write-back", reg_read(R_DIRTY), 0);
    ++waits_expected;
    do_write(0, 0);
    bus_idle();
  }

  // ========================================================================
  phase = "a request denied";
  {
    // **DENIED, THE WALK TAKES THE MISS.**  Last, because `store_miss` is
    // sticky until the controller's reset: a block taken away, asked for,
    // and Linux says no.
    const Held &x = held[2];
    const unsigned page = 0xC8;
    (void)go(0, 0, x.slot, CTL_TAKE);
    wait_done("the take-away before the denial");
    fill_page(page);
    ccw(CLP, page);
    do_write(0, 00);
    do_write(1, CLP);
    do_write(2, tag_of(x.c, x.h, x.b));
    do_write(3, 0);
    d_rq = 0;
    for (int q = 0; q < 200; ++q) run_tick(false);
    if (!dut->ch_active) Say("the Read before the denial did not wait");
    uint32_t rq = reg_read(R_REQ);
    if (rq != (REQ_VALID | tag_of(x.c, x.h, x.b))) Fail("REQ before the denial", rq, REQ_VALID | tag_of(x.c, x.h, x.b));
    if (miss_now) Say("store_miss was up before the denial");
    reg_write(R_CTL, CTL_DENY);
    settle_walk();
    if (!miss_now) Say("a Read whose request was denied did not miss");
    else { ++misses_expected; ++denials; }
    if (req_now) Fail("REQ after the denial", reg_read(R_REQ), 0);
    uint32_t ctl = reg_read(R_CTL);
    if (!(ctl & ST_STORE_MISS)) Fail("store_miss in the status word after the denial", ctl, ST_STORE_MISS);
    if (ctl & ST_WAITING) Fail("waiting in the status word after the denial", ctl, 0);
    page_is(page, [&](int i) { return page_word(page, i); }, "the page of a Read whose request was denied");
    unsigned s = do_read(0);
    if (!(s & 1u)) Fail("not-active after the denial", s, 1);
    // Given back, it reads again; the miss stands, as the header says.
    fetch(x.at, tag_of(x.c, x.h, x.b), x.slot, "the fetch that gives it back after the denial");
    ++fetches;
    fill_page(page);
    ccw(CLP, page);
    command(00, CLP, tag_of(x.c, x.h, x.b));
    if (page_is(page, [&](int i) { return rec_word(x.at, i); }, "a Read of the block given back after the denial")) ++reads_compared;
    do_write(0, 0);
    bus_idle();
  }

  // ========================================================================
  phase = "the tally";
  {
    // Every burst the slave saw: eight of sixteen then one of two, per move.
    const long moves = fetches + writebacks + 1;   // +1: the refused-burst fetch
    if (hp2.aw_count != writebacks * 9) Fail("write address handshakes", hp2.aw_count, writebacks * 9);
    if (hp2.b_count != writebacks * 9) Fail("write responses", hp2.b_count, writebacks * 9);
    if (hp2.w_count != writebacks * 130) Fail("write data beats", hp2.w_count, writebacks * 130);
    if (hp2.ar_count != (moves - writebacks) * 9) Fail("read address handshakes", hp2.ar_count, (moves - writebacks) * 9);
    if (hp2.r_count != (moves - writebacks) * 130) Fail("read data beats", hp2.r_count, (moves - writebacks) * 130);
    long bad_len = 0;
    for (size_t i = 0; i < hp2.ar_lens.size(); ++i)
      if (hp2.ar_lens[i] != ((i % 9 == 8) ? 1u : 15u)) ++bad_len;
    for (size_t i = 0; i < hp2.aw_lens.size(); ++i)
      if (hp2.aw_lens[i] != ((i % 9 == 8) ? 1u : 15u)) ++bad_len;
    if (bad_len) Fail("bursts whose length is not the record's", bad_len, 0);
    long bad_addr = 0;
    for (size_t i = 0; i < hp2.ar_addrs.size(); ++i) {
      const uint64_t base = hp2.ar_addrs[i - i % 9];
      const uint64_t want = (i % 9 == 8) ? base + 1024 : base + 128 * (i % 9);
      if (hp2.ar_addrs[i] != want) ++bad_addr;
    }
    if (bad_addr) Fail("read bursts not where the record's are", bad_addr, 0);
  }

  delete dut;

  if (bad + hp2.bad + gp0.bad) {
    std::fprintf(stderr, "FAIL: %d mismatches\n", bad + hp2.bad + gp0.bad);
    return 1;
  }
  std::printf(
      "ok: the pack side moves a block between DDR and the store and the\n"
      "    CADR reads back what was put there\n"
      "    %ld fetches, %ld write-backs, %ld blocks read by the CADR and\n"
      "      compared word for word against the record in DDR\n"
      "    %ld records written back and compared, pad and origin untouched,\n"
      "      the data checkword recomputed\n"
      "    %ld of the three words after the block wrong and reported as\n"
      "      <18>, <17>, <16>|<15>\n"
      "    %ld refusals, each without a burst; %ld moves answered SLVERR\n"
      "      and reported\n"
      "    %ld miss, a request denied; %ld walks that met a move on their own\n"
      "      slot and waited for it\n"
      "  the request path:\n"
      "    %ld requests served: the walk waited, the block arrived in a slot\n"
      "      of Linux's choosing, the transfer completed; %ld denial\n"
      "    a Linux 4,000,000 ticks behind a START on a timed drive, sampled\n"
      "      %ld times during the wait: BUSY up, not-active down, the page\n"
      "      poison, nothing dirty; the transfer took %ld ticks and ended\n"
      "      %ld ticks after the tag landed, against an unstalled walk of %ld\n"
      "      (allowance 4)\n"
      "    %ld next block asked for before the current one moved; %ld fill\n"
      "      taken beside a walk on another slot; %ld Reads from two units\n"
      "      with one address\n"
      "    %ld AXI bursts, %ld read beats, %ld write beats, ready and valid\n"
      "      delays varying; %ld register writes and %ld reads over GP0\n",
      fetches, writebacks, reads_compared, writebacks, meta_errors, refusals,
      error_moves, misses_expected, waits_expected,
      requests_served, denials, stall_samples, stall_ticks_measured, stall_tail, walk_ref,
      prefetches, fills_beside_a_walk, unit_reads,
      hp2.bursts, hp2.r_count, hp2.w_count,
      gp0.writes, gp0.reads);
  return 0;
}
