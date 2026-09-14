# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Write the bitstream into the Arty A7-100's QSPI flash, so that the board
# configures itself at power-on with nobody at it.
#
#     CFGMEM_PART=<the flash part> CABLE=<the cable's serial> \
#     BIT=build/a7-bitstream/cadr_arty_a7.bit \
#         vivado -mode batch -source boards/arty-a7-100/vivado/qspi.tcl
#
# **NOTHING HAS EVER RUN THIS.**  It is written down because a board with no
# processing system, no card and no U-Boot has the flash and only the flash as
# a way of coming up on its own, and because the commands are worth having
# recorded before somebody needs them. Every figure and every property in it is
# read off Vivado's own data or off Digilent's published pin file; none of it
# is a measurement. Treat the first run as a bring-up, with the JTAG recipe in
# `README.md` as the control: **a board that will not configure from JTAG
# cannot be diagnosed by writing its flash.**
#
# WHAT THE FLASH BOOT IS FOR, AND WHAT IT IS NOT FOR.  On the Arty Z7-20 the
# board comes up because the processing system reads a card: `BOOT.BIN`, then
# U-Boot, then a bitstream, a kernel and a root filesystem. None of that exists
# here. The flash carries the bitstream and nothing else, the part loads it at
# power-on, and the machine starts when the MMCM locks --- which on a board
# with no main memory means it runs the boot PROM to microcycle 536,303 and
# stops there. So this is not "the board boots"; it is "the fabric is there
# without a cable", which is a smaller and still useful thing.
#
# **THE MODE PINS ARE THE BOARD'S AND NOT THIS SCRIPT'S.**  An Arty A7 reads
# its configuration mode from a jumper, and a board strapped to JTAG will not
# read the flash however correctly it is written. Digilent's reference manual
# has which jumper and which position. This script writes the flash; it cannot
# make the part read it, and a board that is silent after a power cycle should
# be checked there first.

set url   [expr {[info exists ::env(BOARD_URL)] ? $::env(BOARD_URL) : "localhost:3121"}]
set bit   [expr {[info exists ::env(BIT)] ? $::env(BIT) : "build/a7-bitstream/cadr_arty_a7.bit"}]
set cable [expr {[info exists ::env(CABLE)] ? $::env(CABLE) : ""}]
set part  [expr {[info exists ::env(CFGMEM_PART)] ? $::env(CFGMEM_PART) : ""}]
set mcs   [expr {[info exists ::env(MCS)] ? $::env(MCS) : "[file rootname $bit].mcs"}]

if {$cable eq ""} {
    puts "QSPI: FAILED --- CABLE is not set, and this script will not guess."
    puts "QSPI: More than one board can be on one host's USB, and this one"
    puts "QSPI: ERASES a flash. Pass the JTAG cable's serial number."
    exit 1
}

# **THE FLASH PART HAS NO DEFAULT, ON PURPOSE.**  The board carries 16 MB of
# Quad SPI flash and WHICH 128-Mbit device it is depends on the board
# revision; Digilent's master pin file names the four data pins and the chip
# select and says nothing about the part, and this repository has not
# established it. A default here would be the `tick.tcl` trap with a flash
# behind it: right on one board, silently wrong on the next, and the failure is
# a programming run that reports success against a device whose sectors are a
# different size.
#
# HOW TO SETTLE IT, in the order worth trying: the marking on the chip itself;
# Digilent's reference manual for the board revision on the silkscreen (Rev. D
# and Rev. E are the two the pin file names); and `get_cfgmem_parts` at a
# Vivado prompt, which lists what the tool will accept.
#
# The candidates, from Vivado 2026.1's own
# `data/xicom/xicom_cfgmem_part_table.csv` --- every 128-Mbit SPI device it
# lists as compatible with `artix7` at a four-bit data width:
#
#     mt25ql128-spi-x1_x2_x4          Micron, and the successor to the
#                                     N25Q128 at 3.3 V --- the table carries
#                                     `n25q128` at 1.8 V only, which is worth
#                                     knowing before looking for it
#     s25fl128sxxxxxx0-spi-x1_x2_x4   Spansion/Cypress, 64 kB sectors
#     s25fl128sxxxxxx1-spi-x1_x2_x4   the same, 256 kB sectors
#     s25fl128l-spi-x1_x2_x4          the later Cypress part
if {$part eq ""} {
    puts "QSPI: FAILED --- CFGMEM_PART is not set, and this script will not"
    puts "QSPI: guess which flash is on the board. The header lists the four"
    puts "QSPI: parts Vivado accepts for a 128-Mbit x4 SPI flash on an Artix-7"
    puts "QSPI: and the three ways to find out which one this board has."
    exit 1
}
if {![file exists $bit]} {
    puts "QSPI: $bit is missing; build it first"
    exit 1
}

# --- 1. the image
#
# `-size 16` is megabytes and is the board's 16 MB of flash. `-interface SPIx4`
# must agree with `BITSTREAM.CONFIG.SPI_BUSWIDTH`, which
# `boards/arty-a7-100/cadr_arty_a7.xdc` sets to 4 and says at the property that
# nothing has exercised. `up 0x0` puts the bitstream at the bottom, which is
# where the part looks.
#
# **AND THE PART DOES NOT READ AN `.mcs`; IT READS WHAT THIS WRITES INTO THE
# FLASH.** The intermediate file is Vivado's own format and its only reader is
# the step below.
write_cfgmem -force -format MCS -size 16 -interface SPIx4 \
    -loadbit "up 0x0 $bit" -file $mcs
if {![file exists $mcs]} {
    puts "QSPI: FAILED --- write_cfgmem left no file at $mcs"
    exit 1
}
puts "QSPI: wrote $mcs, [file size $mcs] bytes, from [file tail $bit]"

# --- 2. the board
open_hw_manager
connect_hw_server -url $url
puts "QSPI: connected to $url"

set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
    puts "QSPI: FAILED --- the server connected and offered no targets."
    exit 1
}
puts "QSPI: the server offers [llength $targets] target(s): [join $targets {, }]"
set matched {}
foreach t $targets {
    if {[string first $cable $t] >= 0} { lappend matched $t }
}
if {[llength $matched] != 1} {
    puts "QSPI: FAILED --- [llength $matched] of the targets above carry the"
    puts "QSPI: serial $cable. Exactly one is wanted."
    exit 1
}
current_hw_target [lindex $matched 0]
open_hw_target

set dev [lindex [get_hw_devices xc7a100t_0] 0]
if {$dev eq ""} {
    puts "QSPI: FAILED --- no xc7a100t_0 in the chain."
    exit 1
}
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set memparts [get_cfgmem_parts -quiet $part]
if {[llength $memparts] != 1} {
    puts "QSPI: FAILED --- CFGMEM_PART `$part` names [llength $memparts] of"
    puts "QSPI: Vivado's configuration memory parts; exactly one is wanted."
    puts "QSPI: `get_cfgmem_parts` at a Vivado prompt lists them all."
    exit 1
}

# --- 3. the write
#
# **WHAT ACTUALLY PROGRAMS A FLASH OVER JTAG IS A PROGRAM IN THE FABRIC.**
# `create_hw_bitstream` loads Vivado's own indirect-programming design into the
# part --- which is why this REPLACES whatever the part was configured with,
# including the machine --- and `program_hw_cfgmem` then drives the flash
# through it. A board that was running the CADR is not running it afterwards
# until it is programmed again or power-cycled.
#
# `PROGRAM.ERASE`, `PROGRAM.CFG_PROGRAM` and `PROGRAM.VERIFY` are the three
# that matter and all three are on: an unverified write to a flash is the same
# shape of claim as a `write_bitstream` that left no file.
create_hw_cfgmem -hw_device $dev [lindex $memparts 0]
set cfgmem [get_property PROGRAM.HW_CFGMEM $dev]
set_property PROGRAM.FILES              [list $mcs]        $cfgmem
set_property PROGRAM.ADDRESS_RANGE      {use_file}         $cfgmem
set_property PROGRAM.BLANK_CHECK        0                  $cfgmem
set_property PROGRAM.ERASE              1                  $cfgmem
set_property PROGRAM.CFG_PROGRAM        1                  $cfgmem
set_property PROGRAM.VERIFY             1                  $cfgmem
set_property PROGRAM.CHECKSUM           0                  $cfgmem
set_property PROGRAM.PRM_FILE           {}                 $cfgmem
# The pins the indirect-programming design does not use. `pull-none` is what
# Vivado's own flow writes and is the safe answer on a board whose other pins
# go to LEDs, switches and Pmod headers.
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none}    $cfgmem

create_hw_bitstream -hw_device $dev [get_property PROGRAM.HW_CFGMEM_BITFILE $dev]
program_hw_devices $dev
refresh_hw_device -update_hw_probes false $dev
program_hw_cfgmem -hw_cfgmem $cfgmem

puts "QSPI: wrote and verified [file tail $mcs] into $part"
puts "QSPI: **THE PART IS NOW RUNNING VIVADO'S PROGRAMMING DESIGN AND NOT THE"
puts "QSPI: MACHINE.** Power-cycle the board, or press its PROG button, to make"
puts "QSPI: it read what was just written --- and check the configuration-mode"
puts "QSPI: jumper first: a board strapped to JTAG will not read the flash."
puts "QSPI: What says it worked is the lamps: the green LD5 blinking at about"
puts "QSPI: 1.5 Hz with nothing plugged into the JTAG cable at all."
close_hw_manager
