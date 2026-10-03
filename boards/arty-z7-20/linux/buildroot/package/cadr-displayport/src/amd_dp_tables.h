// Copyright (C) 2010-2020 Xilinx, Inc.  All rights reserved.
// Copyright (C) 2017 - 2020 Xilinx, Inc.  All rights reserved.
// SPDX-License-Identifier: MIT
//
// THIS FILE IS NOT THIS PROJECT'S WORK.  It carries two tables of AMD's
// (formerly Xilinx's), both under the MIT License, whose text is
// `AMD-Xilinx-MIT.txt` beside this file; `docs/license.md` lists them.  The
// copyright lines above are the two sources' own.  Everything else in this
// package is AGPL-3.0-or-later.
//
// 1. THE PS-GTR LANE 1 WRITES FOR DISPLAYPORT.  The writes the boot firmware
//    makes to put the Kria KR260's DisplayPort on the processing system's
//    transceiver lane 1, as Vivado 2026.1's own processing-system IP
//    (`zynq_ultra_ps_e`) generates them in `psu_init.c` for the part
//    `xck26-sfvc784-2LV-c` with the board files `kr260_som` 2.0 and
//    `kr260_carrier` 2.0 applied (DisplayPort "Single Lower" on GT lane 1,
//    reference clock 1 at 27 MHz): `psu_serdes_init_data`'s writes to lane
//    1's registers and to the two shared ones that name lane 1, in that
//    function's order, each as (address, mask, value).  The generated file's
//    sha256 was 8a70b571e36867524643b07e28a4115adbab16d22dde5bc75588a847ca4d5573.
//    The factory firmware on the board is built for the module alone and
//    leaves lane 1 powered down (ICM_CFG0 reads 0x05), so without a display
//    driver in Linux nothing else makes these writes.
//
// 2. THE VOLTAGE SWING AND PRE-EMPHASIS TABLE.  The values for lane's
//    margining factor (TXPMD_TM_48) and de-emphasis (TX_ANA_TM_18) registers
//    at each DisplayPort training level, indexed [pre-emphasis][voltage swing],
//    0xff for a pair not offered: `vs` and `pe` from AMD's embeddedsw,
//    `XilinxProcessorIPLib/drivers/dppsu/src/xdppsu_serdes.c` at commit
//    97f2baf7f69e9d5f447650110af0d8841e501277, sha256
//    c4b8d7772febbc32ef5a1b333d10491b471735d6bcdc52ccfdef5d3256d24e07.

#ifndef AMD_DP_TABLES_H
#define AMD_DP_TABLES_H

#include <stdint.h>

struct amd_psgtr_write {
	uint32_t addr, mask, value;
	const char *name;
};

static const struct amd_psgtr_write amd_psgtr_lane1_dp[] = {
	{ 0xFD410004u, 0x0000001Fu, 0x00000009u, "PLL_REF_SEL1" },
	{ 0xFD402864u, 0x00000080u, 0x00000080u, "L0_L1_REF_CLK_SEL" },
	{ 0xFD406368u, 0x000000FFu, 0x00000058u, "L1_PLL_SS_STEPS_0_LSB" },
	{ 0xFD40636Cu, 0x00000007u, 0x00000003u, "L1_PLL_SS_STEPS_1_MSB" },
	{ 0xFD406370u, 0x000000FFu, 0x0000007Cu, "L1_PLL_SS_STEP_SIZE_0_LSB" },
	{ 0xFD406374u, 0x000000FFu, 0x00000033u, "L1_PLL_SS_STEP_SIZE_1" },
	{ 0xFD406378u, 0x000000FFu, 0x00000002u, "L1_PLL_SS_STEP_SIZE_2" },
	{ 0xFD40637Cu, 0x00000033u, 0x00000030u, "L1_PLL_SS_STEP_SIZE_3_MSB" },
	{ 0xFD405074u, 0x00000010u, 0x00000010u, "L1_TM_DIG_8" },
	{ 0xFD405994u, 0x00000007u, 0x00000007u, "L1_TM_ILL13" },
	{ 0xFD40507Cu, 0x0000000Fu, 0x00000001u, "L1_TM_DIG_10" },
	{ 0xFD4059A4u, 0x000000FFu, 0x000000FFu, "L1_TM_RST_DLY" },
	{ 0xFD405038u, 0x00000040u, 0x00000040u, "L1_TM_ANA_BYP_15" },
	{ 0xFD40502Cu, 0x00000040u, 0x00000040u, "L1_TM_ANA_BYP_12" },
	{ 0xFD4059ACu, 0x00000003u, 0x00000000u, "L1_TM_MISC3" },
	{ 0xFD405978u, 0x00000010u, 0x00000010u, "L1_TM_EQ11" },
	// ICM_CFG0's lane 1 field only; the generated write sets lane 0's too,
	// which is not DisplayPort's and is left as the board has it.
	{ 0xFD410010u, 0x00000070u, 0x00000040u, "ICM_CFG0" },
	{ 0xFD404CB4u, 0x00000037u, 0x00000037u, "L1_TXPMD_TM_45" },
	{ 0xFD4041D8u, 0x00000001u, 0x00000001u, "L1_TX_ANA_TM_118" },
	{ 0xFD404CC0u, 0x0000001Fu, 0x00000000u, "L1_TXPMD_TM_48" },
	{ 0xFD404048u, 0x000000FFu, 0x00000000u, "L1_TX_ANA_TM_18" },
};

// Lane 1's PLL lock, which the generated `psu_resetout_init_data` polls.
#define AMD_PSGTR_L1_PLL_STATUS      0xFD4063E4u
#define AMD_PSGTR_L1_PLL_LOCKED      0x00000010u

// Lane 1's margining factor and de-emphasis, which the table below fills.
#define AMD_PSGTR_L1_TX_MARGININGF   0xFD404CC0u
#define AMD_PSGTR_L1_TX_DEEMPHASIS   0xFD404048u

static const uint8_t amd_dp_vs[4][4] = {
	{ 0x2a, 0x27, 0x24, 0x20 },
	{ 0x27, 0x23, 0x20, 0xff },
	{ 0x24, 0x20, 0xff, 0xff },
	{ 0xff, 0xff, 0xff, 0xff },
};

static const uint8_t amd_dp_pe[4][4] = {
	{ 0x02, 0x02, 0x02, 0x02 },
	{ 0x01, 0x01, 0x01, 0xff },
	{ 0x00, 0x00, 0xff, 0xff },
	{ 0xff, 0xff, 0xff, 0xff },
};

#endif
