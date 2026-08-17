# Plan: physics pipeline optimisation — decisions and slices

*Drafted 2026-08-17 after the first 11 measured steps (`docs/progress/performance/2026/08/`) and the
measurement-accuracy work (`…T11-30-00Z--measurement-accuracy-repeat-ab-pinning.md`). Status: **DONE 2026-08-17** — slices 1–6 implemented and committed (one commit per slice, notes in
`docs/progress/performance/2026/08/2026-08-17T13-00…16-00`). Slice 0 (quiet-machine re-baseline of the p95 ceilings)
still pending — the machine was busy all day; run `MORPHO_BENCH_PIN=<cpu> npm run bench:sim:assert -- --set-thresholds`
when idle. Open for the user: the stiffness tuning pass after true XPBD (hand-over in the slice 5 note).*

## Decisions (2026-08-17)

| Question | Decision |
|---|---|
| Constraint generation cadence | **Once per step, with margin**: contacts from predicted positions with ~1 particle diameter of margin (max measured displacement 3.6 px/step at 6 iterations vs 10 px contact), distance constraints once; XPBD iterations only solve. Contacts appearing mid-step are picked up next step. |
| XPBD semantics | **True XPBD**: λ persists per constraint across the step's iterations; single `dt²` in the compliance term (today it is divided twice, effective stiffness ∝ dt⁴). |
| Re-tuning after true XPBD | **User tunes** `DISTANCE_STIFFNESS`, `COLLISION_STIFFNESS` etc. afterwards. I hand over with before/after phase tables and scenario descriptions; goldens regenerated with a note once tuning is done. |
| Restitution | **Remove the dead code** (collision velocity impulse, −0.8 wall bounce) — both are overwritten by `updateFromPrediction`; behaviour already inelastic. |
| Spatial bins | **20 px cells** (contact-sized) with a **5×5 mouse-grab search** so the 25 px grab radius still holds; guarded by the `disp px` counter (needs ≥ ~10 px slack ⇒ ≥ 3 XPBD iterations). |
| Order | Re-baseline on a **quiet, pinned** machine → mechanical steps (#2 data layout, #3 20 px bins, #4 half-neighbourhood) as A/B'd steps → the XPBD/generation change last, so its before/after is measured against the fastest generation path. |
| Shipped wasm | **Strip DWARF** in `build.sh` release output (~590 KB of 811 KB); perf/bench builds stay unstripped. |
| Commits | **One commit per kept slice** by the agent (message: slice + key numbers, referencing the progress note). Changed 2026-08-17. |

## Slices (each: baseline → one change → `bench:sim:ab` under `MORPHO_BENCH_PIN` → note → gate)

0. **Re-baseline** — quiet machine, pinned: `bench:sim:assert --set-thresholds`, `bench:memory`; note.
1. **Collision scan data layout** — cells store dense index + predicted x/y (SoA), pair-once by dense
   index, arena touched only on contact. Oracle: checksum *changes* (ordering) → coll/it per state via
   an A/B single-step comparison is not available; use `disp px`, `ovf`, S counts, and the physics
   rules unchanged; regolden. Expect a large share of the 70 % `gen_collide`.
2. **20 px bins + 5×5 grab** — `BIN_SIZE_PIXELS = 2 diameters`, `mouse.findParticlesInGrabRadius`
   scans ±2 cells; `MAX_PARTICLES_PER_CELL` re-checked against `bin`/`ovf` (physical max ~4–7 at 20 px).
   Note in `spatial.zig` updated (bin ≥ contact + slack; grab radius via search width).
3. **Half-neighbourhood scan** — visit self + 4 forward cells with dense-index ownership.
4. **Strip DWARF** for release; `springs_to_remove` off the stack; dynamic spatial grid dims — small
   hygiene slice, memory-report before/after.
5. **Once-per-step generation + true XPBD + dead-code removal** (one slice, since they touch the same
   loop; but three commits' worth of notes): `update_particles` = predict → mouse → bonds → generate
   (grid once, contacts with margin, springs) → N × solve (λ accumulates) → commit. `Constraint`
   keeps `lagrange_multiplier` across iterations; compliance = 1/(k·dt²) used once. Remove the
   impulse/bounce code. Deliverable to the user: before/after phase tables (S2, S3, S4, S6), the
   S7 iteration sweep (cost now ~linear in solve only), and a short "what changed in feel" list;
   goldens regenerated after the user's tuning pass.
6. **Mouse-line renderer index** (analysis §8.1 #4) — correctness, tiny; Tier 2 unaffected.

## Acceptance for the plan as a whole

- Gate green (`bench:sim:assert`, `bench:browser:assert`) after every kept slice; history
  independence and Debug ≡ ReleaseFast maintained.
- Every slice has a progress note with the A/B table (paired ratios, pinned) and a keep/revert line.
- Slice 5 hand-over note names the tuning knobs and what each now means physically.
