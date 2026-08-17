# (3) spatial cell capacity 500 → 64, (4) reset() order / mouse handle, (5) dangling stack slices

**Machine:** imac-battleship / Xeon W-2170B (load 5–8 from other processes) · **Profile:** fast · **Zig:** 0.16.0
**Follows:** `2026-08-17T06-40-00Z--collision-scan-hoists-and-bin-size.md` (bins now 30 px).

## Step 3 — `MAX_PARTICLES_PER_CELL` 500 → 64 (memory)

Why: with 30 px bins the measured max occupancy is 14 (35 at 1 XPBD iteration); 500 slots × 4 B ×
10 000 cells = 20 MB static for a ~16-particle physical maximum. Overflow used to be silent (`add`
dropped the particle → missed collisions), so first: `spatial.overflow_count` + export
`get_spatial_overflow_count()`, gated counter `cell_overflow` (`ovf` column), and `sim-assert` fails
on any overflow.

| | before | after |
| --- | --- | --- |
| linear memory | 519 pages / 34.0 MB | **253 pages / 15.8 MB** |
| `ovf` (S2, S3, S6, S7[1..12]) | — | 0 everywhere |
| checksums S2/S3/S7 | a9ea9d39 / 9322c041 / … | unchanged ✅ |
| S6 checksum | e3e46414 | **b10dda7b** ⚠ → investigated below |

**Keep** (memory −18 MB, no timing change beyond noise, overflow now observable and gated).

## Finding — S6 checksum depended on what ran before it

S6 alone (twice): `e3e46414`, `e3e46414`. S6 after S2, S3 in the same instance: `b10dda7b`. Cause:
`reset()` spawned the mouse particle into the *old* arena before re-initialising it, leaving a stale
handle whose `(index, generation)` depended on the previous scenario's population; S6 paints ~10 000
particles and one of them receives exactly that `(index, gen)`, so `isMouseParticle()` becomes true
for a real particle, which is then skipped by predict/collide. Self-consistent per sequence — invisible
to the gate's "run the same sequence twice" — visible only across histories. This is analysis-report
bug #2 and the "history-dependent post-reset behaviour" hazard from `docs/principles/determinism.md`.

## Step 4 — `reset()` re-inits the arenas *before* `mouse.initMouseSystem()` (correctness)

Acceptance: (a) new gate check **history independence** — `sim-bench` reruns S2 after all scenarios,
`sim-assert` requires equality with the earlier S2; (b) unit tests: reset is history-independent
(3000-particle history vs fresh), a press after reset grabs and the drag changes the checksum;
(c) S5 ≠ S2 in the harness. The mouse particle now lives in the dense set (P = 933), so **all
checksums changed** (intended; goldens regenerated).

S5 also needed a scenario fix: it pressed at the lattice's *initial* centre (−200,−200) after 600
steps of gravity — the lattice was on the floor, nothing within 25 px. It now presses on particle 0's
actual position (`particlePosition()` from the bulk buffer) and circles it (r = 60).

| scenario | p50 ms | S | grabs | disp px | checksum |
| --- | --- | --- | --- | --- | --- |
| S2 | 2.139 | 1161 | 0 | 3.6 | b71199bc |
| S5 | 1.556 | 1158 | **5** | 11.4 | **4e34a35e** (≠ S2 ✅; springs break under the drag) |

**Keep.**

## Step 5 — remove `getDenseData()` / `getDenseHandles()` (dangling stack slices; analysis bug #1)

`getParticleHandleByIndex`, `getParticleByIndex`, `findClosestParticleIndex` now read the arena
directly; the no-op `rebuildDenseArrays`/`writeDenseToSparse` leftovers are gone. The grab path
(`mouse.findParticlesInGrabRadius`) was the live consumer. Behaviour-preserving: S2 `b71199bc`,
S5 `4e34a35e` unchanged; `zig build test` 9/9.

**Keep.**

## Lock-in

`npm run bench:sim:assert -- --set-thresholds --update-goldens` — see appended gate summary.

## Step 6 — found by the lock-in gate: `u8` valence refund underflow (analysis bug #3)

The first lock-in run **failed in the Debug pass** (`integer overflow` in `generateConstraints`):
S5's drag now really breaks mouse springs, and the refund `current_valence - 1` runs on the mouse
particle whose valence is 0 (mouse springs are never counted). Debug panics; ReleaseFast wrapped to
255 silently. Fix: saturating `-|= 1`; unit test that yanks the mouse until its springs break.
Checksums unchanged in ReleaseFast (the wrapped 255 never fed back into anything measured);
Debug S5 now runs and equals ReleaseFast (`4e34a35e`).

**Keep.**

## Gate after lock-in (`--set-thresholds --update-goldens`) — GATE PASS

| scenario | p50 ms | p95 ms | S | ovf | disp px | checksum |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | 1.906 | 2.624 | 1161 | 0 | 8.3 | 1dac2147 |
| S2 | 2.071 | 2.182 | 1161 | 0 | 3.6 | b71199bc |
| S3 | 8.638 | 9.581 | 1185 | 0 | 2.0 | c5ed95c5 |
| S4 | 7.080 | 7.647 | 7041 | 0 | 2.9 | 03b8e42b |
| S5 | 1.526 | 2.269 | 1158 | 0 | 11.4 | 4e34a35e |
| S7[1] | 0.646 | 0.742 | 1041 | 0 | 26.8 | b811d252 |
| S7[3] | 0.876 | 0.948 | 1161 | 0 | 4.0 | 3f85d2f1 |
| S7[6] | 1.482 | 1.596 | 1161 | 0 | 4.0 | 4ba1a542 |
| S7[12] | 2.764 | 3.060 | 1172 | 0 | 4.0 | 6a7abe49 |

History independence ✅ · self-consistency 9/9 ✅ · Debug ≡ ReleaseFast 7/7 ✅ · linear memory 253 pages.
