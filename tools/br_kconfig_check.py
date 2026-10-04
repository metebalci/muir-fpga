#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Mete Balci
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The image check's configuration questions, asked of each board's defconfig.

    br_kconfig_check.py <post-build.sh> <package dir> <work dir> <defconfig>...

`post-build.sh` (the Arty Z7-20's, which every board runs) asks of the built
`.config` that each package's symbol is there, set or "is not set" (its check
3a).  Kconfig writes no line at all for a symbol whose `depends on` is unmet,
so a package that exists for one board only --- cadr-displayport, the Kria
KR260's --- is absent from every other board's `.config`, and a check that
read that absence as "Config.in not sourced" stopped those boards' builds.

This writes, for each defconfig and without Buildroot, the lines Kconfig
would write for this tree's own symbols: a symbol is `y` when the defconfig
sets it or a `y` symbol selects it; a symbol whose `depends on` holds is
written `=y` or `# ... is not set`; one whose `depends on` does not hold is not
written at all.  The board choice in cadr-common (BR2_CADR_BOARD_*) is written
as its choice: the defconfig's, else its default, inside its `if`.  A symbol
the defconfig sets whose dependency does not hold is reported, because
Kconfig drops it silently and the package is then missing from the image.

Symbols this tree does not declare (Buildroot's own, such as
BR2_PACKAGE_HOST_RUSTC_TARGET_ARCH_SUPPORTS for the Rust packages) cannot be
evaluated without Buildroot; they are written `=y` and named in the output,
which holds for the four boards here (two ARMv7 and two ARMv8 targets that
Rust supports).

Then it runs `post-build.sh` itself against that `.config` and a target tree
it fills on demand: each "a package installs <path> and the image has no such
file" is answered by creating <path>, until the script ends.  The target
checks are not what this asks, the configuration checks are.

**AND THE OTHER SIDE OF THE BOUND.**  A check 3a that accepted every absent
symbol would pass the above too, and would no longer catch the fault it exists
for, a package whose Config.in is not sourced.  So for each board, each
package symbol Kconfig does write there is taken out of the `.config` in turn,
as an unsourced Config.in leaves it, and the script must refuse every one of
them by name.  The check passes when the script accepts each board's `.config`
and refuses each of those controls.
"""
import os
import re
import shutil
import subprocess
import sys

ENTRY = re.compile(r'^(config|menuconfig|comment|menu|choice|endchoice|if|endif|source|endmenu)\b')


def parse_config_in(path, syms, ifs=()):
    """Every `config` entry of one Config.in: its depends, selects, default
    and enclosing `if`s; choices as lists of their symbols."""
    cur = None
    stack = list(ifs)
    choice = None
    for raw in open(path):
        line = raw.rstrip('\n')
        s = line.strip()
        if ENTRY.match(line):
            cur = None
            kw = line.split()[0]
            if kw in ('config', 'menuconfig'):
                name = line.split()[1]
                cur = {'depends': list(stack), 'select': [], 'choice': choice, 'path': path}
                syms[name] = cur
                if choice is not None:
                    choice['members'].append(name)
            elif kw == 'if':
                stack.append(line.split(None, 1)[1].strip())
            elif kw == 'endif':
                stack.pop()
            elif kw == 'choice':
                choice = {'members': [], 'default': None, 'depends': list(stack)}
                cur = choice
            elif kw == 'endchoice':
                syms.setdefault('__choices__', []).append(choice)
                choice = None
            continue
        if cur is None:
            continue
        if re.match(r'^\s*(help|---help---)\s*$', line):
            cur = None
            continue
        m = re.match(r'^\s*depends on\s+(.*)$', line)
        if m:
            cur['depends'].append(m.group(1).strip())
        m = re.match(r'^\s*select\s+(\S+)', line)
        if m and 'select' in cur:
            cur['select'].append(m.group(1))
        m = re.match(r'^\s*default\s+(BR2_\S+)\s*$', line)
        if m and 'members' in cur:
            cur['default'] = m.group(1)


def holds(expr, y):
    """A `depends on` expression of symbols and `!symbol` joined by `&&`."""
    for term in expr.split('&&'):
        term = term.strip()
        if not re.fullmatch(r'!?BR2_[A-Z0-9_]+', term):
            sys.exit(f'br_kconfig_check: cannot evaluate the dependency {expr!r}')
        if term.startswith('!'):
            if term[1:] in y:
                return False
        elif term not in y:
            return False
    return True


def kconfig_lines(defconfig, syms):
    """The `.config` lines Kconfig would write for this tree's symbols."""
    asked = set(re.findall(r'^(BR2_[A-Z0-9_]+)=y\s*$', open(defconfig).read(), re.M))
    choices = syms.get('__choices__', [])
    ours = {k: v for k, v in syms.items() if k != '__choices__'}
    external = set()
    for v in list(ours.values()) + choices:
        for d in v['depends']:
            external |= {t.lstrip('!').strip() for t in d.split('&&')} - set(ours)
    y = (asked & set(ours)) | external
    while True:
        more = {t for s in y if s in ours for t in ours[s]['select']} - y
        for c in choices:
            if all(holds(d, y) for d in c['depends']):
                pick = [m for m in c['members'] if m in asked] or [c['default']]
                more |= set(pick) - y
        if not more:
            break
        y |= more
    faults = []
    lines = [f'{s}=y' for s in sorted(external)]
    for name, v in sorted(ours.items()):
        met = all(holds(d, y) for d in v['depends'])
        if not met:
            if name in asked:
                faults.append(f'{name}=y is in the defconfig and its dependency '
                              f'{" && ".join(v["depends"])} does not hold: Kconfig drops it')
            continue
        lines.append(f'{name}=y' if name in y else f'# {name} is not set')
    return lines, sorted(external), faults


def package_symbols(pkgdir):
    """The symbol post-build.sh asks about for each package: the first
    `config BR2_PACKAGE_...` of its Config.in."""
    out = {}
    for name in sorted(os.listdir(pkgdir)):
        cfg = os.path.join(pkgdir, name, 'Config.in')
        if os.path.isfile(cfg):
            m = re.search(r'^config (BR2_PACKAGE_[A-Z0-9_]+)\s*$', open(cfg).read(), re.M)
            if m:
                out[name] = m.group(1)
    return out


def run_post_build(script, config, target):
    os.makedirs(target, exist_ok=True)
    env = dict(os.environ, BR2_CONFIG=config)
    env.pop('BASE_DIR', None)
    env.pop('BUILD_DIR', None)
    for _ in range(200):
        p = subprocess.run(['sh', script, target], env=env, capture_output=True, text=True)
        if p.returncode == 0:
            return 0, p.stdout
        m = re.search(r'a package installs (\S+) and the image has no such file', p.stderr)
        if not m:
            return p.returncode, p.stdout + p.stderr
        path = os.path.join(target, m.group(1))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, 'w').close()
    return 1, 'br_kconfig_check: post-build.sh asked for more than 200 files'


def main():
    script, pkgdir, work = sys.argv[1:4]
    syms = {}
    for name in sorted(os.listdir(pkgdir)):
        cfg = os.path.join(pkgdir, name, 'Config.in')
        if os.path.isfile(cfg):
            parse_config_in(cfg, syms)
    bad = 0
    for defconfig in sys.argv[4:]:
        board = os.path.basename(defconfig)
        lines, external, faults = kconfig_lines(defconfig, syms)
        d = os.path.join(work, board)
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d)
        config = os.path.join(d, '.config')
        open(config, 'w').write('\n'.join(lines) + '\n')
        absent = [s for s in syms if s != '__choices__' and s.startswith('BR2_PACKAGE_')
                  and not any(l == f'{s}=y' or l == f'# {s} is not set' for l in lines)]
        for f in faults:
            print(f'br_kconfig_check: {board}: {f}')
            bad += 1
        rc, out = run_post_build(script, config, os.path.join(d, 'target'))
        if rc != 0:
            print(f'br_kconfig_check: {board}: post-build.sh refuses the .config Kconfig writes '
                  f'for this defconfig (exit {rc}):')
            for l in out.strip().splitlines():
                print('    ' + l)
            bad += 1
            continue
        refused = 0
        env = dict(os.environ, BR2_CONFIG=os.path.join(d, 'control'))
        env.pop('BASE_DIR', None)
        env.pop('BUILD_DIR', None)
        for name, sym in package_symbols(pkgdir).items():
            if f'{sym}=y' not in lines and f'# {sym} is not set' not in lines:
                continue
            open(env['BR2_CONFIG'], 'w').write(
                '\n'.join(l for l in lines if l not in (f'{sym}=y', f'# {sym} is not set')) + '\n')
            p = subprocess.run(['sh', script, os.path.join(d, 'target')], env=env,
                               capture_output=True, text=True)
            if p.returncode != 0 and f'declares {sym} and the built .config has never heard of it' in p.stderr:
                refused += 1
            else:
                print(f'br_kconfig_check: {board}: with {sym} taken out of the .config, as an '
                      f'unsourced {name}/Config.in leaves it, post-build.sh does not refuse it '
                      f'(exit {p.returncode})')
                bad += 1
        print(f'br_kconfig_check: {board}: post-build.sh accepts it; '
              f'{len(absent)} package symbol(s) Kconfig does not write here'
              + (f' ({", ".join(sorted(absent))})' if absent else '')
              + f'; {refused} control(s) with a written symbol taken out, each refused'
              + f'; taken as set: {", ".join(external) or "none"}')
    shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
