// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The screen program, held on the build host to a viewer of this file's own:
// no board, no fabric, nothing but a C compiler and a loopback socket.
//
//     screen_test [--screens DIR]
//
// **WHAT DRIVES IT.**  `screen_server.c` never reads DDR --- it is handed a
// `struct screen_frame` --- so the check builds screens in memory, hands them
// over exactly as `cadr-terminal.c` hands over what it read out of the window,
// and connects a viewer written here over a real TCP socket on the loopback
// address.  Both ends are in this process, so the check pumps them by hand:
// `pump` calls `screen_server_poll` and then reads whatever has arrived.
//
// **THE GEOMETRY IS ANCHORED ON HAND-COMPUTED PIXELS, NOT ON A ROUND TRIP.**
// The whole-screen checks build a buffer with muir's rule and compare what
// the viewer receives against what the rule says should be there --- and if
// the rule were written wrong in BOTH the builder here and the reader under
// test, they would agree with each other and the check would pass a mirrored
// screen.  So the mapping is pinned first, on single bits, at coordinates
// worked out by hand from muir `src/tv.rs:554-557` and written as
// literals: word 0 bit 0 is the top-left pixel, word 0 bit 31 is pixel 31 of
// line 0, word 1 bit 0 is pixel 32, word 23 bit 31 is the last pixel of line
// 0, word 24 bit 0 is the first of line 1, and word 23,111 bit 31 is the
// bottom-right.  A reversed bit order, a stride of 23 or 25 words and a
// screen served upside down each move at least one of those, and no
// arrangement of a reader and a writer that are wrong together can put them
// all back.
//
// **THE REAL SCREENS.**  `--screens DIR` names a directory holding two
// pictures muir drew of MIT's System 100 band --- `screen-rtl-200000000.png`
// and `screen-rtl-225000000.png`, 25 million microcycles apart, white text on
// black with mode 0, differing only in the blinking cursor.  They are muir's
// own PNG (`Tv::png`), which is the monitor's picture and not the frame
// buffer, so the check turns each back into frame-buffer words with the rule
// above, serves it, and compares the viewer's pixels against the PNG's.  The
// pair is a REAL incremental update: one changed rectangle of an ordinary
// screen, which is the case a synthetic pattern cannot supply.  They live in
// vendor/, gitignored, and the check says so and goes on without them.
//
// **NOTHING IN THIS FILE CALLS THE PROGRAM'S OWN PIXEL CODE.**  The viewer
// decodes a pixel by comparing it against the two byte patterns it works out
// for itself from the format it asked for, and lays RRE's subrectangles out
// itself; otherwise a mutation of `rfb_put` or of the RRE encoder would be
// answered by the same mistake in the check and cancel.
//
// **WHAT IS CHECKED.**  The mapping, on the eight anchors and in both
// directions of `MODE BOW`.  A whole screen, pixel for pixel, in five pixel
// formats --- 32, 16 and 8 bits, both byte orders, and a color-mapped one
// whose `SetColourMapEntries` must arrive.  An incremental update after part
// of the buffer changes: the rows sent are the rows that changed, the
// viewer's canvas comes out equal to the whole screen, and a viewer whose
// screen has not changed is left waiting.  The frame re-read from the window
// each pass, so that a stale copy is visible.  A viewer that offers only
// encodings this server has not got, which must still be served, in Raw.  RRE
// against Raw on a real screen, and a dithered screen where Raw is the
// smaller and must be the one used.  A viewer that goes in the middle of an
// update, after which the server serves the next one.  RFB 3.3, 3.7 and 3.8;
// a viewer asking for a security type not offered; a message type RFC 6143
// does not give a length for.  The whole-screen interval, held by a clock
// this file owns.  And the blank-screen states.

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cadr/cadr_log.h>

#include "input_face.h"
#include "input_keys.h"
#include "input_mapping.h"
#include "screen_frame.h"
#include <cadr/cadr_endpoint.h>

#include "screen_geom.h"

// The port cadr-terminal defaults to, repeated here rather than included from
// the program: this holds the grammar against a default and does not care
// which number it is, and a shared constant would let both move together and
// say nothing.
#define TERM_TEST_PORT 5900
#include "screen_rfb.h"
#include "screen_server.h"

static int bad;
static unsigned checks;

static void fail(int line, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void fail(int line, const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stderr, "screen_test.c:%d: FAIL: ", line);
	vfprintf(stderr, fmt, ap);
	fputc('\n', stderr);
	va_end(ap);
	++bad;
	if (bad > 30) {
		fprintf(stderr, "FAIL: too many; stopping\n");
		exit(1);
	}
}

#define CHECK(cond, ...)                             \
	do {                                         \
		++checks;                            \
		if (!(cond))                         \
			fail(__LINE__, __VA_ARGS__); \
	} while (0)

// ---- the clock ----------------------------------------------------------
//
// The whole-screen interval is a property of the server and is checked, so
// the clock it reads is this file's and not the machine's.

// The clock does not run while an update drains: a viewer that has not
// finished its handshake is dropped after thirty seconds, and a clock that
// ran a frame per pump would age one past that in a few hundred passes.  It
// moves only where a frame is meant to have passed --- which is what the
// whole-screen interval is measured in, so `check_full_update_interval` freezes
// it and moves it itself.
static uint64_t clock_ns = 1000000000u;
static int clock_frozen;

static void tick(void)
{
	if (!clock_frozen)
		clock_ns += SCREEN_FULL_UPDATE_NS;
}

// Polls until nobody is watching, so that a check counting drops is not
// counting the last check's viewer.
static void settle(void);

// ---- the screen, built by muir's rule -----------------------------------
//
// muir src/tv.rs:554-557 and :607-609, written out here rather than
// called, for the reason in the header.

static void screen_clear(uint32_t *w)
{
	memset(w, 0, SCREEN_VISIBLE_WORDS * sizeof *w);
}

static void screen_set_white(uint32_t *w, unsigned x, unsigned y, int white, int bow)
{
	const unsigned bit = y * SCREEN_WORDS_PER_LINE * 32u + x;
	const int lit = white != (bow != 0);
	if (lit)
		w[bit / 32u] |= 1u << (bit % 32u);
	else
		w[bit / 32u] &= ~(1u << (bit % 32u));
}

// ---- a viewer of this file's own ----------------------------------------

struct screen_server srv;
static struct screen_frame frame;

// What the viewer believes is on the screen, one byte a pixel: 1 white, 0
// black, 0xFF never painted.
static uint8_t canvas[SCREEN_HEIGHT][SCREEN_WIDTH];

struct client {
	int fd;
	uint8_t *in;
	size_t len, cap;
	struct rfb_format format;
	unsigned n;			/* bytes a pixel */
	uint8_t white[4], black[4];
	int got_colour_map;
	unsigned long rects_raw, rects_rre, subrects;
	unsigned long long bytes;
};

// `rfb_put` and `rfb_white` written again, so that a mutation of theirs does
// not cancel here.  RFC 6143 section 7.4.
static void test_pixel_bytes(const struct rfb_format *f, uint32_t value, uint8_t *out)
{
	const unsigned n = f->bits_per_pixel / 8u;
	for (unsigned k = 0; k < n; ++k) {
		const unsigned shift = f->big_endian ? 8 * (n - 1 - k) : 8 * k;
		out[k] = (uint8_t)(value >> shift);
	}
}

static void client_format(struct client *c, const struct rfb_format *f)
{
	c->format = *f;
	c->n = f->bits_per_pixel / 8u;
	uint32_t white = RFB_WHITE_INDEX;
	if (f->true_colour)
		white = (uint32_t)f->red_max << f->red_shift
		      | (uint32_t)f->green_max << f->green_shift
		      | (uint32_t)f->blue_max << f->blue_shift;
	test_pixel_bytes(f, white, c->white);
	test_pixel_bytes(f, 0, c->black);
}

static int client_open(struct client *c, unsigned port)
{
	memset(c, 0, sizeof *c);
	c->fd = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons((uint16_t)port);
	a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (connect(c->fd, (struct sockaddr *)&a, sizeof a) < 0) {
		fprintf(stderr, "connect: %s\n", strerror(errno));
		return -1;
	}
	const int fl = fcntl(c->fd, F_GETFL, 0);
	fcntl(c->fd, F_SETFL, fl | O_NONBLOCK);
	// Nagle holds a small message until the last one is acknowledged, so a
	// check that writes eight bytes and polls a few hundred times would see
	// only the first of them.  A real viewer sets this for the same reason.
	const int one = 1;
	setsockopt(c->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
	c->cap = 1 << 20;
	c->in = malloc(c->cap);
	client_format(c, &RFB_RGB888);
	return 0;
}

static void client_close(struct client *c)
{
	if (c->fd >= 0)
		close(c->fd);
	c->fd = -1;
	free(c->in);
	c->in = NULL;
}

static void client_send(struct client *c, const void *p, size_t n)
{
	const uint8_t *b = p;
	size_t at = 0;
	for (int spin = 0; at < n && spin < 10000; ++spin) {
		const ssize_t put = write(c->fd, b + at, n - at);
		if (put > 0)
			at += (size_t)put;
		else if (put < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)
			break;
		screen_server_poll(&srv, &frame, 1, clock_ns);
	}
}

// Pumps both ends until the viewer holds `n` bytes.  0 if it does.
static int client_need(struct client *c, size_t n)
{
	for (int spin = 0; spin < 200000; ++spin) {
		if (c->len >= n)
			return 0;
		if (c->len + 65536 > c->cap) {
			c->cap *= 2;
			c->in = realloc(c->in, c->cap);
		}
		const ssize_t got = read(c->fd, c->in + c->len, c->cap - c->len);
		if (got > 0) {
			c->len += (size_t)got;
			continue;
		}
		if (got == 0)
			return -1;
		screen_server_poll(&srv, &frame, 0, clock_ns);
	}
	return -1;
}

static void client_take(struct client *c, size_t n)
{
	memmove(c->in, c->in + n, c->len - n);
	c->len -= n;
}

static uint16_t be16at(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint32_t be32at(const uint8_t *p)
{
	return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}

// The opening exchange, RFC 6143 section 7.1, from the viewer's side.
static int client_handshake(struct client *c, const char *version)
{
	if (client_need(c, 12) < 0)
		return -1;
	if (memcmp(c->in, "RFB 003.008\n", 12) != 0) {
		fail(__LINE__, "the server offered %.11s, not RFB 003.008", (const char *)c->in);
		return -1;
	}
	client_take(c, 12);
	client_send(c, version, 12);
	const int v33 = memcmp(version, "RFB 003.007\n", 12) != 0
		     && memcmp(version, "RFB 003.008\n", 12) != 0;
	if (v33) {
		if (client_need(c, 4) < 0)
			return -1;
		CHECK(be32at(c->in) == 1, "3.3: the server named security type %u, wanting 1",
		      be32at(c->in));
		client_take(c, 4);
	} else {
		if (client_need(c, 2) < 0)
			return -1;
		CHECK(c->in[0] == 1 && c->in[1] == 1,
		      "the server offered %u types, the first %u; wanting one, None",
		      c->in[0], c->in[1]);
		client_take(c, 2);
		const uint8_t pick = 1;
		client_send(c, &pick, 1);
		if (memcmp(version, "RFB 003.008\n", 12) == 0) {
			if (client_need(c, 4) < 0)
				return -1;
			CHECK(be32at(c->in) == 0, "3.8: SecurityResult was %u, wanting 0",
			      be32at(c->in));
			client_take(c, 4);
		}
	}
	const uint8_t shared = 1;
	client_send(c, &shared, 1);		/* ClientInit */
	if (client_need(c, 24) < 0)
		return -1;
	const unsigned w = be16at(c->in), h = be16at(c->in + 2);
	CHECK(w == SCREEN_WIDTH && h == SCREEN_HEIGHT,
	      "ServerInit says %ux%u, wanting %ux%u", w, h, SCREEN_WIDTH, SCREEN_HEIGHT);
	const uint32_t namelen = be32at(c->in + 20);
	if (client_need(c, 24 + namelen) < 0)
		return -1;
	client_take(c, 24 + namelen);
	return 0;
}

static void client_set_format(struct client *c, const struct rfb_format *f)
{
	uint8_t m[20];
	memset(m, 0, sizeof m);
	m[0] = 0;
	rfb_format_encode(f, m + 4);
	client_send(c, m, sizeof m);
	client_format(c, f);
	if (!f->true_colour) {
		// SetColourMapEntries, section 7.6.2: two colors from 0.
		if (client_need(c, 18) == 0 && c->in[0] == 1) {
			CHECK(be16at(c->in + 2) == 0 && be16at(c->in + 4) == 2,
			      "the color map named %u colors from %u, wanting 2 from 0",
			      be16at(c->in + 4), be16at(c->in + 2));
			CHECK(be16at(c->in + 12) == 0xFFFF,
			      "color map entry 1 is not white");
			c->got_colour_map = 1;
			client_take(c, 18);
		}
	}
}

static void client_set_encodings(struct client *c, const int32_t *list, unsigned n)
{
	uint8_t m[4 + 4 * 16];
	m[0] = 2;
	m[1] = 0;
	m[2] = (uint8_t)(n >> 8);
	m[3] = (uint8_t)n;
	for (unsigned k = 0; k < n; ++k) {
		const uint32_t e = (uint32_t)list[k];
		m[4 + 4 * k + 0] = (uint8_t)(e >> 24);
		m[4 + 4 * k + 1] = (uint8_t)(e >> 16);
		m[4 + 4 * k + 2] = (uint8_t)(e >> 8);
		m[4 + 4 * k + 3] = (uint8_t)e;
	}
	client_send(c, m, 4 + 4 * (size_t)n);
}

static void client_request(struct client *c, int incremental, unsigned x, unsigned y,
			   unsigned w, unsigned h)
{
	uint8_t m[10];
	m[0] = 3;
	m[1] = (uint8_t)(incremental != 0);
	m[2] = (uint8_t)(x >> 8); m[3] = (uint8_t)x;
	m[4] = (uint8_t)(y >> 8); m[5] = (uint8_t)y;
	m[6] = (uint8_t)(w >> 8); m[7] = (uint8_t)w;
	m[8] = (uint8_t)(h >> 8); m[9] = (uint8_t)h;
	client_send(c, m, sizeof m);
}

// One pixel out of the viewer's bytes: 1 white, 0 black, -1 neither, which is
// a failure in itself.
static int client_pixel(struct client *c, const uint8_t *p)
{
	if (memcmp(p, c->white, c->n) == 0)
		return 1;
	if (memcmp(p, c->black, c->n) == 0)
		return 0;
	return -1;
}

// Where the last update's rectangles were, so that the rows sent can be held
// to the rows that changed.
static unsigned last_y[SCREEN_HEIGHT], last_h[SCREEN_HEIGHT], last_rects;

// Takes one `FramebufferUpdate` and paints it onto the canvas.  Returns the
// number of rectangles, or -1.  `encodings` is filled with the encoding of
// each rectangle, up to `max`.
static int client_update(struct client *c, int32_t *encodings, unsigned max)
{
	if (client_need(c, 4) < 0)
		return -1;
	if (c->in[0] != 0) {
		fail(__LINE__, "the server sent message type %u where an update was due", c->in[0]);
		return -1;
	}
	const unsigned rects = be16at(c->in + 2);
	client_take(c, 4);
	for (unsigned r = 0; r < rects; ++r) {
		if (client_need(c, 12) < 0)
			return -1;
		const unsigned x = be16at(c->in), y = be16at(c->in + 2);
		const unsigned w = be16at(c->in + 4), h = be16at(c->in + 6);
		const int32_t enc = (int32_t)be32at(c->in + 8);
		client_take(c, 12);
		if (r < max)
			encodings[r] = enc;
		if (r < SCREEN_HEIGHT) {
			last_y[r] = y;
			last_h[r] = h;
			last_rects = r + 1;
		}
		if (x + w > SCREEN_WIDTH || y + h > SCREEN_HEIGHT) {
			fail(__LINE__, "a rectangle at %u,%u of %ux%u leaves the screen", x, y, w, h);
			return -1;
		}
		if (enc == RFB_ENCODING_RAW) {
			const size_t n = (size_t)w * h * c->n;
			if (client_need(c, n) < 0)
				return -1;
			++c->rects_raw;
			c->bytes += n;
			for (unsigned dy = 0; dy < h; ++dy)
				for (unsigned dx = 0; dx < w; ++dx) {
					const int v = client_pixel(c, c->in + ((size_t)dy * w + dx) * c->n);
					if (v < 0) {
						fail(__LINE__, "a pixel at %u,%u is neither black nor white",
						     x + dx, y + dy);
						return -1;
					}
					canvas[y + dy][x + dx] = (uint8_t)v;
				}
			client_take(c, n);
		} else if (enc == RFB_ENCODING_RRE) {
			// Section 7.7.2: a count, a background pixel, then that
			// many subrectangles of pixel, x, y, w, h.
			if (client_need(c, 4 + c->n) < 0)
				return -1;
			const uint32_t count = be32at(c->in);
			const int background = client_pixel(c, c->in + 4);
			if (background < 0) {
				fail(__LINE__, "the RRE background is neither black nor white");
				return -1;
			}
			client_take(c, 4 + c->n);
			for (unsigned dy = 0; dy < h; ++dy)
				for (unsigned dx = 0; dx < w; ++dx)
					canvas[y + dy][x + dx] = (uint8_t)background;
			const size_t each = c->n + 8;
			if (client_need(c, each * count) < 0)
				return -1;
			++c->rects_rre;
			c->subrects += count;
			c->bytes += 4 + c->n + each * count;
			for (uint32_t k = 0; k < count; ++k) {
				const uint8_t *p = c->in + each * k;
				const int v = client_pixel(c, p);
				const unsigned sx = be16at(p + c->n), sy = be16at(p + c->n + 2);
				const unsigned sw = be16at(p + c->n + 4), sh = be16at(p + c->n + 6);
				if (v < 0) {
					fail(__LINE__, "an RRE subrectangle's pixel is neither color");
					return -1;
				}
				if (sx + sw > w || sy + sh > h) {
					fail(__LINE__,
					     "an RRE subrectangle at %u,%u of %ux%u leaves its %ux%u rectangle",
					     sx, sy, sw, sh, w, h);
					return -1;
				}
				for (unsigned q = 0; q < sh; ++q)
					for (unsigned p2 = 0; p2 < sw; ++p2)
						canvas[y + sy + q][x + sx + p2] = (uint8_t)v;
			}
			client_take(c, each * count);
		} else {
			fail(__LINE__, "the server used encoding %d, which it does not offer", enc);
			return -1;
		}
	}
	return (int)rects;
}

static void settle(void)
{
	for (int k = 0; k < 4000 && srv.viewers; ++k)
		screen_server_poll(&srv, &frame, 0, clock_ns);
}

// ---- what the screen should look like -----------------------------------

static uint8_t want[SCREEN_HEIGHT][SCREEN_WIDTH];

static void want_from(const uint32_t *words, int bow)
{
	for (unsigned y = 0; y < SCREEN_HEIGHT; ++y)
		for (unsigned x = 0; x < SCREEN_WIDTH; ++x) {
			const unsigned bit = y * SCREEN_WORDS_PER_LINE * 32u + x;
			const int lit = (words[bit / 32u] >> (bit % 32u)) & 1u;
			want[y][x] = (uint8_t)(lit != (bow != 0));
		}
}

// Every pixel of the canvas against `want`; says the first few that differ.
static unsigned canvas_differs(const char *what)
{
	unsigned differ = 0;
	for (unsigned y = 0; y < SCREEN_HEIGHT; ++y)
		for (unsigned x = 0; x < SCREEN_WIDTH; ++x)
			if (canvas[y][x] != want[y][x]) {
				if (differ < 4)
					fail(__LINE__, "%s: pixel %u,%u came back %s, wanting %s",
					     what, x, y, canvas[y][x] == 1 ? "white" :
					     canvas[y][x] == 0 ? "black" : "unpainted",
					     want[y][x] ? "white" : "black");
				++differ;
			}
	++checks;
	if (differ)
		fail(__LINE__, "%s: %u of %u pixels differ", what, differ,
		     SCREEN_WIDTH * SCREEN_HEIGHT);
	return differ;
}

// ---- muir's PNG ---------------------------------------------------------
//
// `Tv::png` (muir src/tv.rs:616) writes 1-bit grayscale, filter
// none on every row, and STORED deflate blocks --- "the encoder is here
// rather than a crate: a 1-bit grayscale PNG is a header, the rows behind
// stored deflate blocks, and two checksums."  So this reads exactly that and
// refuses anything else loudly rather than pulling in zlib for a file whose
// shape is known.  A PNG row is packed MSB first, left to right, which is
// PNG's own rule (RFC 2083 section 2.3) and has nothing to do with the CADR's
// bit order --- which is the point: the picture arrives here in a layout that
// is not the one under test.
static int png_read(const char *path, uint8_t out[SCREEN_HEIGHT][SCREEN_WIDTH])
{
	FILE *f = fopen(path, "rb");
	if (!f)
		return -1;
	fseek(f, 0, SEEK_END);
	const long size = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *b = malloc((size_t)size);
	if (fread(b, 1, (size_t)size, f) != (size_t)size) {
		fclose(f);
		free(b);
		return -1;
	}
	fclose(f);
	static const uint8_t sig[8] = { 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };
	if (size < 8 || memcmp(b, sig, 8) != 0) {
		fail(__LINE__, "%s is not a PNG", path);
		free(b);
		return -1;
	}
	uint8_t *idat = malloc((size_t)size);
	size_t idat_len = 0;
	unsigned width = 0, height = 0;
	size_t at = 8;
	while (at + 8 <= (size_t)size) {
		const uint32_t len = be32at(b + at);
		const char *kind = (const char *)b + at + 4;
		const uint8_t *data = b + at + 8;
		if (memcmp(kind, "IHDR", 4) == 0) {
			width = be32at(data);
			height = be32at(data + 4);
			if (data[8] != 1 || data[9] != 0 || data[12] != 0) {
				fail(__LINE__, "%s is %u-bit color type %u interlace %u, not muir's 1-bit grayscale",
				     path, data[8], data[9], data[12]);
				free(b);
				free(idat);
				return -1;
			}
		} else if (memcmp(kind, "IDAT", 4) == 0) {
			memcpy(idat + idat_len, data, len);
			idat_len += len;
		} else if (memcmp(kind, "IEND", 4) == 0) {
			break;
		}
		at += 12 + len;
	}
	if (width != SCREEN_WIDTH || height != SCREEN_HEIGHT) {
		fail(__LINE__, "%s is %ux%u, not the CADR's %ux%u", path, width, height,
		     SCREEN_WIDTH, SCREEN_HEIGHT);
		free(b);
		free(idat);
		return -1;
	}
	// The zlib stream: two bytes of header, then stored blocks.
	const size_t stride = SCREEN_WIDTH / 8 + 1;
	uint8_t *raw = malloc(stride * SCREEN_HEIGHT);
	size_t raw_len = 0;
	size_t z = 2;
	for (;;) {
		if (z + 5 > idat_len) {
			fail(__LINE__, "%s: the deflate stream ran out", path);
			break;
		}
		const uint8_t head = idat[z];
		if ((head >> 1 & 3) != 0) {
			fail(__LINE__, "%s: a deflate block of type %u; muir writes stored blocks only",
			     path, head >> 1 & 3);
			break;
		}
		const size_t n = (size_t)idat[z + 1] | (size_t)idat[z + 2] << 8;
		if (raw_len + n > stride * SCREEN_HEIGHT || z + 5 + n > idat_len) {
			fail(__LINE__, "%s: a stored block of %zu overruns", path, n);
			break;
		}
		memcpy(raw + raw_len, idat + z + 5, n);
		raw_len += n;
		z += 5 + n;
		if (head & 1)
			break;
	}
	int ok = raw_len == stride * SCREEN_HEIGHT;
	if (!ok)
		fail(__LINE__, "%s: %zu bytes of image, wanting %zu", path, raw_len,
		     stride * SCREEN_HEIGHT);
	for (unsigned y = 0; ok && y < SCREEN_HEIGHT; ++y) {
		if (raw[y * stride] != 0) {
			fail(__LINE__, "%s: row %u has filter %u; muir writes none", path, y,
			     raw[y * stride]);
			ok = 0;
			break;
		}
		for (unsigned x = 0; x < SCREEN_WIDTH; ++x)
			out[y][x] = (uint8_t)((raw[y * stride + 1 + x / 8] >> (7 - x % 8)) & 1u);
	}
	free(raw);
	free(idat);
	free(b);
	return ok ? 0 : -1;
}

// A picture as the monitor shows it, back into frame-buffer words.  muir's
// rule, this file's expression of it.
static void words_from_picture(uint32_t *w, const uint8_t pic[SCREEN_HEIGHT][SCREEN_WIDTH], int bow)
{
	screen_clear(w);
	for (unsigned y = 0; y < SCREEN_HEIGHT; ++y)
		for (unsigned x = 0; x < SCREEN_WIDTH; ++x)
			screen_set_white(w, x, y, pic[y][x], bow);
}

// ---- the checks ---------------------------------------------------------

static unsigned port;

// A viewer through the handshake, its format and encodings set, ready to ask.
static int open_viewer(struct client *c, const char *version, const struct rfb_format *f,
		       const int32_t *encodings, unsigned n_encodings)
{
	if (client_open(c, port) < 0)
		return -1;
	if (client_handshake(c, version) < 0)
		return -1;
	if (f)
		client_set_format(c, f);
	if (encodings)
		client_set_encodings(c, encodings, n_encodings);
	return 0;
}

// The whole screen, once, onto the canvas.
static int whole_screen(struct client *c, int32_t *encodings, unsigned max)
{
	memset(canvas, 0xFF, sizeof canvas);
	tick();
	client_request(c, 0, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
	return client_update(c, encodings, max);
}

// **THE ANCHORS.**  One bit in an empty screen, and the pixel it must light.
// Every coordinate below is worked out by hand from muir src/tv.rs:555,
// `bit = y * WORDS_PER_LINE * 32 + x`, and written as a literal: nothing here
// computes it from the same expression the program uses.
struct anchor { unsigned word, bit, x, y; const char *what; };

static const struct anchor ANCHORS[] = {
	{ 0, 0, 0, 0, "word 0 bit 0 is the top-left pixel" },
	{ 0, 1, 1, 0, "word 0 bit 1 is one pixel to its right" },
	{ 0, 31, 31, 0, "word 0 bit 31 is the rightmost pixel of the first word" },
	{ 1, 0, 32, 0, "word 1 bit 0 is the pixel after it" },
	{ 23, 31, 767, 0, "word 23 bit 31 is the last pixel of line 0" },
	{ 24, 0, 0, 1, "word 24 bit 0 is the first pixel of line 1" },
	{ 24 * 481, 12, 12, 481, "the middle of the screen" },
	{ 24 * 962, 0, 0, 962, "word 23,088 bit 0 is the first pixel of the last line" },
	{ 24 * 962 + 23, 31, 767, 962, "word 23,111 bit 31 is the bottom-right pixel" },
};

static void check_anchors(int bow, int use_rre)
{
	static const int32_t rre_list[] = { RFB_ENCODING_RRE, RFB_ENCODING_RAW };
	static const struct rfb_format eight = {
		.bits_per_pixel = 8, .depth = 8, .big_endian = 0, .true_colour = 1,
		.red_max = 3, .green_max = 3, .blue_max = 3,
		.red_shift = 4, .green_shift = 2, .blue_shift = 0,
	};
	for (unsigned k = 0; k < sizeof ANCHORS / sizeof *ANCHORS; ++k) {
		const struct anchor *a = &ANCHORS[k];
		screen_frame_init(&frame, bow);
		screen_clear(frame.words);
		frame.words[a->word] = 1u << a->bit;
		struct client c;
		if (open_viewer(&c, "RFB 003.008\n", &eight, use_rre ? rre_list : NULL,
				use_rre ? 2 : 0) < 0) {
			fail(__LINE__, "%s: no viewer", a->what);
			return;
		}
		if (whole_screen(&c, NULL, 0) < 0) {
			fail(__LINE__, "%s: no update", a->what);
			client_close(&c);
			return;
		}
		// Exactly one pixel differs from the empty screen, and it is
		// the one named.  With BOW clear a lit bit is white; with BOW
		// set it is black on a white field.
		const uint8_t lit_shows = (uint8_t)(bow ? 0 : 1);
		unsigned wrong = 0, found_x = SCREEN_WIDTH, found_y = SCREEN_HEIGHT;
		for (unsigned y = 0; y < SCREEN_HEIGHT; ++y)
			for (unsigned x = 0; x < SCREEN_WIDTH; ++x)
				if (canvas[y][x] == lit_shows) {
					if (wrong == 0) {
						found_x = x;
						found_y = y;
					}
					++wrong;
				}
		CHECK(wrong == 1 && found_x == a->x && found_y == a->y,
		      "%s (BOW %s, %s): word %u bit %u lit %u pixels, the first at %u,%u; "
		      "wanting exactly one at %u,%u",
		      a->what, bow ? "set" : "clear", use_rre ? "RRE" : "Raw", a->word, a->bit,
		      wrong, found_x, found_y, a->x, a->y);
		client_close(&c);
		screen_server_poll(&srv, &frame, 0, clock_ns);
	}
}

// Pumps without expecting anything, and says how many bytes turned up.
static size_t client_quiet(struct client *c, int spins)
{
	for (int k = 0; k < spins; ++k) {
		screen_server_poll(&srv, &frame, 1, clock_ns);
		const ssize_t got = read(c->fd, c->in + c->len, c->cap - c->len);
		if (got > 0)
			c->len += (size_t)got;
	}
	return c->len;
}

// The window Linux would map: the check writes it and `screen_frame_read`
// copies out of it, so a frame served from a stale copy is visible here.
static uint32_t window[SCREEN_WINDOW_WORDS];

static void check_whole_screen(const uint8_t pic[SCREEN_HEIGHT][SCREEN_WIDTH], int bow,
			       const char *what)
{
	static const struct rfb_format formats[] = {
		{ 32, 24, 0, 1, 255, 255, 255, 16, 8, 0 },	/* the offered one */
		{ 32, 24, 1, 1, 255, 255, 255, 0, 8, 16 },	/* big-endian, shifts moved */
		{ 16, 16, 0, 1, 31, 63, 31, 11, 5, 0 },		/* 5-6-5 */
		{ 8, 8, 0, 1, 3, 3, 3, 4, 2, 0 },		/* 2-2-2 */
		{ 8, 8, 0, 0, 0, 0, 0, 0, 0, 0 },		/* a color map */
	};
	static const char *names[] = { "32bpp little", "32bpp big", "16bpp 5-6-5", "8bpp 2-2-2",
				       "8bpp color-mapped" };
	words_from_picture(window, pic, bow);
	screen_frame_init(&frame, bow);
	screen_frame_read(&frame, window);
	want_from(frame.words, bow);
	for (unsigned k = 0; k < sizeof formats / sizeof *formats; ++k) {
		struct client c;
		if (open_viewer(&c, "RFB 003.008\n", &formats[k], NULL, 0) < 0) {
			fail(__LINE__, "%s in %s: no viewer", what, names[k]);
			return;
		}
		if (!formats[k].true_colour)
			CHECK(c.got_colour_map, "%s: a mapped format got no SetColourMapEntries",
			      names[k]);
		int32_t enc[8];
		const int rects = whole_screen(&c, enc, 8);
		CHECK(rects == 1, "%s in %s: %d rectangles for a whole screen, wanting 1", what,
		      names[k], rects);
		if (rects >= 1)
			CHECK(enc[0] == RFB_ENCODING_RAW,
			      "%s in %s: a viewer that named no encodings was sent %d, wanting Raw",
			      what, names[k], enc[0]);
		canvas_differs(names[k]);
		client_close(&c);
	}
}

// The rows that differ between two screens, computed here so that the rows
// the server sends can be held to them.
static unsigned changed_here(const uint32_t *a, const uint32_t *b, unsigned *y, unsigned *h)
{
	unsigned n = 0;
	for (unsigned row = 0; row < SCREEN_HEIGHT; ++row) {
		const unsigned at = row * SCREEN_WORDS_PER_LINE;
		if (memcmp(a + at, b + at, SCREEN_WORDS_PER_LINE * sizeof *a) == 0)
			continue;
		if (n && y[n - 1] + h[n - 1] == row) {
			++h[n - 1];
			continue;
		}
		y[n] = row;
		h[n] = 1;
		++n;
	}
	return n;
}

static void check_incremental(const uint8_t before[SCREEN_HEIGHT][SCREEN_WIDTH],
			      const uint8_t after[SCREEN_HEIGHT][SCREEN_WIDTH],
			      const char *what)
{
	static const int32_t rre_only[] = { RFB_ENCODING_RRE, RFB_ENCODING_RAW };
	static uint32_t was[SCREEN_VISIBLE_WORDS];
	words_from_picture(window, before, 0);
	screen_frame_init(&frame, 0);
	screen_frame_read(&frame, window);
	memcpy(was, frame.words, sizeof was);

	struct client c;
	if (open_viewer(&c, "RFB 003.008\n", NULL, rre_only, 2) < 0) {
		fail(__LINE__, "%s: no viewer", what);
		return;
	}
	want_from(frame.words, 0);
	int32_t enc[SCREEN_HEIGHT];
	if (whole_screen(&c, enc, SCREEN_HEIGHT) < 0) {
		client_close(&c);
		return;
	}
	CHECK(canvas_differs("the first screen") == 0, "%s: the first screen", what);

	// Nothing has changed: RFC 6143 leaves the request outstanding.
	client_request(&c, 1, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
	CHECK(client_quiet(&c, 200) == 0,
	      "%s: an incremental request answered with %zu bytes when nothing had changed",
	      what, c.len);

	// Now the machine draws.  The words go into the WINDOW, and the frame
	// is read again: a program that kept its first copy serves the old
	// screen and this is where that shows.
	words_from_picture(window, after, 0);
	screen_frame_read(&frame, window);
	want_from(frame.words, 0);
	unsigned wy[SCREEN_HEIGHT], wh[SCREEN_HEIGHT];
	const unsigned runs = changed_here(was, frame.words, wy, wh);
	CHECK(runs > 0, "%s: the two screens do not differ, so there is nothing to check", what);

	const int rects = client_update(&c, enc, SCREEN_HEIGHT);
	CHECK(rects == (int)runs, "%s: %d rectangles for %u runs of changed rows", what, rects,
	      runs);
	for (unsigned k = 0; k < runs && k < (unsigned)(rects > 0 ? rects : 0); ++k)
		CHECK(last_y[k] == wy[k] && last_h[k] == wh[k],
		      "%s: rectangle %u is rows %u..%u, wanting %u..%u", what, k, last_y[k],
		      last_y[k] + last_h[k] - 1, wy[k], wy[k] + wh[k] - 1);
	CHECK(canvas_differs("after the change") == 0, "%s: the screen after the change", what);
	client_close(&c);
}

// A viewer that offers only encodings this server has not got must still be
// served, and in Raw: RFC 6143 section 7.7.1 obliges every server to have it
// and every viewer to take it, so it is the floor under the negotiation and
// not something a viewer has to ask for.
static void check_unoffered_encodings(void)
{
	static const int32_t nothing_we_have[] = { 1, 5, 16, 21, -239, -223 };
	words_from_picture(window, want, 0);	/* whatever is in `want` will do */
	screen_frame_init(&frame, 0);
	screen_frame_read(&frame, window);
	want_from(frame.words, 0);
	struct client c;
	if (open_viewer(&c, "RFB 003.008\n", NULL, nothing_we_have, 6) < 0) {
		fail(__LINE__, "unoffered encodings: no viewer");
		return;
	}
	int32_t enc[8];
	const int rects = whole_screen(&c, enc, 8);
	CHECK(rects >= 1, "a viewer offering CopyRect, Hextile, ZRLE and two pseudo-encodings got %d rectangles",
	      rects);
	if (rects >= 1)
		CHECK(enc[0] == RFB_ENCODING_RAW,
		      "a viewer that offers no encoding this server has was sent %d, wanting Raw (0)",
		      enc[0]);
	canvas_differs("a viewer offering only encodings we have not got");
	client_close(&c);
}

// RRE against Raw, measured on whatever screen is handed in, and the rule
// that decides between them: the smaller, per rectangle.
static void check_rre(const uint8_t pic[SCREEN_HEIGHT][SCREEN_WIDTH], const char *what,
		      int expect_rre)
{
	static const int32_t with_rre[] = { RFB_ENCODING_RRE, RFB_ENCODING_RAW };
	words_from_picture(window, pic, 0);
	screen_frame_init(&frame, 0);
	screen_frame_read(&frame, window);
	want_from(frame.words, 0);

	struct client raw_v, rre_v;
	if (open_viewer(&raw_v, "RFB 003.008\n", NULL, NULL, 0) < 0)
		return;
	int32_t enc[8];
	whole_screen(&raw_v, enc, 8);
	CHECK(canvas_differs("Raw") == 0, "%s: Raw", what);
	const unsigned long long raw_bytes = raw_v.bytes;
	client_close(&raw_v);

	const unsigned long long declined_before = srv.declined_rre;
	if (open_viewer(&rre_v, "RFB 003.008\n", NULL, with_rre, 2) < 0)
		return;
	const int rects = whole_screen(&rre_v, enc, 8);
	CHECK(rects == 1, "%s: %d rectangles", what, rects);
	if (rects >= 1)
		CHECK((enc[0] == RFB_ENCODING_RRE) == (expect_rre != 0),
		      "%s: the whole screen went in encoding %d; %s was the smaller",
		      what, enc[0], expect_rre ? "RRE" : "Raw");
	CHECK(canvas_differs(expect_rre ? "RRE" : "Raw, RRE having lost") == 0, "%s: the pixels",
	      what);
	// What RRE cost, whether or not it was the one sent: a decision made by
	// measuring is only reported by giving both numbers.
	const unsigned long long rre_bytes = expect_rre ? rre_v.bytes
						       : srv.declined_rre - declined_before;
	printf("    %-34s Raw %9llu   RRE %9llu   %s\n", what, raw_bytes, rre_bytes,
	       expect_rre ? "RRE is the one sent" : "Raw is the one sent, RRE having lost");
	client_close(&rre_v);
}

// A viewer that goes in the middle of an update: the server drops it, says
// so, and serves the next one.
static void check_disconnect_mid_frame(const uint8_t pic[SCREEN_HEIGHT][SCREEN_WIDTH])
{
	settle();
	words_from_picture(window, pic, 0);
	screen_frame_init(&frame, 0);
	screen_frame_read(&frame, window);
	want_from(frame.words, 0);
	const unsigned long before = srv.drops;
	struct client c;
	if (open_viewer(&c, "RFB 003.008\n", NULL, NULL, 0) < 0)
		return;
	// A whole screen in 32 bits a pixel is 2,958,336 bytes; take a few of
	// them and go.
	client_request(&c, 0, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
	client_need(&c, 4096);
	close(c.fd);
	c.fd = -1;
	client_close(&c);
	for (int k = 0; k < 200; ++k)
		screen_server_poll(&srv, &frame, 1, clock_ns);
	CHECK(srv.drops == before + 1, "a viewer that went mid-update left %lu drops, wanting %lu",
	      srv.drops, before + 1);
	CHECK(srv.viewers == 0, "%u viewers still on the books after the one that went",
	      srv.viewers);
	// And the next viewer is served in full.
	struct client next;
	if (open_viewer(&next, "RFB 003.008\n", NULL, NULL, 0) < 0) {
		fail(__LINE__, "no viewer after the one that went");
		return;
	}
	whole_screen(&next, NULL, 0);
	CHECK(canvas_differs("the viewer after the one that went") == 0,
	      "the screen served after a viewer went mid-update");
	client_close(&next);
}

// RFC 6143's opening exchange in its three versions, and the two ways a
// viewer can be refused.
static void check_handshakes(void)
{
	static const char *versions[] = { "RFB 003.003\n", "RFB 003.007\n", "RFB 003.008\n",
					  "RFB 003.889\n" };
	for (unsigned k = 0; k < 4; ++k) {
		struct client c;
		if (open_viewer(&c, versions[k], NULL, NULL, 0) < 0) {
			fail(__LINE__, "%.11s: no viewer", versions[k]);
			continue;
		}
		int32_t enc[4];
		CHECK(whole_screen(&c, enc, 4) >= 1, "%.11s got no update", versions[k]);
		client_close(&c);
	}
	// A 3.8 viewer picking a type that is not offered: section 7.1.3 says
	// the server says it failed, with a reason, and closes.
	{
		struct client c;
		if (client_open(&c, port) == 0) {
			client_need(&c, 12);
			client_take(&c, 12);
			client_send(&c, "RFB 003.008\n", 12);
			client_need(&c, 2);
			client_take(&c, 2);
			const unsigned long before = srv.drops;
			const uint8_t pick = 2;			/* VNC authentication */
			client_send(&c, &pick, 1);
			if (client_need(&c, 8) == 0) {
				CHECK(be32at(c.in) == 1,
				      "a refused security type gave SecurityResult %u, wanting 1",
				      be32at(c.in));
				const uint32_t n = be32at(c.in + 4);
				CHECK(n > 0 && n < 200,
				      "the reason string is %u bytes", n);
			} else {
				fail(__LINE__, "no SecurityResult for a refused security type");
			}
			for (int k = 0; k < 200; ++k)
				screen_server_poll(&srv, &frame, 0, clock_ns);
			CHECK(srv.drops == before + 1,
			      "the viewer that asked for a type not offered was not dropped");
			client_close(&c);
		}
	}
	// A message type RFC 6143 gives no length for: the connection has to
	// go, because there is no way to skip it.
	{
		struct client c;
		if (open_viewer(&c, "RFB 003.008\n", NULL, NULL, 0) == 0) {
			const unsigned long before = srv.drops;
			const uint8_t nonsense[] = { 0xFF, 0, 0, 0 };
			client_send(&c, nonsense, sizeof nonsense);
			for (int k = 0; k < 200; ++k)
				screen_server_poll(&srv, &frame, 0, clock_ns);
			CHECK(srv.drops == before + 1,
			      "a viewer sending message type 255 was not dropped");
			client_close(&c);
		}
	}
}

// Keys and pointer events are read, counted and dropped, and the line is said
// once.
// With NO input face --- which is `--no-input`, and a bitstream without the
// input cables --- the events are still read off the wire and dropped, and the
// connection survives all of it.  RFC 6143 gives a server no way to tell a
// viewer it takes no input, and every viewer sends pointer events as the
// mouse crosses its window, so refusing the connection would be worse.
// ---- `--terminal`'s endpoint, which is muir's grammar -------------------
//
// **WHY THE GRAMMAR IS CHECKED AND NOT THE FLAG.**  `cadr-terminal.c`'s `main`
// is not in this check --- the check links the core files and drives them ---
// so what is held here is the thing `main` calls, which is where every
// decision about a spelling is made.  `main` reads one word, hands it here and
// binds what comes back.
//
// muir's four forms, out of its own `endpoint_at`: nothing, a port, an
// address, address:port.  All four are taken here, because the screen's number
// is one every VNC viewer already knows and an endpoint that does not say it
// still says something.
//
// **AND THE DEFAULT ADDRESS IS EVERY INTERFACE AND NOT THE LOOPBACK**, which
// is the one place this board parts from muir and is checked here so that
// nobody changes it by accident.  muir binds the loopback because that is
// where an unauthenticated server belongs on a machine somebody is sitting at;
// this board has no screen of its own and the whole point of this program is
// to be watched from another machine.  `--terminal 127.0.0.1:5900` is how the
// loopback is asked for, and the card writes its endpoint out in full so that
// nothing rests on which default is which.
static void check_the_endpoint_grammar(void)
{
	struct cadr_endpoint e;

	// Nothing: the flag given bare is the default, every interface at
	// VNC's display :0.
	CHECK(cadr_endpoint_parse(NULL, NULL, TERM_TEST_PORT, &e) == 0,
	      "the flag given bare must be taken");
	CHECK(e.port == TERM_TEST_PORT, "and it is the default port: %u", e.port);
	CHECK(e.addr[0] == '\0', "and every interface, not the loopback: [%s]", e.addr);
	CHECK(e.port_named == 0, "and it names no port");

	// A bare port.
	CHECK(cadr_endpoint_parse("5901", NULL, TERM_TEST_PORT, &e) == 0,
	      "a bare port must be taken");
	CHECK(e.port == 5901, "a bare port is that port: %u", e.port);
	CHECK(e.addr[0] == '\0',
	      "and it is on the default's address, every interface here: [%s]", e.addr);
	CHECK(e.port_named == 1, "and it names a port");

	// A bare address, at the default's port.
	CHECK(cadr_endpoint_parse("127.0.0.1", NULL, TERM_TEST_PORT, &e) == 0,
	      "a bare address must be taken");
	CHECK(strcmp(e.addr, "127.0.0.1") == 0, "the address is the address: [%s]", e.addr);
	CHECK(e.port == TERM_TEST_PORT, "at the default's port: %u", e.port);
	CHECK(e.port_named == 0, "and it names no port");

	// address:port, which is what the card writes.
	CHECK(cadr_endpoint_parse("0.0.0.0:5900", NULL, TERM_TEST_PORT, &e) == 0,
	      "address:port must be taken");
	CHECK(strcmp(e.addr, "0.0.0.0") == 0 && e.port == 5900 && e.port_named == 1,
	      "and it is itself: [%s]:%u", e.addr, e.port);

	// The loopback with a port, which is how the screen is kept off the
	// LAN now that there is no --bind to say it with.
	CHECK(cadr_endpoint_parse("127.0.0.1:5900", NULL, TERM_TEST_PORT, &e) == 0 &&
	      strcmp(e.addr, "127.0.0.1") == 0 && e.port == 5900,
	      "the loopback with a port must be taken");

	// The refusals, each a spelling somebody could write on a card.
	CHECK(cadr_endpoint_parse("nonsense", NULL, TERM_TEST_PORT, &e) != 0,
	      "a word that is neither a port nor an address must be refused");
	CHECK(cadr_endpoint_parse(":5900", NULL, TERM_TEST_PORT, &e) != 0,
	      "an empty host must be refused rather than read as every interface: "
	      "0.0.0.0:5900 is how that is said");
	CHECK(cadr_endpoint_parse("5900:", NULL, TERM_TEST_PORT, &e) != 0,
	      "a colon with no port after it must be refused");
	CHECK(cadr_endpoint_parse("65536", NULL, TERM_TEST_PORT, &e) != 0,
	      "a port above 65535 must be refused");
	CHECK(cadr_endpoint_parse("0.0.0.0:65536", NULL, TERM_TEST_PORT, &e) != 0,
	      "and so must one in address:port");
	CHECK(cadr_endpoint_parse("-1", NULL, TERM_TEST_PORT, &e) != 0,
	      "a negative port must be refused");
	CHECK(cadr_endpoint_parse("59 00", NULL, TERM_TEST_PORT, &e) != 0,
	      "a port with a space in it must be refused");
	CHECK(cadr_endpoint_parse("1.2.3", NULL, TERM_TEST_PORT, &e) != 0,
	      "an address that is not a dotted quad must be refused");
	CHECK(cadr_endpoint_parse("", NULL, TERM_TEST_PORT, &e) != 0,
	      "an empty argument --- --terminal= --- must be refused, which is not "
	      "the same case as the flag given bare");

	// **AN ADDRESS THIS TAKES IS ONE THE BIND TAKES**, which is the whole
	// reason the parse uses the same inet_pton the server does.  A grammar
	// that accepted a spelling the socket then refused would move the
	// failure from the flag to the bind, where nobody is reading.
	CHECK(cadr_endpoint_parse("127.0.0.1", NULL, 0, &e) == 0, "the loopback parses");
	struct screen_server probe;
	CHECK(screen_server_bind(&probe, e.addr, e.port) == 0,
	      "and the server binds the address the grammar gave back");
	screen_server_close(&probe);
}

static void check_read_only(void)
{
	struct client c;
	srv.input = NULL;
	if (open_viewer(&c, "RFB 003.008\n", NULL, NULL, 0) < 0)
		return;
	const unsigned long before = srv.input_events;
	const uint8_t key_down[8] = { 4, 1, 0, 0, 0, 0, 0, 'a' };
	const uint8_t key_up[8] = { 4, 0, 0, 0, 0, 0, 0, 'a' };
	const uint8_t pointer[6] = { 5, 1, 0, 10, 0, 20 };
	client_send(&c, key_down, sizeof key_down);
	client_send(&c, key_up, sizeof key_up);
	client_send(&c, pointer, sizeof pointer);
	// And a clipboard, whose bytes are dropped as they arrive.
	const uint8_t cut[8 + 5] = { 6, 0, 0, 0, 0, 0, 0, 5, 'h', 'e', 'l', 'l', 'o' };
	client_send(&c, cut, sizeof cut);
	for (int k = 0; k < 200; ++k)
		screen_server_poll(&srv, &frame, 1, clock_ns);
	CHECK(srv.input_events == before + 3,
	      "%lu input events counted, wanting %lu: they are read and dropped, not ignored",
	      srv.input_events, before + 3);
	// The connection survives all of it and still serves a screen.
	int32_t enc[4];
	CHECK(whole_screen(&c, enc, 4) >= 1,
	      "a viewer that sent keys, a pointer and a clipboard got no screen afterwards");
	client_close(&c);
}

// The whole-screen interval: a viewer asking for the whole screen at every
// poll gets one a frame, and an incremental update is never held back.
static void check_full_update_interval(const uint8_t pic[SCREEN_HEIGHT][SCREEN_WIDTH])
{
	words_from_picture(window, pic, 0);
	screen_frame_init(&frame, 0);
	screen_frame_read(&frame, window);
	struct client c;
	if (open_viewer(&c, "RFB 003.008\n", NULL, NULL, 0) < 0)
		return;
	int32_t enc[4];
	// Frozen from before the first screen, so that the second request is
	// inside the same frame as the answer to the first.
	clock_frozen = 1;
	CHECK(whole_screen(&c, enc, 4) >= 1, "the interval check got no first screen");
	client_request(&c, 0, 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
	CHECK(client_quiet(&c, 300) == 0,
	      "a second whole screen inside one frame gave %zu bytes; one a frame is the rule",
	      c.len);
	clock_ns += SCREEN_FULL_UPDATE_NS;
	CHECK(client_need(&c, 4) == 0 && c.in[0] == 0,
	      "no whole screen a frame later, when the interval had passed");
	clock_frozen = 0;
	client_close(&c);
	for (int k = 0; k < 50; ++k)
		screen_server_poll(&srv, &frame, 0, clock_ns);
}

// Blank is a state worth saying, and each kind is told apart.
static void check_blank(void)
{
	screen_frame_init(&frame, 0);
	screen_clear(frame.words);
	CHECK(screen_frame_blank(&frame) == SCREEN_BLANK_ZEROS, "a zero screen is not called zero");
	for (unsigned k = 0; k < SCREEN_VISIBLE_WORDS; ++k)
		frame.words[k] = 0xFFFFFFFFu;
	CHECK(screen_frame_blank(&frame) == SCREEN_BLANK_ONES,
	      "an all-ones screen is not called all ones");
	CHECK(screen_frame_lit(&frame) == SCREEN_VISIBLE_WORDS * 32,
	      "an all-ones screen does not count %u lit", SCREEN_VISIBLE_WORDS * 32);
	for (unsigned k = 0; k < SCREEN_VISIBLE_WORDS; ++k)
		frame.words[k] = 0xA5A5A5A5u;
	CHECK(screen_frame_blank(&frame) == SCREEN_BLANK_OTHER,
	      "a screen of one repeated word is not called blank");
	frame.words[SCREEN_VISIBLE_WORDS - 1] ^= 1u;
	CHECK(screen_frame_blank(&frame) == SCREEN_BLANK_NO,
	      "one word different in 23,112 and the screen is still called blank");
	frame.words[SCREEN_VISIBLE_WORDS - 1] ^= 1u;
	frame.words[0] ^= 1u;
	CHECK(screen_frame_blank(&frame) == SCREEN_BLANK_NO,
	      "the first word different and the screen is still called blank");
}


// ---- a model of the fabric's input face ---------------------------------
//
// **IT RECORDS AND IT DOES NOT INTERPRET.**  CLAUDE.md's standing rule is
// that a shadow of the thing under test must not move with a bug in it, so
// this keeps the word stream the program wrote and nothing else: every check
// below compares that stream against words worked out BY HAND from
// `keyboard::up_down` and MIT's own table.  A model that turned the words
// back into keysyms would agree with a program that was wrong the same way.
//
// What it does model is the one thing the program has to cope with, which is
// a queue that fills: `room` says how many more words it will take, and a
// check sets it to nothing to make the program hold what it could not send.

#define MODEL_WORDS 512

// **AND IT MODELS THE SEAM'S OWN PACING, WHICH THE CARD'S HANDSHAKE IS NOT
// ALL OF.**  Three things sit between a word written here and a character on
// the machine's screen, and only the first two are in any register:
//
//   the fabric's queue   `cadr_input_cables.sv`, DEPTH words;
//   the card             `cadr_io_board.sv`, ONE word behind `KBD READY`,
//                        and the fabric hands it the next only when the
//                        machine has read the last --- `taking`, which is
//                        `muir::terminal::keyboard::Keyboard::deliver`;
//   the machine          which reads every word the card offers, and
//                        DIGESTS them at its own rate, which no register
//                        here can see.
//
// The third is what the board measured and what nothing modeled: twenty
// characters handed over with no gap arrived as nineteen while the fabric's
// `LOST` stayed zero, because nothing was lost in the fabric --- the machine
// read all forty words and its software kept nineteen characters' worth.  So
// the machine here reads the card whenever there is something on it, and
// takes the word only if `digest_ns` has gone by since the last one it took;
// otherwise it counts it in `swallowed`, which is the board's silent loss.
//
// `digest_ns` of 0 is a machine that keeps up with anything, which is what
// every check of what a key MEANS wants behind it.
#define MODEL_DEPTH 16

struct model_face {
	uint32_t reg[1024];
	uint32_t keys[MODEL_WORDS];
	unsigned nkeys;
	int moves[MODEL_WORDS][2];
	unsigned nmoves;
	uint32_t buttons[MODEL_WORDS];
	unsigned nbuttons;
	unsigned flushes;
	// How many more words it will take; -1 for "as many as come".
	int room;
	unsigned long over;      // words offered with no room, which must be 0

	// --- the fabric's queue
	uint32_t q[MODEL_DEPTH];
	unsigned qhead, qcount;
	// --- the card: one word, and the flop the machine clears by reading
	uint32_t card;
	int kbd_ready;
	// How long the machine takes to notice a word on the card --- its
	// interrupt latency, which is nothing to do with how fast its software
	// digests them.  0 is a machine that reads the instant a word lands.
	uint64_t read_ns, next_read;
	// The most the fabric's queue ever held.  **ONE WORD IN FLIGHT** is
	// the first of the seam's two rules, and this is what says it holds:
	// a program that placed a second word while the first had not reached
	// the card would show here and nowhere else.
	unsigned qmax;
	// --- the machine behind it
	uint64_t now;            // the test's own clock, handed over before a pass
	uint64_t digest_ns;      // 0: a machine that keeps up with anything
	uint64_t next_digest;    // when it will take another
	uint32_t got[MODEL_WORDS];
	unsigned ngot;
	unsigned long swallowed; // read off the card too soon to be kept
	uint64_t gap_min;        // the closest two kept words ever were
	uint64_t last_kept;
	int ever_kept;
};

static struct model_face model;
static struct input_face face;

// One turn of the fabric and the machine, run wherever the program touches
// the face --- which is every pass in which it has a word to place, since it
// must read `STAT` to know whether it may.
static void model_step(void)
{
	struct model_face *m = &model;
	// The modeled machine runs on the check's own clock, read here rather
	// than handed over, so that a pass taken anywhere --- `pump`, or the
	// polling inside `client_write` --- sees the same time.
	m->now = clock_ns;
	// `cadr_input_cables.sv`: a word goes to the card when the card is
	// free.  ONE word, and not the queue: that gate is the whole reason
	// the fabric cannot overwrite the card.
	if (!m->kbd_ready && m->qcount) {
		m->card = m->q[m->qhead];
		m->qhead = (m->qhead + 1) % MODEL_DEPTH;
		--m->qcount;
		m->kbd_ready = 1;
	}
	if (!m->kbd_ready)
		return;
	if (m->read_ns && m->now < m->next_read)
		return;
	// ...and the machine reads it, which is what clears `KBD READY` ---
	// `R_KBD_LOW: if (!wr) kbd_ready <= 1'b0`.  The READ always happens.
	m->kbd_ready = 0;
	m->next_read = m->now + m->read_ns;
	if (m->digest_ns && m->now < m->next_digest) {
		++m->swallowed;
		return;
	}
	if (m->ever_kept) {
		const uint64_t gap = m->now - m->last_kept;
		if (gap < m->gap_min)
			m->gap_min = gap;
	}
	m->last_kept = m->now;
	m->ever_kept = 1;
	m->next_digest = m->now + m->digest_ns;
	if (m->ngot < MODEL_WORDS)
		m->got[m->ngot++] = m->card;
}

static uint32_t model_read(struct input_face *f, unsigned word)
{
	struct model_face *m = f->ctx;
	model_step();
	if (word == IN_IDENT)
		return IN_IDENT_WORD;
	if (word == IN_STAT) {
		// Room, the card's `KBD READY` and what the queue still holds:
		// the three things the program asks about before it places a
		// word.  `build/gp0_split.pass` is what holds the fabric to
		// them; what is here is enough of them to pace against.
		uint32_t st = 0;
		if (m->room != 0 && m->qcount < MODEL_DEPTH)
			st |= IN_ST_ROOM;
		if (m->kbd_ready)
			st |= IN_ST_KBD_READY;
		st |= (uint32_t)(m->qcount & 0x3Fu) << 8;
		return st;
	}
	return m->reg[word & 1023];
}

static void model_write(struct input_face *f, unsigned word, uint32_t v)
{
	struct model_face *m = f->ctx;
	model_step();
	m->reg[word & 1023] = v;
	switch (word) {
	case IN_KEY:
		if (m->room == 0 || m->qcount >= MODEL_DEPTH) {
			++m->over;
			break;
		}
		if (m->room > 0)
			--m->room;
		m->q[(m->qhead + m->qcount) % MODEL_DEPTH] = v;
		++m->qcount;
		if (m->qcount > m->qmax)
			m->qmax = m->qcount;
		if (m->nkeys < MODEL_WORDS)
			m->keys[m->nkeys++] = v;
		break;
	case IN_MOUSE:
		if (m->nmoves < MODEL_WORDS) {
			// Sign-extended out of the two twelve-bit fields, which
			// is the register's own shape: `input_face.h`.
			const int dx = (int)((v & 0xFFFu) << 20) >> 20;
			const int dy = (int)(((v >> 12) & 0xFFFu) << 20) >> 20;
			m->moves[m->nmoves][0] = dx;
			m->moves[m->nmoves][1] = dy;
			++m->nmoves;
		}
		break;
	case IN_BUTTONS:
		if (m->nbuttons < MODEL_WORDS)
			m->buttons[m->nbuttons++] = v;
		break;
	case IN_CTL:
		if (v & IN_CTL_FLUSH) {
			++m->flushes;
			m->qcount = 0;
			m->qhead = 0;
		}
		break;
	default:
		break;
	}
}

static void model_reset(void)
{
	memset(&model, 0, sizeof model);
	model.room = -1;
	model.gap_min = UINT64_MAX;
	face.read = model_read;
	face.write = model_write;
	face.ctx = &model;
}

// A pass costs the modeled clock this much.  A real poll loop takes time,
// and the pacing rule the program follows is measured on the clock its caller
// hands it --- so a check of what a key MEANS needs the clock to move at all,
// or the first word of a burst would be the only one.  A MICROSECOND, which
// is small against the 30.912 ms frame and the 30 s handshake deadline that
// the clock must not run past, and large against the 1 ns interval those
// checks set.
#define POLL_STEP_NS 1000u

// The words the program has sent, drained by polling.  The server drains its
// queue at the end of a pass, so a pass is what it takes.
static void pump(int passes)
{
	for (int k = 0; k < passes; ++k) {
		screen_server_poll(&srv, &frame, 0, clock_ns);
		if (!clock_frozen)
			clock_ns += POLL_STEP_NS;
		model_step();
	}
}

// `keyboard::up_down`, written out here so that the check's expected words
// and the program's are not one expression.
static uint32_t word_of(unsigned position, int up)
{
	return 0xF90000u | (up ? 0x100u : 0u) | (position & 0177u);
}

// What a key event should become, compared as a whole stream.
static void want_keys(const char *what, const uint32_t *w, unsigned n)
{
	++checks;
	if (model.nkeys != n) {
		fail(__LINE__, "%s: %u words reached the fabric, wanting %u", what, model.nkeys, n);
		for (unsigned k = 0; k < model.nkeys; ++k)
			fprintf(stderr, "      [%u] 0x%06x\n", k, model.keys[k]);
		return;
	}
	for (unsigned k = 0; k < n; ++k) {
		++checks;
		if (model.keys[k] != w[k])
			fail(__LINE__, "%s: word %u is 0x%06x, wanting 0x%06x (position 0%o %s)",
			     what, k, model.keys[k], w[k], w[k] & 0177u,
			     (w[k] & 0x100u) ? "up" : "down");
	}
}

// One viewer, with the input face attached, the model emptied, and the
// mapping it is to resolve against --- the built-in one unless a check hands
// over another.
static int open_typist_with(struct client *c, const struct key_map *map)
{
	model_reset();
	srv.input = &face;
	// **THESE CHECKS ARE ABOUT WHAT A KEY MEANS AND NOT ABOUT PACING.**
	// One nanosecond is an interval every pass satisfies, so the stream
	// they compare is the stream the mapping makes.  `check_key_pacing`
	// below sets the real figure and drives the clock itself.
	srv.key_interval_ns = 1;
	srv.key_at_ns = 0;
	srv.key_ever = 0;
	if (map)
		key_state_init_with(&srv.keys, map);
	else
		key_state_init(&srv.keys);
	srv.have_ptr = 0;
	srv.buttons = 0;
	if (open_viewer(c, "RFB 003.008\n", NULL, NULL, 0) < 0)
		return -1;
	pump(4);
	model.nkeys = 0;
	return 0;
}

static int open_typist(struct client *c)
{
	return open_typist_with(c, NULL);
}

static void send_key(struct client *c, uint32_t keysym, int down)
{
	const uint8_t m[8] = { 4, (uint8_t)(down ? 1 : 0), 0, 0,
			       (uint8_t)(keysym >> 24), (uint8_t)(keysym >> 16),
			       (uint8_t)(keysym >> 8), (uint8_t)keysym };
	client_send(c, m, sizeof m);
}

static void send_pointer(struct client *c, uint8_t buttons, unsigned x, unsigned y)
{
	const uint8_t m[6] = { 5, buttons, (uint8_t)(x >> 8), (uint8_t)x,
			       (uint8_t)(y >> 8), (uint8_t)y };
	client_send(c, m, sizeof m);
}

// ---- the keyboard -------------------------------------------------------
//
// **EVERY EXPECTED WORD BELOW IS HAND-COMPUTED FROM MIT'S OWN TABLE**, the
// positions in octal exactly as `keyboard.rs` has them, and `word_of` is
// `up_down` written a second time.  That is the anchors' rule applied to the
// keyboard: a builder and a reader that are wrong the same way agree with
// each other, and the literals are what no such pair can put back.
static void check_keyboard(void)
{
	struct client c;

	// --- a plain letter.  'a' is at 0o123 on the unshifted plane, and
	// with no shift held the position is simply pressed and released:
	// there are no modifier bits in a word on this keyboard.
	if (open_typist(&c) == 0) {
		send_key(&c, 'a', 1);
		send_key(&c, 'a', 0);
		pump(40);
		const uint32_t w[] = { word_of(0123, 0), word_of(0123, 1) };
		want_keys("'a' down and up", w, 2);
		// ...and the frame bits, which are what the card's high half
		// carries: `word >> 16` is 0o371 on every word this keyboard
		// sends, bits 23-19 all ones and 18-16 the source ID.
		CHECK(model.nkeys == 2 && (model.keys[0] >> 16) == 0371u,
		      "the frame bits of a key word: 0x%02x, wanting 0o371",
		      model.nkeys ? model.keys[0] >> 16 : 0);
		client_close(&c);
		settle();
	}

	// --- a character whose plane the viewer is not holding.  RFB sends
	// the SHIFTED keysym, '!', and the Lisp Machine wants position 0o121
	// with Shift down --- so the Shift key is worked around the key and
	// the viewer's own release of '!' is dropped, the key having gone
	// whole already.
	if (open_typist(&c) == 0) {
		send_key(&c, '!', 1);
		send_key(&c, '!', 0);
		pump(40);
		const uint32_t w[] = {
			word_of(024, 0),    // Left Shift down
			word_of(0121, 0),   // '1'/'!'
			word_of(0121, 1),
			word_of(024, 1)     // ...and up again
		};
		want_keys("'!' with no shift held: the shift worked around it", w, 4);
		client_close(&c);
		settle();
	}

	// --- and the same character with the viewer holding shift, where
	// nothing has to be worked around: the position is pressed and the
	// machine, which follows the stream, sees the shift already down.
	if (open_typist(&c) == 0) {
		send_key(&c, 0xffe1u, 1);   // Shift_L
		send_key(&c, 'A', 1);
		send_key(&c, 'A', 0);
		send_key(&c, 0xffe1u, 0);
		pump(40);
		const uint32_t w[] = {
			word_of(024, 0), word_of(0123, 0), word_of(0123, 1), word_of(024, 1)
		};
		want_keys("Shift_L and 'A': the plane the viewer holds", w, 4);
		client_close(&c);
		settle();
	}

	// --- AND THE OTHER HALF OF THE SAME DECISION: the viewer holding
	// shift and sending a keysym whose only position is on the UNSHIFTED
	// plane.  A viewer with caps lock on does this, and so does one whose
	// own keymap puts a character somewhere this keyboard does not.  Every
	// shift the viewer holds comes UP around the key and goes back down,
	// so that the machine --- which decodes from the stream --- sees the
	// character the viewer meant.
	if (open_typist(&c) == 0) {
		send_key(&c, 0xffe1u, 1);   // Shift_L, and held
		send_key(&c, 'a', 1);       // ...with a keysym on plane 0 only
		send_key(&c, 'a', 0);
		send_key(&c, 0xffe1u, 0);
		pump(40);
		const uint32_t w[] = {
			word_of(024, 0),     // the shift the viewer pressed
			word_of(024, 1),     // ...lifted around the key
			word_of(0123, 0),
			word_of(0123, 1),
			word_of(024, 0),     // ...and put back
			word_of(024, 1)      // ...until the viewer lets it go
		};
		want_keys("Shift_L held and a plane-0 keysym: the shift lifted around it", w, 6);
		client_close(&c);
		settle();
	}

	// --- the named keys a host keyboard has a key for, which are
	// `default.keys`' own `key` lines.  Each is one position and its
	// release, and the positions are MIT's.
	if (open_typist(&c) == 0) {
		struct named { uint32_t keysym; unsigned position; const char *what; };
		static const struct named NAMED[] = {
			{ 0xff0du, 0136, "Return" },
			{ 0xff8du, 0136, "KP_Enter, which is Return too" },
			{ 0xff09u, 022,  "Tab" },
			{ 0xff08u, 023,  "BackSpace, which is Rubout" },
			{ 0xffffu, 023,  "Delete, which is Rubout as well" },
			{ 0xff0au, 036,  "Linefeed, which is Line" },
			{ 0xff1bu, 0143, "Escape, which is Alt Mode" },
			{ 0xff6au, 0116, "Help" },
			{ 0xff6bu, 0167, "Break" },
			{ 0xff69u, 067,  "Cancel, which is Abort" },
			{ 0xff57u, 0156, "End" },
			{ 0xff13u, 030,  "Pause, which is Hold Output" },
			{ 0xffbeu, 040,  "F1, which is Terminal" },
			{ 0xffbfu, 0141, "F2, which is System" },
			{ 0xffc0u, 042,  "F3, which is Network" },
			{ 0xffc1u, 046,  "F4, which is Status" },
			{ 0xffc2u, 047,  "F5, which is Resume" },
			{ 0xffc9u, 0120, "F12, which is Quote" },
		};
		for (unsigned k = 0; k < sizeof NAMED / sizeof NAMED[0]; ++k) {
			model.nkeys = 0;
			send_key(&c, NAMED[k].keysym, 1);
			send_key(&c, NAMED[k].keysym, 0);
			pump(20);
			const uint32_t w[] = { word_of(NAMED[k].position, 0),
					       word_of(NAMED[k].position, 1) };
			want_keys(NAMED[k].what, w, 2);
		}
		client_close(&c);
		settle();
	}

	// --- the modifiers, which are keys of their own at their own
	// positions.  Left and Right are different positions and a face that
	// collapsed them would be caught here.
	if (open_typist(&c) == 0) {
		struct named { uint32_t keysym; unsigned position; const char *what; };
		static const struct named MODS[] = {
			{ 0xffe1u, 024,  "Shift_L" },
			{ 0xffe2u, 025,  "Shift_R" },
			{ 0xffe3u, 020,  "Control_L" },
			{ 0xffe4u, 026,  "Control_R" },
			{ 0xffe7u, 045,  "Meta_L" },
			{ 0xffe9u, 045,  "Alt_L, which is Meta too" },
			{ 0xffe8u, 0165, "Meta_R" },
			{ 0xffebu, 05,   "Super_L" },
			{ 0xffecu, 065,  "Super_R" },
			{ 0xffedu, 0145, "Hyper_L" },
			{ 0xffeeu, 0175, "Hyper_R" },
			{ 0xffe5u, 0125, "Caps_Lock" },
			// **`Left Greek` IS POSITION 0o035, WHICH MIT'S TABLE
			// LABELS *RIGHT* GREEK**, and that is muir's and not a
			// slip here.  `shifting(s)` walks the table upwards and
			// `Left` takes the FIRST position it finds, and Greek
			// is the one shifting key of the seven whose two
			// positions are in the other order: 0o035 is Right and
			// 0o044 is Left, where Shift, Control, Meta, Super,
			// Hyper and Top all have Left below Right.  Harmless,
			// both positions being the same shift to the machine,
			// and pinned here so that nobody "fixes" it into a
			// disagreement with muir.
			{ 0xfe03u, 035,  "ISO_Level3_Shift, which is Greek" },
			{ 0xff67u, 0104, "Menu, which is Left Top" },
		};
		for (unsigned k = 0; k < sizeof MODS / sizeof MODS[0]; ++k) {
			model.nkeys = 0;
			send_key(&c, MODS[k].keysym, 1);
			send_key(&c, MODS[k].keysym, 0);
			pump(20);
			const uint32_t w[] = { word_of(MODS[k].position, 0),
					       word_of(MODS[k].position, 1) };
			want_keys(MODS[k].what, w, 2);
		}
		client_close(&c);
		settle();
	}

	// --- the prefix, which is muir's answer to a keyboard with fewer keys
	// than this one.  `Scroll_Lock` sends nothing of its own; the keysym
	// after it is looked up behind it.  Behind a prefix a SHIFTING key is
	// held for the one key that follows, and everything else is tapped.
	if (open_typist(&c) == 0) {
		// Scroll_Lock then '1' is Roman I, at 0o101: tapped, and the
		// '1' release dropped.
		send_key(&c, 0xff14u, 1);
		send_key(&c, 0xff14u, 0);
		send_key(&c, '1', 1);
		send_key(&c, '1', 0);
		pump(40);
		const uint32_t w[] = { word_of(0101, 0), word_of(0101, 1) };
		want_keys("Scroll_Lock then '1', which is Roman I", w, 2);

		// Scroll_Lock then 'l' is Control, a shifting key: held, then
		// the next key tapped inside it and the latch let go after.
		// 'x' is at 0o064.
		model.nkeys = 0;
		send_key(&c, 0xff14u, 1);
		send_key(&c, 'l', 1);
		send_key(&c, 'l', 0);
		send_key(&c, 'x', 1);
		send_key(&c, 'x', 0);
		pump(40);
		const uint32_t v[] = {
			word_of(020, 0),    // Left Control down, latched
			word_of(064, 0),    // 'x' tapped inside it
			word_of(064, 1),
			word_of(020, 1)     // ...and the latch let go
		};
		want_keys("Scroll_Lock l then 'x', which is Control-X", v, 4);

		// A prefix pressed again is the way out of a sequence begun by
		// mistake, and sends nothing.
		model.nkeys = 0;
		send_key(&c, 0xff14u, 1);
		send_key(&c, 0xff14u, 1);
		send_key(&c, 'a', 1);
		send_key(&c, 'a', 0);
		pump(40);
		const uint32_t u[] = { word_of(0123, 0), word_of(0123, 1) };
		want_keys("a prefix pressed twice lets go, and 'a' is 'a'", u, 2);
		client_close(&c);
		settle();
	}

	// --- a keysym nothing maps goes nowhere, and is counted so that it
	// can be said.  `Home` is in muir's keysym names and in no binding,
	// and is not printable ASCII, so `positions` finds nothing for it.
	if (open_typist(&c) == 0) {
		const unsigned long before = srv.keys.unbound;
		send_key(&c, 0xff50u, 1);   // Home
		send_key(&c, 0xff50u, 0);
		send_key(&c, 0xff63u, 1);   // Insert
		send_key(&c, 0xff63u, 0);
		pump(40);
		want_keys("Home and Insert, which nothing maps", NULL, 0);
		// FOUR and not two: `positions` finds nothing for an unbound
		// keysym going DOWN or coming UP, and muir counts each.
		CHECK(srv.keys.unbound == before + 4,
		      "%lu unbound keysyms counted, wanting %lu",
		      srv.keys.unbound - before, 4ul);
		client_close(&c);
		settle();
	}

	// --- a viewer that goes with keys down owes the machine their
	// releases.  There are no modifier bits in a word here, so a Control
	// held when a connection drops is a Control held for the rest of the
	// run and every character after it is a control character.
	if (open_typist(&c) == 0) {
		send_key(&c, 0xffe3u, 1);   // Control_L down and never up
		send_key(&c, 0xffe1u, 1);   // Shift_L too
		pump(40);
		const uint32_t w[] = { word_of(020, 0), word_of(024, 0) };
		want_keys("two modifiers held", w, 2);
		client_close(&c);
		settle();
		pump(20);
		const uint32_t v[] = {
			word_of(020, 0), word_of(024, 0),
			word_of(020, 1), word_of(024, 1)
		};
		want_keys("...and released when the viewer went", v, 4);
	}

	// --- a fabric with no room holds the program up rather than losing
	// what it could not send.  The face refuses, the word stays at the
	// head of the queue, and the next pass with room delivers it in
	// ORDER: nothing is dropped and nothing is reordered.
	if (open_typist(&c) == 0) {
		model.room = 2;
		send_key(&c, 'a', 1);
		send_key(&c, 'a', 0);
		send_key(&c, 'b', 1);
		send_key(&c, 'b', 0);
		pump(40);
		CHECK(model.nkeys == 2, "%u words through a face with room for two, wanting 2",
		      model.nkeys);
		CHECK(model.over == 0, "%lu words offered to a full face, wanting none: "
		      "the program must ask for room", model.over);
		CHECK(srv.keys_stuck > 0, "the program did not record waiting for room");
		CHECK(key_pending(&srv.keys) == 2, "%u words still held, wanting 2",
		      key_pending(&srv.keys));
		model.room = -1;
		pump(20);
		const uint32_t w[] = {
			word_of(0123, 0), word_of(0123, 1),   // 'a'
			word_of(0114, 0), word_of(0114, 1)    // 'b', at 0o114
		};
		want_keys("held and then delivered in order", w, 4);
		client_close(&c);
		settle();
	}
}

// ---- the mouse ----------------------------------------------------------
//
// A `PointerEvent` is an absolute position and the CADR's mouse counts
// deltas, so what crosses is the difference.  `muir::terminal::mouse`: one
// count a pixel, right and down positive, and the FIRST event only
// establishes where the pointer is.
// ---- how fast words may be handed over ----------------------------------
//
// **THE BOARD MEASURED BOTH OF THESE AND NOTHING IN THE TREE COULD SEE
// EITHER.**  The four words of a shifted keystroke, written back to back,
// gave `=` where `+` was meant; the same four 50 ms apart gave `+`.  Twenty
// characters with no gap arrived as nineteen, one missing and one doubled.
// Throughout, the fabric's `LOST` read zero --- nothing was lost in the
// fabric.  What loses them is behind the card, where the machine's own
// software digests the stream, and `input_face.h` has the rule and where its
// number comes from.
//
// The model above is what makes this checkable without a board: a machine
// that reads every word the card offers and keeps only those far enough
// apart, which is the board's symptom written down.

// A pass, with the modeled clock moved on by `step_ns`.  The pacing rule is
// measured on the clock the caller hands the server, so a check of it has to
// drive that clock.
static void pace(unsigned passes, uint64_t step_ns)
{
	for (unsigned k = 0; k < passes; ++k) {
		screen_server_poll(&srv, &frame, 0, clock_ns);
		clock_ns += step_ns;
		// **THE FABRIC AND THE MACHINE RUN WHETHER THE PROGRAM LOOKS OR
		// NOT.**  Stepping the model only where the program touches the
		// face would leave the last word of a burst sitting in the
		// queue for ever, which is the model's doing and not the
		// program's.
		model_step();
	}
}

// The machine put behind the card for these checks, and the pacing turned on.
//
// **THE INTERVAL IS LEFT AT ZERO, WHICH IS THE DERIVED DEFAULT.**  Setting it
// here would leave the default --- what a server struct that was only zeroed
// paces itself at, and so what the program on the board actually uses ---
// tested by nothing at all.  The one check below that sets it is there to say
// the field is read when it is set.
static void expect_a_real_machine(void)
{
	srv.key_interval_ns = 0;
	srv.key_at_ns = 0;
	srv.key_ever = 0;
	model.digest_ns = INPUT_KEY_INTERVAL_NS;
	model.next_digest = 0;
	model.ngot = 0;
	model.swallowed = 0;
	model.gap_min = UINT64_MAX;
	model.ever_kept = 0;
	model.nkeys = 0;
	model.read_ns = 0;
	model.next_read = 0;
	model.qmax = 0;
}

static void want_got(const char *what, const uint32_t *w, unsigned n)
{
	CHECK(model.ngot == n, "%s: the machine kept %u words, wanting %u",
	      what, model.ngot, n);
	CHECK(model.swallowed == 0,
	      "%s: %lu words reached the machine too fast to be kept, wanting none",
	      what, model.swallowed);
	const unsigned m = model.ngot < n ? model.ngot : n;
	for (unsigned i = 0; i < m; ++i)
		CHECK(model.got[i] == w[i], "%s: word %u is 0x%06x, wanting 0x%06x",
		      what, i, model.got[i], w[i]);
}

static void check_key_pacing(void)
{
	// The constant, said in the two facts it is made of, so that a change
	// to either has to be made here as well as at the constant.  muir
	// attempts one `deliver` every `TERMINAL_CHECK` = 4,096 microcycles,
	// and a microcycle on this board is 29 ticks of 10 ns.
	CHECK(INPUT_KEY_INTERVAL_NS == 4096ull * 290ull,
	      "the key interval is %llu ns, wanting 4096 microcycles of 290 ns",
	      (unsigned long long)INPUT_KEY_INTERVAL_NS);

	struct client c;

	// --- (1) THE FOUR WORDS OF A SHIFTED KEYSTROKE.  `+` is the shifted
	// plane of the `=` key, and a viewer that is not holding Shift gets
	// the Shift worked around it: down, key down, key up, up.  The board
	// gave `=` for this, which is the machine having kept the key and not
	// the Shift in front of it.
	if (open_typist(&c) == 0) {
		expect_a_real_machine();
		send_key(&c, '+', 1);
		send_key(&c, '+', 0);
		// Five intervals' worth of passes, at a step well under one, so
		// that the pacing and not the step is what spaces the words.
		pace(300, INPUT_KEY_INTERVAL_NS / 20);
		CHECK(model.nkeys == 4, "%u words placed for `+`, wanting 4", model.nkeys);
		const uint32_t w[] = {
			word_of(024, 0),   // Shift_L down
			word_of(0126, 0),  // the `=` key down
			word_of(0126, 1),  // ...and up
			word_of(024, 1)    // Shift_L up
		};
		want_got("the four words of `+`", w, 4);
		CHECK(model.gap_min >= INPUT_KEY_INTERVAL_NS,
		      "two words arrived %llu ns apart, wanting no closer than %llu",
		      (unsigned long long)model.gap_min,
		      (unsigned long long)INPUT_KEY_INTERVAL_NS);
		client_close(&c);
		settle();
	}

	// --- (2) TWENTY CHARACTERS WITH NO GAP, which is forty words: the
	// burst that arrived as nineteen characters on the board.  They are
	// all sent before a single pass is taken, so the whole burst is
	// waiting when the pacing starts.
	if (open_typist(&c) == 0) {
		expect_a_real_machine();
		static const char text[] = "abcdefghijklmnopqrst";
		for (unsigned i = 0; i < 20; ++i) {
			send_key(&c, (uint32_t)(unsigned char)text[i], 1);
			send_key(&c, (uint32_t)(unsigned char)text[i], 0);
		}
		// Forty-one intervals, at a step well under one.
		pace(1200, INPUT_KEY_INTERVAL_NS / 20);
		CHECK(model.nkeys == 40, "%u words placed for twenty characters, wanting 40",
		      model.nkeys);
		CHECK(model.ngot == 40,
		      "the machine kept %u of forty words; %lu were swallowed",
		      model.ngot, model.swallowed);
		CHECK(model.swallowed == 0,
		      "%lu words reached the machine too fast to be kept, wanting none",
		      model.swallowed);
		// And in order, and each exactly once: the board's burst lost
		// one and repeated another, so counting is not enough.
		unsigned wrong = 0;
		for (unsigned i = 0; i < model.ngot && i < 40; ++i)
			if (model.got[i] != model.keys[i])
				++wrong;
		CHECK(wrong == 0, "%u of the forty words arrived out of order or changed",
		      wrong);
		CHECK(model.gap_min >= INPUT_KEY_INTERVAL_NS,
		      "two of the forty arrived %llu ns apart, wanting no closer than %llu",
		      (unsigned long long)model.gap_min,
		      (unsigned long long)INPUT_KEY_INTERVAL_NS);
		client_close(&c);
		settle();
	}

	// --- and the interval is a FIELD, so that the host check can hold the
	// mapping checks still and this one can ask for a slower machine.  A
	// server that ignored it would pace everything at the default and this
	// is what says it does not.
	if (open_typist(&c) == 0) {
		expect_a_real_machine();
		const uint64_t slow = INPUT_KEY_INTERVAL_NS * 4;
		srv.key_interval_ns = slow;
		model.digest_ns = slow;
		send_key(&c, 'a', 1);
		send_key(&c, 'a', 0);
		pace(400, slow / 20);
		want_got("a slower machine", (const uint32_t[]){
			word_of(0123, 0), word_of(0123, 1)
		}, 2);
		CHECK(model.gap_min >= slow,
		      "the two words arrived %llu ns apart, wanting no closer than %llu: "
		      "the interval the caller set was not the one used",
		      (unsigned long long)model.gap_min, (unsigned long long)slow);
		client_close(&c);
		settle();
	}

	// --- ONE WORD IN FLIGHT, which is the seam's other rule and the one
	// the fabric already keeps for itself.  It only shows against a machine
	// that is SLOW TO NOTICE a word on its card: the interval then comes
	// round while the card still holds the last word, and a program that
	// went by the clock alone would place a second.  The fabric would hold
	// it --- its queue is sixteen words --- so nothing is lost, and that is
	// exactly why nothing but the queue's own high-water mark can see it.
	if (open_typist(&c) == 0) {
		expect_a_real_machine();
		// Reads its card every third interval, and keeps everything it
		// reads: the loss here would be of the rule, not of a word.
		model.read_ns = INPUT_KEY_INTERVAL_NS * 3;
		model.digest_ns = 0;
		static const char text[] = "abcdef";
		for (unsigned i = 0; i < 6; ++i) {
			send_key(&c, (uint32_t)(unsigned char)text[i], 1);
			send_key(&c, (uint32_t)(unsigned char)text[i], 0);
		}
		pace(1400, INPUT_KEY_INTERVAL_NS / 20);
		CHECK(model.qmax <= 1,
		      "the fabric's queue reached %u words, wanting no more than 1: "
		      "a word was placed while the card still held the last",
		      model.qmax);
		CHECK(model.ngot == 12,
		      "the machine kept %u of twelve words", model.ngot);
		CHECK(model.over == 0, "%lu words were offered with no room", model.over);
		client_close(&c);
		settle();
	}

	// --- WHAT THE LOOP MAY SLEEP FOR.  The pacing holds a word back, and a
	// caller that then slept its whole frame would make a keystroke cost a
	// frame a word instead of an interval a word --- the rule paying for
	// itself twice.  `cadr-terminal.c` shortens its poll to this.
	if (open_typist(&c) == 0) {
		expect_a_real_machine();
		const uint64_t t0 = clock_ns;
		CHECK(screen_server_key_wait_ns(&srv, t0) == 0,
		      "a word is due with nothing waiting");
		send_key(&c, 'a', 1);
		pace(1, 0);
		// One word has gone; the next is a whole interval away.
		CHECK(srv.key_ever, "no word was placed at all");
		const uint64_t due = screen_server_key_wait_ns(&srv, srv.key_at_ns);
		CHECK(due == 0 || due == INPUT_KEY_INTERVAL_NS,
		      "the wait just after a word is %llu ns, wanting %llu or nothing left "
		      "to send", (unsigned long long)due,
		      (unsigned long long)INPUT_KEY_INTERVAL_NS);
		// ...and once it has gone by, the answer is "now".
		if (key_pending(&srv.keys))
			CHECK(screen_server_key_wait_ns(&srv,
				srv.key_at_ns + INPUT_KEY_INTERVAL_NS) == 1,
			      "a word whose interval has gone by is not due now");
		client_close(&c);
		settle();
	}

	// --- (3) THE BACKLOG GUARD, WHICH CHECKED ONE SLOT AND THEN PUSHED
	// FOUR.  `tap`'s own comment says a keystroke beyond the backlog is
	// "refused whole ... so that it leaves nothing down", and at
	// `KEY_BACKLOG - 1` it was not: the Shift went down and its release
	// was dropped, which on this keyboard is a Shift held for the rest of
	// the machine's run.
	{
		struct key_state k;
		// A queue one short of full, filled with a word that is not any
		// of the four, so that a partial push shows as a changed tail.
		const uint32_t filler = word_of(0177, 1);
		key_state_init(&k);
		k.head = 0;
		k.count = KEY_BACKLOG - 1;
		for (unsigned i = 0; i < KEY_BACKLOG - 1; ++i)
			k.queue[i] = filler;
		const unsigned long refused_before = k.refused;
		key_event(&k, '+', 1);
		CHECK(key_pending(&k) == KEY_BACKLOG - 1,
		      "a shifted keystroke at one free slot pushed %u words, wanting none: "
		      "it is refused whole or it leaves Shift down",
		      key_pending(&k) - (KEY_BACKLOG - 1));
		CHECK(k.queue[KEY_BACKLOG - 1] != word_of(024, 0),
		      "a Shift went down into the last free slot and its release was dropped");
		CHECK(k.refused == refused_before + 1,
		      "%lu keystrokes refused, wanting 1", k.refused - refused_before);
		CHECK(k.dropped == 0, "%lu words were dropped silently, wanting none",
		      k.dropped);

		// And the other way round: a viewer HOLDING Shift, typing a key
		// on the plain plane, which is Shift up, key down, key up, Shift
		// down --- four words again, and three free slots.  A partial
		// push there leaves the machine believing Shift is UP while the
		// viewer still holds it.
		key_state_init(&k);
		key_event(&k, 0xffe1u, 1);          // Shift_L down: one word
		k.head = 0;
		k.queue[0] = word_of(024, 0);
		k.count = KEY_BACKLOG - 3;
		for (unsigned i = 1; i < KEY_BACKLOG - 3; ++i)
			k.queue[i] = filler;
		key_event(&k, 'a', 1);
		CHECK(key_pending(&k) == KEY_BACKLOG - 3,
		      "a keystroke under a held Shift at three free slots pushed %u words, "
		      "wanting none", key_pending(&k) - (KEY_BACKLOG - 3));
		CHECK(k.dropped == 0, "%lu words were dropped silently, wanting none",
		      k.dropped);
	}
}

static void check_mouse(void)
{
	struct client c;
	if (open_typist(&c) < 0)
		return;

	// The first event moves nothing.  Without that, a viewer connecting
	// would fling the machine's cursor from wherever it was to wherever
	// the pointer happened to enter the window.
	send_pointer(&c, 0, 100, 200);
	pump(20);
	CHECK(model.nmoves == 0, "%u movements for the first pointer event, wanting none",
	      model.nmoves);
	CHECK(model.nbuttons == 1 && model.buttons[0] == 0,
	      "the switches on the first pointer event: %u writes, first 0x%x",
	      model.nbuttons, model.nbuttons ? model.buttons[0] : 0u);

	// Right and down are positive.
	send_pointer(&c, 0, 110, 205);
	pump(20);
	CHECK(model.nmoves == 1 && model.moves[0][0] == 10 && model.moves[0][1] == 5,
	      "right and down: (%d, %d), wanting (10, 5)",
	      model.nmoves ? model.moves[0][0] : 0, model.nmoves ? model.moves[0][1] : 0);

	// ...and left and up negative, which is the same statement the other
	// way round and is what a sign error would fail.
	send_pointer(&c, 0, 103, 201);
	pump(20);
	CHECK(model.nmoves == 2 && model.moves[1][0] == -7 && model.moves[1][1] == -4,
	      "left and up: (%d, %d), wanting (-7, -4)",
	      model.nmoves > 1 ? model.moves[1][0] : 0, model.nmoves > 1 ? model.moves[1][1] : 0);

	// A pointer event that moved nothing writes nothing: the register
	// ADDS, so a zero written every time a viewer breathed would be
	// harmless and a decode that read it as a step would not.
	const unsigned was = model.nmoves;
	send_pointer(&c, 0, 103, 201);
	pump(20);
	CHECK(model.nmoves == was, "%u movements for a pointer that did not move, wanting %u",
	      model.nmoves, was);

	// The three switches are RFB's own mask unchanged: left 1, middle 2,
	// right 4, which is `mouse::BUTTONS` in MIT's order --- `mouse.rs`
	// says the two need no translation.  Written on a change and not on
	// every event.
	const unsigned btn = model.nbuttons;
	send_pointer(&c, 1, 103, 201);
	pump(20);
	CHECK(model.nbuttons == btn + 1 && model.buttons[btn] == 1,
	      "the left button down: %u writes, last 0x%x", model.nbuttons,
	      model.nbuttons ? model.buttons[model.nbuttons - 1] : 0u);
	send_pointer(&c, 1, 103, 201);
	pump(20);
	CHECK(model.nbuttons == btn + 1, "%u writes for a mask that did not change, wanting %u",
	      model.nbuttons, btn + 1);
	send_pointer(&c, 4, 103, 201);
	pump(20);
	CHECK(model.nbuttons == btn + 2 && model.buttons[btn + 1] == 4,
	      "the right button, which is bit 2: last write 0x%x",
	      model.nbuttons ? model.buttons[model.nbuttons - 1] : 0u);
	// A wheel, which RFB puts at bits 3 and 4 and this mouse has not got.
	send_pointer(&c, 4 | 8, 103, 201);
	pump(20);
	CHECK(model.nbuttons == btn + 3 && model.buttons[btn + 2] == 4,
	      "a wheel button, which the cable has no wire for: last write 0x%x",
	      model.nbuttons ? model.buttons[model.nbuttons - 1] : 0u);

	// And a viewer going lifts the switches: a button held by nobody is a
	// button the machine goes on seeing.
	const unsigned lift = model.nbuttons;
	client_close(&c);
	settle();
	CHECK(model.nbuttons > lift && model.buttons[model.nbuttons - 1] == 0,
	      "the switches when the viewer went: last write 0x%x",
	      model.nbuttons ? model.buttons[model.nbuttons - 1] : 0u);
}

// ---- the face ------------------------------------------------------------
static void check_input_face(void)
{
	model_reset();
	CHECK(input_face_ident(&face) == 0, "IDENT is not answered by the model");
	// **THE FLUSH IS THE PROGRAM'S LEG AGAINST THE AUTOBOOT TRAP.**
	// `uc-cadr.lisp` at `(LOC 6)` warm-boots if the keyboard is ready, so
	// a word left in the fabric's queue by a previous run is a machine
	// sent somewhere nobody asked for.  `cadr-terminal.c` writes this
	// after IDENT and before the socket is bound.
	input_face_flush(&face);
	CHECK(model.flushes == 1 && (model.reg[IN_CTL] & IN_CTL_FLUSH),
	      "FLUSH: %u writes, CTL 0x%x", model.flushes, model.reg[IN_CTL]);
	// A delta wider than the register's twelve bits is HELD and not
	// wrapped: the fabric saturates what it owes, not what it is handed,
	// so a pointer that jumped a screen would otherwise go the other way.
	input_face_move(&face, 5000, -5000);
	CHECK(model.nmoves == 1 && model.moves[0][0] == 2047 && model.moves[0][1] == -2048,
	      "a delta wider than the field: (%d, %d), wanting (2047, -2048)",
	      model.moves[0][0], model.moves[0][1]);
	// And a word offered with no room is refused and reported, never
	// written: `IN_KEY` on a full queue is dropped and counted in LOST.
	model.room = 0;
	CHECK(input_face_key(&face, word_of(0123, 0)) == 0,
	      "a word offered with no room was not refused");
	CHECK(model.over == 0, "the face wrote a word the fabric had no room for");
	model.room = -1;
	CHECK(input_face_key(&face, word_of(0123, 0)) == 1, "a word with room was refused");
	CHECK(model.nkeys == 1 && model.keys[0] == 0xF90053u,
	      "the word written: 0x%06x, wanting 0xf90053", model.nkeys ? model.keys[0] : 0u);
}

// ---- the screens the check makes for itself ------------------------------

static uint8_t pic_a[SCREEN_HEIGHT][SCREEN_WIDTH];
static uint8_t pic_b[SCREEN_HEIGHT][SCREEN_WIDTH];
static uint8_t pic_dither[SCREEN_HEIGHT][SCREEN_WIDTH];

// A pattern that is asymmetric in x, in y, and inside a word, so that a
// mirrored screen, an upside-down one and a reversed bit order each come out
// different from it.  It is not a substitute for the anchors, which are what
// actually pin the mapping; it is a screen with something on every line.
// ---- the keyboard mapping -----------------------------------------------
//
// **THE BUILT-IN MAPPING IS CHECKED AGAINST muir's OWN `default.keys`, WHICH
// IS IN THIS DIRECTORY AS TEXT AND WAS NOT RESOLVED HERE.**  `input_keymap.h`
// carries two things that came out of muir by different routes:
// `KEY_BOUND`/`KEY_PREFIX`, which `keymap_from_muir.py` resolved in Python,
// and `KEY_DEFAULT_MAPPING`, which is the file itself, byte for byte.  So
// parsing the text with the C parser and requiring the result to equal the
// tables holds two independent resolutions of one reference to each other.
// A program that built its own map by parsing that text would instead be
// compared against itself, which is the check-written-to-confirm trap; the
// two are kept apart for exactly that reason and `keymap_from_muir.py`'s
// header says so.
//
// **AND THE ERROR TEXTS ARE muir's, MEASURED AND NOT TRANSCRIBED.**  Each
// literal below was compared against `muir --keyboard-mapping <file>
// --keyboard-mapping-dump` built at `muir.commit`, thirty files, and every
// one came out character for character the same; ten merged mappings were
// compared against muir's own dump of the same merge and agreed entry for
// entry.  That measurement needs muir beside the tree and so cannot live in
// this check; `docs/terminal.md` records it with its commit.  What lives
// here is the result, pinned, so that a change to any of it is a failure.

static void want_binding(const struct key_map *m, const char *what, uint32_t keysym,
			 unsigned position, unsigned shifted)
{
	for (unsigned i = 0; i < m->bounds; ++i) {
		if (m->bound[i].keysym != keysym)
			continue;
		CHECK(m->bound[i].position == position && m->bound[i].shifted == shifted,
		      "%s: keysym 0x%x is position 0%o plane %u, wanting 0%o plane %u",
		      what, keysym, m->bound[i].position, m->bound[i].shifted,
		      position, shifted);
		return;
	}
	CHECK(0, "%s: keysym 0x%x is bound to nothing", what, keysym);
}

static void want_prefixed(const struct key_map *m, const char *what, uint32_t first,
			  uint32_t second, unsigned position)
{
	for (unsigned i = 0; i < m->afters; ++i) {
		if (m->after[i].first != first || m->after[i].second != second)
			continue;
		CHECK(m->after[i].position == position,
		      "%s: 0x%x then 0x%x is position 0%o, wanting 0%o",
		      what, first, second, m->after[i].position, position);
		return;
	}
	CHECK(0, "%s: 0x%x then 0x%x is bound to nothing", what, first, second);
}

// A file's text over the built-in mapping, which must be taken.
static void want_read(struct key_map *m, const char *what, const char *text)
{
	char err[KEY_MAP_ERR_MAX];
	key_map_built_in(m);
	++checks;
	if (key_map_read(m, text, err, sizeof err) != 0)
		fail(__LINE__, "%s: refused, saying %s", what, err);
}

// ...and one that must be refused, with muir's own words for it.
static void want_refused(const char *what, const char *text, const char *message)
{
	struct key_map m, before;
	char err[KEY_MAP_ERR_MAX];
	key_map_built_in(&m);
	before = m;
	err[0] = '\0';
	++checks;
	if (key_map_read(&m, text, err, sizeof err) == 0) {
		fail(__LINE__, "%s: taken, and it should not be", what);
		return;
	}
	CHECK(strcmp(err, message) == 0, "%s: said\n        %s\n      wanting\n        %s",
	      what, err, message);
	// **THE WHOLE FILE OR NONE OF IT.**  muir builds a fresh mapping and
	// drops it on an error, so nothing a refused file said is kept; here
	// the trial copy is what does that, and this is the assertion that
	// says it works.  Without it a file whose second line is wrong would
	// leave the first line's binding in force, which is a mapping that is
	// neither the file's nor the built-in one.
	CHECK(memcmp(&m, &before, sizeof m) == 0,
	      "%s: the mapping was changed by a file that was refused", what);
}

static void check_keyboard_mapping(const char *work_dir)
{
	struct key_map m, built;
	char err[KEY_MAP_ERR_MAX];

	// --- the built-in mapping IS muir's default.keys, resolved twice by
	// two programs that share no code.
	key_map_built_in(&built);
	memset(&m, 0, sizeof m);
	++checks;
	if (key_map_read(&m, KEY_DEFAULT_MAPPING, err, sizeof err) != 0) {
		fail(__LINE__, "muir's own default.keys does not parse: %s", err);
	} else {
		CHECK(m.bounds == built.bounds && m.afters == built.afters,
		      "default.keys parses to %u bindings and %u prefixed, where the generated "
		      "tables have %u and %u", m.bounds, m.afters, built.bounds, built.afters);
		unsigned differ = 0;
		for (unsigned i = 0; i < built.bounds; ++i) {
			int found = 0;
			for (unsigned j = 0; j < m.bounds; ++j)
				if (m.bound[j].keysym == built.bound[i].keysym) {
					found = m.bound[j].position == built.bound[i].position
						&& m.bound[j].shifted == built.bound[i].shifted;
					break;
				}
			differ += !found;
		}
		for (unsigned i = 0; i < built.afters; ++i) {
			int found = 0;
			for (unsigned j = 0; j < m.afters; ++j)
				if (m.after[j].first == built.after[i].first
				    && m.after[j].second == built.after[i].second) {
					found = m.after[j].position == built.after[i].position
						&& m.after[j].shifted == built.after[i].shifted;
					break;
				}
			differ += !found;
		}
		CHECK(differ == 0,
		      "%u of muir's own bindings come out differently from the parser than from "
		      "the generator", differ);
		printf("    muir's default.keys, %u bindings and %u prefixed, parsed here and "
		       "resolved in Python by the generator: identical\n", m.bounds, m.afters);
	}

	// --- the built-in mapping itself, on hand-computed positions.  These
	// are MIT's own octal, read off `keyboard.rs`'s TABLE, and they are
	// what says the tables above are not two copies of one mistake.
	want_binding(&built, "the built-in mapping", 0xff1bu, 0143, 0);   // Escape -> Alt Mode
	want_binding(&built, "the built-in mapping", 0xffe3u, 0020, 0);   // Control_L -> Left Control
	want_binding(&built, "the built-in mapping", 0xffe4u, 0026, 0);   // Control_R -> Right Control
	want_binding(&built, "the built-in mapping", 0xfe03u, 0035, 0);   // ISO_Level3_Shift -> Greek
	want_prefixed(&built, "the built-in mapping", 0xff14u, 'g', 0035);
	want_prefixed(&built, "the built-in mapping", 0xff14u, 0xff51u, 0117);  // Left -> Hand Left

	// --- A FILE GOES OVER THE BUILT-IN MAPPING, IT DOES NOT REPLACE IT.
	// One line changes one key and every other keysym keeps what it had,
	// which is the whole point of the file and the thing a reader would
	// otherwise have to take on trust.
	want_read(&m, "one line over the built-in mapping", "key F1 Line\n");
	want_binding(&m, "F1 rebound", 0xffbeu, 0036, 0);
	want_binding(&m, "Escape, which the file said nothing about", 0xff1bu, 0143, 0);
	want_prefixed(&m, "a prefix the file said nothing about", 0xff14u, 'x', 0100);
	CHECK(m.bounds == built.bounds && m.afters == built.afters,
	      "rebinding one keysym changed the count: %u and %u, wanting %u and %u",
	      m.bounds, m.afters, built.bounds, built.afters);

	// A keysym the built-in mapping never named is added, not swapped in.
	want_read(&m, "a keysym the built-in mapping does not name", "key Insert Macro\n");
	want_binding(&m, "Insert", 0xff63u, 0100, 0);
	CHECK(m.bounds == built.bounds + 1, "a new keysym gave %u bindings, wanting %u",
	      m.bounds, built.bounds + 1);

	// ...and so is a prefix pair, with a prefix keysym of its own.
	want_read(&m, "a second prefix key", "prefix Num_Lock g Greek\n");
	want_prefixed(&m, "the new prefix", 0xff7fu, 'g', 0035);
	want_prefixed(&m, "the built-in prefix beside it", 0xff14u, 'g', 0035);
	CHECK(m.afters == built.afters + 1, "a new prefix pair gave %u, wanting %u",
	      m.afters, built.afters + 1);

	// The last line wins, silently, as `BTreeMap::insert` does.
	want_read(&m, "one keysym on two lines", "key Escape Return\nkey Escape Tab\n");
	want_binding(&m, "the second line", 0xff1bu, 0022, 0);

	// --- the grammar.  A `#` is a comment only where a trimmed line
	// STARTS with one, so `key 0x23 #` binds the number sign and is not a
	// line somebody truncated.  The generator's Python is more lenient
	// than this and it does not matter there, `default.keys` having no
	// such line; here it would be a real difference from muir.
	want_read(&m, "a `#` that is a key and not a comment", "key 0x23 #\n");
	want_binding(&m, "the number sign", 0x23u, 0161, 1);
	want_refused("a `#` after a key, which is no comment", "key Escape Return # why\n",
		     "line 1: Return # why is no key of this keyboard");

	// Blank lines, whitespace-only lines, comment lines, tabs, leading and
	// trailing space, and CRLF --- which is what a file edited on a laptop
	// over the card's FAT32 partition arrives as.
	want_read(&m, "comments, blanks, tabs and CRLF",
		  "# a comment\r\n\r\n   \t \r\n\tkey\tF1\tLine\t\r\n   key F2 Tab   \r\n");
	want_binding(&m, "a tabbed line", 0xffbeu, 0036, 0);
	want_binding(&m, "a line with spaces round it", 0xffbfu, 0022, 0);

	// `key` and `prefix` are the only case-sensitive words here; every
	// name after them folds ASCII case.
	want_refused("an upper-case verb", "KEY Escape Return\n",
		     "line 1: KEY is not `key` or `prefix`");
	want_read(&m, "names in any case", "key escape ALT MODE\n");
	want_binding(&m, "a lower-case keysym and an upper-case key", 0xff1bu, 0143, 0);

	// --- `position <octal> [shifted]`, which is the only spelling that
	// reaches every key: position 0 and the second key giving a character
	// have no other name.
	want_read(&m, "a position", "key F1 position 22\n");
	want_binding(&m, "position 22, in OCTAL", 0xffbeu, 022, 0);
	want_read(&m, "a position on the shifted plane", "key F1 position 121 shifted\n");
	want_binding(&m, "position 121 shifted", 0xffbeu, 0121, 1);
	want_refused("a position that is not octal", "key F1 position 99\n",
		     "line 1: position 99: the number is in octal");
	// Two ways to be out of range and muir says them differently: 0o777
	// does not fit the byte a position is, 0o200 does and is past the
	// table.  A parser that reported one for both would pass a check that
	// only tried one of them.
	want_refused("a position past a byte", "key F1 position 777\n",
		     "line 1: position 777: the number is in octal");
	want_refused("a position past the table", "key F1 position 200\n",
		     "line 1: position 200: the table is 128 positions");
	want_refused("a word after a position that is not `shifted`",
		     "key F1 position 5 wobble\n",
		     "line 1: position 5 wobble: `shifted` or nothing after the number");

	// --- LEFT AND RIGHT ARE THE LOWER AND HIGHER POSITION, NOT MIT'S OWN
	// SIDES, and Greek is the one shifting key where those disagree ---
	// MIT's table calls 0o035 Right Greek and muir's `shifting` returns it
	// first.  `input_keys.h` records why; this is what stops somebody
	// correcting it into a disagreement with muir.
	want_read(&m, "both sides of Control and of Greek",
		  "key F1 Left Control\nkey F2 Right Control\n"
		  "key F3 Left Greek\nkey F4 Right Greek\n");
	want_binding(&m, "Left Control", 0xffbeu, 0020, 0);
	want_binding(&m, "Right Control", 0xffbfu, 0026, 0);
	want_binding(&m, "Left Greek, which MIT's table labels Right", 0xffc0u, 0035, 0);
	want_binding(&m, "Right Greek, which MIT's table labels Left", 0xffc1u, 0044, 0);
	// A shifting key with one position answers to either side.
	want_read(&m, "the right of a shifting key that has one position",
		  "key F1 Right Caps Lock\nkey F2 Caps Lock\n");
	want_binding(&m, "Right Caps Lock", 0xffbeu, 0125, 0);
	want_binding(&m, "Caps Lock", 0xffbfu, 0125, 0);

	// --- a keysym is a name, a character, decimal or `0x` hexadecimal,
	// and `0X` is none of them.
	want_read(&m, "a keysym as hexadecimal and as decimal",
		  "key 0x41 Tab\nkey 66 Line\nkey +67 Help\n");
	want_binding(&m, "0x41", 0x41u, 0022, 0);
	want_binding(&m, "66", 66u, 0036, 0);
	want_binding(&m, "+67, which Rust's own parse takes", 67u, 0116, 0);
	want_refused("an upper-case 0X", "key 0X41 Tab\n", "line 1: 0X41 is no keysym");
	want_refused("a keysym past 32 bits", "key 4294967296 Tab\n",
		     "line 1: 4294967296 is no keysym");
	want_refused("a name nothing knows", "key Nosuchsym Tab\n",
		     "line 1: Nosuchsym is no keysym");
	want_refused("a key nothing knows", "key Escape Nosuchkey\n",
		     "line 1: Nosuchkey is no key of this keyboard");
	// `space` is a NAME for a keysym and is no key: the one keysym whose
	// single-character spelling is the separator.
	want_read(&m, "the space keysym by name", "key space Quote\n");
	want_binding(&m, "space", 0x20u, 0120, 0);
	want_refused("space as a key, which it is not", "key F1 space\n",
		     "line 1: space is no key of this keyboard");

	// --- a line that runs out, on both kinds.
	want_refused("a key line with no key", "key Escape\n",
		     "line 1: wants a keysym and what it means, not \"Escape\"");
	want_refused("a bare key line", "key\n",
		     "line 1: wants a keysym and what it means, not \"\"");
	want_refused("a prefix line with no key", "prefix Scroll_Lock g\n",
		     "line 1: wants a keysym and what it means, not \"g\"");
	want_refused("a word that is neither", "bind Escape Return\n",
		     "line 1: bind is not `key` or `prefix`");

	// --- A KEYSYM IS A KEY OR A PREFIX AND NEVER BOTH, checked over the
	// whole mapping after the file rather than a line at a time --- so a
	// file's `key` line collides with a built-in PREFIX and a file's
	// `prefix` line with a built-in KEY.  Neither error carries a line
	// number, the two halves not having to be on one line or in one file.
	want_refused("a key line on the built-in prefix", "key Scroll_Lock Return\n",
		     "Scroll_Lock is bound as a key and used as a prefix");
	want_refused("a prefix line on a built-in key", "prefix Escape g Greek\n",
		     "Escape is bound as a key and used as a prefix");

	// --- the line number is the line, counted from one, whatever came
	// before it.  A file that fails on its fourth line must say four.
	want_refused("the line a file fails on",
		     "# a comment\n\nkey F1 Line\nkey F2 Nosuchkey\n",
		     "line 4: Nosuchkey is no key of this keyboard");

	// --- and a file this program reads off the card, which is the path
	// `S85cadr-terminal` uses.  An absent file is reported by name.
	if (work_dir) {
		char path[512];
		snprintf(path, sizeof path, "%s/terminal.keyboard.mapping.txt", work_dir);
		FILE *f = fopen(path, "w");
		if (f) {
			fputs("# a mapping of this check's own\r\n", f);
			fputs("key F1 Macro\r\n", f);
			fclose(f);
			key_map_built_in(&m);
			++checks;
			if (key_map_read_file(&m, path, err, sizeof err) != 0)
				fail(__LINE__, "%s: refused, saying %s", path, err);
			else
				want_binding(&m, "a file off the disk", 0xffbeu, 0100, 0);
			remove(path);
		}
		snprintf(path, sizeof path, "%s/there-is-no-such-file.txt", work_dir);
		key_map_built_in(&m);
		++checks;
		if (key_map_read_file(&m, path, err, sizeof err) == 0)
			fail(__LINE__, "a file that is not there was read");
		else
			CHECK(strstr(err, path) != NULL && strstr(err, "No such file") != NULL,
			      "an absent mapping file said %s", err);
	}

	// --- AND THE MAPPING REACHES THE MACHINE.  Everything above is about
	// the table; this is the one that says a viewer's key goes through it.
	// F1 is Terminal, 0o040, in the built-in mapping and Return, 0o136,
	// after the file --- so a mapping that was read and then not used
	// would send 0o040 here and be caught.
	struct client c;
	struct key_map rebound;
	key_map_built_in(&rebound);
	++checks;
	if (key_map_read(&rebound, "key F1 Return\n", err, sizeof err) != 0) {
		fail(__LINE__, "the rebinding for the typist was refused: %s", err);
		return;
	}
	if (open_typist_with(&c, &rebound) == 0) {
		send_key(&c, 0xffbeu, 1);
		send_key(&c, 0xffbeu, 0);
		pump(40);
		const uint32_t w[] = { word_of(0136, 0), word_of(0136, 1) };
		want_keys("F1 rebound to Return, through the whole program", w, 2);
		client_close(&c);
		settle();
	}
	// ...and the built-in mapping still gives Terminal to the same key,
	// which is what says the line above measured the FILE and not a
	// program that happens to send 0o136 for everything.
	if (open_typist(&c) == 0) {
		send_key(&c, 0xffbeu, 1);
		send_key(&c, 0xffbeu, 0);
		pump(40);
		const uint32_t w[] = { word_of(0040, 0), word_of(0040, 1) };
		want_keys("F1 under the built-in mapping: Terminal", w, 2);
		client_close(&c);
		settle();
	}
}

static void make_synthetic(uint8_t pic[SCREEN_HEIGHT][SCREEN_WIDTH], unsigned salt)
{
	for (unsigned y = 0; y < SCREEN_HEIGHT; ++y)
		for (unsigned x = 0; x < SCREEN_WIDTH; ++x) {
			// A left margin that grows down the screen, a diagonal,
			// a block of text-like runs, and a single lit pixel in
			// the top-left corner that nothing else can supply.
			const int margin = x < 3 + y / 64;
			const int diagonal = (x + y * 3) % 257 < 5;
			const int runs = y % 17 < 9 && (x / 11 + y / 17 + salt) % 5 == 0;
			const int corner = x == 0 && y == 0;
			pic[y][x] = (uint8_t)((margin || diagonal || runs || corner) ? 1 : 0);
		}
}

// Every other pixel: 768 subrectangles a row, which is where RRE loses and
// Raw has to be the one chosen.
static void make_dither(uint8_t pic[SCREEN_HEIGHT][SCREEN_WIDTH])
{
	for (unsigned y = 0; y < SCREEN_HEIGHT; ++y)
		for (unsigned x = 0; x < SCREEN_WIDTH; ++x)
			pic[y][x] = (uint8_t)((x + y) & 1u);
}

// ---- the keyboard's own boot sequence -----------------------------------
//
// **THE KEYBOARD BOOTS THE MACHINE AND THE MACHINE IS NOT ASKED.**
// `sys/io1/ukbd.lisp`'s `check-boot` runs after every key-down: with the
// Controls and Metas held along with Rubout it sends the cold boot code, and
// with Return the warm one, and the I/O board decodes that word itself.  Then
// `bootflag` holds every key-up back until the next key-down, so that the
// machine has time to read the word.
//
// **EVERY EXPECTED WORD HERE IS HAND-COMPUTED**, as the rest of the keyboard
// checks are: the boot words are written as literals and derived in the
// comment beside them, so that the program's own expression is not what says
// what they are.
//
//     frame                 0o371 << 16              0xF90000
//     bits 15-10 all ones   0o77 << 10               0x00FC00
//     cold, low six bits    0o46                     0x000026  -> 0xF9FC26
//     warm, low six bits    0o62                     0x000032  -> 0xF9FC32
#define BOOT_COLD_WORD 0xF9FC26u
#define BOOT_WARM_WORD 0xF9FC32u

// The keys the chord is typed with, by X11 keysym, in the built-in mapping:
// `Control_L` and `Control_R` are MIT's two Controls, `Alt_L` and `Alt_R` are
// its two Metas --- which is what makes the default sequence Ctrl-Alt-Del ---
// and `Delete` is Rubout.
#define KS_CONTROL_L 0xffe3u
#define KS_CONTROL_R 0xffe4u
#define KS_ALT_L     0xffe9u
#define KS_ALT_R     0xffeau
#define KS_DELETE    0xffffu
#define KS_RETURN    0xff0du
#define KS_SHIFT_L   0xffe1u

// A spelling parsed, for the flag's own grammar.
static int boot_keys_of(const char *spelling, struct key_boot *out, char *why, unsigned n)
{
	return key_boot_parse(spelling, out, why, n);
}

static void check_keyboard_boot(const char *work_dir)
{
	struct client c;
	char why[256];
	struct key_boot b;

	// --- (1) THE KEYS ARE WHERE THE FIRMWARE SAYS THEY ARE.  `check-boot`
	// names its own positions --- "both controls and both metas ... along
	// with rubout or return", control 20 and 26, meta 45 and 165, rubout
	// 23, return 136 --- and MIT's key table has to agree with it, or the
	// sequence is typed at keys that are not the sequence's.
	CHECK(KEY_TABLE[0020].kind == KEY_SHIFT && KEY_TABLE[0020].shift == SH_CONTROL,
	      "position 0o20 is not the left Control");
	CHECK(KEY_TABLE[0026].kind == KEY_SHIFT && KEY_TABLE[0026].shift == SH_CONTROL,
	      "position 0o26 is not the right Control");
	CHECK(KEY_TABLE[0045].kind == KEY_SHIFT && KEY_TABLE[0045].shift == SH_META,
	      "position 0o45 is not the left Meta");
	CHECK(KEY_TABLE[0165].kind == KEY_SHIFT && KEY_TABLE[0165].shift == SH_META,
	      "position 0o165 is not the right Meta");
	CHECK(KEY_POS_RUBOUT == 0023 && KEY_TABLE[0023].kind == KEY_NAMED
	      && strcmp(KEY_TABLE[0023].name, "Rubout") == 0,
	      "position 0o23 is not Rubout");
	CHECK(KEY_POS_RETURN == 0136 && KEY_TABLE[0136].kind == KEY_NAMED
	      && strcmp(KEY_TABLE[0136].name, "Return") == 0,
	      "position 0o136 is not Return");

	// ...and the two words, against the literals above and against the
	// I/O board's own decode, which looks at bits 13-6 and nothing else:
	// ones in 13-10 over zeros in 9-6.  A word that failed that would
	// reach the machine's keyboard register and boot nothing.
	CHECK(key_boot_word(1) == BOOT_COLD_WORD, "the cold boot word is 0x%06x, wanting 0x%06x",
	      key_boot_word(1), BOOT_COLD_WORD);
	CHECK(key_boot_word(0) == BOOT_WARM_WORD, "the warm boot word is 0x%06x, wanting 0x%06x",
	      key_boot_word(0), BOOT_WARM_WORD);
	for (int cold = 0; cold < 2; ++cold) {
		const uint32_t w = key_boot_word(cold);
		CHECK(((w >> 10) & 0xFu) == 0xFu && ((w >> 6) & 0xFu) == 0u,
		      "the %s boot word 0x%06x does not carry the board's own decode: "
		      "bits 13-10 ones over bits 9-6 zeros", cold ? "cold" : "warm", w);
		CHECK((w >> 16) == 0371u,
		      "the %s boot word 0x%06x has the wrong frame and source",
		      cold ? "cold" : "warm", w);
	}

	// --- (2) THE FLAG'S GRAMMAR.  Four spellings and no others, counted,
	// order-insensitive, `ctrl` and `meta` and nothing else --- muir's
	// `BootKeys::parse`, refused in muir's own words.
	static const struct { const char *spelling; unsigned controls, metas; } good[] = {
		{ "ctrl,meta", 1, 1 },
		{ "ctrl,ctrl,meta", 2, 1 },
		{ "ctrl,meta,meta", 1, 2 },
		{ "ctrl,ctrl,meta,meta", 2, 2 },
		// The order does not matter, nor does case or the spaces
		// around a word: the flag is a bag of keys to hold.
		{ "meta,ctrl", 1, 1 },
		{ "meta,ctrl,ctrl", 2, 1 },
		{ " CTRL , Meta ", 1, 1 },
	};
	for (unsigned i = 0; i < sizeof good / sizeof good[0]; ++i) {
		memset(&b, 0, sizeof b);
		const int ok = boot_keys_of(good[i].spelling, &b, why, sizeof why);
		CHECK(ok == 0 && b.controls == good[i].controls && b.metas == good[i].metas,
		      "`%s` read as %u Controls and %u Metas (answer %d), wanting %u and %u",
		      good[i].spelling, b.controls, b.metas, ok, good[i].controls, good[i].metas);
	}
	// ...and everything else refused, with the four named.  `ctrl` alone
	// and `meta` alone are refused because the sequence is both; three of
	// a word is refused because there are only two of each key; and
	// `rubout` is refused because Rubout is never in it --- it is the key
	// the sequence ENDS on and naming it would say the opposite.
	static const char *const refused[] = {
		"ctrl", "meta", "", "ctrl,", "ctrl,ctrl,ctrl,meta", "ctrl,meta,meta,meta",
		"ctrl,alt", "control,meta", "ctrl meta", "ctrl,rubout", "rubout,return"
	};
	for (unsigned i = 0; i < sizeof refused / sizeof refused[0]; ++i) {
		memset(&b, 0xAA, sizeof b);
		why[0] = '\0';
		const int ok = boot_keys_of(refused[i], &b, why, sizeof why);
		CHECK(ok < 0, "`%s` was taken as the keys the boot sequence needs, wanting a "
		      "refusal", refused[i]);
		CHECK(strstr(why, "ctrl,ctrl,meta,meta") != NULL
		      && strstr(why, "is not the keys the boot sequence needs") != NULL,
		      "`%s` was refused with \"%s\", which does not name the four spellings",
		      refused[i], why);
	}
	// ...and the spelling written back is the spelling read, so that a
	// program saying what it is set to says something the flag would take.
	for (unsigned i = 0; i < 4; ++i) {
		char out[32];
		struct key_boot again;
		CHECK(boot_keys_of(good[i].spelling, &b, why, sizeof why) == 0, "unreachable");
		key_boot_spelling(b, out, sizeof out);
		CHECK(strcmp(out, good[i].spelling) == 0,
		      "`%s` writes back as `%s`", good[i].spelling, out);
		CHECK(boot_keys_of(out, &again, why, sizeof why) == 0
		      && again.controls == b.controls && again.metas == b.metas,
		      "`%s` does not read back as itself", out);
	}

	// --- (3) CTRL-ALT-DEL, WHICH IS THE DEFAULT SEQUENCE, AND THE WORD
	// GOES AFTER THE KEY-DOWN'S OWN.  Every key of it is held, so each
	// sends its position down; the boot word follows Rubout's, because
	// `check-boot` runs after the key-down and not instead of it --- the
	// machine sees the key as well as the request.
	if (open_typist(&c) == 0) {
		send_key(&c, KS_CONTROL_L, 1);
		send_key(&c, KS_ALT_L, 1);
		send_key(&c, KS_DELETE, 1);
		pump(60);
		const uint32_t w[] = {
			word_of(020, 0),    // the left Control
			word_of(045, 0),    // the left Meta
			word_of(023, 0),    // Rubout
			BOOT_COLD_WORD      // ...and the boot word after it
		};
		want_keys("Control, Meta and Rubout held: the cold boot word", w, 4);
		// ...and what the firmware did with THAT key, which is what
		// muir's trace says on the line after what the key became.
		CHECK(srv.keys.firmware == KEY_FW_BOOT_COLD,
		      "the firmware answered %d for the key that completed the sequence, "
		      "wanting the cold boot", srv.keys.firmware);

		// ...AND NO KEY-UP GOES UNTIL THE NEXT KEY-DOWN.  `bootflag`
		// is set, and the three releases that follow send nothing at
		// all: a word landing in the keyboard register before the
		// microcode looks at it replaces the one there.
		send_key(&c, KS_DELETE, 0);
		send_key(&c, KS_ALT_L, 0);
		send_key(&c, KS_CONTROL_L, 0);
		pump(60);
		want_keys("the three key-ups behind the boot word: held back", w, 4);
		CHECK(srv.keys.firmware == KEY_FW_HELD_BACK,
		      "the firmware answered %d for a key-up behind the boot word, wanting "
		      "held back", srv.keys.firmware);

		// ...and the next key-DOWN clears the flag, sends its own word,
		// and the key-up after it goes as any key-up does.
		send_key(&c, 'a', 1);
		send_key(&c, 'a', 0);
		pump(60);
		const uint32_t after[] = {
			w[0], w[1], w[2], w[3],
			word_of(0123, 0),   // 'a' down, which clears `bootflag`
			word_of(0123, 1)    // ...and its up, which is no longer held
		};
		want_keys("a key-down after the boot word lets key-ups go again", after, 6);
		CHECK(srv.keys.firmware == KEY_FW_NONE,
		      "the firmware answered %d for an ordinary key-up, wanting nothing",
		      srv.keys.firmware);
		CHECK(srv.keys.boots == 1, "%lu boot words went, wanting 1", srv.keys.boots);
		CHECK(srv.keys.held_back == 3, "%lu key-ups were held back, wanting 3",
		      srv.keys.held_back);
		client_close(&c);
		settle();
	}

	// --- (4) THE OTHER CONTROL, THE OTHER META, AND RETURN, WHICH IS THE
	// WARM BOOT.  The same sequence on the right-hand keys, so that a
	// program that had found only one of each pair is caught.
	if (open_typist(&c) == 0) {
		send_key(&c, KS_CONTROL_R, 1);
		send_key(&c, KS_ALT_R, 1);
		send_key(&c, KS_RETURN, 1);
		pump(60);
		const uint32_t w[] = {
			word_of(026, 0),    // the right Control
			word_of(0165, 0),   // the right Meta
			word_of(0136, 0),   // Return
			BOOT_WARM_WORD
		};
		want_keys("the right-hand Control and Meta with Return: the warm boot word",
			  w, 4);
		client_close(&c);
		settle();
	}

	// --- (5) RUBOUT IS TESTED FIRST, AS THE FIRMWARE TESTS IT.  With both
	// Rubout and Return down the boot is COLD, and the two are pressed
	// before the modifiers so that neither completes the sequence on its
	// own way in.
	if (open_typist(&c) == 0) {
		send_key(&c, KS_DELETE, 1);
		send_key(&c, KS_RETURN, 1);
		send_key(&c, KS_CONTROL_L, 1);
		send_key(&c, KS_ALT_L, 1);
		pump(60);
		const uint32_t w[] = {
			word_of(023, 0), word_of(0136, 0), word_of(020, 0), word_of(045, 0),
			BOOT_COLD_WORD
		};
		want_keys("Rubout and Return both down: the cold word, Rubout tested first",
			  w, 5);
		client_close(&c);
		settle();
	}

	// --- (6) A CHORD WITH TOO FEW CONTROLS HELD DOES NOT BOOT.  With
	// `ctrl,ctrl,meta` set, one Control and a Meta and Rubout send three
	// key-downs and nothing else; the second Control completes it.
	if (open_typist(&c) == 0) {
		CHECK(boot_keys_of("ctrl,ctrl,meta", &b, why, sizeof why) == 0, "unreachable");
		key_boot_set(&srv.keys, b);
		send_key(&c, KS_CONTROL_L, 1);
		send_key(&c, KS_ALT_L, 1);
		send_key(&c, KS_DELETE, 1);
		pump(60);
		const uint32_t w[] = { word_of(020, 0), word_of(045, 0), word_of(023, 0) };
		want_keys("one Control where the setting asks for two: no boot word", w, 3);
		send_key(&c, KS_CONTROL_R, 1);
		pump(60);
		const uint32_t both[] = { w[0], w[1], w[2], word_of(026, 0), BOOT_COLD_WORD };
		want_keys("...and the second Control completes it", both, 5);
		client_close(&c);
		settle();
	}

	// --- (7) AND TOO FEW METAS, WHICH IS THE OTHER HALF OF THE SETTING.
	if (open_typist(&c) == 0) {
		CHECK(boot_keys_of("ctrl,meta,meta", &b, why, sizeof why) == 0, "unreachable");
		key_boot_set(&srv.keys, b);
		send_key(&c, KS_CONTROL_L, 1);
		send_key(&c, KS_ALT_L, 1);
		send_key(&c, KS_DELETE, 1);
		pump(60);
		const uint32_t w[] = { word_of(020, 0), word_of(045, 0), word_of(023, 0) };
		want_keys("one Meta where the setting asks for two: no boot word", w, 3);
		send_key(&c, KS_ALT_R, 1);
		pump(60);
		const uint32_t both[] = { w[0], w[1], w[2], word_of(0165, 0), BOOT_COLD_WORD };
		want_keys("...and the second Meta completes it", both, 5);
		client_close(&c);
		settle();
	}

	// --- (8) HELD KEYS ONLY, WHICH IS muir's RULE AND THE KEYBOARD'S.  A
	// viewer holding Shift sends Rubout on a plane this key has not got,
	// so the Shift is worked around it and the key is TAPPED --- down and
	// up in one breath --- and a tapped key is not down when `check-boot`
	// looks.  On the keyboard itself a Shift defeats the sequence too:
	// the firmware compares whole bytes of its bit map and Shift at 24 and
	// 25 sits in the same byte as the Controls at 20 and 26.
	if (open_typist(&c) == 0) {
		send_key(&c, KS_CONTROL_L, 1);
		send_key(&c, KS_ALT_L, 1);
		send_key(&c, KS_SHIFT_L, 1);
		send_key(&c, KS_DELETE, 1);
		pump(60);
		const uint32_t w[] = {
			word_of(020, 0),    // Control down
			word_of(045, 0),    // Meta down
			word_of(024, 0),    // the Shift the viewer pressed
			word_of(024, 1),    // ...lifted around the tapped key
			word_of(023, 0),    // Rubout, down and up in one breath
			word_of(023, 1),
			word_of(024, 0)     // ...and the Shift put back
		};
		want_keys("Rubout tapped under a held Shift: no boot word", w, 7);
		CHECK(srv.keys.boots == 0, "%lu boot words went for a tapped Rubout, wanting 0",
		      srv.keys.boots);
		client_close(&c);
		settle();
	}

	// --- (9) AND IT IS A SECOND WORD, WHICH ASKS FOR ITS OWN ROOM.  The
	// key-down that completes the sequence has taken the one slot it
	// reserved, so the boot word behind it needs another --- and at a full
	// queue it is refused and counted rather than dropped into nothing.
	// `dropped` is the counter that says a caller pushed what it had not
	// reserved, and it must stay zero.
	{
		struct key_state k;
		key_state_init(&k);
		key_event(&k, KS_CONTROL_L, 1);
		key_event(&k, KS_ALT_L, 1);
		// One free slot: Rubout's own word fits in it and the boot word
		// does not.  The queue is filled with a word that is none of
		// the four, so that a partial push shows as a changed tail.
		const uint32_t filler = word_of(0177, 1);
		k.head = 0;
		k.queue[0] = word_of(020, 0);
		k.queue[1] = word_of(045, 0);
		k.count = KEY_BACKLOG - 1;
		for (unsigned i = 2; i < KEY_BACKLOG - 1; ++i)
			k.queue[i] = filler;
		const unsigned long refused_before = k.refused;
		key_event(&k, KS_DELETE, 1);
		CHECK(key_pending(&k) == KEY_BACKLOG,
		      "Rubout's own word did not take the last slot: %u words waiting",
		      key_pending(&k));
		CHECK(k.queue[KEY_BACKLOG - 1] == word_of(023, 0),
		      "the last slot holds 0x%06x, wanting Rubout's own word",
		      k.queue[KEY_BACKLOG - 1]);
		CHECK(k.dropped == 0, "%lu words were dropped silently, wanting none",
		      k.dropped);
		CHECK(k.refused == refused_before + 1,
		      "%lu refusals for a boot word with no room, wanting 1",
		      k.refused - refused_before);
		CHECK(k.boots == 0 && k.hold_back == 0,
		      "a boot word that was refused set the flag anyway: %lu boots, hold %d",
		      k.boots, k.hold_back);
	}

	// --- (10) THE BOOT WORD IS A WORD LIKE ANY OTHER AND IS PACED LIKE
	// ONE.  It goes onto the same queue and through the same two rules ---
	// the card's handshake and the machine's own interval --- so a
	// sequence typed at a real machine arrives as four words no closer
	// together than any other four.  A boot word that went straight to the
	// card would land on top of Rubout's own word before the machine had
	// read it, which is the exact thing `bootflag` exists to prevent one
	// step further on.
	if (open_typist(&c) == 0) {
		expect_a_real_machine();
		send_key(&c, KS_CONTROL_L, 1);
		send_key(&c, KS_ALT_L, 1);
		send_key(&c, KS_DELETE, 1);
		pace(300, INPUT_KEY_INTERVAL_NS / 20);
		const uint32_t w[] = {
			word_of(020, 0), word_of(045, 0), word_of(023, 0), BOOT_COLD_WORD
		};
		want_got("the boot sequence at a real machine", w, 4);
		CHECK(model.gap_min >= INPUT_KEY_INTERVAL_NS,
		      "two words of the boot sequence arrived %llu ns apart, wanting no closer "
		      "than %llu", (unsigned long long)model.gap_min,
		      (unsigned long long)INPUT_KEY_INTERVAL_NS);
		client_close(&c);
		settle();
	}

	// --- (11) AND THE CHORD TYPED AT THE BOARD'S OWN USB KEYBOARD BOOTS
	// THE MACHINE TOO.
	//
	// **THE HELD-KEY SET IS ONE SET AND NOT ONE A SOURCE.**  There is a
	// single `struct key_state` in the server, and every source puts its
	// keys into it: a viewer's through `KeyEvent` and the board's own
	// keyboard through the input link, which `cadr-usb-input` writes.  So
	// `check-boot` sees the keys everybody is holding, and a chord held
	// half at the board and half in a window is a chord.  That is the
	// keyboard the machine has: one cable, one shift register, and the
	// machine decodes what is held from the stream on it.
	if (work_dir) {
		char path[128];
		const char *home = getenv("HOME");
		// A Unix socket's path is 108 bytes including the terminator
		// and the mutation runner names a directory after each record,
		// so the socket goes somewhere short and the length is
		// asserted rather than hoped for.
		snprintf(path, sizeof path, "%.80s/.cache/kbdt-%u",
			 home && *home ? home : work_dir, (unsigned)getpid());
		if (strlen(path) >= 100) {
			printf("--- the boot sequence over the input link: skipped, the socket's "
			       "path would be %u characters\n", (unsigned)strlen(path));
		} else if (open_typist(&c) == 0) {
			unlink(path);
			srv.input = &face;
			if (screen_server_link(&srv, path) < 0) {
				fail(__LINE__, "no input link at %s", path);
			} else {
				struct cadr_input_link_client link;
				const char *link_why = NULL;
				link.fd = -1;
				if (cadr_input_link_open(&link, path, &link_why) < 0) {
					fail(__LINE__, "the link client could not attach: %s",
					     link_why ? link_why : "?");
				} else {
					for (unsigned k = 0; k < 8 && !link.greeted; ++k) {
						pump(2);
						cadr_input_link_greet(&link, &link_why);
					}
					CHECK(link.greeted,
					      "the link client was not greeted: %s",
					      link_why ? link_why : "?");
					model.nkeys = 0;
					// The whole chord from the link, which
					// is a key pressed at the board.
					static const uint32_t chord[] = {
						KS_CONTROL_L, KS_ALT_L, KS_DELETE
					};
					for (unsigned i = 0; i < 3; ++i) {
						struct cadr_input_event e;
						memset(&e, 0, sizeof e);
						e.type = CADR_INPUT_KEY;
						e.down = 1;
						e.keysym = chord[i];
						CHECK(cadr_input_link_send(&link, &e) == 0,
						      "the link would not take key %u", i);
						pump(8);
					}
					pump(60);
					const uint32_t w[] = {
						word_of(020, 0), word_of(045, 0),
						word_of(023, 0), BOOT_COLD_WORD
					};
					want_keys("the chord typed at the board's USB keyboard",
						  w, 4);

					// ...and half at the board and half in a
					// window, which is the same keyboard.
					key_state_init(&srv.keys);
					model.nkeys = 0;
					struct cadr_input_event e;
					memset(&e, 0, sizeof e);
					e.type = CADR_INPUT_KEY;
					e.down = 1;
					e.keysym = KS_CONTROL_L;
					CHECK(cadr_input_link_send(&link, &e) == 0,
					      "the link would not take the Control");
					pump(8);
					send_key(&c, KS_ALT_L, 1);   // ...in the window
					pump(20);
					e.keysym = KS_DELETE;
					CHECK(cadr_input_link_send(&link, &e) == 0,
					      "the link would not take the Rubout");
					pump(60);
					want_keys("a chord held half at the board and half in a "
						  "window", w, 4);
					cadr_input_link_shut(&link);
				}
			}
			client_close(&c);
			settle();
			// The listener is closed with the server at the end of
			// the run; the file goes now so that nothing is left
			// behind if that never happens.
			unlink(path);
		}
	} else {
		printf("--- the boot sequence over the input link: skipped, no --server-log to "
		       "put the socket beside\n");
	}

	// Back to the default for whatever runs after this.
	CHECK(boot_keys_of("ctrl,meta", &b, why, sizeof why) == 0, "unreachable");
	key_boot_set(&srv.keys, b);
}

// **THE TRACE, WHICH IS muir'S OWN LINE.**
//
// `--keyboard-mapping-trace` writes a line for every keysym that arrives and
// what it became, and this holds the WORDING of it: this project's rule that
// a check on a program asserts the line it prints, and here the line IS the
// product --- a trace that named the wrong key would send somebody to fix a
// mapping that is right.
//
// **AND IT IS HELD TO muir's WORDING AND NOT TO ITS OWN.**  Every phrase
// below is `muir::terminal::keyboard`'s `Went` Display, word for word, and
// the shape of the line is `Keyboard::key_traced`'s: the keysym by number and
// by name, down or up, and what it became.  What this adds is where the
// keysym came from, and with no source named the line is muir's exactly ---
// which is the property asserted last.
static void check_keyboard_trace(void)
{
	struct key_state k;
	char line[KEY_TRACE_MAX];

	// --- (1) OFF BY DEFAULT, AND SILENT.  A trace nobody asked for would
	// be a line a keystroke on the board's own console.
	key_state_init(&k);
	CHECK(k.trace == 0, "the trace is on before anything asked for it");
	{
		char *buf = NULL;
		size_t len = 0;
		FILE *was = cadr_log_file();
		FILE *mem = open_memstream(&buf, &len);
		cadr_log_init("  server: ", mem);
		key_event_from(&k, 'a', 1, "a viewer");
		key_event_from(&k, 'a', 0, "a viewer");
		fflush(mem);
		cadr_log_init("  server: ", was);
		CHECK(len == 0, "the trace said something with the trace off: %s", buf ? buf : "");
		fclose(mem);
		free(buf);
	}

	// --- (2) THE EIGHT ANSWERS, each in muir's own words.  The line is
	// handed back as well as printed, which is muir's own arrangement and
	// is why this needs no stream.
	key_state_init(&k);
	key_traced(&k, 1);

	// A key whose plane the viewer already holds: pressed, and named as a
	// mapping file would name it.
	key_event_traced(&k, 'a', 1, "a viewer", line, sizeof line);
	CHECK(strcmp(line, "keysym 0x61 a down from a viewer, a") == 0,
	      "a plain letter from a viewer traced as: %s", line);
	key_event_traced(&k, 'a', 0, "a viewer", line, sizeof line);
	CHECK(strcmp(line, "keysym 0x61 a up from a viewer, a") == 0,
	      "a plain letter's release traced as: %s", line);

	// A character whose plane the viewer is not holding: the Shift is
	// worked around the key, and the line says so rather than calling it a
	// plain press.
	key_event_traced(&k, '!', 1, "a viewer", line, sizeof line);
	CHECK(strcmp(line, "keysym 0x21 ! down from a viewer, !, "
		     "tapped with the shift worked around it") == 0,
	      "a shifted character traced as: %s", line);
	// ...and its release is owed to nobody, the key having gone whole.
	key_event_traced(&k, '!', 0, "a viewer", line, sizeof line);
	CHECK(strcmp(line, "keysym 0x21 ! up from a viewer, nothing: its key was tapped "
		     "and has gone already") == 0,
	      "the release of a tapped key traced as: %s", line);

	// A shifting key is a key at a position of its own, and is named as
	// one: `Left Control` and not `Control`, which is what tells a mapping
	// that collapsed the pair from one that did not.
	key_event_traced(&k, KS_CONTROL_L, 1, "the input link", line, sizeof line);
	CHECK(strcmp(line, "keysym 0xffe3 Control_L down from the input link, "
		     "Left Control") == 0,
	      "a modifier from the input link traced as: %s", line);
	key_event_traced(&k, KS_CONTROL_L, 0, "the input link", line, sizeof line);
	CHECK(strcmp(line, "keysym 0xffe3 Control_L up from the input link, Left Control") == 0,
	      "a modifier's release traced as: %s", line);

	// A keysym the mapping has nothing for: the answer to `why does this
	// key do nothing`, and the reason the trace exists.  `Home` is one of
	// the keys muir's own mapping reaches only behind the prefix, so it is
	// named and unbound both, which is the pair worth pinning.
	key_event_traced(&k, 0xff50u, 1, "a viewer", line, sizeof line);
	CHECK(strcmp(line, "keysym 0xff50 Home down from a viewer, no binding") == 0,
	      "an unbound keysym traced as: %s", line);

	// The prefix, which sends nothing of its own --- and saying so is the
	// point, since printing nothing would look exactly like `no binding`.
	key_event_traced(&k, 0xff14u, 1, "a viewer", line, sizeof line);
	CHECK(strcmp(line, "keysym 0xff14 Scroll_Lock down from a viewer, held as a prefix; "
		     "the keysym after it is looked up behind it") == 0,
	      "a prefix traced as: %s", line);
	key_event_traced(&k, '1', 1, "a viewer", line, sizeof line);
	CHECK(strcmp(line, "keysym 0x31 1 down from a viewer, behind Scroll_Lock: Roman I") == 0,
	      "a key behind the prefix traced as: %s", line);
	// ...and a pair the mapping does not name, which is a different thing
	// from a keysym with no binding of its own.
	key_event_traced(&k, 0xff14u, 1, "a viewer", line, sizeof line);
	key_event_traced(&k, '9', 1, "a viewer", line, sizeof line);
	CHECK(strcmp(line, "keysym 0x39 9 down from a viewer, behind Scroll_Lock: "
		     "no binding") == 0,
	      "an unbound pair behind the prefix traced as: %s", line);
	// The prefix pressed again, which is the way out of a sequence begun by
	// mistake.
	key_event_traced(&k, 0xff14u, 1, "a viewer", line, sizeof line);
	key_event_traced(&k, 0xff14u, 1, "a viewer", line, sizeof line);
	CHECK(strcmp(line, "keysym 0xff14 Scroll_Lock down from a viewer, the prefix is let go, "
		     "and nothing is sent") == 0,
	      "the prefix let go traced as: %s", line);

	// --- (3) A KEYSTROKE THE QUEUE HAD NO ROOM FOR, which is a character
	// that does not type.  **Said, and not folded into a press**: a trace
	// that called this sent would be asserting the opposite of what
	// happened to the one person reading it for exactly this.
	{
		struct key_state full;
		key_state_init(&full);
		key_traced(&full, 1);
		// The backlog filled: one key down and up, over and over, which
		// is two words a time and is what a machine that has stopped
		// reading its keyboard leaves behind.  **A key held down cannot
		// fill it** --- a press of a key that is already down queues
		// nothing --- so the release is what makes each pass count.
		for (unsigned i = 0; i < KEY_BACKLOG; ++i)
			key_event(&full, 'a', (int)(i % 2u) == 0);
		CHECK(key_pending(&full) == KEY_BACKLOG,
		      "the queue is %u words and not the %u the backlog is",
		      key_pending(&full), (unsigned)KEY_BACKLOG);
		// **AND THE KEY IS WRITTEN AS A POSITION HERE, WHICH IS muir'S
		// OWN RULE AND NOT A SLIP.**  `(` is on two keys --- shifted at
		// `0o71` and unshifted at `0o132` --- and with no shift held it
		// is the unshifted one that is chosen, whose name `(` would read
		// back as the OTHER key.  `key_written` writes a name only when
		// reading it back gives this key again, so a mapping file could
		// be written from this line.
		key_event_traced(&full, '(', 1, "a viewer", line, sizeof line);
		CHECK(strcmp(line, "keysym 0x28 ( down from a viewer, position 132 refused: "
			     "the queue is full, 256 words the machine has not read") == 0,
		      "a refused keystroke traced as: %s", line);
	}

	// --- (4) WHAT THE KEYBOARD'S OWN FIRMWARE DID, which is muir's
	// `Firmware` and is said after what the key became: a key-up held back
	// behind a boot word did nothing by design, and a line calling it sent
	// would be the opposite of the truth.
	{
		struct key_state boot;
		key_state_init(&boot);
		key_traced(&boot, 1);
		key_event_traced(&boot, KS_CONTROL_L, 1, NULL, line, sizeof line);
		key_event_traced(&boot, KS_ALT_L, 1, NULL, line, sizeof line);
		key_event_traced(&boot, KS_DELETE, 1, NULL, line, sizeof line);
		CHECK(strcmp(line, "keysym 0xffff Delete down, Rubout, and the boot sequence is "
			     "complete: the cold boot word goes after it") == 0,
		      "the key that completes the boot sequence traced as: %s", line);
		key_event_traced(&boot, KS_DELETE, 0, NULL, line, sizeof line);
		CHECK(strcmp(line, "keysym 0xffff Delete up, Rubout held back: no key-up goes "
			     "until the next key-down, so that the machine reads the boot word "
			     "first") == 0,
		      "the key-up held back behind the boot word traced as: %s", line);
	}

	// --- (5) WITH NO SOURCE NAMED THE LINE IS muir'S EXACTLY, which is
	// the property that makes somebody who has read one machine's trace
	// able to read the other's.  `../muir/src/terminal/keyboard.rs`'s
	// `key_traced`: `keysym {:#x} {name} {down|up}, {went}`.
	key_state_init(&k);
	key_traced(&k, 1);
	key_event_traced(&k, 'B', 1, NULL, line, sizeof line);
	CHECK(strcmp(line, "keysym 0x42 B down, B, tapped with the shift worked around it") == 0,
	      "muir's own line, with no source, came out as: %s", line);
	CHECK(strstr(line, " from ") == NULL,
	      "a line with no source named one anyway: %s", line);

	// --- (6) THE SIGNALS SWITCH IT WHILE THE PROGRAM RUNS.  SIGUSR1 on,
	// SIGUSR2 off, acted on where the program's loop calls
	// `key_trace_apply` --- and the line is said only when it CHANGES, so
	// that `cadr-console trace-keys on` twice is not two lines.
	{
		struct key_state sw;
		char *buf = NULL;
		size_t len = 0;
		FILE *was = cadr_log_file();
		FILE *mem = open_memstream(&buf, &len);
		key_state_init(&sw);
		key_trace_signals();
		cadr_log_init("  server: ", mem);

		raise(SIGUSR1);
		key_trace_apply(&sw);
		CHECK(sw.trace == 1, "SIGUSR1 did not turn the trace on");
		key_event_from(&sw, 'a', 1, "a viewer");
		fflush(mem);
		CHECK(strstr(buf ? buf : "", "keysym 0x61 a down from a viewer, a") != NULL,
		      "after SIGUSR1 no traced line appeared: %s", buf ? buf : "");
		const size_t after_on = len;
		// Asked again: nothing said, and nothing changed.
		raise(SIGUSR1);
		key_trace_apply(&sw);
		fflush(mem);
		CHECK(len == after_on, "a second SIGUSR1 said something: %s", buf + after_on);

		raise(SIGUSR2);
		key_trace_apply(&sw);
		CHECK(sw.trace == 0, "SIGUSR2 did not turn the trace off");
		fflush(mem);
		const size_t after_off = len;
		key_event_from(&sw, 'b', 1, "a viewer");
		key_event_from(&sw, 'b', 0, "a viewer");
		fflush(mem);
		CHECK(len == after_off, "a key was traced after SIGUSR2: %s", buf + after_off);
		cadr_log_init("  server: ", was);
		fclose(mem);
		free(buf);
	}
}

int main(int argc, char **argv)
{
	// A viewer that is dropped mid-write must not take the check with it:
	// write(2) on a socket the server has closed raises SIGPIPE, whose
	// default is to end the process.
	signal(SIGPIPE, SIG_IGN);
	const char *screens = NULL, *server_log = NULL;
	for (int k = 1; k < argc; ++k) {
		if (strcmp(argv[k], "--screens") == 0 && k + 1 < argc)
			screens = argv[++k];
		else if (strcmp(argv[k], "--server-log") == 0 && k + 1 < argc)
			server_log = argv[++k];
	}
	FILE *logf = stdout;
	if (server_log) {
		logf = fopen(server_log, "w");
		if (!logf) {
			fprintf(stderr, "screen_test: %s: %s\n", server_log, strerror(errno));
			return 1;
		}
	}
	cadr_log_init("  server: ", logf);

	// Where a check may write a file of its own: beside the server's log,
	// which the Makefile puts under ~/.cache.  No option of its own,
	// because there is nothing to choose --- a second path to pass would
	// be a second thing to get wrong.  Without `--server-log` the mapping
	// checks that need a real file are skipped and the rest still run.
	char work[512];
	const char *work_dir = NULL;
	if (server_log) {
		snprintf(work, sizeof work, "%s", server_log);
		char *slash = strrchr(work, '/');
		if (slash) {
			*slash = '\0';
			work_dir = work;
		}
	}

	if (screen_server_bind(&srv, "127.0.0.1", 0) < 0) {
		fprintf(stderr, "screen_test: no socket\n");
		return 1;
	}
	port = screen_server_port(&srv);
	screen_frame_init(&frame, 0);
	printf("screen_test: RFB on 127.0.0.1:%u, %ux%u, %u words a line, %u visible words\n",
	       port, SCREEN_WIDTH, SCREEN_HEIGHT, SCREEN_WORDS_PER_LINE, SCREEN_VISIBLE_WORDS);
	if (server_log)
		printf("screen_test: the server's own log is %s\n", server_log);

	printf("--- the mapping, on hand-computed anchors\n");
	check_anchors(0, 0);
	check_anchors(1, 0);
	check_anchors(0, 1);
	check_anchors(1, 1);

	printf("--- blank screens\n");
	check_blank();

	make_synthetic(pic_a, 0);
	make_synthetic(pic_b, 1);
	make_dither(pic_dither);

	printf("--- a whole screen, pixel for pixel, in five pixel formats\n");
	check_whole_screen(pic_a, 0, "the synthetic screen");
	check_whole_screen(pic_a, 1, "the synthetic screen with MODE BOW set");

	printf("--- a viewer that offers no encoding this server has\n");
	check_unoffered_encodings();

	printf("--- RRE against Raw\n");
	check_rre(pic_a, "the synthetic screen", 1);
	check_rre(pic_dither, "a dither, where RRE loses", 0);

	printf("--- an incremental update, and a frame re-read from the window\n");
	check_incremental(pic_a, pic_b, "the synthetic screens");

	printf("--- the handshakes, and the two ways a viewer is refused\n");
	check_handshakes();

	printf("--- where the screen is served: muir's endpoint grammar\n");
	check_the_endpoint_grammar();

	printf("--- read-only, with no input face\n");
	check_read_only();

	printf("--- the register face\n");
	check_input_face();

	printf("--- the keyboard: muir's mapping onto MIT's own key table\n");
	check_keyboard();

	printf("--- how fast key words may be handed over\n");
	check_key_pacing();

	printf("--- the trace: muir's own line for what a keysym became\n");
	check_keyboard_trace();

	printf("--- the mouse\n");
	check_mouse();

	printf("--- the keyboard mapping, and a file over it\n");
	check_keyboard_mapping(work_dir);

	printf("--- the keyboard's own boot sequence: the chord, the two words, the hold-back\n");
	check_keyboard_boot(work_dir);

	// Back to read-only for the screen checks that follow, which have no
	// business with a keyboard.
	srv.input = NULL;

	printf("--- the whole-screen interval\n");
	check_full_update_interval(pic_a);

	printf("--- a viewer that goes mid-frame\n");
	check_disconnect_mid_frame(pic_a);

	// The real screens: two pictures muir drew of MIT's System 100 band,
	// 25 million microcycles apart, differing only in the blinking cursor.
	if (screens) {
		char pa[512], pb[512];
		snprintf(pa, sizeof pa, "%s/screen-rtl-200000000.png", screens);
		snprintf(pb, sizeof pb, "%s/screen-rtl-225000000.png", screens);
		static uint8_t real_a[SCREEN_HEIGHT][SCREEN_WIDTH];
		static uint8_t real_b[SCREEN_HEIGHT][SCREEN_WIDTH];
		if (png_read(pa, real_a) == 0 && png_read(pb, real_b) == 0) {
			unsigned lit_a = 0, differ = 0;
			for (unsigned y = 0; y < SCREEN_HEIGHT; ++y)
				for (unsigned x = 0; x < SCREEN_WIDTH; ++x) {
					lit_a += real_a[y][x];
					differ += real_a[y][x] != real_b[y][x];
				}
			printf("--- MIT's System 100 band, as muir drew it: %u of %u pixels white, "
			       "%u of them changed by the cursor\n",
			       lit_a, SCREEN_WIDTH * SCREEN_HEIGHT, differ);
			check_whole_screen(real_a, 0, "a real screen");
			check_rre(real_a, "a real screen", 1);
			check_incremental(real_a, real_b, "two real screens, cursor on and off");
			check_disconnect_mid_frame(real_a);
		} else {
			printf("--- no real screens at %s: the check ran on its anchors and its own "
			       "patterns. docs/terminal.md has the three commands that make them\n",
			       screens);
		}
	} else {
		printf("--- no --screens given\n");
	}

	screen_server_close(&srv);
	printf("screen_test: %u checks, %d failures; %lu viewers came and %lu went, "
	       "%lu rectangles Raw for %llu bytes and %lu RRE for %llu, saving %llu; "
	       "%lu key words and %lu pointer movements across the seam\n",
	       checks, bad, srv.connects, srv.drops, srv.rects_raw, srv.sent_raw, srv.rects_rre,
	       srv.sent_rre, srv.saved_by_rre, srv.keys_sent, srv.pointer_moves);
	return bad ? 1 : 0;
}
