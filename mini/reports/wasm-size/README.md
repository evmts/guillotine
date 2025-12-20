# WASM Size Analysis Report

**Generated:** 2025-10-20T18:57:18.105Z
**WASM File:** zig-out/bin/guillotine_mini.wasm
**Total Size:** 225K (230,721 bytes)

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

- `top.txt` - Top 30 functions by size
- `dominators.txt` - Top 30 dominators
- `paths.txt` - Top 30 call paths
- `garbage.txt` - Unused code


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

```bash
# Rebuild WASM
zig build wasm

# Analyze top functions
twiggy top zig-out/bin/guillotine_mini.wasm -n 30

# Analyze dominators
twiggy dominators zig-out/bin/guillotine_mini.wasm -n 30

# Analyze paths
twiggy paths zig-out/bin/guillotine_mini.wasm -n 30

# Find garbage
twiggy garbage zig-out/bin/guillotine_mini.wasm -n 30
```

## Reproduce This Report

```bash
bun scripts/analyze-wasm-size.ts --limit 30
```
