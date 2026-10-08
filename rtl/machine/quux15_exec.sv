// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// **REVISION 15'S EX DATAPATH** (contract G3 revision 15, appendix A15b): what
// a word computes in EX, combinationally, from its operands --- the ALU, the
// output select, `Q`'s step, the fixnum overflow flag and LC's adder; BYTE's
// rotator and masker; a JUMP's condition; a DISPATCH's address --- for
// `quux15_core.sv`, which owns the registers, the memories and the stages.
//
// It is revision 14's QUUX datapath at 40 bits, `cadr_microcycle.sv`'s
// (`WORD_BITS` 40, `REVISION` 14), taken out of that file's single-edge
// microcycle and written as functions of a word and its operands; that file
// is untouched.  muir's `src/pipeline/exec.rs` is the reference, line for
// line: `alu`, `byte`, `jump_condition` and `dispatch`'s address, on
// `ttl::alu_control`, `ttl::alu`, `ttl::alu_tag` and `ttl::lc_high`.
//
// `ir` is `IR<47:0>` with the word's OA selects applied (A15b.15).  `m` is the
// M operand as the word reads it, M memory's word or a functional source's;
// `a` the A operand.  MUL and DIV (`quux_muldiv.sv`) are the core's, whose
// results come in here only to reach the output bus and `Q`.

`default_nettype none

module quux15_exec (
    input  var logic [47:0] ir,
    input  var logic [39:0] m,
    input  var logic [39:0] a,
    input  var logic [39:0] q,
    // LC's counter and byte mode, for LC's rotation (A1.2).
    input  var logic [33:0] lc,
    input  var logic        byte_mode,
    // The fixnum overflow flag as the word before left it (condition 10).
    input  var logic        overflow,
    // Conditions 4-6: VMAOK, an interrupt pending under its enable, a
    // sequence break.
    input  var logic        vmaok,
    input  var logic        int_pending,
    input  var logic        sequence_break,
    // A map-bit dispatch's bits, `{<23>, <22>}` of the entry port B
    // translated `MD` through, both 1 for an `MD` that is not a pointer.
    input  var logic [1:0]  map_bits,
    // MUL's and DIV's words, the core's divider's.
    input  var logic [31:0] mul_ob,
    input  var logic [31:0] mul_q,
    input  var logic [31:0] div_ob,
    input  var logic [31:0] div_q,
    // An ALU or BYTE word's output bus, which its destination takes.
    output var logic [39:0] ob,
    // `Q` after an ALU word.
    output var logic [39:0] q_alu,
    // The fixnum overflow flag after an ALU word.
    output var logic        overflow_alu,
    // `LC<33:32>` an LC write takes from an ALU word: the adder's, when
    // `lc_adder` (A14.11), and otherwise the word's own.
    output var logic        lc_adder,
    output var logic [1:0]  lc_high,
    // A JUMP's condition, before its invert.
    output var logic        jcond,
    // A DISPATCH's address into dispatch memory, its map bits not yet in.
    output var logic [11:0] daddr,
    // MUL or DIV, decoded from the word EX runs.
    output var logic        is_mul,
    output var logic        is_div
);

  logic [1:0] cls;
  assign cls = ir[44:43];
  logic iralu, irjump;
  assign iralu  = cls == 2'd0;
  assign irjump = cls == 2'd1;

  // --- The ring of 40 and LC's rotation (A1.2; muir's `rol40`,
  // `lc_rotation_at`).
  function automatic logic [5:0] mod40(input logic [6:0] k);
    if (k >= 7'd80) return 6'(k - 7'd80);
    if (k >= 7'd40) return 6'(k - 7'd40);
    return 6'(k);
  endfunction
  function automatic logic [39:0] rol40(input logic [39:0] v, input logic [5:0] k);
    logic [5:0] s;
    s = mod40({1'b0, k});
    if (s == 6'd0) return v;
    return (v << s) | (v >> (6'd40 - s));
  endfunction
  function automatic logic [5:0] lc_rotation(input logic [5:0] rotate);
    logic [5:0] add;
    if (byte_mode) begin
      unique case (lc[1:0])
        2'd0: add = 6'd16;
        2'd1: add = 6'd0;
        2'd2: add = 6'd32;
        default: add = 6'd24;
      endcase
    end else begin
      add = lc[1] ? 6'd0 : 6'd24;
    end
    return mod40({1'b0, rotate} + {1'b0, add});
  endfunction
  // muir's `mask40`: `n` + 1 ones from `right`, none when they do not fit.
  function automatic logic [39:0] mask40(input logic [5:0] right, input logic [5:0] n);
    logic [6:0] top;
    top = {1'b0, right} + {1'b0, n};
    if (top > 7'd39) return 40'd0;
    return ({40{1'b1}} >> (6'd39 - n)) << right;
  endfunction

  // --- MUL and DIV (`muldiv::decode`): an ALU word with `IR<8>` and
  // `IR<4:3>` 2 or 3.
  assign is_mul = iralu && ir[8] && ir[4:3] == 2'd2;
  assign is_div = iralu && ir[8] && ir[4:3] == 2'd3;

  // --- Page ALUC4 (`ttl::alu_control`), for an ALU word or a JUMP.
  logic specalu, mul_step, div_step, divpos, divsub, divadd, mulnop, aluadd, alusub;
  assign specalu  = ir[8] && iralu;
  assign mul_step = specalu && ir[4:3] == 2'b00;
  assign div_step = specalu && ir[4:3] == 2'b01;
  assign divpos   = q[0] || ir[6];
  assign divsub   = div_step && divpos;
  assign divadd   = div_step && (ir[5] || !divpos);
  assign mulnop   = mul_step && !q[0];
  assign aluadd   = (divadd && !a[31]) || (divsub && a[31]) || mul_step;
  assign alusub   = mulnop || (divsub && !a[31]) || (divadd && a[31]) || irjump;

  logic [3:0] aluf;
  logic       alumode, cin;
  always_comb begin
    unique case ({alusub, aluadd})
      2'b00:   begin aluf = {ir[3], ir[4], !ir[6], !ir[5]}; alumode = !ir[7]; cin = ir[2];   end
      2'b01:   begin aluf = 4'b1001;                        alumode = 1'b0;   cin = 1'b0;    end
      2'b10:   begin aluf = 4'b0110;                        alumode = 1'b0;   cin = !irjump; end
      default: begin aluf = 4'b1111;                        alumode = 1'b1;   cin = 1'b1;    end
    endcase
  end

  // --- The 74S181 array over the fields, sign-extended to 33 bits
  // (`ttl::alu`).
  logic [32:0] x, y, p, s, f;
  assign x = {m[31], m[31:0]};
  assign y = {a[31], a[31:0]};
  always_comb begin
    p = 33'd0;
    s = 33'd0;
    if (alumode) begin
      unique case (aluf)
        4'h0: p = ~x;
        4'h1: p = ~(x | y);
        4'h2: p = ~x & y;
        4'h3: p = 33'd0;
        4'h4: p = ~(x & y);
        4'h5: p = ~y;
        4'h6: p = x ^ y;
        4'h7: p = x & ~y;
        4'h8: p = ~x | y;
        4'h9: p = ~(x ^ y);
        4'ha: p = y;
        4'hb: p = x & y;
        4'hc: p = {33{1'b1}};
        4'hd: p = x | ~y;
        4'he: p = x | y;
        default: p = x;
      endcase
    end else begin
      unique case (aluf)
        4'h0: begin p = x;          s = 33'd0;       end
        4'h1: begin p = x | y;      s = 33'd0;       end
        4'h2: begin p = x | ~y;     s = 33'd0;       end
        4'h3: begin p = {33{1'b1}}; s = 33'd0;       end
        4'h4: begin p = x;          s = x & ~y;      end
        4'h5: begin p = x | y;      s = x & ~y;      end
        4'h6: begin p = x;          s = ~y;          end
        4'h7: begin p = x & ~y;     s = {33{1'b1}};  end
        4'h8: begin p = x;          s = x & y;       end
        4'h9: begin p = x;          s = y;           end
        4'ha: begin p = x | ~y;     s = x & y;       end
        4'hb: begin p = x & y;      s = {33{1'b1}};  end
        4'hc: begin p = x;          s = x;           end
        4'hd: begin p = x | y;      s = x;           end
        4'he: begin p = x | ~y;     s = x;           end
        default: begin p = x;       s = {33{1'b1}};  end
      endcase
    end
  end
  assign f = alumode ? p : (p + s + {32'd0, cin});
  logic aeqm;
  assign aeqm = &f[31:0];

  // --- The tag, `<39:32>` (`ttl::alu_tag`): a logical function's of M's and
  // A's, the same table; an arithmetic one's M's.
  logic [7:0] tx, ty, tf;
  assign tx = m[39:32];
  assign ty = a[39:32];
  always_comb begin
    unique case (aluf)
      4'h0: tf = ~tx;
      4'h1: tf = ~(tx | ty);
      4'h2: tf = ~tx & ty;
      4'h3: tf = 8'd0;
      4'h4: tf = ~(tx & ty);
      4'h5: tf = ~ty;
      4'h6: tf = tx ^ ty;
      4'h7: tf = tx & ~ty;
      4'h8: tf = ~tx | ty;
      4'h9: tf = ~(tx ^ ty);
      4'ha: tf = ty;
      4'hb: tf = tx & ty;
      4'hc: tf = 8'hff;
      4'hd: tf = tx | ~ty;
      4'he: tf = tx | ty;
      default: tf = tx;
    endcase
  end
  logic [39:0] mtag, alu_out;
  assign mtag    = {tx, 32'd0};
  assign alu_out = {alumode ? tf : tx, f[31:0]};

  // --- An ALU word (`Pipeline::alu`).
  logic [1:0]  osel;
  logic [39:0] masked;
  assign osel   = ir[13:12];
  assign masked = (rol40(m, ir[5:0]) & mask40(ir[5:0], {2'd0, ir[9:6]}))
                | (a & ~mask40(ir[5:0], {2'd0, ir[9:6]}));

  // LC's adder (A14.11, `ttl::lc_high`): E = (M<33:32> + 3 s32 + c32) mod 4.
  logic       c32;
  logic [1:0] lc_e;
  assign c32      = f[32] ^ p[32] ^ s[32];
  assign lc_e     = m[33:32] + {s[32], s[32]} + {1'b0, c32};
  assign lc_adder = iralu && !alumode && !is_mul && !is_div && osel[0];
  assign lc_high  = osel[1] ? {lc_e[0], f[31]} : lc_e;

  // The fixnum overflow flag: an arithmetic function, `IR<8:7>` 01, whose
  // 33-bit result's bit 32 is unlike its bit 31.
  assign overflow_alu = ir[8:7] == 2'b01 && f[32] != f[31];

  logic [39:0] ob_alu, ob_byte;
  always_comb begin
    unique case (osel)
      2'd0:    ob_alu = masked;
      2'd1:    ob_alu = alu_out;
      2'd2:    ob_alu = mtag | {8'd0, f[32:1]};
      default: ob_alu = mtag | {8'd0, alu_out[30:0], q[31]};
    endcase
    if (is_mul) ob_alu = mtag | {8'd0, mul_ob};
    if (is_div) ob_alu = mtag | {8'd0, div_ob};
  end

  always_comb begin
    q_alu = q;
    if (is_mul) q_alu = {q[39:32], mul_q};
    else if (is_div) q_alu = {q[39:32], div_q};
    else begin
      unique case (ir[1:0])
        2'd1:    q_alu = {q[39:32], q[30:0], !alu_out[31]};
        2'd2:    q_alu = {q[39:32], alu_out[0], q[31:1]};
        2'd3:    q_alu = alu_out;
        default: q_alu = q;
      endcase
    end
  end

  // --- A BYTE word (`Pipeline::byte`): LDB with `IR<24>` rotates by LC's
  // rotation; a selective deposit and a DPB mask from the rotate.
  logic [5:0]  bpos, bright;
  logic [39:0] bmask, bm;
  assign bpos    = (ir[13:12] == 2'd1 && ir[24]) ? lc_rotation(ir[5:0]) : ir[5:0];
  assign bright  = ir[13] ? ir[5:0] : 6'd0;
  assign bmask   = mask40(bright, ir[11:6]);
  assign bm      = ir[12] ? rol40(m, bpos) : m;
  assign ob_byte = (bm & bmask) | (a & ~bmask);

  assign ob = cls == 2'd3 ? ob_byte : ob_alu;

  // --- A JUMP's condition (`Pipeline::jump_condition`): a bit of M rotated by
  // `{IR<47>, IR<4:0>}`, or by LC's rotation under `IR<11:10>` = 3; or with
  // `IR<5>` the condition `IR<4:0>` names.
  // Only the rotated word's bit 0 is a condition.
  logic [5:0]  jrot;
  logic        jbit;
  logic [39:0] jr;
  assign jrot   = (ir[11:10] == 2'd3) ? lc_rotation({ir[47], ir[4:0]}) : {ir[47], ir[4:0]};
  assign jr     = rol40(m, jrot);
  assign jbit   = jr[0];
  logic [4:0] code;
  assign code = (ir[4:0] == 5'o10 || ir[4:0] == 5'o11 || ir[4:0] == 5'o12) ? ir[4:0]
              : {2'd0, ir[2:0]};
  always_comb begin
    if (!ir[5]) jcond = jbit;
    else begin
      unique case (code)
        5'd0:    jcond = jbit;
        5'd1:    jcond = !aeqm && f[32];
        5'd2:    jcond = f[32];
        5'd3:    jcond = aeqm && m[39:32] == a[39:32];
        5'd4:    jcond = !vmaok;
        5'd5:    jcond = !vmaok || int_pending;
        5'd6:    jcond = !vmaok || int_pending || sequence_break;
        5'o10:   jcond = overflow;
        5'o11:   jcond = m[31:0] < a[31:0];
        5'o12:   jcond = m[31:0] <= a[31:0];
        default: jcond = 1'b1;
      endcase
    end
  end

  // --- A DISPATCH's address (`Pipeline::dispatch`): `IR<23:12>` with the
  // M operand's bits rotated and masked to the length `IR<7:5>`.
  logic [5:0]  drot;
  logic [31:0] dm, dmask;
  assign drot  = (ir[11:10] == 2'd3) ? lc_rotation({ir[47], ir[4:0]}) : {ir[47], ir[4:0]};
  assign dm    = rol40(m, drot)[31:0];
  assign dmask = (ir[7:5] == 3'd0) ? 32'd0 : (32'hffff_ffff >> (5'd31 - 5'(ir[7:5] - 3'd1)));
  // With map bits (`IR<9:8>`), `<0>` is the map bit 1, 2 or either picks.
  always_comb begin
    if (ir[9:8] == 2'd0) daddr = ir[23:12] | 12'(dm & dmask);
    else daddr = ir[23:12] | 12'(dm & dmask & ~32'd1)
               | {11'd0, ir[9:8] == 2'd1 ? map_bits[0] : ir[9:8] == 2'd2 ? map_bits[1] : |map_bits};
  end

  // Bits nothing here reads: the class's other fields, LC's high counter.
  logic unused;
  assign unused = ^{ir[46:45], ir[42:25], lc[33:2], jr[39:1]};

endmodule

`default_nettype wire
