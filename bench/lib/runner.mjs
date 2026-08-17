// Scenario runner: warm-up, bursts, per-step timing, ring/counters/checksum collection.
import { dist, median, iqrRel } from "./stats.mjs";
import { DT, freshScene, step } from "./scenarios.mjs";

export const BURST_DEFAULTS = { fast: { bursts: 3, burstSteps: 300 }, slow: { bursts: 2, burstSteps: 200 } };
export const WARMUP_STEPS = 300;

const nowMs = () => Number(process.hrtime.bigint()) / 1e6;

/** JIT warm-up (V8 wasm tier-up). Returns ms/step per 50-step chunk so the plateau can be checked. */
export function warmUp(host, steps = WARMUP_STEPS) {
  const e = host.exports;
  freshScene(e);
  const chunks = [];
  for (let done = 0; done < steps; done += 50) {
    const t0 = nowMs();
    step(e, 50);
    chunks.push((nowMs() - t0) / 50);
  }
  const last = chunks[chunks.length - 1], prev = chunks[chunks.length - 2] ?? last;
  const plateau = Math.abs(last - prev) / Math.max(prev, 1e-9) <= 0.10;
  return { chunks, plateau };
}

/** One setup + `bursts` measured bursts of `burstSteps`. Returns per-burst records + final state. */
function runOnce(host, scenario, { variant, bursts, burstSteps }) {
  const e = host.exports;
  scenario.setup(e, variant);
  const aliveBefore = { particles: e.get_alive_particle_count(), springs: e.get_alive_spring_count() };
  const burstResults = [];
  let stepIndex = 0;
  for (let b = 0; b < bursts; b++) {
    e.perf_reset();
    const stepMs = new Array(burstSteps);
    for (let i = 0; i < burstSteps; i++, stepIndex++) {
      scenario.drive?.(e, stepIndex);
      const t0 = nowMs();
      e.update_particles(DT);
      stepMs[i] = nowMs() - t0;
    }
    burstResults.push({ steps: burstSteps, timing: dist(stepMs), phases: host.phaseMeans(), counters: host.counters(), stackHwm: host.stackHwm() });
  }
  const mouseGrabs = e.get_mouse_grab_count();
  scenario.teardown?.(e);
  return { burstResults, aliveBefore, alive: { particles: e.get_alive_particle_count(), springs: e.get_alive_spring_count() }, mouseGrabs, checksum: host.checksum() };
}

/**
 * Run one scenario (variant optional). `repeat` > 1 re-runs setup + bursts that many times: since the
 * sim is deterministic every repeat measures the identical workload, so spread across repeats is pure
 * environment noise, `min` is a near-ideal estimate of intrinsic cost, and p50 is the median over
 * ALL bursts. Returns a result record.
 */
export function runScenario(host, scenario, { profile, variant, repeat = 1 } = {}) {
  const bursts = scenario.bursts ?? BURST_DEFAULTS[profile].bursts;
  const burstSteps = scenario.burstSteps ?? BURST_DEFAULTS[profile].burstSteps;

  const runs = [];
  for (let r = 0; r < repeat; r++) runs.push(runOnce(host, scenario, { variant, bursts, burstSteps }));
  const first = runs[0];
  const checksumsAgree = runs.every((r) => r.checksum === first.checksum);
  const allBursts = runs.flatMap((r) => r.burstResults);
  const p50s = allBursts.map((b) => b.timing.p50);
  const runP50s = runs.map((r) => median(r.burstResults.map((b) => b.timing.p50)));
  const rep = allBursts[Math.floor(allBursts.length / 2)];
  const phaseMeanAcross = Object.fromEntries(Object.keys(rep.phases).map((k) => [k, median(allBursts.map((b) => b.phases[k]))]));

  return {
    id: scenario.id + (variant !== undefined ? `[${variant}]` : ""),
    key: scenario.key,
    variant,
    title: scenario.title,
    bursts,
    burstSteps,
    repeat,
    aliveBefore: first.aliveBefore,
    alive: first.alive,
    mouseGrabs: first.mouseGrabs,
    min: Math.min(...allBursts.map((b) => b.timing.min)),
    p50: median(p50s),
    p95: median(allBursts.map((b) => b.timing.p95)),
    p99: median(allBursts.map((b) => b.timing.p99)),
    max: Math.max(...allBursts.map((b) => b.timing.max)),
    /** spread of burst p50s (single run) or of per-repeat p50s (repeat > 1): (max−min)/median */
    spreadP50: repeat > 1
      ? (Math.max(...runP50s) - Math.min(...runP50s)) / median(runP50s)
      : (p50s.length > 1 ? (Math.max(...p50s) - Math.min(...p50s)) / median(p50s) : 0),
    iqrP50: iqrRel(p50s),
    phases: phaseMeanAcross,
    counters: rep.counters,
    stackHwm: allBursts.reduce((m, b) => (b.stackHwm.bytes > m.bytes ? b.stackHwm : m), allBursts[0].stackHwm),
    memoryPages: host.memoryPages(),
    checksum: first.checksum,
    checksumHex: first.checksum.toString(16).padStart(8, "0"),
    checksumsAgree,
    burstResults: allBursts,
  };
}

/** Expand scenarios with variants into (scenario, variant) pairs. */
export function expandVariants(scenarios) {
  const out = [];
  for (const s of scenarios) {
    if (s.variants) for (const v of s.variants) out.push({ scenario: s, variant: v });
    else out.push({ scenario: s, variant: undefined });
  }
  return out;
}
