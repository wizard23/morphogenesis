#!/usr/bin/env node
// Interleaved A/B: two wasm builds measured alternately in one process, so slow drift (load, thermal)
// hits both sides equally. Verdict per scenario from the sign/size of the p50 and min deltas versus the
// per-side spread. Both sides must be self-consistent (checksum identical across repeats).
//
//   node bench/sim-ab.mjs --a <ref|path|.> --b <ref|path|.> [--only S2,S4] [--repeat 5] [--burst-steps 300]
//   <ref>  = git ref (built from a temporary worktree with -Dperf=true)   .  = working tree
//   MORPHO_BENCH_PIN=<cpu> to pin.  Example: node bench/sim-ab.mjs --a HEAD --b .
import { execSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { ensureWasm, instantiate, REPO_ROOT, PHASES } from "./lib/wasm-host.mjs";
import { machineInfo, wasmInfo, formatHeader, PROFILE, pinIfRequested, LOAD_WARN } from "./lib/machine.mjs";
import { scenariosForProfile } from "./lib/scenarios.mjs";
import { warmUp, runScenario, expandVariants } from "./lib/runner.mjs";
import { median, iqrRel, padTable, fmtMs } from "./lib/stats.mjs";

pinIfRequested();
const argv = process.argv.slice(2);
const opt = (n, d) => { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : d; };
const A = opt("a", "HEAD"), B = opt("b", ".");
const only = opt("only", null)?.split(",");
const REPEAT = Number(opt("repeat", 5));
const BURST_STEPS = Number(opt("burst-steps", 300));

const temps = [];
/** Resolve a side spec to a perf-instrumented wasm path. */
function resolveWasm(spec) {
  if (spec === ".") return ensureWasm("ReleaseFast");
  if (existsSync(spec) && spec.endsWith(".wasm")) return path.resolve(spec);
  // git ref → temporary worktree → build
  const dir = mkdtempSync(path.join(os.tmpdir(), "morpho-ab-"));
  temps.push(dir);
  execSync(`git worktree add --detach "${dir}" ${spec}`, { cwd: REPO_ROOT, stdio: "ignore" });
  execSync(`zig build -Doptimize=ReleaseFast -Dperf=true --prefix "${dir}/out"`, { cwd: dir, stdio: "inherit" });
  return path.join(dir, "out", "bin", "webgpu-demo.wasm");
}
function cleanup() {
  for (const dir of temps) { try { execSync(`git worktree remove --force "${dir}"`, { cwd: REPO_ROOT, stdio: "ignore" }); } catch { /* best effort */ } rmSync(dir, { recursive: true, force: true }); }
}

try {
  const wasmA = resolveWasm(A), wasmB = resolveWasm(B);
  const machine = machineInfo();
  console.log(formatHeader(machine, wasmInfo(wasmA), { A: `${A} → ${wasmA}`, B: `${B} → ${wasmB}`, repeat: `${REPEAT} × 1 burst × ${BURST_STEPS} steps, interleaved A,B,A,B…` }));
  if (machine.loadAvg1 > LOAD_WARN) console.warn(`note: load ${machine.loadAvg1} — that's what interleaving is for; still prefer a quiet machine`);
  const hostA = await instantiate(wasmA), hostB = await instantiate(wasmB);
  warmUp(hostA); warmUp(hostB);

  const scen = expandVariants(scenariosForProfile(PROFILE)).filter(({ scenario }) => !only || only.includes(scenario.id) || only.includes(scenario.key));
  const rows = [];
  for (const { scenario, variant } of scen) {
    const s = { ...scenario, bursts: 1, burstSteps: BURST_STEPS };
    const side = { A: { p50: [], min: [], ck: new Set(), phases: [] }, B: { p50: [], min: [], ck: new Set(), phases: [] } };
    for (let r = 0; r < REPEAT; r++) {
      // alternate order each repeat: A,B / B,A / … so periodic interference has no favourite side
      const order = r % 2 === 0 ? [["A", hostA], ["B", hostB]] : [["B", hostB], ["A", hostA]];
      for (const [name, host] of order) {
        const res = runScenario(host, s, { profile: PROFILE, variant });
        side[name].p50.push(res.p50); side[name].min.push(res.min); side[name].ck.add(res.checksumHex); side[name].phases.push(res.phases);
      }
    }
    const medA = median(side.A.p50), medB = median(side.B.p50), minA = Math.min(...side.A.min), minB = Math.min(...side.B.min);
    // Paired estimators: B/A within each repeat (A and B ran back-to-back under the same conditions),
    // so slow drift and repeat-level slowdowns cancel. Median of ratios is the estimate; the IQR of the
    // ratios is the noise. Unpaired Δ of medians is shown for context only.
    const ratiosP50 = side.A.p50.map((a, i) => side.B.p50[i] / a);
    const ratiosMin = side.A.min.map((a, i) => side.B.min[i] / a);
    const rP50 = median(ratiosP50) - 1, rMin = median(ratiosMin) - 1;
    const nP50 = Math.max(iqrRel(ratiosP50), 0.01), nMin = Math.max(iqrRel(ratiosMin), 0.01);
    const dP50 = (medB - medA) / medA, dMin = (minB - minA) / minA;
    const agree = Math.sign(rP50) === Math.sign(rMin);
    const p50Clear = Math.abs(rP50) > 2 * nP50, minClear = Math.abs(rMin) > 2 * nMin;
    let verdict;
    if (agree && p50Clear && minClear) verdict = rP50 < 0 ? "B faster" : "B slower";
    else if (Math.abs(rP50) <= nP50 && Math.abs(rMin) <= nMin) verdict = "no difference";
    else if (!minClear && p50Clear) verdict = "inconclusive (p50 moved, min did not → interference?)";
    else verdict = "inconclusive";
    const phaseDelta = PHASES.map((p) => { const a = median(side.A.phases.map((x) => x[p])), b = median(side.B.phases.map((x) => x[p])); return a > 0.02 ? `${p} ${((b - a) / a * 100).toFixed(0)}%` : null; }).filter(Boolean).join("  ");
    rows.push([s.id + (variant !== undefined ? `[${variant}]` : ""), fmtMs(medA), fmtMs(medB), `${(rP50 * 100).toFixed(1)}%`, `${(nP50 * 100).toFixed(1)}%`, fmtMs(minA), fmtMs(minB), `${(rMin * 100).toFixed(1)}%`, `${(nMin * 100).toFixed(1)}%`, `${(dP50 * 100).toFixed(1)}%`, verdict, side.A.ck.size === 1 && side.B.ck.size === 1 ? ([...side.A.ck][0] === [...side.B.ck][0] ? "same" : "differ") : "NOT SELF-CONSISTENT", phaseDelta]);
    console.log(`  ${rows.at(-1)[0].padEnd(8)} paired B/A: p50 ${(rP50 * 100).toFixed(1)}% (IQR ${(nP50 * 100).toFixed(1)}%)  min ${(rMin * 100).toFixed(1)}% (IQR ${(nMin * 100).toFixed(1)}%)  → ${verdict}`);
  }
  const h = ["scenario", "A p50", "B p50", "paired Δp50", "IQR", "A min", "B min", "paired Δmin", "IQR", "unpaired Δp50", "verdict", "checksum", "phase Δ (B vs A, phases > 0.02 ms)"];
  console.log("\n== A/B ==");
  console.log(padTable([h, ...rows], h.map((_, i) => (i === 0 || i >= 10 ? "left" : "right"))).join("\n"));
  console.log("\nverdict rule (paired B/A per repeat): conclusive iff |median ratio−1| > 2×IQR(ratios) for BOTH p50 and min, same sign; both within IQR → no difference; else inconclusive.");
} finally {
  cleanup();
}
