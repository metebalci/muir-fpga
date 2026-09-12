// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The FILE service, held against a real directory: `chaos_file.c`'s check.
//
// **NO BOARD, NO FABRIC, NO NETWORK.**  The session object is driven directly
// --- `chaos_file_new(...)->request(...)` hands back a `struct chaos_session
// *`, a command goes in through its `data`, and what the service wants sent
// comes out of its `poll` into a queue this file reads.  A data connection is
// the same thing one level down: the service asks the transport to call a
// contact name, and what the transport would have made is taken straight out
// of the queue and driven the same way.  So everything below is the protocol
// and the filesystem and nothing else, which is what lets it run on the build
// host in a fraction of a second.
//
// **WHY IT IS WORTH THIS MUCH TROUBLE.**  A board that boots MIT's Lisp
// Machine system and paints the window system prints
// `#<ZWEI::ZWEI-FILE-HOST "ED-FILE"> is not a known host`.  The service under
// test is what answers that, and the two properties that decide whether a real
// band gets its file are held here in as many words: the bytes that go down a
// data connection are the file's, with the Lisp Machine's newline where Unix
// has its own; and **the containment**, which has a section of its own,
// because a file server that can be walked out of is worse than no file
// server.
//
// **THE SCRATCH TREE IS THIS SUITE'S OWN AND NOT `chaos_test_scratch`'s.**
// The containment checks need two directories that are NOT under the served
// root --- one linked at the root, which must be followed, and one linked
// deeper, which must not be --- and a single scratch leaf cannot be both
// inside and outside itself.  So this builds its own parent, under
// `chaos_test_work_root()` so that `--work` still reaches it, never under
// `$HOME` directly and never under `/tmp`, which is a RAM disk on this build
// host.

#include "chaos_test.h"

#include <dirent.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "chaos_file.h"
#include "chaos_ncp.h"

// The Lisp Machine's newline as a string, so that a command and an expected
// reply can be written out the way they go on the wire.
#define NLS "\215"

// The client this suite is: a plausible Chaosnet address, and the one the
// service is told to serve.
#define CLIENT 03050
#define STRANGER 04401

// ------------------------------------------------------------- the scratch

static char work[256];		// the suite's own directory
static char root[512];		// the served root, under it
static char release[512];	// a tree linked AT THE ROOT: must be followed
static char elsewhere[512];	// a tree linked deeper: must not be
// A directory that is NOT the root and whose path BEGINS WITH THE ROOT'S as
// text --- `.../servedmore` beside `.../served`.  Containment is a question
// about components and not about characters, and this is the only shape that
// tells the two apart.
static char sibling[512];

static void shell(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void shell(const char *fmt, ...)
{
	char cmd[2048];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(cmd, sizeof cmd, fmt, ap);
	va_end(ap);
	if (system(cmd) != 0)
		chaos_test_fail(__FILE__, __LINE__, "could not run %s", cmd);
}

static void put(const char *path, const char *bytes, size_t len)
{
	FILE *f = fopen(path, "wb");
	if (!f) {
		chaos_test_fail(__FILE__, __LINE__, "cannot write %s", path);
		return;
	}
	if (len)
		fwrite(bytes, 1, len, f);
	fclose(f);
}

// The whole of a file, for comparing against what was written.  Returns the
// length, or -1 if it is not there.
static long slurp(const char *path, char *into, size_t max)
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return -1;
	size_t n = fread(into, 1, max, f);
	fclose(f);
	return (long)n;
}

// How many entries of `dir` begin with `prefix`: the temporary a write goes
// through is counted this way, which is the only way to see it from outside.
static unsigned count_prefixed(const char *dir, const char *prefix)
{
	DIR *d = opendir(dir);
	if (!d)
		return 0;
	unsigned n = 0;
	struct dirent *de;
	const size_t pl = strlen(prefix);
	while ((de = readdir(d)))
		if (!strncmp(de->d_name, prefix, pl))
			++n;
	closedir(d);
	return n;
}

// The file's own date, in the form the protocol carries it, so that an OPEN's
// properties can be compared in full rather than around the date.
static void stat_date(const char *path, char *into, size_t n)
{
	struct stat st;
	if (stat(path, &st) != 0) {
		// Not a date any file can have, and no trigraph in it.
		snprintf(into, n, "00/00/00 00:00:00");
		return;
	}
	chaos_file_date((uint64_t)st.st_mtime, into, (unsigned)n);
}

// The served tree.  Written out rather than copied from anywhere, so that
// every byte a check compares against is in this file.
static const char HELLO[] = "Hello, ED-FILE." "\n" "Two lines." "\n";
// The same file as it must go down a data connection: the Lisp Machine's
// newline, 0215, where the host's file has 012.  Written as a literal and not
// computed, so that a mutation to the translation cannot move both sides.
static const char HELLO_WIRE[] = "Hello, ED-FILE." NLS "Two lines." NLS;
static const char BANNER[] = "the release tree, reached through the root's link" "\n";
static const char SECRET[] = "the host's own business" "\n";
// Three packets and a bit: 488 bytes is what one carries.
#define BIG_LEN 1500u

static void build_tree(void)
{
	// Under the harness's work root, which `--work` names, and not under
	// `$HOME` directly: `mutate.py` gives every mutant its own work root,
	// and a suite that ignored it would write into the baseline's tree.
	snprintf(work, sizeof work, "%s/file", chaos_test_work_root());
	shell("rm -rf '%s'", work);
	shell("mkdir -p '%s'", work);
	snprintf(root, sizeof root, "%s/served", work);
	snprintf(release, sizeof release, "%s/release", work);
	snprintf(elsewhere, sizeof elsewhere, "%s/elsewhere", work);
	snprintf(sibling, sizeof sibling, "%s/servedmore", work);
	shell("mkdir -p '%s/notes' '%s' '%s' '%s'", root, release, elsewhere, sibling);

	char p[768];
	snprintf(p, sizeof p, "%s/hello.text", root);
	put(p, HELLO, sizeof HELLO - 1);
	snprintf(p, sizeof p, "%s/empty.text", root);
	put(p, "", 0);
	snprintf(p, sizeof p, "%s/notes/one.text", root);
	put(p, "one" "\n", 4);
	snprintf(p, sizeof p, "%s/notes/two.lisp", root);
	put(p, "(two)" "\n", 6);
	snprintf(p, sizeof p, "%s/banner.text", release);
	put(p, BANNER, sizeof BANNER - 1);
	snprintf(p, sizeof p, "%s/secret.text", elsewhere);
	put(p, SECRET, sizeof SECRET - 1);
	snprintf(p, sizeof p, "%s/hidden.text", sibling);
	put(p, SECRET, sizeof SECRET - 1);
	// A file of more than one packet: the service chunks its own output,
	// because only it knows where a chunk may end, and a check whose files
	// all fit in one packet would never look at that loop.
	{
		char big[BIG_LEN];
		for (unsigned i = 0; i < BIG_LEN; ++i)
			big[i] = (i % 50 == 49) ? '\n' : (char)('a' + i % 26);
		snprintf(p, sizeof p, "%s/big.text", root);
		put(p, big, BIG_LEN);
	}
	// A compiled file, by its first four bytes: `QFASL` in sixbit.
	snprintf(p, sizeof p, "%s/fasl.qfasl", root);
	put(p, CHAOS_FILE_QFASL_MAGIC "xy", 6);

	// The link AT THE ROOT is how each release's sources are put under the
	// root --- `sys` for System 304, `tree` for System 100 --- and must be
	// followed.  The link one level deeper must not be.
	shell("ln -s '%s' '%s/sys'", release, root);
	shell("ln -s '%s' '%s/notes/escape'", elsewhere, root);
	shell("ln -s '%s' '%s/notes/sneak'", sibling, root);
}

// ---------------------------------------------------- driving the sessions

#define WIRE_CTL 16384
#define WIRE_EVENTS 512

enum ev_kind { EV_DATA, EV_EOF, EV_CLOSE };

struct wire {
	struct chaos_service *sv;
	struct chaos_session *control;
	// The data connections the service asked the transport to make, in the
	// order it asked.
	struct chaos_session *data[4];
	// As wide as the queue node it is copied out of, so that the copy
	// cannot be the thing that shortens a contact name.
	char contact[4][sizeof ((struct chaos_out *)0)->text];
	unsigned ndata;
	// What came down the control connection since the last command.
	char ctl[WIRE_CTL];
	size_t ctl_n;
	int ctl_closed;
	// What came down the data connections since the last command.
	struct {
		enum ev_kind kind;
		uint8_t op;
		unsigned len;
		uint8_t b[CHAOS_PKT_MAX_DATA];
	} ev[WIRE_EVENTS];
	unsigned nev;
	uint64_t now;
};

static struct wire w;

static void take(struct chaos_outq *q, int is_control)
{
	struct chaos_out *o;
	while ((o = chaos_outq_pop(q))) {
		if (is_control) {
			switch (o->kind) {
			case CHAOS_OUT_DATA:
				if (w.ctl_n + o->len < sizeof w.ctl) {
					memcpy(w.ctl + w.ctl_n, o->bytes, o->len);
					w.ctl_n += o->len;
					w.ctl[w.ctl_n] = '\0';
				}
				break;
			case CHAOS_OUT_CONNECT:
				if (w.ndata < 4) {
					w.data[w.ndata] = o->session;
					snprintf(w.contact[w.ndata],
						 sizeof w.contact[0], "%s", o->text);
					++w.ndata;
				}
				break;
			case CHAOS_OUT_CLOSE:
				w.ctl_closed = 1;
				break;
			case CHAOS_OUT_EOF:
				break;
			}
		} else if (w.nev < WIRE_EVENTS) {
			unsigned i = w.nev++;
			w.ev[i].op = o->op;
			w.ev[i].len = o->len;
			w.ev[i].kind = o->kind == CHAOS_OUT_DATA ? EV_DATA :
				       o->kind == CHAOS_OUT_EOF  ? EV_EOF : EV_CLOSE;
			if (o->len)
				memcpy(w.ev[i].b, o->bytes, o->len);
		}
		free(o);
	}
}

// One turn of the server: the control connection says what it has, then every
// data connection does.  Time moves by a millisecond, which nothing in this
// service reads but which a session that timed things would.
static void pump(void)
{
	struct chaos_outq q = { NULL, NULL };
	w.control->poll(w.control, w.now, &q);
	take(&q, 1);
	for (unsigned i = 0; i < w.ndata; ++i) {
		struct chaos_outq dq = { NULL, NULL };
		w.data[i]->poll(w.data[i], w.now, &dq);
		take(&dq, 0);
	}
	w.now += 1000000;
}

static void forget(void)
{
	w.ctl_n = 0;
	w.ctl[0] = '\0';
	w.nev = 0;
}

// A command up the control connection, with NO turn of the server after it:
// two commands can arrive back to back, and a check that always polls between
// them cannot see what the first one left queued.
static void send(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void send(const char *fmt, ...)
{
	char line[CHAOS_PKT_MAX_DATA + 1];
	va_list ap;
	va_start(ap, fmt);
	const int n = vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	w.control->data(w.control, w.now, CHAOS_DAT, (const uint8_t *)line,
			n > 0 ? (unsigned)n : 0);
}

// A command, then a turn.  What the service answers is in `w.ctl` and what it
// puts on a data connection is in `w.ev`.
static void cmd(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void cmd(const char *fmt, ...)
{
	char line[CHAOS_PKT_MAX_DATA + 1];
	va_list ap;
	va_start(ap, fmt);
	const int n = vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	forget();
	w.control->data(w.control, w.now, CHAOS_DAT, (const uint8_t *)line,
			n > 0 ? (unsigned)n : 0);
	pump();
}

// Bytes up a data connection, as a write's do.
static void up(unsigned which, uint8_t op, const void *bytes, unsigned len)
{
	w.data[which]->data(w.data[which], w.now, op, (const uint8_t *)bytes, len);
}

static int said(const char *s)
{
	return strstr(w.ctl, s) != NULL;
}

// Everything the data connections sent, run together, with the marks and the
// EOF left out: the file as the user end would have read it.
static unsigned wire_bytes(uint8_t *into, unsigned max)
{
	unsigned n = 0;
	for (unsigned i = 0; i < w.nev; ++i) {
		if (w.ev[i].kind != EV_DATA)
			continue;
		if (w.ev[i].op != CHAOS_FILE_CHARACTER_OP &&
		    w.ev[i].op != CHAOS_FILE_BINARY_OP)
			continue;
		if (n + w.ev[i].len > max)
			break;
		memcpy(into + n, w.ev[i].b, w.ev[i].len);
		n += w.ev[i].len;
	}
	return n;
}

static unsigned count_ev(enum ev_kind kind, uint8_t op)
{
	unsigned n = 0;
	for (unsigned i = 0; i < w.nev; ++i)
		if (w.ev[i].kind == kind && (kind != EV_DATA || w.ev[i].op == op))
			++n;
	return n;
}

// The service, and a control connection from the client it serves.
static void connect_control(void)
{
	const uint16_t served[] = { CLIENT };
	memset(&w, 0, sizeof w);
	w.now = 1000000;
	w.sv = chaos_file_new(root, CHAOS_TEST_UNIVERSAL, served, 1);
	CHECK(w.sv != NULL, "the FILE service was not made");
	if (!w.sv)
		exit(1);
	CHECK(!strcmp(w.sv->contact, CHAOS_FILE_CONTACT), "the contact is %s",
	      w.sv->contact);
	struct chaos_response r;
	w.sv->request(w.sv, w.now, "1", CLIENT, 0101, &r);
	CHECK(r.kind == CHAOS_RESP_ACCEPT, "the served client was not accepted");
	if (r.kind != CHAOS_RESP_ACCEPT)
		exit(1);
	w.control = r.session;
}

// A data connection: the service asks for one, the transport would have made
// it, and here it is made by hand.
static void connect_data(const char *tid, const char *in, const char *out)
{
	const unsigned before = w.ndata;
	cmd("%s  DATA-CONNECTION %s %s", tid, in, out);
	CHECK(w.ndata == before + 1, "DATA-CONNECTION asked for %u connections",
	      w.ndata - before);
	if (w.ndata != before + 1)
		return;
	// "The output file handle name is the contact name the user end is
	// listening for, so send it."
	CHECK(!strcmp(w.contact[before], out), "it called %s and not %s",
	      w.contact[before], out);
	// Nothing is answered until the connection is open, as `FILE.c`
	// answers it only once `chopen` has succeeded.
	CHECK(!said("DATA-CONNECTION"), "it was answered before it was open");
	w.data[before]->opened(w.data[before], w.now);
	forget();
	pump();
	CHECK(said("DATA-CONNECTION"), "no answer once it was open: [%s]", w.ctl);
}

static void teardown(void)
{
	for (unsigned i = 0; i < w.ndata; ++i)
		w.data[i]->destroy(w.data[i]);
	w.control->destroy(w.control);
	w.sv->destroy(w.sv);
	memset(&w, 0, sizeof w);
}

// ------------------------------------------------------- the pieces alone

static void check_translation(void)
{
	// The Lisp Machine's newline is 0215 and its carriage return is 0212,
	// which is `FILE.c`'s own note: "0212 maps to 015 since 0215 must map
	// to 012".
	uint8_t in[1], out[1];
	in[0] = '\n';
	chaos_file_to_lispm(in, 1, out);
	CHECK(out[0] == CHAOS_FILE_NEWLINE, "\\n went to %o and not 0215", out[0]);
	in[0] = CHAOS_FILE_NEWLINE;
	chaos_file_from_lispm(in, 1, out);
	CHECK(out[0] == '\n', "0215 came back as %o and not \\n", out[0]);
	in[0] = 015;
	chaos_file_to_lispm(in, 1, out);
	CHECK(out[0] == 0212, "015 went to %o and not 0212", out[0]);
	in[0] = 0212;
	chaos_file_from_lispm(in, 1, out);
	CHECK(out[0] == 015, "0212 came back as %o and not 015", out[0]);
	// The format effectors go up into the 0200s where the Lisp Machine
	// keeps them, and a Lisp Machine file's effectors as Unix stored them
	// come back down.
	in[0] = 0177;
	chaos_file_to_lispm(in, 1, out);
	CHECK(out[0] == 0377, "0177 went to %o and not 0377", out[0]);
	in[0] = 0210;
	chaos_file_to_lispm(in, 1, out);
	CHECK(out[0] == 010, "0210 went to %o and not 010", out[0]);

	// Both ways round, over every byte there is.  A translation that loses
	// one value loses a file, and which value it is cannot be guessed.
	unsigned bad = 0;
	for (unsigned c = 0; c < 256; ++c) {
		uint8_t a[1] = { (uint8_t)c }, b[1], d[1];
		chaos_file_to_lispm(a, 1, b);
		chaos_file_from_lispm(b, 1, d);
		if (d[0] != c)
			++bad;
	}
	CHECK(bad == 0, "%u of 256 bytes did not survive to_lispm then from_lispm",
	      bad);
	bad = 0;
	for (unsigned c = 0; c < 256; ++c) {
		uint8_t a[1] = { (uint8_t)c }, b[1], d[1];
		chaos_file_from_lispm(a, 1, b);
		chaos_file_to_lispm(b, 1, d);
		if (d[0] != c)
			++bad;
	}
	CHECK(bad == 0, "%u of 256 bytes did not survive from_lispm then to_lispm",
	      bad);
	// A run, so that a translation that works a byte at a time and not in
	// place is caught: the service translates a whole file into its own
	// buffer.
	uint8_t run[sizeof HELLO], back[sizeof HELLO];
	chaos_file_to_lispm((const uint8_t *)HELLO, sizeof HELLO - 1, run);
	CHECK(!memcmp(run, HELLO_WIRE, sizeof HELLO - 1),
	      "a whole line did not translate to the wire form");
	chaos_file_from_lispm(run, sizeof HELLO - 1, back);
	CHECK(!memcmp(back, HELLO, sizeof HELLO - 1), "and did not come back");
}

static void check_dates(void)
{
	char d[24];
	chaos_file_date(0, d, sizeof d);
	CHECK(!strcmp(d, "01/01/70 00:00:00"), "the Unix epoch read %s", d);
	chaos_file_date(1700000000u, d, sizeof d);
	CHECK(!strcmp(d, "11/14/23 22:13:20"), "1700000000 read %s", d);
	// The universal time the checks fix a clock at, back through the
	// Lisp Machine's own epoch: 1 September 2026.
	chaos_file_date(CHAOS_TEST_UNIVERSAL - CHAOS_UNIX_EPOCH_UNIVERSAL, d, sizeof d);
	CHECK(!strcmp(d, "09/01/26 00:00:00"), "the fixed universal time read %s", d);
	// A leap day, which is where a civil-date arithmetic goes wrong.
	chaos_file_date(1709208000u, d, sizeof d);
	CHECK(!strcmp(d, "02/29/24 12:00:00"), "the leap day read %s", d);
}

static void check_matches(void)
{
	CHECK(chaos_file_matches("*", "anything.text"), "* matched nothing");
	CHECK(chaos_file_matches("", "anything.text"), "the empty pattern matched nothing");
	CHECK(chaos_file_matches("*.text", "hello.text"), "*.text missed hello.text");
	CHECK(!chaos_file_matches("*.text", "hello.lisp"), "*.text took hello.lisp");
	CHECK(chaos_file_matches("hello.*", "hello.text"), "hello.* missed its file");
	// One wild character.  `chaos_file.h`'s contract names `#`, which is
	// the Lisp Machine's; muir's matcher takes `?`, so both are taken.
	CHECK(chaos_file_matches("hello.tex#", "hello.text"), "# did not match one");
	CHECK(chaos_file_matches("#ello.text", "hello.text"), "# did not match a first");
	CHECK(!chaos_file_matches("hello.te#", "hello.text"), "# matched two");
	CHECK(chaos_file_matches("hello.tex?", "hello.text"), "? did not match one");
	CHECK(!chaos_file_matches("hello", "hello.text"), "a plain name matched a longer one");
	CHECK(chaos_file_matches("hello.text", "hello.text"), "a plain name missed itself");
	CHECK(!chaos_file_matches("*.text", "text"), "*.text took a name with no dot");
	CHECK(chaos_file_matches("*a*b*", "xxaxxbxx"), "two stars missed");
	CHECK(!chaos_file_matches("*a*b*", "xxbxxaxx"), "two stars matched out of order");
	// The pattern that made the recursive matcher exponential.  It must
	// answer, and quickly; muir's note is that ten `*a` against a long run
	// of `a`s pinned the engine's thread for billions of tries.
	CHECK(!chaos_file_matches("*a*a*a*a*a*a*a*a*a*a*b",
				  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
	      "the pathological pattern matched");
}

static void check_who_is_served(void)
{
	const uint16_t served[] = { CLIENT };
	struct chaos_service *sv = chaos_file_new(root, CHAOS_TEST_UNIVERSAL, served, 1);
	CHECK(sv != NULL, "the service was not made");
	if (!sv)
		return;
	struct chaos_response r;
	// Reachability is not authorisation: a peer a packet arrived from can
	// be answered, and being answerable is not being allowed to read and
	// write a real directory.
	sv->request(sv, 1000, "1", STRANGER, 0101, &r);
	CHECK(r.kind == CHAOS_RESP_REFUSE, "a host that is not served was not refused");
	CHECK(strstr(r.reason, "4401") != NULL,
	      "the refusal does not name the address in octal: %s", r.reason);
	sv->request(sv, 1000, "1", CLIENT, 0101, &r);
	CHECK(r.kind == CHAOS_RESP_ACCEPT, "the served host was not accepted");
	if (r.kind == CHAOS_RESP_ACCEPT)
		r.session->destroy(r.session);
	sv->destroy(sv);

	// No list at all answers everyone, which is what a cable with one
	// trusted machine on it is.
	sv = chaos_file_new(root, CHAOS_TEST_UNIVERSAL, NULL, 0);
	CHECK(sv != NULL, "the open service was not made");
	if (!sv)
		return;
	sv->request(sv, 1000, "1", STRANGER, 0101, &r);
	CHECK(r.kind == CHAOS_RESP_ACCEPT, "an unlisted service refused a host");
	if (r.kind == CHAOS_RESP_ACCEPT)
		r.session->destroy(r.session);
	sv->destroy(sv);
}

// ------------------------------------------------------------- the commands

static void check_login(void)
{
	connect_control();
	// Two spaces: there is no file handle on a LOGIN.
	cmd("L1  LOGIN mete");
	// `FILE.c`: the name, the home directory with a slash, the full name;
	// the user end takes the home directory and the personal name off the
	// two lines.
	CHECK(said("L1  LOGIN mete /mete/" NLS "mete" NLS),
	      "LOGIN answered [%s]", w.ctl);
	// The home directory is the user's name in lower case and the name
	// itself is not: `FILE.c` gives the name, then the home directory with
	// a slash, then the full name.
	cmd("LU  LOGIN METE");
	CHECK(said("LU  LOGIN METE /mete/" NLS "METE" NLS),
	      "LOGIN of an upper-case user answered [%s]", w.ctl);
	cmd("L2  LOGIN");
	CHECK(said("L2  ERROR UNK C Unknown user"), "a LOGIN with no user answered [%s]",
	      w.ctl);
	// An unknown command is refused by name rather than ignored.
	// **A reply longer than one packet.**  The control connection is a
	// stream, and a reply quoting a command back --- an unknown command's
	// name, a LOGIN's user in its home directory --- may run past what a
	// packet carries.
	{
		char big[300];
		memset(big, 'u', sizeof big - 1);
		big[sizeof big - 1] = '\0';
		cmd("LL  LOGIN %s", big);
		char expect[2048];
		snprintf(expect, sizeof expect, "LL  LOGIN %s /%s/" NLS "%s" NLS,
			 big, big, big);
		CHECK(w.ctl_n > CHAOS_PKT_MAX_DATA,
		      "a long LOGIN's reply was %zu bytes and did not need two "
		      "packets", w.ctl_n);
		CHECK(said(expect), "a long LOGIN's reply did not join up again");
	}
	cmd("L3  SET-BYTE-SIZE 16");
	CHECK(said("L3  ERROR UKC C SET-BYTE-SIZE is not served here"),
	      "an unknown command answered [%s]", w.ctl);
	teardown();
}

static void check_read(void)
{
	connect_control();
	cmd("L1  LOGIN mete");
	connect_data("D1", "IN1", "OUT1");

	// A handle exists once: a second DATA-CONNECTION naming one of them is
	// refused rather than quietly taking the name off its connection.
	cmd("D8  DATA-CONNECTION IN1 OUT8");
	CHECK(said("D8  ERROR BUG C File handle already exists"),
	      "reusing an input handle answered [%s]", w.ctl);
	cmd("D9  DATA-CONNECTION IN9 OUT1");
	CHECK(said("D9  ERROR BUG C File handle already exists"),
	      "reusing an output handle answered [%s]", w.ctl);
	cmd("DA  DATA-CONNECTION IN7");
	CHECK(said("DA  ERROR BUG C DATA-CONNECTION wants two handles"),
	      "a DATA-CONNECTION with one handle answered [%s]", w.ctl);

	char path[768], when[24], want[256];
	snprintf(path, sizeof path, "%s/hello.text", root);
	stat_date(path, when, sizeof when);
	cmd("R1 IN1 OPEN READ" NLS "hello.text");
	// `FILE.c`: date, length, QFASL as T or NIL, then the truename.
	snprintf(want, sizeof want, "R1 IN1 OPEN %s %zu NIL" NLS "hello.text" NLS,
		 when, sizeof HELLO - 1);
	CHECK(said(want), "OPEN READ answered [%s], wanting [%s]", w.ctl, want);

	// The file goes down the data connection and the newline is the Lisp
	// Machine's.  This is the thing the band is waiting for.
	uint8_t got[4096];
	unsigned n = wire_bytes(got, sizeof got);
	CHECK(n == sizeof HELLO_WIRE - 1, "%u bytes came down the wire, wanting %zu",
	      n, sizeof HELLO_WIRE - 1);
	CHECK(n == sizeof HELLO_WIRE - 1 && !memcmp(got, HELLO_WIRE, n),
	      "the bytes down the wire are not the file's");
	CHECK(count_ev(EV_DATA, CHAOS_FILE_CHARACTER_OP) >= 1,
	      "nothing went down under the character opcode");
	CHECK(count_ev(EV_EOF, 0) == 1, "%u EOFs after the file, wanting one",
	      count_ev(EV_EOF, 0));
	CHECK(count_ev(EV_DATA, CHAOS_FILE_SYNC_MARK_OP) == 0,
	      "a synchronous mark came before the CLOSE");

	// CLOSE is answered on the control connection and THEN the mark goes
	// down the data connection --- "we must respond to the close before
	// sending the SYNCMARK since otherwise we would likely block" --- and
	// the mark is what the user end reads until.
	cmd("R2 IN1 CLOSE");
	snprintf(want, sizeof want, "R2 IN1 CLOSE %s %zu NIL" NLS "hello.text" NLS,
		 when, sizeof HELLO - 1);
	CHECK(said(want), "CLOSE answered [%s], wanting [%s]", w.ctl, want);
	CHECK(count_ev(EV_DATA, CHAOS_FILE_SYNC_MARK_OP) == 1,
	      "%u synchronous marks after the CLOSE, wanting one",
	      count_ev(EV_DATA, CHAOS_FILE_SYNC_MARK_OP));

	// A second CLOSE has nothing to close.
	cmd("R3 IN1 CLOSE");
	CHECK(said("R3 IN1 ERROR BUG C No transfer in progress"),
	      "a second CLOSE answered [%s]", w.ctl);

	// An empty file is an EOF and not one empty packet.
	cmd("R4 IN1 OPEN READ" NLS "empty.text");
	CHECK(said("R4 IN1 OPEN "), "OPEN of the empty file answered [%s]", w.ctl);
	CHECK(count_ev(EV_DATA, CHAOS_FILE_CHARACTER_OP) == 0,
	      "the empty file sent %u data packets",
	      count_ev(EV_DATA, CHAOS_FILE_CHARACTER_OP));
	CHECK(count_ev(EV_EOF, 0) == 1, "the empty file did not end in one EOF");
	cmd("R5 IN1 CLOSE");

	// **More than one packet.**  The file goes down in chunks of at most
	// what a packet carries, in order, and nothing is lost at a boundary.
	cmd("RG IN1 OPEN READ" NLS "big.text");
	snprintf(want, sizeof want, " %u NIL" NLS "big.text" NLS, BIG_LEN);
	CHECK(said(want), "OPEN of the big file answered [%s]", w.ctl);
	n = wire_bytes(got, sizeof got);
	CHECK(n == BIG_LEN, "%u bytes came down for a %u byte file", n, BIG_LEN);
	CHECK(count_ev(EV_DATA, CHAOS_FILE_CHARACTER_OP) == 4,
	      "a %u byte file came in %u packets, wanting four", BIG_LEN,
	      count_ev(EV_DATA, CHAOS_FILE_CHARACTER_OP));
	unsigned oversize = 0;
	for (unsigned i = 0; i < w.nev; ++i)
		if (w.ev[i].kind == EV_DATA && w.ev[i].len > CHAOS_PKT_MAX_DATA)
			++oversize;
	CHECK(oversize == 0, "%u packets are longer than a packet", oversize);
	{
		// Every byte, in order, with the newline translated: a check
		// that only counted them would pass a server that reordered
		// its chunks.
		unsigned bad = 0;
		for (unsigned i = 0; i < n && i < BIG_LEN; ++i) {
			const uint8_t want_byte = (i % 50 == 49) ?
				CHAOS_FILE_NEWLINE : (uint8_t)('a' + i % 26);
			if (got[i] != want_byte)
				++bad;
		}
		CHECK(bad == 0, "%u of %u bytes of the big file are wrong", bad, n);
	}
	cmd("RH IN1 CLOSE");

	// A file that is not there, which is the error form.
	cmd("R6 IN1 OPEN READ" NLS "nothing.text");
	CHECK(said("R6 IN1 ERROR FNF C File not found"),
	      "a missing file answered [%s]", w.ctl);
	// And a directory is not a file to read.
	cmd("R7 IN1 OPEN READ" NLS "notes");
	CHECK(said("R7 IN1 ERROR FNF C That is a directory"),
	      "OPEN READ of a directory answered [%s]", w.ctl);
	// PROBE answers without moving anything.
	cmd("R8 IN1 OPEN PROBE" NLS "hello.text");
	CHECK(said("R8 IN1 OPEN "), "PROBE answered [%s]", w.ctl);
	CHECK(count_ev(EV_DATA, CHAOS_FILE_CHARACTER_OP) == 0,
	      "PROBE sent the file down the wire");
	cmd("R9 IN1 OPEN PROBE-DIRECTORY" NLS "notes");
	CHECK(said("R9 IN1 OPEN ") && said(NLS "notes/" NLS),
	      "PROBE-DIRECTORY answered [%s]", w.ctl);

	// A compiled file: DEFAULT takes it as binary and measures it in
	// words, which is `FILE.c`'s own order --- the characters decision
	// first, and the length from it.
	cmd("RA IN1 OPEN READ DEFAULT" NLS "fasl.qfasl");
	CHECK(said(" 3 T NIL" NLS "fasl.qfasl" NLS),
	      "OPEN DEFAULT of a QFASL answered [%s]", w.ctl);
	CHECK(count_ev(EV_DATA, CHAOS_FILE_BINARY_OP) == 1,
	      "a QFASL did not go down under the binary opcode");
	n = wire_bytes(got, sizeof got);
	CHECK(n == 6 && !memcmp(got, CHAOS_FILE_QFASL_MAGIC "xy", 6),
	      "a QFASL was translated on its way down");

	// FILEPOS: the reply, then a mark to throw away what is in flight,
	// then the file again from where it was asked for.
	cmd("RB IN1 CLOSE");
	// **The OPEN and the FILEPOS with no turn of the server between them**,
	// which is the case the command exists for: the client sends it with
	// its mark flag set and reads until the mark, which is how it throws
	// away what is already in flight from the old position.  A check that
	// polled in between would have emptied the connection first, and then a
	// server that threw nothing away would pass.
	forget();
	send("RC IN1 OPEN READ" NLS "hello.text");
	send("RD IN1 FILEPOS 16");
	pump();
	CHECK(said("RC IN1 OPEN "), "the OPEN before a FILEPOS answered [%s]", w.ctl);
	CHECK(said("RD IN1 FILEPOS"), "FILEPOS answered [%s]", w.ctl);
	CHECK(w.nev >= 1 && w.ev[0].kind == EV_DATA &&
	      w.ev[0].op == CHAOS_FILE_SYNC_MARK_OP,
	      "FILEPOS did not begin with a synchronous mark");
	n = wire_bytes(got, sizeof got);
	CHECK(n == sizeof HELLO_WIRE - 1 - 16 &&
	      !memcmp(got, HELLO_WIRE + 16, n),
	      "FILEPOS 16 sent %u bytes and not the tail", n);
	cmd("RE IN1 FILEPOS 9999");
	CHECK(said("RE IN1 ERROR FOR C Filepos out of range"),
	      "a FILEPOS past the end answered [%s]", w.ctl);
	cmd("RF IN1 CLOSE");
	teardown();
}

// **THE CONTAINMENT.**  Its own function, because a file server that can be
// walked out of is worse than no file server, and because every one of these
// is a rule muir's `resolve` states in as many words.
static void check_containment(void)
{
	connect_control();
	cmd("L1  LOGIN mete");
	connect_data("D1", "IN1", "OUT1");

	// `..` and `.` are REFUSED rather than followed, wherever they appear.
	// `ATD`, "Access to directory denied", is the error `FILE.c` gives a
	// pathname the user may not reach.
	cmd("C1 IN1 OPEN READ" NLS "../elsewhere/secret.text");
	CHECK(said("C1 IN1 ERROR ATD C Access to directory denied"),
	      ".. answered [%s]", w.ctl);
	cmd("C2 IN1 OPEN READ" NLS "notes/../hello.text");
	CHECK(said("C2 IN1 ERROR ATD C"), "a .. in the middle answered [%s]", w.ctl);
	cmd("C3 IN1 OPEN READ" NLS "./hello.text");
	CHECK(said("C3 IN1 ERROR ATD C"), "a leading . answered [%s]", w.ctl);
	cmd("C4 IN1 OPEN READ" NLS "notes/./one.text");
	CHECK(said("C4 IN1 ERROR ATD C"), "a . in the middle answered [%s]", w.ctl);
	CHECK(count_ev(EV_DATA, CHAOS_FILE_CHARACTER_OP) == 0,
	      "something went down the wire for a refused pathname");
	uint8_t got[4096];

	// A link INSIDE the tree that leads out of it is refused.  The
	// pathname has no `..` in it and every component is a real one; what
	// refuses it is the deepest existing part being resolved on the host
	// and landing outside.
	cmd("C5 IN1 OPEN READ" NLS "notes/escape/secret.text");
	CHECK(said("C5 IN1 ERROR ATD C Access to directory denied"),
	      "a link out of the tree answered [%s]", w.ctl);
	unsigned n = wire_bytes(got, sizeof got);
	CHECK(n == 0, "%u bytes went down the wire through a link out of the tree", n);
	// And the directory it points at cannot be listed either.
	cmd("C6 IN1 DIRECTORY" NLS "notes/escape/*");
	CHECK(said("C6 IN1 ERROR ATD C"), "listing through the link answered [%s]",
	      w.ctl);

	// **And the tree is bounded by COMPONENTS, not by characters.**
	// `.../servedmore` begins with `.../served` as text and is a different
	// directory; a containment test written as a string prefix lets a link
	// into it through, and every other check in this file would still pass.
	cmd("CI IN1 OPEN READ" NLS "notes/sneak/hidden.text");
	CHECK(said("CI IN1 ERROR ATD C Access to directory denied"),
	      "a link into a directory whose name merely begins with the root's "
	      "answered [%s]", w.ctl);
	CHECK(wire_bytes(got, sizeof got) == 0,
	      "bytes came out of a directory beside the root");

	// A link AT THE ROOT is followed, because that is how each release's
	// sources are put under the root: `sys` for System 304, `tree` for
	// System 100, under the name that release's band asks for.  Refusing
	// this would serve an empty tree to a real band.
	cmd("C7 IN1 OPEN READ" NLS "sys/banner.text");
	CHECK(said("C7 IN1 OPEN "), "the root's own link answered [%s]", w.ctl);
	n = wire_bytes(got, sizeof got);
	CHECK(n == sizeof BANNER - 1, "%u bytes came through the root's link", n);
	cmd("C8 IN1 CLOSE");

	// **An absolute pathname is taken UNDER THE ROOT and is not a way
	// out.**  The root is the service's `/`, so a leading slash names the
	// root and not the host's: muir's `resolve` splits on `/` and drops
	// the empty first part, and the host's own `/etc/passwd` --- which
	// exists on this build host --- is therefore unreachable rather than
	// denied.  So the answer is "File not found", and the check that
	// matters is the pair: the host's file is NOT served, and a rooted
	// pathname reaches the served file of the same shape.
	cmd("C9 IN1 OPEN READ" NLS "/etc/passwd");
	CHECK(!said("C9 IN1 OPEN "), "an absolute pathname opened something");
	CHECK(said("C9 IN1 ERROR FNF C File not found"),
	      "an absolute pathname answered [%s]", w.ctl);
	n = wire_bytes(got, sizeof got);
	CHECK(n == 0, "%u bytes went down the wire for the host's own /etc/passwd", n);
	cmd("CA IN1 OPEN READ" NLS "/notes/one.text");
	CHECK(said("CA IN1 OPEN ") && said(NLS "/notes/one.text" NLS),
	      "a rooted pathname answered [%s]", w.ctl);
	n = wire_bytes(got, sizeof got);
	CHECK(n == 4, "the rooted pathname sent %u bytes and not the served file's 4", n);
	cmd("CB IN1 CLOSE");

	// Nothing may be WRITTEN outside the tree either, and the root itself
	// is not a thing to write, rename, delete or create.
	cmd("CC OUT1 OPEN WRITE" NLS "../elsewhere/planted.text");
	CHECK(said("CC OUT1 ERROR ATD C"), "a write outside answered [%s]", w.ctl);
	cmd("CD OUT1 OPEN WRITE" NLS "notes/escape/planted.text");
	CHECK(said("CD OUT1 ERROR ATD C"), "a write through the link answered [%s]",
	      w.ctl);
	cmd("CE  DELETE" NLS "../elsewhere/secret.text");
	CHECK(said("CE  ERROR ATD C"), "a delete outside answered [%s]", w.ctl);
	cmd("CF  DELETE" NLS "");
	CHECK(said("CF  ERROR ATD C"), "deleting the root itself answered [%s]", w.ctl);
	cmd("CG  RENAME" NLS "hello.text" NLS "../elsewhere/taken.text");
	CHECK(said("CG  ERROR ATD C"), "a rename outside answered [%s]", w.ctl);
	cmd("CH  CREATE-LINK" NLS "widen" NLS "../elsewhere");
	CHECK(said("CH  ERROR ATD C"), "a link pointing outside answered [%s]", w.ctl);
	// Everything the tree held is still there.
	char buf[256];
	char p[768];
	snprintf(p, sizeof p, "%s/secret.text", elsewhere);
	CHECK(slurp(p, buf, sizeof buf) == (long)sizeof SECRET - 1,
	      "the file outside the tree was disturbed");
	snprintf(p, sizeof p, "%s/planted.text", elsewhere);
	CHECK(slurp(p, buf, sizeof buf) < 0, "a file was planted outside the tree");
	snprintf(p, sizeof p, "%s/widen", root);
	struct stat st;
	CHECK(lstat(p, &st) != 0, "a link out of the tree was made");
	teardown();
}

static void check_write(void)
{
	connect_control();
	cmd("L1  LOGIN mete");
	connect_data("D1", "IN1", "OUT1");

	char p[768], buf[256];
	snprintf(p, sizeof p, "%s/written.text", root);
	cmd("W1 OUT1 OPEN WRITE" NLS "written.text");
	CHECK(said("W1 OUT1 OPEN ") && said(" 0 NIL" NLS "written.text" NLS),
	      "OPEN WRITE answered [%s]", w.ctl);
	// **It goes through a temporary and is renamed into place**, `FILE.c`'s
	// `tempfile(dirname)` linked over the real name on close.  Nothing is
	// at the real name yet, and the temporary is there to be counted.
	CHECK(slurp(p, buf, sizeof buf) < 0, "the file appeared before its CLOSE");
	CHECK(count_prefixed(root, "#muir-") == 1,
	      "%u temporaries in the directory, wanting one",
	      count_prefixed(root, "#muir-"));

	// The data up the connection, in two packets, with the Lisp Machine's
	// newline; what lands on disk must be the host's.
	up(0, CHAOS_FILE_CHARACTER_OP, "one" NLS, 4);
	up(0, CHAOS_FILE_CHARACTER_OP, "two" NLS, 4);
	forget();
	pump();
	CHECK(slurp(p, buf, sizeof buf) < 0, "the file appeared before its mark");
	// The synchronous mark says the data is all there, and then the CLOSE.
	up(0, CHAOS_FILE_SYNC_MARK_OP, NULL, 0);
	cmd("W2 OUT1 CLOSE");
	CHECK(said("W2 OUT1 CLOSE ") && said(NLS "written.text" NLS),
	      "CLOSE of a write answered [%s]", w.ctl);
	long n = slurp(p, buf, sizeof buf);
	CHECK(n == 8, "the written file is %ld bytes, wanting 8", n);
	CHECK(n == 8 && !memcmp(buf, "one\ntwo\n", 8),
	      "the written file is not what was sent");
	CHECK(count_prefixed(root, "#muir-") == 0,
	      "a temporary was left behind after the CLOSE");
	// The reply carries the file's length, which is the length on disk and
	// not the count of bytes that arrived.
	CHECK(said(" 8" NLS), "the CLOSE does not give the file's length: [%s]", w.ctl);

	// **The CLOSE may overtake the mark**, which `sys/doc/chfile.text`'s
	// worked example allows in as many words: "a SYNC mark on the DATA
	// connection and a CLOSE on the CONTROL connection (in either order)".
	// A CLOSE that arrives first waits, and is answered from the poll once
	// the mark has come; renaming without the mark would put a file into
	// place short of whatever had not arrived.
	snprintf(p, sizeof p, "%s/second.text", root);
	cmd("W3 OUT1 OPEN WRITE" NLS "second.text");
	up(0, CHAOS_FILE_CHARACTER_OP, "held" NLS, 5);
	cmd("W4 OUT1 CLOSE");
	CHECK(!said("W4 OUT1 CLOSE"), "the CLOSE was answered before the mark");
	CHECK(slurp(p, buf, sizeof buf) < 0, "the file was renamed before the mark");
	up(0, CHAOS_FILE_SYNC_MARK_OP, NULL, 0);
	forget();
	pump();
	CHECK(said("W4 OUT1 CLOSE "), "the held CLOSE was not answered by the mark: [%s]",
	      w.ctl);
	n = slurp(p, buf, sizeof buf);
	CHECK(n == 5 && !memcmp(buf, "held\n", 5),
	      "the file held until its mark is %ld bytes and not what was sent", n);

	// IF-EXISTS ERROR refuses; the default supersedes; APPEND starts from
	// what is there.
	cmd("W5 OUT1 OPEN WRITE IF-EXISTS ERROR" NLS "second.text");
	CHECK(said("W5 OUT1 ERROR FAE C File already exists"),
	      "IF-EXISTS ERROR answered [%s]", w.ctl);
	cmd("W6 OUT1 OPEN WRITE IF-EXISTS APPEND" NLS "second.text");
	CHECK(said(" 5 NIL" NLS), "an APPEND did not start from the 5 bytes there: [%s]",
	      w.ctl);
	up(0, CHAOS_FILE_CHARACTER_OP, "more" NLS, 5);
	up(0, CHAOS_FILE_SYNC_MARK_OP, NULL, 0);
	cmd("W7 OUT1 CLOSE");
	n = slurp(p, buf, sizeof buf);
	CHECK(n == 10 && !memcmp(buf, "held\nmore\n", 10),
	      "an APPEND left %ld bytes and not the ten it should", n);
	cmd("W8 OUT1 OPEN WRITE IF-DOES-NOT-EXIST ERROR" NLS "nothing.text");
	CHECK(said("W8 OUT1 ERROR FNF C File not found"),
	      "IF-DOES-NOT-EXIST ERROR answered [%s]", w.ctl);
	cmd("W9 OUT1 OPEN WRITE IF-EXISTS NONSENSE" NLS "second.text");
	CHECK(said("W9 OUT1 ERROR UOO C NONSENSE is not a way to write"),
	      "an unknown IF-EXISTS answered [%s]", w.ctl);

	// A DELETE on a handle in the middle of a write abandons the temporary
	// and leaves the real file alone, which is what the client's
	// `:REAL-CLOSE` does when it aborts.
	cmd("WA OUT1 OPEN WRITE" NLS "second.text");
	up(0, CHAOS_FILE_CHARACTER_OP, "gone" NLS, 5);
	forget();
	pump();
	CHECK(count_prefixed(root, "#muir-") == 1, "no temporary to abandon");
	cmd("WB OUT1 DELETE");
	CHECK(said("WB OUT1 DELETE"), "an abandoning DELETE answered [%s]", w.ctl);
	CHECK(count_prefixed(root, "#muir-") == 0, "the temporary was left behind");
	n = slurp(p, buf, sizeof buf);
	CHECK(n == 10, "the real file was disturbed by an abandoned write");

	// CONTINUE without a stopped transfer is the server's own BUG, which
	// is what `FILE.c` answers.
	cmd("WC OUT1 CONTINUE");
	CHECK(said("WC OUT1 ERROR BUG C No transfer to continue"),
	      "CONTINUE with no transfer answered [%s]", w.ctl);
	cmd("WD OUT1 OPEN WRITE" NLS "third.text");
	cmd("WE OUT1 CONTINUE");
	CHECK(said("WE OUT1 ERROR BUG C CONTINUE received when not in error state"),
	      "CONTINUE on a healthy transfer answered [%s]", w.ctl);
	cmd("WF OUT1 DELETE");
	teardown();
}

static void check_directory(void)
{
	connect_control();
	cmd("L1  LOGIN mete");
	connect_data("D1", "IN1", "OUT1");

	// The listing goes down the input handle as records of text: a first
	// record with the file system's properties, then one a file, each a
	// pathname line, property lines `NAME value`, and a blank line.
	cmd("G1 IN1 DIRECTORY" NLS "notes/*");
	CHECK(said("G1 IN1 DIRECTORY"), "DIRECTORY answered [%s]", w.ctl);
	uint8_t got[16384];
	unsigned n = wire_bytes(got, sizeof got - 1);
	got[n] = '\0';
	const char *text = (const char *)got;
	CHECK(strstr(text, "BLOCK-SIZE 1024" NLS) != NULL,
	      "the listing has no file-system record");
	CHECK(strstr(text, "SETTABLE-PROPERTIES CREATION-DATE AUTHOR" NLS) != NULL,
	      "the listing does not say what may be set");
	CHECK(strstr(text, NLS "notes/one.text" NLS) != NULL,
	      "the listing is missing notes/one.text");
	// Each record ends in a blank line, which is what tells the reader
	// where one file's properties stop and the next file begins.
	CHECK(strstr(text, NLS NLS "notes/one.text" NLS) != NULL,
	      "there is no blank line before a record");
	CHECK(strstr(text, NLS "notes/two.lisp" NLS) != NULL,
	      "the listing is missing notes/two.lisp");
	CHECK(strstr(text, "AUTHOR mete" NLS) != NULL,
	      "the listing does not carry the logged-in user as the author");
	CHECK(strstr(text, "LENGTH-IN-BYTES 4" NLS) != NULL,
	      "the listing does not carry a length in bytes");
	CHECK(strstr(text, "LENGTH-IN-BLOCKS 1" NLS) != NULL,
	      "the listing does not carry a length in blocks");
	CHECK(strstr(text, "BYTE-SIZE 8" NLS) != NULL,
	      "the listing does not carry a byte size");
	CHECK(count_ev(EV_EOF, 0) == 1, "the listing did not end in one EOF");
	// The names come out sorted, so that two runs list a directory the
	// same way round.
	const char *one = strstr(text, "notes/one.text");
	const char *two = strstr(text, "notes/two.lisp");
	CHECK(one && two && one < two, "the listing is not in order");
	cmd("G2 IN1 CLOSE");
	CHECK(said("G2 IN1 CLOSE"), "CLOSE of a listing answered [%s]", w.ctl);
	CHECK(count_ev(EV_DATA, CHAOS_FILE_SYNC_MARK_OP) == 1,
	      "a listing's CLOSE did not send one synchronous mark");

	// The wildcards, against the directory itself.
	cmd("G3 IN1 DIRECTORY" NLS "notes/*.lisp");
	n = wire_bytes(got, sizeof got - 1);
	got[n] = '\0';
	CHECK(strstr(text, "notes/two.lisp") != NULL, "*.lisp missed two.lisp");
	CHECK(strstr(text, "notes/one.text") == NULL, "*.lisp took one.text");
	cmd("G4 IN1 CLOSE");
	cmd("G5 IN1 DIRECTORY" NLS "notes/one.tex#");
	n = wire_bytes(got, sizeof got - 1);
	got[n] = '\0';
	CHECK(strstr(text, "notes/one.text") != NULL, "the # wildcard missed one.text");
	CHECK(strstr(text, "notes/two.lisp") == NULL, "the # wildcard took two.lisp");
	cmd("G6 IN1 CLOSE");
	// A directory that is not there.
	cmd("G7 IN1 DIRECTORY" NLS "nowhere/*");
	CHECK(said("G7 IN1 ERROR DNF C Directory not found"),
	      "a missing directory answered [%s]", w.ctl);

	// PROPERTIES is one record of the same shape.
	cmd("G8 IN1 PROPERTIES" NLS "hello.text");
	CHECK(said("G8 IN1 PROPERTIES"), "PROPERTIES answered [%s]", w.ctl);
	n = wire_bytes(got, sizeof got - 1);
	got[n] = '\0';
	CHECK(strstr(text, "hello.text" NLS "AUTHOR mete" NLS) != NULL,
	      "PROPERTIES sent [%s]", text);
	cmd("G9 IN1 CLOSE");
	teardown();
}

static void check_housekeeping(void)
{
	connect_control();
	cmd("L1  LOGIN mete");

	char p[768], q[768], buf[64];
	snprintf(p, sizeof p, "%s/spare.text", root);
	put(p, "spare" "\n", 6);
	cmd("H1  RENAME" NLS "spare.text" NLS "moved.text");
	CHECK(said("H1  RENAME"), "RENAME answered [%s]", w.ctl);
	snprintf(q, sizeof q, "%s/moved.text", root);
	CHECK(slurp(p, buf, sizeof buf) < 0, "the old name is still there");
	CHECK(slurp(q, buf, sizeof buf) == 6, "the new name has the wrong file");
	cmd("H2  RENAME" NLS "spare.text" NLS "again.text");
	CHECK(said("H2  ERROR FNF C File not found"),
	      "renaming what is not there answered [%s]", w.ctl);
	cmd("H3  RENAME" NLS "moved.text" NLS "hello.text");
	CHECK(said("H3  ERROR REF C Rename to existing file"),
	      "renaming onto a file answered [%s]", w.ctl);
	cmd("H4  DELETE" NLS "moved.text");
	CHECK(said("H4  DELETE"), "DELETE answered [%s]", w.ctl);
	CHECK(slurp(q, buf, sizeof buf) < 0, "DELETE left the file there");
	cmd("H5  DELETE" NLS "moved.text");
	CHECK(said("H5  ERROR FNF C File not found"),
	      "deleting what is not there answered [%s]", w.ctl);

	cmd("H6  CREATE-DIRECTORY" NLS "made");
	CHECK(said("H6  CREATE-DIRECTORY"), "CREATE-DIRECTORY answered [%s]", w.ctl);
	struct stat st;
	snprintf(q, sizeof q, "%s/made", root);
	CHECK(stat(q, &st) == 0 && S_ISDIR(st.st_mode), "no directory was made");
	cmd("H7  CREATE-DIRECTORY" NLS "made");
	CHECK(said("H7  ERROR DAE C Directory already exists"),
	      "making it twice answered [%s]", w.ctl);
	cmd("H8  DELETE" NLS "notes");
	CHECK(said("H8  ERROR DNE C Directory not empty"),
	      "deleting a full directory answered [%s]", w.ctl);
	cmd("H9  DELETE" NLS "made");
	CHECK(said("H9  DELETE"), "deleting an empty directory answered [%s]", w.ctl);

	// A link the band makes can only point inside the tree, so this one
	// must both be made and be followed.
	cmd("HA  CREATE-LINK" NLS "shortcut" NLS "notes/one.text");
	CHECK(said("HA  CREATE-LINK"), "CREATE-LINK answered [%s]", w.ctl);
	snprintf(q, sizeof q, "%s/shortcut", root);
	CHECK(lstat(q, &st) == 0 && S_ISLNK(st.st_mode), "no link was made");
	cmd("HB  CREATE-LINK" NLS "shortcut" NLS "notes/two.lisp");
	CHECK(said("HB  ERROR FAE C File already exists"),
	      "a second link of one name answered [%s]", w.ctl);
	cmd("HC  DELETE" NLS "shortcut");
	CHECK(said("HC  DELETE"), "deleting a link answered [%s]", w.ctl);

	// EXPUNGE answers with the blocks it recovered, and on Unix, where a
	// delete is a delete, that is always none.
	cmd("HD  EXPUNGE" NLS "");
	CHECK(said("HD  EXPUNGE 0"), "EXPUNGE answered [%s]", w.ctl);

	// CHANGE-PROPERTIES takes what `FILE.c` can set and refuses the rest
	// by name.
	cmd("HE  CHANGE-PROPERTIES" NLS "hello.text" NLS "AUTHOR mete");
	CHECK(said("HE  CHANGE-PROPERTIES"), "CHANGE-PROPERTIES answered [%s]", w.ctl);
	cmd("HF  CHANGE-PROPERTIES" NLS "hello.text" NLS "DONT-DELETE T");
	CHECK(said("HF  ERROR UKP C DONT-DELETE cannot be set here"),
	      "an unsettable property answered [%s]", w.ctl);
	cmd("HG  CHANGE-PROPERTIES" NLS "nothing.text" NLS "AUTHOR mete");
	CHECK(said("HG  ERROR FNF C File not found"),
	      "CHANGE-PROPERTIES of what is not there answered [%s]", w.ctl);

	// COMPLETE: a status word and the completion, a line each.  The client
	// reads the word as a keyword and takes NIL for no completion.
	cmd("HH  COMPLETE" NLS "/notes/one.text" NLS "/notes/two");
	CHECK(said("HH  COMPLETE OLD" NLS "/notes/two.lisp" NLS),
	      "a unique completion answered [%s]", w.ctl);
	cmd("HI  COMPLETE" NLS "/notes/one.text" NLS "/notes/");
	CHECK(said("HI  COMPLETE NIL" NLS "/notes/"),
	      "an ambiguous completion answered [%s]", w.ctl);
	cmd("HJ  COMPLETE NEW-OK" NLS "/notes/one.text" NLS "/notes/zzz");
	CHECK(said("HJ  COMPLETE NEW" NLS "/notes/zzz" NLS),
	      "NEW-OK on a name that is not there answered [%s]", w.ctl);
	cmd("HK  COMPLETE" NLS "/notes/one.text" NLS "/notes/zzz");
	CHECK(said("HK  COMPLETE NIL" NLS "/notes/zzz" NLS),
	      "a completion of nothing answered [%s]", w.ctl);
	teardown();
}

// **THE HANDLES ARE WALKED IN ORDER, AND THE ORDER IS THE POINT.**  muir keeps
// them in a `BTreeMap` and says why: the poll walks them, and with a hashed map
// that walk is in a different order in every process, "so anything that depends
// on which handle comes first happens in some runs and not others.  One such
// bug took an afternoon to catch.  Ordering it does more than take the
// variation away: it makes the order that used to lose data the only order
// there is, so a test can hold it and fails every time rather than half of
// them."  This is that test.  Two writes are made to wait for their marks, the
// LATER handle in the alphabet first; when both marks come, the poll answers
// them in handle order and not in the order the CLOSEs arrived.
static void check_handle_order(void)
{
	connect_control();
	cmd("L1  LOGIN mete");
	connect_data("DZ", "ZIN", "ZOUT");
	connect_data("DA", "AIN", "AOUT");

	cmd("O1 ZOUT OPEN WRITE" NLS "zed.text");
	CHECK(said("O1 ZOUT OPEN "), "the first write answered [%s]", w.ctl);
	cmd("O2 AOUT OPEN WRITE" NLS "ay.text");
	CHECK(said("O2 AOUT OPEN "), "the second write answered [%s]", w.ctl);
	up(0, CHAOS_FILE_CHARACTER_OP, "zed" NLS, 4);
	up(1, CHAOS_FILE_CHARACTER_OP, "ay" NLS, 3);
	// Both CLOSEs before either mark, Z first.
	cmd("O3 ZOUT CLOSE");
	cmd("O4 AOUT CLOSE");
	CHECK(!said("CLOSE "), "a CLOSE was answered before its mark");
	up(0, CHAOS_FILE_SYNC_MARK_OP, NULL, 0);
	up(1, CHAOS_FILE_SYNC_MARK_OP, NULL, 0);
	forget();
	pump();
	const char *z = strstr(w.ctl, "O3 ZOUT CLOSE");
	const char *a = strstr(w.ctl, "O4 AOUT CLOSE");
	CHECK(z != NULL && a != NULL, "one of the held CLOSEs was not answered: [%s]",
	      w.ctl);
	CHECK(z && a && a < z,
	      "the held CLOSEs came back in the order they arrived, not in handle order");
	// And both files are whole, which is the bug the ordering was for.
	char p[768], buf[64];
	snprintf(p, sizeof p, "%s/zed.text", root);
	CHECK(slurp(p, buf, sizeof buf) == 4, "the first write did not land whole");
	snprintf(p, sizeof p, "%s/ay.text", root);
	CHECK(slurp(p, buf, sizeof buf) == 3, "the second write did not land whole");

	// **A read and a write on one data connection keep their own bytes.**
	// Both handles of a connection share one channel, and what comes up it
	// belongs to the write and to nothing else --- which is what the band
	// does through every compile, holding the source open around the QFASL
	// it writes.
	cmd("O5 AIN OPEN READ" NLS "hello.text");
	CHECK(said("O5 AIN OPEN "), "the read alongside a write answered [%s]", w.ctl);
	cmd("O6 AOUT OPEN WRITE" NLS "both.text");
	up(1, CHAOS_FILE_CHARACTER_OP, "kept" NLS, 5);
	// A turn of the server with the bytes standing on the connection and
	// BOTH handles holding a transfer.  This is where the poll walks the
	// handles, and it is the only place the read's drain can steal the
	// write's bytes: a CLOSE drains the writing handle itself, so a check
	// that went straight to the CLOSE would never see it.
	forget();
	pump();
	up(1, CHAOS_FILE_SYNC_MARK_OP, NULL, 0);
	cmd("O7 AOUT CLOSE");
	CHECK(said("O7 AOUT CLOSE "), "the write beside a read answered [%s]", w.ctl);
	snprintf(p, sizeof p, "%s/both.text", root);
	CHECK(slurp(p, buf, sizeof buf) == 5,
	      "the write beside a read lost its bytes to the read's drain");
	cmd("O8 AIN CLOSE");

	// UNDATA-CONNECTION takes both handles of the connection and the
	// transfers on both: "UNDATA-CONNECTION implies a CLOSE on each file
	// handle of the DATA connection for which there is a file transfer in
	// progress".  The client names the INPUT handle and a write is on the
	// output one, so a server that took only the named handle would leave
	// the write's temporary in the directory.
	cmd("O9 AOUT OPEN WRITE" NLS "undone.text");
	up(1, CHAOS_FILE_CHARACTER_OP, "lost" NLS, 5);
	forget();
	pump();
	CHECK(count_prefixed(root, "#muir-") == 1, "no temporary to leave behind");
	cmd("OA AIN UNDATA-CONNECTION");
	CHECK(said("OA AIN UNDATA-CONNECTION"), "UNDATA-CONNECTION answered [%s]",
	      w.ctl);
	CHECK(count_prefixed(root, "#muir-") == 0,
	      "UNDATA-CONNECTION on the input handle left the output handle's temporary");
	snprintf(p, sizeof p, "%s/undone.text", root);
	CHECK(slurp(p, buf, sizeof buf) < 0, "an undone write landed anyway");
	// The handles are gone, so an OPEN on either has none.
	cmd("OB AOUT OPEN WRITE" NLS "after.text");
	CHECK(said("OB AOUT ERROR BUG C No such file handle"),
	      "a handle survived its UNDATA-CONNECTION: [%s]", w.ctl);
	teardown();
}

// A control connection that goes away in the middle of a write leaves a
// temporary that will never be renamed into place; it is removed.
static void check_dropped_connection(void)
{
	connect_control();
	cmd("L1  LOGIN mete");
	connect_data("D1", "IN1", "OUT1");
	cmd("X1 OUT1 OPEN WRITE" NLS "dropped.text");
	up(0, CHAOS_FILE_CHARACTER_OP, "half" NLS, 5);
	forget();
	pump();
	CHECK(count_prefixed(root, "#muir-") == 1, "no temporary was made");
	w.control->closed(w.control, w.now, "the machine rebooted under it");
	CHECK(count_prefixed(root, "#muir-") == 0,
	      "a dropped control connection left its temporary behind");
	char p[768], buf[64];
	snprintf(p, sizeof p, "%s/dropped.text", root);
	CHECK(slurp(p, buf, sizeof buf) < 0, "a dropped write landed anyway");
	// And the data connections are told to go with it.
	struct chaos_outq q = { NULL, NULL };
	w.control->poll(w.control, w.now, &q);
	int closes = 0;
	struct chaos_out *o;
	while ((o = chaos_outq_pop(&q))) {
		free(o);
	}
	struct chaos_outq dq = { NULL, NULL };
	w.data[0]->poll(w.data[0], w.now, &dq);
	while ((o = chaos_outq_pop(&dq))) {
		if (o->kind == CHAOS_OUT_CLOSE)
			++closes;
		free(o);
	}
	CHECK(closes > 0, "the data connection was not closed with the control one");
	teardown();
}

// The one file in the served root whose name is a temporary's, which is how a
// write in progress is found from outside.
static int find_temp(char *into, size_t n)
{
	DIR *d = opendir(root);
	if (!d)
		return -1;
	int found = -1;
	struct dirent *de;
	while ((de = readdir(d)))
		if (!strncmp(de->d_name, "#muir-", 6)) {
			snprintf(into, n, "%s/%s", root, de->d_name);
			found = 0;
		}
	closedir(d);
	return found;
}

// The bytes of the first event of this kind and opcode, as a string.
static const char *ev_text(enum ev_kind kind, uint8_t op, char *into, size_t n)
{
	into[0] = '\0';
	for (unsigned i = 0; i < w.nev; ++i)
		if (w.ev[i].kind == kind && w.ev[i].op == op) {
			unsigned len = w.ev[i].len;
			if (len > n - 1)
				len = (unsigned)n - 1;
			memcpy(into, w.ev[i].b, len);
			into[len] = '\0';
			break;
		}
	return into;
}

// **A WRITE THAT CANNOT BE WRITTEN STOPS RECOVERABLY AND IS CONTINUED.**  The
// server stops the transfer with an asynchronous mark down the data
// connection, which `FILE.c`'s `fherror` writes as `TIDNO <handle> ERROR
// <code> R <message>`, the literal `TIDNO` standing where a transaction id
// would be; the client's `QFILE-PROCESS-ASYNC-MARK` strips that first word,
// shows the error as proceedable, and sends CONTINUE if the user proceeds.
// The temporary is made unwritable to provoke it, which is why this is the
// one check here that root cannot run.
static void check_stalled_write(void)
{
	if (geteuid() == 0) {
		chaos_test_note("   (the stalled write is skipped: root may write "
				"a file it has taken the permission off)");
		return;
	}
	connect_control();
	cmd("L1  LOGIN mete");
	connect_data("D1", "IN1", "OUT1");
	cmd("S1 OUT1 OPEN WRITE" NLS "stalled.text");
	char temp[768], mark[256], p[768], buf[64];
	CHECK(find_temp(temp, sizeof temp) == 0, "no temporary to take away");
	CHECK(chmod(temp, 0444) == 0, "could not make the temporary unwritable");
	up(0, CHAOS_FILE_CHARACTER_OP, "kept" NLS, 5);
	forget();
	pump();
	CHECK(count_ev(EV_DATA, CHAOS_FILE_ASYNC_MARK_OP) == 1,
	      "%u asynchronous marks for a write that could not be written",
	      count_ev(EV_DATA, CHAOS_FILE_ASYNC_MARK_OP));
	ev_text(EV_DATA, CHAOS_FILE_ASYNC_MARK_OP, mark, sizeof mark);
	CHECK(!strncmp(mark, "TIDNO OUT1 ERROR NMR R ", 23),
	      "the asynchronous mark reads [%s]", mark);

	// CONTINUE retries what the stall is holding.  Still unwritable, so it
	// fails again and raises another mark; `FILE.c` answers the command
	// and lets the transfer retry after, so the reply says only that the
	// command was understood.
	cmd("S2 OUT1 CONTINUE");
	CHECK(said("S2 OUT1 CONTINUE"), "CONTINUE answered [%s]", w.ctl);
	CHECK(count_ev(EV_DATA, CHAOS_FILE_ASYNC_MARK_OP) == 1,
	      "a retry that failed again raised %u marks",
	      count_ev(EV_DATA, CHAOS_FILE_ASYNC_MARK_OP));

	// Writable again: the held bytes go in, and nothing was lost by the
	// stall.
	CHECK(chmod(temp, 0644) == 0, "could not make the temporary writable");
	cmd("S3 OUT1 CONTINUE");
	CHECK(count_ev(EV_DATA, CHAOS_FILE_ASYNC_MARK_OP) == 0,
	      "a retry that worked raised a mark anyway");
	up(0, CHAOS_FILE_SYNC_MARK_OP, NULL, 0);
	cmd("S4 OUT1 CLOSE");
	CHECK(said("S4 OUT1 CLOSE "), "the continued write's CLOSE answered [%s]",
	      w.ctl);
	snprintf(p, sizeof p, "%s/stalled.text", root);
	CHECK(slurp(p, buf, sizeof buf) == 5 && !memcmp(buf, "kept\n", 5),
	      "the continued write did not land the bytes it was holding");

	// **A CLOSE while the stall still holds bytes does not put the file
	// into place**: it would be short of whatever the stall is holding, so
	// the error that stopped it is repeated, fatal this time.
	cmd("S5 OUT1 OPEN WRITE" NLS "never.text");
	CHECK(find_temp(temp, sizeof temp) == 0, "no second temporary");
	CHECK(chmod(temp, 0444) == 0, "could not make the second temporary unwritable");
	up(0, CHAOS_FILE_CHARACTER_OP, "gone" NLS, 5);
	forget();
	pump();
	up(0, CHAOS_FILE_SYNC_MARK_OP, NULL, 0);
	cmd("S6 OUT1 CLOSE");
	CHECK(said("S6 OUT1 ERROR NMR F "),
	      "the CLOSE of a stalled write answered [%s]", w.ctl);
	snprintf(p, sizeof p, "%s/never.text", root);
	CHECK(slurp(p, buf, sizeof buf) < 0, "a short write landed anyway");
	CHECK(count_prefixed(root, "#muir-") == 0,
	      "the stalled write's temporary was left behind");
	teardown();
}

void chaos_test_file(void)
{
	build_tree();
	chaos_test_note("   the served tree is at %s", root);
	check_translation();
	check_dates();
	check_matches();
	check_who_is_served();
	check_login();
	check_read();
	check_containment();
	check_write();
	check_directory();
	check_housekeeping();
	check_stalled_write();
	check_handle_order();
	check_dropped_connection();
}
