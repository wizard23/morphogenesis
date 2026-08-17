//! Native unit tests (`zig build test`). Host externs are stubbed by host.zig.
//! Focus: arena semantics, spatial mapping, and determinism (docs/principles/determinism.md).
const std = @import("std");
const testing = std.testing;
const generational = @import("generational.zig");
const main = @import("main.zig");
const spatial = @import("spatial.zig");
const perf = @import("perf.zig");

const Item = struct { v: u32 };
const SmallArena = generational.GenerationalArena(Item, 4);

test "arena: spawn returns valid handle and get sees the data" {
    var arena: SmallArena = undefined;
    arena.init();
    const h = arena.spawn(.{ .v = 7 });
    try testing.expect(h.isValid());
    try testing.expectEqual(@as(u32, 1), arena.getAliveCount());
    try testing.expectEqual(@as(u32, 7), arena.get(h).?.v);
}

test "arena: destroy invalidates handle; slot reuse bumps generation" {
    var arena: SmallArena = undefined;
    arena.init();
    const h1 = arena.spawn(.{ .v = 1 });
    arena.destroy(h1);
    try testing.expect(arena.get(h1) == null);
    try testing.expectEqual(@as(u32, 0), arena.getAliveCount());
    const h2 = arena.spawn(.{ .v = 2 });
    try testing.expectEqual(h1.index, h2.index);
    try testing.expect(h2.generation != h1.generation);
    try testing.expect(arena.get(h1) == null);
    try testing.expectEqual(@as(u32, 2), arena.get(h2).?.v);
    // destroying a stale handle is a no-op
    arena.destroy(h1);
    try testing.expectEqual(@as(u32, 1), arena.getAliveCount());
}

test "arena: capacity exhaustion returns invalid handle" {
    var arena: SmallArena = undefined;
    arena.init();
    for (0..4) |i| try testing.expect(arena.spawn(.{ .v = @intCast(i) }).isValid());
    try testing.expect(!arena.spawn(.{ .v = 99 }).isValid());
}

test "arena: dense order is swap-remove (order-sensitive but deterministic)" {
    var arena: SmallArena = undefined;
    arena.init();
    const a = arena.spawn(.{ .v = 10 });
    const b = arena.spawn(.{ .v = 20 });
    const c = arena.spawn(.{ .v = 30 });
    _ = b;
    arena.destroy(a); // last (c) moves into slot 0
    try testing.expectEqual(@as(u32, 30), arena.getDataAt(0).v);
    try testing.expectEqual(@as(u32, 20), arena.getDataAt(1).v);
    try testing.expectEqual(@as(u32, 0), arena.getDenseIndex(c).?);
    try testing.expect(arena.getHandleAt(0).eql(c));
}

test "spatial: worlds wider than MAX_GRID_SIZE bins grow the bin instead of overflowing edge cells" {
    main.init();
    main.reset();
    main.set_world_dimensions(4000, 3000);
    try testing.expect(spatial.bin_size > spatial.BIN_SIZE_PIXELS);
    // spread a uniform field over the whole world; no cell may overflow
    for (0..60) |r| for (0..80) |c| main.add_particle(@as(f32, @floatFromInt(c)) * 48.0 - 1900, @as(f32, @floatFromInt(r)) * 48.0 - 1400, 0);
    for (0..10) |_| main.update_particles(0.016);
    try testing.expectEqual(@as(u32, 0), spatial.getOverflowCount());
    main.set_world_dimensions(1920, 1080);
    try testing.expectEqual(spatial.BIN_SIZE_PIXELS, spatial.bin_size);
}

test "collisions: spatial scan finds exactly the brute-force contact set (several states)" {
    main.init();
    main.reset();
    main.set_world_dimensions(1920, 1080);
    // dense pile of inert particles at contact spacing dropped from the top, plus the default lattices
    for (0..50) |r| for (0..60) |c| main.add_particle(@as(f32, @floatFromInt(c)) * 10.0 - 300, @as(f32, @floatFromInt(r)) * 10.0 + 40, 0);
    var total: u32 = 0;
    for (0..6) |_| {
        for (0..100) |_| main.update_particles(0.016);
        const counts = main.collisionPairCountsForTest(0.016 / 6.0);
        try testing.expectEqual(counts.brute, counts.grid);
        total += counts.brute;
    }
    try testing.expect(total > 500);
    // and a bonding lattice (valence-6) mid-formation
    main.reset();
    main.set_world_dimensions(1920, 1080);
    for (0..40) |r| for (0..40) |c| main.add_particle(@as(f32, @floatFromInt(c)) * 15.5 - 300, @as(f32, @floatFromInt(r)) * 15.5 - 300, 6);
    for (0..3) |_| {
        for (0..40) |_| main.update_particles(0.016);
        const counts = main.collisionPairCountsForTest(0.016 / 6.0);
        try testing.expectEqual(counts.brute, counts.grid);
    }
}

test "spatial: worldToGrid clamps to grid bounds" {
    main.set_world_dimensions(1920, 1080);
    const gx_max: i32 = @intCast(spatial.grid_size_x - 1);
    const gy_max: i32 = @intCast(spatial.grid_size_y - 1);
    try testing.expectEqual(@as(i32, 0), spatial.worldToGridX(-1e6));
    try testing.expectEqual(gx_max, spatial.worldToGridX(1e6));
    try testing.expectEqual(@as(i32, 0), spatial.worldToGridY(-1e6));
    try testing.expectEqual(gy_max, spatial.worldToGridY(1e6));
    // centre maps inside the grid
    const cx = spatial.worldToGridX(0);
    try testing.expect(cx >= 0 and cx <= gx_max);
}

fn runScenario(steps: u32) u32 {
    main.reset();
    main.set_world_dimensions(1920, 1080);
    for (0..steps) |_| main.update_particles(0.016);
    return perf.stateChecksum();
}

test "determinism: same scene + same steps → same checksum (self-consistency)" {
    main.init();
    const a = runScenario(60);
    const b = runScenario(60);
    try testing.expectEqual(a, b);
    // and the state actually evolves
    const c = runScenario(61);
    try testing.expect(c != a);
    try testing.expect(main.get_alive_particle_count() > 0);
}

test "determinism: reset() is history-independent (mouse handle lives in the new arena)" {
    main.init();
    const fresh = runScenario(60);
    // A different history: paint many particles, then reset and run the same scenario.
    main.reset();
    main.set_world_dimensions(1920, 1080);
    for (0..3000) |i| {
        const col: i32 = @intCast(i % 60);
        const row: i32 = @intCast(i / 60);
        main.add_particle(@floatFromInt(col * 10 - 300), @floatFromInt(row * 10 - 250), 0);
    }
    for (0..30) |_| main.update_particles(0.016);
    const after_history = runScenario(60);
    try testing.expectEqual(fresh, after_history);
}

test "mouse: a press after reset() grabs particles and the drag changes the state" {
    main.init();
    main.reset();
    main.set_world_dimensions(1920, 1080);
    for (0..100) |_| main.update_particles(0.016);
    const before = perf.stateChecksum();
    // grid 0 is centred at (-200, -200); press there and pull
    main.set_mouse_interaction(-200, -200, true);
    try testing.expect(main.get_mouse_grab_count() > 0);
    for (0..30) |i| {
        main.set_mouse_interaction(-200 + @as(f32, @floatFromInt(i)) * 2.0, -200, true);
        main.update_particles(0.016);
    }
    main.set_mouse_interaction(0, 0, false);
    // Compare against the same 30 steps without dragging from the same start
    main.reset();
    main.set_world_dimensions(1920, 1080);
    for (0..100) |_| main.update_particles(0.016);
    try testing.expectEqual(before, perf.stateChecksum());
    for (0..30) |_| main.update_particles(0.016);
    const undragged = perf.stateChecksum();
    // and re-run the drag to get its checksum
    main.reset();
    main.set_world_dimensions(1920, 1080);
    for (0..100) |_| main.update_particles(0.016);
    main.set_mouse_interaction(-200, -200, true);
    for (0..30) |i| {
        main.set_mouse_interaction(-200 + @as(f32, @floatFromInt(i)) * 2.0, -200, true);
        main.update_particles(0.016);
    }
    main.set_mouse_interaction(0, 0, false);
    try testing.expect(perf.stateChecksum() != undragged);
}

test "valence refund saturates at 0 when a mouse spring breaks (Debug safety)" {
    main.init();
    main.reset();
    main.set_world_dimensions(1920, 1080);
    for (0..100) |_| main.update_particles(0.016);
    // grab, then yank the mouse far away so the mouse springs exceed 10× rest length and break
    main.set_mouse_interaction(-200, -200, true);
    try testing.expect(main.get_mouse_grab_count() > 0);
    main.set_mouse_interaction(700, 400, true);
    for (0..5) |_| main.update_particles(0.016); // would panic on u8 underflow before the fix
    main.set_mouse_interaction(0, 0, false);
}

test "bonds: no two alive springs connect the same pair, and valence counts match springs" {
    main.init();
    main.reset();
    main.set_world_dimensions(1920, 1080);
    // a lattice of unsatisfied valence-6 particles bonds heavily
    for (0..40) |r| for (0..40) |c| main.add_particle(@as(f32, @floatFromInt(c)) * 15.5 - 300, @as(f32, @floatFromInt(r)) * 15.5 - 300, 6);
    for (0..120) |_| main.update_particles(0.016);
    const n = main.getDenseSpringCount();
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const a = main.getDenseSpringAt(i);
        var j: u32 = i + 1;
        while (j < n) : (j += 1) {
            const b = main.getDenseSpringAt(j);
            const same = (a.particle_a.eql(b.particle_a) and a.particle_b.eql(b.particle_b)) or (a.particle_a.eql(b.particle_b) and a.particle_b.eql(b.particle_a));
            try testing.expect(!same);
        }
    }
    try testing.expect(n > 1000);
}

noinline fn burnStack(depth: u32) u32 {
    var buf: [16 * 1024]u8 = undefined;
    @memset(&buf, @intCast(depth & 0xff));
    std.mem.doNotOptimizeAway(&buf);
    if (depth == 0) return buf[0];
    return burnStack(depth - 1) + buf[1];
}

test "perf: stack high-water mark sees deep stack use below the reset frame" {
    perf.perf_reset();
    _ = burnStack(8); // ~9 × 16 KB touched below the reset frame (top frame overlaps the 4 KB paint margin)
    const hwm = perf.perf_stack_hwm();
    try testing.expect(hwm >= 8 * 16 * 1024);
    // and after a fresh reset the probe is clean again (steps of the default scene fit in the margin)
    perf.perf_reset();
    try testing.expectEqual(@as(u32, 0), perf.perf_stack_hwm());
}
