// Machine / build provenance block — printed at the top of every benchmark run and pasted into
// progress notes. Compare numbers only when this block matches (docs/HOWTO-performance.md).
import os from "node:os";
import childProcess, { execSync } from "node:child_process";
import { statSync } from "node:fs";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";

function sh(cmd) {
  try { return execSync(cmd, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim(); } catch { return "n/a"; }
}

export const PROFILE = (process.env.MORPHO_BENCH_PROFILE ?? "fast").toLowerCase();
if (!["fast", "slow"].includes(PROFILE)) throw new Error(`MORPHO_BENCH_PROFILE must be fast|slow, got ${PROFILE}`);

/** Load average (1 min). Above LOAD_WARN the machine is busy and timing tails are unreliable. */
export const LOAD_WARN = 2.0;
export function loadAverage() { return os.loadavg()[0]; }

/**
 * MORPHO_BENCH_PIN=<cpu> re-executes the current script under `taskset -c <cpu>` (Linux) so the
 * benchmark stays on one core. Call first thing in an entry script; returns only in the child.
 */
export function pinIfRequested() {
  const pin = process.env.MORPHO_BENCH_PIN;
  if (!pin || process.env.__MORPHO_PINNED) return;
  const { spawnSync } = childProcess;
  const r = spawnSync("taskset", ["-c", pin, process.execPath, ...process.argv.slice(1)], { stdio: "inherit", env: { ...process.env, __MORPHO_PINNED: "1" } });
  process.exit(r.status ?? 1);
}

export function machineInfo() {
  const cpu = os.cpus()[0]?.model ?? "unknown-cpu";
  return {
    machineId: `${os.hostname()} / ${cpu} / ${os.cpus().length} cores`,
    loadAvg1: +loadAverage().toFixed(2),
    pinned: process.env.__MORPHO_PINNED ? `cpu ${process.env.MORPHO_BENCH_PIN}` : "no",
    profile: PROFILE,
    node: process.version,
    zig: sh("zig version"),
    gitSha: sh("git rev-parse --short HEAD"),
    gitDirty: sh("git status --porcelain") !== "",
    timestamp: new Date().toISOString(),
  };
}

export function wasmInfo(path) {
  const bytes = readFileSync(path);
  return {
    path,
    bytes: statSync(path).size,
    sha256: createHash("sha256").update(bytes).digest("hex").slice(0, 12),
  };
}

export function formatHeader(m, w, extra = {}) {
  const lines = [
    `machine:  ${m.machineId}`,
    `load:     ${m.loadAvg1} (1 min)${m.loadAvg1 > LOAD_WARN ? "  ⚠ busy machine — p95/p99/max unreliable, prefer min/p50 and A/B" : ""}   pinned: ${m.pinned}`,
    `profile:  ${m.profile}`,
    `node:     ${m.node}   zig: ${m.zig}   git: ${m.gitSha}${m.gitDirty ? " (dirty)" : ""}`,
    `wasm:     ${w.path}  ${w.bytes} bytes  sha ${w.sha256}`,
    ...Object.entries(extra).map(([k, v]) => `${(k + ":").padEnd(10)}${v}`),
    `time:     ${m.timestamp}`,
  ];
  return lines.join("\n");
}
