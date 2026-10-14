# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# **HOW MANY READ PORTS A LUT RAM WAS BUILT WITH**, asked of the synthesized
# netlist by the Zynq boards' revision 15 flows (`boards/kria-kr260/vivado/
# quux15_bitstream.tcl`, `boards/arty-z7-20/vivado/quux15_bitstream.tcl`)
# for the macro dispatch memory (`rtl/machine/quux15_mdmem.sv`).
#
# A LUT RAM cell (a leaf `RAMD64E` or `RAMD32`, which both families build
# their LUT RAMs of) holds 64 or 32 bits and has one read port, so a RAM
# read at N addresses holds N copies of its bits in the cells that read.  The
# cells that read only at the write address (the last cell of a RAM64M or
# RAM32M, whose read address pins are its write address's) are left out,
# and the bits of the rest, divided by the RAM's bits, are its read ports.
# Counting bits rather than addresses keeps the answer when a tool
# replicates an address's drivers.  Vivado 2026.1 has built the macro
# dispatch memory, read at four addresses, with one read port's worth of
# cells when its reads were written as calls of one function; this is what
# refuses such a build.
#
#     source tools/quux15_lutram_ports.tcl
#     lassign [quux15_lutram_read_ports *u_core/u_mdmem/* [expr {1024 * 18}]] cells ports

# The drivers of a cell's pins `prefix`0 to `prefix`<n-1>, in order.  A net
# is named again inside each macro it passes through; its driver is the one
# name it has.
proc quux15_lutram_pin_key {cell prefix n} {
    set key {}
    for {set i 0} {$i < $n} {incr i} {
        set pin [get_pins -quiet -of_objects $cell -filter "REF_PIN_NAME == ${prefix}${i}"]
        set net [get_nets -quiet -of_objects $pin]
        lappend key [lsort [get_pins -quiet -leaf -of_objects $net -filter {DIRECTION == OUT}]]
    }
    return [join $key ,]
}

# The LUT RAM cells under `pat`, and how many read ports of `bits` bits the
# cells that read hold.
proc quux15_lutram_read_ports {pat bits} {
    set cells [get_cells -hier -quiet -filter "IS_PRIMITIVE && REF_NAME =~ RAMD* && NAME =~ $pat"]
    set read_bits 0
    foreach c $cells {
        set n [expr {[string match *64* [get_property REF_NAME $c]] ? 6 : 5}]
        if {[quux15_lutram_pin_key $c RADR $n] ne [quux15_lutram_pin_key $c WADR $n]} {
            incr read_bits [expr {1 << $n}]
        }
    }
    return [list [llength $cells] [expr {$read_bits / $bits}]]
}
