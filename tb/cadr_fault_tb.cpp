// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The fault bitstream, on each board's own fault top level.
//
// **WHAT IT IS.**  The top level U-Boot loads when the CADR's bitstream could
// not be loaded: no machine, every lamp blinking together, and the processor's
// side of the board kept whole so that Linux runs on and can say what
// happened.  `boards/*/cadr_*_fault.sv` are the three, and
// `tb/cadr_fault_harness.sv` puts one of them between the processor of
// `tb/cadr_ps7_sim.sv` or `tb/cadr_de25_hps_sim.sv` and this file.
//
// **WHAT IT HOLDS.**
//
//   THE LAMPS.  Every lamp that must blink is sampled on every tick.  All of
//   them must read the same at every tick, which is in phase; each must be
//   dark from configuration for one half period, then lit for one, then dark,
//   at the harness's `HALF_T`, which is the polarity and the rate against an
//   absolute clock rather than against each other; and the green and blue
//   pins of every color lamp must never light, which is red and red only.
//   The DE25-Nano's lamps are lit LOW, the Zynq boards' high.
//
//   EVERY WINDOW ANSWERED.  Reads and writes at every page the CADR's
//   bitstream decodes on both ports, and at addresses between and beyond
//   them, with burst lengths from one beat to the port's longest: each read
//   must return exactly ARLEN+1 beats, RLAST on the last and on no other,
//   its ID, OKAY and "FALT" in every beat; each write one OKAY response with
//   its ID.  Each within `ANSWER_T` ticks of its address going out, so that
//   a port that swallowed an address fails here and does not hang a
//   processor.
//
//   THE TALLY.  What the programs read before anything else must be "FALT":
//   both EMIO words on a Zynq board, and `h2f_gp_in` on the DE25-Nano
//   whichever half `h2f_gp_out[1]` selects.  That is what makes every program
//   refuse this fabric and what the init scripts recognize.
//
//   NOTHING MASTERS MEMORY.  Every valid on every memory port is counted,
//   and the count must be zero; and the ports must have been looked at, so a
//   harness that never reached them is not taken for a quiet one.
//
//   ON THE DE25-Nano, THE WARM-RESET HANDSHAKE.  Never acknowledged while no
//   request stands, watched on every tick with the gate shut and open;
//   acknowledged within a few ticks of the request, as U-Boot's `bridge
//   enable` requires; and withdrawn when the request is.

#include "Vcadr_fault_harness.h"
#include "Vcadr_fault_harness__Dpi.h"
#include "verilated.h"
#include "svdpi.h"

#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <string>
#include <vector>

namespace {

Vcadr_fault_harness *top;
long now = 0;
int failures = 0;

void fail(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void fail(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  std::printf("FAIL t=%ld: ", now);
  std::vprintf(fmt, ap);
  std::printf("\n");
  va_end(ap);
  ++failures;
}

// ---------------------------------------------------------------- the board
const uint32_t FALT = 0x4641'4C54;   // "FALT"
const long HALF_T = 64;              // the harness's default
#if defined(CADR_BOARD_DE25)
const char *BOARD = "DE25-Nano";
const bool DE25 = true;
const int LAMPS = 8;
const char *LAMP_NAME[8] = {"LEDR0", "LEDR1", "LEDR2", "LEDR3",
                            "LEDR4", "LEDR5", "LEDR6", "LEDR7"};
const char *DARK_NAME[4] = {"", "", "", ""};
const int DARK = 0;
const int ID_MASK = 0xF;
const int MAX_LEN = 255;
// Offsets into the two bridges' windows, as the fabric sees them: the
// HPS-to-FPGA bridge's 30 bits and the lightweight bridge's 29.
const std::vector<uint32_t> PORT0 = {0x0000'0000, 0x0000'1000, 0x0000'2000,
                                     0x0000'3000, 0x0000'4000, 0x0123'4560,
                                     0x3FFF'FFFC};
const std::vector<uint32_t> PORT1 = {0x0000'0000, 0x0000'1000, 0x0000'2000,
                                     0x0076'5430, 0x1FFF'FFFC};
const int MEM_PORTS[] = {4};
#else
#if defined(CADR_BOARD_CORA)
const char *BOARD = "Cora Z7-07S";
const int LAMPS = 2;
const char *LAMP_NAME[8] = {"LD0 red", "LD1 red", "", "", "", "", "", ""};
const char *DARK_NAME[4] = {"LD0 green", "LD0 blue", "LD1 green", "LD1 blue"};
const int MEM_PORTS[] = {0, 2};
#else
const char *BOARD = "Arty Z7-20";
const int LAMPS = 6;
const char *LAMP_NAME[8] = {"LD0", "LD1", "LD2", "LD3", "LD4 red", "LD5 red", "", ""};
const char *DARK_NAME[4] = {"LD4 green", "LD4 blue", "LD5 green", "LD5 blue"};
const int MEM_PORTS[] = {0, 2, 3};
#endif
const bool DE25 = false;
const int DARK = 4;
const int ID_MASK = 0xFFF;
const int MAX_LEN = 15;
// `M_AXI_GP0` from 0x4000_0000 and `M_AXI_GP1` from 0x8000_0000, 1 GB each:
// the four faces' pages, the console's and the debug window's, and
// addresses between and beyond them.
const std::vector<uint32_t> PORT0 = {0x4000'0000, 0x4000'1000, 0x4000'2000,
                                     0x4000'3000, 0x4000'4000, 0x4123'4560,
                                     0x7FFF'FFFC};
const std::vector<uint32_t> PORT1 = {0x8000'0000, 0x8000'1000, 0x8000'2000,
                                     0x8765'4320, 0xBFFF'FFFC};
#endif

const long ANSWER_T = 1200;

// The levels the processing system drives: `cadr_sim_level`.
int level[4] = {0, 1, 0, 1};   // Zynq ports' reset_n, h2f_reset, gp_out, req_n

// ------------------------------------------------------ the processor's side
struct Txn {
  std::string name;
  bool write;
  uint32_t addr;
  int len;
  int id;
  long t_out = -1, t_addr = -1, t_done = -1;
  int beats = 0;
};

std::vector<Txn> txns;

struct Master {
  std::deque<int> rq, wq;
  int cur_r = -1, cur_w = -1;
  uint32_t awaddr = 0, awlen = 0, awid = 0, araddr = 0, arlen = 0, arid = 0;
  bool awvalid = false, wvalid = false, wlast = false, bready = false,
       arvalid = false, rready = false;
  int wbeat = 0;
  bool aw_done = false, w_done = false;
};
Master masters[2];

void add(int port, const std::string &name, bool write, uint32_t addr, int len) {
  static int next_id = 1;
  Txn t;
  t.name = name;
  t.write = write;
  t.addr = addr;
  t.len = len;
  t.id = (next_id++ * 7 + 5) & ID_MASK;
  txns.push_back(t);
  const int i = static_cast<int>(txns.size()) - 1;
  (write ? masters[port].wq : masters[port].rq).push_back(i);
}

}  // namespace

void cadr_sim_gp(int port, svBit awready, svBit wready, svBit bvalid, int bresp,
                 int bid, svBit arready, svBit rvalid, int rdata, int rresp,
                 int rid, svBit rlast, int *o_awaddr, int *o_awlen, int *o_awid,
                 svBit *o_awvalid, int *o_wdata, int *o_wstrb, svBit *o_wlast,
                 svBit *o_wvalid, svBit *o_bready, int *o_araddr, int *o_arlen,
                 int *o_arid, svBit *o_arvalid, svBit *o_rready) {
  Master &m = masters[port];

  // --- the read channel
  if (m.arvalid && arready) {
    m.arvalid = false;
    txns[m.cur_r].t_addr = now;
  }
  if (rvalid && m.rready) {
    if (m.cur_r < 0) {
      fail("port %d: a read beat with no read outstanding", port);
    } else {
      Txn &t = txns[m.cur_r];
      if (t.t_addr < 0) fail("%s: a beat before the address was taken", t.name.c_str());
      if ((rid & ID_MASK) != t.id) fail("%s: RID %x, want %x", t.name.c_str(), rid, t.id);
      if (rresp != 0) fail("%s: RRESP %d", t.name.c_str(), rresp);
      if (static_cast<uint32_t>(rdata) != FALT)
        fail("%s: beat %d read %08x, want FALT %08x", t.name.c_str(), t.beats,
             static_cast<uint32_t>(rdata), FALT);
      ++t.beats;
      const bool last_due = t.beats == t.len + 1;
      if (static_cast<bool>(rlast) != last_due)
        fail("%s: RLAST %d on beat %d of %d", t.name.c_str(), rlast, t.beats, t.len + 1);
      if (rlast || last_due) {
        t.t_done = now;
        m.cur_r = -1;
        m.rready = false;
      }
    }
  }
  if (m.cur_r < 0 && !m.rq.empty()) {
    m.cur_r = m.rq.front();
    m.rq.pop_front();
    Txn &t = txns[m.cur_r];
    m.araddr = t.addr;
    m.arlen = static_cast<uint32_t>(t.len);
    m.arid = static_cast<uint32_t>(t.id);
    m.arvalid = true;
    m.rready = true;
    t.t_out = now;
  }

  // --- the write channel
  if (m.awvalid && awready) {
    m.awvalid = false;
    m.aw_done = true;
    txns[m.cur_w].t_addr = now;
  }
  if (m.wvalid && wready) {
    if (m.wlast) {
      m.wvalid = false;
      m.w_done = true;
    } else {
      ++m.wbeat;
      m.wlast = m.wbeat == txns[m.cur_w].len;
    }
  }
  if (bvalid && m.bready) {
    if (m.cur_w < 0) {
      fail("port %d: a write response with no write outstanding", port);
    } else {
      Txn &t = txns[m.cur_w];
      if (!m.aw_done || !m.w_done)
        fail("%s: a response before the address and the data were taken", t.name.c_str());
      if ((bid & ID_MASK) != t.id) fail("%s: BID %x, want %x", t.name.c_str(), bid, t.id);
      if (bresp != 0) fail("%s: BRESP %d", t.name.c_str(), bresp);
      t.t_done = now;
      m.cur_w = -1;
      m.bready = false;
    }
  }
  if (m.cur_w < 0 && !m.wq.empty()) {
    m.cur_w = m.wq.front();
    m.wq.pop_front();
    Txn &t = txns[m.cur_w];
    m.awaddr = t.addr;
    m.awlen = static_cast<uint32_t>(t.len);
    m.awid = static_cast<uint32_t>(t.id);
    m.awvalid = true;
    m.wvalid = true;
    m.wbeat = 0;
    m.wlast = t.len == 0;
    m.aw_done = false;
    m.w_done = false;
    m.bready = true;
    t.t_out = now;
  }

  *o_awaddr = static_cast<int>(m.awaddr);
  *o_awlen = static_cast<int>(m.awlen);
  *o_awid = static_cast<int>(m.awid);
  *o_awvalid = m.awvalid;
  *o_wdata = static_cast<int>(0x5A5A'0000u | static_cast<uint32_t>(m.wbeat));
  *o_wstrb = 0xF;
  *o_wlast = m.wlast;
  *o_wvalid = m.wvalid;
  *o_bready = m.bready;
  *o_araddr = static_cast<int>(m.araddr);
  *o_arlen = static_cast<int>(m.arlen);
  *o_arid = static_cast<int>(m.arid);
  *o_arvalid = m.arvalid;
  *o_rready = m.rready;
}

// ------------------------------------------------------------ the memory side
namespace {
long mem_calls[5] = {};
long mem_valids[5] = {};
}  // namespace

// Memory that is never asked anything: ready everywhere, never valid.  Every
// valid the fabric raises is counted.
void cadr_sim_mem(int port, svBit rst, int awaddr, int awlen, int awid,
                  svBit awvalid, long long wdata, int wstrb, svBit wlast,
                  svBit wvalid, svBit bready, int araddr, int arlen, int arid,
                  svBit arvalid, svBit rready, svBit *o_awready,
                  svBit *o_wready, svBit *o_bvalid, int *o_bresp, int *o_bid,
                  svBit *o_arready, svBit *o_rvalid, long long *o_rdata,
                  int *o_rresp, int *o_rid, svBit *o_rlast) {
  (void)awaddr; (void)awlen; (void)awid; (void)wdata; (void)wstrb; (void)wlast;
  (void)bready; (void)araddr; (void)arlen; (void)arid; (void)rready;
  ++mem_calls[port];
  if (!rst && (awvalid || wvalid || arvalid)) {
    if (mem_valids[port] == 0)
      fail("memory port %d: the fabric raised %s%s%s", port, awvalid ? "AWVALID " : "",
           wvalid ? "WVALID " : "", arvalid ? "ARVALID" : "");
    ++mem_valids[port];
  }
  *o_awready = !rst;
  *o_wready = !rst;
  *o_bvalid = 0;
  *o_bresp = 0;
  *o_bid = 0;
  *o_arready = !rst;
  *o_rvalid = 0;
  *o_rdata = 0;
  *o_rresp = 0;
  *o_rid = 0;
  *o_rlast = 0;
}

int cadr_sim_level(int which) { return level[which]; }

// ------------------------------------------------------------------ running
namespace {

// The lamps, sampled after every edge.
long lamp_ticks = 0;
long lamp_changes = 0;
long last_change = -1;
bool lamp_state = false;
bool lamp_seen = false;
long first_change = -1;
long out_of_phase[8] = {};
long dark_lit[4] = {};
long bad_spacing = 0;

bool lit(int i) {
  const bool pin = (top->blink >> i) & 1;
  return DE25 ? !pin : pin;
}

void watch_lamps() {
  ++lamp_ticks;
  const bool s = lit(0);
  for (int i = 1; i < LAMPS; i++)
    if (lit(i) != s && out_of_phase[i]++ == 0)
      fail("%s reads %s while %s reads %s: the lamps are not in phase",
           LAMP_NAME[i], lit(i) ? "lit" : "dark", LAMP_NAME[0], s ? "lit" : "dark");
  for (int i = 0; i < DARK; i++)
    if (((top->dark >> i) & 1) && dark_lit[i]++ == 0)
      fail("%s is lit: a color lamp shows red and nothing else", DARK_NAME[i]);
  if (!lamp_seen) {
    lamp_seen = true;
    lamp_state = s;
    if (s) fail("%s is lit at configuration: the first half period is dark", LAMP_NAME[0]);
    return;
  }
  if (s != lamp_state) {
    lamp_state = s;
    ++lamp_changes;
    if (first_change < 0) {
      first_change = now;
      if (!s) fail("%s's first change is to dark: the lamps are lit the wrong way", LAMP_NAME[0]);
    } else if (now - last_change != HALF_T && bad_spacing++ == 0) {
      fail("%s changed %ld ticks after its last change, want %ld", LAMP_NAME[0],
           now - last_change, HALF_T);
    }
    last_change = now;
  }
}

// The warm-reset acknowledgment, watched on every tick: never given while no
// request has stood for longer than the synchronizers take, from the first
// ticks after configuration on.  A check made only at one moment would miss an
// acknowledgment given at another.
long unasked_since = 0;
long unasked_acks = 0;

void watch_ack() {
  if (level[3] == 0) {
    unasked_since = -1;
    return;
  }
  if (unasked_since < 0) unasked_since = now;
  if (now - unasked_since > 10 && now > 10 && !top->warm_ack_n && unasked_acks++ == 0)
    fail("the warm-reset acknowledgment is given with no request standing");
}

void tick() {
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
  ++now;
  watch_lamps();
  watch_ack();
}

void run(long n) {
  for (long i = 0; i < n; i++) tick();
}

bool settle(long limit) {
  for (long i = 0; i < limit; i++) {
    bool all = true;
    for (const Txn &t : txns)
      if (t.t_done < 0) all = false;
    if (all) return true;
    tick();
  }
  return false;
}

void judge() {
  for (Txn &t : txns) {
    if (t.t_done < 0) {
      fail("%s: never answered (address %s)", t.name.c_str(),
           t.t_addr >= 0 ? "taken" : "not taken");
      continue;
    }
    if (t.t_done - t.t_out > ANSWER_T)
      fail("%s: answered %ld ticks after its address went out", t.name.c_str(),
           t.t_done - t.t_out);
    if (!t.write && t.beats != t.len + 1)
      fail("%s: %d beats, want %d", t.name.c_str(), t.beats, t.len + 1);
  }
}

void check_tally(const char *when) {
  const uint64_t w = top->tally;
  const uint32_t lo = static_cast<uint32_t>(w), hi = static_cast<uint32_t>(w >> 32);
  if (lo != FALT) fail("%s: the tally's word reads %08x, want FALT %08x", when, lo, FALT);
  if (!DE25 && hi != FALT)
    fail("%s: the tally's second word reads %08x, want FALT %08x", when, hi, FALT);
  // And it must fail the programs' own marker test, `cadr_tally_ok`.
  if ((lo & 0x8000'8000u) == 0x0000'8000u || (!DE25 && (hi & 0x8000'8000u) == 0x0000'8000u))
    fail("%s: the tally carries the CADR's marker bits", when);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vcadr_fault_harness;
  std::printf("%s: the fault bitstream\n", BOARD);

  // --- the processor out of reset.
  run(40);
  level[0] = 1;   // the Zynq ports out of reset
  level[1] = 0;   // the DE25's processor out of reset
  run(40);
  check_tally("after the processor's reset");

  // --- every window, answered: each address as a single read and a single
  // write, then bursts of every shape up to the port's longest.
  const int lens[] = {0, 1, 3, 7, MAX_LEN};
  for (int port = 0; port < 2; port++) {
    const std::vector<uint32_t> &addrs = port == 0 ? PORT0 : PORT1;
    for (uint32_t a : addrs) {
      char nm[64];
      for (int len : lens) {
        std::snprintf(nm, sizeof nm, "port %d read %08x len %d", port, a, len);
        add(port, nm, false, a, len);
        std::snprintf(nm, sizeof nm, "port %d write %08x len %d", port, a, len);
        add(port, nm, true, a, len);
      }
    }
  }
  if (!settle(400000)) fail("the transactions did not all finish");
  judge();
  std::printf("%s: %zu transactions on both ports, each answered\n", BOARD, txns.size());

  // --- the tally, and on the DE25-Nano whichever half is selected, with the
  // memory gate open as U-Boot would open it on the CADR's build.
  if (DE25) {
    level[2] = 0x3;   // the gate open and the high half selected
    run(20);
    check_tally("with h2f_gp_out[1] high");
    level[2] = 0x1;
    run(20);
    check_tally("with h2f_gp_out[1] low");

    // --- the warm-reset handshake.
    level[3] = 0;   // the request, low when asserted
    long t = 0;
    while (top->warm_ack_n && t < 200) { tick(); ++t; }
    if (top->warm_ack_n)
      fail("the warm-reset request was not acknowledged in %ld ticks", t);
    else
      std::printf("%s: the warm-reset request was acknowledged %ld ticks after it\n", BOARD, t);
    level[3] = 1;
    t = 0;
    while (!top->warm_ack_n && t < 200) { tick(); ++t; }
    if (!top->warm_ack_n) fail("the acknowledgment stayed after the request was withdrawn");
    // And the bridges answer again after it.
    const size_t before = txns.size();
    add(0, "after the handshake, port 0 read", false, 0x0000'0000, 3);
    add(1, "after the handshake, port 1 read", false, 0x0000'0000, 3);
    add(0, "after the handshake, port 0 write", true, 0x0000'2000, 0);
    if (!settle(4000)) fail("the reads after the handshake did not finish");
    judge();
    (void)before;
  }

  // --- the lamps, over a run long enough for many half periods.
  run(20 * HALF_T);
  check_tally("at the end");
  std::printf("%s: %d lamps, %ld changes in %ld ticks, the first at tick %ld\n", BOARD,
              LAMPS, lamp_changes, lamp_ticks, first_change);
  if (lamp_changes < 20) fail("the lamps changed %ld times, want at least 20", lamp_changes);
  if (first_change < 0 || first_change < HALF_T - 2 || first_change > HALF_T + 2)
    fail("the lamps first lit at tick %ld, want about %ld: dark for one half period "
         "from configuration", first_change, HALF_T);

  // --- nothing mastered memory, and the ports were looked at.
  for (int p : MEM_PORTS) {
    if (mem_calls[p] == 0) fail("memory port %d was never looked at", p);
    if (mem_valids[p] != 0) fail("memory port %d: %ld ticks with a valid raised", p, mem_valids[p]);
  }

  top->final();
  delete top;
  if (failures) {
    std::printf("%s: %d failure%s\n", BOARD, failures, failures == 1 ? "" : "s");
    return 1;
  }
  std::printf("ok: %s's fault bitstream blinks every lamp together, answers every "
              "window with FALT and masters no memory\n", BOARD);
  return 0;
}
