#!/usr/bin/env python3
# Fork-only: Stop hook that backs explain-with-example.sh. Opt-in: turn it on with
# `bin/fm-team-skills.sh hooks enable`.
"""Stop hook: the terminal does not render Mermaid or HTML tags, so a chat reply
that contains a ```mermaid block or <br/> shows raw code. Block the stop and make
the agent resend the diagram as plain text."""
import json, re, sys

event = json.load(sys.stdin)
if event.get("stop_hook_active"):
    sys.exit(0)  # one correction round only; never loop

texts = []
try:
    with open(event["transcript_path"]) as f:
        lines = [json.loads(l) for l in f if l.strip()]
except Exception:
    sys.exit(0)
# collect assistant text since the last real user prompt
for entry in reversed(lines):
    if entry.get("type") == "user":
        content = entry.get("message", {}).get("content")
        if isinstance(content, str) or any(
            isinstance(c, dict) and c.get("type") == "text" for c in content or []
        ):
            break
    if entry.get("type") == "assistant":
        for c in entry.get("message", {}).get("content", []):
            if isinstance(c, dict) and c.get("type") == "text":
                texts.append(c["text"])
reply = "\n".join(texts)

problems = []
if re.search(r"^\s*```\s*mermaid", reply, re.M | re.I):
    problems.append("a ```mermaid block")
# a tag inside code (fenced or inline) is a mention, not markup
prose = re.sub(r"```.*?```", "", reply, flags=re.S)
prose = re.sub(r"`[^`\n]*`", "", prose)
if re.search(r"<br\s*/?>", prose, re.I):
    problems.append("an HTML <br/> tag")
if not problems:
    sys.exit(0)
print(json.dumps({
    "decision": "block",
    "reason": "Your reply contains " + " and ".join(problems) + ". The terminal shows "
    "these as raw code, so the diagram is unreadable. Resend the same answer with every diagram "
    "redrawn as plain text in a ```text block (arrows or box-drawing, one step per line, no tags). "
    "If a picture is truly needed, render it to PNG with mmdc, Read the PNG to check every label, "
    "and send the file instead.",
}))
