// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX revision 16's Ethernet device from both of its sides
// (`tb/quux16_ethernet_harness.sv`): the register page's devices with the
// device in them, and `rtl/plumbing/quux_ed_face.sv` before them, which
// this program reaches through `quux-ethernet-device`'s own page code,
// `qed_face_fabric.c`, its accesses made over AXI.
//
//     Vquux16_ethernet_harness SCRIPT...
//
// **EACH SCRIPT IS muir's DEVICE** (`golden/src/quux16_ethernet.rs`): the
// processor's writes made as the core makes them, 244 and 250 as the held
// write; the host's moves made through the face as the program makes them,
// TX_CONS and RX_CONS under the epoch STATE gives, RX_CONS under the claim
// and after the face's barrier, the counters and 253-257 as the program
// writes them; and after each step every word 240-257 read as the core
// reads it and held to muir's.  Beside the words, the device's own: 244 and
// 250 as the host's side reads them, the interrupt (word 100's `<8>` is the
// only source up here), and each delivery's line clearing: the buffer's
// lines and then the entry's, one set a clock, read from the entry's words
// in memory as muir left them, and 251 moved from the clock after the last.
// The core's side of that port is played here, its grant, fill and clears
// each delayed at random.
//
// **THEN THE HOST'S SIDE, WHICH muir HAS NOT GOT**, each rule with the case
// just outside it:
//
//   - the page's map: IDENT "QE16", MEM_WORDS, every register at its
//     offset, a word nothing names reading 0, a write of fewer than four
//     bytes going nowhere; `qed_fabric_attach` taking the page and dropping
//     a claim left behind
//   - 253-257 at muir's defaults from power-on and the counters at 0, the
//     host's writes landing, and neither changed by a disable,
//     RESET-DEVICES or a reset of the machine
//   - the claim: refused while disabled and under a stale epoch, taken in
//     the current one, holding quiet low across a disable, outliving a reset
//     of the machine, let go in any epoch
//   - the epoch counting the disables, by the machine's write of 240, its
//     RESET-DEVICES and its reset, and not those of a device already
//     disabled
//   - TX_CONS refused under a stale epoch, while disabled, and past 244;
//     taken up to 244, landing the clock after its write
//   - RX_CONS refused under a stale epoch, by nothing, past 250 and while
//     disabled, with no set cleared; taken, the host's RX_CONS the target
//     at once, and 251 only once the entries' lines are cleared, one entry
//     after another, a length past the room or past 1,514 bytes clamped and
//     a length of 0 clearing the entry's line alone; dropped by a disable in
//     the clock between; and a disable while the engine works stopping it,
//     no set cleared after
//   - the counters' places, and a write landing at its edge
//   - 244 and 250 on the host's side only once the held write has landed

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <string>
#include <vector>

#include "Vquux16_ethernet_harness.h"
#include "verilated.h"

extern "C" {
#include "qed_face.h"
}

namespace {

constexpr uint32_t kMainWords = 4096;

Vquux16_ethernet_harness *d;
long ticks = 0;
int bad = 0;
long checks = 0;
std::string where;

void Fail(const std::string &what, uint64_t got, uint64_t want) {
  ++bad;
  if (bad <= 40)
    std::fprintf(stderr, "FAIL: %s%s: %#" PRIx64 ", want %#" PRIx64 " (clock %ld)\n", where.c_str(),
                 what.c_str(), got, want, ticks);
}

void Want(const std::string &what, uint64_t got, uint64_t want) {
  ++checks;
  if (got != want) Fail(what, got, want);
}

// What the device held over each clock, before the edge that ends it.
struct Sample {
  bool clear, irq, host_we, busy;
  unsigned widx, tx_cons, rx_cons, line;
};
std::vector<Sample> log_clocks;

// **THE CORE'S PART OF THE LINE-CLEARING ENGINE'S PORT**, played here: the
// transfer channel granted a few clocks after it is wanted; its START
// dropping the line it holds; a word read once its line has come in, after
// a fill of a few clocks, and every word of that line from the copy taken
// then (so that a line held from before START would read stale); a
// set's clear taken in three clocks of four, as the port's valid maps are
// sometimes taken by an install or a transfer's write.  Each figure drawn
// from xorshift, so that the engine meets every order of them.
struct PortModel {
  std::map<uint32_t, uint64_t> mem;
  uint64_t seed = 88172645463325252ull;
  int grant_in = -1, fill_in = -1;
  bool lb_v = false, granted = false;
  uint32_t lb_line = 0;
  uint64_t lb_data[8] = {};
  unsigned next() {
    seed ^= seed << 13;
    seed ^= seed >> 7;
    seed ^= seed << 17;
    return static_cast<unsigned>(seed);
  }
} port;

// The engine's inputs as this clock's outputs ask, the clock evaluated, and
// the clock's sample.
void Model() {
  d->eval();
  if (!d->e_want) {
    port.granted = false;
    port.grant_in = -1;
  } else if (!port.granted) {
    if (port.grant_in < 0) port.grant_in = static_cast<int>(port.next() % 4);
    if (port.grant_in-- == 0) port.granted = true;
  }
  d->e_grant = port.granted;
  if ((d->e_start || d->e_rd) && !port.granted) {
    ++bad;
    std::fprintf(stderr, "FAIL: %sthe engine on the transfer channel without its grant (clock %ld)\n",
                 where.c_str(), ticks);
  }
  d->e_done = 0;
  d->e_data = 0;
  if (d->e_start) port.lb_v = false;
  if (d->e_rd && !d->e_start) {
    const uint32_t a = d->e_addr, line = a >> 3;
    if (port.lb_v && port.lb_line == line) {
      d->e_done = 1;
      d->e_data = port.lb_data[a & 7];
    } else if (port.fill_in < 0) {
      port.fill_in = 3 + static_cast<int>(port.next() % 10);
    } else if (port.fill_in-- == 0) {
      port.lb_v = true;
      port.lb_line = line;
      port.fill_in = -1;
      for (uint32_t k = 0; k < 8; ++k) {
        const auto it = port.mem.find((line << 3) + k);
        port.lb_data[k] = it == port.mem.end() ? 0 : it->second;
      }
    }
  }
  d->c_done = d->c_req && port.next() % 4 != 0;
  d->eval();
  log_clocks.push_back(Sample{d->c_done != 0, d->int_now != 0, d->dbg_host_we != 0, d->eth_busy != 0,
                              d->dbg_host_widx, d->dbg_tx_cons, d->dbg_rx_cons, d->c_line});
}

void Step() {
  d->clk = 0;
  Model();
  d->clk = 1;
  d->eval();
  ++ticks;
}

void Idle(int n) {
  for (int k = 0; k < n; ++k) Step();
}

// One AXI3 write of a word, with its strobes; the response returned.
int Write(uint32_t addr, uint32_t data, unsigned strb = 0xF) {
  d->m_awaddr = addr & 0xFFFu;
  d->m_awlen = 0;
  d->m_awid = 5;
  d->m_awvalid = 1;
  d->m_wdata = data;
  d->m_wstrb = strb;
  d->m_wlast = 1;
  d->m_wvalid = 1;
  d->m_bready = 1;
  bool aw = false, w = false;
  for (int k = 0; k < 64; ++k) {
    d->clk = 0;
    d->eval();
    const bool aw_now = d->m_awvalid && d->m_awready;
    const bool w_now = d->m_wvalid && d->m_wready;
    const bool b_now = d->m_bvalid && d->m_bready;
    const int resp = d->m_bresp;
    Model();
    d->clk = 1;
    d->eval();
    ++ticks;
    if (aw_now) {
      aw = true;
      d->m_awvalid = 0;
    }
    if (w_now) {
      w = true;
      d->m_wvalid = 0;
    }
    if (b_now && aw && w) {
      d->m_bready = 0;
      return resp;
    }
  }
  Fail("a write never answered at " + std::to_string(addr), 0, 1);
  return -1;
}

uint32_t Read(uint32_t addr) {
  d->m_araddr = addr & 0xFFFu;
  d->m_arlen = 0;
  d->m_arid = 3;
  d->m_arvalid = 1;
  d->m_rready = 1;
  for (int k = 0; k < 64; ++k) {
    d->clk = 0;
    d->eval();
    const bool ar_now = d->m_arvalid && d->m_arready;
    const bool r_now = d->m_rvalid && d->m_rready;
    const uint32_t data = d->m_rdata;
    const int resp = d->m_rresp;
    Model();
    d->clk = 1;
    d->eval();
    ++ticks;
    if (ar_now) d->m_arvalid = 0;
    if (r_now) {
      d->m_rready = 0;
      ++checks;
      if (resp != 0) Fail("RRESP at " + std::to_string(addr), resp, 0);
      if (!d->m_rlast) Fail("RLAST on a single beat at " + std::to_string(addr), 0, 1);
      return data;
    }
  }
  Fail("a read never answered at " + std::to_string(addr), 0, 1);
  return 0;
}

// The core's register read: granted, the word the clock after.
uint32_t PRead(unsigned which) {
  d->rd_v = 1;
  d->rd_k = which & 0xFFu;
  Step();
  d->rd_v = 0;
  d->eval();
  const uint32_t v = d->rd_word;
  ++checks;
  if (!d->rd_built) Fail("word " + std::to_string(which) + " not built", 0, 1);
  Step();
  return v;
}

// The core's register write, taken in one clock.
void PWrite(unsigned which, uint32_t v) {
  d->wr_v = 1;
  d->wr_k = which & 0xFFu;
  d->wr_data = v;
  d->eval();
  ++checks;
  if (!d->wr_built) Fail("a write of word " + std::to_string(which) + " not built", 0, 1);
  Step();
  d->wr_v = 0;
  Step();
}

// The held write of 244 or 250, as the core gives it once every write
// before it is answered.
void PHeld(unsigned which, uint32_t v) {
  d->prod_v = 1;
  d->prod_k = which & 0xFFu;
  d->prod_data = v;
  d->eval();
  ++checks;
  if (d->fd_doorbell) Fail("the held write of " + std::to_string(which) + " rang the file device", 1, 0);
  Step();
  d->prod_v = 0;
  Step();
}

void MachReset() {
  d->mach_rst = 1;
  Idle(3);
  d->mach_rst = 0;
  Idle(2);
}

// --- the program's page code, its accesses over AXI

uint32_t sim_rd(void *, unsigned off) { return Read(off); }
void sim_wr(void *, unsigned off, uint32_t v) {
  if (off == QED_FABRIC_BARRIER) return;
  Want("BRESP of the program's write at " + std::to_string(off), Write(off, v), 0);
}

struct qed_fabric fb;
struct qed_face face;
uint8_t no_memory[8];

void Attach() {
  std::memset(&fb, 0, sizeof fb);
  fb.sim_rd = sim_rd;
  fb.sim_wr = sim_wr;
  char why[256];
  if (qed_fabric_attach(&fb, why, sizeof why) != 0) {
    ++bad;
    std::fprintf(stderr, "FAIL: the program refused the page: %s\n", why);
  }
  qed_fabric_face(&fb, no_memory, &face);
}

qed_state State() {
  qed_state s{};
  face.state(face.ctx, &s);
  return s;
}

void Up() {
  d = new Vquux16_ethernet_harness;
  ticks = 0;
  log_clocks.clear();
  port = PortModel{};
  d->e_grant = 0;
  d->e_done = 0;
  d->e_data = 0;
  d->c_done = 0;
  d->rst = 1;
  d->mach_rst = 1;
  d->rd_v = 0;
  d->rd_k = 0;
  d->wr_v = 0;
  d->wr_k = 0;
  d->wr_data = 0;
  d->prod_v = 0;
  d->prod_k = 0;
  d->prod_data = 0;
  d->m_awvalid = 0;
  d->m_wvalid = 0;
  d->m_bready = 0;
  d->m_arvalid = 0;
  d->m_rready = 0;
  Idle(4);
  d->rst = 0;
  d->mach_rst = 0;
  Idle(2);
  Attach();
}

void Down() {
  d->final();
  delete d;
  d = nullptr;
}

std::vector<uint64_t> Hex(std::istringstream &in) {
  std::vector<uint64_t> v;
  std::string w;
  while (in >> w) v.push_back(std::strtoull(w.c_str(), nullptr, 16));
  return v;
}

// The clock the host's write of index `widx` was handed over in, the last
// one logged.
long LastHostWrite(unsigned widx) {
  for (long t = static_cast<long>(log_clocks.size()) - 1; t >= 0; --t)
    if (log_clocks[t].host_we && log_clocks[t].widx == widx) return t;
  return -1;
}

// The sets cleared from clock `from` on.
long ClearsSince(long from) {
  long n = 0;
  for (long t = from; t < static_cast<long>(log_clocks.size()); ++t) n += log_clocks[t].clear;
  return n;
}

// **ONE DELIVERY'S LINE CLEARING**, from the clock `from` the host's
// RX_CONS write began: the sets cleared are exactly the buffer's lines, from
// its first word's to its last's for the length clamped to the room and to
// 1,514 bytes, in order, and then the entry's line; and 251 moves to `to`
// at the edge that takes the last of them, so from the clock after it.
void Delivered(long from, uint16_t to, uint32_t e, uint64_t w0, uint64_t w1, uint64_t w2) {
  for (int k = 0; k < 4000 && d->dbg_rx_cons != to; ++k) Step();
  Step();
  std::vector<unsigned> want;
  const uint32_t buf = static_cast<uint32_t>(w0) & 0x0FFFFFFFu;
  uint32_t n = static_cast<uint32_t>(w2) < static_cast<uint32_t>(w1) ? static_cast<uint32_t>(w2)
                                                                      : static_cast<uint32_t>(w1);
  if (n > 1514) n = 1514;
  const uint32_t words = (n + 3) / 4;
  if (words)
    for (uint32_t l = buf >> 3; l <= (buf + words - 1) >> 3; ++l) want.push_back(l & 0x1FFFFFFu);
  want.push_back((e >> 3) & 0x1FFFFFFu);
  std::vector<unsigned> got;
  long last = -1, moved = -1;
  for (long t = from; t < static_cast<long>(log_clocks.size()) && moved < 0; ++t) {
    if (log_clocks[t].rx_cons == to) moved = t;
    else if (log_clocks[t].clear) {
      got.push_back(log_clocks[t].line);
      last = t;
    }
  }
  ++checks;
  if (got != want) {
    char b[200];
    std::snprintf(b, sizeof b, "the delivery to %u cleared %zu sets, the first %x, wanting %zu, the first %x", to,
                  got.size(), got.empty() ? 0u : got[0], want.size(), want[0]);
    Fail(b, got.size(), want.size());
  }
  Want("251 from the clock after the last set's clear", static_cast<uint64_t>(moved - last), 1);
  // Busy, which the halt's drain waits for, from the clock the move has
  // landed in until 251 has moved.
  long idle = 0;
  for (long t = LastHostWrite(9u /* RX_CONS */) + 2; t >= 2 && t < moved; ++t) idle += !log_clocks[t].busy;
  Want("the clocks not busy between the landing and 251's move", idle, 0);
  Want("busy once 251 has moved", log_clocks.at(moved).busy, 0);
  Want("no set cleared after 251 moved", ClearsSince(moved), 0);
}

// One script of muir's device.
long deliveries = 0, moves = 0, steps = 0;
void Script(const char *path) {
  std::ifstream f(path);
  if (!f) {
    ++bad;
    std::fprintf(stderr, "FAIL: cannot read %s\n", path);
    return;
  }
  std::string line;
  long n = 0;
  bool up = false;
  while (std::getline(f, line)) {
    ++n;
    where = std::string(path) + ":" + std::to_string(n) + ": ";
    std::istringstream in(line);
    std::string op;
    in >> op;
    if (op == "#") {
      std::string what;
      in >> what;
      if (what == "memory") {
        unsigned long m = 0;
        in >> m;
        if (m != kMainWords) Fail("the script's main memory", m, kMainWords);
      } else if (what == "seed" || what == "generated") {
        // A new run: the device as power-on leaves it.
        if (up) Down();
        Up();
        up = true;
      }
      continue;
    }
    if (!up) {
      Up();
      up = true;
    }
    if (op == "w") {
      std::string k, v;
      in >> k >> v;
      const unsigned word = 0240 + static_cast<unsigned>(std::strtoul(k.c_str(), nullptr, 8));
      const uint32_t value = static_cast<uint32_t>(std::strtoull(v.c_str(), nullptr, 16));
      if (word == 0244 || word == 0250)
        PHeld(word, value);
      else
        PWrite(word, value);
    } else if (op == "reset") {
      PWrite(0104, 1);
    } else if (op == "host") {
      const std::vector<uint64_t> h = Hex(in);
      qed_host q{};
      q.mac[0] = static_cast<uint8_t>(h.at(0) >> 8);
      q.mac[1] = static_cast<uint8_t>(h.at(0));
      for (int k = 0; k < 4; ++k) q.mac[2 + k] = static_cast<uint8_t>(h.at(1) >> (24 - 8 * k));
      q.address = static_cast<uint32_t>(h.at(2));
      q.netmask = static_cast<uint32_t>(h.at(3));
      q.gateway = static_cast<uint32_t>(h.at(4));
      face.host(face.ctx, &q);
    } else if (op == "counts") {
      face.counts(face.ctx, static_cast<uint32_t>(Hex(in).at(0)));
    } else if (op == "tx") {
      const qed_state s = State();
      face.sent(face.ctx, s.epoch, static_cast<uint16_t>(Hex(in).at(0)));
      ++moves;
    } else if (op == "rx") {
      const std::vector<uint64_t> v = Hex(in);
      const qed_state s = State();
      const uint16_t to = static_cast<uint16_t>(v.at(0));
      const uint32_t e = static_cast<uint32_t>(v.at(1));
      for (int k = 0; k < 3; ++k) port.mem[e + k] = v.at(2 + k);
      Want("the claim before a delivery", static_cast<uint64_t>(face.claim(face.ctx, s.epoch)), 1);
      const long from = static_cast<long>(log_clocks.size());
      face.delivered(face.ctx, s.epoch, to);
      Want("RX_CONS on the host's side at once, the target", State().rx_cons, to);
      face.release(face.ctx);
      Delivered(from, to, e, v.at(2), v.at(3), v.at(4));
      ++deliveries;
    } else if (op == "=") {
      const std::vector<uint64_t> want = Hex(in);
      if (want.size() != 16) {
        Fail("a line of words with other than 16", want.size(), 16);
        continue;
      }
      static const char *names[16] = {"240", "241", "242", "243", "244", "245", "246", "247",
                                      "250", "251", "252", "253", "254", "255", "256", "257"};
      for (unsigned k = 0; k < 16; ++k) Want(std::string("word ") + names[k], PRead(0240 + k), want[k]);
      d->eval();
      Want("244 on the host's side", d->eth_tx_prod, want[4]);
      Want("250 on the host's side", d->eth_rx_prod, want[8]);
      Want("word 100's <8> as the interrupt",
           static_cast<uint64_t>(d->int_now),
           static_cast<uint64_t>((want[0] >> 8 & 1) && want[9] != want[10]));
      Want("word 100's <8>", PRead(0100) >> 8 & 1, (want[0] >> 8 & 1) && want[9] != want[10]);
      // The host's side reads the same registers.
      const qed_state s = State();
      Want("STATE's enabled", s.enabled, want[0] & 1);
      Want("STATE's interrupt enable", s.ie, want[0] >> 8 & 1);
      Want("TX_CONS on the host's side", s.tx_cons, want[5]);
      Want("RX_CONS on the host's side", s.rx_cons, want[9]);
      Want("RX_TAKEN on the host's side", s.rx_taken, want[10]);
      Want("COUNTS on the host's side", s.counts, want[1] & QED_COUNTS_MASK);
      ++steps;
    } else if (!op.empty()) {
      Fail("an operation this testbench does not know: " + op, 0, 0);
    }
  }
  if (up) Down();
  where.clear();
}

constexpr uint32_t STATE = 0x100, CLAIM = 0x104, TX_CONS = 0x11C, RX_CONS = 0x124, COUNTS = 0x12C;
constexpr unsigned H_TX_CONS = 7, H_RX_CONS = 9, H_COUNTS = 11;

// **A MOVE A DISABLE OVERTAKES**: the host's write of `off` handed over in
// the clock the machine's disable is taken, so that it is accepted in the
// epoch as that clock began and finds the device disabled the clock after.
// It must not land: no set cleared, and the index `word` 0 once enabled
// again.
void Overtaken(uint32_t off, unsigned widx, unsigned word) {
  const long from = static_cast<long>(log_clocks.size());
  const uint32_t e = Read(STATE) >> 16;
  d->m_awaddr = off;
  d->m_awlen = 0;
  d->m_awid = 5;
  d->m_awvalid = 1;
  d->m_wdata = e << 16 | 1u;
  d->m_wstrb = 0xF;
  d->m_wlast = 1;
  d->m_wvalid = 1;
  d->m_bready = 1;
  bool taken = false;
  for (int k = 0; k < 64 && !taken; ++k) {
    d->clk = 0;
    d->eval();
    const bool aw_now = d->m_awvalid && d->m_awready, w_now = d->m_wvalid && d->m_wready;
    taken = d->dbg_host_we && d->dbg_host_widx == widx;
    if (taken) {
      d->wr_v = 1;
      d->wr_k = 0240;
      d->wr_data = 0;
      d->eval();
    }
    Model();
    d->clk = 1;
    d->eval();
    ++ticks;
    if (aw_now) d->m_awvalid = 0;
    if (w_now) d->m_wvalid = 0;
    d->wr_v = 0;
  }
  Idle(8);
  d->m_bready = 0;
  Want("the overtaken write was taken", taken, 1);
  Want("no set cleared for a move a disable overtook", ClearsSince(from), 0);
  PWrite(0240, 1);
  Want("the index after the disable overtook its move", PRead(word), 0);
  // Nor once enabled again: no target left behind for the engine.
  Idle(200);
  Want("no set cleared once enabled again", ClearsSince(from), 0);
  Want("the index 200 clocks after", PRead(word), 0);
}

// Rings at 0 (two entries) and 64 (four), enabled with the interrupt
// enable; two transmits and three buffers posted.
void Rings() {
  PWrite(0242, 0);
  PWrite(0243, 1);
  PWrite(0246, 64);
  PWrite(0247, 2);
  PWrite(0240, 0x101);
  PHeld(0244, 2);
  PHeld(0250, 3);
}

void Host() {
  where = "the host's side: ";
  Up();
  // ------------------------------------------------------------ the map
  Want("IDENT, \"QE16\"", Read(0x000), 0x51453136u);
  Want("MEM_WORDS", Read(0x004), kMainWords);
  Want("a word nothing names, 0x008", Read(0x008), 0);
  Want("a word nothing names, 0x0FC", Read(0x0FC), 0);
  Want("a word nothing names past GATEWAY, 0x144", Read(0x144), 0);
  Want("the page's last word", Read(0xFFC), 0);
  Want("STATE out of reset: quiet, epoch 0", Read(STATE), 0x8u);
  // 253-257 and the counters from power-on.
  Want("253 at power-on", PRead(0253), 0x0200u);
  Want("254 at power-on", PRead(0254), 0x00000001u);
  Want("255 at power-on", PRead(0255), 0xA9FE6402u);
  Want("256 at power-on", PRead(0256), 0xFFFFFFFCu);
  Want("257 at power-on", PRead(0257), 0xA9FE6401u);
  Want("241 at power-on", PRead(0241), 0x2u);
  Want("COUNTS at power-on", Read(COUNTS), 0);
  // Each register at its offset, written and read back on both sides.
  const struct { uint32_t off; unsigned word; uint32_t v, back; } host[] = {
      {0x130, 0253, 0xFFFF1234u, 0x1234u}, {0x134, 0254, 0x89ABCDEFu, 0x89ABCDEFu},
      {0x138, 0255, 0x0A000102u, 0x0A000102u}, {0x13C, 0256, 0xFFFFFF00u, 0xFFFFFF00u},
      {0x140, 0257, 0x0A000101u, 0x0A000101u}};
  for (const auto &h : host) {
    Write(h.off, h.v);
    Want("the host's word read back at " + std::to_string(h.off), Read(h.off), h.back);
    Want("the machine's word " + std::to_string(h.word), PRead(h.word), h.back);
  }
  // Fewer than four bytes go nowhere.
  Write(0x134, 0x11111111u, 0x3);
  Want("254 after a write of two bytes", PRead(0254), 0x89ABCDEFu);
  Write(COUNTS, 0xFFFFFFFFu, 0x7);
  Want("COUNTS after a write of three bytes", Read(COUNTS), 0);
  // The counters in their places: the other bits read 0.
  Write(COUNTS, 0xFFFFFFFFu);
  Want("COUNTS's places", Read(COUNTS), 0xFFFFFEF0u);
  Want("241 with every counter full", PRead(0241), 0xFFFFFEF2u);
  // A COUNTS write lands at its edge: the clock after the one the host
  // hands it over in reads it.
  Write(COUNTS, 0x01021A30u);
  Want("COUNTS's write handed over", static_cast<uint64_t>(LastHostWrite(H_COUNTS) >= 0), 1);
  Want("241 after COUNTS", PRead(0241), 0x01021A32u);
  // Neither the counters nor 253-257 change at a disable, RESET-DEVICES or
  // a reset of the machine.
  PWrite(0240, 1);
  PWrite(0240, 0);
  PWrite(0104, 1);
  MachReset();
  Want("COUNTS after the resets", Read(COUNTS), 0x01021A30u);
  Want("254 after the resets", PRead(0254), 0x89ABCDEFu);
  Want("257 after the resets", PRead(0257), 0x0A000101u);
  Down();

  // ---------------------------------------------- the claim and the epoch
  Up();
  Want("the claim refused while disabled", static_cast<uint64_t>(face.claim(face.ctx, 0)), 0);
  PWrite(0240, 1);
  Want("STATE enabled, epoch 0", Read(STATE), 0x1u);
  Want("the claim refused under another epoch", static_cast<uint64_t>(face.claim(face.ctx, 1)), 0);
  Want("the claim taken in the epoch", static_cast<uint64_t>(face.claim(face.ctx, 0)), 1);
  Want("the claim taken a second time", static_cast<uint64_t>(face.claim(face.ctx, 0)), 1);
  Want("a refused claim leaves the claim held", (Write(CLAIM, 1u << 16 | 1u), Read(CLAIM)), 1);
  PWrite(0240, 0);
  Want("STATE after the disable: busy, not quiet, epoch 1", Read(STATE), 0x10004u);
  Want("241 after the disable: not quiet", PRead(0241) & 0x3u, 0);
  MachReset();
  Want("busy outlives a reset of the machine, which a disabled device does not count", Read(STATE),
       0x10004u);
  face.release(face.ctx);
  Want("STATE after the release: quiet", Read(STATE), 0x10008u);
  Want("241 after the release: quiet", PRead(0241) & 0x3u, 2);
  // The epoch counts RESET-DEVICES and a reset of an enabled device, and
  // not those of a disabled one.
  PWrite(0240, 1);
  PWrite(0104, 1);
  Want("the epoch after RESET-DEVICES of an enabled device", Read(STATE) >> 16, 2);
  PWrite(0104, 1);
  Want("the epoch after RESET-DEVICES of a disabled one", Read(STATE) >> 16, 2);
  PWrite(0240, 1);
  MachReset();
  Want("the epoch after a reset of an enabled device", Read(STATE) >> 16, 3);
  // A release in any epoch: claimed in 3, released by a write carrying 9.
  PWrite(0240, 1);
  face.claim(face.ctx, 3);
  Write(CLAIM, 9u << 16);
  Want("released under another epoch", Read(CLAIM), 0);
  Down();

  // -------------------------------------------------------- TX_CONS
  Up();
  Rings();
  Want("244 on the host's side once landed", static_cast<uint64_t>(State().tx_prod), 2);
  Want("250 on the host's side once landed", static_cast<uint64_t>(State().rx_prod), 3);
  Write(TX_CONS, 1u << 16 | 1u);
  Want("TX_CONS under a stale epoch", PRead(0245), 0);
  Write(TX_CONS, 3u);
  Want("TX_CONS past 244", PRead(0245), 0);
  Write(TX_CONS, 1u);
  Idle(3);
  {
    const long t = LastHostWrite(H_TX_CONS);
    Want("245 not in the clock after the write", log_clocks.at(t + 1).tx_cons, 0);
    Want("245 the clock after that", log_clocks.at(t + 2).tx_cons, 1);
  }
  Want("245 moved", PRead(0245), 1);
  Write(TX_CONS, 2u);
  Want("TX_CONS up to 244", PRead(0245), 2);
  Write(TX_CONS, 2u);
  Want("TX_CONS by nothing", PRead(0245), 2);
  PWrite(0240, 0);
  Write(TX_CONS, 1u << 16 | 0u);
  Want("TX_CONS while disabled", PRead(0245), 0);
  Down();

  // -------------------------------------------------------- RX_CONS
  Up();
  Rings();
  // Rings' four entries at 64, 72, 80 and 88, each a buffer at 1024 + 384k:
  // 60 bytes in a room of 32, so the room's one line and not the length's
  // two, and ending at a line's end; 1,514 bytes in 1,536, 48 lines; 0
  // bytes; and 2,000 bytes in 1,536 at a buffer five words into its line,
  // so that 1,514's 379 words end in line 47 and 380 would reach 48.
  static const uint64_t bufs[4] = {1024, 1408, 1792, 2176 + 5}, rooms[4] = {32, 1536, 1536, 1536},
                        lens[4] = {60, 1514, 0, 2000};
  for (uint32_t k = 0; k < 4; ++k) {
    port.mem[64 + 8 * k] = bufs[k];
    port.mem[64 + 8 * k + 1] = rooms[k];
    port.mem[64 + 8 * k + 2] = lens[k];
  }
  long from = static_cast<long>(log_clocks.size());
  Write(RX_CONS, 1u << 16 | 1u);
  Want("RX_CONS under a stale epoch", PRead(0251), 0);
  Write(RX_CONS, 0u);
  Want("RX_CONS by nothing", PRead(0251), 0);
  Write(RX_CONS, 4u);
  Want("RX_CONS past 250", PRead(0251), 0);
  Idle(100);
  Want("no set cleared for a refused move", ClearsSince(from), 0);
  Want("the engine idle after refused moves", static_cast<uint64_t>(d->eth_busy), 0);
  from = static_cast<long>(log_clocks.size());
  Write(RX_CONS, 1u);
  Want("the host's RX_CONS the target at once", Read(RX_CONS), 1);
  {
    const long t = LastHostWrite(H_RX_CONS);
    Delivered(t, 1, 64, port.mem[64], port.mem[65], port.mem[66]);
    long irq_at = -1, moved = -1;
    for (long k = t; k < static_cast<long>(log_clocks.size()); ++k) {
      if (irq_at < 0 && log_clocks[k].irq) irq_at = k;
      if (moved < 0 && log_clocks[k].rx_cons == 1) moved = k;
    }
    Want("the interrupt in the clock 251 moves at the end of", static_cast<uint64_t>(moved - irq_at), 1);
    Want("251 not before the entry's words are read", static_cast<uint64_t>(moved - t > 6), 1);
    Want("the engine idle once 251 moved", static_cast<uint64_t>(d->eth_busy), 0);
  }
  Want("251 moved", PRead(0251), 1);
  // Two entries under one write: each entry's lines, then its move.
  from = static_cast<long>(log_clocks.size());
  Write(RX_CONS, 3u);
  Want("the host's RX_CONS the target at once, two entries ahead", Read(RX_CONS), 3);
  Want("the engine busy while 251 is behind the target", static_cast<uint64_t>(d->eth_busy), 1);
  for (int k = 0; k < 2000 && d->dbg_rx_cons != 3; ++k) Step();
  Want("RX_CONS by two, up to 250", PRead(0251), 3);
  Want("the sets two entries cleared, 1,514 bytes and 0", ClearsSince(from), 48 + 1 + 1);
  // 2,000 bytes in a room of 1,536 clamped to 1,514.
  PHeld(0250, 4);
  from = static_cast<long>(log_clocks.size());
  Write(RX_CONS, 4u);
  for (int k = 0; k < 2000 && d->dbg_rx_cons != 4; ++k) Step();
  Want("RX_CONS to 4", PRead(0251), 4);
  Want("2,000 bytes clamped to 1,514: 48 sets and the entry's", ClearsSince(from), 48 + 1);
  // A disable while the engine works stops it: no set cleared once the
  // disable is taken, and 251 never moved.
  port.mem[65] = 1536;
  port.mem[66] = 1514;
  PWrite(0252, 1);
  PHeld(0250, 5);
  Want("250 at 5, the ring's four past 252", PRead(0250), 5);
  const long started = static_cast<long>(log_clocks.size());
  Write(RX_CONS, 5u);
  for (int k = 0; k < 2000 && !log_clocks.back().clear; ++k) Step();
  Want("a set cleared before the disable", log_clocks.back().clear, 1);
  PWrite(0240, 0);
  from = static_cast<long>(log_clocks.size());
  Idle(200);
  Want("no set cleared after a disable mid-delivery", ClearsSince(from), 0);
  Want("the engine idle after the disable", static_cast<uint64_t>(d->eth_busy), 0);
  {
    long at5 = 0;
    for (long t = started; t < static_cast<long>(log_clocks.size()); ++t) at5 += log_clocks[t].rx_cons == 5;
    Want("251 never at 5 through a disable mid-delivery", at5, 0);
  }
  PWrite(0240, 0x101);
  // A disable in the clock between the write and its landing drops it.
  PWrite(0240, 0);
  PWrite(0240, 0x101);
  PHeld(0250, 1);
  Overtaken(RX_CONS, H_RX_CONS, 0251);
  // And TX_CONS likewise: 245 stays at 0.
  PHeld(0244, 1);
  Overtaken(TX_CONS, H_TX_CONS, 0245);
  Down();

  // ------------------------------------- the entry read afresh each time
  // A ring of one entry, so that each delivery reads the same line: the
  // second must read the length the host wrote since, not the line as the
  // first read it.
  Up();
  PWrite(0242, 0);
  PWrite(0243, 1);
  PWrite(0246, 64);
  PWrite(0247, 0);
  PWrite(0240, 0x101);
  port.mem[64] = 1024;
  port.mem[65] = 1536;
  port.mem[66] = 60;
  PHeld(0250, 1);
  from = static_cast<long>(log_clocks.size());
  Write(RX_CONS, 1u);
  Delivered(from, 1, 64, 1024, 1536, 60);
  port.mem[66] = 1514;
  PWrite(0252, 1);
  PHeld(0250, 2);
  from = static_cast<long>(log_clocks.size());
  Write(RX_CONS, 2u);
  Delivered(from, 2, 64, 1024, 1536, 1514);
  Down();
  where.clear();
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  for (int k = 1; k < argc; ++k) Script(argv[k]);
  Host();
  std::printf("quux16_ethernet: %ld steps of muir's device, %ld deliveries and %ld transmit moves through "
              "the face, %ld checks, %d failed\n",
              steps, deliveries, moves, checks, bad);
  if (steps == 0) {
    std::fprintf(stderr, "FAIL: no script\n");
    return 1;
  }
  return bad ? 1 : 0;
}
