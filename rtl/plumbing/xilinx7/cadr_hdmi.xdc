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

# AND THE ONE BUS THAT CROSSES IS BOUNDED RATHER THAN LEFT OPEN. `req_line` is
# ten bits handed from the raster to the memory side beside the toggle. It is
# safe because it is stable for a whole raster line --- 1,688 pixel clocks ---
# before anything reads it, and the toggle that says to read it takes two
# clocks to arrive. So a few nanoseconds of skew between its bits cannot
# matter. But "cannot matter" is not "is not measured": an asynchronous clock
# group makes every path between the two domains a false path, including this
# one, and a false path is a route the fitter may make as long as it likes.
# `-datapath_only` puts a ceiling back on it without asking for the two clocks
# to be related.
#
# The filter is on the register's own name and not on its hierarchy, because
# the hierarchy a generate block gets is the tool's to spell and the register
# is ours. `req_line` exists in exactly one module. `bitstream.tcl` asserts
# that this matched something, which is the half an XDC cannot do for itself.
set_max_delay -datapath_only \
    -from [get_cells -hier -filter {NAME =~ *req_line_reg*}] 10.000
