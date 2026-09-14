// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The keyboard's levels and the mouse's arithmetic.  `usb_keys.h` says what
// each decision is and why; `usb_keymap.h` is the table, generated from the X
// keyboard database.
//
// **NOTHING HERE TOUCHES A DEVICE OR A SOCKET.**  It is given events and it
// answers with records, so the whole of it runs in the check with no board, no
// keyboard and no kernel.

#include "usb_keys.h"

#include <stdio.h>
#include <string.h>

#include "usb_keymap.h"

// evdev's own numbers, from linux/input-event-codes.h.  They are written out
// rather than included because this file is built on a host as well as for
// the board, and a check must not depend on the build host's kernel headers
// matching the board's.  The values are ABI: the kernel cannot change them.
#define EV_KEY_T 0x01u
#define EV_REL_T 0x02u
#define REL_X_C 0x00u
#define REL_Y_C 0x01u
#define REL_WHEEL_C 0x08u
#define REL_HWHEEL_C 0x06u
#define BTN_LEFT_C 0x110u
#define BTN_RIGHT_C 0x111u
#define BTN_MIDDLE_C 0x112u
#define KEY_LEFTSHIFT_C 42u
#define KEY_RIGHTSHIFT_C 54u
#define KEY_NUMLOCK_C 69u

static const struct usb_key *lookup(uint16_t code)
{
	for (size_t i = 0; i < USB_KEYS_COUNT; ++i)
		if (USB_KEYS[i].code == code)
			return &USB_KEYS[i];
	return NULL;
}

void usb_kbd_init(struct usb_kbd_state *k)
{
	memset(k, 0, sizeof *k);
	// **ON, so that the keypad sends the digits it is printed with.**  The
	// first keysym of a keypad key is what it means with Num Lock off,
	// which is `KP_Home` where the key says 7.
	k->numlock = 1;
}

uint32_t usb_kbd_keysym(const struct usb_kbd_state *k, uint16_t code)
{
	const struct usb_key *e = lookup(code);
	if (!e)
		return 0;
	// The level.  Shift for everything, and Num Lock for the keypad and
	// nothing else --- the two never apply to one key, the keypad's keys
	// having no shifted plane of their own.
	const int level2 = e->keypad ? (k->numlock != 0)
				     : (k->shift_l || k->shift_r);
	return level2 ? e->shifted : e->plain;
}

// What became of the key event, left behind for `usb_kbd_line`.  muir's own
// arrangement for its keyboard: the answer is a value the caller may read, so
// that the decision and the printing are not the same branch.
static int went(struct usb_kbd_state *k, int what, uint32_t keysym, int level, int keypad)
{
	k->went = what;
	k->went_keysym = keysym;
	k->went_level = (uint8_t)!!level;
	k->went_keypad = (uint8_t)!!keypad;
	return what == USB_WENT_SENT;
}

static void note_held(struct usb_kbd_state *k, uint16_t code)
{
	if (k->holds < USB_KBD_MAX_DOWN)
		k->held[k->holds++] = code;
}

static void drop_held(struct usb_kbd_state *k, uint16_t code)
{
	for (unsigned i = 0; i < k->holds; ++i) {
		if (k->held[i] != code)
			continue;
		memmove(&k->held[i], &k->held[i + 1], (k->holds - i - 1) * sizeof k->held[0]);
		--k->holds;
		return;
	}
}

int usb_kbd_key(struct usb_kbd_state *k, uint16_t code, int value,
		struct cadr_input_event *out)
{
	if (value == 2) {
		// The kernel's auto-repeat.  See the header: this keyboard has
		// a Repeat key of its own and sends no position twice.
		++k->repeats;
		return went(k, USB_WENT_REPEAT, 0, 0, 0);
	}
	if (code >= USB_KEY_CODES) {
		++k->unknown;
		return went(k, USB_WENT_NO_KEYSYM, 0, 0, 0);
	}
	const int down = value != 0;

	// **SHIFT IS TRACKED BEFORE THE LEVEL IS CHOSEN AND SENT LIKE ANY
	// OTHER KEY.**  Before, because a Shift going down must colour the
	// keys after it and not itself; `Shift_L` has one keysym, so its own
	// level cannot matter.
	if (code == KEY_LEFTSHIFT_C)
		k->shift_l = (uint8_t)down;
	else if (code == KEY_RIGHTSHIFT_C)
		k->shift_r = (uint8_t)down;
	else if (code == KEY_NUMLOCK_C && down)
		// A lock turns over on the press and not on the release, which
		// is what every keyboard does.  It is still SENT as a key: the
		// machine has a Num Lock of nothing, and muir's mapping binds
		// it to nothing, so the far end counts it as unmapped --- which
		// is the truth and is better than swallowing it here.
		k->numlock = (uint8_t)!k->numlock;

	memset(out, 0, sizeof *out);
	out->type = CADR_INPUT_KEY;
	out->down = (uint8_t)down;

	if (down) {
		if (k->sent[code]) {
			// Down twice with no up between: a device that was not
			// drained, or one whose release was lost.  The first
			// press stands and this one is dropped, because a
			// second press with no release owes a second release.
			++k->repeats;
			return went(k, USB_WENT_ALREADY_DOWN, k->sent[code], 0, 0);
		}
		if (k->holds >= USB_KBD_MAX_DOWN) {
			// **REFUSED WHOLE.**  A press this cannot remember is
			// a release it could not owe, and a Shift down whose
			// release went nowhere is a Shift held for the rest of
			// the machine's run.
			++k->refused;
			return went(k, USB_WENT_NO_ROOM, 0, 0, 0);
		}
		const uint32_t sym = usb_kbd_keysym(k, code);
		if (!sym) {
			++k->unknown;
			return went(k, USB_WENT_NO_KEYSYM, 0, 0, 0);
		}
		k->sent[code] = sym;
		note_held(k, code);
		out->keysym = sym;
		// The level the keysym came from, for the trace: the same test
		// `usb_kbd_keysym` made, asked again of the same two flags.
		{
			const struct usb_key *e = lookup(code);
			const int pad = e && e->keypad;
			return went(k, USB_WENT_SENT, sym,
				    pad ? k->numlock != 0 : (k->shift_l || k->shift_r), pad);
		}
	}

	// **UP CARRIES THE KEYSYM THE PRESS CARRIED**, not the one the level
	// would give now: Shift let go between the press and the release must
	// not turn `exclam` into `1` and leave the shifted position down.
	const uint32_t sym = k->sent[code];
	if (!sym)
		return went(k, USB_WENT_NOT_SENT, 0, 0, 0);   // never sent down
	k->sent[code] = 0;
	drop_held(k, code);
	out->keysym = sym;
	// **NO LEVEL ON AN UP**, and the line says so rather than naming one: the
	// level was consulted at the press and the release carries what the
	// press carried.
	return went(k, USB_WENT_SENT, sym, 0, 0);
}

const char *usb_code_name(uint16_t code)
{
	for (size_t i = 0; i < USB_CODE_NAME_COUNT; ++i)
		if (USB_CODE_NAMES[i].code == code)
			return USB_CODE_NAMES[i].name;
	return NULL;
}

// What to call the keysym that crossed: the generated name for the plane it
// came from.  A release carries the keysym its press carried, which may be
// either plane, so it is looked for rather than chosen.
static const char *sym_name(uint16_t code, uint32_t keysym)
{
	const struct usb_key *e = lookup(code);
	if (!e)
		return NULL;
	if (keysym == e->plain)
		return e->plain_name;
	if (keysym == e->shifted)
		return e->shifted_name;
	return NULL;
}

const char *usb_kbd_line(const struct usb_kbd_state *k, const char *device,
			 uint16_t code, int value, char *out, size_t n)
{
	const char *kname = usb_code_name(code);
	const char *sym = sym_name(code, k->went_keysym);
	const int down = value != 0;
	char head[128];

	// The head of every line: the code by number and by the kernel's own
	// name, which is the name `evtest` prints, then up or down and the
	// device it came from.  A repeat is neither up nor down --- the kernel
	// sends it as value 2 --- and says so.
	snprintf(head, sizeof head, "key %u %s %s on %s", code,
		 kname ? kname : "(the kernel names no such code)",
		 value == 2 ? "repeat" : (down ? "down" : "up"), device);

	switch (k->went) {
	case USB_WENT_SENT:
		if (!down) {
			snprintf(out, n, "%s: %s (keysym 0x%x), the keysym its press carried",
				 head, sym ? sym : "?", k->went_keysym);
			break;
		}
		// **THE LEVEL, AND WHAT CHOSE IT.**  Shift for every key but
		// the keypad's and Num Lock for those, which is this file's one
		// decision and the thing somebody tracing a key wants to see.
		snprintf(out, n, "%s, %s: %s (keysym 0x%x)", head,
			 k->went_keypad ? (k->went_level ? "Num Lock on" : "Num Lock off")
					: (k->went_level ? "Shift held" : "no shift"),
			 sym ? sym : "?", k->went_keysym);
		break;
	case USB_WENT_REPEAT:
		snprintf(out, n, "%s: dropped, the kernel's auto-repeat --- this keyboard has a "
			 "Repeat key of its own", head);
		break;
	case USB_WENT_ALREADY_DOWN:
		snprintf(out, n, "%s: dropped, it is already down --- a device that was not "
			 "drained, or a release that was lost", head);
		break;
	case USB_WENT_NO_ROOM:
		snprintf(out, n, "%s: refused whole, %u keys are already held and a press this "
			 "cannot remember is a release it could not owe", head,
			 (unsigned)USB_KBD_MAX_DOWN);
		break;
	case USB_WENT_NOT_SENT:
		snprintf(out, n, "%s: nothing, an up for a key this never sent down", head);
		break;
	default:
		snprintf(out, n, "%s: the code is not in the table, so nothing crosses the "
			 "link --- the far end never sees this key", head);
		break;
	}
	return out;
}

unsigned usb_kbd_release_all(struct usb_kbd_state *k, struct cadr_input_event *out, unsigned max)
{
	unsigned n = 0;
	while (k->holds && n < max) {
		const uint16_t code = k->held[0];
		const uint32_t sym = k->sent[code];
		drop_held(k, code);
		k->sent[code] = 0;
		if (!sym)
			continue;
		memset(&out[n], 0, sizeof out[n]);
		out[n].type = CADR_INPUT_KEY;
		out[n].down = 0;
		out[n].keysym = sym;
		++n;
	}
	// The shifts this program was holding are let go with them: a device
	// unplugged with Shift down must not shift the next device's keys.
	k->shift_l = 0;
	k->shift_r = 0;
	return n;
}

// ---- the mouse -----------------------------------------------------------

void usb_mouse_init(struct usb_mouse_state *m)
{
	memset(m, 0, sizeof *m);
}

void usb_mouse_event(struct usb_mouse_state *m, uint16_t type, uint16_t code, int value)
{
	if (type == EV_REL_T) {
		if (code == REL_X_C) {
			m->dx += value;
			m->moved = 1;
		} else if (code == REL_Y_C) {
			m->dy += value;
			m->moved = 1;
		} else if (code == REL_WHEEL_C || code == REL_HWHEEL_C) {
			// The cable has three switches and no wheel.  Counted
			// so that a status line can say a wheel was turned and
			// went nowhere, rather than leaving somebody to wonder.
			++m->wheels;
		}
		return;
	}
	if (type != EV_KEY_T)
		return;
	unsigned bit = 0;
	if (code == BTN_LEFT_C)
		bit = 1u;
	else if (code == BTN_MIDDLE_C)
		bit = 2u;
	else if (code == BTN_RIGHT_C)
		bit = 4u;
	else
		return;
	const uint8_t was = m->buttons;
	if (value)
		m->buttons |= (uint8_t)bit;
	else
		m->buttons &= (uint8_t)~bit;
	if (m->buttons != was)
		m->switched = 1;
}

int usb_mouse_report(struct usb_mouse_state *m, struct cadr_input_event *out)
{
	if (!m->moved && !m->switched)
		return 0;
	memset(out, 0, sizeof *out);
	out->type = CADR_INPUT_POINTER;
	// **SATURATED TO THE SIXTEEN BITS THE RECORD CARRIES.**  The register
	// at the far end is twelve bits and saturates again there; what must
	// not happen is a wrap on the way, which sends the mouse the other
	// way.  A whole screen is 963 counts, so this is a pointer that jumped.
	int dx = m->dx, dy = m->dy;
	if (dx > 32767)
		dx = 32767;
	if (dx < -32768)
		dx = -32768;
	if (dy > 32767)
		dy = 32767;
	if (dy < -32768)
		dy = -32768;
	out->dx = (int16_t)dx;
	out->dy = (int16_t)dy;
	out->buttons = m->buttons;
	// The motion is TAKEN and the switches are LEFT: a delta is added to
	// what the fabric owes and a switch is a level that stands until it
	// changes.
	m->dx = 0;
	m->dy = 0;
	m->moved = 0;
	m->switched = 0;
	return 1;
}

int usb_mouse_release_all(struct usb_mouse_state *m, struct cadr_input_event *out)
{
	if (!m->buttons)
		return 0;
	m->buttons = 0;
	m->dx = 0;
	m->dy = 0;
	m->moved = 0;
	m->switched = 0;
	memset(out, 0, sizeof *out);
	out->type = CADR_INPUT_POINTER;
	return 1;
}
