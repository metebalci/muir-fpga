# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build a bitstream for the Cora Z7-07S.
#
#     make build/boot_prom.hex
#     vivado -mode batch -source boards/cora-z7-07s/vivado/bitstream.tcl
#
# Run from the repository root. This is
# `boards/arty-z7-20/vivado/bitstream.tcl` with this board's part, this
# board's pins and this board's top level, and with the display output's
# switch and its two constraint blocks taken out, because the Cora Z7-07S has
# no HDMI connector. Every check below is that file's and the reason for each
# is that file's; what follows is the part of its header that is about this
# board rather than about the other one.
#
# THREE THINGS IT CHECKS BEYOND "DID IT FINISH", because all three have gone
# wrong in this project already and none of them produces an error:
#
#   1. THAT THE CONSTRAINTS APPLIED. `rtl/plumbing/xilinx7/cadr_machine.xdc`
#      once built its relaxed register set with a `foreach`, which an XDC
#      rejects outright: the file read cleanly, applied to nothing, and the
#      timing report showed the unconstrained design. A file whose failure mode
#      is a plausible worse number. So the exceptions are counted after
#      reading, and a run with none stops --- and then, because a counted
#      exception can still have reached no path, the paths themselves are
#      asked what setup requirement they carry.
#
#   2. THAT THE MACHINE IS STILL THERE. `cadr_machine` brings its whole
#      datapath out for the testbenches, and a top level that left those
#      unconnected would synthesise to nearly nothing and write a perfectly
#      good bitstream of an empty part. `cadr_cora.sv` folds every output into
#      one register to prevent it; this checks that it worked.
#
#   3. THAT THE BITSTREAM IS A BITSTREAM. `write_bitstream` reporting success
#      and leaving a file too small to be one is the same class of thing.
#
# **THE XC7Z007S IS THE TIGHT PART AND THIS FLOW IS WHAT SAYS WHETHER THE
# MACHINE FITS ON IT.** Until this script existed the only answer anybody had
# was a ratio out of Vivado's part database, and a ratio is not a fit. What it
# reports is in `boards/cora-z7-07s/README.md` with the commit it was measured
# at, and a figure without its commit is not a figure: a bit-identical netlist
# has moved worst slack by a quarter of a nanosecond in this project before.
#
# NOTHING BUILT BY THIS HAS BEEN ON SILICON. No Cora Z7-07S has ever been
# programmed with a bitstream from this repository.

set part   [expr {[info exists ::env(PART)]   ? $::env(PART)   : "xc7z007sclg400-1"}]
set outdir [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR) : "build/bitstream"}]
file mkdir $outdir

# HOW LONG A TICK IS, ASKED OF THE FABRIC THAT DECIDES IT.  The board's own
# 125 MHz is declared in `boards/cora-z7-07s/cadr_cora.xdc` and never moves;
# the machine's clock is derived from it by the MMCM in
# `boards/cora-z7-07s/cadr_cora.sv`, so Vivado works the generated clock out
# on its own and no `create_clock` is needed for it here.  What IS needed is
# the same number in Tcl, because the two assertions below match a setup
# requirement as a formatted string.  `tick.tcl` parses the MMCM's four
# parameters and fails loudly if it cannot find exactly one of each, so a
# period written here can never come apart from the one being built.
#
# **`tick.tcl` AND `constraints_check.tcl` ARE READ OUT OF THE ARTY Z7-20's
# DIRECTORY, AND THAT IS DELIBERATE.**  Neither knows anything about a part:
# one parses four MMCM parameters out of whatever file it is handed, and the
# other asks a design what setup requirement its paths carry.  They live in
# the first board's directory because that is where they were written, and a
# copy of either here would be a second description of the same rule --- which
# is the failure this repository spends most of its prose on.  `tick.tcl` takes
# the Cora's own file as an argument, so nothing about the other board is
# assumed.  When a directory shared between boards exists, these two move into
# it.
source boards/arty-z7-20/vivado/tick.tcl
set tick [cadr_tick_ns boards/cora-z7-07s/cadr_cora.sv]

# AND ONE SWITCH, WHICH BUILDS A DIFFERENT BOARD.
#
#     PROBE_DEPTH=1024 OUTDIR=build/probe vivado -mode batch -source boards/cora-z7-07s/vivado/bitstream.tcl
#
# puts `rtl/plumbing/xilinx7/cadr_probe.sv` in the design: one sample a microcycle of the
# columns `build/rtl.golden` carries, in block RAM, shifted out over JTAG by
# `boards/cora-z7-07s/vivado/probe.tcl`. Zero, the default, is the machine and nothing else ---
# the same LUTs, the same registers, the same 28 block RAM tiles --- so every
# number this script has ever printed still describes the design it described.
#
# **THE SWITCH IS HERE RATHER THAN IN A FLOW OF ITS OWN** because the three
# checks below are policy and not convenience: a second script that placed and
# routed a bitstream would have to repeat them, and a repeated check is a check
# that goes stale on one side. What the instrumented build needs beyond them is
# one constraint file, read only when the cell it names exists --- a
# `create_clock` on an absent object is the "No valid object(s) found" warning
# `rtl/plumbing/xilinx7/cadr_machine.xdc`'s header is about.
set probe_depth [expr {[info exists ::env(PROBE_DEPTH)] ? $::env(PROBE_DEPTH) : 0}]

# AND A SECOND SWITCH, ON THE SAME ARGUMENT.
#
#     DDR=1 OUTDIR=build/ddr vivado -mode batch -source boards/cora-z7-07s/vivado/bitstream.tcl
#
# puts the Zynq processing system and DDR3 behind the machine's memory port:
# `boards/cora-z7-07s/cadr_ps7.sv`, `rtl/plumbing/cadr_axi_master.sv`, and the widening between the
# machine's 32-bit word and `S_AXI_HP0`'s 64-bit one. Zero, the default, ties
# `mem_done` low exactly as this flow has always tied it, so every number
# printed below still describes the design it has always described.
#
# It is a switch and not a second script for the reason the probe's is: the
# three checks below are policy, and a flow that repeated them would be a
# second copy to go stale.
set ddr [expr {[info exists ::env(DDR)] ? $::env(DDR) : 0}]

# AND A THIRD, WHICH BUILDS THE BOARD THAT ANSWERS WHETHER ANY OF IT WORKS.
#
#     PROVE=1 OUTDIR=build/prove-write vivado -mode batch -source boards/cora-z7-07s/vivado/bitstream.tcl
#     PROVE=2 OUTDIR=build/prove-read  vivado -mode batch -source boards/cora-z7-07s/vivado/bitstream.tcl
#
# `rtl/plumbing/cadr_prove.sv` in the design, driving the machine's own memory port ---
# the same adapter, the same widening, the same PS7 --- with one word at one
# address. `PROVE=1` writes it as soon as `SAXIHP0ARESETN` says the port is
# live and stops; `PROVE=2` reads it back as soon as the port comes live and
# writes what it read, raw, to a second address for the debugger to compare
# --- no button, and the lamp is not the observer. The observer for both is a
# debugger reading DDR from outside the design, which is the whole point: the
# design cannot mark its own work.
#
# A `PROVE` BOARD IS A `DDR` BOARD, and `boards/cora-z7-07s/cadr_cora.sv` makes it one --- its
# `PORT` localparam is set by either generic --- so `PROVE=1` alone is a
# complete instruction and everything below that asks "is the processing
# system in this design" has to ask about both.
set prove [expr {[info exists ::env(PROVE)] ? $::env(PROVE) : 0}]

# **THERE IS NO `HDMI` SWITCH ON THIS BOARD.**  The Cora Z7-07S has no HDMI
# connector, so there is no display output to build and `cadr_cora.sv` has no
# `HDMI` parameter to set.  `boards/arty-z7-20/vivado/bitstream.tcl` has that
# third switch and this one does not, which is the one place the two flows
# differ in what they can build.  The CADR's screen on this board is
# `cadr-terminal`'s RFB server over the network.
if {$prove != 0 && $prove != 1 && $prove != 2} {
    puts "BIT: FAILED --- PROVE=$prove is not a board. 1 writes a word, 2 reads"
    puts "BIT: one back, 0 is the machine. See rtl/plumbing/cadr_prove.sv."
    exit 1
}
# Everything below asks this rather than `$ddr`.
set port [expr {($ddr > 0 || $prove > 0) ? 1 : 0}]

set prom build/boot_prom.hex
if {![file exists $prom]} {
    puts "BIT: $prom is missing; run `make $prom` first"
    exit 1
}

# **THE GLOB DROPS THE SOFT PROCESSING SYSTEM, AND IT HAS TO.**
# `rtl/plumbing/cadr_soc*.sv` is the Arty A7-100's Ibex core and the four
# modules around it: a part with no processing system of its own needs one in
# fabric, and this board has a hard one. Those files name Ibex's own packages,
# which live under `third_party/ibex/` and are read only by that board's flow,
# so a glob that took them in stops synthesis with `'ibex_pkg' is not
# declared` --- measured, and it is what a glob does the moment somebody adds
# a file to a shared directory for another board.
#
# Read rather than filtered would be the other way round, and it is worth
# saying why this way. A list would have to be kept in step with `rtl/` by
# hand, which is the thing the glob exists to avoid; naming what does NOT
# belong is one line and rots loudly, because a soft-system file that stopped
# matching would stop the build with the same error.
set sources {}
foreach f [glob rtl/*/*.sv rtl/*/*/*.sv boards/cora-z7-07s/*.sv] {
    if {[string match */cadr_soc*.sv $f]} { continue }
    lappend sources $f
}
read_verilog -sv $sources
synth_design -top cadr_cora -part $part \
    -generic PROM_HEX=[file normalize $prom] \
    -generic PROBE_DEPTH=$probe_depth \
    -generic DDR=$ddr \
    -generic PROVE=$prove
if {$probe_depth > 0} {
    puts "BIT: PROBE_DEPTH=$probe_depth --- this is the instrumented board,"
    puts "BIT: not the one the utilisation and timing prose below describes."
}
if {$port > 0} {
    puts "BIT: the processing system is behind the memory port, so this board"
    puts "BIT: is neither the design the utilisation prose below describes nor"
    puts "BIT: the one the timing prose does."
}
if {$prove > 0} {
    puts "BIT: PROVE=$prove --- rtl/plumbing/cadr_prove.sv drives that port and the"
    puts "BIT: machine does not. The machine is still in the design and still"
    puts "BIT: stalls on its own memory exactly as the default board does;"
    puts "BIT: what this bitstream is for is [expr {$prove == 1 ? {one write a debugger reads back} : {one read a debugger set up}}]."
}

# The board's pins and clock, then the machine's timing exceptions.
#
# THE MACHINE'S FILE IS READ SCOPED, and that is not tidiness. Unscoped, its
# `$slow` set is `all_registers` minus a name list, and on a board `all_
# registers` includes the top level's own --- 26 of them when this was written,
# the reset synchroniser and the free-running heartbeat, each taking a
# fifteen-tick multicycle written for a datapath. `-ref cadr_machine` makes
# `all_registers` mean the machine's, which is what the file's prose has
# always said it meant.
#
# THE COUNT IS NOT THE CHECK, and it has already moved: `cadr_cora.sv` at
# b1bcc34 declares 55 registers of its own --- `rst_sync` is 4 bits now and
# not 2, plus `beat` 24, `tick` 26 and `witness` 1 --- so a run that matched
# on 26 would be matching on nothing in particular. What holds the property is
# `assert_constraints_scoped` below, which asks the design whether any
# register outside `u_machine` carries a relaxed requirement, and does not
# care how many there are.
read_xdc boards/cora-z7-07s/cadr_cora.xdc
read_xdc -ref cadr_machine rtl/plumbing/xilinx7/cadr_machine.xdc
# Only when the BSCANE2 it names is in the design. See the switch above.
if {$probe_depth > 0} { read_xdc boards/cora-z7-07s/cadr_probe.xdc }
# And the same rule for the memory port's own deadline: every object
# `rtl/plumbing/xilinx7/cadr_ddr.xdc` names is inside `g_ddr`, so reading it against the
# default board would be four critical warnings about absent objects.
if {$port > 0} { read_xdc rtl/plumbing/xilinx7/cadr_ddr.xdc }

# And the debug cable's, by the same rule: `rtl/plumbing/xilinx7/cadr_debug.xdc`
# names one register of `cadr_debug_window`, which is inside `g_ddr` too. What
# it exists for is measured and is in its own header --- the machine's
# diagnostic mux reaching the carrier's latch, 23 levels, -8.772 ns on a board
# that read +0.914 one commit earlier.
if {$port > 0} { read_xdc rtl/plumbing/xilinx7/cadr_debug.xdc }
# And the Pmod carrier's, which is the same cone with a second reader on it:
# `rtl/plumbing/xilinx7/cadr_debug_pmod.xdc` names the frame registers of the
# connector's sender. **NOT GATED, where the window's is.** A board is always
# a DEBUGGEE --- Pmod JA is instantiated whatever the switches say, because a
# CADR answers a debugger that plugs in and nothing has to be set for it ---
# so the machine's diagnostic mux reaches that sender on every board. Gated,
# the memory-off board came out at -9.600 ns on 596 endpoints with the file
# read by nothing; that file's own header has the measurement.
read_xdc rtl/plumbing/xilinx7/cadr_debug_pmod.xdc

# ...and then ask the design whether that worked, rather than trusting it.
source boards/arty-z7-20/vivado/constraints_check.tcl
# The list of places the microcycle exception is allowed to live. One when
# this is the machine on a board; two when the probe is in it, because
# `boards/cora-z7-07s/cadr_probe.xdc` relaxes the register that holds the machine's
# combinational outputs and says at length why. Nothing else, either way.
#
# A THIRD ENTRY WITH `DDR=1`, and it is the memory's own contract rather than
# a convenience. `rtl/plumbing/xilinx7/cadr_machine.xdc` gives `mem_addr`, `mem_wdata` and
# `mem_write` sixteen ticks --- the 80 ns the bus specification makes the
# master responsible for --- and what receives them is `cadr_axi_master`'s
# address and data registers, which are outside `u_machine` by construction.
# So the adapter joins the list, and what the invariant still says is that
# nothing ELSE outside the machine is relaxed: the port's reset synchroniser
# and the held error bit sit beside it in `g_ddr` and are not exempt.
#
# A FOURTH WITH `DDR=1`, and it is the debug cable's own contract on the same
# footing. `rtl/plumbing/xilinx7/cadr_debug.xdc` gives four ticks to the
# sixteen bits of `DBD` the debuggee drives, because the word has been
# standing for twenty-five by the time the carrier latches it, and the carrier
# is outside `u_machine` by construction --- the cable is the boundary. The
# entry names the WINDOW and the exemption is one register of it; what keeps
# that honest is `assert_instance_timing` below, which fails if any other
# register of the window carries it.
#
# A FIFTH WITH `DDR=1`, and it is that same cone with a second reader on it.
# The Pmod carrier on the DBGIN connector sends the word a remote debugger
# reads, so `cadr_dbgin.sv`'s `DBD<15:0>` now ends at a frame register outside
# the machine as well as at the window's latch. Measured before it was
# constrained: -9.779 ns on 3,905 endpoints, the ten worst all in that one
# register. `rtl/plumbing/xilinx7/cadr_debug_pmod.xdc` has the argument and
# the numbers; the DBGOUT connector's sender is NOT in this list, because what
# feeds it is the window's own fast registers and not the machine's mux.
set inside u_machine
if {$probe_depth > 0} { lappend inside g_probe.u_probe }
if {$port > 0}        { lappend inside g_ddr.u_axi g_ddr.u_debug_window }
# **AND THE CONNECTOR IS IN THE LIST WHATEVER THE SWITCHES SAY**, for the
# reason its constraint file is read unconditionally: a board is always a
# debuggee, so the cable's sender is relaxed on every board and the invariant
# would otherwise fail on the memory-off one.
lappend inside u_dbg_cable
assert_constraints_scoped $inside $tick

# --- 1. did the constraints apply?
#
# `report_exceptions` rather than a `get_*`: there is no
# `get_timing_exceptions` in Vivado 2026.1, which is worth knowing because the
# obvious name is the one that does not exist and an unguarded call to it
# aborts the script two hundred lines before anything is built.
#
# AND IT IS COUNTED ON `cycles=`, NOT ON THE WORD "multicycle", WHICH THE
# REPORT NEVER WRITES. The first version of this check looked for that word,
# found none, and stopped a run whose constraints had applied perfectly ---
# `cycles=15` setup and `cycles=14` hold, at positions 4 and 5 of the report
# when that was written and 5 and 6 at b1bcc34, `witness_reg`'s false path
# having joined the list in between. Position is not the thing to match on. A
# guard that cries wolf is worse than no guard, and this one was written
# against a report format nobody had read. The same mistake as the `foreach`
# it exists to catch, one level up.
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
if {$clocks < 2} {
    puts "BIT: FAILED --- $clocks clock(s); expected the board's 125 MHz and"
    puts "BIT: the MMCM's 100 MHz derived from it. A generated clock that did"
    puts "BIT: not appear means the fabric is being timed against the wrong one."
    exit 1
}

# AND THE COUNT ABOVE IS THE WEAKER TEST OF THE TWO, which is why this follows
# it rather than replacing it. `report_exceptions` lists a `set_multicycle_path`
# whose object queries matched nothing exactly as it lists one that reached
# 10,929 paths --- the statement was read either way, so the exception exists
# either way, and the `foreach` bug would pass the count. What separates them
# is the setup requirement the paths ask for. The count still earns its place:
# it is the half that says a setup exception has a hold exception beside it.
assert_multicycle_applied $tick 15
# **AND WHICH SET THE TRANSACTION AUDIT'S REGISTERS FELL INTO, ASKED DIRECTLY
# RATHER THAN INFERRED FROM A COUNT.** `rtl/plumbing/cadr_bus_audit.sv` is 347
# registers under `cadr_machine`, which relaxes everything it does not name ---
# so without a clause they would all have been relaxed and nothing would have
# said so. Its three edge detectors and its counters are read every tick and a
# relaxed edge detector misses an edge or invents one; its record, its
# microcycle counter and its readout word are written once and read by a
# console on a halted machine. `assert_instance_timing` holds both halves, and
# the reason it is here rather than left to a reader is the disk controller's
# 3,904 of 4,000: that was found by asking the checkpoint, and nothing in the
# repository had been asking.
#
# **AND IT IS ASKED ONLY WHERE THE AUDIT HAS REGISTERS, WHICH IS NOT
# EVERYWHERE.** Measured 2026-09-12: on the memory-off board `*u_machine/
# audit/*` matches NO flip-flop at all and this assertion stopped the flow.
# The reason is the audit's only consumer: its record leaves the machine by
# the console's readout window, and a board with no processing system has no
# console --- `g_nomem` holds `con_req` and `con_ro_addr` at their idle
# values --- so the whole module constant-folds. That is the same fact as
# `mem_addr` having no timing while its only consumer was a false-pathed
# fold, and the assertion's own message could not tell it from the renamed
# instance it exists to catch. The guard is `$port`, as the memory
# contract's assertion below already is.
#
# THE FLOW HAD BEEN BROKEN THERE SINCE `559f749`, when the assertion landed,
# and nobody had run the memory-off board since: the control run at that
# board's own HEAD fails identically, 18,796 of 26,803 setup paths at
# 150.000 ns and the same refusal. A flow nobody runs is a flow that says
# nothing, which is this project's oldest lesson in a new place.
if {$port > 0} {
    assert_instance_timing $tick 15 *u_machine/audit/* \
        {*audit/first_* *audit/micro_reg* *audit/word_reg*}
} else {
    puts "XDC: the audit has no registers on a board with no console to read\
          it, so its split is not asked about here"
}
# And the memory port's own deadline, which has a destination only on this
# board: with `DDR` off, `mem_addr` reaches nothing but a false-pathed fold
# and the exception is real, legal and connected to nothing. Asserting it
# there would fail on a healthy design; not asserting it here would leave the
# 80 ns claim exactly as unchecked as it was before it existed.
if {$port > 0} { assert_multicycle_applied $tick 16 }
# And the debug cable's four ticks, the same way and for the same reason. The
# instance assertion is the narrow half --- `sts_dbd_reg` may carry it and no
# other register of the carrier may --- and the count is the `foreach` half,
# that it reached a path at all.
if {$port > 0} {
    assert_instance_timing $tick 4 *g_ddr.u_debug_window/* {*sts_dbd_reg*}
}
# And the Pmod carrier's, the same two halves, and ASSERTED ON EVERY BOARD
# because the connector is on every board. The frame registers of the
# carrier's sender may carry it; the strobe's synchroniser, the beat counter,
# the gap counter and the dead man may not, because a counter given four ticks
# to settle is a counter that no longer counts.
assert_instance_timing $tick 4 *u_dbg_cable/* {*tx_frame_reg* *tx_d_reg*}
assert_multicycle_applied $tick 4

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
# and not against the figures anybody quotes. Measured on the board's routed
# design at 712909e: `PRIMITIVE_GROUP == LUT` is 2,101 cells where
# `report_utilization` says 2,876 Slice LUTs, because the report counts sites
# (1,755 as logic, two LUT5 cells often sharing one) and adds the 1,121 sites
# holding distributed RAM, which are not in the LUT group at all --- they are
# `PRIMITIVE_GROUP == DMEM`, 1,411 cells of it. Block RAM goes the other way:
# 29 BMEM cells against 28 tiles, a tile holding two RAMB18s. The registers are
# the one pair that match, 773 either way. Out of context the report says 2,795
# Slice LUTs, 769 registers, 28 tiles.
#
# At b1bcc34 this line printed `2088 LUTs, 746 registers, 29 block RAMs`
# against 2,871 Slice LUTs and 746 registers in the report, so both counts
# move a percent or two with the top level and neither is a constant.
#
# The floors are an order of magnitude under all of that on purpose. What this
# has to tell apart is the machine from an empty part, not one revision from
# the next, and a floor that tracked the design would be edited every time it
# moved.
if {$luts < 1500 || $brams < 20} {
    puts "BIT: FAILED --- that is not the whole machine."
    puts "BIT: Routed on the board it is 2,101 LUT cells and 29 BMEM cells."
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
# unguarded `format` below threw on a met design in `fit.tcl`, which exited 1
# and printed nothing, so success read exactly like failure.
#
# It is the sharpest of a family: a diagnostic gets less testing than the
# thing it diagnoses, and this one lives in **the path that only exists once
# the thing works**. A project that has been failing at something has never
# run its own success case. This branch had never executed here at all until
# the tick became 6.25 ns --- the design had never met its clock --- so it was
# fixed on the strength of what happened next door rather than after it
# happened twice, and the first run that exercised it found it correct.
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

# --- 3. and is it a bitstream, and does it say which tree it came from?
#
# The commit goes into `BITSTREAM.CONFIG.USERID`, which the part reads back
# over JTAG as its USERCODE, so `program.tcl` can tell that a download took on
# a part that was already configured --- which the DONE bit cannot.  A dirty
# tree is recorded and never refused.  `tools/build_stamp.tcl` has the format,
# the two property names and what was measured about them, and it also sets
# `BITSTREAM.CONFIG.USR_ACCESS` to the same value: **nothing reads that one
# back yet**, and a `USR_ACCESSE2` in the fabric with a console word to print
# it is a slice of its own.
source [file join [file dirname [file normalize [info script]]] .. .. .. tools build_stamp.tcl]
set stamp [build_stamp_of_tree]
puts "BIT: build [lindex $stamp 0] --- commit [lindex $stamp 1], tree [lindex $stamp 2]"
build_stamp_apply [current_design] [lindex $stamp 0]

set bit $outdir/cadr_cora.bit
write_bitstream -force $bit
if {![file exists $bit]} {
    puts "BIT: FAILED --- write_bitstream left no file at $bit"
    exit 1
}
set size [file size $bit]
# An XC7Z007S configuration is smaller than an XC7Z020's four megabytes,
# the die being smaller, so the other board's floor would reject a perfectly
# good bitstream here. Anything much under this is a header and not a
# bitstream.
if {$size < 1500000} {
    puts "BIT: FAILED --- $bit is $size bytes, too small to configure an xc7z007s"
    exit 1
}
if {![build_stamp_stamped "BIT:" $bit $stamp]} { exit 1 }
puts "BIT: wrote $bit, $size bytes"
puts "BIT: part $part, reports in $outdir"
