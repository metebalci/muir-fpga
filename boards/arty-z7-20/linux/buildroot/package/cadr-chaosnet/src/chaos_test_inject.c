// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A BURST of frames against a machine with one incoming packet buffer: how
// many of them reach it, in what order, and what the counts say.
//
// **THIS IS THE CHECK THE MEASUREMENT ASKED FOR.**  A host that sends a form
// longer than one packet sends two frames back to back, and the program takes
// up to sixty-four datagrams off the socket in one turn and hands each one
// down at once.  The interface holds ONE packet, so the second frame of a pair
// arrives while the machine is still copying the first out, and the fabric
// refuses it and counts it in `LOST`.  What this suite measures is what became
// of the rest of the burst.
//
// ## The two tables it prints, which are the finding
//
// The first table is the program as it was: each frame handed straight to
// `chaos_face_give`, a refusal handed to the sender's retransmission.  **One
// frame of the burst reaches the machine, however long the burst is.**  The
// second is the program with `chaos_inject.c` in it: the refused frame waits
// for a turn and goes again when the machine has emptied its buffer, and the
// whole burst arrives, in order, at the machine's own pace.
//
// There is a third table under it with the frames spaced twenty milliseconds
// apart on the old path, which is the contrast the original measurement drew
// on another machine: spacing works, and what the retry buys is that the
// sender no longer has to know to do it.
//
// ## The machine's service time, and why no answer here rests on it
//
// The model empties the buffer a service time after a frame is stored in it,
// derived in `chaos_test_model.h` from microcode 323's own `CHAOS-INTR`: about
// 716 us for the longest packet and about 50 us for a short one, at 290 ns a
// microcycle.  Both are used below and both give the same answer, because what
// decides a loss is an ORDER of events and not a duration: a burst handed down
// in one turn cannot outlast any service time at all, and a burst that waits
// for the buffer cannot lose to one.
//
// **AND THE COST OF ONE OFFER IS A PARAMETER, because it is not measured.**  A
// give is about 259 accesses across a general-purpose AXI port and nobody has
// timed one on the board.  The tables are run at nothing and at 25 us, and the
// only row that moves is the long burst on the old path: at 25 us an offer,
// sixty-four doomed offers take longer than the machine takes to empty its
// buffer, so two more frames happen to land when it is free.  That is the same
// finding --- one frame a service time, sampled --- and it is printed rather
// than hidden, because a number that moves with an unmeasured constant must
// not be quoted as though it did not.

#include "chaos_test.h"

#include <stdio.h>
#include <string.h>

#include <cadr/cadr_log.h>

#include "chaos_face.h"
#include "chaos_inject.h"
#include "chaos_packet.h"
#include "chaos_test_model.h"

// `cadr-chaosnet.c`'s own two constants, transcribed rather than included:
// the check never builds the program's main, and these are the shape of its
// loop.  `IDLE_SLEEP_US 1000` is how long a turn that did nothing sleeps, and
// `DRAIN 64` is how many datagrams one turn takes off the socket.
#define LOOP_SLEEP_NS 1000000ull
#define LOOP_DRAIN 64u

// The machine's service time, from `chaos_test_model.h`'s derivation.
#define SERVICE_LONG_NS 716000ull	/* the longest packet, 255 words */
#define SERVICE_SHORT_NS 50000ull	/* a six-byte packet, 14 words */

// What one offer costs the program, which is not measured on the board.
#define OFFER_FREE_NS 0ull
#define OFFER_COSTLY_NS 25000ull

// The longest a case is allowed to run, in turns of the loop.  A burst of
// sixty-four frames at a millisecond a turn is about a hundred; anything that
// needs ten thousand is not draining and the check says so rather than hanging.
#define TURN_BUDGET 10000u

// --- the harness ----------------------------------------------------------
//
// The program's loop, in the two lines of it that matter: hand down whatever
// the socket had, then pump, then sleep if nothing moved.

struct burst {
	struct face_model m;
	struct chaos_face f;
	struct chaos_inject q;
	uint64_t offer_ns;
	unsigned turns;
};

static void burst_init(struct burst *b, uint64_t service_ns, uint64_t offer_ns)
{
	memset(b, 0, sizeof *b);
	chaos_model_init(&b->m);
	chaos_model_attach(&b->f, &b->m);
	chaos_inject_init(&b->q);
	b->m.service_ns = service_ns;
	b->offer_ns = offer_ns;
}

// What an offer costs, charged against the model's clock.  Every road into the
// fabric goes through a commit, so counting commits counts offers.
static void charge(struct burst *b, unsigned commits_before)
{
	b->m.now += (uint64_t)(b->m.commits - commits_before) * b->offer_ns;
}

// `to_machine`, with the retry under it.
static void give(struct burst *b, const uint16_t *words, unsigned n)
{
	const unsigned c = b->m.commits;
	chaos_inject_give(&b->q, &b->f, words, n, b->m.now);
	charge(b, c);
}

// `to_machine` as it was: straight at the face, a refusal handed to the
// sender's retransmission.  Answers whether the frame was stored.
static int give_direct(struct burst *b, const uint16_t *words, unsigned n)
{
	const unsigned c = b->m.commits;
	const int r = chaos_face_give(&b->f, words, n);
	charge(b, c);
	return r == 1;
}

// One turn of the program's loop: pump, and sleep if nothing moved.
static int turn(struct burst *b)
{
	const unsigned c = b->m.commits;
	const int did = chaos_inject_pump(&b->q, &b->f, b->m.now);
	charge(b, c);
	if (!did)
		b->m.now += LOOP_SLEEP_NS;
	++b->turns;
	return did;
}

// Turns until the queue is empty, or until the budget runs out.  Answers the
// turns it took, or 0 if it never drained.
static unsigned settle(struct burst *b)
{
	const unsigned was = b->turns;
	while (b->q.waiting && b->turns - was < TURN_BUDGET)
		(void)turn(b);
	return b->q.waiting ? 0u : b->turns - was;
}

// The identity `chaos_inject.h` states: every frame this edge was handed for
// the machine is stored, given up, dropped for want of room, or waiting.
static void sum_closes(const struct chaos_inject *q, const char *where)
{
	const unsigned long sum = q->stored + q->given_up + q->no_room + q->waiting;
	CHECK(q->taken == sum,
	      "%s: %lu frames were taken for the machine and %lu accounted for "
	      "(%lu stored, %lu given up, %lu with no room, %u waiting)",
	      where, q->taken, sum, q->stored, q->given_up, q->no_room, q->waiting);
}

// --- the burst, on the old path and on the new one ------------------------

// `n` frames handed straight down with `gap_ns` of the machine's time between
// them, which is what the program did before `chaos_inject.c`.  Answers how
// many the machine took out.
static unsigned old_path(unsigned n, unsigned data_len, uint64_t service_ns,
			 uint64_t gap_ns, uint64_t offer_ns, uint32_t *lost)
{
	struct burst b;
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	burst_init(&b, service_ns, offer_ns);
	for (unsigned k = 0; k < n; ++k) {
		const unsigned len = chaos_model_frame(frame, data_len, k + 1);
		(void)give_direct(&b, frame, len);
		b.m.now += gap_ns;
	}
	// And let the machine finish whatever it holds, so that a frame stored
	// at the last instant is counted as having reached it.
	b.m.now += service_ns + 1;
	(void)chaos_face_stat(&b.f);
	*lost = b.m.lost;
	return b.m.delivered;
}

// The same burst with the retry under it: handed down in one turn, then turns
// of the loop until the queue has drained.
static unsigned new_path(unsigned n, unsigned data_len, uint64_t service_ns,
			 uint64_t offer_ns, struct chaos_inject *out, uint32_t *lost,
			 uint16_t *order, unsigned order_max)
{
	struct burst b;
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	burst_init(&b, service_ns, offer_ns);
	for (unsigned k = 0; k < n; ++k) {
		const unsigned len = chaos_model_frame(frame, data_len, k + 1);
		give(&b, frame, len);
	}
	(void)settle(&b);
	b.m.now += service_ns + 1;
	(void)chaos_face_stat(&b.f);
	*lost = b.m.lost;
	*out = b.q;
	for (unsigned k = 0; k < b.m.delivered && k < order_max; ++k)
		order[k] = b.m.seen[k];
	return b.m.delivered;
}

static void check_burst_table(uint64_t service_ns, unsigned data_len, uint64_t offer_ns,
			      const char *what)
{
	static const unsigned sizes[] = { 2u, 3u, LOOP_DRAIN };
	chaos_test_note("  %s: %llu us of service, %u bytes a frame, %llu us an offer",
			what, (unsigned long long)(service_ns / 1000), data_len,
			(unsigned long long)(offer_ns / 1000));
	for (unsigned s = 0; s < sizeof sizes / sizeof sizes[0]; ++s) {
		const unsigned n = sizes[s];
		uint32_t lost_old = 0, lost_new = 0;
		const unsigned got_old = old_path(n, data_len, service_ns, 0, offer_ns,
						  &lost_old);
		struct chaos_inject q;
		uint16_t order[LOOP_DRAIN];
		const unsigned got_new = new_path(n, data_len, service_ns, offer_ns, &q,
						  &lost_new, order, LOOP_DRAIN);
		chaos_test_note("    %2u frames back to back: %2u reached the machine "
				"without the retry (LOST %u), %2u with it (LOST %u)",
				n, got_old, (unsigned)lost_old, got_new, (unsigned)lost_new);

		// **WITHOUT THE RETRY THE BURST IS ONE FRAME.**  It is one and
		// not two whatever the burst is, unless an offer costs enough
		// for the machine to empty its buffer while the doomed offers
		// are being made --- which is the same finding sampled, and is
		// why the bound below is on what CANNOT happen rather than on
		// an exact count.
		CHECK(got_old >= 1u, "%s: a burst of %u delivered nothing at all", what, n);
		CHECK(got_old < n,
		      "%s: a burst of %u delivered all %u frames with no retry, which is "
		      "the fault this suite exists for not being there", what, n, got_old);
		const unsigned could = (unsigned)(1u + (uint64_t)n * offer_ns / service_ns);
		CHECK(got_old <= could,
		      "%s: a burst of %u delivered %u frames with no retry, and only %u "
		      "service times passed while it was offered", what, n, got_old, could);

		// **WITH IT, THE WHOLE BURST ARRIVES, IN ORDER.**
		CHECK(got_new == n, "%s: a burst of %u delivered %u frames with the retry",
		      what, n, got_new);
		for (unsigned k = 0; k < n && k < LOOP_DRAIN; ++k)
			CHECK(order[k] == (uint16_t)(k + 1),
			      "%s: the machine took packet %u where %u was sent %u%s",
			      what, (unsigned)order[k], k + 1, k + 1,
			      k ? " frames in" : " frame in");
		CHECK(q.stored == n, "%s: %lu frames were stored, wanting %u", what,
		      q.stored, n);
		CHECK(q.given_up == 0, "%s: %lu frames were given up and none should be",
		      what, q.given_up);
		CHECK(q.no_room == 0, "%s: %lu frames had no room to wait and none should",
		      what, q.no_room);
		CHECK(q.waiting == 0, "%s: %u frames are still waiting", what, q.waiting);

		// **ONE REFUSAL A FRAME AND NO MORE**, which is what the cable
		// charged too: the receiver aborted the frame once and the
		// sender's driver sent it again.  The first frame of a burst
		// finds the buffer free, so a burst of n costs n-1.
		CHECK(q.refused == n - 1u,
		      "%s: a burst of %u cost %lu refusals, wanting %u --- one a frame "
		      "after the first", what, n, q.refused, n - 1u);
		CHECK(lost_new == n - 1u,
		      "%s: the interface's LOST counts %u refusals, wanting %u", what,
		      (unsigned)lost_new, n - 1u);
		sum_closes(&q, what);
	}
}

static void check_spaced(void)
{
	static const unsigned sizes[] = { 2u, 3u, LOOP_DRAIN };
	chaos_test_note("  and spaced 20 ms apart with no retry, which is the contrast "
			"the first measurement drew");
	for (unsigned s = 0; s < sizeof sizes / sizeof sizes[0]; ++s) {
		const unsigned n = sizes[s];
		uint32_t lost = 0;
		const unsigned got = old_path(n, CHAOS_MAX_DATA, SERVICE_LONG_NS,
					      20000000ull, OFFER_FREE_NS, &lost);
		chaos_test_note("    %2u frames 20 ms apart: %2u reached the machine "
				"(LOST %u)", n, got, (unsigned)lost);
		CHECK(got == n, "%u frames spaced 20 ms apart delivered %u", n, got);
		CHECK(lost == 0, "%u frames spaced 20 ms apart lost %u", n,
		      (unsigned)lost);
	}
}

// --- what the frames carry, and in what order -----------------------------

static void check_words_survive(void)
{
	struct burst b;
	uint16_t frame[3][CHAOS_PKT_MAX_WORDS];
	unsigned len[3];
	burst_init(&b, SERVICE_LONG_NS, OFFER_FREE_NS);

	// Three frames of different lengths, so that a queue that carried the
	// words of one frame with the length of another shows.
	static const unsigned bytes[3] = { 6u, CHAOS_MAX_DATA, 100u };
	for (unsigned k = 0; k < 3; ++k) {
		len[k] = chaos_model_frame(frame[k], bytes[k], k + 1);
		give(&b, frame[k], len[k]);
	}
	// The machine takes each one out as it is stored, so the words have to
	// be compared as they arrive rather than at the end.  Turn by turn, and
	// compare whatever the buffer holds against the frame whose number it
	// carries.
	unsigned seen = 0;
	for (unsigned t = 0; t < TURN_BUDGET && seen < 3; ++t) {
		if (b.m.rx_busy) {
			const unsigned k = b.m.rx[6] - 1u;
			CHECK(k < 3u, "the buffer holds packet %u", (unsigned)b.m.rx[6]);
			if (k < 3u) {
				CHECK(b.m.rx_words == len[k],
				      "packet %u arrived as %u words, wanting %u", k + 1,
				      b.m.rx_words, len[k]);
				CHECK(memcmp(b.m.rx, frame[k],
					     (size_t)len[k] * sizeof frame[0][0]) == 0,
				      "packet %u's words did not survive the wait", k + 1);
				++seen;
			}
			// and let the machine have it
			b.m.now = b.m.free_at;
		}
		(void)turn(&b);
	}
	CHECK(seen == 3u, "%u of three frames were ever in the buffer", seen);
	sum_closes(&b.q, "the words");
}

// --- the bound, which is the CADR's own driver's ---------------------------

static void check_bound(void)
{
	struct burst b;
	uint16_t frame[CHAOS_PKT_MAX_WORDS];

	// **THE BOUND IS WRITTEN OUT BELOW AND NOT NAMED.**  A check that read
	// `CHAOS_INJECT_OFFERS` would move with a mutation of it and agree with
	// any bound at all, which is the trap this project has been caught by
	// twice.  So the number is here, once, with what it is: three offers,
	// which is `CHAOS-NUMBER-TRANSMIT-RETRIES` in `ucadr/uc-chaos.lisp`,
	// "Send once and retry twice if aborted".
	CHECK(CHAOS_INJECT_OFFERS == 3u,
	      "the bound is %u offers and the CADR's own driver allows three",
	      CHAOS_INJECT_OFFERS);
	// No service time at all: the machine does not empty its buffer, which
	// is what a machine whose microcode has stopped listening is.
	burst_init(&b, 0, OFFER_FREE_NS);
	const unsigned n = chaos_model_frame(frame, 6, 1);

	// One frame in, and the buffer stays full for ever.
	CHECK(chaos_face_give(&b.f, frame, n) == 1, "the first frame was not stored");

	const unsigned m = chaos_model_frame(frame, 6, 2);
	give(&b, frame, m);
	CHECK(b.q.waiting == 1u, "the refused frame is not waiting");
	CHECK(b.q.refused == 1ul, "the refused frame was offered %lu times", b.q.refused);

	// **NOTHING HAPPENS UNTIL THE WAIT HAS PASSED.**  The machine never
	// empties its buffer, so the only thing that can make the next offer is
	// the deadline, and a check that did not hold this would pass a retry
	// that hammered the fabric every turn.
	unsigned commits = b.m.commits;
	while (b.m.now < CHAOS_INJECT_WAIT_NS - LOOP_SLEEP_NS)
		(void)turn(&b);
	CHECK(b.m.commits == commits,
	      "the held frame was offered %u times before its wait was up",
	      b.m.commits - commits);
	CHECK(b.q.refused == 1ul, "the held frame was offered %lu times before its wait "
	      "was up", b.q.refused);

	// The second offer, then the third, and then MIT's own word for what
	// happens next: give up.
	while (b.q.refused < 2ul && b.turns < TURN_BUDGET)
		(void)turn(&b);
	CHECK(b.q.refused == 2ul, "the second offer was never made");
	CHECK(b.q.given_up == 0ul, "the frame was given up after two offers");
	CHECK(b.q.waiting == 1u, "the frame stopped waiting after two offers");
	while (b.q.waiting && b.turns < TURN_BUDGET)
		(void)turn(&b);
	CHECK(b.q.refused == 3ul, "the frame was offered %lu times, wanting three",
	      b.q.refused);
	CHECK(b.q.given_up == 1ul, "%lu frames were given up, wanting one", b.q.given_up);
	CHECK(b.q.stored == 0ul, "a frame was stored into a buffer nobody emptied");
	sum_closes(&b.q, "the bound");

	// **AND THE QUEUE MOVES ON.**  A frame given up must not leave the next
	// one standing behind it for ever, which is the whole reason the bound
	// exists.
	const unsigned p = chaos_model_frame(frame, 6, 3);
	give(&b, frame, p);
	CHECK(b.q.waiting == 1u, "the next frame did not take its place at the head");
	chaos_model_drains(&b.m);
	while (b.q.waiting && b.turns < TURN_BUDGET)
		(void)turn(&b);
	CHECK(b.q.stored == 1ul, "the frame behind a given-up one never went");
	sum_closes(&b.q, "after the bound");
}

// --- the wait is cut short by the machine emptying its buffer -------------

static void check_drain_cuts_the_wait(void)
{
	struct burst b;
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	burst_init(&b, 0, OFFER_FREE_NS);
	const unsigned n = chaos_model_frame(frame, 6, 1);
	CHECK(chaos_face_give(&b.f, frame, n) == 1, "the first frame was not stored");
	const unsigned m = chaos_model_frame(frame, 6, 2);
	give(&b, frame, m);
	CHECK(b.q.waiting == 1u, "the refused frame is not waiting");

	// A turn with the buffer still full does nothing.
	CHECK(turn(&b) == 0, "a turn offered a frame to a buffer that is still full");
	CHECK(b.q.refused == 1ul, "the held frame was offered again with nothing changed");

	// The machine reads the packet out, which is the moment a retry can
	// succeed, and the very next turn takes it --- a long way inside the
	// twenty-millisecond deadline, which has not nearly passed.
	chaos_model_drains(&b.m);
	CHECK(b.m.now < CHAOS_INJECT_WAIT_NS,
	      "the deadline had already passed, so this case proves nothing");
	CHECK(turn(&b) == 1, "the turn after the machine emptied its buffer did nothing");
	CHECK(b.q.stored == 1ul, "the frame did not go when the buffer was emptied");
	CHECK(b.q.waiting == 0u, "the frame is still waiting");
	sum_closes(&b.q, "the drain");
}

// --- a drain from BEFORE a refusal is not the turn to go again ------------

static void check_stale_drain(void)
{
	struct burst b;
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	burst_init(&b, 0, OFFER_FREE_NS);
	const unsigned n = chaos_model_frame(frame, 6, 1);

	// A frame in and out, which latches "the machine emptied the incoming
	// buffer".  Nothing has asked about that bit, so it is still set.
	CHECK(chaos_face_give(&b.f, frame, n) == 1, "the first frame was not stored");
	chaos_model_drains(&b.m);
	CHECK((b.m.irq & 2u) != 0u, "the model did not latch the drain");

	// Now fill the buffer and leave it full, and offer another frame.  The
	// offer must throw the stale bit away, or the refusal that follows will
	// be read as having been answered by a drain that happened before it.
	CHECK(chaos_face_give(&b.f, frame, n) == 1, "the second frame was not stored");
	const unsigned m = chaos_model_frame(frame, 6, 2);
	give(&b, frame, m);
	CHECK(b.q.refused == 1ul, "the frame was not refused by a full buffer");
	const unsigned commits = b.m.commits;
	CHECK(turn(&b) == 0, "a drain from before the refusal was taken for a turn");
	CHECK(b.m.commits == commits,
	      "a drain from before the refusal made %u more offers",
	      b.m.commits - commits);
	sum_closes(&b.q, "the stale drain");
}

// --- the queue's own bound -------------------------------------------------

static void check_no_room(void)
{
	struct burst b;
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	burst_init(&b, 0, OFFER_FREE_NS);
	const unsigned n = chaos_model_frame(frame, 6, 1);
	CHECK(chaos_face_give(&b.f, frame, n) == 1, "the first frame was not stored");

	// **WRITTEN OUT AND NOT NAMED**, for the reason the bound above is:
	// sixty-four is one turn's drain off the socket, so a burst that
	// arrives together is never dropped here for want of room.
	const unsigned queue = 64u;
	CHECK(CHAOS_INJECT_QUEUE == queue,
	      "the queue holds %u frames and one turn takes 64 datagrams off the socket",
	      CHAOS_INJECT_QUEUE);

	// One more than the queue holds, plus three that will not fit.  The
	// first of them is refused and becomes the head, so the queue is full
	// after sixty-four of them.
	const unsigned over = 3u;
	for (unsigned k = 0; k < queue + over; ++k) {
		const unsigned m = chaos_model_frame(frame, 6, k + 2u);
		give(&b, frame, m);
	}
	CHECK(b.q.waiting == queue, "%u frames are waiting, wanting %u", b.q.waiting,
	      queue);
	CHECK(b.q.no_room == (unsigned long)over,
	      "%lu frames had no room to wait, wanting %u", b.q.no_room, over);

	// **AND A FRAME WITH NOWHERE TO WAIT NEVER REACHES THE FABRIC.**  A
	// sender with no room for a packet does not transmit one, and a commit
	// made for a frame that was then thrown away would count in `LOST` as
	// though the machine had been too slow for it.
	const unsigned commits = b.m.commits;
	const unsigned m = chaos_model_frame(frame, 6, 99u);
	give(&b, frame, m);
	CHECK(b.m.commits == commits, "a frame with no room to wait was still committed");
	CHECK(b.q.no_room == (unsigned long)over + 1ul, "the frame was not counted");
	sum_closes(&b.q, "no room");

	// And the whole queue drains once the machine starts taking packets.
	b.m.service_ns = SERVICE_SHORT_NS;
	chaos_model_drains(&b.m);
	(void)settle(&b);
	CHECK(b.q.waiting == 0u, "%u frames never drained", b.q.waiting);
	CHECK(b.q.stored == (unsigned long)queue,
	      "%lu of the queue's %u frames were stored", b.q.stored, queue);
	sum_closes(&b.q, "no room, drained");
}

// --- a held frame holds up nothing else -----------------------------------

static void check_holds_up_nothing(void)
{
	struct burst b;
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	uint16_t out[CHAOS_PKT_MAX_WORDS];
	uint16_t got[CHAOS_PKT_MAX_WORDS];
	burst_init(&b, 0, OFFER_FREE_NS);
	const unsigned n = chaos_model_frame(frame, 6, 1);
	CHECK(chaos_face_give(&b.f, frame, n) == 1, "the first frame was not stored");
	const unsigned m = chaos_model_frame(frame, 6, 2);
	give(&b, frame, m);
	CHECK(b.q.waiting == 1u, "the refused frame is not waiting");

	// **THE MACHINE CAN STILL TRANSMIT, AND WHAT IT TRANSMITS STILL COMES
	// OFF WHOLE.**  A frame the machine puts on the cable goes to whoever
	// it is addressed to, and nothing about a frame waiting to go INTO the
	// machine may stand in its way --- which is the difference between a
	// queue at this seam and a program that waits for the buffer.  The
	// frames a held frame could delay are the ones behind it and no others:
	// `carry` only reaches here for a frame whose cable destination is this
	// machine or a broadcast, and everything else goes straight out over
	// UDP without passing this file at all.
	const unsigned t = chaos_model_frame(out, 40, 7);
	chaos_model_transmits(&b.m, out, t);
	for (unsigned k = 0; k < 8u; ++k)
		(void)turn(&b);
	CHECK(chaos_face_take(&b.f, got, CHAOS_PKT_MAX_WORDS) == (int)t,
	      "the machine's own frame was not taken while a frame waited its turn");
	CHECK(memcmp(got, out, (size_t)t * sizeof out[0]) == 0,
	      "the machine's own frame did not survive a turn with a frame waiting");
	CHECK(b.q.waiting == 1u, "the waiting frame went while the buffer was full");
	sum_closes(&b.q, "holding up nothing");
}

// --- the suite -------------------------------------------------------------

void chaos_test_inject(void)
{
	chaos_test_note("inject: a burst against a machine with one packet buffer");
	check_burst_table(SERVICE_LONG_NS, CHAOS_MAX_DATA, OFFER_FREE_NS,
			  "a full packet");
	check_burst_table(SERVICE_LONG_NS, CHAOS_MAX_DATA, OFFER_COSTLY_NS,
			  "a full packet, 25 us an offer");
	check_burst_table(SERVICE_SHORT_NS, 6u, OFFER_FREE_NS, "a short packet");
	check_spaced();
	check_words_survive();
	check_bound();
	check_drain_cuts_the_wait();
	check_stale_drain();
	check_no_room();
	check_holds_up_nothing();
}
