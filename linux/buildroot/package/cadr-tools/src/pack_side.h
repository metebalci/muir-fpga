// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack side's register face, as `rtl/cadr_disk_pack.sv` defines it and
// as Linux drives it over `M_AXI_GP0`.
//
// Sixteen words at `REG_BASE`; the header of that file is the reference and
// this repeats only what a driver needs:
//
//   0  ADDR    the block's address in DDR, bits 6:0 zero
//   1  TAG     {cylinder<11:0>, head<7:0>, block<7:0>}
//   2  SLOT    which of the store's 24 slots
//   3  CTL     written: bit 0 fetch, bit 1 write back, bit 2 take away,
//                       exactly one of them
//              read:    bit 0 busy, 1 done, 2 error, 3 refused,
//                       4 ch_active, 5 store_miss
//   4  DRIVE   bits 7:0 present, 15:8 read-only, 16 timed
//   7  IDENT   "PACK"
//
// A request is the four writes ADDR, TAG, SLOT, CTL and a read of CTL; the
// pack side acts on the CTL beat one tick later and latches the other three
// at that instant, so they may be rewritten at once.  A REFUSED request
// moved nothing and issued no burst.  The refusal the face can raise that
// this program did not itself cause is the channel walking (`ch_active`,
// read back in the same word), and that one is retried; the others ---
// unaligned, a slot past the store, two bits at once, busy --- are bugs in
// the caller and are reported as such.
//
// The face is reached through two function pointers so that the host test
// can put a model of the RTL behind them and the board puts `/dev/mem`.

#ifndef PACK_SIDE_H
#define PACK_SIDE_H

#include <stddef.h>
#include <stdint.h>

#define PS_REG_BASE   0x40000000u
#define PS_REG_BYTES  64u
#define PS_IDENT_WORD 0x5041434Bu	/* "PACK" */
#define PS_SLOTS      24u
#define PS_RECORD_ALIGN 128u

enum ps_reg { PS_ADDR = 0, PS_TAG = 1, PS_SLOT = 2, PS_CTL = 3, PS_DRIVE = 4, PS_IDENT = 7 };
enum ps_ctl { PS_CTL_FETCH = 1u << 0, PS_CTL_WRITE = 1u << 1, PS_CTL_TAKE = 1u << 2 };
enum ps_status {
	PS_ST_BUSY = 1u << 0, PS_ST_DONE = 1u << 1, PS_ST_ERROR = 1u << 2,
	PS_ST_REFUSED = 1u << 3, PS_ST_CH_ACTIVE = 1u << 4, PS_ST_STORE_MISS = 1u << 5
};

struct pack_side {
	uint32_t (*read)(struct pack_side *ps, unsigned reg);
	void (*write)(struct pack_side *ps, unsigned reg, uint32_t v);
	// One poll's wait while the face is busy or the channel is walking.
	void (*pause)(struct pack_side *ps);
	void *ctx;
	// How many polls a move may take before it is called stuck, and how
	// many times a request refused for the channel is asked again.
	unsigned poll_cap, ch_retry_cap;
	// The tally.
	unsigned long fetches, writebacks, takes;
	unsigned long refused_ch, refused_other, errors, polls, stuck;
};

// Sensible caps.
void ps_init(struct pack_side *ps);

uint32_t ps_tag(uint32_t c, uint32_t h, uint32_t b);

// IDENT reads "PACK".
int ps_ident_ok(struct pack_side *ps, uint32_t *got);

// The drive seam: which units have a pack, which are read-only, and
// whether the drive's own time is charged.
void ps_drive(struct pack_side *ps, uint8_t present, uint8_t read_only, int timed);

// One request, run to done.  Returns 0 on done without error, -1 with `why`
// otherwise; `status` is the last status word read.
int ps_request(struct pack_side *ps, uint32_t ctl, uint32_t addr, uint32_t tag, unsigned slot,
	       uint32_t *status, char *why, size_t whylen);

static inline int ps_fetch(struct pack_side *ps, uint32_t addr, uint32_t tag, unsigned slot,
			   uint32_t *status, char *why, size_t whylen)
{
	return ps_request(ps, PS_CTL_FETCH, addr, tag, slot, status, why, whylen);
}
static inline int ps_writeback(struct pack_side *ps, uint32_t addr, unsigned slot,
			       uint32_t *status, char *why, size_t whylen)
{
	return ps_request(ps, PS_CTL_WRITE, addr, 0, slot, status, why, whylen);
}
static inline int ps_take(struct pack_side *ps, unsigned slot, uint32_t *status, char *why, size_t whylen)
{
	return ps_request(ps, PS_CTL_TAKE, 0, 0, slot, status, why, whylen);
}

#endif
