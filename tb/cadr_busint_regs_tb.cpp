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
//   - **The mapped window at `0o140000`-`0o177777`**, out of the `MAP` rows
//     and `busint::map_access`: what a Unibus master that is not this board
//     reaches through the sixteen map registers. Four claims, each with the
//     muir function it comes from:
//       * the responder is `Rtl::try_debug_request`'s --- the buffer, the
//         Xbus, a refusal or a write of `MD` --- and the last two are never
//         acknowledged, which is measured by holding the cycle far past the
//         instant an answer would be due;
//       * the physical address is `Machine::map_entry`'s page with
//         `UBA<9:2>` under it, and the word that crosses is
//         `Machine::mapped_write`'s;
//       * a read's low half is the answer and its high half goes into the
//         page's read buffer, which is `Machine::mapped_read`;
//       * `UB MAP ERROR` is bit 5 of the error status register, which the
//         face of every row carries.
//     The instants are `busint::UB_XBUS_REQUEST_NS` from `-UB MSYN` to the
//     request and `busint::UB_XBUS_READ_ACK_NS` from the acknowledgment to
//     `-UB SSYN` on a read, with it on a write. **The Xbus behind the window
//     answers at a latency that moves from cycle to cycle**, so a block that
//     counted ticks from the strobe rather than watching the acknowledgment
//     could not pass; and it holds the poison `golden/src/busint_regs.rs`
//     puts in muir's own memory, computed here from the address THE FABRIC
//     puts out, so a translation one page or one word wide takes a word muir
//     never had.
//   - **And the whole window at every address in both directions of
//     `ub_foreign`**: silent for the board's own cycle, because
//     `busint::decode` answers `Responder::NoUnibus` there; answered for a
//     foreign master's, at the register and the word the `MAPA` and
//     `MAPSWEEP` rows name.
//
// WHAT IS DELIBERATELY NOT HERE.
//
//   - `MD` itself. `Responder::MapMd` is built now: the `MAPMD` rows hold
//     the request, the thirty-two lines and `-LOADMD ACK`'s instant at this
//     block's own seam, and the register the word lands in is a level up.
//     `build/unibus.pass` carries it through the arbiter to
//     `cadr_memory_path`'s port and `build/md_compose.pass` holds the
//     register itself, on a machine that is still running --- MD having a
//     third writer now, and that being where it lives.
//   - A read through a page whose high five bits are ones reaching `MD`. It
//     does not: `Rtl::try_debug_request` tests `req.write` first, so the odd
//     word of a read is the page's read buffer and the even word a mapped
//     Xbus cycle at physical page `0o37000`, which muir does not model. `MD` is
//     write-only through the map and the trace's last two `MAP` rows say so.
//   - A mapped page that is not main memory. `Busint::debug_xbus_edge` says
//     in its own words that one is **not modeled**, so no row asks for one.
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
#include <map>
#include <string>
#include <vector>

#include "Vcadr_busint_regs.h"
#include "verilated.h"
#include "cadr_tick.h"

namespace {

// MIT's grid, which every tick count in the fabric is measured in.
constexpr long kTickNs = kGridNs;

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

// What `Rtl::try_debug_request` answered a mapped cycle, in the trace's own
// numbering.
enum Resp { kBuffer = 0, kXbus, kRefused, kMd };

// `golden/src/busint_regs.rs`'s own poison, which muir's main memory holds at
// every address this program reaches. Multiplication by an odd constant is a
// bijection on 32 bits, so no two words are the same and a read the map sent
// one page or one word wide takes a word muir never had. **The two functions
// are compared and not assumed equal**: every `MAP` row whose responder is
// the Xbus carries muir's own word, and this one is checked against it.
uint32_t Poison(uint32_t phys) {
  return ((phys ^ 0x00155555u) * 0x9E377969u) ^ 0x5A5A5A5Au;
}

int bad = 0;
constexpr int kMaxBad = 20;

int Fail(long row, const char *what, unsigned long got, unsigned long want) {
  if (bad < kMaxBad)
    std::fprintf(stderr, "FAIL: row %ld: %s is 0x%lx (%lu), wanting 0x%lx (%lu)\n", row, what, got,
                 got, want, want);
  return 1;
}

enum Tag { kOp, kLines, kErr, kMapCyc, kMapMd };

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
  int resp;       // MAP: which of the four responders
  uint32_t phys;  // MAP: the physical word address, or kNone
  uint32_t xword; // MAP: the thirty-two bits that crossed, or kNone
  uint32_t md32;  // MAPMD: the thirty-two bits Machine::mapped_write put in MD
  uint32_t md;    // MAPMD: MD itself afterwards
  uint32_t ctl, err, ubint;
  int lm_int;
};

struct Dut {
  Vcadr_busint_regs *d;
  long tick = 0;

  // The Xbus behind the mapped window. A word is the poison unless something
  // wrote it, and the key is the address THE FABRIC PUT OUT --- which is the
  // point of the poison being injective: the expected word comes from the
  // trace, so a wrong address is a wrong word rather than a consistent lie.
  std::map<uint32_t, uint32_t> mem;
  uint32_t MemRead(uint32_t a) {
    auto it = mem.find(a);
    return it == mem.end() ? Poison(a) : it->second;
  }
  void MemWrite(uint32_t a, uint32_t v) { mem[a] = v; }

  Dut() : d(new Vcadr_busint_regs) {
    d->clk = 0;
    d->rst = 1;
    d->ub_msyn = 0;
    d->ub_write = 0;
    d->ub_addr = 0;
    d->ub_wdata = 0;
    d->ub_foreign = 0;
    d->map_done = 0;
    d->map_rdata = 0;
    d->map_md_done = 0;
    d->xbus_intr = 0;
    d->iob_intr = 0;
    d->iob_vector = 0;
    d->timed_out = 0;
    d->unibus = 0;
    // The debug cable's DBGOUT end: an unplugged connector, which is muir's
    // `debug_cable` false.  The lines read as ones because nothing drives
    // them --- `cadr_dbg_cable.sv` resolves an undriven byte against the far
    // end's pull-ups and there is no far end.  A check that drove zeros here
    // would be handing the block a value the cable cannot produce.
    d->dbgout_ack = 0;
    d->dbgout_dbd_in = 0xFFFF;
    d->dbgout_live = 0;
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

// One cycle of the debugger's own into the debug block, as the trace's
// `DBGOUT` rows carry it: every instant in nanoseconds from the same
// power-on, so the fabric's own can be compared as intervals.
struct DbgRow {
  long n = 0;
  int cable = 0;
  int write = 0;
  unsigned strobe = 0;
  unsigned wdata = 0;
  long grant_ns = 0;
  long msyn_ns = 0;
  long req_ns = -1;
  long ans_ns = -1;
  long ssyn_ns = 0;
  long memack_ns = 0;
  int timed_out = 0;
  int taken = 0;
};

// `chip::VCO_PERIOD`, the REQTIM oscillator's 850 ns.  It is here only to
// size the phase table the trace fills; every value in it is muir's.
constexpr long kVcoPeriodNs = 850;

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
  // The mapped window, out of the `MAPA` and `MAPANONE` rows: whether the
  // address is one, and `busint::MapAccess`'s three fields where it is.
  std::vector<uint8_t> in_win(kAddrs, 0);
  std::vector<uint8_t> win_page(kAddrs, 0);
  std::vector<uint8_t> win_word(kAddrs, 0);
  std::vector<uint8_t> win_high(kAddrs, 0);
  std::vector<uint8_t> win_covered(kAddrs, 0);
  // The sixteen entries the window's exhaustive sweep runs against, and the
  // physical page `Machine::map_entry` reads out of each.
  unsigned sweep_entry[16] = {0};
  uint32_t sweep_page[16] = {0};
  int sweep_seen = 0;
  std::vector<Row> rows;
  // The debug block, out of the trace's APPENDED rows: which strobe each of
  // its thirty-two addresses puts on the cable, how long after the grant the
  // interface gives up at each phase of the REQTIM oscillator, and the cycles
  // muir's own `busint::Busint` ran.
  std::vector<int8_t> dbg(kAddrs, -1);
  std::vector<long> dbg_tmo(kVcoPeriodNs, -1);
  std::vector<DbgRow> dbg_rows_cyc;
  long dbg_rows = 0, dbg_tmo_rows = 0;
  long want_dbg_req_ns = -1, want_dbg_tmo_ns = -1, want_ub_strobe_ns = -1;
  long want_dbg_regs = -1, want_dbg_cycles = -1;
  unsigned want_dbg_low = 0, want_dbg_high = 0;
  long iface_rows = 0, none_runs = 0, win_rows = 0, win_runs = 0;
  long want_ssyn_ns = -1, want_strobe_ns = -1, want_bits = -1;
  long want_rq_ns = -1, want_read_ack_ns = -1, want_map_error = -1;
  long want_md_ack_ns = -1, want_md_writes = -1;
  long want_ops = -1, want_errs = -1, want_lines = -1, want_maps = -1;
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
        if (!std::strcmp(name, "maps")) want_maps = v;
        if (!std::strcmp(name, "ub_xbus_request_ns")) want_rq_ns = v;
        if (!std::strcmp(name, "ub_xbus_read_ack_ns")) want_read_ack_ns = v;
        if (!std::strcmp(name, "ub_md_ack_ns")) want_md_ack_ns = v;
        if (!std::strcmp(name, "md_writes")) want_md_writes = v;
        if (!std::strcmp(name, "debug_out_request_ns")) want_dbg_req_ns = v;
        if (!std::strcmp(name, "debug_timeout_ns")) want_dbg_tmo_ns = v;
        if (!std::strcmp(name, "unibus_strobe_ns")) want_ub_strobe_ns = v;
        if (!std::strcmp(name, "dbg_regs")) want_dbg_regs = v;
        if (!std::strcmp(name, "dbg_cycles")) want_dbg_cycles = v;
        // Octal in the header, as every Unibus address in this trace is.
        if (!std::strcmp(name, "dbg_low")) want_dbg_low = strtoul(line + 10, nullptr, 8);
        if (!std::strcmp(name, "dbg_high")) want_dbg_high = strtoul(line + 11, nullptr, 8);
        // Octal in the header, as muir writes `bus_error`'s bits.
        if (!std::strcmp(name, "ub_map_error")) want_map_error = strtoul(line + 15, nullptr, 8);
        // The three masks are octal in the header, as MIT writes them.
        if (!std::strcmp(name, "control_mask")) want_ctl_mask = strtoul(line + 15, nullptr, 8);
        if (!std::strcmp(name, "control2_mask")) want_ctl2_mask = strtoul(line + 16, nullptr, 8);
        if (!std::strcmp(name, "local_enable")) want_local = strtoul(line + 15, nullptr, 8);
      }
      continue;
    }
    unsigned a, b, k, n;
    {
      unsigned du, ds;
      long dn, dcab, dwr, dstr, dgrant, dmsyn, dssyn, dmemack, dto, dtaken;
      unsigned long dwdata, dreq, dans;
      if (std::sscanf(line, "DBGREG %o %u", &du, &ds) == 2) {
        if (du >= kAddrs || ds > 3) {
          std::fprintf(stderr, "FAIL: %s: a DBGREG row names 0%o strobe %u\n", path, du, ds);
          return 2;
        }
        dbg[du] = (int8_t)ds;
        ++dbg_rows;
        continue;
      }
      if (std::sscanf(line, "DBGTMO %ld %ld", &dn, &dgrant) == 2) {
        dbg_tmo[dn] = dgrant;
        ++dbg_tmo_rows;
        continue;
      }
      if (std::sscanf(line, "DBGOUT %ld %ld %ld %ld %lx %ld %ld %lu %lu %ld %ld %ld %ld", &dn,
                      &dcab, &dwr, &dstr, &dwdata, &dgrant, &dmsyn, &dreq, &dans, &dssyn,
                      &dmemack, &dto, &dtaken) == 13) {
        DbgRow d;
        d.n = dn;
        d.cable = (int)dcab;
        d.write = (int)dwr;
        d.strobe = (unsigned)dstr;
        d.wdata = (unsigned)dwdata;
        d.grant_ns = dgrant;
        d.msyn_ns = dmsyn;
        d.req_ns = (dreq == 0xffffffffu) ? -1 : (long)dreq;
        d.ans_ns = (dans == 0xffffffffu) ? -1 : (long)dans;
        d.ssyn_ns = dssyn;
        d.memack_ns = dmemack;
        d.timed_out = (int)dto;
        d.taken = (int)dtaken;
        dbg_rows_cyc.push_back(d);
        continue;
      }
    }
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
    } else if (std::sscanf(line, "MAPANONE %x %x", &a, &b) == 2) {
      if (b >= kAddrs) {
        std::fprintf(stderr, "FAIL: %s: a MAPANONE run ends at 0x%x, past the address space\n",
                     path, b);
        return 2;
      }
      for (unsigned u = a; u <= b; ++u) win_covered[u] = 1;
      ++win_runs;
    } else if (std::sscanf(line, "MAPA %x %x %x %u", &a, &k, &n, &b) == 4) {
      if (a >= kAddrs || k > 15 || n > 255 || b > 1) {
        std::fprintf(stderr, "FAIL: %s: a MAPA row names 0x%x page %u word %u high %u\n", path, a,
                     k, n, b);
        return 2;
      }
      in_win[a] = 1;
      win_page[a] = (uint8_t)k;
      win_word[a] = (uint8_t)n;
      win_high[a] = (uint8_t)b;
      win_covered[a] = 1;
      ++win_rows;
    } else if (std::sscanf(line, "MAPSWEEP %x %x %x", &k, &a, &b) == 3) {
      if (k > 15) {
        std::fprintf(stderr, "FAIL: %s: a MAPSWEEP row names register %u\n", path, k);
        return 2;
      }
      sweep_entry[k] = a;
      sweep_page[k] = b;
      ++sweep_seen;
    } else if (std::sscanf(line, "MAPMD %ld %d %o %x %d %d %x %x %x %x %x %x %d", &r.n,
                           &r.write, &r.uaddr, &r.wdata, &r.xint, &r.ireq, &r.ivec, &r.md32,
                           &r.md, &r.ctl, &r.err, &r.ubint, &r.lm_int) == 13) {
      // Every row of this tag is `Responder::MapMd`: the generator asserts
      // it and there is no column for it.
      r.tag = kMapMd;
      r.resp = kMd;
      r.phys = kNone;
      r.xword = kNone;
      r.rdata = kNone;
      rows.push_back(r);
    } else if (std::sscanf(line, "MAP %ld %d %o %x %d %d %x %d %x %x %x %x %x %x %d", &r.n,
                           &r.write, &r.uaddr, &r.wdata, &r.xint, &r.ireq, &r.ivec, &r.resp,
                           &r.phys, &r.xword, &r.rdata, &r.ctl, &r.err, &r.ubint,
                           &r.lm_int) == 15) {
      r.tag = kMapCyc;
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
  if ((long)rows.size() != want_ops + want_errs + want_lines + want_maps) {
    std::fprintf(stderr, "FAIL: %s says %ld + %ld + %ld + %ld rows and this read %zu\n", path,
                 want_ops, want_errs, want_lines, want_maps, rows.size());
    return 2;
  }
  if (want_rq_ns <= 0 || want_read_ack_ns <= 0 || want_map_error <= 0 || sweep_seen != 16) {
    std::fprintf(stderr,
                 "FAIL: %s says ub_xbus_request_ns %ld, ub_xbus_read_ack_ns %ld, ub_map_error %ld "
                 "and carries %d of the sweep's sixteen entries\n",
                 path, want_rq_ns, want_read_ack_ns, want_map_error, sweep_seen);
    return 2;
  }
  // `busint::UB_MD_ACK_NS`, which is a different constant from
  // `UB_XBUS_READ_ACK_NS` however equal the two happen to be today: one is
  // `-LOADMD ACK` after the load and the other `-UB SSYN` after `-UBACK`.
  if (want_md_ack_ns <= 0 || want_md_writes <= 0) {
    std::fprintf(stderr, "FAIL: %s says ub_md_ack_ns %ld and md_writes %ld\n", path,
                 want_md_ack_ns, want_md_writes);
    return 2;
  }
  // The window's own coverage, the same claim `covered` makes for the decode:
  // every address is either inside `busint::map_access`'s range or in a run
  // that says it is not.
  for (unsigned u = 0; u < kAddrs; ++u)
    if (!win_covered[u]) {
      std::fprintf(stderr, "FAIL: %s leaves 0x%x undecided in the window\n", path, u);
      return 2;
    }
  if (win_rows != 16 * 256 * 2 * 2) {
    std::fprintf(stderr, "FAIL: %s decodes %ld addresses into the window, wanting %d\n", path,
                 win_rows, 16 * 256 * 2 * 2);
    return 2;
  }
  // The window and the two register groups are disjoint. A block that
  // answered an address as both would answer the wrong one of them, and the
  // sweeps below would then be measuring against a trace that had already
  // agreed with it.
  for (unsigned u = 0; u < kAddrs; ++u)
    if (in_win[u] && table[u] != kNothing) {
      std::fprintf(stderr, "FAIL: 0%o is in the window and is register kind %d\n", u, table[u]);
      return 2;
    }

  // ---- the debug block, out of the APPENDED rows ---------------------------
  //
  // The trace must carry all of it or this file cannot hold the block to
  // anything: thirty-two addresses, a phase for every 5 ns of the
  // oscillator's period, and cycles of both outcomes.
  if (dbg_rows != want_dbg_regs || dbg_rows != 32 || want_dbg_req_ns <= 0 ||
      want_dbg_tmo_ns <= 0 || want_ub_strobe_ns <= 0 || want_dbg_low == 0 ||
      want_dbg_high <= want_dbg_low || (long)dbg_rows_cyc.size() != want_dbg_cycles ||
      want_dbg_cycles < 4) {
    std::fprintf(stderr,
                 "FAIL: %s carries %ld DBGREG rows (wanting %ld), %zu DBGOUT rows (wanting %ld), "
                 "debug_out_request_ns %ld, debug_timeout_ns %ld and the block at 0%o-0%o\n",
                 path, dbg_rows, want_dbg_regs, dbg_rows_cyc.size(), want_dbg_cycles,
                 want_dbg_req_ns, want_dbg_tmo_ns, want_dbg_low, want_dbg_high);
    return 2;
  }
  if (dbg_tmo_rows != kVcoPeriodNs / kTickNs) {
    std::fprintf(stderr, "FAIL: %s carries %ld DBGTMO rows, wanting one every %ld ns of %ld\n",
                 path, dbg_tmo_rows, (long)kTickNs, kVcoPeriodNs);
    return 2;
  }
  // Every phase is filled, and every delay is `busint::DEBUG_TIMEOUT_NS` plus
  // between half a period and a period and a half.  That is not a guess: the
  // gated output takes its first FALL strictly after the grant --- the part
  // cannot pass an edge it has not yet seen --- and the count starts at the
  // rise after that, so a grant landing just before a fall waits nearly two
  // half-periods longer than one landing just after.  A table that had
  // collapsed to one number would pass every replay and would be exactly the
  // recorded bug: restarting the oscillator at the grant is the obvious way
  // to write it and is wrong on every cycle but the lucky ones.
  long tmo_lo = -1, tmo_hi = -1;
  for (long ph = 0; ph < kVcoPeriodNs; ph += kTickNs) {
    const long d = dbg_tmo[ph];
    if (d < want_dbg_tmo_ns + kVcoPeriodNs / 2 ||
        d > want_dbg_tmo_ns + 3 * kVcoPeriodNs / 2) {
      std::fprintf(stderr, "FAIL: %s: a grant at phase %ld is given up on after %ld ns\n", path,
                   ph, d);
      return 2;
    }
    if (tmo_lo < 0 || d < tmo_lo) tmo_lo = d;
    if (d > tmo_hi) tmo_hi = d;
  }
  if (tmo_hi - tmo_lo < kVcoPeriodNs - kTickNs) {
    std::fprintf(stderr, "FAIL: %s's phase table spans %ld ns, so it is not a free-running "
                 "oscillator's\n", path, tmo_hi - tmo_lo);
    return 2;
  }
  // The block is exactly the range the trace names, and it is no register of
  // this board's and no part of the window: three claims about the same
  // thirty-two addresses, from three separate sets of rows.
  for (unsigned u = 0; u < kAddrs; ++u) {
    const bool in = (u >= want_dbg_low && u <= want_dbg_high);
    if (in != (dbg[u] >= 0)) {
      std::fprintf(stderr, "FAIL: 0%o: DBGREG says %s and the block runs 0%o-0%o\n", u,
                   dbg[u] >= 0 ? "debug" : "not", want_dbg_low, want_dbg_high);
      return 2;
    }
    if (dbg[u] >= 0 && (table[u] != kNothing || in_win[u])) {
      std::fprintf(stderr, "FAIL: 0%o is the debug block's and also kind %d\n", u, table[u]);
      return 2;
    }
    // Bits 4 and 1 are not decoded, so the four strobes repeat every eight
    // bytes through the block.  Asserted against the rows rather than
    // recomputed, so that a trace which had lost the repeat would say so.
    if (dbg[u] >= 0 && dbg[u] != (int8_t)((u >> 2) & 3)) {
      std::fprintf(stderr, "FAIL: 0%o carries strobe %d and its address bits say %d\n", u, dbg[u],
                   (u >> 2) & 3);
      return 2;
    }
  }

  const long kSsynT = want_ssyn_ns / kTickNs;
  const long kStrobeT = want_strobe_ns / kTickNs;
  // **WHERE `-UB SSYN` IS SEEN, AND THE WRITE LANDS: ONE STEP SHORT OF EACH
  // INSTANT.**  `Run` counts its steps from the edge `-UB MSYN` is first seen
  // at, and a register that stands for an asynchronous line moves on the
  // edge BEFORE its instant, so that the edge at the instant is the first to
  // see it (`docs/timing.md`, "A change on an edge counts as before it").  So
  // `-UB SSYN` stands from the step `kSsynT - 1` and a register the write
  // loads has it after the step `kStrobeT - 1`.  This check wanted each a
  // step later, and the block answered the processor 10 ns after muir,
  // measured on the whole machine with `quux_unibus`; the diagnostic
  // registers of `cadr_spy_registers.sv`, which share the select and which
  // MIT's boot PROM holds to muir, were one step short all along.
  const long kSsynAt = kSsynT - 1;
  const long kXbusRqT = want_rq_ns / kTickNs;
  const long kReadAckT = want_read_ack_ns / kTickNs;
  const long kMdAckT = want_md_ack_ns / kTickNs;

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
    // The mapped window's Xbus half, as the seam showed it.
    long req_at = -1;    // the tick `map_req` came up, after `-UB MSYN`
    long done_at = -1;   // the tick the seam acknowledged
    uint32_t addr = 0;
    uint32_t mwdata = 0;
    int mwrite = 0;
    int md_seen = 0;     // `-UB TO MD` stood at some tick of the cycle
    // `-UB TO MD`'s own seam, which has no Xbus cycle in it at all.
    long md_req_at = -1;   // the tick `-UB TO MD` came up, after `-UB MSYN`
    long md_done_at = -1;  // the tick the processor took the word
    uint32_t md_word = 0;  // what stood on the thirty-two lines at the request
    // The debug cable's DBGOUT end.
    int sel_dbg = 0;        // `SELECT DEBUG` stood at some tick of the cycle
    int sel_dbg_at_msyn = 0;  // and it stood at the strobe itself
    long dbg_req_at = -1;   // the tick `-DEBUG OUT REQ` came up, after `-UB MSYN`
    unsigned dbg_a = 0;     // `DEBUG OUT A<1:0>` as it went out
    int dbg_wr = 0;         // `DEBUG IN WR`
    unsigned dbg_dbd = 0;   // `DBD<15:0>` as this board drove them
    unsigned dbg_dbd_lift = 0;  // and as they stood at the lift
    long dbg_ack_at = -1;   // the tick the far end's DEBUG ACK reached this edge
  };
  // **THE XBUS BEHIND THE WINDOW ANSWERS AT A LATENCY THAT MOVES.** A fixed
  // one would let a block that counted ticks from `-UB MSYN` rather than
  // watching the acknowledgment pass, which is the whole of what
  // `busint::UB_XBUS_READ_ACK_NS` is a claim about.
  long map_latency = 1;
  // **AND `UB MD LOAD` ANSWERS AT A LATENCY THAT MOVES TOO**, for the same
  // reason: the load is a grant on the machine's side of the seam, and a
  // block that counted ticks from `-UB MSYN` rather than watching the
  // acknowledgment would pass a fixed one.  `busint::UB_MD_ACK_NS` is a
  // claim about the interval from the LOAD, not from the strobe.
  long md_latency = 1;
  // **AND THE FAR END OF THE DEBUG CABLE ANSWERS AT A LATENCY THAT MOVES**,
  // for the third time and the same reason: `DEBUG SSYN` is the other
  // machine's `DEBUG ACK` and comes when it comes, so a block that counted
  // ticks from `-UB MSYN` would pass a fixed one.  Negative is a far end that
  // never answers at all.
  long cable_latency = -1;
  auto Run = [&](unsigned uaddr, int write, unsigned wdata, long hold) {
    Result res;
    b.d->ub_addr = uaddr;
    b.d->ub_write = write;
    b.d->ub_wdata = wdata;
    b.d->ub_msyn = 1;
    long count = -1;      // ticks left before the seam answers, -1 idle
    long mdcount = -1;    // the same, for the processor taking the MD word
    long cablecount = -1; // and for the other machine's DEBUG ACK
    for (long k = 0; k < hold; ++k) {
      // The seam, driven INTO this edge: the DUT takes `map_done` and the
      // word at the same edge, as it takes `-MEMACK` and `MEM<31:0>`.
      if (count == 0) {
        b.d->map_done = 1;
        if (res.mwrite) b.MemWrite(res.addr, res.mwdata);
        else b.d->map_rdata = b.MemRead(res.addr);
        res.done_at = k;
        count = -1;
      }
      // `UB MD LOAD`: the processor takes the word at this edge, which is
      // where `Busint::debug_xbus_edge` loads `MD` --- and `-LOADMD ACK`
      // follows `busint::UB_MD_ACK_NS` later.
      if (mdcount == 0) {
        b.d->map_md_done = 1;
        res.md_done_at = k;
        mdcount = -1;
      }
      // The other machine's `DEBUG ACK`, driven INTO this edge as the seam's
      // acknowledgment is: what `-UB SSYN` must follow with no delay of its
      // own.  It is a level and it stands until the cycle ends.
      if (cablecount == 0) {
        b.d->dbgout_ack = 1;
        res.dbg_ack_at = k;
        cablecount = -1;
      }
      b.Step();
      b.d->map_done = 0;
      b.d->map_md_done = 0;
      // The cable, watched and answered.  The levels are read at the request
      // and again at the lift, because what the far end's latches take is
      // what stands at the TRAILING edge of the strobe.
      if (b.d->select_debug) {
        res.sel_dbg = 1;
        if (k == 0) res.sel_dbg_at_msyn = 1;
      }
      if (b.d->dbgout_req) {
        if (res.dbg_req_at < 0) {
          res.dbg_req_at = k;
          res.dbg_a = b.d->dbgout_a;
          res.dbg_wr = b.d->dbgout_wr;
          res.dbg_dbd = b.d->dbgout_dbd;
          if (cable_latency >= 0) cablecount = cable_latency;
        }
        res.dbg_dbd_lift = b.d->dbgout_dbd;
      }
      if (cablecount > 0) --cablecount;
      if (b.d->map_md) {
        res.md_seen = 1;
        if (res.md_req_at < 0) {
          res.md_req_at = k;
          res.md_word = b.d->map_md_wdata;
          mdcount = md_latency;
        }
      }
      if (mdcount > 0) --mdcount;
      if (b.d->map_req && res.req_at < 0) {
        res.req_at = k;
        res.addr = b.d->map_addr;
        res.mwrite = b.d->map_write;
        res.mwdata = b.d->map_wdata;
        count = map_latency;
      }
      if (count > 0) --count;
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
    // The cable's acknowledgment is a level the far end holds for its own
    // cycle and lets go with it, which is what `cadr_dbgin.sv` does: it is
    // dropped here with the strobe rather than left standing into the next.
    b.d->dbgout_ack = 0;
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
    if (r.ssyn != kSsynAt)
      bad += Fail(row, "-UB SSYN, in ticks after -UB MSYN", (unsigned long)r.ssyn,
                  (unsigned long)kSsynAt);
    return r.word;
  };

  // ---- the rows ------------------------------------------------------------
  long ops = 0, errs = 0, lines = 0, faces = 0, writes = 0, reads = 0;
  long maps = 0, by_resp[4] = {0}, map_xbus_reads = 0, map_xbus_writes = 0, md_writes = 0;
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
        if (got.ssyn != kSsynAt)
          bad += Fail(r.n, "-UB SSYN, in ticks after -UB MSYN", (unsigned long)got.ssyn,
                      (unsigned long)kSsynAt);
        if (r.write) {
          ++writes;
        } else {
          ++reads;
          if (got.word != r.rdata) bad += Fail(r.n, "the word", got.word, r.rdata);
        }
        break;
      }
      case kMapMd:
      case kMapCyc: {
        ++maps;
        by_resp[r.resp]++;
        // The window answers a FOREIGN master and nothing else, which is the
        // whole reason this port exists; the sweeps below hold the other way.
        b.d->ub_foreign = 1;
        map_latency = 1 + (maps % 13);
        md_latency = 1 + (maps % 7);
        // Long enough that "it did not answer" is a measurement and not a
        // race: the request at twenty ticks, the seam's latency, the read's
        // deskew at twenty, and margin over all of it.
        const Result got = Run(r.uaddr, r.write, r.wdata, 200);
        b.d->ub_foreign = 0;
        // **A WRITE OF `MD` IS ANSWERED NOW**, `busint::UB_MD_ACK_NS` after
        // the edge that loads it: `-LOADMD ACK` at REQLM 0A11 is what
        // acknowledges the cycle, and `UB MD LOAD` is a term of it.  Only a
        // refusal is never answered.
        const int want_ack = (r.resp != kRefused);
        if (got.answered != want_ack) {
          bad += Fail(r.n, want_ack ? "-UB SSYN on a mapped cycle muir answers"
                                    : "-UB SSYN on a mapped cycle muir NEVER answers",
                      got.answered, want_ack);
          break;
        }
        // `-UB TO MD` stands on exactly muir's `Responder::MapMd`.
        if (got.md_seen != (r.resp == kMd))
          bad += Fail(r.n, "-UB TO MD", got.md_seen, r.resp == kMd);
        if (r.resp == kMd) {
          ++md_writes;
          // `-UB TO MD` is `NAND(UBMA<21:17>, UBXRQ, -UBRD, MSYN IN)` at REQU
          // 0D12, and `UBXRQ` is one of its four inputs: the request rises
          // `busint::UB_XBUS_REQUEST_NS` after `-UB MSYN`, the same instant
          // the Xbus half's does, because it is the same `UBXRQ`.
          if (got.md_req_at != kXbusRqT)
            bad += Fail(r.n, "-UB TO MD, in ticks after -UB MSYN",
                        (unsigned long)got.md_req_at, (unsigned long)kXbusRqT);
          // It holds the Xbus request off at REQLM 0E09: no bus cycle at all.
          if (got.req_at >= 0)
            bad += Fail(r.n, "an Xbus request from a write of MD", (unsigned long)got.req_at, 0);
          // The thirty-two lines: `Machine::mapped_write`'s own word.  The
          // odd word is the Unibus word over the page's write buffer, and
          // write-through's even word is the Unibus word with ground above
          // it.  A fabric that sent the word to the wrong half, or swapped
          // the two, disagrees here and nowhere else.
          if (r.tag == kMapMd && got.md_word != r.md32)
            bad += Fail(r.n, "the thirty-two bits that go into MD", got.md_word, r.md32);
          // The trace's own two columns, asserted against each other: a row
          // where the word that went out and MD afterwards disagreed would
          // otherwise pass twice.  `MD` itself is a level up and
          // `build/md_compose.pass` is what compares it.
          if (r.tag == kMapMd && r.md != r.md32)
            bad += Fail(r.n, "the trace's own MD, against the word it carried", r.md, r.md32);
          if (got.md_done_at < 0 || got.ssyn - got.md_done_at != kMdAckT)
            bad += Fail(r.n, "-LOADMD ACK, in ticks after the edge that loads MD",
                        (unsigned long)(got.ssyn - got.md_done_at), (unsigned long)kMdAckT);
        } else if (r.resp == kXbus) {
          if (r.write) ++map_xbus_writes; else ++map_xbus_reads;
          if (got.req_at != kXbusRqT)
            bad += Fail(r.n, "the Xbus request, in ticks after -UB MSYN", (unsigned long)got.req_at,
                        (unsigned long)kXbusRqT);
          if (got.addr != r.phys) bad += Fail(r.n, "the physical address", got.addr, r.phys);
          if (got.mwrite != r.write) bad += Fail(r.n, "the Xbus direction", got.mwrite, r.write);
          if (r.write && got.mwdata != r.xword)
            bad += Fail(r.n, "the word that crossed the Xbus", got.mwdata, r.xword);
          // The two programs' poison, compared rather than assumed equal.
          if (b.MemRead(r.phys) != r.xword)
            bad += Fail(r.n, "the word this memory holds against muir's", b.MemRead(r.phys),
                        r.xword);
          // `Busint::debug_xbus_edge`: a write is acknowledged WITH the Xbus
          // acknowledgment and a read `UB_XBUS_READ_ACK_NS` after it.
          const long want = r.write ? 0 : kReadAckT;
          if (got.done_at < 0 || got.ssyn - got.done_at != want)
            bad += Fail(r.n, "-UB SSYN, in ticks after the Xbus acknowledgment",
                        (unsigned long)(got.ssyn - got.done_at), (unsigned long)want);
        } else {
          // The buffer halves and the refusals make no Xbus cycle at all:
          // `Responder::MapBuffer` is a register cycle and a refusal never
          // reaches the bus.
          if (got.req_at >= 0)
            bad += Fail(r.n, "an Xbus request where muir makes none", (unsigned long)got.req_at, 0);
          if (r.resp == kBuffer && got.ssyn != kSsynAt)
            bad += Fail(r.n, "-UB SSYN on a buffer cycle, in ticks after -UB MSYN",
                        (unsigned long)got.ssyn, (unsigned long)kSsynAt);
        }
        if (want_ack && !r.write && got.word != r.rdata)
          bad += Fail(r.n, "the word the master got", got.word, r.rdata);
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
  // cycle just either side of it.  The write is taken on the edge BEFORE the
  // strobe instant, so that a register it loads is seen AT the instant (see
  // `kSsynAt`), which is how `cadr_spy_registers.sv` takes its own: the same
  // write run with the strobe dropped before that edge must NOT land, and run
  // through it must. Nothing else in this file can tell `REGISTER_STROBE_NS`
  // from `DIAGNOSTIC_NS`, which is `RD_FINISH_T` all over again.
  {
    // A word in the map, which is the register with the widest write.
    Run(0766140, 1, 0x1234, kSsynT + 40);
    if (ReadReg(0766140, -1, "the map register before the short write") != 0x1234u)
      bad += Fail(-1, "the map register before the short write", 0, 0x1234);
    Run(0766140, 1, 0x5678, kStrobeT - 1);    // the strobe falls a tick early
    if (ReadReg(0766140, -1, "the map register after the short write") != 0x1234u)
      bad += Fail(-1, "a write whose strobe fell a tick before the strobe instant", 0x5678, 0x1234);
    Run(0766140, 1, 0x5678, kStrobeT);        // and one tick longer
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
  long swept_debug = 0;
  for (unsigned u = 0; u < kAddrs && bad < kMaxBad; ++u) {
    for (int w = 0; w < 2; ++w) {
      const int kind = table[u];
      const int strobe = dbg[u];
      const bool want = (kind != kNothing && kind != kDiagnostic) || strobe >= 0;
      // A cycle nothing answers is held well past the instant an answer would
      // be due, so that "it did not answer" is a measurement and not a race.
      const Result got = Run(u, w, 0x5A5Au, want ? kSsynT + 40 : kSsynT + 20);
      ++swept;
      if (got.answered != (int)want) {
        bad += Fail((long)u, w ? "answering a write" : "answering a read", got.answered, want);
        continue;
      }
      // `SELECT DEBUG` is Y2 of the same decoder and stands on the debug
      // block's thirty-two addresses and nowhere else.  It is what takes the
      // REQTIM PROM's second table in `cadr_busint_xbus.sv`, so a decode a
      // page wide here would give some other cycle 11.05 microseconds to
      // answer in.
      if (got.sel_dbg != (strobe >= 0))
        bad += Fail((long)u, "SELECT DEBUG", got.sel_dbg, strobe >= 0);
      if (strobe >= 0) {
        ++swept_debug;
        // **WITH NO CABLE THE PULL-UP ANSWERS AT `-UB MSYN` ITSELF**, which
        // is muir's own `(msyn, msyn, false)` and is why this block's match
        // is the one that is not held.
        if (got.ssyn != 0)
          bad += Fail((long)u, "-UB SSYN on a debug register with no cable, in ticks after -UB MSYN",
                      (unsigned long)got.ssyn, 0);
        if (!got.sel_dbg_at_msyn)
          bad += Fail((long)u, "SELECT DEBUG at -UB MSYN itself", 0, 1);
        // And the lines read as ones, because nothing drives them.  A block
        // that answered its own machine with zero would be a debugger that
        // said the other machine was there and gave every register as empty.
        if (!w && got.word != 0xFFFFu)
          bad += Fail((long)u, "the word an unplugged cable gives", got.word, 0xFFFFu);
      } else if (want) {
        ++swept_answered;
        by_kind[kind]++;
        if (got.ssyn != kSsynAt)
          bad += Fail((long)u, "-UB SSYN, in ticks after -UB MSYN", (unsigned long)got.ssyn,
                      (unsigned long)kSsynAt);
      } else {
        ++swept_silent;
      }
    }
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", bad, b.tick);
    return 1;
  }

  // ---- the mapped window, at every address, both ways of `ub_foreign` ------
  //
  // The sweep above ran with `ub_foreign` DOWN and required the whole window
  // to be silent, which is the board's own cycle: `busint::decode` answers
  // `Responder::NoUnibus` at every one of those addresses and the generator
  // asserts it. This is the other half, with a foreign master on the bus.
  //
  // The sixteen entries come from the `MAPSWEEP` rows, all valid, all
  // writable and all naming DISTINCT main-memory pages, so the physical
  // address a cycle puts out says which register it came through --- and the
  // page is `Machine::map_entry`'s reading of the word, not this file's.
  for (int k = 0; k < 16 && bad < kMaxBad; ++k) {
    Run(0766140 + 2 * k, 1, sweep_entry[k], kSsynT + 40);
    if (ReadReg(0766140 + 2 * k, -1, "-UB SSYN reading a sweep entry back") != sweep_entry[k])
      bad += Fail(-1, "a sweep entry", 0, sweep_entry[k]);
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", bad, b.tick);
    return 1;
  }

  b.d->ub_foreign = 1;
  long win_swept = 0, win_buf = 0, win_xbus = 0, win_silent = 0, win_reg = 0, win_pairs = 0;
  uint32_t last_high = 0;
  int have_high = 0;
  for (unsigned u = 0; u < kAddrs && bad < kMaxBad; ++u) {
    const int kind = table[u];
    const bool reg = (kind != kNothing && kind != kDiagnostic);
    const bool win = in_win[u] != 0;
    const bool want = reg || win;
    map_latency = 1 + (win_swept % 11);
    const Result got = Run(u, 0, 0, want ? 160 : kSsynT + 20);
    ++win_swept;
    if (got.answered != (int)want) {
      bad += Fail((long)u,
                  dbg[u] >= 0
                      ? "answering a foreign master at the debug block, which muir never does"
                      : "answering a read with a foreign master on the bus",
                  got.answered, want);
      continue;
    }
    if (!want) {
      ++win_silent;
      if (got.req_at >= 0) bad += Fail((long)u, "an Xbus request at an address nothing decodes", 1, 0);
      continue;
    }
    if (!win) {
      ++win_reg;
      // The block's own registers answer everybody --- CC reading `0766044`
      // over the cable is exactly that --- and make no Xbus cycle.
      if (got.ssyn != kSsynAt)
        bad += Fail((long)u, "-UB SSYN on a register read by a foreign master",
                    (unsigned long)got.ssyn, (unsigned long)kSsynAt);
      if (got.req_at >= 0) bad += Fail((long)u, "an Xbus request from a register cycle", 1, 0);
      continue;
    }
    const uint32_t phys = (sweep_page[win_page[u]] << 8) | win_word[u];
    if (win_high[u]) {
      // `-UB READ BUFFER`: the page's read buffer, no Xbus cycle and no look
      // at the map. And it must be the HIGH half of the word the even address
      // two below just read, which is `Machine::mapped_read` --- so every one
      // of the 8,192 words of the window is taken out in two halves and put
      // back together here.
      ++win_buf;
      if (got.req_at >= 0) bad += Fail((long)u, "an Xbus request on the odd word", 1, 0);
      if (got.ssyn != kSsynAt)
        bad += Fail((long)u, "-UB SSYN on a buffer read", (unsigned long)got.ssyn,
                    (unsigned long)kSsynAt);
      if (!have_high) {
        bad += Fail((long)u, "an odd word with no even word before it", 0, 1);
      } else if (got.word != last_high) {
        bad += Fail((long)u, "the high half out of the read buffer", got.word, last_high);
      } else {
        ++win_pairs;
      }
      // **BIT 0 IS DECODED NOWHERE**, so the window comes in fours: two
      // addresses of the low half and then two of the high half, and both of
      // each pair answer the same. The buffer is therefore not cleared here:
      // every high address of a word is compared against the high half the
      // low addresses of that same word fetched.
    } else {
      ++win_xbus;
      if (got.req_at != kXbusRqT)
        bad += Fail((long)u, "the Xbus request, in ticks after -UB MSYN", (unsigned long)got.req_at,
                    (unsigned long)kXbusRqT);
      if (got.addr != phys) bad += Fail((long)u, "the physical address", got.addr, phys);
      if (got.mwrite) bad += Fail((long)u, "the Xbus direction on a read", 1, 0);
      const uint32_t w = b.MemRead(phys);
      if (got.word != (w & 0xFFFFu))
        bad += Fail((long)u, "the low half of the mapped word", got.word, w & 0xFFFFu);
      if (got.done_at < 0 || got.ssyn - got.done_at != kReadAckT)
        bad += Fail((long)u, "-UB SSYN, in ticks after the Xbus acknowledgment",
                    (unsigned long)(got.ssyn - got.done_at), (unsigned long)kReadAckT);
      last_high = w >> 16;
      have_high = 1;
    }
  }
  b.d->ub_foreign = 0;
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", bad, b.tick);
    return 1;
  }

  // ---- the debug block with a cable in it -----------------------------------
  //
  // The sweep above ran with nothing plugged in, which is the pull-up
  // answering.  This runs the same thirty-two addresses with a board at the
  // far end, and it is where the four strobes, the levels and the
  // acknowledgment are compared.
  //
  // **THE FAR END'S WORD IS INJECTIVE IN THE ADDRESS AND THE DIRECTION**, so
  // a block that answered one cycle with another's word says so, and it is
  // never zero and never `0xFFFF`: those two are what an unplugged cable and
  // a dead one read as, and a check whose expected value was one of them
  // could not tell a working cable from no cable at all.
  const long kDbgReqT = want_dbg_req_ns / kTickNs;
  long dbg_cycles = 0, dbg_reads = 0, dbg_writes = 0;
  long dbg_by_strobe[4] = {0};
  b.d->dbgout_live = 1;
  for (unsigned u = want_dbg_low; u <= want_dbg_high && bad < kMaxBad; ++u) {
    for (int w = 0; w < 2; ++w) {
      const unsigned far = 0x3C00u | ((u & 0x3Fu) << 4) | (unsigned)(w << 3) | 5u;
      const unsigned mine = 0x8000u ^ (far * 3u);
      cable_latency = 1 + ((long)(u + (unsigned)w) % 17);
      b.d->dbgout_dbd_in = far;
      const Result got = Run(u, w, mine, 400);
      ++dbg_cycles;
      if (w) ++dbg_writes; else ++dbg_reads;
      dbg_by_strobe[dbg[u] & 3]++;
      if (!got.answered) {
        bad += Fail((long)u, "-UB SSYN on a debug register with a cable", 0, 1);
        continue;
      }
      // `busint::DEBUG_OUT_REQUEST_NS`: the request follows `-UB MSYN` by a
      // delay-line section, so the levels under it have been standing that
      // long when the far end's latches see the strobe.
      if (got.dbg_req_at != kDbgReqT)
        bad += Fail((long)u, "-DEBUG OUT REQ, in ticks after -UB MSYN",
                    (unsigned long)got.dbg_req_at, (unsigned long)kDbgReqT);
      // `DEBUG OUT A<1:0>` is `busint::debug_register`, which is Unibus
      // address bits 3 and 2 through the 74S241 at DBGOUT 0A17.
      if (got.dbg_a != (unsigned)dbg[u])
        bad += Fail((long)u, "DEBUG OUT A<1:0>", got.dbg_a, (unsigned)dbg[u]);
      if (got.dbg_wr != w) bad += Fail((long)u, "DEBUG IN WR", got.dbg_wr, w);
      if (got.dbg_dbd != mine)
        bad += Fail((long)u, "DBD<15:0> as this board drives them", got.dbg_dbd, mine);
      // `DEBUG SSYN` is `DEBUG OUT ACK AND SELECT DEBUG` at DBGOUT 0A12 and
      // has no delay of its own: `-UB SSYN` is the other machine's answer.
      if (got.ssyn != got.dbg_ack_at)
        bad += Fail((long)u, "-UB SSYN, in ticks after DEBUG OUT ACK",
                    (unsigned long)(got.ssyn - got.dbg_ack_at), 0);
      if (!w && got.word != far)
        bad += Fail((long)u, "the word the far end drove", got.word, far);
      // **AND THE LEVELS STAND PAST THE LIFT**, which is the promise the far
      // end's latches rest on: they clock `DBD` at the TRAILING edge of their
      // own strobe, so a block that let the lines go with the request would
      // write the wrong word into the other machine's address register.
      if (b.d->dbgout_req)
        bad += Fail((long)u, "-DEBUG OUT REQ after the master let the cycle go", 1, 0);
      if (b.d->dbgout_dbd != mine)
        bad += Fail((long)u, "DBD<15:0> standing after the lift", b.d->dbgout_dbd, mine);
      if (b.d->dbgout_a != (unsigned)dbg[u])
        bad += Fail((long)u, "DEBUG OUT A<1:0> standing after the lift", b.d->dbgout_a,
                    (unsigned)dbg[u]);
    }
  }
  cable_latency = -1;
  b.d->dbgout_live = 0;
  b.d->dbgout_dbd_in = 0xFFFF;
  if (bad) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", bad, b.tick);
    return 1;
  }

  // ---- an acknowledgment that belongs to the CYCLE BEFORE ------------------
  //
  // `DEBUG OUT ACK` is a level.  On MIT's cable it falls within nanoseconds of
  // the request it belongs to being lifted, because the far end's gate is
  // `NAND(-DB ADR1 CLK, -DB ADR0 CLK, -DB READ STATUS)` and the three go with
  // the request.  A carrier that serializes the cable does not give that for
  // free: the fall takes a frame to cross, so the acknowledgment of the
  // cycle just finished is still standing when the next one starts.
  //
  // So this is the stimulus that loses the race --- the ack left UP across
  // the gap between two cycles, which is what the cable really does --- and
  // the claim is that the second cycle waits for an acknowledgment of its
  // own.  Found on the two-board check before it was a section here.
  {
    b.d->dbgout_live = 1;
    b.d->dbgout_dbd_in = 0x4321;
    cable_latency = 4;
    const Result first = Run(want_dbg_low, 0, 0, 400);
    if (!first.answered) bad += Fail(-1, "-UB SSYN on the first of two cabled cycles", 0, 1);
    // The far end's answer has not had time to go away: it stands into the
    // next cycle, as a level a frame behind does.
    b.d->dbgout_ack = 1;
    b.d->dbgout_dbd_in = 0xFFFF;
    cable_latency = -1;
    b.d->ub_addr = want_dbg_low;
    b.d->ub_write = 0;
    b.d->ub_wdata = 0;
    b.d->ub_msyn = 1;
    long early = -1;
    for (long k = 0; k < 120; ++k) {
      // The far end lets the old acknowledgment go a frame in, and gives one
      // of its own for THIS cycle a little after.
      if (k == 40) b.d->dbgout_ack = 0;
      if (k == 80) {
        b.d->dbgout_ack = 1;
        b.d->dbgout_dbd_in = 0x4321;
      }
      b.Step();
      if (b.d->ub_ssyn && early < 0) early = k;
    }
    b.d->ub_msyn = 0;
    b.d->dbgout_ack = 0;
    b.Idle(3);
    if (early < 80)
      bad += Fail(-1, "-UB SSYN taken from the acknowledgment of the cycle BEFORE",
                  (unsigned long)early, 80);
    b.d->dbgout_live = 0;
    b.d->dbgout_dbd_in = 0xFFFF;
  }

  // ---- and a cable that goes away under a standing request ------------------
  //
  // The far end is there, the request goes out, and then the connector is
  // pulled: no more frames arrive, `cadr_dbg_cable.sv` drops `out_live`, and
  // the lines go back to the pull-ups.  The block must answer THERE rather
  // than wait --- an unplugged cable is a debuggee that answers everything
  // with ones, and a block that waited would hang its own machine's Unibus
  // cycle on a cable nobody is holding.
  {
    b.d->dbgout_live = 1;
    b.d->dbgout_dbd_in = 0x1234;
    b.d->ub_addr = want_dbg_low;
    b.d->ub_write = 0;
    b.d->ub_wdata = 0;
    b.d->ub_msyn = 1;
    long ssyn_at = -1;
    unsigned word = 0;
    for (long k = 0; k < 200; ++k) {
      // Pulled at the fiftieth tick, well after the request has gone out.
      if (k == 50) {
        b.d->dbgout_live = 0;
        b.d->dbgout_dbd_in = 0xFFFF;
      }
      b.Step();
      if (b.d->ub_ssyn && ssyn_at < 0) {
        ssyn_at = k;
        word = b.d->ub_rdata;
      }
    }
    b.d->ub_msyn = 0;
    b.Idle(3);
    if (ssyn_at != 50)
      bad += Fail(-1, "-UB SSYN, in ticks after the cable went away",
                  (unsigned long)ssyn_at, 50);
    if (word != 0xFFFFu)
      bad += Fail(-1, "the word a cable that went away gives", word, 0xFFFFu);
    b.d->dbgout_live = 0;
    b.d->dbgout_dbd_in = 0xFFFF;
  }

  // ---- muir's own cycles, replayed ------------------------------------------
  //
  // `DBGOUT` rows out of `busint::Busint`: the instants a debug cycle is made
  // of, from the grant onwards.  What this file can replay is everything from
  // `-UB MSYN`; the two rows that end on the interface's own `NXM TIMEOUT`
  // are held by `build/unibus.pass`, where the counter is.
  long dbg_replayed = 0, dbg_unanswered = 0;
  for (const DbgRow &r : dbg_rows_cyc) {
    b.d->dbgout_live = r.cable;
    // A cable with a board at the far end drives the lines; one with none
    // reads as the pull-ups, and so does one nobody has answered yet.
    const unsigned far = r.cable ? (unsigned)(0x2A00u ^ (r.n * 0x1111u) ^ 0x0055u) : 0xFFFFu;
    b.d->dbgout_dbd_in = r.cable ? 0xFFFFu : far;
    const long want_req = r.req_ns < 0 ? -1 : (r.req_ns - r.msyn_ns) / kTickNs;
    const long want_ssyn = (r.ssyn_ns - r.msyn_ns) / kTickNs;
    // The stimulus: when the other machine answers, in ticks after the
    // request.  A row muir's interface gave up on is one nothing answers
    // here, and this module has no timer of its own to end it --- which is
    // the claim, and the reason `select_debug` leaves the module at all.
    cable_latency = (r.ans_ns < 0 || !r.taken) ? -1 : (r.ans_ns - r.req_ns) / kTickNs;
    if (cable_latency >= 0) b.d->dbgout_dbd_in = far;
    const Result got = Run(want_dbg_low + 4 * r.strobe, r.write, r.wdata,
                           want_ssyn + 2 * kDbgReqT + 40);
    ++dbg_replayed;
    if (want_req >= 0 && got.dbg_req_at != want_req)
      bad += Fail(r.n, "-DEBUG OUT REQ, in ticks after -UB MSYN", (unsigned long)got.dbg_req_at,
                  (unsigned long)want_req);
    // **A CYCLE WITH NO CABLE PUTS NO REQUEST OUT, AND THE RACE IS THE
    // BOARD'S OWN.**  The pull-up answers at `-UB MSYN` and the master lifts
    // `busint::UNIBUS_STROBE_NS` later, which is the very instant the
    // delay-line section would have made the request: on MIT's board that is
    // a pulse of no width into a connector with nothing in it.  muir puts no
    // request on the cable at all in that arm and neither does this.
    if (want_req < 0 && got.dbg_req_at >= 0)
      bad += Fail(r.n, "a request on a cable muir does not put one on",
                  (unsigned long)got.dbg_req_at, 0);
    if (want_req >= 0 && got.dbg_a != r.strobe)
      bad += Fail(r.n, "DEBUG OUT A<1:0>", got.dbg_a, r.strobe);
    if (r.timed_out) {
      // muir's interface ended this one on its own counter, which is not in
      // this module: here it stands, and `build/unibus.pass` is where the
      // 11.05 microseconds are measured.
      ++dbg_unanswered;
      if (got.answered)
        bad += Fail(r.n, "an answer to a cycle the far end never gave one", 1, 0);
    } else {
      if (!got.answered) {
        bad += Fail(r.n, "-UB SSYN on a cycle muir answers", 0, 1);
        continue;
      }
      if (got.ssyn != want_ssyn)
        bad += Fail(r.n, "-UB SSYN, in ticks after -UB MSYN", (unsigned long)got.ssyn,
                    (unsigned long)want_ssyn);
      if (!r.write && got.word != (r.cable ? far : 0xFFFFu))
        bad += Fail(r.n, "the word the master got", got.word, r.cable ? far : 0xFFFFu);
    }
  }
  cable_latency = -1;
  b.d->dbgout_live = 0;
  b.d->dbgout_dbd_in = 0xFFFF;
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
  least("mapped cycles replayed", maps, 20);
  for (int k = kBuffer; k <= kMd; ++k)
    least("mapped cycles of one of the four responders", by_resp[k], 1);
  least("mapped reads that made an Xbus cycle", map_xbus_reads, 4);
  least("mapped writes that made an Xbus cycle", map_xbus_writes, 3);
  least("mapped writes that loaded MD", md_writes, want_md_writes);
  least("debug addresses answered with no cable in the connector", swept_debug, 64);
  least("debug cycles run over a cable", dbg_cycles, 64);
  least("debug reads over a cable", dbg_reads, 32);
  least("debug writes over a cable", dbg_writes, 32);
  for (int k = 0; k < 4; ++k)
    least("cycles of one of the four debug strobes", dbg_by_strobe[k], 16);
  least("of muir's own debug cycles replayed", dbg_replayed, want_dbg_cycles);
  least("debug cycles nothing answered", dbg_unanswered, 2);
  least("window addresses answered from the read buffer", win_buf, 8192);
  least("window addresses answered off the Xbus", win_xbus, 8192);
  least("words of the window taken out in two halves and put together", win_pairs, 8192);
  if (swept != 2 * (long)kAddrs) {
    std::fprintf(stderr, "FAIL: the sweep ran %ld cycles over %u addresses in two directions\n",
                 swept, kAddrs);
    ++thin;
  }
  if (win_swept != (long)kAddrs) {
    std::fprintf(stderr, "FAIL: the window's sweep ran %ld cycles over %u addresses\n", win_swept,
                 kAddrs);
    ++thin;
  }
  if (thin) return 1;

  std::printf(
      "ok: %ld ticks, agree with muir's busint::register and Machine::interface_read and\n"
      "    interface_write at the Unibus.  %ld register cycles replayed --- %ld reads compared\n"
      "    against muir's word and %ld writes --- and %ld timeouts, each followed by a read of\n"
      "    0766040 and 0766044 off the bus: %ld faces compared, the interrupt status register,\n"
      "    the error status register, UB INT at the port and LM INT made of it.\n"
      "    -UB SSYN is seen %ld ticks after -UB MSYN on every one of %ld answered cycles and at\n"
      "    no earlier tick, and a write is seen at %ld: the same write with the strobe dropped\n"
      "    before the edge ahead of that instant does not take, which is the only thing here\n"
      "    that can tell the two constants apart.\n"
      "    All %ld addresses of the Unibus map were read and written, the odd ones among them:\n"
      "    bit 0 is decoded nowhere in the block, so each is the even address below it, and the\n"
      "    register a word landed in is muir's own Register::Map(n) and not this file's sum.\n"
      "    The decode: %ld cycles over all %u addresses read and written, %ld answered and %ld\n"
      "    silent, against busint::register out of %s (%ld IFACE rows and %ld IFACENONE runs).\n"
      "    The 32 addresses of the DIAGNOSTIC block are among the silent: they are\n"
      "    cadr_spy_registers.sv's, and so are the debug block's, which answers over a cable.\n"
      "    THE MAPPED WINDOW: %ld mapped cycles replayed against Machine::mapped_read and\n"
      "    mapped_write --- %ld answered from a buffer, %ld off the Xbus (%ld reads and %ld\n"
      "    writes), %ld refused with UB MAP ERROR and never answered, and %ld a write of MD,\n"
      "    decoded, answered and loaded into MD.  The Xbus request is %ld ticks after -UB MSYN\n"
      "    on every one of\n"
      "    them and -UB SSYN is %ld ticks after the acknowledgment on a read and with it on a\n"
      "    write, the seam answering at a latency that moves from cycle to cycle.\n"
      "    AND -UB TO MD IS BUILT: %ld of those mapped writes put their thirty-two lines into\n"
      "    the processor's MD instead of onto the Xbus --- the Unibus word in the high half\n"
      "    over the page's write buffer, or with ground above it for write-through's even\n"
      "    word --- with -UB TO MD up %ld ticks after -UB MSYN, no Xbus request at all, and\n"
      "    -LOADMD ACK %ld ticks after the edge the processor took the word at, that edge\n"
      "    moving from cycle to cycle so the interval is measured and not counted from the\n"
      "    strobe.  A read through the same entry never reaches MD.\n"
      "    And the window at every one of the %u addresses with a foreign master on the bus:\n"
      "    %ld answered, %ld of them off the Xbus at the physical address Machine::map_entry\n"
      "    names and %ld from the read buffer --- all %ld words of the window taken out in two\n"
      "    halves and put back together --- %ld by the block's own registers and %ld silent.\n"
      "    The board's OWN cycle is refused all %ld of them, which is the sweep above with\n"
      "    ub_foreign down: busint::decode answers NoUnibus at every address of the window,\n"
      "    so the processor is not mapped and must not be.\n"
      "    AND THE DEBUG BLOCK IS THE CABLE'S OTHER END: all 32 addresses of\n"
      "    busint::debug_register swept with nothing plugged in --- %ld cycles answered at\n"
      "    -UB MSYN itself off the pull-up, every read giving all ones, SELECT DEBUG up on\n"
      "    those addresses and on no other of the %u --- and %ld more over a cable, %ld reads\n"
      "    and %ld writes, with -DEBUG OUT REQ %ld ticks after -UB MSYN, DEBUG OUT A<1:0> the\n"
      "    strobe the address decodes to, the levels standing after the master let the cycle\n"
      "    go, and -UB SSYN on the far end's DEBUG ACK with no delay of its own, that\n"
      "    acknowledgment coming at a latency that moves from cycle to cycle.  A cable\n"
      "    pulled under a standing request answers there with ones rather than waiting.\n"
      "    %ld of muir's own busint::Busint cycles replayed, %ld of them at an address the\n"
      "    far end never answered --- this block has no timer and build/unibus.pass is where\n"
      "    the 11.05 us the interface waits is measured.  A foreign master is refused at all\n"
      "    32, which is Busint::debug_set_master giving Responder::Debug no answer.\n",
      b.tick, ops, reads, writes, errs, faces, kSsynT, answered, kStrobeT, aliases, swept, kAddrs,
      swept_answered, swept_silent, path, iface_rows, none_runs, maps, by_resp[kBuffer],
      by_resp[kXbus], map_xbus_reads, map_xbus_writes, by_resp[kRefused], by_resp[kMd], kXbusRqT,
      kReadAckT, md_writes, kXbusRqT, kMdAckT, kAddrs, win_buf + win_xbus + win_reg, win_xbus, win_buf, win_pairs, win_reg,
      win_silent, win_rows, swept_debug, kAddrs, dbg_cycles, dbg_reads, dbg_writes, kDbgReqT,
      dbg_replayed, dbg_unanswered);
  return 0;
}
