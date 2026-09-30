// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// quux-file-device's check, on the build host.
//
//     qfd_test --script S --tree T --out O   a script of rings, as the golden runs it
//     qfd_test --errno-table                 the status of every errno, 1 to 133
//     qfd_test --unit --work DIR             what no script can reach
//
// **THE SCRIPT IS RUN THROUGH THE WHOLE PROGRAM BUT /dev/mem.**  Its
// operations move a model of the file device's page --- the fabric's rules
// for STATE, CLAIM, RESP_PROD and HANDLES, as the page's definition states
// them --- and the program's own face over that page (`qfd_face_fabric.c`),
// its own service step (`qfd_ring.c`) and its own core (`qfd.c`) answer.  The
// transcript is written in `golden/src/quux_file_device.rs`'s format, line for
// line, so that `qfd_compare.py` can hold the two to each other with `cmp`.
//
// **AND THE MODEL WATCHES THE PROGRAM WHILE IT RUNS.**  Every word of main
// memory the program touches must be touched under the claim; every
// completion must come after a barrier that followed the last word written;
// and the claim must be dropped when a step returns.  A breach is a FAIL line
// and a failed run, whatever the transcript says.

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "qfd.h"
#include "qfd_face.h"
#include "qfd_ring.h"

static int failures;

static void fail(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stdout, "FAIL: ");
	vfprintf(stdout, fmt, ap);
	fprintf(stdout, "\n");
	va_end(ap);
	++failures;
}

// --- the model of the page ----------------------------------------------------------

#define PAGE_IDENT    0x51464439u
#define PAGE_IDENT_13 0x51463133u

// Main memory is 32-bit words to revision 12 (`mem`) and packed storage on
// revision 13 (`pk`, 5 bytes a word, the tag last), as the program's own
// `qfd_mem` has it; `sim_get` and `sim_put` read and write a word of either.
struct sim {
	uint32_t *mem;
	uint8_t *pk;
	int r13;
	size_t words;
	int enabled, ie, busy, refused;
	uint16_t epoch;
	uint32_t cb, cl, rb, rl;
	uint16_t cmd_prod, resp_prod, resp_cons;
	uint32_t handles;          // what the machine sees in 161 <23:16>
	uint32_t staged;           // HANDLES as written, landing with the next completion
	int have_staged;
	uint32_t rtc_sec, rtc_frac, rtc_stage;
	int dirty;                 // a word touched since the last barrier
	long touches;
	long disable_at;           // a disable at this touch, for the unit check
	unsigned wlog[64];         // the offsets written, in order
	int nwlog;
};

static uint64_t sim_get(const struct sim *s, size_t k)
{
	if (!s->r13)
		return s->mem[k];
	uint64_t v = 0;
	for (int i = 4; i >= 0; --i)
		v = v << 8 | s->pk[5 * k + (size_t)i];
	return v;
}

// A 40-bit word on revision 13; `<31:0>` to revision 12.
static void sim_put(struct sim *s, size_t k, uint64_t v)
{
	if (!s->r13) {
		s->mem[k] = (uint32_t)v;
		return;
	}
	for (int i = 0; i < 5; ++i)
		s->pk[5 * k + (size_t)i] = (uint8_t)(v >> (8 * i));
}

static void sim_alloc(struct sim *s, size_t words)
{
	free(s->mem);
	free(s->pk);
	s->mem = NULL, s->pk = NULL;
	s->words = words;
	if (s->r13)
		s->pk = calloc(words ? words : 1, 5);
	else
		s->mem = calloc(words ? words : 1, 4);
}

// The fabric's rule at the enable, muir's: each ring on a line (4 words, 8 on
// revision 13), of at most 256 entries, inside main memory.  A ring that
// breaks it leaves the device disabled.
static int sim_fits(const struct sim *s, uint32_t base, uint32_t log2)
{
	return (base & (s->r13 ? 7u : 3u)) == 0 && log2 <= 8 && base + ((size_t)8 << log2) <= s->words;
}

static void sim_disable(struct sim *s)
{
	if (!s->enabled)
		return;
	s->enabled = s->ie = 0;
	s->epoch++;
	s->cmd_prod = s->resp_prod = s->resp_cons = 0;
	s->handles = 0;
	s->have_staged = 0;
}

static int sim_work(const struct sim *s)
{
	return s->enabled && s->cmd_prod != s->resp_prod
	       && (uint16_t)(s->resp_prod - s->resp_cons) < (1u << s->rl);
}

static uint32_t sim_rd(void *ctx, unsigned off)
{
	struct sim *s = ctx;
	switch (off) {
	case 0x000: return s->r13 ? PAGE_IDENT_13 : PAGE_IDENT;
	case 0x010: return s->rtc_sec;
	case 0x014: return s->rtc_frac;
	case 0x100:
		return (uint32_t)s->enabled | (uint32_t)s->ie << 1 | (uint32_t)s->busy << 2
		       | (uint32_t)(!s->enabled && !s->busy) << 3 | (uint32_t)sim_work(s) << 4
		       | (uint32_t)s->refused << 5 | (uint32_t)s->epoch << 16;
	case 0x104: return (uint32_t)s->busy;
	case 0x108: return s->cb;
	case 0x10C: return s->cl;
	case 0x110: return s->rb;
	case 0x114: return s->rl;
	case 0x118: return s->enabled ? s->cmd_prod : 0;
	case 0x11C: return s->enabled ? s->resp_prod : 0;
	case 0x120: return s->enabled ? s->resp_cons : 0;
	case 0x124: return s->handles;
	case 0x128: return (uint32_t)s->words;
	}
	fail("the program read offset 0x%03x, which the page does not have", off);
	return 0;
}

static void sim_wr(void *ctx, unsigned off, uint32_t v)
{
	struct sim *s = ctx;
	if (s->nwlog < 64)
		s->wlog[s->nwlog++] = off;
	const uint16_t ep = (uint16_t)(v >> 16), idx = (uint16_t)v;
	switch (off) {
	case QFD_FABRIC_BARRIER:
		s->dirty = 0;
		return;
	case 0x010:
		s->rtc_sec = v;
		s->rtc_frac = s->rtc_stage;
		s->rtc_stage = 0;
		return;
	case 0x014:
		s->rtc_stage = v;
		return;
	case 0x104:
		if (!(v & 1))
			s->busy = 0;
		else if (s->enabled && ep == s->epoch)
			s->busy = 1;
		return;
	case 0x11C:
		if (s->dirty)
			fail("a completion was written before a barrier after the last word of memory");
		if (s->enabled && ep == s->epoch && (uint16_t)(idx - s->resp_prod) >= 1
		    && (uint16_t)(idx - s->resp_prod) <= (uint16_t)(s->cmd_prod - s->resp_prod)
		    && (uint16_t)(idx - s->resp_cons) <= (1u << s->rl)) {
			s->resp_prod = idx;
			if (s->have_staged)
				s->handles = s->staged;
			s->have_staged = 0;
		} else
			s->refused = 1;
		return;
	case 0x124:
		// Staged: the machine sees the count move with 170.
		if (s->enabled && ep == s->epoch) {
			s->staged = v & 0xFF;
			s->have_staged = 1;
		}
		return;
	}
	fail("the program wrote 0x%08x to offset 0x%03x, which it may not write", v, off);
}

static void sim_touch(void *ctx)
{
	struct sim *s = ctx;
	++s->touches;
	if (!s->busy)
		fail("a word of main memory was touched without the claim");
	s->dirty = 1;
	if (s->disable_at && s->touches == s->disable_at)
		sim_disable(s);
}

// The program's face over the model: its own fabric face, with the page's
// accesses sent to the model and main memory watched.
static void sim_face(struct sim *s, struct qfd_fabric *fb, struct qfd_face *f)
{
	memset(fb, 0, sizeof *fb);
	fb->sim_rd = sim_rd;
	fb->sim_wr = sim_wr;
	fb->sim = s;
	char why[200];
	if (qfd_fabric_attach(fb, why, sizeof why) != 0)
		fail("attach: %s", why);
	if (fb->revision_13 != s->r13)
		fail("attach: the program took the page for revision %s", fb->revision_13 ? "13" : "12");
	qfd_fabric_face(fb, s->r13 ? (volatile void *)s->pk : (volatile void *)s->mem, f);
	f->mem.touch = sim_touch;
	f->mem.ctx = s;
}

// --- the script ---------------------------------------------------------------------

static unsigned long long num(const char *s)
{
	if (!strncmp(s, "0x", 2))
		return strtoull(s + 2, NULL, 16);
	return strtoull(s, NULL, 10);
}

static size_t hex_bytes(const char *s, uint8_t *out)
{
	if (!strcmp(s, "-"))
		return 0;
	size_t n = strlen(s) / 2;
	for (size_t i = 0; i < n; ++i) {
		unsigned v;
		sscanf(s + 2 * i, "%2x", &v);
		out[i] = (uint8_t)v;
	}
	return n;
}

// FNV-1a over main memory as it is stored: 4 bytes a word to revision 12,
// and on revision 13 the 5 of packed storage.
static uint64_t fnv(const struct sim *s)
{
	uint64_t h = 0xcbf29ce484222325ull;
	const int n = s->r13 ? 5 : 4;
	for (size_t i = 0; i < s->words; ++i) {
		const uint64_t w = sim_get(s, i);
		for (int k = 0; k < n; ++k) {
			h ^= (uint8_t)(w >> (8 * k));
			h *= 0x100000001b3ull;
		}
	}
	return h;
}

// Every directory under `dir` to 1000000000, as the golden does; one that
// cannot be opened keeps its time.
static void settle_dirs(const char *dir)
{
	struct stat st;
	if (lstat(dir, &st) != 0 || !S_ISDIR(st.st_mode))
		return;
	DIR *d = opendir(dir);
	if (d) {
		struct dirent *e;
		while ((e = readdir(d))) {
			if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
				continue;
			char p[4096];
			snprintf(p, sizeof p, "%s/%s", dir, e->d_name);
			settle_dirs(p);
		}
		closedir(d);
	}
	const int fd = open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
	if (fd >= 0) {
		const struct timespec t[2] = { { 0, UTIME_OMIT }, { 1000000000, 0 } };
		if (futimens(fd, t) != 0)
			fail("settling %s: %s", dir, strerror(errno));
		close(fd);
	}
}

static void replace_all(const char *in, const char *what, const char *with, char *out, size_t len)
{
	size_t o = 0;
	const size_t wl = strlen(what);
	while (*in && o + 1 < len) {
		if (wl && !strncmp(in, what, wl)) {
			o += (size_t)snprintf(out + o, len - o, "%s", with);
			in += wl;
		} else {
			out[o++] = *in++;
		}
	}
	out[o < len ? o : len - 1] = '\0';
}

struct logbuf {
	char **lines;
	int n;
};

static void log_keep(void *ctx, const char *line)
{
	struct logbuf *b = ctx;
	b->lines = realloc(b->lines, (size_t)(b->n + 1) * sizeof *b->lines);
	b->lines[b->n++] = strdup(line);
}

struct describe_ctx {
	FILE *out;
	const char *tree;
};

static void describe_line(void *ctx, const char *line)
{
	struct describe_ctx *c = ctx;
	char buf[8192];
	replace_all(line, c->tree, "@", buf, sizeof buf);
	fprintf(c->out, "mount %s\n", buf);
}

static int run_script(const char *script, const char *tree, const char *outpath)
{
	FILE *in = fopen(script, "r");
	FILE *out = fopen(outpath, "w");
	if (!in || !out) {
		fail("opening %s or %s: %s", script, outpath, strerror(errno));
		return 1;
	}
	static struct qfd d;
	qfd_init(&d);
	struct logbuf logs = { 0 };
	d.log = log_keep;
	d.log_ctx = &logs;
	struct sim s;
	memset(&s, 0, sizeof s);
	struct qfd_fabric fb;
	struct qfd_face face;
	struct qfd_ring g;
	qfd_ring_init(&g, &d);
	uint16_t prod = 0, rcons = 0, seen = 0;
	uint16_t nowat[256];
	int nnow = 0;
	char line[1 << 20];
	static uint8_t bytes[1 << 19];
	settle_dirs(tree);
	while (fgets(line, sizeof line, in)) {
		char *w[16];
		int n = 0;
		for (char *t = strtok(line, " \t\n"); t && n < 16; t = strtok(NULL, " \t\n"))
			w[n++] = t;
		if (n == 0 || w[0][0] == '#')
			continue;
		char path[4096];
		if (!strcmp(w[0], "revision")) {
			// Before `memory`: the layout main memory takes.
			s.r13 = num(w[1]) == 13;
		} else if (!strcmp(w[0], "memory")) {
			sim_alloc(&s, (size_t)num(w[1]));
			sim_face(&s, &fb, &face);
		} else if (!strcmp(w[0], "root")) {
			char spec[4096], why[512];
			replace_all(w[1], "@", tree, spec, sizeof spec);
			const int r = qfd_mount_add(&d.mounts, spec, why, sizeof why);
			fprintf(out, "root %s %s\n", w[1], r == 0 ? "ok" : "refused");
		} else if (!strcmp(w[0], "describe")) {
			struct describe_ctx c = { out, tree };
			qfd_mounts_describe(&d.mounts, describe_line, &c);
		} else if (!strcmp(w[0], "rings")) {
			// Registers 162-167 are taken only while the device is
			// disabled, as muir's are.
			if (!s.enabled) {
				const uint32_t mask = s.r13 ? 0x0FFFFFFF : 0xFFFFFF;
				s.cb = (uint32_t)num(w[1]) & mask;
				s.cl = (uint32_t)num(w[2]) & 017;
				s.rb = (uint32_t)num(w[3]) & mask;
				s.rl = (uint32_t)num(w[4]) & 017;
			}
		} else if (!strcmp(w[0], "enable")) {
			if (!s.enabled && sim_fits(&s, s.cb, s.cl) && sim_fits(&s, s.rb, s.rl)) {
				s.enabled = 1;
				s.cmd_prod = s.resp_prod = s.resp_cons = 0;
			}
			s.ie = (int)num(w[1]);
			prod = rcons = seen = 0;
		} else if (!strcmp(w[0], "disable") || !strcmp(w[0], "reset")) {
			sim_disable(&s);
			prod = rcons = seen = 0;
		} else if (!strcmp(w[0], "fill")) {
			const size_t a = (size_t)num(w[1]), k = (size_t)num(w[2]);
			for (size_t i = 0; i < k; ++i)
				sim_put(&s, a + i, num(w[3]));
		} else if (!strcmp(w[0], "bytes")) {
			// On revision 13 each word takes the tag the script gives, 0
			// when it gives none.
			const size_t a = (size_t)num(w[1]), k = hex_bytes(w[2], bytes);
			const uint64_t tag = n > 3 ? num(w[3]) & 0xFF : 0;
			for (size_t i = 0; i < (k + 3) / 4; ++i) {
				uint32_t v = 0;
				for (size_t j = 0; j < 4 && 4 * i + j < k; ++j)
					v |= (uint32_t)bytes[4 * i + j] << (8 * j);
				sim_put(&s, a + i, tag << 32 | v);
			}
		} else if (!strcmp(w[0], "cmd")) {
			const size_t slot = s.cb + 8u * (prod % (1u << s.cl));
			for (int k = 0; k < 8; ++k)
				sim_put(&s, slot + (size_t)k, num(w[1 + k]));
			prod++;
		} else if (!strcmp(w[0], "post")) {
			// A producer that claims more than the ring holds, or
			// fewer than are waiting, is the machine's index fault
			// and goes nowhere, as muir's does.
			const uint16_t claimed = (uint16_t)(prod - s.resp_prod);
			if (s.enabled && claimed <= (1u << s.cl) && claimed >= (uint16_t)(s.cmd_prod - s.resp_prod))
				s.cmd_prod = prod;
		} else if (!strcmp(w[0], "consume")) {
			rcons = (uint16_t)(rcons + num(w[1]));
			if (s.enabled && (uint16_t)(rcons - s.resp_cons) <= (uint16_t)(s.resp_prod - s.resp_cons))
				s.resp_cons = rcons;
		} else if (!strcmp(w[0], "nowat")) {
			nowat[nnow++ & 255] = (uint16_t)num(w[1]);
		} else if (!strcmp(w[0], "run")) {
			for (int r; (r = qfd_ring_step(&g, &face)) != 0;) {
				if (s.busy)
					fail("a step returned with the claim held");
				if (r < 0) {
					fail("the program stopped: the page did not take a completion");
					break;
				}
			}
			if (s.busy)
				fail("a step returned with the claim held");
			if (s.refused)
				fail("the page refused a completion");
			const uint64_t clock = (uint64_t)time(NULL);
			const uint16_t upto = s.resp_prod;
			while (seen != upto) {
				const size_t r = s.rb + 8u * (seen % (1u << s.rl));
				fprintf(out, "resp %u", seen);
				const int digits = s.r13 ? 10 : 8;
				for (int k = 0; k < 8; ++k) {
					const uint64_t v = sim_get(&s, r + (size_t)k);
					const uint32_t low = (uint32_t)v;
					int masked = 0;
					for (int j = 0; j < nnow && j < 256; ++j)
						if (k == 4 && nowat[j] == seen
						    && (low > clock ? low - clock : clock - low) <= 10)
							masked = 1;
					if (masked) {
						fprintf(out, " NOW");
						sim_put(&s, r + (size_t)k, 0);
					}
					else
						fprintf(out, " %0*llx", digits, (unsigned long long)v);
				}
				fprintf(out, "\n");
				const size_t c = s.cb + 8u * (seen % (1u << s.cl));
				const size_t at = (uint32_t)sim_get(&s, c + 4) & (s.r13 ? 0x0FFFFFFF : 0xFFFFFF);
				const size_t len = (uint32_t)sim_get(&s, c + 5);
				if (!(at & (s.r13 ? 7 : 3)) && len <= 65536 && at + (len + 3) / 4 <= s.words) {
					fprintf(out, "b %u", seen);
					for (size_t k = 0; k < (len + 3) / 4; ++k)
						fprintf(out, " %0*llx", digits, (unsigned long long)sim_get(&s, at + k));
					fprintf(out, "\n");
				}
				seen++;
			}
			for (int k = 0; k < logs.n; ++k) {
				fprintf(out, "%s\n", logs.lines[k]);
				free(logs.lines[k]);
			}
			logs.n = 0;
			const unsigned queued = (uint16_t)(s.cmd_prod - s.resp_prod);
			fprintf(out, "state handles %u queued %u\n", s.handles, queued);
			char why[256];
			const char *ref = qfd_checkpoint_refusal(s.handles, queued, why, sizeof why);
			fprintf(out, "refusal %s\n", ref ? ref : "none");
			fprintf(out, "mem %016llx\n", (unsigned long long)fnv(&s));
			settle_dirs(tree);
		} else if (!strcmp(w[0], "hostwrite")) {
			snprintf(path, sizeof path, "%s/%s", tree, w[1]);
			const size_t k = hex_bytes(w[2], bytes);
			FILE *f = fopen(path, "wb");
			if (!f || fwrite(bytes, 1, k, f) != k)
				fail("hostwrite %s", path);
			if (f)
				fclose(f);
		} else if (!strcmp(w[0], "hostrm")) {
			snprintf(path, sizeof path, "%s/%s", tree, w[1]);
			if (unlink(path) != 0)
				fail("hostrm %s", path);
		} else if (!strcmp(w[0], "utime")) {
			snprintf(path, sizeof path, "%s/%s", tree, w[1]);
			const struct timespec t[2] = { { 0, UTIME_OMIT }, { (time_t)num(w[2]), 0 } };
			if (utimensat(AT_FDCWD, path, t, 0) != 0)
				fail("utime %s", path);
		} else if (!strcmp(w[0], "chmod")) {
			snprintf(path, sizeof path, "%s/%s", tree, w[1]);
			if (chmod(path, (mode_t)strtoul(w[2], NULL, 8)) != 0)
				fail("chmod %s", path);
		} else {
			fail("%s: unknown operation %s", script, w[0]);
		}
	}
	// The run is over: what the program does when it stops.
	qfd_reset(&d);
	settle_dirs(tree);
	if (qfd_hook_bad_access)
		fail("%lu accesses to packed main memory were misaligned or outside their run",
		     qfd_hook_bad_access);
	fclose(in);
	fclose(out);
	free(s.mem);
	free(s.pk);
	return failures != 0;
}

// --- what no script reaches ---------------------------------------------------------

static void write_file(const char *path, const char *text)
{
	FILE *f = fopen(path, "w");
	if (!f) {
		fail("making %s: %s", path, strerror(errno));
		return;
	}
	fputs(text, f);
	fclose(f);
}

static int exists(const char *path)
{
	struct stat st;
	return lstat(path, &st) == 0;
}

static int count_temps(const char *dir)
{
	DIR *d = opendir(dir);
	int n = 0;
	struct dirent *e;
	while (d && (e = readdir(d)))
		n += !strncmp(e->d_name, QFD_TEMP_PREFIX, strlen(QFD_TEMP_PREFIX));
	if (d)
		closedir(d);
	return n;
}

// A command into the model's ring by hand: its entry at the producer's slot,
// its name in buffer A at `a`, and the producer moved.
static void post_cmd(struct sim *s, uint32_t op, uint32_t flags, uint32_t handle, const char *a_text,
		     uint32_t a_at, uint32_t off)
{
	const size_t n = a_text ? strlen(a_text) : 0;
	for (size_t i = 0; i < (n + 3) / 4; ++i) {
		uint32_t v = 0;
		for (size_t j = 0; j < 4 && 4 * i + j < n; ++j)
			v |= (uint32_t)(uint8_t)a_text[4 * i + j] << (8 * j);
		s->mem[a_at + i] = v;
	}
	const size_t slot = s->cb + 8u * (s->cmd_prod % (1u << s->cl));
	const uint32_t e[8] = { 0x10u | op << 16 | flags << 24, handle, a_at, (uint32_t)n, 0, 0, off, 0 };
	memcpy(&s->mem[slot], e, sizeof e);
	s->cmd_prod++;
}

static uint32_t resp_status(const struct sim *s, uint16_t i)
{
	return (s->mem[s->rb + 8u * (i % (1u << s->rl))] >> 16) & 0xFF;
}

// A disable while the program is inside a command: the host effect may
// stand, but nothing is published, every handle goes, the temporary file is
// removed, the claim is dropped, and no completion is refused (none tried).
static void unit_disable_mid_command(const char *work)
{
	char root[4096], spec[4200], why[200];
	snprintf(root, sizeof root, "%s/midcmd", work);
	mkdir(root, 0755);
	snprintf(spec, sizeof spec, "%s", root);
	static struct qfd d;
	qfd_init(&d);
	if (qfd_mount_add(&d.mounts, spec, why, sizeof why) != 0)
		fail("mid-command: %s", why);
	struct sim s;
	memset(&s, 0, sizeof s);
	s.words = 0x10000;
	s.mem = calloc(s.words, 4);
	struct qfd_fabric fb;
	struct qfd_face face;
	sim_face(&s, &fb, &face);
	struct qfd_ring g;
	qfd_ring_init(&g, &d);
	s.cb = 0x100, s.cl = 2, s.rb = 0x200, s.rl = 2, s.enabled = 1;
	post_cmd(&s, QFD_OPEN, 1, 0, "/w.txt", 0x1000, 0);
	while (qfd_ring_step(&g, &face) > 0)
		;
	if (s.resp_prod != 1 || resp_status(&s, 0) != QFD_OK || s.handles != 1)
		fail("mid-command: the OPEN for write did not answer OK with one handle (status %u, handles %u)",
		     resp_status(&s, 0), s.handles);
	if (count_temps(root) != 1)
		fail("mid-command: the write's temporary file is not there");
	// The WRITE's buffer A is read after the entry's eight words: the
	// disable lands on its first word.
	post_cmd(&s, QFD_WRITE, 0, 1, "abcd", 0x1100, 0);
	s.disable_at = s.touches + 9;
	const int stepped = qfd_ring_step(&g, &face) == 1;
	if (!stepped)
		fail("mid-command: the step that was overtaken says it did nothing");
	if (s.enabled || s.epoch != 1)
		fail("mid-command: the model did not disable (the injection missed)");
	if (qfd_handles_open(&d) != 0)
		fail("mid-command: the program still holds %u handles after the disable", qfd_handles_open(&d));
	if (count_temps(root) != 0)
		fail("mid-command: the write's temporary file outlived the disable");
	if (s.busy)
		fail("mid-command: the claim is still held");
	if (s.refused)
		fail("mid-command: the program tried to publish an overtaken command");
	char wpath[4200];
	snprintf(wpath, sizeof wpath, "%s/w.txt", root);
	if (exists(wpath))
		fail("mid-command: a write discarded by the disable landed");
	// And the next enable starts clean: a READ of handle 1 is a bad handle.
	s.disable_at = 0;
	s.enabled = 1;
	post_cmd(&s, QFD_READ, 0, 1, NULL, 0x1000, 0);
	while (qfd_ring_step(&g, &face) > 0)
		;
	if (s.resp_prod != 1 || resp_status(&s, 0) != QFD_BAD_HANDLE)
		fail("mid-command: after the disable, handle 1 still answers (status %u)", resp_status(&s, 0));
	free(s.mem);
	qfd_reset(&d);
}

// The page's words as the program writes them: the claim under the epoch,
// the handles under it before the completion, the completion under it after
// a barrier, and the clock's fraction before its seconds.
static void unit_face_words(void)
{
	struct sim s;
	memset(&s, 0, sizeof s);
	s.words = 0x10000;
	s.mem = calloc(s.words, 4);
	s.epoch = 0x1234;
	// A program before this one died holding the claim: the start lets it
	// go, and it is the only write the start makes.
	s.busy = 1;
	struct qfd_fabric fb;
	struct qfd_face face;
	sim_face(&s, &fb, &face);
	if (fb.mem_words != 0x10000)
		fail("face: main memory's size is not the page's MEM_WORDS");
	if (s.busy || s.nwlog != 1 || s.wlog[0] != 0x104)
		fail("face: the start left a claim it found standing (busy %d, %d writes)", s.busy,
		     s.nwlog);
	static struct qfd d;
	qfd_init(&d);
	struct qfd_ring g;
	qfd_ring_init(&g, &d);
	s.cb = 0x100, s.cl = 0, s.rb = 0x200, s.rl = 0, s.enabled = 1;
	post_cmd(&s, 99, 0, 0, NULL, 0x1000, 0);
	s.nwlog = 0;
	while (qfd_ring_step(&g, &face) > 0)
		;
	// The first step's first write is the handles of a new epoch.
	const unsigned want[] = { 0x124, 0x104, 0x124, QFD_FABRIC_BARRIER, 0x11C, 0x104 };
	int same = s.nwlog == 6;
	for (int k = 0; same && k < 6; ++k)
		same = s.wlog[k] == want[k];
	if (!same) {
		fail("face: the page was written in the wrong order:");
		for (int k = 0; k < s.nwlog; ++k)
			printf("        0x%03x\n", s.wlog[k]);
	}
	if (s.resp_prod != 1 || resp_status(&s, 0) != QFD_UOP)
		fail("face: the unknown opcode was not answered UOP and completed");
	// The clock: once a second, fraction then seconds.
	s.nwlog = 0;
	struct timespec t = { 1700000000, 250000000 };
	qfd_ring_clock(&g, &face, &t);
	t.tv_nsec = 750000000;
	qfd_ring_clock(&g, &face, &t);
	t.tv_sec++;
	t.tv_nsec = 10;
	qfd_ring_clock(&g, &face, &t);
	if (s.nwlog != 4 || s.wlog[0] != 0x014 || s.wlog[1] != 0x010)
		fail("face: the clock was written %d times, not twice with the fraction first", s.nwlog / 2);
	if (s.rtc_sec != 1700000001 || s.rtc_frac != 10)
		fail("face: the clock reads %u and %u ns, not 1700000001 and 10", s.rtc_sec, s.rtc_frac);
	// A page that is not the file device's is refused.
	struct qfd_fabric other = { 0 };
	// Its main memory is a size the program would take, so that only
	// the page's name can refuse it.
	uint32_t page[1024] = { 0x4E4F4E45u };
	page[0x128 / 4] = 0x200000u;
	other.page = page;
	char why[200];
	if (qfd_fabric_attach(&other, why, sizeof why) == 0)
		fail("face: a page reading NONE was taken for the file device's");
	free(s.mem);
}

static void sweep_emit(void *ctx, const char *path)
{
	(void)path;
	++*(int *)ctx;
}

// The start's sweep: the temporary files of writable mounts, at any depth,
// and nothing else.
static void unit_sweep(const char *work)
{
	char rw[4096], ro[4096], p[4400], spec[4400], why[200];
	snprintf(rw, sizeof rw, "%s/sweep-rw", work);
	snprintf(ro, sizeof ro, "%s/sweep-ro", work);
	mkdir(rw, 0755);
	mkdir(ro, 0755);
	snprintf(p, sizeof p, "%s/a", rw), mkdir(p, 0755);
	snprintf(p, sizeof p, "%s/a/b", rw), mkdir(p, 0755);
	snprintf(p, sizeof p, "%s/" QFD_TEMP_PREFIX "1-0", rw), write_file(p, "x");
	snprintf(p, sizeof p, "%s/a/b/" QFD_TEMP_PREFIX "2-7", rw), write_file(p, "x");
	snprintf(p, sizeof p, "%s/a/keep.txt", rw), write_file(p, "keep");
	snprintf(p, sizeof p, "%s/a/" QFD_TEMP_PREFIX "dir", rw), mkdir(p, 0755);
	snprintf(p, sizeof p, "%s/" QFD_TEMP_PREFIX "9-9", ro), write_file(p, "x");
	// A symlink to the read-only folder is not followed into it.
	snprintf(p, sizeof p, "%s/link", rw);
	if (symlink(ro, p) != 0)
		fail("sweep: symlink: %s", strerror(errno));
	struct qfd_mounts m;
	memset(&m, 0, sizeof m);
	snprintf(spec, sizeof spec, "w=%s", rw);
	if (qfd_mount_add(&m, spec, why, sizeof why) != 0)
		fail("sweep: %s", why);
	snprintf(spec, sizeof spec, "r=%s,ro", ro);
	if (qfd_mount_add(&m, spec, why, sizeof why) != 0)
		fail("sweep: %s", why);
	int told = 0;
	const unsigned n = qfd_sweep(&m, sweep_emit, &told);
	if (n != 2 || told != 2)
		fail("sweep: %u removed and %d told, not 2 and 2", n, told);
	snprintf(p, sizeof p, "%s/" QFD_TEMP_PREFIX "1-0", rw);
	if (exists(p))
		fail("sweep: the stale file at the mount's top is still there");
	snprintf(p, sizeof p, "%s/a/b/" QFD_TEMP_PREFIX "2-7", rw);
	if (exists(p))
		fail("sweep: the stale file two folders down is still there");
	snprintf(p, sizeof p, "%s/a/keep.txt", rw);
	if (!exists(p))
		fail("sweep: an ordinary file was removed");
	snprintf(p, sizeof p, "%s/a/" QFD_TEMP_PREFIX "dir", rw);
	if (!exists(p))
		fail("sweep: a folder with the prefix was removed");
	snprintf(p, sizeof p, "%s/" QFD_TEMP_PREFIX "9-9", ro);
	if (!exists(p))
		fail("sweep: a read-only mount was changed");
}

// The FAT quirks that a Linux folder of the build host cannot produce: a
// name the host refuses (EINVAL) is IPS wherever the host says it, and a
// folder that finds a name whatever its case still answers only the
// spelling that is there.
static void unit_fat(const char *work)
{
	char root[4096], spec[4200], p[4400], why[200];
	snprintf(root, sizeof root, "%s/fat", work);
	mkdir(root, 0755);
	snprintf(p, sizeof p, "%s/Readme.TXT", root);
	write_file(p, "hello");
	snprintf(spec, sizeof spec, "%s", root);
	static struct qfd d;
	qfd_init(&d);
	if (qfd_mount_add(&d.mounts, spec, why, sizeof why) != 0)
		fail("fat: %s", why);
	struct sim s;
	memset(&s, 0, sizeof s);
	s.words = 0x10000;
	s.mem = calloc(s.words, 4);
	struct qfd_fabric fb;
	struct qfd_face face;
	sim_face(&s, &fb, &face);
	struct qfd_ring g;
	qfd_ring_init(&g, &d);
	s.cb = 0x100, s.cl = 3, s.rb = 0x200, s.rl = 3, s.enabled = 1;
	struct {
		uint32_t op, flags, handle;
		const char *name;
		int hook_errno, fold;
		uint32_t want;
		const char *what;
	} cases[] = {
		{ QFD_OPEN, 2, 0, "/Readme.TXT", 0, 1, QFD_OK, "the name as spelled, on a folding folder" },
		{ QFD_OPEN, 2, 0, "/README.TXT", 0, 1, QFD_FNF, "another spelling, on a folding folder" },
		{ QFD_OPEN, 2, 0, "/readme.txt", 0, 1, QFD_FNF, "a third spelling, on a folding folder" },
		{ QFD_OPEN, 1, 0, "/a:b", EINVAL, 0, QFD_IPS, "OPEN write where the host refuses the name" },
		{ QFD_CREATE_DIRECTORY, 0, 0, "/a*b", EINVAL, 0, QFD_IPS, "CREATE-DIRECTORY the host refuses" },
		{ QFD_OPEN, 1, 0, "/x.txt", ENOSPC, 0, QFD_NMR, "OPEN write on a full host" },
		{ QFD_CREATE_DIRECTORY, 0, 0, "/y", EIO, 0, QFD_DAT, "CREATE-DIRECTORY on a host I/O error" },
	};
	for (unsigned k = 0; k < sizeof cases / sizeof cases[0]; ++k) {
		qfd_hook_errno = cases[k].hook_errno;
		qfd_hook_folding = cases[k].fold ? root : NULL;
		const uint16_t i = s.resp_prod;
		post_cmd(&s, cases[k].op, cases[k].flags, cases[k].handle, cases[k].name, 0x1000, 0);
		while (qfd_ring_step(&g, &face) > 0)
			;
		const uint32_t got = resp_status(&s, i);
		if (got != cases[k].want)
			fail("fat: %s answered %u, not %u", cases[k].what, got, cases[k].want);
		qfd_hook_errno = 0;
		qfd_hook_folding = NULL;
		s.resp_cons = s.resp_prod;
	}
	qfd_reset(&d);
	if (count_temps(root) != 0)
		fail("fat: a temporary file was left behind");
	// And a RENAME the host refuses, through the same path CLOSE uses.
	snprintf(p, sizeof p, "%s/from", root);
	write_file(p, "x");
	char to[] = "/a?b";
	const uint16_t i = s.resp_prod;
	const char *from = "/from";
	for (size_t k = 0; k < (strlen(from) + 3) / 4; ++k) {
		uint32_t v = 0;
		for (size_t j = 0; j < 4 && 4 * k + j < strlen(from); ++j)
			v |= (uint32_t)(uint8_t)from[4 * k + j] << (8 * j);
		s.mem[0x1000 + k] = v;
	}
	for (size_t k = 0; k < (strlen(to) + 3) / 4; ++k) {
		uint32_t v = 0;
		for (size_t j = 0; j < 4 && 4 * k + j < strlen(to); ++j)
			v |= (uint32_t)(uint8_t)to[4 * k + j] << (8 * j);
		s.mem[0x1100 + k] = v;
	}
	const size_t slot = s.cb + 8u * (s.cmd_prod % (1u << s.cl));
	const uint32_t e[8] = { 7u | QFD_RENAME << 16, 0, 0x1000, (uint32_t)strlen(from), 0x1100,
				(uint32_t)strlen(to), 0, 0 };
	memcpy(&s.mem[slot], e, sizeof e);
	s.cmd_prod++;
	qfd_hook_errno = EINVAL;
	while (qfd_ring_step(&g, &face) > 0)
		;
	qfd_hook_errno = 0;
	if (resp_status(&s, i) != QFD_IPS)
		fail("fat: a RENAME the host refuses answered %u, not IPS", resp_status(&s, i));
	free(s.mem);
}

// Revision 13's page and memory, where no script of a quarter of a million
// words reaches: rings and buffers above 16M words, where a base's <27:24>
// are set, and the page's own rules for which main memory it may say.
static void unit_revision_13(const char *work)
{
	char root[4096], spec[4200], p[4400], why[200];
	snprintf(root, sizeof root, "%s/r13", work);
	mkdir(root, 0755);
	snprintf(p, sizeof p, "%s/hi.txt", root);
	write_file(p, "high");
	snprintf(spec, sizeof spec, "%s", root);
	static struct qfd d;
	qfd_init(&d);
	if (qfd_mount_add(&d.mounts, spec, why, sizeof why) != 0)
		fail("r13: %s", why);
	struct sim s;
	memset(&s, 0, sizeof s);
	s.r13 = 1;
	// 16M + 4,096 words: 80 MB of packed storage, which calloc leaves
	// untouched but for the pages the command uses.
	sim_alloc(&s, 0x1001000);
	struct qfd_fabric fb;
	struct qfd_face face;
	sim_face(&s, &fb, &face);
	if (!fb.revision_13 || fb.mem_words != 0x1001000)
		fail("r13: \"QF13\" with %zu words was not taken as revision 13's page", s.words);
	struct qfd_ring g;
	qfd_ring_init(&g, &d);
	// Both rings and the buffer above 16M words: <24> of each address set.
	s.cb = 0x1000000, s.cl = 1, s.rb = 0x1000800, s.rl = 1, s.enabled = 1;
	const char *name = "/hi.txt";
	for (size_t i = 0; i < 2; ++i) {
		uint32_t v = 0;
		for (size_t j = 0; j < 4 && 4 * i + j < strlen(name); ++j)
			v |= (uint32_t)(uint8_t)name[4 * i + j] << (8 * j);
		sim_put(&s, 0x1000400 + i, (uint64_t)0x42 << 32 | v);
	}
	const uint32_t e[8] = { 0x10u | QFD_OPEN << 16 | 2u << 24, 0, 0x1000400,
				(uint32_t)strlen(name), 0, 0, 0, 0 };
	for (int k = 0; k < 8; ++k)
		sim_put(&s, s.cb + (size_t)k, (uint64_t)QFD_TAG_FIXNUM << 32 | e[k]);
	s.cmd_prod = 1;
	while (qfd_ring_step(&g, &face) > 0)
		;
	const uint64_t r0 = sim_get(&s, s.rb);
	if (s.resp_prod != 1 || r0 != ((uint64_t)QFD_TAG_FIXNUM << 32 | QFD_OPEN << 24 | 0x10u))
		fail("r13: a probe with its rings and buffer above 16M words answered %010llx, not "
		     "OK as a fixnum", (unsigned long long)r0);
	if (sim_get(&s, 0) || sim_get(&s, 0x400) || sim_get(&s, 0x800))
		fail("r13: a word below 16M words was touched: the addresses lost <24>");
	if (qfd_hook_bad_access)
		fail("r13: %lu accesses were misaligned or outside their run", qfd_hook_bad_access);
	qfd_reset(&d);
	free(s.pk);
	// What main memory each page may say: revision 13's up to 64M words and
	// revision 12's up to 16M.
	struct { uint32_t ident, words; int ok, r13; } pages[] = {
		{ PAGE_IDENT_13, 64u << 20, 1, 1 }, { PAGE_IDENT_13, (64u << 20) + 1, 0, 1 },
		{ PAGE_IDENT, 16u << 20, 1, 0 }, { PAGE_IDENT, (16u << 20) + 1, 0, 0 },
		{ 0x51464438u, 1u << 20, 0, 0 },
	};
	for (unsigned k = 0; k < sizeof pages / sizeof pages[0]; ++k) {
		static uint32_t page[1024];
		memset(page, 0, sizeof page);
		page[0] = pages[k].ident;
		page[0x128 / 4] = pages[k].words;
		struct qfd_fabric f = { 0 };
		f.page = page;
		const int ok = qfd_fabric_attach(&f, why, sizeof why) == 0;
		if (ok != pages[k].ok || (ok && f.revision_13 != pages[k].r13))
			fail("r13: a page reading 0x%08x with %u words was %s", pages[k].ident, pages[k].words,
			     ok ? "taken" : "refused");
	}
}

static void unit_refusal(void)
{
	char buf[256];
	if (qfd_checkpoint_refusal(0, 0, buf, sizeof buf))
		fail("refusal: an idle device refuses a checkpoint");
	const char *r = qfd_checkpoint_refusal(1, 0, buf, sizeof buf);
	if (!r || !strstr(r, "1 handle open and 0 commands queued"))
		fail("refusal: one handle open: %s", r ? r : "(none)");
}

int main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc == 2 && !strcmp(argv[1], "--errno-table")) {
		for (int e = 1; e <= 133; ++e)
			printf("%d %u\n", e, qfd_errno_status(e));
		return 0;
	}
	if (argc == 3 && !strcmp(argv[1], "--unit")) {
		fprintf(stderr, "usage: qfd_test --unit --work DIR\n");
		return 2;
	}
	if (argc == 4 && !strcmp(argv[1], "--unit") && !strcmp(argv[2], "--work")) {
		const char *work = argv[3];
		unit_disable_mid_command(work);
		unit_face_words();
		unit_sweep(work);
		unit_fat(work);
		unit_refusal();
		unit_revision_13(work);
		printf("qfd_test: unit: %s\n", failures ? "FAILED" : "ok");
		return failures != 0;
	}
	const char *script = NULL, *tree = NULL, *out = NULL;
	for (int i = 1; i + 1 < argc; i += 2) {
		if (!strcmp(argv[i], "--script"))
			script = argv[i + 1];
		else if (!strcmp(argv[i], "--tree"))
			tree = argv[i + 1];
		else if (!strcmp(argv[i], "--out"))
			out = argv[i + 1];
	}
	if (!script || !tree || !out) {
		fprintf(stderr, "usage: qfd_test --script S --tree T --out O | --errno-table | --unit --work DIR\n");
		return 2;
	}
	return run_script(script, tree, out);
}
