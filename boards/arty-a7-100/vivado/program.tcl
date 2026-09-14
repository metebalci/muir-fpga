# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Program the Arty A7-100 over JTAG.
#
#     BIT=build/a7-bitstream/cadr_arty_a7.bit \
#     CABLE=<the cable's serial number> \
#         vivado -mode batch -source boards/arty-a7-100/vivado/program.tcl
#
# **NAME THE CABLE, ALWAYS.**  More than one board can be on one host's USB,
# and `[lindex [get_hw_targets] 0]` then programs whichever the server
# enumerated first --- which is not a fault anybody sees until the wrong board
# changes behaviour.  The serial number is printed on the FTDI device and is
# what `get_hw_targets` puts in the target's own name, so this script matches
# on it and stops when it matches none or more than one.  `CABLE` has no
# default for the same reason `tick.tcl` has no fallback period: a default
# that is right today is a script that quietly does the wrong thing tomorrow.
#
# WHAT SAYS IT WORKED IS THE BUILD THE PART READS BACK, and DONE second.
# `program_hw_devices` can complete against a device that did not take the
# configuration, which is the same shape as every other failure in this
# project's tooling: no error, and a plausible result.
#
# **AND DONE ALONE CANNOT SEE THAT, WHICH THIS BOARD PROVED.**  On a part that
# was already configured DONE is high before the download and high after it.
# Three downloads in six did not take here while this script reported that
# they had, and what caught it was the memory window's identity read --- an
# instrument in the design, not anything the programming did.
#
# So the flow writes the commit into `BITSTREAM.CONFIG.USERID`, the part reads
# it back over JTAG as its USERCODE, and this compares the two.
# `tools/build_stamp.tcl` holds the format, the two Vivado property names and
# what was measured about them.
#
# WHAT THIS WITNESS CAN AND CANNOT TELL.  It says the part holds THE BUILD IN
# THIS FILE.  It cannot tell a part that already held the same build from a
# download that did nothing --- both leave the part holding this build, and
# the line printed says which of the two it saw.  A bitstream that names no
# build at all, which is anything built before the flows stamped them, falls
# back to DONE and says so.
#
# **AND THERE IS NO PROCESSING SYSTEM TO START AFTERWARDS.**  On the Arty
# Z7-20 a `.bit` over JTAG leaves the PS in reset and nothing works until
# `ps7_init` has run.  Here the fabric is the whole design: the machine starts
# when the MMCM locks, some tens of microseconds after DONE goes high, and
# nobody has to be at the board.

# Resolved from this file rather than from the working directory, so that the
# script runs from anywhere and so that a copy of the tree tests its own copy.
source [file join [file dirname [file normalize [info script]]] .. .. .. tools build_stamp.tcl]

set url   [expr {[info exists ::env(BOARD_URL)] ? $::env(BOARD_URL) : "localhost:3121"}]
set bit   [expr {[info exists ::env(BIT)] ? $::env(BIT) : "build/a7-bitstream/cadr_arty_a7.bit"}]
set cable [expr {[info exists ::env(CABLE)] ? $::env(CABLE) : ""}]

if {$cable eq ""} {
    puts "PROG: FAILED --- CABLE is not set, and this script will not guess."
    puts "PROG: More than one board can be on one host's USB. Pass the JTAG"
    puts "PROG: cable's serial number, which is what get_hw_targets names the"
    puts "PROG: target by. docs/board.md has the arrangement."
    exit 1
}
if {![file exists $bit]} {
    puts "PROG: $bit is missing; build it first"
    exit 1
}

# What the part must read back when this has worked.  Read before anything is
# opened, because a bitstream whose own header and whose sidecar disagree is
# not a file to program a board with.
set want [build_stamp_expected "PROG:" $bit]
if {$want eq "!"} { exit 1 }

open_hw_manager
connect_hw_server -url $url
puts "PROG: connected to $url"

set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
    puts "PROG: FAILED --- the server connected and offered no targets."
    puts "PROG: That is the udev rules, not the network: hw_server can read the"
    puts "PROG: cable and not write it. docs/board.md has them."
    exit 1
}
puts "PROG: the server offers [llength $targets] target(s): [join $targets {, }]"

set matched {}
foreach t $targets {
    if {[string first $cable $t] >= 0} { lappend matched $t }
}
if {[llength $matched] != 1} {
    puts "PROG: FAILED --- [llength $matched] of the targets above carry the"
    puts "PROG: serial $cable. Exactly one is wanted: none means the board is"
    puts "PROG: unplugged or somebody else's hw_server holds it, and more than"
    puts "PROG: one means the serial is a prefix of two."
    exit 1
}
current_hw_target [lindex $matched 0]
open_hw_target
puts "PROG: target [get_property NAME [current_hw_target]]"

foreach d [get_hw_devices] {
    puts "PROG: device $d  part=[get_property -quiet PART $d]\
 idcode=[get_property -quiet REGISTER.IDCODE $d]"
}

# **ONE DEVICE, WHERE A ZYNQ HAS TWO.**  There is no ARM debug access port in
# this chain, so the part is the whole of it. Named rather than taken by
# position, so that a board which is not this one fails on the check that says
# so.
set dev [lindex [get_hw_devices xc7a100t_0] 0]
if {$dev eq ""} {
    puts "PROG: FAILED --- no xc7a100t_0 in the chain. The devices the manager"
    puts "PROG: found are listed above; a different part on this cable is a"
    puts "PROG: different board."
    exit 1
}
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set before [get_property REGISTER.IR.BIT5_DONE $dev]
set ubefore [build_stamp_usercode $dev]
puts "PROG: DONE before programming: $before, build [expr {$ubefore eq "" ? {not readable} : $ubefore}]"

set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev

set after [get_property REGISTER.IR.BIT5_DONE $dev]
set uafter [build_stamp_usercode $dev]
puts "PROG: DONE after programming:  $after, build [expr {$uafter eq "" ? {not readable} : $uafter}]"
if {$after != 1} {
    puts "PROG: FAILED --- the device did not assert DONE. It has not taken the"
    puts "PROG: configuration, whatever program_hw_devices reported."
    exit 1
}
if {![build_stamp_verdict "PROG:" $want $ubefore $uafter]} { exit 1 }
# Not "DONE is high" any more: the lines above say what was checked, and
# DONE was never the thing worth summarising.
puts "PROG: programmed [file tail $bit]"
puts "PROG: **THE LAMP NUMBERS ON THIS BOARD ARE NOT THE OTHER BOARD'S.**"
puts "PROG: This board silkscreens its four green LEDs LD4 to LD7 and its four"
puts "PROG: tricolour ones LD0 to LD3. Expect the green LD5 blinking at about"
puts "PROG: 1.5 Hz --- the fabric's own clock --- and the green LD6 blinking"
puts "PROG: with the microcycles, every 0.28 s, and STAYING lit and unlit in"
puts "PROG: turn: with no memory the machine does not stop, it runs about a"
puts "PROG: fifth slower once every main-memory cycle ends on the 4.25 us"
puts "PROG: timer. The green LD4 is MACHRUN and DIMS from that point rather"
puts "PROG: than going out. The tricolour LD1 is blue while the machine is in"
puts "PROG: its boot PROM, which here is for ever. **The tricolour LD0 should"
puts "PROG: stay DARK**: it lights for the machine's own error halt and for"
puts "PROG: nothing else, and a timeout is not one. README.md tabulates all"
puts "PROG: six."
close_hw_manager
