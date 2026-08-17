# Collision scan: (1) inner-loop hoists, (2) spatial bin 60 → 30 px

**Machine:** imac-battleship / Xeon W-2170B (load avg 5–8 from other processes during the session — a
known noise source; polluted bursts were re-run) · **Profile:** fast · **Zig:** 0.16.0 · **git:** 3352ea3 + this change
**Target:** `gen_collide` — 58–89 % of every scenario in the 2026-08-16 baseline. Follow-up #1 of `docs/perf/2026-08-16--tier1-baseline-report.md`.

## Baseline (same day, right before the change) — `npm run bench:sim -- --only S2,S3`

| scenario | p50 ms | p95 ms | gen_collide ms | coll/it | bin | checksum |
| --- | --- | --- | --- | --- | --- | --- |
| S2 | 2.190 | 2.619 | 1.623 (72 %) | 379 | 44 | f983a9f8 |
| S3 | 17.800 | 19.060 | 15.744 (88 %) | 4924 | 48 | d9d26d39 |

(S2 is 2.19 ms today vs 2.99 ms yesterday with the same wasm — machine state moved; hence the fresh baseline.)

## Step 1 — hoists (`src/physics.zig`, `generateCollisionConstraintsForParticle`)

Change: dense count and the mouse particle's dense index hoisted out of the neighbour loop; handle
equality replaced by dense-index equality; squared-distance early reject *before* the `sqrt` while
keeping the original `sqrt(d²) < contact` test (so float semantics are bit-identical). No physics change.

| scenario | p50 ms | gen_collide ms | checksum | run 2 |
| --- | --- | --- | --- | --- |
| S2 | 2.040 | 1.440 (−11 %) | f983a9f8 ✅ | 1.412 |
| S3 | 15.551 | 13.555 (−14 %) | d9d26d39 ✅ | 13.887 (a third run had spread 37 %/max 60 ms → discarded as polluted) |

**Keep.** Checksums unchanged (correctness oracle), improvement reproduced across runs, code is
simpler than before.

## Step 2 — spatial bin 6 → 3 diameters (`src/spatial.zig`, `BIN_SIZE_PIXELS`)

Reasoning to *test*: contact distance is 10 px, the 3×3 scan of 60 px cells covers 180×180 px per
query. Bin must stay ≥ the largest 3×3 query: contact (10 px) and the mouse grab radius (25 px) → 30 px
is the smallest safe value without touching the grab search. Exhaustiveness condition: per-step
displacement (|predicted − x|) < bin − contact = 20 px. Added the gated counter `max_step_disp_milli`
(`perf.zig`) and a `disp px` column so the harness shows it.

| scenario | p50 ms | gen_collide ms | coll/it | bin | disp px | checksum |
| --- | --- | --- | --- | --- | --- | --- |
| S2 | 1.543 | 0.952 (61 %) | 362 | 14 | 3.6 | a9ea9d39 (changed) |
| S3 | 10.139 | 9.319 (78 %) | 5162 | 14 | 2.3 | 9322c041 (changed) |
| S4 | 7.216 | — | 725 | 14 | 2.9 | 1cf244af (changed) |
| S5 | 1.551 | — | 362 | 14 | 3.6 | a9ea9d39 (= S2, stale-mouse bug still present) |
| S6 | 25.844 | — | 10645 | 13 | 2.3 | e3e46414 (changed) |

- Displacement 2.3–3.6 px ≪ 20 px slack → the scan is exhaustive; the contact *set* per state is
  unchanged. Cell visitation order changes, so constraints enter the Gauss-Seidel solver in a different
  order and trajectories diverge → **checksums change by design**. `coll/it` also moves (379→362,
  4924→5162) — that is trajectory divergence, not missed pairs; it is *not* a valid oracle across an
  ordering change (learned here; recorded in the HOWTO).
- vs the fresh baseline: S2 −30 %, S3 −35–43 %; vs yesterday: S4 14.7→7.2 (−51 %), S6 66.5→25.8 (−61 %).
- `bin` max dropped 44 → 14: with 30 px cells the physical maximum is ~14–16 particles; `MAX_PARTICLES_PER_CELL = 500`
  is ~35× oversized (20 MB static). Separate memory step.

**Keep.** Goldens regenerated (`--update-goldens`, intended ordering change); thresholds ratcheted
(`--set-thresholds`).

## Commands

```bash
npm run bench:sim -- --only S2,S3           # before / after each step
npm run bench:sim -- --only S2,S3,S4,S5,S6  # step 2 sweep
npm run bench:sim:assert -- --set-thresholds --update-goldens   # lock-in (see appended gate summary)
```

## Gate after lock-in (`bench:sim:assert --set-thresholds --update-goldens`) — GATE PASS

| scenario | p50 ms | p95 ms | coll/it | bin | disp px | checksum |
| --- | --- | --- | --- | --- | --- | --- |
| S1 | 1.841 | 2.104 | 29 | 12 | 8.3 | c3fff586 |
| S2 | 1.542 | 1.697 | 362 | 14 | 3.6 | a9ea9d39 |
| S3 | 9.136 | 9.804 | 5162 | 14 | 2.3 | 9322c041 |
| S4 | 7.302 | 7.846 | 725 | 14 | 2.9 | 1cf244af |
| S5 | 1.506 | 1.603 | 362 | 14 | 3.6 | a9ea9d39 |
| S7[1] | 0.635 | 0.727 | 899 | 35 | **26.8** | cb454afb |
| S7[3] | 1.253 | 2.406 | 152 | 14 | 4.0 | adf201e0 |
| S7[6] | 2.099 | 2.302 | 169 | 13 | 4.0 | 5146b61b |
| S7[12] | 2.841 | 3.127 | 193 | 13 | 4.0 | 099125e0 |

Self-consistency 9/9 ✅ · Debug ≡ ReleaseFast 7/7 ✅ · new p95 ceilings = these × 1.25.

**Caveat found by the new counter:** at 1 XPBD iteration (`S7[1]`, a sweep variant, not the default)
the per-step displacement reaches 26.8 px > 20 px slack, i.e. the 3×3 scan is *not* guaranteed
exhaustive there. At the default 6 iterations it is 4 px. If iteration count is ever lowered for real,
`BIN_SIZE_PIXELS` must grow with it (or the scan widen); the `disp px` column is the check.
