# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Package pins for the Cora Z7-07S, and the board clock.
#
# Taken from Digilent's own master file in this directory,
# `Cora-Z7-07S-Master.xdc`, which lists every pin commented out to be
# uncommented as used. These are the pins this design uses, copied rather than
# included because the master file is 300 lines of things this design has no
# opinion about, and a constraint file that is mostly comments is a constraint
# file nobody reads. That file's own provenance is in this directory's
# `README.md`.
#
# The pin assignments and the IO standard are Digilent's; the clock period is
# the board's own crystal. Only `sysclk` is a real timing constraint. The LEDs
# and the buttons are asynchronous to everything and are left unconstrained
# deliberately: a false path on a human pressing a button is noise, and an
# output timing constraint on an LED is a fiction about a pin nothing samples.
#
# THE MACHINE'S 100 MHz IS NOT HERE, and that is not an omission. `cadr_cora.sv`
# makes it with an MMCM, and Vivado derives the generated clock from this one
# through the primitive without being told. Writing a second `create_clock`
# for the MMCM's output would override that derivation and silently unhook
# the two clocks from each other.
#
# **MOST OF THIS FILE IS THE SAME PINS THE ARTY Z7-20 USES, AND THAT IS A
# MEASUREMENT RATHER THAN AN ASSUMPTION.** Both boards are the same package,
# `clg400`, and Digilent laid the two out alike. Compared pin by pin against
# `boards/arty-z7-20/cadr_arty.xdc` and against both master files: the system
# clock, the six RGB LED pins and all sixteen Pmod pins are identical, and the
# two buttons are the Arty's first two with their indices exchanged --- the
# Arty's `btn[0]` is D19 and this board's is D20. **So the one pin a reader
# would get right from memory is the one that is wrong.** Taken from the file
# and not from memory, as the rule says.

## Clock: 125 MHz, Sch=sysclk. The same pin and the same frequency as the
## Arty Z7-20's, which is why `cadr_cora.sv`'s MMCM arithmetic is that file's
## unchanged and the tick is still 10 ns.
set_property -dict { PACKAGE_PIN H16 IOSTANDARD LVCMOS33 } [get_ports { sysclk }]
create_clock -add -name sysclk -period 8.000 -waveform {0 4} [get_ports { sysclk }]

## The two RGB LEDs, and the whole of this board's light panel. There are no
## plain LEDs on a Cora Z7-07S. Digilent's file names them `led0_*` and
## `led1_*` and those are the port names here, so the mapping can be checked
## against that file by eye.
set_property -dict { PACKAGE_PIN N15   IOSTANDARD LVCMOS33 } [get_ports { led0_r }]; #IO_L21P_T3_DQS_AD14P_35 Sch=led0_r
set_property -dict { PACKAGE_PIN G17   IOSTANDARD LVCMOS33 } [get_ports { led0_g }]; #IO_L16P_T2_35 Sch=led0_g
set_property -dict { PACKAGE_PIN L15   IOSTANDARD LVCMOS33 } [get_ports { led0_b }]; #IO_L22N_T3_AD7N_35 Sch=led0_b
set_property -dict { PACKAGE_PIN M15   IOSTANDARD LVCMOS33 } [get_ports { led1_r }]; #IO_L23N_T3_35 Sch=led1_r
set_property -dict { PACKAGE_PIN L14   IOSTANDARD LVCMOS33 } [get_ports { led1_g }]; #IO_L22P_T3_AD7P_35 Sch=led1_g
set_property -dict { PACKAGE_PIN G14   IOSTANDARD LVCMOS33 } [get_ports { led1_b }]; #IO_0_35 Sch=led1_b

## Buttons. **BTN0 boots the machine** --- it is `-BOOT2`, the button MIT put
## on the CADR's light panel --- and **BTN1 resets the whole fabric**. There
## are only two, so the reset sits next to the boot button rather than at the
## far end of a row as it does on the Arty Z7-20; `cadr_cora.sv` says at the
## debounce what that costs.
set_property -dict { PACKAGE_PIN D20 IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]; #IO_L4N_T0_35 Sch=btn[0]
set_property -dict { PACKAGE_PIN D19 IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]; #IO_L4P_T0_35 Sch=btn[1]

## Nothing samples an LED and nothing meets setup against a fingertip.
set_false_path -to   [get_ports { led0_* led1_* }]
set_false_path -from [get_ports { btn[*] }]

## `witness` has no timing requirement, and saying so is not a convenience.
##
## It is a reduction of every one of `cadr_machine`'s outputs into one bit,
## and it exists to stop synthesis deleting the machine --- see the note in
## `cadr_cora.sv`. Its VALUE is meaningless: garbage in it lights nothing
## differently from truth, and nothing anywhere reads it. So there is no
## instant by which it must be correct, which is what a false path says.
##
## It is not a multicycle. A multicycle would claim the value is right if
## given longer, and it is not right at any length. And it is not left to the
## machine's own exception either: a seven-hundred-input tree riding a
## microcycle relaxation spends placement effort on a load-bearing nothing,
## and would become the worst path in the design the moment that relaxation
## is scoped to the machine.
##
## Here rather than in `cadr_machine.xdc` because the cell does not exist out
## of context, and a constraint naming an absent object is the "no valid
## object" warning that file has already been through once.
set_false_path -to [get_cells -quiet witness_reg]

## MIT's debug cable on the two Pmod headers, JA carrying DBGOUT and JB
## carrying DBGIN. Pins from `Cora-Z7-07S-Master.xdc` verbatim, with that
## file's own schematic names and header pin numbers kept in the comments so
## that the mapping can be checked against the board rather than against
## memory. Both headers are four differential pairs there; used single-ended,
## as Digilent's own file uses them, they are eight signal pins each.
##
## **ALL SIXTEEN ARE THE SAME PINS THE ARTY Z7-20 USES**, compared pin by pin
## against both master files, so a cable joining one board's JA to the other's
## JB needs nothing said about it.
##
## FOUR PINS EACH WAY, one strobe and three data. A cable joins one board's
## JA to another's JB, so its eight wires carry both directions:
## `rtl/plumbing/cadr_dbg_pmod.sv` has the argument for splitting them rather
## than sharing seven and turning them around.
##
## THE PIN ROLES ARE MIRRORED BETWEEN THE TWO HEADERS, so that a straight Pmod
## cable maps pin one to pin one. Header pins 1 to 4 carry the request
## direction and 7 to 10 the answer, on both connectors; what differs is which
## end drives them. That also makes a cable from this board's JA to its own JB
## a loopback of the whole carrier, which is the cheapest way to exercise it on
## silicon with one board.
##
## AND THE EIGHTH WIRE IS A STROBE AND NOT A CLOCK. Nothing on either side is
## clocked by it, which is just as well: JA3_P/JA3_N is the only clock-capable
## pair on either header and JB has none at all, so a receiver on JB could not
## have been clocked from the cable.

## Pmod JA --- DBGOUT: this board as somebody else's debugger.
set_property -dict { PACKAGE_PIN Y18   IOSTANDARD LVCMOS33 } [get_ports { dbgout_stb }];      #IO_L17P_T2_34 Sch=ja_p[1] (Pin 1)
set_property -dict { PACKAGE_PIN Y19   IOSTANDARD LVCMOS33 } [get_ports { dbgout_d[2] }];     #IO_L17N_T2_34 Sch=ja_n[1] (Pin 2)
set_property -dict { PACKAGE_PIN Y16   IOSTANDARD LVCMOS33 } [get_ports { dbgout_d[1] }];     #IO_L7P_T1_34 Sch=ja_p[2] (Pin 3)
set_property -dict { PACKAGE_PIN Y17   IOSTANDARD LVCMOS33 } [get_ports { dbgout_d[0] }];     #IO_L7N_T1_34 Sch=ja_n[2] (Pin 4)
set_property -dict { PACKAGE_PIN U18   IOSTANDARD LVCMOS33 } [get_ports { dbgout_ret_stb }];  #IO_L12P_T1_MRCC_34 Sch=ja_p[3] (Pin 7)
set_property -dict { PACKAGE_PIN U19   IOSTANDARD LVCMOS33 } [get_ports { dbgout_ret_d[2] }]; #IO_L12N_T1_MRCC_34 Sch=ja_n[3] (Pin 8)
set_property -dict { PACKAGE_PIN W18   IOSTANDARD LVCMOS33 } [get_ports { dbgout_ret_d[1] }]; #IO_L22P_T3_34 Sch=ja_p[4] (Pin 9)
set_property -dict { PACKAGE_PIN W19   IOSTANDARD LVCMOS33 } [get_ports { dbgout_ret_d[0] }]; #IO_L22N_T3_34 Sch=ja_n[4] (Pin 10)

## Pmod JB --- DBGIN: this board as somebody else's debuggee.
set_property -dict { PACKAGE_PIN W14   IOSTANDARD LVCMOS33 } [get_ports { dbgin_stb }];       #IO_L8P_T1_34 Sch=jb_p[1] (Pin 1)
set_property -dict { PACKAGE_PIN Y14   IOSTANDARD LVCMOS33 } [get_ports { dbgin_d[2] }];      #IO_L8N_T1_34 Sch=jb_n[1] (Pin 2)
set_property -dict { PACKAGE_PIN T11   IOSTANDARD LVCMOS33 } [get_ports { dbgin_d[1] }];      #IO_L1P_T0_34 Sch=jb_p[2] (Pin 3)
set_property -dict { PACKAGE_PIN T10   IOSTANDARD LVCMOS33 } [get_ports { dbgin_d[0] }];      #IO_L1N_T0_34 Sch=jb_n[2] (Pin 4)
set_property -dict { PACKAGE_PIN V16   IOSTANDARD LVCMOS33 } [get_ports { dbgin_ret_stb }];   #IO_L18P_T2_34 Sch=jb_p[3] (Pin 7)
set_property -dict { PACKAGE_PIN W16   IOSTANDARD LVCMOS33 } [get_ports { dbgin_ret_d[2] }];  #IO_L18N_T2_34 Sch=jb_n[3] (Pin 8)
set_property -dict { PACKAGE_PIN V12   IOSTANDARD LVCMOS33 } [get_ports { dbgin_ret_d[1] }];  #IO_L4P_T0_34 Sch=jb_p[4] (Pin 9)
set_property -dict { PACKAGE_PIN W13   IOSTANDARD LVCMOS33 } [get_ports { dbgin_ret_d[0] }];  #IO_L4N_T0_34 Sch=jb_n[4] (Pin 10)

## AN UNPLUGGED CONNECTOR MUST READ ZERO AND NOT FLOAT. The carrier treats a
## strobe that never moves as a connector with nothing on it, so it never takes
## a frame, holds its levels at zero and says it is not live --- which is the
## idle cable, `-DEBUG IN REQ` up, and is what the SIP at DBGIN 0A22 does on
## MIT's own board. A floating input decides that question by noise, so the
## four inputs of each connector carry a pull-down.
set_property PULLTYPE PULLDOWN [get_ports { dbgout_ret_stb dbgout_ret_d[*] }]
set_property PULLTYPE PULLDOWN [get_ports { dbgin_stb dbgin_d[*] }]

## AND THERE IS NO CLOCK ON THIS CONNECTOR, so there is no instant by which an
## edge on it must arrive and no setup window to meet. What makes the link safe
## is the beat: the far end holds each level for six ticks and the strobe is
## sampled through two flops, so the data has been standing for two ticks when
## it is taken and stands for three more. That is a property of the protocol
## and not of the route, and an input delay constraint here would be a fiction
## about a clock the board does not have. Saying it is a false path is the
## honest statement, and it is the same statement the buttons already carry.
set_false_path -from [get_ports { dbgout_ret_stb dbgout_ret_d[*] }]
set_false_path -from [get_ports { dbgin_stb dbgin_d[*] }]
set_false_path -to   [get_ports { dbgout_stb dbgout_d[*] }]
set_false_path -to   [get_ports { dbgin_ret_stb dbgin_ret_d[*] }]
