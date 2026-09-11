# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# A JTAG chain, and the Vivado hardware manager around it, in enough detail
# to run `boards/arty-z7-20/vivado/probe.tcl` with no board and no Vivado. `tclsh` and nothing
# else. `tb/cadr_probe_jtag_tb.tcl` is what drives it.
#
# WHY THIS EXISTS.  `boards/arty-z7-20/vivado/probe.tcl` is the only thing that will ever be
# able to say the board computes what muir computes, and until this file it
# was the one program in the repository that nothing could run. It shipped
# with a one-character bug --- `-tdi [string repeat 0 ...]` where the chain
# needs ones --- which no check could have caught, because there was no check.
# The bug reproduces here, off the board, in 80 ms.
#
# ------------------------------------------------------------ WHAT IS MODELLED
#
# A chain of devices as a shift register, and only that:
#
#   an over-long scan.  The whole reason this catches anything. Shift n bits
#   through a register of length L and the bits that come out are the
#   register's captured value for the first L of them and TDI after that ---
#   and what STAYS IN is the LAST L bits shifted in, which is why an
#   over-long IR scan leaves the padding in the instruction register and not
#   the instruction. That single fact is what the shipped bug turned on.
#
#   Capture-IR.  Each device presents its documented capture pattern, whose
#   bottom two bits IEEE 1149.1 fixes at 01.
#
#   Capture-DR, by instruction.  IDCODE gives 32 bits, BYPASS one, USER1 the
#   probe's sample and one advance of the buffer pointer per capture.
#
#   TAP reset, as one thing: every device's instruction register goes to
#   IDCODE. `run_state_hw_jtag RESET` is the only state command honoured.
#
# --------------------------------------------------------- WHAT IS NOT MODELLED
#
# READ THIS BEFORE BELIEVING A GREEN RUN MEANS THE READOUT IS VERIFIED. It
# does not, and the gap is wide.
#
#   NOT A TAP STATE MACHINE.  There is no TMS, no Run-Test/Idle, no
#   Exit1/Update, no state at all between one scan and the next beyond which
#   instruction is loaded. A script that reached Shift-DR without passing
#   through Capture-DR would be modelled as though it had captured.
#
#   NOT SILICON, AND NOT `rtl/plumbing/xilinx7/cadr_probe.sv`.  There is no DRCK here, no
#   clock, and no edges. The probe's shift register clocking the wrong edge of
#   DRCK, capturing after advancing instead of before, or gating on SEL
#   wrongly, are all invisible to this file. `tb/cadr_probe_tb.cpp` is what
#   holds the probe itself, against muir's trace, in Verilator --- and the two
#   checks do not overlap: that one never sees the chain, this one never sees
#   the fabric.
#
#   NOT VIVADO.  `open_hw_manager` and the rest are stubs that return what
#   this file is told to return. Whether Vivado's own `scan_dr_hw_jtag`
#   really answers least significant bit first is not settled here --- the
#   board settled it, at ace4131, and `msb-first` is a case rather than a
#   fact.
#
#   NOT A CLAIM THAT THE CHAIN IS THIS CHAIN.  The device table is written by
#   the caller. It is quoted from the same two BSDL files `boards/arty-z7-20/vivado/probe.tcl`
#   names, so both agree, and a check where both sides are quoting one source
#   cannot tell you the source is right.
#
# So: this reproduces one specific mechanism, and the shipped bug was caught
# by that mechanism rather than by a correct simulation of JTAG. A reader who
# takes a green `probe_jtag.pass` to mean the hardware readout is verified
# will be wrong about the part that matters.

# ------------------------------------------------------------------ the state
#
#   devs      the chain, index 0 nearest TDO, each entry
#             {name irlen idcode capture idcode-opcode user1-opcode user1-drlen}
#             with an empty user1-opcode for a device that has no USER1.
#   insn      one of IDCODE BYPASS USER1 OTHER per device
#   depth     the probe's ring depth
#   rd        how many times USER1's data register has been captured
#   datafn    command prefix answering the 421-bit data word for a cycle
#   tdi_zero  DR scans see TDI low whatever the caller drove, which is the
#             board a script driving TDI with zeros would see
#   msb_first a returned scan comes back most significant bit first
array set ::model {
    devs      {}
    insn      {}
    depth     8
    rd        0
    datafn    model_default_data
    tdi_zero  0
    msb_first 0
}

proc model_default_data {j} { return [expr {($j * 3 + 1) & 0xffff}] }

proc model_reset {} {
    set ::model(insn) {}
    foreach d $::model(devs) { lappend ::model(insn) IDCODE }
}

proc model_ir_total {} {
    set t 0
    foreach d $::model(devs) { incr t [lindex $d 1] }
    return $t
}

proc model_mask {n} { return [expr {(1 << $n) - 1}] }

# THE WHOLE OF AN OVER-LONG SCAN, and the only mechanism this file has.
#
# A register of length L holding `cap` is shifted n times with `tdi` behind
# it. Bit k of what comes out is cap[k] while k < L and tdi[k-L] after, so an
# over-long scan reads the register and then reads back its own padding. What
# remains in the register is the last L bits shifted in --- the TAIL of tdi,
# not its head --- which is why an IR scan longer than the chain loads the
# padding as the instruction and the instruction is lost.
#
# Arithmetic rather than a bit loop: Tcl carries integers at arbitrary
# precision, so a 455-bit scan is a handful of shifts.
proc model_shift {n L cap tdi} {
    if {$n <= $L} {
        set out [expr {$cap & [model_mask $n]}]
        set kept [expr {(($tdi << ($L - $n)) | ($cap >> $n)) & [model_mask $L]}]
    } else {
        set out [expr {($cap & [model_mask $L]) |
                       (($tdi & [model_mask [expr {$n - $L}]]) << $L)}]
        set kept [expr {($tdi >> ($n - $L)) & [model_mask $L]}]
    }
    return [list $out $kept]
}

# A scan's value as Vivado hands it back: a hex string, no prefix, one digit
# per four bits. `%llx` and not `%x` for the reason boards/arty-z7-20/vivado/probe.tcl's own
# `hexof` gives --- `format %x` truncates a bignum to 64 bits in silence.
proc model_hex {value n} {
    if {$::model(msb_first)} {
        set r 0
        for {set k 0} {$k < $n} {incr k} {
            set r [expr {$r | ((($value >> $k) & 1) << ($n - 1 - $k))}]
        }
        set value $r
    }
    return [format %0[expr {($n + 3) / 4}]llx $value]
}

# `set v 0x$hex` and then `expr {$v}`, never `expr {0x[dict get ...]}`. Inside
# braces there is no substitution before parsing, so the second is a syntax
# error --- the same trap `boards/arty-z7-20/vivado/probe.tcl` documents at `set idval 0x$idraw`,
# and the reason a hex string is bound to a variable first.
proc model_arg_tdi {argv} {
    if {[dict exists $argv -tdi]} {
        set v 0x[dict get $argv -tdi]
        return [expr {$v}]
    }
    return 0
}

# ------------------------------------------------------------ the sample
#
# valid, then the cycle, then the data --- the order `rtl/plumbing/xilinx7/cadr_probe.sv`
# stores it in and `boards/arty-z7-20/vivado/probe.tcl` unpacks. 1 + 32 + 421 = 454.
proc model_sample {} {
    set j [expr {$::model(rd) % $::model(depth)}]
    set data [uplevel #0 [concat $::model(datafn) [list $j]]]
    return [expr {(1 << 453) | ($j << 421) | ($data & [model_mask 421])}]
}

# ------------------------------------------------------- the two scan commands

proc scan_ir_hw_jtag {n args} {
    set tdi [model_arg_tdi $args]
    set L [model_ir_total]
    set cap 0
    set at 0
    foreach d $::model(devs) {
        set cap [expr {$cap | ([lindex $d 3] << $at)}]
        incr at [lindex $d 1]
    }
    lassign [model_shift $n $L $cap $tdi] out kept

    # What the devices are now holding. A field of all ones is BYPASS in every
    # device that conforms; the rest is read against the device's own table.
    set insn {}
    set at 0
    foreach d $::model(devs) {
        lassign $d name irlen idcode capture idop user1 user1len
        set v [expr {($kept >> $at) & [model_mask $irlen]}]
        if {$v == [model_mask $irlen]} {
            lappend insn BYPASS
        } elseif {$user1 ne "" && $v == $user1} {
            lappend insn USER1
        } elseif {$v == $idop} {
            lappend insn IDCODE
        } else {
            lappend insn OTHER
        }
        incr at $irlen
    }
    set ::model(insn) $insn
    return [model_hex $out $n]
}

proc scan_dr_hw_jtag {n args} {
    set tdi [model_arg_tdi $args]
    # A board whose TDI is low however the script drove it. Not a mutation of
    # the script: the case that says what the all-ones tail is FOR.
    if {$::model(tdi_zero)} { set tdi 0 }

    set cap 0
    set L 0
    set i 0
    set captured 0
    foreach d $::model(devs) {
        lassign $d name irlen idcode capture idop user1 user1len
        switch [lindex $::model(insn) $i] {
            IDCODE { set w 32          ; set v $idcode }
            USER1  { set w $user1len   ; set v [model_sample] ; set captured 1 }
            default { set w 1          ; set v 0 }
        }
        set cap [expr {$cap | ($v << $L)}]
        incr L $w
        incr i
    }
    lassign [model_shift $n $L $cap $tdi] out kept
    # The pointer advances once per capture, whatever the scan's length --- the
    # ordering `tb/cadr_probe_tb.cpp` holds the fabric to.
    if {$captured} { incr ::model(rd) }
    return [model_hex $out $n]
}

proc run_state_hw_jtag {state} {
    if {$state eq "RESET"} { model_reset }
}

# ------------------------------------------------ the hardware manager, stubbed
#
# Enough of it for `boards/arty-z7-20/vivado/probe.tcl` to open a target and count devices, and
# no more. `get_hw_devices` lists from the TDI end, which is the opposite of
# the order the raw scan reads in --- that opposition is a thing the script
# has to get right and so is modelled rather than smoothed over.
proc open_hw_manager {args} {}
proc connect_hw_server {args} {}
proc get_hw_targets {args} { return {model_target} }
proc current_hw_target {args} {}
proc open_hw_target {args} {}
proc close_hw_target {args} {}
proc close_hw_manager {args} {}

proc get_hw_devices {args} {
    set r {}
    foreach d $::model(devs) { lappend r [lindex $d 0]_0 }
    return [lreverse $r]
}

proc get_property {args} { return "model" }
