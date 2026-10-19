#!/usr/bin/env node
// Fork-only: policy for the op guard - does a shell command call the 1Password
// `op` CLI without the service account token loaded? (applypass fork)
//
// Without OP_SERVICE_ACCOUNT_TOKEN, `op` falls back to the 1Password desktop app
// and pops its full-account "allow CLI access" prompt. Agents must only use the
// vault-scoped service account, so this policy denies a command whose executed
// word is `op` unless that same command, or an earlier `export` on the same
// command line, supplies OP_SERVICE_ACCOUNT_TOKEN. The environment check and the
// harness transport live in bin/fm-op-pretool-check.sh.
//
// The shell tokenizer and command-position analysis come from
// bin/fm-arm-command-policy.mjs, so this guard never duplicates shell lexing.
// It never evaluates, expands, sources, or runs any byte of the command, and the
// deny reason names only this checkout's loader path, never a token value.
// Untokenizable syntax fails open: the threat model is an agent mistake, which
// always tokenizes.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const TOKEN = "OP_SERVICE_ACCOUNT_TOKEN";
const MAX_DEPTH = 8;

const BIN_DIR = dirname(fileURLToPath(import.meta.url));
const FM_ROOT = dirname(BIN_DIR);
const LOADER = `${BIN_DIR}/fm-op-service-account-lib.sh`;
const LOAD_EXAMPLE = `OP_SERVICE_ACCOUNT_TOKEN=$(. "${LOADER}" && fm_op_service_account_token "\${FM_HOME:-${FM_ROOT}}") && export OP_SERVICE_ACCOUNT_TOKEN && op ...`;

const REASONS = {
  "op-bare-call":
    `a bare \`op\` call is refused: without OP_SERVICE_ACCOUNT_TOKEN, op falls back to the 1Password desktop app and pops its full-account 'allow CLI access' prompt. Agents may only use the vault-scoped service account. Load its token in the same command, for example: ${LOAD_EXAMPLE} (fm-op-service-account-lib.sh reads the token from the environment, then the home .env files, and the line stops before op when no token is found). If no token is found, ask for one instead of using the desktop app.`,
};

const SHELLS = new Set(["sh", "bash", "zsh", "dash", "ksh"]);
// Words that run their next non-option word as a command but that
// commandPosition does not unwrap, each with the options that take a
// separate argument.
const PASSTHROUGH = new Map([
  ["builtin", []],
  ["time", ["-f", "-o"]],
  ["nice", ["-n", "--adjustment"]],
  ["xargs", ["-n", "-I", "-P", "-L", "-s", "-d", "-a", "-E"]],
  ["stdbuf", ["-i", "-o", "-e"]],
  ["ionice", ["-c", "-n", "-p"]],
]);
// Shell reserved words that may lead a node without being its command.
const RESERVED = new Set(["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "select", "!"]);

// True for a `TOKEN=value` word whose value is non-empty, counting a value that
// is only a substitution such as "$(cat file)".
function setsToken(word) {
  return word.value.startsWith(`${TOKEN}=`) && (word.value.length > TOKEN.length + 1 || word.subs.length > 0);
}

function base(value) {
  return value.split("/").at(-1);
}

// Walks the env-style words before the command (prefix assignments and
// `env` options) and returns whether the token ends up set and non-empty.
function tokenAfterPrefix(words, loaded) {
  let result = loaded;
  for (let i = 0; i < words.length; i += 1) {
    const value = words[i].value;
    if (value === "-i" || value === "--ignore-environment" || value === "-") result = false;
    else if ((value === "-u" || value === "--unset") && words[i + 1]?.value === TOKEN) {
      result = false;
      i += 1;
    } else if (value === `--unset=${TOKEN}`) result = false;
    else if (value.startsWith(`${TOKEN}=`)) result = setsToken(words[i]);
  }
  return result;
}

function isCommandQuery(position) {
  let sawCommand = false;
  for (const word of position.words.slice(position.prefixAssignments, position.index)) {
    if (word.value === "command") {
      sawCommand = true;
      continue;
    }
    if (sawCommand && /^-[^-]*[vV]/.test(word.value)) return true;
  }
  return false;
}

// Applies an `export`/`declare` node to `state` and returns true when it named
// the token. A name-only export loads the token only when an earlier
// assignment in this walk set it; `export -n` and `declare +x` unload it.
function applyExport(name, args, state) {
  let exporting;
  if (name === "export") exporting = !args.some((word) => /^-[A-Za-z]*n/.test(word.value));
  else if (name === "declare" || name === "typeset") {
    exporting = args.some((word) => /^-[A-Za-z]*x/.test(word.value)) && !args.some((word) => /^\+[A-Za-z]*x/.test(word.value));
  } else return false;
  const named = args.find((word) => word.value === TOKEN || word.value.startsWith(`${TOKEN}=`));
  if (!named) return false;
  if (named.value !== TOKEN) state.assigned = setsToken(named);
  state.loaded = exporting && state.assigned;
  return true;
}

function fork(state) {
  return { loaded: state.loaded, assigned: state.assigned };
}

function stripReserved(node) {
  let start = 0;
  while (node[start]?.type === "word" && RESERVED.has(node[start].value)) start += 1;
  return start === 0 ? node : node.slice(start);
}

// Returns true when `command` calls op without the token. `state.loaded` is the
// token's exported presence entering the command and `state.assigned` its
// shell-variable value; an assignment or `export` node updates them.
function violates(command, state, depth) {
  if (depth > MAX_DEPTH) return false;
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return false;
  const { nodes } = splitProgram(lexed.tokens);
  for (const rawNode of nodes) {
    for (const token of rawNode) {
      if (token.type === "group" && violates(token.content, fork(state), depth + 1)) return true;
      if (token.type === "word") {
        for (const sub of token.subs) {
          if (violates(sub.content, fork(state), depth + 1)) return true;
        }
      }
    }
    const node = stripReserved(rawNode);
    if (node.length === 0) continue;
    const position = commandPosition(node);
    if (isCommandQuery(position)) continue;
    if (position.index === position.words.length) {
      for (const word of position.words) {
        if (!word.value.startsWith(`${TOKEN}=`)) continue;
        state.assigned = setsToken(word);
        state.loaded = state.loaded && state.assigned;
      }
      continue;
    }
    const loaded = tokenAfterPrefix(position.words.slice(0, position.index), state.loaded);
    let index = position.index;
    let word = position.words[index];
    while (word && PASSTHROUGH.has(base(word.value))) {
      const valued = PASSTHROUGH.get(base(word.value));
      index += 1;
      while (position.words[index] && /^-/.test(position.words[index].value)) {
        const option = position.words[index];
        index += 1;
        if (valued.includes(option.value) && node[node.indexOf(option) + 1]?.type === "word") index += 1;
      }
      word = position.words[index];
    }
    if (!word) continue;
    const name = base(word.value);
    const args = position.words.slice(index + 1);
    if (applyExport(name, args, state)) continue;
    if (name === "op") {
      if (!loaded) return true;
      continue;
    }
    if (SHELLS.has(name)) {
      for (let i = 0; i < args.length; i += 1) {
        if (!/^-[A-Za-z]*c[A-Za-z]*$/.test(args[i].value)) continue;
        const payload = args[i + 1];
        if (payload && payload.subs.length === 0 && violates(payload.value, { loaded, assigned: loaded }, depth + 1)) return true;
        break;
      }
    } else if (name === "eval") {
      if (args.length > 0 && args.every((arg) => arg.subs.length === 0) && violates(args.map((arg) => arg.value).join(" "), { loaded, assigned: state.assigned }, depth + 1)) return true;
    }
    for (const payload of position.wrapperPayloads) {
      if (violates(payload, { loaded, assigned: state.assigned }, depth + 1)) return true;
    }
  }
  return false;
}

function decision(command) {
  if (violates(command, { loaded: false, assigned: false }, 0)) return { decision: "deny", code: "op-bare-call", reason: REASONS["op-bare-call"] };
  return { decision: "allow" };
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command") {
      if (i + 1 >= argv.length) throw new Error("--command requires a value");
      result.command = argv[i + 1];
      result.commandSet = true;
      i += 1;
      continue;
    }
    if (name.startsWith("--command=")) {
      result.command = name.slice("--command=".length);
      result.commandSet = true;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (!args.commandSet || !args.command) {
      process.stdout.write("allow\n");
    } else {
      const result = decision(args.command);
      if (result.decision === "allow") {
        process.stdout.write("allow\n");
      } else {
        process.stdout.write(`deny\t${result.code}\t${result.reason}\n`);
      }
    }
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

export { decision };
