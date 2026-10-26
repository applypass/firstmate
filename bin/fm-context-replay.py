#!/usr/bin/env python3
"""Fork-only (applypass): replay supervisor sessions with a context limit.

Usage: fm-context-replay.py <utc-date-prefix[,prefix...]> [--limit N] [--start N] [--homes FRAGMENT] [--root DIR]...

Reads Claude transcripts the way data/quota-waste-reduction/usage.py does
(weights: input 1, output 5, cache read 0.1, cache write 1.25) and, for each
supervisor session (the main firstmate and every second mate home), replays it
as if the session had been handed over to a fresh one each time its context
reached the limit (default 150000 tokens).

Model of the replay, kept simple on purpose:
  - the context of call j is input + cache read + cache creation tokens;
  - a fresh session starts at --start tokens (default 78000: the median
    first-call context of the fresh second-mate sessions, measured 2026-10-26;
    the main supervisor starts near 90000);
  - the simulated context grows by the same step as the real one between calls
    and never exceeds it (a real compaction lowers both), so after a handover
    the cache read of every call shrinks by the difference;
  - each handover pays one cache write of the start-up context.
It does not model waiting for an idle moment, so it is a best case for the
handover timing; the sweep defers a restart while a request is open.
"""
import glob
import json
import os
import sys
import time
from collections import defaultdict

W_IN, W_OUT, W_CR, W_CW = 1.0, 5.0, 0.1, 1.25
# Second-mate homes live under <treehouse pool>/<n>/firstmate; override with --homes.
HOMES_FRAGMENT = "firstmate-8fd6a9"


def category(proj):
    if proj.endswith("workspace-firstmate"):
        return "main supervisor"
    if HOMES_FRAGMENT in proj and proj.endswith("-firstmate"):
        return "second-mate homes"
    return None


def load(roots, days):
    seen = set()
    skipped = 0
    sessions = defaultdict(list)  # (category, file) -> [(ts, i, o, cr, cw)]
    for root in roots:
        for path in glob.glob(root + "/**/*.jsonl", recursive=True):
            if time.time() - os.path.getmtime(path) > 3 * 86400:
                skipped += 1
                continue
            proj = path[len(root) + 1:].split("/")[0]
            cat = category(proj)
            if cat is None or "/subagents/" in path:
                continue
            with open(path, errors="ignore") as fh:
                for line in fh:
                    try:
                        d = json.loads(line)
                    except ValueError:
                        continue
                    ts = d.get("timestamp", "")
                    if not any(ts.startswith(x) for x in days):
                        continue
                    m = d.get("message")
                    u = m.get("usage") if isinstance(m, dict) else None
                    if not u:
                        continue
                    key = (m.get("id"), d.get("requestId"))
                    if key in seen:
                        continue
                    seen.add(key)
                    sessions[(cat, path)].append((
                        ts, u.get("input_tokens", 0), u.get("output_tokens", 0),
                        u.get("cache_read_input_tokens", 0),
                        u.get("cache_creation_input_tokens", 0)))
    if skipped:
        print(f"warning: skipped {skipped} transcripts last modified over 3 days ago; "
              "totals for older dates are partial", file=sys.stderr)
    return sessions


def replay(calls, limit, start):
    """Return (weighted_before, weighted_after, handovers, ctx_before_sum, ctx_after_sum)."""
    calls.sort()
    ctxs = [c[1] + c[3] + c[4] for c in calls]
    before = after = 0.0
    handovers = 0
    ctx_b = ctx_a = 0
    sim = prev = ctxs[0]
    for (_, i, o, cr, cw), ctx in zip(calls, ctxs):
        cost = i * W_IN + o * W_OUT + cr * W_CR + cw * W_CW
        before += cost
        ctx_b += ctx
        sim = max(min(sim + (ctx - prev), ctx), min(start, ctx))
        prev = ctx
        if sim >= limit:
            handovers += 1
            sim = start
            cost += start * W_CW
        after += cost - max(ctx - sim, 0) * W_CR
        ctx_a += sim
    return before, after, handovers, ctx_b, ctx_a


def main(argv):
    days, limit, start, roots = None, 150000, 78000, []
    args = list(argv)
    while args:
        a = args.pop(0)
        if a == "--limit":
            limit = int(args.pop(0))
        elif a == "--start":
            start = int(args.pop(0))
        elif a == "--homes":
            global HOMES_FRAGMENT
            HOMES_FRAGMENT = args.pop(0)
        elif a == "--root":
            roots.append(args.pop(0))
        elif days is None:
            days = a.split(",")
        else:
            sys.exit(__doc__)
    if not days:
        sys.exit(__doc__)
    roots = roots or [os.path.expanduser("~/.claude-work/projects"),
                      os.path.expanduser("~/.claude/projects")]
    sessions = load(roots, days)
    agg = defaultdict(lambda: [0, 0.0, 0.0, 0, 0, 0])
    for (cat, _), calls in sessions.items():
        b, a, h, cb, ca = replay(calls, limit, start)
        r = agg[cat]
        r[0] += len(calls)
        r[1] += b
        r[2] += a
        r[3] += h
        r[4] += cb
        r[5] += ca
    print(f"days={','.join(days)} limit={limit} start={start}")
    print(f"{'category':18} {'calls':>6} {'ctx/call before':>16} {'ctx/call after':>15} "
          f"{'weighted M before':>18} {'after':>8} {'saved':>6} {'handovers':>10}")
    for cat in sorted(agg):
        n, b, a, h, cb, ca = agg[cat]
        print(f"{cat:18} {n:6d} {cb // max(n, 1):16d} {ca // max(n, 1):15d} "
              f"{b / 1e6:18.1f} {a / 1e6:8.1f} {100 * (1 - a / b) if b else 0:5.1f}% {h:10d}")


if __name__ == "__main__":
    main(sys.argv[1:])
