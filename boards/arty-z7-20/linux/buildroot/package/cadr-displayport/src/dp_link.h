// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The Kria KR260's DisplayPort link: brought up, kept and put to sleep from
// user space, with no display driver in the kernel.
//
// **THE PICTURE IS THE FABRIC'S AND THE LINK IS THIS PROGRAM'S.**  The display
// output (`rtl/plumbing/cadr_display_out.sv`) puts the machine's screens on a
// 1920x1080 raster and hands it to the processing system's DisplayPort
// controller's live video input; pixels never pass through software.  The
// controller does nothing until somebody sets up its transceiver lane, trains
// the link with the monitor and tells it what the stream is, and only the
// processing system reaches its registers.  That is this program, the
// counterpart of the DE25-Nano's `cadr_adv7513.sv`.
//
// **WRITTEN FROM UG1085 AND UG1087**: chapter 33's "Source Controller Setup
// and Initialization", "Upon HPD Assertion", the two training procedures,
// "Enabling Main Link Video" and "Accessing the Link Partner", and the
// DISPLAY_PORT module's register descriptions.  Not from Linux's driver,
// whose license does not mix with this one.  The lane's own writes and the
// swing table are AMD's, MIT-licensed, in `amd_dp_tables.h`.
//
// **FIVE THINGS THE BOARD SHOWED, EACH MEASURED IN THE KR260 PORT'S K9 SPIKE,
// AND EACH A RULE HERE:**
//
//   1. The factory boot firmware leaves the transceiver's lane 1 powered
//      down, so this program makes the lane-1 writes the firmware would have
//      made for DisplayPort (`dp_lane_setup`).
//   2. A pulse of DP_PHY_RESET's GT_RESET after the lane is set up breaks
//      clock recovery for good, under Linux's own driver too.  The firmware
//      leaves bit 0 of that register set and GT_RESET clear; only bit 0 is
//      released, and GT_RESET is never written to one (`dp_phy_up`).
//   3. A training with the main stream on fails, and leaves this monitor
//      answering no request until the link has been electrically idle for
//      about ten seconds.  So the stream is always off while the link trains,
//      and a failed training is followed by the link powered down for
//      `DP_IDLE_US` before the next (`dp_bring_up`).
//   4. The live video's scale factors come up at 0x10101, UG1087's value for
//      eight bits a component, and that turns 248 to 254 into 249 to 255 on
//      every channel.  At 0x10000 every value of every channel arrives as it
//      left the fabric, measured by the monitor's own CRC (`dp_stream_on`).
//   5. Voltage swing and pre-emphasis are the lane's margining factor and
//      de-emphasis registers, set from AMD's table at each level the monitor
//      asks for (`dp_drive`).
//
// **AND THE REGISTERS ARE REACHED THROUGH A SEAM**, `struct dp_io`, so that
// `dp_test.c` puts a model of the controller, the lane and the monitor behind
// it on the build host, and the board puts /dev/mem.

#ifndef DP_LINK_H
#define DP_LINK_H

#include <stdint.h>

// The board's mode: CEA-861's 1920x1080 at 60 Hz, both syncs positive, as the
// fabric's raster is built (`boards/kria-kr260/display_raster.mk`), and the
// fabric's pixel clock, 25 MHz x 47.5 / 8.
#define DP_H_ACTIVE   1920u
#define DP_H_FRONT      88u
#define DP_H_SYNC       44u
#define DP_H_BACK      148u
#define DP_V_ACTIVE   1080u
#define DP_V_FRONT       4u
#define DP_V_SYNC        5u
#define DP_V_BACK       36u
#define DP_PIXEL_KHZ  148437u

// The link: HBR2, 5.4 Gb/s, on the one lane the carrier wires (UG1092).
// Measured: this rate on this lane carries the mode, and the monitor trains to
// it at voltage swing 2.
#define DP_LINK_BW    0x14u

// How long the link is held electrically idle after a failed training, so
// that a monitor left deaf by it hears the next (rule 3 above).
#define DP_IDLE_US    (10u * 1000u * 1000u)

// The address spaces the seam reaches.
enum dp_space { DP_CTRL, DP_SERDES, DP_CONSOLE };

struct dp_io {
	uint32_t (*rd)(struct dp_io *io, enum dp_space s, uint32_t off);
	void (*wr)(struct dp_io *io, enum dp_space s, uint32_t off, uint32_t v);
	void (*sleep_us)(struct dp_io *io, uint32_t us);
	uint64_t (*now_us)(struct dp_io *io);
	void (*log)(struct dp_io *io, const char *line);
	void *ctx;
};

// UG1087's DISPLAY_PORT offsets this program uses.
enum {
	DPR_LINK_BW_SET = 0x000, DPR_LANE_COUNT_SET = 0x004, DPR_ENHANCED_FRAME_EN = 0x008,
	DPR_TRAINING_PATTERN_SET = 0x00C, DPR_SCRAMBLING_DISABLE = 0x014,
	DPR_DOWNSPREAD_CTRL = 0x018, DPR_TRANSMITTER_ENABLE = 0x080,
	DPR_MAIN_STREAM_ENABLE = 0x084, DPR_FORCE_SCRAMBLER_RESET = 0x0C0,
	DPR_VERSION = 0x0F8, DPR_AUX_COMMAND = 0x100, DPR_AUX_WRITE_FIFO = 0x104,
	DPR_AUX_ADDRESS = 0x108, DPR_AUX_CLOCK_DIVIDER = 0x10C,
	DPR_INTERRUPT_SIGNAL_STATE = 0x130, DPR_AUX_REPLY_DATA = 0x134,
	DPR_AUX_REPLY_CODE = 0x138, DPR_REPLY_DATA_COUNT = 0x148, DPR_REPLY_STATUS = 0x14C,
	DPR_MS_HTOTAL = 0x180, DPR_MS_VTOTAL = 0x184, DPR_MS_HSWIDTH = 0x18C,
	DPR_MS_VSWIDTH = 0x190, DPR_MS_HRES = 0x194, DPR_MS_VRES = 0x198,
	DPR_MS_HSTART = 0x19C, DPR_MS_VSTART = 0x1A0, DPR_MS_MISC0 = 0x1A4,
	DPR_MS_MISC1 = 0x1A8, DPR_MSA_TU_SIZE = 0x1B0, DPR_USER_DATA_COUNT_PER_LANE = 0x1BC,
	DPR_MIN_BYTES_PER_TU = 0x1C4, DPR_FRAC_BYTES_PER_TU = 0x1C8, DPR_INIT_WAIT = 0x1CC,
	DPR_PHY_RESET = 0x200, DPR_PHY_CLOCK_SELECT = 0x234, DPR_TX_PHY_POWER_DOWN = 0x238,
	DPR_PHY_STATUS = 0x280,
	DPR_V_BLEND_SET_GLOBAL_ALPHA = 0xA00C, DPR_V_BLEND_OUTPUT_VID_FORMAT = 0xA014,
	DPR_V_BLEND_LAYER0_CONTROL = 0xA018,
	DPR_AV_BUF_OUTPUT_AUDIO_VIDEO_SELECT = 0xB070, DPR_AV_BUF_AUD_VID_CLK_SOURCE = 0xB120,
	DPR_AV_BUF_SRST_REG = 0xB124, DPR_AV_BUF_LIVE_VIDEO_COMP0_SF = 0xB218,
	DPR_AV_BUF_LIVE_VIDEO_COMP1_SF = 0xB21C, DPR_AV_BUF_LIVE_VIDEO_COMP2_SF = 0xB220,
	DPR_AV_BUF_LIVE_VID_CONFIG = 0xB224,
	DPR_PATGEN_CRC_R = 0xCC10, DPR_PATGEN_CRC_G = 0xCC14, DPR_PATGEN_CRC_B = 0xCC18,
};

// DP_PHY_RESET: 8b/10b encoding in bit 16, GT_RESET in bit 1, and bit 0, which
// the firmware leaves set and is released here (rule 2).
#define DP_PHY_RESET_8B10B    0x00010000u
#define DP_PHY_RESET_GT       0x00000002u

// The console's page 2 word 36 (`rtl/plumbing/cadr_console.sv`): the display
// output's marker in the top half, the mute in bit 15.
#define DP_CONSOLE_IDENT      0u
#define DP_CONSOLE_IDENT_WORD 0x434F4E53u	/* "CONS" */
#define DP_CONSOLE_SLEEP      36u
#define DP_SLEEP_MARK         0x5A5Au
#define DP_SLEEP_MUTED        0x8000u

// DPCD.
int dp_aux(struct dp_io *io, int write, uint32_t addr, uint8_t *buf, unsigned len);
int dp_dpcd_rd(struct dp_io *io, uint32_t addr, uint8_t *buf, unsigned len);
int dp_dpcd_wr1(struct dp_io *io, uint32_t addr, uint8_t v);

// The steps.  Each returns 0, or -1 having logged why.
int dp_lane_setup(struct dp_io *io);
int dp_phy_up(struct dp_io *io);
uint8_t dp_drive(struct dp_io *io, unsigned vs, unsigned pe);
int dp_train(struct dp_io *io);
void dp_stream_on(struct dp_io *io);
void dp_stream_off(struct dp_io *io);
int dp_hpd(struct dp_io *io);
int dp_in_sync(struct dp_io *io);
int dp_bring_up(struct dp_io *io);

// **THE KEEPER**: one step of the daemon's loop, given what word 36 read.
// It brings the link up while the monitor is there and the display awake,
// follows the mute (D3 and the stream off; D0 and the stream on, trained
// again if the monitor does not take it back), and trains again when the
// monitor drops the stream or is unplugged and plugged back.
struct dp_keeper {
	int up;			// the link trained and the stream on (or asleep)
	int asleep;		// the sink told D3 and the stream off
	uint64_t next_check_us;	// when the stream is next looked at
	uint64_t retry_at_us;	// when a failed bring-up is next tried
	unsigned bring_ups, trainings, failures, sleeps, wakes, lost;
};

void dp_keeper_init(struct dp_keeper *k);
void dp_keeper_step(struct dp_io *io, struct dp_keeper *k, uint32_t word36);

#endif
