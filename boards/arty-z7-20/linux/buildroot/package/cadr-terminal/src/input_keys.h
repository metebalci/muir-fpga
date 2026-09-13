// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A viewer's X11 keysym, and the stream of twenty-four-bit words it becomes.
//
// **THIS IS `muir::terminal::keyboard` IN C, AND DELIBERATELY.**  Two
// programs showing one machine must not disagree about what a key means, so
// the table, the bindings and the decisions are muir's: `input_keymap.h` is
// generated from `keyboard.rs` and `default.keys`, and `input_keys.c` is
// `Keyboard::resolve`, `tap`, `press` and `release` written out.  The
// argument for each of those decisions is in muir's own doc comments and is
// not repeated here; what IS written down here is anything this differs in.
//
// ## What a key is on this keyboard
//
// **There are no modifier bits in a key event.**  The new keyboard --- source
// ID 1, the one with the three 74LS164s --- sends a POSITION going down and
// the same position coming up, and nothing else.  `ukbd.lisp` says why: "All
// key-encoding, including hacking of shifts, will be done in software in the
// central machine, not in the keyboard."  So Shift, Control, Meta, Super,
// Hyper, Top and Greek are keys at positions of their own, and the machine
// works out what was typed from the stream.
//
// The consequence for a viewer is the interesting part, and it is why this
// is a state machine and not a lookup.  RFB gives a keysym per key event,
// already shifted: a viewer that presses shift and `1` sends `Shift_L` down
// and then `!`, not `1`.  The Lisp Machine wants position `0o121` with the
// Shift key down.  Where the viewer's shift state and the plane the keysym
// wants agree, the position is simply pressed; where they do not --- `!` with
// no shift held, `(` with shift held and only the unshifted key free --- the
// Shift key is **worked around the key**: shift down, key down, key up, shift
// up, which is what a typist would have done, and the key's own release is
// then dropped because the terminal has sent it whole already.
//
// ## What could not be mapped, and why
//
// Three things, all of them muir's limits rather than this program's:
//
//   - **A keysym neither bound nor printable ASCII goes nowhere.**  `Home`,
//     `Insert`, `Print`, `Num_Lock`, the arrow keys on their own: muir's
//     `positions` returns an empty list for anything outside `0x20..=0x7e`
//     that no line of `default.keys` names, and nothing goes down the cable.
//     The arrows and the four Roman keys and the two thumbs and the two
//     hands ARE reachable, but only behind the `Scroll_Lock` prefix, which
//     is muir's own answer to a keyboard with fewer keys than this one.
//   - **Position `0o021` is unreachable on purpose.**  MIT's table has
//     plus-minus there, which is not ASCII, so `keyboard.rs` leaves it
//     `Key::None` and no keysym finds it.
//   - **`Left Greek` is position `0o035`, which MIT's table labels RIGHT
//     Greek**, and that is muir's and not a slip here.  `shifting(s)` walks
//     the table upwards and `Left` takes the first position it finds, and
//     Greek is the one shifting key of the seven whose two positions are in
//     the other order --- `0o035` Right and `0o044` Left, where Shift,
//     Control, Meta, Super, Hyper and Top all have Left below Right.  So
//     `ISO_Level3_Shift` reaches the right-hand key and MIT's left-hand one
//     is unreachable by name.  Harmless, both being the same shift to a
//     machine that decodes from the stream, and pinned in the check so that
//     nobody "fixes" it into a disagreement with muir.
//   - **A character on two keys is found on the FIRST of them.**  `(` is
//     shifted at `0o071` and unshifted at `0o132`, and `)` is shifted at
//     `0o171` and unshifted at `0o137`; `positions` returns both in position
//     order and the plane the viewer is holding picks between them, so which
//     key the machine sees depends on whether shift is down.  Both give the
//     same character, so nothing downstream can tell.
//
// And one thing that is NOT a mapping limit and is worth not confusing with
// one: **microcode 323's cold-boot test cannot be reached by typing.**  It
// compares the low six bits of the keyboard word against `0o46`, and on the
// new keyboard `0o46` is the Status key's position, not Rubout's --- Rubout
// is `0o23`.  So "hold Rubout at boot for a cold boot" is the OLD Knight
// keyboard's behaviour and does not happen here.  `input_face.h` has what
// this program does about the test instead.
//
// ## The mapping is a value here, not a table
//
// **`--keyboard-mapping`.**  muir reads a file of `key` and `prefix` lines
// over its built-in map, and so does this: `input_mapping.h` is that file's
// grammar and its parser, and a `struct key_state` carries the mapping it
// resolves against rather than reaching for the generated tables directly.
// `key_state_init` gives it the built-in one, which is what every check and
// every board that has no file on its card uses.  Nothing else about the
// state machine below changed when the file arrived: `positions`,
// `modifier`, `is_prefix` and `after_prefix` ask the mapping instead of the
// table and are otherwise the same functions.

#ifndef INPUT_KEYS_H
#define INPUT_KEYS_H

#include <stdint.h>

#include "input_mapping.h"

// `keyboard::FRAME`: bits 23-19 "Reserved, must be 1's" and 18-16 the source
// ID of the new keyboard.  Every up-down word has `word >> 16 == 0o371`.
#define KEY_FRAME ((037u << 19) | (1u << 16))
// `keyboard::UP`, bit 8: "1=key up, 0=key down".
#define KEY_UP (1u << 8)

// `keyboard::up_down`.
static inline uint32_t key_up_down(unsigned position, int up)
{
	return KEY_FRAME | (up ? KEY_UP : 0u) | (position & 0177u);
}

// How many words wait here while the machine is not reading the keyboard.
// muir's `keyboard::BACKLOG`, and for muir's reason: the keyboard's own
// firmware has a shift register and no queue, so a viewer typing faster than
// the machine reads has to be held somewhere, and the far end is the only
// place with room.  The fabric holds a few more, enough that this need not
// poll at the card's 8 us rate; this is where a burst goes.
#define KEY_BACKLOG 256

// How many keysyms may be down at once, and how many releases may be owed.
// Twenty is more fingers than anyone has; a press beyond it is refused whole
// so that no release is owed for it, which is what `press` does at the
// backlog.
#define KEY_MAX_DOWN 20

struct key_state {
	// What a viewer's keysyms mean here: `Keyboard`'s own `map` field,
	// by value as muir holds it, so that a mapping read at start-up
	// cannot outlive or be outlived by the keyboard using it.
	struct key_map map;
	// Words still to go to the fabric, oldest first.
	uint32_t queue[KEY_BACKLOG];
	unsigned head, count;
	// Positions the viewer has down.
	uint8_t down[KEY_MAX_DOWN];
	unsigned downs;
	// A prefix keysym pressed and not yet answered; 0 for none.  Zero is
	// not a keysym, so it needs no flag of its own.
	uint32_t prefix;
	// Shifting keys held for the one key that follows a prefix.
	uint8_t latched[KEY_MAX_DOWN];
	unsigned latches;
	// Keysyms whose next release is to be dropped, the key having been
	// sent whole already.
	uint32_t tapped[KEY_MAX_DOWN];
	unsigned taps;
	// What this has refused, for a status line: a press beyond the
	// backlog, and a keysym nothing maps.
	unsigned long refused, unbound;
};

// `Keyboard::new`: the built-in mapping.
void key_state_init(struct key_state *k);

// `Keyboard::with_mapping`: a mapping somebody read from a file, copied in.
void key_state_init_with(struct key_state *k, const struct key_map *map);

// A key from the viewer, by X11 keysym, going down or coming up.
// `muir::terminal::keyboard::Keyboard::key`.
void key_event(struct key_state *k, uint32_t keysym, int down);

// How many words are waiting.
unsigned key_pending(const struct key_state *k);

// The oldest word, without taking it.  0 if none is waiting, and 0 is not a
// word this keyboard can produce --- every one of them carries `KEY_FRAME`.
uint32_t key_peek(const struct key_state *k);

// ...and take it.
void key_took(struct key_state *k);

// Every key the viewer has down, released, oldest position first: what a
// viewer going away owes the machine.  Without it a key held when a
// connection drops is a key held for the rest of the run, which on a Lisp
// Machine means a Control that never comes up.
void key_all_up(struct key_state *k);

#endif
