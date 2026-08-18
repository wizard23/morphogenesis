#!/usr/bin/env node
// Tier 2 gate: zero page errors (hard); per phase APP alloc bytes/FRAME and DOM mutations/frame
// ≤ ceilings in bench/thresholds.json → browser.<mode> (created from the first run × 1.25;
// ratchet toward 0/0 — the 0/0/0 hot-loop rule, docs/principles/kaizen.md). Per frame, not per
// second: frame rate moves with sim speed and must not change the verdict on the render path.
//   node bench/browser-assert.mjs [--set-thresholds]      GPU=1 for the real-adapter profile
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";
import { runBrowserBench, printBrowserResults } from "./browser-bench.mjs";
import { REPO_ROOT } from "./lib/wasm-host.mjs";

const THRESHOLDS_PATH = path.join(REPO_ROOT, "bench", "thresholds.json");
const FACTOR = 1.25;
// One HeapProfiler sample (4 KB) over a ~500-frame window ≈ 8 B/frame: below this the metric is
// sampler noise, so no ceiling is set lower (a literal 0 would fail on a single stray sample).
const BYTES_PER_FRAME_FLOOR = 8;
const setThresholds = process.argv.includes("--set-thresholds");
const failures = [], warnings = [];
const fail = (m) => { failures.push(m); console.log(`  ❌ ${m}`); };
const ok = (m) => console.log(`  ✅ ${m}`);
const warn = (m) => { warnings.push(m); console.log(`  ⚠️  ${m}`); };

const run = await runBrowserBench();
printBrowserResults(run);
// frames actually rendered in the window ≈ duration × fps (the ring caps at 512 entries)
const framesInWindow = (r) => Math.max(1, (r.durationMs / 1000) * (r.ring.fps || 0), r.ring.frames);
// DOM mutations are gated per SECOND: the only intended source is the status line at 4 Hz (fixed
// rate, independent of fps), so a per-frame ceiling would depend on the frame rate.
const domPerSec = (r) => r.probes.domMutations / (r.durationMs / 1000);
const DOM_PER_SEC_FLOOR = 6; // 4 Hz status line + slack
const bytesPerFrame = (r) => r.heap.appBytes / framesInWindow(r);

console.log("\n== gate ==");
run.pageErrors.length ? fail(`${run.pageErrors.length} page/console error(s): ${run.pageErrors[0]}`) : ok("no page errors");
run.adapter.isolated ? ok("cross-origin isolated (5 µs timers)") : warn("not cross-origin isolated — timer resolution 100 µs");

const all = existsSync(THRESHOLDS_PATH) ? JSON.parse(readFileSync(THRESHOLDS_PATH, "utf8")) : {};
all.browser ??= {};
const t = all.browser[run.mode];
if (setThresholds || !t) {
  all.browser[run.mode] = {
    _note: `APP alloc bytes/frame (floor ${BYTES_PER_FRAME_FLOOR}) and DOM mutations/second (floor ${DOM_PER_SEC_FLOOR}: the 4 Hz status line) ceilings = first run × ${FACTOR}; ratchet after kept wins.`,
    _setFrom: { machine: run.machine.machineId, git: run.machine.gitSha, adapter: `${run.adapter.vendor}/${run.adapter.architecture}`, time: run.machine.timestamp },
    phases: Object.fromEntries(run.results.map((r) => [r.name, { appBytesPerFrameMax: Math.max(BYTES_PER_FRAME_FLOOR, Math.ceil(bytesPerFrame(r) * FACTOR)), domMutationsPerSecMax: Math.max(DOM_PER_SEC_FLOOR, Math.ceil(domPerSec(r) * FACTOR)) }])),
  };
  writeFileSync(THRESHOLDS_PATH, JSON.stringify(all, null, 2) + "\n");
  console.log(`  browser thresholds for mode '${run.mode}' ${t ? "rewritten" : "created"} → bench/thresholds.json`);
} else {
  for (const r of run.results) {
    const c = t.phases[r.name];
    if (!c) { warn(`${r.name}: no thresholds`); continue; }
    if (c.appBytesPerFrameMax === undefined) { warn(`${r.name}: thresholds predate the bytes/frame metric — rerun with --set-thresholds`); continue; }
    bytesPerFrame(r) > c.appBytesPerFrameMax ? fail(`${r.name}: APP alloc ${bytesPerFrame(r).toFixed(0)} B/frame > ${c.appBytesPerFrameMax}`) : ok(`${r.name}: APP alloc ${bytesPerFrame(r).toFixed(0)} B/frame ≤ ${c.appBytesPerFrameMax}`);
    if (c.domMutationsPerSecMax === undefined) { warn(`${r.name}: thresholds predate the DOM/sec metric — rerun with --set-thresholds`); continue; }
    domPerSec(r) > c.domMutationsPerSecMax ? fail(`${r.name}: DOM ${domPerSec(r).toFixed(1)}/s > ${c.domMutationsPerSecMax}`) : ok(`${r.name}: DOM ${domPerSec(r).toFixed(1)}/s ≤ ${c.domMutationsPerSecMax}`);
  }
}
console.log(`\n${failures.length ? "GATE FAIL" : "GATE PASS"} — ${failures.length} failure(s), ${warnings.length} warning(s)`);
process.exitCode = failures.length ? 1 : 0;
