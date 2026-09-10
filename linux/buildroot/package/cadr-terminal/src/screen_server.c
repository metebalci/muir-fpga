// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The socket and the viewers; `screen_server.h` says what this is and which
// of muir's decisions it keeps.

#include "screen_server.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cadr/cadr_log.h>

// ---- a growable run of bytes -------------------------------------------

struct buf {
	uint8_t *b;
	size_t len, cap, at;	/* `at` is how much of it has gone out */
};

static int buf_room(struct buf *v, size_t more)
{
	if (v->len + more <= v->cap)
		return 0;
	size_t cap = v->cap ? v->cap : 4096;
	while (cap < v->len + more)
		cap *= 2;
	uint8_t *b = realloc(v->b, cap);
	if (!b)
		return -1;
	v->b = b;
	v->cap = cap;
	return 0;
}

static int buf_add(struct buf *v, const void *p, size_t n)
{
	if (buf_room(v, n) < 0)
		return -1;
	memcpy(v->b + v->len, p, n);
	v->len += n;
	return 0;
}

static void buf_reset(struct buf *v)
{
	v->len = 0;
	v->at = 0;
}

// ---- the pixels of a viewer's format ------------------------------------
//
// The screen is one bit a pixel and a pixel is one of two values, so a
// rectangle goes out a frame-buffer BYTE at a time --- a copy out of a table
// --- instead of a pixel at a time, which is a branch on each bit and a fresh
// look at the format's width and byte order.  muir measured that about seven
// times faster over a whole screen and the table is 8 KB at 32 bits a pixel.
// `rfb_put` is the statement of what RFC 6143 section 7.4 asks for, and every
// entry here is built with it.

struct pixels {
	unsigned n;			/* bytes a pixel takes on the wire */
	uint8_t table[256 * 8 * 4];	/* entry b: byte b as eight pixels, bit 0 first */
	uint8_t white[4], black[4];
};

static void pixels_make(struct pixels *px, const struct rfb_format *f)
{
	px->n = rfb_bytes_per_pixel(f);
	if (px->n == 0)
		px->n = 4;
	rfb_put(f, px->white, rfb_white(f));
	rfb_put(f, px->black, rfb_black(f));
	for (unsigned byte = 0; byte < 256; ++byte)
		for (unsigned bit = 0; bit < 8; ++bit)
			memcpy(px->table + (byte * 8 + bit) * px->n,
			       (byte >> bit) & 1u ? px->white : px->black, px->n);
}

static const uint8_t *pixels_eight(const struct pixels *px, uint8_t b)
{
	return px->table + (size_t)b * 8 * px->n;
}

static const uint8_t *pixels_one(const struct pixels *px, int white)
{
	return white ? px->white : px->black;
}

// Byte `k` of row `y`, with `BOW` applied: pixel p is bit p % 8 of byte
// p / 8, and byte k is the k % 4th of word k / 4, from the low end.  This is
// muir's `Pixels::put_row`, whose comment says the same.
static uint8_t row_byte(const struct screen_frame *f, unsigned y, unsigned k)
{
	uint32_t word = f->words[y * f->words_per_line + k / 4];
	if (f->black_on_white)
		word = ~word;
	return (uint8_t)(word >> (k % 4 * 8));
}

// ---- the two encodings ---------------------------------------------------

// Raw, RFC 6143 section 7.7.1: the pixels of the rectangle, left to right and
// top to bottom.  The middle of a row goes eight pixels at a time out of the
// table; the ends, where the rectangle begins or stops inside a byte of the
// frame buffer, go one at a time through `screen_shows_white`, which is where
// the rule about which way round the screen is lives.  A viewer normally asks
// for the whole screen, whose 768 pixels are 96 whole bytes, and then there
// are no ends.
static int encode_raw(struct buf *out, const struct screen_frame *f, const struct pixels *px,
		      unsigned rx, unsigned ry, unsigned rw, unsigned rh)
{
	if (buf_room(out, (size_t)rw * rh * px->n) < 0)
		return -1;
	for (unsigned y = ry; y < ry + rh; ++y) {
		unsigned p = rx;
		const unsigned end = rx + rw;
		while (p < end && p % 8 != 0) {
			memcpy(out->b + out->len, pixels_one(px, screen_shows_white(f->words, p, y, f->black_on_white)), px->n);
			out->len += px->n;
			++p;
		}
		while (p + 8 <= end) {
			memcpy(out->b + out->len, pixels_eight(px, row_byte(f, y, p / 8)), 8 * px->n);
			out->len += 8 * px->n;
			p += 8;
		}
		while (p < end) {
			memcpy(out->b + out->len, pixels_one(px, screen_shows_white(f->words, p, y, f->black_on_white)), px->n);
			out->len += px->n;
			++p;
		}
	}
	return 0;
}

// Which colour the rectangle has more of.
static int rre_background(const struct screen_frame *f, unsigned rx, unsigned ry,
			  unsigned rw, unsigned rh)
{
	unsigned long white = 0;
	for (unsigned y = ry; y < ry + rh; ++y)
		for (unsigned x = rx; x < rx + rw; ++x)
			white += (unsigned)screen_shows_white(f->words, x, y, f->black_on_white);
	return white * 2 >= (unsigned long)rw * rh;
}

// RRE, section 7.7.2: a background pixel and a list of subrectangles of
// everything that is not it.  The screen is two colours, so every
// subrectangle is the other one, and each is one row of a run --- a
// rectangular decomposition that joined runs across rows would be smaller
// still and is not built: this one is a single pass and the measurement says
// it already sends a real screen in a fortieth of Raw.
//
// Counts the subrectangles, and writes them if `out` is not NULL.
static unsigned long rre_walk(struct buf *out, const struct screen_frame *f,
			      const struct pixels *px, unsigned rx, unsigned ry,
			      unsigned rw, unsigned rh, int background)
{
	unsigned long subrects = 0;
	uint8_t head[12];
	for (unsigned y = ry; y < ry + rh; ++y) {
		unsigned x = rx;
		while (x < rx + rw) {
			if (screen_shows_white(f->words, x, y, f->black_on_white) == background) {
				++x;
				continue;
			}
			const unsigned start = x;
			while (x < rx + rw
			       && screen_shows_white(f->words, x, y, f->black_on_white) != background)
				++x;
			++subrects;
			if (!out)
				continue;
			// A subrectangle: the pixel, then x, y, w, h relative
			// to the rectangle, section 7.7.2.
			unsigned n = px->n;
			memcpy(head, pixels_one(px, !background), n);
			head[n + 0] = (uint8_t)((start - rx) >> 8);
			head[n + 1] = (uint8_t)(start - rx);
			head[n + 2] = (uint8_t)((y - ry) >> 8);
			head[n + 3] = (uint8_t)(y - ry);
			head[n + 4] = (uint8_t)((x - start) >> 8);
			head[n + 5] = (uint8_t)(x - start);
			head[n + 6] = 0;
			head[n + 7] = 1;
			if (buf_add(out, head, n + 8) < 0)
				return subrects;
		}
	}
	return subrects;
}

// ---- one viewer ----------------------------------------------------------

enum stage { STAGE_VERSION, STAGE_SECURITY, STAGE_INIT, STAGE_RUNNING };

struct screen_viewer {
	int fd;
	char who[64];
	uint64_t connected_ns;
	uint8_t inbox[4096];
	size_t in_len;
	struct buf out;
	enum stage stage;
	enum rfb_version version;
	struct rfb_format format;
	struct pixels pixels;
	unsigned told_w, told_h;
	// The screen as this viewer last had it, in frame-buffer words.
	uint32_t was[SCREEN_VISIBLE_WORDS];
	int seen;
	// One outstanding request: a viewer that asks again before being
	// answered gets one answer, and the later ask is the one honoured.
	int have_request, incremental;
	unsigned rx, ry, rw, rh;
	uint64_t full_at_ns;
	int have_full_at;
	// Bytes of a `ClientCutText` still to arrive, dropped as they do.
	size_t skip;
	// Whether the viewer named RRE in its `SetEncodings`.
	int takes_rre;
};

static int set_nonblocking(int fd)
{
	const int fl = fcntl(fd, F_GETFL, 0);
	return fl < 0 ? -1 : fcntl(fd, F_SETFL, fl | O_NONBLOCK);
}

static void viewer_free(struct screen_viewer *v)
{
	if (v->fd >= 0)
		close(v->fd);
	free(v->out.b);
	free(v);
}

static void drop(struct screen_server *s, unsigned k, const char *why)
{
	struct screen_viewer *v = s->viewer[k];
	say("viewer %s: gone (%s); %u watching", v->who, why, s->viewers - 1);
	viewer_free(v);
	s->viewer[k] = s->viewer[s->viewers - 1];
	s->viewer[s->viewers - 1] = NULL;
	--s->viewers;
	++s->drops;
}

// ---- the handshake and the messages --------------------------------------

// Answers what the viewer has said, as far as its bytes go.  0 to keep it,
// -1 to drop it, with *why said.
static int viewer_step(struct screen_server *s, struct screen_viewer *v, const char **why)
{
	for (;;) {
		if (v->skip) {
			const size_t n = v->skip < v->in_len ? v->skip : v->in_len;
			memmove(v->inbox, v->inbox + n, v->in_len - n);
			v->in_len -= n;
			v->skip -= n;
			if (v->skip)
				return 0;
		}
		switch (v->stage) {
		case STAGE_VERSION: {
			if (v->in_len < 12)
				return 0;
			v->version = rfb_version_parse(v->inbox);
			uint8_t sec[4];
			int read_back = 0;
			const unsigned n = rfb_security(v->version, sec, &read_back);
			buf_add(&v->out, sec, n);
			memmove(v->inbox, v->inbox + 12, v->in_len - 12);
			v->in_len -= 12;
			v->stage = read_back ? STAGE_SECURITY : STAGE_INIT;
			break;
		}
		case STAGE_SECURITY: {
			if (v->in_len < 1)
				return 0;
			const uint8_t chose = v->inbox[0];
			memmove(v->inbox, v->inbox + 1, v->in_len - 1);
			--v->in_len;
			if (chose != 1) {
				// Section 7.1.3: say it failed, with a reason
				// for a 3.8 viewer, and close.
				if (rfb_wants_security_result(v->version)) {
					uint8_t m[128];
					const size_t n = rfb_security_failed(m,
						"only security type 1, None, is offered");
					buf_add(&v->out, m, n);
				}
				*why = "asked for a security type that is not offered";
				return -1;
			}
			if (rfb_wants_security_result(v->version)) {
				const uint8_t ok[4] = { 0, 0, 0, 0 };
				buf_add(&v->out, ok, 4);
			}
			v->stage = STAGE_INIT;
			break;
		}
		case STAGE_INIT: {
			if (v->in_len < 1)
				return 0;
			// ClientInit's one byte is shared-flag, section 7.3.1;
			// this server serves every viewer either way.
			memmove(v->inbox, v->inbox + 1, v->in_len - 1);
			--v->in_len;
			uint8_t init[24 + sizeof SCREEN_NAME];
			const size_t n = rfb_server_init(init, (uint16_t)SCREEN_WIDTH,
							 (uint16_t)SCREEN_HEIGHT, SCREEN_NAME);
			buf_add(&v->out, init, n);
			v->told_w = SCREEN_WIDTH;
			v->told_h = SCREEN_HEIGHT;
			v->stage = STAGE_RUNNING;
			say("viewer %s: %s, %ux%u, 32 bits a pixel until it asks otherwise",
			    v->who,
			    v->version == RFB_V3_8 ? "RFB 3.8" :
			    v->version == RFB_V3_7 ? "RFB 3.7" : "RFB 3.3",
			    v->told_w, v->told_h);
			break;
		}
		case STAGE_RUNNING: {
			struct rfb_message m;
			size_t used = 0;
			const int got = rfb_parse(v->inbox, v->in_len, &m, &used, why);
			if (got == 0)
				return 0;
			if (got < 0)
				return -1;
			memmove(v->inbox, v->inbox + used, v->in_len - used);
			v->in_len -= used;
			switch (m.kind) {
			case RFB_SET_PIXEL_FORMAT:
				if (!rfb_format_fits(&m.format)) {
					static char complaint[128];
					snprintf(complaint, sizeof complaint,
						 "%u bits a pixel with shifts %u, %u and %u",
						 m.format.bits_per_pixel, m.format.red_shift,
						 m.format.green_shift, m.format.blue_shift);
					*why = complaint;
					return -1;
				}
				v->format = m.format;
				pixels_make(&v->pixels, &v->format);
				if (!v->format.true_colour) {
					uint8_t map[RFB_COLOUR_MAP_BYTES];
					rfb_colour_map(map);
					buf_add(&v->out, map, sizeof map);
				}
				// The viewer has changed what a pixel means, so
				// what it was sent before says nothing about
				// what it now holds.
				v->seen = 0;
				break;
			case RFB_SET_ENCODINGS:
				v->takes_rre = 0;
				for (unsigned k = 0; k < m.encoding_count; ++k)
					if (m.encodings[k] == RFB_ENCODING_RRE)
						v->takes_rre = 1;
				break;
			case RFB_UPDATE_REQUEST:
				v->have_request = 1;
				v->incremental = m.incremental;
				v->rx = m.x;
				v->ry = m.y;
				v->rw = m.w;
				v->rh = m.h;
				break;
			case RFB_KEY:
			case RFB_POINTER:
				// Read-only: counted and dropped.  The line is
				// said once for the program, not once a viewer,
				// because a room of viewers all moving a mouse
				// would otherwise write a line each.
				++s->input_events;
				if (!s->said_input) {
					s->said_input = 1;
					say("a viewer sent a key or pointer event: this server is READ-ONLY and drops them. "
					    "The CADR's keyboard and mouse are the I/O board's, which is not in the fabric");
				}
				break;
			case RFB_CUT_TEXT:
				// A clipboard has nowhere to go on a CADR, and
				// the length is the viewer's 32 bits, so it is
				// never held whole.
				v->skip = m.len;
				break;
			}
			break;
		}
		}
	}
}

// ---- answering a request -------------------------------------------------

// Which of the first `height` rows differ from what the viewer was last sent,
// as runs of consecutive rows.  A row is 24 words, so a run of changed rows
// is one rectangle the full width of the screen.  The comparison is against
// what the viewer HAS, and not against a flag on the frame buffer, so a write
// by any route shows up --- the processor's, the disk channel's --- and
// nothing in the fabric has to know a viewer exists.
struct run { unsigned row, len; };

static unsigned changed_rows(const struct screen_frame *f, const uint32_t *was, unsigned height,
			     struct run *runs, unsigned max)
{
	unsigned n = 0;
	for (unsigned row = 0; row < height; ++row) {
		const unsigned at = row * f->words_per_line;
		if (memcmp(f->words + at, was + at, f->words_per_line * sizeof(uint32_t)) == 0)
			continue;
		if (n && runs[n - 1].row + runs[n - 1].len == row) {
			++runs[n - 1].len;
			continue;
		}
		if (n == max)
			return n;
		runs[n].row = row;
		runs[n].len = 1;
		++n;
	}
	return n;
}

static void answer(struct screen_server *s, struct screen_viewer *v,
		   const struct screen_frame *f, uint64_t now_ns)
{
	// Nothing is queued while anything is still draining: a full screen is
	// 2.9 MB at 32 bits a pixel, and a viewer slower than this program
	// would otherwise be sent frames faster than it takes them until the
	// memory ran out.
	if (v->stage != STAGE_RUNNING || v->out.len > v->out.at || !v->have_request)
		return;
	buf_reset(&v->out);

	// The screen is what `ServerInit` said, and the frame is shown as far
	// as that.
	const unsigned width = f->width < v->told_w ? f->width : v->told_w;
	const unsigned height = f->height < v->told_h ? f->height : v->told_h;
	// Clipped to the screen, then to what was asked for.
	const unsigned ax = v->rx < width ? v->rx : width;
	const unsigned ay = v->ry < height ? v->ry : height;
	unsigned aw = width - ax, ah = height - ay;
	if (v->rw < aw)
		aw = v->rw;
	if (v->rh < ah)
		ah = v->rh;

	const int whole = !(v->incremental && v->seen);
	// A viewer asking for the whole screen at every poll would have this
	// program encode it at every poll; one whole screen per frame to a
	// viewer, the request outstanding meanwhile.
	if (whole && v->have_full_at && now_ns - v->full_at_ns < SCREEN_FULL_UPDATE_NS)
		return;

	struct run runs[SCREEN_HEIGHT];
	unsigned n_runs;
	if (whole) {
		runs[0].row = 0;
		runs[0].len = height;
		n_runs = height ? 1 : 0;
	} else {
		n_runs = changed_rows(f, v->was, height, runs, SCREEN_HEIGHT);
	}

	// Each run, clipped to what was asked for.
	struct run rects[SCREEN_HEIGHT];
	unsigned n_rects = 0;
	for (unsigned k = 0; k < n_runs; ++k) {
		const unsigned top = runs[k].row > ay ? runs[k].row : ay;
		unsigned bottom = runs[k].row + runs[k].len;
		if (bottom > ay + ah)
			bottom = ay + ah;
		if (bottom > top && aw > 0) {
			rects[n_rects].row = top;
			rects[n_rects].len = bottom - top;
			++n_rects;
		}
	}

	// An incremental request with nothing to say is left outstanding,
	// which is what RFC 6143 expects: the answer comes when the screen
	// next changes.
	if (n_rects == 0) {
		if (!v->incremental) {
			uint8_t head[4];
			rfb_update_header(head, 0);
			buf_add(&v->out, head, sizeof head);
			v->have_request = 0;
		}
		return;
	}

	uint8_t head[12];
	rfb_update_header(head, (uint16_t)n_rects);
	buf_add(&v->out, head, 4);
	for (unsigned k = 0; k < n_rects; ++k) {
		const unsigned ry = rects[k].row, rh = rects[k].len;
		const size_t raw_bytes = (size_t)aw * rh * v->pixels.n;
		int use_rre = 0, background = 0;
		size_t rre_bytes = 0;
		if (s->rre_offered && v->takes_rre) {
			background = rre_background(f, ax, ry, aw, rh);
			const unsigned long subrects =
				rre_walk(NULL, f, &v->pixels, ax, ry, aw, rh, background);
			rre_bytes = 4 + v->pixels.n + subrects * (v->pixels.n + 8);
			// The smaller of the two, measured and not guessed: a
			// dithered screen is one subrectangle a pixel and goes
			// Raw.
			use_rre = rre_bytes < raw_bytes;
		}
		rfb_rectangle_header(head, (uint16_t)ax, (uint16_t)ry, (uint16_t)aw, (uint16_t)rh,
				     use_rre ? RFB_ENCODING_RRE : RFB_ENCODING_RAW);
		buf_add(&v->out, head, 12);
		if (use_rre) {
			const size_t count_at = v->out.len;
			uint8_t start[8];
			memset(start, 0, 4);
			memcpy(start + 4, pixels_one(&v->pixels, background), v->pixels.n);
			buf_add(&v->out, start, 4 + v->pixels.n);
			const unsigned long subrects =
				rre_walk(&v->out, f, &v->pixels, ax, ry, aw, rh, background);
			v->out.b[count_at + 0] = (uint8_t)(subrects >> 24);
			v->out.b[count_at + 1] = (uint8_t)(subrects >> 16);
			v->out.b[count_at + 2] = (uint8_t)(subrects >> 8);
			v->out.b[count_at + 3] = (uint8_t)subrects;
			s->sent_rre += rre_bytes;
			s->saved_by_rre += raw_bytes - rre_bytes;
			++s->rects_rre;
		} else {
			encode_raw(&v->out, f, &v->pixels, ax, ry, aw, rh);
			s->sent_raw += raw_bytes;
			s->declined_rre += rre_bytes;
			++s->rects_raw;
		}
	}
	if (whole) {
		v->full_at_ns = now_ns;
		v->have_full_at = 1;
	}
	// What the viewer now has is what was just encoded --- the same frame,
	// not the one that may arrive while this drains.
	memcpy(v->was, f->words, SCREEN_VISIBLE_WORDS * sizeof(uint32_t));
	v->seen = 1;
	v->have_request = 0;
}

// ---- the socket ----------------------------------------------------------

int screen_server_bind(struct screen_server *s, const char *bind_addr, unsigned port)
{
	memset(s, 0, sizeof *s);
	s->listener = -1;
	s->rre_offered = 1;
	struct sockaddr_in a;
	memset(&a, 0, sizeof a);
	a.sin_family = AF_INET;
	a.sin_port = htons((uint16_t)port);
	if (!bind_addr || !*bind_addr) {
		a.sin_addr.s_addr = htonl(INADDR_ANY);
	} else if (inet_pton(AF_INET, bind_addr, &a.sin_addr) != 1) {
		say("--bind %s is not a dotted quad", bind_addr);
		return -1;
	}
	const int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		say("socket: %s", strerror(errno));
		return -1;
	}
	const int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
	if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) {
		say("binding %s:%u: %s", bind_addr && *bind_addr ? bind_addr : "0.0.0.0", port,
		    strerror(errno));
		close(fd);
		return -1;
	}
	if (listen(fd, 4) < 0) {
		say("listen: %s", strerror(errno));
		close(fd);
		return -1;
	}
	set_nonblocking(fd);
	s->listener = fd;
	return 0;
}

// What port the listener actually took, for a check that asked for 0.
unsigned screen_server_port(const struct screen_server *s)
{
	struct sockaddr_in a;
	socklen_t n = sizeof a;
	if (getsockname(s->listener, (struct sockaddr *)&a, &n) < 0)
		return 0;
	return ntohs(a.sin_port);
}

static void accept_one(struct screen_server *s, uint64_t now_ns)
{
	struct sockaddr_in from;
	socklen_t n = sizeof from;
	const int fd = accept(s->listener, (struct sockaddr *)&from, &n);
	if (fd < 0)
		return;
	char who[64];
	char host[INET_ADDRSTRLEN] = "?";
	inet_ntop(AF_INET, &from.sin_addr, host, sizeof host);
	snprintf(who, sizeof who, "%s:%u", host, ntohs(from.sin_port));
	if (s->viewers == SCREEN_MAX_VIEWERS) {
		say("viewer %s: refused, %u already watching", who, s->viewers);
		++s->refused;
		close(fd);
		return;
	}
	struct screen_viewer *v = calloc(1, sizeof *v);
	if (!v) {
		close(fd);
		return;
	}
	v->fd = fd;
	set_nonblocking(fd);
	const int one = 1;
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
	snprintf(v->who, sizeof v->who, "%s", who);
	v->connected_ns = now_ns;
	v->stage = STAGE_VERSION;
	v->format = RFB_RGB888;
	pixels_make(&v->pixels, &v->format);
	buf_add(&v->out, RFB_VERSION, 12);
	s->viewer[s->viewers++] = v;
	++s->connects;
	say("viewer %s: connected; %u watching", v->who, s->viewers);
}

void screen_server_poll(struct screen_server *s, const struct screen_frame *f,
			int timeout_ms, uint64_t now_ns)
{
	struct pollfd fds[SCREEN_MAX_VIEWERS + 1];
	for (unsigned k = 0; k <= SCREEN_MAX_VIEWERS; ++k) {
		fds[k].fd = -1;
		fds[k].events = 0;
		fds[k].revents = 0;
	}
	fds[0].fd = s->listener;
	fds[0].events = POLLIN;
	fds[0].revents = 0;
	for (unsigned k = 0; k < s->viewers; ++k) {
		fds[k + 1].fd = s->viewer[k]->fd;
		fds[k + 1].events = POLLIN;
		if (s->viewer[k]->out.len > s->viewer[k]->out.at)
			fds[k + 1].events |= POLLOUT;
		fds[k + 1].revents = 0;
	}
	if (poll(fds, s->viewers + 1, timeout_ms) < 0 && errno != EINTR)
		return;
	if (fds[0].revents & POLLIN)
		accept_one(s, now_ns);

	// A viewer dropped below moves the last one into its place, so the
	// pollfd for a viewer is found by its descriptor and not by its index:
	// otherwise the moved viewer is answered with somebody else's events.
	for (unsigned k = 0; k < s->viewers;) {
		struct screen_viewer *v = s->viewer[k];
		short ev = 0;
		for (unsigned j = 1; j <= SCREEN_MAX_VIEWERS; ++j)
			if (fds[j].fd == v->fd) {
				ev = fds[j].revents;
				break;
			}
		const char *why = "the viewer closed the connection";
		int gone = 0;

		if (ev & POLLIN) {
			// A viewer streaming faster than this program polls
			// must not keep the poll here, so one read a pass.
			const ssize_t got = read(v->fd, v->inbox + v->in_len,
						 sizeof v->inbox - v->in_len);
			if (got == 0) {
				gone = 1;
			} else if (got < 0) {
				if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
					why = strerror(errno);
					gone = 1;
				}
			} else {
				v->in_len += (size_t)got;
			}
		} else if (ev & (POLLHUP | POLLERR)) {
			gone = 1;
		}
		// A viewer being refused --- a security type not offered, a
		// message type RFC 6143 gives no length for --- has an answer
		// queued for it, and the write loop below is what sends it.
		// A drop that skipped the write would close on an unsent
		// SecurityResult, which section 7.1.3 requires to arrive.
		if (!gone && viewer_step(s, v, &why) < 0)
			gone = 1;
		if (!gone && v->stage != STAGE_RUNNING
		    && now_ns - v->connected_ns > SCREEN_HANDSHAKE_NS) {
			why = "said nothing in thirty seconds";
			gone = 1;
		}
		if (!gone)
			answer(s, v, f, now_ns);
		// What will go, whether or not poll(2) said so this pass: a
		// fresh answer has to start draining somewhere.  A viewer being
		// refused drains too, once, so that its SecurityResult lands.
		int spin = gone ? 64 : 0;
		while (v->out.len > v->out.at && (!gone || spin-- > 0)) {
			const ssize_t put = write(v->fd, v->out.b + v->out.at,
						  v->out.len - v->out.at);
			if (put > 0) {
				v->out.at += (size_t)put;
				continue;
			}
			if (put < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
				break;
			// A viewer that goes mid-frame: the write fails or the
			// connection is gone, and the half-sent update goes
			// with it.  Nothing is retried and nothing is kept.
			if (!gone)
				why = put < 0 ? strerror(errno) : "the write went nowhere";
			gone = 1;
			break;
		}
		if (v->out.len == v->out.at)
			buf_reset(&v->out);
		if (gone)
			drop(s, k, why);
		else
			++k;
	}
}

void screen_server_close(struct screen_server *s)
{
	for (unsigned k = 0; k < s->viewers; ++k)
		viewer_free(s->viewer[k]);
	s->viewers = 0;
	if (s->listener >= 0)
		close(s->listener);
	s->listener = -1;
}
