// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The keyboard's cable and the mouse's, as Linux drives them over a general
// purpose AXI port.
//
// **THIS FILE IS THE ONE PLACE THE TWO HALVES MEET**, as `serial_face.h` and
// `chaos_face.h` are for the other two cables.  The fabric half is
// `rtl/plumbing/cadr_input_cables.sv` on the fourth page of `M_AXI_GP0`, and
// behind it is `rtl/machine/cadr_io_board.sv` --- the I/O board, held to
// `muir::ioboard` over a scripted trace.  What crosses is what crossed MIT's
// own connectors: a twenty-four-bit word for the keyboard's three 74LS164s,
// and deltas for a quadrature encoder that is in FABRIC and not here.
//
// ## What the seam IS
//
// **A KEY IS A WORD AND NOT A BYTE.**  `muir::terminal::keyboard::up_down`
// builds it: bits 23-19 all ones ("Reserved, must be 1's"), 18-16 the source
// ID `1` which is the new keyboard, bit 8 "1=key up, 0=key down", and the
// low seven bits the POSITION on MIT's table.  There are no modifier bits in
// it at all --- `ukbd.lisp` says why, "All key-encoding, including hacking of
// shifts, will be done in software in the central machine, not in the
// keyboard" --- so shift, control and meta are keys of their own, going down
// and coming up like any other, and the machine tracks them from the stream.
// `input_keys.h` is what turns a viewer's keysym into that stream.
//
// **A MOUSE IS A DELTA AND NOT A POSITION.**  The card takes seven lines,
// four quadrature and three switches, and the encoder that turns a delta
// into phases is fabric beside it --- a step is 16,000 ns of the machine's
// own time, so a program making phases would be writing fifty thousand
// times a second.  What is written here is a two's complement dx and dy,
// ADDED to what the fabric still owes, and a button mask that is a LEVEL.
// RFB's own mask needs no translation: `muir::terminal::mouse` says so, left
// 1, middle 2, right 4, which is MIT's `buttons-down-mask` in MIT's order.
//
// ## The registers
//
// Eight words at `IN_REG_BASE`:
//
//    +0x00  0  IDENT    reads "INPT", read-only
//    +0x04  1  STAT     read-only, the bits of `enum in_stat`
//    +0x08  2  KEY      written: bits 23:0, one word for the card's shift
//                       register, queued.  Dropped and counted in `LOST`
//                       when the queue is full, so a program reads `STAT`'s
//                       `IN_ST_ROOM` before it writes.  Read: the word last
//                       HANDED TO THE CARD
//    +0x0C  3  MOUSE    written: bits 11:0 dx, bits 23:12 dy, two's
//                       complement, added to what is owed and saturating.
//                       Read: what is still owed
//    +0x10  4  BUTTONS  bits 2:0, the three switches as a level.  Read back
//    +0x14  5  CTL      bit 0 FLUSH, self-clearing
//    +0x18  6  LOST     read-only, saturating: words dropped for want of room
//    +0x1C  7  LINES    read-only, a diagnostic: bits 6:0 the seven lines the
//                       fabric is driving and bits 23:16 the card's own
//                       status register, for a bring-up on the board
//
// **EVERY ADDRESS IN THE WINDOW MUST BE ANSWERED.**  A read on a GP port
// that nothing answers hangs both Arm cores at one PC each --- measured on
// this board.  So a program runs `cadr_guard()` before it maps anything and
// reads `IDENT` before it believes any other word.
//
// ## FLUSH, AND WHY IT IS THE FIRST THING A PROGRAM DOES
//
// **The machine asks whether anybody is typing four instructions into
// microcode 323.**  `uc-cadr.lisp` at `(LOC 6)` reads the keyboard's status
// register and `(JUMP-IF-BIT-CLEAR (BYTE-FIELD 1 5) MD COLD-BOOT)`: not
// ready is a cold boot, ready is a WARM one --- unless the word in the
// register is the keyboard's own COLD BOOT word, four instructions further
// on, where the microcode reads `764100` and cold-boots on `0o46` in the low
// six bits (`input_keys.h`, the boot sequence).  So a key waiting at that
// register when the microcode starts sends the machine somewhere it was
// never asked to go.
//
// The fabric's own legs against that are in `cadr_input_cables.sv`'s header
// --- nothing but an AXI write can make a strobe, and a machine reset empties
// the queue.  **The leg that belongs to a PROGRAM is this one: write
// `IN_CTL_FLUSH` before you can receive a keystroke.**  `cadr-terminal` does
// it after the guard and before it binds its socket, so a viewer cannot have
// sent anything yet.  A program taking keys from a device the KERNEL has
// been buffering must ALSO drain that device, because the buffering is on the
// far side of this seam and no register here can see it: `cadr-usb-input`
// does, at every device it opens, and `usb_devices.h` says so at the drain.

#ifndef INPUT_FACE_H
#define INPUT_FACE_H

#include <stdint.h>

#define IN_REG_BASE    0x40003000u
#define IN_REG_BYTES   0x1000u
#define IN_IDENT_WORD  0x494E5054u	/* "INPT" */

enum in_reg {
	IN_IDENT = 0, IN_STAT = 1, IN_KEY = 2, IN_MOUSE = 3,
	IN_BUTTONS = 4, IN_CTL = 5, IN_LOST = 6, IN_LINES = 7
};

enum in_stat {
	// `KBD READY` on the card: a word is waiting for the machine to read.
	IN_ST_KBD_READY   = 1u << 0,
	// `MOUSE READY` on the card: a change is waiting.
	IN_ST_MOUSE_READY = 1u << 1,
	// The queue has room for another word.
	IN_ST_ROOM        = 1u << 2,
	// The mouse still owes steps to the card.
	IN_ST_OWES        = 1u << 3
};

// How many words `STAT` says are queued: bits 13:8.
#define IN_ST_QUEUED(st) (((st) >> 8) & 0x3Fu)

enum in_ctl { IN_CTL_FLUSH = 1u << 0 };

// The mouse's three switches, which are RFB's own mask unchanged.
enum in_button {
	IN_BTN_LEFT   = 1u << 0,	/* MOUSE TAILSW */
	IN_BTN_MIDDLE = 1u << 1,	/* MOUSE MIDSW */
	IN_BTN_RIGHT  = 1u << 2		/* MOUSE HEADSW */
};

// The face, reached through two function pointers so that the host test can
// put a model of the RTL behind them and the board puts /dev/mem: the seam
// `pack_side.h`, `console_face.h`, `chaos_face.h` and `serial_face.h` all
// use.
struct input_face {
	uint32_t (*read)(struct input_face *f, unsigned word);
	void (*write)(struct input_face *f, unsigned word, uint32_t v);
	void *ctx;
};

int input_face_open(struct input_face *f, int fd, uint32_t base);
void input_face_close(struct input_face *f);

// IDENT, read and checked.  0, or -1 having said what was there instead ---
// `CADR_IDENT_NONE` for a bitstream with a default slave where this should
// be, which is the common mistake and is named as such.
int input_face_ident(struct input_face *f);

// Empty the queue, abandon what the mouse owes, and lift the switches.  The
// first thing a program does; see the head of this file.
void input_face_flush(struct input_face *f);

uint32_t input_face_stat(struct input_face *f);
uint32_t input_face_lost(struct input_face *f);

// ## HOW FAST WORDS MAY BE HANDED OVER
//
// **THE CARD'S HANDSHAKE IS NOT THE WHOLE RULE, AND THE BOARD PROVED IT.**
// The fabric already hands the card a word only when `KBD READY` is clear ---
// `cadr_input_cables.sv`'s `taking`, which is `muir::terminal::keyboard::
// Keyboard::deliver`'s own gate --- so no word is ever written over one the
// machine has not read.  That gate is about the CARD.  What is behind the
// card is the machine's Unibus channel handler and the software behind
// THAT, and neither of them is in any handshake this seam can see: the
// fabric offers the next word about two ticks after the machine's read of
// the low half clears `KBD READY`, and a machine given its keys twenty
// nanoseconds apart reads them all and digests some of them.
//
// So there are two rules and the fabric implements only the first:
//
//   1. one word in flight --- `input_face_key_idle` below, which is
//      `deliver`'s gate read from this side;
//   2. and successive words no closer than `INPUT_KEY_INTERVAL_NS`, which
//      is muir's `attend` cadence.
//
// **THE INTERVAL IS muir's OWN AND IS NOT TUNED TO A MEASUREMENT.**  muir
// runs `attend` --- and so attempts one `deliver` --- every
// `TERMINAL_CHECK` microcycles, which is 4,096 (`muir src/main.rs`), and a
// microcycle on this board is 15 ticks of 10 ns --- a normal microcycle on
// MIT's 10 ns grid, the read tap and the restart each rounded up.  So the
// interval is 4,096 x 150 ns, and it is the rate at which the reference emulator has
// always fed this same microcode.  muir's own comment at that delivery says
// "a glance every check is far more often than the machine reads it", so this
// is an upper bound on muir's rate and NOT a measured floor of what the
// machine needs --- what recommends it is that the reference has always used
// it and the microcode has always kept up.  The board's own passing
// measurements --- 40 ms between key events, 50 ms between the four words of
// a shifted keystroke --- are thirty-four times more generous, so the
// constant is derived rather than fitted to them; what those measurements
// establish is only that twenty nanoseconds is far too close.
#define INPUT_KEY_MICROCYCLES 4096ull
#define INPUT_KEY_MICROCYCLE_NS 150ull
#define INPUT_KEY_INTERVAL_NS (INPUT_KEY_MICROCYCLES * INPUT_KEY_MICROCYCLE_NS)

// Whether the seam is empty: the fabric holds no word and the card's
// `KBD READY` is clear, so the machine has read everything handed to it and
// the next word will go to a card that is free.  This is
// `Keyboard::deliver`'s `if board.keyboard_ready() { return false }` read
// from the Linux side, with the fabric's own queue counted in as well ---
// a word still in that queue is a word already committed to the card.
int input_face_key_idle(struct input_face *f);

// One word into the card's shift register.  1 if it was queued, 0 if the
// queue was full and the caller should keep it.
int input_face_key(struct input_face *f, uint32_t word);

// A movement, in counts: right and down positive, as `mouse.rs` has them.
// Saturated to the twelve bits the register carries before it is written, so
// a caller that hands over a whole screen's width does not wrap.
void input_face_move(struct input_face *f, int dx, int dy);

// The three switches as a level: `IN_BTN_*` ORed.
void input_face_buttons(struct input_face *f, uint32_t mask);

#endif
