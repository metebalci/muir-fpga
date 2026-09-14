# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Package pins for the Arty Z7-20, and the board clock.
#
# Taken from Digilent's own master file --- github.com/Digilent/digilent-xdc,
# Arty-Z7-20-Master.xdc --- which lists every pin commented out, to be
# uncommented as used. These are the ones it uses, copied rather than included
# because the master file is 185 lines of things this design has no opinion
# about, and a constraint file that is mostly comments is a constraint file
# nobody reads.
#
# The pin assignments and the IO standard are Digilent's; the clock period is
# the board's own crystal. Only `sysclk` is a real timing constraint. The LEDs,
# the buttons and the switches are asynchronous to everything and are left
# unconstrained deliberately: a false path on a human pressing a button is
# noise, and an output timing constraint on an LED is a fiction about a pin
# nothing samples.
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
## on the CADR's light panel --- and **BTN1 resets the whole fabric**. Those
## two are the same buttons on every board in this repository, the Cora
## Z7-07S having two and no more. BTN2 and BTN3 are pins the board has and
## this does not use, brought out so the port list matches the board rather
## than the design.
set_property -dict { PACKAGE_PIN D19 IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]
set_property -dict { PACKAGE_PIN D20 IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]
set_property -dict { PACKAGE_PIN L20 IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]
set_property -dict { PACKAGE_PIN L19 IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]

## The two slide switches. **SW0 is the no-auto-boot switch**: with it on the
## machine comes out of reset with RUN clear, as a CADR is when the power comes
## on with nobody at it, and only the boot button starts it. It is read at the
## fabric's reset and at no other instant, so moving it under a running machine
## does nothing until the next reset. SW1 has no meaning in this design and is
## brought out so that the port list matches the board.
##
## Pins from Digilent's Arty-Z7-20-Master.xdc verbatim, with that file's own
## schematic names kept in the comments so that the mapping can be checked
## against the board rather than against memory.
set_property -dict { PACKAGE_PIN M20 IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]; #IO_L7N_T1_AD2N_35 Sch=SW0
set_property -dict { PACKAGE_PIN M19 IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]; #IO_L7P_T1_AD2P_35 Sch=SW1

## Nothing samples an LED and nothing meets setup against a fingertip, and a
## slide switch is no more of a timing constraint than a fingertip is.
set_false_path -to   [get_ports { led[*] }]
set_false_path -from [get_ports { btn[*] }]
set_false_path -from [get_ports { sw[*] }]

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

## MIT'S DEBUG CABLE ON ONE PMOD HEADER, JA. JB IS UNASSIGNED AND CARRIES
## NOTHING.
##
## A board is a debugger or a debuggee on this cable and never both at once, so
## a second connector bought only a chain of three machines --- and the register
## window already covers the case it looked like it bought, muir on this board's
## own Arm cores reaching the DBGIN page whatever the connector is doing.
## `docs/debug-cable.md` has the whole of it.
##
## Pins from Digilent's `Arty-Z7-20-Master.xdc` verbatim, with that file's own
## schematic names and header pin numbers kept in the comments so that the
## mapping can be checked against the board rather than against memory. That
## file is `github.com/Digilent/digilent-xdc` at commit
## `00a3404901f35aa9567b01ecb3f2c233b6efe9f4`, sha256
## `bfdb236bfbd3a575c86c25aaa2f8d155075a5b4b03ec46503ab2533a777bada5`. The
## header is four differential pairs there; used single-ended, as Digilent's own
## file uses them, it is eight signal pins.
##
## FOUR PINS EACH WAY, one strobe and three data.
## `rtl/plumbing/cadr_dbg_pmod.sv` has the argument for splitting them rather
## than sharing seven and turning them around; `rtl/plumbing/cadr_dbg_cable.sv`
## is the connector that puts both directions on this one header.
##
## THE LOW FOUR ARE THE DEBUGGER'S AND THE HIGH FOUR THE DEBUGGEE'S, at both
## ends. A straight Pmod ribbon joins pin one to pin one, so a cable from one
## board's JA to another's JA maps every pin to the same pin at the far end and
## the roles are what decide who drives which group.
##
## **THEY ARE BIDIRECTIONAL**, and they have to be: the role is not fixed at
## synthesis. `cadr_dbg_cable.sv` hands out a tri-state enable a pad, so the
## group this board does not own is high-impedance and the far end has it.
##
## AND THE EIGHTH WIRE IS A STROBE AND NOT A CLOCK. Nothing on either side is
## clocked by it. JA3_P/JA3_N is the only clock-capable pair on either header
## and it is in the debuggee's group here, which is of no use to anybody and is
## recorded so that nobody reads the choice of JA as being about it: JA is the
## connector because a board needs one and not because of that pair.

## Pmod JA --- the debug cable, both directions.
set_property -dict { PACKAGE_PIN Y18   IOSTANDARD LVCMOS33 } [get_ports { ja[0] }]; #IO_L17P_T2_34 Sch=JA1_P (Pin 1)
set_property -dict { PACKAGE_PIN Y19   IOSTANDARD LVCMOS33 } [get_ports { ja[1] }]; #IO_L17N_T2_34 Sch=JA1_N (Pin 2)
set_property -dict { PACKAGE_PIN Y16   IOSTANDARD LVCMOS33 } [get_ports { ja[2] }]; #IO_L7P_T1_34 Sch=JA2_P (Pin 3)
set_property -dict { PACKAGE_PIN Y17   IOSTANDARD LVCMOS33 } [get_ports { ja[3] }]; #IO_L7N_T1_34 Sch=JA2_N (Pin 4)
set_property -dict { PACKAGE_PIN U18   IOSTANDARD LVCMOS33 } [get_ports { ja[4] }]; #IO_L12P_T1_MRCC_34 Sch=JA3_P (Pin 7)
set_property -dict { PACKAGE_PIN U19   IOSTANDARD LVCMOS33 } [get_ports { ja[5] }]; #IO_L12N_T1_MRCC_34 Sch=JA3_N (Pin 8)
set_property -dict { PACKAGE_PIN W18   IOSTANDARD LVCMOS33 } [get_ports { ja[6] }]; #IO_L22P_T3_34 Sch=JA4_P (Pin 9)
set_property -dict { PACKAGE_PIN W19   IOSTANDARD LVCMOS33 } [get_ports { ja[7] }]; #IO_L22N_T3_34 Sch=JA4_N (Pin 10)

## AN UNPLUGGED CONNECTOR MUST READ ZERO AND NOT FLOAT. The carrier treats a
## strobe that never moves as a connector with nothing on it, so it never takes
## a frame, holds its levels at zero and says it is not live --- which is the
## idle cable, `-DEBUG IN REQ` up, and is what the SIP at DBGIN 0A22 does on
## MIT's own board. A floating input decides that question by noise. All eight
## carry a pull-down and not four of them, because either group can be the one
## this board is listening to.
set_property PULLTYPE PULLDOWN [get_ports { ja[*] }]

## AND THERE IS NO CLOCK ON THIS CONNECTOR, so there is no instant by which an
## edge on it must arrive and no setup window to meet. What makes the link safe
## is the beat: the far end holds each level for six ticks and the strobe is
## sampled through two flops, so the data has been standing for two ticks when
## it is taken and stands for three more. That is a property of the protocol
## and not of the route, and an input delay constraint here would be a fiction
## about a clock the board does not have. Saying it is a false path is the
## honest statement, and it is the same statement the buttons already carry.
set_false_path -from [get_ports { ja[*] }]
set_false_path -to   [get_ports { ja[*] }]

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
