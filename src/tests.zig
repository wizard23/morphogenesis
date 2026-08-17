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
    var arena = SmallArena.init();
    const h = arena.spawn(.{ .v = 7 });
    try testing.expect(h.isValid());
    try testing.expectEqual(@as(u32, 1), arena.getAliveCount());
    try testing.expectEqual(@as(u32, 7), arena.get(h).?.v);
}

test "arena: destroy invalidates handle; slot reuse bumps generation" {
    var arena = SmallArena.init();
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
    var arena = SmallArena.init();
    for (0..4) |i| try testing.expect(arena.spawn(.{ .v = @intCast(i) }).isValid());
    try testing.expect(!arena.spawn(.{ .v = 99 }).isValid());
}

test "arena: dense order is swap-remove (order-sensitive but deterministic)" {
    var arena = SmallArena.init();
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

test "perf: stack high-water mark reports use below the reset frame" {
    perf.perf_reset();
    // update_particles has large stack temporaries (see analysis report)
    main.update_particles(0.016);
    const hwm = perf.perf_stack_hwm();
    try testing.expect(hwm > 0);
}
