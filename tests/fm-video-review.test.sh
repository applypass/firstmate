#!/usr/bin/env bash
# Behavior tests for bin/fm-video-review.sh, the recorded-live-check frame reviewer.
#
# Test media comes from ffmpeg's lavfi sources at run time; nothing binary is
# committed. The ffmpeg-backed cases report a skip when ffmpeg is absent, while
# the help, usage, and missing-tool cases always run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REVIEW="$ROOT/bin/fm-video-review.sh"
TMP_ROOT=$(fm_test_tmproot fm-video-review)
HAVE_FFMPEG=0
command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1 && HAVE_FFMPEG=1

png_size() {  # <png> -> "<width> <height>" read from the IHDR chunk
  python3 -I -c 'import struct,sys; d=open(sys.argv[1],"rb").read(); print(*struct.unpack(">II", d[16:24]))' "$1"
}

make_clip() {  # <path> : white 2s, blue 2s, test pattern 4s
  ffmpeg -nostdin -v error -f lavfi -i 'color=c=white:s=320x180:r=10:d=2' \
    -f lavfi -i 'color=c=blue:s=320x180:r=10:d=2' \
    -f lavfi -i 'testsrc2=s=320x180:r=10:d=4' \
    -filter_complex '[0][1][2]concat=n=3:v=1:a=0' -pix_fmt yuv420p "$1" || fail "could not generate test media"
}

test_help_documents_the_contract() {
  local out
  out=$("$REVIEW" --help) || fail "--help should exit 0"
  assert_contains "$out" "Usage:" "help has no usage line"
  assert_contains "$out" "<name>.contact.png" "help does not name the output path"
  assert_contains "$out" "--interval" "help does not list the interval floor"
  assert_not_contains "$out" "set -u" "help leaked the script body"
  pass "--help prints the usage and output contract"
}

test_usage_errors_exit_2() {
  local rc=0
  "$REVIEW" >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "no arguments"
  rc=0
  "$REVIEW" --bogus x.mp4 >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "unknown option"
  rc=0
  "$REVIEW" --cols >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "option without a value"
  pass "bad usage exits 2"
}

test_missing_ffmpeg_is_reported_clearly() {
  local empty out rc=0
  empty="$TMP_ROOT/empty-path"
  mkdir -p "$empty"
  out=$(PATH="$empty" /bin/bash "$REVIEW" "$TMP_ROOT/none.mp4" 2>&1) || rc=$?
  expect_code 3 "$rc" "missing ffmpeg"
  assert_contains "$out" "ffmpeg not found on PATH" "missing-ffmpeg message"
  assert_contains "$out" "brew install ffmpeg" "missing-ffmpeg message gives no way forward"
  pass "a missing ffmpeg exits 3 with an install hint"
}

test_contact_sheet_at_deterministic_path() {
  local dir out size sum1 sum2
  [ "$HAVE_FFMPEG" = 1 ] || { echo "skip: ffmpeg absent"; return 0; }
  dir="$TMP_ROOT/sheet"
  mkdir -p "$dir"
  make_clip "$dir/clip.mp4"
  out=$("$REVIEW" --tile-width 200 --cols 3 "$dir/clip.mp4") || fail "review failed: $out"
  assert_present "$dir/review/clip.contact.png" "sheet is not beside the video under review/"
  assert_present "$dir/review/clip.contact.txt" "index is missing"
  assert_contains "$out" "sheet: $dir/review/clip.contact.png" "stdout does not name the sheet"
  [ "$(head -c 8 "$dir/review/clip.contact.png" | od -An -c | tr -d ' ')" = '211PNG\r\n032\n' ] ||
    fail "sheet is not a PNG"
  size=$(png_size "$dir/review/clip.contact.png")
  # three 200px tiles and four 4px gaps wide (616); two rows of (112 + 22 label) + three gaps high
  assert_equals "616 280" "$size" "sheet size follows --cols and --tile-width"
  assert_grep "t=0.0s" "$dir/review/clip.contact.txt" "first frame is not sampled"
  assert_grep "t=2.0s" "$dir/review/clip.contact.txt" "scene change at 2s is not sampled"
  assert_grep "t=4.0s" "$dir/review/clip.contact.txt" "scene change at 4s is not sampled"
  sum1=$(cksum <"$dir/review/clip.contact.png")
  "$REVIEW" --tile-width 200 --cols 3 "$dir/clip.mp4" >/dev/null || fail "second run failed"
  sum2=$(cksum <"$dir/review/clip.contact.png")
  assert_equals "$sum1" "$sum2" "same input gave different bytes"
  pass "one sheet per video at <video dir>/review/<name>.contact.png, identical across runs"
}

test_out_dir_and_max_frames() {
  local dir out count
  [ "$HAVE_FFMPEG" = 1 ] || { echo "skip: ffmpeg absent"; return 0; }
  dir="$TMP_ROOT/outdir"
  mkdir -p "$dir"
  make_clip "$dir/a.mp4"
  make_clip "$dir/b.mp4"
  out=$("$REVIEW" --out-dir "$dir/out" --max-frames 3 --interval 1 "$dir/a.mp4" "$dir/b.mp4") || fail "review failed: $out"
  assert_present "$dir/out/a.contact.png" "first video has no sheet"
  assert_present "$dir/out/b.contact.png" "second video has no sheet"
  count=$(grep -c '^  #' "$dir/out/a.contact.txt")
  assert_equals "3" "$count" "--max-frames did not thin the sample"
  assert_grep "sampled frames (thinned by --max-frames)" "$dir/out/a.contact.txt" "index hides the thinning"
  assert_contains "$out" "(thinned by --max-frames)" "stdout hides the thinning"
  pass "--out-dir collects every sheet and --max-frames caps the sample"
}

test_trace_summary_lists_failed_actions() {
  local dir out
  [ "$HAVE_FFMPEG" = 1 ] || { echo "skip: ffmpeg absent"; return 0; }
  dir="$TMP_ROOT/trace"
  mkdir -p "$dir"
  make_clip "$dir/case-1.mp4"
  python3 -I - "$dir/case-1.trace.zip" <<'PY' || fail "could not build the trace fixture"
import json, sys, zipfile
events = [
    {"type": "before", "callId": "c1", "title": "Click Next"},
    {"type": "after", "callId": "c1"},
    {"type": "before", "callId": "c2", "title": "Fill email"},
    {"type": "after", "callId": "c2", "error": {"message": "locator not found\nlong detail"}},
    {"type": "console", "messageType": "error", "text": "boom"},
]
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("trace.trace", "\n".join(json.dumps(e) for e in events))
PY
  out=$("$REVIEW" "$dir/case-1.mp4") || fail "review failed: $out"
  assert_contains "$out" "2 actions, 1 failed, 0 error events, 1 console errors" "trace counts"
  assert_contains "$out" "failed action - Fill email: locator not found" "failed action is not listed"
  assert_grep "failed action - Fill email" "$dir/review/case-1.contact.txt" "index omits the trace summary"
  pass "a neighbouring <name>.trace.zip is summarised with its failed actions"
}

test_runner_trace_counts_each_action_once() {
  local dir out
  [ "$HAVE_FFMPEG" = 1 ] || { echo "skip: ffmpeg absent"; return 0; }
  dir="$TMP_ROOT/runner-trace"
  mkdir -p "$dir"
  make_clip "$dir/case-2.mp4"
  python3 -I - "$dir/case-2.trace.zip" <<'PY' || fail "could not build the trace fixture"
import json, sys, zipfile
steps = [
    {"type": "before", "callId": "s1", "title": "Click Next", "category": "pw:api"},
    {"type": "after", "callId": "s1"},
    {"type": "before", "callId": "s2", "title": "Fill email", "category": "pw:api"},
    {"type": "after", "callId": "s2", "error": {"message": "locator not found"}},
    {"type": "before", "callId": "s3", "title": "Expect heading", "category": "expect"},
    {"type": "after", "callId": "s3", "error": {"message": "heading not visible"}},
    {"type": "error", "message": "test failed"},
]
library = [
    {"type": "before", "callId": "call@1", "stepId": "s1", "title": "Click Next"},
    {"type": "after", "callId": "call@1"},
    {"type": "before", "callId": "call@2", "stepId": "s2", "title": "Fill email"},
    {"type": "after", "callId": "call@2", "error": {"message": "locator not found"}},
]
with zipfile.ZipFile(sys.argv[1], "w") as zf:
    zf.writestr("test.trace", "\n".join(json.dumps(e) for e in steps))
    zf.writestr("trace.trace", "\n".join(json.dumps(e) for e in library))
PY
  out=$("$REVIEW" "$dir/case-2.mp4") || fail "review failed: $out"
  assert_contains "$out" "3 actions, 2 failed, 1 error events, 0 console errors" "runner trace counts"
  assert_equals "1" "$(grep -c 'failed action - Fill email' "$dir/review/case-2.contact.txt")" "failed click listed more than once"
  assert_grep "failed action - Expect heading: heading not visible" "$dir/review/case-2.contact.txt" "runner-only step failure is lost"
  pass "a test-runner trace counts each action once and keeps its own step failures"
}

test_last_frame_is_kept_when_stream_ends_early() {
  local dir out
  [ "$HAVE_FFMPEG" = 1 ] || { echo "skip: ffmpeg absent"; return 0; }
  dir="$TMP_ROOT/early-end"
  mkdir -p "$dir"
  # video stops at 3.9s while the audio runs the container out to 6s
  ffmpeg -nostdin -v error -f lavfi -i 'color=c=white:s=320x180:r=10:d=2' \
    -f lavfi -i 'color=c=blue:s=320x180:r=10:d=2' \
    -f lavfi -i 'anullsrc=r=8000:cl=mono' \
    -filter_complex '[0][1]concat=n=2:v=1:a=0[v]' -map '[v]' -map 2 -t 6 \
    -pix_fmt yuv420p "$dir/early.mp4" || fail "could not generate test media"
  out=$("$REVIEW" --interval 1.5 "$dir/early.mp4") || fail "review failed: $out"
  assert_grep "t=3.9s" "$dir/review/early.contact.txt" "last video frame is dropped"
  pass "the last decoded frame is kept when the video stream ends before the container"
}

test_unreadable_input_fails() {
  local out rc=0
  [ "$HAVE_FFMPEG" = 1 ] || { echo "skip: ffmpeg absent"; return 0; }
  printf 'not a video' >"$TMP_ROOT/bad.mp4"
  out=$("$REVIEW" "$TMP_ROOT/bad.mp4" 2>&1) || rc=$?
  expect_code 1 "$rc" "unreadable video"
  assert_contains "$out" "not a readable video" "unreadable-video message"
  rc=0
  "$REVIEW" "$TMP_ROOT/missing.mp4" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "missing video"
  pass "an unreadable or missing video exits 1"
}

test_help_documents_the_contract
test_usage_errors_exit_2
test_missing_ffmpeg_is_reported_clearly
test_contact_sheet_at_deterministic_path
test_out_dir_and_max_frames
test_trace_summary_lists_failed_actions
test_runner_trace_counts_each_action_once
test_last_frame_is_kept_when_stream_ends_early
test_unreadable_input_fails

echo "# all fm-video-review tests passed"
