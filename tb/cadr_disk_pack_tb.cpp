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
//   A SLOT TAKEN AWAY IS MISSED, AND A WALK THAT MEETS A FILL WAITS FOR
//   IT.  The interlock is mutual: while the pack side is moving a block the
//   controller defers its first command-list fetch, so a transfer STARTed
//   the moment a fetch begins finds the block once the fill is over and
//   reads it whole --- neither a miss nor a block half old and half new.  The
//   take-away is a request of its own, and a block taken away is missed.
//   `store_miss` says so and the status word says so.
//
//   THE DRIVE IS A REGISTER LINUX WRITES.  With nothing present the status
//   reads `0x2321`, the boot PROM's word; a present bit clears three of its
//   bits, the read-only bit sets `<7>`, and the timed bit is what makes a
//   seek take the drive's own time.
//
//   AND AN ERROR RESPONSE IS REPORTED, ONCE.  A burst answered SLVERR sets
//   the error bit for that move, and the next clean move clears it.

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
uint32_t tag_of(unsigned c, unsigned h, unsigned b) {
  return (c & 0xFFF) << 16 | (h & 0xFF) << 8 | (b & 0xFF);
}
// `header_of`, with the next-block code in <31:30>.
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
  auto settle_walk = [&]() -> bool {
    d_rq = 0;
    const long began = tick;
    while (dut->ch_active) {
      run_tick(false);
      if (tick - began > WALK_CAP) { Say("the channel was still walking at the cap"); return false; }
    }
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
    const long b1 = hp2.bursts;
    st = go(held[7].at, tag_of(held[7].c, held[7].h, held[7].b), held[7].slot, CTL_FETCH);
    if (!(st & ST_CH_ACTIVE)) Fail("ch_active in the status word during a walk", st, ST_CH_ACTIVE);
    if (!(st & ST_REFUSED)) Fail("refused, a request while the channel walks", st, ST_REFUSED); else ++refusals;
    settle_walk();
    if (hp2.bursts != b1) Fail("bursts during the walk", hp2.bursts - b1, 0);
    unsigned s = do_read(0);
    if (!(s & ((1u << 16) | (1u << 15)))) Fail("the checkword error the walk was busy with", s, 1u << 16);
    do_write(0, 0);
    bus_idle();
    // Once the walk is over the same request is taken.
    fetch(held[7].at, tag_of(held[7].c, held[7].h, held[7].b), held[7].slot, "the request after the walk");
    ++fetches;
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
    hp2.vary = true;
    // And Y is gone from the store: a Read of it misses too.
    fill_page(page);
    ccw(CLP, page);
    command(00, CLP, tag_of(y.c, y.h, y.b));
    page_is(page, [&](int i) { return page_word(page, i); }, "the page of a Read of the block the fill displaced");
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
    fill_page(page);
    ccw(CLP, page);
    command(00, CLP, tag_of(x.c, x.h, x.b));
    if (!miss_now) Say("a Read of a block taken away did not miss");
    else ++misses_expected;
    page_is(page, [&](int i) { return page_word(page, i); }, "the page of a Read of a block taken away");
    // Given back, it reads again.
    fetch(x.at, tag_of(x.c, x.h, x.b), x.slot, "the fetch that gives it back");
    ++fetches;
    fill_page(page);
    ccw(CLP, page);
    command(00, CLP, tag_of(x.c, x.h, x.b));
    if (page_is(page, [&](int i) { return rec_word(x.at, i); }, "a Read of the block given back")) ++reads_compared;
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
      "    %ld miss, a slot taken away; %ld walk that met a fill and waited\n"
      "    %ld AXI bursts, %ld read beats, %ld write beats, ready and valid\n"
      "      delays varying; %ld register writes and %ld reads over GP0\n",
      fetches, writebacks, reads_compared, writebacks, meta_errors, refusals,
      error_moves, misses_expected, waits_expected, hp2.bursts, hp2.r_count, hp2.w_count,
      gp0.writes, gp0.reads);
  return 0;
}
