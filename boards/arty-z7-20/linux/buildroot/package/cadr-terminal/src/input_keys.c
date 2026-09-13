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

#include <string.h>

#include "input_keymap.h"
#include "input_mapping.h"

// ---- the queue ----------------------------------------------------------

static void push(struct key_state *k, uint32_t word)
{
	if (k->count >= KEY_BACKLOG)
		return;
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

// ---- the keys -----------------------------------------------------------

// `Keyboard::press`: down, if it is up and the queue has room.  A press the
// queue has no room for is refused WHOLE, and the key stays up here too, so
// that no release is owed for it.
static void press(struct key_state *k, uint8_t p)
{
	if (k->count >= KEY_BACKLOG || has_down(k, p)) {
		if (k->count >= KEY_BACKLOG)
			++k->refused;
		return;
	}
	add_down(k, p);
	push(k, key_up_down(p, 0));
}

// `Keyboard::release`: up, if it is down.  ALWAYS queued: the machine has
// read the key going down, or will.
static void release(struct key_state *k, uint8_t p)
{
	if (!has_down(k, p))
		return;
	drop_down(k, p);
	push(k, key_up_down(p, 1));
}

// `Keyboard::tap`: the key pressed and released at once, with the Shift key
// worked around it when the plane it wants is not the one the viewer holds.
// The machine sees shift, key, shift back, which is what a typist would have
// done.  Refused whole beyond the backlog, as a plain press is, so that it
// leaves nothing down.
static void tap(struct key_state *k, uint8_t p, int wants_shift)
{
	if (k->count >= KEY_BACKLOG) {
		++k->refused;
		return;
	}
	uint8_t at[4];
	const unsigned n = shifting(SH_SHIFT, at, 4);
	if (n == 0)
		return;
	const uint8_t shift = at[0];
	const int held = holding(k, SH_SHIFT);
	if (wants_shift && !held) {
		push(k, key_up_down(shift, 0));
		push(k, key_up_down(p, 0));
		push(k, key_up_down(p, 1));
		push(k, key_up_down(shift, 1));
	} else if (!wants_shift && held) {
		// Every shift the viewer holds comes up around the key.
		uint8_t up[4];
		unsigned m = 0;
		for (unsigned i = 0; i < n; ++i)
			if (has_down(k, at[i]))
				up[m++] = at[i];
		for (unsigned i = 0; i < m; ++i)
			push(k, key_up_down(up[i], 1));
		push(k, key_up_down(p, 0));
		push(k, key_up_down(p, 1));
		for (unsigned i = 0; i < m; ++i)
			push(k, key_up_down(up[i], 0));
	} else {
		push(k, key_up_down(p, 0));
		push(k, key_up_down(p, 1));
	}
}

// `Keyboard::behind_prefix`: a shifting key is held for the one key that
// follows it, anything else is tapped.
static void behind_prefix(struct key_state *k, uint8_t p, int wants_shift)
{
	if (KEY_TABLE[p].kind == KEY_SHIFT) {
		press(k, p);
		if (k->latches < KEY_MAX_DOWN)
			k->latched[k->latches++] = p;
	} else {
		tap(k, p, wants_shift);
	}
}

void key_state_init(struct key_state *k)
{
	memset(k, 0, sizeof *k);
	key_map_built_in(&k->map);
}

void key_state_init_with(struct key_state *k, const struct key_map *map)
{
	memset(k, 0, sizeof *k);
	k->map = *map;
}

// `Keyboard::resolve`, branch for branch.
void key_event(struct key_state *k, uint32_t keysym, int down)
{
	// A key the terminal has already sent whole: its release is not owed
	// to the machine.
	if (!down && take_tapped(k, keysym))
		return;

	// A prefix standing: this keysym is looked up behind it.
	if (k->prefix) {
		const uint32_t first = k->prefix;
		if (is_prefix(&k->map, keysym)) {
			// The prefix's own release, or the prefix again, which
			// is the way out of a sequence begun by mistake.
			if (down)
				k->prefix = 0;
			return;
		}
		if (!down)
			return;   // the prefix stands until a key is pressed behind it
		k->prefix = 0;
		mark_tapped(k, keysym);
		uint8_t p, want;
		if (after_prefix(&k->map, first, keysym, &p, &want))
			behind_prefix(k, p, want);
		return;
	}
	if (is_prefix(&k->map, keysym)) {
		if (down)
			k->prefix = keysym;
		return;
	}

	// A modifier is pressed or released at its own position and nothing
	// more: there is no shift state in a word on this keyboard.
	const int mp = modifier_position(&k->map, keysym);
	if (mp >= 0) {
		if (down)
			press(k, (uint8_t)mp);
		else
			release(k, (uint8_t)mp);
		return;
	}

	uint8_t pos[8], want[8];
	const unsigned found = positions(&k->map, keysym, pos, want, 8);
	if (found == 0) {
		++k->unbound;
		return;
	}
	const int shifted = holding(k, SH_SHIFT);

	// Under a latched shifting key the key is tapped inside it and the
	// latch let go after, so that the shifting key held is held for this
	// key and no other.
	if (k->latches) {
		if (!down)
			return;   // a latched shifting key holds for the press alone
		unsigned pick = 0;
		for (unsigned i = 0; i < found; ++i)
			if ((want[i] != 0) == (shifted != 0)) {
				pick = i;
				break;
			}
		mark_tapped(k, keysym);
		tap(k, pos[pick], want[pick]);
		const unsigned n = k->latches;
		k->latches = 0;
		for (unsigned i = 0; i < n; ++i)
			release(k, k->latched[i]);
		return;
	}

	// The position whose plane the viewer's own shift already gives.
	for (unsigned i = 0; i < found; ++i) {
		if ((want[i] != 0) != (shifted != 0))
			continue;
		if (down)
			press(k, pos[i]);
		else
			release(k, pos[i]);
		return;
	}

	// Otherwise the shift is worked around the key.
	if (!down) {
		release(k, pos[0]);
		return;
	}
	mark_tapped(k, keysym);
	tap(k, pos[0], want[0]);
}

void key_all_up(struct key_state *k)
{
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
