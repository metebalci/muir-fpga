# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Program the Arty Z7-20 over a remote hw_server.
#
#     BOARD_URL=<host>:3121 vivado -mode batch -source boards/arty-z7-20/vivado/program.tcl
#
# The board need not be on the machine running Vivado; `docs/board.md` has the
# arrangement and the udev rules, whose absence looks like a network problem.
#
# WHAT SAYS IT WORKED IS THE BUILD THE PART READS BACK, and DONE second.
# `program_hw_devices` can complete against a device that did not take the
# configuration, which is the same shape as every other failure in this
# project's tooling: no error, and a plausible result.
#
# **DONE ALONE CANNOT SEE THAT.**  On a part that was already configured DONE
# is high before the download and high after it, so the bit that was the whole
# witness here reads the same whether the configuration took or not.  On one
# board a download failed silently three times in six while its script said it
# had worked, and what caught it was an identity read out of the design rather
# than anything the programming script did.
#
# So the flows write the commit into `BITSTREAM.CONFIG.USERID`, the part reads
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
# This does NOT start the processor system. A `.bit` over JTAG configures the
# fabric and leaves the PS in reset, so FCLK and DDR are dead until `ps7_init`
# has run. See docs/board.md.

# Resolved from this file rather than from the working directory, so that the
# script runs from anywhere and so that a copy of the tree tests its own copy.
source [file join [file dirname [file normalize [info script]]] .. .. .. tools build_stamp.tcl]

set url [expr {[info exists ::env(BOARD_URL)] ? $::env(BOARD_URL) : "localhost:3121"}]
set bit [expr {[info exists ::env(BIT)] ? $::env(BIT) : "build/bitstream/cadr_arty.bit"}]

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
current_hw_target [lindex $targets 0]
open_hw_target
puts "PROG: target [get_property NAME [current_hw_target]]"

# `-quiet` on the idcode: the chain holds the ARM debug access port as well as
# the part, and `arm_dap_0` has no IDCODE register. Reading it unguarded is an
# error that stops the script after the hard part has already worked.
foreach d [get_hw_devices] {
    puts "PROG: device $d  part=[get_property -quiet PART $d]\
 idcode=[get_property -quiet REGISTER.IDCODE $d]"
}

set dev [lindex [get_hw_devices xc7z020_1] 0]
if {$dev eq ""} {
    puts "PROG: FAILED --- no xc7z020_1 in the chain"
    exit 1
}
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set before [get_property REGISTER.IR.BIT5_DONE $dev]
set ubefore [build_stamp_usercode $dev]
set ubshow "not readable"
if {$ubefore ne ""} { set ubshow $ubefore }
puts "PROG: DONE before programming: $before, build $ubshow"

set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev

set after [get_property REGISTER.IR.BIT5_DONE $dev]
set uafter [build_stamp_usercode $dev]
set uashow "not readable"
if {$uafter ne ""} { set uashow $uafter }
puts "PROG: DONE after programming:  $after, build $uashow"
if {$after != 1} {
    puts "PROG: FAILED --- the device did not assert DONE. It has not taken the"
    puts "PROG: configuration, whatever program_hw_devices reported."
    exit 1
}
if {![build_stamp_verdict "PROG:" $want $ubefore $uafter]} { exit 1 }
# Not "DONE is high" any more: the lines above say what was checked, and
# DONE was never the thing worth summarizing.
puts "PROG: programmed [file tail $bit]"
puts "PROG: expect LD1 blinking at about 3 Hz --- the fabric's own clock ---"
puts "PROG: and LD2 blinking with it once the machine retires microcycles."
puts "PROG: LD0 is MACHRUN and LD5 is lit while the machine is still in its"
puts "PROG: boot PROM. docs/board.md tabulates all six."
close_hw_manager
