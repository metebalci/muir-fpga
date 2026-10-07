// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A board's machine as an `rtl` checkpoint body: `Machine::save` and then the
// `Rtl` tail, field for field, in muir's own order.
//
// **EVERY FIELD IS EITHER SOMETHING THE BOARD SAID OR SOMETHING THIS FILE
// DECIDED, AND WHICH IS WHICH IS MARKED.**  A comment beginning `READ` is a
// value that came out of the fabric; one beginning `IDLE` is a value muir's
// own freshly built machine has and the fabric has no reading for; one
// beginning `NONE` is a thing the fabric does not have at all.  `chk_missing`
// at the bottom is that list in one place, printed by
// `cadr-checkpoint --what-it-cannot-read`, and `docs/checkpoint.md` carries
// the same list in prose, so that nobody has to trust this comment.
//
// **THE FILE IS OF A QUIET MACHINE AND THAT IS WHAT MAKES IT POSSIBLE.**
// muir's `Rtl` carries a bus cycle's whole flight --- the address and word in
// the air, the responder, three absolute deadlines and the bus interface's
// own state machine --- and the fabric keeps none of those in a form this
// window can read, because they are tick-scale counters that
// `cadr_machine.xdc` names FAST and a mux out of one of them would be timed
// at a single tick.  What makes that survivable is muir's own rule for a
// netlist checkpoint: it is "taken where `FarEnd::quiet` says it may be,
// between cycles with nothing in flight".  A machine the console has halted
// at a microcycle boundary is such a point, and every in-flight field is then
// at the value a machine that has never issued a cycle has.
//
// **WHAT THAT COSTS, SAID PLAINLY: the resumed machine's CLOCK is not the
// board's.**  `ns` is the fabric's own tick count times MIT's ten-nanosecond
// grid, which is real; the bus interface's memory-board refresh model and the
// I/O board's two clocks restart from their power-on state.  A resumed
// machine therefore computes what the board would have computed and its
// refresh one-shot fires once, early, for nothing.  It is the one place this
// file knowingly hands muir a machine that is not bit-for-bit the board's,
// and it is here rather than hidden because a checkpoint that invented state
// silently would be worse than none.

#include "chk_rtl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- the constants a fresh muir machine has --------------------------------
//
// Every one of these is muir's, cited at the line that uses it.  They are
// here and not inline so that a muir that moves can be met in one place.

// `busint::interrupt_status::LOCAL_ENABLE`, src/busint.rs:1018.
#define MUIR_LOCAL_ENABLE 0002u
// `machine.rs:780`, `LVMO_AT_POWER_ON` --- the value the fabric also comes up
// with, so this is a cross-check and not an invention.
#define MUIR_LVMO_AT_POWER_ON 0x00C03FFFu
// `Busint::with_timing_model`'s `MemoryBoard::with_timing_model`, under
// `TimingModel::Fpga`, src/busint.rs:437-461: the three derived instants and
// the board's own next change, each crystal edge taken at the first tick at or
// after it and the refresh one-shot rounded up from its trigger --- 1,416,
// 958, 12,991 and 12,992 on the board's own time.
#define MUIR_MB_IDLE_AT 1420u
#define MUIR_MB_TIME_OFF_AT 960u
#define MUIR_MB_REFRESH_TIME_AT 13000u
#define MUIR_MEMORY_NEXT 13001u
// `Responder::NoUnibus`, tag 10; `Responder::Memory(b)`, tag 0.
#define MUIR_RESP_MEMORY 0u
#define MUIR_RESP_NOUNIBUS 10u
// `tv::BUFFER_WORDS` and the sync RAM, and `SyncRam::default`'s enable.
#define MUIR_TV_SYNC_ENABLE 0u
// The tag `Tv::save` writes for the board, src/tv.rs:932-935: the SIMPLE TV
// is 0 and the LISPM TV is 1.
#define MUIR_TV_BOARD_SIMPLE 0u
// `tv::COLORS` times `tv::CHANNELS`, src/tv.rs:225 and :233: sixteen colors
// of three channels each, and `Tv::save` writes them a byte at a time with no
// count in front of them.
#define MUIR_TV_COLOR_CHANNELS  3u
#define MUIR_TV_COLOR_MAP_BYTES (16u * MUIR_TV_COLOR_CHANNELS)
// muir's own `chaos::Config::default().address`, src/chaos/mod.rs:139.
#define MUIR_CHAOS_ADDRESS 0177001u
// `Geometry::CADR`, src/machine.rs: a level-1 map entry of five bits, a PDL
// pointer and index of ten, and no multiply and divide instructions.
// `Machine::save` writes the three after the level-1 map, and `Machine::load`
// takes (5, 10, false) as the CADR.
#define MUIR_L1_BITS 5u
#define MUIR_PDL_BITS 10u
#define MUIR_MULDIV 0u
// QUUX's clocks are not the CADR's either: `Geometry::CADR.tick` is false,
// and `Timers::new` (src/machine.rs) is what a CADR's machine holds --- three
// interval timers in their reset state, each off, periodic, its interrupt
// enable 0, its period 0 and no deadline, `u64::MAX` (version 45, contract
// Q11; before it, Q1's tick and interval timer).
#define MUIR_TICK 0u
#define MUIR_TIMERS 3u
// The size QUUX's video controller would have, which `Tv::save` writes for
// every board: `tv::VIDEO_WIDTH` by `VIDEO_HEIGHT`, the default a CADR's
// display keeps and never uses.  1280 by 1024 since muir's `200818f`, the
// HDMI mode this fabric's boards drive; 1920 by 1080 before it.
#define MUIR_VIDEO_WIDTH 1280u
#define MUIR_VIDEO_HEIGHT 1024u
// **THE ARRAYS ARE muir's LARGEST MACHINE'S, NOT THE CADR's.**  `PDL_WORDS`
// and `L2_MAP_WORDS` in src/machine.rs are QUUX's sixteen thousand PDL words
// and two thousand level-2 entries, so that one `Machine` holds either
// machine; a CADR uses the first 1,024 of each and `Machine::new` leaves the
// rest zero.  The fabric is a CADR and has only those 1,024, so the file
// carries the words read and then zeros, which is what muir's own CADR
// would write.
#define MUIR_PDL_WORDS (16u * 1024u)
#define MUIR_L2_MAP_WORDS 2048u

// `w.u32s` over one of muir's arrays of which the fabric holds the first
// `have` words: the count muir's array has, the words read, then zeros.
static void emit_u32s_padded(struct chk *w, const uint32_t *v, size_t have,
			     size_t total)
{
	chk_u64(w, (uint64_t)total);
	for (size_t i = 0; i < total; ++i)
		chk_u32(w, i < have ? v[i] : 0u);
}

// And `w.words` over one: words at the machine's width.
static void emit_words_padded(struct chk *w, const uint64_t *v, size_t have, size_t total)
{
	chk_u64(w, (uint64_t)total);
	for (size_t i = 0; i < total; ++i)
		chk_word(w, i < have ? v[i] : 0u);
}

// **REVISION 13** (contract G2 appendix A1.13; muir's `Geometry::QUUX`):
// a level-1 entry of seven bits; level 2 in 4,096 entries, `L2_MAP_WORDS`,
// every one of which the machine has; and the cache's 8-word lines, the lines
// of packed storage (`memory_port::Layout::REVISION_13`).
#define MUIR_QUUX13_L1_BITS    7u
#define MUIR_QUUX13_L2_WORDS   4096u
#define MUIR_QUUX13_CACHE_LINE 8u

// --- Machine ---------------------------------------------------------------

static void emit_mode(struct chk *w, const struct cadr_image *img)
{
	// `spy::Mode::save`: six bools.  READ, all but one: the mode register
	// is write-only on the diagnostic bus --- `Engine::spy_read` carries
	// `PROMDISABLE` in FLAG-1 and none of the other five --- so the
	// readout's register table brings `errstop`, `stathenb` and the two
	// speed bits out of `cadr_spy_registers` directly.
	chk_bool(w, img->mode_speed & 1u);		/* READ speed0 */
	chk_bool(w, (img->mode_speed >> 1) & 1u);	/* READ speed1 */
	chk_bool(w, img_flag(img, IMG_F_ERRSTOP));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_STATHENB));	/* READ */
	// NONE: `cadr_spy_registers.sv` drops the mode register's bit 4.
	// TRAPENB gates MIT's boot trap and the fabric raises the trap from
	// reset instead, so there is no bit to read.
	chk_bool(w, 0);					/* NONE trapenb */
	chk_bool(w, img_flag(img, IMG_F_PROMDISABLED));	/* READ */
}

static void emit_clock_control(struct chk *w, const struct cadr_image *img)
{
	// `spy::ClockControl::save`: five bools.  All five are in the fabric
	// --- `cadr_spy_registers.sv` stores the whole of register 3 --- but
	// only RUN is brought out where this program can read it, so the other
	// four are NONE and are written clear.  That is what a halted machine
	// holds: a console writes `2` and then `0`, and a checkpoint is taken
	// with the machine stopped, so the four are down when it is read.
	chk_bool(w, img_flag(img, IMG_F_RUN));		/* READ */
	chk_bool(w, 0);					/* NONE step */
	chk_bool(w, 0);					/* NONE nop11 */
	chk_bool(w, 0);					/* NONE idebug */
	chk_bool(w, 0);					/* NONE ldstat */
}

static void emit_opc_control(struct chk *w)
{
	// `spy::OpcControl::save`: three bools.  NONE, all of them ---
	// register 4 is dropped by the register block, so LPC-HOLD, OPCCLK and
	// OPCINH do not exist in this fabric.  False is also what the fabric
	// BEHAVES as: `lpc` follows `pc` at every boundary and the shift
	// register shifts at every one, which is those three bits clear.
	chk_bool(w, 0);
	chk_bool(w, 0);
	chk_bool(w, 0);
}

// `disk_controller.rs`'s `Controller::save`, and `disk_unit.rs`'s
// `Unit::save` for each attached drive.
//
// **IDLE, WHOLE, AND THIS IS THE LARGEST THING THE WINDOW CANNOT READ.**  The
// fabric's `cadr_disk_controller.sv` has a command register, a command-list
// pointer, a disk address, eight error flops, eight unit slots with their
// heads and their attention timers and a channel walking a block --- none of
// it reachable, the readout window ending at `cadr_microcycle`'s memories.
// So the checkpoint carries a controller that has just been built.
//
// What that costs: a transfer in flight when the board was halted is lost,
// and the resumed machine's next look at the controller finds it idle with
// no error.  The microcode's own retry would cover a lost transfer; a
// half-walked command list would not.  **Halt the board between transfers**
// --- the disk light is the instrument for that --- or expect the cold boot
// to be re-driven.
//
// The drives themselves are NOT lost, and that is worth being clear about: a
// pack is a file a resume opens again, never a thing in the checkpoint, and
// the board's own pack on the card is written through by `cadr-disk-packs`.
// What `Unit::save` carries is muir's in-memory differences from that file,
// which on the board are none.  So a freshly attached drive over the same
// pack file IS the board's drive, bar its head position.
// `disk_unit.rs`'s `Unit::save`, for a drive the bay holds: the CADR
// controller's unit `u`, or on QUUX block-disk's one pack, unit 0.
static void emit_unit(struct chk *w, const struct chk_declared *d, unsigned u)
{
	// **THE GEOMETRY IS THE PACK FILE'S OWN SIZE**, taken exactly as
	// `cadr-disk-packs` takes it, and muir refuses a checkpoint whose
	// geometry is not the resuming drive's --- so this is a reading of the
	// drive bay and not a claim of this program's.
	chk_u32(w, d->cylinders[u]);	/* DECLARED geometry */
	chk_u32(w, d->heads[u]);
	chk_u32(w, d->blocks_per_track[u]);
	chk_u64(w, 0);		/* IDLE written, no blocks */
	// DECLARED: the write-protect switch, which on the board is the pack
	// file's own read-only mark.
	chk_bool(w, d->read_only[u]);
	chk_u32(w, 0);		/* IDLE cylinder --- the heads at zero */
	chk_u32(w, 0);		/* IDLE head */
	chk_u32(w, 0);		/* IDLE block */
	chk_bool(w, 0);		/* IDLE seek_error */
	chk_bool(w, 0);		/* IDLE fault */
	chk_u64(w, ~(uint64_t)0);	/* IDLE attention_at: none */
	chk_u64(w, 0);		/* IDLE headers, none */
	chk_u64(w, 0);		/* IDLE data_checkwords, none */
}

static void emit_disk(struct chk *w, const struct chk_declared *d)
{
	chk_u64(w, 0);		/* IDLE timed --- a u64 carrying a bool */
	chk_u64(w, 0);		/* IDLE done_at */
	chk_u64(w, 0);		/* IDLE now */
	chk_u32(w, 0);		/* NONE cmd */
	chk_u32(w, 0);		/* NONE clp */
	chk_u32(w, 0);		/* NONE da */
	chk_bool(w, 0);		/* NONE header_ecc */
	chk_bool(w, 0);		/* NONE header_compare */
	chk_bool(w, 0);		/* NONE ecc_hard */
	chk_bool(w, 0);		/* NONE ecc_soft */
	chk_u32(w, 0);		/* NONE ecc */
	chk_bool(w, 0);		/* NONE read_compare_difference */
	chk_u64s(w, NULL, 0);	/* IDLE dma_written, empty */
	chk_bool(w, 0);		/* NONE ccw_cycle */
	chk_bool(w, 0);		/* NONE nxm */
	chk_bool(w, 0);		/* NONE timeout */
	chk_bool(w, 0);		/* NONE overrun */
	chk_u32(w, 0);		/* NONE last_memory_address */

	// The eight unit slots.  A flag and then the unit if it is there ---
	// muir writes this by hand rather than through `opt`, and the two are
	// the same bytes.  **`Controller::load` refuses a checkpoint that says
	// a drive is present where the resuming machine has none**, so what is
	// written here has to match the `--disk-pack`s the resume is given.
	for (unsigned u = 0; u < 8; ++u) {
		if (!((d->present >> u) & 1u)) {
			chk_bool(w, 0);
			continue;
		}
		chk_bool(w, 1);
		emit_unit(w, d, u);
	}
}

// `tv.rs`'s `Tv::save`, fixed 135,259 bytes.
//
// **THE PICTURE IS REAL AND NOTHING ELSE HERE IS.**  The display block writes
// the frame buffer into the display's own region of DDR, which Linux can map,
// so the 32,768 words are the board's own screen word for word.  The mode
// register, the sync RAM and the vertical-interrupt flag are inside
// `cadr_tv.sv` and the readout window does not reach them: the sync RAM is
// 4,096 bytes and no readout reaches it, and the flag is one bit that the
// resumed machine will set again at its next frame.  **THE COLOR MAP IS
// READ**, off the console face's page 4 --- register 4 is write only on the
// Xbus, so that page is the only way to ask what a color is.
static void emit_tv(struct chk *w, const struct cadr_image *img)
{
	// **WHICH OF THE TWO DISPLAY BOARDS THIS IS, DECLARED AND NOT READ.**
	// `cadr_tv.sv` comes up as MIT's SIMPLE TV and the console face's page
	// 2 word 33 can strap it as the LISPM TV, `--tv-board` on the card.
	// This program does not read that word, so it writes the SIMPLE TV: a
	// checkpoint of a board strapped the other way declares the wrong board.
	// muir cross-checks it: `resume_engine` (src/main.rs:3524-3531)
	// compares the loaded board against `--tv-board` and refuses by name,
	// so a resume given the board's own setting says so rather than running
	// the wrong machine.
#if CHK_MUTATE == 4
	// The other board's tag.  It LOADS --- `Tv::load` takes 0, 1 and
	// QUUX's 2 and refuses anything else --- and the body is the same length, so only
	// muir's own cross-check against `--tv-board` can say anything.
	chk_u8(w, 1);
#else
	chk_u8(w, MUIR_TV_BOARD_SIMPLE);	/* DECLARED board */
#endif
	chk_u16(w, MUIR_VIDEO_WIDTH);		/* NONE video_size */
	chk_u16(w, MUIR_VIDEO_HEIGHT);
	chk_u32s(w, img->tv, IMG_TV_WORDS);	/* READ, out of DDR */
	chk_u32(w, 0);				/* NONE mode */
	static const uint8_t zero_sync[IMG_TV_SYNC] = { 0 };
	chk_bytes(w, zero_sync, IMG_TV_SYNC);	/* NONE sync.words */
	chk_u16(w, 0);				/* NONE sync.pointer */
	chk_u8(w, MUIR_TV_SYNC_ENABLE);		/* NONE sync.enable */
	// The color map, sixteen colors of three channels: **bare bytes with
	// NO COUNT in front of them**, because `Tv::save` writes them `w.u8` at
	// a time (src/tv.rs:939-943) and not through `w.bytes`.  A count here
	// would shift every byte after it.
	//
	// **IT IS READ NOW AND IT USED TO BE WRITTEN AS ZEROS.**  Register 4 is
	// write only on the Xbus --- the RAMs and their converters are off the
	// board --- so no bus cycle can be asked what the map is; the fabric
	// keeps the sixteen entries as muir's `tv::Tv::color_map` does and
	// offers them on the console face's page 4, which is where `img->tv_map`
	// came from.  This is the FIRST display board's map, because the
	// section being written is the machine's `tv`.
	//
	// The rest of this section is still NONE, and that is not made better
	// by the map arriving: the sync RAM is 4,096 bytes and no readout
	// reaches it, so a resumed machine's display is the map it had with
	// MIT's PROM running.  `chk_rtl_missing` says so.
	for (unsigned i = 0; i < MUIR_TV_COLOR_MAP_BYTES; ++i) {
#if CHK_MUTATE == 5
		// Every gun at full, which is a map somebody has written and
		// not the one this board has.  Forty-eight bytes in the right
		// slots with the wrong values: it loads, muir re-saves it byte
		// for byte, and the digest is the only thing that can see it.
		chk_u8(w, 0xffu);
#else
		chk_u8(w, img->tv_map[i / MUIR_TV_COLOR_CHANNELS][i % MUIR_TV_COLOR_CHANNELS]);
#endif
	}
	chk_bool(w, 0);				/* NONE flag_written */
	chk_u64(w, 0);				/* NONE written_at */
	// When the running sync program last started from its location 0
	// (src/tv.rs:431-434).  Zero is `Tv::default`'s, which says the program
	// has been running since the machine came up.  The fabric does run the
	// sync program, and restarts it at a write of its RAM, a change of the
	// RAM's enable or a change of the clock mode, but nothing reads out when
	// that last was, so zero is written.  `Tv::load` runs the timeline afresh
	// from it, so a resume measures the frame from power-on, whatever phase
	// the board's own program had reached.
#if CHK_MUTATE == 6
	// The machine's own clock in place of zero: "the sync program started
	// when the checkpoint was taken" rather than "it has been running
	// since power-on".  A plausible misreading, a legal value --- muir
	// only needs `ns >= origin` --- and so another one for the digest.
	chk_u64(w, img->ticks * CHK_GRID_NS);
#else
	chk_u64(w, 0);				/* NONE origin */
#endif
	// The sync bits the mode register was holding when the running program
	// started, which it goes on reading until that program's first
	// instruction lands (src/tv.rs:435-441).  The 74LS175 at NSYREG 0D02
	// has its clear on a pull-up, so the register holds what the program
	// before it left and a restart does not touch it.  Zero is
	// `Tv::default`'s and is what power-on leaves in a register that has
	// never been clocked, which is right for a resume whose origin is zero:
	// the program has been running since the machine came up and there is
	// no program before it to have left anything.
	chk_bool(w, 0);				/* NONE sync_held.0, HSYNC */
	chk_bool(w, 0);				/* NONE sync_held.1, VSYNC */
}

// `serial.rs`'s `Pci::save`, fixed 110 bytes, all of it IDLE: the CADR's
// serial line is in `cadr_io_board.sv` and has no readout.
static void emit_serial(struct chk *w)
{
	static const uint8_t regs[6] = { 0, 0, 0, 0, 0, 0 };
	chk_bytes(w, regs, 6);		/* mode1 mode2 command errors next_syn rhr */
	static const uint8_t syn[3] = { 0, 0, 0 };
	chk_bytes(w, syn, 3);
	chk_bool(w, 0);			/* second_mode */
	chk_bool(w, 0);			/* tx_empty */
	chk_bool(w, 0);			/* rx_ready */
	chk_bool(w, 0);			/* dschg */
	chk_bool(w, 0);			/* dsr_was */
	chk_bool(w, 0);			/* dcd_was */
	static const uint64_t froms[2] = { 0, 0 };
	chk_u64s(w, froms, 2);		/* tx_from, rx_from */
	// **THE FLAG-THEN-ALWAYS-THE-VALUE ENCODING**, which is not `opt`:
	// muir writes the flag and then the value whatever the flag said, so
	// omitting the value here would shift every byte after it.
	chk_bool(w, 0);			/* generator_from.is_some() */
	chk_u64(w, 0);			/* ... and its value, always */
	chk_bool(w, 0);			/* thr.is_some() */
	chk_u8(w, 0);
	chk_u64(w, 0);
	chk_bool(w, 0);			/* shifting.is_some() */
	chk_u8(w, 0);
	chk_u64(w, 0);
	chk_bool(w, 0);			/* assembling.is_some() */
	chk_u8(w, 0);
	static const uint64_t rx[2] = { 0, 0 };
	chk_u64s(w, rx, 2);		/* done, ends */
}

// `chaos/board.rs`'s `Interface::save`.
//
// **IT HAS TO BE THERE, AND NONE OF IT CAN BE READ.**  The fabric's Chaosnet
// interface is on the I/O board, which the readout window does not reach.
// `Machine::with_memory_boards` plugs one in and `IoBoard::load` refuses a
// checkpoint that has none where the machine does --- and then refuses again
// if the switches disagree with the address the resume was given.  So this is
// written at muir's own default and `--chaos-address` moves it.
static void emit_chaos(struct chk *w, const struct chk_declared *d)
{
	chk_u16(w, (uint16_t)d->chaos_address);	/* DECLARED */
	chk_u16(w, 0);		/* csr */
	// **TRUE**: `Interface::new` starts with the transmitter done, which
	// is what an interface with nothing to send is.  Found the same way as
	// the mouse's phases.
	chk_bool(w, 1);		/* transmit_done */
	chk_bool(w, 0);		/* transmit_abort */
	chk_bool(w, 0);		/* receive_done */
	chk_bool(w, 0);		/* crc_error */
	chk_u8(w, 0);		/* lost */
	chk_u16s(w, NULL, 0);	/* xmit */
	chk_u16s(w, NULL, 0);	/* rcv */
	chk_u64(w, 0);		/* rcv_at */
	chk_u64(w, 0);		/* rcv_bits */
	chk_opt_u64(w, 0, 0);	/* tdone_at, a real opt */
	chk_u64(w, 0);		/* incoming.len() */
	/* Turn::save */
	chk_u64(w, 0);		/* powered_at */
	chk_u64(w, 0);		/* taken */
	chk_bool(w, 0);		/* q */
	chk_u8(w, 0);		/* low */
	chk_u64(w, 0);		/* frames.len() */
	chk_bool(w, 0);		/* ready.is_some() */
	chk_u64(w, 0);		/* polled */
}

// `ioboard.rs`'s `IoBoard::save`.  IDLE throughout: the keyboard, the mouse,
// the microsecond clock and the sixty-cycle interval are in
// `cadr_io_board.sv`, which the readout window does not reach.
//
// **THE MICROSECOND CLOCK IS THE ONE THAT MATTERS** --- `(TIME)` is that
// counter shifted, and off it hang the wall clock, `PROCESS-SLEEP`, every
// Chaosnet timer and the scheduler --- so a resumed machine's notion of the
// time of day starts again from zero.  Nothing the machine computes depends
// on it being continuous; what it will see is one very long or very short
// interval at the seam.
static void emit_ioboard(struct chk *w, const struct chk_declared *d)
{
	chk_u16(w, 0);		/* NONE csr */
	chk_u32(w, 0);		/* NONE scancode */
	chk_u32(w, 0);		/* NONE usec */
	chk_u16(w, 0);		/* NONE interval */
	chk_bool(w, 0);		/* NONE interval_loaded_at.is_some() */
	chk_u64(w, 0);		/* ... and its value, ALWAYS written */
	chk_u32(w, 0);		/* NONE mouse.encoders.dx */
	chk_u32(w, 0);		/* NONE mouse.encoders.dy */
	// **TWO, AND NOT ZERO.**  `Encoders::default` starts both quadrature
	// phases at 2 (`terminal/mouse.rs:68`), which is Gray `11` with both
	// lines high; `lines()` inverts, so the four bits the card reads are
	// still clear.  A zero here loads and is a mouse half a step from
	// where a fresh one stands --- the kind of wrong value that only a
	// byte comparison against muir's own file would ever find, and did.
#if CHK_MUTATE == 1
	// The value a fresh mouse does NOT have.  It loads, and muir's re-save
	// differs in two bytes --- which is the only kind of evidence a byte
	// comparison gives and an exit code does not.
	chk_u8(w, 0);
	chk_u8(w, 0);
#else
	chk_u8(w, 2);		/* NONE mouse.encoders.x_phase */
	chk_u8(w, 2);		/* NONE mouse.encoders.y_phase */
#endif
	chk_u64(w, 0);		/* NONE mouse.encoders.next */
	chk_u8(w, 0);		/* NONE mouse.switches */
	chk_u8(w, 0);		/* NONE mouse.new */
	chk_u8(w, 0);		/* NONE mouse.old */
	chk_u16(w, 0);		/* NONE mouse.x */
	chk_u16(w, 0);		/* NONE mouse.y */
	chk_u64(w, 0);		/* NONE mouse.sampled */
	chk_bool(w, 0);		/* NONE audio */
	chk_opt_u64(w, 0, 0);	/* NONE audio_click_ns, a real opt */
	chk_bool(w, 0);		/* NONE beep_started */
	emit_serial(w);		/* written BEFORE chaos, against declaration order */
	chk_bool(w, 1);		/* chaos is there: see emit_chaos */
	emit_chaos(w, d);
}

// `busint.rs`'s `Busint::save`, at `Busint::new(boards)`: the idle image, and
// every number in it is muir's own.
static void emit_busint(struct chk *w, const struct cadr_image *img)
{
	chk_u8(w, 0);			/* IDLE State::Idle */
	chk_bool(w, 0);			/* IDLE write */
	chk_u64(w, img->boards);	/* the board count, its THIRD appearance */
	for (unsigned b = 0; b < img->boards; ++b) {
		chk_u64(w, MUIR_MB_IDLE_AT);
		chk_u64(w, 0);				/* release_at */
		chk_u64(w, MUIR_MB_REFRESH_TIME_AT);
		chk_u64(w, MUIR_MB_TIME_OFF_AT);
		chk_u8(w, 0);				/* refresh_stage */
		chk_u64(w, 0);				/* refresh_rq_at */
		chk_bool(w, 0);				/* in_reset */
	}
	chk_opt_u8(w, 0, 0);		/* board */
	chk_u64(w, 0);			/* device_ns, IDEAL_DEVICE_NS */
	chk_bool(w, 0);			/* unibus_master */
	chk_opt_u64(w, 0, 0);		/* memrq_up_at */
	chk_u64(w, ~(uint64_t)0);	/* debug_sack_at */
	chk_bool(w, 0);			/* msyn_down_before_edge */
	chk_bool(w, 0);			/* lm_need_ub */
	chk_u8(w, 0);			/* grant_hold */
	chk_u8(w, 0);			/* Debug::Idle */
	chk_bool(w, 0);			/* debug_request, a real opt */
	chk_u64(w, 0);			/* debug_requested_at */
	chk_u64(w, 0);			/* granted_at */
	chk_u8(w, MUIR_RESP_NOUNIBUS);	/* debug_responder */
	chk_u16(w, 0);			/* debug_address */
	chk_u16(w, 0);			/* debug_modifier */
	chk_u64(w, 0);			/* debug_freed_at */
	chk_u64(w, ~(uint64_t)0);	/* debug_ack */
	chk_u64(w, ~(uint64_t)0);	/* debug_answered */
	chk_bool(w, 0);			/* debug_cable */
	chk_bool(w, 0);			/* debug_out, a real opt */
	chk_bool(w, 0);			/* debug_out_pending */
	chk_u64(w, ~(uint64_t)0);	/* debug_out_timeout_at */
	chk_u64(w, MUIR_MEMORY_NEXT);	/* memory_next */
	// Version 36: QUUX's memory cache and its own memory timing, neither of
	// which a CADR has, and the cycle's address and hit that only the cache
	// reads: `Busint::new` holds each as written here.
	chk_bool(w, 0);			/* NONE cache, an opt */
	chk_u32(w, 0);			/* IDLE addr */
	chk_bool(w, 0);			/* IDLE cached */
	chk_u64(w, 0);			/* IDLE buffer_free_at */
	chk_bool(w, 0);			/* NONE memory_timing, an opt */
	chk_u64(w, 0);			/* IDLE memory_free_at */
}

// `rtl.rs`'s `Bus`, version 40: which of the two the processor's cycles go
// through, written before it --- `Bus::Cadr`, the bus interface above, or
// `Bus::Quux`, QUUX's memory port below (contract Q6).
#define MUIR_BUS_CADR 0u
#define MUIR_BUS_QUUX 1u

// `CacheConfig::QUUX`, src/cache.rs: 4,096 words in lines of 4, 2-way, a hit
// in 20 ns and the write buffer; `MemoryTiming::NOMINAL`: a line fill in
// 380 ns, a write in 290.  The fabric's cache is this shape
// (`rtl/machine/quux_cache.sv`).
#define MUIR_QUUX_CACHE_WORDS 4096u
#define MUIR_QUUX_CACHE_LINE  4u
#define MUIR_QUUX_CACHE_WAYS  2u
#define MUIR_QUUX_CACHE_HIT_NS 20u
#define MUIR_QUUX_READ_NS  380u
#define MUIR_QUUX_WRITE_NS 290u

// `memory_port.rs`'s `MemoryPort::save`, at `MemoryPort::new()`: no cycle in
// flight, and the cache as a fresh port holds it --- EMPTY, with no hits and
// no misses.  muir restores a cache warm; this file restores it cold, so a
// resumed machine misses where muir's saved one would have hit.  That moves
// when a read is answered and never which word it reads, because the cache
// is write-through and every line it holds equals main memory.  Main memory
// is free: a halt drains the write buffer before this program reads the
// machine, so `memory_free_at` and `buffer_free_at` are in the past, and 0
// is a past as good as any.
static void emit_memory_port(struct chk *w, const struct cadr_image *img)
{
#if CHK_MUTATE == 27
	const unsigned line = MUIR_QUUX_CACHE_LINE;
#else
	const unsigned line = img->rev13 ? MUIR_QUUX13_CACHE_LINE : MUIR_QUUX_CACHE_LINE;
#endif
	chk_u8(w, 0);			/* IDLE State::Idle */
	chk_bool(w, 0);			/* IDLE write */
	chk_u32(w, 0);			/* IDLE addr */
	chk_bool(w, 0);			/* IDLE memory */
	chk_u32(w, MUIR_QUUX_CACHE_WORDS);	/* Cache::save: config.words */
	chk_u32(w, line);			/* config.line_words */
	chk_u32(w, MUIR_QUUX_CACHE_WAYS);	/* config.ways */
	chk_u64(w, MUIR_QUUX_CACHE_HIT_NS);	/* config.hit_ns */
	chk_bool(w, 1);				/* config.write_buffer */
	chk_u64(w, 0);				/* NONE hits */
	chk_u64(w, 0);				/* NONE misses */
	for (unsigned s = 0; s < MUIR_QUUX_CACHE_WORDS / (line * MUIR_QUUX_CACHE_WAYS); ++s)
		chk_u32(w, 0);			/* NONE the set's lines: cold */
	chk_u64(w, MUIR_QUUX_READ_NS);		/* timing.read_ns */
	chk_u64(w, MUIR_QUUX_WRITE_NS);		/* timing.write_ns */
	chk_u64(w, 0);				/* IDLE memory_free_at */
	chk_u64(w, 0);				/* IDLE buffer_free_at */
	// Version 49: revision 12's cache-only prefetch, its word with the
	// word's virtual and physical addresses, and a fetch the port is yet to
	// answer, each an option (`MemoryPort::save`).  READ, off the register
	// table's entries 37 to 40, which are the buffer as the last master
	// clock edge left it: a halted machine's master clock runs, so that is
	// the buffer.
	chk_bool(w, img->qx.pf_v);			/* READ prefetched */
	if (img->qx.pf_v) {
		chk_u32(w, img->qx.pf_vaddr);
		chk_u32(w, img->qx.pf_phys);
		chk_word(w, img->qx.pf_word);
	}
	chk_bool(w, img->qx.fetch_v);			/* READ fetch_vaddr */
	if (img->qx.fetch_v)
		chk_u32(w, img->qx.fetch_vaddr);
	// Revision 14: the reference's write-back's end, which a cycle waits
	// for (A14.6); past, as `memory_free_at` is.
#if CHK_MUTATE != 45
	if (img->rev14)
		chk_u64(w, 0);				/* IDLE write_back_until */
#endif
}

// `MacroDispatch::save`, version 49 (revision 12, contract H8a): the
// MACRO-DISPATCH register, the MACRO DISPATCH MEMORY's index and its 1,024
// entries, the base copies, and the operand address and M 31's word a fused
// return armed, each an option.  QUUX's READ off the register table's
// entries 29 to 33 and selector 13; the CADR's as `MacroDispatch::default`
// holds them, which a CADR never writes.
static void emit_macro_dispatch(struct chk *w, const struct cadr_image *img, int quux)
{
	const struct quux_state *q = &img->qx;
	static const uint32_t none[IMG_QUUX_MACRO_ENTRIES] = { 0 };
	chk_u32(w, quux ? q->macro_reg : 0u);		/* READ register */
	chk_u16(w, quux ? (uint16_t)q->macro_index : 0u);	/* READ index */
	chk_u32s(w, quux ? q->macro_entries : none, IMG_QUUX_MACRO_ENTRIES);	/* READ */
	chk_u32(w, quux ? q->localp : 0u);		/* READ localp */
	chk_u32(w, quux ? q->ap : 0u);			/* READ ap */
	chk_bool(w, quux && q->opr_v);			/* READ operand */
	if (quux && q->opr_v) {
		chk_bool(w, q->opr_arg);
		chk_u8(w, (uint8_t)q->opr_delta);
	}
	chk_bool(w, quux && q->m31_v);			/* READ m31 */
	if (quux && q->m31_v)
		chk_word(w, q->m31_w);
}

// --- QUUX ------------------------------------------------------------------
//
// **WHAT A QUUX CHECKPOINT HOLDS THAT A CADR'S DOES NOT**, each written below
// where muir's own order puts it: `Geometry::QUUX` after the level-1 map; the
// processor's clocks, `Tick`; block-disk in the CADR controller's place,
// whose own slot is then an idle controller with no drive; the video
// controller, the display board with the tag 2, its size, its 40,960-word buffer and one bit
// of mode; the keyboard and mouse, `QuuxInput`; the page's bus errors in
// `Machine::bus_error`; and `TimingModel::Sync` with K and L.  All of it is
// READ, off the register table's entries 21 to 25 and selector 12, but for
// what a QUUX machine of muir's holds and never changes --- the Unibus's
// registers at their power-on values, the display's sync program and color
// map, which the video controller has neither of --- and those are written as muir's own
// machine holds them, which is exact rather than idle.
//
// Held to muir's own file for the same machine, byte for byte, by
// `build/checkpoint.quux.pass` (`golden/src/quux_checkpoint.rs`).

// `Geometry::QUUX`, src/machine.rs: a level-1 entry of six bits, a PDL
// pointer and index of fourteen, multiply and divide, and the tick.
#define MUIR_QUUX_L1_BITS  6u
#define MUIR_QUUX_PDL_BITS 14u
// Ticks of MIT's grid in a microsecond, `quux_clocks.sv`'s `TICKS_A_US`.
#define CHK_TICKS_A_US (1000u / CHK_GRID_NS)
// `block_disk::BLOCK_NS`, a block's time, which `BlockDisk::save` writes.
#define MUIR_BLOCK_NS 100000u
// `Tv::save`'s tag for the video controller, `Board::Video`, and
// `tv::mode::BOW`.
#define MUIR_TV_BOARD_VIDEO 2u
#define MUIR_TV_MODE_BOW 04u
// `Rtl::save`'s tag for `TimingModel::Sync`, followed by K and L.
#define MUIR_TIMING_SYNC 2u

// The machine's clock: the fabric's ticks on the CADR; on QUUX muir's own
// instant off the microsecond clock, which `ro_read_quux` unwrapped.
static uint64_t chk_ns(const struct cadr_image *img)
{
	return (img->quux ? img->qx.m : img->ticks) * CHK_GRID_NS;
}

// A timer's `deadline_ns` in muir's terms, from its words.  **muir's
// deadline is when the flag rose, or will next rise; the fabric's counts say
// when it next rises**, `pre + (us - 1) * 100` ticks after the tick the word
// was taken at.  A periodic flag up and not cleared rose a period before
// that.  Off, or on with no period, or a one-shot risen and cleared, is
// `u64::MAX`, no deadline (`IntervalTimer::after`, `write_control`).
//
// **TWO THINGS THE COUNTS CANNOT SAY.**  How many periods ago an uncleared
// periodic flag first rose: muir keeps the first rise and this writes the
// latest.  And when a one-shot rose, its count stopping at the rise (`live`
// down, `quux_clocks.sv`): this writes the latest tick it can have risen
// at, the one before its word was taken.  In both the resumed machine is the
// same machine --- the flag is up either way, a clear moves a periodic
// timer's deadline to the next period boundary of its grid, which both give
// alike, and a one-shot's to none --- but not one file, so a checkpoint
// taken more than a period after a periodic flag rose, or more than a tick
// after a one-shot rose, differs from muir's own in that one field.
static uint64_t quux_deadline(const struct quux_timer *t)
{
	if (!t->en)
		return ~(uint64_t)0;
	if (!t->live)
#if CHK_MUTATE == 20
		// A one-shot that has risen written as one that never will.
		return ~(uint64_t)0;
#else
		return t->one_shot && t->sticky ? (t->m - 1u) * CHK_GRID_NS : ~(uint64_t)0;
#endif
	uint64_t next = t->m + t->pre + (uint64_t)(t->us ? t->us - 1u : 0u) * CHK_TICKS_A_US;
#if CHK_MUTATE == 10
	// The rise the counts name, the next one, even for a flag that is up:
	// a deadline in the future for a flag muir must see as raised.
#else
	if (t->sticky)
		next -= (uint64_t)t->period_us * CHK_TICKS_A_US;
#endif
	return next * CHK_GRID_NS;
}

// `Timers::save`: each timer in turn, on, its mode, its interrupt enable,
// its period and its deadline (version 45).
static void emit_timers(struct chk *w, const struct cadr_image *img)
{
	const struct quux_state *q = &img->qx;
	for (unsigned k = 0; k < MUIR_TIMERS; ++k) {
		const struct quux_timer *t = &q->timer[k];
		chk_bool(w, t->en);			/* READ */
#if CHK_MUTATE == 21
		// The mode and the interrupt enable crossed.
		chk_bool(w, t->ie);
		chk_bool(w, t->one_shot);
#else
		chk_bool(w, t->one_shot);		/* READ */
		chk_bool(w, t->ie);			/* READ */
#endif
		chk_u32(w, t->period_us);		/* READ */
		chk_u64(w, quux_deadline(t));		/* READ */
	}
}

// `disk_image.rs`'s `Disk::save`, block-disk's disk (version 41, contract
// Q8a): its size in blocks and the blocks written that the file does not
// hold.  The size is the pack file's own, in 1,024-byte blocks, which is
// the drive bay's geometry multiplied out, and muir refuses a checkpoint
// whose size is not the resuming disk's.  None is written: the board's pack
// on the card is written through by `cadr-disk-packs`, as a unit's is.
static void emit_quux_disk(struct chk *w, const struct chk_declared *d)
{
	uint32_t blocks = d->cylinders[0] * d->heads[0] * d->blocks_per_track[0];
#if CHK_MUTATE == 17
	blocks -= 1;
#endif
	chk_u32(w, blocks);		/* DECLARED, the file's size */
	chk_u64(w, 0);			/* IDLE written, no blocks */
}

// `BlockDisk::save`: the four registers, when the transfer is done, the
// clock it was last told, a block's time, the three errors, and the disk.
static void emit_block_disk(struct chk *w, const struct cadr_image *img,
			    const struct chk_declared *d)
{
	const struct quux_state *q = &img->qx;
	const uint64_t ns = chk_ns(img);
	chk_u32(w, q->cmd);				/* READ */
	chk_u32(w, q->clp);				/* READ */
	chk_u32(w, q->da);				/* READ */
	chk_u32(w, q->lma);				/* READ */
	// When the blocks moved stop owing their time: the fabric's ticks since
	// that instant, taken back from the checkpoint's own.  A disk that has
	// never walked has muir's zero.  `cadr-checkpoint` refuses a disk that
	// is walking, whose transfer is in flight.
	uint64_t done_at = 0;
	if (q->walked) {
		const int64_t back = (int64_t)q->since_done * (int64_t)CHK_GRID_NS;
		done_at = (back > 0 && (uint64_t)back > ns) ? 0 : (uint64_t)((int64_t)ns - back);
	}
	chk_u64(w, done_at);				/* READ */
	// `now` is the clock a register access last told it; a resumed machine
	// tells it again before any access, and the checkpoint's instant is
	// what one at the checkpoint would have told it.
#if CHK_MUTATE == 12
	chk_u64(w, 0);
#else
	chk_u64(w, ns);					/* READ, the clock */
#endif
	chk_u64(w, MUIR_BLOCK_NS);			/* DECLARED, muir's */
	chk_bool(w, q->past_end);			/* READ */
	chk_bool(w, q->nxm);				/* READ */
	chk_bool(w, q->bad_command);			/* READ */
	// The disk: the bay's one pack, unit 0, a flag and then the disk
	// (`w.opt`).
	if (d->present & 1u) {
		chk_bool(w, 1);
		emit_quux_disk(w, d);
	} else {
		chk_bool(w, 0);
	}
}

// `Tv::save` for the video controller (src/tv.rs): the tag, its size, the
// buffer, and a mode that keeps black-on-white alone.  It has no sync
// program and no color map --- `Tv::write_control` keeps nothing else --- so
// the rest is `Tv::default`'s and stays so on a machine of muir's.
static void emit_video(struct chk *w, const struct cadr_image *img)
{
	chk_u8(w, MUIR_TV_BOARD_VIDEO);			/* READ, the machine */
#if CHK_MUTATE == 38
	// The old bitstreams' size whatever the bitstream says.
	chk_u16(w, MUIR_VIDEO_WIDTH);
	chk_u16(w, MUIR_VIDEO_HEIGHT);
#else
	chk_u16(w, (uint16_t)img->video_width);		/* READ, console word 39 */
	chk_u16(w, (uint16_t)img->video_height);
#endif
#if CHK_MUTATE == 14
	// The CADR's buffer, 32,768 words, where the video controller's is 40,960.
	chk_u32s(w, img->tv, IMG_TV_WORDS);
#else
	chk_u32s(w, img->tv, img->tv_words);		/* READ, out of DDR */
#endif
	chk_u32(w, img->qx.bow ? MUIR_TV_MODE_BOW : 0u);	/* READ */
	static const uint8_t zero_sync[IMG_TV_SYNC] = { 0 };
	chk_bytes(w, zero_sync, IMG_TV_SYNC);		/* NONE on the video controller */
	chk_u16(w, 0);
	chk_u8(w, MUIR_TV_SYNC_ENABLE);
	for (unsigned i = 0; i < MUIR_TV_COLOR_MAP_BYTES; ++i)
		chk_u8(w, 0);				/* NONE on the video controller */
	chk_bool(w, 0);					/* flag_written */
	chk_u64(w, 0);					/* written_at */
	chk_u64(w, 0);					/* origin */
	chk_bool(w, 0);					/* sync_held.0 */
	chk_bool(w, 0);					/* sync_held.1 */
}

// `QuuxInput::save`: the key words waiting, oldest first, then the flags,
// the counts and the buttons.
// `FileDevice::save` (version 43): four flags, the rings' bases and sizes,
// the three indexes and the head's due time.  On QUUX they are the register
// page's readout, words 7 to 9; the due time is absent, because a checkpoint
// is refused while a command is queued and a device with none has taken
// none.  On the CADR every field is a power-on file device's, which muir's
// CADR holds and never touches.
static void emit_file_device(struct chk *w, const struct cadr_image *img)
{
	const struct quux_state *q = &img->qx;
	const int on = img->quux;
	chk_bool(w, on && q->fd_enabled);		/* READ */
	chk_bool(w, on && q->fd_ie);			/* READ */
	chk_bool(w, on && q->fd_refused);		/* READ */
	chk_bool(w, on && q->fd_fault);			/* READ */
#if CHK_MUTATE == 18
	chk_u32(w, on ? q->fd_resp_base : 0);
	chk_u32(w, on ? q->fd_cmd_log2 : 0);
	chk_u32(w, on ? q->fd_cmd_base : 0);
#else
	chk_u32(w, on ? q->fd_cmd_base : 0);		/* READ */
	chk_u32(w, on ? q->fd_cmd_log2 : 0);		/* READ */
	chk_u32(w, on ? q->fd_resp_base : 0);		/* READ */
#endif
	chk_u32(w, on ? q->fd_resp_log2 : 0);		/* READ */
	chk_u16(w, on ? q->fd_cmd_prod : 0);		/* READ */
	chk_u16(w, on ? q->fd_cmd_cons : 0);		/* READ */
	chk_u16(w, on ? q->fd_resp_cons : 0);		/* READ */
	chk_opt_u64(w, 0, 0);				/* IDLE head_due: none queued */
}

static void emit_quux_input(struct chk *w, const struct cadr_image *img)
{
	const struct quux_state *q = &img->qx;
	chk_u32(w, q->count);				/* READ */
	for (unsigned i = 0; i < q->count; ++i) {
#if CHK_MUTATE == 11
		// The FIFO from its first slot and not from its head.
		chk_u32(w, q->fifo[i % IMG_QUUX_FIFO_WORDS]);
#else
		chk_u32(w, q->fifo[(q->head + i) % IMG_QUUX_FIFO_WORDS]);	/* READ */
#endif
	}
	chk_bool(w, q->overflowed);			/* READ */
	chk_bool(w, q->kbd_enable);			/* READ */
	chk_u16(w, (uint16_t)q->x);			/* READ */
	chk_u16(w, (uint16_t)q->y);			/* READ */
	chk_u8(w, (uint8_t)q->buttons);			/* READ */
	chk_bool(w, q->mouse_changed);			/* READ */
	chk_bool(w, q->mouse_enable);			/* READ */
}

void chk_rtl_body(struct chk *w, const struct cadr_image *img,
		  const struct chk_declared *d)
{
	const int quux = img->quux;
	// On QUUX the drive bay's pack is block-disk's, and the CADR controller
	// in muir's machine beside it holds none.
	struct chk_declared no_drives;
	memset(&no_drives, 0, sizeof no_drives);
	no_drives.chaos_address = d->chaos_address;

	// --- Machine::save -------------------------------------------------
	// Words from here on, the engine's after the machine's, at the
	// machine's width: 4 bytes, and 5 on revision 13 (`Writer::set_word_bits`).
#if CHK_MUTATE == 22
	w->word_bytes = 4u;
#else
	w->word_bytes = img->rev13 ? 5u : 4u;
#endif
	chk_u64s(w, img->prom, IMG_PROM_WORDS);		/* READ */
	if (quux) {
		// **THE CONTROL STORE UNDER QUUX'S PROM IS WRITTEN ZERO**: the
		// PROM has addresses of its own there, nothing fetches the RAM
		// behind it and `Machine::write_imem` writes nothing into it, so
		// muir's machine holds zeros.  The fabric's RAM there holds the
		// all-ones it came up with, which no machine can observe.
		chk_u64(w, IMG_IMEM_WORDS);
		for (unsigned i = 0; i < IMG_IMEM_WORDS; ++i)
#if CHK_MUTATE == 15
			chk_u64(w, img->imem[i]);
#else
			chk_u64(w, i < IMG_QUUX_PROM_BASE ? img->imem[i] : 0u);	/* READ */
#endif
	} else {
		chk_u64s(w, img->imem, IMG_IMEM_WORDS);	/* READ */
	}
	emit_mode(w, img);
	emit_clock_control(w, img);
	emit_opc_control(w);
	chk_u64(w, 0);					/* NONE debug_ir */
	// The two mode-register pulses.  They are momentary on the board ---
	// gated with the write strobe on OLORD2 --- so a halted machine has
	// both down, and IDLE is also what it READS.
	chk_bool(w, 0);					/* IDLE prog_reset */
#if CHK_MUTATE != 3
	chk_bool(w, 0);					/* IDLE prog_boot */
#endif
	/* CHK_MUTATE == 3 drops the line above: one byte, and every field
	   after it is read at the wrong offset.  muir must REFUSE. */
	chk_words(w, img->amem, IMG_AMEM_WORDS);		/* READ */
	chk_words(w, img->mmem, IMG_MMEM_WORDS);		/* READ */
	chk_u32s(w, img->dmem, img->dmem_words);	/* READ */
	emit_words_padded(w, img->pdl, img->pdl_words, MUIR_PDL_WORDS);	/* READ */
	chk_u32s(w, img->spc, IMG_SPC_WORDS);		/* READ */
	chk_u8(w, img->spcptr);				/* READ */
	chk_u16(w, img->pdl_ptr);			/* READ */
	chk_u16(w, img->pdl_idx);			/* READ */
	chk_word(w, img->q);				/* READ */
	// `Machine::opc` is "the PC of the instruction that just executed",
	// which `rtl.rs:1794` sets to the PC the boundary retired --- the same
	// word `LPC` takes while LPC-HOLD is clear, and it is clear here
	// because the fabric has no OPC control register.  So this is LPC and
	// not the shift register's output, which is eight microcycles older.
#if CHK_MUTATE == 2
	// The OPC shift register's newest entry in place of LPC: eight
	// microcycles older, the same width, and a field the window really
	// does read --- so this is a crossing rather than an invention.
	chk_u16(w, img->opcs[0]);
#else
	chk_u16(w, img->lpc);				/* READ */
#endif
	// **`Machine::lc` IS ZERO AND THAT IS CORRECT RATHER THAN MISSING.**
	// The `rtl` engine keeps its location counter in its own field and
	// never writes this one; a checkpoint muir itself took would carry
	// zero here too.
	chk_u32(w, 0);					/* IDLE lc */
	chk_word(w, img->vma);				/* READ */
	chk_word(w, img->md);				/* READ */
	// The same argument: `Machine::interrupt_control` is `micro`'s, written
	// at `destintctl` there and never by `rtl`, which keeps the four bits
	// as its own flags.  Zero is what muir would write.
	chk_u32(w, 0);					/* IDLE interrupt_control */
	chk_u16(w, img->dc);				/* READ dispatch_constant */
#if CHK_MUTATE == 25
	chk_u32s(w, img->l1_map, IMG_L1_WORDS);
#else
	chk_u32s(w, img->l1_map, img->l1_words);	/* READ */
#endif
	if (quux) {
		// `Machine::geometry`: `Geometry::QUUX`, or `QUUX_13`, which the
		// register table's entry 21 said the bitstream is.
		// Revision 14's is `Geometry::QUUX_14`, revision 13's with no
		// level-1 entry: 0, feature word 1's (A14.14).
#if CHK_MUTATE == 41
		const unsigned l1_bits = img->rev13 ? MUIR_QUUX13_L1_BITS : MUIR_QUUX_L1_BITS;
#else
		const unsigned l1_bits = img->rev14 ? 0u : img->rev13 ? MUIR_QUUX13_L1_BITS : MUIR_QUUX_L1_BITS;
#endif
#if CHK_MUTATE == 9
		// The CADR's PDL width on QUUX: a machine whose pointer is too
		// wide for its own buffer.
		chk_u8(w, (uint8_t)l1_bits);
		chk_u8(w, MUIR_PDL_BITS);
#else
		chk_u8(w, (uint8_t)l1_bits);		/* READ, the machine */
		chk_u8(w, MUIR_QUUX_PDL_BITS);
#endif
		chk_bool(w, 1);				/* muldiv */
		chk_bool(w, 1);				/* tick */
		chk_bool(w, 1);				/* macro_dispatch: revision 12 and on */
		if (img->rev13) {
			// A wider word says so, and then the fixnum overflow
			// flag (A1.3), the flag word's <35>.
			chk_u8(w, IMG_WORD_BITS_13);	/* READ, the machine */
#if CHK_MUTATE == 24
			chk_bool(w, img_flag(img, IMG_F_MEMSTART_FETCH));
#elif CHK_MUTATE != 23
			chk_bool(w, img_flag(img, IMG_F_OVERFLOW));	/* READ */
#endif
		}
		emit_timers(w, img);
	} else {
		// `Machine::geometry`: the fabric is a CADR, `Geometry::CADR`.
		chk_u8(w, MUIR_L1_BITS);		/* DECLARED l1_bits */
		chk_u8(w, MUIR_PDL_BITS);		/* DECLARED pdl_bits */
		chk_bool(w, MUIR_MULDIV);		/* DECLARED muldiv */
		chk_bool(w, MUIR_TICK);			/* DECLARED tick */
		chk_bool(w, 0);				/* DECLARED macro_dispatch */
		// `Timers::save`: QUUX's interval timers, which a CADR's machine
		// holds in their reset state and never turns on (version 45).
		for (unsigned k = 0; k < MUIR_TIMERS; ++k) {
			chk_bool(w, 0);			/* NONE timer.on */
			chk_bool(w, 0);			/* NONE timer.one_shot */
			chk_bool(w, 0);			/* NONE timer.interrupt_enable */
			chk_u32(w, 0);			/* NONE timer.period_us */
			chk_u64(w, ~(uint64_t)0);	/* NONE timer.deadline_ns */
		}
	}
	emit_macro_dispatch(w, img, quux);
	// **REVISION 9, ON BOTH MACHINES** (versions 42 and 43).  `Rtc::save`:
	// the real-time clock's setting, and a board's is always the host's
	// clock, Linux keeping the fabric's count; so the option is absent, as
	// muir writes it without `--rtc`.  A CADR's machine holds the same.
#if CHK_MUTATE == 19
	chk_bool(w, 1);					/* a counted clock */
	chk_u32(w, 0);
	chk_u64(w, 0);
#else
	chk_bool(w, 0);					/* DECLARED Rtc::Host */
#endif
	// `FileDevice::save`: QUUX's as the register page's readout gives it,
	// the CADR's as a machine that has none holds it.
	emit_file_device(w, img);
	// `Machine::dma_written`, version 36: the disk controller wrote since
	// the engine last looked, which only QUUX's memory cache reads.  A CADR
	// has no cache, and a halted board's controller has told nothing it has
	// not already been asked for, so it is false.
	chk_bool(w, 0);					/* IDLE dma_written */
#if CHK_MUTATE == 30
	emit_u32s_padded(w, img->l2_map, img->l2_words, MUIR_L2_MAP_WORDS);
#else
	emit_u32s_padded(w, img->l2_map, img->l2_words,
			 img->rev13 ? MUIR_QUUX13_L2_WORDS : MUIR_L2_MAP_WORDS);	/* READ */
#endif
	chk_u32(w, img->boards);			/* the count, again */
	if (img->rev13) {
		// **MAIN MEMORY AS IT STANDS IN DDR.**  A 40-bit word is 5 bytes
		// in the file, `<7:0>` first and the tag last, which is packed
		// storage byte for byte (G1 4.1), so the bytes are taken where
		// they are rather than copied (`chk_hole`).
		const size_t words = (size_t)img->boards * IMG_BOARD_WORDS;
		chk_u64(w, (uint64_t)words);
#if CHK_MUTATE == 26
		chk_hole(w, img->main13, 4u * words);
#else
		chk_hole(w, img->main13, 5u * words);	/* READ */
#endif
	} else {
		chk_u32s(w, img->main, (size_t)img->boards * IMG_BOARD_WORDS);	/* READ */
	}
	// The bus interface's own registers.  **THE READOUT WINDOW DOES NOT
	// REACH THEM**, which is not the same as their not existing and used
	// to be: `rtl/machine/cadr_busint_regs.sv` holds the interrupt status
	// register, the error status register, WRITE-THROUGH and the sixteen
	// Unibus map entries, checked against muir's own
	// `Machine::interface_read` and `interface_write`.  What is still
	// absent is the map's read and write buffers, whose one master is the
	// debug cable's.  The window reaches the processor's memories and
	// registers and nothing else, so these are written at the value a
	// machine that has never been asked for them has --- which is right
	// for a board halted out of a boot the PROM drove, the PROM touching
	// none of them, and is a decision anywhere else.
	// On QUUX the bus errors are the register page's word 101, which the
	// readout reaches; on the CADR they are the interface's, which it does
	// not.
#if CHK_MUTATE == 16
	chk_u16(w, 0);
#else
	chk_u16(w, quux ? (uint16_t)img->qx.bus_error : 0u);	/* READ on QUUX */
#endif
	chk_u16(w, MUIR_LOCAL_ENABLE);			/* NONE interrupt_status */
	chk_bool(w, 0);					/* NONE write_through */
	static const uint16_t sixteen[16] = { 0 };
	chk_u16s(w, sixteen, 16);			/* NONE unibus_map */
	chk_u16s(w, sixteen, 16);			/* NONE read_buffer */
	chk_u16s(w, sixteen, 16);			/* NONE write_buffer */
	chk_bool(w, img_flag(img, IMG_F_VMAOK));	/* READ */
	if (quux) {
		// The CADR controller is in muir's machine with no drive on it,
		// and block-disk is fitted in its place with the bay's pack.
		emit_disk(w, &no_drives);
		chk_bool(w, 1);				/* block_disk is there */
		emit_block_disk(w, img, d);
		emit_video(w, img);
	} else {
		emit_disk(w, d);
		// `Machine::block_disk`, version 37: QUUX's block-disk when it
		// is fitted in the CADR controller's place.  The CADR fits none,
		// so the option is written absent and nothing follows it.
		chk_bool(w, 0);				/* NONE block_disk */
		emit_tv(w, img);
	}
	// **WHETHER A SECOND DISPLAY BOARD WAS ON THE BACKPLANE**, and the
	// board itself after it when there was one (`Machine::save`,
	// src/machine.rs:962-965).  The flag is written clear and NOTHING
	// follows it, which is the backplane as the fabric comes up: with no
	// color board fitted `cadr_xbus_decode.sv` answers `17200000` and
	// `17377750` with an NXM --- held to `busint::decode` over all 4,194,304
	// addresses --- and that NXM is how `COLOR-EXISTS-P` finds out which
	// machine it is on.  The console face's page 2 word 33 fits a color
	// board, `--color-tv` on the card, and this program does not read that
	// word: a checkpoint of a board with one fitted declares one screen and
	// carries neither the second board's registers nor its picture.
	// `refuse_color_tv` (src/main.rs:3411-3421) refuses a resume that
	// `--color-tv` disagrees with, by name.
#if CHK_MUTATE == 7
	// A color board this backplane does not have.  muir then reads a
	// whole second 135,259-byte display out of the eight hundred bytes
	// that are left, and REFUSES at the short read --- which is what
	// makes this the flag's own mutant and not the map's.
	chk_bool(w, 1);
#else
	chk_bool(w, 0);					/* DECLARED no color TV */
#endif
	emit_ioboard(w, d);
	if (quux) {
		emit_quux_input(w, img);
	} else {
		// `QuuxInput::save`, version 39: QUUX's keyboard and mouse on
		// its register page, which a CADR's machine holds empty --- no
		// key word waiting, no overflow, both enables off, the counts
		// and the buttons 0.
		chk_u32(w, 0);				/* NONE quux_input.fifo.len() */
		chk_bool(w, 0);				/* NONE quux_input.overflowed */
		chk_bool(w, 0);				/* NONE quux_input.kbd_enable */
		chk_u16(w, 0);				/* NONE quux_input.x */
		chk_u16(w, 0);				/* NONE quux_input.y */
		chk_u8(w, 0);				/* NONE quux_input.buttons */
		chk_bool(w, 0);				/* NONE quux_input.mouse_changed */
		chk_bool(w, 0);				/* NONE quux_input.mouse_enable */
	}
	chk_u64(w, img->cycles);			/* READ */
	// **THE CLOCK.**  A fabric tick stands for `CHK_GRID_NS` nanoseconds of
	// MIT's grid, `cadr_tick_pkg::TICK_NS`, which is muir's own time under
	// `TimingModel::Fpga` --- so this is the machine's own elapsed time in
	// the units muir counts it in, and it is a measurement rather than a
	// guess.  What it is NOT is consistent with the idle instants in
	// `Busint` above, which are a fresh machine's.
	chk_u64(w, chk_ns(img));			/* READ ns */
	// **REVISION 14'S OWN** (A14.14), after everything revision 13 has:
	// `Machine::lc`'s `<40:32>`, the `rtl` engine never writing that
	// field; the memory system's words 220 to 224; and the redirect's
	// copies of the PDL buffer's base and head.  The TLB is not kept: a
	// resume starts with it swept.
	if (img->rev14) {
		chk_u16(w, 0);				/* IDLE Machine::lc <40:32> */
#if CHK_MUTATE == 42
		chk_u32(w, img->qx.refused);
		chk_bool(w, img->qx.ephemeral);
		chk_u64(w, img->qx.pointer_types);
		chk_u32(w, img->qx.directory);
#else
		chk_u32(w, img->qx.directory);		/* READ word 220 */
		chk_bool(w, img->qx.ephemeral);		/* READ word 221 <0> */
#if CHK_MUTATE == 43
		chk_u64(w, (img->qx.pointer_types >> 32) | (img->qx.pointer_types << 32));
#else
		chk_u64(w, img->qx.pointer_types);	/* READ words 222, 223 */
#endif
		chk_u32(w, img->qx.refused);		/* READ word 224 */
#endif
		chk_u32(w, img->qx.pdl_base);		/* READ A 430's copy */
#if CHK_MUTATE == 44
		chk_u16(w, 0);
#else
		chk_u16(w, img->qx.pdl_head);		/* READ A 431's copy */
#endif
	}

	// --- the Rtl tail ---------------------------------------------------
	//
	// `trace` and `flags` are the columns `Rtl::signals` and `Rtl::spy`
	// return for the microcycle just executed --- a RECORD of the last
	// one, read by nothing that runs.  Twelve each, and they are written
	// as zeros: the fabric keeps no such record, and the first microcycle
	// after a resume overwrites both.
	static const uint64_t twelve[12] = { 0 };
	chk_u64s(w, twelve, 12);			/* NONE trace */
	chk_u64s(w, twelve, 12);			/* NONE flags */
	chk_u64(w, img->ir);				/* READ */
	chk_u64(w, img->iwr);				/* READ */
	chk_u16(w, img->wadr);				/* READ */
	chk_bool(w, img_flag(img, IMG_F_DESTD));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_DESTMD));	/* READ */
	chk_word(w, img->l);				/* READ */
	chk_u16(w, img->pc);				/* READ */
	chk_u16(w, img->lpc);				/* READ */
	chk_u32(w, img->lc);				/* READ */
	chk_bool(w, img_flag(img, IMG_F_PWIDX));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_PDLWRITED));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_INOP));		/* READ */
	chk_bool(w, img_flag(img, IMG_F_IWRITED));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_NEWLC));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_SINTR));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_NEXT_INSTRD));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_LC_BYTE_MODE));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_INT_ENABLE));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_SEQUENCE_BREAK));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_PROG_UNIBUS_RESET));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_TRAP));		/* READ boot_trap */
	chk_bool(w, img_flag(img, IMG_F_PROMDISABLED));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_SRUN));		/* READ */
	// NONE: SSTEP and SSDONE are in the fabric now --- OLORD1 1A10, and
	// MACHRUN's first term --- but nothing brings them out where this
	// program can read them.  FLAG-1 bit 9 is SSDONE and could be taken
	// from a spy read; SSTEP has no port at all.  So they are written
	// clear, which is what a machine halted from the console holds: both
	// are down unless a step is in flight, and a checkpoint is taken with
	// the machine stopped.
	chk_bool(w, 0);					/* NONE sstep */
	chk_bool(w, 0);					/* NONE ssdone */
	chk_bool(w, img_flag(img, IMG_F_STATSTOP));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_HALTED));	/* READ */
	// NONE: OPC-CK is the OPC control register's, which is not built.
	chk_bool(w, 0);					/* NONE opc_ck */
	chk_u64(w, 0);					/* IDLE halted_ns */
	// When the instruction standing in `IR` was clocked in.  Only QUUX's
	// divider reads it, so a CADR's value changes nothing; zero is what a
	// fresh `Rtl` holds.
	chk_u64(w, 0);					/* IDLE div_from_ns */
	// `Rtl::pulsed`: whether the write pulse of a microcycle that `-HANG`
	// holds has already fired.  It is set inside a hung step and taken at
	// the step's end, and a halted machine is never inside a hang --- the
	// generator is parked, so no master clock can halt it there --- so it is
	// false wherever this program reads the machine.
	chk_bool(w, 0);					/* IDLE pulsed */
	chk_bool(w, img_flag(img, IMG_F_MEMSTART));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_MBUSY));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_RDCYC));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_WRCYC));	/* READ */
	if (quux) {
		chk_u8(w, MUIR_BUS_QUUX);
		emit_memory_port(w, img);
	} else {
		chk_u8(w, MUIR_BUS_CADR);
		emit_busint(w, img);
	}
	chk_bool(w, img_flag(img, IMG_F_MBUSY_SYNC));	/* READ */
	// The bus cycle in the air.  IDLE, all of it: see the header.  The
	// physical address the fabric holds is in `phys_r` and is READ, but it
	// is the address of a cycle that has FINISHED, and muir's `bus_addr`
	// means one in flight --- so writing it would be putting a fact in a
	// field that means something else.
	chk_u32(w, 0);					/* IDLE bus_addr */
	chk_word(w, 0);					/* IDLE bus_data */
	chk_bool(w, 0);					/* IDLE bus_written */
	chk_opt_u8(w, 0, 0);				/* IDLE bus_spy */
	chk_bool(w, 0);					/* IDLE bus_sampled */
	chk_bool(w, 0);					/* IDLE bus_pulsed */
	chk_u8(w, MUIR_RESP_MEMORY);			/* IDLE bus_responder */
	chk_u8(w, 0);					/*      ... Memory(0) */
	chk_bool(w, img_flag(img, IMG_F_RD_IN_PROGRESS));	/* READ */
	chk_u64(w, ~(uint64_t)0);			/* IDLE rd_finish_at */
	chk_u64(w, ~(uint64_t)0);			/* IDLE mbusy_clear_at */
	chk_bool(w, 0);					/* IDLE bus_acked */
	// The debug cable, which this board has no adapter for at all.
	chk_opt_u16(w, 0, 0);				/* NONE debug_word */
	chk_bool(w, 0);					/* NONE debug_sampled */
	chk_bool(w, 0);					/* NONE debug_written */
	chk_bool(w, 0);					/* NONE debug_pulsed */
	chk_bool(w, 0);					/* NONE debug_answer, a nested opt */
	chk_bool(w, 0);					/* NONE debug_reset */
	chk_u64(w, 0);					/* NONE debug_cycles */
	chk_bool(w, 0);					/* NONE clock_held */
	chk_u16(w, 0xFFFFu);				/* IDLE debug_out_word */
	chk_u64(w, ~(uint64_t)0);			/* IDLE step_limit */
	chk_bool(w, img_flag(img, IMG_F_WMAPD));	/* READ */
	chk_u32(w, img->lvmo);				/* READ */
	// The two totals muir keeps and the fabric does not: how long the
	// machine has stalled and how many bus cycles it has made.  A resumed
	// machine's counters start again; nothing it computes reads them.
	chk_u64(w, 0);					/* NONE stalled_ns */
	chk_u64(w, 0);					/* NONE bus_cycles */
	chk_bool(w, img_flag(img, IMG_F_SPUSHD));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_DESTSPCD));	/* READ */
	chk_u16(w, img->reta);				/* READ */
	chk_bool(w, img_flag(img, IMG_F_IMODD));	/* READ */
	chk_u16s(w, img->opcs, IMG_OPCS);		/* READ */
	chk_u32(w, img->st);				/* READ */
	chk_u8(w, img->speed);				/* READ */
	chk_u8(w, img->speed_a);			/* READ */
	// Whose nanoseconds `ns` counts, muir's `TimingModel`: this fabric keeps
	// muir-fpga's grid, so the count below is in its nanoseconds and the
	// checkpoint says so.
	if (quux) {
		// QUUX's is `sync`, of the K and L the bitstream was built at,
		// which the register table's entry 21 said.
		chk_u8(w, MUIR_TIMING_SYNC);
#if CHK_MUTATE == 13
		chk_u8(w, (uint8_t)img->qx.l);
		chk_u8(w, (uint8_t)img->qx.k);
#else
		chk_u8(w, (uint8_t)img->qx.k);		/* READ cycle_ticks */
		chk_u8(w, (uint8_t)img->qx.l);		/* READ ilong_ticks */
#endif
	} else {
		chk_u8(w, CHK_TIMING_FPGA);		/* DECLARED timing */
	}
	chk_u64(w, chk_ns(img));			/* READ ns, as above */
	chk_word(w, 0);					/* IDLE busint_bus */
	chk_u64(w, ~(uint64_t)0);			/* IDLE loadmd_at */
	chk_opt_u16(w, 0, 0);				/* IDLE executed */
	// Version 49: `MEMSTART`'s cycle is the stream's fetch, for QUUX's
	// prefetch; READ on QUUX, and false on the CADR, which never sets it.
	chk_bool(w, img_flag(img, IMG_F_MEMSTART_FETCH));	/* READ */
	// Revision 14's location counter's `<33:32>` (A14.11, A14.14).
	if (img->rev14)
#if CHK_MUTATE == 47
		chk_u8(w, 0);
#else
		chk_u8(w, img->lc_hi);			/* READ */
#endif
}

// --- what it could not read ------------------------------------------------

static const char *const kMissing[] = {
	"the mode register's TRAPENB: cadr_spy_registers.sv drops bit 4, so it",
	"    is written clear.  The fabric raises MIT's boot trap out of reset",
	"    instead of from this bit, so the machine behaves as it reads.",
	"the clock control register's STEP, NOP11, IDEBUG and LDSTAT, and with",
	"    them SSTEP and SSDONE: the fabric has all of them, but none is",
	"    brought out where this program can read it, so all are written",
	"    clear.  A checkpoint is taken with the machine halted, which is what",
	"    a console leaves them at, so the written value is the right one.",
	"the OPC control register, all three bits: register 4 is dropped.  The",
	"    fabric behaves as all three clear, which is what is written.",
	"the debug IR, 48 bits: it is built and it is written only by a console",
	"    or a debugger, but nothing brings it out to be read back.",
	"the bus interface's own registers --- the sixteen Unibus map entries,",
	"    their read and write buffers, the error register, the interrupt",
	"    status and WRITE-THROUGH.  All but the read and write buffers ARE",
	"    in the fabric; what cannot reach them is this window, which reads",
	"    the processor's memories and registers and nothing else.  The",
	"    interrupt status is written at its power-on value, LOCAL-ENABLE,",
	"    and the rest clear.",
	"the disk controller, whole: its command, command-list pointer, disk",
	"    address, eight error flops, the channel and the eight drives'",
	"    heads and attention timers.  A transfer in flight when the board",
	"    was halted is LOST.  Halt between transfers --- the disk light is",
	"    the instrument --- or expect the microcode to retry.",
	"the display's mode register, its sync RAM, when that program last",
	"    started, and its vertical-interrupt flag.  The PICTURE is read,",
	"    out of DDR, word for word, and so is THE COLOR MAP, off the",
	"    console face's page 4 --- register 4 is write only on the Xbus,",
	"    whose RAMs are off the board, so that page is the only way to ask",
	"    what a color is.  The sync program is 4,096 bytes and no readout",
	"    reaches it, so a resumed machine runs MIT's PROM from its",
	"    power-on instant.  Which display board this is, and whether a",
	"    color board is fitted, are DECLARED rather than read: the SIMPLE",
	"    TV and no color board, which is how the fabric comes up.  A board",
	"    the console has strapped as a LISPM TV, or given a color board, is",
	"    declared wrongly, and muir refuses a resume whose --tv-board or",
	"    --color-tv disagrees with the file.",
	"the I/O board, whole: the keyboard, the mouse, the sixty-cycle",
	"    interval and THE MICROSECOND CLOCK, which is the CADR's whole",
	"    timebase.  A resumed machine's time of day starts again.",
	"the serial line's registers and the Chaosnet interface's.  The",
	"    Chaosnet's switches are written at the address --chaos-address",
	"    names, because a resume refuses a checkpoint that disagrees.",
	"the bus cycle in flight, if there was one: the address and word in the",
	"    air, the responder and three absolute deadlines.  The file is of a",
	"    HALTED machine at a microcycle boundary, where there is none.",
	"the bus interface's memory-board refresh model and its own state.  It",
	"    is written as a machine that has just been built, so a resumed",
	"    machine's refresh one-shot fires once, early, for nothing.",
	"how long the machine has stalled and how many bus cycles it has made:",
	"    two totals muir keeps and nothing computes from.",
	"`Rtl`'s trace and flag columns --- twelve words each, a record of the",
	"    last microcycle that nothing running reads, overwritten by the",
	"    first microcycle after a resume.",
	"and the DISK PACKS, which muir's format never carries: a checkpoint",
	"    holds the blocks a run has written and not the disk.  The packs",
	"    are bound to this file by the sidecar beside it --- their names,",
	"    their geometries and a SHA-256 of every byte, taken while the",
	"    machine was halted.  A resume over a pack that has moved on is",
	"    the one wrong thing NOTHING here or in muir can detect, which is",
	"    why the sidecar is written and why it says to check it.",
	NULL
};

// And QUUX's.  Shorter, and not because more is read: much of what the CADR's
// list names is a board QUUX has not got --- the Unibus's registers, the
// CADR's disk controller, its display's sync program --- which muir's QUUX
// holds at power-on for ever, so the file carries it exactly.
static const char *const kMissingQuux[] = {
	"the mode register's TRAPENB, the clock control register's STEP, NOP11,",
	"    IDEBUG and LDSTAT with SSTEP and SSDONE, the OPC control register",
	"    and the debug IR: as on the CADR, written clear, which is what a",
	"    machine halted from the console holds.",
	"the Chaosnet interface's registers, the register page's words 140 to",
	"    147: they are the I/O board's, which the readout does not reach.",
	"    The switches are written at the address --chaos-address names.",
	"a periodic timer's flag raised and not cleared for MORE than a period:",
	"    the fabric counts to the next rise and cannot say how many rises ago",
	"    the flag went up, so the file has the latest rise where muir keeps",
	"    the first.  The flag is up either way and a clear moves both to the",
	"    same next boundary, so the resumed machine is the same machine.",
	"a one-shot timer's rise, once it has risen: its count stops there, so",
	"    the file has the latest tick it can have risen at, the one before its",
	"    word was read.  The flag is up either way and a clear leaves both",
	"    with no deadline, so the resumed machine is the same machine.",
	"block-disk's instant of completion is taken a few microseconds off the",
	"    checkpoint's own instant, the two being separate reads; it is in the",
	"    past for a disk that is done and the machine sees it so.  A disk",
	"    whose transfer is in flight is REFUSED: halt between transfers.",
	"the instant IR was loaded, which only the divider reads: written as a",
	"    fresh machine's, long ago, which a machine halted for more than the",
	"    divider's 33 ticks is.",
	"the bus cycle in flight, the two totals muir keeps and Rtl's trace and",
	"    flag columns: as on the CADR.",
	"the memory cache's lines and counts: written EMPTY, where muir keeps",
	"    them and restores the cache warm.  The cache is write-through, so",
	"    every line it holds is main memory's word; a resumed machine misses",
	"    where muir's would hit, which moves when a read is answered and",
	"    never what it reads.",
	"and the DISK PACK, which muir's format never carries: bound to the file",
	"    by the sidecar beside it, as on the CADR.",
	NULL
};

const char *const *chk_rtl_missing(void)
{
	return kMissing;
}

const char *const *chk_rtl_missing_quux(void)
{
	return kMissingQuux;
}

int chk_rtl_refusal(const struct cadr_image *img, char *why, size_t n)
{
	if (!img->quux)
		return 0;
	const struct quux_state *q = &img->qx;
	const unsigned queued = (uint16_t)(q->fd_cmd_prod - q->fd_cmd_cons);
	if (q->fd_handles == 0 && queued == 0)
		return 0;
	snprintf(why, n, "the file device has %u handle%s open and %u command%s queued; "
		 "a checkpoint waits until every handle is closed and every command answered",
		 q->fd_handles, q->fd_handles == 1 ? "" : "s", queued, queued == 1 ? "" : "s");
	return 1;
}

// --- the run state before the halt -------------------------------------------
//
// `ClockControl::run`, the clock control register's bit 0, and `Rtl::srun`,
// which follows it at each master clock edge (muir's `mclk_edge`): both up
// on a machine that is running, and both down once the console has written
// the register with RUN clear --- which is how this program halts a machine
// to read it.  So what the window reads is the halt this program made, not
// the machine's own state, and a file written from it resumes halted: muir's
// prompt then says "the machine is halted, its RUN clear".  The two are put
// back as they stood before the halt, and nothing else is: the halt changed
// nothing else that the file carries.
void chk_rtl_run_state(struct cadr_image *img, int was_running)
{
#if CHK_MUTATE == 34
	(void)was_running;
	if (1)
#else
	if (was_running)
#endif
	{
#if CHK_MUTATE != 32
		img->flags |= 1ull << IMG_F_RUN;
#endif
#if CHK_MUTATE != 33
		img->flags |= 1ull << IMG_F_SRUN;
#endif
	}
}

// --- what a mutant of this file was built to do ----------------------------
//
// **`CHK_MUTATE` IS NEVER DEFINED IN THE PROGRAM THAT GOES ON THE BOARD.**
// The host check builds this file again with each value and requires that
// the round trip through muir FAILS for each --- because a round trip that
// cannot fail says nothing, which is this repository's oldest lesson in its
// newest place.  The first three are chosen to fail in three different ways:
// 1 loads and re-saves DIFFERENT BYTES, 2 puts a field the window really does
// read where another belongs, and 3 drops one byte so that muir REFUSES the
// file outright.
//
// **4 TO 7 ARE THE FOUR FIELDS FORMAT 25 ADDED, ONE EACH**, because a field
// nothing is aimed at is a field the check does not hold: the display board's
// tag, the color map, the sync program's origin and the color board's
// presence flag.  Two of the four are caught by muir's REFUSAL --- the tag by
// its cross-check against `--tv-board`, the flag by the short read that
// follows a display board that is not in the file --- and two by the DIGEST
// alone, being legal values in the right slots, which is the leg this file's
// own comment says the round trip cannot replace.

const char *chk_rtl_mutation(void)
{
#if CHK_MUTATE == 1
	return "the mouse's quadrature phases written 0 where a fresh mouse has 2";
#elif CHK_MUTATE == 2
	return "Machine::opc taken from the OPC shift register instead of LPC";
#elif CHK_MUTATE == 3
	return "prog_boot dropped, so every byte after it is at the wrong offset";
#elif CHK_MUTATE == 4
	return "the display board written as the LISPM TV where the fabric is the SIMPLE TV";
#elif CHK_MUTATE == 5
	return "the color map written all ones where the board's own map is read";
#elif CHK_MUTATE == 6
	return "the sync program's origin written at the machine's clock instead of zero";
#elif CHK_MUTATE == 7
	return "a color display board claimed on a backplane that has none";
#elif CHK_MUTATE == 8
	return "--chaos-address read as decimal, which is what strtoul(.., 0) does";
#elif CHK_MUTATE == 9
	return "QUUX's geometry written with the CADR's ten-bit PDL pointer";
#elif CHK_MUTATE == 10
	return "a raised timer flag's deadline written at its next rise, not the last";
#elif CHK_MUTATE == 11
	return "the keyboard FIFO written from its first slot, not from its head";
#elif CHK_MUTATE == 12
	return "block-disk's clock written 0 where the checkpoint's instant belongs";
#elif CHK_MUTATE == 13
	return "the sync timing model's K and L written crossed";
#elif CHK_MUTATE == 14
	return "the video controller's buffer written at the CADR display's 32,768 words";
#elif CHK_MUTATE == 15
	return "the control store under QUUX's PROM written as the fabric's RAM holds it";
#elif CHK_MUTATE == 16
	return "the register page's bus errors written 0";
#elif CHK_MUTATE == 17
	return "block-disk's disk written a block smaller than the pack file";
#elif CHK_MUTATE == 18
	return "the file device's two ring bases written crossed";
#elif CHK_MUTATE == 19
	return "the real-time clock written counted from 0 where a board's is the host's";
#elif CHK_MUTATE == 20
	return "a one-shot timer that has risen written with no deadline, as one that never will";
#elif CHK_MUTATE == 21
	return "a timer's mode and interrupt enable written crossed";
#elif CHK_MUTATE == 22
	return "revision 13's words written in 4 bytes, a 32-bit machine's";
#elif CHK_MUTATE == 23
	return "revision 13's overflow flag left out after the word's width";
#elif CHK_MUTATE == 24
	return "revision 13's overflow flag taken from the flag word's <34>, MEMSTART-FETCH";
#elif CHK_MUTATE == 25
	return "revision 13's level-1 map written at revision 12's 2,048 entries";
#elif CHK_MUTATE == 26
	return "revision 13's main memory written 4 bytes a word";
#elif CHK_MUTATE == 27
	return "revision 13's cache written with revision 12's 4-word lines";
#elif CHK_MUTATE == 28
	return "revision 13's response ring's base read from word 7, the command ring's";
#elif CHK_MUTATE == 29
	return "revision 13's words read out at 32 bits, their tags dropped";
#elif CHK_MUTATE == 30
	return "revision 13's level-2 map written at revision 12's 2,048 entries";
#elif CHK_MUTATE == 31
	return "a 40-bit body written under version 49, a 32-bit machine's";
#elif CHK_MUTATE == 32
	return "a machine found running written with RUN clear, as the halt left it";
#elif CHK_MUTATE == 33
	return "a machine found running written with SRUN clear, as the halt left it";
#elif CHK_MUTATE == 34
	return "a machine found halted written as running";
#elif CHK_MUTATE == 35
	return "QUUX's main memory taken as --boards, the CADR's flag";
#elif CHK_MUTATE == 36
	return "QUUX's main memory written in the sidecar as boards";
#elif CHK_MUTATE == 37
	return "QUUX's main memory said in memory boards";
#elif CHK_MUTATE == 38
	return "the video controller's size written as 1280x1024 whatever the bitstream says";
#elif CHK_MUTATE == 41
	return "revision 14's geometry written with revision 13's level-1 bits";
#elif CHK_MUTATE == 42
	return "revision 14's directory base and refused count written crossed";
#elif CHK_MUTATE == 43
	return "revision 14's pointer-type register written with its two words crossed";
#elif CHK_MUTATE == 44
	return "revision 14's redirect head written 0";
#elif CHK_MUTATE == 45
	return "revision 14's write-back's end left out of the memory port";
#elif CHK_MUTATE == 46
	return "revision 14's map levels read from the window, which has none";
#elif CHK_MUTATE == 47
	return "revision 14's LC<33:32> written 0";
#elif CHK_MUTATE == 48
	return "revision 14's bitstream refused as a revision this program does not know";
#elif CHK_MUTATE == 39
	return "the video controller's buffer sized at 1280x1024 whatever the bitstream says";
#elif CHK_MUTATE == 40
	return "the resume line without the video controller's size";
#else
	return NULL;
#endif
}

// **AN ADDRESS IS OCTAL, AND THIS PROGRAM READ IT AS DECIMAL UNTIL IT WAS
// CAUGHT ON THE BOARD.**  `--chaos-address 177100` went through
// `strtoul(.., 0)`, where a plain string of digits is DECIMAL, and put
// 0o131714 --- the low sixteen bits of one hundred and seventy-seven thousand
// --- into the checkpoint's switches.  muir then refused the file, saying so:
// "the Chaosnet interface's switches read 131714, this machine's 177100".
// Only the spelling `0177100` worked.
//
// muir's own flag "wants one address in octal or subnet:host", and
// `chaos::parse_address` is the whole of what it takes:
//
//   * a bare octal number, `u16::from_str_radix(s, 8)`.  **No prefix**: not
//     `0o`, not `0x`, and a leading `0` changes nothing because the string is
//     octal already.  A digit 8 or 9 is refused.
//   * or `subnet:host`, each an octal byte of at most `0o377`.
//   * and in both forms BOTH halves must be non-zero --- `a >> 8 != 0 && a &
//     0o377 != 0` --- so `0`, `377` and `177000` are not addresses.
//
// This is that parser in C, so that a card, a script and a person all spell an
// address here the way they spell it to muir.  The checkpoint is refused by
// muir when the two disagree, which is what made the defect visible at all.
//
// Returns 0 and sets `*out`, or -1.
int chk_chaos_address(const char *s, unsigned *out)
{
#if CHK_MUTATE == 8
	// The defect as it stood on the board: `strtoul(.., 0)` reads a plain
	// string of digits as DECIMAL, so `177001` becomes 177,001 and its low
	// sixteen bits, 0o131551, go into the checkpoint's switches.  muir
	// refuses the file and says which two addresses disagree, which is how
	// it was found.
	*out = (unsigned)(strtoul(s, NULL, 0) & 0xFFFFu);
	return 0;
#else
	const char *colon = strchr(s, ':');
	unsigned a = 0;

	// One octal byte or one octal address: digits 0 to 7 alone, and at
	// least one of them.
	unsigned long v = 0;
	const char *p = s;
	unsigned n = 0;
	for (; *p && *p != ':'; ++p) {
		if (*p < '0' || *p > '7')
			return -1;
		v = v * 8u + (unsigned long)(*p - '0');
		if (v > 0177777ul)
			return -1;
		++n;
	}
	if (n == 0)
		return -1;
	if (colon) {
		if (v > 0377ul)
			return -1;
		unsigned long h = 0;
		unsigned hn = 0;
		for (p = colon + 1; *p; ++p) {
			if (*p < '0' || *p > '7')
				return -1;
			h = h * 8u + (unsigned long)(*p - '0');
			if (h > 0377ul)
				return -1;
			++hn;
		}
		if (hn == 0)
			return -1;
		a = (unsigned)((v << 8) | h);
	} else {
		a = (unsigned)v;
	}
	// Both halves non-zero, which is muir's `both`.
	if ((a >> 8) == 0 || (a & 0377u) == 0)
		return -1;
	*out = a;
	return 0;
#endif
}
