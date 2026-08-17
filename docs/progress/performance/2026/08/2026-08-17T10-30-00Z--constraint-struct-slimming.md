# (11) `Constraint` struct slimming — drop the Boids-era union payload and constraint kinds

**Machine:** imac-battleship / Xeon W-2170B — **load average 9–10 from other processes throughout**
(timing inconclusive; memory deterministic) · **Zig:** 0.16.0
**Follows:** `2026-08-17T09-30-00Z--arena-inplace-init-and-render-path-0-0-0.md`.

Change (`src/physics.zig`): `ConstraintType` reduced to `distance | collision`; the `aux_data` union
(`cohesion_target`, `alignment_neighbors: [16]ParticleHandle`) and the unused `separation / alignment /
cohesion / mouse_spring` kinds removed; `Vec2` removed. `MAX_CONSTRAINTS = 71 728` entries × ~100 B →
~32 B each. Behaviour-preserving.

| | before | after |
| --- | --- | --- |
| linear memory | 194 pages / 12.1 MB | **119 pages / 7.4 MB** |
| checksums S2 / S3 / S4 | f483375f / 059e121c / 5a438965 | identical ✅ |
| S2 / S4 p50 | 1.43 / 5.35 (quiet machine) | 1.45–1.90 / 5.29–7.04 (load 10) — **inconclusive**, no evidence of change either way |
| gate | — | PASS (no ratchet of p95s under load; `memoryPagesMax` hand-ratcheted 194 → 119) |

**Keep** for memory; timing to be re-read on a quiet machine before any claim about `solve`.

## Cumulative since the 2026-08-16 baseline

| | baseline | now |
| --- | --- | --- |
| S2 default scene p50 | 2.99 ms | 1.43 ms (quiet) |
| S3 dense pile | 18.3 ms | 8.8 ms |
| S4 bond churn | 14.7 ms | 5.3 ms |
| S6 capacity (10 907) | 66.5 ms | ~25 ms (step 2 run; not re-run since) |
| linear memory | 34.0 MB | 7.4 MB |
| wasm (ReleaseFast) | 1 809 KB (38 KB code + 1 017 KB data + DWARF) | 811 KB (39 KB code + 14 KB data + DWARF) |
| stack HWM | 338–423 KB (Debug build could not start) | 0–81 KB (Debug on the default 1 MiB stack) |
| Tier 2, real GPU, steady | 174 fps, 57 B/frame alloc, ~1 DOM write/frame | 425–570 fps, 0 B/frame, ≤ 0.01 DOM/frame |
| known bugs from the analysis report | #1 #2 #3 open | fixed (dangling slices, reset/mouse, u8 refund) |
