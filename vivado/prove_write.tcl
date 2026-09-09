# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Step two: the fabric writes one word to DDR and the debugger reads it back.
#
#     timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb vivado/prove_write.tcl
#     BIT=build/prove-write/cadr_arty.bit BOARD_URL=<host>:3121 \
#         timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb vivado/prove_write.tcl
#
# Run from the repository root.  `vivado/ddr_check.tcl` is step one and its
# header is the argument for the connect, the two identity registers and the
# `timeout`; this file is the next one and does not repeat any of it.
#
# WHAT IS BEING PROVED.  `rtl/cadr_prove.sv` with `PROVE=1` puts
# `0x8A5C36E1` at `0x18A72EE4` through the machine's own memory port --- the
# same `cadr_axi_master` -> `cadr_axi_widen` -> `cadr_ps7` chain the machine
# will use --- as soon as `SAXIHP0ARESETN` says `S_AXI_HP0` can answer, and
# then stops.  Nothing in the design says whether it arrived.  What says so is
# this script, reading DDR through the processing system's own path, which
# shares nothing with the fabric's: a fabric that is wrong about the address,
# the word, the lane or the strobes cannot agree with it by construction.
#
# THE ORDER IS THE WHOLE PROCEDURE AND IT IS NOT THE OBVIOUS ONE.
#
#   1. `ps7_init`.  The PS is in reset after a `.bit` download and DDR does
#      not answer until this has run.  `docs/board.md` has the paragraph.
#   2. Program the bitstream.  DONE says it was taken, not the absence of an
#      error --- `vivado/program.tcl` makes the same point about the same bit,
#      and it is read here as `fpga -state` plus bit 5 of the part's IR
#      capture, which is where `program.tcl`'s `REGISTER.IR.BIT5_DONE` and
#      `vivado/probe.tcl`'s DONE both come from.
#   3. **Poison the neighbourhood, and do it before the port comes live.**
#      Step one measured never-written DDR on this board coming back in bands
#      of all-zeros and all-ones, so an unwritten word reads `0x00000000` in
#      some places and `0xFFFFFFFF` in others and neither is evidence of
#      anything.  Thirty-two words around the address are filled with
#      `0x75A3C91E`, the word's own complement, so every word that should not
#      have changed differs from `PROVE_WORD` in every bit.  CLAUDE.md's "a
#      stimulus that poisons cannot move with the bug".
#   4. `ps7_post_config`, which is the trigger.  It sets LVL_SHFTR_EN at
#      `0xF8000900` and clears FPGA_RST_CTRL at `0xF8000240`; the witness is
#      held in reset until the port answers, so nothing goes out before this
#      call and everything goes out just after it.  A run that forgot it would
#      read thirty-two words of filler and look exactly like a fabric that
#      cannot write.
#   5. Read the block back.
#
# ONE MORE THING THE ORDER DEPENDS ON, MEASURED HERE AND NOT PREDICTED.
# `SAXIHP0ARESETN` follows LVL_SHFTR_EN at `0xF8000900` and **not**
# FPGA_RST_CTRL at `0xF8000240`.  Measured on this board: with the port live,
# poisoning the block and then writing 0xF to FPGA_RST_CTRL and back to 0
# changed nothing, while writing 0 to LVL_SHFTR_EN and back to 0xF made the
# witness run its transaction again.  `ps7_post_config` writes both, so the
# level shifters are the half that matters.
#
# AND THAT MAKES `ps7_post_config` A NO-OP ON A BOARD THAT HAS ALREADY HAD ONE.
# SLCR keeps its value across `ps7_init` and across a `.bit` download, so a
# second run in the same power-on finds LVL_SHFTR_EN already 0xF, the port
# already live, and the witness firing **the instant the part configures** ---
# which is before this script poisons anything.  The block then reads
# thirty-two words of filler and looks exactly like a fabric that cannot
# write.  It cost one run here to see it.  So the port is put back to sleep
# before the bitstream is loaded, and `ps7_post_config` below is a real
# transition rather than a write of a value that is already there.

# PASS IS EXACTLY TWO THINGS, AND THE SECOND IS THE ONE THAT CAN FAIL.
# `0x18A72EE4` holds the word, AND every other word in the block --- with
# `0x18A72EE0` the one that matters, since it is the low half of the same
# 64-bit beat --- still holds the filler.  `cadr_axi_widen.sv` puts a word
# with bit 2 set in the high half and opens only the top four byte strobes; a
# widening that opened both halves would write the low half too, and against a
# neighbourhood of zeros that would be invisible.  The address was chosen for
# this.  All thirty-two are printed either way.
#
# WHAT IT CANNOT SEE.  LD4 carries the witness's own verdict --- blinking red
# for a port still dead, steady red for live and nothing completed, green for
# completed and right, blue for completed and wrong --- and nothing in this
# script can read a lamp.  With nobody at the board the only observer is the
# read-back below, which is the honest one anyway: the lamp is the design
# marking its own work.
#
# THE BLOCK IS READ TWICE, and the second read is not ceremony.  The fabric
# writes through `S_AXI_HP0`, which is not coherent with anything the APU
# holds, so a debugger read served from a stale line would show the filler for
# a write that did land.  Two reads that agree do not rule that out, but two
# that disagree name it immediately, and the alternative --- concluding "the
# fabric cannot write" from one read --- is the failure this project keeps
# meeting.
#
# AN EXIT CODE CANNOT TELL TWO FAILURES APART, so every word is printed beside
# what was expected and the failures are named before the exit.

set url  [expr {[info exists ::env(BOARD_URL)] ? $::env(BOARD_URL) : ""}]
set init [expr {[info exists ::env(PS7_INIT)] ? $::env(PS7_INIT) \
                                              : "build/ps7/ps7_init.tcl"}]
set bit  [expr {[info exists ::env(BIT)] ? $::env(BIT) \
                                         : "build/prove-write/cadr_arty.bit"}]

# ------------------------------------------------------------------ the map
# The same three numbers `rtl/cadr_arty.sv` gives the witness and
# `vivado/ddr_check.tcl` already carries, and the block around them.
set PROVE_ADDR   0x18A72EE4
set PROVE_NEIGH  0x18A72EE0
set PROVE_WORD   0x8A5C36E1
set PROVE_POISON 0x75A3C91E

# 0x18A72EC0 through 0x18A72F3C: thirty-two words with the address ninth.
set BLOCK_BASE   0x18A72EC0
set BLOCK_WORDS  32

# ------------------------------------------------------------------ helpers

set connected 0

proc say {msg} {
    puts "PROVE: $msg"
    flush stdout
}

proc hex {v} {
    return [format 0x%08X [expr {$v & 0xFFFFFFFF}]]
}

proc bye {code} {
    global connected
    if {$connected} {
        catch {disconnect}
        set connected 0
    }
    exit $code
}

proc stop {msg} {
    say "FAILED --- $msg"
    bye 1
}

proc rd32 {addr} {
    return [expr {[lindex [mrd -force -value $addr 1] 0] & 0xFFFFFFFF}]
}

proc rdn {addr n} {
    return [mrd -force -value $addr $n]
}

proc wr32 {addr val} {
    mwr -force $addr [expr {$val & 0xFFFFFFFF}]
}

# What the block should hold once the fabric has run: the word at its own
# address and the filler everywhere else.
proc wanted {addr} {
    global PROVE_ADDR PROVE_WORD PROVE_POISON
    if {$addr == $PROVE_ADDR} { return $PROVE_WORD }
    return $PROVE_POISON
}

# Print the whole block against a per-address expectation and return the list
# of addresses that disagreed.  Every word is printed either way: a check on a
# program has to say which word was wrong, and a count of failures is not that.
proc show_block {label words expectation} {
    global BLOCK_BASE
    set bad {}
    say "$label:"
    set i 0
    foreach w $words {
        set a [expr {$BLOCK_BASE + 4 * $i}]
        set g [expr {$w & 0xFFFFFFFF}]
        set want [expr {[$expectation $a] & 0xFFFFFFFF}]
        set mark [expr {$g == $want ? "  " : "<-- DIFFERS"}]
        say [format "  %s  %s  wanted %s  %s" [hex $a] [hex $g] [hex $want] $mark]
        if {$g != $want} { lappend bad $a }
        incr i
    }
    return $bad
}

# ------------------------------------------------------------------ connect

if {![file exists $init]} {
    say "FAILED --- $init is missing."
    say "FAILED   `make current` regenerates it; it needs Vivado."
    exit 1
}
if {![file exists $bit]} {
    say "FAILED --- $bit is missing."
    say "FAILED   PROVE=1 OUTDIR=build/prove-write vivado -mode batch \\"
    say "FAILED       -source vivado/bitstream.tcl"
    exit 1
}

if {$url eq ""} {
    say "connecting to a local hw_server"
    if {[catch {connect} err]} {
        say "FAILED --- connect: $err"
        exit 1
    }
} else {
    say "connecting to $url"
    if {[catch {connect -url $url} err]} {
        say "FAILED --- connect $url: $err"
        exit 1
    }
}
set connected 1

say "targets seen:"
foreach line [split [string trimright [targets]] "\n"] {
    say "  $line"
}

if {[catch {targets -set -filter {name =~ "APU*"}} err]} {
    stop "no APU target: $err"
}

set saved_mode [configparams force-mem-accesses]
configparams force-mem-accesses 1

# ------------------------------------------- the part, and the silicon version

# Both asserted for the reasons `vivado/ddr_check.tcl`'s header gives at
# length: PSS_IDCODE says these reads came off a live PS, and PCAP_PS_VERSION
# says which tables `ps7_init` will run rather than letting it default.
set idcode [rd32 0xF8000530]
set device [expr {$idcode & 0x0FFFFFFF}]
say "SLCR PSS_IDCODE at 0xF8000530 reads [hex $idcode]"
say "  device identity              [hex $device]  wanted 0x03727093 (XC7Z020)"
if {$device != 0x03727093} {
    say "FAILED at 0xF8000530 --- PSS_IDCODE is not an XC7Z020's."
    say "FAILED   read [hex $idcode], device identity [hex $device], wanted"
    say "FAILED   0x03727093.  Nothing below is initialised or programmed"
    say "FAILED   against a part this routine was not written for."
    bye 1
}

set mctrl   [rd32 0xF8007080]
set version [expr {($mctrl >> 28) & 0xF}]
say "devcfg MCTRL at 0xF8007080 reads [hex $mctrl]"
say "  PCAP_PS_VERSION 31:28        $version"
switch -- $version {
    0 { say "silicon 1.0 --- ps7_init runs the 1.0 tables" }
    1 { say "silicon 2.0 --- ps7_init runs the 2.0 tables" }
    2 { say "silicon 3.0 --- ps7_init runs the 3.0 tables" }
    3 { say "silicon 3.1 --- ps7_init runs the 3.0 tables, by the else branch,\
 which is the path Xilinx's own FSBL takes for a 3.1 part" }
    default {
        say "FAILED at 0xF8007080 --- PCAP_PS_VERSION $version is not one of"
        say "FAILED   the four fsbl.h names (0 = 1.0, 1 = 2.0, 2 = 3.0,"
        say "FAILED   3 = 3.1).  ps7_init's else branch would run the 3.0"
        say "FAILED   tables against it without saying so."
        bye 1
    }
}

# --------------------------------------------------------------- 1. ps7_init

say "sourcing $init"
if {[catch {source $init} err]} { stop "sourcing $init: $err" }
if {[info procs ps7_init] eq ""} { stop "$init defined no ps7_init" }
if {[info procs ps7_post_config] eq ""} {
    stop "$init defined no ps7_post_config, which is step 4 below"
}
say "running ps7_init --- it prints nothing on success"
if {[catch {ps7_init} err]} { stop "ps7_init raised: $err" }
say "ps7_init returned without error"

# DDR has to answer before there is any point going on, and this is one word
# in the region the block below lives in.  It is not the proof of anything ---
# `vivado/ddr_check.tcl` is --- but a controller that did not come up makes
# every read after it meaningless, and the failure would otherwise be reported
# as the fabric's.
wr32 0x18000000 0x5A5AA5A5
set probe [rd32 0x18000000]
say "DDR answers at 0x18000000: wrote 0x5A5AA5A5, read [hex $probe]"
if {$probe != 0x5A5AA5A5} {
    say "FAILED at 0x18000000 --- DDR does not answer after ps7_init, so"
    say "FAILED   nothing below could say anything about the fabric."
    say "FAILED   vivado/ddr_check.tcl is the step that isolates this."
    bye 1
}

# ------------------------------------------------------ 2. program the fabric

# The port back to sleep before the bitstream loads.  See the header: on a
# board that has already had a `ps7_post_config` in this power-on, the port is
# live before the part is configured, the witness fires at configuration, and
# the poison below lands on top of the word it was meant to make visible.
set shft [rd32 0xF8000900]
say "LVL_SHFTR_EN at 0xF8000900 reads [hex $shft] before programming"
if {$shft != 0} {
    say "  the port is already live, which would make the witness fire at"
    say "  configuration and the poison below erase what it wrote.  Clearing"
    say "  it, so that ps7_post_config is a transition and not a no-op."
    wr32 0xF8000900 0x00000000
    say "  LVL_SHFTR_EN now reads [hex [rd32 0xF8000900]]  wanted 0x00000000"
    if {[rd32 0xF8000900] != 0} {
        stop "LVL_SHFTR_EN will not clear; the port cannot be put back to sleep"
    }
}

# The PL device rather than the APU: `fpga` configures the current target when
# it is one, and falls back to the single supported device in the list when it
# is not.  The fallback is what the command's own help documents, so a name
# this filter does not match is not a reason to stop --- but it is a reason to
# say so, because it means the next line is relying on there being exactly one
# part in the chain.
if {[catch {targets -set -filter {name =~ "xc7z020*"}} err]} {
    say "no target named xc7z020* ($err); `fpga` will configure the one"
    say "  supported device in the chain instead, which on this board is the"
    say "  part.  docs/board.md tabulates the chain as arm_dap_0 and xc7z020_1."
}
say "programming [file tail $bit]"
if {[catch {fpga -file [file normalize $bit]} err]} {
    stop "fpga -file $bit: $err"
}

# THESE THREE RETURN PROSE AND NOT NUMBERS, which cost this script its first
# run against a healthy board: `fpga -state` answers "FPGA is configured" and
# `fpga -ir-status` a six-line decode, so a check written as `$state != 1`
# stopped a part that had taken the configuration and printed the very lines
# that said so.  CLAUDE.md's "a check on a program must assert the line it
# prints", met from the other side --- the line was there and the check was
# reading a register that did not exist.
set state [fpga -state]
say "fpga -state reads: $state"
set irstat "unavailable"
catch {set irstat [fpga -ir-status]}
say "fpga -ir-status reads:"
foreach line [split [string trimright $irstat] "\n"] { say "  $line" }
set cfgstat "unavailable"
catch {set cfgstat [fpga -config-status]}
say "fpga -config-status reads:"
foreach line [split [string trimright $cfgstat] "\n"] { say "  $line" }

if {[string match "*not configured*" $state] || \
    ![string match "*is configured*" $state]} {
    say "FAILED --- the part did not take the configuration, whatever"
    say "FAILED   `fpga -file` reported.  `fpga -state` says: $state"
    bye 1
}
# DONE, from where `vivado/program.tcl` and `vivado/probe.tcl` both read it:
# bit 5 of the part's IR capture, "1 when DONE is released".
if {![regexp {DONE \(Bits \[5\]\): 1} $irstat]} {
    say "FAILED --- DONE is not released.  Bit 5 of the part's IR capture is"
    say "FAILED   the bit vivado/program.tcl reads as REGISTER.IR.BIT5_DONE,"
    say "FAILED   and the decode above does not say it is 1."
    bye 1
}
say "programmed, and DONE is high in the IR capture"

if {[catch {targets -set -filter {name =~ "APU*"}} err]} {
    stop "no APU target after programming: $err"
}

# ------------------------------------------------------------- 3. the poison

say "poisoning [hex $BLOCK_BASE] through\
 [hex [expr {$BLOCK_BASE + 4 * ($BLOCK_WORDS - 1)}]] with [hex $PROVE_POISON]"
for {set i 0} {$i < $BLOCK_WORDS} {incr i} {
    wr32 [expr {$BLOCK_BASE + 4 * $i}] $PROVE_POISON
}

proc all_poison {addr} {
    global PROVE_POISON
    return $PROVE_POISON
}
set bad [show_block "the block before the port comes live" \
             [rdn $BLOCK_BASE $BLOCK_WORDS] all_poison]
if {[llength $bad] > 0} {
    say "FAILED --- the poison did not take at [llength $bad] address(es):"
    foreach a $bad { say "FAILED   [hex $a]" }
    say "FAILED   Nothing below could tell a word the fabric wrote from one it"
    say "FAILED   did not, so the run stops here rather than reporting on it."
    bye 1
}
say "the whole block reads filler, so anything that changes below was written"
say "  by the fabric and by nothing else."

# --------------------------------------------------------- 4. ps7_post_config

set neigh_before [rd32 $PROVE_NEIGH]
say "running ps7_post_config --- LVL_SHFTR_EN at 0xF8000900 and FPGA_RST_CTRL"
say "  at 0xF8000240.  This is the trigger: SAXIHP0ARESETN releases and the"
say "  witness runs its one transaction."
if {[catch {ps7_post_config} err]} { stop "ps7_post_config raised: $err" }
say "ps7_post_config returned without error"
say "  LVL_SHFTR_EN  0xF8000900 reads [hex [rd32 0xF8000900]]  wanted 0x0000000F"
say "  FPGA_RST_CTRL 0xF8000240 reads [hex [rd32 0xF8000240]]  wanted 0x00000000"

# The witness needs the 80 ns setup and one AXI write.  This is six orders of
# magnitude more than that and costs nothing.
after 200

# ------------------------------------------------------------- 5. the verdict

set first  [rdn $BLOCK_BASE $BLOCK_WORDS]
set bad    [show_block "the block after the port came live" $first wanted]

set second [rdn $BLOCK_BASE $BLOCK_WORDS]
if {$first eq $second} {
    say "re-read: identical, so what the block holds is stable"
} else {
    say "re-read: DIFFERENT --- the two reads of a settled block disagree."
    show_block "the block, read a second time" $second wanted
    say "That is its own finding and it is not the fabric's: nothing was"
    say "written between the two reads."
    configparams force-mem-accesses $saved_mode
    bye 1
}

configparams force-mem-accesses $saved_mode

if {[llength $bad] == 0} {
    say "PASSED --- the fabric wrote [hex $PROVE_WORD] to [hex $PROVE_ADDR]"
    say "  through S_AXI_HP0, and every other word in the block, [hex $PROVE_NEIGH]"
    say "  included, still holds the filler.  The low half of the beat is"
    say "  untouched, so the strobes opened one half and not two."
    bye 0
}

say "FAILED --- [llength $bad] word(s) of $BLOCK_WORDS are not what was wanted:"
foreach a $bad {
    say "FAILED   [hex $a]"
}
if {[lsearch -exact $bad $PROVE_ADDR] >= 0} {
    say "FAILED   [hex $PROVE_ADDR] is among them, so the word did not arrive"
    say "FAILED   where it was sent.  If it arrived somewhere else in the"
    say "FAILED   block the list above says where."
}
if {[lsearch -exact $bad $PROVE_NEIGH] >= 0} {
    say "FAILED   [hex $PROVE_NEIGH] is among them, which is the low half of"
    say "FAILED   the same 64-bit beat: the write opened both halves.  That is"
    say "FAILED   cadr_axi_widen.sv's strobes, and the address has bit 2 set"
    say "FAILED   so that this could be seen at all."
    say "FAILED   It read [hex $neigh_before] before the port came live."
}
bye 1
