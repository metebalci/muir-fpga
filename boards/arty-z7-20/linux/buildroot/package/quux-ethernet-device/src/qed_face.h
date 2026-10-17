// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Ethernet device's face: what this program sees of the fabric.
//
// The machine's side of the Ethernet device --- words 240-257 of QUUX's
// register page, the enable, the rings' bases and sizes, the processor's
// three indexes, the index and configuration rules, the interrupt and the
// cache's coherence --- is muir's (the Ethernet contract, section 2;
// `src/ethernet_device.rs`) and lives in the fabric.  This program is the
// device's other half: it sends the Ethernet frames the transmit ring names
// and delivers the ones the tap gives into the receive ring's buffers,
// applying section 2.4 to both, and it reaches the fabric through one 4 KB
// page of its own, the face.  `qed_ring.c` is written against the operations
// below and nothing else, so that the page's layout is one file,
// `qed_face_fabric.c`, and the check can put a model of the page's rules in
// its place.
//
// **THE CLAIM AND THE EPOCH ARE THE FILE DEVICE'S** (`quux-file-device`'s
// `qfd_face.h`; the Ethernet contract, section 2.7).  A disable is the
// device's reset, and after it the machine may reuse ring and buffer memory
// once status <1>, quiet, reads 1.  Here Linux may be in the middle of a
// transmit's read or a delivery's writes, so quiet is "not enabled and not
// busy", and busy is this program's claim: set before it touches the
// machine's memory and cleared after.  The claim is taken only with the
// epoch the program last read, and the fabric refuses it when a disable has
// moved the epoch since.  Every write that publishes something --- 245 and
// 251 --- carries the epoch, and the fabric ignores one carrying a stale
// epoch, so a delivery overtaken by a disable writes memory while its claim
// still holds quiet low and never moves 251.
//
// **THE FOUR COUNTERS OF 241 ARE THIS PROGRAM'S TO COUNT AND THE FABRIC'S TO
// KEEP** (section 2.4.1: the fabric never reads an Ethernet frame's bytes, so
// only this program knows a drop).  The program writes all four at once, in
// 241's own places; the fabric shows them in 241, zero at power-on, and no
// disable, RESET-DEVICES or machine reset changes them.  A program started
// again reads them back and counts on from there.

#ifndef QED_FACE_H
#define QED_FACE_H

#include <stddef.h>
#include <stdint.h>

#include "qed_host.h"
#include "qed_mem.h"

// What the page says, read in one go.
struct qed_state {
	int enabled;          // 240 <0>
	int ie;               // 240 <8>
	int busy;             // the claim, as the fabric holds it
	uint16_t epoch;
	uint32_t tx_base, tx_log2, rx_base, rx_log2;   // 242, 243, 246, 247
	uint16_t tx_prod;     // 244, once the processor's write buffer has drained
	uint16_t tx_cons;     // 245
	uint16_t rx_prod;     // 250, once the processor's write buffer has drained
	uint16_t rx_cons;     // 251
	uint16_t rx_taken;    // 252
	uint32_t counts;      // 241's four counters, in their places
};

// 241's four counters, each in its own place and width.
#define QED_COUNTS_TYPE(c)      (((c) >> 4) & 0xFu)    // <7:4>, the type filter
#define QED_COUNTS_IPV4(c)      (((c) >> 9) & 0x7Fu)   // <15:9>, the IPv4 checks
#define QED_COUNTS_RX(c)        (((c) >> 16) & 0xFFu)  // <23:16>, dropped for a buffer
#define QED_COUNTS_TX(c)        (((c) >> 24) & 0xFFu)  // <31:24>, transmits refused
#define QED_COUNTS(type, ipv4, rx, tx)                                                     \
	(((uint32_t)(type) & 0xFu) << 4 | ((uint32_t)(ipv4) & 0x7Fu) << 9                   \
	 | ((uint32_t)(rx) & 0xFFu) << 16 | ((uint32_t)(tx) & 0xFFu) << 24)
#define QED_COUNTS_MASK 0xFFFFFEF0u

struct qed_face {
	void *ctx;
	// Main memory, `mem.words` of it, which the page states.
	struct qed_mem mem;
	void (*state)(void *ctx, struct qed_state *s);
	// Take the claim under `epoch`: 1 if busy now reads set.
	int (*claim)(void *ctx, uint16_t epoch);
	void (*release)(void *ctx);
	// 245 moved to `index` under `epoch`: the entries before it are sent or
	// refused.  A transmit writes no memory, so no barrier comes first.
	void (*sent)(void *ctx, uint16_t epoch, uint16_t index);
	// 251 moved to `index` under `epoch`: every word of memory written is in
	// DDR first (the barrier is the face's), and the fabric makes the
	// machine's cache coherent before the machine sees the index move.
	void (*delivered)(void *ctx, uint16_t epoch, uint16_t index);
	// The four counters, in 241's places.
	void (*counts)(void *ctx, uint32_t counts);
	// 253-257, the host's: `--ethernet-mac`, `--ip-address`, `--ip-gateway`.
	void (*host)(void *ctx, const struct qed_host *h);
};

// The board's page (`qed_face_fabric.c`, the one file that knows its
// layout).  `page` is the 4 KB page mapped; `qed_fabric_attach` checks that
// it is the Ethernet device's and reads main memory's size from it, and
// `qed_fabric_face` fills a face over it and the mapping of main memory.
struct qed_fabric {
	volatile uint32_t *page;
	uint32_t mem_words;
#ifdef QED_TEST_HOOKS
	// The check's model of the page: every register access through it
	// instead, and a barrier reported as an access to offset
	// QED_FABRIC_BARRIER.
	uint32_t (*sim_rd)(void *sim, unsigned off);
	void (*sim_wr)(void *sim, unsigned off, uint32_t v);
	void *sim;
#endif
};

#define QED_FABRIC_BARRIER 0xFFFFu

// The page's place on the processor-to-fabric port: one page above the
// file device's, the sixth of the faces and the first free page above them.
#define QED_FACE_OFFSET 0x5000u

// The most main memory the page may say, in words: the largest room a board
// keeps for QUUX's packed storage (`cadr_board.h`'s
// CADR_BOARD_QUUX13_MAIN_WORDS_MAX on the DE25-Nano).
#define QED_MAX_MEM_WORDS (64u * 1024u * 1024u)

int qed_fabric_attach(struct qed_fabric *fb, char *why, size_t whylen);
// `main` is main memory's mapping, bytes of packed storage.
void qed_fabric_face(struct qed_fabric *fb, volatile void *main, struct qed_face *out);

#endif
