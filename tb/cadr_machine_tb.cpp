// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Drives rtl/machine/cadr_machine.sv --- the processor and the memory path joined by
// the cables --- from muir's own trace, and compares every microcycle.  The trace is written by golden/src/rtl.rs out of muir's `rtl`
// engine running MIT's boot PROM: a real program, not a scripted stimulus.
//
// One row is one microcycle.  The DUT runs on its own 200 MHz clock and says
// when a microcycle ended, on `clock_edge`; the values compared are the ones
// standing *before* that edge, which is the read phase the row describes ---
// `Rtl::signals` is "recorded in the read phase, where the sources drive and
// the ALU result is up but nothing has been written back".
//
// WHAT IS STIMULUS.  There is no map yet, so what comes out of the trace
// rather than out of the DUT is `md` and `vma`, `vmaok` off the map's
// permission bits, the word a SRCMAP puts on MF, the
// dispatch memory's word, and the console's registers.  The bus interface is
// here too, as its far end: this testbench answers -MEMRQ with -MEMGRANT and
// -MEMACK at the instants muir's own interface answered them.
// `rtl/machine/cadr_busint_xbus.sv` is the real thing and has a check of its own.  Every one leaves with
// a later slice.  They are counted and printed, so what this check is still
// being told rather than checking is on its own output.
//
// **AND ONE OF THEM HAS LEFT.**  The Xbus devices used to be answered from
// the trace --- 16,951 cycles of this program's 17,466, the disk controller's
// four registers being all it touches --- and `rtl/machine/cadr_disk_controller.sv`
// answers them now, with `device_ack` driven low here and never raised.  So
// `md` on 11,301 of those rows is the fabric's own status word and the trace
// is the reference for it rather than the source of it.  That is what a slice
// landing looks like from this side: a drive line deleted, not commented out.
//
// **AND SO HAS `sintr`.**  -XBUS.INTR is made inside `cadr_machine` now ---
// the disk controller's request ORed with the display's vertical interrupt,
// one gate before the 74S175 at LCC 3E12 --- and comes back out as
// `sintr_o`.  The trace's `sintr` column is `Machine::xbus_interrupt()`, the
// same OR, and it is COMPARED here rather than driven.  Same slice, same
// shape: the line that drove it is deleted.
//
// `mf_map` is the one that is frankly circular: a SRCMAP is reached **once**
// in 600,000 microcycles and its word is taken from the trace's own M column,
// so on that single row M checks nothing.  One row is not a check of a map
// under any amount of cleverness, and the map is a later slice; the count is
// printed so the circularity is visible rather than buried.
//
// WHAT IS CHECKED.  PC, IR, LPC, OPC, ST, the A and M buses, the ALU, R, OB,
// Q, DC, LC, JCOND, and the four sequencing flags NOP, PCS1, PCS0 and
// IWRITED --- plus the length of every microcycle in 200 MHz ticks.  PC goes
// through the fabric's own stack on a POPJ.
//
// **The stall is no longer subtracted.**  VCTL1 decides -WAIT and -HANG for
// itself now, so the whole interval between one microcycle boundary and the
// next is the fabric's own answer: 6,912 waits and 11,404 hangs over the run,
// 2,198,700 ns of held clock, and every one of them has to land where muir
// lands it.  That is the strongest single column in this check.
//
// WHAT THE CHECKED SIGNALS ARE WORTH, measured by mutation rather than
// assumed.  The A bus is the strong one: 96,192 distinct values over the run,
// and it catches a wrong write address, wrong write data, and the ACTL
// pass-around inverted or removed.  RETA's mux, WPC and the stack's push
// pass-around are each caught through PC on the 16,384 POPJs.  Against that:
//
//   - LC is **zero on every one of the 600,000 rows**.  The boot PROM never
//     runs macrocode, so the location counter never moves and its check is
//     vacuous.  Asserted below, so a trace that does move it re-opens this.
//   - The stack's RAM and pointer are **never read**.  Every push here is
//     popped by the very next microcycle, which takes SPCWPASS --- the word
//     standing on the SPC bus --- and not the 82S21s' output.  Moving SPCPTR
//     by two, or never writing the RAM at all, survives this check.
//   - The ALATCH/MLATCH gating is not distinguished: making the latches
//     transparent through the write phase survives, because the one overlap
//     it could show --- a write to the address being read --- is exactly what
//     the pass-around covers.  It is right for synthesis, not for this trace.
//   - The WADR/AADR comparator's top bit is never the one that differs, so a
//     nine-bit compare survives a ten-bit one.
//   - OB's two shift selects are never taken: `OSEL` is only ever 0 (MO) or
//     1 (ALU), so `ALU >> 1` and `ALU << 1` with Q<31> shifted in are built
//     and unexercised.  Replacing `ALU >> 1` with `ALU` survives.
//   - Q is loaded five times and **never shifted**: `QS<1:0>` is 0 on 599,995
//     microcycles and 3 on the other five, so the 74S194s' shift paths and
//     every multiply and divide step with them are unexercised.
//   - AEQM widened from the low 32 slices to all 33 survives, so the
//     open-collector chain's width is not pinned down here either.
//   - Jump condition 5, `PAGE.FAULT OR INTERRUPT`, is never selected, and
//     condition 2 is selected once.
//   - Two of -WAIT's three terms never fire.  `USE.MD AND MBUSY AND
//     -MEMGRANT` --- MIT's "do not hang when this line is high", the gate
//     that keeps a hang from being taken before the grant --- is zero over
//     the run, and so is `LCINC AND NEEDFETCH AND MBUSY.SYNC`.  Dropping
//     either survives.  The first term carries the whole stall path here.
//   - **RDCYC and WRCYC being taken from the wrong instruction survives**,
//     and `src/rtl.rs` says in advance that it would: "taking it from the
//     instruction standing one microcycle later is the trap: that instruction
//     is the page-fault check MIT puts after every store, so MEMWR reads
//     false and every write cycle is performed as a read.  Nothing catches it
//     early --- the only thing the boot PROM writes before the disk is page
//     0, which it fills with the zeros already there."  Measured here from
//     the other side, and it holds.
//
// Against that, the ALU array is genuinely exercised: 21 of its 32
// function-and-mode combinations are reached, the sign-extending ninth slice
// is caught if removed (JCOND goes wrong at microcycle 5,202), the rotate is
// caught if reversed, the mask is caught if its two ends are swapped or if
// MSKL loses IR<9:5>, and swapping one entry of either half of the 74S181
// function table is caught within a few thousand microcycles.
//
// The stall path itself is caught where it is exercised: dropping -WAIT's
// first term, letting -HANG be taken before -WAIT, or clearing MBUSY one tick
// late are each caught at the boot PROM's first stalled microcycle.
//
// And the one-state-early trap on page DSPCTL is caught: the 25S07s take
// IR<41:32> of the DISPATCH *itself*, the word standing before the edge, and
// reading the newly loaded IR there instead is caught at microcycle 525,527.
//
// WHAT THIS PROGRAM DOES NOT EXERCISE, asserted here rather than assumed, so
// that a trace which reaches further re-opens each claim: every DISPATCH in
// it is a DISPWR, so the dispatch memory is written and never read and
// `dr`/`dp`/`dn`/`dpc` do not matter; it never halts; it never sets IR<46>,
// so the statistics counter never counts; it never sets PROMDISABLE, so it
// never runs the microcode it loads; and it runs at extra slow throughout,
// where both taps of the 74S151 are -TPR160 --- so ILONG changes nothing and
// the -NOPA gate on it at FLAG 3E07 is unchecked.  The scripted trace behind
// cadr_phase_gen.sv is what covers the seven taps.
//
// The control store comes up all ones rather than zero, and that is what
// makes the 16,384 words the boot PROM writes worth writing: every one of
// them is zero, so with the RAM coming up zero a write that never happened
// reads back exactly like one that did.  rtl/machine/cadr_microcycle.sv says so at
// the array.

#include <algorithm>
#include <cerrno>
#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <vector>

#include "Vcadr_machine.h"
#include "verilated.h"

namespace {

// Five nanoseconds, the master clock's period.
constexpr int kTickNs = 5;

// "a write is acknowledged at once, a read XBUS_ACK_NS later, which is the
// 60 ns tap of the TD100 at REQLM 0C09 deskewing the word into MD".
constexpr int kXbusAckNs = 60;

// The trace's columns, in the order golden/src/rtl.rs prints them.
enum Col {
  kCycle, kPc, kIr, kQ, kA, kM, kAlu, kR, kOb, kDc, kOpc, kSt, kLc,
  kWmapd, kDestspcd, kIwrited, kImodd, kPdlwrited, kSpushd, kNop, kNVmaok,
  kJcond, kPcs1, kPcs0, kSrun,
  kLpc, kMd, kVma, kPromdis, kErrstop, kStathenb, kSpeed1, kSpeed0,
  kStall, kHalted, kBus, kAck, kGnt, kSintr, kNs,
  kColumns
};

struct Row {
  uint64_t v[kColumns];
};

// One row of hexadecimal columns. Returns false if the count is wrong.
bool ParseRow(const char *line, Row &r) {
  const char *p = line;
  for (int i = 0; i < kColumns; ++i) {
    char *end = nullptr;
    r.v[i] = std::strtoull(p, &end, 16);
    if (end == p) return false;
    p = end;
  }
  return true;
}

// DESTMDR: the instruction stores OB into MD itself, at the edge.
bool RowDestmdr(const Row &r) {
  const uint64_t cls = (r.v[kIr] >> 43) & 3;
  const bool dest = !r.v[kNop] && (cls == 0 || cls == 3);
  return dest && !((r.v[kIr] >> 25) & 1) && ((r.v[kIr] >> 23) & 1) &&
         ((r.v[kIr] >> 22) & 1);
}

int Fail(const Row &r, const char *what, uint64_t got, uint64_t want) {
  std::fprintf(stderr,
               "microcycle %" PRIu64 " (PC %" PRIo64 "): %s is %" PRIx64
               ", reference says %" PRIx64 "\n"
               "  IR %" PRIo64 "  NOP %" PRIu64 "  JCOND %" PRIu64
               "  PCS %" PRIu64 "%" PRIu64 "\n",
               r.v[kCycle], r.v[kPc], what, got, want, r.v[kIr], r.v[kNop],
               r.v[kJcond], r.v[kPcs1], r.v[kPcs0]);
  return 1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  const char *path = (argc > 1) ? argv[1] : "build/rtl.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s: %s\n", path, std::strerror(errno));
    return 2;
  }

  // THE TRACE IS STREAMED, NOT HELD.  The pack trace is 2.2 million
  // microcycles and 297 MB; holding it as parsed rows is 686 MB of a machine
  // three sessions are building on.  So it is read twice instead: once for
  // the acknowledgement times, which are the only thing needing to be known
  // before their row, and once to drive the DUT.
  bool pack_trace = false;
  std::vector<uint64_t> ack_for;
  std::vector<uint64_t> rdata_for;
  std::vector<uint64_t> md_at_row;
  std::vector<bool> arbitrated;
  long unibus_cycles = 0;
  size_t total_rows = 0;
  {
    char line[512];
    std::vector<uint64_t> bus_at;   // row indices that start a bus cycle
    std::vector<uint64_t> acks;     // and every row's ack column
    std::vector<uint64_t> mds;      // every row's md column
    std::vector<char> stalled_srcmd;

    while (std::fgets(line, sizeof line, f)) {
      if (line[0] == '#') {
        if (std::strstr(line, "rtl_sys.rs")) pack_trace = true;
        continue;
      }
      if (line[0] == '\n') continue;
      Row r;
      if (!ParseRow(line, r)) {
        std::fprintf(stderr, "%s: row %zu has the wrong column count\n", path,
                     total_rows);
        return 2;
      }
      acks.push_back(r.v[kAck]);
      // What `-LOADMD` should put in MD if it strobes during this
      // microcycle, taken from the trace and keyed by the row rather than
      // queued.
      //
      // A QUEUE OF THE WORDS MD WAS SEEN TO TAKE DOES NOT WORK, and the way
      // it fails is worth the comment: a read whose word equals what MD
      // already holds moves nothing, so it is invisible as a change, and the
      // queue then hands the *next* read a later cycle's word. Measured ---
      // it goes wrong at microcycle 536,309 of the boot PROM, where the
      // second read returns the zero MD already had.
      //
      // Keyed by row, the rule is the one `golden/src/trace.rs` already
      // needed for the `md` column itself: a hang loads MD *before* its own
      // microcycle's read phase, so that row's own column is the word; a
      // -WAIT and an unstalled cycle load it at the edge, so the next row's
      // is. A row that both reads MD and writes it needs no special case:
      // `DESTMDR` lands at the edge and overwrites whatever the bus put
      // there, in the fabric as in `Rtl::clock_edge`, so on an unstalled row
      // the loaded word is discarded either way.
      mds.push_back(r.v[kMd]);
      stalled_srcmd.push_back(r.v[kStall] != 0);
      if (r.v[kBus]) bus_at.push_back(total_rows);
      ++total_rows;
    }
    // For each microcycle that starts a bus cycle, when -MEMACK is due. The
    // interface usually knows at the boundary; a cycle that has to arbitrate
    // for the Unibus first is granted, acknowledged and finished inside a
    // later microcycle's stall, so its answer appears on a later row.
    md_at_row = mds;
    rdata_for.assign(total_rows, 0);
    for (size_t i = 0; i < total_rows; ++i) {
      rdata_for[i] = stalled_srcmd[i] ? mds[i]
                                      : (i + 1 < total_rows ? mds[i + 1] : mds[i]);
    }
    ack_for.assign(total_rows, 0);
    arbitrated.assign(total_rows, false);
    for (uint64_t i : bus_at) {
      size_t j = i;
      while (j < acks.size() && acks[j] == 0) ++j;
      ack_for[i] = (j < acks.size()) ? acks[j] : 0;
      // A cycle whose answer is not known at the boundary it started on had
      // to arbitrate for the Unibus first. THE FABRIC'S BUS INTERFACE HAS NO
      // UNIBUS PATH --- `cadr_busint_xbus.sv` is the Xbus half --- so neither
      // this testbench's model of it nor the processor behind it can place
      // that grant, and the microcycles the arbitration stalls are exempt
      // from the length check. They are counted, and the count is held down,
      // so this cannot quietly become the rule.
      if (j != i) {
        ++unibus_cycles;
        for (size_t x = i; x <= j && x < total_rows; ++x) arbitrated[x] = true;
      }
    }
  }

  // A trace the Makefile could not make says so in one comment line and
  // carries no microcycles. That is not a failure: the System release is
  // fetched material and a checkout without it still runs every check that
  // matters.
  if (total_rows == 0) {
    std::printf("skipped: %s carries no microcycles\n", path);
    std::fclose(f);
    return 0;
  }
  if (total_rows < 2) {
    std::fprintf(stderr, "FAIL: %s carries %zu microcycles\n", path,
                 total_rows);
    return 1;
  }
  std::rewind(f);

  auto *dut = new Vcadr_machine;
  dut->clk = 0;
  dut->rst = 1;
  dut->boards = 32;      // Machine::new: MAIN_WORDS >> 16
  dut->mem_done = 0;
  dut->mem_rdata = 0;
  // NOTHING OUTSIDE THE MACHINE ANSWERS AN XBUS DEVICE, and this is the whole
  // of it: `device_ack` is driven low here and never again.  The display and
  // the I/O board are not built and this program does not touch them; the
  // disk controller is inside.
  dut->device_ack = 0;
  dut->device_rdata = 0;
  // Verilator records the previous value of a clock at eval time, so the
  // first eval has to happen with clk low or the first posedge is not one.
  dut->eval();

  // Reads the next data row, skipping comments. False at end of file.
  auto read_next = [&](Row &r) {
    char line[512];
    while (std::fgets(line, sizeof line, f)) {
      if (line[0] == '#' || line[0] == '\n') continue;
      return ParseRow(line, r);
    }
    return false;
  };

  // Present a row's stimulus: what the memory path would be driving over that
  // microcycle, and what the console would be holding.
  // **`device_rdata` NO LONGER CARRIES THE WORD, AND THAT IS THE POINT OF THE
  // SLICE.**  It used to be `rdata_for[row]`, the same column `mem_rdata`
  // gets, so all 16,951 device cycles --- the boot PROM's disk polls --- were
  // answered with muir's own word.  `rtl/machine/cadr_disk_controller.sv` answers
  // them now, and a line that went on handing back the right word would leave
  // that module unchecked: CLAUDE.md's `md` trap verbatim, where a driven
  // input that became an output kept being driven and both processor checks
  // went green with MD unchecked.  What goes on the seam instead is the
  // complement.
  auto drive = [&](const Row &r, size_t row) {
    // **`sintr` WAS DRIVEN HERE AND THE LINE IS GONE.**  -XBUS.INTR is the
    // machine's own now: `cadr_disk_controller.sv` puts the disk's request on
    // it, `cadr_tv.sv` the display's vertical interrupt, and `cadr_machine.sv`
    // ORs the two where the backplane does.  The column is COMPARED below
    // instead, against `sintr_o`.  Deleted rather than left unused, which is
    // CLAUDE.md's `md` trap word for word: Verilator lets a testbench write an
    // output, so a drive line that stayed would have gone on supplying the
    // right answer and the join would have been unchecked with every check
    // green.
    dut->mem_rdata = static_cast<uint32_t>(rdata_for[row]);
    // **POISON ON THE SEAM, ALWAYS, AND NEVER DATA.**  `device_rdata` is what
    // `cadr_machine.sv` puts on MEM<31:0> when no slave inside it is driving
    // them, which is every device WRITE --- no slave drives the data lines on
    // a write --- and every device READ the disk controller fails to answer.
    // Holding the complement of the word MD should hold makes both of those
    // loud: a processor whose -LOADMD has lost its RDCYC gate takes poison on
    // a write, and a register block that stops driving reads poison instead
    // of the word it happened to hand back last.  CLAUDE.md's rule is that a
    // stimulus that poisons cannot move with the bug, and this one cannot: it
    // is the trace's own column, complemented, keyed by the row.
    dut->device_rdata = ~static_cast<uint32_t>(rdata_for[row]);
  };

  // What the DUT held over the microcycle now ending: sampled every tick, so
  // that the edge is compared against the read phase before it and not
  // against the values the edge has just produced.
  struct Sample {
    uint64_t pc, ir, lpc, opc, st, a, m, alu, r, ob, q, dc, lc, vma, md, vmaok,
        jcond, nop, pcs1, pcs0, iwrited, promdis, sintr;
  };
  auto take = [&]() {
    return Sample{dut->pc,  dut->ir,    dut->lpc, dut->opc,   dut->st,
                  dut->a,   dut->m,     dut->alu, dut->r,     dut->ob,
                  dut->q,   dut->dc,    dut->lc,  dut->vma,   dut->md,
                  dut->vmaok,
                  dut->jcond, dut->nop, dut->pcs1, dut->pcs0, dut->iwrited,
                  dut->promdisable, dut->sintr_o};
  };

  Row cur;
  if (!read_next(cur)) {
    std::fprintf(stderr, "FAIL: %s: cannot read the first microcycle\n", path);
    return 1;
  }
  uint64_t prev_ns = 0;
  drive(cur, 0);
  Sample prev = take();

  size_t k = 0;          // the microcycle now running
  long last_edge = -1;   // -1 until the first, whose length has no start
  int bad = 0;

  // Coverage, and the assertions that say what this program leaves untouched.
  long lengths_checked = 0, dispatches = 0, disp_reads = 0, halts = 0;
  long iwrites = 0, popjs = 0, jumps = 0, prom_fetches = 0, ram_fetches = 0;
  long stat_counts = 0, stalls = 0, ram_executes = 0, other_speed = 0;
  long lc_moved = 0, map_sources = 0, cycles_run = 0;
  long q_shifts = 0, ilongs = 0, promdis_rows = 0;
  long sub_tick = 0, worst_slip = 0, best_slip = 0, arb_skipped = 0;
  bool any_slip = false;
  bool bus_outstanding = false, saw_mem_req = false, saw_device = false;
  bool acked_armed = false;
  int prev_n_memgrant = 1;
  long grants_checked = 0;
  uint64_t ack_for_cur = 0;
  std::map<long, long> ack_error;
  bool saw_ub = false;
  long ub_cycles = 0;
  bool was_unibus = false, was_nxm = false;
  uint32_t stuck_phys = 0;
  const char *stopped_because = "nothing on the bus answered it";
  // HOW MANY DEVICE CYCLES THE FABRIC ITSELF ANSWERED.  Counted at the far
  // end of the cycle rather than at the disk's own `dev_ack`, which no port
  // brings out: a device cycle that reached -MEMACK without the NXM timer
  // ending it was answered by something inside the machine, and the only
  // thing inside is the disk controller --- `device_ack` is driven low at the
  // top of `main` and never again.  On this program it must be all 16,951,
  // and the guard below says so rather than printing a number nobody reads.
  long device_answers = 0, device_timeouts = 0;
  bool dev_cycle = false, dev_acked = false;
  // WHICH SLAVE EACH CYCLE WENT TO, counted at the grant. Not a diagnostic:
  // this program's traffic is 16,951 device cycles against 512 to main
  // memory --- the boot PROM polls the disk controller's status register,
  // which the decode places in Xbus I/O space --- and **all 16,951 are now
  // answered by the fabric's own `cadr_disk_controller.sv`** where they used
  // to be answered from the trace.  What is still the testbench's own
  // placement is the 512, through `mem_done`.  The check should fail rather
  // than shrink quietly if either count ever goes to none.
  long mem_cycles = 0, device_cycles = 0;
  // -XBUS.INTR: how many microcycles it was compared on, how many it was up
  // on, and how many rows held the disk's status word in MD --- the guard
  // that says the zero above is a live zero and not a dead controller.
  long sintr_checked = 0, sintr_raised = 0, status_rows = 0;
  long dev_writes_checked = 0;
  std::map<uint32_t,long> dev_words;
  long ack_at_tick = 0;
  size_t unanswerable = 0;
  std::set<uint64_t> a_values, m_values, ob_values;

  // Long enough for every microcycle plus the reset and a margin: the
  // longest cycle the generator makes is 44 ticks at extra slow.
  const long kMaxTicks = static_cast<long>(total_rows) * 96 + 1024;

  for (long t = 0; t < kMaxTicks && k < total_rows; ++t) {
    if (t == 4) dut->rst = 0;

    // THE DDR, AND NOTHING NEARER.  The bus interface, the address decode and
    // the bridge are all inside the DUT now: what this drives is the far side
    // of `mem_req`/`mem_done`, and -MEMGRANT, -MEMACK and -LOADMD are the
    // fabric's own.
    //
    // The answer is placed where muir's responder placed it. `-XBUS.RQ` is
    // SETUP_NS after the grant and the bridge is thin --- "dev_ack follows
    // mem_done without a register" --- so answering at muir's `answered_at`
    // puts -MEMACK at muir's `ack`. A read is acknowledged XBUS_ACK_NS after
    // the word, a write at once, which is the only thing the direction is
    // used for; taking it from the bridge's own `mem_write` times the answer
    // and never chooses the data.
    dut->mem_done = 0;
    if (dut->mem_req) saw_mem_req = true;
    if (dut->dev_rq && dut->device) saw_device = true;
    if (dut->ub_msyn) saw_ub = true;
    // THE GRANT INSTANT, CHECKED DIRECTLY.  A grant a whole microcycle early
    // shows up in a microcycle's *length* as five nanoseconds --- the
    // magnitude of a bug and the magnitude of its symptom are not the same
    // thing --- so a length tolerance sized to this testbench's own tick can
    // blind the check to an error two orders larger. It did: the mutant
    // `the-grant-comes-a-microcycle-early` was caught on one row at -5 ns and
    // survived the moment the tolerance admitted -5. So the instant is
    // compared to muir's rather than inferred from what it does.

    // WHERE THE FABRIC'S OWN -MEMACK LANDS, against muir's. Measured rather
    // than fitted: a constant chosen to make two checks agree is a constant
    // hiding a difference, and this says whether there is one and how big.
    //
    // **READ THE NUMBERS IT PRINTS WITH THIS IN MIND: IT OBSERVES ONE TICK
    // EARLY.**  It samples `n_memack` here, near the top of the tick, before
    // the slave's answer has been driven and eval'd, so an acknowledgement
    // the interface makes combinationally reads back a tick after it
    // happened.  Measured, and the size of it: the printed histogram says -5
    // on every device read and -5 on every device write, which is the
    // instrument's one tick and nothing else.  **THE DEVICE WRITES USED TO
    // READ -10 AND THE DISK CONTROLLER MOVED THEM**: when this testbench
    // answered them, all 5,650 came back a tick late --- 17 ticks from the
    // grant against muir's 16, the signature of CLAUDE.md's fourth entry,
    // an answer worked out before the clock edge rather than after it ---
    // and `rtl/machine/cadr_disk_controller.sv`, answering combinationally off
    // `dev_rq` inside the fabric, lands them at muir's own 16.  The reads
    // were 28 ticks from the grant either way, which is muir's 28.
    //
    // The rest of the histogram is main memory and is the testbench's own
    // rounding, not the fabric's: the 256 writes spread over -9, -7 and -5
    // in 78, 104 and 74, the 256 reads over -4, -2 and 0 in the same three
    // counts, the two NXM cycles at +5 and the single Unibus write at -10.
    // Measured at the commit that added the disk controller; the shape
    // follows from `ack_at_tick` being rounded up to a tick, and it is here
    // so that a change in it is visible as a change and not read as noise.
    //
    // Moving both --- the answer to after the edge, and this observation to
    // after the second eval --- collapses the histogram to sub-tick, and was
    // tried: `tb/cadr_busint_xbus_tb.cpp` already does it that way and says
    // why.  It is not here because on its own it turns this check red on 58
    // microcycles, each exactly one 220 ns wait long, which nobody has
    // characterised.  See the `RD_FINISH_T` comment in
    // `rtl/machine/cadr_microcycle.sv` and issue #11.
    //
    // Anyone re-deriving these numbers should move the observation first and
    // measure again.  Two published readings of this histogram were wrong
    // because that was not done.
    if (acked_armed && !dut->n_memack_o) {
      acked_armed = false;
      const long ns_now = static_cast<long>(prev_ns) + (t - last_edge) * kTickNs;
      ack_error[static_cast<long>(ack_for_cur) - ns_now]++;
    }

    if (bus_outstanding && dut->unibus) {
      was_unibus = true;
      stuck_phys = dut->phys;
    }
    if (bus_outstanding && dut->nxm) was_nxm = true;
    const long answer_tick =
        ack_at_tick - (dut->mem_write ? 0 : kXbusAckNs / kTickNs);
    if (dut->mem_req && bus_outstanding && t >= answer_tick) dut->mem_done = 1;
    // **THE XBUS DEVICES WERE ANSWERED FROM THE TRACE HERE, AND THAT LINE IS
    // GONE.**  It raised `device_ack` whenever the decode said the cycle was
    // a device's, at the instant muir's own responder answered, with
    // `device_rdata` handed muir's word --- and it answered every one of this
    // program's 16,951 device cycles.  Its own comment called that stimulus
    // rather than a model, and it was: the fabric had no disk controller.  It
    // has one now, `rtl/machine/cadr_disk_controller.sv` inside `cadr_machine`, so
    // `device_ack` stays low here and the four registers answer for
    // themselves.  MD is compared every microcycle, so an answer at the wrong
    // instant, or a status word that is not `0x2321`, fails on the row it
    // happens on.
    //
    // Deleted rather than commented out or left unused, which is the whole
    // lesson of CLAUDE.md's `md` entry: a testbench that goes on supplying
    // the right answer leaves the new module unchecked and every check green.
    // POISON ON A WRITE.  -LOADMD is asserted on every acknowledgement and it
    // is RDCYC on the processor's side that keeps a write from strobing MD.
    // Handing back the word MD should hold makes that gate unobservable ---
    // an extra load is then a no-op, and dropping the gate survives, measured
    // --- so a write cycle gets the complement instead. Nothing should take
    // it. Keyed off the DUT's own WRCYC, which is safe here in a way a shadow
    // memory would not be: it chooses poison, never data, so a processor that
    // had the direction wrong takes poison and says so.
    //
    // The seam's own poison is in `drive` above and stands on every
    // microcycle rather than only on a write, because the disk controller
    // answers device reads now and a seam that went quiet would let a module
    // that stopped driving read back something plausible.
    if (dut->wrcyc) {
      dut->mem_rdata = ~static_cast<uint32_t>(rdata_for[k < total_rows ? k : 0]);
    }
    // Only a read takes a word: -LOADMD is gated by RDCYC, so a write must
    // not consume one. Using the DUT's own RDCYC to step the stimulus is safe
    // where it would not normally be, because MD is compared every
    // microcycle: a processor that got the direction wrong would take the
    // wrong word and say so on the next SRCMD.

    dut->clk = 1;
    dut->eval();

    if (dev_cycle && bus_outstanding && !dut->n_memack_o) {
      if (dut->timed_out) {
        if (!dev_acked) ++device_timeouts;
      } else if (!dev_acked) {
        ++device_answers;
      }
      dev_acked = true;
    }

    if (bus_outstanding && !dut->mem_req && !dut->dev_rq && t > ack_at_tick) {
      bus_outstanding = false;
    }

    if (dut->clock_edge) {
      const Row &r = cur;

      if (prev.pc != r.v[kPc]) bad += Fail(r, "PC", prev.pc, r.v[kPc]);
      if (prev.ir != r.v[kIr]) bad += Fail(r, "IR", prev.ir, r.v[kIr]);
      if (prev.lpc != r.v[kLpc]) bad += Fail(r, "LPC", prev.lpc, r.v[kLpc]);
      if (prev.opc != r.v[kOpc]) bad += Fail(r, "OPC", prev.opc, r.v[kOpc]);
      if (prev.st != r.v[kSt]) bad += Fail(r, "ST", prev.st, r.v[kSt]);
      if (prev.a != r.v[kA]) bad += Fail(r, "the A bus", prev.a, r.v[kA]);
      if (prev.lc != r.v[kLc]) bad += Fail(r, "LC", prev.lc, r.v[kLc]);
      if (prev.m != r.v[kM]) bad += Fail(r, "the M bus", prev.m, r.v[kM]);
      if (prev.alu != r.v[kAlu]) bad += Fail(r, "the ALU", prev.alu, r.v[kAlu]);
      if (prev.r != r.v[kR]) bad += Fail(r, "R", prev.r, r.v[kR]);
      if (prev.ob != r.v[kOb]) bad += Fail(r, "OB", prev.ob, r.v[kOb]);
      if (prev.q != r.v[kQ]) bad += Fail(r, "Q", prev.q, r.v[kQ]);
      if (prev.dc != r.v[kDc]) bad += Fail(r, "DC", prev.dc, r.v[kDc]);
      if (prev.jcond != r.v[kJcond])
        bad += Fail(r, "JCOND", prev.jcond, r.v[kJcond]);
      if (prev.vma != r.v[kVma]) bad += Fail(r, "VMA", prev.vma, r.v[kVma]);
      if (prev.md != r.v[kMd]) bad += Fail(r, "MD", prev.md, r.v[kMd]);
      // The mode register is no longer handed to the machine: it is written
      // over the Unibus by the machine itself, which is the whole point of
      // the register block.
      if (prev.promdis != r.v[kPromdis])
        bad += Fail(r, "PROMDISABLE", prev.promdis, r.v[kPromdis]);
      // The net is -VMAOK, `NAND(-PFR, -PFW)` at VCTL1 1D17: *low* when the
      // access is permitted, the opposite of the logical VMAOK the jump
      // conditions and MEMRQ take.
      if (prev.vmaok == r.v[kNVmaok])
        bad += Fail(r, "-VMAOK", !prev.vmaok, r.v[kNVmaok]);
      if (prev.nop != r.v[kNop]) bad += Fail(r, "NOP", prev.nop, r.v[kNop]);
      if (prev.pcs1 != r.v[kPcs1]) bad += Fail(r, "PCS1", prev.pcs1, r.v[kPcs1]);
      if (prev.pcs0 != r.v[kPcs0]) bad += Fail(r, "PCS0", prev.pcs0, r.v[kPcs0]);
      if (prev.iwrited != r.v[kIwrited])
        bad += Fail(r, "IWRITED", prev.iwrited, r.v[kIwrited]);
      // **-XBUS.INTR, WHICH USED TO BE STIMULUS.**  muir samples `SINTR`
      // after the step --- `Machine::xbus_interrupt()`, the disk's request
      // ORed with the display's, as the 74S175 at LCC 3E12 registers it on
      // CLK3C --- so the reference is the value at the end of the microcycle,
      // which is what `prev` holds.  The fabric makes the same OR out of its
      // own two slaves and `sintr_o` is the line.
      //
      // **THE COLUMN IS ZERO ON ALL 600,000 ROWS AND THE ZERO IS A LIVE
      // ONE.**  The boot PROM never writes the disk's command register and
      // never enables the display, so both enables are off --- but the
      // controller answers 11,301 status reads with `0x2321`, `<0>` set, so
      // NOT-ACTIVE, the interrupt's other term, is true throughout.  A fabric
      // that ignored the enable, or that inverted either half of the gate,
      // raises the line here and fails on the first row.  The count below
      // says how many rows carried a live not-active, so that a run where the
      // controller stopped answering could not pass this quietly.
      if (prev.sintr != r.v[kSintr])
        bad += Fail(r, "-XBUS.INTR", prev.sintr, r.v[kSintr]);
      ++sintr_checked;
      if (prev.sintr) ++sintr_raised;
      if (r.v[kMd] == 0x2321u) ++status_rows;

      // The microcycle's own length.  muir charges the stall before the
      // cycle and the cycle after it, so what the generator owes is the
      // interval less the stall.  Nothing here raises -HANG --- VCTL1 is
      // slice 5 --- so the DUT runs the cycles back to back and the stall is
      // arithmetic rather than a driven input.
      if (last_edge >= 0) {
        const uint64_t before = prev_ns;
        // The stall is no longer subtracted: VCTL1 decides it now, so the
        // whole interval between boundaries is the fabric's own answer.
        const uint64_t want = r.v[kNs] - before;
        const uint64_t got = static_cast<uint64_t>(t - last_edge) * kTickNs;
        if (got != want) {
          const long slip = static_cast<long>(got) - static_cast<long>(want);
          if (arbitrated[k]) {
            ++arb_skipped;
          } else if (r.v[kStall] && slip > -kTickNs && slip < kTickNs) {
            ++sub_tick;
            if (!any_slip || slip > worst_slip) worst_slip = slip;
            if (!any_slip || slip < best_slip) best_slip = slip;
            any_slip = true;
          } else {
            bad += Fail(r, "the microcycle in ns", got, want);
          }
        }
        ++lengths_checked;
      }
      if (r.v[kStall]) ++stalls;
      // The bus cycle this edge started, and when the interface will answer.
      // A cycle the fabric cannot answer: the decode did not select main
      // memory and no slave inside the machine claims the address. THE FABRIC
      // HAS THE DISK CONTROLLER'S FOUR REGISTERS AND NOTHING ELSE ON THE
      // XBUS --- no display, no I/O board, no Unibus --- so the machine runs
      // until the program touches one of those, and stops there rather than
      // diverging.
      // An NXM is not unanswerable: nothing is meant to answer it, muir's
      // interface times it out and so does the fabric's. Only a cycle
      // addressed to a bus the fabric does not have stops the run.
      if (saw_ub) ++ub_cycles;
      // Not before the cycle has had its time. A Unibus cycle arbitrates for
      // five master clocks before -UB MSYN goes out, so a detector that gave
      // up one microcycle after the request would call every one of them
      // unanswerable --- which it did, and reported nought Unibus cycles
      // while the arbitration was working.
      if (bus_outstanding && t > ack_at_tick + 40 && !saw_mem_req &&
          !saw_device && !saw_ub && was_unibus) {
        unanswerable = k;
        stopped_because = was_unibus  ? "it is addressed to the Unibus, and "
                                        "cadr_busint_xbus.sv is the Xbus half"
                          : was_nxm   ? "it is Xbus space with nothing in it, "
                                        "which should have timed out"
                                      : "nothing on the bus answered it";
        break;
      }
      // muir grants at the edge the cycle starts on --- `Rtl::clock_edge`
      // calls `Busint::request` and `Busint::mclk_edge` there --- so the
      // fabric's -MEMGRANT must fall at this edge and not at an earlier one.
      if (r.v[kBus]) {
        if (!prev_n_memgrant) {
          std::fprintf(stderr,
                       "microcycle %" PRIu64 ": -MEMGRANT was already out "
                       "before the edge this cycle starts on\n",
                       r.v[kCycle]);
          ++bad;
        }
        ++grants_checked;
        bus_outstanding = true;
        // THE WORD AT THE XBUS SEAM.  `dev_wdata` is a register of its
        // own --- `wdata <= md` at the edge that starts the cycle --- so MD
        // being compared every microcycle says nothing about it, and a slave
        // hung here would be the first thing to notice it was wrong. The
        // reference is the trace's own MD column for the row that started
        // the cycle, which is muir's and not the DUT's.
        //
        // **AND ON THIS PROGRAM IT SAYS ONLY THAT THE WORD IS ZERO.**  All
        // 5,650 device writes the boot PROM makes carry the same word, and
        // that word is zero --- the count is on this check's own output for
        // that reason.  So any bijection on the bits is invisible here: a
        // rotation of `dev_wdata` survives, measured, and is an equivalence
        // *on this trace* rather than in general.  Same shape as the control
        // store's all-zero pass, and the same answer: what catches a wiring
        // fault here is a mutation that makes a nonzero word out of a zero
        // one, and what would catch a bijection is a trace that writes
        // something else.
        if (dut->device && dut->wrcyc) {
          ++dev_writes_checked;
          dev_words[dut->dev_wdata]++;
          if (dut->dev_wdata != md_at_row[k])
            bad += Fail(r, "the word at the Xbus seam", dut->dev_wdata,
                        md_at_row[k]);
        }
        dev_cycle = dut->device;
        dev_acked = false;
        if (dut->device) ++device_cycles;
        else if (!dut->nxm && !dut->unibus) ++mem_cycles;
        acked_armed = ack_for[k] != 0;
        ack_for_cur = ack_for[k];
        saw_mem_req = false;
        saw_device = false;
        saw_ub = false;
        // Rounded *up*: a memory board answers on its own refresh clock, so
        // muir's acknowledgement is not on the five-nanosecond grid, and the
        // fabric can only see it at a tick at or after it. Truncating instead
        // ends a wait one 220 ns cycle early wherever the acknowledgement
        // falls within a tick of a master clock edge.
        ack_at_tick =
            t + static_cast<long>((ack_for[k] - r.v[kNs] + kTickNs - 1) / kTickNs);
        ++cycles_run;
      }
      if (r.v[kLc]) ++lc_moved;
      if (r.v[kPromdis]) ++promdis_rows;
      a_values.insert(r.v[kA]);
      m_values.insert(r.v[kM]);
      ob_values.insert(r.v[kOb]);
      // SRCMAP is group B source 1, and its word is handed to the DUT.
      if (r.v[kNop] == 0 && ((r.v[kIr] >> 31) & 1) && ((r.v[kIr] >> 29) & 1) &&
          (((r.v[kIr] >> 26) & 7) == 1))
        ++map_sources;
      // Extra slow is {SPEED1,SPEED0} = 00, where both taps of the 74S151 are
      // -TPR160 and ILONG changes nothing.  Asserted rather than assumed, so
      // that a trace which does change speed re-opens the claim below.
      if (r.v[kSpeed1] || r.v[kSpeed0]) ++other_speed;

      // What the program reaches, and what it does not.
      if (r.v[kNop] == 0) {
        const uint64_t cls = (r.v[kIr] >> 43) & 3;
        const uint64_t funct = (r.v[kIr] >> 10) & 3;
        if (cls == 2) {
          ++dispatches;
          // DISPWR is misc function 2, which is what makes the dispatch a
          // write of the memory rather than a read of it.  If this ever
          // fails the dispatch memory is being read and slice 1 cannot
          // answer for where the machine goes next.
          if (funct != 2) ++disp_reads;
        }
        if (cls == 1 && ((r.v[kIr] >> 8) & 3) == 3) ++iwrites;
        // QS<1:0> of 1 or 2 is a shift; 3 is the load, which the boot PROM
        // does five times and nothing else.
        if (cls == 0) {
          const uint64_t qs = r.v[kIr] & 3;
          if (qs == 1 || qs == 2) ++q_shifts;
        }
        if ((r.v[kIr] >> 45) & 1) ++ilongs;
        if (((r.v[kIr] >> 46) & 1) != 0) ++stat_counts;
      }
      if (r.v[kPcs1] == 0 && r.v[kPcs0] == 0) ++popjs;
      if (r.v[kPcs1] == 0 && r.v[kPcs0] == 1) ++jumps;
      if (r.v[kSrun] == 0 || r.v[kHalted] != 0) ++halts;
      // -PROMENABLE at PCTL 1C19.  Everything else comes out of the control
      // store RAM, which here is every WRITE-I-MEM reading back the word its
      // own write pulse has just put there.
      if (r.v[kPc] < 1024 && r.v[kPromdis] == 0 && r.v[kIwrited] == 0)
        ++prom_fetches;
      else
        ++ram_fetches;
      // ...and none of them is the machine *running* the microcode it has
      // loaded: this program never gets past the disk wait to `JUMP-TO-6`,
      // so PROMDISABLE is never set and every fetch above the PROM is a
      // write-back.  Said here so the gap is on the check's own output.
      if (r.v[kIwrited] == 0 && r.v[kPc] >= 1024) ++ram_executes;

      last_edge = t;
      prev_ns = r.v[kNs];
      ++k;
      if (k < total_rows) {
        if (!read_next(cur)) {
          std::fprintf(stderr, "FAIL: %s: ran out of rows at %zu of %zu\n",
                       path, k, total_rows);
          return 1;
        }
        drive(cur, k);
      }

      if (bad >= 20) {
        std::fprintf(stderr, "stopping after %d mismatches\n", bad);
        break;
      }
    }

    dut->clk = 0;
    dut->eval();
    prev = take();
    prev_n_memgrant = dut->n_memgrant_o;
  }

  std::printf("    -MEMACK against muir, in nanoseconds (muir minus fabric):\n");
  for (const auto &e : ack_error)
    std::printf("             %+5ld ns  %ld cycles\n", e.first, e.second);

  dut->final();
  delete dut;

  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %zu microcycles\n", bad, k);
    return 1;
  }
  if (unanswerable) {
    std::printf(
        "ok: %zu microcycles of the whole machine agree with muir's rtl "
        "engine\n"
        "    %s, and it stops there rather than diverging: at that\n"
        "    microcycle the program touches something that is not main\n"
        "    memory at %o: %s.\n"
        "    Up to there: %ld Unibus cycles, and %ld bus cycles through the\n"
        "    fabric's own decode,\n"
        "    bus interface and DDR bridge; MD strobed by that interface and\n"
        "    compared every microcycle; every microcycle length the fabric's\n"
        "    own, stalls included.\n",
        unanswerable, pack_trace ? "on a System 100 band" : "on MIT's boot PROM",
        stuck_phys, stopped_because, ub_cycles, cycles_run);
    return 0;
  }
  if (k != total_rows) {
    std::fprintf(stderr,
                 "FAIL: the run stopped after %zu of %zu microcycles --- the "
                 "generator is not making a boundary\n",
                 k, total_rows);
    return 1;
  }

  // A run that agreed everywhere while reaching nothing would pass and mean
  // nothing.  These are what it has to have reached, and what it has to have
  // left alone for the holes above to be the size they are claimed to be.
  int thin = 0;
  if (disp_reads && !pack_trace) {
    std::fprintf(stderr,
                 "FAIL: %ld dispatches are not DISPWR, so the dispatch memory "
                 "is read and the NPC mux has an answer this slice cannot give\n",
                 disp_reads);
    ++thin;
  }
  if (halts) {
    std::fprintf(stderr,
                 "FAIL: the machine halted on %ld microcycles; MACHRUN going "
                 "down is not modelled here\n",
                 halts);
    ++thin;
  }
  if (stat_counts) {
    std::fprintf(stderr,
                 "FAIL: %ld microcycles carry IR<46>; the statistics counter "
                 "is claimed unexercised\n",
                 stat_counts);
    ++thin;
  }
  if (lc_moved && !pack_trace) {
    std::fprintf(stderr,
                 "FAIL: LC is nonzero on %ld microcycles; it is claimed "
                 "constant zero, which is what makes its check vacuous\n",
                 lc_moved);
    ++thin;
  }
  // A fraction of a percent is the Unibus showing through --- the pack trace
  // talks to the disk, and 347 of its 141,849 bus cycles arbitrate. A tenth
  // of them would mean the exemption had become the rule and was covering
  // something other than the missing Unibus path.
  if (unibus_cycles * 100 > cycles_run) {
    std::fprintf(stderr,
                 "FAIL: %ld of %ld bus cycles arbitrated for the Unibus; the "
                 "length check exempts those and cannot exempt that share\n",
                 unibus_cycles, cycles_run);
    ++thin;
  }
  // THE TOLERANCE THIS CHECK NEEDS IS NONE.  The standalone testbench's
  // -MEMACK placement is a testbench's; here the bus interface is the
  // fabric's own and every length comes out exact, so the count below is
  // zero and the guard is set at zero.  It is the guard that was missing
  // when the same count went from 0 to 11,301 in one commit without a line
  // of output changing except the number --- which is what #12 was.
  //
  // NOT IN mutations/list.txt, and the reason is worth stating.  A record
  // there is one edit to one file, and this guard needs two to be exercised:
  // the fabric drifting a tick *and* the tolerance widened to admit it.  The
  // fabric drifting alone fails on the length outright, and the tolerance
  // widened alone changes nothing, because muir's boundaries here are all on
  // the five-nanosecond grid and no slip is ever sub-tick.  Verified by hand
  // instead, with RD_FINISH_T at 28-2 and the band below widened to two
  // ticks: 11,301 of 599,999, the number from #12, and a FAIL rather than an
  // ok line carrying it.
  if (sub_tick) {
    std::fprintf(stderr,
                 "FAIL: %ld of %ld microcycle lengths were within a tick "
                 "rather than exact; the composed machine has its own bus "
                 "interface and owes exactness, not a tolerance\n",
                 sub_tick, lengths_checked);
    ++thin;
  }
  if (dev_words.size() > 1) {
    std::fprintf(stderr,
                 "NOTE: the Xbus seam carried %zu distinct words; the check on "
                 "it is no longer vacuous and the rotation mutation should be "
                 "live again\n",
                 dev_words.size());
  }
  if (dev_writes_checked == 0) {
    std::fprintf(stderr,
                 "FAIL: no device write put a word on the Xbus seam, so "
                 "`dev_wdata` is claimed correct by a check that never "
                 "looked at it\n");
    ++thin;
  }
  // **EVERY DEVICE CYCLE MUST BE THE FABRIC'S OWN ANSWER.**  Nothing outside
  // the machine drives `device_ack`, so a device cycle that got to -MEMACK
  // without the NXM timer got there through `rtl/machine/cadr_disk_controller.sv`.
  // This is the guard that would have caught the slice going backwards: a
  // testbench that started answering these again, or a decode that stopped
  // selecting the disk, both show up here as a count that is not the whole
  // 16,951 --- and a timed-out device cycle is not a quiet degradation, it is
  // a poll the machine waits 4.25 us for.
  if (device_answers != device_cycles || device_timeouts) {
    std::fprintf(stderr,
                 "FAIL: of %ld device cycles the fabric answered %ld and the "
                 "NXM timer ended %ld; every one is the disk controller's and "
                 "nothing outside the machine drives device_ack\n",
                 device_cycles, device_answers, device_timeouts);
    ++thin;
  }
  if (device_cycles == 0) {
    std::fprintf(stderr,
                 "FAIL: none of %ld bus cycles reached an Xbus device, so the "
                 "disk controller's registers are claimed correct by a check "
                 "that never read one\n",
                 cycles_run);
    ++thin;
  }
  // **THE ZERO -XBUS.INTR IS COMPARED AGAINST MUST BE A LIVE ZERO.**  This
  // program raises no interrupt --- it enables neither the disk's nor the
  // display's --- so the comparison above is against zero on every row, and
  // CLAUDE.md's rule is that a check which only ever compares against zero
  // passes a wire stuck at zero.  What makes it a real comparison is that the
  // interrupt's OTHER term is true throughout: `not_active` is `STATUS<0>`
  // and the 11,301 polls all come back `0x2321`, which has it set.  So a
  // fabric that ignored the enable would raise the line and fail.  If MD
  // never holds that word the guarantee is gone and this says so rather than
  // passing on a controller that has stopped answering.
  if (status_rows == 0) {
    std::fprintf(stderr,
                 "FAIL: MD never held the disk's 0x2321, so nothing says the "
                 "controller was not-active while -XBUS.INTR was compared "
                 "against zero on %ld microcycles\n",
                 sintr_checked);
    ++thin;
  }
  if (mem_cycles == 0) {
    std::fprintf(stderr,
                 "FAIL: none of %ld bus cycles reached main memory; every one "
                 "was answered from the trace and the DDR bridge was never "
                 "asked for a word\n",
                 cycles_run);
    ++thin;
  }
  if (other_speed && !pack_trace) {
    std::fprintf(stderr,
                 "FAIL: %ld microcycles run at other than extra slow; ILONG is "
                 "claimed to change nothing here\n",
                 other_speed);
    ++thin;
  }
  if (ram_executes && !pack_trace) {
    std::fprintf(stderr,
                 "FAIL: %ld microcycles run microcode out of the control "
                 "store; PROMDISABLE is claimed never set\n",
                 ram_executes);
    ++thin;
  }
  struct {
    const char *what;
    long n;
  } reached[] = {
      {"POPJ off the stack", popjs},   {"jumps to IR<25:12>", jumps},
      {"WRITE-I-MEMs", iwrites},       {"fetches out of the boot PROM", prom_fetches},
      {"fetches out of the control store", ram_fetches},
      {"microcycles the bus held off", stalls},
  };
  for (const auto &e : reached) {
    if (e.n == 0) {
      std::fprintf(stderr, "FAIL: the run reached no %s\n", e.what);
      ++thin;
    }
  }
  // What the pack trace exists for. The boot PROM reaches none of these, and
  // if this one stops reaching them it has stopped earning its 297 MB.
  if (pack_trace) {
    struct {
      const char *what;
      long n;
    } wanted[] = {
        {"reads of the map", map_sources},   {"reads of the dispatch memory", disp_reads},
        {"shifts of Q", q_shifts},           {"microcycles with PROMDISABLE set", promdis_rows},
        {"instructions with ILONG", ilongs}, {"microcycles run out of the control store", ram_executes},
    };
    for (const auto &e : wanted) {
      if (e.n == 0) {
        std::fprintf(stderr,
                     "FAIL: the pack trace reached no %s, which is what it is "
                     "for\n",
                     e.what);
        ++thin;
      }
    }
  }
  if (thin) return 1;

  std::printf(
      "ok: %zu microcycles of the whole machine agree with muir's rtl engine "
      "%s\n"
      "    PC, IR, LPC, OPC, ST, LC, the A and M buses, the ALU, R, OB, Q,\n"
      "    DC, VMA, -VMAOK, JCOND and NOP/PCS1/PCS0/IWRITED every microcycle;\n"
      "    %ld microcycle lengths in 200 MHz ticks, %ld of them within a tick\n"
      "    rather than exact (slip %+ld to %+ld ns), %ld exempt for the Unibus\n"
      "    arbitration of %ld of %ld bus cycles\n"
      "    of those bus cycles %ld reached main memory and %ld an Xbus device;\n"
      "    %ld of those the fabric's own disk controller answered and %ld the\n"
      "    NXM timer ended; %ld device writes put a word on the seam,\n"
      "    %zu distinct among them\n"
      "    reached: %ld POPJs, %ld jumps, %ld WRITE-I-MEMs, %ld dispatches of\n"
      "             which %ld read the memory, %ld PROM fetches, %ld control\n"
      "             store fetches, %ld microcycles the bus held off, %ld map\n"
      "             reads, %ld Q shifts, %ld ILONG instructions\n"
      "    the A bus took %zu distinct values, the M bus %zu, OB %zu;\n"
      "    %ld grants compared against the edge muir grants on\n"
      "    -XBUS.INTR compared on %ld microcycles and up on %ld of them, the\n"
      "      display's vertical interrupt ORed with the disk's request inside\n"
      "      the machine; %ld rows held the disk's 0x2321 in MD, <0> set, so\n"
      "      not-active was true and the zero compared is the enable's\n"
      "    driven from the trace, and going with the memory path: MD, the\n"
      "             word -LOADMD strobes into it; the console's registers\n",
      k, pack_trace ? "on a System 100 band" : "on MIT's boot PROM",
      lengths_checked, sub_tick, best_slip, worst_slip, arb_skipped,
      unibus_cycles, cycles_run, mem_cycles, device_cycles,
      device_answers, device_timeouts,
      dev_writes_checked, dev_words.size(),
      popjs, jumps, iwrites, dispatches, disp_reads,
      prom_fetches, ram_fetches, stalls, map_sources, q_shifts, ilongs,
      a_values.size(), m_values.size(), ob_values.size(), grants_checked,
      sintr_checked, sintr_raised, status_rows);

  // What this program did not reach, printed from the counts rather than
  // asserted from memory, so the list cannot outlive its reasons.
  struct {
    const char *what;
    long n;
  } unreached[] = {
      {"the dispatch memory's read", disp_reads},
      {"MACHRUN down", halts},
      {"the statistics counter", stat_counts},
      {"microcode run out of the control store", ram_executes},
      {"the location counter (LC is zero throughout)", lc_moved},
      {"a speed other than extra slow", other_speed},
      {"the map's read", map_sources},
      {"a shift of Q", q_shifts},
      {"an ILONG instruction", ilongs},
  };
  bool said = false;
  for (const auto &e : unreached) {
    if (e.n) continue;
    if (!said) {
      std::printf("    not reached by this program, and so not checked:\n");
      said = true;
    }
    std::printf("             %s\n", e.what);
  }
  return 0;
}
