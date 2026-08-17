// Percentiles / medians / table formatting (mirrors asimov-happy's scaling + stats helpers).
export function percentile(sorted, p) {
  if (sorted.length === 0) return 0;
  const i = Math.floor(sorted.length * p);
  return sorted[Math.min(i, sorted.length - 1)];
}

export function dist(values) {
  if (values.length === 0) return { min: 0, p50: 0, p95: 0, p99: 0, max: 0, mean: 0, n: 0 };
  const s = values.slice().sort((a, b) => a - b);
  const mean = s.reduce((a, b) => a + b, 0) / s.length;
  return { min: s[0], p50: percentile(s, 0.5), p95: percentile(s, 0.95), p99: percentile(s, 0.99), max: s[s.length - 1], mean, n: s.length };
}

export function median(values) {
  return percentile(values.slice().sort((a, b) => a - b), 0.5);
}

export function fmtMs(v, digits = 3) {
  return Number.isFinite(v) ? v.toFixed(digits) : "n/a";
}

export function padTable(rows, aligns) {
  const widths = [];
  for (const row of rows) row.forEach((c, i) => { widths[i] = Math.max(widths[i] ?? 0, String(c).length); });
  return rows.map((row) => row.map((c, i) => {
    const s = String(c);
    return (aligns?.[i] ?? "left") === "right" ? s.padStart(widths[i]) : s.padEnd(widths[i]);
  }).join("  "));
}

export function markdownTable(header, rows) {
  const line = (r) => `| ${r.join(" | ")} |`;
  return [line(header), line(header.map(() => "---")), ...rows.map(line)].join("\n");
}

/** Interquartile range relative to the median (0 when < 4 samples). */
export function iqrRel(values) {
  if (values.length < 4) return 0;
  const s = values.slice().sort((a, b) => a - b);
  const m = percentile(s, 0.5);
  return m > 0 ? (percentile(s, 0.75) - percentile(s, 0.25)) / m : 0;
}
