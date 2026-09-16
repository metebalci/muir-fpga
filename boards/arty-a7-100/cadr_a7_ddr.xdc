# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The memory board's two extra clocks, and the three places this design crosses
# between them.
#
# Read only when the memory controller is in the design ---
# `boards/arty-a7-100/vivado/bitstream.tcl` is where that is decided --- because
# every object named here is inside the `g_memory` generate.  **A constraint
# whose objects are not there is a CRITICAL WARNING that reads exactly like one
# which applied**, which is the trap this repository has met three times: a
# `foreach` an XDC rejects, a `get_ports` in a scoped file, and a guard written
# with `if` in a file that allows neither.  So there are no guards here and the
# assertions are in the flow, which is where `cadr_hdmi.xdc` put its own after
# the same mistake.
#
# ---------------------------------------------------------------------------
# WHY THE DOMAINS ARE BOUNDED RATHER THAN GROUPED
#
# The machine runs at 100 MHz and the controller's user interface at
# 81.25 MHz.  Both are made from this board's one oscillator, so they never
# drift --- but they pass through two different clock managers, so their edges
# have no fixed relationship, and a tool asked to time a path between them
# computes a common period and demands about two nanoseconds.  That is a
# requirement nobody asked for and no design meets.
#
# The usual answer is `set_clock_groups -asynchronous`, and it is the wrong one
# HERE.  A grouped path is not timed at all, and a crossing whose payload is
# not timed at all is a payload the fitter may route through a swamp: the
# argument that makes `cadr_mem_cross` correct is that the address and the
# data have STOPPED MOVING before the level that points at them arrives, and
# that argument fails if the payload takes longer to arrive than the level.
# `set_max_delay -datapath_only` says exactly that and nothing more: bound the
# combinational delay, ignore the clock relationship.  **And the two must not
# both be written**, because a clock group silently overrides a maximum delay
# and the bound would then be a comment.
#
# THE BOUND IS THE MACHINE'S OWN TICK, asked of the design rather than written
# down.  `boards/arty-z7-20/vivado/tick.tcl` exists because a period written
# twice is a period that can come apart, and a literal here would be a third
# copy of it.

set mach [get_clocks -of_objects \
              [get_pins -hier -filter {NAME =~ *u_mmcm/CLKOUT0}]]

# The 200 MHz reference reaches the input delay controller and nothing else,
# and the controller's own generated constraints false-path the one signal that
# crosses into it.  So it is asynchronous to everything, which is what a single
# group means.
set ref [get_clocks -of_objects \
             [get_pins -hier -filter {NAME =~ *u_mmcm/CLKOUT1}]]
set_clock_groups -asynchronous -group $ref

# **AND THE BOUND BETWEEN THE MACHINE AND THE CONTROLLER IS NOT WRITTEN HERE,
# BECAUSE IT CANNOT BE.**  Choosing the controller's clocks means asking which
# clocks its registers use and then taking this design's own two back out of
# the answer --- and an XDC is a restricted subset of Tcl in which
# `remove_from_collection` is refused, exactly as `foreach` and `concat` are
# --- and it does not exist in this tool at all, being another vendor's
# command, so the refusal's wording is doubly misleading.  Refused, the two
# lines that took them out did nothing, the bound was written
# from the machine's clock TO THE MACHINE'S OWN CLOCK as well, and it overrode
# `cadr_machine.xdc`'s fifteen-tick exception on all 28,324 of the machine's
# paths: the design was timed at one tick throughout and the flow's own
# `assert_multicycle_applied` said so, printing a requirement histogram with no
# 150.000 ns in it at all.
#
# **THAT IS THE THIRD TIME THIS PROJECT HAS MET THE XDC's OWN RESTRICTION**
# --- a `foreach` loop in `cadr_machine.xdc` that applied to nothing, a
# `get_ports` in a scoped file that resolved to nothing, and now this --- and
# it is the first time it made a constraint too WIDE rather than too narrow,
# which is the harder direction to see: a build that constrains nothing fails
# loudly, and a build that relaxes everything looks finished.
#
# So the two lines live in `boards/arty-a7-100/vivado/bitstream.tcl`, which is
# ordinary Tcl, beside the assertion that says they applied.  This file keeps
# what an XDC does well.

# ---------------------------------------------------------------------------
# THE DEBUGGER'S WINDOW, which is the third crossing and the slowest.
#
# `BSCANE2`'s data register clock is the test access port's, and nothing in
# this design tells the tool how fast that is.  100 ns is 10 MHz, which is
# faster than any cable here drives it and is therefore a bound rather than a
# guess --- `cadr_probe.xdc` writes 33.333 for the same reason and calls it the
# same thing.
#
# What crosses is the scanned command, which has stopped moving before the
# update pulse that announces it: the last shift is in EXIT1-DR and the next
# data register clock is the following scan's CAPTURE.  Same argument, same
# constraint.
set bscan_mem [get_cells -hier -filter {NAME =~ *u_bscan_mem}]
create_clock -name jtag_mem_drck -period 100.000 \
    [get_pins -of_objects $bscan_mem -filter {REF_PIN_NAME == DRCK}]

set_max_delay -datapath_only -from [get_clocks jtag_mem_drck] -to $mach $tick
set_max_delay -datapath_only -from $mach -to [get_clocks jtag_mem_drck] 100.000

# ---------------------------------------------------------------------------
# THE BUS'S OWN 80 ns CONTRACT, WHICH IS WHAT THE ADDRESS PATH IS ENTITLED TO
#
# `cadr_xbus_ddr.sv` quotes the rule: it is "the responsibility of the bus
# master to assert good address, write, and data lines 80 ns. prior to
# asserting -XBUS.RQ".  Eighty nanoseconds on MIT's own five-nanosecond grid is
# SIXTEEN TICKS, and the crossing's payload registers take the address at the
# tick the request arrives --- so the path from the machine's `VMA`, through
# the level-1 map, through `main_byte_address` and into those registers has
# sixteen ticks to settle and not one.
#
# **MEASURED, AND IT IS WHY THIS IS HERE**: unrelaxed, this board reports
# `u_machine/processor/vma_reg[13]/C -> u_cross/addr_q_reg[13]/D` at
# **-0.499 ns**, twelve logic levels and 10.342 ns of which seven are routing.
# The Arty Z7-20 met the same wall one module along and
# `rtl/plumbing/xilinx7/cadr_ddr.xdc` is the same exception for the same
# reason.
#
# **THE `/D` PIN AND NOT THE REGISTER.**  `-to [get_cells ...]` covers every
# input pin including `CE`, and this register's clock enable is driven by the
# handshake watching the request --- which is the one signal the contract must
# NOT relax.
#
# **AND `-from` THE MACHINE'S OWN REGISTERS AND NOT EVERYTHING.**  The memory's
# arbiter, `rtl/plumbing/cadr_mem_share.sv`, sits in front of these registers
# and multiplexes four masters' addresses in --- the debugger's window, the
# disk pack face's master and the soft processing system's window beside the
# machine --- so the fanin of that `D` pin includes the arbiter's owner
# register, which changes one tick before the capture rather than sixteen, and
# the other three masters' own address registers, which make no 80 ns promise
# at all.  Relaxing those arcs would relax a select that has to be right
# immediately and addresses nobody gave sixteen ticks.  Starting the exception
# at the machine's registers leaves all of them timed at one tick, where they
# belong.
set contract [get_pins -quiet {g_memory.u_memory/u_cross/addr_q_reg[*]/D \
                               g_memory.u_memory/u_cross/wdata_q_reg[*]/D \
                               g_memory.u_memory/u_cross/write_q_reg/D}]
set machine_ffs [get_cells -quiet -hier \
    -filter {PRIMITIVE_GROUP == FLOP_LATCH && NAME =~ *u_machine/*}]
set_multicycle_path -setup 16 -from $machine_ffs -to $contract
set_multicycle_path -hold  15 -from $machine_ffs -to $contract
