# Tier 1 baseline report — 2026-08-16

Cross-cutting summary of the first measured baseline (details and raw tables in
`docs/progress/performance/2026/08/2026-08-16T18-28-00Z--initial-tier1-baseline.md`).
Machine imac-battleship (Xeon W-2170B), profile fast, Zig 0.16.0, Node 24, ReleaseFast `-Dperf=true`.

## Headline numbers

| Scenario | P / S | p50 ms/step | dominant phase |
|---|---|---|---|
| S2 default steady (933 particles) | 932 / 1160 | **3.0** | gen_collide 72 % |
| S3 dense pile (+3000 inert) | 3932 / 1184 | **18.3** | gen_collide 89 % |
| S4 bond churn (+2025 valence-6) | 2957 / 7012 | **14.7** | gen_collide 60 %, bonds 27 % |
| S6 capacity (10 907) | 10907 / 11172 | **66.5** | gen_collide 85 % |
| S7 iterations 1 / 3 / 6 / 12 | 932 | 0.81 / 1.70 / 2.57 / 5.76 | linear in iterations |

At 60 fps the budget is 16.7 ms: the default scene uses ~18 % of it in physics; anything past
~3 000 particles is already over budget on this (fast) machine.

## Scaling matrix (uniform valence-2 field, settle 200, measure 300; ms/step)

| P | S | iters | p50 | p95 | µs/particle | bonds | g.grid | g.collide | solve | constr/it |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 933 | 1159 | 3 | 1.246 | 1.398 | 1.34 | 0.275 | 0.035 | 0.818 | 0.087 | 1266 |
| 933 | 1162 | 6 | 2.209 | 3.229 | 2.37 | 0.282 | 0.072 | 1.711 | 0.176 | 1284 |
| 2007 | 2094 | 3 | 3.508 | 4.386 | 1.75 | 1.267 | 0.074 | 2.046 | 0.158 | 2494 |
| 2007 | 2096 | 6 | 7.913 | 14.285 | 3.94 | 1.826 | 0.221 | 6.100 | 0.471 | 2601 |
| 4071 | 4101 | 3 | 12.715 | 19.330 | 3.12 | 4.790 | 0.191 | 6.857 | 0.438 | 5571 |
| 4071 | 4089 | 6 | 20.352 | 27.734 | 5.00 | 4.900 | 0.391 | 13.845 | 0.895 | 5904 |
| 8100 | 8375 | 3 | 25.005 | 39.485 | 3.09 | 2.372 | 0.455 | 21.414 | 1.564 | 14211 |
| 8100 | 8381 | 6 | 47.550 | 73.972 | 5.87 | 2.226 | 0.870 | 42.223 | 3.229 | 15410 |
| 10932 | 10989 | 3 | 41.079 | 59.583 | 3.76 | 10.080 | 0.542 | 26.583 | 1.821 | 20013 |
| 10932 | 10983 | 6 | 70.287 | 114.242 | 6.43 | 10.742 | 1.106 | 55.377 | 3.965 | 22032 |

Readings:
- **µs/particle grows 1.3 → 6.4** — the step is not O(n). `gen_collide` grows ~2.8× faster than
  particle count (denser piles ⇒ more neighbours per 3×3 scan; constraints/iteration grow 17× for
  11.7× particles), `bonds` ~3× faster (O(n²) scan over unsatisfied particles; drops at 8100 only
  because most valence got satisfied — see the S column), `solve` ~1.9× (follows constraint count).
- `gen_grid` (the per-iteration full particle copy the analysis flagged) is 1–3 % everywhere. It is
  a memory/stack smell, not a time problem — don't optimise it for speed.
- `predict`, `mouse`, `commit` are noise.

## Memory

- Linear memory 519 pages = 34.0 MB, static. Budget by owner: spatial grid 20.0 MB (100×100 cells ×
  500 slots), constraints 7.2 MB (union payload for unused Boids types), shadow stack 4.2 MB (raised
  from 1 MiB so the Debug build can run), arenas 1.1 MB, bulk buffers 0.5 MB, connection table 0.3 MB.
- Stack HWM 338–423 KB per step (the `generateConstraints` temporaries).
- wasm 1.81 MB = 38 KB code + **1.02 MB initialised data** + ~0.6 MB DWARF. Owner of the data
  segment unidentified (hypothesis: by-value arena `init()` templates) — verify with the in-place
  init change; DWARF can be stripped for shipping (measure size, keep the perf build unstripped).
- GPU + JS staging buffers ≈ 1.1 MB.

## Correctness / determinism

- Every gate scenario reproduces its checksum across runs; Debug ≡ ReleaseFast on S1, S2, S5, S7.
- Debug wasm **did not run at all before today** (stack overflow at init) — fixed by the stack size,
  root cause (by-value init) still open.
- S5 (drag) is behaviourally dead after `reset()` — checksum equals S2, `grabs = 0`. Kept as the
  regression scenario for the mouse-handle fix.

## Ranked follow-ups (each: baseline → one change → re-measure with `bench:sim:assert` + `bench:sim --only …`)

1. **Collision scan** (`physics.generateCollisionConstraintsForParticle`): 58–89 % everywhere. Ideas
   to *test*, not assume: hoist `getDenseCount()`/mouse check out of the inner loop, compare squared
   distances (skip sqrt until contact), iterate cells once per pair (half-neighbourhood), keep dense
   indices in cells and skip the handle round-trip. Judge on S2/S3/S6 `gen_collide` ms and `coll/it`
   unchanged; checksum unchanged.
2. **Bond search** (`main.updateValenceBonds`): 27–49 % when valence is unsatisfied. Use the spatial
   grid for candidates and the (currently write-only) connection table for the "already connected"
   check. Checksum *will* change if candidate order changes — define the order (cell order, then dense
   order) first, note it, re-golden.
3. **In-place arena init** (`generational.init` → `initInPlace(*Self)`): removes ~1 MB of copies at
   init/reset (and probably the 1 MB data segment); lets the stack go back to 1 MiB. Judge on wasm
   size, stack HWM, reset time; checksum unchanged.
4. **Mouse handle after reset** (`main.reset` order): must make S5 diverge from S2 and `grabs > 0`.
5. Constraint struct slimming (drop Boids union payload): 7.2 MB → ~2 MB static; judge on pages,
   maybe cache effects in `solve`.

Not worth doing for speed: `gen_grid` copy removal (1–3 %) — do it for stack/memory reasons under
item 3 if at all.


---

## Status 2026-08-17

All five ranked follow-ups above have been executed as measured steps (see
`docs/progress/performance/2026/08/2026-08-17T*`): collision scan (hoists + 30 px bins), bond search
via grid + connection table, in-place arena init (1 MB data segment gone, Debug runs on the default
stack), reset/mouse fix + dangling slices + `u8` refund, constraint slimming; plus render-path 0/0/0.
Cumulative table in `2026-08-17T10-30-00Z--constraint-struct-slimming.md`. Remaining ideas: the
`springs_to_remove` stack array (87 KB), DWARF stripping for the shipped wasm, `gen_collide` inner-loop
data layout (still ~65–70 % of the step), XPBD semantics decision (§8.1 #5/#6 in the analysis report).

## Status 2026-08-17 (evening) — physics pipeline plan slices 1–6

S2 default scene **2.99 → 0.50 ms/step** (−83 %), S3 18.3 → 2.6, S4 14.7 → 1.7, S6 66.5 → 6.7 (−90 %);
render path 0/0/0; shipped wasm 1.8 MB → 54 KB; linear memory 34 → 9.8 MB. Physics semantics changed in
slice 5 (true XPBD, once-per-step generation) — tuning hand-over in
`docs/progress/performance/2026/08/2026-08-17T16-00-00Z--slice5-once-per-step-generation-true-xpbd.md`.
`solve` is now the dominant phase (47–66 %).
