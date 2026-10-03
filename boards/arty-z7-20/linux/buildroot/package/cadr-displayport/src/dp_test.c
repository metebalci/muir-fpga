// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The check for cadr-displayport, on the build host: `dp_link.c` against a
// model of the Kria KR260's DisplayPort controller, its transceiver lane and
// the monitor on the other end, on a clock of the model's own.
//
// **THE MODEL IS THE BOARD AS THE K9 SPIKE MEASURED IT, AND NOT THE PROGRAM
// READ BACK.**  Its starting state is the stock board's, read off it: lane 1
// powered down (ICM_CFG0 0x05), DP_PHY_RESET 0x00010001, the live scale
// factors at 0x10101, the monitor at D0.  Its monitor behaves as the CG248 on
// the board did: DPCD 1.2 at HBR2, clock recovery only at voltage swing 2 or
// more, asking one level more each time until then, equalization under
// pattern 3 on its second look, the stream taken back after D3 and D0 without
// a training.  And the three traps the board showed are the model's too, as
// conditions on what the program does and never on what it is:
//
//   - a GT_RESET pulse after the lane is set up, and clock recovery never
//     comes again;
//   - a training begun with the main stream on, and the monitor answers no
//     request until the link has been electrically idle for ten seconds;
//   - the lane's PLL locks only when the lane is set up as the firmware sets
//     it for DisplayPort.
//
// What is held, each by a FAIL line: from the stock board, the link comes up
// with every lane write the firmware's, lane 0's field untouched, GT_RESET
// never set, the stream off through every training, the main stream
// attributes CEA-861's 1920x1080 with the transfer unit sized for HBR2, the
// live input RGB at eight bits with scale factors of exactly one, the fabric's
// clock and timing, and the monitor in sync; the mute puts the monitor in D3
// with the stream off and the release brings back D0 and the stream with no
// training; a monitor that loses the stream across D3 is trained again; a
// monitor unplugged and plugged back is brought up again; a monitor left deaf
// by an earlier training is waited out for ten seconds of an idle link and
// then trained; a monitor that drops the stream is found within the second
// and brought back; a second start leaves a lane already up alone; AUX's
// DEFER is asked again; and a word 36 without the marker is never a mute.

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "amd_dp_tables.h"
#include "dp_link.h"

static int bad;

static void fail(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	fprintf(stdout, "FAIL: ");
	vfprintf(stdout, fmt, ap);
	fprintf(stdout, "\n");
	va_end(ap);
	bad++;
}

#define SER_BASE 0xFD400000u

struct model {
	uint32_t ctrl[0xD000 / 4];
	uint32_t serdes[0x20000 / 4];
	uint32_t console[96];
	uint8_t dpcd[0x700];
	uint64_t now;
	int hpd;
	// AUX.
	uint8_t wfifo[16];
	unsigned nw;
	uint8_t reply[16];
	unsigned nreply, rpos;
	int defer_left;
	// The monitor's training state.
	unsigned cr_looks, eq_looks;
	int deaf;			// left deaf by a training with the stream on
	uint64_t idle_since;		// when the link last went electrically idle, or 0
	int lose_sync_on_d3;		// the monitor drops the stream across D3
	int dropped;			// the monitor dropped the stream by itself
	// What the program did.
	int lane_set_up;
	int gt_reset_after_lane;	// a GT_RESET pulse after the lane was set up
	unsigned trainings_with_stream_on;
	unsigned lane_writes;		// writes to the lane table's addresses
	unsigned trainings;		// training pattern 1 asked of the source
	uint64_t longest_idle;
	char last_log[256];
	int quiet;
};

static struct model M;

static uint32_t serdes_reg(uint32_t addr) { return M.serdes[(addr - SER_BASE) / 4]; }

static int lane_is_dp(void)
{
	return ((serdes_reg(0xFD410010u) >> 4) & 7u) == 4u &&
	       (serdes_reg(0xFD410004u) & 0x1Fu) == 9u;
}

static unsigned swing_level(void)
{
	switch (serdes_reg(AMD_PSGTR_L1_TX_MARGININGF) & 0x3Fu) {
	case 0x2a: return 0;
	case 0x27: return 1;
	case 0x24: return 2;
	case 0x20: return 3;
	default: return 0;
	}
}

static int link_idle(void)
{
	return M.ctrl[DPR_TRANSMITTER_ENABLE / 4] == 0 || (M.ctrl[DPR_TX_PHY_POWER_DOWN / 4] & 3u) == 3u;
}

static void note_idle(void)
{
	if (link_idle()) {
		if (!M.idle_since)
			M.idle_since = M.now ? M.now : 1;
	} else if (M.idle_since) {
		const uint64_t was = M.now - M.idle_since;
		if (was > M.longest_idle)
			M.longest_idle = was;
		if (M.deaf && was >= DP_IDLE_US)
			M.deaf = 0;
		M.idle_since = 0;
	}
}

static int trained(void)
{
	return M.dpcd[0x202] == 0x07 && M.dpcd[0x204] == 0x01;
}

static int msa_right(void)
{
	const uint32_t *c = M.ctrl;
	return c[DPR_MS_HTOTAL / 4] == 2200 && c[DPR_MS_VTOTAL / 4] == 1125 &&
	       c[DPR_MS_HSWIDTH / 4] == 44 && c[DPR_MS_VSWIDTH / 4] == 5 &&
	       c[DPR_MS_HRES / 4] == 1920 && c[DPR_MS_VRES / 4] == 1080 &&
	       c[DPR_MS_HSTART / 4] == 192 && c[DPR_MS_VSTART / 4] == 41 &&
	       c[DPR_MS_MISC0 / 4] == 0x20 && c[DPR_AV_BUF_LIVE_VID_CONFIG / 4] == 1 &&
	       c[DPR_AV_BUF_AUD_VID_CLK_SOURCE / 4] == 0 &&
	       c[DPR_AV_BUF_OUTPUT_AUDIO_VIDEO_SELECT / 4] == 0x3C;
}

static int in_sync(void)
{
	return M.hpd && !M.dropped && trained() && M.ctrl[DPR_TRAINING_PATTERN_SET / 4] == 0 &&
	       M.dpcd[0x102] == 0 && M.ctrl[DPR_MAIN_STREAM_ENABLE / 4] == 1 &&
	       M.ctrl[DPR_TRANSMITTER_ENABLE / 4] == 1 && msa_right();
}

// The monitor's answer to a read of its link status, 0x202 to 0x207.
static void sink_status(void)
{
	const uint32_t tp = M.ctrl[DPR_TRAINING_PATTERN_SET / 4] & 3u;
	const int sending = !link_idle() && lane_is_dp() && !M.gt_reset_after_lane &&
			    (M.ctrl[DPR_PHY_RESET / 4] & 3u) == 0;
	if (M.deaf || !sending) {
		M.dpcd[0x202] = 0; M.dpcd[0x204] = 0; M.dpcd[0x206] = 0;
		return;
	}
	if (tp == 1 && (M.dpcd[0x102] & 3u) == 1 && M.ctrl[DPR_SCRAMBLING_DISABLE / 4]) {
		M.cr_looks++;
		if (swing_level() >= 2) {
			M.dpcd[0x202] = 0x01;
			M.dpcd[0x206] = 0x02;
		} else {
			M.dpcd[0x202] = 0x00;
			M.dpcd[0x206] = (uint8_t)(swing_level() + 1);
		}
		M.dpcd[0x204] = 0;
	} else if (tp == 3 && (M.dpcd[0x102] & 3u) == 3 && (M.dpcd[0x202] & 1u)) {
		if (++M.eq_looks >= 2) {
			M.dpcd[0x202] = 0x07;
			M.dpcd[0x204] = 0x01;
		}
		M.dpcd[0x206] = 0x02;
	}
	M.dpcd[0x205] = in_sync() ? 1 : 0;
}

static void aux_command(uint32_t cmd)
{
	const uint32_t addr = M.ctrl[DPR_AUX_ADDRESS / 4];
	const unsigned len = (cmd & 0xFu) + 1u;
	const unsigned kind = (cmd >> 8) & 0xFu;
	M.nreply = 0;
	M.rpos = 0;
	M.ctrl[DPR_REPLY_STATUS / 4] = 0x1;
	if (!M.hpd) {
		M.ctrl[DPR_REPLY_STATUS / 4] = 0;
		M.ctrl[DPR_INTERRUPT_SIGNAL_STATE / 4] |= 0x8u;
		return;
	}
	if (M.defer_left > 0) {
		M.defer_left--;
		M.ctrl[DPR_AUX_REPLY_CODE / 4] = 2;
		return;
	}
	M.ctrl[DPR_AUX_REPLY_CODE / 4] = 0;
	if (addr + len > sizeof M.dpcd) {
		M.ctrl[DPR_AUX_REPLY_CODE / 4] = 1;
		return;
	}
	if (kind == 0x9u) {
		if (addr <= 0x207 && addr + len > 0x202)
			sink_status();
		if (addr <= 0x205 && addr + len > 0x205)
			M.dpcd[0x205] = in_sync() ? 1 : 0;
		memcpy(M.reply, &M.dpcd[addr], len);
		M.nreply = len;
	} else if (kind == 0x8u) {
		for (unsigned i = 0; i < len && i < M.nw; i++) {
			M.dpcd[addr + i] = M.wfifo[i];
			if (addr + i == 0x102 && (M.wfifo[i] & 3u) == 1u) {
				M.trainings++;
				M.cr_looks = M.eq_looks = 0;
				M.dpcd[0x202] = M.dpcd[0x204] = 0;
				if (M.ctrl[DPR_MAIN_STREAM_ENABLE / 4]) {
					M.trainings_with_stream_on++;
					M.deaf = 1;
				}
			}
			if (addr + i == 0x600 && M.wfifo[i] == 2 && M.lose_sync_on_d3)
				M.dpcd[0x202] = M.dpcd[0x204] = 0;
		}
	}
	M.nw = 0;
}

static uint32_t m_rd(struct dp_io *io, enum dp_space s, uint32_t off)
{
	(void)io;
	switch (s) {
	case DP_CTRL:
		if (off == DPR_AUX_REPLY_DATA)
			return M.rpos < M.nreply ? M.reply[M.rpos++] : 0;
		if (off == DPR_REPLY_DATA_COUNT)
			return M.nreply;
		if (off == DPR_INTERRUPT_SIGNAL_STATE)
			return (M.ctrl[off / 4] & ~1u) | (M.hpd ? 1u : 0u);
		if (off == DPR_PHY_STATUS)
			return (lane_is_dp() && (M.ctrl[DPR_PHY_RESET / 4] & 3u) == 0) ? 0x55u : 0x0u;
		return M.ctrl[off / 4];
	case DP_SERDES:
		if (off == AMD_PSGTR_L1_PLL_STATUS - SER_BASE)
			return lane_is_dp() ? 0x38u : 0x01u;
		return M.serdes[off / 4];
	case DP_CONSOLE:
		return M.console[off];
	}
	return 0;
}

static void m_wr(struct dp_io *io, enum dp_space s, uint32_t off, uint32_t v)
{
	(void)io;
	switch (s) {
	case DP_CTRL:
		if (off == DPR_AUX_WRITE_FIFO) {
			if (M.nw < 16)
				M.wfifo[M.nw++] = (uint8_t)v;
			return;
		}
		if (off == DPR_AUX_COMMAND) {
			M.ctrl[off / 4] = v;
			aux_command(v);
			return;
		}
		if (off == DPR_PHY_RESET && (v & DP_PHY_RESET_GT) && M.lane_set_up)
			M.gt_reset_after_lane = 1;
		M.ctrl[off / 4] = v;
		note_idle();
		return;
	case DP_SERDES: {
		const unsigned n = sizeof amd_psgtr_lane1_dp / sizeof amd_psgtr_lane1_dp[0];
		for (unsigned i = 0; i < n; i++)
			if (amd_psgtr_lane1_dp[i].addr - SER_BASE == off &&
			    off != AMD_PSGTR_L1_TX_MARGININGF - SER_BASE &&
			    off != AMD_PSGTR_L1_TX_DEEMPHASIS - SER_BASE)
				M.lane_writes++;
		M.serdes[off / 4] = v;
		if (lane_is_dp())
			M.lane_set_up = 1;
		return;
	}
	case DP_CONSOLE:
		M.console[off] = v;
		return;
	}
}

static void m_sleep(struct dp_io *io, uint32_t us)
{
	(void)io;
	M.now += us;
	note_idle();
}

static uint64_t m_now(struct dp_io *io)
{
	(void)io;
	return M.now;
}

static void m_log(struct dp_io *io, const char *line)
{
	(void)io;
	snprintf(M.last_log, sizeof M.last_log, "%s", line);
	if (!M.quiet && getenv("DP_TRACE"))
		printf("    [%llu us] %s\n", (unsigned long long)M.now, line);
}

static struct dp_io IO = { m_rd, m_wr, m_sleep, m_now, m_log, NULL };

// The stock board, as read off it in K9 (stock-dp-regs.txt, stock-clocks.txt).
static void stock(void)
{
	memset(&M, 0, sizeof M);
	M.now = 1000;
	M.hpd = 1;
	M.serdes[(0xFD410010u - SER_BASE) / 4] = 0x05;
	M.serdes[(0xFD410004u - SER_BASE) / 4] = 0x08;
	M.ctrl[DPR_PHY_RESET / 4] = 0x00010001;
	M.ctrl[DPR_VERSION / 4] = 0x04010000;
	M.ctrl[DPR_REPLY_STATUS / 4] = 0x10;
	M.ctrl[DPR_AV_BUF_OUTPUT_AUDIO_VIDEO_SELECT / 4] = 0x08;
	M.ctrl[DPR_AV_BUF_LIVE_VIDEO_COMP0_SF / 4] = 0x10101;
	M.ctrl[DPR_AV_BUF_LIVE_VIDEO_COMP1_SF / 4] = 0x10101;
	M.ctrl[DPR_AV_BUF_LIVE_VIDEO_COMP2_SF / 4] = 0x10101;
	static const uint8_t caps[16] = { 0x12, 0x14, 0xc4, 0x01, 0x00, 0x00, 0x01, 0x00,
					  0x02, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
	memcpy(M.dpcd, caps, sizeof caps);
	M.dpcd[0x200] = 0x41;
	M.dpcd[0x600] = 0x01;
	// Word 36: the marker, awake, 300 s.
	M.console[DP_CONSOLE_IDENT] = DP_CONSOLE_IDENT_WORD;
	M.console[DP_CONSOLE_SLEEP] = (DP_SLEEP_MARK << 16) | 300u;
}

static void steps(struct dp_keeper *k, int n)
{
	for (int i = 0; i < n; i++) {
		dp_keeper_step(&IO, k, M.console[DP_CONSOLE_SLEEP]);
		M.now += 100000;
		note_idle();
	}
}

static void hold_up(const char *when)
{
	if (!in_sync())
		fail("%s: the monitor is not in sync (0x202 %02x 0x204 %02x, stream %u, last: %s)", when,
		     M.dpcd[0x202], M.dpcd[0x204], M.ctrl[DPR_MAIN_STREAM_ENABLE / 4], M.last_log);
	if (M.gt_reset_after_lane)
		fail("%s: GT_RESET was set after the lane was set up", when);
	if (M.trainings_with_stream_on)
		fail("%s: %u trainings began with the main stream on", when, M.trainings_with_stream_on);
}

// **LANE 1 AS THE BOARD READ AFTER THE SETUP THAT WORKED**, a transcription
// of its own and not `amd_dp_tables.h` read back: the documented registers
// read off the stock board once its link was up from user space, each with
// the bits the firmware's write covers.  A table changed in the header is a lane that
// differs from this.
static const struct { uint32_t addr, mask, value; } board_lane1[] = {
	{ 0xFD410004u, 0x1Fu, 0x09u }, { 0xFD402864u, 0x80u, 0x80u },
	{ 0xFD406368u, 0xFFu, 0x58u }, { 0xFD40636Cu, 0x07u, 0x03u },
	{ 0xFD406370u, 0xFFu, 0x7Cu }, { 0xFD406374u, 0xFFu, 0x33u },
	{ 0xFD406378u, 0xFFu, 0x02u }, { 0xFD40637Cu, 0x33u, 0x30u },
	{ 0xFD405074u, 0x10u, 0x10u }, { 0xFD40507Cu, 0x0Fu, 0x01u },
	{ 0xFD4059A4u, 0xFFu, 0xFFu }, { 0xFD405038u, 0x40u, 0x40u },
	{ 0xFD40502Cu, 0x40u, 0x40u }, { 0xFD410010u, 0x77u, 0x45u },
	{ 0xFD404CB4u, 0x37u, 0x37u }, { 0xFD4041D8u, 0x01u, 0x01u },
};

static void test_from_stock(void)
{
	printf("  the stock board\n");
	stock();
	struct dp_keeper k;
	dp_keeper_init(&k);
	steps(&k, 3);
	hold_up("from the stock board");
	if (!k.up || k.bring_ups != 1 || k.failures)
		fail("from the stock board: up %d after %u bring-ups, %u failed", k.up, k.bring_ups, k.failures);
	const unsigned n = sizeof amd_psgtr_lane1_dp / sizeof amd_psgtr_lane1_dp[0];
	for (unsigned i = 0; i < n; i++) {
		const struct amd_psgtr_write *w = &amd_psgtr_lane1_dp[i];
		if (w->addr == AMD_PSGTR_L1_TX_MARGININGF || w->addr == AMD_PSGTR_L1_TX_DEEMPHASIS)
			continue;
		if ((serdes_reg(w->addr) & w->mask) != (w->value & w->mask))
			fail("lane 1: %s is %08x, the firmware's is %08x under %08x", w->name,
			     serdes_reg(w->addr), w->value, w->mask);
	}
	for (unsigned i = 0; i < sizeof board_lane1 / sizeof board_lane1[0]; i++)
		if ((serdes_reg(board_lane1[i].addr) & board_lane1[i].mask) != board_lane1[i].value)
			fail("lane 1: %08x reads %08x under %02x, the board read %02x after its setup",
			     board_lane1[i].addr, serdes_reg(board_lane1[i].addr), board_lane1[i].mask,
			     board_lane1[i].value);
	if ((serdes_reg(0xFD410010u) & 0x07u) != 0x05u)
		fail("lane 0's ICM field was changed: ICM_CFG0 %02x", serdes_reg(0xFD410010u));
	if (M.ctrl[DPR_PHY_RESET / 4] != 0x00010000u)
		fail("DP_PHY_RESET is %08x, want 00010000", M.ctrl[DPR_PHY_RESET / 4]);
	if (M.dpcd[0x100] != 0x14 || M.dpcd[0x101] != 0x81 || M.dpcd[0x107] != 0x10 || M.dpcd[0x108] != 0x01)
		fail("the link the monitor was told: %02x %02x .. %02x %02x, want 14 81 .. 10 01",
		     M.dpcd[0x100], M.dpcd[0x101], M.dpcd[0x107], M.dpcd[0x108]);
	if (M.ctrl[DPR_LINK_BW_SET / 4] != 0x14 || M.ctrl[DPR_LANE_COUNT_SET / 4] != 1 ||
	    M.ctrl[DPR_ENHANCED_FRAME_EN / 4] != 1 || M.ctrl[DPR_DOWNSPREAD_CTRL / 4] != 1)
		fail("the link the source was set to: bw %02x lanes %u enhanced %u downspread %u",
		     M.ctrl[DPR_LINK_BW_SET / 4], M.ctrl[DPR_LANE_COUNT_SET / 4],
		     M.ctrl[DPR_ENHANCED_FRAME_EN / 4], M.ctrl[DPR_DOWNSPREAD_CTRL / 4]);
	if (M.ctrl[DPR_PHY_CLOCK_SELECT / 4] != 5)
		fail("PHY_CLOCK_SELECT is %u, HBR2's is 5", M.ctrl[DPR_PHY_CLOCK_SELECT / 4]);
	if (M.ctrl[DPR_AUX_CLOCK_DIVIDER / 4] != ((40u << 8) | 99u))
		fail("AUX_CLOCK_DIVIDER is %08x", M.ctrl[DPR_AUX_CLOCK_DIVIDER / 4]);
	for (uint32_t off = DPR_AV_BUF_LIVE_VIDEO_COMP0_SF; off <= DPR_AV_BUF_LIVE_VIDEO_COMP2_SF; off += 4)
		if (M.ctrl[off / 4] != 0x10000u)
			fail("a live video scale factor is %05x, want exactly one, 10000",
			     M.ctrl[off / 4]);
	if (M.ctrl[DPR_V_BLEND_LAYER0_CONTROL / 4] != 0x102 || M.ctrl[DPR_V_BLEND_OUTPUT_VID_FORMAT / 4] != 0)
		fail("the blender: layer 0 %03x, output %u", M.ctrl[DPR_V_BLEND_LAYER0_CONTROL / 4],
		     M.ctrl[DPR_V_BLEND_OUTPUT_VID_FORMAT / 4]);
	if (M.ctrl[DPR_MSA_TU_SIZE / 4] != 64 || M.ctrl[DPR_MIN_BYTES_PER_TU / 4] != 52 ||
	    M.ctrl[DPR_FRAC_BYTES_PER_TU / 4] != 777 || M.ctrl[DPR_INIT_WAIT / 4] != 12 ||
	    M.ctrl[DPR_USER_DATA_COUNT_PER_LANE / 4] != 2879)
		fail("the transfer unit: size %u, bytes %u.%03u, wait %u, data count %u; want 64, 52.777, 12, 2879",
		     M.ctrl[DPR_MSA_TU_SIZE / 4], M.ctrl[DPR_MIN_BYTES_PER_TU / 4],
		     M.ctrl[DPR_FRAC_BYTES_PER_TU / 4], M.ctrl[DPR_INIT_WAIT / 4],
		     M.ctrl[DPR_USER_DATA_COUNT_PER_LANE / 4]);
	if (swing_level() != 2 || M.dpcd[0x103] != 0x02)
		fail("trained at swing %u, lane set %02x; the monitor takes swing 2, lane set 02",
		     swing_level(), M.dpcd[0x103]);
	if (M.ctrl[DPR_SCRAMBLING_DISABLE / 4] != 0 || M.ctrl[DPR_TRAINING_PATTERN_SET / 4] != 0)
		fail("training not ended: scrambling %u, pattern %u", M.ctrl[DPR_SCRAMBLING_DISABLE / 4],
		     M.ctrl[DPR_TRAINING_PATTERN_SET / 4]);
}

static void test_sleep_and_wake(int lose)
{
	printf("  the mute and its release%s\n", lose ? ", the monitor losing the stream across D3" : "");
	stock();
	M.lose_sync_on_d3 = lose;
	struct dp_keeper k;
	dp_keeper_init(&k);
	steps(&k, 3);
	hold_up("before the mute");
	const unsigned trained_before = M.trainings;
	M.console[DP_CONSOLE_SLEEP] |= DP_SLEEP_MUTED;
	steps(&k, 2);
	if (M.dpcd[0x600] != 2)
		fail("muted: the monitor's power state is %02x, want 02 (D3)", M.dpcd[0x600]);
	if (M.ctrl[DPR_MAIN_STREAM_ENABLE / 4] != 0)
		fail("muted: the main stream is still on");
	if (k.sleeps != 1)
		fail("muted: %u sleeps", k.sleeps);
	steps(&k, 30);
	if (M.dpcd[0x600] != 2 || M.ctrl[DPR_MAIN_STREAM_ENABLE / 4] != 0)
		fail("muted for 3 s: the monitor is at %02x and the stream %u", M.dpcd[0x600],
		     M.ctrl[DPR_MAIN_STREAM_ENABLE / 4]);
	M.console[DP_CONSOLE_SLEEP] &= ~DP_SLEEP_MUTED;
	steps(&k, 3);
	if (M.dpcd[0x600] != 1)
		fail("let go: the monitor's power state is %02x, want 01 (D0)", M.dpcd[0x600]);
	hold_up("after the wake");
	if (k.wakes != 1)
		fail("let go: %u wakes", k.wakes);
	if (!lose && M.trainings != trained_before)
		fail("a monitor that kept the stream across D3 was trained again");
	if (lose && M.trainings == trained_before)
		fail("a monitor that lost the stream across D3 was not trained again");
}

static void test_unplugged(void)
{
	printf("  the monitor unplugged and plugged back\n");
	stock();
	struct dp_keeper k;
	dp_keeper_init(&k);
	steps(&k, 3);
	hold_up("before the unplug");
	M.hpd = 0;
	M.dpcd[0x202] = M.dpcd[0x204] = 0;
	steps(&k, 5);
	if (M.ctrl[DPR_MAIN_STREAM_ENABLE / 4] != 0 || k.up)
		fail("unplugged: the stream is %u and the keeper up %d", M.ctrl[DPR_MAIN_STREAM_ENABLE / 4], k.up);
	M.hpd = 1;
	steps(&k, 3);
	hold_up("plugged back");
	if (k.bring_ups != 2)
		fail("plugged back: %u bring-ups, want 2", k.bring_ups);
	if (M.lane_writes > sizeof amd_psgtr_lane1_dp / sizeof amd_psgtr_lane1_dp[0])
		fail("plugged back: the lane was set up again (%u lane writes)", M.lane_writes);
}

static void test_deaf_monitor(void)
{
	printf("  a monitor left deaf by an earlier training\n");
	stock();
	M.deaf = 1;
	M.quiet = 1;
	struct dp_keeper k;
	dp_keeper_init(&k);
	const uint64_t t0 = M.now;
	steps(&k, 3);
	hold_up("after the idle wait");
	if (M.longest_idle < DP_IDLE_US)
		fail("the link was held idle for at most %llu us before the next training, want %u",
		     (unsigned long long)M.longest_idle, DP_IDLE_US);
	if (M.now - t0 > 60u * 1000000u)
		fail("the deaf monitor took %llu s", (unsigned long long)((M.now - t0) / 1000000u));
}

static void test_dropped(void)
{
	printf("  a monitor that drops the stream by itself\n");
	stock();
	struct dp_keeper k;
	dp_keeper_init(&k);
	steps(&k, 3);
	hold_up("before the drop");
	M.dropped = 1;
	M.dpcd[0x202] = M.dpcd[0x204] = 0;
	int n = 0;
	while (k.lost == 0 && n < 20) {
		steps(&k, 1);
		n++;
	}
	if (k.lost != 1 || n > 11)
		fail("dropped: noticed %u times, after %d steps of 0.1 s; want once within 1.1 s", k.lost, n);
	M.dropped = 0;
	steps(&k, 3);
	hold_up("after the drop");
	if (k.bring_ups != 2)
		fail("after the drop: %u bring-ups, want 2", k.bring_ups);
}

static void test_second_start(void)
{
	printf("  a second start, the lane already up\n");
	stock();
	struct dp_keeper k;
	dp_keeper_init(&k);
	steps(&k, 3);
	hold_up("the first start");
	const unsigned writes = M.lane_writes;
	dp_stream_off(&IO);
	dp_keeper_init(&k);
	steps(&k, 3);
	hold_up("the second start");
	if (M.lane_writes != writes)
		fail("a second start wrote the lane again: %u writes, then %u", writes, M.lane_writes);
}

static void test_defer(void)
{
	printf("  the monitor answers DEFER\n");
	stock();
	M.defer_left = 5;
	struct dp_keeper k;
	dp_keeper_init(&k);
	steps(&k, 3);
	hold_up("after DEFERs");
}

static void test_no_marker(void)
{
	printf("  a word 36 without the display output's marker\n");
	stock();
	M.console[DP_CONSOLE_SLEEP] = 0x0000FFFFu;	// bit 15 set, no marker
	struct dp_keeper k;
	dp_keeper_init(&k);
	steps(&k, 3);
	hold_up("with no marker");
	if (k.sleeps)
		fail("a word without the marker was taken for a mute");
}

static void test_drive(void)
{
	printf("  the drive table\n");
	stock();
	struct { unsigned vs, pe; uint8_t m, d, set; } c[] = {
		{ 0, 0, 0x2a, 0x02, 0x00 }, { 1, 0, 0x27, 0x02, 0x01 }, { 2, 0, 0x24, 0x02, 0x02 },
		{ 3, 0, 0x20, 0x02, 0x27 }, { 2, 1, 0x20, 0x01, 0x2e }, { 0, 2, 0x24, 0x00, 0x30 },
		{ 3, 3, 0x20, 0x00, 0x35 },
	};
	for (unsigned i = 0; i < sizeof c / sizeof c[0]; i++) {
		const uint8_t set = dp_drive(&IO, c[i].vs, c[i].pe);
		const uint8_t m = serdes_reg(AMD_PSGTR_L1_TX_MARGININGF), d = serdes_reg(AMD_PSGTR_L1_TX_DEEMPHASIS);
		if (m != c[i].m || d != c[i].d || set != c[i].set)
			fail("swing %u pre-emphasis %u: margining %02x de-emphasis %02x lane set %02x, "
			     "want %02x %02x %02x", c[i].vs, c[i].pe, m, d, set, c[i].m, c[i].d, c[i].set);
	}
}

int main(void)
{
	printf("dp_test: cadr-displayport against a model of the board\n");
	test_from_stock();
	test_drive();
	test_sleep_and_wake(0);
	test_sleep_and_wake(1);
	test_unplugged();
	test_deaf_monitor();
	test_dropped();
	test_second_start();
	test_defer();
	test_no_marker();
	if (bad) {
		printf("dp_test: %d failure(s)\n", bad);
		return 1;
	}
	printf("ok: cadr-displayport brings the link up from the stock board, follows the mute, "
	       "and recovers from an unplug, a deaf monitor and a dropped stream\n");
	return 0;
}
