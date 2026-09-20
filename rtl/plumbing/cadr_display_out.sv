// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The display output: the CADR's two screens out of DDR and onto a raster.
//
// **NO muir REFERENCE EXISTS AND NONE COULD.**  muir's `tv::Tv` is a frame
// buffer, a mode register and a vertical flag off the sync program; it has no
// raster at all, and `rtl/machine/cadr_tv.sv` is held to it tick for tick and
// does not change.  What this module does --- read the bitmaps at a monitor's
// rate and put pixels on a wire --- is a thing MIT's SIMPLE TV did with a sync
// program, a shift register and an analog video amplifier, into a monitor that
// no longer exists.  So this is held to a SPECIFICATION and to the bitmaps, the
// way `cadr_axi_master.sv` is held to AXI: the raster to VESA's or CEA's own
// figures for the mode, and every pixel to the word in DDR it comes from.
//
// **THIS IS NOT PART OF THE MACHINE AND MUST NOT BECOME PART OF IT.**  It reads
// the display's region of DDR and writes nothing, tells the machine nothing and
// is told nothing by it.  The CADR cannot detect its presence: no cycle of the
// machine's reaches it, both `cadr_tv.sv` instances go on running the board's
// own sync program and presetting their vertical flags where that program's
// `-TVMA CLR` falls, and a board built without this block is the same machine.
// **The frames have nothing to do with each other**: the machine's is the sync
// program's and the monitor's is the video mode's.  That is what lets the raster
// be asynchronous to everything --- see the two clocks below.
//
// ----------------------------------------------------------------------
// THE TWO SCREENS
//
// A CADR carries one display board or two.  The first is 768 by 963 at one bit
// a pixel, 24 words to a line, at `cadr_ddr_map::DISPLAY_BASE`.  The second ---
// the color TV, `lmtv.order`'s "for the color TV, x is 5" --- is 576 by 454 at
// FOUR bits a pixel, 72 words to a line, at `COLOR_DISPLAY_BASE`, and each of
// those four bits is an address into a sixteen-entry map of three eight-bit
// channels.
//
// **THE MAP IS NOT IN THE PICTURE AND IT IS NOT ON THE BUS.**  `lmtv.order`
// gives register 4, the COLOR register, as write only, and says the map RAMs
// and their digital-to-analog converters are OFF the board.  So on a real
// machine nothing on the Xbus can read a color back, and the thing that turns a
// four-bit pixel into three channels is exactly the off-board hardware this
// module stands in for.  `rtl/machine/cadr_tv.sv` keeps the map because the
// picture cannot be drawn without it and offers it on a read port; this module
// takes a COPY of the sixteen entries and does the lookup in the pixel domain,
// where a pixel is.  See "the color map" below for how the copy is kept fresh.
//
// Which screens are shown is `out_sel`, and it is a setting rather than a
// parameter: the card's `fpgarc` names it and the disk pack program writes it
// through the console before the drive is presented, exactly as `--tv-board`
// and `--color-tv` are written.  Bit 0 shows the first display and bit 1 the
// color board, so `01` is the first alone, `10` the color board alone and `11`
// both.
//
// **BOTH SCREENS ARE CENTERED AT 1:1 AND THE COLOR ONE IS DRAWN OVER THE
// FIRST.**  Neither is scaled: a one-bit picture scaled by anything but a whole
// number turns single-pixel strokes into gray, and the CADR's screen is
// single-pixel strokes almost everywhere.  Centered and not side by side,
// because the two pictures are two views of one machine rather than a desktop,
// and because 768 + 576 is 1344, which the narrowest mode's 1280 does not hold.
// Centered, the color screen's 576 by 454 falls wholly inside the first's 768
// by 963, so where they overlap is the whole of the color screen.
//
// ----------------------------------------------------------------------
// ROTATION
//
// `rotate` turns the picture a quarter turn for a monitor stood on its side:
// `01` a quarter turn clockwise, `10` a quarter turn the other way, `00`
// upright.  A CADR screen is 768 by 963 --- TALLER than it is wide --- and every
// monitor made since is wider than it is tall, so upright it wastes the sides
// and a turned monitor holds it with room.
//
// **A ROTATED OUTPUT LINE IS A SOURCE COLUMN, AND THAT IS WHY IT NEEDS A
// DIFFERENT BUFFER.**  Upright, one raster line is one source line: 24
// consecutive words, one burst, and the next line is the next 96 bytes.
// Rotated, one raster line is one source COLUMN: one bit out of each of the
// picture's 963 rows.  The bit's position inside its word is the source column
// modulo 32, so 32 ADJACENT OUTPUT LINES ARE THE 32 BITS OF ONE WORD from each
// row --- and the words those 32 lines need are one word column, 963 words at a
// stride of 96 bytes.
//
// So rotated, the block reads ONE WORD COLUMN into a band buffer and scans that
// buffer once per output line, picking bit k of each word.  The color screen is
// the same with nibbles: 8 pixels to a word, so 8 adjacent output lines are one
// word column of 454 words at a stride of 288 bytes.
//
// **THE PICTURE IS STILL READ EXACTLY ONCE A FRAME.**  The first display is 24
// words wide, so it is 24 word columns of 963 words, which is 23,112 words ---
// the whole picture.  The color screen is 72 word columns of 454, which is
// 32,688, which is `COLOR:MAKE-SCREEN`'s own count.  Rotation costs block RAM
// and costs nothing in bandwidth.
//
// ----------------------------------------------------------------------
// THE TWO CLOCK DOMAINS, AND WHY THERE ARE TWO
//
// The memory side runs on the machine's own 100 MHz, because that is the clock
// `S_AXI_HP0` and `S_AXI_HP2` already run at and the third port has no reason to
// be different.  The raster runs on the pixel clock, which is the monitor's rate
// and is a different number --- 107.8125 MHz for the default mode --- made by an
// MMCM of its own in `rtl/plumbing/xilinx7/cadr_hdmi_phy.sv`.  The two are
// unrelated and nothing tries to relate them.
//
// **THE CADR'S OWN FRAME RATE IS IRRELEVANT HERE, AND THAT IS WORTH SAYING
// BECAUSE IT LOOKS LIKE IT SHOULD NOT BE.**  The display board's frame is
// 15,456,000 ns of the machine's time, which on this board's 10 ns tick and
// 10 ns grid arrives every 15.456 real ms --- 64.70 Hz, the rate the board
// scanned at.  The monitor here runs at 60 Hz, or at 30 in the mode that asks
// for it.  Neither number constrains the other: MIT's TV had the processor and
// the raster reading one memory at whatever rates each ran at, and so does
// this.  The vertical flag the machine reads is `cadr_tv.sv`'s and is not this
// module's VSYNC.
//
// **SO THE PICTURE TEARS, AND TEARING IS THE ORIGINAL BEHAVIOR RATHER THAN A
// DEFECT.**  A line fetched while the machine is drawing shows some words from
// before a write and some from after.  On a one-bit black-and-white screen that
// is a character appearing with its top half drawn, for one frame of 16 ms, and
// it is exactly what the real machine did: the SIMPLE TV scanned the same 4116s
// the processor wrote, with no buffering and no interlock.  Double buffering
// would need a second region, a copy engine and a decision about when to swap,
// and would show the machine's screen LESS faithfully.
//
// ----------------------------------------------------------------------
// HOW THE TWO DOMAINS MEET: THE BUFFERS
//
// One buffer a screen, each of two banks.  The raster reads one bank while the
// memory side fills the other, and they change places when what is being shown
// has to change --- every raster line upright, every 32 (or 8) rotated.
//
// **EACH ENTRY IS A WHOLE 64-BIT BEAT AND NOT A 32-BIT WORD, AND THAT IS WHAT
// MAKES ONE MEMORY SERVE BOTH SHAPES.**  A contiguous fetch brings two words in
// one beat: written as two 32-bit entries that is two writes in one cycle, which
// no block RAM does and which would force the buffer into LUTs.  One 64-bit
// entry a beat is one write, the read picks its half by the low bit of the word
// index, and the strided fetch --- which uses one word of each beat --- writes
// one half at a time, which is a byte-enabled write and is what a block RAM is
// for.
//
//   first display   512 entries a bank: 12 for an upright line of 24 words,
//                   482 for a band of 963.  Two banks of 512 by 64 is
//                   65,536 bits, two RAMB36.
//   color board     256 entries a bank: 36 for an upright line of 72 words,
//                   227 for a band of 454.  Two banks of 256 by 64 is
//                   32,768 bits, one RAMB36.
//
// Upright the two hold 24 and 72 words, which is 96 words a raster line against
// the 24 this block read when it drew one screen.
//
// THE HANDSHAKE IS A TOGGLE EACH WAY PER SCREEN, and the job rides across beside
// it.  The raster sets the address it wants and flips a request toggle on the
// same pixel-clock edge; the memory side sees the flip two of ITS clock edges
// later at the earliest, by which time the address has been stable for two
// clocks and will stay stable for the rest of the line.  So the address is
// settled long before anything looks at it and only the toggle needs
// synchronizing.  Coming back, `ack_tog` is set to the value of the request just
// finished, so `ack == req` means everything asked for has arrived.
//
// **THE BANK IS NEVER CARRIED ACROSS.**  Both sides count requests, one counting
// what it sent and one what it served, and the bank is the low bit of that
// count.  The counts step together because there is exactly one fill per
// request, so a signal saying which bank is in use would be a second description
// of something both sides already know --- and two descriptions of one fact is
// how they come to disagree.
//
// **THE REQUEST IS MADE WHEN WHAT IS WANTED CHANGES, WHICH IS ONCE A LINE
// UPRIGHT AND ONCE A BAND ROTATED.**  The raster computes the byte address it
// will need a fixed number of lines from now --- one line upright, 32 rotated
// for the first display and 8 for the color board --- and asks for it when it
// differs from the address it last asked for.  That is one rule for both shapes,
// and it is what the memory side can be checked against: every fill is at the
// address the rule gives, and there are as many of them as the rule says.
//
// It replaces "one request a line, always, including the lines that show
// nothing", which was this block's invariant while it drew one screen upright.
// The clamped fetches for the 103 border and blanking lines are gone with it,
// which saves half a megabyte a second and was not the reason: the reason is
// that a band is not a line and a rule that names lines cannot describe one.
//
// If a fill has not arrived when the raster needs it, that screen is shown BLACK
// for as long as it is shown from that bank, and a sticky `underrun` bit is
// raised.  The first bank of all is black because nothing has been fetched yet,
// and that is not an underrun --- it is what starting up looks like.
//
// ----------------------------------------------------------------------
// WHICH BIT IS WHICH PIXEL
//
// muir `src/tv.rs`, `Tv::pixel`: a line of the first display is 24 consecutive
// words, the first line first, and within a line the pixels run from the LOW end
// of the first word --- **bit 0 of a word is the LEFTMOST of the 32 pixels it
// carries**.  `Tv::color_pixel` is the same rule at four bits: a line is 72
// consecutive words and **the LOW NIBBLE is the LEFTMOST of the 8 pixels a word
// carries**, which is `lmtv.order`'s own low-order-bit-first.  Both rules are
// written out again in
// `boards/arty-z7-20/linux/buildroot/package/cadr-terminal/src/screen_geom.h`,
// which is the program that already serves these bitmaps over the network and
// has been read against a real screen.  This is the third expression of them and
// the check holds it to the words rather than to the other two.
//
// A LIT BIT OF THE FIRST DISPLAY SHOWS WHITE UNLESS `MODE BOW`.  That bit is
// `MODE<2>` of the display's mode register, four flops inside
// `rtl/machine/cadr_tv.sv`, and **this module cannot read it**: `cadr_tv` does
// not bring the mode register out, and adding a port to it is a change to
// `rtl/machine/`, which is held to muir.  So `BOW` is a parameter whose default
// is the fabric's own power-on state, zero --- which is also `Tv::default` and
// the mode both reference programs leave the register in for their whole run.
// `cadr-terminal` made the identical choice for the identical reason and calls
// it `--bow`.  **It does not reach the color screen**, whose pixels are map
// entries and have no sense of inverted.
//
// **THE BORDER IS BLACK WHATEVER `BOW` SAYS.**  A picture of 768 by 963 in a
// raster of 1280 by 1024 leaves 512 columns and 61 rows that are not the CADR's
// screen at all.  They are not zero pixels of the CADR's screen either --- they
// are outside it --- so they do not follow a bit that decides how the CADR's
// zeros are shown.  Blanking is black for the same reason and by the
// specification's rather than ours.
//
// ----------------------------------------------------------------------
// THE COLOR MAP
//
// Sixteen entries of three eight-bit channels, copied into the pixel domain and
// refreshed ONE ENTRY A RASTER LINE, so the whole map is no more than sixteen
// lines old.
//
// The copy is what makes the lookup possible at all: a pixel needs its color in
// the pixel domain and the map lives in the machine's, four bits of address
// arriving every pixel.  It is refreshed rather than loaded once because
// `WRITE-COLOR-MAP` writes the map while the machine runs and a map loaded at
// reset would be the power-on map for ever.
//
// **THE INDEX AND THE WORD CROSS THE DOMAINS AS ONE SLOW BUS, AND THEY ARE
// BOUNDED RATHER THAN LEFT OPEN.**  `map_a` is set at the first pixel of a line
// and `map_q` is taken eight pixels later, so the round trip --- out of this
// module, through `cadr_machine` into the color board's map, and back --- has 74
// ns to settle against a bus that changes once every 15.7 microseconds.  That is
// the `req_line` argument one level up, and like it the path carries a
// `set_max_delay -datapath_only` in `rtl/plumbing/xilinx7/cadr_hdmi.xdc` so that
// an asynchronous clock group cannot make it a route of any length at all.
// A write landing exactly at the sample gives one entry one wrong frame, which
// is the tearing rule above applied to the map.
//
// ----------------------------------------------------------------------
// SLEEP
//
// **A DIGITAL LINK HAS NO POWER MANAGEMENT OF ITS OWN, SO A MONITOR IS PUT TO
// SLEEP BY STOPPING THE LINK.**  DPMS was an encoding of VGA's two sync lines,
// and DVI has nothing of that kind: a source that wants a monitor asleep stops
// sending, the monitor sees no signal, and it goes into its own power save.  So
// `mute` holds the four lanes at one level --- `rtl/plumbing/cadr_hdmi_tx.sv`
// is what it gates, the clock lane with the three data lanes --- and everything
// in front of it keeps running: the pixel clock, the raster, the fetch and the
// buffers.  A monitor woken up locks onto a picture that never stopped and
// shows the machine's screen as it is now.
//
// **THE TIMER ALWAYS RUNS.**  It counts whole seconds of the machine's clock,
// `sleep_setting` of them, and when they are gone `sleep_due` goes up and
// stays up.  Nothing about the board decides whether it runs --- not whether a
// keyboard is plugged in, not whether anybody is watching over the network ---
// which is how a computer's own display sleeps.  **A setting of zero never
// sleeps.**
//
// **AND THE ONE THING THAT STARTS IT OVER, AND WAKES THE MONITOR, IS `wake`,
// WHICH IS A KEY OR THE MOUSE AT THE BOARD.**  The fabric cannot tell a key
// typed at the board from a key typed into a viewer, because one program writes
// the keyboard's register for both, so the program is what decides:
// `cadr-terminal` pulses `wake` through the console for an event that came over
// its input link from `cadr-usb-input`, and for nothing else.  A viewer's key
// still reaches the machine and neither wakes the monitor nor starts the timer
// over, and a keyboard plugged in or pulled out is not an event at all.
//
// What each of the other things a person can do at the board does to it, and
// why each is the least surprising:
//
//   `sleep_set`     a new setting, from the card's `fpgarc` at boot or
//                   `cadr-console hdmi-sleep` at any time.  THE TIMER STARTS
//                   OVER FROM THE WRITE and a monitor asleep wakes, because the
//                   setting it went to sleep under is gone: a person who asks
//                   for ten minutes expects ten minutes from now.  Zero wakes it
//                   and keeps it awake.  A write and a wake on one edge are the
//                   write, which starts the timer over too.
//   a fabric reset  BTN1.  The timer starts over, the setting goes back to the
//                   fabric's own `SLEEP_S`, and the monitor wakes --- which is
//                   what a fabric that has just been reset is expected to look
//                   like.  The card's own setting comes back at the next boot
//                   of Linux, which a fabric reset does not cause, and this is
//                   the lamps' own standing after BTN1.
//   BTN0 and the    the machine's boot button, from the board or from
//   console's boot  `cadr-console boot`.  **NOTHING**: this block is not part of
//                   the machine and hears nothing from it, and a machine that
//                   boots is a machine whose screen is being drawn on whether or
//                   not a monitor is watching.
//
// **THE MUTE MOVES ONLY AT A FRAME BOUNDARY**, where the settings are taken:
// the instant between a frame's last pixel of blanking and its first line.  The
// lanes stop in the blanking and start again in the blanking, so a monitor is
// never handed half a frame at either end.  The timer's verdict crosses into
// the pixel clock's domain through two flops and the mute takes it at the next
// boundary, a frame later at most; `asleep` is the mute brought back into the
// machine's clock through two more, which is what the console reads.
//
// **THE SECOND IS IN BOARD TICKS AND NOT ON MIT'S GRID.**  `SECOND_T` is how
// many of the machine's clock edges make a real second, a fabric choice like
// `cadr_debug_window.sv`'s watchdog, so it names no nanosecond figure and does
// not go through `cadr_tick_pkg`.  At the 10 ns tick it is 100,000,000.
//
// ----------------------------------------------------------------------
// THE MODE
//
// Three, and **the mode is a parameter and not a setting**: a video mode is a
// pixel clock, the pixel clock comes from an MMCM, and changing an MMCM's
// frequency at run time means rewriting its dividers through its reconfiguration
// port along with the lock and filter registers that go with them.  Those two
// tables are empirical values of Xilinx's with no published arithmetic behind
// them: the only copy on this machine is inside the clocking wizard, under a
// notice that forbids taking it, and writing them from memory is the thing this
// project refuses everywhere else.  `docs/display-output.md` has the whole
// measurement, including the arithmetic that says a fixed oscillator cannot
// serve the three clocks --- a 10:1 serializer makes the pixel divider a
// multiple of five, so one oscillator gives only the ratios 1, 2/3, 1/2.
//
// So the mode is chosen when the bitstream is built, three bitstreams carry the
// three modes, and the console reports which one the fabric is.  The other two
// settings are read from the card at every boot.
//
//   0  VESA DMT 1280x1024 at 60 Hz, 108 MHz, both syncs positive
//   1  CVT reduced blanking 1400x1050 at 60 Hz, 101 MHz, HSYNC positive and
//      VSYNC negative, which is how a sink knows reduced blanking
//   2  CEA-861 1920x1080 at 30 Hz, 74.25 MHz, both syncs positive
//
// The figures are the specifications' and are in `docs/display-output.md` with
// the arithmetic they come from.  They are parameters here so that the check can
// run a small raster in a short simulation, and so that a board that must use
// another mode can.

`default_nettype none

module cadr_display_out #(
    // Where the bitmaps are: `cadr_ddr_map::DISPLAY_BASE` and
    // `COLOR_DISPLAY_BASE`, passed in rather than imported so that the check can
    // put them somewhere else.
    parameter logic [31:0] BASE       = 32'h1C00_0000,
    parameter logic [31:0] COLOR_BASE = 32'h1C02_0000,

    // **THE MODE, AND ITS FIGURES ARE HERE AND NOWHERE ELSE.**  The board picks
    // a column and passes nothing but the number; the check transcribes the
    // three specifications independently and compares.  A table in the top
    // level as well would be a second description of one fact, which is how
    // they come to disagree.
    //
    //   0  VESA DMT 1280x1024 at 60 Hz, 108 MHz, both syncs positive
    //   1  CVT reduced blanking 1400x1050 at 60 Hz, 101 MHz.  Reduced blanking
    //      is 160 pixels of horizontal blanking whatever the width, and HSYNC
    //      POSITIVE with VSYNC NEGATIVE, which is the pair a sink reads it by
    //   2  CEA-861 VIC 34, 1920x1080 at 30 Hz, 74.25 MHz, both syncs positive
    //
    // `docs/display-output.md` has the arithmetic each column comes out of.
    parameter int unsigned MODE = 0,

    // Active, front porch, sync, back porch, in that order, which is the order
    // the raster walks them; and the two polarities, which a monitor reads as
    // part of how it identifies the mode and which are therefore not free.
    // They are parameters of their own, defaulting to the mode's column, so
    // that the check can run a small raster in a short simulation.
    parameter int unsigned H_ACTIVE = (MODE == 1) ? 1400 : (MODE == 2) ? 1920 : 1280,
    parameter int unsigned H_FRONT  = (MODE == 1) ?   48 : (MODE == 2) ?   88 :   48,
    parameter int unsigned H_SYNC   = (MODE == 1) ?   32 : (MODE == 2) ?   44 :  112,
    parameter int unsigned H_BACK   = (MODE == 1) ?   80 : (MODE == 2) ?  148 :  248,
    parameter int unsigned V_ACTIVE = (MODE == 1) ? 1050 : (MODE == 2) ? 1080 : 1024,
    parameter int unsigned V_FRONT  = (MODE == 1) ?    3 : (MODE == 2) ?    4 :    1,
    parameter int unsigned V_SYNC   = (MODE == 1) ?    4 : (MODE == 2) ?    5 :    3,
    parameter int unsigned V_BACK   = (MODE == 1) ?   23 : (MODE == 2) ?   36 :   38,
    parameter bit          HSYNC_POS = 1'b1,
    parameter bit          VSYNC_POS = (MODE == 1) ? 1'b0 : 1'b1,

    // The first display: muir's `WIDTH`, `HEIGHT` and `WORDS_PER_LINE`.
    parameter int unsigned PIC_W = 768,
    parameter int unsigned PIC_H = 963,
    parameter int unsigned WORDS_PER_LINE = 24,

    // The color board: muir's `COLOR_WIDTH`, `COLOR_HEIGHT` and
    // `COLOR_WORDS_PER_LINE`, four bits a pixel.
    parameter int unsigned CPIC_W = 576,
    parameter int unsigned CPIC_H = 454,
    parameter int unsigned CWORDS_PER_LINE = 72,

    // `MODE BOW`: see the header.
    parameter bit          BOW = 1'b0,

    // How many 64-bit entries a bank of each buffer has.  Big enough for a band
    // --- `ceil(PIC_H/2)` and `ceil(CPIC_H/2)` --- rounded up to a power of two
    // so that the bank is one address bit and its stride cannot be anything
    // else.  The check overrides them with the same arithmetic on its own
    // pictures.
    parameter int unsigned MONO_ENTRIES  = 512,
    parameter int unsigned COLOR_ENTRIES = 256,

    // How many single-beat reads the strided fetch may have in flight.  See the
    // strided arm below for why one at a time does not finish in time.
    parameter int unsigned OUTSTANDING = 8,

    // How many of the machine's clock edges make a second for the sleep timer.
    // **ONE SECOND AT THE 10 ns TICK, IN BOARD TICKS AND NOT ON MIT'S GRID**:
    // see "SLEEP" above.  At least two, because the prescaler counts to one
    // below it.  The check builds it at 2,000 so that three hundred seconds is
    // eighty frames rather than a real five minutes.
    parameter int unsigned SECOND_T = 100_000_000,
    // The setting the fabric comes up with and a fabric reset puts back:
    // `--hdmi-sleep`'s own default.  At most 32,767, the setting being fifteen
    // bits.
    parameter int unsigned SLEEP_S  = 300
) (
    // ------------------------------------------------ the memory domain
    input  var logic        clk,
    input  var logic        rst,

    // `S_AXI_HP3`, read only.  This module never writes memory, so the write
    // channels are not here at all rather than tied off somewhere a reader has
    // to go and check.
    output var logic [31:0] m_araddr,
    output var logic [3:0]  m_arlen,
    output var logic [1:0]  m_arsize,
    output var logic [1:0]  m_arburst,
    output var logic        m_arvalid,
    input  var logic        m_arready,
    input  var logic [63:0] m_rdata,
    input  var logic [1:0]  m_rresp,
    input  var logic        m_rlast,
    input  var logic        m_rvalid,
    output var logic        m_rready,

    // **WHAT IS SHOWN AND WHICH WAY UP**, from the console face, in the
    // machine's clock domain.  `out_sel` bit 0 shows the first display and bit 1
    // the color board; `rotate` is 0 upright, 1 a quarter turn clockwise, 2 the
    // other way.  Both are synchronized into the pixel domain here and LATCHED
    // AT THE TOP OF A FRAME, so that a setting written while a frame is being
    // drawn takes at the next one and cannot move the geometry under a picture
    // half drawn.
    input  var logic [1:0]  out_sel,
    input  var logic [1:0]  rotate,

    // **SLEEP**, the face the console writes, in the machine's clock domain:
    // see "SLEEP" above.  `sleep_set` is a one-tick pulse carrying a new
    // setting in `sleep_secs`, and `wake` a one-tick pulse; both start the
    // timer over.  `sleep_setting` is the setting as this block holds it,
    // `sleep_due` is the timer's verdict --- up from the edge the last second
    // ran out until something starts it over --- and `asleep` is the lanes
    // muted, as the machine's clock sees them.
    input  var logic        sleep_set,
    input  var logic [14:0] sleep_secs,
    input  var logic        wake,
    output var logic [14:0] sleep_setting,
    output var logic        sleep_due,
    output var logic        asleep,

    // ------------------------------------------------- the pixel domain
    input  var logic        pclk,
    input  var logic        prst,

    // The color board's map, read one entry a raster line: see the header.
    // `map_a` is driven from this domain and `map_q` comes back combinationally
    // out of `rtl/machine/cadr_tv.sv`, so the pair is a bounded crossing and not
    // a synchronous port.
    output var logic [3:0]  map_a,
    input  var logic [23:0] map_q,

    // The four lanes held at one level, which is a monitor with no signal:
    // see "SLEEP" above.  Moves only at a frame boundary.
    output var logic        mute,
    output var logic        de,
    output var logic        hsync,
    output var logic        vsync,
    // Three channels of eight bits.  The first display's one bit becomes 0x00 or
    // 0xFF on all three; the color board's four bits become the map entry they
    // name, red in bits 23 to 16 of it, which is `WRITE-COLOR-MAP`'s own channel
    // order.
    output var logic [7:0]  red,
    output var logic [7:0]  green,
    output var logic [7:0]  blue,

    // A bank the raster reached before its words did, and a read the port
    // answered with an error.  Both sticky, in the pixel and memory domains
    // respectively; neither is on the machine's path and neither stops anything.
    // They exist so that a wrong picture can be told from a picture that never
    // arrived.
    output var logic        underrun,
    output var logic        rd_error
);

  localparam int unsigned H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
  localparam int unsigned V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;

  localparam int unsigned HC_W = $clog2(H_TOTAL);
  localparam int unsigned VC_W = $clog2(V_TOTAL);

  // Where each picture sits, upright and rotated.  An odd margin loses its half
  // pixel at the bottom and the right, which is where a reader expects it.
  localparam int unsigned MX0  = (H_ACTIVE - PIC_W)  / 2;
  localparam int unsigned MY0  = (V_ACTIVE - PIC_H)  / 2;
  localparam int unsigned CX0  = (H_ACTIVE - CPIC_W) / 2;
  localparam int unsigned CY0  = (V_ACTIVE - CPIC_H) / 2;
  localparam int unsigned RMX0 = (H_ACTIVE - PIC_H)  / 2;
  localparam int unsigned RMY0 = (V_ACTIVE - PIC_W)  / 2;
  localparam int unsigned RCX0 = (H_ACTIVE - CPIC_H) / 2;
  localparam int unsigned RCY0 = (V_ACTIVE - CPIC_W) / 2;

  localparam int unsigned LINE_BYTES  = WORDS_PER_LINE  * 4;
  localparam int unsigned CLINE_BYTES = CWORDS_PER_LINE * 4;

  // How many lines of lead time a rotated band is asked with, which is how many
  // output lines one word column covers: 32 bits a word for the first display
  // and 8 nibbles for the color board.
  localparam int unsigned MONO_LOOK  = 32;
  localparam int unsigned COLOR_LOOK = 8;

  localparam int unsigned ME_W = $clog2(MONO_ENTRIES);
  localparam int unsigned CE_W = $clog2(COLOR_ENTRIES);
  // One width for every word counter, wide enough for the longest band either
  // buffer can hold.  One width and not two, so that nothing below has to widen
  // a comparison and get it wrong.
  // One width a screen for a word index inside its own buffer, and one width
  // for the memory side's counters, which serve whichever job is in hand.
  localparam int unsigned MW_W = ME_W + 1;
  localparam int unsigned CW_W = CE_W + 1;
  localparam int unsigned WC_W = (MW_W > CW_W) ? MW_W : CW_W;

  // The two screens, as one small vocabulary, so that what is written once below
  // is indexed rather than copied.
  localparam int unsigned MONO = 0;
  localparam int unsigned COLR = 1;

  // ====================================================================
  // THE SETTINGS, SYNCHRONIZED AND LATCHED
  // ====================================================================

  logic [1:0] sel_s1, sel_s2, rot_s1, rot_s2;
  logic [1:0] cfg_sel, cfg_rot;
  logic       en_m, en_c, rot_on;
  assign en_m   = cfg_sel[0];
  assign en_c   = cfg_sel[1];
  assign rot_on = (cfg_rot != 2'd0);

  // ====================================================================
  // THE RASTER'S COUNTERS
  // ====================================================================

  logic [HC_W-1:0] hc, hc_n;
  logic [VC_W-1:0] vc, vc_n;

  always_comb begin
    hc_n = (hc == HC_W'(H_TOTAL - 1)) ? '0 : hc + 1'b1;
    vc_n = (hc == HC_W'(H_TOTAL - 1))
             ? ((vc == VC_W'(V_TOTAL - 1)) ? '0 : vc + 1'b1)
             : vc;
  end

  // ====================================================================
  // WHERE A PIXEL COMES FROM
  // ====================================================================
  //
  // Upright, a raster column is a source column and a raster row a source row.
  // Rotated a quarter turn clockwise, the source's top-left corner appears at
  // the raster picture's top-right: source (col, row) is drawn at raster
  // (H-1-row, col), so along an output line the COLUMN is constant --- it is the
  // output line's own number --- and the ROW counts down.  The other way round
  // exchanges the two.
  //
  // **SO THE BUFFER ADDRESS IS A FUNCTION OF THE RASTER COLUMN IN ALL THREE
  // CASES, AND THE BIT WITHIN THE WORD IS A FUNCTION OF THE COLUMN UPRIGHT AND
  // OF THE ROW ROTATED.**  That is the whole of what rotation costs the raster,
  // and it is why the buffer can be read one entry a pixel whichever way up the
  // picture is.

  // The word index each screen wants for the pixel at raster column x.  Only
  // meaningful where that column is inside the picture, which is what the two
  // `in` terms below decide; elsewhere it wraps and is not looked at.
  function automatic logic [MW_W-1:0] mono_widx(input logic [HC_W-1:0] x);
    if (cfg_rot == 2'd0)      return MW_W'((x - HC_W'(MX0)) >> 5);
    else if (cfg_rot == 2'd1) return MW_W'(HC_W'(PIC_H - 1) - (x - HC_W'(RMX0)));
    else                      return MW_W'(x - HC_W'(RMX0));
  endfunction

  function automatic logic [CW_W-1:0] color_widx(input logic [HC_W-1:0] x);
    if (cfg_rot == 2'd0)      return CW_W'((x - HC_W'(CX0)) >> 3);
    else if (cfg_rot == 2'd1) return CW_W'(HC_W'(CPIC_H - 1) - (x - HC_W'(RCX0)));
    else                      return CW_W'(x - HC_W'(RCX0));
  endfunction

  // The bit of a word, and the nibble of a word.  Five and three bits, because
  // the difference is only ever wanted modulo the pixels a word carries, and
  // subtracting the low bits gives that whatever the margin is.
  logic [4:0] mono_bit;
  logic [2:0] color_nib;
  always_comb begin
    if (cfg_rot == 2'd0)      mono_bit = hc[4:0] - 5'(MX0);
    else if (cfg_rot == 2'd1) mono_bit = vc[4:0] - 5'(RMY0);
    else                      mono_bit = 5'(PIC_W - 1) - (vc[4:0] - 5'(RMY0));
  end
  always_comb begin
    if (cfg_rot == 2'd0)      color_nib = hc[2:0] - 3'(CX0);
    else if (cfg_rot == 2'd1) color_nib = vc[2:0] - 3'(RCY0);
    else                      color_nib = 3'(CPIC_W - 1) - (vc[2:0] - 3'(RCY0));
  end

  // Is this pixel inside each picture?  The rectangle is the picture's own size
  // upright and its size exchanged rotated.
  logic de_c, hs_c, vs_c, m_in_c, c_in_c;
  assign de_c = (hc < HC_W'(H_ACTIVE)) && (vc < VC_W'(V_ACTIVE));
  assign hs_c = (hc >= HC_W'(H_ACTIVE + H_FRONT)) &&
                (hc <  HC_W'(H_ACTIVE + H_FRONT + H_SYNC));
  assign vs_c = (vc >= VC_W'(V_ACTIVE + V_FRONT)) &&
                (vc <  VC_W'(V_ACTIVE + V_FRONT + V_SYNC));

  always_comb begin
    if (cfg_rot == 2'd0)
      m_in_c = (hc >= HC_W'(MX0)) && (hc < HC_W'(MX0 + PIC_W)) &&
               (vc >= VC_W'(MY0)) && (vc < VC_W'(MY0 + PIC_H));
    else
      m_in_c = (hc >= HC_W'(RMX0)) && (hc < HC_W'(RMX0 + PIC_H)) &&
               (vc >= VC_W'(RMY0)) && (vc < VC_W'(RMY0 + PIC_W));
  end
  always_comb begin
    if (cfg_rot == 2'd0)
      c_in_c = (hc >= HC_W'(CX0)) && (hc < HC_W'(CX0 + CPIC_W)) &&
               (vc >= VC_W'(CY0)) && (vc < VC_W'(CY0 + CPIC_H));
    else
      c_in_c = (hc >= HC_W'(RCX0)) && (hc < HC_W'(RCX0 + CPIC_H)) &&
               (vc >= VC_W'(RCY0)) && (vc < VC_W'(RCY0 + CPIC_W));
  end

  // ====================================================================
  // WHAT HAS TO BE FETCHED, AND WHEN
  // ====================================================================
  //
  // One rule for both shapes.  `show_addr` is the byte address the line being
  // drawn needs; `ask_addr` is the one the line `LOOK` lines from now will need
  // --- one line upright, 32 rotated for the first display and 8 for the color
  // board --- and a request goes out when `ask_addr` is not what was last asked
  // for.
  //
  // **AND EACH OF THE FOUR IS A REGISTER THAT ADDS A STRIDE ONCE A LINE, NEVER
  // A MULTIPLICATION.**  Written the obvious way --- clamp the line into the
  // picture, multiply by the line's bytes --- it is a DSP and a chain of clamps
  // hanging off the line counter, combinational, recomputed on every pixel, and
  // feeding the comparator that drives the request register's own clock enable.
  // That put twenty-two levels of logic between `vc` and `asked[MONO]`'s enable
  // and missed the pixel clock by 8.430 ns, which is the arithmetic's own depth
  // and not a placement figure: a DSP48E1 and eleven carry chains.
  //
  // The row moves by one a line and the address by one stride, so **the
  // addition IS the product**.  `cadr_phase_gen.sv` makes its taps this way and
  // the disk's block counter its position, and this file's own strided fetch
  // already walks `saddr` by a source line for the same reason.  What stands in
  // front of the comparator is now a register, and in front of that an
  // eleven-bit counter against two constants and one thirty-two-bit add, made
  // once a line where the multiplication was made 1,688 times.
  //
  // Rotated there is no product to begin with --- a word column is the source
  // column shifted --- so the step is four bytes every 32 lines, or every 8 for
  // the color board.  **A quarter turn the other way walks the word columns
  // BACKWARDS**, which is a step of minus four from the last column rather than
  // a rule of its own.

  // Where a rotated picture's FIRST line begins.  A quarter turn clockwise
  // starts at word column zero; the other way starts at the last one, because
  // there the source column counts down as the raster line counts up.
  localparam logic [31:0] MONO_ROT_TOP  = BASE       + 32'(((PIC_W  - 1) >> 5) << 2);
  localparam logic [31:0] COLOR_ROT_TOP = COLOR_BASE + 32'(((CPIC_W - 1) >> 3) << 2);

  // The four addresses, and the line each `ask` one is for.  The `show` pair is
  // for `vc`, which is counted already.
  logic [31:0]     m_show_addr, m_ask_addr, c_show_addr, c_ask_addr;
  logic [VC_W-1:0] va_m, va_c;

  // Does a screen's address move on at line `v`?  Upright, on every line
  // strictly inside the picture, because the row moved.  Rotated, on every line
  // strictly inside it whose source column is the first of a word.  Two
  // comparisons and five bits, and no product anywhere.
  function automatic logic mono_steps(input logic [VC_W-1:0] v);
    if (cfg_rot == 2'd0)
      return (v > VC_W'(MY0)) && (v < VC_W'(MY0 + PIC_H));
    else
      return (v > VC_W'(RMY0)) && (v < VC_W'(RMY0 + PIC_W)) &&
             (((v - VC_W'(RMY0)) & VC_W'(31)) == VC_W'(0));
  endfunction

  function automatic logic color_steps(input logic [VC_W-1:0] v);
    if (cfg_rot == 2'd0)
      return (v > VC_W'(CY0)) && (v < VC_W'(CY0 + CPIC_H));
    else
      return (v > VC_W'(RCY0)) && (v < VC_W'(RCY0 + CPIC_W)) &&
             (((v - VC_W'(RCY0)) & VC_W'(7)) == VC_W'(0));
  endfunction

  // What one step is worth and where a frame's first line begins, for the
  // setting in force; and the same pair for the setting about to be taken,
  // which is what a frame top reloads all four addresses from.
  //
  // **THE FIRST LINE'S `ask` ADDRESS IS THE FIRST LINE'S `show` ADDRESS**, so
  // one reload serves both, and that holds because `LOOK` is inside the top
  // margin in every mode: 1 against 30, 43 and 58 upright, 32 against 128, 141
  // and 156 rotated, and 8 against the color board's 224, 237 and 252.  A mode
  // whose margin were narrower than its lead would want the address for line
  // `LOOK` here instead, and would be a mode that cannot hold the picture.
  logic [1:0]      rot_next;
  logic [31:0]     mono_step, color_step, mono_first, color_first;
  logic [31:0]     mono_first_next, color_first_next;
  logic [VC_W-1:0] look_m_next, look_c_next;
  assign rot_next   = (rot_s2 == 2'd3) ? 2'd0 : rot_s2;
  assign mono_step  = (cfg_rot == 2'd0) ? 32'(LINE_BYTES)
                    : (cfg_rot == 2'd1) ? 32'd4 : 32'hFFFF_FFFC;
  assign color_step = (cfg_rot == 2'd0) ? 32'(CLINE_BYTES)
                    : (cfg_rot == 2'd1) ? 32'd4 : 32'hFFFF_FFFC;
  assign mono_first       = (cfg_rot  == 2'd2) ? MONO_ROT_TOP  : BASE;
  assign color_first      = (cfg_rot  == 2'd2) ? COLOR_ROT_TOP : COLOR_BASE;
  assign mono_first_next  = (rot_next == 2'd2) ? MONO_ROT_TOP  : BASE;
  assign color_first_next = (rot_next == 2'd2) ? COLOR_ROT_TOP : COLOR_BASE;
  assign look_m_next = (rot_next == 2'd0) ? VC_W'(1) : VC_W'(MONO_LOOK);
  assign look_c_next = (rot_next == 2'd0) ? VC_W'(1) : VC_W'(COLOR_LOOK);

  // ====================================================================
  // THE BUFFERS
  // ====================================================================
  //
  // Written a beat at a time on `clk`, read an entry at a time on `pclk` with
  // the output registered, which is what a block RAM with two clocks is.
  //
  // **EACH ENTRY IS A WHOLE 64-BIT BEAT AND NOT A 32-BIT WORD, AND THAT IS WHAT
  // MAKES ONE MEMORY SERVE BOTH SHAPES.**  A contiguous fetch brings two words
  // in one beat: written as two 32-bit entries that is two writes in one cycle,
  // which no block RAM does and which would force the buffer into lookup tables.
  // One 64-bit entry a beat is one write, the read picks its half by the low bit
  // of the word index, and the strided fetch --- which uses one word of each
  // beat --- writes one half at a time, which is a byte-enabled write and is
  // what a block RAM is for.
  //
  // **THE BANK IS THE TOP ADDRESS BIT AND THE ENTRY COUNT IS A POWER OF TWO**,
  // so the bank stride cannot be anything but a power of two: sizing a bank at
  // the entries it uses and indexing it by a concatenation put one bank's tail
  // off the end of the array once already, and the right-hand third of every
  // other line came out black.
  logic [63:0] mbuf [2*MONO_ENTRIES];
  logic [63:0] cbuf [2*COLOR_ENTRIES];

  // ====================================================================
  // THE MEMORY SIDE
  // ====================================================================

  logic [2:0]  req_sync [2];
  logic        req_seen [2];
  logic        fill_n   [2];

  // The raster's two requests, as this side sees them.
  logic        req_tog     [2];
  logic [31:0] req_addr    [2];
  logic        req_strided [2];

  typedef enum logic [2:0] { F_IDLE, F_ADDR, F_AWAIT, F_DATA, F_STRIDE } fetch_e;
  fetch_e fstate;

  // The job in hand.
  logic            job_src;      // 0 the first display, 1 the color board
  logic            job_strided;
  logic            job_half;     // which half of a beat a strided job's word is
  logic [WC_W-1:0] job_words;    // how many words it is

  // Where the next beat goes and where it comes from.  `wptr` runs across the
  // whole job in WORDS, so a burst split at a 4 KB boundary resumes where it
  // left off rather than starting the job again.
  logic [WC_W-1:0] wptr, issued, taken;
  logic [31:0]     cur;

  // The contiguous arm's address channel, and the strided arm's.
  logic [31:0] c_araddr, saddr;
  logic [3:0]  c_arlen;
  logic        c_arvalid, s_arvalid;

  // Another address may go out when the job still owes one and the port is not
  // already holding as many as it may.  Both terms move only on an address
  // handshake, so `ARVALID` can only change just after one, which is what AXI
  // requires of it.
  //
  // **AND THE COUNT IS THE ONE AFTER THE HANDSHAKE HAPPENING THIS CYCLE, WHICH
  // IS NOT THE SAME THING AS THE COUNT.**  `s_arvalid` is set from this on the
  // very cycle an address is taken, so a test against `issued` asks whether the
  // job owed one BEFORE the address that has just gone --- and the job then
  // issues ONE TOO MANY.  That one is not harmless: its beat arrives after the
  // last one the job counts, so it is still in the port when the job ends, and
  // the NEXT job --- which raises `RREADY` as soon as it starts --- takes it as
  // its own first word.  Every word of that band is then one out, its first
  // word is a word of the band before it, and its last read arrives after it has
  // stopped counting.
  //
  // The symptom was a rotated picture right everywhere but its last output
  // column, on alternate bands, which is what one word at the head of a 963-word
  // band looks like from the front of the screen.
  logic            stride_go;
  logic [WC_W-1:0] issued_after;
  logic [WC_W:0]   in_flight;
  assign issued_after = (m_arvalid && m_arready) ? (issued + WC_W'(1)) : issued;
  assign in_flight = {1'b0, issued_after} - {1'b0, taken};
  assign stride_go = (fstate == F_STRIDE) && (issued_after != job_words) &&
                     (in_flight < (WC_W+1)'(OUTSTANDING));

  assign m_araddr  = job_strided ? saddr     : c_araddr;
  assign m_arlen   = job_strided ? 4'd0      : c_arlen;
  assign m_arvalid = job_strided ? s_arvalid : c_arvalid;
  assign m_arsize  = 2'b11;     // 2^3 = 8 bytes
  assign m_arburst = 2'b01;     // INCR
  assign m_rready  = (fstate == F_DATA) || (fstate == F_STRIDE);

  // How long a contiguous burst may be: what the job still owes in beats, what
  // fits before the next 4 KB boundary, and AXI3's own sixteen, whichever is
  // least.  `cur` is always eight-byte aligned, so the distance to the boundary
  // is a whole number of beats and the division is a shift.
  //
  // **THE SIXTEEN IS NOT DECORATION.**  A line of the first display is twelve
  // beats and never met it; a line of the COLOR board is thirty-six, and a
  // master that asked for thirty-six in one burst would be asking for something
  // AXI3 cannot express --- `ARLEN` is four bits.
  //
  // **AND 4 KB IS NOT A MULTIPLE OF EITHER LINE.**  96 and 4096 meet at 12,288,
  // which is three pages and 128 lines, so two lines in each 128 of the first
  // display begin close enough to a boundary that twelve beats run over it ---
  // 15 of the picture's 963, the first at line 42.  288 and 4096 meet at 36,864,
  // which is nine pages and 128 lines.  A fetch is therefore one burst where it
  // fits and more where it does not, split exactly at the boundary.
  logic [9:0]      to_bound;
  logic [WC_W-1:0] beats_left;
  logic [4:0]      blen;
  assign to_bound   = 10'((13'd4096 - {1'b0, cur[11:0]}) >> 3);
  assign beats_left = (job_words - wptr) >> 1;
  always_comb begin
    blen = 5'd16;
    if (beats_left < WC_W'(16))         blen = 5'(beats_left);
    if ({6'd0, to_bound} < {11'd0, blen}) blen = 5'(to_bound);
  end

  // Which buffer entry a returned word belongs in, and which half of it.
  logic [WC_W-1:0] wr_word;
  assign wr_word = job_strided ? taken : wptr;

  logic [31:0] strided_word;
  assign strided_word = job_half ? m_rdata[63:32] : m_rdata[31:0];

  always_ff @(posedge clk) begin
    if (rst) begin
      for (int s = 0; s < 2; s++) begin
        req_sync[s] <= '0;
        req_seen[s] <= 1'b0;
        fill_n[s]   <= 1'b0;
      end
      fstate      <= F_IDLE;
      c_arvalid   <= 1'b0;
      s_arvalid   <= 1'b0;
      c_araddr    <= '0;
      c_arlen     <= '0;
      saddr       <= '0;
      issued      <= '0;
      taken       <= '0;
      wptr        <= '0;
      cur         <= '0;
      job_src     <= 1'b0;
      job_strided <= 1'b0;
      job_half    <= 1'b0;
      job_words   <= '0;
      rd_error    <= 1'b0;
    end else begin
      for (int s = 0; s < 2; s++) req_sync[s] <= {req_sync[s][1:0], req_tog[s]};

      unique case (fstate)
        F_IDLE: begin
          // A request is outstanding whenever the synchronized toggle has moved
          // away from the one last acted on.  Looked at only here, so a request
          // arriving mid-job waits rather than being lost: the toggle is still
          // different when this comes back round.  **The first display is served
          // first**, arbitrarily and stated: it is the machine's own screen, and
          // one rule is one rule.
          if (req_sync[MONO][2] != req_seen[MONO]) begin
            req_seen[MONO] <= req_sync[MONO][2];
            job_src     <= 1'b0;
            job_strided <= req_strided[MONO];
            job_half    <= req_addr[MONO][2];
            job_words   <= req_strided[MONO] ? WC_W'(PIC_H) : WC_W'(WORDS_PER_LINE);
            cur         <= req_addr[MONO];
            saddr       <= {req_addr[MONO][31:3], 3'b000};
            wptr        <= '0;
            issued      <= '0;
            taken       <= '0;
            fstate      <= req_strided[MONO] ? F_STRIDE : F_ADDR;
          end else if (req_sync[COLR][2] != req_seen[COLR]) begin
            req_seen[COLR] <= req_sync[COLR][2];
            job_src     <= 1'b1;
            job_strided <= req_strided[COLR];
            job_half    <= req_addr[COLR][2];
            job_words   <= req_strided[COLR] ? WC_W'(CPIC_H) : WC_W'(CWORDS_PER_LINE);
            cur         <= req_addr[COLR];
            saddr       <= {req_addr[COLR][31:3], 3'b000};
            wptr        <= '0;
            issued      <= '0;
            taken       <= '0;
            fstate      <= req_strided[COLR] ? F_STRIDE : F_ADDR;
          end
        end

        // ------------------------------------------------ the contiguous arm
        F_ADDR: begin
          c_araddr  <= cur;
          c_arlen   <= blen[3:0] - 4'd1;
          c_arvalid <= 1'b1;
          fstate    <= F_AWAIT;
        end

        F_AWAIT: begin
          if (m_arready) begin
            c_arvalid <= 1'b0;
            fstate    <= F_DATA;
          end
        end

        F_DATA: begin
          if (m_rvalid) begin
            // SLVERR or DECERR: recorded and the beat taken anyway, because a
            // master that stops taking beats hangs the port.
            if (m_rresp != 2'b00) rd_error <= 1'b1;
            cur <= cur + 32'd8;
            if (m_rlast && (wptr + WC_W'(2) >= job_words)) begin
              // The job is complete: step that screen's bank, which is how the
              // raster is told a fill has landed.
              fill_n[job_src] <= ~fill_n[job_src];
              fstate <= F_IDLE;
            end else begin
              wptr <= wptr + WC_W'(2);
              // A burst that ended before the job did was stopped by a 4 KB
              // boundary or by AXI3's sixteen beats; ask again from where it
              // stopped.
              fstate <= m_rlast ? F_ADDR : F_DATA;
            end
          end
        end

        // --------------------------------------------------- the strided arm
        //
        // **THE ADDRESS CHANNEL RUNS AHEAD OF THE DATA, AND IT HAS TO.**  A band
        // is one word out of each source row, so every word is a transaction of
        // its own; one at a time, at the port's own round trip, a color band of
        // 454 words does not finish inside the eight raster lines it has.  All
        // of these are single beats to one identifier, so they come back in the
        // order they were asked for and the word that arrives is the word the
        // take counter names --- which is why this needs a counter and not a
        // queue.
        F_STRIDE: begin
          if (m_arvalid && m_arready) begin
            issued <= issued + WC_W'(1);
            saddr  <= saddr + (job_src ? 32'(CLINE_BYTES) : 32'(LINE_BYTES));
          end
          if (!m_arvalid || m_arready) s_arvalid <= stride_go;
          if (m_rvalid) begin
            if (m_rresp != 2'b00) rd_error <= 1'b1;
            if (taken + WC_W'(1) >= job_words) begin
              fill_n[job_src] <= ~fill_n[job_src];
              s_arvalid <= 1'b0;
              fstate    <= F_IDLE;
            end else begin
              taken <= taken + WC_W'(1);
            end
          end
        end

        default: fstate <= F_IDLE;
      endcase
    end
  end

  // The write side.  One beat is one entry of a contiguous job, and one HALF of
  // an entry of a strided one --- the beat carries the word the job wants and
  // the word beside it in the same source line, which belongs to the next word
  // column and to a band this job is not fetching.
  //
  // The two words of a contiguous beat go low half first: AXI puts word 2k in
  // the low half and 2k+1 in the high half, which is the same convention
  // `cadr_axi_widen.sv` and the pack side use, and it is also the order
  // `Tv::pixel` reads them in.
  // **IT IS WRITTEN AS TWO HALVES WITH THEIR OWN ENABLES, AND THAT SHAPE IS
  // WHAT MAKES IT A MEMORY AT ALL ON ONE OF THE TWO VENDORS.**  The same
  // three cases were once written as a full-width assignment in one branch
  // and thirty-two-bit sub-range assignments in the others, which reads more
  // directly and which Vivado infers as block RAM without being asked.
  // Quartus does not: it says "extracting RAM for identifier 'mbuf'" and then
  // builds all 98,304 bits out of registers, with no warning and no mention
  // of it in its RAM summary.  Measured on the DE25-Nano's part, on this
  // module alone: 135,576 ALUTs and 99,437 registers, against 1,257 and 1,005
  // for the form below --- and the whole board's fit then stopped at "Fitter
  // requires 159716 LUTs to implement the design, but the device only has
  // 93600".
  //
  // **AND ASKING QUARTUS FOR AN M20K DOES NOT FIX IT**, which was tried
  // first, because a setting from outside the source is what this project
  // reaches for before changing the source.  Neither attribute moves a
  // single number, measured on the same module and the same part:
  //
  //   as it was written                     135,576 ALUTs, 99,437 registers
  //   with RAMSTYLE_ATTRIBUTE M20K          135,576 ALUTs, 99,437 registers
  //   and RAMSTYLE_ATTRIBUTE_RDW off too    135,576 ALUTs, 99,437 registers
  //   written as below                        1,257 ALUTs,  1,005 registers
  //
  // The assignments are in the project file, synthesis says nothing about
  // them, and nothing moves.  A constraint that reaches nothing looks exactly
  // like one that works.
  //
  // **AND NOTHING IS GIVEN AWAY TO GET THIS.**  The relaxation the disk
  // controller's store and the machine's three asynchronous memories need on
  // this part --- read-during-write checking off, which costs the word read
  // in the tick an edge writes it --- is not needed here and is not asked
  // for, so there is no undefined tick to poison and no check owed for one.
  //
  // So the write is the canonical byte-enabled form instead --- one enable a
  // half, each half written by itself --- which is what a block RAM with byte
  // enables IS, and which both tools infer.  It says the same thing: a
  // contiguous beat writes both halves of an entry, and a strided beat writes
  // the one half its word belongs in.  Nothing about the behavior moves, and
  // `build/display_out.pass` holds every pixel of a frame against the memory
  // it came from, in both rotations and for both screens, in all three modes.
  logic          wr_beat;
  logic [ME_W:0] mb_addr;
  logic [CE_W:0] cb_addr;
  logic [31:0]   wr_hi, wr_lo;
  logic          mb_we_hi, mb_we_lo, cb_we_hi, cb_we_lo;
  assign wr_beat  = ((fstate == F_DATA) || (fstate == F_STRIDE)) && m_rvalid;
  assign mb_addr  = {fill_n[MONO], wr_word[ME_W:1]};
  assign cb_addr  = {fill_n[COLR], wr_word[CE_W:1]};
  assign wr_hi    = job_strided ? strided_word : m_rdata[63:32];
  assign wr_lo    = job_strided ? strided_word : m_rdata[31:0];
  assign mb_we_hi = wr_beat && (job_src == 1'b0) && (!job_strided ||  wr_word[0]);
  assign mb_we_lo = wr_beat && (job_src == 1'b0) && (!job_strided || !wr_word[0]);
  assign cb_we_hi = wr_beat && (job_src == 1'b1) && (!job_strided ||  wr_word[0]);
  assign cb_we_lo = wr_beat && (job_src == 1'b1) && (!job_strided || !wr_word[0]);
  always_ff @(posedge clk) begin
    if (mb_we_hi) mbuf[mb_addr][63:32] <= wr_hi;
    if (mb_we_lo) mbuf[mb_addr][31:0]  <= wr_lo;
  end
  always_ff @(posedge clk) begin
    if (cb_we_hi) cbuf[cb_addr][63:32] <= wr_hi;
    if (cb_we_lo) cbuf[cb_addr][31:0]  <= wr_lo;
  end

  // ====================================================================
  // SLEEP: THE TIMER, IN THE MACHINE'S CLOCK DOMAIN
  // ====================================================================
  //
  // A prescaler counting the machine's clock edges to a second and a count of
  // whole seconds left, both started over by a write, a wake or a reset.  When
  // the last second runs out `slp_want` goes up and the count stops there, so
  // the verdict is a level and not a pulse the pixel side could miss.  **A
  // SETTING OF ZERO NEVER COUNTS**: that is the only thing that stops the timer
  // from running.
  localparam int unsigned PRE_W = $clog2(SECOND_T);

  logic [PRE_W-1:0] slp_pre;    // edges into the current second
  logic [14:0]      slp_secs;   // the setting
  logic [14:0]      slp_left;   // whole seconds still to go, this one included
  logic             slp_want;   // the timer has run out: mute at the boundary

  always_ff @(posedge clk) begin
    if (rst) begin
      slp_secs <= 15'(SLEEP_S);
      slp_left <= 15'(SLEEP_S);
      slp_pre  <= '0;
      slp_want <= 1'b0;
    end else if (sleep_set) begin
      // A write wins over a wake on the same edge, and starts the timer over
      // as a wake would.
      slp_secs <= sleep_secs;
      slp_left <= sleep_secs;
      slp_pre  <= '0;
      slp_want <= 1'b0;
    end else if (wake) begin
      slp_left <= slp_secs;
      slp_pre  <= '0;
      slp_want <= 1'b0;
    end else if (!slp_want && (slp_secs != 15'd0)) begin
      if (slp_pre == PRE_W'(SECOND_T - 1)) begin
        slp_pre <= '0;
        if (slp_left <= 15'd1) slp_want <= 1'b1;
        else                   slp_left <= slp_left - 15'd1;
      end else begin
        slp_pre <= slp_pre + PRE_W'(1);
      end
    end
  end

  assign sleep_setting = slp_secs;
  assign sleep_due     = slp_want;

  // The mute, back in the machine's clock domain for the console.  **NOT
  // RESET**, because what it synchronizes is not reset by this domain's reset:
  // the mute is the pixel domain's and a fabric reset lets it go at the next
  // boundary, so a synchronizer cleared by that reset would say "awake" for two
  // edges while the lanes were still muted, and then "asleep" again.  A flop
  // that only ever follows its source cannot say anything its source did not.
  logic slp_mute;
  logic slp_mute_s1, slp_mute_s2;
  always_ff @(posedge clk) begin
    slp_mute_s1 <= slp_mute;
    slp_mute_s2 <= slp_mute_s1;
  end
  assign asleep = slp_mute_s2;

  // ====================================================================
  // THE PIXEL SIDE
  // ====================================================================
  //
  // **A SWAP COUNTS A FILL AND NEVER A LINE.**  `fill_n` toggles once for every
  // fill that lands; the raster keeps the value it last consumed, and it may
  // take a new bank only when the two differ.  So swaps can never outnumber
  // fills, whatever the settings do mid-run --- and the bank being shown is
  // simply the complement of what was last consumed, which is one register
  // rather than two descriptions of one fact.
  logic [2:0]  ack_sync [2];
  logic        consumed [2];
  logic        primed   [2];
  logic        blackx   [2];
  // **THE FRAME IN WHICH A SETTING CHANGED CANNOT REPORT AN UNDERRUN, AND
  // `primed` ALONE DOES NOT SAY SO.**  A change of geometry makes the fetcher
  // ask afresh, and the raster's first look of that frame can take a bank
  // fetched under the OLD shape --- which primes it --- while TWO fills of the
  // new shape then land between two looks.  `fill_n` is one bit, so two fills
  // toggle it back to where it was and read as NONE: the raster shows black and
  // calls the port slow.  Measured on a quarter turn the other way and not on
  // the one clockwise, because only the anticlockwise picture's first band sits
  // at an address the upright frame had not already asked for --- an accident
  // of the margins, which is exactly what makes a fault look like one rotation
  // being special.  So the changeover frame is marked: it neither primes nor
  // complains, and the frame after it does both.
  logic        settled;
  // The timer's verdict in this domain, two flops deep; `slp_mute` above takes
  // it at the frame boundary.
  logic        slp_want_s1, slp_want_s2;
  logic [31:0] asked    [2];
  logic [31:0] drawn    [2];

  logic show_n [2];
  assign show_n[MONO] = ~consumed[MONO];
  assign show_n[COLR] = ~consumed[COLR];

  // The entry each buffer is read from, and which half of it the pixel wants.
  logic [MW_W-1:0] m_ridx;
  logic [CW_W-1:0] c_ridx;
  assign m_ridx = mono_widx(hc_n);
  assign c_ridx = color_widx(hc_n);

  logic [63:0] m_entry, c_entry;
  logic        m_half_q, c_half_q;
  always_ff @(posedge pclk) begin
    m_entry  <= mbuf[{show_n[MONO], m_ridx[ME_W:1]}];
    c_entry  <= cbuf[{show_n[COLR], c_ridx[CE_W:1]}];
    m_half_q <= m_ridx[0];
    c_half_q <= c_ridx[0];
  end

  logic [31:0] m_word, c_word;
  assign m_word = m_half_q ? m_entry[63:32] : m_entry[31:0];
  assign c_word = c_half_q ? c_entry[63:32] : c_entry[31:0];

  assign mute = slp_mute;

  // The color map's copy, and the index being refreshed.
  logic [23:0] cmap [16];
  logic [3:0]  map_idx;
  assign map_a = map_idx;

  // What each screen puts on the three channels at this pixel, and which of them
  // wins.  The color board is drawn OVER the first display where both are shown
  // and both cover the pixel.
  logic        m_lit, m_show, c_show;
  logic [4:0]  nib_base;
  logic [23:0] c_rgb;
  assign nib_base = {color_nib, 2'b00};
  assign m_lit  = m_word[mono_bit] ^ BOW;
  assign m_show = de_c && en_m && m_in_c && !blackx[MONO];
  assign c_show = de_c && en_c && c_in_c && !blackx[COLR];
  assign c_rgb  = cmap[c_word[nib_base +: 4]];

  always_ff @(posedge pclk) begin
    if (prst) begin
      hc <= '0; vc <= '0;
      sel_s1 <= 2'b01; sel_s2 <= 2'b01; rot_s1 <= 2'd0; rot_s2 <= 2'd0;
      cfg_sel <= 2'b01; cfg_rot <= 2'd0;
      map_idx <= 4'd0;
      for (int c = 0; c < 16; c++) cmap[c] <= 24'd0;
      for (int s = 0; s < 2; s++) begin
        // **A SYNCHRONIZER MUST COME OUT OF RESET HOLDING WHAT ITS SOURCE COMES
        // OUT OF RESET HOLDING**, which is what makes "the two differ" mean a
        // fill and nothing else.  `fill_n` resets to zero and so do these; a
        // synchronizer resetting the other way would make the first line's test
        // true for the two or three clocks before the real value arrived, the
        // first line would take a bank nothing had filled, and every bank after
        // it would be one out --- so the whole picture would be shown one line
        // early, for ever.  Which is exactly what happened when the two were
        // reset apart, and what `tb/cadr_display_out_tb.cpp` caught by comparing
        // against a memory poisoned injectively in the address: line 30 came out
        // holding line 1's words.  Against a memory of zeros it would have
        // looked perfect.
        ack_sync[s] <= '0;
        consumed[s] <= 1'b0;
        req_tog[s]  <= 1'b0;
        blackx[s]   <= 1'b1;    // until a fill has landed, show nothing
        primed[s]   <= 1'b0;
        req_addr[s] <= '0;
        req_strided[s] <= 1'b0;
        // Not an address any job can have, so the first look always asks and the
        // first line always tries to take a bank.
        asked[s]    <= 32'hFFFF_FFFF;
        drawn[s]    <= 32'hFFFF_FFFF;
      end
      // `cfg_rot` comes out of reset upright, so the first line of the first
      // frame is each window's own base and the lead is one line.
      va_m <= VC_W'(1); va_c <= VC_W'(1);
      m_show_addr <= BASE;       m_ask_addr <= BASE;
      c_show_addr <= COLOR_BASE; c_ask_addr <= COLOR_BASE;
      settled  <= 1'b1;
      underrun <= 1'b0;
      // **THE LANES COME UP RUNNING**, whatever the timer says, and a
      // synchronizer comes out of reset holding what its source does ---
      // `slp_want` resets low.
      slp_want_s1 <= 1'b0;
      slp_want_s2 <= 1'b0;
      slp_mute    <= 1'b0;
      de <= 1'b0; hsync <= !HSYNC_POS; vsync <= !VSYNC_POS;
      red <= 8'd0; green <= 8'd0; blue <= 8'd0;
    end else begin
      for (int s = 0; s < 2; s++) ack_sync[s] <= {ack_sync[s][1:0], fill_n[s]};
      sel_s1 <= out_sel; sel_s2 <= sel_s1;
      rot_s1 <= rotate;  rot_s2 <= rot_s1;
      slp_want_s1 <= slp_want; slp_want_s2 <= slp_want_s1;

      hc <= hc_n;
      vc <= vc_n;

      // ---- the four line addresses, stepped once a line.  See the header:
      //      the addition here IS the multiplication that used to hang off
      //      `vc` on every pixel.  A frame top with a change of setting
      //      reloads all four below, and overrides this.
      if (hc == HC_W'(H_TOTAL - 1)) begin
        if (vc_n == '0) begin
          m_show_addr <= mono_first;
          c_show_addr <= color_first;
        end else begin
          if (mono_steps(vc_n))  m_show_addr <= m_show_addr + mono_step;
          if (color_steps(vc_n)) c_show_addr <= c_show_addr + color_step;
        end
        if (va_m == VC_W'(V_TOTAL - 1)) begin
          va_m       <= '0;
          m_ask_addr <= mono_first;
        end else begin
          va_m <= va_m + VC_W'(1);
          if (mono_steps(va_m + VC_W'(1))) m_ask_addr <= m_ask_addr + mono_step;
        end
        if (va_c == VC_W'(V_TOTAL - 1)) begin
          va_c       <= '0;
          c_ask_addr <= color_first;
        end else begin
          va_c <= va_c + VC_W'(1);
          if (color_steps(va_c + VC_W'(1))) c_ask_addr <= c_ask_addr + color_step;
        end
      end

      // ---- the settings, taken at the top of a frame and nowhere else
      //
      // **AND A CHANGE STARTS THE PIPELINE AGAIN RATHER THAN REPORTING A
      // FAULT.**  `primed` is what tells "nothing has been fetched yet" from
      // "the port fell behind", and a change of geometry is the first of those:
      // the buffers hold lines where bands are now wanted, what was asked for
      // is not what is now needed, and the first bank of the new shape cannot
      // have arrived.  Without this the sticky `underrun` would be set on every
      // board whose card names a setting, and would then mean nothing.
      if ((hc == HC_W'(H_TOTAL - 1)) && (vc == VC_W'(V_TOTAL - 1))) begin
        cfg_sel <= sel_s2;
        cfg_rot <= rot_next;
        // The lanes stop and start here and nowhere else: see "SLEEP".
        slp_mute <= slp_want_s2;
        // The shape about to be drawn starts at its own first line, so all four
        // addresses and both ahead-lines are reloaded here rather than stepped.
        m_show_addr <= mono_first_next;
        c_show_addr <= color_first_next;
        va_m <= look_m_next;  m_ask_addr <= mono_first_next;
        va_c <= look_c_next;  c_ask_addr <= color_first_next;
        settled <= 1'b1;
        if ((cfg_sel != sel_s2) || (cfg_rot != rot_next)) begin
          primed[MONO] <= 1'b0;
          primed[COLR] <= 1'b0;
          settled      <= 1'b0;
        end
      end

      // ---- the first pixel of a line: take the new bank, then ask for what the
      //      line `LOOK` ahead will want.  **The order matters.**  The raster
      //      takes over the bank filled while the last one was being shown, and
      //      only then asks for the next; doing both at the END of a line
      //      instead is off by one and shows every line one late.
      if (hc == '0) begin
        if (en_m && (m_show_addr != drawn[MONO])) begin
          drawn[MONO] <= m_show_addr;
          if (ack_sync[MONO][2] != consumed[MONO]) begin
            consumed[MONO] <= ack_sync[MONO][2];
            blackx[MONO]   <= 1'b0;
            if (settled) primed[MONO] <= 1'b1;
          end else begin
            blackx[MONO] <= 1'b1;
            if (primed[MONO]) underrun <= 1'b1;
          end
        end
        if (en_c && (c_show_addr != drawn[COLR])) begin
          drawn[COLR] <= c_show_addr;
          if (ack_sync[COLR][2] != consumed[COLR]) begin
            consumed[COLR] <= ack_sync[COLR][2];
            blackx[COLR]   <= 1'b0;
            if (settled) primed[COLR] <= 1'b1;
          end else begin
            blackx[COLR] <= 1'b1;
            if (primed[COLR]) underrun <= 1'b1;
          end
        end
        // And the request, when what will be wanted is not what was last asked
        // for.  A screen that is not shown is not fetched: that is a setting and
        // not a position, so it is constant for the whole frame and the rule
        // "one fill a change" still describes every fill.
        if (en_m && (m_ask_addr != asked[MONO])) begin
          asked[MONO]       <= m_ask_addr;
          req_addr[MONO]    <= m_ask_addr;
          req_strided[MONO] <= rot_on;
          req_tog[MONO]     <= ~req_tog[MONO];
        end
        if (en_c && (c_ask_addr != asked[COLR])) begin
          asked[COLR]       <= c_ask_addr;
          req_addr[COLR]    <= c_ask_addr;
          req_strided[COLR] <= rot_on;
          req_tog[COLR]     <= ~req_tog[COLR];
        end
      end

      // ---- the color map's copy, one entry a line, taken eight pixels after
      //      the index went out: see the header for the crossing it is.
      if (hc == HC_W'(8)) begin
        cmap[map_idx] <= map_q;
        map_idx       <= map_idx + 4'd1;
      end

      // ---- the outputs
      de    <= de_c;
      hsync <= HSYNC_POS ? hs_c : !hs_c;
      vsync <= VSYNC_POS ? vs_c : !vs_c;
      // Blanking is black by the specification.  The border is black because it
      // is not the CADR's screen --- see the header --- so it does not follow
      // `BOW`.
      if (c_show) begin
        red <= c_rgb[23:16]; green <= c_rgb[15:8]; blue <= c_rgb[7:0];
      end else if (m_show && m_lit) begin
        red <= 8'hFF; green <= 8'hFF; blue <= 8'hFF;
      end else begin
        red <= 8'h00; green <= 8'h00; blue <= 8'h00;
      end
    end
  end

endmodule

`default_nettype wire
