// Fork-only: classifier for the main orchestration guard (applypass fork).
//
// Decides one tool call: is it on the allowlist of what the main firstmate does
// itself? Default deny - a call this policy cannot place is refused. The hook
// wrapper bin/fm-main-orchestration-guard.sh owns scope, the shared captain
// message window, the override, the refusal log, and the deny output; its header
// owns the allowlist text. This file only classifies and never runs, expands, or
// sources any byte of the command it reads.
//
// Shell parsing comes from bin/fm-arm-command-policy.mjs (the repo's single shell
// lexer), so quoting, heredocs, subshells, and command substitution are read the
// same way the other guards read them.
//
// usage: <PreToolUse JSON on stdin> | node fm-main-orchestration-policy.mjs --home <FM_HOME>
// prints one JSON line: {"verdict":"allow|quick|deny","group":"...","summary":"..."}
//   allow  on the allowlist
//   quick  an allowed quick lookup; the caller counts it against the limit
//   deny   refused; group names the kind of work, summary says what, safe to log

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { readFileSync, realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

// Exact bin/fm-* names the main firstmate runs itself: routing, spawn, send,
// control, decide, captain-hold, pr-merge, tasks-axi, wake-drain, crew-state,
// peek, update, plus the supervision and landing steps its own contract names.
export const ALLOWED_SCRIPTS = new Set([
  "fm-wake-drain.sh", "fm-send.sh", "fm-spawn.sh", "fm-control.sh", "fm-decide.sh",
  "fm-captain-hold.sh", "fm-pr-merge.sh", "fm-tasks-axi.sh", "fm-crew-state.sh",
  "fm-peek.sh", "fm-update.sh", "fm-fleet-sync.sh",
  "fm-dispatch-resolve.sh", "fm-project-mode.sh", "fm-brief.sh", "fm-home-seed.sh",
  "fm-branch-report.sh", "fm-branch-outcome.sh", "fm-teardown.sh", "fm-pr-check.sh",
  "fm-shortcut-ticket.sh", "fm-fleet-view.sh", "fm-lease.sh", "fm-watch-arm.sh",
  "fm-session-start.sh", "fm-afk-return.sh", "fm-secondmate-restart.sh",
  "fm-backlog-handoff.sh", "fm-task-ledger.sh", "fm-check-register.sh", "fm-inbox.sh",
]);

// Commands with no side effect beyond the shell, and the fleet-record readers.
const BUILTINS = new Set([
  "export", "set", "unset", "cd", "pushd", "popd", "true", "false", ":", "echo", "printf", "date",
  "test", "[", "[[", "read", "wait", "pwd", "exit", "return", "local", "declare", "basename", "dirname",
]);
// A reader takes file operands; a filter reads only its pipe.
const READERS = new Set(["cat", "head", "tail", "wc", "ls", "stat", "nl", "cut", "sort", "uniq", "grep", "rg", "egrep", "fgrep", "sed", "awk", "jq", "find", "diff"]);
const PATTERN_FIRST = new Set(["grep", "rg", "egrep", "fgrep", "sed", "awk", "jq"]);
const FILTERS = new Set(["tr", "column", "fold", "rev", "tac"]);
const WRITERS = new Set(["mkdir", "cp", "mv", "rm", "touch", "tee", "ln", "chmod"]);
const KEYWORDS_SKIP = new Set(["do", "then", "else", "elif", "if", "while", "until", "!", "{", "}"]);
const KEYWORDS_BARE = new Set(["done", "fi", "esac", "}", "{", "do", "then", "else"]);
const TOOLS_ALLOWED = new Set(["Skill", "ToolSearch", "ReadNotifications", "SendUserFile", "AskUserQuestion"]);
const MEDIA = /\.(png|jpe?g|gif|webp|mp4|mov|webm)$/i;
const QUICK_GH = new Set(["view", "status"]);

const rank = { allow: 0, quick: 1, deny: 2 };

function worse(a, b) {
  return rank[b.verdict] > rank[a.verdict] ? b : a;
}
const allow = () => ({ verdict: "allow", group: "allow", summary: "" });
const quick = (summary) => ({ verdict: "quick", group: "quick-lookup", summary });
const deny = (group, summary) => ({ verdict: "deny", group, summary: clip(summary) });
const clip = (s) => String(s).replace(/\s+/g, " ").slice(0, 160);

const SECRET = /(token|secret|password|passwd|pgpassword|api[_-]?key|bearer|authorization)/i;

// A log-safe rendering of one command: its name, flags, and path-like operands.
// Quoted strings, assignments, and anything near a secret word are dropped.
function describe(name, words) {
  const parts = [name];
  for (const word of words) {
    const v = word.value;
    if (word.quoted && /\s/.test(v)) continue;
    if (SECRET.test(v) || /^[A-Za-z_][A-Za-z0-9_]*=/.test(v)) continue;
    if (v.startsWith("-") || v.includes("/")) parts.push(v.length > 60 ? `${v.slice(0, 57)}...` : v);
    if (parts.length >= 5) break;
  }
  return parts.join(" ");
}

export function makeContext(home, env = process.env) {
  let root = home;
  try { root = realpathSync(home); } catch { /* keep as given */ }
  const mateHomes = [];
  try {
    const reg = readFileSync(path.join(root, "data/secondmates.md"), "utf8");
    for (const line of reg.split("\n")) {
      const m = line.match(/\(\s*(?:host:[^;]*;\s*root:[^;]*;\s*)?home:\s*([^;)]*)/);
      if (m && path.isAbsolute(m[1].trim())) mateHomes.push(path.normalize(m[1].trim()));
    }
  } catch { /* no registry */ }
  return { home: root, homeRaw: home, mateHomes, env };
}

function isMemoryDir(p) {
  return /(^|\/)\.claude[^/]*\/projects\/[^/]+\/memory(\/|$)/.test(p);
}

// 0 when abs is a fleet record of the main home or the memory dir (or a null sink).
function isFleetRecord(abs, ctx) {
  if (["/dev/null", "/dev/stdout", "/dev/stderr", "/dev/stdin"].includes(abs)) return true;
  if (isMemoryDir(abs)) return true;
  for (const dir of ["data", "state", "config"]) {
    for (const base of new Set([ctx.home, path.normalize(ctx.homeRaw)])) {
      const root = path.join(base, dir);
      if (abs === root || abs.startsWith(`${root}/`)) return true;
    }
  }
  return false;
}

// Replace $NAME and ${NAME} with what is known: FM_HOME, HOME, and variables the
// same command assigned with a literal value.
function expandVars(v, ctx, vars) {
  let out = v;
  for (let round = 0; round < 4 && out.includes("$"); round += 1) {
    const next = out.replace(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g, (m, n) => {
      if (n === "FM_HOME") return ctx.home;
      if (n === "HOME") return ctx.env.HOME || m;
      return Object.prototype.hasOwnProperty.call(vars, n) ? vars[n] : m;
    });
    if (next === out) break;
    out = next;
  }
  if (out === "~" || out.startsWith("~/")) out = path.join(ctx.env.HOME || "/nonexistent", out.slice(1));
  return out;
}

// Resolve a word to an absolute path, or null when it cannot be known statically.
// A path whose literal front part is already inside one directory, with a variable
// only in the file name (state/$m.status), resolves to that directory.
function resolvePath(word, cwd, ctx, vars = {}) {
  if (word.subs.length > 0) return null;
  const v = expandVars(word.value, ctx, vars);
  if (v.includes("$")) {
    if (v.includes("..")) return null;
    const prefix = v.slice(0, v.indexOf("$"));
    const dir = prefix.endsWith("/") ? prefix : path.dirname(prefix);
    if (!prefix || (!path.isAbsolute(dir) && !cwd)) return null;
    return path.normalize(path.join(path.isAbsolute(dir) ? "/" : cwd, dir, "__dynamic__"));
  }
  if (path.isAbsolute(v)) return path.normalize(v);
  if (!cwd) return null;
  return path.normalize(path.join(cwd, v));
}

// Output files the harness writes for a command the session ran: readable, never writable.
function isHarnessOutput(abs) {
  return /^\/(private\/)?tmp\/claude-\d+\/[^/]+\/(?:[^/]+\/)?(tool-results|tasks)\//.test(abs)
    || /\/\.claude[^/]*\/projects\/[^/]+\/[^/]+\/tool-results\//.test(abs);
}

const isArtifactHtml = (abs) => /\.html?$/i.test(abs) || abs.includes("/.lavish/");

function groupOfPath(abs, ctx) {
  if (/\/(projects|\.treehouse|conductor)\//.test(abs) || abs.includes("/apply_pass_")) return "project-read";
  if (/\.html?$/i.test(abs) || abs.includes("/.lavish/")) return "artifact-read";
  if (/\/bin\//.test(abs)) return "script-read";
  if (/\.log$|\/logs?\//.test(abs)) return "log-read";
  return "outside-records";
}

// Flags that take the next word as their value, per reader.
const VALUE_FLAGS = {
  head: ["-n", "-c"], tail: ["-n", "-c"], cut: ["-d", "-f", "-c", "-b"], sort: ["-k", "-t", "-o", "-S"],
  uniq: ["-f", "-s", "-w"], grep: ["-A", "-B", "-C", "-m", "-e", "-f"], egrep: ["-A", "-B", "-C", "-m", "-e", "-f"],
  fgrep: ["-A", "-B", "-C", "-m", "-e", "-f"], rg: ["-A", "-B", "-C", "-m", "-e", "-f", "-g", "-t", "-T", "-j"],
  sed: ["-e", "-f", "-l"], awk: ["-F", "-v", "-f"], stat: ["-f", "-c", "-t"],
  jq: ["--arg", "--argjson", "--slurpfile", "--rawfile", "--indent"],
};
const TWO_VALUE_FLAGS = new Set(["--arg", "--argjson", "--slurpfile", "--rawfile"]);
const PATTERN_FLAGS = new Set(["-e", "-f", "--expression", "--file", "--regexp"]);

// The operands of a reader that name files: skip flags and their values, the
// pattern or program, and bare numbers.
function readerOperands(name, words) {
  const ops = [];
  const valueFlags = new Set(VALUE_FLAGS[name] || []);
  let patternTaken = !PATTERN_FIRST.has(name);
  for (let i = 1; i < words.length; i += 1) {
    const v = words[i].value;
    if (v === "--") { for (let j = i + 1; j < words.length; j += 1) ops.push(words[j]); break; }
    if (v.startsWith("-") && v.length > 1) {
      if (PATTERN_FLAGS.has(v) && PATTERN_FIRST.has(name)) patternTaken = true;
      if (valueFlags.has(v)) i += TWO_VALUE_FLAGS.has(v) ? 2 : 1;
      continue;
    }
    if (!patternTaken) { patternTaken = true; continue; }
    if (/^[0-9+,.-]+$/.test(v) && !PATTERN_FIRST.has(name)) continue;
    ops.push(words[i]);
  }
  return ops;
}

function checkRedirections(tokens, cwd, ctx, desc, vars) {
  let result = allow();
  for (let i = 0; i < tokens.length; i += 1) {
    const t = tokens[i];
    if (t.type !== "redir" || t.inlineTarget) continue;
    const isWrite = t.value === ">" || t.value === ">>" || t.value === ">&" || t.value === "<>";
    const isRead = t.value === "<";
    if (!isWrite && !isRead) continue;
    const target = tokens[i + 1];
    if (!target || target.type !== "word") return deny("other", `${desc} redirect with no target`);
    if (/^[0-9-]+$/.test(target.value) && t.value === ">&") continue;
    const abs = resolvePath(target, cwd, ctx, vars);
    if (!abs || !isFleetRecord(abs, ctx)) {
      result = worse(result, deny(isWrite ? "project-edit" : groupOfPath(abs || "", ctx), `${desc} ${t.value} ${abs ? path.basename(abs) : "<dynamic>"}`));
    }
  }
  return result;
}

function ghVerdict(name, words) {
  // gh and gh-axi: global flags (-R repo) may come first; only pr view|status.
  let i = 1;
  while (words[i] && words[i].value.startsWith("-")) i += words[i].value === "-R" || words[i].value === "--repo" ? 2 : 1;
  if (words[i]?.value === "pr" && QUICK_GH.has(words[i + 1]?.value || "")) return quick(`${name} pr ${words[i + 1].value}`);
  return deny("outside-system", describe(name, words.slice(1)));
}

function scriptName(word) {
  if (!word) return null;
  const v = word.value;
  const base = path.basename(v);
  if (!/^fm-[a-z0-9-]+\.sh$/.test(base)) return null;
  if (v === base) return base;
  if (v === `bin/${base}` || v.endsWith(`/bin/${base}`)) return base;
  return null;
}

function classifyNode(tokens, state, depth) {
  let result = allow();
  const { cwd, ctx } = state;
  // A group is a subshell or brace list: classify its content with the same cwd.
  for (const t of tokens) {
    if (t.type === "group") result = worse(result, classifyProgram(t.content, { ...state }, depth + 1));
    else if (t.type === "word") {
      for (const sub of t.subs) result = worse(result, classifyProgram(sub.content, { ...state }, depth + 1));
    }
  }
  if (result.verdict === "deny") return result;
  const words = tokens.filter((t) => t.type === "word");
  if (words.length === 0) return result;
  for (const w of words) {
    const m = w.type === "word" && w.subs.length === 0 ? w.value.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s) : null;
    if (!m) break;
    state.vars[m[1]] = m[2];
  }
  const redirects = checkRedirections(tokens, cwd, ctx, "command", state.vars);
  result = worse(result, redirects);
  if (result.verdict === "deny") return result;

  // Drop leading control keywords (do, then, if, while, until, !) so the command after them is read.
  let start = 0;
  while (tokens[start] && tokens[start].type === "word" && KEYWORDS_SKIP.has(tokens[start].value) && tokens.slice(start + 1).some((t) => t.type === "word" || t.type === "group")) start += 1;
  const position = commandPosition(tokens.slice(start));
  if (position.unresolvedWrapperOption) return deny("other", "unresolved wrapper option");
  if (!position.command) return result; // assignments only
  let pos = position.index;
  let cmdWords = position.words.slice(pos);
  // A command word written with a variable (B=.../bin; $B/fm-send.sh) is read with the
  // variables this command assigned; an unknown variable in front of an fm-*.sh name stays
  // checkable by that name.
  if (cmdWords[0].subs.length === 0 && cmdWords[0].value.includes("$")) {
    const expanded = expandVars(cmdWords[0].value, ctx, state.vars);
    cmdWords = [{ ...cmdWords[0], value: expanded, literal: !expanded.includes("$") }, ...cmdWords.slice(1)];
  }
  let name = path.basename(cmdWords[0].value);
  if (name === "rtk" && cmdWords[1]) { cmdWords = cmdWords.slice(1); name = path.basename(cmdWords[0].value); }
  const dynamicScript = /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?\/(?:bin\/)?(fm-[a-z0-9-]+\.sh)$/.exec(cmdWords[0].value);
  if (!cmdWords[0].literal && !dynamicScript) return deny("other", "dynamic command word");
  const display = describe(name, cmdWords.slice(1));

  if (KEYWORDS_BARE.has(cmdWords[0].value) && cmdWords.length === 1) return result;
  if (cmdWords[0].value === "for" || cmdWords[0].value === "select") return result; // header: words and substitutions were classified above
  if (cmdWords[0].value === "case") return deny("other", "case statement");

  // fm-* script: bare name or a bin/ path, exact.
  const script = scriptName(cmdWords[0]) || (dynamicScript || [])[1];
  if (script) return ALLOWED_SCRIPTS.has(script) ? result : deny(script === "fm-test-run.sh" || script.includes("test") ? "run-script" : "other-script", describe(script, cmdWords.slice(1)));
  if (name === "bash" || name === "sh") {
    const args = cmdWords.slice(1).filter((w) => !w.value.startsWith("-"));
    if (cmdWords.some((w) => w.value === "-c")) {
      const idx = cmdWords.findIndex((w) => w.value === "-c");
      const payload = cmdWords[idx + 1];
      if (payload && payload.literal && payload.subs.length === 0) return worse(result, classifyProgram(payload.value, { ...state }, depth + 1));
      return deny("run-script", `${name} -c <dynamic>`);
    }
    const target = scriptName(args[0]);
    if (target && ALLOWED_SCRIPTS.has(target)) return result;
    return deny("run-script", display);
  }

  if (name === "gh" || name === "gh-axi") return worse(result, ghVerdict(name, cmdWords));
  if (name === "tasks-axi" || name === "quota-axi") return result;
  if (BUILTINS.has(name)) {
    if (name === "export" || name === "declare" || name === "local") {
      for (const w of cmdWords.slice(1)) {
        const m = w.subs.length === 0 ? w.value.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s) : null;
        if (m) state.vars[m[1]] = m[2];
      }
    }
    return result;
  }
  if (FILTERS.has(name)) return result;

  if (READERS.has(name)) {
    const operands = name === "find" ? findRoots(cmdWords) : readerOperands(name, cmdWords);
    if (operands.length === 0) {
      // A bare reader reads its pipe, except ls and find, which read the cwd.
      if (state.piped && name !== "ls" && name !== "find") return result;
      if (cwd && isFleetRecord(cwd, ctx)) return result;
      return deny(cwd ? groupOfPath(cwd, ctx) : "other", display);
    }
    for (const operand of operands) {
      const abs = resolvePath(operand, cwd, ctx, state.vars);
      if (abs && isArtifactHtml(abs)) return deny("artifact-read", display);
      if (!abs || !(isFleetRecord(abs, ctx) || isHarnessOutput(abs))) return deny(abs ? groupOfPath(abs, ctx) : "other", abs ? display : `${display} <dynamic path>`);
    }
    return result;
  }
  if (WRITERS.has(name)) {
    const operands = cmdWords.slice(1).filter((w) => !(w.value.startsWith("-") && w.value.length > 1) && !/^[0-7]{3,4}$/.test(w.value));
    if (operands.length === 0 && name !== "tee") return deny("project-edit", display);
    for (const operand of operands) {
      const abs = resolvePath(operand, cwd, ctx, state.vars);
      if (!abs || !isFleetRecord(abs, ctx)) return deny("project-edit", `${display} ${abs ? path.basename(abs) : "<dynamic path>"}`);
    }
    return result;
  }

  return deny(commandGroup(name, cmdWords), display);
}

function findRoots(words) {
  const roots = [];
  for (let i = 1; i < words.length; i += 1) {
    if (words[i].value.startsWith("-") || words[i].value === "(" || words[i].value === "!") break;
    roots.push(words[i]);
  }
  return roots;
}

function commandGroup(name, words) {
  if (/^(psql|psql-\d+|pg_connection\.sh|sqlite3|pg_dump|pgcli)$/.test(name)) return "prod-db";
  if (/^(doctl|vercel|terraform|kubectl|aws|make)$/.test(name)) return "prod-ops";
  if (name === "git") return "project-read";
  if (/^(sleep|until|watch)$/.test(name)) return "poll-loop";
  if (/^(python3?|node|npm|npx|pnpm|yarn|bun|pytest|cargo|go|tsc|jest|vitest|ruby|perl|uv|pip3?)$/.test(name)) return "run-script";
  if (name === "chrome-devtools-axi") return "browser";
  if (/^(curl|wget|http)$/.test(name)) return "web";
  if (name === "herdr" || name === "treehouse" || name === "ps" || name === "pgrep" || name === "lsof") return "process-inspect";
  return "other";
}

// A program: nodes split at control operators. state.piped marks a pipeline consumer.
function classifyProgram(source, state, depth) {
  if (depth > 6) return deny("other", "nesting too deep");
  const lexer = new Lexer(source);
  const { tokens, error } = lexer.tokenize();
  if (error) return deny("other", `unparseable shell: ${error}`);
  // Walk the tokens so each node knows the operator before it.
  let result = allow();
  let current = [];
  let piped = false;
  const flush = () => {
    if (current.length === 0) return;
    result = worse(result, classifyNode(current, { ...state, piped }, depth));
    current = [];
  };
  for (const token of tokens) {
    if (token.type === "op") {
      // A cd moves the cwd for the commands after it at this level.
      const words = current.filter((t) => t.type === "word");
      if (words[0] && words[0].value === "cd" && token.value !== "|" && token.value !== "&") {
        state.cwd = words[1] ? resolvePath(words[1], state.cwd, state.ctx, state.vars) : null;
      }
      flush();
      piped = token.value === "|" || token.value === "|&";
      continue;
    }
    current.push(token);
  }
  flush();
  return result;
}

function toolPath(input) {
  return input.file_path || input.path || input.notebook_path || "";
}

export function classifyCall(payload, ctx) {
  const tool = String(payload.tool_name || payload.toolName || "");
  const input = payload.tool_input || payload.toolInput || {};
  const cwd = typeof payload.cwd === "string" && payload.cwd ? payload.cwd : ctx.home;
  const abs = (p) => (p ? (path.isAbsolute(p) ? path.normalize(p) : path.normalize(path.join(cwd, p))) : "");

  if (tool === "Bash") {
    const command = String(input.command ?? "");
    if (!command.trim()) return allow();
    return classifyProgram(command, { cwd, ctx, piped: false, vars: {} }, 0);
  }
  if (TOOLS_ALLOWED.has(tool)) return allow();
  if (tool === "Read") {
    const p = abs(toolPath(input));
    if (p && MEDIA.test(p)) return allow();
    if (p && !isArtifactHtml(p) && (isFleetRecord(p, ctx) || isHarnessOutput(p))) return allow();
    return deny(groupOfPath(p, ctx), `Read ${p ? path.basename(p) : ""}`);
  }
  if (tool === "Grep" || tool === "Glob") {
    const p = abs(input.path || cwd);
    if (isFleetRecord(p, ctx) && !isArtifactHtml(p)) return allow();
    return deny(groupOfPath(p, ctx), `${tool} ${path.basename(p)}`);
  }
  if (tool === "Edit" || tool === "Write" || tool === "NotebookEdit" || tool === "MultiEdit") {
    const p = abs(toolPath(input));
    if (p && isFleetRecord(p, ctx)) return allow();
    const group = /\/(\.claude[^/]*|sys-config)\//.test(p) || /settings(\.local)?\.json$/.test(p) ? "config-edit" : "project-edit";
    return deny(group, `${tool} ${p ? path.basename(p) : ""}`);
  }
  if (tool === "Artifact") {
    const action = String(input.action || (input.file_path ? "publish" : ""));
    if (action === "list") return quick("Artifact list");
    if (action === "publish") {
      const p = abs(input.file_path || "");
      const underMate = ctx.mateHomes.some((h) => p.startsWith(`${h}/data/`));
      const workerReport = /\/data\/[^/]+\/report[^/]*$/.test(p);
      if (p && (underMate || workerReport)) return allow();
      return deny("artifact-publish", `Artifact publish ${p ? path.basename(p) : ""}`);
    }
    return deny(action === "read" ? "artifact-read" : "artifact-other", `Artifact ${action}`);
  }
  if (/^(Agent|Workflow|Task|TaskCreate|TaskOutput|TaskStop|SendMessage|Monitor|CronCreate|CronDelete|RemoteTrigger|EnterWorktree)$/.test(tool)) return deny("subagent", tool);
  if (tool.startsWith("mcp__")) {
    const server = tool.split("__")[1] || "mcp";
    const group = /chrome|browser|playwright|puppeteer/i.test(server) ? "browser" : "mcp";
    return deny(group, tool);
  }
  if (tool === "WebSearch" || tool === "WebFetch") return deny("web", tool);
  return deny("other", tool || "unknown tool");
}

function parseArguments(argv) {
  const args = { home: "" };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--home") args.home = argv[++i] || "";
  }
  return args;
}

function invokedDirectly() {
  try {
    return realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
  } catch { return false; }
}

if (invokedDirectly()) {
  const args = parseArguments(process.argv.slice(2));
  let raw = "";
  try { raw = readFileSync(0, "utf8"); } catch { process.exit(3); }
  let payload;
  try { payload = JSON.parse(raw); } catch { process.exit(3); }
  if (!payload || typeof payload !== "object" || !args.home) process.exit(3);
  const verdict = classifyCall(payload, makeContext(args.home));
  process.stdout.write(`${JSON.stringify(verdict)}\n`);
}
