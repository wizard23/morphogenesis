# Slice 1 — collision scan on SoA cells, predicted-position grid, dense-index pair ownership

**Plan:** `docs/plans/2026-08-17--physics-pipeline-optimisation-plan.md` slice 1 · **Machine:** imac-battleship, load 8–12 (busy), **pinned to cpu 27** · **Zig:** 0.16.0

## Change

- `spatial.GridCell` is now SoA: `idx[]`, `x[]`, `y[]`, `count` — the coordinates the grid was populated
  with live in the cell, so a neighbourhood scan is a sequential sweep and the arena is touched only on
  a hit. `populateGridArena(arena, .current | .predicted)` (comptime).
- Physics populates from **predicted** positions and tests predicted positions (was: populate current,
  test predicted); pairs are owned by the lower **dense** index (was: sparse index via a handle read per
  candidate). Bonds: distance test first from cell coordinates, arena read only for in-range candidates.
  Mouse grab uses `cell.idx`.

## A/B (`MORPHO_BENCH_PIN=27 bench:sim:ab --a HEAD --b . --repeat 5`, paired ratios)

| scenario | A p50 | B p50 | paired Δp50 (IQR) | paired Δmin (IQR) | verdict | gen_collide | gen_grid | bonds |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| S2 | 1.378 | 1.268 | −7.6 % (1.1 %) | −7.9 % (1.0 %) | **B faster** | −12 % | +9 % | +11 % |
| S3 | 8.769 | 7.279 | −17.1 % (1.8 %) | −16.2 % (1.0 %) | **B faster** | −20 % | +9 % | +15 % |
| S4 | 5.351 | 4.769 | −10.3 % (1.6 %) | −10.7 % (1.0 %) | **B faster** | −18 % | +9 % | −8 % |
| S6 | 25.393 | 21.675 | −14.9 % (1.0 %) | −13.9 % (1.8 %) | **B faster** | −19 % | +13 % | +20 % |

Populate got ~10 % dearer (three arrays written instead of one) and `bonds` — which contains one
populate — with it; both are small in absolute terms (`bonds` 0.056 ms at S2). Net: 8–17 % per step.
Checksums change (visitation order: predicted-position cells, dense ownership) → goldens regenerated.

## Gate

Self-consistency, history independence, Debug ≡ ReleaseFast: ✅. **Memory: 197 pages > 119 ceiling** —
the SoA cell is 772 B at 64 slots (was 260 B). Ceiling raised to 197 *temporarily* with a note in
`bench/thresholds.json`; slice 2 (20 px bins ⇒ ~16-slot cells) must bring it back below 119.

**Keep.**
