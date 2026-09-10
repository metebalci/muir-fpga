// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// cadr-disk-pack: the program on Linux that serves the CADR's disk from
// the pack file on the card.
//
// WHAT IT IS.  On the board the disk's pack is a file --- `pack.img` on the
// card's FAT partition, muir's format, 1,024 bytes a block --- and the
// drive is this program: the fabric's disk controller holds a store of 24
// blocks (`rtl/cadr_disk_controller.sv`) that Linux fills, and its pack side
// (`rtl/cadr_disk_pack.sv`) moves a block between DDR and that store over
// `S_AXI_HP2` when Linux writes the block's address into a register on
// `M_AXI_GP0`.  The store is a cache this program keeps: the controller
// posts the disk address of a block it lacks in REQ and waits, this program
// puts the block's 259 words --- the block, its header, header checkword
// and data checkword --- into the spare part of the CADR's reserved region
// and asks the face to fetch them into a slot of its choosing, and the
// walk goes on as if the block had been there.  A slot a transfer wrote is
// marked DIRTY and this program takes it back over the same path and puts
// it on the pack file, so the pack persists.  `pack_file.c` is the pack in muir's
// terms, `pack_side.c` the register face, `pack_feeder.c` the cache and
// the moves; `feeder_test.c` holds all three, on the build host, to a
// modelled controller that asks.
//
// HOW IT RUNS.  `S80cadr-disk-pack` mounts the card at /mnt/card and
// starts this at boot with `--pack /mnt/card/pack.img --log /dev/console`.
// In order:
//
//   1. THE GUARD.  A read on M_AXI_GP0 that nothing in the fabric answers
//      hangs both Arm cores, and no software guard can catch it afterwards
//      (CLAUDE.md; measured on the board).  The one thing a program can
//      read first is the EMIO tally at 0xE000A068/6C, which carries marker
//      bits --- `(w & 0x80008000) == 0x00008000` --- only on a bitstream
//      with the processing system in it, and reads all ones or zero
//      otherwise.  Without the markers this program stops before its first
//      GP0 access and says why.  `--no-guard` is for a board somebody knows.
//   2. IDENT.  Register 7 reads "PACK" for the pack side; "NONE" is the
//      proving boards' default slave (`rtl/cadr_gp0_default.sv`), a board
//      with GP0 and no disk.  Either is a reason to stop and say so.
//   3. THE PACK: `pack.img`, the only disk file on the card.  Its headers and
//      checkwords are muir's `Unit`'s: the format's own for a fresh pack,
//      what a transfer or a Write All lays for the run, and forgotten at
//      exit (`pack_file.h`; a sidecar that persisted them was built and
//      dropped by Mete on 10 Sep).
//   4. THE DRIVE COMES PRESENT: every slot of the store taken away (what it
//      held before this program is unknown to it), DRIVE written with the
//      unit the pack is on (`--unit`, 0 by default), its read-only switch
//      (`--read-only`) and whether its time is charged (`--timed`).
//   5. THE LOOP: REQ and DIRTY polled, a request served or denied, dirty
//      slots written back, until SIGTERM or SIGINT (the init script's
//      stop), on which every dirty slot is written back, the drive is taken
//      absent, and it says so.
//
// THE POLLING RATE AND THE LATENCY BUDGET.  `--poll-us`, 250 by default.
// What the controller gives this program to answer in is the time the
// walk would spend anyway: at a START, with the drive's time charged, the
// seek (5.94 ms settle + 60 us a cylinder; nothing for none) and the
// rotational wait (0 to 16.67 ms), and for each further block of a chained
// list the sector's own 968 us, since the next block is asked for as the
// current one begins to move (`rtl/cadr_disk_controller.sv`, "prefetch").
// A poll a quarter of a sector apart keeps the worst poll latency inside
// the smallest of those budgets; what the answer then costs is a 1 KB read
// of the pack file (from the page cache after the first touch; a cold read
// off the card is milliseconds and is the part no rate here can hide), 259
// uncached word writes into DDR and a fetch of some 300 ticks, 1.5 us.
// With the drive UNTIMED --- the default, because it is muir's default and
// every count this project quotes was measured with it off --- the walk
// asks at the START and the budget is nil: every first block of a transfer
// waits the poll latency plus the answer, and a chained block's budget is
// the previous block's 256 bus cycles, tens of microseconds, so it waits
// most of a poll too.  WHAT HAPPENS WHEN THE BUDGET IS MISSED IS NOTHING
// WRONG: the transfer stands with BUSY up and not-active down until the
// block lands, which is `DISK-WAIT`'s own loop, and `tb/cadr_disk_pack_tb.cpp`
// holds that a Linux four million ticks late loses no word.  The cost of
// polling at 250 us is some four thousand wakeups a second and three
// uncached reads each, expected to be a few percent of one A9 core and to
// be measured on the board rather than asserted here.
//
// THE INTERRUPT is in place behind `--irq PATH` and not required: PATH is a
// UIO device on GIC interrupt 61 (`IRQ_F2P` bit 0, device tree
// `interrupts = <0 29 4>`), IRQEN is set for the request and dirty events,
// and the loop sleeps in poll(2) on it with the polling interval as the
// timeout, so a missed interrupt still gets served.  What a later
// interrupt path needs and this slice does not build: a node in the
// board's tree --- `compatible = "generic-uio"; reg = <0x40000000 0x1000>;
// interrupts = <0 29 4>;` --- `CONFIG_UIO_PDRV_GENIRQ` in the kernel and
// `uio_pdrv_genirq.of_id=generic-uio` on its command line; then
// `/dev/uio0` reads four bytes per interrupt and takes a 1 written to
// re-enable.  Nothing in the tree or the kernel is changed here.
//
// WHAT IT PRINTS, low rate on purpose: one line per state change --- the
// guard, the face, the pack and its sidecar, the drive coming present, the
// first three requests served, every block denied named once --- and a
// summary line at most once a minute while the counts move.  Every failure
// line says which block, which slot, which address and what the face
// answered, and a failure repeating is said once a minute.
//
//     cadr-disk-pack [--pack PATH] [--regs ADDR] [--log PATH] [--unit N]
//                      [--timed] [--read-only] [--poll-us N] [--irq PATH]
//                      [--no-guard] [--selftest] [--once]

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
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

// The EMIO tally, the guard before any GP0 access.
#define GPIO_BASE     0xE000A000u
#define GPIO_DATA2_RO 0x68u
#define GPIO_DATA3_RO 0x6Cu
#define TALLY_MASK    0x80008000u
#define TALLY_MARK    0x00008000u
// The proving boards' default slave.
#define IDENT_NONE    0x4E4F4E45u

static FILE *logf;
static volatile sig_atomic_t stopping;
static void on_stop(int sig)
{
	(void)sig;
	stopping = 1;
}

static void say(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void say(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fputs("cadr-disk-pack: ", logf);
	vfprintf(logf, fmt, ap);
	fputc('\n', logf);
	va_end(ap);
	fflush(logf);
}

// ---- the face over /dev/mem -------------------------------------------
struct mmio {
	volatile uint32_t *regs;
	unsigned poll_us;
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
// A move is some 300 to 650 ticks, 1.5 to 3.3 us; a pause between status
// reads shorter than a register read itself buys nothing, and 20 us keeps
// a fetch to a handful of polls.
static void mmio_pause(struct pack_side *ps)
{
	(void)ps;
	usleep(20);
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

// The guard: the tally's marker bits, read before anything on GP0.
static int guard(int mem)
{
	volatile uint32_t *gpio = map(mem, GPIO_BASE, 4096, "the GPIO block");
	if (!gpio)
		return -1;
	const uint32_t w2 = gpio[GPIO_DATA2_RO / 4], w3 = gpio[GPIO_DATA3_RO / 4];
	munmap((void *)gpio, 4096);
	if ((w2 & TALLY_MASK) == TALLY_MARK && (w3 & TALLY_MASK) == TALLY_MARK) {
		say("the EMIO tally reads 0x%08x 0x%08x: a fabric with the processing system in it; M_AXI_GP0 may be read", w2, w3);
		return 0;
	}
	if (w2 == 0 && w3 == 0)
		say("the EMIO tally reads zero twice: either the GPIO block's clock is gated (APER_CLK_CTRL bit 22) or there is no instrument; "
		    "not touching M_AXI_GP0, which would hang the processor on a bitstream without the processing system");
	else
		say("the EMIO tally reads 0x%08x 0x%08x, not the marker bits of a bitstream with the processing system in it; "
		    "not touching M_AXI_GP0, which would hang the processor (--no-guard overrides)", w2, w3);
	return -1;
}

static int probe_face(struct pack_side *ps, uint32_t regs_phys)
{
	uint32_t ident;
	if (ps_ident_ok(ps, &ident)) {
		say("the pack side answers at 0x%08x (IDENT \"PACK\"); status 0x%02x", regs_phys, ps->read(ps, PS_CTL));
		return 0;
	}
	if (ident == IDENT_NONE)
		say("no pack side at 0x%08x: register 7 reads \"NONE\", the proving boards' default slave; a board with M_AXI_GP0 and no disk", regs_phys);
	else
		say("no pack side at 0x%08x: register 7 reads 0x%08x, wanting 0x%08x (\"PACK\"); "
		    "is the fabric the memory-on bitstream with the disk's pack side?", regs_phys, ident, PS_IDENT_WORD);
	return -1;
}

static void usage(void)
{
	fprintf(stderr,
		"usage: cadr-disk-pack [options]\n"
		"  --pack PATH     the pack file (default /mnt/card/pack.img)\n"
		"  --regs ADDR     the pack side's registers (default 0x40000000)\n"
		"  --log PATH      where to write (default stdout)\n"
		"  --unit N        the unit the pack is on, 0..7 (default 0)\n"
		"  --timed         charge the drive's own seek and rotational times (default: untimed, muir's default)\n"
		"  --read-only     open the pack read-only and set the drive's read-only switch\n"
		"  --poll-us N     how often REQ and DIRTY are polled (default 250)\n"
		"  --irq PATH      sleep on this UIO device instead of only polling (see the header)\n"

		"  --no-guard      touch M_AXI_GP0 without checking the EMIO tally first\n"
		"  --selftest      fetch block 0 into slot 0, write it back, compare, exit\n"
		"  --once          do the checks, bring the drive present, and exit\n");
}

static int selftest(struct feeder *f, struct pack *pk, unsigned unit)
{
	char err[256];
	uint32_t want[PACK_RECORD_WORDS];
	if (pack_record(pk, 0, want, err, sizeof err) < 0) {
		say("selftest: %s", err);
		return 1;
	}
	if (feeder_serve(f, unit, 0, 0, 0, 0, err, sizeof err) != 0) {
		say("selftest: FAIL: %s", err);
		return 1;
	}
	if (feeder_writeback(f, 0, err, sizeof err) != 0) {
		say("selftest: FAIL: %s", err);
		return 1;
	}
	const uint32_t wb = feeder_wb_addr(0);
	volatile uint32_t *rec = f->mem + (wb - f->mem_phys) / 4;
	int differ = 0;
	for (int i = 0; i < PACK_RECORD_WORDS; ++i)
		if (rec[i] != want[i]) {
			if (differ < 4)
				say("selftest: word %d came back 0x%08x, the record holds 0x%08x", i, rec[i], want[i]);
			++differ;
		}
	if (feeder_take(f, 0, err, sizeof err) != 0)
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
	const char *irq_path = NULL;
	uint32_t regs_phys = PS_REG_BASE;
	unsigned unit = 0, poll_us = 250;
	int do_selftest = 0, once = 0, timed = 0, read_only = 0, no_guard = 0;
	static const struct option opts[] = {
		{ "pack", required_argument, NULL, 'p' },
		{ "regs", required_argument, NULL, 'r' },
		{ "log", required_argument, NULL, 'l' },
		{ "unit", required_argument, NULL, 'u' },
		{ "timed", no_argument, NULL, 't' },
		{ "read-only", no_argument, NULL, 'R' },
		{ "poll-us", required_argument, NULL, 'P' },
		{ "irq", required_argument, NULL, 'i' },
		{ "no-guard", no_argument, NULL, 'G' },
		{ "selftest", no_argument, NULL, 's' },
		{ "once", no_argument, NULL, 'o' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 }
	};
	int c;
	while ((c = getopt_long(argc, argv, "p:r:l:u:tRP:i:Gsoh", opts, NULL)) != -1) {
		switch (c) {
		case 'p': pack_path = optarg; break;
		case 'r': regs_phys = (uint32_t)strtoul(optarg, NULL, 0); break;
		case 'l': log_path = optarg; break;
		case 'u': unit = (unsigned)strtoul(optarg, NULL, 0); break;
		case 't': timed = 1; break;
		case 'R': read_only = 1; break;
		case 'P': poll_us = (unsigned)strtoul(optarg, NULL, 0); break;
		case 'i': irq_path = optarg; break;
		case 'G': no_guard = 1; break;
		case 's': do_selftest = 1; break;
		case 'o': once = 1; break;
		default: usage(); return 2;
		}
	}
	if (unit > 7) {
		fprintf(stderr, "cadr-disk-pack: --unit %u: a unit is 0 to 7\n", unit);
		return 2;
	}
	logf = stdout;
	if (log_path) {
		logf = fopen(log_path, "a");
		if (!logf) {
			fprintf(stderr, "cadr-disk-pack: %s: %s\n", log_path, strerror(errno));
			return 2;
		}
	}
	setvbuf(logf, NULL, _IOLBF, 0);

	// The mappings.  O_SYNC gives an uncached mapping of all of them: the
	// registers must be, and the records the fabric reads and writes must
	// not sit in a cache the HP port cannot see.
	int mem = open("/dev/mem", O_RDWR | O_SYNC);
	if (mem < 0) {
		say("/dev/mem: %s", strerror(errno));
		return 1;
	}
	// 1. The guard, before anything on GP0.
	if (!no_guard && guard(mem) < 0)
		return 1;
	struct mmio m;
	m.poll_us = poll_us;
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

	// 2. The face is there, or nothing is.
	if (probe_face(&ps, regs_phys) < 0)
		return 1;
	// The drive is absent until the pack is open and the cache started.
	ps_drive(&ps, 0, 0, 0);

	// 3. The pack.
	struct pack pk;
	char err[512];
	if (pack_open(&pk, pack_path, !read_only, err, sizeof err) < 0) {
		say("no pack: %s", err);
		say("the CADR sees a controller with no drive");
		if (once)
			return 1;
		for (;;)
			sleep(3600);
	}
	say("pack %s: %u cylinders, %u heads, %u blocks a track, %u blocks%s",
	    pack_path, pk.g.cylinders, pk.g.heads, pk.g.blocks_per_track, pk.blocks, read_only ? ", read-only" : "");
	{
		uint32_t rec[PACK_RECORD_WORDS];
		if (pack_record(&pk, 0, rec, err, sizeof err) == 0)
			say("block 0 word 0 is 0x%08x%s; header 0x%08x", rec[0],
			    rec[0] == 0x4C42414Cu ? " (LABL: a labelled pack)" : "", rec[256]);
	}
	say("headers and checkwords are the format's own until a transfer lays others, and are the run's, as muir's are");

	struct feeder f;
	if (feeder_init(&f, &pk, &ps, spare, FEEDER_SPARE_BASE, FEEDER_MAP_BYTES, logf) < 0) {
		say("the mapped region does not cover the records");
		return 1;
	}
	say("records at 0x%08x (fetches) and 0x%08x (write-backs), %u slots 0x%x apart",
	    feeder_fetch_addr(0), feeder_wb_addr(0), PS_SLOTS, FEEDER_RECORD_STRIDE);

	if (do_selftest)
		return selftest(&f, &pk, unit);

	// 4. The drive comes present.
	if (feeder_start(&f, unit, read_only, timed, err, sizeof err) < 0) {
		say("starting the cache: %s", err);
		return 1;
	}
	// The interrupt, behind its flag.
	int irq_fd = -1;
	if (irq_path) {
		irq_fd = open(irq_path, O_RDWR);
		if (irq_fd < 0) {
			say("%s: %s; polling instead", irq_path, strerror(errno));
		} else {
			ps_irqen(&ps, PS_IRQ_REQ | PS_IRQ_DIRTY);
			say("sleeping on %s for the request and dirty events, with a %u us poll as the backstop", irq_path, poll_us);
		}
	}
	if (irq_fd < 0)
		say("polling REQ and DIRTY every %u us", poll_us);
	if (once)
		return 0;

	// 5. The loop.
	signal(SIGTERM, on_stop);
	signal(SIGINT, on_stop);
	time_t last_said = time(NULL), last_fail_said = 0;
	char last_fail[512] = "";
	unsigned long said_served = 0, said_wb = 0, said_denied = 0, said_failures = 0;
	unsigned long suppressed_failures = 0;
	while (!stopping) {
		if (irq_fd >= 0) {
			struct pollfd pfd = { irq_fd, POLLIN, 0 };
			if (poll(&pfd, 1, (int)((poll_us + 999) / 1000)) > 0 && (pfd.revents & POLLIN)) {
				uint32_t count;
				if (read(irq_fd, &count, sizeof count) < 0 && errno != EAGAIN)
					say("%s: %s", irq_path, strerror(errno));
			}
		} else {
			usleep(poll_us);
		}
		if (feeder_poll(&f, err, sizeof err) < 0) {
			const time_t now = time(NULL);
			if (strcmp(err, last_fail) != 0 || now - last_fail_said >= 60) {
				if (suppressed_failures)
					say("(%lu more of the last failure)", suppressed_failures);
				say("%s", err);
				snprintf(last_fail, sizeof last_fail, "%s", err);
				last_fail_said = now;
				suppressed_failures = 0;
			} else {
				++suppressed_failures;
			}
		}
		if (irq_fd >= 0) {
			// The events this pass saw are cleared in the fabric; re-arm
			// the line for the next.
			const uint32_t one = 1;
			if (write(irq_fd, &one, sizeof one) < 0 && errno != EAGAIN)
				say("%s: re-enabling: %s", irq_path, strerror(errno));
		}
		const time_t now = time(NULL);
		if (now - last_said >= 60
		    && (f.served != said_served || f.written_back != said_wb || f.denied != said_denied || f.failures != said_failures)) {
			say("served %lu, written back %lu, denied %lu, refused for the walk's slot %lu (write-backs deferred %lu, "
			    "at most %u passes in a row), %lu lost at start, %lu failures%s%s; %lu polls, %lu of the face while busy",
			    f.served, f.written_back, f.denied, f.refused_walk, f.deferred_dirty, f.longest_deferral,
			    f.lost_at_start, f.failures, f.failures ? ", the last: " : "", f.failures ? f.last_failure : "",
			    f.polls, ps.polls);
			said_served = f.served;
			said_wb = f.written_back;
			said_denied = f.denied;
			said_failures = f.failures;
			last_said = now;
		}
	}
	// Stopping: the CADR's writes onto the pack, then no drive.
	const unsigned still = feeder_flush(&f, 50, err, sizeof err);
	if (still)
		say("stopping: %s", err);
	ps_drive(&ps, 0, 0, 0);
	say("stopped: served %lu, written back %lu, denied %lu, %lu failures; the drive on unit %u is absent%s",
	    f.served, f.written_back, f.denied, f.failures, unit, still ? " and the CADR's last writes are not all on the pack" : "");
	pack_close(&pk);
	return still ? 1 : 0;
}
