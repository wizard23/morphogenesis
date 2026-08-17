#!/usr/bin/env node
// Tier 2 gate: zero page errors (hard); per phase APP alloc bytes/sec and DOM mutations/frame
// ≤ ceilings in bench/thresholds.json → browser.<mode> (created from the first run × 1.25;
// ratchet toward 0/0 — the 0/0/0 hot-loop rule, docs/principles/kaizen.md).
//   node bench/browser-assert.mjs [--set-thresholds]      GPU=1 for the real-adapter profile
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";
import { runBrowserBench, printBrowserResults } from "./browser-bench.mjs";
import { REPO_ROOT } from "./lib/wasm-host.mjs";

const THRESHOLDS_PATH = path.join(REPO_ROOT, "bench", "thresholds.json");
const FACTOR = 1.25;
const setThresholds = process.argv.includes("--set-thresholds");
const failures = [], warnings = [];
const fail = (m) => { failures.push(m); console.log(`  ❌ ${m}`); };
const ok = (m) => console.log(`  ✅ ${m}`);
const warn = (m) => { warnings.push(m); console.log(`  ⚠️  ${m}`); };

const run = await runBrowserBench();
printBrowserResults(run);
const perFrame = (r) => r.probes.domMutations / Math.max(1, r.ring.frames);

console.log("\n== gate ==");
run.pageErrors.length ? fail(`${run.pageErrors.length} page/console error(s): ${run.pageErrors[0]}`) : ok("no page errors");
run.adapter.isolated ? ok("cross-origin isolated (5 µs timers)") : warn("not cross-origin isolated — timer resolution 100 µs");

const all = existsSync(THRESHOLDS_PATH) ? JSON.parse(readFileSync(THRESHOLDS_PATH, "utf8")) : {};
all.browser ??= {};
const t = all.browser[run.mode];
if (setThresholds || !t) {
  all.browser[run.mode] = {
    _note: `APP alloc B/s and DOM mutations/frame ceilings = first run × ${FACTOR}; ratchet toward 0 after kept wins.`,
    _setFrom: { machine: run.machine.machineId, git: run.machine.gitSha, adapter: `${run.adapter.vendor}/${run.adapter.architecture}`, time: run.machine.timestamp },
    phases: Object.fromEntries(run.results.map((r) => [r.name, { appBytesPerSecMax: Math.ceil(r.heap.appBytesPerSec * FACTOR), domMutationsPerFrameMax: +(perFrame(r) * FACTOR).toFixed(2) }])),
  };
  writeFileSync(THRESHOLDS_PATH, JSON.stringify(all, null, 2) + "\n");
  console.log(`  browser thresholds for mode '${run.mode}' ${t ? "rewritten" : "created"} → bench/thresholds.json`);
} else {
  for (const r of run.results) {
    const c = t.phases[r.name];
    if (!c) { warn(`${r.name}: no thresholds`); continue; }
    r.heap.appBytesPerSec > c.appBytesPerSecMax ? fail(`${r.name}: APP alloc ${(r.heap.appBytesPerSec / 1024).toFixed(1)} KB/s > ${(c.appBytesPerSecMax / 1024).toFixed(1)} KB/s`) : ok(`${r.name}: APP alloc ${(r.heap.appBytesPerSec / 1024).toFixed(1)} KB/s ≤ ${(c.appBytesPerSecMax / 1024).toFixed(1)}`);
    perFrame(r) > c.domMutationsPerFrameMax ? fail(`${r.name}: DOM ${perFrame(r).toFixed(2)}/frame > ${c.domMutationsPerFrameMax}`) : ok(`${r.name}: DOM ${perFrame(r).toFixed(2)}/frame ≤ ${c.domMutationsPerFrameMax}`);
  }
}
console.log(`\n${failures.length ? "GATE FAIL" : "GATE PASS"} — ${failures.length} failure(s), ${warnings.length} warning(s)`);
process.exitCode = failures.length ? 1 : 0;
