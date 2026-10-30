import sys,re,collections
pat=re.compile(r'^\++(\d+\.\d+) (\d+) (\S+?):(\d+):(\S+) ?(.*)')
by=collections.defaultdict(list)
for l in open(sys.argv[1],errors='replace'):
    m=pat.match(l)
    if m: by[m.group(2)].append((float(m.group(1)),m.group(3)+':'+m.group(4),m.group(3)+':'+m.group(5),m.group(6).split(' ')[0]))
byline=collections.Counter(); byfn=collections.Counter(); bycmd=collections.Counter(); byscript=collections.Counter()
t0=min(r[0][0] for r in by.values()); t1=max(r[-1][0] for r in by.values())
print('wall span',round(t1-t0,2),'pids',len(by))
for pid,rows in by.items():
    for a,b in zip(rows,rows[1:]):
        d=b[0]-a[0]; byline[a[1]]+=d; byfn[a[2]]+=d; bycmd[a[3].rsplit('/',1)[-1]]+=d; byscript[a[1].split(':')[0]]+=d
for name,c in (('script',byscript),('func',byfn),('line',byline),('cmd',bycmd)):
    print('--',name)
    for k,v in c.most_common(10): print(f'{v:7.2f} {k}')
