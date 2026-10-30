#!/usr/bin/env node
// Fork-only: policy for the read-only side session (bin/fm-ask.sh) - does this tool call only read? (applypass fork)
//
// A side session answers questions from a home's records and changes nothing:
// no send, spawn, merge, drain, hold, decide, backlog write, teardown, control
// call, or file write. bin/fm-ask-pretool-check.sh passes each PreToolUse
// payload on stdin and this policy decides. Unlike the cd and op guards, which
// block one named mistake and fail open, this policy is an allowlist and fails
// closed: a call it cannot classify is refused.
//
//   tool        rule
//   Read        a file under the home, never a .env or key file
//   Grep, Glob  a path or absolute pattern under the home (a relative one
//               searches only the scratch directory the session starts in)
//   Bash        every command in the line must be a read-only command from the
//               lists below; output redirection only to /dev/null; no shell
//               re-entry (bash -c, eval, source, xargs, env); no variable
//               command word; substitutions are checked recursively. A system
//               command's arguments and input redirects are literal, and any
//               absolute, ~, or .. path among them must be under the home and
//               not a secret file; git takes no global option but -C <path>
//               and --no-pager, and no option that runs a program or writes
//   anything else (Edit, Write, NotebookEdit, Agent, MCP, ...) is refused
//
// One exception to "changes nothing": in a session on a second mate's home, bin/fm-ask-order.sh
// queues the captain's order to that mate's steering inbox through bin/fm-send.sh. Its target is
// fixed by the session environment (FM_ASK_ORDER_TARGET), never by the caller.
//
// The shell tokenizer and command-position analysis come from
// bin/fm-arm-command-policy.mjs, so this guard never duplicates shell lexing.
// It never evaluates, expands, sources, or runs any byte of the command.
//
// Output: one line, "allow" or "deny<TAB><code><TAB><reason>".
// Usage: <payload JSON on stdin> | node fm-ask-command-policy.mjs --home <home>

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const MAX_DEPTH = 8;
const HAND_OFF = "Hand the order to the real firstmate or the second mate that owns the work; this session only reads.";

// Mutating firstmate scripts, named so the refusal tells the model what it hit.
const MUTATING_SCRIPTS = new Set([
  "fm-send.sh", "fm-spawn.sh", "fm-pr-merge.sh", "fm-merge-local.sh", "fm-wake-drain.sh",
  "fm-captain-hold.sh", "fm-decision-hold.sh", "fm-decide.sh", "fm-teardown.sh", "fm-control.sh",
  "fm-secondmate-report.sh", "fm-brief.sh", "fm-promote.sh", "fm-scout.sh", "fm-inbox.sh",
  "fm-session-start.sh", "fm-lock.sh", "fm-watch.sh", "fm-watch-arm.sh", "fm-release.sh",
  "fm-backlog-handoff.sh", "fm-home-seed.sh", "fm-update.sh",
]);

// Read-only firstmate scripts. fm-tasks-axi.sh is read-only only for the
// subcommands in TASKS_READ.
const READ_SCRIPTS = new Set([
  "fm-crew-state.sh", "fm-fleet-view.sh", "fm-peek.sh", "fm-project-mode.sh", "fm-tasks-axi.sh",
]);
const TASKS_READ = new Set(["list", "show", "view", "--help", "-h"]);

// Read-only system commands. Anything that can run another program (sed with e,
// awk with system, xargs, env, tee, ssh, tmux, ...) is left out on purpose.
const SYSTEM_COMMANDS = new Set([
  "cat", "head", "tail", "ls", "grep", "egrep", "fgrep", "rg", "wc", "jq", "date", "stat", "sort", "uniq",
  "cut", "tr", "basename", "dirname", "readlink", "realpath", "pwd", "echo", "printf", "test", "[", "true",
  "false", "file", "du", "nl", "column", "diff", "cmp", "tac", "rev", "paste", "comm", "sleep", "whoami",
  "hostname", "uname", "which", "find", "git",
]);
const SYSTEM_DIRS = ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"];

const FIND_WRITERS = new Set(["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"]);
const GIT_READ = new Set(["log", "show", "status", "diff", "rev-parse", "ls-files", "cat-file", "shortlog", "blame", "describe"]);
const GIT_RUNS_OR_WRITES = /^(-o|--output|--ext-diff|--textconv|--filters)(=|$)/;
// Commands that only print their arguments; their arguments are not paths to read.
const PRINT_ONLY = new Set(["echo", "printf"]);
// A file path that carries secrets is never read, even inside the home.
const SECRET_PATH = /(^|\/)(\.env($|[./])|[^/]*\.(pem|key|age)$|id_(rsa|ed25519)|[^/]*token[^/]*$)/i;

const REASONS = {
  "ask-mutation": (name) => `${name} changes the fleet and is refused in this read-only side session. ${HAND_OFF}`,
  "ask-not-allowed": (name) => `${name} is not on this read-only session's list of read commands. Use cat, head, tail, ls, grep, rg, jq, find, git log or show, or bin/fm-crew-state.sh, bin/fm-fleet-view.sh, bin/fm-peek.sh, bin/fm-tasks-axi.sh list|show. ${HAND_OFF}`,
  "ask-write": () => `writing to a file is refused in this read-only side session; only redirects to /dev/null are allowed. ${HAND_OFF}`,
  "ask-tool": (name) => `the ${name} tool is refused in this read-only side session; only Read, Grep, Glob, and read-only Bash run here. ${HAND_OFF}`,
  "ask-path": (name) => `${name} is outside this session's home or is a secret file; this session reads only the home's records. ${HAND_OFF}`,
  "ask-literal": (name) => `${name} cannot be checked against this session's home; write the path out in full. ${HAND_OFF}`,
  "ask-parse": () => `this command could not be read safely, so it is refused. Rewrite it as plain read-only commands. ${HAND_OFF}`,
};

class Refusal extends Error {
  constructor(code, subject) {
    super(code);
    this.code = code;
    this.subject = subject;
  }
}

function base(value) {
  return value.split("/").at(-1);
}

function nearestRealpath(path) {
  let current = resolve(path);
  const tail = [];
  while (!existsSync(current)) {
    const parent = dirname(current);
    if (parent === current) break;
    tail.unshift(basename(current));
    current = parent;
  }
  let real = current;
  try {
    real = realpathSync(current);
  } catch {
    // keep the lexical path
  }
  return join(real, ...tail);
}

function underHome(path, home) {
  const real = nearestRealpath(path);
  return real === home || real.startsWith(home + sep);
}

function checkPath(path, home, subject) {
  if (SECRET_PATH.test(path)) throw new Refusal("ask-path", subject);
  if (!isAbsolute(path) || !underHome(path, home)) throw new Refusal("ask-path", subject);
}

// The path part of an argument: the value of --opt=value, the attached value of
// a short option (-f/path), or the argument itself.
function argPath(value) {
  if (value.startsWith("--")) return value.includes("=") ? value.slice(value.indexOf("=") + 1) : "";
  if (value.startsWith("-")) {
    const attached = value.replace(/^-[A-Za-z0-9]*/, "");
    return attached.length > 1 ? attached : "";
  }
  return value;
}

// A relative path without .. stays in the scratch directory the session starts in.
function checkArgPath(path, context, subject) {
  let target = path;
  if (target === "~" || target.startsWith("~/")) target = homedir() + target.slice(1);
  if (target.startsWith("~")) throw new Refusal("ask-path", subject);
  if (isAbsolute(target)) return checkPath(target, context.home, subject);
  if (target.split("/").includes("..")) checkPath(resolve(context.cwd, target), context.home, subject);
}

function checkArgs(args, context) {
  for (const arg of args) {
    if (!arg.literal) throw new Refusal("ask-literal", "an argument built from a variable or substitution");
    if (arg.unquotedExpansion && arg.value.includes("{")) throw new Refusal("ask-literal", arg.value);
    checkArgPath(argPath(arg.value), context, arg.value);
  }
}

function checkRedirections(node, context) {
  for (let i = 0; i < node.length; i += 1) {
    const token = node[i];
    if (token.type !== "redir") continue;
    if (token.value === "<" && !token.inlineTarget) {
      const source = node[i + 1];
      if (!(source?.type === "word" && source.literal)) throw new Refusal("ask-literal", "an input redirect built from a variable or substitution");
      checkArgPath(source.value, context, source.value);
      continue;
    }
    const writes = [">", ">>", "<>", ">&", ">|", "&>", "&>>"].includes(token.value);
    if (!writes || token.inlineTarget) continue;
    const target = node[i + 1];
    if (!(target?.type === "word" && target.literal && target.value === "/dev/null")) throw new Refusal("ask-write", "redirect");
  }
}

function checkCommandName(word, args, context) {
  if (!word.literal) throw new Refusal("ask-not-allowed", "a command built from a variable or substitution");
  const value = word.value;
  const name = base(value);
  // The one mutation allowed: queue an order to the owning mate (bin/fm-ask-order.sh fixes the target).
  if (name === "fm-ask-order.sh") {
    if (!process.env.FM_ASK_ORDER_TARGET) throw new Refusal("ask-mutation", "an order (this session has no owning second mate)");
    return;
  }
  if (MUTATING_SCRIPTS.has(name)) throw new Refusal("ask-mutation", name);
  if (READ_SCRIPTS.has(name)) {
    if (name === "fm-tasks-axi.sh" && args.length > 0 && !TASKS_READ.has(args[0].value)) throw new Refusal("ask-mutation", `${name} ${args[0].value}`);
    return;
  }
  if (!SYSTEM_COMMANDS.has(name)) throw new Refusal("ask-not-allowed", name);
  if (value.includes("/") && !SYSTEM_DIRS.includes(dirname(value))) throw new Refusal("ask-not-allowed", value);
  if (name === "find" && args.some((arg) => FIND_WRITERS.has(arg.value))) throw new Refusal("ask-mutation", "find with an action that runs or writes");
  if (name === "rg" && args.some((arg) => /^--(pre|hostname-bin)(=|$)/.test(arg.value))) throw new Refusal("ask-not-allowed", "rg with an option that runs a program");
  if (name === "sort" && args.some((arg) => arg.value === "-o" || arg.value.startsWith("--output"))) throw new Refusal("ask-write", "sort -o");
  if (name === "git") {
    let i = 0;
    while (i < args.length && args[i].value.startsWith("-")) {
      if (args[i].value === "-C") i += 2;
      else if (args[i].value === "--no-pager") i += 1;
      else throw new Refusal("ask-not-allowed", `git ${args[i].value}`);
    }
    const sub = args[i]?.value;
    if (!sub || !GIT_READ.has(sub)) throw new Refusal("ask-not-allowed", `git ${sub ?? ""}`.trim());
    const runner = args.find((arg) => GIT_RUNS_OR_WRITES.test(arg.value));
    if (runner) throw new Refusal("ask-not-allowed", `git ${runner.value}`);
  }
  if (!PRINT_ONLY.has(name)) checkArgs(args, context);
}

// Shell reserved words that lead a node without being its command. A for or select header
// only names a variable and a word list (substitutions in it are checked above), so it runs nothing.
const RESERVED = new Set(["if", "then", "else", "elif", "fi", "while", "until", "do", "done", "!"]);
function stripReserved(node) {
  if (node[0]?.type === "word" && (node[0].value === "for" || node[0].value === "select")) return null;
  let start = 0;
  while (node[start]?.type === "word" && RESERVED.has(node[start].value)) start += 1;
  return start === 0 ? node : node.slice(start);
}

function checkNodes(command, depth, context) {
  if (depth > MAX_DEPTH) throw new Refusal("ask-parse", "");
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) throw new Refusal("ask-parse", "");
  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    for (const token of node) {
      if (token.type === "group") checkNodes(token.content, depth + 1, context);
      if (token.type === "word") for (const sub of token.subs) checkNodes(sub.content, depth + 1, context);
    }
    checkRedirections(node, context);
    const body = stripReserved(node);
    if (body === null || body.length === 0) continue;
    const position = commandPosition(body);
    if (position.unresolvedWrapperOption) throw new Refusal("ask-parse", "");
    if (position.wrappers.some((wrapper) => wrapper !== "command" && wrapper !== "timeout" && wrapper !== "gtimeout")) {
      throw new Refusal("ask-not-allowed", position.wrappers.find((wrapper) => wrapper !== "command" && wrapper !== "timeout" && wrapper !== "gtimeout"));
    }
    if (position.index >= position.words.length) continue; // assignments only
    // A prefix assignment would reach the command's environment, including the order target.
    if (position.prefixAssignments > 0) throw new Refusal("ask-not-allowed", "a command with a leading variable assignment");
    const word = position.words[position.index];
    const args = position.words.slice(position.index + 1);
    checkCommandName(word, args, context);
  }
}

function decide(payload, home) {
  const tool = String(payload.tool_name ?? payload.toolName ?? "");
  const input = payload.tool_input ?? payload.toolInput ?? {};
  switch (tool) {
    case "Bash":
      checkNodes(String(input.command ?? ""), 0, { home, cwd: String(payload.cwd ?? process.cwd()) });
      return;
    case "Read":
      checkPath(String(input.file_path ?? input.path ?? ""), home, "that file");
      return;
    case "Grep":
    case "Glob": {
      if (input.path) checkPath(String(input.path), home, "that path");
      const pattern = String(input.pattern ?? "");
      if (tool === "Glob" && isAbsolute(pattern)) checkPath(pattern.split(/[*?[{]/)[0] || "/", home, "that pattern");
      if (input.glob && isAbsolute(String(input.glob))) checkPath(String(input.glob), home, "that glob");
      return;
    }
    default:
      throw new Refusal("ask-tool", tool || "that");
  }
}

function parseArguments(argv) {
  let home = "";
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--home" && i + 1 < argv.length) {
      home = argv[i + 1];
      i += 1;
    } else throw new Error(`unknown argument: ${argv[i]}`);
  }
  if (!home) throw new Error("--home requires a value");
  return home;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return entry === fileURLToPath(import.meta.url);
  }
}

if (invokedDirectly()) {
  try {
    const home = nearestRealpath(parseArguments(process.argv.slice(2)));
    let payload;
    try {
      payload = JSON.parse(readFileSync(0, "utf8"));
    } catch {
      throw new Refusal("ask-parse", "");
    }
    decide(payload, home);
    process.stdout.write("allow\n");
  } catch (error) {
    if (error instanceof Refusal) {
      process.stdout.write(`deny\t${error.code}\t${REASONS[error.code](error.subject)}\n`);
    } else {
      process.stderr.write(`${error.message}\n`);
      process.exitCode = 1;
    }
  }
}

export { decide, Refusal };
