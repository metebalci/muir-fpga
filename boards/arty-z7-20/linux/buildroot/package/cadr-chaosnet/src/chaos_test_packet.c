// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `chaos_packet.c` held on the build host: the word layout, the padding rule,
// the check word and the refusals a frame must draw.  No board, no fabric, no
// socket --- nothing but a C compiler.
//
// **THE LAYOUT IS PINNED ON HAND-WRITTEN WORDS AND NOT ON A ROUND TRIP.**  A
// writer and a reader that are wrong in the same way agree with each other
// perfectly: a packet whose opcode went in the low byte and came out of the
// low byte would survive any number of round trips.  So every field is
// checked against a literal word first, the round trip second.  The literals
// are muir's own, from `a_packet_goes_to_words_and_back` in
// `muir/tests/chaos.rs`, and they are AIM-628 §3.5 and §3.6 written out: the
// opcode in the high byte of word 0, the forwarding count in the top four
// bits of word 1 and the byte count in the bottom twelve, then destination,
// destination index, source, source index, packet number, acknowledgement,
// and the data two bytes a word with the FIRST byte in the low half.
//
// **THE CHECK WORD IS ANCHORED ON THE NETLIST BOARD AND NOT ON THIS CODE.**
// `muir::chaos::packet::check_word`'s comment says the arrangement is "not
// read off a document; it is the one arrangement that reproduces the word the
// netlist board itself produced.  Looped back, the board gave `135771` for the
// packet `a_packet_loops_back_through_the_board` writes."  That is the
// strongest anchor there is --- a hardware measurement rather than a second
// transcription --- so this pins the same twelve words to the same 0o135771.
// Transcribing the CRC a second time here would only prove that two
// transcriptions agree.

#include <stdio.h>
#include <string.h>

#include "chaos_packet.h"
#include "chaos_test.h"

// The frame `a_packet_loops_back_through_the_board` writes, as the interface
// leaves it: the eight header words, "TIME" in two words, the cable
// destination, and the source address the hardware appends.  The board's own
// check word over exactly these is 0o135771.
static const uint16_t board_words[] = {
	0000400,	/* RFC, opcode 1 in the high byte */
	0000004,	/* forwarding count 0, byte count 4 */
	0003050,	/* destination address */
	0000000,	/* destination index: none yet */
	0003050,	/* source address */
	0000021,	/* source index */
	0000001,	/* packet number */
	0000000,	/* acknowledgement */
	0044524,	/* "TI", the first byte in the low half */
	0042515,	/* "ME" */
	0003050,	/* the cable destination, written last by the software */
	0003050		/* the source address the interface put in */
};

#define BOARD_CHECK 0135771

// The same packet, built the way the program builds one.
static void board_packet(struct chaos_packet *p)
{
	memset(p, 0, sizeof *p);
	p->opcode = CHAOS_RFC;
	p->forward = 0;
	p->dest = 0003050;
	p->dest_index = 0;
	p->source = 0003050;
	p->source_index = 0021;
	p->number = 1;
	p->ack = 0;
	p->len = 4;
	memcpy(p->data, "TIME", 4);
}

static void words_are(const uint16_t *got, const uint16_t *want, unsigned n, const char *what)
{
	for (unsigned i = 0; i < n; ++i)
		CHECK(got[i] == want[i], "%s word %u is %06o, wanting %06o", what, i,
		      (unsigned)got[i], (unsigned)want[i]);
}

// The eight header words and the data, against literals.
static void the_layout_is_the_memo_s(void)
{
	chaos_test_note("the word layout, against hand-written words");
	struct chaos_packet p;
	board_packet(&p);
	uint16_t w[CHAOS_PKT_MAX_WORDS];
	const unsigned n = chaos_packet_words(&p, w, CHAOS_PKT_MAX_WORDS);
	CHECK(n == 10, "four bytes of data is eight header words and one data pair, not %u", n);
	words_are(w, board_words, 10, "the packet's");

	// The fields the literals above do not separate: a forwarding count in
	// the top four bits of word 1 beside a byte count in the bottom twelve,
	// which one packet cannot show both of.
	p.forward = 013;
	p.len = 0400;
	memset(p.data, 0, sizeof p.data);
	const unsigned m = chaos_packet_words(&p, w, CHAOS_PKT_MAX_WORDS);
	CHECK(m == 8u + 0200u, "256 bytes is 128 data words, not %u", m - 8u);
	CHECK(w[1] == 0130400, "word 1 is the forwarding count over the byte count: %06o",
	      (unsigned)w[1]);
	CHECK(w[0] == 0000400, "the opcode stays in the high byte of word 0: %06o", (unsigned)w[0]);

	// A buffer too small is refused rather than overrun.
	CHECK(chaos_packet_words(&p, w, 9) == 0, "a buffer of nine words cannot hold 136");
}

// AIM-628 §7: an odd last byte "sits in the low half with a garbage padding
// byte in its high half"; the padding this program writes is zero, and the
// count word is what says the byte is not there.
static void an_odd_byte_sits_in_the_low_half(void)
{
	chaos_test_note("the odd-byte-count padding rule");
	struct chaos_packet p;
	board_packet(&p);
	p.len = 5;
	memcpy(p.data, "HELLO", 5);
	uint16_t w[CHAOS_PKT_MAX_WORDS];
	const unsigned n = chaos_packet_words(&p, w, CHAOS_PKT_MAX_WORDS);
	CHECK(n == 11, "five bytes is three data words, making eleven: %u", n);
	static const uint16_t want[3] = { 0042510, 0046114, 0000117 };
	words_are(w + CHAOS_PKT_HEADER_WORDS, want, 3, "HELLO's");
	CHECK((w[1] & 07777u) == 5, "the count word says five bytes, not six: %06o",
	      (unsigned)w[1]);

	// And it comes back as five bytes, the padding gone.
	uint16_t f[CHAOS_PKT_MAX_WORDS];
	const unsigned fn = chaos_packet_frame(&p, 0003050, 0003050, f, CHAOS_PKT_MAX_WORDS);
	CHECK(fn == 14, "eleven words and a three-word trailer: %u", fn);
	struct chaos_frame back;
	CHECK(chaos_frame_parse(f, fn, &back, NULL) == 0, "an odd-length frame parses");
	CHECK(back.packet.len == 5, "five bytes back, not six: %u", (unsigned)back.packet.len);
	CHECK(memcmp(back.packet.data, "HELLO", 5) == 0, "and they are the ones sent");
	CHECK(back.check_ok, "the check word covers the padded word");
}

// The check word the netlist board made, on the words it made it over.
static void the_check_word_is_the_boards(void)
{
	chaos_test_note("the check word, against the netlist board's own 0135771");
	const uint16_t got = chaos_check_word(board_words, 12);
	CHECK(got == BOARD_CHECK, "the check word is %06o, wanting the board's %06o",
	      (unsigned)got, (unsigned)BOARD_CHECK);

	// The frame builder must reach the same word, over the same twelve, and
	// must not fold its own check word into the sum.
	struct chaos_packet p;
	board_packet(&p);
	uint16_t f[CHAOS_PKT_MAX_WORDS];
	const unsigned n = chaos_packet_frame(&p, 0003050, 0003050, f, CHAOS_PKT_MAX_WORDS);
	CHECK(n == 13, "twelve words and the check word: %u", n);
	words_are(f, board_words, 12, "the frame's");
	CHECK(f[12] == BOARD_CHECK, "the frame carries the board's check word: %06o",
	      (unsigned)f[12]);

	// A single flipped bit anywhere in the frame moves the check word ---
	// which is the whole purpose of it, and a check word that were a
	// constant would satisfy every comparison above this one.  Taken
	// against `chaos_check_word` directly rather than through the parser,
	// because a bit flipped in the count word is refused for its length
	// before anything looks at the check.
	unsigned missed = 0, first_word = 0, first_bit = 0;
	for (unsigned i = 0; i < 12; ++i) {
		for (unsigned bit = 0; bit < 16; ++bit) {
			uint16_t bad[12];
			memcpy(bad, board_words, sizeof bad);
			bad[i] ^= (uint16_t)(1u << bit);
			if (chaos_check_word(bad, 12) == BOARD_CHECK) {
				if (!missed) {
					first_word = i;
					first_bit = bit;
				}
				++missed;
			}
		}
	}
	CHECK(missed == 0, "%u of the 192 single-bit flips did not move the check word, "
	      "the first at bit %u of word %u", missed, first_bit, first_word);

	// And a frame whose check word alone is wrong parses but does not check
	// good, which is the difference the caller acts on.
	struct chaos_frame fr;
	f[12] ^= 1u;
	CHECK(chaos_frame_parse(f, 13, &fr, NULL) == 0, "a bad check word is still a frame");
	CHECK(!fr.check_ok, "but it does not check good");
	CHECK(fr.check == (uint16_t)(BOARD_CHECK ^ 1u), "and the word as received is kept: %06o",
	      (unsigned)fr.check);
	f[12] ^= 1u;
	CHECK(chaos_frame_parse(f, 13, &fr, NULL) == 0 && fr.check_ok, "put back, it checks good");
}

// A frame there and back, every field compared.
static void a_frame_goes_there_and_back(void)
{
	chaos_test_note("a frame round trip, field by field");
	struct chaos_packet p;
	board_packet(&p);
	p.opcode = CHAOS_DAT;
	p.forward = 3;
	p.dest = 0003060;
	p.dest_index = 0022;
	p.source = 0003050;
	p.source_index = 0021;
	p.number = 0177776;
	p.ack = 0100000;
	p.len = 488;
	for (unsigned i = 0; i < 488; ++i)
		p.data[i] = (uint8_t)(i * 7u + 3u);
	uint16_t f[CHAOS_PKT_MAX_WORDS];
	const unsigned n = chaos_packet_frame(&p, 0003060, 0003050, f, CHAOS_PKT_MAX_WORDS);
	CHECK(n == CHAOS_PKT_MAX_WORDS, "a full packet is the longest frame: %u", n);
	struct chaos_frame back;
	const char *why = NULL;
	CHECK(chaos_frame_parse(f, n, &back, &why) == 0, "a full frame parses: %s",
	      why ? why : "-");
	CHECK(back.check_ok, "and checks good");
	CHECK(back.cable_dest == 0003060, "the cable destination: %06o",
	      (unsigned)back.cable_dest);
	CHECK(back.cable_source == 0003050, "the cable source: %06o",
	      (unsigned)back.cable_source);
	CHECK(back.packet.opcode == p.opcode, "opcode %03o", (unsigned)back.packet.opcode);
	CHECK(back.packet.forward == p.forward, "forwarding count %u",
	      (unsigned)back.packet.forward);
	CHECK(back.packet.dest == p.dest, "destination %06o", (unsigned)back.packet.dest);
	CHECK(back.packet.dest_index == p.dest_index, "destination index %u",
	      (unsigned)back.packet.dest_index);
	CHECK(back.packet.source == p.source, "source %06o", (unsigned)back.packet.source);
	CHECK(back.packet.source_index == p.source_index, "source index %u",
	      (unsigned)back.packet.source_index);
	CHECK(back.packet.number == p.number, "packet number %u", (unsigned)back.packet.number);
	CHECK(back.packet.ack == p.ack, "acknowledgement %u", (unsigned)back.packet.ack);
	CHECK(back.packet.len == p.len, "byte count %u", (unsigned)back.packet.len);
	CHECK(memcmp(back.packet.data, p.data, 488) == 0, "all 488 bytes");

	// An empty packet is a packet: EOF and STS carry no data.
	struct chaos_packet e;
	memset(&e, 0, sizeof e);
	e.opcode = CHAOS_EOF;
	e.dest = 0003060;
	const unsigned en = chaos_packet_frame(&e, 0003060, 0003050, f, CHAOS_PKT_MAX_WORDS);
	CHECK(en == 11, "eight header words and the trailer: %u", en);
	CHECK(chaos_frame_parse(f, en, &back, NULL) == 0, "an empty frame parses");
	CHECK(back.packet.len == 0 && back.packet.opcode == CHAOS_EOF, "and it is the EOF");
}

// The refusals, each identified by the sentence it gives: an exit status
// cannot tell two failures apart, so a check on a refusal has to assert the
// words as well as the -1.
static void a_frame_that_is_not_one_is_refused(void)
{
	chaos_test_note("the refusals chaos_frame_parse must make");
	struct chaos_packet p;
	board_packet(&p);
	uint16_t f[512];
	const unsigned n = chaos_packet_frame(&p, 0003050, 0003050, f, CHAOS_PKT_MAX_WORDS);
	struct chaos_frame fr;
	const char *why;

	// Fewer words than a header and a trailer.
	for (unsigned k = 0; k < CHAOS_PKT_HEADER_WORDS + CHAOS_PKT_TRAILER_WORDS; ++k) {
		why = NULL;
		CHECK(chaos_frame_parse(f, k, &fr, &why) == -1, "%u words is not a frame", k);
		CHECK(why && strstr(why, "too few words"), "and says so: %s", why ? why : "-");
	}

	// More words than any packet: 8 header, 244 data and 3 trailer.
	memset(f, 0, sizeof f);
	why = NULL;
	CHECK(chaos_frame_parse(f, CHAOS_PKT_MAX_WORDS + 1u, &fr, &why) == -1,
	      "256 words is past the longest frame");
	CHECK(why && strstr(why, "more words"), "and says so: %s", why ? why : "-");

	// A byte count past the 488 a packet carries, checked before the
	// length: a count of 500 in a frame of any length is not a packet.
	const unsigned m = chaos_packet_frame(&p, 0003050, 0003050, f, CHAOS_PKT_MAX_WORDS);
	CHECK(m == n, "the same frame again");
	f[1] = 500;
	why = NULL;
	CHECK(chaos_frame_parse(f, n, &fr, &why) == -1, "a count of 500 is refused");
	CHECK(why && strstr(why, "488"), "and names the 488: %s", why ? why : "-");

	// A byte count that disagrees with the frame's length, both ways round.
	// This is the meter AIM-628 §5.1 counts as "rejected for a length that
	// is not a multiple of 16 bits" and its neighbours.
	chaos_packet_frame(&p, 0003050, 0003050, f, CHAOS_PKT_MAX_WORDS);
	f[1] = 6;
	why = NULL;
	CHECK(chaos_frame_parse(f, n, &fr, &why) == -1, "a count of six in a four-byte frame");
	CHECK(why && strstr(why, "does not agree"), "and says so: %s", why ? why : "-");
	chaos_packet_frame(&p, 0003050, 0003050, f, CHAOS_PKT_MAX_WORDS);
	f[1] = 2;
	why = NULL;
	CHECK(chaos_frame_parse(f, n, &fr, &why) == -1, "a count of two in a four-byte frame");
	CHECK(why && strstr(why, "does not agree"), "and says so: %s", why ? why : "-");

	// And the one that is right is not refused, so the checks above are
	// refusing the fault and not the shape.
	chaos_packet_frame(&p, 0003050, 0003050, f, CHAOS_PKT_MAX_WORDS);
	why = NULL;
	CHECK(chaos_frame_parse(f, n, &fr, &why) == 0, "the untouched frame is taken: %s",
	      why ? why : "-");
	CHECK(why == NULL, "with no complaint");
}

// The names a trace line prints.  They are what somebody reads a run by, and
// an unknown opcode must print as a number rather than as nothing.
static void every_opcode_has_a_name(void)
{
	chaos_test_note("the opcode names");
	char into[8];
	CHECK(strcmp(chaos_op_name(CHAOS_RFC, into, sizeof into), "RFC") == 0, "RFC");
	CHECK(strcmp(chaos_op_name(CHAOS_BRD, into, sizeof into), "BRD") == 0, "BRD");
	CHECK(strcmp(chaos_op_name(CHAOS_DAT, into, sizeof into), "DAT200") == 0, "DAT200: %s",
	      into);
	CHECK(strcmp(chaos_op_name(0201, into, sizeof into), "DAT201") == 0, "DAT201: %s", into);
	CHECK(strcmp(chaos_op_name(CHAOS_DWD, into, sizeof into), "DWD300") == 0, "DWD300: %s",
	      into);
	CHECK(strcmp(chaos_op_name(020, into, sizeof into), "op20") == 0, "op20: %s", into);
	CHECK(chaos_op_is_data(CHAOS_DAT) && chaos_op_is_data(CHAOS_DWD), "both data ranges");
	CHECK(!chaos_op_is_data(CHAOS_EOF), "an EOF carries no user data");
	CHECK(chaos_op_is_controlled(CHAOS_RFC) && chaos_op_is_controlled(CHAOS_OPN) &&
	      chaos_op_is_controlled(CHAOS_EOF) && chaos_op_is_controlled(CHAOS_DAT),
	      "RFC, OPN, EOF and data are the controlled packets");
	CHECK(!chaos_op_is_controlled(CHAOS_STS) && !chaos_op_is_controlled(CHAOS_LOS) &&
	      !chaos_op_is_controlled(CHAOS_UNC) && !chaos_op_is_controlled(CHAOS_CLS),
	      "STS, LOS, UNC and CLS are not");
}

void chaos_test_packet(void)
{
	the_layout_is_the_memo_s();
	an_odd_byte_sits_in_the_low_half();
	the_check_word_is_the_boards();
	a_frame_goes_there_and_back();
	a_frame_that_is_not_one_is_refused();
	every_opcode_has_a_name();
}
