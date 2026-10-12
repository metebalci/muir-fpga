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
// down must find the incoming buffer's pointer and length at 0: the module
// leaves the pointer alone at a commit on that ground.  After a START the frame it
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
    // **WITH RECEIVE DONE DOWN THE POINTER AND THE LENGTH ARE 0**, which is
    // why a commit leaves the pointer where it is.
    const auto *r = dut->rootp;
    if (!dut->rst && !r->quux15_chaos__DOT__ch_rdone &&
        (r->quux15_chaos__DOT__ch_rat != 0 || r->quux15_chaos__DOT__ch_rlen != 0))
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
      for (unsigned j = 0; j < v[2]; ++j) {
        idle();
        dut->chaos_rx_valid = 1;
        dut->chaos_rx_word = v[3 + j];
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
  if (stray) fail("words sent with no START", stray, 0);
  if (unread) fail("clocks with Receive Done down and the pointer or the length not 0", unread, 0);
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
