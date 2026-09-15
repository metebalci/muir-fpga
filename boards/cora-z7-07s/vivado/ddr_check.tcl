# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Start the Cora Z7-07S's processing system and prove, from outside our
# design, that DDR answers.
#
#     timeout 600 ~/Xilinx/2026.1/Vivado/bin/xsdb \
#         boards/cora-z7-07s/vivado/ddr_check.tcl
#
# Run from the repository root, and run it under `timeout`. Xilinx's own
# `mask_poll` waits for DDR-init-complete a hundred million times before it
# gives up, which over JTAG is not a bound anyone will wait for, so a
# controller that never comes up hangs rather than failing. Exit 124 is its own
# finding.
#
# THIS IS A FRONT END AND NOT A SECOND CHECK. It sets the six facts that differ
# between the two boards and sources
# `boards/arty-z7-20/vivado/ddr_check.tcl`, which is where the check itself
# lives. That is the shape `gen_ps7.py` and `ps7_ops.py` in this directory
# already use. What the check does, why each read is made, and what an
# uninitialized word is allowed to look like are hard-won and there is one copy
# of them.
#
# THE ROUTINE IS THIS BOARD'S. `make ps7-init-cora` writes it to
# `build/ps7-cora/ps7_init.tcl` out of Digilent's own board preset for this
# board, and that is the default here. It is the file this check exists to
# judge: `ps7_init` prints nothing, so what says it worked is the read-back.
#
# THE BOARD IS PICKED BY ITS CABLE SERIAL, which the check reads from
# `JTAG_SERIAL` in the environment or from `boards/cora-z7-07s/linux/local.conf`.
# That file is gitignored, because a cable serial identifies one physical board
# the way its MAC address does and this repository is public. With more than
# one Zynq attached and no serial, the check refuses rather than starting the
# memory controller on somebody else's board.

# The name that goes in the messages.
set ::BOARD_NAME "Cora Z7-07S"

# Where this board's gitignored `local.conf` is.
set ::BOARD_DIR "boards/cora-z7-07s"

# The part.
set ::PART_NAME "XC7Z007S"

# The low 28 bits this board's `PSS_IDCODE` must carry, and it is Xilinx's own
# number rather than one derived here. Vivado ships a device table at
# `data/xicom/cable_data/digilent/lnx64/jtscdvclist.txt` which gives every Zynq
# device its IDCODE against the mask `0x0FFFFFFF` that drops the revision
# nibble. Device `007` there is `0x03723093` and device `020`, the other
# board's, is `0x03727093`, which is the constant that board has always
# asserted. The debugger reports this part's JTAG IDCODE as the same word with
# a revision nibble on top.
set ::DEVICE_ID 0x03723093

# Where `make ps7-init-cora` writes the routine.
set ::PS7_INIT_DEFAULT "build/ps7-cora/ps7_init.tcl"

# One past the top of this board's DDR. Digilent's preset gives it one
# MT41K256M16 on a 16-bit bus, which is 512 MB, and that is the same device the
# other board carries. So this is the same number twice and it is stated rather
# than inherited, because it is a fact about a board.
set ::DDR_TOP 0x20000000

# The check itself, found relative to this file so that a moved directory
# cannot silently pick up a different copy. The paths inside it are relative to
# the repository root, which is where it says to run it from.
set here [file dirname [file normalize [info script]]]
source [file join $here .. .. arty-z7-20 vivado ddr_check.tcl]
