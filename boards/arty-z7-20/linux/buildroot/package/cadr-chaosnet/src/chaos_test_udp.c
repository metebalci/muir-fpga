// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Chaosnet over UDP, held to a datagram written out byte by byte and to a
// pair of links on the loopback.  `muir`'s `tests/chudp.rs` is the reference
// and this is that file's shape in C.
//
// **THE FRAME IS PINNED AS BYTES RATHER THAN LEFT IMPLICIT IN THE PACKING
// CODE**, and two of the datagrams below are `cbridge`'s own rather than this
// program's.  A check that built a datagram with the same code it was
// checking would agree with any byte order at all and with any check word; a
// check against bytes `cbridge` accepted, and against a datagram `cbridge`
// sent, cannot.
//
// The two vectors:
//
//   - an RFC for `STATUS`, 32 bytes, whose Internet checksum is 0xEA6D.  It
//     is built here from its fields and must come out byte for byte.
//   - an answer to a STATUS request that `cbridge` itself sent, 94 bytes.  It
//     is read here, its checksum verified, and written back byte for byte.
//
// **THE DATA IS WHAT SHOWS THE ORDER IS NOT ARBITRARY.**  AIM-628 §3.6 puts
// the first byte of a pair in the word's least significant half, and the word
// goes out most significant byte first, so `STATUS` appears on the wire as
// `TSTASU` and `cbtest` as `bcetts`.  Both are asserted below, in the
// direction each belongs to.
//
// **AND THE CHECK WORD CHANGES AT THIS EDGE, WHICH IS WHAT `check_the_check_
// word_is_swapped_at_the_edge` HOLDS.**  The machine's seam carries the
// 9401's CRC-16 in the trailer's third word and the wire carries the Internet
// checksum, so a frame that goes out and comes back must arrive with the CRC
// remade for it --- not with the checksum left where the CRC belongs.

#include "chaos_test.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "chaos_packet.h"
#include "chaos_udp.h"

// This machine, and the file and time host its band calls: System 100's
// band's pair.  That host is OFF this board --- a CADR has none inside it ---
// so here it is just another address reached over UDP.  A peer over UDP, and
// one this machine was never told about.  muir's `tests/chudp.rs` names the
// same four, so a reader can put the two files side by side.
#define ME		03050u
#define HOST		03060u
#define PEER		03040u
#define STRANGER	03041u
// A host beyond the bridge: no peer entry names it, so a frame for it goes to
// the default peer.  muir's `tests/chudp.rs` names the same one.
#define BEYOND		03042u

// --- one known packet -----------------------------------------------------

// An RFC for `STATUS` from PEER to ME, addressed on the cable to ME and
// sourced there by PEER: the frame `chaos_face.h`'s seam carries, which is
// the eight header words, the data, and then the hardware trailer's
// destination, source and check word.
static unsigned status_rfc(uint16_t *out, const void *data, unsigned len)
{
	struct chaos_packet p;
	memset(&p, 0, sizeof p);
	p.opcode = CHAOS_RFC;
	p.forward = 0;
	p.dest = ME;
	p.dest_index = 0;
	p.source = PEER;
	p.source_index = 021;
	p.number = 1;
	p.ack = 0;
	p.len = (uint16_t)len;
	if (len)
		memcpy(p.data, data, len);
	return chaos_packet_frame(&p, ME, PEER, out, CHAOS_PKT_MAX_WORDS);
}

// A frame from this machine to a peer, which is the direction `chudp_send`
// carries: source and destination the other way about.
static unsigned frame_to(uint16_t *out, uint16_t dest, uint8_t opcode, const void *data,
			 unsigned len)
{
	struct chaos_packet p;
	memset(&p, 0, sizeof p);
	p.opcode = opcode;
	p.dest = dest;
	p.source = ME;
	p.source_index = 021;
	p.number = 1;
	p.len = (uint16_t)len;
	if (len)
		memcpy(p.data, data, len);
	return chaos_packet_frame(&p, dest, ME, out, CHAOS_PKT_MAX_WORDS);
}

// --- the frame is these bytes ---------------------------------------------

// The 32 bytes of the RFC above, as `cbridge` takes them.  Every 16-bit word
// most significant byte first, the data swapped in pairs by that, and the
// Internet checksum in the trailer's third word.
static const uint8_t rfc_datagram[32] = {
	/* version 1, function 1, two argument bytes */
	0x01, 0x01, 0x00, 0x00,
	0x01, 0x00,		/* opcode RFC (1) in the high byte of the word */
	0x00, 0x06,		/* no forwarding, six data bytes */
	0x06, 0x28,		/* destination 3050 */
	0x00, 0x00,		/* destination index */
	0x06, 0x20,		/* source 3040 */
	0x00, 0x11,		/* source index 21 */
	0x00, 0x01,		/* packet number */
	0x00, 0x00,		/* acknowledgment */
	'T', 'S', 'T', 'A', 'S', 'U',	/* "STATUS", swapped in pairs */
	0x06, 0x28,		/* the trailer: destination 3050 */
	0x06, 0x20,		/* source 3040 */
	0xEA, 0x6D		/* the Internet checksum */
};

static void check_the_frame_is_these_bytes(void)
{
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	const unsigned n = status_rfc(frame, "STATUS", 6);
	CHECK(n == 14u, "the frame is %u words, wanting 14", n);
	// The check word `0o171007` is the CADR's own hardware CRC-16 over
	// these words --- the Fairchild 9401 at LMTBUF C09 --- and it is what
	// the machine's seam carries at both ends.  It is NOT what goes in the
	// datagram, and the two being different is the whole of what this edge
	// does.
	CHECK(frame[13] == 0171007u, "the hardware's check word is %o, wanting 171007",
	      (unsigned)frame[13]);

	uint8_t got[CHUDP_MAX_FRAME];
	memset(got, 0xAA, sizeof got);
	const unsigned len = chudp_wrap(frame, n, got, sizeof got);
	CHECK(len == 32u, "the datagram is %u bytes, wanting 32", len);
	CHECK(memcmp(got, rfc_datagram, sizeof rfc_datagram) == 0,
	      "the datagram is not the frame this file pins");

	// Named one at a time as well, so a failure says WHICH half of the
	// frame moved rather than only that something did.
	CHECK(got[0] == 1u && got[1] == 1u, "the header is version %u function %u, wanting 1 and 1",
	      (unsigned)got[0], (unsigned)got[1]);
	CHECK(got[2] == 0u && got[3] == 0u, "the two argument bytes are not zero");
	CHECK(got[4] == 0x01u && got[5] == 0x00u,
	      "the opcode word is not most significant byte first");
	CHECK(got[8] == 0x06u && got[9] == 0x28u,
	      "the destination address is not most significant byte first");
	// **`STATUS` IS `TSTASU` ON THE WIRE**, which is the one assertion that
	// distinguishes this framing from the one this program spoke before.
	CHECK(memcmp(got + 20, "TSTASU", 6) == 0,
	      "the data does not come out swapped in pairs, which is what §3.6 packing "
	      "and a most-significant-byte-first word give together");
	CHECK(got[26] == 0x06u && got[27] == 0x28u,
	      "the trailer's destination is not most significant byte first");
	CHECK(got[30] == 0xEAu && got[31] == 0x6Du,
	      "the trailer carries %02x%02x where the Internet checksum 0xEA6D belongs",
	      (unsigned)got[30], (unsigned)got[31]);

	// And the checksum on its own, against the figure `cbridge` accepts,
	// computed over exactly the words the protocol names: the eight header
	// words, the data words, and the trailer's destination and source.
	CHECK(chudp_checksum(frame, n - 1u) == 0xEA6Du,
	      "the checksum over the frame's first %u words is 0x%04x, wanting 0xEA6D",
	      n - 1u, (unsigned)chudp_checksum(frame, n - 1u));

	// And the pinned bytes read back to the words they were made from,
	// the CADR's own check word among them.
	uint16_t back[CHAOS_PKT_MAX_WORDS];
	const char *why = NULL;
	const unsigned m = chudp_unwrap(rfc_datagram, sizeof rfc_datagram, back,
					CHAOS_PKT_MAX_WORDS, &why, NULL);
	CHECK(m == n, "the pinned datagram reads back as %u words, wanting %u: %s", m, n,
	      why ? why : "");
	CHECK(m == n && memcmp(back, frame, (size_t)n * sizeof frame[0]) == 0,
	      "the pinned datagram does not read back to the frame it was made from");
}

// --- a datagram cbridge itself sent ---------------------------------------

// `cbridge`'s answer to a STATUS request, 94 bytes, as it put them on the
// wire.  The bridge was 177020 and named itself `cbtest`; the host that asked
// was 177022.  Its name appears as `bcetts`, and its checksum verifies the
// same way the one above does.
static const uint8_t cbridge_answer[94] = {
	0x01, 0x01, 0x00, 0x00, 0x05, 0x00, 0x00, 0x44, 0xfe, 0x12, 0x00, 0x12,
	0xfe, 0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x62, 0x63, 0x65, 0x74,
	0x74, 0x73, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x01, 0xfe, 0x00, 0x10, 0x00, 0x02, 0x00, 0x00,
	0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0xfe, 0x12, 0xfe, 0x10, 0xc4, 0x05
};

static void check_a_datagram_cbridge_sent_reads_and_writes_back(void)
{
	uint16_t back[CHAOS_PKT_MAX_WORDS];
	const char *why = NULL;
	int bad = 0;
	const unsigned n = chudp_unwrap(cbridge_answer, sizeof cbridge_answer, back,
					CHAOS_PKT_MAX_WORDS, &why, &bad);
	CHECK(n != 0, "the datagram cbridge sent does not read: %s", why ? why : "");
	CHECK(!bad, "the datagram cbridge sent was called a bad checksum");
	if (n == 0)
		return;
	CHECK(n == 45u, "it reads as %u words, wanting 45", n);

	// The checksum `cbridge` put on it, computed over the words before it.
	// `unwrap` has already replaced the trailer's third word with the
	// CADR's own, so the figure is taken from the datagram's own bytes.
	const uint16_t carried = (uint16_t)((unsigned)cbridge_answer[92] << 8 |
					    cbridge_answer[93]);
	CHECK(carried == 0xC405u, "the datagram carries 0x%04x, wanting 0xC405",
	      (unsigned)carried);
	CHECK(chudp_checksum(back, n - 1u) == carried,
	      "the checksum over its words is 0x%04x and it carries 0x%04x",
	      (unsigned)chudp_checksum(back, n - 1u), (unsigned)carried);

	// And it is a packet, with the fields the bridge put in it.
	struct chaos_frame f;
	CHECK(chaos_frame_parse(back, n, &f, &why) == 0, "it is not a packet: %s",
	      why ? why : "");
	CHECK(f.packet.opcode == CHAOS_ANS, "the opcode is %o, wanting ANS", (unsigned)f.packet.opcode);
	CHECK(f.packet.len == 68u, "the data count is %u, wanting 68", (unsigned)f.packet.len);
	CHECK(f.packet.dest == 0177022u && f.packet.source == 0177020u,
	      "it is %o -> %o, wanting 177020 -> 177022", (unsigned)f.packet.source,
	      (unsigned)f.packet.dest);
	CHECK(f.cable_dest == 0177022u && f.cable_source == 0177020u,
	      "the trailer is %o -> %o, wanting 177020 -> 177022", (unsigned)f.cable_source,
	      (unsigned)f.cable_dest);
	// **`bcetts` ON THE WIRE IS `cbtest` IN THE MACHINE.**  The bridge's
	// own name, unswapped by the same packing the RFC above is swapped by.
	CHECK(memcmp(f.packet.data, "cbtest", 6) == 0,
	      "the bridge's name does not read back as cbtest");
	// The CADR's own check word was made for it, so the frame is one the
	// machine's interface would have produced.
	CHECK(f.check_ok, "the CADR's check word was not made for the frame");

	// And it goes back out byte for byte, which is what says nothing was
	// lost or invented in between.
	uint8_t again[CHUDP_MAX_FRAME];
	memset(again, 0xAA, sizeof again);
	const unsigned len = chudp_wrap(back, n, again, sizeof again);
	CHECK(len == sizeof cbridge_answer, "it writes back as %u bytes, wanting 94", len);
	CHECK(len == sizeof cbridge_answer &&
		      memcmp(again, cbridge_answer, sizeof cbridge_answer) == 0,
	      "the datagram cbridge sent does not write back byte for byte");
}

// --- a word altered, and the checksum says so ------------------------------

static void check_one_word_altered_fails_the_checksum(void)
{
	// Every word of the frame in turn, one bit at a time in the low half:
	// the checksum covers all of them, so altering any one must be caught.
	// The trailer's own destination and source are covered too, which is
	// the half a checksum taken over the packet alone would miss.
	for (unsigned k = 0; k < (sizeof cbridge_answer - CHUDP_HEADER) / 2u; ++k) {
		uint8_t bad[sizeof cbridge_answer];
		uint16_t back[CHAOS_PKT_MAX_WORDS];
		const char *why = NULL;
		int flagged = 0;
		memcpy(bad, cbridge_answer, sizeof bad);
		// The count word is not altered here: a changed count is
		// refused for its length before the checksum is ever reached,
		// and this check is about the checksum.
		if (k == 1u)
			continue;
		bad[CHUDP_HEADER + 2u * k + 1u] ^= 0x01u;
		const unsigned n = chudp_unwrap(bad, sizeof bad, back, CHAOS_PKT_MAX_WORDS,
						&why, &flagged);
		CHECK(n == 0, "word %u altered and the frame was taken anyway", k);
		CHECK(flagged, "word %u altered and it was not called a bad checksum: %s", k,
		      why ? why : "(nothing said)");
		CHECK(why && strstr(why, "sum"), "word %u: the refusal does not name the sum: %s",
		      k, why ? why : "(nothing said)");
	}
	// And the checksum field itself.
	{
		uint8_t bad[sizeof cbridge_answer];
		uint16_t back[CHAOS_PKT_MAX_WORDS];
		const char *why = NULL;
		int flagged = 0;
		memcpy(bad, cbridge_answer, sizeof bad);
		bad[sizeof bad - 1u] ^= 0x01u;
		CHECK(chudp_unwrap(bad, sizeof bad, back, CHAOS_PKT_MAX_WORDS, &why,
				   &flagged) == 0,
		      "the checksum field was altered and the frame was taken anyway");
		CHECK(flagged, "an altered checksum was not called a bad checksum");
	}
	// The property the protocol states, on the frame as it stands: all of
	// its words, the checksum among them, sum to 0xFFFF.
	{
		uint32_t sum = 0;
		for (unsigned k = CHUDP_HEADER; k < sizeof cbridge_answer; k += 2u) {
			sum += (unsigned)cbridge_answer[k] << 8 | cbridge_answer[k + 1u];
			sum = (sum & 0xffffu) + (sum >> 16);
		}
		CHECK(sum == 0xffffu, "the frame's words sum to 0x%04x, wanting 0xFFFF",
		      (unsigned)sum);
	}
}

// --- the framing this program spoke before is refused ----------------------

// The same frame written the old way: the Chaos packet's own words least
// significant byte first, and the CADR's CRC-16 in the trailer's third word
// where the Internet checksum belongs.  **This is a NEGATIVE case on purpose.**
// The two framings cannot both be readable: a datagram that parses either way
// would let a board and a bridge disagree about what a packet says while both
// believed they had understood it.
static unsigned old_framing(const uint16_t *words, unsigned n, uint8_t *out)
{
	const unsigned body = n - CHAOS_PKT_TRAILER_WORDS;
	out[0] = 1;
	out[1] = 1;
	out[2] = 0;
	out[3] = 0;
	for (unsigned k = 0; k < body; ++k) {
		out[CHUDP_HEADER + 2u * k] = (uint8_t)words[k];
		out[CHUDP_HEADER + 2u * k + 1u] = (uint8_t)(words[k] >> 8);
	}
	// The trailer was network order then too, and carried the CRC.
	for (unsigned k = 0; k < CHAOS_PKT_TRAILER_WORDS; ++k) {
		uint8_t *at = out + CHUDP_HEADER + body * 2u + 2u * k;
		at[0] = (uint8_t)(words[body + k] >> 8);
		at[1] = (uint8_t)words[body + k];
	}
	return CHUDP_HEADER + body * 2u + CHUDP_TRAILER;
}

static void check_the_old_framing_is_refused(void)
{
	// With data, the count word comes out of the other half and is absurd:
	// six bytes read the other way round is 1,536, which no packet carries.
	// This is what `cbridge` saw when this program spoke to it.
	{
		uint16_t frame[CHAOS_PKT_MAX_WORDS], back[CHAOS_PKT_MAX_WORDS];
		uint8_t old[CHUDP_MAX_FRAME];
		const char *why = NULL;
		int flagged = 0;
		const unsigned n = status_rfc(frame, "STATUS", 6);
		const unsigned len = old_framing(frame, n, old);
		CHECK(len == 32u, "the old framing is %u bytes", len);
		CHECK(memcmp(old + 20, "STATUS", 6) == 0,
		      "the old framing did not put the data in the packet's own order");
		CHECK(chudp_unwrap(old, len, back, CHAOS_PKT_MAX_WORDS, &why, &flagged) == 0,
		      "a datagram in the old framing was read as this one");
		CHECK(why && strstr(why, "count"),
		      "the old framing is not refused for its count: %s", why ? why : "");
	}
	// With no data at all the count word reads the same either way, so the
	// length says nothing --- and the checksum is what refuses it, the old
	// framing carrying the CADR's CRC where the checksum belongs.
	{
		uint16_t frame[CHAOS_PKT_MAX_WORDS], back[CHAOS_PKT_MAX_WORDS];
		uint8_t old[CHUDP_MAX_FRAME];
		const char *why = NULL;
		int flagged = 0;
		const unsigned n = status_rfc(frame, "", 0);
		const unsigned len = old_framing(frame, n, old);
		CHECK(chudp_unwrap(old, len, back, CHAOS_PKT_MAX_WORDS, &why, &flagged) == 0,
		      "a datagram in the old framing with no data was read as this one");
		CHECK(flagged, "it was refused, but not for its checksum: %s", why ? why : "");
	}
}

// --- out and back ---------------------------------------------------------

static void check_a_frame_goes_out_and_comes_back(void)
{
	uint8_t big[CHAOS_PKT_MAX_DATA];
	memset(big, 0xFF, sizeof big);
	const struct {
		const void *data;
		unsigned len;
		const char *what;
	} cases[] = {
		{ "", 0, "no data at all" },
		{ "STATUS", 6, "six bytes" },
		{ "odd", 3, "an odd count" },
		{ big, CHAOS_PKT_MAX_DATA, "the most a packet carries" }
	};
	for (unsigned c = 0; c < sizeof cases / sizeof cases[0]; ++c) {
		uint16_t frame[CHAOS_PKT_MAX_WORDS], back[CHAOS_PKT_MAX_WORDS];
		uint8_t datagram[CHUDP_MAX_FRAME];
		const unsigned n = status_rfc(frame, cases[c].data, cases[c].len);
		const unsigned len = chudp_wrap(frame, n, datagram, sizeof datagram);
		CHECK(len == CHUDP_HEADER + (n - 3u) * 2u + CHUDP_TRAILER,
		      "%s: the datagram is %u bytes", cases[c].what, len);
		const char *why = NULL;
		const unsigned m = chudp_unwrap(datagram, len, back, CHAOS_PKT_MAX_WORDS, &why, NULL);
		CHECK(m == n, "%s: it reads back as %u words, wanting %u: %s", cases[c].what, m,
		      n, why ? why : "");
		CHECK(m == n && memcmp(back, frame, (size_t)n * sizeof frame[0]) == 0,
		      "%s: the words did not survive the datagram", cases[c].what);
		// And the frame is still a packet: the count, the addresses and
		// the check word all read as they were written.
		struct chaos_frame parsed;
		CHECK(chaos_frame_parse(back, m, &parsed, &why) == 0,
		      "%s: what came back is not a packet: %s", cases[c].what, why ? why : "");
		CHECK(parsed.packet.len == cases[c].len, "%s: the data count came back as %u",
		      cases[c].what, (unsigned)parsed.packet.len);
		CHECK(parsed.check_ok, "%s: the check word did not survive", cases[c].what);
	}
}

// --- an odd data count is padded ------------------------------------------

static void check_an_odd_count_is_padded(void)
{
	// The data is a whole number of 16-bit words on the cable, so an odd
	// count leaves a zero in the last word's HIGH half --- and the word
	// goes out most significant byte first, so the pad byte is the one
	// that comes FIRST of that pair on the wire.  `cbridge` always pads.
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	uint8_t padded[CHUDP_MAX_FRAME], unpadded[CHUDP_MAX_FRAME];
	const unsigned n = status_rfc(frame, "odd", 3);
	const unsigned len = chudp_wrap(frame, n, padded, sizeof padded);
	CHECK(len == 4u + 16u + 4u + 6u, "the padded datagram is %u bytes, wanting 30", len);
	// Three bytes of data in two words: `od`, swapped to `do`, and then
	// the pad byte before the `d`.
	CHECK(padded[20] == 'd' && padded[21] == 'o',
	      "the first data word is %c%c on the wire, wanting od swapped to do",
	      padded[20], padded[21]);
	CHECK(padded[22] == 0x00u,
	      "the pad byte is 0x%02x and it is not first of its pair", (unsigned)padded[22]);
	CHECK(padded[23] == 'd', "the odd byte is %c and it is not second of its pair",
	      padded[23]);
	// And the checksum covers the padded word, pad and all.
	CHECK(chudp_checksum(frame, n - 1u) ==
		      (uint16_t)((unsigned)padded[28] << 8 | padded[29]),
	      "the checksum does not cover the padded word");

	uint16_t a[CHAOS_PKT_MAX_WORDS];
	const char *why = NULL;
	const unsigned na = chudp_unwrap(padded, len, a, CHAOS_PKT_MAX_WORDS, &why, NULL);
	CHECK(na == n, "the padded datagram does not read: %s", why ? why : "");
	struct chaos_frame parsed;
	CHECK(na == n && chaos_frame_parse(a, na, &parsed, &why) == 0 &&
		      parsed.packet.len == 3u && memcmp(parsed.packet.data, "odd", 3) == 0,
	      "the padded datagram's data is not \"odd\"");

	// **AND AN UNPADDED ODD COUNT IS REFUSED.**  Its lone trailing byte
	// sits exactly where the pad byte would be, so whether it is data or
	// padding cannot be told from the datagram; reading it either way is a
	// guess about a case nothing produces.
	memcpy(unpadded, padded, 4u + 16u + 3u);
	memcpy(unpadded + 4u + 16u + 3u, padded + 4u + 16u + 4u, 6u);
	const unsigned shorter = len - 1u;
	uint16_t b[CHAOS_PKT_MAX_WORDS];
	why = NULL;
	CHECK(chudp_unwrap(unpadded, shorter, b, CHAOS_PKT_MAX_WORDS, &why, NULL) == 0,
	      "an unpadded odd data count was read, and its last byte guessed at");
	CHECK(why && strstr(why, "count"), "the refusal does not name the count: %s",
	      why ? why : "(nothing said)");
}

// --- the check word is swapped at this edge -------------------------------

static void check_the_check_word_is_swapped_at_the_edge(void)
{
	// The machine's seam carries the 9401's CRC-16 in the trailer's third
	// word and the wire carries the Internet checksum.  So a frame out and
	// back must arrive with the CRC remade for it, and the two must differ
	// on every frame that is not a coincidence --- which is what says the
	// conversion happens rather than the word being passed through.
	static const struct { const char *data; unsigned len; const char *what; } cases[] = {
		{ "", 0, "no data at all" },
		{ "STATUS", 6, "six bytes" },
		{ "odd", 3, "an odd count" }
	};
	for (unsigned c = 0; c < sizeof cases / sizeof cases[0]; ++c) {
		uint16_t frame[CHAOS_PKT_MAX_WORDS], back[CHAOS_PKT_MAX_WORDS];
		uint8_t datagram[CHUDP_MAX_FRAME];
		const char *why = NULL;
		const unsigned n = status_rfc(frame, cases[c].data, cases[c].len);
		const unsigned len = chudp_wrap(frame, n, datagram, sizeof datagram);
		const uint16_t on_the_wire = (uint16_t)((unsigned)datagram[len - 2u] << 8 |
							datagram[len - 1u]);
		CHECK(on_the_wire == chudp_checksum(frame, n - 1u),
		      "%s: the wire carries 0x%04x where the checksum 0x%04x belongs",
		      cases[c].what, (unsigned)on_the_wire,
		      (unsigned)chudp_checksum(frame, n - 1u));
		CHECK(on_the_wire != frame[n - 1u],
		      "%s: the CADR's check word went out unchanged as the checksum",
		      cases[c].what);
		const unsigned m = chudp_unwrap(datagram, len, back, CHAOS_PKT_MAX_WORDS,
						&why, NULL);
		CHECK(m == n, "%s: it does not read back: %s", cases[c].what, why ? why : "");
		CHECK(m == n && back[n - 1u] == frame[n - 1u],
		      "%s: the frame came back with 0%o in the trailer, wanting the CADR's "
		      "own 0%o", cases[c].what, m == n ? (unsigned)back[n - 1u] : 0u,
		      (unsigned)frame[n - 1u]);
	}
}

// --- what is refused, and by name -----------------------------------------

static void check_a_datagram_that_is_not_one_is_refused(void)
{
	uint16_t frame[CHAOS_PKT_MAX_WORDS], back[CHAOS_PKT_MAX_WORDS];
	uint8_t good[CHUDP_MAX_FRAME];
	const unsigned n = status_rfc(frame, "STATUS", 6);
	const unsigned len = chudp_wrap(frame, n, good, sizeof good);
	const char *why = NULL;
	CHECK(chudp_unwrap(good, len, back, CHAOS_PKT_MAX_WORDS, &why, NULL) == n,
	      "the good datagram does not read: %s", why ? why : "");

	// **A version this does not speak is refused BY NUMBER.**  The
	// protocol's author has said a version 2 may differ from version 1 in
	// nothing but byte order, so a version 2 peer read as a version 1 one
	// would exchange nonsense rather than fail.
	for (unsigned v = 0; v < 3; ++v) {
		const uint8_t values[3] = { 0, 2, 255 };
		uint8_t bad[CHUDP_MAX_FRAME];
		char number[8];
		memcpy(bad, good, len);
		bad[0] = values[v];
		why = NULL;
		CHECK(chudp_unwrap(bad, len, back, CHAOS_PKT_MAX_WORDS, &why, NULL) == 0,
		      "version %u was read as version 1", (unsigned)values[v]);
		snprintf(number, sizeof number, "%u", (unsigned)values[v]);
		CHECK(why && strstr(why, "version") && strstr(why, number),
		      "the refusal does not name the version: %s", why ? why : "(nothing said)");
	}
	// And a function that is not "here is a Chaos packet", which is
	// described as the only one defined.
	for (unsigned v = 0; v < 3; ++v) {
		const uint8_t values[3] = { 0, 2, 255 };
		uint8_t bad[CHUDP_MAX_FRAME];
		memcpy(bad, good, len);
		bad[1] = values[v];
		why = NULL;
		CHECK(chudp_unwrap(bad, len, back, CHAOS_PKT_MAX_WORDS, &why, NULL) == 0,
		      "function %u was read as a packet", (unsigned)values[v]);
		CHECK(why && strstr(why, "function"),
		      "the refusal does not say which: %s", why ? why : "(nothing said)");
	}

	// **A length that does not answer the data count is refused**, which is
	// what a wrong byte order looks like on the first packet: the count
	// word comes out of the other half and no longer accounts for the
	// datagram.
	uint8_t bad[CHUDP_MAX_FRAME + 8];
	memcpy(bad, good, len);
	why = NULL;
	CHECK(chudp_unwrap(bad, len - 2u, back, CHAOS_PKT_MAX_WORDS, &why, NULL) == 0,
	      "two bytes fewer than the count wants was read");
	memset(bad + len, 0, 2);
	why = NULL;
	CHECK(chudp_unwrap(bad, len + 2u, back, CHAOS_PKT_MAX_WORDS, &why, NULL) == 0,
	      "two bytes more than the count wants was read");
	// The count word's two bytes swapped, which is the wrong order for that
	// field and gives an absurd twelve-bit count.
	memcpy(bad, good, len);
	const uint8_t hold = bad[6];
	bad[6] = bad[7];
	bad[7] = hold;
	why = NULL;
	CHECK(chudp_unwrap(bad, len, back, CHAOS_PKT_MAX_WORDS, &why, NULL) == 0,
	      "a data count of 1,536 bytes was accepted");
	CHECK(why && strstr(why, "count"), "the refusal does not name the count: %s",
	      why ? why : "(nothing said)");

	// **Too long is refused FOR ITS LENGTH, not read as a truncated
	// packet.**  The receive buffer is one byte more than the longest
	// frame for exactly this.
	uint8_t huge[CHUDP_MAX_FRAME + 1];
	memset(huge, 0, sizeof huge);
	huge[0] = CHUDP_VERSION;
	huge[1] = CHUDP_FUNCTION_PACKET;
	why = NULL;
	CHECK(chudp_unwrap(huge, CHUDP_MAX_FRAME + 1u, back, CHAOS_PKT_MAX_WORDS, &why, NULL) == 0,
	      "a datagram longer than any Chaos packet was read");
	CHECK(why && strstr(why, "longer"), "the refusal does not say it is too long: %s",
	      why ? why : "(nothing said)");

	// Shorter than a header, and a header and a trailer with no packet
	// between them: neither is a frame.
	why = NULL;
	CHECK(chudp_unwrap(good, 3u, back, CHAOS_PKT_MAX_WORDS, &why, NULL) == 0,
	      "three bytes were read as a packet");
	CHECK(why && strstr(why, "short"), "the refusal does not say it is too short: %s",
	      why ? why : "(nothing said)");
	why = NULL;
	CHECK(chudp_unwrap(good, CHUDP_HEADER + CHUDP_TRAILER, back, CHAOS_PKT_MAX_WORDS,
			   &why, NULL) == 0,
	      "a header and a trailer with no packet between them was read");
	why = NULL;
	CHECK(chudp_unwrap(good, 0u, back, CHAOS_PKT_MAX_WORDS, &why, NULL) == 0,
	      "an empty datagram was read as a packet");

	// And a frame that will not fit where the caller put it is refused
	// rather than written past the end of it.
	why = NULL;
	CHECK(chudp_unwrap(good, len, back, 4u, &why, NULL) == 0, "a 14-word frame went into room for 4");

	// `wrap` refuses the same things rather than building a datagram
	// `unwrap` would throw away.
	CHECK(chudp_wrap(frame, 10u, good, sizeof good) == 0, "10 words were wrapped as a frame");
	CHECK(chudp_wrap(frame, CHAOS_PKT_MAX_WORDS + 1u, good, sizeof good) == 0,
	      "a frame longer than any Chaos packet was wrapped");
	CHECK(chudp_wrap(frame, n, good, 8u) == 0, "a 32-byte datagram went into room for 8");
}

// --- two links on the loopback --------------------------------------------

#define HEARD_MAX 8u

struct heard {
	unsigned n;
	unsigned len[HEARD_MAX];
	uint16_t words[HEARD_MAX][CHAOS_PKT_MAX_WORDS];
};

static void heard_deliver(void *ctx, const uint16_t *words, unsigned n)
{
	struct heard *h = ctx;
	if (h->n >= HEARD_MAX)
		return;
	h->len[h->n] = n;
	memcpy(h->words[h->n], words, (size_t)n * sizeof words[0]);
	++h->n;
}

// Where a link is bound, which is the only way to learn the port the host
// chose for a `port` of 0.  `fd` is a public field of `struct chudp` for
// this; there is no other way to ask.
static int bound_at(const struct chudp *u, struct sockaddr_in *at)
{
	socklen_t len = sizeof *at;
	memset(at, 0, sizeof *at);
	return getsockname(u->fd, (struct sockaddr *)at, &len) == 0 ? 0 : -1;
}

// Polls until `want` frames have arrived or five seconds have gone.  A
// datagram on the loopback is quick but not instant, and this is the only
// place this check waits on the host's network.
static int wait_for(struct chudp *u, struct heard *h, unsigned want)
{
	for (unsigned turn = 0; turn < 2500u; ++turn) {
		chudp_poll(u, 8, heard_deliver, h);
		if (h->n >= want)
			return 1;
		usleep(2000);
	}
	return h->n >= want;
}

// One datagram straight out of a socket, bypassing `chudp_send`'s routing:
// what a peer somewhere else would put on the wire, so that what arrives can
// be crafted rather than only what this program would have sent.
static void send_raw(int fd, const struct sockaddr_in *to, const uint16_t *words, unsigned n)
{
	uint8_t datagram[CHUDP_MAX_FRAME];
	const unsigned len = chudp_wrap(words, n, datagram, sizeof datagram);
	CHECK(len > 0, "the raw frame of %u words would not wrap", n);
	if (len == 0)
		return;
	CHECK(sendto(fd, datagram, len, 0, (const struct sockaddr *)to, sizeof *to) ==
		      (ssize_t)len,
	      "the raw datagram did not go: %s", strerror(errno));
}

static void check_the_links(void)
{
	// `a` is this board's link and `b` stands in for the peer.  Each names
	// the other, which is what a run with `--udp-peer` at both ends has.
	struct chudp a, b, c;
	struct sockaddr_in a_at, b_at;
	char spec[64];
	CHECK(chudp_bind(&a, "127.0.0.1", 0) == 0, "the board's link would not bind");
	CHECK(chudp_bind(&b, "127.0.0.1", 0) == 0, "the peer's link would not bind");
	CHECK(chudp_bind(&c, "127.0.0.1", 0) == 0, "the stranger's link would not bind");
	if (bound_at(&a, &a_at) < 0 || bound_at(&b, &b_at) < 0) {
		CHECK(0, "the host will not say where the links are bound");
		chudp_close(&a);
		chudp_close(&b);
		chudp_close(&c);
		return;
	}
	// The one station this cable carries, which is what the program sets
	// from `--chaos-address`: a datagram claiming to come from it is a
	// forgery, and a frame addressed to it is reached on the cable rather
	// than over UDP.
	a.local = ME;
	snprintf(spec, sizeof spec, "%o@127.0.0.1:%u", PEER, (unsigned)ntohs(b_at.sin_port));
	CHECK(chudp_add_peer(&a, spec) == 0, "%s was refused", spec);
	snprintf(spec, sizeof spec, "%o@127.0.0.1:%u", ME, (unsigned)ntohs(a_at.sin_port));
	CHECK(chudp_add_peer(&b, spec) == 0, "%s was refused", spec);
	// `c` names the board too, so that this check can HEAR what the board
	// sends it.  The board still knows nothing about `c`: which endpoints
	// `a` has is what the checks below are about, and naming one at the far
	// end does not put it there.
	CHECK(chudp_add_peer(&c, spec) == 0, "%s was refused for the stranger", spec);
	// A second endpoint for one address is a typed statement contradicting
	// a typed statement, and is refused rather than guessed at.
	CHECK(chudp_add_peer(&b, spec) == -1, "one address took two endpoints");
	CHECK(chudp_add_peer(&b, "3050") == -1, "a spec with no host was taken");
	CHECK(chudp_add_peer(&b, "0@127.0.0.1:1") == -1, "0 was taken for an address");
	CHECK(chudp_add_peer(&b, "400@127.0.0.1:1") == -1,
	      "an address with a zero host byte was taken");
	CHECK(chudp_add_peer(&b, "9@127.0.0.1:1") == -1, "9 was taken for an octal address");
	CHECK(b.npeers == 1u, "the peer's link has %u peers, wanting 1", b.npeers);

	// **A frame goes out as a datagram and arrives as the packet that was
	// written.**
	static struct heard at_b, at_a;
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	const unsigned n = frame_to(frame, PEER, CHAOS_RFC, "STATUS", 6);
	CHECK(chudp_send(&a, frame, n, PEER) == 1, "the frame did not go to its one peer");
	CHECK(wait_for(&b, &at_b, 1), "the peer never heard the frame");
	CHECK(at_b.n == 1u && at_b.len[0] == n &&
		      memcmp(at_b.words[0], frame, (size_t)n * sizeof frame[0]) == 0,
	      "the frame's words did not survive the socket");

	// **A destination no peer claims is dropped and NOT forwarded**: this
	// board is a leaf, not a router.  A good frame follows it so that the
	// check waits on something happening rather than on nothing happening.
	uint16_t stray[CHAOS_PKT_MAX_WORDS];
	const unsigned sn = frame_to(stray, STRANGER, CHAOS_RFC, "STATUS", 6);
	CHECK(chudp_send(&a, stray, sn, STRANGER) == 0,
	      "a frame for a third party was sent somewhere");
	CHECK(chudp_send(&a, frame, n, PEER) == 1, "the frame after it did not go");
	CHECK(wait_for(&b, &at_b, 2), "the peer never heard the second frame");
	CHECK(at_b.n == 2u, "the peer heard %u frames, wanting 2", at_b.n);
	CHECK(at_b.n >= 2u && at_b.len[1] == n &&
		      memcmp(at_b.words[1], frame, (size_t)n * sizeof frame[0]) == 0,
	      "what the peer heard second is not the frame that was sent");

	// **A broadcast goes to every peer**, since every peer is a station on
	// this machine's cable.
	uint16_t bcast[CHAOS_PKT_MAX_WORDS];
	const unsigned bn = frame_to(bcast, 0, CHAOS_BRD, "STATUS", 6);
	CHECK(chudp_send(&a, bcast, bn, 0) == 1, "a broadcast did not reach the one peer");
	CHECK(wait_for(&b, &at_b, 3), "the peer never heard the broadcast");

	// **A frame addressed on the cable to another peer is dropped on the
	// way in too.**  Forwarding it is a bridge's job and this board has no
	// routing table; `cbridge` is the thing to put beside it.  Again a good
	// frame follows, so the check waits on something.
	uint16_t forward[CHAOS_PKT_MAX_WORDS], mine[CHAOS_PKT_MAX_WORDS];
	struct chaos_packet p;
	memset(&p, 0, sizeof p);
	p.opcode = CHAOS_RFC;
	p.dest = PEER;
	p.source = HOST;
	p.len = 0;
	const unsigned fn = chaos_packet_frame(&p, PEER, HOST, forward, CHAOS_PKT_MAX_WORDS);
	send_raw(b.fd, &a_at, forward, fn);
	const unsigned mn = status_rfc(mine, "STATUS", 6);
	send_raw(b.fd, &a_at, mine, mn);
	CHECK(wait_for(&a, &at_a, 1), "the board never heard the frame meant for it");
	CHECK(at_a.n == 1u, "the board heard %u frames, wanting 1 --- a frame for another "
	      "peer was forwarded onto this cable", at_a.n);
	CHECK(at_a.n >= 1u && at_a.len[0] == mn &&
		      memcmp(at_a.words[0], mine, (size_t)mn * sizeof mine[0]) == 0,
	      "what the board heard is not the frame addressed to it");

	// **A frame with no cable source is a frame no station sent.**  The
	// transmitting hardware inserts that word itself and 0 is no station's
	// address, so a datagram carrying it is wreckage or a forgery; muir
	// drops it and so does this.  A good frame follows it again.
	uint16_t sourceless[CHAOS_PKT_MAX_WORDS];
	memset(&p, 0, sizeof p);
	p.opcode = CHAOS_RFC;
	p.dest = ME;
	p.source = PEER;
	p.len = 0;
	const unsigned zn = chaos_packet_frame(&p, ME, 0, sourceless, CHAOS_PKT_MAX_WORDS);
	send_raw(b.fd, &a_at, sourceless, zn);
	send_raw(b.fd, &a_at, mine, mn);
	CHECK(wait_for(&a, &at_a, 2), "the board never heard the frame after the sourceless one");
	CHECK(at_a.n == 2u, "the board heard %u frames, wanting 2 --- a frame with no cable "
	      "source reached the cable", at_a.n);

	// **A DATAGRAM FROM AN ENDPOINT NO FLAG NAMED IS HEARD.**  `c` is a
	// link at an endpoint the board was never told about, and what decides
	// is the frame and not the socket it came off: muir's `Chudp::arrived`
	// never looks at the sender either.  What such a host cannot get is an
	// answer, which the check after this one is about.
	uint16_t strange[CHAOS_PKT_MAX_WORDS];
	memset(&p, 0, sizeof p);
	p.opcode = CHAOS_RFC;
	p.dest = ME;
	p.source = STRANGER;
	p.len = 0;
	const unsigned xn = chaos_packet_frame(&p, ME, STRANGER, strange, CHAOS_PKT_MAX_WORDS);
	send_raw(c.fd, &a_at, strange, xn);
	CHECK(wait_for(&a, &at_a, 3), "a datagram from an endpoint no flag named was not heard");
	CHECK(at_a.n == 3u, "the board heard %u frames, wanting 3", at_a.n);
	CHECK(a.npeers == 1u, "the board has %u peers after hearing a stranger, wanting 1 --- "
	      "an endpoint was learned", a.npeers);

	// **A DATAGRAM CLAIMING A CABLE SOURCE THIS CABLE ALREADY CARRIES IS
	// DROPPED.**  The machine is on this cable, so a frame saying it came
	// FROM the machine is one the interface would take for its own ---
	// Transmit Done and all.  muir refuses it in the same place.  This is
	// the guard that has to hold now that a stranger is not turned away at
	// the door: before, no datagram from an unnamed endpoint got this far.
	// A good frame follows it, so the check waits on something happening.
	uint16_t forgery[CHAOS_PKT_MAX_WORDS];
	memset(&p, 0, sizeof p);
	p.opcode = CHAOS_RFC;
	p.dest = ME;
	p.source = ME;
	p.len = 0;
	const unsigned gn = chaos_packet_frame(&p, ME, ME, forgery, CHAOS_PKT_MAX_WORDS);
	send_raw(c.fd, &a_at, forgery, gn);
	send_raw(b.fd, &a_at, mine, mn);
	CHECK(wait_for(&a, &at_a, 4), "the board never heard the frame after the forgery");
	CHECK(at_a.n == 4u, "the board heard %u frames, wanting 4 --- a datagram claiming "
	      "this machine's own address reached the cable", at_a.n);

	// **NOTHING IS LEARNED, SO THE ANSWER TO A HOST NO FLAG NAMED HAS
	// NOWHERE TO GO.**  `--chaos-udp-dynamic` used to put the sender in
	// the table; a table filled in from what arrives is state nobody wrote
	// down, and it puts the naming in the hands of whoever can reach the
	// port.  muir removed it and so has this.
	uint16_t answer[CHAOS_PKT_MAX_WORDS];
	const unsigned an = frame_to(answer, STRANGER, CHAOS_CLS, "", 0);
	CHECK(chudp_send(&a, answer, an, STRANGER) == 0,
	      "an answer went out to a host no flag named");
	static struct heard at_c;
	chudp_poll(&c, 8, heard_deliver, &at_c);
	CHECK(at_c.n == 0u, "the answer went back where the packet came from; "
	      "an endpoint was learned");

	// **AND WITH A DEFAULT PEER IT GOES THERE.**  A peer entry says that
	// one address lives at one endpoint, so a frame for any other address
	// had nowhere to go; the default peer is the route of last resort, and
	// the frame carries the real destination in its hardware trailer for
	// the bridge there to route on.
	struct chudp bridge;
	static struct heard at_bridge;
	struct sockaddr_in bridge_at;
	CHECK(chudp_bind(&bridge, "127.0.0.1", 0) == 0, "the bridge's link would not bind");
	CHECK(bound_at(&bridge, &bridge_at) == 0, "the host will not say where the bridge is");
	snprintf(spec, sizeof spec, "127.0.0.1:%u", (unsigned)ntohs(bridge_at.sin_port));
	CHECK(chudp_set_default_peer(&a, spec) == 0, "%s was refused as a default peer", spec);
	CHECK(chudp_send(&a, answer, an, STRANGER) == 1,
	      "the answer to a host no entry names did not go to the default peer");
	CHECK(wait_for(&bridge, &at_bridge, 1), "the bridge never got the frame");
	CHECK(at_bridge.n == 1u && at_bridge.len[0] == an &&
		      memcmp(at_bridge.words[0], answer, (size_t)an * sizeof answer[0]) == 0,
	      "what the bridge got is not the frame, with its destination in its trailer");
	// A frame for an address NO entry names at all goes there too, which
	// is the case the flag exists for: 3042 is beyond the bridge.
	uint16_t far_off[CHAOS_PKT_MAX_WORDS];
	const unsigned yn = frame_to(far_off, BEYOND, CHAOS_RFC, "STATUS", 6);
	CHECK(chudp_send(&a, far_off, yn, BEYOND) == 1,
	      "a frame for an address beyond the bridge did not go to the default peer");
	CHECK(wait_for(&bridge, &at_bridge, 2), "the bridge never got the second frame");
	CHECK(at_bridge.n >= 2u && at_bridge.words[1][at_bridge.len[1] - 3] == BEYOND,
	      "the frame the bridge got does not carry its real destination");

	// **A FRAME FOR A NAMED PEER STILL GOES TO THAT PEER AND NOT TO THE
	// DEFAULT.**  The default peer is where what is not named goes, not a
	// route standing in front of the names.
	CHECK(chudp_send(&a, frame, n, PEER) == 1, "the frame to the named peer did not go");
	CHECK(wait_for(&b, &at_b, 4), "the named peer never heard it");
	chudp_poll(&bridge, 8, heard_deliver, &at_bridge);
	CHECK(at_bridge.n == 2u, "the bridge was given a frame a peer entry names");

	// **A BROADCAST GOES TO THE NAMED PEERS AND NOT TO THE DEFAULT
	// PEER.**  The named peers are stations on this machine's own cable so
	// a broadcast is theirs; the default peer is the way out to a wider
	// network, and handing it a broadcast would put this cable's on a
	// network the broadcast was never meant to reach.  Decided in muir,
	// and not an oversight.
	CHECK(chudp_send(&a, bcast, bn, 0) == 1, "the broadcast did not reach the one peer");
	CHECK(wait_for(&b, &at_b, 5), "the peer never heard the second broadcast");
	chudp_poll(&bridge, 8, heard_deliver, &at_bridge);
	CHECK(at_bridge.n == 2u, "the bridge was handed a broadcast");

	// **AND A FRAME FOR THIS CABLE'S OWN ADDRESS GOES NOWHERE.**  The
	// machine is reached on the cable and not over UDP, and it is not the
	// bridge's business either.
	uint16_t selfward[CHAOS_PKT_MAX_WORDS];
	const unsigned sfn = frame_to(selfward, ME, CHAOS_RFC, "STATUS", 6);
	CHECK(chudp_send(&a, selfward, sfn, ME) == 0,
	      "a frame for this cable's own address went out over UDP");
	chudp_poll(&bridge, 8, heard_deliver, &at_bridge);
	CHECK(at_bridge.n == 2u, "the bridge was given a frame for this machine itself");

	// **A packet does not move an endpoint a flag named.**  An endpoint
	// typed on the command line is a statement about where a host is;
	// letting a packet redirect it would put the naming back in the hands
	// of whoever can reach the port.  Nothing moves an entry now because
	// nothing writes one: the table is what the flags said and nothing
	// else, which is what this check holds.  `d` is an endpoint the board
	// has never seen, and it claims to be 3040 --- the address
	// `--chaos-udp-peer` put at `b`.
	struct chudp d;
	static struct heard at_d;
	CHECK(chudp_bind(&d, "127.0.0.1", 0) == 0, "the impostor's link would not bind");
	snprintf(spec, sizeof spec, "%o@127.0.0.1:%u", ME, (unsigned)ntohs(a_at.sin_port));
	CHECK(chudp_add_peer(&d, spec) == 0, "%s was refused for the impostor", spec);
	uint16_t impostor[CHAOS_PKT_MAX_WORDS];
	memset(&p, 0, sizeof p);
	p.opcode = CHAOS_RFC;
	p.dest = ME;
	p.source = PEER;
	p.len = 0;
	const unsigned in = chaos_packet_frame(&p, ME, PEER, impostor, CHAOS_PKT_MAX_WORDS);
	send_raw(d.fd, &a_at, impostor, in);
	CHECK(wait_for(&a, &at_a, 5), "the board never heard the impostor's frame");
	CHECK(a.npeers == 1u, "the board has %u peers after an impostor claimed 3040, wanting 1",
	      a.npeers);
	CHECK(a.peers[0].address == PEER && a.peers[0].where.sin_port == b_at.sin_port,
	      "a packet moved the endpoint a flag named");
	// And the answer goes where the flag said, not to whoever claimed the
	// address: the endpoint is what decides, so this is the check that
	// matters rather than the table's contents.
	uint16_t reply[CHAOS_PKT_MAX_WORDS];
	const unsigned rn = frame_to(reply, PEER, CHAOS_CLS, "", 0);
	CHECK(chudp_send(&a, reply, rn, PEER) == 1, "the answer to 3040 did not go");
	CHECK(wait_for(&b, &at_b, 6), "the answer did not go where the flag said 3040 was");
	chudp_poll(&d, 8, heard_deliver, &at_d);
	CHECK(at_d.n == 0u, "the answer went to whoever claimed the address");

	// **THE DEFAULT PEER IS AN ENDPOINT AND NO CHAOSNET ADDRESS**, which
	// is what tells it from a peer, and there is one route of last resort.
	CHECK(chudp_set_default_peer(&a, spec) == -1,
	      "<address>@<host> was taken for a default peer");
	CHECK(chudp_set_default_peer(&a, "127.0.0.1:42043") == -1,
	      "a second default peer was taken");
	struct chudp forms;
	CHECK(chudp_bind(&forms, "127.0.0.1", 0) == 0, "the forms link would not bind");
	// A bare port is on the loopback, which is what every endpoint here
	// means by one, and CHUDP's own port stands in when none is given.
	CHECK(chudp_set_default_peer(&forms, "42043") == 0, "a bare port was refused");
	CHECK(ntohs(forms.default_peer.sin_port) == 42043u &&
		      forms.default_peer.sin_addr.s_addr == htonl(INADDR_LOOPBACK),
	      "a bare port is not the loopback at that port");
	forms.have_default = 0;
	CHECK(chudp_set_default_peer(&forms, "127.0.0.1") == 0, "a bare address was refused");
	CHECK(ntohs(forms.default_peer.sin_port) == (unsigned)CHUDP_PORT,
	      "an address with no port did not take the protocol's own");
	forms.have_default = 0;
	CHECK(chudp_set_default_peer(&forms, "127.0.0.1:not-a-port") == -1,
	      "127.0.0.1:not-a-port was taken");
	CHECK(forms.have_default == 0, "a refused default peer was kept all the same");
	chudp_close(&forms);

	chudp_close(&a);
	chudp_close(&b);
	chudp_close(&c);
	chudp_close(&d);
	chudp_close(&bridge);
	CHECK(a.fd == -1 && b.fd == -1 && c.fd == -1 && d.fd == -1,
	      "a closed link still holds its socket");
}

// **A DATAGRAM FROM AN ENDPOINT NO FLAG NAMED IS HEARD, AND NOTHING IS
// LEARNED FROM IT.**  muir's `Chudp::arrived` looks at the frame and never at
// the socket it came off: what decides is the cable source and the cable
// destination, so a host this program was never told about is heard exactly
// as a named peer is.  What it does NOT do is write down where that host was,
// which is what `--chaos-udp-dynamic` used to do and what went with it: a
// table learned from packets is state nobody wrote down, and it puts the
// naming in the hands of whoever can reach the port.
//
// So the answer to such a host has nowhere to go unless a flag said where ---
// its own `--chaos-udp-peer`, or `--chaos-udp-default-peer` --- and with
// neither it is dropped.  That is `an_answer_goes_out_only_when_the_node_
// knows_where_to_send_it` in muir's `tests/chudp.rs`, in C.
static void check_a_stranger_is_heard_and_nothing_is_learned(void)
{
	struct chudp a, b, c;
	struct sockaddr_in a_at, b_at;
	char spec[64];
	static struct heard at_a, at_c;
	struct chaos_packet p;
	uint16_t strange[CHAOS_PKT_MAX_WORDS], answer[CHAOS_PKT_MAX_WORDS];

	CHECK(chudp_bind(&a, "127.0.0.1", 0) == 0, "the board's link would not bind");
	CHECK(chudp_bind(&b, "127.0.0.1", 0) == 0, "the peer's link would not bind");
	CHECK(chudp_bind(&c, "127.0.0.1", 0) == 0, "the stranger's link would not bind");
	if (bound_at(&a, &a_at) < 0 || bound_at(&b, &b_at) < 0) {
		CHECK(0, "the host will not say where the links are bound");
		chudp_close(&a);
		chudp_close(&b);
		chudp_close(&c);
		return;
	}
	a.local = ME;
	snprintf(spec, sizeof spec, "%o@127.0.0.1:%u", PEER, (unsigned)ntohs(b_at.sin_port));
	CHECK(chudp_add_peer(&a, spec) == 0, "%s was refused", spec);

	// `c` is at an endpoint no flag named, and its frame is addressed on
	// the cable to this machine, which is the only thing that decides.
	memset(&p, 0, sizeof p);
	p.opcode = CHAOS_RFC;
	p.dest = ME;
	p.source = STRANGER;
	p.len = 0;
	const unsigned xn = chaos_packet_frame(&p, ME, STRANGER, strange, CHAOS_PKT_MAX_WORDS);
	send_raw(c.fd, &a_at, strange, xn);
	CHECK(wait_for(&a, &at_a, 1), "a datagram from an endpoint no flag named was not heard");
	CHECK(at_a.n == 1u && at_a.len[0] == xn &&
		      memcmp(at_a.words[0], strange, (size_t)xn * sizeof strange[0]) == 0,
	      "what the board heard is not the stranger's frame");

	// **And the table is what the flags said.**  Not one entry more, and
	// the answer to that host therefore has nowhere to go.
	CHECK(a.npeers == 1u, "the board has %u peers after hearing a stranger, wanting 1",
	      a.npeers);
	const unsigned an = frame_to(answer, STRANGER, CHAOS_CLS, "", 0);
	CHECK(chudp_send(&a, answer, an, STRANGER) == 0,
	      "an answer went out to a host no flag named");
	chudp_poll(&c, 8, heard_deliver, &at_c);
	CHECK(at_c.n == 0u, "the answer went back where the packet came from; "
	      "an endpoint was learned");

	chudp_close(&a);
	chudp_close(&b);
	chudp_close(&c);
}

// **A FLAG THAT SAYS WHO IS ON THE CABLE NEEDS THE CABLE.**  muir's rule at
// `0851fa7`: `--chaos-address` sets the sixteen address switches and nothing
// else, `--chaos-udp` is the cable, and without it nothing is sent.  A peer
// and a route of last resort are each a statement about a link, so each is
// refused when there is no link --- rather than bringing a cable of its own,
// which is what this program did and which put a run that named its file host
// on a network it had not asked for, listening on a port nobody had named.
//
// The peer is named before the default peer, in muir's own order, so that a
// run giving both is told about the one a person is likelier to have meant.
static void check_a_flag_that_says_who_is_on_the_cable_needs_the_cable(void)
{
	struct {
		int cable;
		unsigned peers;
		int dflt;
		const char *want;
	} cases[] = {
		// With the cable, every combination is a run that makes sense.
		{ 1, 0, 0, NULL },
		{ 1, 2, 0, NULL },
		{ 1, 0, 1, NULL },
		{ 1, 2, 1, NULL },
		// Without it, the switches alone are a machine with no cable ---
		// legal, and it talks to nobody.
		{ 0, 0, 0, NULL },
		// And a flag that says who is on the cable is refused by name.
		{ 0, 1, 0, "--chaos-udp-peer" },
		{ 0, 0, 1, "--chaos-udp-default-peer" },
		{ 0, 1, 1, "--chaos-udp-peer" },
	};
	for (unsigned k = 0; k < sizeof cases / sizeof cases[0]; ++k) {
		const char *got = chudp_flag_without_cable(cases[k].cable, cases[k].peers,
							   cases[k].dflt);
		if (cases[k].want == NULL) {
			CHECK(got == NULL,
			      "cable %d, %u peers, default %d: %s was called a flag "
			      "without a cable",
			      cases[k].cable, cases[k].peers, cases[k].dflt, got ? got : "");
		} else {
			CHECK(got != NULL && strcmp(got, cases[k].want) == 0,
			      "cable %d, %u peers, default %d: %s, wanting %s",
			      cases[k].cable, cases[k].peers, cases[k].dflt,
			      got ? got : "nothing was refused", cases[k].want);
		}
	}
}

// --- every datagram is accounted for --------------------------------------

// One datagram out of a socket exactly as it stands, which `send_raw` cannot
// do: it wraps a frame this program built, and what is wanted here is a
// datagram this program would never have built.
static void send_bytes(int fd, const struct sockaddr_in *to, const uint8_t *bytes, unsigned len)
{
	CHECK(sendto(fd, bytes, len, 0, (const struct sockaddr *)to, sizeof *to) == (ssize_t)len,
	      "the raw datagram of %u bytes did not go: %s", len, strerror(errno));
}

// Every counter the link keeps, added up.  **NOT the identity**: this is what
// is waited on, and waiting on one side of an identity that a mutation has
// broken would make the check hang rather than fail.  Any counter moving
// means the datagram has been dealt with, which is all the waiting needs to
// know; whether the right ones moved is asserted afterwards.
static unsigned long tally(const struct chudp *u)
{
	return u->received + u->delivered + u->bad_shape + u->bad_checksum + u->not_this_cable;
}

// Sends one datagram and polls until the link has counted it somewhere.
static void one_datagram(struct chudp *u, int fd, const struct sockaddr_in *to,
			 const uint8_t *bytes, unsigned len, struct heard *h)
{
	const unsigned long before = tally(u);
	send_bytes(fd, to, bytes, len);
	for (unsigned turn = 0; turn < 2500u; ++turn) {
		chudp_poll(u, 8, heard_deliver, h);
		if (tally(u) != before)
			return;
		usleep(2000);
	}
	CHECK(tally(u) != before,
	      "a datagram sent on the loopback moved no counter at all: it was lost, or "
	      "every road out of the link is uncounted");
}

// **EVERY DATAGRAM THAT ARRIVES IS ACCOUNTED FOR, AND THE SUM CLOSES.**
//
// The link refuses a datagram for eight reasons and until now counted ONE of
// them.  The other seven were printed under `--chaos-trace` and nowhere else,
// so a report line reading "0 in, 0 with a bad checksum" said the same thing
// whether nothing had arrived or everything had arrived and been thrown
// away.  Those are the two states a person reads that line to tell apart.
//
// **WHAT IS HELD IS THE IDENTITY AND NOT THE COUNTERS ONE BY ONE**, though
// the counters are asserted too.  Each road is driven exactly once and then
//
//     received == delivered + bad_shape + bad_checksum + not_this_cable
//
// which is what says no road is uncounted.  A counter deleted, a road that
// falls through to nothing, a refusal counted twice: all three break the sum.
// Asserting the four separately as well is what catches the mutation that
// keeps the sum and moves a count from one class to another, which is a link
// telling a person the wrong thing about their network.
static void check_every_datagram_is_accounted_for(void)
{
	struct chudp board, far;
	struct sockaddr_in board_at, far_at;
	struct heard h;
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	uint8_t good[CHUDP_MAX_FRAME], bad[CHUDP_MAX_FRAME + 1];
	char spec[64];
	unsigned len;

	memset(&h, 0, sizeof h);
	CHECK(chudp_bind(&board, "127.0.0.1", 0) == 0, "the board's link would not bind");
	CHECK(chudp_bind(&far, "127.0.0.1", 0) == 0, "the far end's link would not bind");
	board.local = ME;
	CHECK(bound_at(&board, &board_at) == 0, "the board's link will not say where it is");
	CHECK(bound_at(&far, &far_at) == 0, "the far end's link will not say where it is");
	// One peer, so that a frame addressed on the cable to HOST is a frame
	// for somebody else and takes the leaf's own road out.
	snprintf(spec, sizeof spec, "%o@127.0.0.1:%u", HOST, (unsigned)ntohs(far_at.sin_port));
	CHECK(chudp_add_peer(&board, spec) == 0, "the peer would not take");

	CHECK(board.received == 0 && board.delivered == 0 && board.bad_shape == 0 &&
		      board.bad_checksum == 0 && board.not_this_cable == 0,
	      "a link that has heard nothing does not start at zero");

	// A good frame from PEER to ME: the one road in.
	len = status_rfc(frame, "STATUS", 6);
	len = chudp_wrap(frame, len, good, sizeof good);
	CHECK(len > 0, "the good frame would not wrap");
	one_datagram(&board, far.fd, &board_at, good, len, &h);
	CHECK(board.delivered == 1 && h.n == 1, "the good frame was not delivered: %lu delivered, "
	      "%u heard", board.delivered, h.n);

	// **THE CHECKSUM, WHICH IS THE ONE REFUSAL THAT WAS ALREADY COUNTED.**
	// A data byte altered and the checksum left alone, which is what a
	// damaged datagram is.
	memcpy(bad, good, len);
	bad[20] ^= 0xffu;
	one_datagram(&board, far.fd, &board_at, bad, len, &h);
	CHECK(board.bad_checksum == 1, "a damaged datagram was not counted as one: %lu",
	      board.bad_checksum);

	// **THE SIX SHAPE RULES, EACH DRIVEN ONCE.**  What they have in common
	// is that `chudp_unwrap` refused and it was not the checksum; they
	// share a count for that reason, and the trace is what names which.
	{
		// Longer than any Chaos packet.
		memset(bad, 0, sizeof bad);
		bad[0] = CHUDP_VERSION;
		bad[1] = CHUDP_FUNCTION_PACKET;
		one_datagram(&board, far.fd, &board_at, bad, CHUDP_MAX_FRAME + 1u, &h);
		// Too short for a header, a packet and a trailer.
		one_datagram(&board, far.fd, &board_at, good, 3u, &h);
		// A version this does not speak.
		memcpy(bad, good, len);
		bad[0] = 2;
		one_datagram(&board, far.fd, &board_at, bad, len, &h);
		// A function that is not "here is a Chaos packet".
		memcpy(bad, good, len);
		bad[1] = 2;
		one_datagram(&board, far.fd, &board_at, bad, len, &h);
		// The count word's bytes swapped, which is an absurd count.
		memcpy(bad, good, len);
		bad[6] = good[7];
		bad[7] = good[6];
		one_datagram(&board, far.fd, &board_at, bad, len, &h);
		// Two bytes fewer than the data count wants.
		one_datagram(&board, far.fd, &board_at, good, len - 2u, &h);
		CHECK(board.bad_shape == 6, "six datagrams refused for their shape were "
		      "counted %lu times", board.bad_shape);
	}

	// **THE TWO ROADS THAT ARE NOT THE DATAGRAM'S FAULT.**  A frame
	// claiming a source this cable already carries, and a frame addressed
	// on the cable to a station a peer line names.  Nothing is wrong with
	// either datagram; they are somebody else's, and a leaf does not
	// forward them.
	{
		// The trailer's source is the second word from the end, and
		// the checksum has to be made again for the frame as altered
		// --- a frame refused for its checksum would be counted in the
		// wrong class and the check would not see which road was taken.
		const unsigned n = status_rfc(frame, "STATUS", 6);
		frame[n - 2u] = 0;		/* no station's address */
		frame[n - 1u] = chudp_checksum(frame, n - 1u);
		len = chudp_wrap(frame, n, bad, sizeof bad);
		CHECK(len > 0, "the sourceless frame would not wrap");
		one_datagram(&board, far.fd, &board_at, bad, len, &h);

		frame[n - 2u] = ME;		/* this cable's own address */
		frame[n - 1u] = chudp_checksum(frame, n - 1u);
		len = chudp_wrap(frame, n, bad, sizeof bad);
		one_datagram(&board, far.fd, &board_at, bad, len, &h);

		// And one addressed on the cable to the peer: the leaf rule.
		const unsigned m = frame_to(frame, HOST, CHAOS_RFC, "STATUS", 6);
		frame[m - 2u] = PEER;		/* somebody else put it on the cable */
		frame[m - 1u] = chudp_checksum(frame, m - 1u);
		len = chudp_wrap(frame, m, bad, sizeof bad);
		one_datagram(&board, far.fd, &board_at, bad, len, &h);
		CHECK(board.not_this_cable == 3, "three frames that are not this cable's were "
		      "counted %lu times", board.not_this_cable);
	}

	// **AND THE SUM CLOSES**, which is the whole statement: eleven
	// datagrams arrived, one came in, and every one of the other ten is in
	// exactly one of the three refusals.
	CHECK(board.received == 11, "eleven datagrams were sent and %lu arrived", board.received);
	CHECK(board.received == board.delivered + board.bad_shape + board.bad_checksum +
			       board.not_this_cable,
	      "the counters do not add up: %lu arrived against %lu delivered + %lu shape + "
	      "%lu checksum + %lu not this cable",
	      board.received, board.delivered, board.bad_shape, board.bad_checksum,
	      board.not_this_cable);
	CHECK(board.delivered == 1 && board.bad_shape == 6 && board.bad_checksum == 1 &&
		      board.not_this_cable == 3,
	      "the sum closes on the wrong classes: %lu delivered, %lu shape, %lu checksum, "
	      "%lu not this cable", board.delivered, board.bad_shape, board.bad_checksum,
	      board.not_this_cable);
	chudp_close(&board);
	chudp_close(&far);
}

// **THE TRACE IS SWITCHED WHILE THE PROGRAM RUNS, AND SAYS SO ONCE.**
//
// A board restarted to get a diagnostic is a board whose Lisp is lost to get
// it, so the flag is not the only way in: SIGUSR1 turns the trace on and
// SIGUSR2 off, and `cadr-console trace-chaos on|off` is what sends them.
// This process plays both the daemon and the person, which is the only honest
// way to see that a signal arrived at all.
//
// **WHAT -1 IS FOR.**  `chaos_trace_apply` answers -1 for "nothing to do", and
// there are two of those: nothing was asked, and what was asked is what the
// program is already doing.  The first is what keeps a run started with
// `--chaos-trace` from being turned off by the first pass of its own loop;
// the second is what keeps a second `on` from saying a second line.
static void check_the_trace_switches_while_it_runs(void)
{
	chaos_trace_signals();

	// Nothing asked yet: neither setting moves, and a run that began with
	// the flag stays on.
	CHECK(chaos_trace_apply(0) == -1, "the trace changed with nothing asked");
	CHECK(chaos_trace_apply(1) == -1, "a run started with --chaos-trace was turned off");

	raise(SIGUSR1);
	CHECK(chaos_trace_apply(0) == 1, "SIGUSR1 did not turn the trace on");
	// Asked again with the trace already on: nothing to say and nothing to
	// do, which is what makes a second `trace-chaos on` silent.
	CHECK(chaos_trace_apply(1) == -1, "a second SIGUSR1 turned the trace on again");

	raise(SIGUSR2);
	CHECK(chaos_trace_apply(1) == 0, "SIGUSR2 did not turn the trace off");
	CHECK(chaos_trace_apply(0) == -1, "a second SIGUSR2 turned the trace off again");

	// And on again, so that the switch is not a one-way door.
	raise(SIGUSR1);
	CHECK(chaos_trace_apply(0) == 1, "the trace would not come back on");
	raise(SIGUSR2);
	CHECK(chaos_trace_apply(1) == 0, "the trace would not go off again");

	signal(SIGUSR1, SIG_DFL);
	signal(SIGUSR2, SIG_DFL);
}

// --- the suite ------------------------------------------------------------

void chaos_test_udp(void)
{
	chaos_test_note("udp: CHUDP against a datagram written out byte by byte");
	check_the_frame_is_these_bytes();
	check_a_datagram_cbridge_sent_reads_and_writes_back();
	check_one_word_altered_fails_the_checksum();
	check_the_old_framing_is_refused();
	check_a_frame_goes_out_and_comes_back();
	check_an_odd_count_is_padded();
	check_the_check_word_is_swapped_at_the_edge();
	check_a_datagram_that_is_not_one_is_refused();
	chaos_test_note("udp: two links on the loopback");
	check_the_links();
	check_a_stranger_is_heard_and_nothing_is_learned();
	check_a_flag_that_says_who_is_on_the_cable_needs_the_cable();
	chaos_test_note("udp: every datagram that arrives is accounted for");
	check_every_datagram_is_accounted_for();
	check_the_trace_switches_while_it_runs();
}
