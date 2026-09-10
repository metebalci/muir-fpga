// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// cadr-pack-feeder: the program on Linux that serves the CADR's disk from
// the pack file on the card.
//
// WHAT IT IS.  On the board the disk's pack is a file --- `pack.img` on the
// card's FAT partition, muir's format, 1,024 bytes a block --- and the
// drive is this program: the fabric's disk controller holds a store of 24
// blocks (`rtl/cadr_disk_controller.sv`) that Linux fills, and its pack side
// (`rtl/cadr_disk_pack.sv`) moves a block between DDR and that store over
// `S_AXI_HP2` when Linux writes the block's address into a register on
// `M_AXI_GP0`.  This program puts a block's 259 words --- the block, its
// header, header checkword and data checkword --- into the spare part of
// the CADR's reserved region, asks for the fetch, and takes back over the
// same path a block the CADR wrote, putting it on the pack file so the pack
// persists.  `pack_file.c` is the pack in muir's terms, `pack_side.c` the
// register face, `pack_feeder.c` the moves; `feeder_test.c` holds all three
// to the reference trace on the build host, with a model of the face in the
// fabric's place.
//
// HOW IT RUNS.  `S80cadr-pack-feeder` mounts the card at /mnt/card and
// starts this at boot with `--pack /mnt/card/pack.img --log /dev/console`.
// It maps the register window and the spare region through /dev/mem: the
// reserved region is `no-map`, so mmap works there and read()/write() do
// not (docs/boot.md).  It checks the face is there (register 7 reads "PACK"),
// opens the pack, and says what it found.  With no pack it says so once and
// idles; the CADR then sees a controller with no drive.
//
// WHAT IT CANNOT DO YET, AND SAYS SO.  The register face at HEAD gives Linux
// no way to learn WHICH block the CADR asked for: `store_miss` in CTL is one
// sticky bit, the disk address the walk missed on is not readable over GP0,
// and no register says which slot a transfer wrote (`rtl/cadr_disk_pack.sv`,
// the status word; `rtl/cadr_disk_controller.sv` at `store_miss`: "Fetching
// on demand ... is not built").  So this program cannot serve on demand
// and does not pretend to: it leaves the drive absent (DRIVE = 0), so the
// CADR sees no drive rather than a drive whose every block is missing, and
// watches the status word.  The moves themselves are complete and checked;
// the request path is the RTL's next slice.  `--selftest` runs the moves on
// the board without a request path: block 0 of the pack fetched into slot 0,
// written back to a poisoned area, and the 259 words compared, the pad
// untouched.  That is a round trip through the store and cannot see a fault
// the two directions share; it proves the ports move a block on silicon and
// nothing subtler.
//
// WHAT IT PRINTS.  One line per event while there are few, then a summary
// line at most once a minute: blocks served, written back, taken away,
// refusals for the channel, failures.  Every failure line says which block,
// which slot, which address and what the face answered.
//
//     cadr-pack-feeder [--pack PATH] [--regs ADDR] [--log PATH]
//                      [--selftest] [--once]

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <setjmp.h>
#include <stdarg.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "pack_feeder.h"
#include "pack_file.h"
#include "pack_side.h"

static FILE *logf;

static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("cadr-pack-feeder: ", logf);
	vfprintf(logf, fmt, ap);
	fputc('\n', logf);
	va_end(ap);
	fflush(logf);
}

// ---- the face over /dev/mem -------------------------------------------
struct mmio {
	volatile uint32_t *regs;
};

static uint32_t mmio_read(struct pack_side *ps, unsigned reg)
{
	struct mmio *m = ps->ctx;
	return m->regs[reg];
}
static void mmio_write(struct pack_side *ps, unsigned reg, uint32_t v)
{
	struct mmio *m = ps->ctx;
	m->regs[reg] = v;
	__sync_synchronize();
}
static void mmio_pause(struct pack_side *ps)
{
	(void)ps;
	usleep(100);
}

// A bus error is what a read of an address nothing answers on GP0 becomes:
// DECERR on the interconnect, an external abort on the A9, SIGBUS here.
static sigjmp_buf bus_jump;
static void on_sigbus(int sig)
{
	(void)sig;
	siglongjmp(bus_jump, 1);
}

static void *map(int fd, uint32_t phys, size_t bytes, const char *what)
{
	void *p = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, (off_t)phys);
	if (p == MAP_FAILED) {
		say("mapping %s at 0x%08x: %s", what, phys, strerror(errno));
		return NULL;
	}
	return p;
}

// The first read of the face, under a SIGBUS guard: its own function so
// that nothing sigsetjmp could clobber lives in main's frame.
static int probe_face(struct pack_side *ps, uint32_t regs_phys)
{
	signal(SIGBUS, on_sigbus);
	if (sigsetjmp(bus_jump, 1)) {
		signal(SIGBUS, SIG_DFL);
		say("reading 0x%08x raised a bus error: nothing answers on M_AXI_GP0 there; "
		    "is the fabric the memory-on bitstream with the disk's pack side?", regs_phys);
		return -1;
	}
	uint32_t ident;
	const int ok = ps_ident_ok(ps, &ident);
	signal(SIGBUS, SIG_DFL);
	if (!ok) {
		say("no pack side at 0x%08x: register 7 reads 0x%08x, wanting 0x%08x (\"PACK\"); "
		    "is the fabric the memory-on bitstream with the disk's pack side?",
		    regs_phys, ident, PS_IDENT_WORD);
		return -1;
	}
	say("the pack side answers at 0x%08x (IDENT \"PACK\"); status 0x%02x", regs_phys, ps->read(ps, PS_CTL));
	return 0;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: cadr-pack-feeder [--pack PATH] [--regs ADDR] [--log PATH] [--selftest] [--once]\n"
		"  --pack PATH   the pack file (default /mnt/card/pack.img)\n"
		"  --regs ADDR   the pack side's registers (default 0x40000000)\n"
		"  --log PATH    where to write (default stdout)\n"
		"  --selftest    fetch block 0 into slot 0, write it back, compare, exit\n"
		"  --once        do the checks and exit instead of staying\n");
}

static int selftest(struct feeder *f, struct pack *pk)
{
	char err[256];
	uint32_t want[PACK_RECORD_WORDS];
	if (pack_record(pk, 0, want, err, sizeof err) < 0) {
		say("selftest: %s", err);
		return 1;
	}
	if (feeder_serve(f, 0, 0, 0, 0, err, sizeof err) < 0) {
		say("selftest: FAIL: %s", err);
		return 1;
	}
	if (feeder_writeback(f, 0, err, sizeof err) < 0) {
		say("selftest: FAIL: %s", err);
		return 1;
	}
	// What came back, read out of the write-back area.
	const uint32_t wb = feeder_wb_addr(0);
	volatile uint32_t *rec = f->mem + (wb - f->mem_phys) / 4;
	int differ = 0;
	for (int i = 0; i < PACK_RECORD_WORDS; ++i)
		if (rec[i] != want[i]) {
			if (differ < 4)
				say("selftest: word %d came back 0x%08x, the record holds 0x%08x", i, rec[i], want[i]);
			++differ;
		}
	if (feeder_take(f, 0, err, sizeof err) < 0)
		say("selftest: %s", err);
	if (differ) {
		say("selftest: FAIL: %d of %d words differ after the round trip through the store", differ, PACK_RECORD_WORDS);
		return 1;
	}
	say("selftest: PASS: block 0 fetched over HP2 from 0x%08x into slot 0, written back to 0x%08x, "
	    "all %d words equal, the pad untouched, the slot taken away",
	    feeder_fetch_addr(0), wb, PACK_RECORD_WORDS);
	return 0;
}

int main(int argc, char **argv)
{
	const char *pack_path = "/mnt/card/pack.img";
	const char *log_path = NULL;
	uint32_t regs_phys = PS_REG_BASE;
	int do_selftest = 0, once = 0;
	static const struct option opts[] = {
		{ "pack", required_argument, NULL, 'p' },
		{ "regs", required_argument, NULL, 'r' },
		{ "log", required_argument, NULL, 'l' },
		{ "selftest", no_argument, NULL, 's' },
		{ "once", no_argument, NULL, 'o' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	int c;
	while ((c = getopt_long(argc, argv, "p:r:l:soh", opts, NULL)) != -1) {
		switch (c) {
		case 'p': pack_path = optarg; break;
		case 'r': regs_phys = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'l': log_path = optarg; break;
		case 's': do_selftest = 1; break;
		case 'o': once = 1; break;
		default: usage(); return 2;
		}
	}
	logf = stdout;
	if (log_path) {
		logf = fopen(log_path, "a");
		if (!logf) {
			fprintf(stderr, "cadr-pack-feeder: %s: %s\n", log_path, strerror(errno));
			return 2;
		}
	}
	setvbuf(logf, NULL, _IOLBF, 0);

	// The two mappings.  O_SYNC gives an uncached mapping of both: the
	// registers must be, and the records the fabric reads and writes must
	// not sit in a cache the HP port cannot see.
	int mem = open("/dev/mem", O_RDWR | O_SYNC);
	if (mem < 0) {
		say("/dev/mem: %s", strerror(errno));
		return 1;
	}
	struct mmio m;
	m.regs = map(mem, regs_phys, 4096, "the pack side's registers");
	if (!m.regs)
		return 1;
	volatile uint32_t *spare = map(mem, FEEDER_SPARE_BASE, FEEDER_MAP_BYTES, "the spare part of the CADR's region");
	if (!spare)
		return 1;

	struct pack_side ps;
	ps_init(&ps);
	ps.read = mmio_read;
	ps.write = mmio_write;
	ps.pause = mmio_pause;
	ps.ctx = &m;

	// The face is there, or nothing is.
	if (probe_face(&ps, regs_phys) < 0)
		return 1;

	// The drive is absent until a pack is open --- and, today, after it:
	// see the header.
	ps_drive(&ps, 0, 0, 0);

	struct pack pk;
	char err[256];
	if (pack_open(&pk, pack_path, 1, err, sizeof err) < 0) {
		say("no pack: %s", err);
		say("the CADR sees a controller with no drive");
		if (once)
			return 0;
		for (;;)
			sleep(3600);
	}
	say("pack %s: %u cylinders, %u heads, %u blocks a track, %u blocks",
	    pack_path, pk.g.cylinders, pk.g.heads, pk.g.blocks_per_track, pk.blocks);
	{
		uint32_t rec[PACK_RECORD_WORDS];
		if (pack_record(&pk, 0, rec, err, sizeof err) == 0)
			say("block 0 word 0 is 0x%08x%s; header 0x%08x", rec[0],
			    rec[0] == 0x4C42414Cu ? " (LABL: a labelled pack)" : "", rec[256]);
	}

	struct feeder f;
	if (feeder_init(&f, &pk, &ps, spare, FEEDER_SPARE_BASE, FEEDER_MAP_BYTES, logf) < 0) {
		say("the mapped region does not cover the records");
		return 1;
	}
	say("records at 0x%08x (fetches) and 0x%08x (write-backs), %u slots 0x%x apart",
	    feeder_fetch_addr(0), feeder_wb_addr(0), PS_SLOTS, FEEDER_RECORD_STRIDE);

	if (do_selftest)
		return selftest(&f, &pk);

	say("the register face has no way to say which block the CADR asked for, nor which slot "
	    "a transfer wrote (rtl/cadr_disk_pack.sv: CTL reads back one sticky store_miss bit); "
	    "nothing can be served on demand yet");
	say("the drive is left absent (DRIVE = 0): the CADR sees no drive rather than a drive "
	    "whose every block is missing");
	if (once)
		return 0;

	// Watch the face.  Nothing here can move a block until the request path
	// exists; what can be seen is the status word and the channel.
	uint32_t last = ps.read(&ps, PS_CTL);
	time_t last_said = time(NULL);
	unsigned long changes = 0, misses = 0, walks = 0;
	for (;;) {
		sleep(1);
		const uint32_t st = ps.read(&ps, PS_CTL);
		if (st != last) {
			++changes;
			if ((st & PS_ST_STORE_MISS) && !(last & PS_ST_STORE_MISS))
				++misses;
			if ((st & PS_ST_CH_ACTIVE) && !(last & PS_ST_CH_ACTIVE))
				++walks;
			last = st;
		}
		const time_t now = time(NULL);
		if (changes && now - last_said >= 60) {
			say("status 0x%02x; %lu changes, %lu store_miss risings, %lu walks seen; "
			    "%lu served, %lu written back, %lu failures",
			    st, changes, misses, walks, f.served, f.written_back, f.failures);
			last_said = now;
		}
	}
}
