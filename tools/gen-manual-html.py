#!/usr/bin/env python3
"""Generate the website's Manual section: tools/gen-manual-html.py [--web DIR] [--check]

What it does, in order:
  1. renders docs/INSTALL.md into manual/install.html -- `##` sections and
     `###` subsections, ids equal to the anchors the guide's Contents links to;
  2. writes the section landing page, manual/index.html, whose card grid is
     filled by sidebar.js from the MANUAL entry of SECTIONS;
  3. with --help-dir (the output of tools/cmdref/capture-help.sh), writes the
     command reference, manual/commands.html: every shipped tool grouped by
     area, each with the --help it printed in a sealed container, and a
     closing section naming the tools that did not answer --help and how;
  4. renders every man page in the tree (mandoc -T html) to
     manual/man-<name>.html, cross-references linked where the page exists;
  5. wraps each in the site's chrome (tools/sitechrome.py) and asserts every
     page landed with the section count its source has.

Why: the website had no install page (one sentence on download.html) while
docs/INSTALL.md, checked against the installer source, sat in the repo. The
markdown is the source of truth and the pages are build artifacts, the same
arrangement that stopped the FAQ drifting (tools/gen-faq-html.py). The
operator asked for the manual as its own top-bar section, between Tutorials
and ZFS (2026-09-29); the nav entry itself lives in the website's sidebar.js.

Inputs:  docs/INSTALL.md; <web>/reference/glossary.html as the chrome template;
         --help-dir DIR (tools.tsv + <tool>.help, from capture-help.sh);
         the man pages (usr/local/share/man/man8/*.8, kld/wg/ztxplore docs).
Outputs: <web>/manual/{index,install,commands}.html, <web>/manual/man-*.html.
Exit: 0 written (or, with --check, all current), 1 out of date or an input is
      missing, 2 usage.
"""
import argparse
import html
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from sitechrome import page  # noqa: E402
from sitemd import inline, render_body, slug  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent


def render_guide(md: str, label: str, title: str) -> tuple[str, int]:
    """A markdown guide -> section HTML, and its number of `##` sections."""
    # A `---` between sections is a rule the site already draws above every
    # section heading; kept, it drew two (first render, 2026-09-29).
    lines = [ln for ln in md.splitlines() if ln.strip() != "---"]
    i, n = 0, len(lines)
    intro: list[str] = []
    while i < n and not lines[i].startswith("## "):
        if not lines[i].startswith("# "):
            intro.append(lines[i])
        i += 1
    out = ["<section>", f'<div class="section-label">{label}</div>',
           f'<h1 id="{slug(title)}">{inline(title)}</h1>']
    out += [b.replace("<p", '<p class="prose"', 1) if b.startswith("<p") else b
            for b in render_body(intro)]
    sections = 0
    while i < n:
        line = lines[i]
        if line.startswith(("## ", "### ")):
            level = 2 if line.startswith("## ") else 3
            head = line[level + 1:].strip()
            sections += level == 2
            out.append(f'<h{level} id="{slug(head)}">{inline(head)}</h{level}>')
            i += 1
            body: list[str] = []
            while i < n and not lines[i].startswith(("## ", "### ")):
                body.append(lines[i])
                i += 1
            out += render_body(body)
        else:
            i += 1
    out.append("</section>")
    return "\n      ".join(out), sections


LANDING = """<section>
      <div class="section-label">Manual</div>
      <h1 id="manual">The kldload Manual</h1>
      <p class="prose">How to install kldload and run what it installs. Every
      command shown here was run on a real machine and every output was printed
      by one; where nothing was captured, the page shows the command and says
      so.</p>
      <div class="kld-auto-index" data-section="MANUAL"></div>
    </section>"""


CHROOT = "live-build/config/includes.chroot"
MANPAGES = [f"{CHROOT}/usr/local/share/man/man8/*.8", "kld/docs/*.1", "wg/docs/*.1",
            "ztxplore/docs/*.1"]

# Areas, first match wins. A name is an operator's way into the reference, so
# the areas follow what an operator is doing, not where the file lives.
AREAS: list[tuple[str, str]] = [
    ("Virtual machines", r"^kvm-|^kclone$|^kldload-vm-"),
    ("Golden images and labs", r"^klab|^kzfs-|^kimage$|^kldload-seal$|^kldload-rhel-composer"),
    ("MicroVMs and containers", r"^kfire|^kspawn$|^kpkg$"),
    ("Kubernetes", r"^kube-"),
    ("Storage, snapshots and rollback",
     r"^ksnap$|^kst|^kdf$|^kexport$|^kldload-zfs|^kldload-rollback$|^rollback$|^snapshot-|"
     r"^kldload-backup|^kldload-snapshot$|^zexplore|^kdir$"),
    ("Network and mesh", r"^kldload-networks$|^kvm-mesh$|^wg|^kldload-proxy$|^kldload-tls|"
     r"^kldload-ca$|^kldload-trust-cert$"),
    ("Estate, inventory and automation", r"^kldload-(estate|db|inventory|enroll|collect|follow)"),
    ("Provisioning, install and power", r"^kldload-(netboot|power|install|autoinstall|restore|"
     r"recovery|secure-boot|mok|boot-|firstboot|autodeploy|apply-|restamp|wait-for)"),
    ("Health and diagnostics", r"^kldload-(doctor|test|obs-check|debug|sysdiag|journal|hba|"
     r"io-scheduler)|^klab-vm-debug"),
    ("Consoles and desktop", r"^kldload-(webui|webview|console|command-center|overview|session|"
     r"term|dashboard|chrome|mgmt|help|tty1|install-kiosk|build-monitor)|^kst-dashboard$"),
    ("Services and internal helpers", r"."),
]
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def area_of(name: str) -> str:
    for label, rx in AREAS:
        if re.search(rx, name):
            return label
    return AREAS[-1][0]


def man_pages() -> dict[str, pathlib.Path]:
    """name -> source for every man page in the tree."""
    out: dict[str, pathlib.Path] = {}
    for g in MANPAGES:
        for f in sorted(ROOT.glob(g)):
            out[f.stem] = f
    return out


def render_man(src: pathlib.Path, names: set[str]) -> str:
    """One man page -> an HTML fragment; .Xr links only to pages that exist."""
    frag = subprocess.run(["mandoc", "-T", "html", "-O", "fragment,man=man-%N.html", str(src)],
                          check=True, capture_output=True, text=True).stdout

    def xr(m: "re.Match[str]") -> str:
        target, text = m.group(1), m.group(2)
        if target in names:
            return f'<a class="Xr" href="man-{target}.html">{text}</a>'
        return f'<span class="Xr">{text}</span>'
    # names may carry dots (zfs-tests.sh): match up to the quote, not the first dot
    return re.sub(r'<a class="Xr" href="man-([^"]+?)\.html">(.*?)</a>', xr, frag)


def read_capture(helpdir: pathlib.Path) -> list[dict[str, str]]:
    rows = []
    lines = (helpdir / "tools.tsv").read_text(encoding="utf-8").splitlines()
    head = lines[0].split("\t")
    for ln in lines[1:]:
        r = dict(zip(head, ln.split("\t")))
        f = helpdir / f"{r['name']}.help"
        txt = f.read_text(encoding="utf-8", errors="replace") if f.is_file() else ""
        txt = ANSI.sub("", txt).replace("/w/" + CHROOT, "")
        r["text"] = txt.rstrip()
        r["answered"] = "1" if r["rc"] == "0" and r["sudo"] == "0" and txt.strip() else "0"
        rows.append(r)
    return rows


def why_not(r: dict[str, str]) -> str:
    rc = r["rc"]
    if rc == "-":
        return "a compiled binary: not run"
    if r["sudo"] == "1":
        return "reached for root to print help"
    if rc == "124":
        return "did not return within 10 s: it started working instead of helping"
    if rc == "127":
        return "exec'd a program that is not there"
    if rc == "0":
        return "exited 0 and printed nothing"
    if rc == "2" and r["text"]:
        return "printed a usage text but exited 2, as if --help were an error"
    return f"exited {rc}" + (": " + html.escape(r["text"].splitlines()[-1][:110])
                              if r["text"] else " and printed nothing")


def commands_page(rows: list[dict[str, str]], mans: dict[str, pathlib.Path], when: str) -> str:
    ok = [r for r in rows if r["answered"] == "1"]
    no = [r for r in rows if r["answered"] != "1"]
    by: dict[str, list[dict[str, str]]] = {}
    for r in ok:
        by.setdefault(area_of(r["name"]), []).append(r)
    order = [a for a, _ in AREAS if a in by]
    out = ["<section>", '<div class="section-label">Manual</div>',
           '<h1 id="command-reference">Command Reference</h1>',
           f'<p class="prose">Every command kldload ships, with the <code>--help</code> it prints. '
           f"Each one was run with <code>--help</code> in a sealed container (no network, no "
           f"root, a ten-second limit) on {html.escape(when)}; what is shown is what it printed. "
           f"{len(ok)} of {len(rows)} answered; the rest are listed at the end with what happened "
           f"instead. Commands with a manual page link to it.</p>"]
    out.append("<ul>" + "".join(f'<li><a href="#{slug(a)}">{html.escape(a)}</a> '
                                  f"({len(by[a])})</li>" for a in order)
               + f'<li><a href="#no-help-yet">Without --help yet</a> ({len(no)})</li></ul>')
    if mans:
        out.append('<p class="prose">Manual pages: ' + ", ".join(
            f'<a href="man-{n}.html"><code>{html.escape(n)}({html.escape(f.suffix[1:])})</code></a>'
            for n, f in sorted(mans.items())) + ".</p>")
    for a in order:
        out.append(f'<h2 id="{slug(a)}">{html.escape(a)}</h2>')
        for r in sorted(by[a], key=lambda x: x["name"]):
            n = r["name"]
            man = (f' <a class="cmd-note" href="man-{n}.html">manual page</a>' if n in mans else "")
            out.append(f'<h3 id="cmd-{slug(n)}"><code>{html.escape(n)}</code>{man}</h3>')
            out.append(f'<pre class="help">{html.escape(r["text"])}</pre>')
    out.append('<h2 id="no-help-yet">Without --help yet</h2>')
    out.append('<p class="prose">These did not answer <code>--help</code> cleanly. Every tool '
               "should; each of these is a defect being worked through, not a hidden feature.</p>")
    out.append("<table><thead><tr><th>command</th><th>what happened</th></tr></thead><tbody>"
               + "".join(f"<tr><td><code>{html.escape(r['name'])}</code></td>"
                         f"<td>{why_not(r)}</td></tr>" for r in sorted(no, key=lambda x: x["name"]))
               + "</tbody></table>")
    out.append("</section>")
    return "\n      ".join(out)


def build(web: pathlib.Path, helpdir: "pathlib.Path | None" = None
          ) -> list[tuple[pathlib.Path, str, str, int]]:
    """Every page: (path, html, what-it-is, expected <h2> count)."""
    guide, sections = render_guide((ROOT / "docs" / "INSTALL.md").read_text(encoding="utf-8"),
                                   "Manual", "Install Guide")
    pages = [
        (web / "manual" / "index.html",
         page(web, "The kldload Manual", "Install kldload and run what it installs.", LANDING),
         "landing", 0),
        (web / "manual" / "install.html",
         page(web, "Install Guide",
              "Installing kldload: requirements, verifying the image, writing the USB, the "
              "installer's choices, Secure Boot enrollment, verifying and troubleshooting.",
              guide),
         "install guide", sections),
    ]
    if helpdir is None:
        print("gen-manual-html: no --help-dir: the command reference was NOT generated",
              file=sys.stderr)
        return pages
    mans = man_pages()
    rows = read_capture(helpdir)
    when = (helpdir / "tools.tsv").stat().st_mtime
    import datetime
    stamp = datetime.date.fromtimestamp(when).isoformat()
    body = commands_page(rows, mans, stamp)
    pages.append((web / "manual" / "commands.html",
                  page(web, "Command Reference",
                       "Every command kldload ships, with the --help it prints.", body),
                  "command reference", body.count("<h2 id=")))
    for n, f in sorted(mans.items()):
        frag = render_man(f, set(mans))
        pages.append((web / "manual" / f"man-{n}.html",
                      page(web, f"{n}({f.suffix[1:]})", f"The {n} manual page.",
                           '<section><div class="section-label">Manual page</div>'
                           f'<div class="manpage">{frag}</div></section>'),
                      f"man page {n}", 0))
    return pages


def main() -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("--web", default=str(ROOT.parent / "kldload-web"),
                    help="the website repo (default: ../kldload-web)")
    ap.add_argument("--check", action="store_true", help="report only; write nothing")
    ap.add_argument("--help-dir", help="capture-help.sh output (tools.tsv + <tool>.help)")
    a = ap.parse_args()
    web = pathlib.Path(a.web)
    for f in (ROOT / "docs" / "INSTALL.md", web / "reference" / "glossary.html"):
        if not f.is_file():
            print(f"gen-manual-html: no {f}", file=sys.stderr)
            return 1
    stale = 0
    helpdir = pathlib.Path(a.help_dir) if a.help_dir else None
    if helpdir and not (helpdir / "tools.tsv").is_file():
        print(f"gen-manual-html: no {helpdir}/tools.tsv", file=sys.stderr)
        return 1
    for path, text, what, h2 in build(web, helpdir):
        if a.check:
            if not path.is_file() or path.read_text(encoding="utf-8") != text:
                print(f"gen-manual-html: {path} is OUT OF DATE", file=sys.stderr)
                stale += 1
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        got = path.read_text(encoding="utf-8").count("<h2 id=")
        if got != h2:
            print(f"gen-manual-html: {path} has {got} sections, its source has {h2}",
                  file=sys.stderr)
            return 1
        print(f"gen-manual-html: {path.relative_to(web)}: {what}, {h2} sections")
    if a.check:
        print("gen-manual-html: " + ("all current" if not stale else f"{stale} out of date"))
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
