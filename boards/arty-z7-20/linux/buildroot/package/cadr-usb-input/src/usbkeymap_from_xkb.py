#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# `usb_keymap.h` from the X keyboard database: what keysym each of a USB
# keyboard's key codes produces, on the unshifted plane and the shifted one.
#
# WHY THIS IS GENERATED.  A hundred and thirty keys transcribed by hand is a
# table with a wrong key in it somewhere, and the wrong key types the wrong
# character on one key in a hundred, which is exactly the class of mistake
# nobody notices until the machine is being used.  `keymap_from_muir.py` in
# the screen's package exists for the same reason one table along.
#
# WHY NO BUILD RUNS IT.  It reads xkb-data and X11's keysymdef.h, which are on
# a build host and not in this repository, and neither Buildroot nor CI has
# them.  So the output is committed, its header names the files and the
# package version it came from, and this says how to write it again:
#
#     python3 usbkeymap_from_xkb.py > usb_keymap.h
#
# WHAT IT READS, and what each file is for:
#
#   keycodes/evdev     the key code of each key, as a name like <AE01>.  The
#                      file gives X's own numbering, which is the evdev code
#                      plus eight, and the offset is subtracted here
#   symbols/pc         the keys every layout has: the modifiers, Return,
#                      Escape, the function keys, the keypad, the arrows
#   symbols/us         the alphanumeric keys of the US layout, over it
#   keysymdef.h        the number of every keysym name
#
# `pc` then `us` is what a layout of `pc+us` is, which is what an X server
# loads for a plain US keyboard --- so this table is what a viewer connected
# to such a keyboard would send, which is the whole point: the two sources of
# keys must not disagree about what a key means.

import re
import sys

KEYCODES = "/usr/share/X11/xkb/keycodes/evdev"
SYMBOLS = "/usr/share/X11/xkb/symbols"
KEYSYMDEF = "/usr/include/X11/keysymdef.h"
# The vendor keysyms.  A PC keyboard's extra keys --- a display switch, a
# keyboard lamp --- are named `XF86Something` in the layout and defined as
# `XF86XK_Something` here.  They are kept rather than dropped: the key is on
# the keyboard and it produces a keysym, and whether it means anything is the
# far end's mapping to decide.  On a Lisp Machine none of them does, so they
# reach the machine as nothing and are counted as unmapped, which is the
# truth.
XF86KEYSYMDEF = "/usr/include/X11/XF86keysym.h"
LAYOUT = [("pc", None), ("us", "basic")]
# X's key codes are the evdev ones plus eight: keycodes/evdev says
# `minimum = 8` and <AE01>, which is evdev's KEY_1 = 2, is 10 there.
XKB_OFFSET = 8
# **THE SIX KEYS symbols/pc ITSELF CALLS FAKE.**  Its own comment is "Six fake
# keys for virtual<->real modifiers mapping": they exist so that an X server
# can map a virtual modifier onto a real one, and no keyboard sends them.  The
# key codes file gives them numbers all the same --- 92 and 203 to 207, which
# are 84 and 195 to 199 as evdev counts --- and those are codes Linux leaves
# unassigned, so including them would put keys in this table that no device
# can press.  Left out by name.
FAKE = ("LVL3", "LVL5", "ALT", "META", "SUPR", "HYPR")


def keysym_numbers(path, prefix="XK_", name_prefix=""):
    """Every X11 keysym name and its number, from a keysym header."""
    out = {}
    pat = re.compile(r"^#define\s+%s(\w+)\s+(0x[0-9a-fA-F]+)" % prefix)
    for line in open(path):
        m = pat.match(line)
        if m:
            # The first definition of a name wins; keysymdef.h defines none
            # twice, and an alias is a different name for the same number.
            out.setdefault(name_prefix + m.group(1), int(m.group(2), 16))
    return out


def key_codes(path):
    """<NAME> to an evdev key code, aliases followed.

    **THE ALIASES MATTER AND THE CHECK FOUND THAT OUT.**  symbols/pc writes
    `key <MENU>`, and the key codes file calls that key <COMP> with
    `alias <MENU> = <COMP>;` beside it.  Without the aliases the Menu key ---
    which muir's mapping makes the Top key, one of the two the Lisp Machine
    character set is entered with --- simply was not in the table, and nothing
    but a hand-written anchor would have said so.
    """
    text = open(path).read()
    out = {}
    for m in re.finditer(r"(?<!alias )<(\w+)>\s*=\s*(\d+)\s*;", text):
        out[m.group(1)] = int(m.group(2)) - XKB_OFFSET
    aliases = re.findall(r"alias\s+<(\w+)>\s*=\s*<(\w+)>\s*;", text)
    # To a fixed point, because an alias may name another alias.
    moved = True
    while moved:
        moved = False
        for name, of in aliases:
            if name not in out and of in out:
                out[name] = out[of]
                moved = True
    return out


def section(path, want):
    """The body of one xkb_symbols section, or of the default one."""
    text = open(path).read()
    for m in re.finditer(r'xkb_symbols\s+"([^"]+)"\s*\{', text):
        name = m.group(1)
        if want is not None and name != want:
            continue
        if want is None:
            # The default section is the one whose declaration says so.
            head = text[max(0, m.start() - 200):m.start()]
            if "default" not in head:
                continue
        at = m.end()
        depth = 1
        while depth:
            if text[at] == "{":
                depth += 1
            elif text[at] == "}":
                depth -= 1
            at += 1
        return text[m.end():at - 1]
    sys.exit("%s: no section %s" % (path, want or "(default)"))


def read_symbols(path, want, into, seen):
    """Every `key <NAME> {[ a, b ]}` of a section, includes followed."""
    body = section(path, want)
    for m in re.finditer(r'include\s+"([^"(]+)(?:\(([^)]+)\))?"', body):
        f, sec = m.group(1), m.group(2)
        key = (f, sec)
        if key in seen:
            continue
        seen.add(key)
        read_symbols("%s/%s" % (SYMBOLS, f), sec, into, seen)
    for m in re.finditer(r"key\s+<(\w+)>\s*\{(.*?)\}\s*;", body, re.S):
        name, inner = m.group(1), m.group(2)
        # `symbols[Group1]= [ ... ]` names the group before the list, so the
        # group's own brackets are taken out before the list is looked for.
        # Without this the first `[...]` found is `[Group1]` and every key
        # written that way --- the keypad's operators are --- comes out with a
        # keysym called Group1.
        inner = re.sub(r"\[\s*Group\d+\s*\]", "", inner)
        levels = re.search(r"\[(.*?)\]", inner, re.S)
        if not levels:
            continue
        syms = [s.strip() for s in levels.group(1).split(",")]
        into[name] = syms


def main():
    numbers = keysym_numbers(KEYSYMDEF)
    numbers.update(keysym_numbers(XF86KEYSYMDEF, "XF86XK_", "XF86"))
    # The layout writes some of the vendor keysyms with an underscore after
    # the vendor --- `XF86_Switch_VT_1` --- and the header does not.
    for name, value in list(numbers.items()):
        if name.startswith("XF86"):
            numbers.setdefault("XF86_" + name[4:], value)
    codes = key_codes(KEYCODES)
    symbols = {}
    seen = set()
    for f, sec in LAYOUT:
        read_symbols("%s/%s" % (SYMBOLS, f), sec, symbols, seen)

    rows = []
    for name, syms in symbols.items():
        if name in FAKE:
            continue
        if name not in codes:
            # A key the layout names and this keyboard's codes do not have:
            # the six fake keys xkb uses for modifier mapping, among others.
            continue
        code = codes[name]
        if code < 0 or code > 255:
            continue
        plain = syms[0] if syms else "NoSymbol"
        shifted = syms[1] if len(syms) > 1 else plain
        if plain in ("NoSymbol", "VoidSymbol"):
            continue
        if shifted in ("NoSymbol", "VoidSymbol"):
            shifted = plain
        if plain not in numbers:
            sys.exit("no number for keysym %s (key <%s>)" % (plain, name))
        if shifted not in numbers:
            sys.exit("no number for keysym %s (key <%s>)" % (shifted, name))
        rows.append((code, name, plain, numbers[plain], shifted, numbers[shifted]))
    rows.sort()

    # A key code appearing twice would be two keys claiming one code, which
    # would silently drop one of them.
    dup = [r for i, r in enumerate(rows) if i and rows[i - 1][0] == r[0]]
    if dup:
        sys.exit("two keys with one code: %s" % dup)

    keypad = set()
    for code, name, plain, _, _, _ in rows:
        if plain.startswith("KP_") or name in ("KPDL", "KPPT", "KPEN", "KPEQ"):
            keypad.add(code)

    w = sys.stdout.write
    w("// SPDX-FileCopyrightText: 2026 Mete Balci\n")
    w("// SPDX-License-Identifier: AGPL-3.0-or-later\n")
    w("//\n")
    w("// GENERATED by `usbkeymap_from_xkb.py`.  DO NOT EDIT: run the generator\n")
    w("// again, which is the point of it --- a table of this size typed out by\n")
    w("// hand has a wrong key in it somewhere, and a wrong key types the wrong\n")
    w("// character on one key in a hundred.\n")
    w("//\n")
    w("// From the X keyboard database on the build host:\n")
    w("//\n")
    w("//     %s\n" % KEYCODES)
    w("//     %s/pc, %s/us and what they include\n" % (SYMBOLS, SYMBOLS))
    w("//     %s and %s\n" % (KEYSYMDEF, XF86KEYSYMDEF))
    w("//\n")
    w("// The layout is `pc+us`, which is what an X server loads for a plain US\n")
    w("// keyboard --- so this is what a viewer connected to such a keyboard\n")
    w("// would send, and the two sources of keys cannot disagree about what a\n")
    w("// key means.\n")
    w("//\n")
    w("// The six keys symbols/pc calls fake are left out; the generator says why.\n")
    w("//\n")
    w("// `plain` is the keysym with no shift and `shifted` the one with Shift\n")
    w("// held.  A key with one keysym has the same in both.  Which of them a\n")
    w("// key event uses is `usb_keys.c`'s decision and is written there.\n")
    w("\n")
    w("#ifndef USB_KEYMAP_H\n")
    w("#define USB_KEYMAP_H\n")
    w("\n")
    w("#include <stdint.h>\n")
    w("\n")
    w("struct usb_key {\n")
    w("\tuint16_t code;\t\t/* the evdev key code */\n")
    w("\tuint32_t plain;\t\t/* the keysym with no shift */\n")
    w("\tuint32_t shifted;\t/* ...and with Shift held */\n")
    w("\tuint8_t keypad;\t\t/* on the numeric keypad: Num Lock chooses */\n")
    w("\tconst char *name;\t/* the xkb name of the key, for a message */\n")
    w("};\n")
    w("\n")
    w("static const struct usb_key USB_KEYS[] = {\n")
    for code, name, plain, pn, shifted, sn in rows:
        w("\t{ %3d, 0x%08xu, 0x%08xu, %d, \"%s\" },\t/* %s%s */\n"
          % (code, pn, sn, 1 if code in keypad else 0, name, plain,
             "" if shifted == plain else " " + shifted))
    w("};\n")
    w("\n")
    w("#define USB_KEYS_COUNT (sizeof USB_KEYS / sizeof USB_KEYS[0])\n")
    w("\n")
    w("#endif\n")


if __name__ == "__main__":
    main()
