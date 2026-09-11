# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Step three: the debugger writes a word, the fabric reads it, and the fabric
# writes back what it read.
#
#     timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/prove_read.tcl
#     BIT=build/prove-read/cadr_arty.bit BOARD_URL=<host>:3121 \
#         timeout 900 ~/Xilinx/2026.1/Vivado/bin/xsdb boards/arty-z7-20/vivado/prove_read.tcl
#
# Run from the repository root.  `boards/arty-z7-20/vivado/prove_write.tcl` is step two and
# `boards/arty-z7-20/vivado/ddr_check.tcl` step one; neither is repeated here.
#
# THIS SCRIPT NOW ANSWERS THE QUESTION INSTEAD OF SETTING IT UP.  Its first
# version could not: `PROVE=2` started the read on BTN1 and answered on LD4,
# so both halves of step three needed a finger and an eye, and the board is on
# the end of a JTAG cable.  Two changes made it a program.
#
#   **THE FABRIC WRITES WHAT IT READ TO A SECOND ADDRESS.**  `PROVE_ECHO` is
#   in DDR, so the answer is a value this script can read --- and reading a
#   VALUE rather than a lamp is what makes the check sharp.  A lamp is the
#   fabric comparing what came back against a constant the fabric itself
#   holds, so a witness that read the wrong lane and a witness that held the
#   wrong constant agree with each other and light green either way.  The word
#   written out raw carries the evidence: a lane swap, a shift or a byte
#   reversal is visible IN THE VALUE.
#
#   **`SAXIHP0ARESETN` FOLLOWS `LVL_SHFTR_EN` AT 0xF8000900**, measured at
#   700b98a, so writing that register 0x0 and then 0xF drops the port and
#   raises it, and the witness --- whose `go` is tied high --- runs the whole
#   sequence again.  That is the re-arm, and it needs no reprogramming, so all
#   three cases fit in one session with one bitstream download.
#
# THE THREE CASES, AND WHY THE NEGATIVES COME FIRST.  A fabric that wrote out
# its own constant instead of the word it read passes the positive case, so
# the positive case alone proves nothing.  They are run in this order and the
# order is not optional:
#
#   wrong   0x8A5C36E0 at 0x18A72EE4 --- the word with bit 0 cleared.  The
#           witness reads the right address, in the right half, and gets a
#           word that differs in one bit.  0x8A5C36E0 must come back at
#           `PROVE_ECHO`.  If 0x8A5C36E1 comes back, the fabric is writing out
#           a constant it holds and not what the memory gave it, which is the
#           lamp's failure mode with the lamp removed.  One bit rather than a
#           wholly different word because a comparison that dropped a bit
#           would pass anything coarser.
#
#   half    0x8A5C36E1 at 0x18A72EE0 --- the LOW half of the same 64-bit beat
#           --- with the filler left at 0x18A72EE4.  The word is present in
#           DDR and in the wrong half of the beat, so what the witness reads
#           is the FILLER, and the filler is what must come back at
#           `PROVE_ECHO`.  This is the case that says `cadr_axi_widen.sv`
#           takes the half the address asks for and not whichever half has
#           something in it.
#
#   right   0x8A5C36E1 at 0x18A72EE4.  0x8A5C36E1 must come back, and it means
#           something only after the two above have come back wrong in their
#           own two ways.
#
# THE ECHO BEAT HAS A FILLER OF ITS OWN, 0x3C7A91D6, AND THAT IS THE SHARP
# PART OF THE `half` CASE.  In that case the witness reads 0x75A3C91E --- the
# block's filler --- and writes it out; if `PROVE_ECHO` already held
# 0x75A3C91E, a write-back that happened and one that never happened would
# read back identically.  That is CLAUDE.md's "a memory whose only exercise
# writes one constant tests nothing", one move along, and it is why the two
# words of the echo beat get a third value: 0x3C7A91D6 is none of the three
# words the witness can possibly echo (0x8A5C36E1, 0x8A5C36E0, 0x75A3C91E),
# has four distinct bytes and none of them 0x00 or 0xFF.
#
# WHAT EACH CASE CHECKS, BEYOND THE ONE WORD.
#
#   - `PROVE_ECHO`'s NEIGHBOUR, 0x18A72F1C, is the other half of its 64-bit
#     beat and must still hold 0x3C7A91D6.  The write-back goes through
#     `cadr_axi_widen.sv` like any other write, so a strobe pattern that
#     opened both halves would destroy it --- the same check step two makes
#     about its own write, one address along.  `PROVE_ECHO` has bit 2 CLEAR
#     where `PROVE_ADDR` has it set, so the read takes the high half of its
#     beat and the write-back opens the low half of another: a widening stuck
#     on one half is caught in one direction or the other.
#
#   - THE BEAT THE READ CAME OUT OF IS UNCHANGED.  `PROVE_ECHO` is seven beats
#     from `PROVE_ADDR` so that the write-back cannot reach the word it read;
#     printing 0x18A72EE0 and 0x18A72EE4 afterwards is what says so.
#
#   - AND EVERY OTHER WORD OF THE THIRTY-TWO still holds the filler, printed
#     either way, because an exit code cannot tell two failures apart.
#
# WHAT LD4 SAYS, from `boards/arty-z7-20/cadr_arty.sv`'s `lamp4`.  Nothing here asserts it
# --- a script cannot see a lamp, and the value at `PROVE_ECHO` says more ---
# but it costs nothing and somebody at the board can read it:
#
#   red, blinking   the port is dead: `ps7_post_config` has not run, or did
#                   not release SAXIHP0ARESETN.  Nothing has happened.
#   red, steady     the port is live and nothing has completed.
#   green           the sequence completed and the word matched: the `right`
#                   case, and only it.
#   blue            the sequence completed and the word did not match: the
#                   `wrong` and `half` cases, and a refused transaction.
#
# LD0 to LD3 and LD5 read exactly as `docs/board.md` tabulates them for a
# board with no memory, because on a `PROVE` board the machine's `mem_done` is
# tied low and its own cycles still end on the NXM timer.

set url  [expr {[info exists ::env(BOARD_URL)] ? $::env(BOARD_URL) : ""}]
set init [expr {[info exists ::env(PS7_INIT)] ? $::env(PS7_INIT) \
                                              : "build/ps7/ps7_init.tcl"}]
set bit  [expr {[info exists ::env(BIT)] ? $::env(BIT) \
                                         : "build/prove-read/cadr_arty.bit"}]

# ------------------------------------------------------------------ the map
# The same numbers `boards/arty-z7-20/cadr_arty.sv` gives the witness, and the block around
# them.  `PROVE_ECHO` is `main_byte_address(22'o12345706)` there.
#
# THE ADDRESSES ARE HELD AS INTEGERS AND THE WORDS AS THEY ARE WRITTEN.  Every
# address here is also an array key --- the expectation for each of the
# thirty-two words is kept per address --- and the keys the block loop makes
# are `[expr {$BLOCK_BASE + 4 * $i}]`, which Tcl gives in decimal.  A constant
# left as the string `0x18A72F18` would be a DIFFERENT key from the same
# address arrived at by arithmetic, and the expectation set against it would
# quietly never be read.  `hex` is what puts them back for printing.
set PROVE_ADDR   [expr {0x18A72EE4}]
set PROVE_NEIGH  [expr {0x18A72EE0}]
set PROVE_ECHO   [expr {0x18A72F18}]
set ECHO_NEIGH   [expr {0x18A72F1C}]
set PROVE_WORD   0x8A5C36E1
set PROVE_POISON 0x75A3C91E
set ECHO_POISON  0x3C7A91D6

# 0x18A72EC0 through 0x18A72F3C: thirty-two words, with PROVE_ADDR ninth and
# PROVE_ECHO twenty-third.
set BLOCK_BASE   [expr {0x18A72EC0}]
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
    global connected saved_mode
    catch {configparams force-mem-accesses $saved_mode}
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
    return [expr {[lindex [mrd -force -value [hex $addr] 1] 0] & 0xFFFFFFFF}]
}

proc rdn {addr n} {
    return [mrd -force -value [hex $addr] $n]
}

proc wr32 {addr val} {
    mwr -force [hex $addr] [expr {$val & 0xFFFFFFFF}]
}

# Print the whole block against a per-address expectation held in an array,
# and return the list of addresses that disagreed.  Every word is printed
# either way: a check on a program has to say which word was wrong, and a
# count of failures is not that.
proc show_block {label words expname marks} {
    global BLOCK_BASE
    upvar 1 $expname expect
    array set mark $marks
    set bad {}
    say "$label:"
    set i 0
    foreach w $words {
        set a    [expr {$BLOCK_BASE + 4 * $i}]
        set g    [expr {$w & 0xFFFFFFFF}]
        set want [expr {$expect($a) & 0xFFFFFFFF}]
        set note ""
        if {[info exists mark($a)]} { set note $mark($a) }
        if {$g != $want} {
            set note "<-- DIFFERS  $note"
            lappend bad $a
        }
        say [format "  %s  %s  wanted %s   %s" [hex $a] [hex $g] [hex $want] $note]
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
    say "FAILED   PROVE=2 OUTDIR=build/prove-read vivado -mode batch \\"
    say "FAILED       -source boards/arty-z7-20/vivado/bitstream.tcl"
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
    say "FAILED --- no APU target: $err"
    catch {disconnect}
    exit 1
}

set saved_mode [configparams force-mem-accesses]
configparams force-mem-accesses 1

# ------------------------------------------- the part, and the silicon version
#
# Both asserted for the reasons `boards/arty-z7-20/vivado/ddr_check.tcl`'s header gives at
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
    stop "$init defined no ps7_post_config, which arms the first case"
}
say "running ps7_init --- it prints nothing on success"
if {[catch {ps7_init} err]} { stop "ps7_init raised: $err" }
say "ps7_init returned without error"

wr32 0x18000000 0x5A5AA5A5
set probe [rd32 0x18000000]
say "DDR answers at 0x18000000: wrote 0x5A5AA5A5, read [hex $probe]"
if {$probe != 0x5A5AA5A5} {
    stop "DDR does not answer after ps7_init; boards/arty-z7-20/vivado/ddr_check.tcl isolates this"
}

# ------------------------------------------------------ 2. program the fabric
#
# The port back to sleep before the bitstream loads.  SLCR survives `ps7_init`
# and a `.bit` download, so a second run in one power-on finds LVL_SHFTR_EN
# already 0xF, the port already live, and the witness firing THE INSTANT THE
# PART CONFIGURES --- before the block below is laid out, so the layout would
# erase the write-back it was meant to reveal.  It cost one run at 700b98a.

set shft [rd32 0xF8000900]
say "LVL_SHFTR_EN at 0xF8000900 reads [hex $shft] before programming"
if {$shft != 0} {
    say "  the port is already live, which would make the witness fire at"
    say "  configuration and the block below erase what it wrote.  Clearing"
    say "  it, so that ps7_post_config is a transition and not a no-op."
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
# decode --- and a first draft of `boards/arty-z7-20/vivado/prove_write.tcl` asserted them as
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

# ------------------------------------------------------------- 3. the cases
#
# Each is a layout, an arming, and a read of one address.  The first arming is
# `ps7_post_config`; every later one is the LVL_SHFTR_EN toggle, which is the
# same transition by hand and needs no reprogramming.

# name  put_addr     put_word     what must come back at PROVE_ECHO   lamp
set cases [list \
    [list wrong $PROVE_ADDR  0x8A5C36E0 0x8A5C36E0 BLUE \
     "the address holds the word with bit 0 cleared, so the witness must echo\
 0x8A5C36E0.  0x8A5C36E1 coming back would mean the fabric writes out a\
 constant it holds rather than what the memory gave it"] \
    [list half  $PROVE_NEIGH $PROVE_WORD $PROVE_POISON BLUE \
     "the word is in the LOW half of the beat and the witness asks for the\
 HIGH one, so what it reads is the filler and the filler is what must come\
 back.  0x8A5C36E1 coming back would mean the widening returns whichever half\
 has something in it"] \
    [list right $PROVE_ADDR  $PROVE_WORD $PROVE_WORD GREEN \
     "the word is at the address the witness asks for, in the high half of the\
 beat where bit 2 of the address puts it, so it must come back unaltered"]]

set case_no 0
set passed {}

foreach c $cases {
    lassign $c name put_addr put_word echo_want lamp why
    incr case_no
    say ""
    say "=============================================================="
    say "case $name --- [hex $echo_want] must come back at [hex $PROVE_ECHO],"
    say "  because $why."

    # ---- the layout, and what the block should read before and after
    #
    # Poison everything, then the echo beat's own filler over its two words,
    # then the case's word.  Order matters only in that the case's word is
    # last, and PROVE_ADDR is never in the echo beat.
    for {set i 0} {$i < $BLOCK_WORDS} {incr i} {
        wr32 [expr {$BLOCK_BASE + 4 * $i}] $PROVE_POISON
    }
    wr32 $PROVE_ECHO $ECHO_POISON
    wr32 $ECHO_NEIGH $ECHO_POISON
    wr32 $put_addr $put_word

    unset -nocomplain before after
    for {set i 0} {$i < $BLOCK_WORDS} {incr i} {
        set a [expr {$BLOCK_BASE + 4 * $i}]
        set before($a) $PROVE_POISON
        set after($a)  $PROVE_POISON
    }
    set before($PROVE_ECHO) $ECHO_POISON
    set after($PROVE_ECHO)  $echo_want
    set before($ECHO_NEIGH) $ECHO_POISON
    set after($ECHO_NEIGH)  $ECHO_POISON
    set before($put_addr)   $put_word
    set after($put_addr)    $put_word

    set marks [list \
        $put_addr    "<-- the word put in" \
        $PROVE_ECHO  "<-- what it writes back" \
        $ECHO_NEIGH  "<-- the other half of that beat"]
    if {$put_addr != $PROVE_ADDR} {
        lappend marks $PROVE_ADDR "<-- what the witness reads"
    }

    set bad [show_block "the block as the witness will find it" \
                 [rdn $BLOCK_BASE $BLOCK_WORDS] before $marks]
    if {[llength $bad] > 0} {
        say "FAILED --- the block is not what was written at [llength $bad] address(es):"
        foreach a $bad { say "FAILED   [hex $a]" }
        say "FAILED   The witness would be reading something nobody chose, so"
        say "FAILED   nothing below could say anything about the fabric."
        bye 1
    }

    # ---- the arming
    if {$case_no == 1} {
        say "arming with ps7_post_config --- the port comes live for the first"
        say "  time since the bitstream loaded, and the witness runs"
        if {[catch {ps7_post_config} err]} { stop "ps7_post_config raised: $err" }
        say "  LVL_SHFTR_EN  0xF8000900 reads [hex [rd32 0xF8000900]]  wanted 0x0000000F"
        say "  FPGA_RST_CTRL 0xF8000240 reads [hex [rd32 0xF8000240]]  wanted 0x00000000"
    } else {
        say "re-arming by LVL_SHFTR_EN 0x0 then 0xF --- SAXIHP0ARESETN follows"
        say "  that register, so this is the witness's reset and `go` is tied"
        say "  high, which is one more sequence and no reprogramming"
        wr32 0xF8000900 0x00000000
        set down [rd32 0xF8000900]
        say "  LVL_SHFTR_EN reads [hex $down]  wanted 0x00000000 (the port is dead)"
        if {$down != 0} { stop "LVL_SHFTR_EN will not clear; the port cannot be reset" }
        wr32 0xF8000900 0x0000000F
        set up [rd32 0xF8000900]
        say "  LVL_SHFTR_EN reads [hex $up]  wanted 0x0000000F (the port is live)"
        if {$up != 0xF} { stop "LVL_SHFTR_EN will not set; the port cannot come back" }
    }

    # One read, sixteen ticks of setup, one write, sixteen more.  This is six
    # orders of magnitude more than that and costs nothing.
    after 200

    # ---- the verdict
    #
    # Read twice.  The fabric writes through `S_AXI_HP0`, which is not coherent
    # with anything the APU holds, so a debugger read served from a stale line
    # would show the filler for a write-back that did land.  Two reads that
    # agree do not rule that out; two that disagree name it immediately.
    set first  [rdn $BLOCK_BASE $BLOCK_WORDS]
    set second [rdn $BLOCK_BASE $BLOCK_WORDS]
    set bad [show_block "the block after the witness ran" $first after $marks]
    if {$first ne $second} {
        say "re-read: DIFFERENT --- two reads of a settled block disagree."
        show_block "the block, read a second time" $second after $marks
        say "That is its own finding and it is not the fabric's: nothing was"
        say "written between the two reads."
        bye 1
    }
    say "re-read: identical, so what the block holds is stable"

    set got [expr {[lindex $first 22] & 0xFFFFFFFF}]
    say "[hex $PROVE_ECHO] reads [hex $got], wanted [hex $echo_want]"
    say "  LD4 should be $lamp on this case, and nothing here can see it"

    if {[llength $bad] == 0} {
        say "case $name PASSED"
        lappend passed $name
        continue
    }

    say "FAILED --- case $name: [llength $bad] word(s) of $BLOCK_WORDS are not"
    say "FAILED   what was wanted:"
    foreach a $bad { say "FAILED   [hex $a]" }
    if {[lsearch -exact $bad $PROVE_ECHO] >= 0} {
        say "FAILED   [hex $PROVE_ECHO] is among them, which is the answer"
        say "FAILED   itself.  It reads [hex $got] and should read"
        say "FAILED   [hex $echo_want].  Three readings, in order of how far"
        say "FAILED   they point from here:"
        say "FAILED     [hex $ECHO_POISON] --- the echo beat's own filler, so"
        say "FAILED       nothing was written back at all: the read never"
        say "FAILED       completed, or the write-back never went out."
        say "FAILED     [hex $PROVE_WORD] where something else was wanted ---"
        say "FAILED       the fabric is writing out a constant it holds and"
        say "FAILED       not what the memory gave it, which is exactly what"
        say "FAILED       writing the word back instead of a match bit was"
        say "FAILED       meant to catch."
        say "FAILED     anything else --- the word came back altered, and the"
        say "FAILED       value says how: a lane swap, a shift or a byte"
        say "FAILED       reversal of [hex $put_word] is visible in it."
    }
    if {[lsearch -exact $bad $ECHO_NEIGH] >= 0} {
        say "FAILED   [hex $ECHO_NEIGH] is among them, which is the other half"
        say "FAILED   of the write-back's own 64-bit beat: the write-back"
        say "FAILED   opened both halves.  That is cadr_axi_widen.sv's"
        say "FAILED   strobes, and PROVE_ECHO has bit 2 clear so that this"
        say "FAILED   could be seen at all."
    }
    # AND ONE EXPLANATION THAT IS NOT A FAULT AT ALL, checked before the
    # one that is.  Point this script at `build/prove-write/cadr_arty.bit` ---
    # the same file name one directory over --- and every symptom below is
    # produced by a perfectly good board: nothing comes back at PROVE_ECHO
    # because a `PROVE=1` witness never reads, and PROVE_ADDR changes because
    # it writes PROVE_WORD there when the port comes live.  Measured, by
    # running exactly that.  Without this the run would name the write-back
    # reaching the word it read, which is a suspect that is not in the room
    # --- CLAUDE.md's lesson about a diagnostic naming a suspect its own
    # check will never see, met from the other side.
    set at_addr    [expr {[lindex $first 9] & 0xFFFFFFFF}]
    set wrote_word [expr {$PROVE_WORD & 0xFFFFFFFF}]
    set put_here   [expr {$put_addr == $PROVE_ADDR && \
                          ([expr {$put_word & 0xFFFFFFFF}] == $wrote_word)}]
    if {$got == [expr {$ECHO_POISON & 0xFFFFFFFF}] && \
        $at_addr == $wrote_word && !$put_here} {
        say "FAILED   AND THIS IS WHAT A `PROVE=1` BITSTREAM LOOKS LIKE, which"
        say "FAILED   would be the wrong file and not a fault: nothing came"
        say "FAILED   back at [hex $PROVE_ECHO] because a write board never"
        say "FAILED   reads, and [hex $PROVE_ADDR] holds [hex $PROVE_WORD]"
        say "FAILED   because a write board puts it there when the port comes"
        say "FAILED   live.  Check BIT= --- step two's board and step three's"
        say "FAILED   are two bitstreams with the same file name."
    } elseif {[lsearch -exact $bad $PROVE_ADDR] >= 0 || \
              [lsearch -exact $bad $PROVE_NEIGH] >= 0} {
        say "FAILED   the beat the read came out of has changed, so the"
        say "FAILED   write-back reached the word it was reading.  PROVE_ECHO"
        say "FAILED   is seven beats away from PROVE_ADDR precisely so that it"
        say "FAILED   cannot."
    }
    if {[llength $passed] > 0} {
        say "FAILED   cases that passed before this one: $passed"
    }
    set left {}
    foreach c2 $cases { lappend left [lindex $c2 0] }
    set left [lrange $left $case_no end]
    if {[llength $left] > 0} {
        say "FAILED   not run: $left"
    }
    bye 1
}

say ""
say "PASSED --- all three cases, in one session and one bitstream download."
say "  wrong  0x8A5C36E0 went in at [hex $PROVE_ADDR] and came back at [hex $PROVE_ECHO]"
say "  half   the word went in one half over and the FILLER came back"
say "  right  [hex $PROVE_WORD] went in and came back"
say "  The fabric reads DDR through cadr_ps7 -> cadr_axi_widen ->"
say "  cadr_axi_master and puts what it read back where this script could"
say "  find it, and the two negatives say the value is the memory's and not"
say "  the fabric's own."
bye 0
