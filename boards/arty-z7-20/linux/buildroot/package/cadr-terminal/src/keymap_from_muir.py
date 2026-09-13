#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Writes `input_keymap.h` out of muir's own sources, so that the table this
# program carries is DERIVED and not transcribed.
#
# **WHY IT IS A GENERATOR AND NOT A HAND-WRITTEN TABLE.**  MIT's key table is
# ninety-nine entries and the default mapping is sixty-one bindings, and a
# transcription error in either is a key that types the wrong character on
# one position out of a hundred --- the kind of mistake that survives every
# check that does not happen to press that key.  Reading `keyboard.rs` and
# `default.keys` and resolving the names exactly as `key_of` does removes
# that class of error entirely: the two files are the reference, and this is
# a translation of them into C.
#
# **IT IS NOT RUN BY ANY BUILD, AND THAT IS DELIBERATE.**  It needs muir
# beside the tree, and Buildroot's `local` site method rsyncs only this
# directory --- so a build that ran it would fail on a board and in CI alike.
# The output is committed, and its header names the muir commit it was
# written from.  To move it: pull muir, run
#
#     python3 keymap_from_muir.py --muir ../../../../../../../../muir
#
# from this directory, and commit `input_keymap.h` with the new commit in
# its header, saying what moved.  `muir.commit` at the top of this
# repository is the pin every reference here is held to.
#
# WHAT IT READS.  `src/terminal/keyboard.rs` for `TABLE`, the `Shift` enum
# and `KEYSYM_NAMES`; `src/terminal/default.keys` for the bindings.  What it
# does NOT read is the Rust that uses them: the state machine --- `resolve`,
# `tap`, `press`, `release` --- is written out in C by hand in
# `input_keys.c`, because a translation of behaviour is not a translation of
# data and pretending otherwise would hide where the judgement is.

import argparse
import os
import re
import subprocess
import sys

SHIFTS = [
    ("Shift", "Shift"), ("Greek", "Greek"), ("Top", "Top"),
    ("CapsLock", "Caps Lock"), ("Control", "Control"), ("Meta", "Meta"),
    ("Super", "Super"), ("Hyper", "Hyper"), ("AltLock", "Alt Lock"),
    ("ModeLock", "Mode Lock"), ("Repeat", "Repeat"),
]
SHIFT_ID = {rust: k for k, (rust, _) in enumerate(SHIFTS)}
SHIFT_BY_NAME = {name.lower(): k for k, (_, name) in enumerate(SHIFTS)}


def unescape(lit):
    """A Rust byte literal's character: b'a', b'\\\\', b'\\''."""
    body = lit[2:-1]
    return {"\\\\": "\\", "\\'": "'", "\\n": "\n", "\\t": "\t"}.get(body, body)


def read_table(src):
    """`TABLE`, by position: (kind, plain, shifted, shift id, name)."""
    table = [("NONE", 0, 0, 0, None)] * 128
    body = src.split("pub const TABLE: [Key; 128] = {", 1)[1].split("\n    t\n};", 1)[0]
    for line in body.split("\n"):
        m = re.match(r"\s*t\[0o(\d+)\] = (\w+)\((.*?)\);", line)
        if not m:
            continue
        p, kind, arg = int(m.group(1), 8), m.group(2), m.group(3)
        if kind == "Char":
            a, bch = [x.strip() for x in arg.split(", ")]
            table[p] = ("CHAR", ord(unescape(a)), ord(unescape(bch)), 0, None)
        elif kind == "Named":
            table[p] = ("NAMED", 0, 0, 0, arg.strip().strip('"'))
        elif kind == "Shift":
            s = arg.strip().split("::")[-1]
            table[p] = ("SHIFT", 0, 0, SHIFT_ID[s], None)
        else:
            raise SystemExit("unknown Key variant %r at 0o%o" % (kind, p))
    return table


def read_keysym_names(src):
    body = src.split("const KEYSYM_NAMES: &[(&str, u32)] = &[", 1)[1].split("\n];", 1)[0]
    out = {}
    for name, val in re.findall(r'\("([^"]+)",\s*(0x[0-9a-fA-F]+|\d+)\)', body):
        out[name.lower()] = int(val, 0)
    return out


def shifting(table, s):
    return [p for p in range(128) if table[p][0] == "SHIFT" and table[p][3] == s]


def character_positions(table, keysym):
    """`character_positions`: plane 0 then plane 1, in position order."""
    if not (0x20 <= keysym <= 0x7E):
        return []
    c = keysym
    out = []
    for p in range(128):
        kind, plain, shifted, _, _ = table[p]
        if kind != "CHAR":
            continue
        if plain == c:
            out.append((p, False))
        if shifted == c and shifted != plain:
            out.append((p, True))
    return out


def keysym_of(word, names):
    if word.lower() in names:
        return names[word.lower()]
    if len(word) == 1 and " " <= word <= "~":
        return ord(word)
    if word.startswith("0x"):
        return int(word, 16)
    return int(word)


def key_of(word, table):
    """`key_of`, exactly: a named key, `position <octal> [shifted]`, a
    shifting key with an optional side, or a character."""
    for p in range(128):
        if table[p][0] == "NAMED" and table[p][4].lower() == word.lower():
            return (p, False)
    if word.lower().startswith("position "):
        rest = word.split(None, 1)[1].strip()
        parts = rest.split()
        shifted = len(parts) > 1 and parts[1].lower() == "shifted"
        return (int(parts[0], 8), shifted)
    parts = word.split(None, 1)
    side, name = 0, word
    if len(parts) == 2 and parts[0].lower() in ("left", "right"):
        side = 0 if parts[0].lower() == "left" else 1
        name = parts[1].strip()
    if name.lower() in SHIFT_BY_NAME:
        at = shifting(table, SHIFT_BY_NAME[name.lower()])
        if not at:
            raise SystemExit("%s is on no position" % name)
        return (at[side] if side < len(at) else at[0], False)
    if len(word) == 1:
        found = character_positions(table, ord(word))
        if found:
            return found[0]
    raise SystemExit("%r is no key of this keyboard" % word)


def read_bindings(keys, table, names):
    single, prefixed = {}, {}
    for raw in keys.split("\n"):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        parts = line.split(None, 1)
        what, rest = parts[0], parts[1]
        if what == "key":
            sym, key = rest.split(None, 1)
            single[keysym_of(sym, names)] = key_of(key.strip(), table)
        elif what == "prefix":
            a, b, key = rest.split(None, 2)
            prefixed[(keysym_of(a, names), keysym_of(b, names))] = key_of(key.strip(), table)
        else:
            raise SystemExit("unknown line %r" % line)
    for first, _ in prefixed:
        if first in single:
            raise SystemExit("keysym %#x is bound as a key and used as a prefix" % first)
    return single, prefixed


KINDS = {"NONE": "KEY_NONE", "CHAR": "KEY_CHAR", "NAMED": "KEY_NAMED", "SHIFT": "KEY_SHIFT"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--muir", default="../../../../../../../../muir")
    ap.add_argument("--out", default="input_keymap.h")
    a = ap.parse_args()

    kb = os.path.join(a.muir, "src/terminal/keyboard.rs")
    dk = os.path.join(a.muir, "src/terminal/default.keys")
    src = open(kb).read()
    table = read_table(src)
    names = read_keysym_names(src)
    single, prefixed = read_bindings(open(dk).read(), table, names)
    try:
        commit = subprocess.check_output(
            ["git", "-C", a.muir, "rev-parse", "HEAD"], text=True).strip()
    except Exception:
        commit = "unknown"

    o = []
    w = o.append
    w("// SPDX-FileCopyrightText: 2026 Mete Balci")
    w("// SPDX-License-Identifier: AGPL-3.0-or-later")
    w("//")
    w("// GENERATED by `keymap_from_muir.py`.  DO NOT EDIT: edit muir's own")
    w("// `src/terminal/keyboard.rs` or `src/terminal/default.keys` and run the")
    w("// generator again, which is the point of it --- the two machines must not")
    w("// disagree about what a key means, and a table typed out by hand is a")
    w("// table that drifts.")
    w("//")
    w("// muir %s" % commit)
    w("//")
    w("// `KEY_TABLE` is MIT's own key table by position in octal,")
    w("// `keyboard.rs`'s `TABLE`, itself transcribed there from")
    w("// `KBD-MAKE-NEW-TABLE` in `lmio/kbd.123`.  `KEY_BOUND` and `KEY_PREFIX`")
    w("// are `default.keys` resolved: every `key` and `prefix` line with its")
    w("// name looked up exactly as `key_of` looks it up, so a binding is a")
    w("// position and a plane and no name survives into C.")
    w("")
    w("#ifndef INPUT_KEYMAP_H")
    w("#define INPUT_KEYMAP_H")
    w("")
    w("#include <stdint.h>")
    w("")
    w("enum key_kind { KEY_NONE = 0, KEY_CHAR = 1, KEY_NAMED = 2, KEY_SHIFT = 3 };")
    w("")
    w("// `keyboard.rs`'s `Shift`, in `KBD-SHIFTS`' own order, which is also the")
    w("// bit order of the all-keys-up word.")
    for k, (rust, name) in enumerate(SHIFTS):
        w("#define SH_%-10s %2d   /* %s */" % (rust.upper(), k, name))
    w("")
    w("struct key_entry {")
    w("\tuint8_t kind;        /* enum key_kind */")
    w("\tuint8_t plain;       /* KEY_CHAR: plane 0 */")
    w("\tuint8_t shifted;     /* KEY_CHAR: plane 1 */")
    w("\tuint8_t shift;       /* KEY_SHIFT: which shifting key */")
    w("\tconst char *name;    /* KEY_NAMED: MIT's own name */")
    w("};")
    w("")
    w("static const struct key_entry KEY_TABLE[128] = {")
    for p in range(128):
        kind, plain, shifted, sh, name = table[p]
        nm = '"%s"' % name if name else "0"
        note = ""
        if kind == "CHAR":
            note = "  /* 0o%03o  %s %s */" % (p, repr(chr(plain)), repr(chr(shifted)))
        elif kind == "NAMED":
            note = "  /* 0o%03o  %s */" % (p, name)
        elif kind == "SHIFT":
            note = "  /* 0o%03o  %s */" % (p, SHIFTS[sh][1])
        w("\t[0%03o] = { %s, %3d, %3d, %2d, %s },%s"
          % (p, KINDS[kind], plain, shifted, sh, nm, note))
    w("};")
    w("")
    w("struct key_binding { uint32_t keysym; uint8_t position; uint8_t shifted; };")
    w("")
    w("// `default.keys`' `key` lines, by keysym.")
    w("static const struct key_binding KEY_BOUND[] = {")
    for sym in sorted(single):
        p, sh = single[sym]
        w("\t{ 0x%08xu, 0%03o, %d },   /* %s */" % (sym, p, 1 if sh else 0, describe(table, p, sh)))
    w("};")
    w("#define KEY_BOUND_COUNT %d" % len(single))
    w("")
    w("struct key_prefix { uint32_t first, second; uint8_t position; uint8_t shifted; };")
    w("")
    w("// ...and its `prefix` lines: press the first, then the second.")
    w("static const struct key_prefix KEY_PREFIX[] = {")
    for (a1, b1) in sorted(prefixed):
        p, sh = prefixed[(a1, b1)]
        w("\t{ 0x%08xu, 0x%08xu, 0%03o, %d },   /* %s */"
          % (a1, b1, p, 1 if sh else 0, describe(table, p, sh)))
    w("};")
    w("#define KEY_PREFIX_COUNT %d" % len(prefixed))
    w("")
    w("#endif")
    w("")
    open(a.out, "w").write("\n".join(o))
    print("%s: %d table entries, %d bindings, %d prefixed, from muir %s"
          % (a.out, sum(1 for e in table if e[0] != "NONE"),
             len(single), len(prefixed), commit[:12]))


def describe(table, p, shifted):
    kind, plain, sh, s, name = table[p]
    if kind == "NAMED":
        return name
    if kind == "SHIFT":
        return SHIFTS[s][1]
    if kind == "CHAR":
        return repr(chr(sh if shifted else plain))
    return "position 0%o" % p


if __name__ == "__main__":
    sys.exit(main())
