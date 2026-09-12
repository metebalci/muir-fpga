// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Chaosnet over UDP, held to a datagram written out byte by byte and to a
// pair of links on the loopback.  `muir`'s `tests/chudp.rs` is the reference
// and this is that file's shape in C.
//
// **THE FRAME IS PINNED AS BYTES RATHER THAN LEFT IMPLICIT IN THE PACKING
// CODE**, and the reason is the whole reason this file exists: the byte order
// is **unverified**.  `CHUDP_PACKET_ORDER` and `CHUDP_TRAILER_ORDER` say what
// is believed and `chaos_udp.c`'s header says why and what would settle it;
// the protocol's author has said a version 2 may differ from version 1 in
// nothing but byte order.  So a correction must be a change to two constants
// and to one test, and `the_frame_is_these_bytes` below is that one test.  A
// check that built the datagram with the same code it was checking would
// agree with any order at all.
//
// **THE MIXED ORDER IS WHAT MAKES IT WORTH PINNING, AND THE DATA IS WHAT
// SHOWS IT IS NOT ARBITRARY.**  AIM-628 §3.6 puts the first byte of a pair in
// the word's least significant half, so `STATUS` comes out of a little-endian
// frame as `STATUS` and out of a big-endian one as `TSTASU`.  Bytes 20 to 25
// of the pinned datagram read `STATUS`.

#include "chaos_test.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "chaos_packet.h"
#include "chaos_udp.h"

// This machine, and the Chaosnet server on its cable: System 100's band's
// pair.  A peer over UDP, and one this machine was never told about.  muir's
// `tests/chudp.rs` names the same four, so a reader can put the two files
// side by side.
#define ME		03050u
#define SERVER		03060u
#define PEER		03040u
#define STRANGER	03041u

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

static void check_the_frame_is_these_bytes(void)
{
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	const unsigned n = status_rfc(frame, "STATUS", 6);
	CHECK(n == 14u, "the frame is %u words, wanting 14", n);
	// The check word `0o171007` is the CADR's own hardware CRC-16 over
	// these words --- the Fairchild 9401 at LMTBUF C09 --- and it is the
	// last two bytes of the datagram below, so the pinned bytes hold it
	// too.  What a CHUDP peer puts in that field is unverified, and nothing
	// here or in `chaos_udp.c` drops a packet on it.
	CHECK(frame[13] == 0171007u, "the hardware's check word is %o, wanting 171007",
	      (unsigned)frame[13]);

	uint8_t got[CHUDP_MAX_FRAME];
	memset(got, 0xAA, sizeof got);
	const unsigned len = chudp_wrap(frame, n, got, sizeof got);
	CHECK(len == 32u, "the datagram is %u bytes, wanting 32", len);

	// Four header bytes --- version 1, function 1, two arguments --- then
	// the Chaos packet's eight header words and its data, each word LEAST
	// significant byte first, and then the hardware trailer's destination,
	// source and check word, each MOST significant byte first.
	static const uint8_t want[32] = {
		/* version, function, and two argument bytes */
		0x01, 0x01, 0x00, 0x00,
		0x00, 0x01,		/* opcode: RFC in the high byte of the word */
		0x06, 0x00,		/* count: no forwarding, six data bytes */
		0x28, 0x06,		/* destination 3050 */
		0x00, 0x00,		/* destination index */
		0x20, 0x06,		/* source 3040 */
		0x11, 0x00,		/* source index 21 */
		0x01, 0x00,		/* packet number */
		0x00, 0x00,		/* acknowledge */
		'S', 'T', 'A', 'T', 'U', 'S',
		0x06, 0x28,		/* the trailer, in network order: destination 3050 */
		0x06, 0x20,		/* source 3040 */
		0xF2, 0x07		/* check word 171007 */
	};
	CHECK(memcmp(got, want, sizeof want) == 0,
	      "the datagram is not the frame this file pins");
	// Named one at a time as well, so a failure says WHICH half of the
	// frame moved rather than only that something did.
	CHECK(got[0] == 1u && got[1] == 1u, "the header is version %u function %u, wanting 1 and 1",
	      (unsigned)got[0], (unsigned)got[1]);
	CHECK(got[2] == 0u && got[3] == 0u, "the two argument bytes are not zero");
	CHECK(memcmp(got + 20, "STATUS", 6) == 0,
	      "the data does not read in order, which is the packet's order");
	CHECK(got[26] == 0x06u && got[27] == 0x28u,
	      "the trailer's destination is not in network order");
	CHECK(got[30] == 0xF2u && got[31] == 0x07u,
	      "the trailer's check word is not in network order");

	// And the pinned bytes read back to the words they were made from,
	// which is the half a wrong `unwrap` would fail.
	uint16_t back[CHAOS_PKT_MAX_WORDS];
	const char *why = NULL;
	const unsigned m = chudp_unwrap(want, sizeof want, back, CHAOS_PKT_MAX_WORDS, &why);
	CHECK(m == n, "the pinned datagram reads back as %u words, wanting %u: %s", m, n,
	      why ? why : "");
	CHECK(m == n && memcmp(back, frame, (size_t)n * sizeof frame[0]) == 0,
	      "the pinned datagram does not read back to the frame it was made from");
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
		const unsigned m = chudp_unwrap(datagram, len, back, CHAOS_PKT_MAX_WORDS, &why);
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

// --- an odd data count, padded or not -------------------------------------

static void check_an_odd_count_is_taken_either_way(void)
{
	// The data is a whole number of 16-bit words on the cable, so `wrap`
	// pads it; `unwrap` finds the trailer from the end of the datagram
	// rather than from the count, so a peer that does NOT pad is read all
	// the same.  **Which a peer does is unverified**; one interoperation
	// settles it, and until then neither reading is refused.
	uint16_t frame[CHAOS_PKT_MAX_WORDS];
	uint8_t padded[CHUDP_MAX_FRAME], unpadded[CHUDP_MAX_FRAME];
	const unsigned n = status_rfc(frame, "odd", 3);
	const unsigned len = chudp_wrap(frame, n, padded, sizeof padded);
	CHECK(len == 4u + 16u + 4u + 6u, "the padded datagram is %u bytes, wanting 30", len);
	// The same datagram with the pad byte taken out.
	memcpy(unpadded, padded, 4u + 16u + 3u);
	memcpy(unpadded + 4u + 16u + 3u, padded + 4u + 16u + 4u, 6u);
	const unsigned shorter = len - 1u;
	CHECK(shorter == 4u + 16u + 3u + 6u, "the unpadded datagram is %u bytes", shorter);

	uint16_t a[CHAOS_PKT_MAX_WORDS], b[CHAOS_PKT_MAX_WORDS];
	const char *why = NULL;
	const unsigned na = chudp_unwrap(padded, len, a, CHAOS_PKT_MAX_WORDS, &why);
	CHECK(na == n, "the padded datagram does not read: %s", why ? why : "");
	const unsigned nb = chudp_unwrap(unpadded, shorter, b, CHAOS_PKT_MAX_WORDS, &why);
	CHECK(nb == n, "the unpadded datagram does not read: %s", why ? why : "");
	CHECK(na == nb && na == n && memcmp(a, b, (size_t)n * sizeof a[0]) == 0,
	      "padded and unpadded do not read to the same words");
	struct chaos_frame parsed;
	CHECK(nb == n && chaos_frame_parse(b, nb, &parsed, &why) == 0 &&
		      parsed.packet.len == 3u && memcmp(parsed.packet.data, "odd", 3) == 0,
	      "the unpadded datagram's data is not \"odd\"");
}

// --- what is refused, and by name -----------------------------------------

static void check_a_datagram_that_is_not_one_is_refused(void)
{
	uint16_t frame[CHAOS_PKT_MAX_WORDS], back[CHAOS_PKT_MAX_WORDS];
	uint8_t good[CHUDP_MAX_FRAME];
	const unsigned n = status_rfc(frame, "STATUS", 6);
	const unsigned len = chudp_wrap(frame, n, good, sizeof good);
	const char *why = NULL;
	CHECK(chudp_unwrap(good, len, back, CHAOS_PKT_MAX_WORDS, &why) == n,
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
		CHECK(chudp_unwrap(bad, len, back, CHAOS_PKT_MAX_WORDS, &why) == 0,
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
		CHECK(chudp_unwrap(bad, len, back, CHAOS_PKT_MAX_WORDS, &why) == 0,
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
	CHECK(chudp_unwrap(bad, len - 2u, back, CHAOS_PKT_MAX_WORDS, &why) == 0,
	      "two bytes fewer than the count wants was read");
	memset(bad + len, 0, 2);
	why = NULL;
	CHECK(chudp_unwrap(bad, len + 2u, back, CHAOS_PKT_MAX_WORDS, &why) == 0,
	      "two bytes more than the count wants was read");
	// The count word's two bytes swapped, which is the wrong order for that
	// field and gives an absurd twelve-bit count.
	memcpy(bad, good, len);
	const uint8_t hold = bad[6];
	bad[6] = bad[7];
	bad[7] = hold;
	why = NULL;
	CHECK(chudp_unwrap(bad, len, back, CHAOS_PKT_MAX_WORDS, &why) == 0,
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
	CHECK(chudp_unwrap(huge, CHUDP_MAX_FRAME + 1u, back, CHAOS_PKT_MAX_WORDS, &why) == 0,
	      "a datagram longer than any Chaos packet was read");
	CHECK(why && strstr(why, "longer"), "the refusal does not say it is too long: %s",
	      why ? why : "(nothing said)");

	// Shorter than a header, and a header and a trailer with no packet
	// between them: neither is a frame.
	why = NULL;
	CHECK(chudp_unwrap(good, 3u, back, CHAOS_PKT_MAX_WORDS, &why) == 0,
	      "three bytes were read as a packet");
	CHECK(why && strstr(why, "short"), "the refusal does not say it is too short: %s",
	      why ? why : "(nothing said)");
	why = NULL;
	CHECK(chudp_unwrap(good, CHUDP_HEADER + CHUDP_TRAILER, back, CHAOS_PKT_MAX_WORDS,
			   &why) == 0,
	      "a header and a trailer with no packet between them was read");
	why = NULL;
	CHECK(chudp_unwrap(good, 0u, back, CHAOS_PKT_MAX_WORDS, &why) == 0,
	      "an empty datagram was read as a packet");

	// And a frame that will not fit where the caller put it is refused
	// rather than written past the end of it.
	why = NULL;
	CHECK(chudp_unwrap(good, len, back, 4u, &why) == 0, "a 14-word frame went into room for 4");

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
	p.source = SERVER;
	p.len = 0;
	const unsigned fn = chaos_packet_frame(&p, PEER, SERVER, forward, CHAOS_PKT_MAX_WORDS);
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

	// **An endpoint is learned only when the run asked for it.**  Off by
	// default, because otherwise whatever can reach the port installs
	// itself in the address table under whatever Chaosnet address it
	// claims.  `c` is a link at an endpoint no flag named.
	uint16_t strange[CHAOS_PKT_MAX_WORDS];
	memset(&p, 0, sizeof p);
	p.opcode = CHAOS_RFC;
	p.dest = ME;
	p.source = STRANGER;
	p.len = 0;
	const unsigned xn = chaos_packet_frame(&p, ME, STRANGER, strange, CHAOS_PKT_MAX_WORDS);
	send_raw(c.fd, &a_at, strange, xn);
	send_raw(b.fd, &a_at, mine, mn);
	CHECK(wait_for(&a, &at_a, 3), "the board never heard the frame after the stranger's");
	CHECK(at_a.n == 3u, "the board heard %u frames, wanting 3 --- a stranger was heard "
	      "with no endpoint learned", at_a.n);
	CHECK(a.npeers == 1u, "the board learned an endpoint with learning off");

	// With learning on, the same stranger is heard and its endpoint is
	// taken from the packet's own source, which is where an answer would be
	// addressed.
	a.dynamic = 1;
	send_raw(c.fd, &a_at, strange, xn);
	CHECK(wait_for(&a, &at_a, 4), "the stranger was not heard with learning on");
	CHECK(a.npeers == 2u, "the board has %u peers, wanting 2", a.npeers);
	CHECK(a.npeers == 2u && a.peers[1].address == STRANGER && a.peers[1].learned,
	      "the endpoint learned is not the stranger's own source address");
	// And an answer to it goes where it was learned.
	uint16_t answer[CHAOS_PKT_MAX_WORDS];
	const unsigned an = frame_to(answer, STRANGER, CHAOS_CLS, "", 0);
	CHECK(chudp_send(&a, answer, an, STRANGER) == 1, "the answer did not go to the stranger");
	static struct heard at_c;
	CHECK(wait_for(&c, &at_c, 1), "the stranger never got its answer");

	// **A packet does not move an endpoint a flag named.**  An endpoint
	// typed on the command line is a statement about where a host is;
	// letting a packet redirect it would put the naming back in the hands
	// of whoever can reach the port, which is what leaving learning off by
	// default is for.  `d` is an endpoint the board has never seen, and it
	// claims to be 3040 --- the address `--udp-peer` put at `b`.
	struct chudp d;
	static struct heard at_d;
	CHECK(chudp_bind(&d, "127.0.0.1", 0) == 0, "the impostor's link would not bind");
	CHECK(chudp_add_peer(&d, spec) == 0, "%s was refused for the impostor", spec);
	// **The frame that follows a crafted one must teach the table
	// nothing.**  Every check below waits on something happening rather
	// than on nothing happening, which means a good frame behind the
	// crafted one --- and with learning ON, a good frame from 3040's own
	// endpoint claiming 3040 would put the table back where it was and
	// hide the very thing being tested.  This one's PACKET source is 0,
	// which is no station's address and so is never learned, while its
	// cable source is a real station so that it is still delivered.
	// Measured, not reasoned: with `mine` here instead, a `chudp_poll` that
	// moved a named endpoint went unnoticed.
	uint16_t quiet[CHAOS_PKT_MAX_WORDS];
	memset(&p, 0, sizeof p);
	p.opcode = CHAOS_RFC;
	p.dest = ME;
	p.source = 0;
	p.len = 0;
	const unsigned qn = chaos_packet_frame(&p, ME, PEER, quiet, CHAOS_PKT_MAX_WORDS);
	uint16_t impostor[CHAOS_PKT_MAX_WORDS];
	memset(&p, 0, sizeof p);
	p.opcode = CHAOS_RFC;
	p.dest = ME;
	p.source = PEER;
	p.len = 0;
	const unsigned in = chaos_packet_frame(&p, ME, PEER, impostor, CHAOS_PKT_MAX_WORDS);
	send_raw(d.fd, &a_at, impostor, in);
	send_raw(b.fd, &a_at, quiet, qn);
	CHECK(wait_for(&a, &at_a, 6), "the board never heard the frame after the impostor's");
	CHECK(a.npeers == 2u, "the board has %u peers after an impostor claimed 3040, wanting 2",
	      a.npeers);
	CHECK(a.peers[0].address == PEER && a.peers[0].where.sin_port == b_at.sin_port,
	      "a packet moved the endpoint a flag named");
	// And the answer goes where the flag said, not to whoever claimed the
	// address: the endpoint is what decides, so this is the check that
	// matters rather than the table's contents.
	uint16_t reply[CHAOS_PKT_MAX_WORDS];
	const unsigned rn = frame_to(reply, PEER, CHAOS_CLS, "", 0);
	CHECK(chudp_send(&a, reply, rn, PEER) == 1, "the answer to 3040 did not go");
	CHECK(wait_for(&b, &at_b, 4), "the answer did not go where the flag said 3040 was");
	chudp_poll(&d, 8, heard_deliver, &at_d);
	CHECK(at_d.n == 0u, "the answer went to whoever claimed the address");

	// **A LEARNED endpoint, on the other hand, moves.**  It is only ever
	// the last packet's word for where a host is, so the newest packet has
	// it: a host that moves is followed, and a host that is impersonated is
	// the price of having asked to learn.  3041 was learned at `c`; `d`
	// claims it, and the next answer goes to `d`.
	send_raw(d.fd, &a_at, strange, xn);
	send_raw(b.fd, &a_at, quiet, qn);
	CHECK(wait_for(&a, &at_a, 8), "the board never heard the frame after the move");
	CHECK(a.npeers == 2u, "the board has %u peers after 3041 moved, wanting 2", a.npeers);
	CHECK(chudp_send(&a, answer, an, STRANGER) == 1, "the answer to 3041 did not go");
	CHECK(wait_for(&d, &at_d, 1), "the answer did not follow 3041 to where it moved");
	chudp_poll(&c, 8, heard_deliver, &at_c);
	CHECK(at_c.n == 1u, "the answer still went to where 3041 used to be");

	chudp_close(&a);
	chudp_close(&b);
	chudp_close(&c);
	chudp_close(&d);
	CHECK(a.fd == -1 && b.fd == -1 && c.fd == -1 && d.fd == -1,
	      "a closed link still holds its socket");
}

// --- the suite ------------------------------------------------------------

void chaos_test_udp(void)
{
	chaos_test_note("udp: CHUDP against a datagram written out byte by byte");
	check_the_frame_is_these_bytes();
	check_a_frame_goes_out_and_comes_back();
	check_an_odd_count_is_taken_either_way();
	check_a_datagram_that_is_not_one_is_refused();
	chaos_test_note("udp: two links on the loopback");
	check_the_links();
}
