const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");

pub fn op_pop(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    _ = try frame.stack.pop();

    return Operation.ExecutionResult{};
}

pub fn op_push0(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    try frame.stack.append(0);

    return Operation.ExecutionResult{};
}

// Optimized PUSH1 implementation with direct byte access
pub fn op_push1(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = interpreter;
    
    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    
    if (frame.stack.size >= Stack.CAPACITY) {
        @branchHint(.cold);
        unreachable;
    }
    
    const code = frame.contract.code;
    const value: u256 = if (pc + 1 < code.len) code[pc + 1] else 0;
    
    frame.stack.append_unsafe(value);
    
    return Operation.ExecutionResult{ .bytes_consumed = 2 };
}

// Optimized PUSH2-PUSH8 implementations using u64 arithmetic
pub fn make_push_small(comptime n: u8) fn (usize, *Operation.Interpreter, *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    return struct {
        pub fn push(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
            _ = interpreter;
            
            const frame = @as(*Frame, @ptrCast(@alignCast(state)));
            
            if (frame.stack.size >= Stack.CAPACITY) {
                @branchHint(.cold);
                unreachable;
            }
            
            var value: u64 = 0;
            const code = frame.contract.code;
            
            for (0..n) |i| {
                if (pc + 1 + i < code.len) {
                    @branchHint(.likely);
                    value = (value << 8) | code[pc + 1 + i];
                } else {
                    value = value << 8;
                }
            }
            
            frame.stack.append_unsafe(@as(u256, value));
            
            return Operation.ExecutionResult{ .bytes_consumed = 1 + n };
        }
    }.push;
}

// Generate push operations for PUSH1 through PUSH32
pub fn make_push(comptime n: u8) fn (usize, *Operation.Interpreter, *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    return struct {
        pub fn push(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
            _ = interpreter;

            const frame = @as(*Frame, @ptrCast(@alignCast(state)));

            var value: u256 = 0;
            const code = frame.contract.code;

            var i: isize = -@as(isize, @intCast(n));
            while (i < 0) : (i += 1) {
                const idx = @as(usize, @intCast(i + @as(isize, @intCast(n))));
                if (pc + 1 + idx < code.len) {
                    @branchHint(.likely);
                    value = (value << 8) | code[pc + 1 + idx];
                } else {
                    value = value << 8;
                }
            }

            frame.stack.append_unsafe(value);

            // PUSH operations consume 1 + n bytes
            // (1 for the opcode itself, n for the immediate data)
            return Operation.ExecutionResult{ .bytes_consumed = 1 + n };
        }
    }.push;
}

// Runtime dispatch version for PUSH operations (used in ReleaseSmall mode)
pub fn push_n(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const opcode = frame.contract.code[pc];
    const n = opcode - 0x5f; // PUSH1 is 0x60, so n = opcode - 0x5f

    var value: u256 = 0;
    const code = frame.contract.code;

    var i: isize = -@as(isize, @intCast(n));
    while (i < 0) : (i += 1) {
        const idx = @as(usize, @intCast(i + @as(isize, @intCast(n))));
        if (pc + 1 + idx < code.len) {
            @branchHint(.likely);
            value = (value << 8) | code[pc + 1 + idx];
        } else {
            value = value << 8;
        }
    }

    frame.stack.append_unsafe(value);

    return Operation.ExecutionResult{ .bytes_consumed = 1 + n };
}

// PUSH operations are now generated directly in jump_table.zig using make_push()

// Generate dup operations
pub fn make_dup(comptime n: u8) fn (usize, *Operation.Interpreter, *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    return struct {
        pub fn dup(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
            _ = pc;
            _ = interpreter;

            const frame = @as(*Frame, @ptrCast(@alignCast(state)));

            frame.stack.dup_unsafe(n);

            return Operation.ExecutionResult{};
        }
    }.dup;
}

// Runtime dispatch version for DUP operations (used in ReleaseSmall mode)
pub fn dup_n(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const opcode = frame.contract.code[pc];
    const n = opcode - 0x7f; // DUP1 is 0x80, so n = opcode - 0x7f

    frame.stack.dup_unsafe(@intCast(n));

    return Operation.ExecutionResult{};
}

// DUP operations are now generated directly in jump_table.zig using make_dup()

// Generate swap operations
pub fn make_swap(comptime n: u8) fn (usize, *Operation.Interpreter, *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    return struct {
        pub fn swap(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
            _ = pc;
            _ = interpreter;

            const frame = @as(*Frame, @ptrCast(@alignCast(state)));

            frame.stack.swap_unsafe(n);

            return Operation.ExecutionResult{};
        }
    }.swap;
}

// Runtime dispatch version for SWAP operations (used in ReleaseSmall mode)
pub fn swap_n(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));
    const opcode = frame.contract.code[pc];
    const n = opcode - 0x8f; // SWAP1 is 0x90, so n = opcode - 0x8f

    frame.stack.swap_unsafe(@intCast(n));

    return Operation.ExecutionResult{};
}

// SWAP operations are now generated directly in jump_table.zig using make_swap()

test "optimized PUSH1 handles value correctly" {
    const allocator = std.testing.allocator;
    const Vm = @import("../evm.zig");
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    const primitives = @import("primitives");
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Test with PUSH1 0xFF
    const code = [_]u8{ 0x60, 0xFF };
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    
    const result = try op_push1(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(@as(usize, 2), result.bytes_consumed);
    
    const value = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFF), value);
}

test "optimized PUSH1 handles bytecode boundary" {
    const allocator = std.testing.allocator;
    const Vm = @import("../evm.zig");
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    const primitives = @import("primitives");
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Test with PUSH1 at end of bytecode (no value byte)
    const code = [_]u8{0x60};
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    
    const result = try op_push1(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(@as(usize, 2), result.bytes_consumed);
    
    const value = try frame.stack.pop();
    try std.testing.expectEqual(@as(u256, 0), value);
}

test "optimized PUSH2-PUSH8 handle values correctly" {
    const allocator = std.testing.allocator;
    const Vm = @import("../evm.zig");
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    const primitives = @import("primitives");
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Test PUSH2 with 0x1234
    const code2 = [_]u8{ 0x61, 0x12, 0x34 };
    var contract2 = try Contract.init(allocator, &code2, .{ .address = primitives.Address.ZERO });
    defer contract2.deinit(allocator, null);
    
    var frame2 = try Frame.init(allocator, &vm, 1000000, contract2, primitives.Address.ZERO, &.{});
    defer frame2.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr2: *Operation.State = @ptrCast(&frame2);
    
    const push2_fn = make_push_small(2);
    const result2 = try push2_fn(0, interpreter_ptr, state_ptr2);
    try std.testing.expectEqual(@as(usize, 3), result2.bytes_consumed);
    
    const value2 = try frame2.stack.pop();
    try std.testing.expectEqual(@as(u256, 0x1234), value2);
    
    // Test PUSH8 with max u64 value
    const code8 = [_]u8{ 0x67, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF };
    var contract8 = try Contract.init(allocator, &code8, .{ .address = primitives.Address.ZERO });
    defer contract8.deinit(allocator, null);
    
    var frame8 = try Frame.init(allocator, &vm, 1000000, contract8, primitives.Address.ZERO, &.{});
    defer frame8.deinit();
    
    const state_ptr8: *Operation.State = @ptrCast(&frame8);
    
    const push8_fn = make_push_small(8);
    const result8 = try push8_fn(0, interpreter_ptr, state_ptr8);
    try std.testing.expectEqual(@as(usize, 9), result8.bytes_consumed);
    
    const value8 = try frame8.stack.pop();
    try std.testing.expectEqual(@as(u256, 0xFFFFFFFFFFFFFFFF), value8);
}

test "optimized PUSH handles partial bytecode correctly" {
    const allocator = std.testing.allocator;
    const Vm = @import("../evm.zig");
    const MemoryDatabase = @import("../state/memory_database.zig");
    const Contract = @import("../frame/contract.zig");
    const primitives = @import("primitives");
    
    var memory_db = MemoryDatabase.init(allocator);
    defer memory_db.deinit();
    
    const db_interface = memory_db.toDatabaseInterface();
    var vm = try Vm.init(allocator, db_interface, null, null);
    defer vm.deinit();
    
    // Test PUSH4 with only 2 bytes available
    const code = [_]u8{ 0x63, 0x12, 0x34 };
    var contract = try Contract.init(allocator, &code, .{ .address = primitives.Address.ZERO });
    defer contract.deinit(allocator, null);
    
    var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
    defer frame.deinit();
    
    const interpreter_ptr: *Operation.Interpreter = @ptrCast(&vm);
    const state_ptr: *Operation.State = @ptrCast(&frame);
    
    const push4_fn = make_push_small(4);
    const result = try push4_fn(0, interpreter_ptr, state_ptr);
    try std.testing.expectEqual(@as(usize, 5), result.bytes_consumed);
    
    const value = try frame.stack.pop();
    // Should be 0x12340000 (padded with zeros)
    try std.testing.expectEqual(@as(u256, 0x12340000), value);
}
