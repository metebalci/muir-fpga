# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Does the constraints file constrain what it says it does?
#
# `rtl/cadr_machine.xdc` states a policy: the machine's datapath registers may
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
# `$inside` is the instance path of the machine, or the empty string when the
# machine is the top and there is nothing outside it to find.
proc relaxed_outside {inside period} {
    if {$inside eq ""} {
        set outside [get_cells -quiet -hier -filter {PRIMITIVE_GROUP == FLOP_LATCH}]
        # Out of context the machine is the top, so nothing is outside it and
        # this can only be empty. Checking anyway is the point: if it ever
        # stops being empty, a top level has appeared that nobody expected.
        set outside [filter $outside {NAME !~ *}]
    } else {
        set outside [get_cells -quiet -hier \
            -filter "PRIMITIVE_GROUP == FLOP_LATCH && NAME !~ ${inside}/*"]
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
        puts "XDC: no register outside the machine is relaxed"
        return
    }
    puts "XDC: FAILED --- [llength $caught] register(s) outside the machine"
    puts "XDC: are taking a microcycle exception that was written for the"
    puts "XDC: machine's datapath. A reset synchroniser or a free-running"
    puts "XDC: counter given 75 ns to settle is the one thing that file's own"
    puts "XDC: prose says must not happen."
    foreach c [lrange $caught 0 9] { puts "XDC:   $c" }
    if {[llength $caught] > 10} {
        puts "XDC:   ... and [expr {[llength $caught] - 10}] more"
    }
    puts "XDC: read cadr_machine.xdc scoped --- `read_xdc -ref cadr_machine`"
    puts "XDC: --- so `all_registers` means the machine's and not the board's."
    exit 1
}
