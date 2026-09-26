// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's file device, the Linux side: the protocol core.  `qfd.h` says what
// this is held to.  Each function below names the function of muir's
// `src/file_device.rs` it follows, and follows it in the same order of
// checks, because the order decides which status a command with two faults
// answers.

#define _GNU_SOURCE
#include "qfd.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE 1
#endif

// --- the host's calls ---------------------------------------------------------------
//
// The few that can fail with an errno a Linux folder of the build host never
// gives (FAT's EINVAL for a name it refuses) go through here, so the check can
// give them one.  Outside the check these are the calls themselves.

#ifdef QFD_TEST_HOOKS
int qfd_hook_errno;
const char *qfd_hook_folding;
#define HOOK()                                                                                     \
	do {                                                                                       \
		if (qfd_hook_errno) {                                                              \
			errno = qfd_hook_errno;                                                    \
			return -1;                                                                 \
		}                                                                                  \
	} while (0)
#else
#define HOOK() do { } while (0)
#endif

static int h_lstat(const char *p, struct stat *st)
{
	const int r = lstat(p, st);
#ifdef QFD_TEST_HOOKS
	// A folder that folds case, as FAT does: a name missing as spelled is
	// found as any spelling of it.
	if (r != 0 && errno == ENOENT && qfd_hook_folding) {
		const char *slash = strrchr(p, '/');
		const size_t dl = slash ? (size_t)(slash - p) : 0;
		if (slash && strlen(qfd_hook_folding) == dl && !strncmp(p, qfd_hook_folding, dl)) {
			DIR *d = opendir(qfd_hook_folding);
			struct dirent *e;
			int found = -1;
			while (d && (e = readdir(d))) {
				if (!strcasecmp(e->d_name, slash + 1)) {
					char q[PATH_MAX];
					snprintf(q, sizeof q, "%s/%s", qfd_hook_folding, e->d_name);
					found = lstat(q, st);
					break;
				}
			}
			if (d)
				closedir(d);
			if (found == 0)
				return 0;
			errno = ENOENT;
		}
	}
#endif
	return r;
}

static int h_create(const char *p)
{
	HOOK();
	return open(p, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0666);
}

static int h_mkdir(const char *p)
{
	HOOK();
	return mkdir(p, 0777);
}

static int h_rename(const char *from, const char *to)
{
	HOOK();
	return rename(from, to);
}

static int h_renameat2(const char *from, const char *to)
{
	HOOK();
	return (int)syscall(SYS_renameat2, AT_FDCWD, from, AT_FDCWD, to, RENAME_NOREPLACE);
}

// --- small things ---------------------------------------------------------------

static char *dup_or_die(const char *s)
{
	char *d = strdup(s);
	if (!d) {
		perror("quux-file-device");
		abort();
	}
	return d;
}

static char *join(const char *dir, const char *name)
{
	const size_t a = strlen(dir), b = strlen(name);
	char *p = malloc(a + b + 2);
	if (!p) {
		perror("quux-file-device");
		abort();
	}
	memcpy(p, dir, a);
	p[a] = '/';
	memcpy(p + a + 1, name, b + 1);
	return p;
}

// muir's `valid_component`: 1-255 bytes in 040-176 other than `/`, and not
// `.` or `..`.
static int valid_component(const uint8_t *c, size_t n)
{
	if (n < 1 || n > QFD_MAX_COMPONENT)
		return 0;
	for (size_t i = 0; i < n; ++i)
		if (c[i] < 040 || c[i] > 0176 || c[i] == '/')
			return 0;
	if (n == 1 && c[0] == '.')
		return 0;
	if (n == 2 && c[0] == '.' && c[1] == '.')
		return 0;
	return 1;
}

// Path::starts_with, a component at a time: `/a/bc` is not inside `/a/b`.
static int inside(const char *path, const char *root)
{
	const size_t n = strlen(root);
	if (n == 1 && root[0] == '/')
		return path[0] == '/';
	return !strncmp(path, root, n) && (path[n] == '/' || path[n] == '\0');
}

uint32_t qfd_errno_status(int e)
{
	// muir's `host_status`, which goes by Rust's error kinds: the errnos
	// that are each kind on Linux (library/std/src/sys/pal/unix/mod.rs,
	// `decode_error_kind`), and ELOOP first.
	switch (e) {
	case ELOOP: return QFD_ACC;
	case ENOENT: return QFD_FNF;
	case ENOTDIR: return QFD_DNF;
	case EACCES:
	case EPERM: return QFD_ACC;
	case EROFS: return QFD_ATF;
	case ENOSPC:
	case EDQUOT: return QFD_NMR;
	case EINVAL:
	case ENAMETOOLONG: return QFD_IPS;
	case ENOTEMPTY: return QFD_DNE;
	case EEXIST: return QFD_FAE;
	case EISDIR: return QFD_IOD;
	default: return QFD_DAT;
	}
}

static uint32_t mtime_of(const struct stat *st)
{
	if (st->st_mtime < 0)
		return 0;
	if ((unsigned long long)st->st_mtime > 0xFFFFFFFFull)
		return 0xFFFFFFFFu;
	return (uint32_t)st->st_mtime;
}

void qfd_log_line(const uint8_t *bytes, size_t n, char *out)
{
	char *o = out + sprintf(out, "log: ");
	for (size_t i = 0; i < n; ++i) {
		if (bytes[i] >= 040 && bytes[i] <= 0176)
			*o++ = (char)bytes[i];
		else
			o += sprintf(o, "\\%03o", bytes[i]);
	}
	*o = '\0';
}

const char *qfd_checkpoint_refusal(unsigned handles, unsigned queued, char *buf, size_t len)
{
	if (handles == 0 && queued == 0)
		return NULL;
	snprintf(buf, len,
		 "the file device has %u %s and %u %s; a checkpoint waits until every handle is "
		 "closed and every command answered",
		 handles, handles == 1 ? "handle open" : "handles open",
		 queued, queued == 1 ? "command queued" : "commands queued");
	return buf;
}

// --- mounts --------------------------------------------------------------------

void qfd_init(struct qfd *d)
{
	memset(d, 0, sizeof *d);
	for (int k = 0; k < QFD_MAX_HANDLES; ++k)
		d->h[k].fd = -1;
}

int qfd_mount_add(struct qfd_mounts *m, const char *spec_in, char *why, size_t whylen)
{
	char *spec = dup_or_die(spec_in);
	int ro = 0;
	const size_t sl = strlen(spec);
	if (sl >= 3 && !strcmp(spec + sl - 3, ",ro")) {
		spec[sl - 3] = '\0';
		ro = 1;
	}
	char *name = NULL, *folder = spec;
	char *eq = strchr(spec, '=');
	if (eq && valid_component((const uint8_t *)spec, (size_t)(eq - spec))) {
		*eq = '\0';
		name = spec;
		folder = eq + 1;
	}
	char real[PATH_MAX];
	struct stat st;
	if (!realpath(folder, real)) {
		snprintf(why, whylen, "%s: %s", folder, strerror(errno));
		free(spec);
		return -1;
	}
	if (stat(real, &st) != 0 || !S_ISDIR(st.st_mode)) {
		snprintf(why, whylen, "%s is not a folder", folder);
		free(spec);
		return -1;
	}
	struct qfd_mount mt = { name ? dup_or_die(name) : NULL, dup_or_die(folder), dup_or_die(real), ro };
	free(spec);
	if (mt.name) {
		int at = 0;
		while (at < m->n && strcmp(m->named[at].name, mt.name) < 0)
			++at;
		if (at < m->n && !strcmp(m->named[at].name, mt.name)) {
			snprintf(why, whylen, "%s is mounted twice", mt.name);
			goto refuse;
		}
		if (m->n == QFD_MAX_MOUNTS) {
			snprintf(why, whylen, "more than %d named mounts", QFD_MAX_MOUNTS);
			goto refuse;
		}
		memmove(&m->named[at + 1], &m->named[at], (size_t)(m->n - at) * sizeof m->named[0]);
		m->named[at] = mt;
		m->n++;
	} else {
		if (m->has_default) {
			snprintf(why, whylen, "a second default folder: there is one default, HOST's /");
			goto refuse;
		}
		m->def = mt;
		m->has_default = 1;
	}
	return 0;
refuse:
	free(mt.name);
	free(mt.given);
	free(mt.path);
	return -1;
}

void qfd_mounts_describe(const struct qfd_mounts *m, void (*emit)(void *, const char *), void *ctx)
{
	char line[PATH_MAX + 300];
	if (m->has_default) {
		snprintf(line, sizeof line, "/ is %s, %s", m->def.given, m->def.ro ? "read-only" : "read-write");
		emit(ctx, line);
	} else if (m->n == 0) {
		emit(ctx, "/ is empty and read-only: nothing is mounted");
	} else {
		emit(ctx, "/ holds the mounts alone, read-only");
	}
	for (int k = 0; k < m->n; ++k) {
		snprintf(line, sizeof line, "/%s is %s, %s", m->named[k].name, m->named[k].given,
			 m->named[k].ro ? "read-only" : "read-write");
		emit(ctx, line);
	}
}

static const struct qfd_mount *named_mount(const struct qfd_mounts *m, const char *name)
{
	for (int k = 0; k < m->n; ++k)
		if (!strcmp(m->named[k].name, name))
			return &m->named[k];
	return NULL;
}

// --- names ------------------------------------------------------------------------

// A name's components: muir's `parse_name`.  Absolute, at most 1,024
// bytes, a single trailing `/` allowed.
struct comps {
	int n;
	char *c[QFD_MAX_NAME / 2 + 1];
};

static void comps_free(struct comps *cs)
{
	for (int k = 0; k < cs->n; ++k)
		free(cs->c[k]);
	cs->n = 0;
}

static uint32_t parse_name(const uint8_t *b, size_t n, struct comps *cs)
{
	cs->n = 0;
	if (n == 0 || n > QFD_MAX_NAME || b[0] != '/')
		return QFD_IPS;
	const uint8_t *body = b + 1;
	size_t bl = n - 1;
	if (bl > 0 && body[bl - 1] == '/')
		--bl;
	if (bl == 0)
		return QFD_OK;
	size_t start = 0;
	for (size_t i = 0; i <= bl; ++i) {
		if (i == bl || body[i] == '/') {
			if (!valid_component(body + start, i - start)) {
				comps_free(cs);
				return QFD_IPS;
			}
			char *c = malloc(i - start + 1);
			if (!c)
				abort();
			memcpy(c, body + start, i - start);
			c[i - start] = '\0';
			cs->c[cs->n++] = c;
			start = i + 1;
		}
	}
	return QFD_OK;
}

// Which mount a name is under: muir's `place`.
enum key { KEY_DEFAULT, KEY_NAMED, KEY_BARE };

struct place {
	enum key key;
	const char *named;   // KEY_NAMED: the mount's name
	const char *root;    // NULL for KEY_BARE
	int ro;
	char **rel;          // the components below the mount's folder
	int nrel;
};

static void place(const struct qfd *d, const struct comps *cs, struct place *p)
{
	const struct qfd_mount *m = cs->n ? named_mount(&d->mounts, cs->c[0]) : NULL;
	if (m) {
		*p = (struct place){ KEY_NAMED, m->name, m->path, m->ro, (char **)cs->c + 1, cs->n - 1 };
		return;
	}
	if (d->mounts.has_default)
		*p = (struct place){ KEY_DEFAULT, NULL, d->mounts.def.path, d->mounts.def.ro,
				     (char **)cs->c, cs->n };
	else
		*p = (struct place){ KEY_BARE, NULL, NULL, 1, (char **)cs->c, cs->n };
}

static int same_key(const struct place *a, const struct place *b)
{
	if (a->key != b->key)
		return 0;
	return a->key != KEY_NAMED || !strcmp(a->named, b->named);
}

// muir's `exact_case`: whether `name`, found under `dir`, is spelled there
// as asked.  A folder that folds case finds a name spelled otherwise, and its
// case-flipped twin as the same file; then the folder's own list decides.
static int exact_case(const char *dir, const char *name, const struct stat *found)
{
	int alpha = 0;
	for (const char *c = name; *c; ++c)
		if ((*c >= 'a' && *c <= 'z') || (*c >= 'A' && *c <= 'Z'))
			alpha = 1;
	if (!alpha)
		return 1;
	char *flipped = dup_or_die(name);
	for (char *c = flipped; *c; ++c) {
		if (*c >= 'a' && *c <= 'z')
			*c = (char)(*c - 'a' + 'A');
		else if (*c >= 'A' && *c <= 'Z')
			*c = (char)(*c - 'A' + 'a');
	}
	char *fp = join(dir, flipped);
	free(flipped);
	struct stat st;
	const int twin = h_lstat(fp, &st) == 0 && st.st_dev == found->st_dev && st.st_ino == found->st_ino;
	free(fp);
	if (!twin)
		return 1;
	DIR *dd = opendir(dir);
	if (!dd)
		return 0;
	int spelled = 0;
	struct dirent *e;
	while ((e = readdir(dd)))
		if (!strcmp(e->d_name, name))
			spelled = 1;
	closedir(dd);
	return spelled;
}

// A name looked up: muir's `Found`.
struct found {
	char *parent;
	char *path;
	int has;          // meta is there
	struct stat meta;
};

static void found_free(struct found *f)
{
	free(f->parent);
	free(f->path);
	f->parent = f->path = NULL;
}

// muir's `lookup`: every directory on the way resolved inside the mount's
// folder (DNF if one is missing or a file, ACC if a symlink leaves or loops),
// and the last one followed if `follow`.
static uint32_t lookup(const struct place *p, int follow, struct found *f)
{
	memset(f, 0, sizeof *f);
	if (!p->root) {
		if (p->nrel == 0)
			return QFD_IOD;
		if (p->nrel == 1) {
			f->parent = dup_or_die("");
			f->path = dup_or_die("");
			return QFD_OK;
		}
		return QFD_DNF;
	}
	char *cur = dup_or_die(p->root);
	if (p->nrel == 0) {
		if (stat(p->root, &f->meta) != 0) {
			const int e = errno;
			free(cur);
			return qfd_errno_status(e);
		}
		f->has = 1;
		f->parent = cur;
		f->path = dup_or_die(p->root);
		return QFD_OK;
	}
	for (int k = 0; k < p->nrel; ++k) {
		const int last = k + 1 == p->nrel;
		char *here = join(cur, p->rel[k]);
		struct stat lm;
		int have = 0;
		if (h_lstat(here, &lm) == 0) {
			have = exact_case(cur, p->rel[k], &lm);
		} else if (errno != ENOENT && errno != ENOTDIR) {
			const int e = errno;
			free(here);
			free(cur);
			return qfd_errno_status(e);
		}
		if (!have) {
			if (last) {
				f->parent = cur;
				f->path = here;
				return QFD_OK;
			}
			free(here);
			free(cur);
			return QFD_DNF;
		}
		char *path;
		struct stat meta;
		if (S_ISLNK(lm.st_mode) && (follow || !last)) {
			char real[PATH_MAX];
			if (realpath(here, real)) {
				if (!inside(real, p->root)) {
					free(here);
					free(cur);
					return QFD_ACC;
				}
				if (stat(real, &meta) != 0) {
					const int e = errno;
					free(here);
					free(cur);
					return qfd_errno_status(e);
				}
				path = dup_or_die(real);
				free(here);
			} else if (errno == ENOENT) {
				if (last) {
					f->parent = cur;
					f->path = here;
					return QFD_OK;
				}
				free(here);
				free(cur);
				return QFD_DNF;
			} else {
				const int e = errno;
				free(here);
				free(cur);
				return qfd_errno_status(e);
			}
		} else {
			// A symlink kept as itself must still stay inside.
			if (S_ISLNK(lm.st_mode)) {
				char real[PATH_MAX];
				if (!realpath(here, real) || !inside(real, p->root)) {
					free(here);
					free(cur);
					return QFD_ACC;
				}
			}
			path = here;
			meta = lm;
		}
		if (last) {
			f->parent = cur;
			f->path = path;
			f->has = 1;
			f->meta = meta;
			return QFD_OK;
		}
		if (!S_ISDIR(meta.st_mode)) {
			free(path);
			free(cur);
			return QFD_DNF;
		}
		free(cur);
		cur = path;
	}
	free(cur);
	return QFD_DNF;
}

// --- directory entries ------------------------------------------------------------

struct entry {
	char *name;
	int dir;
	int ro;
	uint64_t len;
	uint32_t mtime;
};

struct entries {
	int n, cap;
	struct entry *e;
};

static void entries_free(struct entries *es)
{
	for (int k = 0; k < es->n; ++k)
		free(es->e[k].name);
	free(es->e);
	memset(es, 0, sizeof *es);
}

static void entries_push(struct entries *es, const char *name, const struct stat *m, int ro)
{
	if (es->n == es->cap) {
		es->cap = es->cap ? 2 * es->cap : 32;
		es->e = realloc(es->e, (size_t)es->cap * sizeof es->e[0]);
		if (!es->e)
			abort();
	}
	const int dir = S_ISDIR(m->st_mode);
	es->e[es->n++] = (struct entry){ dup_or_die(name), dir, ro, dir ? 0 : (uint64_t)m->st_size,
					 mtime_of(m) };
}

static int by_name(const void *a, const void *b)
{
	return strcmp(((const struct entry *)a)->name, ((const struct entry *)b)->name);
}

static void entries_sort(struct entries *es)
{
	if (es->n > 1)
		qsort(es->e, (size_t)es->n, sizeof es->e[0], by_name);
}

// muir's `list_folder`: files and directories, sorted bytewise, dot files
// with them; not the temporary files, not a name the rules refuse, not a
// symlink that leaves `root` or leads nowhere, and not anything else.
static uint32_t list_folder(const char *dir, const char *root, int ro, struct entries *es)
{
	DIR *d = opendir(dir);
	if (!d)
		return qfd_errno_status(errno);
	struct dirent *e;
	errno = 0;
	while ((e = readdir(d))) {
		const char *name = e->d_name;
		if (!valid_component((const uint8_t *)name, strlen(name))
		    || !strncmp(name, QFD_TEMP_PREFIX, strlen(QFD_TEMP_PREFIX)))
			continue;
		char *p = join(dir, name);
		struct stat lm, m;
		int ok = h_lstat(p, &lm) == 0;
		if (ok && S_ISLNK(lm.st_mode)) {
			char real[PATH_MAX];
			ok = realpath(p, real) && inside(real, root) && stat(real, &m) == 0;
		} else if (ok) {
			m = lm;
		}
		free(p);
		if (ok && (S_ISREG(m.st_mode) || S_ISDIR(m.st_mode)))
			entries_push(es, name, &m, ro);
		errno = 0;
	}
	const int e2 = errno;
	closedir(d);
	if (e2) {
		entries_free(es);
		return qfd_errno_status(e2);
	}
	entries_sort(es);
	return QFD_OK;
}

// muir's `list`: the entries of the directory `cs` names; the mounts and the
// default folder's entries at `/`.
static uint32_t list(const struct qfd *d, const struct comps *cs, struct entries *es)
{
	memset(es, 0, sizeof *es);
	if (cs->n == 0) {
		if (d->mounts.has_default) {
			const uint32_t s = list_folder(d->mounts.def.path, d->mounts.def.path, d->mounts.def.ro, es);
			if (s)
				return s;
		}
		int keep = 0;
		for (int k = 0; k < es->n; ++k) {
			if (named_mount(&d->mounts, es->e[k].name))
				free(es->e[k].name);
			else
				es->e[keep++] = es->e[k];
		}
		es->n = keep;
		for (int k = 0; k < d->mounts.n; ++k) {
			struct stat st;
			if (stat(d->mounts.named[k].path, &st) != 0) {
				const int e = errno;
				entries_free(es);
				return qfd_errno_status(e);
			}
			entries_push(es, d->mounts.named[k].name, &st, d->mounts.named[k].ro);
		}
		entries_sort(es);
		return QFD_OK;
	}
	struct place p;
	place(d, cs, &p);
	struct found f;
	uint32_t s = lookup(&p, 1, &f);
	if (s)
		return s;
	if (!f.has)
		s = QFD_DNF;
	else if (S_ISDIR(f.meta.st_mode))
		s = list_folder(f.path, p.root, p.ro, es);
	else
		s = QFD_WKF;
	found_free(&f);
	return s;
}

// --- main memory ------------------------------------------------------------------

static uint32_t rd(struct qfd_mem *m, size_t k)
{
	if (m->touch)
		m->touch(m->ctx);
	return m->w[k];
}

static void wr(struct qfd_mem *m, size_t k, uint32_t v)
{
	if (m->touch)
		m->touch(m->ctx);
	m->w[k] = v;
}

struct buf {
	size_t at;
	uint32_t len;
};

// muir's `buffer`: on a 4-word line, at most 65,536 bytes, inside main memory.
static uint32_t buffer(struct qfd_mem *m, uint32_t addr, uint32_t len, struct buf *b)
{
	const size_t at = addr & 0xFFFFFFu;
	if ((at & 3) || len > QFD_MAX_BUFFER || at + (len + 3u) / 4u > m->words)
		return QFD_BAD_BUFFER;
	b->at = at;
	b->len = len;
	return QFD_OK;
}

// Byte k of a buffer is <8(k mod 4)+7 : 8(k mod 4)> of word k/4.
static uint8_t *bytes_of(struct qfd_mem *m, struct buf b)
{
	uint8_t *out = malloc(b.len + 1);
	if (!out)
		abort();
	for (uint32_t w = 0; w < (b.len + 3u) / 4u; ++w) {
		const uint32_t v = rd(m, b.at + w);
		for (uint32_t k = 0; k < 4 && 4 * w + k < b.len; ++k)
			out[4 * w + k] = (uint8_t)(v >> (8 * k));
	}
	out[b.len] = 0;
	return out;
}

// `data` into the buffer at `at`: ceil(n/4) words, the bytes past n in the
// last one 0, and no other word.
static void put_bytes(struct qfd_mem *m, size_t at, const uint8_t *data, size_t n)
{
	for (size_t w = 0; w < (n + 3) / 4; ++w) {
		uint32_t v = 0;
		for (size_t k = 0; k < 4 && 4 * w + k < n; ++k)
			v |= (uint32_t)data[4 * w + k] << (8 * k);
		wr(m, at + w, v);
	}
}

// --- the commands -------------------------------------------------------------------

// The words of a response past word 0: muir's `Reply`.
struct reply {
	uint32_t w[7];
};
#define R_COUNT  0
#define R_HANDLE 1
#define R_LEN    2
#define R_MTIME  3
#define R_FLAGS  4
#define R_W6     5

static void r_len(struct reply *r, uint64_t v)
{
	r->w[R_LEN] = v > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)v;
}

static void handle_close(struct qfd_handle *h, int remove_temp)
{
	if (h->fd >= 0)
		close(h->fd);
	if (remove_temp && h->temp)
		unlink(h->temp);
	free(h->temp);
	free(h->target);
	*h = (struct qfd_handle){ 0, -1, NULL, NULL, 0, 0 };
}

void qfd_reset(struct qfd *d)
{
	for (int k = 0; k < QFD_MAX_HANDLES; ++k)
		if (d->h[k].kind)
			handle_close(&d->h[k], 1);
}

unsigned qfd_handles_open(const struct qfd *d)
{
	unsigned n = 0;
	for (int k = 0; k < QFD_MAX_HANDLES; ++k)
		n += d->h[k].kind != 0;
	return n;
}

static struct qfd_handle *handle(struct qfd *d, uint32_t h)
{
	if (h < 1 || h > QFD_MAX_HANDLES || !d->h[h - 1].kind)
		return NULL;
	return &d->h[h - 1];
}

static int free_handle(const struct qfd *d)
{
	for (int k = 0; k < QFD_MAX_HANDLES; ++k)
		if (!d->h[k].kind)
			return k;
	return -1;
}

static void entry_reply(struct reply *r, const struct stat *m, int ro)
{
	const int dir = S_ISDIR(m->st_mode);
	r_len(r, dir ? 0 : (uint64_t)m->st_size);
	r->w[R_MTIME] = mtime_of(m);
	r->w[R_FLAGS] = (uint32_t)dir | (uint32_t)ro << 1;
}

// muir's `open_write`.
static uint32_t open_write(struct qfd *d, const struct place *p, uint32_t if_exists, int if_none_error,
			   struct reply *r)
{
	if (p->key == KEY_BARE && p->nrel > 1)
		return QFD_DNF;
	if (p->ro)
		return QFD_ATF;
	if (p->nrel == 0)
		return QFD_IOD;
	struct found f;
	uint32_t s = lookup(p, 1, &f);
	if (s)
		return s;
	uint64_t held = 0;
	if (f.has && S_ISDIR(f.meta.st_mode))
		s = QFD_IOD;
	else if (f.has && !S_ISREG(f.meta.st_mode))
		s = QFD_WKF;
	else if (f.has && if_exists == 1)
		s = QFD_FAE;
	else if (f.has && if_exists == 2) {
		if ((uint64_t)f.meta.st_size > 0xFFFFFFFFull)
			s = QFD_WKF;
		held = (uint64_t)f.meta.st_size;
	} else if (!f.has && if_none_error)
		s = QFD_FNF;
	int k = -1;
	if (!s && (k = free_handle(d)) < 0)
		s = QFD_NER;
	if (s) {
		found_free(&f);
		return s;
	}
	// The temporary file goes in the folder the target is in.
	char *dir = dup_or_die(f.path);
	char *slash = strrchr(dir, '/');
	if (slash && slash != dir)
		*slash = '\0';
	else if (slash)
		slash[1] = '\0';
	char tname[64];
	snprintf(tname, sizeof tname, QFD_TEMP_PREFIX "%ld-%llu", (long)getpid(),
		 (unsigned long long)d->temps++);
	char *temp = join(dir, tname);
	free(dir);
	const int fd = h_create(temp);
	if (fd < 0) {
		const int e = errno;
		free(temp);
		found_free(&f);
		return qfd_errno_status(e);
	}
	if (f.has) {
		// The file keeps its permissions across the write.
		(void)chmod(temp, f.meta.st_mode & 07777);
		if (if_exists == 2) {
			const int from = open(f.path, O_RDONLY | O_CLOEXEC);
			uint64_t copied = 0;
			int e = 0;
			if (from < 0) {
				e = errno;
			} else {
				char chunk[65536];
				for (;;) {
					const ssize_t n = read(from, chunk, sizeof chunk);
					if (n < 0 && errno == EINTR)
						continue;
					if (n < 0) {
						e = errno;
						break;
					}
					if (n == 0)
						break;
					for (ssize_t o = 0; o < n;) {
						const ssize_t w = write(fd, chunk + o, (size_t)(n - o));
						if (w < 0 && errno == EINTR)
							continue;
						if (w <= 0) {
							e = w < 0 ? errno : EIO;
							break;
						}
						o += w;
					}
					if (e)
						break;
					copied += (uint64_t)n;
				}
				close(from);
			}
			if (e) {
				close(fd);
				unlink(temp);
				free(temp);
				found_free(&f);
				return qfd_errno_status(e);
			}
			held = copied;
		}
	}
	d->h[k] = (struct qfd_handle){ 2, fd, temp, f.path, if_exists == 1, held };
	f.path = NULL;
	found_free(&f);
	r->w[R_HANDLE] = (uint32_t)k + 1;
	r_len(r, held);
	return QFD_OK;
}

// muir's `open`: read, write or probe.
static uint32_t cmd_open(struct qfd *d, uint32_t flags, const uint8_t *name, size_t n, struct reply *r)
{
	const uint32_t mode = flags & 3, if_exists = (flags >> 2) & 3;
	const int if_none_error = (flags >> 4) & 1;
	if (mode == 3 || if_exists == 3)
		return QFD_BAD_ARGUMENT;
	struct comps cs;
	uint32_t s = parse_name(name, n, &cs);
	if (s)
		return s;
	struct place p;
	place(d, &cs, &p);
	const uint32_t ro_bit = (uint32_t)p.ro << 1;
	if (mode == 1) {
		s = open_write(d, &p, if_exists, if_none_error, r);
		comps_free(&cs);
		return s;
	}
	if (p.key == KEY_BARE && p.nrel == 0) {
		comps_free(&cs);
		if (mode == 0)
			return QFD_IOD;
		r->w[R_FLAGS] = 1 | ro_bit;
		return QFD_OK;
	}
	struct found f;
	s = lookup(&p, 1, &f);
	comps_free(&cs);
	if (s)
		return s;
	if (!f.has)
		s = QFD_FNF;
	else if (!(S_ISREG(f.meta.st_mode) || S_ISDIR(f.meta.st_mode))
		 || (S_ISREG(f.meta.st_mode) && (uint64_t)f.meta.st_size > 0xFFFFFFFFull))
		s = QFD_WKF;
	else if (mode == 0) {
		int k;
		if (S_ISDIR(f.meta.st_mode))
			s = QFD_IOD;
		else if ((k = free_handle(d)) < 0)
			s = QFD_NER;
		else {
			const int fd = open(f.path, O_RDONLY | O_CLOEXEC);
			if (fd < 0)
				s = qfd_errno_status(errno);
			else {
				d->h[k] = (struct qfd_handle){ 1, fd, NULL, NULL, 0, 0 };
				r->w[R_HANDLE] = (uint32_t)k + 1;
			}
		}
	}
	if (!s)
		entry_reply(r, &f.meta, p.ro);
	found_free(&f);
	return s;
}

// muir's `rename_noreplace`: `renameat2`'s RENAME_NOREPLACE, atomic; where
// the file system has no such flag, a look and then a rename.
static int rename_noreplace(const char *from, const char *to)
{
	if (h_renameat2(from, to) == 0)
		return 0;
	if (errno != EINVAL && errno != ENOSYS)
		return -1;
	struct stat st;
	if (lstat(to, &st) == 0) {
		errno = EEXIST;
		return -1;
	}
	return h_rename(from, to);
}

// muir's `close`.
static uint32_t cmd_close(struct qfd *d, uint32_t hn, uint32_t flags, uint32_t date, struct reply *r)
{
	struct qfd_handle *h = handle(d, hn);
	if (!h)
		return QFD_BAD_HANDLE;
	const int abort_ = flags & 1;
	struct stat m;
	if (h->kind == 1) {
		uint32_t s = QFD_OK;
		if (!abort_) {
			if (fstat(h->fd, &m) != 0)
				s = qfd_errno_status(errno);
			else {
				r_len(r, (uint64_t)m.st_size);
				r->w[R_MTIME] = mtime_of(&m);
			}
		}
		handle_close(h, 0);
		return s;
	}
	if (abort_) {
		handle_close(h, 1);
		return QFD_OK;
	}
	int bad = 0;
	if (flags & 2) {
		const struct timespec t[2] = { { 0, UTIME_OMIT }, { (time_t)date, 0 } };
		if (futimens(h->fd, t) != 0)
			bad = errno;
	}
	if (!bad && (h->noreplace ? rename_noreplace(h->temp, h->target) : h_rename(h->temp, h->target)) != 0)
		bad = errno;
	char *target = dup_or_die(h->target);
	handle_close(h, bad != 0);
	if (bad) {
		free(target);
		return qfd_errno_status(bad);
	}
	uint32_t s = QFD_OK;
	if (stat(target, &m) != 0)
		s = qfd_errno_status(errno);
	else {
		r_len(r, (uint64_t)m.st_size);
		r->w[R_MTIME] = mtime_of(&m);
	}
	free(target);
	return s;
}

// muir's `delete`: a file, or an empty directory.
static uint32_t cmd_delete(struct qfd *d, const uint8_t *name, size_t n)
{
	struct comps cs;
	uint32_t s = parse_name(name, n, &cs);
	if (s)
		return s;
	struct place p;
	place(d, &cs, &p);
	struct found f = { 0 };
	if (p.key == KEY_BARE && p.nrel > 1)
		s = QFD_DNF;
	else if (p.ro)
		s = QFD_ATF;
	else if (p.nrel == 0)
		s = QFD_ACC;
	else if (!(s = lookup(&p, 0, &f))) {
		if (!f.has)
			s = QFD_FNF;
		else if ((S_ISDIR(f.meta.st_mode) ? rmdir(f.path) : unlink(f.path)) != 0)
			s = qfd_errno_status(errno);
	}
	found_free(&f);
	comps_free(&cs);
	return s;
}

// muir's `rename`: never over an existing name, never across mounts.
static uint32_t cmd_rename(struct qfd *d, const uint8_t *from, size_t fn, const uint8_t *to, size_t tn)
{
	struct comps fc, tc;
	uint32_t s = parse_name(from, fn, &fc);
	if (s)
		return s;
	if ((s = parse_name(to, tn, &tc))) {
		comps_free(&fc);
		return s;
	}
	struct place fp, tp;
	place(d, &fc, &fp);
	place(d, &tc, &tp);
	struct found f = { 0 }, t = { 0 };
	if ((fp.key == KEY_BARE && fp.nrel > 1) || (tp.key == KEY_BARE && tp.nrel > 1))
		s = QFD_DNF;
	else if (fp.ro || tp.ro)
		s = QFD_ATF;
	else if (fp.nrel == 0 || tp.nrel == 0)
		s = QFD_ACC;
	else if (!same_key(&fp, &tp))
		s = QFD_RAD;
	else if (!(s = lookup(&fp, 0, &f))) {
		if (!f.has)
			s = QFD_FNF;
		else if (!(s = lookup(&tp, 0, &t))) {
			if (t.has)
				s = QFD_REF;
			else if (rename_noreplace(f.path, t.path) != 0)
				s = (errno == EEXIST || errno == ENOTEMPTY) ? QFD_REF : qfd_errno_status(errno);
		}
	}
	found_free(&f);
	found_free(&t);
	comps_free(&fc);
	comps_free(&tc);
	return s;
}

// muir's `create_directory`: one level.
static uint32_t cmd_create_directory(struct qfd *d, const uint8_t *name, size_t n)
{
	struct comps cs;
	uint32_t s = parse_name(name, n, &cs);
	if (s)
		return s;
	struct place p;
	place(d, &cs, &p);
	struct found f = { 0 };
	if (p.key == KEY_BARE && p.nrel > 1)
		s = QFD_DNF;
	else if (p.ro)
		s = QFD_ATF;
	else if (!(s = lookup(&p, 1, &f))) {
		if (f.has && S_ISDIR(f.meta.st_mode))
			s = QFD_DAE;
		else if (f.has)
			s = QFD_FAE;
		else if (h_mkdir(f.path) != 0)
			s = qfd_errno_status(errno);
	}
	found_free(&f);
	comps_free(&cs);
	return s;
}

// A DIRECTORY record: muir's `record`.
static size_t record(const struct entry *e, uint32_t *out)
{
	const size_t n = strlen(e->name), words = 3 + (n + 3) / 4;
	const int too_large = e->len > 0xFFFFFFFFull;
	out[0] = (uint32_t)n | (uint32_t)words << 8 | (uint32_t)e->dir << 16 | (uint32_t)e->ro << 17
		 | (uint32_t)too_large << 18;
	out[1] = too_large ? 0xFFFFFFFFu : (uint32_t)e->len;
	out[2] = e->mtime;
	for (size_t w = 3; w < words; ++w)
		out[w] = 0;
	for (size_t k = 0; k < n; ++k)
		out[3 + k / 4] |= (uint32_t)(uint8_t)e->name[k] << (8 * (k % 4));
	return words;
}

static uint32_t cmd_directory(struct qfd *d, struct qfd_mem *m, const uint32_t *c, struct reply *r)
{
	struct buf a, b;
	uint32_t s;
	if ((s = buffer(m, c[2], c[3], &a)) || (s = buffer(m, c[4], c[5], &b)))
		return s;
	if (b.len < QFD_MIN_DIRECTORY)
		return QFD_BAD_ARGUMENT;
	uint8_t *name = bytes_of(m, a);
	struct comps cs;
	s = parse_name(name, a.len, &cs);
	free(name);
	if (s)
		return s;
	struct entries es;
	s = list(d, &cs, &es);
	comps_free(&cs);
	if (s)
		return s;
	size_t used = 0, next = c[6];
	uint32_t rec[3 + QFD_MAX_COMPONENT / 4 + 1];
	while (next < (size_t)es.n) {
		const size_t words = record(&es.e[next], rec);
		if ((used + words) * 4 > b.len)
			break;
		for (size_t w = 0; w < words; ++w)
			wr(m, b.at + used + w, rec[w]);
		used += words;
		++next;
	}
	r->w[R_COUNT] = (uint32_t)(4 * used);
	r->w[R_W6] = next < (size_t)es.n ? (uint32_t)next : 0;
	entries_free(&es);
	return QFD_OK;
}

static uint32_t cmd_complete(struct qfd *d, struct qfd_mem *m, const uint32_t *c, struct reply *r)
{
	struct buf a, b;
	uint32_t s;
	if ((s = buffer(m, c[2], c[3], &a)) || (s = buffer(m, c[4], c[5], &b)))
		return s;
	uint8_t *text = bytes_of(m, a);
	size_t slash = a.len;
	for (size_t k = a.len; k-- > 0;)
		if (text[k] == '/') {
			slash = k;
			break;
		}
	if (slash == a.len) {
		free(text);
		return QFD_IPS;
	}
	const uint8_t *prefix = text + slash + 1;
	const size_t pn = a.len - slash - 1;
	// The prefix is bytes of a component, and may be empty.
	int bad = pn > QFD_MAX_COMPONENT;
	for (size_t k = 0; k < pn; ++k)
		if (prefix[k] < 040 || prefix[k] > 0176 || prefix[k] == '/')
			bad = 1;
	if (bad) {
		free(text);
		return QFD_IPS;
	}
	struct comps cs;
	if ((s = parse_name(text, slash + 1, &cs))) {
		free(text);
		return s;
	}
	struct entries es;
	s = list(d, &cs, &es);
	comps_free(&cs);
	if (s) {
		free(text);
		return s;
	}
	const char *lcp = NULL;
	size_t ln = 0;
	uint32_t matches = 0;
	for (int k = 0; k < es.n; ++k) {
		const char *nm = es.e[k].name;
		if (strlen(nm) < pn || memcmp(nm, prefix, pn))
			continue;
		if (!matches++) {
			lcp = nm;
			ln = strlen(nm);
		} else {
			size_t i = 0;
			while (i < ln && nm[i] == lcp[i])
				++i;
			ln = i;
		}
	}
	if (matches) {
		if (ln > b.len)
			s = QFD_BAD_ARGUMENT;
		else {
			put_bytes(m, b.at, (const uint8_t *)lcp, ln);
			r->w[R_COUNT] = (uint32_t)ln;
			r->w[R_W6] = matches;
			for (int k = 0; k < es.n; ++k) {
				const char *nm = es.e[k].name;
				if (strlen(nm) == ln && !memcmp(nm, lcp, ln)) {
					r->w[R_FLAGS] = 4u | (uint32_t)es.e[k].dir << 3;
					break;
				}
			}
		}
	}
	entries_free(&es);
	free(text);
	return s;
}

// muir's `command`: which flags each opcode takes, then the command.
static uint32_t command(struct qfd *d, struct qfd_mem *m, uint32_t opcode, uint32_t flags, const uint32_t *c,
			struct reply *r)
{
	uint32_t allowed;
	if (opcode == QFD_OPEN)
		allowed = 0x1F;
	else if (opcode == QFD_CLOSE)
		allowed = 3;
	else if (opcode >= QFD_READ && opcode <= QFD_LOG)
		allowed = 0;
	else
		return QFD_UOP;
	if (flags & ~allowed)
		return QFD_BAD_ARGUMENT;
	struct buf a, b;
	uint32_t s;
	uint8_t *x, *y;
	struct qfd_handle *h;
	switch (opcode) {
	case QFD_OPEN:
		if ((s = buffer(m, c[2], c[3], &a)))
			return s;
		x = bytes_of(m, a);
		s = cmd_open(d, flags, x, a.len, r);
		free(x);
		return s;
	case QFD_READ: {
		if (!(h = handle(d, c[1])) || h->kind != 1)
			return QFD_BAD_HANDLE;
		if ((s = buffer(m, c[4], c[5], &b)))
			return s;
		struct stat st;
		if (fstat(h->fd, &st) != 0)
			return qfd_errno_status(errno);
		const uint64_t len = (uint64_t)st.st_size, offset = c[6];
		if (offset > len)
			return QFD_FOR;
		const size_t n = (size_t)((uint64_t)b.len < len - offset ? (uint64_t)b.len : len - offset);
		uint8_t *data = malloc(n + 1);
		if (!data)
			abort();
		for (size_t got = 0; got < n;) {
			const ssize_t k = pread(h->fd, data + got, n - got, (off_t)(offset + got));
			if (k < 0 && errno == EINTR)
				continue;
			if (k <= 0) {
				s = k < 0 ? qfd_errno_status(errno) : QFD_DAT;
				free(data);
				return s;
			}
			got += (size_t)k;
		}
		put_bytes(m, b.at, data, n);
		free(data);
		r->w[R_COUNT] = (uint32_t)n;
		return QFD_OK;
	}
	case QFD_WRITE: {
		if ((s = buffer(m, c[2], c[3], &a)))
			return s;
		if (!(h = handle(d, c[1])) || h->kind != 2)
			return QFD_BAD_HANDLE;
		const uint64_t offset = c[6];
		if (offset > h->held || offset + a.len > 0xFFFFFFFFull)
			return QFD_FOR;
		x = bytes_of(m, a);
		for (size_t put = 0; put < a.len;) {
			const ssize_t k = pwrite(h->fd, x + put, a.len - put, (off_t)(offset + put));
			if (k < 0 && errno == EINTR)
				continue;
			if (k <= 0) {
				s = k < 0 ? qfd_errno_status(errno) : QFD_DAT;
				free(x);
				return s;
			}
			put += (size_t)k;
		}
		free(x);
		if (offset + a.len > h->held)
			h->held = offset + a.len;
		r->w[R_COUNT] = a.len;
		return QFD_OK;
	}
	case QFD_CLOSE:
		return cmd_close(d, c[1], flags, c[7], r);
	case QFD_DIRECTORY:
		return cmd_directory(d, m, c, r);
	case QFD_COMPLETE:
		return cmd_complete(d, m, c, r);
	case QFD_DELETE:
		if ((s = buffer(m, c[2], c[3], &a)))
			return s;
		x = bytes_of(m, a);
		s = cmd_delete(d, x, a.len);
		free(x);
		return s;
	case QFD_RENAME:
		if ((s = buffer(m, c[2], c[3], &a)) || (s = buffer(m, c[4], c[5], &b)))
			return s;
		x = bytes_of(m, a);
		y = bytes_of(m, b);
		s = cmd_rename(d, x, a.len, y, b.len);
		free(x);
		free(y);
		return s;
	case QFD_CREATE_DIRECTORY:
		if ((s = buffer(m, c[2], c[3], &a)))
			return s;
		x = bytes_of(m, a);
		s = cmd_create_directory(d, x, a.len);
		free(x);
		return s;
	case QFD_LOG: {
		if ((s = buffer(m, c[2], c[3], &a)))
			return s;
		if (a.len > QFD_MAX_LOG)
			return QFD_BAD_ARGUMENT;
		x = bytes_of(m, a);
		char line[5 + 4 * QFD_MAX_LOG + 1];
		qfd_log_line(x, a.len, line);
		free(x);
		if (d->log)
			d->log(d->log_ctx, line);
		return QFD_OK;
	}
	}
	return QFD_UOP;
}

// muir's `execute`: the entry read, the command done, the response written.
// A failed command's response is word 0 alone.
void qfd_execute(struct qfd *d, struct qfd_mem *m, size_t cmd_at, size_t resp_at)
{
	uint32_t c[8];
	for (int k = 0; k < 8; ++k)
		c[k] = rd(m, cmd_at + (size_t)k);
	const uint32_t tag = c[0] & 0xFFFF, opcode = (c[0] >> 16) & 0xFF, flags = c[0] >> 24;
	struct reply r;
	memset(&r, 0, sizeof r);
	const uint32_t s = command(d, m, opcode, flags, c, &r);
	if (s)
		memset(&r, 0, sizeof r);
	wr(m, resp_at, tag | s << 16 | opcode << 24);
	for (int k = 0; k < 7; ++k)
		wr(m, resp_at + 1 + (size_t)k, r.w[k]);
}

// --- the start's sweep ---------------------------------------------------------------

static unsigned sweep_dir(const char *dir, void (*emit)(void *, const char *), void *ctx)
{
	DIR *d = opendir(dir);
	if (!d)
		return 0;
	unsigned n = 0;
	struct dirent *e;
	while ((e = readdir(d))) {
		if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
			continue;
		char *p = join(dir, e->d_name);
		struct stat st;
		if (lstat(p, &st) == 0) {
			if (S_ISDIR(st.st_mode))
				n += sweep_dir(p, emit, ctx);
			else if (S_ISREG(st.st_mode)
				 && !strncmp(e->d_name, QFD_TEMP_PREFIX, strlen(QFD_TEMP_PREFIX))
				 && unlink(p) == 0) {
				++n;
				if (emit)
					emit(ctx, p);
			}
		}
		free(p);
	}
	closedir(d);
	return n;
}

unsigned qfd_sweep(const struct qfd_mounts *m, void (*emit)(void *, const char *), void *ctx)
{
	unsigned n = 0;
	if (m->has_default && !m->def.ro)
		n += sweep_dir(m->def.path, emit, ctx);
	for (int k = 0; k < m->n; ++k)
		if (!m->named[k].ro)
			n += sweep_dir(m->named[k].path, emit, ctx);
	return n;
}
