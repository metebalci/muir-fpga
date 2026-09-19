# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# PICK A JTAG TARGET BY ITS CABLE SERIAL, NEVER BY POSITION.
#
# Sourced by `program.tcl` and `probe.tcl`, the two flows that reach a board
# through Vivado's hardware manager (`get_hw_targets`, `current_hw_target`).
# `boards/arty-z7-20/vivado/ddr_check.tcl` picks a target the same way against
# xsdb's own `targets` command, which is a different tool with a different
# command set, so that file's selection is not reachable from here; this is
# the same reasoning as its own, moved to Vivado's API.
#
# JTAG_SERIAL in the environment wins, so a run can name a board without
# editing anything. Otherwise the serial is read from a `local.conf` beside
# the board, which is gitignored: a cable serial identifies one physical
# board the way its MAC address does, and this repository is public.
#
# With no serial at all and exactly one target attached, that target is used
# and the run goes ahead as it always has. With no serial and more than one
# target, the run refuses and names every target's own serial, because
# guessing would run against whichever target enumerated first, and that
# order is not ours to choose. A serial that matches nothing, or matches more
# than one target, also refuses.

# `local.conf` is a shell file of KEY=VALUE lines, and this reads one key out
# of it without running it. A file that is not there is not an error: it
# means no serial, which is allowed when one target is attached.
proc jtag_local_conf_serial {path} {
    if {![file readable $path]} {
        return ""
    }
    set fh [open $path]
    set text [read $fh]
    close $fh
    foreach line [split $text "\n"] {
        if {[regexp {^[ \t]*JTAG_SERIAL[ \t]*=[ \t]*\"?([A-Za-z0-9]+)} $line -> s]} {
            return $s
        }
    }
    return ""
}

# The serial to select by, and where it came from, for the message that
# names it. The environment is checked first, so a run can name a board
# without editing anything.
proc jtag_serial_and_source {board_dir} {
    if {[info exists ::env(JTAG_SERIAL)] && $::env(JTAG_SERIAL) ne ""} {
        return [list $::env(JTAG_SERIAL) "JTAG_SERIAL in the environment"]
    }
    set s [jtag_local_conf_serial "$board_dir/linux/local.conf"]
    return [list $s "$board_dir/linux/local.conf"]
}

# The last path element of a target's NAME, which is where every cable this
# project has met (Digilent's `xilinx_tcf` transport included) puts the
# serial. Used only for the messages below; selection itself matches the
# serial against the whole NAME, so a serial recorded without a trailing
# letter the cable itself reports still matches.
proc jtag_target_label {name} {
    if {[regexp {/([^/]+)$} $name -> tail]} {
        return $tail
    }
    return $name
}

# Selects one hw_target object, by cable serial when one is given and by
# being the only target attached when none is. `tag` prefixes every message
# this prints (`"PROG:"`, `"PROBE:"`), matching the rest of each flow's own
# output.
#
# Returns `{1 <target>}` on success. On refusal it returns `{0 <lines>}`,
# a list of the message lines to print, and never exits itself: `program.tcl`
# exits bare on every other failure, while `probe.tcl` closes the hardware
# target and manager first through its own `probe_fail`, and this is called
# before either has opened anything, so the choice of how to leave is the
# caller's.
proc jtag_select_hw_target {tag board_dir} {
    lassign [jtag_serial_and_source $board_dir] serial serial_from

    set all [get_hw_targets -quiet]
    set names {}
    foreach t $all { lappend names [get_property NAME $t] }

    if {$serial eq ""} {
        # Both callers already refuse on zero targets before this is reached
        # (they name the udev rules, which this has no way to). Guarded here
        # too, so nothing downstream is ever handed an empty target.
        if {[llength $all] == 0} {
            return [list 0 [list "$tag FAILED --- no JTAG targets are attached."]]
        }
        if {[llength $all] > 1} {
            set lines {}
            lappend lines "$tag FAILED --- [llength $all] JTAG targets are attached and nothing"
            lappend lines "$tag   says which of them this run is for. Their cable serials:"
            foreach n $names {
                lappend lines "$tag     [jtag_target_label $n]"
            }
            lappend lines "$tag   Set JTAG_SERIAL, or put a JTAG_SERIAL line in"
            lappend lines "$tag   $board_dir/linux/local.conf, which is gitignored."
            lappend lines "$tag   Guessing would run against whichever target enumerated"
            lappend lines "$tag   first, and that order is not ours to choose."
            return [list 0 $lines]
        }
        set only [lindex $all 0]
        puts "$tag no cable serial was given and one target is attached, so it\
 is that one: [jtag_target_label [get_property NAME $only]]"
        return [list 1 $only]
    }

    puts "$tag selecting by cable serial, from $serial_from"
    # A wildcard on both sides: the serial recorded in `local.conf` can be a
    # prefix of what the cable itself reports, as `ddr_check.tcl` notes for
    # the same reason.
    set chosen [get_hw_targets -quiet "*$serial*"]
    if {[llength $chosen] != 1} {
        set lines {}
        lappend lines "$tag FAILED --- [llength $chosen] targets match cable serial $serial."
        lappend lines "$tag   The targets attached are: [join [lmap n $names {jtag_target_label $n}] {, }]"
        return [list 0 $lines]
    }
    set target [lindex $chosen 0]
    puts "$tag selected [jtag_target_label [get_property NAME $target]]"
    return [list 1 $target]
}
