# SoA solver state — flat predicted-position / inverse-mass arrays for the solver

**Machine:** imac-battleship, load ~9, **pinned to cpu 27** · **Zig:** 0.16.0 · A = HEAD (f50cb73, worktree build), B = working tree.

Change (`src/physics.zig`, `src/main.zig`): after constraint generation, `beginSolve()` copies
predicted x/y and 1/mass into flat arrays indexed by dense index; the solver iterations and the
world-box pass touch only those (4 B stride, no arena entry loads); `endSolve()` writes back before
commit. Fixed particles (inverse mass 0 = the mouse) are skipped by the boundary pass via `inv_mass`.

| scenario | A p50 | B p50 | paired Δp50 (IQR) | paired Δmin (IQR) | verdict | solve | checksum |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S2 | 0.514 | 0.498 | −4.8 % (14.5 %) | −5.7 % (2.6 %) | inconclusive (p50 noise; min agrees) | −8 % | **same** |
| S3 | 2.229 | 2.145 | −7.7 % (1.0 %) | −5.9 % (1.8 %) | **B faster** | −9 % | same |
| S4 | 1.683 | 1.575 | −7.4 % (2.1 %) | −5.6 % (2.2 %) | **B faster** | −13 % | same |
| S6 | 7.354 | 6.870 | −7.0 % (2.4 %) | −6.7 % (3.2 %) | **B faster** | −10 % | same |

Bit-identical checksums: pure data-layout change (same arithmetic, same order). Copy-in is accounted
in `gen_grid` (+8…18 % of a small phase), write-back in `commit`. Memory +3 × 44 KB static (150 pages
unchanged). Gate PASS.

**Keep.** Next on `solve`: split distance/collision lists (drops the per-constraint type switch,
preserves order), then wasm SIMD.
