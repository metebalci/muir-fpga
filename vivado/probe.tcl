# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Read the machine's capture off the board, over JTAG, into something
# `tools/probe_check.py` can diff against muir.
#
#     PROBE_DEPTH=1024 OUTDIR=build/probe \
#         vivado -mode batch -source vivado/bitstream.tcl
#     BIT=build/probe/cadr_arty.bit BOARD_URL=<host>:3121 \
#         vivado -mode batch -source vivado/program.tcl
#     BOARD_URL=<host>:3121 vivado -mode batch -source vivado/probe.tcl
#     python3 tools/probe_check.py --capture build/probe/capture.csv \
#         --golden build/rtl.golden
#
# Run from the repository root. The board need not be on this machine;
# `docs/board.md` has the arrangement and the udev rules whose absence looks
# like a network fault.
#
# NOTHING HAS TO BE ARMED AND NOBODY HAS TO BE AT THE BOARD.  The probe's
# trigger is reset: `rtl/cadr_probe.sv` fills from the first microcycle
# after it and then freezes, so by the time a bitstream has been programmed
# and a readout arranged, the window --- the first microcycles the machine
# ever ran --- has long since been taken and cannot be overwritten. Pressing
# BTN0 takes a fresh one.
#
# WHY THIS IS RAW JTAG AND NOT A DEBUG CORE.  `create_debug_core` is refused
# by the licence on this host: `License_Tier:BASIC` in `~/.Xilinx/Xilinx.lic`,
# and Vivado answers "'create_debug_core' tcl command is not supported. Your
# current selected license is BASIC". The ILA IP core does generate at BASIC
# and is the directory of generated XML this project has decided against, so
# the probe is a BSCANE2 and a shift register, and this is the other half of
# it: one DR scan a sample, USER1 selected, the pointer advancing on each
# CAPTURE.
#
# WHAT IT DOES NOT ASSUME.  The chain.  A Zynq presents the ARM debug access
# port as well as the part, so an IR scan has to place USER1 in one device and
# BYPASS in the other, and a DR scan comes back with the other device's bypass
# bit in front of the sample. Both are discovered rather than assumed: the
# chain is read out of the IDCODE scan a TAP reset leaves behind, and the IR
# padding is *tried* against a sample whose first bits are known --- a set
# valid bit and a cycle of zero --- and reported. A guess that fails here
# fails loudly on the first sample instead of quietly on all of them.
#
# WHAT IT HAS NOT BEEN RUN AGAINST.  A board. Everything above this line is
# checked in simulation by `tb/cadr_probe_tb.cpp`, which shifts all 1,024
# samples out through the probe's own shift register and compares every column
# against `build/rtl.golden`. What no simulation reaches is the chain, the
# padding, and Vivado's own bit order in a returned scan --- which is why
# each of those is checked here against something the capture itself says
# rather than trusted.

set url    [expr {[info exists ::env(BOARD_URL)] ? $::env(BOARD_URL) : "localhost:3121"}]
set outdir [expr {[info exists ::env(OUTDIR)]    ? $::env(OUTDIR)    : "build/probe"}]
set depth  [expr {[info exists ::env(PROBE_DEPTH)] ? $::env(PROBE_DEPTH) : 1024}]
set csv    [expr {[info exists ::env(CSV)] ? $::env(CSV) : "$outdir/capture.csv"}]
file mkdir $outdir

# ---------------------------------------------------------------- the layout
#
# THE SAME LIST `rtl/cadr_probe.sv` CONCATENATES, in the same order, most
# significant field first --- and the same list `tb/cadr_probe_tb.cpp`
# holds. Three readings of one order is two too many, and the only thing that
# keeps them together is that a disagreement shows up as a capture that
# disagrees with muir on every row: the check in `tb/` is what catches it
# before a board ever does.
#
# The names are the trace's own columns, so `tools/probe_check.py` resolves them
# without a mapping.
set fields {
    pc 14  ir 48  q 32  a 32  m 32  alu 32  r 32  ob 32  dc 10  opc 14
    st 32  lc 26  iwrited 1  nop 1  n_vmaok 1  jcond 1  pcs1 1  pcs0 1
    lpc 14  md 32  vma 32  promdis 1
}

set data_width 0
foreach {name w} $fields { incr data_width $w }
if {$data_width != 421} {
    puts "PROBE: FAILED --- the field table adds to $data_width bits and the"
    puts "PROBE: probe is 421. One of the three copies of this list has"
    puts "PROBE: moved; rtl/cadr_probe.sv is the one that decides."
    exit 1
}
# valid, cycle, data --- as the probe stores it.
set sample_width [expr {1 + 32 + $data_width}]
set cycle_lsb    $data_width
set valid_bit    [expr {$sample_width - 1}]

# Bit offsets, walked once from the top so that nothing is transcribed.
set offset [dict create]
set width  [dict create]
set lsb $data_width
foreach {name w} $fields {
    set lsb [expr {$lsb - $w}]
    dict set offset $name $lsb
    dict set width  $name $w
}

proc bits {value lsb width} {
    # Tcl's integers are arbitrary precision, which is the whole reason a
    # 454-bit sample can be handled as a number at all.
    return [expr {($value >> $lsb) & ((1 << $width) - 1)}]
}

# ------------------------------------------------------------- the hardware

open_hw_manager
connect_hw_server -url $url
puts "PROBE: connected to $url"

set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
    puts "PROBE: FAILED --- the server connected and offered no targets."
    puts "PROBE: That is the udev rules, not the network. docs/board.md has them."
    exit 1
}
current_hw_target [lindex $targets 0]

# The chain as the hardware manager sees it, for the report. It is not what
# the scan below relies on --- that discovers its own --- but a disagreement
# between the two is worth seeing.
open_hw_target
set seen {}
foreach d [get_hw_devices] {
    lappend seen "$d (part [get_property -quiet PART $d])"
}
puts "PROBE: the hardware manager sees: [join $seen {, }]"
close_hw_target

# ------------------------------------------------------------- the raw chain
#
# In JTAG mode Vivado stops knowing about devices and shifts what it is told
# through the whole chain, which is what talking to a BSCANE2 requires.
open_hw_target -jtag_mode 1

# A TAP reset leaves every device with IDCODE in its data register, or, for a
# device that has no IDCODE register, a single bypass bit reading zero. So a
# long DR scan reads the chain out: a 1 begins a 32-bit IDCODE, a 0 is one
# bypass bit. The order is from the TDO end back towards TDI, which is also
# the order the IR word wants its fields in.
run_state_hw_jtag RESET
set scan_len 256
set idraw [scan_dr_hw_jtag $scan_len -tdi [string repeat 0 [expr {$scan_len / 4}]]]
# A hex string with its prefix is an integer literal, and Tcl carries it at
# arbitrary precision. `expr {0x$idraw}` is not the same thing and is a
# syntax error: inside braces there is no substitution before parsing.
set idval 0x$idraw

set chain {}          ;# list of {kind idcode} from the TDO end
set i 0
while {$i < $scan_len} {
    if {[bits $idval $i 1]} {
        if {$i + 32 > $scan_len} { break }
        set code [bits $idval $i 32]
        # An all-ones word is the end of the chain: nothing is driving TDO.
        if {$code == 0xffffffff} { break }
        lappend chain [list idcode $code]
        incr i 32
    } else {
        lappend chain [list bypass 0]
        incr i 1
    }
}
if {[llength $chain] == 0} {
    puts "PROBE: FAILED --- the IDCODE scan found no devices. The cable is"
    puts "PROBE: there and the chain is not, which is a board that is not"
    puts "PROBE: powered or a target that belongs to something else."
    exit 1
}

# Which of them is ours.
set part_idcode 0x23727093
set mine -1
set pos 0
foreach entry $chain {
    if {[lindex $entry 0] eq "idcode"
        && ([lindex $entry 1] & 0x0fffffff) == ($part_idcode & 0x0fffffff)} {
        set mine $pos
    }
    incr pos
}
if {$mine < 0} {
    set names {}
    foreach entry $chain { lappend names [format %s/%08x [lindex $entry 0] [lindex $entry 1]] }
    puts "PROBE: FAILED --- no xc7z020 in the chain: [join $names {, }]"
    exit 1
}
# Devices between ours and TDO. Each contributes one bypass bit in front of
# the sample in every DR scan.
set after $mine
set before [expr {[llength $chain] - $mine - 1}]
puts "PROBE: [llength $chain] devices; ours is $mine from the TDO end,\
 so a DR scan carries $after bit(s) in front of the sample and $before behind"

# ------------------------------------------------------------ the IR padding
#
# USER1 is 0x02 on a 7-series part and BYPASS is all ones on every JTAG device
# ever made. What is not known here is how many bits of BYPASS the other
# devices want --- the ARM debug access port is four on a Zynq-7000 and this
# does not take that on trust. It tries, and the sample says which try was
# right: a real sample has its valid bit set and the first one read has a
# cycle of zero.
set our_ir_len 6
set user1 0x02

proc ir_word {chain mine our_ir_len user1 other_len} {
    # LSB first is the TDO end, which is the order `chain` is already in.
    set word 0
    set at 0
    set pos 0
    foreach entry $chain {
        if {$pos == $mine} {
            set word [expr {$word | ($user1 << $at)}]
            incr at $our_ir_len
        } else {
            set word [expr {$word | (((1 << $other_len) - 1) << $at)}]
            incr at $other_len
        }
        incr pos
    }
    return [list $word $at]
}

proc hexof {value nbits} {
    set digits [expr {($nbits + 3) / 4}]
    # `%llx` AND NOT `%x`. Tcl carries integers at arbitrary precision and
    # `format %x` truncates them to 64 bits without saying so: a 454-bit
    # sample formats as its bottom sixteen hex digits and every scan after it
    # is of a different length than it says. Measured, in an afternoon.
    return [format %0${digits}llx $value]
}

# One DR scan: the whole chain's registers, of which ours is the middle.
proc read_sample {after before sample_width} {
    set total [expr {$sample_width + $after + $before}]
    set raw [scan_dr_hw_jtag $total -tdi [hexof 0 $total]]
    set v 0x$raw
    return [expr {($v >> $after) & ((1 << $sample_width) - 1)}]
}

set other_len 0
set chosen -1
if {[llength $chain] == 1} {
    set chosen 0
} else {
    foreach try {4 5 6 8 3 10 12} {
        run_state_hw_jtag RESET
        lassign [ir_word $chain $mine $our_ir_len $user1 $try] word irlen
        scan_ir_hw_jtag $irlen -tdi [hexof $word $irlen]
        set s [read_sample $after $before $sample_width]
        # Valid, and a cycle inside the buffer --- not `cycle == 0`. A trial
        # that selects USER1 in our device while mis-padding another one has
        # already advanced the read pointer, so insisting on zero here would
        # make the first wrong guess poison every guess after it. Where in the
        # buffer the reading starts does not matter: the rotation below puts
        # cycle zero first.
        if {[bits $s $valid_bit 1] == 1 && [bits $s $cycle_lsb 32] < $depth} {
            set chosen $try
            break
        }
    }
    if {$chosen < 0} {
        puts "PROBE: FAILED --- no IR padding of 3 to 12 bits for the other"
        puts "PROBE: device(s) produced a sample with its valid bit set and a"
        puts "PROBE: cycle inside the buffer. Either the bitstream in the part"
        puts "PROBE: has no probe in it --- PROBE_DEPTH was zero --- or"
        puts "PROBE: the machine has not run a microcycle, or the chain is not"
        puts "PROBE: the two devices docs/board.md describes."
        exit 1
    }
    puts "PROBE: the other device(s) take $chosen bits of BYPASS; a sample"
    puts "PROBE: reads back valid, at a cycle inside the buffer"
}

# Re-select, so that the run below starts from a known pointer: the trial
# above consumed samples.
run_state_hw_jtag RESET
lassign [ir_word $chain $mine $our_ir_len $user1 $chosen] word irlen
if {$irlen > 0} { scan_ir_hw_jtag $irlen -tdi [hexof $word $irlen] }

# ------------------------------------------------------------- the readout
#
# DEPTH scans return the whole buffer and leave the pointer where they found
# it, so where in the buffer the reading starts does not matter: each sample
# carries its own cycle and the rotation is undone below.
set samples {}
for {set j 0} {$j < $depth} {incr j} {
    lappend samples [read_sample $after $before $sample_width]
}

# Rotate so that cycle zero is first, and drop what the probe never
# reached: an entry the machine did not fill has its valid bit clear.
set start -1
for {set j 0} {$j < $depth} {incr j} {
    set s [lindex $samples $j]
    if {[bits $s $valid_bit 1] && [bits $s $cycle_lsb 32] == 0} { set start $j }
}
if {$start < 0} {
    puts "PROBE: FAILED --- no sample in the buffer carries cycle zero."
    puts "PROBE: The capture is not a window that begins at reset, which is"
    puts "PROBE: the one thing it is for. A machine reset while this was"
    puts "PROBE: reading would do it; so would a readout of the wrong core."
    exit 1
}
if {$start != 0} {
    puts "PROBE: the read pointer stood $start samples into the buffer;\
 rotated"
}

set ordered {}
for {set j 0} {$j < $depth} {incr j} {
    lappend ordered [lindex $samples [expr {($start + $j) % $depth}]]
}

# The contiguous run from cycle zero, and no further. A partial capture is a
# machine that stopped, and it is worth exporting what it did do.
set rows {}
set want 0
foreach s $ordered {
    if {![bits $s $valid_bit 1]} { break }
    if {[bits $s $cycle_lsb 32] != $want} { break }
    lappend rows $s
    incr want
}
if {[llength $rows] != $depth} {
    puts "PROBE: NOTE --- [llength $rows] of $depth samples are a run from"
    puts "PROBE: cycle zero. The rest are unfilled or out of sequence, and"
    puts "PROBE: only the run is exported."
}
if {[llength $rows] == 0} {
    puts "PROBE: FAILED --- nothing to export"
    exit 1
}

close_hw_target
close_hw_manager

# ----------------------------------------------------------------- the file
#
# WHAT `tools/probe_check.py` READS.  Its own header says it takes metadata
# lines, a header line naming trace columns, and one row a sample oldest
# first. Three of those metadata lines are load-bearing and are written here
# deliberately:
#
#   Radix - HEX            an undeclared radix is assumed hexadecimal and
#                          announced, and a capture exported decimal would
#                          then pass quietly. Declared, it cannot.
#   Buffer Sample Count    a readout that stopped early is a truncated file,
#                          which the tool must be able to tell from a buffer
#                          that is simply short.
#   Trigger Position: 0    with the TRIGGER column below, this is the export
#                          saying where it thinks its window begins. The
#                          capture's own `cycle` column is the proof; this is
#                          the claim, and the tool checks the two against each
#                          other.
set fh [open $csv w]
puts $fh "Device: xc7z020_1"
puts $fh "Design: cadr_arty, probe depth $depth"
puts $fh "Radix - HEX"
puts $fh "Buffer Sample Count: [llength $rows]"
puts $fh "Window Sample Count: [llength $rows]"
puts $fh "Trigger Position: 0"

# `list` and not a braced literal: "Sample in Buffer" is one column with two
# spaces in it, and a braced list would make it three.
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

puts "PROBE: wrote $csv --- $n samples, [expr {[llength $fields] / 2}] columns"
puts "PROBE: now: python3 tools/probe_check.py --capture $csv --golden build/rtl.golden"
