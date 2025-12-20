#!/usr/bin/env bun

/**
 * WASM Function Name Mapper
 *
 * Builds a comprehensive mapping of WASM function indices to actual function names
 * by analyzing multiple sources:
 * 1. WASM exports (explicit names)
 * 2. WASM imports (external functions)
 * 3. Source code analysis (Zig functions)
 * 4. Heuristics based on function patterns
 */

import { $ } from "bun";
import { readdir } from "node:fs/promises";
import { join } from "node:path";

const WASM_PATH = "zig-out/bin/guillotine_mini.wasm";
const SRC_DIR = "src";

interface FunctionMapping {
  index: number;
  name: string;
  source: "export" | "import" | "inferred" | "unknown";
  category?: string;
}

async function extractExports(): Promise<Map<number, FunctionMapping>> {
  const mapping = new Map<number, FunctionMapping>();

  const output = await $`wasm-objdump -x ${WASM_PATH}`.text();

  // Extract exports: " - func[13] <evm_create> -> "evm_create""
  const exportMatches = output.matchAll(/- func\[(\d+)\] <([^>]+)> -> "([^"]+)"/g);

  for (const match of exportMatches) {
    const index = parseInt(match[1]);
    const name = match[2];
    mapping.set(index, {
      index,
      name,
      source: "export",
      category: "C API",
    });
  }

  console.log(`✅ Found ${mapping.size} exported functions`);
  return mapping;
}

async function extractImports(): Promise<Map<number, FunctionMapping>> {
  const mapping = new Map<number, FunctionMapping>();

  const output = await $`wasm-objdump -x ${WASM_PATH}`.text();

  // Extract imports: " - func[0] sig=0 <wasi_snapshot_preview1.fd_write> <- wasi_snapshot_preview1.fd_write"
  const importMatches = output.matchAll(/- func\[(\d+)\] sig=\d+ <([^>]+)>/g);

  for (const match of importMatches) {
    const index = parseInt(match[1]);
    const name = match[2];
    mapping.set(index, {
      index,
      name,
      source: "import",
      category: "External",
    });
  }

  console.log(`✅ Found ${mapping.size} imported functions`);
  return mapping;
}

async function inferFromDisassembly(
  existingMap: Map<number, FunctionMapping>
): Promise<Map<number, FunctionMapping>> {
  const mapping = new Map(existingMap);

  const output = await $`wasm-objdump -d ${WASM_PATH}`.text();
  const lines = output.split("\n");

  // Pattern: look for call instructions to known functions
  const knownNames = new Map<number, string>();
  for (const [idx, func] of existingMap.entries()) {
    knownNames.set(idx, func.name);
  }

  let currentFunc: { index: number; calls: Set<number> } | null = null;
  const functionCalls = new Map<number, Set<number>>();

  for (const line of lines) {
    // Function header: "000667 func[13] <evm_create>:"
    const funcMatch = line.match(/^([0-9a-f]{6})\s+func\[(\d+)\]/);
    if (funcMatch) {
      if (currentFunc) {
        functionCalls.set(currentFunc.index, currentFunc.calls);
      }
      currentFunc = {
        index: parseInt(funcMatch[2]),
        calls: new Set(),
      };
      continue;
    }

    // Call instruction: "  000123: 10 85 80 80 80 00          |   call 5"
    if (currentFunc) {
      const callMatch = line.match(/call (\d+)/);
      if (callMatch) {
        currentFunc.calls.add(parseInt(callMatch[1]));
      }
    }
  }

  if (currentFunc) {
    functionCalls.set(currentFunc.index, currentFunc.calls);
  }

  // Infer names based on call patterns
  let inferred = 0;
  for (const [idx, calls] of functionCalls.entries()) {
    if (mapping.has(idx)) continue; // Already named

    // Check if this function primarily calls a specific known function
    const calledNames = Array.from(calls)
      .map(callIdx => knownNames.get(callIdx))
      .filter(Boolean);

    if (calledNames.length > 0) {
      // Group by common patterns
      const hasExecute = calledNames.some(n => n?.includes("execute"));
      const hasStorage = calledNames.some(n => n?.includes("storage"));
      const hasGet = calledNames.some(n => n?.includes("get"));
      const hasSet = calledNames.some(n => n?.includes("set"));

      let category = "Helper";
      let nameHint = "";

      if (hasExecute) {
        category = "Execution";
        nameHint = "execution_helper";
      } else if (hasStorage && hasSet) {
        category = "Storage";
        nameHint = "storage_setter";
      } else if (hasStorage && hasGet) {
        category = "Storage";
        nameHint = "storage_getter";
      } else if (hasSet) {
        category = "State";
        nameHint = "state_setter";
      } else if (hasGet) {
        category = "State";
        nameHint = "state_getter";
      }

      if (nameHint) {
        mapping.set(idx, {
          index: idx,
          name: `${nameHint}_${idx}`,
          source: "inferred",
          category,
        });
        inferred++;
      }
    }
  }

  console.log(`✅ Inferred ${inferred} function names from call patterns`);
  return mapping;
}

async function analyzeSourceCode(): Promise<Map<string, string>> {
  const functionPatterns = new Map<string, string>();

  // Read key source files
  const sourceFiles = [
    "src/evm.zig",
    "src/frame.zig",
    "src/root_c.zig",
    "src/host.zig",
    "src/primitives/root.zig",
    "src/precompiles/precompiles.zig",
  ];

  for (const file of sourceFiles) {
    try {
      const content = await Bun.file(file).text();

      // Extract public function declarations
      // Pattern: pub fn functionName(...) ...
      const funcMatches = content.matchAll(/pub fn ([a-zA-Z_][a-zA-Z0-9_]*)\s*\(/g);

      for (const match of funcMatches) {
        const funcName = match[1];
        const module = file.split("/").pop()?.replace(".zig", "") || "unknown";
        functionPatterns.set(funcName.toLowerCase(), `${module}.${funcName}`);
      }
    } catch {
      // File doesn't exist or can't be read
    }
  }

  console.log(`✅ Found ${functionPatterns.size} function patterns in source code`);
  return functionPatterns;
}

async function categorizeBySize(
  mapping: Map<number, FunctionMapping>,
  sizes: Map<number, number>
): Promise<Map<number, FunctionMapping>> {
  const enhanced = new Map(mapping);

  // Add category hints based on size
  for (const [idx, size] of sizes.entries()) {
    const existing = enhanced.get(idx);
    if (!existing) {
      let category = "Small";
      let hint = "";

      if (size > 20000) {
        category = "Very Large";
        hint = "likely_main_logic_or_matcher";
      } else if (size > 10000) {
        category = "Large";
        hint = "complex_logic";
      } else if (size > 5000) {
        category = "Medium";
        hint = "feature_impl";
      } else if (size > 1000) {
        category = "Normal";
        hint = "helper";
      } else {
        category = "Small";
        hint = "util";
      }

      enhanced.set(idx, {
        index: idx,
        name: `${hint}_func_${idx}`,
        source: "inferred",
        category,
      });
    }
  }

  return enhanced;
}

async function buildFunctionSizeMap(): Promise<Map<number, number>> {
  const sizes = new Map<number, number>();

  const output = await $`wasm-objdump -d ${WASM_PATH}`.text();
  const lines = output.split("\n");

  let currentFunc: { index: number; start: number; end: number } | null = null;

  for (const line of lines) {
    const funcMatch = line.match(/^([0-9a-f]{6})\s+func\[(\d+)\]/);
    if (funcMatch) {
      if (currentFunc) {
        sizes.set(currentFunc.index, currentFunc.end - currentFunc.start);
      }

      currentFunc = {
        index: parseInt(funcMatch[2]),
        start: parseInt(funcMatch[1], 16),
        end: parseInt(funcMatch[1], 16),
      };
      continue;
    }

    const offsetMatch = line.match(/^\s+([0-9a-f]{6}):/);
    if (offsetMatch && currentFunc) {
      currentFunc.end = parseInt(offsetMatch[1], 16);
    }
  }

  if (currentFunc) {
    sizes.set(currentFunc.index, currentFunc.end - currentFunc.start);
  }

  return sizes;
}

async function saveMappingDatabase(
  mapping: Map<number, FunctionMapping>,
  sizes: Map<number, number>,
  outputFile: string
): Promise<void> {
  const database: any = {
    generated: new Date().toISOString(),
    total_functions: mapping.size,
    categories: {} as Record<string, number>,
    functions: [] as any[],
  };

  // Count by category
  for (const func of mapping.values()) {
    const cat = func.category || "Unknown";
    database.categories[cat] = (database.categories[cat] || 0) + 1;
  }

  // Sort by size (descending)
  const sorted = Array.from(mapping.values()).sort((a, b) => {
    const sizeA = sizes.get(a.index) || 0;
    const sizeB = sizes.get(b.index) || 0;
    return sizeB - sizeA;
  });

  for (const func of sorted) {
    database.functions.push({
      index: func.index,
      name: func.name,
      size: sizes.get(func.index) || 0,
      source: func.source,
      category: func.category,
    });
  }

  await Bun.write(outputFile, JSON.stringify(database, null, 2));
  console.log(`\n✅ Saved function mapping database to: ${outputFile}`);

  // Also save human-readable version
  const txtFile = outputFile.replace(".json", ".txt");
  let report = `WASM Function Name Mapping
Generated: ${database.generated}
Total Functions: ${database.total_functions}

Categories:
`;

  for (const [cat, count] of Object.entries(database.categories)) {
    report += `  - ${cat}: ${count}\n`;
  }

  report += `\nTop 100 Functions by Size:\n\n`;
  report += `${"Index".padEnd(8)} | ${"Size".padEnd(10)} | ${"Source".padEnd(10)} | ${"Category".padEnd(15)} | Function Name\n`;
  report += `${"-".repeat(8)} | ${"-".repeat(10)} | ${"-".repeat(10)} | ${"-".repeat(15)} | ${"-".repeat(50)}\n`;

  for (let i = 0; i < Math.min(100, database.functions.length); i++) {
    const func = database.functions[i];
    report += `${String(func.index).padEnd(8)} | ${String(func.size).padEnd(10)} | ${func.source.padEnd(10)} | ${(func.category || "").padEnd(15)} | ${func.name}\n`;
  }

  await Bun.write(txtFile, report);
  console.log(`✅ Saved human-readable mapping to: ${txtFile}`);
}

async function showTopFunctions(
  mapping: Map<number, FunctionMapping>,
  sizes: Map<number, number>,
  limit: number = 20
): Promise<void> {
  const sorted = Array.from(mapping.values())
    .sort((a, b) => {
      const sizeA = sizes.get(a.index) || 0;
      const sizeB = sizes.get(b.index) || 0;
      return sizeB - sizeA;
    })
    .slice(0, limit);

  console.log(`\n📊 Top ${limit} Functions by Size:\n`);
  console.log(`${"Index".padEnd(8)} | ${"Size".padEnd(10)} | ${"% Total".padEnd(8)} | Function Name`);
  console.log(`${"-".repeat(8)} | ${"-".repeat(10)} | ${"-".repeat(8)} | ${"-".repeat(50)}`);

  const totalSize = 230721; // WASM total size

  for (const func of sorted) {
    const size = sizes.get(func.index) || 0;
    const percent = ((size / totalSize) * 100).toFixed(1);
    console.log(`${String(func.index).padEnd(8)} | ${String(size).padEnd(10)} | ${percent.padEnd(8)} | ${func.name}`);
  }
}

async function main() {
  console.log("🔍 Building WASM Function Name Mapping\n");

  // Build function sizes map
  console.log("📏 Analyzing function sizes...");
  const sizes = await buildFunctionSizeMap();
  console.log(`✅ Found ${sizes.size} functions\n`);

  // Extract explicit names from exports and imports
  console.log("📋 Extracting exported functions...");
  let mapping = await extractExports();

  console.log("📋 Extracting imported functions...");
  const imports = await extractImports();
  for (const [idx, func] of imports.entries()) {
    mapping.set(idx, func);
  }

  // Analyze source code for patterns
  console.log("🔍 Analyzing source code patterns...");
  await analyzeSourceCode();

  // Infer names from call patterns
  console.log("🔍 Inferring names from call patterns...");
  mapping = await inferFromDisassembly(mapping);

  // Categorize remaining functions by size
  console.log("🏷️  Categorizing functions by size...");
  mapping = await categorizeBySize(mapping, sizes);

  // Save mapping database
  await saveMappingDatabase(
    mapping,
    sizes,
    "reports/wasm-size/function-mapping.json"
  );

  // Show top functions
  await showTopFunctions(mapping, sizes, 25);

  console.log(`\n✅ Function mapping complete!`);
  console.log(`\n💡 Use this mapping with analyze-wasm-size.ts to see named functions`);
}

main().catch((err) => {
  console.error("❌ Error:", err.message);
  process.exit(1);
});
