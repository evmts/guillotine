# WASM Size Analysis Tools

Complete toolset for analyzing and understanding the guillotine-mini WASM binary size (225KB).

## 🚀 Quick Start

```bash
# Run complete analysis (recommended)
./scripts/wasm-analysis.sh

# Rebuild WASM and analyze
./scripts/wasm-analysis.sh --rebuild

# Show more functions
./scripts/wasm-analysis.sh --limit 100
```

## 📊 Current Size Breakdown

**Total:** 225KB (230,721 bytes)

**Top Contributors:**
- **func[166]** - 48KB (21%) - Opcode execution dispatcher
- **func[71]** - 32KB (14%) - Precompile/gas handler
- **func[191]** - 10KB (4.5%) - Complex logic (CREATE/CALL)
- **evm_execute** - 8KB (3.6%) - Main entry point

**Key Insight:** Just 2 functions = 35% of the entire binary!

## 🛠️ Available Tools

### 1. Complete Workflow (Recommended)

```bash
./scripts/wasm-analysis.sh [--rebuild] [--limit N]
```

**What it does:**
1. Builds WASM (if --rebuild)
2. Generates function name mapping
3. Runs comprehensive size analysis
4. Shows key insights

**Output:** `reports/wasm-size/`

### 2. Function Name Mapping

```bash
bun scripts/map-wasm-functions.ts
```

**What it does:**
- Extracts exported/imported function names
- Analyzes source code patterns
- Infers function purposes from disassembly
- Categorizes by size (Very Large, Large, Normal, Small)

**Output:** `reports/wasm-size/function-mapping.json`

### 3. Size Analysis

```bash
bun scripts/analyze-wasm-size.ts [OPTIONS]

Options:
  --rebuild     Rebuild WASM first
  --limit N     Show top N functions (default: 50)
  --json        Generate JSON output
  --output DIR  Custom output directory
```

**What it does:**
- Disassembles WASM and calculates function sizes
- Runs twiggy analysis (top, dominators, garbage)
- Generates comprehensive reports
- Uses function mapping for names

**Output:** Multiple files in `reports/wasm-size/`

## 📁 Generated Reports

| File | Description |
|------|-------------|
| **ANALYSIS_SUMMARY.md** | 🌟 **START HERE** - Complete analysis with recommendations |
| **function-sizes.txt** | All functions sorted by size with categories |
| **function-mapping.json** | Machine-readable function database |
| **function-mapping.txt** | Human-readable function list |
| **wasm-sections.txt** | Section-level size breakdown |
| **wasm-module-info.txt** | Complete module structure |
| **wasm-exports.txt** | Exported functions |
| **wasm-imports.txt** | Imported functions |
| **wasm-disassembly.txt** | Full WASM disassembly |
| **top.txt** | Twiggy: largest functions |
| **dominators.txt** | Twiggy: removal impact |
| **garbage.txt** | Twiggy: dead code |

## 🎯 Optimization Recommendations

See `reports/wasm-size/ANALYSIS_SUMMARY.md` for detailed recommendations.

**Quick wins:**
1. **Split opcode dispatcher** (func[166]) - Potential: 20-30KB
2. **Hardfork feature flags** - Potential: 10-15KB
3. **Precompile modularization** - Potential: 5-10KB
4. **LTO + wasm-opt** - Potential: 5-10KB

**Total potential savings:** 40-65KB (18-29% reduction)

## 📖 Documentation

- **`WASM_SIZE_ANALYSIS.md`** - Comprehensive guide
  - Interpreting results
  - Optimization strategies
  - Troubleshooting
  - Advanced usage

- **`reports/wasm-size/ANALYSIS_SUMMARY.md`** - Analysis results
  - Current size breakdown
  - Function identification
  - Specific recommendations
  - Implementation plan

- **`reports/wasm-size/README.md`** - Auto-generated guide
  - Overview of analysis types
  - How to interpret reports
  - Quick insights

## 🔍 Common Tasks

### Identify a Large Function

```bash
# Find function by index
FUNC_IDX=166
grep "func\[${FUNC_IDX}\]" reports/wasm-size/function-mapping.txt

# View its disassembly
grep -A 100 "^[0-9a-f]* func\[${FUNC_IDX}\]" \
  reports/wasm-size/wasm-disassembly.txt | head -50
```

### Compare Before/After Optimization

```bash
# Before
zig build wasm
cp zig-out/bin/guillotine_mini.wasm before.wasm
bun scripts/analyze-wasm-size.ts --output reports/before

# Make changes...

# After
zig build wasm
cp zig-out/bin/guillotine_mini.wasm after.wasm
bun scripts/analyze-wasm-size.ts --output reports/after

# Compare
ls -lh before.wasm after.wasm
twiggy diff before.wasm after.wasm
```

### Track Size Over Time

```bash
# Add to git
git add reports/wasm-size/ANALYSIS_SUMMARY.md
git commit -m "WASM size baseline: 225KB"

# After optimization
./scripts/wasm-analysis.sh
git add reports/wasm-size/ANALYSIS_SUMMARY.md
git commit -m "WASM size optimized: XKB (Y% reduction)"
```

## 🧰 Prerequisites

- **Zig 0.15.1+** - For building WASM
- **Bun** - For running TypeScript scripts
  ```bash
  brew install bun
  ```
- **twiggy** - WASM size profiler (optional but recommended)
  ```bash
  cargo install twiggy
  ```
- **wabt** - WebAssembly Binary Toolkit (optional)
  ```bash
  brew install wabt
  ```

## 🐛 Troubleshooting

### "WASM file not found"
```bash
# Build it first
zig build wasm
# Or use --rebuild
./scripts/wasm-analysis.sh --rebuild
```

### "twiggy not found"
```bash
# Install it
cargo install twiggy
# Or continue without it (wabt still works)
```

### "Function mapping not found"
```bash
# Generate it manually
bun scripts/map-wasm-functions.ts
```

### Function names still showing as func[N]
This is expected for most functions due to `ReleaseSmall` optimization stripping debug info. The mapping tries to identify functions by:
1. Explicit exports
2. Call patterns
3. Size heuristics
4. Disassembly analysis

For better names, inspect the disassembly to understand what each function does.

## 🎓 Understanding the Analysis

### Categories

| Category | Size Range | Description |
|----------|------------|-------------|
| Very Large | >20KB | Likely main logic, large switch/match statements |
| Large | 10-20KB | Complex implementations (CREATE, CALL) |
| Medium | 5-10KB | Feature implementations |
| Normal | 1-5KB | Standard helper functions |
| Small | <1KB | Utilities, wrappers |

### Sources

| Source | Meaning |
|--------|---------|
| export | Explicitly exported in WASM (C API) |
| import | External function (WASI, JS callbacks) |
| inferred | Identified from call patterns |
| unknown | Could not identify |

## 📊 Size Targets

| Metric | Current | Good | Excellent |
|--------|---------|------|-----------|
| Total size | 225KB | <200KB | <150KB |
| Largest function | 48KB | <30KB | <20KB |
| Top 2 functions | 80KB (35%) | <50KB (25%) | <30KB (20%) |

## 🔗 Related Files

- `build.zig` - WASM build configuration (line 599-709)
- `src/root_c.zig` - C API exports
- `src/frame.zig` - Opcode execution (likely func[166])
- `src/evm.zig` - Main EVM logic
- `src/primitives/gas_constants.zig` - Gas calculations (likely func[71])

## 💡 Tips

1. **Run analysis regularly** - Track size changes during development
2. **Focus on top 5 functions** - 80/20 rule applies to code size
3. **Use categories** - Quickly identify problem areas
4. **Compare before/after** - Measure impact of optimizations
5. **Check dominators** - See what removing a function would save

## 🚦 Next Steps

1. **Review analysis:** `cat reports/wasm-size/ANALYSIS_SUMMARY.md`
2. **Implement optimizations** (see recommendations in summary)
3. **Measure impact:** Re-run `./scripts/wasm-analysis.sh`
4. **Iterate:** Repeat until size target achieved

## 📝 Adding to CI

```yaml
# .github/workflows/wasm-size.yml
name: WASM Size Check
on: [push, pull_request]
jobs:
  size-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Install Zig
        uses: goto-bus-stop/setup-zig@v2
      - name: Install Bun
        uses: oven-sh/setup-bun@v1
      - name: Build WASM
        run: zig build wasm
      - name: Check size
        run: |
          SIZE=$(wc -c < zig-out/bin/guillotine_mini.wasm)
          echo "WASM size: ${SIZE} bytes"
          if [ $SIZE -gt 250000 ]; then
            echo "❌ WASM size exceeded 250KB threshold"
            exit 1
          fi
      - name: Analyze
        run: ./scripts/wasm-analysis.sh --limit 20
```

## 🤝 Contributing

When adding optimizations:
1. Run analysis before changes (baseline)
2. Implement optimization
3. Run analysis after changes
4. Document size change in commit message
5. Update ANALYSIS_SUMMARY.md if significant

---

**For questions or issues:** See `WASM_SIZE_ANALYSIS.md` for detailed documentation.
