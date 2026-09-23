<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The display output

The CADR's two screens, scanned out of DDR by the fabric and driven onto the
board's HDMI connector, with no software in the path.

The display block writes nothing and reads nothing of the machine's. It takes
the bitmap out of the display's own region of DDR over `S_AXI_HP3`, turns it
into a raster at a monitor's rate, encodes that as DVI and serializes it onto
four differential pairs. The machine cannot detect its presence. A board built
without it is the same machine.

This document is the design, written before the RTL. Every figure in it was
measured on this machine unless it says otherwise, and the measurement is named
beside it.

## What it is driving, and what it is driving it from

There are two pictures, because a CADR carries one display board or two.

The first is `rtl/machine/cadr_tv.sv`'s frame buffer. That is 768 pixels across
and 963 lines, one bit a pixel, 24 words to a line, at `0x1C00_0000` in DDR.
Those are muir's `tv::WIDTH`, `HEIGHT` and `WORDS_PER_LINE` and
`cadr_ddr_map::DISPLAY_BASE`.

The second is the color TV, `lmtv.order`'s "for the color TV, x is 5": 576
pixels across and 454 lines, **four** bits a pixel, 72 words to a line, at
`cadr_ddr_map::COLOR_DISPLAY_BASE`. Those four bits are not a color. They are an
address into a sixteen-entry map of three eight-bit channels, and the map is
where the color is.

**The map is not on the bus.** `lmtv.order` gives the COLOR register as write
only and puts the map RAMs and their digital-to-analog converters OFF the board,
so nothing on the Xbus can read a color back. `rtl/machine/cadr_tv.sv` keeps the
map because the picture cannot be drawn without it; the display output reads it
on a second port of that board and does the lookup in the pixel domain, where a
pixel is. **The block that turns a four-bit pixel into three channels is the
off-board hardware that board describes**, so a port to it is the cable the real
board had rather than a hole in this one.

The copy is refreshed one entry a raster line, so the whole map is never more
than sixteen lines old, and it is refreshed rather than loaded once because
`WRITE-COLOR-MAP` writes the map while the machine runs.

### What is shown, and which way up

Two settings, written at boot by the disk pack program's init step exactly as
`--tv-board` and `--color-tv` are, and changeable at run time from the console.

`--hdmi-output tv|color-tv|both` names the screens. **The first display is
drawn at the left of the active area and the color screen at the right**, both
at 1:1 with the rest black, and where they share a column the color screen is
drawn over the first.

The two are wider together than the raster is, so they share the columns in the
middle. Upright that is 768 + 576 - 1280, which is 64 columns; the first display
occupies columns 0 to 767 and the color screen 704 to 1279. Rotated the widths
are the heights and it is 963 + 454 - 1280, which is 137: columns 0 to 962 and
826 to 1279. Each screen is still centered vertically on its own, so upright the
first display is rows 30 to 992 and the color screen rows 285 to 738, and
rotated they are rows 128 to 895 and 224 to 799.

**Centered on one point they would not share an edge, they would nest.** The
color screen's 576 by 454 falls wholly inside the first display's 768 by 963, so
with both shown the color picture hides the middle of the machine's own screen
and nothing under it can be read. Two views of one machine are worth seeing at
once, which is what having two settings is for.

Neither is scaled. A one-bit picture scaled by anything other than a whole
number turns single-pixel strokes into gray, and the CADR's screen is
single-pixel strokes almost everywhere.

`--hdmi-rotate 0|90|-90` turns the picture a quarter turn, for a monitor stood
on its side. The CADR's screen is 768 by 963 --- taller than it is wide --- and
every monitor made since is wider than it is tall, so upright it wastes the
sides and a turned one holds it with room. Section 2a has how that is done.

Both are latched at the top of a frame, so a setting written while a frame is
being drawn takes at the next one and cannot move the geometry under a picture
half drawn. A change costs one frame, during which the buffers hold the other
shape; the block treats that as starting up rather than as falling behind, which
is why it does not raise `underrun`.

Bit 0 of a word is the leftmost of the 32 pixels that word carries. A lit bit
shows white unless `MODE BOW` is set. On the color screen the LOW NIBBLE is the
leftmost of the 8 pixels a word carries, which is `lmtv.order`'s own
low-order-bit-first. All three rules are muir's `Tv::pixel`,
`Tv::shows_white` and `Tv::color_pixel`, and all three are already written out in
`screen_geom.h`, which is the remote viewer's copy of the same facts. This block
is the third expression of them.

`rtl/machine/cadr_tv.sv` has no raster. It runs the board's sync program, so
the vertical flag is preset where that program's `-TVMA CLR` falls and the
mode register's `VSYNC` and `HSYNC` bits are the program's own; it is held to
muir tick for tick and `docs/tv.md` carries the account. **This block does not
read any of it.** Its frame comes from the video mode below and its picture
from the display's region of DDR, so a machine that changes its sync program,
or one whose program makes no frame at all, changes nothing a monitor sees
here. What the two share is the region and the pixel rules above, and nothing
else.

## 1. The video mode

VESA DMT's **1280x1024 at 60 Hz**: a pixel clock of 108 MHz, both syncs
positive, and a raster of 1688 by 1066.

### Why that one

The picture is 963 lines high. That rules out every common mode below
1280x1024: 1024x768 and 1280x960 are both too short, and 1152x864 is shorter
still. Scaling is not considered. A one-bit picture scaled by anything other
than a whole number turns single-pixel strokes into gray, and the CADR's
screen is single-pixel strokes almost everywhere.

So the smallest standard mode that holds 768x963 unscaled is 1280x1024. It is a
5:4 mode, and a display that will not take 5:4 will not take this output.

The timings are the specification's:

| | Active | Front | Sync | Back | Total |
|---|---|---|---|---|---|
| H | 1280 | 48 | 112 | 248 | 1688 |
| V | 1024 | 1 | 3 | 38 | 1066 |

**The figures live in one place**, `rtl/plumbing/cadr_display_out.sv`'s own
parameters. `tb/cadr_display_out_tb.cpp` carries a second transcription of the
same specification and compares against it, so the two are two descriptions and
can disagree.

### What the part will do

A DVI transmitter in 7-series fabric sends ten bits a pixel down each lane
using a pair of cascaded `OSERDESE2` primitives clocked at five times the pixel
rate on both edges. So the serial clock is five times the pixel clock, and the
lane rate is ten times it.

No Xilinx datasheet exists on this machine, and the speed data inside the
Vivado install is encrypted. The limits were therefore taken from the tool
itself, by over-constraining a clock and asking `report_pulse_width` what
minimum period each primitive's clock input requires. That is the same
speed-file number a build would be held to.

Measured on `xc7z020clg400-1`, speed grade `-1`:

| Clock input | Minimum period required | Maximum frequency |
|---|---|---|
| `OSERDESE2/CLK` | 1.667 ns | 599.9 MHz |
| `OSERDESE2/CLKDIV` | 1.667 ns | 599.9 MHz |
| `BUFIO/I` | 1.666 ns | 600.2 MHz |
| `BUFR/I` | 1.666 ns | 600.2 MHz |
| `BUFG/I` | 2.155 ns | 464.0 MHz |

The same sweep gives 680 MHz at `-2` and `-3`, and 600 MHz for the
XC7Z007S-1, which is the Cora's part.

A serial clock of 600 MHz is a pixel clock of 120 MHz and a lane rate of
1.2 Gb/s. 108 MHz is 1.08 Gb/s a lane, which is inside it. The MMCM is not the
binding limit either: its VCO range on this grade is 600 to 1200 MHz and its
outputs go to 800 MHz, both read out of the clocking wizard's own validation
messages against this part.

The ADV7513 on the DE25-Nano is bound by its own data sheet instead of by a
lane rate, and 108 MHz is inside that too; the section on that board has the
figure.

### The raster is built and not set

A video mode is a pixel clock; the pixel clock comes from a clock manager whose
dividers are fixed when the bitstream loads; and the raster's widths and the
margins that place each picture are elaboration-time constants beside it. So
the whole of it is settled when the fabric is built, and the deadline the
fitter works to is settled with it.

The MMCM dividers are in `boards/arty-z7-20/cadr_arty.sv` and not in the block,
because they are about the BOARD's 125 MHz crystal rather than about the mode.

| DIVCLK | CLKFBOUT | VCO | pixel | refresh |
|---|---|---|---|---|
| 1 | 8.625 | 1078.125 MHz | 107.8125 MHz | 59.92 Hz |

No multiple of an eighth gives 108 MHz exactly. The error is 0.17 per cent, and
monitors accept far more than that.

### How the picture sits in the raster

Side by side horizontally, each centered vertically on its own, with the rest
black.

**Horizontally each picture is pushed to its own edge of the raster.** The
first display's first column is the raster's first column and the color
screen's last column is the raster's last, so the two share exactly as many
columns as the raster is too narrow to hold them separately.

| | first column | last column | first row | last row |
|---|---|---|---|---|
| first display, upright | 0 | 767 | 30 | 992 |
| color screen, upright | 704 | 1279 | 285 | 738 |
| first display, rotated | 0 | 962 | 128 | 895 |
| color screen, rotated | 826 | 1279 | 224 | 799 |

So the two share 64 columns upright and 137 rotated, and there the color screen
is drawn over the first. Vertically the first display's 963 lines in 1024 leave
61 rows, 30 above and 31 below, the odd row going to the bottom, and the color
screen's 454 leave 570, 285 above and 285 below.

**The margins are asserted as first and last columns and not as an overlap.**
An overlap of 64 is right at 704 and wrong at 703, and both are overlaps, so
`tb/cadr_display_out_tb.cpp` measures the extreme column and row each picture
actually reached and holds each of those eight numbers to the table above.

The border is black whatever `MODE BOW` says. The border is not the CADR's
screen at all, so it does not follow a bit that decides how the CADR's own zeros
are shown.

## 2a. Rotation

`--hdmi-rotate 90` turns the picture a quarter turn clockwise and `-90` the
other way. A quarter turn clockwise puts the source's top-left corner at the
picture's top-right: source (column, row) is drawn at raster (H-1-row, column).

**So one output line is one source COLUMN, and that is why it needs a different
buffer.** Upright, a raster line is a source line: 24 consecutive words, one
burst, and the next line is the next 96 bytes. Rotated, a raster line is one bit
out of each of the picture's 963 rows. The bit's position inside its word is the
source column modulo 32, so **32 adjacent output lines are the 32 bits of one
word** from each row --- and the words those 32 lines need are one word column,
963 words at a stride of 96 bytes.

So the block reads one word column into a band buffer and scans that buffer once
per output line, picking bit k of each word. The color screen is the same with
nibbles: 8 pixels to a word, so 8 adjacent output lines are one word column of
454 words at a stride of 288 bytes.

**The picture is still read exactly once a frame.** The first display is 24
words wide, so it is 24 word columns of 963 words, which is 23,112 --- the whole
picture. The color screen is 72 columns of 454, which is 32,688, which is
`COLOR:MAKE-SCREEN`'s own count. Rotation costs block RAM and costs nothing in
bandwidth.

Rotated, the pictures are 963 by 768 and 454 by 576, and both fit the raster at
1:1.

### What the band fetch costs the port

A band's words are one out of each source row, so every word is a transaction of
its own: 963 single-beat reads where an upright line is one or two bursts.
**The address channel therefore runs ahead of the data**, up to eight reads in
flight. One at a time it does not finish in time: a color band is 454 words and
has eight raster lines, which is about 12,500 clocks, and 454 round trips at the
port's own latency is more than that. All of them are single beats to one
identifier, so they come back in the order they were asked for and the word that
arrives is the word the take counter names --- which is why this needs a counter
and not a queue.

### The line address is an addition and not a product

A screen's byte address for a line is a register that adds one stride each
line. It is not the clamped line number multiplied by the line's bytes.

Written as a product it is a DSP and a chain of clamps hanging off the line
counter. It is combinational, it is recomputed on every pixel, and it feeds the
comparator that drives the request register's own clock enable. That put
twenty-two levels of logic between the line counter and that enable and missed
the pixel clock by 8.430 ns. The depth is the arithmetic's own and not a
placement figure.

The row moves by one a line and the address by one stride, so the addition is
the product. The same trick makes the phase generator's taps and the disk's
block position, and this block's own strided fetch already walks its address by
a source line. What stands in front of the comparator is now a register.

Rotated there is no product to begin with, because a word column is the source
column shifted. The step is four bytes every 32 lines, or every 8 for the color
board. A quarter turn the other way walks the word columns backwards, so its
step is minus four from the last column rather than a rule of its own.

### The frame a setting changes in reports nothing

A change of geometry makes the fetcher ask afresh. The raster's first look of
that frame can take a bank fetched under the old shape, and two fills of the new
shape can then land between two looks.

The handshake is one bit, so two fills toggle it back to where it was and read
as none. The raster shows black and calls the port slow. That is the changeover
and not the port, so the frame in which a setting changed neither primes nor
complains, and the frame after it does both.

It was measured on a quarter turn anticlockwise and not on the one clockwise.
Only the anticlockwise picture's first band sits at an address the upright frame
had not already asked for, which is an accident of the margins. That is what
makes a fault of this kind look like one rotation being special.

## 2. The clocks

The pixel clock and its serializer clock come from an MMCM of their own, off
the board's 125 MHz, separate from the machine's. The machine's own MMCM makes
100 MHz and its tick stays 10 ns. Nothing about the machine moves.

**The second MMCM is in `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv` and not in the
top level.** `boards/arty-z7-20/vivado/tick.tcl` reads the machine's tick by
finding exactly one `MMCME2_BASE`'s four parameters in
`boards/arty-z7-20/cadr_arty.sv`, and stops the flow if it finds two. That is
right: the machine's tick is the machine's, and a pixel clock is not a tick. So
the pixel clock is generated in the block that uses it and `tick.tcl` goes on
answering the question it was asked.

**And that guard caught something the arrangement alone did not.** The phy's
own parameters were first spelled the way the primitive spells them, so that a
reader could check them against it. The MMCM was in the phy, but the top level
overrode those parameters by name, so `DIVCLK_DIVIDE` and `CLKFBOUT_MULT_F`
appeared twice in `cadr_arty.sv` and the whole board flow stopped at the first
bitstream saying the tick was ambiguous. It was right to. The two are named
`VCO_DIVIDE` and `VCO_MULT_F` now, which say the same thing about the same
numbers and cannot collide.

**The serial clock rides a `BUFIO`, not a `BUFG`, and that is a measured limit
rather than a style.** The serial clock is 539.0625 MHz and a global buffer on
this speed grade will not take a period shorter than 2.155 ns, which is
464 MHz. Built with a `BUFG` the design routes, reports `WNS +4.734 ns` and
looks finished, and fails one check: `Min Period, BUFG/I, required 2.155 ns,
actual 1.855 ns, slack -0.300 ns`. Built with a `BUFIO` the same design reports
`WNS +4.709, WHS +0.155, WPWS +0.188` and zero failing endpoints of any kind.
The difference is one primitive and it is invisible in a schematic.

A `BUFIO` reaches only its own clock region, which is why this works at all.
All eight of the connector's TX pins are in bank 35 and, measured with
`get_clock_regions`, all eight are in clock region `X1Y2`, which has four
`BUFIO` sites. Had the four pairs been spread across two regions the
serializers could not have shared one regional clock and this would be a
different design. A board that moves those pins has to check this again.

The pixel clock stays on a `BUFG`, because the raster, the line buffer's read
side and the encoders are ordinary fabric and have to be reachable from
anywhere on the die. So a serializer sees its two clocks over different
networks. That is the one thing in the block the fitter has to be asked about
rather than assumed, and the answer is in the fit report quoted above: it
closes.

### How the two domains meet

The memory side runs on the machine's 100 MHz. The raster runs on the pixel
clock. They are unrelated and nothing tries to relate them.

They meet at the buffers. There is one a screen, each of two banks. The raster
reads one bank while the memory side fills the other, and they change places
when what is being shown has to change --- every raster line upright, every 32
lines rotated for the first display and every 8 for the color screen.

**Each entry is a whole 64-bit beat and not a 32-bit word**, and that is what
makes one memory serve both shapes. A contiguous fetch brings two words in one
beat: written as two 32-bit entries that is two writes in one cycle, which no
block RAM does and which would force the buffer into lookup tables. One 64-bit
entry a beat is one write, the read picks its half by the low bit of the word
index, and the strided fetch --- which uses one word of each beat --- writes one
half at a time, which is a byte-enabled write and is what a block RAM is for.

| | entries a bank | upright | rotated | two banks |
|---|---|---|---|---|
| first display | 512 | 12 of them | 482 | 65,536 bits, two RAMB36 |
| color board | 256 | 36 | 227 | 32,768 bits, one RAMB36 |

**And on the second vendor's part that byte-enabled write has to be written as
one, not merely be one.** The same three cases can be written as a full-width
assignment in one branch and two 32-bit sub-range assignments in the others,
which reads more directly. Vivado infers block RAM from that shape without
being asked. Quartus does not: it says it is extracting a RAM and then builds
all 98,304 bits out of registers, with no warning and nothing in its RAM
summary to say so. Measured on the DE25-Nano's part, on this module alone,
135,576 lookup tables and 99,437 registers against 1,257 and 1,005 --- and the
whole board's fit then stops, because the part has 93,600 lookup tables.
Asking Quartus for an M20K does not help; neither that attribute nor turning
its read-during-write checking off moves a single number, which is a
constraint that reaches nothing looking exactly like one that works. So the
write is one enable a half, each half written by itself, which is what a block
RAM with byte enables is. Vivado's result is unchanged by the rewriting: 3
block RAM tiles either way, and six lookup tables fewer.

The fitter agrees, and the table above is a prediction it confirms rather than
a claim about it. Synthesis maps `mbuf` as 1K by 64 into two RAMB36 and `cbuf`
as 512 by 64 into one, and the routed board's block RAM goes from 42.5 tiles to
45.5. The three tiles are the whole of the increase: no RAMB18 moves.

Registers fall by 1,258 at the same time, and that is the same change seen from
the other side. The line buffer this replaces could not be block RAM at all ---
synthesis said so, `Trying to implement RAM 'lbuf_reg' in registers` --- so it
was flip-flops, and a band buffer is not.

So the buffers are **three block RAM tiles** where the one line buffer of 24
words was a handful of lookup tables. Upright the two hold 24 and 72 words,
which is 96 words a raster line against the 24 this block read when it drew one
screen.

The handshake is one toggle each way. The raster sets the line number it wants
and flips a request toggle on the same pixel-clock edge. The memory side sees
that flip two of its own clock edges later at the earliest, by which time the
number has been stable for two clocks and will stay stable for the rest of the
line. A line is 1688 pixel clocks. So the number is settled long before
anything reads it, and only the toggle needs synchronizing. Coming back, an
acknowledge toggle is set to the value of the request just finished, so the two
being equal means everything asked for has arrived.

The bank is never carried across. Both sides count requests, one counting what
it sent and one what it served, and the bank is the low bit of that count. The
counts step together because there is exactly one fill per request. A signal
saying which bank is in use would be a second description of something both
sides already know, and two descriptions of one fact is how they come to
disagree.

The two toggles come out of reset different, on purpose. Equal would mean
"everything asked for has arrived" before anything had been asked for, and the
raster would show one line out of a buffer nothing had written.

If a fill has not arrived when the raster needs it, that line is shown black
and a sticky `underrun` bit is raised. It cannot happen in normal running: a
line gives the memory side 1688 pixel clocks, which is 15.7 microseconds, to
move 96 bytes.

The first line of all is black, because nothing has been fetched when it is
drawn, and that is not counted as an underrun. Counting it would set the sticky
bit on every board at power-on and make it mean nothing afterwards.

### What tearing means here

The machine writes the bitmap whenever it likes and the raster reads it
whenever it likes, so a line fetched while the machine is drawing shows some
words from before a write and some from after.

On a one-bit black-and-white screen that is a character appearing with its top
half drawn, for one frame of 16 milliseconds. It is also exactly what the real
machine did. MIT's display controller scanned the same memory the processor
wrote, with no buffering and no interlock. Double buffering would need a second
region, a copy engine and a rule about when to swap, and would show the
machine's screen less faithfully than tearing does.

The CADR's own frame rate does not enter. The display board's frame is
15,456,000 ns of the machine's time, which at the 10 ns grid and this board's
10 ns tick arrives every 15.456 real milliseconds, or 64.70 Hz. The monitor runs
at 59.90 Hz.
Neither number constrains the other, and the vertical flag the machine reads is
the display block's, not this block's VSYNC.

## 3. The memory read

A burst-reading AXI3 master on `S_AXI_HP3` fetches into each screen's buffer,
ahead of the raster: a line at a time upright, and a word column at a time
rotated, as section 2a says.

A line is 24 words of 32 bits, which is 96 bytes, which is twelve beats of the
64-bit port. Every line starts 96 bytes after the one before it, and 96 is a
multiple of eight, so every line starts on a beat boundary. AXI3 caps a burst
at sixteen beats, so twelve fits with room to spare. A line of the color board
is 72 words, 288 bytes, which is thirty-six beats and never one burst.

**But twelve beats is not always one burst, because 96 bytes does not tile
4 KB.** AXI forbids a burst crossing a 4 KB boundary, and 4096 is not a
multiple of 96. The two have a common multiple at 12,288 bytes, which is three
pages and 128 lines, so the pattern of line starts repeats every 128 lines and
exactly two of each 128 begin close enough to a boundary that twelve beats
would run over it. Over the picture's 963 lines that is **15 lines**, the first
at line 42. A color line's 288 bytes and 4096 meet at 36,864, which is nine
pages and 128 lines.

So a fetch is one burst where it fits and more where it does not, split exactly
at the boundary, and the buffer is filled by a word pointer that runs across the
whole fetch rather than by a beat index inside a burst.

This was not foreseen. The first draft issued one burst of twelve every time,
and the check caught it on the first frame the module ever drew, on exactly
those 15 lines. The testbench recomputes every burst's permitted length
independently, asserts that no burst crosses a boundary, and counts the lines
that take two — so the second burst cannot quietly become dead code.

**A request is made when what is wanted changes, which is once a line upright
and once a band rotated.** The raster computes the byte address it will need a
fixed number of lines from now --- one line upright, 32 rotated for the first
display and 8 for the color board --- and asks for it when it differs from the
address it last asked for. The memory side is checked against that rule: every
fill is at the address the rule gives, and there are as many of them as it says.

It replaced "one request a line, always, including the lines that show
nothing", which was this block's invariant while it drew one screen upright.
The clamped fetches for the 103 border and blanking lines went with it, because
a band is not a line and a rule that names lines cannot describe one.

### The bandwidth

Each picture is read exactly once a frame. The first display is 23,112 words,
92,448 bytes, and at 59.90 frames a second that is 5.54 MB/s. The color screen
is 32,688 words, 130,752 bytes, which is 7.83 MB/s. Both together are
13.37 MB/s.

The port is 64 bits at 100 MHz, which is 800 MB/s. So the display uses under
1.7 per cent of it with both screens shown. The DDR3 behind it runs at 1050
MB/s per 32-bit transfer at this board's clock and is shared four ways. There
is no bandwidth question here and the arithmetic is written down only so that
nobody has to wonder.

### The arbitration

`S_AXI_HP2` and `S_AXI_HP3` are multiplexed down to one DDR controller port,
and `S_AXI_HP0` and `S_AXI_HP1` to another. So the display shares a controller
port with the disk, and neither shares one with the machine's memory bridge on
HP0. That was the reason the disk moved from HP1 to HP2 in the first place, and
it keeps holding: the machine's own memory path is the one seam at machine
speed and nothing else arbitrates against it.

The disk's traffic is bursty, in blocks of 1024 bytes, and idle for long
stretches. The display's is steady, a line or a band as the raster needs it. The
display can be made to wait a long time without anything going wrong, because
it is ahead of the raster; the disk cannot be starved by 14 MB/s.

The machine's own timing is untouched either way. Its NXM timer is 4.25
microseconds from the grant, and it is not on this controller port.

## 4. TMDS

The signal is DVI 1.0: video periods and control periods and nothing between
them. No data islands, no preambles, no guard bands, no audio, no InfoFrames.

Every HDMI monitor accepts it. HDMI's own specification requires a sink to
accept DVI, and it is what every monitor with a DVI input has always taken.
What it costs is that the sink chooses its own colorimetry and cannot be told
the picture is full range. For a picture that is black and white and nothing
else, that costs nothing. Building the data islands would mean a packet
scheduler, BCH error correction and audio clock regeneration, for a machine
that has no audio.

Three channels are 8b/10b encoded by the algorithm in DVI 1.0 section 3.2.2.
Each pixel byte is turned into ten bits in two stages: the first minimizes
transitions by choosing XOR or XNOR along the byte and marking which in a ninth
bit, and the second balances the direct current by inverting the eight bits or
not according to a running disparity, marking that in a tenth.

The channel assignment is the specification's and is not a choice. Channel 0
carries blue and, in its control period, HSYNC as C0 and VSYNC as C1. Channels
1 and 2 carry green and red with both control bits zero. A transmitter that put
the syncs elsewhere would drive a monitor that never locks, and the fault would
look like a cable.

A control period sends one of four fixed ten-bit tokens and resets the running
disparity to zero. That is in the specification, and it is also what makes the
encoder's state space small enough to search exhaustively, since every line's
blanking returns it to a known state.

The clock channel is not encoded. It carries the constant ten-bit word
`0000011111`, sent least significant bit first, so the line is high for five
bit times and then low for five. That is one period of the pixel clock per
pixel.

The CADR's one bit becomes 0x00 or 0xFF on all three channels.

### The pins

The pin constraints are in `boards/arty-z7-20/cadr_arty.xdc` with the rest of
the board's pins, and not in a file of their own read only when the display is
built. The four pairs are in the top level's port list on every board, because
a port with no pin cannot be placed and a pin constrained `TMDS_33` cannot be
driven single-ended; so with the display not built, four `OBUFDS` are fed from
zero and the connector sits at a direct-current level, which a monitor reads as
no signal. The display's own timing constraints are in
`rtl/plumbing/xilinx7/cadr_hdmi.xdc`, which is read only when it is built, on
`cadr_ddr.xdc`'s precedent.

The pins are taken from Digilent's published master file,
`Arty-Z7-20-Master.xdc` from
`github.com/Digilent/digilent-xdc`, at the commit that last touched that file,
`00a3404901f35aa9567b01ecb3f2c233b6efe9f4`. The copy this was read from has
sha256 `bfdb236bfbd3a575c86c25aaa2f8d155075a5b4b03ec46503ab2533a777bada5`. The
lines are copied out with the file's own schematic names and pin functions kept
in the comments, which is what `boards/arty-z7-20/cadr_arty.xdc` already does
for the Pmod headers.

| Signal | Pin | Standard | Pin function |
|---|---|---|---|
| `hdmi_tx_clk_p` / `_n` | L16 / L17 | `TMDS_33` | `IO_L11P/N_T1_SRCC_35` |
| `hdmi_tx_d_p[0]` / `_n[0]` | K17 / K18 | `TMDS_33` | `IO_L12P/N_T1_MRCC_35` |
| `hdmi_tx_d_p[1]` / `_n[1]` | K19 / J19 | `TMDS_33` | `IO_L10P/N_T1_AD11P/N_35` |
| `hdmi_tx_d_p[2]` / `_n[2]` | J18 / H18 | `TMDS_33` | `IO_L14P/N_T2_AD4P/N_SRCC_35` |

`TMDS_33` on a high-range bank is Xilinx's emulation of TMDS out of a 3.3 V
driver and a resistor network on the board. The XC7Z020 has no high-performance
banks at all, so there is no alternative and no choice to make.

The three remaining TX pins are not used and are not brought out. `hdmi_tx_hpdn`
at R19 is the hot-plug detect, which would say whether a monitor is attached;
nothing here changes its behavior depending on that, so reading it would be a
signal with no consumer. `hdmi_tx_scl` and `hdmi_tx_sda` at M17 and M18 are the
display data channel, over which a source reads the monitor's EDID; this block
sends one fixed mode and does not negotiate, so there is nothing to read it
for. `hdmi_tx_cec` at G15 is consumer electronics control and is not wired on
this board's connector in any useful way. Leaving all four out of the port list
is deliberate and is recorded here so that their absence reads as a decision
rather than an oversight.

## 5. `S_AXI_HP3`

`boards/arty-z7-20/vivado/ps7_config.tcl` turns `PCW_USE_S_AXI_HP3` on and
gives it the same 64-bit width and 6-bit ID width HP0 and HP2 have, merged over
Digilent's block at the bottom of the file as the other three of ours are.

**Enabling it changes `ps7_init` by nothing.** Measured by regenerating the
routine and comparing the ordered register operations, which is what
`boards/arty-z7-20/vivado/ps7_ops.py` exists for: 673 operations over 24 procs,
byte-identical to the committed file across all three silicon revisions. That
is the same answer HP2 at 64 bits and `M_AXI_GP1` gave, and it has the same
reason: at its native 64 bits an AFI port needs no width write, and the two
writes that do differ between 32 and 64 bits are in `ps7_post_config` rather
than `ps7_init`.

So the start-up routine on the card does not change, and a board running the
display output boots exactly as a board without it.

The port's own pins are added to `boards/arty-z7-20/cadr_ps7.sv` by
`boards/arty-z7-20/vivado/gen_ps7.py`, which is how HP0, HP2 and both GP ports
got theirs. An exposed PS7 pin that nobody connects is a `PINMISSING` that
stops `build/arty.pass`, so the wrapper change and the wiring of it are one
commit, and HP3 is tied off in the board configurations that do not build the
display.

## 6. Where it lives, and what each check holds

| File | What it is | What holds it |
|---|---|---|
| `rtl/plumbing/cadr_display_out.sv` | the AXI master, the buffers, the raster, the compositor, the map, and the sleep timer and mute | `build/display_out.pass`, `build/display_sleep.pass` |
| `rtl/plumbing/cadr_hdmi_tx.sv` | the three channels and the clock channel | `build/hdmi_tx.pass` |
| `rtl/plumbing/cadr_tmds_encode.sv` | one channel's 8b/10b encoder | `build/hdmi_tx.pass` |
| `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv` | the MMCM, the serializers, the output buffers | lint and the fitter only |
| `boards/arty-z7-20/cadr_arty.xdc` | the eight pins, on every board | the fitter |
| `rtl/plumbing/xilinx7/cadr_hdmi.xdc` | the clock groups, only when it is built | the fitter |
| `tb/cadr_arty_stubs.sv` | `OSERDESE2`, `OBUFDS`, `BUFIO` as empty shells | nothing; it models nothing |
| `rtl/plumbing/cadr_adv7513.sv` | the DE25-Nano's transmitter, written over its two-wire bus | `build/adv7513.pass` |
| `boards/de25-nano/quartus/cadr_hdmi.sdc` | the pixel clock, the forwarded clock and the video pins, only when it is built | the fitter |

The split is not the obvious one and the reason is checkability. Putting the
encoder in the same file as the serializer primitives would have made the
encoder unsimulable, because a check on that file would have to be built
against stubs, and a check built against a stub confirms rather than compares.
So everything that can be plain SystemVerilog is, and the Xilinx-specific file
is four primitives and a clock with no logic in it at all.

### `display_out`

It found three faults in the first draft and a fourth when the two pictures
moved apart, and every one of them would have been invisible against a memory
of zeros.

The 4 KB crossing is described above. The second was a synchronizer that came
out of reset holding zero while the signal it synchronized came out of reset
holding one, so the first line's readiness test was true for the two or three
clocks before the real value arrived, the first line took a bank nothing had
filled, and every bank after it was one out. The whole picture was drawn one
line early, for ever. The third was the line buffer's index: the bank and the
word are concatenated, so the bank stride is 32 and not 24, and an array sized
at two times 24 put the second bank's last eight words off the end of it. The
right-hand third of every other line came out black.

The fourth is the one the placement uncovered. The band buffers' output is
registered, so the entry a pixel is drawn from is read at the edge before that
pixel and the bank that read uses is the bank in force an edge before that; a
bank taken at a line's first pixel is two pixels late. Centered, those two
pixels were border and nothing showed. The first display now begins at the
raster's first column, and the first two columns of every line came out of the
line before it. A line's work is done in the blanking that precedes it now.

None of the four is the kind of thing that is found by reading.

`tb/cadr_display_out_tb.cpp` runs `cadr_display_out` with two clocks at their
real and mutually irrational periods, against a modeled DDR poisoned
injectively in the address, and behaves like a monitor: it recovers the raster
position from the sync and data-enable outputs rather than from any internal
counter, so the module's pipeline depth is not something the check has to know.

It holds:

- every pixel inside the picture against the bit of the modeled memory it
  comes from, over a whole frame;
- every pixel outside the picture and inside the active region black;
- the data-enable and both syncs against the specification's own figures,
  counted rather than sampled: 1280 enabled pixels on each of 1024 lines, 1688
  pixels and 1066 lines to a frame, sync pulses of 112 and 3 at the right
  offsets and the right polarity;
- twelve beats per raster line, `INCR`, eight bytes a beat, at the address the
  line number gives, in one burst or in two where a 4 KB boundary splits it,
  with no burst crossing a boundary, every burst's length recomputed
  independently by the check, exactly one address handshake and one `RLAST`
  per burst, and at least one line actually split so that the second burst is
  not dead code;
- the buffer handoff, by running the memory side slow enough to lose the race
  and requiring that the underrun is reported and the screen goes black rather
  than showing the wrong words;
- the color screen's four-bit pixels through a map the check supplies, against
  the three channels the encoder is given --- the map injective in the color
  with no two channels of one color equal, so a channel order the other way
  round, an index off by one and a map read off the other screen are each
  visible;
- both screens at once, with the color one over the first in the columns they
  share;
- both quarter turns, by the same pictures read the other way: an output line
  against the source column it is, and the band fetch's own walk --- every read
  a source line apart until the band is done, and no more reads in flight than
  the master may hold;
- **where each picture sits**, as the first and last column and the first and
  last row it actually reached, for each screen alone and for both together,
  upright and turned: eight numbers a configuration, held to the table above.
  The two screens are told apart by their colors and not by where they are ---
  the first display draws only black and white and no entry of the map is
  either --- so the measurement says nothing about the margins it checks.  The
  reference frame's own extents are taken first and held to the same numbers,
  because an edge column the bitmap happens to leave dark would move the
  measurement with nothing wrong in the module;
- **the picture read exactly once a frame**, counted in beats per frame against
  the arithmetic for each of the four shapes, so a band fetched twice or a line
  fetched for the border shows as a number.

**The two windows are poisoned with DIFFERENT constants**, so a color pixel
fetched out of the first display's window cannot come back right, and the check
asserts that neither window is read at all when its screen is not being shown.

The last of those is there because a stimulus fast enough hides the race it
exists to show. At the port's real speed the fetcher is never behind, so the
underrun path would be dead code that no mutation could reach.

### `hdmi_tx`

`tb/cadr_hdmi_tx_tb.cpp` carries a second encoder, written from the
specification's pseudocode rather than from the RTL, and compares all three
channels against it.

It holds:

- every one of the 256 byte values in every disparity state the encoder can
  reach. The states are found by breadth-first search over the reference
  model, and the sequence that drives the encoder into each one is played
  through the device, so this is exhaustive over the encoder's whole state
  space rather than over a sample of it;
- all four control tokens, and that a control period resets the disparity;
- the channel assignment: that HSYNC and VSYNC appear as C0 and C1 of channel
  0 and that channels 1 and 2 send the zero token;
- the clock channel's constant word;
- a long pseudorandom stream of pixels and blanking, compared every cycle;
- the mute: all four lanes at one word through a stream of pixels and blanking,
  and the specification's words again after it is let go in a control period.

**It does not hold the serializer, and nothing does.** `OSERDESE2` and
`OBUFDS` are stubbed in `tb/` so that the top level lints, and the stubs tie
their outputs low. A simulation built on them would show a dark connector
whatever the encoder did. What stands behind the serializer is the fitter and,
in the end, a monitor. A monitor has now been put on the connector and shows
the machine's own 768x963 screen in a 1280x1024 raster, white on black. That
reading was taken on a build that centered the first display, before it was
moved to the raster's left edge, and `docs/board.md` has it and says so.

### `arty`

`build/arty.pass` gains a sixth board configuration, `HDMI=1` with `DDR=1`,
which lints the whole top level with the display output in it. That is what
catches a pin that is brought out and not connected.

## The settings

Three settings, all of them written at boot and changeable at run time.

| | where | what |
|---|---|---|
| `--hdmi-output tv\|color-tv\|both` | `fpgarc`, console word 34 | which screens |
| `--hdmi-rotate 0\|90\|-90` | `fpgarc`, console word 34 | which way up |
| `--hdmi-sleep SECONDS` | `fpgarc`, console word 36 | how long before the monitor sleeps |

The sleep setting is described in the next section.

The two settings are written into the console's page 2 word 34 by
`S80cadr-disk-packs` before the drive is presented, exactly as `--tv-board` and
`--color-tv` are written into word 33, and `cadr-console hdmi-output` and
`hdmi-rotate` reach them at run time. `docs/console.md` has the word and
`docs/fpgarc.md` the flags.

## Sleep

A digital link has no power management of its own. DPMS was a way of driving
VGA's two sync lines, and DVI has nothing like it. A source puts a monitor to
sleep by stopping the link. The monitor then sees no signal and goes into its
own power save.

So the display output sleeps a monitor by holding all four lanes at one word.
The clock lane is held with the three data lanes, because a monitor locked to a
running clock stays awake and shows black. `cadr_hdmi_tx.sv` does the holding,
and a held lane looks exactly like a board built without a display output.
Everything in front of the gate keeps running: the pixel clock, the raster, the
fetch and both buffers. A monitor that wakes therefore locks onto a picture that
never stopped, and it shows the machine's screen as it is now.

### The timer

The timer counts whole seconds of the machine's clock. When the setting's
seconds have gone by, the lanes are muted at the next frame boundary. **The
timer always runs.** It does not matter whether a keyboard is plugged in or
whether anybody is watching over the network, which is how a computer's own
display sleeps. A setting of 0 never sleeps.

The setting is `--hdmi-sleep SECONDS` on the card, 300 by default, and
`cadr-console hdmi-sleep [SECONDS]` at any time. With no number the console
reports the setting and whether the monitor is asleep. The setting is fifteen
bits, so the longest is 32,767 seconds, about nine hours.

The setting lives in `cadr_display_out.sv` and not in the console. The console's
page 2 word 36 carries a new setting and a wake to it as one-tick pulses, and
reads back what it holds: the setting, and whether the lanes are muted. A board
with no display output reads `UNMAPPED` there, because it has no timer to
report. The Cora Z7-07S is such a board.

### What wakes it

**Only a key or the mouse at the board wakes the monitor**, and that is also the
only thing that starts the timer over. The fabric cannot tell such a key from a
key typed into a VNC viewer, because one program writes the keyboard's register
for both. So that program decides. `cadr-terminal` writes a wake into word 36
for a record that arrives on its input link from `cadr-usb-input`, and for
nothing else.

A viewer's key still reaches the machine. It neither wakes the monitor nor
starts the timer over. A USB keyboard being plugged in or pulled out is not an
event either, and neither are the key releases the terminal makes for a keyboard
that went away. The terminal writes at most one wake every 100 ms, which loses
nothing against a timer that counts seconds.

### What the board's other controls do

| | the timer | the lanes |
|---|---|---|
| a new setting | starts over from the write | on again at the next frame boundary |
| BTN1, the fabric reset | starts over, and the setting returns to 300 | on again at the next frame boundary |
| BTN0, or `cadr-console boot` | nothing | nothing |

A new setting starts the timer over because the setting the monitor slept under
is gone, and somebody who asks for ten minutes expects ten minutes from now. A
setting of 0 wakes a monitor that is asleep and keeps it awake. A fabric reset
puts the fabric's own 300 back until Linux next boots and writes the card's
setting, which is how the lamps behave after BTN1 too. The machine's boot button
does nothing to the display output, because the display output is not part of
the machine and hears nothing from it.

### Where the mute changes

The mute changes only at a frame boundary, which is the instant before a frame's
first line. So the link stops and starts in the blanking, and a monitor is never
handed half a frame. The timer runs on the machine's clock, and its verdict
crosses into the pixel clock's domain through two flops. The mute takes it at
the next frame boundary, which is at most a frame later. The console reads
`asleep`, which is the mute brought back into the machine's clock through two
more flops. Each is one bit that stands for a frame, so two flops are all it
needs. `rtl/plumbing/xilinx7/cadr_hdmi.xdc` writes a bound on each crossing in
the file's own idiom. Measured, the asynchronous clock group overrides it, as it
overrides the fetch job's bound beside it, so neither is in force on the board.

A second is `SECOND_T` edges of the machine's clock, 100,000,000 at the 10 ns
tick. That is a fabric choice like the debug window's watchdog, so it is counted
in board ticks and not on MIT's grid.

### What holds it

`build/display_sleep.pass` builds `cadr_display_out` with a raster of 100 by 80
and a second of 2,000 ticks, so that the default of 300 seconds is eighty
frames. The default itself is the module's own. The check holds:

- the timer running out after exactly the setting's seconds, to the tick, from a
  write, from a wake while asleep, from a wake while awake and from a fabric
  reset;
- the mute changing only at a frame boundary, recovered from the syncs and the
  data enable as a monitor recovers it;
- the mute coming on at the first boundary the verdict can reach through its
  synchronizer, and not before the timer ran out;
- a wake letting the lanes go at the next boundary;
- a setting of 0 never muting, and a 0 written to a sleeping display waking it;
- the raster keeping its own shape through whole frames with the lanes muted;
- `asleep` agreeing with the mute within its synchronizer;
- a fabric reset letting the lanes go and putting 300 back.

`build/hdmi_tx.pass` holds the gate: all four lanes at one word while muted, and
the specification's words again after the mute is let go in a control period.
`build/console.pass` holds word 36: a key becomes one pulse with its value, a
value that means nothing becomes no pulse, and the word reads back what the
display holds. The terminal's own check holds that a record on the input link
calls the wake and that a viewer's key, a viewer's pointer, a source attaching
and a source going away do not.

**Nothing holds the board's 100,000,000**, which is a literal like the
watchdog's second.

**A monitor has now been put to sleep and woken on silicon**, on the
DE25-Nano. Set to fifteen seconds, with nobody touching that board's keyboard
or mouse, the monitor went into its own standby, and a key pressed at the board
brought the picture back. Both directions were seen at the monitor. Before
that the setting had been left at never, which is a setting doing what it says
rather than a mechanism failing. `docs/board.md` has the session. The same
thing has not been seen on the Arty Z7-20, whose sleep holds the lanes rather
than the clock it hands a transmitter.

## What it costs, and whether it is being timed

`DDR=1 HDMI=1` — the machine running out of real memory with the display
beside it — through `boards/arty-z7-20/vivado/bitstream.tcl`, at the commit
this section was written, beside the same board fitted at the commit before it
so that the two are one comparison and not two readings taken months apart:

| | with this placement | the commit before |
|---|---|---|
| worst setup slack | **+0.319 ns**, 0 failing of 54,752 endpoints | +0.313 ns, 0 of 54,746 |
| worst hold slack | +0.031 ns, 0 failing of 54,368 | +0.039 ns, 0 of 54,362 |
| worst pulse width slack | +0.188 ns, 0 failing of 13,922 | +0.188 ns, 0 of 13,921 |
| Slice LUTs | 14,569 of 53,200 | 14,611 |
| registers | 11,269 | 11,268 |
| occupied slices | 5,361 of 13,300 | 5,381 |
| block RAM tiles | 46 of 140 | 46 |
| bitstream | 4,045,762 bytes, 0 errors | the same size |

So the placement costs nothing: 42 lookup tables fewer, one register more, the
same memory, and the three slacks within the noise. Do not read the slack's
last digits as precision either way — a bit-identical netlist has moved that
number by a quarter of a nanosecond in this project before.

Against the same board without the display, measured at `95cbb84` —
10,909 LUTs, 7,390 registers, 41.5 block RAM tiles — the display costs about
2,200 LUTs, 3,800 registers and three and a half block RAM tiles. That pair is
of an older commit and is kept for the size of the display rather than for the
board's own figures.

**The pulse-width figure is the one to look at, and it is the display's.** It
is the minimum-period check, which is where a clock buffer asked to carry more
than it can shows up. +0.188 ns is the `BUFIO` carrying the 539 MHz serial
clock with 1.855 ns against the 1.666 ns it requires. The negative control is
above: the same design with a `BUFG` there reports `-0.300 ns` on that one
check and is otherwise indistinguishable.

### Whether the new registers are timed at all

This is a real question here and not a formality. `rtl/plumbing/xilinx7/cadr_machine.xdc`
defines its relaxed set as every register minus a name list, scoped to
`cadr_machine`, and this project has already had a whole module land inside
that set unnoticed and three slices quote fit figures for a design nobody was
timing.

The display output is **not** under `cadr_machine` — it is beside it, in the
board's own memory generate — so the machine's scoped file cannot reach it.
That is an argument and not a measurement. The measurement is the flow's own
assertion, which prints:

    XDC: no register outside u_machine, g_ddr.u_axi, g_ddr.u_debug_window,
         u_dbg_cable is relaxed

`g_ddr.g_hdmi` is not in that list, so nothing in the display carries a
relaxation and every one of its paths is timed at one tick of whichever clock
it is on. The per-clock table says the same from the other side: 2,458
endpoints on `pixel_raw` with a worst slack of +0.655 ns, and 52,294 on
`clk_raw`. The serializer's own clock carries ten endpoints and no setup path
at all, which is the pulse-width check above and nothing else.

The two domains have no paths between them, which is what the asynchronous
clock group is for: the inter-clock table is empty.

### The constraint file's own trap, met again

`rtl/plumbing/xilinx7/cadr_hdmi.xdc` was first written with a `foreach` loop
and an `if` guarding that the clocks it names exist. Both came back as
`CRITICAL WARNING [Designutils 20-1307] Command 'foreach' is not supported in
the xdc constraint file`, so the guard applied to nothing while reading as
though it were protecting something — and a third critical warning said the
`set_max_delay` on the crossing had matched no object, because the filter
named a generate hierarchy the tool spells its own way.

That is the same failure recorded against `cadr_machine.xdc`'s
`foreach` and against `cadr_ddr.xdc`'s scoped `get_ports`, in a new file, on
the first try. The file holds only constraints now, the filter is on the
register's own name rather than on its hierarchy, and the assertions are in
`boards/arty-z7-20/vivado/bitstream.tcl` where Tcl control flow is legal and
where the flow's other assertions already live.

## The DE25-Nano

The same display on a second board, with one stage of it off the fabric.

The DE25-Nano has an Analog Devices ADV7513 transmitter between the fabric and
its HDMI connector. The fabric hands that part a raster on a parallel bus,
twenty-four bits of color with a clock, a data enable and two syncs, and the
part encodes and serializes it. So the whole of section 4 above has no
counterpart on this board: `cadr_tmds_encode.sv`, `cadr_hdmi_tx.sv` and
`xilinx7/cadr_hdmi_phy.sv` are not built for it and nothing replaces them.

Everything above the raster is the same file.
`rtl/plumbing/cadr_display_out.sv` already ends at a parallel raster, because
that is what its encoder was always fed, so the two boards run the same
module with the same video mode, the same compositor, the same two rotations
and the same sleep timer. The two settings reach it through the console's page
2 word 34 and word 36 exactly as they do on the Arty Z7-20, and the Linux
programs are the same packages unchanged.

The memory side differs only in where it arrives. The Arty Z7-20 gives the
display a port of its own, `S_AXI_HP3`. The Agilex 5's processor has one
fabric-to-SDRAM bridge, so the machine, the disk pack side and the display
share it through a burst-level arbiter that gives the machine priority;
`rtl/plumbing/cadr_f2sdram_share.sv` is that arbiter and its header carries
the argument. The display is its third master, it reads and never writes, and
it can be made to wait because it runs ahead of its own raster.

### Configuring the transmitter

**The part does nothing at all until its registers are written.** That is the
one piece this board needs and the Arty Z7-20 does not, where a loaded
bitstream is already transmitting. `rtl/plumbing/cadr_adv7513.sv` writes them
over the transmitter's own two-wire bus, which on this board goes to fabric
pins rather than to the processor.

It is fabric and not software, so a picture needs no program, no face and no
boot. That keeps the promise this document opens with, which is that the
screens reach the connector with no software in the path.

The program is written once out of the fabric's reset and again whenever the
display wakes from sleep, and it takes about ten milliseconds at the hundred
kilohertz the bus is driven at. A byte the part does not acknowledge stops the
program, is reported, and leaves the bus released with a stop, because a
half-configured transmitter reporting success is worse than one that says it
failed.

**The register program is not derived here.** The data sheet in the board's
resource package is the short form: it gives the part's pins, its electrical
limits and its bus timing, and it does not give the register map. The register
map is in a programming guide that is not in the package. So the program is
the board vendor's own initialization of the transmitter on this board, taken
whole and in its own order from the resource package's HDMI demonstration,
cited in the module's header by path and digest as the pin file cites the same
package for its pins. Nothing is dropped and nothing is reordered, because
both would be claims that the document which could settle them does not exist
here. Three of its entries carry this design rather than the part's defaults:
the input is 4:4:4 with separate syncs, the input is twenty-four bits wide,
and there is no clock delay.

The two-wire bus is driven at a quarter of the four hundred kilohertz the data
sheet allows, and every interval the sheet bounds is a whole quarter of a bit
period, which is four times the margin the slowest of them asks for. The
module refuses at elaboration a clock or a bus speed that would break any of
the six. A stretched clock is waited for rather than talked over.

### The transmitter's own ceiling

The fabric hands the ADV7513 one pixel a clock on a parallel bus and the part
does the serializing, so what bounds the pixel clock here is the part rather
than a lane rate. The data sheet in the board's resource package --- Rev. B,
page 3 of 12, Table 1 under AC SPECIFICATIONS --- sets the **Input Video Clock
Frequency at 165 MHz maximum** and the TMDS Output Clock Frequency at 20 to
165 MHz. 108 MHz is inside that.

**That ceiling is written down in two places and neither is the same check.**
`boards/de25-nano/quartus/build.sh` refuses a pixel clock the specification
asks for above 165 MHz, before anything is built.
`boards/de25-nano/quartus/sta_check.tcl` refuses a pixel clock the generator
actually MADE above it, after the fit. A PLL asked for 108 and landing
somewhere else would pass the first and fail the second, which is why both are
there.

**What it asks of the shared memory port** is 13.37 MB/s with both screens
shown: each picture is read exactly once a frame, so at 59.92 Hz the first
display's 92,448 bytes are 5.54 MB/s and the color screen's 130,752 are 7.83.
The FPGA-to-SDRAM bridge is 64 bits at the fabric clock, so this is under 1.7
per cent of it, and nothing the arbiter has to think about. The deadline is a
raster line, 1688 pixels at 107.8 MHz, which is 15.66 microseconds; a color
band is eight raster lines, 125.3 microseconds. Both are more than an order of
magnitude longer than the fetch they have to cover.

**And if the port could not keep up, the failure would be a line of black and a
sticky bit rather than a monitor that never syncs.** The raster runs off its own
clock whatever memory does; a bank the raster reaches before its words shows
black and raises `underrun`, which the console reports.

### The pixel clock, and the video bus

The pixel clock is a second I/O PLL off the board's 50 MHz, separate from the
machine's, because no counter chain of that reference gives both the tick and
a pixel clock. That is the same arithmetic that gives the Arty Z7-20 two clock
managers. The flow asks the generator for the mode's frequency and the timing
analyzer is asked afterwards what it actually made, so a PLL generated from a
mistyped parameter is a refusal rather than a picture nobody can explain.

**The video is launched on the rising edge of that clock and the same clock is
forwarded to the part.** The data sheet gives the setup and hold the part's
video inputs need, 1.8 ns and 1.3 ns, and does not say which edge of its clock
it samples on; the programming guide that would is not available. So the
arrangement is not derived here either. It is the one the board vendor's own
demonstration uses on this board, whose video generator registers every output
on the rising edge of the PLL output it forwards, with the same clock-delay
value written. Inventing a half-period shift instead would have been a theory
about an edge no document names.

`boards/de25-nano/quartus/cadr_hdmi.sdc` declares the forwarded clock on the
pin and constrains the twenty-seven video pins against it with the part's own
setup and hold. **The board's trace skew between the clock and the data is not
included, because it is not known**: the resource package carries no schematic
and the manual gives no trace lengths. So that is a bound this design meets
rather than a bound the board meets, and which of the two it is matters more
than the number.

### A retired second mode

This board was once built for 1920 by 1080 at 60 Hz as well, a second mode
beside the one above. A monitor showed it working, once. The build closed
timing with **nine picoseconds** of margin on its worst path, from `vid_d[2]`
to `hdmi_d[2]` --- the video bus leaving the part, not the machine and not the
raster, the same family of path as the current mode's.

That build is not carried today. A video mode is a pixel clock, and the
dividers that make one are fixed in the bitstream, so a second mode was never
a setting a card could choose: it was a second bitstream, with its own margin
to keep current every time anything moved. The project kept the one mode
above instead.

### Sleep

A source puts a monitor to sleep by stopping the link. On the Arty Z7-20 the
fabric makes the link, so it stops it by holding all four lanes at one word.
Here the lanes are the transmitter's, so what this fabric can stop is the
clock it hands the part, which stops the link at one remove and is the same
act.

Everything in front of the gate keeps running, as it does there: the pixel
clock inside the fabric, the raster, the fetch and both buffers. So a monitor
that wakes locks onto a picture that never stopped. The gate takes its enable
while the forwarded clock is low, so the part is never handed a fragment of a
period, and the mute still moves only at a frame boundary, so the link stops
and starts in the blanking.

The transmitter's registers are written again at every wake. Its input clock
went away and came back, and whether it relocks by itself is not established
by any document available here; writing the program again costs ten
milliseconds and removes the question. That is the reason, and it is not a
measurement.

**A monitor has since gone into standby and come back on this board**, so the
sleep and the wake work as they are built, with the program written a second
time. Whether the part would relock without that second program is still not
known, and nothing here asks it to.

### What it costs on this board

The whole memory board with the display in it, through
`boards/de25-nano/quartus/build.sh`, at the commit this section was written
and at the commit before it, so that the two are one comparison:

| | with this placement | the commit before |
|---|---|---|
| logic | **16,268 ALMs** of 46,800, 35 per cent | 16,306, 35 per cent |
| block memory | **135 M20K blocks** of 358, 38 per cent | 135, 38 per cent |
| registers | 13,871 | 13,871 |
| worst setup slack | **+2.346 ns**, over every operating condition the part has | +2.339 ns |
| worst hold slack | +0.000 ns | +0.000 ns |
| pixel clock | 108.0030 MHz, where the mode asks 108 | the same |

So the placement costs 38 ALMs less than nothing here, the same memory and the
same registers, and the setup slack moves by 7 picoseconds.

Against the same board without the display, measured at an earlier commit,
15,028 ALMs and 129 M20K blocks, the display costs about **1,000 ALMs and 6
M20K blocks**. The Arty Z7-20's own display costs about 2,200 lookup tables,
3,800 registers and three and a half block RAM tiles there; the two are not
the same unit and are not comparable directly.

**The hold figure is the video bus, and it is zero.** The worst hold path at
the fast corner is a video data register to its pin, with the arrival and the
requirement equal to the picosecond: it is the transmitter's own 1.3 ns hold
requirement binding exactly. **The board's trace skew between the clock and
the data is not in that number**, because no schematic gives it, so this is a
bound the design meets rather than one the board is shown to meet. A board
whose clock trace is shorter than its data traces would spend margin that is
already zero. It is a thing to measure the first time a monitor is attached.

### What holds it, and what nothing holds

`build/display_out.pass` and `build/display_sleep.pass` hold the raster, the
fetch, the compositor, both rotations and the sleep, and they are the same
checks the Arty Z7-20 runs, because it is the same module.
`build/adv7513.pass` holds what leaves the two-wire pins: a decoder recovers
the starts, the stops, every bit and every acknowledge from the levels of the
two lines, never from a signal inside the module, and compares the byte stream
with its own second transcription of the program. It measures the six
intervals the data sheet bounds and prints the worst of each, and drives a
stretched clock. It refuses the address, the register and the value byte of
one write in turn, and each refusal must stop the program at that byte with
the write uncounted. It requires that neither line moves once the program is
through. `build/de25.pass` lints the board with the display in it as a fourth
configuration, which is what catches a pin brought out and not connected. It
then simulates the board's top level around shells of the processor and the
machine, which holds the wiring lint cannot see: the syncs, the order of the
three channels on the video bus, the gate on the forwarded pixel clock, and
the transmitter written out of reset and at a wake but never at a sleep.
`build/display_share.pass` runs the display behind the DE25-Nano's share of
the memory port against a memory with a pipelined round trip, and requires
every picture, upright and rotated, to keep up.

**These registers do make an ADV7513 transmit, and that was shown rather than
argued.** The register map is in a document that is not available and the
program is the board maker's own, taken whole and cited by digest, so until a
monitor was attached nothing held that it worked at all. One now has been. The
same monitor on the same cable reported no signal while the part was
unconfigured, and a picture after the fabric was loaded; the control was taken
before anyone knew the answer. That part transmits nothing until its registers
are written, so a monitor that synchronizes is the evidence the program
reached it.

**The picture has been described, and a person has typed into it.** The
monitor shows the machine's own 768 by 963 screen in a 1280 by 1024 raster,
white on black, with a black border rather than a picture filling the screen,
and it is the same picture the Arty Z7-20 shows. That reading was taken on a
build that centered the first display, with a border 256 columns wide on each
side, and the first display is at the raster's left edge now. The monitor's
own menu reports the mode the bitstream sends. And what is typed at a USB
keyboard plugged into the board appears on that monitor, which ties the
pixels at the connector to the machine's own memory: the key reaches the I/O
board's keyboard register, the machine paints its frame buffer, this block
scans that memory, and the transmitter sends it. A recognized picture might
be a stale frame or a coincidence of geometry; a character that appears when
a key is pressed and at no other time cannot be.

**What is still not established is what leaves the connector, read from the
board.** Nothing on the board can read that, and five signals that would say
whether the program was acknowledged byte by byte, and whether the display is
being starved, reach no register on any board here. A starved display painting
a screen that does not change looks exactly like one that is fed. So a picture
is still the whole of the evidence that this block is being fed correctly, and
what the last session adds to it is an eye rather than an instrument.
`docs/board.md` carries both sessions and what they did not settle.

**And the question about the pin is answered in practice, not in theory.** The
pixel clock's pin is in a bank whose single-ended standards run from 1.0 V to
1.2 V, so the pin file gives it 1.1 V and Quartus refuses 3.3 V there. The
ADV7513's data sheet asks at least 1.35 V of its video inputs. The board
maker's own demonstration drives that pin the same way at a higher pixel
clock, and there is no schematic in the package to explain how the two meet.
The link works at 108 MHz, which settles that it can be driven this way and
settles nothing about why. `boards/de25-nano/README.md` records it.

## What is not built

Nothing reads the hot-plug detect, so the block sends its raster whether a
monitor is attached or not.

Nothing reads EDID, so the mode is fixed and is not negotiated. A monitor that
does not do the bitstream's mode shows nothing.

`MODE BOW` is a parameter and not a wire. The machine can set that bit and the
display output will not follow it. Making it follow would be one output on
`rtl/machine/cadr_tv.sv` and one wire, and it is left undone because
`rtl/machine/` is held to muir and neither reference program ever writes the
register.

The machine cannot turn the output off, and nor can Linux except by the sleep
timer above. The connector's CEC pin is wired on this board and could tell a
television to stand by. That is not built.

**The rotations, the output selection and the second display board have not
been seen on the DE25-Nano.** Every one of them is built and checked, and no
monitor has shown a turned picture or a color screen on that board.

## Looking at it

`docs/board.md` has the procedure.
