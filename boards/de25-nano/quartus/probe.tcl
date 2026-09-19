# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Read the machine's capture off the DE25-Nano, over JTAG, into what
# `tools/probe_check.py` compares with muir.
#
#     make de25 PROBE_DEPTH=1024
#     make de25-program PROBE_DEPTH=1024
#     make de25-probe
#
# The last of which runs this as `quartus_stp -t` from the repository's root
# and then `tools/probe_check.py` on what it wrote.  It reads the bitstream in
# `build/de25-probe/`, or the one `DE25_BUILD` names, and writes the capture
# to `capture.csv` there, or to `CSV`.
#
# NOTHING HAS TO BE ARMED.  `rtl/plumbing/cadr_probe.sv` fills from the first
# microcycle after the machine's reset and freezes, so by the time the part is
# configured and this runs, the window has long been taken.  KEY1 takes a
# fresh one.
#
# THE PATH A SAMPLE TAKES, AND WHAT IS ASKED OF EACH PIECE OF IT BEFORE A
# SAMPLE IS BELIEVED.  Every line below that begins `PROBE:` and does not say
# FAILED is a measurement that held, and `tb/cadr_de25_jtag_tb.tcl` asserts
# the lines as well as the exit status, because a run that fails at the right
# check and one that limps on and fails later both exit 1.
#
#   1. The cable, by its serial, and the one part on its chain, by its
#      IDCODE: `jtag.tcl`.
#   2. The IDCODE read again by a raw scan, against the constant.  That is
#      the bit order of everything returned below.
#   3. The USERCODE, against the build stamp in this bitstream's assembler
#      report.  **A capture is evidence about the tree it was built from and
#      no other**, so a part holding any other build is refused: the capture
#      would be of a different machine from the one the file names.
#   4. The probe's node on the SLD hub, through Altera's Virtual JTAG.  Its
#      virtual instruction is one bit, 1 the sample register and 0 a bypass
#      bit, and `rtl/plumbing/agilex5/cadr_probe_vjtag.sv` makes both
#      readable.  In bypass, a 16-bit pattern must come back one bit late
#      behind the bypass register's captured 0: the one measurement of this
#      path's order and alignment that owes nothing to the probe.  Then the
#      instruction the node holds, captured by the next virtual IR scan, must
#      be the one shifted in, 0 and then 1.
#   5. The first sample must be valid and carry a cycle inside the buffer.
#      Then the whole buffer, one virtual DR scan a sample, rotated so that
#      cycle zero is first, exported as the Arty's `probe.tcl` exports it.
#
# THE SCAN COMMANDS' SHAPES WERE MEASURED ON THE BOARD, not taken from the
# help text, whose prose and example disagree about which end of a value
# string is shifted first.  A register comes back as a hexadecimal string
# with its first bit out at the right, least significant: the IDCODE reads
# `4362C0DD`.  A virtual IR scan returns the captured instruction as a
# number.
#
# **THE DEVICE STAYS LOCKED FROM THE FIRST SCAN TO THE LAST.**  A virtual IR
# scan selects the node until the device is unlocked, and another program
# selecting another node in between would turn the rest of the readout into
# somebody else's register.  Every way out unlocks and closes it.

source [file join [file dirname [file normalize [info script]]] jtag.tcl]

set root [file normalize [file join $::de25_quartus_dir .. .. ..]]
set build [expr {[info exists ::env(DE25_BUILD)] ? $::env(DE25_BUILD) : [file join $root build de25-probe]}]
set csv   [expr {[info exists ::env(CSV)] ? $::env(CSV) : [file join $build capture.csv]}]
set asm   [file join $build output_files cadr_de25.asm.rpt]
set syn   [file join $build output_files cadr_de25.syn.rpt]

set tag "PROBE:"

set opened 0
set locked 0
proc probe_fail {args} {
    foreach line $args { puts $line }
    if {$::locked} { catch {device_unlock} }
    if {$::opened} { catch {close_device} }
    exit 1
}

# ---------------------------------------------------------------- the layout
#
# THE SAME LIST `rtl/plumbing/cadr_probe.sv` CONCATENATES, in the same order,
# most significant field first, and the same list the Zynq boards' reader
# holds in `boards/arty-z7-20/vivado/probe.tcl`.  `tb/cadr_de25_jtag_tb.tcl`
# compares the two lists, so a change to one is a failure until the other
# follows; the Zynq boards' list is the one that has read silicon.
set fields {
    pc 14  ir 48  q 32  a 32  m 32  alu 32  r 32  ob 32  dc 10  opc 14
    st 32  lc 26  iwrited 1  nop 1  n_vmaok 1  jcond 1  pcs1 1  pcs0 1
    lpc 14  md 32  vma 32  promdis 1
}

set data_width 0
foreach {name w} $fields { incr data_width $w }
if {$data_width != 421} {
    probe_fail "$tag FAILED --- the field table adds to $data_width bits and the probe is 421."
}
# valid, cycle, data --- as the probe stores it.
set sample_width [expr {1 + 32 + $data_width}]
set cycle_lsb    $data_width
set valid_bit    [expr {$sample_width - 1}]

set offset [dict create]
set lsb $data_width
foreach {name w} $fields {
    set lsb [expr {$lsb - $w}]
    dict set offset $name $lsb
}

proc bits {value lsb width} {
    return [expr {($value >> $lsb) & ((1 << $width) - 1)}]
}

# ------------------------------------------------------------ the bitstream
#
# What the part must hold, and how deep the probe in it is, both from
# Quartus's own reports of this build.  The depth is the top level's
# parameter as synthesis records it, in binary.
set want [de25_built_usercode $asm]
if {$want eq ""} {
    probe_fail "$tag FAILED --- $asm names no USERCODE; build the probe first:" \
               "$tag   make de25 PROBE_DEPTH=1024"
}
set depth 0
if {[file readable $syn]} {
    set fh [open $syn]
    set text [read $fh]
    close $fh
    if {[regexp -line {^; PROBE_DEPTH +; ([01]+) +; Unsigned Binary +;} $text -> b]} {
        set depth 0
        foreach c [split $b ""] { set depth [expr {$depth * 2 + $c}] }
    }
}
if {$depth <= 0 || ($depth & ($depth - 1)) != 0} {
    probe_fail "$tag FAILED --- $syn gives the probe no depth that is a power of two ($depth);" \
               "$tag   this is not a probe build."
}
puts "$tag the bitstream is build $want, with a probe of $depth samples"

# ------------------------------------------------------ the cable and the part
lassign [de25_select_cable $tag] ok hw
if {!$ok} { probe_fail {*}$hw }
lassign [de25_select_part $tag $hw] ok dev
if {!$ok} { probe_fail {*}$dev }

open_device -hardware_name $hw -device_name $dev
set opened 1
device_lock -timeout 10000
set locked 1

lassign [de25_read_usercode $tag] ok held
if {!$ok} { probe_fail {*}$held }
if {$held ne $want} {
    probe_fail "$tag FAILED --- the part holds build $held and this bitstream is build $want." \
               "$tag   A capture is evidence about the build it was taken from, and the part" \
               "$tag   is not running this one. Program it first: make de25-program PROBE_DEPTH=$depth"
}
puts "$tag the part holds build $want, the bitstream's"

# ----------------------------------------------------------------- the node
#
# `device_virtual_ir_shift` refuses when no node has this index, which is
# what a bitstream without the probe gives, measured on the plain build.  The
# plain build and the probe's carry one stamp when they come from one tree, so
# the USERCODE check above cannot tell them apart and this is where the plain
# build is refused.
proc vir {value} {
    if {[catch {device_virtual_ir_shift -instance_index 0 -ir_value $value} cap]} {
        probe_fail "$::tag FAILED --- the virtual IR scan of node 0 was refused: $cap" \
                   "$::tag   The part holds a build of this tree with no Virtual JTAG node, which is" \
                   "$::tag   the plain build: it carries the same stamp. Load the probe's first:" \
                   "$::tag   make de25-program PROBE_DEPTH=$::depth"
    }
    return $cap
}
proc vdr {length hex} {
    return [string tolower [string trim \
        [device_virtual_dr_shift -instance_index 0 -length $length -dr_value $hex -value_in_hex]]]
}

vir 0
set pattern a53c
set back [vdr 16 $pattern]
# `set v 0x...` first: inside braces `0x$pattern` is not substituted before
# it is parsed, which the Zynq reader's `idval` notes too.
set pv 0x$pattern
set expect [format %04x [expr {($pv << 1) & 0xffff}]]
puts "$tag bypass: $pattern shifted in, $back back, wanting $expect"
if {$back ne $expect} {
    probe_fail "$tag FAILED --- a bypass scan returned $back where one bit of delay behind a" \
               "$tag   captured 0 gives $expect. The virtual DR path is not the length or the" \
               "$tag   order this script reads samples by, so no sample is read."
}
set held_ir [vir 1]
if {$held_ir != 0} {
    probe_fail "$tag FAILED --- the node held instruction $held_ir after 0 was shifted in."
}
set held_ir [vir 1]
if {$held_ir != 1} {
    probe_fail "$tag FAILED --- the node held instruction $held_ir after 1 was shifted in."
}
puts "$tag the node took instruction 0 and then 1: the sample register is selected"

# -------------------------------------------------------------- the samples
set zeros [string repeat 0 [expr {($sample_width + 3) / 4}]]
proc read_sample {} {
    set v 0x[vdr $::sample_width $::zeros]
    return [expr {$v & ((1 << $::sample_width) - 1)}]
}

set s [read_sample]
if {[bits $s $valid_bit 1] != 1 || [bits $s $cycle_lsb 32] >= $depth} {
    probe_fail "$tag FAILED --- the node and its bypass are as they should be, and the first" \
               "$tag   sample reads valid=[bits $s $valid_bit 1] cycle=[bits $s $cycle_lsb 32], which is" \
               "$tag   not a sample. raw = [format %0114llx $s]" \
               "$tag   The suspects: the machine retired no microcycle, or the probe's shift" \
               "$tag   register takes the wrong edge of TCK."
}
puts "$tag the first sample reads valid, at cycle [bits $s $cycle_lsb 32]"

set samples [list $s]
for {set j 1} {$j < $depth} {incr j} {
    lappend samples [read_sample]
}

device_unlock
set locked 0
close_device
set opened 0

# Rotate so that cycle zero is first.  DEPTH scans leave the pointer where it
# began, so where in the buffer the reading started does not matter.
set start -1
for {set j 0} {$j < $depth} {incr j} {
    set s [lindex $samples $j]
    if {[bits $s $valid_bit 1] && [bits $s $cycle_lsb 32] == 0} { set start $j }
}
if {$start < 0} {
    probe_fail "$tag FAILED --- no sample in the buffer carries cycle zero, so the capture is" \
               "$tag   not a window that begins at reset."
}
if {$start != 0} {
    puts "$tag the read pointer stood $start samples into the buffer; rotated"
}
set rows {}
set want_cycle 0
for {set j 0} {$j < $depth} {incr j} {
    set s [lindex $samples [expr {($start + $j) % $depth}]]
    if {![bits $s $valid_bit 1] || [bits $s $cycle_lsb 32] != $want_cycle} { break }
    lappend rows $s
    incr want_cycle
}
if {[llength $rows] != $depth} {
    puts "$tag NOTE --- [llength $rows] of $depth samples are a run from cycle zero, and only"
    puts "$tag   the run is exported."
}
if {[llength $rows] == 0} {
    probe_fail "$tag FAILED --- nothing to export"
}

# ----------------------------------------------------------------- the file
#
# The format `tools/probe_check.py` reads, with the three metadata lines its
# header calls load-bearing: the radix, the sample count and the trigger.
set fh [open $csv w]
puts $fh "Device: A5EB013BB23BE4SCS"
puts $fh "Design: cadr_de25, build $want, probe depth $depth"
puts $fh "Radix - HEX"
puts $fh "Buffer Sample Count: [llength $rows]"
puts $fh "Window Sample Count: [llength $rows]"
puts $fh "Trigger Position: 0"
set header [list "Sample in Buffer" TRIGGER cycle]
foreach {name w} $fields { lappend header $name }
puts $fh [join $header ","]
set n 0
foreach s $rows {
    set line [list [format %llx $n] [expr {$n == 0 ? 1 : 0}] \
                   [format %llx [bits $s $cycle_lsb 32]]]
    foreach {name w} $fields {
        lappend line [format %llx [bits $s [dict get $offset $name] $w]]
    }
    puts $fh [join $line ","]
    incr n
}
close $fh

puts "$tag wrote $csv --- $n samples, [expr {[llength $fields] / 2}] columns, from build $want"
exit 0
