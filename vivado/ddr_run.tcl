# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Step four: the machine itself, running out of DDR, read from outside.
#
#     timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb vivado/ddr_run.tcl
#     BIT=build/ddr/cadr_arty.bit BOARD_URL=<host>:3121 \
#         timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb vivado/ddr_run.tcl
#
# Run from the repository root.  `vivado/ddr_check.tcl` is step one and
# `vivado/prove_write.tcl` step two; their headers carry the argument for the
# connect, the two identity registers and the `timeout`, and this file does
# not repeat any of it.
#
# WHAT IS BEING PROVED, AND WHY IT NEEDED A NEW INSTRUMENT.  `DDR=1` puts the
# processing system behind the machine's own memory port.  The boot PROM's
# whole main-memory traffic is PAGE-0-PARITY-FIX: it reads each of the 256
# words of physical page 0 and writes the same word straight back, 512 bus
# cycles between 118.0 and 118.4 ms after reset, and never touches memory
# again.  **AN IDENTITY COPY LEAVES NOTHING BEHIND.**  Page 0 reading back
# unchanged afterwards says the path did no harm; it cannot say the path was
# used, because a board whose port is dead times all 512 cycles out and leaves
# page 0 exactly as unchanged.  Nor can any lamp: measured, LD2 blinks at the
# same rate with DDR and without, because the 16,951 disk-controller polls
# time out either way.
#
# And the processing system ships nothing that could stand in.  Its DDR
# controller has no performance monitors --- all 114 of its registers were
# enumerated, and the names people half-remember are write-only arbitration
# starvation controls --- the AFI interface's status is instantaneous, and
# Xilinx's own performance tooling instantiates a counter IP in the fabric for
# exactly this reason.
#
# SO THE FABRIC COUNTS, AT THE PROCESSING SYSTEM'S OWN HANDSHAKES.
# `rtl/cadr_mem_count.sv` keeps four sixteen-bit counters: what the machine
# ASKED the port for, split by direction, and what the processing system
# ANSWERED --- `BVALID`/`BREADY` for a write and the last `RVALID`/`RREADY`
# beat for a read.  A fabric that never issued a transaction cannot fabricate
# a `B` or an `R`, which is what makes the answered pair a witness rather than
# the design marking its own work.  They come out on EMIO GPIO and are read
# here:
#
#     0xE000A068  DATA_2_RO  EMIO 31:0    bits 14:0  answered reads
#                                          bit  15     1
#                                          bits 30:16  answered writes
#                                          bit  31     0
#     0xE000A06C  DATA_3_RO  EMIO 63:32    the same, asked reads and writes
#
# Both registers report the pin whatever the direction registers say, `DIRM`
# comes up input, and `ps7_init` has already turned the GPIO clock on --- bit
# 22 of the 0x01DC044D it writes to APER_CLK_CTRL at 0xF800012C.  Nothing has
# to be configured, and there is no AXI slave and no `M_AXI_GP0` in the
# design.
#
# **THE MARKER BITS ARE WHY THE FIELDS ARE FIFTEEN BITS AND NOT SIXTEEN**, and
# they were put there because of what this script measured.  Run against a
# `DDR=0` bitstream --- a board with no tally in it at all --- both registers
# read 0xFFFFFFFF: with the level shifters ON and nothing in the fabric
# driving the EMIO pins, the processing system reads them as all ones.  With
# the shifters OFF it reads all zeros.  So an absent instrument reads exactly
# like four SATURATED counters, and the failure would have been reported as
# "the machine asked 65,535 times".  `(w & 0x80008000) == 0x00008000` is a
# pattern neither reading can produce, so the register says who wrote it.
# CLAUDE.md's never-written-DDR entry in a new place: a value that means
# nothing must not be a value the instrument can mean.
#
# THE ORDER IS NOT `prove_write.tcl`'s, AND THE DIFFERENCE IS THE POINT.
# There the fabric was a witness held in reset until the port came live, so
# the bitstream could be programmed first and `ps7_post_config` used as the
# trigger.  The machine has no such trigger: `rtl/cadr_arty.sv` resets it on
# the MMCM's lock or on BTN0, so it starts the instant the part configures and
# reaches its memory cycles 118 ms later whether or not anybody has brought
# the port up.  Program first and the machine is finished before
# `ps7_post_config` is typed.  So the port is brought up BEFORE the bitstream
# is loaded:
#
#   1. `ps7_init`, and DDR answers.
#   2. LVL_SHFTR_EN cleared, then page 0 and a margin around it poisoned ---
#      before anything can be running --- and read back.
#   3. The tally read cold.  The level shifters are off and nothing is
#      configured, so both registers must read 0x00000000; anything else here
#      would make everything below uninterpretable.
#   4. `ps7_post_config`.  LVL_SHFTR_EN reads 0xF and the port is live.
#   5. Program the bitstream.  **AND LVL_SHFTR_EN MUST STILL READ 0xF.**
#      SLCR keeps its value across a `.bit` download --- `prove_write.tcl`
#      measured that once as a hazard, where a second run in one power-on
#      found the port already live and the witness firing at configuration.
#      Here it is the mechanism: the machine starts with the port already up.
#      If it did not hold, this step would need the port's reset folded into
#      the machine's, which is a design change and not this script's to make.
#   6. Wait.  The machine reaches memory at 118 ms and is done by 118.4.
#   7. The counters, twice.
#   8. The block, twice, and the two AFI debug registers.
#
# PASS IS 256 OF EACH OF THE FOUR, AND PAGE 0 STILL ITS POISON.  The first
# says the cycles were answered by the processing system; the second says the
# machine copied what it read and nothing else, which an unanswered path
# cannot do to a poison it never saw.  The poison is injective in the address
# and has BIT 0 CLEAR IN EVERY WORD, and that bit is load-bearing: bit 0 of
# what an unanswered read leaves in MD is what the boot PROM's disk poll takes
# for "the controller is ready", and a poison with it set once made the
# machine write a CCW to physical 777 and halt at PC 40.  That behaviour was
# decided against --- an unanswered read gives MD zero --- but the poison
# stays clear of the bit so that this script measures the machine and not that
# decision.
#
# AND EVERYTHING IS READ TWICE.  The fabric writes through `S_AXI_HP0`, which
# is not coherent with anything the APU holds, so a read served from a stale
# line would show the wrong thing for a write that did land.  Two reads that
# agree do not rule that out; two that disagree name it immediately.
#
# AN EXIT CODE CANNOT TELL TWO FAILURES APART, so every value is printed
# beside its expectation and every failure names the address or the counter
# before the exit.

set url  [expr {[info exists ::env(BOARD_URL)] ? $::env(BOARD_URL) : ""}]
set init [expr {[info exists ::env(PS7_INIT)] ? $::env(PS7_INIT) \
                                              : "build/ps7/ps7_init.tcl"}]
set bit  [expr {[info exists ::env(BIT)] ? $::env(BIT) \
                                         : "build/ddr/cadr_arty.bit"}]

# ------------------------------------------------------------------ the map
# rtl/cadr_ddr_map.sv's MAIN_BASE, and the page the parity loop walks.  The
# block poisoned is sixteen times wider than the page, so a cycle that landed
# off it lands somewhere this script prints rather than somewhere nobody
# looks --- physical 777, where the machine used to put a CCW, is word 511 of
# it.
set MAIN_BASE   0x18000000
set BLOCK_WORDS 1024

# The tally, and the two registers it comes out on.
set DATA_2_RO   0xE000A068
set DATA_3_RO   0xE000A06C

# What the boot PROM's page-0 parity loop is.
set WANT_READS  256
set WANT_WRITES 256

# AFI0's two debug registers, whose bit 0 is the channel's overflow.  A port
# that overflowed answered something, but not what it was asked.
set AFI_RDDEBUG 0xF8008010
set AFI_WRDEBUG 0xF8008024

# ------------------------------------------------------------------ helpers

set connected 0

proc say {msg} {
    puts "RUN: $msg"
    flush stdout
}

proc hex {v} {
    return [format 0x%08X [expr {$v & 0xFFFFFFFF}]]
}

proc bye {code} {
    global connected saved_mode
    if {$connected} {
        catch {configparams force-mem-accesses $saved_mode}
        catch {disconnect}
        set connected 0
    }
    exit $code
}

proc stop {msg} {
    say "FAILED --- $msg"
    bye 1
}

proc fail {what addr want got} {
    say "FAILED at [hex $addr] --- $what"
    say "FAILED   wanted [hex $want], read [hex $got]"
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

# THE POISON.  Injective in the word index, bit 0 clear in every word, never
# zero and never its own address.  Multiplication by an odd constant is a
# bijection modulo a power of two, so taking the product modulo 2^31 and
# doubling it gives 1,024 distinct even words --- and the properties are
# ASSERTED below rather than argued for, because a poison with a collision in
# it tests less than it looks like it does.
proc poison {i} {
    return [expr {((($i + 1) * 2654435761) % 2147483648) * 2}]
}

# ------------------------------------------------------------------ connect

if {![file exists $init]} {
    say "FAILED --- $init is missing."
    say "FAILED   `make current` regenerates it; it needs Vivado."
    exit 1
}
if {![file exists $bit]} {
    say "FAILED --- $bit is missing."
    say "FAILED   DDR=1 OUTDIR=build/ddr vivado -mode batch \\"
    say "FAILED       -source vivado/bitstream.tcl"
    exit 1
}

# ------------------------------------------------- the poison, before anything

# Computed and checked before the board is touched, so that a poison this
# script could not tell apart from an unwritten word is a failure of the
# script and not a finding about the machine.
set want {}
for {set i 0} {$i < $BLOCK_WORDS} {incr i} {
    lappend want [poison $i]
}
array set seen {}
for {set i 0} {$i < $BLOCK_WORDS} {incr i} {
    set p [lindex $want $i]
    set a [expr {$MAIN_BASE + 4 * $i}]
    if {($p & 1) != 0} {
        say "FAILED --- poison word $i has bit 0 set, which is the bit the"
        say "FAILED   boot PROM's disk poll reads.  See the header."
        exit 1
    }
    if {$p == 0 || $p == 0xFFFFFFFE} {
        say "FAILED --- poison word $i is [hex $p], which is what never-written"
        say "FAILED   DDR reads on this board.  vivado/ddr_check.tcl measured"
        say "FAILED   the bands."
        exit 1
    }
    if {$p == $a} {
        say "FAILED --- poison word $i is its own address [hex $a]"
        exit 1
    }
    if {[info exists seen($p)]} {
        say "FAILED --- the poison collides: words $seen($p) and $i both hold"
        say "FAILED   [hex $p], so a cycle that landed on the wrong one of them"
        say "FAILED   would be invisible."
        exit 1
    }
    set seen($p) $i
}
say "the poison: $BLOCK_WORDS words, all distinct, bit 0 clear in every one,"
say "  none zero, none all-ones, none its own address"

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

wr32 0x18000000 0x5A5AA5A5
set probe [rd32 0x18000000]
say "DDR answers at 0x18000000: wrote 0x5A5AA5A5, read [hex $probe]"
if {$probe != 0x5A5AA5A5} {
    say "FAILED at 0x18000000 --- DDR does not answer after ps7_init, so"
    say "FAILED   nothing below could say anything about the fabric."
    say "FAILED   vivado/ddr_check.tcl is the step that isolates this."
    bye 1
}

# ------------------------------------------------------ 2. the port asleep,
#                                                            then the poison

# CLEARED SO THAT STEP 4 IS A TRANSITION.  SLCR keeps LVL_SHFTR_EN across a
# `ps7_init` and across a `.bit` download, so a second run in one power-on
# would otherwise find the port already live --- and, since the machine starts
# at configuration, would leave the reading below meaning nothing.  With it
# cleared, the port comes up exactly once and at a moment this script chose.
set shft [rd32 0xF8000900]
say "LVL_SHFTR_EN at 0xF8000900 reads [hex $shft] before anything"
if {$shft != 0} {
    wr32 0xF8000900 0x00000000
    say "  cleared, so that ps7_post_config below is a transition and not a"
    say "  write of a value already there.  It now reads [hex [rd32 0xF8000900]]"
    if {[rd32 0xF8000900] != 0} {
        stop "LVL_SHFTR_EN will not clear; the port cannot be put to sleep"
    }
}

say "poisoning [hex $MAIN_BASE] through\
 [hex [expr {$MAIN_BASE + 4 * ($BLOCK_WORDS - 1)}]], $BLOCK_WORDS words"
for {set i 0} {$i < $BLOCK_WORDS} {incr i} {
    wr32 [expr {$MAIN_BASE + 4 * $i}] [lindex $want $i]
}
set got [rdn $MAIN_BASE $BLOCK_WORDS]
set bad 0
for {set i 0} {$i < $BLOCK_WORDS} {incr i} {
    set a [expr {$MAIN_BASE + 4 * $i}]
    set g [expr {[lindex $got $i] & 0xFFFFFFFF}]
    set w [lindex $want $i]
    if {$g != $w} {
        if {$bad < 8} { say "  [hex $a]  [hex $g]  wanted [hex $w]  <-- DIFFERS" }
        incr bad
    }
}
if {$bad > 0} {
    say "FAILED --- the poison did not take at $bad of $BLOCK_WORDS addresses."
    say "FAILED   Nothing below could tell a word the machine wrote from one"
    say "FAILED   it did not, so the run stops here rather than reporting on it."
    bye 1
}
say "  the whole block reads its poison, so anything that changes below was"
say "  written by the machine and by nothing else"

# ---------------------------------------------------------- 3. the tally, cold

# NOTHING IS CONFIGURED AND THE LEVEL SHIFTERS ARE OFF, so the EMIO inputs are
# not being driven by anything at all.  Recorded because a non-zero reading
# here would mean the numbers at step 7 could not be attributed to the fabric
# --- which is a reason to stop, not a reason to go on and subtract.
# The two registers, and the four fields taken out of them the way
# `rtl/cadr_mem_count.sv` packs them.  Returns the raw pair followed by the
# four numbers, so that a caller can assert either.
proc tally {label} {
    global DATA_2_RO DATA_3_RO
    set d2 [rd32 $DATA_2_RO]
    set d3 [rd32 $DATA_3_RO]
    set t [list $d2 $d3 \
                [expr {$d3 & 0x7FFF}] [expr {($d3 >> 16) & 0x7FFF}] \
                [expr {$d2 & 0x7FFF}] [expr {($d2 >> 16) & 0x7FFF}]]
    say "$label:"
    say "  DATA_2_RO 0xE000A068 [hex $d2]   answered [lindex $t 4] reads,\
 [lindex $t 5] writes"
    say "  DATA_3_RO 0xE000A06C [hex $d3]   asked    [lindex $t 2] reads,\
 [lindex $t 3] writes"
    return $t
}

# Whether the fabric wrote this word at all.  See the header: 0x00000000 and
# 0xFFFFFFFF are what the processing system reads off EMIO when nothing is
# driving it, and this pattern is neither.
proc marked {w} {
    return [expr {($w & 0x80008000) == 0x00008000}]
}

set cold [tally "the tally before the part is configured"]
if {[lindex $cold 0] != 0 || [lindex $cold 1] != 0} {
    say "FAILED --- the level shifters are off and nothing is configured, so"
    say "FAILED   both registers must read 0x00000000.  They read"
    say "FAILED   [hex [lindex $cold 0]] and [hex [lindex $cold 1]], which has a"
    say "FAILED   cause outside this design --- and the numbers at step 7 could"
    say "FAILED   not then be attributed to the machine."
    bye 1
}
say "  both registers read zero with the level shifters off, which is the"
say "  baseline everything below is against"

# --------------------------------------------------------- 4. ps7_post_config

say "running ps7_post_config --- LVL_SHFTR_EN at 0xF8000900 and FPGA_RST_CTRL"
say "  at 0xF8000240.  The port has to be live BEFORE the bitstream loads,"
say "  because the machine starts at configuration and reaches memory 118 ms"
say "  later whether anybody has brought the port up or not."
if {[catch {ps7_post_config} err]} { stop "ps7_post_config raised: $err" }
set shft [rd32 0xF8000900]
say "  LVL_SHFTR_EN  0xF8000900 reads [hex $shft]  wanted 0x0000000F"
say "  FPGA_RST_CTRL 0xF8000240 reads [hex [rd32 0xF8000240]]  wanted 0x00000000"
if {$shft != 0x0000000F} {
    fail "ps7_post_config did not turn the level shifters on" 0xF8000900 \
        0x0000000F $shft
}

# ------------------------------------------------------ 5. program the fabric

if {[catch {targets -set -filter {name =~ "xc7z020*"}} err]} {
    say "no target named xc7z020* ($err); `fpga` will configure the one"
    say "  supported device in the chain instead, which on this board is the"
    say "  part.  docs/board.md tabulates the chain as arm_dap_0 and xc7z020_1."
}
say "programming [file tail $bit]"
if {[catch {fpga -file [file normalize $bit]} err]} {
    stop "fpga -file $bit: $err"
}

# These return prose and not numbers; `vivado/prove_write.tcl`'s header has
# what that cost the first time somebody wrote `$state != 1`.
set state [fpga -state]
say "fpga -state reads: $state"
set irstat "unavailable"
catch {set irstat [fpga -ir-status]}
say "fpga -ir-status reads:"
foreach line [split [string trimright $irstat] "\n"] { say "  $line" }
if {[string match "*not configured*" $state] || \
    ![string match "*is configured*" $state]} {
    say "FAILED --- the part did not take the configuration, whatever"
    say "FAILED   `fpga -file` reported.  `fpga -state` says: $state"
    bye 1
}
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

# **THE MEASUREMENT THIS ORDER STANDS ON.**  If a `.bit` download cleared
# LVL_SHFTR_EN, the port would be dead again at the moment the machine
# started, every cycle would time out, and no order of these steps could fix
# it without changing the design.
set shft [rd32 0xF8000900]
say "LVL_SHFTR_EN at 0xF8000900 reads [hex $shft] AFTER programming"
if {$shft != 0x0000000F} {
    say "FAILED at 0xF8000900 --- the bitstream download cleared the level"
    say "FAILED   shifters, so S_AXI_HP0 was dead when the machine started and"
    say "FAILED   this order cannot work.  read [hex $shft], wanted 0x0000000F."
    say "FAILED   What that would need is the port's reset folded into the"
    say "FAILED   machine's, which is a design change and not this script's."
    bye 1
}
say "  SLCR kept it across the download, so the machine started with the port"
say "  already live.  That is what makes this order work."

# ------------------------------------------------------------- 6. the wait

# The machine reaches its first main-memory cycle at microcycle 536,303, which
# at the boot PROM's extra-slow 220 ns is 118.0 ms, and the parity loop closes
# at 118.4.  A second is four orders of magnitude more than it needs and costs
# nothing.
say "waiting a second; the machine reaches memory at 118 ms and is done by 118.4"
after 1000

# ------------------------------------------------------------ 7. the tally

set first  [tally "the tally, first read"]
set second [tally "the tally, second read"]
if {$first ne $second} {
    say "FAILED --- the two reads of a settled tally disagree.  The machine"
    say "FAILED   has not touched memory since 118 ms and nothing here writes"
    say "FAILED   to it, so this is its own finding and it is not the"
    say "FAILED   machine's."
    bye 1
}
say "  the two reads agree, so the tally is settled"

# WHO WROTE THE WORD, BEFORE ANY NUMBER IS TAKEN OUT OF IT.
if {![marked [lindex $first 0]] || ![marked [lindex $first 1]]} {
    say "FAILED --- the tally reads [hex [lindex $first 1]] [hex [lindex $first 0]],"
    say "FAILED   and (w & 0x80008000) == 0x00008000 does not hold in both"
    say "FAILED   halves, so nothing says the fabric wrote it."
    if {[lindex $first 0] == 0xFFFFFFFF && [lindex $first 1] == 0xFFFFFFFF} {
        say "FAILED   ALL ONES IS WHAT NOTHING-DRIVING READS.  With the level"
        say "FAILED   shifters on and no fabric on the EMIO pins the processing"
        say "FAILED   system reads them all high, so the likeliest cause is"
        say "FAILED   that this bitstream has no tally in it at all ---"
        say "FAILED   rtl/cadr_mem_count.sv is inside the DDR generate, so a"
        say "FAILED   board built with DDR=0 drives no EMIO pin.  It is not a"
        say "FAILED   reading about the machine."
    }
    bye 1
}
say "  the marker bits hold in both halves, so the fabric wrote this word"

set names {"asked reads" "asked writes" "answered reads" "answered writes"}
set wants [list $WANT_READS $WANT_WRITES $WANT_READS $WANT_WRITES]
set tally_bad 0
for {set i 0} {$i < 4} {incr i} {
    set n [lindex $first [expr {$i + 2}]]
    set w [lindex $wants $i]
    say [format "  %-16s %6d  wanted %6d  %s" [lindex $names $i] $n $w \
             [expr {$n == $w ? "" : "<-- DIFFERS"}]]
    if {$n != $w} { incr tally_bad }
}
if {$tally_bad > 0} {
    say "FAILED --- $tally_bad of the four counters is not what the boot PROM's"
    say "FAILED   page-0 parity loop makes: $WANT_READS reads and $WANT_WRITES\
 writes, asked"
    say "FAILED   for and answered."
    if {[lindex $first 2] == 0 && [lindex $first 3] == 0} {
        say "FAILED   NOTHING WAS ASKED FOR, on a word the fabric did write:"
        say "FAILED   the marker bits held, so the tally is in this bitstream"
        say "FAILED   and is reporting that the machine never reached its"
        say "FAILED   memory cycles.  It is not running, or it is not the"
        say "FAILED   machine this bitstream was meant to hold.  LD0 and LD1"
        say "FAILED   on the board say which; docs/board.md tabulates them."
    } elseif {[lindex $first 4] == 0 && [lindex $first 5] == 0} {
        say "FAILED   THE MACHINE ASKED AND NOTHING ANSWERED.  Every one of"
        say "FAILED   its [lindex $first 2] reads and [lindex $first 3] writes\
 ended on the NXM"
        say "FAILED   timer.  That is a dead S_AXI_HP0 --- the level shifters,"
        say "FAILED   the port's reset, or the adapter held in it --- and not"
        say "FAILED   a machine that failed to run."
    }
    bye 1
}
say "  all four are $WANT_READS/$WANT_WRITES: the processing system answered\
 every cycle the"
say "  machine asked for, at its own handshakes, which is the positive witness"
say "  an identity copy cannot leave behind"

# ------------------------------------------------------------ 8. the block

set b1 [rdn $MAIN_BASE $BLOCK_WORDS]
set b2 [rdn $MAIN_BASE $BLOCK_WORDS]
if {$b1 ne $b2} {
    say "FAILED --- the two reads of a settled block disagree.  Nothing was"
    say "FAILED   written between them, and S_AXI_HP0 is not coherent with"
    say "FAILED   anything the APU holds, so a stale line is the first thing"
    say "FAILED   to suspect.  That is its own finding."
    bye 1
}
set bad 0
for {set i 0} {$i < $BLOCK_WORDS} {incr i} {
    set a [expr {$MAIN_BASE + 4 * $i}]
    set g [expr {[lindex $b1 $i] & 0xFFFFFFFF}]
    set w [lindex $want $i]
    if {$g != $w} {
        if {$bad < 16} {
            say "  [hex $a]  [hex $g]  wanted [hex $w]  <-- DIFFERS"
        }
        incr bad
    }
}
say "the block, read twice and identical: $BLOCK_WORDS words,\
 [expr {$BLOCK_WORDS - $bad}] of them their poison"
if {$bad > 0} {
    say "FAILED --- $bad word(s) of $BLOCK_WORDS are not their poison.  The"
    say "FAILED   parity loop is an IDENTITY copy: it writes back the word its"
    say "FAILED   own read returned, so a changed word means the machine wrote"
    say "FAILED   something other than what it read, or wrote it somewhere"
    say "FAILED   else.  The first sixteen are named above."
    bye 1
}

set rdbg [rd32 $AFI_RDDEBUG]
set wdbg [rd32 $AFI_WRDEBUG]
say "AFI0 debug registers:"
say "  RDDEBUG_R 0xF8008010 [hex $rdbg]   overflow bit 0 = [expr {$rdbg & 1}]"
say "  WRDEBUG_R 0xF8008024 [hex $wdbg]   overflow bit 0 = [expr {$wdbg & 1}]"
if {($rdbg & 1) != 0} {
    fail "AFI0's read channel reports an overflow" $AFI_RDDEBUG 0 [expr {$rdbg & 1}]
}
if {($wdbg & 1) != 0} {
    fail "AFI0's write channel reports an overflow" $AFI_WRDEBUG 0 [expr {$wdbg & 1}]
}

# ----------------------------------------------------------------------- done

say "PASSED --- the machine ran out of DDR."
say "  $WANT_READS reads and $WANT_WRITES writes asked for at the memory port,"
say "  and the processing system answered every one of them at its own B and R"
say "  handshakes.  Page 0 and the 768 words above it still hold the poison"
say "  this script wrote, so the copy was the identity it is meant to be, and"
say "  neither AFI0 channel overflowed."
bye 0
