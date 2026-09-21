#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The DE25-Nano's register faces sit where the programs look for them, every
one of them takes its bridge's reset and nothing else, and the debug cable's
twenty-one wires reach the ports they are meant to.

WHY THIS EXISTS.  The faces behind a processor-to-fabric bridge are placed by
parameters on the instances in `boards/de25-nano/cadr_de25.sv`, and that file
cannot be simulated: it instantiates a generated processor system, so lint and
the fitter are all that read it.  Lint holds that every port is connected and
has nothing whatever to say about a number.  A face placed one page out
therefore builds, fits and programs, and is found only when a program reads
`0x4000_1000` and gets the word the default slave answers with -- or, worse,
the word of the face next door, which looks like a working face with wrong
contents.

WHAT MAKES IT CHECKABLE IS THAT THE ADDRESS IS WRITTEN TWICE.  A program takes
its address from `cadr_board.h`, which names the PROCESSOR's address; the
fabric takes its from the instance, which is an OFFSET into the bridge's own
window, because these bridges hand the fabric an offset and not the
processor's address.  The two are the same fact seen from the two ends of the
bridge, so they can be required to agree:

    the face's parameter  ==  the program's address  -  the bridge's window

and the windows are the Agilex 5 HPS Technical Reference Manual's (document
814346, Table 322): the lightweight bridge's 512 MB at 0x2000_0000 and the
HPS-to-FPGA bridge's 1 GB at 0x4000_0000.  Those two numbers are this file's
own, from the manual, and everything else is read out of the tree.

AND THE SHAPE, which is the other thing a parameter decides here.  Both
bridges are AXI4: four bits of transaction ID where a Zynq general-purpose
port has twelve, and eight bits of burst length where AXI3 has four.  Every
face on them is built with those two widths, and a face left at the defaults
would answer a 256-beat read with sixteen beats and leave the processor
waiting for the rest -- which on a general-purpose port is not a wrong answer
but two frozen cores.  So each instance is required to carry both.

AND THE RESET, WHICH IS THE OTHER WAY A PAGE STOPS ANSWERING.  A slave that
owns a page of a bridge's window must answer it whenever the bridge is out of
reset.  A slave held in reset answers nothing, and on these bridges that is
worse than a stall: a face holds its read state machine in its address state
while it is reset, ARREADY is high in that state, so the address is taken and
no beat is ever returned.  The read never completes, both processor cores hang,
and no software guard can see it coming.

That is not hypothetical.  One face on the HPS-to-FPGA bridge was given a reset
that carried the memory port's liveness as well as the bridge's, in imitation
of a Zynq board, where the processing system drives both and they are never
apart.  Here the memory port is opened by software, seconds after the bridge
comes up, so the face sat in reset through every boot, and the first program to
read its registers hung the processor.  Lint cannot see this: a reset is a
legal connection whatever it is made of, and beside lint this file is the only
thing that reads the top level at all.

So two rules, both read out of the source:

    every slave instance on a bridge connects `.rst` to a BARE SIGNAL, and to
    the same signal its bridge's splitter takes; and

    no signal a bridge's slaves take as a reset is derived from the memory
    port's liveness -- the net the memory port drives at its `live` port,
    followed through this file's assignments as far as they go.

What the rules cannot see is what a signal is made of beyond that following: a
reset built out of something this file gives no name to would pass.
`build/gp0_split.pass` is the other half, and the half that demonstrates rather
than reads: it sweeps every page of the window with the memory port shut and
requires an answer at each address.

AND THE DEBUG CABLE'S SEAM, FOR THE SAME REASON AND AGAINST A DIFFERENT SHAPE
OF BUG.  The connector on JP1, the register window on the lightweight bridge,
the join between them and the machine's own two cable ends are five things
wired together in this file with nothing that simulates them.  Lint holds that
every port is connected and that nothing is left undriven or unread; what it
cannot see is a connection that is WRONG rather than missing.  Two shapes
matter here and both have happened in this repository:

    a LITERAL where a signal belongs.  The nine words the console reports
    about the connector were every one of them a constant while there was no
    connector, which was true then and is a lie now -- and lint cannot tell
    them apart, because the connector's own outputs have a second reader in
    the `witness` fold.  A console that reports `not engaged, no frames, no
    peer` whatever the cable is doing looks exactly like a board with nothing
    plugged in.

    a CROSSING between two signals of the same width.  The join's two arms are
    the window and the connector and they carry the same four things; MIT's
    twenty wires leave `cadr_machine` on one set of ports and arrive on
    another.  Crossed, every signal is still driven and still read, so no tool
    that reads this file has anything to say, and the fault is a debugger
    whose word lands in the other debugger's request.  `mutations/list.txt`
    already carries `the-join-crosses-the-two-debuggers-data-lines` for the
    join's own module; this is the same shape one level out.

So `WIRED` below names every port pair across that seam, and each pair must be
one BARE SIGNAL, the same one at both ends.  It is the twenty-one wires and
the console's nine words written down once, where before they were written
twice and compared by nobody.

AND WHICH HEADER PIN EACH OF THE CABLE'S EIGHT LINES IS ON, which is the one
place this board CHOOSES a pin rather than transcribing one.  The Zynq boards
carry MIT's cable on a Pmod header, whose twelve pins a ribbon maps to the far
board's twelve.  This board has no Pmod, so the connector is JP1 pins 31 to 38
and a cable to a Pmod is an adapter.  The map is written in three places that
no tool reading one of them can compare with the others: the top level names a
port a pad and drives it, the top level LISTENS on the same eight in a
concatenation, and `de25_nano_pins.tcl` gives each port a package pin.  So all
three are read here, with `rtl/plumbing/cadr_dbg_cable.sv` for which of the
eight lines each index carries, and four things are required.

    Index k of the carrier is JP1 pin 31 + k, DRIVING AND LISTENING ALIKE.  A
    board that drives one pin and reads another hears its own guard, and it is
    driven in one place and read in another, so nothing that reads one half
    can see it.

    THE CARRIER'S FOUR SIGNAL LINES ARE ON JP1's ODD PINS AND ITS FOUR GUARDS
    ON THE EVEN ONES, with the counts asserted.  This FOLLOWS from `31 + k`,
    and it is asked separately anyway: a rule that only ever fires when
    another rule has already fired is a rule nothing can reach, and that looks
    exactly like a rule that holds.  The reason is the Pmod's: a Pmod's own
    signal pins are 1, 3, 7 and 9 and its guards 2, 4, 8 and 10, so `31 + k`
    lands each signal on its counterpart at the far end of an adapter.  On
    this header it also means no two signals are adjacent in the ribbon, and
    JP1's own ground on pin 30 sits at the end of the run.

    Every pad has a line in the pin file, so the fitter places it rather than
    choosing a pin of its own.

    AND NOTHING ELSE OF EITHER HEADER IS A PORT AT ALL.  JP1 carries 5 V on
    pin 11 and 3.3 V on pin 29, and `docs/debug-cable.md`'s rule is that a
    cable leaves the supply pins open: two boards' regulators tied together is
    not something either of them is built for.  Neither is a fabric pin, so
    the fabric's half of that rule is kept by naming neither, and the cable's
    half is the person making it.  The other 64 signal pins of the two headers
    are ones this design has no opinion about, and a port nothing drives is a
    pin the fitter places and a wire a ribbon carries.

The roles are read out of `cadr_dbg_cable.sv`'s own localparams rather than
written here, so the module renaming a line moves this with it.

AND THE CONNECTOR'S RESET IS THE FABRIC'S AND NOT THE MACHINE'S, which is the
one rule here that is neither a literal nor a crossing.  Modifier bit 1 of the
cable resets this machine, so a connector or a join reset by `mach_rst` would
forget the request that asked for it -- and MIT's own sequence for that bit,
"write a 1 here then write a 0", could not be written at all.  The DBGIN page
inside the machine takes the fabric's reset for exactly this reason, at
`.dbg_rst`, so the rule is that the connector and the join take the same
signal that port does, and that it is not the machine's.

It writes its stamp and prints what it found.  Run as

    python3 tools/de25_faces_check.py . --stamp build/de25_faces.pass
"""

import argparse
import os
import re
import sys
from pathlib import Path

# The pin file's own grammar, from the check that owns it, so that there is
# one place where a `de25_pin` line is parsed.  `tools/` is this file's own
# directory and is where the interpreter starts looking.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import de25_pins_check  # noqa: E402

# The two windows, from the manual.  Written here because they are facts about
# the part and not about this design, and everything else is read from the
# tree.
H2F_BASE = 0x40000000
H2F_SIZE = 1024 * 1024 * 1024
LW_BASE = 0x20000000
LW_SIZE = 512 * 1024 * 1024

TOP = "boards/de25-nano/cadr_de25.sv"
BOARD_H = ("boards/arty-z7-20/linux/buildroot/package/cadr-common/src/cadr/"
           "cadr_board.h")

# Each face: the instance in the top level, the parameter that places it, the
# bridge it is on, and the name `cadr_board.h` gives the program's address.
# The debug cable's window has no program address of its own -- muir is given
# it on its command line -- so it is held one page above the console, which is
# what the header and `cadr_gp1_split.sv` both say.
FACES = [
    ("u_h2f_split", "PACK_BASE", "h2f", "PACK"),
    ("u_h2f_split", "CHAOS_BASE", "h2f", "CHAOS"),
    ("u_h2f_split", "SER_BASE", "h2f", "SERIAL"),
    ("u_h2f_split", "INPUT_BASE", "h2f", "INPUT"),
    ("u_pack", "REG_BASE", "h2f", "PACK"),
    ("u_lw_split", "CON_BASE", "lw", "CONSOLE"),
    ("u_lw_split", "DBG_BASE", "lw", "CONSOLE+0x1000"),
    ("u_console", "REG_BASE", "lw", "CONSOLE"),
    ("u_debug_window", "REG_BASE", "lw", "CONSOLE+0x1000"),
]

# Every instance on either bridge takes the bridges' AXI4 widths.
SHAPED = ["u_h2f_split", "u_pack", "u_chaos", "u_serial", "u_input",
          "u_h2f_rest", "u_lw_split", "u_console", "u_debug_window",
          "u_lw_rest"]

# Which bridge each of them is on, and which instance is that bridge's
# splitter -- the one whose reset the rest are held to.  The splitter is on
# the list too: it owns the window before anything behind it does.
ON_BRIDGE = {"u_h2f_split": "h2f", "u_pack": "h2f", "u_chaos": "h2f",
             "u_serial": "h2f", "u_input": "h2f", "u_h2f_rest": "h2f",
             "u_lw_split": "lw", "u_console": "lw", "u_debug_window": "lw",
             "u_lw_rest": "lw"}
SPLITTER = {"h2f": "u_h2f_split", "lw": "u_lw_split"}

WINDOWS = {"h2f": (H2F_BASE, H2F_SIZE), "lw": (LW_BASE, LW_SIZE)}

# THE DEBUG CABLE'S SEAM, port pair by port pair.  Each row is one net that
# must be named the same way at both ends, and each must be a bare signal
# rather than a literal or an expression.  The header says what the two
# failures are that this is against.
#
# The order is the cable's: the console's nine words about the connector, then
# this machine as the DEBUGGER through its DBGOUT page, then a second board's
# debugger arriving on the connector, then the register window's arm of the
# same page, then the join's one cable into `rtl/machine/cadr_dbgin.sv`.
WIRED = [
    ("u_dbg_cable", "connect", "u_console", "dbg_connect",
     "the role the console asks for"),
    ("u_dbg_cable", "wiring", "u_console", "dbg_wiring",
     "which way round the ribbon was made"),
    ("u_dbg_cable", "engaged", "u_console", "dbg_engaged",
     "whether this board took the role"),
    ("u_dbg_cable", "foreign", "u_console", "dbg_foreign",
     "a debugger already on the connector"),
    ("u_dbg_cable", "peer_far", "u_console", "dbg_peer_far",
     "and on the pins this board answers on"),
    ("u_dbg_cable", "live", "u_console", "dbg_live", "good frames arriving"),
    ("u_dbg_cable", "active", "u_console", "dbg_active",
     "something driving a group"),
    ("u_dbg_cable", "wire_state", "u_console", "dbg_wire_state",
     "what came of the wiring"),
    ("u_dbg_cable", "frames", "u_console", "dbg_frames",
     "frames heard and frames refused"),
    ("u_dbg_cable", "out_req", "u_machine", "dbgout_req", "-DEBUG OUT REQ"),
    ("u_dbg_cable", "out_wr", "u_machine", "dbgout_wr", "DEBUG OUT WR"),
    ("u_dbg_cable", "out_a", "u_machine", "dbgout_a", "DEBUG OUT A<1:0>"),
    ("u_dbg_cable", "out_dbd", "u_machine", "dbgout_dbd",
     "DBD<15:0> going out"),
    ("u_dbg_cable", "out_ack", "u_machine", "dbgout_ack", "DEBUG OUT ACK"),
    ("u_dbg_cable", "out_dbd_in", "u_machine", "dbgout_dbd_in",
     "DBD<15:0> coming back"),
    ("u_dbg_cable", "out_live", "u_machine", "dbgout_live",
     "a board at the far end"),
    ("u_dbg_cable", "in_ack", "u_machine", "dbg_in_ack", "DEBUG IN ACK"),
    ("u_dbg_cable", "in_dbd_out", "u_machine", "dbd_out",
     "DBD<15:0> this machine drives"),
    ("u_dbg_cable", "in_dbd_oe", "u_machine", "dbd_oe",
     "and which bytes of it it drives"),
    ("u_dbg_cable", "in_req", "u_dbg_join", "b_req",
     "-DEBUG IN REQ off the connector"),
    ("u_dbg_cable", "in_wr", "u_dbg_join", "b_wr",
     "DEBUG IN WR off the connector"),
    ("u_dbg_cable", "in_a", "u_dbg_join", "b_a",
     "DEBUG IN A<1:0> off the connector"),
    ("u_dbg_cable", "in_dbd", "u_dbg_join", "b_dbd",
     "DBD<15:0> off the connector"),
    ("u_debug_window", "dbg_in_req", "u_dbg_join", "a_req",
     "-DEBUG IN REQ out of the window"),
    ("u_debug_window", "dbg_in_wr", "u_dbg_join", "a_wr",
     "DEBUG IN WR out of the window"),
    ("u_debug_window", "dbg_in_a", "u_dbg_join", "a_a",
     "DEBUG IN A<1:0> out of the window"),
    ("u_debug_window", "dbd_out", "u_dbg_join", "a_dbd",
     "DBD<15:0> out of the window"),
    ("u_dbg_join", "req", "u_machine", "dbg_in_req",
     "-DEBUG IN REQ at the DBGIN page"),
    ("u_dbg_join", "wr", "u_machine", "dbg_in_wr",
     "DEBUG IN WR at the DBGIN page"),
    ("u_dbg_join", "a", "u_machine", "dbg_in_a",
     "DEBUG IN A<1:0> at the DBGIN page"),
    ("u_dbg_join", "dbd", "u_machine", "dbd_in",
     "DBD<15:0> at the DBGIN page"),
]

# And the reset: the connector and the join take the signal the DBGIN page
# takes, which is the fabric's, and never the machine's.
CABLE_RESET = ["u_dbg_cable", "u_dbg_join"]

# THE CONNECTOR'S PINS.  `rtl/plumbing/cadr_dbg_cable.sv` is where the eight
# indices' roles are and `de25_nano_pins.tcl` is where a package pin is; the
# three numbers below are this project's decision about WHERE the connector
# sits and are the only part of the map written here rather than read.
CABLE = "rtl/plumbing/cadr_dbg_cable.sv"
PINS = "boards/de25-nano/de25_nano_pins.tcl"
DBG_HEADER = 1
DBG_FIRST_PIN = 31
DBG_GROUND_PIN = 30


def fail(msg):
    print("de25_faces: " + msg, file=sys.stderr)
    sys.exit(1)


def instance_parameters(text, instance):
    """The parameter overrides on one instance, as {name: int}.

    The instance is `<module> #( ... ) <instance> (`, and what is wanted is
    the parameter list between them.  A module with no overrides at all is an
    instance with no `#(`, which this reports as an empty map rather than as
    an error: the caller says which parameters it wanted.
    """
    m = re.search(r"\b(\w+)\s*#\(([^;]*?)\)\s*" + re.escape(instance) + r"\s*\(",
                  text, re.S)
    if not m:
        if re.search(r"\b(\w+)\s+" + re.escape(instance) + r"\s*\(", text):
            return {}
        fail("no instance named `%s` in %s" % (instance, TOP))
    out = {}
    for name, value in re.findall(r"\.(\w+)\s*\(\s*([^()]*?)\s*\)", m.group(2)):
        v = value.replace("_", "").strip()
        n = re.match(r"^(?:\d+)'h([0-9a-fA-F]+)$", v)
        if n:
            out[name] = int(n.group(1), 16)
            continue
        n = re.match(r"^(?:(?:\d+)'d)?(\d+)$", v)
        if n:
            out[name] = int(n.group(1))
    return out


def instance_connections(text, instance):
    """The port connections on one instance, as {port: expression}.

    The instance's connection list is what follows `<instance> (`, up to the
    parenthesis that closes it, so this counts parentheses rather than looking
    for the first `)`: an expression on a port has parentheses of its own.
    """
    m = re.search(r"\b" + re.escape(instance) + r"\s*\(", text)
    if not m:
        fail("no instance named `%s` in %s" % (instance, TOP))
    depth, i = 1, m.end()
    while i < len(text) and depth:
        if text[i] == "(":
            depth += 1
        elif text[i] == ")":
            depth -= 1
        i += 1
    body = text[m.end():i - 1]
    out = {}
    for port, expr in re.findall(r"\.(\w+)\s*\(([^()]*(?:\([^()]*\)[^()]*)*)\)",
                                 body):
        out[port] = expr.strip()
    return out


def liveness_net(text):
    """The net the MEMORY PORT drives to say it is live.

    Read off the instance rather than written down here, so that renaming the
    net cannot quietly empty the rule below.  A board built without the memory
    port has no such instance, and then there is nothing to taint.

    **THE INSTANCE IS NAMED AND THE PORT IS NOT SEARCHED FOR ON ITS OWN.**
    This looked for the first `.live(...)` in the file and was right for as
    long as the memory port was the only thing that had one; the debug cable's
    connector has a `.live` too --- good frames arriving --- and it is earlier
    in the file, so the search silently moved the whole reset rule onto a net
    no bridge's reset could ever be made of.  A rule that reaches nothing
    looks exactly like a rule that holds.
    """
    m = re.search(r"\bcadr_f2sdram_port\b[^;]*?\b(\w+)\s*\(", text)
    if not m:
        return None
    return instance_connections(text, m.group(1)).get("live")


def derived_from(text, seed):
    """Every signal in the file that is assigned from `seed`, transitively.

    A line at a time, and only the plain forms this file is written in:
    `assign x = ...;` and `x <= ...;`.  It is a closure over names, so a
    reset made two signals away from the memory port's liveness is still
    caught.  What it cannot follow is a name this file does not assign.
    """
    tainted = {seed}
    changed = True
    while changed:
        changed = False
        for lhs, rhs in re.findall(r"(?:assign\s+)?(\w+)\s*(?:<=|=)\s*([^;]*);",
                                   text):
            if lhs in tainted:
                continue
            words = set(re.findall(r"\b(\w+)\b", rhs))
            if words & tainted:
                tainted.add(lhs)
                changed = True
    return tainted


def cable_roles(text):
    """The carrier's eight pad indices and what each one carries, or None.

    Read off `cadr_dbg_cable.sv`'s own localparams, `FWD_STB`, `FWD_GD0` and
    the rest, so that this moves with the module rather than holding a copy of
    its table.  A name with `_GD` in it is a guard and every other is a
    signal, which is the module's own naming and what its header's pin table
    prints.
    """
    roles = {}
    for label, index in re.findall(
            r"localparam\s+int\s+unsigned\s+((?:FWD|RET)_\w+)\s*=\s*(\d+)\s*;", text):
        roles[int(index)] = label
    if sorted(roles) != list(range(8)):
        fail("%s names pad indices %s, and the connector has eight, 0 to 7"
             % (CABLE, sorted(roles)))
    guards = [i for i, label in roles.items() if "_GD" in label]
    if len(guards) != 4:
        fail("%s names %d guards and each group of four carries two"
             % (CABLE, len(guards)))
    return roles


def connector_pads(text):
    """The top level's eight pads, read BOTH ways, as two {index: header pin}.

    A pad is written twice and the two must agree: once in the continuous
    assignment that DRIVES it, which is also where the pad's tri-state sense
    is, and once in the concatenation the connector LISTENS on.
    """
    nets = {}
    for port in ("pin_o", "pin_t", "pin_i"):
        m = re.search(r"\.%s\s*\(\s*(\w+)\s*\)" % port, text)
        if not m:
            fail("no instance in %s connects the connector's `%s`" % (TOP, port))
        nets[port] = m.group(1)

    drive, bad = {}, 0
    for pin, tnet, tindex, onet, oindex in re.findall(
            r"assign\s+jp(?:1|2)_pin(\d+)\s*=\s*"
            r"(\w+)\[(\d+)\]\s*\?\s*1'bz\s*:\s*(\w+)\[(\d+)\]\s*;", text):
        if tnet != nets["pin_t"] or onet != nets["pin_o"]:
            print("de25_faces: the pad at JP pin %s is driven from `%s`/`%s` "
                  "and the connector hands out `%s`/`%s`"
                  % (pin, tnet, onet, nets["pin_t"], nets["pin_o"]),
                  file=sys.stderr)
            bad += 1
            continue
        if tindex != oindex:
            print("de25_faces: the pad at JP pin %s takes `%s[%s]` for its "
                  "enable and `%s[%s]` for its level: one index drives one pad "
                  "or it is two pads" % (pin, tnet, tindex, onet, oindex),
                  file=sys.stderr)
            bad += 1
            continue
        drive[int(tindex)] = int(pin)

    listen = {}
    m = re.search(r"assign\s+" + re.escape(nets["pin_i"]) + r"\s*=\s*\{([^}]*)\}\s*;",
                  text)
    if not m:
        print("de25_faces: nothing assigns `%s`, which is what the connector "
              "listens on" % nets["pin_i"], file=sys.stderr)
        bad += 1
    else:
        members = [w.strip() for w in m.group(1).split(",") if w.strip()]
        for offset, member in enumerate(members):
            mm = re.fullmatch(r"jp(?:1|2)_pin(\d+)", member)
            if not mm:
                print("de25_faces: `%s` takes `%s`, which is not one of the "
                      "header's pads" % (nets["pin_i"], member), file=sys.stderr)
                bad += 1
                continue
            # A concatenation is written most significant first.
            listen[len(members) - 1 - offset] = int(mm.group(1))
    return drive, listen, bad


def check_connector(root, top):
    """The debug cable's eight pads, and nothing else of either header."""
    bad = 0
    cable_path = os.path.join(root, CABLE)
    if not os.path.exists(cable_path):
        fail("%s is not there" % cable_path)
    roles = cable_roles(open(cable_path).read())
    drive, listen, bad = connector_pads(top)

    if sorted(drive) != list(range(8)):
        print("de25_faces: the top level drives pad indices %s, and the "
              "connector hands out eight, 0 to 7: a pad driven unconditionally "
              "is two drivers on one wire the moment a second board is on the "
              "cable" % sorted(drive), file=sys.stderr)
        return bad + 1
    if drive != listen:
        crossed = sorted(k for k in drive if drive.get(k) != listen.get(k))
        print("de25_faces: the connector drives and listens on different pins "
              "at index%s %s: driving %s and listening on %s, so this board "
              "hears a pin it does not drive" %
              ("" if len(crossed) == 1 else "es", crossed,
               [drive.get(k) for k in crossed], [listen.get(k) for k in crossed]),
              file=sys.stderr)
        return bad + 1

    # The pin file, through the check that owns its grammar.  **ITS COMPLAINTS
    # ARE READ AND NOT LEFT IN ITS LIST**: `read_pins` reports a line that does
    # not parse by appending to a module-level list of its own, and a caller
    # that never looks at it would take a half-parsed file for a short one and
    # say only that some pad has no package pin.
    pins_path = Path(root) / PINS
    if not pins_path.is_file():
        fail("%s is not there" % pins_path)
    before = len(de25_pins_check.failures)
    pins, _supply = de25_pins_check.read_pins(pins_path)
    for message in de25_pins_check.failures[before:]:
        print("de25_faces: %s does not parse: %s" % (PINS, message),
              file=sys.stderr)
        bad += 1
    by_port = {p["port"]: p for p in pins}

    # THE TWO RULES ARE ASKED SEPARATELY, and neither stands in for the other.
    # The order rule implies the odd and even rule, so asking the order first
    # and stopping there would leave the guarding with no mutation that could
    # reach it.
    signals = guards = 0
    for index in range(8):
        pin = drive[index]
        port = "jp%d_pin%d" % (DBG_HEADER, pin)
        if port not in by_port:
            print("de25_faces: %s is a pad of the connector and %s gives it no "
                  "package pin, so the fitter would choose one" % (port, PINS),
                  file=sys.stderr)
            bad += 1
        guard = "_GD" in roles.get(index, "")
        if guard and pin % 2 != 0:
            print("de25_faces: index %d is %s, a guard, and JP%d pin %d is an "
                  "odd pin, which is a signal's" %
                  (index, roles[index], DBG_HEADER, pin), file=sys.stderr)
            bad += 1
        elif not guard and pin % 2 == 0:
            print("de25_faces: index %d is %s, a signal, and JP%d pin %d is an "
                  "even pin, which is a guard's" %
                  (index, roles[index], DBG_HEADER, pin), file=sys.stderr)
            bad += 1
        else:
            guards += guard
            signals += not guard
        want = DBG_FIRST_PIN + index
        if pin != want:
            print("de25_faces: the carrier's index %d is on JP%d pin %d, and "
                  "the connector is JP%d pins %d to %d in order, so index %d "
                  "is pin %d" % (index, DBG_HEADER, pin, DBG_HEADER,
                                 DBG_FIRST_PIN, DBG_FIRST_PIN + 7, index, want),
                  file=sys.stderr)
            bad += 1
    if signals != 4 or guards != 4:
        print("de25_faces: the connector puts %d signals and %d guards on JP%d's "
              "odd and even pins, and a group of four carries two of each" %
              (signals, guards, DBG_HEADER), file=sys.stderr)
        bad += 1

    named = {(int(h), int(p)) for h, p in re.findall(r"\bjp([12])_pin(\d+)\b", top)}
    extra = sorted(named - {(DBG_HEADER, DBG_FIRST_PIN + k) for k in range(8)})
    if extra:
        print("de25_faces: the top level names %s besides the connector's "
              "eight, and every other pin of both headers is one this design "
              "has no opinion about --- the supplies on 11 and 29 most of all, "
              "which a cable must leave open at both ends" %
              ", ".join("JP%d pin %d" % e for e in extra), file=sys.stderr)
        bad += 1

    if bad == 0:
        print("de25_faces: the debug cable is JP%d pins %d to %d, driven and "
              "listened on alike: %s, with ground on pin %d and the supplies "
              "on 11 and 29 named by nothing" %
              (DBG_HEADER, DBG_FIRST_PIN, DBG_FIRST_PIN + 7,
               ", ".join("%d %s %s" % (drive[k], roles[k],
                                       "guard" if "_GD" in roles[k] else "signal")
                         for k in range(8)),
               DBG_GROUND_PIN))
    return bad


def board_addresses(text):
    """The DE25-Nano's addresses out of `cadr_board.h`.

    The file holds one block per board, and the DE25-Nano's is the one under
    `#if defined(CADR_BOARD_DE25_NANO)`.  Taking the whole file would read the
    Zynq's numbers as well, and those are a different board's.
    """
    start = text.index("#if defined(CADR_BOARD_DE25_NANO)")
    end = text.index("#else", start)
    out = {}
    for name, hexdigits in re.findall(
            r"#define\s+CADR_BOARD_(\w+)_HEX\s+([0-9A-Fa-f]+)",
            text[start:end]):
        out[name] = int(hexdigits, 16)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("root", help="the repository's root")
    ap.add_argument("--stamp", help="write this file when the check passes")
    args = ap.parse_args()

    top_path = os.path.join(args.root, TOP)
    board_path = os.path.join(args.root, BOARD_H)
    for p in (top_path, board_path):
        if not os.path.exists(p):
            fail("%s is not there" % p)
    top = open(top_path).read()
    board = board_addresses(open(board_path).read())

    bad = 0
    print("de25_faces: the bridges' windows are 0x%08X for %d MB and "
          "0x%08X for %d MB" %
          (LW_BASE, LW_SIZE >> 20, H2F_BASE, H2F_SIZE >> 20))

    for instance, param, bridge, addr_name in FACES:
        params = instance_parameters(top, instance)
        if param not in params:
            fail("%s does not set `%s`, so its face is wherever the module's "
                 "own default puts it" % (instance, param))
        base, size = WINDOWS[bridge]
        key = addr_name
        plus = 0
        if "+" in addr_name:
            key, extra = addr_name.split("+")
            plus = int(extra, 16)
        if key not in board:
            fail("cadr_board.h names no CADR_BOARD_%s_HEX for this board" % key)
        want = board[key] + plus - base
        got = params[param]
        if got != want:
            print("de25_faces: %s.%s is 0x%08X, and the programs look at "
                  "0x%08X, which is 0x%08X into the bridge's window at "
                  "0x%08X" % (instance, param, got, board[key] + plus, want,
                              base), file=sys.stderr)
            bad += 1
            continue
        if got + 0x1000 > size:
            print("de25_faces: %s.%s is 0x%08X, which is outside the bridge's "
                  "%d MB window" % (instance, param, got, size >> 20),
                  file=sys.stderr)
            bad += 1
            continue
        print("de25_faces: %-15s %-11s 0x%08X   the programs' 0x%08X" %
              (instance, param, got, board[key] + plus))

    for instance in SHAPED:
        params = instance_parameters(top, instance)
        for name, want in (("ID_W", 4), ("LEN_W", 8)):
            if params.get(name) != want:
                print("de25_faces: %s does not set %s to %d, so it is built "
                      "at the Zynq's AXI3 shape on an AXI4 bridge" %
                      (instance, name, want), file=sys.stderr)
                bad += 1
    if bad == 0:
        print("de25_faces: all %d instances carry the bridges' four bits of "
              "ID and eight of burst length" % len(SHAPED))

    # THE RESET.  Every slave on a bridge takes a bare signal, the same one
    # its bridge's splitter takes, and that signal owes nothing to the memory
    # port's liveness.  See the header for what each rule is against.
    live = liveness_net(top)
    tainted = derived_from(top, live) if live else set()
    resets = {}
    for instance in SHAPED:
        conns = instance_connections(top, instance)
        if "rst" not in conns:
            print("de25_faces: %s connects no `rst`" % instance, file=sys.stderr)
            bad += 1
            continue
        resets[instance] = conns["rst"]
    for bridge, splitter in SPLITTER.items():
        want = resets.get(splitter)
        if want is None:
            continue
        if not re.match(r"^\w+$", want):
            print("de25_faces: the %s bridge's splitter takes `%s` as its "
                  "reset, which is an expression and not a signal" %
                  (bridge, want), file=sys.stderr)
            bad += 1
            continue
        for instance in SHAPED:
            if ON_BRIDGE[instance] != bridge or instance not in resets:
                continue
            got = resets[instance]
            if got != want:
                print("de25_faces: %s takes `%s` as its reset and the %s "
                      "bridge takes `%s`: a slave that owns a page of a "
                      "window must answer it whenever the bridge is out of "
                      "reset, and one held in reset takes the address and "
                      "returns no beat, which hangs both processor cores" %
                      (instance, got, bridge, want), file=sys.stderr)
                bad += 1
        if want in tainted:
            print("de25_faces: the %s bridge's slaves are reset by `%s`, "
                  "which is derived from `%s`, the memory port's liveness: "
                  "the window would stop answering for as long as the port "
                  "is shut, which is every boot until software opens it" %
                  (bridge, want, live), file=sys.stderr)
            bad += 1
    if bad == 0:
        for bridge, splitter in sorted(SPLITTER.items()):
            on = [i for i in SHAPED if ON_BRIDGE[i] == bridge]
            print("de25_faces: %-3s %d slaves, all reset by `%s` alone%s" %
                  (bridge, len(on), resets[splitter],
                   ", which owes nothing to `%s`" % live if live else ""))

    # THE DEBUG CABLE'S SEAM.  Every pair one bare signal, the same at both
    # ends, and the connector's reset the fabric's.  See the header.
    conns = {}
    for instance in sorted({row[0] for row in WIRED} | {row[2] for row in WIRED}
                           | set(CABLE_RESET)):
        conns[instance] = instance_connections(top, instance)
    for a_inst, a_port, b_inst, b_port, what in WIRED:
        a = conns[a_inst].get(a_port)
        b = conns[b_inst].get(b_port)
        for inst, port, expr in ((a_inst, a_port, a), (b_inst, b_port, b)):
            if expr is None:
                print("de25_faces: %s connects no `%s`, which is %s" %
                      (inst, port, what), file=sys.stderr)
                bad += 1
        if a is None or b is None:
            continue
        for inst, port, expr in ((a_inst, a_port, a), (b_inst, b_port, b)):
            if not re.fullmatch(r"\w+", expr):
                print("de25_faces: %s takes `%s` at `%s`, which is %s: a "
                      "literal or an expression there is a board that reports "
                      "a constant where the cable's own value belongs, and "
                      "lint cannot tell the two apart" %
                      (inst, expr, port, what), file=sys.stderr)
                bad += 1
        if re.fullmatch(r"\w+", a) and re.fullmatch(r"\w+", b) and a != b:
            print("de25_faces: %s.%s takes `%s` and %s.%s takes `%s`, and they "
                  "are %s: one wire, so one name" %
                  (a_inst, a_port, a, b_inst, b_port, b, what), file=sys.stderr)
            bad += 1
    page_rst = conns["u_machine"].get("dbg_rst")
    mach_rst = conns["u_machine"].get("rst")
    if page_rst is None or not re.fullmatch(r"\w+", page_rst):
        print("de25_faces: the machine's `dbg_rst` is `%s`, and the DBGIN "
              "page's reset is the fabric's own signal" % page_rst,
              file=sys.stderr)
        bad += 1
    else:
        for instance in CABLE_RESET:
            got = conns[instance].get("rst")
            if got != page_rst:
                print("de25_faces: %s takes `%s` as its reset and the DBGIN "
                      "page takes `%s`: the cable's modifier bit 1 resets this "
                      "machine, so a connector reset by the machine's reset "
                      "forgets the request that asked for it, and MIT's own "
                      "\"write a 1 here then write a 0\" cannot be written at "
                      "all" % (instance, got, page_rst), file=sys.stderr)
                bad += 1
        if page_rst == mach_rst:
            print("de25_faces: the DBGIN page and the machine both take `%s` "
                  "as their reset, and the page's must be the fabric's alone"
                  % page_rst, file=sys.stderr)
            bad += 1

    bad += check_connector(args.root, top)

    if bad:
        fail("%d of the DE25-Nano's faces are not where the programs look for "
             "them, are not the bridges' shape, do not answer whenever their "
             "bridge is out of reset, or are a wire or a pad of the debug "
             "cable that does not reach where it belongs" % bad)

    print("de25_faces: %d faces, each at the offset its program's address is "
          "into its bridge's window" % len(FACES))
    print("de25_faces: %d wires of the debug cable's seam, each one signal "
          "named the same at both ends, and the connector and the join reset "
          "by `%s` with the DBGIN page and not by `%s` with the machine" %
          (len(WIRED), page_rst, mach_rst))
    if args.stamp:
        os.makedirs(os.path.dirname(args.stamp), exist_ok=True)
        open(args.stamp, "w").close()


if __name__ == "__main__":
    main()
