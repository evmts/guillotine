# Task 4: Integrate Block Validation into Interpreter

<context>
You are modifying the interpreter to use block-based validation instead of per-instruction validation. This is the core integration that enables the performance improvement.

<prerequisites>
- Task 1-3 completed: Block structures, analysis, and unsafe operations exist
- Understanding of current interpreter loop in interpret.zig
- Knowledge that Frame holds execution state including PC
</prerequisites>

<critical_insight>
The interpreter must:
1. Detect when entering a new block
2. Validate gas and stack ONCE for the entire block
3. Switch to unsafe operations within blocks
4. Handle edge cases (GAS opcode, empty blocks)

EVMOne insights:
- BEGINBLOCK is an intrinsic operation at block start
- Gas correction needed for dynamic gas instructions
- Block validation failure must revert entire block
- Jump destinations still need validation (security)
</critical_insight>
</context>

<task>
<objective>
Modify the interpreter to use block validation and unsafe operations while maintaining correctness.
</objective>

<implementation_plan>
<phases>
1. Add block tracking state to Frame
2. Modify interpreter loop to detect block boundaries
3. Implement block validation logic
4. Switch between safe/unsafe operations based on mode
5. Handle special cases (GAS opcode correction)
</phases>

<frame_modifications>
Add to `src/evm/frame/frame.zig`:
```zig
pub const Frame = struct {
    // ... existing fields ...
    
    // Block execution state (add at end)
    current_block_idx: u16 = 0,
    block_gas_snapshot: u64 = 0,  // Gas when block was entered
    use_unsafe_ops: bool = false,  // Whether in block-validated mode
    block_gas_cost: u32 = 0,      // Current block's gas cost for corrections
    
    // Debug assertions
    comptime {
        // Ensure Frame size doesn't blow up cache line
        std.debug.assert(@sizeOf(Frame) < 4096);
    }
};
```
</frame_modifications>

<interpreter_modifications>
Modify `src/evm/evm/interpret.zig`:
```zig
pub fn interpret(self: *Vm, contract: *Contract, input: []const u8, is_static: bool) ExecutionError.Error!RunResult {
    // ... existing initialization ...
    
    // Ensure contract has analysis (lazy load if needed)
    if (contract.analysis == null and contract.code_size > 0) {
        contract.analysis = try Contract.analyze_code(self.allocator, contract.code, contract.code_hash);
    }
    
    const has_block_analysis = if (contract.analysis) |analysis| 
        analysis.block_metadata.len > 0 
    else 
        false;
    
    frame.use_unsafe_ops = has_block_analysis;
    
    while (frame.pc < contract.code_size) {
        // Block validation check
        if (has_block_analysis) {
            try validateBlockIfNeeded(&frame, contract);
        }
        
        const opcode = contract.get_op(frame.pc);
        
        // Choose operation table based on mode
        const result = if (frame.use_unsafe_ops)
            try executeUnsafe(self, &frame, opcode)
        else
            try self.table.execute(frame.pc, interpreter, state, opcode);
        
        // ... rest of existing logic ...
    }
}

fn validateBlockIfNeeded(frame: *Frame, contract: *Contract) !void {
    const analysis = contract.analysis.?;
    
    // Debug assertions for invariants
    std.debug.assert(frame.pc < contract.code_size);
    std.debug.assert(frame.pc < analysis.pc_to_block.len);
    
    // Check if at block boundary
    if (!analysis.block_starts.isSetUnchecked(frame.pc)) {
        return; // Not at boundary, continue
    }
    
    const block_idx = analysis.pc_to_block[frame.pc];
    
    // Only validate when entering new block
    if (block_idx == frame.current_block_idx) {
        return; // Still in same block
    }
    
    // Handle unreachable code (marked as maxInt)
    if (block_idx == std.math.maxInt(u16)) {
        return error.InvalidJump; // Unreachable code
    }
    
    const block = &analysis.block_metadata[block_idx];
    
    // CRITICAL: Single validation point for entire block
    
    // 1. Gas validation
    if (frame.gas_remaining < block.gas_cost) {
        return error.OutOfGas;
    }
    
    // 2. Stack underflow validation  
    const stack_size = @intCast(i16, frame.stack.size);
    if (stack_size < block.stack_req) {
        return error.StackUnderflow;
    }
    
    // 3. Stack overflow validation
    if (stack_size + block.stack_max > Stack.CAPACITY) {
        return error.StackOverflow;
    }
    
    // Validation passed - update state
    frame.gas_remaining -= block.gas_cost;
    frame.block_gas_snapshot = frame.gas_remaining + block.gas_cost; // Snapshot before deduction
    frame.block_gas_cost = block.gas_cost;
    frame.current_block_idx = block_idx;
    
    // Memory best practice: ensure block data stays in cache
    std.mem.doNotOptimizeAway(block);
}

fn executeUnsafe(vm: *Vm, frame: *Frame, opcode: u8) !ExecutionResult {
    // Get unsafe operation
    const operation = UNSAFE_OPERATIONS[opcode];
    
    if (operation.execute == null) {
        // Fallback to safe operation if unsafe not implemented
        return vm.table.execute(frame.pc, vm, frame, opcode);
    }
    
    // Execute without validation
    return operation.execute.?(frame.pc, vm, frame);
}
```
</interpreter_modifications>

<gas_opcode_handling>
Special handling for GAS opcode that needs actual remaining gas:
```zig
// In operation_unsafe.zig
pub fn gas_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackSpace(frame, 1);
    
    // EVMOne approach: restore gas before this instruction
    // Block deducted all gas upfront, need to add back what wasn't used yet
    const analysis = frame.contract.analysis.?;
    const current_pc_block = analysis.pc_to_block[pc];
    
    // Calculate gas used so far in this block
    var gas_used: u32 = 0;
    var check_pc = frame.pc - frame.current_block_idx;
    while (check_pc < pc) : (check_pc += 1) {
        if (analysis.pc_to_block[check_pc] != current_pc_block) break;
        const op = frame.contract.code[check_pc];
        gas_used += operation_config.OPERATIONS[op].constant_gas;
        if (opcode.is_push(op)) {
            check_pc += opcode.get_push_size(op);
        }
    }
    
    // Correct gas value
    const correction = frame.block_gas_cost - gas_used;
    const actual_gas = frame.gas_remaining + correction;
    
    frame.stack.append_unsafe(actual_gas);
    return ExecutionResult{ .pc_offset = 1 };
}
```
</gas_opcode_handling>

<edge_cases>
1. **Empty blocks**: Handle blocks with 0 gas cost
2. **Contract calls**: New execution context starts fresh
3. **Reverts**: Properly restore gas on revert
4. **Dynamic jumps**: Validate jump targets still use O(1) bitmap
5. **JUMPI fallthrough**: May continue to next block
6. **PC at code end**: Graceful termination
7. **Invalid opcodes**: Should never execute in valid blocks
8. **Stack exactly at limit**: Edge case for overflow check
</edge_cases>
</implementation_plan>

<testing>
Create comprehensive tests:
```zig
test "interpreter uses block validation" {
    const allocator = std.testing.allocator;
    
    // Contract with multiple blocks
    const code = [_]u8{
        0x60, 0x05,  // PUSH1 5
        0x60, 0x0a,  // PUSH1 10  
        0x56,        // JUMP
        0x5b,        // JUMPDEST
        0x01,        // ADD
        0x00,        // STOP
    };
    
    var contract = try Contract.init(...);
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &.{}, false);
    
    // Should execute successfully with block validation
    try std.testing.expect(result.status == .Success);
}

test "block validation catches stack underflow" {
    const allocator = std.testing.allocator;
    
    // Contract that would underflow without proper items
    const code = [_]u8{
        0x01,  // ADD (needs 2 items, have 0)
        0x00,  // STOP
    };
    
    var contract = try Contract.init(...);
    defer contract.deinit(allocator, null);
    
    const result = vm.interpret(&contract, &.{}, false);
    
    // Should catch at block boundary
    try std.testing.expectError(error.StackUnderflow, result);
}

test "GAS opcode returns correct value in block mode" {
    // Test that GAS opcode accounts for block gas consumption
    const allocator = std.testing.allocator;
    
    const code = [_]u8{
        0x5a,  // GAS
        0x00,  // STOP  
    };
    
    var contract = try Contract.init(...);
    contract.gas = 1000000;
    defer contract.deinit(allocator, null);
    
    const result = try vm.interpret(&contract, &.{}, false);
    
    // GAS should return actual remaining, not block-adjusted
    const gas_on_stack = frame.stack.pop();
    try std.testing.expect(gas_on_stack < 1000000); // Some gas was used
}
```
</testing>

<edge_case_tests>
Add tests for corner cases:
```zig
test "empty block handling" {
    const code = [_]u8{
        0x5b,  // JUMPDEST (empty block)
        0x5b,  // JUMPDEST (another empty block)
        0x00,  // STOP
    };
    
    // Should handle empty blocks without issues
    const result = try vm.interpret(&contract, &.{}, false);
    try std.testing.expectEqual(.Success, result.status);
}

test "block validation with exact stack limit" {
    // Create code that pushes exactly to stack limit
    var code = std.ArrayList(u8).init(allocator);
    defer code.deinit();
    
    // Push 1024 items (stack limit)
    for (0..1024) |_| {
        try code.appendSlice(&[_]u8{0x60, 0x01}); // PUSH1 1
    }
    try code.append(0x00); // STOP
    
    // Should succeed - exactly at limit
    const result = try vm.interpret(&contract, code.items, false);
    try std.testing.expectEqual(.Success, result.status);
    
    // One more would fail
    try code.insertSlice(0, &[_]u8{0x60, 0x01}); // Add one more PUSH
    const fail_result = vm.interpret(&contract, code.items, false);
    try std.testing.expectError(error.StackOverflow, fail_result);
}
```
</edge_case_tests>

<performance_validation>
Add benchmark to compare block vs traditional:
```zig
test "benchmark block validation performance" {
    const iterations = 10000;
    const code = @embedFile("../bench/erc20_transfer.bin");
    
    // Traditional mode
    vm.use_block_validation = false;
    const traditional_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = try vm.interpret(&contract, input, false);
    }
    const traditional_time = std.time.nanoTimestamp() - traditional_start;
    
    // Block mode  
    vm.use_block_validation = true;
    const block_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        _ = try vm.interpret(&contract, input, false);
    }
    const block_time = std.time.nanoTimestamp() - block_start;
    
    const improvement = (traditional_time - block_time) * 100 / traditional_time;
    std.debug.print("Performance improvement: {}%\n", .{improvement});
}
```
</performance_validation>

<benchmarking>
Add comprehensive zbench benchmarks:
```zig
const zbench = @import("zbench");

fn benchmarkBlockValidationOverhead(b: *zbench.Benchmark) void {
    const allocator = std.testing.allocator;
    
    // Test with contracts of varying block counts
    const contracts = [_]struct { name: []const u8, code: []const u8 }{
        .{ .name = "single_block", .code = &[_]u8{0x60, 0x01, 0x60, 0x02, 0x01, 0x00} },
        .{ .name = "many_blocks", .code = generateManyBlocks(100) },
        .{ .name = "complex_flow", .code = @embedFile("test_data/complex_jumps.bin") },
    };
    
    for (contracts) |test_contract| {
        var contract = Contract.init(allocator, test_contract.code, ...) catch unreachable;
        defer contract.deinit(allocator, null);
        
        b.run(for (0..b.iterations) |_| {
            var frame = Frame.init(...) catch unreachable;
            defer frame.deinit();
            
            // Measure block validation overhead
            validateBlockIfNeeded(&frame, &contract) catch unreachable;
        });
    }
}

fn benchmarkGasOpcodeCorrection(b: *zbench.Benchmark) void {
    // Benchmark GAS opcode with correction vs without
    const code_with_gas = [_]u8{
        0x60, 0x01,  // PUSH1 1
        0x60, 0x02,  // PUSH1 2  
        0x01,        // ADD
        0x5a,        // GAS
        0x00,        // STOP
    };
    
    b.run(for (0..b.iterations) |_| {
        const result = gas_unsafe(3, &vm, &frame) catch unreachable;
        std.mem.doNotOptimizeAway(result);
    });
}
```
</benchmarking>

<memory_best_practices>
1. **Cache block metadata**: Keep frequently accessed blocks in L1 cache
2. **Minimize frame size**: Added fields should not bloat Frame struct
3. **Avoid allocations**: Block validation should never allocate
4. **Prefetch analysis**: Hint CPU to prefetch next block metadata
5. **Hot path optimization**: Common case (staying in block) should be fast
</memory_best_practices>
</task>

<success_criteria>
- [ ] Frame has block tracking fields
- [ ] Interpreter detects block boundaries correctly
- [ ] Block validation happens once per block
- [ ] Unsafe operations are used within blocks
- [ ] GAS opcode returns correct values
- [ ] All existing tests continue to pass
- [ ] Performance improvement is measurable
- [ ] Edge cases are handled correctly
</success_criteria>

<risks>
- Incorrect block boundary detection could skip validation
- Gas calculation errors could allow infinite loops
- Stack validation errors could cause memory corruption
Mitigation: Extensive testing and gradual rollout
</risks>