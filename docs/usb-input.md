# The USB keyboard and mouse

`cadr-usb-input` carries a USB keyboard and mouse plugged into the board's own
host port to the CADR's keyboard and mouse registers. With it, the machine can
be used at the board. Without it, the only way to type at the machine is a VNC
viewer on another machine over RFB.

The kernel half has been done since the USB port was proved: the tree names the
PHY, an init script switches the port's power on, and `evtest` prints every
event a keyboard delivers. `docs/boot.md` has that. This document is the half
that reaches the machine.

## The design question, and the answer

The input face has one queue and one card behind it, and the rate at which
words may be handed over is a rule about the machine rather than about the
card. `input_face.h` states the two rules: one word in flight, and successive
words no closer than the interval muir feeds the same microcode at. A rule like
that needs one pacer. Two programs writing the face side by side would each
obey it and the machine would still get words twice as fast as either meant.

So the question is which program owns the face. Two shapes were posed.

- **(a)** `cadr-usb-input` hands its events to `cadr-terminal` over a local
  socket, and the terminal stays the face's only writer. Its pacer serves both
  sources.
- **(b)** The writer moves out of the terminal into a small input daemon in
  `cadr-common`, which both the terminal and the USB program feed.

**(a) was taken.** Three reasons, in the order they weigh.

**It is the shape the reference emulator already has.** muir has one
`Keyboard` and one `Mouse` per machine, made once at the start of a run, and
one place that hands words to the card: `attend` in `main.rs`, every
`TERMINAL_CHECK` microcycles. Up to eight viewers can be connected at once and
every one of their keys reaches the machine, because all of them push into the
same queue on the one `Terminal`. There is no arbitration, no lock and no
merging, and muir says why: the terminal has no thread of its own on purpose.
A viewer is a source, not an owner. `cadr-usb-input` is another source.

**It keeps the tested pacing code as the single path.** The terminal's key
queue, its backlog, the shift worked around a key, the releases owed when a
source goes away and the pacer itself are all exercised by the host check in
`screen_test.c`. Shape (b) would move every one of them into a new program and
leave the terminal a client of it, so the path that has been checked since the
screen slice would be rewritten and re-proved for no gain.

**It leaves the number of writers at one, which is what the flush rests on.**
The machine asks whether anybody is typing four instructions into microcode
323, so a word waiting at the keyboard's register when the microcode starts
sends the machine down a path nobody asked for. The terminal's leg against that
is to flush the fabric's queue after it has read `IDENT` and before it binds
its socket. That ordering is only airtight while one program can write the
face. Shape (b) would put the flush in the daemon and make the ordering a
property of three programs starting in the right order.

### What was considered and declined

**The USB program as a ninth viewer.** It could connect to the terminal's own
RFB port and send `KeyEvent` and `PointerEvent` messages, which is how a second
program would have to feed muir today, and it would need no new code in the
terminal at all. The mouse is what rules it out. RFB's `PointerEvent` carries
an absolute position and a USB mouse reports motion, so the program would have
to keep a cursor of its own and clamp it at the edge of the screen. A mouse
pushed past the edge would then stop moving the machine's cursor, and the
machine's cursor is not where the program thinks it is anyway. It would also
take one of the eight places for a viewer.

**Positions on the wire instead of keysyms.** The USB program could map an
evdev key code straight to one of MIT's key positions and send that. It would
be shorter. It would also be a second mapping, with a second file format and a
second set of decisions about what a key means, and the whole argument for
`input_keys.c` is that two programs showing one machine must not disagree about
that. Keysyms cross the link, and one `--keyboard-mapping` file serves both
sources.

## What crosses the link

The link is a Unix-domain stream socket. `cadr-terminal` listens on it and
`cadr-usb-input` connects. `cadr_input_link.h` in `cadr-common` is the one
place the two halves meet, as `input_face.h` is for the fabric's own seam.

A client opens with eight bytes: the word `INLK` and a version. The server
answers with the same eight, so a client can tell the terminal from whatever
else might be listening on a path, and a client that says something else is
dropped with a line saying so.

After that the client sends twelve-byte records. A key record carries an X11
keysym and whether it is going down or coming up. A pointer record carries a
motion in counts and the three switches as a level. Nothing travels the other
way.

**Keysyms, already shifted.** This is the contract, and it is the one thing
about the link that is easy to get wrong. A viewer sends the keysym its own
keyboard produced: shift and `1` arrive as `exclam`, not as `Shift_L` and `1`.
The terminal's state machine is written for that, and where the plane a keysym
wants is not the plane the source is holding it works the Shift key around the
key. A USB keyboard reports a key and a level separately, so if the raw keysym
went across, `Shift` held and `1` pressed would reach the machine as Shift
lifted, `1` typed and Shift put back: the user would type `!` and the machine
would see `1`. So `cadr-usb-input` applies the level itself and hands over the
keysym the key produced. It is an X server's keymap in miniature, and it exists
so that the terminal needs no branch for a USB keyboard.

**A client that goes away releases what it held.** The server keeps the keysyms
each client has down, bounded, and sends the releases through the same path
when the connection closes. There are no modifier bits in a word on this
keyboard, so a Control held by a program that died is a Control held for the
rest of the machine's run.

**And a viewer leaving no longer lifts a USB keyboard's keys.** The terminal
releases every key that is down when its last viewer goes. That is right when
the viewer was the only source and wrong when somebody is standing at the board
with a finger on Shift, so it now runs only when no client is attached to the
link. A client's own keys are released when the client goes, which is the same
rule one source along.

## Keys

`cadr-usb-input` reads `/dev/input/event*`. An `EV_KEY` event carries an evdev
key code and a value of 0 for up, 1 for down and 2 for a repeat. Repeats are
dropped: the Lisp Machine has a Repeat key of its own and a keyboard that
sends a position twice without an intervening release is not a keyboard MIT
built.

A key code becomes a keysym through `usb_keymap.h`, which is generated by
`usbkeymap_from_xkb.py` from the X keyboard database on the build host: the
`evdev` key codes file for the code of each key, `symbols/pc` and `symbols/us`
for the two keysyms each key carries, and `keysymdef.h` and `XF86keysym.h` for
their numbers. The layout is `pc+us`, which is what an X server loads for a
plain US keyboard, so the table is what a viewer on such a keyboard would send.
It is not written by hand for the same reason `input_keymap.h` is not: a
hundred and more entries transcribed by hand is a table with a wrong key in it
somewhere. It is not a build step either, because the database is not in this
repository; the output is committed and its own header names the files it came
from.

The level is chosen here and only here:

- **Shift** selects the second keysym on the key. Both Shift keys do.
- **Caps Lock is not applied.** It is a key at a position of its own on MIT's
  keyboard and the machine does the locking, so it is passed through as a key
  like any other. Applying it here as well would lock twice.
- **Num Lock is applied, to the keypad alone**, and starts on. The keypad's
  first keysym is the one the key means with Num Lock off, which is `KP_Home`
  where the key is printed 7.
- **There is no third level.** The US layout has none, and the right-hand Alt
  key is `Alt_R` there, which muir's mapping makes Right Meta. Greek and Top
  are reached through the `Scroll_Lock` prefix, which is muir's own answer to a
  keyboard with fewer keys than the CADR's.

After that the keysym means what `input_keys.c` says it means, which is muir's
own mapping: Shift, Control, Meta, Super, Hyper, Top and Greek are keys at
positions of their own and there are no modifier bits in a word, because all
key encoding is done in software in the central machine. A word is MIT's frame,
an up-or-down bit and seven bits of position.

**What a plain USB keyboard cannot reach, and what to do about it.** A keysym
that is neither bound nor printable goes nowhere, and the terminal counts it.
That is muir's rule and it is unchanged here. The numeric keypad's digits are
in it: `KP_7` is not bound and is not a printable keysym, so the keypad types
nothing. One line in the mapping file binds any of it. The keysym is written as a
number, because the names the parser knows are the ones muir's own mapping
names and `KP_7` is not among them:

    key 0xffb7 7

Shift and Tab is in the same family and is worth knowing about. The US layout
puts `ISO_Left_Tab` on the shifted plane of the Tab key, and muir's mapping
binds that keysym to nothing, so Shift and Tab types nothing at all. A viewer
sends the same keysym for the same keystroke, so the two sources agree, which
is the property being kept.

    key 0xfe20 Tab

binds it, and then Shift and Tab types a plain Tab: a named key is bound on the
unshifted plane, and the state machine works the Shift key around a key whose
plane the source is not holding. So what the machine sees is Shift lifted, Tab,
Shift put back. **A Lisp Machine keyboard would have sent Shift held with the
Tab position, and no keysym mapping can ask for that**, because a keysym says
what was typed and not which keys were down. It is muir's own limit, it is the
same for a viewer, and the check pins it so that nobody reads the binding as
doing more than it does.

The same file is how the right-hand Alt key becomes Greek if somebody would
rather have it that way than the `Scroll_Lock` prefix:

    key Alt_R Left Greek

Both spellings are muir's own format, which `docs/terminal.md` describes. A `#`
begins a comment only at the start of a line, so a note about a binding goes on
a line of its own.

## The mouse

An `EV_REL` event carries `REL_X` and `REL_Y` in counts, right and down
positive. The CADR's mouse counts the same way: one count a step, right and
down positive, which is `muir::terminal::mouse`'s own convention and what
`tv:mouse-x` and `tv:mouse-y` grow with on the machine. So nothing is negated
anywhere, and the CADR's screen has its origin at the top left as the pointer's
does.

The quadrature encoder is in the fabric. A step is 16,000 ns of the machine's
own time, 32 real microseconds at this board's tick, so a program making phases
over a general-purpose port would be writing fifty thousand times a second.
`docs/io-board.md` settled that at the card's second slice: the card takes the
seven lines MIT's mouse drives, and what turns a delta into phases is fabric
beside it. What crosses the link is the delta.

Motion is accumulated to the end of the kernel's own report. A mouse sends
`REL_X`, `REL_Y` and then `EV_SYN`/`SYN_REPORT`, and the whole report goes as
one record, which is one write to the face instead of two. `REL_WHEEL` and
`REL_HWHEEL` are dropped: the cable has three switches and no wheel.

The three switches need no translation. `BTN_LEFT`, `BTN_MIDDLE` and
`BTN_RIGHT` are bits 0, 1 and 2, which is RFB's mask and MIT's
`buttons-down-mask` in MIT's order.

**There is one mouse and there can be several sources.** The terminal writes
the OR of what the viewers are holding and what each link client is holding, so
a button held in one place is not lifted by the other letting go. The switches
are a level on the cable and the card's own comparator decides whether anything
happened.

## Pacing

`cadr-usb-input` does not pace anything. It reads the device, translates, and
writes to the link as fast as events arrive, which for a person typing is a few
records a second and for a mouse is one report per hundredth of a second.

The pacing is the terminal's, unchanged: a word goes when the fabric holds
none and the card's `KBD READY` is clear, and no sooner than
`INPUT_KEY_INTERVAL_NS` after the last one. That is 4,096 microcycles of 290 ns,
which is the cadence muir has always fed this microcode at. A burst that
arrives faster waits in the terminal's backlog of 256 words, about six seconds
of the fastest typing anybody does.

This is why the link carries no acknowledgement. The far end is a queue with a
bound, and a source that overruns it is refused whole keystrokes rather than
half of them, which is what keeps a Shift from going down with its release
dropped.

## Devices coming and going

The keyboard enumerates about 1.5 seconds after reset, and the board takes
about fifteen seconds to reach the init scripts, so the device is usually there
before the program starts. It need not be: a keyboard plugged in later must
work, and one unplugged and plugged in again must work.

There is no udev in this image. `/dev` is devtmpfs, so a node appears and
disappears by itself, and the program looks for what is there every
`--scan-ms`, a second by default. A device that has gone gives `ENODEV` on the
next read and is closed. A device that has arrived is examined with
`EVIOCGBIT`: one that reports key codes a keyboard has is opened as a keyboard,
and one that reports relative motion and a mouse button is opened as a mouse. A
device that is neither is left alone, and it is remembered so that it is not
examined again every second.

**A device is drained when it is opened.** The kernel buffers events for a node
nobody has open, so the first read could otherwise deliver a keystroke from
before the program started. `input_face.h` names this as the leg of the
cold-boot test that belongs to a program taking keys from a device: the
buffering is on the far side of the seam and no register in the fabric can see
it.

**What a device holds when it goes is released.** Every key the program has
sent down for that device goes up, and its share of the button mask is cleared.
A keyboard unplugged with Control held must not leave the machine holding
Control.

## The flags

The program reads its flags from the command line today. They are named so that
they can move into `fpgarc` beside the Chaosnet's without a second file: that
file is one flag a line in muir's own rc format, and `docs/chaosnet.md`
describes it. Each flag has the program's own short name and a prefixed
spelling for the shared file, which is what `cadr-chaosnet` already does with
`--udp-peer` and `--chaos-udp-peer`.

    --link PATH          the socket cadr-terminal listens on
    --usb-link PATH      /var/run/cadr-input by default

    --device PATH        one device to open, repeatable. With none, the
    --usb-device PATH    program looks in --input-dir for what is there

    --input-dir DIR      where the evdev nodes are, /dev/input by default
    --usb-input-dir DIR

    --scan-ms N          how often to look for a device that came or went,
    --usb-scan-ms N      1000 by default

    --grab               take the devices exclusively, so that nothing else
    --usb-grab           on the board sees the keys. Off by default

    --no-keyboard        ignore keyboards, ignore mice. Either is useful when
    --usb-no-keyboard    two of something are plugged in and one is wanted
    --no-mouse
    --usb-no-mouse

    --log PATH           where the log goes. The init script says /dev/console

    --once               find the devices, say what is there, and exit. It is
                         what to run on a board to see what the program makes
                         of what is plugged in, without starting anything

**What has not been settled is how one file serves several programs.** Today
`S87cadr-chaosnet` passes every line of `fpgarc` to `cadr-chaosnet`, which
refuses a flag it does not know by name, and that refusal is worth keeping: a
boot that silently dropped a flag would look exactly like a boot that honoured
it. So a file holding flags for two programs needs either a filter in each init
script or a rule in each program about which flags are its own, and that
decision belongs with whoever moves the screen's and the serial line's flags
into the file. The names above are chosen so that the decision is about the
file and not about this program.

## What the checks hold

The host check is `usb_test.c` in the package, built and run by
`make -C src check` and by `make build/usb_input.pass` at the top level. It
needs a C compiler and nothing else: no board, no fabric and no USB device.

It runs the whole path in one process. Synthetic `input_event` structures are
written into a socket pair standing where a device node would be, this program
reads them and makes records, the records cross a real Unix socket through the
real link code, the terminal's real server takes them, and a model of the input
face stands where the fabric would be, behind the two function pointers
`input_face.h` provides for exactly this. Behind the face is a model of the machine that reads
a word only so often, because a face that took every word offered would not
test the rule that matters.

What it asserts:

- A letter, a shifted letter and a punctuation key each become the right
  position, with the down word before the up word and MIT's frame in both.
- Shift held and a digit pressed gives the shifted position with Shift still
  down, and **no word that lifts Shift**. That is the contract at the head of
  this document, and it is the assertion that would catch a program sending
  raw keysyms.
- Every shifting key is a position of its own and no word has a modifier bit.
- A burst of key events obeys the interval: words arrive no closer than
  `INPUT_KEY_INTERVAL_NS` on the model's own clock, and none is lost.
- The model machine that reads slowly gets every word in order.
- Motion becomes a delta with the sign the fabric expects, a report becomes one
  write, and the wheel becomes nothing.
- Buttons from a viewer and from the link are ORed, and one letting go does not
  lift the other's.
- A device that disappears has its keys released, and one that appears again is
  opened and works.
- A client that goes away has its keys released.
- A viewer and a keyboard at the board are one keyboard: both reach the
  machine, their buttons are ORed, and **the viewer leaving does not lift what
  the board is holding** --- while a viewer leaving with nothing at the link
  still releases its own keys, which is the behaviour that was there before.
- A mapping file binds a key for both sources at once: the keypad's 7, unbound
  in the built-in mapping, types nothing until one line says what it is.
- And what such a line cannot do: Shift and Tab bound to MIT's Tab types a
  plain Tab, with Shift lifted around it, because a named key is bound on the
  unshifted plane. The six words are asserted in order, so that the binding is
  never read as doing more than it does.
- The generated keysym table agrees with the X keyboard database it was
  generated from, for every key the check names by hand. That anchor earned
  itself at once: the Menu key, which muir's mapping makes the Top key, was
  missing from the first table because the key codes file names it `<COMP>`
  and reaches `<MENU>` by an alias the generator was not following.

Then every record in `usb_mutations.txt` is applied to a copy of the sources,
built and run, and a record the check passes is reported and the run is red.
That is `mutate.py` in the package, which is the top-level mutation runner's
format one program along, as the screen's and the serial line's already are.

## At the board

The program is started by `S88cadr-usb-input`, after the terminal's `S85`,
because the terminal is what listens on the link. A boot where the terminal did
not start leaves this program saying the link is not there and retrying, which
is the right thing to report.

Plugging a keyboard in and typing at it is the whole of using it. What should
happen is that the characters appear at the Lisp Listener on the screen, which
can be watched over RFB from another machine at the same time.

**And a key cannot be pressed from another machine on this image**, which is
worth saying plainly because the obvious ways look as though they would work.
`evtest` only reads. `uinput` would do it --- a program makes a virtual
keyboard and this one finds it on the next scan --- but `CONFIG_INPUT_UINPUT`
is not in this board's kernel configuration, so there is no `/dev/uinput` to
open. What can be done from elsewhere is to feed the link directly, which
proves every part of the road except the read of the device.
`docs/board.md` has the steps and the one-line kernel change.

## What is not built

- **The keyboard's LEDs.** Num Lock, Caps Lock and Scroll Lock have lamps on a
  USB keyboard and the program lights none of them. `EV_LED` written back to
  the device would do it. The machine has its own idea of Caps Lock and no way
  to tell this program about it, so the lamp would be this program's state and
  not the machine's, which is worse than a dark lamp.
- **A second keyboard layout.** The table is the US layout, which is what the
  build host's database was read for. Another layout is another generated
  table, and the generator takes the layout's name.
- **Anything on the link from the terminal back to a client.** The link is one
  way after the opening exchange. A client cannot ask what the machine is
  doing, and nothing needs to.
