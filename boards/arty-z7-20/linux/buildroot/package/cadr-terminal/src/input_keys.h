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
// And one thing that is NOT a mapping limit: **microcode 323's cold-boot test
// reads the keyboard's own BOOT WORD, and an earlier note here read it as a
// key position and concluded the opposite.**  The microcode takes the low six
// bits of the keyboard word and compares them against `0o46`, MIT's comment
// reading "This is cold-boot if key is RUBOUT" --- and `0o46` is the low six
// bits of the cold BOOT word, which `ukbd.lisp` gives as "5-0 46 (octal) if
// cold, 62 (octal) if warm".  So the test is the far end of the boot sequence
// this file implements: the keyboard reboots the machine through a wire of
// its own and leaves the word in the register, and the microcode reads it to
// learn which boot was asked for.  `0o46` is ALSO the Status key's position,
// which is the coincidence that made the wrong reading easy; Rubout is
// `0o23`.  `input_face.h` has the flush, which is this program's part in it.
//
// ## The boot sequence is the KEYBOARD's, and it is not the autoboot test
//
// **THE KEYBOARD BOOTS THE MACHINE, AND THE MACHINE IS NOT ASKED.**  The
// keyboard has its own microprocessor and `sys/io1/ukbd.lisp` is its
// firmware.  Its `check-boot` runs after every key-down: with the Controls
// and Metas held along with Rubout it sends the COLD boot code, and with
// Return the WARM one, and the I/O board decodes that word itself and pulls
// `-BOOT*` --- no microcode is involved and no register is read.  The
// firmware's own comment: "Is request to boot machine if both controls and
// both metas are held down, along with rubout or return."
//
// Then it holds its tongue.  `bootflag` is set after the boot word and
// cleared at the next key-down, and while it is set NO key-up code is sent:
// "This gives the machine time to load microcode and read the character to
// see whether it is a warm or cold boot, before sending any other characters,
// such as up-codes."  That is the whole of the firmware's part and it is
// `check_boot` and `hold_back` below, in the two places a word is queued.
//
// **WHICH Controls and Metas IS A SETTING**, `--keyboard-boot`, muir's
// `BootKeys`: the keyboard's own sequence is both of each, and a host
// keyboard rarely has two Controls and two Metas free to map, so the default
// is either Control and either Meta --- which is Ctrl-Alt-Del pressed on any
// keyboard anyone has, `Alt_L` being Meta in the built-in mapping.
//
// **IT IS NOT THE AUTOBOOT TEST, AND IT IS WHAT THAT TEST READS.**  Microcode
// 323 at `(LOC 6)` reads the keyboard's STATUS register and takes a cold boot
// when `KBD READY` is clear: that is the machine asking, once, as it starts,
// whether anybody is typing, where the sequence here is the keyboard telling
// the machine to start over at any time through a wire of its own.  They meet
// four instructions later, where the microcode reads `764100` and cold-boots
// on `0o46` in the low six bits --- which is the word this file sends.  So
// the hold-back matters at both ends: the word has to still be in the
// register when the microcode looks.  `input_face.h` has the flush, which is
// the same register's other hazard.
//
// **Held keys only.**  A key tapped rather than held --- behind a prefix, or
// with the Shift worked around it --- is not down here and does not complete
// the sequence, which is muir's rule and the same one for the same reason: a
// tap is a key the machine sees go down and come up in one breath, and the
// firmware tests the keys that are DOWN.  The real firmware compares whole
// bytes of its bit map, so on the keyboard itself another key down in the
// same byte as one of the four --- a Shift, at 24 or 25 beside the Controls
// --- defeats the sequence; here, as in muir, only the keys named count.
//
// ## The mapping is a value here, not a table
//
// ## The trace, and it is muir's line
//
// **`--keyboard-mapping-trace`, AND IT PRINTS muir'S OWN LINE.**  muir's
// `Keyboard::key_traced` writes one line for every keysym that arrives ---
// the keysym by name and by number, whether it went down or up, what it
// became, and what the keyboard's own firmware then did with it --- and
// `key_event_traced` below writes the SAME line, word for word, for every
// keysym the two programs share a vocabulary for.  That is the point of it:
// somebody who has read one machine's trace reads the other's.
//
// The one thing this line carries that muir's cannot is WHERE the keysym came
// from, because muir has one keyboard and this program has two sources for
// it: a viewer over RFB, and `cadr-usb-input` over the input link.  So the
// source is written after `down` or `up`, where the sentence has room for it,
// and with no source named the line is muir's exactly.
//
//     keysym 0x42 B down from a viewer, B
//     keysym 0x42 B down, B                      (muir's own line)
//
// `enum key_went_kind` is muir's `Went` and `key_went_text` is its `Display`:
// what a keysym became is a VALUE that `key_event` hands back, and not a
// branch that prints for itself, because the same eight answers are what the
// check holds the wording to.
//
// **AND IT SWITCHES WHILE THE PROGRAM RUNS.**  A trace is a diagnostic
// somebody wants for the minute they are looking at a keyboard, and a board
// that has to be restarted to get one is a board whose Lisp is lost to get
// it.  So `SIGUSR1` turns it on and `SIGUSR2` turns it off ---
// `key_trace_signals` installs them and `key_trace_apply` acts on them once a
// pass of the program's own loop, which is where `say` may be called from ---
// and `cadr-console trace-keys on` is the word that sends them.  The flag is
// how a run STARTS with it on and is nothing else.

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

#include <stddef.h>
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

// `keyboard::boot`: the two boot codes.  `ukbd.lisp`'s protocol section gives
// the word as "15-10 1, 9-6 0, 5-0 46 (octal) if cold, 62 (octal) if warm",
// over the same frame every other word carries.  The I/O board decodes bits
// 13-6 of it and nothing else --- ones in 13-10 over zeros in 9-6 --- and
// pulls `-BOOT*`, which is why the low six bits may say which boot without
// the decode caring.
#define KEY_BOOT_COLD 046u
#define KEY_BOOT_WARM 062u

static inline uint32_t key_boot_word(int cold)
{
	return KEY_FRAME | (077u << 10) | (cold ? KEY_BOOT_COLD : KEY_BOOT_WARM);
}

// The two keys the sequence ends on, by position.  `check-boot` names them
// itself --- "rubout 23, return 136" --- and MIT's table has them there.
#define KEY_POS_RUBOUT 0023u
#define KEY_POS_RETURN 0136u

// **THE KEYS THE BOOT SEQUENCE NEEDS**, `--keyboard-boot`: how many Controls
// and how many Metas have to be held with Rubout or Return.  muir's
// `keyboard::BootKeys`, and for muir's reason: the CADR keyboard's own
// sequence is BOTH Controls and BOTH Metas, and a host keyboard rarely has
// two of each free to map, so the keys to hold are a setting rather than a
// fact.  One of a word is either key of its pair, two is both.
struct key_boot {
	unsigned char controls, metas;
};

// The four spellings, which are the only four settings there are, in the
// wording a refusal prints.
#define KEY_BOOT_SPELLINGS \
	"`ctrl,meta`, `ctrl,ctrl,meta`, `ctrl,meta,meta` or `ctrl,ctrl,meta,meta`"

// `BootKeys::parse`: `ctrl` and `meta`, comma-separated, counted, in any
// order, and nothing else.  0, or -1 having written muir's own refusal into
// `why`.  Rubout and Return are never in it.
int key_boot_parse(const char *s, struct key_boot *out, char *why, unsigned n);

// `BootKeys::fmt`: the spelling `key_boot_parse` reads, Controls first.
void key_boot_spelling(struct key_boot b, char *out, unsigned n);

// **What the keyboard's own firmware did with the last key**, over and above
// the mapping: muir's `Firmware`, which its trace says on the line after what
// the key became.  Cleared at every key event and set by the two places a
// word is queued.
enum key_firmware {
	KEY_FW_NONE = 0,
	// The sequence was complete after this key-down and the boot word
	// went after its own word.
	KEY_FW_BOOT_COLD,
	KEY_FW_BOOT_WARM,
	// The key-up was held back: `bootflag` is set, and no key-up goes
	// until the next key-down.
	KEY_FW_HELD_BACK
};

// **WHAT A KEYSYM BECAME**, which is muir's `Went` and is the only thing that
// says which half of a key's journey is wrong.  A viewer chooses the keysym it
// sends for a physical key --- RFC 6143 leaves that to it --- so the source is
// the only authority on which keysym arrived, and the mapping is the only
// authority on what it meant.
enum key_went_kind {
	// The mapping has nothing for it.  The answer to "why does this key do
	// nothing".
	KEY_WENT_UNBOUND = 0,
	// Held as a prefix: nothing goes down the cable until the keysym after
	// it.  **Saying so is the point** --- a prefix's press produces no key
	// by design, and printing nothing for it would look exactly like
	// `KEY_WENT_UNBOUND`.
	KEY_WENT_HELD_AS_PREFIX,
	// The prefix pressed again, which is the way out of a sequence begun by
	// mistake.
	KEY_WENT_PREFIX_LET_GO,
	// Looked up behind a standing prefix, and what was there.
	KEY_WENT_BEHIND,
	// Sent to a key: its position, the plane wanted, and whether the
	// terminal had to work the shift around it.
	KEY_WENT_SENT,
	// Found on a key and refused there: the queue was full, `KEY_BACKLOG`
	// words the machine has not read, and the press was refused whole.
	// **Said, and not folded into `KEY_WENT_SENT`**: a keystroke refused
	// here is a character that does not type, and a trace that called it
	// sent would be asserting the opposite of what happened to the one
	// person reading it for exactly this.
	KEY_WENT_REFUSED,
	// Nothing went down the cable, and why.  Every one of these is by
	// design rather than a mapping that is short of a line.
	KEY_WENT_NOTHING
};

struct key_went {
	int kind;
	// The key it reached, and the plane: `KEY_WENT_SENT`,
	// `KEY_WENT_REFUSED`, and `KEY_WENT_BEHIND` when `found`.
	uint8_t p, shifted, tapped, found;
	// `KEY_WENT_BEHIND`: the prefix's own keysym.
	uint32_t first;
	// `KEY_WENT_NOTHING`: muir's own words for why, a literal.
	const char *why;
};

// The longest line the trace writes, with room for a key's name and a
// keysym's: the refusal is the longest of the eight and is under 160.
#define KEY_TRACE_MAX 256
// The longest a key's or a keysym's name is written as.  MIT's longest is
// `Right Hyper` at eleven and X11's is `ISO_Level3_Shift` at sixteen; a
// position written out instead is shorter than either.
#define KEY_NAME_MAX 64

// How many words wait here while the machine is not reading the keyboard.
// muir's `keyboard::BACKLOG`, and for muir's reason: the keyboard's own
// firmware has a shift register and no queue, so a viewer typing faster than
// the machine reads has to be held somewhere, and the far end is the only
// place with room.  This is where a burst goes.
//
// **AND IT IS A LONG WAY DEEPER THAN THE FABRIC'S OWN QUEUE, WHICH IS THE
// POINT.**  An earlier note here said the fabric held enough that this need
// not poll at the card's 8 us rate.  The card's rate was never the constraint
// and the fabric's sixteen words are not a buffer to type into: a word may
// only go when the machine has taken the last AND the interval has gone by
// --- `input_face.h`'s two rules --- so twenty characters is forty words and
// about 48 ms, and every one of them waits here meanwhile.  Two hundred and
// fifty-six is roughly six seconds of the fastest typing anybody does.
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
	// The keys the boot sequence needs: `--keyboard-boot`, the default
	// `ctrl,meta`.  `key_state_init` sets it; `key_boot_set` moves it.
	struct key_boot boot;
	// **The firmware's `bootflag`**: the boot word has gone, and no key-up
	// goes until the next key-down.  Not a fourth piece of the state
	// machine in `key_event` --- that function never reads it.  It is the
	// firmware's, under the mapping, read and written in the two places a
	// word is queued, which is where the firmware keeps it.
	int hold_back;
	// What the firmware's part did with the last key, for the trace and
	// for the check: `enum key_firmware`.
	int firmware;
	// `--keyboard-boot-trace`: say on the log when a key-up is held back.
	int boot_trace;
	// `--keyboard-mapping-trace`: say what every keysym arrived as and what
	// it became.  muir's `Keyboard::trace`, and switched by the same two
	// signals at run time.
	int trace;
	// What the last keysym became, for the trace and for the check: muir's
	// `Went`, handed back by `key_event` rather than printed by it.
	struct key_went went;
	// How many boot words have gone, and how many key-ups were held back
	// behind them, for the summary line.
	unsigned long boots, held_back;
	// **AND WHAT WAS DROPPED WITHOUT BEING REFUSED, WHICH MUST STAY 0.**
	// `push` is silent when the queue is full, so a caller that asked for
	// room for one word and then pushed four left the machine half a
	// keystroke --- a Shift down whose release went nowhere.  Every caller
	// reserves the whole burst now; this counts the case that says one did
	// not, and the check holds it at zero.
	unsigned long dropped;
};

// `Keyboard::new`: the built-in mapping.
void key_state_init(struct key_state *k);

// `Keyboard::with_mapping`: a mapping somebody read from a file, copied in.
void key_state_init_with(struct key_state *k, const struct key_map *map);

// `Keyboard::set_boot_keys`: the keys the boot sequence needs from now on.
void key_boot_set(struct key_state *k, struct key_boot b);

// `--keyboard-boot-trace`: say when a key-up is held back behind a boot word.
// The boot word itself is said either way --- it is one line, it is rare, and
// a machine asked to reboot because somebody typed a chord is exactly what
// this program's log is for --- and this adds the key-ups, which are one line
// a keystroke and would be noise otherwise.  muir prints both under
// `--keyboard-mapping-trace`, and so does this program: with that trace on, a
// key-up held back says so on its own line as part of what the key became, and
// this flag is the way to have that one line without the rest.
void key_boot_traced(struct key_state *k, int on);

// `Keyboard::traced`: print every keysym as it arrives and what it became.
// **On the log**, where every line of this program goes, and not on stderr as
// muir's does: muir runs beside a prompt that owns stdout, and this runs as a
// daemon whose stderr `start-stop-daemon -b` sends to /dev/null.
void key_traced(struct key_state *k, int on);

// `SIGUSR1` turns the trace on and `SIGUSR2` turns it off, so that a keyboard
// can be watched without restarting the program and losing the Lisp on the
// machine.  `key_trace_signals` installs the two handlers; `key_trace_apply`
// acts on what they asked for and says one line when it CHANGES, and is
// called once a pass of the program's loop --- not in the handler, where
// `say` may not be called.  Idempotent: a second `SIGUSR1` says nothing.
void key_trace_signals(void);
void key_trace_apply(struct key_state *k);

// A key from the viewer, by X11 keysym, going down or coming up.
// `muir::terminal::keyboard::Keyboard::key`.
void key_event(struct key_state *k, uint32_t keysym, int down);

// ...and from a named source: `a viewer`, or `the input link`.  The only
// difference is the trace's line, which says where the keysym came from; with
// `source` NULL the line is muir's exactly.
void key_event_from(struct key_state *k, uint32_t keysym, int down, const char *source);

// `Keyboard::key_traced`: the key acted on, and the line the trace writes for
// it written into `out`, which wants `KEY_TRACE_MAX` bytes.  Returned as well
// as printed so that the check can hold the wording without capturing a
// stream, which is muir's own reason for handing its line back.  The key is
// acted on either way: this is `key_event_from` with the line handed back.
const char *key_event_traced(struct key_state *k, uint32_t keysym, int down,
			     const char *source, char *out, size_t n);

// `Went`'s `Display`: what a keysym became, in muir's own words.  For the
// check, which holds the eight answers to muir's wording one at a time.
const char *key_went_text(const struct key_went *w, char *out, size_t n);

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
