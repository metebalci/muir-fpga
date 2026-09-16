# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build a bitstream for the Arty A7-100.
#
#     make build/boot_prom.hex build/sync_prom.hex
#     vivado -mode batch -source boards/arty-a7-100/vivado/bitstream.tcl
#
# Run from the repository root. This is `fit.tcl`'s sibling: that one asks
# what the machine costs, out of context and with no pins; this one asks
# whether it can be built at all, against a real part with the board's own
# package pins, through to a `.bit`.
#
# **THIS BOARD HAS NO PROCESSING SYSTEM, AND ITS SWITCHES ARE ITS OWN:
# `PROBE_DEPTH`, `DDR`, `PROVE` AND `SOC`.**  The Arty Z7-20's flow carries
# `DDR`, `PROVE` and `HDMI`, and every one of the three turns on a port of the
# Zynq's. There is no Zynq here: `DDR` and `PROVE` below mean the board's own
# DDR3L through the generated controller, `HDMI` has no counterpart, and `SOC`
# is the soft processing system the other board has no need of. `PROBE_DEPTH`
# is pure fabric and carries over unchanged:
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
#      unconnected would synthesize to nearly nothing and write a perfectly
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

# **THE SOFT PROCESSING SYSTEM, THE FOURTH SWITCH.**  `SOC=1` puts
# `rtl/plumbing/cadr_soc.sv` --- an Ibex core in fabric, its memory with the
# firmware already in it, a UART, a timer and a bridge --- and the four
# register faces it masters into the design, at the addresses the Linux
# programs on the other two boards use.  Zero, the default, is the machine and
# its tie-offs, which is what every figure in `README.md` was measured on.
#
#     SOC=1 OUTDIR=build/a7-soc \
#         vivado -mode batch -source boards/arty-a7-100/vivado/bitstream.tcl
#
# **AND IT BRINGS A SECOND CLOCK WITH IT.**  Ibex computes a load or a store's
# address in the cycle it uses it, and on this part that arc is about 12.9 ns
# against a 10 ns tick; the machine's tick cannot move, every instant in
# `rtl/machine/` being a count of them.  So the soft system runs on `CLKOUT2`
# of the same manager at 50 MHz and the seam between it and the three faces is a
# clock domain crossing --- `rtl/plumbing/cadr_soc_cross.sv`, bounded by
# `rtl/plumbing/xilinx7/cadr_soc.xdc`.  Three things are asserted about that
# below and each of them has a silent failure behind it: that there IS a second
# clock, that the bound reached paths in both directions, and that nothing in
# the soft system is taking a multicycle exception against its own period.
#
# **`SOC=1 DDR=1` IS THE WHOLE BOARD** and is the configuration to build for
# it: the machine with its memory behind it and the soft processing system in
# front of the faces, with both of the design's crossings in one netlist.
set soc [expr {[info exists ::env(SOC)] ? $::env(SOC) : 0}]
# **THE SECOND DISPLAY BOARD, `LMTV=1`.**  MIT's color TV --- `lmtv.order`'s
# "for the color TV, x is 5" --- a second `rtl/machine/cadr_tv.sv` strapped to
# 0o17200000 with its control words at 0o17377750, its frame buffer a second
# window of the display's region of memory, and its color map read by the
# console face.  On by default: whether a MACHINE has the board is the
# console's page 2 word 33, so a fabric that carries the slot is still a
# one-display machine until somebody says otherwise.  Zero leaves the slot
# out of the fabric, for a part with no room for it.
set lmtv [expr {[info exists ::env(LMTV)] ? $::env(LMTV) : 1}]


set prom build/boot_prom.hex
if {![file exists $prom]} {
    puts "BIT: $prom is missing; run `make $prom` first"
    exit 1
}

# And MIT's TV sync PROM, which the display runs from power-on.  Checked here
# for the reason the boot PROM is: `$readmemh` on a file that is not there is
# a WARNING, and a sync program of zeros is a display that never interrupts
# --- which synthesizes, routes and writes a bitstream.
set sync_prom build/sync_prom.hex
if {![file exists $sync_prom]} {
    puts "BIT: $sync_prom is missing; run `make $sync_prom` first"
    exit 1
}

# **THE FIRMWARE IS PART OF THE BITSTREAM AND ITS ABSENCE IS FATAL.**  The
# soft system's memory takes its contents at elaboration, the way the control
# store takes MIT's boot PROM, so a bitstream built without the hex would
# carry a memory of nothing and a core that runs zeros --- which on RISC-V is
# an illegal instruction at the first fetch.  `$readmemh` on a missing file is
# a warning and not an error, so this is the thing that has to notice.
set firmware build/soc_firmware.hex
if {$soc != 0 && ![file exists $firmware]} {
    puts "BIT: $firmware is missing; run `make $firmware` first"
    exit 1
}

# The machine, the plumbing, and this board's top level. The other board's
# `.sv` files are NOT in this glob: `cadr_ps7.sv` instantiates a `PS7`, which
# is not a primitive on an Artix, and reading it would be a black box in a
# design that never asked for one.
set sources [glob rtl/*/*.sv rtl/*/*/*.sv boards/arty-a7-100/*.sv]

# **AND THE SOFT PROCESSING SYSTEM COMES OUT AGAIN WHEN IT IS NOT IN THE
# DESIGN**, for `cadr_a7_memory.sv`'s reason one paragraph down and for a
# sharper one: `rtl/plumbing/cadr_soc*.sv` names Ibex's own packages, and those
# are read below only when `SOC` is set. Left in the list with `SOC` clear,
# synthesis stops with `'ibex_pkg' is not declared` --- measured, on the
# board's own default configuration, which is the one every figure in
# `boards/arty-a7-100/README.md` was taken on.
#
# A glob over a shared directory does this the moment somebody adds a file to
# it for one board, and the answer is the same here as in the two Zynq flows:
# name what does not belong, in one line, where a soft-system file that stopped
# matching would stop the build with the same error rather than quietly.
if {$soc == 0} {
    set soc_free {}
    foreach f $sources {
        if {[string match */cadr_soc*.sv $f]} { continue }
        lappend soc_free $f
    }
    set sources $soc_free
}

# THE MEMORY CONTROLLER'S OWN VERILOG, read as Verilog and not as
# SystemVerilog, and only when it is going to be used.
#
# **IT IS READ AS SOURCE AND NOT AS AN IP.**  Vivado's project-mode IP flow
# would synthesize it out of context into a checkpoint and stitch that in;
# reading the generated files is what this repository does with everything
# else, it keeps this flow one `synth_design` with no intermediate artifact to
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
    set sources [lsearch -all -inline -not -exact $sources \
                     boards/arty-a7-100/cadr_a7_memory.sv]
}

set incdirs {}

if {$soc != 0} {
    # Ibex, as lowRISC publishes it.  `third_party/ibex/README.md` says which
    # commit, which files and why, and carries a digest for each.  The two
    # include directories are its own: `prim_assert.sv` and the macro files
    # beside it, and `dv_fcov_macros.svh`.
    set sources [concat $sources \
        [glob third_party/ibex/rtl/*.sv] \
        third_party/ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_cipher_pkg.sv \
        third_party/ibex/vendor/lowrisc_ip/ip/prim/rtl/prim_lfsr.sv]
    set incdirs [list third_party/ibex/vendor/lowrisc_ip/ip/prim/rtl \
                      third_party/ibex/vendor/lowrisc_ip/dv/sv/dv_utils]
}
read_verilog -sv $sources

# `SYNTHESIS` is what makes Ibex's assertion macros empty --- `prim_assert.sv`
# dispatches on it --- and it is passed explicitly rather than relied on:
# whether a tool defines it for SystemVerilog is a property of the tool and
# this repository's rule is to read rather than to guess.
set synth_args [list -top cadr_arty_a7 -part $part \
    -generic PROM_HEX=[file normalize $prom] \
    -generic SYNC_PROM_HEX=[file normalize $sync_prom] \
    -generic PROBE_DEPTH=$probe_depth \
    -generic DDR=$ddr \
    -generic PROVE=$prove \
    -generic SOC=$soc \
    -generic LMTV=$lmtv]
if {$soc != 0} {
    lappend synth_args -generic FIRMWARE_HEX=[file normalize $firmware]
    lappend synth_args -include_dirs $incdirs
    lappend synth_args -verilog_define SYNTHESIS=1
    puts "BIT: SOC=1 --- the soft processing system is in this design, with"
    puts "BIT: the firmware from $firmware."
}
synth_design {*}$synth_args
if {$memory} {
    puts "BIT: DDR=$ddr PROVE=$prove --- the machine's memory port is answered"
    puts "BIT: by the board's own DDR3L through the generated controller."
}
if {$probe_depth > 0} {
    puts "BIT: PROBE_DEPTH=$probe_depth --- this is the instrumented board,"
    puts "BIT: not the one the utilization and timing figures in README.md"
    puts "BIT: describe."
}

# The board's pins and clock, then the machine's timing exceptions.
#
# THE MACHINE'S FILE IS READ SCOPED, and that is not tidiness. Unscoped, its
# `$slow` set is `all_registers` minus a name list, and on a board
# `all_registers` includes the top level's own --- the reset synchronizer, the
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
# **`rtl/plumbing/xilinx7/cadr_debug.xdc` IS NOT READ ON THIS BOARD, BECAUSE
# THE REGISTER IT NAMES IS NOT HERE.**  That file gives four ticks to one
# register inside `rtl/plumbing/cadr_debug_window.sv` --- the window a debugger
# reaches over a general-purpose port, which is how muir on a Zynq board's ARM
# cores plays the far end of MIT's debug cable in software.  There is no such
# program on this board and no window in any configuration of it; the debugger
# here is a SECOND BOARD on Pmod JB, through the carrier below.  An XDC read
# for a module that is not in the design applies to nothing, and this
# repository's own record of what that looks like is a page long: a constraint
# naming an absent object is "No valid object(s) found", a critical warning
# that reads exactly like a constraint which applied.
#
# **AND THE COST IT USED TO BUY IS NOT LOST, BECAUSE THE CARRIER PAYS IT.**
# The arc the file exists for is the machine's diagnostic multiplexer reaching
# a register a level above `cadr_machine` --- measured here at -9.236 ns from
# `memstart_reg_replica` into the window's `sts_dbd_reg[1]` before it was read.
# The carrier's own sender is at the far end of the same cone and is on every
# configuration of this board, so `cadr_debug_pmod.xdc` below is read with no
# `if` on it at all and is what holds that arc now.
# **AND THE SOFT SYSTEM'S OWN CLOCK, WHICH IS NOT THE MACHINE'S.**  Ibex
# computes a load or a store's address in the cycle it uses it and that arc
# does not settle in a 10 ns tick, so the core runs on `CLKOUT2` of the same
# manager and the seam between it and the faces is a clock domain crossing.
# `rtl/plumbing/xilinx7/cadr_soc.xdc` bounds everything that crosses with a
# maximum delay and deliberately does NOT group the two clocks; its header has
# the whole argument, and the assertions that it reached anything are below,
# where they can be written in ordinary Tcl.
if {$soc != 0} { read_xdc rtl/plumbing/xilinx7/cadr_soc.xdc }

# AND THE PMOD CARRIER'S, WHICH ON THIS BOARD IS THE ONLY READER OF THAT CONE
# AND WHICH IS NOT GATED.  `rtl/plumbing/xilinx7/cadr_debug_pmod.xdc` names the
# frame registers of the debug cable's sender on Pmod JB --- JB rather than the
# JA the two Zynq boards use, this being the only board with four headers and
# the only one whose headers differ; `boards/arty-a7-100/cadr_arty_a7.xdc` has
# the argument and the pins.  A board is always a DEBUGGEE --- the connector is
# instantiated whatever `SOC` says, because a CADR answers a debugger that
# plugs in and nothing has to be set for it --- so the machine's diagnostic mux
# reaches that sender on every configuration of this board, including the ones
# with no soft processing system at all.  That is the file's own header, and it
# is why this read has no `if` on it.
read_xdc rtl/plumbing/xilinx7/cadr_debug_pmod.xdc

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
# outputs and says at length why.  The memory controller and the debug cable's
# connector add one each below, and the debug cable's WINDOW adds none: it is
# not on this board in any configuration, and the memory port's 80 ns contract
# names registers that live behind a processing system this part has not got.
set inside u_machine
if {$probe_depth > 0} { lappend inside g_probe.u_probe }
# **AND THE GENERATED CONTROLLER, WHICH CARRIES EXCEPTIONS OF ITS OWN.**  Its
# constraints relax a read-idle register onto the input serializers by six
# memory clocks, which at 3.077 ns is 18.5 --- more than one of the machine's
# ticks and a half, so the check would catch it and be right to, if the
# exception were the machine's.  It is not: it is the controller's, written
# against the controller's clock, and it lives inside the controller's own
# hierarchy.  **The exemption is the generated core and NOT the memory block**,
# so `cadr_mem_cross`, `cadr_mig_ui`, `cadr_jtag_mem` and the tally are all
# still asked about.
if {$memory} { lappend inside g_memory.u_memory.u_mig }
# **AND NOT THE DEBUG CABLE's WINDOW, WHICH THE OTHER TWO BOARDS' FLOWS LIST
# HERE AND THIS ONE HAS NOT GOT.**  `g_ddr.u_debug_window` is in the Arty
# Z7-20's list because `cadr_debug.xdc` gives a register in that module four
# ticks; there is no window on this board in any configuration, nothing is
# read that could relax one, and an entry naming an absent instance would be
# an exemption that tests nothing while looking exactly like one that is
# right.  The connector below is what carries the cable here.
# **AND THE DEBUG CABLE'S CONNECTOR WHATEVER `SOC` SAYS**, for the reason its
# constraint file is read unconditionally one screen up: the carrier is on
# every board, so its sender is relaxed on every board and the invariant would
# otherwise fail on the plain one.
lappend inside u_dbg_cable
# **AND THE SOFT PROCESSING SYSTEM ITSELF, WHICH IS ASKED A DIFFERENT QUESTION
# RATHER THAN NOT ASKED.**  `assert_constraints_scoped` holds every register
# outside the machine to ONE PERIOD of the clock it is given, and the clock it
# is given is the machine's tick --- so a register on the soft system's slower
# clock reports its own longer period and would fail an assertion written about
# a clock it does not run on.  Excluding it here and leaving it at that would
# be an exemption too wide, which is the failure this repository records more
# often than any other, so `assert_soc_domain_timed` below asks the same
# question of those registers against THEIR OWN period.  Everything else in
# `g_soc` --- the three faces, which are the machine's neighbors --- stays in
# the list and is still held to the tick.
if {$soc != 0} { lappend inside g_soc.u_soc }
# **AND THIS CALL IS WEAKER THAN IT LOOKS WITH TWO CLOCKS IN THE DESIGN, WHICH
# IS MEASURED AND IS NOT THIS DIRECTORY'S TO FIX.**  `relaxed_outside` asks for
# the WORST 400 paths by slack and holds every one of them to one period of the
# single clock it is handed --- and a design with a second clock has healthy
# paths asking for that clock's longer period.  The instance filter above is
# what keeps the soft system out of the question, and **synthesis can flatten a
# cell's name out of the hierarchy and past that filter**: at a 62.5 MHz soft
# clock this assertion stopped the run naming `rdata_q_reg[31]_i_4/D` at
# 16.000 ns, which is Ibex's own load-store unit, both ends on the soft clock,
# one period of it, +5.922 ns of slack.  A false accusation of the `foreach`
# bug this check exists to catch.
#
# At the 50 MHz this board builds, the same flattened path has about ten
# nanoseconds of slack and does not make the worst-400 cut, so the call passes
# --- which is the query's limit and not evidence that no such path exists.
# **AND THE 62.5 MHz DESIGN ITSELF CLOSES**, +0.846 ns on 0 of 46,441 when the
# assertion is made to print instead of exit, so what stops that build is this
# check and not the fabric.  `README.md` has both columns and the reason the
# board builds at 50 anyway.
# The fix is in `boards/arty-z7-20/vivado/constraints_check.tcl`: hold each
# path to ITS OWN capture clock's period, and stop taking only the worst 400.
# That file is read by three boards' flows and changing it is a commit that
# touches all of them.  `assert_soc_domain_timed` below is the question asked
# the right way round for the one domain this slice added.
assert_constraints_scoped $inside $tick

# --- THE SOFT SYSTEM'S CLOCK AND ITS CROSSING, ASKED OF THE DESIGN
#
# Three questions, and every one of them has a silent failure behind it that
# this project has already met.  Is there a second clock at all --- a pattern
# that stopped matching leaves `cadr_soc.xdc` reaching nothing and the crossing
# timed against whatever requirement two unrelated edges happen to make.  Did
# the bound reach any PATH --- an exception that was created and applied to
# nothing still appears in `report_exceptions`, which is the `foreach` trap
# exactly.  And is anything in the soft system taking a multicycle it was not
# given --- which is the disk controller's 3,904 of 4,000 paths, met in a new
# module.
proc assert_soc_domain_timed {instance period} {
    set cells [get_cells -quiet -hier -filter \
                   "PRIMITIVE_GROUP == FLOP_LATCH && NAME =~ ${instance}/*"]
    if {[llength $cells] == 0} {
        puts "XDC: FAILED --- no registers matched $instance, so the soft"
        puts "XDC: processing system was optimized away or renamed. Either is"
        puts "XDC: a finding and neither is a pass."
        exit 1
    }
    set pins [get_pins -quiet -of_objects $cells -filter {REF_PIN_NAME == D}]
    set caught 0
    foreach req [get_property -quiet REQUIREMENT \
                     [get_timing_paths -quiet -setup -to $pins \
                          -max_paths 100000 -nworst 1]] {
        if {$req > [expr {$period * 1.5}]} { incr caught }
    }
    if {$caught > 0} {
        puts "XDC: FAILED --- $caught path(s) into $instance ask for more than"
        puts "XDC: one and a half of that domain's own [format %.3f $period] ns"
        puts "XDC: period. The soft system has no multicycle exception of any"
        puts "XDC: kind and is not entitled to one; a relaxed set defined as"
        puts "XDC: every register minus a name list swallows whatever lands"
        puts "XDC: inside it, which is what this asks about."
        exit 1
    }
    puts "XDC: $instance --- [llength $cells] registers, none asking for more"
    puts "XDC: than its own [format %.3f $period] ns period"
}

if {$soc != 0} {
    set soft_clk [get_clocks -quiet -of_objects \
                      [get_pins -hier -filter {NAME =~ *u_mmcm/CLKOUT2}]]
    set mach_clk [get_clocks -quiet -of_objects \
                      [get_pins -hier -filter {NAME =~ *u_mmcm/CLKOUT0}]]
    if {[llength $soft_clk] != 1 || [llength $mach_clk] != 1} {
        puts "BIT: FAILED --- the machine has [llength $mach_clk] clock(s) and"
        puts "BIT: the soft processing system [llength $soft_clk]. One each is"
        puts "BIT: wanted; a name pattern here has stopped matching and every"
        puts "BIT: crossing constraint in cadr_soc.xdc reaches nothing, which"
        puts "BIT: leaves the two domains timed against whatever requirement"
        puts "BIT: their edges happen to make."
        exit 1
    }
    set soft_ns [get_property PERIOD $soft_clk]
    puts "BIT: the machine's clock is [get_property NAME $mach_clk] at\
 [format %.3f [get_property PERIOD $mach_clk]] ns"
    puts "BIT: the soft system's is [get_property NAME $soft_clk] at\
 [format %.3f $soft_ns] ns ([format %.2f [expr {1000.0 / $soft_ns}]] MHz)"

    # **THE BOUND MUST REACH PATHS IN BOTH DIRECTIONS AND THE COUNT IS WHAT
    # SAYS SO.**  One direction carries the request and its payload, the other
    # the acknowledgment and its answer; a crossing with traffic one way only
    # is a crossing half of which is unconstrained.
    set want [format %.3f $tick]
    foreach pair [list [list $soft_clk $mach_clk "the request and its payload"] \
                       [list $mach_clk $soft_clk "the answer coming back"]] {
        set from [lindex $pair 0]
        set to   [lindex $pair 1]
        set what [lindex $pair 2]
        set reqs [get_property -quiet REQUIREMENT \
                      [get_timing_paths -quiet -setup -from $from -to $to \
                           -max_paths 100000 -nworst 1]]
        set n 0
        set bad 0
        foreach r $reqs {
            incr n
            if {[format %.3f $r] ne $want} { incr bad }
        }
        if {$n == 0} {
            puts "BIT: FAILED --- no path at all runs from\
 [get_property NAME $from] to [get_property NAME $to] ($what)."
            puts "BIT: Either the crossing was optimized away or the two"
            puts "BIT: clocks are not the ones cadr_soc.xdc named. An"
            puts "BIT: exception that reaches no path is the failure that"
            puts "BIT: looks exactly like a build that finished."
            exit 1
        }
        if {$bad > 0} {
            puts "BIT: FAILED --- $bad of $n path(s) from\
 [get_property NAME $from] to [get_property NAME $to] ($what)"
            puts "BIT: do not ask for $want ns, so the maximum delay in"
            puts "BIT: cadr_soc.xdc did not reach them and they are being"
            puts "BIT: timed against whatever requirement the two clocks'"
            puts "BIT: edges happen to make."
            exit 1
        }
        puts "BIT: $n path(s) cross for $what, every one bounded at $want ns"
    }

    assert_soc_domain_timed g_soc.u_soc $soft_ns
}

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

# And the debug cable's four ticks, the two halves the other boards' flows
# assert and for the same reasons.  The instance assertion is the narrow half
# --- the carrier's two frame registers may carry it and no other register of
# it may, because a counter given four ticks to settle is a counter that no
# longer counts --- and the count is the `foreach` half, that the exception
# reached a path at all.
assert_instance_timing $tick 6 *u_dbg_cable/* {*tx_frame_reg* *tx_d_reg*}

# And the carrier's deadline against the carrier's own beat, read out of the
# source rather than remembered here. Pure Tcl and no design, so it runs
# before anything is elaborated and fails naming both files.
assert_cable_beat rtl/plumbing/cadr_dbg_tx.sv rtl/plumbing/xilinx7/cadr_debug_pmod.xdc
assert_multicycle_applied $tick 6

# AND THE TWO CLAUSES `cadr_machine.xdc` ADDED FOR THE SLAVES INSIDE THE
# MACHINE, held the same two ways: the instance half says no OTHER register
# of the block may carry the requirement, and the proc's own empty clause
# says at least one of the named ones must. The display board takes the
# master's word at the first tick of -XBUS.RQ, which the bus rule owes
# sixteen ticks of settling; the bus interface's own block takes it at the
# register strobe, thirty ticks after -UB MSYN. Neither clause touches a
# clock enable, and these assertions are what says so.
assert_instance_timing $tick 16 *u_machine/memory/tv/* {*color_map_reg* *pointer_reg*}
assert_instance_timing $tick 30 *u_machine/memory/busint_regs/* \
    {*wr_buf_reg* *ub_map_reg*}

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
# THESE THREE ARE CELL COUNTS AND NOT THE UTILIZATION REPORT'S, and the two do
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
    puts "BIT: Something upstream has optimized the datapath away, which"
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
        # **AND WHERE, NOT MERELY HOW MUCH.**  A worst-slack figure names one
        # path and says nothing about how many others are wrong or which part
        # of the design they are in, and this repository has spent slices on
        # exactly that gap --- a fit figure for a module nobody was timing, a
        # slack figure whose whole total was one endpoint.  So when the design
        # does not close, the failing endpoints are counted by the top-level
        # instance they end in.  It is the first question anybody asks and it
        # costs one query.
        set fails [get_timing_paths -quiet -max_paths 20000 -nworst 1 \
                       -slack_lesser_than 0 -delay_type max]
        if {[llength $fails]} {
            array unset where
            foreach path $fails {
                set pin [get_property NAME [get_property ENDPOINT_PIN $path]]
                set top [lindex [split $pin /] 0]
                if {[info exists where($top)]} {
                    incr where($top)
                } else {
                    set where($top) 1
                }
            }
            puts "BIT: [llength $fails] failing endpoint(s), by where they end:"
            foreach top [lsort [array names where]] {
                puts "BIT:   [format %6d $where($top)]  $top"
            }
        }
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
if {![build_stamp_stamped "BIT:" $bit $stamp]} { exit 1 }
puts "BIT: wrote $bit, $size bytes"
puts "BIT: part $part, reports in $outdir"
