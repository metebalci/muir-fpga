# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Program the Arty Z7-20 over a remote hw_server.
#
#     BOARD_URL=<host>:3121 vivado -mode batch -source vivado/program.tcl
#
# The board need not be on the machine running Vivado; `docs/board.md` has the
# arrangement and the udev rules, whose absence looks like a network problem.
#
# WHAT SAYS IT WORKED IS THE DONE BIT, not the absence of an error.
# `program_hw_devices` can complete against a device that did not take the
# configuration, which is the same shape as every other failure in this
# project's tooling: no error, and a plausible result.
#
# This does NOT start the processor system. A `.bit` over JTAG configures the
# fabric and leaves the PS in reset, so FCLK and DDR are dead until `ps7_init`
# has run. See docs/board.md.

set url [expr {[info exists ::env(BOARD_URL)] ? $::env(BOARD_URL) : "localhost:3121"}]
set bit [expr {[info exists ::env(BIT)] ? $::env(BIT) : "build/bitstream/cadr_arty.bit"}]

if {![file exists $bit]} {
    puts "PROG: $bit is missing; build it first"
    exit 1
}

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
puts "PROG: DONE before programming: $before"

set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev

set after [get_property REGISTER.IR.BIT5_DONE $dev]
puts "PROG: DONE after programming:  $after"
if {$after != 1} {
    puts "PROG: FAILED --- the device did not assert DONE. It has not taken the"
    puts "PROG: configuration, whatever program_hw_devices reported."
    exit 1
}
puts "PROG: programmed [file tail $bit] --- DONE is high"
puts "PROG: expect LD0 blinking at about 3 Hz. LD1 dark is correct with no"
puts "PROG: memory behind mem_*: the machine stalls at microcycle 535,791."
close_hw_manager
