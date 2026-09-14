// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The check for cadr-usb-input: a USB keyboard and mouse, and what the machine
// is given.
//
// **IT RUNS THE WHOLE ROAD IN ONE PROCESS, ON A BUILD HOST, WITH NO BOARD AND
// NO KEYBOARD.**  Synthetic `input_event`s are written into a socket pair that
// stands where a device node would be; `usb_devices.c` reads them; `usb_keys.c`
// chooses the level and makes records; the real link code carries them over a
// real Unix socket; `cadr-terminal`'s own server takes them, maps them through
// muir's own key table and paces them; and a model of the input face stands
// where the fabric would be, behind the two function pointers `input_face.h`
// provides for exactly this.
//
// **AND BEHIND THE FACE IS A MODEL OF THE MACHINE THAT READS A WORD ONLY SO
// OFTEN.**  A face that took every word offered would not test the rule that
// matters: the fabric hands the card a word only when the card is free, and
// the program may hand over a word only when the machine has taken the last
// one AND the interval has gone by.  The model does the first, the check
// measures the second, and the words the machine actually read are what every
// assertion about a keystroke is made against.
//
// **THE CHECK CROSSES A PACKAGE BOUNDARY AND ONLY HERE.**  It compiles
// `input_keys.c`, `input_mapping.c`, `input_face.c` and `screen_server.c` from
// the screen's package, because the thing being checked is the whole road and
// half of it lives there.  The PROGRAM does not: it reads a device and writes
// a socket, and its target build links nothing of the screen's.  The same
// shape as the host build reaching into cadr-common's src/, which is a real
// directory here and is not there under Buildroot.
//
// What it cannot reach is named where it lives: `usb_set_scan`'s open, which
// needs `EVIOCGBIT` on a real evdev node, which a check cannot make without
// being root.  Everything above that open is driven directly.

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <linux/input.h>

#include <cadr/cadr_input_link.h>
#include <cadr/cadr_log.h>

#include "usb_devices.h"
#include "usb_keymap.h"
#include "usb_keys.h"

// **`KEY_UP` IS TWO THINGS AND THIS FILE INCLUDES BOTH HEADERS.**  evdev's is
// the up-arrow key, code 103; `input_keys.h`'s is bit 8 of a word on MIT's
// cable, "1=key up, 0=key down".  The second is the one every assertion here
// is about, so evdev's is put aside --- by name, so that a reader meeting the
// collision later finds it explained rather than renamed.
#undef KEY_UP

// The screen's package: the far half of the road.
#include "input_face.h"
#include "input_keys.h"
#include "input_mapping.h"
#include "screen_frame.h"
#include "screen_server.h"

static unsigned checks, failures;

static void check(int ok, const char *fmt, ...)
{
	++checks;
	if (ok)
		return;
	++failures;
	va_list ap;
	va_start(ap, fmt);
	fputs("    FAIL: ", stdout);
	vprintf(fmt, ap);
	putchar('\n');
	va_end(ap);
}

static void section(const char *name)
{
	printf("--- %s\n", name);
}

// ---- the fabric and the machine behind the face --------------------------

// The fabric's queue is sixteen words; `input_face.h` says the program must
// ask for room before it writes, and this counts a word written to a full
// queue in LOST exactly as the fabric does.
#define FACE_QUEUE 16
#define GOT_MAX 1024

struct machine_model {
	// the fabric
	uint32_t queue[FACE_QUEUE];
	unsigned head, count;
	uint32_t card;
	int kbd_ready;
	unsigned long lost;
	long long owed_x, owed_y;
	uint32_t buttons;
	unsigned long button_writes, flushes, mouse_writes;
	// the machine: it reads the card's word this often and no oftener
	uint64_t now, last_read, read_ns;
	uint32_t got[GOT_MAX];
	uint64_t got_at[GOT_MAX];
	unsigned gots;
};


static int sign12(uint32_t v)
{
	return (v & 0x800u) ? (int)v - 4096 : (int)v;
}

static uint32_t face_read(struct input_face *f, unsigned w)
{
	struct machine_model *m = f->ctx;
	switch (w) {
	case IN_IDENT:
		return IN_IDENT_WORD;
	case IN_STAT:
		return (uint32_t)((m->kbd_ready ? IN_ST_KBD_READY : 0u)
				  | (m->count < FACE_QUEUE ? IN_ST_ROOM : 0u)
				  | ((m->owed_x || m->owed_y) ? IN_ST_OWES : 0u)
				  | ((uint32_t)m->count << 8));
	case IN_KEY:
		return m->card;
	case IN_BUTTONS:
		return m->buttons;
	case IN_LOST:
		return (uint32_t)m->lost;
	default:
		return 0;
	}
}

static void face_write(struct input_face *f, unsigned w, uint32_t v)
{
	struct machine_model *m = f->ctx;
	switch (w) {
	case IN_KEY:
		if (m->count >= FACE_QUEUE) {
			++m->lost;
			return;
		}
		m->queue[(m->head + m->count) % FACE_QUEUE] = v & 0xFFFFFFu;
		++m->count;
		return;
	case IN_MOUSE:
		++m->mouse_writes;
		m->owed_x += sign12(v & 0xFFFu);
		m->owed_y += sign12((v >> 12) & 0xFFFu);
		return;
	case IN_BUTTONS:
		m->buttons = v & 7u;
		++m->button_writes;
		return;
	case IN_CTL:
		if (v & IN_CTL_FLUSH) {
			m->head = m->count = 0;
			m->kbd_ready = 0;
			m->owed_x = m->owed_y = 0;
			m->buttons = 0;
			++m->flushes;
		}
		return;
	default:
		return;
	}
}

// The fabric offering the card its next word, and the machine reading one.
static void machine_step(struct machine_model *m)
{
	if (m->kbd_ready && m->now - m->last_read >= m->read_ns) {
		if (m->gots < GOT_MAX) {
			m->got[m->gots] = m->card;
			m->got_at[m->gots] = m->now;
			++m->gots;
		}
		m->kbd_ready = 0;
		m->last_read = m->now;
	}
	// `cadr_input_cables.sv`'s `taking`: a word goes to the card as soon
	// as the card is free.
	if (!m->kbd_ready && m->count) {
		m->card = m->queue[m->head];
		m->head = (m->head + 1) % FACE_QUEUE;
		--m->count;
		m->kbd_ready = 1;
	}
}

// ---- a viewer, small and non-blocking ------------------------------------
//
// The screen's own check has a full one; this is the least that can hold a
// place as a viewer and send a key, because what is under check here is not
// RFB but what happens to the ONE keyboard when a viewer and a keyboard at
// the board are both attached.  It is stepped beside the server rather than
// blocking on it, both ends being in this process.

struct viewer {
	int fd;
	uint8_t in[4096];
	size_t len;
	int stage;   /* 0 version, 1 security, 2 result, 3 init, 4 running */
};

static void viewer_open(struct viewer *v, const struct screen_server *srv)
{
	memset(v, 0, sizeof *v);
	v->fd = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	a.sin_port = htons((uint16_t)screen_server_port(srv));
	if (connect(v->fd, (struct sockaddr *)&a, sizeof a) < 0) {
		fprintf(stderr, "usb_test: a viewer could not connect\n");
		exit(1);
	}
	fcntl(v->fd, F_SETFL, O_NONBLOCK);
	// **WITHOUT THIS THE SECOND SMALL MESSAGE WAITS FORTY MILLISECONDS**,
	// and this check's clock is its own: forty passes of the loop take
	// microseconds of real time, so a key held back by Nagle's algorithm
	// until the far end's delayed acknowledgement looks exactly like a key
	// the server never got.  Measured here, and it cost an hour.  The
	// server sets the same option on its own side; a real viewer sets it
	// or does not, and on a real keyboard's timescale it does not matter.
	const int one = 1;
	setsockopt(v->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
}

static void viewer_step(struct viewer *v)
{
	if (v->fd < 0)
		return;
	const ssize_t got = read(v->fd, v->in + v->len, sizeof v->in - v->len);
	if (got > 0)
		v->len += (size_t)got;
	for (;;) {
		if (v->stage == 0 && v->len >= 12) {
			memmove(v->in, v->in + 12, v->len - 12);
			v->len -= 12;
			const ssize_t put = write(v->fd, "RFB 003.008\n", 12);
			(void)put;
			v->stage = 1;
			continue;
		}
		if (v->stage == 1 && v->len >= 2) {
			// The count and the one type, None.
			memmove(v->in, v->in + 2, v->len - 2);
			v->len -= 2;
			const uint8_t pick = 1;
			const ssize_t put = write(v->fd, &pick, 1);
			(void)put;
			v->stage = 2;
			continue;
		}
		if (v->stage == 2 && v->len >= 4) {
			memmove(v->in, v->in + 4, v->len - 4);
			v->len -= 4;
			const uint8_t shared = 1;   /* ClientInit */
			const ssize_t put = write(v->fd, &shared, 1);
			(void)put;
			v->stage = 3;
			continue;
		}
		if (v->stage == 3 && v->len >= 24) {
			const uint32_t namelen = ((uint32_t)v->in[20] << 24)
					       | ((uint32_t)v->in[21] << 16)
					       | ((uint32_t)v->in[22] << 8) | v->in[23];
			if (v->len < 24 + namelen)
				break;
			memmove(v->in, v->in + 24 + namelen, v->len - 24 - namelen);
			v->len -= 24 + namelen;
			v->stage = 4;
			continue;
		}
		break;
	}
}

static void viewer_key(struct viewer *v, uint32_t keysym, int down)
{
	uint8_t m[8];
	memset(m, 0, sizeof m);
	m[0] = 4;                       /* KeyEvent */
	m[1] = (uint8_t)(down ? 1 : 0);
	m[4] = (uint8_t)(keysym >> 24);
	m[5] = (uint8_t)(keysym >> 16);
	m[6] = (uint8_t)(keysym >> 8);
	m[7] = (uint8_t)keysym;
	const ssize_t put = write(v->fd, m, sizeof m);
	(void)put;
}

static void viewer_pointer(struct viewer *v, unsigned buttons, unsigned x, unsigned y)
{
	uint8_t m[6];
	m[0] = 5;                       /* PointerEvent */
	m[1] = (uint8_t)buttons;
	m[2] = (uint8_t)(x >> 8);
	m[3] = (uint8_t)x;
	m[4] = (uint8_t)(y >> 8);
	m[5] = (uint8_t)y;
	const ssize_t put = write(v->fd, m, sizeof m);
	(void)put;
}

static void viewer_gone(struct viewer *v)
{
	if (v->fd >= 0)
		close(v->fd);
	v->fd = -1;
}

// ---- the harness ---------------------------------------------------------

struct harness {
	struct machine_model m;
	struct input_face face;
	struct screen_server srv;
	struct screen_frame frame;
	struct cadr_input_link_client client;
	struct usb_set set;
	struct usb_out out;
	struct viewer *watching;
	int kbd_w, mouse_w;
	unsigned long sent, send_fail;
	char path[128];
};

static void t_send(void *ctx, const struct cadr_input_event *e)
{
	struct harness *h = ctx;
	if (cadr_input_link_send(&h->client, e) < 0)
		++h->send_fail;
	else
		++h->sent;
}

// One pass of everything, with time moved on by `ns`.
static void pump(struct harness *h, uint64_t ns)
{
	h->m.now += ns;
	machine_step(&h->m);
	struct pollfd fds[USB_MAX_DEVICES];
	const unsigned n = usb_set_pollfds(&h->set, fds, USB_MAX_DEVICES);
	if (n) {
		poll(fds, n, 0);
		usb_set_poll(&h->set, fds, n, &h->out);
	}
	screen_server_poll(&h->srv, &h->frame, 0, h->m.now);
	if (h->watching)
		viewer_step(h->watching);
	machine_step(&h->m);
}

static void feed(int fd, uint16_t type, uint16_t code, int value)
{
	struct input_event ev;
	memset(&ev, 0, sizeof ev);
	ev.type = type;
	ev.code = code;
	ev.value = value;
	const ssize_t put = write(fd, &ev, sizeof ev);
	(void)put;
}

// A key, and time enough for it to reach the machine: the pacing rule holds a
// word back until the interval has gone by, so a keystroke of two words needs
// two of them.
static void settle(struct harness *h, unsigned passes)
{
	for (unsigned k = 0; k < passes; ++k)
		pump(h, INPUT_KEY_INTERVAL_NS);
}

static void harness_open(struct harness *h, const char *work, const char *tag, uint64_t read_ns)
{
	memset(h, 0, sizeof *h);
	h->m.read_ns = read_ns;
	h->m.now = 1;
	h->face.read = face_read;
	h->face.write = face_write;
	h->face.ctx = &h->m;
	screen_frame_init(&h->frame, 0);
	if (screen_server_bind(&h->srv, "127.0.0.1", 0) < 0) {
		fprintf(stderr, "usb_test: no socket for the screen server\n");
		exit(1);
	}
	h->srv.input = &h->face;
	key_state_init(&h->srv.keys);
	// The flush, as the program does it, before anything can be sent.
	input_face_flush(&h->face);
	// **THE SOCKET'S PATH IS SHORT ON PURPOSE, AND IT WAS NOT AT FIRST.**
	// A Unix socket's path is 108 bytes including the terminator, and the
	// mutation runner gives each record a directory named after it --- so
	// `<cache>/mutants/<a-long-kebab-case-name>/link-kbd-<pid>` ran over
	// the limit, the bind was refused, the check exited before it had
	// asserted anything, and the runner counted the record as CAUGHT.  A
	// record caught for a reason that is not its own is worse than one
	// that survives.  So the socket goes in a short directory of its own
	// and the length is asserted rather than hoped for.
	const char *home = getenv("HOME");
	snprintf(h->path, sizeof h->path, "%s/.cache/usbt-%u-%s",
		 home && *home ? home : work, (unsigned)getpid(), tag);
	if (strlen(h->path) >= 100) {
		fprintf(stderr, "usb_test: the socket's path is %u characters and a Unix "
				"socket's is 107: %s\n", (unsigned)strlen(h->path), h->path);
		exit(1);
	}
	if (screen_server_link(&h->srv, h->path) < 0) {
		fprintf(stderr, "usb_test: no input link at %s\n", h->path);
		exit(1);
	}
	usb_set_init(&h->set);
	h->out.event = t_send;
	h->out.ctx = h;
	h->client.fd = -1;

	const char *why = NULL;
	if (cadr_input_link_open(&h->client, h->path, &why) < 0) {
		fprintf(stderr, "usb_test: the client could not attach: %s\n", why);
		exit(1);
	}
	// Two passes: the server accepts on one and reads the greeting on the
	// next.
	for (unsigned k = 0; k < 4 && !h->client.greeted; ++k) {
		pump(h, 1000);
		cadr_input_link_greet(&h->client, &why);
	}
}

static void harness_close(struct harness *h)
{
	cadr_input_link_shut(&h->client);
	usb_set_close(&h->set, NULL);
	screen_server_close(&h->srv);
	unlink(h->path);
	if (h->kbd_w >= 0)
		close(h->kbd_w);
	if (h->mouse_w >= 0)
		close(h->mouse_w);
}

// A device the check can write events into: a socket pair standing where an
// evdev node would be.
static int add_device(struct harness *h, unsigned kind, const char *node)
{
	int pair[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) < 0) {
		fprintf(stderr, "usb_test: no socket pair\n");
		exit(1);
	}
	fcntl(pair[0], F_SETFL, O_NONBLOCK);
	if (usb_set_add(&h->set, pair[0], kind, node, "a device made for the check") < 0) {
		fprintf(stderr, "usb_test: no room for a device\n");
		exit(1);
	}
	return pair[1];
}

// ---- what the machine was given ------------------------------------------

#define WORD_FRAME(w) ((w) >> 16)
#define WORD_UP(w) (((w) >> 8) & 1u)
#define WORD_POS(w) ((w) & 0177u)

static int saw(const struct machine_model *m, unsigned at, unsigned pos, unsigned up)
{
	return at < m->gots && WORD_POS(m->got[at]) == pos && WORD_UP(m->got[at]) == up;
}

static const char *word_text(uint32_t w, char *buf, size_t n)
{
	snprintf(buf, n, "0o%o %s", WORD_POS(w), WORD_UP(w) ? "up" : "down");
	return buf;
}

static void dump(const struct machine_model *m, unsigned from)
{
	char b[32];
	for (unsigned k = from; k < m->gots; ++k)
		printf("        %u: %s\n", k, word_text(m->got[k], b, sizeof b));
}

// evdev key codes used below, from linux/input-event-codes.h.
#define C_ESC 1
#define C_1 2
#define C_7 8
#define C_A 30
#define C_D 32
#define C_ENTER 28
#define C_LCTRL 29
#define C_LSHIFT 42
#define C_RSHIFT 54
#define C_SPACE 57
#define C_CAPS 58
#define C_F1 59
#define C_NUMLOCK 69
#define C_KP7 71
#define C_SCROLL 70
#define C_MENU 127
#define C_TAB 15
#define C_RIGHTALT 100
#define C_LALT 56
#define C_DELETE 111

// MIT's own positions, written out rather than looked up in the table the
// code uses: an expectation computed from the same table would agree with a
// table that had moved.
#define P_1 0121
#define P_A 0123
#define P_D 0163
#define P_7 0151
#define P_SPACE 0134
#define P_SHIFT_L 024
#define P_SHIFT_R 025
#define P_CONTROL_L 020
#define P_RETURN 0136
#define P_ALTMODE 0143
#define P_CAPSLOCK 0125
#define P_TERMINAL 040
#define P_TAB 022
#define P_META_L 045
#define P_RUBOUT 023

int main(int argc, char **argv)
{
	const char *work = ".";
	for (int k = 1; k < argc; ++k) {
		if (strcmp(argv[k], "--work") == 0 && k + 1 < argc)
			work = argv[++k];
		else {
			fprintf(stderr, "usage: usb_test [--work DIR]\n");
			return 2;
		}
	}
	// The log goes nowhere by default: this check makes devices come and
	// go on purpose and every one of them says so.
	FILE *quiet = fopen("/dev/null", "w");
	cadr_log_init("usb_test: ", quiet ? quiet : stderr);

	// ---------------------------------------------------------------
	section("the record on the wire");
	{
		struct cadr_input_event e, back;
		uint8_t b[CADR_INPUT_LINK_MSG];
		memset(&e, 0, sizeof e);
		e.type = CADR_INPUT_KEY;
		e.down = 1;
		e.keysym = 0xFF08u;
		cadr_input_encode(&e, b);
		check(cadr_input_decode(b, &back) == 0, "a key record decodes");
		check(back.type == e.type && back.down == e.down && back.keysym == e.keysym,
		      "a key record survives the wire");
		memset(&e, 0, sizeof e);
		e.type = CADR_INPUT_POINTER;
		e.dx = -300;
		e.dy = 17;
		e.buttons = 5;
		cadr_input_encode(&e, b);
		check(cadr_input_decode(b, &back) == 0, "a pointer record decodes");
		check(back.dx == -300 && back.dy == 17 && back.buttons == 5,
		      "a negative delta survives the wire: %d %d %u",
		      back.dx, back.dy, back.buttons);
		b[0] = 9;
		check(cadr_input_decode(b, &back) < 0,
		      "a record of a kind the link does not know is refused");
	}

	// ---------------------------------------------------------------
	section("the levels, which are chosen in this program and nowhere else");
	{
		struct usb_kbd_state k;
		struct cadr_input_event e;
		usb_kbd_init(&k);
		check(usb_kbd_key(&k, C_A, 1, &e) == 1 && e.keysym == 'a',
		      "a with no shift is the keysym a");
		check(usb_kbd_key(&k, C_A, 0, &e) == 1 && e.keysym == 'a', "...and comes up as a");

		check(usb_kbd_key(&k, C_LSHIFT, 1, &e) == 1 && e.keysym == 0xFFE1u,
		      "Shift is a key of its own and goes across as Shift_L");
		check(usb_kbd_key(&k, C_1, 1, &e) == 1 && e.keysym == '!',
		      "**SHIFT AND 1 IS exclam AND NOT 1**: the level is applied here");
		check(usb_kbd_key(&k, C_LSHIFT, 0, &e) == 1, "Shift comes up");
		check(usb_kbd_key(&k, C_1, 0, &e) == 1 && e.keysym == '!',
		      "**AND THE KEY COMES UP WITH THE KEYSYM IT WENT DOWN WITH**, "
		      "Shift having been let go between");

		check(usb_kbd_key(&k, C_A, 2, &e) == 0, "the kernel's repeat goes nowhere");
		check(k.repeats == 1, "...and is counted");
		usb_kbd_key(&k, C_A, 1, &e);
		check(usb_kbd_key(&k, C_A, 1, &e) == 0,
		      "a second press with no release between goes nowhere");
		usb_kbd_key(&k, C_A, 0, &e);

		check(usb_kbd_key(&k, C_RSHIFT, 1, &e) == 1 && e.keysym == 0xFFE2u,
		      "the right Shift is Shift_R");
		check(usb_kbd_key(&k, C_A, 1, &e) == 1 && e.keysym == 'A',
		      "the right Shift shifts as the left one does");
		usb_kbd_key(&k, C_A, 0, &e);
		usb_kbd_key(&k, C_RSHIFT, 0, &e);

		check(usb_kbd_key(&k, C_CAPS, 1, &e) == 1 && e.keysym == 0xFFE5u,
		      "Caps Lock goes across as a key");
		check(usb_kbd_key(&k, C_A, 1, &e) == 1 && e.keysym == 'a',
		      "**AND IS NOT APPLIED HERE**: the machine does the locking");
		usb_kbd_key(&k, C_A, 0, &e);
		usb_kbd_key(&k, C_CAPS, 0, &e);

		check(k.numlock == 1, "Num Lock starts on");
		check(usb_kbd_key(&k, C_KP7, 1, &e) == 1 && e.keysym == 0xFFB7u,
		      "the keypad's 7 is KP_7 with Num Lock on");
		usb_kbd_key(&k, C_KP7, 0, &e);
		usb_kbd_key(&k, C_NUMLOCK, 1, &e);
		usb_kbd_key(&k, C_NUMLOCK, 0, &e);
		check(k.numlock == 0, "Num Lock turns over on the press");
		check(usb_kbd_key(&k, C_KP7, 1, &e) == 1 && e.keysym == 0xFF95u,
		      "...and the same key is KP_Home with it off");
		usb_kbd_key(&k, C_KP7, 0, &e);
		usb_kbd_key(&k, C_NUMLOCK, 1, &e);
		usb_kbd_key(&k, C_NUMLOCK, 0, &e);
		check(usb_kbd_key(&k, C_LSHIFT, 1, &e) == 1, "Shift down");
		check(usb_kbd_key(&k, C_KP7, 1, &e) == 1 && e.keysym == 0xFFB7u,
		      "Shift does not choose the keypad's level; Num Lock does");
		usb_kbd_key(&k, C_KP7, 0, &e);
		usb_kbd_key(&k, C_LSHIFT, 0, &e);

		check(usb_kbd_key(&k, 250, 1, &e) == 0, "a key code nothing maps goes nowhere");
		check(usb_kbd_key(&k, 3000, 1, &e) == 0, "...and one past the table too");
		check(k.unknown == 2, "...and both are counted");

		// What a device owes.
		usb_kbd_key(&k, C_LCTRL, 1, &e);
		usb_kbd_key(&k, C_A, 1, &e);
		struct cadr_input_event owed[USB_KBD_MAX_DOWN];
		const unsigned n = usb_kbd_release_all(&k, owed, USB_KBD_MAX_DOWN);
		check(n == 2, "two keys were held and two releases are owed, not %u", n);
		check(owed[0].keysym == 0xFFE3u && owed[0].down == 0,
		      "the oldest is released first, and it is Control_L");
		check(owed[1].keysym == 'a' && owed[1].down == 0, "then a");
		check(usb_kbd_release_all(&k, owed, USB_KBD_MAX_DOWN) == 0,
		      "and nothing is owed twice");

		// The bound.
		usb_kbd_init(&k);
		unsigned down = 0;
		for (uint16_t code = C_A; code < C_A + 30; ++code)
			if (usb_kbd_key(&k, code, 1, &e))
				++down;
		check(down == USB_KBD_MAX_DOWN,
		      "no more keys are held than releases can be owed for: %u", down);
		check(k.refused > 0, "...and the rest are refused whole and counted");
	}

	// ---------------------------------------------------------------
	section("the mouse");
	{
		struct usb_mouse_state m;
		struct cadr_input_event e;
		usb_mouse_init(&m);
		usb_mouse_event(&m, EV_REL, REL_X, 3);
		usb_mouse_event(&m, EV_REL, REL_Y, -4);
		usb_mouse_event(&m, EV_REL, REL_X, 2);
		check(usb_mouse_report(&m, &e) == 1, "a report with motion in it goes");
		check(e.dx == 5 && e.dy == -4,
		      "**A WHOLE REPORT IS ONE RECORD**: 3 and 2 are 5, and down is positive; "
		      "got %d %d", e.dx, e.dy);
		check(usb_mouse_report(&m, &e) == 0, "a report with nothing in it does not");

		usb_mouse_event(&m, EV_REL, REL_WHEEL, 1);
		check(usb_mouse_report(&m, &e) == 0, "a wheel is not a switch and goes nowhere");
		check(m.wheels == 1, "...and is counted");

		usb_mouse_event(&m, EV_KEY, BTN_LEFT, 1);
		check(usb_mouse_report(&m, &e) == 1 && e.buttons == 1,
		      "the left button is bit 0, which is MIT's order");
		usb_mouse_event(&m, EV_KEY, BTN_RIGHT, 1);
		check(usb_mouse_report(&m, &e) == 1 && e.buttons == 5,
		      "the right button is bit 2 and the switches are a level");
		usb_mouse_event(&m, EV_KEY, BTN_MIDDLE, 1);
		check(usb_mouse_report(&m, &e) == 1 && e.buttons == 7, "the middle is bit 1");
		usb_mouse_event(&m, EV_KEY, BTN_LEFT, 0);
		check(usb_mouse_report(&m, &e) == 1 && e.buttons == 6, "and one of them let go");
		check(usb_mouse_release_all(&m, &e) == 1 && e.buttons == 0,
		      "what a mouse owes when it is unplugged is every switch lifted");
		check(usb_mouse_release_all(&m, &e) == 0, "...and only once");
	}

	// ---------------------------------------------------------------
	section("the generated table against the database it came from");
	{
		// Hand-written anchors: a table generated from files on a build
		// host is checked against what those files say, not against
		// itself.  These are what `pc+us` gives, read off
		// symbols/pc and symbols/us.
		static const struct {
			uint16_t code;
			uint32_t plain, shifted;
			const char *what;
		} anchors[] = {
			{ C_ESC, 0xFF1Bu, 0xFF1Bu, "Escape" },
			{ C_1, '1', '!', "1 and exclam" },
			{ C_A, 'a', 'A', "a and A" },
			{ C_SPACE, ' ', ' ', "space" },
			{ C_ENTER, 0xFF0Du, 0xFF0Du, "Return" },
			{ C_LSHIFT, 0xFFE1u, 0xFFE1u, "Shift_L" },
			{ C_RSHIFT, 0xFFE2u, 0xFFE2u, "Shift_R" },
			{ C_LCTRL, 0xFFE3u, 0xFFE3u, "Control_L" },
			{ C_CAPS, 0xFFE5u, 0xFFE5u, "Caps_Lock" },
			{ C_F1, 0xFFBEu, 0xFFBEu, "F1" },
			{ C_SCROLL, 0xFF14u, 0xFF14u, "Scroll_Lock, which is the prefix" },
			{ C_MENU, 0xFF67u, 0xFF67u, "Menu, which muir's mapping makes Top" },
			{ C_RIGHTALT, 0xFFEAu, 0xFFEAu, "Alt_R, which is Right Meta" },
			{ C_KP7, 0xFF95u, 0xFFB7u, "the keypad's 7" },
		};
		for (unsigned k = 0; k < sizeof anchors / sizeof anchors[0]; ++k) {
			const struct usb_key *e = NULL;
			for (size_t i = 0; i < USB_KEYS_COUNT; ++i)
				if (USB_KEYS[i].code == anchors[k].code) {
					e = &USB_KEYS[i];
					break;
				}
			check(e != NULL, "the table has key code %u (%s)",
			      anchors[k].code, anchors[k].what);
			if (!e)
				continue;
			check(e->plain == anchors[k].plain && e->shifted == anchors[k].shifted,
			      "key code %u is %s: 0x%x/0x%x, wanting 0x%x/0x%x",
			      anchors[k].code, anchors[k].what, e->plain, e->shifted,
			      anchors[k].plain, anchors[k].shifted);
		}
		// Every key code appears once.  Two rows with one code would
		// hide one of them behind the other for ever.
		unsigned twice = 0;
		for (size_t i = 0; i < USB_KEYS_COUNT; ++i)
			for (size_t j = i + 1; j < USB_KEYS_COUNT; ++j)
				if (USB_KEYS[i].code == USB_KEYS[j].code)
					++twice;
		check(twice == 0, "%u key codes appear twice in the table", twice);
		check(USB_KEYS_COUNT > 100, "the table has %u keys", (unsigned)USB_KEYS_COUNT);
	}

	// ---------------------------------------------------------------
	section("a keyboard, end to end, to a machine that reads slowly");
	{
		struct harness h;
		// The machine reads a word every 100 us, which is far slower
		// than the program may offer them: what reaches it is then
		// bounded by the machine and not by this check's clock.
		harness_open(&h, work, "kbd", 100000);
		check(h.client.greeted, "the client is attached and greeted");
		check(h.m.flushes == 1, "the fabric's queue was flushed before anything could type");
		h.kbd_w = add_device(&h, USB_KIND_KEYBOARD, "event0");
		h.mouse_w = -1;

		// `a`
		feed(h.kbd_w, EV_KEY, C_A, 1);
		feed(h.kbd_w, EV_KEY, C_A, 0);
		settle(&h, 8);
		check(h.m.gots == 2, "one key is two words, not %u", h.m.gots);
		check(saw(&h.m, 0, P_A, 0) && saw(&h.m, 1, P_A, 1),
		      "a is position 0o%o down then up", P_A);
		check(WORD_FRAME(h.m.got[0]) == 0371u,
		      "the word carries MIT's frame: 0o%o", WORD_FRAME(h.m.got[0]));

		// Shift and 1, which must NOT lift the Shift.
		const unsigned was = h.m.gots;
		feed(h.kbd_w, EV_KEY, C_LSHIFT, 1);
		feed(h.kbd_w, EV_KEY, C_1, 1);
		feed(h.kbd_w, EV_KEY, C_1, 0);
		feed(h.kbd_w, EV_KEY, C_LSHIFT, 0);
		settle(&h, 12);
		check(h.m.gots - was == 4,
		      "**SHIFT AND 1 IS FOUR WORDS AND NOT SIX**: %u", h.m.gots - was);
		check(saw(&h.m, was, P_SHIFT_L, 0), "Shift goes down at its own position");
		check(saw(&h.m, was + 1, P_1, 0),
		      "**AND THE KEY IS PRESSED WITH SHIFT STILL DOWN**, which is what a "
		      "raw keysym would have got wrong");
		check(saw(&h.m, was + 2, P_1, 1) && saw(&h.m, was + 3, P_SHIFT_L, 1),
		      "then the key and then Shift come up");
		if (h.m.gots - was != 4)
			dump(&h.m, was);

		// The keys that are positions of their own, and no modifier
		// bit anywhere.
		const unsigned m2 = h.m.gots;
		feed(h.kbd_w, EV_KEY, C_LCTRL, 1);
		feed(h.kbd_w, EV_KEY, C_D, 1);
		feed(h.kbd_w, EV_KEY, C_D, 0);
		feed(h.kbd_w, EV_KEY, C_LCTRL, 0);
		settle(&h, 12);
		check(h.m.gots - m2 == 4 && saw(&h.m, m2, P_CONTROL_L, 0)
		      && saw(&h.m, m2 + 1, P_D, 0),
		      "Control is a key at a position of its own, not a bit");
		int bits = 0;
		for (unsigned k = 0; k < h.m.gots; ++k)
			if (WORD_FRAME(h.m.got[k]) != 0371u || (h.m.got[k] & 0x7E00u))
				++bits;
		check(bits == 0, "%d words carried something that is not a position and an up bit",
		      bits);

		// The named keys muir's mapping binds.
		const unsigned m3 = h.m.gots;
		feed(h.kbd_w, EV_KEY, C_ENTER, 1);
		feed(h.kbd_w, EV_KEY, C_ENTER, 0);
		feed(h.kbd_w, EV_KEY, C_ESC, 1);
		feed(h.kbd_w, EV_KEY, C_ESC, 0);
		feed(h.kbd_w, EV_KEY, C_F1, 1);
		feed(h.kbd_w, EV_KEY, C_F1, 0);
		settle(&h, 16);
		check(saw(&h.m, m3, P_RETURN, 0), "Return is MIT's Return");
		check(saw(&h.m, m3 + 2, P_ALTMODE, 0), "Escape is Alt Mode");
		check(saw(&h.m, m3 + 4, P_TERMINAL, 0), "F1 is Terminal");

		// **AN EVENT THAT ARRIVES IN TWO PIECES.**  A read of a device
		// gives whole `input_event`s and may give a part of one, and
		// what is left over is kept until the rest arrives.  Nothing
		// in a socket pair makes that happen by itself, so it is made
		// to happen here: half an event, a pass of the loop, then the
		// other half.
		const unsigned m4 = h.m.gots;
		{
			// A whole event and the first five bytes of the next,
			// in ONE write: the read then carries an event to act
			// on AND a leftover to keep, which is the case the
			// keeping exists for.
			struct input_event two[2];
			memset(two, 0, sizeof two);
			two[0].type = EV_KEY;
			two[0].code = C_A;
			two[0].value = 1;
			two[1].type = EV_KEY;
			two[1].code = C_A;
			two[1].value = 0;
			const uint8_t *b = (const uint8_t *)two;
			const ssize_t a = write(h.kbd_w, b, sizeof two[0] + 5);
			(void)a;
			settle(&h, 4);
			check(h.m.gots == m4 + 1 && saw(&h.m, m4, P_A, 0),
			      "the whole event of a part-read arrives: %u words",
			      h.m.gots - m4);
			const ssize_t c = write(h.kbd_w, b + sizeof two[0] + 5,
						sizeof two[1] - 5);
			(void)c;
			settle(&h, 4);
			check(h.m.gots == m4 + 2 && saw(&h.m, m4 + 1, P_A, 1),
			      "**AND THE PART THAT WAS KEPT COMPLETES**: %u words",
			      h.m.gots - m4);
		}

		// The words arrived in the order they were typed and none was
		// lost in the fabric.
		check(h.m.lost == 0, "%lu words were lost in the fabric", h.m.lost);
		check(h.send_fail == 0, "%lu records would not go down the link", h.send_fail);
		harness_close(&h);
	}

	// ---------------------------------------------------------------
	section("how fast a burst of typing reaches the machine");
	{
		struct harness h;
		// A machine that reads as fast as it is offered, so that what
		// binds is the program's own interval and not the machine.
		harness_open(&h, work, "pace", 1);
		h.kbd_w = add_device(&h, USB_KIND_KEYBOARD, "event0");
		h.mouse_w = -1;
		// Twenty characters as fast as a device can deliver them: one
		// pump takes them all off the device and into the far end's
		// backlog, where they wait.
		for (unsigned k = 0; k < 20; ++k) {
			feed(h.kbd_w, EV_KEY, C_A, 1);
			feed(h.kbd_w, EV_KEY, C_A, 0);
		}
		// Small steps, so that a word going early would be seen going
		// early: a tenth of the interval at a time.
		for (unsigned k = 0; k < 1000; ++k)
			pump(&h, INPUT_KEY_INTERVAL_NS / 10);
		check(h.m.gots == 40, "forty words for twenty characters, not %u", h.m.gots);
		check(h.m.lost == 0, "%lu lost in the fabric", h.m.lost);
		unsigned too_close = 0;
		uint64_t closest = (uint64_t)-1;
		for (unsigned k = 1; k < h.m.gots; ++k) {
			const uint64_t gap = h.m.got_at[k] - h.m.got_at[k - 1];
			if (gap < closest)
				closest = gap;
			if (gap < INPUT_KEY_INTERVAL_NS)
				++too_close;
		}
		check(too_close == 0,
		      "**%u words came closer together than the interval**; the closest was "
		      "%llu ns against %llu", too_close, (unsigned long long)closest,
		      (unsigned long long)INPUT_KEY_INTERVAL_NS);
		unsigned wrong = 0;
		for (unsigned k = 0; k < h.m.gots; ++k)
			if (WORD_POS(h.m.got[k]) != P_A || WORD_UP(h.m.got[k]) != (k & 1u))
				++wrong;
		check(wrong == 0, "%u of the burst's words were out of order or wrong", wrong);
		printf("    twenty characters: forty words, the closest pair %llu ns apart, "
		       "the rule being %llu\n", (unsigned long long)closest,
		       (unsigned long long)INPUT_KEY_INTERVAL_NS);
		harness_close(&h);
	}

	// ---------------------------------------------------------------
	section("the mouse, end to end");
	{
		struct harness h;
		harness_open(&h, work, "mouse", 1);
		h.kbd_w = -1;
		h.mouse_w = add_device(&h, USB_KIND_MOUSE, "event1");
		feed(h.mouse_w, EV_REL, REL_X, 7);
		feed(h.mouse_w, EV_REL, REL_Y, 3);
		feed(h.mouse_w, EV_SYN, SYN_REPORT, 0);
		pump(&h, 1000);
		pump(&h, 1000);
		check(h.m.owed_x == 7 && h.m.owed_y == 3,
		      "right and down are positive at the fabric: %lld %lld",
		      h.m.owed_x, h.m.owed_y);
		check(h.m.mouse_writes == 1, "one report is one write, not %lu", h.m.mouse_writes);
		feed(h.mouse_w, EV_REL, REL_X, -9);
		feed(h.mouse_w, EV_REL, REL_Y, -1);
		feed(h.mouse_w, EV_SYN, SYN_REPORT, 0);
		pump(&h, 1000);
		pump(&h, 1000);
		check(h.m.owed_x == -2 && h.m.owed_y == 2,
		      "left and up are negative and are added to what is owed: %lld %lld",
		      h.m.owed_x, h.m.owed_y);

		// The switches, and the OR with what a viewer is holding.
		feed(h.mouse_w, EV_KEY, BTN_LEFT, 1);
		feed(h.mouse_w, EV_SYN, SYN_REPORT, 0);
		pump(&h, 1000);
		pump(&h, 1000);
		check(h.m.buttons == IN_BTN_LEFT, "the left switch reaches the cable: %u",
		      h.m.buttons);
		// A viewer holding the right one, as `screen_server_poll`
		// would have left it.
		h.srv.buttons = IN_BTN_RIGHT;
		feed(h.mouse_w, EV_KEY, BTN_MIDDLE, 1);
		feed(h.mouse_w, EV_SYN, SYN_REPORT, 0);
		pump(&h, 1000);
		pump(&h, 1000);
		check(h.m.buttons == (IN_BTN_LEFT | IN_BTN_MIDDLE | IN_BTN_RIGHT),
		      "**THE SWITCHES ARE THE OR OF BOTH SOURCES**: 0x%x", h.m.buttons);
		feed(h.mouse_w, EV_KEY, BTN_LEFT, 0);
		feed(h.mouse_w, EV_KEY, BTN_MIDDLE, 0);
		feed(h.mouse_w, EV_SYN, SYN_REPORT, 0);
		pump(&h, 1000);
		pump(&h, 1000);
		check(h.m.buttons == IN_BTN_RIGHT,
		      "the mouse letting go does not lift what the viewer holds: 0x%x",
		      h.m.buttons);
		harness_close(&h);
	}

	// ---------------------------------------------------------------
	section("a device unplugged, and plugged in again");
	{
		struct harness h;
		harness_open(&h, work, "hotplug", 1);
		h.kbd_w = add_device(&h, USB_KIND_KEYBOARD, "event0");
		h.mouse_w = -1;
		feed(h.kbd_w, EV_KEY, C_LCTRL, 1);
		feed(h.kbd_w, EV_KEY, C_A, 1);
		settle(&h, 6);
		check(h.m.gots == 2 && saw(&h.m, 0, P_CONTROL_L, 0) && saw(&h.m, 1, P_A, 0),
		      "two keys are held with nothing released");
		// Unplugged: the node goes and the read gives nothing.
		close(h.kbd_w);
		h.kbd_w = -1;
		settle(&h, 8);
		check(h.set.devices == 0, "the device is forgotten");
		check(h.set.gone == 1, "...and counted");
		check(h.m.gots == 4, "**WHAT IT HELD COMES UP**: %u words, wanting 4", h.m.gots);
		check(saw(&h.m, 2, P_CONTROL_L, 1) && saw(&h.m, 3, P_A, 1),
		      "Control and a are released, oldest first");
		if (h.m.gots != 4)
			dump(&h.m, 2);
		// And plugged in again, at a node of the same name.
		h.kbd_w = add_device(&h, USB_KIND_KEYBOARD, "event0");
		check(h.set.devices == 1, "a device that comes back is opened");
		feed(h.kbd_w, EV_KEY, C_A, 1);
		feed(h.kbd_w, EV_KEY, C_A, 0);
		settle(&h, 8);
		check(h.m.gots == 6 && saw(&h.m, 4, P_A, 0) && saw(&h.m, 5, P_A, 1),
		      "...and it types: %u words", h.m.gots);
		harness_close(&h);
	}

	// ---------------------------------------------------------------
	section("a source that goes away without saying so");
	{
		struct harness h;
		harness_open(&h, work, "gone", 1);
		h.kbd_w = add_device(&h, USB_KIND_KEYBOARD, "event0");
		h.mouse_w = -1;
		feed(h.kbd_w, EV_KEY, C_LCTRL, 1);
		feed(h.kbd_w, EV_KEY, C_LSHIFT, 1);
		settle(&h, 6);
		check(h.m.gots == 2, "two shifting keys are down at the machine");
		check(cadr_input_link_clients(&h.srv.link) == 1, "one source is attached");
		// The program dies: the socket closes with the keys still down.
		cadr_input_link_shut(&h.client);
		settle(&h, 6);
		check(cadr_input_link_clients(&h.srv.link) == 0, "the server lets it go");
		check(h.m.gots == 4, "**AND RELEASES WHAT IT HELD**: %u words, wanting 4",
		      h.m.gots);
		check(saw(&h.m, 2, P_CONTROL_L, 1) && saw(&h.m, 3, P_SHIFT_L, 1),
		      "Control and Shift come up");
		if (h.m.gots != 4)
			dump(&h.m, 2);
		h.set.devices = 0;   /* the devices' own state is not what is under test */
		harness_close(&h);
	}

	// ---------------------------------------------------------------
	section("one mapping file serves a viewer and a keyboard at the board");
	{
		struct harness h;
		harness_open(&h, work, "mapping", 1);
		// muir's own format, and the numeric spelling of a keysym the
		// name table does not carry.  The keypad's 7 is unbound in the
		// built-in mapping --- KP_7 is neither bound nor printable ---
		// so this is the line somebody writes to make the keypad type.
		static const char text[] = "key 0xffb7 7\n";
		struct key_map map;
		char err[KEY_MAP_ERR_MAX];
		key_map_built_in(&map);
		check(key_map_read(&map, text, err, sizeof err) == 0,
		      "the mapping file parses: %s", err);
		key_state_init_with(&h.srv.keys, &map);
		h.kbd_w = add_device(&h, USB_KIND_KEYBOARD, "event0");
		h.mouse_w = -1;
		feed(h.kbd_w, EV_KEY, C_KP7, 1);
		feed(h.kbd_w, EV_KEY, C_KP7, 0);
		settle(&h, 8);
		check(h.m.gots == 2 && saw(&h.m, 0, P_7, 0),
		      "the keypad's 7 types position 0o%o, the file having said so", P_7);
		harness_close(&h);
	}
	{
		// **AND WHAT A BINDING CANNOT DO**, pinned so that nobody
		// reads one as doing more than it does.  The US layout puts
		// `ISO_Left_Tab` on the shifted plane of the Tab key and
		// muir's mapping binds it to nothing, so Shift and Tab types
		// nothing.  Bound to MIT's Tab it types a PLAIN Tab: a named
		// key is bound on the unshifted plane, and the state machine
		// works Shift around a key whose plane the source is not
		// holding.  A Lisp Machine keyboard would have sent Shift held
		// with the Tab position, and no keysym mapping can ask for
		// that --- a keysym says what was typed and not which keys
		// were down.
		struct harness h;
		static const char text[] = "key 0xfe20 Tab\n";
		struct key_map map;
		char err[KEY_MAP_ERR_MAX];
		harness_open(&h, work, "shift-tab", 1);
		key_map_built_in(&map);
		check(key_map_read(&map, text, err, sizeof err) == 0,
		      "the Shift-Tab line parses: %s", err);
		key_state_init_with(&h.srv.keys, &map);
		h.kbd_w = add_device(&h, USB_KIND_KEYBOARD, "event0");
		h.mouse_w = -1;
		feed(h.kbd_w, EV_KEY, C_LSHIFT, 1);
		feed(h.kbd_w, EV_KEY, C_TAB, 1);
		feed(h.kbd_w, EV_KEY, C_TAB, 0);
		feed(h.kbd_w, EV_KEY, C_LSHIFT, 0);
		settle(&h, 16);
		check(h.m.gots == 6, "six words, Shift being worked around the key: %u",
		      h.m.gots);
		check(saw(&h.m, 0, P_SHIFT_L, 0) && saw(&h.m, 1, P_SHIFT_L, 1)
		      && saw(&h.m, 2, P_TAB, 0) && saw(&h.m, 3, P_TAB, 1)
		      && saw(&h.m, 4, P_SHIFT_L, 0) && saw(&h.m, 5, P_SHIFT_L, 1),
		      "Shift down, Shift up, Tab down, Tab up, Shift down, Shift up");
		if (h.m.gots != 6)
			dump(&h.m, 0);
		harness_close(&h);
	}
	{
		// ...and with the built-in mapping it types nothing, which is
		// what the document says and is the reason the line above is
		// worth writing.
		struct harness h;
		harness_open(&h, work, "unbound", 1);
		h.kbd_w = add_device(&h, USB_KIND_KEYBOARD, "event0");
		h.mouse_w = -1;
		feed(h.kbd_w, EV_KEY, C_KP7, 1);
		feed(h.kbd_w, EV_KEY, C_KP7, 0);
		settle(&h, 8);
		check(h.m.gots == 0, "an unbound keysym reaches the machine as nothing: %u words",
		      h.m.gots);
		check(h.srv.keys.unbound == 2, "...and is counted: %lu", h.srv.keys.unbound);
		harness_close(&h);
	}

	// ---------------------------------------------------------------
	section("a viewer and a keyboard at the board, on one keyboard");
	{
		struct harness h;
		struct viewer v;
		harness_open(&h, work, "both", 1);
		h.kbd_w = add_device(&h, USB_KIND_KEYBOARD, "event0");
		h.mouse_w = add_device(&h, USB_KIND_MOUSE, "event1");
		viewer_open(&v, &h.srv);
		h.watching = &v;
		for (unsigned k = 0; k < 40 && v.stage != 4; ++k)
			pump(&h, 1000);
		check(v.stage == 4, "the viewer got through the handshake (stage %d)", v.stage);
		check(h.srv.viewers == 1, "one viewer is watching");

		// Both sources type, and the machine has ONE keyboard.
		viewer_key(&v, 'd', 1);
		viewer_key(&v, 'd', 0);
		settle(&h, 8);
		feed(h.kbd_w, EV_KEY, C_A, 1);
		feed(h.kbd_w, EV_KEY, C_A, 0);
		settle(&h, 8);
		check(h.m.gots == 4, "four words for two keystrokes, not %u", h.m.gots);
		check(saw(&h.m, 0, P_D, 0) && saw(&h.m, 2, P_A, 0),
		      "the viewer's key and the board's key both reach the machine");

		// The switches, both sources holding one.
		viewer_pointer(&v, 0, 100, 100);
		viewer_pointer(&v, 4, 101, 100);   /* the right button */
		settle(&h, 4);
		check(h.m.buttons == IN_BTN_RIGHT, "the viewer holds the right switch: 0x%x",
		      h.m.buttons);
		feed(h.mouse_w, EV_KEY, BTN_LEFT, 1);
		feed(h.mouse_w, EV_SYN, SYN_REPORT, 0);
		settle(&h, 4);
		check(h.m.buttons == (IN_BTN_LEFT | IN_BTN_RIGHT),
		      "**AND THE TWO ARE ORED**, not one over the other: 0x%x", h.m.buttons);

		// **THE ONE THIS SECTION EXISTS FOR.**  A viewer closing its
		// window must not lift the Shift under a finger at the board.
		feed(h.kbd_w, EV_KEY, C_LCTRL, 1);
		settle(&h, 6);
		const unsigned before = h.m.gots;
		check(saw(&h.m, before - 1, P_CONTROL_L, 0), "Control is held at the board");
		viewer_gone(&v);
		h.watching = NULL;
		settle(&h, 10);
		check(h.srv.viewers == 0, "the viewer is gone");
		check(h.m.gots == before,
		      "**AND THE BOARD'S Control IS STILL DOWN**: %u words since, wanting none",
		      h.m.gots - before);
		if (h.m.gots != before)
			dump(&h.m, before);
		harness_close(&h);
	}
	{
		// ...and with nothing at the link, a viewer leaving still
		// releases what IT was holding, which is the behaviour that
		// was there before and must not have been lost.
		struct harness h;
		struct viewer v;
		harness_open(&h, work, "viewer-only", 1);
		cadr_input_link_shut(&h.client);
		for (unsigned k = 0; k < 8; ++k)
			pump(&h, 1000);
		check(cadr_input_link_clients(&h.srv.link) == 0, "nothing is at the link");
		viewer_open(&v, &h.srv);
		h.watching = &v;
		for (unsigned k = 0; k < 40 && v.stage != 4; ++k)
			pump(&h, 1000);
		viewer_key(&v, 0xFFE3u, 1);   /* Control_L, and never released */
		settle(&h, 6);
		check(h.m.gots == 1 && saw(&h.m, 0, P_CONTROL_L, 0),
		      "the viewer holds Control");
		viewer_gone(&v);
		h.watching = NULL;
		settle(&h, 10);
		check(h.m.gots == 2 && saw(&h.m, 1, P_CONTROL_L, 1),
		      "and the last viewer leaving releases it: %u words", h.m.gots);
		h.kbd_w = h.mouse_w = -1;
		harness_close(&h);
	}

	// ---------------------------------------------------------------
	section("Ctrl-Alt-Del at the board boots the machine");
	{
		// **THE WHOLE ROAD, AND IT IS THE TERMINAL'S FIRMWARE AT THE
		// FAR END OF IT.**  `sys/io1/ukbd.lisp`'s `check-boot` lives in
		// `cadr-terminal`'s keyboard, because that is where the one
		// keyboard model is; this section is what says a key pressed
		// at the board's own USB port arrives there as a HELD key and
		// completes the sequence.  A scan code that became the wrong
		// keysym, or a key this program sent as a tap, would type
		// perfectly well and never boot anything.
		//
		// The word is written out rather than built: bits 15-10 ones,
		// 9-6 zero, and 0o46 in the low six for a cold boot, over the
		// frame every word carries.  `docs/terminal.md` has the rest.
		struct harness h;
		harness_open(&h, work, "boot", 1);
		h.kbd_w = add_device(&h, USB_KIND_KEYBOARD, "event0");
		h.mouse_w = -1;
		feed(h.kbd_w, EV_KEY, C_LCTRL, 1);
		feed(h.kbd_w, EV_KEY, C_LALT, 1);
		feed(h.kbd_w, EV_KEY, C_DELETE, 1);
		settle(&h, 12);
		check(h.m.gots == 4, "three keys held and the boot word is four words, not %u",
		      h.m.gots);
		check(saw(&h.m, 0, P_CONTROL_L, 0) && saw(&h.m, 1, P_META_L, 0)
		      && saw(&h.m, 2, P_RUBOUT, 0),
		      "Control, Meta and Rubout go down at their own positions");
		check(h.m.gots > 3 && h.m.got[3] == 0xF9FC26u,
		      "the cold boot word goes after Rubout's own: 0x%06x, wanting 0xf9fc26",
		      h.m.gots > 3 ? h.m.got[3] : 0u);
		if (h.m.gots != 4)
			dump(&h.m, 0);

		// ...and no key-up goes until the next key-down, which is the
		// firmware's `bootflag` reaching this far: the machine has to
		// read the word before anything lands on top of it.
		const unsigned after_boot = h.m.gots;
		feed(h.kbd_w, EV_KEY, C_DELETE, 0);
		feed(h.kbd_w, EV_KEY, C_LALT, 0);
		feed(h.kbd_w, EV_KEY, C_LCTRL, 0);
		settle(&h, 12);
		check(h.m.gots == after_boot,
		      "**AND THE THREE KEY-UPS ARE HELD BACK**: %u words since, wanting none",
		      h.m.gots - after_boot);
		if (h.m.gots != after_boot)
			dump(&h.m, after_boot);
		harness_close(&h);
	}

	// ---------------------------------------------------------------
	section("the scan for devices that came or went");
	{
		char dir[160];
		snprintf(dir, sizeof dir, "%s/nodes-%u", work, (unsigned)getpid());
		mkdir(dir, 0755);
		const char *made[] = { "event10", "event2", "event0", "mice", "by-id" };
		for (unsigned k = 0; k < 5; ++k) {
			char p[256];
			snprintf(p, sizeof p, "%s/%s", dir, made[k]);
			FILE *f = fopen(p, "w");
			if (f)
				fclose(f);
		}
		char names[8][USB_NAME_MAX];
		const unsigned n = usb_scan_names(dir, names, 8);
		check(n == 3, "three of the five names are event*, not %u", n);
		check(n == 3 && strcmp(names[0], "event0") == 0
		      && strcmp(names[1], "event10") == 0 && strcmp(names[2], "event2") == 0,
		      "...and they come out sorted, so a board opens them in one order at "
		      "every boot");
		for (unsigned k = 0; k < 5; ++k) {
			char p[256];
			snprintf(p, sizeof p, "%s/%s", dir, made[k]);
			unlink(p);
		}
		rmdir(dir);
		check(usb_scan_names("/nowhere-at-all", names, 8) == 0,
		      "a directory that is not there is no devices and not a crash");
	}

	// ---------------------------------------------------------------
	section("a server with no face refuses the link");
	{
		struct screen_server srv;
		if (screen_server_bind(&srv, "127.0.0.1", 0) == 0) {
			char path[160];
			const char *home = getenv("HOME");
			snprintf(path, sizeof path, "%s/.cache/usbt-%u-none",
				 home && *home ? home : work, (unsigned)getpid());
			// **A LINK WITH NOWHERE TO PUT A KEY MUST NOT EXIST**:
			// a socket that took keystrokes and dropped them would
			// look exactly like one that worked.
			check(screen_server_link(&srv, path) < 0,
			      "a read-only server does not listen for a source");
			unlink(path);
			screen_server_close(&srv);
		}
	}

	printf("usb_test: %u checks, %u failures\n", checks, failures);
	if (quiet)
		fclose(quiet);
	return failures ? 1 : 0;
}
