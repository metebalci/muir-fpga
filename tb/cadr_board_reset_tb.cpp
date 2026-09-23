// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The fabric's reset under the processor's transactions, on a whole board.
//
// **THE RULE.**  The fabric's reset --- BTN1 on the Zynq boards, KEY1 on the
// DE25-Nano, and the clock generator losing lock --- resets the machine and
// the register faces' state, and never breaks an AXI transaction the
// processing system has started.  Every read and write the processor issues
// on a general-purpose port or a processor-to-fabric bridge is answered per
// AXI whether it arrives before the reset, during it, or across it.  A read
// the fabric takes and never answers hangs both Arm cores, measured on the
// board, and the fabric's reset once did exactly that on all three boards:
// it held every splitter and face in its address state with ARREADY and
// AWREADY high.  `docs/board.md` has the rule.
//
// **WHAT THIS DRIVES AND WHAT IT HOLDS.**  The board's own top level,
// `tb/cadr_board_reset_harness.sv`, with the processing system replaced by
// `tb/cadr_ps7_sim.sv` or `tb/cadr_de25_hps_sim.sv`, whose masters and memory
// are the C++ below.  The top level is where the resets are wired, and
// nothing else in `make check` simulates one, so the wiring is what this is
// for.  On each port:
//
//   A CONTROL, WITH NO RESET.  A register of every face that holds state is
//   written and read back, and must read what was written.  That is what
//   makes the later read of its reset value a comparison and not a
//   confirmation: a register that could not be written would read its reset
//   value either way.
//
//   THE BUTTON, UNDER TRAFFIC.  Reads and writes to every page of both ports
//   are started a tick after the press, so that their addresses are taken
//   before the reset reaches the fabric and they are in flight when it
//   lands; more are started all through the hold, and more just before the
//   release, so that they run across it.  Every one must be answered with
//   exactly ARLEN+1 beats and RLAST on the last, the ID echoed, one write
//   response, and --- for the reads --- the face's own identity word, which
//   no reset changes.  And each must be answered within `ANSWER_T` ticks of
//   its address going out, while the button is still down: a face that
//   merely answered after the release would pass a weaker rule.
//
//   THE STATE, RESET.  After the release every register written in the
//   control reads its reset value: the faces are reset, as the documented
//   behavior says, and only their AXI state survives.
//
// **AND ON THE DE25-NANO, THE MEMORY PORT'S WIRING**, which is also only in
// its top level:
//
//   THE MACHINE WAITS FOR THE PORT AND THE PORT OPENS.  After software opens
//   the port the port is live and the machine is out of reset.  A port whose
//   reset were the machine's would never open, since the machine waits for
//   it.
//
//   THE PROCESSOR'S RESET RESETS THE PORT AT ONCE AND NOT THE MACHINE.  With
//   the display's reads stalled at the bridge, the processor is reset: the
//   bridge drops what it owed.  The machine must not be reset by it; and the
//   display must be, so that it asks again once the port is open, rather
//   than waiting for ever for beats that will never come.  A gate that made
//   the processor's reset wait for quiet would wait for ever here, too.
//
// THE MEMORY'S PROTOCOL IS WATCHED THROUGHOUT: an address or a write beat
// withdrawn before its handshake is counted, and the count must be zero.
//
// `CADR_BOARD_ARTY`, `CADR_BOARD_CORA` or `CADR_BOARD_DE25` picks the board.

#include "Vcadr_board_reset_harness.h"
#include "Vcadr_board_reset_harness__Dpi.h"
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

Vcadr_board_reset_harness *top;
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
#if defined(CADR_BOARD_DE25)
const char *BOARD = "DE25-Nano";
const bool DE25 = true;
// Offsets into the two bridges' windows.
const uint32_t PACK = 0x0000'0000, CHAOS = 0x0000'1000, SER = 0x0000'2000,
               INPUT = 0x0000'3000, DFLT0 = 0x0123'4560;
const uint32_t CONS = 0x0000'0000, WIN = 0x0000'1000, DFLT1 = 0x0076'5430;
const int ID_MASK = 0xF;
#else
#if defined(CADR_BOARD_CORA)
const char *BOARD = "Cora Z7-07S";
#else
const char *BOARD = "Arty Z7-20";
#endif
const bool DE25 = false;
const uint32_t PACK = 0x4000'0000, CHAOS = 0x4000'1000, SER = 0x4000'2000,
               INPUT = 0x4000'3000, DFLT0 = 0x4123'4560;
const uint32_t CONS = 0x8000'0000, WIN = 0x8000'1000, DFLT1 = 0x8765'4320;
const int ID_MASK = 0xFFF;
#endif

// The identity words, which no reset changes.
const uint32_t PACK_IDENT = 0x5041'434B;    // "PACK", word 7
const uint32_t NONE = 0x4E4F'4E45;          // the default slave's "NONE"
const uint32_t DBUG = 0x4442'5547;          // the window's IDENT

// How long an answer may take once its address is out.  The slowest face
// here takes a few ticks a beat; this is loose on purpose, and a face that
// swallows a read never answers at all.
const long ANSWER_T = 400;
// How long the button is held.  Far shorter than a finger, far longer than
// every answer above.
const long HOLD_T = 3000;

// The levels the processing system drives: `cadr_sim_level`.
int level[4] = {0, 1, 0, 1};   // Zynq ports' reset_n, h2f_reset, gp_out, req_n

// ------------------------------------------------------ the processor's side
struct Txn {
  std::string name;
  bool write;
  uint32_t addr;
  int len;                    // AxLEN: beats - 1
  uint32_t wdata;             // every beat of a write carries it
  bool check_rdata;
  uint32_t want;              // every beat of a read must read it
  int id;
  long not_before;
  // What happened.
  long t_out = -1, t_addr = -1, t_done = -1;
  int beats = 0;
  uint32_t first = 0;
  bool bad = false;
};

std::vector<Txn> txns;

struct Master {
  std::deque<int> rq, wq;
  int cur_r = -1, cur_w = -1;
  // What the master drives now.
  uint32_t awaddr = 0, awlen = 0, awid = 0, wdata = 0, araddr = 0, arlen = 0,
           arid = 0;
  bool awvalid = false, wvalid = false, wlast = false, bready = false,
       arvalid = false, rready = false;
  int wbeat = 0;
  bool aw_done = false, w_done = false;
};
Master masters[2];

int add(int port, const std::string &name, bool write, uint32_t addr, int len,
        uint32_t wdata, bool check, uint32_t want, long not_before) {
  static int next_id = 1;
  Txn t;
  t.name = name;
  t.write = write;
  t.addr = addr;
  t.len = len;
  t.wdata = wdata;
  t.check_rdata = check;
  t.want = want;
  t.id = (next_id++ * 5 + 3) & ID_MASK;
  t.not_before = not_before;
  txns.push_back(t);
  int i = static_cast<int>(txns.size()) - 1;
  (write ? masters[port].wq : masters[port].rq).push_back(i);
  return i;
}

}  // namespace

// The master: one read and one write outstanding at a time, as the
// processor's own loads and stores are here.
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
      if (t.t_addr < 0) {
        fail("%s: a beat before the address was taken", t.name.c_str());
        t.bad = true;
      }
      if ((rid & ID_MASK) != t.id) {
        fail("%s: RID %x, want %x", t.name.c_str(), rid, t.id);
        t.bad = true;
      }
      if (rresp != 0) {
        fail("%s: RRESP %d", t.name.c_str(), rresp);
        t.bad = true;
      }
      if (t.beats == 0) t.first = static_cast<uint32_t>(rdata);
      if (t.check_rdata && static_cast<uint32_t>(rdata) != t.want) {
        fail("%s: beat %d read %08x, want %08x", t.name.c_str(), t.beats,
             static_cast<uint32_t>(rdata), t.want);
        t.bad = true;
      }
      ++t.beats;
      const bool last_due = t.beats == t.len + 1;
      if (static_cast<bool>(rlast) != last_due) {
        fail("%s: RLAST %d on beat %d of %d", t.name.c_str(), rlast, t.beats,
             t.len + 1);
        t.bad = true;
      }
      if (rlast || last_due) {
        t.t_done = now;
        m.cur_r = -1;
        m.rready = false;
      }
    }
  }
  if (m.cur_r < 0 && !m.rq.empty() && txns[m.rq.front()].not_before <= now) {
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
      if (!m.aw_done || !m.w_done) {
        fail("%s: a response before the address and the data were taken",
             t.name.c_str());
        t.bad = true;
      }
      if ((bid & ID_MASK) != t.id) {
        fail("%s: BID %x, want %x", t.name.c_str(), bid, t.id);
        t.bad = true;
      }
      if ((bresp & 2) != 0) {
        fail("%s: BRESP %d", t.name.c_str(), bresp);
        t.bad = true;
      }
      t.t_done = now;
      m.cur_w = -1;
      m.bready = false;
    }
  }
  if (m.cur_w < 0 && !m.wq.empty() && txns[m.wq.front()].not_before <= now) {
    m.cur_w = m.wq.front();
    m.wq.pop_front();
    Txn &t = txns[m.cur_w];
    m.awaddr = t.addr;
    m.awlen = static_cast<uint32_t>(t.len);
    m.awid = static_cast<uint32_t>(t.id);
    m.wdata = t.wdata;
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
  *o_wdata = static_cast<int>(m.wdata);
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

struct MemRead {
  int id;
  uint32_t addr;
  int len;
  long due;
  int beat = 0;
};
struct MemWrite {
  int id;
};

struct Mem {
  std::deque<MemRead> rq;
  std::deque<MemWrite> aw;
  int w_bursts = 0;            // write bursts whose last beat has come
  bool b_pending = false;
  int b_id = 0;
  // What the memory drives now.
  bool arready = true, rvalid = false, awready = true, wready = true,
       bvalid = false, rlast = false;
  uint64_t rdata = 0;
  int rid = 0;
  // What the master drove last time, for the protocol watch.
  bool last_arvalid = false, last_awvalid = false, last_wvalid = false;
  bool last_arready = true, last_awready = true, last_wready = true;
  // Reads carrying this ID are taken and never answered, while it is >= 0.
  int stall_id = -1;
  long ar_by_id[32] = {};
  long withdrawn = 0;
};
Mem mems[5];

uint64_t word_at(uint32_t a) {
  return 0xA500'0000'0000'0000ull ^ (static_cast<uint64_t>(a) * 0x9E37'79B9ull);
}

}  // namespace

void cadr_sim_mem(int port, svBit rst, int awaddr, int awlen, int awid,
                  svBit awvalid, long long wdata, int wstrb, svBit wlast,
                  svBit wvalid, svBit bready, int araddr, int arlen, int arid,
                  svBit arvalid, svBit rready, svBit *o_awready,
                  svBit *o_wready, svBit *o_bvalid, int *o_bresp, int *o_bid,
                  svBit *o_arready, svBit *o_rvalid, long long *o_rdata,
                  int *o_rresp, int *o_rid, svBit *o_rlast) {
  (void)awaddr;
  (void)wdata;
  (void)wstrb;
  Mem &m = mems[port];
  if (rst) {
    // The bridge in reset: everything it owed is gone.
    const int stall = m.stall_id;
    long counts[32];
    for (int i = 0; i < 32; i++) counts[i] = m.ar_by_id[i];
    const long withdrawn = m.withdrawn;
    m = Mem();
    m.stall_id = stall;
    for (int i = 0; i < 32; i++) m.ar_by_id[i] = counts[i];
    m.withdrawn = withdrawn;
    m.arready = m.awready = m.wready = false;
    m.last_arready = m.last_awready = m.last_wready = false;
  } else {
    // The watch: a valid that stood unanswered at the last edge must stand.
    if (m.last_arvalid && !m.last_arready && !arvalid) ++m.withdrawn;
    if (m.last_awvalid && !m.last_awready && !awvalid) ++m.withdrawn;
    if (m.last_wvalid && !m.last_wready && !wvalid) ++m.withdrawn;
    m.last_arvalid = arvalid;
    m.last_awvalid = awvalid;
    m.last_wvalid = wvalid;

    // Reads, answered in order after a latency.
    if (arvalid && m.arready) {
      MemRead r;
      r.id = arid;
      r.addr = static_cast<uint32_t>(araddr);
      r.len = arlen;
      r.due = now + 12;
      m.rq.push_back(r);
      ++m.ar_by_id[arid & 31];
    }
    if (m.rvalid && rready) {
      MemRead &r = m.rq.front();
      if (++r.beat > r.len) m.rq.pop_front();
    }
    m.rvalid = false;
    m.rlast = false;
    if (!m.rq.empty() && m.rq.front().due <= now &&
        m.rq.front().id != m.stall_id) {
      MemRead &r = m.rq.front();
      m.rvalid = true;
      m.rid = r.id;
      m.rdata = word_at(r.addr + 8u * static_cast<uint32_t>(r.beat));
      m.rlast = r.beat == r.len;
    }
    m.arready = m.rq.size() < 4;

    // Writes: always ready, a response per burst once both halves are in.
    if (awvalid && m.awready) m.aw.push_back(MemWrite{awid});
    if (wvalid && m.wready && wlast) ++m.w_bursts;
    if (m.bvalid && bready) m.bvalid = false;
    if (!m.bvalid && !m.aw.empty() && m.w_bursts > 0) {
      m.bvalid = true;
      m.b_id = m.aw.front().id;
      m.aw.pop_front();
      --m.w_bursts;
    }
    (void)awlen;
    m.awready = true;
    m.wready = true;
    m.last_arready = m.arready;
    m.last_awready = m.awready;
    m.last_wready = m.wready;
  }
  *o_awready = m.awready;
  *o_wready = m.wready;
  *o_bvalid = m.bvalid;
  *o_bresp = 0;
  *o_bid = m.b_id;
  *o_arready = m.arready;
  *o_rvalid = m.rvalid;
  *o_rdata = static_cast<long long>(m.rdata);
  *o_rresp = 0;
  *o_rid = m.rid;
  *o_rlast = m.rlast;
}

int cadr_sim_level(int which) { return level[which]; }

// ------------------------------------------------------------------ running
namespace {

bool pressed = false;

void tick() {
  // BTN1 is high while pressed on the Zynq boards; KEY1 is low.
  const int b1 = DE25 ? !pressed : pressed;
  top->btn = static_cast<uint8_t>((b1 << 1) | (DE25 ? 1 : 0));
  top->clk = 0;
  top->eval();
  top->clk = 1;
  top->eval();
  ++now;
}

void run(long n) {
  for (long i = 0; i < n; i++) tick();
}

// Run until every transaction queued so far is done, or `limit` ticks.
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

// The results of every transaction so far, against the rule.
void judge(const char *phase) {
  int n = 0;
  for (Txn &t : txns) {
    if (t.name.rfind(phase, 0) != 0) continue;
    ++n;
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
  std::printf("%s: %s, %d transactions\n", BOARD, phase, n);
}

// The registers each face holds, written in the control and read after the
// reset: offset from the face's base, the value written, what it reads back,
// and what it reads at reset.  A write that reads back something else is
// named so, and the control fails.
struct Reg {
  const char *name;
  int port;
  uint32_t addr;
  uint32_t write;
  uint32_t reads;
  uint32_t reset;
};

std::vector<Reg> regs() {
  return {
      {"pack ADDR", 0, PACK + 0x00, 0x0001'2380, 0x0001'2380, 0},
      {"chaos MYADDR", 0, CHAOS + 0x08, 0x0000'1234, 0x0000'1234, 0},
      {"serial CTL", 0, SER + 0x10, 0x5, 0x5, 0},
      // KEY reads back the word last handed to the card, with bit 24 set once
      // one ever has been; the machine's own reset empties the queue and
      // leaves this, so only the fabric's reset clears it.
      {"input KEY", 0, INPUT + 0x08, 0x0012'3456, 0x0112'3456, 0},
      {"console LAMPS", 1, CONS + 0x8C, 0x5354'4459, 0x4C44'0001, 0x4C44'0000},
  };
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  top = new Vcadr_board_reset_harness;
  std::printf("%s: the fabric's reset under the processor's transactions\n",
              BOARD);

  // --- the processor out of reset, and on the DE25 the memory port opened.
  // The fabric comes up in its own reset, as it does on the board while the
  // clock generator locks: the stubs lock at once, so the button stands in.
  pressed = true;
  run(50);
  pressed = false;
  run(50);
  level[0] = 1;   // the Zynq ports out of reset
  level[1] = 0;   // the DE25's processor out of reset
  run(100);
  level[2] = 1;   // software opens the memory port
  // And the machine running for a while, so that its microcycle count is
  // well past what it can reach again between the release and the reads.
  run(5000);
  if (top->mach_rst) fail("the machine is in reset before the control, with nothing pressed");
  if (DE25) {
    if (!top->port_live) fail("the memory port is not live after software opened it");
    if (top->mach_rst) fail("the machine is still in reset after the port opened");
  }

  // --- the control: every face's register written and read back.
  const std::vector<Reg> rs = regs();
  std::vector<int> ctl_reads;
  long t0 = now;
  for (const Reg &r : rs) add(r.port, std::string("control ") + r.name, true, r.addr, 0, r.write, false, 0, t0);
  if (!settle(4000)) fail("the control's writes did not finish");
  // The window: a lift with nothing standing is its third sticky fault.
  add(1, "control window CTL", true, WIN + 0x04, 0, 0, false, 0, now);
  // And the console's engine: a diagnostic read, which sets STAT's
  // `answered`, bit 2.
  add(1, "control console diagnostic read", false, CONS + 0x40, 0, 0, false, 0, now);
  if (!settle(20000)) fail("the control's window write and diagnostic read did not finish");
  t0 = now;
  for (const Reg &r : rs)
    ctl_reads.push_back(add(r.port, std::string("control ") + r.name, false, r.addr, 0, 0, true, r.reads, t0));
  // FAULTS is {count, the marker 01 in bits 15:14, eleven zeros, the three
  // faults}: the marker alone at reset, and the third fault after the lift.
  const int win_ctl = add(1, "control window FAULTS", false, WIN + 0x10, 0, 0, true, 0x0000'4004, t0);
  const int stat_ctl = add(1, "control console STAT", false, CONS + 0x04, 0, 0, false, 0, t0);
  const int cycles_ctl = add(1, "control console CYCLES", false, CONS + 0x08, 0, 0, false, 0, t0);
  if (!settle(4000)) fail("the control's reads did not finish");
  judge("control");
  (void)win_ctl;
  if (!(txns[stat_ctl].first & 4u))
    fail("control: the console's STAT reads %08x, without `answered` after a "
         "diagnostic read", txns[stat_ctl].first);

  // --- the button, under traffic.
  const long press = now + 20;
  auto storm = [&](const char *tag, long at) {
    // Every page of both ports: a four-beat read of each face's identity
    // word where the face has one in a run, single reads otherwise, and a
    // write to a word that ignores it.
    add(0, std::string("press ") + tag + " pack", false, PACK + 0x1C, 0, 0, true, PACK_IDENT, at);
    add(0, std::string("press ") + tag + " default0", false, DFLT0, 3, 0, true, NONE, at);
    add(0, std::string("press ") + tag + " chaos", false, CHAOS, 0, 0, false, 0, at);
    add(0, std::string("press ") + tag + " serial", false, SER, 0, 0, false, 0, at);
    add(0, std::string("press ") + tag + " input", false, INPUT, 0, 0, false, 0, at);
    add(1, std::string("press ") + tag + " window", false, WIN, 0, 0, true, DBUG, at);
    add(1, std::string("press ") + tag + " default1", false, DFLT1, 3, 0, true, NONE, at);
    add(1, std::string("press ") + tag + " console", false, CONS, 1, 0, false, 0, at);
    add(0, std::string("press ") + tag + " write default0", true, DFLT0, 1, 0x1111'1111, false, 0, at);
    add(0, std::string("press ") + tag + " write pack REQ", true, PACK + 0x14, 0, 0x2222'2222, false, 0, at);
    add(1, std::string("press ") + tag + " write default1", true, DFLT1, 1, 0x3333'3333, false, 0, at);
    add(1, std::string("press ") + tag + " write console IDENT", true, CONS, 0, 0x4444'4444, false, 0, at);
  };
  storm("before", press + 1);           // out before the reset reaches the fabric
  storm("during", press + 200);
  storm("late", press + HOLD_T - 40);   // runs across the release
  // The press, held; every answer is due while it is still down.
  while (now < press) tick();
  pressed = true;
  bool mach_reset_seen = false;
  while (now < press + HOLD_T) {
    tick();
    if (top->mach_rst) mach_reset_seen = true;
  }
  pressed = false;
  const long release = now;
  if (!settle(20000)) fail("the transactions under the button did not all finish");
  judge("press");
  if (!mach_reset_seen) fail("the button did not reset the machine");

  // --- the state, reset: every register the control wrote reads its reset
  // value, and the window's faults are clear.
  run(400);
  t0 = now;
  for (const Reg &r : rs)
    add(r.port, std::string("after ") + r.name, false, r.addr, 0, 0, true, r.reset, t0);
  const int win_after = add(1, "after window FAULTS", false, WIN + 0x10, 0, 0, true, 0x0000'4000, t0);
  const int stat_after = add(1, "after console STAT", false, CONS + 0x04, 0, 0, false, 0, t0);
  // CYCLES, the machine's microcycles: counted again from the reset, so
  // fewer than the control read before the press, when the machine had been
  // running far longer than it has since the release.
  const int cycles_after = add(1, "after console CYCLES", false, CONS + 0x08, 0, 0, false, 0, t0);
  if (!settle(4000)) fail("the reads after the button did not finish");
  judge("after");
  (void)win_after;
  if (txns[stat_after].first & 4u)
    fail("after: the console's STAT still reads `answered` (%08x)", txns[stat_after].first);
  std::printf("%s: CYCLES %u before the press, %u %ld ticks after the release\n",
              BOARD, txns[cycles_ctl].first, txns[cycles_after].first,
              txns[cycles_after].t_done - release);
  if (txns[cycles_ctl].first == 0) fail("control: CYCLES reads zero on a running machine");
  if (txns[cycles_after].first >= txns[cycles_ctl].first)
    fail("after: CYCLES reads %u, not below the %u before the press: it was not reset",
         txns[cycles_after].first, txns[cycles_ctl].first);

  // --- the DE25-Nano's memory port.
  if (DE25) {
    Mem &f2s = mems[4];
    if (top->mach_rst) fail("the machine did not come back out of reset after KEY1");
    if (!top->port_live) fail("the memory port did not come back after KEY1");
    // Wait for the display to be reading, then stall its reads at the
    // bridge until one is outstanding.
    long waited = 0;
    while (f2s.ar_by_id[2] == 0 && waited < 3'000'000) { tick(); ++waited; }
    if (f2s.ar_by_id[2] == 0) {
      fail("the display never read the memory port");
    } else {
      f2s.stall_id = 2;
      const long asked = f2s.ar_by_id[2];
      waited = 0;
      while (f2s.ar_by_id[2] == asked && waited < 3'000'000) { tick(); ++waited; }
      run(50);
      std::printf("%s: the display has a read the bridge is not answering\n", BOARD);
      // The processor's reset, and the port reopened after it as software
      // would: `h2f_gp_out` is driven low by every processor reset.
      bool mach_reset = false;
      level[1] = 1;
      level[2] = 0;
      for (int i = 0; i < 200; i++) {
        tick();
        if (top->mach_rst) mach_reset = true;
      }
      f2s.stall_id = -1;
      const long before = f2s.ar_by_id[2];
      level[1] = 0;
      run(100);
      level[2] = 1;
      long t = 0;
      bool live = false;
      while (t < 3'000'000 && f2s.ar_by_id[2] == before) {
        tick();
        ++t;
        if (top->port_live) live = true;
        if (top->mach_rst) mach_reset = true;
      }
      if (mach_reset) fail("the processor's reset reset the running machine");
      if (!live) fail("the memory port did not reopen after the processor's reset");
      if (f2s.ar_by_id[2] == before)
        fail("the display never asked again after the processor's reset: it is "
             "waiting for beats the bridge dropped");
      else
        std::printf("%s: the display asked again %ld ticks after the port reopened\n",
                    BOARD, t);
    }
  }

  for (int p = 0; p < 5; p++)
    if (mems[p].withdrawn != 0)
      fail("memory port %d: %ld addresses or write beats withdrawn before their "
           "handshake", p, mems[p].withdrawn);

  top->final();
  delete top;
  if (failures) {
    std::printf("%s: %d failure%s\n", BOARD, failures, failures == 1 ? "" : "s");
    return 1;
  }
  std::printf("ok: %s answers every transaction across the fabric's reset, "
              "and the reset resets the faces' registers\n", BOARD);
  return 0;
}
