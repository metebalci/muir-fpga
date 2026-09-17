// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The local input link: a second source of keys and mouse movement for the
// one program that writes the keyboard and mouse registers.
//
// **THIS FILE IS THE ONE PLACE THE TWO HALVES MEET**, as `input_face.h` is
// for the fabric's own seam.  `cadr-terminal` listens; `cadr-usb-input`
// connects and sends.  Both are built from this, so the wire format has one
// definition and cannot be two.
//
// ## Why there is a link at all
//
// The input face has one queue, and how fast words may be handed to it is a
// rule about the MACHINE rather than about the card: one word in flight, and
// successive words no closer than muir's own cadence (`input_face.h`).  A rule
// like that needs one pacer.  Two programs writing the face side by side would
// each obey it and the machine would still be given words twice as fast as
// either of them meant.
//
// So one program owns the face and everything else is a SOURCE.  That is
// muir's own arrangement one seam out: there is one `Keyboard` and one
// `Mouse` per machine, up to eight viewers push into the same queue, and
// `attend` is the single place that hands a word to the card.  A viewer is a
// source and not an owner.  This link makes `cadr-usb-input` another source.
//
// `docs/usb-input.md` has the decision in full, and the two shapes that were
// not taken.
//
// ## What crosses it
//
// **KEYSYMS, ALREADY SHIFTED --- and this is the one thing about the link
// that is easy to get wrong.**  A viewer sends the keysym its own keyboard
// produced: Shift and `1` arrive as `exclam`, never as `Shift_L` and `1`.
// `input_keys.c` is written for that, and where the plane a keysym wants is
// not the plane the source is holding it works the Shift key AROUND the key.
// A USB keyboard reports a key and a level separately, so a client sending
// the raw keysym would have Shift held and `1` pressed reach the machine as
// Shift lifted, `1` typed and Shift put back --- the user types `!` and the
// machine sees `1`.  **A client applies the level itself.**  It is an X
// server's keymap in miniature, and it is what lets the far end need no
// branch for a USB keyboard.
//
// A pointer record carries motion in COUNTS, right and down positive, which
// is `muir::terminal::mouse`'s convention and the way `tv:mouse-x` and
// `tv:mouse-y` grow; and the three switches as a LEVEL, left 1, middle 2,
// right 4, which is MIT's `buttons-down-mask` in MIT's order.
//
// ## The exchange
//
// A client opens with eight bytes --- `INLK` and a version --- and the server
// answers with the same eight.  That is so a client can tell this server from
// whatever else may be listening at a path, and so a server can drop
// something that is not a client rather than read its bytes as keystrokes.
// Nothing else ever travels from the server to a client: the link is one way
// after the greeting, and there is nothing a client needs to ask.
//
// Then twelve-byte records, little-endian, encoded byte by byte so that no
// struct layout is on the wire.
//
// ## What a client going away owes
//
// **EVERY KEY IT HELD COMES UP.**  There are no modifier bits in a word on
// this keyboard --- the machine follows the stream of positions --- so a
// Control held by a program that died is a Control held for the rest of the
// machine's run.  The server keeps each client's down keysyms, bounded, and
// releases them through the same path when the connection closes.  A client
// that exits tidily sends its own releases and the set is then empty; this is
// for the one that does not.

#ifndef CADR_INPUT_LINK_H
#define CADR_INPUT_LINK_H

#include <poll.h>
#include <stddef.h>
#include <stdint.h>

// Where the socket is.  /var/run is a tmpfs on this image, so the path is
// gone at every boot and a stale file cannot outlive a crash --- but the
// server unlinks it before binding anyway, because a board is not the only
// place this runs.
#define CADR_INPUT_LINK_PATH "/var/run/cadr-input"

// `INLK`, as `INPT`, `CONS`, `PACK` and `NONE` are printable words elsewhere
// in this project: a link pointed at the wrong socket reads as a word rather
// than as a number nobody recognizes.
#define CADR_INPUT_LINK_MAGIC 0x494E4C4Bu
#define CADR_INPUT_LINK_VERSION 1u
#define CADR_INPUT_LINK_HELLO 8u
#define CADR_INPUT_LINK_MSG 12u

// How many clients at once.  One is the whole of today --- `cadr-usb-input`
// --- and a bound is wanted anyway, so that nothing can take every descriptor
// the terminal has.  Four leaves room for a second input program without
// being a number anybody has to think about.
#define CADR_INPUT_LINK_MAX_CLIENTS 4

// How many keysyms one client may hold at once, which is how many releases it
// can owe.  `KEY_MAX_DOWN` in the terminal is twenty for the same reason:
// more fingers than anybody has.
#define CADR_INPUT_LINK_DOWN_MAX 20

enum cadr_input_type {
	CADR_INPUT_KEY = 1,	// keysym + down
	CADR_INPUT_POINTER = 2	// dx, dy, buttons
};

struct cadr_input_event {
	uint8_t type;		// enum cadr_input_type
	uint8_t down;		// KEY: 1 going down, 0 coming up
	uint8_t buttons;	// POINTER: bits 2:0, a level
	int16_t dx, dy;		// POINTER: counts, right and down positive
	uint32_t keysym;	// KEY: an X11 keysym, already shifted
};

// One record, byte by byte and little-endian.  `decode` answers 0, or -1 on a
// record whose type is neither of the two --- which is a client speaking
// something else and is a reason to drop it, not to guess.
void cadr_input_encode(const struct cadr_input_event *e, uint8_t out[CADR_INPUT_LINK_MSG]);
int cadr_input_decode(const uint8_t in[CADR_INPUT_LINK_MSG], struct cadr_input_event *e);

// ---- the server side, which is the program that owns the face -------------

struct cadr_input_client {
	int fd;
	int greeted;
	uint8_t in[4 * CADR_INPUT_LINK_MSG];
	size_t in_len;
	// What this client holds: keysyms down, and its share of the switches.
	uint32_t down[CADR_INPUT_LINK_DOWN_MAX];
	unsigned downs;
	uint8_t buttons;
};

struct cadr_input_link {
	int listener;
	struct cadr_input_client client[CADR_INPUT_LINK_MAX_CLIENTS];
	unsigned clients;
	// For a status line: clients that came, went, were refused for want of
	// room, and were dropped for saying something this does not understand;
	// and the events that crossed.
	unsigned long connects, drops, refused, rejected, events;
};

// Where a decoded event goes.  Three calls rather than one struct so that the
// far end is written in the vocabulary it already has --- `key_event`,
// `input_face_move`, `input_face_buttons` --- and so the check can put its own
// three functions here.
//
// `buttons` is handed the OR over every client, not one client's mask: the
// machine has one mouse with three switches, and a switch held in one place
// must not be lifted by another letting go.
//
// **AND `event` IS CALLED ONCE FOR EVERY RECORD A CLIENT SENDS, BEFORE THE
// CALLS IT BECOMES, AND FOR NOTHING ELSE.**  A client going away is handed its
// releases through `key` and `buttons` too, and those are the link tidying up
// rather than anybody touching a keyboard, so a far end that wants to know
// that a person at the board did something --- the terminal, which wakes the
// display output for exactly that --- asks here and not there.  A client
// attaching is not a record either.  NULL is allowed.
struct cadr_input_sink {
	void (*key)(void *ctx, uint32_t keysym, int down);
	void (*move)(void *ctx, int dx, int dy);
	void (*buttons)(void *ctx, unsigned mask);
	void (*event)(void *ctx);
	void *ctx;
};

// Bind and listen.  0, or -1 having said why.  A `path` that is NULL is
// `CADR_INPUT_LINK_PATH`.
int cadr_input_link_listen(struct cadr_input_link *l, const char *path);

// Whether anything is attached.  The terminal asks, because a viewer going
// away must not lift a key somebody at the board is holding.
unsigned cadr_input_link_clients(const struct cadr_input_link *l);

// The descriptors to wait on: the listener and every client.  Fills `fds` and
// answers how many it wrote, which is never more than
// `CADR_INPUT_LINK_MAX_CLIENTS + 1`.
unsigned cadr_input_link_pollfds(const struct cadr_input_link *l, struct pollfd *fds, unsigned max);

// Accept what is waiting, read what clients have sent, and call the sink for
// each event.  The `fds` are the caller's own array AFTER poll(2), matched by
// descriptor and not by index, because a client dropped here moves the last
// one into its place.
void cadr_input_link_poll(struct cadr_input_link *l, const struct pollfd *fds, unsigned n,
			  const struct cadr_input_sink *sink);

// Every client's keys released through the sink, every connection closed, and
// the socket unlinked.
void cadr_input_link_close(struct cadr_input_link *l, const struct cadr_input_sink *sink);

// ---- the client side, which is a program with a device --------------------

// **THE GREETING IS WAITED FOR WITHOUT BLOCKING**, and that is not only for
// the check.  A program reading a keyboard must not stop reading it for
// however long a wedged far end takes to answer: the devices are in the same
// poll as this, so the greeting is a state and not a pause.  It also lets a
// check drive both halves in one process, pumping the server between the
// client's steps.
struct cadr_input_link_client {
	int fd;
	uint8_t back[CADR_INPUT_LINK_HELLO];
	unsigned at;
	int greeted;
};

// Connect and send the greeting.  0, or -1 with a short reason in `why` ---
// quiet, because a client retries and a line a second about a terminal that
// has not started yet would be the whole console.
int cadr_input_link_open(struct cadr_input_link_client *c, const char *path, const char **why);

// The answer, as much of it as has arrived.  1 when it is in and is this
// link, 0 while it is still owed, -1 for a connection that has gone or
// answered with something else.
//
// **NOTHING MAY BE SENT UNTIL THIS HAS ANSWERED 1.**  The answer is the only
// thing that tells this server from whatever else may be listening at a path,
// and keystrokes must not be poured into something that is not the machine's
// terminal.
int cadr_input_link_greet(struct cadr_input_link_client *c, const char **why);

// One record.  0, or -1 for a link that must be made again --- a far end that
// has gone gives EPIPE or ECONNRESET, and one that has stopped READING fills
// the socket's buffer and gives EAGAIN.  Both are answered the same way, by
// connecting again, because a record written in halves would put the second
// half in front of the next record.  **A client forgets what it holds when it
// reconnects**, the server having released those keys when the connection
// went: the two sides then agree that nothing is down, and a key still
// physically held gives an up the far end ignores.
int cadr_input_link_send(const struct cadr_input_link_client *c, const struct cadr_input_event *e);

// Closed, and back to the state `cadr_input_link_open` starts from.
void cadr_input_link_shut(struct cadr_input_link_client *c);

#endif
