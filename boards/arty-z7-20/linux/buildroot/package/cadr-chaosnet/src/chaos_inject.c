// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The retry at the machine's end of the cable.  `chaos_inject.h` is the
// reference for what this is and why the hardware asks for it; this file only
// does it.
//
// **IT IS ITS OWN TRANSLATION UNIT, AND NOT THREE FIELDS IN `struct ether`.**
// `cadr-chaosnet.c` is the program's main and the check never builds it, so a
// rule that lived there would be a rule nothing exercises, and a mutation
// aimed at it would be applied, built around, and reported as surviving on
// evidence that does not exist.  `mutate.py` says so at `MUTABLE`.

#include "chaos_inject.h"

#include <limits.h>
#include <string.h>

#include <cadr/cadr_log.h>

#include "chaos_packet.h"

// Saturating, as every count in this program is: a count that came back round
// to a small number reads as a link with nothing wrong with it, which is the
// one thing these exist to show.
static void bump(unsigned long *c)
{
	if (*c != ULONG_MAX)
		++*c;
}

void chaos_inject_init(struct chaos_inject *q)
{
	memset(q, 0, sizeof *q);
}

// The one place a frame leaves this edge for the fabric, and the only place
// the counts of what the fabric did are moved.  It belongs to no frame in
// particular: a frame at the head of the queue and a broadcast that will
// never join it both go through here, and neither the head's offers nor its
// deadline are touched.
//
// **ANYTHING THAT IS NOT A STORE IS A REFUSAL HERE.**  The fabric refuses a
// commit while Receive Done is set, which is the abort AIM-628 §2.5 describes
// and the case this whole file is for; it also answers nought for a length it
// will not carry and while the interface is in Loop Back.  All three are
// counted the same way, because the sending station at the far end of a real
// cable could not have told them apart either --- its interface read Transmit
// Abort and its driver tried again --- and because a frame that is never
// counted anywhere is a frame that goes missing in silence.
static int commit(struct chaos_inject *q, struct chaos_face *f,
		  const uint16_t *words, unsigned n)
{
	if (chaos_face_give(f, words, n) == 1) {
		bump(&q->stored);
		return 1;
	}
	bump(&q->refused);
	return 0;
}

// An offer of the frame at the HEAD, which is the only frame that may be
// offered a second time, and which therefore has to be remembered: when it
// was refused, that it is held, and how many offers it has had of its three.
//
// **`RX_FREE` IS THROWN AWAY FIRST**, so that a drain from BEFORE this offer
// cannot be read as the turn to go again after it.  What a retry waits for is
// the machine emptying its buffer at or after the commit below, and
// `chaos_face_rx_freed` answers an edge since it was last asked.  Only a
// frame that may go again has any use for that bit, which is why nothing else
// in this file reads it.
static int offer(struct chaos_inject *q, struct chaos_face *f,
		 const uint16_t *words, unsigned n, uint64_t now)
{
	(void)chaos_face_rx_freed(f);
	if (commit(q, f, words, n) == 1)
		return 1;
	q->refused_at = now;
	q->held = 1;
	++q->offers;
	return 0;
}

// Whether the frame is addressed to everybody, which is the one thing about a
// frame this file asks.  **The two conditions differ**: a busy receiver COUNTS
// a broadcast and does not ABORT it (AIM-628 §2.5, "will only generate an
// abort signal if the packet was specifically addressed to it"), and a retry
// here stands in for a driver answering an abort that was never sent.
//
// It is read out of the frame's own words, as the card's destination
// comparator reads the word as it goes by, rather than being passed in by a
// caller who might be wrong about it.
//
// A frame too short to carry a trailer has no cable destination at all and so
// cannot be a broadcast; it is left to the ordinary road, where
// `chaos_face_give` refuses it wherever it is offered and the bound retires
// it like any other frame the machine will not take.
static int broadcast(const uint16_t *words, unsigned n)
{
	// The hardware trailer is destination, source, check, so the cable
	// destination is the third word from the end.
	return n >= CHAOS_PKT_TRAILER_WORDS &&
	       words[n - CHAOS_PKT_TRAILER_WORDS] == 0u;
}

// The head is done with, whichever way it went: the next frame's turn comes
// with no offers against it and nothing held.
static void done(struct chaos_inject *q)
{
	q->head = (q->head + 1) % CHAOS_INJECT_QUEUE;
	--q->waiting;
	q->offers = 0;
	q->held = 0;
	q->refused_at = 0;
}

// A frame into the slot it will wait in.
static void put(struct chaos_inject_frame *slot, const uint16_t *words, unsigned n)
{
	slot->n = n;
	memcpy(slot->words, words, (size_t)n * sizeof words[0]);
}

void chaos_inject_give(struct chaos_inject *q, struct chaos_face *f,
		       const uint16_t *words, unsigned n, uint64_t now)
{
	// **A FRAME LONGER THAN A SLOT NEVER REACHES ONE.**  The queue holds
	// whole frames and a longer one would walk off the end of a slot; and
	// no waiting makes such a frame carryable, since nothing about it will
	// change.  So it is offered once --- `chaos_face_give` refuses it and
	// says which half is at fault, having written nothing to the fabric ---
	// and then it is gone.  It never became a frame for the machine and is
	// counted in none of the four.
	//
	// A frame too SHORT for the seam is not caught here, and does not need
	// to be: `chaos_face_give` refuses it wherever it is offered, and the
	// refusal is counted and the bound retires it like any other frame the
	// machine will not take.  It cannot arrive off the cable in any case,
	// the link having refused a datagram shorter than a header and a
	// trailer before this is reached.
	if (n > CHAOS_MAX_WORDS) {
		(void)chaos_face_give(f, words, n);
		return;
	}

	bump(&q->taken);

	// **A BROADCAST IS OFFERED ONCE AND THEN IT IS GONE.**  No abort went
	// out for it on the cable, so no sender was told and no driver would
	// have sent it again; holding it here would invent a retransmission
	// the hardware never made, and would put a frame nobody is waiting for
	// in front of frames somebody is.  So it does not join the queue, it
	// does not wait behind one, and it goes at once whatever is waiting ---
	// which is the cable too, where a broadcast passes the receiver at the
	// instant it is on the wire and a frame being retried is still in some
	// other station's transmit buffer.
	//
	// The refusal is counted twice over, as every refusal here is: in
	// `refused`, which is the twin of the interface's own Lost Count and
	// counts a broadcast exactly as it counts a frame by name, and in
	// `broadcasts_lost`, which is this frame's one road out of the sum.
	if (broadcast(words, n)) {
		if (commit(q, f, words, n) == 0) {
			bump(&q->broadcasts_lost);
			if (q->trace)
				say("the machine's buffer was full: a broadcast "
				    "of %u words is lost, the cable having told "
				    "nobody to send it again", n);
		}
		return;
	}

	// Nothing is waiting, so this frame's turn is now.  A cable the machine
	// is keeping up with never reaches the queue at all, and no latency is
	// added to it.
	if (q->waiting == 0) {
		if (offer(q, f, words, n, now) == 1)
			return;
		put(&q->q[q->head], words, n);
		q->waiting = 1;
		if (q->trace)
			say("the machine's buffer was full: a frame of %u words "
			    "waits for a turn", n);
		return;
	}

	// Something is already waiting, so this goes BEHIND it.  The refused
	// frame stays at the head, as MIT's own driver leaves an aborted packet
	// on the transmit list until it is done with it and as muir's CHUDP
	// node puts an aborted frame back at the front of its queue.  Order is
	// the whole reason the queue is here rather than a single held frame.
	struct chaos_inject_frame *slot =
		q->waiting == CHAOS_INJECT_QUEUE
			? NULL
			: &q->q[(q->head + q->waiting) % CHAOS_INJECT_QUEUE];
	if (!slot) {
		// The cable would have lost it: a sender with nowhere to put a
		// packet does not transmit one.  Counted, because a frame
		// nobody can see going missing is one that gets diagnosed as
		// silence.
		bump(&q->no_room);
		if (q->trace)
			say("no room for a frame to wait its turn: %u are already "
			    "waiting", q->waiting);
		return;
	}
	put(slot, words, n);
	++q->waiting;
}

int chaos_inject_pump(struct chaos_inject *q, struct chaos_face *f, uint64_t now)
{
	if (q->waiting == 0)
		return 0;

	// Whose turn it is, and whether it has come.  A frame that has never
	// been offered goes now --- it is only in the queue because something
	// else was in front of it, and that is gone.  One that was refused goes
	// when the machine has emptied its buffer since, which is the moment a
	// retry can succeed; or when it has waited `CHAOS_INJECT_WAIT_NS` for
	// that and it has not happened, which is what makes the bound below
	// reachable on a machine that has stopped listening.
	if (q->held) {
		const int freed = chaos_face_rx_freed(f);
		if (!freed && now - q->refused_at < CHAOS_INJECT_WAIT_NS)
			return 0;
	}

	// **ONE FRAME A TURN**, which is muir's node popping one frame off its
	// queue at each turn it gets on the modeled cable.
	struct chaos_inject_frame *head = &q->q[q->head];
	if (offer(q, f, head->words, head->n, now) == 1) {
		done(q);
		return 1;
	}
	if (q->offers >= CHAOS_INJECT_OFFERS) {
		// "Send once and retry twice if aborted", and then MIT's own
		// word for what happens next: give up.
		bump(&q->given_up);
		if (q->trace)
			say("a frame of %u words was given up after %u offers the "
			    "machine refused", head->n, q->offers);
		done(q);
	}
	return 1;
}
