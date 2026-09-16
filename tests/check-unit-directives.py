#!/usr/bin/env python3
"""check-unit-directives.py — find systemd directives set MORE THAN ONCE in one section.

Usage: check-unit-directives.py <file> [<file>...]
Exit:  0 no duplicates, 1 at least one found (each printed with both line numbers).

Called by tests/smoke-build.sh. Handles standalone unit files AND units written
from a heredoc inside an installer script, which is where the one real instance
lived.

systemd takes the LAST value for most directives, silently. That is how
kldload-smoke-firstboot.service ended up writing its report to the journal:
`StandardOutput=file:...` was added above a leftover `StandardOutput=journal`
(fiend, build 22, 2026-09-16). Covers both standalone unit files and units
written from a heredoc inside an installer script.

A few directives are legitimately repeatable and are skipped.
"""
import re
import sys

REPEATABLE = {
    "ExecStart", "ExecStartPre", "ExecStartPost", "ExecStop", "ExecStopPost",
    "ExecReload", "ExecCondition", "Environment", "EnvironmentFile", "After",
    "Before", "Wants", "Requires", "RequiresMountsFor", "Also", "WantedBy",
    "RequiredBy", "Conflicts", "ConditionPathExists", "ConditionPathIsDirectory",
    "AssertPathExists", "BindPaths", "ReadWritePaths", "ReadOnlyPaths",
    "InaccessiblePaths", "SupplementaryGroups", "LoadCredential", "Alias",
    "DeviceAllow", "IPAddressAllow", "IPAddressDeny", "ListenStream",
    "ConditionVirtualization", "ConditionKernelCommandLine", "Documentation",
    "TemporaryFileSystem", "UnsetEnvironment", "PassEnvironment", "Sockets",
    # systemd.path: each entry ADDS a watch, they do not overwrite each other
    "PathChanged", "PathExists", "PathExistsGlob", "PathModified", "DirectoryNotEmpty",
}
DIRECTIVE = re.compile(r"^([A-Z][A-Za-z0-9]*)=")
SECTION = re.compile(r"^\[([A-Za-z]+)\]")
HEREDOC = re.compile(r"<<-?'([A-Z][A-Z0-9_]*)'")

def check(name, lines, origin):
    bad = 0
    section = None
    seen = {}
    for n, line in enumerate(lines):
        s = SECTION.match(line.strip())
        if s:
            section = s.group(1)
            seen = {}
            continue
        m = DIRECTIVE.match(line.strip())
        if not m:
            continue
        key = m.group(1)
        if key in REPEATABLE:
            continue
        if key in seen:
            print("%s: [%s] %s set twice — line %d wins over line %d"
                  % (origin, section, key, n + 1, seen[key] + 1))
            print("      first: %s" % lines[seen[key]].strip()[:88])
            print("      last:  %s" % line.strip()[:88])
            bad += 1
        seen[key] = n
    return bad

total = 0
for path in sys.argv[1:]:
    try:
        text = open(path, encoding="utf-8").read()
    except (UnicodeDecodeError, IsADirectoryError, FileNotFoundError):
        continue
    if path.endswith((".txt", ".md", ".html", ".json")):
        continue
    lines = text.split("\n")
    if path.endswith((".service", ".timer", ".path", ".socket", ".mount", ".conf")):
        if any(SECTION.match(x.strip()) for x in lines):
            total += check(path, lines, path)
        continue
    i = 0
    while i < len(lines):
        m = HEREDOC.search(lines[i])
        if not m:
            i += 1
            continue
        word, start = m.group(1), i
        if not re.search(r"\.(service|timer|path|socket|mount|automount|slice)\"?\s*<<", lines[i]):
            i += 1
            continue
        j = i + 1
        while j < len(lines) and lines[j].strip() != word:
            j += 1
        body = lines[start + 1:j]
        first = next((x.strip() for x in body if x.strip()), "")
        if SECTION.match(first):
            total += check(path, body, "%s:%d <<%s" % (path, start + 1, word))
        i = j + 1
print("\n%d duplicate directive(s)" % total)
sys.exit(1 if total else 0)
