# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The display output's clocks and its video pins, for the timing analyzer.
#
# Read only when the display is in the design, which
# `boards/de25-nano/quartus/project.tcl` arranges, for the reason the probe's
# file is read only behind `PROBE_DEPTH`: a constraint on something that is
# not in the design is a warning that reads like a constraint that applied.
#
# **NO CLOCK IS DECLARED FOR THE PIXEL PLL EITHER.**  As with the machine's,
# the generated constraints the IP writes for itself declare the reference on
# `clock50_0` and derive the output from it, and Quartus reads them before
# this file.  So the frequency lives where the PLL is asked for it, in
# `build.sh`, and `sta_check.tcl` reads back what the analyzer derived and
# refuses a build whose pixel clock is not the mode's.
#
# WHAT IS HERE IS THE TWO THINGS THAT LEAVE THE PART.
#
# **THE FORWARDED CLOCK.**  `hdmi_pclk` is the pixel clock gated by the
# display's mute and driven onto a pin, so it is a generated clock of the
# PLL's output and has to be declared as one: a clock on a port that nothing
# declares is a port with no clock, and every path to the video pins would
# then be unconstrained while the report showed no failure --- which is
# exactly the shape this project keeps meeting, a constraint that reaches
# nothing looking like one that works.
#
# **THE VIDEO BUS.**  The twenty-seven pins the transmitter samples, against
# the setup and hold its data sheet gives: `tVSU` 1.8 ns and `tVHLD` 1.3 ns,
# Table 1 under AC SPECIFICATIONS, measured at 0.9 V.  Those are the part's,
# and they are all that is here, because **THE BOARD'S OWN TRACE SKEW BETWEEN
# THE CLOCK AND THE DATA IS NOT KNOWN**: the resource package carries no
# schematic, and the manual gives no trace lengths.  So the numbers below are
# the part's requirement with nothing added for the board, which is a bound
# this design meets rather than a bound the board meets, and saying which it
# is matters more than the number.
#
# **AND THE TWO CLOCKS DO NOT MEET.**  The machine's clock and the pixel
# clock are unrelated, as they are on the Arty Z7-20, and the display crosses
# between them only through the handshakes `rtl/plumbing/cadr_display_out.sv`
# describes --- a toggle each way for the band buffers, and two flops each way
# for the sleep.  So the two are cut, and `sta_check.tcl` asserts that the
# cut reached something and that nothing timed remains between them.

# --------------------------------------------------- the forwarded clock
#
# The pixel clock as the PLL's own constraints named it, found rather than
# spelled: the IP's internal hierarchy is the generator's and changes when
# the generator does, and a pattern written out here would rot silently into
# a clock that matches nothing.  **THE MACHINE'S PLL IS NOT THIS ONE**, and
# the two are told apart by the instance names in
# `boards/de25-nano/cadr_de25.sv`: `u_pll` makes the tick and
# `u_pixel_clock` the mode.  That file says why the second is not called
# `u_pll` anything.
set cadr_pixel_clock ""
set cadr_pixel_source ""
foreach_in_collection cadr_c [get_clocks -nowarn *] {
    set cadr_n [get_clock_info -name $cadr_c]
    if {[string match {*u_pixel_clock*outclk*} $cadr_n]
        || [string match {*u_pixel_clock*out_clk*} $cadr_n]} {
        set cadr_pixel_clock $cadr_n
        set cadr_pixel_source [get_clock_info -targets $cadr_c]
    }
}

if {$cadr_pixel_clock ne ""} {
    # The pin the part is handed is one period of that clock, gated.  The
    # gate takes its enable on the falling edge, so no period is ever cut
    # short and the forwarded clock is the source clock or nothing.
    create_generated_clock -name cadr_hdmi_pclk \
        -source $cadr_pixel_source [get_ports hdmi_pclk]

    # ------------------------------------------------------ the video bus
    #
    # The transmitter samples these twenty-seven against the clock beside
    # them.  A maximum output delay is what the far end needs set up before
    # its edge, and a minimum is what it needs held after: 1.8 ns and
    # 1.3 ns, from the data sheet, with nothing added for the board.
    set cadr_video [get_ports {hdmi_d[*] hdmi_de hdmi_hsync hdmi_vsync}]
    set_output_delay -clock cadr_hdmi_pclk -max  1.8 $cadr_video
    set_output_delay -clock cadr_hdmi_pclk -min -1.3 $cadr_video
}

# ------------------------------------------- the two clocks do not meet
#
# The memory side of the display runs on the machine's clock and its raster
# on the pixel clock, and nothing relates them.  What crosses does so through
# the handshakes the module's header describes, and a path timed as if the
# two clocks were related is what this cut is for.
set cadr_machine_clock ""
foreach_in_collection cadr_c [get_clocks -nowarn *] {
    set cadr_n [get_clock_info -name $cadr_c]
    if {[string match {*u_pll*outclk*} $cadr_n] || [string match {*u_pll*out_clk*} $cadr_n]} {
        set cadr_machine_clock $cadr_n
    }
}
if {$cadr_machine_clock ne "" && $cadr_pixel_clock ne ""} {
    set_clock_groups -asynchronous \
        -group [get_clocks $cadr_machine_clock] \
        -group [get_clocks [list $cadr_pixel_clock cadr_hdmi_pclk]]
}

# ------------------------------- the pixel PLL's lock, into the raster's reset
#
# **A PLL'S LOCK IS NOT OF THE CLOCK THE PLL MAKES.**  `pixel_locked` comes
# out of the pixel PLL on its own reference clock and enters the raster's
# domain in `boards/de25-nano/cadr_de25.sv` through three registers, which is
# what a crossing gets everywhere in this design.  The analyzer relates the
# two clocks anyway --- both descend from `clock50_0` --- and times the first
# of those three against the pixel clock's 9.259 ns, which it misses by
# 1.346 ns.  That is measured, on the first fit of this board with a display
# in it, and it is the same shape `cadr_ddr.sdc` cuts for the processor's
# asynchronous bits: the FIRST register of each synchronizer is cut from
# whatever the analyzer thinks drives it, and the other two are timed as they
# are.
#
# The fabric's own reset reaches the same register, and it is a register of
# the machine's clock; the asynchronous group above already covers that half.
# This cut is for the lock.
#
# `sta_check.tcl` asserts that the collection is the one register and that no
# timed path ends at it, because a cut that reached nothing is indisting-
# uishable from one that worked.
set cadr_prst_first [get_registers -nowarn {prst_sync[0]}]
if {[get_collection_size $cadr_prst_first] > 0} {
    set_false_path -to $cadr_prst_first
}

# ------------------------------------------ the transmitter's two wires
#
# A two-wire bus at 100 kHz, driven open drain by a fabric that runs at
# 100 MHz, and read back through two flops.  Nothing samples these pins
# against a clock of this design: the part clocks them itself, and the whole
# of the timing is in the levels `rtl/plumbing/cadr_adv7513.sv` holds for
# whole quarters of a bit --- two and a half microseconds each, against the
# hundred nanoseconds the data sheet asks.  `build/adv7513.pass` measures all
# six off the waveform.  So there is no setup or hold here to write down, and
# a path from a register to `hdmi_scl` or `hdmi_sda` timed at one tick would
# be a requirement about nothing.
set_false_path -to [get_ports {hdmi_scl hdmi_sda}]
set_false_path -from [get_ports {hdmi_scl hdmi_sda}]
