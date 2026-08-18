# Split constraint lists: distance constraints (32 B) and contact pairs (8 B), specialised solver loops

**Machine:** imac-battleship, load ~9, **pinned to cpu 27** · **Zig:** 0.16.0 · A = HEAD (cd64dfa), B = working tree.

Change (`src/physics.zig`, `src/main.zig`): the single typed constraint array becomes a distance list
(springs/tethers, unchanged record minus the type tag) plus a `ContactPair {a, b}` list at the fixed
contact distance; `solveConstraints` runs the two specialised loops (springs first, then contacts —
the same order as before, hence identical checksums). Test oracle counts `contact_count`.

| scenario | A p50 | B p50 | paired Δp50 (IQR) | paired Δmin (IQR) | verdict | solve | checksum |
| --- | --- | --- | --- | --- | --- | --- | --- |
| S2 | 0.552 | 0.530 | −4.1 % (1.0 %) | −4.2 % (1.0 %) | **B faster** | −5 % | same |
| S3 | 2.378 | 2.254 | −5.2 % (1.0 %) | −5.6 % (1.0 %) | **B faster** | −9 % | same |
| S4 | 1.836 | 1.787 | −2.7 % (1.1 %) | −3.6 % (1.0 %) | **B faster** | −3 % | same |
| S6 | 7.832 | 7.596 | −3.0 % (1.6 %) | −4.6 % (1.0 %) | inconclusive (just under 2×IQR; min agrees) | −3 % | same |

Memory: 152 → **114 pages (7.1 MB)** — contact candidates 32 → 8 B (ceiling ratcheted to 114).
Gate PASS. (Absolute p50s are ~10 % above yesterday's at the same code — the machine is slower today
under load 9; the paired ratios are the comparison.)

**Keep.** Remaining `solve` idea: wasm SIMD over the flat arrays; remaining `gen_*`: dirty-cell clear.
