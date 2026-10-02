// Drive the real branch dispatcher (.pi/extensions/lib/fm-branch-dispatch.ts)
// against a seeded lab state dir holding a silent-handled wake row.
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { pathToFileURL } from "node:url";
const { scopeForUnreadWake, branchOfferForWake } = await import(pathToFileURL(`${process.cwd()}/.pi/extensions/lib/fm-branch-dispatch.ts`).href);
const home = mkdtempSync(`${tmpdir()}/fm-lab.`); const state = `${home}/state`; mkdirSync(state);
writeFileSync(`${state}/t1.meta`, `project=${home}/projects/p\nwindow=t1-window\nkind=ship\n`);
writeFileSync(`${state}/t1.status`, "working: on it\n");
const show = (label, v) => console.log(`${label}: ${JSON.stringify(v)}`);
writeFileSync(`${state}/.wake-queue`, [
  "1\t1\tsignal\tt1.status\tsignal: t1.status",
  "1\t2\tsignal\tt1.silent-handled.027\tsignal: t1.silent-handled.027 (request 027.msg was moved to handled/ with no status line appended since it arrived)",
].join("\n") + "\n");
show("A scope (status row + silent-handled row for live task t1)", scopeForUnreadWake(state, false));
show("A offer for silent-handled trigger", branchOfferForWake(state, "signal: t1.silent-handled.027 (request 027.msg was moved to handled/ with no status line appended since it arrived)", false));
// Task torn down: its rows are pruned by fm_wake_queue_prune_task; an unpruned
// row for an unknown task is still treated as unsafe (control).
writeFileSync(`${state}/.wake-queue`, "1\t3\tsignal\tghost.silent-handled.031\tsignal: ghost.silent-handled.031\n");
show("B control: silent-handled row for a task with no meta", scopeForUnreadWake(state, false));
rmSync(home, { recursive: true, force: true });
