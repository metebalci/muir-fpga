# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Step three: the debugger writes a word and the fabric reads it back.
#
#     timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb vivado/prove_read.tcl
#     CASE=wrong timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb vivado/prove_read.tcl
#
# Run from the repository root.  `vivado/prove_write.tcl` is step two and
# `vivado/ddr_check.tcl` step one; neither is repeated here.
#
# THIS SCRIPT SETS THE BOARD UP AND STOPS, AND THAT IS NOT A LIMITATION OF THE
# SCRIPT.  `rtl/cadr_arty.sv` with `PROVE=2` ties the witness's `go` to BTN1,
# so the read happens on a press and not otherwise, and the verdict comes out
# on LD4 and nowhere else.  Two things follow, and both of them are structural:
#
#   - **The read cannot be started from here.**  BTN1 is package pin D20 with
#     a pushbutton on it.  Nothing in the design reads a JTAG register that
#     could stand in for it --- the `BSCANE2` in `rtl/cadr_probe.sv` is a
#     `PROBE_DEPTH` board's and shifts out, never in --- and the boundary-scan
#     instructions that could drive a pin from the outside take the pins away
#     from the design, the input clock among them, so the fabric would be
#     stopped at the moment it was meant to run.  A press is a finger.
#
#   - **And the verdict cannot be read from here either.**  LD4 is three pins.
#     Nothing carries `matched` anywhere a debugger can see it, and a read
#     leaves no trace in DDR the way step two's write does, so there is no
#     read-back that could stand in for the lamp.  Step two's observer was
#     outside the design; step three's is a person in the room.
#
# So what this does is put the board in the state where one press answers the
# question, print what each colour would then mean, and stop.  It does not
# press anything and it does not report a verdict it cannot see.
#
# THE THREE CASES, AND WHY THE NEGATIVES COME FIRST.  A fabric holding its
# match line high passes the positive case, so the positive case alone proves
# nothing.  `CASE` selects which of the three the board is left in:
#
#   CASE=wrong   0x8A5C36E0 at 0x18A72EE4 --- the word with bit 0 cleared.
#                The witness reads the right address, in the right half, and
#                gets a word that differs in one bit.  A press must give
#                **blue**.  This is the case that says the lamp can fail, and
#                one bit rather than a wholly different word because a
#                comparison that dropped a bit would pass anything coarser.
#
#   CASE=half    0x8A5C36E1 at 0x18A72EE0 --- the LOW half of the same 64-bit
#                beat --- with filler at 0x18A72EE4.  The word is present in
#                DDR and in the wrong half of the beat.  A press must give
#                **blue**.  This is the case that says `cadr_axi_widen.sv`
#                takes the half the address asks for and not whichever half
#                has something in it.
#
#   CASE=right   0x8A5C36E1 at 0x18A72EE4, the default.  A press must give
#                **green**, and it means something only after the two above
#                have given blue.
#
# Run it three times in that order, pressing BTN1 once after each and reading
# LD4.  Each run reprograms and re-poisons, so the cases cannot contaminate
# each other.
#
# WHAT LD4 SAYS, from `rtl/cadr_arty.sv`'s `lamp4`:
#
#   red, blinking   the port is dead: `ps7_post_config` has not run, or did
#                   not release SAXIHP0ARESETN.  Nothing has happened.
#   red, steady     the port is live and nothing has completed.  This is what
#                   this script leaves behind, and it is the correct state
#                   before a press.
#   green           a transaction completed and the word matched.
#   blue            a transaction completed and it did not: a different word,
#                   or SLVERR or DECERR from the port.
#
# A press that leaves LD4 steady red is its own finding and the sharpest one
# available: the transaction went out and never came back.
#
# LD0 to LD3 and LD5 read exactly as `docs/board.md` tabulates them for a
# board with no memory, because on a `PROVE` board the machine's `mem_done` is
# tied low and its own cycles still end on the NXM timer.

set url  [expr {[info exists ::env(BOARD_URL)] ? $::env(BOARD_URL) : ""}]
set init [expr {[info exists ::env(PS7_INIT)] ? $::env(PS7_INIT) \
                                              : "build/ps7/ps7_init.tcl"}]
set bit  [expr {[info exists ::env(BIT)] ? $::env(BIT) \
                                         : "build/prove-read/cadr_arty.bit"}]
set case [expr {[info exists ::env(CASE)] ? $::env(CASE) : "right"}]

set PROVE_ADDR   0x18A72EE4
set PROVE_NEIGH  0x18A72EE0
set PROVE_WORD   0x8A5C36E1
set PROVE_POISON 0x75A3C91E

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

# ------------------------------------------------------------- what to leave

# One word at one address on top of the filler, and what a press should then
# give.
switch -- $case {
    right {
        set put_addr $PROVE_ADDR
        set put_word $PROVE_WORD
        set expect   "GREEN"
        set why      "the word is at the address the witness asks for, in the\
 high half of the beat where bit 2 of the address puts it"
    }
    wrong {
        set put_addr $PROVE_ADDR
        set put_word 0x8A5C36E0
        set expect   "BLUE"
        set why      "the address holds the word with bit 0 cleared, so a lamp\
 that can only go green is caught here and so is a comparison that drops a bit"
    }
    half {
        set put_addr $PROVE_NEIGH
        set put_word $PROVE_WORD
        set expect   "BLUE"
        set why      "the word is in the LOW half of the beat and the witness\
 asks for the high one, so a widening that returns whichever half has\
 something in it is caught here"
    }
    default {
        say "FAILED --- CASE=$case is not one of right, wrong, half."
        say "FAILED   See the header: the negatives come first and the"
        say "FAILED   positive means nothing without them."
        exit 1
    }
}

# ------------------------------------------------------------------ connect

if {![file exists $init]} {
    say "FAILED --- $init is missing."
    say "FAILED   `make current` regenerates it; it needs Vivado."
    exit 1
}
if {![file exists $bit]} {
    say "FAILED --- $bit is missing."
    say "FAILED   PROVE=2 OUTDIR=build/prove-read vivado -mode batch \\"
    say "FAILED       -source vivado/bitstream.tcl"
    exit 1
}

say "case $case --- a press of BTN1 should give $expect,"
say "  because $why."

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

set idcode [rd32 0xF8000530]
set device [expr {$idcode & 0x0FFFFFFF}]
say "SLCR PSS_IDCODE at 0xF8000530 reads [hex $idcode]"
say "  device identity              [hex $device]  wanted 0x03727093 (XC7Z020)"
if {$device != 0x03727093} {
    say "FAILED at 0xF8000530 --- PSS_IDCODE is not an XC7Z020's."
    say "FAILED   read [hex $idcode], wanted device identity 0x03727093."
    bye 1
}

set mctrl   [rd32 0xF8007080]
set version [expr {($mctrl >> 28) & 0xF}]
say "devcfg MCTRL at 0xF8007080 reads [hex $mctrl]"
say "  PCAP_PS_VERSION 31:28        $version"
if {$version > 3} {
    say "FAILED at 0xF8007080 --- PCAP_PS_VERSION $version is not one of the"
    say "FAILED   four fsbl.h names.  ps7_init would run the 3.0 tables"
    say "FAILED   against it without saying so."
    bye 1
}

# --------------------------------------------------------------- 1. ps7_init

say "sourcing $init"
if {[catch {source $init} err]} { stop "sourcing $init: $err" }
if {[info procs ps7_init] eq ""} { stop "$init defined no ps7_init" }
if {[info procs ps7_post_config] eq ""} { stop "$init defined no ps7_post_config" }
say "running ps7_init"
if {[catch {ps7_init} err]} { stop "ps7_init raised: $err" }
say "ps7_init returned without error"

wr32 0x18000000 0x5A5AA5A5
set probe [rd32 0x18000000]
say "DDR answers at 0x18000000: wrote 0x5A5AA5A5, read [hex $probe]"
if {$probe != 0x5A5AA5A5} {
    stop "DDR does not answer after ps7_init; vivado/ddr_check.tcl isolates this"
}

# ------------------------------------------------------ 2. program the fabric

# The port back to sleep before the bitstream loads.  SLCR survives `ps7_init`
# and a `.bit` download, so a second run in one power-on finds LVL_SHFTR_EN
# already 0xF and `ps7_post_config` writes a value that is already there ---
# `SAXIHP0ARESETN` follows that register and not FPGA_RST_CTRL, measured on
# this board.  On a read board nothing fires without a press, so what this
# costs is not a lost transaction but a lost diagnostic: LD4 would already be
# steady red before the port was meant to come live, and the blink that tells
# "post_config was forgotten" from "the port swallowed it" would say nothing.
set shft [rd32 0xF8000900]
say "LVL_SHFTR_EN at 0xF8000900 reads [hex $shft] before programming"
if {$shft != 0} {
    say "  clearing it, so the board starts with a dead port and LD4 blinking,"
    say "  and ps7_post_config below is a transition rather than a no-op."
    wr32 0xF8000900 0x00000000
    say "  LVL_SHFTR_EN now reads [hex [rd32 0xF8000900]]  wanted 0x00000000"
    if {[rd32 0xF8000900] != 0} {
        stop "LVL_SHFTR_EN will not clear; the port cannot be put back to sleep"
    }
}

if {[catch {targets -set -filter {name =~ "xc7z020*"}} err]} {
    say "no target named xc7z020* ($err); `fpga` will configure the one"
    say "  supported device in the chain instead."
}

say "programming [file tail $bit]"
if {[catch {fpga -file [file normalize $bit]} err]} {
    stop "fpga -file $bit: $err"
}
# Both of these answer in prose --- "FPGA is configured" and a six-line
# decode --- and a first draft of `vivado/prove_write.tcl` asserted them as
# integers and stopped a part that had taken the configuration.  Matched as
# text here, which is what they are.
set state [fpga -state]
say "fpga -state reads: $state"
set irstat "unavailable"
catch {set irstat [fpga -ir-status]}
say "fpga -ir-status reads:"
foreach line [split [string trimright $irstat] "\n"] { say "  $line" }
if {[string match "*not configured*" $state] || \
    ![string match "*is configured*" $state]} {
    stop "the part did not take the configuration; `fpga -state` says: $state"
}
if {![regexp {DONE \(Bits \[5\]\): 1} $irstat]} {
    stop "DONE is not released; bit 5 of the part's IR capture is not 1"
}
say "programmed, and DONE is high in the IR capture"

if {[catch {targets -set -filter {name =~ "APU*"}} err]} {
    stop "no APU target after programming: $err"
}

# --------------------------------------------- 3. the poison, then the pattern

say "poisoning [hex $BLOCK_BASE] through\
 [hex [expr {$BLOCK_BASE + 4 * ($BLOCK_WORDS - 1)}]] with [hex $PROVE_POISON]"
for {set i 0} {$i < $BLOCK_WORDS} {incr i} {
    wr32 [expr {$BLOCK_BASE + 4 * $i}] $PROVE_POISON
}
wr32 $put_addr $put_word

say "the block as the witness will find it:"
set words [rdn $BLOCK_BASE $BLOCK_WORDS]
set i 0
set bad {}
foreach w $words {
    set a    [expr {$BLOCK_BASE + 4 * $i}]
    set g    [expr {$w & 0xFFFFFFFF}]
    set want [expr {($a == $put_addr) ? $put_word : $PROVE_POISON}]
    set want [expr {$want & 0xFFFFFFFF}]
    set mark [expr {$a == $put_addr ? "<-- the pattern" : "  "}]
    if {$a == $PROVE_ADDR && $a != $put_addr} { set mark "<-- what the witness reads" }
    say [format "  %s  %s  wanted %s  %s" [hex $a] [hex $g] [hex $want] $mark]
    if {$g != $want} { lappend bad $a }
    incr i
}
if {[llength $bad] > 0} {
    say "FAILED --- the block is not what was written at [llength $bad] address(es):"
    foreach a $bad { say "FAILED   [hex $a]" }
    say "FAILED   The witness would be reading something nobody chose."
    configparams force-mem-accesses $saved_mode
    bye 1
}

# --------------------------------------------------------- 4. ps7_post_config

say "running ps7_post_config --- the port comes live and LD4 stops blinking"
if {[catch {ps7_post_config} err]} { stop "ps7_post_config raised: $err" }
say "  LVL_SHFTR_EN  0xF8000900 reads [hex [rd32 0xF8000900]]  wanted 0x0000000F"
say "  FPGA_RST_CTRL 0xF8000240 reads [hex [rd32 0xF8000240]]  wanted 0x00000000"

after 200

# A read writes nothing, so the block must be exactly as it was left.  This is
# a weak check and it is worth having anyway: a witness built with `writes`
# stuck high would change the block here, with nobody at the board to see the
# lamp say anything at all.
set after_words [rdn $BLOCK_BASE $BLOCK_WORDS]
if {$after_words eq $words} {
    say "the block is unchanged after the port came live, which is what a read"
    say "  board should do: BTN1 has not been pressed and a read writes nothing."
} else {
    say "SURPRISE --- the block changed when the port came live, and a PROVE=2"
    say "  board writes nothing.  Reading it again:"
    set i 0
    foreach w $after_words {
        set a [expr {$BLOCK_BASE + 4 * $i}]
        say "  [hex $a]  [hex $w]  was [hex [lindex $words $i]]"
        incr i
    }
    configparams force-mem-accesses $saved_mode
    bye 1
}

configparams force-mem-accesses $saved_mode

# ------------------------------------------------------------------- the hand

say "SET UP --- and stopped, because the rest of step three is a finger and an"
say "  eye.  The board now holds case $case."
say ""
say "  LD4 should be STEADY RED: the port is live and nothing has completed."
say "  If it is BLINKING red, ps7_post_config did not release the port and a"
say "  press would answer nothing."
say ""
say "  Press BTN1 once.  LD4 should go $expect,"
say "  because $why."
say ""
say "  green   the word came back and matched"
say "  blue    it completed and did not match --- a different word, or SLVERR"
say "          or DECERR from S_AXI_HP0"
say "  red     still: the transaction went out and never came back"
say ""
say "  Then run this again with CASE=wrong and CASE=half if they have not been"
say "  run: a fabric holding its match line high gives green in every case,"
say "  and only the two blues rule it out."
bye 0
