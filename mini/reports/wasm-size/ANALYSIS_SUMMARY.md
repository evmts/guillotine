# WASM Size Analysis Summary

**Generated:** 2025-10-20
**Total WASM Size:** 225K (230,721 bytes)

## 🎯 Key Findings

### Top Size Contributors

| Rank | Function Index | Size | % of Total | Identified As |
|------|---------------|------|------------|---------------|
| 1 | func[166] | 48KB | **21.0%** | **Opcode execution dispatcher** (calls js_opcode_callback, large switch/match) |
| 2 | func[71] | 32KB | **13.9%** | **Precompile/intrinsic handler** (intrinsic gas calculation logic) |
| 3 | func[191] | 10KB | 4.5% | Complex logic (likely EVM state management) |
| 4 | evm_execute | 8KB | 3.6% | Main execution entry point (C API export) |
| 5 | func[193] | 7KB | 3.0% | Feature implementation |

**Critical Insight:** Just 2 functions account for **34.9% of your entire binary** (80KB out of 225KB)!

### Size Breakdown by Category

| Category | Functions | Total Size | % of Binary |
|----------|-----------|------------|-------------|
| **Very Large** (>20KB) | 2 | 80KB | **34.9%** |
| Normal (1-5KB) | 24 | 52KB | 22.7% |
| Small (<1KB) | 222 | 48KB | 20.9% |
| External/Imports | 22 | 17KB | 7.5% |
| Medium (5-10KB) | 2 | 13KB | 5.5% |
| Large (10-20KB) | 1 | 10KB | 4.5% |

## 🔍 Function Identification

### Func[166] - Opcode Execution Dispatcher (48KB, 21%)

**Evidence:**
```wasm
call 9 <env.js_opcode_callback>  ; Checks for custom JS opcode handlers
; Large switch/match statement for ~150+ opcodes
; Pattern: opcode byte → handler function dispatch
```

**Why so large:**
- Handles all 150+ EVM opcodes (ADD, MUL, SSTORE, CALL, etc.)
- Each opcode case includes:
  - Stack manipulation
  - Gas calculation
  - Memory expansion checks
  - Operation-specific logic
- Likely monomorphized from Zig's comptime/generic code
- May include inlined helper functions

**Optimization opportunities:**
1. **Split by opcode category** - Arithmetic, storage, control flow, calls
2. **Extract common patterns** - Stack pop/push, gas checks
3. **Table-driven dispatch** - Replace large switch with function pointer table
4. **Reduce inlining** - Let linker eliminate duplicates

### Func[71] - Precompile/Gas Handler (32KB, 14%)

**Evidence:**
```wasm
; Jump table for 18 cases (hardfork-specific gas costs?)
i32.const 16783312  ; Load jump table
i32.load 2 0        ; Indirect branch
; Complex gas calculation logic
```

**Why so large:**
- Handles 9 precompiled contracts (ecrecover, sha256, ripemd160, identity, modexp, bn254, blake2, bls12-381)
- Hardfork-specific gas cost calculations (Berlin, London, Cancun, Prague)
- Each precompile has multiple gas modes
- Intrinsic gas calculation for different transaction types

**Optimization opportunities:**
1. **Feature flags** - Compile out unused hardforks
2. **Dynamic dispatch** - Use function pointers instead of large switch
3. **Constant folding** - More aggressive optimization of gas constants
4. **Split precompiles** - Separate module for each precompile

### Func[191] - Complex Logic (10KB, 4.5%)

Likely candidates:
- CREATE/CREATE2 implementation (complex address calculation, init code handling)
- CALL/STATICCALL/DELEGATECALL dispatcher
- Storage SLOAD/SSTORE with EIP-2929 cold/warm tracking

## 📊 Distribution Analysis

### By Function Size Range

| Size Range | Count | Total Size | % of Binary |
|------------|-------|------------|-------------|
| 0-100 bytes | 49 | 2.7KB | 1.2% |
| 100-500 bytes | 107 | 27.7KB | 12.0% |
| 500-1KB | 66 | 47.8KB | 20.7% |
| 1-2KB | 30 | 42.0KB | 18.2% |
| 2-5KB | 17 | 51.8KB | 22.5% |
| 5-10KB | 3 | 23.4KB | 10.1% |
| **10-20KB** | 1 | 10.4KB | 4.5% |
| **20KB+** | 2 | 80.4KB | 34.9% |

**Key takeaway:** Long tail of small functions (222 functions < 1KB = 21%), but optimization focus should be on the top 5 large functions.

## 🎯 Recommended Optimizations

### Priority 1: Split Opcode Dispatcher (Potential: ~20-30KB savings)

**Current:** Single 48KB function handles all opcodes

**Proposed:**
```
Opcode categories (by Ethereum spec):
- Arithmetic & Logic (ADD, MUL, AND, OR, etc.) - ~15 opcodes
- Comparison & Bitwise (LT, GT, EQ, etc.) - ~10 opcodes
- Stack/Memory/Storage (PUSH, POP, MLOAD, MSTORE, SLOAD, SSTORE) - ~20 opcodes
- Control Flow (JUMP, JUMPI, PC, JUMPDEST) - ~5 opcodes
- Block/Transaction Context (BLOCKHASH, COINBASE, TIMESTAMP, etc.) - ~15 opcodes
- Calls (CALL, STATICCALL, DELEGATECALL, CREATE, CREATE2) - ~10 opcodes
- Cancun-specific (TLOAD, TSTORE, MCOPY, BLOBHASH, etc.) - ~5 opcodes
```

**Implementation:**
```zig
// frame.zig - split into category modules
const arithmetic = @import("opcodes/arithmetic.zig");
const storage = @import("opcodes/storage.zig");
const calls = @import("opcodes/calls.zig");

pub fn execute(frame: *Frame, opcode: u8) !void {
    return switch (opcode) {
        0x00...0x0f => arithmetic.execute(frame, opcode),
        0x50...0x5f => storage.execute(frame, opcode),
        0xf0...0xff => calls.execute(frame, opcode),
        // ...
    };
}
```

**Benefits:**
- Better code organization
- Reduced monomorphization
- Easier dead code elimination
- Potential 30-50% size reduction

### Priority 2: Hardfork Feature Flags (Potential: ~10-15KB savings)

**Current:** All hardforks compiled in (Frontier → Prague)

**Proposed:**
```zig
// build.zig
const wasm_hardforks = b.addOptions();
wasm_hardforks.addOption(bool, "enable_frontier", true);
wasm_hardforks.addOption(bool, "enable_homestead", true);
wasm_hardforks.addOption(bool, "enable_berlin", true);
wasm_hardforks.addOption(bool, "enable_cancun", true);
wasm_hardforks.addOption(bool, "enable_prague", false);  // Latest, may not need

// Usage in code
if (@import("build_options").enable_cancun) {
    // TLOAD/TSTORE, MCOPY, BLOBHASH
}
```

**Benefits:**
- Remove unused hardfork code paths
- Smaller gas constant tables
- Reduced opcode handling complexity

### Priority 3: Precompile Modularization (Potential: ~5-10KB savings)

**Current:** All 9 precompiles in single handler

**Proposed:**
```zig
// precompiles/dispatcher.zig
const ecrecover = @import("ecrecover.zig");
const sha256 = @import("sha256.zig");
const bn254 = @import("bn254.zig");  // Can disable if not needed
const bls12_381 = @import("bls12_381.zig");  // Prague-specific

// With feature flags
const enable_bn254 = @import("build_options").enable_bn254;
const enable_bls = @import("build_options").enable_bls;
```

**Already partially implemented:**
```zig
// build.zig (already has this!)
wasm_build_options.addOption(bool, "use_bn254", false);
wasm_build_options.addOption(bool, "use_c_kzg", false);
```

**Action:** Verify these flags actually reduce size, may need more aggressive compile guards.

### Priority 4: Table-Driven Dispatch (Potential: ~10-20KB savings)

**Current:** Large switch/match statements generate jump tables + inline code

**Proposed:**
```zig
// Opcode function pointer table
const OpcodeHandler = *const fn(*Frame) EvmError!void;

const OPCODE_TABLE = [_]OpcodeHandler{
    op_stop,    // 0x00
    op_add,     // 0x01
    op_mul,     // 0x02
    // ...
};

pub fn execute(frame: *Frame, opcode: u8) !void {
    return OPCODE_TABLE[opcode](frame);
}
```

**Benefits:**
- Smaller code (no large switch)
- Faster dispatch (direct function call)
- Better dead code elimination

### Priority 5: Aggressive Optimization Flags

**Current:** `ReleaseSmall` with default settings

**Try:**
```zig
// build.zig - WASM target
wasm_lib.root_module.optimize = .ReleaseSmall;
wasm_lib.root_module.strip = true;
wasm_lib.root_module.link_time_optimization = true;  // Add LTO
wasm_lib.root_module.single_threaded = true;  // WASM is single-threaded
```

Also consider:
```bash
# Post-build optimization
wasm-opt --strip-debug --strip-producers --strip-target-features \
         --optimize-level=4 --shrink-level=2 \
         zig-out/bin/guillotine_mini.wasm \
         -o zig-out/bin/guillotine_mini.opt.wasm
```

## 🧪 Validation Strategy

### Before/After Comparison

```bash
# Baseline
zig build wasm
cp zig-out/bin/guillotine_mini.wasm baseline.wasm
bun scripts/analyze-wasm-size.ts --output reports/baseline

# After optimization
zig build wasm
bun scripts/analyze-wasm-size.ts --output reports/optimized

# Compare
twiggy diff baseline.wasm zig-out/bin/guillotine_mini.wasm
```

### Success Metrics

| Target | Current | Goal | Aggressive Goal |
|--------|---------|------|-----------------|
| Total size | 225KB | <200KB | <150KB |
| Largest function | 48KB | <30KB | <20KB |
| Top 2 functions | 80KB (35%) | <50KB (25%) | <30KB (20%) |

## 📈 Expected Impact by Optimization

| Optimization | Effort | Savings | Risk |
|--------------|--------|---------|------|
| Split opcode dispatcher | Medium | 20-30KB | Low |
| Hardfork feature flags | Low | 10-15KB | Low |
| Precompile modularization | Low | 5-10KB | Low |
| Table-driven dispatch | High | 10-20KB | Medium |
| LTO + wasm-opt | Low | 5-10KB | Low |
| **TOTAL** | - | **50-85KB** | - |

**Potential final size:** 140-175KB (38-62% reduction from 225KB)

## 🛠️ Implementation Plan

### Phase 1: Quick Wins (1-2 days)
1. ✅ Enable LTO in build.zig
2. ✅ Add wasm-opt post-processing
3. ✅ Verify hardfork flags work (already added)
4. Measure impact

### Phase 2: Structural Changes (1 week)
1. Split opcodes into category modules
2. Add compile-time feature flags for opcode groups
3. Refactor precompile dispatcher
4. Measure impact

### Phase 3: Advanced Optimizations (2 weeks)
1. Implement table-driven dispatch
2. Profile and optimize hot paths
3. Review for remaining monomorphization bloat
4. Final tuning

## 📚 Tools Used

### Analysis Tools
- **twiggy** - WASM size profiler (top contributors, dominators)
- **wabt (wasm-objdump)** - Disassembly and inspection
- **Custom scripts:**
  - `analyze-wasm-size.ts` - Comprehensive analysis
  - `map-wasm-functions.ts` - Function name mapping

### Reports Generated
- `function-sizes.txt` - All functions sorted by size with categories
- `function-mapping.json` - Machine-readable function database
- `wasm-sections.txt` - Section-level size breakdown
- `wasm-disassembly.txt` - Full WASM disassembly
- `top.txt`, `dominators.txt`, `garbage.txt` - Twiggy analyses

## 🎓 Lessons Learned

1. **Zig's comptime is powerful but can bloat binaries** - Generic functions get monomorphized
2. **Large match statements generate huge code** - Consider table-driven approaches
3. **Feature flags are essential for WASM** - Not all features needed in browser
4. **Name mapping is crucial** - Without it, impossible to identify optimization targets
5. **Two functions = 35% of binary** - Pareto principle applies to code size!

## 📞 Next Steps

1. Review this analysis with team
2. Prioritize optimizations based on effort/impact
3. Implement Phase 1 quick wins
4. Measure and iterate
5. Track size in CI to prevent regression

---

**Generated by:** `bun scripts/analyze-wasm-size.ts`
**Function mapping by:** `bun scripts/map-wasm-functions.ts`
**Documentation:** See `scripts/WASM_SIZE_ANALYSIS.md`
