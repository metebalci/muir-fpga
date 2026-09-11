<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The screen

`cadr-terminal`: the program on the processing system that shows the CADR's
display to a VNC viewer. Written at the slice, muir at `dad7249`, the fabric
at the commit that added this file.

The display block is built and checked (`docs/tv.md`), and nothing could look
at what it draws. **It needs no new fabric to fix that**, which is why this
came next: `rtl/machine/cadr_tv.sv` keeps no frame buffer of its own --- a cycle to
the window at `0o17000000` is answered by main memory's bridge at the
display's own base in PS DDR3 --- so the picture the machine draws is 92,448
bytes of ordinary DDR, and Linux can map it. Mete asked for the screen first
and the keyboard and mouse later, when the I/O board exists.

## What it is, and what it is not

    cadr-terminal [--port N] [--bind ADDR] [--log PATH] [--bow]
                  [--window ADDR] [--interval-ms N] [--no-rre]
                  [--no-guard] [--once]

It maps 128 KB at `0x1C00_0000` through `/dev/mem`, copies the visible 23,112
words out of it once a frame while anybody is watching, and serves them over
RFB --- RFC 6143, what a VNC viewer speaks --- on port 5900, which is display
`:0`. `S85cadr-terminal` starts it at boot.

**It is READ-ONLY.** No keyboard, no mouse, no pointer. A viewer's `KeyEvent`
and `PointerEvent` are read off the wire, counted and dropped, and the program
says so once the first time one arrives. The CADR's keyboard and mouse are the
I/O board's, and that board is not in the fabric; muir's own terminal serves
all three because muir has an I/O board to put a keystroke into. A viewer that
types at this screen sees nothing happen, which is what a machine with no
keyboard attached does. RFC 6143 gives a server no way to tell a viewer it
takes no input, and every viewer sends pointer events as the mouse crosses its
window, so refusing the connection would be worse than dropping them.

**It has no authentication.** `None` is the only security type offered (RFC
6143 section 7.2.1), so anybody who can reach the port sees the screen. That
is the decision the rest of this image already makes --- root logs in with the
password `root` over Dropbear --- and it is stated in the program's own
opening line rather than left to be discovered. `--bind 127.0.0.1` restricts
it to the board itself, and then a viewer reaches it over an SSH tunnel.

**It cannot read `MODE BOW`.** Whether a one bit shows white or black is four
flops in the fabric (`rtl/machine/cadr_tv.sv:141`, cleared to zero at `:195`) and
nothing carries them to the processing system: `M_AXI_GP0` is the disk's and
`M_AXI_GP1` the console's, and neither has a word for the display. So the
default is the fabric's own power-on state and muir's, zero --- a one bit is
white --- which is also the mode both reference programs leave the register in
(`docs/tv.md`: "the mode register stays 0 ... for the whole run"), and
`--bow` swaps it. **What it would take to read it instead of assuming it**: a
word on the console's register face carrying `mode[3:0]`, which is one
register and one line in `rtl/plumbing/cadr_console.sv`, or an EMIO GPIO bit beside the
memory tally. Neither is built, and the assumption is right for every program
this project has run. It is written down here so that a screen that comes out
inverted is diagnosed in one step.

**It does not stop the machine to read a frame.** The CADR writes the window
while the copy is being made, so a copy can hold the top of the screen from
before a write and the bottom from after it. There is no interlock to take:
muir's terminal has the same seam, and the vertical flag the microcode uses is
a counter in the fabric with no path to Linux. A torn frame is one frame.

## The geometry, and where every number came from

The classic failure of a program like this one is a picture served upside
down, mirrored, or in the wrong colours, and it is cheap to get right by
reading. `screen_geom.h` carries the table below beside the code, and
`screen_test.c` pins the mapping on hand-computed pixels.

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

A line is 24 consecutive words, the first line first; within a line the pixels
run from the **low** end of the first word, so **bit 0 of a word is the
leftmost of the 32 pixels it carries**. muir says the same in its own words at
`src/terminal/mod.rs:216` --- "entry `b` is the frame-buffer byte `b`, its bit
0 first, bit 0 being the leftmost pixel" --- and states the whole rule again at
`src/terminal/mod.rs:97`, where `tests/terminal.rs` holds the two expressions
to each other pixel for pixel. This program is the third expression, and it has
the same pair inside it: `screen_geom.h`'s `screen_lit` is the rule, and
`screen_server.c`'s `row_byte` is the rule again as a byte at a time, which is
what a whole-width Raw rectangle actually goes through. **Both are mutated in
`screen_mutations.txt` and each is caught by exactly one of the check's two
encodings**, which is what says the check reaches both.

**Which way round black and white are.** muir `src/simpletv.rs:247-250` and
`:268-270`: a lit bit shows **white** unless `MODE BOW` --- `MODE<2>`,
`simpletv.rs:100`, "display one bits as black and zeros as white" --- is set,
and the other way round when it is. So a screen of zeros with BOW clear is
**black**, and that is what a real machine looks like: muir drawing MIT's
System 100 band at microcycle 200,000,000 has mode 0 and 7,572 of its 739,584
pixels lit --- **white text on black, one per cent of the screen**.

## The encodings, and what they cost

**Raw** (RFC 6143 section 7.7.1) is what every server must have and every
viewer must take, so it is the floor: a viewer that offers nothing else, or
offers only encodings this server has not got, is answered in Raw.

**RRE** (section 7.7.2) is the one that compresses runs: a background pixel
and a list of subrectangles of the other colour. muir's terminal declined it,
on the grounds that the screen is one bit a pixel and its own viewer is on a
loopback socket. This one is on a board at the end of a hundred-megabit link
and the measurement goes the other way. **Which one a rectangle goes in is
decided by measuring both and taking the smaller**, so a screen RRE would lose
on costs the comparison and nothing else. Measured by `make -C
boards/arty-z7-20/linux/buildroot/package/cadr-terminal/src check`, a whole screen at 32 bits a
pixel:

    a real CADR screen (muir's, System 100)   Raw 2,958,336   RRE     55,784   53x
    the check's synthetic screen              Raw 2,958,336   RRE    124,928   24x
    a dither, every other pixel               Raw 2,958,336   RRE  4,437,512   Raw is sent

Both numbers are measured, including the one for the encoding that lost: a
decision made by measuring is only reported by giving both sides of it, and a
program that quoted RRE only where RRE won would be quoting the win.

A whole screen is 2.9 MB in Raw whatever is on it, and a viewer asking for one
at every poll would have this program encode 739,584 pixels instead of
sleeping, so **a whole screen goes to a viewer at most once a frame** ---
`SCREEN_FRAME_NS`, 15.456 ms, muir's interval for muir's reason: the machine
cannot produce a new picture faster than the display board scans one. An
incremental update is never held back. The diff is by rows of frame-buffer
words, so a run of changed rows is one rectangle the full width of the screen,
and it is against what the viewer **has** rather than against a flag in the
fabric --- so a write by any route shows up, the processor's or the disk
channel's, and nothing in the fabric has to know a viewer exists.

## What the check holds to

`make -C boards/arty-z7-20/linux/buildroot/package/cadr-terminal/src check`, on the build host,
with no board: the server driven from screens made in the check, and a viewer
written for the purpose on a real loopback socket. **420 checks, 0 failures**,
then **15 mutations, 15 caught, 0 survived, 0 broken.** The whole thing takes
about half a minute.

- **The mapping, on nine hand-computed anchors**, in both directions of `MODE
  BOW` and in both encodings: one bit set in an empty screen must light
  exactly one pixel, at a coordinate written as a literal --- word 0 bit 0 is
  the top-left, word 0 bit 31 is pixel 31, word 1 bit 0 is pixel 32, word 23
  bit 31 is the last pixel of line 0, word 24 bit 0 is the first of line 1,
  word 23,111 bit 31 is the bottom-right. **This is the part that cannot be a
  round trip**: a builder and a reader that are wrong the same way agree with
  each other, and the anchors are the thing no such pair can put back.
- **A whole screen, pixel for pixel, in five pixel formats**: 32 bits a pixel
  little- and big-endian with the shifts moved, 16-bit 5-6-5, 8-bit 2-2-2, and
  a colour-mapped one whose `SetColourMapEntries` must arrive. The viewer works
  the two byte patterns out for itself and refuses a pixel that is neither.
- **An incremental update after part of the buffer changes**: the rectangles
  sent are held to the runs of changed rows, computed a second time in the
  check; the viewer's canvas comes out equal to the whole screen; and a viewer
  whose screen has not changed is left waiting, which is what RFC 6143 expects.
- **The frame re-read from the window each pass**, so that a program serving
  its first copy for ever is visible.
- **A viewer that offers only encodings this server has not got** --- CopyRect,
  Hextile, ZRLE and two pseudo-encodings --- must still be served, in Raw.
- **RRE against Raw**, and the dither where Raw is the smaller and must be the
  one used.
- **A viewer that goes in the middle of an update**: it is dropped, the server
  goes on, and the next viewer gets a whole correct screen.
- **RFB 3.3, 3.7, 3.8 and a version number that is none of them** (Apple's
  `RFB 003.889`, which section 7.1.1 says is to be read as 3.3); a viewer
  asking for a security type that is not offered, which gets a `SecurityResult`
  of 1 with a reason and is then closed; and a message type RFC 6143 gives no
  length for, which has to close the connection because there is no way to skip
  it.
- **The whole-screen interval**, held by a clock the check owns.
- **The blank states**, each told from the others.

**And two real screens, when they are there.** `vendor/screen/` is gitignored
like the rest of `vendor/`, so a fresh clone runs the anchors and the check's
own patterns and says the real ones are absent --- the same shape as `rtl_sys`
skipping when the release archive is not there. To make them:

    cd ../muir && mkdir -p vendor/run
    gunzip -c ../muir-fpga/vendor/system-100-0/disk-sys-100-0.img.gz > vendor/run/disk-sys-100-0.img
    cargo run --release --example screen -- 400000000 25000000
    cp vendor/run/screen-rtl-200000000.png vendor/run/screen-rtl-225000000.png \
       ../muir-fpga/vendor/screen/
    rm vendor/run/disk-sys-100-0.img          # a drive writes its pack

That takes 57 seconds. The two are 25 million microcycles apart and differ
only in the blinking cursor, 84 pixels of 739,584 --- **a real incremental
update of an ordinary screen**, which is the case no synthetic pattern
supplies. They are muir's own PNG (`SimpleTv::png`), which is the monitor's
picture and not the frame buffer, so the check turns each back into
frame-buffer words and compares the viewer's pixels against the PNG's; the
decoder is thirty lines because muir writes stored deflate blocks and says so.

**The mutations**, `src/screen_mutations.txt`, in `mutations/list.txt`'s own
format and run by `src/mutate.py`: the bit order reversed within a word, the
line stride a word short in each of the two places the rule is written, black
and white swapped, an update rectangle starting a row late, adjacent changed
rows not joined (**whose pixels come out right**, so only the check's
comparison of the rectangle list can see it), a frame read once and then held,
a diff that sends the rows that did not change, an RRE subrectangle placed
absolutely, the encoding guessed rather than measured, a viewer's encoding list
read backwards, the byte order a viewer asked for ignored, the whole-screen
interval inverted, a security type that is not offered taken, and an all-ones
screen not called blank. A build that fails is BROKEN and fails the run, which
is CLAUDE.md's lesson about two fabric mutations reported as surviving that had
never been built.

**What it cannot hold to.** The uncached mapping's speed on the board, which is
real traffic on the DDR controller and is measured there and not here. The torn
frame above. And `MODE BOW`, which nothing in the fabric will tell it.

## On the board

**The bitstream must be the memory-on one, `DDR=1`.** With `DDR` clear
`boards/arty-z7-20/cadr_arty.sv` ties `mem_done` low and there is no memory behind the
machine's memory port at all, so the display's window is answered by nothing
and the region in DDR is never written. That is the same bitstream the disk
already needs.

What the console should show at boot, after `S80cadr-disk-pack`'s lines:

    Starting cadr-terminal: OK
    cadr-terminal: the EMIO tally reads 0x8000.... 0x8000....: a fabric with the
      processing system in it; the display's window may be read
    cadr-terminal: the display's window is 128 KB at 0x1c000000; the screen is
      768x963, 24 words a line, 23112 of the window's 32768 words, one bit a
      pixel, a one bit WHITE (MODE BOW clear, the fabric's power-on state)
    cadr-terminal: the screen is BLANK: every visible word zero (0x00000000) ...
    cadr-terminal: RFB on 0.0.0.0:5900 --- display :0 to a viewer. NO
      AUTHENTICATION ... READ-ONLY ... Encodings: Raw and RRE, whichever is
      smaller for each rectangle

The blank line is expected at boot and is the point of it: **an unwritten word
of this board's DDR reads zero in some places and all ones in others**
(CLAUDE.md, measured on the first bring-up), so a viewer shown 739,584
identical pixels cannot tell "the machine has not drawn" from "this program is
reading the wrong address". When the machine draws, one more line says so and
nothing further is printed per frame:

    cadr-terminal: the screen has content: 7572 of 739584 pixels lit
    cadr-terminal: viewer 192.168.x.x:nnnnn: connected; 1 watching

**From a viewer**, on any machine that can reach the board:

    vncviewer <the board>:0          # or :5900, or any RFB client

and, if the port is not to be open on the LAN, `--bind 127.0.0.1` on the board
and

    ssh -L 5900:127.0.0.1:5900 root@<the board>
    vncviewer 127.0.0.1:0

**What should be on it.** The boot PROM never addresses the display
(`docs/tv.md`), so until the band is running the screen is the DDR the
controller left. The System 100 band writes the microcode's two run lights ---
words `0o51763` and `0o51765`, which are words 11 and 13 of **line 895**, near
the bottom --- from microcycle 1,422,272, and those flicker around every disk
transfer. A window-system screen proper --- white text on black, an error
notification and a blinking cursor, one per cent of the pixels lit --- is what
muir shows at microcycle 25,000,000 and after, and is what the board should
come to.

**What to copy where.** Nothing new on the card: `cadr-terminal` and
`S85cadr-terminal` are in the root filesystem, which is the initramfs, so it is
`rootfs.cpio.uboot` that changes and it travels the way it always does ---
`/srv/tftp` on the network path, the card's own copy on the card path
(`docs/boot.md`).

## What is not built

- **Input.** Keyboard, mouse and pointer, which are the I/O board's; when that
  block exists, this program grows a path for them or a second program takes
  them, and `muir`'s `src/terminal/keyboard.rs` and `mouse.rs` are the model
  either way.
- **Reading `MODE BOW`**, above.
- **Encodings past Raw and RRE.** Hextile and ZRLE would both beat RRE on a
  screen of text; ZRLE needs zlib on the board and Hextile is a real amount of
  code, and RRE at fifty times is enough for a screen that changes a cursor.
  A rectangular decomposition that joined runs ACROSS rows inside one RRE
  rectangle would also be smaller, and is one pass more.
- **`CopyRect`**, which a window system dragging a window would make very good
  use of and which needs the program to know what moved.
- **A trigger for the probe**, which is a different instrument and is not this.

## What this slice left for whoever owns the Makefile

**One line in the top-level `Makefile`.** `buildroot-rebuild` names each of our
packages so that a change to its sources is noticed --- "Buildroot does not
watch our files" --- and it names `cadr-common`, `cadr-console` and
`cadr-disk-pack`. `cadr-terminal-reconfigure` belongs beside them. The first
build after this slice works without it, because a new package has no stamp;
**the second one, after an edit under `package/cadr-terminal/src/`, silently
builds the old sources.** Measured, rather than argued from the comment: a
marker string added to `cadr-terminal.c` and a plain `make` in the Buildroot
tree left the marker out of the binary on the target, and
`cadr-terminal-reconfigure` first put it in. That file was another session's
while this slice ran and was deliberately not touched.

**The image cost.** `rootfs.cpio` 6,251,520 -> 6,279,680, **+28,160 bytes
exactly**; `rootfs.cpio.uboot` 2,813,397 -> 2,824,2xx, **about +10.8 KB**. The
compressed figure is quoted to the kilobyte on purpose: three builds of the
same sources gave 2,824,187, 2,824,232 and 2,824,264, because the gzip and
U-Boot headers inside it carry a timestamp, so the last digits of that number
are not a measurement of anything. The program is 25,956 bytes on the target,
stripped, and the init script 1,962. Nothing else in the image changes: no new
library, no kernel option, no device-tree node, nothing on the card.
