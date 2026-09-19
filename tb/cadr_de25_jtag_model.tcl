# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's JTAG as `quartus_stp` presents it, in enough detail to run
# `boards/de25-nano/quartus/probe.tcl` and `usercode.tcl` under plain
# `tclsh`, with no board and no Quartus.  `tb/cadr_de25_jtag_tb.tcl` drives
# it.
#
# ------------------------------------------------------------ WHAT IS MODELED
#
# The ten commands of `::quartus::jtag` the two scripts use, with the shapes
# measured on the board and written down in `jtag.tcl`:
#
#   get_hardware_names       the cables, named `DE25-Nano [<usb device>-iface0]`.
#   get_device_names         the chain, one name a part, ending `(0x<IDCODE>)`.
#   open_device, close_device, device_lock, device_unlock
#                            and the rule Quartus states in each command's
#                            help: no scan without an open device and a lock.
#   device_ir_shift          returns the instruction register's capture as a
#                            number, 1 on the board.
#   device_dr_shift          IDCODE (6) and USERCODE (7), as upper-case hex
#                            with the first bit out at the right.
#   device_virtual_ir_shift  one node at index 0 with a one-bit instruction,
#                            returning the instruction it held.
#   device_virtual_dr_shift  in instruction 0 a bypass bit that captures 0;
#                            in instruction 1 the probe's sample register,
#                            one sample a scan and the read pointer moving on
#                            every capture, as `rtl/plumbing/cadr_probe.sv`
#                            moves it.
#
# ------------------------------------------------------- WHAT IS NOT MODELED
#
# READ THIS BEFORE TAKING A GREEN RUN TO MEAN THE READOUT IS VERIFIED.  This
# is the commands' surface and nothing under it: no TAP, no SLD hub, no TCK
# and no fabric.  What it holds the scripts to is that they read what the
# commands return in the way the board was measured to return it, that each
# refuses a board that is not what it expects on the check that names it, and
# that the capture they write is the layout they say it is.  Whether the node
# and the probe behave is `tb/cadr_probe_tb.cpp`'s question, in Verilator;
# whether the commands really return what is written here is the board's,
# and the board answered it once, as `jtag.tcl` records.
#
# ------------------------------------------------------------------ the state
#
#   hardware   the cables, as get_hardware_names returns them
#   devices    a dict of cable to the part names on its chain
#   ircap      what the part's instruction register captures
#   idcode     what a raw IDCODE scan returns, hex
#   usercode   what a raw USERCODE scan returns, hex
#   reversed   every returned register comes back bit-reversed
#   nodes      how many Virtual JTAG nodes the design has
#   vir_stuck  the node's instruction reads back this value whatever was
#              shifted in, or "" for a node that works
#   bypass_raw the bypass register is missing, so TDI comes straight back
#   depth      the probe's ring depth
#   rd         how many samples have been captured
#   sample     command prefix answering the 454-bit sample stored at slot j
array set ::m {
    hardware   {}
    devices    {}
    ircap      1
    idcode     4362C0DD
    usercode   541A5A83
    reversed   0
    nodes      1
    vir_stuck  ""
    bypass_raw 0
    depth      8
    rd         0
    sample     model_sample
    open       ""
    locked     0
    ir         6
    vir        0
}

proc model_mask {n} { return [expr {(1 << $n) - 1}] }

proc model_hex {value n} {
    if {$::m(reversed)} {
        set r 0
        for {set k 0} {$k < $n} {incr k} {
            set r [expr {$r | ((($value >> $k) & 1) << ($n - 1 - $k))}]
        }
        set value $r
    }
    return [format %0[expr {($n + 3) / 4}]llX $value]
}

# valid, cycle, data, as the probe stores them: slot j holds cycle j.
proc model_sample {j} {
    return [expr {(1 << 453) | ($j << 421) | (($j * 3 + 1) & 0xffff)}]
}

proc model_opt {argv name} {
    set i [lsearch -exact $argv $name]
    if {$i < 0} { return "" }
    return [lindex $argv [expr {$i + 1}]]
}

proc model_need_lock {} {
    if {$::m(open) eq ""} { error "ERROR: No device has been opened." }
    if {!$::m(locked)} {
        error "ERROR: A device has not been locked; exclusive communication must be obtained first."
    }
}

# ------------------------------------------------------------- the commands

proc get_hardware_names {} {
    if {[llength $::m(hardware)] == 0} {
        error "ERROR: No programming hardware is attached to the JTAG server or it is not configured properly."
    }
    return $::m(hardware)
}

proc get_device_names {args} {
    set hw [model_opt $args -hardware_name]
    if {![dict exists $::m(devices) $hw]} { error "ERROR: The specified hardware is not found." }
    return [dict get $::m(devices) $hw]
}

proc open_device {args} {
    if {$::m(open) ne ""} { error "ERROR: A device was opened." }
    set hw [model_opt $args -hardware_name]
    set dev [model_opt $args -device_name]
    if {![dict exists $::m(devices) $hw] || [lsearch -exact [dict get $::m(devices) $hw] $dev] < 0} {
        error "ERROR: The specified device is not found."
    }
    set ::m(open) $dev
}

proc close_device {} { set ::m(open) "" ; set ::m(locked) 0 }

proc device_lock {args} {
    if {$::m(open) eq ""} { error "ERROR: No device has been opened." }
    if {$::m(locked)} { error "ERROR: A device was locked." }
    set ::m(locked) 1
}

proc device_unlock {} { set ::m(locked) 0 }

proc device_ir_shift {args} {
    model_need_lock
    set ::m(ir) [expr {[model_opt $args -ir_value]}]
    return $::m(ircap)
}

proc device_dr_shift {args} {
    model_need_lock
    set n [model_opt $args -length]
    switch -- $::m(ir) {
        6 { set v 0x$::m(idcode) }
        7 { set v 0x$::m(usercode) }
        default { set v 0 }
    }
    return [model_hex [expr {$v & [model_mask $n]}] $n]
}

proc device_virtual_ir_shift {args} {
    model_need_lock
    if {[model_opt $args -instance_index] >= $::m(nodes)} {
        error "ERROR: The specified virtual JTAG instance cannot be found."
    }
    set held $::m(vir)
    if {$::m(vir_stuck) ne ""} { set held $::m(vir_stuck) }
    set ::m(vir) [expr {[model_opt $args -ir_value] & 1}]
    return $held
}

proc device_virtual_dr_shift {args} {
    model_need_lock
    if {[model_opt $args -instance_index] >= $::m(nodes)} {
        error "ERROR: The specified virtual JTAG instance cannot be found."
    }
    set n [model_opt $args -length]
    set hex [model_opt $args -dr_value]
    if {[string length $hex] != ($n + 3) / 4} {
        error "ERROR: The length of the value string specified does not match the length parameter specified."
    }
    set tdi 0x$hex
    set tdi [expr {$tdi & [model_mask $n]}]
    if {$::m(vir) == 0} {
        if {$::m(bypass_raw)} { return [model_hex $tdi $n] }
        return [model_hex [expr {($tdi << 1) & [model_mask $n]}] $n]
    }
    set j [expr {$::m(rd) % $::m(depth)}]
    incr ::m(rd)
    set s [uplevel #0 [concat $::m(sample) [list $j]]]
    # An over-long scan reads TDI back behind the register, as any shift
    # register does; the probe's is 454 bits.
    if {$n > 454} {
        set s [expr {$s | (($tdi & [model_mask [expr {$n - 454}]]) << 454)}]
    }
    return [model_hex [expr {$s & [model_mask $n]}] $n]
}
