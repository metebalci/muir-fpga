// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `chaos_face.c` held on the build host to a MODEL of the fabric half: no
// board, no /dev/mem, and the same two function pointers the board fills with
// a mapping filled here with a structure that behaves as `chaos_face.h` says
// the interface does.  `feeder_test.c` and `console_test.c` do this one seam
// along, and for the same reason: it is what lets the code the board runs be
// the code the check runs.
//
// **THE MODEL IS `chaos_test_model.c`'s**, which is where it went when
// `chaos_test_inject.c` needed it too.  That file carries the argument for
// what it is, what it is not, and why it shares no expression and no constant
// with the code it checks.  What is held HERE is the driver of the register
// face against it: the identity word, the sixteen address switches, a frame
// each way, the lengths this seam will and will not carry, and what the
// status line reads.

#include "chaos_test.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include "chaos_face.h"
#include "chaos_packet.h"
#include "chaos_test_model.h"

// The program's own log prefix, so that capturing what it says and putting
// the log back afterwards leaves it as it was.
#define LOG_PREFIX "cadr-chaosnet: "

// The model's frame, with the packet number the face checks have always used.
// A burst check tells its frames apart by that number; these do not care.
static unsigned a_frame(uint16_t *out, unsigned data_len)
{
	return chaos_model_frame(out, data_len, 1);
}

// --- capturing what the program says --------------------------------------
//
// **An exit code cannot tell two failures apart, so a check on a program
// asserts the line it prints.**  A lesson from a probe script that failed on
// the check that named the fault and one four checks later with the same
// status.  Here it is the difference between "this is not a Chaosnet
// interface" and "this is the default slave, so it is the wrong bitstream",
// which is the one a reader needs.

static char *cap_buf;
static size_t cap_len;
static FILE *cap;
static FILE *cap_was;

static void capture_start(void)
{
	cap_was = cadr_log_file();
	free(cap_buf);
	cap_buf = NULL;
	cap_len = 0;
	cap = open_memstream(&cap_buf, &cap_len);
	cadr_log_init(LOG_PREFIX, cap);
}

// The text, and the log put back where it was.  The prefix goes back as the
// program's own, which is what the harness sets it to.
static const char *capture_end(void)
{
	fflush(cap);
	cadr_log_init(LOG_PREFIX, cap_was);
	fclose(cap);
	cap = NULL;
	return cap_buf ? cap_buf : "";
}

// --- what is there --------------------------------------------------------

static void check_ident(struct chaos_face *f, struct face_model *m)
{
	CHECK(chaos_face_ident(f) == 0, "\"CHAO\" is not taken for the Chaosnet interface");

	// **"NONE" is the common mistake**: a bitstream with a general-purpose
	// port brought out and `cadr_gp0_default.sv` behind this address rather
	// than the interface.  A reader told only "not CHAO" goes looking for a
	// broken interface; a reader told "NONE" goes looking for the right
	// bitstream, so the refusal must name it.
	m->ident = CADR_IDENT_NONE;
	capture_start();
	CHECK(chaos_face_ident(f) == -1, "\"NONE\" is taken for the Chaosnet interface");
	const char *said = capture_end();
	CHECK(strstr(said, "NONE") != NULL,
	      "the refusal does not name \"NONE\", the default slave: %s", said);

	// Neither a dead bus nor an undriven one is an interface.  The board
	// reads all ones where nothing drives the pins and zero where the level
	// shifters are off, and both have been mistaken for data here before.
	m->ident = 0;
	CHECK(chaos_face_ident(f) == -1, "a bus reading zeros is taken for the interface");
	m->ident = 0xFFFFFFFFu;
	CHECK(chaos_face_ident(f) == -1, "a bus reading ones is taken for the interface");
	m->ident = 0x5041434Bu;		/* "PACK", the disk pack side's */
	CHECK(chaos_face_ident(f) == -1, "the pack side is taken for the interface");
	m->ident = IDENT_CHAO;
	CHECK(chaos_face_ident(f) == 0, "\"CHAO\" is not taken for the interface");
}

// --- the sixteen address switches -----------------------------------------

static void check_address(struct chaos_face *f, struct face_model *m)
{
	// Read back as written, at the register the table names and nowhere
	// else: 3050 is this machine's address on System 100's band.
	chaos_face_set_address(f, 03050);
	CHECK(m->myaddr == 03050u, "MYADDR holds %o, wanting 3050", (unsigned)m->myaddr);
	CHECK(chaos_face_address(f) == 03050u, "the address does not read back as written");
	// Both ends of sixteen bits, so a byte lost or a half swapped shows.
	chaos_face_set_address(f, 0xFFFFu);
	CHECK(chaos_face_address(f) == 0xFFFFu, "all sixteen bits do not read back");
	chaos_face_set_address(f, 0x00FFu);
	CHECK(chaos_face_address(f) == 0x00FFu, "the low byte alone does not read back");
	chaos_face_set_address(f, 03050);
}

// --- a frame out of the machine -------------------------------------------

static void check_take(struct chaos_face *f, struct face_model *m)
{
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	uint16_t got[CHAOS_PKT_MAX_WORDS];
	const unsigned n = a_frame(frame, 6);
	CHECK(n == 14u, "a six-byte RFC is %u words, wanting 14", n);

	// Nothing waiting: nothing taken, and the fabric not told anything.
	const unsigned writes = m->writes;
	CHECK(chaos_face_take(f, got, CHAOS_PKT_MAX_WORDS) == 0,
	      "a frame was taken with none waiting");
	CHECK(m->writes == writes, "a take with nothing waiting wrote to the fabric");
	CHECK(m->takes == 0, "a take with nothing waiting told the fabric it took one");

	// **The words survive the round trip exactly.**  A frame the machine
	// transmitted, taken word for word, and the fabric told it was taken so
	// that Transmit Done can come up and the machine can send again.
	chaos_model_transmits(m, frame, n);
	memset(got, 0, sizeof got);
	CHECK(chaos_face_take(f, got, CHAOS_PKT_MAX_WORDS) == (int)n,
	      "the frame taken is not %u words", n);
	CHECK(memcmp(got, frame, (size_t)n * sizeof frame[0]) == 0,
	      "the frame's words did not survive the seam");
	CHECK(m->tx_valid == 0, "the frame is still waiting after it was taken");
	CHECK(m->takes == 1, "the fabric was told %u times that the frame was taken",
	      m->takes);
	CHECK(chaos_face_take(f, got, CHAOS_PKT_MAX_WORDS) == 0,
	      "the same frame was taken twice");

	// The longest frame there can be, at the boundary rather than near it:
	// 488 bytes of data is 244 words, and with the header and the trailer
	// that is 255.
	const unsigned big = a_frame(frame, CHAOS_MAX_DATA);
	CHECK(big == 255u, "the longest frame is %u words, wanting 255", big);
	chaos_model_transmits(m, frame, big);
	CHECK(chaos_face_take(f, got, CHAOS_PKT_MAX_WORDS) == (int)big,
	      "the longest frame was not taken whole");
	CHECK(memcmp(got, frame, (size_t)big * sizeof frame[0]) == 0,
	      "the longest frame's words did not survive the seam");

	// **A length this program cannot hold is said, and the frame is taken
	// anyway.**  A frame left standing holds the machine's transmitter down
	// for ever, so the fault is reported and the machine let go --- which
	// is a decision, and it is written at the code that makes it.
	chaos_model_transmits(m, frame, n);
	m->txlen = 1000;
	CHECK(chaos_face_take(f, got, CHAOS_PKT_MAX_WORDS) == -1,
	      "a frame of 1,000 words was accepted");
	CHECK(m->tx_valid == 0, "a frame this program cannot hold was left standing");
	// A length of zero with a frame said to be waiting: the other way the
	// fabric can contradict itself, and it must not read as "none waiting".
	chaos_model_transmits(m, frame, n);
	m->txlen = 0;
	CHECK(chaos_face_take(f, got, CHAOS_PKT_MAX_WORDS) == -1,
	      "a frame of no words was accepted");
	CHECK(m->tx_valid == 0, "a frame of no words was left standing");
	// And a caller whose buffer is smaller than the frame is refused rather
	// than given a truncated frame.
	chaos_model_transmits(m, frame, n);
	CHECK(chaos_face_take(f, got, 5u) == -1, "a 14-word frame was put in room for 5");
}

// --- a frame into the machine ---------------------------------------------

static void check_give(struct chaos_face *f, struct face_model *m)
{
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	const unsigned n = a_frame(frame, 6);

	// Stored, and stored exactly.
	CHECK(chaos_face_give(f, frame, n) == 1, "a frame was not stored");
	CHECK(m->commits == 1, "the frame was committed %u times", m->commits);
	CHECK(m->rx_words == n, "the fabric stored %u words, wanting %u", m->rx_words, n);
	CHECK(memcmp(m->rx, frame, (size_t)n * sizeof frame[0]) == 0,
	      "the frame's words did not survive the seam");
	CHECK(m->lost == 0, "a stored frame was counted lost");

	// **Refused while the machine has not emptied the buffer**, and counted
	// in LOST.  Nought, not a failure: the caller may try again, and the
	// four-bit Lost Count on the real interface means exactly this.
	uint16_t other[CHAOS_PKT_MAX_WORDS];
	const unsigned m2 = a_frame(other, 8);
	CHECK(chaos_face_give(f, other, m2) == 0,
	      "a frame was stored while the machine held the last one");
	CHECK(m->lost == 1, "LOST counts %u refusals, wanting 1", (unsigned)m->lost);
	CHECK(m->rx_words == n && memcmp(m->rx, frame, (size_t)n * sizeof frame[0]) == 0,
	      "a refused frame overwrote the one the machine had not read");

	// And taken once the machine has read the packet out.
	chaos_model_drains(m);
	CHECK(chaos_face_give(f, other, m2) == 1, "a frame was refused by an empty buffer");
	CHECK(m->rx_words == m2 && memcmp(m->rx, other, (size_t)m2 * sizeof other[0]) == 0,
	      "the second frame's words did not survive the seam");
	CHECK(m->lost == 1, "a stored frame moved LOST");

	// **A refusal the driver could not have predicted is still reported.**
	// With the receiver not armed the model refuses too --- whether the
	// fabric does is not known and is not asserted here.  What is asserted
	// is that `chaos_face_give` reads the fabric's own count rather than
	// deciding for it, so any refusal comes back as nought.
	chaos_model_drains(m);
	m->rx_armed = 0;
	const uint32_t lost = m->lost;
	CHECK(chaos_face_give(f, frame, n) == 0, "a refusal by the fabric read as a store");
	CHECK(m->lost == lost + 1u, "the fabric's refusal was not counted");
	m->rx_armed = 1;

	// **Loop Back is honored rather than ignored.**  `csr::LOOP_BACK` is a
	// maintenance mode in which the fabric carries the machine's own
	// packets back to it; a frame injected then would arrive as though the
	// machine had sent it to itself.  Nothing is offered at all, so the
	// commit count does not move.
	chaos_model_drains(m);
	m->looped = 1;
	const unsigned commits = m->commits;
	CHECK(chaos_face_give(f, frame, n) == 0, "a frame was injected into a looped interface");
	CHECK(m->commits == commits, "a looped interface was offered a frame");
	m->looped = 0;
	CHECK(chaos_face_give(f, frame, n) == 1, "a frame was refused after Loop Back ended");
}

static void check_give_lengths(struct chaos_face *f, struct face_model *m)
{
	uint16_t frame[CHAOS_PKT_MAX_WORDS + 8];
	memset(frame, 0, sizeof frame);
	const unsigned n = a_frame(frame, CHAOS_MAX_DATA);
	CHECK(n == CHAOS_MAX_WORDS, "the longest frame is %u words, wanting %u", n,
	      (unsigned)CHAOS_MAX_WORDS);

	// **Refused for its length, not truncated.**  Nothing at all is written
	// to the fabric: not the window, not RXLEN, not a commit --- a driver
	// that wrote 256 words into a 256-word window and then refused would
	// have already walked off the end of it.
	chaos_model_drains(m);
	const unsigned reads = m->reads, writes = m->writes;
	CHECK(chaos_face_give(f, frame, CHAOS_MAX_WORDS + 1u) == -1,
	      "a frame of %u words was accepted", CHAOS_MAX_WORDS + 1u);
	CHECK(m->reads == reads && m->writes == writes,
	      "a frame too long for the seam still reached the fabric");

	// The shortest thing that is not a frame: fewer words than a header and
	// a trailer, whatever is in them.
	CHECK(chaos_face_give(f, frame, 10u) == -1, "10 words were accepted as a frame");
	CHECK(chaos_face_give(f, frame, 0u) == -1, "an empty frame was accepted");
	CHECK(m->reads == reads && m->writes == writes,
	      "a frame too short for the seam still reached the fabric");

	// And the boundary itself is inside, not outside.
	CHECK(chaos_face_give(f, frame, CHAOS_MAX_WORDS) == 1,
	      "the longest frame there can be was refused");
	CHECK(m->rx_words == CHAOS_MAX_WORDS,
	      "the fabric stored %u words of the longest frame", m->rx_words);
	CHECK(memcmp(m->rx, frame, (size_t)n * sizeof frame[0]) == 0,
	      "the longest frame's words did not survive the seam");
}

// --- STAT and LOST, which the status line reads ---------------------------

static void check_status(struct chaos_face *f, struct face_model *m)
{
	chaos_model_drains(m);
	m->looped = 0;
	m->rx_armed = 1;
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	const unsigned n = a_frame(frame, 4);
	chaos_model_transmits(m, frame, n);
	const uint32_t st = chaos_face_stat(f);
	CHECK((st & ST_TX_VALID) != 0, "STAT does not say a frame is waiting");
	CHECK((st & ST_RX_BUSY) == 0, "STAT says the incoming buffer is busy and it is empty");
	CHECK((st & ST_RX_ARMED) != 0, "STAT does not say the receiver is armed");
	CHECK((st & ST_LOOPED) == 0, "STAT says the interface is looped and it is not");
	uint16_t got[CHAOS_PKT_MAX_WORDS];
	(void)chaos_face_take(f, got, CHAOS_PKT_MAX_WORDS);
	CHECK((chaos_face_stat(f) & ST_TX_VALID) == 0,
	      "STAT still says a frame is waiting after it was taken");

	m->lost = 7;
	CHECK(chaos_face_lost(f) == 7u, "LOST reads %u, wanting 7", (unsigned)chaos_face_lost(f));
	m->lost = 0;
}

// --- the suite ------------------------------------------------------------

void chaos_test_face(void)
{
	struct face_model m;
	struct chaos_face f;
	chaos_model_init(&m);
	chaos_model_attach(&f, &m);

	chaos_test_note("face: the interface's register face against a model of the fabric");
	// Each group starts from a fresh interface, and each ends by holding the
	// model's fault count at zero: nothing wrote a read-only register,
	// nothing wrote past a window, and nothing committed a length no frame
	// can be.  A driver that did any of those would be wrong on the board in
	// a way the returns above cannot show, so the count is read after every
	// group rather than once at the end where an earlier group's fault would
	// be thrown away with its model.
	check_ident(&f, &m);
	check_address(&f, &m);
	check_take(&f, &m);
	CHECK(m.faults == 0, "taking frames did %u things to the fabric it may not do",
	      m.faults);

	chaos_model_init(&m);
	check_give(&f, &m);
	CHECK(m.faults == 0, "giving frames did %u things to the fabric it may not do",
	      m.faults);

	chaos_model_init(&m);
	check_give_lengths(&f, &m);
	CHECK(m.faults == 0, "a frame of the wrong length did %u things to the fabric it "
	      "may not do", m.faults);

	chaos_model_init(&m);
	check_status(&f, &m);
	CHECK(m.faults == 0, "reading the status did %u things to the fabric it may not do",
	      m.faults);

	free(cap_buf);
	cap_buf = NULL;
}
