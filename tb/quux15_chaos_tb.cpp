// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Holds rtl/machine/quux15_chaos.sv, revision 15's Chaosnet interface, to
// muir's `chaos::board::Interface` over the script `golden/src/quux15_chaos.rs`
// writes: reads and writes of words 140-147, RESET-DEVICES, and what the
// cable did between them.
//
// A read is one clock, the clock it lands in: its word is the module's
// `rd_word` in that clock, before the edge, and its effect is made at the
// edge.  A write is one clock.  The far end's frame is its words on
// `chaos_rx_word` a clock each and then `chaos_rx_done`, as
// `cadr_chaos_cable.sv` streams one; a lost frame, Transmit Done and the
// cable's busy level are one clock of their wires, the level held after.
// After each line the interrupt, `irq` with the inputs idle and `irq_state`
// after one more idle clock, must be muir's; and in a write's own clock
// `irq`, the interrupt as the write leaves it.  At every clock, Receive Done
// down must find the incoming buffer's pointer at 0 and no read taken: the
// module leaves the pointer alone at a commit on that ground.  After a START the frame it
// sent must come out whole, `chaos_tx_go` with its length at the read's
// edge and its words a clock each after.  Nothing here keeps a model of the
// interface.

#include <cinttypes>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sstream>
#include <string>
#include <vector>

#include "Vquux15_chaos.h"
#include "Vquux15_chaos___024root.h"
#include "verilated.h"

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  const char *path = (argc > 1) ? argv[1] : "build/quux15_chaos.quux.golden";
  std::FILE *f = std::fopen(path, "r");
  if (!f) {
    std::fprintf(stderr, "cannot read %s\n", path);
    return 2;
  }
  auto *dut = new Vquux15_chaos;
  bool busy = false;
  auto idle = [&]() {
    dut->dev_reset = 0;
    dut->rd = 0;
    dut->wr = 0;
    // Poison on the selects and the data lines when nothing reads or writes.
    dut->rd_k = 2;
    dut->wr_k = 1;
    dut->wdata = 0xdead;
    dut->chaos_address = 0177001;
    dut->chaos_rx_valid = 0;
    dut->chaos_rx_word = 0xbeef;
    dut->chaos_rx_done = 0;
    dut->chaos_rx_bits = 0x1fff;
    dut->chaos_rx_crc = 0;
    dut->chaos_rx_lost = 0;
    dut->chaos_tx_done = 0;
    dut->chaos_tx_abort = 1;
    dut->chaos_cbl_busy = busy;
  };
  // The frame the module is sending: its length at START and its words.
  long tx_len = -1;
  std::vector<unsigned> tx_words;
  long stray = 0, unread = 0;
  auto tick = [&]() {
    dut->clk = 0;
    dut->eval();
    dut->clk = 1;
    dut->eval();
    // **WITH RECEIVE DONE DOWN THE POINTER IS 0 AND NO READ IS TAKEN**,
    // which is why a commit leaves the pointer where it is.
    const auto *r = dut->rootp;
    if (!dut->rst && !r->quux15_chaos__DOT__ch_rdone &&
        (r->quux15_chaos__DOT__ch_rat != 0 || r->quux15_chaos__DOT__ch_read != 0))
      ++unread;
    if (dut->chaos_tx_go) {
      tx_len = dut->chaos_tx_len;
      tx_words.clear();
    }
    if (dut->chaos_tx_valid) {
      if (tx_len < 0) ++stray;
      tx_words.push_back(dut->chaos_tx_word);
    }
  };
  idle();
  dut->rst = 1;
  tick();
  tick();
  dut->rst = 0;
  tick();
  char line[8192];
  long rows = 0, bad = 0, reads = 0, writes = 0, frames = 0, losts = 0, dones = 0, sends = 0, resets = 0;
  long irq_up = 0, busy_rows = 0;
  auto fail = [&](const char *what, uint64_t got, uint64_t want) {
    if (bad < 20)
      std::fprintf(stderr, "row %ld: %s is %" PRIx64 ", muir has %" PRIx64 "\n", rows, what, got, want);
    ++bad;
  };
  auto irq_check = [&](unsigned irq) {
    idle();
    dut->eval();
    if (dut->irq != irq) fail("the interrupt", dut->irq, irq);
    tick();
    dut->eval();
    if (dut->irq_state != irq) fail("the interrupt as the clock began", dut->irq_state, irq);
    if (irq) ++irq_up;
  };
  while (std::fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    ++rows;
    std::istringstream in(line);
    std::string op;
    in >> op;
    std::vector<unsigned> v;
    unsigned x;
    while (in >> std::hex >> x) v.push_back(x);
    idle();
    if (op == "r" && v.size() == 3) {
      dut->rd = 1;
      dut->rd_k = v[0] - 0140;
      dut->eval();
      if (dut->rd_word != v[1]) fail("a read", dut->rd_word, v[1]);
      tick();
      ++reads;
      irq_check(v[2]);
    } else if (op == "w" && v.size() == 3) {
      dut->wr = 1;
      dut->wr_k = v[0] - 0140;
      dut->wdata = v[1];
      // A write of a word above 147 is the trace's mistake.
      if (v[0] < 0140 || v[0] > 0147) fail("a write's word", v[0], 0140);
      // The interrupt as the write leaves it, in the write's own clock.
      dut->eval();
      if (dut->irq != v[2]) fail("the interrupt in the write's clock", dut->irq, v[2]);
      tick();
      ++writes;
      irq_check(v[2]);
    } else if (op == "x" && v.size() == 1) {
      dut->dev_reset = 1;
      dut->eval();
      if (dut->irq != v[0]) fail("the interrupt in RESET-DEVICES's clock", dut->irq, v[0]);
      tick();
      ++resets;
      irq_check(v[0]);
    } else if (op == "f" && v.size() >= 4 && v.size() == 4 + v[2]) {
      // The frame's length is on `chaos_rx_bits` from its first word to its
      // done, as `cadr_chaos_cable.sv` holds it: the card places each word
      // by it as it comes.
      for (unsigned j = 0; j < v[2]; ++j) {
        idle();
        dut->chaos_rx_valid = 1;
        dut->chaos_rx_word = v[3 + j];
        dut->chaos_rx_bits = v[0];
        tick();
      }
      idle();
      dut->chaos_rx_done = 1;
      dut->chaos_rx_bits = v[0];
      dut->chaos_rx_crc = v[1];
      tick();
      ++frames;
      irq_check(v.back());
    } else if (op == "l" && v.size() == 1) {
      dut->chaos_rx_lost = 1;
      tick();
      ++losts;
      irq_check(v[0]);
    } else if (op == "d" && v.size() == 2) {
      dut->chaos_tx_done = 1;
      dut->chaos_tx_abort = v[0];
      tick();
      ++dones;
      irq_check(v[1]);
    } else if (op == "b" && v.size() == 1) {
      busy = v[0] != 0;
      busy_rows += busy;
      idle();
      tick();
    } else if (op == "s" && v.size() == 1 + v[0]) {
      // The START just read: its frame out, a word a clock.
      for (unsigned j = 0; j < v[0] + 2; ++j) {
        idle();
        tick();
      }
      if (tx_len != static_cast<long>(v[0])) fail("the frame START sent, its length", tx_len, v[0]);
      if (tx_words.size() != v[0]) fail("the frame START sent, its words out", tx_words.size(), v[0]);
      for (unsigned j = 0; j < v[0] && j < tx_words.size(); ++j)
        if (tx_words[j] != v[1 + j]) fail("a word of the frame START sent", tx_words[j], v[1 + j]);
      tx_len = -1;
      tx_words.clear();
      ++sends;
    } else {
      std::fprintf(stderr, "%s: cannot read row %ld: %s", path, rows, line);
      return 2;
    }
  }
  std::fclose(f);

  // **A CLEAR RECEIVER OR A RESET WHILE A FRAME STREAMS IN DROPS THE REST OF
  // THE STREAM AND ITS DONE** (`cadr_io_board.sv` has the netlist's
  // account): no Receive Done, no Lost Count, CRC Error down, the bit count
  // and the buffer reading 0, and the next frame lands whole.  Not in muir's
  // script, where a frame is one row and nothing lands inside it.  The far
  // end leaves its stream, with no done, one clock after `chaos_reset`, as
  // `cadr_chaos_cable.sv` does.  The command lands with the first word, the
  // second, one in the middle, the last, and in the idle clock before the
  // done.
  {
    const unsigned N = 40;
    auto dfail = [&](const char *what, uint64_t got, uint64_t want) {
      if (bad < 20) std::fprintf(stderr, "%s is %" PRIx64 ", wanting %" PRIx64 "\n", what, got, want);
      ++bad;
    };
    auto word = [](unsigned j) { return (0100000u | (j * 0421u)) & 0xffffu; };
    auto rd1 = [&](unsigned k) {
      idle();
      dut->rd = 1;
      dut->rd_k = k;
      dut->eval();
      const unsigned w = dut->rd_word;
      tick();
      return w;
    };
    auto wr1 = [&](unsigned k, unsigned v) {
      idle();
      dut->wr = 1;
      dut->wr_k = k;
      dut->wdata = v;
      tick();
    };
    // A frame of N words, and the command in the clock of word `at` (N: the
    // idle clock before the done; N + 1: the done's; ~0u: none), and a Reset
    // in the clock of word `at2` after it.
    auto stream = [&](unsigned at, int how, unsigned at2 = ~0u) {
      bool leaving = false, gone = false;
      for (unsigned j = 0; j <= N && !gone; ++j) {
        idle();
        if (j < N) {
          dut->chaos_rx_valid = 1;
          dut->chaos_rx_word = word(j);
        }
        dut->chaos_rx_bits = N * 16;
        if (j == at) {
          if (how == 2) {
            dut->dev_reset = 1;
          } else {
            dut->wr = 1;
            dut->wr_k = 0;
            dut->wdata = how == 0 ? 010u : 020000u;
          }
        }
        if (j == at2) {
          dut->wr = 1;
          dut->wr_k = 0;
          dut->wdata = 020000u;
        }
        tick();
        if (leaving) gone = true;
        if (dut->chaos_reset) leaving = true;
      }
      if (!gone) {
        idle();
        dut->chaos_rx_done = 1;
        dut->chaos_rx_bits = N * 16;
        if (at == N + 1) {
          if (how == 2) {
            dut->dev_reset = 1;
          } else {
            dut->wr = 1;
            dut->wr_k = 0;
            dut->wdata = how == 0 ? 010u : 020000u;
          }
        }
        tick();
      }
    };
    const char *hows[] = {"Clear Receiver", "Reset", "RESET-DEVICES", "Clear Receiver, then Reset,"};
    long drops = 0;
    for (int how = 0; how < 4; ++how) {
      for (unsigned at : {0u, 1u, N / 2, N - 1, N, N + 1}) {
        if (how == 3 && at >= N - 1) continue;
        const long before = bad;
        wr1(0, 010u);
        // The fourth: a Reset after a drop began ends it, the stream gone
        // with no done.
        if (how == 3) stream(at, 0, at + 1);
        else stream(at, how);
        const unsigned csr = rd1(0);
        if (csr & 0177000u) dfail("the CSR's Receive Done, CRC Error and Lost Count after a drop", csr, csr & ~0177000u);
        const unsigned bits = rd1(3);
        if (bits != 0u) dfail("the bit count after a drop", bits, 0);
        unsigned nonzero = 0;
        for (unsigned j = 0; j < N; ++j)
          if (rd1(2) != 0u) ++nonzero;
        if (nonzero) dfail("buffer reads that were not 0 after a drop", nonzero, 0);
        // The next frame lands whole.
        stream(~0u, 0);
        const unsigned next = rd1(0);
        if (!(next & 0100000u)) dfail("Receive Done for the frame after a drop", next, next | 0100000u);
        if (next & 017000u) dfail("Lost Count with the frame after a drop", (next & 017000u) >> 9, 0);
        if (rd1(3) != N * 16 - 1) dfail("the bit count of the frame after a drop", rd1(3), N * 16 - 1);
        unsigned wrong = 0;
        for (unsigned j = 0; j < N; ++j)
          if (rd1(2) != word(j)) ++wrong;
        if (wrong) dfail("words of the frame after a drop that landed garbled", wrong, 0);
        if (bad != before) std::fprintf(stderr, "  (that was %s in the clock of word %u)\n", hows[how], at);
        ++drops;
      }
    }
    wr1(0, 010u);
    if (!bad) std::printf("ok: %ld clears and resets mid-stream dropped the rest of the stream and its done\n", drops);
  }

  if (stray) fail("words sent with no START", stray, 0);
  if (unread) fail("clocks with Receive Done down and the pointer not 0 or a read taken", unread, 0);
  if (!bad && (reads == 0 || frames == 0 || losts == 0 || dones == 0 || sends == 0 || resets == 0 ||
               irq_up == 0 || busy_rows == 0)) {
    std::fprintf(stderr, "FAIL: the script reached too little: %ld reads, %ld frames in, %ld lost, %ld Transmit "
                 "Dones, %ld STARTs, %ld RESET-DEVICES, %ld rows interrupting, %ld busy\n",
                 reads, frames, losts, dones, sends, resets, irq_up, busy_rows);
    return 1;
  }
  if (bad) {
    std::fprintf(stderr, "FAIL: %ld mismatches over %ld rows\n", bad, rows);
    return 1;
  }
  std::printf("ok: %ld rows agree with muir's chaos::board::Interface on revision 15's Chaosnet interface: "
              "%ld reads, %ld writes, %ld frames in, %ld lost, %ld Transmit Dones, %ld frames sent, "
              "%ld RESET-DEVICES, %ld rows interrupting\n",
              rows, reads, writes, frames, losts, dones, sends, resets, irq_up);
  delete dut;
  return 0;
}
