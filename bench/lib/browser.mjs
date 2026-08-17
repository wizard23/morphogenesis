// Tier 2 shared pieces: static server (serves the repo root + the perf wasm), Chromium launch with
// WebGPU flags, adapter probe, CDP heap sampling aggregation, timing-ring summary.
import http from "node:http";
import { readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { chromium } from "playwright";
import { REPO_ROOT } from "./wasm-host.mjs";
import { dist } from "./stats.mjs";

const MIME = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".wasm": "application/wasm", ".svg": "image/svg+xml", ".json": "application/json" };

/** Serve the repo root on 127.0.0.1:0 with COOP/COEP; `/webgpu-demo.wasm` is overridden by `wasmPath`. */
export function startStaticServer(wasmPath) {
  const server = http.createServer((req, res) => {
    let url = decodeURIComponent((req.url ?? "/").split("?")[0]);
    if (url === "/") url = "/index.html";
    const file = url === "/webgpu-demo.wasm" ? wasmPath : path.join(REPO_ROOT, path.normalize(url));
    if (!file.startsWith(REPO_ROOT) && file !== wasmPath) { res.writeHead(403); res.end(); return; }
    if (!existsSync(file)) { res.writeHead(404); res.end("not found"); return; }
    res.writeHead(200, {
      "Content-Type": MIME[path.extname(file)] ?? "application/octet-stream",
      "Cross-Origin-Opener-Policy": "same-origin",
      "Cross-Origin-Embedder-Policy": "require-corp",
      "Cache-Control": "no-store",
    });
    res.end(readFileSync(file));
  });
  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve({ server, origin: `http://127.0.0.1:${server.address().port}` })));
}

/** GPU=1 → real adapter (Vulkan, blocklist ignored); default → SwiftShader software WebGPU. */
export async function launchBrowser({ gpu = process.env.GPU === "1", headed = process.env.HEADED === "1" } = {}) {
  const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ?? (existsSync("/usr/bin/chromium") ? "/usr/bin/chromium" : undefined);
  const args = ["--no-sandbox", "--enable-unsafe-webgpu", "--enable-features=Vulkan", "--js-flags=--expose-gc", "--disable-frame-rate-limit", "--disable-gpu-vsync"];
  if (gpu) args.push("--ignore-gpu-blocklist", "--use-gl=angle", "--use-angle=vulkan");
  else args.push("--use-webgpu-adapter=swiftshader");
  const browser = await chromium.launch({ headless: !headed, executablePath, args });
  return { browser, mode: gpu ? "gpu" : "swiftshader", executablePath: executablePath ?? "(playwright bundled)" };
}

export async function adapterInfo(page) {
  return page.evaluate(async () => {
    if (!navigator.gpu) return { available: false, secure: isSecureContext };
    const a = await navigator.gpu.requestAdapter();
    if (!a) return { available: false, secure: isSecureContext, reason: "no adapter" };
    const i = a.info ?? {};
    return { available: true, vendor: i.vendor, architecture: i.architecture, device: i.device, description: i.description, isolated: crossOriginIsolated, timerResolutionUs: await (async () => { let min = Infinity; for (let k = 0; k < 2000; k++) { const t0 = performance.now(); let t1 = t0; while (t1 === t0) t1 = performance.now(); min = Math.min(min, t1 - t0); } return +(min * 1000).toFixed(1); })() };
  });
}

/** Wait until the app is running (wasm loaded, renderer up, first frames recorded). */
export async function waitForApp(page, timeoutMs = 30000) {
  await page.waitForFunction(() => window.__morphoBench && window.__morphoTimingRing && (() => { try { return window.__morphoBench.snapshot().particles > 0; } catch { return false; } })(), null, { timeout: timeoutMs });
  await page.waitForFunction(() => window.__morphoTimingRing.read().count > 10, null, { timeout: timeoutMs });
}

// ---- probes: DOM mutations + page errors ------------------------------------------------------
export async function installProbes(page) {
  await page.evaluate(() => {
    if (window.__morphoProbes) return;
    const state = { domMutations: 0, sources: {} };
    new MutationObserver((records) => {
      for (const r of records) {
        state.domMutations++;
        const t = r.target, key = t.nodeType === Node.TEXT_NODE ? `#text<${t.parentElement?.id || t.parentElement?.tagName}>` : `${t.tagName}#${t.id || "-"}`;
        state.sources[key] = (state.sources[key] ?? 0) + 1;
      }
    }).observe(document.documentElement, { attributes: true, childList: true, subtree: true, characterData: true });
    window.__morphoProbes = { reset: () => { state.domMutations = 0; state.sources = {}; }, read: () => ({ domMutations: state.domMutations, sources: { ...state.sources } }) };
  });
}

// ---- CDP heap sampling ----------------------------------------------------------------------------
const APP_FILES = ["script.js", "renderer.js"];
export function aggregateHeapProfile(head) {
  const byFn = new Map();
  let app = 0, runtime = 0;
  (function walk(node) {
    const f = node.callFrame;
    if (node.selfSize > 0) {
      const url = f.url ?? "";
      const isApp = APP_FILES.some((n) => url.endsWith("/" + n));
      if (isApp) {
        const key = `${f.functionName || "(anonymous)"} — ${url.split("/").pop()}:${f.lineNumber + 1}`;
        byFn.set(key, (byFn.get(key) ?? 0) + node.selfSize);
        app += node.selfSize;
      } else runtime += node.selfSize;
    }
    for (const c of node.children ?? []) walk(c);
  })(head);
  return { appBytes: app, runtimeBytes: runtime, top: [...byFn.entries()].sort((a, b) => b[1] - a[1]).slice(0, 12) };
}

/** Run one measured phase: setup (unsampled) → settle → gc → reset probes/ring → sample → action → collect. */
export async function measurePhase(page, cdp, name, durationMs, action, setup) {
  if (setup) { await setup(); await page.waitForTimeout(300); }
  await page.evaluate(() => { window.gc?.(); window.__morphoTimingRing.reset(); window.__morphoProbes.reset(); });
  await cdp.send("HeapProfiler.startSampling", { samplingInterval: 4096 });
  const t0 = Date.now();
  await action();
  const elapsedMs = Date.now() - t0;
  const { profile } = await cdp.send("HeapProfiler.stopSampling");
  const heap = aggregateHeapProfile(profile.head);
  const ring = await page.evaluate(() => window.__morphoTimingRing.read());
  const probes = await page.evaluate(() => window.__morphoProbes.read());
  const snap = await page.evaluate(() => window.__morphoBench.snapshot());
  return { name, durationMs: elapsedMs, ring: summarizeRing(ring), heap: { ...heap, appBytesPerSec: heap.appBytes / (elapsedMs / 1000), runtimeBytesPerSec: heap.runtimeBytes / (elapsedMs / 1000) }, probes, snap };
}

export function summarizeRing({ buffer, count }) {
  const stride = 4, fields = ["simMs", "uploadMs", "submitMs", "frameIntervalMs"];
  const out = { frames: count };
  fields.forEach((f, i) => { const v = []; for (let k = 0; k < count; k++) { const x = buffer[k * stride + i]; if (i !== 3 || x > 0) v.push(x); } out[f] = dist(v); });
  out.fps = out.frameIntervalMs.p50 > 0 ? 1000 / out.frameIntervalMs.p50 : 0;
  return out;
}
