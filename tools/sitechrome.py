"""Site chrome for generated website pages: head, topbar and footer.

The chrome is lifted from a page one directory deep (reference/glossary.html)
at generation time, so a generated page follows the site when its topbar,
footer or asset versions change -- nothing here is a copy that can go stale.
Only the <title>, the Open Graph title and description, and the per-page
<style> are replaced.

Used by tools/gen-manual-html.py. Pages it produces live one directory deep
(manual/...), which is what the template's ../ paths assume.
"""
import html
import pathlib
import re

TEMPLATE = "reference/glossary.html"

# The generated pages' own styles. site.css carries the site's typography; this
# only styles what the markdown renderer emits that site.css does not expect
# inside a plain section (tables, quotes, a --help block).
STYLE = """
.page-view { display: block; padding-top: 1.5rem; }
.prose { font-size: 0.95rem; line-height: 1.85; color: var(--subtle); max-width: 780px; }
main.content section p, main.content section li { max-width: 780px; line-height: 1.8; }
main.content section table { border-collapse: collapse; margin: 1rem 0; font-size: 0.88rem; }
main.content section th, main.content section td { border: 1px solid var(--border); padding: 0.35rem 0.7rem; text-align: left; vertical-align: top; }
main.content section blockquote { border-left: 3px solid var(--accent); margin: 1rem 0; padding: 0.2rem 1rem; background: rgba(0,184,217,0.04); }
main.content section hr { border: none; border-top: 1px solid var(--border); margin: 2rem 0; }
pre.help { white-space: pre-wrap; font-size: 0.82rem; line-height: 1.5; background: var(--bg2); border: 1px solid var(--border); border-radius: 6px; padding: 1rem; overflow-x: auto; }
.cmd-note { font-size: 0.85rem; color: var(--orange); }
"""


def page(web: pathlib.Path, title: str, description: str, body: str) -> str:
    """A complete depth-1 page: the template's chrome around `body`."""
    tpl = (web / TEMPLATE).read_text(encoding="utf-8")
    m_main = re.search(r'<main class="content">', tpl)
    m_end = tpl.rfind("</main>")
    if not m_main or m_end < 0:
        raise SystemExit(f"sitechrome: {TEMPLATE} has no <main class=\"content\"> ... </main>")
    head, tail = tpl[:m_main.end()], tpl[m_end:]
    t = html.escape(title)
    d = html.escape(description, quote=True)
    head = re.sub(r"<title>.*?</title>", f"<title>{t} &mdash; kldload</title>", head,
                  count=1, flags=re.S)
    head = re.sub(r'(<meta property="og:title" content=")[^"]*"', rf'\g<1>{t} — kldload"',
                  head, count=1)
    head = re.sub(r'(<meta property="og:description" content=")[^"]*"', rf'\g<1>{d}"',
                  head, count=1)
    head = re.sub(r"<style>.*?</style>", "<style>" + STYLE + "</style>", head, count=1, flags=re.S)
    return (f"{head}\n    <div class=\"page-view active\">\n      {body}\n    </div>\n  {tail}")
