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
flags and not about the reader. `--port` is taken by the screen and by the
serial line both, so no list may claim it and no line here can say it. A flag
two programs take is passed by the init script that wants it, on the program's
own command line.

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
one means.

    --terminal            the endpoint the screen is served on
    --keyboard-mapping    what a viewer's keysyms mean
    --keyboard-boot       the chord a cold boot is asked for with
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
section on it.

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

`--port` and `--bind` are the screen's words and the serial line's both. A flag
here names one program, so neither can be a line in this file. muir says the
same things as `--terminal <address>:<port>` and `--serial <address>:<port>`,
one word each and each belonging to one program, and those are the spellings
this file takes.

`--log` is passed by the init script, which is what decides where a daemon
writes. `--once` and `--no-guard` are for somebody at a prompt and not for a
card. `--base`, `--no-fabric` and `--device` reach past the program into the
fabric or name a word another program could want.

Two of the spellings above are in the lists before their programs take them.
`--terminal` and `--keyboard-boot` arrive with the screen's own work, and
`--serial` with the serial line's. Until then a card that names one gets that
program's own refusal. They are listed now so that the line goes to its own
program on the day it lands, rather than to nobody.

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

`boards/arty-z7-20/linux/mksd-buildroot.sh` writes this file. It writes the
Chaosnet address and the cable on every card, the peers and the bridge from
`local.conf`, and the `--no-auto-boot` line commented out with the sentence
that explains it.

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

`chaosnet.pass` holds the Chaosnet script's own wait for the network, and it now
also holds that script to taking its own flags out of a file written for the
whole board.

No mutation record can aim at any of this. The runner compiles C, so a record
naming a shell script would be broken by construction. The evidence that the
check can fail is that it was written against the tree before the reader existed
and did fail there.
