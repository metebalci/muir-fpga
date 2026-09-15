// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The sending station's end of the seam: a frame the machine's buffer refused
// is held and offered again, as an interface's driver retries on Transmit
// Abort.
//
// **WHY THERE IS ANYTHING HERE AT ALL.**  The interface has ONE incoming
// packet buffer.  A frame given to it while the machine has not read the last
// packet out is refused and counted in `LOST`, which is the four-bit Lost
// Count of AIM-628 §7.  Before this file the program handed such a frame's
// loss to the sender's retransmission and went on to the next one, and a
// burst of frames from one host therefore delivered exactly ONE frame however
// long the burst was --- measured on the build host against a model of the
// fabric, and that measurement is `chaos_test_inject.c`'s first table.
//
// **THE CABLE DID NOT LOSE THOSE FRAMES, AND THIS IS WHAT IT DID INSTEAD.**
// AIM-628 §2.5: "When a receiving interface determines that an incoming
// packet is addressed to it, but its receive buffer already contains a
// packet, it sends an abort signal which causes the transmitter to stop.
// This serves the dual purpose of immediately informing the transmitter that
// its message did not get through, and preventing the ether from being tied
// up while a long packet is transmitted which the receiver cannot receive."
// The sender's interface reads Transmit Abort, and §2.6: "the transmitter
// does not distinguish receiver-busy aborts from real collisions ... we
// recover from it (in software) by retransmitting the packet again a couple
// of times, hoping ... that the receiver will soon clear its packet buffer."
//
// So a refusal at this seam is the hardware's abort, and the hardware's
// answer to an abort is the SENDER'S RETRY.  This program is the cable and
// there is no sender on it to retry --- the station that sent the frame is at
// the far end of a UDP socket and has long since gone on --- so the retry is
// here, standing in for the sending interface exactly as the rest of the
// program stands in for the cable.
//
// ## What the CADR's own driver does, which is what this copies
//
// `ucadr/uc-chaos.lisp`, the transmit interrupt handler:
//
//   - `(ASSIGN CHAOS-NUMBER-TRANSMIT-RETRIES 3)`, "Send once and retry twice
//     if aborted".  So THREE OFFERS IN ALL, which is `CHAOS_INJECT_OFFERS`.
//   - On an abort the retry count is counted down and, at zero, the packet
//     goes to `CHAOS-XMT-DONE` --- MIT's own comment is "Give up".  A frame
//     past the bound is therefore LOST, and counted here rather than
//     retried for ever.
//   - "Note buffer not removed from list until done": the aborted packet
//     stays at the head of the transmit list, so what was queued behind it
//     stays behind it.  muir's CHUDP node does the same thing from the other
//     side --- `Chudp::aborted` pushes the frame to the FRONT of `out`, "A
//     frame aborted on interference goes again at the next turn, ahead of
//     anything that arrived since, as an interface's driver retries on
//     Transmit Abort".  **Order is kept**, and the queue here is that `out`.
//   - Between the abort and the retry the handler exits: "Wait a while, then
//     retransmit".  And the wait is cut short by any wake-up, "this prevents
//     infinite hang if the clock is off".
//
// ## When the retry goes, which is the one place this does better than MIT
//
// MIT waits a while because the sender cannot see the receiver.  This program
// can: the fabric latches `CHAOS_IRQ_RX_FREE` when the machine empties its
// incoming buffer (`chaos_face.h`), so the moment a retry can succeed is a
// bit this program reads.  `chaos_face_rx_freed` reads and CLEARS it, so what
// it answers is an edge since the last call and never a level --- and the bit
// is cleared immediately before every offer, so a drain from before a refusal
// cannot be mistaken for the turn to go again.
//
// **AND IT IS READ RATHER THAN WAITED ON.**  The fabric ORs that bit with the
// other one under `IRQEN` onto the processing system's `IRQ_F2P`, but on this
// board `IRQ_F2P` bit 0 is the disk pack's and the device tree gives Linux no
// interrupt for the Chaosnet interface at all, so there is no line to sleep
// on.  `chaos_inject_pump` therefore reads the register once a turn while a
// frame is held, and not otherwise: a bus cycle a millisecond on a link that
// is waiting, and none at all when nothing is.
//
// The wait is still there, as `CHAOS_INJECT_WAIT_NS`, and it is what makes
// the bound reachable: a machine that never empties its buffer never raises
// that bit, and without a deadline the frame would be held for ever and the
// bound would be an exemption that tests nothing.  MIT's own reason for
// cutting its wait short is the same one in the other direction.
//
// ## What is NOT done here, and was considered
//
// **The frames are not paced to cable timing.**  A real cable delivers two
// frames from one station at least a transmission time and a turn apart, and
// pacing every frame to that would be a second thing this seam does that the
// hardware does not ask for.  The measurement says it is not needed: with the
// retry, a burst of two, three and sixty-four frames all arrive whole, at the
// machine's own pace, and the only cost is one refusal a frame --- which is
// exactly what the cable charged, one abort and one retransmission.
//
// **An offer is not gated on `RX_BUSY`.**  A sender on the cable cannot see
// the receiver's buffer and offers anyway; `chaos_face.c` says the same thing
// at `chaos_face_give`, which offers and lets the fabric refuse and count.
// Gating here would make `LOST` read zero on a board where frames really were
// arriving faster than the machine takes them, which is the one thing that
// count exists to show.
//
// ## A BROADCAST IS COUNTED AND NOT RETRIED, AND THE TWO CONDITIONS DIFFER
//
// **The frames a busy receiver COUNTS and the frames it ABORTS are different
// sets, and this is the easiest thing here to get wrong.**  AIM-628 §2.5,
// having described the abort: "Note that a receiver whose packet buffer is
// full will only generate an abort signal if the packet was specifically
// addressed to it."  So:
//
//     the frame                       counted in Lost Count   sender aborted
//     addressed to this interface     yes                     YES
//     a broadcast, destination zero   yes                     no
//     anything taken under Spy        yes                     no
//     another station's frame         no                      no
//
// MIT's card wires the two apart at one gate: the 74S10 at LMMYNM 0D02 takes
// `MATCH SO FAR` --- mine, or zero, or spying --- for the count, and the
// abort flip-flop at LMMODU 0A09 is preset only when `ITS.ME` is true with
// it.  muir's ether makes the same split in two lines, the counting test
// admitting a broadcast and the aborting test not.
//
// **AND THE ABORT IS THE ONLY THING A RETRY CAN STAND ON.**  A retry here
// stands in for the sending station's driver answering Transmit Abort; a
// broadcast into a full buffer produces no abort, so no interface on the
// cable is told and no driver anywhere sends it again.  Retrying one would
// invent traffic the hardware never carried, and would delay the frames
// behind it while it did.  So a broadcast is offered ONCE, and if the buffer
// refuses it it is counted in `broadcasts_lost` and gone --- no wait, no
// second offer, and no place in the queue for anything to wait behind.
//
// **THE MACHINE'S OWN COUNT DOES NOT FOLLOW THIS SPLIT**, and that is the
// point of writing the table out.  The fabric counts a refused commit in
// `LOST` whatever the frame was addressed to, and the card's four-bit Lost
// Count counts a broadcast exactly as it counts a frame by name, because
// counting is the wider condition.  It is the ABORT, and therefore the
// RETRY, that is by name alone.
//
// **A broadcast touches no state of the queue's** --- not the head, not its
// offers, not its deadline, and not the latched `RX_FREE` bit, which exists
// only to make the head's turn an edge.  One consequence is worth stating
// rather than discovering: a broadcast that takes a buffer the machine has
// just emptied can cost a frame waiting behind it one of its three offers,
// refused against a buffer the broadcast filled.  That is what the cable
// charged the sender too, which retried blind into a busy receiver and was
// aborted again.

#ifndef CHAOS_INJECT_H
#define CHAOS_INJECT_H

#include <stdint.h>

#include "chaos_face.h"

// Offers in all, counting the first: `CHAOS-NUMBER-TRANSMIT-RETRIES`, "Send
// once and retry twice if aborted".
#define CHAOS_INJECT_OFFERS 3u

// The most frames that wait for a turn.  One turn of the program's loop takes
// up to `DRAIN` datagrams off the socket, which is 64, so a burst that
// arrives together is never dropped here for want of room; what overflows is
// a second burst arriving while the first is still held.  A frame past the
// bound is dropped and counted, as the cable would have lost it.
#define CHAOS_INJECT_QUEUE 64u

// How long a refused frame waits for the buffer to be emptied before it goes
// again anyway.  The machine's own copy loop is about 716 us for the longest
// packet --- 38 + 19 microinstructions for every two words at 290 ns each,
// derived in `docs/chaosnet.md` from microcode 323's `CHAOS-INTR` --- and the
// board's measured Unibus interrupt latency is a couple of milliseconds at
// worst.  Twenty is an order of magnitude above both, so a machine that is
// merely slow is never given up on, and a machine that has stopped listening
// holds one frame for at most two waits before the bound retires it.
#define CHAOS_INJECT_WAIT_NS 20000000ull

// One frame waiting for a turn.
struct chaos_inject_frame {
	uint16_t words[CHAOS_MAX_WORDS];
	unsigned n;
};

// **THE COUNTS CLOSE, AND THE IDENTITY IS THE PROPERTY.**  Every frame this
// edge is handed for the machine ends in exactly one of four places:
//
//     taken == stored + given_up + broadcasts_lost + no_room + waiting
//
// `chaos_test_inject.c` asserts it after every case, so a road added later
// that counts nothing breaks the sum and the check says so.  This is
// `struct chudp`'s rule one seam along, and for the same reason: a frame a
// person cannot see going missing is one that gets diagnosed as silence.
//
// **`refused` IS OFFERS AND NOT FRAMES**, and it is the only one of them that
// is.  It stands beside `LOST` in the fabric, which counts refused commits,
// so one frame offered three times moves both by three.  That is what makes
// the two comparable at the board, and it is why it is not in the sum above.
struct chaos_inject {
	struct chaos_inject_frame q[CHAOS_INJECT_QUEUE];
	unsigned head;			// the frame whose turn it is
	unsigned waiting;		// how many are queued, head included
	unsigned offers;		// offers made of the frame at the head
	uint64_t refused_at;		// when the head was last refused
	int held;			// the head has been refused and waits
	int trace;			// `--chaos-trace`, the ether's flag
	unsigned long taken;		// frames handed here for the machine
	unsigned long stored;		// frames the machine's buffer took
	unsigned long refused;		// OFFERS the fabric refused: `LOST`'s twin
	unsigned long given_up;		// frames past `CHAOS_INJECT_OFFERS`
	// Broadcasts a full buffer refused: offered once, counted, and gone,
	// because no abort went out for them and so no sender was ever told.
	// **It is its own count and not part of `given_up`**, which means a
	// machine that has stopped listening; folding the two together would
	// make that reading mean either that or ordinary broadcast loss on a
	// busy link, and a count that can mean two things is one nobody reads.
	unsigned long broadcasts_lost;
	unsigned long no_room;		// frames with no room to wait a turn
};

void chaos_inject_init(struct chaos_inject *q);

// A frame for the machine.  Offered at once when nothing is waiting, which is
// the common case and adds no latency to a cable that is keeping up; queued
// behind whatever is waiting otherwise, so that order is kept.
//
// **A BROADCAST NEVER QUEUES AND NEVER WAITS**, whatever is waiting: it is
// offered once, and counted in `broadcasts_lost` if the buffer refuses it.
// The destination is read out of the frame's own words rather than passed in,
// which is what the card's destination comparator does with the word as it
// goes by, and which means no caller can tell this file a frame is something
// it is not.  A frame of a
// length this seam cannot carry is neither queued nor counted: `chaos_face.c`
// has said what is wrong with it and no waiting will make it carryable.
void chaos_inject_give(struct chaos_inject *q, struct chaos_face *f,
		       const uint16_t *words, unsigned n, uint64_t now);

// One turn.  Offers the frame at the head if its turn has come --- it has
// never been offered, or the machine has emptied its buffer since it was
// refused, or it has waited `CHAOS_INJECT_WAIT_NS` for that and it has not
// happened.  Answers whether anything moved, so that the program's loop does
// not sleep through a queue that is draining.
//
// **ONE FRAME A TURN**, which is muir's `Chudp::transmit` popping one frame
// off `out` at each of the node's turns on the modeled cable.
int chaos_inject_pump(struct chaos_inject *q, struct chaos_face *f, uint64_t now);

#endif
