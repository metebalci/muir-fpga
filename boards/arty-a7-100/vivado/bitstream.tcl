# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build a bitstream for the Arty A7-100.
#
#     make build/boot_prom.hex
#     vivado -mode batch -source boards/arty-a7-100/vivado/bitstream.tcl
#
# Run from the repository root. This is `fit.tcl`'s sibling: that one asks
# what the machine costs, out of context and with no pins; this one asks
# whether it can be built at all, against a real part with the board's own
# package pins, through to a `.bit`.
#
# **THIS BOARD HAS NO PROCESSING SYSTEM, SO IT HAS NO SWITCHES BUT ONE.**  The
# Arty Z7-20's flow carries `DDR`, `PROVE` and `HDMI`, and every one of the
# three turns on a port of the Zynq's. There is no Zynq here. What is left is
# `PROBE_DEPTH`, which is pure fabric and carries over unchanged:
#
#     PROBE_DEPTH=1024 OUTDIR=build/a7-probe \
#         vivado -mode batch -source boards/arty-a7-100/vivado/bitstream.tcl
#
# puts `rtl/plumbing/xilinx7/cadr_probe.sv` in the design: one sample a
# microcycle of the columns `build/rtl.golden` carries, in block RAM, shifted
# out over JTAG by `boards/arty-a7-100/vivado/probe.tcl`. Zero, the default,
# is the machine and nothing else.
#
# THREE THINGS IT CHECKS BEYOND "DID IT FINISH", because all three have gone
# wrong in this project already and none of them produces an error:
#
#   1. THAT THE CONSTRAINTS APPLIED. `rtl/plumbing/xilinx7/cadr_machine.xdc`
#      once built its relaxed register set with a `foreach`, which an XDC
#      rejects outright: the file read cleanly, applied to nothing, and the
#      timing report showed the unconstrained design. A file whose failure
#      mode is a plausible worse number. So the exceptions are counted after
#      reading, and then --- because a counted exception can still have
#      reached no path --- the paths themselves are asked what setup
#      requirement they carry.
#
#   2. THAT THE MACHINE IS STILL THERE. `cadr_machine` brings its whole
#      datapath out for the testbenches, and a top level that left those
#      unconnected would synthesise to nearly nothing and write a perfectly
#      good bitstream of an empty part. `cadr_arty_a7.sv` folds every output
#      into one register to prevent it; this checks that it worked.
#
#   3. THAT THE BITSTREAM IS A BITSTREAM. `write_bitstream` reporting success
#      and leaving a file too small to configure the part is the same shape of
#      failure as the other two, so the file's size is checked against what an
#      XC7A100T configuration is.
#
# **THREE FILES THIS FLOW READS LIVE UNDER THE OTHER BOARD, AND SHOULD NOT.**
# `vivado/tick.tcl`, `vivado/constraints_check.tcl` and `cadr_probe.xdc` are
# board-independent by construction --- the first takes the file to parse as
# an argument, the second takes a period and a list of instance names, and the
# third names the `BSCANE2` by what it is and the clock by a name both boards
# use. Copying them here would be three more copies to go stale, which is the
# failure this project records more often than any other, so they are read
# from `boards/arty-z7-20/` where they already are. **They belong somewhere
# neutral** --- `rtl/plumbing/xilinx7/` is where this repository's layout
# decision already puts the vendor-specific pieces that are not a board's ---
# and moving them is a commit that touches both boards, which is not this
# one's to make. `README.md` records it as owed.

set part   [expr {[info exists ::env(PART)]   ? $::env(PART)   : "xc7a100tcsg324-1"}]
set outdir [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR) : "build/a7-bitstream"}]
file mkdir $outdir

# HOW LONG A TICK IS, ASKED OF THE FABRIC THAT DECIDES IT.  The board's own
# 100 MHz is declared in `boards/arty-a7-100/cadr_arty_a7.xdc` and never moves;
# the machine's clock is derived from it by the MMCM in
# `boards/arty-a7-100/cadr_arty_a7.sv`, so Vivado works the generated clock out
# on its own and no `create_clock` is needed for it here.  What IS needed is
# the same number in Tcl, because the assertions below match a setup
# requirement as a formatted string.  `tick.tcl` parses the MMCM's four
# parameters and fails loudly if it cannot find exactly one of each, so a
# period written here can never come apart from the one being built --- and it
# is pointed at THIS board's top level, which is the whole reason that proc
# takes the file as an argument.
source boards/arty-z7-20/vivado/tick.tcl
set tick [cadr_tick_ns boards/arty-a7-100/cadr_arty_a7.sv]

set probe_depth [expr {[info exists ::env(PROBE_DEPTH)] ? $::env(PROBE_DEPTH) : 0}]

set prom build/boot_prom.hex
if {![file exists $prom]} {
    puts "BIT: $prom is missing; run `make $prom` first"
    exit 1
}

# The machine, the plumbing, and this board's top level. The other board's
# `.sv` files are NOT in this glob: `cadr_ps7.sv` instantiates a `PS7`, which
# is not a primitive on an Artix, and reading it would be a black box in a
# design that never asked for one.
read_verilog -sv [glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-a7-100/*.sv]
synth_design -top cadr_arty_a7 -part $part \
    -generic PROM_HEX=[file normalize $prom] \
    -generic PROBE_DEPTH=$probe_depth
if {$probe_depth > 0} {
    puts "BIT: PROBE_DEPTH=$probe_depth --- this is the instrumented board,"
    puts "BIT: not the one the utilisation and timing figures in README.md"
    puts "BIT: describe."
}

# The board's pins and clock, then the machine's timing exceptions.
#
# THE MACHINE'S FILE IS READ SCOPED, and that is not tidiness. Unscoped, its
# `$slow` set is `all_registers` minus a name list, and on a board
# `all_registers` includes the top level's own --- the reset synchroniser, the
# button's debounce counter, the free-running heartbeat, the microcycle beat,
# the disk lamp's one-shot --- each of which would take a fifteen-tick
# multicycle written for a datapath. `-ref cadr_machine` makes `all_registers`
# mean the machine's, which is what the file's prose has always said it meant.
read_xdc boards/arty-a7-100/cadr_arty_a7.xdc
read_xdc -ref cadr_machine rtl/plumbing/xilinx7/cadr_machine.xdc
# Only when the BSCANE2 it names is in the design: a `create_clock` on a cell
# that is not there is "No valid object(s) found", a critical warning that
# reads exactly like a constraint which applied. The file is the other board's
# and is read unchanged --- see the header for why it is not copied.
if {$probe_depth > 0} { read_xdc boards/arty-z7-20/cadr_probe.xdc }

# ...and then ask the design whether that worked, rather than trusting it.
source boards/arty-z7-20/vivado/constraints_check.tcl

# The list of places the microcycle exception is allowed to live. One when this
# is the machine on a board; two when the probe is in it, because
# `cadr_probe.xdc` relaxes the register that holds the machine's combinational
# outputs and says at length why. Nothing else, either way --- and on this
# board there is no third or fourth entry, because the memory port's 80 ns
# contract and the debug cable's four ticks both name registers that live
# behind a processing system this part has not got.
set inside u_machine
if {$probe_depth > 0} { lappend inside g_probe.u_probe }
assert_constraints_scoped $inside $tick

# --- 1. did the constraints apply?
#
# `report_exceptions` rather than a `get_*`: there is no
# `get_timing_exceptions` in Vivado 2026.1, which is worth knowing because the
# obvious name is the one that does not exist.
#
# AND IT IS COUNTED ON `cycles=`, NOT ON THE WORD "multicycle", WHICH THE
# REPORT NEVER WRITES.
report_exceptions -file $outdir/exceptions.rpt
set fh [open $outdir/exceptions.rpt r]
set exception_text [read $fh]
close $fh
set exceptions [regexp -all {cycles=} $exception_text]
set clocks     [llength [get_clocks -quiet]]
puts "BIT: $exceptions multicycle exceptions, $clocks clocks"
# Two: a setup and a hold. One alone would mean half the pair went missing.
if {$exceptions < 2} {
    puts "BIT: FAILED --- no timing exceptions were created."
    puts "BIT: cadr_machine.xdc's multicycle set applied to nothing, so every"
    puts "BIT: number this run would print is of a design constrained wrongly."
    exit 1
}
# **TWO CLOCKS ON A BOARD WHOSE TWO FREQUENCIES ARE EQUAL.** The board's
# 100 MHz and the MMCM's 100 MHz derived from it are the same number and are
# not the same clock, and a design where the generated one never appeared
# would be timed against the pin instead of against the primitive's output ---
# which here would look completely healthy, every path meeting a 10 ns period
# either way. That is exactly why this is counted rather than eyeballed.
if {$clocks < 2} {
    puts "BIT: FAILED --- $clocks clock(s); expected the board's 100 MHz and"
    puts "BIT: the MMCM's 100 MHz derived from it. A generated clock that did"
    puts "BIT: not appear means the fabric is being timed against the wrong"
    puts "BIT: one --- and on this board the two have the same period, so"
    puts "BIT: nothing else in any report would say so."
    exit 1
}

# AND THE COUNT ABOVE IS THE WEAKER TEST OF THE TWO, which is why this follows
# it rather than replacing it. `report_exceptions` lists a
# `set_multicycle_path` whose object queries matched nothing exactly as it
# lists one that reached ten thousand paths. What separates them is the setup
# requirement the paths ask for.
assert_multicycle_applied $tick 15
# **AND THE TRANSACTION AUDIT IS NOT ASKED ABOUT HERE, FOR A MEASURED
# REASON.** `rtl/plumbing/cadr_bus_audit.sv` is 347 registers under
# `cadr_machine`, and on a board with no console `*u_machine/audit/*` matches
# no flip-flop at all: the audit's record leaves the machine by the console's
# readout window, and with `con_req` and `con_ro_addr` at their idle values the
# whole module constant-folds. The other board's flow discovered that by
# stopping on it, and the guard there is its `$port`. This board has no port
# and never will have one of that shape, so the assertion is simply absent and
# this comment is why.
puts "XDC: the audit has no registers on a board with no console to read it,\
 so its split is not asked about here"

opt_design
place_design
phys_opt_design
route_design

# --- 2. is the machine still there?
set luts  [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == LUT}]]
set brams [llength [get_cells -quiet -hier -filter {PRIMITIVE_TYPE =~ BMEM.*.*}]]
set ffs   [llength [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]]
puts "BIT: $luts LUTs, $ffs registers, $brams block RAMs"
# THESE THREE ARE CELL COUNTS AND NOT THE UTILISATION REPORT'S, and the two do
# not agree by construction --- so the floors below must be read against these
# and not against the figures anybody quotes. The report counts sites, two LUT5
# cells often sharing one, and adds the sites holding distributed RAM, which
# are not in the LUT group at all.
#
# The floors are an order of magnitude under the design on purpose. What this
# has to tell apart is the machine from an empty part, not one revision from
# the next, and a floor that tracked the design would be edited every time it
# moved.
if {$luts < 1500 || $brams < 20} {
    puts "BIT: FAILED --- that is not the whole machine."
    puts "BIT: Something upstream has optimised the datapath away, which"
    puts "BIT: happens when the top level does not use what cadr_machine brings"
    puts "BIT: out. A bitstream of an empty part is the failure to look for."
    exit 1
}

report_utilization                     -file $outdir/utilisation.rpt
report_timing_summary -max_paths 10    -file $outdir/timing.rpt
report_clocks                          -file $outdir/clocks.rpt

# Guarded, because `get_timing_paths` returns an empty list when there is
# nothing to report --- and nothing to report is what SUCCESS looks like. The
# unguarded `format` threw on a met design in the other board's `fit.tcl`,
# which exited 1 and printed nothing, so success read exactly like failure.
set paths [get_timing_paths -quiet -max_paths 1 -delay_type max]
if {[llength $paths]} {
    set wns [get_property SLACK [lindex $paths 0]]
    puts "BIT: worst slack [format %.3f $wns] ns"
    if {$wns < 0} {
        puts "BIT: TIMING IS NOT MET --- the bitstream below is of a design that"
        puts "BIT: does not close. It proves the flow, not the machine."
    } else {
        puts "BIT: timing is met"
    }
} else {
    puts "BIT: no timing path reported --- timing is met"
}

# --- 3. and is it a bitstream?
set bit $outdir/cadr_arty_a7.bit
write_bitstream -force $bit
if {![file exists $bit]} {
    puts "BIT: FAILED --- write_bitstream left no file at $bit"
    exit 1
}
set size [file size $bit]
# An XC7A100T configuration is 30,606,304 bits, a little over 3.8 MB. Anything
# much smaller is a header and not a bitstream.
if {$size < 3000000} {
    puts "BIT: FAILED --- $bit is $size bytes, too small to configure an"
    puts "BIT: xc7a100t, whose configuration is about 3.8 MB."
    exit 1
}
puts "BIT: wrote $bit, $size bytes"
puts "BIT: part $part, reports in $outdir"
