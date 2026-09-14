#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Turn a flat binary into the hex file `$readmemh` reads.

`rtl/plumbing/cadr_soc_ram.sv` is a 32-bit memory whose contents arrive at
elaboration, the way `rtl/machine/cadr_microcycle.sv`'s control store does.
This writes the file: one 32-bit word a line, most significant digit first,
little-endian within the word because that is the byte order RISC-V has and
the order the linker wrote the image in.

It refuses an image that does not fit. `$readmemh` on a file longer than the
memory is a warning and carries on, and a firmware whose tail was dropped runs
until it reaches the part that is not there. The same argument as the Makefile
naming the toolchain: a build that cannot succeed should stop rather than
produce something that looks finished.

A short image is padded with zeros to the memory's length, so that the hex
names every word. `$readmemh` would leave the rest as whatever the simulator
or the fitter chose, and a memory whose tail means two different things in two
tools is the kind of difference nobody finds.
"""

import sys


def main(argv):
    if len(argv) != 4:
        sys.stderr.write(
            "usage: bin2hex.py <image.bin> <words> <out.hex>\n")
        return 2
    src, words, dst = argv[1], int(argv[2]), argv[3]
    with open(src, "rb") as f:
        data = f.read()
    if len(data) % 4:
        data += b"\x00" * (4 - len(data) % 4)
    have = len(data) // 4
    if have > words:
        sys.stderr.write(
            "bin2hex: %s is %d words and the memory is %d: "
            "the image does not fit\n" % (src, have, words))
        return 1
    with open(dst, "w") as f:
        for i in range(words):
            if i < have:
                w = int.from_bytes(data[4 * i:4 * i + 4], "little")
            else:
                w = 0
            f.write("%08x\n" % w)
    sys.stderr.write("bin2hex: %d of %d words used, %d bytes\n"
                     % (have, words, len(data)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
