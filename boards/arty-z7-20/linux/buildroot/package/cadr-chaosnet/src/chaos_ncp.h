// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Chaosnet transport --- AIM-628 chapters 3 and 4 --- and the services
// that answer on it: `muir::chaos::server`, ported.
//
// A host keeps the packets addressed to it, runs the connection protocol, and
// hands what arrives to a service by contact name.  A service either answers
// a request outright --- the *simple transaction* of §4.1, RFC then ANS ---
// or accepts it as a *stream connection*, RFC, OPN, STS and then numbered
// data both ways, ended with EOF and CLS as §4.4 says.  Adding a service is
// one `struct chaos_service`; the transport does not know what any of them
// do.
//
// **WHAT RUST'S TRAITS BECOME HERE.**  `Service` and `Session` are trait
// objects in muir and are structs of function pointers here, with the
// implementation's own state reached from the struct's first member by the
// usual downcast.  `Response` and `Out` are tagged unions.  The one place the
// shapes genuinely differ is `Session::poll`, which returns a `Vec<Out>` in
// muir and appends to a caller-owned queue here, because a C function
// returning a vector of 500-byte structures would be a worse thing than the
// queue.
//
// **THE ONE-PACKET-IN-FLIGHT RULE IS muir's AND IS KEPT.**  `Server::pump`'s
// comment: whatever window the other end offers, one controlled packet goes
// at a time, "the CADR's interface holds one packet, and its microcode drains
// it a word a Unibus cycle --- six microseconds a pair when the disk is busy
// --- so a burst up to the window lost most of its packets into the
// interface's full buffer, and each loss cost a RETRANSMIT_NS: CC's files
// came at a kilobyte a second and stalled for tens of seconds."  That was
// measured against this very machine's microcode, so it is if anything more
// true on the board than in the emulator.

#ifndef CHAOS_NCP_H
#define CHAOS_NCP_H

#include <stdint.h>

#include "chaos_packet.h"

// How long before an unreceipted controlled packet goes again, §3.8:
// "Retransmission occurs every 1/2 second."
#define CHAOS_RETRANSMIT_NS 500000000ull

// How long a connection lives without a packet from the other end: the band's
// `HOST-DOWN-INTERVAL`, `(* 60. 90. 2)` sixtieths of a second, "3 minutes",
// `sys/network/chaos/chsncp.lisp`.
#define CHAOS_HOST_DOWN_NS 180000000000ull

// The longest a CLS or refusal reason may be: a CLS is a controlled-nothing
// packet like any other and its data must fit a packet (§3.5).
#define CHAOS_REASON_MAX 200u

// The longest contact name this will send or match.
#define CHAOS_CONTACT_MAX 64u

struct chaos_session;
struct chaos_server;

// ---------------------------------------------------------------- outbound

enum chaos_out_kind {
	// A data packet, `op` in the data range and the bytes.
	CHAOS_OUT_DATA,
	// An EOF, §4.4.
	CHAOS_OUT_EOF,
	// A CLS with `text` as its reason, ending the connection.
	CHAOS_OUT_CLOSE,
	// A new connection *from* this host to `text` at `host`, served by
	// `session` once open: an RFC goes out, and the session's `opened` is
	// called when the OPN comes back.  The FILE protocol's data
	// connections are made this way, the server calling the contact name
	// the user end listens on.
	CHAOS_OUT_CONNECT
};

struct chaos_out {
	struct chaos_out *next;
	enum chaos_out_kind kind;
	uint8_t op;
	uint16_t len;
	uint16_t host;
	struct chaos_session *session;
	char text[CHAOS_CONTACT_MAX > CHAOS_REASON_MAX ? CHAOS_CONTACT_MAX : CHAOS_REASON_MAX];
	uint8_t bytes[CHAOS_PKT_MAX_DATA];
};

// A queue of them, oldest first.
struct chaos_outq {
	struct chaos_out *head;
	struct chaos_out *tail;
};

// Appends a node and returns it for filling in, or NULL if out of memory
// (having said so).  `kind`, `next` and the lengths are set; the caller fills
// the rest.
struct chaos_out *chaos_outq_push(struct chaos_outq *q, enum chaos_out_kind kind);
struct chaos_out *chaos_outq_pop(struct chaos_outq *q);
void chaos_outq_clear(struct chaos_outq *q);

// The three common shapes, so a service does not repeat the filling in.
int chaos_out_data(struct chaos_outq *q, uint8_t op, const void *bytes, unsigned len);
int chaos_out_eof(struct chaos_outq *q);
int chaos_out_close(struct chaos_outq *q, const char *reason);
int chaos_out_connect(struct chaos_outq *q, uint16_t host, const char *contact,
		      struct chaos_session *session);

// ---------------------------------------------------------------- sessions

// One end of one stream connection at this host.
struct chaos_session {
	// The connection this host asked for is open: the OPN came back.
	void (*opened)(struct chaos_session *s, uint64_t now);
	// Data arrived: `op` in the data range, and the bytes.
	void (*data)(struct chaos_session *s, uint64_t now, uint8_t op,
		     const uint8_t *bytes, unsigned len);
	// The other side sent EOF.
	void (*eof)(struct chaos_session *s, uint64_t now);
	// The connection ended: a CLS or LOS from the other side with its
	// reason, or this end's own timeout.  The session is freed by the
	// transport straight after, through `destroy`.
	void (*closed)(struct chaos_session *s, uint64_t now, const char *reason);
	// What the session wants sent, appended to `q` in order.
	void (*poll)(struct chaos_session *s, uint64_t now, struct chaos_outq *q);
	// Frees the session's own storage.  Called exactly once, after
	// `closed`, and never by anything but the transport.
	void (*destroy)(struct chaos_session *s);
};

// ---------------------------------------------------------------- services

enum chaos_response_kind {
	// A simple transaction: the data of an ANS, and no connection.
	CHAOS_RESP_ANSWER,
	// A refusal: the reason, sent in a CLS.
	CHAOS_RESP_REFUSE,
	// A stream connection, served by this session.
	CHAOS_RESP_ACCEPT
};

struct chaos_response {
	enum chaos_response_kind kind;
	unsigned len;			// ANSWER: how much of `answer`
	uint8_t answer[CHAOS_PKT_MAX_DATA];
	char reason[CHAOS_REASON_MAX];	// REFUSE
	struct chaos_session *session;	// ACCEPT
};

// A service answering to a contact name.
struct chaos_service {
	// The contact name, AIM-628 §3.2: "a string of uppercase letters,
	// numbers, and ASCII punctuation".
	const char *contact;
	// A request for connection with this contact name arrived at `now`,
	// with `args` the rest of the RFC's data after the name, from
	// `from_host` and `from_index`.  Fills `r`.
	void (*request)(struct chaos_service *sv, uint64_t now, const char *args,
			uint16_t from_host, uint16_t from_index,
			struct chaos_response *r);
	// Frees the service.  May be NULL for a service with no storage.
	void (*destroy)(struct chaos_service *sv);
};

// The three services whose whole content is an answer.  `chaos_time_new`'s
// `fixed` is a universal time to answer with always, or 0 for the machine's
// clock --- which is what `--chaos-time` sets and what the tests fix so that
// two runs do the same work.
struct chaos_service *chaos_status_new(const char *name, uint8_t subnet);
struct chaos_service *chaos_time_new(uint32_t fixed);
struct chaos_service *chaos_uptime_new(uint64_t since_ns);

// Seconds from 1 January 1900 to 1 January 1970: the universal time of the
// Unix epoch, as the Lisp Machine counts time.
#define CHAOS_UNIX_EPOCH_UNIVERSAL 2208988800ull

// The universal time the tests fix a server's clock at: 1 September 2026,
// 00:00:00 UT, `muir::chaos::time::TEST_UNIVERSAL`.
#define CHAOS_TEST_UNIVERSAL 3997209600u

// ---------------------------------------------------------------- the host

// A server, at one address, with its services.
struct chaos_server *chaos_server_new(uint16_t address);
void chaos_server_free(struct chaos_server *h);

// Takes ownership of the service.
void chaos_server_serve(struct chaos_server *h, struct chaos_service *sv);

uint16_t chaos_server_address(const struct chaos_server *h);
unsigned chaos_server_connections(const struct chaos_server *h);

// Every packet the server handles or sends, printed as it goes: `--trace`,
// which is muir's `--chaos-trace`.
void chaos_server_trace(struct chaos_server *h, int on);

// One packet arrived at `now`, already known to be for this host or a
// broadcast.  Its check word is the caller's to have verified.
void chaos_server_handle(struct chaos_server *h, uint64_t now, const struct chaos_packet *p);

// Opens a connection from this host: an RFC to `contact` at `host`, §4.1.
// Returns the local index.  Takes ownership of the session.
uint16_t chaos_server_connect(struct chaos_server *h, uint64_t now, uint16_t host,
			      const char *contact, struct chaos_session *s);

// The next packet the server wants put on the cable, if any: 1 with `p` and
// `cable_dest` filled, 0 if it has nothing to say.  Calling it when the queue
// is empty lets every session send what it has and retransmits what has gone
// unreceipted too long, which is muir's `Node::transmit`.
int chaos_server_transmit(struct chaos_server *h, uint64_t now,
			  struct chaos_packet *p, uint16_t *cable_dest);

// A frame that was aborted on the cable goes again at the next turn, ahead of
// anything queued since, as an interface's driver retries on Transmit Abort.
void chaos_server_aborted(struct chaos_server *h, const struct chaos_packet *p,
			  uint16_t cable_dest);

#endif
