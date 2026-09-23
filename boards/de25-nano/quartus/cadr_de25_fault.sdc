# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's fault bitstream, `boards/de25-nano/cadr_de25_fault.sv`, for
# the timing analyzer.
#
# **NO CLOCK IS DECLARED HERE**, for `cadr_de25.sdc`'s reason: the I/O PLL's
# generated constraints declare the reference on `clock50_0` and derive the
# 10 ns output, and `fault_sta.tcl` refuses a build whose two clocks are not
# those.  What is here is the CADR build's own treatment of the pins and of
# the processor's asynchronous signals, for the registers the fault top level
# keeps, under the same names.

derive_clock_uncertainty

# A finger, a slide switch and an LED are not timing constraints.
set_false_path -from [get_ports {btn[*] sw[*]}]
set_false_path -to [get_ports {led[*]}]

# The debug cable's pads, which this design leaves to their pull-downs.
set dbg_pads [get_ports {jp1_pin3*}]
set_false_path -from $dbg_pads
set_false_path -to   $dbg_pads

# The processor's reset, `h2f_gp_out` and the warm-reset request, each into
# the first stage of its synchronizer, as `cadr_ddr.sdc` gives the CADR's
# gate; and the acknowledgment back to the processor, which takes it
# asynchronously.
set_false_path -to [get_registers -nowarn {u_gate|rst_s[0] u_gate|open_s[0]
                                           u_gate|req_s[0] h2f_rst_s[0]}]
set_false_path -from [get_registers -nowarn {u_gate|ack_n}]
