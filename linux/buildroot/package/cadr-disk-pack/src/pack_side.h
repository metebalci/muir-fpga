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
//   1  TAG     {unit<2:0>, cylinder<11:0>, head<7:0>, block<7:0>}, bits 30:0
//   2  SLOT    which of the store's 24 slots
//   3  CTL     written: bit 0 fetch, bit 1 write back, bit 2 take away,
//                       exactly one of them; bit 3 DENY the request REQ
//                       holds, independent of the other three, never refused
//              read:    bit 0 busy, 1 done, 2 error, 3 refused,
//                       4 ch_active, 5 store_miss, 6 waiting
//   4  DRIVE   bits 7:0 present, 15:8 read-only, 16 timed, 24:17 ATTENTION
//              (a 1 raises that unit's attention; see below)
//   5  REQ     read only: bit 31 valid, bits 30:0 the disk address the
//              controller lacks, in TAG's layout
//   6  DIRTY   read only: bit s, a transfer has written slot s since Linux
//              last moved it
//   7  IDENT   "PACK"
//   8  REF     bit s, the walk has taken slot s since the bit was last
//              cleared; a 1 written clears the bit
//   9  IRQ     bit 0 a request posted, 1 a slot dirtied, 2 a move finished;
//              a 1 written clears the bit
//  10  IRQEN   the mask over IRQ; `IRQ_F2P` bit 0 is the OR under it
//
// A move is the four writes ADDR, TAG, SLOT, CTL and a read of CTL; the
// pack side acts on the CTL beat one tick later and latches the other three
// at that instant, so they may be rewritten at once.  A REFUSED move moved
// nothing and issued no burst.  **THE REFUSAL IS PER SLOT**: a move on the
// slot the walk is on is refused, a move on any other slot is taken during
// a walk, and the answer is another slot for a fetch or a later pass for a
// write-back, never a wait.  The `ch_active` and `waiting` bits read back
// beside `refused` are live and later than the beat, so they do not say
// why the move was refused (`pack_side.c` at the refusal).  The other
// refusals --- unaligned, a slot past the store, two bits at once, busy ---
// are bugs in the caller and are reported as such.
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

enum ps_reg {
	PS_ADDR = 0, PS_TAG = 1, PS_SLOT = 2, PS_CTL = 3, PS_DRIVE = 4,
	PS_REQ = 5, PS_DIRTY = 6, PS_IDENT = 7, PS_REF = 8, PS_IRQ = 9, PS_IRQEN = 10
};
enum ps_ctl { PS_CTL_FETCH = 1u << 0, PS_CTL_WRITE = 1u << 1, PS_CTL_TAKE = 1u << 2, PS_CTL_DENY = 1u << 3 };
enum ps_status {
	PS_ST_BUSY = 1u << 0, PS_ST_DONE = 1u << 1, PS_ST_ERROR = 1u << 2,
	PS_ST_REFUSED = 1u << 3, PS_ST_CH_ACTIVE = 1u << 4, PS_ST_STORE_MISS = 1u << 5,
	PS_ST_WAITING = 1u << 6
};
#define PS_REQ_VALID 0x80000000u
#define PS_TAG_MASK  0x7FFFFFFFu
// DRIVE's fields.
#define PS_DRIVE_PRESENT_SHIFT   0
#define PS_DRIVE_READ_ONLY_SHIFT 8
#define PS_DRIVE_TIMED           (1u << 16)
// **THE ATTENTION FIELD, AND WHAT THE FABRIC DOES WITH IT TODAY: NOTHING.**
// A drive raises an attention when it comes ready, which on this board is
// the instant Linux says a pack is on that cable --- `disk-pack-N.img`
// appearing in the bay, or going away.  `r_drive` in `rtl/cadr_disk_pack.sv`
// is twenty-five bits and only 16:0 reach an output, so bits 24:17 are
// storage that reaches nothing, and `rtl/cadr_disk_controller.sv` arms
// `u_att_armed` from a seek and a recalibrate and from nowhere else.  So
// this program writes the field, `feeder_test.c` holds it to being a PULSE
// --- the word is written once with the bits and once without, so the field
// is a pulse whether or not the fabric self-clears it --- and the CADR does
// not see an attention when a pack is loaded until two lines of RTL exist:
// `drive_attention` out of the pack side off a write of this field, and
// `u_att_armed[u] <= 1'b1; u_att_ns[u] <= 0;` on it in the controller.
// Named here so that the ask is one place and the program is already right
// when it lands.  Nothing else in this program depends on it.
#define PS_DRIVE_ATTENTION_SHIFT 17
enum ps_irq { PS_IRQ_REQ = 1u << 0, PS_IRQ_DIRTY = 1u << 1, PS_IRQ_DONE = 1u << 2 };

// What `ps_request` returns besides 0: the slot named is the walk's own
// (choose another), or a failure `why` describes.
#define PS_WALK_SLOT (-2)

struct pack_side {
	uint32_t (*read)(struct pack_side *ps, unsigned reg);
	void (*write)(struct pack_side *ps, unsigned reg, uint32_t v);
	// One poll's wait while the face is busy.
	void (*pause)(struct pack_side *ps);
	void *ctx;
	// How many polls a move may take before it is called stuck.
	unsigned poll_cap;
	// The tally.
	unsigned long fetches, writebacks, takes, denials, attentions;
	unsigned long refused_walk, refused_other, errors, polls, stuck;
};

// Sensible caps.
void ps_init(struct pack_side *ps);

// The tag, and the tag taken apart.
uint32_t ps_tag(unsigned unit, uint32_t c, uint32_t h, uint32_t b);
void ps_tag_split(uint32_t tag, unsigned *unit, uint32_t *c, uint32_t *h, uint32_t *b);

// IDENT reads "PACK".
int ps_ident_ok(struct pack_side *ps, uint32_t *got);

// The drive seam: which units have a pack, which are read-only, whether the
// drive's own time is charged, and which units' attention is raised by this
// write.  `attention` is a pulse: with any bit set the word is written twice,
// once with the field and once without, so nothing is left standing in a
// register the fabric may or may not clear for itself.
void ps_drive(struct pack_side *ps, uint8_t present, uint8_t read_only, int timed, uint8_t attention);

// The status word, read without starting anything: `ch_active` says the
// controller is walking, which is what a drive bay waits out before it opens
// a door.
static inline uint32_t ps_status(struct pack_side *ps) { return ps->read(ps, PS_CTL); }

// One move, run to done.  Returns 0 on done without error; PS_WALK_SLOT if
// the slot named is the walk's and another must be chosen; -1 with `why`
// otherwise.  `status` is the last status word read.
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

// Deny the request REQ holds: the walk waiting on it takes its miss.  Never
// refused, and not a move, so nothing is waited for.
void ps_deny(struct pack_side *ps);

// The cache's registers.
static inline uint32_t ps_req(struct pack_side *ps) { return ps->read(ps, PS_REQ); }
static inline uint32_t ps_dirty(struct pack_side *ps) { return ps->read(ps, PS_DIRTY); }
static inline uint32_t ps_ref(struct pack_side *ps) { return ps->read(ps, PS_REF); }
static inline uint32_t ps_irq(struct pack_side *ps) { return ps->read(ps, PS_IRQ); }
static inline void ps_ref_clear(struct pack_side *ps, uint32_t mask) { ps->write(ps, PS_REF, mask); }
static inline void ps_irq_clear(struct pack_side *ps, uint32_t mask) { ps->write(ps, PS_IRQ, mask); }
static inline void ps_irqen(struct pack_side *ps, uint32_t mask) { ps->write(ps, PS_IRQEN, mask); }

#endif
