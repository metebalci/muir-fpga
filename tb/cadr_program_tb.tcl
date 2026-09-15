# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The two `program.tcl`s, against a stubbed hardware manager, ten cases
# apiece, and three more on the flow's own end.  No Vivado, no cable and no
# part: `tclsh tb/cadr_program_tb.tcl`.
#
#     make build/program_tcl.pass
#
# WHY THIS EXISTS.  A programming script's verdict used to be the DONE bit
# alone, and DONE is high before the download on any part that was already
# configured.  So the witness read the same whether the configuration took or
# not, and on the Arty A7-100 three downloads in six did not take while the
# script reported that they had.  What found that was an identity read out of
# the design; the script itself could not have.
#
# The scripts now compare the build the part reads back over JTAG against the
# build the bitstream names.  `tools/build_stamp.tcl` holds both ends of that
# and the measurements behind it.
#
# WHAT THIS HOLDS THEM TO.  Not the exit code.  Two of these cases fail and
# two succeed with the same exit status as each other, and the whole point is
# which of the four happened --- a part that already held this build is not a
# download that took, and the scripts must not say it is.  So every case names
# the LINE the script must print, as `tb/cadr_probe_jtag_tb.tcl` does and for
# the same reason.
#
# WHAT IT DOES NOT HOLD THEM TO, and this is the half to read before quoting a
# green run:
#
#   NOT SILICON, AND NOT JTAG.  `REGISTER.USERCODE` is a stub here answering
#   what the case says.  That `BITSTREAM.CONFIG.USERID` really arrives in that
#   register on a configured part is read out of the parts' BSDL and Vivado's
#   own device tables, cited in `tools/build_stamp.tcl`, and **has not been
#   measured on a board by anything in this repository.**  The day it is, the
#   evidence is a board whose USERCODE equals the stamp its bitstream names.
#
#   NOT VIVADO.  `program_hw_devices` here sets two variables.  Whether the
#   real one can complete against a part that did not take the configuration
#   is not in question --- it has, three times in six --- but nothing here
#   reproduces the mechanism.
#
#   NOT `write_bitstream`.  That the flows set the property and that the
#   written file names it in its header was measured under Vivado on a trivial
#   design; this check reads a header it wrote itself.

set here [file dirname [file normalize [info script]]]
set repo [file normalize [file join $here ..]]

# The two scripts under test, resolved from THIS FILE and not from the working
# directory --- so the mutation runner, which runs the harness out of a copy
# of the tree, tests that copy's scripts and never the working tree's.
set SCRIPTS {
    {z7 {boards arty-z7-20 vivado program.tcl}  xc7z020_1}
    {a7 {boards arty-a7-100 vivado program.tcl} xc7a100t_0}
}

# ------------------------------------------------------------------ the model
#
#   done_before/after   the DONE bit either side of the download
#   code_before/after   what REGISTER.USERCODE reads either side
#   has_usercode        0 for a manager that has no such property here
#
# A device is a name and nothing else; the stubs answer from these.
array set ::model {
    done_before 1  done_after 1
    code_before ffffffff  code_after 4a585e10
    has_usercode 1
    device {}
    programmed 0
    marker {}
}

proc open_hw_manager {args} {}
proc connect_hw_server {args} {}
proc get_hw_targets {args} { return {localhost:3121/xilinx_tcf/Digilent/MODEL0000} }
proc current_hw_target {args} { return {localhost:3121/xilinx_tcf/Digilent/MODEL0000} }
proc open_hw_target {args} {}
proc close_hw_target {args} {}
proc close_hw_manager {args} {}
proc current_hw_device {args} {}
proc refresh_hw_device {args} {}
proc get_hw_devices {args} {
    # The chain as each board presents it.  `get_hw_devices <name>` filters,
    # which is how both scripts name their part rather than taking position 0.
    set all $::model(chain)
    foreach a $args {
        if {[string index $a 0] eq "-"} { continue }
        set hit {}
        foreach d $all { if {$d eq $a} { lappend hit $d } }
        return $hit
    }
    return $all
}

proc set_property {args} {}

proc program_hw_devices {args} {
    set ::model(programmed) 1
    # A marker on disk, because the case that must refuse before it opens
    # anything is checked from the parent process.
    if {$::model(marker) ne ""} {
        set fh [open $::model(marker) w] ; puts $fh "programmed" ; close $fh
    }
}

proc get_property {args} {
    set quiet 0
    set rest {}
    foreach a $args {
        if {$a eq "-quiet"} { set quiet 1 } else { lappend rest $a }
    }
    set prop [lindex $rest 0]
    switch -exact -- $prop {
        NAME    { return "localhost:3121/xilinx_tcf/Digilent/MODEL0000" }
        PART    { return "model" }
        REGISTER.IDCODE { return "13631093" }
        REGISTER.IR.BIT5_DONE {
            return [expr {$::model(programmed) ? $::model(done_after)
                                               : $::model(done_before)}]
        }
        REGISTER.USERCODE {
            if {!$::model(has_usercode)} {
                if {$quiet} { return "" }
                error "no such property"
            }
            # **NOT `expr`**, and this stub is where the defect it now tests
            # was reproduced a third time: eight hex digits whose fifth is
            # `e` are a Tcl float, so a ternary here handed the script
            # `8.108e+236` and `build_stamp_norm` refused it as unreadable.
            # A model that cannot present a legal value cannot test one.
            if {$::model(programmed)} { return $::model(code_after) }
            return $::model(code_before)
        }
    }
    return "model"
}

# ------------------------------------------------------------- a bitstream file
#
# The first bytes of a real `.bit` as Vivado writes them: a 13-byte preamble,
# then the design-name field `a` with its length, then the name --- which
# carries `;UserID=XXXXXXXX;` when the flow set one.  Measured on a bitstream
# written by Vivado 2026.1 for an xc7a100t, where the string begins 29 bytes
# in.  `build_stamp_of_bitstream` searches for it rather than seeking, so what
# matters here is that it is where a reader would find it and nowhere else in
# the file.
proc write_fake_bitstream {path userid} {
    set name "cadr_model"
    if {$userid ne ""} { append name ";UserID=$userid" }
    append name ";Version=2026.1;SW_CRC=00000000\x00"
    set fh [open $path w]
    fconfigure $fh -translation binary -encoding binary
    puts -nonewline $fh [binary format H* 00090ff00ff00ff00ff00000]
    puts -nonewline $fh "\x01a"
    puts -nonewline $fh [binary format S [string length $name]]
    puts -nonewline $fh $name
    # Enough body that the file is not obviously a header, and no ASCII in it.
    puts -nonewline $fh [string repeat [binary format H* 00ff00ff] 64]
    close $fh
}

# What `tools/build_stamp.tcl` would have written for a stamp's nibble.  The
# sidecar's commit and tree used to be two constants here, which made every
# case's `commit ... , tree ...` line the same sentence whatever the build
# was: a line that cannot differ is a line no case can be wrong about.
proc sidecar_tree_words {userid} {
    switch -- [string index $userid 7] {
        0 { return "clean" }
        1 { return "modified" }
        2 { return "untracked" }
        3 { return "modified and untracked" }
        f { return "git could not read the tree" }
    }
    return "clean"
}

proc write_sidecar {path userid commit tree} {
    set fh [open $path w]
    puts $fh "# a model sidecar"
    puts $fh "userid $userid"
    puts $fh "commit $commit"
    puts $fh "tree $tree"
    close $fh
}

# ------------------------------------------------------------------ the cases
#
# {name exit {header sidecar} {model settings} {lines}}
#
# `header` and `sidecar` are the build each names, or `-` for absent.  A case
# that must refuse BEFORE the hardware manager is opened says so with
# `no-program`, which is checked from the marker file rather than from a line.
#
# **THE LIST IS A TCL LIST AND HAS NO COMMENTS IN IT.**  A `#` line inside
# those braces is an element and not a remark, and one with a backtick in it
# stops the whole file parsing.  So what a case is for is said here.
#
# `float-shaped-build` and `float-shaped-usercode` are **a build that is also
# a floating-point literal**, which is every stamp whose fifth hex digit is
# `e` and whose others are decimal.  `8108e233` is a real commit of this
# repository with a dirty tree, and it is how the defect was found: a ternary
# in `expr` returned `8.108e+236`, the bitstream and its sidecar were declared
# to disagree, and a good file was refused before the hardware manager was
# even opened.  Tcl's `expr` converts and `if` does not.  There are two cases
# because two different readers touched such a value --- the one that compares
# the header with the sidecar, and the one that prints what the part read back
# --- which is why the second carries the shape in `code_before` as well.
set CASES {
    {fresh 0 {4a585e10 4a585e10}
        {code_before ffffffff code_after 4a585e10}
        {"PROG: this bitstream is build 4a585e10"
         "PROG:   commit 4a585e1, tree clean"
         "PROG: the part holds build 4a585e10 and held ffffffff before, so the"
         "PROG: download took."}}

    {again 0 {4a585e10 4a585e10}
        {code_before 4a585e10 code_after 4a585e10}
        {"PROG: the part holds build 4a585e10, and held it before this run too, so"
         "PROG: this cannot tell a download that took from one that did nothing."}}

    {did-not-take 1 {4a585e10 4a585e10}
        {code_before deadbee1 code_after deadbee1}
        {"PROG: FAILED --- the part reads back build deadbee1 where this bitstream"
         "PROG: is 4a585e10. It is holding something else, whatever"}}

    {overwritten 1 {4a585e10 4a585e10}
        {code_before 4a585e10 code_after deadbee1}
        {"PROG: FAILED --- the part reads back build deadbee1 where this bitstream"
         "PROG: is 4a585e10. It is holding something else, whatever"}}

    {no-stamp 0 {- -}
        {code_before ffffffff code_after ffffffff}
        {"PROG: this bitstream does not name the build it came from, so DONE"
         "PROG: is the only witness here"
         "PROG: programmed"}}

    {sidecar-only 0 {- 4a585e10}
        {code_before ffffffff code_after 4a585e10}
        {"PROG: this bitstream is build 4a585e10 by its sidecar; its own header names none."
         "PROG: the part holds build 4a585e10 and held ffffffff before, so the"}}

    {disagree 1 {4a585e10 deadbee1}
        {no-program 1}
        {"PROG: FAILED --- the bitstream names build 4a585e10 and its sidecar names deadbee1."
         "PROG: One of the two was copied without the other."}}

    {not-done 1 {4a585e10 4a585e10}
        {done_after 0 code_before ffffffff code_after 4a585e10}
        {"PROG: FAILED --- the device did not assert DONE."}}

    {no-usercode 0 {4a585e10 4a585e10}
        {has_usercode 0}
        {"PROG: the hardware manager gave no USERCODE for this device, so DONE"
         "PROG: is the only witness here."
         "PROG: programmed"}}

    {unreadable-before 0 {4a585e10 4a585e10}
        {code_before {} code_after 4a585e10}
        {"PROG: the part holds build 4a585e10; what it held before could not"
         "PROG: be read, so this does not say whether the download changed it."
         "PROG: programmed"}}

    {float-shaped-build 0 {8108e233 8108e233}
        {code_before ffffffff code_after 8108e233}
        {"PROG: this bitstream is build 8108e233"
         "PROG:   commit 8108e23, tree modified and untracked"
         "PROG: the part holds build 8108e233 and held ffffffff before, so the"
         "PROG: download took."}}

    {float-shaped-usercode 0 {8108e233 8108e233}
        {code_before 8108e233 code_after 8108e233}
        {"PROG: DONE before programming: 1, build 8108e233"
         "PROG: DONE after programming:  1, build 8108e233"
         "PROG: the part holds build 8108e233, and held it before this run too, so"}}
}

# ------------------------------------------------------------- a single case

if {[lindex $argv 0] eq "--case"} {
    lassign $argv _ which case outdir
    set script ""
    foreach spec $SCRIPTS {
        lassign $spec name path part
        if {$name eq $which} {
            set script [file join $repo {*}$path]
            break
        }
    }
    if {$script eq ""} { puts stderr "no such script: $which" ; exit 2 }
    # The chain each board presents: the Zynq's carries the ARM debug access
    # port beside the part, and the Artix is one device.  Both scripts name
    # their part rather than taking position 0, and this is what they name.
    set ::model(chain) [expr {$which eq "z7" ? [list $part arm_dap_0] : [list $part]}]

    foreach spec $CASES {
        lassign $spec name want_exit files settings lines
        if {$name ne $case} { continue }
        lassign $files header sidecar
        set bit [file join $outdir $which-$case.bit]
        # Not `expr`, for the reason the model's USERCODE gives: a ternary
        # turns a float-shaped build into a double and the header would then
        # name a build no reader could parse.
        set hdr ""
        if {$header ne "-"} { set hdr $header }
        write_fake_bitstream $bit $hdr
        file delete -force $bit.stamp
        if {$sidecar ne "-"} {
            write_sidecar $bit.stamp $sidecar [string range $sidecar 0 6] \
                [sidecar_tree_words $sidecar]
        }
        foreach {k v} $settings { if {$k ne "no-program"} { set ::model($k) $v } }
        set ::model(marker) [file join $outdir $which-$case.programmed]
        file delete -force $::model(marker)
        set ::env(BIT) $bit
        set ::env(BOARD_URL) "model"
        set ::env(CABLE) "MODEL0000"
        source $script
        exit 0
    }
    puts stderr "no such case: $case"
    exit 2
}

# ------------------------------------------------------- the writing half
#
# `build_stamp_stamped` and `build_stamp_of_tree` are the flow's end, and
# until this section nothing but a Vivado run exercised them.  A sidecar
# carrying a different number from the bitstream beside it would have been
# invisible, which is the whole failure this slice is about, one file along.
# These run in this process: there is no script to source and no exit to
# catch.
proc flow_cases {outdir} {
    # `$::repo` and not `info script`: inside a proc that is called rather than
    # sourced, what `info script` answers depends on how this file was reached.
    source [file join $::repo tools build_stamp.tcl]
    set bad {}

    # The stamp of the tree this is running in.  Not a fixed value --- it is
    # whatever the checkout says --- so what is held is its SHAPE, and the one
    # value it may never take.
    lassign [build_stamp_of_tree] id commit tree
    if {![regexp {^[0-9a-f]{8}$} $id]} {
        lappend bad "of-tree: `$id` is not eight hex digits"
    }
    if {[string index $id 7] ni {0 1 2 3 f}} {
        lappend bad "of-tree: `$id` ends `[string index $id 7]`, which is not a tree state"
    }
    if {$id eq "ffffffff"} {
        lappend bad "of-tree: gave ffffffff, which an unprogrammed part reads"
    }

    # A bitstream and a sidecar that agree.
    set bit [file join $outdir flow-agrees.bit]
    write_fake_bitstream $bit 4a585e10
    file delete -force $bit.stamp
    set out [flow_capture {build_stamp_stamped "BIT:" $bit {4a585e10 4a585e1 clean}} rc]
    if {!$rc} { lappend bad "agrees: refused a bitstream that names what was set" }
    if {[string first "BIT: build 4a585e10 --- commit 4a585e1, tree clean" $out] < 0} {
        lappend bad "agrees: never said which build it wrote"
    }
    lassign [build_stamp_read $bit] sid scommit stree
    if {$sid ne "4a585e10" || $scommit ne "4a585e1" || $stree ne "clean"} {
        lappend bad "agrees: the sidecar reads back `$sid $scommit $stree`"
    }

    # A bitstream that does not carry what the flow set.  The sidecar must not
    # be written: a file beside a wrong bitstream saying the right number is
    # one more thing to believe.
    set bit [file join $outdir flow-disagrees.bit]
    write_fake_bitstream $bit deadbee1
    file delete -force $bit.stamp
    set out [flow_capture {build_stamp_stamped "BIT:" $bit {4a585e10 4a585e1 clean}} rc]
    if {$rc} { lappend bad "disagrees: accepted a bitstream naming another build" }
    if {[string first "BIT: FAILED --- the bitstream names build deadbee1 where this run set 4a585e10." $out] < 0} {
        lappend bad "disagrees: never named both numbers"
    }
    if {[file exists $bit.stamp]} {
        lappend bad "disagrees: wrote a sidecar beside a bitstream it had refused"
    }

    # A header with no UserID in it, which is what a future Vivado writing the
    # field differently would look like.  Not a failure: the sidecar carries
    # the number and the line says so.
    set bit [file join $outdir flow-nameless.bit]
    write_fake_bitstream $bit ""
    file delete -force $bit.stamp
    set out [flow_capture {build_stamp_stamped "BIT:" $bit {4a585e10 4a585e1 clean}} rc]
    if {!$rc} { lappend bad "nameless: refused a bitstream whose header names nothing" }
    if {[string first "BIT: the bitstream's header does not name a UserID" $out] < 0} {
        lappend bad "nameless: never said the header named nothing"
    }
    if {[lindex [build_stamp_read $bit] 0] ne "4a585e10"} {
        lappend bad "nameless: no sidecar, so nothing at all records the build"
    }
    return $bad
}

# Run a script with `puts` collected rather than printed.
proc flow_capture {body rcvar} {
    upvar 1 $rcvar rc
    rename puts flow_real_puts
    set ::flow_out ""
    proc puts {args} {
        set text [lindex $args end]
        if {[llength $args] > 1 && [lindex $args 0] ne "-nonewline"} {
            flow_real_puts {*}$args
            return
        }
        append ::flow_out $text "\n"
    }
    # `catch`, so that a body which throws does not leave the interpreter with
    # no `puts` and every later line of this harness silently lost.
    set err [catch {uplevel 1 $body} rc]
    rename puts {}
    rename flow_real_puts puts
    if {$err} {
        append ::flow_out "the body threw: $rc\n"
        set rc 0
    }
    return $::flow_out
}

# ------------------------------------------------------------------- the run

set outdir [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR)
                                              : [file join [pwd] build program_tcl]}]
file mkdir $outdir

set self [file normalize [info script]]
set bad 0
set broke {}
set runs 0
puts "the two program.tcl scripts against a stubbed hardware manager:"

foreach why [flow_cases $outdir] {
    incr bad ; lappend broke "flow" ; puts [format "  %-4s %-13s FAIL %s" flow "" $why]
}
incr runs 3
if {!$bad} { puts "  flow write-and-read ok   the sidecar, the header and the tree's own stamp" }

foreach script_spec $SCRIPTS {
    lassign $script_spec which path part
    foreach spec $CASES {
        lassign $spec case want_exit files settings lines
        incr runs
        set out ""
        set rc 0
        if {[catch {exec [info nameofexecutable] $self --case $which $case $outdir 2>@1} out]} {
            if {[lindex $::errorCode 0] eq "CHILDSTATUS"} {
                set rc [lindex $::errorCode 2]
            } else {
                set rc -1
            }
        }
        set why ""
        if {$rc != $want_exit} {
            set why "exit $rc, wanting $want_exit"
        } else {
            foreach want $lines {
                if {[string first $want $out] < 0} { set why "never said: $want" ; break }
            }
        }
        if {$why eq "" && [dict exists $settings no-program]} {
            if {[file exists [file join $outdir $which-$case.programmed]]} {
                set why "programmed the part anyway"
            }
        }
        if {$why eq ""} {
            puts [format "  %-4s %-13s ok" $which $case]
        } else {
            incr bad
            lappend broke "$which/$case"
            puts [format "  %-4s %-13s FAIL %s" $which $case $why]
            foreach l [split [string trimright $out "\n"] "\n"] { puts "         | $l" }
        }
    }
}

puts ""
if {$bad} {
    puts "FAIL: $bad of $runs cases read wrongly: [join $broke {, }]"
    exit 1
}
puts "ok: $runs cases, and both program.tcl scripts say which of the four\
 things happened"
puts "    a part that did not take the download is refused, and a part that\
 already held this build is not called a download that took"
puts "    and the flow's end writes a sidecar that says what its bitstream\
 says"
exit 0
