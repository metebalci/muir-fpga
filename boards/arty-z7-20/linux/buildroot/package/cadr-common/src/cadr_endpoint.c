// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// muir's endpoint grammar; `cadr/cadr_endpoint.h` says what it is for.

#include "cadr/cadr_endpoint.h"

#include <arpa/inet.h>
#include <stdio.h>
#include <string.h>

// A port as muir reads one: `v.parse::<u16>()`, so digits alone and 0 to
// 65535.  Nothing else --- no sign, no space, no empty string --- because
// every one of those would be a number somebody meant and did not get.
// Leading zeros are taken, as Rust takes them.
static int a_port(const char *s, unsigned *out)
{
	if (!*s)
		return -1;
	unsigned v = 0;
	for (const char *p = s; *p; ++p) {
		if (*p < '0' || *p > '9')
			return -1;
		v = v * 10u + (unsigned)(*p - '0');
		if (v > 65535u)
			return -1;
	}
	*out = v;
	return 0;
}

// An address into the endpoint, or -1.  Empty is every interface and is not
// an address to read; anything else goes through the same `inet_pton` the
// two bind functions use, so a spelling this takes is one they take.
static int an_addr(struct cadr_endpoint *e, const char *a)
{
	if (!a || !*a) {
		e->addr[0] = '\0';
		return 0;
	}
	if (strlen(a) >= sizeof e->addr)
		return -1;
	struct in_addr scratch;
	if (inet_pton(AF_INET, a, &scratch) != 1)
		return -1;
	snprintf(e->addr, sizeof e->addr, "%s", a);
	return 0;
}

int cadr_endpoint_parse(const char *spec, const char *def_addr, unsigned def_port,
			struct cadr_endpoint *out)
{
	struct cadr_endpoint e;
	memset(&e, 0, sizeof e);
	e.port = def_port;
	if (an_addr(&e, def_addr) != 0)
		return -1;

	// Nothing: the default, and it named no port.
	if (!spec) {
		*out = e;
		return 0;
	}

	// An argument that is there and is empty --- `--terminal=` --- is
	// refused.  It is not the flag given bare: somebody wrote an argument
	// and it says nothing, and muir refuses it too, every one of its three
	// parses failing on an empty string.  `an_addr` below would take it as
	// every interface, which is the one reading nobody meant.
	if (!*spec)
		return -1;

	// <address>:<port>.  muir tries a whole SocketAddr first, so this is
	// first here too: `5900` has no colon and `1.2.3.4` has none either,
	// and the two orders can only differ on a spelling neither accepts.
	const char *colon = strrchr(spec, ':');
	if (colon) {
		char host[64];
		const size_t hostlen = (size_t)(colon - spec);
		// An empty host --- `:5900` --- is refused rather than read as
		// every interface.  muir refuses it, and "every interface" has
		// a spelling of its own that says so: `0.0.0.0:5900`.
		if (hostlen == 0 || hostlen >= sizeof host)
			return -1;
		memcpy(host, spec, hostlen);
		host[hostlen] = '\0';
		if (an_addr(&e, host) != 0)
			return -1;
		if (a_port(colon + 1, &e.port) != 0)
			return -1;
		e.port_named = 1;
		*out = e;
		return 0;
	}

	// A bare port, on the default's address.
	if (a_port(spec, &e.port) == 0) {
		e.port_named = 1;
		*out = e;
		return 0;
	}

	// A bare address, on the default's port.  It names no port, which is
	// what lets `--serial` refuse it.
	if (an_addr(&e, spec) == 0) {
		*out = e;
		return 0;
	}

	return -1;
}

const char *cadr_endpoint_show(const struct cadr_endpoint *e, char *buf, unsigned n)
{
	snprintf(buf, n, "%s:%u", e->addr[0] ? e->addr : "0.0.0.0", e->port);
	return buf;
}
