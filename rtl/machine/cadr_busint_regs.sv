// SPDX-FileCopyrightText: 2026 Mete Balci
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The bus interface's own Unibus registers: the interrupt block at
// `0o766040`-`0o766076`, the Unibus map at `0o766140`-`0o766176`, and the
// mapped window at `0o140000`-`0o177777` that the map translates through.
//
// The 74S133 at UBCYC 0E08 decodes `0o766000` to `0o766176` and the 74S139 at
// 0E07 splits it four ways on address bits 6 and 5.  MIT's `unaddr.text` lists
// the four the same way: "CADR UNIBUS interrupt status" at `766040`, "CADR
// XBUS error status" at `766044`, "Debuggee's selected UNIBUS location" from
// `766100`, and "`XBUS<->UNIBUS` mapping registers" at `766140`-`766176`.
// Two of the four are here.
//
//   - the DIAGNOSTIC block is `rtl/machine/cadr_spy_registers.sv` and has
//     been since the console;
//   - the DEBUG block is a cycle on the OTHER machine's Unibus, answered over
//     the cable by that machine.  muir's `busint::register` gives it `None`
//     for exactly that reason and so does the decode below: a slave here that
//     answered `0o766100` would be answering for a machine that is not there.
//     **In the composed machine those four addresses therefore time out**,
//     where muir's `Responder::Debug` with no cable answers at `-UB MSYN` off
//     the pull-up on `DEBUG OUT ACK`.  That is a divergence of the cable's
//     absence and not of this module, and it goes when the cable's side is
//     built.
//
// **WHY THIS IS A MODULE AND NOT MORE OF `cadr_spy_registers.sv`.**  The two
// answer with the same register cycle --- `busint::DIAGNOSTIC_NS` after
// `-UB MSYN`, the write landing at `REGISTER_STROBE_NS` --- so the timing
// shell below is that file's a second time, which is a duplication worth
// naming.  What is not duplicated is anything else: every one of the
// diagnostic sixteen is the PROCESSOR's own state, read back over
// `spy_eadr`/`spy_rdata` and written to the console's three registers, while
// none of these is.  These are pages UBINTC, REQERR, UBMAP, RBUF and WBUF;
// that file is page DIAG.  The alternative was to rename that module and
// widen it, which moves every source list, every harness and every mutation
// record aimed at it; the constant is shared instead, under muir's own name
// in both files, so a mutation on either is caught by that file's own check.
//
// **THE MATCH IS HELD, NEVER COMPUTED.**  `rtl/machine/cadr_io_board.sv`'s
// header carries the measurement: the disk controller's first draft matched
// combinationally and carried the map's ripple into `-MEMACK`/`-LOADMD` and so
// into the countdowns' clock enables, -6.195 ns on 1,065 endpoints.  So `sel`,
// `in_int`, `in_map`, `in_win`, `which`, `mapk`, `mp_page`, `mp_word`,
// `mp_high` and `wr` are taken from `ub_addr` into registers every tick and
// nothing downstream ever sees the address.  The earliest answer this block
// can give is fifty ticks after `-UB MSYN`, and the earliest thing it does at
// all is the Xbus request at twenty, so a match a tick behind the strobe is
// nineteen ticks early and the hold is free --- and the counter starts on
// `ub_msyn` alone, so a master that puts the address up on the tick of the
// strobe, which is what `golden/src/busint_regs.rs` is, is served.
//
// **THAT MAKES THE HOLD A TIMING FACT AND NOT A BEHAVIOURAL ONE, AND IT WAS
// MEASURED RATHER THAN ASSERTED.**  The six rewritten as `assign`s off
// `ub_addr` passed `busint_regs` over all 38,319,186 of its ticks and
// `unibus` over all 13,192,237 of its, with both summaries byte-identical.
// So no mutation of this is live and `mutations/list.txt` records the
// equivalence rather than leaving somebody to file it as a hole.  **That
// measurement was made at `8e9e94e`, before the window, and both tick counts
// have moved since** --- `busint_regs` runs 57,139,860 now and `unibus`
// 13,190,033 --- so it is cited at its commit rather than restated.  The
// argument has not moved, and the four fields the window added qualify the
// same way with less margin: they are read at the Xbus request, twenty ticks
// after the strobe rather than fifty.
//
// **AND THOSE SIX ARE THE ONLY REGISTERS OF THIS MODULE IN THE RELAXED SET.**
// `rtl/plumbing/xilinx7/cadr_machine.xdc` defines `slow` as every register
// minus a name list, which swallows every module written after it --- the
// trap that cost the disk controller three slices' fit figures --- so this
// module is excluded whole there and the six are put back.  That file carries
// the argument for each of the rest, and says that no fit has been run at the
// commit which added the clause.
//
// **WHAT IS HERE, REGISTER BY REGISTER.**
//
//   `766040`  the interrupt status register.  Read, it is three things at
//             once: the bits it holds, `XBUS INTR IN` live in bit 14, and the
//             interrupt TAKEN in bit 15 with its vector in bits 2 to 9.  The
//             vector field is stored by a write and does not read back on its
//             own --- the 74LS374 at UBINTC 0D17 is enabled by `UB INT` ---
//             which is muir's `Machine::interface_read` exactly.  Written, it
//             reaches `CONTROL_MASK`, `0o36001`: bit 0 and bits 10 to 13.
//             MIT: writing `766040` "writes into bits 0 and 10-13 (mask
//             36001)".
//
//   `766042`  the same register's other half, `-LOAD INT CTL2 REG`, which the
//             microcode calls `CLEAR-INTERRUPT`.  It reads as nothing --- it
//             is a write strobe and has no read select --- and a write
//             reaches `CONTROL2_MASK`, `0o101774`: the vector field and
//             `UB INT`.
//
//   `766044`  the error status register.  Read, the high byte is the Unibus
//             pulled up and reads as ones, `WRITE THROUGH ENB` is bit 7,
//             `-FREE` is bit 6 and reads SET --- the interface is busy with
//             the read that is fetching it --- `UB MAP ERROR` is bit 5 and
//             the two NXM bits are below.  Written, it is `-RESET ERR`:
//             "Writing this location ignores the data written and clears the
//             status bits", all but bit 7, which the 74S74 at UBCYC 0B08
//             clocks from data bit 7.
//
//   `766046`  decoded, and wired to nothing.  It answers and reads zero.
//
//   `766140`  sixteen 29701s at UBMAP 0E12-0E15, read back through the
//   `-766176` 74LS244s at 0E16 and 0E17.  Sixteen bits each: `MAPVALID` in
//             bit 15, `WRITEOK` in bit 14 and `UBMA<21:8>` under them, which
//             is `Machine::map_entry` --- "Bit 15 of the register signifies
//             that mapping of that page is turned on; otherwise, that section
//             of the unibus is non-existent memory.  Bit 14 enables write
//             access from the unibus.  The remainder of the register is the
//             page number", `unaddr.text`.  What translates through them is
//             the window below.
//
//   `140000`  **THE MAPPED WINDOW**, `busint::map_access`.  Not a register of
//   `-177777` this block at all but a Unibus master's access to the Xbus
//             through the map.  The 74S258s at UBMAP 0E10 and 0E11 take
//             `UBA<13:10>` as the map's address, `UBA<9:2>` as the word
//             within the mapped page and `UBA1` as which half, and the second
//             half of the 74S139 at UBCYC 0E07 decodes that with `C1 IN` into
//             `-UB READ XBUS`, `-UB READ BUFFER`, `-UB WRITE BUFFER` and
//             `-UB WR XBUS`.  "Each Lisp machine memory word is accessed as
//             two unibus words; the low half has the lower unibus address"
//             --- `unaddr.text`.  The read buffer at RBUF and the write
//             buffer at WBUF are sixteen words each, one a page, and they
//             carry the HIGH half of the Lisp machine word between the two
//             Unibus cycles that make it.
//
// **WHAT A MAPPED CYCLE IS, FUNCTION BY FUNCTION.**  `Machine::mapped_read`
// and `Machine::mapped_write` are the whole of it and this module is those
// two:
//
//   a READ of the EVEN word     an Xbus read at `(page << 8) | word`, whose
//                               LOW half is the answer and whose HIGH half
//                               goes into this page's read buffer.
//                               `Responder::MapXbus`.
//   a READ of the ODD word      the read buffer, with no Xbus cycle and no
//                               look at the map at all --- an invalid page
//                               still answers.  `Responder::MapBuffer`.
//   a WRITE of the EVEN word    the write buffer, and nothing else.
//                               `Responder::MapBuffer`.
//   a WRITE of the ODD word     an Xbus write of `{this word, the write
//                               buffer}` at `(page << 8) | word`.
//                               `Responder::MapXbus`.
//   write-through               bit 7 of the error status register, the
//                               74S74 at UBCYC 0B08.  On the upper eight
//                               pages a WRITE of the EVEN word writes the
//                               buffer AND makes an Xbus write of the Unibus
//                               word with zeros above it --- the 74LS244s at
//                               BUSSEL under `-UB16>BUS` putting ground on
//                               `BUS<31:16>`.  Measured on the netlist board,
//                               muir's `tests/chip.rs`.
//   the page refuses            `MAPVALID` down, or `WRITEOK` down on a
//                               write: `UB MAP ERROR` and the cycle is NEVER
//                               answered.  `Responder::MapRefused`, and
//                               muir's own `bus_error::UB_MAP_ERROR`: "Set
//                               when an attempt to perform an Xbus cycle
//                               through the Unibus map is refused because the
//                               map specifies invalid or write-protected."
//
// **THE WINDOW ANSWERS A FOREIGN MASTER AND NOT THE BOARD ITSELF**, which is
// `ub_foreign` and is the one thing here that is a reading of muir rather
// than a transcription of it.  `busint::decode` --- which is what the
// PROCESSOR's own Unibus cycle goes through --- answers `Responder::NoUnibus`
// at every address of this window: `register` is `None` there,
// `debug_register` is `None` there and the I/O board answers none of it, so a
// cycle of the machine's own at `0o140000`-`0o177777` times out.  The map
// responders are made in `Rtl::try_debug_request` and nowhere else.  The
// drawings say the same at the gate: `-UB TO MD` is `NAND(UBMA<21:17>,
// UBXRQ, -UBRD, MSYN IN)` at REQU 0D12, and `MSYN IN` is the strobe as
// RECEIVED --- a master that is not this board.  Turning the board's own
// Unibus cycle back into an Xbus cycle would be a loop.  `build/
// busint_regs.pass` sweeps both ways: all 262,144 addresses with `ub_foreign`
// down, where the window must be silent, and all 262,144 again with it up,
// where the window must answer and nothing else may start to.
//
// **AND THE ONLY MASTER THAT CAN REACH IT IS THE DEBUG CABLE'S, WHICH IS NOT
// COMPOSED.  SAID PLAINLY, BECAUSE IT IS WHAT THIS BLOCK IS WORTH TODAY.**
// `rtl/machine/cadr_console_bus.sv` has three masters.  The processor's is
// the board itself and `ub_foreign` is down for it by the paragraph above.
// `rtl/machine/cadr_dbgin.sv` is the debug cable's --- MIT's own, the one
// `Machine::mapped_read` and `mapped_write` were written for --- and
// `cadr_memory_path.sv` still ties its request off, so `dbg_gnt` is a
// constant there.  The console's is a master and `ub_foreign` counts it,
// because a slave decodes the address and not the master and a board on
// MIT's backplane would answer it the same; but `rtl/plumbing/
// cadr_console.sv` builds its address as `SPY_BASE | eadr<<1` with four bits
// of `eadr`, so it cannot put anything but `0o766000`-`0o766036` on the bus
// and cannot reach this window at all.  **So nothing in the composed machine
// makes a mapped cycle today**, and what this block is is the debuggee's half
// of a route waiting for its master.  `build/busint_regs.pass` drives it at
// its own seam and `build/unibus.pass` drives it through the arbiter with a
// master of the testbench's own; neither is a program, and the header of
// `golden/src/busint_regs.rs` says so in as many words.
//
// **WHAT THE XBUS HALF IS HELD TO, AND WHAT IT IS NOT.**  Held: the request
// goes out `busint::UB_XBUS_REQUEST_NS` after `-UB MSYN`; the physical
// address is `Machine::map_entry`'s page with `UBA<9:2>` under it; the
// thirty-two bits are `Machine::mapped_write`'s; and `-UB SSYN` is
// `busint::UB_XBUS_READ_ACK_NS` after the acknowledgement on a read and with
// it on a write.  NOT held: everything between, because it is this fabric's
// arbiter and not MIT's.  `cadr_dbgin.sv` records the same parting for the
// Unibus grant and for the same reason --- `cadr_busint_xbus.sv`'s header
// says every branch it left out of the processor's arbitration belongs to
// this cable.  The testbench answers at a latency that moves from cycle to
// cycle for exactly that reason: an answer at a fixed instant would let a
// block that counted ticks rather than watching `map_done` pass.
//
// **AND A MAPPED PAGE THAT IS NOT MAIN MEMORY IS NOT MODELLED, BY muir'S OWN
// WORDS.**  `Busint::debug_xbus_edge`: "The processor asking for the Xbus
// meanwhile, and a mapped page nothing answers, are **not modelled**: the
// debuggee CC works on is halted, and its map points at memory."  So
// `rtl/machine/cadr_memory_path.sv` takes the bus for this master only for a
// main-memory page, and a mapped cycle at any other page is never
// acknowledged --- which is what `cadr_dbgin.sv` already says happens to a
// cycle nothing answers: "there being no timeout for this master", it stands
// until the debugger gives up.  Nothing is starved meanwhile, because the arm
// never takes the Xbus at all.
//
// **`-UB TO MD` IS DECODED AND NOT BUILT, AND THE REASON IS ONE GATE IN
// ANOTHER FILE.**  A write of the odd word through a page whose high five
// bits are ones is `busint::map_to_md` --- CC's `CC-WRITE-MD`, which loads
// map register `0o16` with `0o177000` --- and muir loads the processor's `MD`
// with it and acknowledges `busint::UB_MD_ACK_NS` on.  The path is `UB MD
// LOAD`, `NOR(-UB TO MD, -UBX GRANT)` at REQLM 0B17, a term of `-LOADMD` at
// 0C10.  In this fabric `-LOADMD` is gated by `RDCYC` inside
// `rtl/machine/cadr_microcycle.sv` --- which is right for the processor's own
// cycles, and is the gate the `rdcyc-gate-dropped` record holds --- so a
// foreign master's `MD` load cannot be made without changing that file.  This
// module therefore DECODES it, raises `map_md`, makes no Xbus cycle, sets no
// error and does not answer; the check compares the decode against muir's own
// `Responder::MapMd` on every mapped cycle and counts the rows whose answer
// it exempts, so the exemption is a number on the output rather than a
// silence.  The cycle hangs where muir acknowledges it, and that is written
// here rather than left to be found.
//
// **WITHIN THE INTERRUPT BLOCK THE FOUR REPEAT EVERY EIGHT BYTES.**  The
// 74S138 at 0E03 looks at address bits 2 and 1 alone, so `0o766050` is
// `0o766040` and `0o766064` is `0o766044`, through `0o766076`.  The decode
// below is `busint::register` and `build/busint_regs.pass` sweeps it against
// that function at every one of the 262,144 addresses an eighteen-bit
// `ub_addr` can carry.
//
// **AND `0o766077` AND `0o766177` ARE DECODED BY NOBODY**, because muir's own
// ranges end at the even address.  Nothing can tell: bit 0 of a Unibus address
// is always zero, the master's `UAO<17:1>` dropping it, so no cycle reaches
// one.  muir is the reference and this follows it; the trace's `IFACENONE`
// runs are where the claim lives.
//
// **WHAT THIS CLOSES.**  `rtl/machine/cadr_memory_path.sv` used to say that
// the card's interrupt request could not be joined into `-XBUS.INTR`, because
// muir takes it only under `ENABLE UB INTS` and that bit had no register to
// live in.  It has one now: `ub_int` below is `Machine::unibus_interrupt`,
// and `cadr_machine.sv` makes `sintr_o` the OR of it with the Xbus line, as
// `LM INT` is `UB INT OR XBUS INTR IN` at UBINTC 0E04.
//
// And it closes the first of the two defects behind the interrupt storm.
// Microcode 323's handler reads `766040` and branches on bit 1, `LOCAL
// ENABLE`, a jumper pulled up on the board: clear, it takes `INNL0` and the
// PDP-11-arbitrating path, which falls through to `XB-INTR-RET` and never
// reaches `INTRX0`, the only code that clears an Xbus level.  Unanswered,
// that read gives MD zero and the bit is clear.  Answered, it is set, and the
// handler takes the branch MIT wrote for a machine that arbitrates its own
// Unibus.
//
// And the window closes the half-route `docs/debug-cable.md` names: "The
// Unibus map is not built, so a debug cycle cannot reach main memory."  The
// map's registers were built before the window they translate through, so
// the debugger could program the map and then had nothing to send through
// it.  It has the window now; what it still needs is `cadr_dbgin.sv`
// composed into `cadr_machine`, which is that file's own note.

`default_nettype none

module cadr_busint_regs (
    input  var logic        clk,          // 100 MHz, one tick = 10 ns
    input  var logic        rst,

    // --- the Unibus, as a slave sees it
    input  var logic        ub_msyn,      // -UB MSYN, the master's strobe
    input  var logic        ub_write,
    input  var logic [17:0] ub_addr,      // the Unibus address
    input  var logic [15:0] ub_wdata,     // UDI<15:0> from the master
    output var logic        ub_ssyn,      // -UB SSYN: this block answers
    output var logic [15:0] ub_rdata,

    // --- whether the master on the bus is somebody other than this board:
    // `MSYN IN` rather than `MSYN OUT`.  The mapped window answers only a
    // foreign master, because the board's own Unibus cycle goes through
    // `busint::decode` and that function has no map responder in it.  The
    // interrupt block and the map registers answer everybody, the debug
    // cable's CC reading `0o766044` being exactly that.
    input  var logic        ub_foreign,

    // --- the Xbus half of a mapped cycle, `Responder::MapXbus`, which
    // `rtl/machine/cadr_memory_path.sv` arbitrates onto the bus as it does
    // the disk's channel.  `map_done` is the acknowledgement with the word on
    // `map_rdata`; a page that is not main memory is never acknowledged and
    // the header says why.
    output var logic        map_req,
    output var logic [21:0] map_addr,     // (page << 8) | UBA<9:2>
    output var logic        map_write,
    output var logic [31:0] map_wdata,
    input  var logic        map_done,
    input  var logic [31:0] map_rdata,

    // --- `-UB TO MD`: a mapped write whose page is the processor's `MD`.
    // Decoded here and built nowhere; see the header.
    output var logic        map_md,

    // --- `XBUS INTR IN`, the backplane's own interrupt line, live.  It is
    // read in bit 14 of the interrupt status register and is not stored.
    input  var logic        xbus_intr,

    // --- the I/O board's request and the vector it is asking with, which
    // `rtl/machine/cadr_io_board.sv` brings out as `intr_request` and
    // `intr_vector`.  Nothing in this fabric runs a Unibus interrupt CYCLE ---
    // no grant chain, no `BR5`, no vector on the bus --- so the vector arrives
    // on a wire where the board reads it off `UDI<9:2>` at the grant.  muir
    // does the same and says why: "The model has no grant cycle to latch at,
    // so the vector is read off the requesting board at the time of the read:
    // the same value, since the request holds until the microcode has read the
    // device's data."
    input  var logic        iob_intr,
    input  var logic [7:0]  iob_vector,

    // --- the interface's own cycles, for the error status register.
    // `timed_out` is `NXM TIMEOUT` as `cadr_busint_xbus.sv` gives it, a level
    // that stands for the cycle it belongs to; `unibus` is the held decode,
    // which says which of the two NXM bits that cycle sets.
    input  var logic        timed_out,
    input  var logic        unibus,

    // --- `UB INT`: a Unibus interrupt taken, or simulated by writing the bit.
    // `cadr_machine.sv` ORs it with the Xbus line into `SINTR`.
    output var logic        ub_int
);

  // busint::DIAGNOSTIC_NS and REGISTER_STROBE_NS, the same two instants
  // `cadr_spy_registers.sv` answers on: this is one register cycle on the
  // board and the block select is shared.
  localparam int unsigned SSYN_T   = 250 / 5;
  localparam int unsigned STROBE_T = 150 / 5;

  // busint::UB_XBUS_REQUEST_NS, `UBXRQ` up after `-UB MSYN` --- which is also
  // `UB XBUS T100`, the clock on the 74LS74 at REQERR 0D03 that carries
  // `UB MAP ERROR`, and so the instant a refused access sets it.  And
  // busint::UB_XBUS_READ_ACK_NS, `-UB SSYN` after `-UBACK` on a read.
  localparam int unsigned XBUS_RQ_T  = 100 / 5;
  localparam int unsigned READ_ACK_T = 100 / 5;

  // busint::interrupt_status and busint::error_status.
  localparam logic [15:0] LOCAL_ENABLE  = 16'o000002;
  localparam logic [15:0] VECTOR_MASK   = 16'o001774;
  localparam logic [15:0] ENABLE_UB_INTS = 16'o002000;
  localparam logic [15:0] XBUS_INTR     = 16'o040000;
  localparam logic [15:0] UB_INT        = 16'o100000;
  localparam logic [15:0] CONTROL_MASK  = 16'o036001;
  localparam logic [15:0] CONTROL2_MASK = 16'o101774;

  // busint::register's two ranges, which end at the even address.
  localparam logic [17:0] INT_LOW  = 18'o766040;
  localparam logic [17:0] INT_HIGH = 18'o766076;
  localparam logic [17:0] MAP_LOW  = 18'o766140;
  localparam logic [17:0] MAP_HIGH = 18'o766176;

  // busint::map_access's range, `UB17-14=MAP` at UBCYC 0E06.
  localparam logic [17:0] WIN_LOW  = 18'o140000;
  localparam logic [17:0] WIN_HIGH = 18'o177777;

  // ------------------------------------------------------------- the decode
  //
  // Combinational here and registered below; nothing downstream sees these.
  logic in_int_c, in_map_c, in_win_c;
  assign in_int_c = (ub_addr >= INT_LOW) && (ub_addr <= INT_HIGH);
  assign in_map_c = (ub_addr >= MAP_LOW) && (ub_addr <= MAP_HIGH);
  assign in_win_c = ub_foreign && (ub_addr >= WIN_LOW) && (ub_addr <= WIN_HIGH);

  logic        sel, in_int, in_map, wr;
  logic [1:0]  which;   // UBA<2:1>, which of the interrupt block's four
  logic [3:0]  mapk;    // UBA<4:1>, which of the map's sixteen

  // `busint::MapAccess`, field for field, held like the rest.
  logic        in_win;
  logic [3:0]  mp_page;  // UBA<13:10>, which of the sixteen map registers
  logic [7:0]  mp_word;  // UBA<9:2>, the word within the mapped page
  logic        mp_high;  // UBA1, the high half of the Lisp machine word

  // ------------------------------------------------------- the interrupt taken
  //
  // `Machine::unibus_interrupt`: a bit written by hand stands until it is
  // written clear and carries the vector the same write put there; otherwise
  // the card's request is taken while `ENABLE UB INTS` is set, with the
  // card's own vector.  A Unibus vector is a multiple of four, so the field
  // holds it unshifted and `VECTOR_MASK` takes nothing real out of it.
  logic [15:0] int_status;
  logic [15:0] ub_map [16];
  logic        taken_hand, taken_card;
  logic [15:0] taken_vector;
  assign taken_hand   = (int_status & UB_INT) != 16'd0;
  assign taken_card   = ((int_status & ENABLE_UB_INTS) != 16'd0) && iob_intr;
  assign ub_int       = taken_hand || taken_card;
  assign taken_vector = taken_hand ? (int_status & VECTOR_MASK)
                                   : ({8'd0, iob_vector} & VECTOR_MASK);

  // ------------------------------------------------ the map's own two buffers
  //
  // The 29701s at RBUF and WBUF, sixteen words each: `Machine::read_buffer`
  // and `Machine::write_buffer`.  One a page, and each carries the HIGH half
  // of the Lisp machine word between the two Unibus cycles that make it.
  logic [15:0] rd_buf [16];
  logic [15:0] wr_buf [16];

  // ------------------------------------------------- what a mapped cycle is
  //
  // Every one of these is a function of registers alone --- the held decode,
  // the map's own sixteen words and `WRITE THROUGH ENB` --- so `ub_addr`
  // reaches none of them and neither does `ub_write`.
  logic [15:0] ent;
  logic        ent_valid, ent_write, ent_md;
  logic [13:0] ent_page;
  assign ent       = ub_map[mp_page];
  assign ent_valid = ent[15];                      // MAPVALID, `UDI15`
  assign ent_write = ent[14];                      // WRITEOK,  `UDI14`
  assign ent_page  = ent[13:0];                    // UBMA<21:8>
  // `busint::map_to_md`: "if high 5 bits of page=1, writes MD register".
  assign ent_md    = &ent_page[13:9];

  logic err_xbus, err_unibus, err_map, write_through;

  logic wt_low, buf_half, xbus_half, to_md, xbus_ok, refused;
  // The write-through exception, `-UBPN3A` into the 74S32 at UBCYC 0E04 with
  // `-WRITE THROUGH ENB`: the EVEN word of a write on the upper eight pages
  // is an Xbus cycle as well as a buffer write.
  assign wt_low    = wr && write_through && mp_page[3];
  assign buf_half  = in_win && (mp_high != wr) && !wt_low;
  assign xbus_half = in_win && !buf_half;
  // `Rtl::try_debug_request`'s three arms, in its own order.
  assign to_md     = xbus_half && wr && ent_valid && ent_write && ent_md;
  assign xbus_ok   = xbus_half && !to_md && ent_valid && (!wr || ent_write);
  assign refused   = xbus_half && !to_md && !xbus_ok;
  // `-UB TO MD` is `NAND(UBMA<21:17>, UBXRQ, -UBRD, MSYN IN)` at REQU 0D12,
  // so it stands while the cycle does and not a tick longer.
  assign map_md    = to_md && ub_msyn;

  // ---------------------------------------------------------- the read side
  logic [15:0] ctl_word, err_word, word;
  // The low half of the last word the Xbus gave this master, which is what a
  // read of the even word answers with.  It is let go when the cycle ends, a
  // slave driving the lines only for its own cycle: the rule the DDR bridge
  // broke by holding its word past the end of one.
  logic [15:0] xword;

  // What the stored register shows of itself: everything but the three
  // things the read makes up, which are bit 14, bit 15 and the vector field.
  assign ctl_word = (int_status & ~(XBUS_INTR | UB_INT | VECTOR_MASK))
                  | (xbus_intr ? XBUS_INTR : 16'd0)
                  | (ub_int ? (UB_INT | taken_vector) : 16'd0);

  // The 74LS244 at REQERR 0C16 drives eight bits of `UDO`; the high byte is
  // the Unibus pulled up and reads as ones, measured on the netlist board.
  // `-FREE` in bit 6 reads SET because the interface is busy with this very
  // read.  Bit 5 is `UB MAP ERROR`, the 74LS74 at REQERR 0D03.
  assign err_word = {8'hFF, write_through, 1'b1, err_map, 1'b0, err_unibus, 2'b00, err_xbus};

  always_comb begin
    if (in_win) begin
      // `-UB READ BUFFER` or `-UB READ XBUS`; a write drives nothing.
      word = buf_half ? rd_buf[mp_page] : xword;
    end else if (in_map) begin
      word = ub_map[mapk];
    end else if (in_int) begin
      unique case (which)
        2'd0: word = ctl_word;
        2'd2: word = err_word;
        // `766042` is a write strobe with no read select, and `766046` is
        // decoded and wired to nothing.  Both read as zero, which is what
        // `Machine::interface_read` answers for them.
        default: word = 16'd0;
      endcase
    end else begin
      word = 16'd0;
    end
  end

  // The lines are driven only while this block is selected and reading, as a
  // slave on an open-collector bus drives them only for its own cycle: the
  // rule the DDR bridge broke by holding its word past the end of one.
  assign ub_rdata = ((sel || in_win) && !wr) ? word : 16'd0;

  // ------------------------------------------------------------ the bus cycle
  logic [6:0]  t_msyn;   // ticks since `-UB MSYN`, saturating
  logic [6:0]  t_ack;    // ticks since the Xbus acknowledgement, saturating
  logic        answer_reg, answer_buf, answer_x, answer_now, land, land_wbuf;

  // The Xbus half's three states.  A plain register rather than an enum: the
  // whole of it is these three lines and a `unique case` on four values would
  // be a fourth state nothing can reach.
  localparam logic [1:0] XS_IDLE = 2'd0, XS_ASK = 2'd1, XS_DONE = 2'd2;
  logic [1:0] xs;

  // Saturating and never wrapping, for `cadr_io_board.sv`'s reason: `elapsed`
  // in `cadr_busint_xbus.sv` was ten bits and wrapped, and six checks and
  // sixty-three mutations passed over what that did to `-XBUS.RQ`.
  localparam logic [6:0] T_MAX = 7'd127;

  assign answer_reg = sel && (t_msyn >= 7'(SSYN_T));
  // `-UB READ BUFFER` and `-UB WRITE BUFFER` answer as a register cycle:
  // `Busint::debug_set_master` gives `Responder::MapBuffer` the same
  // `DIAGNOSTIC_NS` the interface's own registers get.
  assign answer_buf = buf_half && (t_msyn >= 7'(SSYN_T));
  // The Xbus half.  A write is acknowledged WITH the Xbus acknowledgement and
  // a read `UB_XBUS_READ_ACK_NS` after it, which is `Busint::debug_xbus_edge`
  // --- `ack = if write { xack } else { xack + UB_XBUS_READ_ACK_NS }`.
  assign answer_x   = ((xs == XS_ASK) && map_done && wr)
                   || ((xs == XS_DONE) && (wr || (t_ack >= 7'(READ_ACK_T))));
  assign answer_now = answer_reg || answer_buf || answer_x;

  // The tick the write lands, which muir puts at `REGISTER_STROBE_NS` and
  // not at the answer: `Busint`'s `answered` for a write of this block.
  assign land = ub_msyn && sel && wr && (t_msyn == 7'(STROBE_T));
  // And the write buffer's own landing.  `Machine::mapped_write` writes it
  // for EVERY write of the even word, write-through or not: "if !access.high
  // { self.write_buffer[k] = v; ... }" comes before the map is looked at.
  assign land_wbuf = ub_msyn && in_win && wr && !mp_high && (t_msyn == 7'(STROBE_T));

  // **A TIMEOUT IS AN EDGE AND `timed_out` IS A LEVEL.**  It stands for the
  // whole of the cycle it belongs to, so the bit is set on its rise and the
  // one cycle sets one bit.
  logic timed_out_q;

  integer k;
  always_ff @(posedge clk) begin
    if (rst) begin
      sel           <= 1'b0;
      in_int        <= 1'b0;
      in_map        <= 1'b0;
      in_win        <= 1'b0;
      wr            <= 1'b0;
      which         <= 2'd0;
      mapk          <= 4'd0;
      mp_page       <= 4'd0;
      mp_word       <= 8'd0;
      mp_high       <= 1'b0;
      ub_ssyn       <= 1'b0;
      t_msyn        <= 7'd0;
      t_ack         <= 7'd0;
      xs            <= XS_IDLE;
      xword         <= 16'd0;
      map_req       <= 1'b0;
      map_addr      <= 22'd0;
      map_write     <= 1'b0;
      map_wdata     <= 32'd0;
      timed_out_q   <= 1'b0;
      // `LOCAL ENABLE` is a jumper, pulled up on the board: this machine
      // arbitrates its own Unibus.  It is in neither write mask, so nothing
      // can clear it and reset is the only thing that sets it ---
      // `Machine::new` comes up at exactly this value.
      int_status    <= LOCAL_ENABLE;
      err_xbus      <= 1'b0;
      err_unibus    <= 1'b0;
      err_map       <= 1'b0;
      write_through <= 1'b0;
      for (k = 0; k < 16; k = k + 1) begin
        ub_map[k] <= 16'd0;
        rd_buf[k] <= 16'd0;
        wr_buf[k] <= 16'd0;
      end
    end else begin
      // The held match: taken every tick, and the whole reason nothing
      // downstream of here ever sees `ub_addr`.
      sel     <= in_int_c || in_map_c;
      in_int  <= in_int_c;
      in_map  <= in_map_c;
      in_win  <= in_win_c;
      wr      <= ub_write;
      which   <= ub_addr[2:1];
      mapk    <= ub_addr[4:1];
      mp_page <= ub_addr[13:10];
      mp_word <= ub_addr[9:2];
      mp_high <= ub_addr[1];

      // The error flops.  `-RESET ERR` is a clear on them and the timeout is
      // a clock, so a write landing on the tick a timeout rises clears: the
      // clear pin wins, which is what the ordering here says.
      timed_out_q <= timed_out;
      if (timed_out && !timed_out_q) begin
        if (unibus) err_unibus <= 1'b1;
        else err_xbus <= 1'b1;
      end

      if (!ub_msyn) begin
        ub_ssyn <= 1'b0;
        t_msyn  <= 7'd0;
        t_ack   <= 7'd0;
        xs      <= XS_IDLE;
        map_req <= 1'b0;
        xword   <= 16'd0;
      end else begin
        if (t_msyn != T_MAX) t_msyn <= t_msyn + 7'd1;
        if (answer_now) ub_ssyn <= 1'b1;

        // ---- the mapped window's Xbus half ------------------------------
        unique case (xs)
          // `UBXRQ` is up `UB_XBUS_REQUEST_NS` after `-UB MSYN` and this is
          // that instant: the request goes out, or the refusal clocks
          // `UB MAP ERROR` at `UB XBUS T100`, which is the same one.
          XS_IDLE:
            if (t_msyn == 7'(XBUS_RQ_T)) begin
              if (refused) err_map <= 1'b1;
              if (xbus_ok) begin
                map_req   <= 1'b1;
                map_addr  <= {ent_page, mp_word};
                map_write <= wr;
                // `Machine::mapped_write`: the odd word carries the write
                // buffer under it, and write-through's even word puts ground
                // on `BUS<31:16>`.  A read drives nothing.
                map_wdata <= !wr    ? 32'd0
                           : mp_high ? {ub_wdata, wr_buf[mp_page]}
                                     : {16'd0, ub_wdata};
                xs        <= XS_ASK;
              end
            end
          // The acknowledgement.  A read's HIGH half goes into this page's
          // read buffer and its LOW half is the answer, which is
          // `Machine::mapped_read` exactly.
          XS_ASK:
            if (map_done) begin
              map_req <= 1'b0;
              if (!wr) begin
                rd_buf[mp_page] <= map_rdata[31:16];
                xword           <= map_rdata[15:0];
              end
              t_ack <= 7'd1;
              xs    <= XS_DONE;
            end
          default:
            if (t_ack != T_MAX) t_ack <= t_ack + 7'd1;
        endcase

        // ---- the write buffer, `-UB WRITE BUFFER` -----------------------
        if (land_wbuf) wr_buf[mp_page] <= ub_wdata;

        // ---- the block's own registers ----------------------------------
        if (land) begin
          if (in_map) begin
            ub_map[mapk] <= ub_wdata;
          end else begin
            unique case (which)
              2'd0: int_status <= (int_status & ~CONTROL_MASK) | (ub_wdata & CONTROL_MASK);
              2'd1: int_status <= (int_status & ~CONTROL2_MASK) | (ub_wdata & CONTROL2_MASK);
              // `-RESET ERR`: "Writing this location ignores the data written
              // and clears the status bits" --- all but the one the drawings
              // clock from it.  `Machine::interface_write` sets `bus_error`
              // to zero, so `UB MAP ERROR` goes with the two NXM bits.
              2'd2: begin
                err_xbus      <= 1'b0;
                err_unibus    <= 1'b0;
                err_map       <= 1'b0;
                write_through <= ub_wdata[7];
              end
              // `766046` is decoded and wired to nothing.
              default: ;
            endcase
          end
        end
      end
    end
  end

  logic unused;
  // `ub_addr<17:14>` and `<0>` reach nothing: the two register ranges and the
  // window are compared whole above, bit 0 is decoded nowhere in the block,
  // and what is left picks the register or the word.  `iob_vector<1:0>` are
  // masked off by `VECTOR_MASK`, a Unibus vector being a multiple of four.
  assign unused = &{1'b0, ub_addr[17:14], ub_addr[0], iob_vector[1:0]};

endmodule

`default_nettype wire
