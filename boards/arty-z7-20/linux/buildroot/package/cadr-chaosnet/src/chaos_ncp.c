// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Chaosnet transport --- AIM-628 chapters 3 and 4: `muir::chaos::server`
// ported.  `chaos_ncp.h` says what each piece is and which of muir's
// decisions are kept; this file is those decisions carried out.
//
// **NOTHING HERE RE-DERIVES THE PROTOCOL.**  Every rule below is muir's, and
// where muir's comment says why a rule is what it is the reasoning is carried
// over rather than restated: those reasons are evidence in this project, and
// a reason rewritten from memory has stopped being one.  Where this file and
// `muir/src/chaos/server.rs` differ it is a bug here.
//
// **WHAT THE RUST SHAPES BECAME.**  `Vec<Option<Conn>>` is a grown array of
// pointers, NULL for a free slot, with slot 0 never a connection.
// `VecDeque<(u16, Packet, u64)>` --- the packets we have sent and not had
// receipted --- is a singly linked list, oldest first, which is the only
// order anything walks it in.  `VecDeque<Vec<u16>>`, muir's queue of buffers
// ready for the cable, is a list of whole packets with the cable destination
// beside each: the words are made at the seam (`chaos_face.c`), so a packet
// queued and a packet aborted are the same thing and `chaos_server_aborted`
// can put one back at the front without taking it apart.

#include "chaos_ncp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <cadr/cadr_log.h>

// Our receive window, told to the other end in every OPN and STS.  muir has
// it as a public field defaulting to 8 that nothing ever sets; here it is the
// constant it has always been in practice.  It is what we promise to take,
// not what we send: the one-packet-in-flight rule in `pump` governs sending,
// whatever window either end offers.
#define OUR_WINDOW 8u

enum state {
	// We sent an RFC and wait for the OPN, ANS or CLS.
	ST_RFC_SENT,
	// We sent an OPN and wait for the STS that acknowledges it; data may
	// already flow from them.
	ST_OPN_SENT,
	ST_OPEN
};

// One of our controlled packets, kept until it is receipted.
struct unacked {
	struct unacked *next;
	uint16_t number;
	// When it last went, so that `service_all` knows when it is due again.
	uint64_t last;
	struct chaos_packet p;
};

// One end of a connection at this host.
struct conn {
	enum state state;
	uint16_t remote_host;
	uint16_t remote_index;
	struct chaos_session *session;
	// The number the next controlled packet we send will carry.
	uint16_t next_number;
	struct unacked *unacked_head, *unacked_tail;
	// How many packets they will take: their window, from their OPN or
	// STS.  Kept because the protocol has it; the one-packet rule in
	// `pump` is what actually decides when we send.
	uint16_t their_window;
	// The number of the last in-order controlled packet we took from them,
	// and of the last one we acknowledged to them.
	uint16_t last_received;
	uint16_t last_acked;
	// Our receive window, told to them.
	uint16_t window;
	// When we last had a packet from the other end.  A connection silent
	// past CHAOS_HOST_DOWN_NS is given up, as the band gives up on a host,
	// so a dead connection is freed rather than retransmitting for ever
	// and holding its index against a fresh RFC.
	uint64_t last_heard;
	// What the session has offered that their window has not yet had room
	// for.
	struct chaos_outq backlog;
};

// A packet waiting for the cable, with the destination the interface is to
// put on the frame.
struct outpkt {
	struct outpkt *next;
	struct chaos_packet p;
	uint16_t cable_dest;
};

struct chaos_server {
	uint16_t address;
	struct chaos_service **services;
	unsigned nservices;
	// Connections by local index; index 0 is never a connection.
	struct conn **conns;
	unsigned nconns;
	struct outpkt *out_head, *out_tail;
	// Packets printed as they go by, for watching a run.
	int trace;
	// Our receive window for connections we accept.
	uint16_t window;
};

// ----------------------------------------------------------------- the wire
//
// The two-byte fields inside a packet's data --- the receipt and the window
// of an OPN or an STS --- are little-endian, AIM-628 §3.6 putting the first
// 8-bit byte of a 16-bit word "in the arithmetically least-significant
// position".

static uint16_t le16(const uint8_t *b)
{
	return (uint16_t)((unsigned)b[0] | ((unsigned)b[1] << 8));
}

static void put_le16(uint8_t *b, uint16_t v)
{
	b[0] = (uint8_t)v;
	b[1] = (uint8_t)(v >> 8);
}

// ------------------------------------------------------------------ tracing

static void fmt_end(char *into, size_t n, uint16_t host, uint16_t index)
{
	snprintf(into, n, "%o/%u", host, index);
}

// muir's `fmt_data`: a word count for 16-bit data, the text itself when all
// of it is printable, and a byte count otherwise.
static void fmt_data(const struct chaos_packet *p, char *into, size_t n)
{
	if (chaos_op_is_data(p->opcode) && p->opcode >= CHAOS_DWD) {
		snprintf(into, n, "%u words", (unsigned)p->len / 2u);
		return;
	}
	int printable = p->len > 0;
	for (unsigned i = 0; printable && i < p->len; ++i) {
		const uint8_t b = p->data[i];
		if (!((b >= 0x20 && b < 0x7f) || b == '\r' || b == '\n'))
			printable = 0;
	}
	if (!printable) {
		snprintf(into, n, "%u bytes", (unsigned)p->len);
		return;
	}
	size_t at = 0;
	if (at + 1 < n)
		into[at++] = '"';
	for (unsigned i = 0; i < p->len && at + 3 < n; ++i) {
		const uint8_t b = p->data[i];
		if (b == '\r' || b == '\n' || b == '"' || b == '\\') {
			into[at++] = '\\';
			into[at++] = b == '\r' ? 'r' : b == '\n' ? 'n' : (char)b;
		} else {
			into[at++] = (char)b;
		}
	}
	if (at + 1 < n)
		into[at++] = '"';
	into[at] = '\0';
}

// One trace line.  `when` is the instant for a packet arriving and empty for
// one going out, which is muir's own arrangement: a packet we send has no
// instant of its own, being queued now and leaving when the cable is free.
// The program's name is the prefix `say` already carries.
static void trace(const struct chaos_server *h, const char *when,
		  const struct chaos_packet *p)
{
	if (!h->trace)
		return;
	char from[24], to[24], name[8], what[160];
	fmt_end(from, sizeof from, p->source, p->source_index);
	fmt_end(to, sizeof to, p->dest, p->dest_index);
	fmt_data(p, what, sizeof what);
	say("%6s: %s -> %s %s %s", when, from, to,
	    chaos_op_name(p->opcode, name, sizeof name), what);
}

// ------------------------------------------------------------- the out queue

static void send_packet(struct chaos_server *h, const struct chaos_packet *p)
{
	struct outpkt *o = calloc(1, sizeof *o);
	if (!o) {
		say("out of memory queueing a packet for the cable");
		return;
	}
	o->p = *p;
	// muir: `let dest = p.dest; self.out.push_back(p.to_buffer(dest))`.
	// The cable destination is the packet's own destination; a bridge
	// forwarding a packet would put its next hop here instead, which is
	// why the two are separate words at all (AIM-628 §7).
	o->cable_dest = p->dest;
	trace(h, "", p);
	if (h->out_tail)
		h->out_tail->next = o;
	else
		h->out_head = o;
	h->out_tail = o;
}

// -------------------------------------------------------------- the packets

static void mkpacket(const struct chaos_server *h, struct chaos_packet *p, uint8_t op,
		     uint16_t to_host, uint16_t to_index, uint16_t from_index,
		     uint16_t number, uint16_t ack, const void *data, unsigned len)
{
	memset(p, 0, sizeof *p);
	p->opcode = op;
	p->forward = 0;
	p->dest = to_host;
	p->dest_index = to_index;
	p->source = h->address;
	p->source_index = from_index;
	p->number = number;
	p->ack = ack;
	if (len > CHAOS_PKT_MAX_DATA)
		len = CHAOS_PKT_MAX_DATA;
	p->len = (uint16_t)len;
	if (len)
		memcpy(p->data, data, len);
}

// ---------------------------------------------------------------- the table

// Frees an out queue, destroying the session inside any CHAOS_OUT_CONNECT
// still waiting in it: muir drops the `Box<dyn Session>` that `Out::Connect`
// carries when a connection's backlog is dropped, and a port that freed only
// the node would leak the session instead.
static void free_outq(struct chaos_outq *q)
{
	struct chaos_out *o;
	while ((o = chaos_outq_pop(q))) {
		if (o->kind == CHAOS_OUT_CONNECT && o->session && o->session->destroy)
			o->session->destroy(o->session);
		free(o);
	}
}

static void free_conn(struct conn *c)
{
	struct unacked *u = c->unacked_head;
	while (u) {
		struct unacked *next = u->next;
		free(u);
		u = next;
	}
	free_outq(&c->backlog);
	if (c->session && c->session->destroy)
		c->session->destroy(c->session);
	free(c);
}

static uint16_t free_index(struct chaos_server *h)
{
	// Index 0 is never a connection; reuse the lowest freed slot.
	for (unsigned i = 1; i < h->nconns; ++i)
		if (!h->conns[i])
			return (uint16_t)i;
	// No free slot: grow the table.  It reaches only the peak of
	// connections live at once, and a dead one is freed after
	// CHAOS_HOST_DOWN_NS, so it stays far below the 16 bits an index is
	// --- the band's own table is a few dozen slots (`chsncp.lisp`
	// MAXIMUM-INDEX).  Past 65,535 at once would be a leak, not traffic.
	if (h->nconns >= 0xffffu) {
		say("connection indices exhausted");
		return 0;
	}
	struct conn **grown = realloc(h->conns, (h->nconns + 1) * sizeof *grown);
	if (!grown) {
		say("out of memory making a connection");
		return 0;
	}
	h->conns = grown;
	h->conns[h->nconns] = NULL;
	++h->nconns;
	return (uint16_t)(h->nconns - 1);
}

static struct conn *at(struct chaos_server *h, uint16_t index)
{
	return index < h->nconns ? h->conns[index] : NULL;
}

static void close_conn(struct chaos_server *h, uint64_t now, uint16_t index, const char *reason)
{
	struct conn *c = at(h, index);
	if (!c)
		return;
	// Taken out of the table first, so that a session told it has closed
	// cannot be reached again by anything it does from inside `closed`.
	h->conns[index] = NULL;
	if (c->session && c->session->closed)
		c->session->closed(c->session, now, reason);
	free_conn(c);
}

// Gives up a connection silent past CHAOS_HOST_DOWN_NS, as the band's
// `PROBE-CONN` moves a host to `HOST-DOWN-STATE` when nothing has been
// received on it for that long (`sys/network/chaos/chsncp.lisp`): its
// unreceipted packets stop going again, its index is freed, and an RFC that
// reuses its (source, index) --- which a reboot of the same band sends, its
// indices seeded from a clock the simulator repeats --- is no longer taken
// for a duplicate.  The comparison is strict, as the band's
// `(> DELTA-TIME HOST-DOWN-INTERVAL)` is.
static void expire(struct chaos_server *h, uint64_t now)
{
	for (unsigned index = 1; index < h->nconns; ++index) {
		const struct conn *c = h->conns[index];
		// muir's `now.saturating_sub(c.last_heard)`: a clock that has
		// gone backwards must not make a connection look ancient.
		if (c && now > c->last_heard && now - c->last_heard > CHAOS_HOST_DOWN_NS)
			close_conn(h, now, (uint16_t)index, "Host down");
	}
}

// Keeps a controlled packet for retransmission until receipted.
static void remember(struct chaos_server *h, uint16_t index, const struct chaos_packet *p,
		     uint64_t now)
{
	struct conn *c = at(h, index);
	if (!c)
		return;
	struct unacked *u = calloc(1, sizeof *u);
	if (!u) {
		say("out of memory keeping a packet for retransmission");
		return;
	}
	u->number = p->number;
	u->p = *p;
	u->last = now;
	if (c->unacked_tail)
		c->unacked_tail->next = u;
	else
		c->unacked_head = u;
	c->unacked_tail = u;
}

// A receipt or acknowledgement of our packets up to `number`: muir's
// `retain(|&(n, _, _)| n.wrapping_sub(number) as i16 > 0)`, which keeps only
// what is still ahead of the receipt in the 16-bit number space, so that a
// number that has wrapped is still receipted by the right packet.
static void receipted(struct chaos_server *h, uint16_t index, uint16_t number)
{
	struct conn *c = at(h, index);
	if (!c)
		return;
	struct unacked **link = &c->unacked_head;
	c->unacked_tail = NULL;
	while (*link) {
		struct unacked *u = *link;
		if ((int16_t)(uint16_t)(u->number - number) > 0) {
			c->unacked_tail = u;
			link = &u->next;
		} else {
			*link = u->next;
			free(u);
		}
	}
}

// An STS: a receipt and our window, §4.3.  It is not a controlled packet, so
// it carries `next_number` without consuming it and is not remembered.
static void sts(struct chaos_server *h, uint16_t index)
{
	struct conn *c = at(h, index);
	if (!c)
		return;
	uint8_t data[4];
	put_le16(data, c->last_received);
	put_le16(data + 2, c->window);
	struct chaos_packet p;
	mkpacket(h, &p, CHAOS_STS, c->remote_host, c->remote_index, index, c->next_number,
		 c->last_received, data, sizeof data);
	c->last_acked = c->last_received;
	send_packet(h, &p);
}

// A refusal, its reason cut to the bytes a packet carries: a CLS is a
// controlled-nothing packet like any other, and a reason quoting a long
// contact name back could run past the data a packet holds --- the count word
// is twelve bits, so an over-long frame would go out past the interface's
// buffer (AIM-628 §3.5).  muir cuts at MAX_DATA; `chaos_ncp.h` fixes the
// shorter CHAOS_REASON_MAX for every reason this program sends, so the cut
// happens where the string is built and this only has to keep it.
static void refuse(struct chaos_server *h, uint16_t to_host, uint16_t to_index,
		   uint16_t number, const char *reason)
{
	struct chaos_packet p;
	mkpacket(h, &p, CHAOS_CLS, to_host, to_index, 0, number, number, reason,
		 (unsigned)strlen(reason));
	send_packet(h, &p);
}

// ------------------------------------------------------------------ pumping

// Sends what a session wants sent, as far as their window allows: AIM-628
// §3.8, "The sending process is only allowed to emit packets whose packet
// numbers lie within the window."  What the window has no room for waits in
// the connection's backlog for the next receipt.
static void pump(struct chaos_server *h, uint64_t now, uint16_t index)
{
	for (;;) {
		struct conn *c = at(h, index);
		if (!c)
			return;
		// **ONE CONTROLLED PACKET IN FLIGHT AT A TIME, WHATEVER WINDOW
		// THE OTHER END OFFERS, AND THIS WAS MEASURED RATHER THAN
		// CHOSEN.**  muir's own comment, kept because it is the
		// evidence: the CADR's interface holds one packet, and its
		// microcode drains it a word a Unibus cycle --- six
		// microseconds a pair when the disk is busy --- so a burst up
		// to the window lost most of its packets into the interface's
		// full buffer, and each loss cost a CHAOS_RETRANSMIT_NS: CC's
		// files came at a kilobyte a second and stalled for tens of
		// seconds.  Waiting for the receipt of each packet before the
		// next is what a careful host did, and it moves a file at the
		// other end's acknowledgement rate, some three milliseconds a
		// packet.  That was measured against this very machine's
		// microcode, so it is if anything more true on the board than
		// it was in muir.
		if (c->unacked_head)
			return;
		struct chaos_out *next = chaos_outq_pop(&c->backlog);
		if (!next) {
			if (!c->session || !c->session->poll)
				return;
			c->session->poll(c->session, now, &c->backlog);
			next = chaos_outq_pop(&c->backlog);
			if (!next)
				return;
		}
		// A session's `poll` can have opened connections of its own, so
		// the table is looked at again rather than held across it.
		c = at(h, index);
		if (!c) {
			if (next->kind == CHAOS_OUT_CONNECT && next->session &&
			    next->session->destroy)
				next->session->destroy(next->session);
			free(next);
			return;
		}
		const uint16_t to_host = c->remote_host;
		const uint16_t to_index = c->remote_index;
		const uint16_t number = c->next_number;
		const uint16_t ack = c->last_received;
		struct chaos_packet p;
		if (next->kind == CHAOS_OUT_CONNECT) {
			// A connection of the session's own: an RFC goes out on
			// a fresh index and this connection carries on.  The
			// FILE service's data connections are made this way,
			// the server calling the contact name the user end
			// listens on.
			chaos_server_connect(h, now, next->host, next->text, next->session);
			free(next);
			continue;
		}
		if (next->kind == CHAOS_OUT_CLOSE) {
			mkpacket(h, &p, CHAOS_CLS, to_host, to_index, index, number, ack,
				 next->text, (unsigned)strlen(next->text));
			free(next);
			send_packet(h, &p);
			// The session asked for the connection to end, so it is
			// not told that it ended: muir drops the `Conn` here,
			// which runs the session's destructor and never
			// `closed`.  `destroy` still runs exactly once, which
			// is the invariant `chaos_ncp.h` names.
			struct conn *dying = at(h, index);
			if (dying) {
				h->conns[index] = NULL;
				free_conn(dying);
			}
			return;
		}
		if (next->kind == CHAOS_OUT_EOF) {
			mkpacket(h, &p, CHAOS_EOF, to_host, to_index, index, number, ack,
				 NULL, 0);
		} else {
			// A session that offers more than a packet carries is a
			// bug in the session, which `chaos_out_data` already
			// refuses; muir asserts it here and this says so.
			if (next->len > CHAOS_PKT_MAX_DATA)
				say("a session offered %u bytes", (unsigned)next->len);
			mkpacket(h, &p, next->op ? next->op : CHAOS_DAT, to_host, to_index,
				 index, number, ack, next->bytes, next->len);
		}
		free(next);
		c = at(h, index);
		if (c) {
			c->next_number = (uint16_t)(c->next_number + 1u);
			// The acknowledgement rides on this packet, so nothing
			// more owes them an STS.
			c->last_acked = c->last_received;
		}
		remember(h, index, &p, now);
		send_packet(h, &p);
	}
}

// ------------------------------------------------------------------ inbound

// A controlled packet in: taken in order, receipted otherwise.
static void controlled(struct chaos_server *h, uint64_t now, uint16_t index,
		       const struct chaos_packet *p)
{
	struct conn *c = at(h, index);
	if (!c)
		return;
	if (c->state == ST_OPN_SENT) {
		// Data may arrive before the STS: "the user process may begin
		// transmitting data when it sees the OPN."
		c->state = ST_OPEN;
	}
	const uint16_t expected = (uint16_t)(c->last_received + 1u);
	if (p->opcode == CHAOS_UNC) {
		// An uncontrolled data packet is neither numbered nor
		// acknowledged, so it goes straight up whatever the sequence
		// is doing.
		if (c->session && c->session->data)
			c->session->data(c->session, now, p->opcode, p->data, p->len);
		return;
	}
	if (p->number == expected) {
		c->last_received = p->number;
		if (c->session) {
			if (p->opcode == CHAOS_EOF) {
				if (c->session->eof)
					c->session->eof(c->session, now);
			} else if (c->session->data) {
				c->session->data(c->session, now, p->opcode, p->data, p->len);
			}
		}
		// An acknowledgement rides on our next packet; if the session
		// has nothing to say, an STS carries it.  §3.8 batches these at
		// a third of the window; here every packet is acknowledged,
		// which the protocol allows and keeps the other side moving.
		pump(h, now, index);
		c = at(h, index);
		if (c && c->last_acked != c->last_received)
			sts(h, index);
	} else if ((int16_t)(uint16_t)(p->number - expected) < 0) {
		// A duplicate: "evidence of unnecessary retransmission, and an
		// STS is generated to carry a receipt".
		sts(h, index);
	}
	// Out of order: dropped; they retransmit.
}

// The OPN that answers an RFC we sent: every unreceipted RFC on this
// connection is let go.  muir's reason, which is a fact about the band and
// not about the protocol: the OPN answers the RFC whatever its
// acknowledgement field says, because the band's OPN did not receipt it and
// the RFC went out again every retransmission interval for the whole of a
// file transfer.
static void forget_rfc(struct conn *c)
{
	struct unacked **link = &c->unacked_head;
	c->unacked_tail = NULL;
	while (*link) {
		struct unacked *u = *link;
		if (u->p.opcode == CHAOS_RFC) {
			*link = u->next;
			free(u);
		} else {
			c->unacked_tail = u;
			link = &u->next;
		}
	}
}

// A packet for one of our connections.
static void on_connection(struct chaos_server *h, uint64_t now, uint16_t index,
			  const struct chaos_packet *p)
{
	struct conn *c = at(h, index);
	if (!c) {
		// §4.2: "LOS is sent in response to situations such as: arrival
		// of a data packet or an STS for a connection that does not
		// exist".  A CLS or a LOS is not answered, or two hosts that
		// have both forgotten a connection would tell each other so for
		// ever.
		if (p->opcode != CHAOS_LOS && p->opcode != CHAOS_CLS) {
			static const char why[] = "No such connection";
			struct chaos_packet los;
			mkpacket(h, &los, CHAOS_LOS, p->source, p->source_index, index, 0, 0,
				 why, (unsigned)sizeof why - 1u);
			send_packet(h, &los);
		}
		return;
	}
	if ((c->remote_host != p->source || c->remote_index != p->source_index) &&
	    !(c->state == ST_RFC_SENT &&
	      (p->opcode == CHAOS_OPN || p->opcode == CHAOS_CLS ||
	       p->opcode == CHAOS_ANS || p->opcode == CHAOS_FWD))) {
		// Not the end we are talking to --- except that the answer to
		// an RFC comes from an index we cannot know until it arrives.
		return;
	}
	// Every packet's acknowledgement field receipts our packets.  A LOS is
	// the exception: it belongs to no connection and its fields carry
	// nothing.
	if (p->opcode != CHAOS_LOS)
		receipted(h, index, p->ack);
	// A packet from the other end means it is alive: the host-down timer
	// starts again from here.
	c = at(h, index);
	if (c)
		c->last_heard = now;
	switch (p->opcode) {
	case CHAOS_OPN:
		c = at(h, index);
		if (!c)
			return;
		if (c->state == ST_RFC_SENT) {
			forget_rfc(c);
			c->remote_host = p->source;
			c->remote_index = p->source_index;
			c->state = ST_OPEN;
			c->last_received = p->number;
			c->last_acked = p->number;
			if (p->len >= 4)
				c->their_window = le16(p->data + 2);
			sts(h, index);
			c = at(h, index);
			if (c && c->session && c->session->opened)
				c->session->opened(c->session, now);
			pump(h, now, index);
		} else {
			// "if an OPN is received for a connection which is not
			// in the RFC-sent state, it is simply discarded and an
			// STS is sent."
			sts(h, index);
		}
		break;
	case CHAOS_STS:
		if (p->len >= 4) {
			const uint16_t receipt = le16(p->data);
			const uint16_t window = le16(p->data + 2);
			receipted(h, index, receipt);
			c = at(h, index);
			if (c) {
				c->their_window = window;
				if (c->state == ST_OPN_SENT)
					c->state = ST_OPEN;
			}
			pump(h, now, index);
		}
		break;
	case CHAOS_SNS:
		sts(h, index);
		break;
	case CHAOS_CLS:
	case CHAOS_LOS: {
		char reason[CHAOS_REASON_MAX];
		const unsigned room = (unsigned)sizeof reason - 1u;
		const unsigned n = p->len < room ? p->len : room;
		memcpy(reason, p->data, n);
		reason[n] = '\0';
		close_conn(h, now, index, reason);
		break;
	}
	case CHAOS_ANS:
		// The answer to a simple transaction we started.  No service
		// here starts one, so the connection is simply closed; a client
		// of the transport would take the data first.
		close_conn(h, now, index, "answered");
		break;
	case CHAOS_EOF:
	case CHAOS_UNC:
		controlled(h, now, index, p);
		break;
	default:
		if (chaos_op_is_data(p->opcode))
			controlled(h, now, index, p);
		break;
	}
}

// A request for connection, from the packet's source, with the contact name
// and the arguments in its data.
static void rfc(struct chaos_server *h, uint64_t now, const struct chaos_packet *p)
{
	const uint16_t from_host = p->source;
	const uint16_t from_index = p->source_index;
	// A connection whose peer has fallen silent is given up first, so that
	// its (source, index) does not shadow this RFC: a reboot of the same
	// band reuses the index while the old connection is still in the table.
	expire(h, now);
	// §4.1: "an NCP receives an RFC packet, it checks all pending RFC's and
	// all connections which are in the Open or RFC-received state, to see
	// if the source address and index match; if so, the RFC is a duplicate
	// and is discarded."
	for (unsigned i = 1; i < h->nconns; ++i) {
		const struct conn *c = h->conns[i];
		if (c && c->remote_host == from_host && c->remote_index == from_index)
			return;
	}
	// The data as text: the contact name, then a space, then the service's
	// arguments.  muir's `String::from_utf8_lossy` keeps an embedded null
	// where a C string ends at one; a contact name is "a string of
	// uppercase letters, numbers, and ASCII punctuation" (§3.2), so nothing
	// legitimate is lost and a name carrying a null is refused here rather
	// than quoted back whole.
	char text[CHAOS_PKT_MAX_DATA + 1u];
	memcpy(text, p->data, p->len);
	text[p->len] = '\0';
	char *args = strchr(text, ' ');
	if (args)
		*args++ = '\0';
	else
		args = text + strlen(text);
	struct chaos_service *sv = NULL;
	for (unsigned i = 0; i < h->nservices; ++i) {
		if (h->services[i]->contact && strcmp(h->services[i]->contact, text) == 0) {
			sv = h->services[i];
			break;
		}
	}
	if (!sv) {
		// The reason quotes the name back so that the asker can tell
		// which of its requests failed.  The precision is a literal
		// rather than a computed bound, so that the fit is plain to a
		// reader and to the compiler alike: 27 characters of prose and
		// 160 of contact name are inside CHAOS_REASON_MAX, and a name
		// longer than that is cut rather than making the CLS too long
		// for a packet.
		_Static_assert(CHAOS_REASON_MAX >= 27 + 160 + 1,
			       "a refusal naming a contact must fit its buffer");
		char why[CHAOS_REASON_MAX];
		snprintf(why, sizeof why, "No server for contact name %.160s", text);
		refuse(h, from_host, from_index, p->number, why);
		return;
	}
	struct chaos_response r;
	memset(&r, 0, sizeof r);
	// A service that fills nothing in refuses.  An ANS of no bytes is a
	// thing a service may mean, so it has to be said rather than be what
	// silence gives.
	r.kind = CHAOS_RESP_REFUSE;
	snprintf(r.reason, sizeof r.reason, "The service gave no answer");
	sv->request(sv, now, args, from_host, from_index, &r);
	switch (r.kind) {
	case CHAOS_RESP_ANSWER: {
		// §4.1: the ANS goes back to the asker's index, acknowledging
		// the RFC, and no connection is made.
		struct chaos_packet ans;
		mkpacket(h, &ans, CHAOS_ANS, from_host, from_index, 0, p->number, p->number,
			 r.answer, r.len);
		send_packet(h, &ans);
		break;
	}
	case CHAOS_RESP_REFUSE:
		refuse(h, from_host, from_index, p->number, r.reason);
		break;
	case CHAOS_RESP_ACCEPT: {
		if (!r.session) {
			say("a service accepted a connection with no session");
			refuse(h, from_host, from_index, p->number,
			       "No session for the connection");
			break;
		}
		const uint16_t index = free_index(h);
		struct conn *c = index ? calloc(1, sizeof *c) : NULL;
		if (!c) {
			if (r.session->destroy)
				r.session->destroy(r.session);
			refuse(h, from_host, from_index, p->number, "No free connection index");
			break;
		}
		// §4.1: the OPN "conveys the server's index number ... its data
		// field is the same as that of STS", a receipt and a window;
		// its acknowledgement field acknowledges the RFC.
		const uint16_t initial = 1;
		c->state = ST_OPN_SENT;
		c->remote_host = from_host;
		c->remote_index = from_index;
		c->session = r.session;
		c->next_number = (uint16_t)(initial + 1u);
		c->their_window = 1;
		c->last_received = p->number;
		c->last_acked = p->number;
		c->window = h->window;
		c->last_heard = now;
		h->conns[index] = c;
		uint8_t data[4];
		put_le16(data, p->number);
		put_le16(data + 2, h->window);
		struct chaos_packet opn;
		mkpacket(h, &opn, CHAOS_OPN, from_host, from_index, index, initial, p->number,
			 data, sizeof data);
		remember(h, index, &opn, now);
		send_packet(h, &opn);
		break;
	}
	}
}

// Lets every session send what it has, and retransmits what has gone
// unreceipted too long.
static void service_all(struct chaos_server *h, uint64_t now)
{
	// Give up connections whose peer has gone silent before doing any more
	// work for them.
	expire(h, now);
	for (unsigned index = 1; index < h->nconns; ++index) {
		if (h->conns[index])
			pump(h, now, (uint16_t)index);
		struct conn *c = h->conns[index];
		if (!c)
			continue;
		for (struct unacked *u = c->unacked_head; u; u = u->next) {
			if (now >= u->last && now - u->last >= CHAOS_RETRANSMIT_NS) {
				u->last = now;
				send_packet(h, &u->p);
			}
		}
	}
}

// --------------------------------------------------------------- the server

struct chaos_server *chaos_server_new(uint16_t address)
{
	struct chaos_server *h = calloc(1, sizeof *h);
	if (!h) {
		say("out of memory making a Chaosnet server");
		return NULL;
	}
	// Index 0 is never a connection, so the table starts as the one slot
	// that is always empty.
	h->conns = calloc(1, sizeof *h->conns);
	if (!h->conns) {
		say("out of memory making a Chaosnet server");
		free(h);
		return NULL;
	}
	h->address = address;
	h->nconns = 1;
	h->window = OUR_WINDOW;
	return h;
}

void chaos_server_free(struct chaos_server *h)
{
	if (!h)
		return;
	for (unsigned i = 1; i < h->nconns; ++i)
		if (h->conns[i])
			// Neither the peer nor the session is told: the program
			// is going away, not the connection.
			free_conn(h->conns[i]);
	free(h->conns);
	for (unsigned i = 0; i < h->nservices; ++i)
		if (h->services[i] && h->services[i]->destroy)
			h->services[i]->destroy(h->services[i]);
	free(h->services);
	struct outpkt *o = h->out_head;
	while (o) {
		struct outpkt *next = o->next;
		free(o);
		o = next;
	}
	free(h);
}

void chaos_server_serve(struct chaos_server *h, struct chaos_service *sv)
{
	if (!h || !sv)
		return;
	struct chaos_service **grown = realloc(h->services, (h->nservices + 1) * sizeof *grown);
	if (!grown) {
		say("out of memory adding the %s service", sv->contact ? sv->contact : "?");
		if (sv->destroy)
			sv->destroy(sv);
		return;
	}
	h->services = grown;
	h->services[h->nservices++] = sv;
}

uint16_t chaos_server_address(const struct chaos_server *h)
{
	return h->address;
}

unsigned chaos_server_connections(const struct chaos_server *h)
{
	unsigned n = 0;
	for (unsigned i = 1; i < h->nconns; ++i)
		if (h->conns[i])
			++n;
	return n;
}

void chaos_server_trace(struct chaos_server *h, int on)
{
	h->trace = on;
}

void chaos_server_handle(struct chaos_server *h, uint64_t now, const struct chaos_packet *p)
{
	if (h->trace) {
		char when[24];
		snprintf(when, sizeof when, "%llu", (unsigned long long)now);
		trace(h, when, p);
	}
	switch (p->opcode) {
	case CHAOS_RFC:
		rfc(h, now, p);
		break;
	case CHAOS_BRD: {
		// §4.5: "a subnet bit map followed by a contact name and
		// possible arguments"; the acknowledgement field is the map's
		// length in bytes.  Stripped, it is an RFC, which is how "the
		// TIME and STATUS protocols ... will work through BRD packets".
		struct chaos_packet q = *p;
		const unsigned skip = p->ack < p->len ? p->ack : p->len;
		q.opcode = CHAOS_RFC;
		q.len = (uint16_t)(p->len - skip);
		memmove(q.data, p->data + skip, q.len);
		rfc(h, now, &q);
		break;
	}
	case CHAOS_RUT:
	case CHAOS_MNT:
		// Routing and maintenance are not this host's to answer.
		break;
	default:
		on_connection(h, now, p->dest_index, p);
		break;
	}
}

uint16_t chaos_server_connect(struct chaos_server *h, uint64_t now, uint16_t host,
			      const char *contact, struct chaos_session *s)
{
	const uint16_t index = free_index(h);
	struct conn *c = index ? calloc(1, sizeof *c) : NULL;
	if (!c) {
		// An index of 0 is never a connection, so it is also how this
		// says it could not make one.  The session is destroyed here
		// because the caller has already given it up.
		say("cannot open a connection to %o for %s", host, contact ? contact : "?");
		if (s && s->destroy)
			s->destroy(s);
		return 0;
	}
	// AIM-628 §4.1: the connection is in the RFC-sent state until the OPN.
	const uint16_t initial = 1;
	c->state = ST_RFC_SENT;
	c->remote_host = host;
	c->remote_index = 0;
	c->session = s;
	c->next_number = (uint16_t)(initial + 1u);
	c->their_window = 1;
	c->last_received = 0;
	c->last_acked = 0;
	c->window = h->window;
	c->last_heard = now;
	h->conns[index] = c;
	struct chaos_packet rq;
	mkpacket(h, &rq, CHAOS_RFC, host, 0, index, initial, 0, contact,
		 contact ? (unsigned)strlen(contact) : 0u);
	remember(h, index, &rq, now);
	send_packet(h, &rq);
	return index;
}

int chaos_server_transmit(struct chaos_server *h, uint64_t now, struct chaos_packet *p,
			  uint16_t *cable_dest)
{
	// muir's `Node::transmit`: the sessions are asked for more only once
	// the queue has drained, so that what is already on its way keeps its
	// order and one talkative session cannot hold the cable.
	if (!h->out_head)
		service_all(h, now);
	struct outpkt *o = h->out_head;
	if (!o)
		return 0;
	h->out_head = o->next;
	if (!h->out_head)
		h->out_tail = NULL;
	if (p)
		*p = o->p;
	if (cable_dest)
		*cable_dest = o->cable_dest;
	free(o);
	return 1;
}

void chaos_server_aborted(struct chaos_server *h, const struct chaos_packet *p,
			  uint16_t cable_dest)
{
	// A frame aborted on interference goes again at the next turn, ahead of
	// anything queued since, as an interface's driver retries on Transmit
	// Abort.
	struct outpkt *o = calloc(1, sizeof *o);
	if (!o) {
		say("out of memory putting an aborted frame back");
		return;
	}
	o->p = *p;
	o->cable_dest = cable_dest;
	o->next = h->out_head;
	h->out_head = o;
	if (!h->out_tail)
		h->out_tail = o;
}
