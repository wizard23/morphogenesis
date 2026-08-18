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

pub const ConstraintType = enum {
    distance,
    collision,
};

/// One solver constraint. Kept small: it is regenerated every XPBD iteration and streamed by the
/// solver, and MAX_CONSTRAINTS of them are static memory (was ~100 B with a Boids-era union payload).
pub const Constraint = struct {
    type: ConstraintType,
    particle_a: ParticleHandle,
    particle_b: ParticleHandle,

    // Cached dense indices for fast access
    dense_a: u32,
    dense_b: u32,

    // Constraint parameters
    target_value: f32, // rest_length for distance, contact distance for collision
    /// XPBD α̃ = 1 / (stiffness · dt²), dt = the full step (constraints live for one step and the
    /// solver iterates over the same predicted state; λ accumulates across those iterations).
    compliance: f32,
    lagrange_multiplier: f32,

    const Self = @This();

    pub fn initDistance(a: ParticleHandle, b: ParticleHandle, rest_length: f32, stiffness: f32, dt: f32) Self {
        return Self{
            .type = .distance,
            .particle_a = a,
            .particle_b = b,
            .dense_a = 0xFFFFFFFF,
            .dense_b = 0xFFFFFFFF,
            .target_value = rest_length,
            .compliance = 1.0 / (stiffness * dt * dt),
            .lagrange_multiplier = 0.0,
        };
    }

    /// Contacts are hard (non-compliant) inequality constraints; compliance/λ are unused for them.
    pub fn initCollision(a: ParticleHandle, b: ParticleHandle, contact_distance: f32) Self {
        return Self{
            .type = .collision,
            .particle_a = a,
            .particle_b = b,
            .dense_a = 0xFFFFFFFF,
            .dense_b = 0xFFFFFFFF,
            .target_value = contact_distance,
            .compliance = 0.0,
            .lagrange_multiplier = 0.0,
        };
    }
};

/// Springs found overstretched during constraint generation, destroyed after the pass. Static so the
/// per-iteration frame does not carry a MAX_SPRINGS-sized array (was the last big stack user).
var springs_to_remove: [MAX_SPRINGS]SpringHandle = undefined;

pub const PhysicsSystem = struct {
    // Direct references to arenas - no callbacks needed
    particle_arena: *main.ParticleArena,
    spring_arena: *main.SpringArena,

    // Unified constraint array
    constraints: []Constraint,
    constraint_count: u32,

    const Self = @This();

    pub fn init(
        particle_arena: *main.ParticleArena,
        spring_arena: *main.SpringArena,
        constraints: []Constraint,
    ) Self {
        return Self{
            .particle_arena = particle_arena,
            .spring_arena = spring_arena,
            .constraints = constraints,
            .constraint_count = 0,
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
        const spring_constraint_count = self.constraint_count;

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
            const handle = self.particle_arena.getHandleAt(@intCast(i));
            self.generateCollisionConstraintsForParticle(handle, @intCast(i), mouse_dense);
        }
        perf.count(.collision_pairs, self.constraint_count - spring_constraint_count);
        perf.count(.constraints, self.constraint_count);
        perf.add(.gen_collide, t0);
    }

    fn generateCollisionConstraintsForParticle(
        self: *Self,
        particle_handle: ParticleHandle,
        particle_dense_idx: u32,
        mouse_dense: u32,
    ) void {
        const particle = self.particle_arena.getDataAt(particle_dense_idx);
        const px = particle.predicted_x;
        const py = particle.predicted_y;
        const contact_distance = PARTICLE_SIZE * 2.0;
        // Candidates: pairs that could touch during this step's iterations (contact + margin).
        const candidate_radius = contact_distance + CONTACT_MARGIN;
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

                    if (self.constraint_count >= self.constraints.len) {
                        perf.count(.constraints_dropped, 1);
                    } else {
                        const neighbor_handle = self.particle_arena.getHandleAt(neighbor_index);
                        var constraint = Constraint.initCollision(particle_handle, neighbor_handle, contact_distance);
                        constraint.dense_a = particle_dense_idx;
                        constraint.dense_b = neighbor_index;

                        self.constraints[self.constraint_count] = constraint;
                        self.constraint_count += 1;
                    }
                }
            }
        }
    }

    pub fn solveConstraints(self: *Self) void {
        for (0..self.constraint_count) |i| {
            self.solveConstraint(&self.constraints[i]);
        }
    }

    fn solveConstraint(self: *Self, constraint: *Constraint) void {
        // Use cached dense indices for direct access
        if (constraint.dense_a == NO_INDEX or constraint.dense_b == NO_INDEX or
            constraint.dense_a >= self.particle_arena.getDenseCount() or
            constraint.dense_b >= self.particle_arena.getDenseCount())
        {
            return;
        }

        const particle_a = self.particle_arena.getDataAt(constraint.dense_a);
        const particle_b = self.particle_arena.getDataAt(constraint.dense_b);

        const dx = particle_a.predicted_x - particle_b.predicted_x;
        const dy = particle_a.predicted_y - particle_b.predicted_y;
        const current_distance = @sqrt(dx * dx + dy * dy);
        const w_a = 1.0 / particle_a.mass;
        const w_b = 1.0 / particle_b.mass;

        switch (constraint.type) {
            .distance => {
                // XPBD: C = d − rest, ∇C unit along the pair, Δλ = −(C + α̃λ) / (w_a + w_b + α̃)
                if (current_distance < 0.001) return;
                const grad_x = dx / current_distance;
                const grad_y = dy / current_distance;
                const constraint_value = current_distance - constraint.target_value;
                const denominator = w_a + w_b + constraint.compliance;
                if (denominator < 1e-12) return;
                const delta_lambda = -(constraint_value + constraint.compliance * constraint.lagrange_multiplier) / denominator;
                constraint.lagrange_multiplier += delta_lambda;

                particle_a.predicted_x += w_a * delta_lambda * grad_x;
                particle_a.predicted_y += w_a * delta_lambda * grad_y;
                particle_b.predicted_x -= w_b * delta_lambda * grad_x;
                particle_b.predicted_y -= w_b * delta_lambda * grad_y;
            },

            .collision => {
                // Non-penetration as a hard inequality: inactive unless closer than contact; then
                // separate along the normal, weighted by inverse mass. (No velocity impulse: velocity
                // is recomputed from positions at commit, so contacts are inelastic by design.)
                if (current_distance < 0.001) {
                    particle_a.predicted_x += 0.01;
                    particle_b.predicted_x -= 0.01;
                    return;
                }
                const penetration = constraint.target_value - current_distance;
                if (penetration <= 0) return;
                const normal_x = dx / current_distance;
                const normal_y = dy / current_distance;
                const w_sum = w_a + w_b;
                if (w_sum < 1e-12) return;
                particle_a.predicted_x += normal_x * penetration * (w_a / w_sum);
                particle_a.predicted_y += normal_y * penetration * (w_a / w_sum);
                particle_b.predicted_x -= normal_x * penetration * (w_b / w_sum);
                particle_b.predicted_y -= normal_y * penetration * (w_b / w_sum);
            },
        }
    }
};
