# Morphogenesis — Application Analysis

*Date: 2026-08-16 · Commit analyzed: `6cd6947` (branch `main`, clean tree)*

## 1. Executive summary

Morphogenesis is a browser-based 2D particle/soft-body sandbox written in **Zig (compiled to freestanding wasm32)** with a **WebGPU** renderer and a thin **vanilla-JS host**. It is the early stage of a longer-term artificial-life / morphogenesis project (inspired by Levin and Turing): particles carry a *desired valence*, spontaneously form spring bonds with neighbours until that valence is satisfied, bonds break when overstretched, and the user can drag particles or "paint" new particles of a chosen valence.

State of the project (32 commits, most recent are `wip`/refactor commits):

- **Works end-to-end**: `zig build` succeeds (verified with Zig 0.16.0), the WASM exports a stable API, and the JS host renders particles/springs with instanced WebGPU draws.
- **Architecture is sound for its size**: simulation state lives entirely in static Zig arrays behind a generational arena; JS reads bulk `f32` buffers directly out of WASM memory and uploads them to the GPU with one `writeBuffer` each.
- **Physics is a partial XPBD implementation** with several semantic shortcuts (constraints regenerated every iteration, velocity impulses that get overwritten) — it is stable enough to play with, but the stiffness parameters do not mean what they appear to.
- **Several latent bugs** exist (dangling stack slices, broken drag after *Reset*, wrong particle used for the mouse-line visual, `u8` underflow in ReleaseFast). See §8.
- **README is stale** in most quantitative details (grid counts, Zig version, serve command, "current: triangle demo").

---

## 2. Repository layout

| Path | Lines | Role |
|---|---:|---|
| `src/main.zig` | 692 | Constants, `Particle`/`Spring` types, global state, WASM export surface, valence-bond formation, frame driver `update_particles` |
| `src/physics.zig` | 349 | `Constraint` type and `PhysicsSystem` (constraint generation from springs + spatial-grid collisions, solver) |
| `src/generational.zig` | 209 | `GenerationalArena(T, capacity)` — dense array + sparse→dense map + free list, 32-bit packed handles |
| `src/mouse.zig` | 221 | Virtual infinite-mass "mouse particle", grab radius search, grab springs |
| `src/reset.zig` | 111 | Initial layout of hexagonal particle grids and pseudo-random free agents; connection-table helpers |
| `src/spatial.zig` | 134 | Uniform spatial hash grid (fixed 60 px bins, ≤100×100 cells, ≤500 particles/cell) |
| `renderer.js` | 677 | `MorphogenesisRenderer`: WebGPU device/context, 4 pipelines (grid, springs, mouse spring, particles), WGSL shaders, bulk buffer upload |
| `script.js` | 406 | WASM loading, canvas/DPR handling, pointer & keyboard input, tools (grab / spawn valence 0-6), pause/step/reset, RAF loop, status line |
| `index.html`, `style.css`, `favicon.svg` | — | Fullscreen canvas + minimal overlay UI |
| `build.zig`, `build.sh` | — | wasm32-freestanding executable, `entry = .disabled`, `rdynamic = true`; helper script copies the artefact to repo root |
| `dev-server.js`, `package.json` | — | Node static server on :8000 with chokidar watch, auto-`./build.sh` on `.zig` change, WebSocket (:8001) hot reload injected into HTML |
| `claude.md` | — | Contributor guidelines (don't revert changed constants; no literal-duplicating comments) |
| `README.md` | — | Vision, roadmap, (outdated) tech notes |
| `webgpu-demo.wasm` | 1.8 MB | Build output, git-ignored, served from repo root |

There are **no tests**, no CI, and no lint configuration.

---

## 3. Build & tooling

- **Target**: `wasm32-freestanding`, no entry point, all `export fn`s exposed via `rdynamic`. Only two imports from JS: `console_log(ptr,len)` and `emscripten_webgpu_get_device()` (the latter is vestigial — the returned handle is logged and never used).
- **`build.sh`** hard-codes a Homebrew `zig@0.14` path (macOS-specific), falls back to `zig` on `PATH`, defaults to `ReleaseFast`, then copies `zig-out/bin/webgpu-demo.wasm` to `./`. README says "Zig 0.13.0+"; the `build.zig` uses the `root_module`/`createModule` API (0.14+). **Verified**: builds cleanly with Zig **0.16.0** on Linux.
- **`npm run dev`** → `dev-server.js`: serves the repo root, rebuilds on Zig changes, reloads browser via WS. Serving is naïve (`path.join(__dirname, req.url)` — no traversal guard; fine for localhost dev only).
- README's "serve with `python3 -m http.server`" also works since everything is static.

---

## 4. Runtime architecture

```
 ┌──────────── Browser ─────────────────────────────────────────────────────┐
 │  script.js                       renderer.js (WebGPU)                    │
 │  ├─ fetch+instantiate WASM       ├─ 4 render pipelines (WGSL inline)     │
 │  ├─ init(), set_world_dimensions ├─ uniform {particle_size, world_w/h}   │
 │  ├─ pointer/keyboard → tools     ├─ instance buffer ← get_particle_data_bulk()
 │  ├─ RAF loop:                    ├─ spring VB     ← get_spring_data_bulk()
 │  │    update_particles(0.016)    └─ draw grid → springs → mouse line → particles
 │  │    renderer.render()                                                  │
 │  └─ status line (ms, P, S, world, grid, bin occupancy)                   │
 └───────────────▲───────────────────────────┬──────────────────────────────┘
                 │ exports (~35 fns)         │ Float32Array views into wasm memory
 ┌───────────────┴───────────────────────────▼──────────────────────────────┐
 │  webgpu-demo.wasm (Zig, freestanding)                                     │
 │  main.zig  ── owns ParticleArena, SpringArena, constraints[], bulk bufs   │
 │     │  update_particles(dt):                                              │
 │     │   predict → mouse lock → updateValenceBonds → 6×{gen+solve} → commit│
 │     ├─ physics.zig   PhysicsSystem (distance + collision constraints)     │
 │     ├─ spatial.zig   60px uniform grid, populated each iteration          │
 │     ├─ mouse.zig     virtual particle + ≤5 grab springs                   │
 │     ├─ reset.zig     initial hex grids + free agents                      │
 │     └─ generational.zig  GenerationalArena(T, cap)                        │
 └───────────────────────────────────────────────────────────────────────────┘
```

**Coordinate system.** World units are **CSS pixels**, origin at screen centre, +y up. `set_world_dimensions(innerWidth, innerHeight)` is called on load, resize and DPR/zoom change; the shaders divide by half-extents to reach NDC, so particles stay 1:1 with logical pixels under browser zoom (canvas backing store follows `devicePixelRatio`).

---

## 5. Simulation core (Zig)

### 5.1 Data model

```zig
Particle { x, y, predicted_x, predicted_y, vx, vy : f32;
           mass : f32; grid_id, desired_valence, current_valence : u8 }
Spring   { particle_a, particle_b : ParticleHandle; rest_length : f32 }
Handle   = packed struct { index : u16, generation : u16 }   // 0xFFFF/0xFFFF = invalid
```

`Particle.init` seeds a velocity of `0.1·(x, y)` — a small radial outward drift used for the initial grids.

### 5.2 Generational arena (`generational.zig`)

- Dense `entries[capacity]` of `{data, handle}` + `sparse_to_dense[capacity]` + `generations[capacity]` + LIFO `free_indices`.
- `spawn` pops the free list (from the *end*, so the first particle gets index `capacity-1`), bumps the slot generation, appends to dense storage. `destroy` swap-removes and pushes the index back. `get/getMut/getDenseIndex` validate generation + dense range → safe against stale handles.
- Iteration is by dense index (`getDataAt`, `getHandleAt`, `forEachDense`), so hot loops are cache-friendly.
- ⚠ `getDenseData()` and `getDenseHandles()` copy the whole dense array into a **function-local** array and return a slice to it — a dangling-pointer bug (see §8.1). `rebuildDenseArrays`/`writeDenseToSparse` are no-op leftovers.

### 5.3 Capacities & key constants (`main.zig`)

| Constant | Value | Notes |
|---|---:|---|
| `GRID_COUNT × GRID_PARTICLE_SIZE²` | 3 × 144 = 432 | hexagonal lattices, valence 6 |
| `FREE_AGENT_COUNT` | 500 | valence 0 (inert), pseudo-random `sin`-hash positions |
| `EXTRA_PARTICLE_SLOTS` | 10 000 | user-painted particles |
| `PARTICLE_COUNT` (arena cap) | **10 932** | +1 slot is consumed by the mouse particle |
| `MAX_SPRINGS` | 1 728 + 20 000 = **21 728** | |
| `MAX_CONSTRAINTS` | 71 728 | springs + up to 50 000 collision pairs per iteration |
| `PARTICLE_SIZE` | 5 px radius | contact distance 10 px |
| `GRID_SPACING` | 14 px | initial lattice pitch |
| `SPRING_REST_LENGTH` | 15.5 px | bond forms at 0.9–1.1×, breaks at >1.4× (mouse springs >10×) |
| `XPBD_ITERATIONS` | 6 | `microDt = dt/6` |
| `GRAVITY` | 25 px/s² | `AIR_DAMPING = 1.0` (i.e. none) |
| `DISTANCE_STIFFNESS` | 1e9 | `COLLISION_STIFFNESS = 1.0`, ×10 "billiard" |
| Spatial bin | 60 px | `MAX_GRID_SIZE` 100×100, `MAX_PARTICLES_PER_CELL` 500 |

Fixed simulation `dt = 0.016 s` per rendered frame regardless of real frame time.

### 5.4 Per-frame pipeline (`update_particles`)

1. **Predict** — for every non-mouse particle: `vy -= g·dt`, `predicted = pos + v·dt`, clamp to world box and flip velocity ×−0.8.
2. **Mouse lock** — pin the mouse particle's position/prediction to the cursor, zero velocity.
3. **Valence bonding** (`updateValenceBonds`) — O(n²) scan over dense particles (with an inner O(springs) "already connected" check): if both have `current < desired` valence and their distance is within ±10 % of rest length, spawn a spring and bump both counters. Comment `// todo use neighbors` acknowledges the missing spatial query.
4. **6× iterations** of
   - `generateConstraints(microDt)` — reset constraint list; for each spring: destroy it if overstretched (refund valence) else emit a *distance* constraint with cached dense indices; then copy all particles into a temporary array, `populateGrid`, and for each non-mouse particle scan the 3×3 neighbourhood emitting *collision* constraints for overlapping pairs (`a.index < b.index` dedup).
   - `solveConstraints(microDt)` — Gauss-Seidel over the list.
5. **Commit** — `v = (predicted − pos)/dt`, `pos = predicted`.

### 5.5 Constraint solver semantics (`physics.zig`)

- **Distance** (springs & mouse springs): textbook XPBD form with `w = 1/mass` (mouse mass = +∞ → w = 0, so it never moves), `compliance = 1/(k·dt²)`, and `Δλ = −(C + α̃·λ)/(Σw + α̃)` where `α̃ = compliance/dt²`.
  - Because the constraint list is **rebuilt every iteration**, `λ` restarts at 0 each time — the accumulated-multiplier part of XPBD is effectively disabled and the method degrades to compliant PBD.
  - The compliance is divided by `dt²` twice (once at construction, once in the solver), so `α̃ = 1/(k·dt⁴)`. With `k = 1e9` and `microDt ≈ 0.00267`, `α̃ ≈ 20`, i.e. each iteration corrects only ~1/11 of the spring error. **Effective stiffness scales with `dt⁴`** and is much softer than the constant suggests.
- **Collision**: *not* XPBD — a hard positional split (50/50, mass ignored, compliance ignored) followed by a restitution-0.9 velocity impulse. The impulse writes `vx/vy`, but step 5 **recomputes velocity from positions**, so the impulse (and likewise the −0.8 wall bounce in step 1) is overwritten and has no lasting effect. Contact behaviour is therefore effectively inelastic.
- Constraint types `separation / alignment / cohesion` and the `aux_data` union (with a 16-handle array) are Boids leftovers — unused, but they inflate every `Constraint` to ~100 B (≈7 MB for the static array).

### 5.6 Spatial grid (`spatial.zig`)

Flat `[100·100]GridCell`, each cell a fixed `[500]u32` of **dense** indices + count (≈20 MB static). Bin size is fixed at 60 px = 6 particle diameters, grid dims derived from world size on `set_world_dimensions`. Populated from `particle.x/y` (current positions) while collisions are tested on `predicted_*` — acceptable because bins are much larger than a per-frame displacement. `max_occupancy` is tracked and shown in the UI status line.

### 5.7 Mouse interaction (`mouse.zig`)

The cursor is a real arena particle with `mass = inf`, `grid_id = 255`, valence 0. On press, up to 5 particles within `GRAB_RADIUS = 25 px` (via 3×3 grid-cell search) are connected to it by springs whose rest length is the grab distance; on release those springs are destroyed. Because the mouse particle is in the arena it is also **rendered** (as a grey valence-0 dot) and counted in `P:` in the status line.

### 5.8 Initial scene (`reset.zig`)

Grid centres are laid out on a 3×3 lattice 200 px apart but only the first `GRID_COUNT = 3` are used (top row: x = −200, 0, +200; y = −200). Each grid is a 12×12 hexagonal packing (odd rows offset ½, row pitch ×0.866) of valence-6 particles. Free agents get deterministic pseudo-random positions from `sin(i·12.9898)`, `sin(i·78.233)` across ±40 % of the world (with a 1920×1080 fallback when the world is still 1.95 units at `init` time). No springs are pre-created — bonding is emergent from valence.

---

## 6. WASM export surface

**Used by the JS host**

| Export | Purpose |
|---|---|
| `init()`, `reset()` | build/rebuild arenas, scene, mouse system |
| `update_particles(dt)` | one simulation step |
| `set_world_dimensions(w,h)`, `get_world_width/height`, `get_world_size` | world box (CSS px); `get_world_size` still returns the legacy 1.95 |
| `get_particle_data_bulk()` → `[x,y,desired,current]×N`, `get_bulk_particle_count()` | instance data |
| `get_spring_data_bulk()` → `[ax,ay,bx,by]×N`, `get_bulk_spring_count()` | line-list vertices |
| `get_max_particles()` (`PARTICLE_COUNT+1000`), `get_max_springs()`, `get_particle_size()`, `get_grid_size()` | buffer sizing / uniforms |
| `add_particle(x,y,valence)` | spawn tool |
| `set_mouse_interaction(x,y,pressed)`, `get_mouse_connected_particle()`, `get_mouse_position_x/y()` | drag tool + red mouse line |
| `get_alive_particle_count`, `get_alive_spring_count`, `get_spatial_max_occupancy`, `get_grid_dimensions_x/y`, `get_world_width/height_debug` | status line |

**Exported but stubbed / unused**: `get_spring_particle_a/b` (return −1), `get_particle_data` (returns 0), `get_particle_valence`, `get_particle_current_valence` (return 0), `destroy_particle_by_index` (no-op), `get_particle_count`, `get_mouse_grab_count`, `is_mouse_pressed`.

---

## 7. Rendering & host (JS)

- **Pipelines**: (1) spatial-grid lines, blue α 0.15; (2) springs, white α 0.9; (3) mouse spring, red; (4) particles — 6-vertex quad × instance buffer `[x, y, desired_valence, current_valence]`, fragment shader draws a soft disc (`smoothstep` edge + inner glow, `discard` outside). Particle colour encodes desired valence (grey 0, red 1, green 2, blue 3, yellow 4, magenta 5, cyan 6, rainbow beyond) and dims to 60 % when satisfied. All pipelines use premultiplied-style `src-alpha / one-minus-src-alpha` blending, one 12-byte uniform buffer shared through four identical bind groups.
- **Data path**: `renderer.updateData` calls the two `*_bulk` exports, wraps the returned pointer in a `Float32Array` view over `wasm.memory.buffer` and `queue.writeBuffer`s it — zero JS-side loops per particle. Grid lines and uniforms are rewritten every frame (cheap, but could be resize-only).
- **Host loop** (`script.js`): `requestAnimationFrame` → optionally `update_particles(0.016)` (respects Pause/Step) → `render` → status text `"<ms> | P:<n> S:<n> | WxH | GxG | bin:<max>"`.
- **Input**: pointer events converted to centred, y-up CSS-pixel world coords. Tools: **Grab** (`Q`/`G`, default) drives `set_mouse_interaction`; **Spawn 0–6** (`0`–`6` keys / toolbar) paints particles with the chosen valence, throttled to one particle per `PARTICLE_SIZE` of pointer travel. Buttons: Pause/Resume, Step (only while paused), Reset.
- Zoom handling: `resize` listener plus a 500 ms `setInterval` polling `devicePixelRatio`.

---

## 8. Findings

Ordered roughly by impact. Line references are to the analyzed commit.

### 8.1 Bugs / correctness

1. **Dangling slices from `getDenseData()` / `getDenseHandles()`** — `src/generational.zig:155-160,174-179` return `data_array[0..count]` where `data_array` is a stack local. Callers `getParticleHandleByIndex`, `getParticleByIndex`, `findClosestParticleIndex` (`src/main.zig:298-334`) read freed stack memory. `getParticleHandleByIndex` is on the live path of `mouse.findParticlesInGrabRadius` (`src/mouse.zig:106`), where it also copies the entire handle array (~44 KB) per candidate particle. It happens to work today only because nothing overwrites that stack region before use. Fix: return `self.entries[i].handle` directly.

2. **Drag stops working after *Reset*** — `reset()` (`src/main.zig:449-464`) calls `mouse.initMouseSystem()` *before* `initializeParticleSystems()` re-creates the arena, so the mouse particle handle it stores refers to the old arena. In the fresh arena that slot's generation is 0 ≠ the stored generation, every `getParticlePtr(mouse)` returns null, and grab springs are created with a dead endpoint (never solved, never drawn, never removed). Fix: spawn the mouse particle after the arena is re-initialized (as `init()` already does).

3. **`u8` underflow when refunding valence** — `src/physics.zig:143-144`: `@max(0, v - 1)` does not prevent `0 - 1` on a `u8`; it's a safety panic in Debug and wraps to 255 in ReleaseFast (a particle at 255 then never bonds again). Use saturating subtraction (`-|`) or guard on `> 0`.

4. **Mouse line drawn to the wrong particle** — `get_mouse_connected_particle` returns the grabbed handle's **sparse** index (`src/main.zig:671-676`), but `renderer.js:602-603` uses it to index the **dense**-ordered `cachedParticleData`. Also the grab springs are already in the spring arena and are drawn by the white bulk path, so the red line is both redundant and mis-targeted (and only ever shows one of up to five grabs).

5. **Velocity effects silently discarded** — the wall bounce (`predictPosition`, `vx *= -0.8`) and the collision restitution impulse (`solveConstraint .collision`) both modify `vx/vy`, but `updateFromPrediction` recomputes velocity from positions afterwards. Result: walls and contacts are effectively perfectly inelastic; the impulse code is dead weight. Either apply post-projection velocity corrections after the commit step, or drop the code.

6. **XPBD parameters don't mean what they say** — see §5.5: `λ` is reset every iteration (constraint list rebuilt), and compliance is divided by `dt²` twice, giving an effective `α̃ = 1/(k·dt⁴)`. Any tuning of `DISTANCE_STIFFNESS`, `MOUSE_STIFFNESS` (unused) or `XPBD_ITERATIONS` will behave non-intuitively. Consider generating springs' constraints once per frame (persisting `λ`) and regenerating only collisions per iteration.

7. **Valence counters can drift** — `current_valence` is maintained incrementally (bond +1, break −1) but `initializeValenceCounts()` is only run in `reset()`, and `destroyParticle`/`endGrab` don't touch valence (grab springs intentionally don't count, but ordinary springs whose partner disappears would). Low impact today because particles are never destroyed.

### 8.2 Performance

- **Large per-iteration stack copies**: `generateConstraints` declares `temp_particles: [PARTICLE_COUNT]Particle` (~440 KB) and `springs_to_remove: [MAX_SPRINGS]SpringHandle` (~87 KB) on the stack and copies all particles into `temp_particles` purely to feed `populateGrid` — **6 times per frame**. `populateGrid` is `anytype`, so it could take the arena directly.
- `updateValenceBonds` is O(n²·s) in the worst case (nested full scans plus a linear spring search per candidate pair). With ~1 000 particles it is fine; with the 10 000 paintable slots filled by non-zero-valence particles it will dominate the frame. The spatial grid and the (currently write-only) `particle_connections` table are the obvious fix.
- Static memory ≈ 20 MB spatial grid + ≈ 7 MB constraints + arenas/bulk buffers; comfortably within WASM limits but the grid cell capacity (500 × 4 B) is generous for 60 px bins of 10 px particles (max ≈ 40 tightly packed).
- Grid lines and uniforms are re-uploaded every frame; harmless but unnecessary.

### 8.3 Dead / vestigial code

- Stub exports listed in §6; `MOUSE_STIFFNESS`, `SEPARATION_RADIUS`, `SPRING_STRENGTH`, `SEPARATION_STRENGTH`, `applyBoundaryConstraints`, `Particle.init` (superseded by `initWithValence`), `Constraint` union payloads, `rebuildDenseArrays`/`writeDenseToSparse`, `mouse_spring` constraint type, `emscripten_webgpu_get_device` import/`device_handle`, `Vec2`.
- `particle_connections` / `particle_connection_counts` are written by `addParticleConnection` but never read; `destroyParticle` is never called; `initializeSprings` only zeroes the table (and is not re-run on `reset`).
- The renderer's grid overlay divides the world into `gridSize = max(gx, gy)` equal strips, which does **not** coincide with the actual 60 px spatial bins (aspect ratio and bin size differ) — it is decorative rather than diagnostic.

### 8.4 Documentation drift (`README.md`)

| README says | Code does |
|---|---|
| "Current: animated triangle demo" | full particle / valence-bond sandbox |
| 5 grids × 144, 1 000 boids, 16×16 spatial grid | 3 grids × 144, 500 free agents, dynamic ≤100×100 grid of 60 px bins |
| Zig 0.13.0+ | build.sh targets 0.14, builds on 0.16; `build.zig` API needs ≥0.14 |
| serve with `python3 -m http.server` | `npm run dev` (hot-reload dev server) is the intended flow |
| Boids separation/alignment/cohesion | Boids removed; XPBD springs + collisions + valence bonding |
| "~20 000+ spring capacity" | 21 728 ✔ (one of the few numbers still right) |

---

## 9. Recommendations (prioritised)

1. Fix the two arena API bugs (§8.1 #1, #2) — both are small, mechanical changes with user-visible impact.
2. Use `-|` for valence refunds (#3) and make `get_mouse_connected_particle` return a dense index or drop the red-line path (#4).
3. Decide on the physics semantics: either commit to XPBD (persist springs' `λ` across iterations, single `dt²`, add a post-solve velocity pass for restitution) or simplify to plain PBD and delete the impulse code. Re-tune constants afterwards.
4. Replace the O(n²) bond search with the spatial grid, and pass the arena (or its dense slice) to `populateGrid` to eliminate the per-iteration copies.
5. Prune vestigial exports/constants and update the README (or fold the accurate parts into `docs/`).
6. Add a minimal Zig test file for `GenerationalArena` (spawn/destroy/generation invalidation) and run `zig build test` in the dev server or a CI job.

---

## 10. Verification performed

- Read all tracked source files (`src/*.zig`, `*.js`, `*.html`, `*.css`, build & tooling files, README, claude.md).
- `zig build -Doptimize=ReleaseFast` with Zig 0.16.0 → success, `zig-out/bin/webgpu-demo.wasm` (1.8 MB).
- Findings in §8 are from static reading; the app was not exercised in a browser for this report.
