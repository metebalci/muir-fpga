<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# The debugger's disk pack

muir on the board is the far end of the debug cable. The debugger itself is
not muir. The debugger is CC, MIT's own console program, running on a CADR
that muir simulates. So muir on the board needs a band to boot, and that band
needs CC in it.

muir's own `tests/cc_304.rs` gets CC by compiling it over the Chaosnet FILE
service from a host on the model network. That is the right thing on a build
host. It is the wrong thing on the board, where it would mean standing a
Chaosnet file host up beside muir before the debugger could exist at all.
This pack removes that dependency. CC is compiled once, here, and the world
is saved back into a partition of the pack. On the board the debugger is a
pack you boot.

`tools/make-cc-pack.sh` builds it. `tools/cc-pack/cc_pack.rs` is the program
it drives.

## What the pack is

It is the System 304 release pack with a new band in a spare partition.

| | |
|---|---|
| Geometry | Trident T-300, 815 cylinders, 19 heads, 17 blocks a track |
| Size | 269,562,880 bytes, 263,245 blocks, 257.1 MiB |
| Release | System 304.0, ZWEI 130.0, microcode 323 |
| Band | `LOD3` by default, 24,225 blocks at block 115,278 |
| Current band | set to the saved one, so the machine boots it with no argument |
| In the band | the whole `CADR-DEBUGGER` system, and the microcode's own symbol table for version 323 |

The band's partition comment reads `Exp 304.0`, which is what
`SYSTEM-VERSION-INFO` gives and what the release's own band says. The pack
therefore has two partitions with that comment: `LOD2`, the release as
published, and `LOD3`, the same release with CC in it.

Every pack this project makes is a T-300. A T-80 was offered and declined.

The name must not be `disk-pack-0.img` through `disk-pack-7.img`, because
that is what `cadr-disk-packs` takes for the CADR's own drive bay. This pack
is muir's, not one of the CADR's drives. The script's default name is
`muir-cc-304.img`.

## Where it goes

It goes in the packs partition, next to the other packs, at
`/mnt/packs/muir-cc-304.img`. The boot partition does not grow.

The room is there. A T-300 is 257.1 MiB. A full bay of eight is 2,056.6 MiB,
and with the debugger's pack beside them 2,313.7 MiB. The release card's
packs partition is 3,584 MiB, so 1,270.3 MiB is left over.

## Using it

muir needs the pack and the band's own Chaosnet address. Nothing else about
the pack is special.

    muir --rtl --disk-pack /mnt/packs/muir-cc-304.img --chaos-address 4401

Measured with that command on the build host: muir reports `pack: ... in unit
0, written as the machine writes it`, runs at about five million microcycles
a second, and has the band up and asking for the date well inside sixty
million microcycles. `(cadr:cc)` at the listener is the debugger.

**The pack is written as the machine runs.** muir opens `--disk-pack`
read-write, so the board's copy drifts from the moment it first boots. That
is what a drive does to a pack, and it is why the digest below identifies the
pack as built rather than the pack as it will be found.

## Which release, and why

System 304, at the check-in `tools/fetch-system-304.sh` names. That was
settled before this work started. It is the more expensive of the two
choices: System 100 ships `CC QFASL` in its release and System 304 ships the
sources alone, so on this release CC has to be compiled on the machine before
it can be loaded.

It boots well. It reached its Lisp Listener at microcycle 11,000,000, which
is 2.3 seconds of wall clock on the build host, with the harness's Chaosnet
server answering. The herald reads:

    LM-3 System, band 2 of AMS-LISPM-1.
    2048K physical memory, 16127K virtual memory.
     Experimental System 304.0
     Experimental ZWEI    130.0
     Microcode            323
    AMS Lisp Machine One, with associated machine OZ.

That is six lines where System 100's herald is five, which matters only
because a test that watches for the prompt by counting lit pixels in a band
of rows has to cover both.

The two bands are different machines and want different numbers. System 304's
band is `AMS-LISPM-1` at 4401 octal and calls its file and time host `OZ` at
4403. System 100's is `MIT-LISPM-1` at 3050 calling `MIT-OZ` at 3060. At any
other pair the machine boots and reaches no server at all.

## How a band is saved

The mechanism is MIT's own `SI:DISK-SAVE`, in `sys/qmisc.lisp:1157`. Its
second argument is `NO-QUERY`. With that argument true the routine asks the
keyboard nothing at all: it takes the version string from
`SYSTEM-VERSION-INFO` instead of prompting for one, and it skips the
confirmation. So `(si:disk-save "LOD3" t)` is the whole of it.

The form does not return. It ends in the `%DISK-SAVE` microcode operation,
which swaps every page out, finds the partition, writes the world into it
region by region, and finishes at `COLD-SWAP-IN` — "Physical core now
clobbered, so re-swap-in", `ucadr/uc-cold-disk.lisp:174-176`. The world comes
back out of the band that was just written. The machine carries on with a
fresh herald reading `band 3 of AMS-LISPM-1` and a who-line saying it
cold-booted.

Two consequences are worth stating. The machine does not return to the band
the label calls current, and it does not touch the label's current-band word
at all. That word is set afterwards with `diskpack`, off the machine, because
`SET-CURRENT-BAND` is something you do at a listener and the listener the
save left behind belongs to the new band.

Everything the save writes reaches the file because muir opens a pack
read-write. `Unit::open_rw` is what `muir --disk-pack` does; `Unit::open` is
what muir's own tests do, so that fetched packs stay as fetched. The pack
this script writes is always a copy.

## A world with CC freshly loaded in it cannot be saved

**This is the one thing that does not work by itself, and it was found by
the save falling over after the compile had already run.**

`DISK-SAVE`'s first act is to run the `BEFORE-COLD` initialization list.
`cc/cc.lisp:1400` adds one to that list called "Assure CC Symbols loaded". It
calls `ASSURE-CC-SYMBOLS-LOADED`, which reads
`CC-FILE-SYMBOLS-LOADED-FROM`. That variable is `(DEFVAR ... :UNBOUND)` in
`cc/cadld.lisp:5`, and nothing binds it when CC is merely loaded. So the save
stops in the error handler on

    >>TRAP 8084 (TRANS-TRAP)
    The variable CADR::CC-FILE-SYMBOLS-LOADED-FROM is unbound.
    While in the function CADR::ASSURE-CC-SYMBOLS-LOADED

and never writes a block. It waits there for a key that nobody will press.

The fix is to set the variable to `NIL` and run the initialization by hand
before the save. That is not a way around it. It is what makes it do its job:
with `NIL` there the version test fails, and the initialization loads
`SYS: UBIN; UCADR SYM #323` over the file service. Those are the microcode's
own symbols, which are what let CC name a control-store address instead of
printing a number.

So the band carries them, and the save's own run of the list then finds the
right version already loaded and does nothing. **The file service pays for
itself twice here**: CC compiled, and CC's symbols, neither of which the
board can fetch for itself.

The program fails fast on this now. A save that has written nothing to the
partition after 2,000,000,000 microcycles is not going to, because a bare
save reaches the partition inside eight million, so the run stops there and
writes the screen out rather than waiting forty billion microcycles with
nothing to look at.

## What the run costs

Measured on the build host, with the `rtl` engine and one machine, which
runs at about five million microcycles a second.

| | |
|---|---|
| Boot to the listener | 11,000,000 microcycles, 2.3 s |
| `make-system` compiling all sixteen files | 10,332,154,000 microcycles, about 35 minutes |
| `make-system` loading them already compiled | 1,147,154,000 microcycles |
| Loading the microcode's symbols | 930,000,000 microcycles |
| The dump, with CC in the world | 75,558,000 microcycles |
| The dump, on a bare world | 7,708,000 microcycles |
| A bare save, form typed to herald back | 672,078,000 microcycles, 112.4 s |
| Booting the saved band and asking it for `CADR:CC` | 9.6 s |

The compile is nearly all of it. Everything else together is under ten
minutes.

**The compiled files are worth keeping if a run has to be repeated.** They
are QFASLs written back through the file service into the sources' own `cc/`,
so a second run with the same file-service root loads them instead of
compiling again. A whole build then takes nine minutes rather than
forty-five.

## Reproducibility

**The run is reproducible to the microcycle. Whether the file is
byte-identical between runs has not been measured, and should not be assumed.**

The machine's own execution is deterministic and the harness gives it a fixed
universal time, so two independent runs that compiled all sixteen files
reached exactly the same counts: `make-system` took 10,332,154,000
microcycles in both, and CC was loaded at microcycle 10,417,717,000 in both.
That is worth knowing, because it means a run that goes wrong goes wrong in
the same place.

The file is a different question. A band is a dump of a running Lisp world,
and the world holds the truenames of every file it loaded. The FILE service
writes through a temporary whose name carries a process id, so there is at
least one plausible way for two runs to differ in their bytes. Nobody has run
the script twice under identical conditions and compared, so the honest
statement is that the procedure is reproducible and the artefact is
identified by its digest rather than predicted by it.

A pack is named by three things together: its digest, the commit of muir it
was built with, and the release it was built from. The script prints all
three when it finishes.

The pack is also a pack a machine has written, so this project's standing
rule applies to it: a drive writes its pack, and any run that opens it
read-write moves it. The output is a fresh copy of the release pack plus one
band. Keep it as the reference and let the board write its own copy, or
accept that the board's copy drifts.

## How the program is built

The program is one of muir's own integration tests, and that is deliberate
rather than convenient. The Chaosnet server that serves the release as `SYS:`
lives in muir's `tests/support/`, not in its library. Nothing outside a muir
test binary can compile a Lisp file on a simulated CADR.

So `tools/cc-pack/cc_pack.rs` is this repository's file, and
`tools/make-cc-pack.sh` copies it beside muir's own tests in a build tree of
its own. The muir checkout it is given is never written to. The release's
sources are copied rather than linked, because `make-system :compile` writes
every QFASL back through the file service and the vendored sources must not
be what it writes into.

The program has five tests, each run on its own, so that a cheap one can be
had without the expensive one. The script runs two of them; the other three
are measurements.

| | |
|---|---|
| `boots_system_304` | the band reaches its listener |
| `saves_a_band` | the saving mechanism alone, with nothing loaded |
| `builds_the_cc_pack` | compile CC, load it, save the band |
| `the_saved_band_has_cc` | boot the saved band and ask for `CADR:CC` |
| `the_saved_band_with_no_network` | what a user at the board sees |

`saves_a_band` is worth keeping for its own sake. It answers the question the
whole plan rests on in under two minutes, where the plan itself takes an
hour.

## What told the run it was finished, and what did not

Knowing when `DISK-SAVE` is through is the awkward part, because the form
never returns. Two obvious signals were tried and both are wrong.

The screen is not the signal. `DISK-SAVE` deexposes every screen before it
dumps, so the thing to wait for looks like the screen going black and the
herald coming back. A deexposed sheet leaves its bits where they were, so it
never goes black. Worse, the rebooted herald lights 18,299 pixels where the
screen before the save lit 18,301. That coincidence would have read as
"nothing happened" for as long as anyone cared to wait.

The drive's head position is no better. muir's controller moves a whole
command list in one call, so `Unit::position` is where the last list ended. A
sampler taking it every 500,000 microcycles never saw it inside the partition
at all.

The pack itself is the signal, which is right in principle as well as in
practice, because the pack is the artefact the run exists to make. Six blocks
spread through the partition are read back out of the file while the machine
writes it. When they have changed from what they were and then stayed put for
600,000,000 microcycles, the dump is over. The reboot that follows only
reads.

## What the board sees, with no network at all

muir on the board has no file host and no time host. Measured, that is not
fatal and it is not silent.

The saved band comes up and prints `Please type the date and time:` and
waits. Type a date and it asks `OK? (Y or N)`; answer `Y` and it goes on to
its herald and its Lisp Listener. That took 83,400,000 microcycles in all,
which is about fourteen seconds of wall clock, nearly all of it the machine
waiting to be typed at.

**The band reads the date the British way round.** `09/12/26` came back as
"the ninth of December, 1926", so it is day, month, year, and the year wants
all four digits. `12/09/2026 21:30:00` is read as the twelfth of September
2026.

With no server the herald reads `AMS Unknown, with associated machine
ED-FILE` rather than naming `OZ`. `ED-FILE` is a name the band's own site
configuration still refers to and its host table no longer contains. It is
what the band falls back to when nothing answers, and it is not an error
here.

So a user at the board types two short lines and has a Lisp Listener with CC
in it. If that is not wanted, the other answer is already in the plan:
`cadr-chaosnet` answers the TIME lookup, and for System 304 it would need
that band's own numbers, 4401 calling 4403, where System 100 uses 3050 and
3060.

## The partitions of the System 304 pack

The release pack has four spare bands and a fifth larger one, so the saved
band displaces nothing.

    MCR1  block      17,    148 blocks   "UCADR 323"
    MCR2 to MCR8     165 to 1200, 148 blocks each, empty
    PAGE  block    1292,  65536 blocks   the paging area
    LOD1  block   66828,  24225 blocks   "cold 27-May-25"
    LOD2  block   91053,  24225 blocks   "Exp 304.0", the release
    LOD3  block  115278,  24225 blocks   empty; where the saved band goes
    LOD4 to LOD6   139503 to 212177, 24225 blocks each, empty
    LOD9  block  212178,  51067 blocks   empty

`BAND` in the environment picks another. `LOD9` is the one to use if the
world with CC in it ever outgrows 24,225 blocks; `SI:DISK-SAVE` checks the
size itself and refuses rather than overrunning.

## The first one built

`tools/make-cc-pack.sh` was run end to end on the build host and it made a
pack that boots with CC in it.

| | |
|---|---|
| Digest | `455e522638ba1658d7d07814bf2dcf2555118e55c80c5ff99d6411bd80bb6628` |
| Size | 269,562,880 bytes |
| muir | `0486b0af69706da689004439da6e96a39c7769d7` |
| Release | System 304, at the check-in `tools/fetch-system-304.sh` names |
| Band | `LOD3`, the label's current band |
| Built | 12 September 2026, in about thirty-five minutes |

It was checked three ways. `the_saved_band_has_cc` booted it and `CADR:CC`
answered `CC-LOADED` at microcycle 50,826,000. `the_saved_band_with_no_network`
booted it with nothing on the Chaosnet cable and reached a Lisp Listener once
a date was typed. And `muir --rtl --disk-pack <it> --chaos-address 4401`,
which is the command the board will run, brought the band up to its date
prompt.
