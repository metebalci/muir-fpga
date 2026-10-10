# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The Kria KR260's pins for QUUX revision 15 (`quux15_kr260.sv`): the
# carrier's 25 MHz, the two user LEDs, the fan and PMOD1's pads, as
# `cadr_kr260.xdc` has them.  The machine's clock is the MMCM's output,
# which Vivado derives from the 25 MHz clock below.

set_property -dict { PACKAGE_PIN C3 IOSTANDARD LVCMOS18 } [get_ports { clk25 }]
create_clock -add -name clk25 -period 40.000 -waveform {0 20} [get_ports { clk25 }]

set_property -dict { PACKAGE_PIN F8 IOSTANDARD LVCMOS18 } [get_ports { uf1 }]
set_property -dict { PACKAGE_PIN E8 IOSTANDARD LVCMOS18 } [get_ports { uf2 }]
set_false_path -to [get_ports { uf1 uf2 }]

# The SOM's fan, on while low, which the top level holds.
set_property -dict { PACKAGE_PIN A12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports { fan_en_b }]
set_false_path -to [get_ports { fan_en_b }]

# PMOD1, the debug cable's connector, which QUUX has not got: undriven and
# pulled down, the unplugged connector.
set_property -dict { PACKAGE_PIN H12 IOSTANDARD LVCMOS33 } [get_ports { pmod1[0] }]
set_property -dict { PACKAGE_PIN E10 IOSTANDARD LVCMOS33 } [get_ports { pmod1[1] }]
set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 } [get_ports { pmod1[2] }]
set_property -dict { PACKAGE_PIN C11 IOSTANDARD LVCMOS33 } [get_ports { pmod1[3] }]
set_property -dict { PACKAGE_PIN B10 IOSTANDARD LVCMOS33 } [get_ports { pmod1[4] }]
set_property -dict { PACKAGE_PIN E12 IOSTANDARD LVCMOS33 } [get_ports { pmod1[5] }]
set_property -dict { PACKAGE_PIN D11 IOSTANDARD LVCMOS33 } [get_ports { pmod1[6] }]
set_property -dict { PACKAGE_PIN B11 IOSTANDARD LVCMOS33 } [get_ports { pmod1[7] }]
set_property PULLTYPE PULLDOWN [get_ports { pmod1[*] }]
set_false_path -from [get_ports { pmod1[*] }]
set_false_path -to   [get_ports { pmod1[*] }]
