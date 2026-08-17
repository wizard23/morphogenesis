const std = @import("std");

// Pre-calculated constants for worldToGrid optimization
const main_module = @import("main.zig");
const BASE_WORLD_SIZE = main_module.WORLD_SIZE;

// Spatial partitioning grid for O(n) performance.
// Bin size in particle diameters. A 3×3 scan finds every pair closer than (bin − per-step
// displacement); contact is 1 diameter and the measured displacement is ≤ 0.4 diameter at ≥ 3 XPBD
// iterations, so 2 diameters is the smallest safe bin (slice 2, 2026-08-17; was 6, then 3).
// Larger query radii (mouse grab, 2.5 diameters) widen their scan instead: see GRAB_SEARCH_CELLS.
pub const BIN_SIZE_PIXELS = 2.0 * (2.0 * main_module.PARTICLE_SIZE);
/// Effective bin size: BIN_SIZE_PIXELS, or larger when the world would need more than MAX_GRID_SIZE
/// bins per axis (large screens) — bigger cells stay exhaustive, clamping to the edge cell would not.
pub var bin_size: f32 = BIN_SIZE_PIXELS;
/// Cells a query of radius r must scan on each side: ceil(r / bin).
pub fn cellsForRadius(radius: f32) i32 {
    return @intFromFloat(@ceil(radius / bin_size));
}
// Physical maximum for 20 px cells and 10 px particles is ~4–7 (measured max 14 at 30 px / 6
// iterations, 35 at 1 iteration where the solver leaves overlaps). Overflow is counted
// (`overflow_count`) and gated in bench/sim-assert; it must be 0.
pub const MAX_PARTICLES_PER_CELL = 24;

// Dynamic grid size based on world dimensions and fixed bin size
pub var grid_size_x: u32 = 0;
pub var grid_size_y: u32 = 0;

// Spatial grid cell: SoA of dense index + the coordinates the grid was populated with, so a
// neighbourhood scan is a sequential sweep over cell memory and the arena is touched only on a hit.
pub const GridCell = struct {
    idx: [MAX_PARTICLES_PER_CELL]u32,
    x: [MAX_PARTICLES_PER_CELL]f32,
    y: [MAX_PARTICLES_PER_CELL]f32,
    count: u32,

    const Self = @This();

    pub fn init() Self {
        return Self{ .idx = undefined, .x = undefined, .y = undefined, .count = 0 };
    }

    pub fn clear(self: *Self) void {
        self.count = 0;
    }

    pub fn add(self: *Self, dense_index: u32, px: f32, py: f32) void {
        if (self.count < MAX_PARTICLES_PER_CELL) {
            self.idx[self.count] = dense_index;
            self.x[self.count] = px;
            self.y[self.count] = py;
            self.count += 1;
        } else {
            overflow_count += 1;
        }
    }
};

// Maximum grid dimensions (for static allocation)
const MAX_GRID_SIZE = 100;
const MAX_GRID_CELLS = MAX_GRID_SIZE * MAX_GRID_SIZE;

// Flat spatial grid for better cache locality
pub var spatial_grid: [MAX_GRID_CELLS]GridCell = undefined;
var grid_initialized = false;
var max_occupancy: u32 = 0;
/// Particles dropped because their cell was full (since the last clearGrid). Missed collisions.
var overflow_count: u32 = 0;

// Helper to convert 2D coords to flat index
inline fn gridIndex(x: u32, y: u32) u32 {
    return y * grid_size_x + x;
}

// Spatial grid helper functions with fixed bin size
pub inline fn worldToGridX(world_x: f32) i32 {
    const world_width = main_module.get_world_width();
    const world_half_x = world_width / 2.0;
    const grid_pos = @as(i32, @intFromFloat((world_x + world_half_x) / bin_size));
    return @max(0, @min(@as(i32, @intCast(grid_size_x)) - 1, grid_pos));
}

pub inline fn worldToGridY(world_y: f32) i32 {
    const world_height = main_module.get_world_height();
    const world_half_y = world_height / 2.0;
    const grid_pos = @as(i32, @intFromFloat((world_y + world_half_y) / bin_size));
    return @max(0, @min(@as(i32, @intCast(grid_size_y)) - 1, grid_pos));
}

pub fn getGridCell(x: f32, y: f32) *GridCell {
    const gx = worldToGridX(x);
    const gy = worldToGridY(y);
    const idx = gridIndex(@intCast(gx), @intCast(gy));
    return &spatial_grid[idx];
}

pub fn getGridCellByCoords(gx: u32, gy: u32) *GridCell {
    const idx = gridIndex(gx, gy);
    return &spatial_grid[idx];
}

pub fn updateGridDimensions() void {
    // Calculate grid dimensions based on world size and fixed bin size
    const world_width = main_module.get_world_width();
    const world_height = main_module.get_world_height();

    // Grow the bin instead of clamping the grid: every world position must map to a distinct cell.
    const largest = @max(world_width, world_height);
    bin_size = @max(BIN_SIZE_PIXELS, largest / @as(f32, @floatFromInt(MAX_GRID_SIZE - 1)));
    grid_size_x = @min(MAX_GRID_SIZE, @max(1, @as(u32, @intFromFloat(world_width / bin_size)) + 1));
    grid_size_y = @min(MAX_GRID_SIZE, @max(1, @as(u32, @intFromFloat(world_height / bin_size)) + 1));
}

pub fn initializeGrid() void {
    if (!grid_initialized) {
        updateGridDimensions();

        // Initialize only the cells we'll actually use
        const total_cells = grid_size_x * grid_size_y;
        for (0..total_cells) |i| {
            spatial_grid[i] = GridCell.init();
        }
        grid_initialized = true;
    }
}

pub fn clearGrid() void {
    max_occupancy = 0;
    overflow_count = 0;
    const total_cells = grid_size_x * grid_size_y;
    for (0..total_cells) |i| {
        spatial_grid[i].clear();
    }
}

/// Which particle coordinates populate the grid: the committed position (bonding, mouse grab) or the
/// predicted position (collision detection runs on predictions).
pub const Positions = enum { current, predicted };

/// Populate directly from the particle arena's dense storage (no intermediate copy).
pub fn populateGridArena(arena: *main_module.ParticleArena, comptime which: Positions) void {
    clearGrid();
    const count = arena.getDenseCount();
    for (0..count) |i| {
        const particle = arena.getDataAt(@intCast(i));
        const px = if (which == .predicted) particle.predicted_x else particle.x;
        const py = if (which == .predicted) particle.predicted_y else particle.y;
        const cell = getGridCell(px, py);
        cell.add(@intCast(i), px, py);
        if (cell.count > max_occupancy) {
            max_occupancy = cell.count;
        }
    }
}

// Get current maximum bin occupancy
pub fn getMaxOccupancy() u32 {
    return max_occupancy;
}

pub fn getOverflowCount() u32 {
    return overflow_count;
}

// Get grid dimensions
pub fn getGridDimensions() struct { x: u32, y: u32 } {
    return .{ .x = grid_size_x, .y = grid_size_y };
}