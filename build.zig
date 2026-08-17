const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // Plain `zig build` matches ./build.sh (ReleaseFast); pass -Doptimize=Debug for safety checks.
    // (Not standardOptimizeOption(.{ .preferred_optimize_mode }) — that swaps -Doptimize for a
    // -Drelease bool whose default is still Debug.)
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Prioritize performance, safety, or binary size (default: ReleaseFast)") orelse .ReleaseFast;

    // -Dperf=true compiles the phase-timing ring + counters into the wasm (see src/perf.zig).
    // Off by default: every hook is a comptime no-op.
    const perf_enabled = b.option(bool, "perf", "Enable performance instrumentation (perf.zig ring/counters)") orelse false;
    // -Dstrip=true drops DWARF from the wasm (~590 KB of ~810 KB). ./build.sh uses it for the shipped
    // release build; bench/perf builds keep symbols for readable stack traces.
    const strip = b.option(bool, "strip", "Strip debug info from the wasm") orelse false;
    const build_options = b.addOptions();
    build_options.addOption(bool, "perf_enabled", perf_enabled);
    build_options.addOption(std.builtin.OptimizeMode, "optimize_mode", optimize);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_options", build_options);
    if (strip) root_module.strip = true;

    const exe = b.addExecutable(.{
        .name = "webgpu-demo",
        .root_module = root_module,
    });

    // No entry point for WASM library
    exe.entry = .disabled;

    // Export functions for WebAssembly
    exe.rdynamic = true;

    b.installArtifact(exe);

    // `zig build test` — native unit tests (arena, spatial mapping, checksum determinism).
    // Host externs are stubbed via src/host.zig when not targeting wasm.
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", build_options);
    const unit_tests = b.addTest(.{ .root_module = test_module });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
