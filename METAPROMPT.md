# METAPROMPT: Performance Optimization for Issue #334

## Your Task
You are implementing a performance optimization for **Issue #334: Direct memory access vs API abstraction overhead**.

## Issue Summary
Memory operations (MLOAD, MSTORE, etc.) currently go through multiple API layers with separate calls for gas calculation, capacity checking, and data operations. This adds significant overhead in the critical path compared to evmone's more direct approach.

## Your Goal
Create a unified memory operation that combines gas calculation, memory expansion, and bounds checking into a single function, then provide direct memory access for operations.

## Getting Started

1. **Read the full issue details**:
   ```bash
   gh issue view 334
   ```

2. **Review the performance optimization workflow**:
   - Read `/Users/williamcory/Guillotine/prompts/perf-single-issue.md`
   - This contains the complete workflow you should follow

3. **Key files to modify**:
   - `src/evm/execution/memory.zig` - MLOAD/MSTORE implementations
   - `src/evm/memory/memory.zig` or `src/evm/memory/context.zig` - Memory management
   - Look for gas calculation and expansion functions

4. **Implementation approach**:
   ```zig
   // Unified memory check function
   pub inline fn checkMemory(
       frame: *Frame,
       offset: usize,
       size: usize,
   ) !void {
       const new_size = offset + size;
       const current_size = frame.memory.size();
       
       if (new_size > current_size) {
           // Calculate gas for expansion
           const new_words = (new_size + 31) / 32;
           const current_words = (current_size + 31) / 32;
           const gas_cost = calculateMemoryCost(new_words) - calculateMemoryCost(current_words);
           
           // Check gas and expand in one go
           try frame.consumeGasAndExpandMemory(gas_cost, new_size);
       }
   }

   // Optimized MSTORE
   pub fn op_mstore(...) {
       // Single check
       try checkMemory(frame, offset_usize, 32);
       
       // Direct memory write
       const value_bytes = @bitCast([32]u8, value);
       @memcpy(frame.memory.data[offset_usize..][0..32], &value_bytes);
   }

   // Optimized MLOAD
   pub fn op_mload(...) {
       // Single check
       try checkMemory(frame, offset_usize, 32);
       
       // Direct memory read
       var value: u256 = 0;
       @memcpy(@ptrCast(&value), frame.memory.data[offset_usize..][0..32]);
       frame.stack.append_unsafe(value);
   }
   ```

5. **Use Test-Driven Development**:
   - Write tests for MLOAD, MSTORE, MSTORE8 operations
   - Test memory expansion scenarios
   - Verify gas calculation remains correct
   - Test edge cases: large offsets, out-of-gas scenarios

6. **Optimization targets**:
   - Combine gas check + memory expansion
   - Remove intermediate buffers
   - Provide direct data pointer access
   - Inline common cases

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
- Reduce function call overhead for memory operations
- Eliminate redundant checks across API layers
- Expected improvement: 5-10% on memory-intensive benchmarks
- Should help with `snailtracer` and `ten-thousand-hashes`

## Remember
- ALWAYS use `zig build test`, never just `zig build`
- Ensure gas calculations remain accurate
- Maintain memory safety while optimizing
- Test out-of-gas scenarios thoroughly