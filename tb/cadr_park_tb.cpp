// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A HALTED MACHINE MUST GO ON MAKING MASTER CLOCKS, AND CC's OWN ENTRY MUST
// NOT PARK THE RING.
//
// **WHAT THIS HOLDS, AND WHERE THE REFERENCE IS.**  `Rtl::step` answers a
// halted machine before it looks at the bus at all --- `if !r.machrun { the
// master clock cycle; return }` --- so a halted muir never takes a `-HANG`,
// the generator goes on running, and the console, the bus interface and the
// synchronizers on OLORD1 go on working.  That is the property here, and it
// is a property rather than a trace because no reference program halts
// itself: the clock control register is the console's, and a machine running
// its own microcode has no console.  `build/sstep.pass` scripts the same
// register against muir row for row; what it cannot reach is a memory cycle,
// which its own header says, and this is that half.
//
// **THE SEQUENCE IS MIT's, NOT INVENTED.**  `sys/cc/lcadrd.lisp`:
//
//     CC-STOP-MACH        (SPY-WRITE SPY-CLK 0)     and nothing else at all
//     CC-PASSIVE-SAVE     spy reads
//     CC-SAVE-OPCS        spy reads and OPC clocks
//     CC-READ-A-MEM 1     CC-EXECUTE-R -> one CC-NOOP-DEBUG-CLOCK, 16 octal
//     CC-READ-M-MEM 0     the same
//     CC-SAVE-MEM-STATUS  three more: VMA, MAP, and **MD**, the last being
//                         `CONS-M-SRC-MD`, which is `SRCMD` --- the source
//                         `USE.MD` and so `-HANG` are made of.
//
// There is no handshake anywhere in it.  CC clears RUN mid-microcycle with no
// regard for what the machine was doing, and forces five microinstructions
// afterwards; `SSDONE` and `CLOCK-WAIT` are in FLAG-1 and named in CC's own
// bit table, and CC reads neither.  So whatever protected the real CADR here
// was in the hardware.
//
// **WHAT PARKING LOOKS LIKE, AND WHY IT CANNOT BE ESCAPED.**
// `cadr_phase_gen.sv`'s ring parks on `-HANG` at the wrap and makes no
// boundary, so `cadr_microcycle.sv`'s `mclk` never rises; the bus interface
// takes its grant only with `mclk` high (`cadr_busint_xbus.sv`, IDLE and
// REQUESTED), so no cycle can be started to end the hang; and
// `cadr_spy_registers.sv`'s `landing` is `mclk || phase_t == SPEEDCLK_T` with
// `phase_t` saturating, so **no console write can ever land again**.  RUN, a
// STEP pulse and the console's own step are all inert.  Only `rst` is left,
// which is what the board measured.
//
// So the check is crude on purpose: after every step of CC's entry the master
// clock must have run inside a bound, and at the end the machine must start
// again and retire microcycles.
//
// **THE STIMULUS IS THE BOOT PROM's PARITY LOOP**, `PAGE-0-PARITY-FIX`, which
// is the only main-memory traffic the PROM has: 512 reads and 512 writes from
// microcycle 536,303.  DDR is modeled here as `md_compose` models it, keyed
// by the bridge's own address out of a window poisoned injectively, because
// the point is the handshake and not the words.  The halt is issued at each
// phase of a memory cycle in turn --- before MEMGO, between MEMGO and the
// grant, between the grant and the acknowledgement, after it, and with no
// cycle at all --- and the state the machine actually froze in is reported
// rather than assumed, since the write lands at a boundary and the machine
// stops where it stops.

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "Vcadr_machine.h"
#include "Vcadr_machine___024root.h"
#include "verilated.h"

namespace {

constexpr uint32_t kMainBase = 0x18000000u;
constexpr int kWindowWords = 4096;
constexpr uint32_t kNotAnswering = 0xDEADBEE5u;

// The boot PROM's first memory cycle is at microcycle 536,303, which is about
// 15.5 million ticks; the parity loop runs 512 of them.
constexpr long kWarmTicks = 30000000L;

// How long the ring may go without a boundary before it is parked.  A
// microcycle is 29 ticks at normal speed and 44 at extra slow, and a hang
// that ends legitimately is `RD_FINISH_T` = 25 ticks; 400 is an order of
// magnitude past any of them.
constexpr long kParkedTicks = 400;

// The halt is issued at every tick of a microcycle in turn.  A microcycle is
// 29 ticks at normal speed, so this covers every instruction of the loop and
// every phase of a memory cycle within it.
constexpr int kSweep = 40;

// The sixteen diagnostic registers at Unibus 0o766000, EADR = addr<4:1>.
constexpr int kSpyBase = 0766000;
constexpr int kIrLow = 0, kIrMed = 1, kIrHigh = 2, kClk = 3, kPc = 5;
constexpr int kFlag1 = 8;

// `spy::ClockControl`, MIT's own octal: 1 RUN, 2 STEP, 4 NOP11, 10 IDEBUG.
constexpr int kRun = 1, kStep = 2, kNop11 = 4, kIdebug = 010;
constexpr int kCcNoopDebugClock = kStep | kNop11 | kIdebug;   // 16 octal

uint32_t Poison(int word) {
  uint32_t p = (0x9E3779B9u * static_cast<uint32_t>(word + 1)) ^ 0xA5A5A5A5u;
  return p & ~1u;
}

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

class Sim {
 public:
  Sim() {
    dut_ = new Vcadr_machine;
    // `-BOOT2` is a pulled-up line and nothing here presses it. **Active low,
    // so an undriven input would hold the machine at the boot trap for ever.**
    dut_->n_boot2 = 1;
    root_ = dut_->rootp;
    mem_.assign(kWindowWords, 0);
    for (int i = 0; i < kWindowWords; ++i) mem_[i] = Poison(i);
    dut_->clk = 0;
    dut_->rst = 1;
    dut_->boards = 32;
    dut_->device_ack = 0;
    dut_->device_rdata = 0;
    dut_->mem_done = 0;
    dut_->mem_rdata = kNotAnswering;
    dut_->con_req = 0;
    dut_->con_msyn = 0;
    dut_->con_write = 0;
    dut_->con_addr = 0;
    dut_->con_wdata = 0;
    dut_->eval();
    for (long t = 0; t < 16; ++t) {
      dut_->rst = (t < 8);
      Tick();
    }
  }
  ~Sim() { delete dut_; }

  // One tick, with the modeled DDR answering on the machine's memory port.
  void Tick() {
    dut_->mem_done = 0;
    dut_->mem_rdata = kNotAnswering;
    if (dut_->mem_req) {
      if (!req_last_) pending_ = 4 + (transactions_ * 13) % 37;
      if (pending_ > 0) --pending_;
      if (pending_ == 0) {
        ++transactions_;
        const long w =
            (static_cast<long>(dut_->mem_addr) - static_cast<long>(kMainBase)) / 4;
        const bool inside =
            w >= 0 && w < kWindowWords && (dut_->mem_addr & 3u) == 0;
        if (dut_->mem_write) {
          if (inside) mem_[w] = dut_->mem_wdata;
        } else {
          dut_->mem_rdata = inside ? mem_[w] : kNotAnswering;
        }
        dut_->mem_done = 1;
        pending_ = -1;
      }
    } else {
      pending_ = -1;
    }
    req_last_ = dut_->mem_req != 0;

    dut_->clk = 1;
    dut_->eval();
    ++ticks_;
    if (MclkEdge()) last_mclk_ = ticks_;
    if (dut_->clock_edge) ++micro_;
    dut_->clk = 0;
    dut_->eval();
  }

  int MclkEdge() const {
    return root_->cadr_machine__DOT__processor__DOT__mclk_edge;
  }
  long TicksSinceMclk() const { return ticks_ - last_mclk_; }
  bool Parked() { return TicksSinceMclk() > kParkedTicks; }
  long ticks() const { return ticks_; }
  long micro() const { return micro_; }

  // The console's Unibus cycle, bounded so a parked ring ends it rather than
  // hanging the check: this is exactly the board's own experience, where
  // `cadr-console write 3 1` completed and did nothing.
  bool ConsoleCycle(int addr, bool write, uint16_t wdata, uint16_t *rdata) {
    dut_->con_req = 1;
    dut_->con_addr = addr;
    dut_->con_write = write ? 1 : 0;
    dut_->con_wdata = wdata;
    for (long g = 0; g < 600 && !dut_->con_gnt; ++g) Tick();
    if (!dut_->con_gnt) {
      dut_->con_req = 0;
      return false;
    }
    dut_->con_msyn = 1;
    bool answered = false;
    for (long g = 0; g < 4000; ++g) {
      Tick();
      if (dut_->con_ssyn) {
        answered = true;
        break;
      }
    }
    if (rdata) *rdata = dut_->con_rdata & 0xFFFFu;
    dut_->con_msyn = 0;
    for (long g = 0; g < 8; ++g) Tick();
    dut_->con_req = 0;
    for (long g = 0; g < 4; ++g) Tick();
    return answered;
  }

  bool SpyWrite(int eadr, uint16_t v) {
    return ConsoleCycle(kSpyBase + 2 * eadr, true, v, nullptr);
  }
  uint16_t SpyRead(int eadr) {
    uint16_t v = 0xFFFF;
    ConsoleCycle(kSpyBase + 2 * eadr, false, 0, &v);
    return v;
  }

  // CC-EXECUTE-R: the debug IR in three halves, then one CC-NOOP-DEBUG-CLOCK.
  void CcExecuteR(uint64_t insn) {
    SpyWrite(kIrLow, static_cast<uint16_t>(insn));
    SpyWrite(kIrMed, static_cast<uint16_t>(insn >> 16));
    SpyWrite(kIrHigh, static_cast<uint16_t>(insn >> 32));
    SpyWrite(kClk, kCcNoopDebugClock);
    for (long g = 0; g < 120; ++g) Tick();
    SpyWrite(kClk, 0);
    for (long g = 0; g < 120; ++g) Tick();
  }

  Vcadr_machine *dut() { return dut_; }

  // The state the machine froze in, which is the honest variable: the halt
  // write lands at a boundary, so where it stops is not the phase it was
  // asked at.
  std::string Frozen() {
    char buf[256];
    std::snprintf(buf, sizeof buf,
                  "PC %o memstart %d rdcyc %d -MEMRQ %d -MEMGRANT %d "
                  "-MEMACK %d MBUSY %d",
                  dut_->pc, dut_->memstart, dut_->rdcyc_o, dut_->n_memrq_o,
                  dut_->n_memgrant_o, dut_->n_memack_o, dut_->mbusy_o);
    return std::string(buf);
  }

 private:
  Vcadr_machine *dut_;
  Vcadr_machine___024root *root_;
  std::vector<uint32_t> mem_;
  long pending_ = -1;
  bool req_last_ = false;
  long transactions_ = 0;
  long ticks_ = 0;
  long last_mclk_ = 0;
  long micro_ = 0;
};

// The five microinstructions CC's entry forces, in CC's own order.  `ALU`,
// `SETA` and `SETM` are `muir::isa::asm`'s encodings, which `golden/src/
// sstep.rs` uses for the same purpose.
constexpr uint64_t kAlu = 1ull << 12;
constexpr uint64_t kSetM = 3ull << 3;
constexpr uint64_t kSetA = 5ull << 3;
uint64_t ASrc(uint64_t a) { return a << 32; }
uint64_t MSrc(uint64_t m) { return m << 26; }
uint64_t FSrc(uint64_t n) { return (1ull << 31) | (n << 26); }

// `CONS-M-SRC-MD` is functional source 12 octal, which `cadr_microcycle.sv`
// decodes as `srcmd` --- `group_b && ir<28:26> == 2` --- and `USE.MD` is
// `srcmd && !nop`.  This is the instruction CC-SAVE-MEM-STATUS forces last.
const uint64_t kReadMd = kAlu | kSetM | FSrc(012);
const uint64_t kReadVma = kAlu | kSetM | FSrc(011);
const uint64_t kReadMap = kAlu | kSetM | FSrc(015);
const uint64_t kReadAMem1 = kAlu | kSetA | ASrc(1) | MSrc(7);
const uint64_t kReadMMem0 = kAlu | kSetA | ASrc(0) | MSrc(0);

}  // namespace


// One halt: CC-STOP-MACH is a single write of zero, and nothing else.
void Halt(Sim &s) {
  s.SpyWrite(kClk, 0);
  for (long g = 0; g < 400; ++g) s.Tick();
}

// The assertions every halted machine must satisfy, whatever it was doing.
void MustBeAlive(Sim &s, const char *who) {
  if (s.Parked()) {
    Check(false, "%s: the ring is parked --- no master clock for %ld ticks, at %s",
          who, s.TicksSinceMclk(), s.Frozen().c_str());
    return;
  }
  // A frozen read-back latch --- `cadr_console_bus.sv`'s `if (mclk) con_rdata
  // <= sr_rdata` --- shows ONE constant on all sixteen diagnostic registers,
  // register 3 among them, which is what the board read.
  const uint16_t flag1 = s.SpyRead(kFlag1);
  const uint16_t pc = s.SpyRead(kPc);
  const uint16_t clkreg = s.SpyRead(kClk);
  Check(!(flag1 == pc && pc == clkreg),
        "%s: all sixteen diagnostic registers read 0x%04x --- the read-back "
        "latch is frozen", who, flag1);
  // EADR 5 is `{2'b00, pc}`: bits 15 and 14 cannot come from the machine.
  Check((pc & 0xC000u) == 0, "%s: PC reads 0x%04x, which the mux cannot produce",
        who, pc);
}

// CC-START-MACH's last act, and the machine must retire microcycles again
// AND LET THE BUS GO.
//
// The second half is not a tidiness.  A halt stands -MEMRQ on its frozen
// MEMSTART and the interface answers and then sits in ACKED, which it leaves
// only when -MEMRQ falls; -MEMRQ falls only when MBUSY does, and MBUSY is
// cleared by -MFINISHD, the acknowledgement delayed.  So a machine whose
// MBUSY is never cleared holds -XBUS.RQ up for ever, the interface
// acknowledges every later cycle before it has happened, and every read
// takes the word the last one left --- while the ring turns, microcycles
// retire and the console answers.  A check that asks only whether the
// machine is alive calls that healthy.
void Restart(Sim &s, const char *who) {
  s.SpyWrite(kClk, kRun);
  const long before = s.micro();
  bool rq_released = false, ack_released = false;
  for (long g = 0; g < 4000; ++g) {
    s.Tick();
    if (s.dut()->n_memrq_o) rq_released = true;
    if (s.dut()->n_memack_o) ack_released = true;
  }
  Check(s.micro() > before + 10,
        "%s: the machine did not start again --- %ld microcycles in 4,000 "
        "ticks, at %s", who, s.micro() - before, s.Frozen().c_str());
  Check(rq_released,
        "%s: -MEMRQ never fell in 4,000 ticks of a running machine --- the "
        "bus was never let go, at %s", who, s.Frozen().c_str());
  Check(ack_released,
        "%s: -MEMACK stood for the whole of 4,000 ticks of a running machine "
        "--- every cycle is being answered before it happens, at %s",
        who, s.Frozen().c_str());
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Sim s;

  // ---- to the boot PROM's parity loop, `PAGE-0-PARITY-FIX`, which is the
  // ---- PROM's only main-memory traffic: 512 reads and 512 writes.
  long warm = 0;
  while (warm < kWarmTicks && !s.dut()->mem_req) {
    s.Tick();
    ++warm;
  }
  if (!s.dut()->mem_req) {
    std::fprintf(stderr, "FAIL: the machine never asked for memory in %ld ticks\n",
                 warm);
    return 1;
  }
  std::printf("the parity loop is reached at tick %ld, microcycle %ld\n",
              s.ticks(), s.micro());

  // ---- How often MBUSY stands with the bus not yet granted, which is the
  // ---- window MIT's second -WAIT term --- `USE.MD AND MBUSY AND -MEMGRANT`
  // ---- --- exists to cover.  Reported rather than asserted: an Xbus cycle
  // ---- is granted at the same master clock as MEMGO, so the two come up
  // ---- together and the window is empty, while a Unibus cycle spends five
  // ---- master clocks in ARB and it is not.  Either way it is not where the
  // ---- hazard below lives, which is the point worth writing down.
  long ungranted = 0, cycles_watched = 0, prev_mbusy = 0;
  for (long g = 0; g < 60000; ++g) {
    s.Tick();
    if (s.dut()->mbusy_o && !prev_mbusy) ++cycles_watched;
    if (s.dut()->mbusy_o && s.dut()->n_memgrant_o) ++ungranted;
    prev_mbusy = s.dut()->mbusy_o;
  }
  Check(cycles_watched > 100,
        "only %ld memory cycles were watched, which is too few to claim "
        "anything", cycles_watched);
  std::printf("  %ld memory cycles watched, %ld ticks with MBUSY up and the "
              "bus ungranted\n", cycles_watched, ungranted);

  // ==== PART ONE: a halt at every phase, and a plain restart.
  //
  // This is the shorter reproduction and it needs no debugger at all.  A halt
  // freezes MEMSTART, which stands -MEMRQ for the whole halt and holds the
  // interface acknowledging; the restart's first cpu edge fires MEMGO again
  // off that frozen MEMSTART, and what happens next is the whole question.
  // A halt and a restart move no PC, so the machine stays in the loop and the
  // sweep can be long.
  int read_prepared = 0, write_prepared = 0, idle_halt = 0, halts = 0;
  for (int k = 0; k < kSweep && fails == 0; ++k) {
    ++halts;
    for (int g = 0; g < k; ++g) s.Tick();
    Halt(s);
    const long stopped = s.micro();
    for (long g = 0; g < 400; ++g) s.Tick();
    Check(s.micro() == stopped, "k=%d: the machine did not stop (%ld -> %ld)",
          k, stopped, s.micro());
    if (s.dut()->memstart && s.dut()->rdcyc_o) ++read_prepared;
    else if (s.dut()->memstart) ++write_prepared;
    else ++idle_halt;
    char who[64];
    std::snprintf(who, sizeof who, "halt k=%d", k);
    MustBeAlive(s, who);
    Restart(s, who);
    // And the machine must go on being able to be halted, which is what the
    // next turn of this loop asks.
    for (long g = 0; g < 1000; ++g) s.Tick();
    MustBeAlive(s, who);
  }
  std::printf("  %d halts: %d froze a read, %d a write, %d no cycle at all\n",
              halts, read_prepared, write_prepared, idle_halt);
  Check(read_prepared > 0,
        "no halt in the sweep froze MEMSTART up on a read, so the hazard was "
        "never reached and this check proves nothing");
  Check(idle_halt > 0,
        "every halt in the sweep froze a memory cycle, so the sweep is not a "
        "sweep");

  // ==== PART TWO: CC's own entry, on a halt that froze a read.
  //
  // `CC-STOP-MACH` is one write of zero with no handshake; `CC-FULL-SAVE`
  // then forces five microinstructions through the debug IR, the last of them
  // `CONS-M-SRC-MD` --- `SRCMD`, which is what `USE.MD` and so `-HANG` are
  // made of.  This is destructive of the program, since a forced instruction
  // advances PC and CC puts it back only in `CC-FULL-RESTORE`, so it is done
  // once and last.
  int tries = 0;
  while (tries < 60 && fails == 0) {
    ++tries;
    Halt(s);
    if (s.dut()->memstart && s.dut()->rdcyc_o) break;
    Restart(s, "looking for a read prepared");
    for (long g = 0; g < 200 + 37 * tries; ++g) s.Tick();
  }
  Check(s.dut()->memstart && s.dut()->rdcyc_o,
        "no halt in %d tries froze a read for CC's entry to be run against",
        tries);
  if (fails == 0) {
    std::printf("  CC enters a machine halted at %s\n", s.Frozen().c_str());
    const uint64_t forced[5] = {kReadAMem1, kReadMMem0, kReadVma, kReadMap,
                                kReadMd};
    const char *what[5] = {"CC-READ-A-MEM 1", "CC-READ-M-MEM 0",
                           "CC-SAVE-MEM-STATUS VMA", "CC-SAVE-MEM-STATUS MAP",
                           "CC-SAVE-MEM-STATUS MD"};
    for (int i = 0; i < 5 && fails == 0; ++i) {
      s.CcExecuteR(forced[i]);
      MustBeAlive(s, what[i]);
    }
    // And left halted with the MD-reading instruction standing in IR and
    // NOP11 down, which is where the board parked --- between two of CC's
    // own writes, with the debugger still running and nothing stopped.
    if (fails == 0) {
      for (long g = 0; g < 4000; ++g) s.Tick();
      MustBeAlive(s, "halted after CC's save");
      Restart(s, "CC-START-MACH");
    }
  }

  if (fails) {
    std::fprintf(stderr, "park: %d failure(s)\n", fails);
    return 1;
  }
  std::printf("park: %d halts at every phase and CC's own entry after one of "
              "them, and the master clock never stopped\n", halts);
  return 0;
}
