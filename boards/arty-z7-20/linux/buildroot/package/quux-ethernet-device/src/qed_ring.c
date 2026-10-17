// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The device's two directions over the face.  The order, and why:
//
// **TRANSMIT.**  Read the page.  Disabled, or 245 = 244, is nothing to do.
// Take the claim under that epoch and read the page again under it: from
// here a disable holds quiet low until the claim is dropped, so the machine
// does not reuse the memory an entry and its Ethernet frame are read from.
// For each entry from 245 up to 244: the entry's words 0 and 1, the frame's
// length and placement checked as muir's `send` checks them, the frame's
// words read, section 2.4's transmit applied to the copy, the copy sent; a
// refused entry is counted in 241 <31:24>; and 245 passes it, under the
// epoch.  A transmit writes no memory.
//
// **RECEIVE.**  Read the page.  Disabled: the Ethernet frame is discarded and
// counted nowhere (section 2.7).  Then muir's order (section 2.4.3): the
// MAC address filter, which counts nothing; the type filter, counted in
// <7:4>; the IPv4 checks, counted in <15:9>; a buffer, none given (250 =
// 251) counted in <23:16>.  None of these touches memory.  Then the claim
// under the epoch, the page again, and the entry at slot 251: a buffer
// shorter than the frame, off a line or past main memory, or a frame longer
// than 1,514 bytes, is counted in <23:16> and nothing is written.  Else the
// frame's ceil(n/4) words, the bytes past its end in the last word 0, the
// length into the entry's word 2, each a fixnum; then 251 under the epoch,
// after the face's barrier; then the claim dropped.  A delivery overtaken
// by a disable (the epoch moved) never moves 251.

#include "qed_ring.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "qed_offload.h"

static const uint8_t BROADCAST[6] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };

static void say(struct qed_ring *g, void (*to)(void *, const char *), const char *fmt, ...)
	__attribute__((format(printf, 3, 4)));

static void say(struct qed_ring *g, void (*to)(void *, const char *), const char *fmt, ...)
{
	if (!to)
		return;
	char line[512];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	to(g->say_ctx, line);
}

void qed_described(const uint8_t *f, size_t n, char *out, size_t len)
{
	if (n < 14) {
		snprintf(out, len, "%zu bytes", n);
		return;
	}
	snprintf(out, len,
		 "%zu bytes, %02x:%02x:%02x:%02x:%02x:%02x from %02x:%02x:%02x:%02x:%02x:%02x, type %04x", n,
		 f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11],
		 (unsigned)f[12] << 8 | f[13]);
}

static void put_counts(struct qed_ring *g, struct qed_face *f)
{
	f->counts(f->ctx, QED_COUNTS(g->type_drops, g->ipv4_drops, g->rx_drops, g->tx_refusals));
}

void qed_ring_init(struct qed_ring *g, struct qed_face *f, const struct qed_host *host)
{
	g->said_misfit = 0;
	g->host = *host;
	f->host(f->ctx, host);
	struct qed_state s;
	f->state(f->ctx, &s);
	g->type_drops = QED_COUNTS_TYPE(s.counts);
	g->ipv4_drops = QED_COUNTS_IPV4(s.counts);
	g->rx_drops = QED_COUNTS_RX(s.counts);
	g->tx_refusals = QED_COUNTS_TX(s.counts);
}

// A ring the fabric would have refused at the enable: more than 256
// entries, off a line, or past main memory.
static int fits(const struct qed_face *f, uint32_t base, uint32_t log2)
{
	return log2 <= 8 && (base & QED_LINE) == 0 && (size_t)base + ((size_t)8 << log2) <= f->mem.words;
}

static int rings_fit(struct qed_ring *g, struct qed_face *f, const struct qed_state *u)
{
	if (fits(f, u->tx_base, u->tx_log2) && fits(f, u->rx_base, u->rx_log2))
		return 1;
	if (!g->said_misfit)
		say(g, g->log, "the rings (%o, %u and %o, %u) do not fit %zu words of main memory; not served",
		    u->tx_base, u->tx_log2, u->rx_base, u->rx_log2, f->mem.words);
	g->said_misfit = 1;
	return 0;
}

// The `n` bytes of a frame at word `at`: byte k is <8(k mod 4)+7:8(k mod 4)>
// of word at + k/4.
static void frame_of(struct qed_mem *m, size_t at, size_t n, uint8_t *out)
{
	uint32_t w[(QED_MAX_FRAME + 3) / 4];
	const size_t words = (n + 3) / 4;
	qed_mem_read(m, at, words, w);
	for (size_t k = 0; k < n; ++k)
		out[k] = (uint8_t)(w[k / 4] >> (8 * (k % 4)));
}

unsigned qed_ring_transmit(struct qed_ring *g, struct qed_face *f, unsigned most)
{
	struct qed_state s, u;
	f->state(f->ctx, &s);
	if (!s.enabled || s.tx_prod == s.tx_cons || !most)
		return 0;
	if (!f->claim(f->ctx, s.epoch))
		return 0;
	f->state(f->ctx, &u);
	if (u.epoch != s.epoch || !u.enabled || !rings_fit(g, f, &u)) {
		f->release(f->ctx);
		return 0;
	}
	unsigned done = 0;
	uint16_t cons = u.tx_cons;
	const uint32_t entries = 1u << u.tx_log2;
	uint8_t frame[QED_MAX_FRAME];
	while (cons != u.tx_prod && done < most) {
		const uint16_t index = cons;
		const size_t e = u.tx_base + 8u * (index % entries);
		uint32_t w[2];
		qed_mem_read(&f->mem, e, 2, w);
		const uint32_t addr = w[0] & QED_ADDRESS, len = w[1];
		char why[96];
		const char *refused = NULL;
		if (len < QED_MIN_FRAME || len > QED_MAX_FRAME) {
			snprintf(why, sizeof why, "length %u, outside %u-%u", len, QED_MIN_FRAME, QED_MAX_FRAME);
			refused = why;
		} else if (addr & QED_LINE) {
			snprintf(why, sizeof why, "its Ethernet frame at %o, off a line", addr);
			refused = why;
		} else if ((size_t)addr + (len + 3) / 4 > f->mem.words) {
			snprintf(why, sizeof why, "its Ethernet frame at %o, past main memory", addr);
			refused = why;
		} else {
			frame_of(&f->mem, addr, len, frame);
			refused = qed_transmit(frame, len);
		}
		cons = (uint16_t)(cons + 1);
		++done;
		if (refused) {
			g->tx_refusals = (g->tx_refusals + 1) & 0xFFu;
			put_counts(g, f);
			say(g, g->trace, "transmit entry %u refused: %s", index, refused);
			say(g, g->log, "transmit entry %u refused: %s", index, refused);
		} else {
			char d[96];
			qed_described(frame, len, d, sizeof d);
			say(g, g->trace, "sent %s", d);
			if (g->send)
				g->send(g->send_ctx, frame, len);
		}
		f->sent(f->ctx, s.epoch, cons);
	}
	f->release(f->ctx);
	return done;
}

int qed_ring_receive(struct qed_ring *g, struct qed_face *f, const uint8_t *frame, size_t n)
{
	char d[96];
	qed_described(frame, n, d, sizeof d);
	struct qed_state s, u;
	f->state(f->ctx, &s);
	if (!s.enabled) {
		say(g, g->trace, "received %s, dropped: the device is disabled", d);
		return 0;
	}
	if (n < 6 || (memcmp(frame, g->host.mac, 6) && memcmp(frame, BROADCAST, 6))) {
		say(g, g->trace, "received %s, dropped: not this device's MAC address", d);
		return 0;
	}
	const char *why = NULL;
	switch (qed_receive(frame, n, &why)) {
	case QED_COUNT_NONE:
		break;
	case QED_COUNT_TYPE:
		g->type_drops = (g->type_drops + 1) & 0xFu;
		put_counts(g, f);
		say(g, g->trace, "received %s, dropped: %s", d, why);
		say(g, g->log, "received %s, dropped: %s", d, why);
		return 0;
	case QED_COUNT_IPV4:
		g->ipv4_drops = (g->ipv4_drops + 1) & 0x7Fu;
		put_counts(g, f);
		say(g, g->trace, "received %s, dropped: %s", d, why);
		say(g, g->log, "received %s, dropped: %s", d, why);
		return 0;
	}
	if (s.rx_prod == s.rx_cons) {
		g->rx_drops = (g->rx_drops + 1) & 0xFFu;
		put_counts(g, f);
		say(g, g->trace, "received %s, dropped: no buffer given", d);
		say(g, g->log, "received %s, dropped: no buffer given", d);
		return 0;
	}
	if (!f->claim(f->ctx, s.epoch)) {
		say(g, g->trace, "received %s, dropped: the device is disabled", d);
		return 0;
	}
	f->state(f->ctx, &u);
	if (u.epoch != s.epoch || !u.enabled || !rings_fit(g, f, &u)) {
		f->release(f->ctx);
		say(g, g->trace, "received %s, dropped: the device is disabled", d);
		return 0;
	}
	const uint16_t index = u.rx_cons;
	const size_t e = u.rx_base + 8u * (index % (1u << u.rx_log2));
	uint32_t w[2];
	qed_mem_read(&f->mem, e, 2, w);
	const uint32_t buf = w[0] & QED_ADDRESS, room = w[1];
	const size_t words = (n + 3) / 4;
	char reason[96];
	reason[0] = 0;
	if (n > QED_MAX_FRAME)
		snprintf(reason, sizeof reason, "longer than %u bytes", QED_MAX_FRAME);
	else if (n > room)
		snprintf(reason, sizeof reason, "entry %u's buffer of %u bytes is too short", index, room);
	else if (buf & QED_LINE)
		snprintf(reason, sizeof reason, "entry %u's buffer at %o, off a line", index, buf);
	else if ((size_t)buf + words > f->mem.words)
		snprintf(reason, sizeof reason, "entry %u's buffer at %o, past main memory", index, buf);
	if (reason[0]) {
		f->release(f->ctx);
		g->rx_drops = (g->rx_drops + 1) & 0xFFu;
		put_counts(g, f);
		say(g, g->trace, "received %s, dropped: %s", d, reason);
		say(g, g->log, "received %s, dropped: %s", d, reason);
		return 0;
	}
	uint32_t data[(QED_MAX_FRAME + 3) / 4];
	memset(data, 0, sizeof data);
	for (size_t k = 0; k < n; ++k)
		data[k / 4] |= (uint32_t)frame[k] << (8 * (k % 4));
	qed_mem_write(&f->mem, buf, words, data);
	const uint32_t len = (uint32_t)n;
	qed_mem_write(&f->mem, e + 2, 1, &len);
	f->delivered(f->ctx, s.epoch, (uint16_t)(index + 1));
	f->release(f->ctx);
	say(g, g->trace, "received %s, into entry %u", d, index);
	return 1;
}
