# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The display output's clocks, and the one crossing between them and the
# machine's.
#
# READ ONLY BY AN `HDMI=1` BOARD, on `cadr_ddr.xdc`'s precedent. Every object
# it names is inside the `g_hdmi` generate, which exists only when
# `boards/arty-z7-20/cadr_arty.sv`'s `HDMI` parameter is set; read against any
# other board it would be critical warnings about objects that are not there,
# and a critical warning that means nothing is how a constraint that means
# nothing goes unnoticed.
#
# THE PINS ARE NOT HERE. They are in `boards/arty-z7-20/cadr_arty.xdc` with
# the rest of the board's pins, because the four differential pairs are in the
# port list on EVERY board --- a pin with no driver cannot be placed --- so
# their constraints have to be read on every board too.
#
# **AND THERE IS NO CONTROL FLOW IN THIS FILE, WHICH IS NOT A STYLE
# CHOICE.** An XDC is a restricted Tcl subset that rejects `if` and `foreach`
# outright. The first draft of this file guarded itself with both, and both
# came back as `CRITICAL WARNING [Designutils 20-1307] Command 'foreach' is
# not supported in the xdc constraint file` --- so the guard applied to
# nothing while reading as though it were protecting something. That is the
# loudest trap this project has recorded, met again in a new file. Every
# assertion this file wants is in `boards/arty-z7-20/vivado/bitstream.tcl`
# instead, which is plain Tcl and where the flow's other assertions already
# live.
#
# WHY THE THREE CLOCKS NEED SAYING ANYTHING ABOUT AT ALL. Vivado derives all
# of them by itself: the machine's `clk_raw` off the top level's MMCM, and the
# display's `pixel_raw` and `serial_raw` off the phy's. What it cannot derive
# is that the first has nothing to do with the other two. They come from two
# MMCMs off one board crystal, so the tool can compute a common period and
# will happily time a path between them against it --- and the paths between
# them are the line buffer's, which are crossed by a toggle through a
# synchronizer and are asynchronous on purpose.
#
# `set_clock_groups -asynchronous` is what says so. Without it the two-flop
# synchronizer is timed as an ordinary path, the fitter spends effort on it,
# and the report carries failures that mean nothing.
set_clock_groups -asynchronous \
    -group [get_clocks clk_raw] \
    -group [get_clocks {pixel_raw serial_raw}]

# AND THE TWO BUSES THAT CROSS ARE BOUNDED RATHER THAN LEFT OPEN.
#
# The first is the fetch job: the byte address the raster wants and whether it
# is a strided band, handed to the memory side beside the toggle. It is safe
# because it is stable for a whole raster line --- 1,688 pixel clocks --- before
# anything reads it, and the toggle that says to read it takes two clocks to
# arrive. So a few nanoseconds of skew between its bits cannot matter. But
# "cannot matter" is not "is not measured": an asynchronous clock group makes
# every path between the two domains a false path, including this one, and a
# false path is a route the fitter may make as long as it likes.
# `-datapath_only` puts a ceiling back on it without asking for the two clocks
# to be related.
#
# The filter is on the register's own name and not on its hierarchy, because
# the hierarchy a generate block gets is the tool's to spell and the register is
# ours. Both names exist in exactly one module. `bitstream.tcl` asserts that
# this matched something, which is the half an XDC cannot do for itself.
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *req_addr_reg* || \
                                    NAME =~ *req_strided_reg*}] 10.000

# **AND THE SECOND IS THE COLOR MAP, WHICH IS A ROUND TRIP AND NOT A HANDOFF.**
# The display output names a color from the pixel clock's domain on `map_a`, the
# word comes back combinationally out of the color board's map inside
# `cadr_machine` --- the machine's own clock domain, and physically the other
# side of the die --- and the pixel side takes it eight pixel clocks later. So
# the path leaves a register here, crosses, passes through sixteen-to-one of
# multiplexing there, crosses back, and ends at a register here.
#
# It is safe for the reason the job above is: the index changes once a raster
# line and the word is taken 74 ns after it went out. It is bounded for the same
# reason too, and generously --- 20 ns, which is two pixel clocks of the four the
# handshake leaves spare, because this path crosses the die and a ceiling that
# cannot be met is a ceiling that gets relaxed rather than believed.
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *map_idx_reg*}] \
    -to   [get_cells -hier -filter {NAME =~ *cmap_reg*}] 20.000

# **AND THE THIRD IS SLEEP: TWO ONE-BIT LEVELS, ONE EACH WAY.** The sleep timer
# runs on the machine's clock and its verdict, `slp_want`, crosses into the
# pixel clock's domain through two flops, where the frame boundary takes it into
# the mute. The mute, `slp_mute`, crosses back through two more, which is what
# the console reads as the display being asleep. Each is a level that stands
# for a frame at the least, so neither needs more than a synchronizer --- but
# the clock group makes the route into each first flop a false path of any
# length. One pixel clock, as the job's is; the `-to` is named as well as the
# `-from` because the mute also gates the four lanes inside its own domain, and
# that path is timed as an ordinary one. `bitstream.tcl` asserts that all four
# registers were found.
#
# **AND MEASURED, NONE OF THESE BOUNDS REACHES A PATH.** A synthesized
# `DDR=1 HDMI=1 LMTV=1` board's `report_exceptions -ignored` lists this pair and
# the fetch job's bound above as "Totally overridden path by CG", and
# `get_timing_paths` on each names the asynchronous clock group as the exception
# in force. A clock group outranks `set_max_delay` in Vivado's precedence, so the
# `-datapath_only` ceiling the paragraphs above describe is not put back. Nothing
# here depends on it: each of these two is one bit that stands for a frame
# through two flops. The fetch job's bound is the one whose absence could
# matter, and the group and the bounds want settling together rather than here.
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *slp_want_reg*}] \
    -to   [get_cells -hier -filter {NAME =~ *slp_want_s1_reg*}] 10.000
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *slp_mute_reg*}] \
    -to   [get_cells -hier -filter {NAME =~ *slp_mute_s1_reg*}] 10.000
