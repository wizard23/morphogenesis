# Slice 3 — half-neighbourhood collision scan (5 cells, ownership by cell order)

**Plan:** slice 3 · **Machine:** imac-battleship, load ~10, **pinned to cpu 27** · **Zig:** 0.16.0 · A = slice-2 wasm, B = working tree.

## Change (`physics.generateCollisionConstraintsForParticle`)

Each unordered pair is visited exactly once: from the particle whose cell comes first in (y, x) order
(own cell → later entries only; forward cells (+x), (−x,+y), (0,+y), (+x,+y) → all entries). 5 cell
visits instead of 9 and no "≤ dense index" rejects for the backward half.

New oracle (`main.collisionPairCountsForTest`, `tests.zig`): from one identical state, the grid scan must
produce exactly the brute-force O(n²) contact count over predicted positions — checked at 6 states of a
dense pile and 3 states of a bonding lattice, both build modes. (It first failed on my own `> 1000`
scene assumption — 288 contacts, equal on both sides — then passed with the assumption fixed. This is
the single-state pair-set oracle the ordering changes of slices 1–3 lacked; the earlier "coll/it moved"
readings were trajectory divergence, as suspected.)

## A/B (`MORPHO_BENCH_PIN=27 bench:sim:ab --a <slice2.wasm> --b . --repeat 5`, paired)

| scenario | A p50 | B p50 | paired Δp50 (IQR) | paired Δmin (IQR) | verdict | gen_collide |
| --- | --- | --- | --- | --- | --- | --- |
| S2 | 1.215 | 0.848 | −30.2 % (1.5 %) | −30.8 % (1.0 %) | **B faster** | −48 % |
| S3 | 5.901 | 3.630 | −38.4 % (1.2 %) | −39.1 % (1.0 %) | **B faster** | −49 % |
| S4 | 4.436 | 3.275 | −26.8 % (2.1 %) | −18.1 % (6.4 %) | **B faster** | −47 % |
| S6 | 18.034 | 12.001 | −33.3 % (1.0 %) | −34.3 % (1.1 %) | **B faster** | −47 % |

Contacts per iteration are 6–10 % lower after the change (S2 335 vs 372, S3 4 556 vs 4 852): the
different Gauss-Seidel order settles piles slightly differently — the oracle above shows the *scan* is
exhaustive. Checksums change → goldens regenerated.

## Gate — PASS (pinned; p95 ceilings not re-set: busy machine). S2 p50 0.898, S3 3.890, S4 3.381,
S6 (bench) 11.9 ms; memory 124 pages.

**Keep.**

Cumulative since the 2026-08-16 baseline: S2 2.99 → **0.90 ms** (−70 %), S3 18.3 → 3.9 (−79 %),
S4 14.7 → 3.4 (−77 %), S6 66.5 → 11.9 (−82 %).
