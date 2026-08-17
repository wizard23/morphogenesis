const std = @import("std");
const spatial = @import("spatial.zig");
const mouse = @import("mouse.zig");
const main = @import("main.zig");
const perf = @import("perf.zig");

pub const Vec2 = struct {
    x: f32,
    y: f32,
};

const ParticleHandle = main.ParticleHandle;
const SpringHandle = main.SpringHandle;
const Particle = main.Particle;
const Spring = main.Spring;
const MAX_SPRINGS = main.MAX_SPRINGS;
const PARTICLE_SIZE = main.PARTICLE_SIZE;
const PARTICLE_COUNT = main.PARTICLE_COUNT;

// Unified constraint type to reduce code duplication
pub const ConstraintType = enum {
    distance,
    collision,
    separation,
    alignment,
    cohesion,
    mouse_spring,
};

pub const Constraint = struct {
    type: ConstraintType,
    particle_a: ParticleHandle,
    particle_b: ParticleHandle,

    // Cached dense indices for fast access
    dense_a: u32,
    dense_b: u32,

    // Constraint parameters
    target_value: f32, // rest_length for distance, min_distance for collision, etc.
    compliance: f32,
    lagrange_multiplier: f32,

    // Additional data for complex constraints
    aux_data: union {
        none: void,
        cohesion_target: Vec2,
        alignment_neighbors: struct {
            handles: [16]ParticleHandle,
            count: u32,
        },
    },

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
            .aux_data = .{ .none = {} },
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
            .aux_data = .{ .none = {} },
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

                        // Refund valence
                        particle_a.?.current_valence = @max(0, particle_a.?.current_valence - 1);
                        particle_b.?.current_valence = @max(0, particle_b.?.current_valence - 1);
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

        // Create a temporary array for spatial grid population
        var temp_particles: [main.PARTICLE_COUNT]Particle = undefined;
        self.particle_arena.fillDenseArray(temp_particles[0..particle_count]);
        spatial.populateGrid(temp_particles[0..particle_count], particle_count);
        perf.max(.bin_max, spatial.getMaxOccupancy());
        perf.add(.gen_grid, t0);

        t0 = perf.now();
        for (0..particle_count) |i| {
            const handle = self.particle_arena.getHandleAt(@intCast(i));
            if (!mouse.isMouseParticle(handle)) {
                self.generateCollisionConstraintsForParticle(handle, @intCast(i), dt, collision_stiffness);
            }
        }
        perf.count(.collision_pairs, self.constraint_count - spring_constraint_count);
        perf.count(.constraints, self.constraint_count);
        perf.add(.gen_collide, t0);
    }

    fn generateCollisionConstraintsForParticle(
        self: *Self,
        particle_handle: ParticleHandle,
        particle_dense_idx: u32,
        dt: f32,
        collision_stiffness: f32,
    ) void {
        const particle = self.particle_arena.getDataAt(particle_dense_idx);

        // Use current position for spatial lookup (since that's what was populated)
        const gx = spatial.worldToGridX(particle.x);
        const gy = spatial.worldToGridY(particle.y);

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
                        const neighbor_index = cell.particles[i];

                        if (neighbor_index >= self.particle_arena.getDenseCount()) continue;
                        const neighbor_handle = self.particle_arena.getHandleAt(neighbor_index);

                        if (!neighbor_handle.eql(particle_handle) and
                            particle_handle.index < neighbor_handle.index and
                            !mouse.isMouseParticle(neighbor_handle))
                        {
                            const other = self.particle_arena.getDataAt(neighbor_index);
                            const dx_pred = particle.predicted_x - other.predicted_x;
                            const dy_pred = particle.predicted_y - other.predicted_y;
                            const dist_sq = dx_pred * dx_pred + dy_pred * dy_pred;

                            const ball_radius = PARTICLE_SIZE;
                            const contact_distance = ball_radius * 2.0;
                            const current_distance = @sqrt(dist_sq);

                            if (current_distance < contact_distance) {
                                if (self.constraint_count < self.constraints.len) {
                                    const billiard_stiffness = collision_stiffness * 10.0;

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
            .distance, .mouse_spring => {
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

            else => {},
        }
    }
};
