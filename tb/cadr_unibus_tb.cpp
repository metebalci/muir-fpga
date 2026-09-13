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
//   - **A cycle nothing answers gives MD zero**, which is the decision for an
//     unanswered read, one bus along from where it was made.
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
// THE THIRD MASTER, AND WHAT IT CLOSED.  `rtl/machine/cadr_dbgin.sv` is MIT's
// DBGIN page and is instantiated inside `cadr_memory_path.sv` beside the two
// Unibus slaves, so this is the only check in the tree where a DEBUG CYCLE
// crosses the composed machine.  `build/dbgin.pass` puts that page on an
// arbiter with the diagnostic register block and the processor and holds the
// cable's own instants to muir; `build/busint_regs.pass` holds the mapped
// window at its own seam.  Neither has the cable and the window in one
// design, and until they are in one design a debug cycle cannot reach main
// memory.  The last section here drives one that does, and reads the error
// status byte --- which is assembled in `cadr_memory_path.sv` out of two
// modules and nowhere else --- back over MIT's own wires.
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
#include <map>
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

// **NOTHING IN THE CARD'S BLOCK IS EXEMPT ANY MORE.**  This file used to
// exempt `0o764140`-`0o764176` --- `ioboard::answers`' groups 6 and 7, the
// Chaosnet interface and the serial port --- because the card decoded them
// and answered neither, those being two other slices.  Both are built: the
// AIM-628 registers and both packet buffers, and the 2651's four registers,
// are on the card, with the cable and the line on a seam the two Linux
// programs own.  So every direction `ioboard::answers` decodes is answered
// here and the sweep holds all of them.

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

// And a word injective in the DDR BYTE address, for the mapped window's own
// section. `cadr_ddr_map::main_byte_address` is `0x1800_0000 + (phys << 2)`,
// so the physical word address is recoverable from what the port asks for and
// the claim is on the address as much as on the word: a translation one page
// or one word wide reaches a byte address this testbench put nothing else at.
// Multiplication by an odd constant is a bijection on 32 bits.
uint32_t MainPoison(uint32_t byte_addr) {
  return ((byte_addr ^ 0x2AAAAAAAu) * 0x85EBCA6Bu) ^ 0x3C3C3C3Cu;
}

// The DDR byte address the machine's memory port names a physical word at,
// and the physical word address back out of one.
constexpr uint32_t kMainBase = 0x18000000u;
uint32_t MainByteAddress(uint32_t phys) { return kMainBase + (phys << 2); }

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
  // The mapped window's first map entry and the physical page
  // `Machine::map_entry` reads out of it, out of the `MAPSWEEP` rows. The
  // section below programs that entry and then reaches main memory through
  // it, and the page it must land on is muir's reading of the word and not
  // this file's arithmetic on it.
  // All sixteen are kept, because the debug cable's section below reaches
  // main memory through a different one and must compare against muir's
  // reading of that word rather than against arithmetic of its own.
  unsigned sweep_entry[16] = {0};
  uint32_t sweep_page[16] = {0};
  unsigned sweep_entry0 = 0;
  uint32_t sweep_page0 = 0;
  int sweep_seen = 0;
  while (std::fgets(line, sizeof line, g)) {
    unsigned a, b, k, n;
    if (std::sscanf(line, "MAPSWEEP %x %x %x", &k, &a, &b) == 3) {
      if (k < 16) {
        sweep_entry[k] = a;
        sweep_page[k] = b;
      }
      if (k == 0) {
        sweep_entry0 = a;
        sweep_page0 = b;
      }
      ++sweep_seen;
    } else if (std::sscanf(line, "IFACENONE %x %x", &a, &b) == 2) {
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
  if (sweep_seen != 16 || !(sweep_entry0 & 0x8000u) || !(sweep_entry0 & 0x4000u) || !sweep_page0) {
    std::fprintf(stderr,
                 "FAIL: %s carries %d MAPSWEEP rows and entry 0 is 0x%x naming page 0%o; the "
                 "window's section needs a valid, writable entry\n",
                 ipath, sweep_seen, sweep_entry0, sweep_page0);
    return 2;
  }
  // The debug cable's section reaches main memory through entry 3, so that
  // one has to be valid and writable as well and has to name a page of its
  // own.  Checked here rather than assumed, because a trace whose entries
  // stopped being distinct would make the window's own byte addresses
  // ambiguous and nothing would say so.
  for (unsigned k = 0; k < 16; ++k) {
    if (!(sweep_entry[k] & 0x8000u) || !(sweep_entry[k] & 0x4000u) || !sweep_page[k]) {
      std::fprintf(stderr,
                   "FAIL: %s: MAPSWEEP entry %u is 0x%x naming page 0%o, and every one of the "
                   "sixteen has to be valid and writable\n",
                   ipath, k, sweep_entry[k], sweep_page[k]);
      return 2;
    }
    for (unsigned j = 0; j < k; ++j)
      if (sweep_page[j] == sweep_page[k]) {
        std::fprintf(stderr, "FAIL: %s: MAPSWEEP entries %u and %u both name page 0%o\n", ipath, j,
                     k, sweep_page[k]);
        return 2;
      }
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
  // MIT's cable, idle.  `dbg_in_req` high means `-DEBUG IN REQ` is DOWN,
  // which is the sense the whole transport uses, so idle is zero.
  dut->dbg_rst = 1;
  dut->dbg_in_req = 0;
  dut->dbg_in_wr = 0;
  dut->dbg_in_a = 0;
  dut->dbd_in = 0;
  dut->eval();

  // One tick.  Nothing is behind the memory port on a Unibus cycle --- the
  // decode sends none of these addresses there --- but it is answered anyway
  // so that a fault which sent one to main memory hangs nothing and shows up
  // as the wrong slave rather than as a stuck run.
  //
  // **EXCEPT WHILE THE MAPPED WINDOW IS OPEN**, which is the one thing here
  // that reaches main memory on purpose: a foreign Unibus master's cycle at
  // `0o140000`-`0o177777` is an Xbus cycle at the translated address, and
  // that section opens this port for exactly its own cycles.  The two are
  // counted apart so that the claim below --- no Unibus address of the
  // machine's own reaches the memory port --- stays the claim it was.
  long main_memory_cycles = 0, window_mem_cycles = 0;
  int window_open = 0;
  std::map<uint32_t, uint32_t> main_mem;
  uint32_t last_mem_addr = 0, last_mem_wdata = 0;
  int last_mem_write = 0;
  // **THE TWO RESETS, AND THE LOOP THAT TELLS THEM APART.**  `cadr_memory_path`
  // has `rst` and `dbg_rst`, and the DBGIN page takes the second: the machine's
  // reset carries `debuggee_reset`, which is the page's own modifier bit 1, and
  // a modifier register cleared by its own bit 1 clears the bit that is
  // clearing it.  Until something writes that bit the two are the same tick
  // and a check cannot tell them apart, which is why the last section of the
  // cable's own run closes the loop `boards/arty-z7-20/cadr_arty.sv` closes ---
  // `debuggee_reset` registered and joined into the machine's reset --- and
  // writes it.  `cable_reset_wired` is zero everywhere else, so nothing else in
  // this file moves by a tick.
  int cable_rst_q = 0, cable_reset_wired = 0;

  // **`UB MD LOAD`, THE ONE THING THIS MODULE PUTS OUT THAT IS NEITHER THE
  // BUS NOR THE UNIBUS.**  A foreign master's mapped write through a page
  // whose high five bits are ones is `busint::map_to_md` --- CC's
  // `CC-WRITE-MD` --- and the word goes into the processor's `MD` instead of
  // onto the Xbus.  `MD` is a level up, so what this file stands in for is
  // the processor taking the word: `ub_md_ack` at a latency that MOVES, for
  // `tb/cadr_busint_regs_tb.cpp`'s reason, so a block counting ticks from
  // `-UB MSYN` could not pass.
  long md_latency = 3, md_count = -1, md_loads = 0, md_req_ticks = 0;
  uint32_t last_md_data = 0;
  int md_open = 0, md_warned = 0;
  auto Tick = [&]() {
    dut->rst = (tick == 0) || cable_rst_q;
    dut->dbg_rst = (tick == 0);
    dut->mclk = (tick % kMicrocycle) == 0;
    dut->clk = 1;
    dut->eval();
    // Driven INTO this edge, as `mem_done` is.
    dut->ub_md_ack = 0;
    if (dut->ub_md_req) {
      ++md_req_ticks;
      if (md_count < 0) md_count = md_latency;
      if (md_count == 0) {
        dut->ub_md_ack = 1;
        last_md_data = dut->ub_md_data;
        ++md_loads;
        md_count = -1;
      } else {
        --md_count;
      }
    } else {
      md_count = -1;
    }
    dut->mem_done = dut->mem_req;
    dut->mem_rdata = 0;
    if (dut->mem_req) {
      if (window_open) {
        ++window_mem_cycles;
        last_mem_addr = dut->mem_addr;
        last_mem_write = dut->mem_write;
        last_mem_wdata = dut->mem_wdata;
        if (dut->mem_write) main_mem[dut->mem_addr] = dut->mem_wdata;
        const auto it = main_mem.find(dut->mem_addr);
        dut->mem_rdata = (it == main_mem.end()) ? MainPoison(dut->mem_addr) : it->second;
      } else {
        ++main_memory_cycles;
      }
    }
    dut->eval();
    // Nothing outside the `MD` section may ask for a load at all: the port
    // is the debugger's alone and the machine's own cycles never reach it.
    if (dut->ub_md_req && !md_open && !md_warned) {
      failures += Fail("UB MD LOAD asked for outside the mapped window's MD page", 1, 0,
                       "the machine");
      md_warned = 1;   // say it once
    }
    // `always_ff @(posedge clk) mach_rst <= rst || con_mach_rst ||
    // debuggee_reset;`, which is the line the top level carries.
    cable_rst_q = cable_reset_wired && dut->debuggee_reset;
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
  for (unsigned u = kSweepFirst; u <= kSweepLast && failures < kMaxFailures; u += 2) {
    for (int w = 0; w < 2; ++w) {
      char where[64];
      std::snprintf(where, sizeof where, "0%o %s", u, w ? "written" : "read");
      const bool want_card = (card[u] & (w ? 2 : 1)) != 0;
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

  // ---- the mapped window, through the arbiter and into main memory --------
  //
  // **THIS IS THE COMPOSITION THE WINDOW EXISTS FOR**, and it is the half
  // `build/busint_regs.pass` cannot make: there the Xbus seam is two ports
  // the testbench drives, and here it is the arbiter, the bridge and the
  // machine's own memory port.  A foreign Unibus master writes a map entry,
  // reaches `0o140000`-`0o177777` through it, and the word comes off
  // `mem_addr` at the translated address.
  //
  // **THE MASTER HERE IS THIS TESTBENCH ON THE CONSOLE'S SEAM**, which is the
  // seam a foreign master presents to this module: `con_req`, `con_addr` and
  // `con_msyn`, with `con_gnt` half of the `ub_foreign` the window answers on.
  // So this section is the arbiter and the datapath held to a property; the
  // words and the responders are `build/busint_regs.pass`'s, against muir.
  //
  // **AND THE SECTION AFTER IT RUNS THE SAME ROUTE WITH MIT'S OWN MASTER.**
  // `rtl/machine/cadr_dbgin.sv` is instantiated in `cadr_memory_path.sv` and
  // its grant is the other half of `ub_foreign`, so the debug cable makes
  // mapped cycles in the composed machine.  `rtl/plumbing/cadr_console.sv`
  // still cannot: it builds its address as `SPY_BASE | eadr<<1` with four
  // bits of `eadr` and can put nothing but `0o766000`-`0o766036` on the bus.
  // Both are kept, because they are different claims --- this one is the
  // arbiter's seam and that one is MIT's cable end to end.
  long window_cycles = 0, window_reads = 0, window_writes = 0;
  int window_timed_out = 0;
  if (failures < kMaxFailures) {
    // The entry, written by the PROCESSOR's own master --- the map registers
    // answer everybody and only the window is foreign-only.
    Run(0766140, true, sweep_entry0);
    const Cycle back = Run(0766140, false, 0);
    if ((back.word & 0xFFFFu) != sweep_entry0)
      failures += Fail("the map entry read back", back.word & 0xFFFFu, sweep_entry0, "the window");
    iface_writes += 1;
    iface_reads += 1;

    // A foreign master's cycle, driven the way the console drives one: the
    // request up, the grant taken with the processor's strobe down, the
    // strobe held until the slave answers, and the request dropped only once
    // the line is free.
    auto Foreign = [&](unsigned uaddr, bool write, unsigned wdata, long guard) {
      dut->con_req = 1;
      dut->con_addr = uaddr;
      dut->con_write = write ? 1 : 0;
      dut->con_wdata = wdata;
      for (long gg = 0; gg < 200 && !dut->con_gnt; ++gg) Tick();
      dut->con_msyn = 1;
      long at = -1;
      unsigned word = 0, by = 0;
      for (long gg = 0; gg < guard; ++gg) {
        Tick();
        // **`ub_ssyn_o` IS THE PROCESSOR'S OWN LINE AND IS MASKED HERE**:
        // `cadr_console_bus.sv` makes `cpu_ssyn` zero while another master
        // holds the bus, which is the discipline the section above measures.
        // A foreign master's answer is its own `-UB SSYN`.
        if (dut->con_ssyn) {
          at = tick - 1;
          // The word off the BUS, at the instant the slave pulls the line:
          // `cadr_console_bus.sv` captures the console's own copy at the
          // microcycle boundary, and what is being held here is the slave.
          word = dut->ub_rdata_o & 0xFFFFu;
          by = dut->ub_ssyn_by;
          break;
        }
      }
      dut->con_msyn = 0;
      for (long gg = 0; gg < 400; ++gg) {
        Tick();
        if (!dut->ub_ssyn_by) break;
      }
      dut->con_req = 0;
      for (long gg = 0; gg < 40; ++gg) Tick();
      ++window_cycles;
      return std::make_pair((long)by, (long)((at < 0) ? -1 : (long)word));
    };

    window_open = 1;
    const uint32_t phys = (sweep_page0 << 8) | 0x2Au;
    const uint32_t byte_addr = MainByteAddress(phys);
    const uint32_t want = MainPoison(byte_addr);

    // The EVEN word: an Xbus read at the translated address, whose low half
    // is the answer and whose high half goes into the page's read buffer.
    const unsigned base = 0140000u + (0u << 10) + (0x2Au << 2);
    auto r = Foreign(base, false, 0, 4000);
    ++window_reads;
    if (r.second < 0) {
      failures += Fail("-UB SSYN on a mapped read", 0, 1, "the window");
    } else {
      if (r.first != 4)
        failures += Fail("which slave answered the mapped read", (unsigned)r.first, 4,
                         "the window");
      if ((uint32_t)r.second != (want & 0xFFFFu))
        failures += Fail("the low half of the mapped word", (unsigned)r.second, want & 0xFFFFu,
                         "the window");
      if (last_mem_addr != byte_addr)
        failures += Fail("the byte address the memory port was asked for", last_mem_addr,
                         byte_addr, "the window");
      if (last_mem_write)
        failures += Fail("the direction at the memory port on a mapped read", 1, 0, "the window");
    }
    // The ODD word: the read buffer, no Xbus cycle, the HIGH half.
    const long before = window_mem_cycles;
    r = Foreign(base + 2, false, 0, 4000);
    ++window_reads;
    if (r.second < 0)
      failures += Fail("-UB SSYN on a mapped buffer read", 0, 1, "the window");
    else if ((uint32_t)r.second != (want >> 16))
      failures += Fail("the high half out of the read buffer", (unsigned)r.second, want >> 16,
                       "the window");
    if (window_mem_cycles != before)
      failures += Fail("memory cycles for a read of the odd word",
                       (unsigned long)(window_mem_cycles - before), 0, "the window");

    // And a WRITE: the even word into the write buffer, the odd word an Xbus
    // write of the two halves at the same address.
    const long before_w = window_mem_cycles;
    Foreign(base, true, 0x4321, 4000);
    ++window_writes;
    if (window_mem_cycles != before_w)
      failures += Fail("memory cycles for a write of the even word",
                       (unsigned long)(window_mem_cycles - before_w), 0, "the window");
    r = Foreign(base + 2, true, 0x8765, 4000);
    ++window_writes;
    if (!last_mem_write || last_mem_addr != byte_addr || last_mem_wdata != 0x87654321u)
      failures += Fail("the word the mapped write put in main memory", last_mem_wdata,
                       0x87654321u, "the window");
    // Read it back through the map, which is what says the whole route works
    // in both directions rather than each half on its own.
    r = Foreign(base, false, 0, 4000);
    ++window_reads;
    if (r.second < 0 || (uint32_t)r.second != 0x4321u)
      failures += Fail("the low half read back through the map", (unsigned)r.second, 0x4321u,
                       "the window");
    r = Foreign(base + 2, false, 0, 4000);
    ++window_reads;
    if (r.second < 0 || (uint32_t)r.second != 0x8765u)
      failures += Fail("the high half read back through the map", (unsigned)r.second, 0x8765u,
                       "the window");
    window_open = 0;

    // **AND THE MACHINE'S OWN CYCLE AT THE SAME ADDRESS TIMES OUT.**
    // `busint::decode` answers `Responder::NoUnibus` over the whole window,
    // so the processor is not mapped --- and this is that claim in the
    // composition, where `ub_foreign` is a wire from the arbiter rather than
    // a port the testbench holds.  A block that answered it would reach main
    // memory here and `main_memory_cycles` would say so as well.
    const Cycle own = Run(base, false, 0);
    if (!own.timed_out || own.answered())
      failures += Fail("the processor's own cycle in the mapped window",
                       (unsigned)(own.answered() ? own.by : 0), 0, "the window");
    else
      window_timed_out = 1;
    ++unanswered;
  }

  // ---- MIT's debug cable, the third master, through the composed machine --
  //
  // **THIS IS THE FIRST CHECK IN THE TREE THAT DRIVES A DEBUG CYCLE THROUGH
  // `cadr_memory_path.sv`**, and it is what the two slices above it were
  // each missing half of.  `build/dbgin.pass` puts `cadr_dbgin.sv` on an
  // arbiter with the diagnostic register block and the processor and holds
  // the cable's own instants to muir; `build/busint_regs.pass` holds the
  // mapped window at its own seam.  Neither has the cable and the window in
  // one design, and until they are in one design a debug cycle cannot reach
  // main memory at all.  It reaches it here.
  //
  // The master is the same `cadr_dbgin` the board carries, instantiated
  // inside the DUT, and the testbench stands where the carrier stands: the
  // levels up, the request down, held until `DEBUG IN ACK`, and lifted with
  // the levels still standing.  `rtl/plumbing/cadr_debug_window.sv` is the
  // carrier on the board and `build/gp1_split.pass` holds it; what is driven
  // here is the cable and nothing else, which is the boundary
  // `docs/debug-cable.md` draws.
  //
  // **AND THE ERROR STATUS BYTE IS THE OTHER HALF OF THE SECTION.**  The
  // eight lines the 8304 at REQERR 0B15 puts on `DBD<7:0>` are assembled in
  // `cadr_memory_path.sv` out of two modules --- `cadr_busint_regs.sv`'s four
  // flops and `cadr_busint_xbus.sv`'s `-FREE` --- and nothing else in this
  // tree composes them.  `build/dbgin.pass` drives that byte from OUTSIDE on
  // purpose, so that a check which supplies the answer cannot be the thing
  // that tests it; so what makes each bit true here is the machine being
  // driven, and the byte is read back over the cable.  A bit misplaced by one
  // in the join lands on a neighbour this section has just measured clear.
  long cable_strobes = 0, cable_cycles = 0, cable_reads = 0, cable_writes = 0;
  long cable_mapped = 0, cable_status_reads = 0, cable_unanswered = 0;
  long md_writes_seen = 0;
  long cable_after_reset = 0;
  unsigned cable_status_bits = 0;
  if (failures < kMaxFailures) {
    // The four strobes, `DEBUG IN A<1:0>`, which are the debugger's own Unibus
    // address bits 3 and 2: `busint::DEBUG_CYCLE`, `DEBUG_STATUS`,
    // `DEBUG_MODIFIER` and `DEBUG_ADDRESS`.
    const unsigned kACycle = 0, kAStatus = 1, kAModifier = 2, kAAddress = 3;

    // `busint::DEBUG_OUT_REQUEST_NS`: the levels are on the cable a hundred
    // nanoseconds before the request, because `-DEBUG OUT REQ` is
    // `NAND(SELECT DEBUG, SELECT DEBUG DLYD)` and the MTD100 at DBGOUT 0A10
    // delays the second.  Twenty ticks on MIT's grid.
    const long kCableLeadT = 100 / kTickNs;

    // What an open cable reads: the two bytes the debuggee drives, and ones
    // wherever it drives nothing, which is the SIP at DBGIN 0A22.  This is
    // `cable::DebugIn::observe` and is why `Rtl::try_debug_request` writes a
    // status answer as `0xff00 | status`.
    auto Seen = [&]() {
      const unsigned drv = dut->dbd_oe;
      return (unsigned)((((drv & 2) ? (dut->dbd_out & 0xFF00u) : 0xFF00u) |
                         ((drv & 1) ? (dut->dbd_out & 0x00FFu) : 0x00FFu)));
    };

    // One request on the cable.  Returns the word the debuggee drove at the
    // instant `DEBUG IN ACK` first rose, or -1 if it never did.
    auto Strobe = [&](unsigned a, bool write, unsigned dbd, long guard) {
      dut->dbg_in_a = a;
      dut->dbg_in_wr = write ? 1 : 0;
      dut->dbd_in = dbd;
      for (long i = 0; i < kCableLeadT; ++i) Tick();
      dut->dbg_in_req = 1;
      long word = -1;
      for (long g = 0; g < guard && failures < kMaxFailures; ++g) {
        Tick();
        if (dut->dbg_in_ack) {
          word = (long)Seen();
          break;
        }
      }
      // The lift, with every level still standing: the two latches take `DBD`
      // at the trailing edge of their own strobe, so a carrier that cleared
      // the lines as part of lifting would write the wrong word into this
      // machine's address or modifier register.
      dut->dbg_in_req = 0;
      Tick();
      dut->dbg_in_a = 0;
      dut->dbg_in_wr = 0;
      dut->dbd_in = 0;
      // `RELEASE_T` and then some: `-DB BUS REQ` is down only once the page
      // is back in `C_IDLE`, and the arbiter may not be asked for anything
      // else until it is.
      for (long g = 0; g < 200; ++g) Tick();
      ++cable_strobes;
      return word;
    };

    // A cycle on this machine's Unibus at `uaddr`: the address latched into
    // the two 74LS374s as `UAO<16:1>`, bit 17 into the modifier register, and
    // then `-DB NEED UB`.  `ub_addr` is `{modifier[0], address, 1'b0}`, which
    // is `Busint::debug_unibus_address`, so an eighteen-bit address crosses in
    // two strobes and MIT's own note --- "Bit 0 of the address is not sent
    // over the cable" --- is why the third bit is never sent.
    //
    // **MODIFIER BITS 1 AND 2 ARE HELD CLEAR ON EVERY ONE OF THESE.**  Bit 1
    // is `-DEBUGEE RESET` and would halt the machine; bit 2 is the timeout
    // inhibit, which nothing in this fabric consumes.  `build/dbgin.pass`
    // owns both.
    auto CableCycle = [&](unsigned uaddr, bool write, unsigned wdata, long guard) {
      dut->spy_rdata = Poison(SpyEadr(uaddr));
      Strobe(kAAddress, false, (uaddr >> 1) & 0xFFFFu, 200);
      Strobe(kAModifier, false, (uaddr >> 17) & 1u, 200);
      ++cable_cycles;
      if (write) ++cable_writes; else ++cable_reads;
      return Strobe(kACycle, write, wdata, guard);
    };

    // The byte, read the way CC's `DBG-PRINT-STATUS` reads it.  The high byte
    // is the open cable and must come back as ones, which is the one place
    // this fabric deliberately drives nothing.
    auto Status = [&](const char *where) {
      const long w = Strobe(kAStatus, false, 0, 200);
      ++cable_status_reads;
      if (w < 0) {
        failures += Fail("DEBUG IN ACK on -DB READ STATUS", 0, 1, where);
        return 0u;
      }
      if (((unsigned)w >> 8) != 0xFFu)
        failures += Fail("the high byte of a status read", (unsigned)w >> 8, 0xFFu, where);
      cable_status_bits |= (unsigned)w & 0xFFu;
      return (unsigned)w & 0xFFu;
    };

    // ---- the cable reaches the diagnostic register block --------------------
    //
    // CC's whole vocabulary is `0o766000` plus twice the register number, so
    // this is the claim that muir over this cable can do to this machine what
    // muir over the lashup does to a simulated one.  The word is the poison
    // driven from the address THIS testbench put on the bus and never from
    // `spy_eadr`, so a block that answered the wrong register is visible.
    for (unsigned eadr = 0; eadr < 16; ++eadr) {
      const unsigned uaddr = 0766000u + 2u * eadr;
      const long w = CableCycle(uaddr, false, 0, 4000);
      if (w < 0)
        failures += Fail("DEBUG IN ACK on a cycle at the register block", 0, 1, "the cable");
      else if ((unsigned)w != Poison(eadr))
        failures += Fail("the register block's word over the cable", (unsigned)w, Poison(eadr),
                         "the cable");
    }

    // A WRITE over the cable, whose landing is a wire out of the machine:
    // `0o766012` is the mode register and bit 5 is `PROMDISABLE`, which is
    // how MIT's boot PROM turns itself off.  The register loads at the
    // machine's next look, so the level is read after a microcycle.
    const int promdisable_before = dut->promdisable;
    CableCycle(0766012u, true, 040u, 4000);
    Idle(2 * kMicrocycle);
    if (promdisable_before || !dut->promdisable)
      failures += Fail("PROMDISABLE after a mode register write over the cable",
                       (unsigned)dut->promdisable, 1, "the cable");
    CableCycle(0766012u, true, 0u, 4000);
    Idle(2 * kMicrocycle);
    if (dut->promdisable)
      failures += Fail("PROMDISABLE after the cable wrote it back", (unsigned)dut->promdisable, 0,
                       "the cable");

    // ---- the error status byte, bit by bit, each made true by the machine ---
    //
    // `-RESET ERR` first: "Writing this location ignores the data written and
    // clears the status bits", all but bit 7, which the 74S74 at UBCYC 0B08
    // clocks from data bit 7.  So this clears the three error flops and puts
    // write-through down with them.
    Run(0766044u, true, 0);
    iface_writes += 1;
    unsigned st = Status("the cable, with nothing wrong and the bus free");
    if (st != 0x00u)
      failures += Fail("the status byte with nothing wrong", st, 0x00u, "the cable");

    // Bit 6, `-FREE`: the byte read WHILE a cycle of the machine's own stands.
    // This is the one bit of the eight that is not a flop of the error status
    // register at all --- it is `cadr_busint_xbus.sv`'s own busy, which is
    // `Busint::busy`, and `Machine::debug_status` takes it live.  A cycle at a
    // Unibus address nothing answers stands for the whole NXM timeout, which
    // is a window wide enough to read the byte in; the SAME byte is read again
    // once the cycle is over and must have the bit clear.
    //
    // A status strobe is not a bus cycle and takes no bus: `DEBUG IN ACK` for
    // it is `NAND(-DB ADR1 CLK, -DB ADR0 CLK, -DB READ STATUS)` at DBGIN 0A14
    // and the cycle engine never leaves `C_IDLE`.  So this can be done under a
    // standing processor cycle, and nothing else in the machine moves.
    unsigned st_busy = 0xFFFFu, st_free = 0xFFFFu;
    {
      dut->phys = UnibusPhysical(0765000u);
      dut->wrcyc = 0;
      dut->wdata = 0;
      dut->spy_rdata = 0;
      dut->n_memrq = 0;
      // Far enough in that the cycle is running and nowhere near the timer.
      for (long g = 0; g < 400 && dut->n_memgrant; ++g) Tick();
      st_busy = Status("the cable, with a cycle of the machine's own standing");
      for (long g = 0; g < 6000; ++g) {
        Tick();
        if (!dut->n_memack) break;
      }
      dut->n_memrq = 1;
      for (long g = 0; g < 200; ++g) {
        Tick();
        if (dut->n_memgrant && !dut->ub_msyn_o) break;
      }
      Idle(4);
      ++unanswered;
      st_free = Status("the cable, with the bus free again");
    }
    const unsigned kNotFree = 0100u, kXbusNxm = 01u, kUnibusNxm = 010u, kUbMapError = 040u;
    const unsigned kWriteThrough = 0200u;
    if (!(st_busy & kNotFree))
      failures += Fail("-FREE in the status byte with a cycle standing", st_busy, kNotFree,
                       "the cable");
    if (st_free & kNotFree)
      failures += Fail("-FREE in the status byte with the bus free", st_free & kNotFree, 0,
                       "the cable");
    // And that cycle timed out on the Unibus, so bit 3 is up and bit 0 is not.
    if ((st_free & (kUnibusNxm | kXbusNxm)) != kUnibusNxm)
      failures += Fail("the NXM bits after a Unibus cycle nothing answered",
                       st_free & (kUnibusNxm | kXbusNxm), kUnibusNxm, "the cable");

    // Bit 0, `XB NXM ERROR`: the same again on the XBUS.  An Xbus page above
    // the fitted memory and below the device pages is `Responder::NoXbus`, so
    // nothing answers and the timer ends it.  The two bits are three apart in
    // the register and a join that crossed them is caught here rather than at
    // a read of `0o766044`, where `build/busint_regs.pass` already holds them.
    {
      dut->phys = 0x300000u;   // 3,145,728: past 32 boards, short of 0o36000
      dut->wrcyc = 0;
      dut->wdata = 0;
      dut->n_memrq = 0;
      for (long g = 0; g < 6000; ++g) {
        Tick();
        if (!dut->n_memack) break;
      }
      dut->n_memrq = 1;
      for (long g = 0; g < 200; ++g) {
        Tick();
        if (dut->n_memgrant) break;
      }
      Idle(4);
    }
    st = Status("the cable, after a cycle nothing on the Xbus answered");
    if ((st & (kXbusNxm | kUnibusNxm)) != (kXbusNxm | kUnibusNxm))
      failures += Fail("both NXM bits after one cycle of each kind",
                       st & (kXbusNxm | kUnibusNxm), kXbusNxm | kUnibusNxm, "the cable");

    // Bit 7, `WRITE THROUGH ENB`: a write of `0o766044` clears the three error
    // flops and clocks bit 7 from the data.  So the byte becomes exactly bit 7
    // and nothing else, which says the clear reaches all three and the one bit
    // it must not reach survives.
    Run(0766044u, true, 0200u);
    iface_writes += 1;
    st = Status("the cable, with write-through on and the errors cleared");
    if (st != kWriteThrough)
      failures += Fail("the status byte with write-through alone", st, kWriteThrough, "the cable");
    Run(0766044u, true, 0);
    iface_writes += 1;
    st = Status("the cable, with write-through written back off");
    if (st != 0x00u)
      failures += Fail("the status byte with write-through off again", st, 0x00u, "the cable");

    // ---- THE MAPPED WINDOW, WITH THE CABLE AS THE MASTER --------------------
    //
    // `Machine::mapped_read` and `mapped_write` were written for exactly this
    // master, and `Rtl::try_debug_request` is the only place in muir that
    // makes a map responder at all.  The map entry is written OVER THE CABLE
    // too --- `0o766140` is above `0o400000`, so modifier bit 0 carries
    // address bit 17 and a cable that dropped it would write somewhere else
    // entirely and the read-back would say so.
    window_open = 1;
    const unsigned kCablePage = 3u;
    const unsigned kCableWord = 0x5Cu;
    const unsigned cable_entry = sweep_entry[kCablePage];
    const uint32_t cphys = (sweep_page[kCablePage] << 8) | kCableWord;
    const uint32_t cbyte = MainByteAddress(cphys);
    const uint32_t cwant = MainPoison(cbyte);
    const unsigned cbase = 0140000u + (kCablePage << 10) + (kCableWord << 2);

    CableCycle(0766140u + 2u * kCablePage, true, cable_entry, 4000);
    long w = CableCycle(0766140u + 2u * kCablePage, false, 0, 4000);
    if (w < 0 || (unsigned)w != cable_entry)
      failures += Fail("the map entry written and read back over the cable", (unsigned)w,
                       cable_entry, "the cable");

    // The EVEN word: an Xbus read at the translated address, whose low half is
    // the answer and whose high half goes into the page's read buffer.  This
    // is the sentence `docs/debug-cable.md` used to carry the opposite of.
    w = CableCycle(cbase, false, 0, 8000);
    ++cable_mapped;
    if (w < 0) {
      failures += Fail("DEBUG IN ACK on a mapped read over the cable", 0, 1, "the cable");
    } else {
      if ((unsigned)w != (cwant & 0xFFFFu))
        failures += Fail("the low half of the mapped word over the cable", (unsigned)w,
                         cwant & 0xFFFFu, "the cable");
      if (last_mem_addr != cbyte)
        failures += Fail("the byte address the memory port was asked for over the cable",
                         last_mem_addr, cbyte, "the cable");
      if (last_mem_write)
        failures += Fail("the direction at the memory port on a mapped read over the cable", 1, 0,
                         "the cable");
    }
    // The ODD word: the read buffer, no Xbus cycle at all.
    {
      const long before = window_mem_cycles;
      w = CableCycle(cbase + 2, false, 0, 8000);
      ++cable_mapped;
      if (w < 0 || (unsigned)w != (cwant >> 16))
        failures += Fail("the high half out of the read buffer over the cable", (unsigned)w,
                         cwant >> 16, "the cable");
      if (window_mem_cycles != before)
        failures += Fail("memory cycles for a cable read of the odd word",
                         (unsigned long)(window_mem_cycles - before), 0, "the cable");
    }
    // And a WRITE, which is the half a read alone cannot make: the even word
    // into the write buffer and nothing else, the odd word an Xbus write of
    // the two halves at the translated address.
    {
      const long before = window_mem_cycles;
      CableCycle(cbase, true, 0xBEEFu, 8000);
      ++cable_mapped;
      if (window_mem_cycles != before)
        failures += Fail("memory cycles for a cable write of the even word",
                         (unsigned long)(window_mem_cycles - before), 0, "the cable");
    }
    CableCycle(cbase + 2, true, 0x1234u, 8000);
    ++cable_mapped;
    if (!last_mem_write || last_mem_addr != cbyte || last_mem_wdata != 0x1234BEEFu)
      failures += Fail("the word a cable write put in main memory", last_mem_wdata, 0x1234BEEFu,
                       "the cable");
    w = CableCycle(cbase, false, 0, 8000);
    ++cable_mapped;
    if (w < 0 || (unsigned)w != 0xBEEFu)
      failures += Fail("the low half read back through the map over the cable", (unsigned)w,
                       0xBEEFu, "the cable");
    w = CableCycle(cbase + 2, false, 0, 8000);
    ++cable_mapped;
    if (w < 0 || (unsigned)w != 0x1234u)
      failures += Fail("the high half read back through the map over the cable", (unsigned)w,
                       0x1234u, "the cable");

    // ---- `-UB TO MD`: CC's `CC-WRITE-MD`, over MIT's own cable -------------
    //
    // A map entry whose page has its high five bits ones is `MD` and not the
    // Xbus: `busint::map_to_md`, and CC loads register `0o16` with
    // `0o177000` for it.  This is the composition of that --- the cable's
    // master, the arbiter, the register block's decode and the word leaving
    // `cadr_memory_path` on `UB MD LOAD` --- and it is the one path in the
    // machine that reaches `MD` without a memory cycle.  The register the
    // word lands in is `cadr_microcycle`'s and `build/md_compose.pass` holds
    // it, on a machine that is still running.
    {
      const unsigned kMdPage = 016u;
      const unsigned mdbase = 0140000u + (kMdPage << 10) + (0x21u << 2);
      CableCycle(0766140u + 2u * kMdPage, true, 0177000u, 4000);
      w = CableCycle(0766140u + 2u * kMdPage, false, 0, 4000);
      if (w < 0 || (unsigned)w != 0177000u)
        failures += Fail("CC's own map entry written and read back over the cable", (unsigned)w,
                         0177000u, "the cable");

      md_open = 1;
      // The EVEN word is the page's write buffer and nothing else: no memory
      // cycle, and NO LOAD.  A fabric that took the low half straight to `MD`
      // would be caught here rather than by a word comparison.
      long before = window_mem_cycles;
      long loads_before = md_loads;
      CableCycle(mdbase, true, 0xC3A5u, 8000);
      ++cable_mapped;
      if (window_mem_cycles != before)
        failures += Fail("memory cycles for the even word of a write of MD",
                         (unsigned long)(window_mem_cycles - before), 0, "the cable");
      if (md_loads != loads_before)
        failures += Fail("UB MD LOAD on the even word of a write of MD",
                         (unsigned long)(md_loads - loads_before), 0, "the cable");

      // And the ODD word loads `MD` with the two halves and is ACKNOWLEDGED,
      // which is the whole finding: `-LOADMD ACK` at REQLM 0A11 answers the
      // cycle, so `DEBUG IN ACK` comes back where it used to hang for ever.
      before = window_mem_cycles;
      md_latency = 9;
      w = CableCycle(mdbase + 2, true, 0x7E19u, 8000);
      ++cable_mapped;
      if (w < 0)
        failures += Fail("DEBUG IN ACK on a write of MD over the cable", 0, 1, "the cable");
      if (md_loads != loads_before + 1)
        failures += Fail("UB MD LOAD on the odd word of a write of MD",
                         (unsigned long)(md_loads - loads_before), 1, "the cable");
      if (last_md_data != 0x7E19C3A5u)
        failures += Fail("the thirty-two bits UB MD LOAD carried", last_md_data, 0x7E19C3A5u,
                         "the cable");
      if (window_mem_cycles != before)
        failures += Fail("memory cycles for a write of MD --- it never reaches the Xbus",
                         (unsigned long)(window_mem_cycles - before), 0, "the cable");

      // A second pair at a different word of the same page and with the
      // latency moved, so that neither the word address nor a fixed delay is
      // what the load is a function of.
      md_latency = 31;
      CableCycle(mdbase + 0x40u, true, 0x0FF0u, 8000);
      w = CableCycle(mdbase + 0x42u, true, 0x1234u, 8000);
      cable_mapped += 2;
      if (w < 0)
        failures += Fail("DEBUG IN ACK on the second write of MD", 0, 1, "the cable");
      if (last_md_data != 0x12340FF0u)
        failures += Fail("the thirty-two bits the second write of MD carried", last_md_data,
                         0x12340FF0u, "the cable");
      if (md_loads != loads_before + 2)
        failures += Fail("UB MD LOADs after two writes of MD",
                         (unsigned long)(md_loads - loads_before), 2, "the cable");
      md_latency = 3;

      // **AND A READ THROUGH THE SAME ENTRY IS NOT A READ OF `MD`.**
      // `Rtl::try_debug_request` tests `req.write` first, so the odd word is
      // the page's read buffer --- a register cycle, no load and no bus ---
      // and the even word is a mapped Xbus cycle at physical page `0o37000`,
      // which is the Unibus and not main memory, so this arbiter never grants
      // it and it is never answered.  Both halves are run.
      before = window_mem_cycles;
      w = CableCycle(mdbase + 2, false, 0, 8000);
      ++cable_mapped;
      if (w < 0)
        failures += Fail("DEBUG IN ACK reading the odd word through CC's entry", 0, 1,
                         "the cable");
      if (md_loads != loads_before + 2)
        failures += Fail("UB MD LOAD on a READ through CC's entry",
                         (unsigned long)(md_loads - loads_before), 2, "the cable");
      if (window_mem_cycles != before)
        failures += Fail("memory cycles for a buffer read through CC's entry",
                         (unsigned long)(window_mem_cycles - before), 0, "the cable");
      w = CableCycle(mdbase, false, 0, 2000);
      ++cable_mapped;
      if (w >= 0)
        failures += Fail("a mapped read at a page that is not main memory was acknowledged",
                         (unsigned)w, 0, "the cable");
      else
        ++cable_unanswered;
      if (window_mem_cycles != before)
        failures += Fail("memory cycles for a mapped read of a page that is not memory",
                         (unsigned long)(window_mem_cycles - before), 0, "the cable");
      md_open = 0;
      // The entry is put back where the sweep left it, so nothing after this
      // sees CC's page.
      CableCycle(0766140u + 2u * kMdPage, true, sweep_entry[kMdPage], 4000);
      md_writes_seen = md_loads - loads_before;
    }

    // ---- bit 5, `UB MAP ERROR`, and the cycle that is never acknowledged ----
    //
    // "Set when an attempt to perform an Xbus cycle through the Unibus map is
    // refused because the map specifies invalid or write-protected."  A page
    // whose `MAPVALID` is down refuses, sets the bit at `UB XBUS T100` --- the
    // 74LS74 at REQERR 0D03 --- and NEVER ANSWERS.  So this measures two
    // things at once that no other check in the tree puts together: the bit
    // reaching the cable's own status driver, and `cadr_dbgin.sv`'s "a cycle
    // at an address nothing answers is never acknowledged, there being no
    // timeout for this master".
    //
    // The guard is 2,000 ticks, which is longer than the debugger's own
    // 11.05 us timeout and nearly three times this machine's 4.25 us NXM
    // timer.  Nothing must acknowledge inside it.
    Run(0766044u, true, 0);   // -RESET ERR, so bit 5 is the only bit that can rise
    iface_writes += 1;
    {
      const unsigned bad_page = 5u;
      CableCycle(0766140u + 2u * bad_page, true, 0u, 4000);   // MAPVALID down
      const unsigned bad = 0140000u + (bad_page << 10) + (0x10u << 2);
      const long before = window_mem_cycles;
      w = CableCycle(bad, false, 0, 2000);
      ++cable_mapped;
      if (w >= 0)
        failures += Fail("a mapped cable cycle through an invalid page was acknowledged",
                         (unsigned)w, 0, "the cable");
      else
        ++cable_unanswered;
      if (window_mem_cycles != before)
        failures += Fail("memory cycles for a refused mapped cycle",
                         (unsigned long)(window_mem_cycles - before), 0, "the cable");
    }
    window_open = 0;
    st = Status("the cable, after a mapped cycle the map refused");
    if (st != kUbMapError)
      failures += Fail("the status byte after a refused mapped cycle", st, kUbMapError,
                       "the cable");
    Run(0766044u, true, 0);
    iface_writes += 1;
    st = Status("the cable, after -RESET ERR cleared the map error");
    if (st != 0x00u)
      failures += Fail("the status byte after -RESET ERR", st, 0x00u, "the cable");

    // ---- THE PAGE'S TWO RESETS, WHICH ARE TWO ON PURPOSE --------------------
    //
    // **AND THIS IS LAST BECAUSE IT RESETS THE MACHINE.**  The card's two
    // clocks, the map's sixteen registers and the error flops all go with it,
    // so nothing above may run after it; the section that follows reads the
    // microsecond counter from wherever it stands and is the only one that
    // could care.
    //
    // `cadr_memory_path` takes `rst` and `dbg_rst` and gives the DBGIN page the
    // second.  MIT's modifier bit 1 is `-DEBUGEE RESET` and is a LEVEL ---
    // "write a 1 here then write a 0" --- and it crosses the debuggee's own
    // cables to OLORD2 as that processor's power-on reset.  So the machine's
    // reset carries it, and a DBGIN page reset by the machine's reset would
    // clear the modifier register that is holding the bit down: the level
    // becomes a one-tick pulse and MIT's sequence cannot be written at all.
    //
    // **UNTIL THIS POINT THE TWO RESETS HAVE BEEN THE SAME TICK IN THIS FILE**,
    // so a `.rst(rst)` at the instantiation would have survived every line
    // above.  `build/dbgin.pass` writes the bit, but against a harness that
    // wires the two itself rather than against this module.  Here the loop is
    // closed the way the top level closes it --- `debuggee_reset` registered
    // and joined into `rst` --- and what is measured is that the level STANDS.
    cable_reset_wired = 1;
    Idle(8);
    if (dut->debuggee_reset || cable_rst_q)
      failures += Fail("-DEBUGEE RESET before the cable asked for it",
                       (unsigned)dut->debuggee_reset, 0, "the two resets");
    // Bit 0 with it, as CC's own sequence carries it: the address bit must
    // survive a write that is about to reset the machine.
    Strobe(kAModifier, false, 0b011u, 200);
    if (!dut->debuggee_reset)
      failures += Fail("-DEBUGEE RESET after modifier bit 1 was written",
                       (unsigned)dut->debuggee_reset, 1, "the two resets");
    long stood = 0;
    for (long g = 0; g < 400; ++g) {
      Tick();
      if (dut->debuggee_reset) ++stood;
    }
    if (stood != 400)
      failures += Fail("ticks -DEBUGEE RESET stood out of 400", (unsigned long)stood, 400,
                       "the two resets");
    if (!cable_rst_q)
      failures += Fail("the machine's own reset under -DEBUGEE RESET", (unsigned)cable_rst_q, 1,
                       "the two resets");
    // And the modifier register kept address bit 17 through all of it, which a
    // page in reset could not have done.
    Strobe(kAAddress, false, 0xF600u, 200);   // 0o766000 >> 1, the block's base
    Strobe(kAModifier, false, 0b001u, 200);
    if (dut->debuggee_reset)
      failures += Fail("-DEBUGEE RESET after modifier bit 1 was written back",
                       (unsigned)dut->debuggee_reset, 0, "the two resets");
    Idle(8);
    if (cable_rst_q)
      failures += Fail("the machine still in reset after the cable let go",
                       (unsigned)cable_rst_q, 0, "the two resets");
    // The machine works again, and the address the cable latched while it was
    // held is the one the cycle now runs at.
    {
      dut->spy_rdata = Poison(0);
      ++cable_cycles;
      ++cable_reads;
      const long back = Strobe(kACycle, false, 0, 4000);
      if (back < 0 || (unsigned)back != Poison(0))
        failures += Fail("the register block over the cable after the reset", (unsigned)back,
                         Poison(0), "the two resets");
      else
        ++cable_after_reset;
    }
    cable_reset_wired = 0;
    Idle(4 * kMicrocycle);

    // **AND THE MACHINE TAKES ITS OWN UNIBUS AGAIN, WHICH THE RESET GAVE
    // BACK.**  `cadr_busint_xbus.sv` sets `LMUB MASTER` at arbitration stage 3
    // and nothing but a reset ever clears it, which is why its header says
    // stages 1 to 3 happen once in the life of the machine --- and a reset
    // makes that life start again.  So the first processor cycle after this
    // section pays the 200 ns `SACK` wait and the stages either side of it,
    // 116 ticks more than the cycles before and after it.
    //
    // The section below times the microsecond counter by two of its own
    // strobes and requires them to be an exact number of the card's
    // microseconds apart, so one cycle 116 ticks longer than its partner
    // breaks an invariant that has nothing to do with this one.  Measured
    // rather than foreseen: the run failed there before this line existed,
    // which is the arbitration's own "it runs once" caveat arriving from the
    // far side.
    Run(0766044u, true, 0);
    iface_writes += 1;
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
  least("mapped cycles run by a foreign master", window_cycles, 6);
  least("mapped reads", window_reads, 4);
  least("mapped writes", window_writes, 2);
  least("requests made on MIT's debug cable", cable_strobes, 60);
  least("cycles the debug master ran on this machine's Unibus", cable_cycles, 20);
  least("reads by the debug master", cable_reads, 18);
  least("writes by the debug master", cable_writes, 4);
  least("mapped cycles with the DEBUG CABLE as the master", cable_mapped, 7);
  least("error status bytes read over the cable", cable_status_reads, 6);
  least("mapped cable cycles nothing acknowledged --- one refused by the map and one at a "
        "page that is not main memory", cable_unanswered, 2);
  least("writes of MD over the cable that reached UB MD LOAD", md_writes_seen, 2);
  least("cycles the debug master ran after it had reset the machine", cable_after_reset, 1);
  // **THE FIVE LIVE BITS WERE EACH SEEN UP AND THE THREE PARITY BITS NEVER
  // WERE.**  A byte that is only ever compared against zero passes a driver
  // stuck at zero, which is this project's standing rule about a memory whose
  // only exercise writes one constant; this is the same rule for eight wires.
  // Bits 1, 2 and 4 are `XB PAR ERROR`, `LM ADR PAR ERROR` and `LM PAR
  // ERROR`, which muir says cannot happen here, so a join that shifted a live
  // bit onto one of them shows as a bit this run never saw and a bit it
  // should not have.
  if (cable_status_bits != 0351u) {
    std::fprintf(stderr,
                 "FAIL: the status bits this run saw set over the cable are 0%03o, wanting 0351 ---\n"
                 "      XB NXM (1), UB NXM (10), UB MAP ERROR (40), -FREE (100) and WRITE THROUGH\n"
                 "      (200), and never the three parity bits\n",
                 cable_status_bits);
    ++thin;
  }
  // Three, and the number is the route: two reads of the even word and one
  // write of the odd word reach main memory, while the three cycles of the
  // odd word's buffer and the even word's buffer reach nothing at all.
  least("memory cycles the mapped window made", window_mem_cycles, 3);
  if (!window_timed_out) {
    std::fprintf(stderr,
                 "FAIL: the processor's own cycle in the mapped window did not time out, so the\n"
                 "      ub_foreign gate was not measured in the composition\n");
    ++thin;
  }
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
      "    ONCE, which is measured at ub_ssyn_by and not inferred from the word.  NOTHING IS\n"
      "    EXEMPT: the Chaosnet interface's group (0764140-0764156) and the serial port's\n"
      "    (0764160-0764176) are answered by the card now, so every direction\n"
      "    ioboard::answers decodes is held here.\n"
      "    The three slaves' sets are disjoint over all %zu addresses in both directions, against\n"
      "    muir's own ioboard::answers (%ld DEC rows and %ld DECNONE runs out of %s) and its\n"
      "    busint::register (%ld IFACE rows out of %s) --- no transcription of either.\n"
      "    The bus interface's own registers answered %ld of the sweep's directions: the interrupt\n"
      "    block at 0766040-0766076 and the Unibus map at 0766140-0766176.\n"
      "    AND THE MAPPED WINDOW REACHED MAIN MEMORY: %ld cycles of a foreign Unibus master at\n"
      "    0140000-0177777 --- %ld reads and %ld writes --- through a map entry out of %s,\n"
      "    %ld of them reaching the machine's own memory port at the byte address\n"
      "    cadr_ddr_map::main_byte_address gives the translated page, the odd word answered from\n"
      "    the read buffer with no memory cycle at all, and a word written through the map and\n"
      "    read back through it.  The PROCESSOR's own cycle at the same address timed out, which\n"
      "    is busint::decode answering NoUnibus over the whole window.  That master is this\n"
      "    testbench on the console's seam, which is the seam a foreign master presents; the\n"
      "    section below runs the same route with MIT's own master on MIT's own cable.\n"
      "    AND THE DEBUG CABLE DROVE A CYCLE THROUGH THE COMPOSED MACHINE: %ld requests on the\n"
      "    cable, %ld of them cycles on this machine's Unibus --- %ld reads and %ld writes --- by\n"
      "    the same cadr_dbgin.sv the board carries, on the arbiter cadr_memory_path.sv\n"
      "    instantiates.  All sixteen diagnostic registers read back the word driven from the\n"
      "    address and never from spy_eadr; a mode register write over the cable moved\n"
      "    PROMDISABLE, which is a wire out of the machine.  %ld mapped cycles had the CABLE as\n"
      "    the master, through a map entry the cable itself wrote and read back at 0766146 ---\n"
      "    which is above 0400000, so modifier bit 0 carried address bit 17 --- and the even\n"
      "    word's read and the odd word's write reached the machine's own memory port at the\n"
      "    byte address cadr_ddr_map::main_byte_address gives muir's own translated page.  A\n"
      "    cycle through a page whose MAPVALID is down was never acknowledged over 2,000 ticks,\n"
      "    which is longer than the debugger's own 11.05 us timeout and nearly three times this\n"
      "    machine's NXM timer: there is no timeout for this master.\n"
      "    THE ERROR STATUS BYTE IS ASSEMBLED IN cadr_memory_path.sv AND WAS READ BACK OVER THE\n"
      "    CABLE %ld times, high byte 0377 every time, being the open cable's pull-ups.  Each of\n"
      "    its five live bits was made true by driving the machine and then read: XB NXM by an\n"
      "    Xbus cycle nothing answered, UB NXM by a Unibus one, UB MAP ERROR by the refused\n"
      "    mapped cycle above, WRITE THROUGH by a write of 0766044, and -FREE --- which is\n"
      "    cadr_busint_xbus.sv's own busy and no flop of the register's --- by reading the byte\n"
      "    with a cycle of the machine's own standing and again with the bus free.  The three\n"
      "    parity bits were never seen set, and -RESET ERR left the byte at zero.\n"
      "    AND THE DBGIN PAGE'S TWO RESETS ARE TWO: with debuggee_reset registered and joined\n"
      "    into the machine's own reset, as the top level joins it, modifier bit 1 held\n"
      "    -DEBUGEE RESET up for all 400 ticks it was asked to.  A page reset by the machine's\n"
      "    reset would have cleared the bit that was clearing it and made MIT's level a\n"
      "    one-tick pulse.  The address bit the modifier carried survived the hold, and the\n"
      "    cable ran a cycle at it once it let the machine go.\n",
      tick, card_reads, card_writes, block_reads, block_writes, iface_reads, iface_writes, kStrobeT,
      kAckT, carry_ticks, swept,
      kSweepFirst, kSweepLast, answered_by_card, answered_by_block, unanswered, kAddrs, dec_rows,
      dec_none_runs, path, iface_rows, ipath, answered_by_iface, window_cycles, window_reads,
      window_writes, ipath, window_mem_cycles, cable_strobes, cable_cycles, cable_reads,
      cable_writes, cable_mapped, cable_status_reads);
  return 0;
}
