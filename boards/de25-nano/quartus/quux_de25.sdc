# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX's own exceptions on the DE25-Nano, read after `cadr_de25.sdc` and only
# for a QUUX build: `rtl/plumbing/xilinx7/quux_machine.xdc` gives each its
# argument, and this is the same two clauses in this tool's words.
#
# The tick needs no clause: its write reaches its countdown from `L`, a tick
# after the edge, and `quux_machine.xdc` says why.

# The divider's operands, taken seven ticks into the microcycle, and the
# narrower clauses' paths into it.
# grid: 60 ns + 1 tick
set quux_divider [get_registers -nowarn {u_machine|processor|*muldiv|dv_*}]
set_multicycle_path -setup 7 -from $slow -to $quux_divider
set_multicycle_path -hold  6 -from $slow -to $quux_divider
# grid: 60 ns - 1 tick
set_multicycle_path -setup 5 -from $split_cstore -to $quux_divider
set_multicycle_path -hold  4 -from $split_cstore -to $quux_divider
# grid: 60 ns
set_multicycle_path -setup 6 -from $split_every_tick -to $quux_divider
set_multicycle_path -hold  5 -from $split_every_tick -to $quux_divider
