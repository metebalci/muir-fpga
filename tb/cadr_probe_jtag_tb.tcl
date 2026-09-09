# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# `vivado/probe.tcl`, run against `tb/cadr_jtag_chain.tcl`, on seven chains.
# No board, no Vivado, no bitstream: `tclsh tb/cadr_probe_jtag_tb.tcl`, 80 ms.
#
#     make build/probe_jtag.pass
#
# WHAT THIS HOLDS THE SCRIPT TO.  Not the exit code. `vivado/probe.tcl`'s own
# header claims that "a board that is not that chain fails on the check that
# names it, not on a sample of zeros", and an exit code cannot tell those
# apart --- a chain that fails at the right place and one that limps on and
# dies later both exit 1. So every case names the LINE the script must print,
# and a case that fails somewhere else is a failure here. That is the only
# reason the third mutation in `mutations/list.txt` is catchable: deleting the
# instruction-register measurement does not make a bad chain pass, it makes it
# fail one check further down.
#
# WHAT `tb/cadr_jtag_chain.tcl` DOES NOT MODEL is written at length in its own
# header and is the thing to read before quoting this check. In one line: it
# is a shift chain, not a TAP and not silicon, and it cannot see a DRCK edge,
# `BSCANE2`'s real behaviour, or anything at all about `rtl/cadr_probe.sv` ---
# which `tb/cadr_probe_tb.cpp` holds instead, in Verilator, against muir.
#
# WHY IT IS IN `tb/`.  Both `vivado/fit.tcl` and `vivado/bitstream.tcl` read
# `[glob rtl/*.sv]`, so a simulation-only file under `rtl/` becomes part of
# the bitstream --- `tb/cadr_arty_stubs.sv` is there for exactly that reason
# and says so. These two are Tcl and no glob would take them, but the rule is
# the rule and the obvious wrong home for a stub is the one that causes the
# accident. `tb/` is globbed by nothing.
#
# THE CHAIN THE MODEL PRESENTS is quoted from the same BSDLs `vivado/probe.tcl`
# quotes --- xc7z020_clg400.bsd and zynq7000_arm_dap.bsd --- and confirmed
# against silicon at ace4131: both IDCODEs exact, the part at the TDO end, IR
# total 10, first bit out least significant, DONE high. Both sides quoting one
# source cannot prove the source right; what this checks is that the script
# reads correctly whatever the chain does.

set here [file dirname [file normalize [info script]]]
source [file join $here cadr_jtag_chain.tcl]

# The script under test. Overridable so that the mutation runner can point at
# a copy, and resolved from this file rather than from the working directory.
set probe [expr {[info exists ::env(PROBE_TCL)] ? $::env(PROBE_TCL)
                                                : [file join $here .. vivado probe.tcl]}]
set probe [file normalize $probe]

# ------------------------------------------------------------- the two devices
#
# {name irlen idcode capture idcode-opcode user1-opcode user1-drlen}
#
# The PL TAP's capture is 0x21 rather than the 0x01 IEEE 1149.1 requires at
# the bottom: bit 5 is DONE, and its BSDL says "1 when DONE is released". A
# configured part reads 1 there, which is what the board read, and it is put
# in the model so that the script's `our_ir_lsb + 5` has something to be
# wrong about --- an off-by-one in that offset reads a neighbouring device's
# capture bit and no exit code would notice.
set ZYNQ {xc7z020          6 0x23727093 0x21 0x09 0x02 454}
set DAP  {zynq7000_arm_dap 4 0x4ba00477 0x01 0x0e {}   0}

# The part with a five-bit instruction register: silicon disagreeing with the
# BSDL the script quotes. Nothing before the instruction-register measurement
# can see it --- the IDCODEs are right and the device count is right --- so
# this is the case that reaches that measurement, and the only one that does.
set ZYNQ_IR5 {xc7z020 5 0x23727093 0x01 0x09 0x02 454}

# ------------------------------------------------------------------ the cases
#
# The case name, the exit status, and every line the script must print. A
# passing case names what it must have worked out; a failing case names the
# failure it must fail WITH. `want_exit` alone would let a case fail for a
# reason the case is not about, which is the whole point --- see the header.
#
# The DONE line is asserted on all three passing chains because the offset it
# is read at, `our_ir_lsb + 5`, moves with the device order: 5 when the part
# is at the TDO end, 9 when the DAP is in front of it. An off-by-one there
# reads a neighbouring device's capture bit, which is a plausible 0 or 1 and
# changes no exit code anywhere.
set CASES {
    {good      0 {"PROBE: the 10-bit instruction register captures 061, wanting 041 under mask 0c3"
                  "PROBE: ours is 0 from the TDO end, so a DR scan carries 0 bypass bit(s) in front of the sample and 1 behind"
                  "PROBE: the part's IR capture reads DONE = 1"}}
    {reversed  0 {"PROBE: the 10-bit instruction register captures 211, wanting 011 under mask 033"
                  "PROBE: ours is 1 from the TDO end, so a DR scan carries 1 bypass bit(s) in front of the sample and 0 behind"
                  "PROBE: the part's IR capture reads DONE = 1"}}
    {threedev  0 {"PROBE: the 14-bit instruction register captures 0461, wanting 0441 under mask 0cc3"
                  "PROBE: ours is 0 from the TDO end, so a DR scan carries 0 bypass bit(s) in front of the sample and 2 behind"
                  "PROBE: the part's IR capture reads DONE = 1"}}
    {stranger  1 {"PROBE: FAILED --- IDCODE 0x12345679 at bit 32 is not a"}}
    {msb-first 1 {"PROBE: FAILED --- the IDCODE scan found 0 device(s) and the"}}
    {tdi-zero  1 {"PROBE: FAILED --- bit 64 of the IDCODE scan is a bypass bit, so a"}}
    {irlen     1 {"PROBE: FAILED --- the instruction register does not capture 01 at the"}}
}

# `good` reads the whole buffer and its export is checked column by column;
# the rest only have to reach their line, and eight samples is enough.
#
# 421 for `good` is not a round number: it is the probe's data width, and the
# case hands out one-hot data so that bit k of the payload is the only bit set
# in cycle k. See check_capture.
set DEPTHS {good 421 reversed 8 threedev 8 stranger 8 msb-first 8 tdi-zero 8 irlen 8}

# Where in the ring the read pointer stands when the readout begins. Non-zero
# for `good` deliberately: the rotation back to cycle zero is a branch, and a
# readout that always started at zero would never take it.
set START_AT 5

proc one_hot {j} { return [expr {1 << $j}] }

# --------------------------------------------------------------- a single case
#
# Run as a child process, because `vivado/probe.tcl` ends in `exit` on every
# path --- there is no way to source it seven times in one interpreter.
proc setup_case {case} {
    global ZYNQ DAP ZYNQ_IR5 DEPTHS START_AT
    set ::model(depth) [dict get $DEPTHS $case]
    switch -exact -- $case {
        good      { set ::model(devs) [list $ZYNQ $DAP]
                    set ::model(datafn) one_hot
                    set ::model(rd) $START_AT }
        reversed  { set ::model(devs) [list $DAP $ZYNQ] }
        threedev  { set ::model(devs) [list $ZYNQ $DAP $DAP] }
        stranger  { set ::model(devs) [list $ZYNQ {mystery 5 0x12345679 0x01 0x09 {} 0}] }
        msb-first { set ::model(devs) [list $ZYNQ $DAP]
                    set ::model(msb_first) 1 }
        tdi-zero  { set ::model(devs) [list $ZYNQ $DAP]
                    set ::model(tdi_zero) 1 }
        irlen     { set ::model(devs) [list $ZYNQ_IR5 $DAP] }
        default   { puts stderr "no such case: $case" ; exit 2 }
    }
    model_reset
}

if {[lindex $argv 0] eq "--case"} {
    set case [lindex $argv 1]
    setup_case $case
    set ::env(BOARD_URL)   "model"
    set ::env(PROBE_DEPTH) $::model(depth)
    set ::env(OUTDIR)      [lindex $argv 2]
    set ::env(CSV)         [file join [lindex $argv 2] $case.csv]
    source $probe
    exit 0
}

# ------------------------------------------------------- what `good` exported
#
# THE FIELD TABLE IS NOT COPIED HERE, AND THAT IS THE POINT. There are already
# three descriptions of the probe's 421-bit payload --- `rtl/cadr_probe.sv`,
# `tb/cadr_probe_tb.cpp` and `vivado/probe.tcl` --- and a fourth would be one
# more thing to keep in step and one more way to be wrong in agreement.
#
# So the layout is MEASURED instead. The `good` case hands the script a buffer
# whose sample for cycle j has exactly bit j of the payload set and nothing
# else, 421 cycles for 421 bits. Each exported row must then have exactly one
# non-zero field cell, holding a power of two, and reading the rows in order
# walks the payload from bit 0 upwards. That says, without naming a single
# width: the fields tile the payload with no gap and no overlap, they are
# exported most significant first, and each one's bits are contiguous. A
# transposed pair, a dropped bit, an off-by-one in the offset walk and a
# column exported from the wrong place all break it.
# `set v 0x$cell` before `expr`, never `expr {0x$cell}` --- braces defer no
# substitution, so the second does not parse. vivado/probe.tcl says the same
# where it builds `idval`.
proc hexval {s} {
    set v 0x$s
    return [expr {$v}]
}

proc check_capture {path depth} {
    if {![file exists $path]} { return "wrote no capture at $path" }
    set fh [open $path r]
    set text [read $fh]
    close $fh
    set lines {}
    foreach l [split $text "\n"] { if {$l ne ""} { lappend lines $l } }

    # The metadata `tools/probe_check.py` is documented to need. An undeclared
    # radix is assumed hex and announced, so a capture exported decimal would
    # pass quietly; declared, it cannot.
    set head [join [lrange $lines 0 5] "\n"]
    foreach want [list "Radix - HEX" "Buffer Sample Count: $depth" \
                       "Window Sample Count: $depth" "Trigger Position: 0"] {
        if {[string first $want $head] < 0} {
            return "no `$want` in the metadata"
        }
    }

    set hi -1
    for {set i 0} {$i < [llength $lines]} {incr i} {
        if {[string match "Sample in Buffer,*" [lindex $lines $i]]} { set hi $i ; break }
    }
    if {$hi < 0} { return "no header row" }
    set header [split [lindex $lines $hi] ","]
    if {[lrange $header 0 2] ne {{Sample in Buffer} TRIGGER cycle}} {
        return "header begins [lrange $header 0 2], wanting {Sample in Buffer} TRIGGER cycle"
    }
    set fields [lrange $header 3 end]
    set nf [llength $fields]

    set rows [lrange $lines [expr {$hi + 1}] end]
    if {[llength $rows] != $depth} {
        return "[llength $rows] rows, wanting $depth"
    }

    # Column index and bit position within the column, per payload bit.
    array set col {}
    array set sh {}
    for {set j 0} {$j < $depth} {incr j} {
        set cells [split [lindex $rows $j] ","]
        if {[llength $cells] != $nf + 3} {
            return "row $j has [llength $cells] cells, wanting [expr {$nf + 3}]"
        }
        if {[hexval [lindex $cells 0]] != $j} {
            return "row $j numbers itself [lindex $cells 0]"
        }
        if {[lindex $cells 1] != ($j == 0 ? 1 : 0)} {
            return "row $j has TRIGGER [lindex $cells 1]"
        }
        # The rotation: the model started the pointer part-way round, so a
        # script that did not rotate would emit cycle $START_AT first.
        if {[hexval [lindex $cells 2]] != $j} {
            return "row $j carries cycle [lindex $cells 2], wanting $j --- the\
 buffer was not rotated back to cycle zero"
        }
        set set_at -1
        for {set c 0} {$c < $nf} {incr c} {
            set v [hexval [lindex $cells [expr {$c + 3}]]]
            if {$v == 0} { continue }
            if {$set_at >= 0} {
                return "payload bit $j lit [lindex $fields $set_at] and\
 [lindex $fields $c]; a bit belongs to one field"
            }
            if {($v & ($v - 1)) != 0} {
                return "payload bit $j gave [lindex $fields $c] = [format %llx $v],\
 which is not one bit"
            }
            set set_at $c
            set sh($j) [expr {int(log($v) / log(2) + 0.5)}]
            if {(1 << $sh($j)) != $v} {
                return "payload bit $j: [format %llx $v] is not a power of two"
            }
        }
        if {$set_at < 0} { return "payload bit $j reached no field at all" }
        set col($j) $set_at
    }

    # Walk it. Bit 0 is the bottom of the last field; each time the column
    # changes it must step exactly one to the left and restart at bit 0.
    set expect [expr {$nf - 1}]
    set lo 0
    for {set j 0} {$j < $depth} {incr j} {
        if {$col($j) != $expect} {
            if {$col($j) != $expect - 1 || $sh($j) != 0} {
                return "payload bit $j landed in [lindex $fields $col($j)] at\
 bit $sh($j); the fields do not tile the payload in header order"
            }
            incr expect -1
            set lo $j
        }
        if {$sh($j) != $j - $lo} {
            return "payload bit $j landed at bit $sh($j) of\
 [lindex $fields $col($j)], wanting [expr {$j - $lo}]"
        }
    }
    if {$expect != 0} {
        return "the payload ran out inside [lindex $fields $expect]; the top\
 [expr {$expect}] field(s) were never reached"
    }
    return ""
}

# ------------------------------------------------------------------- the run

set outdir [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR)
                                              : [file join [pwd] build probe_jtag]}]
file mkdir $outdir

set self [file normalize [info script]]
set bad 0
set broke {}
puts "vivado/probe.tcl against tb/cadr_jtag_chain.tcl:"

foreach spec $CASES {
    lassign $spec case want_exit want_lines
    set depth [dict get $DEPTHS $case]
    set out ""
    set rc 0
    if {[catch {exec [info nameofexecutable] $self --case $case $outdir 2>@1} out]} {
        if {[lindex $::errorCode 0] eq "CHILDSTATUS"} {
            set rc [lindex $::errorCode 2]
        } else {
            set rc -1
        }
    }

    set why ""
    if {$rc != $want_exit} {
        set why "exit $rc, wanting $want_exit"
    } else {
        foreach want $want_lines {
            if {[string first $want $out] < 0} {
                set why "never said: $want"
                break
            }
        }
    }
    if {$why eq "" && $case eq "good"} {
        set why [check_capture [file join $outdir $case.csv] $depth]
    }

    if {$why eq ""} {
        puts [format "  %-10s ok   %s" $case \
                  [expr {$want_exit ? "fails where it should" \
                                    : "reads $depth sample(s)"}]]
    } else {
        incr bad
        lappend broke $case
        puts [format "  %-10s FAIL %s" $case $why]
        foreach l [split [string trimright $out "\n"] "\n"] { puts "         | $l" }
    }
}

puts ""
if {$bad} {
    puts "FAIL: $bad of [llength $CASES] chains read wrongly: [join $broke {, }]"
    exit 1
}
puts "ok: [llength $CASES] chains, and vivado/probe.tcl reads each one the way\
 it says it does"
puts "    the four it must refuse fail on the check that names them, not later"
puts "    421 payload bits, one-hot, tile 22 columns in header order with no\
 gap or overlap"
exit 0
