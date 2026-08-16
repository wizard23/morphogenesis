# Plan: Performance & Memory Tests for Morphogenesis

*Drafted 2026-08-16 against commit `6cd6947`. Companion to
[`docs/reports/2026-08-16-app-analysis.md`](../reports/2026-08-16-app-analysis.md).*
*Status: **READY** (decisions recorded 2026-08-16, see §0a). Milestone 1 = Phases 0, 1, 2, 3, 5, 6.*

## 0a. Decisions (2026-08-16)

| Question | Decision |
|---|---|
| Canonical Zig version | **0.16.0**. Update `build.sh` (drop the Homebrew 0.14 path) and README. Goldens keyed by version + optimize mode anyway. |
| Plain `zig build` mode | Set `preferred_optimize_mode = .ReleaseFast` in `build.zig` so IDE/plain builds match `build.sh`; `-Doptimize=Debug` still available. |
| Checksum policy | **Self-consistency is the hard failure** (two runs of the same build/scenario must match). **Committed goldens are advisory** — compared and reported, warn-only, regenerated with `--update-goldens` + a note — until physics tuning settles; then promote to hard. |
| Debug build in the gate | **Yes, correctness only**: run scenarios in Debug for safety-check panics and assert Debug ≡ ReleaseFast checksum; no timing thresholds on Debug. |
| Timing thresholds | Baseline p95 × **1.25** per scenario/profile; ratchet down after kept wins. |
| Machine profile of this machine | **fast** (full set incl. S6). |
| S5-path bugs (stale mouse handle after Reset, dangling stack slices) | **Baseline as-is**; fix afterwards as measured changes (each its own baseline → change → re-measure). Note the caveat in the S5 baseline. |
| Harness location | `bench/` + scripts in root `package.json`; Tier 1 has no new dependencies (Node ≥ 24 only). |
| Zig phase clock | **Import `perf_now()` from the host** (script.js and Node harness both supply it). Not phase-split exports. |
| Arena unit tests in Phase 1 | **Yes** (`zig build test`: spawn/destroy/generation, dense order, checksum self-consistency, `worldToGrid`, valence saturation). |
| Harness JSON in repo | **Markdown only**; paste tables into progress notes, JSON stays in scratch unless a study needs it. |
| COOP/COEP on dev server | **Yes** in Phase 3 (5 µs `performance.now()`, `measureUserAgentSpecificMemory`). No cross-origin resources today, so no CORP fallout. |
| Scenarios | **All seven** (S1–S7) at fixed 1920×1080; S7 gets `set_xpbd_iterations`; S6 fast-profile only. |
| Extras | **Track ReleaseFast wasm size** as a gate ceiling next to memory ceilings. No pre-push hook, no CI for now. |
| Milestone split | **M1** = Phases 0, 1, 2, 3, 5, 6 (no browser). **M2** = Phase 4 (browser tier) after the headless-WebGPU spike, plus Phase 7 wiring. |

## 0. Why this plan looks the way it does — what we take from `asimov-happy`

`../asimov-happy` has ~4 months of measurement-driven optimisation practice. The parts worth
carrying over verbatim (with the source file for reference):

| Practice | Where it lives in asimov-happy | Adopted here as |
|---|---|---|
| **Measure first, one narrow change, re-measure with the same harness, keep/revert/inconclusive** | `docs/HOWTO-performance.md`, `docs/flows/performance--heap-trash.md` | §1 rules, copied into a new `docs/HOWTO-performance.md` |
| **No assumptions about the runtime** — the profiler, not folklore, is the authority; distinguish bytes vs count vs rate vs timing | `docs/HOWTO-performance.md` §Principle 1 | §1 |
| **Zero-alloc in-app timing ring** (512 frames × phases, `window.__ecTimingRing.reset()/read()`), written from the hot loop with `performance.now()`; bench hooks (`__ecBenchStepBurst`, `__ecReadMetrics`, `__ecBenchSet*`) | `packages/web/src/app/ec-devapp-route.tsx:967-992`, plan `docs/plans/2026-05-31--measurement-tiers-1-2-3.md` | Phase 3 (`window.__morphoTimingRing`, `window.__morphoBench`) |
| **Sim-only bursts vs in-app rate** as two separate numbers; warm-up before measurement; median of repeated windows; print what actually ran (rule/renderer) | `e2e/sim-steps-perf.mjs` | Phase 2 (Node WASM bursts) + Phase 4 (browser rate); §7 honesty rules |
| **Playwright + headless Chromium harness** that owns its servers, pre-warms every path, then runs named phases (`idle`, `hover`, `click_drag`) and reports per-phase deltas | `scripts/benchmark-devapp-idle.ts` | Phase 4 |
| **CDP `HeapProfiler.startSampling` for gross allocation** (catches literals; constructor `Proxy` counters miss them), APP (`/src/`) vs runtime noise split, `gc()` between scenarios | `scripts/benchmark-devapp-idle.ts:265-270`, `e2e/perf-baseline.mjs`, `e2e/player-heap-bench.mjs` | Phase 4 |
| **Net heap delta is the weakest signal**; primary metrics are gross alloc bytes/sec, DOM mutations, phase-local timing | `docs/flows/performance--heap-trash.md` §What The Metrics Mean | §5 metric table |
| **Deterministic structural memory counts** via an introspection hook instead of raw heap when the environment inflates heap numbers | `e2e/paint-render-memory-bench.mjs` header | Phase 5 (WASM static/stack accounting) |
| **Percentiles p50/p95/p99/max** over a ring, scaling matrix, stabilisation delay before each window | `scripts/benchmark-devapp-scaling.ts` | Phase 2 + Phase 6 |
| **Regression gate `bench:*:assert`** with hard thresholds, non-zero exit, tightened ("ratcheted") after each win | `scripts/benchmark-devapp-assert.ts` | Phase 2 gate, Phase 4 gate |
| **Machine profiles** (`slow`/`fast`), record machine id in every note, never run two benchmarks in parallel, compare only matched conditions | flow doc §Machine Profiles, `AGENTS.md` §Performance Work | §7 |
| **Where results go**: standalone progress notes `docs/progress/performance/<yyyy>/<mm>/<ts>--<tag>.md` (what/why/commands/raw output/interpretation/decision); cross-cutting reports in `docs/perf/`; plans in `docs/plans/` | flow doc §Record Location, `AGENTS.md` | §8 |

What is **different** here and forces changes to that recipe:

- The hot path is **WASM (Zig) CPU time**, not JS allocation. Zig has no GC and no allocator in this
  code base — all memory is static arrays + stack. So the primary metric is `update_particles` time
  (split by physics phase), and the memory questions are *static footprint*, *stack high-water*,
  and *GPU buffer bytes*, not heap churn. JS-side allocation still matters (the render path allocates
  every frame today), but it is the secondary gate.
- The sim is **deterministic** (fixed `dt`, no runtime RNG, `sin`-hash initial positions), so a
  state checksum after N steps is a cheap correctness oracle for every optimisation — asimov-happy
  has determinism verifies; we get one nearly for free.
- The sim can run **without a browser**: Node 24 instantiates the WASM directly (verified in a spike
  today: 471 pages = 30.9 MB linear memory, 933 particles / 1 159 springs, **~3.1 ms/step** on this
  machine after a 200-step warm-up). That gives a fast, deterministic, CI-able Tier 1 that
  asimov-happy never had for its GPU kernels.
- Rendering is **WebGPU**, not WebGL. Headless Chromium WebGPU needs explicit flags and may fall back
  to SwiftShader/none — a spike is required before Phase 4 is scheduled (§9 risks).

---

## 1. Ground rules (adopted verbatim)

1. **Baseline before code.** Capture and save numbers before editing.
2. **One narrow change per experiment.** Never bundle cleanup with an optimisation.
3. **Same harness, same machine profile, same scenario, similar sample counts** — or it is not a comparison.
4. **Keep only what the numbers justify.** Flat / noisy / worse → revert. Inconclusive → fix the measurement first.
5. **No assumptions about the runtime** (V8's wasm tier-up, WebGPU driver, GC). Hypothesise, then prove with the harness.
6. **Match the metric to the claim**: ms/step, p95, bytes, count, and rate are different questions.
7. **Print what actually ran**: build mode (`ReleaseFast`/`Debug`), wasm size, machine id, WebGPU adapter/renderer, scenario parameters. A number without provenance is not recorded.
8. **Run benchmarks sequentially, never in parallel.**
9. **Ratchet**: after a kept win, tighten the relevant threshold in the assert gate.

---

## 2. Goals

- G1 — A **fast regression gate** (`npm run bench:sim:assert`, < 60 s, no browser) that fails on: sim
  time regression per scenario beyond threshold, determinism checksum mismatch, static memory growth
  beyond threshold.
- G2 — **Attribution**: per-phase timing inside `update_particles` (predict / bond search /
  constraint gen: springs, grid populate, collisions / solve / commit) and workload counters, so a
  regression or a win can be attributed to a phase, not guessed.
- G3 — **Scaling curves**: ms/step vs particle count, spring count, and XPBD iterations; identify the
  O(n²) knees (bond search, `already_connected` scan) with data.
- G4 — **Memory accounting**: static wasm footprint by symbol/section, linear-memory pages, per-call
  stack high-water mark, GPU buffer bytes, JS gross allocation/sec in the render loop.
- G5 — **Browser reality check**: in-app frame timing (sim / upload / submit), JS alloc bytes/sec
  (target: 0 KB/s steady-state), rendering cost — measured, not inferred from Tier 1.
- G6 — **Documentation discipline** identical to asimov-happy so notes are comparable over time.

Non-goals: fixing any of the issues the harness will surface (that is follow-up work, each its own
baseline → change → re-measure cycle); GPU-side timing (WebGPU timestamp queries) — deferred.

---

## 3. Architecture of the test suite

```
morphogenesis/
├─ bench/                          # NEW — all harness code (Node ESM, no build step)
│  ├─ lib/
│  │  ├─ wasm-host.mjs             # instantiate wasm w/ stub imports; perf_now → hrtime; helpers
│  │  ├─ stats.mjs                 # percentile/median/dist, table + JSON formatting (mirrors asimov-happy)
│  │  ├─ scenarios.mjs             # named scenario builders (S1..S6) using only wasm exports
│  │  ├─ machine.mjs               # machine id (hostname+cpu model), profile slow|fast, git sha, wasm sha
│  │  └─ report.mjs                # write JSON + markdown block for progress notes
│  ├─ sim-bench.mjs                # Tier 1: warm-up → bursts → p50/p95/p99 per scenario + phase split
│  ├─ sim-assert.mjs               # Tier 1 gate: thresholds + determinism goldens + memory ceilings
│  ├─ sim-scaling.mjs              # Tier 1 matrix: particles × iterations × springs
│  ├─ memory-report.mjs            # static footprint (sections/symbols), pages, stack HWM, GPU bytes
│  ├─ browser-bench.mjs            # Tier 2: Playwright + CDP, phases idle/drag/paint, alloc + timing ring
│  ├─ browser-assert.mjs           # Tier 2 gate: APP alloc/sec ≤ threshold, no page errors
│  ├─ goldens/                     # determinism checksums per scenario per N steps (JSON)
│  └─ README.md                    # commands, profiles, what each number means
├─ src/perf.zig                    # NEW — comptime-gated instrumentation (ring, counters, checksum)
├─ docs/HOWTO-performance.md       # NEW — adapted from asimov-happy
├─ docs/progress/performance/YYYY/MM/<ts>--<tag>.md   # every measurement
└─ docs/perf/                      # cross-cutting reports
```

Two tiers, deliberately:

| Tier | Runs in | Measures | Cost | Use |
|---|---|---|---|---|
| **1 — Sim-only (Node + wasm)** | Node 24, `WebAssembly.instantiate` with stub imports | wasm step time (total + per phase), counters, checksum, linear-memory pages, stack HWM | seconds, deterministic, no GPU | the gate; every optimisation loop iteration |
| **2 — In-app (Playwright + Chromium)** | headless Chromium with WebGPU flags | frame timing ring (sim / upload / submit / frame), JS gross alloc (CDP), DOM mutations, page errors, adapter string | 30–90 s, GPU-dependent, noisier | render-path work; before hand-off; periodic reality check |

Tier 1 numbers and Tier 2 sim numbers must agree within noise (same wasm, same V8) — a divergence
is itself a finding (e.g. `performance.now()` clamping, main-thread contention).

---

## 4. Scenarios (fixed, named, versioned)

All are built purely through existing/added wasm exports so Tier 1 and Tier 2 run the *same* thing.
World is fixed at 1920×1080 logical px (Tier 2 sets the viewport accordingly).

| Id | Name | Construction | Exercises |
|---|---|---|---|
| **S1** | `default-settle` | `init`, `set_world_dimensions(1920,1080)`, run 600 steps | initial bonding burst, `updateValenceBonds` O(n²) on 933 particles, spring formation |
| **S2** | `default-steady` | S1 then measure the next N steps | steady-state cost of the shipped scene (the "idle" analog) |
| **S3** | `dense-pile` | S1 + paint 3 000 valence-0 particles in a 400×300 px block at top centre; let fall 600 steps; measure | collision-heavy: grid populate, 3×3 neighbour scans, contact constraints, bin occupancy |
| **S4** | `bond-churn` | S1 + paint 2 000 valence-6 particles in a 500×500 block; measure | bond search + `already_connected` linear scan + spring breaking/refund |
| **S5** | `drag` | S2 + `set_mouse_interaction` scripted circular drag over a lattice, 5 grabs | mouse springs, spring breaking at 1.4×, `findParticlesInGrabRadius` (dangling-slice path) |
| **S6** | `capacity` | fill to `PARTICLE_COUNT` (10 932) with valence-2 particles across the world; settle 300; measure | worst case; `MAX_CONSTRAINTS` saturation; stack HWM |
| **S7** | `iterations-sweep` | S2 with `XPBD_ITERATIONS` ∈ {1, 3, 6, 12} (needs export/setter, see Phase 1) | cost per iteration vs quality; solver share |

Each scenario records its **workload descriptors** alongside timings — `alive_particles`,
`alive_springs`, `constraints_per_iteration`, `collision_pairs`, `bonds_formed`, `springs_removed`,
`spatial_max_occupancy` — the analog of asimov-happy's `stepsTotal`/`framesCollected`, and required
for the comparison checklist (§7).

---

## 5. Metrics

| Metric | Source | Role |
|---|---|---|
| `stepMs` p50 / p95 / p99 / max | Tier 1 hrtime around `update_particles`; Tier 2 ring | **primary** |
| `phaseMs[predict, bonds, gen.springs, gen.grid, gen.collide, solve, commit]` avg per step | `perf.zig` ring (imported `perf_now`) | **primary (attribution)** |
| `constraints_per_iter`, `collision_pairs`, `bonds_formed`, `springs_removed`, `bin_max` | `perf.zig` counters | workload / sanity |
| `checksum(N)` | `perf.zig` FNV-1a over dense `x,y,vx,vy` + spring endpoints | **correctness gate** |
| `wasm.memory.buffer.byteLength` (pages) | host | memory (static; must not grow) |
| static footprint by section & top symbols | `wasm-objdump`/`wasm-tools`/`twiggy` if available, else `WebAssembly.Module` custom-section parse + `zig build --verbose-link` map | memory |
| `stack_hwm_bytes` per phase | `perf.zig`: paint the stack region with a sentinel at `perf_reset`, scan from `__stack_pointer` at read | memory (the ~530 KB/iteration copies) |
| GPU buffer bytes | computed from `get_max_particles/get_max_springs` and renderer allocations; `writeBuffer` bytes/frame | memory / bandwidth |
| `frameMs`, `simMs`, `uploadMs` (renderer.updateData), `submitMs` | Tier 2 ring in `script.js`/`renderer.js` | render path |
| `allocBytesTotal`, `allocBytesPerSec` APP vs runtime, top allocators | CDP `HeapProfiler` sampling (Tier 2) | **primary for render-path work** |
| `domMutations`, `pageErrors`, `uncapturederror` | MutationObserver, page events | hygiene |
| `usedJSHeapSize` delta | `performance.memory` | weakest — context only |
| wasm binary size | `stat` | tracked, not gated initially |

---

## 6. Phases of work

Ordered so each phase yields a usable artefact; Phase 2 alone already gives the gate.

### Phase 0 — Conventions & skeleton (½ day)
- Add `docs/HOWTO-performance.md` (adapted from asimov-happy: rules §1, metric meanings §5,
  keep/revert/inconclusive judging, comparison checklist, where to record).
- Create `docs/progress/performance/`, `docs/perf/`, `bench/README.md`.
- `bench/lib/machine.mjs`: machine id = hostname + CPU model + core count; profile from
  `MORPHO_BENCH_PROFILE=slow|fast` (slow: shorter windows, skip S6; fast: full).
- `package.json` scripts (see §10). Add `playwright` as devDependency only in Phase 4.
- **Acceptance**: docs exist; `node bench/lib/machine.mjs` prints the header block used by every note.

### Phase 1 — Zig instrumentation (`src/perf.zig`) (1 day)
- `build.zig`: `preferred_optimize_mode = .ReleaseFast` (decision) and `-Dperf=true|false` option
  → `build_options.perf_enabled`. Update `build.sh` to Zig 0.16 (drop the Homebrew 0.14 path). When false, every hook is a
  comptime no-op (zero cost in the shipped wasm — mirrors asimov-happy's disabled `phase-trace`).
- Import `extern fn perf_now() f64` (host supplies `performance.now`/hrtime; stub returns 0 when the
  page doesn't provide it — `script.js` must add it to `env`).
- Ring buffer `[512][N_PHASES]f32` + counters, all static; exports:
  `perf_reset()`, `perf_ring_ptr()`, `perf_ring_count()`, `perf_counter(id)`,
  `perf_stack_hwm()`, `state_checksum()`.
- Instrument `update_particles` at phase boundaries only (never inside per-particle loops):
  predict → mouse → bonds → [per iteration: gen-springs, gen-grid, gen-collide, solve] → commit.
- Add setters needed by scenarios: `set_xpbd_iterations(n)` (S7). Keep constants as constants
  otherwise (per `claude.md`, don't churn tuning values).
- Stack HWM: on `perf_reset`, fill `[__stack_pointer - STACK_PROBE_BYTES, __stack_pointer)` with a
  sentinel; `perf_stack_hwm()` scans for the first non-sentinel byte. Zig exposes the stack pointer
  as a global in wasm; if it turns out not to be addressable cleanly, fall back to `@frameAddress()`
  deltas at phase boundaries (coarser, still useful).
- Unit tests (`zig build test`, TDD per `docs/principles/determinism.md`): arena
  spawn/destroy/generation invalidation and dense-order behaviour, checksum self-consistency,
  `worldToGrid` mapping, valence saturation.
- **Acceptance**: `zig build -Dperf=true` and default build both succeed; `zig build test` passes;
  Tier 1 spike script reads a non-empty ring; checksum is identical across two runs of S1.

### Phase 2 — Tier 1 harness + gate (1–1½ days)
- `bench/lib/wasm-host.mjs`: load `zig-out/bin/webgpu-demo.wasm` (build first with `-Dperf=true
  -Doptimize=ReleaseFast`; also allow `MORPHO_WASM=` override), stub `console_log` (collect), provide
  `perf_now`, expose typed helpers (`paintBlock`, `dragCircle`, `stepBurst`).
- `bench/sim-bench.mjs`: for each scenario → build → **warm-up** (default 300 steps; V8 wasm tier-up
  from Liftoff to TurboFan must finish before measuring — verify by observing ms/step plateau and
  print the warm-up curve once) → `perf_reset` → 3 bursts × 300 steps → percentiles per burst, median
  of bursts, phase averages, counters, checksum. Output: human table + `--json <path>`.
- `bench/goldens/*.json`: checksums for S1..S7 at fixed step counts, keyed by `zig version` +
  optimize mode. **Advisory** for now (warn on mismatch, never fail); regenerate via
  `--update-goldens` with a progress note saying why. Promote to hard failure once physics settles.
- `bench/sim-assert.mjs`: hard failures = (a) **self-consistency**: two runs of the same
  build/scenario produce identical checksums; (b) **Debug ≡ ReleaseFast** checksum and no Debug
  panic; (c) p95 `stepMs` ≤ threshold per scenario/profile (ReleaseFast only); (d) memory ceilings:
  linear-memory pages, stack HWM, **ReleaseFast wasm file size**. Non-zero exit on failure.
  Initial thresholds = baseline × 1.25; ratchet down after wins.
- `bench/sim-scaling.mjs`: matrix particles ∈ {933, 2k, 4k, 8k, 10 932} × iterations ∈ {3, 6}
  (fast profile) → table with p50/p95 and phase share; flags super-linear phases.
- **Acceptance**: `npm run bench:sim:assert` passes on a clean tree in < 60 s (fast) / < 120 s
  (slow); a deliberate regression (e.g. `XPBD_ITERATIONS` 6→12 in a scratch build) fails it; a
  deliberate physics change fails the golden check.

### Phase 3 — In-app instrumentation (JS) (½ day)
- `script.js`: preallocated `Float32Array(512*4)` ring `[simMs, uploadMs, submitMs, frameMs]`,
  `window.__morphoTimingRing = {reset, read}`; `env.perf_now = () => performance.now()`.
- `window.__morphoBench = { stepBurst(n), paintBlock(...), dragCircle(...), setPaused(b),
  snapshot() → {alive, springs, binMax, checksum, memPages} }` — thin wrappers over exports, no
  UI dependence, so Tier 2 scenarios are the same S1..S6.
- All of it zero-alloc on the frame path (no object literals per frame; `read()` may allocate).
- `dev-server.js`: send `Cross-Origin-Opener-Policy: same-origin` +
  `Cross-Origin-Embedder-Policy: require-corp` so `performance.now()` gets 5 µs resolution instead
  of 100 µs (needed for sub-ms phase timings) and `performance.measureUserAgentSpecificMemory()`
  becomes available.
- **Acceptance**: ring fills at 60 Hz in the running app; `__morphoBench.snapshot()` matches Tier 1
  values for S2 (same alive/springs/checksum).

### Phase 4 — Tier 2 browser harness (1½ days, after the WebGPU spike in §9)
- `bench/browser-bench.mjs` (Playwright, `/usr/bin/chromium` like asimov-happy): start
  `dev-server.js` on a free port (or a minimal static server), launch Chromium with
  `--enable-unsafe-webgpu --enable-features=Vulkan --use-angle=swiftshader` (or `GPU=1` for real
  hardware, like asimov-happy's `sim-steps-perf.mjs`), **print the adapter info** on every run.
- Phases (2 s each, `HeapProfiler.startSampling` around each, `gc()` before): `idle-paused`,
  `steady` (S2 playing), `drag` (S5), `paint` (S3 painting), `reset-storm` (5× Reset).
- Report per phase: ring percentiles, `allocBytesTotal/PerSec` **APP (`script.js`, `renderer.js`)
  vs runtime**, top 20 allocators (function:line), DOM mutations, page errors.
- `bench/browser-assert.mjs`: APP `allocBytesPerSec ≤ threshold` in `steady` and `drag`; zero page
  errors / `uncapturederror`. Expected first run: **fails** — `renderer.js` allocates every frame
  (`new Float32Array` grid lines, two `Float32Array` views, the `updateData` result object, status
  strings). That is the harness proving itself; fixing it is follow-up work.
- **Acceptance**: runs unattended; identical scenario ids to Tier 1; sim ms agrees with Tier 1
  within ~10 %.

### Phase 5 — Memory report (½–1 day)
- `bench/memory-report.mjs`: (a) linear-memory pages after `init` and after S6 (must be equal — no
  allocator; growth = bug); (b) static footprint: `wasm-objdump -h` / `wasm-tools objdump` if
  present, else parse the wasm binary's section sizes in JS and read `zig build --verbose-link` /
  `-femit-map` for top symbols (`spatial_grid` ≈ 20 MB, `constraints` ≈ 7 MB, arenas…); (c) stack
  HWM per scenario from `perf_stack_hwm()`; (d) GPU buffer bytes and `writeBuffer` bytes/frame from
  Tier 2; (e) wasm file size per optimize mode.
- Writes a markdown table suitable for `docs/perf/`.
- **Acceptance**: report reproduces the ~28–31 MB static budget from the analysis by symbol; stack
  HWM shows the `generateConstraints` temporaries; ceilings feed `sim-assert`.

### Phase 6 — Baseline capture & first report (½ day)
- Run everything sequentially on this machine (record id + profile), both `ReleaseFast` and `Debug`
  wasm for the sim gate (Debug catches the `u8` underflow panic path etc.).
- Write `docs/progress/performance/2026/08/<ts>--initial-baseline.md` per harness and a
  cross-cutting `docs/perf/2026-08-XX--morphogenesis-performance-baseline.md` with the scaling curves
  and memory table.
- Set assert thresholds from these numbers; commit goldens.

### Phase 7 — Wire into the workflow (¼ day)
- `bench/README.md` + `claude.md` note: "before/after any change to `src/*.zig` hot paths run
  `npm run bench:sim:assert`; before hand-off of render changes run `npm run bench:browser:assert`;
  record in `docs/progress/performance/`".
- Optional: `dev-server.js` prints a reminder when a `.zig` rebuild happens; optional git pre-push
  hook running the Tier 1 gate.

Total: ~6–7 working days for everything; **Milestone 1** (Phases 0, 1, 2, 3, 5, 6 — no browser)
≈ 4 days and delivers the gate, the in-app ring, and the memory report. **Milestone 2** = Phase 4
after the headless-WebGPU spike, then Phase 7.

---

## 7. Judging & honesty rules (adopted from the flow doc)

**Keep** when: p95 `stepMs` (or the targeted phase) drops repeatably across ≥ 2 runs; counters show
the same workload (±5 %); checksum unchanged (or intentionally changed and re-goldened); code stays
kaizen-clean. **Revert** when: flat/worse; the win only appears because workload collapsed (fewer
constraints, fewer springs — check the descriptors); the harness window was polluted (warm-up
incomplete, other benchmark running). **Inconclusive** when: bursts disagree by more than the
claimed delta; phase boundaries moved; sample counts differ.

Comparison checklist before trusting a delta: same machine id, same profile, same wasm build mode,
same scenario version, same warm-up, similar `constraints_per_iter` / `alive_springs`, adapter
string identical (Tier 2).

Tier-2 caveat to state in every note (asimov-happy learned this the hard way): SwiftShader numbers
are software-renderer artefacts; only the JS-vs-GPU split transfers. Use `GPU=1` for anything
claimed about rendering cost.

---

## 8. Recording

- Every measurement: `docs/progress/performance/<yyyy>/<mm>/<ISO-ts>--<tag>.md` — standalone: what
  changed, why, exact commands, machine block, raw/summarised output (paste the harness table),
  interpretation, keep/revert.
- Cross-cutting reports (baseline, scaling study, memory study): `docs/perf/`.
- Plans for optimisation efforts: `docs/plans/`, each linking its baseline note.
- Harness JSON outputs may be committed next to the note (`*.run1.json`) as asimov-happy does for
  the SOM training runs.

---

## 9. Risks & spikes (do before committing to Phase 4/5 dates)

| Risk | Mitigation / spike |
|---|---|
| Headless Chromium has no WebGPU adapter (`navigator.gpu.requestAdapter()` → null) | 1-hour spike: try `--enable-unsafe-webgpu --enable-features=Vulkan --use-angle=swiftshader`, `--use-webgpu-adapter=swiftshader`, and `GPU=1` headed on this machine; print `adapter.info`. If none works, Tier 2 measures the JS path with a **null-renderer fallback** (skip pipeline creation, keep `updateData`) — still valuable for alloc gating. |
| `perf_now` import call overhead distorts phase timings | measure the overhead (call it 1e6× in a loop) and subtract; phases are ≥ tens of µs so it should be noise |
| V8 wasm tier-up makes early steps slow → warm-up too short | print ms/step for the warm-up window once; assert plateau (last 50 steps within 10 % of the previous 50) before measuring |
| Stack-pointer access from Zig for HWM | try `@extern` global `__stack_pointer`; fallback `@frameAddress()` at phase boundaries |
| `performance.now()` 100 µs clamping in the browser | COOP/COEP headers (Phase 3); verify with a resolution probe |
| Determinism goldens brittle across Zig versions / optimize modes (float reassociation) | key goldens by `zig version` + optimize mode; ReleaseFast should not enable fast-math but verify with the Debug/ReleaseFast pair |
| Timing noise on laptops | slow profile with more bursts and medians; record thermal state note if it matters |

---

## 10. Commands (target shape)

```bash
npm run build:perf            # zig build -Dperf=true -Doptimize=ReleaseFast (+ copy)
npm run bench:sim             # Tier 1 tables for S1..S7 (fast) — MORPHO_BENCH_PROFILE=slow to shorten
npm run bench:sim:assert      # Tier 1 gate: thresholds + goldens + memory ceilings, exit≠0 on fail
npm run bench:sim:scaling     # particles × iterations matrix
npm run bench:memory          # static footprint / pages / stack HWM / GPU bytes report
npm run bench:browser         # Tier 2 phases with CDP alloc + timing ring (prints adapter)
npm run bench:browser:assert  # Tier 2 gate: APP alloc/sec + zero page errors
# env: MORPHO_BENCH_PROFILE=slow|fast  GPU=1  MORPHO_WASM=<path>  --json <out>  --update-goldens
```

---

## 11. Expected first findings the harness should surface (to validate it, not to fix now)

From the analysis report — the harness is working if it *shows* these rather than us asserting them:

- Phase split: `gen.grid` (per-iteration full particle copy + populate, ×6) and `bonds`
  (O(n²)) dominate S1/S4; `gen.collide` dominates S3; `solve` scales linearly with
  `constraints_per_iter`.
- Stack HWM ≈ 0.5 MB inside `generateConstraints`.
- Linear memory fixed at 471 pages regardless of scenario.
- Tier 2 `steady`: non-zero APP alloc/sec from `renderer.js` (`updateGridLines`, `updateData`) and
  `script.js` status string.
- Tier 2 `reset-storm`: after Reset, drag scenario produces zero mouse-spring effect (stale mouse
  handle bug) — a behavioural regression the harness can catch by asserting `grab_count > 0`
  after a scripted press.
