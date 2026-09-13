// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Chaosnet over UDP: the stations on this machine's cable that are not on
// this board.  `muir::chaos::udp`, ported.
//
// CHUDP puts one Chaosnet packet in one UDP datagram behind a four-byte
// header, and it is what `cbridge`, `usim`, `klh10` and the live Chaosnet
// hosts speak to each other.  Ordinary UDP: no privileges, and it crosses a
// NAT --- which IP protocol 16, the assigned number for Chaosnet, does not.
// This is the board's gigabit Ethernet and what makes the machine's Chaosnet
// reach further than the card it is on.
//
// **THIS BOARD IS A LEAF, NOT A ROUTER**, as muir is.  A datagram whose
// hardware destination is neither the machine nor the broadcast address is
// dropped rather than forwarded; AIM-628 chapter 6's routing is a bridge's
// job and `cbridge` is the thing to put beside this.
//
// **THE BRIDGE IS REACHED AS THE DEFAULT PEER.**  A peer entry says that one
// Chaosnet address lives at one endpoint, so naming a bridge as a peer does
// not let this board talk THROUGH it: a frame for any other address has
// nowhere to go.  `chudp_set_default_peer` is where such a frame goes
// instead, which is the route of last resort and the whole of the routing
// here --- nothing reads a routing packet.  The frame carries the real
// destination in its hardware trailer for the bridge to route on, which is
// why the default peer is an endpoint and carries no Chaosnet address.  A
// broadcast is NOT sent there: the named peers are stations on this machine's
// own cable and a broadcast is theirs, while the default peer is the way out
// to a wider network.  muir's `--chaos-udp-default-peer`, and its own
// `chaos::udp` has the same paragraph.
//
// **NOTHING IS LEARNED FROM A PACKET.**  An endpoint typed on the command
// line is a statement; a table filled in from what arrives is state nobody
// wrote down, and it puts the naming in the hands of whoever can reach the
// port.  muir removed its `--chaos-udp-dynamic` for those two reasons and so
// has this.  A datagram is therefore judged by what is IN it --- its cable
// source and its cable destination --- and never by the socket it came off,
// so a host no flag named is heard exactly as a named peer is and the answer
// to it goes out only when a flag said where that host is.
//
// ## The frame
//
//     offset  width  field
//          0      1  version
//          1      1  function
//          2      2  two argument bytes
//     ---- the Chaos packet, AIM-628 §3.5, in 16-bit words ----
//          4      2  operation
//          6      2  count: 4-bit forwarding count, 12-bit data count
//          8      2  destination address
//         10      2  destination index
//         12      2  source address
//         14      2  source index
//         16      2  packet number
//         18      2  acknowledge
//         20      n  data, n the byte count rounded up to a whole word
//     ---- the hardware trailer, AIM-628 §2.2 ----
//     20 + n      2  destination
//     22 + n      2  source
//     24 + n      2  check
//
// ## Byte order, which is **unverified** and is muir's reading
//
// `CHUDP_PACKET_ORDER` and `CHUDP_TRAILER_ORDER` say it and are the only
// place a word becomes bytes.  The packet's own words are LITTLE-endian and
// the trailer's three are NETWORK order --- a mixed frame.  muir's own
// header explains why each is believed and what would settle it (a capture of
// a live exchange, or one interoperation); the protocol's author has said a
// version 2 may differ from version 1 in nothing but byte order, so it is two
// constants to change rather than an audit of the packing.  The wrong order
// fails loudly on the first packet --- an absurd 12-bit data count against
// the datagram's length --- so it does not fail quietly.
//
// `CHUDP_VERSION` is checked on receipt for the same reason: an unknown
// version is refused with its number rather than parsed as this one.

#ifndef CHAOS_UDP_H
#define CHAOS_UDP_H

#include <netinet/in.h>
#include <stdint.h>

#include "chaos_packet.h"

// The port CHUDP is spoken on unless a flag names another.
#define CHUDP_PORT 42042

// The version this speaks, and the only one it takes.
#define CHUDP_VERSION 1

// The function code for "here is a Chaos packet", described as the only one
// defined.
#define CHUDP_FUNCTION_PACKET 1

// The CHUDP header: version, function, and two argument bytes, which this
// sends as zero and does not read.
#define CHUDP_HEADER 4

// The hardware trailer, AIM-628 §2.2: destination, source, check.
#define CHUDP_TRAILER 6

// The most a CHUDP frame can be.  The receive buffer is one byte more, so a
// longer datagram fills it and is refused for its length rather than read as
// a truncated packet.
#define CHUDP_MAX_FRAME \
	(CHUDP_HEADER + 16u + CHAOS_PKT_MAX_DATA + CHUDP_TRAILER)

// How many peers a run may name.
#define CHUDP_MAX_PEERS 16u

enum chudp_order { CHUDP_LITTLE, CHUDP_BIG };
#define CHUDP_PACKET_ORDER  CHUDP_LITTLE
#define CHUDP_TRAILER_ORDER CHUDP_BIG

struct chudp_peer {
	uint16_t address;
	struct sockaddr_in where;
};

struct chudp {
	int fd;
	int trace;
	// The one address this cable carries in this process: the machine's,
	// which the fabric's interface answers to.  muir's node is handed the
	// same thing as `Chudp::local` and a list, having a modelled cable
	// with more than one station on it; here there is one.  A datagram
	// claiming to be FROM it is a forgery and is dropped, because the
	// interface would take the frame for its own --- Transmit Done and
	// all.  0 says nobody has said, which is what a link bound and not yet
	// told is.
	uint16_t local;
	// Where a frame goes whose destination no peer entry names: the route
	// of last resort, an endpoint and no Chaosnet address.  `have_default`
	// rather than a zero address, since every endpoint is a real one.
	struct sockaddr_in default_peer;
	int have_default;
	unsigned npeers;
	struct chudp_peer peers[CHUDP_MAX_PEERS];
};

// Binds the socket.  `port` of 0 asks the host for one.  0, or -1 having said
// why.  Bound before anything else runs, so that a port that cannot be had is
// a refusal at the start rather than a program that quietly reaches nobody.
int chudp_bind(struct chudp *u, const char *bind_addr, uint16_t port);
void chudp_close(struct chudp *u);

// `<address>@<host>[:<port>]`, which is muir's `--chaos-udp-peer`.  0, or -1
// having said why.
int chudp_add_peer(struct chudp *u, const char *spec);

// `<host>[:<port>]`, which is muir's `--chaos-udp-default-peer`.  0, or -1
// having said why.  **It takes no Chaosnet address**, and that is what tells
// it from a peer: it is not a host at an address, it is where what is not
// named goes.  A bare port is on the loopback, an address alone takes
// CHUDP's own port, and a name is resolved here and once.  Twice is refused,
// as a second endpoint for one peer is.
int chudp_set_default_peer(struct chudp *u, const char *spec);

// **WHICH FLAG ASKS FOR A LINK THAT IS NOT THERE**, or NULL when the flags
// agree.  muir's rule: `--chaos-address` sets the sixteen address switches
// and nothing else, and `--chaos-udp` is the cable --- on the board the
// switches are set whether or not anything is plugged in, and a cable can be
// unplugged.  So a flag that says who is ON the cable needs the cable, and a
// run that names a peer without one is asking for a link that does not exist.
// The peer is reported before the default peer, as muir reports them.
//
// It is a function rather than three lines in `main` so that the rule is
// checkable: `cadr-chaosnet.c` is in neither the check's binary nor the
// mutation runner's, and a rule nothing exercises is not a rule.
const char *chudp_flag_without_cable(int have_cable, unsigned npeers, int have_default);

// A frame out to whoever should have it, which is muir's `Chudp::addressed`:
// every peer for a broadcast (`cable_dest` 0), since they are stations on
// this cable; nobody at all for this cable's own address; the peer whose
// address is `cable_dest`; and failing that the default peer.  Returns how
// many datagrams went.  A destination no entry names and no default peer
// covers is dropped and counted, not forwarded: this is a leaf.
int chudp_send(struct chudp *u, const uint16_t *words, unsigned n, uint16_t cable_dest);

// One turn at the socket, never blocking: up to `max` frames taken.  Each is
// handed to `deliver` as the words of a frame, in the same layout
// `chaos_face.h` carries --- header, data, cable destination, cable source,
// check word --- so a packet crossing between the machine and a peer is
// copied and not rebuilt.  Returns how many were delivered.
int chudp_poll(struct chudp *u, unsigned max,
	       void (*deliver)(void *ctx, const uint16_t *words, unsigned n),
	       void *ctx);

// The two halves on their own, so that `chaos_test.c` can hold a whole
// datagram's bytes without a socket --- which is the test muir pins in
// `tests/chudp.rs`.
//
// `wrap`: the frame's words into a datagram.  Returns its length, or 0.
// `unwrap`: a datagram back into a frame's words.  Returns the word count, or
// 0 having put a sentence in `*why`.
unsigned chudp_wrap(const uint16_t *words, unsigned n, uint8_t *out, unsigned max);
unsigned chudp_unwrap(const uint8_t *datagram, unsigned len, uint16_t *out,
		      unsigned max, const char **why);

#endif
