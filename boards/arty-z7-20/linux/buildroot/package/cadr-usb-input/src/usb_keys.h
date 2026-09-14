// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A USB keyboard's key codes and a USB mouse's motion, and what this program
// makes of them.
//
// ## The keyboard, and the one decision in it
//
// **THIS APPLIES THE SHIFT LEVEL ITSELF, AND THAT IS THE WHOLE POINT OF THE
// FILE.**  What crosses the link is a keysym as a VIEWER would send one ---
// already shifted, so Shift and `1` leave here as `exclam` and never as `1`.
// `cadr/cadr_input_link.h` says why: the far end's state machine is written
// for a viewer, and where the plane a keysym wants is not the plane the
// source is holding it works the Shift key AROUND the key.  Hand it the raw
// `1` with Shift held and the machine is given Shift lifted, `1` typed and
// Shift put back --- the user types `!` and the machine sees `1`.
//
// So this is an X server's keymap in miniature.  It is the ONLY place a level
// is chosen, and the far end needs no branch for a USB keyboard.
//
// Three rules about levels, and each is a decision:
//
//   - **Shift selects the second keysym**, either Shift key.
//   - **CAPS LOCK IS NOT APPLIED HERE.**  It is a key at a position of its own
//     on MIT's keyboard --- `KEY_TABLE[0125]`, a shifting key --- and the
//     machine does the locking, because there are no modifier bits in a word
//     and all key encoding is done in software in the central machine.  So it
//     is passed through as a key like any other.  Applying it here as well
//     would lock twice and the two would fight.
//   - **NUM LOCK IS APPLIED, TO THE KEYPAD ALONE**, and starts on.  The
//     keypad's first keysym is what the key means with Num Lock OFF, which is
//     `KP_Home` where the key is printed 7, so without this the keypad would
//     send the keysyms of a cursor pad.  There is no lamp: writing `EV_LED`
//     back to the device would light one, and it would be lighting this
//     program's state rather than the machine's.
//
// There is no third level.  The US layout has none and the right-hand Alt key
// is `Alt_R` there, which muir's mapping makes Right Meta.  Greek and Top are
// reached through the `Scroll_Lock` prefix, which is muir's own answer to a
// keyboard with fewer keys than the CADR's.  One line in the keyboard mapping
// file moves either of them if somebody would rather.
//
// **A KEY COMES UP WITH THE KEYSYM IT WENT DOWN WITH.**  Press Shift, press
// `1`, let Shift go, let `1` go: the release must be `exclam` and not `1`, or
// the far end holds the shifted position down for ever and every character
// after it is wrong.  So what was sent for a key code is remembered until
// that code comes up, and the level is consulted only when a key goes DOWN.
//
// **A REPEAT IS DROPPED.**  evdev's value 2 is the kernel's auto-repeat.  The
// Lisp Machine keyboard has a Repeat key of its own, and a keyboard that sends
// a position twice with no release between is not a keyboard MIT built.
//
// ## The trace, and what it is for
//
// **`--usb-trace` SAYS WHAT EACH KEY BECAME**, one line a key event on the
// log: the device it came from, the key code as the KERNEL names it, the
// level this file chose and why, and the keysym that crossed the link --- or
// that the code is not in the table, which is the answer to "why does this
// key do nothing".  It is `evtest` and the mapping in one line, and it is the
// near half of the road whose far half is the screen's own
// `--keyboard-mapping-trace`: the two together follow a key from the board's
// USB port to MIT's own key position.
//
//     key 30 KEY_A down on /dev/input/event0, no shift: a (keysym 0x61)
//     key 30 KEY_A down on /dev/input/event0, Shift held: A (keysym 0x41)
//     key 183 KEY_F13 down on /dev/input/event0: the code is not in the table
//
// **THE MOUSE IS NOT TRACED.**  A mouse sends a report every few
// milliseconds while it is moving and a line each would be the whole console;
// what a mouse did is in the counters the program already prints.  `evtest`
// on the node is there for anybody who wants the raw stream.
//
// `enum usb_went` is what became of a key, kept as a VALUE that `usb_kbd_key`
// hands back rather than printed where it is decided --- muir's own
// arrangement for its keyboard's trace, and the reason the check can hold the
// wording of all seven answers without a device or a socket.
//
// **AND IT SWITCHES WHILE THE PROGRAM RUNS.** `SIGUSR1` turns it on and
// `SIGUSR2` turns it off, which is what `cadr-console trace-keys on|off`
// sends: a board that had to be restarted to watch a key would lose the
// machine's Lisp to get the line.  The flag is how a run STARTS with it on.
//
// ## The mouse
//
// `REL_X` and `REL_Y` in counts, right and down positive, which is what the
// cable wants: `muir::terminal::mouse`'s convention, and the way `tv:mouse-x`
// and `tv:mouse-y` grow on the machine.  Nothing is negated anywhere.
//
// Motion is accumulated to the end of the kernel's own report --- a mouse
// sends `REL_X`, `REL_Y`, the buttons and then `EV_SYN`/`SYN_REPORT` --- and
// the report goes as one record, which is one write to the fabric instead of
// three.  `REL_WHEEL` and `REL_HWHEEL` go nowhere: the cable has three
// switches and no wheel.
//
// The switches are `BTN_LEFT`, `BTN_MIDDLE` and `BTN_RIGHT` at bits 0, 1 and
// 2, which is RFB's mask and MIT's `buttons-down-mask` in MIT's order, and
// they cross as a LEVEL.

#ifndef USB_KEYS_H
#define USB_KEYS_H

#include <stddef.h>
#include <stdint.h>

#include <cadr/cadr_input_link.h>

// How many keys may be held at once, which is how many releases may be owed.
// Twenty is `KEY_MAX_DOWN` at the far end and is more fingers than anybody
// has; a keyboard reporting more than this holds the rest down, which is why
// the count is the same at both ends.
#define USB_KBD_MAX_DOWN 20

// Key codes this program understands.  evdev numbers keys up to 0x2ff, and
// everything above this is a button, a switch or a media key that no CADR
// keyboard has; the generated table's largest code is far below it.
#define USB_KEY_CODES 256

// **WHAT BECAME OF A KEY EVENT**, which is what `--usb-trace` prints.  Every
// one of these but the first is an event that goes nowhere, and each goes
// nowhere for a reason of its own: a trace that printed nothing for them would
// leave somebody watching a key that does nothing with nothing to read.
enum usb_went {
	// Across the link: the keysym, and on a press the level that chose it.
	USB_WENT_SENT = 0,
	// The kernel's own auto-repeat, value 2.
	USB_WENT_REPEAT,
	// Down with no up between: a device that was not drained, or a release
	// that was lost.  The first press stands.
	USB_WENT_ALREADY_DOWN,
	// More keys are held than this can owe releases for, so the press is
	// refused whole.
	USB_WENT_NO_ROOM,
	// The code has no keysym here: past the codes this program keeps, or
	// simply not in the table the layout gave.
	USB_WENT_NO_KEYSYM,
	// An up for a key this never sent down.
	USB_WENT_NOT_SENT
};

// The longest line the trace writes.  A device node, a key name, a keysym and
// its number, with the longest of the answers above.
#define USB_TRACE_MAX 256

struct usb_kbd_state {
	// Shift, tracked here and ALSO sent as a key.  Both, because the level
	// is chosen here and the machine decodes the stream of positions.
	uint8_t shift_l, shift_r;
	// Num Lock, for the keypad alone.  Starts on; see the header.
	uint8_t numlock;
	// What was sent for a key code, so that the release carries the same
	// keysym the press did.  0 is not a keysym anything sends.
	uint32_t sent[USB_KEY_CODES];
	// The codes held, oldest first, so that what a device owes can be
	// released in the order the machine saw it pressed.
	uint16_t held[USB_KBD_MAX_DOWN];
	unsigned holds;
	// For a status line: codes with no keysym, repeats dropped, and presses
	// refused because more keys were held than this can owe releases for.
	unsigned long unknown, repeats, refused;
	// What became of the last key event, for the trace and for the check:
	// `enum usb_went`, the keysym that crossed, and the level that chose it.
	int went;
	uint32_t went_keysym;
	uint8_t went_level, went_keypad;
};

void usb_kbd_init(struct usb_kbd_state *k);

// One `EV_KEY` event: `value` is 0 up, 1 down, 2 the kernel's repeat.
// 1 with `out` filled in, or 0 for an event that goes nowhere.
int usb_kbd_key(struct usb_kbd_state *k, uint16_t code, int value,
		struct cadr_input_event *out);

// The releases a device owes, oldest first: what must be sent when it is
// unplugged or this program stops.  How many were written, at most `max`.
unsigned usb_kbd_release_all(struct usb_kbd_state *k, struct cadr_input_event *out, unsigned max);

// The keysym a code would send right now, or 0.  For the check, and for the
// line this program says about a key nothing maps.
uint32_t usb_kbd_keysym(const struct usb_kbd_state *k, uint16_t code);

// The kernel's own name for a key code --- `KEY_A` --- or NULL for a code it
// does not name.  `usb_keymap.h`'s `USB_CODE_NAMES`, which covers every code
// the kernel names and not only the ones with a keysym here.
const char *usb_code_name(uint16_t code);

// `--usb-trace`'s line for the key event just given to `usb_kbd_key`, written
// into `out`, which wants `USB_TRACE_MAX` bytes.  `device` is the node it came
// from.  Returned rather than printed so that the check can hold the wording,
// and so that nothing in this file reaches for a log.
//
// **CALLED AFTER `usb_kbd_key` AND ABOUT THAT SAME EVENT**: what it prints is
// the `went` fields that call left behind.
const char *usb_kbd_line(const struct usb_kbd_state *k, const char *device,
			 uint16_t code, int value, char *out, size_t n);

// ---- the mouse -----------------------------------------------------------

struct usb_mouse_state {
	int dx, dy;
	uint8_t buttons;
	// Whether anything has happened since the last report went.
	int moved, switched;
	unsigned long wheels;
};

void usb_mouse_init(struct usb_mouse_state *m);

// One event that is not `EV_SYN`.  `type` and `code` are evdev's.
void usb_mouse_event(struct usb_mouse_state *m, uint16_t type, uint16_t code, int value);

// `SYN_REPORT`: the record for everything since the last one, or 0 if nothing
// happened.  The motion is taken and the switches are left, being a level.
int usb_mouse_report(struct usb_mouse_state *m, struct cadr_input_event *out);

// The record that lifts every switch: what a mouse owes when it is unplugged.
// 0 if it was holding none.
int usb_mouse_release_all(struct usb_mouse_state *m, struct cadr_input_event *out);

#endif
