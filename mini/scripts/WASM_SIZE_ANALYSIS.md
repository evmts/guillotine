# WASM Size Analysis Guide

This guide explains how to analyze the size breakdown of the guillotine-mini WASM binary to understand which functions contribute to the 225KB total size.

## Quick Start

```bash
# Run the analysis (most common use case)
bun scripts/analyze-wasm-size.ts

# Rebuild WASM and analyze
bun scripts/analyze-wasm-size.ts --rebuild

# Show more items (default is 50)
bun scripts/analyze-wasm-size.ts --limit 100

# Generate JSON output files
bun scripts/analyze-wasm-size.ts --json

# Save to custom directory
bun scripts/analyze-wasm-size.ts --output my-reports
```

## Prerequisites

The script requires at least one of these tools:

1. **twiggy** (recommended) - Rust-based WASM size profiler
   ```bash
   cargo install twiggy
   ```

2. **wabt** - WebAssembly Binary Toolkit (includes wasm-objdump)
   ```bash
   brew install wabt
   ```

Both tools provide complementary information, so having both is ideal.

## Output Files

The analysis generates several reports in `reports/wasm-size/`:

### Function Analysis (from wasm-objdump)
- **function-sizes.txt** - Functions sorted by code size with names (where available)
- **wasm-module-info.txt** - Complete module structure and metadata
- **wasm-sections.txt** - Size breakdown by WASM sections
- **wasm-exports.txt** - List of exported functions
- **wasm-imports.txt** - List of imported functions
- **wasm-disassembly.txt** - Full disassembly of all functions

### Size Analysis (from twiggy)
- **top.txt** - Largest items (functions/data) by shallow size
- **dominators.txt** - Dominator tree showing removal impact
- **garbage.txt** - Potentially dead/unused code
- **README.md** - Guide to interpreting the reports

### JSON Output (optional, with --json flag)
- **top.json**, **dominators.json**, **garbage.json** - Machine-readable versions

## Current WASM Size Breakdown

**Total Size: 225K (230,721 bytes)**

### Top Functions by Code Size

Based on the latest analysis:

| Index | Size (bytes) | % of Total | Function Name | Notes |
|-------|--------------|------------|---------------|-------|
| 166 | 48,337 | 21.0% | func[166] | Largest function |
| 71 | 32,086 | 13.9% | func[71] | Second largest |
| 191 | 10,412 | 4.5% | func[191] | |
| 54 | 8,223 | 3.6% | **evm_execute** | Main execution loop |
| 193 | 6,928 | 3.0% | func[193] | |
| 227 | 5,850 | 2.5% | func[227] | |
| data[0] | 6,193 | 2.7% | **Data section** | Static data |

**Key Insights:**
- Top 2 functions account for **35%** of the binary (80KB)
- Top 10 functions account for **~60%** of the binary (138KB)
- `evm_execute` is the largest **named** function at 8KB

### Why Functions are Unnamed

Most functions show as `func[N]` because:
1. WASM is built with `ReleaseSmall` optimization
2. Debug symbols are stripped by default
3. Only exported functions retain their names

To identify unnamed functions:
1. Cross-reference with `wasm-exports.txt` for exported functions
2. Check `wasm-module-info.txt` for import/export mappings
3. Review `wasm-disassembly.txt` to see what operations the function performs

## Interpreting the Results

### 1. Function Sizes (function-sizes.txt)

Shows actual compiled code size for each function. Focus on:
- **Large functions** - Candidates for optimization or splitting
- **Exported functions** - Public API, harder to remove
- **Patterns** - Are similar operations compiled differently?

### 2. Twiggy Top (top.txt)

Shows "shallow" size - the size of the item itself, not including dependencies.

**Reading the output:**
```
 Shallow Bytes │ Shallow % │ Item
───────────────┼───────────┼────────────────────
         48342 ┊    20.95% ┊ code[153]  ← This function is 48KB alone
          6193 ┊     2.68% ┊ data[0]    ← Static data section
```

### 3. Twiggy Dominators (dominators.txt)

Shows what **removing** a function would save. A function "dominates" code that would become unreachable if it were removed.

**Use case:** If you want to remove a feature, check dominators to see total size savings.

### 4. Twiggy Garbage (garbage.txt)

Shows code that appears unused but hasn't been eliminated by the linker.

**Action items:**
- Investigate why it's included
- Consider LTO (Link Time Optimization)
- Check for unnecessary dependencies

## Optimization Strategies

Based on the analysis results, consider:

### 1. Target Large Functions (>5KB)

**Approach:**
- Review `func[166]` (48KB) and `func[71]` (32KB)
- Are they doing too much? Can they be split?
- Check for code duplication or monomorphization bloat

### 2. Review Data Section (6KB)

**Approach:**
- Check `wasm-sections.txt` for data section breakdown
- Are there large lookup tables?
- Can data be generated at runtime instead?

### 3. Build Optimizations

Current: `ReleaseSmall` ✅

Additional options:
```zig
// In build.zig, modify WASM target:
.optimize = .ReleaseSmall,  // Current
.strip = true,               // Remove debug info (already done)
.link_time_optimization = true,  // LTO for better dead code elimination
```

### 4. Feature Flags

If WASM doesn't need all features:
```zig
// Already implemented in build.zig:
const wasm_build_options = b.addOptions();
wasm_build_options.addOption(bool, "use_bn254", false);  // ✅
wasm_build_options.addOption(bool, "use_c_kzg", false);  // ✅
```

Consider adding more feature flags for:
- Tracing/debugging code
- Specific precompiles
- Optional hardfork support

### 5. Code Generation Review

Large unnamed functions might be:
- Monomorphized generic functions
- Inlined loops with unrolling
- Pattern matching with many cases

**Action:** Review Zig code for patterns that generate large functions.

## Tracking Size Over Time

### Create a Baseline

```bash
# Generate initial report
bun scripts/analyze-wasm-size.ts --output reports/wasm-size-baseline

# After changes, compare
bun scripts/analyze-wasm-size.ts --output reports/wasm-size-after-changes

# Compare file sizes
diff reports/wasm-size-baseline/function-sizes.txt \
     reports/wasm-size-after-changes/function-sizes.txt
```

### Automated Tracking

Add to CI:
```yaml
- name: Check WASM size
  run: |
    zig build wasm
    bun scripts/analyze-wasm-size.ts --limit 20
    SIZE=$(wc -c < zig-out/bin/guillotine_mini.wasm)
    echo "WASM size: ${SIZE} bytes"
    # Fail if size exceeds threshold
    [ $SIZE -lt 250000 ] || exit 1
```

## Troubleshooting

### "twiggy not found"

```bash
# Install via cargo
cargo install twiggy

# Or skip twiggy (wabt still works)
bun scripts/analyze-wasm-size.ts  # Will warn but continue
```

### "wasm-objdump not found"

```bash
# Install via homebrew
brew install wabt
```

### "WASM file not found"

```bash
# Build first
zig build wasm

# Or use --rebuild
bun scripts/analyze-wasm-size.ts --rebuild
```

### Function names missing

This is expected with `ReleaseSmall`. To get more names:
1. Check `wasm-exports.txt` for exported functions
2. Cross-reference function indices with `wasm-module-info.txt`
3. Use `wasm-disassembly.txt` to understand what functions do

## Advanced Usage

### Analyzing Specific Functions

Once you identify a large unnamed function (e.g., `func[166]`):

```bash
# View its disassembly
grep -A 100 "^[0-9a-f]* func\[166\]" reports/wasm-size/wasm-disassembly.txt | head -50

# Check if it's exported
grep "func\[166\]" reports/wasm-size/wasm-exports.txt

# See its full disassembly
wasm-objdump -d zig-out/bin/guillotine_mini.wasm | \
  sed -n '/^[0-9a-f]* func\[166\]/,/^[0-9a-f]* func\[/p'
```

### Comparing Builds

```bash
# Before optimization
zig build wasm
cp zig-out/bin/guillotine_mini.wasm /tmp/before.wasm

# Make changes...

# After optimization
zig build wasm
cp zig-out/bin/guillotine_mini.wasm /tmp/after.wasm

# Compare
ls -lh /tmp/before.wasm /tmp/after.wasm
twiggy diff /tmp/before.wasm /tmp/after.wasm
```

## References

- [twiggy documentation](https://rustwasm.github.io/twiggy/)
- [WABT tools](https://github.com/WebAssembly/wabt)
- [WebAssembly size optimization guide](https://rustwasm.github.io/book/reference/code-size.html)
- [Zig WASM target](https://ziglang.org/documentation/master/#WebAssembly)

## Script Help

```bash
bun scripts/analyze-wasm-size.ts --help
```

## Next Steps

1. **Run the analysis** to establish a baseline
2. **Identify optimization targets** from the reports
3. **Implement changes** (feature flags, code refactoring, etc.)
4. **Re-run analysis** to measure impact
5. **Track over time** in version control or CI

Good luck optimizing! 🚀
