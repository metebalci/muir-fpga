# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Package pins for the Arty Z7-20, and the board clock.
#
# Taken from Digilent's own master file --- github.com/Digilent/digilent-xdc,
# Arty-Z7-20-Master.xdc --- which lists every pin commented out, to be
# uncommented as used. These are the four it uses, copied rather than included
# because the master file is 185 lines of things this design has no opinion
# about, and a constraint file that is mostly comments is a constraint file
# nobody reads.
#
# The pin assignments and the IO standard are Digilent's; the clock period is
# the board's own crystal. Only `sysclk` is a real timing constraint. The LEDs
# and the button are asynchronous to everything and are left unconstrained
# deliberately: a false path on a human pressing a button is noise, and an
# output timing constraint on an LED is a fiction about a pin nothing samples.
#
# THE 200 MHz CLOCK IS NOT HERE, and that is not an omission. `cadr_arty.sv`
# makes it with an MMCM, and Vivado derives the generated clock from this one
# through the primitive without being told. Writing a second `create_clock`
# for the MMCM's output would override that derivation and silently unhook
# the two clocks from each other.

## Clock: 125 MHz, Sch=SYSCLK
set_property -dict { PACKAGE_PIN H16 IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -add -name sysclk -period 8.000 -waveform {0 4} [get_ports { sysclk }]

## LEDs
set_property -dict { PACKAGE_PIN R14 IOSTANDARD LVCMOS33 } [get_ports { led[0] }]
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports { led[1] }]
set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 } [get_ports { led[2] }]
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 } [get_ports { led[3] }]

## Buttons. BTN0 is reset; the rest are pins the board has and this does not
## use, brought out so the port list matches the board rather than the design.
set_property -dict { PACKAGE_PIN D19 IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN D20 IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]
set_property -dict { PACKAGE_PIN L20 IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]
set_property -dict { PACKAGE_PIN L19 IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]

## Nothing samples an LED and nothing meets setup against a fingertip.
set_false_path -to   [get_ports { led[*] }]
set_false_path -from [get_ports { btn[*] }]

## `witness` has no timing requirement, and saying so is not a convenience.
##
## It is a reduction of every one of `cadr_machine`'s outputs into one bit,
## and it exists to stop synthesis deleting the machine --- see the note in
## `cadr_arty.sv`. Its VALUE is meaningless: garbage in it lights an LED
## exactly as well as truth does, and nothing anywhere reads it. So there is
## no instant by which it must be correct, which is what a false path says.
##
## It is not a multicycle. A multicycle would claim the value is right if
## given longer, and it is not right at any length. And it is not left to the
## machine's own exception either: a seven-hundred-input tree riding a
## microcycle relaxation spends placement effort on a load-bearing nothing,
## and would become the worst path in the design the moment that relaxation
## is scoped to the machine --- which is what makes this worth writing down
## now rather than when it appears at the top of a timing report.
##
## Here rather than in `cadr_machine.xdc` because the cell does not exist out
## of context, and a constraint naming an absent object is the "no valid
## object" warning that file has already been through once.
set_false_path -to [get_cells -quiet witness_reg]
