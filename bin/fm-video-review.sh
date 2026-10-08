#!/usr/bin/env bash
# fm-video-review.sh - turn a recorded live check into one contact-sheet PNG per video.
#
# Usage:
#   fm-video-review.sh [options] <video> [<video>...] [<trace.zip>...]
#
# Options:
#   --out-dir <dir>    write sheets here (default: <video dir>/review)
#   --interval <sec>   longest gap between sampled frames (default 3)
#   --scene <0-1>      scene-change threshold; lower picks more frames (default 0.08)
#   --min-gap <sec>    shortest gap between sampled frames (default 0.5)
#   --max-frames <n>   thin the sample to at most n frames, noting it (default 24)
#   --cols <n>         tiles per row (default 4)
#   --tile-width <px>  width of each tile (default 400)
#   -h, --help         show this help
#
# For each video the script writes, at deterministic paths:
#   <out-dir>/<name>.contact.png   tiles in time order, each labelled "t=<sec>s #<n>"
#   <out-dir>/<name>.contact.txt   the sampled timestamps plus the trace summary
# It samples the first frame, every scene change, at least one frame per
# --interval, and the last frame, so a quiet stretch still shows and a burst of
# change is not lost. The same input and options give the same bytes.
#
# A trace named <name>.trace.zip beside <name>.mp4 is summarised automatically.
# A trace zip passed on the command line pairs with the video whose name matches
# its own (x.trace.zip with x.mp4) and replaces the neighbour.
# The summary counts Playwright actions and test-runner expect steps (not hooks,
# fixtures, or test.step wrappers), lists failed actions and error events, and
# counts console errors.
#
# Needs ffmpeg 5.1 or newer, ffprobe, and python3 on PATH; it installs nothing.
# Exit: 0 ok, 1 bad input or a failed run, 2 usage, 3 a required tool is missing.
set -u

usage() {
  sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

die_usage() {
  printf 'fm-video-review: %s\n' "$1" >&2
  printf "Run 'fm-video-review.sh --help' for usage.\n" >&2
  exit 2
}

OUT_DIR=''
INTERVAL=3
SCENE=0.08
MIN_GAP=0.5
MAX_FRAMES=24
COLS=4
TILE_WIDTH=400
INPUTS=()

need_value() {  # <flag> <remaining-arg-count>
  [ "$2" -ge 2 ] || die_usage "$1 needs a value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --out-dir) need_value "$1" "$#"; OUT_DIR=$2; shift 2 ;;
    --interval) need_value "$1" "$#"; INTERVAL=$2; shift 2 ;;
    --scene) need_value "$1" "$#"; SCENE=$2; shift 2 ;;
    --min-gap) need_value "$1" "$#"; MIN_GAP=$2; shift 2 ;;
    --max-frames) need_value "$1" "$#"; MAX_FRAMES=$2; shift 2 ;;
    --cols) need_value "$1" "$#"; COLS=$2; shift 2 ;;
    --tile-width) need_value "$1" "$#"; TILE_WIDTH=$2; shift 2 ;;
    --) shift; INPUTS+=("$@"); break ;;
    -*) die_usage "unknown option: $1" ;;
    *) INPUTS+=("$1"); shift ;;
  esac
done

[ "${#INPUTS[@]}" -gt 0 ] || die_usage "give at least one video"

for tool in ffmpeg ffprobe python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf "fm-video-review: %s not found on PATH; install it first (for example 'brew install ffmpeg' for ffmpeg and ffprobe)\n" "$tool" >&2
    exit 3
  fi
done

exec python3 -I - "$OUT_DIR" "$INTERVAL" "$SCENE" "$MIN_GAP" "$MAX_FRAMES" "$COLS" "$TILE_WIDTH" "${INPUTS[@]}" <<'PY'
import json
import math
import os
import re
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib

out_dir_arg, interval_s, scene_s, min_gap_s, max_frames_s, cols_s, tile_w_s, *inputs = sys.argv[1:]


def fail(message, code=1):
    print(f"fm-video-review: {message}", file=sys.stderr)
    sys.exit(code)


def number(text, name, kind=float, low=0.0):
    try:
        value = kind(text)
    except ValueError:
        fail(f"{name} must be a number, got '{text}'", 2)
    if not value > low:
        fail(f"{name} must be greater than {low:g}, got '{text}'", 2)
    return value


interval = number(interval_s, "--interval")
scene = number(scene_s, "--scene")
min_gap = number(min_gap_s, "--min-gap", low=-1.0)
max_frames = number(max_frames_s, "--max-frames", int)
cols = number(cols_s, "--cols", int)
tile_w = number(tile_w_s, "--tile-width", int, 15)
if scene >= 1:
    fail("--scene must be below 1", 2)

# 5x7 glyphs for the label text, one string of seven 5-bit rows each.
GLYPHS = {
    "0": "01110 10001 10011 10101 11001 10001 01110",
    "1": "00100 01100 00100 00100 00100 00100 01110",
    "2": "01110 10001 00001 00010 00100 01000 11111",
    "3": "11110 00001 00001 01110 00001 00001 11110",
    "4": "00010 00110 01010 10010 11111 00010 00010",
    "5": "11111 10000 11110 00001 00001 10001 01110",
    "6": "00110 01000 10000 11110 10001 10001 01110",
    "7": "11111 00001 00010 00100 01000 01000 01000",
    "8": "01110 10001 10001 01110 10001 10001 01110",
    "9": "01110 10001 10001 01111 00001 00010 01100",
    ".": "00000 00000 00000 00000 00000 01100 01100",
    "=": "00000 00000 11111 00000 11111 00000 00000",
    "#": "01010 01010 11111 01010 11111 01010 01010",
    "t": "01000 01000 11100 01000 01000 01001 00110",
    "s": "00000 00000 01111 10000 01110 00001 11110",
    " ": "00000 00000 00000 00000 00000 00000 00000",
}
SCALE = 2
LABEL_H = 7 * SCALE + 8
GAP = 4
BG = (24, 24, 24)
LABEL_BG = (52, 52, 52)
LABEL_FG = (255, 255, 255)


def run(cmd, **kwargs):
    try:
        return subprocess.run(cmd, check=False, **kwargs)
    except OSError as exc:
        fail(f"cannot run {cmd[0]}: {exc}", 3)


def probe(video):
    proc = run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0",
         "-show_entries", "stream=width,height:format=duration",
         "-of", "json", video],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    try:
        data = json.loads(proc.stdout.decode("utf-8", "replace") or "{}")
        stream = data["streams"][0]
        duration = float(data["format"]["duration"])
        return int(stream["width"]), int(stream["height"]), duration
    except (KeyError, IndexError, ValueError):
        detail = proc.stderr.decode("utf-8", "replace").strip()
        fail(f"{video}: not a readable video ({detail or 'no video stream'})")


def grab(video, vf, before=()):
    """Run ffmpeg once and return (raw rgb24 bytes, showinfo stderr text)."""
    with tempfile.TemporaryFile() as err:
        proc = run(
            ["ffmpeg", "-nostdin", "-hide_banner", "-v", "info", *before, "-i", video,
             "-vf", vf, "-fps_mode", "passthrough", "-an",
             "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
            stdout=subprocess.PIPE, stderr=err,
        )
        err.seek(0)
        log = err.read().decode("utf-8", "replace")
    if proc.returncode != 0:
        tail = "\n".join(log.strip().splitlines()[-5:])
        fail(f"ffmpeg failed on {video}:\n{tail}")
    return proc.stdout, log


def sample(video, width, height, duration):
    tile_h = max(2, int(tile_w * height / width))
    select = (f"select='isnan(prev_selected_t)+gte(t-prev_selected_t\\,{min_gap})"
              f"*(gt(scene\\,{scene})+gte(t-prev_selected_t\\,{interval}))'")
    vf = f"{select},showinfo,scale={tile_w}:{tile_h}"
    raw, log = grab(video, vf)
    times = [float(m) for m in re.findall(r"pts_time:([0-9.]+)", log)]
    size = tile_w * tile_h * 3
    if size * len(times) != len(raw):
        fail(f"{video}: frame count did not match the sampled timestamps")
    frames = [(times[i], raw[i * size:(i + 1) * size]) for i in range(len(times))]
    if frames and duration - frames[-1][0] > 1e-3:
        start = frames[-1][0]
        tail, tail_log = grab(video, f"showinfo,scale={tile_w}:{tile_h}", before=("-ss", f"{start:.3f}"))
        tail_times = [float(m) for m in re.findall(r"pts_time:([0-9.]+)", tail_log)]
        if tail_times and tail_times[-1] > 1e-3 and len(tail) >= size:
            frames.append((start + tail_times[-1], tail[-size:]))
    sampled = len(frames)
    if max_frames > 1 and len(frames) > max_frames:
        keep = sorted({round(i * (len(frames) - 1) / (max_frames - 1)) for i in range(max_frames)})
        frames = [frames[i] for i in keep]
    elif max_frames == 1:
        frames = frames[:1]
    return tile_h, frames, sampled


def fill(buf, stride, x, y, w, h, color):
    row = bytes(color) * w
    for yy in range(y, y + h):
        start = yy * stride + x * 3
        buf[start:start + w * 3] = row


def draw_text(buf, stride, x, y, text, right):
    for ch in text:
        if x + 5 * SCALE > right:
            break
        glyph = GLYPHS.get(ch, GLYPHS[" "]).split()
        for gy, bits in enumerate(glyph):
            for gx, bit in enumerate(bits):
                if bit == "1":
                    fill(buf, stride, x + gx * SCALE, y + gy * SCALE, SCALE, SCALE, LABEL_FG)
        x += 6 * SCALE


def png_bytes(width, height, rgb):
    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    stride = width * 3
    rows = b"".join(b"\x00" + bytes(rgb[y * stride:(y + 1) * stride]) for y in range(height))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 6))
            + chunk(b"IEND", b""))


def contact_sheet(tile_h, frames):
    n = len(frames)
    ncols = min(cols, n)
    nrows = math.ceil(n / ncols)
    cell_h = tile_h + LABEL_H
    width = GAP + ncols * (tile_w + GAP)
    height = GAP + nrows * (cell_h + GAP)
    stride = width * 3
    buf = bytearray(bytes(BG) * (width * height))
    for i, (t, raw) in enumerate(frames):
        x = GAP + (i % ncols) * (tile_w + GAP)
        y = GAP + (i // ncols) * (cell_h + GAP)
        fill(buf, stride, x, y, tile_w, LABEL_H, LABEL_BG)
        draw_text(buf, stride, x + 6, y + 4, f"t={t:.1f}s #{i + 1:02d}", x + tile_w)
        for r in range(tile_h):
            dst = (y + LABEL_H + r) * stride + x * 3
            buf[dst:dst + tile_w * 3] = raw[r * tile_w * 3:(r + 1) * tile_w * 3]
    return png_bytes(width, height, buf)


RUNNER_ACTIONS = ("pw:api", "expect")


def trace_summary(path):
    try:
        with zipfile.ZipFile(path) as zf:
            names = sorted(n for n in zf.namelist() if n.endswith(".trace"))
            events = []
            for name in names:
                runner = os.path.basename(name) == "test.trace"
                for line in zf.read(name).decode("utf-8", "replace").splitlines():
                    try:
                        ev = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(ev, dict):
                        events.append((runner, ev))
    except (OSError, zipfile.BadZipFile) as exc:
        return [f"trace: {path} is unreadable ({exc})"]
    covered = {ev.get("stepId") for runner, ev in events
               if not runner and ev.get("type") == "before" and ev.get("stepId")}
    counted = {ev.get("callId") for runner, ev in events
               if runner and ev.get("type") == "before" and ev.get("method") in RUNNER_ACTIONS}
    titles, actions, failed, errors, console = {}, 0, [], [], 0
    for runner, ev in events:
        kind = ev.get("type")
        if runner and kind in ("before", "after") and (ev.get("callId") in covered or ev.get("callId") not in counted):
            continue
        if kind == "before":
            titles[ev.get("callId")] = ev.get("title") or ev.get("apiName") or ev.get("method") or "action"
        elif kind == "after":
            actions += 1
            err = ev.get("error")
            if err:
                msg = err.get("message", "") if isinstance(err, dict) else str(err)
                failed.append(f"{titles.get(ev.get('callId'), 'action')}: {msg.strip().splitlines()[0] if msg.strip() else 'failed'}")
        elif kind == "error":
            msg = str(ev.get("message", "")).strip()
            errors.append(msg.splitlines()[0] if msg else "error")
        elif kind == "console" and ev.get("messageType") == "error":
            console += 1
    out = [f"trace: {os.path.basename(path)} - {actions} actions, {len(failed)} failed, "
           f"{len(errors)} error events, {console} console errors"]
    out += [f"  failed action - {item}" for item in failed[:10]]
    out += [f"  error event - {item}" for item in errors[:10]]
    return out


TRACE_SUFFIX = ".trace.zip"
videos, traces = [], {}
for item in inputs:
    if item.endswith(".zip"):
        base = os.path.basename(item)
        base = base[:-len(TRACE_SUFFIX)] if base.endswith(TRACE_SUFFIX) else base[:-4]
        traces[base] = item
    else:
        videos.append(item)
if not videos:
    fail("give at least one video; trace zips pair with a video of the same name", 2)

names = {}
for video in videos:
    if not os.path.isfile(video):
        fail(f"{video}: no such file")
    name = os.path.splitext(os.path.basename(video))[0]
    if name in names and out_dir_arg:
        fail(f"{video} and {names[name]} share the name '{name}'; they would overwrite one sheet", 2)
    names[name] = video
stray = sorted(set(traces) - set(names))
if stray:
    fail(f"trace {traces[stray[0]]} has no video named '{stray[0]}'", 2)

for video in videos:
    name = os.path.splitext(os.path.basename(video))[0]
    out_dir = out_dir_arg or os.path.join(os.path.dirname(os.path.abspath(video)), "review")
    os.makedirs(out_dir, exist_ok=True)
    width, height, duration = probe(video)
    tile_h, frames, sampled = sample(video, width, height, duration)
    if not frames:
        fail(f"{video}: no frames sampled")
    png_path = os.path.join(out_dir, f"{name}.contact.png")
    txt_path = os.path.join(out_dir, f"{name}.contact.txt")
    with open(png_path, "wb") as fh:
        fh.write(contact_sheet(tile_h, frames))
    trace = traces.get(name)
    if trace is None:
        neighbour = os.path.join(os.path.dirname(video), f"{name}{TRACE_SUFFIX}")
        trace = neighbour if os.path.isfile(neighbour) else None
    count = f"{len(frames)} frames"
    if sampled > len(frames):
        count = f"{len(frames)} of {sampled} sampled frames (thinned by --max-frames)"
    report = [f"video: {video}", f"duration: {duration:.1f}s, {width}x{height}",
              f"frames: {count}"]
    report += [f"  #{i + 1:02d} t={t:.1f}s" for i, (t, _) in enumerate(frames)]
    report += trace_summary(trace) if trace else ["trace: none found beside the video"]
    with open(txt_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(report) + "\n")
    print(f"sheet: {png_path} ({count}, {duration:.1f}s)")
    print("\n".join(line for line in report if line.startswith(("trace", "  failed", "  error"))))
PY
