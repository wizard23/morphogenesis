# Kaizen Programming Approach

*Imported from `asimov-happy/AGENTS.md` ("Kaizen Programming Approach", "Review Standard") and
`docs/meta/concepts.md` ("0/0/0"), adapted for a Zig → WASM + WebGPU code base on 2026-08-16.*

Kaizen here means continuous improvement through small, coherent, reviewable steps. The goal is
not just to make a change work; the goal is to leave the code base easier to understand, safer to
change, and less surprising than before. It applies equally to physics code, the JS host, the
build, and the docs.

## Core principles

- **No hacks.** Do not paper over design problems with local special cases, hidden flags,
  duplicated state, or magic constants. In Zig that also means: no `undefined` reads to dodge an
  init order problem, no `@intCast`/`@ptrCast` to silence a type mismatch you don't understand, no
  `anytype` where a concrete type expresses the contract, no `catch unreachable` on a path that can
  fail.
- **Prefer behaviour-preserving cleanup before feature work** when the existing structure blocks a
  clean implementation. Do the cleanup as its own step (own commit, own verification).
- **Make the smallest change that fully solves the current problem** without creating avoidable
  future cleanup.
- **Keep the simulation separate from the host.** Physics, arenas, spatial hashing, and bonding
  live in Zig and know nothing about the DOM, WebGPU, or input devices. The JS host owns rendering,
  input, and lifecycle. Data crosses the boundary as bulk buffers, not per-item calls.
- **Prefer explicit contracts over implicit coupling.** Exports are the API; a JS file must not
  depend on the memory layout of a Zig struct except through an export that names it
  (`get_particle_data_bulk` → 4 floats per particle, documented once).
- **Prefer simple modules with clear ownership** over large coordinator files. `main.zig` is
  currently the coordinator (constants, types, globals, exports, bonding); do not make it larger
  without extracting something first.
- **Leave unrelated code alone** unless touching it is necessary for a clean result.
- **When a shortcut is tempting, stop and name the underlying design problem** — in the commit
  message, the plan, or a `docs/` note.
- **Constants may change externally** (`claude.md`): tuning constants belong to the person tuning.
  If a constant changed under you, assume intent and don't revert it without asking. Never
  duplicate a literal in a comment.

## The hot-loop rule: 0 / 0 / 0

asimov-happy's shorthand for its rAF loop is `0/0/0` — zero DOM writes, zero allocations, zero GPU
readbacks per frame. Translated to this app's frame (`update_particles` + `renderer.render`):

- **0 JS allocations per frame** — no object/array literals, no `new Float32Array` in
  `renderFrame`/`updateData`; preallocate views and reuse them; strings only on value change.
- **0 DOM writes per frame** — status text and tool display update on change or at a fixed low
  rate, never unconditionally every frame.
- **0 per-frame copies across the wasm↔JS boundary** beyond the two bulk uploads; and inside Zig,
  **0 whole-population copies per XPBD iteration** (the current `temp_particles` copy in
  `generateConstraints` is the known violation).

This is not aesthetic. It is what keeps the frame time attributable to physics rather than to
runtime noise, and it is measured, not assumed — see `docs/HOWTO-performance.md` (when it exists)
and `docs/plans/2026-08-16--performance-testing-plan.md`.

## Planning work

- Start by reading the relevant code and docs. Let the existing architecture guide the change.
- For non-trivial work, write or update a plan in `docs/plans/` before implementing.
- Split large work into slices that can be reviewed and verified independently. Each slice has a
  behavioural goal, affected files, acceptance criteria, and verification steps.
- Do not mix unrelated refactors with behaviour changes unless the refactor is required to make
  the behaviour change clean.
- Prefer one migration path. Don't keep old and new designs alive indefinitely (e.g. stub exports
  that return `-1`/`0` "for compatibility" — remove them or implement them).

## Clean-architecture expectations for this repo

- **Zig modules own their state.** `spatial.zig` owns the grid, `mouse.zig` owns grab state,
  `generational.zig` owns nothing but the arena type. Cross-module access goes through `pub fn`s,
  not through reaching into another module's `var`s.
- **Handles, not indices, cross module boundaries.** Dense indices are an iteration detail of the
  arena and are valid only until the next spawn/destroy; a function that returns one must say so.
- **Never return a slice into a stack-local array.** (`getDenseData`/`getDenseHandles` are the
  known offenders.)
- **Sizes and capacities are named once** and derived (`PARTICLE_COUNT` → buffer sizes on both
  sides via exports), never re-typed in JS.
- **Lifecycle is explicit** on the JS side: rAF handle, event listeners, GPU buffers, `setInterval`
  polls, WebSocket for hot reload — created once, torn down deterministically if the page ever
  gains a second scene.
- **Build modes are explicit.** `./build.sh` = `ReleaseFast`; a bare `zig build` = `Debug`.
  Anything that reports a number states which one it measured.
- **Physics semantics are written down**, not implied by constants. If a stiffness value only
  works because of a `dt²` double-division, that is a design problem to name, not a tuning fact.

## Zig-specific safety habits

- Prefer safe arithmetic on `u8`/`u16` counters (`-|`, `+|`, or an explicit guard) — `ReleaseFast`
  wraps silently, `Debug` panics; both are bugs.
- Prefer `?T`/error unions over sentinel values at new boundaries; keep existing sentinels
  (`0xFFFF` handles) documented where they are.
- Keep `comptime` gates for instrumentation (`-Dperf`) truly zero-cost when off.
- Run `zig build` in `Debug` at least once per change touching indices, arithmetic on small ints,
  or arena code — the safety checks are the cheapest test we have until unit tests exist.
- Add `zig build test` coverage for pure pieces (arena, spatial mapping, checksum) as they are
  touched — see [determinism.md](determinism.md) for what those tests must assert.

## Testing and verification

- Add focused tests for pure helpers and deterministic algorithms; broaden them when changing
  shared contracts (export signatures, bulk buffer layouts, arena semantics).
- For visual/interaction changes, verify in the browser and write down what was checked.
- Before hand-off of substantial changes: `./build.sh` (ReleaseFast) **and** `./build.sh Debug`
  both build; the page loads without console errors; the perf gate (once it exists) passes.
- If a check cannot be run, say so and state the remaining risk.

## Documentation

- Documentation describes decisions and trade-offs, not just code.
- Plans go to `docs/plans/`, reports to `docs/reports/` (or `docs/perf/` for performance),
  measurements to `docs/progress/performance/<yyyy>/<mm>/`.
- Keep the README truthful; a stale README is a defect (see the 2026-08-16 analysis report).

## Git and worktree discipline

- The worktree may contain user changes. Do not revert or overwrite changes you did not make.
- Keep diffs focused; avoid formatting churn outside touched code.
- No destructive git commands unless explicitly requested.

## Review standard

Before calling work done, ask:

- Is the behaviour correct — and is it *still deterministic* ([determinism.md](determinism.md))?
- Is the design simpler or clearer than before?
- Are responsibilities in the right module (Zig sim vs JS host; `main.zig` vs owned module)?
- Are boundaries validated (handles checked, indices bounded, imports supplied)?
- Are resources and capacities accounted for (static memory, stack, GPU buffers)?
- Are tests or manual checks appropriate for the risk?
- Did the change avoid repo-specific hacks and preserve future options?

If the answer is no, do the next small kaizen step before handing off.

> Write the test first, then
> watch it fail, then make it pass,
> refactor with peace.
