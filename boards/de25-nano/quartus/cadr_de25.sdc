# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's clock and its asynchronous pins, for the timing analyzer.
#
# **NO CLOCK IS DECLARED HERE, NOT EVEN THE BOARD'S.**  `CLOCK0_50` is 50 MHz
# according to the user manual's Table 3-6, and the I/O PLL in
# `boards/de25-nano/cadr_de25.sv` makes the 10 ns tick from it.  The PLL's
# generated constraints, which Quartus reads before this file, declare the
# reference clock on `clock50_0` from the PLL's own reference parameter and
# derive the output from it; a `create_clock` here is then refused (warning
# 332049, measured) and changes nothing.  So the two numbers live in the one
# place the PLL is generated from, and `sta_check.tcl` refuses a build whose
# clock on `clock50_0` is not the manual's 20 ns or whose machine clock is not
# the 10 ns tick.  A reference parameter typed wrong would otherwise still
# give a 10 ns clock in the report and a different one on the board.
#
# **AND THE MACHINE'S EXCEPTIONS ARE `cadr_machine.xdc`'s, WRITTEN AGAIN.**
# The first fit on this part asked whether the machine closes at one tick
# with no exception, and it did not: 135 endpoints failed at -2.012 ns, every
# one a register the processor loads at the microcycle boundary.  Those are
# the paths `rtl/plumbing/xilinx7/cadr_machine.xdc` relaxes on the Zynq
# boards, so its three clauses are below, with the same register sets named
# by the same names, the same counts and the same `/D` rule.  The argument
# for every name is that file's and is not repeated here; what is here is
# what differs in Quartus's words.
#
#   - Quartus names a register by its signal and its bits, `md[14]`, and a
#     hierarchy with `|`, so `*u_phase_gen*` stays as it is and a Vivado
#     `*/elapsed_reg*` is `*|elapsed*` here.
#   - That file is read scoped to `cadr_machine`, so its `all_registers` is
#     the machine's.  Here every pattern begins at `u_machine|`, which is the
#     same scope written out.
#   - A register's data pin is `|d`, beside `|ena` and `|sclr`, where Vivado's
#     is `/D` beside `/CE` and `/R`.
#
# `sta_check.tcl` asks, as `constraints_check.tcl` does for Vivado, which
# paths each clause reaches: that the relaxed set reached the design, that
# nothing outside the machine is relaxed, and for the two instance clauses,
# that the named registers carry the requirement and no other register of
# the instance does.  And the register retiming Quartus does by default is
# off in `project.tcl`, so the registers these names match are the design's.

derive_clock_uncertainty

# A person's finger and a slide switch are not timing constraints.  Both
# buttons and SW0 reach the fabric through synchronizers, and the buttons'
# debouncing is the board's Schmitt trigger.  SW1 to SW3 reach nothing, and
# the timing netlist has no port for them.
set_false_path -from [get_ports {btn[*] sw[*]}]

# Nor is an LED, which nothing samples.
set_false_path -to [get_ports {led[*]}]

# ------------------------------------------- MIT's debug cable, on JP1
#
# **THE EIGHT PADS ARE ASYNCHRONOUS AND THE TWO BOARDS SHARE NO CLOCK.**  What
# crosses this connector is a strobe and a data line at the far end of a
# ribbon, sampled here through two flops like any other asynchronous input ---
# `rtl/plumbing/cadr_dbg_rx.sv` does the sampling and the frame's own gap is
# what says where a frame begins.  There is no clock to constrain them against
# and no input or output delay that would mean anything, so both directions
# are cut, which is what `boards/arty-z7-20/cadr_arty.xdc` does for the same
# eight pads on Pmod JA.
#
# **THE PATTERN IS A WILDCARD, BECAUSE A BRACKET HERE IS A BUS INDEX AND NOT A
# RANGE.**  The eight pads are eight SCALAR ports, `jp1_pin31` to `jp1_pin38`,
# and a collection pattern of the shape `jp1_pin3[1-8]` names none of them:
# Quartus reads the brackets as the index of a bus called `jp1_pin3`, finds no
# such port, and leaves the collection empty.  Measured on this design:
# `{jp1_pin3[1-8]}` is 0 ports, `{jp1_pin3*}` is 8 and `{jp1_pin31}` is 1.  An
# exception written against an empty collection is a warning in a log and a
# connector nobody is cutting, which is the defect the section below records
# for a constraint file that was read by nothing, in another disguise: a
# constraint that reaches nothing looks exactly like one that works.
#
# **AND `project.tcl`'s `^jp1_pin3[1-8]$` IS NOT A PRECEDENT FOR WRITING IT
# THAT WAY HERE.**  That is a Tcl regexp, where the brackets are a character
# class and the range does mean the eight, which is why the pins were placed
# and pulled down correctly while these two cuts reached nothing.  The two
# files name the same eight pads in two languages, and only one of them reads
# a range.
#
# **AND THE COLLECTION IS MADE ONCE**, so that `sta_check.tcl` counts the very
# collection the two cuts were written against rather than a second copy of
# the pattern.  A pattern written twice is two patterns: they agree until they
# do not, and a check that re-derives what it is checking passes on a build
# where the constraint reached nothing.  This is `cable_frame` below on the
# same footing.
set dbg_pads [get_ports {jp1_pin3*}]
set_false_path -from $dbg_pads
set_false_path -to   $dbg_pads

# --------------------------------------- and the carrier's own six ticks
#
# **`rtl/plumbing/xilinx7/cadr_debug_pmod.xdc`'s ONE CLAUSE, WRITTEN AGAIN**,
# and read by every configuration of this board for the reason that file
# records: a board is always a DEBUGGEE, so `cadr_dbgin.sv`'s page is driven by
# the cable on every board, `DBD<15:0>` is live on every board, and the arc
# this exists for is real whether or not a processor is in the build.  That
# file was once gated on a general-purpose port being brought out, and the
# memory-off Arty Z7-20 measured -9.600 ns on 596 endpoints with it read by
# nothing.
#
# THE ARC IS THE MACHINE'S WORD INTO THE FRAME THE SENDER IS ABOUT TO SHIFT
# OUT: `VMA` through both levels of the map to `-VMAOK`, into FLAG-2, through
# the processor's sixteen-way diagnostic mux, the register block, the arbiter
# and MIT's DBGIN page, out of `cadr_machine` on `DBD<15:0>` and into
# `tx_frame`.  It is the same cone `cadr_ddr.sdc` relaxes into the register
# window's `sts_dbd`, with a second reader on it, and the remedy is the same.
#
# **SIX TICKS IS THE CARRIER'S OWN NUMBER AND NOT A MARGIN.**  The sender takes
# the cable's levels once at the first beat of a frame and shifts them out over
# the twenty-three that follow, so the two ways into these registers are a
# snapshot every 162 ticks and a SHIFT every `BEAT_T`, which is six.  Six is
# the tighter of the two, and that is what makes it a bound rather than a
# margin.
#
# The `|d` pins and not the registers, as every other clause in this file
# does: `-to [get_registers ...]` would cover the clock enable too, and the
# enable on these is the beat countdown, a free-running counter that must keep
# its tick.  `sta_check.tcl` asserts what it reached --- these two registers of
# the sender and no other register of the connector --- because a constraint
# that reaches nothing looks exactly like one that works.
# grid: 60 ns
set cable_frame [get_pins -nowarn {u_dbg_cable|u_tx|tx_frame[*]|d
                                   u_dbg_cable|u_tx|tx_d[*]|d}]
set_multicycle_path -setup 6 -to $cable_frame
set_multicycle_path -hold  5 -to $cable_frame

# ------------------------------------------------ the machine's relaxed set
#
# Every register of the machine but the ones that must stay at the tick: the
# phase generator, the free-running counters, the edge detectors and the bus
# interface's three acknowledgments.  And four modules out whole but for
# their held decodes: the disk controller, the transaction audit, the display
# board and the I/O board, and the bus interface's own register block.
# `cadr_machine.xdc` gives each name its reason.
set machine [get_registers -nowarn {u_machine|*}]

# A register is named by its leaf, one bit or a bus: `X` and `X[*]`.  A bare
# prefix is too wide here where Vivado's `_reg` suffix was not:
# `busint_regs|wr*` would take `write_through` with `wr`, and that file
# leaves `write_through` at the tick on purpose.
proc cadr_leaves {prefix names} {
    set patterns {}
    foreach name $names {
        lappend patterns "${prefix}${name}" "${prefix}${name}\[*\]"
    }
    return $patterns
}
set fast [add_to_collection [get_registers -nowarn {*u_phase_gen*}] \
              [get_registers -nowarn [cadr_leaves {*|} {mfinish_t rdfinish_t elapsed
                  vco_count arb_t phase_t n_memack_q n_loadmd_q n_tpwpiram_q n_tpwp_q
                  deskewed ub_acked ub_loadmd tpclk_q}]]]
set out_whole [get_registers -nowarn {u_machine|disk|* u_machine|audit|*
                                      u_machine|memory|tv|* u_machine|memory|iob|*
                                      u_machine|memory|busint_regs|*}]
set held [get_registers -nowarn [concat \
    [cadr_leaves {u_machine|disk|} {mine which}] \
    [list {u_machine|audit|first_*}] \
    [cadr_leaves {u_machine|audit|} {micro word}] \
    [cadr_leaves {u_machine|memory|tv|} {ctl fb which}] \
    [cadr_leaves {u_machine|memory|iob|} {sel kbm clkgrp chgrp sergrp wr which}] \
    [cadr_leaves {u_machine|memory|busint_regs|} {sel in_int in_map wr which mapk}]]]
set slow [remove_from_collection $machine $fast]
set slow [remove_from_collection $slow $out_whole]
set slow [add_to_collection $slow $held]

# The fast read tap, the tightest instant a datapath register is read at:
# `cadr_tick_pkg::ticks(75)`, eight at a 10 ns grid.
# grid: 75 ns
set_multicycle_path -setup 8 -from $slow -to $slow
set_multicycle_path -hold  7 -from $slow -to $slow

# ------------------------------------ the bus's own eighty nanoseconds
#
# The display board takes the master's word at the first tick of -XBUS.RQ,
# which the bus rule owes 80 ns of settling.  The `|d` pins and not the
# registers, so the clock enable keeps its tick.
# grid: 80 ns
set bus_word [get_pins -nowarn {u_machine|memory|tv|color_map[*][*][*]|d
                                u_machine|memory|tv|pointer[*]|d
                                u_machine|memory|g_color_tv.tv_color|color_map[*][*][*]|d
                                u_machine|memory|g_color_tv.tv_color|pointer[*]|d}]
set_multicycle_path -setup 8 -to $bus_word
set_multicycle_path -hold  7 -to $bus_word

# ---------------------------------- the Unibus map and its write buffer
#
# Taken at the register strobe, fifteen ticks after -UB MSYN, from a word the
# master had good before it raised the strobe.  The `|d` pins, for the same
# reason.
# grid: 150 ns
set ub_strobe [get_pins -nowarn {u_machine|memory|busint_regs|wr_buf[*][*]|d
                                 u_machine|memory|busint_regs|ub_map[*][*]|d}]
set_multicycle_path -setup 15 -to $ub_strobe
set_multicycle_path -hold  14 -to $ub_strobe
