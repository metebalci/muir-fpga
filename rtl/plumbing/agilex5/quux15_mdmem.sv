// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **THE MACRO DISPATCH MEMORY ON AN AGILEX 5**: the Agilex 5 version of
// `rtl/machine/quux15_mdmem.sv`, which says what it holds and who reads it.
// The same ports and the same behavior: five copies, one for each read
// port, each an MLAB written at the same clock with the same entry, so that
// every copy holds the same 1,024 entries and each read sees the array the
// behavioral version reads.
//
// **WHY ALTERA'S `altdpram` AND NOT INFERENCE**: Quartus Prime Pro 26.1
// infers an MLAB from a read only when it can take a register into the RAM,
// on the read's address or on its word.  Every read here has both
// unregistered (each address is a halfword of M 31 that LC selects, and
// each entry is decided on in the same clock), and Quartus then builds the
// array in flip-flops and 1,024-way selectors ("uninferred due to
// asynchronous read logic"), about 18,400 registers and most of the
// DE25-Nano's logic.  `altdpram` with its read address and its output both
// `UNREGISTERED` and `RAM_BLOCK_TYPE` "MLAB" builds each copy as a simple
// dual-port MLAB, 32 words by 576 bits.
//
// **THE WRITE**: `altdpram`'s write side registered on `inclock`, the
// address, the entry and the enable taken at the clock's edge as the
// behavioral version's `always_ff` takes them.  A read of the address
// written in the same clock is the old entry, the write not yet taken, as
// the behavioral version's; its poison (`QUUX15_RDW_POISON`) shows the core
// never uses that word.
//
// **A READ OF THE ADDRESS WRITTEN AT THE CLOCK'S START IS THE NEW ENTRY,
// AND THE CORE USES IT** (the behavioral version says where).  An MLAB
// writes its cell during the clock after the edge that takes the write,
// so such a read overlaps the write, which `altdpram` calls a mixed-port
// read during write and leaves undefined (`DONT_CARE`).  **THE ENTRY JUST
// WRITTEN IS THEREFORE FORWARDED**: the write is held a clock (`we_q`,
// `waddr_q`, `wdata_q`), and a read of its address in that clock takes
// `wdata_q` and not the MLAB's word.  From the clock after, the MLAB holds
// it.  So nothing here depends on how an MLAB behaves while it writes.
//
// Power-on: every entry 0, as the behavioral version's `initial`.

`default_nettype none

module quux15_mdmem (
    input  var logic        clk,
    input  var logic        we,
    input  var logic [9:0]  waddr,
    input  var logic [17:0] wdata,
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic        wmay,     // the behavioral version's poison's
    /* verilator lint_on UNUSEDSIGNAL */
    input  var logic [9:0]  rd_a,
    output var logic [17:0] rd_e,
    input  var logic [9:0]  rx_a,
    output var logic [17:0] rx_e,
    input  var logic [9:0]  ex_a,
    output var logic [17:0] ex_e,
    input  var logic [9:0]  d_a,
    output var logic [17:0] d_e,
    input  var logic [9:0]  ro_a,
    output var logic [17:0] ro_e
);
  logic [4:0][9:0]  ra;
  logic [4:0][17:0] re;
  assign ra = {ro_a, d_a, ex_a, rx_a, rd_a};
  assign {ro_e, d_e, ex_e, rx_e, rd_e} = re;

  // The write the MLABs are still taking, forwarded to a read of its address.
  logic        we_q = 1'b0;
  logic [9:0]  waddr_q;
  logic [17:0] wdata_q;
  always_ff @(posedge clk) begin
    we_q    <= we;
    waddr_q <= waddr;
    wdata_q <= wdata;
  end
  logic [4:0][17:0] mq;
  for (genvar k = 0; k < 5; k++) begin : g_fwd
    assign re[k] = (we_q && waddr_q == ra[k]) ? wdata_q : mq[k];
  end

  for (genvar k = 0; k < 5; k++) begin : g_copy
    altdpram #(
        .WIDTH(18), .WIDTHAD(10), .NUMWORDS(1024),
        .INDATA_REG("INCLOCK"), .WRADDRESS_REG("INCLOCK"), .WRCONTROL_REG("INCLOCK"),
        .RDADDRESS_REG("UNREGISTERED"), .RDCONTROL_REG("UNREGISTERED"),
        .OUTDATA_REG("UNREGISTERED"),
        .RAM_BLOCK_TYPE("MLAB"), .USE_EAB("ON"), .INTENDED_DEVICE_FAMILY("Agilex 5"),
        .READ_DURING_WRITE_MODE_MIXED_PORTS("DONT_CARE")
    ) u_copy (
        .inclock(clk), .wren(we), .wraddress(waddr), .data(wdata),
        .rdaddress(ra[k]), .q(mq[k])
    );
  end
endmodule

`default_nettype wire
