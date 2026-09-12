// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The transport and the three answering services, held on the build host:
// `chaos_ncp.c` and `chaos_services.c` against AIM-628 and against what muir
// does.  No board, no fabric, no socket and no cable --- the check hands the
// server packets and takes back what it wants to send, which is exactly the
// seam `chaos_face.c` sits on.
//
// **THE CLOCK IS THIS FILE'S OWN.**  Every instant is a literal nanosecond
// passed in, so the retransmission interval and the host-down interval are
// checked at the tick either side of them rather than by waiting.  Nothing
// here reads the wall clock, and the TIME service is fixed at
// CHAOS_TEST_UNIVERSAL for the same reason: two runs must do the same work.
//
// **THE FAKE SERVICE AND THE FAKE SESSION ARE THIS FILE'S TOO**, so that what
// is being checked is the transport and not a service.  They are muir's
// `Echo` and `EchoSession` from `tests/chaos.rs`: a service that accepts
// unless its argument is `NO`, and a session that offers back what it is
// sent.  A session is destroyed by the transport as soon as its connection
// ends, so what it saw is recorded in a `struct record` the check owns and
// the session only points at --- otherwise every assertion about a closed
// connection would be reading freed memory.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "chaos_ncp.h"
#include "chaos_test.h"

// The two ends every check uses: this server, and the peer asking it for
// things.  Both are addresses on subnet 6, the band's own.
#define SERVER 0003060
#define PEER   0003050

// ------------------------------------------------------------- the fixtures

// What a session wants sent at its next poll.
struct offer {
	enum chaos_out_kind kind;
	uint8_t op;
	unsigned len;
	uint8_t bytes[64];
	char text[CHAOS_REASON_MAX];
	uint16_t host;
	struct chaos_session *session;
};

// What one session saw.  Owned by the check, because the transport frees the
// session itself the moment its connection ends.
struct record {
	int opened, eofs, closed, destroyed;
	char reason[CHAOS_REASON_MAX];
	unsigned ndata, npolls;
	uint8_t last_op;
	uint8_t last[CHAOS_PKT_MAX_DATA];
	unsigned last_len;
	// Echo what arrives, as muir's `EchoSession` does.
	int echo;
	struct offer offers[8];
	unsigned noffers;
};

struct fake_session {
	struct chaos_session base;
	struct record *r;
};

static struct offer *push_offer(struct record *r, enum chaos_out_kind kind)
{
	if (r->noffers >= sizeof r->offers / sizeof r->offers[0]) {
		chaos_test_fail(__FILE__, __LINE__, "the check offered more than the fixture holds");
		return &r->offers[0];
	}
	struct offer *o = &r->offers[r->noffers++];
	memset(o, 0, sizeof *o);
	o->kind = kind;
	return o;
}

static void offer_data(struct record *r, uint8_t op, const void *bytes, unsigned len)
{
	struct offer *o = push_offer(r, CHAOS_OUT_DATA);
	o->op = op;
	o->len = len;
	if (len)
		memcpy(o->bytes, bytes, len);
}

static void offer_eof(struct record *r)
{
	push_offer(r, CHAOS_OUT_EOF);
}

static void offer_close(struct record *r, const char *reason)
{
	struct offer *o = push_offer(r, CHAOS_OUT_CLOSE);
	snprintf(o->text, sizeof o->text, "%s", reason);
}

static void offer_connect(struct record *r, uint16_t host, const char *contact,
			  struct chaos_session *s)
{
	struct offer *o = push_offer(r, CHAOS_OUT_CONNECT);
	o->host = host;
	o->session = s;
	snprintf(o->text, sizeof o->text, "%s", contact);
}

static void fs_opened(struct chaos_session *s, uint64_t now)
{
	(void)now;
	++((struct fake_session *)s)->r->opened;
}

static void fs_data(struct chaos_session *s, uint64_t now, uint8_t op, const uint8_t *bytes,
		    unsigned len)
{
	struct record *r = ((struct fake_session *)s)->r;
	(void)now;
	++r->ndata;
	r->last_op = op;
	r->last_len = len;
	if (len)
		memcpy(r->last, bytes, len);
	if (r->echo)
		offer_data(r, op, bytes, len);
}

static void fs_eof(struct chaos_session *s, uint64_t now)
{
	struct record *r = ((struct fake_session *)s)->r;
	(void)now;
	++r->eofs;
	if (r->echo)
		offer_eof(r);
}

static void fs_closed(struct chaos_session *s, uint64_t now, const char *reason)
{
	struct record *r = ((struct fake_session *)s)->r;
	(void)now;
	++r->closed;
	snprintf(r->reason, sizeof r->reason, "%s", reason ? reason : "");
}

static void fs_poll(struct chaos_session *s, uint64_t now, struct chaos_outq *q)
{
	struct record *r = ((struct fake_session *)s)->r;
	(void)now;
	++r->npolls;
	for (unsigned i = 0; i < r->noffers; ++i) {
		const struct offer *o = &r->offers[i];
		switch (o->kind) {
		case CHAOS_OUT_DATA:
			chaos_out_data(q, o->op, o->bytes, o->len);
			break;
		case CHAOS_OUT_EOF:
			chaos_out_eof(q);
			break;
		case CHAOS_OUT_CLOSE:
			chaos_out_close(q, o->text);
			break;
		case CHAOS_OUT_CONNECT:
			chaos_out_connect(q, o->host, o->text, o->session);
			break;
		}
	}
	r->noffers = 0;
}

static void fs_destroy(struct chaos_session *s)
{
	++((struct fake_session *)s)->r->destroyed;
	free(s);
}

static struct fake_session *session_new(struct record *r)
{
	struct fake_session *s = calloc(1, sizeof *s);
	s->base.opened = fs_opened;
	s->base.data = fs_data;
	s->base.eof = fs_eof;
	s->base.closed = fs_closed;
	s->base.poll = fs_poll;
	s->base.destroy = fs_destroy;
	s->r = r;
	return s;
}

// muir's `Echo`: accepts unless the argument is `NO`, which is how the check
// reaches the refusal path without a second service.
struct fake_service {
	struct chaos_service base;
	struct record *next_record;
	unsigned requests;
	char last_args[64];
	uint16_t last_from_host, last_from_index;
};

static void fsv_request(struct chaos_service *sv, uint64_t now, const char *args,
			uint16_t from_host, uint16_t from_index, struct chaos_response *r)
{
	struct fake_service *f = (struct fake_service *)sv;
	(void)now;
	++f->requests;
	snprintf(f->last_args, sizeof f->last_args, "%s", args);
	f->last_from_host = from_host;
	f->last_from_index = from_index;
	if (strcmp(args, "NO") == 0) {
		r->kind = CHAOS_RESP_REFUSE;
		snprintf(r->reason, sizeof r->reason, "Not today");
		return;
	}
	r->kind = CHAOS_RESP_ACCEPT;
	r->session = &session_new(f->next_record)->base;
}

static void fsv_destroy(struct chaos_service *sv)
{
	free(sv);
}

static struct fake_service *service_new(struct record *r)
{
	struct fake_service *f = calloc(1, sizeof *f);
	f->base.contact = "ECHO";
	f->base.request = fsv_request;
	f->base.destroy = fsv_destroy;
	f->next_record = r;
	return f;
}

// ------------------------------------------------------------- the plumbing

static uint16_t le(const uint8_t *b)
{
	return (uint16_t)((unsigned)b[0] | ((unsigned)b[1] << 8));
}

static void put_le(uint8_t *b, uint16_t v)
{
	b[0] = (uint8_t)v;
	b[1] = (uint8_t)(v >> 8);
}

// A packet arriving, built by hand: what the peer put in each field.
static void mk(struct chaos_packet *p, uint8_t op, uint16_t from_host, uint16_t from_index,
	       uint16_t to_host, uint16_t to_index, uint16_t number, uint16_t ack,
	       const void *data, unsigned len)
{
	memset(p, 0, sizeof *p);
	p->opcode = op;
	p->dest = to_host;
	p->dest_index = to_index;
	p->source = from_host;
	p->source_index = from_index;
	p->number = number;
	p->ack = ack;
	p->len = (uint16_t)len;
	if (len)
		memcpy(p->data, data, len);
}

static void mk_rfc(struct chaos_packet *p, uint16_t from_index, uint16_t number,
		   const char *contact)
{
	mk(p, CHAOS_RFC, PEER, from_index, SERVER, 0, number, 0, contact,
	   (unsigned)strlen(contact));
}

// muir's `next_from`: the next packet the server wants on the cable, if any.
static int next_from(struct chaos_server *h, uint64_t now, struct chaos_packet *p)
{
	uint16_t cable_dest = 0xffff;
	memset(p, 0, sizeof *p);
	if (!chaos_server_transmit(h, now, p, &cable_dest))
		return 0;
	if (cable_dest != p->dest)
		chaos_test_fail(__FILE__, __LINE__,
				"the cable destination %o is not the packet's %o",
				(unsigned)cable_dest, (unsigned)p->dest);
	return 1;
}

// Everything the server has to say at this instant, thrown away: used where
// what is wanted is the state afterwards and not the packets.
static void drain(struct chaos_server *h, uint64_t now)
{
	struct chaos_packet p;
	unsigned n = 0;
	while (next_from(h, now, &p))
		if (++n > 64) {
			chaos_test_fail(__FILE__, __LINE__, "the server will not stop talking");
			return;
		}
}

// ------------------------------------------------------- simple transactions

// **TIME IS A SIMPLE TRANSACTION.**  AIM-628 §5.8: an RFC to `TIME` evokes an
// ANS with the universal time in four bytes, least significant first, and no
// connection.  The ANS goes back to the asker's index, acknowledging the RFC.
static void time_answers_a_simple_transaction(void)
{
	chaos_test_note("TIME, and the refusal an unknown contact draws");
	struct chaos_server *h = chaos_server_new(SERVER);
	chaos_server_serve(h, chaos_time_new(CHAOS_TEST_UNIVERSAL));
	struct chaos_packet p, ans;

	mk_rfc(&p, 7, 01234, "TIME");
	chaos_server_handle(h, 100, &p);
	CHECK(next_from(h, 100, &ans), "an answer");
	CHECK(ans.opcode == CHAOS_ANS, "an ANS, not %03o", (unsigned)ans.opcode);
	CHECK(ans.dest == PEER && ans.dest_index == 7, "back to the asker's index");
	CHECK(ans.source == SERVER, "from this host: %06o", (unsigned)ans.source);
	CHECK(ans.source_index == 0, "and from no index, no connection having been made");
	CHECK(ans.ack == 01234, "acknowledging the RFC: %u", (unsigned)ans.ack);
	CHECK(ans.len == 4, "four bytes, not %u", (unsigned)ans.len);
	// Least-significant byte first, and pinned byte by byte: a 32-bit
	// number reassembled by the same rule that wrote it would agree with
	// itself whichever way round it went.
	CHECK(ans.data[0] == (uint8_t)CHAOS_TEST_UNIVERSAL, "byte 0 is the least significant");
	CHECK(ans.data[1] == (uint8_t)(CHAOS_TEST_UNIVERSAL >> 8), "byte 1");
	CHECK(ans.data[2] == (uint8_t)(CHAOS_TEST_UNIVERSAL >> 16), "byte 2");
	CHECK(ans.data[3] == (uint8_t)(CHAOS_TEST_UNIVERSAL >> 24), "byte 3 is the most");
	CHECK(chaos_server_connections(h) == 0, "no connection was made");
	CHECK(!next_from(h, 100, &ans), "and nothing more");

	// An unknown contact is refused with a CLS that names it, so that the
	// asker can say which of its requests failed.
	mk_rfc(&p, 9, 2, "NOSUCH");
	chaos_server_handle(h, 300, &p);
	struct chaos_packet cls;
	CHECK(next_from(h, 300, &cls), "a refusal");
	CHECK(cls.opcode == CHAOS_CLS, "a CLS, not %03o", (unsigned)cls.opcode);
	CHECK(cls.dest == PEER && cls.dest_index == 9, "back to the asker");
	CHECK(cls.ack == 2, "acknowledging the RFC it refuses");
	char reason[CHAOS_PKT_MAX_DATA + 1];
	memcpy(reason, cls.data, cls.len);
	reason[cls.len] = '\0';
	CHECK(strstr(reason, "NOSUCH") != NULL, "naming the contact: %s", reason);
	CHECK(chaos_server_connections(h) == 0, "and no connection");

	// §4.5: "The TIME and STATUS protocols ... will work through BRD
	// packets".  A BRD is "a subnet bit map followed by a contact name and
	// possible arguments", and the acknowledgement field is the map's
	// length in bytes; stripped of the map it is an RFC.
	uint8_t brd[8] = { 0xff, 0xff, 0xff, 0xff, 'T', 'I', 'M', 'E' };
	mk(&p, CHAOS_BRD, PEER, 10, 0, 0, 3, 4, brd, 8);
	chaos_server_handle(h, 400, &p);
	CHECK(next_from(h, 400, &ans), "an answer to a broadcast");
	CHECK(ans.opcode == CHAOS_ANS && ans.dest_index == 10, "an ANS to the asker's index");
	CHECK(ans.len == 4, "the time, the subnet map having been stripped");

	// A map of no bytes at all is an RFC already, and a map claiming more
	// bytes than the packet holds must not read past it.
	mk(&p, CHAOS_BRD, PEER, 11, 0, 0, 3, 0, "TIME", 4);
	chaos_server_handle(h, 500, &p);
	CHECK(next_from(h, 500, &ans) && ans.opcode == CHAOS_ANS, "a BRD with no map");
	mk(&p, CHAOS_BRD, PEER, 12, 0, 0, 3, 99, "TIME", 4);
	chaos_server_handle(h, 600, &p);
	CHECK(next_from(h, 600, &ans) && ans.opcode == CHAOS_CLS,
	      "a map longer than the packet leaves no contact name, and is refused");

	chaos_server_free(h);
}

// UPTIME "is similar to the TIME protocol, except that the contact name is
// UPTIME, and the time returned is actually an interval (in seconds)
// describing how long the host has been up."
static void uptime_answers_how_long_the_host_has_been_up(void)
{
	chaos_test_note("UPTIME");
	struct chaos_server *h = chaos_server_new(SERVER);
	chaos_server_serve(h, chaos_uptime_new(1000000000ull));
	struct chaos_packet p, ans;

	// Sixty and a half seconds after the host came up: sixty, the interval
	// being in whole seconds.
	mk_rfc(&p, 7, 5, "UPTIME");
	chaos_server_handle(h, 61500000000ull, &p);
	CHECK(next_from(h, 61500000000ull, &ans), "an answer");
	CHECK(ans.opcode == CHAOS_ANS && ans.len == 4, "an ANS of four bytes");
	CHECK(ans.data[0] == 60 && ans.data[1] == 0 && ans.data[2] == 0 && ans.data[3] == 0,
	      "sixty seconds, least significant byte first: %u %u %u %u", ans.data[0],
	      ans.data[1], ans.data[2], ans.data[3]);

	// And a question asked before the host came up is nought, not an
	// enormous interval read off an unsigned subtraction.
	mk_rfc(&p, 8, 6, "UPTIME");
	chaos_server_handle(h, 0, &p);
	CHECK(next_from(h, 0, &ans), "an answer before the host came up");
	CHECK(ans.data[0] == 0 && ans.data[1] == 0 && ans.data[2] == 0 && ans.data[3] == 0,
	      "nought seconds");
	chaos_server_free(h);
}

// **STATUS IS WHAT `HOSTAT` READS.**  AIM-628 §5.1, and MIT's own reader
// `HOSTAT-FORMAT-ANS-1` in `sys/network/chaos/chsaux.lisp`:
//
//   - the name is the bytes up to the first null in the first 32
//     (`STRING-SEARCH-CHAR 0 ... 0 32.`);
//   - a block is an identifier word and a count word, the count in 16-bit
//     WORDS and not in meters, so the reader steps `(+ I 2 CT)`;
//   - an identifier of 0o400 and up is a subnet block for subnet
//     `ID - 0o400`, whose meters are 32 bits each, low half first ---
//     `(DPB (AREF PKT (1+ J)) #o2020 (AREF PKT J))`.
static void status_answers_what_hostat_reads(void)
{
	chaos_test_note("STATUS, byte for byte as HOSTAT decodes it");
	struct chaos_server *h = chaos_server_new(SERVER);
	chaos_server_serve(h, chaos_status_new("MIT-OZ", 6));
	struct chaos_packet p, ans;
	mk_rfc(&p, 7, 01234, "STATUS");
	chaos_server_handle(h, 100, &p);
	CHECK(next_from(h, 100, &ans), "an answer");
	CHECK(ans.opcode == CHAOS_ANS, "an ANS");
	CHECK(ans.dest == PEER && ans.dest_index == 7, "back to the asker's index");
	CHECK(ans.ack == 01234, "acknowledging the RFC");
	CHECK(chaos_server_connections(h) == 0, "no connection was made");

	// 32 bytes of name, an identifier word, a count word, eight 32-bit
	// meters: the block is all there is.
	CHECK(ans.len == 32 + 4 + 8 * 4, "sixty-eight bytes, not %u", (unsigned)ans.len);
	CHECK(memcmp(ans.data, "MIT-OZ", 6) == 0, "the name the server was given");
	int padded = 1;
	for (unsigned i = 6; i < 32; ++i)
		if (ans.data[i] != 0)
			padded = 0;
	CHECK(padded, "padded with nulls to 32, not with spaces");

	// The identifier is "400 plus a subnet number", little-endian: subnet 6
	// is 0o406, whose two bytes differ, so the order is pinned and not
	// merely reassembled by the rule that wrote it.
	CHECK(ans.data[32] == 0006 && ans.data[33] == 0001,
	      "the identifier is 0o406 low byte first: %03o %03o", ans.data[32], ans.data[33]);
	CHECK(le(ans.data + 32) == 0400 + 6, "which reads as 0o400 plus subnet 6");
	CHECK(ans.data[34] == 16 && ans.data[35] == 0,
	      "a count of sixteen WORDS, low byte first: %u %u", ans.data[34], ans.data[35]);
	CHECK(le(ans.data + 34) == 8 * 2, "eight 32-bit meters are sixteen words");
	CHECK(ans.len == 32 + 4 + le(ans.data + 34) * 2, "and the count is the rest of it");
	int zero = 1;
	for (unsigned i = 36; i < ans.len; ++i)
		if (ans.data[i] != 0)
			zero = 0;
	CHECK(zero, "every meter is nought: this program keeps none, and says so truthfully");
	chaos_server_free(h);

	// A name longer than the field is cut, and the null that ends it
	// survives: MIT looks for one within the first 32 bytes and finds
	// nothing at all if the field is full.
	h = chaos_server_new(SERVER);
	chaos_server_serve(h, chaos_status_new("A-VERY-LONG-HOST-NAME-INDEED-AND-THEN-SOME", 6));
	chaos_server_handle(h, 100, &p);
	CHECK(next_from(h, 100, &ans), "an answer from the long-named host");
	CHECK(ans.data[31] == 0, "the name field still ends in a null");
	CHECK(memcmp(ans.data, "A-VERY-LONG-HOST-NAME-INDEED-AN", 31) == 0,
	      "cut at thirty-one bytes");
	chaos_server_free(h);
}

// ------------------------------------------------------------ the stream

// **A STREAM CONNECTION OPENS, MOVES DATA BOTH WAYS AND CLOSES**, as AIM-628
// §4.1 to §4.4 lay it out: RFC, then the server's OPN carrying its index, its
// initial packet number and its window and acknowledging the RFC; the user's
// STS; numbered data acknowledged in the header of what goes back or in an
// STS; EOF answered by EOF; CLS.
static void a_stream_opens_moves_data_and_closes(void)
{
	chaos_test_note("a stream connection, end to end");
	struct record rec;
	memset(&rec, 0, sizeof rec);
	rec.echo = 1;
	struct chaos_server *h = chaos_server_new(SERVER);
	struct fake_service *sv = service_new(&rec);
	chaos_server_serve(h, &sv->base);
	struct chaos_packet p, out, spare;

	mk_rfc(&p, 021, 100, "ECHO");
	chaos_server_handle(h, 0, &p);
	CHECK(next_from(h, 0, &out), "an OPN");
	CHECK(out.opcode == CHAOS_OPN, "an OPN, not %03o", (unsigned)out.opcode);
	CHECK(out.dest == PEER && out.dest_index == 021, "to the asker");
	CHECK(out.source_index != 0, "carrying the server's own index");
	CHECK(out.ack == 100, "acknowledging the RFC");
	CHECK(out.len == 4, "its data is the same as an STS's: a receipt and a window");
	CHECK(le(out.data) == 100, "the receipt is the RFC's number");
	CHECK(le(out.data + 2) >= 1, "and the window is at least one: %u", le(out.data + 2));
	CHECK(chaos_server_connections(h) == 1, "one connection");
	CHECK(!next_from(h, 0, &spare), "and nothing more");
	const uint16_t si = out.source_index;
	const uint16_t opn_number = out.number;
	const uint16_t our_window = le(out.data + 2);

	// The user's STS receipts the OPN and offers a window.  It wants
	// nothing back.
	uint8_t d[4];
	put_le(d, opn_number);
	put_le(d + 2, 5);
	mk(&p, CHAOS_STS, PEER, 021, SERVER, si, 101, opn_number, d, 4);
	chaos_server_handle(h, 10, &p);
	CHECK(!next_from(h, 10, &out), "an STS wants nothing back");

	// The sessions are asked for more only once the queue has drained, so
	// that what is already on its way keeps its place and one talkative
	// session cannot hold the cable.  With a refusal for somebody else
	// already queued, a transmit hands that over without asking this
	// connection's session for anything.
	const unsigned polls = rec.npolls;
	mk_rfc(&p, 077, 7, "NOSUCH");
	chaos_server_handle(h, 11, &p);
	CHECK(next_from(h, 11, &out) && out.opcode == CHAOS_CLS, "the refusal that was queued");
	CHECK(rec.npolls == polls, "and the open connection's session was not asked for more");

	// §4.3: an SNS asks for a status report, and an STS is the report.
	mk(&p, CHAOS_SNS, PEER, 021, SERVER, si, 0, opn_number, NULL, 0);
	chaos_server_handle(h, 12, &p);
	CHECK(next_from(h, 12, &out), "an STS in answer to an SNS");
	CHECK(out.opcode == CHAOS_STS, "an STS, not %03o", (unsigned)out.opcode);
	CHECK(le(out.data) == 100, "receipting what we have taken, which is the RFC");
	CHECK(le(out.data + 2) == our_window, "and offering the window the OPN offered");

	// "if an OPN is received for a connection which is not in the RFC-sent
	// state, it is simply discarded and an STS is sent."
	mk(&p, CHAOS_OPN, PEER, 021, SERVER, si, 55, opn_number, d, 4);
	chaos_server_handle(h, 14, &p);
	CHECK(next_from(h, 14, &out) && out.opcode == CHAOS_STS, "an STS for a stray OPN");
	CHECK(le(out.data) == 100, "and its number was not taken as one we had received");

	// Data in: echoed back, numbered after the OPN, and acknowledging ours
	// in its own header rather than in a separate STS.
	mk(&p, CHAOS_DAT, PEER, 021, SERVER, si, 101, opn_number, "hello", 5);
	chaos_server_handle(h, 20, &p);
	CHECK(rec.ndata == 1, "the session was handed the data");
	CHECK(rec.last_op == CHAOS_DAT && rec.last_len == 5 &&
	      memcmp(rec.last, "hello", 5) == 0, "all five bytes of it");
	CHECK(next_from(h, 20, &out), "the echo");
	CHECK(out.opcode == CHAOS_DAT, "a data packet");
	CHECK(out.len == 5 && memcmp(out.data, "hello", 5) == 0, "with the bytes back");
	CHECK(out.number == (uint16_t)(opn_number + 1), "numbered after the OPN: %u",
	      (unsigned)out.number);
	CHECK(out.ack == 101, "acknowledging our data");
	CHECK(out.source_index == si && out.dest_index == 021, "on the same connection");
	CHECK(!next_from(h, 20, &spare), "the acknowledgement rode on the echo, so no STS");
	const uint16_t echo_number = out.number;

	// A duplicate of our data draws an STS with a receipt, not a second
	// delivery: §3.8, "evidence of unnecessary retransmission".
	chaos_server_handle(h, 30, &p);
	CHECK(next_from(h, 30, &out), "an STS for the duplicate");
	CHECK(out.opcode == CHAOS_STS, "an STS, not %03o", (unsigned)out.opcode);
	CHECK(le(out.data) == 101, "receipting through our packet: %u", le(out.data));
	CHECK(rec.ndata == 1, "and the duplicate is not delivered a second time");
	CHECK(!next_from(h, 30, &spare), "and nothing else");

	// A packet that is not from the end we are talking to is not taken,
	// however well numbered it is: a connection is a pair of (host, index)
	// and not a host, and the same band can have several at once.
	mk(&p, CHAOS_DAT, PEER, 022, SERVER, si, 102, echo_number, "wrong", 5);
	chaos_server_handle(h, 32, &p);
	CHECK(rec.ndata == 1, "a packet from another index is not delivered");
	CHECK(!next_from(h, 32, &spare), "nor answered");

	// A data packet with an opcode of its own --- the data range is
	// "opcodes 200 through 277 ... and 300 through 377", and the FILE
	// protocol uses several of them for its marks --- is delivered with
	// that opcode and comes back with it, not with the default.
	mk(&p, CHAOS_DAT + 1, PEER, 021, SERVER, si, 102, echo_number, "mark", 4);
	chaos_server_handle(h, 33, &p);
	CHECK(rec.ndata == 2, "the second packet was delivered");
	CHECK(rec.last_op == CHAOS_DAT + 1, "with its own opcode: %03o", rec.last_op);
	CHECK(next_from(h, 33, &out), "the echo of it");
	CHECK(out.opcode == CHAOS_DAT + 1, "which keeps the opcode: %03o", (unsigned)out.opcode);
	CHECK(out.ack == 102, "acknowledging it");
	const uint16_t echo2_number = out.number;
	CHECK(echo2_number == (uint16_t)(echo_number + 1), "and numbered next");

	// One out of order is dropped and not answered: they retransmit.  Its
	// acknowledgement field still receipts the echo, which is what lets the
	// EOF below go out.
	mk(&p, CHAOS_DAT, PEER, 021, SERVER, si, 104, echo2_number, "skipped", 7);
	chaos_server_handle(h, 35, &p);
	CHECK(rec.ndata == 2, "an out-of-order packet is not delivered");
	CHECK(!next_from(h, 35, &spare), "nor answered");

	// An uncontrolled data packet is neither numbered nor acknowledged: it
	// goes straight up whatever the sequence is doing, and nothing goes
	// back for it.  Its own number, 999 here, is nonsense on purpose ---
	// nothing may read it.  The echo is turned off across it because what
	// is being checked is that the TRANSPORT sends nothing.
	rec.echo = 0;
	mk(&p, CHAOS_UNC, PEER, 021, SERVER, si, 999, echo2_number, "uncontrolled", 12);
	chaos_server_handle(h, 36, &p);
	rec.echo = 1;
	CHECK(rec.ndata == 3, "a UNC is delivered");
	CHECK(rec.last_op == CHAOS_UNC && rec.last_len == 12, "with its own opcode and its bytes");
	CHECK(!next_from(h, 36, &spare), "and draws nothing back");

	// EOF in, EOF back, §4.4.
	mk(&p, CHAOS_EOF, PEER, 021, SERVER, si, 103, echo2_number, NULL, 0);
	chaos_server_handle(h, 40, &p);
	CHECK(rec.eofs == 1, "the session was told");
	CHECK(rec.ndata == 3, "and an EOF is not data");
	CHECK(next_from(h, 40, &out), "an EOF back");
	CHECK(out.opcode == CHAOS_EOF && out.len == 0, "an EOF carries nothing");
	CHECK(out.ack == 103, "acknowledging theirs");
	const uint16_t eof_number = out.number;

	// CLS ends it, and the session is told the reason and then freed.
	mk(&p, CHAOS_CLS, PEER, 021, SERVER, si, 105, eof_number, "done", 4);
	chaos_server_handle(h, 50, &p);
	CHECK(chaos_server_connections(h) == 0, "closed");
	CHECK(rec.closed == 1, "the session was told once");
	CHECK(strcmp(rec.reason, "done") == 0, "with the reason: %s", rec.reason);
	CHECK(rec.destroyed == 1, "and freed exactly once");
	CHECK(!next_from(h, 50, &spare), "a CLS is not answered");

	// A refusal: the service's own reason goes back in a CLS and no
	// connection is made.
	struct record other;
	memset(&other, 0, sizeof other);
	sv->next_record = &other;
	mk_rfc(&p, 022, 200, "ECHO NO");
	chaos_server_handle(h, 60, &p);
	CHECK(strcmp(sv->last_args, "NO") == 0, "the argument reached the service: %s",
	      sv->last_args);
	CHECK(sv->last_from_host == PEER && sv->last_from_index == 022,
	      "and so did the asker's address and index");
	CHECK(next_from(h, 60, &out), "a refusal");
	CHECK(out.opcode == CHAOS_CLS && out.dest_index == 022, "a CLS to the asker");
	CHECK(out.len == 9 && memcmp(out.data, "Not today", 9) == 0, "with the service's reason");
	CHECK(chaos_server_connections(h) == 0, "and no connection");
	CHECK(other.destroyed == 0, "a refused request makes no session at all");

	chaos_server_free(h);
	CHECK(rec.destroyed == 1, "freeing the server does not free a session twice");
}

// **ONE CONTROLLED PACKET GOES AT A TIME, WHATEVER WINDOW THE OTHER END
// OFFERS.**  This is muir's measured rule, not the protocol's: the CADR's
// interface holds one packet and its microcode drains it a word a Unibus
// cycle, so a burst up to the window lost most of its packets into a full
// buffer and each loss cost half a second.  What the window has no room for
// waits in the connection's backlog, and the backlog is what this shows: the
// session is polled once and two packets come out of it, one per receipt.
static void one_controlled_packet_goes_at_a_time(void)
{
	chaos_test_note("one packet in flight, and the backlog behind it");
	struct record rec;
	memset(&rec, 0, sizeof rec);
	struct chaos_server *h = chaos_server_new(SERVER);
	struct fake_service *sv = service_new(&rec);
	chaos_server_serve(h, &sv->base);
	struct chaos_packet p, out;
	offer_data(&rec, CHAOS_DAT, "one", 3);
	offer_data(&rec, CHAOS_DAT, "two", 3);

	mk_rfc(&p, 021, 100, "ECHO");
	chaos_server_handle(h, 0, &p);
	CHECK(next_from(h, 0, &out) && out.opcode == CHAOS_OPN, "an OPN");
	const uint16_t si = out.source_index;
	const uint16_t opn_number = out.number;
	CHECK(!next_from(h, 0, &out), "nothing goes while the OPN is unreceipted");
	CHECK(rec.npolls == 0, "and the session is not even asked: there is no room");

	// The STS receipts the OPN, and one packet goes.
	uint8_t d[4];
	put_le(d, opn_number);
	put_le(d + 2, 5);
	mk(&p, CHAOS_STS, PEER, 021, SERVER, si, 101, opn_number, d, 4);
	chaos_server_handle(h, 10, &p);
	CHECK(next_from(h, 10, &out), "the first packet");
	CHECK(out.len == 3 && memcmp(out.data, "one", 3) == 0, "the first the session offered");
	CHECK(out.number == (uint16_t)(opn_number + 1), "numbered after the OPN");
	CHECK(rec.npolls == 1, "the session was polled once");
	CHECK(!next_from(h, 10, &out),
	      "and the second waits, though the window they offered is five");

	// The receipt for the first lets the second go, out of the backlog and
	// not out of a second poll.
	put_le(d, (uint16_t)(opn_number + 1));
	mk(&p, CHAOS_STS, PEER, 021, SERVER, si, 102, (uint16_t)(opn_number + 1), d, 4);
	chaos_server_handle(h, 20, &p);
	CHECK(next_from(h, 20, &out), "the second packet");
	CHECK(out.len == 3 && memcmp(out.data, "two", 3) == 0, "in the order offered");
	CHECK(out.number == (uint16_t)(opn_number + 2), "and numbered next");
	CHECK(rec.npolls == 1, "which came out of the backlog, not a second poll");

	// A session that asks to close: the CLS goes on the connection and the
	// connection is gone.  muir does not call `closed` here --- a session
	// that asked does not need telling --- but `destroy` still runs once.
	offer_close(&rec, "Goodbye");
	put_le(d, (uint16_t)(opn_number + 2));
	mk(&p, CHAOS_STS, PEER, 021, SERVER, si, 103, (uint16_t)(opn_number + 2), d, 4);
	chaos_server_handle(h, 30, &p);
	CHECK(next_from(h, 30, &out), "the session's CLS");
	CHECK(out.opcode == CHAOS_CLS, "a CLS, not %03o", (unsigned)out.opcode);
	CHECK(out.source_index == si && out.dest_index == 021, "on its own connection");
	CHECK(out.len == 7 && memcmp(out.data, "Goodbye", 7) == 0, "with its reason");
	CHECK(chaos_server_connections(h) == 0, "and the connection is gone");
	CHECK(rec.closed == 0, "a session that asked to close is not told that it closed");
	CHECK(rec.destroyed == 1, "but it is freed, exactly once");
	chaos_server_free(h);
}

// §3.8: "Retransmission occurs every 1/2 second."  Checked at the tick either
// side of it, which is the only way to tell a retransmission interval from a
// constant.
static void an_unreceipted_packet_goes_again(void)
{
	chaos_test_note("retransmission at half a second, and not before");
	struct record rec;
	memset(&rec, 0, sizeof rec);
	struct chaos_server *h = chaos_server_new(SERVER);
	chaos_server_serve(h, &service_new(&rec)->base);
	struct chaos_packet p, out;
	mk_rfc(&p, 021, 300, "ECHO");
	chaos_server_handle(h, 70, &p);
	CHECK(next_from(h, 70, &out) && out.opcode == CHAOS_OPN, "an OPN");
	const uint16_t number = out.number;

	CHECK(!next_from(h, 70 + CHAOS_RETRANSMIT_NS - 1, &out),
	      "nothing a nanosecond before the interval");
	CHECK(next_from(h, 70 + CHAOS_RETRANSMIT_NS, &out), "retransmitted at the interval");
	CHECK(out.opcode == CHAOS_OPN && out.number == number, "the same OPN, the same number");
	CHECK(!next_from(h, 70 + CHAOS_RETRANSMIT_NS, &out), "once, not for ever");
	CHECK(!next_from(h, 70 + 2 * CHAOS_RETRANSMIT_NS - 1, &out),
	      "and the interval starts again from the retransmission");
	CHECK(next_from(h, 70 + 2 * CHAOS_RETRANSMIT_NS, &out), "so it goes a third time");

	// And a receipt stops it: the packet is let go, not merely delayed.
	uint8_t d[4];
	put_le(d, number);
	put_le(d + 2, 5);
	mk(&p, CHAOS_STS, PEER, 021, SERVER, out.source_index, 301, number, d, 4);
	chaos_server_handle(h, 70 + 2 * CHAOS_RETRANSMIT_NS, &p);
	CHECK(!next_from(h, 70 + 10 * CHAOS_RETRANSMIT_NS, &out),
	      "a receipted packet never goes again");
	chaos_server_free(h);
}

// A connection silent past CHAOS_HOST_DOWN_NS is given up, as the band's
// `PROBE-CONN` moves a host to `HOST-DOWN-STATE`.  The comparison is strict,
// as the band's `(> DELTA-TIME HOST-DOWN-INTERVAL)` is, so this checks the
// nanosecond either side of it.
static void a_silent_peer_is_given_up(void)
{
	chaos_test_note("a connection given up after three minutes of silence");
	struct record rec;
	memset(&rec, 0, sizeof rec);
	struct chaos_server *h = chaos_server_new(SERVER);
	chaos_server_serve(h, &service_new(&rec)->base);
	struct chaos_packet p;
	mk_rfc(&p, 021, 100, "ECHO");
	chaos_server_handle(h, 0, &p);
	drain(h, 0);
	CHECK(chaos_server_connections(h) == 1, "one connection");

	drain(h, CHAOS_HOST_DOWN_NS);
	CHECK(chaos_server_connections(h) == 1, "still there at exactly three minutes");
	CHECK(rec.closed == 0, "and the session has not been told anything");
	drain(h, CHAOS_HOST_DOWN_NS + 1);
	CHECK(chaos_server_connections(h) == 0, "gone a nanosecond later");
	CHECK(rec.closed == 1, "the session was told");
	CHECK(strcmp(rec.reason, "Host down") == 0, "and why: %s", rec.reason);
	CHECK(rec.destroyed == 1, "and freed");

	// The index is free again, which is the point of giving up: an RFC
	// reusing the same (source, index) --- what a reboot of the same band
	// sends, its indices seeded from a clock the simulator repeats --- must
	// not be taken for a duplicate of the dead connection.
	mk_rfc(&p, 021, 200, "ECHO");
	chaos_server_handle(h, CHAOS_HOST_DOWN_NS + 2, &p);
	CHECK(chaos_server_connections(h) == 1, "and a fresh RFC from it is taken");
	chaos_server_free(h);

	// **AND THE RFC ITSELF MUST GIVE UP THE DEAD CONNECTION**, not merely
	// find it already gone.  Above, the dead one was reaped on the way past
	// by a call that wanted a packet; here nothing asks the server for a
	// packet between the silence and the RFC, which is the case muir's
	// comment is about, and the only thing that can clear the way is the
	// RFC's own sweep.
	struct record again;
	memset(&again, 0, sizeof again);
	struct chaos_server *g = chaos_server_new(SERVER);
	struct fake_service *sv = service_new(&again);
	chaos_server_serve(g, &sv->base);
	mk_rfc(&p, 021, 100, "ECHO");
	chaos_server_handle(g, 0, &p);
	drain(g, 0);
	CHECK(chaos_server_connections(g) == 1, "a connection, and now three minutes of silence");
	struct chaos_packet out;
	sv->next_record = &again;
	mk_rfc(&p, 021, 300, "ECHO");
	chaos_server_handle(g, CHAOS_HOST_DOWN_NS + 1, &p);
	CHECK(sv->requests == 2, "the RFC reached the service rather than being discarded");
	CHECK(chaos_server_connections(g) == 1, "one connection, the dead one having gone");
	CHECK(again.closed == 1 && strcmp(again.reason, "Host down") == 0,
	      "the dead session was told: %s", again.reason);
	CHECK(next_from(g, CHAOS_HOST_DOWN_NS + 1, &out) && out.opcode == CHAOS_OPN,
	      "and the new one was opened");
	CHECK(out.ack == 300, "acknowledging the second RFC and not the first");
	chaos_server_free(g);
}

// §4.1: "an NCP receives an RFC packet, it checks all pending RFC's and all
// connections which are in the Open or RFC-received state, to see if the
// source address and index match; if so, the RFC is a duplicate and is
// discarded."
static void a_duplicate_rfc_is_discarded(void)
{
	chaos_test_note("a duplicate RFC, and one from a different index");
	struct record a, b;
	memset(&a, 0, sizeof a);
	memset(&b, 0, sizeof b);
	struct chaos_server *h = chaos_server_new(SERVER);
	struct fake_service *sv = service_new(&a);
	chaos_server_serve(h, &sv->base);
	struct chaos_packet p, out;

	mk_rfc(&p, 021, 100, "ECHO");
	chaos_server_handle(h, 0, &p);
	CHECK(next_from(h, 0, &out) && out.opcode == CHAOS_OPN, "an OPN");
	CHECK(sv->requests == 1, "the service was asked once");

	chaos_server_handle(h, 1, &p);
	CHECK(!next_from(h, 1, &out), "the duplicate draws nothing at all, not even a CLS");
	CHECK(sv->requests == 1, "and the service is not asked again");
	CHECK(chaos_server_connections(h) == 1, "still one connection");

	// The same host at a different index is a different connection.
	sv->next_record = &b;
	mk_rfc(&p, 022, 100, "ECHO");
	chaos_server_handle(h, 2, &p);
	CHECK(next_from(h, 2, &out) && out.opcode == CHAOS_OPN, "a second OPN");
	CHECK(out.source_index != 0 && out.dest_index == 022, "on its own index");
	CHECK(sv->requests == 2, "and the service was asked again");
	CHECK(chaos_server_connections(h) == 2, "two connections");
	chaos_server_free(h);
	CHECK(a.destroyed == 1 && b.destroyed == 1, "both sessions freed");
}

// §4.2: "LOS is sent in response to situations such as: arrival of a data
// packet or an STS for a connection that does not exist".
static void a_packet_for_no_connection_draws_a_los(void)
{
	chaos_test_note("a packet for a connection that does not exist");
	struct chaos_server *h = chaos_server_new(SERVER);
	struct chaos_packet p, out;

	mk(&p, CHAOS_DAT, PEER, 021, SERVER, 99, 1, 0, "x", 1);
	chaos_server_handle(h, 0, &p);
	CHECK(next_from(h, 0, &out), "a LOS");
	CHECK(out.opcode == CHAOS_LOS, "a LOS, not %03o", (unsigned)out.opcode);
	CHECK(out.dest == PEER && out.dest_index == 021, "back to whoever sent it");
	CHECK(out.source_index == 99, "naming the index that does not exist: %u",
	      (unsigned)out.source_index);
	CHECK(out.len == 18 && memcmp(out.data, "No such connection", 18) == 0,
	      "with a reason a person can read");
	CHECK(chaos_server_connections(h) == 0, "and no connection was made by answering");

	// An STS draws one too; the memo names both.
	mk(&p, CHAOS_STS, PEER, 021, SERVER, 99, 1, 0, "\0\0\0\0", 4);
	chaos_server_handle(h, 10, &p);
	CHECK(next_from(h, 10, &out) && out.opcode == CHAOS_LOS, "an STS draws one as well");

	// A CLS or a LOS does not, or two hosts that have both forgotten a
	// connection would tell each other about it for ever.
	mk(&p, CHAOS_CLS, PEER, 021, SERVER, 99, 1, 0, "gone", 4);
	chaos_server_handle(h, 20, &p);
	CHECK(!next_from(h, 20, &out), "a CLS for nothing is not answered");
	mk(&p, CHAOS_LOS, PEER, 021, SERVER, 99, 1, 0, "gone", 4);
	chaos_server_handle(h, 30, &p);
	CHECK(!next_from(h, 30, &out), "and neither is a LOS");

	// Routing and maintenance are not this host's business either.
	mk(&p, CHAOS_RUT, PEER, 0, SERVER, 0, 0, 0, "\0\0\0\0", 4);
	chaos_server_handle(h, 40, &p);
	mk(&p, CHAOS_MNT, PEER, 0, SERVER, 0, 0, 0, NULL, 0);
	chaos_server_handle(h, 50, &p);
	CHECK(!next_from(h, 50, &out), "a RUT and an MNT are ignored");
	chaos_server_free(h);
}

// This host opening a connection of its own, §4.1: an RFC out, the connection
// in the RFC-sent state until the OPN comes back from an index we cannot know
// until it arrives.  The FILE service's data connections are made this way.
static void this_host_can_open_a_connection(void)
{
	chaos_test_note("a connection this host opens, and one its session opens");
	struct record rec, inner;
	memset(&rec, 0, sizeof rec);
	memset(&inner, 0, sizeof inner);
	struct chaos_server *h = chaos_server_new(SERVER);
	struct chaos_packet p, out;

	const uint16_t index = chaos_server_connect(h, 0, PEER, "FILE 1", &session_new(&rec)->base);
	CHECK(index != 0, "an index that is not zero, zero never being a connection");
	CHECK(chaos_server_connections(h) == 1, "one connection");
	CHECK(next_from(h, 0, &out), "an RFC");
	CHECK(out.opcode == CHAOS_RFC, "an RFC, not %03o", (unsigned)out.opcode);
	CHECK(out.dest == PEER && out.dest_index == 0, "to the host, at no index yet");
	CHECK(out.source == SERVER && out.source_index == index, "from ours");
	CHECK(out.number == 1 && out.ack == 0, "numbered one and acknowledging nothing");
	CHECK(out.len == 6 && memcmp(out.data, "FILE 1", 6) == 0,
	      "carrying the contact name and its argument");

	// The OPN answers it, from an index we did not know.
	uint8_t d[4];
	put_le(d, 1);
	put_le(d + 2, 3);
	mk(&p, CHAOS_OPN, PEER, 022, SERVER, index, 7, 1, d, 4);
	chaos_server_handle(h, 10, &p);
	CHECK(rec.opened == 1, "the session was told it was open");
	CHECK(next_from(h, 10, &out), "an STS");
	CHECK(out.opcode == CHAOS_STS, "an STS, not %03o", (unsigned)out.opcode);
	CHECK(out.dest_index == 022, "now addressed to their index");
	CHECK(le(out.data) == 7, "receipting the OPN: %u", le(out.data));
	CHECK(!next_from(h, 10, &out), "and nothing else");

	// **THE OPN ANSWERS THE RFC WHATEVER ITS ACKNOWLEDGEMENT FIELD SAYS**,
	// which is muir's own finding about the band rather than about the
	// memo: the band's OPN did not receipt the RFC, and the RFC went out
	// again every retransmission interval for the whole of a file
	// transfer.  Its acknowledgement above is 1, which does receipt it ---
	// so the case is made again below with an OPN that receipts nothing.
	CHECK(!next_from(h, 10 + 4 * CHAOS_RETRANSMIT_NS, &out),
	      "the RFC does not go again once the OPN has come");

	// The same, with an OPN whose acknowledgement field is nought.  The
	// clock only ever goes forward here, so `t` carries it along.
	uint64_t t = 10 + 4 * CHAOS_RETRANSMIT_NS;
	struct record second;
	memset(&second, 0, sizeof second);
	const uint16_t other = chaos_server_connect(h, t, PEER, "FILE 1",
						    &session_new(&second)->base);
	CHECK(next_from(h, t, &out) && out.opcode == CHAOS_RFC, "a second RFC");
	t += 10;
	mk(&p, CHAOS_OPN, PEER, 023, SERVER, other, 9, 0, d, 4);
	chaos_server_handle(h, t, &p);
	CHECK(next_from(h, t, &out) && out.opcode == CHAOS_STS, "an STS for it");
	t += 4 * CHAOS_RETRANSMIT_NS;
	CHECK(!next_from(h, t, &out), "and the RFC it did not receipt is still let go");

	// A session may open a connection of its own.
	t += 10;
	offer_connect(&rec, PEER, "O0001", &session_new(&inner)->base);
	CHECK(next_from(h, t, &out), "the session's own RFC");
	CHECK(out.opcode == CHAOS_RFC, "an RFC, not %03o", (unsigned)out.opcode);
	CHECK(out.dest == PEER && out.dest_index == 0, "to the host it named");
	CHECK(out.source_index != index && out.source_index != other, "on a fresh index");
	CHECK(out.len == 5 && memcmp(out.data, "O0001", 5) == 0, "with the contact it named");
	CHECK(chaos_server_connections(h) == 3, "three connections now");

	// An ANS answers a simple transaction this host started.  No service
	// here starts one, so the connection is simply closed; a client of the
	// transport would take the data first.  The ANS comes from index 0, the
	// answering end never having made a connection, which the RFC-sent
	// state is what lets through.
	struct record asked;
	memset(&asked, 0, sizeof asked);
	t += 10;
	chaos_server_connect(h, t, PEER, "TIME", &session_new(&asked)->base);
	CHECK(next_from(h, t, &out) && out.opcode == CHAOS_RFC, "an RFC for TIME");
	const uint16_t third = out.source_index;
	t += 10;
	mk(&p, CHAOS_ANS, PEER, 0, SERVER, third, 0, 1, "\1\2\3\4", 4);
	chaos_server_handle(h, t, &p);
	CHECK(asked.closed == 1, "the session was told the transaction ended");
	CHECK(strcmp(asked.reason, "answered") == 0, "with muir's own word: %s", asked.reason);
	CHECK(asked.destroyed == 1, "and freed");
	CHECK(chaos_server_connections(h) == 3, "and its index is free again");

	chaos_server_free(h);
	CHECK(rec.destroyed == 1 && second.destroyed == 1 && inner.destroyed == 1,
	      "every session freed exactly once");
}

void chaos_test_ncp(void)
{
	time_answers_a_simple_transaction();
	uptime_answers_how_long_the_host_has_been_up();
	status_answers_what_hostat_reads();
	a_stream_opens_moves_data_and_closes();
	one_controlled_packet_goes_at_a_time();
	an_unreceipted_packet_goes_again();
	a_silent_peer_is_given_up();
	a_duplicate_rfc_is_discarded();
	a_packet_for_no_connection_draws_a_los();
	this_host_can_open_a_connection();
}
