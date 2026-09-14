# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The debug cable's deadline again, one module further out: the Pmod carrier
# takes the same word the register window takes, and it is outside the machine
# for the same reason.
#
# **READ BY EVERY CONFIGURATION OF EVERY BOARD, AND IT USED NOT TO BE.**  It
# was gated on a general-purpose port being brought out, on
# `rtl/plumbing/xilinx7/cadr_debug.xdc`'s precedent, and the reasoning was that
# with no window `dbg_in_req` is tied low and the whole sender folds to
# constants.  **That reasoning was made false by the connector.**  A board is
# always a DEBUGGEE --- Pmod JA is instantiated whatever the switches say ---
# so `cadr_dbgin.sv`'s page is driven by the cable on every board, `dbd_out` is
# live on every board, and the arc this file exists for is real on every board.
#
# Measured while the gate was still there: the memory-off Arty Z7-20 came out
# at **-9.600 ns on 596 endpoints**, every one of them in the carrier, with the
# constraint file read by nothing.  That is exactly the failure this project
# keeps meeting --- a constraint that applies to nothing, and a report of a
# design nobody was timing.  The gate is gone and `assert_instance_timing` in
# each board's flow is what says it reached a path.
#
# WHY THERE IS A DEADLINE HERE AT ALL, MEASURED RATHER THAN FORESEEN. The
# first board with a Pmod carrier on it came out at **-9.779 ns on the
# memory-on flow**, 3,905 failing endpoints, and the ten worst paths were all
# one register:
#
#     u_machine/processor/vma_reg[14]_replica_2/C
#       -> <the carrier>/tx_frame_reg[3]/D
#     25 logic levels, requirement 10.000 ns
#
# That is `VMA` through both levels of the map to `-VMAOK`, into FLAG-2, into
# the processor's sixteen-way diagnostic mux, through the register block, the
# arbiter and MIT's DBGIN page, out of `cadr_machine` on `DBD<15:0>` and into
# the frame the carrier is about to send. `cadr_debug.xdc` measured the same
# arc at 23 levels and -8.772 ns when the register window latched it. **It is
# the same cone with a second reader on it**, and the remedy is the same.
#
# THE READER CANNOT SIMPLY MOVE INSIDE THE MACHINE. A Pmod serialiser is a
# board's carrier and not the CADR: `rtl/machine/` is what muir is the
# reference for, and a transport that exists because a connector has eight
# pins has no place in it. The cable is the boundary and the deadline belongs
# to the arc that crosses it.
#
# AND THE DEADLINE IS THE CARRIER'S OWN, WRITTEN DOWN, NOT CHOSEN. The sender
# takes the cable's levels once at the first beat of each frame and shifts
# them out over the seven that follow, so the two ways into these registers
# are a snapshot every sixty-six ticks and a shift every six. Four ticks is
# below the tighter of those by a third, and it is the number
# `cadr_debug.xdc` already uses for the same cone, so nothing new has to be
# defended. The measured need is two.
#
# WHAT THE RELAXATION DOES NOT EXCUSE. The word on `DBD<15:0>` is driven live
# while a cycle runs, and MIT's own note is that read and write at one
# diagnostic address are uncorrelated because the 74LS244s drive `SPY<15:0>`
# asynchronously. A word a tick or two stale on a running machine is already
# the semantics of this bus, and CC halts the debuggee before it does anything
# else. A two-tick arrival inside a frame of sixty-six is invisible to it.
#
# HOW THIS IS KEPT FROM BEING TOO WIDE.
#
#   - **The `/D` pins and not the cells.** `-to [get_cells ...]` covers every
#     input pin including `CE`, and the clock enable on these registers is the
#     beat countdown --- a free-running counter, which is the one thing that
#     must keep its tick. That is `cadr_ddr.xdc`'s split between the address
#     and `-XBUS.RQ` and the `elapsed -> md/CE` lesson underneath both.
#
#   - **ONE CARRIER NOW CARRIES BOTH DIRECTIONS, so the split that used to be
#     between two instances is gone.** With two connectors the DBGOUT sender
#     was fed by the register window's own fast registers and was not relaxed,
#     and only the DBGIN one had the machine's mux in front of it. One
#     connector has a mux on `tx_levels` instead --- the debuggee's twenty or
#     the debugger's --- and the slowest input decides, which is the
#     debuggee's. So the relaxation is the same arc it always was, and what it
#     now also covers is the debugger's half, which needed none. That is a
#     widening and it is stated rather than hidden: it relaxes registers that
#     were meeting their deadline anyway, and `assert_instance_timing` still
#     holds it to those two register names and no others.
#
#   - **And the receivers are untouched.** The strobe's synchroniser, the
#     frame counter, the gap counter and the dead man all count ticks, and a
#     counter given four of them is a counter that no longer counts.
#     Each board's `vivado/bitstream.tcl` asserts exactly that with
#     `assert_instance_timing`: no path into any other register of this
#     carrier may ask for 40 ns, and at least one path into these must.
set pmod [get_pins -quiet {u_dbg_cable/u_pmod/tx_frame_reg[*]/D
                           u_dbg_cable/u_pmod/tx_d_reg[*]/D}]
set_multicycle_path -setup 4 -to $pmod
set_multicycle_path -hold  3 -to $pmod
