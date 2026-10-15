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
// deny reason is a fixed string that never contains a token value.
// Untokenizable syntax fails open: the threat model is an agent mistake, which
// always tokenizes.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const TOKEN = "OP_SERVICE_ACCOUNT_TOKEN";
const MAX_DEPTH = 8;

const REASONS = {
  "op-bare-call":
    "a bare `op` call is refused: without OP_SERVICE_ACCOUNT_TOKEN, op falls back to the 1Password desktop app and pops its full-account 'allow CLI access' prompt. Agents may only use the vault-scoped service account. Load its token in the same command, for example: export OP_SERVICE_ACCOUNT_TOKEN=\"$(. \"$FM_ROOT/bin/fm-op-service-account-lib.sh\" && fm_op_service_account_token \"$FM_HOME\")\" && op ... (bin/fm-op-service-account-lib.sh reads the token from the environment, then the home .env files). If no token is found, ask for one instead of using the desktop app.",
};

const SHELLS = new Set(["sh", "bash", "zsh", "dash", "ksh"]);
// Words that run their next non-option word as a command but that
// commandPosition does not unwrap.
const PASSTHROUGH = new Set(["builtin", "time", "nice", "xargs", "stdbuf", "ionice"]);

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

function exportsToken(name, args) {
  if (name === "export") {
    return args.some((word) => word.value === TOKEN || setsToken(word));
  }
  if (name === "declare" || name === "typeset") {
    const exporting = args.some((word) => /^-[A-Za-z]*x/.test(word.value));
    return exporting && args.some((word) => word.value === TOKEN || setsToken(word));
  }
  return false;
}

// Returns true when `command` calls op without the token. `state.loaded` is the
// token's presence entering the command and is updated by an `export`.
function violates(command, state, depth) {
  if (depth > MAX_DEPTH) return false;
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) return false;
  const { nodes } = splitProgram(lexed.tokens);
  for (const node of nodes) {
    for (const token of node) {
      if (token.type === "group" && violates(token.content, { loaded: state.loaded }, depth + 1)) return true;
      if (token.type === "word") {
        for (const sub of token.subs) {
          if (violates(sub.content, { loaded: state.loaded }, depth + 1)) return true;
        }
      }
    }
    const position = commandPosition(node);
    if (isCommandQuery(position)) continue;
    const loaded = tokenAfterPrefix(position.words.slice(0, position.index), state.loaded);
    let index = position.index;
    let word = position.words[index];
    while (word && PASSTHROUGH.has(base(word.value))) {
      index += 1;
      while (position.words[index] && /^-/.test(position.words[index].value)) index += 1;
      word = position.words[index];
    }
    if (!word) continue;
    const name = base(word.value);
    const args = position.words.slice(index + 1);
    if (exportsToken(name, args)) {
      state.loaded = true;
      continue;
    }
    if (name === "op") {
      if (!loaded) return true;
      continue;
    }
    if (SHELLS.has(name)) {
      for (let i = 0; i < args.length; i += 1) {
        if (!/^-[A-Za-z]*c[A-Za-z]*$/.test(args[i].value)) continue;
        const payload = args[i + 1];
        if (payload?.literal && violates(payload.value, { loaded }, depth + 1)) return true;
        break;
      }
    } else if (name === "eval") {
      const payloads = args.filter((arg) => arg.literal);
      if (payloads.length === args.length && args.length > 0 && violates(payloads.map((arg) => arg.value).join(" "), { loaded }, depth + 1)) return true;
    }
    for (const payload of position.wrapperPayloads) {
      if (violates(payload, { loaded }, depth + 1)) return true;
    }
  }
  return false;
}

function decision(command) {
  if (violates(command, { loaded: false }, 0)) return { decision: "deny", code: "op-bare-call", reason: REASONS["op-bare-call"] };
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
