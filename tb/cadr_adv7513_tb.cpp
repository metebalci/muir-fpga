// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The HDMI transmitter's configuration, read off the two wires as a bus
// analyzer reads them.
//
// WHAT THIS IS COMPARING WITH WHAT.  `rtl/plumbing/cadr_adv7513.sv` writes a
// fixed program to the ADV7513 on the DE25-Nano.  This file carries a SECOND
// transcription of that program, typed from the same source the module's
// header cites and not from the module, and a decoder that recovers the
// bytes from the levels of SCL and SDA.  So the two are two descriptions of
// one thing and can disagree, which is the whole reason the transcription is
// here twice.
//
// **NOTHING HERE READS ANY SIGNAL INSIDE THE MODULE, AND NOTHING AIMS AT AN
// INSTANT.**  The decoder is given the two lines and the tick, and finds the
// starts, the stops, the bits and the acknowledges from their edges, exactly
// as `tb/cadr_display_out_tb.cpp` recovers the raster position from the
// syncs rather than from a counter.  It never predicts where an edge will
// be, so nothing here is a coin toss that would look green while the module
// drifted.
//
// The one thing the decoder is told beyond the two lines is what THIS FILE
// drove, which is the slave's acknowledge and the slave's stretched clock.
// It has to be: an interval is a property of whichever end moved the line,
// and the worst the MODULE managed is the number this check is about.  That
// is the tb's own knowledge of the tb, not knowledge of the device.
//
// WHAT IS HELD
//
//   - the framing: every write is its own transaction, a start, three bytes
//     each followed by an acknowledge bit, and a stop; nothing moves SDA at
//     an edge of SCL anywhere in between, which is what a slave would read
//     as a start or a stop in the middle of a byte;
//   - the bytes: the address with its write bit, then the register, then the
//     value, against this file's own transcription, in order, all of it;
//   - the counts: how many transactions, how many bytes, how many
//     acknowledges, and `writes` against them, so a program that ran twice
//     or stopped early is a number and not an impression;
//   - the six intervals the data sheet bounds, measured off the waveform,
//     the worst of each printed, and each of them with a mutation just
//     outside it in `mutations/list.txt`;
//   - a stretched clock, followed rather than talked over, and the stretch
//     counted so that a check where it never happened cannot pass;
//   - a byte the part does not acknowledge, which must stop the program,
//     raise `failed`, leave `configured` down, put a stop on the bus and
//     send nothing more;
//   - the bus left alone once the program is through: neither line moves
//     again;
//   - `restart`, which must run the whole program again, byte for byte.
//
// WHAT IT DOES NOT HOLD, AND NOTHING DOES.  That these registers and these
// values make an ADV7513 transmit.  That is the part's, it is in a document
// that is not on this machine, and this board's connector has never been
// wired to a monitor.  The module's header says the same.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "Vcadr_adv7513.h"
#include "verilated.h"

namespace {

// THE SECOND TRANSCRIPTION.  The register and the value of each of the
// thirty-three writes, typed from `I2C_HDMI_Config.v` of the DE25-Nano rev B
// resource package (sha256 b9b7c477...), in its order.
const uint16_t kProgram[] = {
    0x9803, 0x0100, 0x0218, 0x0300, 0x0B2E, 0x0CBC, 0x1472, 0x1520,
    0x1630, 0x1846, 0x4080, 0x4110, 0x49A8, 0x5510, 0x5608, 0x96F6,
    0x7307, 0x761F, 0x9803, 0x9902, 0x9AE0, 0x9C30, 0x9D61, 0xA2A4,
    0xA3A4, 0xA504, 0xAB40, 0xAF16, 0xBA60, 0xD1FF, 0xDE10, 0xE460,
    0xFA7D,
};
constexpr int kEntries = (int)(sizeof(kProgram) / sizeof(kProgram[0]));

// The eight-bit write address this board's transmitter answers to.
constexpr uint8_t kWriteAddr = 0x72;

// The clock the module is built for, and what the data sheet asks of the bus
// it drives.  One tick of the design is one of these.
constexpr double kClockNs = 10.0;             // 100 MHz
constexpr double kSclMaxHz = 400e3;           // Table 1, I2C INTERFACE
constexpr double kSdaSetupNs = 100.0;         // tDSU
constexpr double kSdaHoldNs = 100.0;          // tDHO
constexpr double kStartSetupNs = 600.0;       // tSTASU
constexpr double kStartHoldNs = 600.0;        // tSTAH
constexpr double kStopSetupNs = 600.0;        // tSTOSU

int bad = 0;
long tick = 0;

void Fail(const char *what) {
  std::fprintf(stderr, "tick %ld: %s\n", tick, what);
  ++bad;
}

void Failf(const char *what, long long got, long long want) {
  std::fprintf(stderr, "tick %ld: %s is %lld, expected %lld\n", tick, what, got, want);
  ++bad;
}

// ---------------------------------------------------------------- the decoder
//
// Given the two lines at each tick, and told which edges of SDA this file
// itself made, it recovers the transactions.  It knows nothing else.
struct Analyzer {
  // What it has recovered.
  struct Txn {
    std::vector<uint8_t> bytes;
    std::vector<bool> acked;     // one per byte: true if the line was low
    bool stopped = false;
  };
  std::vector<Txn> txns;

  // The worst of each interval the data sheet bounds, in ticks; -1 is "not
  // seen yet".  Every one is measured between two edges of the waveform.
  long worst_scl_period = -1;
  long worst_sda_setup = -1;
  long worst_sda_hold = -1;
  long worst_start_setup = -1;
  long worst_start_hold = -1;
  long worst_stop_setup = -1;

  long starts = 0, stops = 0, bytes = 0, acks = 0, nacks = 0;
  long sda_edges_at_scl_edge = 0;   // SDA and SCL moving at the same tick
  long moves_after_done = 0;

  bool prev_scl = true, prev_sda = true;
  bool have_prev = false;
  bool in_txn = false;
  int nbits = 0;
  uint8_t shifter = 0;
  long last_scl_rise = -1, last_scl_fall = -1;
  // **THE MODULE'S OWN LAST MOVE OF SDA, AND NOT THE SLAVE'S.**  A setup and
  // a hold belong to whichever end moved the line, and the numbers this
  // check is about are the module's.  Measured against every edge instead,
  // tDSU came out as the slave model's three microseconds rather than the
  // module's two and a half, and a module that had lost half its setup would
  // not have shown.
  long last_master_sda_edge = -1;
  long start_fall_tick = -1;
  bool watch_quiet = false;

  static void Keep(long *worst, long v) {
    if (*worst < 0 || v < *worst) *worst = v;
  }

  // `mine` says this file's own slave pulled SDA at this tick, so an edge of
  // SDA is the slave's rather than the module's.
  void Step(long t, bool scl, bool sda, bool mine) {
    if (!have_prev) {
      prev_scl = scl;
      prev_sda = sda;
      have_prev = true;
      return;
    }
    const bool scl_rise = scl && !prev_scl;
    const bool scl_fall = !scl && prev_scl;
    const bool sda_edge = sda != prev_sda;

    if (watch_quiet && (scl_rise || scl_fall || sda_edge)) ++moves_after_done;

    // SDA must never move at an edge of SCL: that is a start or a stop to
    // anything listening.  Counted rather than tolerated.
    if (sda_edge && (scl_rise || scl_fall)) ++sda_edges_at_scl_edge;

    if (scl_rise) {
      if (last_scl_rise >= 0) Keep(&worst_scl_period, t - last_scl_rise);
      last_scl_rise = t;
      if (last_master_sda_edge >= 0) Keep(&worst_sda_setup, t - last_master_sda_edge);
      // A bit, or the acknowledge after eight of them.
      if (in_txn) {
        if (nbits < 8) {
          shifter = (uint8_t)((shifter << 1) | (sda ? 1 : 0));
          if (++nbits == 8) {
            txns.back().bytes.push_back(shifter);
            ++bytes;
          }
        } else {
          txns.back().acked.push_back(!sda);
          if (sda) ++nacks; else ++acks;
          nbits = 0;
          shifter = 0;
        }
      }
    }
    if (scl_fall) {
      last_scl_fall = t;
      if (start_fall_tick >= 0) {
        Keep(&worst_start_hold, t - start_fall_tick);
        start_fall_tick = -1;
      }
    }
    if (sda_edge) {
      if (scl && prev_scl) {
        // SCL high across the move: a start or a stop.  **AN INTERVAL WITH
        // NOTHING AT ITS FAR END IS NOT MEASURED**: the very first start of a
        // run has no rise of SCL behind it, and counting the ticks since the
        // beginning of time made tSTASU read 12.59 us when the real worst was
        // 17.52 --- a bound satisfied by an accident of arithmetic, which is
        // the shape of a check that confirms rather than compares.
        if (!sda) {
          if (last_scl_rise >= 0) Keep(&worst_start_setup, t - last_scl_rise);
          start_fall_tick = t;
          ++starts;
          txns.push_back(Txn());
          in_txn = true;
          nbits = 0;
          shifter = 0;
        } else {
          if (last_scl_rise >= 0) Keep(&worst_stop_setup, t - last_scl_rise);
          ++stops;
          if (in_txn) txns.back().stopped = true;
          in_txn = false;
          nbits = 0;
        }
      } else if (!mine && last_scl_fall >= 0) {
        // A data move, and this file did not make it: the hold after SCL
        // fell is the module's own.
        Keep(&worst_sda_hold, t - last_scl_fall);
      }
      if (!mine) last_master_sda_edge = t;
    }
    prev_scl = scl;
    prev_sda = sda;
  }
};

// ------------------------------------------------------------ the slave model
//
// The part, as far as the bus is concerned: it acknowledges each byte by
// pulling SDA low for the ninth bit, it may stretch the clock, and it may
// refuse to acknowledge one chosen byte.
struct Slave {
  bool sda_low = false;
  bool scl_low = false;

  int bitcnt = 0;
  bool live = false;
  long stretch_left = 0;

  // What to do, set by the case being run.
  long stretch_ticks = 0;       // how long to hold SCL down after it falls
  int stretch_every = 0;        // stretch on every Nth falling edge; 0 never
  long nack_after_bytes = -1;   // refuse the acknowledge of this many-th byte
  long bytes_seen = 0;
  long stretches = 0;

  // **THE SLAVE RESPECTS THE SAME TWO INTERVALS THE MASTER DOES**, which it
  // has to for this file's measurements to be about the master at all.  It
  // puts its acknowledge up well after the falling edge, not on it, and
  // takes it down well after the next one.  A model that drove the
  // acknowledge exactly at an edge of SCL would make every byte whose last
  // bit was a one look like a start, and the first run of this check counted
  // twenty-two of them --- all of them this file's own doing.
  long ack_setup = 0;           // ticks after the fall before it drives
  long ack_hold = 0;            // ticks after the next fall before it lets go
  long ack_assert_in = -1;
  long ack_release_in = -1;
  long falls = 0;

  bool prev_scl = true, prev_sda = true;

  // Called with the line as the master alone would drive it; returns the
  // composed lines.
  void Step(bool m_scl, bool m_sda, bool *scl_out, bool *sda_out) {
    // The clock first, so that a stretch composes with the master's release.
    bool scl_pre = m_scl;
    if (prev_scl && !scl_pre && stretch_every > 0) {
      ++falls;
      if (falls % stretch_every == 0) {
        stretch_left = stretch_ticks;
        ++stretches;
      }
    }
    if (stretch_left > 0) {
      --stretch_left;
      scl_low = true;
    } else {
      scl_low = false;
    }
    const bool scl = scl_pre && !scl_low;

    // The bit machine, on the composed clock.
    const bool rise = scl && !prev_scl;
    const bool fall = !scl && prev_scl;
    // A start and a stop, recognized the same way anybody does.
    const bool sda_now = m_sda && !sda_low;
    if (prev_scl && scl && sda_now != prev_sda) {
      if (!sda_now) {         // a start
        live = true;
        bitcnt = 0;
      } else {                // a stop
        live = false;
        bitcnt = 0;
        sda_low = false;
        ack_assert_in = -1;
        ack_release_in = -1;
      }
    }
    if (rise && live) ++bitcnt;
    if (fall && live) {
      if (bitcnt == 8) {
        ++bytes_seen;
        const bool refuse = (nack_after_bytes >= 0 && bytes_seen == nack_after_bytes);
        ack_assert_in = refuse ? -1 : ack_setup;
      } else if (bitcnt == 9) {
        // Held for a while after the fall, as a real part holds it, so that
        // the decoder's hold measurement is about the master and this
        // release is not mistaken for one of its moves.
        ack_release_in = ack_hold;
        bitcnt = 0;
      }
    }
    if (ack_assert_in > 0) {
      --ack_assert_in;
    } else if (ack_assert_in == 0) {
      sda_low = true;
      ack_assert_in = -1;
    }
    if (ack_release_in > 0) {
      --ack_release_in;
    } else if (ack_release_in == 0) {
      sda_low = false;
      ack_release_in = -1;
    }

    const bool sda = m_sda && !sda_low;
    prev_scl = scl;
    prev_sda = sda;
    *scl_out = scl;
    *sda_out = sda;
  }
};

struct Bus {
  Vcadr_adv7513 *dut;
  Slave slave;
  Analyzer an;

  void Step() {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
    ++tick;
    bool scl, sda;
    const bool was_low = slave.sda_low;
    slave.Step(!dut->scl_oe, !dut->sda_oe, &scl, &sda);
    // The slave moved SDA at this tick if its own pull changed.
    const bool mine = (slave.sda_low != was_low);
    an.Step(tick, scl, sda, mine);
    dut->scl_i = scl ? 1 : 0;
    dut->sda_i = sda ? 1 : 0;
  }
};

double Ns(long ticks) { return (double)ticks * kClockNs; }

// Every transaction of a run must be the address, a register and its value,
// each acknowledged, with a stop.  `from` is where in the analyzer's list
// this run begins.
void CheckRun(const Analyzer &an, size_t from, const char *what) {
  const size_t have = an.txns.size() - from;
  if (have != (size_t)kEntries) {
    std::fprintf(stderr, "%s: %zu transactions, expected %d\n", what, have, kEntries);
    ++bad;
    return;
  }
  for (int i = 0; i < kEntries; ++i) {
    const Analyzer::Txn &t = an.txns[from + i];
    if (t.bytes.size() != 3 || t.acked.size() != 3) {
      std::fprintf(stderr, "%s: write %d carried %zu bytes and %zu acknowledges,"
                   " expected 3 and 3\n", what, i, t.bytes.size(), t.acked.size());
      ++bad;
      continue;
    }
    const uint8_t want[3] = {kWriteAddr,
                             (uint8_t)(kProgram[i] >> 8),
                             (uint8_t)(kProgram[i] & 0xFF)};
    for (int b = 0; b < 3; ++b) {
      if (t.bytes[b] != want[b]) {
        std::fprintf(stderr, "%s: write %d byte %d is 0x%02x, expected 0x%02x\n",
                     what, i, b, t.bytes[b], want[b]);
        ++bad;
      }
      if (!t.acked[b]) {
        std::fprintf(stderr, "%s: write %d byte %d was not acknowledged\n", what, i, b);
        ++bad;
      }
    }
    if (!t.stopped) {
      std::fprintf(stderr, "%s: write %d has no stop\n", what, i);
      ++bad;
    }
  }
}

// Run until `configured`, `failed`, or a bound; returns the ticks taken.
long RunUntilSettled(Bus &bus, long limit) {
  const long began = tick;
  while (tick - began < limit && !bus.dut->configured && !bus.dut->failed) bus.Step();
  return tick - began;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);

  // How long a whole program may take, generously: a write is a start,
  // twenty-seven bits, an acknowledge each and a stop, and a bit is a
  // thousand clocks at 100 kHz.
  const long kBudget = (long)kEntries * 40 * 1000 + 100000;

  long program_ticks = 0;
  long quiet_checked = 0;
  long stretches_seen = 0;
  double worst_scl_khz = 0;
  double worst[5] = {0, 0, 0, 0, 0};

  // ==================================================== 1. the plain program
  {
    Bus bus;
    bus.dut = new Vcadr_adv7513;
    bus.slave.ack_setup = 300;   // three microseconds after the fall
    bus.slave.ack_hold = 200;    // two microseconds after the next one     // two microseconds, as a part would
    bus.dut->rst = 1;
    bus.dut->restart = 0;
    bus.dut->scl_i = 1;
    bus.dut->sda_i = 1;
    for (int i = 0; i < 8; ++i) bus.Step();
    bus.dut->rst = 0;

    program_ticks = RunUntilSettled(bus, kBudget);
    if (!bus.dut->configured) Fail("the program did not finish");
    if (bus.dut->failed) Fail("`failed` is up on a bus that acknowledged everything");
    if (bus.dut->writes != kEntries) Failf("`writes`", bus.dut->writes, kEntries);

    CheckRun(bus.an, 0, "the plain program");
    if (bus.an.starts != kEntries) Failf("starts", bus.an.starts, kEntries);
    if (bus.an.stops != kEntries) Failf("stops", bus.an.stops, kEntries);
    if (bus.an.bytes != 3 * kEntries) Failf("bytes", bus.an.bytes, 3 * kEntries);
    if (bus.an.acks != 3 * kEntries) Failf("acknowledges", bus.an.acks, 3 * kEntries);
    if (bus.an.nacks != 0) Failf("refusals", bus.an.nacks, 0);
    if (bus.an.sda_edges_at_scl_edge != 0)
      Failf("moves of SDA at an edge of SCL", bus.an.sda_edges_at_scl_edge, 0);

    // THE SIX BOUNDS, measured off the waveform.
    worst_scl_khz = 1e6 / Ns(bus.an.worst_scl_period);
    worst[0] = Ns(bus.an.worst_sda_setup);
    worst[1] = Ns(bus.an.worst_sda_hold);
    worst[2] = Ns(bus.an.worst_start_setup);
    worst[3] = Ns(bus.an.worst_start_hold);
    worst[4] = Ns(bus.an.worst_stop_setup);
    if (bus.an.worst_scl_period < 0) Fail("no clock period was measured");
    if (worst_scl_khz * 1e3 > kSclMaxHz)
      std::fprintf(stderr, "tick %ld: SCL reaches %.1f kHz, and the data sheet"
                   " allows %.0f kHz\n", tick, worst_scl_khz, kSclMaxHz / 1e3), ++bad;
    struct { const char *name; double got; double want; } b[5] = {
        {"tDSU, the setup of SDA", worst[0], kSdaSetupNs},
        {"tDHO, the hold of SDA", worst[1], kSdaHoldNs},
        {"tSTASU, the setup of a start", worst[2], kStartSetupNs},
        {"tSTAH, the hold of a start", worst[3], kStartHoldNs},
        {"tSTOSU, the setup of a stop", worst[4], kStopSetupNs},
    };
    // **AN INTERVAL THAT WAS NEVER MEASURED IS NOT AN INTERVAL THAT PASSED.**
    const long seen[5] = {bus.an.worst_sda_setup, bus.an.worst_sda_hold,
                          bus.an.worst_start_setup, bus.an.worst_start_hold,
                          bus.an.worst_stop_setup};
    for (int i = 0; i < 5; ++i) {
      if (seen[i] < 0) {
        std::fprintf(stderr, "tick %ld: %s was never measured\n", tick, b[i].name);
        ++bad;
        continue;
      }
      if (b[i].got < b[i].want) {
        std::fprintf(stderr, "tick %ld: %s is %.0f ns at worst, and the data"
                     " sheet asks %.0f ns\n", tick, b[i].name, b[i].got, b[i].want);
        ++bad;
      }
    }
    // **AND THE BUS IS LEFT ALONE.**  A module that kept talking after its
    // program would be invisible to every count above.
    bus.an.watch_quiet = true;
    for (int i = 0; i < 40000; ++i) bus.Step();
    quiet_checked = 40000;
    if (bus.an.moves_after_done != 0)
      Failf("moves of either line after the program", bus.an.moves_after_done, 0);
    delete bus.dut;
  }

  // ============================================ 2. the same, with `restart`
  {
    Bus bus;
    bus.dut = new Vcadr_adv7513;
    bus.slave.ack_setup = 300;   // three microseconds after the fall
    bus.slave.ack_hold = 200;    // two microseconds after the next one
    bus.dut->rst = 1;
    bus.dut->restart = 0;
    bus.dut->scl_i = 1;
    bus.dut->sda_i = 1;
    for (int i = 0; i < 8; ++i) bus.Step();
    bus.dut->rst = 0;
    RunUntilSettled(bus, kBudget);
    if (!bus.dut->configured) Fail("restart: the first program did not finish");
    const size_t after_first = bus.an.txns.size();

    // A pulse, and it must run the whole thing again.
    bus.dut->restart = 1;
    bus.Step();
    bus.Step();
    bus.dut->restart = 0;
    if (bus.dut->configured) Fail("restart: `configured` is still up after a restart");
    RunUntilSettled(bus, kBudget);
    if (!bus.dut->configured) Fail("restart: the second program did not finish");
    if (bus.dut->writes != kEntries) Failf("restart: `writes`", bus.dut->writes, kEntries);
    CheckRun(bus.an, after_first, "the program after a restart");
    if ((long)bus.an.txns.size() != 2 * kEntries)
      Failf("restart: transactions over two runs", (long)bus.an.txns.size(), 2 * kEntries);
    if (bus.an.sda_edges_at_scl_edge != 0)
      Failf("restart: moves of SDA at an edge of SCL", bus.an.sda_edges_at_scl_edge, 0);
    delete bus.dut;
  }

  // ================================================= 3. a stretched clock
  {
    Bus bus;
    bus.dut = new Vcadr_adv7513;
    bus.slave.ack_setup = 300;   // three microseconds after the fall
    bus.slave.ack_hold = 200;    // two microseconds after the next one
    // Every third falling edge held down for three quarters of a bit, which
    // is longer than the master would have waited on its own.
    bus.slave.stretch_every = 3;
    bus.slave.stretch_ticks = 750;
    bus.dut->rst = 1;
    bus.dut->restart = 0;
    bus.dut->scl_i = 1;
    bus.dut->sda_i = 1;
    for (int i = 0; i < 8; ++i) bus.Step();
    bus.dut->rst = 0;
    RunUntilSettled(bus, kBudget * 3);
    if (!bus.dut->configured) Fail("stretch: the program did not finish");
    if (bus.dut->writes != kEntries) Failf("stretch: `writes`", bus.dut->writes, kEntries);
    CheckRun(bus.an, 0, "the program over a stretched clock");
    if (bus.an.sda_edges_at_scl_edge != 0)
      Failf("stretch: moves of SDA at an edge of SCL", bus.an.sda_edges_at_scl_edge, 0);
    // **A STRETCH THAT NEVER HAPPENED WOULD TEST NOTHING**, so it is counted.
    stretches_seen = bus.slave.stretches;
    if (stretches_seen < 100)
      Failf("stretch: times the clock was held down", stretches_seen, 100);
    // And the clock must still be inside the bound with the stretch in it.
    const double khz = 1e6 / Ns(bus.an.worst_scl_period);
    if (khz * 1e3 > kSclMaxHz)
      Failf("stretch: SCL in Hz", (long)(khz * 1e3), (long)kSclMaxHz);
    delete bus.dut;
  }

  // ================================= 4. a byte the part does not acknowledge
  //
  // Refused on the second byte of the fifth write, which is a register byte
  // in the middle of the program: four writes must be through, the fifth
  // must stop where it was refused, and nothing may follow it.
  {
    const long kRefuseAt = 4 * 3 + 2;     // the 14th byte of the run
    Bus bus;
    bus.dut = new Vcadr_adv7513;
    bus.slave.ack_setup = 300;   // three microseconds after the fall
    bus.slave.ack_hold = 200;    // two microseconds after the next one
    bus.slave.nack_after_bytes = kRefuseAt;
    bus.dut->rst = 1;
    bus.dut->restart = 0;
    bus.dut->scl_i = 1;
    bus.dut->sda_i = 1;
    for (int i = 0; i < 8; ++i) bus.Step();
    bus.dut->rst = 0;
    RunUntilSettled(bus, kBudget);
    if (!bus.dut->failed) Fail("a refused byte did not raise `failed`");
    if (bus.dut->configured) Fail("a refused byte still reported `configured`");
    if (bus.dut->writes != 4) Failf("writes before the refusal", bus.dut->writes, 4);
    if (bus.an.nacks != 1) Failf("refusals seen on the bus", bus.an.nacks, 1);
    if ((long)bus.an.txns.size() != 5)
      Failf("transactions before the module gave up", (long)bus.an.txns.size(), 5);
    if (bus.an.stops != 5) Failf("stops, so the bus was released", bus.an.stops, 5);
    // The first four are whole, and the fifth stopped after two bytes.
    for (int i = 0; i < 4; ++i) {
      if (bus.an.txns[i].bytes.size() != 3)
        Failf("bytes in a whole write", (long)bus.an.txns[i].bytes.size(), 3);
    }
    if (bus.an.txns[4].bytes.size() != 2)
      Failf("bytes in the refused write", (long)bus.an.txns[4].bytes.size(), 2);
    if (!bus.an.txns[4].stopped) Fail("the refused write left the bus without a stop");
    // And nothing more.
    bus.an.watch_quiet = true;
    for (int i = 0; i < 40000; ++i) bus.Step();
    if (bus.an.moves_after_done != 0)
      Failf("moves of either line after a refusal", bus.an.moves_after_done, 0);
    // A restart must clear it and try again.
    bus.an.watch_quiet = false;
    bus.slave.nack_after_bytes = -1;
    bus.slave.bytes_seen = 0;
    const size_t before = bus.an.txns.size();
    bus.dut->restart = 1;
    bus.Step();
    bus.dut->restart = 0;
    if (bus.dut->failed) Fail("a restart did not clear `failed`");
    RunUntilSettled(bus, kBudget);
    if (!bus.dut->configured) Fail("a restart after a refusal did not finish the program");
    CheckRun(bus.an, before, "the program after a refusal and a restart");
    delete bus.dut;
  }

  if (bad) {
    std::fprintf(stderr, "FAIL: %d problems\n", bad);
    return 1;
  }
  std::printf(
      "ok: the ADV7513's configuration, read off the two wires.\n"
      "    %d register writes at 0x%02x, %d bytes, each its own transaction of a\n"
      "      start, three bytes with an acknowledge each and a stop, compared\n"
      "      byte for byte with this file's own transcription of the program;\n"
      "      the whole of it in %.2f ms of the fabric's clock.\n"
      "    the bus at %.1f kHz at its fastest, against the data sheet's %.0f kHz.\n"
      "    tDSU %.0f ns (asks %.0f), tDHO %.0f ns (asks %.0f), tSTASU %.0f ns\n"
      "      (asks %.0f), tSTAH %.0f ns (asks %.0f), tSTOSU %.0f ns (asks %.0f),\n"
      "      each the worst measured off the waveform.\n"
      "    no move of SDA at any edge of SCL, and neither line moves in the\n"
      "      %ld ticks after the program.\n"
      "    a clock stretched %ld times, followed; a refused byte stopping the\n"
      "      program with a stop on the bus, `failed` up and `configured` down;\n"
      "      and a restart running the whole program again.\n",
      kEntries, kWriteAddr, 3 * kEntries, Ns(program_ticks) / 1e6,
      worst_scl_khz, kSclMaxHz / 1e3,
      worst[0], kSdaSetupNs, worst[1], kSdaHoldNs, worst[2], kStartSetupNs,
      worst[3], kStartHoldNs, worst[4], kStopSetupNs,
      quiet_checked, stretches_seen);
  return 0;
}
