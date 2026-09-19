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
