# Measurement accuracy: repeats, interleaved A/B with paired ratios, core pinning

**Machine:** imac-battleship / Xeon W-2170B, **load average 9–11 throughout** (other processes) — the
condition this note is about. · **Zig:** 0.16.0

## Question

Can accuracy be improved by more particles / more steps? Assessment: mostly no — the dominant noise
was other processes (p50 IQR ~30 % between runs, tails 5–10×), plus non-stationary scenarios; more
steps only helps stationary scenarios and more particles changes the workload. What was built instead:

- `bench/sim-bench.mjs --repeat K` (runner re-runs setup+bursts K times; reports `min` and the spread
  of per-repeat p50s = pure noise, since the sim is deterministic) and a `min ms` column everywhere.
- `bench/sim-ab.mjs`: two builds (git ref → temp worktree build, wasm path, or `.`) in one process,
  interleaved with alternating order per repeat; **paired B/A ratios per repeat**, median as estimate,
  IQR of ratios as noise; verdict requires p50 *and* min to clear 2×IQR in the same direction.
- `MORPHO_BENCH_PIN=<cpu>` (taskset re-exec) and the 1-min load average in every header with a warning
  above 2.

## Validation

Null test (working tree vs itself, S2/S4, 5 repeats, load ~9): paired Δ 0.5 % / 0.6 %, verdict "no
difference" — no false positive.

Real test — step 11 (constraint slimming), A = HEAD with the struct change reverted (temp worktree
build), B = working tree, load 9–11:

| run | S2 | S3 | S4 |
| --- | --- | --- | --- |
| unpaired Δp50 (first tool version) | −0.3 % | +32.9 % (!) | +31.9 % (!) |
| paired Δp50 / Δmin, 7 repeats, unpinned | +1.3 % / +0.5 % → no difference | +12 % (IQR 28 %) / **+4.0 % (IQR 1.1 %)** → inconclusive | −1.8 % / −0.9 % → no difference |
| paired, **pinned to cpu 27**, 9 repeats (S3 only) | | **+2.3 % (IQR 1.0 %) / +1.7 % (IQR 2.7 %)** → inconclusive | |

Readings:
- The +32 % unpaired numbers were interference (uniform across *all* phases incl. `predict`; min unmoved);
  the first verdict rule accepted one of them — fixed by requiring the min ratio to clear its noise too
  and by alternating A/B order.
- Pinning to one core cut the p50 IQR from ~30 % to ~1 % (and, curiously, lowered absolute S3 mins
  7.9 → 7.1 ms — a different core / less migration).
- Step 11's true effect: **S2/S4 no difference; S3 ≈ +2 % slower** (same sign in four A/B runs, each
  individually below the conclusive bar). Kept for the −4.7 MB; a targeted look at why (constraint copy
  in `initCollision`? layout?) is a candidate future step, to be judged with this A/B under pinning.

## Guidance now in `docs/HOWTO-performance.md`

Pin → paired A/B → repeats → only then longer bursts (stationary scenarios only). Gate p95 ceilings only
(re)set on a quiet machine.
