// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// quux-ethernet-device's check, on the build host.
//
//     qed_test --vectors FILE                the checksum vectors, muir-sim's file
//     qed_test --script S --out O            a script of rings, as the golden runs it
//     qed_test --unit                        what no script can reach
//
// **THE VECTORS** are muir-sim's `tests/ethernet_vectors.txt`, read from the
// pinned muir beside this tree, as `golden/` reads muir: one set of cases
// for both implementations of section 2.4 (the Ethernet contract, section
// 9).  Every case is run through `qed_transmit` or `qed_receive` and must
// give the file's result: for `tx` the frame sent, in hex, or `refused`,
// with a refused frame left as it was; for `rx`, `delivered`, `dropped by
// type` or `dropped by the IPv4 checks`.  The results come from frames Linux
// made and from a checker written apart from both implementations
// (muir-sim's `tools/ethernet-vectors.py`), never from this program.  The
// file's own shape is asserted too, so that a file cut short is not a pass.

#define _GNU_SOURCE
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/if.h>
#include <linux/if_tun.h>

#include "qed_face.h"
#include "qed_host.h"
#include "qed_offload.h"
#include "qed_ring.h"
#include "qed_tap.h"

static int failures;

static void fail(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stdout, "FAIL: ");
	vfprintf(stdout, fmt, ap);
	fprintf(stdout, "\n");
	va_end(ap);
	++failures;
}

// --- hex ----------------------------------------------------------------------------

static int hexval(int c)
{
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

// `s`, `len` digits, into `out`: the byte count, or -1 for an odd length or a
// character that is not a digit.
static long unhex(const char *s, size_t len, uint8_t *out, size_t room)
{
	if (len % 2 || len / 2 > room)
		return -1;
	for (size_t i = 0; i < len; i += 2) {
		const int a = hexval((unsigned char)s[i]), b = hexval((unsigned char)s[i + 1]);
		if (a < 0 || b < 0)
			return -1;
		out[i / 2] = (uint8_t)(a << 4 | b);
	}
	return (long)(len / 2);
}

static void tohex(const uint8_t *b, size_t n, char *out)
{
	static const char d[] = "0123456789abcdef";
	for (size_t i = 0; i < n; ++i) {
		out[2 * i] = d[b[i] >> 4];
		out[2 * i + 1] = d[b[i] & 15];
	}
	out[2 * n] = 0;
}

// --- the checksum vectors -------------------------------------------------------------

#define MAX_FRAME_BYTES 65536

static void vectors(const char *path)
{
	FILE *fp = fopen(path, "r");
	if (!fp) {
		fail("the checksum vectors: %s: %s", path, strerror(errno));
		return;
	}
	static uint8_t frame[MAX_FRAME_BYTES], before[MAX_FRAME_BYTES];
	static char got[2 * MAX_FRAME_BYTES + 1];
	char *line = NULL;
	size_t cap = 0;
	ssize_t len;
	unsigned lineno = 0, cases = 0, failed = 0, linux_rx = 0, linux_tx = 0, refused = 0;
	unsigned delivered = 0, by_type = 0, by_ipv4 = 0;
	while ((len = getline(&line, &cap, fp)) >= 0) {
		++lineno;
		while (len && (line[len - 1] == '\n' || line[len - 1] == '\r'))
			line[--len] = 0;
		if (!len || line[0] == '#')
			continue;
		// NAME DIRECTION FRAME RESULT, the result the rest of the line.
		char *name = line, *dir = strchr(name, ' ');
		char *hex = dir ? strchr(dir + 1, ' ') : NULL;
		char *result = hex ? strchr(hex + 1, ' ') : NULL;
		if (!result) {
			fail("the checksum vectors: line %u has not four fields", lineno);
			continue;
		}
		*dir++ = 0, *hex++ = 0, *result++ = 0;
		const long n = unhex(hex, strlen(hex), frame, sizeof frame);
		if (n < 0 || n > 1514) {
			fail("the checksum vectors: line %u %s: the frame is not 0 to 1514 bytes of hex", lineno,
			     name);
			continue;
		}
		++cases;
		const int linux_made = !strncmp(name, "linux-", 6);
		if (!strcmp(dir, "tx")) {
			linux_tx += linux_made;
			memcpy(before, frame, (size_t)n);
			const char *why = qed_transmit(frame, (size_t)n);
			if (why) {
				if (memcmp(before, frame, (size_t)n))
					fail("the checksum vectors: line %u %s tx: a refused frame was changed", lineno,
					     name);
				if (!*why)
					fail("the checksum vectors: line %u %s tx: a refusal with no reason", lineno,
					     name);
				snprintf(got, sizeof got, "refused");
			} else {
				tohex(frame, (size_t)n, got);
			}
			refused += !strcmp(result, "refused");
		} else if (!strcmp(dir, "rx")) {
			linux_rx += linux_made;
			const char *why = NULL;
			switch (qed_receive(frame, (size_t)n, &why)) {
			case QED_COUNT_NONE:
				snprintf(got, sizeof got, "delivered");
				break;
			case QED_COUNT_TYPE:
				snprintf(got, sizeof got, "dropped by type");
				break;
			case QED_COUNT_IPV4:
				snprintf(got, sizeof got, "dropped by the IPv4 checks");
				break;
			}
			if (strcmp(got, "delivered") && (!why || !*why))
				fail("the checksum vectors: line %u %s rx: a drop with no reason", lineno, name);
			delivered += !strcmp(result, "delivered");
			by_type += !strcmp(result, "dropped by type");
			by_ipv4 += !strcmp(result, "dropped by the IPv4 checks");
			if (linux_made && strcmp(result, "delivered"))
				fail("the checksum vectors: line %u %s: a frame Linux made, not delivered", lineno,
				     name);
		} else {
			fail("the checksum vectors: line %u %s: direction %s", lineno, name, dir);
			continue;
		}
		if (strcmp(got, result)) {
			size_t at = 0;
			while (got[at] && got[at] == result[at])
				++at;
			at -= at % 2;
			fail("the checksum vectors: line %u %s %s: from byte %zu, expected %.24s, got %.24s",
			     lineno, name, dir, at / 2, result + at, got + at);
			++failed;
		}
		// No frame, cut anywhere, upsets either direction (muir's
		// `every_prefix_is_handled`); under the sanitizers a read past
		// the end is a fault.
		for (long k = 0; k <= n; ++k) {
			const char *why = NULL;
			uint8_t *cut = malloc(k ? (size_t)k : 1);
			memcpy(cut, before, (size_t)k);
			(void)qed_receive(cut, (size_t)k, &why);
			(void)qed_transmit(cut, (size_t)k);
			free(cut);
		}
	}
	free(line);
	fclose(fp);
	// The file is what section 9 asks for, so that a file cut short or the
	// wrong file is not a pass: at least 150 cases, 20 frames Linux made
	// each way, every result five times, ten refusals.
	if (cases < 150 || linux_rx < 20 || linux_tx < 20 || delivered < 5 || by_type < 5 || by_ipv4 < 5
	    || refused < 10)
		fail("the checksum vectors: %s is not the whole file: %u cases, %u and %u frames Linux made, "
		     "%u delivered, %u and %u dropped, %u refused",
		     path, cases, linux_rx, linux_tx, delivered, by_type, by_ipv4, refused);
	// RFC 1071 section 3's worked example.
	static const uint8_t rfc[] = { 0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7 };
	if (qed_ones_sum(rfc, 8) != 0xddf2 || qed_ones_sum(rfc, 7) != 0xdcfb)
		fail("the checksum vectors: RFC 1071's example sums to %04x and %04x, not ddf2 and dcfb",
		     qed_ones_sum(rfc, 8), qed_ones_sum(rfc, 7));
	printf("the checksum vectors: %u cases, %u failed\n", cases, failed);
}

// --- the model of the page ------------------------------------------------------------
//
// **WHAT THE FABRIC OWES, AS A MODEL** (`qed_face_fabric.c` lists it): the
// register page's rules for 240-257, which are muir's `EthernetDevice::write`
// and `::read`, and the face's: STATE, CLAIM, TX_CONS and RX_CONS under the
// epoch, COUNTS and 253-257.  The program's own face (`qed_face_fabric.c`)
// talks to it through the test hooks, so the offsets are the program's.
//
// **AND IT WATCHES THE PROGRAM WHILE IT RUNS.**  Every word of main memory
// the program touches must be touched under the claim; every RX_CONS must
// come after a barrier that followed the last word touched; 245 and 251 may
// only move forward by what the rings hold; and the claim must be dropped
// when a step returns.  A breach is a FAIL line and a failed run, whatever
// the transcript says.

#define PAGE_IDENT 0x51453136u
#define REG_CONTROL 0240u
#define REG_STATUS  0241u
#define REG_GATEWAY 0257u

struct sim {
	uint8_t *pk;
	size_t words;
	int enabled, ie, refused, fault, busy;
	uint16_t epoch;
	uint32_t tx_base, tx_log2, rx_base, rx_log2;
	uint16_t tx_prod, tx_cons, rx_prod, rx_cons, rx_taken;
	uint32_t counts;
	uint32_t mac_high, mac_low, ip, mask, gw;
	int dirty;               // a word touched since the last barrier
	int published;           // 251 moved under the claim now held
	long touches;
	long disable_at;         // a disable at this touch, for the unit checks
	long epoch_at_claim;     // the epoch moves just before this claim, for the unit checks
	unsigned ident, mem_words_said;
	unsigned wlog[64];       // the offsets written, in order
	int nwlog;
};

static uint64_t sim_get(const struct sim *s, size_t k)
{
	uint64_t v = 0;
	for (int i = 4; i >= 0; --i)
		v = v << 8 | s->pk[5 * k + (size_t)i];
	return v;
}

static void sim_put(struct sim *s, size_t k, uint64_t v)
{
	for (int i = 0; i < 5; ++i)
		s->pk[5 * k + (size_t)i] = (uint8_t)(v >> (8 * i));
}

static void sim_init(struct sim *s, size_t words)
{
	free(s->pk);
	memset(s, 0, sizeof *s);
	s->words = words;
	s->pk = calloc(words ? words : 1, 5);
	s->ident = PAGE_IDENT;
	s->mem_words_said = (unsigned)words;
	s->disable_at = -1;
	s->epoch_at_claim = -1;
	// 253-257 at power-on: muir's defaults.
	s->mac_high = 0x0200u;
	s->mac_low = 0x00000001u;
	s->ip = 169u << 24 | 254u << 16 | 100u << 8 | 2u;
	s->mask = 0xFFFFFFFCu;
	s->gw = 169u << 24 | 254u << 16 | 100u << 8 | 1u;
}

static int sim_fits(const struct sim *s, uint32_t base, uint32_t log2)
{
	return (base & 7u) == 0 && log2 <= 8 && base + ((size_t)8 << log2) <= s->words;
}

// muir's `disable`: the indexes and the interrupt enable 0, and the epoch on.
static void sim_disable(struct sim *s)
{
	if (s->enabled)
		s->epoch++;
	s->enabled = s->ie = 0;
	s->tx_prod = s->tx_cons = s->rx_prod = s->rx_cons = s->rx_taken = 0;
}

// A write of the machine's, to word `w` of the register page: muir's rules.
static void sim_reg_write(struct sim *s, unsigned w, uint32_t v)
{
	const int on = s->enabled;
	const uint16_t tx_n = (uint16_t)(1u << s->tx_log2), rx_n = (uint16_t)(1u << s->rx_log2);
	switch (w) {
	case 0240: {
		s->refused = s->fault = 0;
		const int enable = v & 1u, ie = (v >> 8) & 1u;
		if (!on && enable) {
			if (sim_fits(s, s->tx_base, s->tx_log2) && sim_fits(s, s->rx_base, s->rx_log2))
				s->enabled = 1, s->ie = ie;
			else
				s->refused = 1;
		} else if (on && !enable) {
			sim_disable(s);
		} else if (on) {
			s->ie = ie;
		}
		break;
	}
	case 0242: if (!on) s->tx_base = v & 0x0FFFFFFFu; break;
	case 0243: if (!on) s->tx_log2 = v & 017u; break;
	case 0246: if (!on) s->rx_base = v & 0x0FFFFFFFu; break;
	case 0247: if (!on) s->rx_log2 = v & 017u; break;
	case 0244:
		if (on) {
			const uint16_t nw = (uint16_t)v, claimed = (uint16_t)(nw - s->tx_cons);
			if (claimed > tx_n || claimed < (uint16_t)(s->tx_prod - s->tx_cons))
				s->fault = 1;
			else
				s->tx_prod = nw;
		}
		break;
	case 0250:
		if (on) {
			const uint16_t nw = (uint16_t)v, given = (uint16_t)(nw - s->rx_taken);
			if (given > rx_n || given < (uint16_t)(s->rx_prod - s->rx_taken))
				s->fault = 1;
			else
				s->rx_prod = nw;
		}
		break;
	case 0252:
		if (on) {
			const uint16_t nw = (uint16_t)v;
			if ((uint16_t)(nw - s->rx_taken) > (uint16_t)(s->rx_cons - s->rx_taken))
				s->fault = 1;
			else
				s->rx_taken = nw;
		}
		break;
	}
}

static uint32_t sim_reg_read(const struct sim *s, unsigned w)
{
	const int on = s->enabled;
	switch (w) {
	case 0240: return (uint32_t)on | (uint32_t)s->ie << 8;
	case 0241:
		return (uint32_t)on | (uint32_t)(!on && !s->busy) << 1 | (uint32_t)s->refused << 2
		       | (uint32_t)s->fault << 3 | (s->counts & 0xF0u)
		       | (uint32_t)(s->rx_cons != s->rx_taken) << 8 | (s->counts & 0xFFFFFE00u);
	case 0242: return s->tx_base;
	case 0243: return s->tx_log2;
	case 0244: return on ? s->tx_prod : 0;
	case 0245: return on ? s->tx_cons : 0;
	case 0246: return s->rx_base;
	case 0247: return s->rx_log2;
	case 0250: return on ? s->rx_prod : 0;
	case 0251: return on ? s->rx_cons : 0;
	case 0252: return on ? s->rx_taken : 0;
	case 0253: return s->mac_high & 0xFFFFu;
	case 0254: return s->mac_low;
	case 0255: return s->ip;
	case 0256: return s->mask;
	case 0257: return s->gw;
	}
	return 0;
}

static uint32_t sim_rd(void *ctx, unsigned off)
{
	struct sim *s = ctx;
	switch (off) {
	case 0x000: return s->ident;
	case 0x004: return s->mem_words_said;
	case 0x100:
		return (uint32_t)s->enabled | (uint32_t)s->ie << 1 | (uint32_t)s->busy << 2
		       | (uint32_t)(!s->enabled && !s->busy) << 3 | (uint32_t)s->epoch << 16;
	case 0x104: return (uint32_t)s->busy;
	case 0x108: return s->tx_base;
	case 0x10C: return s->tx_log2;
	case 0x110: return s->rx_base;
	case 0x114: return s->rx_log2;
	case 0x118: return s->enabled ? s->tx_prod : 0;
	case 0x11C: return s->enabled ? s->tx_cons : 0;
	case 0x120: return s->enabled ? s->rx_prod : 0;
	case 0x124: return s->enabled ? s->rx_cons : 0;
	case 0x128: return s->enabled ? s->rx_taken : 0;
	case 0x12C: return s->counts;
	case 0x130: return s->mac_high;
	case 0x134: return s->mac_low;
	case 0x138: return s->ip;
	case 0x13C: return s->mask;
	case 0x140: return s->gw;
	}
	fail("the program read offset 0x%x, which the page does not have", off);
	return 0;
}

static void sim_wr(void *ctx, unsigned off, uint32_t v)
{
	struct sim *s = ctx;
	if (s->nwlog < 64)
		s->wlog[s->nwlog++] = off;
	const uint16_t epoch = (uint16_t)(v >> 16), index = (uint16_t)v;
	switch (off) {
	case QED_FABRIC_BARRIER:
		s->dirty = 0;
		return;
	case 0x104:
		s->published = 0;
		if (v & 1u) {
			if (s->epoch_at_claim == 0)
				sim_disable(s);
			if (s->epoch_at_claim >= 0)
				s->epoch_at_claim--;
			s->busy = s->enabled && epoch == s->epoch;
		} else {
			s->busy = 0;
		}
		return;
	case 0x11C:
		if (!s->enabled || epoch != s->epoch)
			return;
		if ((uint16_t)(index - s->tx_cons) > (uint16_t)(s->tx_prod - s->tx_cons))
			fail("the program moved 245 to %u, past 244 at %u from %u", index, s->tx_prod, s->tx_cons);
		else
			s->tx_cons = index;
		return;
	case 0x124:
		if (!s->enabled || epoch != s->epoch)
			return;
		if (s->dirty)
			fail("251 moved with no barrier after the words written");
		if (index != (uint16_t)(s->rx_cons + 1) || s->rx_cons == s->rx_prod)
			fail("the program moved 251 to %u from %u, with 250 at %u", index, s->rx_cons, s->rx_prod);
		else
			s->rx_cons = index;
		s->published = 1;
		return;
	case 0x12C: s->counts = v & QED_COUNTS_MASK; return;
	case 0x130: s->mac_high = v & 0xFFFFu; return;
	case 0x134: s->mac_low = v; return;
	case 0x138: s->ip = v; return;
	case 0x13C: s->mask = v; return;
	case 0x140: s->gw = v; return;
	}
	fail("the program wrote 0x%08x to offset 0x%x, which is not a register it may write", v, off);
}

static void sim_touch(void *ctx)
{
	struct sim *s = ctx;
	if (s->touches++ == s->disable_at)
		sim_disable(s);
	if (!s->busy)
		fail("a word of main memory touched without the claim");
	if (s->published)
		fail("a word of main memory touched after 251 moved");
	s->dirty = 1;
}

static void sim_face(struct sim *s, struct qed_fabric *fb, struct qed_face *f)
{
	memset(fb, 0, sizeof *fb);
	fb->sim_rd = sim_rd;
	fb->sim_wr = sim_wr;
	fb->sim = s;
	char why[256];
	if (qed_fabric_attach(fb, why, sizeof why) != 0)
		fail("the program refused the model's page: %s", why);
	qed_fabric_face(fb, s->pk, f);
	f->mem.touch = sim_touch;
	f->mem.ctx = s;
}

// --- a script, as the golden runs it --------------------------------------------------

struct sent { uint8_t *f; size_t n; };

struct capture {
	struct sent frames[1024];
	int nframes;
	char *lines[4096];
	int nlines;
};

static void cap_send(void *ctx, const uint8_t *frame, size_t n)
{
	struct capture *c = ctx;
	if (c->nframes == 1024) {
		fail("more than 1024 frames sent between two runs");
		return;
	}
	c->frames[c->nframes].f = malloc(n ? n : 1);
	memcpy(c->frames[c->nframes].f, frame, n);
	c->frames[c->nframes++].n = n;
}

static void cap_trace(void *ctx, const char *line)
{
	struct capture *c = ctx;
	if (c->nlines < 4096)
		c->lines[c->nlines++] = strdup(line);
}

static unsigned long long num(const char *s)
{
	if (!strncmp(s, "0x", 2))
		return strtoull(s + 2, NULL, 16);
	return strtoull(s, NULL, 10);
}

static uint64_t fnv(const struct sim *s)
{
	uint64_t h = 0xcbf29ce484222325ull;
	for (size_t k = 0; k < 5 * s->words; ++k) {
		h ^= s->pk[k];
		h *= 0x100000001b3ull;
	}
	return h;
}

// The arrived frames, in order.
struct arrivals {
	uint8_t *f[1024];
	size_t n[1024];
	int head, tail;
};

// The program's whole pass: every frame that arrived received, then every
// transmit posted sent, as the device advanced to the next operation's time
// has done.  The claim is down after each step.
static void program_pass(struct qed_ring *g, struct qed_face *f, struct sim *s, struct arrivals *a)
{
	while (a->head != a->tail) {
		qed_ring_receive(g, f, a->f[a->head], a->n[a->head]);
		free(a->f[a->head]);
		a->head++;
		if (s->busy)
			fail("the claim was held after a delivery");
	}
	// A pass that never ends is a failure, not a hang: 245 must reach 244
	// in the ring's size of entries.
	for (int k = 0; qed_ring_transmit(g, f, 16); ++k) {
		if (s->busy)
			fail("the claim was held after a transmit");
		if (k == 64) {
			fail("the transmits posted were never all taken: 245 at %u, 244 at %u", s->tx_cons,
			     s->tx_prod);
			break;
		}
	}
	if (s->busy)
		fail("the claim was held after a pass");
}

static int run_script(const char *script, const char *outpath)
{
	FILE *in = fopen(script, "r");
	if (!in) {
		fail("%s: %s", script, strerror(errno));
		return 1;
	}
	FILE *out = fopen(outpath, "w");
	if (!out) {
		fail("%s: %s", outpath, strerror(errno));
		fclose(in);
		return 1;
	}
	static struct sim s;
	static struct capture cap;
	static struct arrivals arr;
	memset(&cap, 0, sizeof cap);
	memset(&arr, 0, sizeof arr);
	sim_init(&s, 0);
	struct qed_fabric fb;
	struct qed_face face;
	struct qed_ring g;
	struct qed_host host;
	qed_host_default(&host);
	memset(&g, 0, sizeof g);
	g.send = cap_send;
	g.send_ctx = &cap;
	g.trace = cap_trace;
	g.say_ctx = &cap;
	int have_face = 0;
	qed_hook_bad_access = 0;
	char *line = NULL;
	size_t capn = 0;
	ssize_t len;
	unsigned lineno = 0;
	static uint8_t frame[MAX_FRAME_BYTES];
	while ((len = getline(&line, &capn, in)) >= 0) {
		++lineno;
		char *w[8] = { 0 };
		int nw = 0;
		for (char *t = strtok(line, " \t\r\n"); t && nw < 8; t = strtok(NULL, " \t\r\n"))
			w[nw++] = t;
		if (!nw || w[0][0] == '#')
			continue;
		if (have_face)
			program_pass(&g, &face, &s, &arr);
		const char *op = w[0];
#define WANT(k) do { if (nw <= (k)) { fail("%s:%u: %s wants more", script, lineno, op); goto next; } } while (0)
		if (!strcmp(op, "memory")) {
			WANT(1);
			sim_init(&s, (size_t)num(w[1]));
			sim_face(&s, &fb, &face);
			qed_ring_init(&g, &face, &host);
			have_face = 1;
		} else if (!have_face) {
			fail("%s:%u: `memory` comes first", script, lineno);
		} else if (!strcmp(op, "host")) {
			WANT(3);
			char why[256];
			if (qed_parse_mac(w[1], host.mac, why, sizeof why)
			    || qed_parse_ip_address(w[2], &host.address, &host.netmask, why, sizeof why)
			    || qed_parse_ip_gateway(w[3], &host.gateway, why, sizeof why))
				fail("%s:%u: %s", script, lineno, why);
			qed_ring_init(&g, &face, &host);
		} else if (!strcmp(op, "rings")) {
			WANT(4);
			sim_reg_write(&s, 0242, (uint32_t)num(w[1]));
			sim_reg_write(&s, 0243, (uint32_t)num(w[2]));
			sim_reg_write(&s, 0246, (uint32_t)num(w[3]));
			sim_reg_write(&s, 0247, (uint32_t)num(w[4]));
		} else if (!strcmp(op, "enable")) {
			WANT(1);
			sim_reg_write(&s, 0240, 1u | (uint32_t)num(w[1]) << 8);
		} else if (!strcmp(op, "disable")) {
			sim_reg_write(&s, 0240, 0);
		} else if (!strcmp(op, "reset")) {
			sim_disable(&s);
			s.refused = s.fault = 0;
		} else if (!strcmp(op, "write")) {
			WANT(2);
			sim_reg_write(&s, (unsigned)strtoul(w[1], NULL, 8), (uint32_t)num(w[2]));
		} else if (!strcmp(op, "word")) {
			WANT(2);
			sim_put(&s, (size_t)num(w[1]), num(w[2]) & 0xFFFFFFFFFFull);
		} else if (!strcmp(op, "fill")) {
			WANT(3);
			const size_t a = (size_t)num(w[1]), k = (size_t)num(w[2]);
			for (size_t i = 0; i < k; ++i)
				sim_put(&s, a + i, num(w[3]) & 0xFFFFFFFFFFull);
		} else if (!strcmp(op, "bytes")) {
			WANT(2);
			const size_t a = (size_t)num(w[1]);
			const uint64_t tag = nw > 3 ? num(w[3]) & 0xFFu : 0;
			const long n = unhex(w[2], strlen(w[2]), frame, sizeof frame);
			for (long k = 0; k < n; k += 4) {
				uint32_t v = 0;
				for (long i = 0; i < 4 && k + i < n; ++i)
					v |= (uint32_t)frame[k + i] << (8 * i);
				sim_put(&s, a + (size_t)k / 4, tag << 32 | v);
			}
		} else if (!strcmp(op, "arrive")) {
			WANT(1);
			const long n = strcmp(w[1], "-") ? unhex(w[1], strlen(w[1]), frame, sizeof frame) : 0;
			if (n < 0) {
				fail("%s:%u: not a frame in hex", script, lineno);
			} else if (arr.tail == 1024) {
				fail("%s:%u: more than 1024 frames arrive", script, lineno);
			} else {
				arr.f[arr.tail] = malloc(n ? (size_t)n : 1);
				memcpy(arr.f[arr.tail], frame, (size_t)n);
				arr.n[arr.tail++] = (size_t)n;
			}
		} else if (!strcmp(op, "run")) {
			for (int i = 0; i < cap.nlines; ++i) {
				fprintf(out, "trace %s\n", cap.lines[i]);
				free(cap.lines[i]);
			}
			cap.nlines = 0;
			static char hexed[2 * MAX_FRAME_BYTES + 1];
			for (int i = 0; i < cap.nframes; ++i) {
				tohex(cap.frames[i].f, cap.frames[i].n, hexed);
				fprintf(out, "sent %s\n", hexed);
				free(cap.frames[i].f);
			}
			cap.nframes = 0;
			fprintf(out, "regs");
			for (unsigned r = REG_CONTROL; r <= REG_GATEWAY; ++r)
				fprintf(out, " %08x", sim_reg_read(&s, r));
			fprintf(out, "\nmemory %016llx\n", (unsigned long long)fnv(&s));
		} else {
			fail("%s:%u: %s is not an operation", script, lineno, op);
		}
	next:;
#undef WANT
	}
	free(line);
	fclose(in);
	fclose(out);
	while (arr.head != arr.tail)
		free(arr.f[arr.head++]);
	if (qed_hook_bad_access)
		fail("%s: %lu accesses to main memory not naturally aligned or outside their run", script,
		     qed_hook_bad_access);
	return 0;
}

// --- the flags, against muir's own parsers ------------------------------------------

// Each question of FILE answered as `golden/src/quux_ethernet_device.rs
// --flags` answers it from muir, into OUT.
static void flags(const char *path, const char *outpath)
{
	FILE *fp = fopen(path, "r"), *out = fopen(outpath, "w");
	if (!fp || !out) {
		fail("the flags: %s or %s: %s", path, outpath, strerror(errno));
		return;
	}
	char *line = NULL;
	size_t cap = 0;
	ssize_t len;
	struct qed_host d;
	qed_host_default(&d);
	while ((len = getline(&line, &cap, fp)) >= 0) {
		if (len && line[len - 1] == '\n')
			line[--len] = 0;
		if (!len || line[0] == '#')
			continue;
		char arg[512] = "", what[16] = "", why[512] = "", v[64] = "";
		const char *sp = strchr(line, ' ');
		snprintf(what, sizeof what, "%.*s", (int)(sp ? sp - line : len), line);
		if (sp)
			snprintf(arg, sizeof arg, "%s", sp + 1);
		int r = -1;
		if (!strcmp(what, "mac")) {
			uint8_t m[6];
			if ((r = qed_parse_mac(arg, m, why, sizeof why)) == 0)
				qed_mac_text(m, v);
		} else if (!strcmp(what, "address")) {
			uint32_t a, m;
			if ((r = qed_parse_ip_address(arg, &a, &m, why, sizeof why)) == 0) {
				char t[16];
				qed_ipv4_text(a, t);
				snprintf(v, sizeof v, "%s/%u", t, qed_prefix_length(m));
			}
		} else if (!strcmp(what, "gateway")) {
			uint32_t g;
			if ((r = qed_parse_ip_gateway(arg, &g, why, sizeof why)) == 0)
				qed_ipv4_text(g, v);
		} else if (!strcmp(what, "pair")) {
			char *g = strchr(arg, ' ');
			if (!g) {
				fail("the flags: pair wants two words: %s", line);
				continue;
			}
			*g++ = 0;
			uint32_t a = d.address, m = d.netmask, gw = d.gateway;
			r = strcmp(arg, "-") ? qed_parse_ip_address(arg, &a, &m, why, sizeof why) : 0;
			if (r == 0 && strcmp(g, "-"))
				r = qed_parse_ip_gateway(g, &gw, why, sizeof why);
			if (r == 0)
				r = qed_check_gateway(a, m, gw, !strcmp(g, "-"), why, sizeof why);
			if (r == 0) {
				char ta[16], tg[16];
				qed_ipv4_text(a, ta);
				qed_ipv4_text(gw, tg);
				snprintf(v, sizeof v, "%s/%u %s", ta, qed_prefix_length(m), tg);
			}
		} else {
			fail("the flags: %s is not a question", what);
			continue;
		}
		if (r == 0)
			fprintf(out, "%s => ok %s\n", line, v);
		else
			fprintf(out, "%s => refused %s\n", line, why);
	}
	free(line);
	fclose(fp);
	fclose(out);
}

// --- the unit checks ------------------------------------------------------------------

static int units;

#define CHECK(cond, ...) do { ++units; if (!(cond)) fail(__VA_ARGS__); } while (0)

// A model and the program's ring over it, enabled, with an ARP frame
// queued for each test to use: the transmit ring at 0 (4 entries), the
// receive ring at 64 (8 entries), buffers from 1024.
struct bench {
	struct sim s;
	struct qed_fabric fb;
	struct qed_face face;
	struct qed_ring g;
	struct capture cap;
	struct qed_host host;
};

static const uint8_t ARP_FRAME[42] = {
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x02, 0, 0, 0, 0, 0x02, 0x08, 0x06,
	0, 1, 8, 0, 6, 4, 0, 1, 0x02, 0, 0, 0, 0, 0x02, 169, 254, 100, 1,
	0, 0, 0, 0, 0, 0, 169, 254, 100, 2,
};

static void log_keep(void *ctx, const char *line)
{
	struct capture *c = ctx;
	if (c->nlines < 4096)
		c->lines[c->nlines++] = strdup(line);
}

static void bench_up(struct bench *b, int log_too)
{
	free(b->s.pk);
	memset(b, 0, sizeof *b);
	sim_init(&b->s, 4096);
	sim_face(&b->s, &b->fb, &b->face);
	qed_host_default(&b->host);
	b->g.send = cap_send;
	b->g.send_ctx = &b->cap;
	if (log_too)
		b->g.log = log_keep;
	b->g.say_ctx = &b->cap;
	qed_ring_init(&b->g, &b->face, &b->host);
	sim_reg_write(&b->s, 0242, 0);
	sim_reg_write(&b->s, 0243, 2);
	sim_reg_write(&b->s, 0246, 64);
	sim_reg_write(&b->s, 0247, 3);
	sim_reg_write(&b->s, 0240, 1);
	for (unsigned k = 0; k < 8; ++k) {
		sim_put(&b->s, 64 + 8 * k, 005ull << 32 | (1024u + 384u * k));
		sim_put(&b->s, 64 + 8 * k + 1, 005ull << 32 | 1536u);
	}
	// A transmit entry for each slot, an ARP frame at 3072.
	for (unsigned k = 0; k < 42; k += 4) {
		uint32_t v = 0;
		for (unsigned i = 0; i < 4 && k + i < 42; ++i)
			v |= (uint32_t)ARP_FRAME[k + i] << (8 * i);
		sim_put(&b->s, 3072 + k / 4, 005ull << 32 | v);
	}
	for (unsigned k = 0; k < 4; ++k) {
		sim_put(&b->s, 8 * k, 005ull << 32 | 3072u);
		sim_put(&b->s, 8 * k + 1, 005ull << 32 | 42u);
	}
}

static void bench_down(struct bench *b)
{
	for (int i = 0; i < b->cap.nframes; ++i)
		free(b->cap.frames[i].f);
	for (int i = 0; i < b->cap.nlines; ++i)
		free(b->cap.lines[i]);
	b->cap.nframes = b->cap.nlines = 0;
	free(b->s.pk);
	b->s.pk = NULL;
}

// **THE FACE'S OFFSETS, ON A PAGE OF PLAIN WORDS.**  Every other check runs
// the page through the model's hooks, which take the program's offsets as
// they come; this one maps a 4 KB array as the board maps the page and
// reads back where each operation wrote, so that the layout F1 must build is
// the layout this program uses.
static void unit_face_words(void)
{
	static uint32_t page[1024];
	memset(page, 0, sizeof page);
	page[0x000 / 4] = PAGE_IDENT;
	page[0x004 / 4] = 4096;
	page[0x104 / 4] = 1;   // a claim a program before this one left
	struct qed_fabric fb = { 0 };
	fb.page = page;
	char why[256];
	CHECK(qed_fabric_attach(&fb, why, sizeof why) == 0 && fb.mem_words == 4096,
	      "the face: the page at QE16 with 4096 words was refused: %s", why);
	CHECK(page[0x104 / 4] == 0, "the face: the start did not drop a claim left on the page");
	static uint8_t mem[5 * 4096];
	struct qed_face f;
	qed_fabric_face(&fb, mem, &f);
	page[0x100 / 4] = 0x80070000u | 1u | 2u | 4u;
	page[0x108 / 4] = 0xF0000008u, page[0x10C / 4] = 0x13u;
	page[0x110 / 4] = 0x00000040u, page[0x114 / 4] = 0x3u;
	page[0x118 / 4] = 0x11111u, page[0x11C / 4] = 0x22222u, page[0x120 / 4] = 0x33333u;
	page[0x124 / 4] = 0x44444u, page[0x128 / 4] = 0x55555u, page[0x12C / 4] = 0xFFFFFFFFu;
	struct qed_state s;
	f.state(f.ctx, &s);
	CHECK(s.enabled && s.ie && s.busy && s.epoch == 0x8007, "the face: STATE at 0x100 read wrong");
	CHECK(s.tx_base == 0x00000008u && s.tx_log2 == 3 && s.rx_base == 0x40 && s.rx_log2 == 3,
	      "the face: the rings at 0x108-0x114 read wrong: %x %u %x %u", s.tx_base, s.tx_log2,
	      s.rx_base, s.rx_log2);
	CHECK(s.tx_prod == 0x1111 && s.tx_cons == 0x2222 && s.rx_prod == 0x3333 && s.rx_cons == 0x4444
	      && s.rx_taken == 0x5555, "the face: the indexes at 0x118-0x128 read wrong");
	CHECK(s.counts == QED_COUNTS_MASK, "the face: COUNTS at 0x12C read %08x", s.counts);
	page[0x104 / 4] = 0;
	f.claim(f.ctx, 0x8007);
	CHECK(page[0x104 / 4] == (0x8007u << 16 | 1u), "the face: a claim wrote %08x to 0x104",
	      page[0x104 / 4]);
	f.release(f.ctx);
	CHECK(page[0x104 / 4] == 0, "the face: a release left %08x at 0x104", page[0x104 / 4]);
	f.sent(f.ctx, 7, 0x1234);
	CHECK(page[0x11C / 4] == (7u << 16 | 0x1234u), "the face: TX_CONS at 0x11C holds %08x",
	      page[0x11C / 4]);
	f.delivered(f.ctx, 7, 0x4321);
	CHECK(page[0x124 / 4] == (7u << 16 | 0x4321u), "the face: RX_CONS at 0x124 holds %08x",
	      page[0x124 / 4]);
	f.counts(f.ctx, 0xFFFFFFFFu);
	CHECK(page[0x12C / 4] == QED_COUNTS_MASK, "the face: COUNTS at 0x12C holds %08x", page[0x12C / 4]);
	const struct qed_host h = { { 0x02, 0x12, 0x34, 0x56, 0x78, 0x9a }, 0xC000020Au, 0xFFFFFF00u,
				    0xC0000201u };
	f.host(f.ctx, &h);
	CHECK(page[0x130 / 4] == 0x0212u && page[0x134 / 4] == 0x3456789Au && page[0x138 / 4] == 0xC000020Au
	      && page[0x13C / 4] == 0xFFFFFF00u && page[0x140 / 4] == 0xC0000201u,
	      "the face: 253-257 at 0x130-0x140 hold %08x %08x %08x %08x %08x", page[0x130 / 4],
	      page[0x134 / 4], page[0x138 / 4], page[0x13C / 4], page[0x140 / 4]);
	// The page refused: another ident, and main memory of no words or more
	// than a board keeps.
	page[0] = 0x4E4F4E45u;
	CHECK(qed_fabric_attach(&fb, why, sizeof why) != 0 && strstr(why, "\"NONE\""),
	      "the face: a page reading NONE was taken, or not named: %s", why);
	page[0] = 0x51463133u;
	CHECK(qed_fabric_attach(&fb, why, sizeof why) != 0, "the face: the file device's page was taken");
	page[0] = PAGE_IDENT;
	page[1] = 0;
	CHECK(qed_fabric_attach(&fb, why, sizeof why) != 0, "the face: main memory of 0 words was taken");
	page[1] = QED_MAX_MEM_WORDS + 1;
	CHECK(qed_fabric_attach(&fb, why, sizeof why) != 0, "the face: main memory past a board's was taken");
	page[1] = QED_MAX_MEM_WORDS;
	CHECK(qed_fabric_attach(&fb, why, sizeof why) == 0, "the face: the most main memory was refused");
}

// The delivery's order on the page: the claim, the words, the barrier, 251,
// the release.
static void unit_delivery_order(void)
{
	static struct bench b;
	bench_up(&b, 0);
	sim_reg_write(&b.s, 0250, 1);
	b.s.nwlog = 0;
	qed_ring_receive(&b.g, &b.face, ARP_FRAME, 42);
	const unsigned want[] = { 0x104, QED_FABRIC_BARRIER, 0x124, 0x104 };
	int same = b.s.nwlog == 4;
	for (int i = 0; same && i < 4; ++i)
		same = b.s.wlog[i] == want[i];
	CHECK(same, "a delivery wrote %d offsets, first 0x%x, not the claim, the barrier, 251 and the release",
	      b.s.nwlog, b.s.wlog[0]);
	CHECK(b.s.rx_cons == 1 && (sim_get(&b.s, 64 + 2) & 0xFFFFFFFFFFull) == (005ull << 32 | 42u),
	      "a delivery left 251 at %u and word 2 at %010llx", b.s.rx_cons,
	      (unsigned long long)sim_get(&b.s, 64 + 2));
	bench_down(&b);
}

// **A DISABLE IN THE MIDDLE OF A DELIVERY.**  The words may land, but 251
// never moves, quiet stays low while the claim is held, and the claim is
// dropped; the next frame finds the device disabled and counts nowhere.
static void unit_disable_mid_delivery(void)
{
	static struct bench b;
	for (long at = 2; at < 14; at += 3) {
		bench_up(&b, 0);
		sim_reg_write(&b.s, 0250, 2);
		b.s.disable_at = at;
		qed_ring_receive(&b.g, &b.face, ARP_FRAME, 42);
		CHECK(!b.s.enabled && b.s.rx_cons == 0, "a disable at touch %ld: 251 moved to %u", at,
		      b.s.rx_cons);
		CHECK(!b.s.busy, "a disable at touch %ld: the claim was left held", at);
		const uint32_t before = b.s.counts;
		const long touched = b.s.touches;
		qed_ring_receive(&b.g, &b.face, ARP_FRAME, 42);
		CHECK(b.s.counts == before && b.s.touches == touched,
		      "after a disable: a frame was counted, or memory touched");
		bench_down(&b);
	}
	// Every touch above was under the claim: `sim_touch` fails one that is
	// not, so a disable that quietly dropped the claim would show there.
}

// The epoch moves between the state's read and the claim: the claim is
// refused, no word is touched, and nothing moves.
static void unit_epoch_before_claim(void)
{
	static struct bench b;
	bench_up(&b, 0);
	sim_reg_write(&b.s, 0250, 1);
	b.s.epoch_at_claim = 0;
	qed_ring_receive(&b.g, &b.face, ARP_FRAME, 42);
	CHECK(b.s.touches == 0 && b.s.rx_cons == 0 && !b.s.busy,
	      "an epoch moved before the claim: %ld words touched, 251 at %u", b.s.touches, b.s.rx_cons);
	bench_up(&b, 0);
	sim_reg_write(&b.s, 0244, 1);
	b.s.epoch_at_claim = 0;
	CHECK(qed_ring_transmit(&b.g, &b.face, 16) == 0 && b.s.touches == 0 && b.cap.nframes == 0,
	      "an epoch moved before a transmit's claim: something was read or sent");
	bench_down(&b);
}

// **THE COUNTERS ARE THE PAGE'S TO KEEP**: a program started again reads
// them back and counts on, and none moves another.
static void unit_counts_read_back(void)
{
	static struct bench b;
	bench_up(&b, 0);
	b.s.counts = QED_COUNTS(3, 100, 200, 250);
	qed_ring_init(&b.g, &b.face, &b.host);
	static const uint8_t ipv6[54] = { 0x02, 0, 0, 0, 0, 0x01, 0x02, 0, 0, 0, 0, 0x02, 0x86, 0xDD };
	qed_ring_receive(&b.g, &b.face, ipv6, sizeof ipv6);
	CHECK(b.s.counts == QED_COUNTS(4, 100, 200, 250), "a program started again: 241's counters are %08x",
	      b.s.counts);
	bench_down(&b);
}

// The indexes are 16 bits and run free: a transmit and a delivery across
// 2^16, each at its slot mod the ring's size.
static void unit_wrap_2_16(void)
{
	static struct bench b;
	bench_up(&b, 0);
	b.s.epoch = 0x1234;     // an epoch past eight bits, as a long-running board's
	b.s.tx_cons = 65534, b.s.tx_prod = 1;
	CHECK(qed_ring_transmit(&b.g, &b.face, 16) == 3 && b.s.tx_cons == 1 && b.cap.nframes == 3,
	      "a transmit across 2^16: 245 at %u, %d sent", b.s.tx_cons, b.cap.nframes);
	b.s.rx_taken = b.s.rx_cons = 65535, b.s.rx_prod = 1;
	qed_ring_receive(&b.g, &b.face, ARP_FRAME, 42);
	qed_ring_receive(&b.g, &b.face, ARP_FRAME, 42);
	CHECK(b.s.rx_cons == 1 && (uint32_t)sim_get(&b.s, 64 + 8 * 7 + 2) == 42u
	      && (uint32_t)sim_get(&b.s, 64 + 2) == 42u,
	      "a delivery across 2^16: 251 at %u, slots 7 and 0 not written", b.s.rx_cons);
	bench_down(&b);
}

// A transmit pass takes at most what it is asked for.
static void unit_transmit_most(void)
{
	static struct bench b;
	bench_up(&b, 0);
	b.s.tx_prod = 4;
	CHECK(qed_ring_transmit(&b.g, &b.face, 3) == 3 && b.s.tx_cons == 3,
	      "a pass of at most 3: 245 at %u", b.s.tx_cons);
	CHECK(qed_ring_transmit(&b.g, &b.face, 3) == 1 && b.s.tx_cons == 4, "the pass after: 245 at %u",
	      b.s.tx_cons);
	bench_down(&b);
}

// **THE LOG NAMES EVERY REFUSAL AND DROP THAT IS A BAND'S BUG**, and not the
// frames the filter and a disable leave, which are no one's.
static void unit_log(void)
{
	static struct bench b;
	bench_up(&b, 1);
	static const uint8_t ipv6[54] = { 0x02, 0, 0, 0, 0, 0x01, 0x02, 0, 0, 0, 0, 0x02, 0x86, 0xDD };
	uint8_t other[42];
	memcpy(other, ARP_FRAME, 42);
	other[0] = 0x02, other[5] = 0x07;
	qed_ring_receive(&b.g, &b.face, other, 42);              // the filter: nothing
	CHECK(b.cap.nlines == 0, "the log named a frame for another station");
	qed_ring_receive(&b.g, &b.face, ipv6, 54);               // type
	qed_ring_receive(&b.g, &b.face, ARP_FRAME, 42);          // no buffer
	sim_put(&b.s, 64 + 1, 005ull << 32 | 41u);
	sim_reg_write(&b.s, 0250, 1);
	qed_ring_receive(&b.g, &b.face, ARP_FRAME, 42);          // too short
	sim_put(&b.s, 1, 005ull << 32 | 13u);
	sim_reg_write(&b.s, 0244, 1);
	qed_ring_transmit(&b.g, &b.face, 16);                    // refused
	CHECK(b.cap.nlines == 4 && strstr(b.cap.lines[0], "type not IPv4 or ARP")
	      && strstr(b.cap.lines[1], "no buffer given") && strstr(b.cap.lines[2], "too short")
	      && strstr(b.cap.lines[3], "transmit entry 0 refused: length 13"),
	      "the log: %d lines, not the four drops and refusals", b.cap.nlines);
	sim_reg_write(&b.s, 0240, 0);
	qed_ring_receive(&b.g, &b.face, ipv6, 54);               // disabled: nothing
	CHECK(b.cap.nlines == 4, "the log named a frame that arrived while disabled");
	bench_down(&b);
}

// **THE TAP: IFF_TAP | IFF_NO_PI, NEVER IFF_VNET_HDR, AND NO OFFLOAD.**
static unsigned long ioctls[8];
static unsigned short ioctl_flags[8];
static int nioctls;
static unsigned short tap_reports;

static int fake_open(const char *path, int flags)
{
	(void)flags;
	return strcmp(path, "/dev/net/tun") ? -1 : dup(1);
}

static int fake_ioctl(int fd, unsigned long request, void *arg)
{
	(void)fd;
	struct ifreq *r = arg;
	if (nioctls < 8) {
		ioctls[nioctls] = request;
		ioctl_flags[nioctls++] = (unsigned short)r->ifr_flags;
	}
	if (request == TUNGETIFF)
		r->ifr_flags = (short)tap_reports;
	return 0;
}

static void unit_tap(void)
{
	char why[256];
	qed_hook_open = fake_open;
	qed_hook_ioctl = fake_ioctl;
	nioctls = 0;
	tap_reports = IFF_TAP | IFF_NO_PI;
	const int fd = qed_tap_open("quux0", why, sizeof why);
	CHECK(fd >= 0, "the tap: an open the kernel took was refused: %s", why);
	if (fd >= 0)
		close(fd);
	int offload = 0, vnet = 0;
	for (int i = 0; i < nioctls; ++i) {
		offload |= ioctls[i] == TUNSETOFFLOAD || ioctls[i] == TUNSETVNETHDRSZ;
		if (ioctls[i] == TUNSETIFF)
			vnet |= (ioctl_flags[i] & IFF_VNET_HDR) || ioctl_flags[i] != (IFF_TAP | IFF_NO_PI);
	}
	CHECK(nioctls >= 1 && ioctls[0] == TUNSETIFF && !vnet,
	      "the tap: TUNSETIFF was not asked for IFF_TAP | IFF_NO_PI alone (0x%04x)", ioctl_flags[0]);
	CHECK(!offload, "the tap: an offload or a virtio-net header's size was asked for");
	// A tap the kernel says has a virtio-net header, or packet information,
	// is refused.
	tap_reports = IFF_TAP | IFF_NO_PI | IFF_VNET_HDR;
	CHECK(qed_tap_open("quux0", why, sizeof why) < 0, "the tap: one with IFF_VNET_HDR was taken");
	tap_reports = IFF_TAP;
	CHECK(qed_tap_open("quux0", why, sizeof why) < 0, "the tap: one with packet information was taken");
	qed_hook_open = NULL;
	qed_hook_ioctl = NULL;
}

// **PACKED STORAGE, A RUN FROM ANY WORD.**  The program reads only entries
// and frames, which sit on lines, so a run that starts on a line is all the
// scripts make; this reads and writes runs from every start in a line and of
// every length to past `PACK_RUN`, through a mapping whose every access is
// counted, and each must be naturally aligned, stay inside its run and give
// back what was put.
static void unit_mem(void)
{
	static uint8_t pk[5 * 256];
	struct qed_mem m = { pk, 256, NULL, NULL };
	static uint32_t in[160], out[160];
	qed_hook_bad_access = 0;
	int wrong = 0;
	for (size_t k = 0; k < 8; ++k)
		for (size_t n = 1; n <= 140; n += 3) {
			memset(pk, 0x5A, sizeof pk);
			for (size_t i = 0; i < n; ++i)
				in[i] = (uint32_t)(0x9E3779B9u * (k + 1) * (i + 7));
			qed_mem_write(&m, k, n, in);
			qed_mem_read(&m, k, n, out);
			wrong += memcmp(in, out, n * sizeof *in) != 0;
			// The tag of every word written is a fixnum's, and the bytes
			// on either side of the run are untouched.
			for (size_t i = 0; i < n; ++i)
				wrong += pk[5 * (k + i) + 4] != QED_TAG_FIXNUM;
			wrong += k && pk[5 * k - 1] != 0x5A;
			wrong += pk[5 * (k + n)] != 0x5A;
		}
	CHECK(!wrong, "packed storage: %d runs read back wrong, or reached outside themselves", wrong);
	CHECK(!qed_hook_bad_access, "packed storage: %lu accesses not naturally aligned or outside their run",
	      qed_hook_bad_access);
}

static void unit_checks(void)
{
	unit_mem();
	unit_face_words();
	unit_delivery_order();
	unit_disable_mid_delivery();
	unit_epoch_before_claim();
	unit_counts_read_back();
	unit_wrap_2_16();
	unit_transmit_most();
	unit_log();
	unit_tap();
	printf("the unit checks: %d\n", units);
}

int main(int argc, char **argv)
{
	if (argc == 3 && !strcmp(argv[1], "--vectors")) {
		vectors(argv[2]);
	} else if (argc == 5 && !strcmp(argv[1], "--flags") && !strcmp(argv[3], "--out")) {
		flags(argv[2], argv[4]);
	} else if (argc == 5 && !strcmp(argv[1], "--script") && !strcmp(argv[3], "--out")) {
		run_script(argv[2], argv[4]);
	} else if (argc == 2 && !strcmp(argv[1], "--unit")) {
		unit_checks();
	} else {
		fprintf(stderr, "usage: qed_test --vectors FILE | --flags FILE --out O | --script S --out O | --unit\n");
		return 2;
	}
	if (failures)
		printf("FAIL: %d failures\n", failures);
	return failures ? 1 : 0;
}
