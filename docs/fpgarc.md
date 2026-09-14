<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# `fpgarc`, the card's file of flags

The board runs two CADRs. One is in the fabric. The other is inside muir, which
is the debugger. Each is configured by one file on the pack partition, in the
same format, with the same flag names. `fpgarc` is the fabric machine's and
`muirrc` is muir's. Somebody who has read one can read the other.

The partition is FAT32, so a laptop with a card reader can edit either file.
That is the point of putting them there.

## The format, which is muir's own

One flag a line. The flag comes first, then a space, then the rest of the line
as its argument. An argument with a space in it therefore needs no quoting. A
line that is blank or that starts with `#` is a comment. Carriage returns are
stripped, because a card reader leaves them.

    # this machine's own Chaosnet address, in octal
    --chaos-address 3050
    --chaos-udp 0.0.0.0:42042
    --keyboard-mapping /mnt/packs/terminal.keyboard.mapping.txt

A flag given twice is settled by the program, which takes the last one.

## One file, several programs

muir is one program, so `muirrc` goes to it whole. The fabric machine is served
by several programs. The screen, the serial line, the network and the USB input
each have their own, and the boot button has a step of its own in the disk pack
program's init script.

Every one of those programs refuses a flag it does not know. That is muir's
behaviour and it is the property worth keeping, because a flag that is quietly
ignored is a setting somebody wrote down and did not get. So the file cannot be
passed to any of them whole.

**Each init script names the flags its own program owns.** It hands the file to
the reader at `/usr/share/cadr/fpgarc.sh`, which `cadr-common` installs, and
gets back the lines whose flag is in that list. Nothing is refused anywhere in
the reader. A flag that no list names goes to nobody.

**A flag in this file therefore names one program.** That is a rule about the
flags and not about the reader. A flag two programs take is passed by the init
script that wants it, on the program's own command line, and never written
here. `--port` was the case that proved it: the screen and the serial line both
took that word, so neither could say where it listened. The section below on
`--terminal` and `--serial` is how that was settled.

## What each program takes

**The Chaosnet**, read by `S87cadr-chaosnet`. Each flag has muir's spelling and
this program's short one, and both are taken. `docs/chaosnet.md` says what each
one means.

    --chaos-address       --address
    --chaos-udp           --udp
    --chaos-udp-peer      --udp-peer
    --chaos-udp-default-peer  --udp-default-peer
    --chaos-trace         --trace

Four more are in that list although the program refuses them: `--chaos-file-root`,
`--chaos-file-peers`, `--server-name` and `--time`. They named services that
used to live inside the program and now do not, and the program answers each by
saying where the host went. Dropped by the reader instead, the card would say
nothing at all.

**The screen**, read by `S85cadr-terminal`. `docs/terminal.md` says what each
one means. `--terminal` takes nothing, a port, an address, or address:port.

    --terminal            the endpoint the screen is served on
    --keyboard-mapping    what a viewer's keysyms mean
    --keyboard-boot       the chord a cold boot is asked for with
    --keyboard-boot-trace say when a key-up is held behind a boot word
    --bow                 the display's MODE BOW
    --window              the display's region
    --interval-ms         how often the window is read
    --no-rre              send every rectangle Raw
    --input               the keyboard and mouse registers
    --no-input            do not carry the keyboard and mouse
    --input-link          the socket another source sends keys on
    --no-input-link       do not listen for one

The keyboard mapping is also taken from `terminal.keyboard.mapping.txt` beside
this file when that file is there. The init script passes that one first, so a
`--keyboard-mapping` line here wins.

**The serial line**, read by `S86cadr-serial`. `docs/chaosnet.md` has the
section on it. `--serial` takes a port or address:port, and the port must be
named.

    --serial              the endpoint the line's far end is offered on
    --regs                the register face's address
    --poll-us             how often the registers are read
    --quiet               say less

**The USB keyboard and mouse**, read by `S88cadr-usb-input`. The program takes
every flag twice, and it is the `--usb-` spelling that belongs here, because the
other spelling is a word another program could want. `docs/usb-input.md` says
what each one means.

    --usb-link            the socket the screen listens on
    --usb-device          one device to read, repeatable
    --usb-input-dir       where the evdev nodes are
    --usb-scan-ms         how often to look for a device
    --usb-grab            take the devices exclusively
    --usb-no-keyboard     ignore keyboards
    --usb-no-mouse        ignore mice

**The boot button**, read by `S80cadr-disk-packs` before it starts the disk pack
program. One flag, and the section below is about it.

    --no-auto-boot        leave the boot button unpressed

## What cannot be written here, and why

`--log` is passed by the init script, which is what decides where a daemon
writes. `--once` and `--no-guard` are for somebody at a prompt and not for a
card. `--base`, `--no-fabric` and `--device` reach past the program into the
fabric or name a word another program could want.

## `--port` and `--bind` are gone, replaced by `--terminal` and `--serial`

The screen and the serial line each used to take a `--port` and a `--bind` of
their own. Two programs answering to one word is exactly what this file cannot
carry. A flag here names one program, so neither word could be claimed by
either list, and the two settings a person is most likely to want to change
were the two this file could not say.

muir says both in one word each. `--terminal <endpoint>` is where the screen is
served and `--serial <endpoint>` is where the far end of the cable is offered.
Each belongs to one program. Both programs take those spellings now and take no
other, so there is one vocabulary on this board and it is muir's.

**The grammar is muir's own, read off its source.** An endpoint is one of four
forms: nothing, a port, an address, or address:port. A bare port is on the
default's address and a bare address is on the default's port. Anything else is
refused.

`--serial` requires the port to be named, which is muir's rule for it. Every
other endpoint has a number a person already knows to fall back on, and a
serial line has none, so an endpoint that does not say its port is an endpoint
nobody was told to attach to. `--serial 127.0.0.1` is therefore refused and
`--serial 7641` is not.

**The one place these part from muir is the default address, and the difference
is the board's rather than the flag's.** muir binds the loopback unless told
otherwise, which is where an unauthenticated server belongs on a machine
somebody is sitting at. This board has no screen and no terminal of its own,
and both programs exist to be reached from another machine, so their default is
every interface. That was this board's decision long before these flags
existed. The grammar is unchanged; only the default it is read against differs.
The card writes both endpoints out in full, so nothing on a real board rests on
which default is which.

## The file is the whole menu

The card script writes every flag every program takes out of this file, grouped
by program, each under a sentence or two saying what it does and what it falls
back to. The flags a card uses are live and the rest are commented out.
Somebody with the card in a reader therefore sees the whole list and uncomments
what they want, instead of going elsewhere to find out what may be said here.

A commented-out setting is written as `#` with the flag straight after it. A
flag inside an explanation is indented away from the `#`. So `#--bow` is a
setting to uncomment and `#     --chaos-udp-peer <address>@<host>:<port>` is a
sentence about one. The reader treats both as comments. The difference is what
lets `fpgarc.pass` count the settings, and it holds every flag in every init
script's list to appearing in the written file exactly once. A flag added to a
program and not to the card fails that check by name.

Two flags may appear more than once, because they are repeatable by their own
definition. A peer entry places one Chaosnet address, and a named USB device is
one device.

Four flags in the Chaosnet's list are written commented out with a note saying
the program refuses them. They are not part of the menu. They named a file host
and a time host that used to live inside that program, and they are listed so
that a card still carrying one gets an answer about where the host went.

## A line no program takes is named at boot

Nothing in the reader refuses anything. That is what lets one file serve five
strict programs, and it is the one way a setting can still be lost. `--bwo` for
`--bow` is a card that says something and a board that does nothing, with every
program starting cleanly and nothing to read.

So the last init script to read the file names what went to nobody, in one line
on the console. Every script records the flags it claimed as it reads the file,
and the last one compares the file against all of them. A flag for a program
that is not installed on this board is reported too, which is true and worth
knowing.

The lists are not gathered anywhere to do this. A union written in one place
would be a second copy of five lists and a second place to be wrong. What the
last script compares against is what the scripts that actually ran asked for.

## A flag a program refuses is printed, not swallowed

Every one of these programs refuses a flag it does not know. That refusal used
to go nowhere. An init script starts its program with `start-stop-daemon -b`,
which daemonises it and closes its output, so the program printed its refusal
into `/dev/null` and the script printed `OK`. A carriage return on every peer's
port once cost this board its whole Chaosnet that way, on a boot that looked
perfect.

Every init script now starts its program through `cadr_daemon`, which
`cadr-common` installs at `/usr/share/cadr/daemon.sh` beside the reader. It
starts the program, looks for it a moment later, and prints `OK` only if it is
there. If it is not, it prints `FAIL` and then runs the program once more with
the same words and prints what it says. That is the refusal, in the program's
own words, on the console.

Running it again is safe because it only happens when the program is already
gone. A refusal happens at argument parsing, before the program has opened
`/dev/mem`, bound a socket or touched the fabric, so a second run refuses
identically and does nothing else. A start-up check that failed is
deterministic too, and just as worth printing. A program that ran and then died
is the only case where the second run would really run, and it is bounded: the
second run is killed by its own process id a moment later, and the script says
that the flags were not what stopped it.

The moment is one second, and the board has five programs. There is no shorter
honest interval. `start-stop-daemon` returns as soon as it has forked, before
the child has read a flag, so looking at once would find every program alive
including the ones about to die. A whole second is also the only interval a
POSIX `sleep` is certain to take. Five seconds on a board that reaches a login
in fifteen is the price of a class of failure that has already cost this
project a night.

## `--no-auto-boot`

muir's flag, and it means here what it means there: leave the boot button
unpressed, as a CADR is when the power comes on with nobody at the button. The
machine is held with RUN clear and nothing running.

The fabric keeps RUN preset at reset, which is muir's own default and what the
bring-up boards need. So a board that is not to boot itself is held by halting
it. `S80cadr-disk-packs` reads the flag, halts the machine with `cadr-console
halt`, and leaves a marker at `/var/run/cadr-held`. It prints one line saying
the machine is held and that `cadr-console boot` or BTN0 on the board presses
the button. Without the flag it does nothing and says nothing.

**The step is in that script for two reasons.** It must run before the disk pack
program starts, because a drive coming present is what lets the boot PROM go on
and read a band. And it must read this file, which is on the partition that
script is the one thing that mounts. A step of its own at S79 would have to
mount that partition itself, which would leave the mount with two owners and
one unmounter.

**The PROM has already run when Linux halts it, and that is not a gap in the
hold.** The CADR starts when the bitstream is loaded, which is seconds before
Linux reaches this step. Within a few hundred milliseconds it has cleared its
control store and reached `AWAIT-DRIVE-READY`. It can go no further, because no
drive is present until the disk pack program starts. So the machine that is
halted has done its PROM work and is waiting, with nothing of a band loaded.
`cadr-console boot` presses `-BOOT2`, which presets RUN and starts the PROM
again from zero.

While the marker stands, `cadr-console` refuses `start` and `step`, in muir's
own words. `boot` presses the button and removes it. BTN0 on the board presses
the same line in the fabric, so a held machine can be booted by hand with
nobody logged in.

The marker is under `/var/run`, which is on the root filesystem, and that is a
RAM disk unpacked at every boot. A marker cannot in fact survive a reset. The
init step removes a marker it finds all the same, because a `restart` of that
script is a case that can leave one standing, and a marker that outlives its
hold is a lie about the machine.

## What the card script writes

`boards/arty-z7-20/linux/mksd-buildroot.sh` writes this file. It writes every
flag every program takes, grouped by program, with an explanation above each.

The live lines are the Chaosnet address and the cable, which are the same on
every card; the peers and the bridge, which come from `local.conf`; the
screen's endpoint and the serial line's, written out in full; and the boot
keyboard's chord. Everything else is commented out with what it does. The
`--no-auto-boot` line is commented out with the sentence that explains it.

`NO_AUTO_BOOT=1` in `local.conf` makes that same line live. The two cards then
differ in one character and carry the same explanation. A released card always
boots its band by itself, because `STANDALONE` clears the setting along with
everything else that comes from `local.conf`.

## What holds all of this

`make check`'s `fpgarc.pass` runs `fpgarc_test.sh` in `cadr-common`. It runs the
five real init scripts, with the tools they call stubbed, against one file that
has a line for every program on the board. Each program must get its own flags
and no others. A few constants in each script are rewritten so that nothing
reaches a real board, and every rewrite is asserted to have matched exactly
once, so renaming a constant fails the check by name.

It also holds the reader itself: a carriage return that must not reach a
program, an argument with spaces in it, an argument with a quote in it, a bare
flag, a commented-out flag, a flag no list names, and a file that is not there
told apart from a file with nothing in it. It holds the boot button's step under
a stubbed console, both when the flag is there and when it is not, and it holds
the card script's two ways of writing the line.

One case in it claims another program's flag on purpose and requires that the
flag then arrives. Everything else in that section is an absence, and an absence
is also what a check looking at the wrong thing reports.

**It holds the refusal.** The stubbed `start-stop-daemon` forks the program and
closes its output, as the real one does, and a stand-in program on the stub path
refuses one named flag on stderr, as all five do. Each script is then required
to print that refusal and not to print `OK`. Each is required to print `OK` on
the same run with nothing refused, because a check that always saw `FAIL` would
pass the first half while saying nothing. A program that exits at once and says
nothing is a case of its own, and the script must say that it died at start.

**And it holds the written file to the programs' own lists.** Every flag named
in any init script's list must appear in what the card script writes exactly
once, live or commented out. The requirements are read out of the scripts and
never from a list in the check, because a second list is a second place to be
wrong. One line of a script's list is one requirement, since the Chaosnet
program takes two spellings of each of its flags and a card says a setting once.

`chaosnet.pass` holds the Chaosnet script's own wait for the network, and it now
also holds that script to taking its own flags out of a file written for the
whole board.

No mutation record can aim at any of this. The runner compiles C, so a record
naming a shell script would be broken by construction. The evidence that the
check can fail is that it was written against the tree before the reader existed
and did fail there.
