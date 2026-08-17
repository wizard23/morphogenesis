#!/usr/bin/env node
// Tier 1 scaling matrix: ms/step vs particle count × XPBD iterations (plan §6 Phase 2 / G3).
//   node bench/sim-scaling.mjs [--particles 933,2000,4000,8000,10932] [--iterations 3,6] [--md out.md]
import { writeFileSync } from "node:fs";
import { ensureWasm, instantiate, PHASES } from "./lib/wasm-host.mjs";
import { machineInfo, wasmInfo, formatHeader, PROFILE } from "./lib/machine.mjs";
import { freshScene, step, paintBlock, WORLD_W, WORLD_H, DT } from "./lib/scenarios.mjs";
import { warmUp } from "./lib/runner.mjs";
import { dist, padTable, fmtMs, markdownTable } from "./lib/stats.mjs";

const argv = process.argv.slice(2);
const opt = (name, def) => { const i = argv.indexOf(`--${name}`); return i >= 0 ? argv[i + 1] : def; };
const particleTargets = opt("particles", PROFILE === "fast" ? "933,2000,4000,8000,10932" : "933,2000,4000").split(",").map(Number);
const iterationSet = opt("iterations", "3,6").split(",").map(Number);
const mdOut = opt("md", null);
const SETTLE = 200, MEASURE = PROFILE === "fast" ? 300 : 150;
const nowMs = () => Number(process.hrtime.bigint()) / 1e6;

const wasmPath = ensureWasm("ReleaseFast");
const header = formatHeader(machineInfo(), wasmInfo(wasmPath), { mode: "ReleaseFast", settle: `${SETTLE} steps`, measure: `${MEASURE} steps` });
console.log(header);
const host = await instantiate(wasmPath);
const e = host.exports;
warmUp(host);

/** Build a scene with ~`target` alive particles: default 933 + a uniform valence-2 field. */
function buildScene(target) {
  freshScene(e);
  step(e, 300);
  const extra = target - e.get_alive_particle_count();
  if (extra > 0) {
    const area = (WORLD_W * 0.95) * (WORLD_H * 0.95);
    const spacing = Math.sqrt(area / extra);
    const cols = Math.floor((WORLD_W * 0.95) / spacing), rows = Math.ceil(extra / cols);
    paintBlock(e, { cx: 0, cy: 0, cols, rows, spacing, valence: 2 });
  }
  step(e, SETTLE);
}

const rows = [];
for (const target of particleTargets) {
  for (const iters of iterationSet) {
    buildScene(target);
    e.set_xpbd_iterations(iters);
    e.perf_reset();
    const ms = [];
    for (let i = 0; i < MEASURE; i++) { const t0 = nowMs(); e.update_particles(DT); ms.push(nowMs() - t0); }
    const d = dist(ms), ph = host.phaseMeans(), c = host.counters();
    rows.push({ particles: e.get_alive_particle_count(), springs: e.get_alive_spring_count(), iters, d, ph, c, hwm: host.stackHwm().bytes });
    console.log(`  P=${rows.at(-1).particles} iters=${iters}: p50 ${d.p50.toFixed(3)} ms`);
    e.set_xpbd_iterations(6);
  }
}

const header2 = ["P", "S", "iters", "p50 ms", "p95 ms", "ms/P (µs)", ...PHASES.map((p) => p.replace("gen_", "g.")), "constr/it", "hwm KB"];
const table = rows.map((r) => [
  r.particles, r.springs, r.iters, fmtMs(r.d.p50), fmtMs(r.d.p95), (1000 * r.d.p50 / r.particles).toFixed(2),
  ...PHASES.map((p) => fmtMs(r.ph[p])), (r.c.constraints / Math.max(1, r.c.iterations)).toFixed(0), (r.hwm / 1024).toFixed(0),
]);
console.log("\n== scaling (ms/step) ==");
console.log(padTable([header2, ...table], header2.map(() => "right")).join("\n"));

// crude super-linearity flag: ms/P should be ~flat for O(n); print growth from smallest to largest
if (rows.length >= 2) {
  const byIter = new Map();
  for (const r of rows) (byIter.get(r.iters) ?? byIter.set(r.iters, []).get(r.iters)).push(r);
  for (const [iters, rs] of byIter) {
    const a = rs[0], b = rs[rs.length - 1];
    for (const p of PHASES) {
      const growth = (b.ph[p] / Math.max(1e-6, a.ph[p])) / (b.particles / a.particles);
      if (growth > 1.5 && b.ph[p] > 0.05) console.log(`  super-linear: ${p} grows ${growth.toFixed(1)}× faster than particle count (iters=${iters})`);
    }
  }
}
if (mdOut) writeFileSync(mdOut, ["```", header, "```", "", markdownTable(header2, table), ""].join("\n"));
