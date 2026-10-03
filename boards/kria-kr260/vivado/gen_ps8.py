# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Write `boards/kria-kr260/cadr_ps8.sv` and `tb/cadr_ps8_stub.sv` out of
# Xilinx's own `PS8.v`, the Zynq UltraScale+ processing system's primitive.
#
#     python3 boards/kria-kr260/vivado/gen_ps8.py            # write both files
#     python3 boards/kria-kr260/vivado/gen_ps8.py --check    # are they current?
#
# THE SAME DISCIPLINE AS THE ZYNQ-7000's `gen_ps7.py`, FOR THE SAME REASON:
# an unconnected input of a hard block produces no warning, so the wrapper
# names every one of the primitive's pins --- 1,015 of them here --- either
# driven from a port, tied to a stated value, or left open, and the lint stub
# comes off the same parse in the same pass.  A front end over the Arty's
# generator was not enough: the primitive, its port count, its tie table and
# its ports are all different, and only `width` and `zero` would be shared.
#
# THE TIE TABLE IS MEASURED, NOT REMEMBERED.  `PS8` has inputs whose quiet
# value is ONE --- the RPU's interrupt lines are active low, so a zero there
# is an interrupt held asserted --- and nothing in the port list says which.
# So the values below are those Vivado's own PS IP (`zynq_ultra_ps_e`, with
# the KR260's board preset and the ports this wrapper exposes) drives into the
# primitive: its RTL was elaborated and every `PS8` input pin's driver read
# back.  Of the 531 inputs, every one the IP ties is tied low except the
# eighteen in `TIED` below, and those are tied to the IP's own values.  The
# two `AxCACHE` pairs are this project's choice, as on the Zynq-7000.
#
# THERE IS NOTHING TO CONFIGURE IN FABRIC, as with `PS7`: the primitive's only
# parameter is `LOC`, under `XIL_TIMING`.  The processing system's whole
# configuration --- the clocks, the DDR controller, the port widths --- is
# the boot firmware's, written at run time.  In particular the width of each
# AXI port is a register (UG1087: `FPD_SLCR.AFI_FS`, `AFIFM*.RDCTRL` and
# `WRCTRL`), which the KR260's firmware leaves at its reset value, 128 bits;
# the fabric is built for that width (`rtl/plumbing/cadr_axi_widen128.sv`).
#
# WITHOUT VIVADO IT SKIPS AND SAYS SO, as `gen_ps7.py` does: the committed
# files are what `make current` compares against.

import argparse
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

RTL = os.path.join(REPO, "boards", "kria-kr260", "cadr_ps8.sv")
STUB = os.path.join(REPO, "tb", "cadr_ps8_stub.sv")

# What the header must be, or this is not the part the wrapper was written
# for.  Measured against Vivado 2026.1.
WANT = {"input": 531, "output": 452, "inout": 32}

SPDX = ("// SPDX-FileCopyrightText: 2026 Mete Balci\n"
        "// SPDX-License-Identifier: AGPL-3.0-or-later")


def axi_master(p):
    """A PS master port's pins a 32-bit register face needs (AXI4)."""
    return [p + s for s in (
        "ACLK",
        "AWADDR", "AWLEN", "AWID", "AWVALID", "AWREADY",
        "WDATA", "WSTRB", "WLAST", "WVALID", "WREADY",
        "BRESP", "BID", "BVALID", "BREADY",
        "ARADDR", "ARLEN", "ARID", "ARVALID", "ARREADY",
        "RDATA", "RRESP", "RID", "RLAST", "RVALID", "RREADY")]


def axi_slave(p):
    """A PS slave port's pins a fabric master drives (AXI4, one ID)."""
    return [p + s for s in (
        "RCLK", "WCLK",
        "AWADDR", "AWLEN", "AWSIZE", "AWBURST", "AWVALID", "AWREADY",
        "WDATA", "WSTRB", "WLAST", "WVALID", "WREADY",
        "BRESP", "BVALID", "BREADY",
        "ARADDR", "ARLEN", "ARSIZE", "ARBURST", "ARVALID", "ARREADY",
        "RDATA", "RRESP", "RLAST", "RVALID", "RREADY")]


# The pins the fabric brings out, and the whole of them.
#
#   `M_AXI_HPM0_FPD` (the primitive's `MAXIGP0`): the faces --- the disk
#     pack's registers, the Chaosnet and serial cables, the input face ---
#     behind `rtl/plumbing/cadr_gp0_split.sv`, at 0xA000_0000 (UG1085 table
#     10-1, with no video codec mapped).  The Zynq-7000's `M_AXI_GP0`.
#   `M_AXI_HPM1_FPD` (`MAXIGP1`): the console and the debug window behind
#     `rtl/plumbing/cadr_gp1_split.sv`, at 0xB000_0000.  The Zynq-7000's
#     `M_AXI_GP1`.
#   `S_AXI_HP0_FPD` (`SAXIGP2`): the machine's main memory.  It shares its
#     DDR controller port, XPI 3, with the DisplayPort controller's DMA only
#     (UG1085 ch. 35), which stays idle while the display is the fabric's
#     live input; no HP port has a DDR port to itself on this part.
#   `S_AXI_HP2_FPD` (`SAXIGP4`): the disk pack's.  XPI 4, shared with HP1
#     and nothing else here, so the disk's traffic is off the machine's port.
#   `S_AXI_HP3_FPD` (`SAXIGP5`): the display output's reads of the CADR's
#     screens.  XPI 5, shared with the FPD DMA alone, and off both the
#     machine's port and the pack side's (UG1085 ch. 35).
#   `DPVIDEOINCLK` and `DPLIVEVIDEOIN*`: the display output's raster into the
#     DisplayPort controller's live video input, pixel 1 at 8 bits a
#     component in UG1085 table 33-3's places, clocked by the fabric's own
#     pixel clock.  The controller's video reference clock (`DPVIDEOREFCLK`)
#     is not used: without Linux's display driver it is not at the mode's
#     rate (measured in the board's K9 spike).
#   `EMIOGPIOI`: the fabric's ninety-six bits into the GPIO block.  Banks 3
#     and 4 carry the memory tally (`rtl/plumbing/cadr_mem_count.sv`), read
#     at `DATA_3_RO` 0xFF0A_006C and `DATA_4_RO` 0xFF0A_0070 (UG1087); bank 5
#     carries a count of the machine's clock, for measuring it.
#   `EMIOGPIOO`: bit 95 is `pl_resetn0`, the fabric reset the processing
#     system releases once a load has opened the PS-PL boundary --- Vivado's
#     own IP takes it from exactly that bit.  It is the counterpart of the
#     Zynq-7000's per-port `ARESETN`: the ports are live while it is high.
#   `PLPSIRQ0`: the fabric's eight interrupt lines, GIC SPIs 121 to 128
#     (UG1085 table 13-1).
#
# Every port is clocked by the fabric's own 100 MHz, the machine's tick,
# made from the carrier's 25 MHz input: none of the processing system's
# `pl_clk` outputs is used, because the kernel gates them at late start-up
# unless a driver claims them (measured on the board).
EXPOSED = (axi_master("MAXIGP0") + axi_master("MAXIGP1")
           + axi_slave("SAXIGP2") + axi_slave("SAXIGP4")
           + ["EMIOGPIOI", "EMIOGPIOO", "PLPSIRQ0"]
           + axi_slave("SAXIGP5")
           + ["DPVIDEOINCLK", "DPLIVEVIDEOINVSYNC", "DPLIVEVIDEOINHSYNC",
              "DPLIVEVIDEOINDE", "DPLIVEVIDEOINPIXEL1"])

# Inputs that are not exposed and must not be zero, each with its value and
# the reason.  All but the four `AxCACHE` lines are what Vivado's own PS IP
# drives, read from its elaborated RTL (see the header).
TIED = {
    "NFIQ0LPDRPU": ("1'b1", "the RPU's FIQ, active low: not asserted"),
    "NFIQ1LPDRPU": ("1'b1", "as NFIQ0LPDRPU, the second R5"),
    "NIRQ0LPDRPU": ("1'b1", "the RPU's IRQ, active low: not asserted"),
    "NIRQ1LPDRPU": ("1'b1", "as NIRQ0LPDRPU, the second R5"),
    "EMIOENET0TXRSOP": ("1'b1", "as Vivado's PS IP ties it: no EMIO Ethernet"),
    "EMIOENET0TXREOP": ("1'b1", "as Vivado's PS IP ties it: no EMIO Ethernet"),
    "EMIOENET1TXRSOP": ("1'b1", "as Vivado's PS IP ties it: no EMIO Ethernet"),
    "EMIOENET1TXREOP": ("1'b1", "as Vivado's PS IP ties it: no EMIO Ethernet"),
    "EMIOENET2TXRSOP": ("1'b1", "as Vivado's PS IP ties it: no EMIO Ethernet"),
    "EMIOENET2TXREOP": ("1'b1", "as Vivado's PS IP ties it: no EMIO Ethernet"),
    "EMIOENET3TXRSOP": ("1'b1", "as Vivado's PS IP ties it: no EMIO Ethernet"),
    "EMIOENET3TXREOP": ("1'b1", "as Vivado's PS IP ties it: no EMIO Ethernet"),
    "EMIOSDIO0WP": ("1'b1", "as Vivado's PS IP ties it: no EMIO SD card"),
    "EMIOSDIO1WP": ("1'b1", "as Vivado's PS IP ties it: no EMIO SD card"),
    "EMIOSPI0SSIN": ("1'b1", "the SPI slave select, active low: not selected"),
    "EMIOSPI1SSIN": ("1'b1", "as EMIOSPI0SSIN"),
    "SACEFPDAWUSER": ("16'h03C0", "as Vivado's PS IP ties it: no ACE master"),
    "SACEFPDARUSER": ("16'h03C0", "as SACEFPDAWUSER"),
    "SAXIGP2AWCACHE": ("4'b0011",
                       "normal, non-cacheable, bufferable --- what the"
                       " Zynq-7000's HP ports are given here too"),
    "SAXIGP2ARCACHE": ("4'b0011", "as AWCACHE"),
    "SAXIGP4AWCACHE": ("4'b0011", "as HP0's: a fabric master writing DDR"),
    "SAXIGP4ARCACHE": ("4'b0011", "as AWCACHE"),
    "SAXIGP5AWCACHE": ("4'b0011", "as HP0's: the display never writes"),
    "SAXIGP5ARCACHE": ("4'b0011", "as HP0's: a fabric master reading DDR"),
}

WHY_ZERO = {
    "SAXIGP2AWID": "one transaction is outstanding at a time, so one ID",
    "SAXIGP2ARID": "as AWID",
    "SAXIGP2AWLOCK": "no exclusive access on this path",
    "SAXIGP2ARLOCK": "as AWLOCK",
    "SAXIGP2AWPROT": "data, secure, unprivileged, as on the Zynq-7000's HP ports",
    "SAXIGP2ARPROT": "as AWPROT",
    "SAXIGP2AWQOS": "no quality-of-service arbitration is asked for",
    "SAXIGP2ARQOS": "as AWQOS",
    "SAXIGP2AWUSER": "no coherency is asked for: the region is uncached",
    "SAXIGP2ARUSER": "as AWUSER",
    "SAXIGP4AWID": "one burst is outstanding at a time, so one ID",
    "SAXIGP4ARID": "as AWID",
    "SAXIGP4AWLOCK": "no exclusive access on this path",
    "SAXIGP4ARLOCK": "as AWLOCK",
    "SAXIGP4AWPROT": "data, secure, unprivileged, as HP0's",
    "SAXIGP4ARPROT": "as AWPROT",
    "SAXIGP4AWQOS": "no quality-of-service arbitration is asked for",
    "SAXIGP4ARQOS": "as AWQOS",
    "SAXIGP4AWUSER": "no coherency is asked for: the region is uncached",
    "SAXIGP4ARUSER": "as AWUSER",
    "SAXIGP5AWID": "the display never writes",
    "SAXIGP5ARID": "one ID: the display's reads come back in the order asked",
    "SAXIGP5AWLOCK": "no exclusive access on this path",
    "SAXIGP5ARLOCK": "as AWLOCK",
    "SAXIGP5AWPROT": "data, secure, unprivileged, as HP0's",
    "SAXIGP5ARPROT": "as AWPROT",
    "SAXIGP5AWQOS": "no quality-of-service arbitration is asked for",
    "SAXIGP5ARQOS": "as AWQOS",
    "SAXIGP5AWUSER": "no coherency is asked for: the region is uncached",
    "SAXIGP5ARUSER": "as AWUSER",
}

# The prefix a pin's block is known by, and what the wrapper calls it.
PREFIXES = [
    ("MAXIGP0", "hpm0_"),
    ("MAXIGP1", "hpm1_"),
    ("SAXIGP2", "hp0_"),
    ("SAXIGP4", "hp2_"),
    ("EMIOGPIO", "gpio_"),
    ("PLPSIRQ0", "irq0"),
    ("SAXIGP5", "hp3_"),
    ("DP", "dp_"),
]


def die(msg):
    sys.stderr.write("ps8: %s\n" % msg)
    sys.exit(1)


def parse_ps8(path):
    """The ports of PS8's module header, in the order they are declared."""
    with open(path) as f:
        lines = f.read().split("\n")
    start = None
    for i, line in enumerate(lines):
        if line.strip() == "module PS8":
            start = i
            break
    if start is None:
        die("%s: no `module PS8`" % path)
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


def port_name(pin):
    """The wrapper's name for a pin, by rule: `MAXIGP0AWADDR` is
    `hpm0_awaddr`, `SAXIGP2RCLK` is `hp0_rclk`, `EMIOGPIOI` is `gpio_i`."""
    for prefix, short in sorted(PREFIXES, key=lambda p: -len(p[0])):
        if pin.startswith(prefix):
            return short + pin[len(prefix):].lower()
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
            die("%s is not a PS8 port" % pin)
    if len(set(EXPOSED)) != len(EXPOSED):
        die("a pin is exposed twice")
    for pin in list(TIED) + list(WHY_ZERO):
        if pin not in by_name:
            die("%s is not a PS8 port" % pin)
        if by_name[pin][1] != "input":
            die("%s is a %s and cannot be tied" % (pin, by_name[pin][1]))
        if pin in EXPOSED:
            die("%s is both exposed and tied" % pin)
    for pin in TIED:
        if pin in WHY_ZERO:
            die("%s is both tied high and explained as zero" % pin)

    out = [SPDX, """//
// GENERATED by boards/kria-kr260/vivado/gen_ps8.py from $XILINX_VIVADO's own PS8.v.
// Do not edit; run `make ps8`.
//
// The Zynq UltraScale+ processing system, with a port list the fabric can
// read: the Kria KR260's counterpart of the Zynq-7000 boards' `cadr_ps7.sv`.
//
// **ALL %d PINS ARE NAMED BELOW**, because an unconnected input of a hard
// block produces no warning of any kind.  Every input is driven from a port
// here or tied to a stated value --- the values Vivado's own PS IP ties them
// to, read from its elaborated RTL, which is how the active-low ones are
// known --- every unused output is explicitly open, and the inouts are the
// dedicated processing-system pads, placed without help.
//
// There is nothing to configure: PS8's only parameter is `LOC`.  The port
// widths are registers the boot firmware writes, and the KR260's leaves all
// of them at 128 bits, which is what the fabric behind this is built for.
""" % len(ports)]

    out.append("`default_nettype none\n\nmodule cadr_ps8 (")
    lines = []
    for pin in EXPOSED:
        _, direction, rng = by_name[pin]
        kind = "input  var logic" if direction == "input" else "output var logic"
        lines.append("    %s%s %s" % (kind, width(rng).ljust(9), port_name(pin)))
    out.append(",\n".join(lines))
    out.append(");\n")

    out.append("""  // PINCONNECTEMPTY is turned off rather than answered with wires nothing
  // reads: an unused OUTPUT left open is what this file means to say.
  /* verilator lint_off PINCONNECTEMPTY */
  PS8 u_ps8 (""")

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
    body += ["      .%s()," % pin for pin, direction, _ in ports
             if direction == "output" and pin not in EXPOSED]
    body.append("")
    body.append("      // --- the processing system's dedicated pads")
    body += ["      .%s()," % pin for pin, direction, _ in ports
             if direction == "inout"]
    text = "\n".join(body).rstrip()
    if not text.endswith(","):
        die("the last connection is not a connection")
    out.append(text[:-1])
    out.append("  );\n  /* verilator lint_on PINCONNECTEMPTY */\n")
    out.append("endmodule\n\n`default_nettype wire\n")
    return "\n".join(out)


def stub(ports):
    out = [SPDX, """//
// GENERATED by boards/kria-kr260/vivado/gen_ps8.py from $XILINX_VIVADO's own PS8.v.
// Do not edit; run `make ps8`.
//
// `PS8` as an empty shell, so that Verilator can elaborate
// `boards/kria-kr260/cadr_ps8.sv` and lint the top level that instantiates it.
//
// **THIS FILE MUST NEVER MOVE TO `rtl/` OR `boards/`**: the Vivado flows glob
// those, and a stub there would be handed to synthesis in place of the real
// primitive.  Nothing globs `tb/`.
//
// **AND IT MODELS NOTHING.**  Every output is zero, so `pl_resetn0` is low
// and the fabric's ports are held in reset for ever.  What it carries is the
// PORT LIST, all %d of them, off the same parse as the wrapper.
""" % len(ports)]
    out.append("`default_nettype none\n")
    out.append("/* verilator lint_off DECLFILENAME */\n")
    out.append("module PS8 (")
    lines = []
    for pin, direction, rng in ports:
        kind = {"input": "input  var logic",
                "output": "output var logic",
                "inout": "inout  wire      "}[direction]
        lines.append("    %s%s %s" % (kind, width(rng).ljust(9), pin))
    out.append(",\n".join(lines))
    out.append(");\n")
    for pin, direction, rng in ports:
        if direction == "output":
            out.append("  assign %s = %s;" % (pin, zero(rng)))
    out.append("""
  // Every input, read once, so that lint has nothing to say about any of
  // them.
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
    src = (os.path.join(root, "data", "verilog", "src", "unisims", "PS8.v")
           if root else None)
    if not src or not os.path.exists(src):
        print("ps8: skipped --- $XILINX_VIVADO/data/verilog/src/unisims/PS8.v "
              "is not here")
        return 0

    ports = parse_ps8(src)
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
                die("%s is missing: run `make ps8` and commit it"
                    % os.path.relpath(path, REPO))
            if have != text:
                die("%s is not what the generator writes today: run `make ps8`"
                    % os.path.relpath(path, REPO))
        print("ok: boards/kria-kr260/cadr_ps8.sv and tb/cadr_ps8_stub.sv are "
              "current (%d PS8 pins)" % len(ports))
        return 0

    for path, text in sorted(want.items()):
        with open(path, "w") as f:
            f.write(text)
        print("ps8: wrote %s" % os.path.relpath(path, REPO))
    return 0


if __name__ == "__main__":
    sys.exit(main())
