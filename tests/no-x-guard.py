#!/usr/bin/env python3
"""Refuse `[ -x ... ]` on a file this module ships.

ksud installs every file in a module 0644 regardless of the mode the zip carried, so such
a guard is always false and the branch it protects is silently skipped - it cost a whole
boot cycle of the stats refresh, from two call sites, with no error anywhere.

A binary like ksud or ksu_susfs IS executable, so `[ -x "$KSUD" ]` is correct. The
difference is what the path points at, which means following variable assignments rather
than pattern-matching the test itself.
"""
import re, sys, pathlib

OURS = re.compile(r'(\$\{?MODDIR\}?/|\$\{0%/\*\}/|/data/adb/(modules|lkm)/)')
ASSIGN = re.compile(r'^\s*([A-Za-z_][A-Za-z0-9_]*)=(.+)$')
XTEST = re.compile(r'\[\s+-x\s+"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"?\s')
XLIT = re.compile(r'\[\s+-x\s+"?(' + OURS.pattern + r'[^"\s\]]*)')

bad = []
for path in sys.argv[1:]:
    text = pathlib.Path(path).read_text(errors="replace")
    ours = set()
    for line in text.splitlines():
        m = ASSIGN.match(line)
        if m and OURS.search(m.group(2)):
            ours.add(m.group(1))
    for n, line in enumerate(text.splitlines(), 1):
        if XLIT.search(line):
            bad.append((path, n, line.strip(), "literal module path"))
            continue
        m = XTEST.search(line)
        if m and m.group(1) in ours:
            bad.append((path, n, line.strip(), "$%s is a module path" % m.group(1)))

for p, n, line, why in bad:
    print("::error file=%s,line=%d::-x on a file this module ships (%s): ksud installs it 0644, so this is always false. Use -s and run it with sh." % (p, n, why))
    print("  %s:%d  %s" % (p, n, line))
print("  ok   no -x guards on shipped files" if not bad else "  %d problem(s)" % len(bad))
sys.exit(1 if bad else 0)
