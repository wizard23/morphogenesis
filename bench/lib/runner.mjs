// Scenario runner: warm-up, bursts, per-step timing, ring/counters/checksum collection.
import { dist, median } from "./stats.mjs";
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

/** Run one scenario (variant optional). Returns a result record. */
export function runScenario(host, scenario, { profile, variant } = {}) {
  const e = host.exports;
  const bursts = scenario.bursts ?? BURST_DEFAULTS[profile].bursts;
  const burstSteps = scenario.burstSteps ?? BURST_DEFAULTS[profile].burstSteps;

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
    burstResults.push({
      steps: burstSteps,
      timing: dist(stepMs),
      phases: host.phaseMeans(),
      counters: host.counters(),
      stackHwm: host.stackHwm(),
    });
  }
  const mouseGrabs = e.get_mouse_grab_count();
  scenario.teardown?.(e);

  const checksum = host.checksum();
  const alive = { particles: e.get_alive_particle_count(), springs: e.get_alive_spring_count() };
  const p50s = burstResults.map((b) => b.timing.p50);
  const p95s = burstResults.map((b) => b.timing.p95);
  const rep = burstResults[Math.floor(burstResults.length / 2)]; // representative burst for phases/counters
  const phaseMeanAcross = Object.fromEntries(Object.keys(rep.phases).map((k) => [k, median(burstResults.map((b) => b.phases[k]))]));

  return {
    id: scenario.id + (variant !== undefined ? `[${variant}]` : ""),
    key: scenario.key,
    variant,
    title: scenario.title,
    bursts,
    burstSteps,
    aliveBefore,
    alive,
    mouseGrabs,
    p50: median(p50s),
    p95: median(p95s),
    p99: median(burstResults.map((b) => b.timing.p99)),
    max: Math.max(...burstResults.map((b) => b.timing.max)),
    spreadP50: p50s.length > 1 ? (Math.max(...p50s) - Math.min(...p50s)) / median(p50s) : 0,
    phases: phaseMeanAcross,
    counters: rep.counters,
    stackHwm: burstResults.reduce((m, b) => (b.stackHwm.bytes > m.bytes ? b.stackHwm : m), burstResults[0].stackHwm),
    memoryPages: host.memoryPages(),
    checksum,
    checksumHex: checksum.toString(16).padStart(8, "0"),
    burstResults,
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
