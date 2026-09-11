// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The readout program: the machine's own memories, printed.
//
//     cadr-readout                       the register table
//     cadr-readout --dump NAME [FILE]    a whole memory, a word a line
//     cadr-readout --word NAME:ADDR      one word
//     cadr-readout --list                what the window can reach
//     cadr-readout --leave-halted        do not start the machine again
//     cadr-readout --no-guard            skip the EMIO tally guard
//
// **WHAT IT IS FOR.**  The sixteen diagnostic registers and the three words
// beside them are what a console can see, and the machine's own memories are
// not among them.  The control store, the boot PROM, the A and M scratchpads,
// the pushdown buffer, the micro-stack, the dispatch memory and both levels
// of the map are inside `cadr_microcycle.sv`, and the readout window on page
// 0's words 10, 11 and 12 is the only way out of it.  This is the Linux side
// of that window and it does one thing: it reads and prints.
//
// **IT IS NOT A DEBUGGER AND IS NOT MEANT TO BECOME ONE.**  The debugger for
// this machine is CC over the debug cable, which reads the scratchpads by
// forcing a microinstruction into the instruction register --- MIT's own
// answer, and one that tests a piece of the CADR rather than adding a piece
// that is not the CADR.  This is the crude thing beside it: a way to read
// those memories that costs a write and three reads a word and needs nothing
// of the machine but that it stand still.
//
// **IT HALTS THE MACHINE AND THAT IS NOT A CONVENIENCE.**  The console's own
// documentation says to halt first, and a read taken while the datapath moves
// is torn: `docs/console.md` records a mid-run readout that reported six
// parity errors on a machine whose parity bits were all clean.  So this
// writes the clock control register with RUN clear, reads, and writes RUN
// back unless `--leave-halted` says not to.
//
// **THE ORDER IS THE ONE THE GP0 RULE FORCES.**  `cadr_guard` runs before
// anything on a GP port is touched: a read on `M_AXI_GP1` that nothing in the
// fabric answers hangs both Arm cores at one PC each, measured on the board,
// and no software guard can catch that afterwards.

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cadr/cadr_log.h"
#include "cadr/cadr_mem.h"
#include "cadr_image.h"
#include "readout.h"

// The memories, by the name a person types and the selector the fabric takes.
struct mem {
	const char *name;
	unsigned sel;
	unsigned depth;
	unsigned bits;
	const char *what;
};
static const struct mem kMems[] = {
	{ "imem",  IMG_SEL_IMEM, IMG_IMEM_WORDS, 48, "the control store" },
	{ "prom",  IMG_SEL_PROM, IMG_PROM_WORDS, 48, "the boot PROM" },
	{ "amem",  IMG_SEL_AMEM, IMG_AMEM_WORDS, 32, "the A memory" },
	{ "mmem",  IMG_SEL_MMEM, IMG_MMEM_WORDS, 32, "the M memory" },
	{ "pdl",   IMG_SEL_PDL,  IMG_PDL_WORDS,  32, "the pushdown buffer" },
	{ "spc",   IMG_SEL_SPC,  IMG_SPC_WORDS,  21, "the micro-stack" },
	{ "dmem",  IMG_SEL_DMEM, IMG_DMEM_WORDS, 17, "the dispatch memory" },
	{ "map1",  IMG_SEL_MAP1, IMG_L1_WORDS,    5, "the level-1 map" },
	{ "map2",  IMG_SEL_MAP2, IMG_L2_WORDS,   24, "the level-2 map" },
	{ "opcs",  IMG_SEL_OPCS, IMG_OPCS,       14, "the OPC shift register" },
	{ "regs",  IMG_SEL_REGS, 21,             48, "the register table below" },
};
static const unsigned kMemCount = sizeof(kMems) / sizeof(kMems[0]);

// The register table's entries, in the order `cadr_microcycle.sv` numbers
// them.  A name a person would recognise, and the machine's own.
static const char *const kRegNames[21] = {
	"PC", "LPC", "IR", "IWR", "L", "Q", "VMA", "MD", "ST", "LC",
	"WADR", "PDL-POINTER", "PDL-INDEX", "SPCPTR", "RETA", "DC", "LVMO",
	"MD-HELD", "PHYS", "SPEED", "FLAGS"
};

// The flag word, bit by bit, in `ro_flags`'s own order.
static const char *const kFlagNames[33] = {
	"DESTD", "DESTMD", "PWIDX", "PDLWRITED", "INOP", "IWRITED", "NEWLC",
	"SINTR", "NEXT-INSTRD", "LC-BYTE-MODE", "INT-ENABLE", "SEQUENCE-BREAK",
	"PROG-UNIBUS-RESET", "TRAP", "PROMDISABLE", "SRUN", "STATSTOP",
	"HALTED", "MEMSTART", "MBUSY", "RDCYC", "WRCYC", "MBUSY-SYNC",
	"RD-IN-PROGRESS", "WMAPD", "SPUSHD", "DESTSPCD", "IMODD", "VMAOK",
	"MD-PENDING", "RUN", "ERRSTOP", "STATHENB"
};

struct mem_face {
	volatile uint32_t *reg;
};

static uint32_t mem_read(struct readout *r, unsigned word)
{
	struct mem_face *f = r->ctx;
	return f->reg[word];
}

static void mem_write(struct readout *r, unsigned word, uint32_t v)
{
	struct mem_face *f = r->ctx;
	f->reg[word] = v;
}

static const struct mem *by_name(const char *name)
{
	for (unsigned i = 0; i < kMemCount; ++i)
		if (!strcmp(name, kMems[i].name))
			return &kMems[i];
	return NULL;
}

static void list(void)
{
	say("the window reaches these, `--dump NAME` or `--word NAME:ADDR`:");
	for (unsigned i = 0; i < kMemCount; ++i)
		say("  %-6s %5u words of %2u bits   %s", kMems[i].name,
		    kMems[i].depth, kMems[i].bits, kMems[i].what);
	say("a word is read by writing the address to page 0's word 10 and");
	say("reading words 10, 11 and 12; word 10 comes back as the address the");
	say("word beside it was read at, and this program refuses any word whose");
	say("echo is not what it asked for.");
}

static void usage(void)
{
	fprintf(stderr,
		"usage: cadr-readout [--dump NAME [FILE]] [--word NAME:ADDR] [--list]\n"
		"                    [--leave-halted] [--no-guard]\n");
	exit(2);
}

// The register table, printed.  Octal as well as hex, because MIT's own
// listings are octal and a PC compared against `ucadr.sym` has to be.
static int print_registers(struct readout *r)
{
	uint64_t v[21];
	for (unsigned i = 0; i < 21; ++i)
		if (ro_word(r, IMG_SEL_REGS, i, &v[i]) != 0) {
			say("the readout gave back a word for an address that was "
			    "not the one asked for: the window is not answering");
			return -1;
		}
	for (unsigned i = 0; i < 21; ++i) {
		if (i == IMG_RG_FLAGS)
			continue;
		say("  %-12s 0x%012llx  0o%llo", kRegNames[i],
		    (unsigned long long)v[i], (unsigned long long)v[i]);
	}
	// The flags, named, and only the ones that are up: thirty-three names
	// with thirty of them clear is a wall nobody reads.
	char line[512];
	size_t at = 0;
	line[0] = '\0';
	for (unsigned b = 0; b < 33; ++b) {
		if (!((v[IMG_RG_FLAGS] >> b) & 1u))
			continue;
		const int n = snprintf(line + at, sizeof line - at, "%s%s",
				       at ? " " : "", kFlagNames[b]);
		if (n < 0 || (size_t)n >= sizeof line - at)
			break;
		at += (size_t)n;
	}
	say("  %-12s 0x%012llx  %s", "FLAGS",
	    (unsigned long long)v[IMG_RG_FLAGS], at ? line : "(none up)");
	return 0;
}

int main(int argc, char **argv)
{
	cadr_log_init("cadr-readout: ", NULL);

	const char *dump = NULL, *dump_file = NULL, *word = NULL;
	int leave_halted = 0, guard = 1;

	for (int i = 1; i < argc; ++i) {
		const char *a = argv[i];
		if (!strcmp(a, "--list")) {
			list();
			return 0;
		} else if (!strcmp(a, "--dump") && i + 1 < argc) {
			dump = argv[++i];
			if (i + 1 < argc && argv[i + 1][0] != '-')
				dump_file = argv[++i];
		} else if (!strcmp(a, "--word") && i + 1 < argc) {
			word = argv[++i];
		} else if (!strcmp(a, "--leave-halted")) {
			leave_halted = 1;
		} else if (!strcmp(a, "--no-guard")) {
			guard = 0;
		} else {
			usage();
		}
	}

	int fd = cadr_open_mem();
	if (fd < 0)
		return 1;
	// **BEFORE ANYTHING ON GP1.**  See the header, and `cadr_mem.h`'s.
	if (guard && cadr_guard(fd, "M_AXI_GP1") != 0)
		return 1;

	struct mem_face face;
	face.reg = cadr_map(fd, RO_REG_BASE, RO_REG_BYTES, "the console's window");
	if (!face.reg)
		return 1;

	struct readout r;
	memset(&r, 0, sizeof r);
	r.read = mem_read;
	r.write = mem_write;
	r.ctx = &face;

	uint32_t ident = 0;
	if (ro_ident_ok(&r, &ident) != 0) {
		if (ident == CADR_IDENT_NONE)
			say("no console at 0x%08x: word 0 reads \"NONE\", which is the "
			    "default slave --- this bitstream has no console in it",
			    RO_REG_BASE);
		else if (ident == RO_UNMAPPED)
			say("no console at 0x%08x: word 0 reads 0x%08x, the window's "
			    "own UNMAPPED", RO_REG_BASE, ident);
		else
			say("no console at 0x%08x: word 0 reads 0x%08x, wanting "
			    "\"CONS\" 0x%08x", RO_REG_BASE, ident, RO_IDENT_WORD);
		return 1;
	}

	// **THE READOUT HAS TO BE IN THE BITSTREAM, AND THE WINDOW SAYS SO
	// WITHOUT BEING ASKED.**  A fabric older than these three words answers
	// UNMAPPED at all of them, and UNMAPPED is a value that means nothing:
	// it must not be read as an address or as a word.
	if (r.read(&r, RO_ADDR) == RO_UNMAPPED) {
		say("this bitstream's console has no readout: page 0's word 10 "
		    "reads 0x%08x, cadr_console.sv's own UNMAPPED", RO_UNMAPPED);
		return 1;
	}

	const int was_running = !ro_is_halted(&r);
	if (was_running) {
		say("the machine is running; halting it, as the console's own "
		    "documentation says to.  A read taken while the datapath "
		    "moves is torn.");
		ro_halt(&r);
	}
	if (!ro_is_halted(&r)) {
		say("the machine did not stop: it is still retiring microcycles "
		    "after a write of zero to the clock control register");
		return 1;
	}
	say("halted at %llu microcycles, %llu ticks",
	    (unsigned long long)ro_cycles(&r), (unsigned long long)ro_ticks(&r));

	int rc = 0;
	if (word) {
		char name[16];
		unsigned addr = 0;
		if (sscanf(word, "%15[^:]:%u", name, &addr) != 2)
			usage();
		const struct mem *m = by_name(name);
		if (!m) {
			say("no memory called %s; --list says what there is", name);
			rc = 1;
		} else if (addr >= m->depth) {
			say("%s has %u words and you asked for %u", m->name,
			    m->depth, addr);
			rc = 1;
		} else {
			uint64_t w = 0;
			if (ro_word(&r, m->sel, addr, &w) != 0) {
				say("the echo was not the address asked for");
				rc = 1;
			} else {
				say("%s[%u] = 0x%012llx  0o%llo", m->name, addr,
				    (unsigned long long)w, (unsigned long long)w);
			}
		}
	} else if (dump) {
		const struct mem *m = by_name(dump);
		if (!m) {
			say("no memory called %s; --list says what there is", dump);
			rc = 1;
		} else {
			FILE *out = stdout;
			if (dump_file) {
				out = fopen(dump_file, "w");
				if (!out) {
					say("%s: %s", dump_file, strerror(errno));
					return 1;
				}
			}
			// A word a line, the address first, hex then octal: a
			// format `diff` can take against another dump, which is
			// what a person with two boards or a board and muir
			// actually does with this.
			for (unsigned a = 0; a < m->depth && rc == 0; ++a) {
				uint64_t w = 0;
				if (ro_word(&r, m->sel, a, &w) != 0) {
					say("%s[%u]: the echo was not the address "
					    "asked for", m->name, a);
					rc = 1;
					break;
				}
				fprintf(out, "%-6u 0x%012llx 0o%llo\n", a,
					(unsigned long long)w,
					(unsigned long long)w);
			}
			if (out != stdout)
				fclose(out);
			if (rc == 0)
				say("%s: %u words of %s", m->name, m->depth, m->what);
		}
	} else {
		say("the machine's own registers, which the diagnostic bus has "
		    "no register for:");
		rc = print_registers(&r) == 0 ? 0 : 1;
	}

	say("%lu reads and %lu writes over the console's window, %lu refused "
	    "for an echo that was not the address asked for",
	    r.reads, r.writes, r.stale);

	if (was_running && !leave_halted) {
		ro_start(&r);
		say("the machine is running again");
	} else if (leave_halted) {
		say("the machine is left halted, as asked");
	}
	return rc;
}
