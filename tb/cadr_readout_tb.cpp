// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The readout of the machine's memories, held to every word of every array
// in the processor.
//
// **WHAT THIS CHECK HOLDS AND WHAT IT DOES NOT.**  The thing under test is
// the path from a write of page 0's word 10 to the word that comes back on
// words 11 and 12: the address register in `rtl/plumbing/cadr_console.sv`,
// the three-tick pipeline at the end of `rtl/machine/cadr_microcycle.sv`,
// the second read port of each memory, the selector's mux and the echo.
// The reference is the array itself, read out of the model by name.  **That
// is not the shadow-memory mistake CLAUDE.md records**, and the difference
// is worth stating because the shapes look alike: a shadow keyed by the
// DUT's own address and filled from the DUT's own data moves with the bug,
// so a bridge writing the address instead of the word writes consistent
// nonsense and every read agrees.  Here the storage is the reference and the
// READOUT is the suspect, and nothing the readout does can move a word in an
// array --- it drives no address, no enable and no word that the machine
// reads.  A bug in what the machine WRITES is not this check's to catch and
// `build/machine.pass` is where it would show.
//
// **TWO PHASES, AND THE SECOND EXISTS BECAUSE THE FIRST TESTS ALMOST
// NOTHING ON ITS OWN.**
//
//   A. The machine runs MIT's boot PROM and then is halted from the console,
//      and every word of every memory is read back and compared.  This is
//      "what the machine put there", which is the question somebody with a
//      board in front of them is actually asking.  **But the boot PROM's
//      pass over the control store writes ZERO to all 16,384 words** --- it
//      is clearing the store, not loading microcode --- so against a readout
//      that returned a constant zero this phase would pass on the largest
//      memory in the machine.  That is the control-store trap this
//      repository has met twice already, and the check PRINTS how many
//      distinct words each memory held so that nobody has to take the
//      coverage on trust.
//
//   B. Every array is poisoned from outside, injectively in the memory and
//      the address, and read back again.  The poison is what makes a wrong
//      address, a wrong memory and a word stale by one visible at all: it
//      differs between any two adjacent words of any memory and between any
//      two memories at one address, and the check ASSERTS both of those
//      before it uses them, because a poison that turned out not to be
//      injective would make this phase as blind as the first.
//
// **AND THE MACHINE STANDS STILL WHILE IT IS LOOKED AT --- EXCEPT IN ONE WAY
// THIS CHECK FOUND BY BEING WRONG ABOUT IT.**  The console halts the machine
// before either phase reads anything and the microcycle count is required
// not to move.  Phase B was then written expecting every array still to hold
// the poison it was given, and three words did not: `amem[0]`, `mmem[0]` and
// one level-2 map entry.  **A halted CADR goes on firing its write pulses.**
// MACHRUN gates `-CLK0`, which is what stops microcycles retiring; the
// pulses are `-WP` off the phase generator, which nothing stops, and
// `destd`, `wadr` and `l` stand frozen --- so the last instruction's
// destination is re-written once a generator cycle, for ever, with the same
// word.  Harmless, because it is the word that instruction was going to
// write; not nothing, because anything reading those arrays off a halted
// board cannot assume they are inert.  The count is bounded at six, one per pulse,
// and the check names them on its own output.
//
// **THE ECHO IS CHECKED ON EVERY SINGLE WORD.**  `ro_echo` is the address
// the word in `ro_data` was read at, and a reader that does not compare it
// with what it asked cannot tell a word still in flight from the one it
// wanted.  Every read here compares it, and the three words come out of one
// burst so that the echo and the two halves name one instant of the
// pipeline.

#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <utility>
#include <vector>

#include "Vcadr_console_harness.h"
#include "Vcadr_console_harness___024root.h"
#include "verilated.h"

namespace {

// The console's window, `console_face.h`'s names.
const uint32_t kBase = 0x80000000u;
uint32_t Con(unsigned i) { return kBase + 4u * i; }
uint32_t Spy(unsigned e) { return kBase + 0x40u + 4u * e; }

// The readout's own three words and the two values that mean "nothing has
// been asked" and "this fabric maps no such memory".  They are
// `cadr_microcycle.sv`'s and `cadr_console.sv`'s; repeated here, as the RTL
// repeats them, because a window whose two ends disagree about what nothing
// looks like is the failure the values exist to prevent.
const unsigned kRoAddr = 10, kRoLo = 11, kRoHi = 12;
const uint32_t kRoNone = 0x3FFFFu;
const uint64_t kRoNoMemory = 0xA5A55A5AA5A5ull;

// The selectors, and what each one is.  `depth` and `bits` are the array's
// own, from the declarations in `cadr_microcycle.sv`.
struct Mem {
  const char *name;
  unsigned sel;
  unsigned depth;
  unsigned bits;
};
const Mem kMems[] = {
    {"the control store", 0, 16384, 48}, {"the boot PROM", 1, 1024, 48},
    {"the A memory", 2, 1024, 32},       {"the M memory", 3, 32, 32},
    {"the pushdown buffer", 4, 1024, 32},{"the micro-stack", 5, 32, 21},
    {"the dispatch memory", 6, 2048, 17},{"the level-1 map", 7, 2048, 5},
    {"the level-2 map", 8, 1024, 24},    {"the OPC shift register", 9, 8, 14},
};
const unsigned kMemCount = sizeof(kMems) / sizeof(kMems[0]);
const unsigned kSelRegs = 10;

uint64_t Mask(unsigned bits) {
  return bits >= 64 ? ~0ull : ((1ull << bits) - 1ull);
}

// The poison, injective in the memory and in the address as far as the
// memory's own width allows, and the check asserts that much before using
// it.  Both multipliers are odd, so the low `n` bits of either term are a
// bijection on the low `n` bits of its argument --- which is what makes a
// word stale by one visible in a five-bit map entry as well as in a
// forty-eight-bit control store word.
uint64_t Poison(unsigned sel, unsigned addr, unsigned bits) {
  const uint64_t h = (uint64_t)(sel + 1) * 0x9E3779B97F4A7C15ull +
                     (uint64_t)(addr + 1) * 0xC2B2AE3D27D4EB4Full;
  return h & Mask(bits);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vcadr_console_harness *dut = new Vcadr_console_harness;
  auto *root = dut->rootp;

  long bad = 0;
  long fails_printed = 0;
  auto Fail = [&](const char *what, uint64_t got, uint64_t want) {
    if (fails_printed < 20) {
      std::fprintf(stderr, "%s is 0x%" PRIx64 ", the reference says 0x%" PRIx64 "\n",
                   what, got, want);
      ++fails_printed;
    }
    ++bad;
  };

  // ---- the arrays, by name --------------------------------------------
  //
  // `--public-flat-rw` is what makes these reachable, and they are the
  // reference rather than the thing under test: see the header.
#define P(x) root->cadr_console_harness__DOT__processor__DOT__##x
  auto Get = [&](unsigned sel, unsigned a) -> uint64_t {
    switch (sel) {
      case 0: return P(imem)[a];
      case 1: return P(prom_mem)[a];
      case 2: return P(amem)[a];
      case 3: return P(mmem)[a];
      case 4: return P(pdl)[a];
      case 5: return P(spcm)[a];
      case 6: return P(dmem)[a];
      case 7: return P(l1_map)[a];
      case 8: return P(l2_map)[a];
      case 9: return P(opcs)[a];
      default: return 0;
    }
  };
  auto Put = [&](unsigned sel, unsigned a, uint64_t v) {
    switch (sel) {
      case 0: P(imem)[a] = v; break;
      case 1: P(prom_mem)[a] = v; break;
      case 2: P(amem)[a] = (uint32_t)v; break;
      case 3: P(mmem)[a] = (uint32_t)v; break;
      case 4: P(pdl)[a] = (uint32_t)v; break;
      case 5: P(spcm)[a] = (uint32_t)v; break;
      case 6: P(dmem)[a] = (uint32_t)v; break;
      case 7: P(l1_map)[a] = (uint8_t)v; break;
      case 8: P(l2_map)[a] = (uint32_t)v; break;
      case 9: P(opcs)[a] = (uint16_t)v; break;
      default: break;
    }
  };

  // The register table, entry by entry: what `cadr_microcycle.sv`'s
  // `RG_*` name and where the same value can be read independently.  The
  // ports come off the harness, the rest out of the model by name --- and
  // the packed flag word is assembled here in the same order the RTL packs
  // it, so a bit moved in one and not the other is a mismatch rather than a
  // silent agreement.
  struct Reg { const char *name; unsigned idx; };
  const Reg kRegs[] = {
      {"PC", 0},    {"LPC", 1},    {"IR", 2},     {"IWR", 3},
      {"L", 4},     {"Q", 5},      {"VMA", 6},    {"MD", 7},
      {"ST", 8},    {"LC", 9},     {"WADR", 10},  {"PDLPTR", 11},
      {"PDLIDX", 12},{"SPCPTR", 13},{"RETA", 14}, {"DC", 15},
      {"LVMO", 16}, {"MDHELD", 17},{"PHYS", 18},  {"SPEED", 19},
      {"FLAGS", 20},
  };
  const unsigned kRegCount = sizeof(kRegs) / sizeof(kRegs[0]);
  auto RegRef = [&](unsigned i) -> uint64_t {
    switch (i) {
      case 0: return dut->pc;
      case 1: return dut->lpc;
      case 2: return dut->ir;
      case 3: return P(iwr);
      case 4: return P(l);
      case 5: return dut->q;
      case 6: return dut->vma;
      case 7: return dut->md;
      case 8: return dut->st;
      case 9: return dut->lc;
      case 10: return P(wadr);
      case 11: return P(pdl_ptr);
      case 12: return P(pdl_idx);
      case 13: return P(spcptr);
      case 14: return P(reta);
      case 15: return dut->dc;
      case 16: return P(lvmo);
      case 17: return P(md_held);
      case 18: return P(phys_r);
      case 19: return (uint64_t)P(speed) | ((uint64_t)P(speed_a) << 2) |
                      ((uint64_t)dut->mode_speed_o << 4);
      case 20: {
        // The flags, in the order the RTL packs them: bit 0 is `destd`.
        const uint64_t b[33] = {
            (uint64_t)(P(destd) != 0),        (uint64_t)(P(destmd) != 0),
            (uint64_t)(P(pwidx) != 0),        (uint64_t)(P(pdlwrited) != 0),
            (uint64_t)(P(inop) != 0),         (uint64_t)(dut->iwrited != 0),
            (uint64_t)(P(newlc) != 0),        (uint64_t)(P(sintr_d) != 0),
            (uint64_t)(P(next_instrd) != 0),  (uint64_t)(P(lc_byte_mode) != 0),
            (uint64_t)(P(int_enable) != 0),   (uint64_t)(P(sequence_break) != 0),
            (uint64_t)(P(prog_unibus_reset) != 0), (uint64_t)(P(trap) != 0),
            (uint64_t)(P(promdisabled) != 0), (uint64_t)(P(srun) != 0),
            (uint64_t)(P(statstop) != 0),     (uint64_t)(P(halted) != 0),
            (uint64_t)(P(memstart) != 0),     (uint64_t)(P(mbusy) != 0),
            // **rdcyc BEFORE wrcyc, WHICH THIS HAD THE WRONG WAY ROUND AND
            // THE CHECK COULD NOT SEE.**  The two are one flip-flop holding
            // the last bus cycle's direction, and at the instant this table
            // is read --- a halted machine that has not reached its first
            // memory cycle --- both are clear, so crossing them agreed with
            // the RTL bit for bit.  The order below is `ro_flags`'s, and the
            // fact that this check cannot tell these two bits apart is on
            // its own output beside the word.
            (uint64_t)(P(rdcyc) != 0),        (uint64_t)(dut->wrcyc != 0),
            (uint64_t)(P(mbusy_sync) != 0),   (uint64_t)(P(rd_in_progress) != 0),
            (uint64_t)(P(wmapd) != 0),        (uint64_t)(P(spushd) != 0),
            (uint64_t)(P(destspcd) != 0),     (uint64_t)(P(imodd) != 0),
            (uint64_t)(dut->vmaok != 0),      (uint64_t)(P(md_pending) != 0),
            // The three that are input ports of the processor and registers
            // of `cadr_spy_registers`: the console's own, which MIT's
            // sixteen cannot read back.
            (uint64_t)(dut->run_o != 0),      (uint64_t)(dut->errstop_o != 0),
            (uint64_t)(dut->stathenb_o != 0)};
        uint64_t w = 0;
        for (unsigned k = 0; k < 33; ++k) w |= b[k] << k;
        return w;
      }
      default: return 0;
    }
  };
#undef P

  // ---- the AXI master ---------------------------------------------------
  //
  // `tb/cadr_console_tb.cpp`'s, in the same order and with the same
  // assertions: a response offered before the data is in is a slave
  // answering a transaction nobody made, and an unanswered transaction on a
  // GP port hangs both Arm cores, so a bound on every one of them is what
  // the check is for.
  struct Axi {
    enum { IDLE, AW, W, B, AR, R } st = IDLE;
    unsigned len = 0, beat = 0, id = 0;
    std::vector<uint32_t> got;
    long began = 0;
    bool aw_hs = false, w_hs = false, b_hs = false, ar_hs = false, r_hs = false;
    int hold = 0;
  } axi;
  uint32_t jitter = 0x13579BDu;
  auto rnd = [&]() { jitter = jitter * 1664525u + 1013904223u; return jitter >> 9; };

  long tick = 0;
  long edges = 0;              // microcycles the processor has retired
  const long kBound = 8192;    // ticks a transaction may take: LOST_T and more

  // **THE ECHO AND THE WORD ARRIVE TOGETHER**, watched every tick, which is
  // the only place that property can be seen.  `watch_for` is an address a
  // program has just asked for; the first tick the echo names it, the word
  // standing beside it is taken.  An AXI read cannot come back inside the
  // three ticks the pipeline takes, so over the window a right design and one
  // whose word is a tick staler than its echo look identical --- which is
  // what makes this the phase that bites.
  uint32_t watch_for = 0xFFFFFFFFu;
  bool watch_seen = false;
  uint64_t watch_data = 0;
  long watch_at = -1;

  auto Tick = [&]() {
    // The bus interface, inactive.  **This check needs no reference trace**:
    // its property is about the readout and not about what the machine
    // computes, and the machine computing MIT's boot PROM out of its own
    // control store is stimulus enough to fill the memories.  `-MEMGRANT`
    // high is "do not hang", so the machine runs on past its first memory
    // cycle rather than stalling for ever on a bus nothing answers.
    dut->n_memack = 1;
    dut->n_memgrant = 1;
    dut->n_loadmd = 1;
    dut->rdata = 0;
    dut->sintr = 0;
    dut->cpu_msyn = 0;
    dut->cpu_write = 0;
    dut->cpu_addr = 0;
    dut->cpu_wdata = 0;
    dut->gnt_inhibit = 0;

    dut->clk = 1;
    dut->eval();
    if (dut->clock_edge) ++edges;

    if (axi.hold > 0) --axi.hold;
    switch (axi.st) {
      case Axi::AW: if (axi.aw_hs) { axi.st = Axi::W; axi.beat = 0; axi.hold = rnd() % 3; } break;
      case Axi::W:
        if (axi.w_hs) {
          if (axi.beat == axi.len) { axi.st = Axi::B; axi.hold = rnd() % 3; }
          else { ++axi.beat; axi.hold = rnd() % 3; }
        }
        break;
      case Axi::B: if (axi.b_hs) axi.st = Axi::IDLE; break;
      case Axi::AR: if (axi.ar_hs) { axi.st = Axi::R; axi.beat = 0; axi.hold = rnd() % 3; } break;
      case Axi::R:
        if (axi.r_hs) {
          if (axi.beat == axi.len) axi.st = Axi::IDLE;
          else { ++axi.beat; axi.hold = rnd() % 3; }
        }
        break;
      default: break;
    }
    if (axi.st != Axi::IDLE && tick - axi.began > kBound) {
      Fail("an AXI transaction did not complete inside the engine's own bound",
           (uint64_t)axi.st, (uint64_t)Axi::IDLE);
      axi.st = Axi::IDLE;
    }

    dut->s_awvalid = (axi.st == Axi::AW) && axi.hold == 0;
    dut->s_wvalid  = (axi.st == Axi::W) && axi.hold == 0;
    dut->s_wlast   = (axi.st == Axi::W) && (axi.beat == axi.len);
    dut->s_bready  = (axi.st == Axi::B) && axi.hold == 0;
    dut->s_arvalid = (axi.st == Axi::AR) && axi.hold == 0;
    dut->s_rready  = (axi.st == Axi::R) && axi.hold == 0;

    dut->clk = 0;
    dut->eval();

    axi.aw_hs = dut->s_awvalid && dut->s_awready;
    axi.w_hs  = dut->s_wvalid && dut->s_wready;
    axi.b_hs  = dut->s_bready && dut->s_bvalid;
    axi.ar_hs = dut->s_arvalid && dut->s_arready;
    axi.r_hs  = dut->s_rready && dut->s_rvalid;
    if (dut->s_bvalid && axi.st != Axi::B) Fail("BVALID with no write awaiting one", 1, 0);
    if (dut->s_rvalid && axi.st != Axi::R) Fail("RVALID with no read awaiting one", 1, 0);
    if (axi.b_hs) {
      if (dut->s_bresp != 0) Fail("BRESP", dut->s_bresp, 0);
      if (dut->s_bid != axi.id) Fail("BID", dut->s_bid, axi.id);
    }
    if (axi.r_hs) {
      if (dut->s_rresp != 0) Fail("RRESP", dut->s_rresp, 0);
      if (dut->s_rid != axi.id) Fail("RID", dut->s_rid, axi.id);
      const bool last = (axi.beat == axi.len);
      if ((dut->s_rlast != 0) != last)
        Fail(last ? "RLAST missing on the last beat"
                  : "RLAST on a beat that is not the last",
             dut->s_rlast, last);
      axi.got.push_back(dut->s_rdata);
    }
    if (!watch_seen && dut->ro_echo_o == watch_for) {
      watch_seen = true;
      watch_data = dut->ro_data_o;
      watch_at = tick;
    }
    ++tick;
  };

  auto DoRead = [&](uint32_t addr, unsigned len) {
    axi.st = Axi::AR; axi.len = len; axi.beat = 0;
    axi.id = rnd() & 0xFFF; axi.got.clear(); axi.began = tick;
    axi.hold = rnd() % 3;
    dut->s_araddr = addr; dut->s_arlen = len; dut->s_arid = axi.id;
    while (axi.st != Axi::IDLE && bad < 20) Tick();
    while (axi.got.size() < (size_t)len + 1) axi.got.push_back(0);
    return axi.got;
  };
  auto ReadWord = [&](uint32_t addr) { return DoRead(addr, 0).at(0); };
  auto DoWrite = [&](uint32_t addr, uint32_t data) {
    axi.st = Axi::AW; axi.len = 0; axi.beat = 0;
    axi.id = rnd() & 0xFFF; axi.began = tick; axi.hold = rnd() % 3;
    dut->s_awaddr = addr; dut->s_awlen = 0; dut->s_awid = axi.id;
    dut->s_wdata = data; dut->s_wstrb = 0xF;
    while (axi.st != Axi::IDLE && bad < 20) Tick();
  };
  auto SpyWrite = [&](unsigned e, uint16_t v) { DoWrite(Spy(e), v); };

  // **ONE WORD OUT OF THE WINDOW IS ONE WRITE AND ONE THREE-BEAT BURST**, and
  // the burst is what makes the echo worth having: words 10, 11 and 12 come
  // out of the latch a read of word 10 armed, so the address the word was
  // read at and the two halves of the word name one instant of the pipeline.
  long ro_reads = 0, echo_bad = 0;
  auto ReadRo = [&](unsigned sel, unsigned a, uint64_t *word) {
    const uint32_t asked = ((uint32_t)sel << 14) | (a & 0x3FFFu);
    DoWrite(Con(kRoAddr), asked);
    const std::vector<uint32_t> got = DoRead(Con(kRoAddr), 2);
    ++ro_reads;
    if (got[0] != asked) {
      ++echo_bad;
      if (echo_bad <= 5)
        std::fprintf(stderr,
                     "the echo for %u:%u is 0x%05x, the address asked was 0x%05x\n",
                     sel, a, got[0], asked);
      ++bad;
    }
    *word = (uint64_t)got[1] | ((uint64_t)(got[2] & 0xFFFFu) << 32);
    return got[0];
  };

  // ---- reset -----------------------------------------------------------
  dut->rst = 1;
  dut->clk = 0;
  for (int i = 0; i < 8; ++i) Tick();
  dut->rst = 0;

  // The window before anything is asked of it: the reserved selector and the
  // word a selector this fabric does not map answers with.  **Neither is
  // zero and neither is all ones**, so "nothing has been asked" is not a
  // value a memory could have held.
  {
    const uint32_t e = ReadWord(Con(kRoAddr));
    if (e != kRoNone) Fail("the echo out of reset", e, kRoNone);
    const uint64_t w = (uint64_t)ReadWord(Con(kRoLo)) |
                       ((uint64_t)(ReadWord(Con(kRoHi)) & 0xFFFFu) << 32);
    if (w != kRoNoMemory) Fail("the word out of reset", w, kRoNoMemory);
  }

  // ---- the poison, checked before it is used ---------------------------
  //
  // A poison that is not injective makes phase B as blind as phase A, and
  // "injective" has to mean something different for a five-bit map entry
  // with 2,048 of them than for the control store.  What is asserted is what
  // the mutations need: adjacent words of one memory differ, and any two
  // memories differ at one address.
  for (unsigned i = 0; i < kMemCount; ++i) {
    const Mem &m = kMems[i];
    for (unsigned a = 0; a + 1 < m.depth; ++a)
      if (Poison(m.sel, a, m.bits) == Poison(m.sel, a + 1, m.bits))
        Fail("two adjacent words of one memory share a poison", a, a + 1);
    for (unsigned j = i + 1; j < kMemCount; ++j) {
      const Mem &n = kMems[j];
      const unsigned common = m.depth < n.depth ? m.depth : n.depth;
      const unsigned bits = m.bits < n.bits ? m.bits : n.bits;
      for (unsigned a = 0; a < common; ++a)
        if ((Poison(m.sel, a, m.bits) & Mask(bits)) ==
            (Poison(n.sel, a, n.bits) & Mask(bits)))
          Fail("two memories share a poison at one address", m.sel, n.sel);
    }
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: the poison is not injective; nothing below tests anything\n");
    return 1;
  }

  // ---- phase A: what the machine put there ------------------------------
  //
  // The console starts the machine --- `run` comes out of the register block
  // and is clear at reset --- and stops it again.  The memories then hold
  // what MIT's boot PROM wrote into them.
  // **THREE HALTS AND NOT ONE, BECAUSE OF WHAT THE FLAG WORD LOOKS LIKE AT
  // ANY ONE OF THEM.**  The register table's flag word is 33 bits and four
  // of them are set at the first halt this check made; two bits that agree
  // at the one instant a table is read are two bits a crossing between them
  // would leave agreeing, which is how `rdcyc` and `wrcyc` were the wrong way
  // round here and nothing said so.  So the table is compared at three
  // microcycles far apart and the check reports the UNION of the bits it ever
  // saw set --- which is the coverage figure, and it is on the output because
  // a reader should not have to take it on trust.
  const long kHaltAt[] = {997, 60007, 300001};
  const unsigned kHalts = sizeof(kHaltAt) / sizeof(kHaltAt[0]);
  long halted_at = 0;
  long phase_a_regs = 0;
  uint64_t flags_seen = 0, flags_ever_clear = ~0ull;
  for (unsigned h = 0; h < kHalts && bad < 20; ++h) {
    SpyWrite(3, 1);
    while (edges < kHaltAt[h] && bad < 20) Tick();
    SpyWrite(3, 0);
    for (int i = 0; i < 200; ++i) Tick();
    halted_at = edges;
    for (int i = 0; i < 2000; ++i) Tick();
    if (edges != halted_at)
      Fail("the machine moved after the console halted it", edges, halted_at);
    // The register table, against the same registers read independently.
    for (unsigned i = 0; i < kRegCount && bad < 20; ++i) {
      uint64_t w = 0;
      ReadRo(kSelRegs, kRegs[i].idx, &w);
      const uint64_t want = RegRef(i);
      if (w != want) {
        std::fprintf(stderr, "at microcycle %ld the register table's %s reads "
                             "0x%012" PRIx64 ", the machine holds 0x%012" PRIx64 "\n",
                     halted_at, kRegs[i].name, w, want);
        ++fails_printed;
        ++bad;
      }
      if (kRegs[i].idx == 20) {
        flags_seen |= w;
        flags_ever_clear &= ~w;
      }
      ++phase_a_regs;
    }
  }

  long phase_a_words = 0;
  std::vector<long> distinct(kMemCount, 0);
  for (unsigned i = 0; i < kMemCount; ++i) {
    const Mem &m = kMems[i];
    std::vector<uint64_t> seen;
    for (unsigned a = 0; a < m.depth; ++a) {
      uint64_t w = 0;
      ReadRo(m.sel, a, &w);
      const uint64_t want = Get(m.sel, a) & Mask(m.bits);
      if (w != want) {
        if (fails_printed < 20)
          std::fprintf(stderr, "%s word %u reads 0x%012" PRIx64
                               ", the array holds 0x%012" PRIx64 "\n",
                       m.name, a, w, want);
        ++fails_printed;
        ++bad;
      }
      ++phase_a_words;
      bool novel = true;
      for (uint64_t s : seen) if (s == want) { novel = false; break; }
      if (novel && seen.size() < 4096) seen.push_back(want);
    }
    distinct[i] = (long)seen.size();
    if (bad >= 20) break;
  }

  // An entry the table does not carry, and a selector this fabric does not
  // map: both must answer with the word that means nothing, and the echo
  // must still name what was asked.
  {
    uint64_t w = 0;
    ReadRo(kSelRegs, 31, &w);
    if (w != kRoNoMemory) Fail("an unused register-table entry", w, kRoNoMemory);
    for (unsigned sel = 11; sel < 16; ++sel) {
      ReadRo(sel, 7, &w);
      if (w != kRoNoMemory) Fail("a selector this fabric does not map", w, kRoNoMemory);
    }
  }

  // ---- phase B: poison from outside ------------------------------------
  for (unsigned i = 0; i < kMemCount; ++i) {
    const Mem &m = kMems[i];
    for (unsigned a = 0; a < m.depth; ++a) Put(m.sel, a, Poison(m.sel, a, m.bits));
  }
  for (int i = 0; i < 8; ++i) Tick();

  long phase_b_words = 0, standing = 0;
  std::vector<std::pair<unsigned, unsigned> > stood;
  for (unsigned i = 0; i < kMemCount && bad < 20; ++i) {
    const Mem &m = kMems[i];
    for (unsigned a = 0; a < m.depth; ++a) {
      uint64_t w = 0;
      ReadRo(m.sel, a, &w);
      // **THE REFERENCE IS THE ARRAY AS IT STANDS, NOT THE POISON THAT WAS
      // PUT IN IT**, and the difference is a finding rather than a
      // convenience: see the standing-write count below.
      const uint64_t want = Get(m.sel, a) & Mask(m.bits);
      if (w != want) {
        if (fails_printed < 20)
          std::fprintf(stderr, "%s word %u reads 0x%012" PRIx64
                               ", the array holds 0x%012" PRIx64 "\n",
                       m.name, a, w, want);
        ++fails_printed;
        ++bad;
      }
      if (want != Poison(m.sel, a, m.bits)) {
        ++standing;
        if (stood.size() < 16) stood.push_back(std::make_pair(m.sel, a));
      }
      ++phase_b_words;
      if (bad >= 20) break;
    }
  }

  // **A HALTED CADR GOES ON FIRING ITS WRITE PULSES, AND THIS IS WHERE THAT
  // WAS FOUND.**  The check was written expecting every word to still hold
  // the poison it was given and three did not: `amem[0]`, `mmem[0]` and one
  // level-2 map entry.  The reason is in `cadr_microcycle.sv` and is not a
  // defect: the write pulses are `-AWPA`, `-MWPA`, `-PWPA`, `-SWPA` and the
  // two map pulses, all of them `-WP` gated by a REGISTERED enable, and
  // `-WP` comes off the phase generator, which MACHRUN does not stop ---
  // MACHRUN gates `-CLK0`, which is what stops microcycles from RETIRING.
  // So a machine the console has halted stands with `destd`, `wadr` and `l`
  // frozen and re-writes the last instruction's destination once a
  // generator cycle, for ever, with the same word.
  //
  // **It is harmless and it is not nothing.**  Harmless, because the word
  // written is the word that instruction was going to write and writing it
  // again changes nothing; not nothing, because anything reading those arrays
  // off a halted board cannot assume they are inert, and because anything
  // that WROTE through this window would be fighting those pulses.  At most
  // six words can be standing --- one per pulse --- and the check holds that
  // bound, names them, and requires the readout to agree with the array at
  // every one of them.
  if (standing > 6)
    Fail("words of a halted machine's memories standing under a write pulse",
         standing, 6);
  if (edges != halted_at) Fail("the machine ran while it was being read", edges, halted_at);

  // ---- phase C: the echo and the word arrive together --------------------
  //
  // **THE ECHO IS THE WHOLE OF WHAT MAKES THIS A READOUT AND NOT A GUESS**,
  // and an echo that runs a tick ahead of the word it is supposed to
  // describe would be worse than none: a program comparing it with what it
  // asked would be told the word was fresh when it was the previous
  // address's.  Nothing over AXI can see that --- a read cannot come back
  // inside the three ticks the pipeline takes --- so this phase watches the
  // three wires every tick and takes the word standing at the FIRST tick the
  // echo names the address asked for.
  //
  // The addresses alternate between memories and are never adjacent, so the
  // word a stale pipeline would hand over is nothing like the right one.
  const unsigned kFreshSel[] = {0, 4, 8, 2, 6, 0, 9, 5, 1, 3, 7, 0};
  const unsigned kFreshAdr[] = {1234, 7, 900, 513, 2047, 16383, 3, 31, 77, 5, 1000, 0};
  long fresh = 0, fresh_late = 0;
  for (unsigned i = 0; i < sizeof(kFreshSel) / sizeof(kFreshSel[0]) && bad < 20; ++i) {
    const unsigned sel = kFreshSel[i], a = kFreshAdr[i];
    const uint32_t asked = ((uint32_t)sel << 14) | (a & 0x3FFFu);
    watch_for = asked;
    watch_seen = false;
    watch_at = -1;
    DoWrite(Con(kRoAddr), asked);
    long spin = 0;
    while (!watch_seen && spin < 64 && bad < 20) { Tick(); ++spin; }
    if (!watch_seen) {
      Fail("the echo never named an address that was asked for", asked, asked);
      continue;
    }
    const uint64_t want = Get(sel, a) & Mask(kMems[sel].bits);
    if (watch_data != want) {
      std::fprintf(stderr,
                   "at the tick the echo first named %u:%u the word beside it "
                   "is 0x%012" PRIx64 ", the array holds 0x%012" PRIx64 "\n",
                   sel, a, watch_data, want);
      ++fails_printed;
      ++bad;
    }
    ++fresh;
    if (spin > 0) ++fresh_late;
  }
  watch_for = 0xFFFFFFFFu;

  // ---- phase D: the register table, every entry distinct -----------------
  //
  // **THE TABLE'S TWENTY-ONE ENTRIES WERE COMPARED AGAINST THE MACHINE'S OWN
  // REGISTERS THREE TIMES, AND AT NONE OF THOSE THREE WERE THEY ALL
  // DIFFERENT.**  `Q`, `VMA` and `MD` all read zero at a boot PROM halt, so a
  // mux that crossed any two of them agreed with the reference at every one.
  // That is the control-store trap in a register file: a memory whose only
  // exercise writes one constant tests nothing, and a table whose entries are
  // all zero is that memory.
  //
  // So the wide registers are written from outside, injectively, and the
  // table is read back.  It is phase B's argument applied one selector along
  // and it needs no new mechanism --- the machine is halted, these registers
  // are written only at a microcycle boundary, and no boundary comes.
  //
  // **THE FLAG WORD AND THE THREE CONSOLE BITS ARE NOT POISONED AND THAT IS
  // DELIBERATE.**  `srun` poisoned to one is a machine that starts running
  // again; `run`, `errstop` and `stathenb` are input ports whose far end is a
  // register of `cadr_spy_registers`, so a write here is overwritten at the
  // next evaluation.  Their coverage is what the three halts gave and the
  // line above says what that was.
  struct WideReg { const char *name; unsigned idx; unsigned bits; };
  const WideReg kWide[] = {
      {"PC", 0, 14},    {"LPC", 1, 14},    {"IR", 2, 48},   {"IWR", 3, 48},
      {"L", 4, 32},     {"Q", 5, 32},      {"VMA", 6, 32},  {"MD", 7, 32},
      {"ST", 8, 32},    {"LC", 9, 26},     {"WADR", 10, 10},
      {"PDLPTR", 11, 10}, {"PDLIDX", 12, 10}, {"SPCPTR", 13, 5},
      {"RETA", 14, 14}, {"DC", 15, 10},    {"LVMO", 16, 24},
      {"MDHELD", 17, 32}, {"PHYS", 18, 22},
  };
  const unsigned kWideCount = sizeof(kWide) / sizeof(kWide[0]);
#define Q(x) root->cadr_console_harness__DOT__processor__DOT__##x
  for (unsigned i = 0; i < kWideCount; ++i) {
    const uint64_t v = Poison(15, kWide[i].idx, kWide[i].bits);
    switch (kWide[i].idx) {
      case 0: Q(pc) = (uint16_t)v; break;
      case 1: Q(lpc) = (uint16_t)v; break;
      case 2: Q(ir) = v; break;
      case 3: Q(iwr) = v; break;
      case 4: Q(l) = (uint32_t)v; break;
      case 5: Q(q) = (uint32_t)v; break;
      case 6: Q(vma) = (uint32_t)v; break;
      case 7: Q(md) = (uint32_t)v; break;
      case 8: Q(st) = (uint32_t)v; break;
      case 9: Q(lc) = (uint32_t)v; break;
      case 10: Q(wadr) = (uint16_t)v; break;
      case 11: Q(pdl_ptr) = (uint16_t)v; break;
      case 12: Q(pdl_idx) = (uint16_t)v; break;
      case 13: Q(spcptr) = (uint8_t)v; break;
      case 14: Q(reta) = (uint16_t)v; break;
      case 15: Q(dc) = (uint16_t)v; break;
      case 16: Q(lvmo) = (uint32_t)v; break;
      case 17: Q(md_held) = (uint32_t)v; break;
      case 18: Q(phys_r) = (uint32_t)v; break;
      default: break;
    }
  }
#undef Q
  for (int i = 0; i < 8; ++i) Tick();
  long phase_d = 0;
  for (unsigned i = 0; i < kWideCount && bad < 20; ++i) {
    uint64_t w = 0;
    ReadRo(kSelRegs, kWide[i].idx, &w);
    const uint64_t want = RegRef(kWide[i].idx);
    if (w != want) {
      std::fprintf(stderr, "with every entry distinct, the register table's %s "
                           "reads 0x%012" PRIx64 ", the machine holds "
                           "0x%012" PRIx64 "\n", kWide[i].name, w, want);
      ++fails_printed;
      ++bad;
    }
    // The poison is injective in the entry, so any two entries differ: this
    // is what says a crossed mux has nowhere to hide.
    for (unsigned j = 0; j < kWideCount; ++j)
      if (j != i && (RegRef(kWide[j].idx) == want))
        Fail("two entries of the register table hold the same word", i, j);
    ++phase_d;
  }

  // ---- what it covered --------------------------------------------------
  std::printf("readout: %ld words out of the window, %ld of them poisoned; "
              "%ld register-table entries; %ld echoes, all compared\n",
              phase_a_words + phase_b_words, phase_b_words, phase_a_regs,
              ro_reads);
  std::printf("  the machine ran %ld microcycles of MIT's boot PROM and was "
              "halted from the console; it retired none while it was read\n",
              halted_at);
  std::printf("  the flag word was compared at %u halts and %d of its 33 bits "
              "were seen set across them (0x%012" PRIx64 "); the other %d stood "
              "clear throughout, and a crossing between any two of THOSE is "
              "invisible to this check\n",
              kHalts, __builtin_popcountll(flags_seen), flags_seen,
              33 - __builtin_popcountll(flags_seen));
  std::printf("  %ld addresses watched tick by tick: the word beside the echo "
              "was the echo's own every time, %ld of them still in flight when "
              "the write that asked for them completed\n", fresh, fresh_late);
  std::printf("  %ld of the table's wide entries compared again with every one "
              "of them holding a different word, so a crossed mux has nowhere "
              "to hide among them\n", phase_d);
  std::printf("  %ld words stood under a write pulse while it was halted, of "
              "the six the pulses can reach:\n", standing);
  for (size_t i = 0; i < stood.size(); ++i)
    std::printf("    %-24s word %u\n", kMems[stood[i].first].name, stood[i].second);
  std::printf("  distinct words each memory held after that run, which is the "
              "coverage phase A has and phase B does not depend on:\n");
  for (unsigned i = 0; i < kMemCount; ++i)
    std::printf("    %-24s %5u words, %5ld distinct%s\n", kMems[i].name,
                kMems[i].depth, distinct[i],
                distinct[i] <= 1 ? "   <-- ONE CONSTANT: phase A tests nothing here" : "");

  if (bad) {
    std::fprintf(stderr, "FAIL: %ld mismatches\n", bad);
    return 1;
  }
  std::printf("PASS\n");
  delete dut;
  return 0;
}
