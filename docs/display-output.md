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

`--hdmi-output tv|color-tv|both` names the screens. Whatever is shown is
centered on the active area at 1:1 with the rest black, and **where both overlap
the color screen is drawn over the first**. Centered and not side by side,
because the two are two views of one machine rather than a desktop, and because
768 + 576 is 1344, which the narrowest mode's 1280 does not hold. Centered, the
color screen falls wholly inside the first, so the overlap is the whole of it.

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

### What has to hold

The picture is 963 lines high. That rules out every common mode below
1280x1024: 1024x768 and 1280x960 are both too short, and 1152x864 is shorter
still. Scaling is not considered. A one-bit picture scaled by anything other
than a whole number turns single-pixel strokes into gray, and the CADR's
screen is single-pixel strokes almost everywhere.

So the smallest standard mode that holds 768x963 unscaled is **1280x1024**.

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
1.2 Gb/s. The MMCM is not the binding limit: its VCO range on this grade is
600 to 1200 MHz and its outputs go to 800 MHz, both read out of the clocking
wizard's own validation messages against this part.

### The decision

**Three modes, one a bitstream**, and the default is the one the board has run.

| mode | pixel clock | a lane's bit rate | syncs |
|---|---|---|---|
| VESA DMT 1280x1024 at 60 Hz | 108 MHz | 1.08 Gb/s | H+ V+ |
| CVT reduced blanking 1400x1050 at 60 Hz | 101 MHz | 1.01 Gb/s | H+ V- |
| CEA-861 VIC 34, 1920x1080 at 30 Hz | 74.25 MHz | 0.74 Gb/s | H+ V+ |

All three are inside the 1.2 Gb/s a lane the part will do. The two that are not
offered are ruled out by the same figure: 1400x1050 with NORMAL blanking is
1.22 Gb/s and 1920x1080 at 60 Hz is 1.485. 1280x720 holds neither orientation of
a 768 by 963 screen and is not offered either.

Reduced blanking is accepted by flat-panel monitors and not by televisions;
30 Hz is accepted by televisions and not by every PC monitor. That is why both
are there.

The timings are the specifications':

| | Active | Front | Sync | Back | Total |
|---|---|---|---|---|---|
| 1280x1024 H | 1280 | 48 | 112 | 248 | 1688 |
| 1280x1024 V | 1024 | 1 | 3 | 38 | 1066 |
| 1400x1050 H | 1400 | 48 | 32 | 80 | 1560 |
| 1400x1050 V | 1050 | 3 | 4 | 23 | 1080 |
| 1920x1080 H | 1920 | 88 | 44 | 148 | 2200 |
| 1920x1080 V | 1080 | 4 | 5 | 36 | 1125 |

The middle one is CVT reduced blanking's own arithmetic rather than a table
lookup: reduced blanking fixes the horizontal blanking at 160 pixels whatever
the width, which gives 1560; its minimum vertical blanking is 460 microseconds,
which at 1560/101 MHz = 15.446 microseconds a line is 29.8 lines and rounds up
to 30, which gives 1080; and 1560 x 1080 x 60 is 101.088 MHz, which CVT rounds
down to the quarter megahertz at 101.00. **Its VSYNC is negative and its HSYNC
positive**, and that pair is how a sink tells reduced blanking from an ordinary
mode of the same size, so it is not free. The last is CEA-861's VIC 34, whose
2200 x 1125 x 30 is 74.25 MHz exactly.

**THE FIGURES LIVE IN ONE PLACE**, `rtl/plumbing/cadr_display_out.sv`'s own
parameter table, and the board passes a column number and nothing else.
`tb/cadr_display_out_tb.cpp` carries a second transcription of the same three
specifications and compares against it, so the two are two descriptions and can
disagree.

### Why the mode is a parameter and not a setting

This was measured before it was built. The answer then was that changing it at
run time is closed to this project, and that answer was wrong: it is open, and
it is simply not built. What follows says why the mode is still a build here,
and what building the other thing would take.

A video mode is a pixel clock; the pixel clock and its serializer clock come
from an MMCM; and an MMCM's dividers are fixed in the bitstream. Moving them at
run time means writing its reconfiguration port --- which needs `MMCME2_ADV`
rather than `MMCME2_BASE`, and that part is present in the unisim library and
costs no license feature.

**The data is not the blocker, and an earlier reading of this said it was.**
Rewriting an MMCM's multiplier and divider also means rewriting its LOCK and
FILTER registers, which are empirical values with no published arithmetic behind
them. Those values are not out of reach. The clocking wizard creates and
generates for this part with no license feature checked out, and asked for
dynamic reconfiguration it emits a core with an AXI4-Lite interface that rewrites
the multiply and divide values at run time. The file declaring the two lookups
is part of what it generates.

So the tables arrive the way the memory controller's files arrive: as generated
output of the vendor's own tool, for our part, which this repository already
carries on that footing and holds current with a checker. The license is not
what stops this.

**And a fixed oscillator cannot serve the three, so it is the multiplier that
would have to move, and not the output dividers alone.** A 10:1 serializer needs the serial clock to be exactly five times the
pixel clock. `CLKOUT0_DIVIDE_F` moves in eighths and `CLKOUT1_DIVIDE` is an
integer, so if the pixel divider is `D` and the serial divider `D/5`, then `D`
must be a multiple of five. One oscillator therefore offers the pixel ratios
1, 2/3, 1/2 and no others --- and the three modes want 1, 0.93 and 0.69.

So the mode is chosen when the bitstream is built, three bitstreams carry the
three, and the console's page 2 word 34 reports which one the fabric is. A card
that names another mode is told which bitstream it wants rather than given a
setting that quietly does nothing.

The MMCM dividers are in `boards/arty-z7-20/cadr_arty.sv` and not in the block,
because they are about the BOARD's 125 MHz crystal rather than about the mode:

| mode | DIVCLK | CLKFBOUT | VCO | pixel | refresh |
|---|---|---|---|---|---|
| 1280x1024 | 1 | 8.625 | 1078.125 MHz | 107.8125 MHz | 59.92 Hz |
| 1400x1050 | 2 | 16.125 | 1007.8125 MHz | 100.78125 MHz | 59.82 Hz |
| 1920x1080 | 2 | 11.875 | 742.1875 MHz | 74.21875 MHz | 29.99 Hz |

No multiple of an eighth gives any of the three exactly. The errors are 0.17,
0.22 and 0.04 per cent, and monitors accept far more than that. **Mode 0's
dividers are unchanged from the board that has run**, which is why it is the one
that divides by one.

### Why three modes are three bitstreams

This is the whole of the mode's cost, and it is worth setting out rather than
asserting, because it is the one place where a decision was made for us.

**The serializer ties the two clocks together.** Ten bits leave a serializer for
every pixel and a serializer clocked on both edges moves two bits a period, so
the serial clock is exactly five times the pixel clock. Both come from one clock
manager, so if the pixel output divides the oscillator by `D` and the serial
output by `d`, then `D` is five times `d`. The serial divider moves in eighths
and the pixel divider is a whole number, so `D` is a whole multiple of five.

**One oscillator therefore reaches very few pixel clocks.** It reaches its own
frequency over 5, 10, 15, 20 and so on, which as ratios between modes is 1, 2/3,
1/2, 2/5. The three modes want 108, 101 and 74.25 MHz, whose ratios are 1.0693
and 1.4545, and neither is among them.

Ask what oscillator would serve the first two together. The dividers would have
to be in the ratio 101 to 108, and both must be multiples of five, so the
smallest pair is 505 and 540. An oscillator of 108 MHz times 540 is 58.3 GHz.
The clock manager's own range is 600 to 1200 MHz. The question answers itself.

**Two clock managers and a switch do not rescue it.** The pixel clock could be
switched, because the buffer that carries it has a glitch-free select. The
serial clock cannot: it rides a regional buffer, which has no select at all, and
the global buffer that does have one will not take a period shorter than
2.155 ns on this speed grade --- 464 MHz, measured from the tool's own speed
file and recorded in section 1. The three serial clocks are 539, 504 and
371 MHz, so the fastest two are beyond it. A switch that works for one mode and
not the others is not a switch.

### Why the clock manager is the constraint, and where it stops

A clock cannot be made in fabric logic. It has to come from the part's own clock
manager, and that manager's multiplier is fixed when the bitstream loads.

Changing it while the design runs is possible in principle: the manager has a
reconfiguration port, and the primitive that exposes it is in the tool's own
library and costs no license feature. That is not where this stops.

It stops at the work, and not at the data or the license.

The vendor's procedure for reprogramming the multiplier writes two further
registers whose values come from empirical tables. Those tables are generated
output: the clocking wizard writes the file that declares
`mmcm_pll_lock_lookup` and `mmcm_pll_filter_lookup`, for this part, with no
license feature checked out, and the template that calls them with the
multiplier is beside it. In a 2026.1 install the two are
`data/ip/xilinx/clk_wiz_v6_0/mmcm_pll_drp_func_7s_mmcm.vh` and
`data/ip/xilinx/clk_wiz_v6_0/ttcl/mmcm_pll_drp_v.ttcl`. A repository that
already carries a generated memory controller can carry them the same way.

So the mode is a build here because nobody has built the other thing, and the
next section says what that is. An earlier version of this document said the
mode could not be a setting because the tables were closed to us. That was
wrong and is withdrawn.

### What would make run-time switching possible

It is possible, and it is not built. This is what building it would take.

**Reprogramming one clock manager is not the same as switching between two, and
that is what makes it reachable.** The section above rules out a switch, because
the serial clock rides a regional buffer with no glitch-free select and the
global buffer that has one will not take 539 MHz. Reprogramming leaves the
buffer where it is: one manager, one source, new dividers. The objection to the
switch is not an objection to this.

Four pieces, none of them measured on a board:

1. `MMCME2_ADV` in place of `MMCME2_BASE`, which is the same primitive with the
   reconfiguration port brought out, and costs no license feature.
2. A writer for that port, with the two lookup tables beside it, vendored as
   generated output for this part and held current by a checker, as the memory
   controller's files are.
3. The raster's own widths and margins become registers rather than a build
   parameter. Today `HDMI_MODE` reaches them at elaboration, and a mode that
   moves at run time needs them to move with it.
4. A blank interval around the change. A manager stops its outputs while it
   relocks, so the link goes down and the serializers are reset and restarted
   behind it. A monitor sees a mode change, which is what it is.

**What does not change.** The serializer's 600 MHz and the global buffer's
464 MHz stand: they are measured, and section 1 has them. The three modes still
want three different oscillator frequencies, which is why one bitstream carries
one mode today.

**And the vendor's own HDMI transmitter is not the way round this.** That
subsystem is refused for this part outright and asks for license keys besides,
so it is not an alternative to any of the above.

### How the picture sits in the raster

Centered, with the rest black, and each picture centered on its own.

Upright in 1280x1024 the first display is 768 wide in 1280, so 256 columns of
border each side, and 963 high in 1024, so 61 rows: 30 above and 31 below, the
odd row going to the bottom. The color screen is 576 by 454 in the same raster,
so it falls wholly inside the first and the overlap is the whole of it.

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

Rotated, the pictures are 963 by 768 and 454 by 576, and both fit every one of
the three modes at 1:1.

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
counts step together because there is exactly one request per line and one fill
per request. A signal saying which bank is in use would be a second description
of something both sides already know, and two descriptions of one fact is how
they come to disagree.

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
15,456,000 ns of the machine's time, which on this board's 10 ns tick arrives
every 30.912 real milliseconds, or 32.35 Hz. The monitor runs at 59.90 Hz.
Neither number constrains the other, and the vertical flag the machine reads is
the display block's, not this block's VSYNC.

## 3. The memory read

A burst-reading AXI3 master on `S_AXI_HP3` fetches one line at a time into the
line buffer, ahead of the raster.

A line is 24 words of 32 bits, which is 96 bytes, which is twelve beats of the
64-bit port. Every line starts 96 bytes after the one before it, and 96 is a
multiple of eight, so every line starts on a beat boundary. AXI3 caps a burst
at sixteen beats, so twelve fits with room to spare.

**But twelve beats is not always one burst, because 96 bytes does not tile
4 KB.** AXI forbids a burst crossing a 4 KB boundary, and 4096 is not a
multiple of 96. The two have a common multiple at 12,288 bytes, which is three
pages and 128 lines, so the pattern of line starts repeats every 128 lines and
exactly two of each 128 begin close enough to a boundary that twelve beats
would run over it. Over the picture's 963 lines that is **15 lines**, the first
at line 42.

So a fetch is one burst where it fits and two where it does not, split exactly
at the boundary, and the line buffer is filled by a word pointer that runs
across the whole line rather than by a beat index inside a burst.

This was not foreseen. The first draft issued one burst of twelve every time,
and the check caught it on the first frame the module ever drew, on exactly
those 15 lines. The testbench recomputes every burst's permitted length
independently, asserts that no burst crosses a boundary, and counts the lines
that take two — so the second burst cannot quietly become dead code.

**Exactly one request per raster line, always, including the lines that show
nothing.** The raster asks at the first pixel of every one of the mode's 1066
lines, clamping the line number into the picture's 963 when it is outside, and
throws the answer away for the 103 that are border or blanking. That costs 103
bursts a frame and it buys an invariant worth more than they cost: the memory
side has no idea where the raster is, does the same thing every line, and can
be checked against "one burst a line, at the address the line number says". A
fetcher that knew about the vertical blanking would have a second mode that
runs 103 times a frame, which is the kind of thing that stays wrong for a year.

### The bandwidth

1066 bursts of 96 bytes, 59.90 times a second, is 6.13 MB/s. Of that, 5.54
MB/s is picture and the rest is the clamped lines.

The port is 64 bits at 100 MHz, which is 800 MB/s. So the display uses 0.77 per
cent of it. The DDR3 behind it runs at 1050 MB/s per 32-bit transfer at this
board's clock and is shared four ways. There is no bandwidth question here and
the arithmetic is written down only so that nobody has to wonder.

### The arbitration

`S_AXI_HP2` and `S_AXI_HP3` are multiplexed down to one DDR controller port,
and `S_AXI_HP0` and `S_AXI_HP1` to another. So the display shares a controller
port with the disk, and neither shares one with the machine's memory bridge on
HP0. That was the reason the disk moved from HP1 to HP2 in the first place, and
it keeps holding: the machine's own memory path is the one seam at machine
speed and nothing else arbitrates against it.

The disk's traffic is bursty, in blocks of 1024 bytes, and idle for long
stretches. The display's is a steady 96 bytes every 15.7 microseconds. The
display can be made to wait a long time without anything going wrong, because
it is a whole line ahead of the raster; the disk cannot be starved by 6 MB/s.

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
| `rtl/plumbing/cadr_display_out.sv` | the AXI master, the buffers, the raster, the compositor and the map | `build/display_out.pass` |
| `rtl/plumbing/cadr_hdmi_tx.sv` | the three channels and the clock channel | `build/hdmi_tx.pass` |
| `rtl/plumbing/cadr_tmds_encode.sv` | one channel's 8b/10b encoder | `build/hdmi_tx.pass` |
| `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv` | the MMCM, the serializers, the output buffers | lint and the fitter only |
| `boards/arty-z7-20/cadr_arty.xdc` | the eight pins, on every board | the fitter |
| `rtl/plumbing/xilinx7/cadr_hdmi.xdc` | the clock groups, only when it is built | the fitter |
| `tb/cadr_arty_stubs.sv` | `OSERDESE2`, `OBUFDS`, `BUFIO` as empty shells | nothing; it models nothing |

The split is not the obvious one and the reason is checkability. Putting the
encoder in the same file as the serializer primitives would have made the
encoder unsimulable, because a check on that file would have to be built
against stubs, and a check built against a stub confirms rather than compares.
So everything that can be plain SystemVerilog is, and the Xilinx-specific file
is four primitives and a clock with no logic in it at all.

### `display_out`

**IT IS BUILT THREE TIMES, ONE A MODE**, because the mode is a parameter: the
raster's widths, the two margins that center each picture and one sync polarity
are all elaboration-time constants, so a check that ran one of them would hold
the code and say nothing about the other two columns of the table. The testbench
takes the mode as its argument and carries its own transcription of the three
specifications.

It found three faults in the first draft, and all three would have been
invisible against a memory of zeros.

The 4 KB crossing is described above. The second was a synchronizer that came
out of reset holding zero while the signal it synchronized came out of reset
holding one, so the first line's readiness test was true for the two or three
clocks before the real value arrived, the first line took a bank nothing had
filled, and every bank after it was one out. The whole picture was drawn one
line early, for ever. The third was the line buffer's index: the bank and the
word are concatenated, so the bank stride is 32 and not 24, and an array sized
at two times 24 put the second bank's last eight words off the end of it. The
right-hand third of every other line came out black.

None of the three is the kind of thing that is found by reading.

`tb/cadr_display_out_tb.cpp` runs `cadr_display_out` with two clocks at their
real and mutually irrational periods, against a modeled DDR poisoned
injectively in the address, and behaves like a monitor: it recovers the raster
position from the sync and data-enable outputs rather than from any internal
counter, so the module's pipeline depth is not something the check has to know.

It holds:

- every pixel inside the picture against the bit of the modeled memory it
  comes from, over a whole frame;
- every pixel outside the picture and inside the active region black;
- the data-enable and both syncs against the mode's own figures, counted
  rather than sampled: 1280 enabled pixels on each of 1024 lines, 1688 pixels
  and 1066 lines to a frame, sync pulses of 112 and 3 at the right offsets and
  the right polarity;
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
- both screens at once, with the color one over the first where they overlap;
- both quarter turns, by the same pictures read the other way: an output line
  against the source column it is, and the band fetch's own walk --- every read
  a source line apart until the band is done, and no more reads in flight than
  the master may hold;
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
- a long pseudorandom stream of pixels and blanking, compared every cycle.

**It does not hold the serializer, and nothing does.** `OSERDESE2` and
`OBUFDS` are stubbed in `tb/` so that the top level lints, and the stubs tie
their outputs low. A simulation built on them would show a dark connector
whatever the encoder did. What stands behind the serializer is the fitter and,
in the end, a monitor. A monitor has now been put on the connector and shows
the machine's screen as built: 1280x1024 with the CADR's 768x963 centered in it,
white on black. `docs/board.md` has that reading.

### `arty`

`build/arty.pass` gains a sixth board configuration, `HDMI=1` with `DDR=1`,
which lints the whole top level with the display output in it. That is what
catches a pin that is brought out and not connected.

## The settings

Two of the three are settings and one is a build.

| | where | what |
|---|---|---|
| `--hdmi-output tv\|color-tv\|both` | `fpgarc`, console word 34 | which screens |
| `--hdmi-rotate 0\|90\|-90` | `fpgarc`, console word 34 | which way up |
| `--hdmi-mode ...` | `HDMI_MODE` at build; the card's line only ASKS | which mode |

The two settings are written into the console's page 2 word 34 by
`S80cadr-disk-packs` before the drive is presented, exactly as `--tv-board` and
`--color-tv` are written into word 33, and `cadr-console hdmi-output`,
`hdmi-rotate` and `hdmi-mode` reach them at run time. `docs/console.md` has the
word and `docs/fpgarc.md` the flags.

**A card that names a mode the bitstream does not carry gets a line saying which
bitstream it wants.** It is not a setting that quietly does nothing, which is
what a word that accepted the key and changed nothing would be.

## What it costs, and whether it is being timed

Built at the commit this document arrived at, `DDR=1 HDMI=1` — the machine
running out of real memory with the display beside it — through
`boards/arty-z7-20/vivado/bitstream.tcl`:

| | |
|---|---|
| worst setup slack | **+0.255 ns**, 0 failing of 52,355 endpoints |
| worst hold slack | +0.031 ns, 0 failing |
| worst pulse width slack | +0.188 ns, 0 failing of 13,831 |
| Slice LUTs | 13,079 |
| registers | 11,189 |
| block RAM tiles | 45 |
| bitstream | 4,045,764 bytes, 0 errors |

Against the same board without the display, measured at `95cbb84` —
10,909 LUTs, 7,390 registers, 41.5 block RAM tiles — the display costs about
2,200 LUTs, 3,800 registers and three and a half block RAM tiles. Do not read
the slack's last digits as precision: a bit-identical netlist has moved that
number by a quarter of a nanosecond in this project before.

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
it is on. The per-clock table says the same from the other side: 292 endpoints
on `pixel_raw` with a worst slack of +1.334 ns, and 52,063 on `clk_raw`.

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

## What is not built

Nothing reads the hot-plug detect, so the block sends its raster whether a
monitor is attached or not.

Nothing reads EDID, so the mode is fixed and is not negotiated. A monitor that
does not do 1280x1024 at 60 Hz shows nothing.

`MODE BOW` is a parameter and not a wire. The machine can set that bit and the
display output will not follow it. Making it follow would be one output on
`rtl/machine/cadr_tv.sv` and one wire, and it is left undone because
`rtl/machine/` is held to muir and neither reference program ever writes the
register.

There is no way to turn the output off from the machine or from Linux, and
nothing sleeps the monitor: a source puts a digital monitor to sleep by stopping
the link, and nothing here stops it. The connector's CEC pin is wired on this
board and would let a television be told to stand by; it is not built either.

**The mode is not a setting**: this bitstream carries one mode and the console
reports which. Making it a setting is possible and is not built; section 1 has
what it would take.

## Looking at it

`docs/board.md` has the procedure.
