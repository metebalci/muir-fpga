// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// `rtl/machine/quux15_core.sv` as a SHELL, for the simulations of revision
// 15's top levels: `tb/quux15_de25_top_tb.cpp` (the DE25-Nano's, around the
// shells of `tb/cadr_de25_sim_stubs.sv`) and `tb/quux15_zynq_reset_tb.cpp`
// (the Arty Z7-20's and the Kria KR260's, around the processing system's
// simulation).  **A SHELL ON PURPOSE**, for the reason
// `tb/cadr_de25_sim_stubs.sv` gives for `cadr_machine`'s: what a top level's
// check holds is its wiring, and a shell drives each line on its own.  Every
// output is a register the testbench writes (`tbo_<port>`) and every input a
// copy it reads (`tbi_<port>`).  The port list and the parameters are the
// core's own, so a port added there and not here is an elaboration error,
// and one here a top level leaves unconnected is a lint error.
//
// **NONE OF THIS MAY MOVE TO `rtl/`**, for the reason `tb/cadr_de25_stubs.sv`
// gives: the board flows glob that tree.

`default_nettype none

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNDRIVEN */

module quux15_core #(
    parameter string PROM_HEX = "",
    parameter logic [31:0] MACHINE_ID = {16'h5155, 12'd15, 4'd4},
    parameter int unsigned MAIN_WORDS = 32'h0020_0000,
    parameter int unsigned CACHE_WORDS = 65536,
    parameter int unsigned VIDEO_W = 1280,
    parameter int unsigned VIDEO_H = 1024,
    parameter int unsigned FB_WORDS = VIDEO_W / 32 * VIDEO_H,
    parameter logic [8*64-1:0] BOARD_NAME = '0,
    parameter bit ONE_WRITE_ID = 1'b1,
    parameter logic [31:0] MAIN_BASE    = 32'h0000_0000,
    parameter logic [31:0] DISPLAY_BASE = 32'h0A00_0000,
    parameter int unsigned BUBBLES = 1,
    parameter int unsigned RESET_BOUND = 65536,
    parameter int unsigned RESET_MIN   = 64
) (
    input var logic clk,
    input var logic rst,
    input var logic rst_req,
    output var logic rst_pend,
    output var logic rst_on,
    output var logic rst_cut,
    output var logic [15:0] obs_cs,
    output var logic [15:0] obs_rd,
    output var logic [15:0] obs_ex,
    output var logic [15:0] obs_wb,
    output var logic [15:0] obs_commit,
    output var logic [13:0] obs_pdlptr,
    output var logic [13:0] obs_pdlidx,
    output var logic [4:0] obs_spcptr,
    output var logic [39:0] obs_q,
    output var logic [39:0] obs_vma,
    output var logic [39:0] obs_md,
    output var logic [40:0] obs_lc,
    output var logic [31:0] obs_ic,
    output var logic obs_opnd,
    output var logic [39:0] obs_ea,
    output var logic [39:0] obs_em,
    output var logic [39:0] obs_ob,
    output var logic [25:0] obs_oalow,
    output var logic [21:0] obs_oahigh,
    output var logic [1:0] obs_grant,
    output var logic [31:0] obs_gaddr,
    output var logic obs_mdl,
    output var logic [39:0] obs_mdword,
    output var logic obs_reg,
    output var logic [31:0] obs_raddr,
    output var logic [3:0] obs_queue,
    output var logic [4:0] obs_inflight,
    output var logic obs_halted,
    output var logic [1:0] obs_errhalt,
    output var logic [3:0] m_awid,
    output var logic [31:0] m_awaddr,
    output var logic [7:0] m_awlen,
    output var logic [2:0] m_awsize,
    output var logic [1:0] m_awburst,
    output var logic m_awvalid,
    input var logic m_awready,
    output var logic [63:0] m_wdata,
    output var logic [7:0] m_wstrb,
    output var logic m_wlast,
    output var logic m_wvalid,
    input var logic m_wready,
    input var logic [3:0] m_bid,
    input var logic [1:0] m_bresp,
    input var logic m_bvalid,
    output var logic m_bready,
    output var logic [31:0] m_araddr,
    output var logic [7:0] m_arlen,
    output var logic [2:0] m_arsize,
    output var logic [1:0] m_arburst,
    output var logic m_arvalid,
    input var logic m_arready,
    input var logic [63:0] m_rdata,
    input var logic [1:0] m_rresp,
    input var logic m_rlast,
    input var logic m_rvalid,
    output var logic m_rready,
    input var logic [6:0] period,
    input var logic [31:0] rtc_start,
    output var logic fd_doorbell,
    output var logic [15:0] fd_prod,
    output var logic fd_enabled,
    input var logic host_we,
    input var logic [3:0] host_widx,
    input var logic [31:0] host_wdata,
    input var logic [3:0] host_ridx,
    output var logic [31:0] host_rdata,
    input var logic eth_we,
    input var logic [4:0] eth_widx,
    input var logic [31:0] eth_wdata,
    input var logic [4:0] eth_ridx,
    output var logic [31:0] eth_rdata,
    output var logic [15:0] eth_tx_prod,
    output var logic [15:0] eth_rx_prod,
    input var logic kbd_strobe,
    input var logic [23:0] kbd_code,
    input var logic [6:0] mouse_lines,
    output var logic kbd_busy,
    output var logic axi_one_write_id,
    output var logic [3:0] axi_read_clocks,
    output var logic [3:0] axi_write_clocks,
    input var logic spy_we,
    input var logic [3:0] spy_eadr,
    input var logic [15:0] spy_wdata,
    input var logic [3:0] spy_raddr,
    output var logic [15:0] spy_rdata,
    input var logic [4:0] ro_sel,
    output var logic [63:0] ro_word,
    input var logic rm_en,
    input var logic rm_snap,
    input var logic [3:0] rm_sel,
    input var logic [13:0] rm_addr,
    output var logic [63:0] rm_word,
    output var logic [63:0] obs_committed,
    output var logic [47:0] obs_clocks,
    input var logic drive_present,
    input var logic store_we,
    input var logic [4:0] store_slot,
    input var logic [8:0] store_addr,
    input var logic [31:0] store_wdata,
    output var logic [31:0] store_rdata,
    output var logic store_miss,
    output var logic req_valid,
    output var logic [30:0] req_tag,
    output var logic req_post,
    output var logic ch_waiting,
    input var logic store_deny,
    output var logic [4:0] ch_slot,
    output var logic ch_wrote,
    output var logic ch_hit,
    output var logic ch_active,
    input var logic store_busy,
    input var logic [4:0] store_busy_slot,
    output var logic obs_transfer,
    output var logic bow
);

  logic tbi_clk /*verilator public_flat_rw*/;
  assign tbi_clk = clk;
  logic tbi_rst /*verilator public_flat_rw*/;
  assign tbi_rst = rst;
  logic tbi_rst_req /*verilator public_flat_rw*/;
  assign tbi_rst_req = rst_req;
  logic tbo_rst_pend /*verilator public_flat_rw*/;
  assign rst_pend = tbo_rst_pend;
  logic tbo_rst_on /*verilator public_flat_rw*/;
  assign rst_on = tbo_rst_on;
  logic tbo_rst_cut /*verilator public_flat_rw*/;
  assign rst_cut = tbo_rst_cut;
  logic [15:0] tbo_obs_cs /*verilator public_flat_rw*/;
  assign obs_cs = tbo_obs_cs;
  logic [15:0] tbo_obs_rd /*verilator public_flat_rw*/;
  assign obs_rd = tbo_obs_rd;
  logic [15:0] tbo_obs_ex /*verilator public_flat_rw*/;
  assign obs_ex = tbo_obs_ex;
  logic [15:0] tbo_obs_wb /*verilator public_flat_rw*/;
  assign obs_wb = tbo_obs_wb;
  logic [15:0] tbo_obs_commit /*verilator public_flat_rw*/;
  assign obs_commit = tbo_obs_commit;
  logic [13:0] tbo_obs_pdlptr /*verilator public_flat_rw*/;
  assign obs_pdlptr = tbo_obs_pdlptr;
  logic [13:0] tbo_obs_pdlidx /*verilator public_flat_rw*/;
  assign obs_pdlidx = tbo_obs_pdlidx;
  logic [4:0] tbo_obs_spcptr /*verilator public_flat_rw*/;
  assign obs_spcptr = tbo_obs_spcptr;
  logic [39:0] tbo_obs_q /*verilator public_flat_rw*/;
  assign obs_q = tbo_obs_q;
  logic [39:0] tbo_obs_vma /*verilator public_flat_rw*/;
  assign obs_vma = tbo_obs_vma;
  logic [39:0] tbo_obs_md /*verilator public_flat_rw*/;
  assign obs_md = tbo_obs_md;
  logic [40:0] tbo_obs_lc /*verilator public_flat_rw*/;
  assign obs_lc = tbo_obs_lc;
  logic [31:0] tbo_obs_ic /*verilator public_flat_rw*/;
  assign obs_ic = tbo_obs_ic;
  logic tbo_obs_opnd /*verilator public_flat_rw*/;
  assign obs_opnd = tbo_obs_opnd;
  logic [39:0] tbo_obs_ea /*verilator public_flat_rw*/;
  assign obs_ea = tbo_obs_ea;
  logic [39:0] tbo_obs_em /*verilator public_flat_rw*/;
  assign obs_em = tbo_obs_em;
  logic [39:0] tbo_obs_ob /*verilator public_flat_rw*/;
  assign obs_ob = tbo_obs_ob;
  logic [25:0] tbo_obs_oalow /*verilator public_flat_rw*/;
  assign obs_oalow = tbo_obs_oalow;
  logic [21:0] tbo_obs_oahigh /*verilator public_flat_rw*/;
  assign obs_oahigh = tbo_obs_oahigh;
  logic [1:0] tbo_obs_grant /*verilator public_flat_rw*/;
  assign obs_grant = tbo_obs_grant;
  logic [31:0] tbo_obs_gaddr /*verilator public_flat_rw*/;
  assign obs_gaddr = tbo_obs_gaddr;
  logic tbo_obs_mdl /*verilator public_flat_rw*/;
  assign obs_mdl = tbo_obs_mdl;
  logic [39:0] tbo_obs_mdword /*verilator public_flat_rw*/;
  assign obs_mdword = tbo_obs_mdword;
  logic tbo_obs_reg /*verilator public_flat_rw*/;
  assign obs_reg = tbo_obs_reg;
  logic [31:0] tbo_obs_raddr /*verilator public_flat_rw*/;
  assign obs_raddr = tbo_obs_raddr;
  logic [3:0] tbo_obs_queue /*verilator public_flat_rw*/;
  assign obs_queue = tbo_obs_queue;
  logic [4:0] tbo_obs_inflight /*verilator public_flat_rw*/;
  assign obs_inflight = tbo_obs_inflight;
  logic tbo_obs_halted /*verilator public_flat_rw*/;
  assign obs_halted = tbo_obs_halted;
  logic [1:0] tbo_obs_errhalt /*verilator public_flat_rw*/;
  assign obs_errhalt = tbo_obs_errhalt;
  logic [3:0] tbo_m_awid /*verilator public_flat_rw*/;
  assign m_awid = tbo_m_awid;
  logic [31:0] tbo_m_awaddr /*verilator public_flat_rw*/;
  assign m_awaddr = tbo_m_awaddr;
  logic [7:0] tbo_m_awlen /*verilator public_flat_rw*/;
  assign m_awlen = tbo_m_awlen;
  logic [2:0] tbo_m_awsize /*verilator public_flat_rw*/;
  assign m_awsize = tbo_m_awsize;
  logic [1:0] tbo_m_awburst /*verilator public_flat_rw*/;
  assign m_awburst = tbo_m_awburst;
  logic tbo_m_awvalid /*verilator public_flat_rw*/;
  assign m_awvalid = tbo_m_awvalid;
  logic tbi_m_awready /*verilator public_flat_rw*/;
  assign tbi_m_awready = m_awready;
  logic [63:0] tbo_m_wdata /*verilator public_flat_rw*/;
  assign m_wdata = tbo_m_wdata;
  logic [7:0] tbo_m_wstrb /*verilator public_flat_rw*/;
  assign m_wstrb = tbo_m_wstrb;
  logic tbo_m_wlast /*verilator public_flat_rw*/;
  assign m_wlast = tbo_m_wlast;
  logic tbo_m_wvalid /*verilator public_flat_rw*/;
  assign m_wvalid = tbo_m_wvalid;
  logic tbi_m_wready /*verilator public_flat_rw*/;
  assign tbi_m_wready = m_wready;
  logic [3:0] tbi_m_bid /*verilator public_flat_rw*/;
  assign tbi_m_bid = m_bid;
  logic [1:0] tbi_m_bresp /*verilator public_flat_rw*/;
  assign tbi_m_bresp = m_bresp;
  logic tbi_m_bvalid /*verilator public_flat_rw*/;
  assign tbi_m_bvalid = m_bvalid;
  logic tbo_m_bready /*verilator public_flat_rw*/;
  assign m_bready = tbo_m_bready;
  logic [31:0] tbo_m_araddr /*verilator public_flat_rw*/;
  assign m_araddr = tbo_m_araddr;
  logic [7:0] tbo_m_arlen /*verilator public_flat_rw*/;
  assign m_arlen = tbo_m_arlen;
  logic [2:0] tbo_m_arsize /*verilator public_flat_rw*/;
  assign m_arsize = tbo_m_arsize;
  logic [1:0] tbo_m_arburst /*verilator public_flat_rw*/;
  assign m_arburst = tbo_m_arburst;
  logic tbo_m_arvalid /*verilator public_flat_rw*/;
  assign m_arvalid = tbo_m_arvalid;
  logic tbi_m_arready /*verilator public_flat_rw*/;
  assign tbi_m_arready = m_arready;
  logic [63:0] tbi_m_rdata /*verilator public_flat_rw*/;
  assign tbi_m_rdata = m_rdata;
  logic [1:0] tbi_m_rresp /*verilator public_flat_rw*/;
  assign tbi_m_rresp = m_rresp;
  logic tbi_m_rlast /*verilator public_flat_rw*/;
  assign tbi_m_rlast = m_rlast;
  logic tbi_m_rvalid /*verilator public_flat_rw*/;
  assign tbi_m_rvalid = m_rvalid;
  logic tbo_m_rready /*verilator public_flat_rw*/;
  assign m_rready = tbo_m_rready;
  logic [6:0] tbi_period /*verilator public_flat_rw*/;
  assign tbi_period = period;
  logic [31:0] tbi_rtc_start /*verilator public_flat_rw*/;
  assign tbi_rtc_start = rtc_start;
  logic tbo_fd_doorbell /*verilator public_flat_rw*/;
  assign fd_doorbell = tbo_fd_doorbell;
  logic [15:0] tbo_fd_prod /*verilator public_flat_rw*/;
  assign fd_prod = tbo_fd_prod;
  logic tbo_fd_enabled /*verilator public_flat_rw*/;
  assign fd_enabled = tbo_fd_enabled;
  logic tbi_host_we /*verilator public_flat_rw*/;
  assign tbi_host_we = host_we;
  logic [3:0] tbi_host_widx /*verilator public_flat_rw*/;
  assign tbi_host_widx = host_widx;
  logic [31:0] tbi_host_wdata /*verilator public_flat_rw*/;
  assign tbi_host_wdata = host_wdata;
  logic [3:0] tbi_host_ridx /*verilator public_flat_rw*/;
  assign tbi_host_ridx = host_ridx;
  logic [31:0] tbo_host_rdata /*verilator public_flat_rw*/;
  assign host_rdata = tbo_host_rdata;
  logic tbi_eth_we /*verilator public_flat_rw*/;
  assign tbi_eth_we = eth_we;
  logic [4:0] tbi_eth_widx /*verilator public_flat_rw*/;
  assign tbi_eth_widx = eth_widx;
  logic [31:0] tbi_eth_wdata /*verilator public_flat_rw*/;
  assign tbi_eth_wdata = eth_wdata;
  logic [4:0] tbi_eth_ridx /*verilator public_flat_rw*/;
  assign tbi_eth_ridx = eth_ridx;
  logic [31:0] tbo_eth_rdata /*verilator public_flat_rw*/;
  assign eth_rdata = tbo_eth_rdata;
  logic [15:0] tbo_eth_tx_prod /*verilator public_flat_rw*/;
  assign eth_tx_prod = tbo_eth_tx_prod;
  logic [15:0] tbo_eth_rx_prod /*verilator public_flat_rw*/;
  assign eth_rx_prod = tbo_eth_rx_prod;
  logic tbi_kbd_strobe /*verilator public_flat_rw*/;
  assign tbi_kbd_strobe = kbd_strobe;
  logic [23:0] tbi_kbd_code /*verilator public_flat_rw*/;
  assign tbi_kbd_code = kbd_code;
  logic [6:0] tbi_mouse_lines /*verilator public_flat_rw*/;
  assign tbi_mouse_lines = mouse_lines;
  logic tbo_kbd_busy /*verilator public_flat_rw*/;
  assign kbd_busy = tbo_kbd_busy;
  logic tbo_axi_one_write_id /*verilator public_flat_rw*/;
  assign axi_one_write_id = tbo_axi_one_write_id;
  logic [3:0] tbo_axi_read_clocks /*verilator public_flat_rw*/;
  assign axi_read_clocks = tbo_axi_read_clocks;
  logic [3:0] tbo_axi_write_clocks /*verilator public_flat_rw*/;
  assign axi_write_clocks = tbo_axi_write_clocks;
  logic tbi_spy_we /*verilator public_flat_rw*/;
  assign tbi_spy_we = spy_we;
  logic [3:0] tbi_spy_eadr /*verilator public_flat_rw*/;
  assign tbi_spy_eadr = spy_eadr;
  logic [15:0] tbi_spy_wdata /*verilator public_flat_rw*/;
  assign tbi_spy_wdata = spy_wdata;
  logic [3:0] tbi_spy_raddr /*verilator public_flat_rw*/;
  assign tbi_spy_raddr = spy_raddr;
  logic [15:0] tbo_spy_rdata /*verilator public_flat_rw*/;
  assign spy_rdata = tbo_spy_rdata;
  logic [4:0] tbi_ro_sel /*verilator public_flat_rw*/;
  assign tbi_ro_sel = ro_sel;
  logic [63:0] tbo_ro_word /*verilator public_flat_rw*/;
  assign ro_word = tbo_ro_word;
  logic tbi_rm_en /*verilator public_flat_rw*/;
  assign tbi_rm_en = rm_en;
  logic tbi_rm_snap /*verilator public_flat_rw*/;
  assign tbi_rm_snap = rm_snap;
  logic [3:0] tbi_rm_sel /*verilator public_flat_rw*/;
  assign tbi_rm_sel = rm_sel;
  logic [13:0] tbi_rm_addr /*verilator public_flat_rw*/;
  assign tbi_rm_addr = rm_addr;
  logic [63:0] tbo_rm_word /*verilator public_flat_rw*/;
  assign rm_word = tbo_rm_word;
  logic [63:0] tbo_obs_committed /*verilator public_flat_rw*/;
  assign obs_committed = tbo_obs_committed;
  logic [47:0] tbo_obs_clocks /*verilator public_flat_rw*/;
  assign obs_clocks = tbo_obs_clocks;
  logic tbi_drive_present /*verilator public_flat_rw*/;
  assign tbi_drive_present = drive_present;
  logic tbi_store_we /*verilator public_flat_rw*/;
  assign tbi_store_we = store_we;
  logic [4:0] tbi_store_slot /*verilator public_flat_rw*/;
  assign tbi_store_slot = store_slot;
  logic [8:0] tbi_store_addr /*verilator public_flat_rw*/;
  assign tbi_store_addr = store_addr;
  logic [31:0] tbi_store_wdata /*verilator public_flat_rw*/;
  assign tbi_store_wdata = store_wdata;
  logic [31:0] tbo_store_rdata /*verilator public_flat_rw*/;
  assign store_rdata = tbo_store_rdata;
  logic tbo_store_miss /*verilator public_flat_rw*/;
  assign store_miss = tbo_store_miss;
  logic tbo_req_valid /*verilator public_flat_rw*/;
  assign req_valid = tbo_req_valid;
  logic [30:0] tbo_req_tag /*verilator public_flat_rw*/;
  assign req_tag = tbo_req_tag;
  logic tbo_req_post /*verilator public_flat_rw*/;
  assign req_post = tbo_req_post;
  logic tbo_ch_waiting /*verilator public_flat_rw*/;
  assign ch_waiting = tbo_ch_waiting;
  logic tbi_store_deny /*verilator public_flat_rw*/;
  assign tbi_store_deny = store_deny;
  logic [4:0] tbo_ch_slot /*verilator public_flat_rw*/;
  assign ch_slot = tbo_ch_slot;
  logic tbo_ch_wrote /*verilator public_flat_rw*/;
  assign ch_wrote = tbo_ch_wrote;
  logic tbo_ch_hit /*verilator public_flat_rw*/;
  assign ch_hit = tbo_ch_hit;
  logic tbo_ch_active /*verilator public_flat_rw*/;
  assign ch_active = tbo_ch_active;
  logic tbi_store_busy /*verilator public_flat_rw*/;
  assign tbi_store_busy = store_busy;
  logic [4:0] tbi_store_busy_slot /*verilator public_flat_rw*/;
  assign tbi_store_busy_slot = store_busy_slot;
  logic tbo_obs_transfer /*verilator public_flat_rw*/;
  assign obs_transfer = tbo_obs_transfer;
  logic tbo_bow /*verilator public_flat_rw*/;
  assign bow = tbo_bow;

endmodule

`default_nettype wire
