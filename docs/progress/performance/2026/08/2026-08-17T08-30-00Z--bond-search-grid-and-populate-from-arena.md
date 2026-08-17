# (7) bond search via spatial grid + connection table, (8) grid populated from the arena (no copy)

**Machine:** imac-battleship / Xeon W-2170B (load 5–8 from other processes) · **Profile:** fast · **Zig:** 0.16.0
**Follows:** `2026-08-17T07-30-00Z--cell-capacity-reset-order-dangling-slices.md`.
**Target:** `bonds` — 16–54 % of the step when valence is unsatisfied (S4 39 %, S7[1] 54 %); the
analysis report's O(n²) finding. Baseline = the gate run right before (`assert4`).

## Step 7 — `main.updateValenceBonds`: grid candidates, table lookup, self-healing connection table

Before: every unsatisfied particle scanned *all* later particles (O(n²)), and every in-range pair
scanned *all* springs for "already connected" (O(S)). The per-particle connection table existed but
was write-only and never forgot destroyed springs.

After: the spatial grid is populated at the start of the phase from the arena (current positions);
each unsatisfied particle scans its 3×3 cells; a pair is owned by the lower dense index; "already
connected" reads the owner's connection table, which is compacted lazily (dead handles dropped on
lookup and when full); `reset()` clears the table. Visit order is defined and written down (owner
dense order → cells dy,dx ascending → cell insertion order). Distance test on squares. New unit
test: after 120 steps of a 40×40 valence-6 lattice no pair has two springs.

| scenario | bonds ms before → after | p50 ms before → after | S before → after | checksum |
| --- | --- | --- | --- | --- |
| S1 | 0.359 → **0.058** (−84 %) | 1.906 → 1.469 | 1161 → 1160 | changed (order) |
| S2 | 0.250 → **0.064** (−74 %) | 2.071 → 1.883 | 1161 → 1160 | changed |
| S4 | 3.433 → **0.167** (−95 %) | 7.080 → 5.352 | 7041 → 7047 | changed |
| S7[1] | 0.360 → 0.161 (−55 %) | 0.646 → 0.666 | 1041 → 1053 | changed |

Bond *outcomes* are equivalent in kind (spring counts within a handful; same rules), but which of
several equally valid candidates bonds first differs → trajectories diverge → checksums change by
design; goldens regenerated. `bonds` now includes one grid population per frame (~0.05 ms at 933).

**Keep.**

## Step 8 — `physics.generateConstraints` populates the grid from the arena too

Removes the per-iteration `temp_particles: [PARTICLE_COUNT]Particle` stack copy (≈440 KB frame,
6× per step) and `GenerationalArena.fillDenseArray`/`spatial.populateGrid(anytype)`. Same population
order → **checksums identical** (S2 `f483375f`, S4 `5a438965`).

| | before | after |
| --- | --- | --- |
| stack HWM S2 / S4 | 338 KB / 423 KB | **0 KB / 81 KB** (what remains is `springs_to_remove: [MAX_SPRINGS]` at 87 KB, touched only when springs break) |
| gen_grid ms (S2) | 0.106 | 0.106 (as predicted by the baseline report: the copy was never a *time* problem) |

**Keep.** The 4 MiB shadow stack can return to 1 MiB once the by-value arena init is also gone (next).

## Lock-in — `bench:sim:assert --set-thresholds --update-goldens` → GATE PASS

| scenario | p50 ms | p95 ms | S | hwm KB | checksum |
| --- | --- | --- | --- | --- | --- |
| S1 | 1.532 | 1.803 | 1160 | 0 | 51afd543 |
| S2 | 1.431 | 1.462 | 1160 | 0 | f483375f |
| S3 | 8.809 | 9.051 | 1180 | 0 | 059e121c |
| S4 | 5.351 | 5.498 | 7047 | 81 | 5a438965 |
| S5 | 1.465 | 1.529 | 1159 | 81 | 3d28f006 |
| S7[1] | 0.456 | 0.479 | 1053 | 81 | 986b9099 |
| S7[3] | 0.730 | 0.761 | 1160 | 0 | 2038553f |
| S7[6] | 1.381 | 1.458 | 1160 | 0 | 18fe4b8c |
| S7[12] | 2.845 | 2.940 | 1173 | 0 | cdcc688d |

History independence ✅ · self-consistency 9/9 ✅ · Debug ≡ ReleaseFast 7/7 ✅ (Debug warm-up did not
plateau in this run — Debug is correctness-only, so no timing claim depends on it).

Cumulative since the 2026-08-16 baseline: S2 2.99 → 1.43 ms (−52 %), S3 18.3 → 8.8 (−52 %),
S4 14.7 → 5.35 (−64 %), S6 66.5 → ~25 (−62 %, from step 2; not re-run today), linear memory 34 → 15.8 MB,
stack HWM 423 → 81 KB.
