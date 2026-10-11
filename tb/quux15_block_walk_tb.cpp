// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Holds rtl/machine/quux15_block_walk.sv, revision 15's walk and block
// store, to muir's `block_disk::BlockDisk::write` over the scripts
// `golden/src/quux13_block_disk.rs` writes, as `tb/quux13_block_disk_tb.cpp`
// holds revision 13's: the registers written and read at muir's instants,
// the done interrupt on either side of the instant muir raises it, and at the
// end every 1024-word page of main memory and every block of the pack the
// script names, each by its hash, and the GPT fixture's page read through an
// 8-bit view.  What is compared cannot move with a bug: main memory and the
// pack start as a rule of the address alone, and every change to either
// afterwards is the module's --- its writes into memory, and the pack side's
// write-backs of the slots the walk wrote.
//
// **THE REGISTERS AND DONE ARE `quux15_devices.sv`'S ON REVISION 15**, held
// by the core's goldens; here they are this testbench's, as that module keeps
// them: a START of a read or a write with a pack and the walk idle starts
// the walk with the command, the pointer and the disk address; DONE is the
// START's instant plus 100 us for each block the walk charges; not-active is
// the walk ended and DONE reached; the last memory address, the disk address
// (unless written since) and the errors (unless the command was written
// since) are the walk's at its end.  A clock is 10 ns, the scripts' grid.
//
// Main memory here is 40-bit words, `MAIN_WORDS` of them as the script's
// geometry says (the module is built so), answered a few clocks after the
// walk asks: **THE WALK ASKS FOR NOTHING PAST MAIN MEMORY'S END**, where the
// script puts the frame buffer window's pages too --- it finds NXM itself, as
// revision 15's port answers none --- and a word asked for past it is a
// failure here.  The pack side takes a slot away, fills it and writes its
// tag some clocks after a request, a dirty slot written back first, and
// denies a block past the pack's end.  **A REQUEST FOR A BLOCK AT 2^28 OR
// PAST IT IS A FAILURE HERE**: the tag the pack side reads carries the disk
// address's 28 bits, and such a block is past the end of every pack.
//
// The GPT fixture's page (`view`): its words read four bytes a word, byte i
// in word i/4 at 8(i mod 4), must be the bytes of the four blocks the pack
// was given, and every word must carry tag 005; the blocks are this
// program's own copy of muir-sim's `data/quux-disk.img`, from the script.

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "Vquux15_block_walk.h"
#include "verilated.h"

namespace {

constexpr int kSlots = 24;
constexpr int kBlockWords = 256;
constexpr uint32_t kPageWords = 1024;
constexpr int kMemLatency = 3;     // ticks from a channel request to its answer
constexpr int kPackLatency = 40;   // ticks from a request to the pack side's move
constexpr uint64_t kMask40 = (1ull << 40) - 1;

uint32_t pack_word(uint32_t lba, uint32_t w) {
  const uint32_t rot = (lba << 23) | (lba >> 9);
  return (lba << 12) ^ (w << 1) ^ 0x5a000001u ^ rot;
}
uint64_t mem_word(uint32_t a) {
  const uint64_t x = (static_cast<uint64_t>(a) + 1) * 0x9e3779b97f4a7c15ull;
  return ((x >> 17) ^ 0x5ac3a53c0full) & kMask40;
}
uint32_t hash(const uint64_t *w, size_t n, int bytes) {
  uint32_t h = 0x811c9dc5u;
  for (size_t i = 0; i < n; ++i)
    for (int b = 0; b < bytes; ++b) {
      h ^= (w[i] >> (8 * b)) & 0xff;
      h *= 0x01000193u;
    }
  return h;
}

struct Op {
  char kind;
  uint32_t a;
  uint64_t b;
  uint64_t ns;
};

// One script, on a DUT of its own: 0 when it agrees, else 1, or 2 when the
// script cannot be read.
int RunScript(const char *path) {
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s\n", path);
    return 2;
  }
  uint32_t blocks = 0, mem_words = 0;
  std::set<uint32_t> preloaded;
  std::map<uint32_t, std::vector<uint32_t>> raw;
  std::vector<Op> ops;
  std::map<uint32_t, uint32_t> want_page, want_block;
  std::vector<std::pair<uint32_t, uint32_t>> views;
  std::string line;
  {
    char buf[8192];
    while (std::fgets(buf, sizeof buf, f)) {
      line = buf;
      if (line[0] == '#' || line[0] == '\n') continue;
      unsigned a = 0, b = 0;
      unsigned long long x = 0, ns = 0;
      char k[16];
      if (std::sscanf(buf, "geometry %x %x", &a, &b) == 2) {
        blocks = a;
        mem_words = b;
      } else if (std::sscanf(buf, "pack %x", &a) == 1) {
        preloaded.insert(a);
      } else if (std::strncmp(buf, "raw ", 4) == 0) {
        char *p = buf + 4;
        const uint32_t lba = static_cast<uint32_t>(std::strtoul(p, &p, 16));
        std::vector<uint32_t> w(kBlockWords);
        for (int i = 0; i < kBlockWords; ++i) w[i] = static_cast<uint32_t>(std::strtoul(p, &p, 16));
        raw[lba] = w;
      } else if (std::sscanf(buf, "mem %x %llx", &a, &x) == 2) {
        ops.push_back({'m', a, x, 0});
      } else if (std::sscanf(buf, "view %x %x", &a, &b) == 2) {
        views.emplace_back(a, b);
      } else if (std::sscanf(buf, "page %x %x", &a, &b) == 2) {
        want_page[a] = b;
      } else if (std::sscanf(buf, "block %x %x", &a, &b) == 2) {
        want_block[a] = b;
      } else if (std::sscanf(buf, "i %x %llx", &a, &ns) == 2) {
        ops.push_back({'i', a, 0, ns});
      } else if (std::sscanf(buf, "%15s %x %llx %llx", k, &a, &x, &ns) == 4 && (k[0] == 'w' || k[0] == 'r')) {
        ops.push_back({k[0], a, x, ns});
      } else {
        std::fprintf(stderr, "%s: cannot read: %s", path, buf);
        return 2;
      }
    }
  }
  std::fclose(f);

  std::vector<uint64_t> mem(mem_words);
  for (uint32_t a = 0; a < mem_words; ++a) mem[a] = mem_word(a);
  std::map<uint32_t, std::vector<uint32_t>> pack;   // blocks written back
  auto pack_block = [&](uint32_t lba) {
    std::vector<uint32_t> b(kBlockWords, 0);
    const auto it = pack.find(lba);
    if (it != pack.end()) return it->second;
    const auto r = raw.find(lba);
    if (r != raw.end()) return r->second;
    if (preloaded.count(lba))
      for (int w = 0; w < kBlockWords; ++w) b[w] = pack_word(lba, w);
    return b;
  };

  auto *dut = new Vquux15_block_walk;
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
  enum { P_IDLE, P_WAIT, P_BACK, P_FILL } pstate = P_IDLE;
  int p_t = 0, p_slot = 0, p_k = 0;
  uint32_t p_lba = 0;
  std::vector<uint32_t> p_words;
  std::vector<uint32_t> back(kBlockWords);
  long served = 0, written_back = 0, denied = 0, walks_waited = 0, past_28 = 0;

  // --- main memory, through the port's D --------------------------------------
  int m_t = -1;
  long mem_reads = 0, mem_writes = 0, mem_nxm = 0, tagged_005 = 0, past_main = 0;

  // --- the registers and DONE, as `quux15_devices.sv` keeps them -----------
  uint32_t cmd = 0, clp = 0, da = 0, lma = 0;
  bool bad_cmd = false, past_end = false, nxm = false, own = false, da_own = false;
  bool started = false;
  uint64_t done_ns = 0;
  long charges = 0, walks = 0;

  auto tick = [&]() {
    dut->d_done = 0;
    if (dut->d_req) {
      if (m_t < 0) m_t = 0;
      if (++m_t > kMemLatency) {
        const uint32_t a = dut->d_addr;
        dut->d_done = 1;
        if (a >= mem_words) {
          std::fprintf(stderr, "at tick %ld: the walk asks main memory for word %o, past its end\n", tick_n, a);
          ++bad;
          ++past_main;
          dut->d_rdata = 0xdeadbeefa5ull;
        } else if (dut->d_write) {
          mem[a] = dut->d_wdata & kMask40;
          if ((mem[a] >> 32) == 05) ++tagged_005;
          ++mem_writes;
        } else {
          dut->d_rdata = mem[a];
          ++mem_reads;
        }
        m_t = -1000;
      }
    } else {
      m_t = -1;
    }
    dut->store_we = 0;
    dut->store_deny = 0;
    dut->store_busy = 0;
    switch (pstate) {
      case P_IDLE:
        if (dut->req_valid) {
          pstate = P_WAIT;
          p_t = 0;
          p_lba = dut->req_tag;
          if (p_lba >= (1u << 28)) {
            std::fprintf(stderr, "at tick %ld: the pack side is asked for block %x, past the "
                         "disk address's 28 bits\n", tick_n, p_lba);
            ++bad;
            ++past_28;
          }
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
          dut->store_wdata = 0x80000000u;
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
    dut->start = 0;
    if (dut->ch_wrote) slot_dirty[dut->ch_slot_o] = true;
    // The edge's charge and end, as the registers take them.
    if (dut->charge) {
      done_ns += 100000;
      ++charges;
    }
    if (dut->fin) {
      lma = dut->fin_lma;
      if (da_own) da = dut->fin_da;
      if (own) {
        past_end = dut->fin_past_end;
        nxm = dut->fin_nxm;
        mem_nxm += nxm;
      }
      ++walks;
    }
    ++tick_n;
  };

  dut->rst = 1;
  dut->start = 0;
  dut->st_cmd = 0;
  dut->st_clp = 0;
  dut->st_da = 0;
  dut->drive_present = 1;
  dut->store_we = 0;
  dut->store_deny = 0;
  dut->store_busy = 0;
  dut->store_slot = 0;
  dut->store_addr = 0;
  dut->d_done = 0;
  tick();
  tick();
  dut->rst = 0;
  tick_n = -1;
  tick();   // tick 0

  long reads = 0, writes = 0, irqs = 0;
  // The status as `quux15_devices.sv` reads it at `now`: not active once the
  // walk has ended and DONE is reached.
  auto not_active = [&](uint64_t now) { return !(started && (dut->walking || now < done_ns)); };
  auto status = [&](uint64_t now) {
    const bool na = not_active(now), intr = na && ((cmd >> 11) & 1);
    return static_cast<uint32_t>(nxm) << 20 | static_cast<uint32_t>(past_end) << 17 |
           static_cast<uint32_t>(bad_cmd || past_end || nxm) << 13 | static_cast<uint32_t>(intr) << 3 |
           static_cast<uint32_t>(na);
  };
  for (const Op &op : ops) {
    if (op.kind == 'm') {
      mem[op.a] = op.b & kMask40;
      continue;
    }
    const long at = static_cast<long>(op.ns / 10);
    while (tick_n < at) tick();
    const uint64_t now = static_cast<uint64_t>(at) * 10;
    if (op.kind == 'i') {
      const bool intr = not_active(now) && ((cmd >> 11) & 1);
      if (intr != (op.a != 0)) fail("the done interrupt", intr, op.a, op.ns);
      ++irqs;
      continue;
    }
    if (op.kind == 'r') {
      uint32_t got = 0;
      switch (op.a & 3) {
        case 0: got = status(now); break;
        case 1: got = lma; break;
        case 2: got = da; break;
        default: got = 0; break;
      }
      if (got != op.b) {
        char what[64];
        std::snprintf(what, sizeof what, "register %u", op.a);
        fail(what, got, op.b, op.ns);
      }
      ++reads;
      continue;
    }
    ++writes;
    const uint32_t v = static_cast<uint32_t>(op.b);
    switch (op.a & 3) {
      case 0:
        cmd = v;
        bad_cmd = past_end = nxm = false;
        own = false;
        break;
      case 1: clp = v & 0xfffffffu; break;
      case 2:
        da = v & 0xfffffffu;
        da_own = false;
        break;
      default:
        past_end = nxm = false;
        bad_cmd = !((cmd & 017) == 000 || (cmd & 017) == 011);
        if (!bad_cmd && !dut->walking) {
          dut->start = 1;
          dut->st_cmd = cmd;
          dut->st_clp = clp;
          dut->st_da = da;
          started = true;
          done_ns = now;
          own = da_own = true;
        }
        break;
    }
  }
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
  long pages = 0, blocks_seen = 0, view_bytes = 0;
  for (const auto &p : want_page) {
    const uint32_t h = hash(&mem[static_cast<size_t>(p.first) * kPageWords], kPageWords, 5);
    if (h != p.second) {
      char what[64];
      std::snprintf(what, sizeof what, "main memory's page %o", p.first * kPageWords);
      fail(what, h, p.second, 0);
    }
    ++pages;
  }
  for (const auto &b : want_block) {
    const std::vector<uint32_t> w = pack_block(b.first);
    std::vector<uint64_t> w64(w.begin(), w.end());
    const uint32_t h = hash(w64.data(), w64.size(), 4);
    if (h != b.second) {
      char what[64];
      std::snprintf(what, sizeof what, "the pack's block %u", b.first);
      fail(what, h, b.second, 0);
    }
    ++blocks_seen;
  }
  // The GPT fixture through an 8-bit view: the file's bytes, every word 005.
  for (const auto &v : views) {
    for (uint32_t i = 0; i < 4 * 1024; ++i) {
      const uint64_t word = mem[v.first + i / 4];
      const uint8_t got = static_cast<uint8_t>(word >> (8 * (i % 4)));
      const std::vector<uint32_t> blk = pack_block(v.second + i / 1024);
      const uint8_t want = static_cast<uint8_t>(blk[(i % 1024) / 4] >> (8 * (i % 4)));
      if (got != want) {
        char what[80];
        std::snprintf(what, sizeof what, "byte %u of the GPT's 8-bit view at page %o", i, v.first);
        fail(what, got, want, 0);
      }
      ++view_bytes;
    }
    for (uint32_t w = 0; w < kPageWords; ++w)
      if ((mem[v.first + w] >> 32) != 05) fail("a GPT word's tag", mem[v.first + w] >> 32, 05, 0);
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %ld mismatches\n", bad);
    return 1;
  }
  // What a script must reach to say anything: the whole-space script's pack
  // has every block the disk address names, so nothing is denied there.
  const bool whole = blocks == (1u << 28);
  if (served == 0 || written_back == 0 || (!whole && denied == 0) || walks_waited == 0 ||
      pages == 0 || blocks_seen == 0 || (!whole && (view_bytes == 0 || tagged_005 == 0)) ||
      (mem_nxm == 0 && !whole) || charges == 0) {
    std::fprintf(stderr, "FAIL: the script reached too little: %ld served, %ld written back, "
                 "%ld denied, %ld waits, %ld pages, %ld blocks, %ld view bytes, %ld words "
                 "tagged 005, %ld walks ended in NXM, %ld blocks charged\n",
                 served, written_back, denied, walks_waited, pages, blocks_seen, view_bytes,
                 tagged_005, mem_nxm, charges);
    return 1;
  }
  std::printf("ok: revision 15's walk agrees with muir's BlockDisk::write on a pack of "
              "%x blocks: %ld register reads, %ld writes, %ld interrupt instants, %ld pages and "
              "%ld blocks at the end, %ld bytes of the GPT's 8-bit view;\n"
              "    %ld walks, %ld blocks charged; the pack side served %ld blocks, wrote %ld back, "
              "denied %ld; the walk read %ld words and wrote %ld, %ld of them tagged 005, and %ld "
              "walks ended in NXM\n",
              blocks, reads, writes, irqs, pages, blocks_seen, view_bytes, walks, charges, served,
              written_back, denied, mem_reads, mem_writes, tagged_005, mem_nxm);
  delete dut;
  return 0;
}

}  // namespace

// Every script named, each on its own DUT: the transfers on a pack three
// blocks short of 2^28, and those that reach 2^28 on a pack of all of them.
int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s SCRIPT...\n", argv[0]);
    return 2;
  }
  int worst = 0;
  for (int i = 1; i < argc; ++i) {
    const int rc = RunScript(argv[i]);
    if (rc > worst) worst = rc;
  }
  return worst;
}
