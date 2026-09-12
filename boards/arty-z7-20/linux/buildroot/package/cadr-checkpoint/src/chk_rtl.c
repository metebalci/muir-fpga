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
// board's.**  `ns` is the fabric's own tick count on MIT's five-nanosecond
// grid, which is real; the bus interface's memory-board refresh model and the
// I/O board's two clocks restart from their power-on state.  A resumed
// machine therefore computes what the board would have computed and its
// refresh one-shot fires once, early, for nothing.  It is the one place this
// file knowingly hands muir a machine that is not bit-for-bit the board's,
// and it is here rather than hidden because a checkpoint that invented state
// silently would be worse than none.

#include "chk_rtl.h"

#include <string.h>

// --- the constants a fresh muir machine has --------------------------------
//
// Every one of these is muir's, cited at the line that uses it.  They are
// here and not inline so that a muir that moves can be met in one place.

// `busint::interrupt_status::LOCAL_ENABLE`, src/busint.rs:976.
#define MUIR_LOCAL_ENABLE 0002u
// `machine.rs:780`, `LVMO_AT_POWER_ON` --- the value the fabric also comes up
// with, so this is a cross-check and not an invention.
#define MUIR_LVMO_AT_POWER_ON 0x00C03FFFu
// `Busint::new`'s `MemoryBoard::default()`, src/busint.rs:433-447: the three
// derived instants and the board's own next change.
#define MUIR_MB_IDLE_AT 1416u
#define MUIR_MB_TIME_OFF_AT 958u
#define MUIR_MB_REFRESH_TIME_AT 12991u
#define MUIR_MEMORY_NEXT 12992u
// `Responder::NoUnibus`, tag 10; `Responder::Memory(b)`, tag 0.
#define MUIR_RESP_MEMORY 0u
#define MUIR_RESP_NOUNIBUS 10u
// `simpletv::BUFFER_WORDS` and the sync RAM, and `SyncRam::default`'s enable.
#define MUIR_TV_SYNC_ENABLE 0u
// muir's own `chaos::Config::default().address`, src/chaos/mod.rs:145.
#define MUIR_CHAOS_ADDRESS 0177001u

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
	// `spy::ClockControl::save`: five bools.  Only RUN is in the fabric
	// --- `cadr_spy_registers.sv` keeps bit 0 of register 3 and drops bits
	// 4:1 --- so single step, NOP11, IDEBUG and LDSTAT are NONE.  A
	// resumed machine therefore cannot be single-stepped from where the
	// board left it, which nobody can do on the board either.
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
		// **THE GEOMETRY IS THE PACK FILE'S OWN SIZE**, taken exactly as
		// `cadr-disk-packs` takes it, and muir refuses a checkpoint whose
		// geometry is not the resuming drive's --- so this is a reading
		// of the drive bay and not a claim of this program's.
		chk_u32(w, d->cylinders[u]);	/* DECLARED geometry */
		chk_u32(w, d->heads[u]);
		chk_u32(w, d->blocks_per_track[u]);
		chk_u64(w, 0);		/* IDLE written, no blocks */
		// DECLARED: the write-protect switch, which on the board is the
		// pack file's own read-only mark.
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
}

// `simpletv.rs`'s `SimpleTv::save`, fixed 135,200 bytes.
//
// **THE PICTURE IS REAL AND NOTHING ELSE HERE IS.**  The display block writes
// the frame buffer into the display's own region of DDR, which Linux can map,
// so the 32,768 words are the board's own screen word for word.  The mode
// register, the sync RAM and the vertical-interrupt flag are inside
// `cadr_tv.sv` and the readout window does not reach them: the sync RAM is
// muir's model of a sync generator the fabric does not have at all, and the
// flag is one bit that the resumed machine will set again at its next frame.
static void emit_tv(struct chk *w, const struct cadr_image *img)
{
	chk_u32s(w, img->tv, IMG_TV_WORDS);	/* READ, out of DDR */
	chk_u32(w, 0);				/* NONE mode */
	static const uint8_t zero_sync[IMG_TV_SYNC] = { 0 };
	chk_bytes(w, zero_sync, IMG_TV_SYNC);	/* NONE sync.words */
	chk_u16(w, 0);				/* NONE sync.pointer */
	chk_u8(w, MUIR_TV_SYNC_ENABLE);		/* NONE sync.enable */
	chk_bool(w, 0);				/* NONE flag_written */
	chk_u64(w, 0);				/* NONE written_at */
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
// **IT HAS TO BE THERE EVEN THOUGH THE FABRIC HAS NO CHAOSNET**, because
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
}

void chk_rtl_body(struct chk *w, const struct cadr_image *img,
		  const struct chk_declared *d)
{
	// --- Machine::save -------------------------------------------------
	chk_u64s(w, img->prom, IMG_PROM_WORDS);		/* READ */
	chk_u64s(w, img->imem, IMG_IMEM_WORDS);		/* READ */
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
	chk_u32s(w, img->amem, IMG_AMEM_WORDS);		/* READ */
	chk_u32s(w, img->mmem, IMG_MMEM_WORDS);		/* READ */
	chk_u32s(w, img->dmem, IMG_DMEM_WORDS);		/* READ */
	chk_u32s(w, img->pdl, IMG_PDL_WORDS);		/* READ */
	chk_u32s(w, img->spc, IMG_SPC_WORDS);		/* READ */
	chk_u8(w, img->spcptr);				/* READ */
	chk_u16(w, img->pdl_ptr);			/* READ */
	chk_u16(w, img->pdl_idx);			/* READ */
	chk_u32(w, img->q);				/* READ */
	// `Machine::opc` is "the PC of the instruction that just executed",
	// which `rtl.rs:1776` sets to the PC the boundary retired --- the same
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
	chk_u32(w, img->vma);				/* READ */
	chk_u32(w, img->md);				/* READ */
	// The same argument: `Machine::interrupt_control` is `micro`'s, written
	// at `destintctl` there and never by `rtl`, which keeps the four bits
	// as its own flags.  Zero is what muir would write.
	chk_u32(w, 0);					/* IDLE interrupt_control */
	chk_u16(w, img->dc);				/* READ dispatch_constant */
	chk_u32s(w, img->l1_map, IMG_L1_WORDS);		/* READ */
	chk_u32s(w, img->l2_map, IMG_L2_WORDS);		/* READ */
	chk_u32(w, img->boards);			/* the count, again */
	chk_u32s(w, img->main, (size_t)img->boards * IMG_BOARD_WORDS);	/* READ */
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
	chk_u16(w, 0);					/* NONE bus_error */
	chk_u16(w, MUIR_LOCAL_ENABLE);			/* NONE interrupt_status */
	chk_bool(w, 0);					/* NONE write_through */
	static const uint16_t sixteen[16] = { 0 };
	chk_u16s(w, sixteen, 16);			/* NONE unibus_map */
	chk_u16s(w, sixteen, 16);			/* NONE read_buffer */
	chk_u16s(w, sixteen, 16);			/* NONE write_buffer */
	chk_bool(w, img_flag(img, IMG_F_VMAOK));	/* READ */
	emit_disk(w, d);
	emit_tv(w, img);
	emit_ioboard(w, d);
	chk_u64(w, img->cycles);			/* READ */
	// **THE CLOCK.**  A fabric tick stands for five nanoseconds of MIT's
	// grid whatever it costs in real time --- `cadr_phase_gen.sv`'s
	// `TICK_NS` is 5 and stays 5, the board's own tick being 6.25 ns since
	// 2026-09-11 --- so this is the machine's own elapsed time in the
	// units muir counts it in, and it is a measurement rather than a
	// guess.  What it is NOT is consistent with the idle instants in
	// `Busint` above, which are a fresh machine's.
	chk_u64(w, img->ticks * 5u);			/* READ ns */

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
	chk_u32(w, img->l);				/* READ */
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
	// NONE: single step is not in this fabric --- the register block drops
	// the clock control register's bits 4:1 --- so SSTEP and SSDONE have
	// no reading and no meaning here.
	chk_bool(w, 0);					/* NONE sstep */
	chk_bool(w, 0);					/* NONE ssdone */
	chk_bool(w, img_flag(img, IMG_F_STATSTOP));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_HALTED));	/* READ */
	// NONE: OPC-CK is the OPC control register's, which is not built.
	chk_bool(w, 0);					/* NONE opc_ck */
	chk_u64(w, 0);					/* IDLE halted_ns */
	chk_bool(w, img_flag(img, IMG_F_MEMSTART));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_MBUSY));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_RDCYC));	/* READ */
	chk_bool(w, img_flag(img, IMG_F_WRCYC));	/* READ */
	emit_busint(w, img);
	chk_bool(w, img_flag(img, IMG_F_MBUSY_SYNC));	/* READ */
	// The bus cycle in the air.  IDLE, all of it: see the header.  The
	// physical address the fabric holds is in `phys_r` and is READ, but it
	// is the address of a cycle that has FINISHED, and muir's `bus_addr`
	// means one in flight --- so writing it would be putting a fact in a
	// field that means something else.
	chk_u32(w, 0);					/* IDLE bus_addr */
	chk_u32(w, 0);					/* IDLE bus_data */
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
	chk_u64(w, img->ticks * 5u);			/* READ ns, as above */
	chk_u32(w, 0);					/* IDLE busint_bus */
	chk_u64(w, ~(uint64_t)0);			/* IDLE loadmd_at */
	chk_opt_u16(w, 0, 0);				/* IDLE executed */
}

// --- what it could not read ------------------------------------------------

static const char *const kMissing[] = {
	"the mode register's TRAPENB: cadr_spy_registers.sv drops bit 4, so it",
	"    is written clear.  The fabric raises MIT's boot trap out of reset",
	"    instead of from this bit, so the machine behaves as it reads.",
	"the clock control register's STEP, NOP11, IDEBUG and LDSTAT: the same",
	"    block keeps bit 0 and drops bits 4:1.  A resumed machine cannot be",
	"    single-stepped from where the board left it; neither can the board.",
	"the OPC control register, all three bits: register 4 is dropped.  The",
	"    fabric behaves as all three clear, which is what is written.",
	"the debug IR, 48 bits: IDEBUG is not built, so there is nothing to read",
	"    and nothing that would look at it.",
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
	"the display's mode register, its sync RAM and its vertical-interrupt",
	"    flag.  The PICTURE is read, out of DDR, word for word.",
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

const char *const *chk_rtl_missing(void)
{
	return kMissing;
}

// --- what a mutant of this file was built to do ----------------------------
//
// **`CHK_MUTATE` IS NEVER DEFINED IN THE PROGRAM THAT GOES ON THE BOARD.**
// The host check builds this file again with each value and requires that
// the round trip through muir FAILS for each --- because a round trip that
// cannot fail says nothing, which is this repository's oldest lesson in its
// newest place.  The three are chosen to fail in three different ways: 1
// loads and re-saves DIFFERENT BYTES, 2 puts a field the window really does
// read where another belongs, and 3 drops one byte so that muir REFUSES the
// file outright.

const char *chk_rtl_mutation(void)
{
#if CHK_MUTATE == 1
	return "the mouse's quadrature phases written 0 where a fresh mouse has 2";
#elif CHK_MUTATE == 2
	return "Machine::opc taken from the OPC shift register instead of LPC";
#elif CHK_MUTATE == 3
	return "prog_boot dropped, so every byte after it is at the wrong offset";
#else
	return NULL;
#endif
}
