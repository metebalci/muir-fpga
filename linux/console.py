#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Log the board's serial console to a file, with a wall-clock stamp on every
# line, until killed.  Started before the board is powered so that U-Boot's
# first line is in the log --- which fetch happened, or did not, is decided in
# the first seconds and nowhere else.
#
#     linux/console.py /dev/ttyUSB1 build/console.log
#
# The Arty Z7's FT2232 gives two ports; the UART is the second (ttyUSB1 when
# it is the only FTDI device), 115200 8N1.  A byte that is not UTF-8 is kept
# as \xNN rather than dropped, since a corrupt line is a finding too.
import sys, time, serial

dev, out = sys.argv[1], sys.argv[2]

# A power cycle re-enumerates the FT2232, so the port goes away and comes back
# under the same name with a new device behind it.  The first version of this
# file died there --- at 06:05:32 on the first boot it was written for, with
# nothing in the log --- so the open is retried until the port is back.  The
# gap is written into the log, since a stamp with nothing between it and the
# next line would read as a board that printed nothing.
def opened():
    while True:
        try:
            return serial.Serial(dev, 115200, timeout=1)
        except (serial.SerialException, OSError):
            time.sleep(0.2)

with open(out, "ab", buffering=0) as log:
    port = opened()
    log.write(f"# console {dev} opened {time.strftime('%Y-%m-%d %H:%M:%S')}\n".encode())
    buf = b""
    while True:
        try:
            data = port.read(4096)
        except (serial.SerialException, OSError):
            log.write(f"# {time.strftime('%H:%M:%S')} port lost, waiting for it to come back\n".encode())
            port.close()
            port = opened()
            log.write(f"# {time.strftime('%H:%M:%S')} port reopened\n".encode())
            buf = b""
            continue
        if not data:
            continue
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            stamp = time.strftime("%H:%M:%S").encode()
            log.write(stamp + b" " + line.rstrip(b"\r").decode("utf-8", "backslashreplace").encode() + b"\n")
