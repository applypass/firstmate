#!/usr/bin/env python3
"""Fork-only: reply latency of the main firstmate, per captain message (applypass fork).

usage: fm-reply-latency.py <transcript.jsonl> [--since <ISO time|epoch>] [--json <out.json>]

The method of the 2026-10-30 latency report (an.py): a captain message is a
transcript record with origin.kind == "human" (a turn start) or a queued_command
attachment that is not a task notification (folded into a running turn). It
starts when it entered the queue, so time stuck behind another turn counts. The
reply is the last assistant text of the turn that handled it. Commands are the
tool calls between pick-up and that reply.

Prints the share of captain messages with more than 3 commands before the reply
(the budget bin/fm-reply-first.sh enforces) and the median and p90 wait, for all
messages and split by that share. --since keeps only messages that started at or
after the given time, so a transcript from before and after the hook can be
compared with one command each.
"""
import json, sys, re, collections, datetime as dt, statistics

args = sys.argv[1:]
since = None
json_out = None
path = None
i = 0
while i < len(args):
    if args[i] == '--since':
        v = args[i + 1]; i += 2
        since = float(v) if re.fullmatch(r'\d+(\.\d+)?', v) else dt.datetime.fromisoformat(v.replace('Z', '+00:00')).timestamp()
    elif args[i] == '--json':
        json_out = args[i + 1]; i += 2
    else:
        path = args[i]; i += 1
if path is None:
    sys.exit(__doc__)

def ts(s):
    return dt.datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp()

recs = []
for line in open(path):
    d = json.loads(line)
    if 'timestamp' in d and isinstance(d['timestamp'], str):
        d['_t'] = ts(d['timestamp'])
    recs.append(d)

def utext(d):
    ct = d.get('message', {}).get('content')
    if isinstance(ct, str):
        return ct
    if isinstance(ct, list):
        return ' '.join(x.get('text', '') for x in ct if isinstance(x, dict) and x.get('type') == 'text')
    return ''

def is_tool_result(d):
    ct = d.get('message', {}).get('content')
    return isinstance(ct, list) and any(isinstance(x, dict) and x.get('type') == 'tool_result' for x in ct)

def is_human(d):
    return (d.get('origin') or {}).get('kind') == 'human'

def tool_label(name, inp):
    if name == 'Bash':
        c = inp.get('command', '')
        m = re.findall(r'(fm-[a-z0-9-]+\.sh|psql-?\d*|gh-axi|gh |herdr|tasks-axi|lavish-axi|quota-axi|curl|git |python3?|sleep|op read|doctl|jq|grep|rg|cat|sed|ls|tail|head|find)', c)
        key = m[0].strip() if m else c.split()[0] if c.split() else 'bash'
        return 'Bash:' + key
    return name

# enqueue times by content
enq = collections.defaultdict(list)
for d in recs:
    if d.get('type') == 'queue-operation' and d.get('operation') == 'enqueue' and 'content' in d:
        enq[d['content']].append(d['_t'])

def arrival(content, t_proc):
    lst = enq.get(content) or []
    cands = [x for x in lst if x <= t_proc + 1]
    if cands:
        x = cands[-1] if len(cands) == 1 else min(cands, key=lambda v: t_proc - v)
        # prefer the earliest unconsumed enqueue
        lst.remove(x)
        return x
    return t_proc

human_enq = {}
import bisect
att = sorted(d['_t'] for d in recs if d.get('type') == 'attachment' and d['attachment'].get('type') == 'queued_command')
def is_abs(t):
    i = bisect.bisect_left(att, t - 0.01)
    return i < len(att) and abs(att[i] - t) < 0.01
pend = []
unmatched = 0
for d in recs:
    if d.get('type') == 'queue-operation' and d.get('operation') == 'enqueue' and not str(d.get('content') or '').startswith('<task'):
        if not is_abs(d['_t']):
            pend.append(d['_t'])
    if d.get('type') == 'user' and is_human(d):
        c = [x for x in pend if x <= d['_t'] + 0.01]
        human_enq[d['uuid']] = c[-1] if c else d['_t']
        unmatched += 0 if c else 1
        pend = []
print('pending left', len(pend), 'unmatched', unmatched, file=sys.stderr)
# build turns: split at turn_duration
turns = []
cur = []
for d in recs:
    cur.append(d)
    if d.get('type') == 'system' and d.get('subtype') == 'turn_duration':
        turns.append(cur); cur = []
if cur:
    turns.append(cur)

def starter(turn):
    for d in turn:
        if d.get('type') == 'user' and not is_tool_result(d) and not d.get('isMeta'):
            return d
    return None

def tkind(turn):
    s = starter(turn)
    if s is None:
        return 'none'
    if is_human(s):
        return 'captain'
    t = utext(s)
    if 'Stop hook feedback' in t:
        return 'wake'
    if '<task-notification' in t:
        return 'bgtask'
    return 'other'

# per-turn timeline analysis
def analyze(turn, t_from=None, t_to=None):
    """Attribute wall time between consecutive timestamped records in [t_from, t_to]."""
    ev = [d for d in turn if '_t' in d and d.get('type') in ('assistant', 'user', 'attachment', 'system')]
    out = collections.Counter()
    tools = collections.Counter(); tool_n = collections.Counter()
    pending = {}
    calls = []
    for d in ev:
        if d['type'] == 'assistant':
            for x in d['message']['content']:
                if x.get('type') == 'tool_use':
                    pending[x['id']] = (d['_t'], tool_label(x['name'], x.get('input', {})), x)
        elif d['type'] == 'user' and is_tool_result(d):
            for x in d['message']['content']:
                if x.get('type') == 'tool_result' and x.get('tool_use_id') in pending:
                    t0, lab, inp = pending.pop(x['tool_use_id'])
                    if t_from is not None and t0 < t_from: continue
                    if t_to is not None and t0 > t_to: continue
                    dur = d['_t'] - t0
                    tools[lab] += dur; tool_n[lab] += 1
                    calls.append((dur, lab, inp, t0, x.get('is_error')))
    prev = None
    for d in ev:
        t = d['_t']
        if t_from is not None and t < t_from:
            prev = d; continue
        if t_to is not None and t > t_to:
            break
        if prev is not None:
            gap = t - max(prev['_t'], t_from or 0)
            if d['type'] == 'assistant':
                out['model'] += gap
            elif d['type'] == 'user' and is_tool_result(d):
                out['tool'] += gap
            elif d['type'] == 'system' and d.get('subtype') == 'compact_boundary':
                out['compact'] += gap
            else:
                out['other'] += gap
        prev = d
    return out, tools, tool_n, calls

caps = []  # captain messages
for i, turn in enumerate(turns):
    k = tkind(turn)
    texts = [d for d in turn if d.get('type') == 'assistant' and any(x.get('type') == 'text' and x.get('text', '').strip() for x in d['message']['content'])]
    last_text = texts[-1]['_t'] if texts else None
    first_text = texts[0]['_t'] if texts else None
    msgs = []
    s = starter(turn)
    if k == 'captain':
        msgs.append(('direct', s['_t'], utext(s), s))
    for d in turn:
        if d.get('type') == 'attachment' and d['attachment'].get('type') == 'queued_command':
            p = d['attachment'].get('prompt')
            p = p if isinstance(p, str) else json.dumps(p)
            if p.lstrip().startswith('<task-notification'):
                continue
            msgs.append(('absorbed', d['_t'], p, d))
    for kind, tproc, text, d in msgs:
        t0 = human_enq.get(d.get('uuid'), tproc) if kind == 'direct' else tproc
        # reply = last text in this turn after tproc
        after = [x['_t'] for x in texts if x['_t'] >= tproc]
        reply = after[-1] if after else None
        first = after[0] if after else None
        caps.append(dict(turn=i, kind=kind, tkind=k, t0=t0, tproc=tproc, reply=reply, first=first, text=text, turn_end=turn[-1].get('_t')))

# blocked-behind wait: time from t0 to tproc, attributed to the turn(s) running in between
turn_spans = []
for i, turn in enumerate(turns):
    tt = [d['_t'] for d in turn if '_t' in d]
    if tt:
        turn_spans.append((min(tt), max(tt), i, tkind(turn)))

res = []
for c in caps:
    if c['reply'] is None:
        continue
    lat = c['reply'] - c['t0']
    wait = c['tproc'] - c['t0']
    out, tools, tool_n, calls = analyze(turns[c['turn']], c['tproc'], c['reply'])
    blockers = [s for s in turn_spans if s[1] > c['t0'] and s[0] < c['tproc'] and s[2] != c['turn']]
    blk_kind = collections.Counter()
    for s in blockers:
        blk_kind[s[3]] += min(s[1], c['tproc']) - max(s[0], c['t0'])
    # time in own turn before absorbing (absorbed msgs wait on current turn's tool/model work)
    if c['kind'] == 'absorbed':
        blk_kind['own-turn-before-absorb:' + c['tkind']] += c['tproc'] - max(c['t0'], min(d['_t'] for d in turns[c['turn']] if '_t' in d))
    ncalls = len(calls)
    res.append(dict(c, lat=lat, wait=wait, out=dict(out), tools=dict(tools), tool_n=dict(tool_n), ncalls=ncalls,
                    calls=sorted(calls, key=lambda x: -x[0])[:5], blk=dict(blk_kind)))

if since is not None:
    res = [r for r in res if r['t0'] >= since]

def pct(vals, q):
    s = sorted(vals)
    return s[min(len(s) - 1, int(round(q * (len(s) - 1))))] if s else 0.0

def show(label, rows):
    if not rows:
        print('%-22s n=0' % label); return
    lat = [r['lat'] for r in rows]
    print('%-22s n=%d  median wait %.0f s  p90 wait %.0f s  summed %.0f min' % (
        label, len(rows), statistics.median(lat), pct(lat, 0.9), sum(lat) / 60))

over = [r for r in res if r['ncalls'] > 3]
print('captain messages with a reply: %d' % len(res))
if res:
    print('more than 3 commands before the reply: %d of %d (%.0f%%)' % (len(over), len(res), 100.0 * len(over) / len(res)))
show('all', res)
show('more than 3 commands', over)
show('3 commands or fewer', [r for r in res if r['ncalls'] <= 3])
if json_out:
    json.dump({'res': res}, open(json_out, 'w'), default=str)
