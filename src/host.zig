//! Host (JavaScript) imports, with native stubs so the same modules compile under `zig build test`.
const std = @import("std");
const builtin = @import("builtin");

const externs = struct {
    pub extern fn console_log(ptr: [*]const u8, len: usize) void;
    pub extern fn emscripten_webgpu_get_device() u32;
    /// High-resolution monotonic clock in milliseconds (performance.now / hrtime). Only imported
    /// when perf instrumentation is compiled in.
    pub extern fn perf_now() f64;
};

const stubs = struct {
    pub fn console_log(ptr: [*]const u8, len: usize) void {
        if (builtin.is_test) return;
        std.debug.print("{s}\n", .{ptr[0..len]});
    }
    pub fn emscripten_webgpu_get_device() u32 {
        return 0;
    }
    pub fn perf_now() f64 {
        return @as(f64, @floatFromInt(std.time.nanoTimestamp())) / std.time.ns_per_ms;
    }
};

pub const is_wasm_host = builtin.cpu.arch == .wasm32 and builtin.os.tag == .freestanding;
const impl = if (is_wasm_host) externs else stubs;

pub const console_log = impl.console_log;
pub const emscripten_webgpu_get_device = impl.emscripten_webgpu_get_device;
pub const perf_now = impl.perf_now;

pub fn log(comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(buffer[0..], fmt, args) catch "Log message too long";
    console_log(message.ptr, message.len);
}
