# Determinism

*Imported from `asimov-happy` (`docs/meta/concepts.md` "Determinism", `AGENTS.md` "Testing And
Verification (TDD and Determinism)", the deterministic-replay plans and
`docs/future/deterministic-layer-state-transformers.md`), adapted for this simulation on
2026-08-16.*

Determinism means the same inputs produce the same outputs. Here it applies to the physics step,
scene construction, user actions replayed as export calls, benchmarks, and tests. It is a core
engine requirement, not cosmetics.

## Why it matters for Morphogenesis

1. **Repeatable emergent behaviour.** Bond formation, lattice folding, and piles are chaotic; for a
   fixed initial state, fixed parameters, and fixed input stream they must evolve identically every
   time. That is what makes an emergent shape reproducible content rather than a lucky screenshot.
2. **Optimisation with a correctness oracle.** Every performance change is judged against a state
   checksum after N steps. If the checksum moved and no physics change was intended, the
   optimisation is wrong — no matter how good the timing looks. asimov-happy needed determinism
   verifies for this; we get it almost for free because the sim has no runtime randomness.
3. **Debuggability.** A bug that reproduces from `init` + a recorded list of export calls is a bug
   that can be fixed. One that depends on wall-clock time or pointer-event timing is not.
4. **Future replay/undo/multiplayer.** asimov-happy undoes by re-folding an effect log from
   frame 0. The same design is open to us only if the step function is a pure function of state +
   inputs. Keep that door open.

## What is deterministic today (keep it that way)

- `update_particles(dt)` is called with a **fixed `dt = 0.016`**; wall-clock time never enters the
  simulation. (FPS/ms displays are read-only observers.)
- **No `Math.random`, no `Date`, no `performance.now()` feeds the sim.** Initial free-agent
  positions come from a `sin`-hash of the index — deterministic, if crude.
- Physics runs on the **CPU in WASM** with IEEE-754 `f32`. Unlike asimov-happy's GPU float rules,
  the same wasm binary gives bit-identical results on every device. Rendering (WebGPU) is *outside*
  the deterministic core and may differ per GPU — that is fine.
- Iteration order is the **dense arena order**, which is a pure function of the spawn/destroy
  history. Same history → same order → same bonds formed in the same order.

## Practices (the rules)

- **Seeded randomness only.** If real randomness is ever needed (spawn jitter, growth rules), use a
  seeded PRNG in Zig (`std.Random.Xoshiro`/`Xoroshiro` or a tiny XorShift as asimov-happy does) whose
  seed is an explicit input (an export parameter, recorded in the scenario). Never JS `Math.random`
  for anything that reaches the sim.
- **Define tie-breaking rules explicitly.** Which particle bonds first when several are in range?
  Today: dense order, first fit. If that changes to a spatial query, the neighbour visit order
  must be defined (cell order, then dense order) and covered by the checksum test.
- **Keep iteration order stable and named.** Swap-remove in the arena changes dense order on
  destroy — that is deterministic but *order-sensitive*. Any refactor of `destroy`, `spawn`, or the
  free list is a determinism change and must be checked against goldens.
- **No hidden global state affecting the step.** Everything that influences `update_particles`
  must be reachable through the wasm exports (constants, world size, mouse, painted particles).
  Bench hooks that mutate parameters (`set_xpbd_iterations`, future setters) are inputs and must
  be recorded with the scenario.
- **No time-dependent behaviour in the sim.** Frame time, FPS, and `performance.now()` are for
  display and measurement only. If a variable-`dt` mode is ever added, the harness pins `dt`.
- **Floating point stays explicit.** No fast-math flags; `ReleaseFast` and `Debug` must agree on
  the checksum (verify this once and keep a test for it). Prefer `@sqrt`, `@mulAdd` and standard
  ops whose semantics are fixed over library functions whose implementations may vary. Reductions
  (sums over neighbours) keep a fixed order.
- **Inputs are values, not references to mutable UI.** Scenarios are built from export calls
  only (`init`, `set_world_dimensions`, `add_particle`, `set_mouse_interaction`, `update_particles`,
  `reset`), so a Node harness and the browser reproduce the same run.
- **Version what you can't keep stable.** Goldens are keyed by Zig version and optimise mode until
  cross-version stability is demonstrated. A physics change (intended) regenerates goldens with a
  note saying why; an unintended checksum change is a bug.

## The oracle: state checksum

- `state_checksum()` (planned in `src/perf.zig`, plain export, always available): FNV-1a-32 over
  the dense particles' `x, y, vx, vy` bit patterns and every alive spring's `(a, b, rest_length)`,
  in dense order. Same idea as asimov-happy's `fnv1a32` fingerprint over a stable serialisation.
- Two runs of the same build and scenario must be equal (**self-consistency**); the value must equal
  the committed golden for that scenario/N/build key (**regression**).
- Determinism scope: `Debug` vs `ReleaseFast` equality is a *test*, not an assumption; JS host
  differences (viewport, DPR) must not affect the checksum for the same world size — if they do,
  the host is leaking into the sim.

## Testing expectations (TDD)

- Write the failing test first when touching arena, bonding, spatial mapping, or the step order.
- Unit tests (`zig build test`): arena spawn/destroy/generation invalidation and dense-order
  behaviour; checksum stability across two identical runs; `worldToGrid` mapping; `u8` valence
  saturation.
- Harness tests (`bench/sim-assert`): golden checksums per scenario; Debug/ReleaseFast agreement.
- E2E (when the browser harness exists): a scripted paint + drag replayed twice yields the same
  checksum.

## Known determinism hazards in the current code

Not bugs in the sense of "wrong number", but places where determinism is fragile:

- `getDenseData()`/`getDenseHandles()` return slices into stack memory — reads may differ run to
  run once the stack is reused. Fix before relying on S5-style scenarios.
- `reset()` spawns the mouse particle before re-initialising the arena — the resulting stale handle
  makes post-reset behaviour depend on history rather than on the current scene.
- `spatial.max_occupancy` is overwritten each XPBD iteration — a display quirk, but any test that
  reads it must know which iteration it reflects.
- The `u8` valence refund can wrap in `ReleaseFast` — the same input then diverges between build
  modes.

> Same seed, same outcome,
> no drift in the folding
> lattice of our world.
