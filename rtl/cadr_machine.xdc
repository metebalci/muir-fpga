# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Timing constraints for the composed machine.
#
# Without these every timing report on this design is measuring a requirement
# nobody intends. CLAUDE.md's own note says why: 200 MHz exists only to
# resolve the 5 ns delay-line taps, and netlist logic settles *between*
# phases, where the 75 ns fast read tap is the real constraint. Hold all 1,821
# registers to the 5 ns tick and the report says WNS -17.265 ns --- the map
# lookup rippling into the control store's address, 21.615 ns over 26 logic
# levels, which is a path that has a phase to happen in.
#
# Worse than a misleading report: it distorts placement. With everything held
# to 5 ns the placer spends itself on 6,637 impossible datapath paths, and the
# ring counter --- the one thing that genuinely must meet the tick --- routed to
# -1.526 ns. With the constraints below the same logic makes +0.233 ns.
#
# Measured on an xc7z020clg400-1, synthesised, placed and routed out of
# context: **all user specified timing constraints are met**, zero violated
# paths, worst slack +0.110 ns. 2,764 LUTs of 53,200 and 28 block RAM tiles of
# 140.

create_clock -name clk -period 5.000 [get_ports clk]

# Everything but the ring counter advances once a microcycle. The datapath
# registers change at phase boundaries, and the tightest instant any of them
# is read at is the fast read tap, 15 ticks after the boundary --- so 15, not
# 29, and not the 44 of an extra slow cycle. 1,787 of 1,821 registers are in
# this set; the 34 that are not are the generator's own.
#
# Paths *from* the generator into the machine are deliberately not relaxed:
# the taps are enables and are sampled every tick.
set slow [filter [all_registers] {NAME !~ *u_phase_gen*}]
set_multicycle_path -setup 15 -from $slow -to $slow
set_multicycle_path -hold  14 -from $slow -to $slow
