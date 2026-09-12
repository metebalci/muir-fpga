// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Chaosnet over UDP: `muir::chaos::udp` ported.  `chaos_udp.h` says what the
// frame is, which of it is unverified, and what every function here must do.
//
// The whole of the byte order lives in `put_word`, `get_word` and `odd_word`
// below, driven by `CHUDP_PACKET_ORDER` and `CHUDP_TRAILER_ORDER`.  That is
// deliberate and it is muir's reason: **the order is unverified**, the
// protocol's author has said a version 2 may differ from version 1 in nothing
// but byte order, and a correction should be a change to two constants and to
// one test --- `chaos_test_udp.c` pins one whole datagram's bytes for exactly
// that, as muir pins one in `tests/chudp.rs`.
//
// **WHAT IS BELIEVED, AND WHAT WOULD SETTLE IT.**  The Chaos packet's own
// sixteen-bit words are least significant byte first; the hardware trailer's
// three words are network order.  A mixed frame.  The packet's order is what
// the protocol's own documentation says in as many words ("I'm really sorry
// about this, and might develop version 2 of the protocol with the only
// change being big-endian byte order"), and it fits AIM-628 §3.6, which puts
// the first byte of a pair in the word's least significant half --- so the
// data bytes come out of a little-endian frame in the order they were
// written and out of a big-endian one swapped in pairs.  The trailer's order
// is belief and not knowledge: the reference implementation was read BY A
// PERSON as taking the trailer through `ntohs`, and how the packet's own
// bytes are assembled there was not traced.  What would settle either: a
// capture of a live exchange, or one interoperation.  **The wrong order fails
// loudly on the first packet** --- an absurd twelve-bit data count against
// the datagram's own length, which `chudp_unwrap` refuses by name, and
// addresses that match nothing configured --- so it does not fail quietly.
//
// Read from the Wireshark dissector published at
// `gist.github.com/ams/6bde1da514479e27c9f70c161b5537c1` and the protocol
// page at `chaosnet.net/protocol`, cross-read against the Computer History
// Wiki's Chaosnet page.  **Not** from `bictorv/chaosnet-bridge`, the
// reference implementation, whose author forbids language models to read or
// process it; that is the author's decision about the author's own work and
// it is kept here, as it is kept in muir.
//
// **THIS BOARD IS A LEAF, NOT A ROUTER**, as muir is.  AIM-628 chapter 6's
// routing is a bridge's job and `cbridge` is the thing to put beside this.
// Two halves of that rule are here and the third is the caller's:
// `chudp_send` drops a frame no peer claims rather than flooding it;
// `chudp_poll` drops a datagram addressed on the cable to another peer; and
// whether a destination is one of the addresses THIS cable carries --- the
// machine's and the Chaosnet server's --- only the caller knows, since
// `struct chudp` holds no list of them.

#include "chaos_udp.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cadr/cadr_log.h>

// The software header in bytes, AIM-628 §3.5: eight sixteen-bit words.  Named
// rather than written as 16 wherever the datagram's length is judged, because
// it is the one number in that arithmetic that is a header and not a count.
#define CHUDP_SOFTWARE_HEADER (CHAOS_PKT_HEADER_WORDS * 2u)

// --- a word's two bytes, in whichever order -------------------------------

static void put_word(enum chudp_order order, uint16_t w, uint8_t *at)
{
	if (order == CHUDP_LITTLE) {
		at[0] = (uint8_t)w;
		at[1] = (uint8_t)(w >> 8);
	} else {
		at[0] = (uint8_t)(w >> 8);
		at[1] = (uint8_t)w;
	}
}

static uint16_t get_word(enum chudp_order order, const uint8_t *at)
{
	return order == CHUDP_LITTLE ? (uint16_t)((unsigned)at[0] | (unsigned)at[1] << 8)
				     : (uint16_t)((unsigned)at[0] << 8 | (unsigned)at[1]);
}

// The word a lone trailing byte makes: it is the half that comes first, and
// the other half is not there.  A peer that does not pad an odd data count to
// a whole word produces one of these, and whether a peer pads is unverified.
static uint16_t odd_word(enum chudp_order order, uint8_t b)
{
	return order == CHUDP_LITTLE ? (uint16_t)b : (uint16_t)((unsigned)b << 8);
}

// --- the frame's bytes ----------------------------------------------------

unsigned chudp_wrap(const uint16_t *words, unsigned n, uint8_t *out, unsigned max)
{
	// A frame on this seam is the eight header words, the data, and the
	// three-word hardware trailer --- `chaos_face.h`'s layout, which is
	// also what `chaos_packet_frame` builds.  Anything shorter is not a
	// frame and anything longer is not a Chaos packet; building a datagram
	// that `chudp_unwrap` would refuse helps nobody.
	if (n < CHAOS_PKT_HEADER_WORDS + CHAOS_PKT_TRAILER_WORDS || n > CHAOS_PKT_MAX_WORDS)
		return 0;
	// The packet's own words, and then the trailer: the cable destination
	// appears ONCE, in the trailer, which is where the frame's last three
	// words are.
	const unsigned body = n - CHAOS_PKT_TRAILER_WORDS;
	const unsigned len = CHUDP_HEADER + body * 2u + CHUDP_TRAILER;
	if (len > max)
		return 0;
	out[0] = CHUDP_VERSION;
	out[1] = CHUDP_FUNCTION_PACKET;
	// The two argument bytes, which this sends as zero and does not read.
	out[2] = 0;
	out[3] = 0;
	for (unsigned k = 0; k < body; ++k)
		put_word(CHUDP_PACKET_ORDER, words[k], out + CHUDP_HEADER + 2u * k);
	for (unsigned k = 0; k < CHAOS_PKT_TRAILER_WORDS; ++k)
		put_word(CHUDP_TRAILER_ORDER, words[body + k],
			 out + CHUDP_HEADER + body * 2u + 2u * k);
	return len;
}

unsigned chudp_unwrap(const uint8_t *datagram, unsigned len, uint16_t *out,
		      unsigned max, const char **why)
{
	// The sentence a refusal carries.  A static buffer, good until the next
	// call: one socket, one datagram at a time, and the caller either
	// prints it or drops it before asking again.  `chaos_frame_parse`'s
	// `why` is a literal for the same job; these need a number in them.
	static char said[128];
	static const char *unused;
	if (!why)
		why = &unused;
	*why = NULL;
	// Longer than any Chaos packet.  The caller's buffer is one byte more
	// than `CHUDP_MAX_FRAME` for exactly this: a longer datagram fills it
	// and is refused FOR ITS LENGTH rather than read as a truncated packet.
	if (len > CHUDP_MAX_FRAME) {
		snprintf(said, sizeof said, "%u bytes is longer than any Chaos packet", len);
		*why = said;
		return 0;
	}
	if (len < CHUDP_HEADER + CHUDP_SOFTWARE_HEADER + CHUDP_TRAILER) {
		snprintf(said, sizeof said, "%u bytes is too short for a packet", len);
		*why = said;
		return 0;
	}
	// **The version is checked by number and not parsed as this one.**  The
	// protocol's author has said a version 2 may differ from version 1 in
	// nothing but byte order, so a version 2 peer read as a version 1 one
	// would exchange nonsense rather than fail.
	if (datagram[0] != CHUDP_VERSION) {
		snprintf(said, sizeof said, "version %u, and this speaks %u",
			 (unsigned)datagram[0], (unsigned)CHUDP_VERSION);
		*why = said;
		return 0;
	}
	if (datagram[1] != CHUDP_FUNCTION_PACKET) {
		snprintf(said, sizeof said, "function %u, and only %u carries a packet",
			 (unsigned)datagram[1], (unsigned)CHUDP_FUNCTION_PACKET);
		*why = said;
		return 0;
	}
	// **The trailer is found from the END of the datagram**, not from the
	// data count, so where it starts is not a guess --- which is what lets
	// both a peer that pads an odd data count to a whole word and one that
	// does not be read.  The length is then held to one of the two.
	const unsigned body = len - CHUDP_HEADER - CHUDP_TRAILER;
	const unsigned count = get_word(CHUDP_PACKET_ORDER, datagram + CHUDP_HEADER + 2u) & 07777u;
	if (count > CHAOS_PKT_MAX_DATA) {
		snprintf(said, sizeof said, "a data count of %u, and the most is %u", count,
			 (unsigned)CHAOS_PKT_MAX_DATA);
		*why = said;
		return 0;
	}
	if (body != CHUDP_SOFTWARE_HEADER + ((count + 1u) & ~1u) &&
	    body != CHUDP_SOFTWARE_HEADER + count) {
		snprintf(said, sizeof said, "%u bytes of packet against a data count of %u",
			 body, count);
		*why = said;
		return 0;
	}
	const unsigned body_words = (body + 1u) / 2u;
	const unsigned n = body_words + CHAOS_PKT_TRAILER_WORDS;
	if (n > max) {
		snprintf(said, sizeof said, "%u words, and there is room for %u", n, max);
		*why = said;
		return 0;
	}
	for (unsigned k = 0; k < body_words; ++k) {
		const uint8_t *at = datagram + CHUDP_HEADER + 2u * k;
		out[k] = 2u * k + 1u < body ? get_word(CHUDP_PACKET_ORDER, at)
					    : odd_word(CHUDP_PACKET_ORDER, at[0]);
	}
	for (unsigned k = 0; k < CHAOS_PKT_TRAILER_WORDS; ++k)
		out[body_words + k] =
			get_word(CHUDP_TRAILER_ORDER, datagram + len - CHUDP_TRAILER + 2u * k);
	// **Nothing is dropped on the check word here**, and the caller should
	// not either: what a CHUDP peer puts in the trailer's third word is
	// unverified --- the hardware trailer's is the 9401's CRC-16, and the
	// trailer has also been described as carrying an Internet checksum ---
	// so `chaos_frame_parse` reports the answer and leaves the frame alone.
	// One interoperation settles it.
	return n;
}

// --- the socket -----------------------------------------------------------

// Where a peer is, as one line.  ONE static buffer, so two of these in one
// `say` would print the same endpoint twice; every call site below passes it
// once and is done with it.
static const char *where(const struct sockaddr_in *a)
{
	static char text[32];
	char host[INET_ADDRSTRLEN];
	if (!inet_ntop(AF_INET, &a->sin_addr, host, sizeof host))
		return "somewhere";
	snprintf(text, sizeof text, "%s:%u", host, (unsigned)ntohs(a->sin_port));
	return text;
}

int chudp_bind(struct chudp *u, const char *bind_addr, uint16_t port)
{
	// **This is the initialiser.**  There is no `chudp_init`, and the
	// header's own rule is that the socket is bound before anything else
	// runs --- so `dynamic`, `trace` and the peers are set AFTER this call,
	// never before it.
	memset(u, 0, sizeof *u);
	u->fd = -1;
	struct sockaddr_in at;
	memset(&at, 0, sizeof at);
	at.sin_family = AF_INET;
	at.sin_port = htons(port);
	if (!bind_addr || !*bind_addr) {
		at.sin_addr.s_addr = htonl(INADDR_ANY);
	} else if (inet_pton(AF_INET, bind_addr, &at.sin_addr) != 1) {
		// A name here would be resolved at every start against whatever
		// the resolver said that day; an address to bind to is a
		// statement about this host's own interfaces and is written as
		// one.  A name for a PEER is another matter and is resolved.
		say("udp: %s is not an IPv4 address to bind to", bind_addr);
		return -1;
	}
	const int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0) {
		say("udp: a socket: %s", strerror(errno));
		return -1;
	}
	if (bind(fd, (const struct sockaddr *)&at, sizeof at) < 0) {
		say("udp: binding %s:%u: %s", bind_addr && *bind_addr ? bind_addr : "0.0.0.0",
		    (unsigned)port, strerror(errno));
		close(fd);
		return -1;
	}
	// Never blocking: `chudp_poll` is one turn at the socket beside every
	// other thing this program does, and a read that waited would stop the
	// machine's own frames from moving.
	const int flags = fcntl(fd, F_GETFL, 0);
	if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
		say("udp: the socket cannot be made non-blocking: %s", strerror(errno));
		close(fd);
		return -1;
	}
	u->fd = fd;
	// The port the host chose, for a `port` of 0: said, because nothing
	// else can tell the person running this where to point a peer.
	struct sockaddr_in bound;
	socklen_t blen = sizeof bound;
	if (getsockname(fd, (struct sockaddr *)&bound, &blen) == 0)
		say("udp: listening at %s, speaking CHUDP version %u", where(&bound),
		    (unsigned)CHUDP_VERSION);
	else
		say("udp: listening, and the host will not say where");
	return 0;
}

void chudp_close(struct chudp *u)
{
	if (u->fd >= 0)
		close(u->fd);
	u->fd = -1;
	u->npeers = 0;
}

// --- who is on the other end ----------------------------------------------

// muir's `chaos::parse_address`: octal, or `subnet:host` with both in octal,
// and neither byte zero --- a Chaosnet address is a subnet and a host on it
// and neither half may be absent.  Returns 0 for anything else, 0 being an
// address no station has.
static uint16_t parse_address(const char *s)
{
	char *end = NULL;
	const char *colon = strchr(s, ':');
	unsigned long a;
	if (colon) {
		char subnet[16];
		const size_t n = (size_t)(colon - s);
		if (n == 0 || n >= sizeof subnet)
			return 0;
		memcpy(subnet, s, n);
		subnet[n] = '\0';
		const unsigned long hi = strtoul(subnet, &end, 8);
		if (*end || hi == 0 || hi > 0377u)
			return 0;
		const unsigned long lo = strtoul(colon + 1, &end, 8);
		if (end == colon + 1 || *end || lo == 0 || lo > 0377u)
			return 0;
		a = hi << 8 | lo;
	} else {
		a = strtoul(s, &end, 8);
		if (end == s || *end || a > 0177777u)
			return 0;
	}
	// Both bytes: an address with a zero subnet or a zero host is not one.
	if ((a >> 8) == 0 || (a & 0377u) == 0)
		return 0;
	return (uint16_t)a;
}

int chudp_add_peer(struct chudp *u, const char *spec)
{
	const char *at = strchr(spec, '@');
	if (!at) {
		say("udp: %s wants <address>@<host>[:<port>]", spec);
		return -1;
	}
	char address[32];
	const size_t alen = (size_t)(at - spec);
	if (alen == 0 || alen >= sizeof address) {
		say("udp: %s wants <address>@<host>[:<port>]", spec);
		return -1;
	}
	memcpy(address, spec, alen);
	address[alen] = '\0';
	const uint16_t a = parse_address(address);
	if (a == 0) {
		say("udp: %s is not an address in octal or subnet:host", address);
		return -1;
	}
	// `<host>[:<port>]`.  The last colon is the port's, and the address
	// before the `@` is where a `subnet:host` colon can appear, so the two
	// cannot be confused.  IPv4 only: `struct chudp_peer` holds a
	// `sockaddr_in`, which is the whole of what CHUDP has ever been spoken
	// over here.
	char host[128];
	unsigned long port = CHUDP_PORT;
	const char *lives = at + 1;
	const char *colon = strrchr(lives, ':');
	if (colon) {
		char *end = NULL;
		port = strtoul(colon + 1, &end, 10);
		if (end == colon + 1 || *end || port == 0 || port > 65535u) {
			say("udp: %s is not a port", colon + 1);
			return -1;
		}
	}
	const size_t hlen = colon ? (size_t)(colon - lives) : strlen(lives);
	if (hlen == 0 || hlen >= sizeof host) {
		say("udp: %s names no host", spec);
		return -1;
	}
	memcpy(host, lives, hlen);
	host[hlen] = '\0';
	// **Resolved here, once, before anything runs**, so that a name with no
	// address is a refusal at the start rather than a peer that is never
	// reached.  A name that moves afterwards is not followed; naming the
	// address instead, or `dynamic`, is what covers that.
	struct addrinfo hints;
	memset(&hints, 0, sizeof hints);
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_DGRAM;
	struct addrinfo *found = NULL;
	const int e = getaddrinfo(host, NULL, &hints, &found);
	if (e != 0 || !found) {
		say("udp: %s has no address this host can reach: %s", host, gai_strerror(e));
		if (found)
			freeaddrinfo(found);
		return -1;
	}
	struct sockaddr_in lands;
	memcpy(&lands, found->ai_addr, sizeof lands);
	freeaddrinfo(found);
	lands.sin_port = htons((uint16_t)port);
	// One endpoint an address: a second `--udp-peer` for the same address
	// is a typed statement contradicting a typed statement, and guessing
	// which was meant is worse than refusing.
	for (unsigned k = 0; k < u->npeers; ++k) {
		if (u->peers[k].address == a) {
			say("udp: %o twice; one endpoint an address", (unsigned)a);
			return -1;
		}
	}
	if (u->npeers == CHUDP_MAX_PEERS) {
		say("udp: %u peers is all this holds", (unsigned)CHUDP_MAX_PEERS);
		return -1;
	}
	u->peers[u->npeers].address = a;
	u->peers[u->npeers].where = lands;
	u->peers[u->npeers].learned = 0;
	++u->npeers;
	say("udp: %o is at %s", (unsigned)a, where(&lands));
	return 0;
}

// Which peer lives at this endpoint, or -1.
static int peer_at(const struct chudp *u, const struct sockaddr_in *from)
{
	for (unsigned k = 0; k < u->npeers; ++k) {
		if (u->peers[k].where.sin_addr.s_addr == from->sin_addr.s_addr &&
		    u->peers[k].where.sin_port == from->sin_port)
			return (int)k;
	}
	return -1;
}

// Which peer claims this Chaosnet address, or -1.
static int peer_for(const struct chudp *u, uint16_t address)
{
	for (unsigned k = 0; k < u->npeers; ++k) {
		if (u->peers[k].address == address)
			return (int)k;
	}
	return -1;
}

// --- a frame out ----------------------------------------------------------

int chudp_send(struct chudp *u, const uint16_t *words, unsigned n, uint16_t cable_dest)
{
	uint8_t datagram[CHUDP_MAX_FRAME];
	const unsigned len = chudp_wrap(words, n, datagram, sizeof datagram);
	if (len == 0) {
		say("udp: %u words is not a frame CHUDP carries", n);
		return 0;
	}
	int sent = 0;
	for (unsigned k = 0; k < u->npeers; ++k) {
		// A cable destination of 0 is a broadcast, and every peer is a
		// station on this machine's cable, so every peer gets it.
		if (cable_dest != 0 && u->peers[k].address != cable_dest)
			continue;
		if (sendto(u->fd, datagram, len, 0, (const struct sockaddr *)&u->peers[k].where,
			   sizeof u->peers[k].where) < 0) {
			say("udp: to %s: %s", where(&u->peers[k].where), strerror(errno));
			continue;
		}
		++sent;
	}
	// **A destination no peer claims is DROPPED, not forwarded.**  This
	// board is a leaf: it has no routing table, it is on nobody's path, and
	// flooding a packet at every peer in the hope that one of them is a
	// bridge would put traffic on cables that never asked for it.  Traced
	// rather than said, because a machine talking to somebody unreachable
	// would otherwise fill the log with one line a packet.
	if (sent == 0 && cable_dest != 0 && u->trace)
		say("udp: %o is no peer of ours; the frame is dropped and not forwarded",
		    (unsigned)cable_dest);
	return sent;
}

// --- a frame in -----------------------------------------------------------

int chudp_poll(struct chudp *u, unsigned max,
	       void (*deliver)(void *ctx, const uint16_t *words, unsigned n), void *ctx)
{
	int delivered = 0;
	for (unsigned turn = 0; turn < max; ++turn) {
		// One byte more than the longest frame, so a datagram longer
		// than any Chaos packet fills the buffer and `chudp_unwrap`
		// refuses it for its length rather than reading a truncated
		// packet out of it.
		uint8_t datagram[CHUDP_MAX_FRAME + 1];
		struct sockaddr_in from;
		socklen_t flen = sizeof from;
		memset(&from, 0, sizeof from);
		const ssize_t got = recvfrom(u->fd, datagram, sizeof datagram, 0,
					     (struct sockaddr *)&from, &flen);
		if (got < 0) {
			if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
				break;
			say("udp: the socket: %s", strerror(errno));
			break;
		}
		uint16_t words[CHAOS_PKT_MAX_WORDS];
		const char *why = NULL;
		const unsigned n = chudp_unwrap(datagram, (unsigned)got, words,
						CHAOS_PKT_MAX_WORDS, &why);
		if (n == 0) {
			if (u->trace)
				say("udp: from %s: %s", where(&from), why ? why : "not a frame");
			continue;
		}
		const int known = peer_at(u, &from);
		// The packet's own source, which is where an answer would be
		// addressed, and the cable source the far side's hardware put
		// in.  `chaos_face.h`'s layout: words 0 to 7 are the software
		// header and the last three are the trailer.
		const uint16_t packet_source = words[4];
		const uint16_t cable_dest = words[n - 3];
		const uint16_t cable_source = words[n - 2];
		// **An endpoint is learned only when the run asked for it.**  Off
		// by default, because otherwise whatever can reach the port
		// installs itself in the address table under whatever Chaosnet
		// address it claims.  A datagram from an endpoint no peer is at
		// is dropped at the door, which is `chaos_udp.h`'s own rule.
		// **muir differs here and the difference is worth knowing**: its
		// link hears such a datagram and simply cannot answer it,
		// because its node sits on a modelled cable that hears
		// everything.  This one sits in front of a real machine, so the
		// door is where the drop belongs.
		if (known < 0 && !u->dynamic) {
			if (u->trace)
				say("udp: from %s: no peer is there, and endpoints are not "
				    "learned", where(&from));
			continue;
		}
		// What is learned is the PACKET's own source, since that is
		// where an answer would be addressed.  Reachability, which is
		// not authorisation: this says where a peer can be reached and
		// nothing about what it may ask for.
		if (u->dynamic && packet_source != 0) {
			const int claims = peer_for(u, packet_source);
			const int moved =
				claims >= 0 &&
				(u->peers[claims].where.sin_addr.s_addr != from.sin_addr.s_addr ||
				 u->peers[claims].where.sin_port != from.sin_port);
			if (claims < 0 && u->npeers == CHUDP_MAX_PEERS) {
				if (u->trace)
					say("udp: %o is at %s and there is no room to learn it",
					    (unsigned)packet_source, where(&from));
			} else if (claims < 0) {
				u->peers[u->npeers].address = packet_source;
				u->peers[u->npeers].where = from;
				u->peers[u->npeers].learned = 1;
				++u->npeers;
				if (u->trace)
					say("udp: %o is at %s", (unsigned)packet_source,
					    where(&from));
			} else if (moved && u->peers[claims].learned) {
				// A learned endpoint is only ever the last
				// packet's word for where a host is, so the
				// newest packet has it.  A host that moves is
				// followed; a host that is impersonated is the
				// price of having asked to learn, which is why
				// learning is off unless the run asks.
				u->peers[claims].where = from;
				if (u->trace)
					say("udp: %o has moved to %s", (unsigned)packet_source,
					    where(&from));
			} else if (moved) {
				// **A packet does not move an endpoint a flag
				// named.**  An endpoint typed on the command
				// line is a statement about where a host is;
				// letting a packet redirect it would put the
				// naming back in the hands of whoever can reach
				// the port.
				if (u->trace)
					say("udp: from %s: %o is where a flag put it, and "
					    "stays there", where(&from),
					    (unsigned)packet_source);
			}
		}
		// A frame with no cable source is a frame no station sent: the
		// hardware inserts that word itself and 0 is no station's
		// address.  muir drops it, and so does this.
		if (cable_source == 0) {
			if (u->trace)
				say("udp: from %s: a frame with no cable source", where(&from));
			continue;
		}
		// **The leaf rule, the half this can see.**  A frame addressed
		// on the cable to another station that is reached over UDP is
		// for that station and not for this cable, and forwarding it is
		// a bridge's job.  Whether the destination is one of the
		// addresses THIS cable carries --- the machine's and the
		// Chaosnet server's --- is the caller's to judge: `struct
		// chudp` holds no list of them, and muir's node is given one
		// (`Chudp::local`) because it is attached to the cable itself.
		if (cable_dest != 0 && peer_for(u, cable_dest) >= 0) {
			if (u->trace)
				say("udp: from %s: %o is another peer's, not this cable's",
				    where(&from), (unsigned)cable_dest);
			continue;
		}
		deliver(ctx, words, n);
		++delivered;
	}
	return delivered;
}
