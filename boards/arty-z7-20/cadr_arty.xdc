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
# THE MACHINE'S 100 MHz IS NOT HERE, and that is not an omission. `cadr_arty.sv`
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

## The two tricolour LEDs, from Digilent's Arty-Z7-20-Master.xdc verbatim.
## Taken from the file rather than from memory: a wrong pin here is a light
## that does not come on, which reads as a design fault.
set_property -dict { PACKAGE_PIN N15   IOSTANDARD LVCMOS33 } [get_ports { led4_r }]
set_property -dict { PACKAGE_PIN G17   IOSTANDARD LVCMOS33 } [get_ports { led4_g }]
set_property -dict { PACKAGE_PIN L15   IOSTANDARD LVCMOS33 } [get_ports { led4_b }]
set_property -dict { PACKAGE_PIN M15   IOSTANDARD LVCMOS33 } [get_ports { led5_r }]
set_property -dict { PACKAGE_PIN L14   IOSTANDARD LVCMOS33 } [get_ports { led5_g }]
set_property -dict { PACKAGE_PIN G14   IOSTANDARD LVCMOS33 } [get_ports { led5_b }]

## Buttons. **BTN0 boots the machine** --- it is `-BOOT2`, the button MIT put
## on the CADR's light panel --- and **BTN3 resets the whole fabric**, at the
## far end of the row where it is hard to press by accident. BTN1 and BTN2 are
## pins the board has and this does not use, brought out so the port list
## matches the board rather than the design.
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

## MIT's debug cable on the two Pmod headers, JA carrying DBGOUT and JB
## carrying DBGIN. Pins from Digilent's Arty-Z7-20-Master.xdc verbatim, with
## that file's own schematic names and header pin numbers kept in the comments
## so that the mapping can be checked against the board rather than against
## memory. Both headers are four differential pairs there; used single-ended,
## as Digilent's own file uses them, they are eight signal pins each.
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
## have been clocked from the cable. It is on JA's own pins 7 and 8, where this
## design's inputs are, which is the one place a clock-capable pin would have
## been of any use if the arrangement had ever needed one.

## Pmod JA --- DBGOUT: this board as somebody else's debugger.
set_property -dict { PACKAGE_PIN Y18   IOSTANDARD LVCMOS33 } [get_ports { dbgout_stb }];      #IO_L17P_T2_34 Sch=JA1_P (Pin 1)
set_property -dict { PACKAGE_PIN Y19   IOSTANDARD LVCMOS33 } [get_ports { dbgout_d[2] }];     #IO_L17N_T2_34 Sch=JA1_N (Pin 2)
set_property -dict { PACKAGE_PIN Y16   IOSTANDARD LVCMOS33 } [get_ports { dbgout_d[1] }];     #IO_L7P_T1_34 Sch=JA2_P (Pin 3)
set_property -dict { PACKAGE_PIN Y17   IOSTANDARD LVCMOS33 } [get_ports { dbgout_d[0] }];     #IO_L7N_T1_34 Sch=JA2_N (Pin 4)
set_property -dict { PACKAGE_PIN U18   IOSTANDARD LVCMOS33 } [get_ports { dbgout_ret_stb }];  #IO_L12P_T1_MRCC_34 Sch=JA3_P (Pin 7)
set_property -dict { PACKAGE_PIN U19   IOSTANDARD LVCMOS33 } [get_ports { dbgout_ret_d[2] }]; #IO_L12N_T1_MRCC_34 Sch=JA3_N (Pin 8)
set_property -dict { PACKAGE_PIN W18   IOSTANDARD LVCMOS33 } [get_ports { dbgout_ret_d[1] }]; #IO_L22P_T3_34 Sch=JA4_P (Pin 9)
set_property -dict { PACKAGE_PIN W19   IOSTANDARD LVCMOS33 } [get_ports { dbgout_ret_d[0] }]; #IO_L22N_T3_34 Sch=JA4_N (Pin 10)

## Pmod JB --- DBGIN: this board as somebody else's debuggee.
set_property -dict { PACKAGE_PIN W14   IOSTANDARD LVCMOS33 } [get_ports { dbgin_stb }];       #IO_L8P_T1_34 Sch=JB1_P (Pin 1)
set_property -dict { PACKAGE_PIN Y14   IOSTANDARD LVCMOS33 } [get_ports { dbgin_d[2] }];      #IO_L8N_T1_34 Sch=JB1_N (Pin 2)
set_property -dict { PACKAGE_PIN T11   IOSTANDARD LVCMOS33 } [get_ports { dbgin_d[1] }];      #IO_L1P_T0_34 Sch=JB2_P (Pin 3)
set_property -dict { PACKAGE_PIN T10   IOSTANDARD LVCMOS33 } [get_ports { dbgin_d[0] }];      #IO_L1N_T0_34 Sch=JB2_N (Pin 4)
set_property -dict { PACKAGE_PIN V16   IOSTANDARD LVCMOS33 } [get_ports { dbgin_ret_stb }];   #IO_L18P_T2_34 Sch=JB3_P (Pin 7)
set_property -dict { PACKAGE_PIN W16   IOSTANDARD LVCMOS33 } [get_ports { dbgin_ret_d[2] }];  #IO_L18N_T2_34 Sch=JB3_N (Pin 8)
set_property -dict { PACKAGE_PIN V12   IOSTANDARD LVCMOS33 } [get_ports { dbgin_ret_d[1] }];  #IO_L4P_T0_34 Sch=JB4_P (Pin 9)
set_property -dict { PACKAGE_PIN W13   IOSTANDARD LVCMOS33 } [get_ports { dbgin_ret_d[0] }];  #IO_L4N_T0_34 Sch=JB4_N (Pin 10)

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

## The HDMI transmitter's four differential pairs. Pins from Digilent's
## Arty-Z7-20-Master.xdc verbatim, with that file's own schematic names and
## pin functions kept in the comments so that the mapping can be checked
## against the board rather than against memory.
##
## **CONSTRAINED ON EVERY BOARD, NOT ONLY AN `HDMI=1` ONE.** The four pairs
## are in `cadr_arty.sv`'s port list whatever `HDMI` says, because a port
## with no pin cannot be placed and a pin constrained `TMDS_33` cannot be
## driven single-ended. With the display not built the four buffers are fed
## from zero and the connector sits at a direct-current level, which a
## monitor reads as no signal. The display's own timing constraints are in
## `rtl/plumbing/xilinx7/cadr_hdmi.xdc`, which IS read only when it is built.
##
## `TMDS_33` on a high-range bank is Xilinx's emulation of TMDS out of a
## 3.3 V driver and the resistor network on the board. The XC7Z020 has no
## high-performance banks, so there is no alternative to choose.
##
## All eight pins are in bank 35 and, measured with `get_clock_regions`, all
## eight are in clock region X1Y2 --- which is what lets one `BUFIO` carry
## the serial clock to all four serialisers. A board that moves these pins
## has to check that again.
set_property -dict { PACKAGE_PIN L16   IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_clk_p }]; # IO_L11P_T1_SRCC_35      Sch=HDMI_TX_CLK_P
set_property -dict { PACKAGE_PIN L17   IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_clk_n }]; # IO_L11N_T1_SRCC_35      Sch=HDMI_TX_CLK_N
set_property -dict { PACKAGE_PIN K17   IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_p[0] }]; # IO_L12P_T1_MRCC_35     Sch=HDMI_TX_D0_P
set_property -dict { PACKAGE_PIN K18   IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_n[0] }]; # IO_L12N_T1_MRCC_35     Sch=HDMI_TX_D0_N
set_property -dict { PACKAGE_PIN K19   IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_p[1] }]; # IO_L10P_T1_AD11P_35    Sch=HDMI_TX_D1_P
set_property -dict { PACKAGE_PIN J19   IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_n[1] }]; # IO_L10N_T1_AD11N_35    Sch=HDMI_TX_D1_N
set_property -dict { PACKAGE_PIN J18   IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_p[2] }]; # IO_L14P_T2_AD4P_SRCC_35 Sch=HDMI_TX_D2_P
set_property -dict { PACKAGE_PIN H18   IOSTANDARD TMDS_33 } [get_ports { hdmi_tx_d_n[2] }]; # IO_L14N_T2_AD4N_SRCC_35 Sch=HDMI_TX_D2_N
