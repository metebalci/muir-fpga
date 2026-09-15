# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The two proving steps, ported: does the FABRIC write real memory, and does it
# read it?
#
#     PROVE=1 CABLE=<serial> vivado -mode batch \
#         -source boards/arty-a7-100/vivado/prove.tcl
#
# WHAT A PROVING BOARD IS.  `rtl/plumbing/cadr_prove.sv` in the machine's place
# on the memory port, driving `mem_*`'s own wires into the same crossing, the
# same user interface and the same controller the machine will --- a witness
# with a path of its own would prove that path and say nothing about this one.
# `PROVE=1` writes one known word at one known address.  `PROVE=2` reads that
# address and writes WHAT IT READ, raw, to a second one.
#
# **AND THE SECOND IS NOT A MATCH BIT.**  A witness that compared what came
# back against a constant it holds itself would agree with a witness that read
# the wrong lane and held the wrong constant.  The write-back puts the word
# itself where the debugger can read it, which is what this script asserts.
#
# THE ORDER, AND WHY THE WITNESS IS HELD UNTIL THIS SCRIPT SAYS SO.  The poison
# has to be in memory BEFORE the witness writes into it, and on this board the
# poison goes through the same window the witness's port does.  So the witness
# comes out of reset only when the `arm` bit is scanned in, and every later
# rise of that bit runs the whole sequence again with no reprogramming --- what
# toggling `LVL_SHFTR_EN` bought on the Arty Z7-20.
#
# THE THREE CONSTANTS ARE THE OTHER BOARD'S, unchanged, so that the two boards'
# proving steps are one exercise: an address that is not the region's base,
# whose bit 2 is set so the word is not the first lane of its sixteen-byte
# block, and whose bits alternate so a dropped one moves it somewhere
# unrelated; a word of four distinct bytes, neither half a rotation of the
# other; and an echo address seven blocks away with bit 2 clear, so a read
# takes a high lane and the write-back opens a low one.

set here [file dirname [file normalize [info script]]]
source $here/mem_window.tcl

set cable [expr {[info exists ::env(CABLE)] ? $::env(CABLE) : ""}]
set url   [expr {[info exists ::env(HW_SERVER)] ? $::env(HW_SERVER)
                                                : "localhost:3121"}]
set prove [expr {[info exists ::env(PROVE)] ? $::env(PROVE) : 0}]
if {$cable eq "" || ($prove != 1 && $prove != 2)} {
    puts "MEM: FAILED --- CABLE must name the JTAG cable's serial and PROVE"
    puts "MEM: must be 1 (the fabric writes) or 2 (the fabric reads)."
    exit 1
}

# `cadr_ddr_map::main_byte_address(22'o12345671)` and its echo, and the word,
# as `boards/arty-a7-100/cadr_arty_a7.sv` ties them.
set prove_addr 0x18A72EE4
set prove_word 0x8A5C36E1
set prove_echo 0x18A72F18

window_open $cable $url
set st [window_settle]
puts "MEM: the window answers [format 0x%08x [dict get $st ident]] (\"MEMW\")"
if {![dict get $st calib]} {
    window_fail "MEM: FAILED --- the controller has not calibrated the DDR3L."
}

# ---- the neighborhood, poisoned.  Sixteen blocks around the address, so that
# every lane of its own block and both its neighbors are recognizable.
set base [expr {$prove_addr & ~0xFF}]
for {set i 0} {$i < 64} {incr i} {
    set a [expr {$base + 4 * $i}]
    window_issue 1 $a [poison $a]
}
if {$prove == 2} {
    # ...and the word the fabric is to read, put there by the debugger.
    window_issue 1 $prove_addr $prove_word
}
window_settle
puts "MEM: 64 words poisoned around [format 0x%08x $prove_addr]"

# ---- release the witness and let it run
window_arm
after 200
set st [window_settle]
if {![dict get $st prove_has_run]} {
    window_fail \
        "MEM: FAILED --- the witness has not run. It comes out of reset on the" \
        "MEM: rise of the arm bit and one sequence is two transactions, which" \
        "MEM: is microseconds. Either this is not a PROVE bitstream, or the" \
        "MEM: port never answered it."
}
puts "MEM: the witness has run; its own comparison says\
 [expr {[dict get $st prove_matched] ? {they matched} : {they did not match}}]"

# ---- and what it did, read by the debugger rather than by the fabric
if {$prove == 1} {
    set got [dict get [window_read $prove_addr] rdata]
    if {$got != $prove_word} {
        window_fail \
            "MEM: FAILED --- [format 0x%08x $prove_addr] reads" \
            "MEM: [format 0x%08x $got] and the fabric was to write" \
            "MEM: [format 0x%08x $prove_word]." \
            "MEM: If it reads this address's own poison the write never" \
            "MEM: happened; if it reads a NEIGHBOR's poison the write went to" \
            "MEM: the wrong lane or the wrong block, and the poison is a" \
            "MEM: function of the address, so which one says which."
    }
    puts "MEM: the fabric's word is at its address, read by the debugger"
    # ...and the three lanes it shares a block with are untouched.
    set bad 0
    for {set l 0} {$l < 4} {incr l} {
        set a [expr {($prove_addr & ~0xF) + 4 * $l}]
        if {$a == $prove_addr} { continue }
        set got [dict get [window_read $a] rdata]
        if {$got != [poison $a]} {
            puts "MEM: [format 0x%08x $a] reads [format 0x%08x $got], wanting\
 its poison [format 0x%08x [poison $a]]"
            incr bad
        }
    }
    if {$bad} {
        window_fail \
            "MEM: FAILED --- the fabric's one-word write disturbed $bad of the" \
            "MEM: three other 32-bit lanes of its own sixteen-byte block. The" \
            "MEM: controller moves 128 bits a transaction and the byte mask is" \
            "MEM: what keeps a 32-bit write to its own quarter of it."
    }
    puts "MEM: the three lanes it shares a block with are untouched"
    puts "MEM: PASSED --- the fabric writes this board's own DDR3L, in the"
    puts "MEM: right lane of the right block, and the debugger read it back."
} else {
    set got [dict get [window_read $prove_echo] rdata]
    if {$got != $prove_word} {
        window_fail \
            "MEM: FAILED --- the echo at [format 0x%08x $prove_echo] reads" \
            "MEM: [format 0x%08x $got] and the fabric read and wrote back" \
            "MEM: [format 0x%08x $prove_word]." \
            "MEM: Its own poison means the write-back never happened; the" \
            "MEM: poison of the address it READ means the fabric took the" \
            "MEM: wrong lane and wrote what it found there, which is the one" \
            "MEM: fault a match bit inside the fabric could not tell from" \
            "MEM: success."
    }
    puts "MEM: PASSED --- the fabric reads this board's own DDR3L: the word the"
    puts "MEM: debugger put at [format 0x%08x $prove_addr] came back out at"
    puts "MEM: [format 0x%08x $prove_echo], raw, with no constant in between."
}

window_close
exit 0
