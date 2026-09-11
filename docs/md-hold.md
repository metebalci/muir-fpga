<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# MD holds what its own instruction put there

`docs/map.md` asks what says the fabric's map is right. This document asks the
question one step earlier: what says the map is written at the entry the
microcode named? The answer, until now, was nothing.

The map is indexed by `MAPI`, and `rtl/machine/cadr_microcycle.sv` computes it
as `memstart ? vma[23:8] : md[23:8]`. Outside a memory cycle the index is MD.
The map write is not made by the instruction that asks for it either: `wmapd`
is `wmap` registered at the microcycle boundary, and the write pulse that
carries it belongs to the microcycle after, with the module saying at the
array that "address and data are the live ones: nothing latches them". So an
instruction that puts a virtual address in MD and then writes the map through
it needs MD to stand from its own boundary until a write pulse several
microcycles later. That span is what this document calls a window.

## What MD's register does

MD has exactly two writers, both inside one `always_ff`.

```
      if (loadmd_edge) begin
        md_held    <= rdata;
        md_pending <= 1'b1;
      end else if (md_pending && (mclk_edge || hang)) begin
        md         <= md_held;
        md_pending <= 1'b0;
      end
```

and, inside `if (cpu_edge)`,

```
        if (destmdr) md <= ob;
```

`-LOADMD` is asynchronous and arrives in the middle of a microcycle, so the
word is latched at the strobe and committed where the machine next looks: at
a master clock edge, or at once while `-HANG` has the generator parked, a hang
not being a boundary. At a boundary that carries both a pending word and a
`DESTMDR`, the `else if` commits the held word, clears the flag, and the
`DESTMDR` assignment after it wins. The instruction's word is what stands and
nothing is left queued. That is muir's rule as well: `Rtl` has no special case
for such a row, because the bus word is applied where the engine looks and
`DESTMDR` is applied at the edge.

**Unless `loadmd_edge` is true on that very tick.** Then the first branch is
taken, the `else if` never runs, and `md_pending` survives the write. The
instruction still writes MD, and the held word commits afterwards — at the
next master clock edge, or at the very next tick if `-HANG` is up — over the
word the instruction put there. Every map write from there to the next
`DESTMDR` is then made at a different entry.

## The check

`build/md_hold.pass` and `build/md_hold_sys.pass` run
`tb/cadr_md_hold_tb.cpp` over MIT's boot PROM and over a System 100 band. The
stimulus is `tb/cadr_microcycle_tb.cpp`'s — muir's own trace, one row a
microcycle, with the testbench standing in for the bus interface at the
instants muir's interface answered, and the complement of MD's word handed
back on a write so that a load which should not have happened cannot be
mistaken for a no-op. Nothing is compared against the trace; the trace is
there to keep a real program running under the property.

The model is verilated `--public-flat-rw`, because `destmdr`, `wmapd`, the
write pulse and `md_pending` are internal. They are read by name rather than
re-decoded out of IR, which would only assert a property of the testbench's
own decode.

Three things are asserted, every tick:

1. At the `cpu_edge` where `DESTMDR` is up, MD takes OB. This is free, and it
   is what makes the rest mean anything: a window whose opening value were
   wrong would compare a wrong word against itself for ever after.
2. At that same edge `md_pending` must be clear. This is the invariant, and it
   fails at the instant the damage is done rather than wherever the wrong map
   entry is eventually read.
3. MD does not change between that edge and the write pulse that reads it,
   unless a `-LOADMD` strobe has arrived since. MD has two writers, so a
   change with nothing strobed is the other one, and there is nothing else it
   can be.

## What the two programs contain — measured

| | boot PROM | band |
|---|---|---|
| microcycles | 600,000 | 2,200,000 |
| `DESTMDR` writes of MD | 91,934 | 165,175 |
| `-LOADMD` strobes | 11,558 | 37,514 |
| strobes that committed a word | 5,652 | 34,849 |
| windows, a `DESTMDR` to the first map write after it | 67,588 | 74,303 |
| window length, ticks | 82 to 214 | 23 to 553 |
| window length, microcycles | 2 to 5 | 1 to 19 |
| map writes under an owning `DESTMDR` | 133,125 | 139,852 |
| of those, further writes under the same MD | 65,537 | 65,549 |
| map writes indexed by MD | 133,125 | 139,852 |
| map writes indexed by VMA with `MEMSTART` up | 0 | 0 |
| windows that carried a strobe | 5,907 | 1,778 |
| strobes that landed inside a window | 11,557 | 35,573 |
| cpu edges at which a word was owed | 0 | 357 |
| of those, a `DESTMEM` instruction | 0 | 0 |
| **cpu edges writing MD at which a word was owed** | **0** | **0** |
| **strobes that landed on a `DESTMDR` boundary** | **0** | **0** |

Both programs pass. The last two rows are the finding: the tick at which the
MD register takes its other branch is reached by neither program. Clause 2 is
measured at all 257,109 `DESTMDR` edges and the module never left the flag
set — but a defect reachable only at that tick could not have shown, which is
a different statement from the property holding. The check prints those
numbers whether it passes or fails, because a property nothing brings a load
near is a property nothing is holding.

**How near it comes, and why it does not get nearer.** A word is owed at 357
of the band's own `cpu_edge`s, so "a word is never owed at a boundary" is
false. It is owed at **none that carry a `DESTMEM` instruction**, on either
program, and `DESTMDR` is one of the two `DESTMEM` destinations. That is
`-WAIT`'s first term, `DESTMEM AND MBUSY.SYNC`, doing exactly what it is for:
an instruction that touches memory waits while the bus is busy, so it has
`MACHRUN` down at every boundary where a word could still be outstanding, and
by the time it resumes the word has committed at an intervening master clock
edge. The 357 are instructions that do not touch memory and do not wait.

So on the processor alone, with one master and this bus interface, the
coincidence is held off by a gate rather than missed by luck — which is a
much better answer than the count alone, and it is the count that establishes
it. It is not a proof that the composed machine cannot produce it: `-WAIT`
reads `mbusy_sync`, the processor's own view of its own cycle, and a
`-LOADMD` that does not come with `-MEMACK` is not covered by that argument
at all.

The nearest a strobe outside a window ever came to one is 56 ticks, 280 ns, on
the band.

## The record

`mutations/list.txt` carries `the-held-word-is-never-let-go`, which deletes
the `md_pending <= 1'b0` at the commit. Every later master clock edge then
writes `md_held` over MD, including the boundary after an instruction has just
put its own word there — a word strobed before that instruction landing after
it, which is the shape the property is about.

It is caught by `md_hold` at **microcycle 536,303**, the boot PROM's first bus
cycle, on clause 2. `microcycle` catches it too, at **microcycle 537,844**, on
MD disagreeing with muir 1,541 microcycles later. The difference is the point:
one names the flag at the instant it leaks, the other reports a wrong word
somewhere downstream. Both are worth having and neither replaces the other.

**The mutation this check was written for is not in the list, and that is the
finding rather than an omission.** Suppressing the clear only for a boundary
that carries a `DESTMDR` —

```
      end else if (md_pending && (mclk_edge || hang)
                   && !(cpu_edge && destmdr)) begin
```

— which is the defect written out as one term, **survives every check this
repository has**: `md_hold`, `md_hold_sys`, `microcycle`, `microcycle_sys`,
`machine`, `map_boot`, `ddr_boot` and `probe`. Measured, not supposed. It
survives because the precondition never occurs: no word is ever owed at an
edge that writes MD, on either program — 0 of 91,934 on the boot PROM and 0
of 165,175 on the band, and 0 at any `DESTMEM` edge at all. A record for it
would be a survivor, and a survivor needs an issue and a `@hole` rather than
a quiet entry.

## The stimulus, and why it is red

`build/md_inject.pass` is `tb/cadr_md_inject_tb.cpp` and is **not in `make
check`**. It runs MIT's boot PROM and drives one extra `-LOADMD` strobe, for
one tick, at an instant no trace reaches: the `cpu_edge` at which an
instruction writes MD. It asserts muir's rule — the edge consumes the word and
the instruction's stands — against a control run that places no strobe at all.

Driving `n_loadmd` there is not a fantasy. It is an input of
`cadr_microcycle`, and the module has to be right for what its port can be
told; and on the far side `cadr_busint_xbus.sv` drives `n_loadmd` as
`!(acked || (state == UB && ub_loadmd))` against `n_memack`'s `!acked`, so a
Unibus cycle asserts `-LOADMD` off a term `-MEMACK` does not carry.

Measured at this commit, both configurations acting on microcycle 536,405:

```
    A  control: microcycle 536405 writes MD 00000000 and no strobe is
       placed; 8 boundaries later MD is 00000000
    B  strobed: microcycle 536405 writes MD 00000000 while -LOADMD rises on
       that very tick offering ffffffff; md_pending is STILL SET after the
       edge, and 8 boundaries later MD is 00000000
FAIL: md_pending is still set after the edge.
FAIL: MD moved to ffffffff at microcycle 536406, 44 ticks after the edge.
```

Forty-four ticks is one extra-slow microcycle: the next boundary. The control
holds, so the difference is the strobe and nothing else. `MD<23:8>` goes from
`0000` to `ffff`, which is the entry a `VMA-WRITE-MAP` in that window would
reach.

The defect is therefore real at the module's own port, and unfixed. The test
is written first and left red; it joins `check` in the commit that makes it
pass, and a record may be aimed at it then and not before — a mutation caught
by a check that was already failing is caught by nothing.

## What to measure next

**Whether the composed machine can place that edge at all**, which is the one
question that decides whether the defect is a hazard or a tidiness. It is
about `rtl/machine/cadr_memory_path.sv` and `rtl/machine/cadr_busint_xbus.sv`
rather than about the processor, and two things there are worth measuring.

`n_loadmd` is `!(acked || (state == UB && ub_loadmd))` against `n_memack`'s
`!acked`, and `ub_loadmd` and `ub_acked` are two registers loaded from two
different due times. The Unibus is where the two signals come apart, and the
`DESTMEM` gate above says nothing about a strobe that arrives without the
acknowledgement its `MBUSY` is waiting on. Count, on `memory_path` or on the
composed machine, how many ticks separate `n_loadmd` falling from `n_memack`
falling, over every Unibus cycle in `busint_xbus.golden`.

And there is a second master now. `cadr_disk_controller.sv`'s channel takes
the bus for a word at a time, and the rule that "the bus must idle one tick
at every change of owner" exists because a slave's state is per cycle. What
the processor's `-LOADMD` does while the channel owns the bus is a question
of the same family, and it is not answered by anything measured here.

The cheap version of both is to add the two counters this check already has
— a word owed at a `cpu_edge`, and a strobe on a `DESTMDR` boundary — to
`tb/cadr_machine_tb.cpp` and `tb/cadr_map_boot_tb.cpp`, where the real bus
interface is underneath instead of a model of it.
