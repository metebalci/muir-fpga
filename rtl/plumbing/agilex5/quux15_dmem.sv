// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **DISPATCH MEMORY ON AN AGILEX 5**: the Agilex 5 version of
// `rtl/machine/quux15_dmem.sv`, which says what it holds and who reads it.
// The same ports and the same behavior, the halves in MLAB.
//
// **A READ IN THE CLOCK AFTER A WRITE TAKES THE WRITE**: the core reads an
// entry in the clock after writing it.  An MLAB writes its cell during the
// clock after the edge that takes the write, and a read of the cell in
// that clock is undefined (Quartus's `no_rw_check`, which the build gives
// these RAMs).  **SO THE WRITE IS FORWARDED**: it is held a clock (`fw_we`,
// `fw_wa`, `fw_wd`), and a read of its address in that clock takes the held
// entry and not the MLAB's.  From the clock after, the MLAB holds it.  Under
// `QUUX15_A5_MLAB_POISON`, simulation's only, the MLAB's read in that clock
// is the entry's complement, so that a design that came to rely on the MLAB
// there fails (`tools/quux15_ram_eq_check.py dmem`, `make quux15-a5`).

`default_nettype none

module quux15_dmem (
    input  var logic        clk,
    input  var logic        we,
    input  var logic [11:0] waddr,
    input  var logic [16:0] wdata,
    input  var logic [11:0] ex_a,
    output var logic [16:0] ex_e,
    input  var logic [11:0] ro_a,
    output var logic [16:0] ro_e
);
  logic [16:0] even[2048] /* verilator public_flat_rw */;
  logic [16:0] odd[2048] /* verilator public_flat_rw */;

  initial begin
    for (int k = 0; k < 2048; k++) begin
      even[k] = 17'd0;
      odd[k]  = 17'd0;
    end
  end

  always_ff @(posedge clk) begin
    if (we && !waddr[0]) even[waddr[11:1]] <= wdata;
    if (we && waddr[0]) odd[waddr[11:1]] <= wdata;
  end

  // The write the MLABs are still taking.
  logic        fw_we = 1'b0;
  logic [11:0] fw_wa;
  logic [16:0] fw_wd;
  always_ff @(posedge clk) begin
    fw_we <= we;
    fw_wa <= waddr;
    fw_wd <= wdata;
  end

  logic [16:0] ex_w, ro_w;
  assign ex_w = ex_a[0] ? odd[ex_a[11:1]] : even[ex_a[11:1]];
  assign ro_w = ro_a[0] ? odd[ro_a[11:1]] : even[ro_a[11:1]];
  logic [16:0] ex_m, ro_m;
`ifdef QUUX15_A5_MLAB_POISON
  // The MLAB's write window, kept apart from the forwarding's registers.
  logic        pz_we = 1'b0;
  logic [11:0] pz_wa;
  always_ff @(posedge clk) begin
    pz_we <= we;
    pz_wa <= waddr;
  end
  assign ex_m = (pz_we && pz_wa == ex_a) ? ~ex_w : ex_w;
  assign ro_m = (pz_we && pz_wa == ro_a) ? ~ro_w : ro_w;
`else
  assign ex_m = ex_w;
  assign ro_m = ro_w;
`endif
  assign ex_e = (fw_we && fw_wa == ex_a) ? fw_wd : ex_m;
  assign ro_e = (fw_we && fw_wa == ro_a) ? fw_wd : ro_m;
endmodule

`default_nettype wire
