const canvas = document.getElementById("webgpu-canvas");
let wasmModule = null;
let renderer = null;
let animationId = null;
let time = 0;
let updateTimeMs = 0;
const timingDisplay = document.getElementById("timing-display");

// Status line refresh cadence and last written text (skip unchanged writes)
const STATUS_INTERVAL_MS = 250;
let statusNextUpdateAt = 0;
let lastStatusText = "";

// FPS: frames counted per wall-clock window, refreshed every FPS_WINDOW_MS
const FPS_WINDOW_MS = 500;
let fpsFrames = 0;
let fpsWindowStart = 0;
let fpsValue = 0;

// In-app timing ring (zero-alloc on the frame path): per frame [simMs, uploadMs, submitMs, frameIntervalMs].
// Read by benchmarks via window.__morphoTimingRing (see docs/HOWTO-performance.md).
const TIMING_RING_FRAMES = 512;
const TIMING_RING_STRIDE = 4;
const timingRing = new Float32Array(TIMING_RING_FRAMES * TIMING_RING_STRIDE);
let timingRingHead = 0;
let timingRingCount = 0;
let lastFrameStart = 0;

// Mouse interaction state
let mousePressed = false;
let mouseX = 0;
let mouseY = 0;

// Simulation control state
let isPaused = false;
let stepRequested = false;

// Tool states
const TOOLS = {
  DRAG: 'drag',
  SPAWN: 'spawn'
};
let currentTool = TOOLS.DRAG;

// Particle painting state
let lastSpawnX = null;
let lastSpawnY = null;
let spawnValence = 0; // Default spawn valence

function log(message) {
  console.log(message);
}

// Set canvas size to match viewport
function resizeCanvas() {
  // Get the actual device pixel ratio (respects browser zoom)
  const currentDPR = window.devicePixelRatio;
  
  // Canvas resolution follows device pixel ratio
  canvas.width = window.innerWidth * currentDPR;
  canvas.height = window.innerHeight * currentDPR;
  canvas.style.width = window.innerWidth + "px";
  canvas.style.height = window.innerHeight + "px";

  // Store aspect ratio for reference
  window.aspectRatio = canvas.width / canvas.height;
  
  // Set world dimensions based on CSS pixels (not device pixels)
  // This makes the world size stay constant in logical units while zoom changes
  if (wasmModule && wasmModule.exports.set_world_dimensions) {
    // Use CSS pixel dimensions for world space (zoom-independent logical size)
    const worldWidth = window.innerWidth;
    const worldHeight = window.innerHeight;
    
    wasmModule.exports.set_world_dimensions(worldWidth, worldHeight);
    console.log(`World: ${worldWidth}x${worldHeight} logical pixels | Canvas: ${canvas.width}x${canvas.height} device pixels (DPR: ${currentDPR.toFixed(2)})`);
  }
}

// Listen for both resize and zoom changes
window.addEventListener("resize", resizeCanvas);

// Detect zoom changes by monitoring devicePixelRatio
let lastDPR = window.devicePixelRatio;
function checkZoomChange() {
  if (window.devicePixelRatio !== lastDPR) {
    lastDPR = window.devicePixelRatio;
    resizeCanvas();
  }
}
// Check for zoom changes periodically
setInterval(checkZoomChange, 500);
resizeCanvas();

// Convert mouse screen coordinates to world coordinates
function screenToWorld(screenX, screenY) {
  const rect = canvas.getBoundingClientRect();
  
  // Convert to logical coordinates (CSS pixels)
  const logicalX = screenX - rect.left;
  const logicalY = screenY - rect.top;
  
  // World coordinates use CSS pixels (logical size) with origin at center
  const worldX = logicalX - (window.innerWidth / 2);
  const worldY = (window.innerHeight / 2) - logicalY; // Flip Y axis for standard coordinate system
  
  return { x: worldX, y: worldY };
}

// Set tool to drag/grab
function setDragTool() {
  currentTool = TOOLS.DRAG;
  updateToolButtons();
  updateToolDisplay();
}

// Set tool to spawn with specified valence
function setSpawnTool(valence) {
  currentTool = TOOLS.SPAWN;
  spawnValence = valence;
  updateToolButtons();
  updateToolDisplay();
}

// Update button visual states
function updateToolButtons() {
  // Remove active class from all buttons
  document.querySelectorAll('.tool-btn').forEach(btn => btn.classList.remove('active'));
  
  // Add active class to current tool button
  if (currentTool === TOOLS.DRAG) {
    document.getElementById('grab-btn').classList.add('active');
  } else if (currentTool === TOOLS.SPAWN) {
    document.getElementById(`spawn-${spawnValence}-btn`).classList.add('active');
  }
}

// Keyboard event handlers for tool switching
document.addEventListener('keydown', (event) => {
  if (!wasmModule) return;
  
  const key = event.key.toLowerCase();
  
  if (key === 'q' || key === 'g') {
    setDragTool();
  } else if (key >= '0' && key <= '6') {
    setSpawnTool(parseInt(key));
  }
});

// Update tool display in UI
function updateToolDisplay() {
  const toolDisplay = document.getElementById('tool-display');
  if (toolDisplay) {
    const toolName = currentTool === TOOLS.DRAG ? 'Grab' : `Spawn valence ${spawnValence}`;
    toolDisplay.textContent = `Tool: ${toolName}`;
  }
}

// Spawn a particle if far enough from the last spawn point
function trySpawnParticle(worldX, worldY) {
  if (!wasmModule) return false;
  
  // Check if we should spawn based on distance from last spawn
  if (lastSpawnX !== null && lastSpawnY !== null) {
    const dx = worldX - lastSpawnX;
    const dy = worldY - lastSpawnY;
    const distance = Math.sqrt(dx * dx + dy * dy);
    
    // Use 2x particle diameter as threshold (diameter = 2 * radius)
    const particleSize = wasmModule.exports.get_particle_size();
    const spawnThreshold = particleSize ;
    
    if (distance < spawnThreshold) {
      return false; // Too close to last spawn point
    }
  }
  
  wasmModule.exports.add_particle(worldX, worldY, spawnValence);
  
  lastSpawnX = worldX;
  lastSpawnY = worldY;
  return true;
}

// Mouse event handlers
canvas.addEventListener('pointerdown', (event) => {
  if (!wasmModule) return;
  
  mousePressed = true;
  const worldPos = screenToWorld(event.clientX, event.clientY);
  mouseX = worldPos.x;
  mouseY = worldPos.y;
  
  // Handle based on current tool
  if (currentTool === TOOLS.DRAG) {
    // Tell WASM about mouse press for dragging
    wasmModule.exports.set_mouse_interaction(mouseX, mouseY, true);
  } else if (currentTool === TOOLS.SPAWN) {
    // Start particle painting - spawn first particle and reset spawn tracking
    const spawned = trySpawnParticle(mouseX, mouseY);
    if (spawned) {
      console.log(`Started painting at (${mouseX.toFixed(1)}, ${mouseY.toFixed(1)})`);
    }
  }
});

canvas.addEventListener('pointermove', (event) => {
  if (!wasmModule) return;
  
  const worldPos = screenToWorld(event.clientX, event.clientY);
  mouseX = worldPos.x;
  mouseY = worldPos.y;
  
  // Handle based on current tool and mouse state
  if (mousePressed) {
    if (currentTool === TOOLS.DRAG) {
      // Update mouse position in WASM for dragging
      wasmModule.exports.set_mouse_interaction(mouseX, mouseY, true);
    } else if (currentTool === TOOLS.SPAWN) {
      // Continue painting particles if we've moved far enough
      trySpawnParticle(mouseX, mouseY);
    }
  }
});

canvas.addEventListener('pointerup', (event) => {
  if (!wasmModule) return;
  
  mousePressed = false;
  
  // Handle based on current tool
  if (currentTool === TOOLS.DRAG) {
    // Tell WASM about mouse release for dragging
    wasmModule.exports.set_mouse_interaction(mouseX, mouseY, false);
  } else if (currentTool === TOOLS.SPAWN) {
    // End painting - reset spawn tracking for next painting session
    lastSpawnX = null;
    lastSpawnY = null;
    console.log('Ended particle painting');
  }
});

// Control button event handlers
document.getElementById('pause-btn').addEventListener('click', () => {
  isPaused = !isPaused;
  const btn = document.getElementById('pause-btn');
  btn.textContent = isPaused ? 'Resume' : 'Pause';
});

document.getElementById('step-btn').addEventListener('click', () => {
  if (isPaused) {
    stepRequested = true;
  }
});

document.getElementById('reset-btn').addEventListener('click', () => {
  if (wasmModule) {
    wasmModule.exports.reset(); // Reset simulation to initial state
  }
});

// Toolbar button event handlers
document.getElementById('grab-btn').addEventListener('click', () => {
  setDragTool();
});

document.getElementById('spawn-0-btn').addEventListener('click', () => {
  setSpawnTool(0);
});

document.getElementById('spawn-1-btn').addEventListener('click', () => {
  setSpawnTool(1);
});

document.getElementById('spawn-2-btn').addEventListener('click', () => {
  setSpawnTool(2);
});

document.getElementById('spawn-3-btn').addEventListener('click', () => {
  setSpawnTool(3);
});

document.getElementById('spawn-4-btn').addEventListener('click', () => {
  setSpawnTool(4);
});

document.getElementById('spawn-5-btn').addEventListener('click', () => {
  setSpawnTool(5);
});

document.getElementById('spawn-6-btn').addEventListener('click', () => {
  setSpawnTool(6);
});

async function initRenderer() {
  // Create and initialize the renderer
  renderer = new MorphogenesisRenderer(canvas);
  return await renderer.initialize(wasmModule);
}

// Load and instantiate WASM module
async function loadWasm() {
  try {
    // Environment for WASM module
    const env = {
      console_log: (ptr, len) => {
        if (wasmModule && wasmModule.exports.memory) {
          const memory = wasmModule.exports.memory;
          const buffer = new Uint8Array(memory.buffer, ptr, len);
          const message = new TextDecoder().decode(buffer);
          log("[WASM] " + message);
        }
      },
      emscripten_webgpu_get_device: () => (renderer?.device ? 1 : 0),
      // High-resolution clock for perf.zig phase timing (only imported by -Dperf=true builds)
      perf_now: () => performance.now(),
    };

    const wasmResponse = await fetch("webgpu-demo.wasm");
    const wasmBytes = await wasmResponse.arrayBuffer();
    const wasmObj = await WebAssembly.instantiate(wasmBytes, {
      env: env,
    });

    wasmModule = wasmObj.instance;
    log("WASM module loaded successfully");

    // Initialize the WASM module
    wasmModule.exports.init();
    
    // Set initial world dimensions based on current aspect ratio
    resizeCanvas(); // This will call set_world_dimensions
    
    return true;
  } catch (error) {
    log("WASM loading error: " + error.message);
    return false;
  }
}

// Render frame with particles, springs, and grid
function renderFrame() {
  if (!renderer || !wasmModule) {
    return;
  }

  // Start timing the entire frame
  const frameStart = performance.now();

  // Update FPS estimate (frame interval includes GPU/vsync wait, unlike totalFrameTimeMs)
  fpsFrames++;
  if (fpsWindowStart === 0) {
    fpsWindowStart = frameStart;
  } else if (frameStart - fpsWindowStart >= FPS_WINDOW_MS) {
    fpsValue = (fpsFrames * 1000) / (frameStart - fpsWindowStart);
    fpsFrames = 0;
    fpsWindowStart = frameStart;
  }

  // Check pause/step state
  const shouldUpdate = !isPaused || stepRequested;
  if (stepRequested) {
    stepRequested = false;
  }

  let physicsTimeMs = 0;
  if (shouldUpdate) {
    time += 0.016; // ~60fps timing

    // Time the particle update loop
    const updateStart = performance.now();
    wasmModule.exports.update_particles(0.016);
    const updateEnd = performance.now();
    physicsTimeMs = updateEnd - updateStart;
  }

  // Always render (even when paused) to show current state
  const renderStart = performance.now();
  renderer.render(wasmModule);
  const renderEnd = performance.now();
  const renderTimeMs = renderEnd - renderStart;
  
  // Calculate total frame time
  const frameEnd = performance.now();
  const totalFrameTimeMs = frameEnd - frameStart;

  // Record into the timing ring
  const ringBase = timingRingHead * TIMING_RING_STRIDE;
  timingRing[ringBase] = physicsTimeMs;
  timingRing[ringBase + 1] = renderer.lastUploadMs;
  timingRing[ringBase + 2] = renderer.lastSubmitMs;
  timingRing[ringBase + 3] = lastFrameStart ? frameStart - lastFrameStart : 0;
  lastFrameStart = frameStart;
  timingRingHead = (timingRingHead + 1) % TIMING_RING_FRAMES;
  if (timingRingCount < TIMING_RING_FRAMES) timingRingCount++;
// console.log(totalFrameTimeMs);
  // Status line: at most STATUS_INTERVAL_MS apart and only when the text changed (0/0/0 rule:
  // a per-frame template string + textContent write was the whole JS allocation / DOM budget).
  if (frameStart >= statusNextUpdateAt) {
    statusNextUpdateAt = frameStart + STATUS_INTERVAL_MS;
    let statusText;
    if (isPaused) {
      statusText = "PAUSED";
    } else {
      const maxOccupancy = wasmModule.exports.get_spatial_max_occupancy();
      const gridX = wasmModule.exports.get_grid_dimensions_x();
      const gridY = wasmModule.exports.get_grid_dimensions_y();
      const worldW = Math.round(wasmModule.exports.get_world_width_debug());
      const worldH = Math.round(wasmModule.exports.get_world_height_debug());
      const aliveParticles = wasmModule.exports.get_alive_particle_count();
      const aliveSprings = wasmModule.exports.get_alive_spring_count();

      statusText = `${fpsValue.toFixed(0)}fps ${Math.round(totalFrameTimeMs)}ms | P:${aliveParticles} S:${aliveSprings} | ${worldW}x${worldH} | ${gridX}x${gridY} | bin:${maxOccupancy}`;
    }
    if (statusText !== lastStatusText) {
      lastStatusText = statusText;
      timingDisplay.textContent = statusText;
    }
  }

  // Continue animation
  animationId = requestAnimationFrame(renderFrame);
}

// Benchmark hooks (Tier 2 harness / manual console use). Read-only or export-wrapping; no UI coupling.
window.__morphoTimingRing = {
  stride: TIMING_RING_STRIDE,
  fields: ["simMs", "uploadMs", "submitMs", "frameIntervalMs"],
  reset() { timingRingHead = 0; timingRingCount = 0; timingRing.fill(0); lastFrameStart = 0; },
  read() { return { buffer: Array.from(timingRing), head: timingRingHead, count: timingRingCount }; },
};

window.__morphoBench = {
  stepBurst(n) { for (let i = 0; i < n; i++) wasmModule.exports.update_particles(0.016); },
  paintBlock({ cx, cy, cols, rows, spacing, valence }) {
    const x0 = cx - ((cols - 1) * spacing) / 2, y0 = cy - ((rows - 1) * spacing) / 2;
    for (let r = 0; r < rows; r++) for (let c = 0; c < cols; c++) wasmModule.exports.add_particle(x0 + c * spacing, y0 + r * spacing, valence);
  },
  mouse(x, y, pressed) { wasmModule.exports.set_mouse_interaction(x, y, pressed); },
  setPaused(paused) { isPaused = paused; document.getElementById('pause-btn').textContent = paused ? 'Resume' : 'Pause'; },
  reset() { wasmModule.exports.reset(); },
  snapshot() {
    const e = wasmModule.exports;
    return {
      particles: e.get_alive_particle_count(), springs: e.get_alive_spring_count(),
      binMax: e.get_spatial_max_occupancy(), grabs: e.get_mouse_grab_count(),
      checksum: (e.state_checksum() >>> 0).toString(16).padStart(8, "0"),
      memoryPages: e.memory.buffer.byteLength / 65536,
      stackHwm: e.perf_stack_hwm(), perfEnabled: !!e.perf_is_enabled(),
      worldW: e.get_world_width(), worldH: e.get_world_height(), fps: fpsValue,
    };
  },
};

// Initialize everything
async function init() {
  log("Starting WebGPU + Zig WASM demo...");

  const wasmOk = await loadWasm();
  if (!wasmOk) {
    log("Cannot continue without WASM module");
    return;
  }

  const rendererOk = await initRenderer();
  if (!rendererOk) {
    log("Cannot continue without WebGPU renderer");
    return;
  }

  log(
    `WASM initialized ${wasmModule.exports.get_particle_count()} particles`
  );

  // Initialize UI
  updateToolDisplay();
  updateToolButtons();

  log("Starting animation loop...");
  renderFrame(); // Start the animation
}

// Start when page loads
window.addEventListener("load", init);