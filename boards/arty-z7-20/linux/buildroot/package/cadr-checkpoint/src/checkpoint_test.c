// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The checkpoint program's core, against a model of the fabric, on the build
// host --- no board, no Vivado, nothing but a C compiler.
//
// **WHAT THIS PROVES AND WHAT muir PROVES.**  This file holds the parts that
// can be decided here: that the packer is muir's packer, that the program
// compares the echo and refuses a word that came back for another address,
// and that every memory and every register the window reports reaches the
// body at the offset muir's format puts it.  **It cannot prove the format is
// right**, because a self-consistent writer and a self-consistent reader of
// the same wrong format agree perfectly.  What proves that is muir itself,
// and `build/checkpoint.pass` does it: this program writes a file, muir
// resumes it and writes its own, and the two are compared BYTE FOR BYTE.
// That is muir's own round-trip property --- `tests/checkpoint.rs`'s
// "the checkpoint loads and saves as itself" --- and it is the only evidence
// available here that every field went where it was meant to.
//
// The machine behind the model is a poison, injective in the memory and the
// address, for the reason every stimulus in this repository is: a machine of
// zeros would let a program that wrote the same field twice, or skipped one,
// or crossed two, agree with muir at every byte.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cadr_image.h"
#include "chk.h"
#include "chk_rtl.h"
#include "pack_bind.h"
#include "sha256.h"
#include "readout.h"

static long bad;
static void fail(const char *what, unsigned long long got, unsigned long long want)
{
	fprintf(stderr, "%s is 0x%llx, the reference says 0x%llx\n", what, got, want);
	++bad;
}

// --- the model -------------------------------------------------------------

struct model {
	uint64_t imem[IMG_IMEM_WORDS], prom[IMG_PROM_WORDS];
	uint32_t amem[IMG_AMEM_WORDS], mmem[IMG_MMEM_WORDS];
	uint32_t pdl[IMG_PDL_WORDS], spc[IMG_SPC_WORDS];
	uint32_t dmem[IMG_DMEM_WORDS], l1[IMG_L1_WORDS], l2[IMG_L2_WORDS];
	uint16_t opcs[IMG_OPCS];
	uint64_t regs[21];
	uint32_t ro_addr;
	uint32_t hi_latch_cycles, hi_latch_ticks;
	uint64_t cycles, ticks;
	int running;
	// **THE ECHO, DELIBERATELY STALE FOR THE FIRST `stale_for` READS.**  A
	// program that did not compare it would take a word for the address
	// before the one it asked for and never know; this is how the check
	// asks whether it does.
	int stale_for;
};

static uint64_t model_word(struct model *m, unsigned sel, unsigned a)
{
	switch (sel) {
	case IMG_SEL_IMEM: return a < IMG_IMEM_WORDS ? m->imem[a] : 0;
	case IMG_SEL_PROM: return a < IMG_PROM_WORDS ? m->prom[a] : 0;
	case IMG_SEL_AMEM: return a < IMG_AMEM_WORDS ? m->amem[a] : 0;
	case IMG_SEL_MMEM: return a < IMG_MMEM_WORDS ? m->mmem[a] : 0;
	case IMG_SEL_PDL:  return a < IMG_PDL_WORDS ? m->pdl[a] : 0;
	case IMG_SEL_SPC:  return a < IMG_SPC_WORDS ? m->spc[a] : 0;
	case IMG_SEL_DMEM: return a < IMG_DMEM_WORDS ? m->dmem[a] : 0;
	case IMG_SEL_MAP1: return a < IMG_L1_WORDS ? m->l1[a] : 0;
	case IMG_SEL_MAP2: return a < IMG_L2_WORDS ? m->l2[a] : 0;
	case IMG_SEL_OPCS: return a < IMG_OPCS ? m->opcs[a] : 0;
	case IMG_SEL_REGS: return a < 21 ? m->regs[a] : RO_NO_MEMORY;
	default: return RO_NO_MEMORY;
	}
}

static uint32_t model_read(struct readout *r, unsigned word)
{
	struct model *m = r->ctx;
	const unsigned sel = (m->ro_addr >> 14) & 0xFu;
	const unsigned a = m->ro_addr & 0x3FFFu;
	switch (word) {
	case RO_IDENT: return RO_IDENT_WORD;
	case RO_STAT: return 0;
	case RO_CYCLES:
		m->hi_latch_cycles = (uint32_t)(m->cycles >> 32);
		return (uint32_t)m->cycles;
	case RO_CYCLESH: return m->hi_latch_cycles;
	case RO_TICKS:
		m->hi_latch_ticks = (uint32_t)(m->ticks >> 32);
		return (uint32_t)m->ticks;
	case RO_TICKSH: return m->hi_latch_ticks;
	case RO_ADDR:
		if (m->stale_for > 0) {
			--m->stale_for;
			// One address short: the word for the one before it.
			return (m->ro_addr - 1u) & 0x3FFFFu;
		}
		return m->ro_addr;
	case RO_DATA_LO: return (uint32_t)model_word(m, sel, a);
	case RO_DATA_HI: return (uint32_t)(model_word(m, sel, a) >> 32) & 0xFFFFu;
	default: return RO_UNMAPPED;
	}
}

static void model_write(struct readout *r, unsigned word, uint32_t v)
{
	struct model *m = r->ctx;
	if (word == RO_ADDR)
		m->ro_addr = v & 0x3FFFFu;
	else if (word == RO_SPY(RO_SPY_CLK_W))
		m->running = (v & RO_CLK_RUN) != 0;
}

// The poison, `tb/cadr_readout_tb.cpp`'s, so that the two checks disagree
// about nothing.
static uint64_t poison(unsigned sel, unsigned addr, unsigned bits)
{
	const uint64_t h = (uint64_t)(sel + 1) * 0x9E3779B97F4A7C15ull +
			   (uint64_t)(addr + 1) * 0xC2B2AE3D27D4EB4Full;
	return bits >= 64 ? h : (h & ((1ull << bits) - 1ull));
}

static void fill(struct model *m)
{
	memset(m, 0, sizeof *m);
	for (unsigned i = 0; i < IMG_IMEM_WORDS; ++i)
		m->imem[i] = poison(IMG_SEL_IMEM, i, 48);
	for (unsigned i = 0; i < IMG_PROM_WORDS; ++i)
		m->prom[i] = poison(IMG_SEL_PROM, i, 48);
	for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
		m->amem[i] = (uint32_t)poison(IMG_SEL_AMEM, i, 32);
	for (unsigned i = 0; i < IMG_MMEM_WORDS; ++i)
		m->mmem[i] = (uint32_t)poison(IMG_SEL_MMEM, i, 32);
	for (unsigned i = 0; i < IMG_PDL_WORDS; ++i)
		m->pdl[i] = (uint32_t)poison(IMG_SEL_PDL, i, 32);
	for (unsigned i = 0; i < IMG_SPC_WORDS; ++i)
		m->spc[i] = (uint32_t)poison(IMG_SEL_SPC, i, 21);
	for (unsigned i = 0; i < IMG_DMEM_WORDS; ++i)
		m->dmem[i] = (uint32_t)poison(IMG_SEL_DMEM, i, 17);
	for (unsigned i = 0; i < IMG_L1_WORDS; ++i)
		m->l1[i] = (uint32_t)poison(IMG_SEL_MAP1, i, 5);
	for (unsigned i = 0; i < IMG_L2_WORDS; ++i)
		m->l2[i] = (uint32_t)poison(IMG_SEL_MAP2, i, 24);
	for (unsigned i = 0; i < IMG_OPCS; ++i)
		m->opcs[i] = (uint16_t)poison(IMG_SEL_OPCS, i, 14);

	// The register table.  **Every entry is masked to the width the
	// machine's own register has**, because muir refuses a pointer wider
	// than its register by name --- `spcptr > 0o37` and the two PDL
	// pointers past ten bits are three of its four range checks.
	static const unsigned bits[21] = { 14, 14, 48, 48, 32, 32, 32, 32,
					   32, 26, 10, 10, 10, 5, 14, 10,
					   24, 32, 22, 6, 33 };
	for (unsigned i = 0; i < 21; ++i)
		m->regs[i] = poison(IMG_SEL_REGS, i, bits[i]);
	m->cycles = 0x1234567890ull;
	m->ticks = 0x9876543210ull;
	m->running = 0;
}

// --- the packer, against its own inverse -----------------------------------

static int unpack_equals(const uint8_t *raw, size_t len)
{
	size_t plen = 0;
	uint8_t *p = chk_pack(raw, len, &plen);
	if (!p)
		return 0;
	uint8_t *out = malloc(len ? len : 1);
	size_t o = 0, at = 0;
	int ok = 1;
	while (at < plen) {
		uint64_t zeros = 0, lit = 0;
		unsigned shift = 0;
		while (at < plen) {
			uint8_t b = p[at++];
			zeros |= (uint64_t)(b & 0x7f) << shift;
			shift += 7;
			if (!(b & 0x80))
				break;
		}
		shift = 0;
		while (at < plen) {
			uint8_t b = p[at++];
			lit |= (uint64_t)(b & 0x7f) << shift;
			shift += 7;
			if (!(b & 0x80))
				break;
		}
		if (o + zeros + lit > len) { ok = 0; break; }
		memset(out + o, 0, zeros);
		o += zeros;
		memcpy(out + o, p + at, lit);
		o += lit;
		at += lit;
	}
	if (ok)
		ok = (o == len) && (len == 0 || memcmp(out, raw, len) == 0);
	free(out);
	free(p);
	return ok;
}

int main(int argc, char **argv)
{
	// **THE SCRATCH DIRECTORY IS NOT OPTIONAL.**  Half of what this file
	// checks --- the sidecar written, read back and made to notice a pack
	// that has moved --- needs somewhere to put three small files, and a
	// check that quietly does less when an argument is missing is the
	// failure this repository keeps meeting.  So it is demanded.
	if (argc < 2) {
		fprintf(stderr, "usage: checkpoint_test <scratch directory> "
			"[<checkpoint to write>]\n");
		return 2;
	}
	const char *work = argv[1];
	const char *out = argc > 2 ? argv[2] : NULL;

	if (chk_rtl_mutation())
		printf("checkpoint: THIS IS A MUTANT --- %s\n", chk_rtl_mutation());

	// ---- SHA-256, against the standard's own vectors ---------------------
	//
	// **A HASH THAT IS SELF-CONSISTENTLY WRONG AGREES WITH ITSELF PERFECTLY
	// AND WITH NOBODY ELSE**, and the whole point of the digest in a
	// sidecar is that somebody with `sha256sum` and no software of ours can
	// check it.  So it is held to FIPS 180-4's published values and not to
	// a second implementation of the same mistake.
	{
		struct { const char *in; unsigned long repeat; const char *want; } v[] = {
			{ "", 1,
			  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
			{ "abc", 1,
			  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
			{ "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", 1,
			  "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" },
			// A million 'a's, fed a thousand at a time: the vector that
			// exercises the length field and the buffering together.
			{ "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 20000,
			  "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0" },
		};
		for (unsigned i = 0; i < sizeof v / sizeof v[0]; ++i) {
			struct sha256 h;
			sha256_init(&h);
			for (unsigned long k = 0; k < v[i].repeat; ++k)
				sha256_feed(&h, v[i].in, strlen(v[i].in));
			uint8_t d[SHA256_BYTES];
			char hex[SHA256_HEX];
			sha256_end(&h, d);
			sha256_hex(d, hex);
			if (strcmp(hex, v[i].want) != 0) {
				fprintf(stderr, "SHA-256 vector %u is %s, the standard "
					"says %s\n", i, hex, v[i].want);
				++bad;
			}
		}
	}

	// ---- a pack's geometry, which is its size and nothing else -----------
	//
	// `Unit::load` REFUSES a checkpoint whose geometry is not the resuming
	// drive's, so a geometry guessed rather than measured turns into a
	// refusal at the far end.  It is measured the way `cadr-disk-packs`
	// measures it: from the file's length.
	{
		uint32_t c = 0, h = 0, b = 0;
		if (bind_geometry_of_size(269562880ull, &c, &h, &b) != 0 ||
		    c != 815 || h != 19 || b != 17)
			fail("the T-300's geometry", ((uint64_t)c << 32) | (h << 8) | b, 0);
		if (bind_geometry_of_size(70937600ull, &c, &h, &b) != 0 ||
		    c != 815 || h != 5 || b != 17)
			fail("the T-80's geometry", ((uint64_t)c << 32) | (h << 8) | b, 0);
		// One byte short is a pack still being copied in, and is no drive.
		if (bind_geometry_of_size(269562879ull, &c, &h, &b) == 0)
			fail("a file one byte short was taken for a pack", 1, 0);
	}

	// ---- the sidecar: written, read back, and made to notice ------------
	//
	// Two small files stand in for packs.  `bind_verify` digests whatever
	// path it is given and does not care what a pack's size is, so the
	// property under test --- that a pack which has moved since the
	// checkpoint is NAMED rather than passed over --- is reachable without
	// a quarter of a gigabyte.
	{
		// Short by construction: `struct binding` holds a checkpoint's name in
		// 512 bytes and a pack's in 1024, and a scratch name that could not
		// fit would be a warning here rather than a finding.
		char a[256], b2[256], side[320], stand[256];
		snprintf(a, sizeof a, "%s/stand-in-pack-0", work);
		snprintf(b2, sizeof b2, "%s/stand-in-pack-1", work);
		snprintf(stand, sizeof stand, "%s/stand-in.chk", work);
		snprintf(side, sizeof side, "%s%s", stand, BIND_SUFFIX);
		FILE *f = fopen(a, "wb");
		if (f) { fputs("the pack as it was", f); fclose(f); }
		f = fopen(b2, "wb");
		if (f) { fputs("the other pack", f); fclose(f); }
		f = fopen(stand, "wb");
		if (f) { fputs("a checkpoint, for the purposes of this check", f); fclose(f); }

		struct binding w;
		bind_init(&w);
		w.boards = 32;
		w.microcycles = 1234567890ull;
		w.ns = 9876543210ull;
		w.machine_halted_first = 1;
		snprintf(w.taken, sizeof w.taken, "2026-09-11T19:30:00+0300");
		snprintf(w.checkpoint, sizeof w.checkpoint, "%s", stand);
		if (sha256_file(stand, w.checkpoint_sha, &w.checkpoint_bytes) != 0)
			fail("the stand-in checkpoint could not be digested", 1, 0);
		w.u[0].present = 1;
		snprintf(w.u[0].path, sizeof w.u[0].path, "%s", a);
		w.u[0].bytes = strlen("the pack as it was");
		w.u[0].cylinders = 815; w.u[0].heads = 19; w.u[0].blocks_per_track = 17;
		w.u[3].present = 1;
		snprintf(w.u[3].path, sizeof w.u[3].path, "%s", b2);
		w.u[3].bytes = strlen("the other pack");
		w.u[3].cylinders = 815; w.u[3].heads = 5; w.u[3].blocks_per_track = 17;
		w.u[3].read_only = 1;
		w.present = 2;
		char err[512] = "";
		if (bind_digest(&w, err, sizeof err) != 0)
			fail("the stand-in packs could not be digested", 1, 0);
		// **A DIGEST OF NOTHING IS NOT A DIGEST.**  Two different files
		// must have two different digests, or the check below would pass
		// against a binding that recorded one constant.
		if (strcmp(w.u[0].sha256, w.u[3].sha256) == 0)
			fail("two different packs digested the same", 1, 0);
		if (bind_write(&w, side, err, sizeof err) != 0)
			fail("the sidecar could not be written", 1, 0);

		struct binding rd;
		if (bind_read(&rd, side, err, sizeof err) != 0) {
			fprintf(stderr, "reading the sidecar back: %s\n", err);
			++bad;
		} else {
			if (rd.present != 2)
				fail("the sidecar's pack count", rd.present, 2);
			if (!rd.u[0].present || !rd.u[3].present)
				fail("the sidecar lost a unit", 0, 1);
			if (strcmp(rd.u[0].sha256, w.u[0].sha256) != 0)
				fail("unit 0's digest did not survive the sidecar", 1, 0);
			if (strcmp(rd.u[0].path, a) != 0)
				fail("unit 0's path did not survive the sidecar", 1, 0);
			if (rd.u[3].heads != 5 || !rd.u[3].read_only)
				fail("unit 3's geometry or switch did not survive", 1, 0);
			if (rd.boards != 32 || rd.microcycles != 1234567890ull)
				fail("the sidecar's header did not survive", rd.boards, 32);
			int chk_moved = 0;
			const int moved = bind_verify(&rd, &chk_moved, err, sizeof err);
			if (moved != 0)
				fail("an unchanged pack was called moved", (unsigned)moved, 0);
			// Now move one, by one byte, and require that it is named.
			f = fopen(a, "ab");
			if (f) { fputc('!', f); fclose(f); }
			struct binding again;
			if (bind_read(&again, side, err, sizeof err) != 0)
				fail("the sidecar could not be read a second time", 1, 0);
			const int moved2 = bind_verify(&again, &chk_moved, err, sizeof err);
			if (moved2 != 1)
				fail("a pack that moved was not caught", (unsigned)moved2, 1);
			else if (!again.u[0].moved || again.u[3].moved)
				fail("the wrong unit was named as moved", 1, 0);
			// And a pack that is not there at all is a refusal and not
			// a verdict: nothing can be said about a file nobody has.
			remove(a);
			struct binding gone;
			if (bind_read(&gone, side, err, sizeof err) != 0)
				fail("the sidecar could not be read a third time", 1, 0);
			if (bind_verify(&gone, &chk_moved, err, sizeof err) >= 0)
				fail("a missing pack was given a verdict", 1, 0);
			remove(b2);
			remove(stand);
			remove(side);
		}
	}

	// ---- the packer ----------------------------------------------------
	//
	// muir's `unpack` accepts any valid packing, so this does not prove the
	// packing is muir's; what proves that is the byte comparison against
	// muir's own re-save.  What this proves is that nothing is LOST, which
	// a round trip can say on its own.
	{
		static const uint8_t cases[][24] = {
			{ 0 },
			{ 1, 2, 3 },
			{ 0, 0, 0, 1 },			/* three zeros stay literal */
			{ 0, 0, 0, 0, 1 },		/* four end the run */
			{ 1, 0, 0, 2, 0, 0, 0, 0, 3 },
		};
		static const size_t lens[] = { 0, 3, 4, 5, 9 };
		for (unsigned i = 0; i < 5; ++i)
			if (!unpack_equals(cases[i], lens[i]))
				fail("a packed case does not unpack to itself", i, i);
		uint8_t big[4096];
		for (unsigned i = 0; i < sizeof big; ++i)
			big[i] = (i % 37u) < 30u ? 0u : (uint8_t)i;
		if (!unpack_equals(big, sizeof big))
			fail("a long packed case does not unpack to itself", 1, 0);
	}

	// ---- the echo, which the program must compare -----------------------
	{
		struct model m;
		fill(&m);
		m.stale_for = 1;
		struct readout r;
		memset(&r, 0, sizeof r);
		r.read = model_read;
		r.write = model_write;
		r.ctx = &m;
		uint64_t w = 0;
		if (ro_word(&r, IMG_SEL_IMEM, 7, &w) == 0)
			fail("a word came back for an address that was not asked "
			     "for and the program took it", 1, 0);
		if (r.stale != 1)
			fail("the stale read was not counted", r.stale, 1);
		// And the next read, with the echo honest, must succeed.
		if (ro_word(&r, IMG_SEL_IMEM, 7, &w) != 0)
			fail("an honest read was refused", 1, 0);
		if (w != poison(IMG_SEL_IMEM, 7, 48))
			fail("the word", w, poison(IMG_SEL_IMEM, 7, 48));
	}

	// ---- the whole machine through the window ---------------------------
	struct model *m = malloc(sizeof *m);
	if (!m) {
		fprintf(stderr, "out of memory\n");
		return 1;
	}
	fill(m);
	struct readout r;
	memset(&r, 0, sizeof r);
	r.read = model_read;
	r.write = model_write;
	r.ctx = m;

	// One memory board: the file is then small enough to be diffed by hand
	// and muir resumes it at the header's own count.  Thirty-two is what
	// the board has and the field is the same field either way.
	struct cadr_image img;
	if (img_alloc(&img, 1) != 0) {
		fprintf(stderr, "out of memory\n");
		return 1;
	}
	// **NO DRIVE, SO THE FILE muir RESUMES NEEDS NO PACK.**  The board
	// declares the units its drive bay holds; here there are none, which
	// is a state `Controller::load` accepts and is the one that makes the
	// round trip runnable with nothing but a muir.
	struct chk_declared decl;
	memset(&decl, 0, sizeof decl);
	decl.chaos_address = 0177001u;

	if (ro_read_machine(&r, &img) != 0) {
		fail("the window would not give the machine up", r.stale, 0);
		return 1;
	}

	// Every memory came back as the model holds it.  This is the program's
	// own transport, not muir's format: a selector read into the wrong
	// array, or a length off by one, shows here.
	for (unsigned i = 0; i < IMG_IMEM_WORDS; ++i)
		if (img.imem[i] != m->imem[i]) { fail("imem", img.imem[i], m->imem[i]); break; }
	for (unsigned i = 0; i < IMG_PROM_WORDS; ++i)
		if (img.prom[i] != m->prom[i]) { fail("prom", img.prom[i], m->prom[i]); break; }
	for (unsigned i = 0; i < IMG_AMEM_WORDS; ++i)
		if (img.amem[i] != m->amem[i]) { fail("amem", img.amem[i], m->amem[i]); break; }
	for (unsigned i = 0; i < IMG_DMEM_WORDS; ++i)
		if (img.dmem[i] != m->dmem[i]) { fail("dmem", img.dmem[i], m->dmem[i]); break; }
	for (unsigned i = 0; i < IMG_L2_WORDS; ++i)
		if (img.l2_map[i] != m->l2[i]) { fail("l2_map", img.l2_map[i], m->l2[i]); break; }
	if (img.pc != (uint16_t)m->regs[IMG_RG_PC])
		fail("PC", img.pc, m->regs[IMG_RG_PC]);
	if (img.ir != m->regs[IMG_RG_IR])
		fail("IR", img.ir, m->regs[IMG_RG_IR]);
	if (img.spcptr != (uint8_t)m->regs[IMG_RG_SPCPTR])
		fail("SPCPTR", img.spcptr, m->regs[IMG_RG_SPCPTR]);
	if (img.cycles != m->cycles)
		fail("CYCLES", img.cycles, m->cycles);
	if (img.ticks != m->ticks)
		fail("TICKS", img.ticks, m->ticks);

	// Main memory and the display are DDR on the board and are poisoned
	// here, so that the two largest arrays in the file are not zeros.
	for (size_t i = 0; i < IMG_BOARD_WORDS; ++i)
		img.main[i] = (uint32_t)poison(12, (unsigned)i, 32);
	for (size_t i = 0; i < IMG_TV_WORDS; ++i)
		img.tv[i] = (uint32_t)poison(13, (unsigned)i, 32);

	struct chk body;
	chk_init(&body);
	chk_rtl_body(&body, &img, &decl);
	if (body.broken) {
		fail("the body ran out of memory", 1, 0);
		return 1;
	}

	// **THE BODY'S LENGTH IS A FIXED NUMBER AND IT IS ASSERTED.**  Every
	// field in an `rtl` body is fixed-width and every array's length is
	// known, so the whole body is one arithmetic expression --- and a field
	// added, dropped or written at the wrong width moves it.  That is a
	// cheap, sharp check on a format with no framing in it: muir would
	// catch the same mistake, but only after the file reached a machine
	// with muir on it.
	//
	// Machine::save, one board:
	//   prom       8 + 1024*8         = 8200
	//   imem       8 + 16384*8        = 131080
	//   mode/clk/opc  6 + 5 + 3       = 14
	//   debug_ir + prog_reset + boot  = 10
	//   amem/mmem/dmem/pdl/spc  (8+4096)+(8+128)+(8+8192)+(8+4096)+(8+128) = 16680
	//   spcptr..dispatch_constant     = 1+2+2+4+2+4+4+4+4+2 = 29
	//   l1_map     8 + 8192           = 8200
	//   l2_map     8 + 4096           = 4104
	//   boards     4
	//   main       8 + 65536*4        = 262152
	//   bus_error..write_buffer  2+2+1+(8+32)*3 = 125
	//   vmaok      1
	//   disk       61 + 8             = 69       (no drives: 8 flag bytes)
	//   simpletv   (8+131072)+4+(8+4096)+2+1+1+8 = 135200
	//   ioboard    57 + 110 + 1 + 85  = 253      (its own, the serial port's
	//                                             Pci, the chaos flag, and
	//                                             the Chaosnet interface)
	//   cycles+ns  16
	// Rtl tail:
	//   trace+flags  (8+96)*2         = 208
	//   ir..lc       8+8+2+1+1+4+2+2+4 = 32
	//   19 bools                       = 19
	//   halted_ns + 4 bools            = 12
	//   busint     (1+1+8) + 42*1 + (1+8+1+1+8+1+1+1+1+8+8+1+2+2+8+8+8+1+1+1+8+8) = 140
	//   mbusy_sync                     = 1
	//   bus_addr..bus_acked            = 4+4+1+1+1+1+2+1+8+8+1 = 32
	//   debug_*                        = 1+1+1+1+1+1+8+1+2+8 = 25
	//   wmapd..imodd                   = 1+4+8+8+1+1+2+1 = 26
	//   opc        8 + 16              = 24
	//   stat..executed                 = 4+1+1+8+4+8+1 = 27
	//
	// The arithmetic is written out rather than summed by hand so that a
	// reader can check one line instead of one number.
	{
		const size_t machine_part =
			8200 + 131080 + 14 + 10 + 16680 + 29 + 8200 + 4104 + 4 +
			262152 + 125 + 1 + 69 + 135200 + 253 + 16;
		const size_t rtl_part =
			208 + 32 + 19 + 12 + 140 + 1 + 32 + 25 + 26 + 24 + 27;
		// **A MUTANT IS JUDGED BY muir AND NOT HERE.**  Two of the three
		// keep the body's length and one does not, and the point of
		// building them is what the ROUND TRIP does with them, so this
		// assertion --- which belongs to the real thing --- stands down.
		if (!chk_rtl_mutation() && body.len != machine_part + rtl_part)
			fail("the body's length", body.len, machine_part + rtl_part);
	}

	if (out) {
		if (chk_write_file(out, "rtl", 1, &body) != 0) {
			perror(out);
			return 1;
		}
	}

	printf("checkpoint: %zu bytes of body, %lu reads and %lu writes over a "
	       "modelled window, %lu of them refused for a stale echo\n",
	       body.len, r.reads, r.writes, r.stale);
	if (out)
		printf("checkpoint: wrote %s --- muir opening it is the proof, and "
		       "`make build/checkpoint.pass` is where that happens\n", out);
	chk_free(&body);
	img_free(&img);
	free(m);

	if (bad) {
		fprintf(stderr, "FAIL: %ld mismatches\n", bad);
		return 1;
	}
	printf("PASS\n");
	return 0;
}
