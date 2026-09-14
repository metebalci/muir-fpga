// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `muir::terminal::keyboard`'s state machine in C.  `input_keys.h` says what
// it is for and what it could not map; `input_keymap.h` is the data,
// generated from muir's own sources.
//
// **THE FUNCTION NAMES ARE muir's**, one for one --- `positions`, `modifier`,
// `is_prefix`, `after_prefix`, `holding`, `press`, `release`, `tap`,
// `behind_prefix`, `resolve` --- so that the two can be read side by side.
// muir's own comment on `resolve` is worth having here too: "Three pieces of
// state reached through branches is a state machine written as conditionals:
// `prefix`, `latched` and `tapped` ... if this grows again, make the machine
// explicit."  It has not grown.

#include "input_keys.h"

#include <ctype.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>

#include <cadr/cadr_log.h>

#include "input_keymap.h"
#include "input_mapping.h"

// ---- the queue ----------------------------------------------------------

static void push(struct key_state *k, uint32_t word)
{
	if (k->count >= KEY_BACKLOG) {
		// **A DROP HERE IS A CALLER THAT DID NOT RESERVE ITS BURST.**
		// Every caller asks for room for the WHOLE keystroke before it
		// pushes any of it, so this cannot happen; it is counted rather
		// than ignored because the failure it stands for is silent --- a
		// Shift down whose release was dropped is a Shift held for the
		// rest of the machine's run.
		++k->dropped;
		return;
	}
	k->queue[(k->head + k->count) % KEY_BACKLOG] = word;
	++k->count;
}

unsigned key_pending(const struct key_state *k)
{
	return k->count;
}

uint32_t key_peek(const struct key_state *k)
{
	return k->count ? k->queue[k->head] : 0u;
}

void key_took(struct key_state *k)
{
	if (!k->count)
		return;
	k->head = (k->head + 1) % KEY_BACKLOG;
	--k->count;
}

// ---- small sets ---------------------------------------------------------

static int has_down(const struct key_state *k, uint8_t p)
{
	for (unsigned i = 0; i < k->downs; ++i)
		if (k->down[i] == p)
			return 1;
	return 0;
}

static void add_down(struct key_state *k, uint8_t p)
{
	if (k->downs < KEY_MAX_DOWN)
		k->down[k->downs++] = p;
}

static void drop_down(struct key_state *k, uint8_t p)
{
	for (unsigned i = 0; i < k->downs; ++i) {
		if (k->down[i] != p)
			continue;
		memmove(&k->down[i], &k->down[i + 1], (k->downs - i - 1) * sizeof k->down[0]);
		--k->downs;
		return;
	}
}

// A keysym whose next release is to be dropped.  Returns 1 and removes it.
static int take_tapped(struct key_state *k, uint32_t keysym)
{
	for (unsigned i = 0; i < k->taps; ++i) {
		if (k->tapped[i] != keysym)
			continue;
		memmove(&k->tapped[i], &k->tapped[i + 1], (k->taps - i - 1) * sizeof k->tapped[0]);
		--k->taps;
		return 1;
	}
	return 0;
}

static void mark_tapped(struct key_state *k, uint32_t keysym)
{
	if (k->taps < KEY_MAX_DOWN)
		k->tapped[k->taps++] = keysym;
}

// ---- the map ------------------------------------------------------------

// `shifting(s)`: the positions of a shifting key, left then right.  Written
// as a walk of the table rather than a second table, because the table is
// generated and a hand-written index beside it is exactly the thing that
// drifts.  Called a handful of times per keystroke on a 667 MHz core.
static unsigned shifting(unsigned s, uint8_t *out, unsigned max)
{
	unsigned n = 0;
	for (unsigned p = 0; p < 128 && n < max; ++p)
		if (KEY_TABLE[p].kind == KEY_SHIFT && KEY_TABLE[p].shift == s)
			out[n++] = (uint8_t)p;
	return n;
}

// ---- what to call a key, which is what the trace prints ------------------
//
// `keyboard.rs`'s `position_name`, `key_name` and `key_written`, in that
// order and doing the same three things.  A key is named the way a MAPPING
// FILE names it, so that a traced line says what a `key` line would have to
// say --- and where the name would not read back as this key, the position is
// written instead, in octal as MIT writes it.

static const char *position_name(uint8_t p, int shifted, char *out, size_t n)
{
	snprintf(out, n, "position %o%s", p, shifted ? " shifted" : "");
	return out;
}

// `key_name`: what to call a position, the way the mapping writes it.
static const char *key_name(uint8_t p, int shifted, char *out, size_t n)
{
	const struct key_entry *e = &KEY_TABLE[p];
	switch (e->kind) {
	case KEY_NAMED:
		snprintf(out, n, "%s", e->name);
		return out;
	case KEY_SHIFT: {
		uint8_t at[4];
		const unsigned m = shifting(e->shift, at, 4);
		unsigned side = 0;
		for (unsigned i = 0; i < m; ++i)
			if (at[i] == p) {
				side = i;
				break;
			}
		if (m > 1)
			snprintf(out, n, "%s %s", side == 0 ? "Left" : "Right",
				 KEY_SHIFT_NAMES[e->shift]);
		else
			snprintf(out, n, "%s", KEY_SHIFT_NAMES[e->shift]);
		return out;
	}
	case KEY_CHAR:
		snprintf(out, n, "%c", shifted ? e->shifted : e->plain);
		return out;
	default:
		// MIT's table has plus-minus at `0o021`, which is not ASCII, so
		// the entry is empty and has no name to give.  muir's own
		// `Key::None` arm writes the position with no plane, and so
		// does this.
		return position_name(p, 0, out, n);
	}
}

// `key_written`: the name if reading it back gives this key again, and the
// position if it does not.  **THE ROUND TRIP IS THE POINT.**  A name that
// `key_key_of` would not resolve to this position and plane is a name nobody
// could write in a mapping file, and printing it would send somebody to write
// a line that is refused.
static const char *key_written(uint8_t p, int shifted, char *out, size_t n)
{
	char name[KEY_NAME_MAX];
	char why[KEY_MAP_ERR_MAX];
	uint8_t back_p = 0, back_s = 0;
	key_name(p, shifted, name, sizeof name);
	if (key_key_of(name, &back_p, &back_s, why, sizeof why) == 0
	    && back_p == p && (back_s != 0) == (shifted != 0)) {
		snprintf(out, n, "%s", name);
		return out;
	}
	return position_name(p, shifted, out, n);
}

// `Keyboard::holding`: whether a shifting key is down at either position.
static int holding(const struct key_state *k, unsigned s)
{
	uint8_t at[4];
	const unsigned n = shifting(s, at, 4);
	for (unsigned i = 0; i < n; ++i)
		if (has_down(k, at[i]))
			return 1;
	return 0;
}

// `character_positions`: a printable ASCII keysym on MIT's own table, plane 0
// first then plane 1, in position order, possibly on more than one key.
static unsigned character_positions(uint32_t keysym, uint8_t *pos, uint8_t *want, unsigned max)
{
	unsigned n = 0;
	if (keysym < 0x20 || keysym > 0x7E)
		return 0;
	const uint8_t c = (uint8_t)keysym;
	for (unsigned p = 0; p < 128 && n < max; ++p) {
		if (KEY_TABLE[p].kind != KEY_CHAR)
			continue;
		if (KEY_TABLE[p].plain == c) {
			pos[n] = (uint8_t)p;
			want[n] = 0;
			++n;
		}
		if (n < max && KEY_TABLE[p].shifted == c
		    && KEY_TABLE[p].shifted != KEY_TABLE[p].plain) {
			pos[n] = (uint8_t)p;
			want[n] = 1;
			++n;
		}
	}
	return n;
}

// `Mapping::positions`: a binding first, then the character search.
static unsigned positions(const struct key_map *m, uint32_t keysym,
			  uint8_t *pos, uint8_t *want, unsigned max)
{
	for (unsigned i = 0; i < m->bounds; ++i) {
		if (m->bound[i].keysym != keysym)
			continue;
		if (max == 0)
			return 0;
		pos[0] = m->bound[i].position;
		want[0] = m->bound[i].shifted;
		return 1;
	}
	return character_positions(keysym, pos, want, max);
}

// `Mapping::modifier`: the shifting key a keysym is, and which side of it.
// -1 if the keysym is not bound to a shifting key.
static int modifier_position(const struct key_map *m, uint32_t keysym)
{
	for (unsigned i = 0; i < m->bounds; ++i) {
		if (m->bound[i].keysym != keysym)
			continue;
		const unsigned p = m->bound[i].position;
		if (KEY_TABLE[p].kind != KEY_SHIFT)
			return -1;
		// muir looks the side up and then looks the position back out
		// of `shifting`, which for a binding that came out of the table
		// is the position it started at.  Taken directly here, and the
		// check pins Left and Right Control apart so that a face which
		// collapsed them would be caught.
		return (int)p;
	}
	return -1;
}

// `Mapping::is_prefix`.
static int is_prefix(const struct key_map *m, uint32_t keysym)
{
	for (unsigned i = 0; i < m->afters; ++i)
		if (m->after[i].first == keysym)
			return 1;
	return 0;
}

// `Mapping::after_prefix`.
static int after_prefix(const struct key_map *m, uint32_t first, uint32_t second,
			uint8_t *pos, uint8_t *want)
{
	for (unsigned i = 0; i < m->afters; ++i) {
		if (m->after[i].first != first || m->after[i].second != second)
			continue;
		*pos = m->after[i].position;
		*want = m->after[i].shifted;
		return 1;
	}
	return 0;
}

// ---- the keyboard's own firmware ----------------------------------------
//
// `sys/io1/ukbd.lisp`'s `check-boot` and `bootflag`, which act on the words
// after the mapping has chosen them.  `input_keys.h` says what they are and
// why they are not the autoboot test; muir keeps them in the same two places,
// `queue_down` and `queue_up`.

int key_boot_parse(const char *s, struct key_boot *out, char *why, unsigned n)
{
	unsigned controls = 0, metas = 0;
	const char *at = s;
	int bad = 0;
	while (!bad) {
		const char *comma = strchr(at, ',');
		const char *end = comma ? comma : at + strlen(at);
		// A word, trimmed of the spaces around it and read without
		// regard to case, as muir reads it.
		while (at < end && isspace((unsigned char)*at))
			++at;
		const char *stop = end;
		while (stop > at && isspace((unsigned char)stop[-1]))
			--stop;
		const size_t len = (size_t)(stop - at);
		if (len == 4 && strncasecmp(at, "ctrl", 4) == 0)
			++controls;
		else if (len == 4 && strncasecmp(at, "meta", 4) == 0)
			++metas;
		else
			bad = 1;
		if (!comma)
			break;
		at = comma + 1;
	}
	if (bad || controls < 1 || controls > 2 || metas < 1 || metas > 2) {
		// muir's own wording, so that somebody who has been refused by
		// one is not refused differently by the other.
		if (why && n)
			snprintf(why, n,
				 "\"%s\" is not the keys the boot sequence needs: "
				 KEY_BOOT_SPELLINGS, s);
		return -1;
	}
	out->controls = (unsigned char)controls;
	out->metas = (unsigned char)metas;
	return 0;
}

void key_boot_spelling(struct key_boot b, char *out, unsigned n)
{
	char buf[32];
	unsigned at = 0;
	for (unsigned i = 0; i < b.controls && at + 5 < sizeof buf; ++i)
		at += (unsigned)snprintf(buf + at, sizeof buf - at, "%s", at ? ",ctrl" : "ctrl");
	for (unsigned i = 0; i < b.metas && at + 5 < sizeof buf; ++i)
		at += (unsigned)snprintf(buf + at, sizeof buf - at, "%s", at ? ",meta" : "meta");
	snprintf(out, n, "%s", buf);
}

void key_boot_set(struct key_state *k, struct key_boot b)
{
	k->boot = b;
}

void key_boot_traced(struct key_state *k, int on)
{
	k->boot_trace = on;
}

// `Keyboard::queue_down`: a key-down's word onto the queue.  EVERY one clears
// the firmware's `bootflag` --- `check-boot`'s `not-boot` path does, after
// every key-down --- and `check_boot` sets it again when the key completes
// the sequence.
static void queue_down(struct key_state *k, uint8_t p)
{
	push(k, key_up_down(p, 0));
	k->hold_back = 0;
}

// `Keyboard::queue_up`: a key-up's word, unless the firmware's `bootflag`
// holds it back.  `ukbd.lisp`: "If booting, don't send key-up codes."
static void queue_up(struct key_state *k, uint8_t p)
{
	if (k->hold_back) {
		k->firmware = KEY_FW_HELD_BACK;
		++k->held_back;
		if (k->boot_trace)
			say("the keyboard: a key-up held back, no key-up goes until the next "
			    "key-down, so that the machine reads the boot word first");
		return;
	}
	push(k, key_up_down(p, 1));
}

// **`check-boot` ITSELF**, run after every key-down that is HELD: with the
// Controls and Metas the setting asks for down, Rubout down sends the cold
// boot word and Return down the warm one, Rubout tested first as the firmware
// tests it.  Then `bootflag` is set and no key-up goes until the next
// key-down.
static void check_boot(struct key_state *k)
{
	uint8_t at[4];
	unsigned n, held;

	n = shifting(SH_CONTROL, at, 4);
	held = 0;
	for (unsigned i = 0; i < n; ++i)
		held += has_down(k, at[i]) ? 1u : 0u;
	if (held < k->boot.controls)
		return;
	n = shifting(SH_META, at, 4);
	held = 0;
	for (unsigned i = 0; i < n; ++i)
		held += has_down(k, at[i]) ? 1u : 0u;
	if (held < k->boot.metas)
		return;
	int cold;
	if (has_down(k, KEY_POS_RUBOUT))
		cold = 1;
	else if (has_down(k, KEY_POS_RETURN))
		cold = 0;
	else
		return;
	// **THE BOOT WORD IS A SECOND WORD AND IT ASKS FOR ITS OWN ROOM.**  The
	// press that got here reserved one slot and has used it, so a queue
	// that was one short of full is full now; pushing into it would drop
	// the word silently and count it in `dropped`, which is the thing that
	// must stay zero.  Refused instead, and counted with the keystrokes
	// the queue had no room for, and the flag is NOT set --- no word went,
	// so there is nothing for the key-ups to be held back behind.  A queue
	// this full is a machine that is not reading its keyboard at all.
	if (k->count >= KEY_BACKLOG) {
		++k->refused;
		return;
	}
	// **NOT `queue_down`**: the boot word is not a key going down and must
	// not clear the flag it is about to set.
	push(k, key_boot_word(cold));
	k->hold_back = 1;
	k->firmware = cold ? KEY_FW_BOOT_COLD : KEY_FW_BOOT_WARM;
	++k->boots;
	// Said whether or not the trace is on: see `key_boot_traced`.
	say("the keyboard: the boot sequence is complete, and the %s boot word goes after "
	    "the key-down --- the machine is being asked to start over",
	    cold ? "cold" : "warm");
}

// ---- the keys -----------------------------------------------------------

// `Keyboard::press`: down, if it is up and the queue has room.  A press the
// queue has no room for is refused WHOLE, and the key stays up here too, so
// that no release is owed for it.
//
// Whether the key is down for the machine after this, which is muir's own
// answer and is what the trace needs: so, too, for a key the viewer already
// had down, since the machine has that press or will; not so only for the
// press the queue refused.
static int press(struct key_state *k, uint8_t p)
{
	if (has_down(k, p))
		return 1;
	if (k->count >= KEY_BACKLOG) {
		++k->refused;
		return 0;
	}
	add_down(k, p);
	queue_down(k, p);
	check_boot(k);
	return 1;
}

// `Keyboard::release`: up, if it is down.  ALWAYS queued: the machine has
// read the key going down, or will.
static void release(struct key_state *k, uint8_t p)
{
	if (!has_down(k, p))
		return;
	drop_down(k, p);
	queue_up(k, p);
}

// One key of a burst: a position and whether it is going up.
struct key_burst { uint8_t p, up; };

// `Keyboard::tap`: the key pressed and released at once, with the Shift key
// worked around it when the plane it wants is not the one the viewer holds.
// The machine sees shift, key, shift back, which is what a typist would have
// done.  Refused whole beyond the backlog, as a plain press is, so that it
// leaves nothing down.
static int tap(struct key_state *k, uint8_t p, int wants_shift)
{
	uint8_t at[4];
	const unsigned n = shifting(SH_SHIFT, at, 4);
	if (n == 0)
		return 0;
	// **THE WHOLE KEYSTROKE IS WORKED OUT BEFORE ANY OF IT IS PUSHED, AND
	// THE ROOM IS ASKED FOR ONCE, FOR ALL OF IT.**  A guard that tests one
	// free slot and then pushes four is worse than no guard at all: at the
	// backlog it let the Shift go down and dropped its release, and this
	// keyboard has no modifier bits --- `ukbd.lisp`, "all key-encoding ...
	// will be done in software in the central machine" --- so a Shift the
	// machine never saw come up is a Shift held for the rest of the run,
	// and every character after it a different character.  Ten is the
	// longest burst the branches below can make: four shifting keys let go
	// around the key and put back.
	// **A BURST IS KEYS AND NOT WORDS**, so that every one of them goes
	// through the firmware's own two doors below: a key-down in here
	// clears `bootflag` exactly as a held press does, and a key-up in here
	// is held back exactly as a held release is.  muir's `tap` queues
	// through `queue_down` and `queue_up` for the same reason.
	struct key_burst burst[2 * 4 + 2];
	unsigned m = 0;
	const uint8_t shift = at[0];
	const int held = holding(k, SH_SHIFT);
	if (wants_shift && !held) {
		burst[m++] = (struct key_burst){ shift, 0 };
		burst[m++] = (struct key_burst){ p, 0 };
		burst[m++] = (struct key_burst){ p, 1 };
		burst[m++] = (struct key_burst){ shift, 1 };
	} else if (!wants_shift && held) {
		// Every shift the viewer holds comes up around the key.
		uint8_t up[4];
		unsigned u = 0;
		for (unsigned i = 0; i < n; ++i)
			if (has_down(k, at[i]))
				up[u++] = at[i];
		for (unsigned i = 0; i < u; ++i)
			burst[m++] = (struct key_burst){ up[i], 1 };
		burst[m++] = (struct key_burst){ p, 0 };
		burst[m++] = (struct key_burst){ p, 1 };
		for (unsigned i = 0; i < u; ++i)
			burst[m++] = (struct key_burst){ up[i], 0 };
	} else {
		burst[m++] = (struct key_burst){ p, 0 };
		burst[m++] = (struct key_burst){ p, 1 };
	}
	if (k->count + m > KEY_BACKLOG) {
		++k->refused;
		return 0;
	}
	for (unsigned i = 0; i < m; ++i) {
		if (burst[i].up)
			queue_up(k, burst[i].p);
		else
			queue_down(k, burst[i].p);
	}
	return 1;
}

// `Keyboard::behind_prefix`: a shifting key is held for the one key that
// follows it, anything else is tapped.  Whether it went: a shifting key the
// queue refused is not latched either, there being nothing down to hold for
// the key after it.
static int behind_prefix(struct key_state *k, uint8_t p, int wants_shift)
{
	if (KEY_TABLE[p].kind == KEY_SHIFT) {
		const int went = press(k, p);
		if (went && k->latches < KEY_MAX_DOWN)
			k->latched[k->latches++] = p;
		return went;
	}
	return tap(k, p, wants_shift);
}

// `BootKeys::default`: `ctrl,meta`, either Control and either Meta, which is
// Ctrl-Alt-Del pressed on a keyboard anybody has.
static const struct key_boot KEY_BOOT_DEFAULT = { 1, 1 };

void key_state_init(struct key_state *k)
{
	memset(k, 0, sizeof *k);
	k->boot = KEY_BOOT_DEFAULT;
	key_map_built_in(&k->map);
}

void key_state_init_with(struct key_state *k, const struct key_map *map)
{
	memset(k, 0, sizeof *k);
	k->boot = KEY_BOOT_DEFAULT;
	k->map = *map;
}

// ---- what a keysym became -----------------------------------------------
//
// muir's `Went`, made here rather than printed here: `resolve` hands one back
// at every one of its returns and the trace's line is written from it, which
// is muir's own arrangement and is what lets the check hold the wording.

static struct key_went w_of(int kind, uint8_t p, int shifted, int tapped)
{
	struct key_went w;
	memset(&w, 0, sizeof w);
	w.kind = kind;
	w.p = p;
	w.shifted = (uint8_t)!!shifted;
	w.tapped = (uint8_t)!!tapped;
	return w;
}

static struct key_went w_nothing(const char *why)
{
	struct key_went w = w_of(KEY_WENT_NOTHING, 0, 0, 0);
	w.why = why;
	return w;
}

static struct key_went w_behind(uint32_t first, int found, uint8_t p, int shifted)
{
	struct key_went w = w_of(KEY_WENT_BEHIND, p, shifted, 0);
	w.first = first;
	w.found = (uint8_t)!!found;
	return w;
}

const char *key_went_text(const struct key_went *w, char *out, size_t n)
{
	char key[KEY_NAME_MAX], first[KEY_NAME_MAX];
	switch (w->kind) {
	case KEY_WENT_UNBOUND:
		snprintf(out, n, "no binding");
		break;
	case KEY_WENT_HELD_AS_PREFIX:
		snprintf(out, n, "held as a prefix; the keysym after it is looked up behind it");
		break;
	case KEY_WENT_PREFIX_LET_GO:
		snprintf(out, n, "the prefix is let go, and nothing is sent");
		break;
	case KEY_WENT_BEHIND:
		key_sym_name(w->first, first, sizeof first);
		if (!w->found)
			snprintf(out, n, "behind %s: no binding", first);
		else
			snprintf(out, n, "behind %s: %s", first,
				 key_written(w->p, w->shifted, key, sizeof key));
		break;
	case KEY_WENT_SENT:
		key_written(w->p, w->shifted, key, sizeof key);
		if (w->tapped)
			snprintf(out, n, "%s, tapped with the shift worked around it", key);
		else
			snprintf(out, n, "%s", key);
		break;
	case KEY_WENT_REFUSED:
		snprintf(out, n, "%s refused: the queue is full, %u words the machine has "
			 "not read", key_written(w->p, w->shifted, key, sizeof key),
			 (unsigned)KEY_BACKLOG);
		break;
	default:
		snprintf(out, n, "nothing: %s", w->why ? w->why : "");
		break;
	}
	return out;
}

// `Keyboard::resolve`, branch for branch, and what each branch did.
static struct key_went resolve(struct key_state *k, uint32_t keysym, int down)
{
	// What the firmware did is about THIS key and no other.
	k->firmware = KEY_FW_NONE;

	// A key the terminal has already sent whole: its release is not owed
	// to the machine.
	if (!down && take_tapped(k, keysym))
		return w_nothing("its key was tapped and has gone already");

	// A prefix standing: this keysym is looked up behind it.
	if (k->prefix) {
		const uint32_t first = k->prefix;
		if (is_prefix(&k->map, keysym)) {
			// The prefix's own release, or the prefix again, which
			// is the way out of a sequence begun by mistake.
			if (down) {
				k->prefix = 0;
				return w_of(KEY_WENT_PREFIX_LET_GO, 0, 0, 0);
			}
			return w_nothing("a prefix acts on its press");
		}
		if (!down)
			return w_nothing("the prefix stands until a key is pressed behind it");
		k->prefix = 0;
		mark_tapped(k, keysym);
		uint8_t p, want;
		if (!after_prefix(&k->map, first, keysym, &p, &want))
			return w_behind(first, 0, 0, 0);
		if (!behind_prefix(k, p, want))
			return w_of(KEY_WENT_REFUSED, p, want, 0);
		return w_behind(first, 1, p, want);
	}
	if (is_prefix(&k->map, keysym)) {
		if (down) {
			k->prefix = keysym;
			return w_of(KEY_WENT_HELD_AS_PREFIX, 0, 0, 0);
		}
		return w_nothing("a prefix acts on its press");
	}

	// A modifier is pressed or released at its own position and nothing
	// more: there is no shift state in a word on this keyboard.
	const int mp = modifier_position(&k->map, keysym);
	if (mp >= 0) {
		if (down && !press(k, (uint8_t)mp))
			return w_of(KEY_WENT_REFUSED, (uint8_t)mp, 0, 0);
		if (!down)
			release(k, (uint8_t)mp);
		return w_of(KEY_WENT_SENT, (uint8_t)mp, 0, 0);
	}

	uint8_t pos[8], want[8];
	const unsigned found = positions(&k->map, keysym, pos, want, 8);
	if (found == 0) {
		++k->unbound;
		return w_of(KEY_WENT_UNBOUND, 0, 0, 0);
	}
	const int shifted = holding(k, SH_SHIFT);

	// Under a latched shifting key the key is tapped inside it and the
	// latch let go after, so that the shifting key held is held for this
	// key and no other.
	if (k->latches) {
		if (!down)
			return w_nothing("a latched shifting key holds for the press alone");
		unsigned pick = 0;
		for (unsigned i = 0; i < found; ++i)
			if ((want[i] != 0) == (shifted != 0)) {
				pick = i;
				break;
			}
		mark_tapped(k, keysym);
		const int went = tap(k, pos[pick], want[pick]);
		const unsigned n = k->latches;
		k->latches = 0;
		for (unsigned i = 0; i < n; ++i)
			release(k, k->latched[i]);
		if (!went)
			return w_of(KEY_WENT_REFUSED, pos[pick], want[pick], 0);
		return w_of(KEY_WENT_SENT, pos[pick], want[pick], 1);
	}

	// The position whose plane the viewer's own shift already gives.
	for (unsigned i = 0; i < found; ++i) {
		if ((want[i] != 0) != (shifted != 0))
			continue;
		if (down && !press(k, pos[i]))
			return w_of(KEY_WENT_REFUSED, pos[i], shifted, 0);
		if (!down)
			release(k, pos[i]);
		return w_of(KEY_WENT_SENT, pos[i], shifted, 0);
	}

	// Otherwise the shift is worked around the key.
	if (!down) {
		release(k, pos[0]);
		return w_of(KEY_WENT_SENT, pos[0], want[0], 0);
	}
	mark_tapped(k, keysym);
	if (!tap(k, pos[0], want[0]))
		return w_of(KEY_WENT_REFUSED, pos[0], want[0], 0);
	return w_of(KEY_WENT_SENT, pos[0], want[0], 1);
}

// ---- the trace ----------------------------------------------------------

void key_traced(struct key_state *k, int on)
{
	k->trace = on;
}

// **THE TRACE SWITCHES WHILE THE PROGRAM RUNS**, because a diagnostic that
// needs a restart costs the machine's Lisp to get.  The handler does the one
// thing a handler may: writes a `sig_atomic_t`.  `key_trace_apply` is what
// acts on it, from the program's own loop, where `say` is allowed.
//
// `-1` is nothing asked, so that a run started with the flag is not turned off
// by the first pass of the loop.
static volatile sig_atomic_t trace_asked = -1;

static void trace_signal(int sig)
{
	trace_asked = (sig == SIGUSR1);
}

void key_trace_signals(void)
{
	signal(SIGUSR1, trace_signal);
	signal(SIGUSR2, trace_signal);
}

void key_trace_apply(struct key_state *k)
{
	const int want = trace_asked;
	if (want < 0 || want == (k->trace != 0))
		return;
	k->trace = want;
	if (want)
		say("the keyboard trace is ON (SIGUSR1): every keysym and what it became is a "
		    "line here, until SIGUSR2 --- `cadr-console trace-keys off`");
	else
		say("the keyboard trace is off (SIGUSR2)");
}

const char *key_event_traced(struct key_state *k, uint32_t keysym, int down,
			     const char *source, char *out, size_t n)
{
	const struct key_went w = resolve(k, keysym, down);
	char sym[KEY_NAME_MAX], became[KEY_TRACE_MAX];
	const char *firmware = "";
	k->went = w;
	// muir's `Firmware` Display, word for word: what the keyboard's own
	// firmware did with the key after the mapping had chosen it.
	switch (k->firmware) {
	case KEY_FW_BOOT_COLD:
		firmware = ", and the boot sequence is complete: the cold boot word goes after it";
		break;
	case KEY_FW_BOOT_WARM:
		firmware = ", and the boot sequence is complete: the warm boot word goes after it";
		break;
	case KEY_FW_HELD_BACK:
		firmware = " held back: no key-up goes until the next key-down, so that the "
			   "machine reads the boot word first";
		break;
	default:
		break;
	}
	snprintf(out, n, "keysym 0x%x %s %s%s%s, %s%s", keysym,
		 key_sym_name(keysym, sym, sizeof sym), down ? "down" : "up",
		 source ? " from " : "", source ? source : "",
		 key_went_text(&w, became, sizeof became), firmware);
	if (k->trace)
		say("%s", out);
	return out;
}

void key_event_from(struct key_state *k, uint32_t keysym, int down, const char *source)
{
	// **THE LINE IS BUILT ONLY WHEN IT IS WANTED.**  A keystroke costs two
	// `snprintf`s and a round trip through `key_key_of` under the trace,
	// and nothing at all without it.
	if (k->trace) {
		char line[KEY_TRACE_MAX];
		key_event_traced(k, keysym, down, source, line, sizeof line);
		return;
	}
	k->went = resolve(k, keysym, down);
}

void key_event(struct key_state *k, uint32_t keysym, int down)
{
	key_event_from(k, keysym, down, NULL);
}

void key_all_up(struct key_state *k)
{
	// **AND A RELEASE HERE IS HELD BACK LIKE ANY OTHER IF A BOOT WORD HAS
	// JUST GONE.**  That is the firmware's rule and not an oversight: a
	// viewer that leaves right after asking for a boot has its keys lifted
	// here, the machine is not told, and the next key-down anybody makes
	// clears the flag.  The machine is being restarted, which is what
	// `bootflag` exists to protect.

	// **NOT muir's `all_keys_up` WORD.**  That exists in `keyboard.rs` and
	// nothing in muir's runtime sends one; what it carries is a bit per
	// shifting key still down, and a machine that has been following the
	// stream does not need to be told.  What a viewer going away owes is
	// the RELEASES it did not send, one word each, which is the same
	// stream the machine has been reading all along.
	while (k->downs) {
		const uint8_t p = k->down[0];
		release(k, p);
		// `release` drops it from `down`; guard against a queue with no
		// room, which would leave it down for ever and spin here.
		if (has_down(k, p)) {
			drop_down(k, p);
			++k->refused;
		}
	}
	k->latches = 0;
	k->taps = 0;
	k->prefix = 0;
}
