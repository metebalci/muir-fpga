// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The clock control register against muir: halting, single-stepping, and
// forcing a microinstruction in through the debug IR.
//
// **WHAT IS HELD TO muir, AND WHERE THE REFERENCE IS.**  `build/sstep.golden`,
// out of `golden/src/sstep.rs`, which runs muir's own `rtl` engine on MIT's
// boot PROM and scripts the register the way CC does.  Every compared column
// is a word `Engine::spy_read` answered, so the seam here is the diagnostic
// bus and not a field reached into: the testbench sets `spy_eadr` and reads
// `spy_rdata`, which is what a console has.
//
//   the step        `MACHRUN`'s first term, `SSTEP AND -SSDONE`, the 9S42 at
//                   OLORD1 1A15 over the two flip flops of the 74S174 at
//                   1A10.  Raising `STEP` runs ONE microcycle --- MIT's own
//                   "raising step clocks the machine once" --- and it must be
//                   lowered before the next.  The trace holds `STEP` up over
//                   six master clocks for exactly that reason: a fabric whose
//                   step is a level rather than an edge runs six microcycles
//                   there and the `cycles` column says so.
//
//   `SSDONE`        `FLAG-1` bit 9, which is the board's own witness that the
//                   step it was asked for has run.  It rises one master clock
//                   behind `SSTEP` and falls two behind the write.
//
//   the debug IR    `IDEBUG` puts the six 74S374s on page DEBUG on the I bus
//                   in place of the control store, and `NOP11` stops the
//                   instruction there having any effect.  So one noop debug
//                   clock loads `IR` and shows the console the operands and
//                   the result on the A, M and O buses without executing it,
//                   which is `CC-EXECUTE` and is how CC reads a scratchpad.
//
//   `LDSTAT`        the statistics counter loads from `IWR<31:0>`.
//
// **WHY `cadr_microcycle` DIRECTLY AND NOT THE COMPOSED MACHINE.**  The five
// bits are ports here, as `run`, `promdisable`, `errstop`, `stathenb` and the
// speed bits already were: the register that holds them is
// `cadr_spy_registers.sv` and what lands them at the machine's next look is
// its own, held by `build/console.pass`.  What this check holds is what the
// PROCESSOR does with them once they are there, which is the half no trace
// could reach before.  Driving them directly is also what makes the
// stimulus muir's own: `Machine::spy_write` takes effect at once, and a check
// that went through the register block would be comparing the block's landing
// rule at the same time as the gate.
//
// **THE SAMPLING POINT, AND WHY IT IS NOT `cadr_microcycle_tb.cpp`'s.**  That
// testbench compares the state held OVER the microcycle now ending, because
// its reference is a row per microcycle and the row describes the cycle that
// ran.  This one's rows are what a CONSOLE READS between master clocks ---
// `Engine::spy_read` after `Engine::step` --- so the sample is the state the
// edge has just produced: `PC` advanced, `IR` holding the instruction the
// edge loaded, and the A, M and O buses showing THAT instruction's operands
// and result, which is exactly what makes `CC-EXECUTE` work.
//
// `mclk` is `mclk_edge` unregistered and stands high one tick BEFORE the
// registers move, so the edge is taken a tick late here --- which makes the
// trigger exactly `clock_edge`'s with the `machrun` gate taken off, and the
// gate coming off is the whole point: a halted master clock is a row of this
// trace and retires no microcycle.  The sample is then taken in that same
// tick, after the registers have moved.
//
// **THE STIMULUS IS TWO COLUMNS AND NOTHING ELSE IS DRIVEN.**  The script
// never reaches a memory cycle --- the boot PROM's first is at microcycle
// 536,303 and this runs around 2,000 --- so `-MEMACK`, `-MEMGRANT` and
// `-LOADMD` stand idle and `rdata` is never taken.  A row that stalled would
// be several master clocks where every other row is one, and the run says so
// rather than drifting: the interval between edges is compared against muir's
// own nanoseconds.

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "Vcadr_microcycle.h"
#include "verilated.h"

namespace {

// `cadr_phase_gen.sv`'s `TICK_NS`: MIT's 5 ns grid, which is what every tick
// count in the machine is a count of.  It is not the board's clock period.
constexpr int kTickNs = 5;

// The clock control register's five bits, `spy::ClockControl`'s order and
// MIT's `ir.bits`, whose numbers are OCTAL: 1 Run, 2 Step, 4 NOP, 10 IDEBUG,
// 20 LDSTAT.
constexpr uint16_t kRun = 1u << 0;
constexpr uint16_t kStep = 1u << 1;
constexpr uint16_t kNop11 = 1u << 2;
constexpr uint16_t kIdebug = 1u << 3;
constexpr uint16_t kLdstat = 1u << 4;

struct Row {
  uint16_t clk;
  uint64_t dbgir;
  uint64_t cycles;
  uint16_t pc;
  uint64_t ir;
  uint16_t flag1, flag2;
  uint32_t ob, a, m, st;
  uint64_t ns;
  char what[32];
};

bool ParseRow(const char *line, Row &r) {
  return std::sscanf(line,
                     "%4" SCNx16 " %12" SCNx64 " %" SCNx64 " %4" SCNx16
                     " %12" SCNx64 " %4" SCNx16 " %4" SCNx16 " %8" SCNx32
                     " %8" SCNx32 " %8" SCNx32 " %8" SCNx32 " %" SCNx64 " %31s",
                     &r.clk, &r.dbgir, &r.cycles, &r.pc, &r.ir, &r.flag1,
                     &r.flag2, &r.ob, &r.a, &r.m, &r.st, &r.ns, r.what) == 13;
}

// What a console reads back over the diagnostic bus, sampled every tick so
// that an edge is compared against the master clock before it and not against
// what the edge has just produced.
struct Sample {
  uint64_t ir;
  uint16_t pc, flag1, flag2;
  uint32_t ob, a, m, st;
};

int bad = 0;

int Fail(size_t row, const Row &r, const char *what, uint64_t got,
         uint64_t want) {
  if (bad < 20)
    std::fprintf(stderr,
                 "FAIL: row %zu (%s, clk %04" PRIx16 "): %s is %" PRIx64
                 ", the reference says %" PRIx64 "\n",
                 row, r.what, r.clk, what, got, want);
  return 1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <sstep.golden>\n", argv[0]);
    return 2;
  }
  const char *path = argv[1];
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "FAIL: cannot open %s: %s\n", path,
                 std::strerror(errno));
    return 2;
  }

  // The whole trace, so the run knows how many rows it owes.
  std::vector<Row> rows;
  {
    char line[512];
    while (std::fgets(line, sizeof line, f)) {
      if (line[0] == '#' || line[0] == '\n') continue;
      Row r;
      if (!ParseRow(line, r)) {
        std::fprintf(stderr, "FAIL: cannot parse %s at row %zu: %s", path,
                     rows.size(), line);
        return 2;
      }
      rows.push_back(r);
    }
  }
  std::fclose(f);
  if (rows.empty()) {
    std::fprintf(stderr, "FAIL: %s has no rows\n", path);
    return 2;
  }

  auto *dut = new Vcadr_microcycle;
  // `-BOOT` is a pulled-up line and nothing on this check presses it.
  // **Active low, so an undriven input would hold the machine at the boot
  // trap for ever**, which is the loud failure this line exists to avoid.
  dut->n_boot = 1;
  dut->clk = 0;
  dut->rst = 1;
  dut->n_memack = 1;
  dut->n_memgrant = 1;
  dut->n_loadmd = 1;
  dut->rdata = 0;
  dut->sintr = 0;
  dut->ro_addr = 0;
  dut->promdisable = 0;
  dut->errstop = 0;
  dut->stathenb = 0;
  dut->mode_speed = 0;
  // The machine comes up running, as a boot button just released leaves it:
  // the warm-up rows of the trace are muir free-running from `Engine::boot`.
  dut->run = 1;
  dut->step = 0;
  dut->nop11 = 0;
  dut->idebug = 0;
  dut->ldstat = 0;
  dut->debug_ir = 0;
  dut->spy_eadr = 0;
  dut->eval();

  // A console's read of the sixteen registers, through the mux the console
  // actually uses.  Register 3 has no read select and is not read here; the
  // rest are the trace's columns.
  auto spy = [&](uint8_t eadr) {
    dut->spy_eadr = eadr;
    dut->eval();
    return static_cast<uint16_t>(dut->spy_rdata);
  };
  auto take = [&]() {
    Sample s;
    s.ir = static_cast<uint64_t>(spy(2)) << 32 |
           static_cast<uint64_t>(spy(1)) << 16 | spy(0);
    s.pc = spy(5);
    s.ob = static_cast<uint32_t>(spy(7)) << 16 | spy(6);
    s.flag1 = spy(8);
    s.flag2 = spy(9);
    s.m = static_cast<uint32_t>(spy(11)) << 16 | spy(10);
    s.a = static_cast<uint32_t>(spy(13)) << 16 | spy(12);
    s.st = static_cast<uint32_t>(spy(15)) << 16 | spy(14);
    return s;
  };

  // The clock control register and the debug IR, as `Machine::spy_write`
  // leaves them: five bits of one word and forty-eight of three.
  auto drive = [&](const Row &r) {
    dut->run = (r.clk & kRun) ? 1 : 0;
    dut->step = (r.clk & kStep) ? 1 : 0;
    dut->nop11 = (r.clk & kNop11) ? 1 : 0;
    dut->idebug = (r.clk & kIdebug) ? 1 : 0;
    dut->ldstat = (r.clk & kLdstat) ? 1 : 0;
    dut->debug_ir = r.dbgir;
  };

  // Long enough for the warm-up, the script and its halted master clocks: the
  // trace's own `cycles` column says where the script starts.
  const uint64_t first_cycle = rows.front().cycles;
  const long kMaxTicks =
      static_cast<long>(first_cycle + rows.size() + 64) * 96 + 1024;

  uint64_t cycles = 0;   // master clocks that retired a microcycle
  bool mclk_prev = false;
  long last_edge = -1;
  size_t k = 0;          // the next row whose stimulus is to be driven
  size_t compared = 0;
  bool scripting = false;

  // The row whose edge has passed and whose answer is still settling.
  bool have_pending = false;
  size_t pending_k = 0;
  uint64_t pending_cycles = 0, pending_len = 0;

  for (long t = 0; t < kMaxTicks && compared < rows.size(); ++t) {
    if (t == 4) dut->rst = 0;

    dut->clk = 1;
    dut->eval();

    // `mclk` stands high in the tick BEFORE the registers move, so it names
    // two different instants a tick apart, and the check needs both: `edge`
    // is the tick the registers moved in --- which is `clock_edge`'s own tick
    // with the `machrun` gate taken off --- and `last_tick` is the end of the
    // master clock now running, the settled instant before the next edge.
    const bool edge = mclk_prev;
    const bool last_tick = dut->mclk != 0;
    mclk_prev = last_tick;
    if (dut->clock_edge) ++cycles;

    if (edge) {
      if (!scripting) {
        // The trace's first row is the master clock that takes `cycles` TO
        // `first_cycle`, so the script is armed at the edge before it.
        if (cycles + 1 == first_cycle) {
          scripting = true;
          last_edge = t;
        }
      } else {
        // `CYCLES` and the master clock's length are made here, at the row's
        // own edge, and carried to where the row is compared.
        if (k > 0) {
          have_pending = true;
          pending_k = k - 1;
          pending_cycles = cycles;
          pending_len = static_cast<uint64_t>(t - last_edge) * kTickNs;
        }
        last_edge = t;
      }
    }

    if (last_tick && scripting) {
      // **A ROW IS READ AT THE END OF ITS OWN MASTER CLOCK, WITH ITS OWN
      // STIMULUS STILL STANDING.**  Two things forbid any earlier instant.
      // The datapath has to have settled: `Rtl::spy_read` recomputes the
      // whole read phase from the registers as they stand, where the fabric
      // has ALATCH and MLATCH to follow, so a sample taken a tick after the
      // edge reads the previous instruction's operands.  And `NOP11` and
      // `IDEBUG` are combinational into `NOP` and the I bus, so a sample
      // taken after the NEXT row's stimulus had been applied would read a
      // mixture of the two --- which is muir's order exactly: `step`, then
      // `spy_read`, and only then the next `spy_write`.
      if (have_pending) {
        const Sample now = take();
        const Row &r = rows[pending_k];

        // **THE CLAIM THE WHOLE CHECK IS FOR.**  `CYCLES` counts the master
        // clocks that retired a microcycle, which is the only thing that says
        // whether a step stepped.  A fabric that drops `STEP` stands still
        // where the reference moves; one that takes it as a level runs a
        // microcycle every master clock it is up, and the six rows with
        // `STEP` held say so.
        if (pending_cycles != r.cycles)
          bad += Fail(pending_k, r, "CYCLES", pending_cycles, r.cycles);
        if (now.pc != r.pc) bad += Fail(pending_k, r, "PC", now.pc, r.pc);
        if (now.ir != r.ir) bad += Fail(pending_k, r, "IR", now.ir, r.ir);
        // `FLAG-1` carries `SRUN` at bit 8 and `SSDONE` at bit 9, the two a
        // console reads to know what the machine is doing.
        if (now.flag1 != r.flag1)
          bad += Fail(pending_k, r, "FLAG-1", now.flag1, r.flag1);
        // `FLAG-2` bit 4 is `NOP`, which is what `NOP11` makes.
        if (now.flag2 != r.flag2)
          bad += Fail(pending_k, r, "FLAG-2", now.flag2, r.flag2);
        if (now.ob != r.ob) bad += Fail(pending_k, r, "OB", now.ob, r.ob);
        if (now.a != r.a) bad += Fail(pending_k, r, "the A bus", now.a, r.a);
        if (now.m != r.m) bad += Fail(pending_k, r, "the M bus", now.m, r.m);
        if (now.st != r.st) bad += Fail(pending_k, r, "ST", now.st, r.st);

        // The master clock's own length.  Nothing here stalls, so every row
        // is one generator cycle, and a row that is not says the script has
        // reached a memory cycle it was written to stay clear of.
        if (pending_len != r.ns)
          bad += Fail(pending_k, r, "the master clock's length", pending_len,
                      r.ns);

        have_pending = false;
        ++compared;
      }

      // And the next row's stimulus goes up now, a tick before the edge that
      // samples it, which is where muir's next `spy_write` falls.
      if (k < rows.size()) {
        drive(rows[k]);
        ++k;
      }

      if (bad >= 20) {
        std::fprintf(stderr, "stopping after %d mismatches\n", bad);
        break;
      }
    }

    dut->clk = 0;
    dut->eval();
  }

  dut->final();
  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %zu of %zu rows\n", bad, k,
                 rows.size());
    return 1;
  }
  if (compared != rows.size()) {
    std::fprintf(stderr,
                 "FAIL: the run stopped after %zu of %zu rows --- the script's "
                 "first microcycle is %" PRIu64 " and the machine reached %" PRIu64
                 "\n",
                 compared, rows.size(), first_cycle, cycles);
    return 1;
  }

  // What the run exercised, counted rather than claimed.
  size_t halted = 0, stepping = 0, idebug = 0, nopped = 0, ldstat = 0;
  size_t retired_under_step = 0;
  uint64_t last_cycles = rows.front().cycles;
  for (const Row &r : rows) {
    if (r.clk == 0) ++halted;
    if (r.clk & kStep) ++stepping;
    if (r.clk & kIdebug) ++idebug;
    if (r.clk & kNop11) ++nopped;
    if (r.clk & kLdstat) ++ldstat;
    if ((r.clk & kStep) && r.cycles != last_cycles) ++retired_under_step;
    last_cycles = r.cycles;
  }
  // **A CHECK THAT CANNOT SEE A STEP MUST NOT PASS.**  If no row retired a
  // microcycle under `STEP` the trace has stopped exercising the thing, and
  // every column would still agree with a fabric that has no step at all.
  if (retired_under_step == 0) {
    std::fprintf(stderr,
                 "FAIL: not one row retired a microcycle with STEP up, so the "
                 "trace tests no step at all\n");
    return 1;
  }
  if (idebug == 0 || ldstat == 0) {
    std::fprintf(stderr,
                 "FAIL: the trace has %zu rows under IDEBUG and %zu under "
                 "LDSTAT; both must be exercised\n",
                 idebug, ldstat);
    return 1;
  }

  std::printf(
      "ok: the clock control register agrees with muir over %zu master clocks\n"
      "    %zu halted, %zu with STEP up of which %zu retired a microcycle\n"
      "    %zu under IDEBUG, %zu under NOP11, %zu under LDSTAT\n"
      "    compared each row: CYCLES, PC, IR, FLAG-1 (SRUN and SSDONE),\n"
      "    FLAG-2, OB, the A and M buses, ST, and the master clock's length\n"
      "    every column read through spy_eadr/spy_rdata, which is the\n"
      "    diagnostic bus and is what a console has\n",
      rows.size(), halted, stepping, retired_under_step, idebug, nopped,
      ldstat);
  return 0;
}
