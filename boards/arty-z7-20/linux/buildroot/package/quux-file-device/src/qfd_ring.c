// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The service loop's one step.  The order, and why:
//
//   1. Read the page.  An epoch other than the one last read means a disable
//      (or a machine reset) came in between: every handle is closed and every
//      write discarded, as muir's disable does, and the page is told none are
//      open.
//   2. Nothing waiting (STATE <4>) is nothing to do.
//   3. Take the claim under that epoch, and read the page again under it:
//      from here a disable holds quiet low until the claim is dropped, so
//      the machine does not reuse the memory this command reads and writes.
//   4. Do the command at slot `165 mod size`: the entry and buffer A read,
//      the host's operation, buffer B and the response written.
//   5. Read the page a third time.  If the epoch has moved, the command was
//      overtaken: its host effect stands, as the contract allows, but its
//      handles are closed and nothing is published.
//   6. The handles open, then the completion, both under the epoch, then
//      the claim dropped.  The page stages the count and lands it with the
//      completion, so the machine sees 161 <23:16> and 170 move together, as
//      on muir, and a checkpoint that finds 164 = 165 finds the count that
//      goes with it.  It is written for every command, which costs one word
//      and leaves no command whose count the page could miss.

#include "qfd_ring.h"

#include <stdio.h>
#include <string.h>

void qfd_ring_init(struct qfd_ring *g, struct qfd *d)
{
	memset(g, 0, sizeof *g);
	g->d = d;
	g->rtc_second = -1;
}

// A ring the fabric would have refused at the enable: more than 256
// entries, off a line (4 words, 8 on revision 13), or past main memory.
static int fits(const struct qfd_face *f, uint32_t base, uint32_t log2)
{
	return log2 <= 8 && (base & qfd_mem_line(&f->mem)) == 0
	       && (size_t)base + ((size_t)8 << log2) <= f->mem.words;
}

int qfd_ring_step(struct qfd_ring *g, struct qfd_face *f)
{
	struct qfd_state s, u;
	f->state(f->ctx, &s);
	if (!g->seen || s.epoch != g->epoch) {
		qfd_reset(g->d);
		g->epoch = s.epoch;
		g->seen = 1;
		f->handles(f->ctx, s.epoch, 0);
	}
	if (!s.work)
		return 0;
	if (!f->claim(f->ctx, s.epoch))
		return 0;
	f->state(f->ctx, &u);
	if (u.epoch != s.epoch || !u.work) {
		f->release(f->ctx);
		return 0;
	}
	if (!fits(f, u.cmd_base, u.cmd_log2) || !fits(f, u.resp_base, u.resp_log2)) {
		if (!g->said_misfit && g->say) {
			char line[200];
			snprintf(line, sizeof line,
				 "the rings (%o, %u and %o, %u) do not fit %zu words of main memory; not served",
				 u.cmd_base, u.cmd_log2, u.resp_base, u.resp_log2, f->mem.words);
			g->say(g->say_ctx, line);
		}
		g->said_misfit = 1;
		f->release(f->ctx);
		return 0;
	}
	const uint16_t i = u.resp_prod;
	const size_t cmd_at = u.cmd_base + 8u * (i % (1u << u.cmd_log2));
	const size_t resp_at = u.resp_base + 8u * (i % (1u << u.resp_log2));
	qfd_execute(g->d, &f->mem, cmd_at, resp_at);
	f->state(f->ctx, &u);
	if (u.epoch != s.epoch) {
		qfd_reset(g->d);
		g->epoch = u.epoch;
		f->release(f->ctx);
		return 1;
	}
	f->handles(f->ctx, s.epoch, qfd_handles_open(g->d));
	f->complete(f->ctx, s.epoch, (uint16_t)(i + 1));
	f->state(f->ctx, &u);
	f->release(f->ctx);
	// **A COMPLETION THE PAGE DID NOT TAKE STOPS THE PROGRAM.**  Under the
	// same epoch the index must have moved; if it has not, the command
	// would be taken again and its host effect done twice, which is worse
	// than a device that stops answering.
	if (u.epoch == s.epoch && u.resp_prod != (uint16_t)(i + 1)) {
		if (g->say) {
			char line[160];
			snprintf(line, sizeof line,
				 "the page did not take the completion of command %u (it reads %u); stopping",
				 (unsigned)i, (unsigned)u.resp_prod);
			g->say(g->say_ctx, line);
		}
		return -1;
	}
	return 1;
}

void qfd_ring_clock(struct qfd_ring *g, struct qfd_face *f, const struct timespec *now)
{
	if ((long)now->tv_sec == g->rtc_second)
		return;
	g->rtc_second = (long)now->tv_sec;
	const long long s = (long long)now->tv_sec;
	f->rtc(f->ctx, s < 0 ? 0 : s > 0xFFFFFFFFll ? 0xFFFFFFFFu : (uint32_t)s, (uint32_t)now->tv_nsec);
}
