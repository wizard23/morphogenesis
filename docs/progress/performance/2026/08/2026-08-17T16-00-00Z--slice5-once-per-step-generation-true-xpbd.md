# Slice 5 — constraints once per step, true XPBD, dead restitution removed — HAND-OVER FOR TUNING

**Plan:** slice 5 · **Machine:** imac-battleship, load ~10, **pinned to cpu 27** · **Zig:** 0.16.0 · A = slice-4 wasm, B = working tree.
**Decisions applied (plan §Decisions):** generation once per step with margin · true XPBD · remove dead
impulse/bounce code · user re-tunes stiffness afterwards.

## What changed in the physics (read this before tuning)

1. **`update_particles` = predict → mouse → bonds → generateConstraints (once) → N × solve → commit.**
   Springs are turned into distance constraints once per step (overstretched springs destroyed
   there); collision *candidates* are every pair within `contact + CONTACT_MARGIN` (10 + 10 px) on
   predicted positions, stored as inequality constraints (inactive until closer than contact).
   Contacts forming during the iterations are inside the margin; a contact forming from beyond
   20 px within one step waits one step (accepted by decision).
2. **True XPBD for springs.** `compliance = 1 / (k · dt²)` with **dt = the full step (0.016 s)**, used
   once (before: divided by dt² twice, with dt = step/6 → effective stiffness ∝ dt⁴). λ persists
   across the step's iterations. Consequence: **for the same `DISTANCE_STIFFNESS = 1e9`, springs are
   now essentially rigid rods** (α̃ ≈ 4·10⁻⁶) where before they were soft (effective α̃ ≈ 20).
   **The old feel corresponds to `DISTANCE_STIFFNESS ≈ 200`** in the new formula
   (k = 1/(20 · 0.016²)); convergence differs because λ now accumulates, so treat 200 as the starting
   point, not the answer. Mouse springs use the same constant (rigid tether at 1e9).
   `COLLISION_STIFFNESS`, `MOUSE_STIFFNESS`, `SEPARATION_*`, `SPRING_STRENGTH` are unused knobs now
   (collisions are hard projections; the constants are left in place for you to prune or wire).
3. **Collisions** stay hard, inverse-mass-weighted projections (compliance never applied to them
   before either). The velocity impulse (restitution 0.9) and the −0.8 wall bounce were dead code —
   `updateFromPrediction` recomputes velocity from positions — and are removed; walls and contacts are
   inelastic, as they already effectively were.
4. Instrumentation: `constr`/`cand` are now per step; new `solve px` = max solver displacement within
   the step (must stay < margin 10 px), new `drop` = constraints not stored (must be 0, gated);
   `MAX_CONSTRAINTS` 71 728 → 121 728 (+1.6 MB, candidates ~4.5/particle at capacity).

## A/B (`MORPHO_BENCH_PIN=27 bench:sim:ab --a <slice4.wasm> --b . --repeat 5`, paired)

| scenario | A p50 | B p50 | paired Δp50 (IQR) | paired Δmin (IQR) | verdict | gen_* | solve |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S2 | 0.843 | 0.454 | −46.1 % (1.0 %) | −48.4 % (1.0 %) | **B faster** | −76…−83 % | +16 % |
| S3 | 3.595 | 2.362 | −34.3 % (2.0 %) | −33.8 % (1.4 %) | **B faster** | −76…−85 % | +112 % |
| S4 | 3.236 | 1.664 | −48.7 % (2.3 %) | −41.7 % (1.0 %) | **B faster** | −79…−83 % | +6 % |
| S6 | 12.018 | 6.617 | −45.0 % (1.1 %) | −44.3 % (1.0 %) | **B faster** | −78…−83 % | +29 % |

(Physics differ between A and B by design; the comparison is cost per step. `commit` +1390 % at S6 is
the new `solve px` probe in perf builds — ~30 ns/particle, perf build only.)

## Gate — PASS (pinned; p95 ceilings not re-set: busy machine). Goldens regenerated.

| scenario | p50 ms | constr | cand | drop | solve px | checksum |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | 0.387 | 2720 | 1565 | 0 | 11.0 | e23f79d0 |
| S2 | 0.495 | 4309 | 3154 | 0 | 2.8 | 2e02695f |
| S3 | 2.643 | 25775 | 24620 | 0 | 2.5 | afbcba86 |
| S4 | 1.674 | 16415 | 9383 | 0 | 9.1 | c7c85d6a |
| S5 | 0.519 | 4324 | 3164 | 0 | 2.6 | 40987227 |
| S6 (bench) | 6.70 | 60641 | 49443 | 0 | 10.1 | 081546b0 |
| S7[1/3/6/12] | 0.260 / 0.337 / 0.445 / 0.659 | | | 0 | 12.7 / 2.4 / 3.2 / 3.1 | |

Phase split now: `solve` 47–66 %, `gen_collide` 14–23 %, `bonds` 5–21 %. Iterations cost ~0.04 ms
each at S2 (S7 sweep is linear in solve only).

## Things to watch while tuning

- **`solve px` is at/over the 10 px margin in S1, S4, S6, S7[1] (9–13 px)** — that is the rigid-rod
  regime of `1e9`: the solver moves lattice particles ~10 px per step. Softer springs shrink it. If
  it stays ≥ margin after tuning, either raise `CONTACT_MARGIN` (then `BIN_SIZE_PIXELS` must be ≥
  contact + margin, or the collision scan must widen like the grab scan) or accept one-step-late
  contacts.
- Spring counts (`S`) barely break now (rigid rods rarely reach 1.4× rest); with softer springs the
  break rule at 1.4× rest is active again.
- Debug ≡ ReleaseFast, history independence, contact-set oracle (candidates vs brute force at
  contact + margin), zero drops, zero overflow: all ✅.

**Keep.** Next perf target is `solve` (SoA positions / SIMD); next correctness item is your tuning pass,
after which goldens get regenerated once more with a note.
