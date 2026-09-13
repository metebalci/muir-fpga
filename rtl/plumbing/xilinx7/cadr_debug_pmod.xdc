# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The debug cable's deadline again, one module further out: the Pmod carrier
# takes the same word the register window takes, and it is outside the machine
# for the same reason.
#
# READ ONLY BY A BOARD THAT BRINGS A GENERAL-PURPOSE PORT OUT, on
# `rtl/plumbing/xilinx7/cadr_debug.xdc`'s precedent and for its reason. The
# cone this relaxes starts at the machine's own diagnostic mux and reaches the
# carrier through `cadr_dbgin.sv`'s `DBD<15:0>`. On a board with no processing
# system there is no window, `dbg_in_req` is tied low, every strobe is false,
# `dbd_out` is a constant and the whole sender folds --- so the exception would
# be real, legal and connected to nothing, which is the one shape of
# constraint this project has already been bitten by.
#
# WHY THERE IS A DEADLINE HERE AT ALL, MEASURED RATHER THAN FORESEEN. The
# first board with the two Pmod connectors on it came out at **-9.779 ns on
# the memory-on flow**, 3,905 failing endpoints, and the ten worst paths were
# all one register:
#
#     u_machine/processor/vma_reg[14]_replica_2/C
#       -> u_dbgin_pmod/tx_frame_reg[3]/D
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
#   - **The DBGIN connector's sender and nothing else.** The DBGOUT sender is
#     fed by the register window's own outputs, which are fast registers a few
#     levels away, and it is not relaxed. The two modules are the same module
#     and only one of them has the machine's mux in front of it, which is the
#     whole of the reason they are constrained differently.
#
#   - **And the receivers are untouched.** The strobe's synchroniser, the
#     frame counter, the gap counter and the dead man all count ticks, and a
#     counter given four of them is a counter that no longer counts.
#     `boards/arty-z7-20/vivado/bitstream.tcl` asserts exactly that with
#     `assert_instance_timing`: no path into any other register of this
#     carrier may ask for 40 ns, and at least one path into these must.
set pmod [get_pins -quiet {u_dbgin_pmod/tx_frame_reg[*]/D
                           u_dbgin_pmod/tx_d_reg[*]/D}]
set_multicycle_path -setup 4 -to $pmod
set_multicycle_path -hold  3 -to $pmod
