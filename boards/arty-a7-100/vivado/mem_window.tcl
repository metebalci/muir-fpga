# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The debugger's side of the memory window: procedures, sourced by the scripts
# that use them.
#
# WHY THERE IS A WINDOW AT ALL.  On the Arty Z7-20 the debugger reaches DDR
# through the processing system, on a controller port the fabric never touches,
# and every claim that board has made about its memory rests on that
# separation.  An Artix-7 has no debug access port onto memory and no second
# master anywhere, so the only way in is the fabric --- and
# `rtl/plumbing/cadr_jtag_mem.sv` is the smallest one that can be built: a
# register on a second `BSCANE2` user chain, in front of the memory port,
# taking it when the machine is not using it.  That module's header says what
# the loss of separation costs and what makes the instrument sharp anyway.
#
# **WHAT MAKES IT SHARP IS HERE AND NOT IN THE FABRIC.**  The poison below is
# computed by this script, is injective in the address, and differs in every
# lane of every sixteen-byte block.  A dropped address bit makes two addresses
# land on one word and the first one read back carries the second one's poison;
# a lane select stuck at one value collapses four words into one and the
# read-back shows the last one written four times.  Neither is visible to a
# check that writes one word and reads it back.
#
# THE SCAN.  One data register of 160 bits.  What shifts out was captured at
# the start of the scan and what shifts in takes effect at its end, so a read
# is two scans and the fabric has done the work in between --- microseconds,
# against a scan that takes milliseconds.  The command runs on a CHANGE of its
# `go` bit and not on its level, so scanning the same word twice is harmless
# and a host may poll.
#
# The bit numbers below and `cadr_jtag_mem.sv`'s are one layout, and Vivado's
# `scan_dr_hw_jtag` shifts the least significant bit first in both directions,
# so a bit number here is that file's bit number.

# ------------------------------------------------------------- the layout
set ::W_BITS      160
set ::W_HEX       [expr {$::W_BITS / 4}]
set ::W_IDENT     0x4D454D57            ;# "MEMW"
set ::W_PART      0x13631093            ;# XC7A100T
set ::W_IRLEN     6
set ::W_USER2     0x03                  ;# 000011, the second user chain
# What the machine's own memory map calls the bottom of its reservation.
set ::W_BASE      0x18000000

proc bits {value pos width} {
    return [expr {($value >> $pos) & ((1 << $width) - 1)}]
}

# **NOT `format %llx`.**  The command word carries a bit at position 67, so it
# does not fit in sixty-four bits, and Tcl's `format` refuses a value that
# large --- while `>>` and `&` carry arbitrary precision happily.  A hex string
# built a digit at a time is the difference between a script that works and one
# that stops with "integer value too large to represent" on the first command
# it sends.
proc hexof {value width} {
    set digits [expr {($width + 3) / 4}]
    set out ""
    for {set i [expr {$digits - 1}]} {$i >= 0} {incr i -1} {
        append out [format %x [expr {($value >> (4 * $i)) & 0xF}]]
    }
    return $out
}

proc window_fail {args} {
    foreach line $args { puts $line }
    catch { close_hw_target }
    catch { disconnect_hw_server }
    exit 1
}

# The poison: injective in the byte address, different in every lane.  It is
# the project's own idiom --- `cadr_machine_tb.cpp` poisons DDR the same way,
# and `busint_xbus.golden`'s model answers an unwritten word with a function of
# its address for the same reason.
proc poison {addr} {
    return [expr {(0xC5A30000 ^ (($addr >> 2) * 0x9E3779B1)) & 0xFFFFFFFF}]
}

# ------------------------------------------------------- opening the chain
proc window_open {cable url} {
    open_hw_manager
    connect_hw_server -url $url
    puts "MEM: connected to $url"

    set matched {}
    foreach t [get_hw_targets -quiet] {
        if {[string first $cable $t] >= 0} { lappend matched $t }
    }
    if {[llength $matched] != 1} {
        window_fail \
            "MEM: FAILED --- [llength $matched] target(s) carry the serial" \
            "MEM: $cable. Exactly one is wanted: none means the board is" \
            "MEM: unplugged or another server holds it, and more than one" \
            "MEM: means the serial is a prefix of two. More than one board is" \
            "MEM: on this host's USB and none of these scripts has a default."
    }
    current_hw_target [lindex $matched 0]

    # The hardware manager counts the devices; the raw scan says where they sit
    # and how wide their registers are.  The two are checked against each
    # other, which is how the other board's probe found a chain it had assumed.
    open_hw_target
    set n 0
    foreach d [get_hw_devices] { incr n }
    close_hw_target
    if {$n != 1} {
        window_fail "MEM: FAILED --- the hardware manager sees $n device(s);" \
                    "MEM: an Artix-7 is the whole chain and there is one."
    }

    open_hw_target -jtag_mode 1
    run_state_hw_jtag RESET
    set raw [scan_dr_hw_jtag 64 -tdi [string repeat f 16]]
    set val 0x$raw
    set idcode [bits $val 0 32]
    set tail   [bits $val 32 32]
    if {$idcode != $::W_PART || $tail != 0xffffffff} {
        window_fail \
            "MEM: FAILED --- the chain reads IDCODE [format 0x%08x $idcode]" \
            "MEM: followed by [format 0x%08x $tail]. This board's part is" \
            "MEM: [format 0x%08x $::W_PART] and nothing behind it, so TDI's own" \
            "MEM: ones should come straight back. A different chain here is a" \
            "MEM: different board, and every scan below would be talking to it."
    }
    puts "MEM: one device, IDCODE [format 0x%08x $idcode], the whole chain"

    # USER2, and the instruction register's own capture read back as it is
    # replaced.  A TAP that captures something other than xxxxx1 is not a
    # seven-series TAP and the instruction is going nowhere.
    run_state_hw_jtag RESET
    set cap 0x[scan_ir_hw_jtag $::W_IRLEN -tdi [hexof $::W_USER2 $::W_IRLEN]]
    if {($cap & 0x03) != 0x01} {
        window_fail \
            "MEM: FAILED --- the instruction register captured" \
            "MEM: [format 0x%02x $cap], wanting 01 in its low two bits." \
            "MEM: That is IEEE 1149.1's own rule and every seven-series part" \
            "MEM: keeps it, so this is not the chain this script believes in."
    }
    puts "MEM: USER2 selected (IR [hexof $::W_USER2 $::W_IRLEN], capture\
 [format 0x%02x $cap])"
}

proc window_close {} {
    close_hw_target
    disconnect_hw_server
}

# ------------------------------------------------------------- one scan
#
# `cmd` is the 160-bit word to shift in.  Returns the 160-bit word that was
# captured at the start of the scan, as an integer.
proc window_dr {cmd} {
    set out [scan_dr_hw_jtag $::W_BITS -tdi [hexof $cmd $::W_BITS]]
    return 0x$out
}

# The command word, built from its fields.
proc window_word {write addr data go arm} {
    # `W_HELD` rides on every command, because the machine's reset is a LEVEL
    # and a command word that left it out would let the machine go every time
    # the debugger asked for a word.
    return [expr {($data & 0xFFFFFFFF)
                  | (($addr & 0xFFFFFFFF) << 32)
                  | (($write ? 1 : 0) << 64)
                  | (($go ? 1 : 0) << 65)
                  | (($arm ? 1 : 0) << 66)
                  | (($::W_HELD ? 1 : 0) << 67)}]
}

# `go` is a level this script carries, because the fabric runs a command on a
# CHANGE of it.
set ::W_GO   0
set ::W_ARM  0
set ::W_HELD 0

proc window_status {word} {
    return [dict create \
        rdata         [bits $word 0 32] \
        tally_lo      [bits $word 32 32] \
        tally_hi      [bits $word 64 32] \
        busy          [bits $word 96 1] \
        has_run       [bits $word 97 1] \
        error         [bits $word 98 1] \
        calib         [bits $word 99 1] \
        prove_has_run [bits $word 100 1] \
        prove_matched [bits $word 101 1] \
        go            [bits $word 102 1] \
        held          [bits $word 103 1] \
        ident         [bits $word 128 32]]
}

# Ask for one transaction and collect its answer.  Two scans, as the header
# says, and the second carries the same command so that it cannot start a
# second transaction.
proc window_go {write addr data} {
    set ::W_GO [expr {!$::W_GO}]
    set cmd [window_word $write $addr $data $::W_GO $::W_ARM]
    window_dr $cmd
    set st [window_status [window_dr $cmd]]
    if {[dict get $st ident] != $::W_IDENT} {
        window_fail \
            "MEM: FAILED --- the window's IDENT reads" \
            "MEM: [format 0x%08x [dict get $st ident]] and not" \
            "MEM: [format 0x%08x $::W_IDENT], which is \"MEMW\"." \
            "MEM: All zeros or all ones is a chain that is not selected or a" \
            "MEM: part that is not configured; anything else printable is a" \
            "MEM: different register at the other end of this scan."
    }
    if {[dict get $st busy]} {
        window_fail "MEM: FAILED --- the window is still busy one scan after" \
                    "MEM: its command. A transaction takes microseconds and a" \
                    "MEM: scan takes milliseconds, so this is a port that is" \
                    "MEM: not answering: the controller has not trained, or" \
                    "MEM: the machine is holding the port for ever."
    }
    return $st
}

proc window_write {addr data} { return [window_go 1 $addr $data] }

# ONE SCAN A TRANSACTION, WHICH IS WHAT MAKES POISONING A THOUSAND WORDS
# BEARABLE.  A data register scan captures before it updates, so the word this
# returns is the PREVIOUS transaction's answer and the command it carries is
# the next one: a run of writes is a run of single scans, and a run of reads is
# the same with the answers one behind.  At two scans each a page of memory is
# twice as many milliseconds as it needs to be.
proc window_issue {write addr data} {
    set ::W_GO [expr {!$::W_GO}]
    return [window_status \
                [window_dr [window_word $write $addr $data $::W_GO $::W_ARM]]]
}

# ...and the last answer, with no new transaction: the same `go`, so the scan
# is the poll this interface is built to allow.
proc window_settle {} {
    return [window_status \
                [window_dr [window_word 0 0 0 $::W_GO $::W_ARM]]]
}
proc window_read  {addr}      { return [window_go 0 $addr 0] }

# HOLD THE MACHINE STILL, or let it go.  A LEVEL, and it resets the MACHINE and
# not the memory controller --- so what is in DDR survives it, which is the
# whole reason the debugger has it.  Without it the machine reaches its first
# main-memory cycle 118 ms after reset, and poisoning a neighbourhood through
# this register takes seconds, so the poison would always arrive after the
# machine had read.
proc window_hold {held} {
    set ::W_HELD [expr {$held ? 1 : 0}]
    window_dr [window_word 0 0 0 $::W_GO $::W_ARM]
}

# The witness's release, on a proving board: a pulse on the rise of this bit.
proc window_arm {} {
    set ::W_ARM 1
    window_dr [window_word 0 0 0 $::W_GO 1]
    set ::W_ARM 0
    window_dr [window_word 0 0 0 $::W_GO 0]
}

# What the port did, out of the tally --- which is the one witness on this
# board that is not on the path the words above travel.
proc window_tally {st} {
    set lo [dict get $st tally_lo]
    set hi [dict get $st tally_hi]
    if {($lo & 0x80008000) != 0x00008000 ||
        ($hi & 0x80008000) != 0x00008000} {
        window_fail \
            "MEM: FAILED --- the tally reads [format 0x%08x $hi]" \
            "MEM: [format 0x%08x $lo], whose marker bits are wrong. Bit 15 of" \
            "MEM: each half is set and bit 31 clear by construction, so a" \
            "MEM: reading of all ones or all zeros --- no instrument --- can" \
            "MEM: never be mistaken for a count. This is no instrument."
    }
    return [dict create \
        answered_reads  [expr {$lo & 0x7FFF}] \
        answered_writes [expr {($lo >> 16) & 0x7FFF}] \
        asked_reads     [expr {$hi & 0x7FFF}] \
        asked_writes    [expr {($hi >> 16) & 0x7FFF}]]
}
