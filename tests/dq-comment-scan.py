#!/usr/bin/env python3
"""Find shell "comments" that the host executes.

A line that starts with '#' inside a double-quoted string is not a comment to
the shell: it is part of the string, and a $(...) or backquote in it runs when
the string is built -- on THIS host, as whoever runs the script. kvm-mesh sent
its guests a script in "..." whose comment read "$(ip link del)" and
"$(link add)", and every join ran both on the host, as root (2026-09-29).

It asks shfmt's syntax tree, not a regex: a command substitution that is a
part of a double-quoted word, on a line whose text before it starts with '#'.

Usage:  dq-comment-scan.py FILE...
Output: FILE:LINE: TEXT per finding on stdout; a count on stderr.
Exit:   0 always -- the caller (smoke-build) decides; a file shfmt cannot
        parse is skipped, since the syntax gates report that already.
"""

from __future__ import annotations

import json
import subprocess
import sys
from typing import Any


def walk(node: Any, src_lines: list[str], fname: str, out: list[str]) -> None:
    """Append every finding under `node` to `out`."""
    if isinstance(node, dict):
        if node.get("Type") == "DblQuoted":
            for part in node.get("Parts") or []:
                if part.get("Type") != "CmdSubst":
                    continue
                line = part["Pos"]["Line"]
                text = src_lines[line - 1] if line - 1 < len(src_lines) else ""
                before = text[: part["Pos"]["Col"] - 1]
                if before.lstrip().startswith("#"):
                    out.append(f"{fname}:{line}: {text.strip()[:110]}")
        for value in node.values():
            walk(value, src_lines, fname, out)
    elif isinstance(node, list):
        for value in node:
            walk(value, src_lines, fname, out)


def main(files: list[str]) -> int:
    out: list[str] = []
    for fname in files:
        try:
            with open(fname, encoding="utf-8", errors="replace") as fh:
                src = fh.read()
        except OSError:
            continue
        p = subprocess.run(["shfmt", "--to-json"], input=src,
                           capture_output=True, text=True, check=False)
        if p.returncode != 0:
            continue
        walk(json.loads(p.stdout), src.splitlines(), fname, out)
    if out:
        print("\n".join(out))
    print(f"{len(out)} hit(s) in {len(files)} file(s)", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
