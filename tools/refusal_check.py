#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Run a command and hold it to refusing, or to not refusing, and to its words.

**A GUARD NOBODY TESTS IS A GUARD THAT WORKS UNTIL IT MATTERS.**  This
repository is full of elaboration-time refusals --- a bus speed the part will
not take, a mode a board cannot clock --- and every one of them is a branch
that no ordinary check ever reaches, because every ordinary check builds the
configuration that is allowed.  A refusal that has rotted into a comment looks
exactly like a refusal that fires.

So this runs one command and says what must be true of it:

    tools/refusal_check.py --refuse --saying '<words>' -- <command...>
    tools/refusal_check.py --allow -- <command...>

`--refuse` requires a non-zero exit AND requires `--saying`'s text to appear in
what the command wrote, so that a tool failing for some other reason --- a
missing file, a typo in a flag, a lint finding somewhere else entirely --- is
not mistaken for the guard firing.  That mistake is the whole failure mode
here: a check that only asked for a non-zero exit would go on passing after the
guard was deleted, as long as the command broke for any reason at all.

`--allow` requires exit zero, and is not decoration.  **A BOUND NOTHING
REACHES LOOKS EXACTLY LIKE A BOUND THAT WORKS**, so every use of `--refuse`
here is paired with an `--allow` on the value just inside it.  A refusal
written one number too wide refuses everything and passes the `--refuse` half
on its own.

The command's own output is printed whichever way it went, because a check that
swallows what the tool said is a check that has to be re-run by hand to be
understood.
"""

import argparse
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser(add_help=True)
    how = ap.add_mutually_exclusive_group(required=True)
    how.add_argument("--refuse", action="store_true",
                     help="the command must exit non-zero and say --saying")
    how.add_argument("--allow", action="store_true",
                     help="the command must exit zero")
    ap.add_argument("--saying", default=None,
                    help="text that must appear in the refusal")
    ap.add_argument("--what", default=None,
                    help="what is being held, for the line this prints")
    ap.add_argument("command", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    cmd = args.command
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        sys.stderr.write("refusal: no command\n")
        return 2
    if args.refuse and not args.saying:
        sys.stderr.write("refusal: --refuse needs --saying: a non-zero exit on"
                         " its own is not evidence that the guard fired\n")
        return 2

    what = args.what or " ".join(cmd[:3])
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = p.stdout.decode("utf-8", "replace")

    if args.allow:
        if p.returncode != 0:
            sys.stdout.write(out)
            sys.stderr.write("refusal: FAILED --- %s was meant to be allowed"
                             " and the command exited %d\n"
                             % (what, p.returncode))
            return 1
        print("refusal: %s is allowed, as it must be" % what)
        return 0

    if p.returncode == 0:
        sys.stdout.write(out)
        sys.stderr.write("refusal: FAILED --- %s was meant to be refused and"
                         " the command exited 0\n" % what)
        return 1
    if args.saying not in out:
        sys.stdout.write(out)
        sys.stderr.write("refusal: FAILED --- %s was refused, but not for the"
                         " reason it is meant to be: nothing said %r\n"
                         % (what, args.saying))
        return 1
    print("refusal: %s is refused, saying %r" % (what, args.saying))
    return 0


if __name__ == "__main__":
    sys.exit(main())
