# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The Kria KR260's display output: its pixel clock, and the crossings between
# it and the machine's.
#
# **THE ARTY Z7-20'S `rtl/plumbing/xilinx7/cadr_hdmi.xdc` FOR THE SAME
# MODULE**, `rtl/plumbing/cadr_display_out.sv`, and every argument for each
# line is in that file and not repeated here.  What differs is the clocks:
# this board's pixel clock is `cadr_kr260_pixel_clock.sv`'s MMCM, net
# `pixel_raw`, and there is no serializer clock.  The pixel clock also
# clocks the DisplayPort controller's live input through `DPVIDEOINCLK`, and
# the PS8's own timing model holds the live pins to it.
#
# Read only by a board with its processing system (`DDR=1`), where every
# object named here exists; `boards/kria-kr260/vivado/bitstream.tcl` asserts
# that each filter matched something, which an XDC cannot do for itself.
#
# And measured on the Arty, as that file records: the asynchronous clock group
# outranks the `set_max_delay` bounds below in Vivado's precedence, so the
# bounds name registers and are not in force.  The same holds here.
set_clock_groups -asynchronous \
    -group [get_clocks clk_raw] \
    -group [get_clocks pixel_raw]

set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *req_addr_reg* || \
                                    NAME =~ *req_strided_reg*}] 6.700

set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *map_idx_reg*}] \
    -to   [get_cells -hier -filter {NAME =~ *cmap_reg*}] 13.400

set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *slp_want_reg*}] \
    -to   [get_cells -hier -filter {NAME =~ *slp_want_s1_reg*}] 6.700

set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *slp_mute_reg*}] \
    -to   [get_cells -hier -filter {NAME =~ *slp_mute_s1_reg*}] 10.000
