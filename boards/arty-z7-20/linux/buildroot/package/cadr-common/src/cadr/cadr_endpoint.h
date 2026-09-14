// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// muir's endpoint grammar, in one place.
//
// Two programs on this board are reached over TCP --- the screen and the
// serial line --- and muir says where each of its own is with one flag and one
// word: `--terminal <endpoint>` and `--serial <endpoint>`.  Our programs take
// the same two flags, so somebody who knows muir's prompt knows these, and a
// card's `fpgarc` says the same thing `muirrc` beside it says.
//
// **THE GRAMMAR IS muir'S `endpoint_at`, READ OFF ITS OWN SOURCE**, and it is
// four forms:
//
//     nothing          the default, address and port
//     <port>           the default's address at that port
//     <address>        that address at the default's port
//     <address>:<port> itself
//
// A form that is none of those is refused, and the refusal is the caller's to
// word, because the two flags refuse for different reasons.
//
// **WHICH FORMS NAMED A PORT IS PART OF THE ANSWER**, and `port_named` carries
// it.  muir needs it to decide whether to hunt for a free display; here it is
// what lets `--serial` refuse a bare address, which muir refuses too: the
// serial line's port is not a number anybody would guess, so an endpoint that
// does not say it is an endpoint nobody was told to attach to.
//
// **WHY ONE DEFINITION AND NOT TWO.**  The same argument `cadr_input_link.h`
// makes about a wire format: a grammar with two definitions is two grammars,
// and the way they would come apart is one program taking a spelling the other
// refused, on the same card, in the same file.
//
// **IPv4 ONLY**, as everything else here is: `screen_server_bind` and
// `serial_endpoint_bind` both take a dotted quad through `inet_pton(AF_INET)`,
// so an address this reads is one of those and nothing else.

#ifndef CADR_ENDPOINT_H
#define CADR_ENDPOINT_H

// Where a program listens: a dotted quad and a port.
struct cadr_endpoint {
	// The address, as `inet_pton(AF_INET)` reads one --- or EMPTY, which
	// is every interface.  That is what both bind functions already take
	// for a NULL address, so it goes to them unchanged.
	char addr[16];
	unsigned port;
	// Whether the spec named a port: a bare port and <address>:<port> do,
	// nothing and a bare address do not.
	int port_named;
};

// Read `spec` against a default.  `spec` NULL is the flag given bare, which
// is the default itself.  `def_addr` NULL or empty is every interface.
//
// 0 and `out` filled in, or -1 and `out` untouched-as-far-as-anyone-should-
// look.  A refusal is a spelling that is none of the four forms: a port out
// of range, an address that is not a dotted quad, an empty host before the
// colon, a port that is not digits.
int cadr_endpoint_parse(const char *spec, const char *def_addr, unsigned def_port,
			struct cadr_endpoint *out);

// What `out` says, for a log line: `<address>:<port>`, with `0.0.0.0` for
// every interface, so that a program's opening line names the endpoint the
// way a person would type it back. `buf` is at least 24 bytes.
const char *cadr_endpoint_show(const struct cadr_endpoint *e, char *buf, unsigned n);

#endif
