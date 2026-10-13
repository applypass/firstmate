# Review report: sc-6836 upload rendering

Summary of the **review** for `fm/fm-md-html-upload`. See [the PR](https://github.com/applypass/firstmate/pull/36).

## Findings

| # | Severity | File | Finding | Action |
|---|----------|------|---------|--------|
| 1 | warning | `tests/fm-shortcut-ticket.test.sh:452` | Two-upload assertion ran before the markdown-it-py importability guard, so CI without the package would fail | auto-fix |
| 2 | info | `bin/fm-md-to-html.py` | Raw HTML is escaped, never passed through | no-op |
| 3 | info | `bin/fm-shortcut-ticket.sh:340` | A failed render still uploads the `.md` with a warning | no-op |

## Checks

- [x] GFM tables render
- ~~old behaviour~~ replaced
- Nested list:
  1. first
  2. second

> Shortcut serves `.md` attachments as `text/html`, so the browser collapses them into one paragraph.

```bash
bin/fm-shortcut-ticket.sh attach sc-6836 report.md
# uploads report.md and report.html
```

### A wide table

| Column one | Column two | Column three | Column four | Column five | Column six | Column seven |
|---|---|---|---|---|---|---|
| a long cell value here | another long value | yet another value | more text here | and more | and more again | last |

<script>alert('xss')</script>
<img src=x onerror=alert(1)>
[bad link](javascript:alert(1))
