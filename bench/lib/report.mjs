// Human + markdown formatting of scenario results.
import { padTable, fmtMs, markdownTable } from "./stats.mjs";
import { PHASES } from "./wasm-host.mjs";

export function timingRows(results) {
  const header = ["scenario", "P", "S", "min ms", "p50 ms", "p95 ms", "p99 ms", "max ms", "spread", "constr/it", "coll/it", "bin", "ovf", "disp px", "hwm KB", "checksum"];
  const rows = results.map((r) => [
    r.id, r.alive.particles, r.alive.springs,
    fmtMs(r.min), fmtMs(r.p50), fmtMs(r.p95), fmtMs(r.p99), fmtMs(r.max), `${(r.spreadP50 * 100).toFixed(1)}%${r.repeat > 1 ? `/${r.repeat}` : ""}`,
    (r.counters.constraints / Math.max(1, r.counters.iterations)).toFixed(0),
    (r.counters.collision_pairs / Math.max(1, r.counters.iterations)).toFixed(0),
    r.counters.bin_max,
    r.counters.cell_overflow.toFixed(0),
    (r.counters.max_step_disp_milli / 1000).toFixed(1),
    (r.stackHwm.bytes / 1024).toFixed(0) + (r.stackHwm.bytes >= r.stackHwm.probe ? "+" : ""),
    r.checksumHex + (r.checksumsAgree === false ? " ✗" : ""),
  ]);
  return { header, rows };
}

export function phaseRows(results) {
  const header = ["scenario", ...PHASES.map((p) => p + " ms"), "sum ms"];
  const rows = results.map((r) => {
    const sum = PHASES.reduce((a, p) => a + r.phases[p], 0);
    return [r.id, ...PHASES.map((p) => `${fmtMs(r.phases[p])} (${sum ? ((100 * r.phases[p]) / sum).toFixed(0) : 0}%)`), fmtMs(sum)];
  });
  return { header, rows };
}

export function printResults(results) {
  const t = timingRows(results);
  console.log("\n== step timing (ms/step, median over bursts) ==");
  console.log(padTable([t.header, ...t.rows], t.header.map((_, i) => (i === 0 ? "left" : "right"))).join("\n"));
  const p = phaseRows(results);
  console.log("\n== phase split (mean ms per step, share of instrumented sum) ==");
  console.log(padTable([p.header, ...p.rows], p.header.map((_, i) => (i === 0 ? "left" : "right"))).join("\n"));
}

export function markdownReport(header, results) {
  const t = timingRows(results);
  const p = phaseRows(results);
  return [
    "```", header, "```", "",
    "**Step timing (ms/step, median over bursts)**", "", markdownTable(t.header, t.rows), "",
    "**Phase split (mean ms/step)**", "", markdownTable(p.header, p.rows), "",
  ].join("\n");
}
