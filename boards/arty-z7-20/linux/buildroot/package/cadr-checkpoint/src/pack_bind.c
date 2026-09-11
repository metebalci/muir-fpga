// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The pack binding, made and read back.  `pack_bind.h` says what it is for.

#include "pack_bind.h"

#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

// `pack_file.c`'s two, which are muir's `Geometry::T80` and `Geometry::T300`.
static const uint32_t kT80[3] = { 815, 5, 17 };
static const uint32_t kT300[3] = { 815, 19, 17 };
// "Each disk block contains one Lisp Machine page worth of data, i.e. 256.
// words or 1024. bytes."
#define BLOCK_BYTES 1024ull

void bind_init(struct binding *b)
{
	memset(b, 0, sizeof *b);
}

static uint64_t size_of(const uint32_t g[3])
{
	return (uint64_t)g[0] * g[1] * g[2] * BLOCK_BYTES;
}

int bind_geometry_of_size(uint64_t bytes, uint32_t *c, uint32_t *h, uint32_t *b)
{
	const uint32_t *g = NULL;
	if (bytes == size_of(kT300))
		g = kT300;
	else if (bytes == size_of(kT80))
		g = kT80;
	if (!g)
		return -1;
	*c = g[0];
	*h = g[1];
	*b = g[2];
	return 0;
}

static void note(char *err, size_t errlen, const char *fmt, ...)
	__attribute__((format(printf, 3, 4)));

static void note(char *err, size_t errlen, const char *fmt, ...)
{
	if (!err || errlen == 0)
		return;
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(err, errlen, fmt, ap);
	va_end(ap);
}

// One name, looked at.  `unit` is only for the message.
static int look(struct bind_pack *p, unsigned unit, char *err, size_t errlen)
{
	struct stat st;
	if (stat(p->path, &st) != 0)
		return -1;		/* not there: not an error by itself */
	if (!S_ISREG(st.st_mode)) {
		note(err, errlen, "unit %u: %s is not a regular file", unit, p->path);
		return -2;
	}
	if (bind_geometry_of_size((uint64_t)st.st_size, &p->cylinders, &p->heads,
				  &p->blocks_per_track) != 0) {
		// The same rule `pack_bay.h` states: a file is a pack only when
		// its size is a geometry's, which is also what makes a pack
		// still being copied in simply not a drive yet.
		note(err, errlen,
		     "unit %u: %s is %llu bytes, which is no drive's pack "
		     "(a T-300 is %llu, a T-80 is %llu)", unit, p->path,
		     (unsigned long long)st.st_size,
		     (unsigned long long)size_of(kT300),
		     (unsigned long long)size_of(kT80));
		return -2;
	}
	p->bytes = (uint64_t)st.st_size;
	// The write-protect switch, read from the mode as `pack_bay.h` reads
	// it: FAT's read-only attribute shows as the write bits being down.
	p->read_only = (st.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH)) == 0;
	p->present = 1;
	return 0;
}

int bind_scan(struct binding *b, const char *dir, char *err, size_t errlen)
{
	int found = 0;
	for (unsigned u = 0; u < BIND_UNITS; ++u) {
		if (b->u[u].present)
			continue;	/* named by hand already; that wins */
		struct bind_pack p;
		memset(&p, 0, sizeof p);
		snprintf(p.path, sizeof p.path, "%s/" BIND_NAME_FMT, dir, u);
		if (look(&p, u, err, errlen) != 0)
			continue;
		b->u[u] = p;
		++found;
	}
	b->present = 0;
	for (unsigned u = 0; u < BIND_UNITS; ++u)
		b->present += b->u[u].present ? 1u : 0u;
	return found;
}

int bind_add(struct binding *b, const char *spec, char *err, size_t errlen)
{
	struct bind_pack p;
	memset(&p, 0, sizeof p);
	unsigned unit = 0;
	const char *comma = strrchr(spec, ',');
	size_t n = comma ? (size_t)(comma - spec) : strlen(spec);
	if (comma) {
		char *end = NULL;
		const unsigned long v = strtoul(comma + 1, &end, 10);
		if (!end || *end != '\0' || v >= BIND_UNITS) {
			note(err, errlen, "--pack %s: the unit after the comma is "
			     "0 to %u", spec, BIND_UNITS - 1);
			return -1;
		}
		unit = (unsigned)v;
	}
	if (n == 0 || n >= sizeof p.path) {
		note(err, errlen, "--pack %s: the file's name is empty or too long",
		     spec);
		return -1;
	}
	memcpy(p.path, spec, n);
	p.path[n] = '\0';
	const int r = look(&p, unit, err, errlen);
	if (r == -1) {
		note(err, errlen, "--pack %s: %s: %s", spec, p.path, strerror(errno));
		return -1;
	}
	if (r != 0)
		return -1;		/* `look` has said why */
	b->u[unit] = p;
	b->present = 0;
	for (unsigned u = 0; u < BIND_UNITS; ++u)
		b->present += b->u[u].present ? 1u : 0u;
	return 0;
}

int bind_digest(struct binding *b, char *err, size_t errlen)
{
	for (unsigned u = 0; u < BIND_UNITS; ++u) {
		if (!b->u[u].present)
			continue;
		uint64_t bytes = 0;
		if (sha256_file(b->u[u].path, b->u[u].sha256, &bytes) != 0) {
			note(err, errlen, "unit %u: %s: %s", u, b->u[u].path,
			     strerror(errno));
			return -1;
		}
		// The size is taken twice, at the stat and at the read, and they
		// must agree.  A pack that grew or shrank between them is a pack
		// something else is writing, which is exactly the thing this
		// binding exists to rule out.
		if (bytes != b->u[u].bytes) {
			note(err, errlen,
			     "unit %u: %s was %llu bytes and read %llu --- something "
			     "is writing it; stop cadr-disk-packs first",
			     u, b->u[u].path, (unsigned long long)b->u[u].bytes,
			     (unsigned long long)bytes);
			return -1;
		}
	}
	return 0;
}

// --- the sidecar -----------------------------------------------------------

void bind_resume_command(const struct binding *b, const char *chk, char *out, size_t n)
{
	size_t at = 0;
	at += (size_t)snprintf(out + at, at < n ? n - at : 0, "muir --rtl");
	for (unsigned u = 0; u < BIND_UNITS; ++u) {
		if (!b->u[u].present)
			continue;
		at += (size_t)snprintf(out + at, at < n ? n - at : 0,
				       " --disk-pack %s,%u", b->u[u].path, u);
	}
	snprintf(out + at, at < n ? n - at : 0, " --main-memory-boards %u --resume %s",
		 b->boards, chk);
}

int bind_write(const struct binding *b, const char *path, char *err, size_t errlen)
{
	FILE *f = fopen(path, "w");
	if (!f) {
		note(err, errlen, "%s: %s", path, strerror(errno));
		return -1;
	}
	fprintf(f,
		"# The disk packs the machine in the checkpoint beside this file was\n"
		"# running on, and what every byte of them was at the instant the\n"
		"# checkpoint was taken.\n"
		"#\n"
		"# **A CHECKPOINT DOES NOT CARRY ITS DISK.**  muir's format holds the\n"
		"# blocks a run has written and never the pack, so resuming this\n"
		"# checkpoint over a pack that has moved on restores a machine into a\n"
		"# disk it never had --- and NOTHING WILL SAY SO.  muir refuses a\n"
		"# missing drive and a wrong geometry, and has no way at all to notice\n"
		"# wrong contents: the disk controller recomputes a block's header and\n"
		"# checkwords as it moves it, so a block from another moment passes\n"
		"# every check the machine makes and is handed to the microcode as\n"
		"# good. What goes wrong afterwards is a Lisp world whose structures\n"
		"# point at the wrong pages, which looks like anything at all.\n"
		"#\n"
		"# BEFORE RESUMING, check each pack against the digest below:\n"
		"#     sha256sum <the pack>\n"
		"# or, with this file in hand,\n"
		"#     cadr-checkpoint --verify <this file>\n"
		"#\n"
		"# One `key: value` a line.  A `pack:` line's fields are `name=value`\n"
		"# separated by single spaces, and `file=` is LAST because a path may\n"
		"# hold a space and nothing else may.\n"
		"\n");
	fprintf(f, "format: %s\n", BIND_FORMAT);
	fprintf(f, "checkpoint: %s\n", b->checkpoint);
	fprintf(f, "checkpoint-bytes: %llu\n", (unsigned long long)b->checkpoint_bytes);
	fprintf(f, "checkpoint-sha256: %s\n", b->checkpoint_sha);
	fprintf(f, "taken: %s\n", b->taken);
	fprintf(f, "engine: rtl\n");
	fprintf(f, "boards: %u\n", b->boards);
	fprintf(f, "microcycles: %llu\n", (unsigned long long)b->microcycles);
	fprintf(f, "ns: %llu\n", (unsigned long long)b->ns);
	fprintf(f, "machine-halted-first: %s\n", b->machine_halted_first ? "yes" : "no");
	fprintf(f, "packs-program-stopped: %s\n", b->packs_program_stopped ? "yes" : "unknown");
	fprintf(f, "packs: %u\n", b->present);
	for (unsigned u = 0; u < BIND_UNITS; ++u) {
		if (!b->u[u].present)
			continue;
		fprintf(f,
			"pack: unit=%u bytes=%llu geometry=%u,%u,%u read-only=%s "
			"sha256=%s file=%s\n",
			u, (unsigned long long)b->u[u].bytes, b->u[u].cylinders,
			b->u[u].heads, b->u[u].blocks_per_track,
			b->u[u].read_only ? "yes" : "no", b->u[u].sha256,
			b->u[u].path);
	}
	char cmd[4096];
	bind_resume_command(b, b->checkpoint, cmd, sizeof cmd);
	fprintf(f, "resume: %s\n", cmd);
	const int ok = !ferror(f);
	if (fclose(f) != 0 || !ok) {
		note(err, errlen, "%s: %s", path, strerror(errno));
		return -1;
	}
	return 0;
}

// `key: rest`, with the key matched exactly.  Returns `rest` or NULL.
static const char *field(const char *line, const char *key)
{
	const size_t n = strlen(key);
	if (strncmp(line, key, n) != 0 || line[n] != ':' || line[n + 1] != ' ')
		return NULL;
	return line + n + 2;
}

// `name=` inside a `pack:` line's rest, into `out`.  A value ends at the next
// space, except `file=`, which runs to the end of the line.
static int subfield(const char *rest, const char *name, char *out, size_t n)
{
	const size_t k = strlen(name);
	for (const char *p = rest; *p; ) {
		const char *e = strchr(p, ' ');
		const size_t len = e ? (size_t)(e - p) : strlen(p);
		if (len > k && strncmp(p, name, k) == 0 && p[k] == '=') {
			const char *v = p + k + 1;
			size_t vlen = len - k - 1;
			if (strcmp(name, "file") == 0)
				vlen = strlen(v);	/* to the end of the line */
			if (vlen >= n)
				return -1;
			memcpy(out, v, vlen);
			out[vlen] = '\0';
			return 0;
		}
		if (!e)
			break;
		p = e + 1;
	}
	return -1;
}

int bind_read(struct binding *b, const char *path, char *err, size_t errlen)
{
	FILE *f = fopen(path, "r");
	if (!f) {
		note(err, errlen, "%s: %s", path, strerror(errno));
		return -1;
	}
	bind_init(b);
	char line[8192];
	int saw_format = 0;
	while (fgets(line, sizeof line, f)) {
		size_t n = strlen(line);
		while (n && (line[n - 1] == '\n' || line[n - 1] == '\r'))
			line[--n] = '\0';
		if (line[0] == '#' || line[0] == '\0')
			continue;
		const char *v;
		if ((v = field(line, "format")) != NULL) {
			if (strcmp(v, BIND_FORMAT) != 0) {
				note(err, errlen, "%s: format \"%s\", and this program "
				     "writes \"%s\"", path, v, BIND_FORMAT);
				fclose(f);
				return -1;
			}
			saw_format = 1;
		} else if ((v = field(line, "checkpoint")) != NULL) {
			snprintf(b->checkpoint, sizeof b->checkpoint, "%s", v);
		} else if ((v = field(line, "checkpoint-sha256")) != NULL) {
			snprintf(b->checkpoint_sha, sizeof b->checkpoint_sha, "%s", v);
		} else if ((v = field(line, "checkpoint-bytes")) != NULL) {
			b->checkpoint_bytes = strtoull(v, NULL, 10);
		} else if ((v = field(line, "taken")) != NULL) {
			snprintf(b->taken, sizeof b->taken, "%s", v);
		} else if ((v = field(line, "boards")) != NULL) {
			b->boards = (unsigned)strtoul(v, NULL, 10);
		} else if ((v = field(line, "microcycles")) != NULL) {
			b->microcycles = strtoull(v, NULL, 10);
		} else if ((v = field(line, "ns")) != NULL) {
			b->ns = strtoull(v, NULL, 10);
		} else if ((v = field(line, "pack")) != NULL) {
			char buf[1024];
			if (subfield(v, "unit", buf, sizeof buf) != 0) {
				note(err, errlen, "%s: a pack line with no unit", path);
				fclose(f);
				return -1;
			}
			const unsigned u = (unsigned)strtoul(buf, NULL, 10);
			if (u >= BIND_UNITS) {
				note(err, errlen, "%s: unit %u, and there are %u",
				     path, u, BIND_UNITS);
				fclose(f);
				return -1;
			}
			struct bind_pack *p = &b->u[u];
			memset(p, 0, sizeof *p);
			p->present = 1;
			if (subfield(v, "file", p->path, sizeof p->path) != 0 ||
			    subfield(v, "sha256", p->sha256, sizeof p->sha256) != 0) {
				note(err, errlen, "%s: unit %u has no file or no digest",
				     path, u);
				fclose(f);
				return -1;
			}
			if (subfield(v, "bytes", buf, sizeof buf) == 0)
				p->bytes = strtoull(buf, NULL, 10);
			if (subfield(v, "geometry", buf, sizeof buf) == 0)
				sscanf(buf, "%u,%u,%u", &p->cylinders, &p->heads,
				       &p->blocks_per_track);
			if (subfield(v, "read-only", buf, sizeof buf) == 0)
				p->read_only = strcmp(buf, "yes") == 0;
			++b->present;
		}
	}
	fclose(f);
	if (!saw_format) {
		note(err, errlen, "%s: no format line; this is not a pack binding",
		     path);
		return -1;
	}
	return 0;
}

int bind_verify(struct binding *b, int *chk_moved, char *err, size_t errlen)
{
	int moved = 0;
	*chk_moved = 0;
	if (b->checkpoint[0] && b->checkpoint_sha[0]) {
		char hex[SHA256_HEX];
		uint64_t bytes = 0;
		if (sha256_file(b->checkpoint, hex, &bytes) != 0) {
			note(err, errlen, "the checkpoint %s: %s", b->checkpoint,
			     strerror(errno));
			return -1;
		}
		if (strcmp(hex, b->checkpoint_sha) != 0)
			*chk_moved = 1;
	}
	for (unsigned u = 0; u < BIND_UNITS; ++u) {
		if (!b->u[u].present)
			continue;
		uint64_t bytes = 0;
		if (sha256_file(b->u[u].path, b->u[u].now, &bytes) != 0) {
			note(err, errlen, "unit %u: %s: %s", u, b->u[u].path,
			     strerror(errno));
			return -1;
		}
		if (strcmp(b->u[u].now, b->u[u].sha256) != 0) {
			b->u[u].moved = 1;
			++moved;
		}
	}
	return moved;
}
