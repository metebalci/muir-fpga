// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Remote Framebuffer protocol, RFC 6143 --- what a VNC viewer speaks.
//
// RFB is the wire protocol; VNC is the name of the software that speaks it.
// This is the protocol alone: the handshake, the pixel format, the six
// messages a viewer sends and the two the server sends back.  What is on the
// screen and who is connected is `screen_server.h`'s.
//
// The authority is RFC 6143, *The Remote Framebuffer Protocol*, T. Richardson
// and J. Levine, March 2011, which is the protocol MIT never heard of ---
// nothing here is a claim about the CADR.  **It is muir's `src/terminal/rfb.rs`
// in C**, structure for structure and name for name, because muir already
// serves this screen to a viewer and two programs showing one machine must
// not disagree about what a viewer is shown; where this file departs from
// that one it says so at the departure.  It is written from the RFC and not
// from a crate for the reason muir's says: the parts a black-and-white frame
// buffer needs are small.
//
// **TWO ENCODINGS, WHERE muir HAS ONE.**  RFC 6143 section 7.7.1 obliges
// every server to have Raw and every viewer to take it, so Raw is what a
// viewer that offers nothing else gets and is the floor under everything
// here.  RRE, section 7.7.2, is the one that compresses runs: a background
// pixel and a list of subrectangles of the other colour.  muir declined it
// --- "the screen is one bit a pixel and the updates are whole rows, so there
// is nothing here that a run-length encoding would win enough to pay for" ---
// and that was written of a server inside the engine's own process on a
// loopback socket.  This one is on a board at the end of a hundred-megabit
// link, and the measurement is the other way round: a real screen of MIT's
// System 100 band, muir's own at microcycle 200,000,000, is 7,572 lit pixels
// of 739,584, so Raw sends 2,958,336 bytes at 32 bits a pixel and RRE sends
// about a fortieth of that.  **Which one a rectangle goes in is decided by
// measuring both and taking the smaller**, so a screen RRE would lose on ---
// a dither, where every pixel is its own subrectangle at twelve bytes each
// --- goes Raw and costs the comparison and nothing else.
//
// **A PIXEL IS ONE OF TWO VALUES, AND THAT IS THE WHOLE OF THE COLOUR
// HANDLING.**  A viewer may ask for 8, 16 or 32 bits a pixel, either byte
// order, true colour with any shifts, or a colour map; of all that, only
// `rfb_white()` and `rfb_black()` differ, so every format a viewer can ask
// for is answered by computing two pixel values once and copying them.

#ifndef SCREEN_RFB_H
#define SCREEN_RFB_H

#include <stddef.h>
#include <stdint.h>

// RFC 6143 section 7.4: how a viewer wants pixels laid out.
struct rfb_format {
	uint8_t bits_per_pixel;
	uint8_t depth;
	int big_endian;
	int true_colour;
	uint16_t red_max, green_max, blue_max;
	uint8_t red_shift, green_shift, blue_shift;
};

// What the server offers in its `ServerInit`: 32 bits a pixel, eight each of
// red, green and blue in the low three bytes, little-endian.  Viewers may ask
// for something else and this one answers whatever they ask; it is offered
// because it is the format every viewer accepts without asking for another.
extern const struct rfb_format RFB_RGB888;

void rfb_format_encode(const struct rfb_format *f, uint8_t out[16]);
void rfb_format_parse(const uint8_t in[16], struct rfb_format *f);

// Bytes a pixel takes on the wire, or 0 for a width that is not a whole
// number of bytes.  RFC 6143 asks for no such width.
unsigned rfb_bytes_per_pixel(const struct rfb_format *f);

// Whether the format is one a pixel can be written in: a whole number of
// bytes, and shifts that name bits of it.  Section 7.4 gives each shift as
// "the number of shifts needed to get the red value in a pixel to the least
// significant bit", so one at or past the pixel's width names none, and a
// viewer sending such a format is refused as one naming 24 bits a pixel is.
int rfb_format_fits(const struct rfb_format *f);

// Every colour at its maximum, or colour map entry 1 where the viewer wants
// a map; and zero, which is entry 0 either way.
uint32_t rfb_white(const struct rfb_format *f);
uint32_t rfb_black(const struct rfb_format *f);

// One pixel, in as many bytes and whichever order the viewer asked for.
// Writes `rfb_bytes_per_pixel(f)` bytes and returns how many.
unsigned rfb_put(const struct rfb_format *f, uint8_t *out, uint32_t value);

// The colour map entry white takes when a viewer asks for a mapped format.
#define RFB_WHITE_INDEX 1

// `SetColourMapEntries`, section 7.6.2: the two colours this screen has,
// black at 0 and white at 1.  Writes RFB_COLOUR_MAP_BYTES bytes.
#define RFB_COLOUR_MAP_BYTES 18
void rfb_colour_map(uint8_t out[RFB_COLOUR_MAP_BYTES]);

// The version the server offers, section 7.1.1.
#define RFB_VERSION "RFB 003.008\n"

enum rfb_version { RFB_V3_3, RFB_V3_7, RFB_V3_8 };

// Section 7.1.1: "Other version numbers ... should be interpreted as 3.3."
// So anything but 3.7 and 3.8 is 3.3 --- Apple's Screen Sharing, which
// answers `RFB 003.889`, gets 3.3's handshake --- and a viewer that then
// talks something else fails on its next message rather than here.
enum rfb_version rfb_version_parse(const uint8_t b[12]);

// What the server sends once the version is settled, and whether the
// viewer's choice of security type is to be read back.  The only type
// offered is 1, None: section 7.2.1, "no authentication is needed".
// Writes at most 4 bytes; returns how many, and sets *read_back.
unsigned rfb_security(enum rfb_version v, uint8_t out[4], int *read_back);

// Whether a `SecurityResult` follows the viewer's choice.  3.8 only.
int rfb_wants_security_result(enum rfb_version v);

// A failed `SecurityResult`, section 7.1.3: the word 1, "failed", then a
// reason string, after which the server closes the connection.  Returns the
// bytes written into `out`, which must hold 8 + strlen(reason).
size_t rfb_security_failed(uint8_t *out, const char *reason);

// A message from the viewer: RFC 6143 section 7.5.
enum rfb_message_kind {
	RFB_SET_PIXEL_FORMAT,
	RFB_SET_ENCODINGS,
	RFB_UPDATE_REQUEST,
	RFB_KEY,
	RFB_POINTER,
	RFB_CUT_TEXT
};

// How many of a viewer's encoding list is kept.  A viewer may name dozens;
// this server acts on two of them and the rest are a record.
#define RFB_MAX_ENCODINGS 32

struct rfb_message {
	enum rfb_message_kind kind;
	struct rfb_format format;		/* SetPixelFormat */
	int32_t encodings[RFB_MAX_ENCODINGS];	/* SetEncodings */
	unsigned encoding_count;
	int incremental;			/* FramebufferUpdateRequest */
	uint16_t x, y, w, h;
	int down;				/* KeyEvent */
	uint32_t keysym;
	uint8_t buttons;			/* PointerEvent */
	size_t len;				/* ClientCutText */
};

// Takes one message off the front of `buf` and says how many bytes it used.
//
//   1   a message, in *m, having used *used bytes
//   0   the message has not all arrived: keep the bytes and ask again
//  -1   a message this server does not know.  RFC 6143 gives no way to skip
//       one, the length being implied by the type, so the connection has to
//       go; *why points at a description of it.
int rfb_parse(const uint8_t *buf, size_t len, struct rfb_message *m, size_t *used, const char **why);

// `ServerInit`, section 7.3.2: the screen's size, the format offered, and a
// name for the window.  Returns the bytes written; `out` must hold
// 24 + strlen(name).
size_t rfb_server_init(uint8_t *out, uint16_t width, uint16_t height, const char *name);

// The head of a `FramebufferUpdate`, section 7.6.1.
void rfb_update_header(uint8_t out[4], uint16_t rectangles);

// The head of one rectangle: where it is, how big, and which encoding.
#define RFB_ENCODING_RAW 0
#define RFB_ENCODING_RRE 2
void rfb_rectangle_header(uint8_t out[12], uint16_t x, uint16_t y, uint16_t w, uint16_t h,
			  int32_t encoding);

// `Bell`, section 7.6.3: the message type and nothing else.
#define RFB_BELL 2

#endif
