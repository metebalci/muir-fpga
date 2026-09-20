# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# The DE25-Nano's processor system: the Agilex 5's hard processor, its LPDDR4
# controller and its bridges, described for Platform Designer in batch.
#
# Run by `boards/de25-nano/quartus/build.sh` for the memory board, `DDR=1`,
# in the build directory, as
#
#     qsys-script --quartus-project=cadr_de25 \
#                 --cmd="set ddr_mhz <MHz>; source <this file>"
#
# which writes `cadr_de25_hps.qsys` and its two components' `.ip` files there,
# and `qsys-generate` then makes the system's HDL.  **NOTHING GENERATED IS
# COMMITTED.**  Altera's generated files carry Altera's terms and nothing in
# them is this project's, so the system is described here and generated at
# every build, as the PLL is.  `qsys-script`'s interpreter has no `env`
# array, so the one setting this file takes, the memory's speed, is a
# variable the command sets before sourcing it.
#
# **EVERY VALUE BELOW IS A FACT WITH A SOURCE**, and the sources are three:
#
#   the manual     Terasic's DE25-Nano user manual, rev B, version 1.1, whose
#                  sha256 `boards/de25-nano/README.md` records: which package
#                  pin carries which signal of the board, and the clocks.
#   the pin report Quartus's own pin report for this part, which names the
#                  processor's I/O pin, `HPS_IOA_N` or `HPS_IOB_N`, at each
#                  package pin.
#   the IP         Altera's `intel_agilex_5_soc` 14.0.0, whose
#                  `ip/altera/intel_hps/sm/common/interface_ports.tcl` gives
#                  the functions each of those 48 pins can carry, and
#                  `emif_io96b_hps` 5.0.0.
#   the demo       Altera's `agilex5-demo-hps2fpga-interfaces` at commit
#                  `064c0cf2f7e749b72add75d3ac3845f20af63dc8`, under MIT-0,
#                  whose `brd_terasic_de25nano_revb/hw_base/
#                  a55_do_create_no_pins_hps.tcl` configures this board's
#                  LPDDR4 controller, lines 931 to 1881.
#
# Nothing is taken from Terasic's resource package or from Altera's golden
# system reference design, whose terms do not allow it.
#
# ---------------------------------------------------------- the processor
#
# **THE BRIDGES, WHICH ARE WHY THIS SYSTEM EXISTS.**
#
#   f2sdram     the FPGA-to-SDRAM bridge at 64 bits and 32 address bits: the
#               machine's main memory, `rtl/plumbing/cadr_f2sdram_port.sv`.
#               32 bits reach `0x8000_0000` to `0xFFFF_FFFF`, which is all of
#               this board's 1 GB (the HPS Component Reference Manual,
#               document 813752, section 2.2.2.2).
#   hps2fpga    the processor-to-fabric bridge, 32 bits wide with a 30-bit
#               address, its 1 GB window at `0x4000_0000`: the Zynq's
#               `M_AXI_GP0` role, for the faces of a later slice.
#   lwhps2fpga  the lightweight bridge, 32 bits with a 29-bit address, its
#               512 MB window at `0x2000_0000`: the Zynq's `M_AXI_GP1` role.
#   f2s         the coherent fabric-to-processor bridge, not built.
#
# Both processor-to-fabric bridges are answered end to end by the top level
# until their faces arrive.  `GP_Enable` brings out `h2f_gp_out` and
# `h2f_gp_in`, which open the memory port and carry its tally.
#
# **THE PINS**, derived and not chosen.  The manual's section 3.8 names each
# peripheral signal's package pin; Quartus's pin report names the processor
# pin at that package pin; and the IP's own table says which functions that
# processor pin can carry.  Each of the 48 entries below is the one function
# the three agree on, in the order the IP takes them, `HPS_IOA_1` to
# `HPS_IOA_24` and then `HPS_IOB_1` to `HPS_IOB_24`:
#
#   IOA 1 to 12   USB0, ULPI to the USB3320        manual Table 3-24
#   IOA 13 to 24  EMAC0, RGMII to the KSZ9031RN    manual Table 3-20
#   IOB 1 to 3    SD/MMC data 0 and 1, and clock   manual Table 3-23
#   IOB 4         the processor's 25 MHz clock     manual Table 3-6
#   IOB 5         the G-sensor's interrupt, GPIO1 4    manual Table 3-25
#   IOB 6 to 8    SD/MMC data 2 and 3, and command manual Table 3-23
#   IOB 9 to 12   none: the manual names no signal at these four
#   IOB 13, 14    I2C1 to the G-sensor             manual Table 3-25
#   IOB 15, 16    UART1 to the FT4232H             manual Table 3-22
#   IOB 17, 18    the processor's key and LED, GPIO1 16 and 17  Table 3-19
#   IOB 19 to 22  none, as IOB 9 to 12
#   IOB 23, 24    EMAC0's MDIO and MDC             manual Table 3-20
#
# **THE DEBUG PORT** is a project setting, not the IP's: `project.tcl` puts
# the processor's debug access port on the SDM's JTAG pins for this board.
#
# ------------------------------------------------------------- the memory
#
# **ONE LPDDR4 CHANNEL, 32 BITS WIDE, 1 GB**, on the I/O bank the manual's
# section 3.7.4 gives the processor's controller, LPDDR4A, with its
# 166.666 MHz reference clock from the manual's Table 3-6.  The controller's
# other settings are the demo's for this board, and they are the settings
# where the demo differs from the IP's defaults: the placement on the bank,
# the byte lanes' bit order on the board, the memory part's size, refresh and
# timing, its voltage references and terminations, and the controller's
# data masking, read data-bus inversion and priorities.  The latencies the
# IP derives from the speed and the bus inversion are left to it.
#
# **THE SPEED IS ONE PARAMETER, AND ITS DEFAULT IS THE SLOWER BOARD'S.**
# Terasic's revision page gives rev A as running its LPDDR4 up to 1066 MHz
# and rev B up to 1333 MHz, and the manual for rev B gives 1333 MHz in
# section 3.7.4.  Which revision a board is can be read only from the seal
# on its underside.  So `DE25_DDR_MHZ`, which `build.sh` passes as
# `ddr_mhz`, defaults to 1066.667, which runs on either board, and a rev B
# board may be built at 1333.333.  `build.sh` refuses any other value.
#
# **A CHANGE HERE IS A CHANGE TO THE PROCESSOR'S FIRST STAGE.**  The SDM
# configures the processor's I/O and memory controller from what this system
# puts into the bitstream, and a processor that boots first keeps that part
# in its flash; the configuration a later fabric image carries must match
# it, which `quartus_pfg` checks as the images' I/O hash.

package require -exact qsys 26.1

if {![info exists ddr_mhz]} {
    error "hps: set ddr_mhz before sourcing this file"
}
if {[lsearch -exact {1066.667 1333.333} $ddr_mhz] < 0} {
    error "hps: ddr_mhz is '$ddr_mhz', and the DE25-Nano's LPDDR4 runs at 1066.667 (rev A) or 1333.333 (rev B)"
}

create_system cadr_de25_hps
set_project_property DEVICE_FAMILY {Agilex 5}
set_project_property DEVICE {A5EB013BB23BE4SCS}

# ------------------------------------------------------------ the processor
add_component hps ip/cadr_de25_hps/hps.ip intel_agilex_5_soc hps 14.0.0
load_component hps
# The bridges: see the header.
set_component_parameter_value f2sdram_data_width {64}
set_component_parameter_value f2sdram_address_width {32}
set_component_parameter_value H2F_Width {32}
set_component_parameter_value H2F_Address_Width {30}
set_component_parameter_value LWH2F_Width {32}
set_component_parameter_value LWH2F_Address_Width {29}
set_component_parameter_value f2s_data_width {0}
set_component_parameter_value GP_Enable {1}
# The MPU event interface is the IP's default and nothing here uses it.
set_component_parameter_value MPU_Events_Enable {0}
# The processor's memory controller is the separate component below, joined
# to the processor by its AXI link, as the demo joins them (its lines 65, 66).
set_component_parameter_value EMIF_AXI_Enable {1}
set_component_parameter_value EMIF_Topology {1}
# The processor's oscillator: HPS_CLK_25, 25 MHz, the manual's Table 3-6.
set_component_parameter_value eosc1_clk_mhz {25.0}
# The peripherals, on the processor's own pins, and their modes: four data
# lines on the microSD socket (manual section 3.8.4), RGMII with MDIO to the
# PHY (3.8.2), ULPI to the USB PHY (3.8.5), a UART with RX and TX only
# (3.8.3), and I2C to the G-sensor (3.8.6).
set_component_parameter_value SDMMC_PinMuxing {IO}
set_component_parameter_value SDMMC_Mode {4-bit}
set_component_parameter_value EMAC0_PinMuxing {IO}
set_component_parameter_value EMAC0_Mode {RGMII_with_MDIO}
set_component_parameter_value USB0_PinMuxing {IO}
set_component_parameter_value USB0_Mode {default}
set_component_parameter_value UART1_PinMuxing {IO}
set_component_parameter_value UART1_Mode {No_flow_control}
set_component_parameter_value I2C1_PinMuxing {IO}
set_component_parameter_value I2C1_Mode {default}
# The 48 pins, IOA 1 to 24 and IOB 1 to 24: see the header's table.
set_component_parameter_value HPS_IO_Enable [list \
    USB0:CLK USB0:STP USB0:DIR USB0:DATA0 USB0:DATA1 USB0:NXT \
    USB0:DATA2 USB0:DATA3 USB0:DATA4 USB0:DATA5 USB0:DATA6 USB0:DATA7 \
    EMAC0:TX_CLK EMAC0:TX_CTL EMAC0:RX_CLK EMAC0:RX_CTL EMAC0:TXD0 EMAC0:TXD1 \
    EMAC0:RXD0 EMAC0:RXD1 EMAC0:TXD2 EMAC0:TXD3 EMAC0:RXD2 EMAC0:RXD3 \
    SDMMC:DATA0 SDMMC:DATA1 SDMMC:CCLK HCLK:HPS_OSC_CLK GPIO1:IO4 SDMMC:DATA2 \
    SDMMC:DATA3 SDMMC:CMD NONE NONE NONE NONE \
    I2C1:SDA I2C1:SCL UART1:TX UART1:RX GPIO1:IO16 GPIO1:IO17 \
    NONE NONE NONE NONE MDIO0:MDIO MDIO0:MDC]
save_component

# ---------------------------------------------- the LPDDR4 controller
add_component emif ip/cadr_de25_hps/emif.ip emif_io96b_hps emif 5.0.0
load_component emif
set_component_parameter_value EMIF_PROTOCOL {LPDDR4}
set_component_parameter_value EMIF_TOPOLOGY {1x32}
# Each value is the demo's, at the line of its file given beside it, except
# the speed, which is this board's parameter.
set m emif_0_lpddr4
foreach {name value line} [list \
    MEM_NUM_CHANNELS                  1          1526 \
    MEM_NUM_CHANNELS_PER_IO96         1          1527 \
    NUM_IO96_IN_CHIP                  2          1587 \
    PLACEMENT_SCHEMES                 LPDDR4_X32_BOT 1616 \
    PHY_AC_PLACEMENT                  BOT        1588 \
    PHY_SWIZZLE_MAP {PIN_SWIZZLE_CH0_DQS0=5 4 0 7 1 6 2 3;PIN_SWIZZLE_CH0_DQS1=15 8 14 9 12 13 11 10;PIN_SWIZZLE_CH0_DQS2=18 22 19 20 21 23 16 17;PIN_SWIZZLE_CH0_DQS3=27 29 28 26 24 25 31 30;} 1596 \
    PHY_REFCLK_ADVANCED_SELECT_EN     1          1593 \
    PHY_REFCLK_FREQ_MHZ_AUTOSET_EN    0          1595 \
    AXI4_ADDR_WIDTH                   40         1482 \
    MEM_CHANNEL_CAPACITY_GBITS        8.0        1514 \
    MEM_CHANNEL_ADDR_NUM_BITS         33         1513 \
    MEM_DIE_DENSITY_GBITS             4          1522 \
    MEM_ROW_ADDR_WIDTH                15         1541 \
    MEM_TCCD_NS                       8.0        1542 \
    JEDEC_OVERRIDE_TABLE_PARAM_NAME   MEM_TCCD_NS 1509 \
    MEM_TCKCKEH_NS                    2.25       1543 \
    MEM_TCMDCKE_NS                    2.25       1549 \
    MEM_TESCKE_NS                     2.25       1555 \
    MEM_TMRR_NS                       6.0        1558 \
    MEM_TRFCAB_NS                     180.0      1567 \
    MEM_TRFCPB_NS                     90.0       1568 \
    MEM_TXSR_NS                       187.5      1577 \
    MEM_TZQCKE_NS                     2.25       1579 \
    MEM_WR_POSTAMBLE_CYC              0          1586 \
    MEM_CA_VREF                       33         1511 \
    MEM_DQ_VREF                       45         1524 \
    ANALOG_PARAM_DERIVATION_PARAM_NAME {MEM_VREF_DQ_X_VALUE MEM_VREF_CA_X_CA_VALUE MEM_VREF_CA_X_CA_RANGE} 1481 \
    MEM_VREF_CA_X_CA_RANGE            1          1581 \
    MEM_VREF_CA_X_CA_VALUE            23.2       1582 \
    MEM_VREF_DQ_X_VALUE               28.0       1584 \
    CTRL_DM_EN                        1          1485 \
    CTRL_ALL_STRB_EN                  1          1483 \
    CTRL_RD_DBI_EN                    1          1494 \
    CTRL_FIXED_PRIORITY_EN            1          1489 \
    CTRL_FIXED_R_PRIORITY             1          1490 \
    CTRL_PERFORMANCE_PROFILE          SEQ_SIMU   1492 \
    CTRL_PLACEMENT_EN                 0          1493 \
    ] {
    set_component_sub_module_parameter_value $m $name $value
}
# The speed: see the header.  The IP would otherwise choose one itself.
set_component_sub_module_parameter_value $m MEM_OPERATING_FREQ_MHZ_AUTOSET_EN 0
set_component_sub_module_parameter_value $m MEM_OPERATING_FREQ_MHZ $ddr_mhz
# **AND THE REFERENCE CLOCK AS THE IP SPELLS IT AT THAT SPEED.**  The board's
# is 166.666 MHz, the manual's Table 3-6, and the demo gives it as 166.6666
# (its line 1594) at 1333.333 MHz.  The IP accepts a reference clock only as
# one of the strings it derives from the speed, measured: at 1066.667 MHz its
# list holds 166.6667 and refuses 166.6666, and at 1333.333 MHz the reverse.
# Both are the same crystal to within 100 Hz.
# (`qsys-script`'s interpreter has neither `dict` nor `eq`.)
if {[string equal $ddr_mhz 1066.667]} {
    set refclk 166.6667
} else {
    set refclk 166.6666
}
set_component_sub_module_parameter_value $m PHY_REFCLK_FREQ_MHZ $refclk
save_component

# ----------------------------------------------------------- the system
#
# The controller's AXI link to the processor, and everything else exported:
# the top level connects every interface, and the clocks and resets of the
# three bridges are the fabric's own.
add_connection emif.io96b0_to_hps/hps.io96b0_to_hps
foreach {instance interface} {
    hps h2f_reset  hps h2f_warm_reset_handshake  hps hps_gp  hps hps_io
    hps f2sdram  hps f2sdram_axi_clock  hps f2sdram_axi_reset
    hps hps2fpga  hps hps2fpga_axi_clock  hps hps2fpga_axi_reset
    hps lwhps2fpga  hps lwhps2fpga_axi_clock  hps lwhps2fpga_axi_reset
    emif mem_0  emif mem_ck_0  emif mem_reset_n  emif oct_0  emif ref_clk
} {
    set_interface_property ${instance}_$interface EXPORT_OF $instance.$interface
}

# **A SYSTEM THAT DOES NOT VALIDATE IS NOT SAVED.**  Every message is
# printed, and an error stops the build here rather than at generation.
set errors 0
foreach message [validate_system] {
    puts "hps: validation: $message"
    if {[string match -nocase "*error*" $message]} { incr errors }
}
if {$errors > 0} {
    error "hps: the system has $errors validation errors"
}

# The speed the controller will run at, as the IP holds it after validation,
# for the build's log.
load_component emif
puts "hps: LPDDR4 at [get_component_sub_module_parameter_value $m MEM_OPERATING_FREQ_MHZ] MHz\
      from a [get_component_sub_module_parameter_value $m PHY_REFCLK_FREQ_MHZ] MHz reference,\
      read latency [get_component_sub_module_parameter_value $m MEM_CL_CYC],\
      write latency [get_component_sub_module_parameter_value $m MEM_CWL_CYC]"

save_system cadr_de25_hps.qsys
