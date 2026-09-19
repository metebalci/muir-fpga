# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's JTAG, as the scripts beside this reach it: the cable by its
# serial, the one part on it, and the two registers of that part that say
# what it is and what it holds.
#
# Sourced by `probe.tcl` and `usercode.tcl`, which run under `quartus_stp`,
# whose `::quartus::jtag` package gives `get_hardware_names`,
# `get_device_names`, `open_device`, `device_lock`, `device_ir_shift`,
# `device_dr_shift`, `device_virtual_ir_shift`, `device_virtual_dr_shift`,
# `device_unlock` and `close_device`.  Each is used as `quartus_stp --tcl_eval
# help -cmd <name>` documents it, and each shape this reads back was measured
# on the board before it was written down here.  `tb/cadr_de25_jtag_model.tcl`
# defines the same ten commands under plain `tclsh`, so that
# `tb/cadr_de25_jtag_tb.tcl` can run both scripts with no board and no
# Quartus.
#
# ------------------------------------------------------------ the cable
#
# **THE BOARD IS NAMED BY ITS SERIAL AND NEVER BY A POSITION**, because
# several boards share one USB hub on the build host.  `DE25_SERIAL` in the
# environment wins, and otherwise a `DE25_SERIAL=` line in the gitignored
# `boards/de25-nano/local.conf`, the same line `program.sh` reads.
#
# Quartus names a cable by where it is plugged in and not by its serial:
# `DE25-Nano [9-1-iface0]`, measured, where `9-1` is the USB device's name
# under `/sys/bus/usb/devices/`.  So the serial is looked up there, among the
# devices with Altera's vendor ID, 09fb, and a cable is taken when its port
# names the device that carries the serial.  A serial that matches no cable,
# or more than one, is refused.
#
# With no serial at all and exactly one cable attached, that cable is used
# and the line printed says so, as `tools/jtag_target.tcl` does for the Zynq
# boards.  With no serial and more than one, the run is refused and every
# cable is named with the serial it carries.
#
# ------------------------------------------------------------- the part
#
# One part on the chain, and it is this board's: IDCODE 0x4362C0DD, which
# Altera's JTAG boundary-scan guide for the family (document 820038,
# 2026.08.20, the device ID table) gives the A5EB013BB23B, and which Quartus
# prints in the device's name as `@1: A5E(A013BB23B|B013BB23BCS)/..
# (0x4362C0DD)`, measured.  The HPS's own TAP joins the chain only once a
# design with the processor is loaded, the same guide says; a later slice
# will meet that and this refuses it until then.
#
# **THE TWO REGISTERS ARE READ BY RAW SCANS, WITH THE GUIDE'S OPCODES**:
# IDCODE `00 0000 0110` and USERCODE `00 0000 0111`, both in its table 5 of
# the instructions the family supports, which warns that an instruction code
# not in the table can damage the part.  Nothing here shifts any other code
# into the part's own instruction register; the virtual scans go through the
# SLD hub, and Quartus chooses those instructions itself.
#
# The IDCODE is read first, and read against the constant above, because it
# is the one register whose content is known without the board: it says the
# scans return the register least significant bit last in the string, which
# is how the USERCODE and every sample after it are then read.  The
# instruction register's own capture must end in 01, as IEEE 1149.1 requires
# and the guide's section 6.2 repeats, which says the scan went through a TAP
# at all.  Measured on the board: the capture reads 1, the IDCODE `4362C0DD`
# and the USERCODE the bitstream's stamp.

set ::de25_idcode   4362c0dd
set ::de25_ir_idcode   6
set ::de25_ir_usercode 7

# The directory this file is in, captured while it is being sourced.
set ::de25_quartus_dir [file dirname [file normalize [info script]]]

# `local.conf` is a shell file of KEY=VALUE lines; one key out of it, without
# running it.  A file that is not there means no value.
proc de25_conf_value {path key} {
    if {![file readable $path]} { return "" }
    set fh [open $path]
    set text [read $fh]
    close $fh
    set value ""
    foreach line [split $text "\n"] {
        if {[regexp "^\[ \t\]*${key}\[ \t\]*=\[ \t\]*\[\"'\]?(\[^\"' \t\]*)" $line -> v]} {
            set value $v
        }
    }
    return $value
}

# The serial to select by, and where it came from.  `BOARD_DIR` is
# overridable so that a stubbed run never reads this repository's own
# `local.conf`, which names a real board.
proc de25_serial_and_source {} {
    if {[info exists ::env(DE25_SERIAL)] && $::env(DE25_SERIAL) ne ""} {
        return [list $::env(DE25_SERIAL) "DE25_SERIAL in the environment"]
    }
    if {[info exists ::env(BOARD_DIR)]} {
        set dir $::env(BOARD_DIR)
    } else {
        set dir [file normalize [file join $::de25_quartus_dir ..]]
    }
    set conf [file join $dir local.conf]
    return [list [de25_conf_value $conf DE25_SERIAL] $conf]
}

# Every Altera USB device, as a dict of its sysfs name to its serial.
# `DE25_USB_DEVICES` stands in for `/sys/bus/usb/devices` in a stubbed run.
proc de25_usb_serials {} {
    set root /sys/bus/usb/devices
    if {[info exists ::env(DE25_USB_DEVICES)]} { set root $::env(DE25_USB_DEVICES) }
    set found [dict create]
    foreach d [lsort [glob -nocomplain -directory $root *]] {
        set vid [file join $d idVendor]
        set ser [file join $d serial]
        if {![file readable $vid] || ![file readable $ser]} { continue }
        set fh [open $vid]; set v [string trim [read $fh]]; close $fh
        if {$v ne "09fb"} { continue }
        set fh [open $ser]; set s [string trim [read $fh]]; close $fh
        dict set found [file tail $d] $s
    }
    return $found
}

# The USB device a Quartus hardware name is plugged into, or "" for a name
# that does not say: `DE25-Nano [9-1-iface0]` is on `9-1`.
proc de25_cable_port {hw} {
    if {[regexp {\[([0-9][0-9.-]*)-iface[0-9]+\]$} $hw -> dev]} { return $dev }
    return ""
}

# One cable, by serial when one is given and by being the only one when none
# is.  Returns `{1 <hardware name>}`, or `{0 <lines>}` with the lines of the
# refusal for the caller to print, since each caller has its own way out.
proc de25_select_cable {tag} {
    lassign [de25_serial_and_source] serial from
    if {[catch {get_hardware_names} all]} {
        return [list 0 [list "$tag FAILED --- the JTAG server lists no cable: $all"]]
    }
    set serials [de25_usb_serials]
    set labels {}
    foreach hw $all {
        set dev [de25_cable_port $hw]
        if {$dev ne "" && [dict exists $serials $dev]} {
            lappend labels "$hw, serial [dict get $serials $dev]"
        } else {
            lappend labels "$hw, serial unknown"
        }
    }
    if {$serial eq ""} {
        if {[llength $all] == 1} {
            puts "$tag no cable serial was given and one cable is attached, so it is\
 that one: [lindex $labels 0]"
            return [list 1 [lindex $all 0]]
        }
        set lines [list "$tag FAILED --- [llength $all] cables are attached and nothing says which of" \
                        "$tag   them this run is for. They are:"]
        foreach l $labels { lappend lines "$tag     $l" }
        lappend lines "$tag   Set DE25_SERIAL, or put a DE25_SERIAL line in $from," \
                      "$tag   which is gitignored."
        return [list 0 $lines]
    }
    puts "$tag selecting the cable with serial $serial, from $from"
    set chosen {}
    foreach hw $all {
        set dev [de25_cable_port $hw]
        if {$dev ne "" && [dict exists $serials $dev] && [dict get $serials $dev] eq $serial} {
            lappend chosen $hw
        }
    }
    if {[llength $chosen] != 1} {
        return [list 0 [list "$tag FAILED --- [llength $chosen] cables carry serial $serial." \
                             "$tag   The cables attached are: [join $labels {; }]"]]
    }
    puts "$tag selected [lindex $chosen 0]"
    return [list 1 [lindex $chosen 0]]
}

# The one part on the cable's chain, which must be this board's.  Returns
# `{1 <device name>}` or `{0 <lines>}`.
proc de25_select_part {tag hw} {
    if {[catch {get_device_names -hardware_name $hw} devs]} {
        return [list 0 [list "$tag FAILED --- no part answers on $hw: $devs"]]
    }
    if {[llength $devs] != 1} {
        return [list 0 [list "$tag FAILED --- the chain on $hw holds [llength $devs] parts, wanting one:" \
                             "$tag   [join $devs {; }]"]]
    }
    set dev [lindex $devs 0]
    if {![regexp {\(0x([0-9A-Fa-f]{8})\)$} $dev -> id] || [string tolower $id] ne $::de25_idcode} {
        return [list 0 [list "$tag FAILED --- the part on $hw is `$dev`, and this board's IDCODE is" \
                             "$tag   0x[string toupper $::de25_idcode]."]]
    }
    puts "$tag the part is $dev"
    return [list 1 $dev]
}

# A 32-bit register of the part, by its instruction, as eight lower-case hex
# digits.  The part must be open and locked.  Returns `{1 <hex>}`, or
# `{0 <lines>}` when the instruction register's capture does not end in 01.
proc de25_read_register {tag name opcode} {
    set cap [device_ir_shift -ir_value $opcode]
    if {![string is integer -strict $cap] || ($cap & 3) != 1} {
        return [list 0 [list "$tag FAILED --- the instruction register captured `$cap` when $name was" \
                             "$tag   shifted in, and every TAP's capture ends in 01. The scan did not" \
                             "$tag   go through the part's TAP."]]
    }
    set v [string tolower [string trim [device_dr_shift -length 32 -value_in_hex]]]
    if {![regexp {^[0-9a-f]{8}$} $v]} {
        return [list 0 [list "$tag FAILED --- $name read back as `$v`, which is not 32 bits of hex"]]
    }
    return [list 1 $v]
}

# The part's IDCODE and USERCODE, read by raw scans.  The part must be open
# and locked.  Returns `{1 <usercode>}` or `{0 <lines>}`.
proc de25_read_usercode {tag} {
    lassign [de25_read_register $tag IDCODE $::de25_ir_idcode] ok id
    if {!$ok} { return [list 0 $id] }
    if {$id ne $::de25_idcode} {
        return [list 0 [list "$tag FAILED --- IDCODE read by a raw scan is $id, and the part's is" \
                             "$tag   $::de25_idcode. A scan that returns a known register wrongly" \
                             "$tag   returns every other register wrongly too, so nothing is read."]]
    }
    puts "$tag IDCODE $id, read by a raw scan, is the part's"
    lassign [de25_read_register $tag USERCODE $::de25_ir_usercode] ok uc
    if {!$ok} { return [list 0 $uc] }
    puts "$tag USERCODE $uc"
    return [list 1 $uc]
}

# The build a bitstream names, from the assembler's report beside it: its
# `JTAG usercode` line, as eight lower-case hex digits, or "".
proc de25_built_usercode {asm} {
    if {![file readable $asm]} { return "" }
    set fh [open $asm]
    set text [read $fh]
    close $fh
    if {[regexp -line {^; JTAG usercode +; 0x([0-9A-Fa-f]{8}) +;} $text -> v]} {
        return [string tolower $v]
    }
    return ""
}
