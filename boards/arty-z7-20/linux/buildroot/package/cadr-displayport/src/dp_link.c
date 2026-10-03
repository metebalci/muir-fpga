// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Kria KR260's DisplayPort link.  `dp_link.h` is the account: what each
// step is written from, and the five things the board showed that each step
// obeys.

#include "dp_link.h"

#include <stdarg.h>
#include <stdio.h>

#include "amd_dp_tables.h"

static void logf_(struct dp_io *io, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void logf_(struct dp_io *io, const char *fmt, ...)
{
	char line[256];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(line, sizeof line, fmt, ap);
	va_end(ap);
	io->log(io, line);
}

static uint32_t rd(struct dp_io *io, uint32_t off) { return io->rd(io, DP_CTRL, off); }
static void wr(struct dp_io *io, uint32_t off, uint32_t v) { io->wr(io, DP_CTRL, off, v); }

// ------------------------------------------------------------------ AUX
//
// UG1085's "Accessing the Link Partner" and UG1087's AUX registers: the
// address, up to sixteen bytes into the write FIFO, then the command, whose
// write starts the transaction; the reply is received when REPLY_STATUS
// says so with nothing in progress, and its code is ACK, NACK or DEFER.  A
// DEFER is asked again, and so is a reply that timed out.
int dp_aux(struct dp_io *io, int write, uint32_t addr, uint8_t *buf, unsigned len)
{
	if (len == 0 || len > 16)
		return -1;
	for (int attempt = 0; attempt < 16; attempt++) {
		uint64_t t0 = io->now_us(io);
		while (rd(io, DPR_REPLY_STATUS) & 0x6u)
			if (io->now_us(io) - t0 > 10000u) {
				logf_(io, "AUX: the channel is busy at %05x", (unsigned)addr);
				return -1;
			}
		wr(io, DPR_AUX_ADDRESS, addr);
		if (write)
			for (unsigned i = 0; i < len; i++)
				wr(io, DPR_AUX_WRITE_FIFO, buf[i]);
		wr(io, DPR_AUX_COMMAND, ((write ? 0x8u : 0x9u) << 8) | (len - 1u));
		io->sleep_us(io, 50);
		t0 = io->now_us(io);
		int got = 0;
		for (;;) {
			const uint32_t st = rd(io, DPR_REPLY_STATUS);
			if ((st & 0x1u) && !(st & 0x6u)) {
				got = 1;
				break;
			}
			if (rd(io, DPR_INTERRUPT_SIGNAL_STATE) & 0x8u)
				break;
			if (io->now_us(io) - t0 > 10000u)
				break;
			io->sleep_us(io, 20);
		}
		if (!got) {
			io->sleep_us(io, 500);
			continue;
		}
		const uint32_t code = rd(io, DPR_AUX_REPLY_CODE) & 3u;
		if (code == 2u) {		// DEFER
			io->sleep_us(io, 500);
			continue;
		}
		if (code == 1u) {
			logf_(io, "AUX: the monitor refused %s at %05x", write ? "a write" : "a read",
			      (unsigned)addr);
			return -1;
		}
		if (!write) {
			const unsigned n = rd(io, DPR_REPLY_DATA_COUNT) & 0x1Fu;
			for (unsigned i = 0; i < n && i < len; i++)
				buf[i] = rd(io, DPR_AUX_REPLY_DATA) & 0xFFu;
			if (n != len) {
				logf_(io, "AUX: %u of %u bytes at %05x", n, len, (unsigned)addr);
				return -1;
			}
		}
		return 0;
	}
	logf_(io, "AUX: no answer at %05x", (unsigned)addr);
	return -1;
}

int dp_dpcd_rd(struct dp_io *io, uint32_t addr, uint8_t *buf, unsigned len)
{
	return dp_aux(io, 0, addr, buf, len);
}

int dp_dpcd_wr1(struct dp_io *io, uint32_t addr, uint8_t v)
{
	return dp_aux(io, 1, addr, &v, 1);
}

// ---------------------------------------------------------- the lane
//
// **RULE 1: THE LANE IS SET UP HERE, BECAUSE NOTHING ELSE DOES IT.**  The
// writes are the generated firmware's (`amd_dp_tables.h`), masked as it
// masks them.  A lane already set up for DisplayPort with its PLL locked ---
// this program started a second time --- is left as it is: writing it again
// under a live link is not something the board was measured doing.
int dp_lane_setup(struct dp_io *io)
{
	const uint32_t icm = io->rd(io, DP_SERDES, 0xFD410010u - 0xFD400000u);
	const uint32_t lock = io->rd(io, DP_SERDES, AMD_PSGTR_L1_PLL_STATUS - 0xFD400000u);
	if (((icm >> 4) & 7u) == 4u && (lock & AMD_PSGTR_L1_PLL_LOCKED)) {
		logf_(io, "lane 1 is already DisplayPort's and its PLL is locked (ICM_CFG0 %02x)",
		      (unsigned)icm);
		return 0;
	}
	logf_(io, "lane 1 is not set up (ICM_CFG0 %02x); setting it up for DisplayPort",
	      (unsigned)icm);
	const unsigned n = sizeof amd_psgtr_lane1_dp / sizeof amd_psgtr_lane1_dp[0];
	for (unsigned i = 0; i < n; i++) {
		const struct amd_psgtr_write *w = &amd_psgtr_lane1_dp[i];
		const uint32_t off = w->addr - 0xFD400000u;
		const uint32_t v = io->rd(io, DP_SERDES, off);
		io->wr(io, DP_SERDES, off, (v & ~w->mask) | (w->value & w->mask));
	}
	const uint64_t t0 = io->now_us(io);
	while (!(io->rd(io, DP_SERDES, AMD_PSGTR_L1_PLL_STATUS - 0xFD400000u) & AMD_PSGTR_L1_PLL_LOCKED)) {
		if (io->now_us(io) - t0 > 500000u) {
			logf_(io, "lane 1: the PLL did not lock");
			return -1;
		}
		io->sleep_us(io, 100);
	}
	return 0;
}

// ----------------------------------------------------------- the PHY
//
// UG1085's "Source Controller Setup", with **RULE 2**: GT_RESET is never set.
// The transmitter off, the AUX clock divided from the APB's 99.99 MHz
// (topsw_lsbus) with a 400 ns pulse filter, HBR2's clock, the lane powered,
// the firmware's bit 0 released, and the PHY's reset done and PLL locked
// before the transmitter is enabled.
int dp_phy_up(struct dp_io *io)
{
	wr(io, DPR_TRANSMITTER_ENABLE, 0);
	wr(io, DPR_AUX_CLOCK_DIVIDER, (40u << 8) | 99u);
	wr(io, DPR_PHY_CLOCK_SELECT, DP_LINK_BW == 0x14u ? 5u : DP_LINK_BW == 0x0Au ? 3u : 1u);
	wr(io, DPR_TX_PHY_POWER_DOWN, 0);
	wr(io, DPR_PHY_RESET, DP_PHY_RESET_8B10B);
	const uint64_t t0 = io->now_us(io);
	while ((rd(io, DPR_PHY_STATUS) & 0x11u) != 0x11u) {
		if (io->now_us(io) - t0 > 500000u) {
			logf_(io, "the PHY is not ready: PHY_STATUS %08x", (unsigned)rd(io, DPR_PHY_STATUS));
			return -1;
		}
		io->sleep_us(io, 100);
	}
	wr(io, DPR_TRANSMITTER_ENABLE, 1);
	return 0;
}

// **RULE 5**: the level the monitor asks for, as far as the table goes, onto
// the lane, and the TRAINING_LANE0_SET byte that says so, with each "maximum
// reached" flag set where the table goes no further.
uint8_t dp_drive(struct dp_io *io, unsigned vs, unsigned pe)
{
	if (vs > 3) vs = 3;
	if (pe > 3) pe = 3;
	while (pe > 0 && amd_dp_pe[pe][0] == 0xff)
		pe--;
	while (vs > 0 && amd_dp_vs[pe][vs] == 0xff)
		vs--;
	io->wr(io, DP_SERDES, AMD_PSGTR_L1_TX_MARGININGF - 0xFD400000u, amd_dp_vs[pe][vs]);
	io->wr(io, DP_SERDES, AMD_PSGTR_L1_TX_DEEMPHASIS - 0xFD400000u, amd_dp_pe[pe][vs]);
	uint8_t set = (uint8_t)(vs | pe << 3);
	if (vs == 3 || amd_dp_vs[pe][vs + 1] == 0xff)
		set |= 0x04;
	if (pe == 3 || amd_dp_pe[pe + 1][vs] == 0xff)
		set |= 0x20;
	return set;
}

// ------------------------------------------------------ the training
//
// UG1085's "Upon HPD Assertion" and its two procedures, at HBR2 on one lane
// with enhanced framing, and training pattern 3 for the second, as its note
// says for 5.4 Gb/s.  **RULE 3: THE MAIN STREAM IS OFF FIRST.**  The sink is
// told D0 before anything else.  The lane's PLL spreads its clock (the
// firmware's spread settings), so both ends are told the link is
// down-spread.
int dp_train(struct dp_io *io)
{
	uint8_t caps[16], st[6], v;
	wr(io, DPR_MAIN_STREAM_ENABLE, 0);
	if (dp_dpcd_rd(io, 0x000, caps, 16))
		return -1;
	dp_dpcd_wr1(io, 0x600, 1);
	io->sleep_us(io, 1000);
	wr(io, DPR_LINK_BW_SET, DP_LINK_BW);
	wr(io, DPR_LANE_COUNT_SET, 1);
	wr(io, DPR_ENHANCED_FRAME_EN, 1);
	wr(io, DPR_DOWNSPREAD_CTRL, 1);
	if (dp_dpcd_wr1(io, 0x100, DP_LINK_BW) || dp_dpcd_wr1(io, 0x101, 0x81) ||
	    dp_dpcd_wr1(io, 0x107, 0x10) || dp_dpcd_wr1(io, 0x108, 0x01))
		return -1;
	const unsigned rd_interval = caps[14] & 0x7Fu;

	// Clock recovery: training pattern 1, scrambling off.
	wr(io, DPR_SCRAMBLING_DISABLE, 1);
	wr(io, DPR_TRAINING_PATTERN_SET, 1);
	dp_dpcd_wr1(io, 0x102, 0x21);
	uint8_t lane_set = dp_drive(io, 0, 0);
	int cr = 0;
	for (int i = 0; i < 5 && !cr; i++) {
		dp_dpcd_wr1(io, 0x103, lane_set);
		io->sleep_us(io, 100u + rd_interval * 4000u);
		if (dp_dpcd_rd(io, 0x202, st, 6))
			break;
		cr = st[0] & 1u;
		if (!cr)
			lane_set = dp_drive(io, st[4] & 3u, (st[4] >> 2) & 3u);
	}
	if (!cr) {
		logf_(io, "training: no clock recovery at lane set %02x", lane_set);
		goto fail;
	}

	// Channel equalization, symbol lock and alignment: pattern 3 (or 2).
	const unsigned tps = (caps[2] & 0x40u) ? 3u : 2u;
	wr(io, DPR_TRAINING_PATTERN_SET, tps);
	dp_dpcd_wr1(io, 0x102, (uint8_t)(0x20u | tps));
	int eq = 0;
	for (int i = 0; i < 5 && !eq; i++) {
		dp_dpcd_wr1(io, 0x103, lane_set);
		io->sleep_us(io, 400u + rd_interval * 4000u);
		if (dp_dpcd_rd(io, 0x202, st, 6))
			break;
		eq = (st[0] & 7u) == 7u && (st[2] & 1u);
		if (!eq)
			lane_set = dp_drive(io, st[4] & 3u, (st[4] >> 2) & 3u);
	}
	if (!eq) {
		logf_(io, "training: no equalization at lane set %02x", lane_set);
		goto fail;
	}
	dp_dpcd_wr1(io, 0x102, 0x00);
	wr(io, DPR_TRAINING_PATTERN_SET, 0);
	wr(io, DPR_SCRAMBLING_DISABLE, 0);
	if (dp_dpcd_rd(io, 0x103, &v, 1) == 0)
		logf_(io, "trained at %02x on one lane, lane set %02x", DP_LINK_BW, v);
	return 0;
fail:
	dp_dpcd_wr1(io, 0x102, 0x00);
	wr(io, DPR_TRAINING_PATTERN_SET, 0);
	wr(io, DPR_SCRAMBLING_DISABLE, 0);
	return -1;
}

// -------------------------------------------------------- the stream
//
// The live input as the fabric drives it --- RGB, eight bits a component,
// the fabric's clock and the fabric's timing --- layer 0 passed through the
// blender, and **RULE 4: SCALE FACTORS OF EXACTLY ONE.**  Then the main stream
// attributes for the board's mode, the transfer unit sized for HBR2 on one
// lane, the scrambler reset, and the stream on.
void dp_stream_on(struct dp_io *io)
{
	// 64-byte transfer units: the bytes a unit carries are the stream's rate
	// over the link's, times 64; UG1087 gives the integer and the thousandths.
	const uint64_t num = 64ull * 3ull * DP_PIXEL_KHZ;
	const uint64_t den = DP_LINK_BW == 0x14u ? 540000ull : DP_LINK_BW == 0x0Au ? 270000ull : 162000ull;
	const uint32_t min_bytes = (uint32_t)(num / den);
	const uint32_t frac = (uint32_t)((num % den) * 1000ull / den);

	wr(io, DPR_MAIN_STREAM_ENABLE, 0);
	wr(io, DPR_AV_BUF_SRST_REG, 2);
	wr(io, DPR_AV_BUF_LIVE_VID_CONFIG, 0x01);		// RGB, 8 bits a component
	wr(io, DPR_AV_BUF_LIVE_VIDEO_COMP0_SF, 0x10000);
	wr(io, DPR_AV_BUF_LIVE_VIDEO_COMP1_SF, 0x10000);
	wr(io, DPR_AV_BUF_LIVE_VIDEO_COMP2_SF, 0x10000);
	wr(io, DPR_AV_BUF_OUTPUT_AUDIO_VIDEO_SELECT, 0x3C);	// video 1 live, nothing else
	wr(io, DPR_AV_BUF_AUD_VID_CLK_SOURCE, 0);		// the fabric's clock and timing
	wr(io, DPR_V_BLEND_LAYER0_CONTROL, 0x102);		// RGB, passed through
	wr(io, DPR_V_BLEND_OUTPUT_VID_FORMAT, 0);		// RGB
	wr(io, DPR_V_BLEND_SET_GLOBAL_ALPHA, 0);
	wr(io, DPR_AV_BUF_SRST_REG, 0);

	wr(io, DPR_MS_HTOTAL, DP_H_ACTIVE + DP_H_FRONT + DP_H_SYNC + DP_H_BACK);
	wr(io, DPR_MS_VTOTAL, DP_V_ACTIVE + DP_V_FRONT + DP_V_SYNC + DP_V_BACK);
	wr(io, DPR_MS_HSWIDTH, DP_H_SYNC);
	wr(io, DPR_MS_VSWIDTH, DP_V_SYNC);
	wr(io, DPR_MS_HRES, DP_H_ACTIVE);
	wr(io, DPR_MS_VRES, DP_V_ACTIVE);
	wr(io, DPR_MS_HSTART, DP_H_SYNC + DP_H_BACK);
	wr(io, DPR_MS_VSTART, DP_V_SYNC + DP_V_BACK);
	wr(io, DPR_MS_MISC0, 0x20);		// 8 bits a component, RGB, asynchronous clock
	wr(io, DPR_MS_MISC1, 0);
	wr(io, DPR_MSA_TU_SIZE, 64);
	wr(io, DPR_MIN_BYTES_PER_TU, min_bytes);
	wr(io, DPR_FRAC_BYTES_PER_TU, frac);
	wr(io, DPR_USER_DATA_COUNT_PER_LANE, DP_H_ACTIVE * 24u / 16u - 1u);
	wr(io, DPR_INIT_WAIT, min_bytes <= 4u ? 64u : 64u - min_bytes);
	wr(io, DPR_FORCE_SCRAMBLER_RESET, 1);
	wr(io, DPR_MAIN_STREAM_ENABLE, 1);
}

void dp_stream_off(struct dp_io *io)
{
	wr(io, DPR_MAIN_STREAM_ENABLE, 0);
}

int dp_hpd(struct dp_io *io)
{
	return rd(io, DPR_INTERRUPT_SIGNAL_STATE) & 1u;
}

int dp_in_sync(struct dp_io *io)
{
	uint8_t s;
	return dp_dpcd_rd(io, 0x205, &s, 1) == 0 && (s & 1u);
}

// The link, from nothing: the lane, the PHY, and up to three trainings.
// **RULE 3's other half**: after a training that failed, the link is held
// electrically idle for `DP_IDLE_US` before the next, which is what brought
// the monitor back on the board.
int dp_bring_up(struct dp_io *io)
{
	if (dp_lane_setup(io) || dp_phy_up(io))
		return -1;
	for (int attempt = 0; attempt < 3; attempt++) {
		if (attempt) {
			logf_(io, "holding the link idle for %u s before training again",
			      DP_IDLE_US / 1000000u);
			wr(io, DPR_TRANSMITTER_ENABLE, 0);
			wr(io, DPR_TX_PHY_POWER_DOWN, 0xF);
			io->sleep_us(io, DP_IDLE_US);
			if (dp_phy_up(io))
				return -1;
		}
		if (dp_train(io))
			continue;
		dp_stream_on(io);
		io->sleep_us(io, 100000);
		if (dp_in_sync(io)) {
			logf_(io, "the monitor has the stream: %ux%u at 60 Hz", DP_H_ACTIVE, DP_V_ACTIVE);
			return 0;
		}
		logf_(io, "trained, and the monitor does not take the stream");
		dp_stream_off(io);
	}
	return -1;
}

// ------------------------------------------------------- the keeper

void dp_keeper_init(struct dp_keeper *k)
{
	*k = (struct dp_keeper){0};
}

void dp_keeper_step(struct dp_io *io, struct dp_keeper *k, uint32_t word36)
{
	const uint64_t now = io->now_us(io);
	const int muted = (word36 >> 16) == DP_SLEEP_MARK && (word36 & DP_SLEEP_MUTED);

	if (!dp_hpd(io)) {
		if (k->up) {
			logf_(io, "the monitor is gone; the stream is off until it is back");
			dp_stream_off(io);
			k->up = 0;
			k->asleep = 0;
			k->lost++;
		}
		return;
	}
	if (!k->up) {
		// Nothing to show while the display output is muted: the link is
		// brought up when it is let go.
		if (muted || now < k->retry_at_us)
			return;
		k->bring_ups++;
		if (dp_bring_up(io) == 0) {
			k->up = 1;
			k->asleep = 0;
			k->next_check_us = io->now_us(io) + 1000000u;
		} else {
			k->failures++;
			k->retry_at_us = io->now_us(io) + 5000000u;
			logf_(io, "the link did not come up; trying again in 5 s");
		}
		return;
	}
	if (muted && !k->asleep) {
		// Asleep: the stream off and the monitor told D3.
		dp_stream_off(io);
		dp_dpcd_wr1(io, 0x600, 2);
		k->asleep = 1;
		k->sleeps++;
		logf_(io, "the display output is muted: the monitor is told D3, the stream is off");
		return;
	}
	if (!muted && k->asleep) {
		// Awake: D0 and the stream; trained again if the monitor does not
		// take it back.
		dp_dpcd_wr1(io, 0x600, 1);
		io->sleep_us(io, 1000);
		dp_stream_on(io);
		io->sleep_us(io, 100000);
		k->asleep = 0;
		k->wakes++;
		if (dp_in_sync(io)) {
			logf_(io, "the display output is let go: D0, and the monitor has the stream");
		} else {
			logf_(io, "the display output is let go: D0, and the monitor wants training");
			k->trainings++;
			if (dp_train(io) == 0) {
				dp_stream_on(io);
			} else {
				k->up = 0;
				k->retry_at_us = io->now_us(io);
			}
		}
		k->next_check_us = io->now_us(io) + 1000000u;
		return;
	}
	if (!k->asleep && now >= k->next_check_us) {
		k->next_check_us = now + 1000000u;
		if (!dp_in_sync(io)) {
			logf_(io, "the monitor dropped the stream; bringing the link up again");
			dp_stream_off(io);
			k->up = 0;
			k->lost++;
		}
	}
}
