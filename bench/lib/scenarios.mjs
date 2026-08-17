// Named, versioned scenarios built purely from wasm exports (plan §4). Tier 1 and Tier 2 run
// the same builders. World is fixed at 1920×1080 logical px.
export const WORLD_W = 1920;
export const WORLD_H = 1080;
export const DT = 0.016;
export const SCENARIO_VERSION = 1;

/** Paint a block of particles: rows × cols at `spacing`, centred on (cx, cy). Returns count. */
export function paintBlock(e, { cx, cy, cols, rows, spacing, valence }) {
  const x0 = cx - ((cols - 1) * spacing) / 2;
  const y0 = cy - ((rows - 1) * spacing) / 2;
  let n = 0;
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      e.add_particle(x0 + c * spacing, y0 + r * spacing, valence);
      n++;
    }
  }
  return n;
}

/** [x, y] of the particle at dense index i (from the bulk render buffer). */
export function particlePosition(e, i) {
  const n = e.get_bulk_particle_count();
  if (i >= n) throw new Error(`particle ${i} out of range (${n})`);
  const ptr = e.get_particle_data_bulk();
  const view = new Float32Array(e.memory.buffer, ptr, n * 4);
  return [view[i * 4], view[i * 4 + 1]];
}

export function step(e, n) {
  for (let i = 0; i < n; i++) e.update_particles(DT);
}

export function freshScene(e) {
  e.reset();
  e.set_world_dimensions(WORLD_W, WORLD_H);
  e.set_xpbd_iterations(6);
}

/**
 * Each scenario: { id, key, title, setup(e[, variant]), drive?(e, stepIndex), teardown?(e),
 *   fastOnly?  — only in the fast profile (bench + scaling); never in the assert gate (too slow),
 *   debugGate? — false ⇒ skipped in the gate's Debug pass (Debug is ~6× slower; measured 2026-08-16),
 *   variants?, burstSteps?, bursts? }.
 * `setup` prepares the state up to the first measured step; `drive` is called before every
 * measured step (input injection). Burst lengths default from the runner's profile table.
 */
export const SCENARIOS = [
  {
    id: "S1", key: "default-settle", title: "default scene, first 600 steps (bonding burst)",
    burstSteps: 600, bursts: 1,
    setup(e) { freshScene(e); },
  },
  {
    id: "S2", key: "default-steady", title: "default scene after 600-step settle",
    setup(e) { freshScene(e); step(e, 600); },
  },
  {
    id: "S3", key: "dense-pile", title: "S2 + 3000 valence-0 particles dropped from top centre, after 600-step fall",
    debugGate: false,
    setup(e) {
      freshScene(e); step(e, 600);
      paintBlock(e, { cx: 0, cy: 290, cols: 60, rows: 50, spacing: 10, valence: 0 });
      step(e, 600);
    },
  },
  {
    id: "S4", key: "bond-churn", title: "S2 + 45×45 valence-6 lattice at rest-length spacing, after 100 steps",
    debugGate: false,
    setup(e) {
      freshScene(e); step(e, 600);
      paintBlock(e, { cx: 0, cy: 0, cols: 45, rows: 45, spacing: 15.5, valence: 6 });
      step(e, 100);
    },
  },
  {
    // Presses on an actual particle (dense index 0, read from the bulk buffer) — the lattice has
    // fallen to the floor after the settle, so a fixed press position would grab nothing.
    // History: until 2026-08-17 the drag had no effect (stale mouse handle after reset(), fixed).
    id: "S5", key: "drag", title: "S2 + press on particle 0, circular drag (r=60) around it",
    setup(e) {
      freshScene(e); step(e, 600);
      const [x, y] = particlePosition(e, 0);
      this._cx = x; this._cy = y;
      e.set_mouse_interaction(x, y, true);
    },
    drive(e, i) {
      const a = (i / 300) * 2 * Math.PI;
      e.set_mouse_interaction(this._cx + 60 * Math.cos(a), this._cy + 60 * Math.sin(a), true);
    },
    teardown(e) { e.set_mouse_interaction(0, 0, false); },
  },
  {
    id: "S6", key: "capacity", title: "fill to capacity with valence-2 particles (133×75 grid), after 300-step settle",
    fastOnly: true,
    setup(e) {
      freshScene(e); step(e, 600);
      paintBlock(e, { cx: 0, cy: 0, cols: 133, rows: 75, spacing: 14.2, valence: 2 });
      step(e, 300);
    },
  },
  {
    id: "S7", key: "iterations-sweep", title: "S2 with XPBD iterations ∈ {1,3,6,12}",
    variants: [1, 3, 6, 12],
    burstSteps: 300, bursts: 1,
    setup(e, variant) { freshScene(e); step(e, 600); e.set_xpbd_iterations(variant); },
    teardown(e) { e.set_xpbd_iterations(6); },
  },
];

export function scenariosForProfile(profile, { gate = false } = {}) {
  return SCENARIOS.filter((s) => (profile === "fast" || !s.fastOnly) && !(gate && s.fastOnly));
}
