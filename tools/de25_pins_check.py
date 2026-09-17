#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The DE25-Nano's pin file, held to itself and to a second witness.

`boards/de25-nano/de25_nano_pins.tcl` is transcribed from Terasic's user
manual. Nothing in this repository can read a PDF, so a transcription error
would otherwise stand until a board lit the wrong LED. This checks it two ways.

**Always, against itself.** Every `de25_pin` line must parse. Ports, package
pins and the manual's names must each be unique, every I/O standard must be
one this board uses, and each port's name must say the same signal as the
manual's name beside it: `led[3]` beside `LEDR[3]`, `jp2_pin13` beside
`GPIO_1[10]`. Each header must assign exactly its 36 signal pins, which is
the numbering Figure 3-18 of the manual gives. This part needs nothing but
this repository.

**When Terasic's resource package is here, against its Quartus settings.**
The rev B package's `Demonstration/FPGA/Golden_top/golden_top.qsf` assigns
every pin of the board. It is not a source for the pin file and nothing of it
is copied into this repository; it is a second document from the same
publisher, read here to compare. For every port in the pin file, the file
must have a counterpart, and the two must agree on the package pin and the
I/O standard. A port the package does not name fails, unless the line above
it says so with a reason, in a comment of the form

    # de25_pins_check: absent from the package: <why>

The package is not redistributable and needs an account to download, so the
comparison skips when no package is named, and says so. It is named by
`TERASIC_DE25_PACKAGE` in the environment or by a line of that form in the
gitignored `boards/de25-nano/local.conf`. A package that is named and is not
there fails. So does a `.qsf` whose sha256 is not the one this directory's
README records, because a comparison against another file compares nothing
the README describes.

`--stamp PATH` touches PATH only when the comparison ran and agreed. A skip
leaves it alone, so `make` asks again on the next run rather than
remembering a skip as a pass.
"""

import argparse
import hashlib
import os
import re
import sys
from pathlib import Path

PINS = "boards/de25-nano/de25_nano_pins.tcl"
README = "boards/de25-nano/README.md"
LOCAL_CONF = "boards/de25-nano/local.conf"
QSF = "Demonstration/FPGA/Golden_top/golden_top.qsf"
ENV = "TERASIC_DE25_PACKAGE"

STANDARDS = {"1.1-V", "3.3-V LVCMOS"}

LINE = re.compile(r'^de25_pin \{([^{}]+)\} \{([^{}]+)\} (PIN_[A-Z]+[0-9]+) "([^"]+)"\s*$')
SUPPLY = re.compile(r'^set de25_header_supply_pins \{([0-9 ]+)\}\s*$')
ABSENT = re.compile(r'^#\s*de25_pins_check:\s*absent from the package:\s*(\S.*)$')

# The ports whose names are not a rule, each beside the manual's name.
HDMI = {
    "hdmi_pclk": "HDMI_TX_CLK",
    "hdmi_de": "HDMI_TX_DE",
    "hdmi_hsync": "HDMI_TX_HS",
    "hdmi_vsync": "HDMI_TX_VS",
    "hdmi_int": "HDMI_TX_INT",
    "hdmi_scl": "HDMI_I2C_SCL",
    "hdmi_sda": "HDMI_I2C_SDA",
    "hdmi_i2s_data": "HDMI_I2S",
    "hdmi_i2s_mclk": "HDMI_MCLK",
    "hdmi_i2s_lrclk": "HDMI_LRCLK",
    "hdmi_i2s_bclk": "HDMI_SCLK",
}

failures = []


def fail(message):
    failures.append(message)


def header_index(pin):
    """The manual's signal index for header pin `pin`, or None for a supply pin.

    Figure 3-18: pins 1 to 10 are signals 0 to 9, pins 11 and 12 are 5 V and
    ground, pins 13 to 28 are signals 10 to 25, pins 29 and 30 are 3.3 V and
    ground, and pins 31 to 40 are signals 26 to 35.
    """
    if 1 <= pin <= 10:
        return pin - 1
    if 13 <= pin <= 28:
        return pin - 3
    if 31 <= pin <= 40:
        return pin - 5
    return None


def manual_name_for(port):
    """The manual's name for a port, by the pin file's naming, or None."""
    if port in HDMI:
        return HDMI[port]
    m = re.fullmatch(r"clock50_([0-2])", port)
    if m:
        return "CLOCK%s_50" % m.group(1)
    m = re.fullmatch(r"(sw|btn|led|hdmi_d)\[([0-9]+)\]", port)
    if m:
        n = int(m.group(2))
        name, width = {"sw": ("SW[%d]", 4), "btn": ("KEY[%d]", 2),
                       "led": ("LEDR[%d]", 8), "hdmi_d": ("HDMI_TX_D%d", 24)}[m.group(1)]
        return name % n if n < width else None
    m = re.fullmatch(r"jp([12])_pin([0-9]+)", port)
    if m:
        index = header_index(int(m.group(2)))
        if index is None:
            return None
        return "GPIO_%d[%d]" % (int(m.group(1)) - 1, index)
    return None


def package_name_for(manual):
    """The resource package's name for the manual's signal.

    The two documents name three groups differently: the LEDs, the header
    signals and the video bus. Everything else carries the manual's name.
    """
    m = re.fullmatch(r"LEDR\[([0-9]+)\]", manual)
    if m:
        return "LED[%s]" % m.group(1)
    m = re.fullmatch(r"GPIO_([01])\[([0-9]+)\]", manual)
    if m:
        return "GPIO%s_D[%s]" % (m.group(1), m.group(2))
    m = re.fullmatch(r"HDMI_TX_D([0-9]+)", manual)
    if m:
        return "HDMI_TX_D[%s]" % m.group(1)
    return manual


def read_pins(path):
    pins = []
    supply = None
    absent = None
    lines = path.read_text().splitlines()
    in_proc = False
    for number, line in enumerate(lines, 1):
        where = "%s:%d" % (path.name, number)
        if line.startswith("proc de25_pin "):
            in_proc = True
            continue
        if in_proc:
            in_proc = line.rstrip() != "}"
            continue
        m = ABSENT.match(line.strip())
        if m:
            absent = m.group(1)
            continue
        if line.startswith("de25_pin"):
            m = LINE.match(line)
            if not m:
                fail("%s: a de25_pin line that does not parse: %s" % (where, line))
            else:
                pins.append({"port": m.group(1), "manual": m.group(2), "pin": m.group(3),
                             "standard": m.group(4), "where": where, "absent": absent})
            absent = None
            continue
        if absent is not None and line.strip() and not line.lstrip().startswith("#"):
            fail("%s: an absent-from-the-package note stands above something that is "
                 "not a de25_pin line" % where)
            absent = None
        m = SUPPLY.match(line)
        if m:
            supply = sorted(int(x) for x in m.group(1).split())
        elif re.match(r"\s*set_(location|instance)_assignment\b", line):
            fail("%s: an assignment outside de25_pin, which nothing here checks: %s"
                 % (where, line.strip()))
    if in_proc:
        fail("%s: the de25_pin procedure is never closed" % path.name)
    return pins, supply


def check_self(pins, supply, name):
    if not pins:
        fail("%s assigns no pins" % name)
        return
    for key, what in (("port", "port"), ("pin", "package pin"), ("manual", "manual name")):
        seen = {}
        for p in pins:
            if p[key] in seen:
                fail("%s: %s %s is also at %s" % (p["where"], what, p[key], seen[p[key]]))
            seen.setdefault(p[key], p["where"])
    for p in pins:
        if p["standard"] not in STANDARDS:
            fail("%s: %s has I/O standard \"%s\", which is not one this board uses (%s)"
                 % (p["where"], p["port"], p["standard"], ", ".join(sorted(STANDARDS))))
        want = manual_name_for(p["port"])
        if want is None:
            fail("%s: port %s is not a name the pin file's naming has" % (p["where"], p["port"]))
        elif want != p["manual"]:
            fail("%s: port %s is the manual's %s, and the line says %s"
                 % (p["where"], p["port"], want, p["manual"]))
    if supply != [11, 12, 29, 30]:
        fail("%s: de25_header_supply_pins is %s, and Figure 3-18 gives 11, 12, 29 and 30"
             % (name, supply))
    for header in (1, 2):
        have = sorted(int(m.group(1)) for m in
                      (re.fullmatch(r"jp%d_pin([0-9]+)" % header, p["port"]) for p in pins) if m)
        want = [n for n in range(1, 41) if header_index(n) is not None]
        missing = sorted(set(want) - set(have))
        extra = sorted(set(have) - set(want))
        if missing:
            fail("JP%d: header pins %s have no line" % (header, missing))
        if extra:
            fail("JP%d: header pins %s are not signal pins" % (header, extra))


def read_readme_digest(root):
    for line in (root / README).read_text().splitlines():
        if ("`%s`" % QSF) in line:
            m = re.search(r"`([0-9a-f]{64})`", line)
            if m:
                return m.group(1)
    return None


def package_path(root):
    """The package's path and where it was named, or (None, None)."""
    if os.environ.get(ENV):
        return Path(os.environ[ENV]).expanduser(), "the environment's %s" % ENV
    conf = root / LOCAL_CONF
    if conf.is_file():
        for line in conf.read_text().splitlines():
            m = re.match(r"\s*%s\s*=\s*(.*?)\s*$" % ENV, line)
            if m and not line.lstrip().startswith("#"):
                value = m.group(1).strip("\"'")
                if value:
                    return Path(value).expanduser(), LOCAL_CONF
    return None, None


def read_qsf(path):
    location = {}
    standard = {}
    for line in path.read_text(errors="replace").splitlines():
        line = line.strip()
        m = re.match(r"set_location_assignment\s+(PIN_\S+)\s+-to\s+(\S+)", line)
        if m:
            location[m.group(2)] = m.group(1)
            continue
        m = re.match(r'set_instance_assignment\s+-name\s+IO_STANDARD\s+"([^"]+)"\s+-to\s+(\S+)', line)
        if m:
            standard[m.group(2)] = m.group(1)
    return location, standard


def compare(pins, location, standard):
    compared = 0
    for p in pins:
        name = package_name_for(p["manual"])
        if name not in location and name not in standard:
            if p["absent"]:
                continue
            fail("%s: %s, the manual's %s, has no counterpart %s in the package"
                 % (p["where"], p["port"], p["manual"], name))
            continue
        if p["absent"]:
            fail("%s: %s is marked absent from the package, and the package names it %s"
                 % (p["where"], p["port"], name))
        if location.get(name) != p["pin"]:
            fail("%s: %s, the manual's %s, is at %s here and at %s in the package"
                 % (p["where"], p["port"], p["manual"], p["pin"], location.get(name)))
        if standard.get(name) != p["standard"]:
            fail("%s: %s, the manual's %s, is \"%s\" here and \"%s\" in the package"
                 % (p["where"], p["port"], p["manual"], p["standard"], standard.get(name)))
        compared += 1
    return compared


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("root", nargs="?", default=".")
    parser.add_argument("--pins", help="a pin file other than %s" % PINS)
    parser.add_argument("--stamp", help="touched when the comparison ran and agreed")
    args = parser.parse_args()
    root = Path(args.root)
    pins_path = Path(args.pins) if args.pins else root / PINS

    pins, supply = read_pins(pins_path)
    check_self(pins, supply, pins_path.name)
    if failures:
        for f in failures:
            print("de25_pins: FAIL: %s" % f)
        return 1
    print("de25_pins: ok: %d pins in %s agree with themselves and with the header numbering"
          % (len(pins), pins_path.name))

    package, named_by = package_path(root)
    if package is None:
        print("de25_pins: skipped the comparison --- no Terasic DE25-Nano rev B resource package "
              "is named; set %s or write it into %s" % (ENV, LOCAL_CONF))
        return 0
    qsf = package / QSF
    if not qsf.is_file():
        print("de25_pins: FAIL: %s names %s, and %s is not there" % (named_by, package, QSF))
        return 1
    digest = hashlib.sha256(qsf.read_bytes()).hexdigest()
    recorded = read_readme_digest(root)
    if recorded is None:
        print("de25_pins: FAIL: %s records no sha256 for %s" % (README, QSF))
        return 1
    if digest != recorded:
        print("de25_pins: FAIL: %s has sha256 %s, and %s records %s"
              % (QSF, digest, README, recorded))
        return 1

    location, standard = read_qsf(qsf)
    compared = compare(pins, location, standard)
    if failures:
        for f in failures:
            print("de25_pins: FAIL: %s" % f)
        return 1
    absent = sum(1 for p in pins if p["absent"])
    print("de25_pins: ok: %d pins agree with the package's %s on pin and I/O standard%s"
          % (compared, QSF, "" if not absent else ", and %d are marked absent there" % absent))
    if args.stamp:
        Path(args.stamp).touch()
    return 0


if __name__ == "__main__":
    sys.exit(main())
