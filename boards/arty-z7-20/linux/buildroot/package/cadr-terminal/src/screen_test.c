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
// worked out by hand from muir `src/simpletv.rs:254-257` and written as
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
// own PNG (`SimpleTv::png`), which is the monitor's picture and not the frame
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
// formats --- 32, 16 and 8 bits, both byte orders, and a colour-mapped one
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

#include "screen_frame.h"
#include "screen_geom.h"
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
// muir src/simpletv.rs:254-257 and :268-270, written out here rather than
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
		// SetColourMapEntries, section 7.6.2: two colours from 0.
		if (client_need(c, 18) == 0 && c->in[0] == 1) {
			CHECK(be16at(c->in + 2) == 0 && be16at(c->in + 4) == 2,
			      "the colour map named %u colours from %u, wanting 2 from 0",
			      be16at(c->in + 4), be16at(c->in + 2));
			CHECK(be16at(c->in + 12) == 0xFFFF,
			      "colour map entry 1 is not white");
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
					fail(__LINE__, "an RRE subrectangle's pixel is neither colour");
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
// `SimpleTv::png` (muir src/simpletv.rs:277) writes 1-bit greyscale, filter
// none on every row, and STORED deflate blocks --- "the encoder is here
// rather than a crate: a 1-bit greyscale PNG is a header, the rows behind
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
				fail(__LINE__, "%s is %u-bit colour type %u interlace %u, not muir's 1-bit greyscale",
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
// Every coordinate below is worked out by hand from muir src/simpletv.rs:255,
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
		{ 8, 8, 0, 0, 0, 0, 0, 0, 0, 0 },		/* a colour map */
	};
	static const char *names[] = { "32bpp little", "32bpp big", "16bpp 5-6-5", "8bpp 2-2-2",
				       "8bpp colour-mapped" };
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
static void check_read_only(void)
{
	struct client c;
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

// ---- the screens the check makes for itself ------------------------------

static uint8_t pic_a[SCREEN_HEIGHT][SCREEN_WIDTH];
static uint8_t pic_b[SCREEN_HEIGHT][SCREEN_WIDTH];
static uint8_t pic_dither[SCREEN_HEIGHT][SCREEN_WIDTH];

// A pattern that is asymmetric in x, in y, and inside a word, so that a
// mirrored screen, an upside-down one and a reversed bit order each come out
// different from it.  It is not a substitute for the anchors, which are what
// actually pin the mapping; it is a screen with something on every line.
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

	printf("--- read-only\n");
	check_read_only();

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
	       "%lu rectangles Raw for %llu bytes and %lu RRE for %llu, saving %llu\n",
	       checks, bad, srv.connects, srv.drops, srv.rects_raw, srv.sent_raw, srv.rects_rre,
	       srv.sent_rre, srv.saved_by_rre);
	return bad ? 1 : 0;
}
