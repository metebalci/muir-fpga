// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The service loop's one step, over the face: take the next command, do it,
// publish it.  `qfd_face.h` says what the claim and the epoch are for; this
// is the order they are used in.

#ifndef QFD_RING_H
#define QFD_RING_H

#include <time.h>

#include "qfd_face.h"

struct qfd_ring {
	struct qfd *d;
	int seen;             // an epoch has been read
	uint16_t epoch;       // the epoch last read
	long rtc_second;      // the last second written to the clock, -1 for none
	// Said once when the rings do not fit main memory, which the fabric
	// refuses at the enable and so never happens.
	int said_misfit;
	void (*say)(void *ctx, const char *line);
	void *say_ctx;
};

void qfd_ring_init(struct qfd_ring *g, struct qfd *d);

// One command, if there is one to take: 1 if a command was answered or
// dropped by a disable, 0 if there was nothing to do, -1 if the page did not
// take a completion, when the program must stop.
int qfd_ring_step(struct qfd_ring *g, struct qfd_face *f);

// The clock: written when the second has changed since the last write, so
// at least once a second while the loop runs, the fraction first.
void qfd_ring_clock(struct qfd_ring *g, struct qfd_face *f, const struct timespec *now);

#endif
