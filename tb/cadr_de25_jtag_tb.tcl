# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's two JTAG scripts, `boards/de25-nano/quartus/probe.tcl` and
# `usercode.tcl`, run against `tb/cadr_de25_jtag_model.tcl`.  No board, no
# Quartus: `tclsh tb/cadr_de25_jtag_tb.tcl`.
#
#     make build/de25_jtag.pass
#
# WHAT THIS HOLDS THE SCRIPTS TO.  Not the exit status alone.  Each case names
# the LINES the script must print, because a board that is refused at the
# check that names it and one that limps on and is refused later both exit 1,
# and only the first says what is wrong.  That is the Zynq reader's rule, in
# `tb/cadr_probe_jtag_tb.tcl`, one board along.
#
# AND THE CAPTURE THE `good` CASE WRITES IS MEASURED, NOT READ BACK AGAINST A
# COPY OF THE LAYOUT.  The model's buffer holds one-hot data, bit j of the
# payload in cycle j, so each exported row must light exactly one field at
# one bit, and walking the rows must tile the 421 bits in header order with
# no gap and no overlap.  The layout itself is compared with the Zynq
# reader's, which is the list that has read silicon: two readers of one
# register that disagree are one reader wrong.
#
# WHAT THE MODEL DOES NOT MODEL is in its own header: this is the commands'
# surface, and the node, the probe and the hub are `tb/cadr_probe_tb.cpp`'s.
#
# In `tb/` for the reason every harness is: the board flows glob `rtl/`.

set here [file dirname [file normalize [info script]]]
set repo [file normalize [file join $here ..]]
source [file join $here cadr_de25_jtag_model.tcl]

# The scripts under test, overridable so that the mutation runner can point
# at a copy, and resolved from this file rather than the working directory.
set quartus_dir [expr {[info exists ::env(DE25_QUARTUS_DIR)] ? $::env(DE25_QUARTUS_DIR)
                                                           : [file join $repo boards de25-nano quartus]}]
set arty_probe [file join $repo boards arty-z7-20 vivado probe.tcl]

# The two cables a hub might carry, and their USB devices' serials.
set CABLE1 "DE25-Nano \[9-1-iface0\]"
set CABLE2 "DE25-Nano \[9-2-iface0\]"
set PART   "@1: A5E(A013BB23B|B013BB23BCS)/.. (0x4362C0DD)"
set BUILD  541a5a83

# Depth for the `good` case: a power of two above 421, so that every payload
# bit gets a cycle of its own and the rest of the buffer is data of zero.
set GOOD_DEPTH 512
set START_AT   5

proc one_hot {j} {
    if {$j < 421} { set d [expr {1 << $j}] } else { set d 0 }
    return [expr {(1 << 453) | ($j << 421) | $d}]
}
proc never_ran {j} { return 0 }

# ------------------------------------------------------------------ the cases
#
# {case script exit {lines}}.  `script` is `probe` or `usercode`.
set CASES {
    {good probe 0
        {"PROBE: selecting the cable with serial TEST0001, from DE25_SERIAL in the environment"
         "PROBE: selected DE25-Nano [9-1-iface0]"
         "PROBE: the part is @1: A5E(A013BB23B|B013BB23BCS)/.. (0x4362C0DD)"
         "PROBE: IDCODE 4362c0dd, read by a raw scan, is the part's"
         "PROBE: USERCODE 541a5a83"
         "PROBE: the part holds build 541a5a83, the bitstream's"
         "PROBE: bypass: a53c shifted in, 4a78 back, wanting 4a78"
         "PROBE: the node took instruction 0 and then 1: the sample register is selected"
         "PROBE: the first sample reads valid, at cycle 5"
         "PROBE: the read pointer stood 507 samples into the buffer; rotated"
         "PROBE: wrote"}}
    {serial-picks-second probe 0
        {"PROBE: selecting the cable with serial TEST0002, from DE25_SERIAL in the environment"
         "PROBE: selected DE25-Nano [9-2-iface0]"
         "PROBE: wrote"}}
    {serial-ambiguous probe 1
        {"PROBE: FAILED --- 2 cables are attached and nothing says which of"
         "PROBE:     DE25-Nano [9-1-iface0], serial TEST0001"
         "PROBE:     DE25-Nano [9-2-iface0], serial TEST0002"}}
    {serial-one-cable-proceeds probe 0
        {"PROBE: no cable serial was given and one cable is attached, so it is that one: DE25-Nano [9-1-iface0], serial TEST0001"
         "PROBE: wrote"}}
    {serial-no-match probe 1
        {"PROBE: FAILED --- 0 cables carry serial NOPE0000."}}
    {processors-debug-port probe 0
        {"PROBE: the processor's debug port is on the chain: @2: ARM_CORESIGHT_SOC_600 (0x4BA06477)"
         "PROBE: the part is @1: A5E(A013BB23B|B013BB23BCS)/.. (0x4362C0DD)"
         "PROBE: wrote"}}
    {two-strangers probe 1
        {"PROBE: FAILED --- the chain on DE25-Nano [9-1-iface0] holds a part that is neither this board's"}}
    {two-of-ours probe 1
        {"PROBE: FAILED --- the chain on DE25-Nano [9-1-iface0] holds 2 parts with this board's"}}
    {stranger probe 1
        {"PROBE: FAILED --- the chain on DE25-Nano [9-1-iface0] holds a part that is neither this board's"
         "PROBE:   port: @1: SOMETHING (0x12345679)"}}
    {reversed probe 1
        {"PROBE: FAILED --- IDCODE read by a raw scan is bb0346c2, and the part's is"}}
    {no-tap probe 1
        {"PROBE: FAILED --- the instruction register captured `0` when IDCODE was"}}
    {other-build probe 1
        {"PROBE: USERCODE 03cad793"
         "PROBE: FAILED --- the part holds build 03cad793 and this bitstream is build 541a5a83."}}
    {no-node probe 1
        {"PROBE: the part holds build 541a5a83, the bitstream's"
         "PROBE: FAILED --- the virtual IR scan of node 0 was refused: ERROR: The specified virtual JTAG instance cannot be found."
         "PROBE:   the plain build: it carries the same stamp. Load the probe's first:"}}
    {no-bypass probe 1
        {"PROBE: bypass: a53c shifted in, a53c back, wanting 4a78"
         "PROBE: FAILED --- a bypass scan returned a53c where one bit of delay behind a"}}
    {stuck-node probe 1
        {"PROBE: FAILED --- the node held instruction 1 after 0 was shifted in."}}
    {never-ran probe 1
        {"PROBE: the node took instruction 0 and then 1: the sample register is selected"
         "PROBE: FAILED --- the node and its bypass are as they should be, and the first"}}
    {no-probe-build probe 1
        {"PROBE: FAILED --- "
         "gives the probe no depth that is a power of two (0);"}}

    {usercode-read usercode 0
        {"de25-program: selected DE25-Nano [9-1-iface0]"
         "de25-program: IDCODE 4362c0dd, read by a raw scan, is the part's"
         "de25-program: USERCODE 541a5a83"}}
    {usercode-took usercode 0
        {"de25-program: the part holds build 541a5a83 and held 03cad793 before, so the download took."}}
    {usercode-held-before usercode 0
        {"de25-program: the part holds build 541a5a83, and held it before this run too, so this"}}
    {usercode-unread-before usercode 0
        {"de25-program: the part holds build 541a5a83; what it held before could not be read, so"}}
    {usercode-other usercode 1
        {"de25-program: FAILED --- the part holds build 03cad793 and the bitstream is build 541a5a83."}}
    {usercode-reversed usercode 1
        {"de25-program: FAILED --- IDCODE read by a raw scan is bb0346c2, and the part's is"}}
}

# The arguments `usercode.tcl` gets in each of its cases: the bitstream's
# USERCODE as the assembler report writes it, and the reading before.
set UC_ARGS {
    usercode-read         {}
    usercode-took         {0x541A5A83 03cad793}
    usercode-held-before  {0x541A5A83 541a5a83}
    usercode-unread-before {0x541A5A83 {}}
    usercode-other        {0x541A5A83 541a5a83}
    usercode-reversed     {0x541A5A83 541a5a83}
}

# ----------------------------------------------------------- one case, a child
#
# Each case runs in a process of its own, because both scripts end in `exit`.
proc write_file {path text} {
    file mkdir [file dirname $path]
    set fh [open $path w]
    puts -nonewline $fh $text
    close $fh
}

proc setup_case {case dir} {
    global CABLE1 CABLE2 PART BUILD GOOD_DEPTH START_AT
    set ::m(hardware) [list $CABLE1]
    set ::m(devices)  [dict create $CABLE1 [list $PART] $CABLE2 [list $PART]]
    set ::m(depth) 8
    set serial TEST0001
    set usb {9-1 TEST0001}
    set depth 8
    switch -exact -- $case {
        good {
            set ::m(depth) $GOOD_DEPTH
            set ::m(sample) one_hot
            set ::m(rd) $START_AT
            set depth $GOOD_DEPTH
        }
        serial-picks-second {
            set ::m(hardware) [list $CABLE1 $CABLE2]
            set usb {9-1 TEST0001 9-2 TEST0002}
            set serial TEST0002
        }
        serial-ambiguous {
            set ::m(hardware) [list $CABLE1 $CABLE2]
            set usb {9-1 TEST0001 9-2 TEST0002}
            set serial ""
        }
        serial-one-cable-proceeds { set serial "" }
        serial-no-match           { set serial NOPE0000 }
        processors-debug-port {
            set ::m(depth) $GOOD_DEPTH
            set ::m(sample) one_hot
            set ::m(rd) $START_AT
            set depth $GOOD_DEPTH
            dict set ::m(devices) $CABLE1 [list $PART "@2: ARM_CORESIGHT_SOC_600 (0x4BA06477)"]
        }
        two-strangers { dict set ::m(devices) $CABLE1 [list $PART "@2: OTHER (0x12345679)"] }
        two-of-ours   { dict set ::m(devices) $CABLE1 [list $PART "@2: A5E (0x4362C0DD)"] }
        stranger    { dict set ::m(devices) $CABLE1 [list "@1: SOMETHING (0x12345679)"] }
        reversed    - usercode-reversed { set ::m(reversed) 1 }
        no-tap      { set ::m(ircap) 0 }
        other-build - usercode-other { set ::m(usercode) 03CAD793 }
        no-node     { set ::m(nodes) 0 }
        no-bypass   { set ::m(bypass_raw) 1 }
        stuck-node  { set ::m(vir_stuck) 1 }
        never-ran   { set ::m(sample) never_ran }
        no-probe-build { set depth 0 }
    }
    # The USB devices, as sysfs shows them.
    foreach {dev ser} $usb {
        write_file [file join $dir usb $dev idVendor] "09fb\n"
        write_file [file join $dir usb $dev serial] "$ser\n"
    }
    # And a device of another vendor, whose serial must never be read as ours.
    write_file [file join $dir usb 9-3 idVendor] "0403\n"
    write_file [file join $dir usb 9-3 serial] "TEST0002\n"
    set ::env(DE25_USB_DEVICES) [file join $dir usb]
    # The build: the two reports the reader takes its facts from.
    write_file [file join $dir build output_files cadr_de25.asm.rpt] \
        "; JTAG usercode  ; 0x[string toupper $BUILD]                                                        ;\n"
    set bin ""
    for {set k 31} {$k >= 0} {incr k -1} { append bin [expr {($depth >> $k) & 1}] }
    if {$depth > 0} {
        write_file [file join $dir build output_files cadr_de25.syn.rpt] \
            "; PROBE_DEPTH    ; $bin                                ; Unsigned Binary ;\n"
    } else {
        write_file [file join $dir build output_files cadr_de25.syn.rpt] "; nothing here\n"
    }
    set ::env(DE25_BUILD) [file join $dir build]
    set ::env(CSV) [file join $dir capture.csv]
    set ::env(BOARD_DIR) [file join $dir no-such-board]
    catch {unset ::env(DE25_SERIAL)}
    if {$serial ne ""} { set ::env(DE25_SERIAL) $serial }
}

if {[lindex $argv 0] eq "--case"} {
    lassign [lrange $argv 1 end] case script dir
    setup_case $case $dir
    if {$script eq "usercode"} {
        set ::quartus(args) [dict get $UC_ARGS $case]
    }
    source [file join $quartus_dir $script.tcl]
    exit 0
}

# ------------------------------------------------------ what `good` exported
proc hexval {s} {
    set v 0x$s
    return [expr {$v}]
}

proc check_capture {path depth} {
    if {![file exists $path]} { return "wrote no capture at $path" }
    set fh [open $path r]
    set lines {}
    foreach l [split [read $fh] "\n"] { if {$l ne ""} { lappend lines $l } }
    close $fh
    set head [join [lrange $lines 0 5] "\n"]
    foreach want [list "Radix - HEX" "Buffer Sample Count: $depth" \
                       "Window Sample Count: $depth" "Trigger Position: 0"] {
        if {[string first $want $head] < 0} { return "no `$want` in the metadata" }
    }
    set hi [lsearch -glob $lines "Sample in Buffer,*"]
    if {$hi < 0} { return "no header row" }
    set header [split [lindex $lines $hi] ","]
    if {[lrange $header 0 2] ne {{Sample in Buffer} TRIGGER cycle}} {
        return "header begins [lrange $header 0 2]"
    }
    set fields [lrange $header 3 end]
    set nf [llength $fields]
    set rows [lrange $lines [expr {$hi + 1}] end]
    if {[llength $rows] != $depth} { return "[llength $rows] rows, wanting $depth" }
    set expect [expr {$nf - 1}]
    set lo 0
    for {set j 0} {$j < $depth} {incr j} {
        set cells [split [lindex $rows $j] ","]
        if {[llength $cells] != $nf + 3} { return "row $j has [llength $cells] cells" }
        if {[hexval [lindex $cells 0]] != $j} { return "row $j numbers itself [lindex $cells 0]" }
        if {[lindex $cells 1] != ($j == 0 ? 1 : 0)} { return "row $j has TRIGGER [lindex $cells 1]" }
        if {[hexval [lindex $cells 2]] != $j} {
            return "row $j carries cycle [lindex $cells 2]: the buffer was not rotated back to cycle zero"
        }
        set lit {}
        for {set c 0} {$c < $nf} {incr c} {
            set v [hexval [lindex $cells [expr {$c + 3}]]]
            if {$v != 0} { lappend lit $c $v }
        }
        if {$j >= 421} {
            if {[llength $lit]} { return "row $j is past the payload and lit [lindex $fields [lindex $lit 0]]" }
            continue
        }
        if {[llength $lit] != 2} { return "payload bit $j lit [expr {[llength $lit] / 2}] fields, wanting one" }
        lassign $lit c v
        if {($v & ($v - 1)) != 0} { return "payload bit $j gave [lindex $fields $c] = [format %llx $v]" }
        set at 0
        while {(1 << $at) != $v} { incr at }
        # Bit 0 is the bottom of the last field; each change of column steps
        # one to the left and restarts at bit 0.
        if {$c != $expect} {
            if {$c != $expect - 1 || $at != 0} {
                return "payload bit $j landed in [lindex $fields $c] at bit $at: the fields do not tile the payload in header order"
            }
            incr expect -1
            set lo $j
        }
        if {$at != $j - $lo} { return "payload bit $j landed at bit $at of [lindex $fields $c], wanting [expr {$j - $lo}]" }
    }
    if {$expect != 0} { return "the payload ran out inside [lindex $fields $expect]" }
    return ""
}

# The field table as a script writes it: the words of its `set fields {...}`.
proc field_table {path} {
    set fh [open $path]
    set text [read $fh]
    close $fh
    if {![regexp {\nset fields \{([^\}]*)\}} $text -> body]} { return "" }
    return [regexp -all -inline {\S+} $body]
}

# ------------------------------------------------------------------- the run
set outdir [expr {[info exists ::env(OUTDIR)] ? $::env(OUTDIR) : [file join [pwd] build de25_jtag]}]
file delete -force $outdir
file mkdir $outdir
set self [file normalize [info script]]
set bad 0
set broke {}
puts "boards/de25-nano/quartus/probe.tcl and usercode.tcl against tb/cadr_de25_jtag_model.tcl:"

set mine [field_table [file join $quartus_dir probe.tcl]]
set theirs [field_table $arty_probe]
if {$mine eq "" || $mine ne $theirs} {
    incr bad
    lappend broke layout
    puts "  layout     FAIL the DE25 reader's field table is `$mine`,"
    puts "             and the Zynq reader's is `$theirs`"
} else {
    puts "  layout     ok   the field table is the Zynq reader's, [expr {[llength $mine] / 2}] fields"
}

foreach spec $CASES {
    lassign $spec case script want_exit want_lines
    set dir [file join $outdir $case]
    file mkdir $dir
    set rc 0
    if {[catch {exec [info nameofexecutable] $self --case $case $script $dir 2>@1} out]} {
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
            if {[string first $want $out] < 0} { set why "never said: $want" ; break }
        }
    }
    if {$why eq "" && $case eq "good"} {
        set why [check_capture [file join $dir capture.csv] $GOOD_DEPTH]
    }
    if {$why eq ""} {
        puts [format "  %-26s ok   %s" $case [expr {$want_exit ? "refused where it should be" : "as it should"}]]
    } else {
        incr bad
        lappend broke $case
        puts [format "  %-26s FAIL %s" $case $why]
        foreach l [split [string trimright $out "\n"] "\n"] { puts "         | $l" }
    }
}

puts ""
if {$bad} {
    puts "FAIL: $bad of [expr {[llength $CASES] + 1}] cases: [join $broke {, }]"
    exit 1
}
puts "ok: [llength $CASES] cases and the layout; every refusal is made at the check that names it,"
puts "    and 421 one-hot payload bits tile 22 columns in header order with no gap or overlap"
exit 0
