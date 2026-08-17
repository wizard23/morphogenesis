#!/bin/bash
echo "Building Zig WebGPU WASM Demo..."

# Default to ReleaseFast if no optimization level specified
OPTIMIZE=${1:-ReleaseFast}

# Canonical toolchain: Zig 0.16 (see docs/plans/2026-08-16--performance-testing-plan.md §0a)
if command -v zig &> /dev/null; then
    ZIG_CMD="zig"
else
    echo "❌ Zig not found! Please install Zig 0.16.0 or compatible version"
    echo "   https://ziglang.org/download/"
    exit 1
fi

echo "Using Zig: $($ZIG_CMD version)"

# Build WASM module. PERF=1 compiles in the perf.zig timing ring/counters (bench builds).
PERF=${PERF:-0}
PERF_FLAG=""
if [ "$PERF" = "1" ]; then PERF_FLAG="-Dperf=true"; fi
echo "Using optimization level: $OPTIMIZE (perf instrumentation: $PERF)"
$ZIG_CMD build -Doptimize=$OPTIMIZE $PERF_FLAG

# Copy to project root
cp zig-out/bin/webgpu-demo.wasm .

echo "✅ Build complete! "