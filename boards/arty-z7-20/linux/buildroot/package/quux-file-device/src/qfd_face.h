// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The file device's face: what this program sees of the fabric.
//
// The machine's side of the file device --- registers 160-171 of QUUX's
// register page, the enable, the rings' bases and sizes, the processor's two
// indexes --- is muir's (`docs/quux.md` "The file device") and lives in the
// fabric.  This program is the device's other half, and it reaches the
// fabric through one 4 KB page of its own, the face.  `qfd_ring.c` is written
// against the operations below and nothing else, so that the page's layout
// is one file, `qfd_face_fabric.c`, and the check can put a model of the
// page's rules in its place.
//
// **THE CLAIM, AND WHY IT IS NEEDED.**  A disable is the device's reset, and
// after it the machine may reuse ring and buffer memory once status <1>,
// quiet, reads 1.  On muir that is at once.  Here Linux may be in the middle
// of a command, copying into DDR, so quiet is `not enabled and not busy`,
// and busy is this program's claim: set before it touches the machine's
// memory for a command and cleared after.  The claim is taken only with the
// epoch the program last read, and the fabric refuses it when a disable has
// moved the epoch since, so a claim can never be taken on a device that was
// reset behind the program's back.
//
// **THE EPOCH.**  The fabric counts every disable, `160 <0>` from 1 to 0 and
// every machine reset of an enabled device.  A program that sees the epoch
// move closes every handle, as muir's disable does, and forgets the command
// it holds.  Every write that could publish something --- the handles open,
// the response producer --- carries the epoch, and the fabric ignores one
// carrying a stale epoch, so a command overtaken by a disable writes memory
// while its claim still holds quiet low and never publishes.

#ifndef QFD_FACE_H
#define QFD_FACE_H

#include <stdint.h>

#include "qfd.h"

// What the page says, read in one go.
struct qfd_state {
	int enabled;          // 160 <0>
	int busy;             // the claim, as the fabric holds it
	int work;             // enabled, a command waiting, and room for its response
	int refused;          // a completion the fabric refused (sticky)
	uint16_t epoch;
	uint32_t cmd_base, cmd_log2, resp_base, resp_log2;
	uint16_t cmd_prod;    // 164, once the processor's write buffer has drained
	uint16_t resp_prod;   // 165 = 170
	uint16_t resp_cons;   // 171
};

struct qfd_face {
	void *ctx;
	// Main memory, `mem.words` of it, which the page states.
	struct qfd_mem mem;
	void (*state)(void *ctx, struct qfd_state *s);
	// Take the claim under `epoch`: 1 if busy now reads set.
	int (*claim)(void *ctx, uint16_t epoch);
	void (*release)(void *ctx);
	// The handles open, which the machine reads in 161 <23:16> and a
	// checkpoint is refused on.
	void (*handles)(void *ctx, uint16_t epoch, unsigned n);
	// Commands done up to `index`: every word of memory written is in DDR
	// first (the barrier is the face's), and the fabric invalidates the
	// machine's cache before the machine sees the index move.
	void (*complete)(void *ctx, uint16_t epoch, uint16_t index);
	// The real-time clock, word 103, which the fabric counts and this
	// program sets at the start and at least once a second.
	void (*rtc)(void *ctx, uint32_t seconds, uint32_t nanoseconds);
};

// The board's page (`qfd_face_fabric.c`, the one file that knows its
// layout).  `page` is the 4 KB page mapped; `qfd_fabric_attach` checks that
// it is the file device's and reads main memory's size from it, and
// `qfd_fabric_face` fills a face over it and the mapping of main memory.
struct qfd_fabric {
	volatile uint32_t *page;
	uint32_t mem_words;
	// The page's IDENT said revision 13 ("QF13"), whose main memory is
	// packed storage and whose rings are at 28-bit addresses.
	int revision_13;
#ifdef QFD_TEST_HOOKS
	// The check's model of the page: every register access through it
	// instead, and a barrier reported as an access to offset
	// QFD_FABRIC_BARRIER.
	uint32_t (*sim_rd)(void *sim, unsigned off);
	void (*sim_wr)(void *sim, unsigned off, uint32_t v);
	void *sim;
#endif
};

#define QFD_FABRIC_BARRIER 0xFFFFu

// The page's place on the processor-to-fabric port: one page above the
// keyboard and mouse, the fifth of the faces.
#define QFD_FACE_OFFSET 0x4000u

// The most main memory each page may say, in words: revision 12's 16M,
// which is the CADR's 64 MB of words, and revision 13's 64M, the largest room
// a board keeps for it (`cadr_board.h`'s CADR_BOARD_QUUX13_MAIN_WORDS_MAX,
// which the program holds the page to as well).
#define QFD_MAX_MEM_WORDS    (16u * 1024u * 1024u)
#define QFD_MAX_MEM_WORDS_13 (64u * 1024u * 1024u)

int qfd_fabric_attach(struct qfd_fabric *fb, char *why, size_t whylen);
// `main` is main memory's mapping: 32-bit words to revision 12, and bytes of
// packed storage on revision 13.
void qfd_fabric_face(struct qfd_fabric *fb, volatile void *main, struct qfd_face *out);

#endif
