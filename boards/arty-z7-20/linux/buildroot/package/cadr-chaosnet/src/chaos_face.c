// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The driver of the Chaosnet interface's register face, and the frame-level
// vocabulary on it.  `chaos_face.h` is the reference for what the face IS ---
// the register table, the two windows, the handshake and the frame's word
// order --- and this file is the only thing in the program that touches it.
//
// **THE FACE IS REACHED THROUGH TWO FUNCTION POINTERS**, so the board puts
// `/dev/mem` behind them and `chaos_test_face.c` puts a model of the RTL.
// That seam is `pack_side.h`'s and `console_face.h`'s, copied deliberately:
// same shape, same reason.  Everything below `chaos_face_open` is written
// against the pointers alone, so the host check drives the same code the
// board does.
//
// **THE GUARD RUNS BEFORE ANY OF THIS.**  A read on a general-purpose AXI
// port that nothing in the fabric answers does not fault the Arm --- it hangs
// both cores at one PC each, measured on this board, and no software guard
// can catch it.  So `cadr_guard()` (the EMIO tally, which the processing
// system can always reach) must have passed before `chaos_face_open` maps
// anything, and `chaos_face_ident` must have read "CHAO" before any other
// word is believed.  `<cadr/cadr_mem.h>` says all of it at length; this file
// only obeys it.
//
// **WHAT IS ASSUMED ABOUT THE FABRIC HALF, beyond the register table.**  The
// fabric half is another slice's and is held to `muir::chaos::interface`, so
// where this file has had to decide something the decision is written at the
// place it is made and repeated in the program's report:
//
//   - `CTL_TX_TAKE` is what lets the machine transmit again, so a frame this
//     program cannot hold is still taken rather than left standing (see
//     `chaos_face_take`);
//   - a refused commit is told apart from a stored one by `LOST` moving, not
//     by `STAT`, because `RX_BUSY` is up either way (see `chaos_face_give`);
//   - `RX_ARMED` is a level the caller reads, not a per-frame answer, so a
//     give does not gate on it and lets the fabric refuse and count.

#include "chaos_face.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include <cadr/cadr_log.h>
#include <cadr/cadr_mem.h>

#include "chaos_packet.h"

// The fewest words a frame on this seam can be: the eight software header
// words and the three-word hardware trailer, with no data between them.  A
// buffer shorter than that is not a frame, whatever else it is.
#define CHAOS_FACE_MIN_WORDS (CHAOS_PKT_HEADER_WORDS + CHAOS_PKT_TRAILER_WORDS)

// --- the face over /dev/mem ----------------------------------------------

struct chaos_mmio {
	volatile uint32_t *regs;
	uint32_t base;
};

static uint32_t mmio_read(struct chaos_face *f, unsigned word)
{
	struct chaos_mmio *m = f->ctx;
	return m->regs[word];
}

static void mmio_write(struct chaos_face *f, unsigned word, uint32_t v)
{
	struct chaos_mmio *m = f->ctx;
	m->regs[word] = v;
	// The window writes must land before the `CTL_RX_COMMIT` that follows
	// them, or the fabric stores a frame that is half the last one.  The
	// mapping is uncached (`cadr_open_mem` opens /dev/mem with O_SYNC) so
	// the architecture already orders two writes to the same device, and
	// the barrier is what says so in the source rather than leaving it to
	// be inferred.  `cadr-console` and the disk pack program both write it
	// here for the same reason.
	__sync_synchronize();
}

int chaos_face_open(struct chaos_face *f, int fd, uint32_t base)
{
	struct chaos_mmio *m = calloc(1, sizeof *m);
	if (!m) {
		say("out of memory mapping the Chaosnet interface");
		return -1;
	}
	// One mapping covers the registers and both windows: the RX window
	// ends at +0xC00 and `CHAOS_REG_BYTES` is a whole 4 KB page.
	//
	// **`cadr_map`'s body, written out here rather than called**, so that
	// this translation unit --- the one the board runs and the one
	// `chaos_test_face.c` links whole --- needs nothing behind it but the
	// log.  It is the same three lines and the same failure line; what is
	// NOT duplicated, and must still be called by whoever opens the
	// descriptor, is `cadr_guard`, which is the part that matters and the
	// part no software can do without.  The descriptor is
	// `cadr_open_mem`'s, opened `O_RDWR | O_SYNC`, and O_SYNC is what makes
	// this mapping uncached: registers must be.
	void *p = mmap(NULL, CHAOS_REG_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
		       (off_t)base);
	if (p == MAP_FAILED) {
		say("mapping the Chaosnet interface's registers at 0x%08x: %s", (unsigned)base,
		    strerror(errno));
		free(m);
		return -1;
	}
	m->regs = p;
	m->base = base;
	f->read = mmio_read;
	f->write = mmio_write;
	f->ctx = m;
	return 0;
}

void chaos_face_close(struct chaos_face *f)
{
	// Only what `chaos_face_open` made: a face the host check filled in
	// with a model of the RTL owns its own context and must not be freed
	// here.  The test of `f->read` is what keeps that honest.
	if (!f || f->read != mmio_read)
		return;
	struct chaos_mmio *m = f->ctx;
	if (m) {
		munmap((void *)m->regs, CHAOS_REG_BYTES);
		free(m);
	}
	f->read = NULL;
	f->write = NULL;
	f->ctx = NULL;
}

// --- what is there, before anything else is believed ----------------------

int chaos_face_ident(struct chaos_face *f)
{
	const uint32_t got = f->read(f, CHAOS_IDENT);
	if (got == CHAOS_IDENT_WORD)
		return 0;
	// **"NONE" is the common mistake and is named as such.**  It is what
	// `cadr_gp0_default.sv` answers: a board with a general-purpose port
	// brought out and nothing of ours behind this address.  A reader who
	// is told only "not CHAO" goes looking for a broken interface; a
	// reader who is told "NONE" goes looking for the right bitstream.
	//
	// The address is not named here because this function cannot know it:
	// the face may have been opened at a base a flag gave, or be a model
	// with no address at all.  `chaos_face_open` says where it mapped.
	if (got == CADR_IDENT_NONE)
		say("no Chaosnet interface: word 0 reads \"NONE\", which is "
		    "cadr_gp0_default.sv's default slave --- the port is answered and the "
		    "interface is not in this bitstream");
	else if (got == 0)
		say("no Chaosnet interface: word 0 reads zero, which is what a bus nothing "
		    "drives reads, not a value the interface can give");
	else if (got == 0xFFFFFFFFu)
		say("no Chaosnet interface: word 0 reads all ones, which is what an undriven "
		    "bus reads, not a value the interface can give");
	else
		say("no Chaosnet interface: word 0 reads 0x%08x, wanting 0x%08x (\"CHAO\")",
		    (unsigned)got, (unsigned)CHAOS_IDENT_WORD);
	return -1;
}

uint32_t chaos_face_stat(struct chaos_face *f)
{
	return f->read(f, CHAOS_STAT);
}

uint32_t chaos_face_lost(struct chaos_face *f)
{
	return f->read(f, CHAOS_LOST);
}

// --- the sixteen address switches ----------------------------------------
//
// On the board these are a DIP switch body; on this one they are a register,
// because there is no switch to set.  What the machine reads at `MY_ADDRESS`
// (`0o764142`) and the source word its transmitter inserts are both this.

uint16_t chaos_face_address(struct chaos_face *f)
{
	return (uint16_t)(f->read(f, CHAOS_MYADDR) & 0xFFFFu);
}

void chaos_face_set_address(struct chaos_face *f, uint16_t address)
{
	f->write(f, CHAOS_MYADDR, address);
}

// --- a frame out of the machine -------------------------------------------

int chaos_face_take(struct chaos_face *f, uint16_t *words, unsigned max)
{
	const uint32_t stat = f->read(f, CHAOS_STAT);
	if (!(stat & CHAOS_ST_TX_VALID))
		return 0;
	// **`TXLEN` is read whole and not masked.**  Sixteen bits are all a
	// length can need, and masking a fabric that reports 0x10000 down to
	// zero would turn a fault into "no frame waiting" --- a value that
	// means nothing must not be a value the instrument can mean.  Nothing
	// changes between the two reads: only this program clears `TX_VALID`.
	const uint32_t len = f->read(f, CHAOS_TXLEN);
	const unsigned room = max < CHAOS_MAX_WORDS ? max : CHAOS_MAX_WORDS;
	if (len == 0 || len > room) {
		// **Taken anyway, and said.**  A length this program cannot hold
		// will not become holdable by waiting, and a frame left standing
		// holds the machine's transmitter down for ever --- Transmit Done
		// never comes up.  So the frame goes on the floor, the machine is
		// let go, and the line says which half is at fault.
		say("the interface offers a frame of %u words and this holds %u: "
		    "dropped, and the transmitter let go",
		    (unsigned)len, room);
		f->write(f, CHAOS_CTL, CHAOS_CTL_TX_TAKE);
		return -1;
	}
	for (unsigned k = 0; k < (unsigned)len; ++k)
		words[k] = (uint16_t)(f->read(f, CHAOS_TX_WINDOW + k) & 0xFFFFu);
	// Taking a frame includes telling the fabric it was taken, so a caller
	// that drops the frame on the floor has still let the machine transmit
	// again --- which is right: the cable carried it and nobody wanted it.
	f->write(f, CHAOS_CTL, CHAOS_CTL_TX_TAKE);
	return (int)len;
}

// --- a frame into the machine ---------------------------------------------

// Said once when the interface is in Loop Back and cleared when it leaves,
// so a maintenance mode is reported and not repeated on every frame.  A file
// static because `struct chaos_face` is the fabric's face and not a place to
// keep this program's state, and because one program has one interface.
static int looped_said;

int chaos_face_give(struct chaos_face *f, const uint16_t *words, unsigned n)
{
	if (n < CHAOS_FACE_MIN_WORDS || n > CHAOS_MAX_WORDS) {
		say("a frame of %u words is not one this seam carries, which is %u to %u "
		    "--- the eight header words, up to %u bytes of data, and the "
		    "three-word hardware trailer",
		    n, (unsigned)CHAOS_FACE_MIN_WORDS, (unsigned)CHAOS_MAX_WORDS,
		    (unsigned)CHAOS_MAX_DATA);
		return -1;
	}
	const uint32_t stat = f->read(f, CHAOS_STAT);
	if (stat & CHAOS_ST_LOOPED) {
		// `csr::LOOP_BACK`: the fabric is carrying the machine's own
		// packets back to it and the cable is not in use.  Honoured
		// rather than ignored --- a frame injected here would arrive as
		// though the machine had sent it to itself.
		if (!looped_said) {
			say("the interface is in Loop Back; nothing is injected while it is");
			looped_said = 1;
		}
		return 0;
	}
	looped_said = 0;
	// **A REFUSAL IS TOLD FROM A STORE BY `LOST`, NOT BY `STAT`.**  After a
	// commit `RX_BUSY` is up either way --- the machine holds the frame
	// just stored, or the one it had not read out --- so `STAT` cannot
	// answer this and only the fabric's own count of refusals can.  That
	// is also what makes the count in `LOST` true: it is the fabric that
	// refuses and the fabric that counts, and this program offers the
	// frame rather than deciding for it.
	const uint32_t lost_before = f->read(f, CHAOS_LOST);
	for (unsigned k = 0; k < n; ++k)
		f->write(f, CHAOS_RX_WINDOW + k, words[k]);
	f->write(f, CHAOS_RXLEN, n);
	f->write(f, CHAOS_CTL, CHAOS_CTL_RX_COMMIT);
	const uint32_t lost_after = f->read(f, CHAOS_LOST);
	if (lost_after != lost_before)
		return 0;
	// `LOST` saturates rather than wraps, so that a reader cannot mistake a
	// wrap for calm --- and a saturated counter is a counter that has
	// stopped answering this question.  Thirty-two bits of refusals is not
	// a number a run reaches, but a value that means nothing must not be a
	// value the instrument can mean, so at the top the `STAT` read taken
	// before the commit answers instead.  It is conservative: `RX_BUSY` can
	// only have gone DOWN between that read and the commit, so this says
	// "try again" for a frame that was in fact stored and never the other
	// way round.
	if (lost_before == 0xFFFFFFFFu && (stat & CHAOS_ST_RX_BUSY))
		return 0;
	return 1;
}
