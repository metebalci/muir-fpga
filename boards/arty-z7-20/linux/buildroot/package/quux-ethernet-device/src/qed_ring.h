// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The device's other half over the face: the transmit ring's entries sent,
// and an Ethernet frame from the host side dropped or delivered.  muir's
// `EthernetDevice::send` and `::deliver` (`src/ethernet_device.rs`) decision
// for decision, and the trace lines are theirs, without muir's time.
// `qed_face.h` says what the claim and the epoch are for; `qed_ring.c` the
// order they are used in.

#ifndef QED_RING_H
#define QED_RING_H

#include <stddef.h>
#include <stdint.h>

#include "qed_face.h"
#include "qed_host.h"

#define QED_MIN_FRAME 14u
#define QED_MAX_FRAME 1514u

struct qed_ring {
	struct qed_host host;     // 253-257, and the MAC address the filter takes
	// 241's four counters, each to its field's width, as this program has
	// counted them; written to the face whenever one moves.
	uint32_t type_drops, ipv4_drops, rx_drops, tx_refusals;
	int said_misfit;          // the rings' misfit said once
	// An Ethernet frame the device sends, to the host side.
	void (*send)(void *ctx, const uint8_t *frame, size_t n);
	void *send_ctx;
	// `--ethernet-trace`: every Ethernet frame sent and received, and why
	// one is refused or dropped, muir's lines without the time.  NULL for
	// none.
	void (*trace)(void *ctx, const char *line);
	// The program's log: why a transmit entry is refused or a received
	// Ethernet frame dropped for a buffer, the type filter or the IPv4
	// checks, the band's bugs (section 2.3, section 2.4.5).  NULL for none.
	void (*log)(void *ctx, const char *line);
	void *say_ctx;
};

// The ring over `f`, its callbacks already set: 253-257 written from `host`,
// and the counters read back from the page, so that a program started again
// counts on.
void qed_ring_init(struct qed_ring *g, struct qed_face *f, const struct qed_host *host);

// Up to `most` transmit entries sent or refused, from 245 up to 244: how
// many 245 passed.
unsigned qed_ring_transmit(struct qed_ring *g, struct qed_face *f, unsigned most);

// An Ethernet frame of `n` bytes from the host side: 1 if it was delivered
// into the receive ring, 0 if it was dropped.
int qed_ring_receive(struct qed_ring *g, struct qed_face *f, const uint8_t *frame, size_t n);

// An Ethernet frame as the trace names it, muir's `described`: its length,
// its destination and source and its type, as far as it has them.
void qed_described(const uint8_t *f, size_t n, char *out, size_t len);

#endif
