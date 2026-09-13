<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The screen, and the keyboard and mouse

`cadr-terminal` is the program on the processing system that shows the CADR's
display to a VNC viewer and carries the viewer's keys and pointer back to the
machine. The screen was written at the first slice, against muir at
`dad7249` and the fabric at the commit that added this file. The keyboard and
the mouse came at a second slice, against muir at `ff5de42`, once the I/O
board was in the fabric.

The display block is built and checked (`docs/tv.md`), and nothing could look
at what it draws. **It needs no new fabric to fix that**, which is why this
came next. `rtl/machine/cadr_tv.sv` keeps no frame buffer of its own. A cycle
to the window at `0o17000000` is answered by main memory's bridge, at the
display's own base in PS DDR3. So the picture the machine draws is 92,448
bytes of ordinary DDR, and Linux can map it. The screen comes first and the
keyboard and mouse later, when the I/O board exists.

## What it is, and what it is not

    cadr-terminal [--port N] [--bind ADDR] [--log PATH] [--bow]
                  [--window ADDR] [--interval-ms N] [--no-rre]
                  [--no-guard] [--no-input] [--input ADDR]
                  [--keyboard-mapping FILE] [--once]

It maps 128 KB at `0x1C00_0000` through `/dev/mem`. It copies the visible
23,112 words out of that once a frame while anybody is watching. It serves them
over RFB on port 5900, which is display `:0`. RFB is RFC 6143, which is what a
VNC viewer speaks. `S85cadr-terminal` starts it at boot.

**It carries the keyboard and the mouse, and a file may say what its keys
mean.** It did not carry them at first, because there was no I/O board in the
fabric to put a keystroke into. There is one now.
`rtl/plumbing/cadr_input_cables.sv` is the far end of the card's keyboard
cable and its mouse, on the fourth page of `M_AXI_GP0` at `0x4000_3000`. A
viewer's `KeyEvent` becomes a stream of twenty-four-bit words and its
`PointerEvent` becomes deltas and a button mask. The mapping is muir's own,
and so is the file that may replace a line of it: the section below says what
the file looks like and what could not be mapped without one.

**It is read-only where the fabric has no input cables.** A bitstream without
them answers `IDENT` with something other than "INPT", and the program says so
and serves the screen anyway. `--no-input` asks for that deliberately. In
either case a viewer's events are read off the wire, counted and dropped: RFC
6143 gives a server no way to tell a viewer it takes no input, and every
viewer sends pointer events as the mouse crosses its window, so refusing the
connection would be worse than dropping them.

**It has no authentication.** `None` is the only security type offered (RFC
6143 section 7.2.1), so anybody who can reach the port sees the screen. That
is the decision the rest of this image already makes, since root logs in with
the password `root` over Dropbear. It is stated in the program's own
opening line rather than left to be discovered. `--bind 127.0.0.1` restricts
it to the board itself, and a viewer then reaches it over an SSH tunnel.

**It cannot read `MODE BOW`.** Whether a one bit shows white or black is four
flops in the fabric (`rtl/machine/cadr_tv.sv:141`, cleared to zero at `:195`).
Nothing carries them to the processing system. `M_AXI_GP0` is the disk's and
`M_AXI_GP1` is the console's, and neither has a word for the display. So the
default is the fabric's own power-on state and muir's, which is zero, and a
one bit is white. That is also the mode both reference programs leave the
register in (`docs/tv.md`: "the mode register stays 0 ... for the whole run"),
and `--bow` swaps it. The assumption is right for every program this project
has run. It is written down here so that a screen that comes out inverted is
diagnosed in one step.

**Reading it is fabric work and not program work, which is why it is still
not built.** The flops are inside `cadr_tv`, and a program on the processing
system can reach a fabric register only through one of the two general-purpose
ports. So the change is three files and one commit, none of them this
program's:

1. `rtl/machine/cadr_tv.sv` gives `mode` an output port. The register already
   exists and is already read back over the Xbus, so this adds no state.
2. `rtl/machine/cadr_machine.sv` carries that port up. The machine's outputs
   are checked mechanically against its port list, so a port added here and
   not folded is caught.
3. `rtl/plumbing/cadr_console.sv` puts `mode[3:0]` in a word of its register
   face, which is where the processing system can read it over `M_AXI_GP1`.

An EMIO GPIO bit beside the memory tally is the other shape, and it is worse
for one reason: the tally's own bits are already spoken for, and a fifth
instrument on a port with no decode is harder to extend than a word on a face
that has thirty-two of them. Once the word exists, this program drops
`--bow`'s guess and reads it, which is one call and one line of the start-up
message.

**It does not stop the machine to read a frame.** The CADR writes the window
while the copy is being made, so a copy can hold the top of the screen from
before a write and the bottom from after it. There is no interlock to take.
muir's terminal has the same seam, and the vertical flag the microcode uses is
a counter in the fabric with no path to Linux. A torn frame is one frame.

## The geometry, and where every number came from

The classic failure of a program like this one is a picture served upside
down, mirrored, or in the wrong colours. It is cheap to get right by reading.
`screen_geom.h` carries the table below beside the code, and `screen_test.c`
pins the mapping on hand-computed pixels.

| | | from |
|---|---|---|
| 768 pixels across | `WIDTH` | muir `src/simpletv.rs:65`, `(DEFVAR MAIN-SCREEN-WIDTH (:CADR 768.))` |
| 963 lines | `HEIGHT` | muir `src/simpletv.rs:69`, `(:CADR 963.)`, "was 896. for CPT" |
| 24 words to a line | `WORDS_PER_LINE` | muir `src/simpletv.rs:73`, `MAIN-SCREEN-LOCATIONS-PER-LINE` |
| one bit a pixel | | muir `src/simpletv.rs:7`; `docs/tv.md` |
| 32,768 words in the window | `BUFFER_WORDS` | muir `src/simpletv.rs:43`; `rtl/plumbing/cadr_ddr_map.sv:71` |
| 23,112 of them are the screen | `visible()` | muir `src/terminal/mod.rs:88`; 963 x 24 |
| the window is at `0x1C00_0000` | `DISPLAY_BASE` | `rtl/plumbing/cadr_ddr_map.sv:67` |
| word *n* is at base + 4*n* | `display_byte_address` | `rtl/plumbing/cadr_ddr_map.sv:83`; `rtl/plumbing/cadr_xbus_ddr.sv:87` |
| a frame is 15,456,000 ns | `FRAME_NS` | muir `src/simpletv.rs:145`; `rtl/machine/cadr_tv.sv:123` |

**Which bit is which pixel.** muir `src/simpletv.rs:254-257`:

    pub fn pixel(&self, x: usize, y: usize) -> bool {
        let bit = y * WORDS_PER_LINE * 32 + x;
        self.buffer[bit / 32] >> (bit % 32) & 1 != 0
    }

A line is 24 consecutive words, the first line first. Within a line the pixels
run from the **low** end of the first word, so **bit 0 of a word is the
leftmost of the 32 pixels it carries**. muir says the same in its own words at
`src/terminal/mod.rs:216`: "entry `b` is the frame-buffer byte `b`, its bit
0 first, bit 0 being the leftmost pixel". It states the whole rule again at
`src/terminal/mod.rs:97`, where `tests/terminal.rs` holds the two expressions
to each other pixel for pixel. This program is the third expression, and it has
the same pair inside it. `screen_geom.h`'s `screen_lit` is the rule, and
`screen_server.c`'s `row_byte` is the rule again as a byte at a time, which is
what a whole-width Raw rectangle actually goes through. **Both are mutated in
`screen_mutations.txt`, and each is caught by exactly one of the check's two
encodings**, which is what says the check reaches both.

**Which way round black and white are.** muir says it at
`src/simpletv.rs:247-250` and `:268-270`. A lit bit shows **white** unless
`MODE BOW` is set, and the other way round when it is. That is `MODE<2>`, at
`simpletv.rs:100`, "display one bits as black and zeros as white". So a screen
of zeros with BOW clear is **black**, and that is what a real machine looks
like. muir drawing MIT's System 100 band at microcycle 200,000,000 has mode 0
and 7,572 of its 739,584 pixels lit: **white text on black, one per cent of
the screen**.


## What a key is, and what the machine is told

**There are no modifier bits in a key event.** The CADR's keyboard --- source
ID 1, the one with the three 74LS164s --- sends a key POSITION going down and
the same position coming up, and nothing else. MIT's own `ukbd.lisp` says why:
"All key-encoding, including hacking of shifts, will be done in software in the
central machine, not in the keyboard." So Shift, Control, Meta, Super, Hyper,
Top and Greek are keys at positions of their own. The machine works out what
was typed from the stream.

The word is `muir::terminal::keyboard::up_down`. Bits 23 to 19 are all ones,
"Reserved, must be 1's". Bits 18 to 16 are the source ID. Bit 8 is "1=key up,
0=key down". The low seven bits are the position on MIT's table. Every word
this keyboard sends therefore has `word >> 16` equal to `0o371`, which is what
the card's high half at `0o764102` carries.

**RFB gives a keysym per event, already shifted.** A viewer pressing shift and
`1` sends `Shift_L` down and then `!`, not `1`. The Lisp Machine wants position
`0o121` with the Shift key down. Where the viewer's shift state and the plane
the keysym wants already agree, the position is simply pressed. Where they do
not, the Shift key is worked around the key: shift down, key down, key up,
shift up, which is what a typist would have done. The key's own release is
then dropped, the terminal having sent it whole already.

**A viewer that goes away has every key it held released.** There are no
modifier bits in a word, so a Control held when a connection drops is a Control
held for the rest of the machine's run, and every character after it is a
control character. RFB has no message for a server to act on here, so the
releases are sent when the last viewer is dropped.

### How fast words may go, and why one word at a time is not enough

**A word goes only when the machine has taken the last one, and no sooner than
1.188 ms after it.** Both rules are needed. The first is the card's own
handshake. The fabric hands the card a word only when `KBD READY` is clear, so
no word is ever written over one the machine has not read. That is
`muir::terminal::keyboard::Keyboard::deliver`'s gate, kept in hardware.

The second rule exists because the first is about the card and not about the
machine behind it. The fabric offers the card its next word about two ticks
after the machine's read clears `KBD READY`. A machine given its keys twenty
nanoseconds apart reads every one of them and digests only some. Behind the
card are the Unibus channel handler and the software above it, and neither is
in any handshake this seam can see.

Both failures were measured on the board. A shifted keystroke is four words:
Shift down, key down, key up, Shift up. Sent back to back they typed `=` where
`+` was meant, the machine having kept the key and not the Shift in front of
it. Twenty characters sent with no gap arrived as nineteen, one missing and one
doubled. The fabric's `LOST` register read zero throughout, so nothing was lost
in the fabric.

**The interval is muir's own rate and is not fitted to those measurements.**
muir attempts one delivery every `TERMINAL_CHECK` microcycles, which is 4,096,
and a microcycle on this board is 29 ticks of 10 ns. So the interval is
4,096 x 290 ns. It is the rate at which the reference emulator has always fed
this same microcode. The board's own passing measurements were 40 ms and 50 ms,
which are about thirty-four times more generous, so they establish only that
twenty nanoseconds is far too close.

The cost is small. A character is two words, so typing runs at about 420
characters a second, and the twenty-character burst above takes 48 ms. Words
waiting their turn are held in the program's own backlog, which is 256 words.
The poll loop shortens its sleep when a word is due, so a keystroke costs the
interval and not a frame.

### The mapping is muir's, and the table is generated from it

`src/input_keymap.h` is written by `src/keymap_from_muir.py`, which reads
muir's `src/terminal/keyboard.rs` and `src/terminal/default.keys` and resolves
every name exactly as muir's own `key_of` resolves it. MIT's key table is
ninety-nine entries and the default mapping is sixty-one bindings. A
transcription error in either would be a key that types the wrong character on
one position in a hundred, which is the kind of mistake that survives every
check that does not happen to press that key. The generator removes that class
of error entirely.

**No build runs the generator.** It needs muir beside the tree, which neither
Buildroot nor CI has. The output is committed and its header names the muir
commit it came from. `muir.commit` at the top of this repository is the pin
every reference here is held to.

**It writes three more tables for the file the section below describes**, which
resolves names at run time and so needs in C what the four above threw away.
`KEY_SYM_NAMES` is muir's own list of X11 keysym names, in its order.
`KEY_SHIFT_NAMES` is what a file calls each of the eleven shifting keys.
`KEY_DEFAULT_MAPPING` is `default.keys` itself, byte for byte, which is the
text muir compiles in. **That last one is the check's reference and is not the
program's built-in map**, and keeping them apart is the point: the check parses
the text with the C parser and requires the result to equal the tables the
generator resolved, so two independent readings of one reference file are held
to each other. A program that built its map by parsing that text would be
compared against itself.

The state machine over the table is written out by hand in `src/input_keys.c`,
function for function against `Keyboard::resolve`, `tap`, `press` and
`release`. A translation of behaviour is not a translation of data, and
pretending otherwise would hide where the judgement is.

### What could not be mapped

Three things, all of them muir's limits rather than this program's.

**A keysym neither bound nor printable ASCII goes nowhere.** `Home`, `Insert`,
`Print`, `Num_Lock` and the arrow keys on their own are examples. muir's
`positions` returns an empty list for anything outside `0x20` to `0x7e` that no
line of `default.keys` names, and nothing goes down the cable. The program
counts them and says how many.

The arrows, the four Roman keys, the two thumbs and the two hands are
reachable, but only behind the `Scroll_Lock` prefix. That is muir's own answer
to a host keyboard with fewer keys than this one: press `Scroll_Lock`, then the
key it names. Twenty-two of MIT's keys are reachable that way and no other.

**Position `0o021` is unreachable on purpose.** MIT's table has plus-minus
there, which is not ASCII, so `keyboard.rs` leaves it undefined and no keysym
finds it.

**`Left Greek` is position `0o035`, which MIT's table labels Right Greek.**
muir looks a shifting key's positions up by walking the table upwards, and
`Left` takes the first one it finds. Greek is the one shifting key of the seven
whose two positions are in the other order: `0o035` is Right and `0o044` is
Left, where Shift, Control, Meta, Super, Hyper and Top all have Left below
Right. So `ISO_Level3_Shift` reaches the right-hand key and MIT's left-hand one
cannot be named by side. It is harmless, both positions being the same shift to
a machine that decodes from the stream, and it is pinned in the check so that
nobody corrects it into a disagreement with muir.

### A file may say something else: `--keyboard-mapping`

**The built-in mapping is a default and not a cage.** A host keyboard has
fewer keys than this one, and which of its keys a viewer can spare differs
from desk to desk. A Mac keyboard has no Scroll Lock at all, and a desktop
that takes Scroll Lock for itself leaves the twenty-two prefixed keys
unreachable. So a file may say what a keysym means, and one line changes the
prefix.

    key    <keysym> <key>            one host key
    prefix <keysym> <keysym> <key>   press the first, then the second

The grammar is muir's and so are the names, the order the forms are tried in,
and the words of every error the parser gives. `src/input_mapping.h` is the
whole of it beside the code. The rules worth having here:

- **A file goes over the built-in mapping rather than replacing it.** A `key`
  line replaces the binding for that keysym and a `prefix` line the binding
  for that pair. Every keysym the file says nothing about keeps what it had.
  So a file of one line changes one key.
- **There is no way to unbind.** A binding can be pointed somewhere else and
  not removed.
- **A keysym is an X11 name, a single printable character, or a number in
  decimal or `0x` hexadecimal.** A key is one of MIT's own names such as `Alt
  Mode`, a shifting key such as `Greek` with an optional `Left` or `Right`,
  the character a character key gives, or `position <octal>` with `shifted`
  after it for the shifted plane. The last field is the rest of the line,
  which is why the two-word names need no quoting.
- **A line whose first character is `#` is a comment and a `#` anywhere else
  is not.** So `key 0x23 #` binds the number sign.
- **`key` and `prefix` are the only case-sensitive words.** Every name after
  them folds ASCII case.
- **A keysym is a key or a prefix and never both**, which is checked over the
  whole mapping after the file rather than a line at a time.

**The file to start from is muir's own dump**, which is not written twice.
muir is in this board's image, built from the commit `muir.commit` pins, and
that is the same commit `src/input_keymap.h` is generated from. So what it
prints is the mapping this program already carries:

    muir --keyboard-mapping-dump > /mnt/packs/terminal.keyboard.mapping.txt

**Where the file lives on the board.** `/mnt/packs/terminal.keyboard.mapping.txt`,
which is the pack partition that `S80cadr-disk-packs` mounts. The name ends in
`.txt` for the reason the Chaosnet program's three settings files do: the
partition is FAT32, so a laptop with a card reader can edit what is on it, and
a suffixless file asks a laptop what should open it. `S85cadr-terminal` passes
`--keyboard-mapping` only when the file is there.

**The file is read only where there is a keyboard to map onto.** It is read
beside the flush, after `IDENT` has answered and before the socket is bound,
so on a bitstream without the input cables it is not read at all and nothing
is said about it. That is the right way round --- a mapping with no keyboard
behind it is moot --- and the line about the screen being served read-only is
already the answer to why a key did nothing.

**A file that does not parse is reported and the built-in mapping stands.**
This is the one place the program parts from muir deliberately. muir stops the
run, on the argument that a keyboard which is quietly not the one you wrote is
worse than no run. That is right for a program somebody has just typed the
name of. This one is started at boot and is the only way to see the machine at
all, and the file is optional and lives on a card. Stopping would mean that a
typo in a file nobody needs costs the screen as well as the keyboard,
discoverable only over the serial console. So the whole file is discarded, not
the lines before the bad one, and one line on the console names the line and
what was wrong with it. The Chaosnet program takes its defaults and says so
for the same reason.

Two smaller differences, both of them limits this program has and muir has
not. The two tables are arrays of 256 entries each, against a built-in mapping
of 39 and 22, and a file past either is refused by name rather than losing the
rest. A line longer than 200 characters is refused rather than cut, because a
buffer that keeps the front of a line can turn a line that would have been
refused into one that binds something.

### And one thing that is not a mapping limit

**Microcode 323's cold-boot test cannot be reached by typing.** The microcode
compares the low six bits of the keyboard word against `0o46`. On this keyboard
`0o46` is the Status key's position and Rubout is `0o23`, so "hold Rubout at
boot for a cold boot" is the old Knight keyboard's behaviour and does not
happen here. What the test does mean for this program is in the section below.

## The autoboot trap, and the program's part in it

**The machine asks whether anybody is typing four instructions into microcode
323.** MIT's `sys/ucadr/uc-cadr.lisp` at `(LOC 6)`:

    (CALL-XCT-NEXT PHYS-MEM-READ)
   ((VMA) (A-CONSTANT 17772045))        ;Unibus 764112, the KBD CSR
    (JUMP-IF-BIT-CLEAR (BYTE-FIELD 1 5) MD COLD-BOOT)

`KBD READY` clear is a cold boot. Ready is a warm one. So a word waiting at
that register when the microcode starts sends the machine down a path nobody
asked for.

The fabric's legs against that are in `rtl/plumbing/cadr_input_cables.sv`'s own
header: nothing but an AXI write can make a strobe, and a machine reset empties
the queue. **The leg that belongs to a program is the flush.** `cadr-terminal`
writes `CTL`'s FLUSH bit after it has read `IDENT` and before it binds its
socket, so a viewer cannot have sent anything yet. A program taking keys from a
device the kernel has been buffering --- `cadr-usb-input`, when it is built ---
must also drain that device before its first write, because the buffering is on
the far side of this seam and no register here can see it.

## The mouse

A `PointerEvent` carries an absolute position and the CADR's mouse counts
deltas, so what crosses the seam is the difference. One count a pixel, right
and down positive, which is `muir::terminal::mouse`'s own convention. The first
event only establishes where the pointer is: without that, a viewer connecting
would fling the machine's cursor from wherever it was to wherever the pointer
happened to enter the window.

The quadrature encoder is in the fabric and not here. A step is 16,000 ns of
the machine's own time, which is 32 real microseconds at this board's tick, so
a program making phases over `M_AXI_GP0` would be writing fifty thousand times
a second. `docs/io-board.md` settled that at the card's second slice: the card
takes the seven lines MIT's mouse drives, and whatever turns a delta into
phases is fabric beside it.

The three switches need no translation. RFB's mask is left 1, middle 2, right
4, and MIT's `buttons-down-mask` is the same three bits in the same order.
muir's `mouse.rs` says so.

**There is one mouse and there are up to eight viewers.** The difference is
taken between whatever position was last reported and the new one, whoever
reported each. With two viewers moving pointers the machine's cursor jumps.
muir has exactly this and for the same reason: the machine has one mouse, and
which of the people watching is holding it is not something RFB says.

## The encodings, and what they cost

**Raw** (RFC 6143 section 7.7.1) is what every server must have and every
viewer must take, so it is the floor. A viewer that offers nothing else, or
offers only encodings this server has not got, is answered in Raw.

**RRE** (section 7.7.2) is the one that compresses runs. It sends a background
pixel and a list of subrectangles of the other colour. muir's terminal declined
it, on the grounds that the screen is one bit a pixel and its own viewer is on
a loopback socket. This one is on a board at the end of a hundred-megabit link,
and the measurement goes the other way. **Which one a rectangle goes in is
decided by measuring both and taking the smaller.** So a screen RRE would lose
on costs the comparison and nothing else. These were measured by `make -C
boards/arty-z7-20/linux/buildroot/package/cadr-terminal/src check`, over a
whole screen at 32 bits a pixel:

    a real CADR screen (muir's, System 100)   Raw 2,958,336   RRE     55,784   53x
    the check's synthetic screen              Raw 2,958,336   RRE    124,928   24x
    a dither, every other pixel               Raw 2,958,336   RRE  4,437,512   Raw is sent

Both numbers are measured, including the one for the encoding that lost. A
decision made by measuring is only reported by giving both sides of it. A
program that quoted RRE only where RRE won would be quoting the win.

A whole screen is 2.9 MB in Raw whatever is on it. A viewer asking for one at
every poll would have this program encode 739,584 pixels instead of sleeping.
So **a whole screen goes to a viewer at most once a frame**, which is
`SCREEN_FULL_UPDATE_NS`, 30.912 ms. That is a frame for muir's reason --- the
machine cannot produce a new picture faster than the display board scans one
--- but it is the **real** frame and not the machine's own. `screen_geom.h`
carries both: `SCREEN_FRAME_NS` is 15.456 ms, muir's figure and the machine's
own time, and `SCREEN_FRAME_REAL_NS` is 30.912 ms, which is the same
3,091,200 ticks at the 10 ns tick this fabric has run at since 2026-09-11.
This interval is compared against `CLOCK_MONOTONIC`, so it is the real one that
belongs here; `docs/tv.md` records why the machine's frame is the slower of the
two and what it would take to change that.
An incremental update is never held back. The diff is by rows of frame-buffer
words, so a run of changed rows is one rectangle the full width of the screen.
The diff is against what the viewer **has**, rather than against a flag in the
fabric. So a write by any route shows up, the processor's or the disk
channel's, and nothing in the fabric has to know a viewer exists.

## What the check holds to

`make -C boards/arty-z7-20/linux/buildroot/package/cadr-terminal/src check`
runs on the build host, with no board. The server is driven from screens made
in the check, and a viewer written for the purpose sits on a real loopback
socket. **736 checks, 0 failures**, then **42 mutations, 42 caught, 0 survived,
0 broken.** The whole thing takes a few minutes.

**And `make check` at the repository root runs it now**, as `terminal.pass`,
beside `chaosnet.pass` and `serial.pass`. It did not before. That was a hole
the first slice left: this program had its own check from the day it was
written and nothing gated on it, so a change to it was gated by whoever
remembered.

- **The mapping, on nine hand-computed anchors**, in both directions of `MODE
  BOW` and in both encodings. One bit set in an empty screen must light
  exactly one pixel, at a coordinate written as a literal. Word 0 bit 0 is
  the top-left, word 0 bit 31 is pixel 31, word 1 bit 0 is pixel 32, word 23
  bit 31 is the last pixel of line 0, word 24 bit 0 is the first of line 1,
  and word 23,111 bit 31 is the bottom-right. **This is the part that cannot be
  a round trip.** A builder and a reader that are wrong the same way agree with
  each other, and the anchors are the thing no such pair can put back.
- **A whole screen, pixel for pixel, in five pixel formats.** They are 32 bits
  a pixel little- and big-endian with the shifts moved, 16-bit 5-6-5, 8-bit
  2-2-2, and a colour-mapped one whose `SetColourMapEntries` must arrive. The
  viewer works the two byte patterns out for itself and refuses a pixel that
  is neither.
- **An incremental update after part of the buffer changes.** The rectangles
  sent are held to the runs of changed rows, computed a second time in the
  check. The viewer's canvas comes out equal to the whole screen. A viewer
  whose screen has not changed is left waiting, which is what RFC 6143 expects.
- **The frame is re-read from the window each pass**, so that a program serving
  its first copy for ever is visible.
- **A viewer that offers only encodings this server has not got** must still be
  served, in Raw. Those are CopyRect, Hextile, ZRLE and two pseudo-encodings.
- **RRE is measured against Raw**, including the dither where Raw is the
  smaller and must be the one used.
- **A viewer that goes in the middle of an update** is dropped. The server
  goes on, and the next viewer gets a whole correct screen.
- **RFB 3.3, 3.7, 3.8 and a version number that is none of them** are all
  served. The last is Apple's `RFB 003.889`, which section 7.1.1 says is to be
  read as 3.3. A viewer asking for a security type that is not offered gets a
  `SecurityResult` of 1 with a reason and is then closed. A message type RFC
  6143 gives no length for has to close the connection, because there is no way
  to skip it.
- **The whole-screen interval** is held by a clock the check owns.
- **The blank states** are each told from the others.

And, for the keyboard and the mouse, with a model of the fabric's register
face behind the two function pointers. **It records and it does not
interpret**: the model keeps the word stream the program wrote and nothing
else, and every expected word is computed by hand from `up_down` and MIT's own
table. A model that turned the words back into keysyms would agree with a
program that was wrong the same way.

- **A plain letter, and its frame bits.** `a` is position `0o123` on the
  unshifted plane, pressed and released with no shift anywhere.
- **A character whose plane the viewer is not holding**, both ways round: `!`
  with no shift held, where the Shift key is worked around the key; and a
  plane-0 keysym with the viewer holding Shift, where every shift it holds
  comes up around the key and goes back down. The second of those was added
  because a mutation of that branch survived without it.
- **Eighteen named keys and fourteen modifiers**, each by position in octal.
  `Return`, `KP_Enter`, `Tab`, `BackSpace` and `Delete` as Rubout, `Linefeed`
  as Line, `Escape` as Alt Mode, `Help`, `Break`, `Cancel` as Abort, `End`,
  `Pause` as Hold Output, and six of the function keys. Left and Right are
  different positions and a mapping that collapsed them would be caught.
- **The prefix**: `Scroll_Lock` then `1` is Roman I and is tapped;
  `Scroll_Lock` then `l` is Control, which is held for the one key that
  follows and then let go; and a prefix pressed twice is the way out of a
  sequence begun by mistake.
- **A keysym nothing maps** goes nowhere and is counted.
- **A viewer that goes with keys down** has them released.
- **A fabric with no room** holds the program up rather than losing what it
  could not send, and the words come out in order afterwards.
- **The mouse**: the first event moves nothing, right and down are positive,
  left and up negative, a pointer that did not move writes nothing, the three
  switches are RFB's own mask, a wheel button reaches no wire, and a viewer
  going lifts the switches.
- **The face**: `IDENT`, the flush, a delta wider than the register's twelve
  bits held rather than wrapped, and a word refused rather than written when
  the queue is full.

And, for the mapping file:

- **The built-in mapping is muir's own `default.keys`, resolved twice.**
  `src/input_keymap.h` carries that file two ways: `KEY_BOUND` and
  `KEY_PREFIX`, which the generator resolved in Python, and
  `KEY_DEFAULT_MAPPING`, which is the file itself byte for byte. The check
  parses the text with the C parser and requires the result to equal the
  tables, entry for entry, so two independent resolutions of one reference
  file are held to each other. **This is why the program does not build its
  own map by parsing that text**, which would be the same code compared
  against itself.
- **A file goes over the built-in mapping.** One line changes one key, the
  count does not move, and every keysym the file said nothing about keeps what
  it had. A new keysym and a new prefix pair each add one.
- **A file that is refused changes nothing**, not even the lines before the
  bad one.
- **The grammar**, on comments that are comments and a `#` that is a key,
  blank lines, tabs, CRLF, a case-sensitive verb and case-insensitive names.
- **Octal positions**, and the two different messages for a number past a byte
  and a number past the table.
- **Left and Right**, including Greek, where muir's sides are the lower and
  higher position and MIT's table labels them the other way round.
- **Every error, word for word.** The literals came from muir and are pinned
  here so that a change to any of them is a failure.
- **And the mapping reaches the machine.** A viewer presses one key under the
  built-in mapping and again under a file that rebinds it, and the two give
  different positions on the wire. Without this pair the mapping could be read
  correctly and then not used.

**And two real screens, when they are there.** `vendor/screen/` is gitignored
like the rest of `vendor/`. So a fresh clone runs the anchors and the check's
own patterns, and says the real ones are absent. That is the same shape as
`rtl_sys` skipping when the release archive is not there. To make them:

    cd ../muir && mkdir -p vendor/run
    gunzip -c ../muir-fpga/vendor/system-100-0/disk-sys-100-0.img.gz > vendor/run/disk-sys-100-0.img
    cargo run --release --example screen -- 400000000 25000000
    cp vendor/run/screen-rtl-200000000.png vendor/run/screen-rtl-225000000.png \
       ../muir-fpga/vendor/screen/
    rm vendor/run/disk-sys-100-0.img          # a drive writes its pack

That takes 57 seconds. The two are 25 million microcycles apart and differ
only in the blinking cursor, 84 pixels of 739,584. That is **a real incremental
update of an ordinary screen**, which is the case no synthetic pattern
supplies. They are muir's own PNG (`SimpleTv::png`), which is the monitor's
picture and not the frame buffer. So the check turns each back into
frame-buffer words and compares the viewer's pixels against the PNG's. The
decoder is thirty lines, because muir writes stored deflate blocks and says so.

**The measurement that says the errors are muir's was made against muir and
not transcribed.** Thirty-seven files were fed to this parser and to
`muir --keyboard-mapping <file> --keyboard-mapping-dump` built at the commit
`muir.commit` pins, and every message came out character for character the
same, the Rust quoting of a line that ran out included. Ten mappings were
merged from a file over the built-in one and compared against muir's own dump
of the same merge, and all ten agreed entry for entry. The one message that is
not muir's is for a file that cannot be opened at all: muir spells that with
Rust's own error type, which appends `(os error 2)`, and this uses `strerror`,
which stops at `No such file or directory`. That measurement needs muir beside
the tree and so cannot be part of the check; what the check carries is the
result, pinned.

**The mutations** are in `src/screen_mutations.txt`, in `mutations/list.txt`'s
own format, and are run by `src/mutate.py`. They are the bit order reversed
within a word, the line stride a word short in each of the two places the rule
is written, black and white swapped, an update rectangle starting a row late,
adjacent changed rows not joined, a frame read once and then held,
a diff that sends the rows that did not change, an RRE subrectangle placed
absolutely, the encoding guessed rather than measured, a viewer's encoding list
read backwards, the byte order a viewer asked for ignored, the whole-screen
interval inverted, a security type that is not offered taken, and an all-ones
screen not called blank. Twelve more are aimed at the mapping file: the file
replacing the built-in map instead of going over it, a refused file keeping the
lines before the bad one, a `key` line adding a binding instead of replacing
one, a comment taken anywhere on a line, a position read in decimal, Left and
Right swapped, a shifting key's positions walked the other way, a keysym
allowed to be a key and a prefix at once, a line number one too few, `0x` read
case-insensitively, a number past thirty-two bits truncated rather than
refused, and the key taken as the first word instead of the rest of the line.
The unjoined rows are the one **whose pixels come out
right**, so only the check's comparison of the rectangle list can see it. A
build that fails is BROKEN and fails the run, which is CLAUDE.md's lesson about
two fabric mutations reported as surviving that had never been built.

**What it cannot hold to.** It cannot hold to the uncached mapping's speed on
the board, which is real traffic on the DDR controller and is measured there
and not here. It cannot hold to the torn frame above. It cannot hold to
`MODE BOW`, which nothing in the fabric will tell it. And it cannot hold to
the fabric behind the register face, which is `build/gp0_split.pass`'s: that
check drives the same face through the splitter and reads the CARD's own
keyboard and mouse registers over the Unibus, so the two halves meet there and
not here.

### The seam is checked at the other end too

`build/gp0_split.pass` carries a keystroke and a mouse movement all the way
across. It writes a word at `0x4000_3000` and reads it back out of the card's
two halves at `0o764100` and `0o764102`, in MIT's own order, with only the low
half clearing `KBD READY`. It writes four words while the card holds one and
requires them to arrive one at a time and in order. It moves the mouse one
step at a time and compares the quadrature the card latched against muir's own
`00, 10, 11, 01` with counts one to four, the twelve-bit wrap, and 63 steps
against 63 times `MOUSE_STEP_NS`. And it holds the two fabric legs of the
autoboot trap: nothing reaches the card's `KBD READY` until a word is written,
and nothing reaches it after the machine's own reset.

## On the board

**The bitstream must be the memory-on one, `DDR=1`.** With `DDR` clear,
`boards/arty-z7-20/cadr_arty.sv` ties `mem_done` low and there is no memory
behind the machine's memory port at all. So the display's window is answered
by nothing, and the region in DDR is never written. That is the same bitstream
the disk already needs.

This is what the console should show at boot, after `S80cadr-disk-pack`'s
lines:

    Starting cadr-terminal: OK
    cadr-terminal: the EMIO tally reads 0x8000.... 0x8000....: a fabric with the
      processing system in it; the display's window may be read
    cadr-terminal: the display's window is 128 KB at 0x1c000000; the screen is
      768x963, 24 words a line, 23112 of the window's 32768 words, one bit a
      pixel, a one bit WHITE (MODE BOW clear, the fabric's power-on state)
    cadr-terminal: the screen is BLANK: every visible word zero (0x00000000) ...
    cadr-terminal: the keyboard and mouse answer at word 0 with "INPT"; STAT ...
    cadr-terminal: RFB on 0.0.0.0:5900 --- display :0 to a viewer. NO
      AUTHENTICATION ... The keyboard and mouse go to the machine. Encodings:
      Raw and RRE, whichever is smaller for each rectangle
    cadr-terminal: the keyboard and mouse are at 0x40003000; a viewer's keys go
      to the machine as MIT's own key positions, muir's mapping, and its
      pointer as the mouse's own counts. The fabric's queue was flushed before
      this socket was bound, so nothing was waiting at the machine's cold-boot
      test

With no `terminal.keyboard.mapping.txt` on the pack partition there is no line
about the mapping, the built-in one being the default. With one there is a
line saying what was read, and with a file that does not parse there is a line
saying which line of it was wrong and that the built-in mapping stands:

    cadr-terminal: the keyboard mapping is /mnt/packs/terminal.keyboard.mapping.txt
      over the built-in one: 39 keysyms bound and 22 behind a prefix
    cadr-terminal: the keyboard mapping /mnt/packs/terminal.keyboard.mapping.txt
      was NOT read and the built-in one stands:
      /mnt/packs/terminal.keyboard.mapping.txt: line 4: Nosuchkey is no key of
      this keyboard

The blank line is expected at boot, and it is the point of it. **An unwritten
word of this board's DDR reads zero in some places and all ones in others**
(CLAUDE.md, measured on the first bring-up). So a viewer shown 739,584
identical pixels cannot tell "the machine has not drawn" from "this program is
reading the wrong address". When the machine draws, one more line says so, and
nothing further is printed per frame:

    cadr-terminal: the screen has content: 7572 of 739584 pixels lit
    cadr-terminal: viewer 192.168.x.x:nnnnn: connected; 1 watching

**From a viewer**, on any machine that can reach the board, the command is:

    vncviewer <the board>:0          # or :5900, or any RFB client

If the port is not to be open on the LAN, pass `--bind 127.0.0.1` on the board
and use:

    ssh -L 5900:127.0.0.1:5900 root@<the board>
    vncviewer 127.0.0.1:0

**What should be on it.** The boot PROM never addresses the display
(`docs/tv.md`), so until the band is running the screen is the DDR the
controller left. The System 100 band writes the microcode's two run lights
from microcycle 1,422,272, and those flicker around every disk transfer. They
are words `0o51763` and `0o51765`, which are words 11 and 13 of **line 895**,
near the bottom. A window-system screen proper is what muir shows at microcycle
25,000,000 and after, and it is what the board should come to. That is white
text on black, with an error notification and a blinking cursor, one per cent
of the pixels lit.

**What to copy where.** Nothing new goes on the card. `cadr-terminal` and
`S85cadr-terminal` are in the root filesystem, which is the initramfs. So it is
`rootfs.cpio.uboot` that changes, and it travels the way it always does:
`/srv/tftp` on the network path, and the card's own copy on the card path
(`docs/boot.md`).

**The keyboard mapping file is the one thing here that lives on the card**, and
no package installs it. It is written by hand on the pack partition, the way
the Chaosnet program's three settings files are, and it is optional. Two
things the card's own tooling does not know about it yet: the staging script
that writes a card checks partition 2 against a list of names it expects and
would refuse a card carrying this one, and the `README.TXT` it writes there
names the settings files one by one. Both are a line each and neither is this
package's file.

## What is not built

- **Reading `MODE BOW`**, which is described above. It is fabric work in three
  files, none of them this program's, and the section above says which.
- **Encodings past Raw and RRE.** Hextile and ZRLE would both beat RRE on a
  screen of text. ZRLE needs zlib on the board, Hextile is a real amount of
  code, and RRE at fifty times is enough for a screen that changes a cursor.
  A rectangular decomposition that joined runs ACROSS rows inside one RRE
  rectangle would also be smaller, and it is one pass more.
- **`CopyRect`**, and the case for it is weaker than it looks. A window system
  dragging a window would make very good use of it, and it needs the program
  to know what moved. This program is not told what moved: it sees the words
  in DDR and nothing else, so it would have to find the move by searching.
  Measured on the only real incremental update this project has, the two
  screens muir drew of MIT's System 100 band twenty-five million microcycles
  apart: the change is the blinking cursor, **84 pixels in a 7 by 12 block**,
  sent today as one full-width rectangle of 12 rows. The same 7 by 12 block of
  pixels appears in **667,165** other places on that screen, almost all of them
  blank background. So a search would find a source at once, the `CopyRect` it
  sent would be a copy of empty space, and it would save nothing that RRE does
  not already save. The encoding wants a workload with real motion in it, and
  this project has no sample of one. Building it against no sample and no
  reference is the shape of a claim nothing exercises.
- **A trigger for the probe.** That is a different instrument and is not this.

## The Makefile does not name the packages any more, it derives them

**`buildroot-rebuild` used to carry a hand-written list and it had gone
stale.** Buildroot does not watch our files, so a change under a package's
`src/` is not seen by a plain `make buildroot` once that package has a build
stamp. The first build after a new package works without forcing, because a
new package has no stamp; the second one silently builds the old sources. That
was measured rather than argued: a marker string added to `cadr-terminal.c`
and a plain build left the marker out of the binary on the target.

`cadr-terminal-reconfigure` has since been added to that list. **The list was
still wrong, and a hand-written list beside a directory will go wrong again.**
`cadr-checkpoint` was missing from it. That package builds from its own `src/`
by Buildroot's `local` site method and is enabled in the image, and it has had
a build stamp for a long time, so **every** `make buildroot-rebuild` since then
has left it alone and shipped whatever was built first. It is the program that
reads the board's main memory into a muir checkpoint, which is the only way
that memory can be read at all, so a stale one is a stale instrument in the
middle of a diagnosis.

**So the list is derived and no longer typed.** The packages that need forcing
are exactly those whose `.mk` declares `_SITE_METHOD = local`, which is the
property that makes them built from files in this tree, and `BR_RECONFIGURE`
reads that off the `.mk` files. A package added under `package/` joins the list
by existing. `muir` falls out of the derivation and should: its version is the
commit in `muir.commit`, so a new pin is a new build directory and Buildroot
rebuilds it unasked. U-Boot and the kernel stay named, because they are
Buildroot's own packages reading our files through external options and hooks.

**And the two ways the derivation could come out short are refused rather than
silently omitted.** `buildroot-check` fails if any `.mk` declares no site
method at all, which is what a package written differently or a line rewritten
without its spaces would look like, and it fails if the derived list is empty.
The first guard was tested by removing the spaces around one package's
`SITE_METHOD`: the build stops and names the file. Without it that package
would simply have left the list, which is the silent-omission shape this
repository keeps meeting.

**The image cost.** `rootfs.cpio` goes 6,251,520 -> 6,279,680, which is
**+28,160 bytes exactly**. `rootfs.cpio.uboot` goes 2,813,397 -> 2,824,2xx,
which is **about +10.8 KB**. The compressed figure is quoted to the kilobyte on
purpose. Three builds of the same sources gave 2,824,187, 2,824,232 and
2,824,264, because the gzip and U-Boot headers inside it carry a timestamp. So
the last digits of that number are not a measurement of anything. The program
is 25,956 bytes on the target, stripped, and the init script is 1,962. Nothing
else in the image changes: no new library, no kernel option, no device-tree
node, nothing on the card.

**The mapping file added about eight kilobytes to the program and nothing
else.** Built for the board with the Buildroot toolchain's `arm-linux-gcc` and
stripped, the program goes from 34,244 bytes to 42,436, which is **+8,192**.
Those two are the same compiler with the same flags either side of the change,
so the difference is a measurement; neither is comparable with the 25,956
above, which is Buildroot's own build with Buildroot's own flags. There is
still no new library, no kernel option and no device-tree node, and the only
new thing on the card is a file nobody has to write.
