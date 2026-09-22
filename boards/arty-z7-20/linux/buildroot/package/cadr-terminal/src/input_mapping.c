// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `muir::terminal::keyboard::Mapping` in C: the bindings, and the parser
// that reads a file of them.  `input_mapping.h` says what the file is and
// where this parts from muir.
//
// **THE FUNCTION NAMES ARE muir's**, one for one --- `two`, `keysym_of`,
// `key_of`, `strip_word`, `position_of`, `keysym_name`, `read_into` --- so
// that the two can be read side by side, which is the same rule
// `input_keys.c` follows for the state machine.
//
// **AND SO ARE THE MESSAGES, WORD FOR WORD.**  A file is edited on a laptop
// and tried on the board, and a person who has seen muir refuse a line
// should see the same sentence here.  `two`'s message even keeps Rust's
// `{:?}` quoting of the text it could not use, because that is what says
// where a line ran out.

#include "input_mapping.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---- ASCII, explicitly -------------------------------------------------
//
// `strcasecmp` is in the locale's alphabet and muir's `eq_ignore_ascii_case`
// is in ASCII's, and a board whose locale said otherwise would fold a name
// differently from the simulator.  So the folding is written out.

static int ci_eq(const char *a, const char *b)
{
	while (*a && *b) {
		if (tolower((unsigned char)*a) != tolower((unsigned char)*b))
			return 0;
		++a;
		++b;
	}
	return *a == *b;
}

static int is_space(char c)
{
	return isspace((unsigned char)c) != 0;
}

// The word `s` starts with, and where the rest of it begins.  muir splits at
// the FIRST whitespace character and trims what follows; a word with no
// whitespace after it leaves `*rest` at the terminator.
static void split_once(const char *s, char *word, size_t wordlen, const char **rest)
{
	size_t n = 0;
	while (s[n] && !is_space(s[n]))
		++n;
	if (n >= wordlen)
		n = wordlen - 1;
	memcpy(word, s, n);
	word[n] = '\0';
	const char *r = s + n;
	while (*r && is_space(*r))
		++r;
	*rest = r;
}

// ...and the same with the tail's own trailing whitespace gone, which is
// what `rest.trim()` leaves.  Returns the length kept.
static size_t trimmed(const char *s, char *out, size_t outlen)
{
	while (*s && is_space(*s))
		++s;
	size_t n = strlen(s);
	while (n && is_space(s[n - 1]))
		--n;
	if (n >= outlen)
		n = outlen - 1;
	memcpy(out, s, n);
	out[n] = '\0';
	return n;
}

// ---- the words a line is made of ---------------------------------------

// **THE ONE LENGTH LIMIT, AND IT IS A REFUSAL AND NOT A TRUNCATION.**  muir
// has none; a line longer than this is refused here, by name, because the
// alternative in C is a buffer that quietly keeps the front of a line ---
// which can turn a line that would have been refused into one that binds
// something, and is the silent-omission shape this repository keeps meeting.
// Every buffer below is `WORD_MAX`, which is larger, so nothing inside a
// line of a legal length can be cut.  The longest line of the built-in
// mapping is 38 characters.
#define LINE_MAX 200
#define WORD_MAX 256

// Rust's `{:?}` on a `&str`, which is what `two`'s message prints: the text
// in double quotes with the five escapes spelled out and any other control
// character as `\u{..}`.  Reproduced because the quoting is the part that
// says where the line ran out --- a bare `key` reports `not ""`, and without
// the quotes that sentence ends in nothing at all.
static void debug_str(const char *s, char *out, size_t outlen)
{
	size_t o = 0;
	if (outlen < 3) {
		if (outlen)
			out[0] = '\0';
		return;
	}
	out[o++] = '"';
	for (; *s && o + 12 < outlen; ++s) {
		const unsigned char c = (unsigned char)*s;
		switch (c) {
		case '"': out[o++] = '\\'; out[o++] = '"'; break;
		case '\\': out[o++] = '\\'; out[o++] = '\\'; break;
		case '\n': out[o++] = '\\'; out[o++] = 'n'; break;
		case '\r': out[o++] = '\\'; out[o++] = 'r'; break;
		case '\t': out[o++] = '\\'; out[o++] = 't'; break;
		default:
			if (c < 0x20 || c == 0x7f)
				o += (size_t)snprintf(out + o, outlen - o, "\\u{%x}", c);
			else
				out[o++] = (char)c;
			break;
		}
	}
	out[o++] = '"';
	out[o] = '\0';
}

// `two`: a line's first word and the rest of it, BOTH wanted.  The rest must
// not be empty, which is what makes `key Escape` a refused line rather than
// a binding of nothing.
static int two(const char *rest, char *word, size_t wordlen, char *tail, size_t taillen,
	       char *err, size_t errlen)
{
	const char *whole = rest;
	split_once(rest, word, wordlen, &rest);
	if (trimmed(rest, tail, taillen) == 0) {
		// muir prints the WHOLE of what it was handed --- `{rest:?}`
		// --- and not the word it took off the front.  The two are the
		// same string whenever this fires, because `rest` arrives
		// trimmed and the error can only be reached when it holds no
		// whitespace at all; printing what muir prints is nevertheless
		// what keeps them the same when one of us changes.
		// Small enough that the message around it provably fits
		// `KEY_MAP_ERR_MAX`, which is what stops the compiler warning
		// that it might be cut; `debug_str` keeps to the size it is
		// given, so a pathological line is quoted in part rather than
		// overrunning.  A line is at most LINE_MAX characters and the
		// word inside it a good deal less.
		char quoted[KEY_MAP_ERR_MAX - 96];
		debug_str(whole, quoted, sizeof quoted);
		snprintf(err, errlen, "wants a keysym and what it means, not %s", quoted);
		return -1;
	}
	return 0;
}

// ---- a keysym ----------------------------------------------------------

const char *key_sym_name(uint32_t keysym, char *out, size_t outlen)
{
	for (unsigned i = 0; i < KEY_SYM_NAME_COUNT; ++i)
		if (KEY_SYM_NAMES[i].keysym == keysym) {
			snprintf(out, outlen, "%s", KEY_SYM_NAMES[i].name);
			return out;
		}
	if (keysym >= 0x20u && keysym <= 0x7eu)
		snprintf(out, outlen, "%c", (char)keysym);
	else
		snprintf(out, outlen, "0x%x", keysym);
	return out;
}

// Rust's `u32::from_str` and `u8::from_str_radix`, which is not `strtoul`:
// a leading `+` is allowed, a `-` is not, the digits must be in the radix,
// there must be at least one, nothing may follow, and it must not overflow.
// `strtoul` would take `0x41` as hexadecimal, take a `-`, and stop at the
// first character it did not like instead of refusing the word.
static int rust_int(const char *s, unsigned base, unsigned long max, unsigned long *out)
{
	if (*s == '+')
		++s;
	if (!*s)
		return -1;
	unsigned long v = 0;
	for (; *s; ++s) {
		unsigned d;
		if (*s >= '0' && *s <= '9')
			d = (unsigned)(*s - '0');
		else if (*s >= 'a' && *s <= 'f')
			d = (unsigned)(*s - 'a') + 10u;
		else if (*s >= 'A' && *s <= 'F')
			d = (unsigned)(*s - 'A') + 10u;
		else
			return -1;
		if (d >= base)
			return -1;
		if (v > (max - d) / base)
			return -1;
		v = v * base + d;
	}
	*out = v;
	return 0;
}

// `keysym_of`: an X11 name, a single printable character, or a number in
// decimal or `0x` hexadecimal, tried in that order.
int key_sym_of(const char *word, uint32_t *out, char *err, size_t errlen)
{
	for (unsigned i = 0; i < KEY_SYM_NAME_COUNT; ++i)
		if (ci_eq(KEY_SYM_NAMES[i].name, word)) {
			*out = KEY_SYM_NAMES[i].keysym;
			return 0;
		}
	if (word[0] && !word[1] && (unsigned char)word[0] >= 0x20u
	    && (unsigned char)word[0] <= 0x7eu) {
		*out = (uint32_t)(unsigned char)word[0];
		return 0;
	}
	unsigned long v;
	// `strip_prefix("0x")` and not a case-insensitive one: `0X41` is no
	// keysym in muir and is no keysym here.
	if (word[0] == '0' && word[1] == 'x') {
		if (rust_int(word + 2, 16u, 0xFFFFFFFFul, &v) == 0) {
			*out = (uint32_t)v;
			return 0;
		}
		snprintf(err, errlen, "%s is no keysym", word);
		return -1;
	}
	if (rust_int(word, 10u, 0xFFFFFFFFul, &v) == 0) {
		*out = (uint32_t)v;
		return 0;
	}
	snprintf(err, errlen, "%s is no keysym", word);
	return -1;
}

// ---- a key -------------------------------------------------------------

// `shifting(s)`: the positions of a shifting key in ASCENDING order, which
// is what makes muir's `Left` the LOWER of a pair rather than MIT's own
// left-hand one.  Greek is the one pair where those differ --- 0o035 is
// MIT's Right and is muir's Left --- and `input_keys.h` records it.  Written
// as a walk of the generated table here for the same reason `input_keys.c`
// writes it as one.
static unsigned shifting_at(unsigned s, uint8_t *out, unsigned max)
{
	unsigned n = 0;
	for (unsigned p = 0; p < 128u && n < max; ++p)
		if (KEY_TABLE[p].kind == KEY_SHIFT && KEY_TABLE[p].shift == s)
			out[n++] = (uint8_t)p;
	return n;
}

// `character_positions`, first entry only: the first position of MIT's table
// that gives a character, its unshifted plane before its shifted one.
static int character_first(uint32_t keysym, uint8_t *position, uint8_t *shifted)
{
	if (keysym < 0x20u || keysym > 0x7eu)
		return -1;
	const uint8_t c = (uint8_t)keysym;
	for (unsigned p = 0; p < 128u; ++p) {
		if (KEY_TABLE[p].kind != KEY_CHAR)
			continue;
		if (KEY_TABLE[p].plain == c) {
			*position = (uint8_t)p;
			*shifted = 0;
			return 0;
		}
		if (KEY_TABLE[p].shifted == c && KEY_TABLE[p].shifted != KEY_TABLE[p].plain) {
			*position = (uint8_t)p;
			*shifted = 1;
			return 0;
		}
	}
	return -1;
}

// `position_of`: the number in OCTAL, and `shifted` or nothing after it.
static int position_of(const char *rest, uint8_t *position, uint8_t *shifted,
		       char *err, size_t errlen)
{
	char number[WORD_MAX];
	const char *tail;
	split_once(rest, number, sizeof number, &tail);
	*shifted = 0;
	if (*tail) {
		char after[WORD_MAX];
		trimmed(tail, after, sizeof after);
		if (!ci_eq(after, "shifted")) {
			snprintf(err, errlen,
				 "position %s: `shifted` or nothing after the number", rest);
			return -1;
		}
		*shifted = 1;
	}
	unsigned long v;
	// u8 first and then the table's own length, because muir reports them
	// differently: 0o400 does not fit a u8 and 0o200 does.
	if (rust_int(number, 8u, 0xFFul, &v) != 0) {
		snprintf(err, errlen, "position %s: the number is in octal", number);
		return -1;
	}
	if (v >= 128ul) {
		snprintf(err, errlen, "position %s: the table is 128 positions", number);
		return -1;
	}
	*position = (uint8_t)v;
	return 0;
}

// `key_of`: one of MIT's names, `position <octal> [shifted]`, a shifting key
// with an optional side, or the character a character key gives --- in that
// order, which is the order a name is looked for in.
int key_key_of(const char *word, uint8_t *position, uint8_t *shifted,
	       char *err, size_t errlen)
{
	for (unsigned p = 0; p < 128u; ++p)
		if (KEY_TABLE[p].kind == KEY_NAMED && ci_eq(KEY_TABLE[p].name, word)) {
			*position = (uint8_t)p;
			*shifted = 0;
			return 0;
		}

	char first[WORD_MAX];
	const char *rest;
	split_once(word, first, sizeof first, &rest);
	// `strip_word(word, "position")`: it takes a first word AND a rest, so
	// a bare `position` is not this form and falls through to be no key.
	if (*rest && ci_eq(first, "position"))
		return position_of(rest, position, shifted, err, errlen);

	unsigned side = 0;
	const char *name = word;
	char side_name[WORD_MAX];
	if (*rest && (ci_eq(first, "left") || ci_eq(first, "right"))) {
		side = ci_eq(first, "left") ? 0u : 1u;
		trimmed(rest, side_name, sizeof side_name);
		name = side_name;
	}
	for (unsigned s = 0; s < KEY_SHIFT_NAME_COUNT; ++s) {
		if (!ci_eq(KEY_SHIFT_NAMES[s], name))
			continue;
		uint8_t at[4];
		const unsigned n = shifting_at(s, at, 4);
		if (n == 0) {
			snprintf(err, errlen, "%s is on no position", name);
			return -1;
		}
		// `at.get(side).or(at.first())`: asking for the right of a
		// shifting key that has only one position gives that one.
		*position = side < n ? at[side] : at[0];
		*shifted = 0;
		return 0;
	}

	if (word[0] && !word[1] && character_first((uint32_t)(unsigned char)word[0],
						   position, shifted) == 0)
		return 0;

	snprintf(err, errlen, "%s is no key of this keyboard", word);
	return -1;
}

// ---- the mapping -------------------------------------------------------

void key_map_built_in(struct key_map *m)
{
	memset(m, 0, sizeof *m);
	for (unsigned i = 0; i < KEY_BOUND_COUNT; ++i)
		m->bound[i] = KEY_BOUND[i];
	m->bounds = KEY_BOUND_COUNT;
	for (unsigned i = 0; i < KEY_PREFIX_COUNT; ++i)
		m->after[i] = KEY_PREFIX[i];
	m->afters = KEY_PREFIX_COUNT;
}

// `BTreeMap::insert`: an entry already there is REPLACED, so a later line
// wins over an earlier one and a file's line wins over the built-in.
static int bind_key(struct key_map *m, uint32_t keysym, uint8_t position, uint8_t shifted,
		    char *err, size_t errlen)
{
	for (unsigned i = 0; i < m->bounds; ++i)
		if (m->bound[i].keysym == keysym) {
			m->bound[i].position = position;
			m->bound[i].shifted = shifted;
			return 0;
		}
	if (m->bounds >= KEY_MAP_BOUND_MAX) {
		snprintf(err, errlen, "more than %d key bindings", KEY_MAP_BOUND_MAX);
		return -1;
	}
	m->bound[m->bounds].keysym = keysym;
	m->bound[m->bounds].position = position;
	m->bound[m->bounds].shifted = shifted;
	++m->bounds;
	return 0;
}

static int bind_prefix(struct key_map *m, uint32_t first, uint32_t second,
		       uint8_t position, uint8_t shifted, char *err, size_t errlen)
{
	for (unsigned i = 0; i < m->afters; ++i)
		if (m->after[i].first == first && m->after[i].second == second) {
			m->after[i].position = position;
			m->after[i].shifted = shifted;
			return 0;
		}
	if (m->afters >= KEY_MAP_PREFIX_MAX) {
		snprintf(err, errlen, "more than %d prefixed bindings", KEY_MAP_PREFIX_MAX);
		return -1;
	}
	m->after[m->afters].first = first;
	m->after[m->afters].second = second;
	m->after[m->afters].position = position;
	m->after[m->afters].shifted = shifted;
	++m->afters;
	return 0;
}

// `read_into`, line for line, onto a mapping of its own so that a file which
// fails part way through changes nothing.
static int read_into(struct key_map *m, const char *text, char *err, size_t errlen)
{
	unsigned n = 0;
	char what[KEY_MAP_ERR_MAX];
	for (const char *p = text; ; ) {
		const char *nl = strchr(p, '\n');
		const size_t len = nl ? (size_t)(nl - p) : strlen(p);
		++n;
		if (len > LINE_MAX) {
			snprintf(err, errlen, "line %u: longer than %d characters", n, LINE_MAX);
			return -1;
		}
		char raw[LINE_MAX + 1];
		memcpy(raw, p, len);
		raw[len] = '\0';
		// Rust's `str::lines` drops a `\r` before the `\n`, and
		// `trim` would have anyway.  Said here because the file is
		// edited on a laptop over a FAT32 partition and arrives with
		// CRLF more often than not.
		char line[LINE_MAX + 1];
		trimmed(raw, line, sizeof line);

		if (line[0] && line[0] != '#') {
			char word[WORD_MAX];
			const char *rest_raw;
			split_once(line, word, sizeof word, &rest_raw);
			char rest[WORD_MAX];
			trimmed(rest_raw, rest, sizeof rest);
			what[0] = '\0';

			if (strcmp(word, "key") == 0) {
				char sym[WORD_MAX], key[WORD_MAX];
				uint32_t keysym;
				uint8_t position, shifted;
				if (two(rest, sym, sizeof sym, key, sizeof key,
					what, sizeof what) != 0
				    || key_sym_of(sym, &keysym, what, sizeof what) != 0
				    || key_key_of(key, &position, &shifted,
						  what, sizeof what) != 0
				    || bind_key(m, keysym, position, shifted,
						what, sizeof what) != 0) {
					snprintf(err, errlen, "line %u: %s", n, what);
					return -1;
				}
			} else if (strcmp(word, "prefix") == 0) {
				char a[WORD_MAX], b[WORD_MAX], key[WORD_MAX];
				char tail[WORD_MAX];
				uint32_t first, second;
				uint8_t position, shifted;
				if (two(rest, a, sizeof a, tail, sizeof tail,
					what, sizeof what) != 0
				    || two(tail, b, sizeof b, key, sizeof key,
					   what, sizeof what) != 0
				    || key_sym_of(a, &first, what, sizeof what) != 0
				    || key_sym_of(b, &second, what, sizeof what) != 0
				    || key_key_of(key, &position, &shifted,
						  what, sizeof what) != 0
				    || bind_prefix(m, first, second, position, shifted,
						   what, sizeof what) != 0) {
					snprintf(err, errlen, "line %u: %s", n, what);
					return -1;
				}
			} else {
				snprintf(err, errlen, "line %u: %s is not `key` or `prefix`",
					 n, word);
				return -1;
			}
		}

		if (!nl)
			break;
		p = nl + 1;
		// A file ending in a newline has no line after it, which is
		// what Rust's `lines` gives and what a line count has to agree
		// with.
		if (!*p)
			break;
	}

	// A keysym is a key or a prefix, never both: the first press would
	// have to be two things at once.  Checked over the WHOLE mapping after
	// the file, so a file's `key Scroll_Lock ...` collides with the
	// built-in prefixes and a file's `prefix Escape ...` with the built-in
	// key.  No line number: the two halves need not be on one line, or in
	// one file.
	//
	// A file that makes TWO collisions at once is told about one of them,
	// and which one can differ from muir: muir walks a sorted map and
	// names the lowest pair, this walks the array and names the first
	// entry, which is the built-in bindings before anything a file added.
	// Both sentences are true and the second collision is still there to
	// be found on the next try.
	for (unsigned i = 0; i < m->afters; ++i)
		for (unsigned j = 0; j < m->bounds; ++j)
			if (m->after[i].first == m->bound[j].keysym) {
				char nm[64];
				snprintf(err, errlen, "%s is bound as a key and used as a prefix",
					 key_sym_name(m->after[i].first, nm, sizeof nm));
				return -1;
			}
	return 0;
}

int key_map_read(struct key_map *m, const char *text, char *err, size_t errlen)
{
	struct key_map trial = *m;
	if (read_into(&trial, text, err, errlen) != 0)
		return -1;
	*m = trial;
	return 0;
}

int key_map_read_file(struct key_map *m, const char *path, char *err, size_t errlen)
{
	char what[KEY_MAP_ERR_MAX];
	FILE *f = fopen(path, "r");
	if (!f) {
		snprintf(err, errlen, "%s: %s", path, strerror(errno));
		return -1;
	}
	// A mapping file is a page or two; the built-in one is 4,791 bytes.
	// A file past this is refused rather than read in half, which would
	// be a mapping that is neither the file's nor the built-in one.
	static char text[64 * 1024];
	const size_t got = fread(text, 1, sizeof text - 1, f);
	const int full = !feof(f);
	fclose(f);
	text[got] = '\0';
	if (full) {
		snprintf(err, errlen, "%s: longer than %zu bytes", path, sizeof text - 1);
		return -1;
	}
	if (key_map_read(m, text, what, sizeof what) != 0) {
		snprintf(err, errlen, "%s: %s", path, what);
		return -1;
	}
	return 0;
}
