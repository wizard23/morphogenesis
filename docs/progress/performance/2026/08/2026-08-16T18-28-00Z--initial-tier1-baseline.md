# Initial Tier 1 baseline — sim gate, memory, Debug≡ReleaseFast

**Machine:** imac-battleship / Intel Xeon W-2170B @ 2.50 GHz / 28 cores
**Profile:** fast · **Node:** v24.14.1 · **Zig:** 0.16.0 · **git:** 4a595a0 (dirty: instrumentation + harness uncommitted at run time)
**wasm:** `bench/.build/ReleaseFast/bin/webgpu-demo.wasm` 1 808 779 B, sha `daa107f7cfe8` (built `-Dperf=true`, 4 MiB stack)
**Plan:** `docs/plans/2026-08-16--performance-testing-plan.md` (Phases 1, 2, 5) · **Purpose:** first baseline; sets `bench/thresholds.json` and advisory goldens. No optimisation attempted.

## What changed (instrumentation only, physics untouched)

- `src/perf.zig` (`-Dperf=true`): phase ring, counters, `state_checksum`, stack HWM; `perf_now` host import.
- `src/host.zig`: host externs with native stubs → `zig build test` (7 tests: arena, spatial, determinism, HWM).
- `build.zig`: default ReleaseFast, `-Dperf`, `test` step, **`stack_size = 4 MiB`** — the Debug wasm
  trapped at `ParticleArena.init()` with the default 1 MiB shadow stack (init-by-value copies a
  ~570 KB struct; `generateConstraints` adds ~530 KB of temporaries). Physics semantics unchanged;
  checksums verified equal before/after in ReleaseFast (`f983a9f8` for S2).
- `bench/` harness (Node, no deps), `npm run bench:sim|bench:sim:assert|bench:sim:scaling|bench:memory|test:zig`.

## Commands

```bash
npm run bench:sim:assert          # created thresholds + goldens (first run), GATE PASS
npm run bench:memory --md …       # sections / pages / static budget / HWM / GPU bytes
npm run bench:sim:scaling --md …  # see docs/perf/2026-08-16--tier1-baseline-report.md
```

Warm-up ms/step by 50-step chunk: 3.698 2.978 2.767 2.773 2.768 2.726 → plateau **yes** (~300 steps suffice).

## Step timing (ms/step, median over bursts; fast profile 3×300, S1 1×600, S7 1×300)

| scenario | P | S | p50 ms | p95 ms | p99 ms | max ms | spread | constr/it | coll/it | bin | hwm KB | checksum |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | 932 | 1160 | 2.506 | 3.321 | 3.873 | 4.630 | 0.0% | 1183 | 26 | 28 | 338 | ca54662f |
| S2 | 932 | 1160 | 2.990 | 4.904 | 7.800 | 9.112 | 31.0% | 1539 | 379 | 44 | 338 | f983a9f8 |
| S3 | 3932 | 1184 | 18.295 | 26.292 | 44.557 | 56.657 | 42.2% | 6108 | 4924 | 48 | 338 | d9d26d39 |
| S4 | 2957 | 7012 | 14.701 | 20.878 | 32.456 | 70.390 | 25.4% | 7682 | 669 | 44 | 423 | a064f2aa |
| S5 | 932 | 1160 | 2.207 | 2.426 | 3.114 | 3.842 | 2.5% | 1539 | 379 | 44 | 338 | f983a9f8 |
| S6 (bench only) | 10907 | 11172 | 66.457 | 100.438 | 129.080 | 188.221 | 16.5% | 21723 | 10553 | 44 | 423 | 5a833969 |
| S7[1] | 932 | 1047 | 0.810 | 0.999 | 1.157 | 1.269 | 0.0% | 2001 | 933 | 88 | 423 | 2cd52ad7 |
| S7[3] | 932 | 1160 | 1.696 | 2.986 | 4.141 | 5.539 | 0.0% | 1309 | 149 | 38 | 338 | 2775fdf4 |
| S7[6] | 932 | 1160 | 2.569 | 3.404 | 3.887 | 4.383 | 0.0% | 1328 | 168 | 42 | 338 | 659d8037 |
| S7[12] | 932 | 1171 | 5.760 | 7.344 | 14.077 | 17.736 | 0.0% | 1358 | 191 | 41 | 338 | db959338 |

(S6 row from the preceding `bench:sim` run at 18:20Z, same build; S6 is excluded from the gate — 77 s per pass.)

## Phase split (mean ms/step, share of instrumented sum)

| scenario | predict | mouse | bonds | gen_springs | gen_grid | gen_collide | solve | commit | sum |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S1 | 0.004 | 0.000 | 0.323 (13%) | 0.099 (4%) | 0.082 (3%) | 1.720 (71%) | 0.188 (8%) | 0.003 | 2.420 |
| S2 | 0.008 | 0.000 | 0.394 (12%) | 0.121 (4%) | 0.102 (3%) | 2.347 (72%) | 0.307 (9%) | 0.003 | 3.282 |
| S3 | 0.017 | 0.000 | 0.983 (5%) | 0.103 (1%) | 0.327 (2%) | 18.085 (89%) | 0.846 (4%) | 0.010 | 20.373 |
| S4 | 0.013 | 0.000 | 3.763 (27%) | 0.606 (4%) | 0.269 (2%) | 8.503 (60%) | 1.014 (7%) | 0.008 | 14.178 |
| S5 | 0.005 | 0.000 | 0.268 (12%) | 0.082 (4%) | 0.070 (3%) | 1.604 (72%) | 0.203 (9%) | 0.002 | 2.234 |
| S6 | 0.046 | 0.000 | 3.465 (5%) | 1.180 (2%) | 1.077 (2%) | 56.841 (85%) | 4.237 (6%) | 0.034 | 66.880 |
| S7[1] | 0.004 | 0.000 | 0.397 (49%) | 0.017 (2%) | 0.013 (2%) | 0.343 (42%) | 0.038 (5%) | 0.002 | 0.814 |
| S7[3] | 0.006 | 0.000 | 0.412 (22%) | 0.063 (3%) | 0.052 (3%) | 1.233 (65%) | 0.132 (7%) | 0.004 | 1.902 |
| S7[6] | 0.005 | 0.000 | 0.316 (12%) | 0.099 (4%) | 0.081 (3%) | 1.912 (73%) | 0.204 (8%) | 0.003 | 2.620 |
| S7[12] | 0.006 | 0.000 | 0.361 (6%) | 0.236 (4%) | 0.194 (3%) | 4.745 (79%) | 0.491 (8%) | 0.003 | 6.038 |

## Gate results

- Self-consistency: all 9 gate scenarios reproduce their checksum ✅
- Debug ≡ ReleaseFast: S1, S2, S5, S7[1,3,6,12] ✅ (S3/S4 not in the Debug set; Debug ≈ 6× slower: S2 17.7 ms/step)
- Thresholds written (`bench/thresholds.json`, fast): p95 × 1.25; pages ≤ 519; stack HWM ≤ 475 913 B; wasm ≤ 1 899 218 B
- Goldens written (`bench/goldens/zig-0.16.0-ReleaseFast.json`, advisory)
- Wall time of the gate: ~4.5 min (2 × ReleaseFast ≈ 70 s each + Debug ≈ 110 s). The plan's "< 60 s" was an aspiration, not a measurement.

## Memory (bench:memory)

- Linear memory **519 pages = 34.0 MB**, static (no growth in any scenario). Static budget from constants sums to 33.3 MB (spatial grid 20.0 MB, constraints 7.2 MB, shadow stack 4.2 MB, arenas 1.1 MB, bulk buffers 0.5 MB, connections 0.3 MB).
- Stack HWM: **345 736 B** (S1/S2/S3/S5), **432 648 B** (S4/S6/S7[1]) — matches the ~530 KB frame estimate minus untouched tail; Debug reaches 424 KB on S2.
- ReleaseFast wasm 1 808 779 B = **code 38 503 B** + **data segment 1 016 767 B (2 segments)** + DWARF ≈ 590 KB + names. Debug: code 90 KB, data 1 019 623 B. Open question: what owns the 1 MB initialised data segment (hypothesis: by-value arena `init()` templates) — verify with the in-place-init change.
- GPU + JS staging buffers ≈ 1.08 MB.

## Interpretation

- **`gen_collide` is 58–89 % of every scenario** (S3 89 %); the analysis report's expectation that `gen_grid` (the per-iteration particle copy) would dominate was wrong by an order of magnitude — the copy is 2–3 %. First optimisation target is the 3×3 neighbour scan (`generateCollisionConstraintsForParticle`: per-neighbour `getDenseCount()`, `isMouseParticle`, sqrt on every pair, sparse-vs-dense index dance).
- **`bonds` is the second cost** and grows with unsatisfied valence: 27 % in S4, 49 % in S7[1]. O(n²) as predicted.
- `solve` is 5–9 %; `predict/commit/mouse` negligible.
- Iterations: S7 p50 0.81 → 1.70 → 2.57 → 5.76 ms for 1/3/6/12 — near-linear in iterations, as constraint generation is repeated per iteration.
- Noise: `spread` 25–42 % on S2/S3/S4 with 300-step bursts on this machine — the p95 × 1.25 ceilings are tight for those; expect occasional false failures until bursts are lengthened or the machine noise is understood (do that *before* trusting a small delta).
- **S5 ≡ S2** (same checksum `f983a9f8`, `grabs = 0`): the drag scenario currently exercises nothing because of the stale mouse handle after `reset()`. Baselined as-is by decision; the fix must make S5 diverge.

## Decision

Baseline recorded; nothing to keep/revert. Follow-ups (each its own baseline → change → re-measure): (1) collision scan hot loop, (2) in-place arena init (stack + data segment), (3) mouse-handle-after-reset fix (S5), (4) bond search via spatial grid.
