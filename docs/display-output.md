<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The display output

The CADR's screen, scanned out of DDR by the fabric and driven onto the board's
HDMI connector, with no software in the path.

The display block writes nothing and reads nothing of the machine's. It takes
the bitmap out of the display's own region of DDR over `S_AXI_HP3`, turns it
into a raster at a monitor's rate, encodes that as DVI and serialises it onto
four differential pairs. The machine cannot detect its presence. A board built
without it is the same machine.

This document is the design, written before the RTL. Every figure in it was
measured on this machine unless it says otherwise, and the measurement is named
beside it.

## What it is driving, and what it is driving it from

The picture is `rtl/machine/cadr_tv.sv`'s frame buffer. That is 768 pixels
across and 963 lines, one bit a pixel, 24 words to a line, at `0x1C00_0000` in
DDR. Those are muir's `simpletv::WIDTH`, `HEIGHT` and `WORDS_PER_LINE` and
`cadr_ddr_map::DISPLAY_BASE`.

Bit 0 of a word is the leftmost of the 32 pixels that word carries. A lit bit
shows white unless `MODE BOW` is set. Both rules are muir's
`SimpleTv::pixel` and `SimpleTv::shows_white`, and both are already written out
in `screen_geom.h`, which is the remote viewer's copy of the same facts. This
block is the third expression of them.

`rtl/machine/cadr_tv.sv` does not change. It is held to muir tick for tick, it
has no raster, and its vertical flag runs on its own frame clock. Nothing here
touches it.

## 1. The video mode

### What has to hold

The picture is 963 lines high. That rules out every common mode below
1280x1024: 1024x768 and 1280x960 are both too short, and 1152x864 is shorter
still. Scaling is not considered. A one-bit picture scaled by anything other
than a whole number turns single-pixel strokes into grey, and the CADR's
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

**VESA DMT 1280x1024 at 60 Hz.** Its pixel clock is 108 MHz and its lane rate
is 1.08 Gb/s, which is inside the 1.2 Gb/s the part will do, with about ten per
cent to spare.

CVT reduced blanking was the alternative and is not needed. It would have run
at about 90.75 MHz, and the only argument for it was that its serial clock
would have fitted on a global clock buffer. That turns out not to be a reason
to give up the mode every monitor accepts. See the clocks below.

The timings are VESA's.

| | Active | Front porch | Sync | Back porch | Total |
|---|---|---|---|---|---|
| Horizontal | 1280 | 48 | 112 | 248 | 1688 |
| Vertical | 1024 | 1 | 3 | 38 | 1066 |

Both syncs are positive. A monitor reads the pair of polarities as part of how
it identifies the mode, so they are not free.

The board builds this at 107.8125 MHz rather than 108. An MMCM multiplies the
board's 125 MHz by a multiple of one eighth, and no such multiple gives 108
exactly. The nearest that keeps the arithmetic simple multiplies by 8.625 for a
VCO of 1078.125 MHz, which divides by two to 539.0625 MHz and by ten to
107.8125 MHz. That is 0.17 per cent low, and the frame arrives at 59.90 Hz
instead of 60.02. Monitors accept far more than that.

### How the picture sits in the raster

Centred, with the rest black.

The picture is 768 wide in 1280, so there are 256 columns of border on each
side. It is 963 high in 1024, so there are 61 rows of border: 30 above and 31
below, the odd row going to the bottom.

The border is black whatever `MODE BOW` says. The border is not the CADR's
screen at all, so it does not follow a bit that decides how the CADR's own
zeros are shown.

## 2. The clocks

The pixel clock and its serialiser clock come from an MMCM of their own, off
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
serialisers could not have shared one regional clock and this would be a
different design. A board that moves those pins has to check this again.

The pixel clock stays on a `BUFG`, because the raster, the line buffer's read
side and the encoders are ordinary fabric and have to be reachable from
anywhere on the die. So a serialiser sees its two clocks over different
networks. That is the one thing in the block the fitter has to be asked about
rather than assumed, and the answer is in the fit report quoted above: it
closes.

### How the two domains meet

The memory side runs on the machine's 100 MHz. The raster runs on the pixel
clock. They are unrelated and nothing tries to relate them.

They meet at the line buffer. There are two buffers of 24 words. The raster
reads one while the memory side fills the other, and they change places at the
first pixel of every raster line.

The handshake is one toggle each way. The raster sets the line number it wants
and flips a request toggle on the same pixel-clock edge. The memory side sees
that flip two of its own clock edges later at the earliest, by which time the
number has been stable for two clocks and will stay stable for the rest of the
line. A line is 1688 pixel clocks. So the number is settled long before
anything reads it, and only the toggle needs synchronising. Coming back, an
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
Each pixel byte is turned into ten bits in two stages: the first minimises
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
nothing here changes its behaviour depending on that, so reading it would be a
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
| `rtl/plumbing/cadr_display_out.sv` | the AXI master, the line buffer and the raster | `build/display_out.pass` |
| `rtl/plumbing/cadr_hdmi_tx.sv` | the three channels and the clock channel | `build/hdmi_tx.pass` |
| `rtl/plumbing/cadr_tmds_encode.sv` | one channel's 8b/10b encoder | `build/hdmi_tx.pass` |
| `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv` | the MMCM, the serialisers, the output buffers | lint and the fitter only |
| `boards/arty-z7-20/cadr_arty.xdc` | the eight pins, on every board | the fitter |
| `rtl/plumbing/xilinx7/cadr_hdmi.xdc` | the clock groups, only when it is built | the fitter |
| `tb/cadr_arty_stubs.sv` | `OSERDESE2`, `OBUFDS`, `BUFIO` as empty shells | nothing; it models nothing |

The split is not the obvious one and the reason is checkability. Putting the
encoder in the same file as the serialiser primitives would have made the
encoder unsimulable, because a check on that file would have to be built
against stubs, and a check built against a stub confirms rather than compares.
So everything that can be plain SystemVerilog is, and the Xilinx-specific file
is four primitives and a clock with no logic in it at all.

### `display_out`

It found three faults in the first draft, and all three would have been
invisible against a memory of zeros.

The 4 KB crossing is described above. The second was a synchroniser that came
out of reset holding zero while the signal it synchronised came out of reset
holding one, so the first line's readiness test was true for the two or three
clocks before the real value arrived, the first line took a bank nothing had
filled, and every bank after it was one out. The whole picture was drawn one
line early, for ever. The third was the line buffer's index: the bank and the
word are concatenated, so the bank stride is 32 and not 24, and an array sized
at two times 24 put the second bank's last eight words off the end of it. The
right-hand third of every other line came out black.

None of the three is the kind of thing that is found by reading.

`tb/cadr_display_out_tb.cpp` runs `cadr_display_out` with two clocks at their
real and mutually irrational periods, against a modelled DDR poisoned
injectively in the address, and behaves like a monitor: it recovers the raster
position from the sync and data-enable outputs rather than from any internal
counter, so the module's pipeline depth is not something the check has to know.

It holds:

- every pixel inside the picture against the bit of the modelled memory it
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
- the line buffer handoff, by running the memory side slow enough to lose the
  race and requiring that the underrun is reported and the line goes black
  rather than showing the wrong words.

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

**It does not hold the serialiser, and nothing does.** `OSERDESE2` and
`OBUFDS` are stubbed in `tb/` so that the top level lints, and the stubs tie
their outputs low. A simulation built on them would show a dark connector
whatever the encoder did. What stands behind the serialiser is the fitter and,
in the end, a monitor. A monitor has now been put on the connector and shows
the machine's screen as built: 1280x1024 with the CADR's 768x963 centred in it,
white on black. `docs/board.md` has that reading.

### `arty`

`build/arty.pass` gains a sixth board configuration, `HDMI=1` with `DDR=1`,
which lints the whole top level with the display output in it. That is what
catches a pin that is brought out and not connected.

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

That is the same failure CLAUDE.md records against `cadr_machine.xdc`'s
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

There is no way to turn the output off from the machine or from Linux.

## Looking at it

`docs/board.md` has the procedure.
