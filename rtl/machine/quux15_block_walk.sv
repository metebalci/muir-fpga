// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **QUUX REVISION 15'S BLOCK-DISK WALK AND BLOCK STORE** (contract G2 §4.2,
// appendix A1.10 and A1.11; G3 revision 15, A15b.5, A15b.6): what moves a
// START's pages between main memory and the pack.  muir's
// `block_disk::BlockDisk::write` is the reference.  The registers, DONE and
// the done interrupt are `quux15_devices.sv`'s, at revision 15's timing;
// this module is started by START and hands back what the transfer leaves:
// the last memory address, the disk address, the errors, and a pulse for
// each block moved, whose time `quux15_devices.sv` owes.
//
// **THE STORE, ITS SEAM AND THE WALK ARE REVISION 13'S**
// (`quux_block_disk.sv`'s `g_walk13`, which revisions 13 and 14 keep), so
// that `rtl/plumbing/cadr_disk_pack.sv` and `cadr-disk-packs --machine quux`
// serve this one unchanged: 24 slots of a block, its header, its two
// checkwords and a tag, the tag written last and making the slot valid, bit
// 31 taking the block away; a block the walk lacks is asked for on
// `req_valid`/`req_tag` and waited for, and `store_deny` is the pack side
// saying it cannot give it, which is how the end of the pack arrives here.
// The tag is the block number, `{3'b0, lba<27:0>}`.
//
// An entry of the command list moves a 1024-word page, `<27:10>`, and
// command `<12>` chooses how its words lie on the disk.  Packed, 5 blocks a
// page, word w at the page's bytes 5w to 5w + 4, `<7:0>` first and the tag
// last; 4-byte, 4 blocks, `<31:0>` at bytes 4w to 4w + 3, a read writing tag
// `005` and a write dropping the tag.  The store's blocks are 256 32-bit
// words, so the page goes through a byte queue of eight: a store word in is
// four bytes, a memory word out four or five, and the queue carries the
// bytes a block ends with into the next.  **A READ ASKS FOR ALL ITS PAGE'S
// BLOCKS BEFORE IT WRITES A WORD OF MEMORY**, muir's "a page is read whole
// before memory is written": a block past the end then stops it with the
// page as it was, the blocks found before it charged their time.  A write
// moves block by block, and the blocks before one past the end are written,
// as muir's are.  A block past the 28 bits of the disk address, 2^28 and up,
// is past the end of every pack, and is never asked for.  The disk address
// is left at the last block moved or the one that failed, 29 bits.
//
// **WHAT REVISION 15 CHANGES**:
//   - **MAIN MEMORY IS REVISION 15'S PORT** (`quux15_port.sv`'s D), a word
//     at a time: a write is queued behind the processor's queued writes and
//     clears its cache set; a read bypasses the cache under the read rule
//     (A15b.5, A15b.6).  The port answers no NXM: main memory is `MAIN_WORDS`
//     from 0, so an entry's address or its page past it is NXM here, before
//     anything is asked for, as muir's `main.get(clp)` and `page + PAGE >
//     main.len()` find it.  Revision 13's read of the page's word 0, which
//     learned it from the channel, is gone.
//   - **NO TIME IS KEPT HERE**: a block moved is a `charge`, and
//     `quux15_devices.sv` owes `BLOCK_NS` for it on the machine's own time
//     (A15b.12), so that DONE is rounded once, at the end, as muir's is.
//   - **RESET-DEVICES DOES NOT STOP A WALK**: muir moves every page at START,
//     so the walk runs its command list to the end whatever comes after; the
//     registers are `quux15_devices.sv`'s to reset.
//
// What holds it: `build/quux15_block_walk.quux.pass`, this module against
// muir's `BlockDisk` over `golden/src/quux13_block_disk.rs`'s scripts, the
// pack side and main memory the testbench's; and the core's block-disk
// goldens (`golden/src/quux15_blockdisk.rs`), through the port.

`default_nettype none

module quux15_block_walk #(
    parameter int unsigned SLOTS = 24,
    // Main memory's words, from 0 (`quux15_core.sv`'s).
    parameter int unsigned MAIN_WORDS = 32'h0020_0000
) (
    input  var logic        clk,
    input  var logic        rst,

    // START taken this clock: the command, the command list pointer and the
    // disk address as the registers have them.  Taken only while idle.
    input  var logic        start,
    input  var logic [31:0] st_cmd,
    input  var logic [27:0] st_clp,
    input  var logic [27:0] st_da,
    // The walk runs: from the clock after its START to its end.
    output var logic        walking,
    // A block moved this clock, whose time is owed.
    output var logic        charge,
    // The walk ends this clock, and what it leaves: the last memory address
    // the command list made it touch, the disk address (the last block moved
    // or the one that failed, 29 bits), and the errors.
    output var logic        fin,
    output var logic [27:0] fin_lma,
    output var logic [28:0] fin_da,
    output var logic        fin_past_end,
    output var logic        fin_nxm,

    // The pack, unit 0's.
    input  var logic        drive_present,

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
    output var logic        ch_active,
    input  var logic        store_busy,
    input  var logic [4:0]  store_busy_slot,

    // Main memory through the port, a word at a time: the request held
    // until `d_done`, a read's word with it.
    output var logic        d_req,
    output var logic        d_write,
    output var logic [27:0] d_addr,
    output var logic [39:0] d_wdata,
    input  var logic        d_done,
    input  var logic [39:0] d_rdata
);

  localparam int unsigned BLOCK_WORDS = 256;
  localparam logic [28:0] MAIN_END = 29'(MAIN_WORDS);

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

  // The seam's port, two clocks behind its address as the CADR store's is.
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

  // The walk's port on the data words: it reads a word a clock after its
  // address, and writes one a word the channel brought, held with it: the
  // walk has moved on to the next by the clock it lands.  One address, so
  // that the tools infer the block memory; the clock a write lands is in
  // `V_WRITE` or `V_END`, where nothing reads `chb_q`.
  logic [4:0]  ch_slot;
  logic [7:0]  ch_w;
  logic        chb_we;
  logic [31:0] chb_d, chb_q;
  logic [12:0] ch_word, chb_a, chb_port;
  assign ch_word  = 13'(ch_slot) * 13'(BLOCK_WORDS) + 13'(ch_w);
  assign chb_port = chb_we ? chb_a : ch_word;
  always_ff @(posedge clk) begin
    if (chb_we) blk_ram[chb_port] <= chb_d;
    chb_q <= blk_ram[chb_port];
  end

  // ------------------------------------------------------------- the walk

  logic        writing;      // the command is a write
  logic [15:0] n;            // command list entries taken
  logic [27:0] lba;          // the block looked up
  logic        more;
  logic        rd_valid;     // `chb_q` holds word `ch_w` of the slot
  logic [27:0] clp;          // the command list pointer at START
  logic [27:0] lma;
  logic        past_end, nxm;

  // The lookup, registered: the slot holding `lba`, valid.
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
  // A lookup is good two clocks after `lba` last moved.
  logic [1:0] look_age;

  assign ch_slot_o = ch_slot;
  assign req_tag   = {3'b0, lba};

  // The entry's address: "only bits <15:0> of the CLP can count".
  logic [15:0] clp_n;
  logic [27:0] ccw_addr;
  assign clp_n    = clp[15:0] + n;
  assign ccw_addr = {clp[27:16], clp_n};

  typedef enum logic [3:0] {
    V_IDLE, V_CCW, V_GLOOK, V_GWAIT, V_LOOK, V_WAIT, V_READ, V_WRITE, V_END
  } walk_e;
  walk_e       v;
  logic        four;         // the 4-byte transfer, command <12> at START
  logic [17:0] page;         // the page, <27:10> of its entry
  logic [28:0] base;         // the page's first block
  logic [2:0]  k;            // the block of the page
  logic [28:0] cur;          // base + k
  logic [9:0]  mw;           // the page's next word
  logic [63:0] sb;           // the byte queue, its first byte in <7:0>
  logic [3:0]  sn;           // the bytes in it
  logic        drained_blk;  // every word of the block in the slot taken
  logic [2:0]  per_page;
  assign per_page  = four ? 3'd4 : 3'd5;
  assign cur       = base + 29'(k);
  assign ch_active = v != V_IDLE && v != V_END;
  assign ch_waiting = v == V_WAIT || v == V_GWAIT;
  assign walking   = v != V_IDLE;

  // The page main memory has: 1024 words below `MAIN_WORDS`.
  logic page_ok;
  assign page_ok = {1'b0, d_rdata[27:10], 10'd0} < MAIN_END;

  always_ff @(posedge clk) begin
    if (rst) begin
      v           <= V_IDLE;
      d_req       <= 1'b0;
      d_write     <= 1'b0;
      d_addr      <= '0;
      d_wdata     <= '0;
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
      charge      <= 1'b0;
      fin         <= 1'b0;
      writing     <= 1'b0;
      four        <= 1'b0;
      n           <= 16'd0;
      lba         <= 28'd0;
      clp         <= 28'd0;
      lma         <= 28'd0;
      past_end    <= 1'b0;
      nxm         <= 1'b0;
      page        <= 18'd0;
      base        <= 29'd0;
      k           <= 3'd0;
      mw          <= 10'd0;
      sb          <= 64'd0;
      sn          <= 4'd0;
      drained_blk <= 1'b0;
      more        <= 1'b0;
      rd_valid    <= 1'b0;
      look_age    <= 2'd0;
    end else begin
      req_post <= 1'b0;
      ch_wrote <= 1'b0;
      ch_hit   <= 1'b0;
      chb_we   <= 1'b0;
      charge   <= 1'b0;
      fin      <= 1'b0;
      if (look_age != 2'd2) look_age <= look_age + 2'd1;

      // --- START: a read (0) or a write (11), a pack on unit 0, the walk
      // idle; `quux15_devices.sv` sends no other.
      if (start && v == V_IDLE && drive_present) begin
        writing  <= st_cmd[3:0] == 4'o11;
        four     <= st_cmd[12];
        n        <= 16'd0;
        clp      <= st_clp;
        base     <= {1'b0, st_da};
        k        <= 3'd0;
        past_end <= 1'b0;
        nxm      <= 1'b0;
        look_age <= 2'd0;
        v        <= V_CCW;
      end

      unique case (v)
        V_IDLE: ;
        // --- the entry, at the pointer counted in its low sixteen bits; an
        // entry or a page past main memory's end is NXM, asked for nothing.
        V_CCW: begin
          if (!d_req) begin
            lma <= ccw_addr;
            if ({1'b0, ccw_addr} >= MAIN_END) begin
              nxm <= 1'b1;
              v   <= V_END;
            end else begin
              d_req   <= 1'b1;
              d_write <= 1'b0;
              d_addr  <= ccw_addr;
            end
          end else if (d_done) begin
            d_req       <= 1'b0;
            page        <= d_rdata[27:10];
            more        <= d_rdata[0];
            k           <= 3'd0;
            mw          <= 10'd0;
            sb          <= 64'd0;
            sn          <= 4'd0;
            look_age    <= 2'd0;
            if (!page_ok) begin
              nxm <= 1'b1;
              v   <= V_END;
            end else begin
              v <= writing ? V_LOOK : V_GLOOK;
            end
          end
        end
        // --- a read: every block of the page there, or the one past the end
        V_GLOOK: begin
          if (cur[28]) begin
            past_end <= 1'b1;
            v        <= V_END;
          end else if (look_age == 2'd2 && lba == cur[27:0]) begin
            if (any_hit) begin
              // Found, and its time owed: muir charges a block read.
              charge   <= 1'b1;
              look_age <= 2'd0;
              if (k == per_page - 3'd1) begin
                k <= 3'd0;
                v <= V_LOOK;
              end else begin
                k <= k + 3'd1;
              end
            end else begin
              req_valid <= 1'b1;
              req_post  <= 1'b1;
              v         <= V_GWAIT;
            end
          end
        end
        V_GWAIT: begin
          if (store_deny) begin
            past_end  <= 1'b1;
            req_valid <= 1'b0;
            v         <= V_END;
          end else if (store_we && store_addr == 9'd259 && !store_wdata[31]
                       && store_wdata[30:0] == {3'b0, lba}) begin
            req_valid <= 1'b0;
            look_age  <= 2'd0;
            v         <= V_GLOOK;
          end
        end
        // --- the block into a slot, to move its words
        V_LOOK: begin
          if (cur[28]) begin
            past_end <= 1'b1;
            v        <= V_END;
          end else if (look_age == 2'd2 && lba == cur[27:0]) begin
            if (any_hit && !(store_busy && store_busy_slot == hit_slot)) begin
              ch_slot     <= hit_slot;
              ch_hit      <= 1'b1;
              ch_w        <= 8'd0;
              rd_valid    <= 1'b0;
              drained_blk <= 1'b0;
              v           <= writing ? V_WRITE : V_READ;
            end else if (!any_hit) begin
              req_valid <= 1'b1;
              req_post  <= 1'b1;
              v         <= V_WAIT;
            end
          end
        end
        V_WAIT: begin
          if (store_deny) begin
            past_end  <= 1'b1;
            req_valid <= 1'b0;
            v         <= V_END;
          end else if (store_we && store_addr == 9'd259 && !store_wdata[31]
                       && store_wdata[30:0] == {3'b0, lba}) begin
            req_valid <= 1'b0;
            look_age  <= 2'd0;
            v         <= V_LOOK;
          end
        end
        // --- a read: the slot's words through the queue into memory
        V_READ: begin
          if (!d_req) begin
            if (sn >= 4'(per_page)) begin
              d_req   <= 1'b1;
              d_write <= 1'b1;
              d_addr  <= {page, mw};
              d_wdata <= four ? {8'o005, sb[31:0]} : sb[39:0];
              sb      <= four ? sb >> 32 : sb >> 40;
              sn      <= sn - 4'(per_page);
            end else if (drained_blk) begin
              // The block's words all taken: the next block of the page.
              k        <= k + 3'd1;
              look_age <= 2'd0;
              v        <= V_LOOK;
            end else if (rd_valid) begin
              sb       <= sb | (64'(chb_q) << {sn, 3'b000});
              sn       <= sn + 4'd4;
              rd_valid <= 1'b0;
              if (ch_w == 8'd255) drained_blk <= 1'b1;
              else ch_w <= ch_w + 8'd1;
            end else begin
              rd_valid <= 1'b1;   // `chb_q` takes word `ch_w` this clock
            end
          end else if (d_done) begin
            d_req <= 1'b0;
            mw    <= mw + 10'd1;
            if (mw == 10'd1023) v <= V_END;   // replaced below, the page done
          end
        end
        // --- a write: memory's words through the queue into the slot
        V_WRITE: begin
          if (sn >= 4'd4 && !d_req) begin
            chb_we <= 1'b1;
            chb_d  <= sb[31:0];
            chb_a  <= ch_word;
            sb     <= sb >> 32;
            sn     <= sn - 4'd4;
            if (ch_w == 8'd255) begin
              // The block written: dirty, and its time owed.
              ch_wrote <= 1'b1;
              charge   <= 1'b1;
              if (k == per_page - 3'd1) begin
                v <= V_END;   // replaced below, the page done
              end else begin
                k        <= k + 3'd1;
                look_age <= 2'd0;
                v        <= V_LOOK;
              end
            end else begin
              ch_w <= ch_w + 8'd1;
            end
          end else if (!d_req) begin
            d_req   <= 1'b1;
            d_write <= 1'b0;
            d_addr  <= {page, mw};
          end else if (d_done) begin
            d_req <= 1'b0;
            sb    <= sb | ((four ? 64'(d_rdata[31:0]) : 64'(d_rdata)) << {sn, 3'b000});
            sn    <= sn + 4'(per_page);
            mw    <= mw + 10'd1;
          end
        end
        default: begin
          // V_END: what the walk leaves, handed over.
          fin <= 1'b1;
          v   <= V_IDLE;
        end
      endcase

      // --- a page moved whole: its last word the last memory address, and
      // --- the next entry.
      if ((v == V_READ && d_req && d_done && mw == 10'd1023)
          || (v == V_WRITE && sn >= 4'd4 && !d_req && ch_w == 8'd255 && k == per_page - 3'd1)) begin
        lma <= {page, 10'h3FF};
        if (more) begin
          n        <= n + 16'd1;
          base     <= base + 29'(per_page);
          k        <= 3'd0;
          look_age <= 2'd0;
          v        <= V_CCW;
        end
      end

      // The lookup follows the block: `lba` is `cur` a clock later, and a
      // lookup of it good two clocks after that.
      if (lba != cur[27:0]) begin
        lba      <= cur[27:0];
        look_age <= 2'd0;
      end
    end
  end

  assign fin_lma      = lma;
  assign fin_da       = cur;
  assign fin_past_end = past_end;
  assign fin_nxm      = nxm;

  logic unused;
  assign unused = ^{st_cmd[31:13], st_cmd[11:4], d_rdata[39:28], d_rdata[9:1]};

endmodule

`default_nettype wire
