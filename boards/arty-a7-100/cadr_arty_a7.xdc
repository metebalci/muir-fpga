# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Package pins for the Arty A7-100, and the board clock.
#
# Taken from Digilent's own master file --- `Arty-A7-100-Master.xdc`, which is
# in this directory byte for byte as published, with its provenance in
# `README.md`. That file lists every pin commented out, to be uncommented as
# used. These are the ones this design uses, copied rather than included
# because the master file is 210 lines of things this design has no opinion
# about, and a constraint file that is mostly comments is a constraint file
# nobody reads. Digilent's own schematic names are kept in the comments so
# that the mapping can be checked against the board rather than against
# memory: a wrong pin here is a light that does not come on, which reads as a
# design fault.
#
# THE MACHINE'S 100 MHz IS NOT DECLARED HERE, and that is not an omission.
# `cadr_arty_a7.sv` makes it with an MMCM, and Vivado derives the generated
# clock from this one through the primitive without being told. Writing a
# second `create_clock` for the MMCM's output would override that derivation
# and silently unhook the two clocks from each other --- and on this board the
# two frequencies are EQUAL, so the second declaration would look right and
# read right and still be wrong.
#
# **THE CLOCK PORT IS NAMED `sysclk` AND THE CLOCK IS NAMED `sysclk`**, which
# is the other board's name for a pin Digilent calls `CLK100MHZ`. The name is
# deliberate: `boards/arty-z7-20/cadr_probe.xdc` groups the JTAG readout's
# clock apart from `sysclk` and everything generated from it, and that file is
# read by this board's flow unchanged --- see `vivado/bitstream.tcl`. A board
# that renamed its clock would have to copy the file to rename it there too,
# and a copied constraint file is a constraint file that goes stale on one
# side.

## Clock: 100 MHz, Sch=gclk[100]
set_property -dict { PACKAGE_PIN E3    IOSTANDARD LVCMOS33 } [get_ports { sysclk }]; #IO_L12P_T1_MRCC_35
create_clock -add -name sysclk -period 10.000 -waveform {0 5} [get_ports { sysclk }]

## The four plain green LEDs. **DIGILENT'S `led[0]` IS THE BOARD'S LD4**: this
## board silkscreens its four tricolour LEDs LD0 to LD3 and its four green ones
## LD4 to LD7, which is the opposite way round from the Arty Z7-20. The port
## names here are Digilent's, so that a pin can be checked against the master
## file by eye; `cadr_arty_a7.sv`'s header has the table that says which of
## this project's six lamps each one carries.
##
## led[0] MACHRUN, led[1] the fabric's clock, led[2] microcycles, led[3] the disk.
set_property -dict { PACKAGE_PIN H5    IOSTANDARD LVCMOS33 } [get_ports { led[0] }]; #IO_L24N_T3_35 Sch=led[4]
set_property -dict { PACKAGE_PIN J5    IOSTANDARD LVCMOS33 } [get_ports { led[1] }]; #IO_25_35 Sch=led[5]
set_property -dict { PACKAGE_PIN T9    IOSTANDARD LVCMOS33 } [get_ports { led[2] }]; #IO_L24P_T3_A01_D17_14 Sch=led[6]
set_property -dict { PACKAGE_PIN T10   IOSTANDARD LVCMOS33 } [get_ports { led[3] }]; #IO_L24N_T3_A00_D16_14 Sch=led[7]

## The four tricolour LEDs, the board's LD0 to LD3. LD0 is this project's LD4
## --- trouble, red and nothing else --- and LD1 is its LD5, the boot PROM in
## blue. LD2 and LD3 have no meaning in the six-lamp assignment and are driven
## dark; they are constrained anyway, because a port with no pin cannot be
## placed and the port list is meant to match the board.
set_property -dict { PACKAGE_PIN G6    IOSTANDARD LVCMOS33 } [get_ports { led0_r }]; #IO_L19P_T3_35 Sch=led0_r
set_property -dict { PACKAGE_PIN F6    IOSTANDARD LVCMOS33 } [get_ports { led0_g }]; #IO_L19N_T3_VREF_35 Sch=led0_g
set_property -dict { PACKAGE_PIN E1    IOSTANDARD LVCMOS33 } [get_ports { led0_b }]; #IO_L18N_T2_35 Sch=led0_b
set_property -dict { PACKAGE_PIN G3    IOSTANDARD LVCMOS33 } [get_ports { led1_r }]; #IO_L20N_T3_35 Sch=led1_r
set_property -dict { PACKAGE_PIN J4    IOSTANDARD LVCMOS33 } [get_ports { led1_g }]; #IO_L21P_T3_DQS_35 Sch=led1_g
set_property -dict { PACKAGE_PIN G4    IOSTANDARD LVCMOS33 } [get_ports { led1_b }]; #IO_L20P_T3_35 Sch=led1_b
set_property -dict { PACKAGE_PIN J3    IOSTANDARD LVCMOS33 } [get_ports { led2_r }]; #IO_L22P_T3_35 Sch=led2_r
set_property -dict { PACKAGE_PIN J2    IOSTANDARD LVCMOS33 } [get_ports { led2_g }]; #IO_L22N_T3_35 Sch=led2_g
set_property -dict { PACKAGE_PIN H4    IOSTANDARD LVCMOS33 } [get_ports { led2_b }]; #IO_L21N_T3_DQS_35 Sch=led2_b
set_property -dict { PACKAGE_PIN K1    IOSTANDARD LVCMOS33 } [get_ports { led3_r }]; #IO_L23N_T3_35 Sch=led3_r
set_property -dict { PACKAGE_PIN H6    IOSTANDARD LVCMOS33 } [get_ports { led3_g }]; #IO_L24P_T3_35 Sch=led3_g
set_property -dict { PACKAGE_PIN K2    IOSTANDARD LVCMOS33 } [get_ports { led3_b }]; #IO_L23P_T3_35 Sch=led3_b

## Buttons. **BTN0 boots the machine** --- it is `-BOOT2`, the button MIT put
## on the CADR's light panel --- and **BTN1 resets the whole fabric**. Those
## two are the same buttons on every board in this repository, the Cora
## Z7-07S having two and no more. BTN2 and BTN3 are pins the board has and
## this design does not use, brought out so the port list matches the board
## rather than the design.
set_property -dict { PACKAGE_PIN D9    IOSTANDARD LVCMOS33 } [get_ports { btn[0] }]; #IO_L6N_T0_VREF_16 Sch=btn[0]
set_property -dict { PACKAGE_PIN C9    IOSTANDARD LVCMOS33 } [get_ports { btn[1] }]; #IO_L11P_T1_SRCC_16 Sch=btn[1]
set_property -dict { PACKAGE_PIN B9    IOSTANDARD LVCMOS33 } [get_ports { btn[2] }]; #IO_L11N_T1_SRCC_16 Sch=btn[2]
set_property -dict { PACKAGE_PIN B8    IOSTANDARD LVCMOS33 } [get_ports { btn[3] }]; #IO_L12P_T1_MRCC_16 Sch=btn[3]

## The four slide switches. **SW0 is reserved for the no-auto-boot hold** ---
## the machine held at the boot trap at power-on so that somebody at the board
## presses BTN0 to start it. `cadr_machine` has no input for that at this
## commit, so nothing reads any of the four; they are constrained so that the
## port list matches the board and so that the day the input lands, no pin has
## to be found.
set_property -dict { PACKAGE_PIN A8    IOSTANDARD LVCMOS33 } [get_ports { sw[0] }]; #IO_L12N_T1_MRCC_16 Sch=sw[0]
set_property -dict { PACKAGE_PIN C11   IOSTANDARD LVCMOS33 } [get_ports { sw[1] }]; #IO_L13P_T2_MRCC_16 Sch=sw[1]
set_property -dict { PACKAGE_PIN C10   IOSTANDARD LVCMOS33 } [get_ports { sw[2] }]; #IO_L13N_T2_MRCC_16 Sch=sw[2]
set_property -dict { PACKAGE_PIN A10   IOSTANDARD LVCMOS33 } [get_ports { sw[3] }]; #IO_L14P_T2_SRCC_16 Sch=sw[3]

## Nothing samples an LED and nothing meets setup against a fingertip. The
## switches are on the same footing: a slide switch is a level somebody moves
## once, and an input delay constraint on one would be a fiction about a clock
## the board does not have.
set_false_path -to   [get_ports { led[*] }]
set_false_path -to   [get_ports { led0_* led1_* led2_* led3_* }]
set_false_path -from [get_ports { btn[*] }]
set_false_path -from [get_ports { sw[*] }]

## -------------------------------------------------- the board's USB-UART
##
## **THE NAMES ARE FROM THE HOST's POINT OF VIEW AND THEY READ BACKWARDS.**
## `uart_rxd_out` is what the FPGA DRIVES and the USB bridge receives;
## `uart_txd_in` is what the bridge drives and the FPGA receives. Digilent's
## master file names them that way and the names are kept so that a pin can be
## checked against the board by eye.
##
## **THE ARTY Z7-20 CONSTRAINS NO UART PINS AT ALL**, which is worth knowing
## before looking for these there: on that board the serial hardware belongs to
## the processing system and the fabric cannot reach it. Here the line is the
## fabric's, and it is the soft processing system's console --- not the CADR's
## own serial port, which is the 2651 on the I/O board and a different thing
## entirely.
##
## Pins from Digilent's `Arty-A7-100-Master.xdc`, lines 83 and 84.
set_property -dict { PACKAGE_PIN D10   IOSTANDARD LVCMOS33 } [get_ports { uart_rxd_out }]; #IO_L19N_T3_VREF_16 Sch=uart_rxd_out
set_property -dict { PACKAGE_PIN A9    IOSTANDARD LVCMOS33 } [get_ports { uart_txd_in }];  #IO_L14N_T2_SRCC_16 Sch=uart_txd_in

## **BOTH FALSE-PATHED, AND A BAUD RATE IS WHY.** At 115,200 baud one bit
## lasts 868 ticks of this board's clock, so neither end of this line has a
## setup relationship with anything: the transmitter holds a level for the
## whole of a bit time, and the receiver synchronises the pin through two
## stages before it looks at it and then samples in the middle of a bit. A
## timing constraint here would be a claim about a wire nothing is racing on.
set_false_path -to   [get_ports { uart_rxd_out }]
set_false_path -from [get_ports { uart_txd_in }]

## `witness` has no timing requirement, and saying so is not a convenience.
##
## It is a reduction of every one of `cadr_machine`'s outputs into one bit, and
## it exists to stop synthesis deleting the machine --- see the note in
## `cadr_arty_a7.sv`. Its VALUE is meaningless: garbage in it is as good as
## truth, and nothing anywhere reads it. So there is no instant by which it
## must be correct, which is what a false path says.
##
## It is not a multicycle. A multicycle would claim the value is right if given
## longer, and it is not right at any length. And it is not left to the
## machine's own exception either: a seven-hundred-input tree riding a
## microcycle relaxation spends placement effort on a load-bearing nothing, and
## would become the worst path in the design the moment that relaxation is
## scoped to the machine --- which it is, in this board's flow.
##
## Here rather than in `cadr_machine.xdc` because the cell does not exist out
## of context, and a constraint naming an absent object is the "no valid
## object" warning that file has already been through once.
set_false_path -to [get_cells -quiet witness_reg]

## ----------------------------------------------------------- configuration
##
## **THESE TWO ARE REQUIRED ON AN ARTIX AND ARE NOT ON A ZYNQ**, which is why
## nothing like them appears in `boards/arty-z7-20/cadr_arty.xdc`. There the
## fabric is configured by the processing system and the configuration bank's
## voltage is the PS's business. Here the part configures itself from JTAG or
## from its own QSPI flash, and Vivado refuses to reason about the
## configuration bank unless it is told what drives it: without `CFGBVS`,
## `write_bitstream` reports `CRITICAL WARNING: [DRC CFGBVS-1]` and carries on
## --- a warning in a log nobody reads, and a bitstream whose configuration
## pins may be driven at the wrong level.
##
## On this board bank 14, which holds the configuration pins, is at 3.3 V, so
## `CFGBVS VCCO` and `CONFIG_VOLTAGE 3.3` are the board's own values and not a
## default. They are Digilent's for every Arty A7 design; **Digilent's master
## file does not carry them**, which is worth knowing before looking for them
## there.
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

## **AND THIS ONE IS FOR A BOOT NOBODY HAS TRIED.** The part can configure
## itself from the 16 MB QSPI flash at power-on, which is what a board with no
## processing system and no card has instead of a boot sequence, and a
## bitstream meant for that flash has to say how wide the flash reads are. Four
## bits is what the board is wired for --- `qspi_dq[3:0]`, K17, K18, L14, M14
## in Digilent's file. `vivado/qspi.tcl` is the recipe that writes it and
## **nothing has ever run it**, so this property is unexercised: it costs a
## JTAG-programmed board nothing and it is what the flash recipe needs.
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
