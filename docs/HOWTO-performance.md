# HOWTO: Performance Measurement & Measurement-Driven Optimization

*Adapted from `asimov-happy/docs/HOWTO-performance.md` and `docs/flows/performance--heap-trash.md`
for this Zig → WASM + WebGPU app (2026-08-16). Plan:
[`plans/2026-08-16--performance-testing-plan.md`](plans/2026-08-16--performance-testing-plan.md).
Principles: [`principles/kaizen.md`](principles/kaizen.md), [`principles/determinism.md`](principles/determinism.md).*

## TL;DR

1. **Measure first.** Capture a baseline before touching code.
2. **Make one narrow change.** Never bundle experiments.
3. **Re-measure with the same harness**, same machine, same profile, same scenario.
4. **Keep only what the numbers justify.** Flat / noisy / worse → revert. Inconclusive → fix the measurement first.
5. **No assumptions about the runtime** (V8 wasm tier-up, WebGPU driver, GC). The harness is the authority.
6. **The checksum must not move** unless a physics change was intended (and then say so).

## Commands (run from the repo root, one at a time)

```bash
npm run test:zig              # zig build test — arena / spatial / determinism unit tests (native)
npm run bench:sim             # Tier 1: all scenarios, step timing + phase split + counters + checksum
npm run bench:sim -- --only S2,S3 --json out.json --md out.md
npm run bench:sim:assert      # THE GATE: self-consistency, Debug≡ReleaseFast, p95 ceilings, memory ceilings, goldens (advisory)
npm run bench:sim:assert -- --set-thresholds   # (re)write bench/thresholds.json from this run × 1.25 — only after a kept win or a deliberate re-baseline
npm run bench:sim:assert -- --update-goldens   # regenerate bench/goldens/* — only with an intended physics change, noted in docs/progress/performance
npm run bench:sim:scaling     # particles × iterations matrix, flags super-linear phases
npm run bench:memory          # wasm sections, linear-memory pages, static budget, stack HWM per scenario, GPU buffer bytes
npm run bench:browser         # Tier 2: headless Chromium + WebGPU — frame ring, JS gross alloc (CDP), DOM mutations, page errors
npm run bench:browser:assert  # Tier 2 gate: zero page errors; APP alloc B/s + DOM mutations/frame ≤ ceilings (per adapter mode)
GPU=1 npm run bench:browser   # real adapter (Vulkan, blocklist ignored) instead of SwiftShader; HEADED=1 to watch
```

Environment: `MORPHO_BENCH_PROFILE=fast|slow` (default `fast`; slow = shorter bursts, no S6),
`MORPHO_WASM=<path>` to measure a specific wasm (must be built with `-Dperf=true`).
The harness builds `bench/.build/<mode>/bin/webgpu-demo.wasm` itself when sources are newer.

Never run two benchmarks in parallel. Record the header block (machine, profile, zig, git, wasm sha)
in every note — compare only matched headers.

## What the harness measures

| Metric | Source | Role |
|---|---|---|
| `p50/p95/p99/max` ms per `update_particles` | Node `hrtime` around the export; median over bursts | **primary** |
| phase means: `predict, mouse, bonds, gen_springs, gen_grid, gen_collide, solve, commit` | `src/perf.zig` ring via imported `perf_now` (`-Dperf=true`) | **attribution** — which phase moved |
| `constr/it`, `coll/it`, `bin`, `bonds_formed`, `springs_removed` | `perf.zig` counters | workload descriptors — compare only when similar |
| `P`, `S` (alive particles / springs) | exports | workload |
| checksum | FNV-1a over dense state (`state_checksum`) | **correctness oracle** |
| stack HWM | sentinel-painted shadow stack (`perf_stack_hwm`, `+` = saturated probe) | memory |
| linear-memory pages, wasm bytes | host | memory (static; growth = bug) |
| spread | (max−min)/median of burst p50s | noise indicator; > ~15 % ⇒ re-run before trusting a delta |

Tier 2 (`bench/browser-bench.mjs`) adds, per phase (`idle-paused`, `steady`, `drag`, `paint`, `reset-storm`):

| Metric | Source | Role |
|---|---|---|
| `sim/upload/submit` p50/p95, `frame p95`, fps | `window.__morphoTimingRing` (script.js, zero-alloc) | in-app timing; **fps under SwiftShader is a software-raster artefact — use `GPU=1` for anything about rendering** |
| `APP KB/s` (script.js + renderer.js) vs `runtime KB/s`, top allocators | CDP `HeapProfiler` sampling (4 KB interval); attribution is per *function* (line = function start) | **primary for render-path work**; goal 0 (0/0/0 rule) |
| DOM mutations (+ sources) | MutationObserver | goal 0 per frame |
| page / console errors, adapter string, `crossOriginIsolated`, timer resolution | Playwright / probe | hygiene + provenance |

The static server used by the harness serves the repo root with COOP/COEP and overrides
`/webgpu-demo.wasm` with the perf build, so the shipped wasm is never touched.

## Judging a result

**Keep** when p95 (or the targeted phase) drops repeatably across ≥ 2 runs, workload descriptors are
similar (±5 %), checksum unchanged (or intentionally changed + re-goldened), code stays kaizen-clean.
**Revert** when flat/worse; when the win only appears because workload collapsed (fewer constraints,
fewer springs); when the window was polluted (warm-up not plateaued, another process running).
**Inconclusive** when bursts disagree by more than the claimed delta (check `spread`); phase
boundaries moved; sample counts differ. Inconclusive never justifies keeping speculative code.

Comparison checklist: same machine id · same profile · same wasm build mode · same scenario version ·
similar `constr/it` and `S` · warm-up plateaued.

## Where to record

- Every measurement: `docs/progress/performance/<yyyy>/<mm>/<ISO-ts>--<tag>.md` — standalone: what
  changed, why, exact commands, header block, pasted tables, interpretation, keep/revert.
- Cross-cutting reports (baselines, scaling / memory studies): `docs/perf/`.
- Plans: `docs/plans/`. Markdown only; JSON stays out of the repo unless a study needs it.

## Pitfalls specific to this app

- **Build mode.** `./build.sh` and plain `zig build` are ReleaseFast; the harness builds its own
  perf wasm per mode. Debug is ~6× slower and is used for correctness (safety checks + checksum
  equality), never for timing.
- **Warm-up.** V8 tiers wasm up; the harness runs 300 steps first and prints the ms/step curve with a
  plateau check. If it says `plateau=NO`, don't trust the first scenario's numbers.
- **`gen_collide` dominates** (58–88 % at baseline). A change elsewhere will look "flat" in total
  ms — read the phase table, not just p50.
- **S5 (drag) currently equals S2** — the mouse handle is stale after `reset()` (known bug); the
  scenario is kept so the fix has to make it diverge.
- **Tier 1 vs Tier 2 sim time differ** at baseline (S2: 3.0 ms in Node vs 4.9 ms in Chromium, same wasm,
  same state). Not yet explained (main-thread interleaving with rendering? V8 flags?). Until it is,
  compare Node-to-Node and browser-to-browser only.
- Tier 2 `grabs` is not a correctness oracle for the drag (grab_count increments even with a stale
  mouse handle); the checksum divergence S5≠S2 is.
- Stack HWM `+` means the probe saturated (real use ≥ probe); the probe covers the whole shadow
  stack on wasm, so `+` there means overflow is imminent.
