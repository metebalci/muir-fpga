# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX's own exceptions, read scoped to `cadr_machine` after
# `cadr_machine.xdc` and only for a QUUX build: an XDC cannot ask which
# machine it is reading, and a clause whose `-to` matches nothing is a clause
# on every path, so the CADR must never read this file.
#
# **THE TICK NEEDS NO CLAUSE.**  Its countdown and its flag run every tick and
# stay out of the relaxed set, and a write of destination 3 or 4 reaches them
# from `L`, a register, a tick after the edge (`cadr_microcycle.sv` has why),
# so every path into them is a register a tick away and is timed so.

# **THE DIVIDER TAKES ITS OPERANDS SEVEN TICKS INTO THE MICROCYCLE.**  Its
# steps, `dv_*` in `quux_muldiv.sv`, run a tick at a time and stay out of the
# relaxed set, but it loads the M and A buses and `Q` at the seventh tick
# after the edge that loaded `IR` and at no other, when the scratchpad
# latches have closed: so the paths from the relaxed set into it are given
# the latches' own seven ticks, and the narrower clauses keep theirs.  Its
# words go out to the output bus a tick at a time and need no clause.
# grid: 60 ns + 1 tick
set quux_divider [filter [all_registers] {NAME =~ *processor/g_quux_muldiv.muldiv/dv_*}]
set_multicycle_path -setup 7 -from $slow -to $quux_divider
set_multicycle_path -hold  6 -from $slow -to $quux_divider
# grid: 60 ns - 1 tick
set_multicycle_path -setup 5 -from $split_cstore -to $quux_divider
set_multicycle_path -hold  4 -from $split_cstore -to $quux_divider
# grid: 30 ns
set_multicycle_path -setup 3 -from $split_maps -to $quux_divider
set_multicycle_path -hold  2 -from $split_maps -to $quux_divider
# grid: 60 ns
set_multicycle_path -setup 6 -from $split_every_tick -to $quux_divider
set_multicycle_path -hold  5 -from $split_every_tick -to $quux_divider
