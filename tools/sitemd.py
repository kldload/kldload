"""Shared markdown-subset renderer for the website generators.

Used by tools/gen-faq-html.py and tools/gen-install-html.py. One renderer, so a
fix to how code spans or tables render reaches every generated page at once
instead of drifting between copies.

The subset is deliberate: anything not handled is emitted as literal text,
which is loud, rather than silently dropped.
"""
import html
import re


def slug(text: str) -> str:
    """A stable anchor id: lower case, words joined by hyphens."""
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def inline(text: str) -> str:
    """Markdown inline spans -> HTML.

    Code spans are lifted out to placeholders FIRST and put back LAST, so their
    contents are never touched -- a `--flag` in backticks must not become an em
    dash. They are placeholders rather than finished HTML because bold wraps
    code often enough to matter: splitting on backticks and running the bold
    regex per fragment left `**`apt`, `dnf` ...**` with its literal asterisks on
    the page (caught in the first render, 2026-09-20).
    """
    spans: list[str] = []

    def stash(m: "re.Match[str]") -> str:
        spans.append(html.escape(m.group(1)))
        return f"\x00{len(spans) - 1}\x00"

    s = re.sub(r"`([^`]+)`", stash, text)
    s = html.escape(s)
    s = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"(?<![*\w])\*(?![*\s])(.+?)(?<![*\s])\*(?![*\w])", r"<em>\1</em>", s)
    s = re.sub(r"(?<!-)--(?!-)", "&mdash;", s)
    return re.sub(r"\x00(\d+)\x00", lambda m: f"<code>{spans[int(m.group(1))]}</code>", s)


def render_table(rows: list[str]) -> str:
    """A pipe table -> <table>. Row 1 is the header, row 2 the separator."""
    cells = [[c.strip() for c in r.strip().strip("|").split("|")] for r in rows]
    head, body = cells[0], cells[2:]
    out = ["<table>"]
    # a header of empty cells (`| | |`, a two-column key/value table) is not a
    # header: rendering it drew an empty bar across the top of the table
    if any(c for c in head):
        out.append("<thead><tr>")
        out += [f"<th>{inline(c)}</th>" for c in head]
        out.append("</tr></thead>")
    out.append("<tbody>")
    for row in body:
        out.append("<tr>" + "".join(f"<td>{inline(c)}</td>" for c in row) + "</tr>")
    out.append("</tbody></table>")
    return "".join(out)


def render_body(lines: list[str], first_margin: bool = False) -> list[str]:
    """One answer's lines -> its HTML blocks, in order."""
    out: list[str] = []
    i, n = 0, len(lines)
    while i < n:
        line = lines[i]
        if not line.strip():
            i += 1
            continue
        margin = ' style="margin-top:0.6rem"' if out or first_margin else ""
        if line.startswith("```"):
            code = []
            i += 1
            while i < n and not lines[i].startswith("```"):
                code.append(lines[i])
                i += 1
            i += 1
            out.append(f"<pre><code>{html.escape(chr(10).join(code))}</code></pre>")
        elif line.lstrip().startswith("|"):
            rows = []
            while i < n and lines[i].lstrip().startswith("|"):
                rows.append(lines[i])
                i += 1
            out.append(render_table(rows))
        elif line.strip() == "---":
            out.append("<hr/>")
            i += 1
        elif line.startswith("> ") or line == ">":
            quote = []
            while i < n and (lines[i].startswith("> ") or lines[i] == ">"):
                quote.append(lines[i][2:])
                i += 1
            out.append("<blockquote>" + "".join(render_body(quote)) + "</blockquote>")
        elif re.match(r"\s*\d+\. ", line):
            items = []
            while i < n and re.match(r"\s*\d+\. ", lines[i]):
                item = [re.sub(r"^\s*\d+\. ", "", lines[i])]
                i += 1
                while i < n and lines[i].startswith("   ") and not re.match(r"\s*\d+\. ", lines[i]):
                    item.append(lines[i].strip())
                    i += 1
                items.append(" ".join(item))
            out.append("<ol>" + "".join(f"<li>{inline(t)}</li>" for t in items) + "</ol>")
        elif line.lstrip().startswith("- "):
            items = []
            while i < n and lines[i].lstrip().startswith("- "):
                item = [lines[i].lstrip()[2:]]
                i += 1
                while i < n and lines[i].startswith("  ") \
                        and not lines[i].lstrip().startswith("- "):
                    item.append(lines[i].strip())
                    i += 1
                items.append(" ".join(item))
            out.append("<ul>" + "".join(f"<li>{inline(t)}</li>" for t in items) + "</ul>")
        else:
            para = []
            while i < n and lines[i].strip() and not lines[i].startswith(("```", "|", "- ", "> ")) \
                    and lines[i].strip() != "---" and not re.match(r"\s*\d+\. ", lines[i]):
                para.append(lines[i].strip())
                i += 1
            out.append(f"<p{margin}>{inline(' '.join(para))}</p>")
    return out
