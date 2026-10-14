# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# QUUX revision 15 on the DE25-Nano (`boards/de25-nano/quux15_de25.sv`), for
# the timing analyzer: its asynchronous pins and the processor's crossings,
# and nothing else.
#
# **NO CLOCK IS DECLARED HERE**, for the reason `cadr_de25.sdc` gives: the
# I/O PLL's generated constraints declare the reference on `clock50_0` and
# derive the machine's clock at the period `build.sh` asked the PLL for, and
# `quux15_sta_check.tcl` refuses a build whose machine clock is not that
# period.  The pixel clock and the display's crossings are `cadr_hdmi.sdc`'s,
# the processor system's reset synchronizers `hps_reset.sdc`'s, as for the
# CADR.
#
# **AND NO EXCEPTION INTO THE MACHINE.**  Revision 15 is a pipeline timed at
# one clock: every path between its registers has the period, as on the
# Kria KR260 and the Arty Z7-20, whose constraint files have no exception
# into the core either.  `quux15_sta_check.tcl` asks that no path on the
# machine's clock is given more than the period.

derive_clock_uncertainty

# A person's finger and a slide switch are not timing constraints, nor is an
# LED, which nothing samples.  KEY1 reaches the fabric through a
# synchronizer; KEY0 and the switches reach nothing on revision 15.
set_false_path -from [get_ports -nowarn {btn[*] sw[*]}]
set_false_path -to [get_ports {led[*]}]

# The debug cable's eight pads on JP1, which QUUX has not got: undriven and
# read by nothing, and cut both ways as on the CADR, so that the count
# `quux15_sta_check.tcl` asks of them is of ports this build has.
set dbg_pads [get_ports {jp1_pin3*}]
set_false_path -from $dbg_pads
set_false_path -to   $dbg_pads

# **THE PLL'S LOCK**, asynchronous to the machine's clock, into the fabric
# reset's synchronizer (KEY1 beside it is a port, cut above).  At the CADR's
# 10 ns the lock's launch on the 20 ns reference and the machine's edges
# keep a whole period apart; at revision 15's periods they do not (at 23 ns
# the analyzer gave the crossing 1 ns, the worst path of the fit), and a
# synchronizer's first register is timed by nobody.
set lock_crossing [get_registers -nowarn {rst_sync[0]}]
set_false_path -to $lock_crossing

# **THE PROCESSOR'S ASYNCHRONOUS BITS**, as `cadr_ddr.sdc` cuts them on the
# CADR: the first register of each synchronizer into this clock --- the
# processor's reset, the open bit, the warm-reset request and the tally's
# select at the memory port (`quux15_f2sdram_port.sv`, `cadr_f2sdram_gate.sv`),
# and the bridges' reset at the top level --- and the registers the processor
# samples on its own clock, the acknowledgment and the tally.
set ddr_crossing [get_registers -nowarn {u_memory|u_gate|rst_s[0] u_memory|u_gate|open_s[0]
                                         u_memory|u_gate|req_s[0] u_memory|half_s[0]
                                         h2f_rst_s[0]}]
set_false_path -to $ddr_crossing
set ddr_to_hps [get_registers -nowarn {u_memory|u_gate|ack_n u_memory|gp_in[*]}]
set_false_path -from $ddr_to_hps
