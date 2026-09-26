# Mutation-based verification

`make check` says the checks pass. `make mutants` says the checks can still
fail. This document says what the second one is, where it comes from, and
why this project holds its checks to it.

## What it is

A mutation is a deliberate, small, wrong version of the design. The runner
applies one mutation, rebuilds, and runs the check that is supposed to hold
that part of the design. The check must fail. If it does, the mutation is
caught. If the check passes anyway, the mutation survived, and the check
cannot tell a right design from that wrong one.

So the thing measured is not whether the checks ran over a line. It is
whether the checks would notice if that line were wrong. Line coverage cannot
see the difference. A line can be executed by every test and still be
unchecked, because no test looks at what it produced.

## Where it comes from

The idea is from software. It was set out in 1978 as a way to judge test
data, and it has mature tools today, such as PIT for Java, Stryker for
JavaScript, mutmut for Python and cargo-mutants for Rust. It stays a minority
practice there for three reasons. Each mutant costs a build and a full test
run. Some mutants are equivalent to the original and have to be argued away
by hand. And line coverage is free and looks like the same thing.

Hardware has an older relative, fault simulation, where stuck-at faults are
injected into a netlist to see whether a test pattern detects them. That is
about testing a chip after fabrication. The design-verification form, often
called mutation-based or fault-injection verification, exists as commercial
tools and is used where a standard demands evidence that a verification
environment can catch faults. Most hardware teams rely on functional coverage
and assertions instead.

## What a record is

The mutations live in `mutations/list.txt`, one record each. A record names
the check that must catch it, the file it changes, why the change is wrong,
and the literal text to replace. This one is from the bus interface:

```
@mutation memack-registered-on-a-write
@check busint_xbus
@file rtl/machine/cadr_busint_xbus.sv
@note XACK is made from XBUS ACK IN by the 74S64 at REQLM 0C11 --- a gate.
@note Only a read goes through the 60 ns tap of the TD100 at 0C09. Registering
@note both puts the acknowledgment a tick late on every write.
@old
              || (state == GRANTED && ((write && answering) || deskewed))
@new
              || (state == GRANTED && ((write && answered) || deskewed))
@end
```

The `@old` text is the fabric as it is. The `@new` text is a plausible
mistake. The note says which part on MIT's drawing makes it a mistake. The
trace against muir catches it, because every write then acknowledges one tick
late.

Records are literal text rather than patches. There are no line numbers and no
context, so a record rots only when the lines it names change. The `@old`
text must match its file exactly once, or the run stops before it starts.
`mutations/anchors.py` checks that in a few seconds and runs before every
merge that touches the list.

## How a run works

`make mutants` runs `mutations/run.py`. The working tree is never mutated.
Each record gets a fresh copy of the sources, is applied there, built there,
and run there. Before any mutation runs, the unmutated copy must pass every
check that has mutations against it. A catch by a check that was already
failing is worth nothing.

The runner reports each record as one of five things:

| verdict | meaning |
|---|---|
| caught | the check failed, as it should have |
| survived | the check passed; a new finding, and the run fails |
| hole | survived, and the record carries `@hole` naming the issue that holds it |
| closed | caught while still carrying `@hole`; the run fails, because the hole is gone and the line must go |
| broken | the build failed; not a verdict on the check, and the run fails |

A build failure is never counted as a catch. Two mutations were once reported
as surviving when lint had rejected them and a stale binary ran. A record can
declare `@build-fails` when the refusal to build is itself the finding, and a
record carrying it that then builds is broken too.

Most of a mutant's build is text no mutation touched: Verilator's runtime,
the testbench, and the parts of the model outside the mutated module. With
`--ccache`, which `make mutants` passes, the builds compile through ccache, so
only the changed translation units are compiled again. This does not weaken
the rule above. A cached object is keyed on the exact text it was compiled
from, so a mutated unit is always compiled, and every mutant is still linked
and run. The records also run longest first, with the known holes ahead of
all of them, because a survivor then runs every other check that builds its
file. The order changes nothing else, and the report stays in list order.

Three flags matter in practice. `--rev` mutates a commit's sources rather than
the files on disk, so a run is against a commit and not against whatever the
shared tree held at the time. `--since` re-runs every survivor and hole
against an earlier revision. Anything caught there is a check that has got
weaker, not a hole. `--only` runs the records whose name or check contains a
word. The runner also has a `--self-test` that plants faults in itself: a
build that fails must be broken and never caught, and two generator mutations
must report two different failures.

## Why this project uses it

Every check here compares the fabric against a reference, muir, tick for tick.
That makes "caught" sharp. There is no oracle to write for each mutation,
because the trace already says what right is. The design is also small enough
that a full run takes hours rather than days.

The failure it exists to catch is a check written to confirm rather than to
compare. That failure happened here more than once before the list existed,
and each time the check was green.

- A register stopped being a testbench input and became an output of the
  module. The line that drove it from the testbench kept working, because the
  simulator lets a testbench write an output, and the register was checked by
  nothing while both processor checks passed.
- The control store came up zero, as the reference does, and the boot PROM
  writes zero to all of it. Dropping the write pulse for all but one address
  survived, because a write that never happened read back exactly like one
  that did. The store comes up all ones now.
- A ten-bit counter wrapped and dropped a bus request level for sixteen ticks
  in any cycle that ran past 1,024 of them. Six checks and sixty-three
  mutations passed over it, because no slave was ever listening when it
  happened.
- The memory bridge held the last word it returned and strobed the memory
  data register with it on every unanswered cycle. Six checks, two processor
  traces and a hardware capture had passed over it.

The list also says when a check has got weaker. A record caught at one commit
and surviving at a later one points at one diff. Without the comparison, a
weakened check is invisible, because it goes on passing.

## What it cannot do

The list is written by hand, one fault at a time. It holds the faults
somebody thought worth holding, usually because they were made once. It is
not exhaustive, and a check can be blind to a fault nobody has written down.

Some mutations are equivalent to the original. Dropping the edge test on the
timeout oscillator survives every check and is not a hole, because the next
count lands exactly where it would have anyway. The reasoning belongs in the
record, so that nobody files a false hole later. Where a sweep of the
magnitude shows an equivalence at small values and a catch at larger ones,
the record keeps the smallest magnitude that is caught.

Lint must not do the catching. Verilator runs with warnings fatal, so a
mutation that leaves a signal or a bit unread fails to build and the check
never sees it. Several records are written to keep every bit used for that
reason.

A mutation downstream of an exhaustively checked guard tests the guard and
not the thing. A slave's address match cannot be mutated wider while the
mutation honors the decode's select, because the decode is checked false at
every empty address. Such records are written ungated.

A recorded hole is where a regression hides. A survivor with `@hole` keeps
the run green and says "known", and nothing asks whether it was always known.
`--since` is the answer: a hole that used to be caught reddens the run.

## The practice

The gate before any push is `make check` and `make mutants` together, at the
commit, in a fresh worktree. `make check` alone was green for eleven pushed
commits while the mutation run was dead at parse, because one record's anchor
had stopped matching.

A change that touches a file re-runs every record aimed at that file, not
only its own. Two slices met that rule the hard way: a record caught before a
slice survived after it, on a slice that was gated and green by its own runs.

A record's reasoning ages faster than its text. The text rots loudly, since
the anchor stops matching. The reasoning rots silently and goes on reading as
true. Records cite the commit their reasoning was true at.

At `e387e31` the list holds 557 records. The gate at that commit caught 555,
with 2 known holes against issue 1 and none surviving. The two holes are
terms of `-WAIT` that no program the traces run ever makes true, so no check
can see them removed. They are recorded rather than pretended to be checked.
At `dc40ab6` the list holds 653 records, and the two holes are the same two.
