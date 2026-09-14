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

# MAIN MEMORY, `DDR=1`.  The board's own 256 MB of DDR3L behind the machine's
# memory port, through Xilinx's Memory Interface Generator in the fabric ---
# generated in batch by `boards/arty-a7-100/vivado/mig.tcl` from a project file
# in the repository, and committed.  `boards/arty-a7-100/mig/README.md` is the
# argument for taking generated IP here at all.
#
#     DDR=1 OUTDIR=build/a7-ddr vivado -mode batch \
#         -source boards/arty-a7-100/vivado/bitstream.tcl
#
# ...and `PROVE=1` or `PROVE=2`, which are the same board with the proving
# witness driving the port in the machine's place: 1 writes a known word at a
# known address, 2 reads it and echoes it somewhere else.  On the Arty Z7-20 a
# debugger read DDR through the processing system; there is no such door on an
# Artix, so the observer is the JTAG window in `rtl/plumbing/cadr_jtag_mem.sv`.
set ddr   [expr {[info exists ::env(DDR)]   ? $::env(DDR)   : 0}]
set prove [expr {[info exists ::env(PROVE)] ? $::env(PROVE) : 0}]
set memory [expr {($ddr > 0 || $prove > 0) ? 1 : 0}]

set prom build/boot_prom.hex
if {![file exists $prom]} {
    puts "BIT: $prom is missing; run `make $prom` first"
    exit 1
}

# The machine, the plumbing, and this board's top level. The other board's
# `.sv` files are NOT in this glob: `cadr_ps7.sv` instantiates a `PS7`, which
# is not a primitive on an Artix, and reading it would be a black box in a
# design that never asked for one.
set srcs [glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-a7-100/*.sv]

# THE MEMORY CONTROLLER'S OWN VERILOG, read as Verilog and not as
# SystemVerilog, and only when it is going to be used.
#
# **IT IS READ AS SOURCE AND NOT AS AN IP.**  Vivado's project-mode IP flow
# would synthesise it out of context into a checkpoint and stitch that in;
# reading the generated files is what this repository does with everything
# else, it keeps this flow one `synth_design` with no intermediate artefact to
# go stale, and the generated Verilog is plain and unencrypted.
#
# And `boards/arty-a7-100/cadr_a7_memory.sv` --- which names the generated
# core --- is taken OUT of the source list when the memory is not in the
# design, because a module naming a core that is not there is a black box.
if {$memory} {
    # ...and NOT the `_sim` twin beside it.  The generator writes two files
    # defining one module, one for synthesis and one for simulation, and
    # reading both is `CRITICAL WARNING [Synth 8-9873] overwriting previous
    # definition` --- which is a warning in a log nobody reads and a design
    # built from whichever file came second.
    set mig_v {}
    foreach f [glob boards/arty-a7-100/mig/gen/rtl/*.v \
                    boards/arty-a7-100/mig/gen/rtl/*/*.v] {
        if {[string match *_sim.v $f]} { continue }
        lappend mig_v $f
    }
    read_verilog $mig_v
} else {
    set srcs [lsearch -all -inline -not -exact $srcs \
                  boards/arty-a7-100/cadr_a7_memory.sv]
}

read_verilog -sv $srcs
synth_design -top cadr_arty_a7 -part $part \
    -generic PROM_HEX=[file normalize $prom] \
    -generic PROBE_DEPTH=$probe_depth \
    -generic DDR=$ddr \
    -generic PROVE=$prove
if {$memory} {
    puts "BIT: DDR=$ddr PROVE=$prove --- the machine's memory port is answered"
    puts "BIT: by the board's own DDR3L through the generated controller."
}
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

# THE DDR3L's PINS, IN EXACTLY ONE OF TWO FILES.  With the controller in the
# design, its own generated constraints place every pin and add the slew
# rates, input terminations and bufferless clock pair its physical layer needs
# --- and the phaser, fifo and phase-locked loop placements without which it
# will not calibrate.  Without it, those same pins are ordinary input/output
# on a board that holds the memory part in reset, and
# `cadr_a7_ddr_off.xdc` is derived from the generated file by
# `boards/arty-a7-100/vivado/mig_check.py` so that the two cannot come apart.
if {$memory} {
    read_xdc boards/arty-a7-100/mig/gen/constraints/cadr_mig_a7.xdc
    read_xdc boards/arty-a7-100/cadr_a7_ddr.xdc

    # THE CROSSING BETWEEN THE MACHINE'S TICK AND THE CONTROLLER'S USER CLOCK,
    # WRITTEN HERE AND NOT IN THAT FILE.  Its header has the whole of why: an
    # XDC refuses `remove_from_collection`, so the two lines that take this
    # design's own clocks back out of the controller's did nothing, and the
    # bound was then written from the machine's clock to the machine's own ---
    # which OVERRODE the fifteen-tick exception on every path in the machine
    # and timed the design at one tick throughout.  A constraint that is too
    # wide looks like a build that finished.
    set mach [get_clocks -of_objects \
                  [get_pins -hier -filter {NAME =~ *u_mmcm/CLKOUT0}]]
    set ref  [get_clocks -of_objects \
                  [get_pins -hier -filter {NAME =~ *u_mmcm/CLKOUT1}]]
    #
    # **AND THE OBVIOUS WAY TO TAKE THEM OUT DOES NOT EXIST IN THIS TOOL.**
    # `remove_from_collection` is another vendor's command; Vivado has none,
    # and its collections are ordinary Tcl lists.  Worse, an XDC refuses it
    # with `Command 'remove_from_collection' is not supported in the xdc
    # constraint file`, which reads as "not here, use a script" and is how the
    # first draft of this came to be written twice.  The names are compared
    # instead.
    set skip {}
    foreach c [concat $mach $ref] { lappend skip [get_property NAME $c] }
    set keep {}
    foreach c [get_clocks -of_objects \
                   [get_cells -quiet -hier -filter {NAME =~ *u_mig/*}]] {
        set n [get_property NAME $c]
        if {[lsearch -exact $skip $n] >= 0} { continue }
        lappend keep $n
    }
    set mem [get_clocks -quiet $keep]
    if {[llength $mach] != 1 || [llength $mem] == 0} {
        puts "BIT: FAILED --- the machine has [llength $mach] clock(s) and the"
        puts "BIT: controller [llength $mem]. One and at least one are wanted;"
        puts "BIT: a name pattern here has stopped matching and every crossing"
        puts "BIT: constraint below would reach nothing."
        exit 1
    }
    set tick_ns [get_property PERIOD $mach]
    puts "BIT: the machine's clock is [get_property NAME $mach] at\
 [format %.3f $tick_ns] ns"
    foreach c $mem {
        puts "BIT:   the controller's [get_property NAME $c] at\
 [format %.3f [get_property PERIOD $c]] ns"
    }
    set_max_delay -datapath_only -from $mach -to $mem  $tick_ns
    set_max_delay -datapath_only -from $mem  -to $mach $tick_ns

    # AND THE THIRD CROSSING, WHICH THE FIRST BUILD LEFT OUT AND THE REPORT
    # FOUND: the tally and the calibration flag are in the CONTROLLER's clock
    # and the debugger's shift register captures them in the test access
    # port's, so that pair is a crossing too --- and an unconstrained one asks
    # for the 1.538 ns those two clocks happen to share.  **-5.367 ns, and it
    # was the worst path in the design.**  It is the same thing the Arty
    # Z7-20's debugger does when it reads the tally off pins while the fabric
    # is still counting, which that board's own notes call a count that was
    # true at some instant; a bound is what says so to the fitter.
    set_max_delay -datapath_only -from $mem -to [get_clocks jtag_mem_drck] \
        100.000
} else {
    read_xdc boards/arty-a7-100/cadr_a7_ddr_off.xdc
}

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
# **AND THE GENERATED CONTROLLER, WHICH CARRIES EXCEPTIONS OF ITS OWN.**  Its
# constraints relax a read-idle register onto the input serialisers by six
# memory clocks, which at 3.077 ns is 18.5 --- more than one of the machine's
# ticks and a half, so the check would catch it and be right to, if the
# exception were the machine's.  It is not: it is the controller's, written
# against the controller's clock, and it lives inside the controller's own
# hierarchy.  **The exemption is the generated core and NOT the memory block**,
# so `cadr_mem_cross`, `cadr_mig_ui`, `cadr_jtag_mem` and the tally are all
# still asked about.
if {$memory} { lappend inside g_memory.u_memory.u_mig }
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

# --- the memory board's own two questions
#
# **DID THE CONTROLLER'S CLOCKS APPEAR, AND IS THE CROSSING BOUNDED?**  Both
# are counted rather than eyeballed, for the reason this flow already counts
# its clocks: a constraint that reached nothing is reported exactly like one
# that reached ten thousand paths, and the two failures this pair catches are
# both invisible in a timing report.
if {$memory} {
    set uiclks [get_clocks -quiet -of_objects \
                    [get_pins -quiet -hier -filter {NAME =~ *plle2_i/CLKOUT*}]]
    if {[llength $uiclks] == 0} {
        puts "BIT: FAILED --- the memory controller's own clocks are not in the"
        puts "BIT: design. Either the generated core was not read, or its"
        puts "BIT: phase-locked loop has been renamed --- and"
        puts "BIT: boards/arty-a7-100/cadr_a7_ddr.xdc finds it by that name, so"
        puts "BIT: every crossing constraint in that file reached nothing."
        exit 1
    }
    puts "BIT: the controller makes [llength $uiclks] clock(s) of its own"

    # The payload that crosses: the address the machine asked for, held still
    # on this side while the level that points at it goes over.  If the bound
    # did not apply, these paths carry the two clocks' common period --- about
    # two nanoseconds --- and nothing else in any report says so.
    set xcells [get_cells -quiet -hier -filter {NAME =~ *u_cross/addr_q_reg*}]
    if {[llength $xcells] == 0} {
        puts "BIT: FAILED --- cadr_mem_cross's payload registers are not in the"
        puts "BIT: design, so the set_max_delay in cadr_a7_ddr.xdc named"
        puts "BIT: nothing."
        exit 1
    }
    set worst 1e9
    foreach path [get_timing_paths -quiet -from $xcells -max_paths 40 \
                                   -nworst 1 -delay_type max] {
        set req [get_property REQUIREMENT $path]
        if {$req < $worst} { set worst $req }
    }
    if {$worst < [expr {$tick * 0.9}]} {
        puts "BIT: FAILED --- the memory crossing's payload asks for"
        puts "BIT: [format %.3f $worst] ns, not the [format %.3f $tick] ns"
        puts "BIT: cadr_a7_ddr.xdc bounds it to. That is the two clocks' own"
        puts "BIT: common period, which is a requirement nobody asked for and"
        puts "BIT: no design meets --- the set_max_delay did not apply."
        exit 1
    }
    puts "BIT: [llength $xcells] register(s) of the memory crossing are bounded\
 at [format %.3f $worst] ns"
}
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
