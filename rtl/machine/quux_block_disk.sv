// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// QUUX's block-disk: the CADR disk controller's programming interface with
// the drive's geometry taken out, `--disk-controller block-disk`.  muir's
// `block_disk::BlockDisk`, ported, and QUUX's only disk: `cadr_machine.sv`
// builds this in the CADR controller's place on QUUX, at the same four
// registers and on the same two seams.
//
//     17377774  <0> not active, <3> interrupt request, <9> no pack, <13>
//               stopped by error, <17> past the end of the pack, <20> NXM;
//               written, the command: 0 read, 11 write, <11> the done
//               interrupt's enable; a write clears the errors
//     17377775  read, the last memory address the command list made the disk
//               touch; written, the command list pointer
//     17377776  the disk address: a block number from the start of the pack,
//               <27:0>; after a transfer, the last block moved or the one
//               that failed
//     17377777  START, written; reads 0
//
// The command list is the CADR's: one word a block, `<23:8>` the page's
// physical address and `<0>` More, "only bits <15:0> of the CLP can count".
// A command other than read and write stops by error and moves nothing; a
// transfer past the pack's last block stops with `<17>`, and a command list
// word or a page that main memory does not answer for with `<20>`.  One
// pack, unit 0: `drive_present[0]` says a pack is on it.
//
// **THE TIME IS muir'S, `BLOCK_NS` A BLOCK MOVED**: not-active and the done
// interrupt come `BLOCK_NS` times the blocks moved after the START, 100 us
// each, **unverified** in muir ("an estimate until muir-fpga measures its
// disk path").  **WHAT THE FABRIC CANNOT DO IS MOVE THE WORDS AT THE START.**
// muir's words move inside the store at START and the controller is then
// busy for the blocks' time; here the walk runs over that time, a bus cycle
// a word, and the blocks come from the pack side, so the controller goes
// not-active at the later of muir's instant and the walk's end.  A walk
// whose block the pack side answers slowly, or one that fails on its first
// block --- which muir finds at START and leaves not-active at once --- is
// active here until the walk has found its outcome, a few microseconds; the
// errors, the disk address and the last memory address stand from the walk's
// end.  Microcode waits for the done interrupt, or polls not-active, so it
// sees only the later instant.
//
// **THE STORE AND ITS SEAM ARE THE CADR CONTROLLER'S**, so that
// `rtl/plumbing/cadr_disk_pack.sv` and `cadr-disk-packs` serve both: 24
// slots of a block, its header, its two checkwords and a tag, the tag written
// last and making the slot valid, bit 31 taking the block away; a block the
// walk lacks is asked for on `req_valid`/`req_tag` and waited for, and
// `store_deny` is the pack side saying it cannot give it --- which is how the
// end of the pack arrives here, the pack side knowing its size.  **The tag is
// the block number**, `{3'b0, lba<27:0>}`, where the CADR's is `{unit,
// cylinder, head, block}`: `cadr-disk-packs --machine quux` reads it so.
// The header and the checkwords are kept and handed back as they came: this
// controller checks none of them.
//
// What holds it: `build/quux_block_disk.quux.pass`, the module against
// muir's `BlockDisk` over a script of register reads and writes at muir's
// instants, the pack side and main memory answered by the testbench from
// images of their own, and every page and block compared at the end
// (`golden/src/quux_block_disk.rs`); and QUUX's boot PROM trace, which reads
// the registers with no pack (`build/machine.quux.k4.pass`).

`default_nettype none

module quux_block_disk #(
    parameter int unsigned SLOTS = 24,
    // muir's `block_disk::BLOCK_NS`, 100 us, on the grid.
    parameter int unsigned BLOCK_T = cadr_tick_pkg::ticks(100_000)
) (
    input  var logic        clk,
    input  var logic        rst,
    // `-XBUS INIT`: the command and the errors cleared, not-active.
    input  var logic        xbus_init,

    // The pack, unit 0's; the rest of the CADR's drive seam is not read.
    /* verilator lint_off UNUSEDSIGNAL */
    input  var logic [7:0]  drive_present,
    input  var logic [7:0]  drive_read_only,
    input  var logic        drive_timed,
    /* verilator lint_on UNUSEDSIGNAL */

    // The register face, as `cadr_disk_controller.sv`'s.
    input  var logic        sel,
    input  var logic        dev_rq,
    input  var logic        dev_write,
    input  var logic [21:0] phys,
    input  var logic [31:0] wdata,
    output var logic        dev_ack,
    output var logic [31:0] rdata,
    output var logic        drives,
    // The done interrupt, on the Xbus line as the CADR controller's is, and
    // word 100's `<2>`.
    output var logic        intr,

    // The block store's seam, as `cadr_disk_controller.sv`'s.
    input  var logic        store_we,
    input  var logic [4:0]  store_slot,
    input  var logic [8:0]  store_addr,
    input  var logic [31:0] store_wdata,
    output var logic [31:0] store_rdata,
    output var logic        store_miss,
    output var logic        req_valid,
    output var logic [30:0] req_tag,
    output var logic        req_post,
    output var logic        ch_waiting,
    input  var logic        store_deny,
    output var logic [4:0]  ch_slot_o,
    output var logic        ch_wrote,
    output var logic        ch_hit,

    // The memory channel, a master on the Xbus, as the CADR controller's.
    output var logic        ch_req,
    output var logic        ch_write,
    output var logic [21:0] ch_addr,
    output var logic [31:0] ch_wdata,
    input  var logic        ch_done,
    input  var logic        ch_nxm,
    input  var logic [31:0] ch_rdata,
    output var logic        ch_active,
    input  var logic        store_busy,
    input  var logic [4:0]  store_busy_slot
);

  localparam logic [19:0] REGS_PAGE   = 20'd1015807;   // 0o17377774 >> 2
  localparam int unsigned BLOCK_WORDS = 256;

  // ------------------------------------------------------- the block store

  logic [31:0] blk_ram [SLOTS*BLOCK_WORDS];
  logic [31:0] s_header [SLOTS];
  logic [31:0] s_hck    [SLOTS];
  logic [31:0] s_dck    [SLOTS];
  logic [30:0] s_tag    [SLOTS];
  logic [SLOTS-1:0] s_valid;

  logic [12:0] seam_word;
  logic [31:0] seam_meta;
  assign seam_word = 13'(store_slot) * 13'(BLOCK_WORDS) + 13'(store_addr[7:0]);
  always_comb begin
    unique case (store_addr[1:0])
      2'd0: seam_meta = s_header[store_slot];
      2'd1: seam_meta = s_hck[store_slot];
      2'd2: seam_meta = s_dck[store_slot];
      default: seam_meta = {1'b0, s_tag[store_slot]};
    endcase
  end

  // The seam's port, two ticks behind its address as the CADR store's is.
  logic [31:0] seam_q, seam_meta_q;
  logic        seam_meta_sel;
  always_ff @(posedge clk) begin
    if (store_we && store_addr < 9'(BLOCK_WORDS)) blk_ram[seam_word] <= store_wdata;
    seam_q <= blk_ram[seam_word];
  end
  always_ff @(posedge clk) begin
    seam_meta_q   <= seam_meta;
    seam_meta_sel <= store_addr >= 9'(BLOCK_WORDS);
    store_rdata   <= seam_meta_sel ? seam_meta_q : seam_q;
  end
  always_ff @(posedge clk) begin
    if (store_we && store_addr >= 9'(BLOCK_WORDS)) begin
      unique case (store_addr[1:0])
        2'd0: s_header[store_slot] <= store_wdata;
        2'd1: s_hck[store_slot]    <= store_wdata;
        2'd2: s_dck[store_slot]    <= store_wdata;
        default: begin
          if (store_wdata[31]) begin
            s_valid[store_slot] <= 1'b0;
          end else begin
            s_tag[store_slot]   <= store_wdata[30:0];
            s_valid[store_slot] <= 1'b1;
          end
        end
      endcase
    end
    if (rst) s_valid <= '0;
  end

  // The channel's port on the data words: the walk reads a word a tick after
  // its address, and writes one a word the channel brought.
  logic [4:0]  ch_slot;
  logic [7:0]  ch_w;
  logic        chb_we;
  logic [31:0] chb_d, chb_q;
  logic [12:0] ch_word, chb_a;
  assign ch_word = 13'(ch_slot) * 13'(BLOCK_WORDS) + 13'(ch_w);
  // A write goes to the word it was brought for, held with it: the walk has
  // moved on to the next by the tick it lands.  The port has one address, so
  // the tools can infer the block memory; the tick a write lands is in
  // `W_WRITE` or `W_END`, where nothing reads `chb_q`.
  logic [12:0] chb_port;
  assign chb_port = chb_we ? chb_a : ch_word;
  always_ff @(posedge clk) begin
    if (chb_we) blk_ram[chb_port] <= chb_d;
    chb_q <= blk_ram[chb_port];
  end

  // ------------------------------------------------------ the register face
  //
  // The match held one tick, `dev_ack` the held match, and a write taken
  // once a cycle at the first tick of `-XBUS.RQ`: `cadr_disk_controller.sv`'s
  // own face, and its notes are the reasons.
  logic       mine, taken;
  logic [1:0] which;
  logic       store_now;
  assign dev_ack   = mine;
  assign store_now = mine && dev_rq && dev_write && !taken;

  logic [31:0] cmd, clp, da, lma;
  logic        past_end, nxm, bad_command;
  // The time: ticks since the START, and what the blocks moved owe.
  logic [31:0] busy_ticks, due;
  logic        walking, walked;
  logic        not_active;
  assign not_active = !walking && (!walked || busy_ticks >= due);
  assign intr       = not_active && cmd[11];

  logic [31:0] status;
  assign status = {11'd0, nxm, 2'd0, past_end, 3'd0, past_end || nxm || bad_command,
                   3'd0, !drive_present[0], 5'd0, intr, 2'd0, not_active};

  logic [31:0] word;
  always_comb begin
    unique case (which)
      2'd0:    word = status;
      2'd1:    word = lma;
      2'd2:    word = da;
      default: word = 32'd0;
    endcase
  end
  assign drives = mine && !dev_write;
  assign rdata  = drives ? word : 32'd0;

  // ------------------------------------------------------------- the walk

  typedef enum logic [2:0] {
    W_IDLE, W_CCW, W_LOOK, W_WAIT, W_READ, W_WRITE, W_END
  } walk_e;
  walk_e       state;
  logic        writing;      // the command is a write
  logic [15:0] n;            // command list words taken
  logic [27:0] lba;
  logic [13:0] page;
  logic        more;
  logic        rd_valid;     // `chb_q` holds word `ch_w` of the slot

  // The lookup, registered: the slot holding `lba`, valid, and no move on it.
  logic [SLOTS-1:0] hit_q;
  logic             any_hit;
  logic [4:0]       hit_slot;
  always_ff @(posedge clk) begin
    for (int s = 0; s < SLOTS; s++)
      hit_q[s] <= s_valid[s] && (s_tag[s] == {3'b0, lba});
  end
  always_comb begin
    any_hit  = 1'b0;
    hit_slot = 5'd0;
    for (int s = SLOTS - 1; s >= 0; s--) begin
      if (hit_q[s]) begin
        any_hit  = 1'b1;
        hit_slot = 5'(s);
      end
    end
  end
  // A lookup is good two ticks after `lba` last moved.
  logic [1:0] look_age;

  assign ch_active  = state != W_IDLE && state != W_END;
  assign ch_waiting = state == W_WAIT;
  assign ch_slot_o  = ch_slot;
  assign req_tag    = {3'b0, lba};

  logic [15:0] clp_n;
  assign clp_n = clp[15:0] + n;

  always_ff @(posedge clk) begin
    if (rst || xbus_init) begin
      mine        <= 1'b0;
      which       <= 2'd0;
      taken       <= 1'b0;
      cmd         <= 32'd0;
      past_end    <= 1'b0;
      nxm         <= 1'b0;
      bad_command <= 1'b0;
      walking     <= 1'b0;
      walked      <= 1'b0;
      busy_ticks  <= 32'd0;
      due         <= 32'd0;
      state       <= W_IDLE;
      ch_req      <= 1'b0;
      ch_write    <= 1'b0;
      ch_addr     <= 22'd0;
      ch_wdata    <= 32'd0;
      chb_we      <= 1'b0;
      chb_d       <= 32'd0;
      chb_a       <= 13'd0;
      ch_slot     <= 5'd0;
      ch_w        <= 8'd0;
      req_valid   <= 1'b0;
      req_post    <= 1'b0;
      ch_wrote    <= 1'b0;
      ch_hit      <= 1'b0;
      store_miss  <= 1'b0;
      writing     <= 1'b0;
      n           <= 16'd0;
      lba         <= 28'd0;
      page        <= 14'd0;
      more        <= 1'b0;
      rd_valid    <= 1'b0;
      look_age    <= 2'd0;
      if (rst) begin
        // The disk address, the pointer and the last memory address have no
        // pin on `-XBUS INIT`; zero at power-on is this fabric's convention.
        clp <= 32'd0;
        da  <= 32'd0;
        lma <= 32'd0;
      end
    end else begin
      mine     <= sel && (phys[21:2] == REGS_PAGE);
      which    <= phys[1:0];
      req_post <= 1'b0;
      ch_wrote <= 1'b0;
      ch_hit   <= 1'b0;
      chb_we   <= 1'b0;
      if (busy_ticks != 32'hFFFF_FFFF) busy_ticks <= busy_ticks + 32'd1;
      if (look_age != 2'd2) look_age <= look_age + 2'd1;

      if (store_now) taken <= 1'b1;
      else if (!(mine && dev_rq)) taken <= 1'b0;

      // --- a register written ---------------------------------------------
      if (store_now) begin
        unique case (which)
          2'd0: begin
            cmd         <= wdata;
            past_end    <= 1'b0;
            nxm         <= 1'b0;
            bad_command <= 1'b0;
          end
          2'd1: clp <= wdata;
          2'd2: da  <= {4'd0, wdata[27:0]};
          default: begin
            // START.  A command it does not do stops by error and moves
            // nothing; with no pack nothing happens at all; a transfer
            // walks.  One at a time: a START while a walk runs is not
            // taken, where muir would run the second at once.
            past_end    <= 1'b0;
            nxm         <= 1'b0;
            bad_command <= 1'b0;
            if (cmd[3:0] != 4'o00 && cmd[3:0] != 4'o11) begin
              bad_command <= 1'b1;
            end else if (drive_present[0] && state == W_IDLE) begin
              writing    <= cmd[3:0] == 4'o11;
              walking    <= 1'b1;
              walked     <= 1'b1;
              // One at the tick after the START: in the tick `m` after it,
              // `m` have passed, and muir's instant is `due` of them on.
              busy_ticks <= 32'd1;
              due        <= 32'd0;
              n          <= 16'd0;
              lba        <= da[27:0];
              look_age   <= 2'd0;
              state      <= W_CCW;
            end
          end
        endcase
      end

      unique case (state)
        W_IDLE: ;
        // --- a command list word, at the pointer counted in its low sixteen
        W_CCW: begin
          if (!ch_req) begin
            lma <= {clp[31:16], clp_n};
            if (clp[31:22] != 10'd0) begin
              // No main memory answers above twenty-two bits.
              nxm   <= 1'b1;
              state <= W_END;
            end else begin
              ch_req   <= 1'b1;
              ch_write <= 1'b0;
              ch_addr  <= {clp[21:16], clp_n};
            end
          end else if (ch_done) begin
            ch_req <= 1'b0;
            if (ch_nxm) begin
              nxm   <= 1'b1;
              state <= W_END;
            end else begin
              page     <= ch_rdata[21:8];
              more     <= ch_rdata[0];
              look_age <= 2'd0;
              state    <= W_LOOK;
            end
          end
        end
        // --- the block, in the store or asked for
        W_LOOK: begin
          if (look_age == 2'd2) begin
            if (any_hit && !(store_busy && store_busy_slot == hit_slot)) begin
              ch_slot  <= hit_slot;
              ch_hit   <= 1'b1;
              ch_w     <= 8'd0;
              rd_valid <= 1'b0;
              state    <= writing ? W_WRITE : W_READ;
            end else if (!any_hit) begin
              req_valid <= 1'b1;
              req_post  <= 1'b1;
              state     <= W_WAIT;
            end
          end
        end
        W_WAIT: begin
          if (store_deny) begin
            // The pack side cannot give it: past the end of the pack.
            req_valid <= 1'b0;
            past_end  <= 1'b1;
            state     <= W_END;
          end else if (store_we && store_addr == 9'd259 && !store_wdata[31]
                       && store_wdata[30:0] == {3'b0, lba}) begin
            req_valid <= 1'b0;
            look_age  <= 2'd0;
            state     <= W_LOOK;
          end
        end
        // --- a read: the slot's words into memory, a bus cycle each
        W_READ: begin
          if (!ch_req) begin
            if (rd_valid) begin
              ch_req   <= 1'b1;
              ch_write <= 1'b1;
              ch_addr  <= {page, ch_w};
              ch_wdata <= chb_q;
              rd_valid <= 1'b0;
            end else begin
              rd_valid <= 1'b1;   // `chb_q` takes word `ch_w` this tick
            end
          end else if (ch_done) begin
            ch_req <= 1'b0;
            if (ch_nxm) begin
              nxm   <= 1'b1;
              state <= W_END;
            end else if (ch_w == 8'd255) begin
              state <= W_END;   // replaced below, the block done
            end else begin
              ch_w <= ch_w + 8'd1;
            end
          end
        end
        // --- a write: memory's words into the slot, a bus cycle each
        W_WRITE: begin
          if (!ch_req) begin
            ch_req   <= 1'b1;
            ch_write <= 1'b0;
            ch_addr  <= {page, ch_w};
          end else if (ch_done) begin
            ch_req <= 1'b0;
            if (ch_nxm) begin
              nxm   <= 1'b1;
              state <= W_END;
            end else begin
              chb_we <= 1'b1;
              chb_d  <= ch_rdata;
              chb_a  <= ch_word;
              if (ch_w == 8'd255) begin
                ch_wrote <= 1'b1;
                state    <= W_END;   // replaced below, the block done
              end else begin
                ch_w <= ch_w + 8'd1;
              end
            end
          end
        end
        default: begin
          // W_END: the disk address where the walk left it, and the time.
          da      <= {4'd0, lba};
          walking <= 1'b0;
          state   <= W_IDLE;
        end
      endcase

      // --- a block moved whole: the time it owes, and the next ------------
      if ((state == W_READ || state == W_WRITE) && ch_req && ch_done && !ch_nxm
          && ch_w == 8'd255) begin
        lma <= {10'd0, page, 8'd255};
        due <= due + 32'(BLOCK_T);
        if (more) begin
          n        <= n + 16'd1;
          lba      <= lba + 28'd1;
          look_age <= 2'd0;
          state    <= W_CCW;
        end
      end
    end
  end

  logic unused;
  assign unused = ^{cmd[31:12], cmd[10:4]};

endmodule

`default_nettype wire
