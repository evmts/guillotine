# METAPROMPT: Performance Optimization for Issue #341

## Your Task
You are implementing a performance optimization for **Issue #341: Mandatory analysis with extended entries for direct dispatch**.

## Issue Summary
Entry lookup performs multiple conditional checks consuming 1.59s (1.44%) of execution time. The current code falls back through extended entries → basic entries → build on the fly. This optimization mandates that all contracts have extended entries pre-computed, enabling direct array indexing without conditionals.

## Your Goal
Modify the code analysis system to ALWAYS build extended entries for all contracts, then simplify the interpreter to use direct array indexing without any conditional checks.

## Getting Started

1. **Read the full issue details**:
   ```bash
   gh issue view 341
   ```

2. **Review the performance optimization workflow**:
   - Read `/Users/williamcory/Guillotine/prompts/perf-single-issue.md`
   - This contains the complete workflow you should follow

3. **Key files to modify**:
   - `src/evm/frame/code_analysis.zig` - Analysis and ExtendedEntry struct
   - `src/evm/evm/interpret.zig` - Entry lookup code (around lines 118-154)
   - `src/evm/frame/contract.zig` - Contract initialization
   - `src/evm/opcodes/operation.zig` - Operation metadata

4. **Implementation approach**:
   ```zig
   // Always build extended entries
   pub fn analyze_code(...) !*CodeAnalysis {
       var analysis = try allocator.create(CodeAnalysis);
       
       // ALWAYS allocate extended entries for entire code
       analysis.extended_entries = try allocator.alloc(ExtendedEntry, code.len);
       
       // Initialize ALL entries
       for (analysis.extended_entries, 0..) |*entry, pc| {
           const opcode = if (pc < code.len) code[pc] else 0x00;
           const operation = jump_table.table[opcode];
           
           entry.* = ExtendedEntry{
               .operation = operation,
               .opcode_byte = opcode,
               .size = calculateInstructionSize(opcode, pc, code),
               .min_stack = operation.min_stack,
               .max_stack = operation.max_stack,
               .constant_gas = operation.constant_gas,
               .undefined = operation.undefined,
               // Pre-compute everything
               .is_jump = (opcode == 0x56 or opcode == 0x57),
               .is_push = (opcode >= 0x60 and opcode <= 0x7f),
               .push_size = if (opcode >= 0x60 and opcode <= 0x7f) opcode - 0x5f else 0,
           };
       }
       
       return analysis;
   }

   // Simplified direct lookup
   // In interpret.zig, replace complex lookup with:
   const entry = contract.analysis.?.extended_entries[pc];
   // That's it! No conditionals, no conversions

   // Enhanced ExtendedEntry
   pub const ExtendedEntry = struct {
       operation: *const Operation,
       opcode_byte: u8,
       size: u8,
       min_stack: u32,
       max_stack: u32,
       constant_gas: u64,
       undefined: bool,
       
       // New pre-computed fields
       is_jump: bool,
       is_push: bool,
       push_size: u8,
       stack_delta: i8,
       
       // Padding for cache optimization
       _padding: [8]u8 = undefined,
   };
   ```

5. **Use Test-Driven Development**:
   - Write tests verifying extended entries are always present
   - Test that analysis is mandatory before execution
   - Verify direct indexing works correctly
   - Test edge cases with code boundaries

6. **Implementation steps**:
   - Enhance ExtendedEntry struct with pre-computed fields
   - Modify analyze_code to always build entries
   - Update Contract.init to require analysis
   - Simplify interpreter lookup to direct indexing
   - Remove old conditional lookup code

7. **Validate your changes**:
   ```bash
   zig build test
   ```

8. **Run performance benchmarks**:
   ```bash
   ./scripts/perf-slow.sh
   ```

9. **Create a pull request**:
   - If performance improved: Create PR with results
   - If performance didn't improve: Create PR with "DO NOT MERGE" in title

## Expected Impact
- Entry lookup reduced to single array access
- No conditional branches in hot path
- Expected improvement: 1-2% overall performance
- Helps all benchmarks by reducing interpreter overhead

## Remember
- ALWAYS use `zig build test`, never just `zig build`
- Ensure all contracts have analysis before execution
- This trades memory for speed - acceptable tradeoff
- Verify no functionality is broken by mandatory analysis