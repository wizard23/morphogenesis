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
    target_value: f32, // rest_length for distance, min_distance for collision
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

    pub fn initCollision(a: ParticleHandle, b: ParticleHandle, min_dist: f32, stiffness: f32, dt: f32) Self {
        return Self{
            .type = .collision,
            .particle_a = a,
            .particle_b = b,
            .dense_a = 0xFFFFFFFF,
            .dense_b = 0xFFFFFFFF,
            .target_value = min_dist,
            .compliance = 1.0 / (stiffness * dt * dt),
            .lagrange_multiplier = 0.0,
        };
    }
};

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

    pub fn generateConstraints(
        self: *Self,
        dt: f32,
        distance_stiffness: f32,
        collision_stiffness: f32,
    ) void {
        self.constraint_count = 0;

        var t0 = perf.now();
        var springs_to_remove: [MAX_SPRINGS]SpringHandle = undefined;
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
                } else if (self.constraint_count < self.constraints.len) {
                    var constraint = Constraint.initDistance(spring.particle_a, spring.particle_b, spring.rest_length, distance_stiffness, dt);

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
            self.generateCollisionConstraintsForParticle(handle, @intCast(i), mouse_dense, dt, collision_stiffness);
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
        dt: f32,
        collision_stiffness: f32,
    ) void {
        const particle = self.particle_arena.getDataAt(particle_dense_idx);
        const px = particle.predicted_x;
        const py = particle.predicted_y;
        const contact_distance = PARTICLE_SIZE * 2.0;
        const contact_distance_sq = contact_distance * contact_distance;
        const billiard_stiffness = collision_stiffness * 10.0;

        // The grid was populated from predicted positions (see generateConstraints).
        const gx = spatial.worldToGridX(px);
        const gy = spatial.worldToGridY(py);

        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const check_x = gx + dx;
                const check_y = gy + dy;

                if (check_x >= 0 and check_x < @as(i32, @intCast(spatial.grid_size_x)) and
                    check_y >= 0 and check_y < @as(i32, @intCast(spatial.grid_size_y)))
                {
                    const cell = spatial.getGridCellByCoords(@intCast(check_x), @intCast(check_y));

                    for (0..cell.count) |i| {
                        const neighbor_index = cell.idx[i];
                        // Each unordered pair once: the lower dense index owns it. This also skips self.
                        if (neighbor_index <= particle_dense_idx or neighbor_index == mouse_dense) continue;

                        const dx_pred = px - cell.x[i];
                        const dy_pred = py - cell.y[i];
                        const dist_sq = dx_pred * dx_pred + dy_pred * dy_pred;

                        // Cheap exact reject: dist_sq >= c² ⇒ sqrt(dist_sq) >= c (sqrt is monotone,
                        // c² exact), so the sqrt below is only reached for candidate contacts.
                        if (dist_sq >= contact_distance_sq) continue;
                        const current_distance = @sqrt(dist_sq);

                        if (current_distance < contact_distance) {
                            if (self.constraint_count < self.constraints.len) {
                                const neighbor_handle = self.particle_arena.getHandleAt(neighbor_index);
                                var constraint = Constraint.initCollision(particle_handle, neighbor_handle, contact_distance, billiard_stiffness, dt);
                                constraint.dense_a = particle_dense_idx;
                                constraint.dense_b = neighbor_index;

                                self.constraints[self.constraint_count] = constraint;
                                self.constraint_count += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    pub fn solveConstraints(self: *Self, dt: f32) void {
        for (0..self.constraint_count) |i| {
            self.solveConstraint(&self.constraints[i], dt);
        }
    }

    // pub fn solveCollisionConstraintsOnly(self: *Self, dt: f32) void {
    //     for (0..self.constraint_count) |i| {
    //         if (self.constraints[i].type == .collision) {
    //             self.solveConstraint(&self.constraints[i], dt);
    //         }
    //     }
    // }

    fn solveConstraint(self: *Self, constraint: *Constraint, dt: f32) void {
        // Use cached dense indices for direct access
        if (constraint.dense_a == 0xFFFFFFFF or constraint.dense_b == 0xFFFFFFFF or
            constraint.dense_a >= self.particle_arena.getDenseCount() or
            constraint.dense_b >= self.particle_arena.getDenseCount())
        {
            return;
        }

        const particle_a = self.particle_arena.getDataAt(constraint.dense_a);
        const particle_b = self.particle_arena.getDataAt(constraint.dense_b);

        switch (constraint.type) {
            .distance => {
                const dx = particle_a.predicted_x - particle_b.predicted_x;
                const dy = particle_a.predicted_y - particle_b.predicted_y;
                const current_distance = @sqrt(dx * dx + dy * dy);

                if (current_distance < 0.001) return;

                const constraint_value = current_distance - constraint.target_value;

                const grad_x = dx / current_distance;
                const grad_y = dy / current_distance;

                const w_a = 1.0 / particle_a.mass;
                const w_b = 1.0 / particle_b.mass;
                const grad_length_sq = grad_x * grad_x + grad_y * grad_y;
                const denominator = w_a * grad_length_sq + w_b * grad_length_sq + constraint.compliance / (dt * dt);

                if (denominator < 0.001) return;

                const delta_lambda = -(constraint_value + constraint.compliance * constraint.lagrange_multiplier / (dt * dt)) / denominator;

                constraint.lagrange_multiplier += delta_lambda;

                const correction_a_x = w_a * delta_lambda * grad_x;
                const correction_a_y = w_a * delta_lambda * grad_y;
                const correction_b_x = -w_b * delta_lambda * grad_x;
                const correction_b_y = -w_b * delta_lambda * grad_y;

                particle_a.predicted_x += correction_a_x;
                particle_a.predicted_y += correction_a_y;
                particle_b.predicted_x += correction_b_x;
                particle_b.predicted_y += correction_b_y;
            },

            .collision => {
                const dx = particle_a.predicted_x - particle_b.predicted_x;
                const dy = particle_a.predicted_y - particle_b.predicted_y;
                const current_distance = @sqrt(dx * dx + dy * dy);

                if (current_distance < 0.001) {
                    particle_a.predicted_x += 0.01;
                    particle_b.predicted_x -= 0.01;
                    return;
                }

                const constraint_value = constraint.target_value - current_distance;

                if (constraint_value <= 0) return;

                const normal_x = dx / current_distance;
                const normal_y = dy / current_distance;

                const separation = constraint_value * 0.5;
                particle_a.predicted_x += normal_x * separation;
                particle_a.predicted_y += normal_y * separation;
                particle_b.predicted_x -= normal_x * separation;
                particle_b.predicted_y -= normal_y * separation;

                const rel_vx = particle_a.vx - particle_b.vx;
                const rel_vy = particle_a.vy - particle_b.vy;
                const rel_vel_normal = rel_vx * normal_x + rel_vy * normal_y;

                if (rel_vel_normal > 0) return;

                const restitution = 0.9;
                const impulse_magnitude = -(1.0 + restitution) * rel_vel_normal / (1.0 / particle_a.mass + 1.0 / particle_b.mass);

                const impulse_x = impulse_magnitude * normal_x;
                const impulse_y = impulse_magnitude * normal_y;

                particle_a.vx += impulse_x / particle_a.mass;
                particle_a.vy += impulse_y / particle_a.mass;
                particle_b.vx -= impulse_x / particle_b.mass;
                particle_b.vy -= impulse_y / particle_b.mass;
            },

        }
    }
};
