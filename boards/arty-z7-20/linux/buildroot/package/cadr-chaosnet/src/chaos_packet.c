// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A Chaosnet packet, its frame and its check word: `muir::chaos::packet`
// ported.  `chaos_packet.h` is the reference for what each piece is.

#include "chaos_packet.h"

#include <stdio.h>
#include <string.h>

const char *chaos_op_name(unsigned op, char *into, size_t into_len)
{
	switch (op) {
	case CHAOS_RFC: return "RFC";
	case CHAOS_OPN: return "OPN";
	case CHAOS_CLS: return "CLS";
	case CHAOS_FWD: return "FWD";
	case CHAOS_ANS: return "ANS";
	case CHAOS_SNS: return "SNS";
	case CHAOS_STS: return "STS";
	case CHAOS_RUT: return "RUT";
	case CHAOS_LOS: return "LOS";
	case CHAOS_LSN: return "LSN";
	case CHAOS_MNT: return "MNT";
	case CHAOS_EOF: return "EOF";
	case CHAOS_UNC: return "UNC";
	case CHAOS_BRD: return "BRD";
	default: break;
	}
	if (op >= CHAOS_DWD)
		snprintf(into, into_len, "DWD%o", op);
	else if (op >= CHAOS_DAT)
		snprintf(into, into_len, "DAT%o", op);
	else
		snprintf(into, into_len, "op%o", op);
	return into;
}

unsigned chaos_packet_words(const struct chaos_packet *p, uint16_t *out, unsigned max)
{
	const unsigned data_words = ((unsigned)p->len + 1u) / 2u;
	const unsigned n = CHAOS_PKT_HEADER_WORDS + data_words;
	if (n > max)
		return 0;
	out[0] = (uint16_t)((unsigned)p->opcode << 8);
	out[1] = (uint16_t)(((unsigned)p->forward << 12) | ((unsigned)p->len & 07777u));
	out[2] = p->dest;
	out[3] = p->dest_index;
	out[4] = p->source;
	out[5] = p->source_index;
	out[6] = p->number;
	out[7] = p->ack;
	// AIM-628 §3.6: "The first 8-bit byte in a 16-bit word is the one in
	// the arithmetically least-significant position."  An odd last byte
	// sits in the low half with "a garbage padding byte in its high half",
	// §7; the padding here is zero.
	for (unsigned k = 0; k < data_words; ++k) {
		const unsigned lo = 2u * k;
		const unsigned hi = lo + 1u;
		out[CHAOS_PKT_HEADER_WORDS + k] =
			(uint16_t)(p->data[lo] |
				   ((hi < p->len ? (unsigned)p->data[hi] : 0u) << 8));
	}
	return n;
}

unsigned chaos_packet_frame(const struct chaos_packet *p, uint16_t cable_dest,
			    uint16_t cable_source, uint16_t *out, unsigned max)
{
	const unsigned n = chaos_packet_words(p, out, max);
	if (n == 0 || n + CHAOS_PKT_TRAILER_WORDS > max)
		return 0;
	out[n] = cable_dest;
	out[n + 1] = cable_source;
	// The check word is over the words in the order written --- header,
	// data, cable destination, then the source the hardware adds --- and
	// not over itself.
	out[n + 2] = chaos_check_word(out, n + 2);
	return n + CHAOS_PKT_TRAILER_WORDS;
}

int chaos_frame_parse(const uint16_t *words, unsigned n, struct chaos_frame *out,
		      const char **why)
{
	static const char *unused;
	if (!why)
		why = &unused;
	*why = NULL;
	if (n < CHAOS_PKT_HEADER_WORDS + CHAOS_PKT_TRAILER_WORDS) {
		*why = "too few words for a header and a trailer";
		return -1;
	}
	if (n > CHAOS_PKT_MAX_WORDS) {
		*why = "more words than any Chaos packet";
		return -1;
	}
	const unsigned body = n - CHAOS_PKT_TRAILER_WORDS;
	const unsigned count = words[1] & 07777u;
	if (count > CHAOS_PKT_MAX_DATA) {
		*why = "a data count past the 488 bytes a packet carries";
		return -1;
	}
	if (body != CHAOS_PKT_HEADER_WORDS + (count + 1u) / 2u) {
		*why = "the data count does not agree with the frame's length";
		return -1;
	}
	struct chaos_packet *p = &out->packet;
	memset(p, 0, sizeof *p);
	p->opcode = (uint8_t)(words[0] >> 8);
	p->forward = (uint8_t)(words[1] >> 12);
	p->dest = words[2];
	p->dest_index = words[3];
	p->source = words[4];
	p->source_index = words[5];
	p->number = words[6];
	p->ack = words[7];
	p->len = (uint16_t)count;
	for (unsigned k = 0; k < (count + 1u) / 2u; ++k) {
		const uint16_t w = words[CHAOS_PKT_HEADER_WORDS + k];
		if (2u * k < count)
			p->data[2u * k] = (uint8_t)w;
		if (2u * k + 1u < count)
			p->data[2u * k + 1u] = (uint8_t)(w >> 8);
	}
	out->cable_dest = words[body];
	out->cable_source = words[body + 1];
	out->check = words[body + 2];
	out->check_ok = chaos_check_word(words, body + 2) == out->check;
	return 0;
}

// The Fairchild 9401 at LMTBUF C09 dividing by CRC-16, `x^16 + x^15 + x^2 + 1`,
// its select pins grounded, from a cleared register, each word
// most-significant bit first --- which is the order the two 74165s at B12 and
// B13 shift a word out.  `muir::chaos::packet::check_word` transcribed; its
// own comment says this is the one arrangement that reproduces the word the
// netlist board itself produced, and is not read off a document.
uint16_t chaos_check_word(const uint16_t *words, unsigned n)
{
	uint32_t r = 0;		/* stage k in bit k */
	for (unsigned i = 0; i < n; ++i) {
		const uint16_t w = words[i];
		for (int k = 15; k >= 0; --k) {
			const int d = (w >> k) & 1;
			const int fb = d ^ ((r >> 15) & 1);
			uint32_t next = (r << 1) & 0xffffu;
			if (fb)
				next ^= 1u | (1u << 2) | (1u << 15);
			r = next;
		}
	}
	return (uint16_t)r;
}
