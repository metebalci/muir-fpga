// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack feeder, held to the reference trace on the build host: no board,
// no fabric, a model of the register face in its place.
//
//     feeder_test <disk.golden> <work dir>
//
// WHAT THE TRACE SUPPLIES.  `golden/src/disk.rs` writes three kinds of row
// this test reads.  `BLK load|lay` is a block as the pack carries it before
// any transfer --- what a formatter or the vendor laid --- and goes into the
// pack file exactly as muir's `Unit` would hold it.  `NEED` is a block a
// transfer read off the pack, in the order the walk reached it: the request
// the CADR would have made, and the thing the register face at HEAD has no
// way to carry (see the report and `docs/disk-controller.md`), so here the
// trace stands in for that path and the feeder is asked to serve each one.
// `BLK write` is a block a transfer wrote: the 259 words the fabric's store
// holds afterwards, which the feeder must take back and put on the pack.
//
// WHAT IS CHECKED.  Every block the trace needs lands in the model's store
// as the 259 words the trace says the pack carries, tagged with its disk
// address, from a 128-byte-aligned address inside the spare part of the
// CADR's region with no burst crossing 4 KB.  Every block written back
// reaches the pack file byte for byte, and reads back out of it as the
// same 259 words --- the two tables round-trip.  The ECC is held to muir on
// every `load` row's two checkwords.  And the driver's refusal handling is
// exercised against the model's refusals: an unaligned address, a slot past
// the store, two bits at once, the channel walking (retried), a move that
// moved nothing (detected, not committed).
//
// THE MODEL OF THE REGISTER FACE follows `rtl/cadr_disk_pack.sv`: the
// refusal terms at its `bad_align`, `bad_slot`, `bad_busy`, `bad_ch` and
// `go_one`; `refused` rewritten on every request; busy for a number of
// status reads, then done; the slot taken away before a fetch and tagged
// after it; a write-back leaving the pad word alone.  A model, not the RTL:
// what it holds the feeder to is the face's contract, and the RTL is held
// to the same contract by `tb/cadr_disk_pack_tb.cpp`.

#include <errno.h>
#include <stdarg.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "pack_ecc.h"
#include "pack_feeder.h"
#include "pack_file.h"
#include "pack_side.h"

static int bad = 0;
static void fail(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void fail(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("FAIL: ", stderr);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	++bad;
}

// ------------------------------------------------------------ the model
struct fake {
	uint32_t regs[8];
	uint32_t store[PS_SLOTS][PACK_RECORD_WORDS];
	uint32_t tag[PS_SLOTS];
	int valid[PS_SLOTS];
	uint32_t *ddr;		// the spare region, `ddr[0]` at `ddr_phys`
	uint32_t ddr_phys, ddr_bytes;
	int busy_left, busy_polls;	// status reads a move stays busy for
	int ch_active_left;		// pauses the channel stays walking for
	int done, error, refused, miss;
	int drop_next_write;		// a write-back that moves nothing
	uint32_t last_addr, last_ctl;
	unsigned long fetches, writes, takes, refusals, reads, pauses;
};

static int fake_in_ddr(struct fake *k, uint32_t addr, uint32_t bytes)
{
	return addr >= k->ddr_phys && addr - k->ddr_phys + bytes <= k->ddr_bytes;
}

static uint32_t fake_read(struct pack_side *ps, unsigned reg)
{
	struct fake *k = ps->ctx;
	++k->reads;
	switch (reg) {
	case PS_ADDR: case PS_TAG: case PS_SLOT: case PS_DRIVE:
		return k->regs[reg];
	case PS_CTL: {
		int busy = 0;
		if (k->busy_left > 0) {
			--k->busy_left;
			busy = 1;
		}
		return (k->miss ? PS_ST_STORE_MISS : 0) | (k->ch_active_left > 0 ? PS_ST_CH_ACTIVE : 0)
		     | (k->refused ? PS_ST_REFUSED : 0) | (k->error ? PS_ST_ERROR : 0)
		     | (k->done && !busy ? PS_ST_DONE : 0) | (busy ? PS_ST_BUSY : 0);
	}
	case PS_IDENT:
		return PS_IDENT_WORD;
	default:
		return 0;
	}
}

static void fake_write(struct pack_side *ps, unsigned reg, uint32_t v)
{
	struct fake *k = ps->ctx;
	if (reg == PS_ADDR || reg == PS_TAG || reg == PS_SLOT || reg == PS_DRIVE) {
		k->regs[reg] = v & (reg == PS_TAG ? 0x0FFFFFFFu : reg == PS_SLOT ? 0x1Fu : reg == PS_DRIVE ? 0x1FFFFFFu : ~0u);
		return;
	}
	if (reg != PS_CTL)
		return;
	const uint32_t go = v & 7u;
	if (!go)
		return;
	const int one = (go == 1 || go == 2 || go == 4);
	const uint32_t addr = k->regs[PS_ADDR];
	const unsigned slot = k->regs[PS_SLOT];
	const int bad_align = (addr & 0x7Fu) != 0 && go != PS_CTL_TAKE;
	const int bad_slot = slot >= PS_SLOTS;
	const int busy = k->busy_left > 0;
	const int ch = k->ch_active_left > 0;
	k->refused = !one || bad_align || bad_slot || busy || ch;
	k->last_ctl = go;
	if (k->refused) {
		++k->refusals;
		return;
	}
	k->done = 0;
	k->error = 0;
	k->busy_left = k->busy_polls;
	k->last_addr = addr;
	if (go == PS_CTL_TAKE) {
		k->valid[slot] = 0;
		++k->takes;
	} else if (go == PS_CTL_FETCH) {
		k->valid[slot] = 0;
		if (!fake_in_ddr(k, addr, PACK_RECORD_WORDS * 4)) {
			k->error = 1;	// SLVERR/DECERR from the port
		} else {
			memcpy(k->store[slot], k->ddr + (addr - k->ddr_phys) / 4, PACK_RECORD_WORDS * 4);
			k->tag[slot] = k->regs[PS_TAG];
			k->valid[slot] = 1;
		}
		++k->fetches;
	} else {
		if (!fake_in_ddr(k, addr, PACK_RECORD_WORDS * 4))
			k->error = 1;
		else if (k->drop_next_write)
			k->drop_next_write = 0;
		else
			memcpy(k->ddr + (addr - k->ddr_phys) / 4, k->store[slot], PACK_RECORD_WORDS * 4);
		++k->writes;
	}
	k->done = 1;
}

static void fake_pause(struct pack_side *ps)
{
	struct fake *k = ps->ctx;
	++k->pauses;
	if (k->ch_active_left > 0)
		--k->ch_active_left;
}

// ------------------------------------------------------------ the trace
struct shadow {
	uint32_t lba, slot;
	uint32_t words[PACK_RECORD_WORDS];
};
static struct shadow shadows[64];
static size_t n_shadows;

static struct shadow *shadow_of(uint32_t lba, int make)
{
	for (size_t i = 0; i < n_shadows; ++i)
		if (shadows[i].lba == lba)
			return &shadows[i];
	if (!make)
		return NULL;
	if (n_shadows == sizeof shadows / sizeof shadows[0]) {
		fail("more distinct blocks in the trace than this test holds");
		exit(2);
	}
	shadows[n_shadows].lba = lba;
	return &shadows[n_shadows++];
}

static uint32_t hex(const char *s)
{
	return (uint32_t)strtoul(s, NULL, 16);
}

// Checks on an address the feeder chose: the fabric's rules, and that no
// two records the feeder ever placed lie within a record of each other ---
// a stride shorter than 1,036 bytes puts one record's tail under the next
// one's head and the store would still read right at the instant of the
// fetch.
static uint32_t areas[2 * PS_SLOTS + 8];
static size_t n_areas;
static void check_addr(uint32_t at, const char *what)
{
	int seen = 0;
	for (size_t i = 0; i < n_areas; ++i) {
		if (areas[i] == at)
			seen = 1;
		else if ((areas[i] > at ? areas[i] - at : at - areas[i]) < PACK_RECORD_WORDS * 4)
			fail("%s: the record at 0x%08x overlaps the one at 0x%08x", what, at, areas[i]);
	}
	if (!seen && n_areas < sizeof areas / sizeof areas[0])
		areas[n_areas++] = at;
	if (at % PS_RECORD_ALIGN)
		fail("%s: address 0x%08x is not 128-byte aligned", what, at);
	if (at < FEEDER_SPARE_BASE || at + PACK_RECORD_WORDS * 4 > FEEDER_SPARE_BASE + FEEDER_SPARE_BYTES)
		fail("%s: address 0x%08x is not inside the spare part of the CADR's region", what, at);
	for (unsigned burst = 0; burst < 9; ++burst) {
		const uint32_t a = at + (burst < 8 ? 128u * burst : 1024u);
		const uint32_t n = burst < 8 ? 128u : 16u;
		if ((a >> 12) != ((a + n - 1) >> 12))
			fail("%s: burst %u of the record at 0x%08x crosses 4 KB", what, burst, at);
	}
}

int main(int argc, char **argv)
{
	if (argc != 3) {
		fprintf(stderr, "usage: feeder_test <disk.golden> <work dir>\n");
		return 2;
	}
	FILE *trace = fopen(argv[1], "r");
	if (!trace) {
		fprintf(stderr, "feeder_test: %s: %s\n", argv[1], strerror(errno));
		return 2;
	}
	char err[256];

	// The pack: a T-300's size, sparse, fresh for this run.
	char path[4096];
	snprintf(path, sizeof path, "%s/pack-test.img", argv[2]);
	unlink(path);
	{
		int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (fd < 0 || ftruncate(fd, (off_t)PACK_T300.cylinders * PACK_T300.heads * PACK_T300.blocks_per_track * PACK_BLOCK_BYTES) < 0) {
			fprintf(stderr, "feeder_test: %s: %s\n", path, strerror(errno));
			return 2;
		}
		close(fd);
	}
	struct pack pk;
	{
		// A file of the wrong size is refused, as muir refuses it.
		char wrong[4096];
		snprintf(wrong, sizeof wrong, "%s/wrong-size.img", argv[2]);
		int fd = open(wrong, O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (fd >= 0) {
			if (ftruncate(fd, 1234567) < 0)
				fail("truncating the wrong-size file");
			close(fd);
		}
		struct pack w;
		if (pack_open(&w, wrong, 0, err, sizeof err) == 0) {
			fail("a file of 1,234,567 bytes was opened as a pack");
			pack_close(&w);
		}
		unlink(wrong);
	}
	if (pack_open(&pk, path, 1, err, sizeof err) < 0) {
		fail("opening the test pack: %s", err);
		return 1;
	}
	if (pk.g.heads != 19)
		fail("a file of a T-300's size was taken for %u heads", pk.g.heads);

	// The face and the spare.
	struct fake k;
	memset(&k, 0, sizeof k);
	k.busy_polls = 5;
	k.ddr_phys = FEEDER_SPARE_BASE;
	k.ddr_bytes = FEEDER_MAP_BYTES;
	k.ddr = calloc(k.ddr_bytes / 4, 4);
	// Poison everything nothing has written, so a fetch from the wrong
	// place reads as such.
	for (uint32_t i = 0; i < k.ddr_bytes / 4; ++i)
		k.ddr[i] = (i * 0x9E3779B1u) | 1u;
	struct pack_side ps;
	ps_init(&ps);
	ps.read = fake_read;
	ps.write = fake_write;
	ps.pause = fake_pause;
	ps.ctx = &k;
	uint32_t ident;
	if (!ps_ident_ok(&ps, &ident))
		fail("IDENT read 0x%08x", ident);

	struct feeder f;
	if (feeder_init(&f, &pk, &ps, k.ddr, k.ddr_phys, k.ddr_bytes, NULL) < 0) {
		fail("feeder_init");
		return 1;
	}

	// The header's own counts, so the totals below are the trace's.
	unsigned long want_needs = 0, want_writes = 0;
	unsigned long needs = 0, loads = 0, lays = 0, writes = 0, ecc_checked = 0;
	unsigned long words_compared = 0, bytes_compared = 0;
	int present = 0, read_only = 0, timed = 0;

	char *line = NULL;
	size_t cap = 0;
	ssize_t len;
	long lineno = 0;
	while ((len = getline(&line, &cap, trace)) > 0) {
		++lineno;
		if (line[len - 1] == '\n')
			line[--len] = 0;
		if (line[0] == '#') {
			unsigned long v;
			if (sscanf(line, "# blocks_needed %lu", &v) == 1)
				want_needs = v;
			if (sscanf(line, "# starts %*u pages_to_memory %*u blocks_to_pack %lu", &v) == 1)
				want_writes = v;
			continue;
		}
		char *save = NULL;
		char *kind = strtok_r(line, " ", &save);
		if (!kind)
			continue;
		if (strcmp(kind, "BLK") == 0) {
			const char *why = strtok_r(NULL, " ", &save);
			const uint32_t slot = (uint32_t)strtoul(strtok_r(NULL, " ", &save), NULL, 10);
			strtok_r(NULL, " ", &save);	// `at`: the trace's DDR address, the testbench's business
			const uint32_t lba = hex(strtok_r(NULL, " ", &save));
			const uint32_t c = hex(strtok_r(NULL, " ", &save));
			const uint32_t h = hex(strtok_r(NULL, " ", &save));
			const uint32_t b = hex(strtok_r(NULL, " ", &save));
			uint32_t words[PACK_RECORD_WORDS];
			words[256] = hex(strtok_r(NULL, " ", &save));
			words[257] = hex(strtok_r(NULL, " ", &save));
			words[258] = hex(strtok_r(NULL, " ", &save));
			for (int i = 0; i < PACK_BLOCK_WORDS; ++i) {
				const char *w = strtok_r(NULL, " ", &save);
				if (!w) {
					fail("line %ld: BLK row with fewer than 256 words", lineno);
					break;
				}
				words[i] = hex(w);
			}
			uint32_t lba2;
			if (pack_lba(&pk.g, c, h, b, &lba2) < 0 || lba2 != lba)
				fail("line %ld: %u/%u/%u is lba %x here and %x in the trace", lineno, c, h, b, lba2, lba);
			struct shadow *s = shadow_of(lba, 1);
			s->slot = slot;
			memcpy(s->words, words, sizeof words);
			if (strcmp(why, "write") == 0) {
				// The CADR wrote it: the store's slot holds these 259
				// words, and the feeder takes them back.
				++writes;
				memcpy(k.store[slot], words, sizeof words);
				k.tag[slot] = ps_tag(c, h, b);
				k.valid[slot] = 1;
				if (feeder_writeback(&f, slot, err, sizeof err) < 0) {
					fail("line %ld: writing block %x back: %s", lineno, lba, err);
					continue;
				}
				check_addr(k.last_addr, "a write-back");
				if (k.last_ctl != PS_CTL_WRITE)
					fail("line %ld: a write-back asked the face for %u", lineno, k.last_ctl);
				const uint32_t pad = k.ddr[(k.last_addr - k.ddr_phys) / 4 + PACK_RECORD_WORDS];
				if (pad != feeder_poison(k.last_addr, PACK_RECORD_WORDS))
					fail("line %ld: the pad after the record at 0x%08x is 0x%08x, not its poison", lineno, k.last_addr, pad);
				// The pack file, byte for byte.
				uint8_t file_bytes[PACK_BLOCK_BYTES], want_bytes[PACK_BLOCK_BYTES];
				if (pread(pk.fd, file_bytes, sizeof file_bytes, (off_t)lba * PACK_BLOCK_BYTES) != (ssize_t)sizeof file_bytes)
					fail("line %ld: reading block %x of the pack file", lineno, lba);
				for (int i = 0; i < PACK_BLOCK_WORDS; ++i)
					for (int j = 0; j < 4; ++j)
						want_bytes[4 * i + j] = (uint8_t)(words[i] >> (8 * j));
				if (memcmp(file_bytes, want_bytes, sizeof file_bytes) != 0)
					fail("line %ld: block %x in the pack file differs from what the CADR wrote", lineno, lba);
				else
					bytes_compared += sizeof file_bytes;
				// And the record reads back as the same 259 words: the
				// tables round-trip the header and the checkwords.
				uint32_t again[PACK_RECORD_WORDS];
				if (pack_record(&pk, lba, again, err, sizeof err) < 0)
					fail("line %ld: %s", lineno, err);
				else if (memcmp(again, words, sizeof words) != 0)
					fail("line %ld: block %x's record after the write-back is not what was written back", lineno, lba);
			} else {
				// A formatter or the vendor laid it: onto the pack, tables
				// and all.
				if (strcmp(why, "load") == 0) {
					++loads;
					// muir computed both checkwords for a load row: the
					// ECC here must agree.
					if (ecc_over_words(&words[256], 1) != words[257])
						fail("line %ld: header checkword of 0x%08x is 0x%08x here, 0x%08x in muir", lineno, words[256], ecc_over_words(&words[256], 1), words[257]);
					else if (ecc_over_words(words, PACK_BLOCK_WORDS) != words[258])
						fail("line %ld: data checkword of block %x is 0x%08x here, 0x%08x in muir", lineno, lba, ecc_over_words(words, PACK_BLOCK_WORDS), words[258]);
					else
						++ecc_checked;
					if (words[256] != pack_header_of(&pk.g, c, h, b))
						fail("line %ld: header_of(%u,%u,%u) is 0x%08x here, 0x%08x in muir", lineno, c, h, b, pack_header_of(&pk.g, c, h, b), words[256]);
				} else {
					++lays;
				}
				if (pack_writeback(&pk, lba, words, err, sizeof err) < 0)
					fail("line %ld: laying block %x: %s", lineno, lba, err);
			}
		} else if (strcmp(kind, "NEED") == 0) {
			const uint32_t lba = hex(strtok_r(NULL, " ", &save));
			const uint32_t c = hex(strtok_r(NULL, " ", &save));
			const uint32_t h = hex(strtok_r(NULL, " ", &save));
			const uint32_t b = hex(strtok_r(NULL, " ", &save));
			++needs;
			struct shadow *s = shadow_of(lba, 0);
			if (!s) {
				fail("line %ld: NEED %x, which no BLK row put on the pack", lineno, lba);
				continue;
			}
			if (feeder_serve(&f, c, h, b, s->slot, err, sizeof err) < 0) {
				fail("line %ld: serving %u/%u/%u: %s", lineno, c, h, b, err);
				continue;
			}
			check_addr(k.last_addr, "a fetch");
			if (k.last_ctl != PS_CTL_FETCH)
				fail("line %ld: a fetch asked the face for %u", lineno, k.last_ctl);
			if (!k.valid[s->slot])
				fail("line %ld: slot %u is not valid after the fetch", lineno, s->slot);
			if (k.tag[s->slot] != ps_tag(c, h, b))
				fail("line %ld: slot %u is tagged 0x%07x, wanting 0x%07x", lineno, s->slot, k.tag[s->slot], ps_tag(c, h, b));
			for (int i = 0; i < PACK_RECORD_WORDS; ++i) {
				if (k.store[s->slot][i] != s->words[i]) {
					fail("line %ld: block %x word %d in the store is 0x%08x, the pack carries 0x%08x", lineno, lba, i, k.store[s->slot][i], s->words[i]);
					break;
				}
				++words_compared;
			}
		} else if (strcmp(kind, "ATTACH") == 0) {
			present = 1;
			ps_drive(&ps, 1, (uint8_t)read_only, timed);
		} else if (strcmp(kind, "RO") == 0) {
			strtok_r(NULL, " ", &save);
			strtok_r(NULL, " ", &save);
			read_only = atoi(strtok_r(NULL, " ", &save));
			ps_drive(&ps, (uint8_t)present, (uint8_t)read_only, timed);
			const uint32_t want = (present ? 1u : 0u) | (read_only ? 1u << 8 : 0u) | (timed ? 1u << 16 : 0u);
			if (k.regs[PS_DRIVE] != want)
				fail("line %ld: DRIVE is 0x%x, wanting 0x%x", lineno, k.regs[PS_DRIVE], want);
		} else if (strcmp(kind, "TIMED") == 0) {
			strtok_r(NULL, " ", &save);
			strtok_r(NULL, " ", &save);
			timed = atoi(strtok_r(NULL, " ", &save));
			ps_drive(&ps, (uint8_t)present, (uint8_t)read_only, timed);
		}
		// CYC, MEMPAGE, MEMW, PAGE, LAY, INIT: the controller's business.
	}
	free(line);
	fclose(trace);

	// ---- the driver's handling of what the face can refuse -------------
	unsigned long refusals = 0;
	{
		uint32_t st;
		if (ps_fetch(&ps, feeder_fetch_addr(1) + 64, ps_tag(1, 2, 3), 1, &st, err, sizeof err) == 0)
			fail("an unaligned fetch was not refused");
		else if (!strstr(err, "align"))
			fail("an unaligned fetch was refused with '%s'", err);
		else
			++refusals;
		if (ps_fetch(&ps, feeder_fetch_addr(1), ps_tag(1, 2, 3), PS_SLOTS, &st, err, sizeof err) == 0)
			fail("a fetch into slot 24 was not refused");
		else if (!strstr(err, "slot"))
			fail("a fetch into slot 24 was refused with '%s'", err);
		else
			++refusals;
		if (ps_request(&ps, PS_CTL_FETCH | PS_CTL_WRITE, feeder_fetch_addr(1), 0, 1, &st, err, sizeof err) == 0)
			fail("two requests in one word were not refused");
		else
			++refusals;
		if (ps.refused_other != 3)
			fail("the driver counted %lu refusals it caused, wanting 3", ps.refused_other);
		// The channel walking: refused, retried, served.
		const unsigned long before = k.fetches;
		k.ch_active_left = 3;
		struct shadow *s = &shadows[0];
		uint32_t c, h, b;
		pack_chb(&pk.g, s->lba, &c, &h, &b);
		if (feeder_serve(&f, c, h, b, s->slot, err, sizeof err) < 0)
			fail("serving while the channel walked, then stopped: %s", err);
		if (k.fetches != before + 1)
			fail("the request refused for the channel was retried into %lu fetches", k.fetches - before);
		if (ps.refused_ch != 3)
			fail("the driver counted %lu refusals for the channel, wanting 3", ps.refused_ch);
		refusals += 3;
		// A channel that never stops: reported, not waited for for ever.
		k.ch_active_left = 1 << 30;
		if (feeder_serve(&f, c, h, b, s->slot, err, sizeof err) == 0)
			fail("a request the channel refused for ever was reported served");
		else if (!strstr(err, "channel"))
			fail("a channel that never stopped was reported as '%s'", err);
		k.ch_active_left = 0;
		// A write-back that moved nothing: seen by the poison, and the pack
		// left as it was.
		uint8_t before_bytes[PACK_BLOCK_BYTES], after_bytes[PACK_BLOCK_BYTES];
		if (pread(pk.fd, before_bytes, sizeof before_bytes, (off_t)s->lba * PACK_BLOCK_BYTES) != (ssize_t)sizeof before_bytes)
			fail("reading the pack before the dropped write-back");
		memcpy(k.store[s->slot], s->words, sizeof s->words);
		k.store[s->slot][5] ^= 0xFFFFFFFFu;
		k.valid[s->slot] = 1;
		k.drop_next_write = 1;
		if (feeder_writeback(&f, s->slot, err, sizeof err) == 0)
			fail("a write-back that moved nothing was reported done");
		else if (!strstr(err, "nothing"))
			fail("a write-back that moved nothing was reported as '%s'", err);
		if (pread(pk.fd, after_bytes, sizeof after_bytes, (off_t)s->lba * PACK_BLOCK_BYTES) != (ssize_t)sizeof after_bytes)
			fail("reading the pack after the dropped write-back");
		if (memcmp(before_bytes, after_bytes, sizeof before_bytes) != 0)
			fail("a write-back that moved nothing changed the pack");
		if (f.nothing_moved != 1)
			fail("nothing_moved is %lu", f.nothing_moved);
		// A port that answers SLVERR: the error bit, reported.
		if (ps_fetch(&ps, FEEDER_SPARE_BASE + FEEDER_SPARE_BYTES - 0x800u, ps_tag(1, 2, 3), 2, &st, err, sizeof err) == 0)
			fail("a fetch the port answered with an error was reported done");
		else if (!(st & PS_ST_ERROR))
			fail("the error bit was not read back after a refused burst");
		// The slot taken away.
		if (feeder_take(&f, s->slot, err, sizeof err) < 0)
			fail("take: %s", err);
		if (k.valid[s->slot])
			fail("slot %u is still valid after a take-away", s->slot);
	}

	pack_close(&pk);
	unlink(path);
	free(k.ddr);

	if (needs != want_needs)
		fail("%lu NEED rows served, the trace's header says %lu", needs, want_needs);
	if (writes != want_writes)
		fail("%lu BLK write rows written back, the trace's header says %lu", writes, want_writes);
	if (needs == 0 || writes == 0)
		fail("a trace with nothing to serve tests nothing");
	if (f.served != needs + 1)
		fail("the feeder counts %lu served, wanting %lu", f.served, needs + 1);
	if (f.written_back != writes)
		fail("the feeder counts %lu written back, wanting %lu", f.written_back, writes);
	// The face saw the trace's moves, the one retried after the channel,
	// the one it answered with an error, and the one write-back it dropped.
	if (k.fetches != needs + 2 || k.writes != writes + 1)
		fail("the face saw %lu fetches and %lu write-backs, wanting %lu and %lu", k.fetches, k.writes, needs + 2, writes + 1);
	if (ps.polls == 0)
		fail("the driver never polled a busy face");

	if (bad) {
		fprintf(stderr, "FAIL: %d mismatches\n", bad);
		return 1;
	}
	printf("ok: the pack feeder serves the reference trace's blocks and takes\n"
	       "    back what the CADR wrote\n"
	       "    %lu blocks needed and served, %lu words compared against the\n"
	       "      pack, every record 128-byte aligned in the spare region\n"
	       "    %lu blocks written back, %lu bytes of the pack file compared,\n"
	       "      header and checkwords round-tripped through the tables\n"
	       "    %lu load rows' checkwords agree with muir's Ecc; %lu laid\n"
	       "      sectors carried as laid\n"
	       "    %lu refusals seen and named, the channel's retried; a move that\n"
	       "      moved nothing seen by its poison; %lu polls of a busy face\n",
	       needs, words_compared, writes, bytes_compared, ecc_checked, lays, refusals, ps.polls);
	return 0;
}
