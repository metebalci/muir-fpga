# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# THE FAULT BITSTREAM, SEEN FROM LINUX.  Sourced by every init script whose
# program touches the fabric.
#
# **WHAT IT IS.**  When U-Boot cannot load the CADR's bitstream --- a card
# without the file, a file that does not configure the part, a future flag
# naming a bitstream the card lacks --- it loads the fault bitstream instead
# (`boards/*/cadr_*_fault.sv`): no machine, every lamp blinking together, red
# on a color lamp, and both processor-to-fabric ports answered so that Linux
# boots and runs as it would.  `docs/board.md` has the whole of it.
#
# **HOW IT IS RECOGNIZED.**  The tally every program reads before it touches
# a port (`cadr/cadr_mem.h`) reads "FALT", 0x46414C54, in every word: both
# EMIO words on a Zynq board, the system manager's GPI on the DE25-Nano.
# Those registers are the processor's own and answer whatever the fabric
# holds, so reading them cannot hang it.  "FALT" has neither of the tally's
# marker bits, so every program would refuse this fabric anyway; this is what
# lets the init scripts say WHY in one line instead of five programs each
# failing their guard.
#
# **WHICH REGISTERS ARE THE BOARD'S**, and the board is written into this
# file when it is installed: cadr-common's Makefile replaces the placeholder
# on the line below with the board it was built for, as it stages
# `cadr_board.h` with the board's define.  The addresses are `cadr_board.h`'s
# `CADR_BOARD_TALLY_*`.  A placeholder left in place names no board, and then
# nothing is called the fault bitstream: the programs' own guard still
# stands behind this.
#
# **ONE LINE ON THE CONSOLE**, said by the first script to ask and by no
# other: `CADR_FAULT_SAID` is where that is remembered, on the root
# filesystem's RAM disk, so a boot says it once and the next boot says it
# again.  Every script that asks is told, and starts nothing.

CADR_FAULT_BOARD=@CADR_BOARD@
CADR_FAULT_SAID=${CADR_FAULT_SAID:-/var/run/cadr-fault.said}
CADR_FAULT_WORD=0x46414C54

# The board's tally words, one address a word, or failure for a board this
# file does not know.
cadr_fault_tally() {
	case "$CADR_FAULT_BOARD" in
	zynq-7000) echo "0xE000A068 0xE000A06C" ;;
	de25-nano) echo "0x10D120E8" ;;
	*) return 1 ;;
	esac
}

# 0 if the fabric is the fault bitstream: every tally word reads "FALT".
# Anything else --- another value, a word that cannot be read, a board this
# file does not know --- is 1.
cadr_fabric_is_fault() {
	_fault_addrs=$(cadr_fault_tally) || return 1
	for _fault_a in $_fault_addrs; do
		_fault_v=$(devmem "$_fault_a" 32 2>/dev/null) || return 1
		case "$_fault_v" in
		0x*|0X*) ;;
		*) return 1 ;;
		esac
		[ "$(( _fault_v ))" -eq "$(( CADR_FAULT_WORD ))" ] 2>/dev/null || return 1
	done
	return 0
}

# The init scripts' question, asked before anything touches the fabric: 0 if
# this is the fault bitstream and the script must start nothing, having said
# so on the console once a boot; 1 to go on.
cadr_fault_stop() {
	cadr_fabric_is_fault || return 1
	if [ ! -e "$CADR_FAULT_SAID" ]; then
		echo "cadr: THE FAULT BITSTREAM IS LOADED, every lamp blinking: the CADR's bitstream could not be loaded, so nothing that touches the fabric is started; check the card's configuration (docs/board.md)"
		: > "$CADR_FAULT_SAID" 2>/dev/null || true
	fi
	return 0
}
