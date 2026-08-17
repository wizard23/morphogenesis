#!/usr/bin/env node
// Tier 1 regression gate (plan §6 Phase 2, decisions §0a).
//
// Hard failures:
//   1. self-consistency: two runs of the same scenario in the same build → identical checksum
//   2. Debug build runs every scenario without a panic and its checksum equals ReleaseFast's
//   3. ReleaseFast p95 ms/step ≤ threshold (bench/thresholds.json, per profile) when a threshold exists
//   4. memory ceilings: linear-memory pages, stack HWM, ReleaseFast wasm size (bench/thresholds.json)
// Advisory (warn only): checksum vs committed golden (bench/goldens/<zig>-<mode>.json).
//
//   node bench/sim-assert.mjs [--set-thresholds] [--update-goldens] [--skip-debug] [--only S1,S2]
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";
import { runAll, parseArgs } from "./sim-bench.mjs";
import { REPO_ROOT } from "./lib/wasm-host.mjs";
import { pinIfRequested } from "./lib/machine.mjs";
pinIfRequested();
import { printResults } from "./lib/report.mjs";
import { SCENARIO_VERSION } from "./lib/scenarios.mjs";

const THRESHOLDS_PATH = path.join(REPO_ROOT, "bench", "thresholds.json");
const GOLDENS_DIR = path.join(REPO_ROOT, "bench", "goldens");
const THRESHOLD_FACTOR = 1.25;

const readJson = (p, fallback) => (existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : fallback);

const args = parseArgs(process.argv.slice(2));
const failures = [];
const warnings = [];
const fail = (m) => { failures.push(m); console.log(`  ❌ ${m}`); };
const warn = (m) => { warnings.push(m); console.log(`  ⚠️  ${m}`); };
const ok = (m) => console.log(`  ✅ ${m}`);

// ---- 1. ReleaseFast run ×2 (self-consistency + timing) --------------------------------------
console.log("== ReleaseFast run 1 ==");
const run1 = await runAll({ mode: "ReleaseFast", only: args.only, gate: true });
console.log("== ReleaseFast run 2 (self-consistency) ==");
const run2 = await runAll({ mode: "ReleaseFast", only: args.only, quiet: true, gate: true });
printResults(run1.results);

console.log("\n== history independence (S2 rerun after all scenarios ≡ S2 earlier in the same run) ==");
{
  const s2 = run1.results.find((r) => r.id === "S2");
  if (s2 && run1.tail?.S2) (run1.tail.S2.checksum === s2.checksum ? ok : fail)(`S2 after full sequence ${run1.tail.S2.checksumHex} vs earlier ${s2.checksumHex}${run1.tail.S2.checksum === s2.checksum ? "" : " — state leaks across reset()"}`);
}

console.log("\n== self-consistency ==");
for (const r of run1.results) {
  const r2 = run2.results.find((x) => x.id === r.id);
  if (!r2) { fail(`${r.id}: missing in run 2`); continue; }
  if (r2.checksum !== r.checksum) fail(`${r.id}: checksum differs between identical runs (${r.checksumHex} vs ${r2.checksumHex}) — sim is not deterministic`);
  else ok(`${r.id} checksum ${r.checksumHex} reproduced`);
}

// ---- 2. Debug run (correctness only) -----------------------------------------------------------
if (!args.flags.has("skip-debug")) {
  console.log("\n== Debug run (safety checks + Debug≡ReleaseFast) ==");
  try {
    const dbg = await runAll({ mode: "Debug", only: args.only, quiet: true, gate: true, debugGateOnly: true });
    for (const r of run1.results) {
      const d = dbg.results.find((x) => x.id === r.id);
      if (!d) { console.log(`  –  ${r.id} not in Debug gate set`); continue; }
      if (d.checksum !== r.checksum) fail(`${r.id}: Debug checksum ${d.checksumHex} ≠ ReleaseFast ${r.checksumHex}`);
      else ok(`${r.id} Debug ≡ ReleaseFast`);
    }
  } catch (err) {
    fail(`Debug run crashed: ${err.message.split("\n")[0]}`);
  }
}

// ---- 3./4. thresholds ---------------------------------------------------------------------------
console.log("\n== thresholds ==");
const thresholds = readJson(THRESHOLDS_PATH, {});
const profile = run1.profile;
const t = thresholds[profile];
if (args.flags.has("set-thresholds") || !t) {
  const next = {
    _note: `p95 ms/step ceilings = baseline × ${THRESHOLD_FACTOR}; ratchet down after kept wins. Memory ceilings are exact + margin.`,
    _setFrom: { machine: run1.machine.machineId, git: run1.machine.gitSha, wasmSha: run1.wasm.sha256, time: run1.machine.timestamp, scenarioVersion: SCENARIO_VERSION },
    p95StepMs: Object.fromEntries(run1.results.map((r) => [r.id, +(r.p95 * THRESHOLD_FACTOR).toFixed(3)])),
    memoryPagesMax: Math.max(...run1.results.map((r) => r.memoryPages)),
    stackHwmBytesMax: Math.ceil(Math.max(...run1.results.map((r) => r.stackHwm.bytes)) * 1.1),
    wasmBytesMax: Math.ceil(run1.wasm.bytes * 1.05),
  };
  thresholds[profile] = next;
  writeFileSync(THRESHOLDS_PATH, JSON.stringify(thresholds, null, 2) + "\n");
  console.log(`  thresholds for profile '${profile}' ${t ? "rewritten" : "created"} from this run → ${path.relative(REPO_ROOT, THRESHOLDS_PATH)}`);
} else {
  for (const r of run1.results) {
    const ceiling = t.p95StepMs[r.id];
    if (ceiling === undefined) { warn(`${r.id}: no p95 threshold recorded`); continue; }
    if (r.p95 > ceiling) fail(`${r.id}: p95 ${r.p95.toFixed(3)} ms > ceiling ${ceiling} ms`);
    else ok(`${r.id} p95 ${r.p95.toFixed(3)} ms ≤ ${ceiling} ms`);
  }
  for (const r of run1.results) if (r.counters.cell_overflow > 0) fail(`${r.id}: spatial cell overflow ${r.counters.cell_overflow}/frame — collisions missed`);
  for (const r of run1.results) if (r.counters.constraints_dropped > 0) fail(`${r.id}: ${r.counters.constraints_dropped} constraints/frame dropped (MAX_CONSTRAINTS saturated)`);
  const pages = Math.max(...run1.results.map((r) => r.memoryPages));
  pages > t.memoryPagesMax ? fail(`linear memory ${pages} pages > ${t.memoryPagesMax}`) : ok(`linear memory ${pages} pages ≤ ${t.memoryPagesMax}`);
  const hwm = Math.max(...run1.results.map((r) => r.stackHwm.bytes));
  hwm > t.stackHwmBytesMax ? fail(`stack HWM ${hwm} B > ${t.stackHwmBytesMax}`) : ok(`stack HWM ${hwm} B ≤ ${t.stackHwmBytesMax}`);
  run1.wasm.bytes > t.wasmBytesMax ? fail(`wasm ${run1.wasm.bytes} B > ${t.wasmBytesMax}`) : ok(`wasm ${run1.wasm.bytes} B ≤ ${t.wasmBytesMax}`);
}

// ---- goldens (advisory) ---------------------------------------------------------------------------
console.log("\n== goldens (advisory) ==");
const goldenPath = path.join(GOLDENS_DIR, `zig-${run1.machine.zig}-ReleaseFast.json`);
const goldens = readJson(goldenPath, null);
if (args.flags.has("update-goldens") || !goldens) {
  const next = { _scenarioVersion: SCENARIO_VERSION, _setFrom: { git: run1.machine.gitSha, time: run1.machine.timestamp }, checksums: Object.fromEntries(run1.results.map((r) => [r.id, r.checksumHex])) };
  writeFileSync(goldenPath, JSON.stringify(next, null, 2) + "\n");
  console.log(`  goldens ${goldens ? "updated" : "created"} → ${path.relative(REPO_ROOT, goldenPath)}`);
} else {
  for (const r of run1.results) {
    const g = goldens.checksums[r.id];
    if (g === undefined) warn(`${r.id}: no golden`);
    else if (g !== r.checksumHex) warn(`${r.id}: checksum ${r.checksumHex} ≠ golden ${g} (physics changed? --update-goldens with a note)`);
    else ok(`${r.id} matches golden`);
  }
}

console.log(`\n${failures.length ? "GATE FAIL" : "GATE PASS"} — ${failures.length} failure(s), ${warnings.length} warning(s)`);
process.exitCode = failures.length ? 1 : 0;
