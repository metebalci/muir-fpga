# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Can the debugger reach this board's DDR3L at all, and does what it writes
# come back?  The first step on silicon, and everything after it assumes it.
#
#     CABLE=<the cable's serial> \
#         vivado -mode batch -source boards/arty-a7-100/vivado/ddr_check.tcl
#
# THE FOUR QUESTIONS, IN THE ORDER THEY HAVE TO BE ASKED.
#
#   1. **Is the window there?**  A register that reads `MEMW` and not all ones,
#      all zeros, or some other printable word.  All ones is a chain nobody
#      selected, all zeros is a part nobody configured, and either would be
#      reported as "the memory is broken" by anyone who did not check.
#   2. **Has the controller trained?**  Calibration takes about a millisecond
#      after a fabric reset and never finishes on a board whose memory part is
#      not answering.  Until it does, every transaction here would wait for
#      ever, so this is asked before anything is written.
#   3. **Does a word come back?**  A block of sixteen bytes written one
#      32-bit lane at a time with four DIFFERENT words, and read back.  Four
#      different words, because a lane select stuck at one value collapses the
#      four into one and the read-back shows the last one written four times
#      --- which one word, written and read, cannot see.
#   4. **And does the neighborhood survive it?**  A run of blocks poisoned
#      injectively in the address and read back.  A dropped address bit makes
#      two addresses land on one word, and the first one read back then carries
#      the second one's poison.
#
# **THE POISON IS THIS SCRIPT'S AND NOT THE FABRIC'S**, which is what makes
# this an instrument rather than a fabric agreeing with itself.
# `rtl/plumbing/cadr_jtag_mem.sv`'s header says plainly what is lost by the
# debugger's words traveling the machine's own path, and what these four
# questions recover.

set here [file dirname [file normalize [info script]]]
source $here/mem_window.tcl

set cable [expr {[info exists ::env(CABLE)] ? $::env(CABLE) : ""}]
set url   [expr {[info exists ::env(HW_SERVER)] ? $::env(HW_SERVER)
                                                : "localhost:3121"}]
if {$cable eq ""} {
    puts "MEM: FAILED --- CABLE is not set. Every script here names the JTAG"
    puts "MEM: cable by its serial number and none has a default: more than"
    puts "MEM: one board is on this host's USB, and a target taken by position"
    puts "MEM: is whichever the server enumerated first."
    exit 1
}

# How much to poison.  Blocks of sixteen bytes; 256 of them is four kilobytes,
# which is enough for a dropped address bit anywhere in the low twelve to show.
set blocks [expr {[info exists ::env(BLOCKS)] ? $::env(BLOCKS) : 256}]

window_open $cable $url

# ---- 1 and 2: the window, and whether the memory has trained
set st [window_settle]
puts "MEM: the window answers [format 0x%08x [dict get $st ident]] (\"MEMW\")"
if {![dict get $st calib]} {
    window_fail \
        "MEM: FAILED --- the controller says it has not finished calibrating." \
        "MEM: That is about a millisecond after a fabric reset and it never" \
        "MEM: finishes on a board whose memory part is not answering at all." \
        "MEM: Nothing below would return; it would wait."
}
puts "MEM: the controller has calibrated the DDR3L"

# ---- 3: four lanes of one block
#
# Held still first: the machine is running the boot PROM and reaches main
# memory 118 ms after its reset, so a word written under it is a word the
# machine may overwrite.  The hold resets the MACHINE and not the controller,
# so nothing in DDR is lost by it.
window_hold 1
set base [expr {$::W_BASE + 0x0002A000}]
set want {}
for {set l 0} {$l < 4} {incr l} {
    set a [expr {$base + 4 * $l}]
    lappend want [poison $a]
    window_issue 1 $a [poison $a]
}
window_settle
set bad 0
for {set l 0} {$l < 4} {incr l} {
    set a [expr {$base + 4 * $l}]
    set got [dict get [window_read $a] rdata]
    set w [lindex $want $l]
    if {$got != $w} {
        puts "MEM: lane $l of the block at [format 0x%08x $base] reads\
 [format 0x%08x $got], wanting [format 0x%08x $w]"
        incr bad
    }
}
if {$bad} {
    window_fail \
        "MEM: FAILED --- $bad of the four 32-bit lanes of one sixteen-byte" \
        "MEM: block came back wrong. Four different words were written one" \
        "MEM: lane at a time, so a lane select stuck at one value collapses" \
        "MEM: them and the last word written reads back four times."
}
puts "MEM: four lanes of one block, four different words, all four right"

# ---- 4: the neighborhood, poisoned injectively
#
# Written with one scan a word --- a data register scan captures before it
# updates, so a run of writes is a run of single scans.
set words [expr {$blocks * 4}]
for {set i 0} {$i < $words} {incr i} {
    set a [expr {$::W_BASE + 4 * $i}]
    window_issue 1 $a [poison $a]
}
window_settle
puts "MEM: $words words poisoned, injectively in the address"

set bad 0
set first ""
# The answers come one scan behind, which is what `window_issue` returns.
window_issue 0 $::W_BASE 0
for {set i 0} {$i < $words} {incr i} {
    set next [expr {$i + 1 < $words ? $::W_BASE + 4 * ($i + 1) : $::W_BASE}]
    set st [window_issue 0 $next 0]
    set a [expr {$::W_BASE + 4 * $i}]
    set got [dict get $st rdata]
    if {$got != [poison $a]} {
        incr bad
        if {$first eq ""} {
            set first [format "0x%08x reads 0x%08x, wanting 0x%08x" \
                           $a $got [poison $a]]
        }
    }
}
if {$bad} {
    window_fail \
        "MEM: FAILED --- $bad of $words words came back wrong; the first is" \
        "MEM: $first." \
        "MEM: The poison is a function of the address and this script computes" \
        "MEM: it, so a word that came back as ANOTHER address's poison is an" \
        "MEM: address bit lost between here and the memory part."
}
puts "MEM: all $words words read back as the poison written at their own address"

# ---- and what the port itself says it did
set t [window_tally [window_settle]]
puts "MEM: the controller's own tally: [dict get $t asked_reads] reads asked,\
 [dict get $t answered_reads] answered; [dict get $t asked_writes] writes\
 asked, [dict get $t answered_writes] answered"

window_hold 0
window_close
puts "MEM: PASSED --- the debugger reaches this board's DDR3L and what it"
puts "MEM: writes comes back, lane for lane and address for address."
exit 0
