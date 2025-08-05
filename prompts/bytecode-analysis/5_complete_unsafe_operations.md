# Task 5: Complete All Unsafe Operations

<context>
You are completing the conversion of all EVM operations to unsafe variants. Task 3 created core operations, and Task 4 integrated block validation. Now we need to convert the remaining ~200 operations.

<prerequisites>
- Tasks 1-4 completed and working
- Core unsafe operations demonstrate the pattern
- Block validation is functioning in interpreter
</prerequisites>

<strategy>
Group operations by category and convert systematically:
1. Remaining arithmetic/bitwise operations
2. Environmental operations (ADDRESS, BALANCE, etc.)
3. Memory/storage operations
4. Control flow (JUMP, JUMPI - special handling)
5. System operations (CALL, CREATE - complex)

EVMOne insights:
- ~200 operations total, but many are similar patterns
- Invalid/undefined ops can stay as safe fallback
- CALL/CREATE ops have complex gas - keep parts safe
- Debug assertions critical for catching bugs
</strategy>
</context>

<task>
<objective>
Convert all remaining operations to unsafe variants following established patterns.
</objective>

<implementation_approach>
<file_organization>
Split operations into logical files in `src/evm/execution/unsafe/`:
```
unsafe/
├── arithmetic.zig      # ADD, MUL, DIV, MOD, EXP, etc.
├── bitwise.zig        # AND, OR, XOR, NOT, SHL, SHR, etc.
├── comparison.zig     # LT, GT, EQ, ISZERO, etc.
├── stack.zig          # DUP1-16, SWAP1-16, POP
├── memory.zig         # MLOAD, MSTORE, MSIZE, etc.
├── storage.zig        # SLOAD, SSTORE
├── environmental.zig  # ADDRESS, BALANCE, CALLER, etc.
├── block_info.zig     # BLOCKHASH, COINBASE, TIMESTAMP, etc.
├── control.zig        # JUMP, JUMPI, PC, JUMPDEST
├── system.zig         # CALL, CREATE, RETURN, REVERT
└── mod.zig           # Module that exports all operations
```
</file_organization>

<pattern_examples>
<arithmetic_remaining>
```zig
// In arithmetic.zig
pub fn mod_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 2);
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.pop_unsafe();
    const result = if (b == 0) 0 else a % b;
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(result);
    return ExecutionResult{ .pc_offset = 1 };
}

pub fn addmod_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 3);
    const n = frame.stack.pop_unsafe();
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.pop_unsafe();
    
    const result = if (n == 0) 0 else blk: {
        // Use 512-bit arithmetic to prevent overflow
        const a_wide = @as(u512, a);
        const b_wide = @as(u512, b);
        const sum = a_wide + b_wide;
        break :blk @intCast(u256, sum % n);
    };
    
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(result);
    return ExecutionResult{ .pc_offset = 1 };
}

pub fn exp_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 2);
    const exponent = frame.stack.pop_unsafe();
    const base = frame.stack.pop_unsafe();
    
    // EXP has dynamic gas, but base cost was already charged by block
    // TODO: Dynamic gas needs special handling like CALL/SSTORE
    const result = std.math.pow(u256, base, exponent);
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(result);
    
    return ExecutionResult{ .pc_offset = 1 };
}
```
</arithmetic_remaining>

<environmental_ops>
```zig
// In environmental.zig
pub fn address_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    const addr = frame.contract.address.toInt();
    frame.stack.append_unsafe(addr);
    return ExecutionResult{ .pc_offset = 1 };
}

pub fn balance_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    const vm: *Vm = @ptrCast(@alignCast(interpreter));
    
    assertStackHas(frame, 1);
    const addr_int = frame.stack.pop_unsafe();
    const addr = Address.fromInt(addr_int);
    
    // Still need to access state (can fail)
    // This is where unsafe ops can still error
    const balance = try vm.state.get_balance(addr);
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(balance);
    
    return ExecutionResult{ .pc_offset = 1 };
}

pub fn caller_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    frame.stack.append_unsafe(frame.contract.caller.toInt());
    return ExecutionResult{ .pc_offset = 1 };
}
```
</environmental_ops>

<control_flow_special>
```zig
// In control.zig - SPECIAL HANDLING
pub fn jump_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 1);
    const dest = frame.stack.pop_unsafe();
    
    // Still must validate jump destination!
    // This is security critical - never skip
    if (!frame.contract.valid_jumpdest(frame.allocator, dest)) {
        return error.InvalidJump;
    }
    
    // Debug assertion: destination should be valid JUMPDEST
    std.debug.assert(frame.contract.code[@intCast(usize, dest)] == 0x5b);
    
    // Set PC directly instead of returning offset
    frame.pc = @intCast(usize, dest);
    return ExecutionResult{ .pc_offset = 0 }; // PC already updated
}

pub fn jumpi_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 2);
    const dest = frame.stack.pop_unsafe();
    const condition = frame.stack.pop_unsafe();
    
    if (condition != 0) {
        // Still must validate jump destination!
        if (!frame.contract.valid_jumpdest(frame.allocator, dest)) {
            return error.InvalidJump;
        }
        std.debug.assert(frame.contract.code[@intCast(usize, dest)] == 0x5b);
        frame.pc = @intCast(usize, dest);
        return ExecutionResult{ .pc_offset = 0 };
    }
    
    return ExecutionResult{ .pc_offset = 1 };
}

pub fn pc_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    frame.stack.append_unsafe(pc);
    return ExecutionResult{ .pc_offset = 1 };
}
```
</control_flow_special>

<system_ops_complex>
```zig
// In system.zig - These still have complex gas calculations
pub fn call_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    const vm: *Vm = @ptrCast(@alignCast(interpreter));
    
    assertStackHas(frame, 7);
    // Pop arguments without validation
    const gas = frame.stack.pop_unsafe();
    const to = frame.stack.pop_unsafe();
    const value = frame.stack.pop_unsafe();
    const in_offset = frame.stack.pop_unsafe();
    const in_size = frame.stack.pop_unsafe();
    const out_offset = frame.stack.pop_unsafe();
    const out_size = frame.stack.pop_unsafe();
    
    // Complex gas calculation still needed for call
    // Memory expansion, account access, value transfer, etc.
    // This is where dynamic gas comes in
    
    // Memory best practice: validate before expansion
    const in_end = try std.math.add(u256, in_offset, in_size);
    const out_end = try std.math.add(u256, out_offset, out_size);
    const mem_size = @max(in_end, out_end);
    if (mem_size > memory_limits.MAX_MEMORY_SIZE) {
        return error.OutOfMemory;
    }
    
    // ... rest of CALL implementation ...
    
    const success = try vm.call_contract(...);
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(if (success) 1 else 0);
    
    return ExecutionResult{ .pc_offset = 1 };
}
```
</system_ops_complex>
</pattern_examples>

<additional_patterns>
<bitwise_operations>
```zig
// In bitwise.zig
pub fn and_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 2);
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.pop_unsafe();
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(a & b);
    return ExecutionResult{ .pc_offset = 1 };
}

pub fn shl_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 2);
    const shift = frame.stack.pop_unsafe();
    const value = frame.stack.pop_unsafe();
    const result = if (shift >= 256) 0 else value << @intCast(u8, shift);
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(result);
    return ExecutionResult{ .pc_offset = 1 };
}
```
</bitwise_operations>

<comparison_operations>
```zig
// In comparison.zig  
pub fn lt_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 2);
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.pop_unsafe();
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(if (a < b) 1 else 0);
    return ExecutionResult{ .pc_offset = 1 };
}

pub fn iszero_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 1);
    const value = frame.stack.pop_unsafe();
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(if (value == 0) 1 else 0);
    return ExecutionResult{ .pc_offset = 1 };
}
```
</comparison_operations>
</additional_patterns>

<operation_table>
Create `src/evm/jump_table/unsafe_operations_table.zig`:
```zig
const unsafe = @import("../execution/unsafe/mod.zig");
const Operation = @import("../opcodes/operation.zig").Operation;

pub const UNSAFE_OPERATIONS = blk: {
    var table: [256]Operation = undefined;
    
    // Initialize all to undefined
    for (0..256) |i| {
        table[i] = Operation{
            .execute = null,
            .constant_gas = 0,
            .min_stack = 0,
            .max_stack = 0,
            .undefined = true,
        };
    }
    
    // Arithmetic
    table[0x01] = .{ .execute = unsafe.add_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x02] = .{ .execute = unsafe.mul_unsafe, .constant_gas = 5, .min_stack = 2, .max_stack = 1 };
    table[0x03] = .{ .execute = unsafe.sub_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x04] = .{ .execute = unsafe.div_unsafe, .constant_gas = 5, .min_stack = 2, .max_stack = 1 };
    // Arithmetic
    table[0x01] = .{ .execute = unsafe.add_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x02] = .{ .execute = unsafe.mul_unsafe, .constant_gas = 5, .min_stack = 2, .max_stack = 1 };
    table[0x03] = .{ .execute = unsafe.sub_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x04] = .{ .execute = unsafe.div_unsafe, .constant_gas = 5, .min_stack = 2, .max_stack = 1 };
    table[0x05] = .{ .execute = unsafe.sdiv_unsafe, .constant_gas = 5, .min_stack = 2, .max_stack = 1 };
    table[0x06] = .{ .execute = unsafe.mod_unsafe, .constant_gas = 5, .min_stack = 2, .max_stack = 1 };
    table[0x07] = .{ .execute = unsafe.smod_unsafe, .constant_gas = 5, .min_stack = 2, .max_stack = 1 };
    table[0x08] = .{ .execute = unsafe.addmod_unsafe, .constant_gas = 8, .min_stack = 3, .max_stack = 1 };
    table[0x09] = .{ .execute = unsafe.mulmod_unsafe, .constant_gas = 8, .min_stack = 3, .max_stack = 1 };
    table[0x0a] = .{ .execute = unsafe.exp_unsafe, .constant_gas = 10, .min_stack = 2, .max_stack = 1 };
    table[0x0b] = .{ .execute = unsafe.signextend_unsafe, .constant_gas = 5, .min_stack = 2, .max_stack = 1 };
    
    // Comparison
    table[0x10] = .{ .execute = unsafe.lt_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x11] = .{ .execute = unsafe.gt_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x12] = .{ .execute = unsafe.slt_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x13] = .{ .execute = unsafe.sgt_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x14] = .{ .execute = unsafe.eq_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x15] = .{ .execute = unsafe.iszero_unsafe, .constant_gas = 3, .min_stack = 1, .max_stack = 1 };
    
    // Bitwise
    table[0x16] = .{ .execute = unsafe.and_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x17] = .{ .execute = unsafe.or_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x18] = .{ .execute = unsafe.xor_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x19] = .{ .execute = unsafe.not_unsafe, .constant_gas = 3, .min_stack = 1, .max_stack = 1 };
    table[0x1a] = .{ .execute = unsafe.byte_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x1b] = .{ .execute = unsafe.shl_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x1c] = .{ .execute = unsafe.shr_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    table[0x1d] = .{ .execute = unsafe.sar_unsafe, .constant_gas = 3, .min_stack = 2, .max_stack = 1 };
    
    // ... continue for all 256 opcodes ...
    
    break :blk table;
};
```
</operation_table>

<special_considerations>
1. **Memory operations**: Still need expansion checks (can fail)
2. **State access**: Still need error handling for missing accounts
3. **Dynamic gas**: CALL, CREATE, EXP, etc. need additional gas calculation
4. **Terminating ops**: STOP, RETURN, REVERT end execution
5. **Invalid opcodes**: Should never be reached in valid blocks
6. **Debug builds**: All assertions active for catching bugs
7. **Release builds**: Assertions compile away for max performance
</special_considerations>
</implementation_approach>

<testing_strategy>
```zig
// Comprehensive test for each category
test "all arithmetic operations unsafe" {
    const ops = [_]u8{
        0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b,
    };
    
    for (ops) |opcode| {
        // Verify unsafe operation exists
        try std.testing.expect(UNSAFE_OPERATIONS[opcode].execute != null);
        
        // Verify it works correctly
        var frame = try createTestFrame();
        defer frame.deinit();
        
        // Setup appropriate stack
        setupStackForOpcode(&frame, opcode);
        
        // Execute
        const result = try UNSAFE_OPERATIONS[opcode].execute.?(0, null, &frame);
        
        // Verify result
        verifyResultForOpcode(&frame, opcode);
    }
}

// Differential testing against safe operations
test "unsafe operations match safe operations" {
    const test_cases = [_]struct {
        code: []const u8,
        input: []const u8,
        expected_output: []const u8,
    }{
        // Add comprehensive test cases
    };
    
    for (test_cases) |case| {
        // Run with safe operations
        vm.use_block_validation = false;
        const safe_result = try vm.interpret(...);
        
        // Run with unsafe operations  
        vm.use_block_validation = true;
        const unsafe_result = try vm.interpret(...);
        
        // Results must match exactly
        try std.testing.expectEqualSlices(u8, safe_result.output, unsafe_result.output);
        try std.testing.expectEqual(safe_result.gas_left, unsafe_result.gas_left);
    }
}
```
</testing_strategy>

<benchmarking>
Add zbench to measure conversion progress:
```zig
const zbench = @import("zbench");

fn benchmarkOpcodeCategories(b: *zbench.Benchmark) void {
    const categories = [_]struct {
        name: []const u8,
        opcodes: []const u8,
    }{
        .{ .name = "arithmetic", .opcodes = &[_]u8{0x01, 0x02, 0x03, 0x04, 0x05} },
        .{ .name = "bitwise", .opcodes = &[_]u8{0x16, 0x17, 0x18, 0x19, 0x1b} },
        .{ .name = "stack", .opcodes = &[_]u8{0x50, 0x80, 0x81, 0x90, 0x91} },
        .{ .name = "memory", .opcodes = &[_]u8{0x51, 0x52, 0x53, 0x59} },
    };
    
    for (categories) |cat| {
        var total_safe: u64 = 0;
        var total_unsafe: u64 = 0;
        
        b.run(for (0..b.iterations) |_| {
            for (cat.opcodes) |op| {
                // Time safe operation
                const safe_start = std.time.nanoTimestamp();
                _ = SAFE_OPERATIONS[op].execute.?(0, &vm, &frame) catch {};
                total_safe += std.time.nanoTimestamp() - safe_start;
                
                // Time unsafe operation
                const unsafe_start = std.time.nanoTimestamp();
                _ = UNSAFE_OPERATIONS[op].execute.?(0, &vm, &frame) catch {};
                total_unsafe += std.time.nanoTimestamp() - unsafe_start;
            }
        });
        
        const speedup = @intToFloat(f64, total_safe) / @intToFloat(f64, total_unsafe);
        std.debug.print("{s}: {d:.2}x speedup\n", .{ cat.name, speedup });
    }
}
```
</benchmarking>

<memory_best_practices>
1. **Zero allocations**: No unsafe op should ever allocate
2. **Inline everything**: Small functions for CPU to inline
3. **Minimize branches**: Predictable code paths
4. **Data locality**: Access frame fields sequentially
5. **Avoid indirection**: Direct field access, no pointers
</memory_best_practices>
</task>

<success_criteria>
- [ ] All 256 opcodes have unsafe variants (where applicable)
- [ ] Operations are organized into logical modules
- [ ] Special cases (JUMP, CALL, etc.) handle correctly
- [ ] Comprehensive tests for each operation category
- [ ] Differential testing confirms correctness
- [ ] No regressions in existing test suite
- [ ] Code is well-documented for non-obvious operations
</success_criteria>

<notes>
Some operations may not benefit from unsafe variants:
- INVALID (0xFE) - always fails
- Opcodes that don't exist in current hardfork
- Operations with complex state interactions
These can fallback to safe implementations.
</notes>