// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The three machine registers the diagnostic bus has no register for,
// captured at the microcycle boundary so that a console outside `cadr_machine`
// can read them.
//
// **WHY THERE ARE ANY.**  MIT's diagnostic bus is sixteen registers and
// `../muir/src/spy.rs` is the whole of its vocabulary: `IR` in three halves,
// `OPC`, `PC`, `OB`, `FLAG-1`, `FLAG-2`, `M`, `A` and `ST`, with the open bus
// at register 3.  **`VMA`, `Q` and `MD` are on none of them**, so MIT's own
// console cannot see any of the three and neither can
// `rtl/plumbing/cadr_console.sv` through `cadr_spy_registers`.  They are
// `cadr_machine`'s observation ports and nothing else.
//
// On 2026-09-10 the board ran a System 100 band for 351 million microcycles
// and halted inside `PDL-BUFFER-REFILL`, where the microcode reads a
// second-level map entry, writes it back with read/write access ORed in, and
// then reads through the entry it has just hacked --- and that read took a
// page fault, which muir on the same pack does not.  Two suspects: the map
// write did not take, or the address read is not the page the map was hacked
// for.  **Three different faults injected into muir reproduce the board's
// console readout bit for bit** --- same `PC`, same `OPC`, same `FLAG-1` and
// `FLAG-2`, same `IR`, `A`, `M` and `OB` --- so nothing the sixteen can say
// separates them.  What separates them is the virtual address register
// against `Q`: **the map-side faults leave them equal and the wrong-address
// fault leaves them one page apart.**  That difference is the whole reason
// this module exists, and it is why the two travel together and are latched
// together one level up.
//
// **AND `MD` IS THE THIRD, ADDED ON 2026-09-11 BECAUSE THE HALT WAS
// REPRODUCED AND THE PAIR NARROWED IT TO ONE SUSPECT.**  On the board at
// 05:35 the virtual address register read `0o2640010` and `Q` read
// `0o600000000`, and `0o2640010` is EXACTLY what muir shows for the two
// map-side injections --- the wrong-address injection puts `0o2640410`
// there.  So the machine asked for the page it meant to ask for, and what is
// left is the map.  `MD` is what the last read RETURNED: at that halt it
// holds either the map word the microcode wrote back or the word the faulting
// read produced, and either one moves the diagnosis on.  It rides here rather
// than on a wire of its own for the reason the pair does --- the question is
// asked of the three together, `MD` being a map word only in relation to the
// page `VMA` names --- and it is latched with them one level up so that the
// three name ONE microcycle.
//
// **`MD` IS NOT A MICROCYCLE REGISTER IN THE WAY THE OTHER TWO ARE, AND THAT
// HAD TO BE ASKED RATHER THAN ASSUMED.**  `vma` and `q` are written inside
// `if (mclk_edge)` in `cadr_microcycle.sv` and nowhere else, so they cannot
// move between boundaries at all.  `md` is written in two places: `destmdr`
// inside that same `if (mclk_edge)`, and `md_pending && (mclk_edge || hang)`
// --- the word `-LOADMD` deskewed, taken in the middle of a PARKED generator,
// which is a change between boundaries.  Whether that leaves the capture
// below a whole microcycle is a fact about `RD_FINISH_T` and the generator's
// restart and not about anybody's intent, so `tb/cadr_console_tb.cpp`
// measures it every tick over MIT's whole boot PROM: the shortest distance
// from a change of each source to the boundary that captures it, against the
// fifteen ticks `rtl/plumbing/xilinx7/cadr_machine.xdc` relaxes these three
// arcs to.  It fails below fifteen.  An exemption too wide tests nothing and
// looks exactly like one that is right; that measurement is the check on this
// one.
//
// **WHY THE CAPTURE IS HERE AND NOT IN THE CONSOLE.**  This module is
// instantiated by `rtl/machine/cadr_machine.sv`, where `vma`, `q` and `mclk` all are,
// and by `tb/cadr_console_harness.sv` --- the same module and not a copy of
// it, which is the rule `rtl/machine/cadr_console_bus.sv` was extracted for: two
// descriptions of one thing drift and the check then holds the copy.
//
// Being inside `cadr_machine` is not a tidiness: `rtl/plumbing/xilinx7/cadr_machine.xdc` is
// read `read_xdc -ref cadr_machine`, so its `-from $slow -to $slow`
// relaxation can only name cells in there.  `vma_reg` and `q_reg` are in
// `slow`; a register that samples them from outside is not, and that arc is
// then asked for in one tick.  That is the wall the console's own read-back
// met at -12.837 ns, and `cadr_console_bus.sv`'s header has the whole of it.
// Here both ends are `cadr_machine`'s and the arc has the microcycle; what
// crosses to the console is a plain registered word.
//
// **AND IT EARNS THE RELAXED SET ON THAT FILE'S OWN TEST, WHICH IS NOT "IS IT
// SLOW" BUT "IS ITS INPUT STABLE ACROSS THE MICROCYCLE AND ITS CONSUMER
// READING IT ONLY AT THE END".**  `vma` and `q` are microcycle registers ---
// they are written at a boundary and stand still between --- so loading them
// AT THE BOUNDARY and nowhere else is launched at one boundary and captured
// at the next.  `md` is the one that moves between boundaries, and the
// measurement above is what says it still earns the set, rather than the
// argument saying it.  `mclk` is the whole clock enable, exactly as it is
// `con_rdata`'s one module along.  Loaded every tick instead this would be a
// register holding whatever a relaxed path had reached, which is the
// too-wide exemption in its purest form.
//
// **AND `mclk` AND NOT `clock_edge`, WHICH IS THE DIFFERENCE THAT DECIDES
// WHAT A HALTED MACHINE SHOWS.**  `MCLK` runs whether or not `MACHRUN` does
// --- `cadr_console_bus.sv` quotes MIT on it --- so a machine stopped by the
// console goes on refreshing all three and the console reads the state it
// actually stopped in.  `clock_edge` pulses only when a microcycle retires,
// so a capture on it would freeze one microcycle early at exactly the moment
// somebody halted the machine to look.  That is the only time a console is
// used.
//
// The price is the one `con_rdata` pays and is the same price: the console
// reads these as of the last microcycle boundary.  On a halted machine it is
// exact, none of the three moving; on a running one a boundary is where a
// CADR's state is defined at all.

`default_nettype none

module cadr_console_state (
    input  var logic        clk,          // 200 MHz, one tick = 5 ns
    input  var logic        rst,
    input  var logic        mclk,         // MCLK7, the microcycle boundary

    // --- the machine's own, straight off `cadr_microcycle`
    input  var logic [31:0] vma,
    input  var logic [31:0] q,
    input  var logic [31:0] md,

    // --- and as the console reads them, one boundary behind
    output var logic [31:0] con_vma,
    output var logic [31:0] con_q,
    output var logic [31:0] con_md
);

  // **THE THREE ARE LOADED BY ONE ENABLE AND MUST STAY THAT WAY.**  What the
  // console is asked is whether the virtual address register and `Q` are
  // equal or a page apart, and what word `MD` was holding while they were ---
  // so a set taken at three instants answers a question nobody asked.  One
  // `if`, three registers.
  always_ff @(posedge clk) begin
    if (rst) begin
      con_vma <= 32'd0;
      con_q   <= 32'd0;
      con_md  <= 32'd0;
    end else if (mclk) begin
      con_vma <= vma;
      con_q   <= q;
      con_md  <= md;
    end
  end

endmodule

`default_nettype wire
