// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// A stub for the generated DDR3L controller, so that the Arty A7-100's memory
// board can be linted.
//
// **IT IS IN `tb/` AND NOT IN `rtl/` FOR THE REASON THIS PROJECT ALREADY
// RECORDS**: both Vivado flows read every `.sv` under `rtl/`, so a simulation
// stub written there would REPLACE the real thing in synthesis and hand the
// board a wire where its memory controller should be.  Nothing globs `tb/`.
//
// **AND WHAT IT CANNOT CATCH IS THE SAME THING `tb/cadr_arty_stubs.sv` CANNOT
// CATCH**: a stub is written to match what we connect, so a port we have
// forgotten is a port this file has forgotten too.  What it does hold is that
// the wrapper's port list matches this one in name, direction and width, which
// is the fault a hand-copied instantiation template actually makes.  The list
// below is a transcription of the generator's own `cadr_mig_a7.veo` and the
// module it instantiates, and `boards/arty-a7-100/vivado/mig_check.py` is what
// holds it to that file rather than to memory.
//
// It models nothing.  The real behaviour is modelled in
// `tb/cadr_a7_mem_harness.sv`, against which `cadr_mig_ui` is checked.

`default_nettype none

/* verilator lint_off DECLFILENAME */
module cadr_mig_a7 (
    inout  wire [15:0]   ddr3_dq,
    inout  wire [1:0]    ddr3_dqs_n,
    inout  wire [1:0]    ddr3_dqs_p,
    output wire [13:0]   ddr3_addr,
    output wire [2:0]    ddr3_ba,
    output wire          ddr3_ras_n,
    output wire          ddr3_cas_n,
    output wire          ddr3_we_n,
    output wire          ddr3_reset_n,
    output wire [0:0]    ddr3_ck_p,
    output wire [0:0]    ddr3_ck_n,
    output wire [0:0]    ddr3_cke,
    output wire [0:0]    ddr3_cs_n,
    output wire [1:0]    ddr3_dm,
    output wire [0:0]    ddr3_odt,
    input  wire          sys_clk_i,
    input  wire          clk_ref_i,
    input  wire [27:0]   app_addr,
    input  wire [2:0]    app_cmd,
    input  wire          app_en,
    input  wire [127:0]  app_wdf_data,
    input  wire          app_wdf_end,
    input  wire [15:0]   app_wdf_mask,
    input  wire          app_wdf_wren,
    output wire [127:0]  app_rd_data,
    output wire          app_rd_data_end,
    output wire          app_rd_data_valid,
    output wire          app_rdy,
    output wire          app_wdf_rdy,
    input  wire          app_sr_req,
    input  wire          app_ref_req,
    input  wire          app_zq_req,
    output wire          app_sr_active,
    output wire          app_ref_ack,
    output wire          app_zq_ack,
    output wire          ui_clk,
    output wire          ui_clk_sync_rst,
    output wire          init_calib_complete,
    output wire [11:0]   device_temp,
    input  wire          sys_rst
);

  /* verilator lint_off UNUSEDSIGNAL */
  wire _unused = &{1'b0, app_addr, app_cmd, app_en, app_wdf_data, app_wdf_end,
                   app_wdf_mask, app_wdf_wren, app_sr_req, app_ref_req,
                   app_zq_req, clk_ref_i, sys_rst, ddr3_dq, ddr3_dqs_n,
                   ddr3_dqs_p};
  /* verilator lint_on UNUSEDSIGNAL */

  assign ddr3_dq           = 16'dz;
  assign ddr3_dqs_n        = 2'bz;
  assign ddr3_dqs_p        = 2'bz;
  assign ddr3_addr         = 14'd0;
  assign ddr3_ba           = 3'd0;
  assign ddr3_ras_n        = 1'b1;
  assign ddr3_cas_n        = 1'b1;
  assign ddr3_we_n         = 1'b1;
  assign ddr3_reset_n      = 1'b0;
  assign ddr3_ck_p         = 1'b0;
  assign ddr3_ck_n         = 1'b0;
  assign ddr3_cke          = 1'b0;
  assign ddr3_cs_n         = 1'b1;
  assign ddr3_dm           = 2'b11;
  assign ddr3_odt          = 1'b0;
  assign app_rd_data       = 128'd0;
  assign app_rd_data_end   = 1'b0;
  assign app_rd_data_valid = 1'b0;
  assign app_rdy           = 1'b0;
  assign app_wdf_rdy       = 1'b0;
  assign app_sr_active     = 1'b0;
  assign app_ref_ack       = 1'b0;
  assign app_zq_ack        = 1'b0;
  assign ui_clk            = sys_clk_i;
  assign ui_clk_sync_rst   = 1'b1;
  assign init_calib_complete = 1'b0;
  assign device_temp       = 12'd0;

endmodule
/* verilator lint_on DECLFILENAME */

`default_nettype wire
