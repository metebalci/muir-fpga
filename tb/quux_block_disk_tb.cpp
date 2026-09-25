// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Holds rtl/machine/quux_block_disk.sv to muir's `block_disk::BlockDisk` over
// the script `golden/src/quux_block_disk.rs` writes: the registers written
// and read at muir's instants, the done interrupt on either side of the
// instant muir raises it, and at the end every page of main memory and every
// block of the pack the script names, each by its hash.
//
// WHAT IS STIMULUS, AND WHY IT CANNOT MOVE WITH A BUG.  Main memory and the
// pack start as a rule of the address alone, `mem_word` and `pack_word`,
// which the generator and this file both write down; everything that moves
// either of them afterwards moves it through the module --- the channel's
// writes into memory, and the pack side's write-backs of the slots the walk
// wrote --- so what is compared at the end is what the module did, against
// what muir did.  The pack side here is a Linux of its own: it answers a
// request some ticks later by taking a slot away, filling it and writing its
// tag, a dirty slot written back first; a block past the pack's end is
// denied.  Memory answers each channel cycle a few ticks after it asks.
//
// The instants.  Tick 0 is the first after reset; an access at NS has its
// address and direction up the tick before and `-XBUS.RQ` on tick NS / 10,
// which is where the register face answers it, and a read's word is taken
// there.  Nothing here keeps a model of the controller.

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "Vquux_block_disk.h"
#include "verilated.h"

namespace {

constexpr int kSlots = 24;
constexpr int kBlockWords = 256;
constexpr uint32_t kRegs = 017377774u;
constexpr int kMemLatency = 3;     // ticks from a channel request to its answer
constexpr int kPackLatency = 40;   // ticks from a request to the pack side's move

uint32_t pack_word(uint32_t lba, uint32_t w) {
  const uint32_t rot = (lba << 23) | (lba >> 9);
  return (lba << 12) ^ (w << 1) ^ 0x5a000001u ^ rot;
}
uint32_t mem_word(uint32_t a) { return a * 0x9e3779b9u ^ 0x0c0ffee0u; }
uint32_t hash(const uint32_t *w, size_t n) {
  uint32_t h = 0x811c9dc5u;
  for (size_t i = 0; i < n; ++i)
    for (int b = 0; b < 4; ++b) {
      h ^= (w[i] >> (8 * b)) & 0xff;
      h *= 0x01000193u;
    }
  return h;
}

struct Op {
  char kind;
  uint32_t a, b;
  uint64_t ns;
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *path = (argc > 1) ? argv[1] : "build/quux_block_disk.quux.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s\n", path);
    return 2;
  }
  uint32_t blocks = 0, mem_words = 0;
  std::set<uint32_t> preloaded;
  std::vector<Op> ops;
  std::map<uint32_t, uint32_t> want_page, want_block;
  char line[256];
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    unsigned a = 0, b = 0;
    unsigned long long ns = 0;
    char k[16];
    if (std::sscanf(line, "geometry %x %x", &a, &b) == 2) {
      blocks = a;
      mem_words = b;
    } else if (std::sscanf(line, "pack %x", &a) == 1) {
      preloaded.insert(a);
    } else if (std::sscanf(line, "mem %x %x", &a, &b) == 2) {
      ops.push_back({'m', a, b, 0});
    } else if (std::sscanf(line, "page %x %x", &a, &b) == 2) {
      want_page[a] = b;
    } else if (std::sscanf(line, "block %x %x", &a, &b) == 2) {
      want_block[a] = b;
    } else if (std::sscanf(line, "i %x %llx", &a, &ns) == 2) {
      ops.push_back({'i', a, 0, ns});
    } else if (std::sscanf(line, "%15s %x %x %llx", k, &a, &b, &ns) == 4 && (k[0] == 'w' || k[0] == 'r')) {
      ops.push_back({k[0], a, b, ns});
    } else {
      std::fprintf(stderr, "%s: cannot read: %s", path, line);
      return 2;
    }
  }
  std::fclose(f);

  std::vector<uint32_t> mem(mem_words);
  for (uint32_t a = 0; a < mem_words; ++a) mem[a] = mem_word(a);
  std::map<uint32_t, std::vector<uint32_t>> pack;   // blocks written back
  auto pack_block = [&](uint32_t lba) {
    std::vector<uint32_t> b(kBlockWords, 0);
    const auto it = pack.find(lba);
    if (it != pack.end()) return it->second;
    if (preloaded.count(lba))
      for (int w = 0; w < kBlockWords; ++w) b[w] = pack_word(lba, w);
    return b;
  };

  auto *dut = new Vquux_block_disk;
  long bad = 0, tick_n = -1;
  auto fail = [&](const char *what, uint64_t got, uint64_t want, uint64_t ns) {
    if (bad < 20)
      std::fprintf(stderr, "at %" PRIu64 " ns: %s is %" PRIx64 ", muir has %" PRIx64 "\n", ns,
                   what, got, want);
    ++bad;
  };

  // --- the pack side --------------------------------------------------------
  uint32_t slot_tag[kSlots];
  bool slot_valid[kSlots] = {}, slot_dirty[kSlots] = {};
  int victim_rr = 0;
  // One move at a time: a write-back of 256 words, then a fill.
  enum { P_IDLE, P_WAIT, P_BACK, P_FILL } pstate = P_IDLE;
  int p_t = 0, p_slot = 0, p_k = 0;
  uint32_t p_lba = 0;
  std::vector<uint32_t> p_words;
  std::vector<uint32_t> back(kBlockWords);
  long served = 0, written_back = 0, denied = 0, walks_waited = 0;

  // --- the channel's memory -------------------------------------------------
  int m_t = -1;
  long mem_cycles = 0;

  auto drive_idle = [&]() {
    dut->store_we = 0;
    dut->store_deny = 0;
  };

  auto tick = [&]() {
    // Memory: answer a request kMemLatency ticks after it rose.
    dut->ch_done = 0;
    dut->ch_nxm = 0;
    if (dut->ch_req) {
      if (m_t < 0) m_t = 0;
      if (++m_t > kMemLatency) {
        const uint32_t a = dut->ch_addr;
        dut->ch_done = 1;
        if (a >= mem_words) {
          dut->ch_nxm = 1;
          dut->ch_rdata = 0xdeadbeef;
        } else if (dut->ch_write) {
          mem[a] = dut->ch_wdata;
        } else {
          dut->ch_rdata = mem[a];
        }
        ++mem_cycles;
        m_t = -1000;   // until the request drops
      }
    } else {
      m_t = -1;
    }
    // The pack side.
    drive_idle();
    dut->store_busy = 0;
    switch (pstate) {
      case P_IDLE:
        if (dut->req_valid) {
          pstate = P_WAIT;
          p_t = 0;
          p_lba = dut->req_tag & 0x0fffffffu;
          if (dut->ch_waiting) ++walks_waited;
        }
        break;
      case P_WAIT:
        if (!dut->req_valid) {
          pstate = P_IDLE;
          break;
        }
        if (++p_t < kPackLatency) break;
        if (p_lba >= blocks) {
          dut->store_deny = 1;
          ++denied;
          pstate = P_IDLE;
          break;
        }
        // A victim: an invalid slot first, else round robin, never the one
        // the walk is on while it is not waiting.
        p_slot = -1;
        for (int s = 0; s < kSlots && p_slot < 0; ++s)
          if (!slot_valid[s]) p_slot = s;
        while (p_slot < 0) {
          const int s = victim_rr++ % kSlots;
          if (!(dut->ch_active && !dut->ch_waiting && dut->ch_slot_o == s)) p_slot = s;
        }
        p_k = 0;
        pstate = slot_dirty[p_slot] ? P_BACK : P_FILL;
        p_words = pack_block(p_lba);
        break;
      case P_BACK:
        // Read the slot's 256 words: the word at address k is on
        // `store_rdata` two ticks later.
        dut->store_busy = 1;
        dut->store_busy_slot = p_slot;
        dut->store_slot = p_slot;
        dut->store_addr = p_k < kBlockWords ? p_k : 0;
        if (p_k >= 2) back[p_k - 2] = dut->store_rdata;
        if (++p_k == kBlockWords + 2) {
          pack[slot_tag[p_slot]] = back;
          slot_dirty[p_slot] = false;
          ++written_back;
          if (p_lba == slot_tag[p_slot]) p_words = back;
          p_k = 0;
          pstate = P_FILL;
        }
        break;
      case P_FILL:
        dut->store_busy = 1;
        dut->store_busy_slot = p_slot;
        dut->store_we = 1;
        dut->store_slot = p_slot;
        if (p_k == 0) {
          dut->store_addr = 259;
          dut->store_wdata = 0x80000000u;   // taken away first
          slot_valid[p_slot] = false;
        } else if (p_k <= kBlockWords) {
          dut->store_addr = p_k - 1;
          dut->store_wdata = p_words[p_k - 1];
        } else if (p_k <= kBlockWords + 3) {
          dut->store_addr = 256 + (p_k - kBlockWords - 1);
          dut->store_wdata = 0;
        } else {
          dut->store_addr = 259;
          dut->store_wdata = p_lba;
          slot_valid[p_slot] = true;
          slot_tag[p_slot] = p_lba;
          ++served;
          pstate = P_IDLE;
        }
        ++p_k;
        break;
    }
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
    if (dut->ch_wrote) slot_dirty[dut->ch_slot_o] = true;
    ++tick_n;
  };

  dut->rst = 1;
  dut->xbus_init = 0;
  dut->drive_present = 1;
  dut->drive_read_only = 0;
  dut->drive_timed = 0;
  dut->sel = 0;
  dut->dev_rq = 0;
  dut->dev_write = 0;
  dut->phys = 0;
  dut->wdata = 0;
  drive_idle();
  dut->store_busy = 0;
  dut->store_slot = 0;
  dut->store_addr = 0;
  dut->ch_done = 0;
  tick();
  tick();
  dut->rst = 0;
  tick_n = -1;
  tick();   // tick 0

  long reads = 0, writes = 0, irqs = 0;
  for (const Op &op : ops) {
    if (op.kind == 'm') {
      mem[op.a] = op.b;
      continue;
    }
    const long at = static_cast<long>(op.ns / 10);
    if (op.kind == 'i') {
      while (tick_n < at - 1) tick();
      dut->eval();
      if (dut->intr != op.a) fail("the done interrupt", dut->intr, op.a, op.ns);
      ++irqs;
      continue;
    }
    while (tick_n < at - 2) tick();
    // The tick before: the address and the direction.
    dut->sel = 1;
    dut->phys = kRegs + op.a;
    dut->dev_write = op.kind == 'w';
    dut->wdata = op.kind == 'w' ? op.b : 0xdeadbeef;
    tick();
    // The tick of the answer.
    dut->dev_rq = 1;
    dut->eval();
    if (!dut->dev_ack) fail("the acknowledgment", 0, 1, op.ns);
    if (op.kind == 'r') {
      if (dut->rdata != op.b) {
        char what[64];
        std::snprintf(what, sizeof what, "register %u", op.a);
        fail(what, dut->rdata, op.b, op.ns);
      }
      ++reads;
    } else {
      ++writes;
    }
    tick();
    dut->dev_rq = 0;
    dut->sel = 0;
  }
  // Let every write-back out, then compare.
  for (int n = 0; n < 200000; ++n) tick();
  for (int s = 0; s < kSlots; ++s) {
    if (!slot_dirty[s]) continue;
    std::vector<uint32_t> w(kBlockWords);
    for (int k = 0; k < kBlockWords + 2; ++k) {
      dut->store_slot = s;
      dut->store_addr = k < kBlockWords ? k : 0;
      if (k >= 2) w[k - 2] = dut->store_rdata;
      tick();
    }
    pack[slot_tag[s]] = w;
    ++written_back;
  }
  long pages = 0, blocks_seen = 0;
  for (const auto &p : want_page) {
    const uint32_t h = hash(&mem[p.first * 256], 256);
    if (h != p.second) {
      char what[64];
      std::snprintf(what, sizeof what, "main memory's page %o", p.first);
      fail(what, h, p.second, 0);
    }
    ++pages;
  }
  for (const auto &b : want_block) {
    const std::vector<uint32_t> w = pack_block(b.first);
    const uint32_t h = hash(w.data(), w.size());
    if (h != b.second) {
      char what[64];
      std::snprintf(what, sizeof what, "the pack's block %u", b.first);
      fail(what, h, b.second, 0);
    }
    ++blocks_seen;
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %ld mismatches\n", bad);
    return 1;
  }
  if (served == 0 || written_back == 0 || denied == 0 || walks_waited == 0 || pages == 0 ||
      blocks_seen == 0) {
    std::fprintf(stderr, "FAIL: the script reached too little: %ld served, %ld written back, "
                 "%ld denied, %ld waits, %ld pages, %ld blocks\n",
                 served, written_back, denied, walks_waited, pages, blocks_seen);
    return 1;
  }
  std::printf("ok: block-disk agrees with muir's block_disk::BlockDisk: %ld register reads, "
              "%ld writes, %ld interrupt instants, %ld pages and %ld blocks at the end;\n"
              "    the pack side served %ld blocks, wrote %ld back, denied %ld; %ld memory cycles\n",
              reads, writes, irqs, pages, blocks_seen, served, written_back, denied, mem_cycles);
  delete dut;
  return 0;
}
