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
// grant, between the grant and the acknowledgment, after it, and with no
// cycle at all --- and the state the machine actually froze in is reported
// rather than assumed, since the write lands at a boundary and the machine
// stops where it stops.
//
// **AND A HALTED MACHINE TAKES A PREPARED CYCLE OUT.**  `MEMSTART`, `MBUSY`
// and `READ IN PROGRESS` are on the master clock (ACTL 1E20 and 1D21), so a
// cycle the last microcycle prepared goes out at the halted machine's first
// master clock, which is muir's `Rtl::start_bus_cycle` since its `c0bd5a6`.
// Every halt that found a cycle prepared must have let the bus go, and one
// that found a read of main memory prepared --- sought first, while the
// parity loop is still reading page 0 --- must have asked memory for the word
// at the address the machine held when the microcycle retired and put what
// memory gave into MD.

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
      if (!req_last_) {
        pending_ = slow_next_ > 0 ? slow_next_ : 4 + (transactions_ * 13) % 37;
        slow_next_ = 0;
      }
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
          // The read the last retired microcycle prepared, reaching memory
          // at the address the machine had for it when it retired.
          if (prepared_ == 1 && w == prep_word_index_) {
            prep_read_done_ = true;
            prep_word_ = dut_->mem_rdata;
          }
        }
        dut_->mem_done = 1;
        pending_ = -1;
      }
    } else {
      pending_ = -1;
    }
    req_last_ = dut_->mem_req != 0;

    // Whether this edge is a master clock with the cpu clock held and a
    // cycle prepared: the edge the prepared cycle goes out on.
    const bool held_start =
        dut_->memstart && root_->cadr_machine__DOT__processor__DOT__mclk_edge &&
        !root_->cadr_machine__DOT__processor__DOT__cpu_edge;
    const bool start_go = root_->cadr_machine__DOT__processor__DOT__memgo;
    // Every start, at any master clock edge, and what it met: muir's
    // `Busint::request` asserts the interface is idle, so a start must meet
    // neither an acknowledgment still up nor a cycle still running.
    const bool any_start =
        dut_->memstart && root_->cadr_machine__DOT__processor__DOT__mclk_edge &&
        start_go;
    if (any_start) {
      ++starts_;
      if (!dut_->n_memack_o) ++starts_into_ack_;
      if (dut_->mbusy_o) ++starts_overlapping_;
    }

    dut_->clk = 1;
    dut_->eval();
    ++ticks_;
    // `MBUSY` and, for a read, `READ IN PROGRESS` come up at that same edge:
    // the 74S74s at ACTL 1D21 are on `MCLK1A` beside `MEMSTART`.
    // The boot the directed leg asks for, a given number of ticks after a
    // read goes out at a held master clock: pressed for eight ticks and let
    // go, and what READ IN PROGRESS and the trap cycle then do is recorded.
    if (boot_armed_ && held_start && start_go && dut_->rdcyc_o) {
      boot_armed_ = false;
      boot_countdown_ = boot_delay_;
    }
    if (boot_countdown_ >= 0) {
      if (boot_countdown_ == 0) {
        dut_->n_boot2 = 0;
        boot_hold_ = 8;
      }
      --boot_countdown_;
    } else if (boot_hold_ > 0) {
      if (--boot_hold_ == 0) {
        dut_->n_boot2 = 1;
        release_tick_ = ticks_;
        rdip_at_release_ =
            root_->cadr_machine__DOT__processor__DOT__rd_in_progress != 0;
        rdip_fall_tick_ = -1;
        first_edge_tick_ = -1;
      }
    }
    if (release_tick_ >= 0) {
      if (rdip_fall_tick_ < 0 &&
          !root_->cadr_machine__DOT__processor__DOT__rd_in_progress)
        rdip_fall_tick_ = ticks_;
      if (first_edge_tick_ < 0 && dut_->clock_edge) first_edge_tick_ = ticks_;
    }
    if (held_start && start_go) {
      ++held_starts_;
      if (!dut_->mbusy_o ||
          (dut_->rdcyc_o &&
           !root_->cadr_machine__DOT__processor__DOT__rd_in_progress))
        ++held_starts_short_;
    }
    if (MclkEdge()) last_mclk_ = ticks_;
    if (dut_->clock_edge) {
      ++micro_;
      // What the microcycle just retired left prepared: `MEMSTART` is up
      // from here until the next master clock takes the cycle out, and
      // `RDCYC` says which way.  Read at the retiring edge because a halted
      // machine's first master clock drops `MEMSTART` a generator cycle
      // later, long before a console could look.
      prepared_ = !dut_->memstart ? 0 : (dut_->rdcyc_o ? 1 : 2);
      // `phys` is `{VMO, VMA<7:0>}` while MEMSTART is up: the prepared
      // cycle's own word address, which the memory is asked for at
      // `kMainBase` plus four a word.
      prep_word_index_ = static_cast<long>(
          root_->cadr_machine__DOT__processor__DOT__phys);
      prep_read_done_ = false;
    }
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
  // 0 if the last microcycle to retire prepared no memory cycle, 1 a read,
  // 2 a write.
  int prepared() const { return prepared_; }
  // Whether that read has reached memory since, what memory gave it, and
  // what MD holds now.
  bool prep_read_done() const { return prep_read_done_; }
  uint32_t prep_word() const { return prep_word_; }
  long prep_word_index() const { return prep_word_index_; }
  uint32_t md() const { return root_->cadr_machine__DOT__processor__DOT__md; }
  // Cycles taken out at a master clock with the cpu clock held, and how many
  // of them came up without MBUSY, or a read without READ IN PROGRESS.
  long held_starts() const { return held_starts_; }
  long starts() const { return starts_; }
  long starts_into_ack() const { return starts_into_ack_; }
  long starts_overlapping() const { return starts_overlapping_; }
  // The next memory transaction takes `ticks` to answer.
  void SlowNext(int ticks) { slow_next_ = ticks; }
  // Press the boot button `delay` ticks after the next read goes out at a
  // held master clock.
  void ArmBoot(long delay) {
    boot_armed_ = true;
    boot_delay_ = delay;
    release_tick_ = -1;
    rdip_fall_tick_ = -1;
    first_edge_tick_ = -1;
  }
  long release_tick() const { return release_tick_; }
  bool rdip_at_release() const { return rdip_at_release_; }
  long rdip_fall_tick() const { return rdip_fall_tick_; }
  long first_edge_tick() const { return first_edge_tick_; }
  uint32_t mem_word(int w) const { return mem_[w]; }
  void set_mem_word(int w, uint32_t v) { mem_[w] = v; }
  long held_starts_short() const { return held_starts_short_; }

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

  // The debug IR in three halves.
  void LoadDebugIr(uint64_t insn) {
    SpyWrite(kIrLow, static_cast<uint16_t>(insn));
    SpyWrite(kIrMed, static_cast<uint16_t>(insn >> 16));
    SpyWrite(kIrHigh, static_cast<uint16_t>(insn >> 32));
  }
  // One of CC's clocks: the write, a while, the write back to zero.
  void Clock(int clk) {
    SpyWrite(kClk, clk);
    for (long g = 0; g < 120; ++g) Tick();
    SpyWrite(kClk, 0);
    for (long g = 0; g < 120; ++g) Tick();
  }
  // CC's round for one forced instruction: loaded without executing,
  // executed, and one more noop clock "which finishes writes" --- the map
  // is written in the write phase after the store.
  void Force(uint64_t insn) {
    LoadDebugIr(insn);
    Clock(kCcNoopDebugClock);
    Clock(kStep | kIdebug);
    Clock(kCcNoopDebugClock);
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
  int prepared_ = 0;
  long prep_word_index_ = -1;
  bool prep_read_done_ = false;
  uint32_t prep_word_ = 0;
  long held_starts_ = 0, held_starts_short_ = 0;
  long starts_ = 0, starts_into_ack_ = 0, starts_overlapping_ = 0;
  int slow_next_ = 0;
  bool boot_armed_ = false;
  long boot_delay_ = 0, boot_countdown_ = -1, boot_hold_ = 0;
  long release_tick_ = -1, rdip_fall_tick_ = -1, first_edge_tick_ = -1;
  bool rdip_at_release_ = false;
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

// The rest of what the directed leg forces, `muir::isa::asm`'s encodings
// again: all ones and zero from the ALU, the byte class's deposit, and the
// functional destinations MD, VMA-START-READ, VMA-START-WRITE and
// VMA-WRITE-MAP, each of which also lands in M memory 37.
constexpr uint64_t kSetO = 017ull << 3;
constexpr uint64_t kSetZ = 0;
constexpr uint64_t kByte = 3ull << 43;
constexpr uint64_t kDpb = 3ull << 12;
constexpr uint64_t kDestMd = (030ull << 19) | (037ull << 14);
constexpr uint64_t kDestStartRead = (021ull << 19) | (037ull << 14);
constexpr uint64_t kDestStartWrite = (022ull << 19) | (037ull << 14);
constexpr uint64_t kDestWriteMap = (023ull << 19) | (037ull << 14);
uint64_t ADest(uint64_t a) { return (1ull << 25) | (a << 14); }
uint64_t MDest(uint64_t m) { return m << 14; }
// An M memory word of all ones and an A memory word of zero, so that a
// deposit of the first over the second is a field of ones and nothing else.
constexpr uint64_t kMOnes = 030, kAZero = 0102;
uint64_t Field(uint64_t pos, uint64_t bits, uint64_t dest) {
  return kByte | kDpb | (pos & 037) | ((bits - 1) << 5) | ASrc(kAZero) |
         MSrc(kMOnes) | dest;
}

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
// The second half is not a tidiness.  A halt used to stand -MEMRQ on a frozen
// MEMSTART, and the interface answers and then sits in ACKED, which it leaves
// only when -MEMRQ falls; -MEMRQ falls only when MBUSY does, and MBUSY is
// cleared by -MFINISHD, the acknowledgment delayed.  So a machine whose
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

  // ==== PART ZERO: a read of main memory, prepared and then halted on.
  //
  // The sweep below lands in the PROM's disk loop, whose reads are of the
  // disk controller's registers and are answered inside the machine.  So
  // first, while the parity loop is still reading page 0, halt until a halt
  // finds a read of main memory prepared, and hold that one to its address
  // and its word: the master clock takes it out with the machine halted,
  // memory is asked for the word at the address the machine held when the
  // microcycle retired, and MD holds what memory gave.
  int memory_read_prepared = 0, zero_tries = 0;
  while (zero_tries < 40 && memory_read_prepared == 0 && fails == 0) {
    ++zero_tries;
    for (int g = 0; g < (7 * zero_tries) % 29; ++g) s.Tick();
    Halt(s);
    for (long g = 0; g < 400; ++g) s.Tick();
    if (s.prepared() == 1 && s.prep_word_index() >= 0 &&
        s.prep_word_index() < kWindowWords) {
      ++memory_read_prepared;
      const int k = zero_tries;
      Check(!s.dut()->memstart && !s.dut()->mbusy_o && s.dut()->n_memrq_o,
            "try %d: a halt found a read of main memory prepared and the "
            "machine is standing on it, at %s", k, s.Frozen().c_str());
      Check(s.prep_read_done(),
            "try %d: the prepared read of word %lo never reached memory while "
            "the machine stood, at %s", k, s.prep_word_index(),
            s.Frozen().c_str());
      Check(s.md() == s.prep_word(),
            "try %d: MD holds %08x after the prepared read, and memory gave "
            "%08x", k, s.md(), s.prep_word());
    }
    MustBeAlive(s, "part zero");
    Restart(s, "part zero");
    for (long g = 0; g < 1000; ++g) s.Tick();
  }
  std::printf("  a read of main memory prepared at a halt after %d tries, "
              "taken out with the machine halted and landed at its own "
              "address\n", zero_tries);
  Check(memory_read_prepared > 0,
        "no halt in %d tries found a read of main memory prepared, so nothing "
        "says the master clock took one out to the right address",
        zero_tries);

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
  // that lands just after a memory instruction finds a cycle prepared, with
  // MEMSTART up.  This fabric used to freeze it there, standing -MEMRQ for
  // the whole halt and holding the interface acknowledging, and the
  // restart's first cpu edge fired MEMGO again off the frozen MEMSTART.
  // **MEMSTART is on the master clock now**, the 74S175 at ACTL 1E20 clocked
  // by MCLK1A, as muir's `Rtl::start_bus_cycle` has it: the halted machine's
  // first master clock takes the cycle out and drops MEMSTART, so the cycle
  // runs to its end while the machine stands, and -MEMRQ falls with MBUSY.
  // That is asserted here too, on every halt that found a cycle prepared.
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
    if (s.prepared() == 1) ++read_prepared;
    else if (s.prepared() == 2) ++write_prepared;
    else ++idle_halt;
    // A cycle the last microcycle prepared has gone out and finished while
    // the machine stood: MEMSTART is down, MBUSY is down and the bus is let
    // go, eight hundred ticks after the halt was written.
    if (s.prepared() != 0)
      Check(!s.dut()->memstart && !s.dut()->mbusy_o && s.dut()->n_memrq_o,
            "k=%d: a halt found a %s prepared and the machine is standing on "
            "it --- the master clock did not take it out, at %s",
            k, s.prepared() == 1 ? "read" : "write", s.Frozen().c_str());
    char who[64];
    std::snprintf(who, sizeof who, "halt k=%d", k);
    MustBeAlive(s, who);
    Restart(s, who);
    // And the machine must go on being able to be halted, which is what the
    // next turn of this loop asks.
    for (long g = 0; g < 1000; ++g) s.Tick();
    MustBeAlive(s, who);
  }
  std::printf("  %d halts: %d found a read prepared, %d a write, %d no cycle\n",
              halts, read_prepared, write_prepared, idle_halt);
  Check(read_prepared > 0,
        "no halt in the sweep found a read prepared, so the hazard was "
        "never reached and this check proves nothing");
  Check(idle_halt > 0,
        "every halt in the sweep found a memory cycle prepared, so the sweep "
        "is not a sweep");

  // ==== PART TWO: CC's own entry, on a halt that found a read prepared.
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
    if (s.prepared() == 1) break;
    Restart(s, "looking for a read prepared");
    for (long g = 0; g < 200 + 37 * tries; ++g) s.Tick();
  }
  Check(s.prepared() == 1,
        "no halt in %d tries found a read prepared for CC's entry to be run "
        "against", tries);
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

  // ==== PART THREE: the console's own reads and writes of main memory.
  //
  // Forced through the debug IR on a halted machine, so that each cycle is
  // prepared by a step and taken out at the next master clock with the cpu
  // clock held --- a place the program above only reaches by chance.
  //
  // First a write: MD is a field of ones, the map's entry for page 0 is
  // written (both levels, level 1 to 0 and level 2 to access code 3, page
  // 0), and `VMA-START-WRITE` of word 15 must leave MD in memory.  Then a
  // read of that word with the boot button pressed while the read is in
  // flight, and `(MD)` standing in IR: the trap cycle after a boot is nopped
  // by the trap and not by `-NOPA`, so `USE.MD` is up in it and it must hang
  // until READ IN PROGRESS falls --- muir's `-HANG`, `NAND(RD.IN.PROGRESS,
  // USE.MD, ...)`, with `USE.MD` gated by `-NOPA` since its `c0bd5a6`.  The
  // memory is made slow for that read, so the read is still in flight when
  // the button is let go, and the button is pressed at two points of it.
  // READ IN PROGRESS is read off the DUT, which is a property check and not
  // a comparison, and is said so here.
  constexpr uint32_t kWord = 0x3FFE0u;   // bits 5..17
  auto set_up_page0 = [&]() {
    s.Force(kAlu | kSetO | MDest(kMOnes));
    s.Force(kAlu | kSetZ | ADest(kAZero));
    s.Force(kAlu | kSetZ | kDestMd);
    s.Force(Field(22, 5, kDestWriteMap));
  };
  if (fails == 0) {
    Halt(s);
    set_up_page0();
    s.Force(Field(5, 13, kDestMd));
    s.set_mem_word(15, Poison(15));
    Check(s.mem_word(15) != kWord, "the word before the store is the word "
          "the store writes, so the store tests nothing");
    const long before = s.held_starts();
    s.Force(Field(0, 4, kDestStartWrite));
    Check(s.held_starts() > before,
          "the forced store went out at no held master clock");
    Check(s.mem_word(15) == kWord,
          "a store forced on a halted machine left %08x in memory where MD "
          "held %08x", s.mem_word(15), kWord);
    std::printf("  a store forced on a halted machine went out at a held "
                "master clock and left MD in memory\n");
  }
  int boots_in_flight = 0;
  const long kBootDelays[] = {1, 30};
  for (long d : kBootDelays) {
    if (fails) break;
    Halt(s);
    set_up_page0();
    s.set_mem_word(15, 0x13579BDFu);
    s.LoadDebugIr(Field(0, 4, kDestStartRead));
    s.Clock(kCcNoopDebugClock);
    s.LoadDebugIr(kReadMd);
    s.SlowNext(400);
    s.ArmBoot(d);
    s.SpyWrite(kClk, kStep | kIdebug);
    for (long g = 0; g < 6000 && (s.release_tick() < 0 || s.first_edge_tick() < 0); ++g)
      s.Tick();
    s.SpyWrite(kClk, kRun);
    Check(s.release_tick() >= 0, "boot %ld: the button was never pressed, "
          "so no read went out at a held master clock", d);
    if (s.release_tick() < 0) break;
    Check(s.first_edge_tick() >= 0,
          "boot %ld ticks into a read in flight: no microcycle ran in 6,000 "
          "ticks after the button was let go, at %s", d, s.Frozen().c_str());
    if (s.rdip_at_release()) {
      ++boots_in_flight;
      Check(s.rdip_fall_tick() >= 0 &&
                s.first_edge_tick() >= s.rdip_fall_tick(),
            "boot %ld: the trap cycle, standing on (MD), ran at tick %ld with "
            "READ IN PROGRESS still up until %ld --- USE.MD was nopped by the "
            "trap, where -NOPA does not include it", d, s.first_edge_tick(),
            s.rdip_fall_tick());
    }
    std::printf("  boot %ld ticks into a slow read: READ IN PROGRESS %s at the "
                "release, fell %ld ticks after it, and the trap cycle ran %ld "
                "ticks after it\n", d, s.rdip_at_release() ? "up" : "down",
                s.rdip_fall_tick() - s.release_tick(),
                s.first_edge_tick() - s.release_tick());
    for (long g = 0; g < 4000; ++g) s.Tick();
  }
  Check(boots_in_flight > 0,
        "no boot was let go with a read still in flight, so the trap cycle's "
        "USE.MD was never asked anything");

  std::printf("  %ld starts, %ld of them into an acknowledgment still up and "
              "%ld into a cycle still running\n", s.starts(),
              s.starts_into_ack(), s.starts_overlapping());
  Check(s.starts() > 0 && s.starts_into_ack() == 0 &&
            s.starts_overlapping() == 0,
        "%ld of %ld starts met an acknowledgment still up and %ld a cycle "
        "still running, the state muir's Busint::request asserts it never "
        "enters", s.starts_into_ack(), s.starts(), s.starts_overlapping());

  std::printf("  %ld cycles taken out at a master clock with the cpu clock "
              "held, every one with MBUSY up, and a read's with READ IN "
              "PROGRESS\n", s.held_starts());
  Check(s.held_starts() > 0 && s.held_starts_short() == 0,
        "%ld cycles taken out with the cpu clock held, %ld of them without "
        "MBUSY or, for a read, READ IN PROGRESS", s.held_starts(),
        s.held_starts_short());

  if (fails) {
    std::fprintf(stderr, "park: %d failure(s)\n", fails);
    return 1;
  }
  std::printf("park: %d halts at every phase and CC's own entry after one of "
              "them, and the master clock never stopped\n", halts);
  return 0;
}
