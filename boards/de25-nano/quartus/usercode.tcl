# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The build the DE25-Nano's part holds, read back over JTAG, and what that
# says about a download.  `program.sh` runs this twice under `quartus_stp`,
# from the repository's root:
#
#     quartus_stp -t boards/de25-nano/quartus/usercode.tcl
#     quartus_stp -t boards/de25-nano/quartus/usercode.tcl <want> <before>
#
# before the programmer and after it.  Both print `de25-program: USERCODE
# <hex>`, the register as the part reads it back.  The second compares it
# with `<want>`, the USERCODE in the bitstream's assembler report, and with
# `<before>`, the first run's reading, and says which of the three findings
# `tools/build_stamp.tcl`'s `build_stamp_verdict` gives the Zynq boards it
# is: the download took, the part already held this build so a download
# cannot be told from none, or the part holds something else, which exits 1.
# The words are this board's, since the programmer here is `quartus_pgm` and
# the witness it would otherwise be trusted on is its own report that
# configuration succeeded.
#
# **WHY A PROGRAMMER'S SUCCESS IS NOT ENOUGH.**  On a Zynq board a download
# failed silently three times in six while its script said it had worked, and
# what caught it was an identity read out of the design.  `build.sh` writes
# the build stamp into USERCODE, and this reads it back, with the opcode and
# the checks in `jtag.tcl`.

source [file join [file dirname [file normalize [info script]]] jtag.tcl]
source [file join $::de25_quartus_dir .. .. .. tools build_stamp.tcl]

set tag "de25-program:"
set args $quartus(args)
if {[llength $args] != 0 && [llength $args] != 2} {
    puts "$tag usage: usercode.tcl \[<want> <before>\]"
    exit 1
}

set opened 0
set locked 0
proc usercode_fail {lines} {
    foreach line $lines { puts $line }
    if {$::locked} { catch {device_unlock} }
    if {$::opened} { catch {close_device} }
    exit 1
}

lassign [de25_select_cable $tag] ok hw
if {!$ok} { usercode_fail $hw }
lassign [de25_select_part $tag $hw] ok dev
if {!$ok} { usercode_fail $dev }

open_device -hardware_name $hw -device_name $dev
set opened 1
device_lock -timeout 10000
set locked 1
lassign [de25_read_usercode $tag] ok held
if {!$ok} { usercode_fail $held }
# The fault bitstream's stamp (`tools/build_stamp.tcl`), said in words.
if {[build_stamp_is_fault $held]} {
    puts "$tag   that is the FAULT bitstream: no machine, every lamp blinking"
}
device_unlock
set locked 0
close_device
set opened 0

if {[llength $args] == 0} { exit 0 }

# Normalized the way the Zynq boards' readings are, so that an empty `before`
# (a part that could not be read) and a value in either case compare alike.
set want   [build_stamp_norm [lindex $args 0]]
set before [build_stamp_norm [lindex $args 1]]
if {$want eq ""} {
    puts "$tag FAILED --- the bitstream names no build: `[lindex $args 0]`"
    exit 1
}
# `ffffffff` is what a part with no stamp reads, and no build is ever given
# it, so it is no witness; `build_stamp.tcl` says why.
if {$want eq "ffffffff"} {
    puts "$tag the bitstream's USERCODE is all ones, which is no build, so it is no witness."
    exit 0
}
if {$held ne $want} {
    puts "$tag FAILED --- the part holds build $held and the bitstream is build $want."
    puts "$tag   It is running something else, whatever the programmer reported."
    exit 1
}
if {$before eq $want} {
    puts "$tag the part holds build $want, and held it before this run too, so this"
    puts "$tag   cannot tell a download that took from one that did nothing. The claim"
    puts "$tag   is that the part holds this build, and it does."
    exit 0
}
if {$before eq ""} {
    puts "$tag the part holds build $want; what it held before could not be read, so"
    puts "$tag   this does not say whether the download changed it."
    exit 0
}
puts "$tag the part holds build $want and held $before before, so the download took."
exit 0
