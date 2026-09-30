// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The file device's page in the fabric: THE ONE FILE THAT KNOWS ITS LAYOUT.
//
// One 4 KB page on the processor-to-fabric port the other faces use, at the
// pack side's base + 0x4000 on every board, in QUUX's bitstreams only; on a
// CADR's the address is the default slave's and reads "NONE".  Every access
// is one aligned 32-bit word.  Byte offsets:
//
//   0x000 IDENT        RO  "QFD9", 0x51464439, to revision 12; "QF13",
//                          0x51463133, on revision 13
//   0x010 RTC_SECONDS  RW  word 103 as the machine reads it; a write sets the
//                          seconds, with the fraction staged at 0x014
//   0x014 RTC_FRACTION RW  ns into the second; a write stages it
//   0x100 STATE        RO  <0> enabled, <1> interrupt enable, <2> busy (the
//                          claim), <3> quiet, <4> work, <5> a completion
//                          refused (sticky), <31:16> the epoch
//   0x104 CLAIM        RW  {epoch, <0> 1} takes the claim if enabled and the
//                          epoch matches; <0> 0 drops it; reads <0> busy
//   0x108 CMD_BASE     RO  162      0x10C CMD_LOG2   RO  163
//   0x110 RESP_BASE    RO  166      0x114 RESP_LOG2  RO  167
//                          (the bases' <23:0>, and <27:0> on revision 13)
//   0x118 CMD_PROD     RO  164, once the processor's write buffer has drained
//   0x11C RESP_PROD    RW  165 = 170; {epoch, index} completes up to index
//   0x120 RESP_CONS    RO  171
//   0x124 HANDLES      RW  {epoch, count<7:0>}, staged: it lands with the next
//                          completion accepted, so 161 <23:16> and 170 move in
//                          the same tick; reads the count the machine sees;
//                          zeroed at a disable
//   0x128 MEM_WORDS    RO  main memory, in words: the boards << 16
//
// **REVISION 13 IS A PAGE OF ITS OWN NAME** (contract G2 §4.3, appendix
// A1.10): the same offsets and rules, IDENT "QF13", the rings' bases 28 bits,
// and main memory packed storage, 5 bytes a word at the board's
// `CADR_BOARD_QUUX13_MAIN_BASE`, up to 64M words.  The name is what tells
// this program which layout main memory has, and a program of either
// revision refuses the other's page rather than reading its memory wrong.
// **The fabric's side is not built yet**: this is what it owes.
//
// The fabric's side of it is the fabric's to hold; this file is the only
// place the offsets are written on this side, and `qfd_test.c` drives it
// against a model of those rules.
//
// **THE BARRIER BEFORE THE COMPLETION.**  Buffer B and the response entry are
// written through an uncached mapping of DDR (`/dev/mem`, O_SYNC), and the
// completion is a write to this page, which tells the fabric to invalidate
// the machine's cache and move the index.  The machine must not see the index
// before the words.  This is the pattern the disk pack program already uses
// on every board --- words into DDR, `__sync_synchronize()`, then the face
// register that makes the fabric read them over its memory port --- with a
// `dsb sy` after it, which waits for the writes to complete rather than only
// ordering them.  **It is not measured for this page**: it becomes a check on
// the board once a QUUX bitstream carries the page.

#include "qfd_face.h"

#include <stdio.h>

#define QFD_IDENT        0x51464439u
#define QFD_IDENT_13     0x51463133u	/* "QF13" */
#define OFF_IDENT        0x000u
#define OFF_RTC_SECONDS  0x010u
#define OFF_RTC_FRACTION 0x014u
#define OFF_STATE        0x100u
#define OFF_CLAIM        0x104u
#define OFF_CMD_BASE     0x108u
#define OFF_CMD_LOG2     0x10Cu
#define OFF_RESP_BASE    0x110u
#define OFF_RESP_LOG2    0x114u
#define OFF_CMD_PROD     0x118u
#define OFF_RESP_PROD    0x11Cu
#define OFF_RESP_CONS    0x120u
#define OFF_HANDLES      0x124u
#define OFF_MEM_WORDS    0x128u

static uint32_t reg_rd(struct qfd_fabric *fb, unsigned off)
{
#ifdef QFD_TEST_HOOKS
	if (fb->sim_rd)
		return fb->sim_rd(fb->sim, off);
#endif
	return fb->page[off / 4];
}

static void reg_wr(struct qfd_fabric *fb, unsigned off, uint32_t v)
{
#ifdef QFD_TEST_HOOKS
	if (fb->sim_wr) {
		fb->sim_wr(fb->sim, off, v);
		return;
	}
#endif
	fb->page[off / 4] = v;
}

static void barrier(struct qfd_fabric *fb)
{
	__sync_synchronize();
#if defined(__aarch64__) || defined(__arm__)
	__asm__ volatile("dsb sy" ::: "memory");
#endif
#ifdef QFD_TEST_HOOKS
	if (fb->sim_wr)
		fb->sim_wr(fb->sim, QFD_FABRIC_BARRIER, 0);
#else
	(void)fb;
#endif
}

int qfd_fabric_attach(struct qfd_fabric *fb, char *why, size_t whylen)
{
	const uint32_t id = reg_rd(fb, OFF_IDENT);
	if (id != QFD_IDENT && id != QFD_IDENT_13) {
		snprintf(why, whylen,
			 "the file device's page reads 0x%08x where QUUX's reads 0x%08x (\"QFD9\") or, "
			 "on revision 13, 0x%08x (\"QF13\")%s", id, QFD_IDENT, QFD_IDENT_13,
			 id == 0x4E4F4E45u ? ": \"NONE\", a bitstream without it, the CADR's" : "");
		return -1;
	}
	const int r13 = id == QFD_IDENT_13;
	const uint32_t most = r13 ? QFD_MAX_MEM_WORDS_13 : QFD_MAX_MEM_WORDS;
	const uint32_t words = reg_rd(fb, OFF_MEM_WORDS);
	if (words == 0 || words > most) {
		snprintf(why, whylen, "the file device's page says main memory is %u words, which is not "
			 "1 to %u", words, most);
		return -1;
	}
	fb->mem_words = words;
	fb->revision_13 = r13;
	// **THE CLAIM A PROGRAM BEFORE THIS ONE MAY HAVE LEFT.**  Busy outlasts a
	// reset of the machine, so that a completion from before the reset can
	// never land after it, and nothing but this program clears it.  One that
	// died holding it would leave quiet low for good, and a machine waiting
	// for quiet before it reuses its rings waits on nobody; so the start
	// lets it go.
	reg_wr(fb, OFF_CLAIM, 0);
	return 0;
}

static void f_state(void *ctx, struct qfd_state *s)
{
	struct qfd_fabric *fb = ctx;
	const uint32_t st = reg_rd(fb, OFF_STATE);
	s->enabled = st & 1;
	s->busy = (st >> 2) & 1;
	s->work = (st >> 4) & 1;
	s->refused = (st >> 5) & 1;
	s->epoch = (uint16_t)(st >> 16);
	const uint32_t bases = fb->revision_13 ? 0x0FFFFFFFu : 0x00FFFFFFu;
	s->cmd_base = reg_rd(fb, OFF_CMD_BASE) & bases;
	s->cmd_log2 = reg_rd(fb, OFF_CMD_LOG2) & 0xFu;
	s->resp_base = reg_rd(fb, OFF_RESP_BASE) & bases;
	s->resp_log2 = reg_rd(fb, OFF_RESP_LOG2) & 0xFu;
	s->cmd_prod = (uint16_t)reg_rd(fb, OFF_CMD_PROD);
	s->resp_prod = (uint16_t)reg_rd(fb, OFF_RESP_PROD);
	s->resp_cons = (uint16_t)reg_rd(fb, OFF_RESP_CONS);
}

static int f_claim(void *ctx, uint16_t epoch)
{
	struct qfd_fabric *fb = ctx;
	reg_wr(fb, OFF_CLAIM, (uint32_t)epoch << 16 | 1u);
	return reg_rd(fb, OFF_CLAIM) & 1;
}

static void f_release(void *ctx)
{
	reg_wr(ctx, OFF_CLAIM, 0);
}

static void f_handles(void *ctx, uint16_t epoch, unsigned n)
{
	reg_wr(ctx, OFF_HANDLES, (uint32_t)epoch << 16 | (n & 0xFFu));
}

static void f_complete(void *ctx, uint16_t epoch, uint16_t index)
{
	struct qfd_fabric *fb = ctx;
	barrier(fb);
	reg_wr(fb, OFF_RESP_PROD, (uint32_t)epoch << 16 | index);
}

static void f_rtc(void *ctx, uint32_t seconds, uint32_t ns)
{
	reg_wr(ctx, OFF_RTC_FRACTION, ns);
	reg_wr(ctx, OFF_RTC_SECONDS, seconds);
}

void qfd_fabric_face(struct qfd_fabric *fb, volatile void *main, struct qfd_face *out)
{
	*out = (struct qfd_face){
		.ctx = fb,
		.mem = { fb->revision_13 ? NULL : (volatile uint32_t *)main,
			 fb->revision_13 ? (volatile uint8_t *)main : NULL, fb->mem_words,
			 fb->revision_13, NULL, NULL },
		.state = f_state,
		.claim = f_claim,
		.release = f_release,
		.handles = f_handles,
		.complete = f_complete,
		.rtc = f_rtc,
	};
}
