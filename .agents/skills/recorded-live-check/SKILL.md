---
name: recorded-live-check
description: Load when briefing a worker to record a live UI check, and when reviewing a live-check recording (mp4 plus trace) before attaching it to a PR, reporting it, or merging on it.
user-invocable: false
metadata:
  internal: true
---

# Recorded live check

A recording must show where each click lands and how the screen changes, or it proves nothing.
Firstmate reviews every recording itself before it reports, attaches, or merges on it.

## Recording standard

The frontend repo's recording helper, `e2e/support/recording.ts` in `apply_pass_frontend`, owns how to record; read it rather than restating its API.
Every recording has:

- a visible cursor and a ripple at each click point
- the target outlined for about 500 ms before each click, type, or upload
- a caption naming each action before it happens
- slowMo near 300 ms and a hold of about 1 s after each navigation or transition
- a Playwright trace beside each mp4, named `<name>.trace.zip`
- one recording per case, so a failing case stands apart

Signing in and other setup the viewer does not need stays off the caption track.

## Brief lines

When a ship or scout must record a live check, tell it to:

- run against the real test stack (real API and sign-in, mocks off), never demo or mock mode
- record every case through the helper, with a trace beside each mp4
- write recordings to its own data directory and report the paths, never commit them
- stop and report a missing or failing helper rather than recording without the overlay

## Review

1. Run `bin/fm-video-review.sh <name>.mp4...`; it writes `review/<name>.contact.png` and `<name>.contact.txt` beside each video, and summarises the trace beside it.
   Its `--help` owns the options.
2. Read every contact sheet, one per case.
   Check that each click shows a cursor, ripple, and outlined target with a caption, and that the frames after it show the resulting screen.
   A sheet with no overlay, a missing hold after a transition, or a click with no visible target fails the recording.
   Lower `--scene` or `--interval` and rerun when a transition falls between sampled frames; raise `--max-frames` too when the index says the sample was thinned.
3. Read the trace summary and the index file.
   A failed action or console error in a case that looks fine on screen is a finding, not noise.
4. Check each case's frames against what the case claimed to prove.
   Send a failing recording back to the worker with the timestamp and what is missing.

## Attach

Attach the mp4 files and any screenshots to the PR with `gh attach --browser auto <file>...` from the firstmate home, then put the returned references in the PR body or a comment.
Attach the contact sheets only when they explain a result the video cannot.
Report a recording only after the review above passes.
