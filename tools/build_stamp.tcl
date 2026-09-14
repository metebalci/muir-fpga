# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# A BITSTREAM THAT NAMES THE TREE IT WAS BUILT FROM, AND A PROGRAMMING SCRIPT
# THAT CAN TELL THE DOWNLOAD TOOK.
#
# Sourced by the three board flows before `write_bitstream` and by the two
# `program.tcl`s.  It is one implementation because both halves have to agree
# on one number, and two copies of a format are two chances to disagree.
#
# ------------------------------------------------------------------ the number
#
# `BITSTREAM.CONFIG.USERID` is a 32-bit configuration value.  This project
# fills it with the commit's first seven hex digits in the top 28 bits and a
# nibble saying how the tree stood:
#
#     0   every tracked file matches HEAD and nothing untracked is present
#     1   a tracked file differs from HEAD
#     2   an untracked file is present, which matters because the flows build
#         from `[glob rtl/*/*.sv ...]` rather than from the index
#     3   both
#     f   git could not say how the tree stood.  The top 28 bits are the
#         commit where there is one and zero where there is not, so
#         `0000000f` is a build from something that is not a checkout at all.
#
# **A DIRTY TREE IS RECORDED AND NEVER REFUSED.**  A bring-up run against an
# uncommitted change is legitimate work; lying about it is not.
#
# **`ffffffff` CANNOT BE A VALUE THIS WRITES**, because it would need a commit
# whose first seven digits are all `f` and a tree git could not read, and a
# tree git could not read leaves the commit unknown and the top bits zero.
# That matters: `ffffffff` is what an unprogrammed part reads and what a
# bitstream built before this existed leaves in the register, so it must never
# also be a build.  `build_stamp_verdict` refuses to treat it as a witness.
#
# ------------------------------------------------- what the two registers are
#
# `BITSTREAM.CONFIG.USERID` loads the JTAG USERCODE register.  The USERCODE
# instruction is in all three parts' BSDL --- opcode `001000`, reading the
# 32-bit `DEVICE_ID` register, with `USERCODE_REGISTER` given as 32 X's
# because what it holds is whatever was loaded into it.  The files are
# `Vivado/data/parts/xilinx/zynq/public/bsdl/xc7z020_clg400.bsd` and
# `xc7z007s_clg400.bsd`, and `artix7/public/bsdl/xc7a100t_csg324.bsd`.
# Vivado's own device tables say the family supports it as well
# (`Vivado/data/xicom/artix7.cfg` and `azynq.cfg`, `USERCODE = TRUE` with the
# same opcode).  The hardware manager reads it back as the `REGISTER.USERCODE`
# property of a `hw_device`, documented with an example value of `ffffffff` in
# `Vivado/doc/eng/class/hw_device`.
#
# `hw_bitstream` carries a `USERCODE` property of its own, which would be a
# third way to ask what a `.bit` names.  It is not used: it needs an open
# hardware target to create the object, and the file's own header gives the
# same number with no board and no Vivado at all.
#
# `BITSTREAM.CONFIG.USR_ACCESS` loads the AXSS register, which a
# `USR_ACCESSE2` primitive can read from inside the fabric.  It is set to the
# same value here because it costs one line.  **NOTHING READS IT BACK YET:**
# putting a `USR_ACCESSE2` in the fabric and a word in the console's list so
# that a running board can say which build it is carrying is a slice of its
# own, and it is the point of setting this at all.
#
# ------------------------------------------------------- what was measured
#
# Measured under Vivado 2026.1 on a trivial `xc7a100tcsg324-1` design, two
# bitstreams differing only in these two properties:
#
#   `BITSTREAM.CONFIG.USERID` is of type `hex`, reads back as `32'hXXXXXXXX`,
#   and refuses a value that is not hex.  `BITSTREAM.CONFIG.USR_ACCESS` is of
#   type `string` and accepts anything at all, `TIMESTAMP` and `hello` alike,
#   so a typo there is not caught when it is set.
#
#   The written `.bit` carries `;UserID=0ABCDEF1;` as ASCII in its header,
#   inside the design-name field about thirty bytes in, and the 32-bit value
#   as raw bytes in the configuration stream.  The two files differed in 96
#   bytes: the header text, those two words and the checksums.
#
# So the bitstream names its own build and `build_stamp_of_bitstream` reads it
# with no Vivado and no board.  That is the value `program.tcl` expects the
# part to read back, because a file cannot be separated from its own header.
#
# ------------------------------------------------------------- the sidecar
#
# `<bitstream>.stamp`, beside the `.bit`, holding the same number in words: it
# is what says which commit `4a585e10` means without a git checkout to hand.
# **It can be separated from its bitstream**, so it is never the authority:
# where both exist and disagree, that is a failure and is reported as one.

namespace eval buildstamp {
    # The repository root, captured while this file is being sourced, because
    # `info script` means nothing inside a proc called later.
    variable root [file normalize [file join [file dirname [info script]] ..]]
}

# The stamp of the tree this file sits in: a list of {userid commit tree}.
# `commit` and `tree` are for people; `userid` is the eight hex digits that go
# in the bitstream.
proc build_stamp_of_tree {} {
    set root $::buildstamp::root
    set commit ""
    if {![catch {exec git -C $root rev-parse --short=7 HEAD} out]} {
        set out [string trim $out]
        if {[regexp {^[0-9a-f]{7}$} $out]} { set commit $out }
    }
    if {$commit eq ""} {
        return [list "0000000f" "unknown" "no git information"]
    }
    set nibble 0
    set words {}
    if {[catch {exec git -C $root status --porcelain --untracked-files=no} st]} {
        # git answered `rev-parse` and not `status`: say so rather than
        # calling the tree clean, which is the one answer that would be a lie.
        return [build_stamp_pack $commit 15 "git could not read the tree"]
    }
    if {[string trim $st] ne ""} { incr nibble 1 ; lappend words "modified" }
    if {![catch {exec git -C $root status --porcelain --untracked-files=normal} st2]} {
        foreach line [split $st2 "\n"] {
            if {[string range $line 0 1] eq "??"} {
                incr nibble 2 ; lappend words "untracked" ; break
            }
        }
    }
    set tree [expr {[llength $words] ? [join $words " and "] : "clean"}]
    return [build_stamp_pack $commit $nibble $tree]
}

# The commit and the nibble as one value, with the one value that must never
# come out of here kept out of it.  `ffffffff` is what an unprogrammed part
# reads back, so a build may not be called that; only a commit of seven `f`s
# with an unreadable tree could do it, and one line makes that impossible
# rather than merely improbable.
proc build_stamp_pack {commit nibble tree} {
    set id [format "%s%x" $commit $nibble]
    if {$id eq "ffffffff"} {
        return [list "0000000f" $commit "$tree, and the build cannot be named"]
    }
    return [list $id $commit $tree]
}

# Eight lower-case hex digits, from whatever shape a tool hands back:
# `32'hDEADBEEF`, `0xDEADBEEF`, `deadbeef`.  Empty in, empty out.
proc build_stamp_norm {v} {
    set v [string trim $v]
    if {$v eq ""} { return "" }
    regsub {^32'[hH]} $v "" v
    regsub {^0[xX]} $v "" v
    if {![regexp {^[0-9a-fA-F]{1,8}$} $v]} { return "" }
    set v [string tolower $v]
    return [string range "00000000$v" end-7 end]
}

# The build a `.bit` names in its own header, or "" if it names none.
# The header is ASCII and the value is in the design-name field, so this reads
# the first few kilobytes and looks for it.
proc build_stamp_of_bitstream {bit} {
    if {![file exists $bit]} { return "" }
    set fh [open $bit r]
    fconfigure $fh -translation binary -encoding binary
    set head [read $fh 8192]
    close $fh
    if {[regexp {UserID=([0-9a-fA-F]{8})} $head -> id]} {
        return [build_stamp_norm $id]
    }
    return ""
}

proc build_stamp_sidecar {bit} { return "$bit.stamp" }

# Write the sidecar beside the bitstream.
proc build_stamp_write {bit stamp} {
    lassign $stamp userid commit tree
    set fh [open [build_stamp_sidecar $bit] w]
    puts $fh "# What built [file tail $bit], written by tools/build_stamp.tcl."
    puts $fh "#"
    puts $fh "# `userid` is BITSTREAM.CONFIG.USERID, which the part reads back"
    puts $fh "# over JTAG as its USERCODE. The bitstream's own header names it"
    puts $fh "# too, so this file is the commit's name and not the authority."
    puts $fh "userid $userid"
    puts $fh "commit $commit"
    puts $fh "tree $tree"
    close $fh
}

# Read the sidecar back: a list of {userid commit tree}, or {} if there is none
# or it is not one of ours.
proc build_stamp_read {bit} {
    set path [build_stamp_sidecar $bit]
    if {![file exists $path]} { return {} }
    array set got {userid "" commit "" tree ""}
    set fh [open $path r]
    foreach line [split [read $fh] "\n"] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        set key [lindex $line 0]
        if {[info exists got($key)]} {
            set got($key) [string trim [string range $line [string length $key] end]]
        }
    }
    close $fh
    set id [build_stamp_norm $got(userid)]
    if {$id eq ""} { return {} }
    return [list $id $got(commit) $got(tree)]
}

# Set the two properties on a design about to be written.  Separate from
# `build_stamp_of_tree` so that a flow prints the number before it uses it.
proc build_stamp_apply {design userid} {
    set_property BITSTREAM.CONFIG.USERID 0x$userid $design
    set_property BITSTREAM.CONFIG.USR_ACCESS 0x$userid $design
}

# After `write_bitstream`: the sidecar, and a line saying what the file claims
# about itself.  Returns 1 if the bitstream's header names the build that was
# set, 0 if it names a different one --- which is a defect and the caller
# should stop.  A header naming nothing at all is NOT a failure: this reads a
# field Vivado writes and we do not control, so it says so and carries on.
proc build_stamp_stamped {prefix bit stamp} {
    lassign $stamp userid commit tree
    set named [build_stamp_of_bitstream $bit]
    if {$named ne "" && $named ne $userid} {
        # No sidecar: a file beside a bitstream that is already wrong would be
        # one more thing saying the wrong number.
        puts "$prefix FAILED --- the bitstream names build $named where this run set $userid."
        puts "$prefix write_bitstream did not take the USERID it was given, so"
        puts "$prefix nothing downstream can trust the number."
        return 0
    }
    build_stamp_write $bit $stamp
    if {$named eq ""} {
        puts "$prefix the bitstream's header does not name a UserID, so"
        puts "$prefix [file tail [build_stamp_sidecar $bit]] is the only record that this is build $userid."
        return 1
    }
    puts "$prefix build $userid --- commit $commit, tree $tree --- is in the bitstream and in [file tail [build_stamp_sidecar $bit]]"
    return 1
}

# ---------------------------------------------------------- the programming end

# What the part reads back, or "" if the hardware manager has no such property
# for this device.
proc build_stamp_usercode {dev} {
    return [build_stamp_norm [get_property -quiet REGISTER.USERCODE $dev]]
}

# What the part SHOULD read back after this bitstream is downloaded.
#
# Returns the eight hex digits, "" when the bitstream names no build at all,
# and "!" when the bitstream and its sidecar disagree, which means one of them
# was copied without the other and neither can be believed.
proc build_stamp_expected {prefix bit} {
    set named [build_stamp_of_bitstream $bit]
    set side  [build_stamp_read $bit]
    set sid   [expr {[llength $side] ? [lindex $side 0] : ""}]
    if {$named ne "" && $sid ne "" && $named ne $sid} {
        puts "$prefix FAILED --- the bitstream names build $named and its sidecar names $sid."
        puts "$prefix One of the two was copied without the other. Neither can say"
        puts "$prefix what this file is, so nothing after the download could be"
        puts "$prefix checked against anything."
        return "!"
    }
    if {$named eq "" && $sid eq ""} {
        puts "$prefix this bitstream does not name the build it came from, so DONE"
        puts "$prefix is the only witness here --- which cannot tell a download that"
        puts "$prefix took from one that did not on a part already configured. That"
        puts "$prefix is a bitstream built before the flow stamped them."
        return ""
    }
    if {$named eq ""} {
        puts "$prefix this bitstream is build $sid by its sidecar; its own header names none."
    } else {
        puts "$prefix this bitstream is build $named"
    }
    if {[llength $side]} {
        puts "$prefix   commit [lindex $side 1], tree [lindex $side 2]"
    }
    return [expr {$named ne "" ? $named : $sid}]
}

# The verdict, printed.  Returns 1 to carry on and 0 to stop.
#
# WHAT THIS WITNESS CAN AND CANNOT TELL.  It says the part holds THIS BUILD,
# which is the claim anybody downstream actually wants.  It cannot tell a part
# that already held the same build from a download that did nothing, and that
# is harmless: in both cases the part holds this build, and the line says which
# of the two it saw.  What it does catch is the failure DONE cannot --- a part
# that stayed configured with something else while `program_hw_devices`
# reported success.
proc build_stamp_verdict {prefix want before after} {
    if {$want eq ""} { return 1 }
    if {$want eq "ffffffff"} {
        puts "$prefix the build is all ones, which an unprogrammed part reads too,"
        puts "$prefix so it cannot be a witness. No flow here writes that value."
        return 1
    }
    if {$after eq ""} {
        puts "$prefix the hardware manager gave no USERCODE for this device, so DONE"
        puts "$prefix is the only witness here."
        return 1
    }
    if {$after ne $want} {
        puts "$prefix FAILED --- the part reads back build $after where this bitstream"
        puts "$prefix is $want. It is holding something else, whatever"
        puts "$prefix program_hw_devices reported and whatever DONE says: DONE was"
        puts "$prefix already high on a part that was already configured."
        return 0
    }
    if {$before eq $want} {
        puts "$prefix the part holds build $want, and held it before this run too, so"
        puts "$prefix this cannot tell a download that took from one that did nothing."
        puts "$prefix The claim is that the part holds this build, and it does."
        return 1
    }
    if {$before eq ""} {
        # Readable after and not before: odd, and not a failure.  The claim
        # that matters is made either way, and pretending the empty string
        # was a build would put `held  before` in the line.
        puts "$prefix the part holds build $want; what it held before could not"
        puts "$prefix be read, so this does not say whether the download changed it."
        return 1
    }
    puts "$prefix the part holds build $want and held $before before, so the"
    puts "$prefix download took."
    return 1
}
