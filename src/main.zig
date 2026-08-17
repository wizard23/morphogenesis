const std = @import("std");
const math = std.math;
const spatial = @import("spatial.zig");
const reset_module = @import("reset.zig");
const generational = @import("generational.zig");
const mouse = @import("mouse.zig");
const physics = @import("physics.zig");
const perf = @import("perf.zig");
const host = @import("host.zig");
const log = host.log;

pub const GRID_COUNT = 3;
pub const GRID_PARTICLE_SIZE = 12;
pub const PARTICLES_PER_GRID = GRID_PARTICLE_SIZE * GRID_PARTICLE_SIZE;
pub const TOTAL_GRID_PARTICLES = GRID_COUNT * PARTICLES_PER_GRID;
pub const FREE_AGENT_COUNT = 500;
pub const EXTRA_PARTICLE_SLOTS = 10000;
pub const PARTICLE_COUNT = TOTAL_GRID_PARTICLES + FREE_AGENT_COUNT + EXTRA_PARTICLE_SLOTS;

pub const PARTICLE_SIZE = 5.0;
const PARTICLE_MASS = 1.0;
pub const WORLD_SIZE = 1.95;

var world_width: f32 = WORLD_SIZE;
var world_height: f32 = WORLD_SIZE;

const XPBD_ITERATIONS = 6;
// const XPBD_SUBSTEPS = 6;
var xpbd_iterations: u32 = XPBD_ITERATIONS; // runtime override for benchmarks (set_xpbd_iterations)

const DISTANCE_STIFFNESS = 1000_000_000.0;
const COLLISION_STIFFNESS = 1.0;
const MOUSE_STIFFNESS = 50000.0;

const AIR_DAMPING = 1.0;
const GRAVITY = 25.0;

pub const SPRING_REST_LENGTH = PARTICLE_SIZE * 3.1;
const SEPARATION_RADIUS = PARTICLE_SIZE * 1.5;
pub const GRID_SPACING = PARTICLE_SIZE * 2.8;

const SPRING_STRENGTH = DISTANCE_STIFFNESS;
const SEPARATION_STRENGTH = COLLISION_STIFFNESS;

const GRID_MAX_SPRINGS = GRID_COUNT * PARTICLES_PER_GRID * 4;
const USER_ADDED_MAX_SPRINGS = EXTRA_PARTICLE_SLOTS * 2;
pub const MAX_SPRINGS = GRID_MAX_SPRINGS + USER_ADDED_MAX_SPRINGS;

pub const ParticleArena = generational.GenerationalArena(Particle, PARTICLE_COUNT);
pub const SpringArena = generational.GenerationalArena(Spring, MAX_SPRINGS);

pub const ParticleHandle = ParticleArena.Handle;
pub const SpringHandle = SpringArena.Handle;

pub const Particle = struct {
    x: f32,
    y: f32,
    predicted_x: f32,
    predicted_y: f32,
    vx: f32,
    vy: f32,
    mass: f32,
    grid_id: u8,
    desired_valence: u8,
    current_valence: u8,

    const Self = @This();

    pub fn init(x: f32, y: f32, grid: u8) Self {
        return Self{
            .x = x,
            .y = y,
            .predicted_x = x,
            .predicted_y = y,
            .vx = (x * 0.1),
            .vy = (y * 0.1),
            .mass = PARTICLE_MASS,
            .grid_id = grid,
            .desired_valence = 2,
            .current_valence = 0,
        };
    }

    pub fn initWithValence(x: f32, y: f32, grid: u8, valence: u8) Self {
        return Self{
            .x = x,
            .y = y,
            .predicted_x = x,
            .predicted_y = y,
            .vx = (x * 0.1),
            .vy = (y * 0.1),
            .mass = PARTICLE_MASS,
            .grid_id = grid,
            .desired_valence = valence,
            .current_valence = 0,
        };
    }

    pub fn predictPosition(self: *Self, dt: f32) void {
        self.vy -= GRAVITY * dt;

        self.vx *= AIR_DAMPING;
        self.vy *= AIR_DAMPING;

        self.predicted_x = self.x + self.vx * dt;
        self.predicted_y = self.y + self.vy * dt;

        const border_x = world_width / 2.0;
        const border_y = world_height / 2.0;
        if (self.predicted_x > border_x) {
            self.predicted_x = border_x;
            self.vx *= -0.8;
        }
        if (self.predicted_x < -border_x) {
            self.predicted_x = -border_x;
            self.vx *= -0.8;
        }
        if (self.predicted_y > border_y) {
            self.predicted_y = border_y;
            self.vy *= -0.8;
        }
        if (self.predicted_y < -border_y) {
            self.predicted_y = -border_y;
            self.vy *= -0.8;
        }
    }

    pub fn updateFromPrediction(self: *Self, dt: f32) void {
        self.vx = (self.predicted_x - self.x) / dt;
        self.vy = (self.predicted_y - self.y) / dt;

        self.x = self.predicted_x;
        self.y = self.predicted_y;
    }

    pub fn applyBoundaryConstraints(self: *Self) void {
        const border_x = world_width / 2.0;
        const border_y = world_height / 2.0;

        if (self.predicted_x > border_x) {
            self.predicted_x = border_x;
        }
        if (self.predicted_x < -border_x) {
            self.predicted_x = -border_x;
        }
        if (self.predicted_y > border_y) {
            self.predicted_y = border_y;
        }
        if (self.predicted_y < -border_y) {
            self.predicted_y = -border_y;
        }
    }
};

pub const Spring = struct {
    particle_a: ParticleHandle,
    particle_b: ParticleHandle,
    rest_length: f32,

    pub fn init(particle_a: ParticleHandle, particle_b: ParticleHandle, rest_length: f32) Spring {
        return Spring{
            .particle_a = particle_a,
            .particle_b = particle_b,
            .rest_length = rest_length,
        };
    }
};

const MAX_CONSTRAINTS = MAX_SPRINGS + 50000; // Distance + collision constraints
var constraints: [MAX_CONSTRAINTS]physics.Constraint = undefined;

var particle_arena: generational.GenerationalArena(Particle, PARTICLE_COUNT) = undefined;
var particles_initialized = false;

var spring_arena: generational.GenerationalArena(Spring, MAX_SPRINGS) = undefined;
var springs_initialized = false;

pub const MAX_CONNECTIONS_PER_PARTICLE = 6;
var particle_connections: [PARTICLE_COUNT][MAX_CONNECTIONS_PER_PARTICLE]SpringHandle = undefined;
var particle_connection_counts: [PARTICLE_COUNT]u8 = undefined;

var particle_bulk_buffer: [PARTICLE_COUNT * 4]f32 = undefined;
var spring_bulk_buffer: [MAX_SPRINGS * 4]f32 = undefined;

var physics_system: physics.PhysicsSystem = undefined;

var device_handle: u32 = 0;

fn initializeParticleSystems() void {
    particle_arena.init();
}

fn initializeSpringSystems() void {
    spring_arena.init();
}

fn initializePhysicsSystem() void {
    physics_system = physics.PhysicsSystem.init(
        &particle_arena,
        &spring_arena,
        &constraints,
    );
}

pub fn spawnParticle(particle: Particle) ParticleHandle {
    return particle_arena.spawn(particle);
}

pub fn destroyParticle(handle: ParticleHandle) void {
    particle_arena.destroy(handle);
    if (handle.index < PARTICLE_COUNT) {
        particle_connection_counts[handle.index] = 0;
    }
}

pub fn getParticlePtr(handle: ParticleHandle) ?*Particle {
    return particle_arena.getMut(handle);
}

pub fn getParticle(handle: ParticleHandle) ?Particle {
    if (particle_arena.get(handle)) |particle| {
        return particle.*;
    }
    return null;
}

pub fn spawnSpring(spring: Spring) SpringHandle {
    return spring_arena.spawn(spring);
}

pub fn destroySpring(handle: SpringHandle) void {
    spring_arena.destroy(handle);
}

pub fn getSpringPtr(handle: SpringHandle) ?*Spring {
    return spring_arena.getMut(handle);
}

pub fn getSpring(handle: SpringHandle) ?Spring {
    if (spring_arena.get(handle)) |spring| {
        return spring.*;
    }
    return null;
}

fn predictPositionsForAliveParticles(dt: f32) void {
    const count = particle_arena.getDenseCount();
    for (0..count) |i| {
        const handle = particle_arena.getHandleAt(@intCast(i));
        if (mouse.isMouseParticle(handle)) {
            continue;
        }
        const particle = particle_arena.getDataAt(@intCast(i));
        particle.predictPosition(dt);
        if (perf.enabled) {
            const ddx = particle.predicted_x - particle.x;
            const ddy = particle.predicted_y - particle.y;
            perf.max(.max_step_disp_milli, @intFromFloat(@sqrt(ddx * ddx + ddy * ddy) * 1000.0));
        }
    }
}

fn updatePositionsForAliveParticles(dt: f32) void {
    const count = particle_arena.getDenseCount();
    for (0..count) |i| {
        const handle = particle_arena.getHandleAt(@intCast(i));
        if (mouse.isMouseParticle(handle)) {
            continue;
        }
        const particle = particle_arena.getDataAt(@intCast(i));
        particle.updateFromPrediction(dt);
    }
}

fn resetValenceForAliveParticles() void {
    const count = particle_arena.getDenseCount();
    for (0..count) |i| {
        const particle = particle_arena.getDataAt(@intCast(i));
        particle.current_valence = 0;
    }
}

fn countValenceFromAlivesprings() void {
    spring_arena.forEachDense(struct {
        fn countValence(spring_handle: SpringHandle, spring: *const Spring) void {
            _ = spring_handle;

            if (particle_arena.getMut(spring.particle_a)) |particle_a| {
                particle_a.current_valence += 1;
            }
            if (particle_arena.getMut(spring.particle_b)) |particle_b| {
                particle_b.current_valence += 1;
            }
        }
    }.countValence);
}

pub fn getParticleHandleByIndex(index: u32) ?ParticleHandle {
    if (index >= particle_arena.getDenseCount()) return null;
    return particle_arena.getHandleAt(index);
}

pub fn getParticleByIndex(index: u32) ?Particle {
    if (index >= particle_arena.getDenseCount()) return null;
    return particle_arena.getDataAt(index).*;
}

pub fn findClosestParticleIndex(target_x: f32, target_y: f32) u32 {
    var closest_index: u32 = 0;
    var closest_distance_sq: f32 = std.math.inf(f32);

    const dense_count = particle_arena.getDenseCount();
    for (0..dense_count) |i| {
        const particle = particle_arena.getDataAt(@intCast(i));
        const dx = target_x - particle.x;
        const dy = target_y - particle.y;
        const distance_sq = dx * dx + dy * dy;

        if (distance_sq < closest_distance_sq) {
            closest_distance_sq = distance_sq;
            closest_index = @intCast(i);
        }
    }

    return closest_index;
}

// Dense-order accessors (iteration detail; valid until the next spawn/destroy)
pub fn getDenseParticleCount() u32 {
    return particle_arena.getDenseCount();
}

pub fn getDenseParticleAt(index: u32) *const Particle {
    return particle_arena.getDataAt(index);
}

pub fn getDenseSpringCount() u32 {
    return spring_arena.getDenseCount();
}

pub fn getDenseSpringAt(index: u32) *const Spring {
    return spring_arena.getDataAt(index);
}

pub fn getSpringCount() u32 {
    return spring_arena.getAliveCount();
}

pub fn getAliveParticleCount() u32 {
    return particle_arena.getAliveCount();
}

pub fn clearConnectionTable() void {
    @memset(&particle_connection_counts, 0);
}

/// Drop dead spring handles from a particle's connection table (springs destroyed for overstretch
/// are not removed eagerly). Returns the live count.
fn compactConnections(particle_index: u32) u8 {
    var count = particle_connection_counts[particle_index];
    var k: u8 = 0;
    while (k < count) {
        if (spring_arena.get(particle_connections[particle_index][k]) != null) {
            k += 1;
        } else {
            count -= 1;
            particle_connections[particle_index][k] = particle_connections[particle_index][count];
        }
    }
    particle_connection_counts[particle_index] = count;
    return count;
}

/// Is there a live spring between a and b? Checks a's connection table (compacting it).
fn isConnected(a: ParticleHandle, b: ParticleHandle) bool {
    const count = compactConnections(a.index);
    for (0..count) |k| {
        const spring = spring_arena.get(particle_connections[a.index][k]) orelse continue;
        if ((spring.particle_a.eql(a) and spring.particle_b.eql(b)) or
            (spring.particle_a.eql(b) and spring.particle_b.eql(a))) return true;
    }
    return false;
}

fn recordConnection(particle_index: u32, spring_handle: SpringHandle) void {
    var count = particle_connection_counts[particle_index];
    if (count >= MAX_CONNECTIONS_PER_PARTICLE) count = compactConnections(particle_index);
    if (count < MAX_CONNECTIONS_PER_PARTICLE) {
        particle_connections[particle_index][count] = spring_handle;
        particle_connection_counts[particle_index] = count + 1;
    }
}

/// Form valence bonds between unsatisfied particles at ~rest length. Candidates come from the
/// spatial grid (populated here from current positions); a pair is considered once, owned by the
/// lower dense index. Visit order: dense order of the owner, then the 3×3 cells (dy, dx ascending),
/// then cell insertion (dense) order — deterministic, see docs/principles/determinism.md.
fn updateValenceBonds() void {
    spatial.populateGridArena(&particle_arena, .current);
    const dense_particle_count = particle_arena.getDenseCount();
    const min_bond_distance_sq = (SPRING_REST_LENGTH * 0.9) * (SPRING_REST_LENGTH * 0.9);
    const max_bond_distance_sq = (SPRING_REST_LENGTH * 1.1) * (SPRING_REST_LENGTH * 1.1);

    for (0..dense_particle_count) |i| {
        const particle_a = particle_arena.getDataAt(@intCast(i));
        if (particle_a.current_valence >= particle_a.desired_valence) continue;
        const handle_a = particle_arena.getHandleAt(@intCast(i));

        const gx = spatial.worldToGridX(particle_a.x);
        const gy = spatial.worldToGridY(particle_a.y);

        var dy: i32 = -1;
        outer: while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const cx = gx + dx;
                const cy = gy + dy;
                if (cx < 0 or cy < 0 or cx >= @as(i32, @intCast(spatial.grid_size_x)) or cy >= @as(i32, @intCast(spatial.grid_size_y))) continue;
                const cell = spatial.getGridCellByCoords(@intCast(cx), @intCast(cy));

                for (0..cell.count) |k| {
                    const j = cell.idx[k];
                    if (j <= i) continue;

                    // distance first, from the cell's own coordinates (current positions)
                    const ddx = cell.x[k] - particle_a.x;
                    const ddy = cell.y[k] - particle_a.y;
                    const distance_sq = ddx * ddx + ddy * ddy;
                    if (distance_sq < min_bond_distance_sq or distance_sq > max_bond_distance_sq) continue;

                    const particle_b = particle_arena.getDataAt(j);
                    if (particle_b.current_valence >= particle_b.desired_valence) continue;

                    const handle_b = particle_arena.getHandleAt(j);
                    if (isConnected(handle_a, handle_b)) continue;
                    if (spring_arena.getAliveCount() >= MAX_SPRINGS) return;

                    const spring_handle = spawnSpring(Spring{
                        .particle_a = handle_a,
                        .particle_b = handle_b,
                        .rest_length = SPRING_REST_LENGTH,
                    });
                    if (!spring_handle.isValid()) return;
                    perf.count(.bonds_formed, 1);
                    recordConnection(handle_a.index, spring_handle);
                    recordConnection(handle_b.index, spring_handle);
                    particle_a.current_valence += 1;
                    particle_b.current_valence += 1;
                    if (particle_a.current_valence >= particle_a.desired_valence) break :outer;
                }
            }
        }
    }
}

fn initializeValenceCounts() void {
    resetValenceForAliveParticles();
    countValenceFromAlivesprings();
}

pub export fn init() void {
    log("Initializing enhanced particle system: {} grids + {} free agents...", .{ GRID_COUNT, FREE_AGENT_COUNT });
    device_handle = host.emscripten_webgpu_get_device();
    log("WebGPU device initialized: {}", .{device_handle});

    spatial.initializeGrid();

    if (!particles_initialized) {
        initializeParticleSystems();
        initializeSpringSystems();
        initializePhysicsSystem();
        reset_module.initializeGridParticles();
        reset_module.initializeFreeAgents();
        particles_initialized = true;
        log("Initialized {} total particles: {} grid + {} free agents", .{ PARTICLE_COUNT, TOTAL_GRID_PARTICLES, FREE_AGENT_COUNT });
    }

    if (!springs_initialized) {
        reset_module.initializeSprings();
        springs_initialized = true;
        log("Created {} spring connections for {} grids", .{ getSpringCount(), GRID_COUNT });
    }

    mouse.initMouseSystem();
    log("Mouse interaction system initialized", .{});
}

pub export fn reset() void {
    log("Resetting particle system...", .{});

    initializeParticleSystems();
    initializeSpringSystems();
    initializePhysicsSystem();

    reset_module.initializeGridParticles();
    reset_module.initializeFreeAgents();
    reset_module.initializeSprings();

    // After the arenas exist: the mouse particle must live in the *new* arena. (Spawning it before
    // the re-init left a stale handle that could later alias a painted particle — history-dependent
    // physics, found by the harness 2026-08-17.)
    mouse.initMouseSystem();

    initializeValenceCounts();

    log("Particle system reset complete", .{});
}

pub export fn update_particles(dt: f32) void {
    const microDt = dt / @as(f32, @floatFromInt(xpbd_iterations));
    if (!particles_initialized) return;

    perf.beginFrame();

    var t0 = perf.now();
    predictPositionsForAliveParticles(dt);
    perf.add(.predict, t0);

    t0 = perf.now();
    mouse.updateMousePhysics();
    perf.add(.mouse, t0);

    t0 = perf.now();
    updateValenceBonds();
    perf.add(.bonds, t0);

    // Use physics system to generate and solve constraints
    for (0..xpbd_iterations) |_| {
        physics_system.generateConstraints(
            microDt,
            DISTANCE_STIFFNESS,
            COLLISION_STIFFNESS,
        );
        t0 = perf.now();
        physics_system.solveConstraints(microDt);
        perf.add(.solve, t0);
        perf.count(.iterations, 1);
    }

    t0 = perf.now();
    updatePositionsForAliveParticles(dt);
    perf.add(.commit, t0);

    perf.endFrame();
}

/// Test oracle: from the current state, generate constraints once and count collision pairs the
/// spatial scan produced vs a brute-force O(n²) count over predicted positions (mouse excluded).
pub const CollisionPairCounts = struct { grid: u32, brute: u32 };
pub fn collisionPairCountsForTest(dt: f32) CollisionPairCounts {
    physics_system.generateConstraints(dt, DISTANCE_STIFFNESS, COLLISION_STIFFNESS);
    var grid: u32 = 0;
    for (0..physics_system.constraint_count) |c| {
        if (constraints[c].type == .collision) grid += 1;
    }
    var brute: u32 = 0;
    const n = particle_arena.getDenseCount();
    const contact = PARTICLE_SIZE * 2.0;
    for (0..n) |i| {
        if (mouse.isMouseParticle(particle_arena.getHandleAt(@intCast(i)))) continue;
        const a = particle_arena.getDataAt(@intCast(i));
        for ((i + 1)..n) |j| {
            if (mouse.isMouseParticle(particle_arena.getHandleAt(@intCast(j)))) continue;
            const b = particle_arena.getDataAt(@intCast(j));
            const dx = a.predicted_x - b.predicted_x;
            const dy = a.predicted_y - b.predicted_y;
            if (@sqrt(dx * dx + dy * dy) < contact) brute += 1;
        }
    }
    return .{ .grid = grid, .brute = brute };
}

/// Benchmark hook: override the XPBD iteration count (clamped to ≥ 1).
export fn set_xpbd_iterations(n: u32) void {
    xpbd_iterations = @max(1, n);
}

export fn get_xpbd_iterations() u32 {
    return xpbd_iterations;
}

export fn get_particle_count() i32 {
    return PARTICLE_COUNT;
}

export fn get_world_size() f32 {
    return WORLD_SIZE;
}

pub export fn get_world_width() f32 {
    return world_width;
}

pub export fn get_world_height() f32 {
    return world_height;
}

pub export fn set_world_dimensions(width: f32, height: f32) void {
    world_width = width;
    world_height = height;
    spatial.updateGridDimensions();
    log("World dimensions updated: {d:.2} x {d:.2}", .{ world_width, world_height });
}

export fn get_grid_size() i32 {
    return @as(i32, @intCast(@max(spatial.grid_size_x, spatial.grid_size_y)));
}

export fn get_grid_dimensions_x() i32 {
    return @as(i32, @intCast(spatial.grid_size_x));
}

export fn get_grid_dimensions_y() i32 {
    return @as(i32, @intCast(spatial.grid_size_y));
}

export fn get_world_width_debug() f32 {
    return world_width;
}

export fn get_world_height_debug() f32 {
    return world_height;
}

export fn get_max_particles() i32 {
    return PARTICLE_COUNT + 1000;
}

export fn get_spatial_max_occupancy() i32 {
    return @as(i32, @intCast(spatial.getMaxOccupancy()));
}

export fn get_spatial_cell_capacity() i32 {
    return spatial.MAX_PARTICLES_PER_CELL;
}

/// Particles dropped from a full spatial cell in the last grid population (must be 0).
export fn get_spatial_overflow_count() i32 {
    return @as(i32, @intCast(spatial.getOverflowCount()));
}

export fn get_max_springs() i32 {
    return MAX_SPRINGS;
}

export fn get_particle_size() f32 {
    return PARTICLE_SIZE;
}

export fn get_spring_count() i32 {
    return @intCast(getSpringCount());
}

export fn get_spring_particle_a(spring_index: i32) i32 {
    if (spring_index < 0) return -1;

    const current_spring_index: i32 = 0;
    _ = current_spring_index;
    return -1;
}

export fn get_spring_particle_b(spring_index: i32) i32 {
    _ = spring_index;
    return -1;
}

export fn get_particle_data(index: i32) f32 {
    if (!particles_initialized or index < 0 or index >= @as(i32, @intCast(getAliveParticleCount())) * 2) {
        return 0.0;
    }

    const particle_index = @divFloor(@as(usize, @intCast(index)), 2);
    const coord_index = @mod(@as(usize, @intCast(index)), 2);

    _ = particle_index;
    _ = coord_index;
    return 0.0;
}

export fn get_particle_valence(particle_index: i32) i32 {
    _ = particle_index;
    return 0;
}

export fn get_particle_current_valence(particle_index: i32) i32 {
    _ = particle_index;
    return 0;
}

pub export fn add_particle(x: f32, y: f32, valence: u32) void {
    if (!particles_initialized) return;

    if (particle_arena.getAliveCount() >= PARTICLE_COUNT) {
        log("Cannot add more particles - reached limit of {}", .{PARTICLE_COUNT});
        return;
    }

    const new_particle = Particle.initWithValence(x, y, 255, @intCast(valence));
    const handle = spawnParticle(new_particle);

    if (!handle.isValid()) {
        log("Failed to spawn particle", .{});
        return;
    }
}

export fn destroy_particle_by_index(particle_index: i32) void {
    _ = particle_index;
}

pub export fn get_alive_particle_count() i32 {
    return @intCast(getAliveParticleCount());
}

export fn get_alive_spring_count() i32 {
    return @intCast(getSpringCount());
}

export fn get_particle_data_bulk() [*]f32 {
    const dense_particle_count = particle_arena.getDenseCount();
    var write_index: u32 = 0;
    for (0..dense_particle_count) |i| {
        const particle = particle_arena.getDataAt(@intCast(i));

        if (write_index + 3 < PARTICLE_COUNT * 4) {
            particle_bulk_buffer[write_index] = particle.x;
            particle_bulk_buffer[write_index + 1] = particle.y;
            particle_bulk_buffer[write_index + 2] = @floatFromInt(particle.desired_valence);
            particle_bulk_buffer[write_index + 3] = @floatFromInt(particle.current_valence);
            write_index += 4;
        }
    }

    return &particle_bulk_buffer;
}

export fn get_spring_data_bulk() [*]f32 {
    const spring_count = spring_arena.getDenseCount();
    var write_index: u32 = 0;

    for (0..spring_count) |i| {
        const spring = spring_arena.getDataAt(@intCast(i));

        const particle_a = particle_arena.getMut(spring.particle_a);
        const particle_b = particle_arena.getMut(spring.particle_b);

        if (particle_a != null and particle_b != null and write_index + 3 < MAX_SPRINGS * 4) {
            spring_bulk_buffer[write_index] = particle_a.?.x;
            spring_bulk_buffer[write_index + 1] = particle_a.?.y;
            spring_bulk_buffer[write_index + 2] = particle_b.?.x;
            spring_bulk_buffer[write_index + 3] = particle_b.?.y;
            write_index += 4;
        }
    }

    return &spring_bulk_buffer;
}

export fn get_bulk_particle_count() i32 {
    return @intCast(particle_arena.getDenseCount());
}

export fn get_bulk_spring_count() i32 {
    return @intCast(getSpringCount());
}

pub export fn set_mouse_interaction(x: f32, y: f32, pressed: bool) void {
    mouse.updateMousePosition(x, y);
    mouse.setMousePressed(pressed);
}

/// Dense index of the first grabbed particle (matches the order of get_particle_data_bulk), or -1.
export fn get_mouse_connected_particle() i32 {
    if (mouse.getGrabbedParticle(0)) |handle| {
        if (particle_arena.getDenseIndex(handle)) |dense| return @intCast(dense);
    }
    return -1;
}

export fn get_mouse_position_x() f32 {
    return mouse.getMousePositionX();
}

export fn get_mouse_position_y() f32 {
    return mouse.getMousePositionY();
}

pub export fn get_mouse_grab_count() i32 {
    return @intCast(mouse.getGrabCount());
}

export fn is_mouse_pressed() bool {
    return mouse.isMousePressed();
}
