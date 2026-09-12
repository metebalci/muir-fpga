// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The FILE service: `muir::chaos::file`, ported command for command.
// `chaos_file.h` says what the protocol is and where it is written down; this
// file is the machinery, and muir's reasoning travels with it, because in this
// project a reason is evidence.
//
// **WHAT THIS ANSWERS.**  A board that boots MIT's Lisp Machine system and
// paints the window system prints `#<ZWEI::ZWEI-FILE-HOST "ED-FILE"> is not a
// known host`.  That is a Chaosnet file host lookup with nothing on the other
// end.  Everything below exists so that there is something.
//
// ## The three ends this is read against
//
// In the order the project ranks them: MIT's own specification,
// `sys/doc/chfile.text`; MIT's own server, `sys/file/server.lisp`; the Lisp
// Machine's client, `sys/network/chaos/qfile.lisp`; and last the MIT/Symbolics
// Unix server of 1984, `FILE.c`, whose decisions muir follows where the first
// three are silent.  Nothing here re-derives the protocol from scratch: where
// this file and muir differ it is a bug here, and the comments name which of
// the four settled each question so that the next reader can check rather than
// trust.
//
// ## What Rust's shapes become in C
//
// **`Arc<Mutex<Channel>>` becomes a refcount and no lock.**  muir shares one
// data connection between the control connection and the data session with an
// `Arc<Mutex<..>>`, and the mutex is there because muir's engine and its
// server can run on two threads.  This program is single-threaded --- one
// `poll` loop over the ether, as `cadr-chaosnet.c`'s own header says --- so
// what is left of that type is the *sharing*, which is a refcount, and the
// lock would be a lie about concurrency that does not exist.  `struct channel`
// is that refcount, and both handles of a data connection plus the data
// session each hold one.
//
// **`BTreeMap` becomes a list kept in sorted order, and the order is load
// bearing.**  muir's comment at `handles` is worth having verbatim: the poll
// walks them, "and with a hashed map that walk is in a different order in
// every process, so anything that depends on which handle comes first happens
// in some runs and not others.  One such bug took an afternoon to catch.
// Ordering it does more than take the variation away: it makes the order that
// used to lose data the only order there is, so a test can hold it and fails
// every time rather than half of them."  So the handles here are a singly
// linked list held in `strcmp` order --- the same order `BTreeMap<String, _>`
// walks for the ASCII handle names the band sends --- and not a hash table
// that would have been easier to write.
//
// **One list where muir has two maps.**  muir keeps `handles` and `transfers`
// as separate `BTreeMap`s keyed by the same names, and every insertion into
// `transfers` is guarded by the handle already existing, so the transfer keys
// are always a subset of the handle keys.  Here the transfer lives in the
// handle's own record, with `T_NONE` for "no transfer", which cannot represent
// the impossible state and walks both in one pass.

#include "chaos_file.h"

#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <cadr/cadr_log.h>

// The Lisp Machine's newline as a string, for building a reply with: the
// protocol's line separator is one byte, 0215, and every reply of more than
// one line carries it.
#define NLS "\215"

// A transaction id, a file handle and a pathname as the client wrote them.  A
// command arrives in one data packet, so none of the three can be longer than
// a packet; these are the sizes past which a client is being absurd rather
// than the sizes the protocol allows, and what overflows them is truncated by
// `snprintf` rather than overrunning anything.
#define FILE_TID_MAX 64
#define FILE_HANDLE_MAX 64
#define FILE_NAME_MAX 512
// The property line of a transfer, repeated in its CLOSE: a date, a length and
// two flags.
#define FILE_PROPS_MAX 128
// The most whitespace-separated words an argument line is read for.  `OPEN`'s
// is the longest the protocol has and is nowhere near this.
#define FILE_WORDS_MAX 32

// ------------------------------------------------------------ growable text
//
// A reply line is `tid handle COMMAND` and then results that may be a whole
// directory listing, so the things built here have no useful bound and are
// built in a buffer that grows.  `bad` latches an allocation failure so that
// every `buf_add` after one is a no-op and only the caller has to check.

struct buf {
	char *p;
	size_t len, cap;
	int bad;
};

static int buf_room(struct buf *b, size_t extra)
{
	if (b->bad)
		return -1;
	if (b->p && b->len + extra + 1 <= b->cap)
		return 0;
	size_t want = b->cap ? b->cap : 256;
	while (want < b->len + extra + 1)
		want *= 2;
	char *q = realloc(b->p, want);
	if (!q) {
		say("out of memory building a %zu byte reply", want);
		b->bad = 1;
		return -1;
	}
	b->p = q;
	b->cap = want;
	b->p[b->len] = '\0';
	return 0;
}

static void buf_add(struct buf *b, const char *s, size_t n)
{
	if (buf_room(b, n) < 0)
		return;
	memcpy(b->p + b->len, s, n);
	b->len += n;
	b->p[b->len] = '\0';
}

static void buf_addf(struct buf *b, const char *fmt, ...)
	__attribute__((format(printf, 2, 3)));
static void buf_addf(struct buf *b, const char *fmt, ...)
{
	va_list ap, cp;
	va_start(ap, fmt);
	va_copy(cp, ap);
	int k = vsnprintf(NULL, 0, fmt, cp);
	va_end(cp);
	if (k >= 0 && buf_room(b, (size_t)k) == 0) {
		vsnprintf(b->p + b->len, (size_t)k + 1, fmt, ap);
		b->len += (size_t)k;
	}
	va_end(ap);
}

static const char *buf_str(const struct buf *b)
{
	return b->p ? b->p : "";
}

static void buf_free(struct buf *b)
{
	free(b->p);
	b->p = NULL;
	b->len = b->cap = 0;
	b->bad = 0;
}

// ------------------------------------------------- the character set, dates
//
// muir's `from_lispm` and `to_lispm`, which are `FILE.c`'s, transcribed.  The
// note beside the C is worth keeping: "0212 maps to 015 since 0215 must map to
// 012".

unsigned chaos_file_from_lispm(const uint8_t *in, unsigned len, uint8_t *out)
{
	for (unsigned i = 0; i < len; ++i) {
		uint8_t c = in[i];
		switch (c) {
		case 0010: case 0011: case 0012:
		case 0014: case 0015: case 0177:
			out[i] = (uint8_t)(c | 0200);
			break;
		case 0212:
			out[i] = 015;
			break;
		case CHAOS_FILE_NEWLINE:
			out[i] = '\n';
			break;
		case 0210: case 0211: case 0214: case 0377:
			out[i] = (uint8_t)(c & 0177);
			break;
		default:
			out[i] = c;
			break;
		}
	}
	return len;
}

unsigned chaos_file_to_lispm(const uint8_t *in, unsigned len, uint8_t *out)
{
	for (unsigned i = 0; i < len; ++i) {
		uint8_t c = in[i];
		switch (c) {
		case 0210: case 0211: case 0212:
		case 0214: case CHAOS_FILE_NEWLINE: case 0377:
			out[i] = (uint8_t)(c & 0177);
			break;
		case '\n':
			out[i] = CHAOS_FILE_NEWLINE;
			break;
		case 015:
			out[i] = 0212;
			break;
		case 0010: case 0011: case 0014: case 0177:
			out[i] = (uint8_t)(c | 0200);
			break;
		default:
			out[i] = c;
			break;
		}
	}
	return len;
}

// Calendar date and time from seconds since 1970, UT: Howard Hinnant's
// days-to-civil, as muir has it.
static void civil(uint64_t secs, unsigned *year, unsigned *mon, unsigned *day,
		  unsigned *hh, unsigned *mm, unsigned *ss)
{
	const uint64_t days = secs / 86400u, rem = secs % 86400u;
	const int64_t z = (int64_t)days + 719468;
	const int64_t era = (z >= 0 ? z : z - 146096) / 146097;
	const int64_t doe = z - era * 146097;
	const int64_t yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
	int64_t y = yoe + era * 400;
	const int64_t doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
	const int64_t mp = (5 * doy + 2) / 153;
	const int64_t d = doy - (153 * mp + 2) / 5 + 1;
	const int64_t m = mp < 10 ? mp + 3 : mp - 9;
	if (m <= 2)
		y += 1;
	*year = (unsigned)y;
	*mon = (unsigned)m;
	*day = (unsigned)d;
	*hh = (unsigned)(rem / 3600);
	*mm = (unsigned)(rem % 3600 / 60);
	*ss = (unsigned)(rem % 60);
}

// `MM/DD/YY HH:MM:SS`, the form `PARSE-DIRECTORY-DATE-PROPERTY` reads fastest,
// in UT.
void chaos_file_date(uint64_t unix_secs, char *into, unsigned into_len)
{
	unsigned y, mo, d, hh, mm, ss;
	civil(unix_secs, &y, &mo, &d, &hh, &mm, &ss);
	snprintf(into, into_len, "%02u/%02u/%02u %02u:%02u:%02u", mo, d, y % 100,
		 hh, mm, ss);
}

// `*` any run, `?` or `#` any one, else itself: the glob the user end sends.
//
// The two-pointer match, linear in the lengths, and muir's reason for it is
// kept: "the recursive form that tried both branches of every `*` was
// exponential in the number of stars --- a pattern of ten `*a` against a long
// run of `a`s pinned the engine's thread for billions of tries".
//
// **`#` as well as `?`, and only here does this differ from muir**, which
// takes `?` alone.  `chaos_file.h`'s own contract names `#`, which is the
// character the Lisp Machine's pathname syntax uses for one wild character,
// and a client that sends `?` is matched as muir matches it.  Taking both
// cannot lose a match muir would make; it can gain one, against a name with a
// literal `#` in it, which is what this service's own temporaries are called
// --- and a `#` in a pattern matching a `#` in a name is the same answer
// either way round.
int chaos_file_matches(const char *pattern, const char *name)
{
	// An empty pattern matches anything, as muir has it: DIRECTORY of a
	// path ending in a slash lists the whole directory.
	if (!pattern || !*pattern)
		return 1;
	const unsigned char *p = (const unsigned char *)pattern;
	const unsigned char *n = (const unsigned char *)name;
	const size_t pl = strlen(pattern), nl = strlen(name);
	size_t pi = 0, ni = 0;
	// The last `*` in the pattern, and the name position it is currently
	// taken to have matched up to; `have_star` until one is seen.
	size_t star_p = 0, star_n = 0;
	int have_star = 0;
	while (ni < nl) {
		if (pi < pl && (p[pi] == '?' || p[pi] == '#' || p[pi] == n[ni])) {
			++pi;
			++ni;
		} else if (pi < pl && p[pi] == '*') {
			star_p = pi;
			star_n = ni;
			have_star = 1;
			++pi;
		} else if (have_star) {
			// Back to the last `*`, letting it swallow one more.
			pi = star_p + 1;
			ni = star_n + 1;
			star_n = ni;
		} else {
			return 0;
		}
	}
	// The name is used up; any trailing `*`s match the empty run.
	while (pi < pl && p[pi] == '*')
		++pi;
	return pi == pl;
}

// ------------------------------------------------------- the data connection

// What has come up a data connection and not been taken yet.
struct incoming {
	struct incoming *next;
	uint8_t op;
	unsigned len;
	uint8_t bytes[CHAOS_PKT_MAX_DATA];
};

// A data connection as the control connection sees it: the channel behind a
// pair of file handles.  Both ends of one connection share it, so what the
// user end sends up reaches the control connection's transfer, and what a
// transfer produces goes down.
//
// `refs` is muir's `Arc` with the `Mutex` left out, for the reason the header
// gives: this program has one thread.
struct channel {
	unsigned refs;
	int open;
	int closed;
	int eof;
	// What is to go down it, in order.
	struct chaos_outq out;
	// What has come up it and not been taken yet.
	struct incoming *in_head, *in_tail;
};

static struct channel *channel_new(void)
{
	struct channel *ch = calloc(1, sizeof *ch);
	if (!ch)
		say("out of memory opening a data connection");
	else
		ch->refs = 1;
	return ch;
}

static struct channel *channel_ref(struct channel *ch)
{
	++ch->refs;
	return ch;
}

static void channel_clear_incoming(struct channel *ch)
{
	struct incoming *i = ch->in_head;
	while (i) {
		struct incoming *next = i->next;
		free(i);
		i = next;
	}
	ch->in_head = ch->in_tail = NULL;
}

static void channel_unref(struct channel *ch)
{
	if (!ch || --ch->refs)
		return;
	chaos_outq_clear(&ch->out);
	channel_clear_incoming(ch);
	free(ch);
}

// The bytes down the channel, in as many packets as it takes.  An empty run
// sends nothing at all, which is muir's `chunks()` over an empty slice and
// matters for an empty file: what goes is the EOF alone.
static void channel_send(struct channel *ch, uint8_t op, const uint8_t *bytes,
			 size_t len)
{
	for (size_t off = 0; off < len; off += CHAOS_PKT_MAX_DATA) {
		size_t take = len - off;
		if (take > CHAOS_PKT_MAX_DATA)
			take = CHAOS_PKT_MAX_DATA;
		chaos_out_data(&ch->out, op, bytes + off, (unsigned)take);
	}
}

// A mark carries no data of its own.
static void channel_mark(struct channel *ch, uint8_t op)
{
	chaos_out_data(&ch->out, op, NULL, 0);
}

// Everything queued to go down the channel that is file data --- muir's
// `retain(|o| !matches!(o, Out::DataOp(..) | Out::Eof))`, which a `FILEPOS`
// uses to throw away what is in flight from the old position.  A CLOSE queued
// behind it stays.
static void channel_drop_data(struct channel *ch)
{
	struct chaos_outq keep = { NULL, NULL };
	struct chaos_out *o;
	while ((o = chaos_outq_pop(&ch->out))) {
		if (o->kind == CHAOS_OUT_DATA || o->kind == CHAOS_OUT_EOF) {
			free(o);
			continue;
		}
		if (keep.tail)
			keep.tail->next = o;
		else
			keep.head = o;
		keep.tail = o;
	}
	ch->out = keep;
}

// Moves everything from `src` onto the end of `dst`, in order.
static void outq_splice(struct chaos_outq *dst, struct chaos_outq *src)
{
	if (!src->head)
		return;
	if (dst->tail)
		dst->tail->next = src->head;
	else
		dst->head = src->head;
	dst->tail = src->tail;
	src->head = src->tail = NULL;
}

// The data connection's own end: shares the channel with the control
// connection that asked for it.
struct data_session {
	struct chaos_session base;
	struct channel *ch;
};

static void data_opened(struct chaos_session *s, uint64_t now)
{
	(void)now;
	((struct data_session *)s)->ch->open = 1;
}

static void data_data(struct chaos_session *s, uint64_t now, uint8_t op,
		      const uint8_t *bytes, unsigned len)
{
	(void)now;
	struct channel *ch = ((struct data_session *)s)->ch;
	if (len > CHAOS_PKT_MAX_DATA)
		len = CHAOS_PKT_MAX_DATA;
	struct incoming *i = calloc(1, sizeof *i);
	if (!i) {
		say("out of memory taking %u bytes off a data connection", len);
		return;
	}
	i->op = op;
	i->len = len;
	if (len)
		memcpy(i->bytes, bytes, len);
	if (ch->in_tail)
		ch->in_tail->next = i;
	else
		ch->in_head = i;
	ch->in_tail = i;
}

static void data_eof(struct chaos_session *s, uint64_t now)
{
	(void)now;
	((struct data_session *)s)->ch->eof = 1;
}

static void data_closed(struct chaos_session *s, uint64_t now, const char *reason)
{
	(void)now;
	(void)reason;
	((struct data_session *)s)->ch->closed = 1;
}

static void data_poll(struct chaos_session *s, uint64_t now, struct chaos_outq *q)
{
	(void)now;
	outq_splice(q, &((struct data_session *)s)->ch->out);
}

static void data_destroy(struct chaos_session *s)
{
	struct data_session *d = (struct data_session *)s;
	channel_unref(d->ch);
	free(d);
}

static struct chaos_session *data_session_new(struct channel *ch)
{
	struct data_session *d = calloc(1, sizeof *d);
	if (!d) {
		say("out of memory making a data connection's end");
		return NULL;
	}
	d->base.opened = data_opened;
	d->base.data = data_data;
	d->base.eof = data_eof;
	d->base.closed = data_closed;
	d->base.poll = data_poll;
	d->base.destroy = data_destroy;
	d->ch = channel_ref(ch);
	return &d->base;
}

// ------------------------------------------------------ handles and transfers

enum tkind {
	T_NONE = 0,
	// A file being read: its truename and the properties line, repeated in
	// the CLOSE reply, and the file as it goes down the wire, kept so that
	// a FILEPOS can send it again from somewhere else.
	T_READ,
	T_DIRECTORY,
	// A file being written: the temporary it is going into, where it will
	// be renamed to on close, and how to translate what arrives.
	T_WRITE
};

struct transfer {
	enum tkind kind;
	char truename[FILE_NAME_MAX];
	// T_READ
	char properties[FILE_PROPS_MAX];
	uint8_t *contents;
	size_t contents_len;
	uint8_t op;
	// T_WRITE
	char temp[PATH_MAX];
	char real[PATH_MAX];
	int characters;
	// Bytes a failed append is holding, waiting for a CONTINUE, and the
	// message that went out in the asynchronous mark.  While `stalled` is
	// set the transfer is stopped.
	int stalled;
	uint8_t *held;
	size_t held_len;
	char why[192];
	// Whether the synchronous mark that says the data is all there has come
	// up the data connection.  A flag rather than a count because a write's
	// only inbound mark is that one: the others the protocol has are the
	// ones a FILEPOS or a SET-BYTE-SIZE provokes, and both of those come
	// *from* the server.
	int marked;
	// The transaction id of a CLOSE that came before the mark and is
	// waiting for it.
	int closing;
	char closing_tid[FILE_TID_MAX];
};

// A file handle, and whatever is open on it.  The list is kept in `strcmp`
// order for the reason at the top of this file.
struct handle {
	struct handle *next;
	char name[FILE_HANDLE_MAX];
	struct channel *ch;
	struct transfer t;
};

// A DATA-CONNECTION waiting for its connection to open before it is answered,
// as `FILE.c` answers it only once `chopen` has succeeded.
struct pending {
	struct pending *next;
	char tid[FILE_TID_MAX];
	struct channel *ch;
};

// The control connection.
struct control {
	struct chaos_session base;
	char root[PATH_MAX];
	// A fixed universal time to date things by, or 0 for the machine's
	// clock.
	uint32_t fixed;
	uint16_t client;
	// The protocol version from the RFC's argument: `FILE 1` is 1.  It
	// chooses the shape of the reply to a write's CLOSE --- `FILE.c` writes
	// the plain form when `protocol > 0` and one with a leading `-1` for an
	// older client.
	uint32_t version;
	char user[FILE_HANDLE_MAX];
	int have_user;
	struct handle *handles;
	struct pending *pending;
	struct chaos_outq out;
};

// A counter for temporary-file names, taken once per write and never repeated
// in this process.  muir's reason: two control connections from one client
// writing in one directory used to make the same `#muir-...#` name --- the
// count was kept per control connection --- so opening the second truncated
// the first's temporary.
static uint64_t next_temp;

static void transfer_clear(struct transfer *t)
{
	free(t->contents);
	free(t->held);
	memset(t, 0, sizeof *t);
}

static struct handle *handle_find(struct control *c, const char *name)
{
	for (struct handle *h = c->handles; h; h = h->next) {
		int d = strcmp(h->name, name);
		if (d == 0)
			return h;
		if (d > 0)
			break;	// sorted: past where it would have been
	}
	return NULL;
}

// Inserts in `strcmp` order, which is the order `BTreeMap<String, _>` walks.
static struct handle *handle_add(struct control *c, const char *name,
				 struct channel *ch)
{
	struct handle *h = calloc(1, sizeof *h);
	if (!h) {
		say("out of memory making file handle %s", name);
		return NULL;
	}
	snprintf(h->name, sizeof h->name, "%s", name);
	h->ch = channel_ref(ch);
	struct handle **link = &c->handles;
	while (*link && strcmp((*link)->name, h->name) < 0)
		link = &(*link)->next;
	h->next = *link;
	*link = h;
	return h;
}

static void handle_remove(struct control *c, struct handle *h)
{
	for (struct handle **link = &c->handles; *link; link = &(*link)->next) {
		if (*link == h) {
			*link = h->next;
			break;
		}
	}
	transfer_clear(&h->t);
	channel_unref(h->ch);
	free(h);
}

// ------------------------------------------------------------- saying things

// A line down the control connection, in as many packets as it takes: the
// connection is a stream, and a reply quoting a command back --- an unknown
// command's name, a LOGIN's user in its home directory --- may run past the
// bytes a packet carries.
static void control_say(struct control *c, const char *line, size_t len)
{
	for (size_t off = 0; off < len; off += CHAOS_PKT_MAX_DATA) {
		size_t take = len - off;
		if (take > CHAOS_PKT_MAX_DATA)
			take = CHAOS_PKT_MAX_DATA;
		chaos_out_data(&c->out, CHAOS_DAT, line + off, (unsigned)take);
	}
}

// `tid handle COMMAND results`, `FILE.c`'s `respond`.
static void reply(struct control *c, const char *tid, const char *handle,
		  const char *name, const char *results)
{
	struct buf b = { NULL, 0, 0, 0 };
	buf_addf(&b, "%s %s %s", tid, handle, name);
	if (results && *results) {
		buf_add(&b, " ", 1);
		buf_add(&b, results, strlen(results));
	}
	control_say(c, buf_str(&b), b.len);
	buf_free(&b);
}

// `tid handle ERROR code severity message`, `FILE.c`'s `error`: the severity
// `C` for an error in the command, `F` fatal to a transfer, `R` recoverable.
static void file_error(struct control *c, const char *tid, const char *handle,
		       const char *code, char severity, const char *fmt, ...)
	__attribute__((format(printf, 6, 7)));
static void file_error(struct control *c, const char *tid, const char *handle,
		       const char *code, char severity, const char *fmt, ...)
{
	struct buf b = { NULL, 0, 0, 0 };
	buf_addf(&b, "%s %s ERROR %s %c ", tid, handle, code, severity);
	va_list ap;
	va_start(ap, fmt);
	va_list cp;
	va_copy(cp, ap);
	int k = vsnprintf(NULL, 0, fmt, cp);
	va_end(cp);
	if (k >= 0 && buf_room(&b, (size_t)k) == 0) {
		vsnprintf(b.p + b.len, (size_t)k + 1, fmt, ap);
		b.len += (size_t)k;
	}
	va_end(ap);
	control_say(c, buf_str(&b), b.len);
	buf_free(&b);
}

// The refusal every pathname the service may not reach gets: `ATD`, "Access to
// directory denied", the error `FILE.c` gives a pathname the user may not
// reach.
static void denied(struct control *c, const char *tid, const char *handle)
{
	file_error(c, tid, handle, "ATD", 'C', "Access to directory denied");
}

// ---------------------------------------------------------------- containment

// Appends one component, as `PathBuf::push` does.  -1 if the result would not
// fit, which is refused like any other unreachable pathname.
static int path_push(char *buf, size_t n, const char *part)
{
	size_t l = strlen(buf), pl = strlen(part);
	// A root of `/` must not grow a second slash.
	if (l == 1 && buf[0] == '/')
		l = 0;
	if (l + 1 + pl + 1 > n)
		return -1;
	buf[l] = '/';
	memcpy(buf + l + 1, part, pl + 1);
	return 0;
}

// Cuts the last component off, as `Path::parent` does.  -1 when there is none.
static int path_parent(char *buf)
{
	char *slash = strrchr(buf, '/');
	if (!slash)
		return -1;
	if (slash == buf) {
		if (buf[1] == '\0')
			return -1;	// already `/`
		buf[1] = '\0';
		return 0;
	}
	*slash = '\0';
	return 0;
}

// Whether `real` is `t` or lies under it.  Component-wise, as
// `Path::starts_with` is: `/a/bc` does not start with `/a/b`.
static int under(const char *real, const char *t)
{
	size_t n = strlen(t);
	if (n == 1 && t[0] == '/')
		return real[0] == '/';
	if (strncmp(real, t, n) != 0)
		return 0;
	return real[n] == '\0' || real[n] == '/';
}

// The tree the service may reach: the root, and what the root's own entries
// link to.  Each release's fetch script puts its sources under the root by
// such a link --- `sys` for System 304 and `tree` for System 100, under the
// name that release's band asks for --- so those have to be followed, and a
// link anywhere deeper that leads out must not be.
struct tree {
	char **paths;
	unsigned n, cap;
};

static void tree_push(struct tree *t, char *owned)
{
	if (t->n == t->cap) {
		unsigned cap = t->cap ? t->cap * 2 : 8;
		char **p = realloc(t->paths, cap * sizeof *p);
		if (!p) {
			say("out of memory reading the served tree");
			free(owned);
			return;
		}
		t->paths = p;
		t->cap = cap;
	}
	t->paths[t->n++] = owned;
}

static void tree_free(struct tree *t)
{
	for (unsigned i = 0; i < t->n; ++i)
		free(t->paths[i]);
	free(t->paths);
	t->paths = NULL;
	t->n = t->cap = 0;
}

// The file under the root that a pathname names, or -1 for a refusal.
//
// The root is the service's `/`, and nothing the service does may reach a file
// outside the tree it serves.  So the pathname is taken component by component
// under the root, with `..` and `.` REFUSED rather than followed; then the
// deepest part of the result that exists is resolved on the host, links and
// all, and must lie under the root or under what one of the root's own entries
// links to.  A link anywhere deeper that leads out is refused, and a link the
// band makes with CREATE-LINK can only point under the root, so the band
// cannot widen the tree.
//
// Every refusal this can give is `ATD`; muir returns the pair and every caller
// passes it straight on, so here the caller says `denied`.
static int resolve(struct control *c, const char *pathname, char *out, size_t n)
{
	if (strlen(c->root) + 1 > n)
		return -1;
	snprintf(out, n, "%s", c->root);
	// Component by component.  `..` and `.` are refused rather than
	// followed: following them is how a containment rule is got wrong, and
	// a client with a legitimate use for either can spell the place it
	// means.
	const char *s = pathname;
	while (*s) {
		while (*s == '/')
			++s;
		if (!*s)
			break;
		const char *e = strchr(s, '/');
		size_t len = e ? (size_t)(e - s) : strlen(s);
		if ((len == 2 && s[0] == '.' && s[1] == '.') ||
		    (len == 1 && s[0] == '.'))
			return -1;
		char part[FILE_NAME_MAX];
		if (len + 1 > sizeof part)
			return -1;
		memcpy(part, s, len);
		part[len] = '\0';
		if (path_push(out, n, part) < 0)
			return -1;
		s = e ? e + 1 : s + len;
	}

	struct tree tree = { NULL, 0, 0 };
	char *root_real = realpath(c->root, NULL);
	if (!root_real)
		return -1;
	tree_push(&tree, root_real);
	DIR *d = opendir(c->root);
	if (d) {
		struct dirent *de;
		while ((de = readdir(d))) {
			if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
				continue;
			char entry[PATH_MAX];
			snprintf(entry, sizeof entry, "%s", c->root);
			if (path_push(entry, sizeof entry, de->d_name) < 0)
				continue;
			struct stat st;
			if (lstat(entry, &st) != 0 || !S_ISLNK(st.st_mode))
				continue;
			char *real = realpath(entry, NULL);
			if (real)
				tree_push(&tree, real);
		}
		closedir(d);
	}

	// The deepest part of the result that exists, resolved on the host.
	char probe[PATH_MAX];
	snprintf(probe, sizeof probe, "%s", out);
	char *real = NULL;
	for (;;) {
		real = realpath(probe, NULL);
		if (real)
			break;
		if (path_parent(probe) < 0)
			break;
	}
	int ok = 0;
	for (unsigned i = 0; real && i < tree.n; ++i) {
		if (under(real, tree.paths[i])) {
			ok = 1;
			break;
		}
	}
	free(real);
	tree_free(&tree);
	return ok ? 0 : -1;
}

// `resolve` for a pathname that is to be written, renamed, deleted or created:
// the root itself is none of those.
static int resolve_for_writing(struct control *c, const char *pathname, char *out,
			       size_t n)
{
	if (resolve(c, pathname, out, n) < 0)
		return -1;
	return strcmp(out, c->root) == 0 ? -1 : 0;
}

// ------------------------------------------------------------- small helpers

// The name as the user end will see it: the pathname it asked for.
static void truename_of(const char *pathname, int directory, char *out, size_t n)
{
	size_t l = strlen(pathname);
	while (l > 0 && pathname[l - 1] == '/')
		--l;
	snprintf(out, n, "%.*s%s", (int)l, pathname, directory ? "/" : "");
}

// The date now --- the fixed universal time if there is one, else the
// machine's clock --- in the same form as a file's.
static void now_date(const struct control *c, char *into, unsigned n)
{
	uint64_t secs;
	if (c->fixed) {
		secs = c->fixed > CHAOS_UNIX_EPOCH_UNIVERSAL ?
			       c->fixed - CHAOS_UNIX_EPOCH_UNIVERSAL : 0;
	} else {
		const time_t t = time(NULL);
		secs = t > 0 ? (uint64_t)t : 0;
	}
	chaos_file_date(secs, into, n);
}

static void file_date(const struct stat *st, char *into, unsigned n)
{
	chaos_file_date(st->st_mtime > 0 ? (uint64_t)st->st_mtime : 0, into, n);
}

static int path_exists(const char *p)
{
	struct stat st;
	return stat(p, &st) == 0;
}

// Whole-file read.  NULL on any failure, with the length out.
static uint8_t *read_whole(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	size_t cap = 4096, n = 0;
	uint8_t *p = malloc(cap);
	if (!p) {
		fclose(f);
		say("out of memory reading %s", path);
		return NULL;
	}
	for (;;) {
		if (n == cap) {
			uint8_t *q = realloc(p, cap * 2);
			if (!q) {
				free(p);
				fclose(f);
				say("out of memory reading %s", path);
				return NULL;
			}
			p = q;
			cap *= 2;
		}
		size_t got = fread(p + n, 1, cap - n, f);
		n += got;
		if (got == 0)
			break;
	}
	int bad = ferror(f);
	fclose(f);
	if (bad) {
		free(p);
		return NULL;
	}
	*len = n;
	return p;
}

static int write_whole(const char *path, const uint8_t *bytes, size_t len)
{
	FILE *f = fopen(path, "wb");
	if (!f)
		return -1;
	int ok = len == 0 || fwrite(bytes, 1, len, f) == len;
	if (fclose(f) != 0)
		ok = 0;
	return ok ? 0 : -1;
}

// Adds bytes to the end of a file that must already be there.
static int append(const char *path, const uint8_t *bytes, size_t len)
{
	FILE *f = fopen(path, "ab");
	if (!f)
		return -1;
	int ok = len == 0 || fwrite(bytes, 1, len, f) == len;
	if (fclose(f) != 0)
		ok = 0;
	return ok ? 0 : -1;
}

// The words of an argument line.  `args` is copied into `store` and cut up
// there, so the caller's command buffer is untouched.
struct words {
	const char *w[FILE_WORDS_MAX];
	unsigned n;
	char store[CHAOS_PKT_MAX_DATA + 1];
};

static void words_of(struct words *ws, const char *args)
{
	ws->n = 0;
	snprintf(ws->store, sizeof ws->store, "%s", args);
	char *p = ws->store;
	while (*p && ws->n < FILE_WORDS_MAX) {
		while (*p == ' ' || *p == '\t')
			++p;
		if (!*p)
			break;
		ws->w[ws->n++] = p;
		while (*p && *p != ' ' && *p != '\t')
			++p;
		if (*p)
			*p++ = '\0';
	}
}

static int words_have(const struct words *ws, const char *key)
{
	for (unsigned i = 0; i < ws->n; ++i)
		if (!strcmp(ws->w[i], key))
			return 1;
	return 0;
}

// The word after `key`, or NULL.
static const char *words_named(const struct words *ws, const char *key)
{
	for (unsigned i = 0; i + 1 < ws->n; ++i)
		if (!strcmp(ws->w[i], key))
			return ws->w[i + 1];
	return NULL;
}

// A whole non-negative decimal number, or -1: Rust's `parse::<usize>()`, which
// takes an optional `+` and refuses anything with a tail.
static long long whole_number(const char *s)
{
	while (*s == ' ' || *s == '\t')
		++s;
	if (*s == '+')
		++s;
	if (!*s)
		return -1;
	unsigned long long v = 0;
	for (; *s; ++s) {
		if (*s == ' ' || *s == '\t') {
			// Trailing space only; anything else is a tail.
			for (const char *t = s; *t; ++t)
				if (*t != ' ' && *t != '\t')
					return -1;
			break;
		}
		if (*s < '0' || *s > '9')
			return -1;
		if (v > (unsigned long long)1 << 40)
			return -1;
		v = v * 10 + (unsigned)(*s - '0');
	}
	return (long long)v;
}

// ------------------------------------------------------------ the properties

// The property lines a file has, `NAME value` each, from `FILE.c`'s property
// table.
static void file_properties(struct control *c, const struct stat *st, struct buf *b)
{
	char when[24];
	file_date(st, when, sizeof when);
	const unsigned long long len = (unsigned long long)st->st_size;
	buf_addf(b, "AUTHOR %s" NLS, c->have_user ? c->user : "nobody");
	buf_addf(b, "BYTE-SIZE 8" NLS);
	buf_addf(b, "LENGTH-IN-BLOCKS %llu" NLS, (len + 1023) / 1024);
	buf_addf(b, "LENGTH-IN-BYTES %llu" NLS, len);
	buf_addf(b, "CREATION-DATE %s" NLS, when);
	if (S_ISDIR(st->st_mode))
		buf_addf(b, "DIRECTORY T" NLS);
}

// ------------------------------------------------------------- the commands

static void control_close(struct control *c, const char *tid, const char *handle);
static void drain_incoming(struct control *c, struct handle *h);

// Answers a CLOSE that was still waiting for its synchronous mark when the
// write it was waiting on was taken away --- an UNDATA-CONNECTION or a DELETE
// on the same handle.  `CNO`, "CLOSE on non-open channel", is `chfile.text`'s
// code for it: by the time the CLOSE could be answered there was no longer a
// channel to close.
//
// The band never gets here.  Its `:REAL-CLOSE` waits for the CLOSE's reply
// before it frees the data connection, its abort route sends the DELETE first
// --- when the CLOSE that follows finds no transfer at all --- and it only
// undoes a data connection that has gone dormant.  This is so that a client
// which does it the other way round is told, rather than left waiting for a
// reply that would never come.
static void stranded(struct control *c, const char *handle, const struct transfer *t)
{
	if (t->closing)
		file_error(c, t->closing_tid, handle, "CNO", 'C',
			   "The transfer was abandoned before its mark");
}

static void cmd_login(struct control *c, const char *tid, const char *handle,
		      const char *args)
{
	struct words ws;
	words_of(&ws, args);
	if (ws.n == 0 || !*ws.w[0]) {
		file_error(c, tid, handle, "UNK", 'C', "Unknown user");
		return;
	}
	const char *user = ws.w[0];
	// `FILE.c`: the name, the home directory with a slash, the full name;
	// the user end takes the home directory and the personal name off the
	// two lines.
	struct buf b = { NULL, 0, 0, 0 };
	buf_addf(&b, "%s /", user);
	for (const char *p = user; *p; ++p) {
		char lower = (*p >= 'A' && *p <= 'Z') ? (char)(*p + 32) : *p;
		buf_add(&b, &lower, 1);
	}
	buf_addf(&b, "/" NLS "%s" NLS, user);
	snprintf(c->user, sizeof c->user, "%s", user);
	c->have_user = 1;
	reply(c, tid, handle, "LOGIN", buf_str(&b));
	buf_free(&b);
}

static void cmd_data_connection(struct control *c, const char *tid,
				const char *handle, const char *args)
{
	struct words ws;
	words_of(&ws, args);
	if (ws.n < 2) {
		file_error(c, tid, handle, "BUG", 'C',
			   "DATA-CONNECTION wants two handles");
		return;
	}
	const char *input = ws.w[0], *output = ws.w[1];
	if (handle_find(c, input) || handle_find(c, output)) {
		file_error(c, tid, handle, "BUG", 'C', "File handle already exists");
		return;
	}
	struct channel *ch = channel_new();
	if (!ch) {
		file_error(c, tid, handle, "MSC", 'C', "Out of memory");
		return;
	}
	struct handle *hi = handle_add(c, input, ch);
	struct handle *ho = handle_add(c, output, ch);
	struct chaos_session *s = data_session_new(ch);
	struct pending *p = calloc(1, sizeof *p);
	if (!hi || !ho || !s || !p) {
		if (hi)
			handle_remove(c, hi);
		if (ho)
			handle_remove(c, ho);
		if (s)
			s->destroy(s);
		free(p);
		channel_unref(ch);
		file_error(c, tid, handle, "MSC", 'C', "Out of memory");
		return;
	}
	// "The output file handle name is the contact name the user end is
	// listening for, so send it."
	chaos_out_connect(&c->out, c->client, output, s);
	snprintf(p->tid, sizeof p->tid, "%s", tid);
	p->ch = channel_ref(ch);
	struct pending **link = &c->pending;
	while (*link)
		link = &(*link)->next;
	*link = p;
	// The two handles, the data session and the pending record each hold a
	// reference now, so this function drops the one it made.  That count is
	// all that is left of muir's `Arc<Mutex<Channel>>`: the sharing is real
	// and the lock would be a claim about concurrency this program does not
	// have.
	channel_unref(ch);
}

static void cmd_undata_connection(struct control *c, const char *tid,
				  const char *handle)
{
	// Both handles of the data connection go, and the transfers on both of
	// them: "UNDATA-CONNECTION implies a CLOSE on each file handle of the
	// DATA connection for which there is a file transfer in progress".  The
	// client names the input handle --- `qfile.lisp` sends
	// `(DATA-INPUT-HANDLE DATA-CONN)` --- and a write is on the output one,
	// so taking only the named handle's transfer would leave a write
	// behind, and its temporary in the directory.
	struct handle *named = handle_find(c, handle);
	if (named) {
		// A reference of this function's own, so that the channel
		// outlives the handles being taken off it: the last
		// `handle_remove` would otherwise free it and leave the
		// comparison below reading a pointer that is no longer one.
		struct channel *ch = channel_ref(named->ch);
		chaos_out_close(&ch->out, "Undata");
		struct handle *h = c->handles;
		while (h) {
			struct handle *next = h->next;
			if (h->ch == ch) {
				if (h->t.kind == T_WRITE) {
					unlink(h->t.temp);
					stranded(c, h->name, &h->t);
				}
				handle_remove(c, h);
			}
			h = next;
		}
		channel_unref(ch);
	}
	reply(c, tid, handle, "UNDATA-CONNECTION", "");
}

// `OPEN WRITE`, then the pathname: a temporary file beside the real one, which
// CLOSE renames into place --- `FILE.c` creates `tempfile(dirname)` and links
// it over the real name on close, "we know that both names are in the same
// directory".
//
// `IF-EXISTS` and `IF-DOES-NOT-EXIST` say what to do about what is there; the
// client sends them by name.  `NEW-VERSION` is what a versioned file system
// does and this one has no versions, so it is `SUPERSEDE` here, which is what
// `FILE.c` turns it into.
static void open_write(struct control *c, const char *tid, const char *handle,
		       const struct words *ws, const char *pathname,
		       const char *path, int binary, int with_default)
{
	const char *if_exists = words_named(ws, "IF-EXISTS");
	const char *if_missing = words_named(ws, "IF-DOES-NOT-EXIST");
	if (!if_exists)
		if_exists = "NEW-VERSION";
	if (!if_missing)
		if_missing = "CREATE";
	const int exists = path_exists(path);
	if (exists) {
		if (!strcmp(if_exists, "ERROR")) {
			file_error(c, tid, handle, "FAE", 'C', "File already exists");
			return;
		}
		if (strcmp(if_exists, "NEW-VERSION") && strcmp(if_exists, "SUPERSEDE") &&
		    strcmp(if_exists, "RENAME") && strcmp(if_exists, "RENAME-AND-DELETE") &&
		    strcmp(if_exists, "TRUNCATE") && strcmp(if_exists, "OVERWRITE") &&
		    strcmp(if_exists, "APPEND")) {
			file_error(c, tid, handle, "UOO", 'C',
				   "%s is not a way to write an existing file",
				   if_exists);
			return;
		}
	} else if (!strcmp(if_missing, "ERROR")) {
		file_error(c, tid, handle, "FNF", 'C', "File not found");
		return;
	}
	char dir[PATH_MAX];
	snprintf(dir, sizeof dir, "%s", path);
	struct stat dst;
	if (path_parent(dir) < 0 || stat(dir, &dst) != 0 || !S_ISDIR(dst.st_mode)) {
		file_error(c, tid, handle, "DNF", 'C', "Directory not found");
		return;
	}
	struct handle *h = handle_find(c, handle);
	if (!h) {
		file_error(c, tid, handle, "BUG", 'C', "No such file handle");
		return;
	}
	// A FIFO or a device where the file would be is not a regular file to
	// overwrite; reading it for APPEND or OVERWRITE would block or exhaust
	// the program's one thread, so it is refused with `WKF`, the band's
	// `WRONG-KIND-OF-FILE` in `sys/io/file/open.lisp`, before a temporary
	// is made.
	if (exists) {
		struct stat st;
		if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) {
			file_error(c, tid, handle, "WKF", 'C', "Not a regular file");
			return;
		}
	}
	// The name is taken from a process-wide counter so that two control
	// connections writing in one directory never collide.  It is muir's
	// name and not a new one: a directory served by either program then
	// shows the same shape, and `#...#` is what MIT's own server left
	// behind too.
	char temp[PATH_MAX];
	{
		char leaf[64];
		snprintf(leaf, sizeof leaf, "#muir-%u-%llu#", c->client,
			 (unsigned long long)next_temp++);
		snprintf(temp, sizeof temp, "%s", dir);
		if (path_push(temp, sizeof temp, leaf) < 0) {
			denied(c, tid, handle);
			return;
		}
	}
	// What is already there, for APPEND, and to start from for OVERWRITE;
	// otherwise the temporary starts empty.
	uint8_t *start = NULL;
	size_t start_len = 0;
	if (exists && (!strcmp(if_exists, "APPEND") || !strcmp(if_exists, "OVERWRITE")))
		start = read_whole(path, &start_len);
	if (write_whole(temp, start, start_len) < 0) {
		free(start);
		file_error(c, tid, handle, "ATD", 'C', "Access to directory denied");
		return;
	}
	const int characters = with_default ? 1 : !binary;
	char tn[FILE_NAME_MAX];
	truename_of(pathname, 0, tn, sizeof tn);
	// The reply is the same shape as a read's: the file's date, its length,
	// whether it is compiled.  Nothing is written yet.
	char when[24];
	now_date(c, when, sizeof when);
	struct buf b = { NULL, 0, 0, 0 };
	buf_addf(&b, "%s %zu NIL" NLS "%s" NLS, when, start_len, tn);
	reply(c, tid, handle, "OPEN", buf_str(&b));
	buf_free(&b);
	free(start);

	transfer_clear(&h->t);
	h->t.kind = T_WRITE;
	snprintf(h->t.temp, sizeof h->t.temp, "%s", temp);
	snprintf(h->t.real, sizeof h->t.real, "%s", path);
	snprintf(h->t.truename, sizeof h->t.truename, "%s", tn);
	h->t.characters = characters;
}

// `OPEN direction mode options`, then the pathname on the next line.
static void cmd_open(struct control *c, const char *tid, const char *handle,
		     const char *args, const char *pathname)
{
	struct words ws;
	words_of(&ws, args);
	const char *direction = ws.n ? ws.w[0] : "READ";
	const int binary = words_have(&ws, "BINARY");
	const int with_default = words_have(&ws, "DEFAULT");
	const char *bs = words_named(&ws, "BYTE-SIZE");
	const long long given_byte_size = bs ? whole_number(bs) : -1;
	const int writing = !strcmp(direction, "WRITE");
	char path[PATH_MAX];
	if ((writing ? resolve_for_writing(c, pathname, path, sizeof path) :
		       resolve(c, pathname, path, sizeof path)) < 0) {
		denied(c, tid, handle);
		return;
	}
	if (writing) {
		open_write(c, tid, handle, &ws, pathname, path, binary, with_default);
		return;
	}
	struct stat st;
	if (stat(path, &st) != 0) {
		file_error(c, tid, handle, "FNF", 'C', "File not found");
		return;
	}
	const int is_dir = S_ISDIR(st.st_mode) ? 1 : 0;
	char when[24];
	file_date(&st, when, sizeof when);
	if (!strcmp(direction, "PROBE-DIRECTORY") ||
	    (!strcmp(direction, "PROBE") && is_dir)) {
		char tn[FILE_NAME_MAX];
		truename_of(pathname, 1, tn, sizeof tn);
		struct buf b = { NULL, 0, 0, 0 };
		buf_addf(&b, "%s 0 NIL" NLS "%s" NLS, when, tn);
		reply(c, tid, handle, "OPEN", buf_str(&b));
		buf_free(&b);
		return;
	}
	if (is_dir) {
		file_error(c, tid, handle, "FNF", 'C', "That is a directory");
		return;
	}
	// Only a regular file is read.  A FIFO with no writer blocks the read
	// for ever, a device streams without end: either would hold or exhaust
	// this program's one thread, so what is neither a directory nor a
	// regular file is refused with `WKF`, the band's `WRONG-KIND-OF-FILE`
	// in `sys/io/file/open.lisp`.  PROBE reaches this too, reading the
	// whole file to measure it.
	if (!S_ISREG(st.st_mode)) {
		file_error(c, tid, handle, "WKF", 'C', "Not a regular file");
		return;
	}
	size_t len = 0;
	uint8_t *contents = read_whole(path, &len);
	if (!contents) {
		file_error(c, tid, handle, "ATF", 'C', "Access to file denied");
		return;
	}
	const int qfasl = len >= 4 && memcmp(contents, CHAOS_FILE_QFASL_MAGIC, 4) == 0;
	// Characters unless the file is compiled, when DEFAULT asks.  `FILE.c`
	// decides that first and only then has a byte size: `options |=
	// O_CHARACTER` happens inside the DEFAULT case, and the length is
	// `options & O_CHARACTER || bytesize <= 8 ? st_size : (st_size + 1) /
	// 2` --- bytes for characters, words for binary, so a compiled file
	// opened DEFAULT is measured in words even though nobody said BINARY.
	const int characters = with_default ? !qfasl : !binary;
	const long long byte_size = given_byte_size >= 0 ? given_byte_size :
							   (characters ? 8 : 16);
	const size_t length = (characters || byte_size <= 8) ? len : (len + 1) / 2;
	// `FILE.c`: date, length, QFASL as T or NIL, and with DEFAULT the
	// characters decision as T or NIL after a space.
	char properties[FILE_PROPS_MAX];
	if (with_default)
		snprintf(properties, sizeof properties, "%s %zu %s %s", when, length,
			 qfasl ? "T" : "NIL", characters ? "T" : "NIL");
	else
		snprintf(properties, sizeof properties, "%s %zu %s", when, length,
			 qfasl ? "T" : "NIL");
	char tn[FILE_NAME_MAX];
	truename_of(pathname, 0, tn, sizeof tn);
	struct buf b = { NULL, 0, 0, 0 };
	buf_addf(&b, "%s" NLS "%s" NLS, properties, tn);
	if (!strcmp(direction, "PROBE")) {
		reply(c, tid, handle, "OPEN", buf_str(&b));
		buf_free(&b);
		free(contents);
		return;
	}
	// READ: down the input handle's data connection.
	struct handle *h = handle_find(c, handle);
	if (!h) {
		file_error(c, tid, handle, "BUG", 'C', "No such file handle");
		buf_free(&b);
		free(contents);
		return;
	}
	reply(c, tid, handle, "OPEN", buf_str(&b));
	buf_free(&b);
	uint8_t op;
	if (characters) {
		op = CHAOS_FILE_CHARACTER_OP;
		chaos_file_to_lispm(contents, (unsigned)len, contents);
	} else {
		op = CHAOS_FILE_BINARY_OP;
	}
	channel_send(h->ch, op, contents, len);
	chaos_out_eof(&h->ch->out);
	transfer_clear(&h->t);
	h->t.kind = T_READ;
	snprintf(h->t.truename, sizeof h->t.truename, "%s", tn);
	snprintf(h->t.properties, sizeof h->t.properties, "%s", properties);
	h->t.contents = contents;
	h->t.contents_len = len;
	h->t.op = op;
}

// `DIRECTORY options`, the pathname on the next line: the listing goes down
// the input handle as records of text, `FILE.c`'s `diropen` and `dirread` --- a
// first record with the file system's properties, then one a file, each a
// pathname line, property lines `NAME value`, and a blank line.
static void cmd_directory(struct control *c, const char *tid, const char *handle,
			  const char *args, const char *pathname)
{
	(void)args;
	struct handle *h = handle_find(c, handle);
	if (!h) {
		file_error(c, tid, handle, "BUG", 'C', "No such file handle");
		return;
	}
	char dir[FILE_NAME_MAX], pattern[FILE_NAME_MAX];
	const char *slash = strrchr(pathname, '/');
	if (slash) {
		snprintf(dir, sizeof dir, "%.*s", (int)(slash - pathname), pathname);
		snprintf(pattern, sizeof pattern, "%s", slash + 1);
	} else {
		dir[0] = '\0';
		snprintf(pattern, sizeof pattern, "%s", pathname);
	}
	char dir_path[PATH_MAX];
	if (resolve(c, dir, dir_path, sizeof dir_path) < 0) {
		denied(c, tid, handle);
		return;
	}
	// The names first, so that they can be sorted as muir sorts them.
	DIR *d = opendir(dir_path);
	if (!d) {
		file_error(c, tid, handle, "DNF", 'C', "Directory not found");
		return;
	}
	char **names = NULL;
	unsigned n = 0, cap = 0;
	struct dirent *de;
	while ((de = readdir(d))) {
		if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
			continue;
		if (!chaos_file_matches(pattern, de->d_name))
			continue;
		if (n == cap) {
			unsigned want = cap ? cap * 2 : 32;
			char **p = realloc(names, want * sizeof *p);
			if (!p)
				break;
			names = p;
			cap = want;
		}
		names[n] = strdup(de->d_name);
		if (!names[n])
			break;
		++n;
	}
	closedir(d);
	for (unsigned i = 1; i < n; ++i) {
		// An insertion sort: a directory of a release is a few hundred
		// names and this is not where the time goes.
		char *v = names[i];
		unsigned j = i;
		while (j > 0 && strcmp(names[j - 1], v) > 0) {
			names[j] = names[j - 1];
			--j;
		}
		names[j] = v;
	}
	// The dir as it is shown back, without its trailing slash.
	char shown_dir[FILE_NAME_MAX];
	snprintf(shown_dir, sizeof shown_dir, "%s", dir);
	{
		size_t l = strlen(shown_dir);
		while (l > 0 && shown_dir[l - 1] == '/')
			shown_dir[--l] = '\0';
	}
	struct buf b = { NULL, 0, 0, 0 };
	buf_addf(&b, NLS "BLOCK-SIZE 1024" NLS
		     "SETTABLE-PROPERTIES CREATION-DATE AUTHOR" NLS NLS);
	for (unsigned i = 0; i < n; ++i) {
		char full[PATH_MAX];
		snprintf(full, sizeof full, "%s", dir_path);
		if (path_push(full, sizeof full, names[i]) < 0)
			continue;
		struct stat st;
		if (stat(full, &st) != 0)
			continue;
		buf_addf(&b, "%s/%s" NLS, shown_dir, names[i]);
		file_properties(c, &st, &b);
		buf_add(&b, NLS, 1);
	}
	for (unsigned i = 0; i < n; ++i)
		free(names[i]);
	free(names);
	reply(c, tid, handle, "DIRECTORY", "");
	// A byte a character: the text already holds the protocol's newline at
	// 0215 and must not be translated again.
	channel_send(h->ch, CHAOS_FILE_CHARACTER_OP, (const uint8_t *)buf_str(&b),
		     b.len);
	chaos_out_eof(&h->ch->out);
	buf_free(&b);
	transfer_clear(&h->t);
	h->t.kind = T_DIRECTORY;
}

// `PROPERTIES`, the pathname on the next line: one record down the data
// connection, the same shape a directory's entries have.
static void cmd_properties(struct control *c, const char *tid, const char *handle,
			   const char *pathname)
{
	struct handle *h = handle_find(c, handle);
	if (!h) {
		file_error(c, tid, handle, "BUG", 'C', "No such file handle");
		return;
	}
	char path[PATH_MAX];
	if (resolve(c, pathname, path, sizeof path) < 0) {
		denied(c, tid, handle);
		return;
	}
	struct stat st;
	if (stat(path, &st) != 0) {
		file_error(c, tid, handle, "FNF", 'C', "File not found");
		return;
	}
	char tn[FILE_NAME_MAX];
	truename_of(pathname, S_ISDIR(st.st_mode) ? 1 : 0, tn, sizeof tn);
	struct buf b = { NULL, 0, 0, 0 };
	buf_addf(&b, "%s" NLS, tn);
	file_properties(c, &st, &b);
	buf_add(&b, NLS, 1);
	reply(c, tid, handle, "PROPERTIES", "");
	channel_send(h->ch, CHAOS_FILE_CHARACTER_OP, (const uint8_t *)buf_str(&b),
		     b.len);
	chaos_out_eof(&h->ch->out);
	buf_free(&b);
	transfer_clear(&h->t);
	h->t.kind = T_DIRECTORY;
}

// `DELETE`: on a handle in the middle of a write it abandons the temporary and
// leaves the real file alone, which is what the client's `:REAL-CLOSE` does
// when it aborts; with a pathname and no handle it removes the file.
static void cmd_delete(struct control *c, const char *tid, const char *handle,
		       const char *pathname)
{
	if (*handle) {
		struct handle *h = handle_find(c, handle);
		if (h && h->t.kind == T_WRITE) {
			unlink(h->t.temp);
			stranded(c, handle, &h->t);
			transfer_clear(&h->t);
			reply(c, tid, handle, "DELETE", "");
			return;
		}
	}
	char path[PATH_MAX];
	if (resolve_for_writing(c, pathname, path, sizeof path) < 0) {
		denied(c, tid, handle);
		return;
	}
	// `lstat`, so that a link that leads nowhere can still be removed.
	struct stat st;
	if (lstat(path, &st) != 0) {
		file_error(c, tid, handle, "FNF", 'C', "File not found");
		return;
	}
	const int is_dir = S_ISDIR(st.st_mode) ? 1 : 0;
	const int gone = is_dir ? rmdir(path) : unlink(path);
	if (gone == 0)
		reply(c, tid, handle, "DELETE", "");
	else if (is_dir)
		file_error(c, tid, handle, "DNE", 'C', "Directory not empty: %s",
			   strerror(errno));
	else
		file_error(c, tid, handle, "ATF", 'C', "%s", strerror(errno));
}

// `RENAME`, the old pathname then the new.
static void cmd_rename(struct control *c, const char *tid, const char *handle,
		       const char *old, const char *new)
{
	char from[PATH_MAX], to[PATH_MAX];
	if (resolve_for_writing(c, old, from, sizeof from) < 0 ||
	    resolve_for_writing(c, new, to, sizeof to) < 0) {
		denied(c, tid, handle);
		return;
	}
	if (!path_exists(from)) {
		file_error(c, tid, handle, "FNF", 'C', "File not found");
		return;
	}
	if (path_exists(to)) {
		file_error(c, tid, handle, "REF", 'C', "Rename to existing file");
		return;
	}
	if (rename(from, to) == 0)
		reply(c, tid, handle, "RENAME", "");
	else
		file_error(c, tid, handle, "ATF", 'C', "%s", strerror(errno));
}

// `CREATE-DIRECTORY`, the pathname on the next line.
static void cmd_create_directory(struct control *c, const char *tid,
				 const char *handle, const char *pathname)
{
	char path[PATH_MAX];
	if (resolve_for_writing(c, pathname, path, sizeof path) < 0) {
		denied(c, tid, handle);
		return;
	}
	if (path_exists(path)) {
		file_error(c, tid, handle, "DAE", 'C', "Directory already exists");
		return;
	}
	if (mkdir(path, 0777) == 0)
		reply(c, tid, handle, "CREATE-DIRECTORY", "");
	else
		file_error(c, tid, handle, "CCD", 'C', "%s", strerror(errno));
}

// `CREATE-LINK`, the link then what it points at.  The target goes through
// `resolve` like anything else, so a link the band makes can only point inside
// the tree and the band cannot widen what it may reach.
static void cmd_create_link(struct control *c, const char *tid, const char *handle,
			    const char *link, const char *target)
{
	char link_path[PATH_MAX], target_path[PATH_MAX];
	if (resolve_for_writing(c, link, link_path, sizeof link_path) < 0 ||
	    resolve(c, target, target_path, sizeof target_path) < 0) {
		denied(c, tid, handle);
		return;
	}
	if (path_exists(link_path)) {
		file_error(c, tid, handle, "FAE", 'C', "File already exists");
		return;
	}
	if (symlink(target_path, link_path) == 0)
		reply(c, tid, handle, "CREATE-LINK", "");
	else
		file_error(c, tid, handle, "CCL", 'C', "%s", strerror(errno));
}

// `CHANGE-PROPERTIES`, the pathname then `NAME value` a line.  Only the ones a
// file here has are settable; the rest are refused by name, as `FILE.c`
// refuses what its property table has no setter for.
static void cmd_change_properties(struct control *c, const char *tid,
				  const char *handle, char **lines, unsigned nlines)
{
	const char *pathname = nlines ? lines[0] : "";
	char path[PATH_MAX];
	if (resolve_for_writing(c, pathname, path, sizeof path) < 0) {
		denied(c, tid, handle);
		return;
	}
	if (!path_exists(path)) {
		file_error(c, tid, handle, "FNF", 'C', "File not found");
		return;
	}
	for (unsigned i = 1; i < nlines; ++i) {
		if (!*lines[i])
			continue;
		char name[64];
		const char *sp = strchr(lines[i], ' ');
		snprintf(name, sizeof name, "%.*s",
			 sp ? (int)(sp - lines[i]) : (int)strlen(lines[i]), lines[i]);
		// The dates and the author are what `FILE.c` can set; nothing
		// here keeps an author, and a date is the file's own, which is
		// left as the filesystem has it.
		if (!strcmp(name, "CREATION-DATE") || !strcmp(name, "MODIFICATION-DATE") ||
		    !strcmp(name, "REFERENCE-DATE") || !strcmp(name, "AUTHOR") || !*name)
			continue;
		file_error(c, tid, handle, "UKP", 'C', "%s cannot be set here", name);
		return;
	}
	reply(c, tid, handle, "CHANGE-PROPERTIES", "");
}

// `COMPLETE options`, the default pathname then the string to complete.  The
// reply is a status word and the completion, a line each: the client reads the
// word as a keyword and takes `NIL` for no completion.
static void cmd_complete(struct control *c, const char *tid, const char *handle,
			 const char *args, const char *deflt, const char *partial)
{
	const int new_ok = strstr(args, "NEW-OK") != NULL;
	char dir[FILE_NAME_MAX], stem[FILE_NAME_MAX];
	const char *slash = strrchr(partial, '/');
	if (slash) {
		snprintf(dir, sizeof dir, "%.*s", (int)(slash - partial), partial);
		snprintf(stem, sizeof stem, "%s", slash + 1);
	} else {
		const char *dslash = strrchr(deflt, '/');
		if (dslash)
			snprintf(dir, sizeof dir, "%.*s", (int)(dslash - deflt), deflt);
		else
			dir[0] = '\0';
		snprintf(stem, sizeof stem, "%s", partial);
	}
	char dir_path[PATH_MAX];
	if (resolve(c, dir, dir_path, sizeof dir_path) < 0) {
		denied(c, tid, handle);
		return;
	}
	// The longest head the hits share, kept as they are found, which is the
	// same answer as muir's sort-then-fold and needs no array.
	const size_t stem_len = strlen(stem);
	unsigned hits = 0;
	char common[FILE_NAME_MAX];
	common[0] = '\0';
	DIR *d = opendir(dir_path);
	if (d) {
		struct dirent *de;
		while ((de = readdir(d))) {
			if (!strcmp(de->d_name, ".") || !strcmp(de->d_name, ".."))
				continue;
			if (strncmp(de->d_name, stem, stem_len) != 0)
				continue;
			if (hits == 0) {
				snprintf(common, sizeof common, "%s", de->d_name);
			} else {
				size_t k = 0;
				while (common[k] && de->d_name[k] &&
				       common[k] == de->d_name[k])
					++k;
				common[k] = '\0';
			}
			++hits;
		}
		closedir(d);
	}
	// The dir as it is shown back, without its trailing slash.
	char shown_dir[FILE_NAME_MAX];
	snprintf(shown_dir, sizeof shown_dir, "%s", dir);
	{
		size_t l = strlen(shown_dir);
		while (l > 0 && shown_dir[l - 1] == '/')
			shown_dir[--l] = '\0';
	}
	const char *status;
	struct buf b = { NULL, 0, 0, 0 };
	if (hits == 0)
		status = new_ok ? "NEW" : "NIL";
	else if (hits == 1)
		status = "OLD";
	else
		status = "NIL";
	buf_addf(&b, "%s" NLS "%s/%s" NLS, status, shown_dir,
		 hits == 0 ? stem : common);
	reply(c, tid, handle, "COMPLETE", buf_str(&b));
	buf_free(&b);
}

// `FILEPOS <n>`: the read goes on from byte `n`.
//
// The client sends this with its mark flag set --- `:COMMAND T "File Position"
// "FILEPOS " n` --- and then reads until a synchronous mark, which is how it
// throws away what is already in flight from the old position.  So the reply
// comes first, then the mark, and then the file again from where it was asked
// for.
//
// The position is in the bytes as they go down the wire, which for a character
// file is after the translation: that is what the client counts, having read
// them itself.
static void cmd_filepos(struct control *c, const char *tid, const char *handle,
			const char *arg)
{
	const long long at = whole_number(arg);
	if (at < 0) {
		file_error(c, tid, handle, "FOR", 'C', "Filepos out of range");
		return;
	}
	struct handle *h = handle_find(c, handle);
	if (!h || h->t.kind != T_READ) {
		file_error(c, tid, handle, "BUG", 'C', "No transfer to position");
		return;
	}
	if ((size_t)at > h->t.contents_len) {
		file_error(c, tid, handle, "FOR", 'C', "Filepos out of range");
		return;
	}
	reply(c, tid, handle, "FILEPOS", "");
	// What is still queued from the old position never goes.
	channel_drop_data(h->ch);
	channel_mark(h->ch, CHAOS_FILE_SYNC_MARK_OP);
	channel_send(h->ch, h->t.op, h->t.contents + at, h->t.contents_len - (size_t)at);
	chaos_out_eof(&h->ch->out);
}

// Stops a transfer with a **recoverable** error, AIM-628's `E_RECOVERABLE`: an
// asynchronous mark down the data connection, which `FILE.c`'s `fherror`
// writes as `TIDNO <handle> ERROR <code> R <message>`, the literal `TIDNO`
// standing where a transaction id would be.  The client's
// `QFILE-PROCESS-ASYNC-MARK` strips that first word, shows the error as
// proceedable, and sends CONTINUE if the user proceeds.
static void async_mark(struct handle *h, const char *code, const char *message)
{
	struct buf b = { NULL, 0, 0, 0 };
	buf_addf(&b, "TIDNO %s ERROR %s R %s", h->name, code, message);
	channel_send(h->ch, CHAOS_FILE_ASYNC_MARK_OP, (const uint8_t *)buf_str(&b),
		     b.len);
	buf_free(&b);
}

// `CONTINUE`: retries what the stalled append is holding.
//
// `FILE.c` answers the command and lets the transfer retry after ---
// `filecontinue` sets `X_RETRY` and responds --- so the reply says only that
// the command was understood, and a retry that fails again raises another
// mark.  With no transfer, or one that is not stopped, it is the server's own
// `BUG`, "CONTINUE received when not in error state".
//
// The one mark this service sends is a write that ran out of room, `NMR` from
// `wrote`, so that is the one transfer that can be continued.
static void cmd_continue(struct control *c, const char *tid, const char *handle)
{
	struct handle *h = *handle ? handle_find(c, handle) : NULL;
	if (!h || h->t.kind == T_NONE) {
		file_error(c, tid, handle, "BUG", 'C', "No transfer to continue");
		return;
	}
	if (h->t.kind != T_WRITE || !h->t.stalled) {
		file_error(c, tid, handle, "BUG", 'C',
			   "CONTINUE received when not in error state");
		return;
	}
	reply(c, tid, handle, "CONTINUE", "");
	uint8_t *held = h->t.held;
	const size_t held_len = h->t.held_len;
	h->t.held = NULL;
	h->t.held_len = 0;
	h->t.stalled = 0;
	if (append(h->t.temp, held, held_len) == 0) {
		free(held);
		return;
	}
	snprintf(h->t.why, sizeof h->t.why, "%s", strerror(errno));
	h->t.stalled = 1;
	h->t.held = held;
	h->t.held_len = held_len;
	async_mark(h, "NMR", h->t.why);
}

// Data that has come up a data connection: appended to whatever the handle is
// writing, translated out of the Lisp Machine character set if it is
// characters.
static void wrote(struct handle *h, uint8_t op, const uint8_t *bytes, unsigned len)
{
	if (h->t.kind != T_WRITE)
		return;
	uint8_t *out = malloc(len ? len : 1);
	if (!out) {
		say("out of memory taking %u bytes for a write", len);
		return;
	}
	if (h->t.characters && op != CHAOS_FILE_BINARY_OP)
		chaos_file_from_lispm(bytes, len, out);
	else
		memcpy(out, bytes, len);
	// Already stopped: the client should have stopped sending, but whatever
	// arrives joins what is waiting rather than being lost.
	if (h->t.stalled) {
		uint8_t *p = realloc(h->t.held, h->t.held_len + len);
		if (!p) {
			say("out of memory holding a stalled write");
			free(out);
			return;
		}
		memcpy(p + h->t.held_len, out, len);
		h->t.held = p;
		h->t.held_len += len;
		free(out);
		return;
	}
	if (append(h->t.temp, out, len) == 0) {
		free(out);
		return;
	}
	snprintf(h->t.why, sizeof h->t.why, "%s", strerror(errno));
	h->t.stalled = 1;
	h->t.held = out;
	h->t.held_len = len;
	async_mark(h, "NMR", h->t.why);
}

// Takes everything waiting on a handle's data connection and gives it to the
// write in progress on that handle, in order.  A handle with no transfer has
// its waiting data discarded --- there is nowhere for it to go, and keeping it
// would grow without bound.
static void drain_incoming(struct control *c, struct handle *h)
{
	(void)c;
	if (!h)
		return;
	struct incoming *i = h->ch->in_head;
	h->ch->in_head = h->ch->in_tail = NULL;
	while (i) {
		struct incoming *next = i->next;
		// A synchronous mark says the data is all there; it carries
		// none of its own, and it is what a CLOSE waits for.
		if (i->op == CHAOS_FILE_SYNC_MARK_OP) {
			if (h->t.kind == T_WRITE)
				h->t.marked = 1;
		} else if (i->op != CHAOS_FILE_ASYNC_MARK_OP) {
			if (h->t.kind != T_NONE)
				wrote(h, i->op, i->bytes, i->len);
		}
		free(i);
		i = next;
	}
}

// `CLOSE`: answered on the control connection, and for a read followed by the
// synchronous mark down the data connection, in that order --- "we must
// respond to the close before sending the SYNCMARK since otherwise we would
// likely block".
//
// For a write it is the other way about: the mark is **awaited**, and only
// then does the close rename the temporary into place and answer with the
// file's date, its length and its truename --- `FILE.c`'s `xclose`, which
// writes that plain form when the protocol version is above zero and one with
// a leading `-1` for an older client.
static void control_close(struct control *c, const char *tid, const char *handle)
{
	struct handle *h = handle_find(c, handle);
	// Any data that arrived on the data connection but has not yet been
	// moved into the write goes in before the temporary is renamed: a CLOSE
	// can follow the last data packet with no turn of the server between
	// them.
	drain_incoming(c, h);
	// A write's CLOSE comes up the control connection and its mark up the
	// data connection, and the two can overtake each other:
	// `sys/doc/chfile.text`'s worked example for writing a file sends "a
	// SYNC mark on the DATA connection and a CLOSE on the CONTROL
	// connection (in either order)", so a CLOSE that arrives first is a
	// correct client's doing rather than a fault.  The mark is what says
	// the data is all there, and renaming without it would put a file into
	// place short of whatever had not arrived --- empty, if none of it had.
	// So the transfer stays open and the CLOSE is answered from the poll
	// once the mark has come.
	//
	// The client sends the two that way round and does not wait between
	// them: `qfile.lisp`'s `:COMMAND` writes the command packet on the
	// control connection and then, for an output stream, `(SEND STREAM
	// :WRITE-SYNCHRONOUS-MARK)` before it waits for the response.  So
	// holding the reply back cannot hold the mark back with it.
	if (h && h->t.kind == T_WRITE && !h->t.marked && !h->t.stalled) {
		h->t.closing = 1;
		snprintf(h->t.closing_tid, sizeof h->t.closing_tid, "%s", tid);
		return;
	}
	if (!h || h->t.kind == T_NONE) {
		file_error(c, tid, handle, "BUG", 'C',
			   "No transfer in progress on this file handle");
		return;
	}
	if (h->t.kind == T_READ) {
		struct buf b = { NULL, 0, 0, 0 };
		buf_addf(&b, "%s" NLS "%s" NLS, h->t.properties, h->t.truename);
		transfer_clear(&h->t);
		reply(c, tid, handle, "CLOSE", buf_str(&b));
		buf_free(&b);
		channel_mark(h->ch, CHAOS_FILE_SYNC_MARK_OP);
		return;
	}
	if (h->t.kind == T_DIRECTORY) {
		transfer_clear(&h->t);
		reply(c, tid, handle, "CLOSE", "");
		channel_mark(h->ch, CHAOS_FILE_SYNC_MARK_OP);
		return;
	}
	if (h->t.stalled) {
		// The file would be short of whatever the stall is holding, so
		// it does not go into place; the error that stopped it is
		// repeated, fatal this time.
		char why[sizeof h->t.why];
		snprintf(why, sizeof why, "%s", h->t.why);
		unlink(h->t.temp);
		transfer_clear(&h->t);
		file_error(c, tid, handle, "NMR", 'F', "%s", why);
		return;
	}
	char temp[PATH_MAX], real[PATH_MAX], tn[FILE_NAME_MAX];
	snprintf(temp, sizeof temp, "%s", h->t.temp);
	snprintf(real, sizeof real, "%s", h->t.real);
	snprintf(tn, sizeof tn, "%s", h->t.truename);
	transfer_clear(&h->t);
	if (rename(temp, real) != 0) {
		const int e = errno;
		unlink(temp);
		file_error(c, tid, handle, "MSC", 'F', "%s", strerror(e));
		return;
	}
	struct stat st;
	unsigned long long length = 0;
	char when[24];
	if (stat(real, &st) == 0) {
		length = (unsigned long long)st.st_size;
		file_date(&st, when, sizeof when);
	} else {
		now_date(c, when, sizeof when);
	}
	struct buf b = { NULL, 0, 0, 0 };
	if (c->version == 0)
		buf_add(&b, "-1 ", 3);
	buf_addf(&b, "%s %llu" NLS "%s" NLS, when, length, tn);
	reply(c, tid, handle, "CLOSE", buf_str(&b));
	buf_free(&b);
}

// ---------------------------------------------------------- the command line

// A parsed command: `tid handle COMMAND args`, then the further lines.
struct command {
	char *text;		// owned; the packet's bytes, cut into lines
	char **lines;		// owned; every line, the first included
	unsigned nlines;
	const char *tid, *handle, *name, *args;
};

// `tid <sp> [fh] <sp> cmd [args]`, and two spaces where there is no handle.
// Returns 0 if it is a command at all; muir's `parse` answers `None` for
// anything else and the command is then ignored without a reply, which is what
// `FILE.c` does with a line it cannot read.
static int command_parse(struct command *c, const uint8_t *bytes, unsigned len)
{
	memset(c, 0, sizeof *c);
	c->text = malloc(len + 1);
	if (!c->text) {
		say("out of memory taking a %u byte command", len);
		return -1;
	}
	memcpy(c->text, bytes, len);
	c->text[len] = '\0';
	unsigned n = 1;
	for (unsigned i = 0; i < len; ++i)
		if ((unsigned char)c->text[i] == CHAOS_FILE_NEWLINE)
			++n;
	c->lines = malloc(n * sizeof *c->lines);
	if (!c->lines) {
		say("out of memory cutting a command into %u lines", n);
		return -1;
	}
	c->nlines = 0;
	c->lines[c->nlines++] = c->text;
	for (unsigned i = 0; i < len; ++i) {
		if ((unsigned char)c->text[i] == CHAOS_FILE_NEWLINE) {
			c->text[i] = '\0';
			c->lines[c->nlines++] = c->text + i + 1;
		}
	}
	char *first = c->lines[0];
	char *sp = strchr(first, ' ');
	if (!sp)
		return -1;
	*sp = '\0';
	c->tid = first;
	char *rest = sp + 1;
	if (*rest == ' ') {
		c->handle = "";
		++rest;
	} else {
		sp = strchr(rest, ' ');
		if (!sp)
			return -1;
		*sp = '\0';
		c->handle = rest;
		rest = sp + 1;
	}
	sp = strchr(rest, ' ');
	if (sp) {
		*sp = '\0';
		c->name = rest;
		c->args = sp + 1;
	} else {
		c->name = rest;
		c->args = "";
	}
	return 0;
}

static void command_free(struct command *c)
{
	free(c->lines);
	free(c->text);
}

// The lines after the first, which is where every pathname the protocol
// carries lives.  muir's `c.lines` is exactly this list and `first()` is
// index 0 of it.
static const char *cmd_line(const struct command *c, unsigned i)
{
	return i + 1 < c->nlines ? c->lines[i + 1] : "";
}

static void control_command(struct control *c, const uint8_t *bytes, unsigned len)
{
	struct command cmd;
	if (command_parse(&cmd, bytes, len) < 0) {
		command_free(&cmd);
		return;
	}
	const char *tid = cmd.tid, *handle = cmd.handle, *name = cmd.name;
	if (!strcmp(name, "LOGIN")) {
		cmd_login(c, tid, handle, cmd.args);
	} else if (!strcmp(name, "DATA-CONNECTION")) {
		cmd_data_connection(c, tid, handle, cmd.args);
	} else if (!strcmp(name, "UNDATA-CONNECTION")) {
		cmd_undata_connection(c, tid, handle);
	} else if (!strcmp(name, "OPEN")) {
		cmd_open(c, tid, handle, cmd.args, cmd_line(&cmd, 0));
	} else if (!strcmp(name, "DIRECTORY")) {
		cmd_directory(c, tid, handle, cmd.args, cmd_line(&cmd, 0));
	} else if (!strcmp(name, "CLOSE")) {
		control_close(c, tid, handle);
	} else if (!strcmp(name, "DELETE")) {
		cmd_delete(c, tid, handle, cmd_line(&cmd, 0));
	} else if (!strcmp(name, "RENAME")) {
		cmd_rename(c, tid, handle, cmd_line(&cmd, 0), cmd_line(&cmd, 1));
	} else if (!strcmp(name, "CREATE-DIRECTORY")) {
		cmd_create_directory(c, tid, handle, cmd_line(&cmd, 0));
	} else if (!strcmp(name, "CREATE-LINK")) {
		cmd_create_link(c, tid, handle, cmd_line(&cmd, 0), cmd_line(&cmd, 1));
	} else if (!strcmp(name, "EXPUNGE")) {
		// `FILE.c`'s `expunge` answers with the number of blocks it
		// recovered, and on Unix, where a delete is a delete, that is
		// always none.
		reply(c, tid, handle, "EXPUNGE", "0");
	} else if (!strcmp(name, "CHANGE-PROPERTIES")) {
		cmd_change_properties(c, tid, handle, cmd.lines + 1,
				      cmd.nlines ? cmd.nlines - 1 : 0);
	} else if (!strcmp(name, "COMPLETE")) {
		cmd_complete(c, tid, handle, cmd.args, cmd_line(&cmd, 0),
			     cmd_line(&cmd, 1));
	} else if (!strcmp(name, "FILEPOS")) {
		// Position within a transfer: nothing here reads a file in
		// pieces, so the only position that can be asked for is the one
		// it is already at.
		cmd_filepos(c, tid, handle, cmd.args);
	} else if (!strcmp(name, "PROPERTIES")) {
		cmd_properties(c, tid, handle, cmd_line(&cmd, 0));
	} else if (!strcmp(name, "CONTINUE")) {
		cmd_continue(c, tid, handle);
	} else {
		file_error(c, tid, handle, "UKC", 'C', "%s is not served here", name);
	}
	command_free(&cmd);
}

// ----------------------------------------------------- the control session

static void control_opened(struct chaos_session *s, uint64_t now)
{
	(void)s;
	(void)now;
}

static void control_data(struct chaos_session *s, uint64_t now, uint8_t op,
			 const uint8_t *bytes, unsigned len)
{
	(void)now;
	(void)op;
	control_command((struct control *)s, bytes, len);
}

static void control_eof(struct chaos_session *s, uint64_t now)
{
	(void)s;
	(void)now;
}

static void control_closed(struct chaos_session *s, uint64_t now, const char *reason)
{
	(void)now;
	(void)reason;
	struct control *c = (struct control *)s;
	// A write that never reached its CLOSE --- the user end's connection
	// dropped, or the machine rebooted under it --- leaves a temporary that
	// will never be renamed into place; remove it.
	for (struct handle *h = c->handles; h; h = h->next)
		if (h->t.kind == T_WRITE)
			unlink(h->t.temp);
	for (struct handle *h = c->handles; h; h = h->next)
		chaos_out_close(&h->ch->out, "Control connection closed");
}

static void control_poll(struct chaos_session *s, uint64_t now, struct chaos_outq *q)
{
	(void)now;
	struct control *c = (struct control *)s;
	// Data connections that have opened since: answered now.
	struct pending **link = &c->pending;
	while (*link) {
		struct pending *p = *link;
		if (!p->ch->open) {
			link = &p->next;
			continue;
		}
		*link = p->next;
		reply(c, p->tid, "", "DATA-CONNECTION", "");
		channel_unref(p->ch);
		free(p);
	}
	// What the user end has sent up a data connection belongs to the
	// **write** in progress on that connection, and to nothing else.  Both
	// handles of a connection share one channel, so draining the handle
	// that is writing takes it all; the other is left alone, or it would
	// steal its sibling's data --- and it will have a transfer of its own
	// whenever the user end is reading a file and writing one at once,
	// which is what the band does through every compile
	// (`sys/qcfile.lisp`'s `QC-FILE` holds the source open around the QFASL
	// it writes).  Selecting on *a* transfer rather than a write is how a
	// compiled file came to be written to no one: the read's drain took the
	// write's bytes, dropped them for having nowhere to go, and the clear
	// below finished the job.
	for (struct handle *h = c->handles; h; h = h->next)
		if (h->t.kind == T_WRITE)
			drain_incoming(c, h);
	// A CLOSE that overtook its synchronous mark waits in the transfer; the
	// mark has now come, so it can be answered.  A write that has stalled
	// since goes through here too, to the error the stalled arm gives it: a
	// stall holds bytes that have not been written, so no mark can make
	// that file whole.
	//
	// The name is copied out first, because `control_close` frees the
	// transfer the tid is being read from.
	for (;;) {
		struct handle *ready = NULL;
		for (struct handle *h = c->handles; h; h = h->next) {
			if (h->t.kind == T_WRITE && h->t.closing &&
			    (h->t.marked || h->t.stalled)) {
				ready = h;
				break;
			}
		}
		if (!ready)
			break;
		char tid[FILE_TID_MAX], name[FILE_HANDLE_MAX];
		snprintf(tid, sizeof tid, "%s", ready->t.closing_tid);
		snprintf(name, sizeof name, "%s", ready->name);
		ready->t.closing = 0;
		control_close(c, tid, name);
	}
	// Anything still waiting has no write to go to --- data before an OPEN
	// WRITE, or after a CLOSE --- and is discarded, so a channel never
	// grows without bound.
	for (struct handle *h = c->handles; h; h = h->next)
		channel_clear_incoming(h->ch);
	outq_splice(q, &c->out);
}

static void control_destroy(struct chaos_session *s)
{
	struct control *c = (struct control *)s;
	while (c->handles)
		handle_remove(c, c->handles);
	while (c->pending) {
		struct pending *p = c->pending;
		c->pending = p->next;
		channel_unref(p->ch);
		free(p);
	}
	chaos_outq_clear(&c->out);
	free(c);
}

// ------------------------------------------------------------- the service

struct file_service {
	struct chaos_service base;
	char root[PATH_MAX];
	uint32_t fixed;
	uint16_t *hosts;
	unsigned nhosts;
};

static void file_request(struct chaos_service *sv, uint64_t now, const char *args,
			 uint16_t from_host, uint16_t from_index,
			 struct chaos_response *r)
{
	(void)now;
	(void)from_index;
	struct file_service *f = (struct file_service *)sv;
	memset(r, 0, sizeof *r);
	// Who may have files is not who could reach the cable: a peer over
	// CHUDP is answerable without being authorised.
	if (f->nhosts) {
		int served = 0;
		for (unsigned i = 0; i < f->nhosts; ++i)
			if (f->hosts[i] == from_host)
				served = 1;
		if (!served) {
			r->kind = CHAOS_RESP_REFUSE;
			snprintf(r->reason, sizeof r->reason,
				 "%o is not served files by this host", from_host);
			return;
		}
	}
	struct control *c = calloc(1, sizeof *c);
	if (!c) {
		say("out of memory accepting a FILE connection");
		r->kind = CHAOS_RESP_REFUSE;
		snprintf(r->reason, sizeof r->reason, "Out of memory");
		return;
	}
	c->base.opened = control_opened;
	c->base.data = control_data;
	c->base.eof = control_eof;
	c->base.closed = control_closed;
	c->base.poll = control_poll;
	c->base.destroy = control_destroy;
	snprintf(c->root, sizeof c->root, "%s", f->root);
	c->fixed = f->fixed;
	c->client = from_host;
	// The protocol version from the RFC's argument, and 1 for anything that
	// is not a number, which is muir's `unwrap_or(1)`.
	{
		struct words ws;
		words_of(&ws, args ? args : "");
		const long long v = ws.n ? whole_number(ws.w[0]) : -1;
		c->version = v >= 0 ? (uint32_t)v : 1u;
	}
	r->kind = CHAOS_RESP_ACCEPT;
	r->session = &c->base;
}

static void file_destroy(struct chaos_service *sv)
{
	struct file_service *f = (struct file_service *)sv;
	free(f->hosts);
	free(f);
}

struct chaos_service *chaos_file_new(const char *root, uint32_t fixed,
				     const uint16_t *hosts, unsigned nhosts)
{
	struct file_service *f = calloc(1, sizeof *f);
	if (!f) {
		say("out of memory making the FILE service");
		return NULL;
	}
	f->base.contact = CHAOS_FILE_CONTACT;
	f->base.request = file_request;
	f->base.destroy = file_destroy;
	// The root is kept without a trailing slash, so that the "is this the
	// root itself" test a write makes is a `strcmp`.  `PathBuf` compares by
	// component and does not need this; C does.
	snprintf(f->root, sizeof f->root, "%s", root ? root : ".");
	{
		size_t l = strlen(f->root);
		while (l > 1 && f->root[l - 1] == '/')
			f->root[--l] = '\0';
	}
	f->fixed = fixed;
	if (nhosts) {
		f->hosts = malloc(nhosts * sizeof *f->hosts);
		if (!f->hosts) {
			say("out of memory keeping %u served addresses", nhosts);
			free(f);
			return NULL;
		}
		memcpy(f->hosts, hosts, nhosts * sizeof *f->hosts);
		f->nhosts = nhosts;
	}
	return &f->base;
}
