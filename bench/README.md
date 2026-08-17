# bench/ — Tier 1 performance harness (Node + wasm, no browser)

See `docs/HOWTO-performance.md` for how to run and judge, and
`docs/plans/2026-08-16--performance-testing-plan.md` for the design.

| File | Purpose |
|---|---|
| `sim-bench.mjs` | scenarios S1–S7: warm-up → bursts → p50/p95/p99, phase split, counters, checksum |
| `sim-assert.mjs` | the gate: self-consistency, Debug≡ReleaseFast, p95 ceilings, memory/wasm-size ceilings, goldens (advisory) |
| `sim-scaling.mjs` | particles × iterations matrix |
| `memory-report.mjs` | wasm sections, pages, static budget, stack HWM per scenario, GPU buffer bytes |
| `browser-bench.mjs` | Tier 2: headless Chromium + WebGPU (SwiftShader, or `GPU=1`), phases idle/steady/drag/paint/reset-storm; ring, CDP alloc, DOM mutations, errors |
| `browser-assert.mjs` | Tier 2 gate: zero page errors; APP alloc B/s + DOM mutations/frame ≤ ceilings per adapter mode |
| `lib/browser.mjs` | static server (COOP/COEP, perf wasm override), Chromium launch flags, adapter probe, CDP aggregation |
| `lib/scenarios.mjs` | scenario builders (export calls only; shared with the future browser tier) |
| `lib/runner.mjs` | warm-up + burst runner |
| `lib/wasm-host.mjs` | builds `bench/.build/<mode>/` with `-Dperf=true`, instantiates with `perf_now` |
| `lib/machine.mjs`, `lib/stats.mjs`, `lib/report.mjs` | provenance header, percentiles, tables |
| `thresholds.json` | per-profile p95 / memory / wasm-size ceilings (ratchet after kept wins) |
| `goldens/` | advisory checksums per zig version + mode |

Requires Node ≥ 24 and Zig 0.16 on `PATH`. Tier 1 has no npm dependencies; Tier 2 needs
`npm install` (Playwright) and a Chromium (`/usr/bin/chromium` by default, or
`PLAYWRIGHT_CHROMIUM_EXECUTABLE`).
