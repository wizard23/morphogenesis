//! Performance instrumentation (plan: docs/plans/2026-08-16--performance-testing-plan.md, Phase 1).
//!
//! Two layers:
//!  * Phase timing ring + workload counters — compiled in only with `-Dperf=true`
//!    (`build_options.perf_enabled`). When disabled every hook is a comptime no-op and the
//!    `perf_now` host import is never referenced.
//!  * State checksum + stack high-water mark — always available; both are off the hot path
//!    (called by the harness between frames) and are the correctness / memory oracles.
//!
//! Marks are taken at PHASE BOUNDARIES only, never inside per-particle loops.
const std = @import("std");
const build_options = @import("build_options");
const host = @import("host.zig");
const main = @import("main.zig");

pub const enabled: bool = build_options.perf_enabled;

pub const Phase = enum(u8) {
    predict,
    mouse,
    bonds,
    gen_springs,
    gen_grid,
    gen_collide,
    solve,
    commit,
};
pub const PHASE_COUNT = @typeInfo(Phase).@"enum".fields.len;
pub const RING_FRAMES = 512;

pub const Counter = enum(u8) {
    /// Sum over all iterations in the frame of constraints handed to the solver.
    constraints,
    /// Collision constraints generated (subset of `constraints`).
    collision_pairs,
    /// Valence bonds (springs) created by updateValenceBonds.
    bonds_formed,
    /// Springs destroyed for overstretch.
    springs_removed,
    /// Max spatial-bin occupancy over the frame (max, not sum).
    bin_max,
    /// XPBD iterations executed.
    iterations,
    /// Max |predicted − x| over particles in the frame, in 1/1000 px (max, not sum). Must stay
    /// below spatial bin size − contact distance for the 3×3 collision scan to be exhaustive.
    max_step_disp_milli,
    /// Spatial cell overflows (sum over the frame's grid populations). Must be 0.
    cell_overflow,
};
pub const COUNTER_COUNT = @typeInfo(Counter).@"enum".fields.len;

// ---- phase ring + counters (gated) -------------------------------------------------------

var ring: [RING_FRAMES * PHASE_COUNT]f32 = undefined;
var ring_head: u32 = 0;
var ring_count: u32 = 0;
var frame_phase_ms: [PHASE_COUNT]f32 = [_]f32{0} ** PHASE_COUNT;
var frame_counters: [COUNTER_COUNT]u32 = [_]u32{0} ** COUNTER_COUNT;
var last_frame_counters: [COUNTER_COUNT]u32 = [_]u32{0} ** COUNTER_COUNT;
var total_counters: [COUNTER_COUNT]u64 = [_]u64{0} ** COUNTER_COUNT;
var frames_since_reset: u32 = 0;

/// Timestamp for a phase start. Zero-cost when disabled.
pub inline fn now() f64 {
    if (!enabled) return 0;
    return host.perf_now();
}

/// Accumulate `now() - t0` into `phase` for the current frame.
pub inline fn add(phase: Phase, t0: f64) void {
    if (!enabled) return;
    frame_phase_ms[@intFromEnum(phase)] += @floatCast(host.perf_now() - t0);
}

pub inline fn count(counter: Counter, n: u32) void {
    if (!enabled) return;
    frame_counters[@intFromEnum(counter)] += n;
}

pub inline fn max(counter: Counter, v: u32) void {
    if (!enabled) return;
    const i = @intFromEnum(counter);
    if (v > frame_counters[i]) frame_counters[i] = v;
}

pub inline fn beginFrame() void {
    if (!enabled) return;
    @memset(&frame_phase_ms, 0);
    @memset(&frame_counters, 0);
}

pub inline fn endFrame() void {
    if (!enabled) return;
    const base = ring_head * PHASE_COUNT;
    for (0..PHASE_COUNT) |p| ring[base + p] = frame_phase_ms[p];
    ring_head = (ring_head + 1) % RING_FRAMES;
    if (ring_count < RING_FRAMES) ring_count += 1;
    for (0..COUNTER_COUNT) |c| {
        last_frame_counters[c] = frame_counters[c];
        const kind: Counter = @enumFromInt(c);
        if (kind == .bin_max or kind == .max_step_disp_milli) {
            if (frame_counters[c] > total_counters[c]) total_counters[c] = frame_counters[c];
        } else {
            total_counters[c] += frame_counters[c];
        }
    }
    frames_since_reset += 1;
}

// ---- stack high-water mark (always available) --------------------------------------------

const STACK_SENTINEL: u8 = 0xA5;
/// On wasm the shadow stack is stack-first (occupies [0, stack_size)), so everything below the
/// reset-time frame down to this floor is unused stack we may paint.
const STACK_FLOOR_BYTES: usize = 64 * 1024;
var stack_base: usize = 0;
var stack_probe_len: usize = 0;

/// Locals of the painting function itself live just below its frame address on native targets
/// (and may on wasm if address-taken), so start painting this far below it.
const STACK_PAINT_MARGIN: usize = 4096;

noinline fn paintStack() void {
    const here = @frameAddress() - STACK_PAINT_MARGIN;
    // Never paint below address 0 (wasm) / into unmapped memory (native: keep it modest).
    const len: usize = if (host.is_wasm_host) here -| STACK_FLOOR_BYTES else @min(2 * 1024 * 1024, here -| 4096);
    stack_base = here;
    stack_probe_len = len;
    const region: [*]volatile u8 = @ptrFromInt(here - len);
    for (0..len) |i| region[i] = STACK_SENTINEL;
}

/// Deepest touched byte below the reset frame. Returns `stack_probe_len` (saturated) if even the
/// deepest probed byte was touched — i.e. real use is ≥ probe; check `perf_stack_probe_len()`.
fn stackHighWater() u32 {
    if (stack_probe_len == 0) return 0;
    const region: [*]const volatile u8 = @ptrFromInt(stack_base - stack_probe_len);
    var i: usize = 0;
    while (i < stack_probe_len) : (i += 1) {
        if (region[i] != STACK_SENTINEL) return @intCast(stack_probe_len - i);
    }
    return 0;
}

// ---- state checksum (always available) ---------------------------------------------------

fn fnv1a(hash: u32, bytes: []const u8) u32 {
    var h = hash;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x01000193;
    }
    return h;
}

inline fn fnvF32(hash: u32, v: f32) u32 {
    return fnv1a(hash, std.mem.asBytes(&@as(u32, @bitCast(v))));
}
inline fn fnvU16(hash: u32, v: u16) u32 {
    return fnv1a(hash, std.mem.asBytes(&v));
}

/// FNV-1a-32 over dense particle state (x, y, vx, vy bit patterns) and alive springs
/// (handles + rest length), in dense order. Same inputs → same value, on every device.
pub fn stateChecksum() u32 {
    var h: u32 = 0x811c9dc5;
    const pcount = main.getDenseParticleCount();
    h = fnv1a(h, std.mem.asBytes(&pcount));
    for (0..pcount) |i| {
        const p = main.getDenseParticleAt(@intCast(i));
        h = fnvF32(h, p.x);
        h = fnvF32(h, p.y);
        h = fnvF32(h, p.vx);
        h = fnvF32(h, p.vy);
    }
    const scount = main.getDenseSpringCount();
    h = fnv1a(h, std.mem.asBytes(&scount));
    for (0..scount) |i| {
        const s = main.getDenseSpringAt(@intCast(i));
        h = fnvU16(h, s.particle_a.index);
        h = fnvU16(h, s.particle_a.generation);
        h = fnvU16(h, s.particle_b.index);
        h = fnvU16(h, s.particle_b.generation);
        h = fnvF32(h, s.rest_length);
    }
    return h;
}

// ---- exports -----------------------------------------------------------------------------

export fn perf_is_enabled() bool {
    return enabled;
}

export fn perf_phase_count() u32 {
    return PHASE_COUNT;
}

export fn perf_counter_count() u32 {
    return COUNTER_COUNT;
}

export fn perf_ring_frames() u32 {
    return RING_FRAMES;
}

/// Reset ring, counters, and repaint the stack probe. Call between scenarios / bursts.
pub export fn perf_reset() void {
    if (enabled) {
        ring_head = 0;
        ring_count = 0;
        frames_since_reset = 0;
        @memset(&frame_phase_ms, 0);
        @memset(&frame_counters, 0);
        @memset(&last_frame_counters, 0);
        @memset(&total_counters, 0);
    }
    paintStack();
}

/// Pointer to the ring: `RING_FRAMES × PHASE_COUNT` f32 ms, frame-major, oldest at
/// `(head - count) mod RING_FRAMES`.
export fn perf_ring_ptr() [*]const f32 {
    return &ring;
}
export fn perf_ring_head() u32 {
    return ring_head;
}
export fn perf_ring_count() u32 {
    return ring_count;
}
export fn perf_frames() u32 {
    return frames_since_reset;
}

/// Total since reset (sum; `bin_max` is a max). Returns the low 32 bits.
export fn perf_counter_total(id: u32) u32 {
    if (id >= COUNTER_COUNT) return 0;
    return @truncate(total_counters[id]);
}
/// Value from the last completed frame.
export fn perf_counter_last(id: u32) u32 {
    if (id >= COUNTER_COUNT) return 0;
    return last_frame_counters[id];
}

/// Bytes of stack used below the `perf_reset` call frame since the last reset.
pub export fn perf_stack_hwm() u32 {
    return stackHighWater();
}

/// Size of the painted probe; a HWM equal to this means "at least this much" (saturated).
pub export fn perf_stack_probe_len() u32 {
    return @intCast(stack_probe_len);
}

export fn state_checksum() u32 {
    return stateChecksum();
}
