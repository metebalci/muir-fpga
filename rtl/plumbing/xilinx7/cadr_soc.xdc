# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The soft processing system's clock, and the one place this design crosses
# between it and the machine's.
#
# Read only when the soft processing system is in the design ---
# `boards/arty-a7-100/vivado/bitstream.tcl` is where that is decided --- because
# every object named here is inside the `g_soc` generate.  **A constraint whose
# objects are not there is a CRITICAL WARNING that reads exactly like one which
# applied**, which is the trap this repository has met four times: a `foreach`
# an XDC rejects, a `get_ports` in a scoped file, a guard written with `if` in a
# file that allows neither, and a pattern anchored on the other board's
# generate block.  So there are no guards here and the assertions are in the
# flow, which is where `cadr_a7_ddr.xdc` and `cadr_hdmi.xdc` both put theirs
# after the same mistake.
#
# ---------------------------------------------------------------------------
# WHY THERE ARE TWO CLOCKS
#
# Ibex computes a load or a store's address in the cycle it uses it --- the
# decoder, the operand multiplexers and the main ALU's adder between the
# instruction register and the memory's address pin --- and on an
# `xc7a100tcsg324-1` that arc is about 12.9 ns of logic and routing.  The
# machine's tick is 10 ns and cannot move, every instant in `rtl/machine/`
# being a count of them, and the arc is not a path a constraint may relax: it
# is one cycle of a processor and it is meant to be.  So the soft system runs
# on `CLKOUT2` of the same clock manager, slower, and
# `rtl/plumbing/cadr_soc_cross.sv` carries one request and one answer between
# the two.
#
# ---------------------------------------------------------------------------
# WHY THE DOMAINS ARE BOUNDED RATHER THAN GROUPED
#
# Both clocks come out of one manager, so they are phase-related and Vivado
# will happily time a path between them --- against the requirement two
# unrelated edges happen to make, which for 10 ns and 20 ns is 10 ns and for a
# ratio that is not whole can be a fraction of a nanosecond.  That is a
# requirement nobody asked for.
#
# The usual answer is `set_clock_groups -asynchronous`, and it is the wrong one
# HERE.  A grouped path is not timed at all, and a crossing whose payload is
# not timed at all is a payload the fitter may route through a swamp: the
# argument that makes `cadr_soc_cross` correct is that the address, the data
# and the answer have STOPPED MOVING before the level that points at them
# arrives, and that argument fails if the payload takes longer to arrive than
# the level.  `set_max_delay -datapath_only` says exactly that and nothing
# more: bound the combinational delay, ignore the clock relationship.  **And
# the two must not both be written**, because a clock group silently overrides
# a maximum delay and the bound would then be a comment.
#
# THE BOUND IS THE MACHINE'S OWN TICK, which is the SHORTER of the two periods
# and therefore the conservative choice in both directions: a payload that
# arrives inside one tick has arrived inside one of the soft system's clocks
# too.  It is asked of the design rather than written down ---
# `boards/arty-z7-20/vivado/tick.tcl` exists because a period written twice is
# a period that can come apart, and a literal here would be a third copy of it.
#
# WHAT IS COVERED.  Everything that crosses, which is: the request level and
# its payload going out, the acknowledgement and its answer coming back, and
# the disk pack side's interrupt, which is a level from the machine's domain
# into the core's external interrupt and is synchronised in `cadr_soc.sv`.
# Naming the two CLOCKS rather than the registers is what makes that complete
# --- a signal added to the crossing later is covered by construction, where a
# list of pins would have to be remembered.

# The names are this file's own and not `mach` and `ref`: `cadr_a7_ddr.xdc` is
# read after this one in the memory configurations and sets a `mach` of its
# own, and two files writing one global in a flow that reads both is a
# staleness waiting to happen.
set soc_mach_clk [get_clocks -of_objects \
                      [get_pins -hier -filter {NAME =~ *u_mmcm/CLKOUT0}]]
set soc_soft_clk [get_clocks -of_objects \
                      [get_pins -hier -filter {NAME =~ *u_mmcm/CLKOUT2}]]

set_max_delay -datapath_only -from $soc_soft_clk -to $soc_mach_clk $tick
set_max_delay -datapath_only -from $soc_mach_clk -to $soc_soft_clk $tick
