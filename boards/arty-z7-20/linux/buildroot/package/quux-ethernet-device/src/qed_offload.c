// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Section 2.4 of the Ethernet contract, muir's `ethernet_offload.rs` decision
// for decision: `qed_offload.h` states the rules.  The reasons are muir's
// words, so that `--ethernet-trace` and this program's log say the same.

#include "qed_offload.h"

#include <string.h>

#define TCP  6u
#define UDP  17u
#define ICMP 1u

static unsigned be16(const uint8_t *f, size_t at)
{
	return (unsigned)f[at] << 8 | f[at + 1];
}

// The words of `data` added to a running sum.  Every piece but the last is
// of even length, so no word straddles two pieces.
static uint64_t add(uint64_t sum, const uint8_t *data, size_t n)
{
	size_t i = 0;
	for (; i + 1 < n; i += 2)
		sum += (uint64_t)data[i] << 8 | data[i + 1];
	if (i < n)
		sum += (uint64_t)data[i] << 8;
	return sum;
}

static uint16_t fold(uint64_t sum)
{
	while (sum > 0xFFFFu)
		sum = (sum & 0xFFFFu) + (sum >> 16);
	return (uint16_t)sum;
}

uint16_t qed_ones_sum(const uint8_t *data, size_t n)
{
	return fold(add(0, data, n));
}

// A well-formed IPv4 Ethernet frame's parts.
struct datagram {
	size_t h;        // the header's length H, options included
	unsigned p;      // the payload's protocol P
	size_t start;    // the payload: frame bytes start to end - 1
	size_t end;
	size_t n;        // the frame's length, which no sum takes
	int field;       // a checked protocol's checksum field in the payload, or -1
};

// The pseudo-header's sum for TCP and UDP, 0 for ICMP.
static uint64_t pseudo(const struct datagram *d, const uint8_t *f)
{
	if (d->p != TCP && d->p != UDP)
		return 0;
	const uint8_t zp[2] = { 0, (uint8_t)d->p };
	return add(add(0, f + 26, 8), zp, 2) + (uint64_t)(d->end - d->start);
}

// The protocol's sum over the payload and the pseudo-header, the field as it
// stands.
static uint16_t payload_sum(const struct datagram *d, const uint8_t *f)
{
	return fold(add(pseudo(d, f), f + d->start, d->end - d->start));
}

enum kind { NO_TYPE, OTHER_TYPE, ARP, IPV4 };

// NULL when the IPv4 Ethernet frame is well-formed, `*d` its parts; else
// why it is not.
static const char *datagram(const uint8_t *f, size_t n, struct datagram *d)
{
	if (n < 34)
		return "IPv4 frame under 34 bytes";
	if (f[14] >> 4 != 4)
		return "IPv4 version not 4";
	const size_t ihl = f[14] & 0x0Fu;
	if (ihl < 5)
		return "IPv4 IHL under 5";
	const size_t h = 4 * ihl, tl = be16(f, 16);
	if (tl < h)
		return "IPv4 total length under the header's";
	if (14 + tl > n)
		return "IPv4 total length past the frame";
	d->h = h;
	d->p = f[23];
	d->start = 14 + h;
	d->end = 14 + tl;
	d->n = n;
	d->field = -1;
	const size_t l = d->end - d->start;
	const int fragment = (f[20] & 0x20u) || (be16(f, 20) & 0x1FFFu);
	if (fragment)
		return NULL;
	switch (d->p) {
	case TCP:
		if (l < 20)
			return "TCP payload under 20 bytes";
		d->field = 16;
		break;
	case UDP:
		if (l < 8)
			return "UDP payload under 8 bytes";
		if (be16(f, d->start + 4) != l)
			return "UDP length not the payload's";
		d->field = 6;
		break;
	case ICMP:
		if (l < 8)
			return "ICMP payload under 8 bytes";
		d->field = 2;
		break;
	}
	return NULL;
}

static enum kind kind(const uint8_t *f, size_t n)
{
	if (n < 14)
		return NO_TYPE;
	switch (be16(f, 12)) {
	case QED_TYPE_ARP:
		return ARP;
	case QED_TYPE_IPV4:
		return IPV4;
	default:
		return OTHER_TYPE;
	}
}

const char *qed_transmit(uint8_t *f, size_t n)
{
	struct datagram d;
	switch (kind(f, n)) {
	case NO_TYPE:
		return "frame under 14 bytes";
	case OTHER_TYPE:
		return "type not IPv4 or ARP";
	case ARP:
		return NULL;
	case IPV4:
		break;
	}
	const char *bad = datagram(f, n, &d);
	if (bad)
		return bad;
	f[24] = f[25] = 0;
	const uint16_t header = (uint16_t)~qed_ones_sum(f + 14, d.h);
	f[24] = (uint8_t)(header >> 8);
	f[25] = (uint8_t)header;
	if (d.field >= 0) {
		const size_t at = d.start + (size_t)d.field;
		f[at] = f[at + 1] = 0;
		uint16_t c = (uint16_t)~payload_sum(&d, f);
		if (d.p == UDP && c == 0)
			c = 0xFFFFu;
		f[at] = (uint8_t)(c >> 8);
		f[at + 1] = (uint8_t)c;
	}
	return NULL;
}

enum qed_counter qed_receive(const uint8_t *f, size_t n, const char **why)
{
	struct datagram d;
	switch (kind(f, n)) {
	case NO_TYPE:
		*why = "frame under 14 bytes";
		return QED_COUNT_TYPE;
	case OTHER_TYPE:
		*why = "type not IPv4 or ARP";
		return QED_COUNT_TYPE;
	case ARP:
		return QED_COUNT_NONE;
	case IPV4:
		break;
	}
	const char *bad = datagram(f, n, &d);
	if (bad) {
		*why = bad;
		return QED_COUNT_IPV4;
	}
	if (qed_ones_sum(f + 14, d.h) != 0xFFFFu) {
		*why = "IPv4 header checksum bad";
		return QED_COUNT_IPV4;
	}
	if (d.field < 0)
		return QED_COUNT_NONE;
	if (d.p == UDP && be16(f, d.start + (size_t)d.field) == 0)
		return QED_COUNT_NONE;
	if (payload_sum(&d, f) != 0xFFFFu) {
		*why = d.p == TCP ? "TCP checksum bad" : d.p == UDP ? "UDP checksum bad" : "ICMP checksum bad";
		return QED_COUNT_IPV4;
	}
	return QED_COUNT_NONE;
}
