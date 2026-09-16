// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Arty A7-100's memory path, against a model of the controller it drives.
//
// WHAT IS BEING HELD TO WHAT.  There is no muir reference for any of this ---
// nothing in MIT's drawings is a DDR3 controller, and `busint::MemoryBoard`
// models a board of 4116s refreshing itself.  So this is held to what it has
// to be true of, which is the same list `cadr_axi_master`'s check holds its
// module to, plus the two things that are new on this board:
//
//   1. A read returns what a write put there, with the shadow kept HERE and
//      keyed by the address the STIMULUS asked for --- never by anything the
//      design under test computed.  A shadow keyed off the design moves with
//      the bug: a path that drops an address bit writes and reads the same
//      wrong place and agrees with itself.
//   2. A write lands in ITS OWN LANE of the sixteen-byte block and in no
//      other.  That is the fault this family of module actually makes, and
//      the model's poison --- injective in the address, so a neighbor's word
//      is recognizably a neighbor's --- is what makes it visible.
//   3. The controller's own protocol, watched in the model: an aligned block
//      address, a write burst that ends, a command held still until it is
//      taken, and write data that never arrives more than two user clocks
//      after its command.
//   4. **TWO CLOCKS**, which is what is new here.  The machine's tick and the
//      controller's user clock have no fixed relationship, so every
//      transaction is started at a different phase of one against the other,
//      and the run is done twice at two different ratios.  A crossing that
//      works at one phase and not another is the fault a single ratio hides.
//   5. The debugger's window, which on this board is the only way into memory
//      from outside the machine: its scan register, its command, and that a
//      machine transaction and a window transaction in flight together both
//      complete and neither takes the other's answer.
//   6. **THE DISK PACK FACE'S OWN MASTER, AND THE SOFT SYSTEM'S WINDOW, ON THE
//      SAME PORT.**  A record the window writes is fetched by the real face
//      and read STRAIGHT OUT OF THE STORE the face filled, not back through the
//      path it came by --- a round trip cannot see a fault that is the same in
//      both directions, such as the two halves of a beat swapped both ways.
//      Then the face writes the slot back to an area the window poisoned
//      first, and the window reads it and the model's own memory agrees; the
//      pad after the record must still be poison.  And a record placed outside
//      the machine's reservation fails its move rather than landing somewhere.
//   7. **THE MACHINE FIRST, HELD TO A NUMBER.**  The machine's own accesses are
//      run twice from reset at the same instants, once with nobody else asking
//      and once with the face fetching and writing back a record for the
//      whole run and the window streaming words beside it, and no access may
//      grow by more than ONE access: the word another master had in flight
//      when the machine asked.  This is `tb/cadr_memory_path_tb.cpp`'s
//      configuration B for the Zynq's channel arbiter, on this board's
//      arbiter.  A run where the machine never once asked while another master
//      had the port would pass that bound while testing nothing, so that is a
//      failure of its own.
//
// **THE READ LATENCY IS SWEPT AND THE BACKPRESSURE IS DELIBERATE.**  A model
// that always answers at once and never refuses is a model of a memory nobody
// has, and this project has already recorded what a stimulus more polite than
// the real consumer tests: nothing.

#include <cstdio>
#include <cstdlib>
#include <map>
#include <vector>

#include "Vcadr_a7_mem_harness.h"
#include "verilated.h"

namespace {

Vcadr_a7_mem_harness *dut;
long ps = 0;          // the model's own time, in nanoseconds
int clk_half = 5;     // the machine's tick is 10 ns
int ui_half = 6;      // the controller's user clock, swept below
long clk_next = 0, ui_next = 0;
int bad = 0;

// **WHAT ONE ACCESS COSTS THE MACHINE BEYOND ITS OWN.**  The word another
// master had in flight is at most as long as the machine's own longest access,
// and handing the port over costs a few ticks more: the owner letting go, the
// answer falling, the choice, and the crossing's own acknowledgment clearing
// before it takes the next request.  Set from the measured worst and not a
// round number, so that a second word in the machine's way fails.
const long kHandover = 9;

// The machine's reservation, and the board's translation of it: the map's
// 128 MB at 0x1800_0000 is the TOP half of this board's 256 MB.
const unsigned RESERVED_BASE = 0x18000000u;
unsigned DdrByte(unsigned mem_addr) {
  return 0x08000000u | (mem_addr & 0x07FFFFFFu);
}
// What the model answers for a word nothing has written.
unsigned Poison(unsigned mem_addr) {
  return 0xB0000000u ^ ((DdrByte(mem_addr) & 0x0FFFFFFFu) >> 2);
}

void Step() {
  ++ps;
  if (ps >= clk_next) {
    dut->clk = !dut->clk;
    clk_next = ps + clk_half;
  }
  if (ps >= ui_next) {
    dut->ui_clk = !dut->ui_clk;
    ui_next = ps + ui_half;
  }
  dut->eval();
}

void Steps(int n) {
  for (int i = 0; i < n; ++i) Step();
}

// **EVERY DISAGREEMENT LINE BEGINS WITH `FAIL:`**, so that the first one is
// what a mutation run reports as the catching line rather than the count at the
// end, which says that something disagreed and not what.
int Fail(const char *what, unsigned got, unsigned want) {
  std::fprintf(stderr, "FAIL: ns %ld: %s is 0x%08x, expected 0x%08x\n", ps,
               what, got, want);
  ++bad;
  return 1;
}

// One transaction on the machine's own port, driven the way `cadr_xbus_ddr`
// drives it: the address and the data stand before the request goes up, the
// request is HELD until the word is done, and it is let go afterwards.  **A
// stimulus that dropped the request the instant `mem_done` appeared would be
// more polite than the real consumer and would test less.**
// `hold_ns` is how long the controller refuses, MEASURED FROM THE REQUEST and
// not from before it.  **The first draft set the refusal up and took it down
// again before raising the request**, so the design never once had to wait ---
// a stimulus more polite than the real consumer, and the mutation written to
// break UG586's write-data rule was then caught by a side effect instead of by
// the rule.  The refusal now stands across the transaction and is lifted under
// it.
bool Access(bool write, unsigned addr, unsigned wdata, unsigned *rdata,
            long limit = 20000, int hold_cmd = 0, int hold_wdata = 0,
            int hold_ns = 0) {
  dut->mem_addr = addr;
  dut->mem_wdata = wdata;
  dut->mem_write = write;
  dut->hold_cmd = hold_cmd;
  dut->hold_wdata = hold_wdata;
  Steps(3);
  dut->mem_req = 1;
  long t = 0;
  while (!dut->mem_done) {
    Step();
    if (t == hold_ns) {
      dut->hold_cmd = 0;
      dut->hold_wdata = 0;
    }
    if (++t > limit) {
      std::fprintf(stderr, "FAIL: ns %ld: no answer for %s at 0x%08x\n", ps,
                   write ? "a write" : "a read", addr);
      ++bad;
      dut->mem_req = 0;
      return false;
    }
  }
  if (rdata) *rdata = dut->mem_rdata;
  bool err = dut->mem_error;
  dut->mem_req = 0;
  while (dut->mem_done) Step();
  Steps(2);
  return err;
}

unsigned Peek(unsigned mem_addr) {
  dut->peek_addr = DdrByte(mem_addr);
  dut->eval();
  return dut->peek_data;
}

// ---------------------------------------------------------- the JTAG window
//
// One data register of 160 bits on a `BSCANE2` user chain, scanned the way
// Vivado's `scan_dr_hw_jtag` scans one: bit zero first in both directions, so
// a bit number here is the bit number the host script uses.
const int DR_BITS = 160;

struct Scan {
  unsigned out[5];  // what came back, 160 bits as five words
};

Scan ScanDr(const unsigned in[5]) {
  Scan s{};
  dut->jtag_sel = 1;
  // CAPTURE-DR: one clock of DRCK with capture high.
  dut->jtag_capture = 1;
  dut->jtag_shift = 0;
  dut->jtag_drck = 0;
  Steps(2);
  dut->jtag_drck = 1;
  Steps(2);
  dut->jtag_drck = 0;
  dut->jtag_capture = 0;
  Steps(2);
  // SHIFT-DR.
  dut->jtag_shift = 1;
  for (int i = 0; i < DR_BITS; ++i) {
    dut->jtag_tdi = (in[i / 32] >> (i % 32)) & 1;
    dut->eval();
    if (dut->jtag_tdo) s.out[i / 32] |= (1u << (i % 32));
    dut->jtag_drck = 1;
    Steps(2);
    dut->jtag_drck = 0;
    Steps(2);
  }
  dut->jtag_shift = 0;
  // UPDATE-DR.  **HELD FOR TEN OF THE MACHINE'S TICKS AND NOT ONE.**  The
  // fabric synchronizes this pulse into its own clock with three registers, so
  // a pulse shorter than a few ticks can be missed --- and a real test access
  // port runs at a few megahertz, where this is microseconds.  Written short
  // the first time, it made the window miss about one command in ten and read
  // as a fabric fault.
  dut->jtag_update = 1;
  Steps(100);
  dut->jtag_update = 0;
  Steps(100);
  return s;
}

int go_bit = 0;
int arm_bit = 0;

// Ask the window for one transaction and collect the answer with a second
// scan, which is what the host script does: a data register scan is both
// halves at once and the fabric has done the work in between.
unsigned WindowAccess(bool write, unsigned addr, unsigned wdata,
                      bool *err_out) {
  unsigned in[5] = {0, 0, 0, 0, 0};
  go_bit ^= 1;
  in[0] = wdata;
  in[1] = addr;
  in[2] = (write ? 1u : 0u) | ((unsigned)go_bit << 1) |
          ((unsigned)arm_bit << 2);
  ScanDr(in);
  // The fabric has microseconds; give it a few hundred nanoseconds.
  Steps(2000);
  // The same command word again, `go` unchanged, so that the re-scan is
  // harmless --- which is the property that lets a host poll.
  Scan s = ScanDr(in);
  if (err_out) *err_out = (s.out[3] >> 2) & 1;
  unsigned ident = s.out[4];
  if (ident != 0x4D454D57u) {
    std::fprintf(stderr, "FAIL: ns %ld: the window's IDENT is 0x%08x, not "
                 "MEMW\n", ps, ident);
    ++bad;
  }
  return s.out[0];
}

// ------------------------------------------------ the machine's rising edge
//
// One rising edge of the machine's clock, with the values right after it.  The
// disk pack face and its master are in that clock, so whether a handshake with
// either happens at an edge is decided by what stands just before it --- which
// is what stood just after the edge before, nothing in that domain moving
// between edges.
void Rise() {
  for (;;) {
    int before = dut->clk;
    Step();
    if (!before && dut->clk) return;
  }
}

// --------------------------------------------- the disk pack face's registers
//
// `pack_side.h`'s numbers, written out: this check is C++ against the fabric
// and does not link the Linux program's C.
const unsigned PACK_BASE = 0x40000000u;
enum { PS_ADDR = 0, PS_TAG = 1, PS_SLOT = 2, PS_CTL = 3, PS_IDENT = 7 };
enum { CTL_FETCH = 1, CTL_WRITE = 2 };
enum { ST_BUSY = 1, ST_DONE = 2, ST_ERROR = 4, ST_REFUSED = 8 };
const unsigned REC_WORDS = 259;
const unsigned PACK_IDENT = 0x5041434Bu;  // "PACK"

// One write of one of the face's registers, a single beat as the bridge and
// Linux both make one, with the address and the data offered together.
void PackWrite(unsigned reg, unsigned v) {
  dut->pk_awaddr = PACK_BASE + 4u * reg;
  dut->pk_wdata = v;
  dut->pk_wstrb = 0xF;
  dut->pk_awvalid = 1;
  dut->pk_wvalid = 1;
  dut->pk_bready = 1;
  for (int t = 0; t < 4000; ++t) {
    dut->eval();
    bool haw = dut->pk_awvalid && dut->pk_awready;
    bool hw = dut->pk_wvalid && dut->pk_wready;
    bool hb = dut->pk_bvalid && dut->pk_bready;
    Rise();
    if (haw) dut->pk_awvalid = 0;
    if (hw) dut->pk_wvalid = 0;
    if (hb) {
      dut->pk_bready = 0;
      return;
    }
  }
  std::fprintf(stderr, "FAIL: ns %ld: the disk pack face never answered a "
                       "write of register %u; a hang, so the run stops here\n",
               ps, reg);
  std::exit(1);
}

unsigned PackRead(unsigned reg) {
  dut->pk_araddr = PACK_BASE + 4u * reg;
  dut->pk_arvalid = 1;
  dut->pk_rready = 1;
  for (int t = 0; t < 4000; ++t) {
    dut->eval();
    bool har = dut->pk_arvalid && dut->pk_arready;
    bool hr = dut->pk_rvalid && dut->pk_rready;
    unsigned data = dut->pk_rdata;
    Rise();
    if (har) dut->pk_arvalid = 0;
    if (hr) {
      dut->pk_rready = 0;
      return data;
    }
  }
  std::fprintf(stderr, "FAIL: ns %ld: the disk pack face never answered a "
                       "read of register %u; a hang, so the run stops here\n",
               ps, reg);
  std::exit(1);
}

// One move, run to its end, as `ps_request` runs one: the four registers, then
// the status word read until the move is not busy.  The status it ended with.
unsigned PackMove(unsigned ctl, unsigned addr, unsigned tag, unsigned slot) {
  PackWrite(PS_ADDR, addr);
  PackWrite(PS_TAG, tag);
  PackWrite(PS_SLOT, slot);
  PackWrite(PS_CTL, ctl);
  unsigned st = PackRead(PS_CTL);
  for (int polls = 0; (st & ST_BUSY) && polls < 40000; ++polls)
    st = PackRead(PS_CTL);
  if (st & ST_BUSY) {
    std::fprintf(stderr, "FAIL: ns %ld: a move of the disk pack face stayed "
                         "busy for 40,000 polls; a hang, so the run stops "
                         "here\n", ps);
    std::exit(1);
  }
  return st;
}

// One word through the soft system's DDR window, driven as the bridge drives
// it: the address and the data first, the request held until the answer, and
// let go afterwards.
unsigned Win(bool write, unsigned addr, unsigned wdata) {
  dut->win_addr = addr;
  dut->win_wdata = wdata;
  dut->win_write = write;
  Steps(3);
  dut->win_req = 1;
  long t = 0;
  while (!dut->win_done) {
    Step();
    if (++t > 40000) {
      std::fprintf(stderr, "FAIL: ns %ld: the window got no answer at 0x%08x; "
                           "a hang, so the run stops here\n", ps, addr);
      std::exit(1);
    }
  }
  unsigned r = dut->win_rdata;
  dut->win_req = 0;
  while (dut->win_done) Step();
  Steps(2);
  return r;
}

// A place of a slot, straight out of the store the face fills.
unsigned StorePeek(unsigned slot, unsigned place) {
  dut->store_peek_slot = slot;
  dut->store_peek_addr = place;
  dut->eval();
  return dut->store_peek_data;
}

// The record, a family of words injective in the address, and the poison the
// write-back area holds first --- a family no record word can be at these
// addresses.
unsigned RecWord(unsigned base, unsigned i, int cfg) {
  return 0x5EC00000u ^ (base + 4u * i) ^ ((unsigned)cfg << 20);
}
unsigned RecPoison(unsigned addr) { return ~addr; }

// -------------------------------------------------- the machine first, timed
//
// One run from reset of the machine's own accesses, at fixed instants, with
// the disk pack face and the soft system's window either idle or streaming.
struct GrowthRun {
  std::vector<long> lat;       // per access, ticks from the request to its answer
  long collisions = 0;         // accesses asked while another master had the port
  long pack_moves = 0;         // fetches and write-backs the face finished
  long window_words = 0;       // words the window moved
  long answers[4] = {0, 0, 0, 0};  // the arbiter's answers, per master
};

void ResetForRun(bool read_hold) {
  ps = 0;
  clk_next = 0;
  ui_next = 0;
  dut->clk = 0;
  dut->ui_clk = 0;
  dut->rst = 1;
  dut->ui_rst = 1;
  dut->mem_req = 0;
  dut->mem_write = 0;
  dut->mem_addr = 0;
  dut->mem_wdata = 0;
  dut->win_req = 0;
  dut->win_write = 0;
  dut->win_addr = 0;
  dut->win_wdata = 0;
  dut->pk_awvalid = 0;
  dut->pk_wvalid = 0;
  dut->pk_bready = 0;
  dut->pk_arvalid = 0;
  dut->pk_rready = 0;
  dut->jtag_drck = 0;
  dut->jtag_sel = 0;
  dut->jtag_shift = 0;
  dut->jtag_capture = 0;
  dut->jtag_update = 0;
  dut->hold_cmd = 0;
  dut->hold_wdata = 0;
  dut->read_latency = read_hold ? 4 : 4;
  Steps(200);
  dut->rst = 0;
  dut->ui_rst = 0;
  Steps(200);
}

GrowthRun RunGrowth(bool busy, int cfg, unsigned a1, unsigned a2,
                    unsigned slot, unsigned tag) {
  GrowthRun g;
  ResetForRun(false);
  Rise();

  // The machine's script: a write then a read of the same word, in pairs, each
  // at an instant fixed from reset, far enough apart that one access is over
  // before the next begins even when it waited.  The spacing is a prime and
  // the jitter is a residue of another, so the machine's requests land at
  // every phase of the face's word period and of the controller's clock.
  //
  // **THE ADDRESSES KEEP OFF THE RECORD'S PLACES IN THE MODEL.**  The model
  // is direct-mapped on the low twelve bits of a block number --- bits 15:4
  // of a byte address --- and it reads a block whose tag does not match as
  // poison, which is what keeps it from aliasing.  So a word written here
  // whose index is the record's would evict the record, and the fetch after it
  // would bring back poison.  The first draft did exactly that, at index 0,
  // and it read as the face moving the wrong words.  The record's two areas
  // are at indices 0x000 to 0x0C0; the machine's words are at 0x400 and the
  // window's at 0x600.
  const int N = 96;
  const unsigned M_BASE = 0x18404000u + (unsigned)cfg * 0x10000u +
                          (busy ? 0x800u : 0u);
  auto start_of = [](int i) { return 400L + 181L * i + (long)((i * 53) % 37); };
  auto mword = [&](int i) {
    return 0x6A000000u ^ (M_BASE + 4u * (unsigned)(i / 2)) ^ (unsigned)i;
  };
  int mi = 0, mst = 0;
  long t_req = 0;

  // The face: a fetch of the record and a write-back of it, over and over, as
  // register writes and status polls.  Only between moves may it stop.
  struct Op {
    int kind;  // 0 a write, 1 a poll of the status
    unsigned reg, val;
  };
  const std::vector<Op> ops = {{0, PS_ADDR, a1},   {0, PS_TAG, tag},
                               {0, PS_SLOT, slot}, {0, PS_CTL, CTL_FETCH},
                               {1, PS_CTL, 0},     {0, PS_ADDR, a2},
                               {0, PS_SLOT, slot}, {0, PS_CTL, CTL_WRITE},
                               {1, PS_CTL, 0}};
  size_t pc = 0;
  int pst = 0;  // 0 idle, 1 a write out, 2 a read out
  bool f_aw = false, f_w = false, f_b = false, f_ar = false, f_r = false;
  unsigned r_data = 0;

  // The window: a write then a read of the same word, back to back.
  const unsigned W_BASE = 0x1C906000u + (unsigned)cfg * 0x10000u;
  auto wword = [&](int k) {
    return 0x7B000000u ^ (W_BASE + 4u * (unsigned)((k / 2) % 32)) ^ (unsigned)k;
  };
  int wk = 0, wst = 0;

  unsigned prev_done = 0;
  long tick = 0;
  for (;;) {
    Rise();
    ++tick;

    unsigned sd = dut->sh_done_o;
    for (int i = 0; i < 4; ++i)
      if ((sd >> i & 1) && !(prev_done >> i & 1)) g.answers[i]++;
    prev_done = sd;

    const bool machine_over = (mi >= N);

    // --- the face's register traffic: what the last edge completed
    if (pst == 1) {
      if (f_aw) dut->pk_awvalid = 0;
      if (f_w) dut->pk_wvalid = 0;
      if (f_b) {
        dut->pk_bready = 0;
        pst = 0;
        ++pc;
      }
    } else if (pst == 2) {
      if (f_ar) dut->pk_arvalid = 0;
      if (f_r) {
        dut->pk_rready = 0;
        pst = 0;
        if (!(r_data & ST_BUSY)) {
          if ((r_data & (ST_DONE | ST_ERROR | ST_REFUSED)) != ST_DONE)
            Fail("a move's status while the machine ran", r_data, ST_DONE);
          ++g.pack_moves;
          ++pc;
        }
      }
    }
    if (pc == ops.size()) pc = 0;
    if (busy && pst == 0 && !(machine_over && pc == 0)) {
      const Op &op = ops[pc];
      if (op.kind == 0) {
        dut->pk_awaddr = PACK_BASE + 4u * op.reg;
        dut->pk_wdata = op.val;
        dut->pk_wstrb = 0xF;
        dut->pk_awvalid = 1;
        dut->pk_wvalid = 1;
        dut->pk_bready = 1;
        pst = 1;
      } else {
        dut->pk_araddr = PACK_BASE + 4u * op.reg;
        dut->pk_arvalid = 1;
        dut->pk_rready = 1;
        pst = 2;
      }
    }

    // --- the machine
    switch (mst) {
      case 0:
        if (mi < N && tick >= start_of(mi)) {
          dut->mem_addr = M_BASE + 4u * (unsigned)(mi / 2);
          dut->mem_write = (mi % 2) == 0;
          dut->mem_wdata = mword(mi);
          mst = 1;
        }
        break;
      case 1:
        dut->mem_req = 1;
        t_req = tick;
        if (dut->sh_busy_o && dut->sh_owner_o != 0) ++g.collisions;
        mst = 2;
        break;
      case 2:
        if (dut->mem_done) {
          g.lat.push_back(tick - t_req);
          if ((mi % 2) == 1 && dut->mem_rdata != mword(mi - 1))
            Fail("the machine's word while the others streamed", dut->mem_rdata,
                 mword(mi - 1));
          dut->mem_req = 0;
          mst = 3;
        }
        break;
      default:
        if (!dut->mem_done) {
          ++mi;
          mst = 0;
        }
        break;
    }

    // --- the window
    if (busy) {
      switch (wst) {
        case 0:
          if (!machine_over || (wk % 2) == 1) {
            dut->win_addr = W_BASE + 4u * (unsigned)((wk / 2) % 32);
            dut->win_write = (wk % 2) == 0;
            dut->win_wdata = wword(wk);
            wst = 1;
          }
          break;
        case 1:
          dut->win_req = 1;
          wst = 2;
          break;
        case 2:
          if (dut->win_done) {
            if ((wk % 2) == 1 && dut->win_rdata != wword(wk - 1))
              Fail("the window's word while the others streamed",
                   dut->win_rdata, wword(wk - 1));
            ++g.window_words;
            dut->win_req = 0;
            wst = 3;
          }
          break;
        default:
          if (!dut->win_done) {
            ++wk;
            wst = 0;
          }
          break;
      }
    }

    // --- the handshakes the next edge will make
    dut->eval();
    f_aw = dut->pk_awvalid && dut->pk_awready;
    f_w = dut->pk_wvalid && dut->pk_wready;
    f_b = dut->pk_bvalid && dut->pk_bready;
    f_ar = dut->pk_arvalid && dut->pk_arready;
    f_r = dut->pk_rvalid && dut->pk_rready;
    r_data = dut->pk_rdata;

    if (machine_over && mst == 0 &&
        (!busy || (pst == 0 && pc == 0 && wst == 0 && (wk % 2) == 0)))
      break;
    if (tick > 400000) {
      std::fprintf(stderr, "FAIL: a growth run did not finish: machine %d of "
                           "%d, face op %zu, window op %d; a hang, so the run "
                           "stops here\n", mi, N, pc, wk);
      std::exit(1);
    }
  }

  if (dut->viol_addr_align || dut->viol_wdf_end || dut->viol_cmd_unstable ||
      dut->viol_wdata_late) {
    std::fprintf(stderr, "FAIL: the controller's protocol was broken while "
                         "three masters shared the port\n");
    ++bad;
  }
  return g;
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  dut = new Vcadr_a7_mem_harness;

  long writes = 0, reads = 0, reads_checked = 0, window_ops = 0;
  long lanes_checked = 0, neighbours_checked = 0, refused = 0;
  long contended = 0, stalled_cmd = 0, stalled_wdata = 0;
  long store_checked = 0, backs_checked = 0, soc_window_words = 0;
  long pack_moves = 0, refused_moves = 0;
  long collisions = 0, growth_accesses = 0, worst_growth = 0, bound_used = 0;

  // The two ratios.  `ui_half` 6 makes the controller's clock 83.3 MHz against
  // the machine's 100, and 7 makes it 71.4 --- neither is a whole ratio of the
  // other, so each transaction starts at a different phase.
  for (int cfg = 0; cfg < 2; ++cfg) {
    ui_half = cfg == 0 ? 6 : 7;
    ps = 0;
    clk_next = 0;
    ui_next = 0;
    go_bit = 0;
    arm_bit = 0;

    dut->clk = 0;
    dut->ui_clk = 0;
    dut->rst = 1;
    dut->ui_rst = 1;
    dut->mem_req = 0;
    dut->mem_write = 0;
    dut->mem_addr = 0;
    dut->mem_wdata = 0;
    dut->jtag_drck = 0;
    dut->jtag_sel = 0;
    dut->jtag_shift = 0;
    dut->jtag_capture = 0;
    dut->jtag_update = 0;
    dut->jtag_tdi = 0;
    dut->calib_done = 1;
    dut->prove_has_run = 0;
    dut->prove_matched = 0;
    dut->hold_cmd = 0;
    dut->hold_wdata = 0;
    dut->read_latency = 3;
    dut->peek_addr = 0;
    dut->pk_awaddr = 0;
    dut->pk_awvalid = 0;
    dut->pk_wdata = 0;
    dut->pk_wstrb = 0;
    dut->pk_wvalid = 0;
    dut->pk_bready = 0;
    dut->pk_araddr = 0;
    dut->pk_arvalid = 0;
    dut->pk_rready = 0;
    dut->win_req = 0;
    dut->win_write = 0;
    dut->win_addr = 0;
    dut->win_wdata = 0;
    dut->store_peek_slot = 0;
    dut->store_peek_addr = 0;
    Steps(200);
    dut->rst = 0;
    dut->ui_rst = 0;
    Steps(200);

    // **THE TWO RUNS USE DIFFERENT ADDRESSES, BECAUSE THE MEMORY IS NOT
    // CLEARED BETWEEN THEM.**  A model that forgot everything at each reset
    // would be a model of a memory nobody has, and the first draft of this
    // check read the first run's words back in the second and called them
    // corruption.  Eight megabytes apart is far enough that the model's own
    // index and tag both differ.
    const unsigned CFG_OFF = (unsigned)cfg * 0x00800000u;

    std::map<unsigned, unsigned> shadow;  // keyed by the STIMULUS's address
    unsigned seed = 12345u + cfg;
    auto lcg = [&seed]() {
      seed = seed * 1664525u + 1013904223u;
      return seed >> 8;
    };

    // ---- 1. writes and reads, at every phase, with the controller refusing
    for (int op = 0; op < 400; ++op) {
      // Inside the machine's own reservation, and drawn from a SMALL SET OF
      // ADDRESSES spread by an odd stride.  Small, so that a read usually
      // lands on something a write put there --- a run whose reads mostly hit
      // never-written words would be checking the model's poison and not the
      // path.  Odd, because 452 bytes is twenty-eight blocks and one lane, so
      // consecutive slots move the block AND the lane and every one of the
      // four lanes is exercised.
      unsigned slot = lcg() % 96;
      unsigned addr = RESERVED_BASE + CFG_OFF + slot * 452u;
      dut->read_latency = op % 12;
      // The controller refuses, and goes on refusing while the design waits.
      int hc = (op % 5) == 0;
      int hw = (op % 7) == 0;
      // **LONG ENOUGH TO BE A REFUSAL AND NOT A HICCUP.**  Two hundred to six
      // hundred nanoseconds is sixteen to forty-eight of the controller's own
      // clocks, where thirty was two and a half --- and UG586's write-data
      // rule is broken at THREE, so a shorter refusal cannot tell a design
      // that keeps the rule from one that does not.
      int hns = (hc || hw) ? 200 + (op % 400) : 0;
      if (hc) ++stalled_cmd;
      if (hw) ++stalled_wdata;
      if ((op % 3) == 0) {
        unsigned v = lcg() | 0x80000001u;
        Access(true, addr, v, nullptr, 20000, hc, hw, hns);
        shadow[addr] = v;
        ++writes;
      } else {
        unsigned got = 0;
        Access(false, addr, 0, &got, 20000, hc, hw, hns);
        ++reads;
        auto it = shadow.find(addr);
        unsigned want = it == shadow.end() ? Poison(addr) : it->second;
        if (it != shadow.end()) ++reads_checked;
        if (got != want) Fail("a read", got, want);
      }
    }

    // ---- 2. all four lanes of one block, written differently
    //
    // A lane select stuck at one value collapses the four into one, and the
    // read-back then shows the last word written four times.  That is the
    // fault, and it is invisible to a check that writes one lane.
    {
      unsigned base = RESERVED_BASE + CFG_OFF + 0x0002A000u;  // block aligned
      unsigned v[4] = {0x11223344u, 0x55667788u, 0x99AABBCCu, 0xDDEEFF01u};
      for (int l = 0; l < 4; ++l) Access(true, base + 4 * l, v[l], nullptr);
      for (int l = 0; l < 4; ++l) {
        unsigned got = 0;
        Access(false, base + 4 * l, 0, &got);
        if (got != v[l]) Fail("a lane of a block", got, v[l]);
        ++lanes_checked;
        // ...and the model's own memory says the same, which is what tells a
        // read that compensates for a wrong write from one that is right.
        unsigned in_model = Peek(base + 4 * l);
        if (in_model != v[l]) Fail("the lane in memory", in_model, v[l]);
      }
    }

    // ---- 3. a write disturbs nothing beside it
    {
      unsigned base = RESERVED_BASE + CFG_OFF + 0x0003C000u;
      unsigned v = 0xFACEB00Cu;
      Access(true, base + 8, v, nullptr);  // lane 2 of the block
      for (int l = 0; l < 4; ++l) {
        unsigned got = Peek(base + 4 * l);
        unsigned want = l == 2 ? v : Poison(base + 4 * l);
        if (got != want) Fail("a neighboring lane", got, want);
        ++neighbours_checked;
      }
      // ...and the blocks either side are untouched, which is what a dropped
      // address bit would show.
      for (int d = -16; d <= 16; d += 32) {
        unsigned a = base + 8 + d;
        unsigned got = Peek(a);
        if (got != Poison(a)) Fail("a neighboring block", got, Poison(a));
        ++neighbours_checked;
      }
    }

    // ---- 4. an address outside the reservation is refused, not wrapped
    {
      unsigned outside = 0x10000000u;  // below the map's base
      unsigned got = 0;
      bool err = Access(false, outside, 0, &got);
      if (!err) {
        std::fprintf(stderr,
                     "FAIL: ns %ld: a read outside the reservation was not "
                     "refused\n", ps);
        ++bad;
      }
      if (got != 0) Fail("the word a refused read gave", got, 0);
      err = Access(true, outside, 0xDEADBEEFu, nullptr);
      if (!err) {
        std::fprintf(stderr,
                     "FAIL: ns %ld: a write outside the reservation was not "
                     "refused\n", ps);
        ++bad;
      }
      refused += 2;
    }

    // ---- 5. the debugger's window
    {
      unsigned base = RESERVED_BASE + CFG_OFF + 0x00051000u;
      bool err = false;
      // Four lanes again, through the window this time: the host's own poison
      // is what makes a collapsed lane select visible from this side too.
      unsigned v[4] = {0xA1B2C3D4u, 0xE5F60718u, 0x293A4B5Cu, 0x6D7E8F90u};
      for (int l = 0; l < 4; ++l) {
        WindowAccess(true, base + 4 * l, v[l], &err);
        ++window_ops;
      }
      for (int l = 0; l < 4; ++l) {
        unsigned got = WindowAccess(false, base + 4 * l, 0, &err);
        ++window_ops;
        if (got != v[l]) Fail("the window's read", got, v[l]);
        if (err) {
          std::fprintf(stderr, "FAIL: ns %ld: the window reported an error\n",
                   ps);
          ++bad;
        }
      }
      // ...and the machine sees the same words, which is what says the window
      // and the machine are looking at one memory.
      for (int l = 0; l < 4; ++l) {
        unsigned got = 0;
        Access(false, base + 4 * l, 0, &got);
        if (got != v[l]) Fail("the machine's view of the window's word", got,
                              v[l]);
      }
      // A word the machine wrote, read back through the window.
      Access(true, base + 0x40, 0x0BADF00Du, nullptr);
      unsigned got = WindowAccess(false, base + 0x40, 0, &err);
      ++window_ops;
      if (got != 0x0BADF00Du) Fail("the window's view of the machine's word",
                                   got, 0x0BADF00Du);
    }

    // ---- 6. the two of them at once
    //
    // The machine must win and must still be answered, and the window's own
    // transaction must not take the machine's word or lose its own.
    {
      unsigned ma = RESERVED_BASE + CFG_OFF + 0x00061000u;
      unsigned wa = RESERVED_BASE + CFG_OFF + 0x00062000u;
      Access(true, ma, 0x13579BDFu, nullptr);
      Access(true, wa, 0x2468ACE0u, nullptr);
      for (int k = 0; k < 12; ++k) {
        // **THE CONTROLLER IS TOLD TO TAKE NOTHING FIRST**, which is what makes
        // this a race at all.  A scan takes hundreds of nanoseconds of its own
        // and the window's transaction is over before it ends, so a machine
        // request issued after the scan finds the port free and the two never
        // meet.  Refusing every command holds the window's transaction open
        // until the machine has asked; the refusal is then lifted and both
        // must complete, each with its own word.
        //
        // A race check needs the stimulus that loses the race, and the
        // testbench's convenience speed is the speed at which nothing races.
        dut->hold_cmd = 1;
        unsigned in[5] = {0, 0, 0, 0, 0};
        go_bit ^= 1;
        in[0] = 0;
        in[1] = wa;
        in[2] = ((unsigned)go_bit << 1);
        ScanDr(in);
        // The machine asks while the window owns the port.
        dut->mem_addr = ma;
        dut->mem_wdata = 0;
        dut->mem_write = 0;
        Steps(3);
        dut->mem_req = 1;
        Steps(20 + k * 7);
        dut->hold_cmd = 0;
        long t = 0;
        while (!dut->mem_done) {
          Step();
          if (++t > 20000) {
            std::fprintf(stderr, "FAIL: ns %ld: the machine got no answer "
                                 "under contention\n", ps);
            ++bad;
            break;
          }
        }
        unsigned got = dut->mem_rdata;
        dut->mem_req = 0;
        while (dut->mem_done) Step();
        Steps(2);
        if (got != 0x13579BDFu) Fail("the machine's word under contention", got,
                                     0x13579BDFu);
        Steps(2000);
        Scan s = ScanDr(in);
        if (s.out[0] != 0x2468ACE0u)
          Fail("the window's word under contention", s.out[0], 0x2468ACE0u);
        ++contended;
      }
    }

    // ---- 7. the protocol flags the model raised, if any
    if (dut->viol_addr_align) {
      std::fprintf(stderr,
                   "FAIL: a command named an address that is not a "
                   "sixteen-byte block, or set the rank bit\n");
      ++bad;
    }
    if (dut->viol_wdf_end) {
      std::fprintf(stderr, "FAIL: a write data beat did not end its burst\n");
      ++bad;
    }
    if (dut->viol_cmd_unstable) {
      std::fprintf(stderr,
                   "FAIL: a command moved while the controller had not taken "
                   "it\n");
      ++bad;
    }
    if (dut->viol_wdata_late) {
      std::fprintf(stderr,
                   "FAIL: write data arrived more than two user clocks after "
                   "its command\n");
      ++bad;
    }

    // ---- 8. the tally
    //
    // It is the one witness on this board that is not on the path the
    // debugger's own words travel, so what it says has to be right.
    {
      unsigned lo = dut->tally & 0xFFFFFFFFu;
      unsigned hi = (unsigned)(dut->tally >> 32);
      if ((lo & 0x80008000u) != 0x00008000u ||
          (hi & 0x80008000u) != 0x00008000u) {
        std::fprintf(stderr,
                     "FAIL: the tally's marker bits read 0x%08x 0x%08x, which "
                     "neither an all-ones nor an all-zeros reading may\n",
                     hi, lo);
        ++bad;
      }
      unsigned answered_reads = lo & 0x7FFFu;
      unsigned answered_writes = (lo >> 16) & 0x7FFFu;
      unsigned asked_reads = hi & 0x7FFFu;
      unsigned asked_writes = (hi >> 16) & 0x7FFFu;
      // **ASKED AND ANSWERED DIFFER BY EXACTLY WHAT WAS REFUSED.**  A request
      // for an address outside the machine's reservation is answered by
      // `cadr_mig_ui` itself and never reaches the controller, so it is asked
      // and not answered --- one read and one write in this run.  Writing the
      // two counts as equal would either fail here or, worse, pass a design
      // that had stopped refusing anything.
      if (asked_reads != answered_reads + 1)
        Fail("the tally's reads", answered_reads + 1, asked_reads);
      if (asked_writes != answered_writes + 1)
        Fail("the tally's writes", answered_writes + 1, asked_writes);
      if (asked_reads == 0 || asked_writes == 0) {
        std::fprintf(stderr, "FAIL: the tally counted nothing\n");
        ++bad;
      }
    }

    // ---- 9. the disk pack face's master and the soft system's window
    //
    // After the tally, because the refused move below asks for 260 words the
    // controller never sees, and the tally's arithmetic above is about the
    // refusals it already knows.
    const unsigned A1 = 0x1C800000u + CFG_OFF;  // 128-byte aligned, as the face demands
    const unsigned A2 = A1 + 0x800u;
    const unsigned SLOT = 3u + (unsigned)cfg;
    const unsigned TAG = 0x00ABC000u + (unsigned)cfg;
    {
      if (PackRead(PS_IDENT) != PACK_IDENT)
        Fail("the disk pack face's IDENT", PackRead(PS_IDENT), PACK_IDENT);

      // The record and its pad, through the window, and read back.
      for (unsigned i = 0; i <= REC_WORDS; ++i)
        Win(true, A1 + 4u * i, RecWord(A1, i, cfg));
      for (unsigned i = 0; i <= REC_WORDS; ++i) {
        unsigned got = Win(false, A1 + 4u * i, 0);
        if (got != RecWord(A1, i, cfg))
          Fail("the window's read of a word it wrote", got, RecWord(A1, i, cfg));
        ++soc_window_words;
      }

      // **THE FACE FETCHES IT, AND THE STORE IS READ DIRECTLY.**
      unsigned st = PackMove(CTL_FETCH, A1, TAG, SLOT);
      if ((st & (ST_BUSY | ST_DONE | ST_ERROR | ST_REFUSED)) != ST_DONE)
        Fail("the status of a fetch of a record the window wrote", st, ST_DONE);
      ++pack_moves;
      for (unsigned i = 0; i < REC_WORDS; ++i) {
        unsigned got = StorePeek(SLOT, i);
        if (got != RecWord(A1, i, cfg))
          Fail("a place of the slot the face filled", got, RecWord(A1, i, cfg));
        ++store_checked;
      }
      if (StorePeek(SLOT, REC_WORDS) != TAG)
        Fail("the tag the face wrote last", StorePeek(SLOT, REC_WORDS), TAG);

      // **AND THE WINDOW READS WHAT THE FACE WROTE BACK**, into an area the
      // window poisoned first.
      for (unsigned i = 0; i <= REC_WORDS; ++i)
        Win(true, A2 + 4u * i, RecPoison(A2 + 4u * i));
      st = PackMove(CTL_WRITE, A2, 0, SLOT);
      if ((st & (ST_BUSY | ST_DONE | ST_ERROR | ST_REFUSED)) != ST_DONE)
        Fail("the status of a write-back", st, ST_DONE);
      ++pack_moves;
      for (unsigned i = 0; i < REC_WORDS; ++i) {
        unsigned got = Win(false, A2 + 4u * i, 0);
        if (got != RecWord(A1, i, cfg))
          Fail("a word the face wrote back, through the window", got,
               RecWord(A1, i, cfg));
        unsigned in_model = Peek(A2 + 4u * i);
        if (in_model != RecWord(A1, i, cfg))
          Fail("a word the face wrote back, in the memory", in_model,
               RecWord(A1, i, cfg));
        ++backs_checked;
      }
      unsigned pad = Win(false, A2 + 4u * REC_WORDS, 0);
      if (pad != RecPoison(A2 + 4u * REC_WORDS))
        Fail("the pad after a written-back record", pad,
             RecPoison(A2 + 4u * REC_WORDS));

      // **A RECORD OUTSIDE THE MACHINE'S RESERVATION FAILS ITS MOVE.**
      st = PackMove(CTL_FETCH, 0x10000000u, TAG, SLOT + 8u);
      if (!(st & ST_ERROR) || (st & ST_BUSY)) {
        std::fprintf(stderr, "FAIL: ns %ld: a fetch from outside the "
                             "reservation ended with status 0x%x and no "
                             "error\n", ps, st);
        ++bad;
      }
      ++refused_moves;
    }

    // ---- 10. the machine first, held to a number
    {
      GrowthRun quiet = RunGrowth(false, cfg, A1, A2, SLOT, TAG);
      GrowthRun busy = RunGrowth(true, cfg, A1, A2, SLOT, TAG);
      if (quiet.lat.size() != busy.lat.size() || quiet.lat.empty()) {
        std::fprintf(stderr, "FAIL: the two growth runs made %zu and %zu "
                             "machine accesses\n", quiet.lat.size(),
                     busy.lat.size());
        ++bad;
      } else {
        long longest_quiet = 0;
        for (long l : quiet.lat) longest_quiet = l > longest_quiet ? l : longest_quiet;
        long bound = longest_quiet + kHandover;
        long worst = 0;
        size_t worst_at = 0;
        for (size_t i = 0; i < quiet.lat.size(); ++i) {
          long grew = busy.lat[i] - quiet.lat[i];
          if (grew > worst) {
            worst = grew;
            worst_at = i;
          }
        }
        std::printf("    ratio %d: the machine's longest quiet access %ld "
                    "ticks; the worst grew %ld at access %zu (%ld quiet, %ld "
                    "busy); %ld of %zu asked while another master had the "
                    "port\n", cfg, longest_quiet, worst, worst_at,
                    quiet.lat[worst_at], busy.lat[worst_at], busy.collisions,
                    busy.lat.size());
        if (worst > bound) {
          std::fprintf(stderr,
                       "FAIL: machine access %zu is %ld ticks with the face "
                       "and the window streaming and %ld with them idle, %ld "
                       "more than the %ld one access may cost it\n",
                       worst_at, busy.lat[worst_at], quiet.lat[worst_at], worst,
                       bound);
          ++bad;
        }
        if (busy.collisions < 8) {
          std::fprintf(stderr,
                       "FAIL: only %ld of the machine's accesses were asked "
                       "while another master had the port, so the bound tested "
                       "almost nothing\n", busy.collisions);
          ++bad;
        }
        if (busy.pack_moves < 2 || busy.window_words < 64) {
          std::fprintf(stderr,
                       "FAIL: the busy run had the face finish %ld moves and "
                       "the window move %ld words: not streaming\n",
                       busy.pack_moves, busy.window_words);
          ++bad;
        }
        if (quiet.answers[2] || quiet.answers[3]) {
          std::fprintf(stderr, "FAIL: the quiet run answered the face or the "
                               "window\n");
          ++bad;
        }
        if (worst > worst_growth) worst_growth = worst;
        bound_used = bound;
        collisions += busy.collisions;
        growth_accesses += (long)busy.lat.size();
        pack_moves += busy.pack_moves;
        soc_window_words += busy.window_words;
      }
      // And what streamed has to have landed: the slot the face kept
      // fetching, and the area it kept writing back to.
      for (unsigned i = 0; i < REC_WORDS; ++i)
        if (StorePeek(SLOT, i) != RecWord(A1, i, cfg))
          Fail("a place of the slot after the growth run", StorePeek(SLOT, i),
               RecWord(A1, i, cfg));
      for (unsigned i = 0; i < REC_WORDS; i += 37)
        if (Peek(A2 + 4u * i) != RecWord(A1, i, cfg))
          Fail("a written-back word after the growth run", Peek(A2 + 4u * i),
               RecWord(A1, i, cfg));
    }
  }

  if (bad) {
    std::fprintf(stderr, "FAIL: %d disagreement(s)\n", bad);
    return 1;
  }

  const struct {
    const char *what;
    long n;
  } want[] = {{"writes", writes},
              {"reads", reads},
              {"reads matched against an earlier write", reads_checked},
              {"lanes of one block read back", lanes_checked},
              {"neighbors found untouched", neighbours_checked},
              {"addresses outside the reservation refused", refused},
              {"transactions through the debugger's window", window_ops},
              {"contended pairs", contended},
              {"transactions the controller refused a command on", stalled_cmd},
              {"transactions the controller refused write data on",
               stalled_wdata},
              {"places of a slot read straight out of the store", store_checked},
              {"words the face wrote back, read", backs_checked},
              {"words through the soft system's window", soc_window_words},
              {"moves the disk pack face finished", pack_moves},
              {"moves refused for an address outside the reservation",
               refused_moves},
              {"machine accesses timed twice", growth_accesses},
              {"machine accesses asked while another master had the port",
               collisions}};
  for (const auto &w : want)
    if (w.n == 0) {
      std::fprintf(stderr, "FAIL: the run has no %s\n", w.what);
      return 1;
    }

  std::printf(
      "ok: the A7's memory path agrees with a model of the controller\n"
      "    two clock ratios, 100 MHz against 83.3 and 71.4\n"
      "    %ld writes and %ld reads, %ld of them matched against a write\n"
      "    %ld lanes of a block and %ld neighbors, all where they belong\n"
      "    %ld addresses outside the reservation refused with a zero word\n"
      "    %ld transactions through the debugger's window, %ld contended\n"
      "    %ld waited on a refused command and %ld on refused write data\n"
      "    the controller's protocol held at every tick: aligned blocks, a\n"
      "    burst that ends, a command held until taken, data never late\n"
      "    the disk pack face fetched %ld places read straight out of its store\n"
      "    and wrote back %ld words the window read, %ld moves in all, %ld\n"
      "    refused outside the reservation; %ld words through the window\n"
      "    and the machine first: %ld accesses timed twice, %ld of them asked\n"
      "    while another master had the port, the worst grew %ld ticks\n"
      "    against a bound of %ld, one access\n",
      writes, reads, reads_checked, lanes_checked, neighbours_checked, refused,
      window_ops, contended, stalled_cmd, stalled_wdata, store_checked,
      backs_checked, pack_moves, refused_moves, soc_window_words,
      growth_accesses, collisions, worst_growth, bound_used);
  return 0;
}
