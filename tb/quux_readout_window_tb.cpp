// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX'S STATE THROUGH THE CONSOLE'S READOUT WINDOW, AGAINST THE REGISTERS
// THAT HOLD IT: what a checkpoint of a QUUX board reads, word by word.
//
// **WHAT THIS HOLDS.**  A checkpoint carries muir's `Machine`, and on QUUX
// that is more than the CADR's: the processor's clocks (`Machine::tick`),
// the register page's keyboard and mouse (`QuuxInput`), block-disk
// (`BlockDisk`), the bus errors word 101 reads and MONO TV's black-on-white;
// and the CADR's arrays at QUUX's sizes, a PDL buffer of 16K words, a
// level-1 map of six bits and a level-2 map of 2,048 entries.  Each is
// poisoned HERE, by name, in the register or array that holds it, and read
// back through the window at the address `cadr-checkpoint` reads it at; the
// reference is the storage and the window is the suspect, which is
// `build/readout.pass`'s arrangement and its argument.
//
// **THE CLOCKS MOVE WHILE THEY ARE READ, AND SO DOES BLOCK-DISK'S TIME.**  A
// timer's counts, the microsecond clock and the ticks since block-disk's
// blocks ran out change every tick, halted machine or not.  So each is
// compared with what the registers held at the ticks a word could have been
// taken at --- a word matching none of the last few is a failure, and so is
// one whose microsecond bits belong to another tick than its counts.  And
// the one arithmetic a reader does on the clocks, the tick a timer's flag
// next rises, `pre + (us - 1) * 100` ticks after its word was taken, is held
// against the register itself: the timer is set going, its word read, and
// the flag must rise at exactly the tick the word says.
//
// **AND ON THE CADR NONE OF IT IS THERE.**  Built with `QUUX_TB` 0 the same
// addresses must read `RO_NO_MEMORY`, which is how `cadr-checkpoint` tells
// the two bitstreams apart and refuses the wrong machine's checkpoint.

#include <cinttypes>
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <deque>

#include "Vcadr_machine.h"
#include "Vcadr_machine___024root.h"
#include "verilated.h"

#ifndef QUUX_TB
#error "QUUX_TB is 1 for a QUUX build of cadr_machine and 0 for a CADR one"
#endif
#if QUUX_TB
#ifndef SYNC_K_TB
#error "SYNC_K_TB and SYNC_L_TB are the K and L the machine was built at"
#endif
#endif

namespace {

constexpr uint64_t kNoMemory = 0xA5A5'5A5A'A5A5ull;
constexpr unsigned kSelPdl = 4, kSelMap1 = 7, kSelMap2 = 8, kSelProm = 1;
constexpr unsigned kSelRegs = 10, kSelAudit = 11, kSelPage = 12;
constexpr unsigned kRgQuuxId = 21, kRgTime = 22, kRgTick = 23, kRgInterval = 24,
                   kRgPeriod = 25;

int fails = 0;
long checks = 0;

void Check(bool ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void Check(bool ok, const char *fmt, ...) {
  ++checks;
  if (ok) return;
  ++fails;
  va_list ap;
  va_start(ap, fmt);
  std::fprintf(stderr, "FAIL: ");
  std::vfprintf(stderr, fmt, ap);
  std::fprintf(stderr, "\n");
  va_end(ap);
}

// `checkpoint_test.c`'s poison, injective in the memory and the address.
uint64_t Poison(unsigned sel, unsigned addr, unsigned bits) {
  const uint64_t h = static_cast<uint64_t>(sel + 1) * 0x9E3779B97F4A7C15ull +
                     static_cast<uint64_t>(addr + 1) * 0xC2B2AE3D27D4EB4Full;
  return bits >= 64 ? h : (h & ((1ull << bits) - 1ull));
}

Vcadr_machine *dut;
long ticks = 0;

#if QUUX_TB
// What each moving word should read, from the registers, after every tick.
struct Expect {
  uint64_t time, tick, interval, since;
};
std::deque<Expect> history;
Expect Now();
#endif

void Tick() {
  dut->clk = 0;
  dut->eval();
  dut->clk = 1;
  dut->eval();
  ++ticks;
#if QUUX_TB
  history.push_back(Now());
  if (history.size() > 6) history.pop_front();
#endif
}

// One word out of the window, as `cadr-readout` takes it, the echo compared.
uint64_t Window(unsigned sel, unsigned addr) {
  const unsigned asked = ((sel & 0xFu) << 14) | (addr & 0x3FFFu);
  dut->con_ro_addr = asked;
  for (int i = 0; i < 4; ++i) Tick();
  Check(dut->con_ro_echo == asked, "the window echoed 0x%05x for an address of 0x%05x",
        static_cast<unsigned>(dut->con_ro_echo), asked);
  return dut->con_ro_data;
}

#if QUUX_TB
#define CLK(x) dut->rootp->cadr_machine__DOT__processor__DOT__g_quux_tick__DOT__clocks__DOT__##x
#define IN(x) \
  dut->rootp->cadr_machine__DOT__g_quux_feature_page__DOT__feature_page__DOT__input_regs__DOT__##x
#define BD(x) dut->rootp->cadr_machine__DOT__g_quux_disk__DOT__disk__DOT__##x
#define PROC(x) dut->rootp->cadr_machine__DOT__processor__DOT__##x

uint64_t TimerWord(unsigned k) {
  const uint64_t usec = CLK(usec), usec_t = CLK(usec_t);
  return ((usec & 0x7Full) << 41) | ((usec_t & 0x7Full) << 34) |
         (static_cast<uint64_t>((CLK(en) >> k) & 1u) << 33) |
         (static_cast<uint64_t>((CLK(sticky) >> k) & 1u) << 32) |
         (static_cast<uint64_t>((CLK(live) >> k) & 1u) << 31) |
         (static_cast<uint64_t>(CLK(pre)[k] & 0x7Fu) << 24) | (CLK(us)[k] & 0xFFFFFFu);
}

Expect Now() {
  Expect e;
  e.time = (static_cast<uint64_t>(CLK(usec_t) & 0x7Fu) << 32) | CLK(usec);
  e.tick = TimerWord(0);
  e.interval = TimerWord(1);
  const uint32_t since = BD(busy_ticks) - BD(due);
  e.since = since;
  return e;
}

// A moving word: it must be what the registers held at one of the ticks it
// could have been taken at.
void Moving(const char *what, uint64_t got, uint64_t Expect::*field) {
  bool found = false;
  for (const Expect &e : history) found = found || (e.*field == got);
  Check(found, "%s read 0x%012" PRIx64 ", which the registers held at none of the "
        "last %zu ticks (the newest 0x%012" PRIx64 ")", what, got, history.size(),
        history.back().*field);
}
#endif

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vcadr_machine;
  dut->n_boot2 = 1;
  dut->clk = 0;
  dut->rst = 1;
  // **HELD UNBOOTED**, SW0's and `--no-auto-boot`'s way: nothing the boot
  // PROM does may move a register this check has poisoned.
  dut->no_auto_boot = 1;
  dut->con_ro_addr = 0x3FFFF;
  dut->port_read_ack = 0;
  dut->port_write_ack = 0;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  dut->drive_present = 0;
  dut->drive_read_only = 0;
  dut->drive_timed = 0;
  dut->store_we = 0;
  dut->store_slot = 0;
  dut->store_addr = 0;
  dut->store_wdata = 0;
  dut->store_busy = 0;
  dut->store_busy_slot = 0;
  dut->store_deny = 0;
  dut->boards = 32;
  dut->mem_done = 0;
  dut->mem_rdata = 0;
  dut->con_req = 0;
  dut->con_msyn = 0;
  dut->con_write = 0;
  dut->con_addr = 0;
  dut->con_wdata = 0;
  dut->kbd_strobe = 0;
  dut->kbd_code = 0;
  dut->mouse_lines = 0;
  dut->eval();
  for (int i = 0; i < 8; ++i) Tick();
  dut->rst = 0;
  for (int i = 0; i < 300; ++i) Tick();

#if !QUUX_TB
  // ---- THE CADR: nothing of QUUX's answers -------------------------------
  for (unsigned rg = kRgQuuxId; rg <= kRgPeriod; ++rg) {
    const uint64_t w = Window(kSelRegs, rg);
    Check(w == kNoMemory, "the CADR's register table entry %u read 0x%012" PRIx64
          ", not RO_NO_MEMORY", rg, w);
  }
  for (unsigned a : {0u, 1u, 5u, 6u, 7u, 64u, 127u, 16383u}) {
    const uint64_t w = Window(kSelPage, a);
    Check(w == kNoMemory, "the CADR's selector 12 word %u read 0x%012" PRIx64
          ", not RO_NO_MEMORY", a, w);
  }
#else
  // ---- which machine, and its K and L ------------------------------------
  {
    const uint64_t w = Window(kSelRegs, kRgQuuxId);
    const uint64_t want = (0x5155ull << 32) | (static_cast<uint64_t>(SYNC_K_TB) << 24) |
                          (static_cast<uint64_t>(SYNC_L_TB) << 16);
    Check(w == want, "entry 21 read 0x%012" PRIx64 ", wanting QUUX's 0x%012" PRIx64, w, want);
    Check(Window(kSelRegs, 26) == kNoMemory, "entry 26 is not RO_NO_MEMORY");
  }

  // ---- the CADR's arrays at QUUX's sizes ---------------------------------
  //
  // The top of each: a window one bit too narrow reads another word there.
  {
    struct { const char *what; unsigned sel, addr, bits; } at[] = {
        {"the PDL buffer's word 16383", kSelPdl, 16383, 32},
        {"the PDL buffer's word 1024", kSelPdl, 1024, 32},
        {"the level-1 map's entry 2047", kSelMap1, 2047, 6},
        {"the level-2 map's entry 2047", kSelMap2, 2047, 24},
        {"the level-2 map's entry 1024", kSelMap2, 1024, 24},
        {"the boot PROM's word 1023", kSelProm, 1023, 48},
    };
    for (auto &a : at) {
      // The poison with its top bit forced, so the bit a narrower window
      // loses is a one.
      const uint64_t v = Poison(a.sel, a.addr, a.bits) | (1ull << (a.bits - 1));
      switch (a.sel) {
        case kSelPdl: PROC(pdl)[a.addr] = static_cast<uint32_t>(v); break;
        case kSelMap1: PROC(l1_map)[a.addr] = static_cast<uint8_t>(v); break;
        case kSelMap2: PROC(l2_map)[a.addr] = static_cast<uint32_t>(v); break;
        default: PROC(prom_mem)[a.addr] = v; break;
      }
      // And the word below it different, so an address that lost its top
      // bit cannot come back right.
      const uint64_t w = Window(a.sel, a.addr);
      Check(w == v, "%s read 0x%012" PRIx64 ", holding 0x%012" PRIx64, a.what, w, v);
    }
    // PDL pointer and index are fourteen bits on QUUX.
    PROC(pdl_ptr) = 0x3ABC;
    PROC(pdl_idx) = 0x2DEF;
    Check(Window(kSelRegs, 11) == 0x3ABC, "the PDL pointer's fourteen bits");
    Check(Window(kSelRegs, 12) == 0x2DEF, "the PDL index's fourteen bits");
  }

  // ---- the clocks: entries 22 to 25 --------------------------------------
  for (int round = 0; round < 2; ++round) {
    // Two poisons, each bit of the flags taken both ways, and in each timer
    // each flag unlike the one beside it, so two flags crossed are seen.
    CLK(usec) = static_cast<uint32_t>(Poison(30 + round, 0, 32));
    CLK(usec_t) = static_cast<uint8_t>(Poison(30 + round, 1, 32) % 100u);
    CLK(en) = round ? 0b10 : 0b01;
    CLK(sticky) = round ? 0b01 : 0b10;
    CLK(live) = round ? 0b10 : 0b01;
    for (unsigned k = 0; k < 2; ++k) {
      CLK(pre)[k] = static_cast<uint8_t>(Poison(32 + round, k, 32) % 100u);
      CLK(us)[k] = static_cast<uint32_t>(Poison(34 + round, k, 24)) | 0x800000u;
    }
    CLK(interval_us) = static_cast<uint32_t>(Poison(36 + round, 0, 24));
    Tick();
    Moving("entry 22, the microsecond clock", Window(kSelRegs, kRgTime), &Expect::time);
    Moving("entry 23, the tick", Window(kSelRegs, kRgTick), &Expect::tick);
    Moving("entry 24, the interval timer", Window(kSelRegs, kRgInterval), &Expect::interval);
    const uint64_t p = Window(kSelRegs, kRgPeriod);
    Check(p == CLK(interval_us), "entry 25 read 0x%012" PRIx64 ", the period being 0x%06x", p,
          static_cast<unsigned>(CLK(interval_us)));
  }

  // ---- the arithmetic a reader does: when the flag next rises ------------
  //
  // The tick set going with a rise a few hundred ticks off, the interval
  // timer off.  From the word alone, with the microsecond clock's full count
  // from entry 22, the tick of the rise is predicted and then watched for.
  {
    CLK(en) = 0b01;
    CLK(live) = 0b01;
    CLK(sticky) = 0;
    CLK(pre)[0] = 37;
    CLK(us)[0] = 4;
    Tick();
    const uint64_t t = Window(kSelRegs, kRgTime);
    const uint64_t w = Window(kSelRegs, kRgTick);
    const uint64_t usec_full = t & 0xFFFFFFFFull;
    // The word's own microsecond bits, unwrapped against the full count
    // taken just before it.
    const uint64_t low = (w >> 41) & 0x7Fu, usec_t = (w >> 34) & 0x7Fu;
    const uint64_t usec = usec_full + ((low - usec_full) & 0x7Fu);
    const uint64_t m_word = usec * 100 + 99 - usec_t;
    const uint64_t pre = (w >> 24) & 0x7Fu, us = w & 0xFFFFFFu;
    const uint64_t m_rise = m_word + pre + (us - 1) * 100;
    long waited = 0;
    uint64_t m_seen = 0;
    while (waited < 2000) {
      Tick();
      ++waited;
      if ((CLK(sticky) & 1u) != 0) {
        // The flag is up in the tick after the one it rose in, and the
        // microsecond clock has moved on one with it.
        m_seen = static_cast<uint64_t>(CLK(usec)) * 100 + 99 - CLK(usec_t) - 1;
        break;
      }
    }
    Check(m_seen != 0, "the tick's flag never rose");
    Check(m_seen == m_rise, "the tick's flag rose at tick %" PRIu64 " of the microsecond "
          "clock and its word said %" PRIu64, m_seen, m_rise);
  }

  // ---- the keyboard and the mouse: selector 12 word 0 and the FIFO -------
  for (int round = 0; round < 2; ++round) {
    for (unsigned i = 0; i < 64; ++i)
      IN(fifo)[i] = static_cast<uint32_t>(Poison(20 + round, i, 24));
    IN(head) = round ? 59 : 6;
    IN(count) = round ? 5 : 64;
    IN(overflowed) = round;
    IN(kbd_enable) = !round;
    IN(mouse_enable) = round;
    dut->rootp->cadr_machine__DOT__memory__DOT__iob__DOT__mouse_x =
        static_cast<uint16_t>(Poison(22, round, 12));
    dut->rootp->cadr_machine__DOT__memory__DOT__iob__DOT__mouse_y =
        static_cast<uint16_t>(Poison(23, round, 12));
    dut->mouse_lines = round ? 0x50 : 0x20;
    for (int i = 0; i < 8; ++i) Tick();
    const uint64_t w = Window(kSelPage, 0);
    auto field = [&](unsigned hi, unsigned lo) { return (w >> lo) & ((1ull << (hi - lo + 1)) - 1); };
    Check(field(43, 38) == IN(head), "word 0's head %" PRIu64 ", the FIFO's %u", field(43, 38),
          static_cast<unsigned>(IN(head)));
    Check(field(37, 31) == IN(count), "word 0's count %" PRIu64 ", the FIFO's %u", field(37, 31),
          static_cast<unsigned>(IN(count)));
    Check(field(30, 30) == IN(overflowed), "word 0's overflowed");
    Check(field(29, 29) == IN(kbd_enable), "word 0's keyboard enable");
    Check(field(28, 28) == IN(mouse_changed), "word 0's mouse changed");
    Check(field(27, 27) == IN(mouse_enable), "word 0's mouse enable");
    Check(field(26, 24) == dut->rootp->cadr_machine__DOT__mouse_buttons, "word 0's buttons %" PRIu64
          ", the switches' %u", field(26, 24),
          static_cast<unsigned>(dut->rootp->cadr_machine__DOT__mouse_buttons));
    Check(field(23, 12) == dut->rootp->cadr_machine__DOT__mouse_y, "word 0's Y");
    Check(field(11, 0) == dut->rootp->cadr_machine__DOT__mouse_x, "word 0's X");
    Check(field(47, 44) == 0, "word 0's top four bits");
    for (unsigned i = 0; i < 64; ++i) {
      const uint64_t f = Window(kSelPage, 64 + i);
      Check(f == IN(fifo)[i], "the FIFO's word %u read 0x%012" PRIx64 ", holding 0x%06x", i, f,
            static_cast<unsigned>(IN(fifo)[i]));
    }
  }
  Check(IN(mouse_changed) == 1, "the mouse was moved and its changed bit is not up, so the "
        "field above was never a one");

  // ---- block-disk: words 1 to 5 ------------------------------------------
  for (int round = 0; round < 2; ++round) {
    BD(cmd) = static_cast<uint32_t>(Poison(40 + round, 0, 32));
    BD(clp) = static_cast<uint32_t>(Poison(40 + round, 1, 32));
    BD(da) = static_cast<uint32_t>(Poison(40 + round, 2, 28));
    BD(lma) = static_cast<uint32_t>(Poison(40 + round, 3, 32));
    BD(walking) = round;
    BD(walked) = !round;
    BD(past_end) = round;
    BD(nxm) = !round;
    BD(bad_command) = round;
    BD(busy_ticks) = round ? 0x1000u : 0x10u;
    BD(due) = round ? 0x0F00u : 0x5000u;
    dut->drive_present = round ? 1 : 0;
    Tick();
    Check(Window(kSelPage, 1) == BD(cmd), "word 1, the command");
    Check(Window(kSelPage, 2) == BD(clp), "word 2, the command list pointer");
    Check(Window(kSelPage, 3) == BD(da), "word 3, the disk address");
    Check(Window(kSelPage, 4) == BD(lma), "word 4, the last memory address");
    const uint64_t w = Window(kSelPage, 5);
    Moving("word 5's ticks since the blocks' time", w & 0xFFFFFFFFull, &Expect::since);
    const unsigned flags = static_cast<unsigned>((w >> 32) & 0x7Fu);
    const bool not_active = !BD(walking) && (!BD(walked) || BD(busy_ticks) >= BD(due));
    const unsigned want = (BD(walking) << 6) | (BD(walked) << 5) | (not_active << 4) |
                          (BD(past_end) << 3) | (BD(nxm) << 2) | (BD(bad_command) << 1) |
                          (dut->drive_present & 1u);
    Check(flags == want, "word 5's flags 0x%02x, the registers' 0x%02x", flags, want);
    Check((w >> 39) == 0, "word 5's top nine bits");
  }

  // ---- the page: the bus errors and MONO TV's black-on-white -------------
  for (int round = 0; round < 2; ++round) {
#define ERR(x) dut->rootp->cadr_machine__DOT__memory__DOT__busint_regs__DOT__##x
    ERR(err_xbus) = !round;
    ERR(err_unibus) = round;
    ERR(err_map) = !round;
    dut->rootp->cadr_machine__DOT__memory__DOT__g_quux_mono_tv__DOT__mono_tv__DOT__bow = !round;
    Tick();
    const uint64_t w = Window(kSelPage, 6);
    const uint64_t want = (round ? 0ull : 0x100ull) | (round ? 010ull : 041ull);
    Check(w == want, "word 6 read 0%" PRIo64 ", wanting 0%" PRIo64, w, want);
  }

  // ---- and nothing else answers there ------------------------------------
  for (unsigned a : {7u, 8u, 63u, 128u, 1000u, 16383u}) {
    const uint64_t w = Window(kSelPage, a);
    Check(w == kNoMemory, "selector 12 word %u read 0x%012" PRIx64 ", not RO_NO_MEMORY", a, w);
  }
  // The audit and the processor are still where they were.
  Check((Window(kSelAudit, 0) >> 32) == 0xB05A, "selector 11 is no longer the audit");
  Check(Window(kSelRegs, 0) == dut->rootp->cadr_machine__DOT__processor__DOT__pc,
        "the register table's PC");
#endif

  std::printf("quux_readout_window: %s, %ld checks, %ld ticks, %d failed\n",
              QUUX_TB ? "QUUX" : "the CADR", checks, ticks, fails);
  delete dut;
  return fails ? 1 : 0;
}
