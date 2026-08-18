# Stiffness 200 + real mouse tether, world box enforced in the solve, stiffness sweep for tuning

**Machine:** imac-battleship, load ~8, pinned where A/B'd · **Zig:** 0.16.0 · follows the slice 5 hand-over.

## Changes (`src/main.zig`, `src/physics.zig`)

- `DISTANCE_STIFFNESS` 1e9 → **200** (≈ the pre-slice-5 effective softness; decision 2026-08-18).
  `MOUSE_STIFFNESS = 50000` is now *used*: mouse tethers get their own stiffness (was: same as lattice).
  `set_distance_stiffness(k)` bench hook. Pruned unused knobs (`COLLISION_STIFFNESS`, `SEPARATION_*`,
  `SPRING_STRENGTH`); `initCollision` no longer takes a stiffness (contacts are hard). `AIR_DAMPING`
  kept (wired, = 1.0).
- **World box enforced after every solver iteration** (`applyBoundaryToAliveParticles`). Found via S5:
  the drag circle takes the cursor below the floor; the stiff tether pulled grabbed particles 45–57 px
  out of the world each step and the *pre-solve* clamp put them back → sawtooth (`solve px` 47).
  With the per-iteration clamp: S5 `solve px` 5.3, particles never leave the box (new unit test).
  Cost lesson: the `@min(@max())` form of the clamp cost 0.17 ms/step at S2 (30 ns/particle, 6×/step);
  compare-and-store-only-when-outside costs ~0.02 ms — same checksum. Recorded in the HOWTO.
- S5 scenario: the drive circle now starts at the press point (scenario version 2) — the previous
  version teleported the cursor 60 px on the first drive step.

## Stiffness sweep (`set_distance_stiffness`, S1/S2/S4/S5, one run each, tether 50000)

| k | S1 p50 / S / rem·s⁻¹ / bonds·s⁻¹ | S2 p50 / S / cand | S4 p50 / S / rem / bonds | S5 p50 / solve px |
| --- | --- | --- | --- | --- |
| 50 | 0.477 / 1060 / 1.10 / 2.87 | 0.672 / 1054 / 4368 | 2.457 / 6640 / 7.31 / 8.19 | 0.639 / 24.1 |
| **200** | 0.431 / 1145 / 0.31 / 2.21 | 0.622 / 1149 / 3990 | 2.281 / 6800 / 3.74 / 3.27 | 0.606 / 12.0 |
| 1000 | 0.363 / 1158 / 0.00 / 1.93 | 0.534 / 1158 / 3161 | 1.781 / 7035 / 0.02 / 0.06 | 0.503 / 21.0 |
| 10000 | 0.395 / 1155 / 0.00 / 1.93 | 0.538 / 1155 / 3181 | 1.721 / 6921 / 0.00 / 0.11 | 0.515 / 3.8 |
| 1e9 | 0.370 / 1155 / 0.00 / 1.93 | 0.535 / 1155 / 3203 | 1.697 / 7033 / 0.00 / 0.00 | 0.522 / 2.1 |

("rem" = springs removed per step for overstretch, "bonds" = new bonds per step, "cand" = collision
candidates per step; S1 is the fresh bonding burst, S4 the valence-6 lattice under churn.)

Readings for tuning: below ~1000 the 1.4×-rest break rule is *active* (bonds break and re-form —
S4 churns 3–7 springs per step at 50–200, none at ≥ 1000); softer lattices compress, so contact
candidates grow ~25 % (50 vs 1e9) and the step costs 15–30 % more; the S5 `solve px` column is the
cursor-below-floor stress case (tether 50000 vs lattice) — non-monotonic in k, watch it after tuning
the tether. Feel is yours to judge in the browser; the harness gives you these proxies per value.

## Gate — PASS (pinned), goldens regenerated for k = 200. Memory unchanged (150 pages).
