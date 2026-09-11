<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The map's two access bits, and the order the two levels are written in

A second-level map entry is twenty-four bits. Bit 23 permits the access at all
and bit 22 permits a write. Every check in this repository had compared those
two bits only in the direction where both are set, so nothing could tell them
apart. This document is what closed that, and a second finding about the map
that came out of the same work.

`tb/cadr_map_access_tb.cpp` is the check and `make check` runs it as
`build/map_access.pass`.

## What was missing

`build/map_boot.pass` writes a map entry across the whole machine and reads
through it, against a real memory, over MIT's boot PROM. Its own output says
what it cannot reach. muir refuses the access on 0 of those 600,000
microcycles. Every map word the boot PROM writes has bits 23 and 22 alike, all
of them `MAP-ACCESS-CODE 3`. So `-VMAOK` was compared only in its permitted
direction, and a fabric that took read permission from the write bit would have
passed.

The band cannot close it either. This was measured rather than assumed. In
`build/rtl_sys.golden` the first microcycle muir refuses is 2,084,533 and the
first asymmetric map word is written at 2,088,933. A whole-machine comparison
stops at 1,062,507, where the first disk transfer is, so neither is reachable.

## How the machine is made to write a chosen word

By one field of one microinstruction of MIT's own boot PROM.

`SET-UP-FOUR-PAGES` writes four second-level entries. The word written is
`VMA<23:0>`, and VMA comes from OB. At PROM address `0o274` the byte masker
builds OB out of nothing but that instruction's own mask field, because the A
side is zero and the M side is all ones. OB is therefore the mask itself. The
field gives ones from bit 22 to bit 25, which is `0o360000000`. Bit 25 is
`MAPWR1D` at VCTL2 1C15, the enable that makes the write a second-level write.
Bits 23 and 22 are the access code. Bit 24 is spare, the entry being
`VMA<23:0>` alone.

That word goes to A memory and the other three entries are built from it, so
one field decides the access code of all four. Moving the mask's right edge
moves the access code and changes nothing else about the program.

| `ir[4:0]` | `ir[9:5]` | mask | entry | access bits |
|---|---|---|---|---|
| 22 | 3 | bits 25 to 22 | `0o60000000` | 1, 1 |
| 23 | 2 | bits 25 to 23 | `0o40000000` | 1, 0 |
| 24 | 1 | bits 25 to 24 | `0o00000000` | 0, 0 |

### What that costs

The first configuration is MIT's program unaltered and is held to muir's trace
microcycle for microcycle. The other two are MIT's program with ten bits of one
word changed, and muir has no trace of them. No generator in `golden/` takes a
PROM argument, so nothing here can produce one.

What holds the patched runs is therefore narrower. It is the instruction
stream, which must be muir's everywhere but at the patched address. It is the
control flow, which must follow muir's PC until the program reacts to a refusal
muir never had. And it is the permission behaviour, which muir's own rule
predicts. That is weaker than `map_boot`'s comparison and stronger than a
fabric-only property. The check says which claim is which on its own output.

The fourth combination, bit 23 clear with bit 22 set, is not reachable this
way. A mask is contiguous, so bits 25 and 22 without bits 24 and 23 cannot be
one field. Reaching it would need a microcode fragment of our own, which
nothing here has. It costs less than it looks. That combination behaves
identically to both bits clear in a correct machine, and every mutation aimed
at the two bits turns the read-only configuration's permitted reads into
refusals and is caught there.

### The patch is read back, not trusted

Two things could leave the run testing nothing. The patched word might not
reach the fabric's boot PROM, and the machine might not write the entry the
patch predicts. Both are read out of the machine itself over the console's
readout window, which reaches the boot PROM and both levels of the map. If the
field positions were wrong the check fails naming the word it found.

## The four combinations, and where the truth comes from

muir states the rule twice, once in each engine.

    ../muir/src/machine.rs  Machine::translate
        write_permitted:  l2_data & (1 << 22) != 0,
        access_permitted: l2_data & (1 << 23) != 0,
    ../muir/src/rtl.rs      Rtl::step
        let pfr = bit(lvmo as u64, 23);
        let pfw = !(!bit(lvmo as u64, 22) && self.wrcyc);
        let vmaok = pfr && pfw;

muir also has a test of its own for exactly this, and it is better provenance
than a transcription. `tests/busint.rs`'s `a_bus_timeout_is_not_a_page_fault`
writes a map entry three ways and asserts what each does. With both bits set a
read is permitted. With bit 23 clear the read faults and "the cycle never
started". With bit 22 clear the read is permitted and the write is refused,
"which never reached the bus".

| bit 23 | bit 22 | a read | a write |
|---|---|---|---|
| 0 | 0 | refused | refused |
| 0 | 1 | refused | refused |
| 1 | 0 | permitted | refused |
| 1 | 1 | permitted | permitted |

A refusal has a signature beyond one flag, and the check takes all of it.
`-MEMRQ` off the 9S42 at VCTL1 1E25 is `MEMSTART AND VMAOK OR MBUSY`. So a
refused reference raises no request, gets no `-MEMACK`, never strobes
`-LOADMD`, and leaves MD standing. No address ever reaches the memory. Each of
those is counted separately, because a fabric that dropped `VMAOK` out of
`-MEMRQ` alone would still get the flag right.

## What the check measured

The unaltered configuration agrees with muir for all 600,000 microcycles, with
17,466 accesses attempted and every one permitted, 256 words read and 256
written.

The read-only configuration writes `0o40000000` into all four entries. It
agrees with muir's PC for 536,305 microcycles. It reads through the entry once,
with `-VMAOK` permitted and the word fetched from the memory, and it is refused
a write through the same entry, with `-VMAOK` refused, no `-MEMRQ`, MD standing
and nothing written. That is the asymmetry, and it is the one thing no other
check in the tree can show.

The no-access configuration writes `0o00000000` into all four entries. It
agrees with muir's PC for 536,303 microcycles and is then refused its first
read, with no `-MEMRQ` and nothing fetched.

Both patched runs then part from muir, and where they go is the most useful
thing the check prints. `PAGE-0-PARITY-FIX` puts `JUMP-IF-PAGE-FAULT
ERROR-PAGE-FAULT` after its read and again after its write
(`sys/ucadr/promh.text:397-403`). The refused read and the refused write
therefore both leave for PC `0o24`, which is `ILLOP`, where muir has `0o313`
and `0o315`. So the refusal reached the microcode's own jump condition and not
merely a flag a testbench reads, and it reached it by the same route the board
halts through. The check asserts that the two runs take the same trap and that
it is not where muir went.

The counts through the asymmetric entry are therefore one read and one write,
which is thin. The program stops looking as soon as it is refused, so no
configuration can accumulate more. It is enough to catch every mutation aimed
at the two bits, and it is said here rather than left to be inferred.

## The second finding: which level-1 entry a level-2 write is indexed by

A `VMA-WRITE-MAP` can enable both levels at once. `VMA<26>` writes the first
level from `VMA<31:27>` and `VMA<25>` writes the second from `VMA<23:0>`. The
second level's index is `{VMAP<4:0>, MAPI<4:0>}`, and `VMAP` is the first
level's own output. So when one microinstruction writes both, the question is
whether the second-level write uses the first level's old value or its new one.

**muir answers it two different ways.**

`Rtl::step`, which every golden trace comes from and which the fabric is held
to, computes both addresses before either write:

    let (adr0, adr1) = self.map_address();
    if bit(self.m.vma as u64, 26) { self.m.l1_map[adr0] = ...; }
    if bit(self.m.vma as u64, 25) { self.m.l2_map[adr1] = ...; }

So `Rtl` uses the OLD first-level entry. `Machine::write_map`, which `micro.rs`
uses, re-reads the first level after writing it:

    if vma & (1 << 26) != 0 { self.l1_map[l1_index] = (vma >> 27) & 0o37; }
    if vma & (1 << 25) != 0 {
        let l1_data = self.l1_map[l1_index] & 0o37;
        ...
    }

So `Micro` uses the NEW one. The two engines disagree.

**The fabric follows `Rtl`.** `rtl/machine/cadr_microcycle.sv` reads
`l1_map[adr0]` combinationally into `vmap`, and both array writes are
non-blocking in one block, so `adr1` is formed from the old entry. The check's
fourth configuration measures this rather than reasoning about it. It patches
the same microinstruction to a mask of bits 31 to 22, so that one instruction
writes the first-level entry from 0 to `0o37` and the second level in the same
write phase, and then reads three words back out of the machine. The
first-level entry is `0o37`, the second-level word is at index 0 and not at
index 992, and the control entry at index 993 holds the next write, which says
the first-level write did take effect. So the fabric indexes by the old entry.

**Nothing reaches this case, measured three ways.** In 600,000 microcycles of
the boot PROM and 2,800,000 of the band there is no microcycle at all with
`WMAPD` and both `VMA<26>` and `VMA<25>` set. The boot PROM has 67,585
first-level writes and 65,540 second-level writes and no instruction doing
both; the band has 72,660 and 86,882 and none. In MIT's own microcode no
`VMA-WRITE-MAP` names both enables. `LEVEL-1-MAP-MISS` in
`sys/ucadr/uc-page-fault.lisp` writes the first level alone, then reads main
memory, then fills the thirty-two second-level entries in a loop, each a
second-level write alone. The separation is deliberate.

**And the hardware does not define an answer.** The first-level map is 93425As
on `mit/cadr/vmem0.drw`, whose outputs `-VMAP<4:0>` pass through a 74S04 to
become the `VMAP<4:0>` that address `mit/cadr/vmem1.drw`. The 93425A has a
three-state output that is high impedance while the part is deselected or while
it is being written; muir records that in `src/part.rs`, whose `ram1` returns
high impedance when the write enable is low and whose comment reads "High
impedance while deselected or written". Both write pulses are `-WP1`. So on the
real board the first-level map's outputs are floating exactly while the
second-level write latches, and the block the word lands in is whatever the
floating nets settle to. A floating TTL input reads high, which through the
inverters would give block 0, but that is an inference from float-high and not
a measurement.

The conclusion is that there is no correct behaviour to implement. The fabric
agrees with the engine it is checked against, the case is unreachable in MIT's
microcode, and the disagreement that exists is between muir's own two engines.
It is recorded here so that nobody files it as a fabric defect, and the check
holds the fabric to `Rtl`'s ordering so that it cannot drift silently.

## Mutation records

These records are written and measured but are **not yet in
`mutations/list.txt`**, because a record's `@check` is validated against the
runner's `CHECKS` before anything else runs, and a record naming a check the
runner has no entry for stops `make mutants` at parse for every record. The
runner needs the entry below, and the two must land in the same commit.

    "map_access": {
        "sources": ["rtl/machine/cadr_microcycle.sv", "rtl/plumbing/cadr_ddr_map.sv"],
        "extra": [
            "rtl/machine/cadr_phase_gen.sv",
            "rtl/machine/cadr_xbus_decode.sv",
            "rtl/machine/cadr_busint_xbus.sv", "rtl/plumbing/cadr_xbus_ddr.sv",
            "rtl/machine/cadr_disk_controller.sv", "rtl/machine/cadr_tv.sv",
            "rtl/machine/cadr_io_board.sv",
            "rtl/machine/cadr_spy_registers.sv",
            "rtl/machine/cadr_console_bus.sv", "rtl/machine/cadr_console_state.sv",
            "rtl/machine/cadr_memory_path.sv", "rtl/machine/cadr_machine.sv",
        ],
        "top": "cadr_machine",
        "tb": "tb/cadr_map_access_tb.cpp",
        "flags": ["-O2", "-CFLAGS", "-O2", "-Irtl/machine", "-Irtl/plumbing",
                  "-Irtl/plumbing/xilinx7", "-Iboards/arty-z7-20"],
        "golden": "rtl.golden",
        "gprom_path": "map_access_prom.hex",
    },

`gprom_path` is a new key. The check needs its boot PROM under a name of its
own, because the testbench writes the patched image to that file before the
model is built and must not touch the one every other check reads. Everything
else is `map_boot`'s entry.

The records themselves are below. Each was applied by hand to a copy of the
tree, built and run, and all five are caught. The catching lines were read
rather than the exit codes counted, which is what CLAUDE.md asks for.

| record | verdict | the line that caught it |
|---|---|---|
| `map-read-permission-takes-the-write-bit` | caught | code 2, microcycle 536,302: a read through `800000` refused where muir's rule permits |
| `map-access-bits-swapped` | caught | the same line |
| `map-write-bit-refuses-a-read-too` | caught | the same line |
| `map-refusal-still-starts-a-cycle` | caught | code 2, microcycle 536,304: a write muir's rule refuses and `-MEMRQ` went out |
| `level-2-map-write-takes-the-new-first-level-entry` | caught | the level-2 write landed in the new level-1 block |

The first three all fail on the same line, which is worth saying rather than
hiding: the read-only configuration's permitted read is the one thing all three
break, and that is the property the file exists for. The fourth is caught on the
other half, the write that must not start a cycle. The fifth is caught only by
the fourth configuration and by nothing else in the tree.

    # A read needing the write bit as well.  Both bits stay read, so lint
    # cannot catch it; the read-only configuration's permitted read becomes a
    # refusal.
    @name map-read-permission-takes-the-write-bit
    @check map_access
    @file rtl/machine/cadr_microcycle.sv
    @old   assign pfr   = lvmo_eff[23];
    @new   assign pfr   = lvmo_eff[23] && lvmo_eff[22];

    # The two access bits in each other's place.  Both stay read.
    @name map-access-bits-swapped
    @check map_access
    @file rtl/machine/cadr_microcycle.sv
    @old   assign pfr   = lvmo_eff[23];
           assign pfw   = !(!lvmo_eff[22] && wrcyc);
    @new   assign pfr   = lvmo_eff[22];
           assign pfw   = !(!lvmo_eff[23] && wrcyc);

    # The write bit refusing a read as well, which is the `WRCYC` term of the
    # 74S00 at VCTL1 1D17 dropped.
    @name map-write-bit-refuses-a-read-too
    @check map_access
    @file rtl/machine/cadr_microcycle.sv
    @old   assign pfw   = !(!lvmo_eff[22] && wrcyc);
    @new   assign pfw   = !(!lvmo_eff[22] && (wrcyc || rdcyc));

    # A refused reference that still raises -MEMRQ.  `vmaok` stays read by
    # MBUSY.SYNC and the jump conditions, so lint is silent.
    @name map-refusal-still-starts-a-cycle
    @check map_access
    @file rtl/machine/cadr_microcycle.sv
    @old   assign memgo = memstart && vmaok;
    @new   assign memgo = memstart;

    # The level-2 write indexed by the level-1 entry the same instruction is
    # writing, which is `Machine::write_map`'s ordering rather than
    # `Rtl::step`'s.  Only the fourth configuration can see it.
    @name level-2-map-write-takes-the-new-first-level-entry
    @check map_access
    @file rtl/machine/cadr_microcycle.sv
    @old         if (vma[25]) l2_map[adr1] <= vma[23:0];
    @new         if (vma[25]) l2_map[vma[26] ? {vma[31:27], mapi[4:0]} : adr1] <= vma[23:0];
