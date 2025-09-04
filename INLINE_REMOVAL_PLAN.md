# Inline Removal Implementation Plan

## This PR: Proof of Concept (MINIMAL)

This PR demonstrates the approach for removing unnecessary inline annotations. 

### What's Included (MINIMAL):
1. **Basic benchmark framework** (`src/evm/bench_inline_impact.zig`)
   - Shows how we'll measure performance impact
   - Includes regression calculation logic
   - TODOs for complete implementation

2. **Example inline removals** (2 files modified):
   - `created_contracts.zig`: Removed inline from 3 simple HashMap wrapper functions
   - `bytecode.zig`: Removed inline from 2 simple getter functions
   
3. **Documentation of approach** (this file)

### What's NOT Implemented (Intentionally):
- Complete baseline measurement system (TODO comments)
- Full test suite for performance regression
- Binary size tracking
- Stack operation analysis (critical path - needs careful measurement)
- Gas calculation function analysis
- Integration with existing zbench system

## Rationale for Examples

### Created Contracts Functions (SAFE)
These are simple HashMap wrappers:
```zig
// BEFORE: pub inline fn init(allocator: std.mem.Allocator) CreatedContracts
// AFTER:  pub fn init(allocator: std.mem.Allocator) CreatedContracts
```
**Why safe**: Single-line functions wrapping standard library calls. Compiler will inline automatically when beneficial.

### Bytecode Getters (SAFE) 
Simple getters with no complex logic:
```zig
// BEFORE: pub inline fn len(self: Self) PcType
// AFTER:  pub fn len(self: Self) PcType
```
**Why safe**: Simple field access with type conversion. Modern compilers excel at inlining these patterns.

## Next Steps (NOT in this PR)

1. **Establish baselines**: Run comprehensive benchmarks with current inline annotations
2. **Implement full framework**: Complete the TODO items in `bench_inline_impact.zig`
3. **Critical path analysis**: Carefully measure stack operations (may keep inline)
4. **Gas calculation testing**: A/B test complex mathematical functions
5. **Documentation**: Create inline usage guidelines

## Testing Strategy

### Current (Minimal)
- Basic regression calculation logic
- Framework structure validation

### Future (Complete TDD)
- Performance regression tests (RED → GREEN → REFACTOR)
- Binary size tracking tests
- Architecture-specific validation

## Risk Mitigation

- **ONLY removed obvious safe inlines** (HashMap wrappers, simple getters)
- **Added clear comments** explaining removal rationale
- **Preserved critical path inlines** (stack operations untouched)
- **Created measurement framework** for data-driven decisions

## Performance Expectations

**Expected impact of this PR**: 
- ✅ No performance regression (functions too simple to benefit from inline)
- ✅ Slight binary size reduction
- ✅ Cleaner code without unnecessary annotations
- ✅ Demonstration of systematic approach