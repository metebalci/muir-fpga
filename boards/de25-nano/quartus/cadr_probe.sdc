# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The JTAG clock the capture is read out on, and the one register of the
# probe that takes the machine's microcycle.  The DE25-Nano's counterpart of
# `boards/arty-z7-20/cadr_probe.xdc`, whose arguments hold here unchanged.
#
# READ ONLY WHEN THE PROBE IS IN THE DESIGN.  `project.tcl` adds this file
# behind `PROBE_DEPTH`, and `sta_check.tcl` asks the timing analyzer whether
# each clause below reached what it names.
#
# THE JTAG CLOCK.  The probe's shift register and read pointer are clocked by
# TCK, which reaches the fabric through the SLD hub from the device's
# `altera_reserved_tck`.  Quartus gives that port a clock only for the
# fitter, in the IP's own `default_jtag.sdc`
# (`ip/altera/sld/jtag/altera_jtag_wys_atom/`), and leaves the timing
# analyzer, which signs a build off, with no clock on it at all: the whole
# readout would be timed against nothing and reported as nothing.  So the
# clock is declared here, with the period that file uses, 30 ns: "A10 & S10
# support max 33.3Mhz clock", in its words.  The period is a bound on the
# cable and not a measurement, as the Arty's 33.333 ns is.
create_clock -name altera_reserved_tck -period 30.000 [get_ports {altera_reserved_tck}]

# AND THE TWO DOMAINS ARE ASYNCHRONOUS, because they are: TCK comes off a
# cable and the machine's clock off the PLL.  What crosses between them is
# the read pointer, through two flops, and the sample word, which stands
# still for thousands of ticks before the JTAG side loads it.
# `rtl/plumbing/cadr_probe.sv` has the argument.  `default_jtag.sdc` makes
# the same declaration for the fitter.
set_clock_groups -asynchronous -group [get_clocks {altera_reserved_tck}]

# ------------------------------------------------ and the microcycle, again
#
# **WHAT THE MACHINE BRINGS OUT IS MOSTLY COMBINATIONAL**, and `stable_q` is
# the half of the probe's holding register that may take the microcycle
# exception the machine's own registers take, in `cadr_de25.sdc`, at the
# same eight ticks.  `late_q`, which holds `lpc`, `md`, `vma` and `promdis`,
# deliberately may not.  `cadr_probe.xdc` and `cadr_probe.sv` give the
# argument, and it is the same argument here: the inputs of `stable_q` stand
# still from one microcycle boundary to the next.
#
# The fast read tap, the tightest instant a datapath register is read at:
# `cadr_tick_pkg::ticks(75)`, eight at a 10 ns grid.
# grid: 75 ns
set probe_stable [get_registers -nowarn {g_probe.u_probe|stable_q[*]}]
set_multicycle_path -setup 8 -to $probe_stable
set_multicycle_path -hold  7 -to $probe_stable
