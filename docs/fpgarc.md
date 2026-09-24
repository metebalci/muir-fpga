<!--
SPDX-FileCopyrightText: 2026 Mete Balci
SPDX-License-Identifier: AGPL-3.0-or-later
-->

# `fpgarc`, the card's file of flags

The board runs two CADRs. One is in the fabric. The other is inside muir, which
is the debugger. Each is configured by one file at the root of the card, in the
same format, with the same flag names. `fpgarc` is the fabric machine's and
`muirrc` is muir's. Somebody who has read one can read the other.

The card is FAT32, so a laptop with a card reader can edit either file. That is
the point of putting them there, and the root is where a person looks.

## The format, which is muir's own

One flag a line. The flag comes first, then a space, then the rest of the line
as its argument. An argument with a space in it therefore needs no quoting. A
line that is blank or that starts with `#` is a comment. Carriage returns are
stripped, because a card reader leaves them.

    # this machine's own Chaosnet address, in octal
    --chaos-address 3050
    --chaos-udp 0.0.0.0:42042
    --keyboard-mapping /mnt/card/terminal.keyboard.mapping.txt

A flag given on more than one line is taken from its last line. The console
says so at boot, in one line naming the flag and every line it is on, such as
`fpgarc: --date is on lines 3 and 7 of /mnt/card/fpgarc; line 7 is used and the
others are not`. A warning on a board is easy to miss, so the value used is the
one a person most plausibly meant, and somebody editing a file expects the line
further down to win.

Every reader of the card follows this rule, and no program is left to settle a
repeat. The init script hands its program the last line alone. A script that
also reads a value for itself reads the same line, so the two cannot disagree.
The ozd script writes the Chaosnet program's peer from `--ozd-chaos-address`
and hands ozd the same address. The two spellings of a Chaosnet flag, such as
`--chaos-address` and `--address`, count as one flag. The flags that may repeat
are listed below, and they keep every line without a warning.

## One file, several programs

muir is one program, so `muirrc` goes to it whole. The fabric machine is served
by several programs. The screen, the serial line, the network and the USB input
each have their own, and the boot button has a step of its own in the disk pack
program's init script.

Every one of those programs refuses a flag it does not know. That is muir's
behavior and it is the property worth keeping, because a flag that is quietly
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

## A default is passed only where this file says nothing

An init script writes some of its program's settings out in full, so that the
script itself says what it does. The screen's endpoint is one. The Chaosnet
address switches are another, and the keyboard mapping file beside this one is
a third.

A card that names one of those flags wins. The script asks the reader whether
this file carries the flag before passing its own value for it. So the flag
stands on the program's command line exactly once, with the card's value where
the card has one and the script's where it has not.

Passing both would work, because a program takes the last flag it is given. It
would also put the same flag on the command line twice, which reads as a fault
to anybody looking at `ps` to see what a program is doing. The board ran
`cadr-terminal --terminal 0.0.0.0:5900 --terminal 0.0.0.0:5900` until this was
fixed.

## Two settings are off when this file says nothing, and that is muir's rule

The Chaosnet cable and the serial line are not defaults a script supplies. They
are things a user plugs in.

`--chaos-udp` is the cable. Without it the Chaosnet program sets its address
switches and sends nothing, which is what a machine with no cable does. muir
behaves the same way: the switches are one flag and the cable is another,
because they are two things on the board. A card that is there and says nothing
about `--chaos-udp` is a board on no network, and the init script says so on
the console and does not wait for a network it has nothing to reach.

`--serial` is the serial line. Without it the serial program is not started at
all. muir gives `--serial` no default, because a port it invented would be one
nobody knows, and a line nobody asked for is a port nobody was told to attach
to. The init script says the line is off and how to turn it on.

**A file that is there and says nothing is not the same as no file.** A file
that is there has been asked and has answered. No file at all is nobody having
been asked, and it is also what a boot looks like when the card did not mount.
A board in that state runs what it has always run: the Chaosnet address and
the cable, and the serial line on its own endpoint.

## What each program takes

**The Chaosnet**, read by `S87cadr-chaosnet`. Each flag has muir's spelling and
this program's short one, and both are taken. `docs/chaosnet.md` says what each
one means.

    --chaos-address       --address
    --chaos-udp           --udp
    --chaos-udp-peer      --udp-peer
    --chaos-udp-default-peer  --udp-default-peer
    --chaos-trace         --trace

Four flags are deliberately absent from that list. `--chaos-file-root`,
`--chaos-file-peers`, `--server-name` and `--time` named a file host and a time
host that used to live inside the program and now do not. A flag that no
program has is not a setting this file can carry. A card still carrying one of
the first three is named at boot by the report below, which says the line went
to nobody. The program itself still refuses each by name, saying where the host
went, for somebody who passes one by hand.

`--time` is the exception among those four, and the reason is worth stating.
The word now names the clock's time of day, which the section below has, and
the disk pack program's init script claims it. So a card carrying `--time` is
a card setting this board's clock, and it never reaches the Chaosnet program.
The refusal there stands for somebody who passes the flag to that program by
hand, and it is about the time host that went, which is a different thing.

**The file and time host on this board**, read by `S84ozd`. `docs/chaosnet.md`
has the section on it. Every setting is spelled `--ozd-` because a word like
`--root`, `--host`, `--name` or `--port` is a word another program could want,
and each maps to one of that program's own flags.

    --no-ozd              do not run it at all
    --ozd-chaos-address   the Chaosnet address it answers at, in octal
    --ozd-name            its names, the official one first
    --ozd-port            the loopback port it listens on
    --ozd-root            a tree it serves, repeatable.  A card that carries
                          a band carries its sources in `sys/` and its site
                          configuration in `site/`, and both lines are live
                          on it.  `sys` carries `,ro` and `site` does not
    --ozd-host            a machine in the host table it answers from,
                          repeatable
    --ozd-hosts-text      a band's own host table, whose hosts it also answers
                          for
    --ozd-trace           say every packet

**It is on when this file says nothing**, which is the opposite of the cable
and the serial line and is deliberate: a board with no network had no file
host and no time host at all, and one on the board costs almost nothing. The
section below is about the flag that turns it off.

**The `site` tree is served read-write, and so the host can write the whole
card.** A band saves the host table it generates into `site/`, and the host
refuses a writable tree it cannot write. So `S80cadr-disk-packs` mounts the
card with its group set to the `ozd` group and `umask=0002`: root and that
group may write, and everybody may read. The group's id is looked up at boot,
because the image picks it when it is built. An image without the `ozd` user
mounts the card as root's alone, with `umask=0022`, and says so on the console.
The cost is accepted: FAT has no owner per directory, so the host can write
every file on the card, the packs, the boot files and this file included, and
not only `site/`. `sys` stays `,ro`, so the host itself refuses to write the
sources.

**There is no flag for the address it listens on, only for the port.** It
authenticates nobody, so an endpoint flag would let a card put it on a network
where anything that reached the port could read and write every tree it
serves. That is not a setting to be made by uncommenting a line with the card
in a reader.

**The screen**, read by `S85cadr-terminal`. `docs/terminal.md` says what each
one means. `--terminal` takes nothing, a port, an address, or address:port.

    --terminal            the endpoint the screen is served on
    --color-terminal      the endpoint the SECOND screen is served on
    --color-window        the color TV's region
    --keyboard-mapping    what a viewer's keysyms mean
    --keyboard-boot       the chord a cold boot is asked for with
    --keyboard-boot-trace say when a key-up is held behind a boot word
    --bow                 the display's MODE BOW
    --machine             which machine the bitstream is: cadr or quux
    --window              the display's region
    --interval-ms         how often the window is read
    --no-rre              send every rectangle Raw
    --input               the keyboard and mouse registers
    --no-input            do not carry the keyboard and mouse
    --input-link          the socket another source sends keys on
    --no-input-link       do not listen for one

The keyboard mapping is also taken from `terminal.keyboard.mapping.txt` beside
this file when that file is there. A `--keyboard-mapping` line here wins. The
init script passes the file beside it only when this file says nothing about
that flag.

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

**The display boards**, read by `S80cadr-disk-packs` before it starts the disk
pack program, and written into the console face. `docs/tv.md` has the boards.

    --tv-board simple-tv|lispm-tv
                          which display board the first one is
    --color-tv            fit the second board, the color TV

Both are muir's flags with muir's meanings. A card that says nothing is a
machine with one SIMPLE TV and no color board, which is muir's own default.
The two are set before the drive comes present, for the reason the boot
button's flag is: a machine that has read a band may already have looked at a
display board.

**A MACHINE WITH NO COLOR BOARD MUST GIVE THE NXM AT ITS ADDRESSES**, which
is how `COLOR-EXISTS-P` in the band finds out whether it has one. So
`--color-tv` is off unless the card asks for it, and the color screen is
served with `--color-terminal` above.

**The display output**, read by `S80cadr-disk-packs` before it starts the disk
pack program, and written into the console face. `docs/display-output.md` is the
design.

    --hdmi-output tv|color-tv|both
                          which screens go to the monitor
    --hdmi-rotate 0|90|-90
                          which way up, for a monitor on its side
    --hdmi-sleep SECONDS  how long before the monitor sleeps; 0 never

The first display is drawn at the left of the monitor and the color board at
the right, at 1:1, with the rest black. The two are wider together than the
monitor is, so they share the columns in the middle, and there the color board
is drawn over the first. Neither is scaled: a one-bit picture scaled by
anything but a whole number turns single-pixel strokes into gray, and the
CADR's screen is single-pixel strokes almost everywhere.

**`--hdmi-sleep` is how long the display output waits with nobody at the board's
own keyboard or mouse.** Then it stops the link, which is how a monitor is put to
sleep. A key or the mouse at the board wakes it, and a viewer's keys do not. The
default is 300 seconds and 0 never sleeps. A board with no display output says so
when the line is there, and the boot goes on.

**The clock**, read by `S80cadr-disk-packs` before anything else it does. No
board here has a real-time clock in it, so these two lines are what tell one
the date. The section below is about them.

    --date yyyyMMdd       the date: a four-digit year, a two-digit month and a
                          two-digit day
    --time HHmm           the time of day on a 24-hour clock, with the second
                          after the minute when it is wanted

**The lamps**, read by `S80cadr-disk-packs` and written into the console face.
One flag, and the section below is about it.

    --no-blinking-leds    the activity lamps hold a level instead of blinking

**The boot button**, read by `S80cadr-disk-packs` before it starts the disk pack
program. One flag, and the section below is about it.

    --no-auto-boot        leave the boot button unpressed

SW0 on the board asks for the same thing, and the two are an OR. `docs/board.md`
has the switch.

**The debug cable**, read by the same script. Two flags.

    --debug-cable-connect be the debugger on Pmod JA
    --debug-cable-wiring auto|straight|crossover
                          which way round the JA ribbon was made

A board with the first line commented out is a debuggee. It answers a debugger
that plugs into the connector, which is what a CADR is with nothing set.
`docs/debug-cable.md` has the cable and the sections below have the flags.

## What cannot be written here, and why

`--log` is passed by `cadr_daemon`, which is what decides where a daemon
writes, and it is the same two places for every program. `--once` and
`--no-guard` are for somebody at a prompt and not for a card. `--base`,
`--no-fabric` and `--device` reach past the program into the fabric or name a
word another program could want.

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

Four flags may appear more than once, because they are repeatable by their own
definition. They are `--chaos-udp-peer` (or `--udp-peer`), `--usb-device`,
`--ozd-root` and `--ozd-host`. A peer entry places one Chaosnet address, a
named USB device is one device, a root names one tree, of which the card
carries two, and a host line places one machine in ozd's host table. Each
init script names its own repeatable flags to the reader. Every other flag is
taken from its last line, as the format section says.

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
which daemonizes it and closes its output, so the program printed its refusal
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

Stopping has the opposite problem. `start-stop-daemon -K` sends SIGTERM and
returns at once, without waiting for the program to exit. So every init script
stops its program through `cadr_stop`, which `cadr-common` installs at
`/usr/share/cadr/stop.sh`. It sends SIGTERM, waits until the program has gone,
and prints `OK` only then. A program still running at the bound is named and
left running, and the script prints `FAIL`. The bound is five seconds, and
thirty for the disk pack program, which writes every dirty block back to its
pack before it exits. Only after that does the disk pack script save the clock,
sync and unmount the card, and an unmount that fails is printed.

## Where a program's log is, and how to follow it

`cadr_daemon` starts every daemon with two destinations:

    --log /dev/console --log /var/log/cadr-<program>.log

So a boot is watched on the serial console as it always was, and the same
lines are in a file that somebody with nothing but ssh can read:

    tail -F /var/log/cadr-terminal.log
    tail -F /var/log/cadr-usb-input.log

Those two are where `cadr-console trace-keys on` puts what it switches on, and
the person who wants a key trace is usually the person over ssh. The programs
take `--log` more than once for this, and every line goes to every destination
named.

**`tail -F` and not `tail -f`.** A rotated file is a new file under the old
name, and `tail -f` goes on following the one it opened.

**A file is capped at 1 MiB and rotated to `<name>.1`.** The root filesystem is
unpacked into memory at every boot, `/var/log` is a symlink to `/tmp`, and
`/tmp` is that same memory, so a log that grew without bound would take the
board down. Each program holds at most two of these files and the five at most
ten megabytes, however long the board is up. The logs go at a reboot, which is
right for a log of this kind. `docs/console.md` has the routine and what holds
it.

## `--date` and `--time`

No board here presents a real-time clock to Linux. `date` straight after a boot
reads the epoch, `/sys/class/rtc` is empty, there is no `/dev/rtc` and the
kernel names no such device. So a board that boots from its card alone does not
know the date or the time, and everything it writes is stamped 1970.

Two lines on the card tell it.

    --date 20260920       a four-digit year, then a two-digit month, then a
                          two-digit day
    --time 1438           the hour on a 24-hour clock from 00 to 23, then the
                          minute, then the second if it is given

There is no am and no pm, and `1438` and `143800` name the same instant. The
clock is UTC, which is what the board's is, and there is no timezone flag.

**Either line may stand alone and sets only the field it names.** A card with
`--date` alone sets the date and leaves the time of day exactly as it stands,
and a card with `--time` alone sets the time of day and leaves the date exactly
as it stands. A lone `--time` is not that time today. The board has no today,
and a date it invented would be a day nobody meant.

**The clock is saved at a clean shutdown and restored at the next boot.** It is
fourteen digits, `yyyyMMddHHmmss`, in `clock` at the root of the card beside
this file. The disk pack program's init script writes it while it is stopping,
after the program has gone and before the card is unmounted, and reads it at
the next boot. The line is cleaned the way a line of this file is, so a carriage
return and a space at either end do not matter, and a file holding anything
else is named at boot and not used. A board that lost its power rather than
being halted keeps whatever the shutdown before it saved, which is the most a
board with no clock in it can offer.

**The restore happens first, and the card's lines are set on top of it.** That
is what gives the board a date for a lone `--time` to leave alone, so `--time`
alone on a board that was halted at two in the afternoon is that same day and
not a day in 1970.

**The two are never compared.** A line that is there overrides the field it
names, whatever was restored and whatever the board came up with. A value
written on the card is one the operator asked for, so `--time 0900` on a board
halted at two in the afternoon is nine that morning. A rule that dropped the
line because the saved value happened to be later would be a setting somebody
wrote down and did not get, visible from nowhere but the console, which is the
failure this whole file of flags exists to prevent. If the clock is to be moved
forward, the line on the card is what moves it.

**A value that is not a date or a time is named at boot and dropped, and the
other line still lands.** `--date 20260931` is eight digits and looks exactly
like a date, and a board that passed it on would be told the 31st of September
and would quietly get the 1st of October. So the month must be 01 to 12, the
day must be one the month really has with leap years counted properly, the hour
must be 00 to 23, and the minute and the second must be 00 to 59. The line that
says a value was refused names the form, because the person who wrote it has
the card in a reader and the form is what they need.

**Both lines are written on the card commented out, and what stands after them
is the form rather than a date.** There is no date a card script could write. A
line uncommented without being filled in gets the line at boot that says so,
which is better than a day nobody meant.

**The step is first, before every other step in that script and before the
drive comes present.** The machine, the programs and every file written want to
agree from the first second, and a band read with the clock still at the epoch
is a band whose files are stamped 1970. The step is in that script for the boot
button's reason: it reads this file and the saved clock, and both are on the
card that script is the one thing that mounts.

## `--no-ozd`

The board runs the band's file and time host itself unless this line is there.
`docs/chaosnet.md` says what it serves, what it costs and why it listens on
the loopback; this section is about the flag.

**It is the one flag whose setting decides another line's meaning.** A band
calls one address for its file host. If this file names a peer at that address
on a network, and the host on the board answers at the same address on the
loopback, then the Chaosnet program is given one Chaosnet address at two
endpoints. It refuses that by name and does not start, so the board is left
with no cable at all, on a boot that started a file host.

So a card whose band has a file host on a real network writes this line live.
The card script does it: a card that names any `--chaos-udp-peer` gets
`--no-ozd` live, and every other card gets it commented out under the sentence
that explains it. A card that names the address itself without this line is
not left to fail either. The Chaosnet script sees that the card places the
address and keeps the card's host, and the console says which of the two the
machine reaches.

**The host is reached over the cable like any other.** It is on the loopback
rather than on a network, but the machine still talks to it through the
Chaosnet program's socket, so a card with `--chaos-udp` commented out cannot
reach it. A released card therefore carries `--chaos-udp 127.0.0.1:42042`
live, which plugs the cable into the board and into no network. The console
says so when a host is running and the cable is not plugged in.

## `--no-auto-boot`

muir's flag, and it means here what it means there: leave the boot button
unpressed, as a CADR is when the power comes on with nobody at the button. The
machine is held with RUN clear and nothing running.

With SW0 off the fabric keeps RUN preset at reset, which is muir's own default
and what the bring-up boards need. So a board that is not to boot itself is held
by halting it. `S80cadr-disk-packs` reads the flag, halts the machine with
`cadr-console halt`, and leaves a marker at `/var/run/cadr-held` saying the flag
held it. It prints one line saying the machine is held and another naming both
ways to press the button.

**SW0 on the board asks for the same thing and the two are an OR.** With the
switch on, the fabric itself brings the machine up with RUN clear and it has
never run a microcycle. The init step asks the fabric with `cadr-console
switch`, writes a marker saying SW0 held it, and halts nothing, there being
nothing running to halt. If the flag is there as well, the line says so, because
a setting somebody wrote down should not look as though it was dropped.

**A flag can never turn the switch off.** That is what an OR means here, and it
is deliberate: the switch is a board somebody has their hands on, and a file on
a card should not be able to overrule it.

With neither the flag nor the switch the step does nothing and says nothing.

**The step is in that script for two reasons.** It must run before the disk pack
program starts, because a drive coming present is what lets the boot PROM go on
and read a band. And it must read this file, which is on the card that script
is the one thing that mounts. A step of its own at S79 would have to mount the
card itself, which would leave the mount with two owners and one unmounter.

**The PROM has already run when the FLAG is what holds it, and that is not a gap
in the hold.** The CADR starts when the bitstream is loaded, which is seconds
before Linux reaches this step. Within a few hundred milliseconds it has cleared
its control store and reached `AWAIT-DRIVE-READY`. It can go no further, because
no drive is present until the disk pack program starts. So the machine that is
halted has done its PROM work and is waiting, with nothing of a band loaded.
`cadr-console boot` presses `-BOOT2`, which presets RUN and starts the PROM
again from zero. The switch has no such gap, because the machine never ran at
all.

While the marker stands, `cadr-console` refuses `start` and `step`, in muir's
own words. `boot` presses the button and removes it. BTN0 on the board presses
the same line in the fabric, so a held machine can be booted by hand with
nobody logged in.

The marker is under `/var/run`, which is on the root filesystem, and that is a
RAM disk unpacked at every boot. A marker cannot in fact survive a reset. The
init step removes a marker it finds all the same, because a `restart` of that
script is a case that can leave one standing, and a marker that outlives its
hold is a lie about the machine.

## `--no-blinking-leds`

The board's activity lamps hold a level instead of blinking. On the Arty Z7-20
those are LD1, the fabric's clock, and LD2, the microcycles. On the Cora Z7-07S
it is LD1's green. The fabric comes up blinking, and a card that says nothing
keeps the blink.

Steady, the clock lamp is the clock generator's lock and the microcycle lamp is
lit while the machine retires microcycles, dark about 42 ms after it stops.
What the lamps say does not change, only how. `docs/board.md` has the lamps and
says why each steady form is what it is.

This is not a muir flag, because muir has no lamps. It is spelled the way muir
spells a setting that turns something off.

`S80cadr-disk-packs` reads the line before anything it asks the fabric for,
after the clock and before every other step, and asks the console with
`cadr-console blinking-leds off`. A person watching the board should see the
lamps settle as early in the boot as anything can make them, and the clock ahead
of it is not something anybody watches. That command exits 0
when the lamps are steady afterwards, so a console that could not be reached
and a fabric too old to have the word both get one line saying the lamps blink.
The boot goes on either way. `cadr-console blinking-leds on` and `off` do the
same thing at any time, and with no word it says which the lamps are doing.

**A fabric reset puts the lamps back to blinking**, as it puts every setting on
the console's face back to what the fabric comes up with, and the init step does
not run again until the next boot.

## `--debug-cable-connect`

muir's flag, and it means here what it means there: be the debugger on the
debug cable. MIT's cable is Pmod JA on this board, carrying both directions on
one connector.

**A board with nothing said is a debuggee.** It answers a debugger that plugs
into JA exactly as MIT's board answers one on its DBGIN. That is the power-on
state and nothing has to be set to reach it.

The flag takes no argument, because the connector is fixed in the bitstream.
**There is no listen flag**, here or in muir, because listening is what a CADR
always does.

`S80cadr-disk-packs` reads the flag and asks the fabric for the role with
`cadr-console debug-cable-connect`, after the boot button's step and before the
drive comes present. `cadr-console debug-cable-disconnect` gives the role back
at any time, and `cadr-console debug-cable` says which role this board has.

**Asking is not having, and the console says which happened.** A board that can
see a debugger already driving the connector holds its own engagement down, and
the first board told is the one that has the role. So the line printed at boot
reports the outcome and not the request.

## `--debug-cable-wiring`

Which way round the JA ribbon was made. It takes one word: `auto`, `straight`
or `crossover`.

A Pmod ribbon is supposed to join pin one to pin one. One made from two host
sockets mirrors the header's two rows instead, so each board's pins 1 to 4
reach the other board's pins 7 to 10. Two boards were found on exactly such a
cable. `docs/debug-cable.md` has the measurement and the table.

**Only a debugger applies the setting**, so it changes nothing on a board that
is a debuggee. A debuggee always drives the high four pins and listens on the
low four; a debugger swaps its two groups when the cable is crossed. One end
compensating is what straightens a mirrored ribbon and two would cross it
again.

`auto` is the default and is the fabric's own reset value. The board drives
nothing while it listens on both groups, then assumes straight and tries the
other wiring in turn until something answers. `straight` and `crossover` take
the looking out of the way when somebody is diagnosing a cable.

**The line is applied before `--debug-cable-connect` and not after.** The
fabric refuses a wiring that moves under a board that already holds the role,
because the wiring decides which four pins the board drives. `cadr-console
debug-cable-wiring auto|straight|crossover` does the same thing at any time,
and `cadr-console debug-cable` says which wiring the board found.

**The DBGIN page is never switched off by any of this.** Only the connector
changes hands. A board debugging somebody else is still debuggable through its
own register window, which is what a real CADR's two live connectors give it.

**`muirrc` beside this file has a flag of the same name and it is a different
end of the same cable.** There it is muir's own, and it takes the address of
the register window muir reaches the fabric machine through, so that muir on
this board's Arm cores debugs the CADR in this board's fabric. Here it is the
Pmod connector and takes no argument. The two can both be live on one card, and
a board with both is a machine being debugged by the muir beside it while it
debugs a second board over the ribbon.

## What the card script writes

`boards/arty-z7-20/linux/mksd-buildroot.sh` writes this file. It writes every
flag every program takes, grouped by program, with an explanation above each.

On the card this project builds for itself, the live lines are the Chaosnet
address and the cable; the peers and the bridge, which come from `local.conf`;
the screen's endpoint and the serial line's, written out in full; the boot
keyboard's chord; and `--debug-cable-wiring auto`. Everything else is commented
out with what it does. The
`--no-auto-boot` and `--debug-cable-connect` lines are commented out with the
sentences that explain them.

`NO_AUTO_BOOT=1` in `local.conf` makes that same line live. The two cards then
differ in one character and carry the same explanation. A released card always
boots its band by itself, because `STANDALONE` clears the setting along with
everything else that comes from `local.conf`.

`--no-blinking-leds` is written the same way. `NO_BLINKING_LEDS=1` in
`local.conf` makes the line live on a development card, for a board left
running where a blink is a distraction. A released card always writes it
commented, so a released board blinks: `STANDALONE` clears the variable, and
the card script also refuses it under `RELEASE`, so the menu a stranger is given
never depends on one flag having done its job.

## The released card's menu has four live lines

A card a stranger is given carries the same whole menu, with four of its lines
live.

    --chaos-address 177101
    --chaos-udp 127.0.0.1:42042
    --terminal 0.0.0.0:5900
    --keyboard-boot ctrl,meta

Those are what a board out of the box needs. A Chaosnet interface has an
address whether or not anything is plugged into it, so the switches are always
set. The cable is plugged into the board itself, because the band's file and
time host is on the board and the machine reaches it over the cable. The
screen is the only way to use a board that has no monitor of its own. The
chord is what cold-boots the machine from a viewer.

**The cable came back onto this menu when the board gained a host of its
own.** The argument for leaving it out was that a release with the cable live
would put a station on a network the user has not got, listening on a port
nobody named, with no peer it could reach. Two of those three are still true
of a cable on every interface and none of them is true of a cable on the
loopback. A user who wants a station on their own network changes `127.0.0.1`
to `0.0.0.0` in that one line.

Every other flag is on the card and commented out, under the sentence that
says what it does. **The serial line is among them.** A release with
`--serial` live would offer an unauthenticated port on every interface for a
cable hardly anybody wants. It is one `#` away from being on.

The development card is unchanged. It has those three lines, the cable, the
serial line and the debug cable's wiring as well, which is what this project's
own board needs.

`RELEASE=1` is what writes the released menu, and `mksd-release.sh` sets it.
That is a separate flag from `STANDALONE=1`, which is about what is private:
one decides which lines are live and the other keeps an address, a MAC and this
board's own station numbers off a public artifact. `fpgarc.pass` writes both
menus and compares them, so a release menu cut down by turning the development
card's lines off as well would fail by name.

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

It holds the lamps' step the same way: a card with `--no-blinking-leds` asks the
console for `blinking-leds off` with the boot log named, a card without it asks
nothing, and a console that did not make the lamps steady is said to have
failed while the boot goes on. It holds the card script's three ways of writing
that line: commented by default, live with `NO_BLINKING_LEDS=1` and nothing else
made live with it, and commented on a released card even with the variable set.

**It holds the clock in two places.** The arithmetic is tried on its own, one
process a case, against the wrong values as well as the right ones: a date that
is not eight digits, a month of 00 and of 13, a day of 00 and of 32, the 31st
of September, the 29th of February in a year that is not a leap year and in
1900 which is not one, an hour of 24, a minute of 60, a second of 60, letters
where digits belong, nothing at all, and a space at either end or in the
middle. A check that tried only the good values would pass a step that took
every eight digits it was given.

The rule that a line sets only the field it names is held by a pair of cases
rather than one. The same card is booted beside a saved clock later than what
its lines name and beside one earlier, one second either side, and the two
cases require the same outcome, which is the whole of the rule. A lone `--time`
and a lone `--date` are each tried against a saved clock that is later than
them, and each case asserts that the field the line did not name did not move.
A step that weighed the line against the saved clock, which is what this once
did, fails every one of those. The sentence that step printed when it dropped a
line is asserted absent by name, and both files are required to carry no
comparison between two instants at all. The restore is held to being
unconditional too, since a condition on it would be the same comparison moved
into the step's other half. The `date` the step reads and writes is stubbed, so
the clock in the case is the check's own and the build host's is never touched.
Where in the boot the clock was set is recorded too: it must
land before the pack program starts and before the console is asked anything.
The save is held to happening while the card is still mounted, since a
save after the unmount writes into a RAM disk and is lost at the next boot.

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
That is held for the released menu as well as the development one.

**And it holds the two menus apart.** The released menu must have those three
live lines and no others, and the development menu must still have its six.
The second half is the control: a release menu with three live lines could
otherwise be bought by turning the development card's lines off too, and every
other case would still pass.

**And it holds what a board does with the released menu**, on the file the real
card script really writes rather than one written in the check. The Chaosnet
program is given the address and no cable, and says so. The serial program is
not started, and the script says the line is off and how to turn it on. The
screen is given its endpoint and the boot chord. A menu whose commented lines
the scripts ignored, or whose live ones they missed, would be a card that says
one thing and a board that does another.

**And it holds the file and time host on the board**, which is the sixth
program the file reaches and the first one whose settings have to be rewritten
on the way. Ten cases: the host is on with nothing said and is given the four
flags its program requires; `--no-ozd` stops it and leaves nothing behind for
the Chaosnet script to find; a setting left beside `--no-ozd` still reaches a
program, with a misspelling of the same flag reported on the same run as the
control; every setting the card names arrives under the program's own name,
with the absence of every `--ozd-` spelling asserted beside it, because a
rewrite that did not happen would be a host that never started and the
defaults would be there to find either way; a tree the board has not got stops
the host and prints the program's own refusal; the machine is given the host
on its own board, and is not given it when none is running; a card that places
that address itself keeps its own host and its cable; and the card script
writes `--no-ozd` live for a card with a peer and commented for a card
without, both halves, because a script that wrote it live always would pass
the first alone.

**And it holds the wait for the network to being a wait for a name.** A board
whose peers are all addresses must not wait, on a stubbed board with nothing
plugged in, and a board with a peer named by name must still wait on that same
board. The second is the control: a script that had stopped waiting for
anything would pass the first. The case that used to require a board with no
card to wait now requires it not to, since the defaults name no peer at all.

**And it holds how big a card has to be, by running the card script's own
arithmetic rather than restating it.** The function is lifted out on its
anchors and called with the real byte counts, and what is asserted is that the
answer covers a T-300 pack, both of the band's trees and the twelve megabytes
of loader, kernel, fabric image and root filesystem together. The control is
that the same card without the pack must come out smaller by about a pack,
since a function that returned a round number or the boot files alone would
pass the first half. The rounding is held to going up, because a card of
exactly the floor is a card with nothing left and the number is advice a
person acts on. **It is advice and not a size**: there is no partition to
size any more, the user's own formatter makes it, and what the arithmetic can
honestly say is how small a card would be too small. The card is held to
naming a tree exactly when it carries one, both ways, since a line naming a
tree that is not there stops the host.

**And it holds the root of the card to what belongs there.** That matters more
with one partition than it did with two, because the root is now both where the
loader looks and where a person copies things, so it is where a stray file
lands and a stray file there is one nothing on the board reads. The guard is
lifted out of the card script and run against a fabricated card twice, once
clean and once with one extra file, and the second is the point: a guard that
accepted everything would pass the first.

**And it holds the readback of the zip.** The image used to be read back file
by file out of each partition with the tool that speaks FAT, because a staging
that merely copied into a directory says nothing about what the board would
find. The zip is read back the same way, and the cases require it to catch a
file the zip did not carry.

`chaosnet.pass` holds the Chaosnet script's own wait for the network, and it now
also holds that script to taking its own flags out of a file written for the
whole board.

No mutation record can aim at any of this. The runner compiles C, so a record
naming a shell script would be broken by construction. The evidence that the
check can fail is that it was written against the tree before the reader existed
and did fail there.
