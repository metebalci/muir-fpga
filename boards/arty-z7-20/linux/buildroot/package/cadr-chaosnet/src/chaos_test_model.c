// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The model of the fabric half, moved here whole when a second suite needed
// it.  `chaos_test_model.h` is the reference for what it is and what it is
// not; this file only behaves.

#include "chaos_test_model.h"

#include <string.h>

#include "chaos_packet.h"

// **THE MACHINE'S OWN CLOCK.**  A burst check sets a service time and advances
// `now`; the machine then empties its incoming buffer by itself `service_ns`
// after a frame was stored in it, and the frame's packet number joins the list
// of what it took.  With no service time nothing happens here and the face
// checks drive the machine by hand, which is what they want.
//
// It runs at every read and every write rather than on a tick of its own, so
// that a check advancing the clock and then reading `STAT` sees what the
// fabric would have shown it.  Nothing between two accesses can observe the
// difference.
static void advance(struct face_model *m)
{
	if (!m->service_ns || !m->rx_busy || m->now < m->free_at)
		return;
	// Word 6 of a frame is the packet number (`chaos_face.h`'s word order),
	// which is what a burst check tells its frames apart by.
	if (m->delivered < MODEL_SEEN)
		m->seen[m->delivered] = m->rx[6];
	++m->delivered;
	chaos_model_drains(m);
}


void chaos_model_init(struct face_model *m)
{
	memset(m, 0, sizeof *m);
	m->ident = IDENT_CHAO;
	// The machine's microcode has started and written Clear Receiver, so
	// the receiver is listening.  Before that it is not, which is its own
	// check below.
	m->rx_armed = 1;
}

static uint32_t model_stat(const struct face_model *m)
{
	return (m->tx_valid ? ST_TX_VALID : 0u) | (m->rx_busy ? ST_RX_BUSY : 0u) |
	       (m->rx_armed ? ST_RX_ARMED : 0u) | (m->looped ? ST_LOOPED : 0u);
}

static uint32_t model_read(struct chaos_face *f, unsigned word)
{
	struct face_model *m = f->ctx;
	advance(m);
	++m->reads;
	if (word >= W_TX && word < W_TX + W_WORDS) {
		const unsigned k = word - W_TX;
		// The window holds the waiting frame; past its length there is
		// nothing, and nothing is what it reads.
		return m->tx_valid && k < m->txlen ? m->tx[k] : 0u;
	}
	if (word >= W_RX && word < W_RX + W_WORDS)
		// The RX window is written, not read.  A read of it is harmless
		// and gives back what was written, so a driver that reads one
		// back to check itself is not lied to.
		return m->rxwin[word - W_RX];
	switch (word) {
	case R_IDENT:	return m->ident;
	case R_STAT:	return model_stat(m);
	case R_MYADDR:	return m->myaddr;
	case R_TXLEN:	return m->tx_valid ? m->txlen : 0u;
	case R_RXLEN:	return m->rxlen;
	case R_CTL:	return 0u;	/* the read-only bits are a reset count; none has happened */
	case R_LOST:	return m->lost;
	case R_IRQ:	return m->irq;
	case R_IRQEN:	return m->irqen;
	default:
		// Every address in the window the fabric claims must be
		// ANSWERED --- a read nothing answers hangs both Arm cores ---
		// so the model answers, and `chaos_face.c` never reads one of
		// these.  What such a word holds is the fabric half's to say.
		return 0u;
	}
}

static void model_ctl(struct face_model *m, uint32_t v)
{
	if (v & DO_TX_TAKE) {
		if (m->tx_valid) {
			m->tx_valid = 0;
			m->txlen = 0;
			m->irq &= ~IRQ_TX;
			++m->takes;
		} else {
			// Taking a frame that is not there: the machine's
			// Transmit Done would come up for a transmission
			// nobody made.
			++m->faults;
		}
	}
	if (v & DO_RX_COMMIT) {
		++m->commits;
		if (m->rxlen == 0 || m->rxlen > MODEL_MAX_WORDS) {
			++m->faults;
			return;
		}
		// **Refused, and counted in LOST**, when the machine has not
		// read the previous packet out --- which is exactly what the
		// interface's four-bit Lost Count means (AIM-628 §7).  The
		// model also refuses when the receiver is not armed and when
		// the interface is looped back; whether the fabric does is not
		// known, and no check below asserts that it does --- what they
		// assert is that the driver reports a refusal it could not have
		// predicted, which is why it reads LOST rather than guessing.
		if (m->rx_busy || !m->rx_armed || m->looped) {
			if (m->lost != 0xFFFFFFFFu)
				++m->lost;	/* saturating, not wrapping */
			return;
		}
		memcpy(m->rx, m->rxwin, (size_t)m->rxlen * sizeof m->rx[0]);
		m->rx_words = m->rxlen;
		m->rx_busy = 1;
		// The machine will have read it out and written Clear Receiver
		// this long from now, if anybody is servicing this interface.
		m->free_at = m->now + m->service_ns;
	}
	if (v & DO_RX_ABORT) {
		++m->aborts;
		m->rxlen = 0;
	}
}

static void model_write(struct chaos_face *f, unsigned word, uint32_t v)
{
	struct face_model *m = f->ctx;
	advance(m);
	++m->writes;
	if (word >= W_RX && word < W_RX + W_WORDS) {
		m->rxwin[word - W_RX] = (uint16_t)v;
		return;
	}
	if (word >= W_TX && word < W_TX + W_WORDS) {
		++m->faults;		/* the TX window is read-only */
		return;
	}
	switch (word) {
	case R_MYADDR:	m->myaddr = v & 0xFFFFu; return;
	case R_RXLEN:	m->rxlen = v; return;
	case R_CTL:	model_ctl(m, v); return;
	case R_IRQ:	m->irq &= ~v; return;
	case R_IRQEN:	m->irqen = v; return;
	default:	++m->faults; return;	/* 0, 1, 3 and 6 are read-only */
	}
}

void chaos_model_attach(struct chaos_face *f, struct face_model *m)
{
	f->read = model_read;
	f->write = model_write;
	f->ctx = m;
}

// The machine puts a frame in its outgoing buffer and reads START.
void chaos_model_transmits(struct face_model *m, const uint16_t *words, unsigned n)
{
	memcpy(m->tx, words, (size_t)n * sizeof m->tx[0]);
	m->txlen = n;
	m->tx_valid = 1;
	m->irq |= IRQ_TX;
}

// The machine reads the incoming buffer out and writes Clear Receiver.
void chaos_model_drains(struct face_model *m)
{
	m->rx_busy = 0;
	m->rx_words = 0;
	m->irq |= IRQ_RX_FREE;
}

// --- a frame to send through the seam -------------------------------------
//
// A packet from 3040 to 3050 carrying `number`, which is what a burst check
// tells its frames apart by, and which the face checks leave at 1.  It is the
// packet `chaos_test_udp.c` pins the bytes of: one frame described once, so
// that a word order wrong in one place is wrong in both and shows.

static unsigned model_frame_to(uint16_t *out, unsigned data_len, unsigned number,
			       uint16_t cable_dest)
{
	struct chaos_packet p;
	memset(&p, 0, sizeof p);
	// The opcode is an RFC because one of them has to be, and this seam
	// never looks inside a frame: the program routes by the cable
	// destination alone and parses a packet only to print a trace line.  So
	// a burst of these stands for a burst of anything.
	p.opcode = CHAOS_RFC;
	p.dest = 03050;
	p.source = 03040;
	p.source_index = 021;
	p.number = (uint16_t)number;
	p.len = (uint16_t)data_len;
	// Every byte different from its neighbors and from its own index's low
	// bits, so a swap, a shift or a lost byte shows; and different from
	// frame to frame, so that a burst check comparing the words the machine
	// took out cannot pass on the wrong frame.
	for (unsigned k = 0; k < data_len; ++k)
		p.data[k] = (uint8_t)(0x41u + ((k + number) % 59u));
	return chaos_packet_frame(&p, cable_dest, 03040, out, CHAOS_PKT_MAX_WORDS);
}

unsigned chaos_model_frame(uint16_t *out, unsigned data_len, unsigned number)
{
	return model_frame_to(out, data_len, number, 03050);
}

// Addressed to everybody.  The cable destination is the ONLY word that differs
// from the frame above, for the reason `chaos_test_model.h` gives at the
// declaration.
unsigned chaos_model_broadcast(uint16_t *out, unsigned data_len, unsigned number)
{
	return model_frame_to(out, data_len, number, 0);
}
