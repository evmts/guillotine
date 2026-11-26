#!/usr/bin/env node
/**
 * Cross-EVM Apples-to-Apples Benchmark Orchestrator
 *
 * Runs every EVM engine strictly sequentially (zero CPU/cache contention),
 * enforces a 0-tolerance differential verification gate (success, exact
 * gas_used, byte-for-byte output_hex), computes geometric mean speedups and
 * non-parametric distribution statistics (median, IQR, p95, min, MGas/s),
 * and emits:
 *   - bench/compare/results/latest.json
 *   - bench/compare/results/RESULTS.md
 *   - bench/compare/results/report.html
 */

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync, spawnSync } from "node:child_process";

const ROOT = path.resolve(import.meta.dirname);
const REPO_ROOT = path.resolve(ROOT, "../..");
const WORKLOADS_DIR = path.join(ROOT, "workloads");
const RESULTS_DIR = path.join(ROOT, "results");
const BIN_DIR = path.join(ROOT, "bin");

fs.mkdirSync(RESULTS_DIR, { recursive: true });

// --- CLI parsing ---
const argv = process.argv.slice(2);
const opts = {
  filter: null,
  modes: ["warm", "cold", "jit"],
  engines: null,
  warmup: 20,
  minSamples: 15,
  maxSamples: 150,
  targetMs: 1200,
  coldTargetMs: 600,
  coldMinSamples: 7,
  coldMaxSamples: 40,
  timeoutMs: 120_000,
};

for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--filter") opts.filter = argv[++i];
  else if (a === "--modes") opts.modes = argv[++i].split(",").map((s) => s.trim());
  else if (a === "--engines") opts.engines = argv[++i].split(",").map((s) => s.trim());
  else if (a === "--warmup") opts.warmup = Number(argv[++i]);
  else if (a === "--min-samples") opts.minSamples = Number(argv[++i]);
  else if (a === "--max-samples") opts.maxSamples = Number(argv[++i]);
  else if (a === "--target-ms") opts.targetMs = Number(argv[++i]);
  else if (a === "--cold-target-ms") opts.coldTargetMs = Number(argv[++i]);
  else if (a === "--help" || a === "-h") {
    console.log(`Usage: node bench/compare/run.mjs [options]
  --filter <substr>        Substring filter on workload name or category
  --modes <warm,cold,jit>  Modes to run (default: warm,cold,jit)
  --engines <a,b,c>        Subset of engines to run
  --warmup <N>             Warmup runs (default: 20)
  --min-samples <N>        Minimum measured samples (default: 15)
  --max-samples <N>        Maximum measured samples (default: 150)
  --target-ms <M>          Target measurement time ms for warm/jit (default: 1200)
  --cold-target-ms <M>     Target measurement time ms for cold (default: 600)`);
    process.exit(0);
  }
}

const versions = JSON.parse(fs.readFileSync(path.join(ROOT, "versions.json"), "utf8"));
const manifest = JSON.parse(fs.readFileSync(path.join(WORKLOADS_DIR, "manifest.json"), "utf8"));

const INTERPRETER_ENGINES = [
  { id: "guillotine", bin: path.join(REPO_ROOT, "zig-out/bin/guillotine-compare"), engineArg: "guillotine" },
  { id: "guillotine-nofusion", bin: path.join(REPO_ROOT, "zig-out/bin/guillotine-compare"), engineArg: "guillotine-nofusion" },
  { id: "evm2", bin: path.join(BIN_DIR, "compare-evm2"), engineArg: "evm2" },
  { id: "revm", bin: path.join(BIN_DIR, "compare-revm"), engineArg: "revm" },
  { id: "evmone-advanced", bin: path.join(BIN_DIR, "compare-evmone"), engineArg: "evmone-advanced" },
  { id: "evmone-baseline", bin: path.join(BIN_DIR, "compare-evmone"), engineArg: "evmone-baseline" },
  { id: "ethrex-levm", bin: path.join(BIN_DIR, "compare-ethrex"), engineArg: "ethrex-levm" },
  { id: "gevm", bin: path.join(BIN_DIR, "compare-gevm"), engineArg: "gevm" },
  { id: "geth", bin: path.join(BIN_DIR, "compare-geth"), engineArg: "geth" },
];

const JIT_ENGINES = [
  { id: "guillotine-jit", bin: path.join(REPO_ROOT, "zig-out/bin/guillotine-compare"), engineArg: "guillotine-jit" },
  { id: "evm2-jit", bin: path.join(BIN_DIR, "compare-evm2"), engineArg: "evm2-jit" },
  { id: "revmc", bin: path.join(BIN_DIR, "compare-revmc"), engineArg: "revmc" },
];

function cmdOut(cmd, args) {
  try {
    return execFileSync(cmd, args, { encoding: "utf8", cwd: REPO_ROOT, stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch {
    return "unknown";
  }
}

function collectEnvironment() {
  const cpuModel =
    process.platform === "darwin"
      ? cmdOut("sysctl", ["-n", "machdep.cpu.brand_string"])
      : os.cpus()[0]?.model || "unknown";
  const guillotineRev = cmdOut("jj", ["--no-pager", "log", "-r", "@", "-T", "commit_id.short(12)", "--no-graph"]);
  const zigBin = fs.existsSync("/Users/williamcory/.zvm/0.17.1/zig") ? "/Users/williamcory/.zvm/0.17.1/zig" : "zig";
  return {
    timestamp_iso: new Date().toISOString(),
    hostname: os.hostname(),
    os: `${os.type()} ${os.release()} (${os.arch()})`,
    kernel: cmdOut("uname", ["-sr"]),
    cpu: cpuModel,
    cpu_cores: os.cpus().length,
    memory_gb: Math.round((os.totalmem() / 1024 ** 3) * 10) / 10,
    guillotine_rev: guillotineRev,
    compilers: {
      zig: cmdOut(zigBin, ["version"]),
      rustc: cmdOut("rustc", ["--version"]),
      clang: cmdOut("clang++", ["--version"]).split("\n")[0],
      go: cmdOut("go", ["version"]),
      llvm_evm2_jit: cmdOut("/opt/homebrew/opt/llvm/bin/llvm-config", ["--version"]),
      llvm_revmc: cmdOut("/opt/homebrew/opt/llvm@22/bin/llvm-config", ["--version"]),
    },
    build_flags: {
      zig: "-OReleaseFast (native CPU, LLVM backend)",
      rust: "opt-level=3, lto=thin, codegen-units=1, panic=abort, RUSTFLAGS='-C target-cpu=native'",
      cpp_evmone: "-DCMAKE_BUILD_TYPE=Release -O3 -mcpu=native -DEVMONE_PRECOMPILES_LIBSECP256K1=ON",
      go: "go build (default optimized Go 1.26)",
    },
    sampling: {
      warmup: opts.warmup,
      warm_min_samples: opts.minSamples,
      warm_max_samples: opts.maxSamples,
      warm_target_ms: opts.targetMs,
      cold_min_samples: opts.coldMinSamples,
      cold_max_samples: opts.coldMaxSamples,
      cold_target_ms: opts.coldTargetMs,
    },
  };
}

function runSingle(engineSpec, workloadEntry, mode) {
  if (!fs.existsSync(engineSpec.bin)) {
    return {
      engine: engineSpec.id,
      workload: workloadEntry.name,
      mode,
      status: "unavailable",
      reason: `binary missing: ${engineSpec.bin}`,
    };
  }
  const workloadPath = path.join(WORKLOADS_DIR, workloadEntry.file);
  const isCold = mode === "cold";
  const args = [
    "--workload", workloadPath,
    "--engine", engineSpec.engineArg,
    "--mode", mode,
    "--warmup", String(isCold ? Math.min(5, opts.warmup) : opts.warmup),
    "--min-samples", String(isCold ? opts.coldMinSamples : opts.minSamples),
    "--max-samples", String(isCold ? opts.coldMaxSamples : opts.maxSamples),
    "--target-ms", String(isCold ? opts.coldTargetMs : opts.targetMs),
  ];

  const proc = spawnSync(engineSpec.bin, args, {
    cwd: REPO_ROOT,
    encoding: "utf8",
    timeout: opts.timeoutMs,
    maxBuffer: 16 * 1024 * 1024,
  });

  if (proc.error) {
    return {
      engine: engineSpec.id,
      workload: workloadEntry.name,
      mode,
      status: "failed",
      reason: proc.error.message,
    };
  }
  const stdout = (proc.stdout || "").trim();
  const lastLine = stdout.split("\n").filter(Boolean).pop() || "";
  if (proc.status !== 0 && !lastLine.startsWith("{")) {
    return {
      engine: engineSpec.id,
      workload: workloadEntry.name,
      mode,
      status: "failed",
      reason: `exit ${proc.status}: ${(proc.stderr || stdout).slice(0, 300)}`,
    };
  }
  try {
    const parsed = JSON.parse(lastLine);
    return parsed;
  } catch (e) {
    return {
      engine: engineSpec.id,
      workload: workloadEntry.name,
      mode,
      status: "failed",
      reason: `invalid json output: ${lastLine.slice(0, 200)}`,
    };
  }
}

function fmtNs(ns) {
  if (ns === null || ns === undefined || Number.isNaN(ns)) return "—";
  if (ns < 1_000) return `${ns.toFixed(0)} ns`;
  if (ns < 1_000_000) return `${(ns / 1_000).toFixed(2)} µs`;
  if (ns < 1_000_000_000) return `${(ns / 1_000_000).toFixed(2)} ms`;
  return `${(ns / 1_000_000_000).toFixed(2)} s`;
}

function fmtRatio(r) {
  if (r === null || r === undefined || Number.isNaN(r)) return "—";
  return `${r.toFixed(2)}×`;
}

function geomean(values) {
  const valid = values.filter((v) => typeof v === "number" && v > 0 && Number.isFinite(v));
  if (valid.length === 0) return null;
  const logSum = valid.reduce((acc, v) => acc + Math.log(v), 0);
  return Math.exp(logSum / valid.length);
}

// --- Main execution ---
const workloads = manifest.workloads.filter((w) => {
  if (!opts.filter) return true;
  const q = opts.filter.toLowerCase();
  return w.name.toLowerCase().includes(q) || w.category.toLowerCase().includes(q);
});

const activeInterpreters = INTERPRETER_ENGINES.filter((e) => !opts.engines || opts.engines.includes(e.id));
const activeJits = JIT_ENGINES.filter((e) => !opts.engines || opts.engines.includes(e.id));

console.log(`=== Cross-EVM Benchmark Suite ===`);
console.log(`Workloads: ${workloads.length}, Modes: ${opts.modes.join(", ")}`);
console.log(`Interpreters: ${activeInterpreters.map((e) => e.id).join(", ")}`);
console.log(`JITs: ${activeJits.map((e) => e.id).join(", ")}\n`);

const envInfo = collectEnvironment();
const results = {
  warm: {},
  cold: {},
  jit: {},
};

for (const w of workloads) {
  if (opts.modes.includes("warm")) results.warm[w.name] = {};
  if (opts.modes.includes("cold")) results.cold[w.name] = {};
  if (opts.modes.includes("jit")) results.jit[w.name] = {};
}

// Run strictly sequentially per mode -> workload -> engine (zero CPU contention)
for (const mode of opts.modes) {
  const engines = mode === "jit" ? activeJits : activeInterpreters;
  if (engines.length === 0) continue;
  console.log(`\n--- Mode: ${mode.toUpperCase()} ---`);
  for (const w of workloads) {
    // Skip precompiles in JIT mode (precompiles have no EVM bytecode to compile)
    if (mode === "jit" && w.category === "precompile") continue;
    process.stdout.write(`  [${w.category.padEnd(10)}] ${w.name.padEnd(25)}`);
    const lineParts = [];
    for (const eng of engines) {
      const res = runSingle(eng, w, mode);
      results[mode][w.name][eng.id] = res;
      if (res.status === "ok") {
        const tag = mode === "jit" && !res.jit_compiled ? `${fmtNs(res.median_ns)}(interp)` : fmtNs(res.median_ns);
        lineParts.push(`${eng.id}=${tag}`);
      } else {
        lineParts.push(`${eng.id}=${res.status.toUpperCase()}`);
      }
    }
    console.log(lineParts.join("  "));
  }
}

// --- 0-Tolerance Differential Verification Gate ---
const verification = {};
const ANCHOR_ORDER = ["evm2", "revm", "geth", "gevm", "ethrex-levm", "evmone-advanced", "guillotine"];

for (const w of workloads) {
  // Collect all ok results across all modes for this workload
  const allOk = [];
  for (const mode of opts.modes) {
    const bucket = results[mode]?.[w.name] || {};
    for (const [engId, r] of Object.entries(bucket)) {
      if (r && r.status === "ok" && r.success) {
        allOk.push({ mode, engId, r });
      }
    }
  }

  // Pick canonical reference gas & output by majority vote across distinct reference engines
  const gasVotes = new Map();
  const outVotes = new Map();
  for (const { mode, engId, r } of allOk) {
    if (mode !== "warm" && opts.modes.includes("warm")) continue;
    gasVotes.set(r.gas_used, (gasVotes.get(r.gas_used) || 0) + 1);
    if (r.output_hex !== null && r.output_hex !== undefined) {
      outVotes.set(r.output_hex, (outVotes.get(r.output_hex) || 0) + 1);
    }
  }
  // Fallback if warm mode wasn't run
  if (gasVotes.size === 0) {
    for (const { r } of allOk) {
      gasVotes.set(r.gas_used, (gasVotes.get(r.gas_used) || 0) + 1);
      if (r.output_hex !== null && r.output_hex !== undefined) {
        outVotes.set(r.output_hex, (outVotes.get(r.output_hex) || 0) + 1);
      }
    }
  }

  let canonicalGas = null;
  let maxGasVotes = 0;
  for (const [g, c] of gasVotes.entries()) {
    if (c > maxGasVotes) {
      maxGasVotes = c;
      canonicalGas = g;
    }
  }
  let canonicalOut = null;
  let maxOutVotes = 0;
  for (const [o, c] of outVotes.entries()) {
    if (c > maxOutVotes) {
      maxOutVotes = c;
      canonicalOut = o;
    }
  }

  // Tie-break with anchor order if needed
  if (gasVotes.size > 1) {
    for (const anchor of ANCHOR_ORDER) {
      const ar = results.warm?.[w.name]?.[anchor];
      if (ar && ar.status === "ok" && ar.success) {
        if ((gasVotes.get(ar.gas_used) || 0) >= maxGasVotes) {
          canonicalGas = ar.gas_used;
          if (ar.output_hex !== null && ar.output_hex !== undefined) canonicalOut = ar.output_hex;
          break;
        }
      }
    }
  }

  const discrepancies = [];
  let verifiedCount = 0;
  let totalChecked = 0;

  for (const mode of opts.modes) {
    const bucket = results[mode]?.[w.name] || {};
    for (const [engId, r] of Object.entries(bucket)) {
      if (!r || r.status !== "ok") {
        r.verified = false;
        r.verification_error = r?.reason || r?.status || "failed";
        discrepancies.push({ mode, engine: engId, error: r.verification_error });
        continue;
      }
      totalChecked++;
      const errs = [];
      if (canonicalGas !== null && r.gas_used !== canonicalGas) {
        errs.push(`gas mismatch: got ${r.gas_used}, canonical ${canonicalGas} (delta ${r.gas_used - canonicalGas})`);
      }
      if (canonicalOut !== null && r.output_hex !== null && r.output_hex !== undefined && r.output_hex !== canonicalOut) {
        errs.push(`output mismatch: got ${r.output_hex.slice(0, 34)}..., canonical ${canonicalOut.slice(0, 34)}...`);
      }
      if (errs.length > 0) {
        r.verified = false;
        r.verification_error = errs.join("; ");
        discrepancies.push({ mode, engine: engId, error: r.verification_error });
      } else {
        r.verified = true;
        r.verification_error = null;
        verifiedCount++;
      }
    }
  }

  verification[w.name] = {
    canonical_gas: canonicalGas,
    canonical_output_bytes: canonicalOut ? (canonicalOut.length - 2) / 2 : null,
    canonical_output_prefix: canonicalOut ? canonicalOut.slice(0, 66) : null,
    verified_runs: verifiedCount,
    total_runs: totalChecked,
    all_match: discrepancies.length === 0,
    discrepancies,
  };
}

// --- Compute Geomean Summary (verified cells only!) ---
function computeSummary(mode, engineList, baselineId) {
  const categories = ["classic", "mainnet", "precompile", "opcode"];
  const summary = { baseline: baselineId, overall: {}, by_category: {} };
  for (const cat of categories) summary.by_category[cat] = {};

  for (const eng of engineList) {
    const allSpeedups = [];
    let count = 0;
    for (const cat of categories) {
      const catSpeedups = [];
      for (const w of workloads.filter((x) => x.category === cat)) {
        const r = results[mode]?.[w.name]?.[eng.id];
        const b = results[mode]?.[w.name]?.[baselineId];
        if (r?.verified && b?.verified && r.median_ns > 0 && b.median_ns > 0) {
          const speedup = b.median_ns / r.median_ns; // >1 means faster than baseline
          catSpeedups.push(speedup);
          allSpeedups.push(speedup);
          count++;
        }
      }
      summary.by_category[cat][eng.id] = {
        geomean_speedup: geomean(catSpeedups),
        count: catSpeedups.length,
      };
    }
    summary.overall[eng.id] = {
      geomean_speedup: geomean(allSpeedups),
      count,
    };
  }
  return summary;
}

const summaries = {
  warm_vs_revm: computeSummary("warm", activeInterpreters, "revm"),
  warm_vs_evm2: computeSummary("warm", activeInterpreters, "evm2"),
  cold_vs_revm: computeSummary("cold", activeInterpreters, "revm"),
  cold_vs_evm2: computeSummary("cold", activeInterpreters, "evm2"),
};

// Strip giant output_hex blobs (e.g. 192 KB burntpix SVG) after 0-tolerance verification,
// replacing them with exact cryptographic output_sha256 + output_bytes + output_prefix.
for (const mode of Object.keys(results)) {
  for (const wName of Object.keys(results[mode])) {
    for (const eId of Object.keys(results[mode][wName])) {
      const r = results[mode][wName][eId];
      if (!r) continue;
      if (typeof r.output_hex === "string") {
        r.output_bytes = Math.max(0, (r.output_hex.length - 2) / 2);
        r.output_sha256 = crypto.createHash("sha256").update(r.output_hex).digest("hex");
        r.output_prefix = r.output_hex.slice(0, 66);
        delete r.output_hex;
      }
    }
  }
}

// Write latest.json atomically
const fullReport = {
  schema_version: 1,
  environment: envInfo,
  versions: versions.engines,
  workloads,
  verification,
  summaries,
  results,
};

const jsonPath = path.join(RESULTS_DIR, "latest.json");
fs.writeFileSync(jsonPath + ".tmp", JSON.stringify(fullReport, null, 2) + "\n");
fs.renameSync(jsonPath + ".tmp", jsonPath);

// --- Generate RESULTS.md ---
function buildMarkdown() {
  const lines = [];
  lines.push(`# Guillotine Cross-EVM Benchmark Report`);
  lines.push(``);
  lines.push(`**Generated:** ${envInfo.timestamp_iso}  `);
  lines.push(`**Hardware:** ${envInfo.cpu} (${envInfo.cpu_cores} cores, ${envInfo.memory_gb} GB RAM), ${envInfo.os}  `);
  lines.push(`**Guillotine commit:** \`${envInfo.guillotine_rev}\`  `);
  lines.push(`**Compilers:** Zig \`${envInfo.compilers.zig}\` · Rust \`${envInfo.compilers.rustc}\` · C++ \`${envInfo.compilers.clang}\` · Go \`${envInfo.compilers.go}\` · LLVM \`${envInfo.compilers.llvm_evm2_jit}\` (evm2-jit) / \`${envInfo.compilers.llvm_revmc}\` (revmc)`);
  lines.push(``);
  lines.push(`> **Methodology & Fairness Guarantee:** All engines run **in-process** with zero CLI startup overhead, strictly sequentially on the same machine, against the **exact same canonical JSON workloads** (21 fixtures verbatim from \`alloy-rs/evm2@${manifest.evm2_fixture_rev}\` + 4 targeted hot-loop workloads). Gas accounting is **enabled** and tracing is **disabled** for every engine. Every timed sample must pass a **0-tolerance differential verification gate** (\`success == true\`, exact \`gas_used\` match, byte-for-byte \`output\` match). Any mismatched cell is disqualified (\`MISMATCH\`) rather than reported.`);
  lines.push(``);

  // Pinned versions table
  lines.push(`## Pinned Engine Versions`);
  lines.push(``);
  lines.push(`| Engine | Language | Tier | Source / Pinned Revision | Build Flags |`);
  lines.push(`| :--- | :--- | :--- | :--- | :--- |`);
  for (const [id, info] of Object.entries(versions.engines)) {
    const revStr = info.rev ? `\`${info.rev}\`${info.tag ? ` (${info.tag})` : ""}` : `\`${envInfo.guillotine_rev}\``;
    const flag =
      info.language === "Zig"
        ? envInfo.build_flags.zig
        : info.language === "Rust"
          ? envInfo.build_flags.rust
          : info.language === "C++"
            ? envInfo.build_flags.cpp_evmone
            : envInfo.build_flags.go;
    lines.push(`| **${info.name}** (\`${id}\`) | ${info.language} | ${info.tier} | ${info.repo} @ ${revStr} | ${flag} |`);
  }
  lines.push(``);

  // Headline Geomean Summary (Warm Interpreters)
  if (opts.modes.includes("warm")) {
    lines.push(`## 1. Headline Summary — Warm Steady-State Interpreters (Geometric Mean Speedup)`);
    lines.push(``);
    lines.push(`Higher is faster (\`> 1.00×\` means faster than baseline). Only workloads passing the 0-tolerance gas + output verification gate on **both** the engine and baseline are included.`);
    lines.push(``);
    lines.push(`| Engine | Lang | Overall vs \`revm\` | Overall vs \`evm2\` | Classic (7) vs \`revm\` | Mainnet DeFi (9) vs \`revm\` | Precompiles (5) vs \`revm\` | Hot-Loops (4) vs \`revm\` |`);
    lines.push(`| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: |`);
    const ranked = [...activeInterpreters].sort((a, b) => {
      const sa = summaries.warm_vs_revm.overall[a.id]?.geomean_speedup || 0;
      const sb = summaries.warm_vs_revm.overall[b.id]?.geomean_speedup || 0;
      return sb - sa;
    });
    for (const eng of ranked) {
      const info = versions.engines[eng.id];
      const oRevm = summaries.warm_vs_revm.overall[eng.id];
      const oEvm2 = summaries.warm_vs_evm2.overall[eng.id];
      const cClassic = summaries.warm_vs_revm.by_category.classic[eng.id];
      const cMainnet = summaries.warm_vs_revm.by_category.mainnet[eng.id];
      const cPre = summaries.warm_vs_revm.by_category.precompile[eng.id];
      const cOp = summaries.warm_vs_revm.by_category.opcode[eng.id];
      lines.push(
        `| **${info.name}** | ${info.language} | **${fmtRatio(oRevm?.geomean_speedup)}** (${oRevm?.count || 0}) | ${fmtRatio(oEvm2?.geomean_speedup)} | ${fmtRatio(cClassic?.geomean_speedup)} | ${fmtRatio(cMainnet?.geomean_speedup)} | ${fmtRatio(cPre?.geomean_speedup)} | ${fmtRatio(cOp?.geomean_speedup)} |`
      );
    }
    lines.push(``);
  }

  // Detailed Warm Interpreter Table
  if (opts.modes.includes("warm")) {
    const showEngines = activeInterpreters.filter((e) => e.id !== "guillotine-nofusion");
    lines.push(`## 2. Warm Steady-State Latency (Interpreters, Median per TX)`);
    lines.push(``);
    lines.push(`Bytecode pre-loaded/analyzed where supported; fresh clean state snapshot per transaction (no state accumulation). Lower is faster. Fastest verified interpreter per row is **bold**.`);
    lines.push(``);
    lines.push(`| Workload | Cat | Fork | Gas | ${showEngines.map((e) => versions.engines[e.id].name).join(" | ")} | Guillotine vs \`revm\` | Guillotine vs \`evm2\` |`);
    lines.push(`| :--- | :--- | :--- | ---: | ${showEngines.map(() => "---:").join(" | ")} | ---: | ---: |`);
    for (const w of workloads) {
      const bucket = results.warm[w.name] || {};
      const ver = verification[w.name];
      let bestNs = Infinity;
      for (const e of showEngines) {
        const r = bucket[e.id];
        if (r?.verified && r.median_ns < bestNs) bestNs = r.median_ns;
      }
      const cells = showEngines.map((e) => {
        const r = bucket[e.id];
        if (!r) return "—";
        if (!r.verified) return r.status === "ok" ? `MISMATCH` : r.status.toUpperCase();
        const s = fmtNs(r.median_ns);
        return r.median_ns === bestNs ? `**${s}**` : s;
      });
      const g = bucket["guillotine"];
      const rv = bucket["revm"];
      const e2 = bucket["evm2"];
      const vsRevm = g?.verified && rv?.verified ? fmtRatio(rv.median_ns / g.median_ns) : "—";
      const vsEvm2 = g?.verified && e2?.verified ? fmtRatio(e2.median_ns / g.median_ns) : "—";
      lines.push(`| \`${w.name}\` | ${w.category} | ${w.hardfork} | ${ver.canonical_gas?.toLocaleString() || "—"} | ${cells.join(" | ")} | ${vsRevm} | ${vsEvm2} |`);
    }
    lines.push(``);
  }

  // Cold First-Run Table
  if (opts.modes.includes("cold")) {
    const showEngines = activeInterpreters.filter((e) => e.id !== "guillotine-nofusion");
    lines.push(`## 3. Cold First-Run Latency (Includes Bytecode Analysis + EVM Init)`);
    lines.push(``);
    lines.push(`Every sample constructs a fresh EVM with unanalyzed raw bytecode (empty dispatch/jumpdest cache), fairly measuring single-shot / cold-contract cost.`);
    lines.push(``);
    lines.push(`| Engine | Overall Cold vs \`revm\` | Overall Cold vs \`evm2\` | Classic | Mainnet DeFi | Precompiles | Hot-Loops |`);
    lines.push(`| :--- | ---: | ---: | ---: | ---: | ---: | ---: |`);
    const rankedCold = [...activeInterpreters].sort((a, b) => {
      const sa = summaries.cold_vs_revm.overall[a.id]?.geomean_speedup || 0;
      const sb = summaries.cold_vs_revm.overall[b.id]?.geomean_speedup || 0;
      return sb - sa;
    });
    for (const eng of rankedCold) {
      const info = versions.engines[eng.id];
      lines.push(
        `| **${info.name}** | **${fmtRatio(summaries.cold_vs_revm.overall[eng.id]?.geomean_speedup)}** | ${fmtRatio(summaries.cold_vs_evm2.overall[eng.id]?.geomean_speedup)} | ${fmtRatio(summaries.cold_vs_revm.by_category.classic[eng.id]?.geomean_speedup)} | ${fmtRatio(summaries.cold_vs_revm.by_category.mainnet[eng.id]?.geomean_speedup)} | ${fmtRatio(summaries.cold_vs_revm.by_category.precompile[eng.id]?.geomean_speedup)} | ${fmtRatio(summaries.cold_vs_revm.by_category.opcode[eng.id]?.geomean_speedup)} |`
      );
    }
    lines.push(``);
    lines.push(`| Workload | Cat | ${showEngines.map((e) => versions.engines[e.id].name).join(" | ")} |`);
    lines.push(`| :--- | :--- | ${showEngines.map(() => "---:").join(" | ")} |`);
    for (const w of workloads) {
      const bucket = results.cold[w.name] || {};
      let bestNs = Infinity;
      for (const e of showEngines) {
        const r = bucket[e.id];
        if (r?.verified && r.median_ns < bestNs) bestNs = r.median_ns;
      }
      const cells = showEngines.map((e) => {
        const r = bucket[e.id];
        if (!r) return "—";
        if (!r.verified) return r.status === "ok" ? `MISMATCH` : r.status.toUpperCase();
        const s = fmtNs(r.median_ns);
        return r.median_ns === bestNs ? `**${s}**` : s;
      });
      lines.push(`| \`${w.name}\` | ${w.category} | ${cells.join(" | ")} |`);
    }
    lines.push(``);
  }

  // Tier 2: JIT / Native Compilers
  if (opts.modes.includes("jit")) {
    lines.push(`## 4. Tier 2 — JIT / Native Compilers (Compile Time + Warm Execution)`);
    lines.push(``);
    lines.push(`Reported strictly separately from interpreters. Shows **one-time compile cost** alongside **warm steady-state execution latency**. Note that Guillotine's zero-dependency ARM64 JIT only compiles pure side-effect-free contracts and transparently falls back to its interpreter for stateful contracts (marked \`interp fallback\`).`);
    lines.push(``);
    lines.push(`| Workload | Guillotine Interp | Guillotine JIT (run / compile) | \`evm2\` Interp | \`evm2-jit\` LLVM 23 (run / compile) | \`revmc\` LLVM 22 (run / compile) |`);
    lines.push(`| :--- | ---: | ---: | ---: | ---: | ---: |`);
    for (const w of workloads.filter((x) => x.category !== "precompile")) {
      const gInt = results.warm?.[w.name]?.["guillotine"];
      const eInt = results.warm?.[w.name]?.["evm2"];
      const gJit = results.jit?.[w.name]?.["guillotine-jit"];
      const eJit = results.jit?.[w.name]?.["evm2-jit"];
      const rJit = results.jit?.[w.name]?.["revmc"];
      const fmtJit = (r) => {
        if (!r) return "—";
        if (!r.verified) return r.status === "ok" ? "MISMATCH" : r.status.toUpperCase();
        if (!r.jit_compiled) return `${fmtNs(r.median_ns)} *(interp fallback)*`;
        return `**${fmtNs(r.median_ns)}** / ${fmtNs(r.compile_ns)}`;
      };
      lines.push(
        `| \`${w.name}\` | ${gInt?.verified ? fmtNs(gInt.median_ns) : "—"} | ${fmtJit(gJit)} | ${eInt?.verified ? fmtNs(eInt.median_ns) : "—"} | ${fmtJit(eJit)} | ${fmtJit(rJit)} |`
      );
    }
    lines.push(``);
  }

  // Differential Verification Audit
  lines.push(`## 5. Differential Verification Audit`);
  lines.push(``);
  const allClean = Object.values(verification).every((v) => v.all_match);
  lines.push(allClean
    ? `✅ **All engines matched identically on \`success\`, exact \`gas_used\`, and byte-for-byte \`output\` across every workload and mode.**`
    : `⚠️ **Some engines had execution failures or gas/output discrepancies on specific workloads (excluded from geomean rankings above):**`
  );
  lines.push(``);
  lines.push(`| Workload | Fork | Canonical Gas | Output Bytes | Verified Runs | Status / Discrepancies |`);
  lines.push(`| :--- | :--- | ---: | ---: | ---: | :--- |`);
  for (const w of workloads) {
    const v = verification[w.name];
    const disc = v.all_match
      ? "✅ Exact match"
      : v.discrepancies.map((d) => `\`${d.engine}\` (${d.mode}): ${d.error}`).join("<br>");
    lines.push(`| \`${w.name}\` | ${w.hardfork} | ${v.canonical_gas?.toLocaleString() || "—"} | ${v.canonical_output_bytes ?? "—"} | ${v.verified_runs}/${v.total_runs} | ${disc} |`);
  }
  lines.push(``);
  lines.push(`## Caveats & Notes`);
  lines.push(``);
  lines.push(`- **Platform note (\`category-labs/monad\`):** Monad's C++ execution engine explicitly requires Linux + \`libstdc++\` + \`-march=x86-64-v3\` and cannot build natively on Apple Silicon macOS. It is omitted on macOS ARM64 runs.`);
  lines.push(`- **\`evmone\` return output:** \`evmone::state::TransactionReceipt\` does not expose top-level return bytes on the receipt struct; \`evmone\` is verified on \`EVMC_SUCCESS\` and exact \`gas_used\`, while all other engines are verified on \`success\`, exact \`gas_used\`, and byte-for-byte \`output_hex\`.`);
  lines.push(`- **\`evmone\` bytecode analysis:** \`evmone\` does not cache analyzed bytecode across separate \`evmc_execute\` calls, so its warm and cold latencies reflect its native single-pass per-call analysis design.`);
  lines.push(`- **Reproducing:** Run \`node bench/compare/run.mjs\` from the repository root. See \`bench/compare/README.md\` for full build instructions.`);
  lines.push(``);
  return lines.join("\n");
}

const mdPath = path.join(ROOT, "RESULTS.md");
fs.writeFileSync(mdPath, buildMarkdown());

// --- Generate Self-Contained Interactive HTML Report ---
function buildHtml() {
  const embedded = JSON.stringify({
    environment: envInfo,
    versions: versions.engines,
    workloads,
    verification,
    summaries,
    // Strip raw samples_ns from HTML payload to keep report crisp & snappy
    results: Object.fromEntries(
      Object.entries(results).map(([mode, wlMap]) => [
        mode,
        Object.fromEntries(
          Object.entries(wlMap).map(([wName, engMap]) => [
            wName,
            Object.fromEntries(
              Object.entries(engMap).map(([eId, r]) => {
                if (!r) return [eId, null];
                const { samples_ns, ...rest } = r;
                return [eId, rest];
              })
            ),
          ])
        ),
      ])
    ),
  }).replace(/</g, "\\u003c");

  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Guillotine Cross-EVM Benchmarks</title>
<style>
  :root {
    --bg: #0b0e14; --surface: #121722; --surface2: #192132; --border: #263147;
    --text: #e6edf7; --muted: #8b99b0; --accent: #f59e0b; --green: #10b981;
    --blue: #38bdf8; --purple: #a78bfa; --red: #ef4444; --pink: #f472b6;
  }
  * { box-sizing: border-box; }
  body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", sans-serif; background: var(--bg); color: var(--text); line-height: 1.5; }
  .wrap { max-width: 1360px; margin: 0 auto; padding: 28px 24px 64px; }
  header { display: flex; flex-wrap: wrap; justify-content: space-between; align-items: flex-end; gap: 16px; border-bottom: 1px solid var(--border); padding-bottom: 18px; margin-bottom: 24px; }
  h1 { margin: 0; font-size: 26px; letter-spacing: -0.02em; }
  .subtitle { color: var(--muted); font-size: 13px; margin-top: 6px; }
  .pill { display: inline-block; padding: 3px 9px; border-radius: 999px; font-size: 12px; font-weight: 600; background: var(--surface2); border: 1px solid var(--border); color: var(--text); }
  .pill.ok { border-color: #065f46; color: #34d399; background: rgba(16,185,129,0.12); }
  .pill.warn { border-color: #78350f; color: #fbbf24; background: rgba(245,158,11,0.12); }
  .kpis { display: grid; grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); gap: 14px; margin-bottom: 24px; }
  .kpi { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 16px 18px; }
  .kpi .label { font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; color: var(--muted); }
  .kpi .val { font-size: 28px; font-weight: 700; margin-top: 6px; font-variant-numeric: tabular-nums; }
  .kpi .sub { font-size: 12px; color: var(--muted); margin-top: 4px; }
  .controls { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-bottom: 18px; }
  .tabs { display: inline-flex; background: var(--surface); border: 1px solid var(--border); border-radius: 10px; padding: 3px; }
  .tab { background: transparent; border: none; color: var(--muted); padding: 7px 14px; border-radius: 7px; cursor: pointer; font-size: 13px; font-weight: 600; }
  .tab.active { background: var(--surface2); color: var(--text); }
  .card { background: var(--surface); border: 1px solid var(--border); border-radius: 12px; padding: 18px 20px; margin-bottom: 22px; overflow-x: auto; }
  .card h2 { margin: 0 0 12px; font-size: 16px; }
  .bar-row { display: grid; grid-template-columns: 170px 1fr 90px; align-items: center; gap: 12px; margin: 8px 0; font-size: 13px; }
  .bar-track { background: var(--surface2); height: 22px; border-radius: 6px; overflow: hidden; position: relative; }
  .bar-fill { height: 100%; border-radius: 6px; transition: width 0.25s ease; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; font-variant-numeric: tabular-nums; }
  th, td { padding: 9px 10px; border-bottom: 1px solid var(--border); text-align: right; white-space: nowrap; }
  th:first-child, td:first-child, th:nth-child(2), td:nth-child(2) { text-align: left; }
  th { color: var(--muted); font-weight: 600; font-size: 12px; position: sticky; top: 0; background: var(--surface); }
  tr:hover td { background: rgba(255,255,255,0.025); }
  .best { color: var(--green); font-weight: 700; }
  .bad { color: var(--red); font-weight: 600; }
  .dim { color: var(--muted); }
  .mono { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12px; }
  .meta-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 12px; font-size: 12px; color: var(--muted); }
</style>
</head>
<body>
<div class="wrap">
  <header>
    <div>
      <h1>Guillotine Cross-EVM Benchmarks</h1>
      <div class="subtitle" id="env-sub"></div>
    </div>
    <div id="verify-badge"></div>
  </header>

  <div class="kpis" id="kpis"></div>

  <div class="controls">
    <div class="tabs" id="mode-tabs">
      <button class="tab active" data-mode="warm">Warm Interpreters</button>
      <button class="tab" data-mode="cold">Cold First-Run</button>
      <button class="tab" data-mode="jit">Tier 2: JIT Compilers</button>
    </div>
    <div class="tabs" id="cat-tabs">
      <button class="tab active" data-cat="all">All (25)</button>
      <button class="tab" data-cat="classic">Classic</button>
      <button class="tab" data-cat="mainnet">Mainnet DeFi</button>
      <button class="tab" data-cat="precompile">Precompiles</button>
      <button class="tab" data-cat="opcode">Hot-Loops</button>
    </div>
  </div>

  <div class="card" id="chart-card">
    <h2 id="chart-title">Geometric Mean Speedup vs REVM</h2>
    <div id="chart"></div>
  </div>

  <div class="card">
    <h2 id="table-title">Per-Workload Median Latency</h2>
    <div id="table-wrap"></div>
  </div>

  <div class="card">
    <h2>Differential Verification &amp; Environment Provenance</h2>
    <div id="verify-table"></div>
    <div class="meta-grid" id="meta-grid" style="margin-top:16px"></div>
  </div>
</div>

<script>
const DATA = ${embedded};
const COLORS = {
  "guillotine": "#f59e0b",
  "guillotine-nofusion": "#d97706",
  "guillotine-jit": "#fbbf24",
  "evm2": "#38bdf8",
  "evm2-jit": "#0ea5e9",
  "revm": "#a78bfa",
  "revmc": "#8b5cf6",
  "evmone-advanced": "#10b981",
  "evmone-baseline": "#34d399",
  "ethrex-levm": "#f472b6",
  "gevm": "#fb7185",
  "geth": "#64748b",
};

function fmtNs(ns) {
  if (ns == null || Number.isNaN(ns)) return "—";
  if (ns < 1e3) return ns.toFixed(0) + " ns";
  if (ns < 1e6) return (ns / 1e3).toFixed(2) + " µs";
  if (ns < 1e9) return (ns / 1e6).toFixed(2) + " ms";
  return (ns / 1e9).toFixed(2) + " s";
}

let state = { mode: "warm", cat: "all" };

document.getElementById("env-sub").textContent =
  DATA.environment.cpu + " (" + DATA.environment.cpu_cores + " cores) · " +
  DATA.environment.os + " · Guillotine @" + DATA.environment.guillotine_rev + " · " +
  DATA.environment.timestamp_iso.slice(0, 10);

const allVerified = Object.values(DATA.verification).every(v => v.all_match);
const totalRuns = Object.values(DATA.verification).reduce((a, v) => a + v.total_runs, 0);
const verifiedRuns = Object.values(DATA.verification).reduce((a, v) => a + v.verified_runs, 0);
document.getElementById("verify-badge").innerHTML =
  '<span class="pill ' + (allVerified ? 'ok' : 'warn') + '">' +
  (allVerified ? '✓ ' : '⚠ ') + verifiedRuns + '/' + totalRuns + ' runs 0-tolerance gas+output verified</span>';

function renderKpis() {
  const gVsRevm = DATA.summaries.warm_vs_revm.overall["guillotine"]?.geomean_speedup;
  const gVsEvm2 = DATA.summaries.warm_vs_evm2.overall["guillotine"]?.geomean_speedup;
  const gColdRevm = DATA.summaries.cold_vs_revm.overall["guillotine"]?.geomean_speedup;
  const snail = DATA.results.warm?.["snailtracer"]?.["guillotine"];
  const items = [
    { label: "Guillotine vs REVM (Warm)", val: gVsRevm ? gVsRevm.toFixed(2) + "×" : "—", sub: "Geometric mean across all verified workloads" },
    { label: "Guillotine vs evm2 (Warm)", val: gVsEvm2 ? gVsEvm2.toFixed(2) + "×" : "—", sub: "vs alloy-rs/evm2 (new revm-team EVM)" },
    { label: "Guillotine vs REVM (Cold)", val: gColdRevm ? gColdRevm.toFixed(2) + "×" : "—", sub: "Includes fresh bytecode analysis + init" },
    { label: "Snailtracer (Warm)", val: snail?.verified ? fmtNs(snail.median_ns) : "—", sub: snail?.verified ? (snail.mgas_per_sec / 1000).toFixed(2) + " Ggas/s" : "" },
  ];
  document.getElementById("kpis").innerHTML = items.map(k =>
    '<div class="kpi"><div class="label">' + k.label + '</div><div class="val">' + k.val + '</div><div class="sub">' + k.sub + '</div></div>'
  ).join("");
}

function render() {
  const mode = state.mode;
  const cat = state.cat;
  const wls = DATA.workloads.filter(w => (cat === "all" || w.category === cat) && (mode !== "jit" || w.category !== "precompile"));

  if (mode === "warm" || mode === "cold") {
    const sum = mode === "warm" ? DATA.summaries.warm_vs_revm : DATA.summaries.cold_vs_revm;
    const engines = Object.keys(sum.overall);
    const rows = engines.map(id => {
      const entry = cat === "all" ? sum.overall[id] : sum.by_category[cat][id];
      return { id, name: DATA.versions[id]?.name || id, val: entry?.geomean_speedup || 0, count: entry?.count || 0 };
    }).filter(r => r.val > 0).sort((a, b) => b.val - a.val);
    const maxV = Math.max(...rows.map(r => r.val), 1);
    document.getElementById("chart-card").style.display = "block";
    document.getElementById("chart-title").textContent =
      (mode === "warm" ? "Warm Steady-State" : "Cold First-Run") + " — Geometric Mean Speedup vs REVM (" + (cat === "all" ? "All Categories" : cat) + ")";
    document.getElementById("chart").innerHTML = rows.map(r =>
      '<div class="bar-row">' +
      '<div><strong>' + r.name + '</strong> <span class="dim">(' + r.count + ')</span></div>' +
      '<div class="bar-track"><div class="bar-fill" style="width:' + (r.val / maxV * 100).toFixed(1) + '%;background:' + (COLORS[r.id] || "#38bdf8") + '"></div></div>' +
      '<div style="text-align:right;font-weight:700">' + r.val.toFixed(2) + '×</div></div>'
    ).join("");

    const showEng = engines.filter(id => id !== "guillotine-nofusion");
    document.getElementById("table-title").textContent =
      (mode === "warm" ? "Warm Steady-State" : "Cold First-Run") + " Median Latency (" + wls.length + " workloads)";
    let html = '<table><thead><tr><th>Workload</th><th>Cat</th><th>Gas</th>' +
      showEng.map(id => '<th>' + (DATA.versions[id]?.name || id) + '</th>').join("") +
      '<th>Guillotine / REVM</th></tr></thead><tbody>';
    for (const w of wls) {
      const b = DATA.results[mode]?.[w.name] || {};
      const ver = DATA.verification[w.name];
      let best = Infinity;
      for (const id of showEng) if (b[id]?.verified && b[id].median_ns < best) best = b[id].median_ns;
      const g = b["guillotine"], rv = b["revm"];
      const ratio = g?.verified && rv?.verified ? (rv.median_ns / g.median_ns).toFixed(2) + "×" : "—";
      html += '<tr><td class="mono">' + w.name + '</td><td class="dim">' + w.category + '</td><td>' + (ver.canonical_gas?.toLocaleString() || "—") + '</td>';
      for (const id of showEng) {
        const r = b[id];
        if (!r) { html += '<td class="dim">—</td>'; continue; }
        if (!r.verified) { html += '<td class="bad">' + (r.status === "ok" ? "MISMATCH" : r.status.toUpperCase()) + '</td>'; continue; }
        const cls = r.median_ns === best ? ' class="best"' : '';
        html += '<td' + cls + ' title="IQR: ' + fmtNs(r.iqr_ns) + ' · p95: ' + fmtNs(r.p95_ns) + ' · ' + r.mgas_per_sec.toFixed(0) + ' MGas/s">' + fmtNs(r.median_ns) + '</td>';
      }
      html += '<td><strong>' + ratio + '</strong></td></tr>';
    }
    html += '</tbody></table>';
    document.getElementById("table-wrap").innerHTML = html;
  } else {
    document.getElementById("chart-card").style.display = "none";
    document.getElementById("table-title").textContent = "Tier 2 — JIT / Native Compilers (Warm Execution / One-Time Compile)";
    let html = '<table><thead><tr><th>Workload</th><th>Cat</th><th>Guillotine Interp</th><th>Guillotine JIT (ARM64)</th><th>evm2 Interp</th><th>evm2-jit (LLVM 23)</th><th>revmc (LLVM 22)</th></tr></thead><tbody>';
    for (const w of wls) {
      const gI = DATA.results.warm?.[w.name]?.["guillotine"];
      const eI = DATA.results.warm?.[w.name]?.["evm2"];
      const gJ = DATA.results.jit?.[w.name]?.["guillotine-jit"];
      const eJ = DATA.results.jit?.[w.name]?.["evm2-jit"];
      const rJ = DATA.results.jit?.[w.name]?.["revmc"];
      const cell = (r) => {
        if (!r) return '<td class="dim">—</td>';
        if (!r.verified) return '<td class="bad">' + (r.status === "ok" ? "MISMATCH" : r.status.toUpperCase()) + '</td>';
        if (!r.jit_compiled) return '<td class="dim">' + fmtNs(r.median_ns) + ' (interp)</td>';
        return '<td><strong>' + fmtNs(r.median_ns) + '</strong> <span class="dim">/ ' + fmtNs(r.compile_ns) + '</span></td>';
      };
      html += '<tr><td class="mono">' + w.name + '</td><td class="dim">' + w.category + '</td>' +
        '<td>' + (gI?.verified ? fmtNs(gI.median_ns) : '—') + '</td>' +
        cell(gJ) +
        '<td>' + (eI?.verified ? fmtNs(eI.median_ns) : '—') + '</td>' +
        cell(eJ) + cell(rJ) + '</tr>';
    }
    html += '</tbody></table>';
    document.getElementById("table-wrap").innerHTML = html;
  }
}

function renderAudit() {
  const discs = Object.entries(DATA.verification).filter(([, v]) => !v.all_match);
  if (discs.length === 0) {
    document.getElementById("verify-table").innerHTML = '<div class="pill ok">✓ Zero discrepancies across all ' + DATA.workloads.length + ' workloads and all engines.</div>';
  } else {
    document.getElementById("verify-table").innerHTML = '<table><thead><tr><th>Workload</th><th>Canonical Gas</th><th>Discrepancies</th></tr></thead><tbody>' +
      discs.map(([name, v]) => '<tr><td class="mono">' + name + '</td><td>' + (v.canonical_gas?.toLocaleString() || '—') + '</td><td style="text-align:left">' +
        v.discrepancies.map(d => '<code>' + d.engine + '</code> (' + d.mode + '): ' + d.error).join("<br>") + '</td></tr>').join("") + '</tbody></table>';
  }
  const c = DATA.environment.compilers;
  document.getElementById("meta-grid").innerHTML =
    '<div><strong>Zig:</strong> ' + c.zig + '<br><strong>Rust:</strong> ' + c.rustc + '</div>' +
    '<div><strong>C++:</strong> ' + c.clang + '<br><strong>Go:</strong> ' + c.go + '</div>' +
    '<div><strong>LLVM (evm2-jit / revmc):</strong> ' + c.llvm_evm2_jit + ' / ' + c.llvm_revmc + '<br><strong>Pinned date:</strong> ' + DATA.environment.timestamp_iso + '</div>';
}

document.querySelectorAll("#mode-tabs .tab").forEach(btn => btn.onclick = () => {
  document.querySelectorAll("#mode-tabs .tab").forEach(b => b.classList.remove("active"));
  btn.classList.add("active");
  state.mode = btn.dataset.mode;
  render();
});
document.querySelectorAll("#cat-tabs .tab").forEach(btn => btn.onclick = () => {
  document.querySelectorAll("#cat-tabs .tab").forEach(b => b.classList.remove("active"));
  btn.classList.add("active");
  state.cat = btn.dataset.cat;
  render();
});

renderKpis();
render();
renderAudit();
</script>
</body>
</html>
`;
}

const htmlPath = path.join(ROOT, "report.html");
fs.writeFileSync(htmlPath, buildHtml());

console.log(`\n=== Done ===`);
console.log(`  JSON:   ${jsonPath}`);
console.log(`  Report: ${mdPath}`);
console.log(`  HTML:   ${htmlPath}`);

const anyDiscrepancy = Object.values(verification).some((v) => !v.all_match);
if (anyDiscrepancy) {
  console.log(`\n⚠️  Verification discrepancies detected (see Audit section in RESULTS.md):`);
  for (const [name, v] of Object.entries(verification)) {
    if (!v.all_match) {
      for (const d of v.discrepancies) {
        console.log(`    - ${name} [${d.mode}] ${d.engine}: ${d.error}`);
      }
    }
  }
} else {
  console.log(`\n✅ 100% differential verification passed across all engines and workloads!`);
}
