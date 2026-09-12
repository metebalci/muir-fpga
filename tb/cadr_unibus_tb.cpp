// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Unibus with both its slaves on it: the machine's own bus cycle reaching
// the I/O board.
//
// WHY THIS CHECK EXISTS, AND WHAT NO OTHER ONE SAYS.
//
// `build/iob.pass` holds `rtl/machine/cadr_io_board.sv` to muir's
// `ioboard::IoBoard` through `busint::IoBoardTiming` over 81 million ticks, at
// the card's own seam, with a Unibus master in the testbench.  That is the
// card.  What it cannot say is that a cycle of the MACHINE'S reaches it ---
// that `cadr_busint_xbus` arbitrates for the bus, puts `-UB MSYN` out with the
// address `cadr_memory_path` computed, takes the card's `-UB SSYN` back and
// turns it into `-MEMACK` and `-LOADMD`, and that the word the card drove is
// the word on MEM<15:0>.
//
// **AND NO CHECK IN THIS REPOSITORY HAS EVER RUN A UNIBUS READ.**  Measured
// rather than assumed: `build/machine.pass` prints "the Unibus arbitration of
// 1 of 17466 bus cycles" and that one cycle is MIT's boot PROM writing the
// mode register at `0o766012`, which is how it turns itself off.
// `busint_xbus.golden`'s addresses are main memory and empty Xbus space and it
// runs no Unibus cycle at all; the band trace runs against `Vcadr_microcycle`,
// where `-MEMACK` and `-LOADMD` are muir's stimulus.  So
// `cadr_busint_xbus.sv`'s `ub_md_at` --- the MD strobe, `UNIBUS_STROBE_NS`
// after `-UB SSYN` and fifty nanoseconds BEFORE the acknowledgement, which is
// the one place on either bus where the word and the acknowledgement come
// apart --- had never carried a word anybody looked at.  It does here, on
// every answered read the run makes, and the count is printed.
//
// THE DUT IS `cadr_memory_path` AND NOT A HARNESS, for `build/tv.pass`'s
// reason: the card is instantiated inside it, behind the arbiter that
// `cadr_console_bus.sv` presents, so what is driven is the wiring the board
// has rather than a second description of it.  The master is this file, as it
// is for `build/memory_path.pass`: `-MEMRQ`, `WRCYC`, `phys` and the word,
// with `MCLK` on the 29-tick grid.
//
// WHAT IT HOLDS TO, and where each expectation comes from.
//
//   - **The card's own answers are `iob.pass`'s and are not repeated here.**
//     What is compared instead is what this testbench itself put in: the
//     twenty-four-bit scan code it strobed, the seven mouse lines it drove,
//     the interval and the interrupt enables it wrote.  A word that came from
//     the stimulus cannot move with a bug in the card, in the mux or in the
//     bus interface --- which is CLAUDE.md's rule about a shadow that must
//     come from the stimulus and never from the DUT.
//   - **The register block's word is a poison injective in the register
//     number**, driven on `spy_rdata` from the address this testbench is
//     driving and never from `spy_eadr`, for the same reason.  So a mux that
//     returned the other slave's word is caught in both directions: a card
//     read that comes back as the poison, and a block read that does not.
//   - **The decode is muir's, read out of TWO traces.**
//     `build/iob.golden` carries `ioboard::answers` for all 262,144 Unibus
//     addresses in both directions as `DEC` and `DECNONE` rows, and
//     `build/busint_regs.golden` carries `busint::register` over the same
//     eighteen bits as `IFACE` and `IFACENONE` rows --- the diagnostic block
//     included, which this file used to carry as a base of its own.  Between
//     them they say which cycles of the machine's must be answered, by which
//     slave, and which must end on the NXM timer.
//   - **The bus interface's own registers, where they are the composition
//     and not the module.**  `build/busint_regs.pass` holds every word they
//     give and take; what is here is the card's request arriving at
//     `0o766040` through a cycle of the machine's own --- `UB INT` and the
//     vector read back once `ENABLE UB INTS` is written, and gone when it is
//     cleared --- and the sweep's own timeouts setting `UNIBUS NXM` and not
//     `XBUS NXM` in the error status register, with `-RESET ERR` clearing
//     it.  Both are wires that exist only once the modules are composed.
//   - **The three slaves' sets are disjoint over the whole eighteen-bit
//     address**, checked against muir's two tables with no simulation at all,
//     and `ub_ssyn_by` says which slave pulled `-UB SSYN` on every cycle the
//     sweep runs so that two answering at once is measured and not inferred.
//   - **The bus interface's two Unibus instants.**  `-LOADMD` is
//     `unibus_strobe_ns` after `-UB SSYN`, which the trace's own header
//     carries, and `-MEMACK` is `busint::UNIBUS_ACK_NS` --- 150 ns --- which
//     it does not, so that one is named here as a constant with muir's name
//     on it.
//   - **A cycle nothing answers gives MD zero**, which is Mete's decision of
//     10 Sep for an unanswered read, one bus along from where it was made.
//
// WHAT IS DELIBERATELY NOT HERE.
//
//   - The microsecond counter's absolute value.  Its edges are at
//     `first_usec_edge_ns` + 1,000k and `iob.pass` compares 208 reads of it
//     against muir; repeating that arithmetic here would be a second
//     description of the card.  What is compared is a DIFFERENCE: two reads
//     whose `-UB MSYN` instants this run MEASURES to be an exact multiple of
//     the card's microsecond apart must differ by exactly that many counts.
//     That is the timebase claim and it needs no model.
//   - The mouse's counters.  The card takes quadrature and `iob.pass` drives
//     seventeen moves through it; here the lines are held still, so both
//     counters stay where reset left them and the two mouse registers carry
//     the switch and quadrature lines this file drove.  **The mouse's
//     counting is therefore not exercised by this check, and is not meant to
//     be.**
//   - The sixty-cycle clock's exact count, for the same reason.  It is read
//     early and late and must be zero and then not zero.
//
// THE SWEEP'S WINDOW, and why it is not the whole bus.  Every one of the
// 131,072 word addresses would be 262,144 cycles and most of them a full NXM
// timeout, which is nine hundred and thirty-odd ticks each.  The window is
// `0o763000`-`0o770776`, which holds all three slaves' blocks, the pages
// between them and a page either side: any widening of any match that escapes
// its own block lands inside it, because every match is on the top eleven bits
// of the address or more.  The DISJOINTNESS half is exhaustive over the whole
// eighteen bits, because it costs nothing --- and a sweep of the whole bus at
// the bus interface's own registers is `build/busint_regs.pass`'s, where a
// cycle is fifty ticks rather than nine hundred.
//
// THE THIRD SLAVE, AND WHAT IT CLOSED.  `rtl/machine/cadr_busint_regs.sv` is
// the bus interface's own two groups --- the interrupt block at
// `0o766040`-`0o766076` and the Unibus map at `0o766140`-`0o766176` --- and
// until it existed those thirty-two word addresses timed out here where muir
// answers, with this file counting them and printing the count.  They are
// answered now, and the count is of what the third slave took.
//
// **And the decode for all three is muir's**, which it was not: this file
// used to carry `cadr_spy_registers.sv`'s base as two constants of its own,
// so the one block whose address set was nobody's reference was the one this
// machine cannot start without.  `busint_regs.golden` carries
// `busint::register` over the same eighteen bits, the diagnostic block
// included, and it is the second trace this check is handed.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

#include "Vcadr_memory_path.h"
#include "verilated.h"

namespace {

// A microcycle at normal speed, which is when MCLK falls: the bus interface
// only looks at -MEMRQ towards the end of the cycle.
const long kMicrocycle = 29;

// MIT's grid, which is what every tick count in the fabric is measured in.
// `cadr_arty.sv` decides how long a tick is in real time and nothing here
// cares.
const long kTickNs = 5;

// `busint::UNIBUS_ACK_NS`, -UB SSYN to -LMACK.  The trace's header carries
// `unibus_strobe_ns` and not this one, so it is written out with muir's name
// on it; `tb/cadr_unibus_tb.cpp` and `rtl/machine/cadr_busint_xbus.sv` are the
// two places it appears and a mutation on either is caught by the other.
const long kUnibusAckNs = 150;

// The card's registers, `0o764100`-`0o764126`.
const unsigned kKbdLow = 0764100, kKbdHigh = 0764102;
const unsigned kMouseY = 0764104, kMouseX = 0764106;
const unsigned kBeep = 0764110, kCsr = 0764112;
const unsigned kUsecLow = 0764120, kUsecHigh = 0764122;
const unsigned kClock = 0764124, kGpio = 0764126;

// The six kinds `busint_regs.golden`'s `IFACE` rows carry, in the trace's own
// numbering, and the seventh for an address `busint::register` answers
// nothing at.  Kind 0, the DIAGNOSTIC block, is `cadr_spy_registers.sv`; the
// other five are `cadr_busint_regs.sv`.
enum IfaceKind { kDiagnostic = 0, kIntCtl, kIntCtl2, kErrStatus, kUnwired, kMap, kNoIface };

// The sweep's window: both blocks, what is between them and a page either side.
const unsigned kSweepFirst = 0763000, kSweepLast = 0770776;

// **THE CHAOSNET INTERFACE'S AND THE SERIAL PORT'S GROUPS, WHICH THE CARD
// DECODES AND DOES NOT ANSWER.**  `0o764140`-`0o764176` is `ioboard::answers`'
// groups 6 and 7, and the card as MIT built it answers them whether or not the
// LMU chips and the 2651 are fitted, their `-SSYN` coming from the card's own
// synchronisers.  `rtl/machine/cadr_io_board.sv` decodes the whole block and
// answers only the two groups it implements, rather than invent the
// transmitter's, the receive buffer's and the half-microsecond clock's timings
// for parts nothing can exercise; `tb/cadr_io_board_tb.cpp` exempts exactly
// these from its own sweep and prints the count, and so does this.  Whoever
// builds either slice makes the card answer its group and moves both lines.
const unsigned kUnbuiltFirst = 0764140, kUnbuiltLast = 0764176;
bool Unbuilt(unsigned uaddr) { return uaddr >= kUnbuiltFirst && uaddr <= kUnbuiltLast; }

// Nothing drives UBO8..UBO15 on a read of the status register, the two unnamed
// slots of the keyboard group, the beep or the GPIO.
const unsigned kFloating = 0177400;
const unsigned kOpenBus = 0177777;

// The word the diagnostic register block gives back.  Injective in the
// register number, never zero, never all ones, and with a top nibble no
// register of the card can produce in this run: `{1'b0, ...}` cannot reach it
// and the mouse lines below are chosen so that the quadrature nibble does not
// either.
uint16_t Poison(unsigned eadr) { return 0xC300u | (uint16_t)((eadr & 0xF) * 0x11u); }

// The seven lines the mouse drives, held still for the whole run: bits 0 to 3
// the quadrature, 4 to 6 the tail, middle and head switches, each pulled to
// ground when pressed.  The card inverts all seven.  Chosen so that the two
// mouse registers read differently from each other and neither can be mistaken
// for a poison.
const unsigned kMouseIdle = 0x1A;   // ~0x1A = 0x65 in seven bits: 110 and 0101
const unsigned kMousePress = 0x0A;  // one switch changes

unsigned MouseHeld(unsigned lines) { return (~lines) & 0x7F; }

// `busint::unibus_physical`: the physical address at which a Unibus location
// is reached.  Bit 0 of the Unibus address is always zero, as the master's
// UAO<17:1> drop it, so only even addresses are reachable from the processor
// at all.
unsigned UnibusPhysical(unsigned uaddr) {
  const unsigned word = (uaddr >> 1) & 0377777u;
  return ((037000u + (word >> 8)) << 8) | (word & 0xFFu);
}

// EADR<3:0>, which register of the diagnostic block an address names.
unsigned SpyEadr(unsigned uaddr) { return (uaddr >> 1) & 0xF; }

struct Cycle {
  long start = -1;    // the tick -MEMRQ dropped
  long msyn = -1;     // the tick -UB MSYN rose
  long ssyn = -1;     // the tick -UB SSYN came back
  long loadmd = -1;   // the tick -LOADMD asserted
  long memack = -1;   // the tick -MEMACK asserted
  int by = 0;         // ub_ssyn_by at -UB SSYN: bit 0 the block, bit 1 the card
  int timed_out = 0;
  uint32_t word = 0;  // MEM<31:0> at the -LOADMD edge
  bool answered() const { return ssyn >= 0; }
};

int failures = 0;
const int kMaxFailures = 20;

int Fail(const char *what, unsigned long got, unsigned long want, const char *where) {
  if (failures < kMaxFailures)
    std::fprintf(stderr, "FAIL: %s at %s is 0x%lx (%lu), wanting 0x%lx (%lu)\n", what, where, got,
                 got, want, want);
  return 1;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *path = (argc > 1) ? argv[1] : "build/iob.golden";

  // ---- muir's decode, out of the card's own reference trace --------------
  //
  // `DECNONE first last` is a run of addresses nothing answers in either
  // direction; `DEC uaddr write reg` is one direction that is answered.  The
  // two together cover the whole eighteen-bit space, and this asserts that
  // they do rather than defaulting anything.
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "FAIL: cannot read %s\n", path);
    return 2;
  }
  const size_t kAddrs = 1u << 18;
  std::vector<uint8_t> card(kAddrs, 0);     // bit 0 read, bit 1 write
  std::vector<uint8_t> covered(kAddrs, 0);
  long dec_rows = 0, dec_none_runs = 0;
  long want_strobe_ns = -1, want_bits = -1, want_tick_ns = -1;
  char line[512];
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#') {
      char name[64];
      long v;
      if (std::sscanf(line, "# %63s %ld", name, &v) == 2) {
        if (!std::strcmp(name, "unibus_strobe_ns")) want_strobe_ns = v;
        if (!std::strcmp(name, "ub_address_bits")) want_bits = v;
        if (!std::strcmp(name, "tick_ns")) want_tick_ns = v;
      }
      continue;
    }
    unsigned a, b, w, reg;
    if (std::sscanf(line, "DECNONE %x %x", &a, &b) == 2) {
      if (b >= kAddrs) {
        std::fprintf(stderr, "FAIL: %s: a DECNONE run ends at 0x%x, past the address space\n", path, b);
        return 2;
      }
      for (unsigned u = a; u <= b; ++u) covered[u] |= 3;
      ++dec_none_runs;
    } else if (std::sscanf(line, "DEC %x %x %x", &a, &w, &reg) == 3) {
      if (a >= kAddrs) {
        std::fprintf(stderr, "FAIL: %s: a DEC row names 0x%x, past the address space\n", path, a);
        return 2;
      }
      // "reg ffffffff is none": `ioboard::answers` decodes the address and
      // takes the direction nowhere.  A WRITE of either half of the
      // microsecond counter is the case --- the counter has no write pulse ---
      // and there is a row for it so that the trace states the refusal rather
      // than leaving it to a gap.
      if (reg != 0xffffffffu) card[a] |= (uint8_t)(w ? 2 : 1);
      covered[a] |= (uint8_t)(w ? 2 : 1);
      ++dec_rows;
    }
  }
  std::fclose(f);

  // ---- and the bus interface's own decode, out of its trace --------------
  //
  // `busint_regs.golden`'s `IFACE` and `IFACENONE` rows are
  // `busint::register` over the same eighteen bits: the diagnostic block, the
  // interrupt block and the Unibus map, with the debug block decoded to
  // nothing because it is answered over a cable.  **This file used to carry
  // `cadr_spy_registers.sv`'s base as two constants of its own and count the
  // other two groups as addresses muir answers and this fabric does not.**
  // Both are gone: the table below is muir's, the register block's thirty-two
  // addresses are the kind-0 rows of it, and the two groups that used to be
  // counted are answered.
  const char *ipath = (argc > 2) ? argv[2] : "build/busint_regs.golden";
  std::FILE *g = std::fopen(ipath, "r");
  if (!g) {
    std::fprintf(stderr, "FAIL: cannot read %s\n", ipath);
    return 2;
  }
  std::vector<uint8_t> iface(kAddrs, kNoIface);
  std::vector<uint8_t> icovered(kAddrs, 0);
  long iface_rows = 0, iface_none_runs = 0;
  while (std::fgets(line, sizeof line, g)) {
    unsigned a, b, k, n;
    if (std::sscanf(line, "IFACENONE %x %x", &a, &b) == 2) {
      if (b >= kAddrs) {
        std::fprintf(stderr, "FAIL: %s: an IFACENONE run ends at 0x%x\n", ipath, b);
        return 2;
      }
      for (unsigned u = a; u <= b; ++u) icovered[u] = 1;
      ++iface_none_runs;
    } else if (std::sscanf(line, "IFACE %x %x %x", &a, &k, &n) == 3) {
      if (a >= kAddrs || k > kMap) {
        std::fprintf(stderr, "FAIL: %s: an IFACE row names 0x%x kind %u\n", ipath, a, k);
        return 2;
      }
      iface[a] = (uint8_t)k;
      icovered[a] = 1;
      ++iface_rows;
    }
  }
  std::fclose(g);
  for (size_t u = 0; u < kAddrs; ++u)
    if (!icovered[u]) {
      std::fprintf(stderr, "FAIL: %s leaves 0x%zx undecided\n", ipath, u);
      return 2;
    }
  if (iface_rows < 90) {
    std::fprintf(stderr, "FAIL: %s carries %ld IFACE rows; the block has more than that\n", ipath,
                 iface_rows);
    return 2;
  }

  if (want_tick_ns != kTickNs || want_bits != 18) {
    std::fprintf(stderr, "FAIL: %s says tick_ns %ld and ub_address_bits %ld; this file is written for %ld and 18\n",
                 path, want_tick_ns, want_bits, kTickNs);
    return 2;
  }
  if (want_strobe_ns <= 0) {
    std::fprintf(stderr, "FAIL: %s carries no unibus_strobe_ns, which is the MD strobe this check measures\n", path);
    return 2;
  }
  for (size_t u = 0; u < kAddrs; ++u)
    if (covered[u] != 3) {
      std::fprintf(stderr, "FAIL: %s leaves 0x%zx undecided in %s direction\n", path, u,
                   (covered[u] & 1) ? "the write" : "the read");
      return 2;
    }
  long card_answers = 0;
  for (size_t u = 0; u < kAddrs; ++u) card_answers += ((card[u] & 1) ? 1 : 0) + ((card[u] & 2) ? 1 : 0);
  if (dec_rows < 20 || card_answers < 20) {
    std::fprintf(stderr, "FAIL: %s decodes %ld answering directions in %ld rows; the card has more than that\n",
                 path, card_answers, dec_rows);
    return 2;
  }

  // ---- the two slaves are disjoint, over the whole bus, with no simulation
  //
  // The claim a decode in front of them would have ASSUMED.  There is no such
  // decode --- each slave matches the whole address for itself, as a board on
  // the backplane does --- so it is checked here against muir's own table and
  // the register block's own base, and the sweep below then measures it on the
  // bus over the window where it could be false.
  long overlaps = 0, block_addrs = 0, iface_addrs = 0;
  for (size_t u = 0; u < kAddrs; ++u) {
    const bool block = (iface[u] == kDiagnostic);
    const bool bir = (iface[u] != kDiagnostic && iface[u] != kNoIface);
    if (block) ++block_addrs;
    if (bir) ++iface_addrs;
    // Three sets, three ways: no address may be claimed by two of them.
    if ((block && card[u]) || (bir && card[u]) || (block && bir)) ++overlaps;
  }
  if (overlaps) {
    std::fprintf(stderr, "FAIL: %ld addresses are claimed by two of the three Unibus slaves\n", overlaps);
    return 1;
  }
  if (block_addrs != 32 || iface_addrs != 62) {
    std::fprintf(stderr,
                 "FAIL: the register block covers %ld addresses and the bus interface's own %ld,\n"
                 "      wanting 32 and 62\n",
                 block_addrs, iface_addrs);
    return 1;
  }

  const long kStrobeT = want_strobe_ns / kTickNs;
  const long kAckT = kUnibusAckNs / kTickNs;

  // ---- the DUT -----------------------------------------------------------
  auto *dut = new Vcadr_memory_path;
  long tick = 0;

  dut->clk = 0;
  dut->rst = 1;
  dut->xbus_init = 0;
  dut->mclk = 0;
  dut->n_memrq = 1;
  dut->wrcyc = 0;
  dut->phys = 0;
  dut->wdata = 0;
  dut->boards = 32;
  dut->device_ack = 0;
  dut->device_rdata = 0;
  dut->spy_rdata = 0;
  dut->mem_done = 0;
  dut->mem_rdata = 0;
  dut->ch_req = 0;
  dut->ch_write = 0;
  dut->ch_addr = 0;
  dut->ch_wdata = 0;
  dut->con_req = 0;
  dut->con_msyn = 0;
  dut->con_write = 0;
  dut->con_addr = 0;
  dut->con_wdata = 0;
  dut->kbd_strobe = 0;
  dut->kbd_code = 0;
  dut->mouse_lines = kMouseIdle;
  dut->ser_ready = 0;
  dut->chaos_intr = 0;
  dut->eval();

  // One tick.  Nothing is behind the memory port on a Unibus cycle --- the
  // decode sends none of these addresses there --- but it is answered anyway
  // so that a fault which sent one to main memory hangs nothing and shows up
  // as the wrong slave rather than as a stuck run.
  long main_memory_cycles = 0;
  auto Tick = [&]() {
    dut->rst = (tick == 0);
    dut->mclk = (tick % kMicrocycle) == 0;
    dut->clk = 1;
    dut->eval();
    dut->mem_done = dut->mem_req;
    dut->mem_rdata = 0;
    if (dut->mem_req) ++main_memory_cycles;
    dut->eval();
    dut->clk = 0;
    dut->eval();
    ++tick;
  };

  // Idle ticks, with -MEMRQ up.
  auto Idle = [&](long n) {
    for (long i = 0; i < n && failures < kMaxFailures; ++i) Tick();
  };

  // One memory cycle of the processor's, at a Unibus address.  The word the
  // register block would give is driven from THIS address and never from
  // `spy_eadr`, so a block that answered the wrong register is visible.
  auto Run = [&](unsigned uaddr, bool write, uint32_t wdata) {
    Cycle c;
    c.start = tick;
    dut->phys = UnibusPhysical(uaddr);
    dut->wrcyc = write ? 1 : 0;
    dut->wdata = wdata;
    dut->spy_rdata = Poison(SpyEadr(uaddr));
    dut->n_memrq = 0;
    int msyn_last = 0, ssyn_last = 0, loadmd_last = 1, memack_last = 1;
    for (long guard = 0; guard < 6000; ++guard) {
      Tick();
      const long now = tick - 1;
      if (dut->ub_msyn_o && !msyn_last && c.msyn < 0) c.msyn = now;
      msyn_last = dut->ub_msyn_o;
      if (dut->ub_ssyn_o && !ssyn_last && c.ssyn < 0) {
        c.ssyn = now;
        c.by = dut->ub_ssyn_by;
      }
      ssyn_last = dut->ub_ssyn_o;
      if (!dut->n_loadmd && loadmd_last && c.loadmd < 0) {
        c.loadmd = now;
        c.word = dut->rdata;
      }
      loadmd_last = dut->n_loadmd;
      if (!dut->n_memack && memack_last) {
        c.memack = now;
        c.timed_out = dut->timed_out;
        break;
      }
      memack_last = dut->n_memack;
    }
    // -MEMRQ up, and wait for the interface to come back to rest.  A cycle
    // ends where the processor lifts it; the card wants the strobe down for a
    // tick before the next one, which it gets and then some.
    dut->n_memrq = 1;
    for (long guard = 0; guard < 200; ++guard) {
      Tick();
      if (dut->n_memgrant && !dut->ub_msyn_o) break;
    }
    Idle(4);
    return c;
  };

  // The claims every answered cycle makes, whichever slave answered.
  auto CheckTiming = [&](const Cycle &c, const char *where) {
    if (!c.answered()) {
      failures += Fail("-UB SSYN", 0, 1, where);
      return;
    }
    if (c.timed_out) failures += Fail("NXM TIMEOUT on an answered cycle", 1, 0, where);
    if (c.loadmd != c.ssyn + kStrobeT)
      failures += Fail("-LOADMD, in ticks after -UB SSYN", (unsigned long)(c.loadmd - c.ssyn),
                       (unsigned long)kStrobeT, where);
    if (c.memack != c.ssyn + kAckT)
      failures += Fail("-MEMACK, in ticks after -UB SSYN", (unsigned long)(c.memack - c.ssyn),
                       (unsigned long)kAckT, where);
    if (c.msyn < 0 || c.ssyn < c.msyn)
      failures += Fail("-UB MSYN before -UB SSYN", (unsigned long)c.msyn, (unsigned long)c.ssyn, where);
  };

  // A read of the card: answered by the card alone, the word on MEM<15:0> and
  // ones above it, and not the register block's poison.
  long card_reads = 0, card_writes = 0, block_reads = 0, block_writes = 0;
  long iface_reads = 0, iface_writes = 0;
  // Which of the card's twelve register addresses were read BY NAME --- with
  // the word compared against what this file put in, rather than merely
  // answered in the sweep.  A check that swept everything and named nothing
  // would count twelve here too, which is why the bit is set in `ReadCard`
  // and in the two clock sections and nowhere else.
  unsigned card_regs_named = 0;
  auto Named = [&](unsigned uaddr) {
    if (uaddr >= kKbdLow && uaddr <= kGpio) card_regs_named |= 1u << ((uaddr - kKbdLow) >> 1);
  };
  auto ReadCard = [&](unsigned uaddr, unsigned want, const char *where) {
    const Cycle c = Run(uaddr, false, 0);
    CheckTiming(c, where);
    if (!c.answered()) return c;
    if (c.by != 2) failures += Fail("which slave pulled -UB SSYN", (unsigned)c.by, 2, where);
    // muir's `Machine::bus_read` widens a sixteen-bit register to a word, so
    // `MEM<31:16>` is ZERO, under its own comment that the Unibus carries
    // sixteen bits in the bottom of one Lisp machine word.  This asserted
    // 0xFFFF against a constant of its own until 11 Sep, which held the one
    // place the two machines disagreed to this fabric's own choice.
    if ((c.word >> 16) != 0x0000u)
      failures += Fail("MEM<31:16> on a Unibus read", c.word >> 16, 0x0000u, where);
    if ((c.word & 0xFFFFu) != want) failures += Fail("the word", c.word & 0xFFFFu, want, where);
    ++card_reads;
    Named(uaddr);
    return c;
  };

  // ---- power-on, and a little time for the card's clocks -----------------
  Idle(64);

  // ---- the register block still answers its own sixteen ------------------
  //
  // The composition's first claim, and the one `build/machine.pass` already
  // depends on: MIT's boot PROM turns itself off by writing `0o766012` and
  // nothing else on this bus.
  for (unsigned e = 0; e < 16 && failures < kMaxFailures; ++e) {
    char where[64];
    std::snprintf(where, sizeof where, "diagnostic register %u at 0%o", e, 0766000 + 2 * e);
    const Cycle c = Run(0766000 + 2 * e, false, 0);
    CheckTiming(c, where);
    if (!c.answered()) continue;
    if (c.by != 1) failures += Fail("which slave pulled -UB SSYN", (unsigned)c.by, 1, where);
    if ((c.word & 0xFFFFu) != Poison(e)) failures += Fail("the word", c.word & 0xFFFFu, Poison(e), where);
    ++block_reads;
  }

  // The mode register, bit 5: PROMDISABLE.  The write lands at the machine's
  // next look, so the level is read a microcycle later.
  if (dut->promdisable) failures += Fail("PROMDISABLE before the mode register is written", 1, 0, "reset");
  {
    const Cycle c = Run(0766012, true, 0040);
    CheckTiming(c, "the mode register at 0766012");
    if (c.by != 1) failures += Fail("which slave pulled -UB SSYN", (unsigned)c.by, 1, "the mode register");
    ++block_writes;
    Idle(2 * kMicrocycle);
    if (!dut->promdisable)
      failures += Fail("PROMDISABLE after a write of bit 5 to the mode register", 0, 1, "the mode register");
  }

  // ---- the keyboard ------------------------------------------------------
  //
  // A word off the three 74LS164s at IOBKBD with `EOC.KBD^` as the strobe.
  // The code is a poison: all twenty-four bits distinct between the halves,
  // neither half zero nor all ones, and not the register block's word for any
  // register.
  const uint32_t kScan = 0x9C36E1u;
  if (dut->csr_face & 0x20) failures += Fail("KBD READY before a key", 1, 0, "reset");
  dut->kbd_code = kScan;
  dut->kbd_strobe = 1;
  Tick();
  dut->kbd_strobe = 0;
  dut->kbd_code = 0;   // the cable holds nothing between words
  Idle(8);
  if (!(dut->csr_face & 0x20)) failures += Fail("KBD READY after a key", 0, 1, "the keyboard's strobe");

  // MIT's microcode reads the high half first, because the 74LS74 at IOBKBD
  // 0B30 has `-READ.KBD.LOW` on its clear pin and nothing else.
  ReadCard(kKbdHigh, kFloating | ((kScan >> 16) & 0xFF), "KBD HIGH at 0764102");
  if (!(dut->csr_face & 0x20))
    failures += Fail("KBD READY after a read of the HIGH half", 0, 1, "KBD HIGH");
  ReadCard(kKbdLow, kScan & 0xFFFF, "KBD LOW at 0764100");
  if (dut->csr_face & 0x20) failures += Fail("KBD READY after a read of the LOW half", 1, 0, "KBD LOW");

  // ---- the mouse ---------------------------------------------------------
  //
  // The lines and not the counters: a switch changes, `MOUSE STATUS CHANGE`
  // off the 25LS2521 at IOBMSE 0A21 sets the ready bit at the next `KB CLK^`,
  // and a read of Y clears it where a read of X does not.  `KB CLK^` is
  // 8,000 ns, which is 1,600 ticks.
  if (dut->csr_face & 0x10) failures += Fail("MOUSE READY before the mouse moves", 1, 0, "reset");
  dut->mouse_lines = kMousePress;
  Idle(1700);
  if (!(dut->csr_face & 0x10))
    failures += Fail("MOUSE READY after a switch changed", 0, 1, "the mouse's switches");
  {
    const unsigned held = MouseHeld(kMousePress);
    ReadCard(kMouseX, ((held & 0xF) << 12), "MOUSE X at 0764106");
    if (!(dut->csr_face & 0x10))
      failures += Fail("MOUSE READY after a read of X", 0, 1, "MOUSE X");
    ReadCard(kMouseY, (((held >> 4) & 7) << 12), "MOUSE Y at 0764104");
    if (dut->csr_face & 0x10) failures += Fail("MOUSE READY after a read of Y", 1, 0, "MOUSE Y");
  }

  // ---- the beep ----------------------------------------------------------
  //
  // `-CLICK.AUDIO` is not gated by `-WRITE`, so a read clicks as a write does.
  // One reference is one edge of a square wave.
  {
    const int before = dut->audio;
    ReadCard(kBeep, kOpenBus, "BEEP at 0764110");
    if (dut->audio == before) failures += Fail("AUDIO after a read of the beep", (unsigned)dut->audio,
                                               (unsigned)!before, "BEEP");
    const Cycle c = Run(kBeep, true, 0);
    CheckTiming(c, "a write of the beep at 0764110");
    if (c.by != 2) failures += Fail("which slave pulled -UB SSYN", (unsigned)c.by, 2, "a write of the beep");
    ++card_writes;
    if (dut->audio != before) failures += Fail("AUDIO after a write of the beep", (unsigned)dut->audio,
                                               (unsigned)before, "a write of the beep");
  }

  // ---- the status register ------------------------------------------------
  //
  // `ioboard::csr::WRITABLE` is `0o217`: the 74LS175's four enables and the
  // serial enable, and nothing above them.  The two ready bits stand through
  // a write, which is what this asks after writing zero over them.
  {
    const unsigned write_me = 0x8F;   // all five writable bits
    const Cycle c = Run(kCsr, true, write_me);
    CheckTiming(c, "a write of the status register at 0764112");
    if (c.by != 2) failures += Fail("which slave pulled -UB SSYN", (unsigned)c.by, 2, "a write of the CSR");
    ++card_writes;
    Idle(4);
    if (dut->csr_face != (write_me & 0x8F))
      failures += Fail("the status register's flip-flops after a write", dut->csr_face, write_me & 0x8F,
                       "a write of the CSR");
    // And the read: the five written bits, CLOCK READY in bit 6, the two
    // ready bits this run knows the state of, and ones above.  CLOCK READY is
    // SET from reset, no interval having been loaded.
    const unsigned want = kFloating | 0x80 | 0x40 | 0x0F;
    ReadCard(kCsr, want, "KBD CSR at 0764112");
  }

  // ---- THE CARD'S REQUEST REACHING THE INTERFACE'S OWN REGISTER ----------
  //
  // **This is the wire the composition exists to test, and no other check can
  // see it.**  `build/busint_regs.pass` drives `iob_intr` and `iob_vector`
  // from a trace, because at that seam they are inputs; `build/iob.pass`
  // compares the card's `intr_request` against muir, because at that seam
  // they are outputs.  Only here are they the same wire, so only here can a
  // crossed or dropped connection between the two modules show --- and
  // `.m_awaddr` swapped with `.m_araddr` is the crossing CLAUDE.md records
  // as caught by nothing, anywhere, by any tool.
  //
  // The CSR write above set all five writable bits, `CLOCK INT ENABLE` among
  // them, and `CLOCK READY` has been up since reset with no interval loaded.
  // So the card is asking, with the clock's vector, and `ENABLE UB INTS` is
  // what decides whether the interface takes it.
  {
    const unsigned kClockVector = 0274;   // `ioboard::CLOCK_VECTOR`
    if (!dut->iob_intr)
      failures += Fail("the card's request with CLOCK INT ENABLE set", 0, 1, "the interrupt");
    if (dut->iob_vector != kClockVector)
      failures += Fail("the vector the card is asking with", dut->iob_vector, kClockVector,
                       "the interrupt");
    // With `ENABLE UB INTS` clear the interface does not take it: the request
    // is on the bus and this bit is the grant.
    if (dut->ub_int) failures += Fail("UB INT with ENABLE UB INTS clear", 1, 0, "the interrupt");
    Cycle c = Run(0766040, false, 0);
    CheckTiming(c, "the interrupt status register at 0766040");
    if (c.by != 4)
      failures += Fail("which slave pulled -UB SSYN", (unsigned)c.by, 4, "the interrupt status register");
    if ((c.word & 0xFFFFu) != 0000002u)
      failures += Fail("the interrupt status register before anything is written", c.word & 0xFFFFu,
                       0000002u, "the interrupt status register");
    ++iface_reads;
    // "Enable one more Unibus interrupt" --- `uc-interrupt.lisp` writes 6000
    // here at the end of the cold boot and at the end of every interrupt.
    c = Run(0766040, true, 06000);
    CheckTiming(c, "a write of 6000 to 0766040");
    if (c.by != 4) failures += Fail("which slave pulled -UB SSYN", (unsigned)c.by, 4, "ENABLE UB INTS");
    ++iface_writes;
    Idle(4);
    if (!dut->ub_int)
      failures += Fail("UB INT once ENABLE UB INTS is set over a request", 0, 1, "the interrupt");
    c = Run(0766040, false, 0);
    CheckTiming(c, "the interrupt status register with an interrupt taken");
    ++iface_reads;
    // `UB INT` in bit 15, the vector in bits 2 to 9 in place, `LOCAL ENABLE`
    // and `ENABLE UB INTS` still standing.  `uc-interrupt.lisp` reads the
    // vector back with `(BYTE-FIELD 8 2)`.
    const unsigned want = 0100000u | 06000u | 02u | kClockVector;
    if ((c.word & 0xFFFFu) != want)
      failures += Fail("the interrupt status register with the card asking", c.word & 0xFFFFu, want,
                       "the interrupt status register");
    // And dismissed, as `UB-INTR-RET-0` dismisses it.
    c = Run(0766040, true, 0);
    CheckTiming(c, "a write of zero to 0766040");
    ++iface_writes;
    Idle(4);
    if (dut->ub_int) failures += Fail("UB INT once ENABLE UB INTS is cleared", 1, 0, "the interrupt");
    c = Run(0766040, false, 0);
    CheckTiming(c, "the interrupt status register once the interrupt is dismissed");
    ++iface_reads;
    if ((c.word & 0xFFFFu) != 0000002u)
      failures += Fail("the interrupt status register after the dismissal", c.word & 0xFFFFu,
                       0000002u, "the interrupt status register");
  }

  // ---- the interval timer and the sixty-cycle clock -----------------------
  //
  // `-LOAD INTERVAL` loads the four 74LS193s and clears the 74LS279's latch at
  // CLKTIM 0D09.  A count is 16,000 ns, so an interval of two is 32 us and
  // CLOCK READY is down for the whole of it.
  if (!dut->clock_ready) failures += Fail("CLOCK READY before an interval is loaded", 0, 1, "reset");
  {
    const unsigned iv = 2;
    const Cycle c = Run(kClock, true, iv);
    CheckTiming(c, "a write of the interval timer at 0764124");
    if (c.by != 2) failures += Fail("which slave pulled -UB SSYN", (unsigned)c.by, 2, "the interval timer");
    ++card_writes;
    Idle(4);
    if (dut->interval != iv)
      failures += Fail("the interval last loaded", dut->interval, iv, "the interval timer");
    if (dut->clock_ready) failures += Fail("CLOCK READY after an interval is loaded", 1, 0, "the interval timer");
    // 2 x 16,000 ns is 6,400 ticks; give it a little more than that.
    Idle(6600);
    if (!dut->clock_ready) failures += Fail("CLOCK READY after the interval ran out", 0, 1, "the interval timer");
  }
  // The sixty-cycle counter has not reached its first edge yet, 16,666,666 ns
  // being 3,333,334 ticks and this run being nowhere near it.
  ReadCard(kClock, 0, "the sixty-cycle clock at 0764124, early");

  // ---- the two words with nothing behind them, and the GPIO ---------------
  ReadCard(0764114, kOpenBus, "0764114");
  ReadCard(0764116, kOpenBus, "0764116");
  ReadCard(kGpio, kOpenBus, "the GPIO at 0764126");

  // ---- THE MICROSECOND CLOCK, which is why this slice was urgent ----------
  //
  // MIT's `(TIME)` is this counter shifted, and off it hang the wall clock,
  // `PROCESS-SLEEP`, every Chaosnet timer and the scheduler.  A System 100
  // band's first `READ-MICROSECOND-CLOCK` is at microcycle 2,087,379.
  //
  // The claim is a DIFFERENCE and not a value: two reads whose `-UB MSYN`
  // instants this run measures to be an exact multiple of the card's
  // microsecond apart must differ by exactly that many counts.  The card's
  // microsecond is 1,000 ns, which is 200 ticks, and its edges have been
  // periodic since `first_usec_edge_ns` --- so the count between two instants
  // 200k ticks apart is k whatever the phase, and no model of the offset is
  // needed.  A cycle is placed on the 29-tick MCLK grid, so the two are
  // started a multiple of 5,800 ticks apart and the measured instants are then
  // compared to make sure the placement took.
  {
    const Cycle first = Run(kUsecLow, false, 0);
    CheckTiming(first, "the microsecond counter's low half at 0764120");
    if (first.by != 2)
      failures += Fail("which slave pulled -UB SSYN", (unsigned)first.by, 2, "the microsecond counter");
    ++card_reads;
    const unsigned v1 = first.word & 0xFFFFu;
    if (v1 == 0)
      failures += Fail("the microsecond counter, which has run since power-on", 0, 1, "0764120");
    Named(kUsecLow);

    // Stand still until the next cycle STARTS a whole number of beats after
    // this one did.  A beat is 5,800 ticks, which is the least common multiple
    // of the microcycle's 29 and the card's 200: a cycle begun on the same
    // phase of MCLK runs identically, so its strobe lands the same number of
    // ticks in and the two strobes are then 5,800k apart --- which the run
    // MEASURES below rather than assuming.  Placing it off the strobe instead
    // was tried and is wrong: the wait then lands the start on an arbitrary
    // phase and the strobes come out 22,881 ticks apart, not 23,200.
    const long kBeat = 5800;   // lcm(29, 200)
    const long target = first.start + 4 * kBeat;
    while (tick < target && failures < kMaxFailures) Tick();
    const Cycle second = Run(kUsecLow, false, 0);
    CheckTiming(second, "the microsecond counter's low half, again");
    ++card_reads;
    const unsigned v2 = second.word & 0xFFFFu;
    const long apart = second.msyn - first.msyn;
    if (apart % 200 != 0)
      failures += Fail("the two strobes, in ticks apart", (unsigned long)apart, (unsigned long)(4 * kBeat),
                       "the microsecond counter");
    else if ((long)(v2 - v1) != apart / 200)
      failures += Fail("the microsecond counter's advance", (unsigned long)(v2 - v1),
                       (unsigned long)(apart / 200), "the microsecond counter");

    // The high half is MIT's latch and not the counter.  It reads zero until
    // the count carries at 65,536, which is 13.1 million ticks --- so it is
    // read here, and again past the carry below, and the two are compared
    // against the difference rather than against an offset this file would
    // have to know.
    const Cycle hi = Run(kUsecHigh, false, 0);
    CheckTiming(hi, "the microsecond counter's high half at 0764122");
    ++card_reads;
    if ((hi.word & 0xFFFFu) != 0)
      failures += Fail("the high half before the count carries", hi.word & 0xFFFFu, 0, "0764122");
    Named(kUsecHigh);
  }

  // ---- the sweep ---------------------------------------------------------
  //
  // Every word address of the window, read and written, against muir's own
  // decode for the card and `cadr_spy_registers.sv`'s base for the block.
  // What each cycle must do: be answered by exactly one of them, or end on the
  // NXM timer with MD zero.
  //
  // **AND THE ERROR STATUS REGISTER IS READ EITHER SIDE OF IT**, which is the
  // second wire only the composition can see: `timed_out` and the held
  // `unibus` reach `cadr_busint_regs.sv` from `cadr_busint_xbus.sv` and the
  // decode, and every one of the sweep's unanswered cycles is a Unibus one.
  // So `UNIBUS NXM` must be clear before and set after, and `XBUS NXM` clear
  // throughout: nothing in this run ever addresses the Xbus.
  {
    const Cycle c = Run(0766044, false, 0);
    CheckTiming(c, "the error status register before the sweep");
    if (c.by != 4) failures += Fail("which slave pulled -UB SSYN", (unsigned)c.by, 4, "0766044");
    ++iface_reads;
    // The high byte pulled up, `-FREE` set, and neither NXM bit: nothing has
    // timed out yet, every cycle so far having been answered.
    if ((c.word & 0xFFFFu) != 0177500u)
      failures += Fail("the error status register before the sweep", c.word & 0xFFFFu, 0177500u,
                       "0766044");
  }

  long swept = 0, answered_by_card = 0, answered_by_block = 0, answered_by_iface = 0, unanswered = 0;
  long exempt = 0;
  for (unsigned u = kSweepFirst; u <= kSweepLast && failures < kMaxFailures; u += 2) {
    for (int w = 0; w < 2; ++w) {
      char where[64];
      std::snprintf(where, sizeof where, "0%o %s", u, w ? "written" : "read");
      bool want_card = (card[u] & (w ? 2 : 1)) != 0;
      if (want_card && Unbuilt(u)) {
        want_card = false;
        ++exempt;
      }
      const bool want_block = (iface[u] == kDiagnostic);
      const bool want_iface = (iface[u] != kDiagnostic && iface[u] != kNoIface);
      const Cycle c = Run(u, w != 0, 0x5A5Au);
      ++swept;
      const int want_by = (want_card ? 2 : 0) | (want_block ? 1 : 0) | (want_iface ? 4 : 0);
      if (!want_by) {
        if (c.answered()) {
          failures += Fail("a slave answered an address nothing is at", (unsigned)c.by, 0, where);
        } else {
          if (!c.timed_out) failures += Fail("NXM TIMEOUT on a cycle nothing answered", 0, 1, where);
          if (c.word != 0) failures += Fail("MEM<31:0> on a cycle nothing answered", c.word, 0, where);
          ++unanswered;
        }
        continue;
      }
      if (!c.answered()) {
        failures += Fail("-UB SSYN", 0, 1, where);
        continue;
      }
      if (c.by != want_by) failures += Fail("which slave pulled -UB SSYN", (unsigned)c.by, (unsigned)want_by, where);
      if (c.timed_out) failures += Fail("NXM TIMEOUT on an answered cycle", 1, 0, where);
      if (want_iface) {
        ++answered_by_iface;
        // The words are `build/busint_regs.pass`'s, at that block's own seam
        // and against muir.  What is checked here is that the word did not
        // come from the OTHER two slaves: the register block's poison is
        // driven from this address on every cycle, and a card read is
        // impossible at these addresses by the disjointness above.
        if (!w && (c.word & 0xFFFFu) == Poison(SpyEadr(u)))
          failures += Fail("a bus interface register read came back as the block's word",
                           c.word & 0xFFFFu, 0, where);
      } else if (want_block) {
        ++answered_by_block;
        if (!w && (c.word & 0xFFFFu) != Poison(SpyEadr(u)))
          failures += Fail("the register block's word", c.word & 0xFFFFu, Poison(SpyEadr(u)), where);
      } else {
        ++answered_by_card;
        if (!w && (c.word & 0xFFFFu) == Poison(SpyEadr(u)))
          failures += Fail("a card read came back as the register block's word", c.word & 0xFFFFu, 0, where);
      }
    }
  }

  // The sweep's unanswered cycles, in the register MIT put them in.
  {
    const Cycle c = Run(0766044, false, 0);
    CheckTiming(c, "the error status register after the sweep");
    ++iface_reads;
    // `UNIBUS NXM` is bit 3, `XBUS NXM` bit 0, and every cycle this run has
    // given up on was on the Unibus.
    if ((c.word & 0xFFFFu) != (0177500u | 010u))
      failures += Fail("the error status register after the sweep's timeouts", c.word & 0xFFFFu,
                       0177500u | 010u, "0766044");
    // `-RESET ERR`: "Writing this location ignores the data written and
    // clears the status bits".
    const Cycle w = Run(0766044, true, 0);
    CheckTiming(w, "a write of 0766044");
    ++iface_writes;
    const Cycle a = Run(0766044, false, 0);
    CheckTiming(a, "the error status register after -RESET ERR");
    ++iface_reads;
    if ((a.word & 0xFFFFu) != 0177500u)
      failures += Fail("the error status register after -RESET ERR", a.word & 0xFFFFu, 0177500u,
                       "0766044");
  }

  // ---- the arbiter covers both slaves -------------------------------------
  //
  // The console takes the BUS and not the block, so a processor cycle to the
  // card is masked while it holds, exactly as one to the block is.  It can
  // only name the register block itself --- `cadr_console.sv` builds its
  // address as `SPY_BASE | eadr<<1` --- so what is checked is that a card
  // cycle standing when the console takes the bus waits, and then completes.
  long console_held_ticks = 0, console_cycles = 0;
  {
    // **THE CONSOLE HOLDS THE BUS ACROSS SEVERAL CYCLES, WHICH IS WHAT MAKES
    // THE WINDOW EXIST AT ALL.**  Measured before it was written: one console
    // cycle is `DIAGNOSTIC_NS` plus the drop, about fifty-five ticks, and a
    // processor Unibus cycle takes seventy-eight to a hundred and six ticks
    // from `-MEMRQ` to `-UB MSYN` --- two master clocks of arbitration and
    // then `UNIBUS_ADDRESS_NS`.  So a console that took the bus for ONE
    // register would always have let it go before the processor's strobe
    // rose, and a card wired to the wrong master would never be caught.
    //
    // A console does not read one register.  `cadr_console.sv` holds
    // `dbg_req` up while its engine walks what a program asked for --- a
    // `status` read is all sixteen --- and `cadr_console_bus.sv` holds the
    // grant until the request drops.  So this drives cycles back to back with
    // the request up throughout, which is the console's own shape, and stops
    // at whichever comes later: four of them, or the tick the card's answer
    // to the processor would have been due.  The assertion after the loop is
    // that the second condition was actually met, so that a window too short
    // to test anything fails here rather than passing quietly.
    dut->con_req = 1;
    dut->con_addr = 0766000 + 2 * 5;   // `spy::BASE`, which is the console's whole vocabulary
    dut->con_write = 0;
    dut->spy_rdata = Poison(5);
    for (long g = 0; g < 200 && !dut->con_gnt; ++g) Tick();
    if (!dut->con_gnt) failures += Fail("the console's grant", 0, 1, "the arbiter");

    // The processor asks for the card while the console holds the bus.
    //
    // **THE CARD CYCLE IS THE SIXTY-CYCLE CLOCK AND NOT THE MICROSECOND
    // COUNTER, AND THAT IS THE DIFFERENCE BETWEEN A CHECK AND A DECORATION.**
    // Measured: with `0o764120` here, the card's answer is due `USEC_LOW_T`
    // past the NEXT edge of its microsecond clock, which is 63 to 263 ticks
    // after the strobe, and the strobe itself is 78 to 106 ticks after
    // `-MEMRQ` --- so the answer often fell PAST the end of the hold and the
    // record aimed at this, `unibus-the-card-is-not-behind-the-arbiter`,
    // SURVIVED.  `0o764124` answers a flat `IOB_STRAIGHT_NS` --- fifty ticks
    // --- after the strobe, and the loop below then holds the bus until the
    // strobe has been up long enough for that answer to be due, and fails if
    // it could not.  A race check needs the stimulus that loses the race.
    dut->phys = UnibusPhysical(kClock);
    dut->wrcyc = 0;
    dut->n_memrq = 0;

    // The card's straight answer is `IOB_STRAIGHT_NS` past the strobe, plus a
    // tick for the held match; twenty more is margin over the console's own
    // cycle boundaries.
    const long kCardDue = 50 + 1 + 20;
    long msyn_first = -1;
    for (int cycle = 0; cycle < 12 && failures < kMaxFailures; ++cycle) {
      if (cycle >= 4 && msyn_first >= 0 && tick >= msyn_first + kCardDue) break;
      dut->con_msyn = 1;
      for (long g = 0; g < 400; ++g) {
        Tick();
        ++console_held_ticks;
        if (dut->ub_msyn_o && msyn_first < 0) msyn_first = tick - 1;
        // The processor's own master must see nothing: its strobe is masked.
        if (dut->ub_ssyn_o) {
          failures += Fail("-UB SSYN reaching the processor while the console held the bus", 1, 0,
                           "the arbiter");
          break;
        }
        // And the card must answer nobody.  The console names the register
        // block; a card on the wrong master answers the processor's address
        // lines while a second master is driving the bus.
        if (dut->ub_ssyn_by & 2) {
          failures += Fail("the I/O board answering while the console held the bus",
                           (unsigned)dut->ub_ssyn_by, 1, "the arbiter");
          break;
        }
        if (dut->con_ssyn) break;
      }
      if (!dut->con_ssyn) {
        failures += Fail("the console's own -UB SSYN", 0, 1, "the arbiter");
        break;
      }
      if ((dut->con_rdata & 0xFFFFu) != 0 && (dut->con_rdata & 0xFFFFu) != Poison(5))
        failures += Fail("the console's word", dut->con_rdata & 0xFFFFu, Poison(5), "the arbiter");
      // **THE REQUEST IS DROPPED ONLY ONCE THE SLAVE HAS LET THE LINE GO**,
      // which is what `cadr_console.sv`'s `E_DROP` does and why: "dropping the
      // request while SSYN is still up would hand the next master a bus that
      // is already answering".  This master model follows the console in that,
      // and it matters --- written the impolite way, with the request dropped
      // beside the strobe, the processor's standing cycle was acknowledged by
      // the register block's leftover `-UB SSYN` at `ub_ssyn_by` 1 rather than
      // by the card at 2.  Measured, not reasoned: it is the same fact as the
      // bus idling a tick at every change of owner in this module's channel
      // arbiter, and the discipline lives in the console rather than in the
      // arbiter.
      dut->con_msyn = 0;
      for (long g = 0; g < 200; ++g) {
        Tick();
        ++console_held_ticks;
        if (!dut->ub_ssyn_by) break;
      }
      ++console_cycles;
    }
    // **THE WINDOW HAS TO HAVE EXISTED, OR NOTHING ABOVE WAS TESTED.**  The
    // processor's strobe must have gone up inside the hold AND the hold must
    // have outlasted the instant the card would have answered it.  This is
    // the assertion that turns "the card did not answer" from a tautology
    // into a measurement, and it is here because the first version of this
    // section had no window at all and said nothing.
    if (msyn_first < 0)
      failures += Fail("the processor's -UB MSYN rising inside the console's hold", 0, 1,
                       "the arbiter");
    else if (tick < msyn_first + kCardDue)
      failures += Fail("ticks of hold after the processor's strobe rose",
                       (unsigned long)(tick - msyn_first), (unsigned long)kCardDue, "the arbiter");
    dut->con_req = 0;
    // And now the processor's cycle, which has been standing all along, must
    // finish against the card.
    dut->spy_rdata = Poison(SpyEadr(kUsecLow));
    Cycle c;
    int ssyn_last = 0, loadmd_last = 1, memack_last = 1, msyn_last = dut->ub_msyn_o;
    for (long g = 0; g < 2000; ++g) {
      Tick();
      const long now = tick - 1;
      if (dut->ub_msyn_o && !msyn_last && c.msyn < 0) c.msyn = now;
      msyn_last = dut->ub_msyn_o;
      if (dut->ub_ssyn_o && !ssyn_last && c.ssyn < 0) { c.ssyn = now; c.by = dut->ub_ssyn_by; }
      ssyn_last = dut->ub_ssyn_o;
      if (!dut->n_loadmd && loadmd_last && c.loadmd < 0) { c.loadmd = now; c.word = dut->rdata; }
      loadmd_last = dut->n_loadmd;
      if (!dut->n_memack && memack_last) { c.memack = now; c.timed_out = dut->timed_out; break; }
      memack_last = dut->n_memack;
    }
    if (!c.answered() || c.by != 2 || c.timed_out)
      failures += Fail("the card's answer once the console let the bus go",
                       (unsigned)(c.answered() ? c.by : 0), 2, "the arbiter");
    else
      ++card_reads;
    dut->n_memrq = 1;
    for (long g = 0; g < 200; ++g) {
      Tick();
      if (dut->n_memgrant && !dut->ub_msyn_o) break;
    }
    Idle(4);
  }

  // ---- the counter's high half, past the carry ----------------------------
  //
  // 65,536 of the card's microseconds is 13.1 million ticks.  Standing still
  // for them is what makes the high half a live comparison rather than zero
  // against zero, which is the control-store-comes-up-zero trap in a register
  // sixteen bits wide.
  long carry_ticks = 0;
  if (failures < kMaxFailures) {
    const Cycle before_lo = Run(kUsecLow, false, 0);
    const Cycle before_hi = Run(kUsecHigh, false, 0);
    CheckTiming(before_lo, "the low half, before the carry");
    CheckTiming(before_hi, "the high half, before the carry");
    card_reads += 2;
    const uint32_t before = ((before_hi.word & 0xFFFFu) << 16) | (before_lo.word & 0xFFFFu);
    // Stand still until the count is past 65,536 and on the same phase, so the
    // advance is again a whole number of microseconds this run can name.
    const long beats = ((65536L - (long)(before & 0xFFFFu) + 400L) * 200L + 5799L) / 5800L;
    const long target = before_lo.start + beats * 5800L;
    while (tick < target && failures < kMaxFailures) { Tick(); ++carry_ticks; }
    const Cycle after_lo = Run(kUsecLow, false, 0);
    const Cycle after_hi = Run(kUsecHigh, false, 0);
    CheckTiming(after_lo, "the low half, past the carry");
    CheckTiming(after_hi, "the high half, past the carry");
    card_reads += 2;
    const uint32_t after = ((after_hi.word & 0xFFFFu) << 16) | (after_lo.word & 0xFFFFu);
    const long apart = after_lo.msyn - before_lo.msyn;
    if (apart % 200 != 0)
      failures += Fail("the two strobes, in ticks apart", (unsigned long)apart,
                       (unsigned long)(beats * 5800L), "the counter's carry");
    else if ((long)(after - before) != apart / 200)
      failures += Fail("the microsecond counter's advance across the carry", after - before,
                       (unsigned long)(apart / 200), "the counter's carry");
    if ((after >> 16) != 1)
      failures += Fail("the high half past the carry", after >> 16, 1, "the counter's carry");
    if ((before >> 16) != 0)
      failures += Fail("the high half before the carry", before >> 16, 0, "the counter's carry");
    // And the sixty-cycle clock, which has had 65.5 ms and cannot still read
    // zero.  Its exact count against muir is `build/iob.pass`'s.
    const Cycle mains = Run(kClock, false, 0);
    CheckTiming(mains, "the sixty-cycle clock, late");
    ++card_reads;
    if ((mains.word & 0xFFFFu) == 0)
      failures += Fail("the sixty-cycle clock after 65 ms", 0, 1, "the sixty-cycle clock");
  }

  dut->final();
  delete dut;

  if (failures) {
    std::fprintf(stderr, "FAIL: %d mismatches over %ld ticks\n", failures, tick);
    return 1;
  }

  // ---- what the run reached ----------------------------------------------
  int thin = 0;
  auto least = [&](const char *what, long got, long want) {
    if (got < want) {
      std::fprintf(stderr, "FAIL: the run reached %ld %s and cannot hold anything with fewer than %ld\n", got,
                   what, want);
      ++thin;
    }
  };
  least("reads answered by the card", card_reads, 15);
  if (card_regs_named != 0xFFFu) {
    std::fprintf(stderr,
                 "FAIL: of the card's twelve registers this run named %d, mask 0x%03x --- every one of\n"
                 "      0764100 to 0764126 has to be read with its word compared against the stimulus\n",
                 __builtin_popcount(card_regs_named), card_regs_named);
    ++thin;
  }
  least("writes answered by the card", card_writes, 3);
  least("reads answered by the register block", block_reads, 16);
  least("reads answered by the bus interface's own registers", iface_reads, 6);
  least("writes answered by the bus interface's own registers", iface_writes, 3);
  least("cycles nothing answered", unanswered, 100);
  least("addresses swept", swept, 3000);
  least("console cycles run while a card cycle stood behind them", console_cycles, 4);
  if (main_memory_cycles != 0) {
    std::fprintf(stderr, "FAIL: %ld of these cycles reached the memory port, and a Unibus address must not\n",
                 main_memory_cycles);
    ++thin;
  }
  if (thin) return 1;

  std::printf(
      "ok: %ld ticks --- the machine's own bus cycle reaches ALL THREE Unibus slaves, and no other\n"
      "    check runs a Unibus read at all (MIT's boot PROM runs one Unibus cycle in 17,466 and it is\n"
      "    the write of the mode register).  %ld reads and %ld writes answered by the I/O board, %ld and\n"
      "    %ld by the diagnostic register block, %ld and %ld by the bus interface's own registers, each\n"
      "    with -LOADMD %ld ticks after -UB SSYN and -MEMACK %ld, the word on MEM<15:0> and zero above.\n"
      "    The card's request reached 0766040 through the machine's own bus cycle: UB INT and the\n"
      "    clock's vector 0274 read back once ENABLE UB INTS was written, and gone when it was\n"
      "    cleared --- the one place iob_intr and iob_vector are the same wire at both ends.  And\n"
      "    the sweep's timeouts set UNIBUS NXM in the error status register and not XBUS NXM,\n"
      "    with -RESET ERR clearing it.\n"
      "    The keyboard's scan code, the mouse's seven lines, the interval and the interrupt enables\n"
      "    came back as this testbench put them in; the microsecond counter advanced by exactly the\n"
      "    number of its own microseconds between two measured strobes, across its 65,536 carry, and\n"
      "    the sixty-cycle clock went from zero to not zero over %ld ticks of standing still.\n"
      "    The sweep: %ld cycles over 0%o-0%o read and written, %ld answered by the card, %ld by the\n"
      "    block, %ld by nothing --- each ending on the NXM timer with MD zero --- and NEVER TWO AT\n"
      "    ONCE, which is measured at ub_ssyn_by and not inferred from the word.  EXEMPT: %ld\n"
      "    directions in the Chaosnet interface's and the serial port's groups\n"
      "    (0764140-0764176), which ioboard::answers decodes and this card does not answer,\n"
      "    those being two other slices.\n"
      "    The three slaves' sets are disjoint over all %zu addresses in both directions, against\n"
      "    muir's own ioboard::answers (%ld DEC rows and %ld DECNONE runs out of %s) and its\n"
      "    busint::register (%ld IFACE rows out of %s) --- no transcription of either.\n"
      "    The bus interface's own registers answered %ld of the sweep's directions: the interrupt\n"
      "    block at 0766040-0766076 and the Unibus map at 0766140-0766176.\n",
      tick, card_reads, card_writes, block_reads, block_writes, iface_reads, iface_writes, kStrobeT,
      kAckT, carry_ticks, swept,
      kSweepFirst, kSweepLast, answered_by_card, answered_by_block, unanswered, exempt, kAddrs, dec_rows,
      dec_none_runs, path, iface_rows, ipath, answered_by_iface);
  return 0;
}
