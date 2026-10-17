// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The flags of 253-257, muir's `ethernet_socket.rs` parsers in C: `qed_host.h`
// says what they are held to.

#include "qed_host.h"

#include <stdio.h>
#include <string.h>

void qed_host_default(struct qed_host *h)
{
	static const uint8_t mac[6] = { 0x02, 0, 0, 0, 0, 0x01 };
	memcpy(h->mac, mac, 6);
	h->address = 169u << 24 | 254u << 16 | 100u << 8 | 2u;
	h->netmask = 0xFFFFFFFFu << 2;
	h->gateway = 169u << 24 | 254u << 16 | 100u << 8 | 1u;
}

// `arg` as Rust's `{:?}` writes a string: in double quotes, with `"` and `\`
// escaped, and a control character as \t, \r, \n, \0 or \u{..}.  A byte from
// 0x80 up is written as it is, as a valid UTF-8 string's printable characters
// are.
static void debug_quoted(const char *arg, char *out, size_t len)
{
	size_t o = 0;
#define PUT(c) do { if (o + 1 < len) out[o++] = (c); } while (0)
	PUT('"');
	for (const unsigned char *p = (const unsigned char *)arg; *p; ++p) {
		const unsigned c = *p;
		if (c == '"' || c == '\\') {
			PUT('\\');
			PUT((char)c);
		} else if (c == '\t' || c == '\r' || c == '\n') {
			PUT('\\');
			PUT(c == '\t' ? 't' : c == '\r' ? 'r' : 'n');
		} else if (c < 0x20 || c == 0x7F) {
			char u[12];
			snprintf(u, sizeof u, "\\u{%x}", c);
			for (const char *q = u; *q; ++q)
				PUT(*q);
		} else {
			PUT((char)c);
		}
	}
	PUT('"');
#undef PUT
	out[o < len ? o : len - 1] = 0;
}

static int hexdigit(int c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

int qed_parse_mac(const char *arg, uint8_t mac[6], char *why, size_t len)
{
	uint8_t m[6];
	const char *p = arg;
	int ok = 1;
	for (int k = 0; k < 6 && ok; ++k) {
		const int a = hexdigit((unsigned char)p[0]);
		const int b = a < 0 ? -1 : hexdigit((unsigned char)p[1]);
		if (a < 0 || b < 0) {
			ok = 0;
			break;
		}
		m[k] = (uint8_t)(a << 4 | b);
		p += 2;
		if (k < 5) {
			if (*p != ':')
				ok = 0;
			else
				++p;
		} else if (*p) {
			ok = 0;
		}
	}
	if (!ok) {
		char q[256];
		debug_quoted(arg, q, sizeof q);
		snprintf(why, len, "--ethernet-mac wants XX:XX:XX:XX:XX:XX, six pairs of hex digits: %s", q);
		return -1;
	}
	if (m[0] & 1u) {
		snprintf(why, len,
			 "--ethernet-mac %s: a group address, <0> of its first byte set; the device's own "
			 "address is a station's",
			 arg);
		return -1;
	}
	memcpy(mac, m, 6);
	return 0;
}

// A dotted IPv4 address as Rust's `Ipv4Addr` parses one: four parts by
// dots, each decimal 0 to 255 in at most three digits and with no leading
// zero, and nothing else.
static int parse_ipv4(const char *s, size_t n, uint32_t *out)
{
	uint32_t v = 0;
	size_t i = 0;
	for (int part = 0; part < 4; ++part) {
		if (part) {
			if (i >= n || s[i] != '.')
				return -1;
			++i;
		}
		const size_t from = i;
		unsigned x = 0;
		while (i < n && s[i] >= '0' && s[i] <= '9' && i - from < 3)
			x = 10 * x + (unsigned)(s[i++] - '0');
		const size_t digits = i - from;
		if (!digits || x > 255 || (digits > 1 && s[from] == '0'))
			return -1;
		v = v << 8 | x;
	}
	if (i != n)
		return -1;
	*out = v;
	return 0;
}

#define MAX_PREFIX 30u

int qed_parse_ip_address(const char *arg, uint32_t *address, uint32_t *netmask, char *why,
			 size_t len)
{
	const char *slash = strchr(arg, '/');
	uint32_t a;
	int ok = slash && parse_ipv4(arg, (size_t)(slash - arg), &a) == 0;
	const char *prefix = slash ? slash + 1 : "";
	const size_t pl = strlen(prefix);
	if (ok && (pl == 0 || pl > 2 || strspn(prefix, "0123456789") != pl))
		ok = 0;
	if (!ok) {
		char q[256];
		debug_quoted(arg, q, sizeof q);
		snprintf(why, len,
			 "--ip-address wants A.B.C.D/N, QUUX's IPv4 address and its prefix length: %s", q);
		return -1;
	}
	unsigned n = 0;
	for (size_t i = 0; i < pl; ++i)
		n = 10 * n + (unsigned)(prefix[i] - '0');
	if (n < 1 || n > MAX_PREFIX) {
		snprintf(why, len,
			 "--ip-address %s: a prefix length of %u; it is 1 to %u, so that the subnet holds "
			 "QUUX's address and its gateway besides its network and broadcast addresses",
			 arg, n, MAX_PREFIX);
		return -1;
	}
	const uint32_t mask = 0xFFFFFFFFu << (32 - n);
	const unsigned top = a >> 24;
	const char *not_a_host = top == 0                  ? "in 0.x.x.x, this network"
				 : top == 127              ? "in 127.x.x.x, loopback"
				 : top >= 224 && top <= 239 ? "from 224.0.0.0 to 239.255.255.255, multicast"
				 : top >= 240              ? "from 240.0.0.0 up, reserved"
				 : (a & ~mask) == 0        ? "the subnet's network address"
				 : (a & ~mask) == ~mask    ? "the subnet's broadcast address"
							   : NULL;
	if (not_a_host) {
		snprintf(why, len, "--ip-address %s: not a host's address: %s", arg, not_a_host);
		return -1;
	}
	*address = a;
	*netmask = mask;
	return 0;
}

int qed_parse_ip_gateway(const char *arg, uint32_t *gateway, char *why, size_t len)
{
	if (parse_ipv4(arg, strlen(arg), gateway) != 0) {
		char q[256];
		debug_quoted(arg, q, sizeof q);
		snprintf(why, len, "--ip-gateway wants A.B.C.D, the gateway's IPv4 address: %s", q);
		return -1;
	}
	return 0;
}

void qed_ipv4_text(uint32_t a, char out[16])
{
	snprintf(out, 16, "%u.%u.%u.%u", a >> 24, a >> 16 & 255u, a >> 8 & 255u, a & 255u);
}

void qed_mac_text(const uint8_t mac[6], char out[18])
{
	snprintf(out, 18, "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2], mac[3], mac[4],
		 mac[5]);
}

unsigned qed_prefix_length(uint32_t netmask)
{
	unsigned n = 0;
	while (n < 32 && (netmask & (0x80000000u >> n)))
		++n;
	return n;
}

int qed_check_gateway(uint32_t address, uint32_t netmask, uint32_t gateway, int is_default,
		      char *why, size_t len)
{
	char g[16], a[16];
	qed_ipv4_text(gateway, g);
	qed_ipv4_text(address, a);
	const char *dflt = is_default ? ", its default," : "";
	if (gateway == 0) {
		snprintf(why, len, "--ip-gateway %s%s: there is always a gateway, by default the link's other end",
			 g, dflt);
		return -1;
	}
	char what[160];
	if (gateway == address)
		snprintf(what, sizeof what, "is QUUX's own address, --ip-address %s/%u's", a,
			 qed_prefix_length(netmask));
	else if ((gateway & netmask) != (address & netmask))
		snprintf(what, sizeof what,
			 "is off --ip-address %s/%u's subnet: a gateway is on a connected network (RFC 1122 "
			 "§3.3.1)",
			 a, qed_prefix_length(netmask));
	else if ((gateway & ~netmask) == 0)
		snprintf(what, sizeof what, "is the subnet's network address");
	else if ((gateway & ~netmask) == ~netmask)
		snprintf(what, sizeof what, "is the subnet's broadcast address");
	else
		return 0;
	snprintf(why, len, "--ip-gateway %s%s %s%s", g, dflt, what, is_default ? "; give --ip-gateway" : "");
	return -1;
}
