// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Chaosnet cable's register face, alone, against the order in which
// `chaos_face.c` really drives it.
//
// `gp0_split` drives this face through the splitter and the card together,
// one frame at a time, which is what shows the seam carries the right words.
// What it cannot show is what happens when two of the program's calls overlap
// the cable's own work, because nothing there overlaps.  This does, and each
// case below is a way the face went wrong:
//
//   - A give whose `RXLEN` write landed while the previous commit was still
//     streaming changed the length of the frame on the wire.  The stream read
//     `RXLEN` live, both for where to stop and for the bit count it hands the
//     card, so a second give of 11 words right behind a commit of 255 cut the
//     first frame short and gave the card a bit count of 176.  The length is
//     now taken at the commit.
//   - A commit of no words, or of more than the buffer holds, was counted in
//     `LOST` and on the card's own Lost Count, which are the frames the
//     machine had no room for.  It is now ignored and counted nowhere.
//   - Taking a frame was not tied to which frame the program had read: if the
//     machine cleared its transmitter and started a new frame while the
//     program was reading the old one, the program's take dropped the new one
//     and let the machine believe it had gone.  A take now counts only for a
//     frame whose `TXLEN` was read after it arrived.
//   - `LOST` survives the card's own Reset and is cleared by this module's
//     reset input, which is what the header now says.
//   - Transmit Abort was held low, so the machine's own frame to its own
//     address into a full buffer came back as a plain Transmit Done, where
//     the board's busy receiver aborts it.  A take with `CTL` bit 3 now
//     raises it on the take's Transmit Done, and only there.
//
// And the frame the card sends is the frame as it goes on the cable, the
// source and the check word in it, which this face offers as it comes; one
// of three words or fewer, 48 bits that no receiver takes, is not offered at
// all and the machine is let go at once.
//
// The card is modeled only as far as this face sees it: its Receive Done is
// raised on `chaos_rx_done` and dropped when the test says the machine has
// read the frame out, and its transmitter is driven directly.

#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>

#include "Vcadr_chaos_cable.h"
#include "verilated.h"

namespace {

Vcadr_chaos_cable *t;
long tick = 0;
int bad = 0;

// What the card saw, counted on every tick.
long rx_valid_n = 0, rx_done_n = 0, rx_lost_n = 0, tx_done_n = 0;
// Transmit Done with Transmit Abort, and Transmit Abort on any other tick.
long tx_abort_n = 0, abort_alone_n = 0;
long bits_at_done = -1;
std::vector<unsigned> streamed;
bool card_rdone = false;

// The card's transmitter, played out by `Step` so that the program's reads
// can overlap it: START, then one word a tick from the tick after.
std::vector<unsigned> tx_queue;
bool tx_go_due = false;
unsigned tx_at = 0;

enum { STAT = 1, TXLEN = 3, RXLEN = 4, CTL = 5, LOST = 6 };
const unsigned TX_WIN = 0x400, RX_WIN = 0x800;

void Fail(const char *what, long got, long want) {
  std::fprintf(stderr, "tick %ld: %s is %ld, expected %ld\n", tick, what, got, want);
  ++bad;
}

void Step() {
  t->chaos_csr = card_rdone ? 0x8000u : 0u;
  t->chaos_tx_go = 0;
  t->chaos_tx_valid = 0;
  if (tx_go_due) {
    t->chaos_tx_go = 1;
    t->chaos_tx_len = tx_queue.size();
    tx_go_due = false;
    tx_at = 0;
  } else if (tx_at < tx_queue.size()) {
    t->chaos_tx_valid = 1;
    t->chaos_tx_word = tx_queue[tx_at++];
  }
  t->clk = 0;
  t->eval();
  if (t->chaos_rx_valid) {
    ++rx_valid_n;
    streamed.push_back(t->chaos_rx_word);
  }
  if (t->chaos_rx_done) {
    ++rx_done_n;
    bits_at_done = t->chaos_rx_bits;
    card_rdone = true;
  }
  if (t->chaos_rx_lost) ++rx_lost_n;
  if (t->chaos_tx_done) ++tx_done_n;
  if (t->chaos_tx_done && t->chaos_tx_abort) ++tx_abort_n;
  if (!t->chaos_tx_done && t->chaos_tx_abort) ++abort_alone_n;
  t->clk = 1;
  t->eval();
  ++tick;
}

void Idle(int n) { for (int i = 0; i < n; ++i) Step(); }

void Write(unsigned a, unsigned d) {
  t->s_awaddr = a; t->s_awvalid = 1; t->s_awlen = 0; t->s_awid = 0;
  for (;;) { t->eval(); bool h = t->s_awready; Step(); if (h) break; }
  t->s_awvalid = 0;
  t->s_wdata = d; t->s_wstrb = 0xF; t->s_wlast = 1; t->s_wvalid = 1;
  for (;;) { t->eval(); bool h = t->s_wready; Step(); if (h) break; }
  t->s_wvalid = 0;
  t->s_bready = 1;
  for (;;) { t->eval(); bool h = t->s_bvalid; Step(); if (h) break; }
  t->s_bready = 0;
}

unsigned Read(unsigned a) {
  t->s_araddr = a; t->s_arvalid = 1; t->s_arlen = 0; t->s_arid = 0;
  for (;;) { t->eval(); bool h = t->s_arready; Step(); if (h) break; }
  t->s_arvalid = 0;
  t->s_rready = 1;
  unsigned v = 0;
  for (;;) { t->eval(); bool h = t->s_rvalid; v = t->s_rdata; Step(); if (h) break; }
  t->s_rready = 0;
  return v;
}

unsigned Reg(unsigned r) { return Read(4 * r); }
void SetReg(unsigned r, unsigned v) { Write(4 * r, v); }

void Reset() {
  t->rst = 1;
  Idle(4);
  t->rst = 0;
  Idle(1);
  card_rdone = false;
}

void Clear() {
  rx_valid_n = rx_done_n = rx_lost_n = tx_done_n = 0;
  tx_abort_n = abort_alone_n = 0;
  bits_at_done = -1;
  streamed.clear();
}

// Words the RX window is filled with for frame `tag`.
unsigned Word(unsigned tag, unsigned k) { return (tag << 12 | k) & 0xFFFFu; }

void Fill(unsigned tag, unsigned n) {
  for (unsigned k = 0; k < n; ++k) Write(RX_WIN + 4 * k, Word(tag, k));
}

// The frame the card was handed, against the frame that was committed.
void Expect(const char *what, unsigned tag, unsigned n) {
  if (rx_done_n != 1) Fail((std::string(what) + ": chaos_rx_done pulses").c_str(), rx_done_n, 1);
  if (rx_valid_n != static_cast<long>(n))
    Fail((std::string(what) + ": chaos_rx_valid pulses").c_str(), rx_valid_n, n);
  if (bits_at_done != static_cast<long>(n) * 16)
    Fail((std::string(what) + ": chaos_rx_bits at the done").c_str(), bits_at_done, n * 16);
  for (unsigned k = 0; k < streamed.size() && k < n; ++k)
    if (streamed[k] != Word(tag, k)) {
      Fail((std::string(what) + ": a word the card was handed").c_str(), streamed[k], Word(tag, k));
      break;
    }
}

// A commit of `n` words already in the window, as `chaos_face_give` makes it.
void Commit(unsigned n) {
  SetReg(RXLEN, n);
  SetReg(CTL, 2);
}

}  // namespace

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  t = new Vcadr_chaos_cable;
  t->chaos_tx_go = 0; t->chaos_tx_len = 0; t->chaos_tx_valid = 0; t->chaos_tx_word = 0;
  t->chaos_tx_clear = 0; t->chaos_reset = 0;
  t->s_awvalid = 0; t->s_wvalid = 0; t->s_bready = 0; t->s_arvalid = 0; t->s_rready = 0;
  long cases = 0;

  // ====================================================================
  // THE LENGTH IS TAKEN AT THE COMMIT
  // ====================================================================
  // A control first: one give of 255 words with nothing behind it.
  Reset(); Clear();
  Fill(1, 255);
  Commit(255);
  Idle(400);
  Expect("one give of 255", 1, 255);
  ++cases;

  // Then a second give right behind it, in `chaos_face_give`'s own order:
  // STAT, LOST, the window, RXLEN, CTL.  The machine has not read the first
  // frame out, so the second is refused --- and the first must go to the
  // card whole whatever the second one's RXLEN write did to the register.
  for (unsigned n2 : {11u, 1u, 200u, 0u, 300u}) {
    Reset(); Clear();
    Fill(1, 255);
    Commit(255);
    (void)Reg(STAT);
    (void)Reg(LOST);
    Fill(2, n2 < 256 ? n2 : 4);
    SetReg(RXLEN, n2);
    SetReg(CTL, 2);
    Idle(600);
    char what[80];
    std::snprintf(what, sizeof what, "255 words, then a give of %u behind them", n2);
    Expect(what, 1, 255);
    ++cases;
  }

  // RXLEN written at every offset into a stream, and the discard command
  // too: neither may reach the frame already on its way.
  for (int at = 0; at < 40; at += 3) {
    for (int discard = 0; discard < 2; ++discard) {
      Reset(); Clear();
      Fill(3, 30);
      Commit(30);
      Idle(at);
      if (discard) SetReg(CTL, 4);
      else SetReg(RXLEN, 5 + at);
      Idle(100);
      char what[80];
      std::snprintf(what, sizeof what, "%s %d ticks into a stream of 30",
                    discard ? "the discard" : "an RXLEN write", at);
      Expect(what, 3, 30);
      ++cases;
    }
  }

  // ====================================================================
  // A MALFORMED COMMIT IS IGNORED, NOT COUNTED AS A LOST FRAME
  // ====================================================================
  for (unsigned n : {0u, 257u, 511u}) {
    Reset(); Clear();
    Fill(4, 8);
    const unsigned before = Reg(LOST);
    Commit(n);
    Idle(20);
    char what[80];
    std::snprintf(what, sizeof what, "LOST after a commit of %u words", n);
    if (Reg(LOST) != before) Fail(what, Reg(LOST), before);
    std::snprintf(what, sizeof what, "the card's lost strobe for a commit of %u words", n);
    if (rx_lost_n != 0) Fail(what, rx_lost_n, 0);
    std::snprintf(what, sizeof what, "words streamed for a commit of %u words", n);
    if (rx_valid_n != 0 || rx_done_n != 0) Fail(what, rx_valid_n, 0);
    ++cases;
  }
  // And the boundaries that ARE frames still go: 1 and 256.
  for (unsigned n : {1u, 256u}) {
    Reset(); Clear();
    Fill(5, n);
    Commit(n);
    Idle(400);
    char what[80];
    std::snprintf(what, sizeof what, "a commit of %u words", n);
    Expect(what, 5, n);
    if (Reg(LOST) != 0) Fail("LOST after a frame that was stored", Reg(LOST), 0);
    ++cases;
  }
  // A commit refused because the buffer is busy IS still a lost frame, on
  // both counts: that is what the malformed case must not be confused with.
  {
    Reset(); Clear();
    card_rdone = true;
    Fill(6, 10);
    Commit(10);
    Idle(20);
    if (Reg(LOST) != 1) Fail("LOST for a commit onto a full buffer", Reg(LOST), 1);
    if (rx_lost_n != 1) Fail("the card's lost strobe for a full buffer", rx_lost_n, 1);
    ++cases;
  }

  // ====================================================================
  // LOST SURVIVES THE CARD'S RESET AND NOT THIS MODULE'S
  // ====================================================================
  {
    Reset(); Clear();
    card_rdone = true;
    Fill(6, 10);
    Commit(10);
    Commit(10);
    const unsigned lost = Reg(LOST);
    if (lost != 2) Fail("LOST after two refusals", lost, 2);
    t->chaos_reset = 1; Idle(2); t->chaos_reset = 0; Idle(2);
    if (Reg(LOST) != lost) Fail("LOST across the card's Reset", Reg(LOST), lost);
    Reset();
    if (Reg(LOST) != 0) Fail("LOST across this module's reset input", Reg(LOST), 0);
    ++cases;
  }

  // ====================================================================
  // A TAKE COUNTS ONLY FOR THE FRAME WHOSE LENGTH WAS READ
  // ====================================================================
  // A frame from the machine: queued, and played out by `Step`.
  auto start = [](unsigned tag, unsigned n) {
    tx_queue.clear();
    for (unsigned k = 0; k < n; ++k) tx_queue.push_back(Word(tag, k));
    tx_go_due = true;
    tx_at = n;  // nothing plays until the START tick resets it
  };
  auto transmit = [&](unsigned tag, unsigned n) {
    start(tag, n);
    Idle(n + 6);
  };
  {
    // The ordinary take, as `chaos_face_take` makes it.
    Reset(); Clear();
    transmit(7, 9);
    if (!(Reg(STAT) & 1)) Fail("STAT's TX_VALID after a frame", 0, 1);
    if (Reg(TXLEN) != 9) Fail("TXLEN", Reg(TXLEN), 9);
    for (unsigned k = 0; k < 9; ++k)
      if (Read(TX_WIN + 4 * k) != Word(7, k)) Fail("a word of the TX window", Read(TX_WIN + 4 * k), Word(7, k));
    SetReg(CTL, 1);
    Idle(2);
    if (tx_done_n != 1) Fail("Transmit Done pulses for a take", tx_done_n, 1);
    if (tx_abort_n != 0) Fail("Transmit Abort with the Transmit Done of a plain take", tx_abort_n, 0);
    if (Reg(STAT) & 1) Fail("STAT's TX_VALID after the take", 1, 0);
    ++cases;
  }
  {
    // The race: the program has read frame A's length and is reading its
    // words when the machine clears its transmitter and starts frame B.
    // The take the program then writes is for A, and must not drop B.
    Reset(); Clear();
    transmit(8, 9);
    if (Reg(TXLEN) != 9) Fail("TXLEN of frame A", Reg(TXLEN), 9);
    (void)Read(TX_WIN);
    t->chaos_tx_clear = 1; Step(); t->chaos_tx_clear = 0;
    transmit(9, 5);
    const long done_before = tx_done_n;
    SetReg(CTL, 1);
    Idle(2);
    if (tx_done_n != done_before)
      Fail("Transmit Done pulses for a take of a frame already cleared", tx_done_n - done_before, 0);
    if (!(Reg(STAT) & 1)) Fail("STAT's TX_VALID for frame B after a take meant for A", 0, 1);
    // And B is then taken the ordinary way.
    if (Reg(TXLEN) != 5) Fail("TXLEN of frame B", Reg(TXLEN), 5);
    if (Read(TX_WIN) != Word(9, 0)) Fail("word 0 of frame B", Read(TX_WIN), Word(9, 0));
    SetReg(CTL, 1);
    Idle(2);
    if (tx_done_n != done_before + 1) Fail("Transmit Done pulses for the take of B", tx_done_n - done_before, 1);
    if (Reg(STAT) & 1) Fail("STAT's TX_VALID after B was taken", 1, 0);
    ++cases;
  }

  {
    // And the program polling `TXLEN` while a frame arrives, the poll
    // started at every phase against the frame's last tick: whenever it sees
    // a length, the take that follows must go through, once.  A length read
    // on the very tick the frame arrives is the frame the program was told
    // about, and a take that ignored it would have the machine's frame
    // offered again and sent twice.
    for (int off = 0; off < 16; ++off) {
      Reset(); Clear();
      start(10, 6);
      Idle(off);
      unsigned len = 0;
      for (int i = 0; i < 20 && len == 0; ++i) len = Reg(TXLEN);
      if (len != 6) Fail("TXLEN seen by a poll", len, 6);
      SetReg(CTL, 1);
      Idle(2);
      if (tx_done_n != 1) Fail("Transmit Done pulses for a polled take", tx_done_n, 1);
      if (Reg(STAT) & 1) Fail("STAT's TX_VALID after a polled take", 1, 0);
      ++cases;
    }
  }

  // ====================================================================
  // A FRAME OF 48 BITS OR FEWER IS NOT OFFERED
  // ====================================================================
  // Nothing at all (254 words written), 16 to 48 bits (255 to 257, and an
  // empty START's source and check word): no receiver takes it and CHUDP
  // carries none, and the program, which routes by the third word from the
  // end, must never be handed one of one or two words.  Nothing waits for
  // the program and Transmit Done comes at once.  Four words are a frame
  // and wait.
  for (unsigned n : {0u, 1u, 2u, 3u, 4u}) {
    Reset(); Clear();
    transmit(11, n);
    char what[80];
    std::snprintf(what, sizeof what, "STAT's TX_VALID after a frame of %u words", n);
    if (((Reg(STAT) & 1) != 0) != (n > 3)) Fail(what, Reg(STAT) & 1, n > 3);
    std::snprintf(what, sizeof what, "Transmit Done pulses for a frame of %u words, untaken", n);
    if (tx_done_n != (n > 3 ? 0 : 1)) Fail(what, tx_done_n, n > 3 ? 0 : 1);
    std::snprintf(what, sizeof what, "TXLEN for a frame of %u words", n);
    if (Reg(TXLEN) != (n > 3 ? n : 0)) Fail(what, Reg(TXLEN), n > 3 ? n : 0);
    std::snprintf(what, sizeof what, "Transmit Abort for a frame of %u words", n);
    if (tx_abort_n != 0 || abort_alone_n != 0) Fail(what, tx_abort_n + abort_alone_n, 0);
    ++cases;
  }

  // ====================================================================
  // A TAKE WITH CTL BIT 3 RAISES TRANSMIT ABORT ON ITS TRANSMIT DONE
  // ====================================================================
  // The machine's own frame to its own address, met by its own busy
  // receiver: `chaos_face_let_go` takes it with bit 3, and the card must
  // see Transmit Abort on the tick of that take's Transmit Done and on no
  // other tick.  Bit 3 alone takes nothing, and a take with it that lands
  // on no frame raises nothing.
  {
    Reset(); Clear();
    transmit(12, 11);
    if (Reg(TXLEN) != 11) Fail("TXLEN of the frame to be aborted", Reg(TXLEN), 11);
    SetReg(CTL, 8);
    Idle(2);
    if (tx_done_n != 0) Fail("Transmit Done pulses for CTL bit 3 alone", tx_done_n, 0);
    if (!(Reg(STAT) & 1)) Fail("STAT's TX_VALID after CTL bit 3 alone", 0, 1);
    SetReg(CTL, 1 | 8);
    Idle(2);
    if (tx_done_n != 1) Fail("Transmit Done pulses for an aborted take", tx_done_n, 1);
    if (tx_abort_n != 1) Fail("Transmit Abort with the aborted take's Transmit Done", tx_abort_n, 1);
    if (abort_alone_n != 0) Fail("Transmit Abort on a tick with no Transmit Done", abort_alone_n, 0);
    if (Reg(STAT) & 1) Fail("STAT's TX_VALID after the aborted take", 1, 0);
    // And the next frame, taken plainly, is not aborted.
    transmit(13, 11);
    (void)Reg(TXLEN);
    SetReg(CTL, 1);
    Idle(2);
    if (tx_done_n != 2) Fail("Transmit Done pulses for the plain take after", tx_done_n, 2);
    if (tx_abort_n != 1) Fail("Transmit Abort with the plain take after an aborted one", tx_abort_n, 1);
    // An aborted take with nothing waiting raises neither.
    const long done_was = tx_done_n, abort_was = tx_abort_n;
    SetReg(CTL, 1 | 8);
    Idle(2);
    if (tx_done_n != done_was) Fail("Transmit Done for an aborted take of nothing", tx_done_n - done_was, 0);
    if (tx_abort_n != abort_was || abort_alone_n != 0)
      Fail("Transmit Abort for an aborted take of nothing", tx_abort_n - abort_was + abort_alone_n, 0);
    ++cases;
  }

  t->final();
  delete t;
  if (bad) {
    std::fprintf(stderr, "FAIL: %d problems over %ld cases\n", bad, cases);
    return 1;
  }
  std::printf("ok: %ld cases: the length is taken at the commit, a malformed commit is "
              "counted nowhere, a take counts only for the frame it read, a frame of 48 bits "
              "or fewer is not offered, an aborted take raises Transmit Abort with its Transmit Done\n", cases);
  return 0;
}
