# Claude Code Guidelines

## Code Changes & Constants

- **Constants may change externally**: If you see that a constant has changed from under you, assume I did that intentionally and don't change it back without asking first.

- **Avoid literal comments**: Don't leave comments that include literals which we have in code since it makes it annoying to edit the literals and creates repetitive maintenance overhead.
## Example

**Bad:**
```zig
const PARTICLE_SIZE = 0.008; // Physical radius of particles is 0.008
```

**Good:**  
```zig
const PARTICLE_SIZE = 0.008; // Physical radius of particles
```

This keeps comments descriptive without duplicating values that may change.

## Principles

- **Kaizen** — small, coherent, reviewable steps; no hacks; 0/0/0 hot loop; review standard.
  See [`docs/principles/kaizen.md`](docs/principles/kaizen.md).
- **Determinism** — same inputs, same outputs; fixed `dt`, seeded randomness only, state checksum
  as the oracle for every optimisation. See [`docs/principles/determinism.md`](docs/principles/determinism.md).

## Performance workflow

- Before/after any change to `src/*.zig` hot paths: `npm run bench:sim:assert` (≈4.5 min) — or
  `npm run bench:sim -- --only S2` while iterating. Before hand-off of render/host changes:
  `npm run bench:browser:assert`. Record every measurement in `docs/progress/performance/<yyyy>/<mm>/`.
  How to run and judge: [`docs/HOWTO-performance.md`](docs/HOWTO-performance.md).
