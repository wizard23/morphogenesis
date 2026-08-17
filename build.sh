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
# Release builds are stripped of DWARF (STRIP=0 to keep symbols, e.g. for browser stack traces).
PERF=${PERF:-0}
STRIP=${STRIP:-1}
FLAGS=""
if [ "$PERF" = "1" ]; then FLAGS="$FLAGS -Dperf=true"; fi
if [ "$STRIP" = "1" ] && [ "$OPTIMIZE" != "Debug" ]; then FLAGS="$FLAGS -Dstrip=true"; fi
echo "Using optimization level: $OPTIMIZE (perf instrumentation: $PERF, strip: $STRIP)"
$ZIG_CMD build -Doptimize=$OPTIMIZE $FLAGS

# Copy to project root
cp zig-out/bin/webgpu-demo.wasm .

echo "✅ Build complete! "