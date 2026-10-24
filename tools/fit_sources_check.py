#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Whether every file the boards' Vivado and Quartus flows read is in the tree.

    python3 tools/fit_sources_check.py . [--make] [--list]

A flow names its files in text that no simulation reads: a fit is the first
thing that opens them, and a file deleted from `rtl/` but still named in a
flow's list builds every check here and stops the fit at `read_verilog`.  So
this reads the flows' own text, as Vivado and Quartus would, and asks for
each file a flow reads whether it is there.

**WHAT IS READ.**  Every `.tcl`, `.xdc` and `.sdc` under `boards/`, `rtl/`
and `tools/`, parsed as Tcl and walked as an interpreter walks it, every
branch of every `if` and `switch` taken: `read_verilog`, `read_vhdl`,
`read_xdc`, `read_mem`, `read_ip`, `read_bd`, `read_edif`,
`read_checkpoint`, `add_files`, `import_files`, `source` (and the sourced
script walked in its place), `open` for reading, `set_global_assignment
-name <x>_FILE`, a `-generic` or `set_parameter` whose value is a memory
image, and `-include_dirs`.  A word is resolved as Tcl would: `set`,
`lappend` and `append` bind it, `[list]`, `[file join]`, `[file dirname]`,
`[file normalize]`, `[info script]`, `[pwd]` and the flows' own
`[expr {[info exists ::env(X)] ? $::env(X) : default}]`, which is taken at
its default, evaluate.  A variable holds the set of values the branches
before it can give it: every branch of an `if` is walked and the sets after
it united, so the walk is linear in the script.  Only a `switch` on a
variable keeps its arms apart, each binding the variable to its pattern, and
an `if` comparing that variable with a literal is then decided; `exit` ends
the branch that reaches it.  So `tools/fault_zynq.tcl`'s `$dir/$top.sv` is
the Arty's file in the Arty's arm and the Kria's in the Kria's, and never
one board's directory with the other's top level.  A procedure is walked at each call with the call's words, and one
nothing calls is walked once with its defaults.  `glob` names only files
that exist, so a globbed list (the CADR's flows read `[glob rtl/*/*.sv
...]`) is held only to matching something.  And the DE25-Nano's two shell
scripts, `boards/de25-nano/quartus/build.sh` and `program.sh`: every path
their code names, `$here/...` and `$root/...` resolved.

**WHAT COUNTS AS THERE.**  A file under `build/` is made by make or by the
flow itself and is not in the tree; it is counted and not required.  A
script whose working directory is its build directory (the DE25-Nano's
timing and RAM scripts and `hps.tcl`, run by `build.sh` from `$out`) reads
its relative names there.  Every other path must be a file (a directory for
`-include_dirs`), and in a git work tree a tracked one, so a file left
untracked here cannot stand in for one a clone lacks.

**WHAT A STATIC READING CANNOT RESOLVE** is named in `UNRESOLVED` below,
each with its reason and the number of reads it covers, and both directions
are held: a read that resolves to nothing and is not there fails, and an
entry that no longer covers exactly its count fails too, so the table cannot
quietly grow wider than what it excuses.  The DE25-Nano's sources are the
one large case: `project.tcl` takes them from its command line, which
`build.sh` passes on from make.  With `--make` (the Makefile passes it; the
mutation runner's copy has no Makefile) make is asked for them:
`make -n de25` for the CADR, the CADR with every option, QUUX, and
`make -n de25-fault`, and every file each hands `build.sh` must be there;
make itself refuses a list naming a file it cannot find.

WHAT THIS DOES NOT SAY.  It runs neither Vivado nor Quartus, so it says
nothing about whether a file that is there is the right one, or whether a
flow reads it in the right order or with the right options; and it does not
see a path built by a command it does not evaluate (such a read is
unresolved, so it fails unless the table names it).  `tb/`'s Tcl is the
testbenches' and not a flow's, and is not read.

`--list` prints every read the walk found, as it resolved it.

Exit status 0 when every read is accounted for, 1 otherwise, with every
missing file and the totals printed.
"""

import fnmatch
import glob as globmod
import os
import posixpath
import re
import subprocess
import sys

UNK = "\x01"          # in a value: something a static reading cannot know
GLOB = "\x00glob:"     # a list element that is a glob pattern's matches
ENV = "\x02"          # in a value: an environment variable's default
ARM = "\x03"          # a state's key: the arm of a `switch` on that variable
MAX_STATES = 64
MAX_VALUES = 256

# Scripts whose working directory is their build directory, so a relative
# name they read is the build's: `build.sh` runs each from `$out`.
BUILD_CWD = {
    "boards/de25-nano/quartus/hps.tcl",
    "boards/de25-nano/quartus/rams_check.tcl",
    "boards/de25-nano/quartus/sta_check.tcl",
    "boards/de25-nano/quartus/quux15_sta_check.tcl",
    "boards/de25-nano/quartus/fault_sta.tcl",
    "boards/de25-nano/quartus/sta_common.tcl",
}

# A path a script in `BUILD_CWD` reads that starts with one of these is the
# tree's (named through `[info script]`), not the build directory's.
TREE_TOPS = ("boards", "rtl", "tools", "tb", "golden", "mutations")

# What a static reading cannot resolve: (script, command, the read's words
# as written, how many reads that covers, why).  Every entry is held to its
# count.
UNRESOLVED = [
    ("boards/de25-nano/quartus/project.tcl", "set_global_assignment",
     "[file join $root $f]", 1,
     "the DE25-Nano's sources, `[lrange $argv 2 end]`: make's list, which "
     "build.sh passes on; held by --make"),
    ("boards/de25-nano/quartus/project.tcl", "set_global_assignment",
     "[file join $build ip *.ip]", 4,
     "the IP variants build.sh's ip-deploy step writes into the build "
     "directory named on the command line"),
    ("boards/arty-z7-20/vivado/ddr_check.tcl", "open", "$path", 1,
     "`local_conf_serial`'s argument, the board's `linux/local.conf` under "
     "`BOARD_DIR` from the environment: the operator's own, gitignored"),
    ("tools/jtag_target.tcl", "open", "$path", 1,
     "`jtag_local_conf_serial`'s argument, the board's `linux/local.conf` "
     "under the directory its caller is given: the operator's own, gitignored"),
    ("boards/de25-nano/quartus/jtag.tcl", "open", "$path", 1,
     "`de25_conf_value`'s argument, the board's `local.conf`, under "
     "`BOARD_DIR` when the environment names one: the operator's own"),
    ("boards/de25-nano/quartus/jtag.tcl", "open", "$vid", 1,
     "a USB device's `idVendor` under /sys/bus/usb/devices, found at run time"),
    ("boards/de25-nano/quartus/jtag.tcl", "open", "$ser", 1,
     "a USB device's `serial` under /sys/bus/usb/devices, found at run time"),
    ("tools/build_stamp.tcl", "open", "$path", 1,
     "`build_stamp_read`'s sidecar, `<bitstream>.stamp`, which "
     "`build_stamp_write` writes beside a bitstream the flow built"),
    ("boards/arty-z7-20/vivado/ddr_check.tcl", "source", "$init", 1,
     "ps7_init.tcl, named by PS7_INIT or the board's facts; `make ps7-init` "
     "writes it under build/"),
    ("boards/arty-z7-20/vivado/ddr_run.tcl", "source", "$init", 1,
     "ps7_init.tcl, `PS7_INIT` or build/ps7/; `make ps7-init` writes it"),
    ("boards/arty-z7-20/vivado/prove_read.tcl", "source", "$init", 1,
     "ps7_init.tcl, `PS7_INIT` or build/ps7/; `make ps7-init` writes it"),
    ("boards/arty-z7-20/vivado/prove_write.tcl", "source", "$init", 1,
     "ps7_init.tcl, `PS7_INIT` or build/ps7/; `make ps7-init` writes it"),
]


# ------------------------------------------------------------------ parsing

class Word:
    __slots__ = ("kind", "text", "expand", "line")

    def __init__(self, kind, text, expand=False, line=1):
        self.kind, self.text, self.expand, self.line = kind, text, expand, line

    def raw(self):
        if self.kind == "brace":
            return "{" + self.text + "}"
        if self.kind == "quote":
            return '"' + self.text + '"'
        return self.text


class ParseError(Exception):
    pass


def match_brace(s, i):
    """The index of the `}` closing the `{` at `i`."""
    depth, n = 0, len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ParseError("unbalanced {")


def match_bracket(s, i):
    """The index of the `]` closing the `[` at `i`."""
    depth, n, start = 0, len(s), True
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            start = False
            continue
        if c == "{" and start:
            i = match_brace(s, i) + 1
            start = False
            continue
        if c == '"' and start:
            i = match_quote(s, i) + 1
            start = False
            continue
        if c == "[":
            depth += 1
            start = True
            i += 1
            continue
        if c == "]":
            depth -= 1
            if depth == 0:
                return i
        start = c in " \t\n;"
        i += 1
    raise ParseError("unbalanced [")


def match_quote(s, i):
    """The index of the `"` closing the `"` at `i`."""
    i += 1
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == "[":
            i = match_bracket(s, i) + 1
            continue
        if c == '"':
            return i
        i += 1
    raise ParseError('unbalanced "')


def scan_bare(s, i):
    n = len(s)
    while i < n:
        c = s[i]
        if c in " \t\r\n;":
            return i
        if c == "\\":
            if i + 1 < n and s[i + 1] == "\n":
                return i
            i += 2
            continue
        if c == "[":
            i = match_bracket(s, i) + 1
            continue
        i += 1
    return i


def parse(s, line=1):
    """Tcl's commands: a list of (line, [Word])."""
    cmds, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c in " \t\r;":
            i += 1
            continue
        if c == "\n":
            line += 1
            i += 1
            continue
        if c == "\\" and i + 1 < n and s[i + 1] == "\n":
            line += 1
            i += 2
            continue
        if c == "#":
            while i < n and s[i] != "\n":
                if s[i] == "\\" and i + 1 < n:
                    if s[i + 1] == "\n":
                        line += 1
                    i += 2
                    continue
                i += 1
            continue
        words, cline = [], line
        while i < n and s[i] not in "\n;":
            c = s[i]
            if c in " \t\r":
                i += 1
                continue
            if c == "\\" and i + 1 < n and s[i + 1] == "\n":
                line += 1
                i += 2
                continue
            start, expand = i, False
            if s.startswith("{*}", i) and i + 3 < n and s[i + 3] not in " \t\r\n;":
                expand = True
                i += 3
            if s[i] == "{":
                j = match_brace(s, i)
                words.append(Word("brace", s[i + 1:j], expand, line))
                i = j + 1
            elif s[i] == '"':
                j = match_quote(s, i)
                words.append(Word("quote", s[i + 1:j], expand, line))
                i = j + 1
            else:
                j = scan_bare(s, i)
                words.append(Word("bare", s[i:j], expand, line))
                i = j
            line += s.count("\n", start, i)
        if words:
            cmds.append((cline, words))
    return cmds


def list_split(v):
    """A Tcl list's elements."""
    out, i, n = [], 0, len(v)
    while i < n:
        if v[i] in " \t\r\n":
            i += 1
            continue
        if v[i] == "{":
            j = match_brace(v, i)
            out.append(v[i + 1:j])
            i = j + 1
        elif v[i] == '"':
            j = match_quote(v, i)
            out.append(v[i + 1:j])
            i = j + 1
        else:
            j = i
            while j < n and v[j] not in " \t\r\n":
                j += 1
            out.append(v[i:j])
            i = j
    return out


def list_join(elems):
    return " ".join("{%s}" % e if (e == "" or re.search(r"[\s{}\"\[\]$;\\]", e)) else e
                    for e in elems)


# --------------------------------------------------------------- the walker

class Read:
    def __init__(self, script, line, cmd, raw, path, kind="file"):
        self.script, self.line, self.cmd, self.raw = script, line, cmd, raw
        self.path, self.kind = path, kind


class Walker:
    """Tcl walked for what it reads.  A state maps each variable to the set
    of values it can hold; every branch of an `if` is walked and the states
    after it are merged, so the walk is linear in the script.  Only a
    `switch` on a variable keeps its arms apart, as separate states, so that
    what an arm binds stays with the arm."""
    READERS = {"read_verilog", "read_vhdl", "read_xdc", "read_mem", "read_ip",
               "read_bd", "read_edif", "read_checkpoint", "add_files",
               "import_files"}
    OPT_VALUE = {"-ref", "-cell", "-library", "-fileset", "-of_objects",
                 "-mode", "-processing_order", "-encoding", "-section_id",
                 "-entity", "-tag", "-to", "-from"}
    IMAGES = (".hex", ".mem", ".mif", ".coe")

    def __init__(self, root, tracked):
        self.root, self.tracked = root, tracked
        self.reads = []
        self.procs = {}
        self.called = set()
        self.defined = {}
        self.stack = []
        self.line = 1

    # -- values: a word's value is a set of strings

    def var(self, st, name):
        name = name[2:] if name.startswith("::") else name
        v = st.get(name)
        return {UNK + name} if v is None else set(v)

    def subst(self, w, st):
        if w.kind == "brace":
            return {w.text}
        return self.subst_text(w.text, st)

    def subst_text(self, s, st):
        acc, i, n = {""}, 0, len(s)
        def add(piece):
            nonlocal acc
            if isinstance(piece, str):
                acc = {a + piece for a in acc}
            else:
                acc = {a + p for a in acc for p in piece}
                if len(acc) > MAX_VALUES:
                    acc = {UNK + "many"}
        while i < n:
            c = s[i]
            if c == "\\" and i + 1 < n:
                nxt = s[i + 1]
                add({"n": "\n", "t": "\t"}.get(nxt, " " if nxt == "\n" else nxt))
                i += 2
            elif c == "[":
                j = match_bracket(s, i)
                add(self.command_value(s[i + 1:j], st))
                i = j + 1
            elif c == "$":
                m = re.match(r"\$(?:\{([^}]*)\}|((?:::)?[A-Za-z0-9_]+(?:::[A-Za-z0-9_]+)*))", s[i:])
                if not m:
                    add("$")
                    i += 1
                    continue
                name = m.group(1) or m.group(2)
                i += m.end()
                if m.group(2) and i < n and s[i] == "(":
                    j = s.find(")", i)
                    add(UNK + name + "()")
                    i = (j if j >= 0 else n - 1) + 1
                    continue
                add(self.var(st, name))
            else:
                j = i
                while j < n and s[j] not in "\\[$":
                    j += 1
                add(s[i:j])
                i = j
        return acc

    def combos(self, words, st):
        """Every combination of the words' values, as tuples."""
        out = [()]
        for w in words:
            vals = self.subst(w, st)
            out = [o + (v,) for o in out for v in vals]
            if len(out) > MAX_VALUES:
                return [tuple(UNK + "many" for _ in words)]
        return out

    def command_value(self, script, st):
        """A command substitution's values, walked for its reads."""
        val = {""}
        for line, words in parse(script, self.line):
            self.command(line, words, [st])
            val = self.value_of(words, st)
        return val

    def value_of(self, words, st):
        out = set()
        for name in self.subst(words[0], st):
            out |= self.value_of1(name, words[1:], st)
        return out

    def value_of1(self, name, args, st):
        if name == "list":
            return {list_join(list(c)) for c in self.combos(args, st)}
        if name == "concat":
            return {" ".join(c) for c in self.combos(args, st)}
        if name == "set" and len(args) == 1:
            return set().union(*(self.var(st, v) for v in self.subst(args[0], st)))
        if name == "set" and len(args) == 2:
            return self.subst(args[1], st)
        if name == "pwd":
            return {"."}
        if name == "info" and args and "script" in self.subst(args[0], st):
            return {self.stack[-1] if self.stack else UNK}
        if name == "file" and args:
            out = set()
            for c in self.combos(args, st):
                sub, vals = c[0], [v.replace(ENV, "") if UNK not in v else v for v in c[1:]]
                if sub == "join" and vals:
                    out.add(posixpath.join(*vals))
                elif sub == "normalize" and len(vals) == 1:
                    out.add(posixpath.normpath(vals[0]))
                elif sub == "dirname" and len(vals) == 1:
                    out.add(posixpath.dirname(vals[0]) or ".")
                elif sub == "tail" and len(vals) == 1:
                    out.add(posixpath.basename(vals[0]))
                else:
                    out.add(UNK + "file")
            return out
        if name == "expr" and len(args) == 1:
            m = re.match(r"\s*\[info exists ::env\((\w+)\)\]\s*\?\s*\$::env\(\1\)\s*:\s*(.*?)\s*$",
                         args[0].text if args[0].kind == "brace" else "", re.S)
            if m:
                default = parse(m.group(2))
                if len(default) == 1 and len(default[0][1]) == 1:
                    return {ENV + v for v in self.subst(default[0][1][0], st)}
            return {UNK + "expr"}
        if name == "glob":
            out = set()
            for c in self.combos(args, st):
                pats, directory, i = [], None, 0
                while i < len(c):
                    if c[i] == "-directory" and i + 1 < len(c):
                        directory = c[i + 1]
                        i += 2
                        continue
                    if not c[i].startswith("-"):
                        pats.append(c[i] if directory is None else posixpath.join(directory, c[i]))
                    i += 1
                out.add(list_join([GLOB + p for p in pats]))
            return out
        return {UNK + name}

    # -- states

    def bind(self, st, name, values):
        name = name[2:] if name.startswith("::") else name
        st = dict(st)
        st.pop(ARM + name, None)
        st[name] = frozenset(values)
        return st

    def merge(self, states):
        """One state from several: each variable's values, united."""
        if len(states) == 1:
            return states[0]
        keys = set().union(*states)
        out = {}
        for k in keys:
            if k.startswith(ARM):
                vals = [s.get(k) for s in states]
                if all(v == vals[0] for v in vals):
                    out[k] = vals[0]
                continue
            vals = set()
            for s in states:
                vals |= s.get(k, {UNK + k})
            out[k] = frozenset(vals) if len(vals) <= MAX_VALUES else frozenset({UNK + "many"})
        return out

    # -- the walk

    def walk_script(self, path, states):
        if path in self.stack or len(self.stack) > 8:
            return states
        with open(os.path.join(self.root, path), encoding="utf-8", errors="replace") as f:
            text = f.read()
        try:
            cmds = parse(text)
        except ParseError as e:
            raise ParseError("%s: %s" % (path, e))
        self.stack.append(path)
        try:
            return self.walk(cmds, states)
        finally:
            self.stack.pop()

    def walk(self, cmds, states):
        for line, words in cmds:
            if not states:
                break
            out = []
            for st in states:
                out.extend(self.command1(line, words, st))
            states = dedupe(out)
            if len(states) > MAX_STATES:
                raise ParseError("%s:%d: more than %d arms through the script"
                                 % (self.stack[-1], line, MAX_STATES))
        return states

    def command(self, line, words, states):
        out = []
        for st in states:
            out.extend(self.command1(line, words, st))
        return out

    def walk_body(self, w, line, st):
        """A body's states after it; [] when every path through it exits."""
        if w.kind == "brace":
            return self.walk(parse(w.text, w.line), [st])
        out = []
        for text in self.subst(w, st):
            out.extend(self.walk(parse(text, w.line), [st]))
        return out

    def command1(self, line, words, st):
        self.line = line
        names = self.subst(words[0], st)
        if len(names) != 1:
            for w in words[1:]:
                self.subst(w, st)
            return [st]
        name = next(iter(names))
        args = words[1:]
        if name in ("exit", "error"):
            for w in args:
                self.subst(w, st)
            return []
        if name == "set" and len(args) == 2:
            vals = self.subst(args[1], st)
            for v in self.subst(args[0], st):
                st = self.bind(st, v, vals)
            return [st]
        if name in ("incr", "gets", "unset") and args:
            for v in self.subst(args[0 if name != "gets" else -1], st):
                st = self.bind(st, v, {UNK + name})
            return [st]
        if name in ("lappend", "append") and args:
            for v in self.subst(args[0], st):
                old = self.var(st, v)
                new = set()
                for o in old:
                    for c in self.combos(args[1:], st):
                        if name == "append":
                            new.add(o + "".join(c))
                        elif UNK in o:
                            new.add(o + " " + list_join(list(c)))
                        else:
                            new.add(list_join(list_split(o) + list(c)))
                st = self.bind(st, v, new if len(new) <= MAX_VALUES else {UNK + "many"})
            return [st]
        if name == "if":
            return self.walk_if(line, args, st)
        if name == "switch":
            return self.walk_switch(line, args, st)
        if name == "foreach" and len(args) >= 3:
            return self.walk_foreach(line, args, st)
        if name == "while" and len(args) == 2:
            self.walk_expr(args[0], st)
            return [self.merge([st] + self.walk_body(args[1], line, st))]
        if name == "for" and len(args) == 4:
            sts = [self.merge([st] + self.walk_body(args[0], line, st))]
            after = []
            for s in sts:
                for s2 in self.walk_body(args[3], line, s):
                    after.extend(self.walk_body(args[2], line, s2))
            return [self.merge(sts + after)]
        if name == "catch" and args:
            return [self.merge([st] + self.walk_body(args[0], line, st))]
        if name == "namespace" and len(args) >= 3 and self.subst(args[0], st) == {"eval"}:
            return self.walk_body(args[2], line, st)
        if name == "proc" and len(args) == 3:
            for pname in self.subst(args[0], st):
                self.procs[pname] = (args[1].text, args[2], line, self.stack[-1])
                self.defined[(self.stack[-1], pname)] = self.procs[pname]
            return [st]
        if len(args) >= 2 and self.subst(args[0], st) == {"eval"} and args[1].kind == "bare" \
                and args[1].text.startswith("[list ") and args[1].text.endswith("]"):
            inner = parse(args[1].text[6:-1])
            if len(inner) == 1:
                return self.command1(line, inner[0][1], st)
        if name == "eval" and len(args) == 1 and args[0].kind == "brace":
            return self.walk_body(args[0], line, st)
        if name in self.procs:
            return self.call(line, name, args, st)
        combos = self.combos(args, st)
        for values in combos:
            self.reader(line, name, args, list(values))
        if name == "source":
            out = []
            for values in combos:
                path = [v for v in values if not v.startswith("-")]
                if path and UNK not in path[-1]:
                    p = norm(path[-1].replace(ENV, ""))
                    if p.endswith(".tcl") and os.path.isfile(os.path.join(self.root, p)):
                        out.extend(self.walk_script(p, [st]))
                        continue
                out.append(st)
            return dedupe(out)
        return [st]

    def walk_expr(self, w, st):
        """Walk the command substitutions in an expression for their reads."""
        text, i = w.text, 0
        while i < len(text):
            if text[i] == "\\":
                i += 2
            elif text[i] == "[":
                j = match_bracket(text, i)
                self.command_value(text[i + 1:j], st)
                i = j + 1
            else:
                i += 1

    def decide(self, w, st):
        """True or False when the condition compares only what a `switch`
        arm bound with literals; None otherwise.  Any other variable may have
        been set by a command this does not follow, so it decides nothing."""
        text = w.text.strip()
        def atom(a):
            a = a.strip()
            m = re.fullmatch(r'\$(?:::)?([A-Za-z0-9_]+)', a)
            if m:
                return st.get(ARM + m.group(1))
            m = re.fullmatch(r'"([^"$\[\\]*)"', a) or re.fullmatch(r"([A-Za-z0-9_.]+)", a)
            return m.group(1) if m else None
        for op_re, fn in ((r"\s*&&\s*", all), (r"\s*\|\|\s*", any)):
            parts = re.split(op_re, text)
            if len(parts) > 1:
                vals = [self.decide(Word("brace", p), st) for p in parts]
                return None if None in vals else fn(vals)
        m = re.fullmatch(r"(.+?)\s+(eq|ne|==|!=)\s+(.+)", text)
        if m:
            a, b = atom(m.group(1)), atom(m.group(3))
            if a is None or b is None:
                return None
            return (a == b) == (m.group(2) in ("eq", "=="))
        return None

    def walk_if(self, line, args, st):
        out, i, closed = [], 0, False
        while i < len(args):
            cond = args[i]
            i += 1
            if i < len(args) and args[i].text == "then":
                i += 1
            if i >= len(args):
                break
            body = args[i]
            i += 1
            self.walk_expr(cond, st)
            d = self.decide(cond, st)
            if d is not False:
                out.extend(self.walk_body(body, line, st))
            if d is True:
                closed = True
                break
            if i < len(args) and args[i].text == "elseif":
                i += 1
                continue
            if i < len(args) and args[i].text == "else" and i + 1 < len(args):
                out.extend(self.walk_body(args[i + 1], line, st))
                closed = True
            break
        if not closed:
            out.append(st)
        return [self.merge(out)] if out else []

    def walk_switch(self, line, args, st):
        i, mode = 0, "exact"
        while i < len(args) and args[i].text.startswith("-"):
            o = args[i].text
            i += 1
            if o == "--":
                break
            if o in ("-glob", "-regexp", "-exact"):
                mode = o[1:]
        if i >= len(args):
            return [st]
        subj_w = args[i]
        subjects = self.subst(subj_w, st)
        rest = args[i + 1:]
        if len(rest) == 1 and rest[0].kind == "brace":
            arms = list_split(rest[0].text)
            text, lines, at = rest[0].text, [], 0
            for a in arms:
                at = text.find(a, at)
                lines.append(rest[0].line + text.count("\n", 0, max(at, 0)))
                at += len(a)
        elif len(rest) == 1:
            arms, lines = [], []
        else:
            arms, lines = [w.text for w in rest], [w.line for w in rest]
        pairs = list(zip(arms[0::2], arms[1::2]))
        m = re.fullmatch(r"\$(?:::)?([A-Za-z0-9_]+)", subj_w.text) if subj_w.kind == "bare" else None
        subject = next(iter(subjects)) if len(subjects) == 1 else UNK
        known = UNK not in subject and GLOB not in subject and ENV not in subject
        out, pending, has_default = [], [], False
        for k, (pat, body) in enumerate(pairs):
            line = lines[2 * k + 1]
            pending.append(pat)
            if body == "-":
                continue
            lits = [p for p in pending if p != "default" or k != len(pairs) - 1]
            is_default = "default" in pending and k == len(pairs) - 1
            has_default |= is_default
            if known:
                hit = any(subject == p if mode == "exact" else
                          fnmatch.fnmatchcase(subject, p) if mode == "glob" else
                          re.search(p, subject) for p in lits)
                if hit or is_default:
                    return self.walk(parse(body, line), [st])
            else:
                s2 = st
                if m and mode == "exact" and len(lits) == 1 and not is_default:
                    s2 = dict(st)
                    s2[ARM + m.group(1)] = lits[0]
                out.extend(self.walk(parse(body, line), [s2]))
            pending = []
        if known or not has_default:
            out.append(st)
        return dedupe(out)

    def walk_foreach(self, line, args, st):
        """The body once, each loop variable holding every element."""
        body = args[-1]
        s2 = st
        for k in range(0, len(args) - 1, 2):
            names = list_split(args[k].text)
            elems = set()
            for v in self.subst(args[k + 1], st):
                if UNK in v:
                    elems.add(v)
                else:
                    try:
                        elems.update(list_split(v))
                    except ParseError:
                        elems.add(UNK + "list")
            for nm in names:
                s2 = self.bind(s2, nm, elems or {""})
        return [self.merge([st] + self.walk_body(body, line, s2))]

    def call(self, line, name, args, st):
        params, body, pline, where = self.procs[name]
        self.called.add((where, name))
        if len(self.stack) > 8 or name in self.stack[-1:]:
            return [st]
        local = dict(st)
        plist = list_split(params)
        vals = [self.subst(w, st) for w in args]
        for k, p in enumerate(plist):
            pe = list_split(p)
            pname = pe[0] if pe else p
            if pname == "args" and k == len(plist) - 1:
                local[pname] = frozenset({UNK + "args"})
                break
            if k < len(vals):
                local[pname] = frozenset(vals[k])
            elif len(pe) > 1:
                local[pname] = frozenset({pe[1]})
            else:
                local[pname] = frozenset({UNK + pname})
        self.stack.append(where)
        try:
            self.walk_body(body, pline, local)
        finally:
            self.stack.pop()
        return [st]

    def uncalled(self):
        """Every procedure no walk called, once, with its defaults: what it
        reads with a parameter is unresolved."""
        while True:
            todo = [k for k in self.defined if k not in self.called]
            if not todo:
                return
            for key in todo:
                params, body, pline, where = self.defined[key]
                self.called.add(key)
                local = {}
                for p in list_split(params):
                    pe = list_split(p)
                    if pe:
                        local[pe[0]] = frozenset({pe[1]} if len(pe) > 1 else {UNK + pe[0]})
                self.stack.append(where)
                try:
                    self.walk_body(body, pline, local)
                finally:
                    self.stack.pop()

    # -- what a command reads

    def reader(self, line, name, args, values):
        script = self.stack[-1]
        raws = [w.raw() for w in args]
        def emit(k, kind="file"):
            v = values[k]
            if UNK in v:
                elems = [v]
            else:
                try:
                    elems = list_split(v)
                except ParseError:
                    elems = [UNK + v]
            for e in elems:
                self.reads.append(Read(script, line, name, raws[k], e, kind))
        if name in self.READERS or name == "source":
            k = 0
            while k < len(args):
                if values[k].startswith("-"):
                    k += 2 if values[k] in self.OPT_VALUE else 1
                    continue
                emit(k)
                k += 1
            return
        if name == "open" and values:
            mode = values[1] if len(values) > 1 else "r"
            if mode.startswith("r") and "w" not in mode and "a" not in mode:
                emit(0)
            return
        if name == "set_global_assignment" and "-name" in values:
            k = values.index("-name")
            if k + 1 < len(values) and values[k + 1].endswith("_FILE"):
                emit(len(values) - 1)
            return
        if name == "set_parameter" and "-name" in values and len(values) >= 3:
            if values[-1].endswith(self.IMAGES):
                emit(len(values) - 1)
            return
        if name == "synth_design":
            for k, v in enumerate(values):
                if v == "-include_dirs" and k + 1 < len(values):
                    emit(k + 1, "dir")
                if v == "-generic" and k + 1 < len(values) and "=" in values[k + 1]:
                    val = values[k + 1].split("=", 1)[1]
                    if val.replace(ENV, "").endswith(self.IMAGES):
                        self.reads.append(Read(script, line, name, raws[k + 1], val))


def norm(p):
    return posixpath.normpath(p) if p else p


def dedupe(states):
    seen, out = set(), []
    for s in states:
        key = frozenset(s.items())
        if key not in seen:
            seen.add(key)
            out.append(s)
    return out


# ------------------------------------------------------------- the checks

def tracked_files(root):
    try:
        out = subprocess.run(["git", "-C", root, "ls-files", "-z"],
                             capture_output=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    # A copy of a tree that is not itself a git work tree (the mutation
    # runner's) has no index of its own; `git -C` would find an enclosing one.
    top = subprocess.run(["git", "-C", root, "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True)
    if top.returncode != 0 or os.path.realpath(top.stdout.strip()) != os.path.realpath(root):
        return None
    return set(p.decode() for p in out.stdout.split(b"\0") if p)


def flow_scripts(root):
    found = []
    for top in ("boards", "rtl", "tools"):
        for d, dirs, files in os.walk(os.path.join(root, top)):
            dirs[:] = sorted(x for x in dirs if x not in ("linux", "target", "__pycache__"))
            for f in sorted(files):
                if f.endswith((".tcl", ".xdc", ".sdc")):
                    found.append(os.path.relpath(os.path.join(d, f), root).replace(os.sep, "/"))
    return found


SHELL_SCRIPTS = ["boards/de25-nano/quartus/build.sh",
                 "boards/de25-nano/quartus/program.sh"]
SHELL_PATH = re.compile(
    r"\$\{?(here|root)\}?/([\w./-]*\w)"
    r"|(?<![\w$/.{-])((?:boards|rtl|tools|tb|golden|build)/[\w./-]*\w)")


def shell_reads(root):
    """Every path the shell scripts' code names: (script, line, path)."""
    out = []
    for script in SHELL_SCRIPTS:
        here = posixpath.dirname(script)
        with open(os.path.join(root, script)) as f:
            for n, line in enumerate(f, 1):
                if line.lstrip().startswith("#"):
                    continue
                for m in SHELL_PATH.finditer(line):
                    tail = line[m.end():m.end() + 1]
                    if tail in ("*", "$", "{"):
                        continue
                    if m.group(1):
                        base, rel = {"here": here, "root": "."}[m.group(1)], m.group(2)
                    else:
                        base, rel = ".", m.group(3)
                    out.append((script, n, norm(posixpath.join(base, rel))))
    return out


def make_lists(root):
    """What `make -n` hands `build.sh` for each DE25-Nano build."""
    hexes = ["build/boot_prom.hex", "build/sync_prom.hex", "build/boot_prom.quux15.hex"]
    runs = [("de25", ["MACHINE=cadr"]),
            ("de25", ["MACHINE=cadr", "DDR=1", "HDMI=1", "PROBE_DEPTH=1024"]),
            ("de25", ["MACHINE=quux"]),
            ("de25-fault", [])]
    out, fails = [], []
    for target, extra in runs:
        cmd = ["make", "-s", "-n", "--no-print-directory"] + \
              sum((["-o", h] for h in hexes), []) + [target] + extra
        r = subprocess.run(cmd, cwd=root, capture_output=True, text=True)
        what = " ".join([target] + extra)
        if r.returncode != 0:
            fails.append("make -n %s: %s" % (what, (r.stderr.strip().splitlines() or ["failed"])[-1]))
            continue
        text = r.stdout.replace("\\\n", " ")
        m = re.search(r"boards/de25-nano/quartus/build\.sh((?:[ \t]+[^\s;&|]+)*)", text)
        if not m:
            fails.append("make -n %s: no build.sh command" % what)
            continue
        files = m.group(1).split()
        if not files:
            fails.append("make -n %s: build.sh is handed no sources" % what)
        out.extend((what, f) for f in files)
    return out, fails


def main():
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = os.path.abspath(argv[0] if argv else ".")
    use_make = "--make" in sys.argv[1:]
    listing = "--list" in sys.argv[1:]
    tracked = tracked_files(root)
    scripts = flow_scripts(root)

    reads, sourced = [], set()
    w = Walker(root, tracked)
    # Each script on its own, with what it sources walked in place; a script
    # that another sources is a root of its own only if nothing sources it,
    # since what it reads may be named by its caller's variables.
    per_root = {}
    errors = []
    for s in scripts:
        w.reads, w.procs = [], {}
        try:
            w.walk_script(s, [{}])
        except ParseError as e:
            errors.append("cannot read %s" % e)
            continue
        per_root[s] = w.reads
        for r in w.reads:
            if r.cmd == "source" and UNK not in r.path:
                sourced.add(norm(r.path.replace(ENV, "")))
    for s in scripts:
        if s in per_root and s not in sourced:
            reads.extend(per_root[s])
    # Then every procedure that no script calls.
    w.reads, w.procs = [], {}
    try:
        w.uncalled()
    except ParseError as e:
        errors.append("cannot read %s" % e)
    reads.extend(w.reads)

    missing, unresolved, ok, generated, globs, local = [], [], set(), set(), set(), set()
    seen = set()
    for r in reads:
        key = (r.script, r.line, r.cmd, r.path)
        if key in seen:
            continue
        seen.add(key)
        if listing:
            print("read: %s:%d: %s %s" % (r.script, r.line, r.cmd,
                                          r.path.replace(ENV, "").replace(UNK, "?").replace(GLOB, "glob:")))
        p = r.path.replace(ENV, "")
        if UNK in p or p.startswith("/"):
            unresolved.append(r)
            continue
        if p.startswith(GLOB):
            pat = p[len(GLOB):]
            if not globmod.glob(os.path.join(root, pat)):
                missing.append("%s:%d: %s %s matches no file" % (r.script, r.line, r.cmd, pat))
            else:
                globs.add(pat)
            continue
        p = norm(p)
        if r.script in BUILD_CWD and p.split("/")[0] not in TREE_TOPS:
            generated.add(p)
            continue
        if p == "build" or p.startswith("build/"):
            generated.add(p)
            continue
        if posixpath.basename(p) == "local.conf":
            local.add(p)     # the operator's own, gitignored, read only if there
            continue
        there = os.path.isdir(os.path.join(root, p)) if r.kind == "dir" \
            else os.path.isfile(os.path.join(root, p))
        if not there:
            missing.append("%s:%d: %s %s, which is not in the tree" % (r.script, r.line, r.cmd, p))
        elif tracked is not None and r.kind == "file" and p not in tracked:
            missing.append("%s:%d: %s %s, which is not tracked" % (r.script, r.line, r.cmd, p))
        else:
            ok.add(p)

    for script, n, p in shell_reads(root):
        if listing:
            print("read: %s:%d: names %s" % (script, n, p))
        if p == "build" or p.startswith("build/"):
            generated.add(p)
            continue
        if posixpath.basename(p) == "local.conf":
            local.add(p)
            continue
        full = os.path.join(root, p)
        if not (os.path.isfile(full) or os.path.isdir(full)):
            missing.append("%s:%d: names %s, which is not in the tree" % (script, n, p))
        else:
            ok.add(p)

    # The table of what cannot be resolved, held to its counts: a read is
    # its script, line and words, however many values it might take.
    counts = [0] * len(UNRESOLVED)
    once = set()
    for r in unresolved:
        if (r.script, r.line, r.cmd, r.raw) in once:
            continue
        once.add((r.script, r.line, r.cmd, r.raw))
        for k, (script, cmd, pattern, _, _) in enumerate(UNRESOLVED):
            if r.script == script and r.cmd == cmd and re.fullmatch(
                    re.escape(pattern).replace(r"\*", ".*"), r.raw):
                counts[k] += 1
                break
        else:
            missing.append("%s:%d: %s %s resolves to nothing a static reading knows"
                           % (r.script, r.line, r.cmd, r.raw))
    for k, (script, cmd, pattern, want, why) in enumerate(UNRESOLVED):
        if counts[k] != want:
            missing.append("UNRESOLVED's %s %s %s covers %d reads and says %d"
                           % (script, cmd, pattern, counts[k], want))

    made = 0
    if use_make:
        lists, fails = make_lists(root)
        missing.extend(fails)
        for what, f in lists:
            if not os.path.isfile(os.path.join(root, f)):
                missing.append("make -n %s hands build.sh %s, which is not in the tree" % (what, f))
            elif tracked is not None and f not in tracked:
                missing.append("make -n %s hands build.sh %s, which is not tracked" % (what, f))
            else:
                ok.add(f)
                made += 1

    for e in errors:
        print("fit-sources: FAIL --- %s" % e)
    for m in missing:
        print("fit-sources: FAIL --- %s" % m)
    print("fit-sources: %d scripts, %d files read and there, %d globs, %d under build/ "
          "or the build directory, %d local.conf, %d reads named in UNRESOLVED%s"
          % (len(scripts) + len(SHELL_SCRIPTS), len(ok), len(globs), len(generated),
             len(local), sum(counts), ", %d sources make hands build.sh" % made if use_make else ""))
    if errors or missing:
        return 1
    print("fit-sources: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
