# Slice 2 — 20 px bins, radius-aware grab scan, 24-slot cells, runtime bin growth for large worlds

**Plan:** slice 2 · **Machine:** imac-battleship, load 8–12, **pinned to cpu 27** · **Zig:** 0.16.0 · A = slice-1 wasm (kept copy), B = working tree.

## Change (`src/spatial.zig`, `src/mouse.zig`)

- `BIN_SIZE_PIXELS` 3 → **2 diameters (20 px)**; comment states the rule (bin ≥ contact + per-step
  displacement; queries with a larger radius widen their scan). Mouse grab scans `cellsForRadius(25 px)`
  = ±2 cells instead of a fixed 3×3.
- `MAX_PARTICLES_PER_CELL` 64 → 24 (measured max 7–8 at 6 iterations, 20 at 1 iteration; `ovf` = 0
  everywhere, gated).
- New: `spatial.bin_size` (runtime) = max(BIN_SIZE_PIXELS, world / (MAX_GRID_SIZE−1)). Before, a
  world wider than 100 bins clamped particles to the edge cell (latent overflow bug for large screens,
  made worse by smaller bins). Unit test: 4000×3000 world, uniform 4 800-particle field, zero overflow.

## A/B (`MORPHO_BENCH_PIN=27 bench:sim:ab --a <slice1.wasm> --b . --repeat 5`, paired)

| scenario | A p50 | B p50 | paired Δp50 (IQR) | paired Δmin (IQR) | verdict | gen_collide | gen_grid |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S2 | 1.258 | 1.208 | −3.8 % (1.0 %) | −4.3 % (1.0 %) | **B faster** | −11 % | +55 % |
| S3 | 7.159 | 5.968 | −16.6 % (2.6 %) | −18.7 % (1.3 %) | **B faster** | −22 % | +38 % |
| S4 | 4.712 | 4.392 | −6.8 % (1.5 %) | −9.8 % (1.0 %) | **B faster** | −13 % | +49 % |
| S6 | 21.439 | 18.202 | −15.2 % (1.0 %) | −13.8 % (1.1 %) | **B faster** | −23 % | +24 % |

`gen_grid` grows because `clearGrid` now zeroes 5 335 cells (97×55) instead of 2 405 per populate — ~0.05 ms
at S2; a dirty-cell list would remove it (later, if it ever matters). Checksums change (cell order) →
goldens regenerated.

## Gate — PASS (pinned; p95 ceilings deliberately not re-set on a busy machine)

Linear memory **124 pages** (SoA cells: 24 × 12 B × 10 000 = 2.9 MB vs 2.6 MB before slice 1) —
ceiling set to 124 with a note; the slice-1 note's "below 119" was optimistic by 5 pages, accepted for
the −8…−17 % (slice 1) and −4…−17 % (slice 2) step-time wins. Gate table: S2 p50 1.260, S3 6.314,
S4 4.516, S6 (bench) 18.2 ms.

**Keep.**
