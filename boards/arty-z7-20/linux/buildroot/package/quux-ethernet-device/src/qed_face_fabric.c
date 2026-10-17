// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Ethernet device's page in the fabric: THE ONE FILE THAT KNOWS ITS
// LAYOUT.
//
// One 4 KB page on the processor-to-fabric port the other faces use, at the
// pack side's base + 0x5000 on every board, in QUUX revision 16's
// bitstreams only; on any other the address is the default slave's and reads
// "NONE".  Every access is one aligned 32-bit word.  Byte offsets:
//
//   0x000 IDENT       RO  "QE16", 0x51453136: revision 16's Ethernet device
//   0x004 MEM_WORDS   RO  main memory, in words
//   0x100 STATE       RO  <0> enabled (240 <0>), <1> interrupt enable
//                         (240 <8>), <2> busy (the claim), <3> quiet,
//                         <31:16> the epoch
//   0x104 CLAIM       RW  {epoch, <0> 1} takes the claim if enabled and the
//                         epoch matches; <0> 0 drops it; reads <0> busy
//   0x108 TX_BASE     RO  242 <27:0>       0x10C TX_LOG2  RO  243 <3:0>
//   0x110 RX_BASE     RO  246 <27:0>       0x114 RX_LOG2  RO  247 <3:0>
//   0x118 TX_PROD     RO  244, once the processor's write buffer has drained
//                         (section 2.5: a write of 244 moves only once the
//                         queue and the in-flight list are empty)
//   0x11C TX_CONS     RW  245; {epoch, index} moves it to index, ignored
//                         under a stale epoch
//   0x120 RX_PROD     RO  250, once the processor's write buffer has drained
//   0x124 RX_CONS     RW  251; {epoch, index} makes the machine's cache
//                         coherent (section 2.5) and then moves 251 to index,
//                         ignored under a stale epoch
//   0x128 RX_TAKEN    RO  252
//   0x12C COUNTS      RW  241's four counters in 241's own places, <7:4>,
//                         <15:9>, <23:16> and <31:24>; a write sets all four
//                         and the other bits are ignored and read 0; 0 at
//                         power-on, and no disable, RESET-DEVICES or machine
//                         reset changes them
//   0x130 MAC_HIGH    RW  253 <15:0>    0x134 MAC_LOW     RW  254
//   0x138 IP_ADDRESS  RW  255           0x13C NETMASK     RW  256
//   0x140 GATEWAY     RW  257
//                         read only to the machine; at power-on muir's
//                         defaults, 02:00:00:00:00:01 and 169.254.100.2/30 by
//                         169.254.100.1, and no reset changes them
//
// **THE FABRIC'S SIDE** (`rtl/machine/quux16_ethernet.sv` behind
// `rtl/plumbing/quux_ed_face.sv`) is what `qed_test.c`'s model of the page
// does.  Besides the offsets, the
// fabric owes the rules of muir's device that are the machine's and not this
// program's: the configuration and its refusal at the enable (status <2>);
// the index rules and their fault (status <3>), a second held write of 244
// or 250 replacing the first; the indexes reading 0 while disabled; the
// epoch, counted at every disable, RESET-DEVICES of an enabled device and
// machine reset of an enabled device; quiet as "not enabled and not busy";
// busy outliving a reset, cleared only by this program; status <8> and word
// 100 <8> from 251 and 252; and the cache's coherence at the write of
// RX_CONS, by the mechanism M-refill chooses.
//
// **THE BARRIER BEFORE THE DELIVERY.**  A buffer's words and the entry's word
// 2 are written through an uncached mapping of DDR (`/dev/mem`, O_SYNC), and
// the delivery is a write to this page, which tells the fabric to make the
// cache coherent and move the index.  The machine must not see the index
// before the words.  So the write of RX_CONS comes after
// `__sync_synchronize()` and a `dsb sy`, as the file device's completion
// does.  A transmit writes no memory, and TX_CONS needs no barrier.

#include "qed_face.h"

#include <stdio.h>

#define QED_IDENT_16     0x51453136u	/* "QE16" */
#define OFF_IDENT        0x000u
#define OFF_MEM_WORDS    0x004u
#define OFF_STATE        0x100u
#define OFF_CLAIM        0x104u
#define OFF_TX_BASE      0x108u
#define OFF_TX_LOG2      0x10Cu
#define OFF_RX_BASE      0x110u
#define OFF_RX_LOG2      0x114u
#define OFF_TX_PROD      0x118u
#define OFF_TX_CONS      0x11Cu
#define OFF_RX_PROD      0x120u
#define OFF_RX_CONS      0x124u
#define OFF_RX_TAKEN     0x128u
#define OFF_COUNTS       0x12Cu
#define OFF_MAC_HIGH     0x130u
#define OFF_MAC_LOW      0x134u
#define OFF_IP_ADDRESS   0x138u
#define OFF_NETMASK      0x13Cu
#define OFF_GATEWAY      0x140u

static uint32_t reg_rd(struct qed_fabric *fb, unsigned off)
{
#ifdef QED_TEST_HOOKS
	if (fb->sim_rd)
		return fb->sim_rd(fb->sim, off);
#endif
	return fb->page[off / 4];
}

static void reg_wr(struct qed_fabric *fb, unsigned off, uint32_t v)
{
#ifdef QED_TEST_HOOKS
	if (fb->sim_wr) {
		fb->sim_wr(fb->sim, off, v);
		return;
	}
#endif
	fb->page[off / 4] = v;
}

static void barrier(struct qed_fabric *fb)
{
	__sync_synchronize();
#if defined(__aarch64__) || defined(__arm__)
	__asm__ volatile("dsb sy" ::: "memory");
#endif
#ifdef QED_TEST_HOOKS
	if (fb->sim_wr)
		fb->sim_wr(fb->sim, QED_FABRIC_BARRIER, 0);
#else
	(void)fb;
#endif
}

int qed_fabric_attach(struct qed_fabric *fb, char *why, size_t whylen)
{
	const uint32_t id = reg_rd(fb, OFF_IDENT);
	if (id != QED_IDENT_16) {
		snprintf(why, whylen,
			 "the Ethernet device's page reads 0x%08x where QUUX revision 16's reads 0x%08x "
			 "(\"QE16\")%s",
			 id, QED_IDENT_16,
			 id == 0x4E4F4E45u ? ": \"NONE\", a bitstream without it, the CADR's or an older "
					     "revision's"
					   : "");
		return -1;
	}
	const uint32_t words = reg_rd(fb, OFF_MEM_WORDS);
	if (words == 0 || words > QED_MAX_MEM_WORDS) {
		snprintf(why, whylen,
			 "the Ethernet device's page says main memory is %u words, which is not 1 to %u",
			 words, QED_MAX_MEM_WORDS);
		return -1;
	}
	fb->mem_words = words;
	// **THE CLAIM A PROGRAM BEFORE THIS ONE MAY HAVE LEFT.**  Busy outlasts
	// a reset of the machine, so that a delivery from before the reset can
	// never land after it, and nothing but this program clears it.  One that
	// died holding it would leave quiet low for good, and the machine's
	// reset waits for quiet; so the start lets it go.
	reg_wr(fb, OFF_CLAIM, 0);
	return 0;
}

static void f_state(void *ctx, struct qed_state *s)
{
	struct qed_fabric *fb = ctx;
	const uint32_t st = reg_rd(fb, OFF_STATE);
	s->enabled = st & 1u;
	s->ie = (st >> 1) & 1u;
	s->busy = (st >> 2) & 1u;
	s->epoch = (uint16_t)(st >> 16);
	s->tx_base = reg_rd(fb, OFF_TX_BASE) & QED_ADDRESS;
	s->tx_log2 = reg_rd(fb, OFF_TX_LOG2) & 0xFu;
	s->rx_base = reg_rd(fb, OFF_RX_BASE) & QED_ADDRESS;
	s->rx_log2 = reg_rd(fb, OFF_RX_LOG2) & 0xFu;
	s->tx_prod = (uint16_t)reg_rd(fb, OFF_TX_PROD);
	s->tx_cons = (uint16_t)reg_rd(fb, OFF_TX_CONS);
	s->rx_prod = (uint16_t)reg_rd(fb, OFF_RX_PROD);
	s->rx_cons = (uint16_t)reg_rd(fb, OFF_RX_CONS);
	s->rx_taken = (uint16_t)reg_rd(fb, OFF_RX_TAKEN);
	s->counts = reg_rd(fb, OFF_COUNTS) & QED_COUNTS_MASK;
}

static int f_claim(void *ctx, uint16_t epoch)
{
	struct qed_fabric *fb = ctx;
	reg_wr(fb, OFF_CLAIM, (uint32_t)epoch << 16 | 1u);
	return reg_rd(fb, OFF_CLAIM) & 1u;
}

static void f_release(void *ctx)
{
	reg_wr(ctx, OFF_CLAIM, 0);
}

static void f_sent(void *ctx, uint16_t epoch, uint16_t index)
{
	reg_wr(ctx, OFF_TX_CONS, (uint32_t)epoch << 16 | index);
}

static void f_delivered(void *ctx, uint16_t epoch, uint16_t index)
{
	struct qed_fabric *fb = ctx;
	barrier(fb);
	reg_wr(fb, OFF_RX_CONS, (uint32_t)epoch << 16 | index);
}

static void f_counts(void *ctx, uint32_t counts)
{
	reg_wr(ctx, OFF_COUNTS, counts & QED_COUNTS_MASK);
}

static void f_host(void *ctx, const struct qed_host *h)
{
	struct qed_fabric *fb = ctx;
	reg_wr(fb, OFF_MAC_HIGH, (uint32_t)h->mac[0] << 8 | h->mac[1]);
	reg_wr(fb, OFF_MAC_LOW,
	       (uint32_t)h->mac[2] << 24 | (uint32_t)h->mac[3] << 16 | (uint32_t)h->mac[4] << 8 | h->mac[5]);
	reg_wr(fb, OFF_IP_ADDRESS, h->address);
	reg_wr(fb, OFF_NETMASK, h->netmask);
	reg_wr(fb, OFF_GATEWAY, h->gateway);
}

void qed_fabric_face(struct qed_fabric *fb, volatile void *main, struct qed_face *out)
{
	*out = (struct qed_face){
		.ctx = fb,
		.mem = { (volatile uint8_t *)main, fb->mem_words, NULL, NULL },
		.state = f_state,
		.claim = f_claim,
		.release = f_release,
		.sent = f_sent,
		.delivered = f_delivered,
		.counts = f_counts,
		.host = f_host,
	};
}
