#!/usr/bin/env node
// Memory report (plan §6 Phase 5): wasm section sizes, linear-memory pages, largest static
// symbols (from the linker map when available), stack HWM per scenario, GPU buffer bytes.
//   node bench/memory-report.mjs [--md out.md]
import { readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { ensureWasm, instantiate, REPO_ROOT } from "./lib/wasm-host.mjs";
import { machineInfo, wasmInfo, formatHeader, PROFILE } from "./lib/machine.mjs";
import { scenariosForProfile } from "./lib/scenarios.mjs";
import { warmUp, runScenario, expandVariants } from "./lib/runner.mjs";
import { padTable, markdownTable } from "./lib/stats.mjs";

const mdOut = (() => { const i = process.argv.indexOf("--md"); return i >= 0 ? process.argv[i + 1] : null; })();

// ---- wasm sections -------------------------------------------------------------------------------
const SECTION_NAMES = ["custom", "type", "import", "function", "table", "memory", "global", "export", "start", "element", "code", "data", "datacount"];
function readLEB(buf, pos) { let result = 0, shift = 0, b; do { b = buf[pos++]; result |= (b & 0x7f) << shift; shift += 7; } while (b & 0x80); return [result >>> 0, pos]; }
function parseSections(buf) {
  let pos = 8; const out = [];
  while (pos < buf.length) {
    const id = buf[pos++]; let size; [size, pos] = readLEB(buf, pos);
    let name = SECTION_NAMES[id] ?? `id${id}`;
    if (id === 0) { const [nlen, p2] = readLEB(buf, pos); name = `custom:${buf.subarray(p2, p2 + nlen).toString()}`; }
    if (id === 11) { // data: count segments and total init bytes
      let [count, p] = readLEB(buf, pos); let initBytes = 0;
      for (let i = 0; i < count; i++) {
        let flags; [flags, p] = readLEB(buf, p);
        if (flags === 2) [, p] = readLEB(buf, p);
        if (flags !== 1) { while (buf[p] !== 0x0b) p++; p++; } // skip init expr
        let len; [len, p] = readLEB(buf, p); initBytes += len; p += len;
      }
      out.push({ name: "data (segments)", bytes: size, extra: `${count} segments, ${initBytes} init bytes` });
    } else out.push({ name, bytes: size });
    pos += size;
  }
  return out;
}

const modes = ["ReleaseFast", "Debug"];
const sectionTables = {};
for (const mode of modes) {
  const p = ensureWasm(mode);
  sectionTables[mode] = { path: p, size: readFileSync(p).length, sections: parseSections(readFileSync(p)) };
}

// No per-symbol size dump for wasm in Zig 0.16 (no map-file emission); static sizes below are
// derived from the constants in src/*.zig and cross-checked against the measured page count.
// Static budgets derived from the constants in src/*.zig (kept in sync by hand; verified against pages).
const PARTICLE_COUNT = 3 * 144 + 500 + 10000, MAX_SPRINGS = 3 * 144 * 4 + 10000 * 2, MAX_CONSTRAINTS = MAX_SPRINGS + 50000;
const staticEstimates = [
  ["spatial_grid (100×100 cells × (64×4+4) B)", 100 * 100 * (64 * 4 + 4)],
  ["constraints (MAX_CONSTRAINTS × ~100 B)", MAX_CONSTRAINTS * 100],
  ["particle_arena (entries ~44 B + maps ~8 B) × PARTICLE_COUNT", PARTICLE_COUNT * 52],
  ["spring_arena (entries 16 B + maps 8 B) × MAX_SPRINGS", MAX_SPRINGS * 24],
  ["particle_connections (6 × 4 B) + counts", PARTICLE_COUNT * 25],
  ["bulk buffers (particles 16 B + springs 16 B)", PARTICLE_COUNT * 16 + MAX_SPRINGS * 16],
  ["perf ring (512 × 8 × 4 B)", 512 * 8 * 4],
  ["shadow stack (build.zig stack_size)", 4 * 1024 * 1024],
];

// ---- runtime: pages + stack HWM per scenario ------------------------------------------------------
const rfPath = sectionTables.ReleaseFast.path;
const header = formatHeader(machineInfo(), wasmInfo(rfPath), { mode: "ReleaseFast (+Debug sections)" });
console.log(header);
const host = await instantiate(rfPath);
const pagesAfterInit = host.memoryPages();
warmUp(host);
const hwmRows = [];
for (const { scenario, variant } of expandVariants(scenariosForProfile(PROFILE))) {
  if (scenario.fastOnly && PROFILE !== "fast") continue;
  const r = runScenario(host, scenario, { profile: PROFILE, variant });
  hwmRows.push([r.id, r.alive.particles, r.alive.springs, r.stackHwm.bytes, r.stackHwm.probe, r.memoryPages]);
  console.log(`  ${r.id.padEnd(8)} stack HWM ${r.stackHwm.bytes} B  pages ${r.memoryPages}`);
}

// ---- GPU buffers (renderer.js sizing rules) ---------------------------------------------------------
const e = host.exports;
const maxParticles = e.get_max_particles(), maxSprings = e.get_max_springs(), gridSize = e.get_grid_size();
const gpu = [
  ["instanceBuffer (maxParticles × 16 B)", maxParticles * 16],
  ["springVertexBuffer (maxSprings × 16 B)", maxSprings * 16],
  ["gridVertexBuffer ((gridSize+1)×2 × 16 B)", (gridSize + 1) * 2 * 16],
  ["quad + mouse + uniform", 48 + 16 + 12],
  ["JS staging Float32Arrays (particles + springs)", maxParticles * 16 + maxSprings * 16],
];

// ---- print ------------------------------------------------------------------------------------------
const out = [];
const section = (title, headerRow, rows, aligns) => {
  console.log(`\n== ${title} ==`);
  console.log(padTable([headerRow, ...rows], aligns).join("\n"));
  out.push(`**${title}**`, "", markdownTable(headerRow, rows), "");
};
for (const mode of modes) {
  const t = sectionTables[mode];
  section(`wasm sections — ${mode} (${t.size} bytes)`, ["section", "bytes", "note"], t.sections.map((s) => [s.name, s.bytes, s.extra ?? ""]), ["left", "right", "left"]);
}
section("linear memory", ["item", "value"], [["pages after init", pagesAfterInit], ["bytes", pagesAfterInit * 65536], ["grows during scenarios?", hwmRows.some((r) => r[5] !== pagesAfterInit) ? "YES" : "no (static, no allocator)"]], ["left", "right"]);
section("static budget (from src constants; sum vs pages)", ["item", "bytes"], [...staticEstimates.map(([n, b]) => [n, b]), ["sum", staticEstimates.reduce((a, [, b]) => a + b, 0)]], ["left", "right"]);
section("stack high-water per scenario (ReleaseFast)", ["scenario", "P", "S", "hwm B", "probe B", "pages"], hwmRows, ["left", "right", "right", "right", "right", "right"]);
section("GPU / JS render buffers", ["buffer", "bytes"], [...gpu, ["sum", gpu.reduce((a, [, b]) => a + b, 0)]], ["left", "right"]);
if (mdOut) writeFileSync(mdOut, ["```", header, "```", "", ...out].join("\n"));
