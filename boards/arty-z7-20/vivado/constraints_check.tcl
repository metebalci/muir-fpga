# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Does the constraints file constrain what it says it does?
#
# `rtl/plumbing/xilinx7/cadr_machine.xdc` states a policy: the machine's datapath registers may
# take a microcycle, the ring counter and the free-running counters and the
# edge detectors may not. Nothing has ever checked that the policy is what
# arrived. Four defects in that file, and **every one of them was silent** ---
# a `foreach` an XDC rejects, applying to nothing; a `create_clock` on a port
# that does not exist in a board flow; a relaxation reaching registers that
# were not there when it was written. None of them errored, and two of them
# produced a plausible number instead.
#
# Everything else in this repository is checked by something: the fabric by
# the checks, the checks by the mutation list, the runner by its self-test.
# This is the missing member of that set. **a9 owns the policy; this asserts
# that the policy did what it says.**
#
# It asserts an INVARIANT AND NOT A COUNT, deliberately. "No register outside
# the machine is relaxed" stays true when somebody adds a flip-flop; "1,829
# registers are relaxed" becomes a maintenance burden the first time they do,
# and a check that has to be edited to stay true is a check people edit
# rather than read.
#
# It asks the design rather than re-reading the policy. Recomputing the
# exclusion list here would make two copies of it, and they would agree until
# they did not --- which is the shape of every staleness problem this project
# has had.

# Registers whose setup requirement is longer than one clock period, among
# those NOT inside `$inside`. Empty is the healthy answer.
#
# `$inside` is a LIST of instance paths that may carry the relaxation --- the
# machine, and whatever else has been given it deliberately --- or the empty
# list when the machine is the top and there is nothing outside it to find.
# One path is still one path; a list of one behaves exactly as it always did.
#
# IT BECAME A LIST WHEN THE PROBE ARRIVED, and the alternative would have
# been worse. `rtl/plumbing/xilinx7/cadr_probe.sv` holds the machine's *combinational*
# outputs --- the A and M buses, the ALU, the sequencing flags --- for a tick,
# and those settle inside a microcycle and not inside one tick: the first
# instrumented board came out at -13.156 ns on 2,400 endpoints because of it.
# So `boards/arty-z7-20/cadr_probe.xdc` relaxes that one register, on the same argument
# the machine makes for its own, and the invariant here is unchanged: nothing
# *else* may take it. The other way to make this pass would have been to
# widen the check, and a check widened to admit one thing stops catching the
# reset synchroniser it was written for.
proc relaxed_outside {inside period} {
    if {[llength $inside] == 0} {
        set outside [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]
        # Out of context the machine is the top, so nothing is outside it and
        # this can only be empty. Checking anyway is the point: if it ever
        # stops being empty, a top level has appeared that nobody expected.
        set outside [filter $outside {NAME !~ *}]
    } else {
        set want "PRIMITIVE_GROUP == FLOP_LATCH"
        foreach path $inside { append want " && NAME !~ ${path}/*" }
        set outside [get_cells -quiet -hier -filter $want]
    }
    if {[llength $outside] == 0} { return {} }

    set caught {}
    foreach path [get_timing_paths -quiet -to $outside -max_paths 400 \
                                   -delay_type max -nworst 1] {
        set req [get_property REQUIREMENT $path]
        # A tick of tolerance for floating point, not for policy: anything a
        # whole period beyond one period is a multicycle that reached here.
        if {$req > [expr {$period * 1.5}]} {
            lappend caught [format "%s (requirement %.3f ns)" \
                            [get_property NAME [get_property ENDPOINT_PIN $path]] $req]
        }
    }
    return $caught
}

# Fails the run, loudly, naming what it found.
proc assert_constraints_scoped {inside period} {
    set caught [relaxed_outside $inside $period]
    if {[llength $caught] == 0} {
        if {[llength $inside] <= 1} {
            puts "XDC: no register outside the machine is relaxed"
        } else {
            puts "XDC: no register outside [join $inside {, }] is relaxed"
        }
        return
    }
    puts "XDC: FAILED --- [llength $caught] register(s) outside [join $inside {, }]"
    puts "XDC: are taking a microcycle exception that was written for the"
    puts "XDC: machine's datapath. A reset synchroniser or a free-running"
    puts "XDC: counter given a whole microcycle to settle is the one thing"
    puts "XDC: that file's own prose says must not happen."
    foreach c [lrange $caught 0 9] { puts "XDC:   $c" }
    if {[llength $caught] > 10} {
        puts "XDC:   ... and [expr {[llength $caught] - 10}] more"
    }
    puts "XDC: read cadr_machine.xdc scoped --- `read_xdc -ref cadr_machine`"
    puts "XDC: --- so `all_registers` means the machine's and not the board's."
    exit 1
}

# Did the exceptions reach any path at all?
#
# THIS ASKS THE PATHS AND NOT THE EXCEPTION OBJECTS, and the difference is the
# whole reason the file exists. `report_exceptions` lists what was *created*:
# a `set_multicycle_path -from {} -to {}` whose object queries matched nothing
# still appears there, with its `cycles=15`, because the statement was read and
# an exception was made. That is the `foreach` bug exactly --- the file read
# cleanly, the report showed the exception, and the design was timed
# unconstrained at -16.405 ns, against -0.484 ns for the constrained design at
# 712909e. Counting exception objects cannot tell those two apart. The setup
# REQUIREMENT of the paths can: an exception that reached nothing leaves every
# path in the design asking for one period.
#
# So: `cycles` periods is what a relaxed path must report, and a count of zero
# at that requirement is the failure. It is a floor and not an equality,
# because the number of paths in the family moves whenever the datapath does,
# and moves again between synthesis and routing: at 712909e it is 10,972 out
# of context and 10,929 on the board where this check runs, and 10,956 on the
# board's routed design. A check that has to be edited to stay true is a check
# people edit rather than read.
#
# `-nworst 1` is one path per endpoint, which is what makes this affordable:
# 14,135 paths came back in 2.7 s on the board's post-route design, and their
# requirements in 43 ms more.
#
# **AND THE LIMIT IS NOT A TUNING KNOB, IT IS A CORRECTNESS HAZARD, MEASURED.**
# `get_timing_paths` hands back the WORST slack first and a relaxed path has
# fifteen periods of slack, so a query that hits its limit drops exactly the
# paths this counts.  At 40,000 that stopped being theoretical the moment the
# transaction audit was instantiated: the `DDR=1` board went from 39,397
# endpoints to over 40,000, the query truncated, and
# `assert_multicycle_applied $tick 16` --- the memory port's own 160 ns
# contract, whose paths have the most slack of all --- reported that
# `cadr_machine.xdc` had "applied to NO PATH" on a design where it had applied
# perfectly.  That is a false accusation of the `foreach` bug this check exists
# to catch, which is the one failure a check must never make.  The limit is
# 100,000 now, and the truncated case is a failure of its own with its own
# words rather than a note above somebody else's.
proc relaxed_path_histogram {limit} {
    set hist {}
    foreach req [get_property -quiet REQUIREMENT \
                     [get_timing_paths -quiet -setup -max_paths $limit -nworst 1]] {
        dict incr hist [format %.3f $req]
    }
    return $hist
}

# **AND THE QUESTION THE AGGREGATE COUNT CANNOT ANSWER: WHICH SET DID A NEW
# MODULE'S REGISTERS FALL INTO?**
#
# `rtl/plumbing/xilinx7/cadr_machine.xdc` defines `slow` as every register
# under `cadr_machine` less a name list, so ANY module instantiated there is
# relaxed to fifteen ticks by default and nothing says so.  That is not a
# hypothetical: `cadr_disk_controller.sv` landed with none of its registers
# named and **3,904 of its 4,000 internal paths carried the exception**, the
# longest 20.1 ns, and three slices quoted fit figures for a disk nobody was
# timing.  It was found by asking the routed checkpoint which paths carried the
# exception, not by any report reading red --- and that question is what this
# proc is.
#
# The assertion is deliberately the ONE DIRECTION THAT IS TRUE.  A relaxed
# register's paths are relaxed only when BOTH ends are in `slow`, so "every
# path to a named capture register asks for fifteen ticks" is FALSE by
# construction --- a capture register's data comes from fast counters as well
# --- and a check written that way would fail on a healthy design.  What holds
# is the other way round:
#
#   no path ending at a register the clause meant to keep FAST may ask for the
#   relaxed requirement, which is the swallowing above; and
#
#   at least one path ending at a register the clause meant to RELAX must ask
#   for it, which is the `foreach` trap --- a clause that matched nothing
#   leaves every figure looking plausible.
#
# `fast` and `relaxed` are lists of name patterns under the instance.  An
# instance that has no registers at all fails: a module optimised away is a
# finding and not a pass.
proc assert_instance_timing {period cycles instance relaxed} {
    set want [format %.3f [expr {$period * $cycles}]]
    set all [get_cells -quiet -hier -filter \
                 "NAME =~ $instance && PRIMITIVE_GROUP == FLOP_LATCH"]
    if {[llength $all] == 0} {
        puts "XDC: FAILED --- no registers matched $instance."
        puts "XDC: Either the instance was renamed, in which case the clause"
        puts "XDC: in cadr_machine.xdc that names it is empty and every"
        puts "XDC: register under it is relaxed in silence, or the module was"
        puts "XDC: optimised away, which is a finding of its own."
        exit 1
    }
    set fast {}
    set slow {}
    foreach cell $all {
        set name [get_property NAME $cell]
        set is_slow 0
        foreach pat $relaxed {
            if {[string match $pat $name]} { set is_slow 1 }
        }
        if {$is_slow} { lappend slow $cell } else { lappend fast $cell }
    }
    puts "XDC: $instance --- [llength $all] registers,\
          [llength $fast] meant fast, [llength $slow] meant relaxed"

    # THE SWALLOWING.  Every path ending at a register meant to be fast, one
    # per endpoint, and not one of them may carry the relaxed requirement.
    set swallowed 0
    if {[llength $fast] > 0} {
        set pins [get_pins -quiet -of_objects $fast -filter {REF_PIN_NAME == D}]
        foreach req [get_property -quiet REQUIREMENT \
                         [get_timing_paths -quiet -setup -to $pins \
                              -max_paths 100000 -nworst 1]] {
            if {[format %.3f $req] eq $want} { incr swallowed }
        }
    }
    if {$swallowed > 0} {
        puts "XDC: FAILED --- $swallowed paths into registers of $instance"
        puts "XDC: that must be timed at one tick ask for $want ns instead."
        puts "XDC: They were swallowed by cadr_machine.xdc's relaxed set,"
        puts "XDC: which is every register under the machine less a name"
        puts "XDC: list --- the disk controller's 3,904 of 4,000, met again."
        puts "XDC: Every slack figure this run would print is of a design"
        puts "XDC: that is not the one being built."
        exit 1
    }

    # THE EMPTY CLAUSE.  At least one path into the registers that were meant
    # to be relaxed must actually be.
    set kept 0
    if {[llength $slow] > 0} {
        set pins [get_pins -quiet -of_objects $slow -filter {REF_PIN_NAME == D}]
        foreach req [get_property -quiet REQUIREMENT \
                         [get_timing_paths -quiet -setup -to $pins \
                              -max_paths 100000 -nworst 1]] {
            if {[format %.3f $req] eq $want} { incr kept }
        }
        if {$kept == 0} {
            puts "XDC: FAILED --- not one path into the capture registers of"
            puts "XDC: $instance asks for $want ns, so the clause that names"
            puts "XDC: them reached nothing. Look for a renamed instance or a"
            puts "XDC: name pattern that stopped matching."
            exit 1
        }
    }
    puts "XDC: $instance --- 0 fast paths relaxed, $kept capture paths at\
          $want ns: the split took"
}

# Fails the run when no path carries the relaxed requirement.
proc assert_multicycle_applied {period cycles {limit 100000}} {
    set want [format %.3f [expr {$period * $cycles}]]
    set hist [relaxed_path_histogram $limit]
    set total 0
    dict for {k n} $hist { incr total $n }
    set relaxed [expr {[dict exists $hist $want] ? [dict get $hist $want] : 0}]
    if {$relaxed > 0} {
        if {$total >= $limit} {
            puts "XDC: NOTE --- the query returned its $limit-path limit, so"
            puts "XDC: the count below is of the worst $limit paths and not of"
            puts "XDC: the whole design. It is a floor and not a total."
        }
        puts "XDC: $relaxed of $total setup paths ask for $want ns --- the"
        puts "XDC: microcycle exception reached the design"
        return
    }
    # **THE TRUNCATED CASE IS A DIFFERENT FAILURE AND SAYS SO.**  The paths
    # this counts have the most slack in the design, so they are the first the
    # limit drops; reporting that as "the constraints reached no path" is the
    # false accusation the header above records.  An exit code cannot tell two
    # failures apart, so the words have to.
    if {$total >= $limit} {
        puts "XDC: FAILED --- the query returned its $limit-path limit and"
        puts "XDC: none of those $limit paths asks for $want ns. THIS IS MOST"
        puts "XDC: LIKELY THE LIMIT AND NOT THE CONSTRAINTS: relaxed paths"
        puts "XDC: carry the most slack in the design and are exactly the ones"
        puts "XDC: a truncated worst-first query drops. Raise the limit above"
        puts "XDC: the design's endpoint count and run again before believing"
        puts "XDC: anything else. Requirements seen, path count by requirement:"
        foreach k [lsort -real [dict keys $hist]] {
            puts "XDC:   $k ns : [dict get $hist $k]"
        }
        exit 1
    }
    puts "XDC: FAILED --- not one of $total setup paths asks for $want ns."
    puts "XDC: cadr_machine.xdc's multicycle set applied to NO PATH, so this"
    puts "XDC: design is being timed as if every datapath register had one"
    puts "XDC: [format %g $period] ns tick to settle in. That is the"
    puts "XDC: unconstrained design, and every slack figure a run like this"
    puts "XDC: prints is of a machine nobody meant to build --- -16.405 ns the"
    puts "XDC: last time it happened, against -0.484 constrained (712909e)."
    puts "XDC: The exceptions may still EXIST and be listed by"
    puts "XDC: report_exceptions; what they do not do is reach a path. Look"
    puts "XDC: for an XDC-illegal construct in the object query --- `foreach`"
    puts "XDC: and `concat` are rejected --- or a name pattern that stopped"
    puts "XDC: matching, or a missing clock."
    puts "XDC: setup requirements seen, path count by requirement:"
    foreach k [lsort -real [dict keys $hist]] {
        puts "XDC:   $k ns : [dict get $hist $k]"
    }
    exit 1
}
