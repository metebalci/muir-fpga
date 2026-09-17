# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's fabric pins, transcribed from Terasic's user manual.
#
# Which package pin a trace on the board reaches is a fact the manual
# publishes, and this file is that fact written down in this project's own
# words and names. The source is the rev B user manual, version 1.1,
# `DE25-Nano_User_manual_revB.pdf`, whose size and sha256 are in this
# directory's README. Page numbers below are the ones printed on its pages.
# Terasic's revision page gives the two revisions' difference as the speed of
# the LPDDR4, so these pins are taken to stand for a rev A board too. No rev A
# manual was read to confirm it.
# Nothing here is taken from the resource package's Quartus files, which are
# read only by `tools/de25_pins_check.py` as a second witness.
#
# **What is here.** The three 50 MHz clock inputs, the four slide switches,
# the two push buttons, the eight LEDs, both 2x20 GPIO headers, and the
# fabric's connections to the ADV7513 HDMI transmitter, audio included. The
# LPDDR4 banks, the SDRAM, the MIPI connector, the ADC and the processor's own
# pins are left out, because nothing here uses them yet. The fabric UART's two
# pins are left out too, because the manual does not list them.
#
# **How to use it.** Source it from a Quartus Tcl flow with a project open, and
# then export the assignments. Each `de25_pin` line makes two assignments, the
# pin's location and its I/O standard. A top level declares only the ports it
# uses. Quartus ignores an assignment to a port the design does not have, and
# warns about each one.
#
# **The names.** Every port is lowercase. The second word on each line is the
# manual's own name for the signal, kept so that each line can be looked up in
# the manual's table and matched against a second source. The groups below
# say how the two names relate.
#
# **The I/O standards.** The manual prints them in its own words, as "1.1V",
# "3.3V", "3.3V LVCMOS" and "3.3-V LVCMOS". The Quartus names are "1.1-V" and
# "3.3-V LVCMOS". Each group says what the manual prints. One line departs
# from the manual, the HDMI pixel clock, and its group says why.

# One pin: the port, the manual's name, the package pin and the Quartus I/O
# standard.
proc de25_pin {port manual pin standard} {
    set_location_assignment $pin -to $port
    set_instance_assignment -name IO_STANDARD $standard -to $port
}

# ------------------------------------------------------------------ clocks
#
# Table 3-6, "Pin Assignment of Clock Inputs", page 18. `clock50_N` is the
# manual's `CLOCKN_50`. The first is on a 1.1 V bank, and the manual prints
# "1.1V" for it; the other two are on 3.3 V banks, and it prints
# "3.3-V LVCMOS".
de25_pin {clock50_0} {CLOCK0_50} PIN_DJ35 "1.1-V"
de25_pin {clock50_1} {CLOCK1_50} PIN_V16 "3.3-V LVCMOS"
de25_pin {clock50_2} {CLOCK2_50} PIN_BF23 "3.3-V LVCMOS"

# -------------------------------------------------- switches, buttons, LEDs
#
# Section 3.7.1. The manual prints "1.1V" for the switches and the LEDs and
# "3.3-V LVCMOS" for the buttons.
#
# Table 3-8, "Pin Assignments of Slide Switches", pages 21 and 22. `sw[N]` is
# the manual's `SW[N]`. A switch reads low in its down position, toward the
# board's edge.
de25_pin {sw[0]} {SW[0]} PIN_DK24 "1.1-V"
de25_pin {sw[1]} {SW[1]} PIN_DD24 "1.1-V"
de25_pin {sw[2]} {SW[2]} PIN_DD27 "1.1-V"
de25_pin {sw[3]} {SW[3]} PIN_DF27 "1.1-V"

# Table 3-9, "Pin Assignments of Push-buttons", page 22. `btn[N]` is the
# manual's `KEY[N]`, the name the Zynq boards' top levels use for their
# buttons. The buttons are debounced on the board and read low while pressed.
de25_pin {btn[0]} {KEY[0]} PIN_C8 "3.3-V LVCMOS"
de25_pin {btn[1]} {KEY[1]} PIN_C11 "3.3-V LVCMOS"

# Table 3-10, "Pin Assignments of LEDs", page 22. `led[N]` is the manual's
# `LEDR[N]`. An LED is lit when its pin is driven low.
de25_pin {led[0]} {LEDR[0]} PIN_DF35 "1.1-V"
de25_pin {led[1]} {LEDR[1]} PIN_DJ32 "1.1-V"
de25_pin {led[2]} {LEDR[2]} PIN_DN22 "1.1-V"
de25_pin {led[3]} {LEDR[3]} PIN_DP23 "1.1-V"
de25_pin {led[4]} {LEDR[4]} PIN_DN25 "1.1-V"
de25_pin {led[5]} {LEDR[5]} PIN_DP25 "1.1-V"
de25_pin {led[6]} {LEDR[6]} PIN_DJ27 "1.1-V"
de25_pin {led[7]} {LEDR[7]} PIN_DP30 "1.1-V"

# ------------------------------------------------------ GPIO headers
#
# Table 3-12, "Pin Assignment of Expansion Headers", pages 23 to 26, and
# Figure 3-18 on page 23 for which header pin each signal is on. The manual
# prints "3.3V" for every one of them.
#
# The ports are named by header pin rather than by signal index, so that
# choosing pins for a cable is a matter of naming header pins. `jp1_pinP` is
# pin P of JP1, which the manual calls GPIO 0, and `jp2_pinP` is pin P of JP2,
# GPIO 1. The manual numbers the 36 signals of each header `GPIO_0[N]` and
# `GPIO_1[N]` in header pin order, skipping the four supply pins:
#
#     pins  1 to 10  are N = P - 1
#     pins 13 to 28  are N = P - 3
#     pins 31 to 40  are N = P - 5
#
# The ports are single wires and not a bus indexed by header pin. A bus would
# have four bits with no package pin behind them. Quartus puts a bit like that
# on a pin of its own choosing, at a default standard, and the fit still
# succeeds with only a critical warning.
#
# The four supply pins have no fabric pin and get no assignment. Figure 3-18
# gives them, and they are the same on both headers:
#
#     pin 11   5 V
#     pin 12   ground
#     pin 29   3.3 V
#     pin 30   ground
set de25_header_supply_pins {11 12 29 30}

de25_pin {jp1_pin1} {GPIO_0[0]} PIN_H16 "3.3-V LVCMOS"
de25_pin {jp1_pin2} {GPIO_0[1]} PIN_Y1 "3.3-V LVCMOS"
de25_pin {jp1_pin3} {GPIO_0[2]} PIN_C2 "3.3-V LVCMOS"
de25_pin {jp1_pin4} {GPIO_0[3]} PIN_P1 "3.3-V LVCMOS"
de25_pin {jp1_pin5} {GPIO_0[4]} PIN_Y2 "3.3-V LVCMOS"
de25_pin {jp1_pin6} {GPIO_0[5]} PIN_U2 "3.3-V LVCMOS"
de25_pin {jp1_pin7} {GPIO_0[6]} PIN_L1 "3.3-V LVCMOS"
de25_pin {jp1_pin8} {GPIO_0[7]} PIN_F2 "3.3-V LVCMOS"
de25_pin {jp1_pin9} {GPIO_0[8]} PIN_P2 "3.3-V LVCMOS"
de25_pin {jp1_pin10} {GPIO_0[9]} PIN_B3 "3.3-V LVCMOS"
de25_pin {jp1_pin13} {GPIO_0[10]} PIN_H4 "3.3-V LVCMOS"
de25_pin {jp1_pin14} {GPIO_0[11]} PIN_H14 "3.3-V LVCMOS"
de25_pin {jp1_pin15} {GPIO_0[12]} PIN_C6 "3.3-V LVCMOS"
de25_pin {jp1_pin16} {GPIO_0[13]} PIN_H6 "3.3-V LVCMOS"
de25_pin {jp1_pin17} {GPIO_0[14]} PIN_B5 "3.3-V LVCMOS"
de25_pin {jp1_pin18} {GPIO_0[15]} PIN_H11 "3.3-V LVCMOS"
de25_pin {jp1_pin19} {GPIO_0[16]} PIN_C14 "3.3-V LVCMOS"
de25_pin {jp1_pin20} {GPIO_0[17]} PIN_B10 "3.3-V LVCMOS"
de25_pin {jp1_pin21} {GPIO_0[18]} PIN_A15 "3.3-V LVCMOS"
de25_pin {jp1_pin22} {GPIO_0[19]} PIN_A10 "3.3-V LVCMOS"
de25_pin {jp1_pin23} {GPIO_0[20]} PIN_B17 "3.3-V LVCMOS"
de25_pin {jp1_pin24} {GPIO_0[21]} PIN_B15 "3.3-V LVCMOS"
de25_pin {jp1_pin25} {GPIO_0[22]} PIN_AH16 "3.3-V LVCMOS"
de25_pin {jp1_pin26} {GPIO_0[23]} PIN_A13 "3.3-V LVCMOS"
de25_pin {jp1_pin27} {GPIO_0[24]} PIN_AE19 "3.3-V LVCMOS"
de25_pin {jp1_pin28} {GPIO_0[25]} PIN_C19 "3.3-V LVCMOS"
de25_pin {jp1_pin31} {GPIO_0[26]} PIN_H19 "3.3-V LVCMOS"
de25_pin {jp1_pin32} {GPIO_0[27]} PIN_AH19 "3.3-V LVCMOS"
de25_pin {jp1_pin33} {GPIO_0[28]} PIN_R19 "3.3-V LVCMOS"
de25_pin {jp1_pin34} {GPIO_0[29]} PIN_R14 "3.3-V LVCMOS"
de25_pin {jp1_pin35} {GPIO_0[30]} PIN_V19 "3.3-V LVCMOS"
de25_pin {jp1_pin36} {GPIO_0[31]} PIN_V14 "3.3-V LVCMOS"
de25_pin {jp1_pin37} {GPIO_0[32]} PIN_AG31 "3.3-V LVCMOS"
de25_pin {jp1_pin38} {GPIO_0[33]} PIN_AL31 "3.3-V LVCMOS"
de25_pin {jp1_pin39} {GPIO_0[34]} PIN_AL37 "3.3-V LVCMOS"
de25_pin {jp1_pin40} {GPIO_0[35]} PIN_AL34 "3.3-V LVCMOS"

de25_pin {jp2_pin1} {GPIO_1[0]} PIN_BV14 "3.3-V LVCMOS"
de25_pin {jp2_pin2} {GPIO_1[1]} PIN_CG26 "3.3-V LVCMOS"
de25_pin {jp2_pin3} {GPIO_1[2]} PIN_DM2 "3.3-V LVCMOS"
de25_pin {jp2_pin4} {GPIO_1[3]} PIN_CD23 "3.3-V LVCMOS"
de25_pin {jp2_pin5} {GPIO_1[4]} PIN_CG23 "3.3-V LVCMOS"
de25_pin {jp2_pin6} {GPIO_1[5]} PIN_CE14 "3.3-V LVCMOS"
de25_pin {jp2_pin7} {GPIO_1[6]} PIN_CA23 "3.3-V LVCMOS"
de25_pin {jp2_pin8} {GPIO_1[7]} PIN_CH16 "3.3-V LVCMOS"
de25_pin {jp2_pin9} {GPIO_1[8]} PIN_CV16 "3.3-V LVCMOS"
de25_pin {jp2_pin10} {GPIO_1[9]} PIN_CH14 "3.3-V LVCMOS"
de25_pin {jp2_pin13} {GPIO_1[10]} PIN_CR6 "3.3-V LVCMOS"
de25_pin {jp2_pin14} {GPIO_1[11]} PIN_CH11 "3.3-V LVCMOS"
de25_pin {jp2_pin15} {GPIO_1[12]} PIN_CV6 "3.3-V LVCMOS"
de25_pin {jp2_pin16} {GPIO_1[13]} PIN_CR14 "3.3-V LVCMOS"
de25_pin {jp2_pin17} {GPIO_1[14]} PIN_CR19 "3.3-V LVCMOS"
de25_pin {jp2_pin18} {GPIO_1[15]} PIN_CR11 "3.3-V LVCMOS"
de25_pin {jp2_pin19} {GPIO_1[16]} PIN_CV19 "3.3-V LVCMOS"
de25_pin {jp2_pin20} {GPIO_1[17]} PIN_CV11 "3.3-V LVCMOS"
de25_pin {jp2_pin21} {GPIO_1[18]} PIN_CV14 "3.3-V LVCMOS"
de25_pin {jp2_pin22} {GPIO_1[19]} PIN_DJ3 "3.3-V LVCMOS"
de25_pin {jp2_pin23} {GPIO_1[20]} PIN_DF3 "3.3-V LVCMOS"
de25_pin {jp2_pin24} {GPIO_1[21]} PIN_DN2 "3.3-V LVCMOS"
de25_pin {jp2_pin25} {GPIO_1[22]} PIN_CV4 "3.3-V LVCMOS"
de25_pin {jp2_pin26} {GPIO_1[23]} PIN_DD3 "3.3-V LVCMOS"
de25_pin {jp2_pin27} {GPIO_1[24]} PIN_CE11 "3.3-V LVCMOS"
de25_pin {jp2_pin28} {GPIO_1[25]} PIN_CE8 "3.3-V LVCMOS"
de25_pin {jp2_pin31} {GPIO_1[26]} PIN_DE1 "3.3-V LVCMOS"
de25_pin {jp2_pin32} {GPIO_1[27]} PIN_DH1 "3.3-V LVCMOS"
de25_pin {jp2_pin33} {GPIO_1[28]} PIN_DH2 "3.3-V LVCMOS"
de25_pin {jp2_pin34} {GPIO_1[29]} PIN_CH4 "3.3-V LVCMOS"
de25_pin {jp2_pin35} {GPIO_1[30]} PIN_DC2 "3.3-V LVCMOS"
de25_pin {jp2_pin36} {GPIO_1[31]} PIN_DC1 "3.3-V LVCMOS"
de25_pin {jp2_pin37} {GPIO_1[32]} PIN_BV19 "3.3-V LVCMOS"
de25_pin {jp2_pin38} {GPIO_1[33]} PIN_CE6 "3.3-V LVCMOS"
de25_pin {jp2_pin39} {GPIO_1[34]} PIN_BV11 "3.3-V LVCMOS"
de25_pin {jp2_pin40} {GPIO_1[35]} PIN_BV16 "3.3-V LVCMOS"

# ----------------------------------------------------- HDMI transmitter
#
# Table 3-13, "Pin Assignment of HDMI", pages 27 and 28, with Figure 3-19 on
# page 27 for the directions. The manual prints "3.3V" for every signal.
#
#     hdmi_d[N]        HDMI_TX_DN, the 24-bit video bus, to the ADV7513
#     hdmi_pclk        HDMI_TX_CLK, the pixel clock, to the ADV7513
#     hdmi_de          HDMI_TX_DE, data enable, to the ADV7513
#     hdmi_hsync       HDMI_TX_HS, to the ADV7513
#     hdmi_vsync       HDMI_TX_VS, to the ADV7513
#     hdmi_int         HDMI_TX_INT, the transmitter's interrupt, to the fabric
#     hdmi_scl         HDMI_I2C_SCL, the transmitter's I2C clock
#     hdmi_sda         HDMI_I2C_SDA, the transmitter's I2C data
#     hdmi_i2s_data    HDMI_I2S, audio data, to the ADV7513
#     hdmi_i2s_mclk    HDMI_MCLK, the audio reference clock, to the ADV7513
#     hdmi_i2s_lrclk   HDMI_LRCLK, the audio left/right clock, to the ADV7513
#     hdmi_i2s_bclk    HDMI_SCLK, the I2S bit clock, to the ADV7513
#
# **The I2C pair has two names in the manual.** Table 3-13 calls it
# `FPGA_I2C_SCL` and `FPGA_I2C_SDA`. Table 3-7, "I2C Bus Pin Assignments", on
# page 19, and Figure 3-19 call it `HDMI_I2C_SCL` and `HDMI_I2C_SDA`. Both
# tables give the same two pins, so the lines below carry the name that says
# what the pair is for.
#
# **The pixel clock is not 3.3 V, whatever Table 3-13 prints.** Its pin, DJ24,
# is in Quartus's bank 2A_T with the switches, the LEDs and `clock50_0`. That
# is a high-speed I/O bank, whose single-ended standards run from 1.0 V to
# 1.2 V according to Table 14 of Altera's device overview in the resource
# package. The standard below is therefore "1.1-V". Quartus refuses
# "3.3-V LVCMOS" on this pin even with nothing else in its bank, and this
# directory's README records the message. How a 1.1 V output meets the
# transmitter's input levels is not in the manual.
de25_pin {hdmi_d[0]} {HDMI_TX_D0} PIN_AV19 "3.3-V LVCMOS"
de25_pin {hdmi_d[1]} {HDMI_TX_D1} PIN_AT11 "3.3-V LVCMOS"
de25_pin {hdmi_d[2]} {HDMI_TX_D2} PIN_BE11 "3.3-V LVCMOS"
de25_pin {hdmi_d[3]} {HDMI_TX_D3} PIN_AV14 "3.3-V LVCMOS"
de25_pin {hdmi_d[4]} {HDMI_TX_D4} PIN_AT19 "3.3-V LVCMOS"
de25_pin {hdmi_d[5]} {HDMI_TX_D5} PIN_AT14 "3.3-V LVCMOS"
de25_pin {hdmi_d[6]} {HDMI_TX_D6} PIN_AV16 "3.3-V LVCMOS"
de25_pin {hdmi_d[7]} {HDMI_TX_D7} PIN_AV11 "3.3-V LVCMOS"
de25_pin {hdmi_d[8]} {HDMI_TX_D8} PIN_BH11 "3.3-V LVCMOS"
de25_pin {hdmi_d[9]} {HDMI_TX_D9} PIN_BE14 "3.3-V LVCMOS"
de25_pin {hdmi_d[10]} {HDMI_TX_D10} PIN_BE19 "3.3-V LVCMOS"
de25_pin {hdmi_d[11]} {HDMI_TX_D11} PIN_BH14 "3.3-V LVCMOS"
de25_pin {hdmi_d[12]} {HDMI_TX_D12} PIN_BV6 "3.3-V LVCMOS"
de25_pin {hdmi_d[13]} {HDMI_TX_D13} PIN_BJ23 "3.3-V LVCMOS"
de25_pin {hdmi_d[14]} {HDMI_TX_D14} PIN_BV4 "3.3-V LVCMOS"
de25_pin {hdmi_d[15]} {HDMI_TX_D15} PIN_BU23 "3.3-V LVCMOS"
de25_pin {hdmi_d[16]} {HDMI_TX_D16} PIN_BH16 "3.3-V LVCMOS"
de25_pin {hdmi_d[17]} {HDMI_TX_D17} PIN_DA1 "3.3-V LVCMOS"
de25_pin {hdmi_d[18]} {HDMI_TX_D18} PIN_BH19 "3.3-V LVCMOS"
de25_pin {hdmi_d[19]} {HDMI_TX_D19} PIN_CP2 "3.3-V LVCMOS"
de25_pin {hdmi_d[20]} {HDMI_TX_D20} PIN_CM1 "3.3-V LVCMOS"
de25_pin {hdmi_d[21]} {HDMI_TX_D21} PIN_DA2 "3.3-V LVCMOS"
de25_pin {hdmi_d[22]} {HDMI_TX_D22} PIN_CP1 "3.3-V LVCMOS"
de25_pin {hdmi_d[23]} {HDMI_TX_D23} PIN_CU2 "3.3-V LVCMOS"
de25_pin {hdmi_pclk} {HDMI_TX_CLK} PIN_DJ24 "1.1-V"
de25_pin {hdmi_de} {HDMI_TX_DE} PIN_CJ2 "3.3-V LVCMOS"
de25_pin {hdmi_hsync} {HDMI_TX_HS} PIN_BR11 "3.3-V LVCMOS"
de25_pin {hdmi_vsync} {HDMI_TX_VS} PIN_BR14 "3.3-V LVCMOS"
de25_pin {hdmi_int} {HDMI_TX_INT} PIN_CF2 "3.3-V LVCMOS"
de25_pin {hdmi_scl} {HDMI_I2C_SCL} PIN_BT1 "3.3-V LVCMOS"
de25_pin {hdmi_sda} {HDMI_I2C_SDA} PIN_BW2 "3.3-V LVCMOS"
de25_pin {hdmi_i2s_data} {HDMI_I2S} PIN_CB2 "3.3-V LVCMOS"
de25_pin {hdmi_i2s_mclk} {HDMI_MCLK} PIN_CF1 "3.3-V LVCMOS"
de25_pin {hdmi_i2s_lrclk} {HDMI_LRCLK} PIN_BR6 "3.3-V LVCMOS"
de25_pin {hdmi_i2s_bclk} {HDMI_SCLK} PIN_BW1 "3.3-V LVCMOS"
