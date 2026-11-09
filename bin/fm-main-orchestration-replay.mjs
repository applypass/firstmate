// Fork-only: replay recorded main-session tool calls through the orchestration guard classifier (applypass fork).
//
// usage: node fm-main-orchestration-replay.mjs [--home <main FM_HOME>] [--json] [--examples <n>] <transcript.jsonl>...
//
// Feeds every recorded tool call through bin/fm-main-orchestration-policy.mjs with the
// captain message windows rebuilt from the transcript: a typed prompt or a mid-turn
// queued_command from a human opens a window when bin/fm-reply-first.sh classify says
// the captain wrote it (the same classifier the hooks use), and resets the quick-lookup
// count; the override phrases lift the check for that window. Prints counts per class,
// the blocked calls grouped (command name and path shape only), and the allowed calls
// that look like work. It reads transcripts and writes nothing; nothing it prints holds
// transcript text beyond a command name, flags, and path basenames.
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { classifyCall, makeContext } from "./fm-main-orchestration-policy.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
let home = process.env.FM_HOME || path.join(process.env.HOME || "", "workspace/firstmate");
let asJson = false;
let examples = 3;
const files = [];
for (let i = 0; i < args.length; i += 1) {
  if (args[i] === "--home") home = args[++i];
  else if (args[i] === "--json") asJson = true;
  else if (args[i] === "--examples") examples = Number(args[++i]) || 3;
  else files.push(args[i]);
}
if (files.length === 0) { console.error("usage: fm-main-orchestration-replay.mjs [--home DIR] [--json] <transcript.jsonl>..."); process.exit(2); }

const LIMIT = Number(process.env.FM_MAIN_LOOKUP_LIMIT) > 0 ? Number(process.env.FM_MAIN_LOOKUP_LIMIT) : 2;
const OVERRIDE = /look yourself|look it up yourself|look at it yourself|check yourself|check it yourself|dig yourself|dig in yourself/i;
const ctx = makeContext(home);

function messageText(entry) {
  if (entry.type === "user" && entry.origin?.kind === "human" && !entry.isMeta && typeof entry.message?.content === "string") return entry.message.content;
  if (entry.type === "user" && entry.origin?.kind === "human" && !entry.isMeta && Array.isArray(entry.message?.content) && !entry.message.content.some((b) => b.type === "tool_result")) {
    return entry.message.content.filter((b) => b.type === "text").map((b) => b.text).join("\n");
  }
  const a = entry.attachment;
  if (entry.type === "attachment" && a?.type === "queued_command" && a.origin?.kind === "human") {
    return typeof a.prompt === "string" ? a.prompt : (a.prompt || []).filter((b) => b.type === "text").map((b) => b.text).join("\n");
  }
  return null;
}

// A user prompt (string or text block, not a tool result or meta line) or a queued_command
// attachment starts a turn, the same entries bin/fm-reply-first.sh's turn marker reads.
function startsTurn(entry) {
  if (entry.type === "attachment") return entry.attachment?.type === "queued_command";
  if (entry.type !== "user" || entry.isMeta) return false;
  const c = entry.message?.content;
  return typeof c === "string" || (Array.isArray(c) && c.some((b) => b.type === "text"));
}

// Pass 1: collect distinct message texts, ask the real classifier once.
const texts = new Map();
async function eachLine(file, fn) {
  const rl = createInterface({ input: createReadStream(file), crlfDelay: Infinity });
  for await (const line of rl) {
    if (!line) continue;
    let entry;
    try { entry = JSON.parse(line); } catch { continue; }
    fn(entry);
  }
}
for (const file of files) {
  await eachLine(file, (entry) => {
    const text = messageText(entry);
    if (text !== null) texts.set(text.trim(), null);
  });
}
const keys = [...texts.keys()];
const out = spawnSync("bash", [path.join(here, "fm-reply-first.sh"), "classify"], {
  input: keys.map((k) => JSON.stringify(k)).join("\n") + "\n",
  env: { ...process.env, FM_HOME: home }, encoding: "utf8", maxBuffer: 1 << 28,
});
const verdicts = (out.stdout || "").split("\n").filter(Boolean);
keys.forEach((k, i) => texts.set(k, verdicts[i] === "1"));

const counts = { allow: 0, quick: 0, "quick-over-limit": 0, deny: 0, overridden: 0 };
const groups = new Map(); // group -> Map(summary -> n)
const looksLikeWork = new Map();
let calls = 0;
let messages = 0;

function anonymise(s) {
  return s.replace(/\/Users\/[^/\s]+/g, "~").replace(/\bsc-?\d{3,}\b/g, "sc-N").replace(/\b\d{4,}\b/g, "N").replace(/[0-9a-f]{12,}/g, "ID").slice(0, 100);
}
function bump(map, key) { map.set(key, (map.get(key) || 0) + 1); }

for (const file of files) {
  let lookups = 0;
  let override = false;
  let windowOpen = false;
  let cwd = home;
  await eachLine(file, (entry) => {
    if (entry.cwd) cwd = entry.cwd;
    const text = messageText(entry);
    if (text !== null && texts.get(text.trim())) {
      lookups = 0; override = OVERRIDE.test(text); windowOpen = true; messages += 1;
    } else if (startsTurn(entry) && (entry.type === "user" || !windowOpen)) {
      // A user prompt that is not the captain's (wake, notification, doorbell) closes the
      // captain window as the live prompt hook does; a queued_command with no window open
      // starts a new turn. Either way the turn counts its own 2 quick lookups from zero.
      // A queued_command inside an open captain window changes nothing.
      lookups = 0; override = false; windowOpen = false;
    }
    if (entry.type !== "assistant") return;
    for (const block of entry.message?.content || []) {
      if (block.type !== "tool_use") continue;
      calls += 1;
      const v = classifyCall({ tool_name: block.name, tool_input: block.input || {}, cwd }, ctx);
      let state = v.verdict;
      let group = v.group;
      if (state === "quick") {
        lookups += v.quickCount || 1;
        if (lookups > LIMIT) { state = "deny"; group = "quick-lookup-limit"; }
      }
      if (state === "deny" && override) { counts.overridden += 1; continue; }
      if (state === "allow" || state === "quick") {
        counts[state] += 1;
        const input = JSON.stringify(block.input || {});
        const cmd = String(block.input?.command ?? "");
        const flag = block.name === "Bash"
          ? (/\bpsql|curl |python3? |node -e|git |gh-axi pr diff/.test(cmd.replace(/"[^"]*"|'[^']*'/g, "")) ? "names a work tool inside an allowed command" : "")
          : ((block.name === "Write" || block.name === "Edit") && input.length > 3000 ? "large authored file in the records" : "");
        if (flag) bump(looksLikeWork, `${flag}: ${anonymise(block.name === "Bash" ? cmd.split("\n")[0] : block.name)}`);
        continue;
      }
      counts.deny += 1;
      if (!groups.has(group)) groups.set(group, new Map());
      bump(groups.get(group), anonymise(`${block.name}: ${v.summary || ""}`));
    }
  });
}

const top = (map, n) => [...map.entries()].sort((a, b) => b[1] - a[1]).slice(0, n);
const report = {
  transcripts: files.length, calls, captainMessages: messages, counts,
  blockedByGroup: Object.fromEntries([...groups.entries()].sort((a, b) => [...b[1].values()].reduce((x, y) => x + y, 0) - [...a[1].values()].reduce((x, y) => x + y, 0))
    .map(([g, m]) => [g, { total: [...m.values()].reduce((x, y) => x + y, 0), examples: top(m, examples).map(([k, n]) => `${n}x ${k}`) }])),
  allowedThatLookLikeWork: top(looksLikeWork, 12).map(([k, n]) => `${n}x ${k}`),
};
if (asJson) console.log(JSON.stringify(report, null, 2));
else {
  console.log(`transcripts ${report.transcripts}, calls ${calls}, captain message windows ${messages}`);
  console.log(`allowed ${counts.allow}, quick lookups ${counts.quick}, blocked ${counts.deny}, blocked but lifted by the override ${counts.overridden}`);
  for (const [g, info] of Object.entries(report.blockedByGroup)) {
    console.log(`\n${g}: ${info.total}`);
    for (const e of info.examples) console.log(`  ${e}`);
  }
  console.log("\nallowed calls that look like work:");
  for (const e of report.allowedThatLookLikeWork) console.log(`  ${e}`);
}
