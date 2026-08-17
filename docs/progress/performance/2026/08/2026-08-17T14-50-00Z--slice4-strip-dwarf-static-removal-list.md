# Slice 4 — stripped release wasm, `springs_to_remove` off the stack

**Plan:** slice 4 · **Zig:** 0.16.0 · behaviour-preserving (checksums identical: S4 5acb4310, S5 3efa13f7).

| | before | after |
| --- | --- | --- |
| shipped `webgpu-demo.wasm` (`./build.sh`, ReleaseFast) | 807 710 B (39 KB code + ~590 KB DWARF + names) | **54 293 B** (`-Dstrip=true`; `STRIP=0 ./build.sh` keeps symbols) |
| bench/perf builds | unstripped | unchanged (readable stack traces) |
| stack HWM (S4, S5, S7[1]) | 81 KB (`springs_to_remove: [MAX_SPRINGS]` in the per-iteration frame) | **0 KB** (static module array) |
| linear memory | 124 pages | 125 pages (+87 KB static) — ceiling set to 125 with note |

Gate PASS otherwise (pinned). **Keep.**
