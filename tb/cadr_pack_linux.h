// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE PROCESSING SYSTEM'S TWO FACES ONTO `rtl/plumbing/cadr_disk_pack.sv`,
// FOR A HARNESS THAT INSTANTIATES IT RATHER THAN PLAYING IT.
//
// `tb/cadr_pack_axi_harness.sv` puts the pack side in the design, so what the
// testbench drives is no longer the block store's seam but the two AXI faces
// the board's own PS drives: `M_AXI_GP0`, where Linux writes registers, and
// `S_AXI_HP2`, where the records live in DDR.  This header is those two, plus
// the program that sits behind them.
//
//   Hp2Slave   the AXI3 slave the pack side masters.  It counts, in the shape
//              `tb/cadr_pack_side.h`'s does: exactly one address handshake per
//              burst, as many data beats as the length promised, WLAST and
//              RLAST where the length says and nowhere else, one response a
//              burst, no burst across a 4 KB boundary, every beat aligned to
//              its size.  A slave that only recorded the address could not see
//              a duplicate handshake, which is CLAUDE.md's
//              `awvalid-held-up-after-awready` lesson.
//
//   Gp0Linux   a single-beat 32-bit AXI3 master, NON-BLOCKING: one register
//              access at a time, advanced a tick at a time by the caller's own
//              loop.  `tb/cadr_pack_side.h`'s `Gp0Master` runs an access to
//              completion behind a tick callback, which suits a directed
//              testbench and cannot be used from inside one big tick loop that
//              is also running a machine.
//
//   Feeder     `cadr-disk-packs` as a state machine over those accesses: take
//              every slot away at the start, put the drives on the cable, then
//              poll REQ and serve what the walk asks for --- write a dirty
//              slot back to the pack first, put the record in DDR at the
//              staging address for the slot, and FETCH.  Its addresses are
//              `pack_feeder.h`'s own, so a record lands where the program
//              would put it.
//
// **THE MEMORY BEHIND BOTH PORTS IS THE CALLER'S, AND ON PURPOSE.**  On the
// board `S_AXI_HP0` and `S_AXI_HP2` are two doors into one DRAM.  The slave
// here reads and writes through two callbacks, so a testbench can give it the
// same array the machine's own memory model uses --- and then a pack-side
// master that wandered into the machine's region is caught by the machine's
// own watchpoint instead of being unreachable by construction.
//
// THE TICK PROTOCOL, which both sides follow and which the caller must too:
//
//     dut->clk = 0;  <set the testbench's own inputs>
//     hp2.drive(dut);  linux.drive(dut);      // readies and valids, combinational
//     dut->eval();
//     hp2.sample(dut); linux.sample(dut);     // what the edge is about to see
//     dut->clk = 1; dut->eval();
//     hp2.after_edge(dut); linux.after_edge(dut);
//
// Every `valid` the pack side drives on either face comes out of a registered
// state machine (`pst` for HP2, the GP0 slave's own), so a ready computed from
// a valid in the same tick is not a combinational loop.  That is a fact about
// `rtl/plumbing/cadr_disk_pack.sv` and it is checked by the run rather than
// assumed: Verilator reports a loop if it is ever untrue.

#ifndef CADR_PACK_LINUX_H
#define CADR_PACK_LINUX_H

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <vector>

namespace pack_linux {

// ------------------------------------------------------------- the layout
//
// `rtl/plumbing/cadr_disk_pack.sv`'s own register map and record shape.
constexpr int kRecordWords = 259;      // 256 data, header, its checkword, the data's
constexpr int kBlockWords = 256;
constexpr uint32_t kRegBase = 0x4000'0000u;
enum Reg {
  R_ADDR = 0, R_TAG = 1, R_SLOT = 2, R_CTL = 3, R_DRIVE = 4,
  R_REQ = 5, R_DIRTY = 6, R_IDENT = 7, R_REF = 8, R_IRQ = 9, R_IRQEN = 10
};
enum Ctl {
  CTL_FETCH = 1u << 0, CTL_WRITE = 1u << 1, CTL_TAKE = 1u << 2,
  CTL_DENY = 1u << 3,
  ST_BUSY = 1u << 0, ST_DONE = 1u << 1, ST_ERROR = 1u << 2,
  ST_REFUSED = 1u << 3, ST_CH_ACTIVE = 1u << 4, ST_STORE_MISS = 1u << 5,
  ST_WAITING = 1u << 6
};
constexpr uint32_t kReqValid = 1u << 31;
constexpr uint32_t kIdent = 0x5041'434Bu;
constexpr int kSlots = 24;

// `pack_feeder.h`'s staging area: the spare part of the CADR's own 128 MB
// reservation, past main memory (64 MB at 0x1800_0000) and past the display's
// 8 MB at 0x1C00_0000.  The record for a fetch and the record for a write-back
// are separate so that one of each can be in flight; the stride is 2 KB, which
// is 128-byte aligned as the pack side demands.
constexpr uint32_t kSpareBase = 0x1C80'0000u;
constexpr uint32_t kFetchOff = 0x00000u;
constexpr uint32_t kWbOff = 0x10000u;
constexpr uint32_t kRecordStride = 0x800u;
inline uint32_t fetch_addr(unsigned slot) {
  return kSpareBase + kFetchOff + slot * kRecordStride;
}
inline uint32_t wb_addr(unsigned slot) {
  return kSpareBase + kWbOff + slot * kRecordStride;
}

// The tag: {unit<2:0>, cylinder<11:0>, head<7:0>, block<7:0>}, the disk
// address register's own layout without its bit 31.
inline uint32_t tag_of(unsigned unit, unsigned c, unsigned h, unsigned b) {
  return (unit & 7u) << 28 | (c & 0xFFFu) << 16 | (h & 0xFFu) << 8 | (b & 0xFFu);
}

// ---------------------------------------------------------- the HP2 slave
template <class Dut>
struct Hp2Slave {
  // The memory, the caller's.  A beat is eight bytes at an eight-aligned
  // address; `wr` takes the byte strobes.
  std::function<uint64_t(uint32_t)> rd;
  std::function<void(uint32_t, uint64_t, unsigned)> wr;
  // Named so a failure says which clause, not merely that one broke.
  std::function<void(const char *)> complain;

  long bad = 0;
  long read_bursts = 0, write_bursts = 0, read_beats = 0, write_beats = 0;
  long aw_handshakes = 0, ar_handshakes = 0, b_responses = 0;

  // The write burst in flight.
  bool w_open = false;
  uint32_t w_addr = 0;
  unsigned w_len = 0, w_beat = 0;
  bool b_due = false;
  // The read burst in flight.
  bool r_open = false;
  uint32_t r_addr = 0;
  unsigned r_len = 0, r_beat = 0;

  // What the edge is about to see.
  int s_awvalid = 0, s_awready = 0, s_wvalid = 0, s_wready = 0;
  int s_wlast = 0, s_bvalid = 0, s_bready = 0;
  int s_arvalid = 0, s_arready = 0, s_rvalid = 0, s_rready = 0;
  uint32_t s_awaddr = 0, s_araddr = 0, s_wstrb = 0;
  uint64_t s_wdata = 0;
  unsigned s_awlen = 0, s_awsize = 0, s_awburst = 0;
  unsigned s_arlen = 0, s_arsize = 0, s_arburst = 0;

  void fail(const char *what) {
    ++bad;
    if (complain) complain(what);
  }

  void reset(Dut *dut) {
    dut->hp2_awready = 0;
    dut->hp2_wready = 0;
    dut->hp2_bvalid = 0;
    dut->hp2_bresp = 0;
    dut->hp2_arready = 0;
    dut->hp2_rvalid = 0;
    dut->hp2_rlast = 0;
    dut->hp2_rresp = 0;
    dut->hp2_rdata = 0;
    w_open = r_open = b_due = false;
  }

  // A burst's own rules, checked at the address handshake rather than inferred
  // from where the beats landed.
  void check_addr(uint32_t a, unsigned len, unsigned size, unsigned burst,
                  const char *which) {
    if (size != 3) fail(which);            // 2^3 = 8 bytes, the port's width
    if (burst != 1) fail(which);           // INCR
    if (a & 7u) fail(which);               // aligned to its size
    const uint64_t bytes = 8ull * (len + 1u);
    if ((a & ~0xFFFu) != ((a + bytes - 1u) & ~0xFFFu)) fail(which);
  }

  void drive(Dut *dut) {
    // The address channels: one burst open at a time on each half, which is
    // what `cadr_disk_pack.sv`'s own state machine issues.  A SECOND address
    // handshake while one is open would be a duplicate and is refused here
    // and counted below.
    dut->hp2_awready = dut->hp2_awvalid && !w_open;
    dut->hp2_arready = dut->hp2_arvalid && !r_open;
    dut->hp2_wready = w_open && dut->hp2_wvalid;
    if (!b_due) { dut->hp2_bvalid = 0; }
    if (r_open && !dut->hp2_rvalid) {
      dut->hp2_rdata = rd(r_addr + 8u * r_beat);
      dut->hp2_rresp = 0;
      dut->hp2_rlast = (r_beat == r_len);
      dut->hp2_rvalid = 1;
    }
  }

  void sample(Dut *dut) {
    s_awvalid = dut->hp2_awvalid; s_awready = dut->hp2_awready;
    s_wvalid = dut->hp2_wvalid;   s_wready = dut->hp2_wready;
    s_wlast = dut->hp2_wlast;
    s_bvalid = dut->hp2_bvalid;   s_bready = dut->hp2_bready;
    s_arvalid = dut->hp2_arvalid; s_arready = dut->hp2_arready;
    s_rvalid = dut->hp2_rvalid;   s_rready = dut->hp2_rready;
    s_awaddr = dut->hp2_awaddr;   s_araddr = dut->hp2_araddr;
    s_wstrb = dut->hp2_wstrb;     s_wdata = dut->hp2_wdata;
    s_awlen = dut->hp2_awlen;     s_awsize = dut->hp2_awsize;
    s_awburst = dut->hp2_awburst;
    s_arlen = dut->hp2_arlen;     s_arsize = dut->hp2_arsize;
    s_arburst = dut->hp2_arburst;
  }

  void after_edge(Dut *dut) {
    if (s_awvalid && s_awready) {
      ++aw_handshakes;
      ++write_bursts;
      check_addr(s_awaddr, s_awlen, s_awsize, s_awburst,
                 "HP2: a write burst that is not the port's shape");
      w_open = true; w_addr = s_awaddr; w_len = s_awlen; w_beat = 0;
    }
    if (s_wvalid && s_wready) {
      ++write_beats;
      if (!w_open) {
        fail("HP2: a write beat with no burst open");
      } else {
        if ((s_wlast != 0) != (w_beat == w_len))
          fail("HP2: WLAST is not on the beat the length names");
        wr(w_addr + 8u * w_beat, s_wdata, s_wstrb);
        if (s_wlast) {
          w_open = false;
          b_due = true;
          dut->hp2_bvalid = 1;
          dut->hp2_bresp = 0;
        } else {
          ++w_beat;
        }
      }
    }
    if (s_bvalid && s_bready) {
      ++b_responses;
      b_due = false;
      dut->hp2_bvalid = 0;
    }
    if (s_arvalid && s_arready) {
      ++ar_handshakes;
      ++read_bursts;
      check_addr(s_araddr, s_arlen, s_arsize, s_arburst,
                 "HP2: a read burst that is not the port's shape");
      r_open = true; r_addr = s_araddr; r_len = s_arlen; r_beat = 0;
    }
    if (s_rvalid && s_rready) {
      ++read_beats;
      if (r_beat == r_len) {
        r_open = false;
      } else {
        ++r_beat;
      }
      dut->hp2_rvalid = 0;
      dut->hp2_rlast = 0;
    }
  }
};

// ------------------------------------------------------------ GP0: Linux
//
// One single-beat 32-bit AXI3 access at a time.  `start_write`/`start_read`
// while `busy()` is false; `done()` is one tick.
template <class Dut>
struct Gp0Linux {
  std::function<void(const char *)> complain;
  long bad = 0;
  long writes = 0, reads = 0;

  enum State { IDLE, W_ADDR, W_RESP, R_ADDR, R_DATA };
  State st = IDLE;
  uint32_t addr = 0, wdata = 0, last_rdata = 0;
  bool aw_done = false, w_done = false;
  bool finished = false;
  uint32_t id = 1;

  int s_awvalid = 0, s_awready = 0, s_wvalid = 0, s_wready = 0;
  int s_bvalid = 0, s_bready = 0, s_arvalid = 0, s_arready = 0;
  int s_rvalid = 0, s_rready = 0, s_rlast = 0;
  uint32_t s_rdata = 0;
  unsigned s_bresp = 0, s_rresp = 0;

  void fail(const char *what) { ++bad; if (complain) complain(what); }

  bool busy() const { return st != IDLE; }
  bool done() const { return finished; }
  uint32_t rdata() const { return last_rdata; }

  void reset(Dut *dut) {
    dut->gp0_awvalid = 0; dut->gp0_wvalid = 0; dut->gp0_bready = 0;
    dut->gp0_arvalid = 0; dut->gp0_rready = 0;
    dut->gp0_awlen = 0; dut->gp0_arlen = 0;
    dut->gp0_awid = 0; dut->gp0_arid = 0;
    dut->gp0_wstrb = 0xF; dut->gp0_wlast = 1;
    dut->gp0_awaddr = 0; dut->gp0_araddr = 0; dut->gp0_wdata = 0;
    st = IDLE; finished = false;
  }

  void start_write(unsigned reg, uint32_t v) {
    if (st != IDLE) { fail("GP0: a write started while one was in flight"); return; }
    addr = kRegBase + 4u * reg;
    wdata = v;
    st = W_ADDR;
    aw_done = w_done = false;
    finished = false;
    ++writes;
  }

  void start_read(unsigned reg) {
    if (st != IDLE) { fail("GP0: a read started while one was in flight"); return; }
    addr = kRegBase + 4u * reg;
    st = R_ADDR;
    finished = false;
    ++reads;
  }

  // A hung register access, and the last of the ticks before it.  A GP0
  // access that never completes stops Linux dead, and the symptom a tick
  // later is only that the machine waits for a block for ever --- which is
  // the disk hang this project has already met twice.  So it is reported
  // where it happens.
  long stuck = 0;
  struct Moment { long tick; long st; int arv, arr, rv, rr, awr, wr, bv; };
  Moment ring[2048];
  int ring_at = 0;
  long ticks = 0;
  bool said_stuck = false;

  void drive(Dut *dut) {
    ++ticks;
    if (st == IDLE) stuck = 0; else ++stuck;
    if (stuck == 400 && !said_stuck) {
      said_stuck = true;
      std::printf("GP0 STUCK in state %d at address %08x; the last 64 ticks, "
                  "oldest first (st arvalid arready rvalid rready awready "
                  "wready bvalid):\n", (int)st, addr);
      long was = -1;
      for (int i = 0; i < 2048; ++i) {
        const Moment &m = ring[(ring_at + i) % 2048];
        const bool shake = (m.arv && m.arr) || (m.rv && m.rr) ||
                           (m.awr && m.st == 1) || (m.bv && m.st == 2);
        if (m.st == was && !shake) continue;
        was = m.st;
        std::printf("   t %ld  st %ld  %d %d %d %d %d %d %d\n", m.tick, m.st,
                    m.arv, m.arr, m.rv, m.rr, m.awr, m.wr, m.bv);
      }
      std::fflush(stdout);
    }
    finished = false;
    dut->gp0_awvalid = 0; dut->gp0_wvalid = 0; dut->gp0_bready = 0;
    dut->gp0_arvalid = 0; dut->gp0_rready = 0;
    dut->gp0_awid = id & 0xFFFu; dut->gp0_arid = id & 0xFFFu;
    dut->gp0_awlen = 0; dut->gp0_arlen = 0;
    dut->gp0_wstrb = 0xF; dut->gp0_wlast = 1;
    switch (st) {
      case W_ADDR:
        dut->gp0_awaddr = addr; dut->gp0_wdata = wdata;
        dut->gp0_awvalid = !aw_done;
        dut->gp0_wvalid = !w_done;
        break;
      case W_RESP: dut->gp0_bready = 1; break;
      case R_ADDR: dut->gp0_araddr = addr; dut->gp0_arvalid = 1; break;
      case R_DATA: dut->gp0_rready = 1; break;
      default: break;
    }
  }

  void sample(Dut *dut) {
    s_awvalid = dut->gp0_awvalid; s_awready = dut->gp0_awready;
    s_wvalid = dut->gp0_wvalid;   s_wready = dut->gp0_wready;
    s_bvalid = dut->gp0_bvalid;   s_bready = dut->gp0_bready;
    s_arvalid = dut->gp0_arvalid; s_arready = dut->gp0_arready;
    s_rvalid = dut->gp0_rvalid;   s_rready = dut->gp0_rready;
    s_rlast = dut->gp0_rlast;     s_rdata = dut->gp0_rdata;
    s_bresp = dut->gp0_bresp;     s_rresp = dut->gp0_rresp;
    ring[ring_at] = Moment{ticks, (long)st, s_arvalid, s_arready, s_rvalid,
                           s_rready, s_awready, s_wready, s_bvalid};
    ring_at = (ring_at + 1) % 2048;
  }

  void after_edge(Dut *) {
    switch (st) {
      case W_ADDR:
        if (s_awvalid && s_awready) aw_done = true;
        if (s_wvalid && s_wready) w_done = true;
        if (aw_done && w_done) st = W_RESP;
        break;
      case W_RESP:
        if (s_bvalid && s_bready) {
          // Every register this program touches is in the window, so SLVERR
          // here is the pack side answering an address it should not have to.
          if (s_bresp != 0) fail("GP0: a register write came back not OKAY");
          st = IDLE; finished = true;
        }
        break;
      case R_ADDR:
        if (s_arvalid && s_arready) st = R_DATA;
        break;
      case R_DATA:
        if (s_rvalid && s_rready) {
          if (!s_rlast) fail("GP0: a single-beat read without RLAST");
          if (s_rresp != 0) fail("GP0: a register read came back not OKAY");
          last_rdata = s_rdata;
          st = IDLE; finished = true;
          ++id;
        }
        break;
      default: break;
    }
  }
};

// ----------------------------------------------------------- the program
//
// `cadr-disk-packs`'s loop, as a state machine over the accesses above.
//
// **THE SLOT IS THE PROGRAM'S CHOICE AND THE FABRIC'S TAG IS THE TRUTH.**
// The replacement rule here is the documented one --- second chance over the
// REF bits the fabric keeps, never the slot the walk is on, a dirty slot
// written back to the pack before it is taken --- and the program keeps its
// own note of which block it put in which slot, because the tags live in
// fabric and are not readable over GP0.
template <class Dut>
struct Feeder {
  Gp0Linux<Dut> *gp0 = nullptr;
  // What the pack holds.  `read` fills 256 words and says whether the block
  // is on the pack at all; `write` takes a block back.
  std::function<bool(unsigned, unsigned, unsigned, unsigned, uint32_t *)> read_block;
  std::function<void(unsigned, unsigned, unsigned, unsigned, const uint32_t *)> write_block;
  // The header and the two checkwords, which Linux computes for a block
  // nothing has laid.
  std::function<uint32_t(unsigned, unsigned, unsigned)> header_of;
  std::function<uint32_t(const uint8_t *, int)> ecc_bytes;
  std::function<uint32_t(const uint32_t *, int)> ecc_words;
  // The staging records in DDR, which the fabric reads and writes through
  // HP2.  The caller owns the memory; these put a word in and take one out.
  std::function<void(uint32_t, uint32_t)> poke;
  std::function<uint32_t(uint32_t)> peek;

  // Which drives are on the cable, and whether their own time is charged.
  uint8_t present = 0x01, read_only = 0x00;
  bool timed = false;

  // The program's own note of the cache.
  bool valid[kSlots] = {false};
  uint32_t tag[kSlots] = {0};
  uint64_t used[kSlots] = {0};
  int hand = 0;

  long served = 0, written_back = 0, denied = 0, refusals = 0, errors = 0;
  long polls = 0, taken_at_start = 0;
  long declined_already_held = 0;
  long serve_ticks = 0, longest_serve = 0;
  uint64_t serve_started = 0;

  // The state machine.  Each state issues at most one register access and
  // moves on when it finishes, so the machine under it keeps running.
  enum St {
    S_START_TAKE_SLOT, S_START_TAKE_CTL, S_START_DRIVE,
    S_POLL_REQ,
    S_WB_ADDR, S_WB_SLOT, S_WB_CTL, S_WB_POLL, S_WB_HARVEST,
    S_DENY,
    S_F_ADDR, S_F_TAG, S_F_SLOT, S_F_CTL, S_F_POLL,
  };
  St st = S_START_TAKE_SLOT;
  int step = 0;                 // the slot being taken away at the start
  int slot = 0;                 // the slot being filled or written back
  uint32_t want = 0;            // the tag the walk is waiting for
  uint32_t ctl_seen = 0;
  bool issued = false;

  // The record being staged, kept so that a write-back's harvest and a
  // fetch's placement are one place.
  uint32_t rec[kRecordWords];

  void place_record(uint32_t at) {
    for (int i = 0; i < kRecordWords; ++i) poke(at + 4u * i, rec[i]);
  }
  void take_record(uint32_t at) {
    for (int i = 0; i < kRecordWords; ++i) rec[i] = peek(at + 4u * i);
  }

  // One tick of the program.  `walk_slot` and `walk_holds` are the interlock
  // the real program reads out of CTL; they are passed in because the caller
  // already has them and reading CTL for every decision would double the
  // register traffic without changing what is tested.
  void tick(uint64_t now, int req_valid, uint32_t req_tag, int ch_waiting,
            int walk_holds, int walk_slot) {
    if (gp0->busy()) return;
    const uint32_t got = gp0->rdata();
    switch (st) {
      // ---- the start: every slot taken away, then the drives on the cable
      case S_START_TAKE_SLOT:
        gp0->start_write(R_SLOT, static_cast<uint32_t>(step));
        st = S_START_TAKE_CTL;
        return;
      case S_START_TAKE_CTL:
        gp0->start_write(R_CTL, CTL_TAKE);
        ++taken_at_start;
        ++step;
        st = (step < kSlots) ? S_START_TAKE_SLOT : S_START_DRIVE;
        return;
      case S_START_DRIVE:
        gp0->start_write(R_DRIVE,
                         static_cast<uint32_t>(present) |
                             (static_cast<uint32_t>(read_only) << 8) |
                             (timed ? (1u << 16) : 0u));
        st = S_POLL_REQ;
        return;

      // ---- the loop
      case S_POLL_REQ: {
        ++polls;
        if (!req_valid) return;
        const uint32_t t2 = req_tag & 0x7FFF'FFFFu;
        // The block may already be in the store: `req_valid` is a LEVEL that
        // stands until a tag becomes it, and a program that acts on the level
        // alone refills one block for ever.  `cadr-disk-packs` acts on what it
        // has already served; so does this.
        for (int s = 0; s < kSlots; ++s)
          if (valid[s] && tag[s] == t2) { ++declined_already_held; return; }
        want = t2;
        serve_started = now;
        const unsigned unit = (t2 >> 28) & 7u;
        const unsigned c = (t2 >> 16) & 0xFFFu;
        const unsigned h = (t2 >> 8) & 0xFFu;
        const unsigned b = t2 & 0xFFu;
        if (!read_block(unit, c, h, b, rec)) {
          // Linux cannot serve it.  The deny is only delivered while the walk
          // is standing: elsewhere it drops the request without ending the
          // transfer.
          if (!ch_waiting) return;
          st = S_DENY;
          return;
        }
        rec[kBlockWords] = header_of(c, h, b);
        {
          const uint32_t hd = rec[kBlockWords];
          const uint8_t hb[4] = {
              static_cast<uint8_t>(hd), static_cast<uint8_t>(hd >> 8),
              static_cast<uint8_t>(hd >> 16), static_cast<uint8_t>(hd >> 24)};
          rec[kBlockWords + 1] = ecc_bytes(hb, 4);
        }
        rec[kBlockWords + 2] = ecc_words(rec, kBlockWords);
        // Second chance, never the slot the walk is on.
        slot = -1;
        for (int i = 0; i < kSlots && slot < 0; ++i) {
          const int s = (hand + i) % kSlots;
          if (walk_holds && s == walk_slot) continue;
          if (!valid[s]) slot = s;
        }
        if (slot < 0) {
          uint64_t oldest = UINT64_MAX;
          for (int s = 0; s < kSlots; ++s) {
            if (walk_holds && s == walk_slot) continue;
            if (used[s] < oldest) { oldest = used[s]; slot = s; }
          }
        }
        if (slot < 0) return;             // every slot is the walk's: wait
        hand = (slot + 1) % kSlots;
        st = dirty[slot] ? S_WB_ADDR : S_F_ADDR;
        return;
      }

      // ---- a dirty slot goes back to the pack before it is taken
      case S_WB_ADDR:
        gp0->start_write(R_ADDR, wb_addr(slot));
        st = S_WB_SLOT;
        return;
      case S_WB_SLOT:
        gp0->start_write(R_SLOT, static_cast<uint32_t>(slot));
        st = S_WB_CTL;
        return;
      case S_WB_CTL:
        gp0->start_write(R_CTL, CTL_WRITE);
        st = S_WB_POLL;
        issued = true;
        return;
      case S_WB_POLL:
        if (issued) { issued = false; gp0->start_read(R_CTL); return; }
        ctl_seen = got;
        if (ctl_seen & ST_REFUSED) { ++refusals; st = S_WB_ADDR; return; }
        if (ctl_seen & ST_ERROR) ++errors;
        if (ctl_seen & ST_BUSY) { gp0->start_read(R_CTL); return; }
        st = S_WB_HARVEST;
        return;
      case S_WB_HARVEST: {
        take_record(wb_addr(slot));
        const uint32_t t2 = tag[slot];
        write_block((t2 >> 28) & 7u, (t2 >> 16) & 0xFFFu, (t2 >> 8) & 0xFFu,
                    t2 & 0xFFu, rec);
        dirty[slot] = false;
        valid[slot] = false;
        ++written_back;
        // The record for the fetch has to be rebuilt: `rec` was the slot's.
        st = S_POLL_REQ;
        return;
      }

      // ---- the block is not on the pack
      case S_DENY:
        gp0->start_write(R_CTL, CTL_DENY);
        ++denied;
        st = S_POLL_REQ;
        return;

      // ---- the fetch
      case S_F_ADDR:
        place_record(fetch_addr(slot));
        gp0->start_write(R_ADDR, fetch_addr(slot));
        st = S_F_TAG;
        return;
      case S_F_TAG:
        gp0->start_write(R_TAG, want);
        st = S_F_SLOT;
        return;
      case S_F_SLOT:
        gp0->start_write(R_SLOT, static_cast<uint32_t>(slot));
        st = S_F_CTL;
        return;
      case S_F_CTL:
        gp0->start_write(R_CTL, CTL_FETCH);
        issued = true;
        st = S_F_POLL;
        return;
      case S_F_POLL:
        if (issued) { issued = false; gp0->start_read(R_CTL); return; }
        ctl_seen = got;
        if (ctl_seen & ST_REFUSED) { ++refusals; st = S_F_ADDR; return; }
        if (ctl_seen & ST_ERROR) ++errors;
        if (ctl_seen & ST_BUSY) { gp0->start_read(R_CTL); return; }
        valid[slot] = true;
        tag[slot] = want;
        used[slot] = now;
        dirty[slot] = false;
        ++served;
        {
          const long took = static_cast<long>(now - serve_started);
          serve_ticks += took;
          if (took > longest_serve) longest_serve = took;
        }
        st = S_POLL_REQ;
        return;
    }
  }

  // A transfer has written a slot: the pack holds the block only once this
  // side has taken it out again.  The caller reports `ch_wrote`.
  bool dirty[kSlots] = {false};
  void wrote(int s) { if (s >= 0 && s < kSlots) dirty[s] = true; }
  void hit(int s, uint64_t now) { if (s >= 0 && s < kSlots) used[s] = now; }
};

}  // namespace pack_linux

#endif  // CADR_PACK_LINUX_H
