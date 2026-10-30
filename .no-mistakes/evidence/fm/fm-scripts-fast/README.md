# Live timing of fm-wake-drain, fm-send and fm-decide: base 91e4d276 vs target fefed261

All runs used the real scripts from `git archive` copies of both commits, against
disposable lab homes (bin/fm-lab-home.sh) with a private tmux socket. Shortcut was
a local fake curl (decide-bench.sh), so nothing reached the network.

## fm-wake-drain, warm (7 interleaved runs, load ~4-5): drain-warm-stats.txt
| home          | base median | target median |
|---------------|-------------|---------------|
| 4 mates x 2500 lines | 1.59 s | 1.26 s |
| 6 mates x 400 lines  | 1.99 s | 1.55 s |
| 8 mates x 60 lines   | 2.42 s | 1.61 s |
Output is byte-identical between base and target on every run (drain-cold-quiet.txt, drain-summary.txt).
Under heavier load (~9.5) target medians were 2.5-3.8 s against base 4.4-5.3 s (drain-warm-cpu.txt).

## fm-wake-drain, unread span (first drain after 2500 new lines per mate)
4x2500: base 34.1 s, target 23.2 s; 6x400: base 8.0 s, target 6.3 s. Profile: drain-cold-profile.txt
(upstream bash open-decision fold over the new lines dominates).

## fm-send (real tmux pane, 2500-line log): send-summary.txt
--resolve-key: base 3.5-6.2 s, target 0.54-0.58 s. Plain steer: ~0.36 s vs ~0.41 s (path unchanged).
Closing an already-closed key is refused on both (send-target-closed.out).

## fm-decide (fake Shortcut answers after 3 s per call): decide-summary.txt
record --story: base 4.7 s, target 0.56 s; record without story: base 6.4 s, target 0.05 s.
Background job stamps sc-6523 and files chore sc-7777; a final failure leaves the entry
pending and queues a note for main; two concurrent syncs post one comment.
