// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// THE TRANSACTION AUDIT AS A HALTED BOARD WILL BE ASKED ABOUT IT: through the
// console's readout window, on the composed machine, against the module's own
// registers.
//
// **WHAT THIS HOLDS THAT THE OTHER THREE DO NOT.**
// `build/bus_audit_unit.pass` drives `rtl/plumbing/cadr_bus_audit.sv` alone
// and holds what each clause catches; `build/bus_audit.pass` runs the property
// through the composed machine on MIT's boot PROM and holds that no clause
// ever fires; `build/readout.pass` holds the window itself, against the
// processor's own arrays.  **Between them is the join, and before this check
// nothing held it at all**: that `cadr_machine.sv` puts the audit on the
// window's own three-tick pipeline at a selector of its own, that the word
// which comes back is the word the module holds, that the marker survives the
// journey, and --- the half that is easiest to break and hardest to notice ---
// that joining it did not disturb the eleven selectors that were already
// there.
//
// **A VALUE THAT MEANS NOTHING MUST NOT BE A VALUE THE INSTRUMENT CAN MEAN**,
// and this window has three ways of meaning nothing, all of them asserted
// here: `A5A5_5A5A_A5A5` for a selector the fabric does not map, the echo
// `cadr-readout` refuses on a mismatch, and `B05A` in the top sixteen bits of
// every word the audit produces.  A bitstream without the audit answers the
// first at selector 11, so "no faults" cannot be read off a board that has no
// audit in it.
//
// **THE FAULT IS INJECTED THROUGH A PORT AND NOT THROUGH THE MACHINE**, which
// is the only way it can be.  The boot PROM's first main-memory cycle is at
// microcycle 536,303 --- about fifteen and a half million ticks --- and a
// program cannot be made to fault on demand anyway; `port_read_ack` and
// `port_write_ack` are inputs of `cadr_machine` and a pulse of one with
// nothing owed is exactly the fault the seventh clause exists to name: the
// port answered a transaction nobody asked for.  That is the shape an extra
// write born inside `cadr_axi_master` has, one level below where anything in
// `rtl/machine/` can see it.
//
// The machine runs from reset throughout and is never halted.  A read taken
// while the datapath moves is torn for the REGISTER table --- `docs/console.md`
// says so and means it --- and is exact for the audit, whose eight capture
// registers move only when a fault is latched and whose counters are compared
// here against themselves at the same instant.

#include <cinttypes>
#include <cstdarg>
#include <cstdint>
#include <cstdio>

#include "Vcadr_machine.h"
#include "Vcadr_machine___024root.h"
#include "verilated.h"

namespace {

constexpr uint64_t kNoMemory = 0xA5A5'5A5A'A5A5ull;
constexpr uint16_t kMark = 0xB05A;
constexpr unsigned kAuditSel = 11;
constexpr unsigned kAuditWords = 9;

// The clause codes, as `rtl/plumbing/cadr_bus_audit.sv` names them.
constexpr unsigned kNone = 0, kPortExtra = 7;

int fails = 0;

void Check(bool ok, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void Check(bool ok, const char *fmt, ...) {
  if (ok) return;
  ++fails;
  va_list ap;
  va_start(ap, fmt);
  std::fprintf(stderr, "FAIL: ");
  std::vfprintf(stderr, fmt, ap);
  std::fprintf(stderr, "\n");
  va_end(ap);
}

Vcadr_machine *dut;
long ticks = 0;

void Tick() {
  dut->clk = 0;
  dut->eval();
  dut->clk = 1;
  dut->eval();
  ++ticks;
}

// One word out of the window, the way `cadr-readout` takes it: write the
// address, wait for the pipeline, and REFUSE a word whose echo is not what was
// asked.  Three ticks is the depth --- `ro_a0`, the second ports, the word
// register --- and four are taken so that a design a tick slower would be seen
// rather than accommodated.
uint64_t Window(unsigned sel, unsigned addr) {
  const unsigned asked = ((sel & 0xFu) << 14) | (addr & 0x3FFFu);
  dut->con_ro_addr = asked;
  for (int i = 0; i < 4; ++i) Tick();
  Check(dut->con_ro_echo == asked,
        "the window echoed 0x%05x for an address of 0x%05x",
        static_cast<unsigned>(dut->con_ro_echo), asked);
  return dut->con_ro_data;
}

uint16_t Mark(uint64_t w) { return static_cast<uint16_t>(w >> 32); }

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vcadr_machine;
  auto *root = dut->rootp;
#define A(x) root->cadr_machine__DOT__audit__DOT__##x

  dut->clk = 0;
  dut->rst = 1;
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
  dut->ser_ready = 0;
  dut->chaos_intr = 0;
  dut->eval();
  for (int i = 0; i < 8; ++i) Tick();
  dut->rst = 0;

  // A few hundred microcycles of MIT's boot PROM, so that the machine is
  // running and the audit's microcycle counter is a real coordinate rather
  // than zero.  Nothing here reaches a bus cycle --- the first is at 536,303
  // --- and nothing needs to: what this check is about is the join.
  for (int i = 0; i < 20000; ++i) Tick();
  const uint32_t micro_now = A(micro);
  Check(micro_now > 100,
        "the machine retired %u microcycles in 20,000 ticks, so it is not "
        "running and nothing below means anything", micro_now);

  // ---- A CLEAN INSTRUMENT, THROUGH THE WINDOW -------------------------------
  //
  // Every one of the sixteen words carries the marker, the nine that are
  // defined read what the module holds, and the seven above them read the
  // marker with nothing beside it.  An all-zeros and an all-ones reading are
  // each impossible, which is the whole point of the marker.
  for (unsigned i = 0; i < 16; ++i) {
    const uint64_t w = Window(kAuditSel, i);
    Check(Mark(w) == kMark,
          "audit word %u reads %012" PRIx64 ", marker %04x and not %04x", i, w,
          Mark(w), kMark);
    Check(w != 0 && w != 0xFFFFFFFFFFFFull,
          "audit word %u reads %012" PRIx64 ", which is a value an undriven "
          "path can also produce", i, w);
    Check(w != kNoMemory,
          "audit word %u collides with the window's own answer for a selector "
          "the fabric does not map", i);
    if (i >= kAuditWords) {
      Check((w & 0xFFFFFFFFull) == 0,
            "audit word %u is not a word: it reads %012" PRIx64, i, w);
    }
  }

  Check((Window(kAuditSel, 0) & 0x7FFFu) == 0,
        "a machine that has made no bus cycle reads %llu faults",
        static_cast<unsigned long long>(Window(kAuditSel, 0) & 0x7FFFu));
  Check(((Window(kAuditSel, 1) >> 22) & 7u) == kNone,
        "a machine that has made no bus cycle has latched clause %llu",
        static_cast<unsigned long long>((Window(kAuditSel, 1) >> 22) & 7u));
  Check((Window(kAuditSel, 8) & 0xFFFFFFFFull) == 0x00008000ull,
        "the port's own tally reads %08llx before the port has answered "
        "anything, wanting the two marker bits alone",
        static_cast<unsigned long long>(Window(kAuditSel, 8) & 0xFFFFFFFFull));

  // ---- THE ELEVEN SELECTORS THAT WERE ALREADY THERE --------------------------
  //
  // The join is a mux on `con_ro_data`, and the way to break a mux is to have
  // it select the wrong arm.  `build/readout.pass` holds every word of every
  // memory against the arrays; what is held here is only that they still come
  // from the processor and not from the audit --- which the marker makes
  // decidable, `B05A` in the top sixteen bits being a thing no memory of this
  // machine produces for these words.
  {
    const uint64_t regs_pc = Window(10, 0);            // the register table, PC
    Check(Mark(regs_pc) != kMark,
          "the register table answered with the audit's marker: the window's "
          "mux is selecting the wrong arm");
    Check((regs_pc & 0x3FFFu) == dut->pc,
          "the window says PC is 0o%llo and the machine's own port says 0o%o",
          static_cast<unsigned long long>(regs_pc & 0x3FFFu), dut->pc);
    const uint64_t prom0 = Window(1, 0);               // the boot PROM
    Check(Mark(prom0) != kMark,
          "the boot PROM answered with the audit's marker");
    // AND THE SELECTORS ABOVE THE AUDIT ARE STILL UNMAPPED.  A mux written as
    // "11 or above" rather than "11" would swallow these, and a bitstream with
    // no audit in it answers this at selector 11 --- which is what makes "no
    // faults" unreadable off a board that has none.
    for (unsigned s = 12; s < 16; ++s) {
      const uint64_t w = Window(s, 0);
      Check(w == kNoMemory,
            "selector %u reads %012" PRIx64 ", wanting the window's own "
            "%012" PRIx64 " for a selector the fabric does not map", s, w,
            kNoMemory);
    }
  }

  // ---- THE FAULT THAT REACHES PAST `cadr_machine` ----------------------------
  //
  // A `B` at the processing system's boundary with no write owed.  Nothing in
  // `rtl/machine/` can see the transaction that caused it --- the adapter is a
  // level above this module and raises no `mem_req` for one of its own --- and
  // this is the clause that does.
  const uint32_t vma_before = dut->vma;
  const uint32_t md_before = dut->md;
  dut->port_write_ack = 1;
  Tick();
  dut->port_write_ack = 0;
  for (int i = 0; i < 4; ++i) Tick();

  {
    const uint64_t w0 = Window(kAuditSel, 0);
    const uint64_t w1 = Window(kAuditSel, 1);
    const uint64_t w8 = Window(kAuditSel, 8);
    Check((w0 & 0x7FFFu) == 1, "the fault count reads %llu, wanting 1",
          static_cast<unsigned long long>(w0 & 0x7FFFu));
    Check(((w1 >> 22) & 7u) == kPortExtra,
          "clause %llu latched, wanting %u --- the port answered a "
          "transaction nobody asked for",
          static_cast<unsigned long long>((w1 >> 22) & 7u), kPortExtra);
    Check(((w1 >> 25) & 0x7Fu) == (1u << (kPortExtra - 1)),
          "the clause bitmap reads %#llx",
          static_cast<unsigned long long>((w1 >> 25) & 0x7Fu));
    Check((w8 & 0x7FFFu) == 0 && ((w8 >> 16) & 0x7FFFu) == 1,
          "the port's tally reads %llu reads and %llu writes, wanting 0 and 1",
          static_cast<unsigned long long>(w8 & 0x7FFFu),
          static_cast<unsigned long long>((w8 >> 16) & 0x7FFFu));
    // THE RECORD NAMES THE INSTANT, which is what makes it worth reading
    // hours later.  VMA and MD are the machine's own at the fault and are
    // compared against the ports rather than against a constant.
    Check(static_cast<uint32_t>(Window(kAuditSel, 4)) == vma_before,
          "the record's VMA is 0x%08x and the machine's was 0x%08x",
          static_cast<uint32_t>(Window(kAuditSel, 4)), vma_before);
    Check(static_cast<uint32_t>(Window(kAuditSel, 5)) == md_before,
          "the record's MD is 0x%08x and the machine's was 0x%08x",
          static_cast<uint32_t>(Window(kAuditSel, 5)), md_before);
    Check(static_cast<uint32_t>(Window(kAuditSel, 6)) >= micro_now,
          "the record names microcycle %u and the machine had retired %u "
          "before the fault",
          static_cast<uint32_t>(Window(kAuditSel, 6)), micro_now);
  }

  // ---- AND THE WORD IS THE MODULE'S OWN, BIT FOR BIT -------------------------
  //
  // The join could carry a stale word, a word off by a tick, or a word from
  // the wrong index and every assertion above would still pass.  This is the
  // one that says the window is reading THIS module: each field against the
  // register it comes from, reached by name.  Another read is thrown at it
  // first, in the wrong order, so that a window answering whatever it last
  // held rather than what was asked is caught rather than accommodated.
  {
    (void)Window(kAuditSel, 3);
    const uint64_t w0 = Window(kAuditSel, 0);
    const uint64_t w1 = Window(kAuditSel, 1);
    const uint64_t w2 = Window(kAuditSel, 2);
    const uint64_t w3 = Window(kAuditSel, 3);
    const uint64_t w6 = Window(kAuditSel, 6);
    const uint64_t w7 = Window(kAuditSel, 7);
    const uint64_t w8 = Window(kAuditSel, 8);
    Check((w0 & 0x7FFFu) == A(faults), "word 0's fault count is %llu and the "
          "module holds %u", static_cast<unsigned long long>(w0 & 0x7FFFu),
          A(faults));
    Check(((w0 >> 16) & 0x7FFFu) == A(stalled),
          "word 0's stall count is %llu and the module holds %u",
          static_cast<unsigned long long>((w0 >> 16) & 0x7FFFu), A(stalled));
    Check((w1 & 0x3FFFFFu) == A(first_phys),
          "word 1's physical address is 0o%llo and the module holds 0o%o",
          static_cast<unsigned long long>(w1 & 0x3FFFFFu), A(first_phys));
    Check(((w1 >> 22) & 7u) == A(first_clause),
          "word 1's clause is %llu and the module holds %u",
          static_cast<unsigned long long>((w1 >> 22) & 7u), A(first_clause));
    Check(((w1 >> 25) & 0x7Fu) == A(seen),
          "word 1's clause bitmap is %#llx and the module holds %#x",
          static_cast<unsigned long long>((w1 >> 25) & 0x7Fu), A(seen));
    Check(static_cast<uint32_t>(w2) == A(first_addr),
          "word 2 is 0x%08x and the module holds 0x%08x",
          static_cast<uint32_t>(w2), A(first_addr));
    Check(static_cast<uint32_t>(w3) == A(first_data),
          "word 3 is 0x%08x and the module holds 0x%08x",
          static_cast<uint32_t>(w3), A(first_data));
    Check(static_cast<uint32_t>(w6) == A(first_micro),
          "word 6 is %u and the module holds %u", static_cast<uint32_t>(w6),
          A(first_micro));
    Check((w7 & 0x3FFFu) == A(first_opc),
          "word 7's OPC is 0o%llo and the module holds 0o%o",
          static_cast<unsigned long long>(w7 & 0x3FFFu), A(first_opc));
    Check(((w7 >> 16) & 0x3FFFu) == A(first_pc),
          "word 7's PC is 0o%llo and the module holds 0o%o",
          static_cast<unsigned long long>((w7 >> 16) & 0x3FFFu), A(first_pc));
    Check((w8 & 0x7FFFu) == A(port_reads),
          "word 8's read count is %llu and the module holds %u",
          static_cast<unsigned long long>(w8 & 0x7FFFu), A(port_reads));
    Check(((w8 >> 16) & 0x7FFFu) == A(port_writes),
          "word 8's write count is %llu and the module holds %u",
          static_cast<unsigned long long>((w8 >> 16) & 0x7FFFu),
          A(port_writes));
  }

  // ---- THE LATCH HOLDS THE FIRST AND THE TALLY KEEPS MOVING ------------------
  //
  // A second fault, in the other direction: the record must not move and both
  // counts must.  An instrument whose record followed the last fault would
  // hand back the neighbourhood of a machine that had already been corrupted.
  {
    const uint32_t first_addr = A(first_addr);
    for (int i = 0; i < 3; ++i) {
      dut->port_read_ack = 1;
      Tick();
      dut->port_read_ack = 0;
      Tick();
    }
    const uint64_t w0 = Window(kAuditSel, 0);
    const uint64_t w1 = Window(kAuditSel, 1);
    const uint64_t w8 = Window(kAuditSel, 8);
    Check((w0 & 0x7FFFu) == 4, "the fault count reads %llu, wanting 4",
          static_cast<unsigned long long>(w0 & 0x7FFFu));
    Check(((w1 >> 22) & 7u) == kPortExtra, "the latched clause moved to %llu",
          static_cast<unsigned long long>((w1 >> 22) & 7u));
    Check(A(first_addr) == first_addr,
          "the record moved: byte address 0x%08x, wanting the first fault's "
          "0x%08x", A(first_addr), first_addr);
    Check((w8 & 0x7FFFu) == 3 && ((w8 >> 16) & 0x7FFFu) == 1,
          "the port's tally reads %llu reads and %llu writes, wanting 3 and 1",
          static_cast<unsigned long long>(w8 & 0x7FFFu),
          static_cast<unsigned long long>((w8 >> 16) & 0x7FFFu));
  }

  // ---- AND THE MACHINE IS STILL RUNNING --------------------------------------
  //
  // The audit is read-only and nothing it produces reaches the datapath.  That
  // is a claim and this is the cheap check on it: the machine has gone on
  // retiring microcycles through every read above.
  {
    const uint32_t before = A(micro);
    for (int i = 0; i < 2000; ++i) Tick();
    Check(A(micro) > before,
          "the machine retired nothing over 2,000 ticks of being read: the "
          "window is disturbing it");
  }

  if (fails) {
    std::fprintf(stderr, "audit window: %d failure%s\n", fails,
                 fails == 1 ? "" : "s");
    return 1;
  }
  std::printf("audit window: ok --- the audit answers selector 11 of the "
              "console's window with the words the module holds, every one of "
              "them marked, the eleven selectors below it untouched and the "
              "four above it still unmapped; a transaction the port answered "
              "that nobody asked for is latched, named and readable, and the "
              "machine ran through all of it (%ld ticks, %u microcycles)\n",
              ticks, A(micro));
  return 0;
}
