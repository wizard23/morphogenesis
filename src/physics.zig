const std = @import("std");
const spatial = @import("spatial.zig");
const mouse = @import("mouse.zig");
const main = @import("main.zig");
const perf = @import("perf.zig");

const ParticleHandle = main.ParticleHandle;
const SpringHandle = main.SpringHandle;
const Particle = main.Particle;
const Spring = main.Spring;
const MAX_SPRINGS = main.MAX_SPRINGS;
const PARTICLE_SIZE = main.PARTICLE_SIZE;
const PARTICLE_COUNT = main.PARTICLE_COUNT;
const NO_INDEX: u32 = 0xFFFFFFFF;
/// Extra radius (beyond contact) within which pairs become collision candidates for the step.
/// Must exceed the per-step displacement (measured ≤ 4.4 px at 6 iterations, `disp px` counter);
/// contact + margin must not exceed spatial.BIN_SIZE_PIXELS (3×3 scan exhaustiveness: the grid is populated at generation time, so no displacement slack is needed any more).
pub const CONTACT_MARGIN: f32 = PARTICLE_SIZE * 2.0;
pub const CONTACT_DISTANCE: f32 = PARTICLE_SIZE * 2.0;

/// One XPBD distance constraint (springs, mouse tethers). Regenerated once per step; MAX_SPRINGS of
/// them are static memory.
pub const Constraint = struct {
    particle_a: ParticleHandle,
    particle_b: ParticleHandle,

    // Cached dense indices for fast access
    dense_a: u32,
    dense_b: u32,

    target_value: f32, // rest length
    /// XPBD α̃ = 1 / (stiffness · dt²), dt = the full step (constraints live for one step and the
    /// solver iterates over the same predicted state; λ accumulates across those iterations).
    compliance: f32,
    lagrange_multiplier: f32,

    const Self = @This();

    pub fn initDistance(a: ParticleHandle, b: ParticleHandle, rest_length: f32, stiffness: f32, dt: f32) Self {
        return Self{
            .particle_a = a,
            .particle_b = b,
            .dense_a = 0xFFFFFFFF,
            .dense_b = 0xFFFFFFFF,
            .target_value = rest_length,
            .compliance = 1.0 / (stiffness * dt * dt),
            .lagrange_multiplier = 0.0,
        };
    }
};

/// A collision candidate: two dense indices. Contacts are hard inequality constraints at the fixed
/// contact distance (2 × PARTICLE_SIZE); no per-pair parameters, so 8 B per candidate.
pub const ContactPair = struct { a: u32, b: u32 };

/// Springs found overstretched during constraint generation, destroyed after the pass. Static so the
/// per-iteration frame does not carry a MAX_SPRINGS-sized array (was the last big stack user).
var springs_to_remove: [MAX_SPRINGS]SpringHandle = undefined;

/// SoA solver state for one step, indexed by dense particle index: the solver and the boundary pass
/// touch only these flat arrays (4 B stride) instead of 44 B arena entries; copied in after
/// constraint generation and written back before commit (slice "SoA solver", 2026-08-18).
var pred_x: [PARTICLE_COUNT]f32 = undefined;
var pred_y: [PARTICLE_COUNT]f32 = undefined;
var inv_mass: [PARTICLE_COUNT]f32 = undefined;
var solve_count: u32 = 0;

pub const PhysicsSystem = struct {
    // Direct references to arenas - no callbacks needed
    particle_arena: *main.ParticleArena,
    spring_arena: *main.SpringArena,

    // This step's constraint set: distance constraints first, then contact candidates. Solved in that
    // order (springs, then contacts) — the same order as the former single array.
    constraints: []Constraint,
    constraint_count: u32,
    contacts: []ContactPair,
    contact_count: u32,

    const Self = @This();

    pub fn init(
        particle_arena: *main.ParticleArena,
        spring_arena: *main.SpringArena,
        constraints: []Constraint,
        contacts: []ContactPair,
    ) Self {
        return Self{
            .particle_arena = particle_arena,
            .spring_arena = spring_arena,
            .constraints = constraints,
            .constraint_count = 0,
            .contacts = contacts,
            .contact_count = 0,
        };
    }

    /// Build this step's constraint set ONCE (plan 2026-08-17 slice 5): distance constraints for
    /// live springs (overstretched ones destroyed here), and collision candidates for every pair
    /// closer than contact + CONTACT_MARGIN on predicted positions. The solver then iterates over
    /// this fixed set; contacts that form during the iterations are inside the margin.
    pub fn generateConstraints(
        self: *Self,
        dt: f32,
        distance_stiffness: f32,
        mouse_stiffness: f32,
    ) void {
        self.constraint_count = 0;
        self.contact_count = 0;

        var t0 = perf.now();
        var remove_count: u32 = 0;

        // Generate distance constraints from springs
        const spring_count = self.spring_arena.getDenseCount();
        for (0..spring_count) |i| {
            const spring = self.spring_arena.getDataAt(@intCast(i));
            const spring_handle = self.spring_arena.getHandleAt(@intCast(i));

            const particle_a = self.particle_arena.getMut(spring.particle_a);
            const particle_b = self.particle_arena.getMut(spring.particle_b);

            if (particle_a != null and particle_b != null) {
                const dx = particle_b.?.x - particle_a.?.x;
                const dy = particle_b.?.y - particle_a.?.y;
                const current_length = @sqrt(dx * dx + dy * dy);

                const is_mouse_spring = mouse.isMouseParticle(spring.particle_a) or mouse.isMouseParticle(spring.particle_b);
                const max_allowed_length = if (is_mouse_spring) spring.rest_length * 10.0 else spring.rest_length * 1.4;
                const min_allowed_length = if (is_mouse_spring) spring.rest_length * 0.0 else spring.rest_length * 0.0;

                if (current_length > max_allowed_length or current_length < min_allowed_length) {
                    if (remove_count < MAX_SPRINGS) {
                        springs_to_remove[remove_count] = spring_handle;
                        remove_count += 1;

                        // Refund valence (saturating: mouse springs never counted, so the mouse
                        // particle sits at 0 — plain `- 1` panics in Debug / wraps in ReleaseFast)
                        particle_a.?.current_valence -|= 1;
                        particle_b.?.current_valence -|= 1;
                    }
                } else if (self.constraint_count >= self.constraints.len) {
                    perf.count(.constraints_dropped, 1);
                } else {
                    const stiffness = if (is_mouse_spring) mouse_stiffness else distance_stiffness;
                    var constraint = Constraint.initDistance(spring.particle_a, spring.particle_b, spring.rest_length, stiffness, dt);

                    // Cache dense indices
                    constraint.dense_a = self.particle_arena.getDenseIndex(spring.particle_a) orelse 0xFFFFFFFF;
                    constraint.dense_b = self.particle_arena.getDenseIndex(spring.particle_b) orelse 0xFFFFFFFF;

                    self.constraints[self.constraint_count] = constraint;
                    self.constraint_count += 1;
                }
            }
        }

        // Remove overstretched springs
        for (0..remove_count) |j| {
            self.spring_arena.destroy(springs_to_remove[j]);
        }
        perf.count(.springs_removed, remove_count);
        perf.add(.gen_springs, t0);

        // Generate collision constraints using spatial grid
        t0 = perf.now();
        const particle_count = self.particle_arena.getDenseCount();

        spatial.populateGridArena(self.particle_arena, .predicted);
        perf.max(.bin_max, spatial.getMaxOccupancy());
        perf.count(.cell_overflow, spatial.getOverflowCount());
        perf.add(.gen_grid, t0);

        t0 = perf.now();
        // Dense index of the mouse particle (or none): lets the inner loop skip it by index instead
        // of comparing handles per neighbour.
        const mouse_dense: u32 = if (mouse.mouse_particle) |mh| (self.particle_arena.getDenseIndex(mh) orelse NO_INDEX) else NO_INDEX;
        for (0..particle_count) |i| {
            if (i == mouse_dense) continue;
            self.generateCollisionConstraintsForParticle(@intCast(i), mouse_dense);
        }
        perf.count(.collision_pairs, self.contact_count);
        perf.count(.constraints, self.constraint_count + self.contact_count);
        perf.add(.gen_collide, t0);
    }

    fn generateCollisionConstraintsForParticle(
        self: *Self,
        particle_dense_idx: u32,
        mouse_dense: u32,
    ) void {
        const particle = self.particle_arena.getDataAt(particle_dense_idx);
        const px = particle.predicted_x;
        const py = particle.predicted_y;
        // Candidates: pairs that could touch during this step's iterations (contact + margin).
        const candidate_radius = CONTACT_DISTANCE + CONTACT_MARGIN;
        const candidate_radius_sq = candidate_radius * candidate_radius;

        // The grid was populated from predicted positions (see generateConstraints).
        const gx = spatial.worldToGridX(px);
        const gy = spatial.worldToGridY(py);
        const gsx: i32 = @intCast(spatial.grid_size_x);
        const gsy: i32 = @intCast(spatial.grid_size_y);

        // Half neighbourhood: each unordered pair is visited exactly once — from the particle whose
        // cell comes first in (y, x) order, or, within one cell, from the earlier entry. Own cell:
        // later entries only; forward cells (+x), (−x,+y), (0,+y), (+x,+y): all entries.
        const offsets = [_][2]i32{ .{ 0, 0 }, .{ 1, 0 }, .{ -1, 1 }, .{ 0, 1 }, .{ 1, 1 } };
        inline for (offsets, 0..) |off, oi| {
            const check_x = gx + off[0];
            const check_y = gy + off[1];
            if (check_x >= 0 and check_x < gsx and check_y >= 0 and check_y < gsy) {
                const cell = spatial.getGridCellByCoords(@intCast(check_x), @intCast(check_y));
                const own_cell = oi == 0;

                for (0..cell.count) |i| {
                    const neighbor_index = cell.idx[i];
                    if (own_cell and neighbor_index <= particle_dense_idx) continue; // self + earlier entries
                    if (neighbor_index == mouse_dense) continue;

                    const dx_pred = px - cell.x[i];
                    const dy_pred = py - cell.y[i];
                    const dist_sq = dx_pred * dx_pred + dy_pred * dy_pred;

                    if (dist_sq >= candidate_radius_sq) continue;

                    if (self.contact_count >= self.contacts.len) {
                        perf.count(.constraints_dropped, 1);
                    } else {
                        self.contacts[self.contact_count] = .{ .a = particle_dense_idx, .b = neighbor_index };
                        self.contact_count += 1;
                    }
                }
            }
        }
    }

    /// Copy predicted positions and inverse masses into the SoA solver arrays.
    pub fn beginSolve(self: *Self) void {
        const n = self.particle_arena.getDenseCount();
        solve_count = n;
        for (0..n) |i| {
            const p = self.particle_arena.getDataAt(@intCast(i));
            pred_x[i] = p.predicted_x;
            pred_y[i] = p.predicted_y;
            inv_mass[i] = 1.0 / p.mass;
        }
    }

    /// Write solved predictions back to the arena.
    pub fn endSolve(self: *Self) void {
        for (0..solve_count) |i| {
            const p = self.particle_arena.getDataAt(@intCast(i));
            p.predicted_x = pred_x[i];
            p.predicted_y = pred_y[i];
        }
    }

    pub fn solveConstraints(self: *Self) void {
        for (0..self.constraint_count) |i| {
            solveDistance(&self.constraints[i]);
        }
        for (0..self.contact_count) |i| {
            solveContact(self.contacts[i]);
        }
    }

    /// World box as a hard constraint on the SoA state (after every iteration). Fixed particles
    /// (inverse mass 0, i.e. the mouse) are left alone.
    pub fn applyBoundary(self: *Self, half_w: f32, half_h: f32) void {
        _ = self;
        for (0..solve_count) |i| {
            if (inv_mass[i] == 0) continue;
            if (pred_x[i] > half_w) {
                pred_x[i] = half_w;
            } else if (pred_x[i] < -half_w) {
                pred_x[i] = -half_w;
            }
            if (pred_y[i] > half_h) {
                pred_y[i] = half_h;
            } else if (pred_y[i] < -half_h) {
                pred_y[i] = -half_h;
            }
        }
    }

    /// XPBD: C = d − rest, ∇C unit along the pair, Δλ = −(C + α̃λ) / (w_a + w_b + α̃)
    fn solveDistance(constraint: *Constraint) void {
        const a = constraint.dense_a;
        const b = constraint.dense_b;
        if (a == NO_INDEX or b == NO_INDEX or a >= solve_count or b >= solve_count) return;

        const dx = pred_x[a] - pred_x[b];
        const dy = pred_y[a] - pred_y[b];
        const current_distance = @sqrt(dx * dx + dy * dy);
        if (current_distance < 0.001) return;
        const w_a = inv_mass[a];
        const w_b = inv_mass[b];
        const grad_x = dx / current_distance;
        const grad_y = dy / current_distance;
        const constraint_value = current_distance - constraint.target_value;
        const denominator = w_a + w_b + constraint.compliance;
        if (denominator < 1e-12) return;
        const delta_lambda = -(constraint_value + constraint.compliance * constraint.lagrange_multiplier) / denominator;
        constraint.lagrange_multiplier += delta_lambda;

        pred_x[a] += w_a * delta_lambda * grad_x;
        pred_y[a] += w_a * delta_lambda * grad_y;
        pred_x[b] -= w_b * delta_lambda * grad_x;
        pred_y[b] -= w_b * delta_lambda * grad_y;
    }

    /// Non-penetration as a hard inequality: inactive unless closer than contact; then separate along
    /// the normal, weighted by inverse mass. (No velocity impulse: velocity is recomputed from
    /// positions at commit, so contacts are inelastic by design.)
    fn solveContact(pair: ContactPair) void {
        const a = pair.a;
        const b = pair.b;
        const dx = pred_x[a] - pred_x[b];
        const dy = pred_y[a] - pred_y[b];
        const current_distance = @sqrt(dx * dx + dy * dy);
        if (current_distance < 0.001) {
            pred_x[a] += 0.01;
            pred_x[b] -= 0.01;
            return;
        }
        const penetration = CONTACT_DISTANCE - current_distance;
        if (penetration <= 0) return;
        const w_a = inv_mass[a];
        const w_b = inv_mass[b];
        const normal_x = dx / current_distance;
        const normal_y = dy / current_distance;
        const w_sum = w_a + w_b;
        if (w_sum < 1e-12) return;
        pred_x[a] += normal_x * penetration * (w_a / w_sum);
        pred_y[a] += normal_y * penetration * (w_a / w_sum);
        pred_x[b] -= normal_x * penetration * (w_b / w_sum);
        pred_y[b] -= normal_y * penetration * (w_b / w_sum);
    }
};
