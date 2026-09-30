# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# How long is a tick?  One answer, read out of the RTL that decides it.
#
# `boards/arty-z7-20/cadr_arty.sv` instantiates one `MMCME2_BASE` and its four
# parameters are the whole of the machine's clock: the board crystal's period,
# the input divider, the feedback multiplier and the output divider.  That
# arithmetic is the tick, and **this file is the only other place in the
# repository allowed to know it** --- `fit.tcl` writes its `create_clock` from
# what this returns, and both flows hand the same number to
# `constraints_check.tcl`'s assertions.
#
# WHY IT IS PARSED AND NOT DECLARED.  A period written a second time in a Tcl
# script is a period that can disagree with the fabric, and every failure of
# that shape this project has met has been silent.  `assert_multicycle_applied`
# matches the relaxed setup requirement **as a formatted string**: a script
# still asking for 75.000 ns against a design timed at 10 ns finds no path at
# that requirement and fails saying the constraints applied to NOTHING --- a
# false accusation of the exact bug (the `foreach` an XDC rejects) that
# assertion exists to catch, and the reader would go looking at `cadr_machine.xdc`.
# `fit.tcl` is worse, because there the stale number does not fail at all: the
# out-of-context flow declares its own clock, so it would go on reporting for
# ever what the machine costs at a tick nobody builds.  Parsing is what makes
# both impossible.
#
# AND IT FAILS LOUDLY RATHER THAN DEFAULTING.  There is no fallback period
# here on purpose.  A default that is right today is the
# two-ways-to-invoke-one-file trap rebuilt: the flow keeps working after the
# RTL moves, and reports a design nobody meant to build.  If the parse cannot
# find exactly one of each parameter, the run stops and names the file.
#
# WHAT IT DOES NOT DO is check that the VCO is legal or that the tick divides
# anything.  Vivado checks the first itself --- an `MMCME2_BASE` outside 600 to
# 1200 MHz on a -1 part is a synthesis error --- and the second is not a
# constraint on this number at all: `cadr_phase_gen.sv`'s `TICK_NS` is 5 for
# ever, being the conversion from MIT's drawings into TICK COUNTS, and how long
# a tick then lasts is this file's business and nothing else's.

# The machine's tick, in nanoseconds, as `cadr_arty.sv` builds it.
proc cadr_tick_ns {{file "boards/arty-z7-20/cadr_arty.sv"}} {
    if {![file exists $file]} {
        puts "TICK: FAILED --- $file does not exist, so the period the"
        puts "TICK: constraints are written against cannot be read from the"
        puts "TICK: fabric that sets it. Run from the repository root."
        exit 1
    }
    set fh [open $file r]
    set text [read $fh]
    close $fh

    # One value each, and exactly one: a second MMCM in this file would make
    # "the tick" ambiguous, and the honest answer to an ambiguous question is
    # to stop.
    array set got {}
    foreach {name pattern} {
        CLKIN1_PERIOD    {\.CLKIN1_PERIOD\s*\(\s*([0-9]+\.?[0-9]*)\s*\)}
        DIVCLK_DIVIDE    {\.DIVCLK_DIVIDE\s*\(\s*([0-9]+\.?[0-9]*)\s*\)}
        CLKFBOUT_MULT_F  {\.CLKFBOUT_MULT_F\s*\(\s*([0-9]+\.?[0-9]*)\s*\)}
        CLKOUT0_DIVIDE_F {\.CLKOUT0_DIVIDE_F\s*\(\s*([0-9]+\.?[0-9]*)\s*\)}
    } {
        set hits [regexp -all -inline $pattern $text]
        # `regexp -all -inline` returns the whole match and then the capture
        # for each occurrence, so a list of two is one occurrence.
        if {[llength $hits] != 2} {
            puts "TICK: FAILED --- $file names $name\
                  [expr {[llength $hits] / 2}] time(s); exactly one is wanted."
            puts "TICK: The machine's clock is that one MMCME2_BASE and this"
            puts "TICK: script is how the constraints learn its period. A"
            puts "TICK: parameter that has been renamed, reformatted onto two"
            puts "TICK: lines, or given a second instance has to be settled"
            puts "TICK: here before any flow can say what it is building."
            exit 1
        }
        set got($name) [lindex $hits 1]
    }

    if {$got(CLKFBOUT_MULT_F) <= 0 || $got(DIVCLK_DIVIDE) <= 0 ||
        $got(CLKIN1_PERIOD) <= 0 || $got(CLKOUT0_DIVIDE_F) <= 0} {
        puts "TICK: FAILED --- a clock parameter in $file is zero or negative."
        exit 1
    }

    # The primitive's own arithmetic: VCO = CLKIN1 / DIVCLK_DIVIDE *
    # CLKFBOUT_MULT_F, and CLKOUT0 = VCO / CLKOUT0_DIVIDE_F, so in periods it
    # is one expression. With the VCO at 1000 MHz the output divider happens to
    # BE the tick in nanoseconds --- which is a convenience for a reader and
    # not an assumption made here.
    set tick [expr {double($got(CLKIN1_PERIOD)) * double($got(DIVCLK_DIVIDE))
                    * double($got(CLKOUT0_DIVIDE_F)) / double($got(CLKFBOUT_MULT_F))}]

    set vco [expr {1000.0 * double($got(CLKFBOUT_MULT_F))
                   / (double($got(CLKIN1_PERIOD)) * double($got(DIVCLK_DIVIDE)))}]
    puts [format "TICK: %s: %g MHz in, VCO %g MHz, one tick = %.3f ns (%.3f MHz)" \
              $file [expr {1000.0 / double($got(CLKIN1_PERIOD))}] $vco \
              $tick [expr {1000.0 / $tick}]]
    return $tick
}

# And how many ticks is QUUX's microcycle?  The same file's answer, for the
# same reason: `cadr_arty.sv` hands the machine `SYNC_K` to revision 12 and
# `SYNC_K13` at revision 13, and `quux_machine.xdc` writes every one of its
# counts from the `sync_k` the flow takes from here before it reads that
# file.  A K written a second time in the flow is a K that can disagree with
# the machine: a constraint a tick longer than the microcycle is a path the
# fit calls met that the fabric does not.  `build/machine_param.pass` holds
# this answer against each revision's own K.
proc cadr_sync_k {word_bits {file "boards/arty-z7-20/cadr_arty.sv"}} {
    if {$word_bits ne "32" && $word_bits ne "40"} {
        puts "TICK: FAILED --- WORD_BITS=$word_bits has no K; it is 32, or 40 for revision 13."
        exit 1
    }
    set name [expr {$word_bits eq "40" ? "SYNC_K13" : "SYNC_K"}]
    set fh [open $file r]
    set text [read $fh]
    close $fh
    set hits [regexp -all -inline -line \
        "^\\s*parameter\\s+int\\s+unsigned\\s+$name\\s*=\\s*(\\d+)\\s*,?\\s*$" $text]
    if {[llength $hits] != 2} {
        puts "TICK: FAILED --- $file states $name [expr {[llength $hits] / 2}] time(s);\
              exactly one is wanted."
        exit 1
    }
    set k [lindex $hits 1]
    puts "TICK: $file: QUUX's microcycle at WORD_BITS=$word_bits is $name = $k ticks"
    return $k
}
