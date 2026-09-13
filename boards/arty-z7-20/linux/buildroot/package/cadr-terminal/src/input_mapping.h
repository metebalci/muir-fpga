// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// What a viewer's keysyms mean on the Lisp Machine keyboard, and the file
// that may say something else.
//
// **THIS IS `muir::terminal::keyboard::Mapping` IN C.**  `input_keys.c` is
// the state machine over a mapping; this is the mapping itself and the
// parser that reads one.  The file's grammar, the names it may use, the
// order the forms are tried in and the words of every error the PARSER gives
// are muir's, so that a file written for one program is the same file for the
// other and a mistake in it is reported the same way twice.
//
// The one message that is not muir's is the one for a file that cannot be
// opened.  muir spells that with Rust's own `io::Error`, which appends `(os
// error 2)` to it; this uses `strerror`, which is C's way of saying the same
// thing and stops at `No such file or directory`.  Everything up to and
// including the path is identical.
//
// ## The file
//
//     key    <keysym> <key>            one host key
//     prefix <keysym> <keysym> <key>   press the first, then the second
//
// A line is trimmed; an empty one and one whose first character is `#` are
// skipped.  **A `#` anywhere else is not a comment** --- muir's
// `read_into` tests `starts_with('#')` and nothing else --- so `key 0x23 #`
// binds the number sign and is not a truncated line.  The last field is the
// REST of the line, which is why `Alt Mode` and `Left Control` need no
// quoting, and there is no quoting to be had.
//
// `key` and `prefix` are the only two words and they are the only
// case-SENSITIVE thing here; every name after them is matched with ASCII
// case folding.
//
// **A FILE GOES OVER THE BUILT-IN MAPPING RATHER THAN REPLACING IT.**  A
// `key` line replaces the binding for that keysym and a `prefix` line the
// binding for that pair; every keysym the file says nothing about keeps
// what it had.  So a file with one line in it changes one key.  There is no
// way to unbind: a binding can be pointed somewhere else and not removed.
//
// ## What is not here, and where it is instead
//
// **THE DUMP IS muir's AND IS NOT WRITTEN TWICE.**  `muir
// --keyboard-mapping-dump` prints the mapping in exactly this form and is
// in this board's own image, built from the commit `muir.commit` pins ---
// the same commit `input_keymap.h` is generated from, so what it prints IS
// the mapping this program carries.  A second implementation here would be
// a second thing to keep in step for no gain, and writing a dump means
// writing `key_of` backwards as well as forwards.  The way to a starting
// file on the board is therefore:
//
//     muir --keyboard-mapping-dump > /mnt/packs/terminal.keyboard.mapping.txt
//
// ## Where this parts from muir, and why
//
// **A FILE THAT DOES NOT PARSE IS REPORTED AND THE BUILT-IN MAPPING
// STANDS.**  muir stops the run --- "rather than leaving the user with a
// keyboard that is quietly not the one they wrote" --- which is right for a
// program somebody has just typed the name of.  This one is started by
// `S85cadr-terminal` at boot and is the only way to SEE the machine at all,
// and the file it reads is optional and lives on a card a laptop can edit.
// Stopping would mean that a typo in a file nobody needs costs the screen
// as well as the keyboard, discoverable only over the serial console.  So
// the line is refused, the whole file is discarded --- not the lines before
// the bad one --- and one line on the console says which line and what was
// wrong with it.  `S87cadr-chaosnet` takes its defaults and says so for the
// same reason.
//
// **THE TWO TABLES ARE BOUNDED WHERE muir's ARE NOT.**  muir holds its
// bindings in two `BTreeMap`s and has no limit; these are arrays, and a
// file with more than `KEY_MAP_BOUND_MAX` bindings or
// `KEY_MAP_PREFIX_MAX` prefixed ones is refused by name rather than
// silently losing the rest.  Both are 256, against a built-in mapping of 39
// and 22 and a host keyboard of about 110 keys.
//
// **WHITESPACE IS ASCII.**  muir splits on `char::is_whitespace`, which is
// Unicode's; this is `isspace` over unsigned char, which is ASCII's.  They
// differ only on a file carrying something like U+00A0, which muir would
// treat as a separator and this would treat as part of a name --- so such a
// line is refused here and accepted there.  Nothing on MIT's key table or
// in X11's keysym names is outside ASCII.

#ifndef INPUT_MAPPING_H
#define INPUT_MAPPING_H

#include <stddef.h>
#include <stdint.h>

#include "input_keymap.h"

// How many bindings of each kind a mapping holds.  See the header.
#define KEY_MAP_BOUND_MAX 256
#define KEY_MAP_PREFIX_MAX 256

// The longest error this writes, including the file name it is given.
//
// It is larger than a line, on purpose.  `two`'s message quotes the text it
// could not use, and quoting can grow it --- a tab becomes two characters and
// a control character six --- so a buffer the size of a line would let a
// message be cut short at exactly the point it was about to say what was
// wrong.  The cross compiler says so where the host one does not: gcc 14.3
// for the board reports `-Wformat-truncation` on a quote that cannot fit, and
// gcc on the build host is silent.  That is the lesson this repository
// already records about the runner's Verilator being stricter than the local
// one, met in C.
#define KEY_MAP_ERR_MAX 320

struct key_map {
	struct key_binding bound[KEY_MAP_BOUND_MAX];
	unsigned bounds;
	struct key_prefix after[KEY_MAP_PREFIX_MAX];
	unsigned afters;
};

// `Mapping::built_in`: `KEY_BOUND` and `KEY_PREFIX`, which are muir's own
// `default.keys` resolved by `keymap_from_muir.py`.
void key_map_built_in(struct key_map *m);

// `Mapping::read_into` over a mapping already in `m`: every line of `text`
// applied, the whole file or none of it.
//
// 0 and `m` changed, or -1 with `m` UNTOUCHED and muir's own message in
// `err`.  A partial file is never applied, which is what `Mapping::from_file`
// gets from building a fresh `Mapping` and dropping it on an error.
int key_map_read(struct key_map *m, const char *text, char *err, size_t errlen);

// ...from a file.  The message is `<path>: <what read gave>`, as
// `Mapping::from_file` writes it, and an unreadable file is reported the
// same way.
int key_map_read_file(struct key_map *m, const char *path, char *err, size_t errlen);

// `keysym_name`: the X11 name of a keysym, else the character it is, else
// its number as `0x...`.  Written into `out` and returned, so that it can be
// used twice in one message.  This is here because the error about a keysym
// bound as a key and used as a prefix names one.
const char *key_sym_name(uint32_t keysym, char *out, size_t outlen);

// `keysym_of` and `key_of`, for the check to reach on their own: -1 on a
// word neither understands, with muir's message in `err`.
int key_sym_of(const char *word, uint32_t *out, char *err, size_t errlen);
int key_key_of(const char *word, uint8_t *position, uint8_t *shifted,
	       char *err, size_t errlen);

#endif
