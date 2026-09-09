<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# Reaching the board

The board need not be attached to the machine that runs Vivado. `hw_server`
owns the JTAG cable and speaks to Vivado's hardware manager over TCP 3121, so
the tools can sit on one machine and the Arty on another. That is the
arrangement here: Vivado on a machine with the memory for it, the board on
whatever is convenient.

## On the machine holding the board

Install **Hardware Server** from the AMD unified installer --- not Vivado, and
not Vivado Lab Edition unless you also want to program from that machine. It is
the smallest of the three and it is `hw_server` plus the cable drivers.
Its version should match the Vivado it will talk to; mixing them sometimes
works and is a poor thing to be debugging on a first bring-up.

    ~/Xilinx/<version>/HWSRVR/bin/hw_server

There is no `settings64.sh` in that install; call the binary by its path. It
listens on `TCP::3121` unless `-s<url>` says otherwise, and `-d` daemonises it.

## The udev rules, which are not optional

The Arty Z7-20's JTAG is an onboard FTDI FT2232H, `0403:6010`, reporting
`manufacturer = Digilent`. Without rules its device node is `crw-rw-r--
root root`, so `hw_server` running as an ordinary user can read it and not
write it. **The symptom is not a permission error.** The server starts,
Vivado connects to it, and then:

    ERROR: [Labtoolstcl 44-199] No matching targets found on connected
    servers: <address>

which reads like a cable or a network problem and is neither.

The rules ship with Vivado, so take them from a machine that has it rather
than writing them:

    <Vivado>/data/xicom/cable_drivers/lin64/install_script/install_drivers/
        52-xilinx-digilent-usb.rules
        52-xilinx-ftdi-usb.rules
        52-xilinx-pcusb.rules

    sudo cp 52-xilinx-*.rules /etc/udev/rules.d/
    sudo udevadm control --reload-rules && sudo udevadm trigger

Then **unplug the board and plug it back in.** udev applies rules on `add`, so
a device already enumerated keeps the permissions it was born with, and the
whole thing looks unchanged until it is replugged. The device number changes
when it works.

The rule that does the work is

    ACTION=="add", ATTRS{idVendor}=="0403", ATTRS{manufacturer}=="Digilent", MODE:="666"

`:=` rather than `=` so that a later rules file cannot lower it.

## From Vivado

    open_hw_manager
    connect_hw_server -url <board-machine>:3121
    current_hw_target [lindex [get_hw_targets] 0]
    open_hw_target

These are Tcl commands inside Vivado, not programs: run them in the Tcl
console, in `vivado -mode tcl`, or from a script with `-mode batch -source`.
Over ssh the last is easiest, and a long run wants `nohup setsid ...
</dev/null &` with a poll, since the session will not outlive it.

A working chain on this board answers with two devices --- the ARM debug
access port and the part itself:

    device: arm_dap_0   part=arm_dap
    device: xc7z020_1   part=xc7z020   idcode=0x23727093

If `get_hw_targets` finds none but the server connected, it is the rules
above, not the network.

## The console

The same cable carries a UART. Interface 0 is JTAG and belongs to
`hw_server`; **interface 1 is the console** --- `/dev/ttyUSB1` where
`ttyUSB0` is the JTAG channel. The rules above leave both world read-write,
so `dialout` membership is not needed. If that is too permissive, join
`dialout` and tighten the rule to `0660` instead.

`ftdi_sio` claims both interfaces and creates both nodes. That is expected:
libusb detaches it from the JTAG interface once it has write permission.
