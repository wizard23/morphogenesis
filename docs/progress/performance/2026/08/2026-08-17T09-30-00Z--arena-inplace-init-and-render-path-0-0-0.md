# (9) in-place arena init + 1 MiB stack restored, (10) render path to 0/0/0, harness fixes

**Machine:** imac-battleship / Xeon W-2170B (load 5–8 from other processes) · **Zig:** 0.16.0 · **Chromium** 146 headless, `GPU=1` = amd/gcn-5
**Follows:** `2026-08-17T08-30-00Z--bond-search-grid-and-populate-from-arena.md`.

## Step 9 — `GenerationalArena.init(self: *Self)` in place (was: return by value)

Hypothesis from the baseline memory report: the 1.02 MB initialised wasm data segment is the arena
struct templates that by-value `init()` materialises and copies through the stack (the same copies
that overflowed the Debug build's 1 MiB shadow stack at init).

| | before | after |
| --- | --- | --- |
| wasm (ReleaseFast, `-Dperf`) | 1 808 779 B — data segment 1 016 767 B | **812 464 B — data segment 14 270 B** (code 39 KB, DWARF ~590 KB) |
| linear memory | 253 pages | 242 pages (template gone) → **194 pages / 12.1 MB** after removing the 4 MiB stack override |
| Debug build with the default 1 MiB stack | trapped at init (2026-08-16) | runs; stack HWM 82 KB on S2/S4/S5 |
| checksums S2 / S4 / S5 | f483375f / 5a438965 / 3d28f006 | identical ✅ (both modes) |

Hypothesis confirmed; `build.zig` `stack_size` override removed. **Keep.** Gate → PASS.

## Step 10 — render path (Tier 2, `GPU=1`)

Baseline (this morning, after the sim work): steady 174 fps, DOM 672 mutations / 512-frame ring
(≈1 per frame from `#timing-display`), APP alloc 9.7 KB/s ≈ 57 B/frame, `renderFrame` top allocator.

10a `script.js`: status line rebuilt at most every 250 ms and written only when the text changed
(also stops the per-frame `"PAUSED"` re-assignment). → DOM mutations 1822 → 2 (idle), 672 → 11 (steady).

10b `renderer.js`: no per-frame allocations in `updateData` — grid lines + uniforms rebuilt only when
world dimensions change (was `new Float32Array` every frame), the two `Float32Array` views over WASM
memory reused while buffer/pointer/length are unchanged, `getCurrentWorldDimensions()`/result-object
literals replaced by fields, render-pass descriptor hoisted (view swapped in place).
→ upload p50 0.065 → 0.020–0.025 ms; APP alloc 0 B/frame in every playing phase.

Harness fixes made along the way (measurement first): (i) gate metric changed from bytes/**second**
to bytes/**frame** — fps tripled with the sim work and must not change the verdict on the render
path; (ii) phase *setup* (pause/reset/settle) moved out of the sampled window — it was landing a
deterministic ~48 KB (a `renderFrame` de-opt/re-opt after the pause toggle) inside `steady`;
(iii) bytes/frame ceilings floored at 8 B/frame = one 4 KB sample per ~500 frames, because a
literal-0 ceiling from a noisy 0 sample fails on a single stray sample.

Result (`GPU=1 npm run bench:browser:assert --set-thresholds`, GATE PASS):

| phase | fps | sim p50 | upload p50 | submit p50 | APP B/frame | DOM/frame |
| --- | --- | --- | --- | --- | --- | --- |
| idle-paused | 2083 | 0 | 0.040 | 0.075 | 0 | 0.00 |
| steady | 425 | 2.085 | 0.025 | 0.055 | 0 | 0.01 |
| drag | 416 | 2.100 | 0.025 | 0.060 | 0 | 0.01 |
| paint | 334 | 2.685 | 0.030 | 0.060 | 0 | 0.01 |
| reset-storm | 499 | 1.700 | 0.030 | 0.060 | 0 | 0.01 |

(The remaining ≤ 0.01 DOM/frame is the 4 Hz status line = the documented irreducible floor; the WebGPU
per-frame wrapper objects — encoder, view, pass — are runtime allocations, not ours.)

Also: the Tier 1 vs Tier 2 sim gap from the baseline (3.0 vs 4.9 ms) is gone — Node 1.43 vs browser
1.5–2.1 ms for the same S2 state. Not investigated further; recorded as resolved-by-observation.

**Keep** (10a, 10b, harness fixes). SwiftShader thresholds re-set too; that mode's `submit` is 60–70 ms
(software raster) — artefact, not a target.
