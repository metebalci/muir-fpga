# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The machine running MIT's boot PROM out of this board's own DDR3L, with the
# debugger outside it saying so.  This is the Arty Z7-20's step four, on a
# board with no processing system.
#
#     CABLE=<the cable's serial> \
#         vivado -mode batch -source boards/arty-a7-100/vivado/ddr_run.tcl
#
# WHAT THE BOOT PROM DOES TO MEMORY, AND WHY IT IS THE RIGHT PROGRAM.  Its only
# main-memory traffic is `PAGE-0-PARITY-FIX`: it reads each of page 0's 256
# words and writes the same word straight back to refresh parity, and never
# looks at the data.  512 bus cycles, microcycles 536,302 to 537,834, and after
# that it never touches DDR again --- so the region is frozen for a debugger to
# read at leisure.  Everything else in its 17,466 bus cycles is the disk
# controller's registers, which answer in the fabric.
#
# **AGAINST ZERO-FILLED MEMORY NOT ONE WORD CHANGES, SO A RUN COMPARED AGAINST
# ZERO TESTS NOTHING.**  That is this project's control-store-comes-up-zero
# lesson and it applies here exactly: the program is an identity copy, so a
# memory that lost every word and a memory that kept every word read the same
# if both read zero.  The cure is the same too --- poison from outside,
# injectively in the address --- and the poison is this script's.
#
# AND THE ORDER MATTERS.  The machine reaches its first main-memory cycle
# 118 ms after ITS OWN reset, and poisoning a thousand words through a JTAG
# register takes seconds, so the poison would always arrive after the machine
# had read.  The Arty Z7-20 solved this with the processing system's port gate;
# here the window holds the machine in reset, which resets the MACHINE and not
# the memory controller, so the poison survives being let go.
#
#     hold the machine -> poison -> let it go -> wait -> read the tally and
#     the words back
#
# THE TWO WITNESSES, AND WHY THERE HAVE TO BE TWO.  The words say the path did
# no harm; they cannot say the machine used it, because a machine whose port
# was dead times every cycle out and leaves the same words untouched.  The
# tally says how many transactions the CONTROLLER accepted and answered, which
# a fabric that issued nothing cannot fabricate --- and it is not on the path
# the debugger's own words travel.

set here [file dirname [file normalize [info script]]]
source $here/mem_window.tcl

set cable [expr {[info exists ::env(CABLE)] ? $::env(CABLE) : ""}]
set url   [expr {[info exists ::env(HW_SERVER)] ? $::env(HW_SERVER)
                                                : "localhost:3121"}]
if {$cable eq ""} {
    puts "MEM: FAILED --- CABLE is not set; see ddr_check.tcl for why there is"
    puts "MEM: no default."
    exit 1
}

# Page 0 and its margin: 1,024 words, of which the program touches the first
# 256.  The margin is what says the path wrote only where it was asked to.
set words [expr {[info exists ::env(WORDS)] ? $::env(WORDS) : 1024}]
set touched 256

window_open $cable $url

set st [window_settle]
puts "MEM: the window answers [format 0x%08x [dict get $st ident]] (\"MEMW\")"
if {![dict get $st calib]} {
    window_fail "MEM: FAILED --- the controller has not calibrated the DDR3L."
}

# ---- hold the machine, and poison what it is about to read
window_hold 1
puts "MEM: the machine is held in reset; the controller is not"
for {set i 0} {$i < $words} {incr i} {
    set a [expr {$::W_BASE + 4 * $i}]
    window_issue 1 $a [poison $a]
}
window_settle
puts "MEM: $words words poisoned at [format 0x%08x $::W_BASE] upwards"

# ...and read them straight back, so that a failure later can be told from a
# poison that never landed.  One scan a word, the answers one behind.
set bad 0
window_issue 0 $::W_BASE 0
for {set i 0} {$i < $words} {incr i} {
    set next [expr {$i + 1 < $words ? $::W_BASE + 4 * ($i + 1) : $::W_BASE}]
    set st [window_issue 0 $next 0]
    set a [expr {$::W_BASE + 4 * $i}]
    if {[dict get $st rdata] != [poison $a]} { incr bad }
}
if {$bad} {
    window_fail \
        "MEM: FAILED --- $bad of $words words did not read back as the poison" \
        "MEM: just written, with the machine held still. Nothing below would" \
        "MEM: mean anything: this is the debugger's own path to memory, and it" \
        "MEM: is what ddr_check.tcl exists to establish before this runs."
}
puts "MEM: the poison reads back with the machine held; the debugger's path is\
 good"

# The tally, before the machine has done anything, so that what it does can be
# counted rather than assumed.
set before [window_tally [window_settle]]
puts "MEM: before the machine runs, the controller has answered\
 [dict get $before answered_reads] reads and\
 [dict get $before answered_writes] writes --- all of them this script's"

# ---- let the machine go
window_hold 0
puts "MEM: the machine is running"
# Its first main-memory cycle is at microcycle 536,303, which is 118 ms at the
# 10 ns tick, and its last is 1,532 microcycles later.  Two hundred more
# milliseconds is a factor of two on the whole of it.
after 400
set after [window_tally [window_settle]]

set dr [expr {[dict get $after answered_reads]  - [dict get $before answered_reads]}]
set dw [expr {[dict get $after answered_writes] - [dict get $before answered_writes]}]
set ar [expr {[dict get $after asked_reads]     - [dict get $before asked_reads]}]
set aw [expr {[dict get $after asked_writes]    - [dict get $before asked_writes]}]
puts "MEM: the machine asked for $ar read(s) and $aw write(s); the controller\
 answered $dr and $dw"

if {$ar != $touched || $aw != $touched} {
    window_fail \
        "MEM: FAILED --- the boot PROM's only main-memory traffic is an" \
        "MEM: identity copy of page 0: $touched reads and $touched writes," \
        "MEM: no more and no fewer. This run asked for $ar and $aw." \
        "MEM: Fewer means the machine did not get there --- SW0 is the" \
        "MEM: no-auto-boot switch and a board with it on comes up with the" \
        "MEM: machine standing still, which is what a CADR does when the power" \
        "MEM: comes on with nobody at it. More means something else is on the" \
        "MEM: port."
}
if {$dr != $ar || $dw != $aw} {
    window_fail \
        "MEM: FAILED --- $ar reads and $aw writes were asked for and $dr and" \
        "MEM: $dw were answered. A cycle the controller never answered ends on" \
        "MEM: the bus's own 4.25 microsecond timer and the machine carries on," \
        "MEM: so nothing else here would say so."
}
puts "MEM: $ar reads and $aw writes asked, $dr and $dw answered --- every one"

# ---- and page 0 is what it was
window_hold 1
set bad 0
set first ""
window_issue 0 $::W_BASE 0
for {set i 0} {$i < $words} {incr i} {
    set next [expr {$i + 1 < $words ? $::W_BASE + 4 * ($i + 1) : $::W_BASE}]
    set st [window_issue 0 $next 0]
    set a [expr {$::W_BASE + 4 * $i}]
    if {[dict get $st rdata] != [poison $a]} {
        incr bad
        if {$first eq ""} {
            set first [format "0x%08x reads 0x%08x, wanting 0x%08x" \
                           $a [dict get $st rdata] [poison $a]]
        }
    }
}
window_hold 0
if {$bad} {
    window_fail \
        "MEM: FAILED --- $bad of $words words changed while the machine ran;" \
        "MEM: the first is $first." \
        "MEM: The boot PROM reads each of page 0's words and writes the same" \
        "MEM: word back, so every one of them must be exactly what it was."
}
puts "MEM: all $words words are byte-identical to their poison, page 0 and its\
 margin"

window_close
puts "MEM: PASSED --- the machine ran MIT's boot PROM out of this board's own"
puts "MEM: DDR3L. $ar reads and $aw writes asked and answered at the"
puts "MEM: controller's own edge, and $words words unchanged."
exit 0
