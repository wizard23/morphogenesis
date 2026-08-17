#!/usr/bin/env node
// Tier 2: in-app measurement in headless Chromium (WebGPU). Frame timing ring, JS gross allocation
// (CDP HeapProfiler sampling, APP = script.js/renderer.js vs runtime), DOM mutations, page errors.
//   node bench/browser-bench.mjs [--json out.json] [--md out.md]     GPU=1 → real adapter, HEADED=1
import { writeFileSync } from "node:fs";
import { ensureWasm } from "./lib/wasm-host.mjs";
import { machineInfo, wasmInfo, formatHeader } from "./lib/machine.mjs";
import { startStaticServer, launchBrowser, adapterInfo, waitForApp, installProbes, measurePhase } from "./lib/browser.mjs";
import { padTable, fmtMs, markdownTable } from "./lib/stats.mjs";

export const PHASES = [
  { name: "idle-paused", ms: 2000, desc: "paused, rendering only" },
  { name: "steady", ms: 3000, desc: "S2: fresh scene + 600 steps, then playing" },
  { name: "drag", ms: 3000, desc: "S5: circular mouse drag around lattice 0 (page-side 60 Hz driver)" },
  { name: "paint", ms: 3000, desc: "spawn tool: valence-0 stroke across the top (page-side driver)" },
  { name: "reset-storm", ms: 2500, desc: "5× Reset while playing, then a grab check" },
];

export async function runBrowserBench({ quiet = false } = {}) {
  const wasmPath = ensureWasm("ReleaseFast");
  const machine = machineInfo();
  const { server, origin } = await startStaticServer(wasmPath);
  const { browser, mode, executablePath } = await launchBrowser();
  const results = [];
  let header, adapter, pageErrors = [];
  try {
    const context = await browser.newContext({ viewport: { width: 1920, height: 1080 } });
    const page = await context.newPage();
    page.on("pageerror", (e) => pageErrors.push(String(e).split("\n")[0]));
    page.on("console", (m) => { if (m.type() === "error") pageErrors.push("console.error: " + m.text().slice(0, 160)); });
    const cdp = await context.newCDPSession(page);
    await cdp.send("HeapProfiler.enable");
    await page.goto(`${origin}/`, { waitUntil: "load" });
    adapter = await adapterInfo(page);
    header = formatHeader(machine, wasmInfo(wasmPath), {
      browser: `${executablePath} (${mode})`,
      adapter: adapter.available ? `${adapter.vendor}/${adapter.architecture}${adapter.description ? " " + adapter.description : ""}` : `NONE (${adapter.reason ?? "no navigator.gpu"})`,
      isolated: `${adapter.isolated} (performance.now resolution ≈ ${adapter.timerResolutionUs} µs)`,
    });
    if (!quiet) console.log(header);
    if (!adapter.available) throw new Error("no WebGPU adapter in this browser configuration");
    await waitForApp(page);
    await installProbes(page);

    // Warm-up: exercise every path once (JIT + lazy pipeline work), like asimov-happy's pre-warm.
    await page.evaluate(() => { const b = window.__morphoBench; b.reset(); b.stepBurst(200); b.mouse(-200, -200, true); b.stepBurst(30); b.mouse(0, 0, false); b.paintBlock({ cx: 0, cy: 400, cols: 10, rows: 1, spacing: 12, valence: 0 }); b.stepBurst(60); });
    await page.waitForTimeout(500);

    const sleep = (ms) => page.waitForTimeout(ms);
    for (const ph of PHASES) {
      const r = await measurePhase(page, cdp, ph.name, ph.ms, async () => {
        const b = "window.__morphoBench";
        switch (ph.name) {
          case "idle-paused":
            await page.evaluate(() => window.__morphoBench.setPaused(true)); await sleep(ph.ms); break;
          case "steady":
            await page.evaluate(() => { const b = window.__morphoBench; b.setPaused(true); b.reset(); b.stepBurst(600); b.setPaused(false); });
            await sleep(ph.ms); break;
          case "drag":
            await page.evaluate((ms) => { const b = window.__morphoBench; let t = 0; b.mouse(-200, -200, true);
              window.__morphoDrive = setInterval(() => { t += 16 / 300 * 2 * Math.PI; b.mouse(-200 + 100 * Math.cos(t), -200 + 100 * Math.sin(t), true); }, 16);
              setTimeout(() => { clearInterval(window.__morphoDrive); b.mouse(0, 0, false); }, ms); }, ph.ms);
            await sleep(ph.ms + 50); break;
          case "paint":
            await page.evaluate((ms) => { const b = window.__morphoBench; let x = -800;
              window.__morphoDrive = setInterval(() => { for (let k = 0; k < 3; k++) { b.paintBlock({ cx: x, cy: 450, cols: 1, rows: 1, spacing: 0, valence: 0 }); x += 6; if (x > 800) x = -800; } }, 16);
              setTimeout(() => clearInterval(window.__morphoDrive), ms); }, ph.ms);
            await sleep(ph.ms + 50); break;
          case "reset-storm":
            for (let i = 0; i < 5; i++) { await page.evaluate(() => window.__morphoBench.reset()); await sleep(400); }
            await page.evaluate(() => { const b = window.__morphoBench; b.mouse(-200, -200, true); b.stepBurst(5); });
            await sleep(300);
            break;
        }
      });
      r.desc = ph.desc;
      results.push(r);
      if (!quiet) console.log(`  ${ph.name.padEnd(12)} frames ${String(r.ring.frames).padStart(3)}  sim p50 ${fmtMs(r.ring.simMs.p50)}  upload ${fmtMs(r.ring.uploadMs.p50)}  submit ${fmtMs(r.ring.submitMs.p50)}  fps ${r.ring.fps.toFixed(0)}  APP alloc ${(r.heap.appBytesPerSec / 1024).toFixed(1)} KB/s  dom ${r.probes.domMutations}  grabs ${r.snap.grabs}`);
    }
    await page.evaluate(() => window.__morphoBench.mouse(0, 0, false));
  } finally {
    await browser.close();
    server.close();
  }
  return { header, machine, adapter, mode, results, pageErrors };
}

export function printBrowserResults(run) {
  const h = ["phase", "frames", "fps", "sim p50", "sim p95", "upload p50", "submit p50", "frame p95", "APP KB/s", "runtime KB/s", "DOM mut", "P", "S", "grabs"];
  const rows = run.results.map((r) => [r.name, r.ring.frames, r.ring.fps.toFixed(0), fmtMs(r.ring.simMs.p50), fmtMs(r.ring.simMs.p95), fmtMs(r.ring.uploadMs.p50), fmtMs(r.ring.submitMs.p50), fmtMs(r.ring.frameIntervalMs.p95), (r.heap.appBytesPerSec / 1024).toFixed(1), (r.heap.runtimeBytesPerSec / 1024).toFixed(1), r.probes.domMutations, r.snap.particles, r.snap.springs, r.snap.grabs]);
  console.log("\n== phases ==");
  console.log(padTable([h, ...rows], h.map((_, i) => (i ? "right" : "left"))).join("\n"));
  for (const r of run.results) {
    if (!r.heap.top.length) continue;
    console.log(`\n  top APP allocators — ${r.name}:`);
    for (const [k, b] of r.heap.top.slice(0, 6)) console.log(`    ${(b / 1024).toFixed(1).padStart(8)} KB  ${k}`);
    const src = Object.entries(r.probes.sources).sort((a, b) => b[1] - a[1]).slice(0, 3);
    if (src.length) console.log(`    DOM mutation sources: ${src.map(([k, v]) => `${k}×${v}`).join(", ")}`);
  }
  if (run.pageErrors.length) { console.log(`\n  page errors (${run.pageErrors.length}):`); for (const e of run.pageErrors.slice(0, 5)) console.log("    " + e); }
  return { h, rows };
}

const isMain = process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href;
if (isMain) {
  const argv = process.argv.slice(2);
  const opt = (n) => { const i = argv.indexOf(`--${n}`); return i >= 0 ? argv[i + 1] : null; };
  const run = await runBrowserBench();
  const { h, rows } = printBrowserResults(run);
  if (opt("json")) writeFileSync(opt("json"), JSON.stringify(run, null, 2));
  if (opt("md")) writeFileSync(opt("md"), ["```", run.header, "```", "", markdownTable(h, rows), ""].join("\n"));
}
