# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The Kria KR260's pins for `boards/kria-kr260/cadr_kr260.sv`.  Package pins
# and standards from AMD's own KR260 board files and platform XDCs; which LED
# is which and the fan's sense were seen on the board.

# The carrier's 25 MHz (HPA_CLK0P_CLK, a Si5332 output), on C3 in bank 66 at
# 1.8 V.  The MMCM's 100 MHz is derived from it by the tools.
set_property -dict { PACKAGE_PIN C3 IOSTANDARD LVCMOS18 } [get_ports { clk25 }]
create_clock -add -name clk25 -period 40.000 -waveform {0 20} [get_ports { clk25 }]

# UF1 and UF2, bank 66, lit when driven high.  The LED marked UF1 is F8.
set_property -dict { PACKAGE_PIN F8 IOSTANDARD LVCMOS18 } [get_ports { uf1 }]
set_property -dict { PACKAGE_PIN E8 IOSTANDARD LVCMOS18 } [get_ports { uf2 }]
set_false_path -to [get_ports { uf1 uf2 }]

# The SOM's fan: `fan_en_b`, bank 45 at 3.3 V, LOW runs it.  SLOW and DRIVE 4
# as AMD's own XDCs give it.
set_property -dict { PACKAGE_PIN A12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4 } [get_ports { fan_en_b }]
set_false_path -to [get_ports { fan_en_b }]

# The fold is a load and nothing reads it: see the top level.
set_false_path -to [get_cells -quiet witness_reg]

# MIT's debug cable on PMOD1, bank 45 at 3.3 V, in AMD's signal order
# `pmod1_pin1` to `pmod1_pin8` (kr260_4mb_4pmod XDC): index k is AMD's pin
# k+1.  Pulled down as JA is on the Zynq boards, so an unplugged connector
# reads zeros.  The cable is asynchronous to this clock and has its own
# synchronizers and its own beat (`cadr_debug_pmod.xdc`), so the pads are
# false paths here as they are there.
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
