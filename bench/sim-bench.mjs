#!/usr/bin/env node
// Tier 1 benchmark: sim-only wasm step timing per scenario, phase split, counters, checksum.
//
//   node bench/sim-bench.mjs [--mode ReleaseFast|Debug] [--only S2,S3] [--json out.json] [--md out.md]
//   MORPHO_BENCH_PROFILE=slow|fast (default fast)   MORPHO_WASM=<path> to skip the build
import { writeFileSync } from "node:fs";
import { ensureWasm, instantiate } from "./lib/wasm-host.mjs";
import { machineInfo, wasmInfo, formatHeader, PROFILE } from "./lib/machine.mjs";
import { scenariosForProfile } from "./lib/scenarios.mjs";
import { warmUp, runScenario, expandVariants } from "./lib/runner.mjs";
import { printResults, markdownReport } from "./lib/report.mjs";

export function parseArgs(argv) {
  const args = { mode: "ReleaseFast", only: null, json: null, md: null, flags: new Set() };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--mode") args.mode = argv[++i];
    else if (a === "--only") args.only = new Set(argv[++i].split(","));
    else if (a === "--json") args.json = argv[++i];
    else if (a === "--md") args.md = argv[++i];
    else if (a.startsWith("--")) args.flags.add(a.slice(2));
    else throw new Error(`unknown arg ${a}`);
  }
  return args;
}

export async function runAll({ mode = "ReleaseFast", only = null, quiet = false, gate = false, debugGateOnly = false } = {}) {
  const wasmPath = ensureWasm(mode);
  const machine = machineInfo();
  const wasm = wasmInfo(wasmPath);
  const header = formatHeader(machine, wasm, { mode, warmup: "300 steps" });
  if (!quiet) console.log(header);

  const host = await instantiate(wasmPath);
  const warm = warmUp(host);
  if (!quiet) console.log(`warm-up ms/step by 50-step chunk: ${warm.chunks.map((c) => c.toFixed(3)).join(" ")}  plateau=${warm.plateau ? "yes" : "NO"}`);
  if (!warm.plateau) console.warn("WARNING: warm-up did not plateau (last two chunks differ > 10%); numbers may include tier-up.");

  const results = [];
  for (const { scenario, variant } of expandVariants(scenariosForProfile(PROFILE, { gate }))) {
    if (only && !only.has(scenario.id) && !only.has(scenario.key)) continue;
    if (debugGateOnly && scenario.debugGate === false) continue;
    const t0 = Date.now();
    const r = runScenario(host, scenario, { profile: PROFILE, variant });
    r.wallMs = Date.now() - t0;
    if (!quiet) console.log(`  ${r.id.padEnd(8)} ${r.title}  → p50 ${r.p50.toFixed(3)} ms  (${r.wallMs} ms wall)`);
    results.push(r);
  }
  return { header, machine, wasm, mode, profile: PROFILE, warmup: warm, results, logs: host.logs };
}

const isMain = process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href;
if (isMain) {
  const args = parseArgs(process.argv.slice(2));
  const run = await runAll(args);
  printResults(run.results);
  if (args.json) writeFileSync(args.json, JSON.stringify(run, null, 2));
  if (args.md) writeFileSync(args.md, markdownReport(run.header, run.results));
  if (args.json || args.md) console.log(`\nwritten: ${[args.json, args.md].filter(Boolean).join(", ")}`);
}
