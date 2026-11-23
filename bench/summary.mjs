#!/usr/bin/env node
import * as Fs from "node:fs"
import * as Path from "node:path"

const args = process.argv.slice(2)
let resultsDir = "bench/results"
let baselinePath = "bench/baseline.json"
let outMd = null
let outJson = null
let writeBaseline = false

for (let i = 0; i < args.length; i++) {
  const arg = args[i]
  if (arg === "--results-dir") resultsDir = args[++i]
  else if (arg === "--baseline") baselinePath = args[++i]
  else if (arg === "--out-md") outMd = args[++i]
  else if (arg === "--out-json") outJson = args[++i]
  else if (arg === "--write-baseline") writeBaseline = true
  else {
    console.error(`Unknown argument: ${arg}`)
    process.exit(2)
  }
}

const files = Fs.existsSync(resultsDir)
  ? Fs.readdirSync(resultsDir)
      .filter((f) => f.endsWith(".json") && f !== "all.json" && f !== "baseline.json")
      .sort()
  : []

if (files.length === 0) {
  console.error(`No benchmark JSON files found in ${resultsDir}`)
  process.exit(1)
}

const baseline = Fs.existsSync(baselinePath)
  ? JSON.parse(Fs.readFileSync(baselinePath, "utf8"))
  : { benchmarks: {} }
const baseMap = baseline.benchmarks ?? {}

const allBenchmarks = {}
const sections = []
let totalOk = 0
let totalFailed = 0
let totalUnavailable = 0

const formatDelta = (curr, prev) => {
  if (typeof prev !== "number" || prev <= 0 || typeof curr !== "number" || curr <= 0) return "—"
  const ratio = ((prev - curr) / prev) * 100
  if (Math.abs(ratio) < 1.0) return "~0%"
  if (prev / curr >= 2.0) return `${(prev / curr).toFixed(2)}x faster (+${ratio.toFixed(1)}%)`
  if (curr / prev >= 2.0) return `${(curr / prev).toFixed(2)}x slower (${ratio.toFixed(1)}%)`
  return ratio > 0 ? `+${ratio.toFixed(1)}% faster` : `${ratio.toFixed(1)}% slower`
}

for (const file of files) {
  const data = JSON.parse(Fs.readFileSync(Path.join(resultsDir, file), "utf8"))
  const suiteName = data.suite ?? Path.basename(file, ".json")
  const rows = data.results ?? []
  const lines = []
  lines.push(`### ${suiteName} (${data.optimize ?? "ReleaseFast"}, ${data.architecture ?? ""}/${data.os ?? ""})`)
  lines.push("")
  lines.push("| Benchmark | ns/op | Median ns | p95 ns | ops/sec | vs Baseline | Status |")
  lines.push("|:--|:--|--:|--:|--:|:--|:--|")

  for (const row of rows) {
    const key = row.mode ? `${row.name} [${row.mode}]` : row.name
    if (row.status === "ok" && row.statistics) {
      totalOk++
      const nsPerOp = row.ns_per_op ?? row.statistics.median_ns
      const prev = baseMap[key]?.ns_per_op
      const delta = formatDelta(nsPerOp, prev)
      allBenchmarks[key] = {
        suite: suiteName,
        ns_per_op: nsPerOp,
        median_ns: row.statistics.median_ns,
        mean_ns: row.statistics.mean_ns,
        p95_ns: row.statistics.p95_ns,
        ops_per_sec: row.statistics.ops_per_sec,
        mgas_per_sec: row.statistics.mgas_per_sec ?? null,
        gas_used: row.gas_used ?? null,
        status: row.status
      }
      lines.push(
        `| ${key} | ${nsPerOp.toFixed(2)} | ${row.statistics.median_ns.toFixed(1)} | ${row.statistics.p95_ns} | ${Math.round(row.statistics.ops_per_sec).toLocaleString("en-US")} | ${delta} | ok |`
      )
    } else if (row.status === "unavailable") {
      totalUnavailable++
      lines.push(`| ${key} | — | — | — | — | — | unavailable: ${row.reason ?? ""} |`)
    } else {
      totalFailed++
      lines.push(`| ${key} | — | — | — | — | — | failed: ${row.reason ?? ""} |`)
    }
  }
  sections.push(lines.join("\n"))
}

const header = [
  "# Guillotine Performance Benchmarks",
  "",
  `Suites: **${files.length}** | Passed: **${totalOk}** | Unavailable: **${totalUnavailable}** | Failed: **${totalFailed}**`,
  ""
].join("\n")

const md = `${header}\n${sections.join("\n\n")}\n`
process.stdout.write(md)

if (outMd) {
  Fs.mkdirSync(Path.dirname(outMd), { recursive: true })
  Fs.writeFileSync(outMd, md)
}

const snapshot = {
  schema_version: 1,
  generated_at: new Date().toISOString(),
  counts: { suites: files.length, ok: totalOk, unavailable: totalUnavailable, failed: totalFailed },
  benchmarks: allBenchmarks
}

if (outJson) {
  Fs.mkdirSync(Path.dirname(outJson), { recursive: true })
  Fs.writeFileSync(outJson, `${JSON.stringify(snapshot, null, 2)}\n`)
}

if (writeBaseline) {
  Fs.mkdirSync(Path.dirname(baselinePath), { recursive: true })
  Fs.writeFileSync(baselinePath, `${JSON.stringify(snapshot, null, 2)}\n`)
}

if (totalFailed > 0) process.exit(1)
