// Instantiate the simulation wasm in Node with stub host imports and a high-resolution clock.
// Builds the wasm on demand (perf-instrumented) into bench/.build/<mode>/ unless MORPHO_WASM is set.
import { readFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { execSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const REPO_ROOT = path.resolve(__dirname, "..", "..");

export const PHASES = ["predict", "mouse", "bonds", "gen_springs", "gen_grid", "gen_collide", "solve", "commit"];
export const COUNTERS = ["constraints", "collision_pairs", "bonds_formed", "springs_removed", "bin_max", "iterations", "max_step_disp_milli", "cell_overflow"];

/** Build (if needed) and return the path of a perf-instrumented wasm for `mode` (ReleaseFast|Debug). */
export function ensureWasm(mode = "ReleaseFast", { force = false } = {}) {
  if (process.env.MORPHO_WASM) return path.resolve(process.env.MORPHO_WASM);
  const prefix = path.join(REPO_ROOT, "bench", ".build", mode);
  const out = path.join(prefix, "bin", "webgpu-demo.wasm");
  if (force || !existsSync(out) || sourcesNewerThan(out)) {
    execSync(`zig build -Doptimize=${mode} -Dperf=true --prefix "${prefix}"`, { cwd: REPO_ROOT, stdio: "inherit" });
  }
  return out;
}

function mtime(p) {
  try { return statSync(p).mtimeMs; } catch { return 0; }
}

function sourcesNewerThan(file) {
  const t = mtime(file);
  const src = path.join(REPO_ROOT, "src");
  return readdirSync(src).some((f) => mtime(path.join(src, f)) > t) || mtime(path.join(REPO_ROOT, "build.zig")) > t;
}

/** Instantiate; returns { exports, logs, mode, ring helpers }. */
export async function instantiate(wasmPath) {
  const bytes = readFileSync(wasmPath);
  const logs = [];
  const { instance } = await WebAssembly.instantiate(bytes, {
    env: {
      console_log: (ptr, len) => {
        const mem = instance.exports.memory;
        logs.push(new TextDecoder().decode(new Uint8Array(mem.buffer, ptr, len)));
      },
      emscripten_webgpu_get_device: () => 0,
      perf_now: () => Number(process.hrtime.bigint()) / 1e6,
    },
  });
  const e = instance.exports;
  if (!e.perf_is_enabled?.()) throw new Error(`wasm at ${wasmPath} was not built with -Dperf=true`);
  const phaseCount = e.perf_phase_count();
  const ringFrames = e.perf_ring_frames();
  if (phaseCount !== PHASES.length) throw new Error(`phase count mismatch: wasm ${phaseCount} vs harness ${PHASES.length}`);
  e.init(); // one-time system init (arenas, spatial grid, mouse); scenarios call reset()
  return {
    exports: e,
    logs,
    memoryPages: () => e.memory.buffer.byteLength / 65536,
    checksum: () => e.state_checksum() >>> 0,
    stackHwm: () => ({ bytes: e.perf_stack_hwm(), probe: e.perf_stack_probe_len() }),
    /** Per-phase mean ms over frames currently in the ring (since perf_reset). */
    phaseMeans: () => {
      const n = e.perf_ring_count();
      const ring = new Float32Array(e.memory.buffer, e.perf_ring_ptr(), ringFrames * phaseCount);
      const head = e.perf_ring_head();
      const means = new Array(phaseCount).fill(0);
      for (let k = 0; k < n; k++) {
        const f = (head - n + k + ringFrames) % ringFrames;
        for (let p = 0; p < phaseCount; p++) means[p] += ring[f * phaseCount + p];
      }
      return Object.fromEntries(PHASES.map((name, p) => [name, n ? means[p] / n : 0]));
    },
    counters: () => {
      const frames = Math.max(1, e.perf_frames());
      const out = {};
      COUNTERS.forEach((name, i) => {
        out[name] = (name === "bin_max" || name === "max_step_disp_milli") ? e.perf_counter_total(i) : e.perf_counter_total(i) / frames;
      });
      return out;
    },
  };
}
