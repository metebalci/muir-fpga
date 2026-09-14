# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Read the machine's capture off the Arty A7-100, over JTAG, into something
# `tools/probe_check.py` can diff against muir.
#
#     make build/boot_prom.hex build/rtl.golden
#     PROBE_DEPTH=1024 OUTDIR=build/a7-probe \
#         vivado -mode batch -source boards/arty-a7-100/vivado/bitstream.tcl
#     BIT=build/a7-probe/cadr_arty_a7.bit CABLE=<the cable's serial> \
#         vivado -mode batch -source boards/arty-a7-100/vivado/program.tcl
#     CABLE=<the cable's serial> PROBE_DEPTH=1024 OUTDIR=build/a7-probe \
#         vivado -mode batch -source boards/arty-a7-100/vivado/probe.tcl
#     python3 tools/probe_check.py --capture build/a7-probe/capture.csv \
#         --golden build/rtl.golden
#
# Run from the repository root.
#
# **NAME THE CABLE, ALWAYS.**  More than one board can be on one host's USB
# and a target taken by position is whichever the server enumerated first.
# `CABLE` has no default, for the same reason `tick.tcl` has no fallback
# period.
#
# NOTHING HAS TO BE ARMED AND NOBODY HAS TO BE AT THE BOARD.  The probe's
# trigger is reset: `rtl/plumbing/xilinx7/cadr_probe.sv` fills from the first
# microcycle after it and then freezes, so by the time a bitstream has been
# programmed and a readout arranged, the window --- the first microcycles the
# machine ever ran --- has long since been taken and cannot be overwritten.
# Pressing BTN1 takes a fresh one.
#
# WHY THIS IS RAW JTAG AND NOT A DEBUG CORE.  `create_debug_core` is refused by
# the licence on this host: `License_Tier:BASIC`, and Vivado answers
# "'create_debug_core' tcl command is not supported. Your current selected
# license is BASIC". The ILA IP core does generate at BASIC and is the
# directory of generated XML this project has decided against, so the probe is
# a `BSCANE2` and a shift register, and this is the other half of it: one DR
# scan a sample, USER1 selected, the pointer advancing on each CAPTURE.
#
# **THE CHAIN IS ONE DEVICE, WHERE THE ARTY Z7-20's IS TWO, AND THAT IS THE
# ONE THING THAT HAD TO CHANGE.**  A Zynq presents the ARM debug access port
# beside the part, so an IR scan there has to place USER1 in one device and
# BYPASS in the other, and a DR scan comes back with the other device's bypass
# bit behind the sample. An Artix-7 has no such companion: the part is the
# whole chain, the instruction register is its own six bits and a DR scan is
# the sample and nothing else. **So the padding on this board is zero in both
# directions, and this script still COMPUTES it rather than writing it down.**
# That is not ceremony. A constant zero would be right until the day somebody
# put a second device on the cable or read this file on a different board, and
# it would then be wrong silently; the computation is wrong loudly, at the
# device-count check, before a sample is read.
#
# AND WHERE THE NUMBERS COME FROM. **Vivado ships the BSDL and it is the
# authority**:
#
#   <Vivado>/data/parts/xilinx/artix7/public/bsdl/xc7a100t_csg324.bsd
#
# INSTRUCTION_LENGTH 6, USER1 000010, BYPASS 111111, INSTRUCTION_CAPTURE
# XXXX01 --- with its own comment that "bit 5 is 1 when DONE is released" ---
# and IDCODE_REGISTER `XXXX 0011011 000110001 00001001001 1`, which is
# 0x_3631093 with the version nibble masked off. Each of those is asserted
# below and each is checked against the board before a sample is read: the
# IDCODE scan says the chain is that one device, and the instruction
# register's own capture pattern says it is the six bits the BSDL says it is.
# A board that is not that chain fails on the check that names it, not on a
# sample of zeros.
#
# **A SEARCH OVER IR LENGTHS IS A GUESS DRESSED AS ROBUSTNESS.** The other
# board's script used to try 3 to 12 bits of padding until a sample came back
# valid. When every one of them failed it could say only that --- not which
# had been right, which is the thing worth knowing, and not that the padding
# was never what was wrong.
#
# WHAT IT HAS NOT BEEN RUN AGAINST.  This board. Everything the probe itself
# does is checked in simulation by `tb/cadr_probe_tb.cpp`, which shifts all
# 1,024 samples out through the probe's own shift register and compares every
# column against `build/rtl.golden`; and the machinery here is the Arty
# Z7-20's, which has read a real capture off a real part. What is untried is
# this chain, this part's IR capture, and this board at all.

set url    [expr {[info exists ::env(BOARD_URL)] ? $::env(BOARD_URL) : "localhost:3121"}]
set outdir [expr {[info exists ::env(OUTDIR)]    ? $::env(OUTDIR)    : "build/a7-probe"}]
set depth  [expr {[info exists ::env(PROBE_DEPTH)] ? $::env(PROBE_DEPTH) : 1024}]
set csv    [expr {[info exists ::env(CSV)] ? $::env(CSV) : "$outdir/capture.csv"}]
set cable  [expr {[info exists ::env(CABLE)] ? $::env(CABLE) : ""}]
file mkdir $outdir

# ---------------------------------------------------------------- the layout
#
# THE SAME LIST `rtl/plumbing/xilinx7/cadr_probe.sv` CONCATENATES, in the same
# order, most significant field first --- and the same list
# `tb/cadr_probe_tb.cpp` holds, and the same list the other board's reader
# holds. Four readings of one order is three too many, and the only thing that
# keeps them together is that a disagreement shows up as a capture that
# disagrees with muir on every row: the check in `tb/` is what catches it
# before a board ever does.
#
# The names are the trace's own columns, so `tools/probe_check.py` resolves
# them without a mapping.
set fields {
    pc 14  ir 48  q 32  a 32  m 32  alu 32  r 32  ob 32  dc 10  opc 14
    st 32  lc 26  iwrited 1  nop 1  n_vmaok 1  jcond 1  pcs1 1  pcs0 1
    lpc 14  md 32  vma 32  promdis 1
}

set data_width 0
foreach {name w} $fields { incr data_width $w }
if {$data_width != 421} {
    puts "PROBE: FAILED --- the field table adds to $data_width bits and the"
    puts "PROBE: probe is 421. One of the copies of this list has moved;"
    puts "PROBE: rtl/plumbing/xilinx7/cadr_probe.sv is the one that decides."
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

# ------------------------------------------------------------------ helpers

proc hexof {value nbits} {
    set digits [expr {($nbits + 3) / 4}]
    # `%llx` AND NOT `%x`. Tcl carries integers at arbitrary precision and
    # `format %x` truncates them to 64 bits without saying so: a 454-bit sample
    # formats as its bottom sixteen hex digits and every scan after it is of a
    # different length than it says. Measured, in an afternoon, on the other
    # board.
    return [format %0${digits}llx $value]
}

# EVERY EXIT PATH CLOSES THE MANAGER. One thing at a time may hold a board's
# JTAG, so a run that dies with a target open makes the next run's failure
# somebody else's puzzle.
proc probe_fail {args} {
    foreach line $args { puts $line }
    catch {close_hw_target}
    catch {close_hw_manager}
    exit 1
}

if {$cable eq ""} {
    puts "PROBE: FAILED --- CABLE is not set, and this script will not guess."
    puts "PROBE: More than one board can be on one host's USB. Pass the JTAG"
    puts "PROBE: cable's serial number, which is what get_hw_targets names the"
    puts "PROBE: target by."
    exit 1
}

# ------------------------------------------------------ the documented chain
#
# Keyed on IDCODE with the version nibble masked off, because that nibble is
# silicon revision and this does not care which. Everything in the value is
# quoted from the BSDL named in the header: the instruction register length,
# and the two bits of its capture pattern that IEEE 1149.1 fixes at 01 in
# every device that conforms to it.
#
#                                       name           irlen cap-mask cap
set device_spec [dict create \
    03631093 {xc7a100t                       6      0x03 0x01} ]

# The part, and USER1 within it.
set part_idcode 0x13631093
set user1       0x02

# ------------------------------------------------------------- the hardware

open_hw_manager
connect_hw_server -url $url
puts "PROBE: connected to $url"

set targets [get_hw_targets -quiet]
if {[llength $targets] == 0} {
    probe_fail \
        "PROBE: FAILED --- the server connected and offered no targets." \
        "PROBE: That is the udev rules, not the network. docs/board.md has them."
}
puts "PROBE: the server offers [llength $targets] target(s): [join $targets {, }]"
set matched {}
foreach t $targets {
    if {[string first $cable $t] >= 0} { lappend matched $t }
}
if {[llength $matched] != 1} {
    probe_fail \
        "PROBE: FAILED --- [llength $matched] of the targets above carry the" \
        "PROBE: serial $cable. Exactly one is wanted: none means the board is" \
        "PROBE: unplugged or somebody else's hw_server holds it, and more than" \
        "PROBE: one means the serial is a prefix of two."
}
current_hw_target [lindex $matched 0]

# THE HARDWARE MANAGER IS THE AUTHORITY ON HOW MANY DEVICES THERE ARE. The raw
# scan below is the authority on where they sit and how wide their registers
# are, and it cannot count them on its own --- see the next section for what
# happened when it was asked to. The two are checked against each other.
open_hw_target
set seen {}
set ndevices 0
foreach d [get_hw_devices] {
    lappend seen "$d (part [get_property -quiet PART $d])"
    incr ndevices
}
puts "PROBE: the hardware manager sees $ndevices device(s): [join $seen {, }]"
close_hw_target

# ------------------------------------------------------------- the raw chain
#
# In JTAG mode Vivado stops knowing about devices and shifts what it is told
# through the whole chain, which is what talking to a BSCANE2 requires.
#
# A TAP reset leaves every device with IDCODE in its data register, or, for a
# device that has no IDCODE register, a single bypass bit reading zero. So a
# long DR scan reads the chain out: a 1 begins a 32-bit IDCODE, a 0 is one
# bypass bit. The order is from the TDO end back towards TDI, which is also the
# order the IR word wants its fields in.
#
# **TDI IS DRIVEN WITH ONES.** What ends the chain is TDI coming back out
# behind the last device, so the scan is self-terminating only if TDI is driven
# with something that is neither an IDCODE nor a bypass bit. All ones is both:
# 0xffffffff is not a legal IDCODE, and a run of ones cannot be read as bypass
# devices. Driven with zeros it counts its own padding as devices, which is
# what the other board's script did on its first run against silicon: 256 bits,
# the real IDCODEs at the front and the zeros behind them read as 192 more
# devices, and the IR scan then 778 bits where the chain wanted 10. An
# over-long IR scan keeps only its last bits, so USER1 was never selected in
# anything and every sample read back as a bypass bit.
open_hw_target -jtag_mode 1

run_state_hw_jtag RESET
set scan_len 256
set idraw [scan_dr_hw_jtag $scan_len -tdi [string repeat f [expr {$scan_len / 4}]]]
puts "PROBE: IDCODE scan, $scan_len bits, TDI all ones: $idraw"
# A hex string with its prefix is an integer literal, and Tcl carries it at
# arbitrary precision. `expr {0x$idraw}` is not the same thing and is a syntax
# error: inside braces there is no substitution before parsing.
set idval 0x$idraw

set chain {}          ;# {code name irlen cap_mask cap_value} from the TDO end
set i 0
set terminated 0
while {$i < $scan_len} {
    if {![bits $idval $i 1]} {
        # A bypass bit. The one device documented above has none after a TAP
        # reset --- it carries IDCODE --- so this is not our chain.
        probe_fail \
            "PROBE: FAILED --- bit $i of the IDCODE scan is a bypass bit, so a" \
            "PROBE: device in this chain has no IDCODE register. The Artix-7" \
            "PROBE: this board carries has one, and it is meant to be alone in" \
            "PROBE: the chain. Scan: $idraw"
    }
    if {$i + 32 > $scan_len} {
        probe_fail \
            "PROBE: FAILED --- an IDCODE begins at bit $i and runs off the end" \
            "PROBE: of a $scan_len-bit scan. Raise scan_len. Scan: $idraw"
    }
    set code [bits $idval $i 32]
    if {$code == 0xffffffff} { set terminated 1; break }
    set key [format %08x [expr {$code & 0x0fffffff}]]
    if {![dict exists $device_spec $key]} {
        probe_fail \
            "PROBE: FAILED --- IDCODE [format 0x%08x $code] at bit $i is not a" \
            "PROBE: device this script has a BSDL for. Its instruction register" \
            "PROBE: length is therefore unknown and no padding can be computed." \
            "PROBE: Scan: $idraw"
    }
    lappend chain [concat [list $code] [dict get $device_spec $key]]
    incr i 32
}
if {!$terminated} {
    probe_fail \
        "PROBE: FAILED --- the $scan_len-bit IDCODE scan never reached its" \
        "PROBE: all-ones tail, so the chain is longer than the scan and what" \
        "PROBE: was parsed is a prefix of it. Raise scan_len. Scan: $idraw"
}

set names {}
foreach entry $chain {
    lappend names [format "%s/0x%08x" [lindex $entry 1] [lindex $entry 0]]
}
puts "PROBE: the scan reads, from the TDO end: [join $names {, }]"

# THE TWO COUNTS MUST AGREE. If they do not, one of them is inventing devices
# and the padding below would be computed from whichever it was.
#
# AND THIS IS ALSO THE BIT-ORDER DETECTOR, which was not why it was written.
# Measured on the other board at `4e4fccb`: a scan returned most significant
# bit first puts the all-ones tail at the bottom, so the parser terminates
# immediately and reports zero devices, and it dies here. The IR capture below
# names a reversed scan as one of its suspects and will never see one ---
# every reversal is caught at this line, four checks earlier.
if {[llength $chain] != $ndevices} {
    probe_fail \
        "PROBE: FAILED --- the IDCODE scan found [llength $chain] device(s) and the" \
        "PROBE: hardware manager found $ndevices. Scan: $idraw"
}

# Which of them is ours.
set mine -1
set pos 0
foreach entry $chain {
    if {([lindex $entry 0] & 0x0fffffff) == ($part_idcode & 0x0fffffff)} {
        if {$mine >= 0} {
            probe_fail \
                "PROBE: FAILED --- two xc7a100ts in the chain, at $mine and $pos." \
                "PROBE: The probe is in one of them and this cannot say which."
        }
        set mine $pos
    }
    incr pos
}
if {$mine < 0} {
    probe_fail "PROBE: FAILED --- no xc7a100t in the chain: [join $names {, }]"
}

# Devices between ours and TDO, each contributing one bypass bit in front of
# the sample in every DR scan, and those behind it contributing one each after.
# `chain` is ordered from the TDO end, so this is a count of positions.
#
# **ON THIS BOARD BOTH ARE ZERO**, the part being the whole chain, and the
# script says so out loud rather than assuming it: a line reading "0 bypass
# bit(s) in front and 0 behind" is the measurement that the chain is what this
# board is supposed to be.
set after  $mine
set before [expr {[llength $chain] - $mine - 1}]
puts "PROBE: ours is $mine from the TDO end, so a DR scan carries $after bypass\
 bit(s) in front of the sample and $before behind"

# ------------------------------------------------------------ the instruction
#
# THE LENGTH IS DOCUMENTED AND ASSERTED, NOT SWEPT --- 6 bits, from the BSDL
# named in the header.
#
# WHAT IS MEASURED IS THE TOTAL. On entry to Capture-IR every conforming device
# loads a fixed pattern whose bottom two bits IEEE 1149.1 requires to be 01, so
# an IR scan of exactly the right length reads back a 01 at the bottom of each
# device's field and nowhere else. That single scan is a direct measurement of
# three things this script would otherwise assume: the chain's instruction
# register length, the order of the devices in it, and Vivado's bit order in a
# returned scan value. It is taken before anything depends on any of them, and
# it is taken with BYPASS shifted in, which is the one instruction the device
# is documented as safe to hold.
set ir_total   0
set cap_mask   0
set cap_expect 0
set our_ir_lsb 0
set pos 0
foreach entry $chain {
    lassign $entry code name irlen cmask cval
    if {$pos == $mine} { set our_ir_lsb $ir_total }
    set cap_mask   [expr {$cap_mask   | ($cmask << $ir_total)}]
    set cap_expect [expr {$cap_expect | ($cval  << $ir_total)}]
    incr ir_total $irlen
    incr pos
}

run_state_hw_jtag RESET
set ircap 0x[scan_ir_hw_jtag $ir_total -tdi [hexof [expr {(1 << $ir_total) - 1}] $ir_total]]
puts "PROBE: the $ir_total-bit instruction register captures\
 [hexof $ircap $ir_total], wanting [hexof $cap_expect $ir_total] under mask\
 [hexof $cap_mask $ir_total]"
if {($ircap & $cap_mask) != $cap_expect} {
    probe_fail \
        "PROBE: FAILED --- the instruction register does not capture 01 at the" \
        "PROBE: bottom of each device's field, so the chain is not the" \
        "PROBE: $ir_total bits the BSDL says it is. A reversed bit order would" \
        "PROBE: have died at the device-count check above and cannot reach" \
        "PROBE: here --- measured, at 4e4fccb on the other board, so do not go" \
        "PROBE: looking for one." \
        "PROBE: Nothing below this line would mean anything, so it stops here."
}
# Bit 5 of the capture is DONE --- "1 when DONE is released", says the BSDL.
# Free evidence, on the way past, that the part is configured.
puts "PROBE: the part's IR capture reads DONE =\
 [bits $ircap [expr {$our_ir_lsb + 5}] 1]"

# USER1 in ours, BYPASS in the rest. LSB first is the TDO end, which is the
# order `chain` is already in.
set word 0
set at   0
set pos  0
foreach entry $chain {
    lassign $entry code name irlen cmask cval
    if {$pos == $mine} {
        set word [expr {$word | ($user1 << $at)}]
    } else {
        set word [expr {$word | (((1 << $irlen) - 1) << $at)}]
    }
    incr at $irlen
    incr pos
}
scan_ir_hw_jtag $ir_total -tdi [hexof $word $ir_total]
puts "PROBE: USER1 selected: IR = [hexof $word $ir_total]"

# ------------------------------------------------------------- one sample
#
# One DR scan: the whole chain's registers, of which ours is the middle --- and
# on this board the whole of it.
proc read_sample {after before sample_width} {
    set total [expr {$sample_width + $after + $before}]
    set raw [scan_dr_hw_jtag $total -tdi [hexof 0 $total]]
    set v 0x$raw
    return [expr {($v >> $after) & ((1 << $sample_width) - 1)}]
}

# THE FIRST SAMPLE IS THE CHECK ON EVERYTHING ABOVE. Valid, and a cycle inside
# the buffer --- not `cycle == 0`: where in the buffer the reading starts does
# not matter, because the rotation below puts cycle zero first.
set s [read_sample $after $before $sample_width]
if {[bits $s $valid_bit 1] != 1 || [bits $s $cycle_lsb 32] >= $depth} {
    probe_fail \
        "PROBE: FAILED --- the chain and the instruction register are the ones" \
        "PROBE: the BSDL documents and USER1 is selected, and the first sample" \
        "PROBE: still reads back valid=[bits $s $valid_bit 1]" \
        "PROBE: cycle=[bits $s $cycle_lsb 32], which is not a sample." \
        "PROBE: raw = [hexof $s $sample_width]" \
        "PROBE: With the chain proved, the suspects are, in order: the" \
        "PROBE: bitstream in the part has no probe in it --- PROBE_DEPTH was" \
        "PROBE: zero; the machine has retired no microcycle; the shift" \
        "PROBE: register in rtl/plumbing/xilinx7/cadr_probe.sv clocks the wrong" \
        "PROBE: edge of DRCK. None of those is fixable here: this is the reader."
}
puts "PROBE: the first sample reads valid, at cycle [bits $s $cycle_lsb 32]"

# ------------------------------------------------------------- the readout
#
# DEPTH scans return the whole buffer and leave the pointer where they found
# it, so where in the buffer the reading starts does not matter: each sample
# carries its own cycle and the rotation is undone below. The sample already
# read above is one of them and is kept, so the run is DEPTH scans in total and
# the pointer ends where it began.
set samples [list $s]
for {set j 1} {$j < $depth} {incr j} {
    lappend samples [read_sample $after $before $sample_width]
}

# Rotate so that cycle zero is first, and drop what the probe never reached: an
# entry the machine did not fill has its valid bit clear.
set start -1
for {set j 0} {$j < $depth} {incr j} {
    set s [lindex $samples $j]
    if {[bits $s $valid_bit 1] && [bits $s $cycle_lsb 32] == 0} { set start $j }
}
if {$start < 0} {
    probe_fail \
        "PROBE: FAILED --- no sample in the buffer carries cycle zero." \
        "PROBE: The capture is not a window that begins at reset, which is the" \
        "PROBE: one thing it is for. A machine reset while this was reading" \
        "PROBE: would do it; so would a readout of the wrong core."
}
if {$start != 0} {
    puts "PROBE: the read pointer stood $start samples into the buffer; rotated"
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
    puts "PROBE: cycle zero. The rest are unfilled or out of sequence, and only"
    puts "PROBE: the run is exported."
}
if {[llength $rows] == 0} {
    probe_fail "PROBE: FAILED --- nothing to export"
}

close_hw_target
close_hw_manager

# ----------------------------------------------------------------- the file
#
# WHAT `tools/probe_check.py` READS.  Its own header says it takes metadata
# lines, a header line naming trace columns, and one row a sample oldest first.
# Three of those metadata lines are load-bearing and are written here
# deliberately:
#
#   Radix - HEX            an undeclared radix is assumed hexadecimal and
#                          announced, and a capture exported decimal would then
#                          pass quietly. Declared, it cannot.
#   Buffer Sample Count    a readout that stopped early is a truncated file,
#                          which the tool must be able to tell from a buffer
#                          that is simply short.
#   Trigger Position: 0    with the TRIGGER column below, this is the export
#                          saying where it thinks its window begins. The
#                          capture's own `cycle` column is the proof; this is
#                          the claim, and the tool checks the two against each
#                          other.
set fh [open $csv w]
puts $fh "Device: xc7a100t_0"
puts $fh "Design: cadr_arty_a7, probe depth $depth"
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
