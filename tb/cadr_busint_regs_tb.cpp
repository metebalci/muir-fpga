// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `rtl/machine/cadr_busint_regs.sv` against muir's `busint::register` and
// `Machine::interface_read` and `interface_write`, at the Unibus.
//
// WHAT THIS CHECK IS FOR, AND WHAT `build/unibus.pass` CANNOT SAY.
//
// The composition check drives a cycle of the MACHINE's and holds the wiring:
// three slaves on one bus, `-UB SSYN` the OR of theirs, never two at once. It
// can afford a sweep of the three thousand addresses either side of the two
// blocks and no more, a cycle there being a hundred ticks or a nine-hundred
// tick timeout. This one drives the block alone, so a real bus cycle at every
// one of the 262,144 addresses in both directions is affordable --- and that
// is the claim worth making exhaustively, because within the interrupt block
// the 74S138 at 0E03 looks at address bits 2 and 1 alone and the four
// registers repeat every eight bytes. An aliasing decode is exactly what a
// hand transcription gets wrong.
//
// WHAT IT HOLDS TO.
//
//   - **The decode is `busint::register`, at every address**, out of the
//     trace's `IFACE` and `IFACENONE` rows. A register of the DIAGNOSTIC
//     kind must NOT be answered here: `cadr_spy_registers.sv` is that block
//     and this one must leave its thirty-two addresses alone, which is the
//     disjointness the composition then measures on the bus.
//   - **Every word is muir's own**, out of the `OP` rows: what a read gives
//     and what a write leaves behind, with the interrupt status and error
//     status registers read back after every row as the trace's face.
//   - **`-UB SSYN` is `busint::DIAGNOSTIC_NS` after `-UB MSYN`** and at no
//     earlier tick, and **a write lands at `REGISTER_STROBE_NS`** --- which
//     is asserted by running the same write twice with the strobe dropped a
//     tick early the first time and seeing that it did not land.
//   - **`UB INT` is `Machine::unibus_interrupt`**, at the port, on every row.
//
// WHAT IS DELIBERATELY NOT HERE.
//
//   - The Unibus map's read and write buffers, and `UB MAP ERROR`. Their one
//     master is the debug cable's and it is not built; the module's header
//     says the same.
//   - The debug block at `0o766100`-`0o766136`. `busint::register` decodes it
//     to nothing and the sweep holds this block to answering nothing there;
//     what answers it on a real machine is the cable.
//
// THE FACE IS READ BACK OVER THE BUS AND NOT OFF A PORT, which is the point
// of it: `0o766040` and `0o766044` are what a program sees, and the generator
// samples them with `Machine::bus_read` for the same reason. The one column
// that is a port is `ub_int`, because `SINTR` is a wire and not a register a
// program can read.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

#include "Vcadr_busint_regs.h"
#include "verilated.h"

namespace {

// MIT's grid, which every tick count in the fabric is measured in.
constexpr long kTickNs = 5;

// The eighteen-bit Unibus.
constexpr unsigned kAddrs = 1u << 18;

// `ffffffff` in a column that can be absent.
constexpr uint32_t kNone = 0xffffffffu;

// The six kinds, in the trace's own numbering.
enum Kind { kDiagnostic = 0, kIntCtl, kIntCtl2, kErrStatus, kUnwired, kMap, kNothing };

// `cadr_spy_registers.sv`'s block, which this one must not answer.
constexpr unsigned kSpyBase = 0766000u, kSpyTop = 0766040u;

// The two registers the face is read out of.
constexpr unsigned kCtlAddr = 0766040u, kErrAddr = 0766044u;

int bad = 0;
constexpr int kMaxBad = 20;

int Fail(long row, const char *what, unsigned long got, unsigned long want) {
  if (bad < kMaxBad)
    std::fprintf(stderr, "FAIL: row %ld: %s is 0x%lx (%lu), wanting 0x%lx (%lu)\n", row, what, got,
                 got, want, want);
  return 1;
}

enum Tag { kOp, kLines, kErr };

struct Row {
  Tag tag;
  long n;
  int write;
  unsigned uaddr;
  unsigned wdata;
  int xint, ireq;
  unsigned ivec;
  uint32_t rdata;
  int which;      // ERR: 0 an Xbus cycle, 1 a Unibus one
  uint32_t ctl, err, ubint;
  int lm_int;
};

struct Dut {
  Vcadr_busint_regs *d;
  long tick = 0;

  Dut() : d(new Vcadr_busint_regs) {
    d->clk = 0;
    d->rst = 1;
    d->ub_msyn = 0;
    d->ub_write = 0;
    d->ub_addr = 0;
    d->ub_wdata = 0;
    d->xbus_intr = 0;
    d->iob_intr = 0;
    d->iob_vector = 0;
    d->timed_out = 0;
    d->unibus = 0;
    d->eval();
  }
  ~Dut() {
    d->final();
    delete d;
  }
  void Step() {
    d->rst = (tick == 0);
    d->clk = 1;
    d->eval();
    d->clk = 0;
    d->eval();
    ++tick;
  }
  void Idle(long n) {
    for (long k = 0; k < n; ++k) Step();
  }
};

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *path = (argc > 1) ? argv[1] : "build/busint_regs.golden";

  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "FAIL: cannot read %s\n", path);
    return 2;
  }

  std::vector<uint8_t> table(kAddrs, kNothing);
  std::vector<uint8_t> regno(kAddrs, 0);
  std::vector<uint8_t> covered(kAddrs, 0);
  std::vector<Row> rows;
  long iface_rows = 0, none_runs = 0;
  long want_ssyn_ns = -1, want_strobe_ns = -1, want_bits = -1;
  long want_ops = -1, want_errs = -1, want_lines = -1;
  unsigned want_ctl_mask = 0, want_ctl2_mask = 0, want_local = 0;
  char line[512];
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#') {
      char name[64];
      long v;
      if (std::sscanf(line, "# %63s %ld", name, &v) == 2) {
        if (!std::strcmp(name, "diagnostic_ns")) want_ssyn_ns = v;
        if (!std::strcmp(name, "register_strobe_ns")) want_strobe_ns = v;
        if (!std::strcmp(name, "ub_address_bits")) want_bits = v;
        if (!std::strcmp(name, "ops")) want_ops = v;
        if (!std::strcmp(name, "errs")) want_errs = v;
        if (!std::strcmp(name, "lines_rows")) want_lines = v;
        // The three masks are octal in the header, as MIT writes them.
        if (!std::strcmp(name, "control_mask")) want_ctl_mask = strtoul(line + 15, nullptr, 8);
        if (!std::strcmp(name, "control2_mask")) want_ctl2_mask = strtoul(line + 16, nullptr, 8);
        if (!std::strcmp(name, "local_enable")) want_local = strtoul(line + 15, nullptr, 8);
      }
      continue;
    }
    unsigned a, b, k, n;
    Row r;
    std::memset(&r, 0, sizeof r);
    if (std::sscanf(line, "IFACENONE %x %x", &a, &b) == 2) {
      if (b >= kAddrs) {
        std::fprintf(stderr, "FAIL: %s: an IFACENONE run ends at 0x%x, past the address space\n",
                     path, b);
        return 2;
      }
      for (unsigned u = a; u <= b; ++u) covered[u] = 1;
      ++none_runs;
    } else if (std::sscanf(line, "IFACE %x %x %x", &a, &k, &n) == 3) {
      if (a >= kAddrs || k > kMap) {
        std::fprintf(stderr, "FAIL: %s: an IFACE row names 0x%x kind %u\n", path, a, k);
        return 2;
      }
      table[a] = (uint8_t)k;
      regno[a] = (uint8_t)n;
      covered[a] = 1;
      ++iface_rows;
    } else if (std::sscanf(line, "OP %ld %d %o %x %d %d %x %x %x %x %x %d", &r.n, &r.write,
                           &r.uaddr, &r.wdata, &r.xint, &r.ireq, &r.ivec, &r.rdata, &r.ctl, &r.err,
                           &r.ubint, &r.lm_int) == 12) {
      r.tag = kOp;
      rows.push_back(r);
    } else if (std::sscanf(line, "LINES %ld %d %d %x %x %x %x %d", &r.n, &r.xint, &r.ireq, &r.ivec,
                           &r.ctl, &r.err, &r.ubint, &r.lm_int) == 8) {
      r.tag = kLines;
      rows.push_back(r);
    } else if (std::sscanf(line, "ERR %ld %d %x %x %x %d", &r.n, &r.which, &r.ctl, &r.err, &r.ubint,
                           &r.lm_int) == 6) {
      r.tag = kErr;
      rows.push_back(r);
    }
  }
  std::fclose(f);

  if (want_bits != 18 || want_ssyn_ns <= 0 || want_strobe_ns <= 0) {
    std::fprintf(stderr,
                 "FAIL: %s says ub_address_bits %ld, diagnostic_ns %ld, register_strobe_ns %ld\n",
                 path, want_bits, want_ssyn_ns, want_strobe_ns);
    return 2;
  }
  if (!want_ctl_mask || !want_ctl2_mask || !want_local) {
    std::fprintf(stderr, "FAIL: %s carries no write masks, which are what a write claim is\n", path);
    return 2;
  }
  for (unsigned u = 0; u < kAddrs; ++u)
    if (!covered[u]) {
      std::fprintf(stderr, "FAIL: %s leaves 0x%x undecided\n", path, u);
      return 2;
    }
  long counted[kNothing + 1] = {0};
  for (unsigned u = 0; u < kAddrs; ++u) counted[table[u]]++;
  if (counted[kDiagnostic] != 32 || counted[kMap] != 31) {
    std::fprintf(stderr, "FAIL: %s decodes %ld diagnostic and %ld map addresses, wanting 32 and 31\n",
                 path, counted[kDiagnostic], counted[kMap]);
    return 2;
  }
  // The diagnostic block is the other slave's, and must be exactly the range
  // `cadr_spy_registers.sv` matches: if muir ever moved it, this file's idea
  // of which addresses this block must leave alone would be wrong.
  for (unsigned u = 0; u < kAddrs; ++u) {
    const bool spy = (u >= kSpyBase && u < kSpyTop);
    if (spy != (table[u] == kDiagnostic)) {
      std::fprintf(stderr,
                   "FAIL: 0%o: the trace says kind %d and cadr_spy_registers.sv's own base says %s\n",
                   u, table[u], spy ? "diagnostic" : "not");
      return 2;
    }
  }
  if ((long)rows.size() != want_ops + want_errs + want_lines) {
    std::fprintf(stderr, "FAIL: %s says %ld + %ld + %ld rows and this read %zu\n", path, want_ops,
                 want_errs, want_lines, rows.size());
    return 2;
  }

  const long kSsynT = want_ssyn_ns / kTickNs;
  const long kStrobeT = want_strobe_ns / kTickNs;

  Dut b;
  b.Idle(4);

  // One bus cycle. The address goes up with the strobe, as the generator's
  // master does --- it has no setup at all --- and the held match is a tick
  // behind it, which is forty-nine ticks before the answer is due.
  //
  // `hold` is how many ticks past `-UB MSYN` the strobe stands. A cycle this
  // block answers is ended one tick after `-UB SSYN`; the two callers that
  // want a shorter one say so.
  struct Result {
    long ssyn = -1;
    uint32_t word = 0;
    int answered = 0;
  };
  auto Run = [&](unsigned uaddr, int write, unsigned wdata, long hold) {
    Result res;
    b.d->ub_addr = uaddr;
    b.d->ub_write = write;
    b.d->ub_wdata = wdata;
    b.d->ub_msyn = 1;
    for (long k = 0; k < hold; ++k) {
      b.Step();
      if (b.d->ub_ssyn && res.ssyn < 0) {
        res.ssyn = k;
        res.answered = 1;
        res.word = b.d->ub_rdata;
        // One more tick with the strobe up, as a master holds it, and then
        // the cycle ends: the word is taken at `-UB SSYN`.
        b.Step();
        break;
      }
    }
    b.d->ub_msyn = 0;
    // The bus idles between cycles: a slave's state is its own cycle's.
    b.Idle(3);
    return res;
  };

  // A read that must be answered, with its word. The two face reads go
  // through here too.
  long answered = 0;
  auto ReadReg = [&](unsigned uaddr, long row, const char *what) -> uint32_t {
    const Result r = Run(uaddr, 0, 0, kSsynT + 40);
    if (!r.answered) {
      bad += Fail(row, what, 0, 1);
      return 0;
    }
    ++answered;
    if (r.ssyn != kSsynT)
      bad += Fail(row, "-UB SSYN, in ticks after -UB MSYN", (unsigned long)r.ssyn,
                  (unsigned long)kSsynT);
    return r.word;
  };

  // ---- the rows ------------------------------------------------------------
  long ops = 0, errs = 0, lines = 0, faces = 0, writes = 0, reads = 0;
  for (const Row &r : rows) {
    if (bad >= kMaxBad) break;
    // The three wires, which every row carries and which move only on a
    // `LINES` row: driven before whatever the row does and held through it,
    // as a level on a backplane and on a cable is.
    if (r.tag != kErr) {
      b.d->xbus_intr = r.xint;
      b.d->iob_intr = r.ireq;
      b.d->iob_vector = r.ivec;
    }
    switch (r.tag) {
      case kLines:
        ++lines;
        b.Idle(2);
        break;
      case kOp: {
        ++ops;
        const Result got = Run(r.uaddr, r.write, r.wdata, kSsynT + 40);
        if (!got.answered) {
          bad += Fail(r.n, "-UB SSYN on a register the block answers", 0, 1);
          break;
        }
        ++answered;
        if (got.ssyn != kSsynT)
          bad += Fail(r.n, "-UB SSYN, in ticks after -UB MSYN", (unsigned long)got.ssyn,
                      (unsigned long)kSsynT);
        if (r.write) {
          ++writes;
        } else {
          ++reads;
          if (got.word != r.rdata) bad += Fail(r.n, "the word", got.word, r.rdata);
        }
        break;
      }
      case kErr: {
        ++errs;
        // `NXM TIMEOUT` is a level standing for the cycle it belongs to, and
        // `unibus` is the held decode beside it. The module takes the rise.
        b.d->unibus = r.which;
        b.d->timed_out = 1;
        b.Idle(6);
        b.d->timed_out = 0;
        b.d->unibus = 0;
        b.Idle(2);
        break;
      }
    }
    if (bad >= kMaxBad) break;
    // The face, read back over the bus exactly as the generator reads it.
    const uint32_t ctl = ReadReg(kCtlAddr, r.n, "-UB SSYN reading 766040 for the face");
    const uint32_t err = ReadReg(kErrAddr, r.n, "-UB SSYN reading 766044 for the face");
    if (ctl != r.ctl) bad += Fail(r.n, "the interrupt status register", ctl, r.ctl);
    if (err != r.err) bad += Fail(r.n, "the error status register", err, r.err);
    const int want_ub = (r.ubint != kNone);
    if (b.d->ub_int != want_ub) bad += Fail(r.n, "UB INT", b.d->ub_int, want_ub);
    // `LM INT` is `UB INT OR XBUS INTR IN` at UBINTC 0E04, which
    // `cadr_machine.sv` makes of this port and the Xbus line. Held here so
    // that the composition's one line has a reference of its own.
    const int lm = b.d->ub_int || b.d->xbus_intr;
    if (lm != r.lm_int) bad += Fail(r.n, "LM INT", lm, r.lm_int);
    // The vector the interface is asking with, which the handler reads back
    // out of bits 2 to 9. It is in `ctl` above and compared with it; this is
    // the assertion that the trace's own two columns agree, so that a row
    // where they did not would stop the run rather than pass twice.
    if (want_ub && ((r.ubint & 01774u) != (r.ctl & 01774u)))
      bad += Fail(r.n, "the trace's own vector, ubint against ctl", r.ubint & 01774u,
                  r.ctl & 01774u);
    ++faces;
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", bad, b.tick);
    return 1;
  }

  // ---- the write lands at REGISTER_STROBE_NS and not at the answer ---------
  //
  // A mutation cannot reach a testbench, so the instant is tested with a DUT
  // cycle just either side of it: the same write run with the strobe dropped
  // one tick before the strobe instant must NOT land, and run to the strobe
  // instant must. Nothing else in this file can tell `REGISTER_STROBE_NS`
  // from `DIAGNOSTIC_NS`, which is `RD_FINISH_T` all over again.
  {
    // A word in the map, which is the register with the widest write.
    Run(0766140, 1, 0x1234, kSsynT + 40);
    if (ReadReg(0766140, -1, "the map register before the short write") != 0x1234u)
      bad += Fail(-1, "the map register before the short write", 0, 0x1234);
    Run(0766140, 1, 0x5678, kStrobeT);        // the strobe falls a tick early
    if (ReadReg(0766140, -1, "the map register after the short write") != 0x1234u)
      bad += Fail(-1, "a write whose strobe fell a tick before the strobe instant", 0x5678, 0x1234);
    Run(0766140, 1, 0x5678, kStrobeT + 1);    // and one tick longer
    if (ReadReg(0766140, -1, "the map register after the strobe") != 0x5678u)
      bad += Fail(-1, "a write held exactly to the strobe instant", 0x1234, 0x5678);
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", bad, b.tick);
    return 1;
  }

  // ---- the map's sixteen, at all thirty-one of their addresses -------------
  //
  // Bit 0 of a Unibus address is decoded nowhere in the block, so `0o766141`
  // is `0o766140`. Nothing in the machine can reach an odd address --- the
  // master's `UAO<17:1>` drop bit 0 --- but the decode still has to agree
  // with muir at one, and this is where an aliasing read or write shows.
  //
  // The register a trace address names is `regno`, which is muir's own
  // `Register::Map(n)` and not this file's arithmetic. The word is a poison
  // injective in the register number with a high and a low bit both moving,
  // so that an address off by one and a word off by one do not look alike.
  auto MapPoison = [](unsigned k) -> unsigned { return (0x3C00u ^ (k * 0x1111u) ^ (k << 8)) & 0xFFFFu; };
  long aliases = 0;
  for (unsigned k = 0; k < 16 && bad < kMaxBad; ++k) Run(0766140 + 2 * k, 1, MapPoison(k), kSsynT + 40);
  for (unsigned u = 0766140; u <= 0766176 && bad < kMaxBad; ++u) {
    if (table[u] != kMap) {
      bad += Fail((long)u, "the trace's kind for an address inside the map", table[u], kMap);
      continue;
    }
    const uint32_t got = ReadReg(u, (long)u, "-UB SSYN reading a map address");
    if (got != MapPoison(regno[u]))
      bad += Fail((long)u, "the map word at this address", got, MapPoison(regno[u]));
    ++aliases;
  }
  // And a WRITE at each of the thirty-one, read back at the even address of
  // the register muir says it names.
  for (unsigned u = 0766140; u <= 0766176 && bad < kMaxBad; ++u) {
    const unsigned k = regno[u];
    const unsigned v = (MapPoison(k) ^ 0xA55Au) & 0xFFFFu;
    Run(u, 1, v, kSsynT + 40);
    const uint32_t got = ReadReg(0766140 + 2 * k, (long)u, "-UB SSYN reading the map back");
    if (got != v) bad += Fail((long)u, "a write at this address landed elsewhere", got, v);
    Run(0766140 + 2 * k, 1, MapPoison(k), kSsynT + 40);
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", bad, b.tick);
    return 1;
  }

  // ---- the decode, at every address, read and written ----------------------
  //
  // A real bus cycle each. What must be answered is what `busint::register`
  // decodes to anything but a diagnostic register; the diagnostic block is
  // `cadr_spy_registers.sv`'s and this one must leave it alone.
  //
  // **This half is the decode and nothing else, and the writes it runs are
  // let through on purpose.** A sweep that refused to write could not tell a
  // decode that answers a read and not a write; one that wrote and then
  // compared would be 262,144 writes into twenty registers, and what it read
  // back would be the last address swept rather than the one asked about.
  // The words are the rows' business and the aliasing the section above's;
  // the registers are left wherever this leaves them, nothing following.
  b.d->xbus_intr = 0;
  b.d->iob_intr = 0;
  b.d->iob_vector = 0;
  long swept = 0, swept_answered = 0, swept_silent = 0;
  long by_kind[kNothing + 1] = {0};
  for (unsigned u = 0; u < kAddrs && bad < kMaxBad; ++u) {
    for (int w = 0; w < 2; ++w) {
      const int kind = table[u];
      const bool want = (kind != kNothing && kind != kDiagnostic);
      // A cycle nothing answers is held well past the instant an answer would
      // be due, so that "it did not answer" is a measurement and not a race.
      const Result got = Run(u, w, 0x5A5Au, want ? kSsynT + 40 : kSsynT + 20);
      ++swept;
      if (got.answered != (int)want) {
        bad += Fail((long)u, w ? "answering a write" : "answering a read", got.answered, want);
        continue;
      }
      if (want) {
        ++swept_answered;
        by_kind[kind]++;
        if (got.ssyn != kSsynT)
          bad += Fail((long)u, "-UB SSYN, in ticks after -UB MSYN", (unsigned long)got.ssyn,
                      (unsigned long)kSsynT);
      } else {
        ++swept_silent;
      }
    }
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", bad, b.tick);
    return 1;
  }

  // ---- what the run reached ------------------------------------------------
  int thin = 0;
  auto least = [&](const char *what, long got, long want) {
    if (got < want) {
      std::fprintf(stderr, "FAIL: the run reached %ld %s and cannot hold anything with fewer\n", got,
                   what);
      ++thin;
    }
  };
  least("register cycles from the trace", ops, 200);
  least("reads compared against muir's word", reads, 100);
  least("writes", writes, 50);
  least("timeouts", errs, 8);
  least("rows whose face was compared", faces, 200);
  least("map addresses read back through the aliasing", aliases, 31);
  for (int k = kIntCtl; k <= kMap; ++k)
    least("addresses of one of the four kinds answered in the sweep", by_kind[k], 7);
  if (swept != 2 * (long)kAddrs) {
    std::fprintf(stderr, "FAIL: the sweep ran %ld cycles over %u addresses in two directions\n",
                 swept, kAddrs);
    ++thin;
  }
  if (thin) return 1;

  std::printf(
      "ok: %ld ticks, agree with muir's busint::register and Machine::interface_read and\n"
      "    interface_write at the Unibus.  %ld register cycles replayed --- %ld reads compared\n"
      "    against muir's word and %ld writes --- and %ld timeouts, each followed by a read of\n"
      "    0766040 and 0766044 off the bus: %ld faces compared, the interrupt status register,\n"
      "    the error status register, UB INT at the port and LM INT made of it.\n"
      "    -UB SSYN is %ld ticks after -UB MSYN on every one of %ld answered cycles and at no\n"
      "    earlier tick, and a write lands at %ld: the same write with the strobe dropped one\n"
      "    tick before that instant does not take, which is the only thing here that can tell\n"
      "    the two constants apart.\n"
      "    All %ld addresses of the Unibus map were read and written, the odd ones among them:\n"
      "    bit 0 is decoded nowhere in the block, so each is the even address below it, and the\n"
      "    register a word landed in is muir's own Register::Map(n) and not this file's sum.\n"
      "    The decode: %ld cycles over all %u addresses read and written, %ld answered and %ld\n"
      "    silent, against busint::register out of %s (%ld IFACE rows and %ld IFACENONE runs).\n"
      "    The 32 addresses of the DIAGNOSTIC block are among the silent: they are\n"
      "    cadr_spy_registers.sv's, and so are the debug block's, which answers over a cable.\n",
      b.tick, ops, reads, writes, errs, faces, kSsynT, answered, kStrobeT, aliases, swept, kAddrs,
      swept_answered, swept_silent, path, iface_rows, none_runs);
  return 0;
}
