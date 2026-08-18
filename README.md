# Morphogenesis

A real-time 2D particle / soft-body sandbox exploring artificial life and morphogenesis (after Michael
Levin and Alan Turing). Particles carry a *valence*, bond to neighbours with springs until it is
satisfied, bonds break when overstretched, and you can drag particles or paint new ones.

- **Simulation**: Zig → `wasm32-freestanding` (XPBD springs, hard contacts, spatial hash, generational
  arenas; deterministic — same inputs, same state).
- **Rendering**: WebGPU (instanced particles, spring lines) from a small vanilla-JS host.

## Run

```bash
./build.sh            # Zig 0.16 → webgpu-demo.wasm (ReleaseFast, stripped; STRIP=0 keeps symbols, PERF=1 adds instrumentation)
npm install           # dev server deps (+ Playwright for the browser benchmarks)
npm run dev           # http://localhost:8000 — rebuilds on .zig changes, hot-reloads the page
```

Any WebGPU-capable browser. Controls: **Q/G** grab & drag · **0–6** spawn tool with that valence
(paint by dragging) · buttons: pause / step / reset. Status line: `fps ms | P:particles S:springs |
world | grid | bin`.

## Layout

| Path | What |
|---|---|
| `src/main.zig` | constants, particle/spring types, step driver, valence bonding, WASM exports |
| `src/physics.zig` | constraint generation (once per step) and the XPBD solver |
| `src/spatial.zig` | spatial hash grid (SoA cells) |
| `src/generational.zig` | generational arena (handles + dense storage) |
| `src/mouse.zig` | cursor as an infinite-mass particle, grab tethers |
| `src/perf.zig`, `src/host.zig`, `src/tests.zig` | instrumentation (`-Dperf`), host shim, unit tests (`zig build test`) |
| `script.js`, `renderer.js` | host: input, loop, WebGPU |
| `bench/` | performance harness — see below |
| `docs/` | plans, reports, principles, measurement notes |

## Performance workflow

Measured, not guessed — see [`docs/HOWTO-performance.md`](docs/HOWTO-performance.md).

```bash
npm run test:zig               # unit tests (arena, spatial, determinism, contact-set oracle)
npm run bench:sim              # Tier 1: wasm step timing per scenario, phase split, counters, checksum
npm run bench:sim:assert       # the gate: determinism, Debug≡ReleaseFast, p95/memory ceilings
npm run bench:sim:ab -- --a HEAD --b .   # interleaved A/B of two builds (paired ratios)
npm run bench:browser          # Tier 2: headless Chromium + WebGPU (GPU=1 for the real adapter)
```

Principles: [`docs/principles/kaizen.md`](docs/principles/kaizen.md),
[`docs/principles/determinism.md`](docs/principles/determinism.md). Current status and history:
`docs/perf/`, `docs/progress/performance/`.
