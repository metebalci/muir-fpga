# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Write `rtl/cadr_ps7.sv` and `tb/cadr_ps7_stub.sv` out of Xilinx's own
# `PS7.v`, because an unconnected PS7 *input* produces no warning of any kind.
#
#     python3 vivado/gen_ps7.py            # write both files
#     python3 vivado/gen_ps7.py --check    # are they what this writes today?
#
# WHY THIS IS GENERATED AND NOT WRITTEN BY HAND.  Measured at 1d3a9bc: a bare
# `PS7` instantiation connecting only the pins it used drew 101 "port is
# unconnected" messages from synthesis, and every one of the 100 distinct
# names was an OUTPUT.  Roughly 300 unconnected inputs were silent, and the
# design routed and wrote a bitstream.  Xilinx's own IP wrapper ties 211
# things explicitly for exactly this reason.  A hand-written instantiation
# cannot be trusted, and a `tb/` stub restricted to the pins we name cannot
# catch it either --- the stub would be written to match what we connect.  So
# both come off the same parse of the same file, in one pass, and the wrapper
# names all 620 pins whether it uses them or not.
#
# WHAT IT READS.  `$XILINX_VIVADO/data/verilog/src/unisims/PS7.v`, whose
# module header is 620 ports --- 325 in, 274 out, 21 inout --- and whose only
# parameter is `LOC`, under `XIL_TIMING`.  There is nothing to configure in
# fabric: the PS7 is a hard block whose entire configuration is software
# written to SLCR at run time.  The counts are asserted below rather than
# assumed, so a Vivado release that moves the port list stops this rather than
# quietly writing a wrapper for a different part.
#
# WITHOUT VIVADO IT SKIPS AND SAYS SO, on `rtl_sys.golden`'s precedent: the
# committed files are what `make check` compares against, CI has no Vivado,
# and a check that cannot run must say it did not run rather than fail.

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

RTL = os.path.join(REPO, "rtl", "cadr_ps7.sv")
STUB = os.path.join(REPO, "tb", "cadr_ps7_stub.sv")

# What the header must be, or this is not the part this wrapper was written
# for.  Measured at 1d3a9bc against Vivado 2026.1.
WANT = {"input": 325, "output": 274, "inout": 21}

SPDX = ("// SPDX-FileCopyrightText: 2026 Mete Balci\n"
        "// SPDX-License-Identifier: AGPL-3.0-or-later")

# The pins the fabric brings out, and the whole of them.  Everything else is
# tied or left open below.
#
# `S_AXI_HP0` at its NATIVE 64 BITS, which is not an arbitrary choice: diffed
# at 1d3a9bc, HP0 disabled against HP0 enabled at 64 bits gives a
# byte-identical `ps7_init.tcl`, and 64-bit against 32-bit differs by exactly
# two register writes per silicon revision --- the AFI0 channel controls, both
# annotated `n32BitEn = 1`.  So at 64 bits any correct Arty Z7-20 `ps7_init`
# works unmodified, including the one already compiled into Digilent's stock
# FSBL, and choosing 32 bits would make us own an FSBL.
#
# `SAXIHP0ARESETN` is an OUTPUT and it is the handshake that says the port is
# live: `ps7_post_config` writes LVL_SHFTR_EN and clears FPGA_RST_CTRL, and
# until then the PS-PL level shifters are off and the port is dead.  A fabric
# that waits on it needs nobody at the board.
#
# `SAXIHP0ACLK` is an INPUT, driven by our own 200 MHz: the fabric clocks the
# port rather than the other way round, and the fabric clock stays on the pin
# because a bitstream programmed over JTAG does not start the PS.
EXPOSED = [
    "SAXIHP0ACLK", "SAXIHP0ARESETN",
    "SAXIHP0AWADDR", "SAXIHP0AWLEN", "SAXIHP0AWSIZE", "SAXIHP0AWBURST",
    "SAXIHP0AWVALID", "SAXIHP0AWREADY",
    "SAXIHP0WDATA", "SAXIHP0WSTRB", "SAXIHP0WLAST", "SAXIHP0WVALID",
    "SAXIHP0WREADY",
    "SAXIHP0BRESP", "SAXIHP0BVALID", "SAXIHP0BREADY",
    "SAXIHP0ARADDR", "SAXIHP0ARLEN", "SAXIHP0ARSIZE", "SAXIHP0ARBURST",
    "SAXIHP0ARVALID", "SAXIHP0ARREADY",
    "SAXIHP0RDATA", "SAXIHP0RRESP", "SAXIHP0RLAST", "SAXIHP0RVALID",
    "SAXIHP0RREADY",
]

# Inputs that are not exposed but must not be zero by default, each with the
# reason it is what it is.  Everything else defaults to zero: an EMIO
# peripheral the SLCR configuration never enables cannot see its own pins, and
# a defined value is the whole requirement.
TIED = {
    "SAXIHP0AWCACHE": ("4'b0011",
                       "normal, non-cacheable, bufferable --- what a PL"
                       " master writing DDR through an AFI port asks for"),
    "SAXIHP0ARCACHE": ("4'b0011", "as AWCACHE"),
}

# Why an input that is tied to zero is tied to zero, for the ones where the
# answer is not "nothing here uses this peripheral".
WHY_ZERO = {
    "SAXIHP0AWID": "one transaction is outstanding at a time, so one ID",
    "SAXIHP0ARID": "as AWID",
    "SAXIHP0WID": "as AWID; AXI3 carries an ID on the write data channel",
    "SAXIHP0AWLOCK": "no exclusive or locked access on this path",
    "SAXIHP0ARLOCK": "as AWLOCK",
    "SAXIHP0AWPROT": "data, secure, unprivileged --- bit 1 clear is SECURE,"
                     " and a non-secure write to a secure DDR region is"
                     " refused rather than misrouted",
    "SAXIHP0ARPROT": "as AWPROT",
    "SAXIHP0AWQOS": "no quality-of-service arbitration is asked for",
    "SAXIHP0ARQOS": "as AWQOS",
    "SAXIHP0RDISSUECAP1EN": "the port's default issuing capability",
    "SAXIHP0WRISSUECAP1EN": "as RDISSUECAP1EN",
}


def parse_ps7(path):
    """The 620 ports of PS7's module header, in the order they are declared."""
    with open(path) as f:
        lines = f.read().split("\n")
    start = None
    for i, line in enumerate(lines):
        if line.startswith("module PS7"):
            start = i
            break
    if start is None:
        die("%s: no `module PS7`" % path)
    i = start
    while lines[i].strip() != "(":
        i += 1
        if i > start + 20:
            die("%s: the module header does not open where it used to" % path)
    pat = re.compile(
        r"^\s*(input|output|inout)\s*(\[[^\]]*\])?\s*([A-Za-z0-9_]+)\s*,?\s*$")
    ports = []
    i += 1
    while lines[i].strip() != ");":
        line = lines[i]
        i += 1
        if not line.strip():
            continue
        m = pat.match(line)
        if not m:
            die("%s: cannot read a port from `%s`" % (path, line))
        ports.append((m.group(3), m.group(1), m.group(2)))
    return ports


def die(msg):
    sys.stderr.write("ps7: %s\n" % msg)
    sys.exit(1)


def port_name(pin):
    """The wrapper's own name for a PS7 pin, by rule and not by table.

    `SAXIHP0` becomes `hp0_` and the rest is lowered, so `SAXIHP0AWADDR` is
    `hp0_awaddr`.  A rule rather than a mapping because a mapping is a second
    description of the same thing and the two drift.
    """
    if pin.startswith("SAXIHP0"):
        return "hp0_" + pin[len("SAXIHP0"):].lower()
    return pin.lower()


def width(rng):
    return "" if rng is None else " %s" % rng


def zero(rng):
    if rng is None:
        return "1'b0"
    hi, lo = rng.strip("[]").split(":")
    return "%d'b0" % (int(hi) - int(lo) + 1)


def wrapper(ports):
    by_name = dict((p[0], p) for p in ports)
    for pin in EXPOSED:
        if pin not in by_name:
            die("%s is not a PS7 port" % pin)
    for pin in list(TIED) + list(WHY_ZERO):
        if pin not in by_name:
            die("%s is not a PS7 port" % pin)
        if by_name[pin][1] != "input":
            die("%s is a %s and cannot be tied" % (pin, by_name[pin][1]))
        if pin in EXPOSED:
            die("%s is both exposed and tied" % pin)

    out = [SPDX, """//
// GENERATED by vivado/gen_ps7.py from $XILINX_VIVADO's own PS7.v.
// Do not edit; run `make ps7`.
//
// The Zynq processing system, with a port list the fabric can read.
//
// **ALL %d PINS ARE NAMED BELOW**, and that is the only reason this file is
// generated rather than written.  An unconnected PS7 input produces no
// warning of any kind --- 101 messages came back from a bare instantiation
// at 1d3a9bc and all 100 distinct names were outputs, while some 300 silent
// inputs floated and the design still wrote a bitstream.  So every input is
// either driven from a port here or tied to a stated value, every unused
// output is explicitly open, and the 21 inouts --- the fixed-I/O set, DDR*
// and MIO and the three PS pins --- are open because they are dedicated pads
// the tool places without help and without an XDC.
//
// There is nothing to configure: PS7's only parameter is `LOC`, under
// `XIL_TIMING`.  The processing system's whole configuration is software
// written to SLCR at run time by `ps7_init`, which is why this wrapper can be
// a wrapper and not an IP core.
""" % len(ports)]

    out.append("`default_nettype none\n\nmodule cadr_ps7 (")
    lines = []
    for pin in EXPOSED:
        _, direction, rng = by_name[pin]
        kind = "input  var logic" if direction == "input" else "output var logic"
        lines.append("    %s%s %s" % (kind, width(rng).ljust(8), port_name(pin)))
    out.append(",\n".join(lines))
    out.append(");\n")

    out.append("""  // PINCONNECTEMPTY is turned off rather than answered with wires nothing
  // reads: an unused OUTPUT left open is what this file means to say, and it
  // is the one direction the tools already warn about.
  /* verilator lint_off PINCONNECTEMPTY */
  PS7 u_ps7 (""")

    body = []
    body.append("      // --- the pins the fabric drives and reads")
    for pin in EXPOSED:
        body.append("      .%s(%s)," % (pin, port_name(pin)))
    body.append("")
    body.append("      // --- inputs tied to a stated value")
    for pin, (value, why) in sorted(TIED.items()):
        body.append("      // %s" % why)
        body.append("      .%s(%s)," % (pin, value))
    body.append("")
    body.append("      // --- every other input, tied low")
    for pin, direction, rng in ports:
        if direction != "input" or pin in EXPOSED or pin in TIED:
            continue
        if pin in WHY_ZERO:
            body.append("      // %s" % WHY_ZERO[pin])
        body.append("      .%s(%s)," % (pin, zero(rng)))
    body.append("")
    body.append("      // --- every unused output, open")
    opens = ["      .%s()," % pin for pin, direction, _ in ports
             if direction == "output" and pin not in EXPOSED]
    body += opens
    body.append("")
    body.append("      // --- the fixed I/O: dedicated pads, placed without help")
    inouts = ["      .%s()," % pin for pin, direction, _ in ports
              if direction == "inout"]
    body += inouts
    text = "\n".join(body)
    # One instantiation, so the last connection carries no comma.
    text = text.rstrip()
    if not text.endswith(","):
        die("the last connection is not a connection")
    out.append(text[:-1])
    out.append("  );\n  /* verilator lint_on PINCONNECTEMPTY */\n")
    out.append("endmodule\n\n`default_nettype wire\n")
    return "\n".join(out)


def stub(ports):
    out = [SPDX, """//
// GENERATED by vivado/gen_ps7.py from $XILINX_VIVADO's own PS7.v.
// Do not edit; run `make ps7`.
//
// `PS7` as an empty shell, so that Verilator can elaborate `rtl/cadr_ps7.sv`
// and lint the top level that instantiates it.
//
// **THIS FILE MUST NEVER MOVE TO `rtl/`.**  `vivado/fit.tcl` and
// `vivado/bitstream.tcl` both read `[glob rtl/*.sv]`, so a stub here would be
// handed to synthesis in place of the real primitive --- and a board whose
// processing system is a bundle of constants is a machine with no memory that
// still lights LEDs.  Nothing globs `tb/`, which is why this is here.
//
// **AND IT MODELS NOTHING.**  Every output is zero, which means
// `hp0_aresetn` is zero, which means the fabric's own gate on it holds the
// memory path in reset for ever.  That is correct for lint and useless for
// anything else.  The one thing it does carry is the PORT LIST, all %d of
// them, off the same parse as the wrapper in the same pass --- so a pin the
// wrapper names and the primitive does not cannot exist here either.
""" % len(ports)]
    out.append("`default_nettype none\n")
    out.append("/* verilator lint_off DECLFILENAME */\n")
    out.append("module PS7 (")
    lines = []
    for pin, direction, rng in ports:
        kind = {"input": "input  var logic",
                "output": "output var logic",
                "inout": "inout  wire      "}[direction]
        lines.append("    %s%s %s" % (kind, width(rng).ljust(8), pin))
    out.append(",\n".join(lines))
    out.append(");\n")
    for pin, direction, rng in ports:
        if direction == "output":
            out.append("  assign %s = %s;" % (pin, zero(rng)))
    out.append("""
  // Every input, read once, so that lint has nothing to say about any of
  // them. The wrapper ties most of these to constants and a fold of
  // constants is still a fold: what it is for is the ones that are not.
  /* verilator lint_off UNUSEDSIGNAL */
  logic unused;
  assign unused = ^{1'b0,""")
    ins = [pin for pin, direction, _ in ports if direction == "input"]
    row = "                    "
    rows = []
    for pin in ins:
        if len(row) + len(pin) + 2 > 78:
            rows.append(row)
            row = "                    "
        row += " " + pin + ","
    rows.append(row.rstrip(","))
    out.append("\n".join(rows) + "};")
    out.append("""  /* verilator lint_on UNUSEDSIGNAL */

endmodule

/* verilator lint_on DECLFILENAME */

`default_nettype wire""")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="compare the committed files with what this writes")
    args = ap.parse_args()

    root = os.environ.get("XILINX_VIVADO")
    src = (os.path.join(root, "data", "verilog", "src", "unisims", "PS7.v")
           if root else None)
    if not src or not os.path.exists(src):
        # The `rtl_sys.golden` rule's shape: say that it did not run, and do
        # not fail. CI has no Vivado and the committed files are the point.
        print("ps7: skipped --- $XILINX_VIVADO/data/verilog/src/unisims/PS7.v "
              "is not here")
        return 0

    ports = parse_ps7(src)
    counts = {}
    for _, direction, _ in ports:
        counts[direction] = counts.get(direction, 0) + 1
    if counts != WANT:
        die("%s has %s, wanting %s --- this is not the port list the wrapper "
            "was written against" % (src, counts, WANT))

    want = {RTL: wrapper(ports), STUB: stub(ports)}
    if args.check:
        for path, text in sorted(want.items()):
            try:
                with open(path) as f:
                    have = f.read()
            except IOError:
                die("%s is missing: run `make ps7` and commit it"
                    % os.path.relpath(path, REPO))
            if have != text:
                die("%s is not what the generator writes today: run `make ps7`"
                    % os.path.relpath(path, REPO))
        print("ok: rtl/cadr_ps7.sv and tb/cadr_ps7_stub.sv are current "
              "(%d PS7 pins)" % len(ports))
        return 0

    for path, text in sorted(want.items()):
        with open(path, "w") as f:
            f.write(text)
        print("ps7: wrote %s" % os.path.relpath(path, REPO))
    return 0


if __name__ == "__main__":
    sys.exit(main())
