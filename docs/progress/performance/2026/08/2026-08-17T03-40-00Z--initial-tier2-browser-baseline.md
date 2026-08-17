# Initial Tier 2 (browser) baseline — SwiftShader and real GPU

**Machine:** imac-battleship / Intel Xeon W-2170B / 28 cores · **Zig:** 0.16.0 · **Node:** v24.14.1 · **git:** 3352ea3 (dirty: Tier 2 harness uncommitted)
**wasm:** perf build ReleaseFast, sha `daa107f7cfe8` (served in place of the shipped file) · **Browser:** `/usr/bin/chromium` 146, headless, `--enable-unsafe-webgpu --enable-features=Vulkan --disable-frame-rate-limit --disable-gpu-vsync --js-flags=--expose-gc`
**Adapters:** SwiftShader (`google/swiftshader`) and `GPU=1` → `amd/gcn-5` (Radeon Vega, Vulkan) · cross-origin isolated, `performance.now()` resolution ≈ 5 µs
**Plan:** Phase 4 · **Purpose:** first browser baseline; creates `bench/thresholds.json → browser.{swiftshader,gpu}`. No optimisation attempted.

## Commands

```bash
npm run bench:browser            # swiftshader
GPU=1 npm run bench:browser      # real adapter
npm run bench:browser:assert && GPU=1 npm run bench:browser:assert   # created thresholds, both GATE PASS
```

Headless-WebGPU spike (same day): `navigator.gpu` is undefined on `about:blank` (not a secure context) but
present on `http://localhost`; SwiftShader adapter needs `--use-webgpu-adapter=swiftshader`; the real
adapter needs `--ignore-gpu-blocklist --use-gl=angle --use-angle=vulkan`.

## Results — `GPU=1` (amd/gcn-5), viewport 1920×1080, uncapped

| phase | frames | fps | sim p50 | sim p95 | upload p50 | submit p50 | frame p95 | APP KB/s | runtime KB/s | DOM mut | P | S |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| idle-paused | 512 | 885 | 0.000 | 0.000 | 0.090 | 0.110 | 1.975 | 5.0 | 2.1 | 1822 | 942 | 1159 |
| steady | 512 | 174 | 4.915 | 5.040 | 0.065 | 0.085 | 6.045 | 9.7 | 0.8 | 672 | 932 | 1160 |
| drag | 512 | 221 | 3.770 | 5.310 | 0.055 | 0.080 | 6.385 | 0.0 | 0.0 | 635 | 932 | 1160 |
| paint | 512 | 189 | 4.440 | 6.920 | 0.065 | 0.095 | 7.935 | 20.9 | 1.3 | 562 | 1487 | 1160 |
| reset-storm | 512 | 356 | 2.285 | 3.145 | 0.040 | 0.055 | 3.860 | 0.0 | 1.7 | 815 | 932 | 1159 |

Top APP allocator in every allocating phase: `renderFrame — script.js:338` (function-level attribution: the
per-frame status template string). DOM mutation source: `DIV#timing-display` ≈ 1 per frame (also while
paused: `"PAUSED"` is re-assigned every frame).

## Results — SwiftShader (software WebGPU)

| phase | frames | fps | sim p50 | sim p95 | upload p50 | submit p50 | frame p95 | APP KB/s | DOM mut |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| idle-paused | 288 | (n/a) | 0.000 | 0.000 | 0.100 | 0.105 | 65.8 | 0.0 | 291 |
| steady | 87 | 19 | 4.925 | 9.555 | 0.105 | 0.115 | 71.1 | 0.8 | 91 |
| drag | 50 | 15 | 8.275 | 12.360 | 0.150 | 0.170 | 73.3 | 16.7 | 51 |
| paint | 47 | 14 | 8.310 | 12.100 | 0.140 | 0.165 | 81.4 | 0.0 | 48 |
| reset-storm | 38 | 16 | 7.555 | 15.490 | 0.145 | 0.340 | 136.4 | 0.0 | 40 |

SwiftShader frame times (65–136 ms p95) are software-raster artefacts — 15–19 fps says nothing about the
app. Only the JS-side numbers (alloc, DOM, upload/submit CPU ms) transfer.

## Interpretation

- **Render path is cheap on the CPU**: upload (bulk readback + `writeBuffer`) 0.04–0.10 ms, submit 0.05–0.11 ms.
  On the real GPU the frame is ~5.7 ms at 174 fps with sim ≈ 4.9 ms — physics is the frame.
- **0/0/0 violations, as predicted**: ~1 DOM mutation per frame and 5–21 KB/s of JS allocation, all from
  the status line in `renderFrame` (and `"PAUSED"` re-assignment). `checkZoomChange` shows up as a
  4 KB blip in some windows. First render-path kaizen: update the status text on change / at ≤ 4 Hz.
- **Tier 1 vs Tier 2 sim disagreement**: S2 sim p50 4.9 ms in Chromium vs 3.0 ms in Node (same wasm,
  same state, both after warm-up). Unexplained; candidates: main-thread interleaving with rendering
  and input, different V8 flags/tiering in the renderer process, GC pauses landing inside the span.
  Until understood: no cross-tier comparisons.
- `grabs = 1..5` after reset-storm/drag even though the drag has no physical effect (stale mouse handle
  after `reset()`): `grab_count` is not a correctness oracle; the checksum is.
- The ring saturates at 512 frames in a 3 s window above ~170 fps; fps is derived from the frame-interval
  p50, so it is still valid, but `frames` no longer counts the whole window.

## Decision

Baseline recorded; thresholds created for both adapter modes (× 1.25). Nothing kept/reverted.
Follow-ups (render path): (1) status line on change/throttled — expect APP KB/s → ~0 and DOM/frame → ~0
in `steady`/`drag`/`paint`, then ratchet the browser thresholds to 0; (2) investigate the 4.9 vs 3.0 ms
sim gap before using Tier 2 sim numbers for decisions.
