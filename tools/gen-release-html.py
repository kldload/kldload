#!/usr/bin/env python3
"""gen-release-html.py — render a release page from CHANGELOG.md.

The release notes live in CHANGELOG.md and the website shows them again. Doing
that by hand is how 1.5.0's section ended up claiming 267 commits and seven
editions when the real numbers were 449 and eleven: two copies, one edited.

This renders the newest section of CHANGELOG.md into the website's release-page
shell, taken from the previous release page so the chrome (theme script,
sidebar, footer) stays in step with the rest of the site rather than being
frozen at whenever this script was written.

Usage:
    tools/gen-release-html.py [--version X.Y.Z] [--template PATH] [--out PATH]
                              [--title TEXT] [--status TEXT]

Defaults: version from builder/build-iso.sh, template from the newest existing
releases/*.html, output to ../kldload-web/releases/<version>.html.

Exit: 0 written, 1 something was missing, 2 usage.
"""
from __future__ import annotations

import argparse
import html
import io
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))


def read_version() -> str:
    src = io.open(os.path.join(REPO, "builder/build-iso.sh"), encoding="utf-8").read()
    m = re.search(r'^VERSION="\$\{KLDLOAD_VERSION:-(.*)\}"$', src, re.M)
    if not m:
        raise SystemExit("could not read VERSION from builder/build-iso.sh")
    return m.group(1)


def changelog_section(version: str) -> tuple[str, str]:
    """Return (heading_line, body) for the newest section, asserting its version."""
    src = io.open(os.path.join(REPO, "CHANGELOG.md"), encoding="utf-8").read()
    m = re.search(r"^## (\S+) — (.+?)$(.*?)(?=^## )", src, re.S | re.M)
    if not m:
        raise SystemExit("no dated '## <version> — <date>' section in CHANGELOG.md")
    if m.group(1) != version:
        raise SystemExit(
            "CHANGELOG.md's newest section is %s but build-iso.sh says %s"
            % (m.group(1), version)
        )
    return m.group(2), m.group(3)


def inline(t: str) -> str:
    t = html.escape(t)
    t = re.sub(r"`([^`]+)`", r"<code>\1</code>", t)
    t = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", t)
    t = re.sub(r"(?<![\w*])\*([^*]+)\*(?![\w*])", r"<em>\1</em>", t)
    t = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', t)
    return t


def slug(t: str) -> str:
    t = re.sub(r"[^\w\s-]", "", t.lower())
    return re.sub(r"\s+", "-", t.strip())


def render_body(md: str) -> str:
    out: list[str] = []
    para: list[str] = []
    tbl: list[str] = []
    code: list[str] = []
    listmode: str | None = None
    incode = False

    def flush_para() -> None:
        if para:
            out.append('<p class="prose">' + inline(" ".join(para)) + "</p>")
            para.clear()

    def close_list() -> None:
        nonlocal listmode
        if listmode:
            out.append("</ol>" if listmode == "ol" else "</ul>")
            listmode = None

    def flush_tbl() -> None:
        if not tbl:
            return
        rows = [r for r in tbl if not re.match(r"^\|[\s:|-]+\|$", r)]
        buf = ['<table class="release-table">']
        for i, r in enumerate(rows):
            cells = [c.strip() for c in r.strip().strip("|").split("|")]
            tag = "th" if i == 0 else "td"
            buf.append(
                "<tr>" + "".join("<%s>%s</%s>" % (tag, inline(c), tag) for c in cells) + "</tr>"
            )
        buf.append("</table>")
        out.append("\n".join(buf))
        tbl.clear()

    for line in md.split("\n"):
        st = line.strip()
        if st.startswith("```"):
            if incode:
                out.append("<pre><code>" + html.escape("\n".join(code)) + "</code></pre>")
                code.clear()
                incode = False
            else:
                flush_para()
                flush_tbl()
                close_list()
                incode = True
            continue
        if incode:
            code.append(line)
            continue
        if st.startswith("|") and st.endswith("|"):
            flush_para()
            close_list()
            tbl.append(st)
            continue
        flush_tbl()
        if st.startswith("### "):
            flush_para()
            close_list()
            out.append('<h3 id="%s">%s</h3>' % (slug(st[4:]), inline(st[4:])))
        elif st == "---":
            flush_para()
            close_list()
            out.append("<hr>")
        elif re.match(r"^\d+\. ", st):
            flush_para()
            if listmode != "ol":
                close_list()
                out.append('<ol class="release-toc">')
                listmode = "ol"
            out.append("<li>" + inline(re.sub(r"^\d+\. ", "", st)) + "</li>")
        elif st.startswith("- "):
            flush_para()
            if listmode != "ul":
                close_list()
                out.append("<ul>")
                listmode = "ul"
            out.append("<li>" + inline(st[2:]) + "</li>")
        elif st == "":
            flush_para()
            close_list()
        else:
            if listmode and line.startswith("  "):
                out[-1] = out[-1][:-5] + " " + inline(st) + "</li>"
            else:
                para.append(st)
    flush_para()
    flush_tbl()
    close_list()
    return "\n".join(out)


def iso_sha(version: str, suffix: str) -> str | None:
    """First 12 hex of the built ISO's sha256 sidecar, when one exists."""
    name = "kldload-%s-x86_64%s.iso" % (version, suffix)
    for cand in (
        os.path.join(REPO, "live-build/output", name + ".sha256"),
        os.path.join(REPO, "live-build/output", name + ".sha256sum"),
    ):
        if os.path.exists(cand):
            txt = io.open(cand, encoding="utf-8").read().split()
            if txt:
                return txt[0][:12]
    return None


def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--version")
    ap.add_argument("--template")
    ap.add_argument("--out")
    ap.add_argument("--title", default="")
    ap.add_argument("--status", default="")
    a = ap.parse_args()

    version = a.version or read_version()
    web = os.environ.get("KLDLOAD_WEB") or os.path.join(os.path.dirname(REPO), "kldload-web")
    if not os.path.isdir(web):
        print("website checkout not found: %s (set KLDLOAD_WEB)" % web, file=sys.stderr)
        return 1

    template = a.template
    if not template:
        out_name = "%s.html" % version
        rel = sorted(
            (
                f
                for f in os.listdir(os.path.join(web, "releases"))
                if f.endswith(".html") and f != out_name
            ),
            key=lambda f: [int(x) for x in re.findall(r"\d+", f)] or [0],
        )
        if not rel:
            print("no existing release page to use as a template", file=sys.stderr)
            return 1
        template = os.path.join(web, "releases", rel[-1])
    shell = io.open(template, encoding="utf-8").read()

    date, body = changelog_section(version)
    title = a.title or "kldload %s" % version
    status = a.status or ("release candidate" if "-rc" in version else "released")

    meta = [
        "<span>Status:</span> %s &nbsp;&middot;&nbsp;" % html.escape(status),
        "<span>Date:</span> %s &nbsp;&middot;&nbsp;" % html.escape(date),
        "<span>License:</span> BSD-3-Clause<br>",
    ]
    dls = [
        ("kldload-free-latest.iso", "", "offline"),
        ("kldload-free-net-latest.iso", "-net", "net installer"),
        ("kldload-free-core-latest.iso", "-core", "substrate only"),
        ("kldload-free-fedora-latest.iso", "-fedora", "Fedora only"),
    ]
    meta.append("<span>Download:</span> ")
    parts = []
    for key, suffix, what in dls:
        sha = iso_sha(version, suffix)
        parts.append(
            '<a href="https://dl.kldload.com/%s" style="color:var(--accent)">%s</a> (%s%s)'
            % (key, key, what, (", <code>%s&hellip;</code>" % sha) if sha else "")
        )
    meta.append(" &nbsp;&middot;&nbsp; ".join(parts))

    section = """
      <section>
        <div class="section-label">Releases</div>
        <h2 style="border:none">%s</h2>

        <div class="release-meta">
          %s
        </div>

%s

        <p class="prose" style="margin-top:2rem">Full detail in
        <a href="https://github.com/kldload/kldload/blob/v%s/CHANGELOG.md"
           style="color:var(--accent2)">CHANGELOG.md</a> at the tag.</p>
      </section>
""" % (html.escape(title), "\n          ".join(meta), body_indent(render_body(body)), version)

    # Match on CONTENT, never on leading whitespace: the template indents
    # <section> with four spaces and an earlier version of this line assumed
    # six, so it silently matched nothing and wrote no page.
    # re.subn, not `new == shell`: when the template IS the previous run's
    # output, a correct substitution produces an identical string, and an
    # equality test then reports "no match" on a working regeneration. Count
    # the substitutions instead of guessing from the result.
    new, nsub = re.subn(
        r"\n[ \t]*<section>.*?</section>\n", section, shell, count=1, flags=re.S
    )
    if nsub != 1:
        print("could not find the <section> block in the template", file=sys.stderr)
        return 1
    # The generated body uses two classes the template's own <style> does not
    # define, because no hand-written release page has had a table or a
    # contents list. Ship them with the page rather than editing site.css,
    # which every other page also loads.
    extra_css = """
.release-table { border-collapse: collapse; width: 100%; margin: 0 0 1.4rem; font-size: 0.85rem; }
.release-table th { text-align: left; color: var(--bright); border-bottom: 1px solid var(--border); padding: 0.5rem 0.7rem; font-weight: 600; }
.release-table td { border-bottom: 1px solid var(--border); padding: 0.5rem 0.7rem; color: var(--subtle); vertical-align: top; }
.release-toc { padding-left: 1.4rem; margin: 0 0 1.6rem; font-size: 0.9rem; color: var(--subtle); }
.release-toc li { margin-bottom: 0.3rem; }
.release-toc a { color: var(--accent2); text-decoration: none; }
.release-toc a:hover { text-decoration: underline; }
"""
    new = new.replace("  </style>", extra_css + "  </style>", 1)
    new = re.sub(r"<title>[^<]*</title>", "<title>%s</title>" % html.escape(title), new, count=1)
    new = re.sub(
        r'<meta property="og:title" content="[^"]*"/>',
        '<meta property="og:title" content="%s Release Notes"/>' % html.escape(title),
        new,
        count=1,
    )
    new = re.sub(
        r'<meta property="og:url" content="[^"]*"/>',
        '<meta property="og:url" content="https://kldload.com/releases/%s.html"/>' % version,
        new,
        count=1,
    )

    out = a.out or os.path.join(web, "releases", "%s.html" % version)
    io.open(out, "w", encoding="utf-8").write(new)
    n = len(re.findall(r"<h3 ", new))
    print("gen-release-html: %s — %d sections, %d bytes" % (out, n, len(new)))
    return 0


def body_indent(s: str) -> str:
    return "\n".join(("        " + ln) if ln else ln for ln in s.split("\n"))


if __name__ == "__main__":
    sys.exit(main())
