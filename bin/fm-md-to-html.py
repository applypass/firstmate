#!/usr/bin/env python3
"""fm-md-to-html.py - render a Markdown file to one self-contained HTML page (applypass fork).

Usage: fm-md-to-html.py <in.md> <out.html>

Used by bin/fm-shortcut-ticket.sh so an uploaded report opens readable in a
browser (Shortcut serves .md attachments as text/html, which collapses them).
GFM tables, strikethrough, headings, lists, links and fenced code render;
raw HTML in the source is escaped, never passed through, and the page carries
inline CSS only: no script, font, or other external resource. Needs the
markdown-it-py package; exits 2 with a one-line reason when it is missing.
"""
import html
import os
import sys

CSS = """
:root{color-scheme:light dark;--bg:#fff;--fg:#1f2328;--muted:#59636e;--line:#d1d9e0;--code:#f6f8fa;--link:#0969da}
@media(prefers-color-scheme:dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#9198a1;--line:#3d444d;--code:#151b23;--link:#4493f8}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif}
main{max-width:860px;margin:0 auto;padding:24px 16px 64px;overflow-wrap:break-word}
h1,h2,h3,h4,h5,h6{line-height:1.25;margin:1.6em 0 .6em}
h1,h2{padding-bottom:.3em;border-bottom:1px solid var(--line)}
h1{font-size:1.9em}h2{font-size:1.5em}h3{font-size:1.25em}
a{color:var(--link)}
p,ul,ol,blockquote,pre,.table-wrap{margin:0 0 1em}
ul,ol{padding-left:2em}
blockquote{margin-left:0;padding:0 1em;color:var(--muted);border-left:.25em solid var(--line)}
code{font:.9em ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;background:var(--code);padding:.15em .35em;border-radius:4px}
pre{background:var(--code);padding:12px 16px;border-radius:6px;overflow-x:auto;line-height:1.45}
pre code{background:none;padding:0;font-size:.875em}
.table-wrap{overflow-x:auto}
table{border-collapse:collapse;min-width:100%}
th,td{border:1px solid var(--line);padding:6px 12px;text-align:left;vertical-align:top}
th{background:var(--code)}
tr:nth-child(even) td{background:var(--code)}
hr{border:0;border-top:1px solid var(--line);margin:1.5em 0}
img{max-width:100%}
"""


def main(argv):
    if len(argv) != 3:
        print("usage: fm-md-to-html.py <in.md> <out.html>", file=sys.stderr)
        return 64
    try:
        from markdown_it import MarkdownIt
    except ImportError:
        print("the markdown-it-py package is not installed for " + sys.executable, file=sys.stderr)
        return 2
    src, dst = argv[1], argv[2]
    with open(src, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    # html=False escapes raw HTML; markdown-it also refuses javascript: and similar link targets.
    md = MarkdownIt("commonmark", {"html": False, "linkify": False}).enable(["table", "strikethrough"])
    body = md.render(text)
    body = body.replace("<table>", '<div class="table-wrap"><table>').replace("</table>", "</table></div>")
    title = html.escape(os.path.basename(src))
    page = (
        '<!doctype html>\n<html lang="en"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        "<title>%s</title><style>%s</style></head><body><main>\n%s</main></body></html>\n"
    ) % (title, CSS, body)
    with open(dst, "w", encoding="utf-8") as fh:
        fh.write(page)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
