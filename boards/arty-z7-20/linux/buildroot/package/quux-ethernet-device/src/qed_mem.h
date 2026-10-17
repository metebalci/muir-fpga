// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's main memory as the Ethernet device sees it: `words` 40-bit words
// of packed storage (revision 13's layout, which revisions 15 and 16 keep;
// contract G1 section 4.1): word k is the five bytes b[5k] to b[5k + 4],
// <7:0> first and the tag <39:32> last.  On a board it is an uncached
// mapping of DDR, and every access to it is naturally aligned
// (`cadr_mem.h`), as `quux-file-device`'s are; in the check it is an array.
// `touch`, when set, is called before every word read or written, which is
// how the check holds that no word is touched outside the claim.
//
// The device reads <31:0> of a word, whatever its tag, and writes every word
// it fills as a fixnum: the field and the tag 005.  Its rings and buffers
// are at 28-bit physical word addresses on an 8-word line.

#ifndef QED_MEM_H
#define QED_MEM_H

#include <stddef.h>
#include <stdint.h>

struct qed_mem {
	volatile uint8_t *b;
	size_t words;
	void (*touch)(void *ctx);
	void *ctx;
};

#define QED_TAG_FIXNUM 005u
// An address as the device takes it, <27:0>, and the line it must be on.
#define QED_ADDRESS 0x0FFFFFFFu
#define QED_LINE    7u

// `n` words from word `k`, <31:0> of each.
void qed_mem_read(struct qed_mem *m, size_t k, size_t n, uint32_t *out);
// `n` words from word `k`, each <31:0> from `in` and the tag a fixnum's.
void qed_mem_write(struct qed_mem *m, size_t k, size_t n, const uint32_t *in);

#ifdef QED_TEST_HOOKS
// Accesses that were not naturally aligned or reached a byte outside their
// run, which the build host would not fault on and a board's device memory
// would.
extern unsigned long qed_hook_bad_access;
#endif

#endif
