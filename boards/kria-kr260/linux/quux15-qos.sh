#!/bin/sh
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX revision 15's main-memory priority on the Kria KR260 (contract G3
# revision 15, A15b.5): HP0's read and write QoS, `AFIFM2`'s RDQOS at
# 0xFD380008 and WRQOS at 0xFD38001C (UG1087), set to 0xF after every
# fabric load, so that the machine's traffic rides at the DDR controller's
# video-class priority against the scan-out and the processing system.  The
# firmware leaves both 0.
#
# Run as root on the board after the bitstream is loaded and before the
# machine is released.  It writes both registers, reads them back, and prints
# one line for the board-run log; it exits non-zero when either reads back
# other than 0xF.

set -u
RDQOS=0xFD380008
WRQOS=0xFD38001C

devmem "$RDQOS" 32 0xF || exit 2
devmem "$WRQOS" 32 0xF || exit 2
rd=$(devmem "$RDQOS" 32) || exit 2
wr=$(devmem "$WRQOS" 32) || exit 2
echo "quux15-qos: HP0 RDQOS $rd WRQOS $wr"
[ "$((rd & 0xF))" -eq 15 ] && [ "$((wr & 0xF))" -eq 15 ]
