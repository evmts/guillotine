#!/usr/bin/env bun

/**
 * WASM Size Analysis Script
 *
 * Analyzes the size breakdown of guillotine_mini.wasm using twiggy.
 * Provides multiple views: top functions, dominators, paths, and sections.
 *
 * Prerequisites:
 * - twiggy (install with: cargo install twiggy)
 * - WASM file built with: zig build wasm
 *
 * Usage:
 *   bun scripts/analyze-wasm-size.ts [options]
 *
 * Options:
 *   --rebuild     Rebuild WASM before analysis
 *   --output DIR  Output directory for reports (default: reports/wasm-size)
 *   --limit N     Number of items to show in each report (default: 50)
 *   --json        Also generate JSON output
 */

import { $ } from "bun";
import { mkdir, exists } from "node:fs/promises";
import { join } from "node:path";

interface AnalysisOptions {
  rebuild: boolean;
  outputDir: string;
  limit: number;
  json: boolean;
}

const WASM_PATH = "zig-out/bin/guillotine_mini.wasm";
const MAPPING_FILE = "reports/wasm-size/function-mapping.json";

interface FunctionMapping {
  index: number;
  name: string;
  size: number;
  source: string;
  category?: string;
}

interface MappingDatabase {
  generated: string;
  total_functions: number;
  categories: Record<string, number>;
  functions: FunctionMapping[];
}

async function loadFunctionMapping(): Promise<Map<number, FunctionMapping>> {
  const mapping = new Map<number, FunctionMapping>();

  try {
    const file = Bun.file(MAPPING_FILE);
    if (await file.exists()) {
      const data: MappingDatabase = await file.json();
      for (const func of data.functions) {
        mapping.set(func.index, func);
      }
      console.log(`✅ Loaded ${mapping.size} function names from mapping database`);
    }
  } catch (err) {
    console.warn("⚠️  Could not load function mapping, will generate basic names");
  }

  return mapping;
}

async function parseArgs(): Promise<AnalysisOptions> {
  const args = process.argv.slice(2);
  const options: AnalysisOptions = {
    rebuild: false,
    outputDir: "reports/wasm-size",
    limit: 50,
    json: false,
  };

  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case "--rebuild":
        options.rebuild = true;
        break;
      case "--output":
        options.outputDir = args[++i];
        break;
      case "--limit":
        options.limit = parseInt(args[++i], 10);
        break;
      case "--json":
        options.json = true;
        break;
      case "--help":
        console.log(`
WASM Size Analysis Script

Analyzes the size breakdown of guillotine_mini.wasm using twiggy.

Usage:
  bun scripts/analyze-wasm-size.ts [options]

Options:
  --rebuild     Rebuild WASM before analysis
  --output DIR  Output directory for reports (default: reports/wasm-size)
  --limit N     Number of items to show in each report (default: 50)
  --json        Also generate JSON output
  --help        Show this help message

Examples:
  bun scripts/analyze-wasm-size.ts
  bun scripts/analyze-wasm-size.ts --rebuild --limit 100
  bun scripts/analyze-wasm-size.ts --output my-reports --json
`);
        process.exit(0);
      default:
        console.error(`Unknown option: ${args[i]}`);
        process.exit(1);
    }
  }

  return options;
}

async function checkPrerequisites(): Promise<{ twiggy: boolean; wabt: boolean }> {
  const tools = { twiggy: false, wabt: false };

  try {
    await $`which twiggy`.quiet();
    tools.twiggy = true;
  } catch {
    console.error(`
⚠️  Warning: twiggy not found

twiggy is recommended for detailed WASM size analysis.

Install with:
  cargo install twiggy
`);
  }

  try {
    await $`which wasm-objdump`.quiet();
    tools.wabt = true;
  } catch {
    console.error(`
⚠️  Warning: wasm-objdump not found

wasm-objdump provides symbol information.

Install with:
  brew install wabt
`);
  }

  if (!tools.twiggy && !tools.wabt) {
    console.error(`
❌ Error: No analysis tools found

At least one of these tools is required:
  - twiggy: cargo install twiggy
  - wabt: brew install wabt
`);
    return tools;
  }

  return tools;
}

async function buildWasm(): Promise<void> {
  console.log("🔨 Building WASM...");
  await $`zig build wasm`;
  console.log("✅ WASM build complete\n");
}

async function getWasmSize(): Promise<string> {
  const stat = await Bun.file(WASM_PATH).size;
  return `${Math.round(stat / 1024)}K (${stat.toLocaleString()} bytes)`;
}

async function runTwiggy(
  command: string,
  outputFile: string,
  options: AnalysisOptions
): Promise<string> {
  let args: string[];

  // Different commands have different argument formats
  if (command === "top" || command === "garbage" || command === "paths") {
    args = [command, WASM_PATH, "-n", options.limit.toString()];
  } else if (command === "dominators") {
    args = [command, WASM_PATH, "-r", options.limit.toString()];
  } else {
    args = [command, WASM_PATH];
  }

  const result = await $`twiggy ${args}`.text();

  // Write to file
  await Bun.write(outputFile, result);

  return result;
}

async function runTwiggyJson(
  command: string,
  outputFile: string,
  options: AnalysisOptions
): Promise<void> {
  if (!options.json) return;

  let args: string[];

  // Different commands have different argument formats
  if (command === "top" || command === "garbage" || command === "paths") {
    args = [command, WASM_PATH, "-n", options.limit.toString(), "--format", "json"];
  } else if (command === "dominators") {
    args = [command, WASM_PATH, "-r", options.limit.toString(), "--format", "json"];
  } else {
    args = [command, WASM_PATH, "--format", "json"];
  }

  const result = await $`twiggy ${args}`.text();

  await Bun.write(outputFile, result);
}

async function generateWasmInfo(outputDir: string): Promise<void> {
  console.log("🔍 Extracting WASM module information...");

  try {
    // Get full module details
    const fullDump = await $`wasm-objdump -x ${WASM_PATH}`.text();
    await Bun.write(join(outputDir, "wasm-module-info.txt"), fullDump);

    // Extract sections summary
    const sections = await $`wasm-objdump -h ${WASM_PATH}`.text();
    await Bun.write(join(outputDir, "wasm-sections.txt"), sections);

    // Extract exports
    const exportsMatch = fullDump.match(/Export\[\d+\]:.*?(?=\n\w+\[|$)/s);
    if (exportsMatch) {
      await Bun.write(join(outputDir, "wasm-exports.txt"), exportsMatch[0]);
    }

    // Extract imports
    const importsMatch = fullDump.match(/Import\[\d+\]:.*?(?=\nFunction\[|$)/s);
    if (importsMatch) {
      await Bun.write(join(outputDir, "wasm-imports.txt"), importsMatch[0]);
    }

    console.log("✅ WASM module information extracted");
  } catch (err) {
    console.warn("⚠️  Could not extract WASM info:", err);
  }
}

async function analyzeCodeSections(
  outputDir: string,
  nameMapping: Map<number, FunctionMapping>
): Promise<void> {
  console.log("🔍 Analyzing code sections...");

  try {
    const result = await $`wasm-objdump -d ${WASM_PATH}`.text();
    await Bun.write(join(outputDir, "wasm-disassembly.txt"), result);

    // Parse disassembly to get function sizes
    const functions: Array<{ index: number; name: string; size: number; category?: string; source?: string }> = [];
    const lines = result.split("\n");

    let currentFunc: { index: number; start: number; end: number } | null = null;

    for (const line of lines) {
      // Look for function headers like "000667 func[13] <evm_create>:"
      const funcMatch = line.match(/^([0-9a-f]{6})\s+func\[(\d+)\](?:\s+<([^>]+)>)?:/);
      if (funcMatch) {
        if (currentFunc) {
          // Save previous function with enhanced name
          const size = currentFunc.end - currentFunc.start;
          if (size > 0) {
            const mapped = nameMapping.get(currentFunc.index);
            functions.push({
              index: currentFunc.index,
              name: mapped?.name || `func[${currentFunc.index}]`,
              size: size,
              category: mapped?.category,
              source: mapped?.source,
            });
          }
        }

        const startOffset = parseInt(funcMatch[1], 16);
        currentFunc = {
          index: parseInt(funcMatch[2]),
          start: startOffset,
          end: startOffset,
        };
      }

      // Look for byte offsets like " 000668: 04 7f"
      const offsetMatch = line.match(/^\s+([0-9a-f]{6}):/);
      if (offsetMatch && currentFunc) {
        const offset = parseInt(offsetMatch[1], 16);
        currentFunc.end = offset;
      }
    }

    // Save last function
    if (currentFunc && currentFunc.end > currentFunc.start) {
      const mapped = nameMapping.get(currentFunc.index);
      functions.push({
        index: currentFunc.index,
        name: mapped?.name || `func[${currentFunc.index}]`,
        size: currentFunc.end - currentFunc.start,
        category: mapped?.category,
        source: mapped?.source,
      });
    }

    // Sort by size and generate report
    functions.sort((a, b) => b.size - a.size);

    const totalSize = 230721; // WASM total size

    let report = `Function Size Analysis (Enhanced with Name Mapping)
Generated: ${new Date().toISOString()}

Top ${Math.min(100, functions.length)} Functions by Code Size:

${"Index".padEnd(8)} | ${"Size (bytes)".padEnd(12)} | ${"% Total".padEnd(8)} | ${"Category".padEnd(15)} | Function Name
${"-".repeat(8)} | ${"-".repeat(12)} | ${"-".repeat(8)} | ${"-".repeat(15)} | ${"-".repeat(50)}
`;

    for (let i = 0; i < Math.min(100, functions.length); i++) {
      const func = functions[i];
      const percent = ((func.size / totalSize) * 100).toFixed(1);
      const category = (func.category || "Unknown").padEnd(15);
      report += `${func.index.toString().padEnd(8)} | ${func.size.toString().padEnd(12)} | ${percent.padEnd(8)} | ${category} | ${func.name}\n`;
    }

    report += `\nTotal functions analyzed: ${functions.length}\n`;
    report += `\nSummary by Category:\n`;

    // Calculate category stats
    const categoryStats = new Map<string, { count: number; size: number }>();
    for (const func of functions) {
      const cat = func.category || "Unknown";
      const stats = categoryStats.get(cat) || { count: 0, size: 0 };
      stats.count++;
      stats.size += func.size;
      categoryStats.set(cat, stats);
    }

    const sortedCategories = Array.from(categoryStats.entries()).sort((a, b) => b[1].size - a[1].size);
    for (const [cat, stats] of sortedCategories) {
      const percent = ((stats.size / totalSize) * 100).toFixed(1);
      report += `  ${cat.padEnd(20)}: ${stats.count} functions, ${stats.size.toLocaleString()} bytes (${percent}%)\n`;
    }

    await Bun.write(join(outputDir, "function-sizes.txt"), report);

    console.log("✅ Code section analysis complete");
  } catch (err) {
    console.warn("⚠️  Could not analyze code sections:", err);
  }
}

async function generateSummary(outputDir: string, options: AnalysisOptions): Promise<void> {
  const timestamp = new Date().toISOString();
  const wasmSize = await getWasmSize();

  const summary = `# WASM Size Analysis Report

**Generated:** ${timestamp}
**WASM File:** ${WASM_PATH}
**Total Size:** ${wasmSize}

## Overview

This report analyzes the size breakdown of the guillotine-mini WASM binary.
Each section below shows a different view of what contributes to the binary size.

## Analysis Types

### 1. Top Functions (top.txt)
Shows the largest functions by size. This is useful for identifying which functions
are contributing most to the binary size.

### 2. Dominators (dominators.txt)
Shows the "dominator tree" - functions that uniquely own their descendants in the
call graph. A dominator is a function that, if removed, would allow removal of all
its dominated functions. This is useful for understanding what removing a function
would save.

### 3. Paths (paths.txt)
Shows the call paths that contribute most to binary size. This is useful for
understanding why certain functions are included and what's calling them.

### 4. Garbage (garbage.txt)
Shows unused items that could potentially be removed through dead code elimination.

## Files Generated

- \`top.txt\` - Top ${options.limit} functions by size
- \`dominators.txt\` - Top ${options.limit} dominators
- \`paths.txt\` - Top ${options.limit} call paths
- \`garbage.txt\` - Unused code
${options.json ? `- \`*.json\` - JSON versions of all reports` : ""}

## Quick Insights

To find optimization opportunities, look at:

1. **Large functions in top.txt** - Can they be simplified or split?
2. **High dominators** - Removing these would have the biggest impact
3. **Unexpected paths** - Why are these functions being called?
4. **Garbage** - Can dead code elimination be improved?

## Next Steps

1. Review top.txt to identify the largest functions
2. Check dominators.txt to see what removing functions would save
3. Use paths.txt to understand why large functions are included
4. Consider build optimizations:
   - Strip debug info
   - Enable LTO (Link Time Optimization)
   - Use ReleaseSmall mode (already enabled)
   - Remove unused features

## Commands Used

\`\`\`bash
# Rebuild WASM
zig build wasm

# Analyze top functions
twiggy top ${WASM_PATH} -n ${options.limit}

# Analyze dominators
twiggy dominators ${WASM_PATH} -n ${options.limit}

# Analyze paths
twiggy paths ${WASM_PATH} -n ${options.limit}

# Find garbage
twiggy garbage ${WASM_PATH} -n ${options.limit}
\`\`\`

## Reproduce This Report

\`\`\`bash
bun scripts/analyze-wasm-size.ts --limit ${options.limit}${options.json ? " --json" : ""}
\`\`\`
`;

  await Bun.write(join(outputDir, "README.md"), summary);
}

async function generateQuickView(outputDir: string): Promise<void> {
  // Try to read function-sizes.txt first (has names), fallback to top.txt
  const funcSizesFile = join(outputDir, "function-sizes.txt");
  const topFile = join(outputDir, "top.txt");

  let content: string;
  try {
    content = await Bun.file(funcSizesFile).text();
    const lines = content.split("\n").slice(0, 28); // Header + 20 items

    console.log("\n📊 Quick View - Top 20 Functions by Code Size:\n");
    console.log(lines.join("\n"));
  } catch {
    // Fallback to twiggy output
    try {
      content = await Bun.file(topFile).text();
      const lines = content.split("\n").slice(0, 25); // Header + 20 items

      console.log("\n📊 Quick View - Top 20 Functions by Size (twiggy):\n");
      console.log(lines.join("\n"));
    } catch {
      console.log("\n⚠️  Could not generate quick view");
    }
  }

  console.log(`\n💡 Full report available in: ${outputDir}/`);
}

async function main() {
  console.log("🔍 WASM Size Analysis\n");

  const options = await parseArgs();

  // Check prerequisites
  const tools = await checkPrerequisites();
  if (!tools.twiggy && !tools.wabt) {
    process.exit(1);
  }

  // Rebuild if requested
  if (options.rebuild) {
    await buildWasm();
  }

  // Check if WASM file exists
  if (!(await exists(WASM_PATH))) {
    console.error(`❌ Error: WASM file not found: ${WASM_PATH}`);
    console.error("Run with --rebuild to build it first");
    process.exit(1);
  }

  // Create output directory
  await mkdir(options.outputDir, { recursive: true });

  console.log(`📦 Analyzing WASM file: ${WASM_PATH}`);
  console.log(`📏 Total size: ${await getWasmSize()}\n`);

  // Load function name mapping
  console.log("📚 Loading function name mapping...");
  const nameMapping = await loadFunctionMapping();

  // If mapping doesn't exist or is empty, generate it
  if (nameMapping.size === 0) {
    console.log("⚠️  Function mapping not found, generating now...");
    try {
      await $`bun scripts/map-wasm-functions.ts`.quiet();
      // Reload after generation
      const newMapping = await loadFunctionMapping();
      for (const [idx, func] of newMapping.entries()) {
        nameMapping.set(idx, func);
      }
    } catch {
      console.warn("⚠️  Could not generate function mapping, continuing with basic names");
    }
  }
  console.log();

  // Run wasm-objdump analyses if available
  if (tools.wabt) {
    await generateWasmInfo(options.outputDir);
    await analyzeCodeSections(options.outputDir, nameMapping);
  }

  // Run twiggy analyses if available
  if (tools.twiggy) {
    console.log("🔍 Running twiggy top (largest functions)...");
    await runTwiggy("top", join(options.outputDir, "top.txt"), options);
    await runTwiggyJson("top", join(options.outputDir, "top.json"), options);

    console.log("🔍 Running twiggy dominators (removal impact)...");
    await runTwiggy("dominators", join(options.outputDir, "dominators.txt"), options);
    await runTwiggyJson("dominators", join(options.outputDir, "dominators.json"), options);

    console.log("🔍 Running twiggy garbage (unused code)...");
    await runTwiggy("garbage", join(options.outputDir, "garbage.txt"), options);
    await runTwiggyJson("garbage", join(options.outputDir, "garbage.json"), options);

    // Note: paths command requires specific function names as arguments
    // Skipping for now as we don't have function names in stripped WASM
  }

  // Generate summary
  console.log("📝 Generating summary...");
  await generateSummary(options.outputDir, options);

  // Show quick view
  await generateQuickView(options.outputDir);

  console.log(`\n✅ Analysis complete!`);
  console.log(`\n📁 Reports saved to: ${options.outputDir}/`);

  if (tools.wabt) {
    console.log(`   - function-sizes.txt (functions with names and sizes)`);
    console.log(`   - wasm-module-info.txt (full module details)`);
    console.log(`   - wasm-sections.txt (section sizes)`);
    console.log(`   - wasm-exports.txt (exported functions)`);
    console.log(`   - wasm-imports.txt (imported functions)`);
    console.log(`   - wasm-disassembly.txt (full disassembly)`);
  }

  if (tools.twiggy) {
    console.log(`   - README.md (overview and guide)`);
    console.log(`   - top.txt (largest functions by twiggy)`);
    console.log(`   - dominators.txt (removal impact)`);
    console.log(`   - garbage.txt (unused code)`);

    if (options.json) {
      console.log(`   - *.json (JSON versions)`);
    }
  }
}

main().catch((err) => {
  console.error("❌ Error:", err.message);
  process.exit(1);
});
