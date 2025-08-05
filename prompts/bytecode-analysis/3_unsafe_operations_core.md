# Task 3: Create Core Unsafe Operations

<context>
You are creating "unsafe" variants of operations that skip gas and stack validation, relying on block-level validation instead. This is a critical performance optimization.

<prerequisites>
- Task 1 & 2 completed: Block analysis infrastructure exists
- Understanding that block validation guarantees safety within the block
- Familiarity with Guillotine's operation structure
</prerequisites>

<safety_guarantee>
Block validation ensures:
- Sufficient gas for all operations in the block
- Stack has required items for all operations
- Stack won't overflow during block execution
Therefore, operations can skip individual checks.

EVMOne insights:
- Unsafe operations are ~2x faster due to no bounds checking
- Critical to have debug assertions in debug builds
- Memory operations still need expansion checks (can fail)
- JUMP/JUMPI still validate destinations (security critical)
</safety_guarantee>
</context>

<task>
<objective>
Create unsafe variants for core arithmetic and stack operations to validate the approach before converting all operations.
</objective>

<operations_to_convert>
Priority operations that execute frequently:
1. ADD, SUB, MUL, DIV (arithmetic)
2. PUSH1-PUSH8 (constants) 
3. POP, DUP1-DUP4, SWAP1-SWAP4 (stack manipulation)
4. MLOAD, MSTORE (memory)
</operations_to_convert>

<implementation_strategy>
<approach>
1. Create new operation_unsafe.zig module
2. Define operation signature for unsafe variants
3. Implement unsafe versions that use stack.pop_unsafe() etc.
4. Create operation table entries for unsafe variants
</approach>

<module_structure>
Create `src/evm/execution/operation_unsafe.zig`:
```zig
//! Unsafe operation variants for block-based execution.
//! These operations skip individual gas and stack checks,
//! relying on block-level validation for safety.

const std = @import("std");
const Frame = @import("../frame/frame.zig");
const Operation = @import("../opcodes/operation.zig");
const ExecutionResult = Operation.ExecutionResult;
const Interpreter = Operation.Interpreter;
const State = Operation.State;

/// Execute operation without gas/stack validation.
/// Block validation guarantees safety.
pub const UnsafeOperation = fn(pc: usize, interpreter: Interpreter, state: State) anyerror!ExecutionResult;

// Debug build safety checks
const builtin = @import("builtin");
const debug_checks = builtin.mode == .Debug;

fn assertStackHas(frame: *Frame, n: usize) void {
    if (debug_checks) {
        std.debug.assert(frame.stack.size >= n);
    }
}

fn assertStackSpace(frame: *Frame, n: usize) void {
    if (debug_checks) {
        std.debug.assert(frame.stack.size + n <= 1024);
    }
}
```
</module_structure>

<arithmetic_operations>
```zig
// Arithmetic operations
pub fn add_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    
    // Debug assertion for safety
    assertStackHas(frame, 2);
    
    // No validation - block guarantees 2 items exist
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.pop_unsafe();
    
    // Debug assertion for space
    assertStackSpace(frame, 1);
    
    // No overflow check - block guarantees space
    frame.stack.append_unsafe(a +% b);
    
    return ExecutionResult{ .pc_offset = 1 };
}

pub fn sub_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 2);
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.pop_unsafe();
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(a -% b);
    return ExecutionResult{ .pc_offset = 1 };
}

pub fn mul_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 2);
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.pop_unsafe();
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(a *% b);
    return ExecutionResult{ .pc_offset = 1 };
}

pub fn div_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 2);
    const b = frame.stack.pop_unsafe();
    const a = frame.stack.pop_unsafe();
    // EVM division by zero returns 0, not error
    const result = if (b == 0) 0 else @divFloor(a, b);
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(result);
    return ExecutionResult{ .pc_offset = 1 };
}
```
</arithmetic_operations>

<stack_operations>
```zig
// Stack operations
pub fn pop_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 1);
    _ = frame.stack.pop_unsafe();
    return ExecutionResult{ .pc_offset = 1 };
}

pub fn push1_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackSpace(frame, 1);
    // Debug: ensure push data exists
    std.debug.assert(pc + 1 < frame.contract.code.len);
    const value = frame.contract.code[pc + 1];
    frame.stack.append_unsafe(value);
    return ExecutionResult{ .pc_offset = 2 };
}

// Generic push for PUSH2-PUSH8
pub fn make_push_small_unsafe(comptime n: u8) UnsafeOperation {
    return struct {
        fn push_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
            const frame: *Frame = @ptrCast(@alignCast(state));
            
            var value: u64 = 0;
            const code = frame.contract.code;
            
            // Debug: ensure push data exists
            std.debug.assert(pc + n < code.len);
            
            // Build value from bytes (big-endian)
            comptime var i: usize = 0;
            inline while (i < n) : (i += 1) {
                value = (value << 8) | code[pc + 1 + i];
            }
            
            assertStackSpace(frame, 1);
            
            frame.stack.append_unsafe(value);
            return ExecutionResult{ .pc_offset = n + 1 };
        }
    }.push_unsafe;
}

// DUP operations
pub fn make_dup_unsafe(comptime n: u8) UnsafeOperation {
    return struct {
        fn dup_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
            const frame: *Frame = @ptrCast(@alignCast(state));
            assertStackHas(frame, n);
            assertStackSpace(frame, 1);
            const value = frame.stack.items[frame.stack.size - n];
            frame.stack.append_unsafe(value);
            return ExecutionResult{ .pc_offset = 1 };
        }
    }.dup_unsafe;
}

// SWAP operations  
pub fn make_swap_unsafe(comptime n: u8) UnsafeOperation {
    return struct {
        fn swap_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
            const frame: *Frame = @ptrCast(@alignCast(state));
            assertStackHas(frame, n + 1);
            const stack_top = frame.stack.size - 1;
            const swap_idx = stack_top - n;
            
            const tmp = frame.stack.items[stack_top];
            frame.stack.items[stack_top] = frame.stack.items[swap_idx];
            frame.stack.items[swap_idx] = tmp;
            
            return ExecutionResult{ .pc_offset = 1 };
        }
    }.swap_unsafe;
}
```
</stack_operations>

<memory_operations>
```zig
// Memory operations (still need memory expansion check)
pub fn mload_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 1);
    const offset = frame.stack.pop_unsafe();
    
    // Memory expansion still needed (can fail)
    // This is a key difference from pure unsafe ops
    const value = try frame.memory.load(offset);
    assertStackSpace(frame, 1);
    frame.stack.append_unsafe(value);
    
    return ExecutionResult{ .pc_offset = 1 };
}

pub fn mstore_unsafe(pc: usize, interpreter: Interpreter, state: State) !ExecutionResult {
    const frame: *Frame = @ptrCast(@alignCast(state));
    assertStackHas(frame, 2);
    const offset = frame.stack.pop_unsafe();
    const value = frame.stack.pop_unsafe();
    
    // Memory expansion still needed (can fail)
    // Memory best practice: check bounds before expansion
    try frame.memory.store(offset, value);
    
    return ExecutionResult{ .pc_offset = 1 };
}
```
</memory_operations>
</implementation_strategy>

<integration>
Create operation table entries in a new file `src/evm/jump_table/unsafe_operations.zig`:
```zig
const operation_unsafe = @import("../execution/operation_unsafe.zig");
const Operation = @import("../opcodes/operation.zig").Operation;

pub const UNSAFE_OPERATIONS = [256]*const Operation{
    // 0x01: ADD
    &Operation{
        .execute = operation_unsafe.add_unsafe,
        .constant_gas = 3,
        .min_stack = 2,
        .max_stack = 1,
    },
    // ... etc for each converted operation
};
```
</integration>

<testing>
Create tests in operation_unsafe.zig:
```zig
test "unsafe arithmetic operations" {
    const allocator = std.testing.allocator;
    var frame = try Frame.init(allocator, ...);
    defer frame.deinit();
    
    // Pre-populate stack (block validation would ensure this)
    try frame.stack.push(10);
    try frame.stack.push(5);
    
    // Test ADD
    _ = try add_unsafe(0, null, &frame);
    try std.testing.expectEqual(@as(u256, 15), frame.stack.pop());
}

test "unsafe operations assume valid state" {
    // This test documents that unsafe ops don't validate
    const allocator = std.testing.allocator;
    var frame = try Frame.init(allocator, ...);
    defer frame.deinit();
    
    // Empty stack - would normally error
    // But unsafe operations assume block validated
    // DO NOT call in production without block validation!
}
```
</testing>

<edge_cases>
1. Division by zero returns 0 (EVM behavior)
2. PUSH operations at end of code (handled by block analysis)
3. Memory operations can still fail (OOM)
4. Stack indices must be valid (debug assertions catch)
5. Operations after STOP/RETURN are unreachable
</edge_cases>

<benchmarking>
Add zbench benchmarks to measure speedup:
```zig
const zbench = @import("zbench");

fn benchmarkUnsafeVsSafe(b: *zbench.Benchmark) void {
    const allocator = std.testing.allocator;
    var frame = Frame.init(allocator, ...) catch unreachable;
    defer frame.deinit();
    
    // Pre-populate stack for testing
    for (0..100) |i| {
        frame.stack.push(@intCast(u256, i)) catch unreachable;
    }
    
    const iterations = b.iterations;
    
    // Benchmark safe operations
    const safe_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        // Safe ADD with checks
        if (frame.stack.size >= 2) {
            const b_val = frame.stack.pop() catch unreachable;
            const a_val = frame.stack.pop() catch unreachable;
            frame.stack.push(a_val +% b_val) catch unreachable;
        }
    }
    const safe_time = std.time.nanoTimestamp() - safe_start;
    
    // Benchmark unsafe operations
    const unsafe_start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        // Unsafe ADD no checks
        const b_val = frame.stack.pop_unsafe();
        const a_val = frame.stack.pop_unsafe();
        frame.stack.append_unsafe(a_val +% b_val);
    }
    const unsafe_time = std.time.nanoTimestamp() - unsafe_start;
    
    std.debug.print("Safe: {}ns, Unsafe: {}ns, Speedup: {d:.2}x\n", .{
        safe_time / iterations,
        unsafe_time / iterations,
        @intToFloat(f64, safe_time) / @intToFloat(f64, unsafe_time),
    });
}
```
</benchmarking>

<memory_best_practices>
1. **No allocations**: Unsafe ops should never allocate memory
2. **Stack bounds**: Use debug assertions to catch errors early
3. **Code bounds**: Verify PUSH data exists in debug builds
4. **Memory ops**: Still need proper error handling for expansion
5. **Cache friendly**: Keep operations small and inline-able
</memory_best_practices>
</task>

<success_criteria>
- [ ] operation_unsafe.zig module created with core operations
- [ ] Unsafe operations use pop_unsafe/append_unsafe methods
- [ ] No gas consumption in unsafe operations
- [ ] No stack validation in unsafe operations  
- [ ] Debug assertions added for safety in debug builds
- [ ] Tests demonstrate operations work correctly
- [ ] Tests document unsafe assumptions
- [ ] Benchmarks show ~2x speedup
</success_criteria>

<next_steps>
After validating this approach works:
1. Task 4 will modify interpreter to use block validation
2. Task 5 will convert remaining operations to unsafe variants
</next_steps>