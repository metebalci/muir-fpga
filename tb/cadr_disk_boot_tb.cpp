// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The channel walking a command list of more than one CCW, over a real
// System 100 pack, with the blocks fetched on demand --- against muir's
// `Controller::transfer`, word for word.
//
// **THE HOLE THIS CLOSES, AND THE BUG THAT FELL THROUGH IT.**  Three checks
// touch the channel and none of them could see this:
//
//   `disk.pass`     drives the whole register face against a reference trace
//                   on the 5 ns grid, but the pack is BLANK and every block
//                   a walk will need is already in the store before the
//                   START that needs it --- a Linux of no latency, which is
//                   what keeps the trace's rows on their instants.
//   `disk_pack.pass` fills the store on demand, but every command list in it
//                   is ONE CCW long bar a single chained pair whose first
//                   block is already resident.
//   `machine.pass`  is MIT's boot PROM: 512 identity memory cycles and no
//                   channel traffic at all.
//
// So no check had ever walked a list of more than one CCW whose blocks the
// store has to ask for, and none had ever moved a block of a real pack into
// main memory and compared it.  On 2026-09-10 the board booted, loaded its
// microcode off the pack, ran, and halted itself at microcode PC `0o5163` on
// `ILLOP-IF-PAGE-FAULT`: the cold boot's first `COLD-DISK-READ` is one list
// of three CCWs into physical pages 0, 1 and 2, page 0 arrived and pages 1
// and 2 did not.  Every transfer of the boot before it is a list of one,
// which is why the machine got that far.
//
// **WHAT THIS FILE IS.**  `build/disk_boot.golden`, out of
// `golden/src/disk_boot.rs`, carries:
//
//   - the blocks of the real pack as STIMULUS: 259 words a record, at an
//     address the generator chose, spread across the address bits so that a
//     fetch one record over lands on the DDR's poison and not on a
//     neighbour;
//   - main memory as the PROGRAM leaves it: the command lists, and the
//     poison every destination page carries, a function of the page and the
//     offset both, so that a page nothing wrote cannot read back like one
//     that was written;
//   - every page muir's own `Controller::transfer` moved, word for word,
//     and the disk address, memory address and status afterwards, as
//     EXPECTED OUTPUT;
//   - the 259 words a Write left in the store, written back and compared.
//
// **AND LINUX IS IN THE LOOP.**  The store comes up empty and stays a cache:
// the walk asks for what it lacks over REQ, and the feeder below --- second
// chance over the twenty-four slots, the walk's slot passed over, the same
// rule `linux/buildroot/package/cadr-disk-pack/src/pack_feeder.c` runs on the
// board --- answers it a varying number of ticks later.  Nothing is
// pre-filled: a fabric that could not ask would move no block at all.
//
// The feeder is STIMULUS and never a shadow: the record it serves comes from
// the trace's `BLK` row and never from the DUT, and a tag no `BLK` row named
// is DENIED rather than invented.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <string>
#include <vector>

#include "Vcadr_disk_harness.h"
#include "cadr_pack_side.h"
#include "verilated.h"

using namespace pack_side;

namespace {

const unsigned REGS = 017377774u;   // `disk_controller::REGS`, a word address
const int SLOTS = 24;
const long WALK_CAP = 1 << 22;

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

// One row of the trace, as read.
struct Row {
  char kind;                 // B block, W write-back, M memw, P mempage,
                             // X xfer, G page, R result
  uint64_t at = 0;           // BLK/WB: the record's address in DDR
  unsigned c = 0, h = 0, b = 0;
  unsigned hdr = 0, hck = 0, dck = 0;
  unsigned addr = 0, word = 0;      // MEMW
  unsigned page = 0;                // MEMPAGE, PAGE
  std::string name;                 // XFER
  unsigned cmd = 0, clp = 0, da = 0, nccw = 0;
  unsigned status = 0, lma = 0, npages = 0;
  size_t words = 0;                 // index into the bulk store
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <disk_boot.golden>\n", argv[0]);
    return 2;
  }
  // How often the processor's own wait loop reads the status register, in
  // ticks, and how long the feeder sits on a request before answering it.
  long poll_spacing = 300;
  long feed_delay = 0;
  for (int i = 2; i < argc; ++i) {
    if (!std::strcmp(argv[i], "--poll") && i + 1 < argc) poll_spacing = std::atol(argv[++i]);
    else if (!std::strcmp(argv[i], "--feed-delay") && i + 1 < argc) feed_delay = std::atol(argv[++i]);
  }
  std::FILE *f = std::fopen(argv[1], "r");
  if (!f) { std::perror(argv[1]); return 2; }
  {
    // The trace needs `vendor/`: a checkout without the System 100 release
    // gets a stub saying so, and this says so and passes, as `rtl_sys`
    // does.  A check that cannot run is not a check that failed.
    char first[64] = {0};
    if (std::fgets(first, sizeof first, f) && !std::strncmp(first, "# skipped", 9)) {
      std::printf("disk_boot: skipped --- no System 100 release\n");
      std::fclose(f);
      return 0;
    }
    std::rewind(f);
  }

  // ---- the trace ---------------------------------------------------------
  std::vector<Row> rows;
  std::vector<unsigned> bulk;      // every 256-word run, end to end
  unsigned memory_words = 0, block_words = 0;
  unsigned geom_c = 0, geom_h = 0, geom_b = 0;
  std::string line;
  {
    char *buf = nullptr;
    size_t cap = 0;
    ssize_t n;
    auto words_of = [&](Row &r, char *p, int count) {
      r.words = bulk.size();
      for (int i = 0; i < count; ++i) {
        unsigned v = 0;
        while (*p == ' ') ++p;
        char *end = nullptr;
        v = (unsigned)std::strtoul(p, &end, 16);
        // A short row is a broken trace and a failure, but the words are
        // still pushed so that nothing below indexes past the store.
        if (end == p) Say("a row is short of words");
        else p = end;
        bulk.push_back(v);
      }
    };
    while ((n = getline(&buf, &cap, f)) > 0) {
      if (buf[0] == '#') {
        std::sscanf(buf, "# geometry %u %u %u", &geom_c, &geom_h, &geom_b);
        std::sscanf(buf, "# memory_words %u", &memory_words);
        std::sscanf(buf, "# block_words %u", &block_words);
        continue;
      }
      Row r;
      char kind[16] = {0};
      if (std::sscanf(buf, "%15s", kind) != 1) continue;
      char *p = buf + std::strlen(kind);
      if (!std::strcmp(kind, "BLK") || !std::strcmp(kind, "WB")) {
        r.kind = kind[0] == 'B' ? 'B' : 'W';
        unsigned long long at = 0;
        int used = 0;
        std::sscanf(p, " %llx %x %x %x %x %x %x%n", &at, &r.c, &r.h, &r.b,
                    &r.hdr, &r.hck, &r.dck, &used);
        r.at = at;
        words_of(r, p + used, 256);
      } else if (!std::strcmp(kind, "MEMW")) {
        r.kind = 'M';
        std::sscanf(p, " %x %x", &r.addr, &r.word);
      } else if (!std::strcmp(kind, "MEMPAGE") || !std::strcmp(kind, "PAGE")) {
        r.kind = kind[0] == 'M' ? 'P' : 'G';
        int used = 0;
        std::sscanf(p, " %x%n", &r.page, &used);
        words_of(r, p + used, 256);
      } else if (!std::strcmp(kind, "XFER")) {
        r.kind = 'X';
        unsigned nn = 0;
        char nm[64] = {0};
        std::sscanf(p, " %u %63s %x %x %x %u", &nn, nm, &r.cmd, &r.clp, &r.da, &r.nccw);
        r.name = nm;
      } else if (!std::strcmp(kind, "RES")) {
        r.kind = 'R';
        std::sscanf(p, " %x %x %x %u", &r.status, &r.da, &r.lma, &r.npages);
      } else {
        continue;
      }
      rows.push_back(r);
    }
    std::free(buf);
  }
  std::fclose(f);
  if (rows.empty()) { Say("the trace has no rows"); return 1; }
  if (block_words != 256) { Fail("block_words", block_words, 256); return 1; }
  if (memory_words < (1u << 16)) { Fail("memory_words", memory_words, 1u << 16); return 1; }
  if (geom_c == 0 || geom_h == 0 || geom_b == 0) { Say("the trace names no geometry"); return 1; }

  auto *dut = new Vcadr_disk_harness;

  Ddr ddr;
  Hp2Slave hp2;
  hp2.ddr = &ddr;
  hp2.vary = true;
  hp2.complain = [](const char *w) { Say(w); };
  Gp0Master gp0;
  gp0.vary = true;
  gp0.complain = [](const char *w) { Say(w); };

  // Main memory, reached only through `ch_*`: the pack side never touches it
  // and neither does the feeder.  Zero where the program set nothing, and
  // poisoned by the trace's own `MEMPAGE` rows where it did.
  std::vector<unsigned> mem((size_t)memory_words, 0u);

  int d_sel = 0, d_rq = 0, d_wr = 0, d_rst = 1;
  unsigned d_phys = 0, d_wdata = 0;
  int live_sel = 0, live_reg = -1;
  long ch_up = -1, ch_serial = 0;
  int ch_served = 0;
  long ch_reads = 0, ch_writes = 0, ch_nxms = 0;
  unsigned sampled = 0;
  int req_now = 0;
  long req_rises = 0, waiting_ticks = 0, irq_ticks = 0, miss_rises = 0;
  int miss_now = 0;

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
    // The channel's answer, after the request has stood a tick or three: a
    // latency that varies, because a fixed one lets a master that assumed
    // one shape of handshake pass.
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
        if (a >= mem.size()) { dut->ch_nxm = 1; ++ch_nxms; }
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
    if (dut->req_valid && !req_now) ++req_rises;
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

  // ---- the pack side's registers ----------------------------------------
  auto reg_write = [&](unsigned r, uint32_t v) {
    gp0.write(dut, tick_fn, REG_BASE + 4 * r, v, 0xF);
  };
  auto reg_read = [&](unsigned r) -> uint32_t { return gp0.read(dut, tick_fn, REG_BASE + 4 * r); };
  auto wait_done = [&](const char *what) -> uint32_t {
    uint32_t st = 0;
    for (int n = 0; n < 4000; ++n) {
      st = reg_read(R_CTL);
      if (!(st & ST_BUSY)) return st;
    }
    Say(what);
    Say("the pack side stayed busy");
    return st;
  };
  auto go = [&](uint64_t at, uint32_t tg, unsigned slot, unsigned ctl) -> uint32_t {
    reg_write(R_ADDR, (uint32_t)at);
    reg_write(R_TAG, tg);
    reg_write(R_SLOT, slot);
    reg_write(R_CTL, ctl);
    return reg_read(R_CTL);
  };

  // ---- the pack, as the feeder knows it ---------------------------------
  // Every block a `BLK` row named: its record, and where in DDR it goes.
  // The trace is the only source; a tag nothing named is denied.
  struct Rec { uint64_t at; uint32_t w[RECORD_WORDS]; };
  std::vector<Rec> recs;
  std::vector<uint32_t> rec_tag;
  auto find_rec = [&](uint32_t tg) -> int {
    for (size_t i = 0; i < rec_tag.size(); ++i) if (rec_tag[i] == tg) return (int)i;
    return -1;
  };
  auto put_rec = [&](uint64_t at, uint32_t tg, const unsigned *data,
                     uint32_t hdr, uint32_t hck, uint32_t dck) {
    Rec r;
    r.at = at;
    for (int i = 0; i < 256; ++i) r.w[i] = data[i];
    r.w[256] = hdr; r.w[257] = hck; r.w[258] = dck;
    ddr.place(at, r.w);
    const int k = find_rec(tg);
    if (k < 0) { recs.push_back(r); rec_tag.push_back(tg); }
    else recs[(size_t)k] = r;
  };

  // ---- the feeder --------------------------------------------------------
  // Second chance over the twenty-four slots, the walk's slot passed over
  // when the face refuses it: `pack_feeder.c`'s own rule.
  int slot_tag[SLOTS];
  for (int s = 0; s < SLOTS; ++s) slot_tag[s] = -1;
  unsigned hand = 0;
  long served = 0, denied = 0, refused_walk = 0, wrote_back = 0;
  long polls = 0, polls_saw_ready = 0, served_irq_cleared = 0;
  uint32_t feed_seed = 0x0910A5A5u;

  auto next_victim = [&](uint32_t skip) -> int {
    uint32_t ref = reg_read(R_REF);
    for (int tries = 0; tries < 2 * SLOTS + 1; ++tries) {
      const unsigned s = hand;
      hand = (hand + 1) % SLOTS;
      if (skip & (1u << s)) continue;
      if (ref & (1u << s)) { reg_write(R_REF, 1u << s); ref &= ~(1u << s); continue; }
      return (int)s;
    }
    return -1;
  };
  // The write-back of a slot, to `at`, with the record compared afterwards.
  auto writeback_slot = [&](unsigned s, uint64_t at, const char *what) -> int {
    uint32_t st = go(at, 0, s, CTL_WRITE);
    if (st & ST_REFUSED) return 1;      // the walk's slot; try again later
    st = wait_done(what);
    if (!(st & ST_DONE)) { Say(what); Fail("done after a write-back", st, ST_DONE); return -1; }
    ++wrote_back;
    return 0;
  };
  // One request answered.  The record comes from the trace; a block no `BLK`
  // row named is denied, which is what the board's feeder does with a block
  // off the pack.
  auto answer = [&](uint32_t tg) {
    const int k = find_rec(tg);
    if (k < 0) { reg_write(R_CTL, CTL_DENY); ++denied; return; }
    uint32_t skip = 0;
    for (int tries = 0; tries < SLOTS; ++tries) {
      const int v = next_victim(skip);
      if (v < 0) break;
      if (reg_read(R_DIRTY) & (1u << v)) {
        // A dirty victim would lose the CADR's write; this check writes
        // every dirty slot back at the end of the transfer that made it, so
        // reaching here means the bookkeeping is wrong.
        Say("second chance picked a dirty slot mid-transfer");
        skip |= 1u << (unsigned)v;
        continue;
      }
      ddr.place(recs[(size_t)k].at, recs[(size_t)k].w);
      uint32_t st = go(recs[(size_t)k].at, tg, (unsigned)v, CTL_FETCH);
      if (st & ST_REFUSED) { ++refused_walk; skip |= 1u << (unsigned)v; continue; }
      st = wait_done("a fetch the walk asked for");
      if (!(st & ST_DONE)) { Fail("done after a fetch", st, ST_DONE); return; }
      for (int s = 0; s < SLOTS; ++s) if (s != v && slot_tag[s] == (int)tg) slot_tag[s] = -1;
      slot_tag[v] = (int)tg;
      ++served;
      // The events, cleared as read, as `feeder_pass` clears them: an
      // interrupt line left up would say nothing about the next request.
      reg_write(R_IRQ, IRQ_REQ | IRQ_DIRTY | IRQ_DONE);
      ++served_irq_cleared;
      return;
    }
    Say("no slot could take a requested block");
  };

  // ---- the Xbus face -----------------------------------------------------
  auto do_read = [&](int reg) -> unsigned {
    if (!(live_sel && live_reg == reg)) {
      d_sel = 1; d_rq = 1; d_wr = 0; d_phys = REGS | (unsigned)reg;
      run_tick(false);
    }
    d_sel = 1; d_rq = 1; d_wr = 0; d_phys = REGS | (unsigned)reg;
    run_tick(true);
    return sampled;
  };
  auto do_write = [&](int reg, unsigned v) {
    d_sel = 1; d_rq = 0; d_wr = 1; d_phys = REGS | (unsigned)reg; d_wdata = v;
    run_tick(false);
    d_rq = 1;
    run_tick(false);
    run_tick(false);
    run_tick(false);
  };

  // The walk, run to its end with the feeder answering what it asks for.
  // The answer is deliberately LATE: a varying number of ticks after the
  // request goes up, so that a walk which assumed the block was there the
  // tick it asked fails.  `POLL_SPACING` and the feeder's delay can be
  // pushed from the command line, so that a Linux slower than any board's
  // and a processor busier than any can be run over the same trace.
  auto settle_walk = [&](const char *what) -> bool {
    d_rq = 0;
    const long began = tick;
    long pending_since = -1;
    long next_poll = tick + poll_spacing;
    while (dut->ch_active) {
      // **THE PROCESSOR POLLS WHILE THE TRANSFER RUNS.**
      // `uc-disk.lisp`'s `DISK-RECALIBRATE-WAIT`, which `COLD-RUN-DISK`
      // calls, sits in a two-instruction loop reading the status register
      // until `<0>` is up and `<8>` is down --- so on the board every
      // transfer is walked with a bus cycle on the controller's own
      // register face every few hundred ticks, and with the memory path's
      // arbiter handing those cycles to the processor ahead of the channel.
      // Nothing else here reads a register during a walk.
      if (poll_spacing > 0 && tick >= next_poll) {
        const unsigned st = do_read(0);
        ++polls;
        if (st & 1u) ++polls_saw_ready;
        d_rq = 0;
        next_poll = tick + poll_spacing;
        continue;
      }
      if (dut->req_valid) {
        if (pending_since < 0) pending_since = tick;
        if (tick - pending_since >= feed_delay + (long)(lcg(feed_seed) % 7 + 1)) {
          const uint32_t rq = reg_read(R_REQ);
          if (rq & REQ_VALID) answer(rq & 0x7FFFFFFFu);
          pending_since = -1;
        } else {
          run_tick(false);
        }
      } else {
        pending_since = -1;
        run_tick(false);
      }
      if (tick - began > WALK_CAP) {
        Say(what);
        Say("the channel was still walking at the cap");
        std::fprintf(stderr,
                     "  waiting=%d req_valid=%d req_tag=%08x store_miss=%d\n",
                     (int)dut->ch_waiting, (int)dut->req_valid,
                     (unsigned)dut->req_tag, (int)dut->store_miss);
        return false;
      }
    }
    for (int q = 0; q < 4; ++q) run_tick(false);
    return true;
  };

  // ---- the run -----------------------------------------------------------
  // The drive on unit 0: present, writable, its own time not charged.
  reg_write(R_DRIVE, 0x00000001u);
  reg_write(R_REF, 0xFFFFFFFFu);
  reg_write(R_IRQ, 0x7u);
  // The interrupt Linux actually runs on: a request posted raises `IRQ_F2P`,
  // and a check whose feeder polls instead would never exercise the line the
  // board's driver waits on.
  reg_write(R_IRQEN, IRQ_REQ | IRQ_DIRTY | IRQ_DONE);

  long xfers = 0, pages_compared = 0, words_compared = 0, blk_rows = 0, wb_rows = 0;
  long ccws_walked = 0, longest = 0;
  std::string xname;
  for (size_t i = 0; i < rows.size(); ++i) {
    const Row &r = rows[i];
    switch (r.kind) {
      case 'B': {
        ++blk_rows;
        put_rec(r.at, pack_side::tag_of(0, r.c, r.h, r.b), &bulk[r.words],
                r.hdr, r.hck, r.dck);
        break;
      }
      case 'M':
        if (r.addr >= mem.size()) { Say("a MEMW row is off the end of memory"); break; }
        mem[r.addr] = r.word;
        break;
      case 'P':
        for (int k = 0; k < 256; ++k) mem[(size_t)r.page * 256u + (unsigned)k] = bulk[r.words + (size_t)k];
        break;
      case 'X': {
        ++xfers;
        xname = r.name;
        phase = xname.c_str();
        ccws_walked += r.nccw;
        if ((long)r.nccw > longest) longest = (long)r.nccw;
        do_write(0, r.cmd);
        do_write(1, r.clp);
        do_write(2, r.da);
        do_write(3, 0);
        if (!settle_walk(xname.c_str())) { std::fprintf(stderr, "giving up\n"); goto done; }
        break;
      }
      case 'G': {
        ++pages_compared;
        int said = 0;
        for (int k = 0; k < 256; ++k) {
          const unsigned got = mem[(size_t)r.page * 256u + (unsigned)k];
          const unsigned want = bulk[r.words + (size_t)k];
          ++words_compared;
          if (got != want && said < 4) {
            char msg[160];
            std::snprintf(msg, sizeof msg, "page %x word %d", r.page, k);
            Fail(msg, got, want);
            ++said;
          }
        }
        break;
      }
      case 'R': {
        // The block counter, `STATUS<31:24>`, is the drive's rotational
        // position and this check does not place its rows on muir's clock,
        // so the comparison is of the twenty-four bits below it.  Everything
        // that says what the transfer DID is in those.
        const unsigned st = do_read(0);
        if ((st & 0x00FFFFFFu) != (r.status & 0x00FFFFFFu))
          Fail("the status after a transfer", st & 0x00FFFFFFu, r.status & 0x00FFFFFFu);
        const unsigned da = do_read(2);
        if (da != r.da) Fail("the disk address after a transfer", da, r.da);
        const unsigned lma = do_read(1);
        if (lma != r.lma) Fail("the memory address after a transfer", lma, r.lma);
        d_rq = 0;
        run_tick(false);
        break;
      }
      case 'W': {
        // A block a Write put on the pack: the slot holding it must be
        // dirty, and what the pack side writes back must be the 259 words
        // muir's own drive now has.
        ++wb_rows;
        const uint32_t tg = pack_side::tag_of(0, r.c, r.h, r.b);
        int s = -1;
        for (int k = 0; k < SLOTS; ++k) if (slot_tag[k] == (int)tg) s = k;
        if (s < 0) { Say("a written block is in no slot the feeder filled"); break; }
        const uint32_t dirty = reg_read(R_DIRTY);
        if (!(dirty & (1u << (unsigned)s))) {
          Fail("DIRTY for the slot a Write wrote", dirty, 1u << (unsigned)s);
          break;
        }
        // Poison the destination, the pad included, so that a write-back
        // that moved nothing, or one that wrote the pad, is seen.
        for (int k = 0; k <= RECORD_WORDS; ++k)
          ddr.set_word(r.at + 4u * (unsigned)k, (unsigned)(0x5A5A0000u ^ (unsigned)k * 0x9E3779B1u));
        const int w = writeback_slot((unsigned)s, r.at, "a write-back after a Write");
        if (w != 0) { Say("the write-back of a written block was refused"); break; }
        uint32_t got[RECORD_WORDS];
        ddr.record(r.at, got);
        int said = 0;
        for (int k = 0; k < 256; ++k)
          if (got[k] != bulk[r.words + (size_t)k] && said < 4) {
            char msg[160];
            std::snprintf(msg, sizeof msg, "the word %d written back for block %x/%x/%x", k, r.c, r.h, r.b);
            Fail(msg, got[k], bulk[r.words + (size_t)k]);
            ++said;
          }
        if (got[256] != r.hdr) Fail("the header written back", got[256], r.hdr);
        if (got[257] != r.hck) Fail("the header checkword written back", got[257], r.hck);
        if (got[258] != r.dck) Fail("the data checkword written back", got[258], r.dck);
        if (ddr.pad(r.at) != (unsigned)(0x5A5A0000u ^ (unsigned)RECORD_WORDS * 0x9E3779B1u))
          Say("the pad word after a written-back record was written");
        break;
      }
      default: break;
    }
  }
done:
  phase = "the end";

  // ---- what the run has to have done -------------------------------------
  // A check that ran no transfer, moved no page, or never had to ask for a
  // block would pass a fabric that could do none of those.
  if (xfers < 8) Fail("transfers run", (unsigned)xfers, 8);
  if (longest < 16) Fail("the longest command list walked", (unsigned)longest, 16);
  if (pages_compared < 40) Fail("pages compared", (unsigned)pages_compared, 40);
  if (words_compared < 10000) Fail("words compared", (unsigned)words_compared, 10000);
  if (served < 40) Fail("blocks the feeder was asked for and served", (unsigned)served, 40);
  if (req_rises < 40) Fail("times REQ went up", (unsigned)req_rises, 40);
  if (waiting_ticks < 100) Fail("ticks the walk spent waiting for a block", (unsigned)waiting_ticks, 100);
  if (miss_rises != 0) Fail("times the walk missed the store", (unsigned)miss_rises, 0);
  if (irq_ticks < 1) Fail("ticks the interrupt to Linux was up", (unsigned)irq_ticks, 1);
  if (polls < 100) Fail("status reads made while a transfer was in flight", (unsigned)polls, 100);
  // The controller is BUSY for the whole of a walk: `<0>` not-active is down
  // at every one of the polls above, which is what `DISK-RECALIBRATE-WAIT`
  // spins on.  A walk that let it up mid-transfer would let the microcode go
  // on before the pages were there.
  if (polls_saw_ready != 0) Fail("polls that read not-active during a walk", (unsigned)polls_saw_ready, 0);
  if (denied != 0) Fail("blocks the feeder denied", (unsigned)denied, 0);
  if (ch_nxms != 0) Fail("channel cycles main memory did not answer", (unsigned)ch_nxms, 0);
  if (hp2.bad) Fail("protocol errors on S_AXI_HP2", (unsigned)hp2.bad, 0);
  if (gp0.bad) Fail("protocol errors on M_AXI_GP0", (unsigned)gp0.bad, 0);

  std::printf(
      "disk_boot: %ld transfers, %ld CCWs, longest list %ld; %ld pages and %ld words\n"
      "           compared against muir's Controller::transfer over a real pack\n"
      "           %ld blocks placed, %ld written back and compared\n"
      "           the store asked Linux for a block %ld times and was served %ld,\n"
      "           %ld ticks waiting, %ld ticks of interrupt, %ld denials, %ld walk refusals\n"
      "           %ld channel reads, %ld writes, %ld ticks\n"
      "           the processor read the status register %ld times during a walk,\n"
      "           %ld of them reading ready (a poll every %ld ticks, feeder delay %ld)\n",
      xfers, ccws_walked, longest, pages_compared, words_compared, blk_rows,
      wb_rows, req_rises, served, waiting_ticks, irq_ticks, denied, refused_walk,
      ch_reads, ch_writes, tick, polls, polls_saw_ready, poll_spacing, feed_delay);

  if (bad) {
    std::fprintf(stderr, "disk_boot: %d disagreement(s)\n", bad);
    return 1;
  }
  delete dut;
  return 0;
}
