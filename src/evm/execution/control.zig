const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const Log = @import("../log.zig");
const ExecutionError = @import("execution_error.zig");
const ExecutionResult = @import("execution_result.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const GasConstants = @import("primitives").GasConstants;
const AccessList = @import("../access_list/access_list.zig").AccessList;
const primitives = @import("primitives");
const from_u256 = primitives.Address.from_u256;

pub fn op_stop(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!ExecutionResult {
    _ = pc;
    _ = interpreter;
    _ = state;

    return ExecutionError.Error.STOP;
}

pub fn op_jump(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size >= 1);

    // Use unsafe pop since bounds checking is done by jump_table
    const dest = frame.stack.pop_unsafe();

    // Check if destination is a valid JUMPDEST (pass u256 directly)
    if (!frame.contract.valid_jumpdest(frame.allocator, dest)) {
        @branchHint(.unlikely);
        return ExecutionError.Error.InvalidJump;
    }

    // The destination must be within the bounds of the code
    std.debug.assert(dest <= std.math.maxInt(usize));

    frame.pc = @as(usize, @intCast(dest));

    return ExecutionResult{};
}

pub fn op_jumpi(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!ExecutionResult {
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size >= 2);

    // Use batch pop for performance - pop 2 values at once
    // Stack order (top to bottom): [destination, condition]
    const values = frame.stack.pop2_unsafe();
    const destination = values.b; // Top
    const condition = values.a; // Second from top

    Log.debug("JUMPI: condition={}, destination={}, current_pc={}", .{ condition, destination, pc });

    if (condition != 0) {
        Log.debug("JUMPI: condition is non-zero, checking jump destination", .{});

        // Check if destination is a valid JUMPDEST (pass u256 directly)
        if (!frame.contract.valid_jumpdest(frame.allocator, destination)) {
            @branchHint(.unlikely);
            Log.debug("JUMPI: Invalid jump destination {}", .{destination});
            return ExecutionError.Error.InvalidJump;
        }
        const new_pc = @as(usize, @intCast(destination));
        Log.debug("JUMPI: Setting frame.pc from {} to {}", .{ frame.pc, new_pc });
        frame.pc = new_pc;
    } else {
        Log.debug("JUMPI: condition is zero, not jumping", .{});
    }

    return ExecutionResult{};
}

pub fn op_pc(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!ExecutionResult {
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size < Stack.CAPACITY);

    // Use unsafe push since bounds checking is done by jump_table
    frame.stack.append_unsafe(@as(u256, @intCast(pc)));

    return ExecutionResult{};
}

pub fn op_jumpdest(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!ExecutionResult {
    _ = pc;
    _ = interpreter;
    _ = state;

    // No-op, just marks valid jump destination
    return ExecutionResult{};
}

pub fn op_return(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size >= 2);

    // Use batch pop for performance - pop 2 values at once
    // Stack order (top to bottom): [offset, size] with offset on top
    const values = frame.stack.pop2_unsafe();
    const offset = values.b; // Top
    const size = values.a; // Second from top

    Log.debug("RETURN opcode: offset={}, size={}", .{ offset, size });

    if (size == 0) {
        @branchHint(.unlikely);
        frame.output = &[_]u8{};
    } else {
        if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
            @branchHint(.unlikely);
            return ExecutionError.Error.OutOfOffset;
        }

        const offset_usize = @as(usize, @intCast(offset));
        const size_usize = @as(usize, @intCast(size));

        // Calculate memory expansion gas cost
        const end = offset_usize + size_usize;
        if (end > offset_usize) { // Check for overflow
            const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(end)));
            try frame.consume_gas(memory_gas);

            _ = try frame.memory.ensure_context_capacity(end);
        }

        // Get data from memory
        const data = try frame.memory.get_slice(offset_usize, size_usize);

        Log.debug("RETURN reading {} bytes from memory[{}..{}]", .{ size_usize, offset_usize, offset_usize + size_usize });
        if (size_usize <= 32) {
            Log.debug("RETURN data: {x}", .{std.fmt.fmtSliceHexLower(data)});
        } else {
            Log.debug("RETURN data (first 32 bytes): {x}", .{std.fmt.fmtSliceHexLower(data[0..32])});
        }

        // Note: The memory gas cost already protects against excessive memory use.
        // Set the output data that will be returned to the caller
        frame.output = data;

        Log.debug("RETURN data set to frame.output, size: {}", .{data.len});
    }

    Log.debug("RETURN opcode complete, about to return STOP error", .{});
    return ExecutionError.Error.STOP; // RETURN ends execution normally
}

pub fn op_revert(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = state;

    std.debug.assert(frame.stack.size >= 2);

    // Use batch pop for performance - pop 2 values at once
    // Stack order (top to bottom): [offset, size] with offset on top
    const values = frame.stack.pop2_unsafe();
    const offset = values.b; // Top
    const size = values.a; // Second from top

    if (size == 0) {
        @branchHint(.unlikely);
        frame.output = &[_]u8{};
    } else {
        if (offset > std.math.maxInt(usize) or size > std.math.maxInt(usize)) {
            @branchHint(.unlikely);
            return ExecutionError.Error.OutOfOffset;
        }

        const offset_usize = @as(usize, @intCast(offset));
        const size_usize = @as(usize, @intCast(size));

        // Calculate memory expansion gas cost
        const end = offset_usize + size_usize;
        if (end > offset_usize) { // Check for overflow
            const memory_gas = frame.memory.get_expansion_cost(@as(u64, @intCast(end)));
            try frame.consume_gas(memory_gas);

            _ = try frame.memory.ensure_context_capacity(end);
        }

        // Get data from memory
        const data = try frame.memory.get_slice(offset_usize, size_usize);

        // Note: The memory gas cost already protects against excessive memory use.
        // Set the output data that will be returned to the caller
        frame.output = data;
    }

    return ExecutionError.Error.REVERT;
}

pub fn op_invalid(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = state;

    // Debug: op_invalid entered
    // INVALID opcode consumes all remaining gas
    frame.gas_remaining = 0;
    // Debug: op_invalid returning InvalidOpcode

    return ExecutionError.Error.InvalidOpcode;
}

pub fn op_selfdestruct(pc: usize, interpreter: Operation.Interpreter, state: Operation.State) ExecutionError.Error!ExecutionResult {
    _ = pc;

    const frame = state;
    const vm = interpreter;

    // Check if we're in a static call
    if (frame.is_static) {
        @branchHint(.unlikely);
        return ExecutionError.Error.WriteProtection;
    }

    std.debug.assert(frame.stack.size >= 1);

    // Use unsafe pop since bounds checking is done by jump_table
    const recipient_u256 = frame.stack.pop_unsafe();
    const recipient = from_u256(recipient_u256);

    // EIP-2929: Check if recipient address is cold and consume appropriate gas
    // Note: Jump table already consumes base SELFDESTRUCT gas cost
    const access_cost = vm.access_list.access_address(recipient) catch |err| switch (err) {
        error.OutOfMemory => return ExecutionError.Error.OutOfGas,
    };
    const is_cold = access_cost == AccessList.COLD_ACCOUNT_ACCESS_COST;
    if (is_cold) {
        @branchHint(.likely);
        // Cold address access costs more (2600 gas)
        try frame.consume_gas(GasConstants.ColdAccountAccessCost);
    }

    // Mark contract for destruction at end of transaction
    vm.state.mark_for_destruction(frame.contract.address, recipient) catch |err| switch (err) {
        error.OutOfMemory => return ExecutionError.Error.OutOfGas,
    };

    // Halt execution
    return ExecutionError.Error.STOP;
}

// Fuzz testing functions for control flow operations
pub fn fuzz_control_operations(allocator: std.mem.Allocator, operations: []const FuzzControlOperation) !void {
    for (operations) |op| {
        // Create clean VM and frame for each test
        var memory = try @import("../memory/memory.zig").init_default(allocator);
        defer memory.deinit();

        var db = @import("../state/memory_database.zig").init(allocator);
        defer db.deinit();

        var vm = try Vm.init(allocator, db.to_database_interface(), null, null);
        defer vm.deinit();

        // Create bytecode with JUMPDEST at positions we want to jump to
        var code = std.ArrayList(u8).init(allocator);
        defer code.deinit();

        // Add some NOPs and JUMPDESTs for testing
        var i: usize = 0;
        while (i < 256) : (i += 1) {
            if (i == 10 or i == 20 or i == 100) {
                try code.append(0x5B); // JUMPDEST
            } else {
                try code.append(0x00); // STOP
            }
        }

        var contract = try @import("../frame/contract.zig").init(allocator, code.items, .{});
        defer contract.deinit(allocator, null);

        var frame = try Frame.init(allocator, &vm, 1000000, contract, @import("../../Address.zig").ZERO, &.{});
        defer frame.deinit();

        // Set initial PC if needed
        if (op.initial_pc) |pc| {
            frame.pc = pc;
        }

        // Setup stack with test values
        switch (op.op_type) {
            .stop, .jumpdest, .invalid => {
                // No stack setup needed
            },
            .jump => {
                try frame.stack.append(op.destination);
            },
            .jumpi => {
                try frame.stack.append(op.condition);
                try frame.stack.append(op.destination);
            },
            .pc => {
                // No stack setup needed
            },
            .return_op, .revert => {
                try frame.stack.append(op.size);
                try frame.stack.append(op.offset);
            },
            .selfdestruct => {
                try frame.stack.append(op.recipient);
            },
        }

        // Pre-fill memory for return/revert tests
        if (op.op_type == .return_op or op.op_type == .revert) {
            // Ensure memory has some data
            const memory_size = 1024;
            _ = try frame.memory.ensure_context_capacity(memory_size);

            // Write some test data to memory
            var test_data: [32]u8 = undefined;
            std.mem.writeInt(u256, &test_data, 0x123456789ABCDEF0, .big);
            try frame.memory.set_slice(0, &test_data);
        }

        // Execute the operation
        const result = execute_control_operation(op.op_type, frame.pc, &vm, &frame);

        // Verify the result makes sense
        try validate_control_result(&frame, op, result);
    }
}

const FuzzControlOperation = struct {
    op_type: ControlOpType,
    destination: u256 = 0,
    condition: u256 = 0,
    offset: u256 = 0,
    size: u256 = 0,
    recipient: u256 = 0,
    initial_pc: ?usize = null,
};

const ControlOpType = enum {
    stop,
    jump,
    jumpi,
    pc,
    jumpdest,
    return_op,
    revert,
    invalid,
    selfdestruct,
};

fn execute_control_operation(op_type: ControlOpType, pc: usize, vm: *Vm, frame: *Frame) ExecutionError.Error!ExecutionResult {
    switch (op_type) {
        .stop => return op_stop(pc, @ptrCast(vm), @ptrCast(frame)),
        .jump => return op_jump(pc, @ptrCast(vm), @ptrCast(frame)),
        .jumpi => return op_jumpi(pc, @ptrCast(vm), @ptrCast(frame)),
        .pc => return op_pc(pc, @ptrCast(vm), @ptrCast(frame)),
        .jumpdest => return op_jumpdest(pc, @ptrCast(vm), @ptrCast(frame)),
        .return_op => return op_return(pc, @ptrCast(vm), @ptrCast(frame)),
        .revert => return op_revert(pc, @ptrCast(vm), @ptrCast(frame)),
        .invalid => return op_invalid(pc, @ptrCast(vm), @ptrCast(frame)),
        .selfdestruct => return op_selfdestruct(pc, @ptrCast(vm), @ptrCast(frame)),
    }
}

fn validate_control_result(frame: *const Frame, op: FuzzControlOperation, result: ExecutionError.Error!ExecutionResult) !void {
    const testing = std.testing;

    switch (op.op_type) {
        .stop => {
            // STOP should always return STOP error
            try testing.expectError(ExecutionError.Error.STOP, result);
        },
        .jump => {
            if (op.destination == 10 or op.destination == 20 or op.destination == 100) {
                // Valid jump destinations should succeed and set PC
                _ = try result; // Should not error
                try testing.expectEqual(@as(usize, @intCast(op.destination)), frame.pc);
            } else {
                // Invalid jump destinations should return InvalidJump error
                try testing.expectError(ExecutionError.Error.InvalidJump, result);
            }
        },
        .jumpi => {
            if (op.condition == 0) {
                // Conditional jump with false condition should not jump
                _ = try result; // Should not error
                // PC should not change (we don't track original PC here)
            } else {
                // Conditional jump with true condition
                if (op.destination == 10 or op.destination == 20 or op.destination == 100) {
                    _ = try result; // Should not error
                    try testing.expectEqual(@as(usize, @intCast(op.destination)), frame.pc);
                } else {
                    try testing.expectError(ExecutionError.Error.InvalidJump, result);
                }
            }
        },
        .pc => {
            // PC should succeed and push current PC to stack
            _ = try result; // Should not error
            try testing.expectEqual(@as(usize, 1), frame.stack.size);
            // Stack should contain the PC value
            try testing.expect(frame.stack.data[0] >= 0);
        },
        .jumpdest => {
            // JUMPDEST should always succeed (no-op)
            _ = try result; // Should not error
        },
        .return_op => {
            // RETURN should always end with STOP
            try testing.expectError(ExecutionError.Error.STOP, result);
            // Frame should have output set (even if empty)
            try testing.expect(frame.output != null);
        },
        .revert => {
            // REVERT should always end with REVERT error
            try testing.expectError(ExecutionError.Error.REVERT, result);
            // Frame should have output set (even if empty)
            try testing.expect(frame.output != null);
        },
        .invalid => {
            // INVALID should always return InvalidOpcode error
            try testing.expectError(ExecutionError.Error.InvalidOpcode, result);
            // Should consume all gas
            try testing.expectEqual(@as(u64, 0), frame.gas_remaining);
        },
        .selfdestruct => {
            // SELFDESTRUCT should return STOP (ends execution)
            try testing.expectError(ExecutionError.Error.STOP, result);
        },
    }
}

// test "fuzz_control_basic_operations" {
//     const allocator = std.testing.allocator;
//
//     const operations = [_]FuzzControlOperation{
//         .{ .op_type = .stop },
//         .{ .op_type = .jumpdest },
//         .{ .op_type = .pc },
//         .{ .op_type = .jump, .destination = 10 }, // Valid JUMPDEST
//         .{ .op_type = .jumpi, .destination = 20, .condition = 1 }, // Valid conditional jump
//         .{ .op_type = .jumpi, .destination = 20, .condition = 0 }, // False condition
//         .{ .op_type = .return_op, .offset = 0, .size = 32 },
//         .{ .op_type = .revert, .offset = 0, .size = 16 },
//         .{ .op_type = .invalid },
//         .{ .op_type = .selfdestruct, .recipient = 0x123456789ABCDEF0 },
//     };
//
//     try fuzz_control_operations(allocator, &operations);
// }

// test "fuzz_control_jump_validation" {
//     const allocator = std.testing.allocator;
//
//     const operations = [_]FuzzControlOperation{
//         // Valid jump destinations
//         .{ .op_type = .jump, .destination = 10 },
//         .{ .op_type = .jump, .destination = 20 },
//         .{ .op_type = .jump, .destination = 100 },
//
//         // Invalid jump destinations
//         .{ .op_type = .jump, .destination = 5 }, // Not a JUMPDEST
//         .{ .op_type = .jump, .destination = 15 }, // Not a JUMPDEST
//         .{ .op_type = .jump, .destination = 1000 }, // Out of bounds
//         .{ .op_type = .jump, .destination = std.math.maxInt(u256) }, // Max value
//
//         // Conditional jumps with various conditions
//         .{ .op_type = .jumpi, .destination = 10, .condition = 1 },
//         .{ .op_type = .jumpi, .destination = 10, .condition = 0 },
//         .{ .op_type = .jumpi, .destination = 5, .condition = 1 }, // Invalid dest
//         .{ .op_type = .jumpi, .destination = 5, .condition = 0 }, // Invalid dest, false condition
//     };
//
//     try fuzz_control_operations(allocator, &operations);
// }

// test "fuzz_control_memory_operations" {
//     const allocator = std.testing.allocator;
//
//     const operations = [_]FuzzControlOperation{
//         // Basic memory operations
//         .{ .op_type = .return_op, .offset = 0, .size = 0 }, // Empty return
//         .{ .op_type = .return_op, .offset = 0, .size = 1 }, // Single byte
//         .{ .op_type = .return_op, .offset = 0, .size = 32 }, // Word
//         .{ .op_type = .return_op, .offset = 16, .size = 16 }, // Offset return
//
//         .{ .op_type = .revert, .offset = 0, .size = 0 }, // Empty revert
//         .{ .op_type = .revert, .offset = 0, .size = 32 }, // Word revert
//         .{ .op_type = .revert, .offset = 8, .size = 24 }, // Offset revert
//
//         // Edge cases
//         .{ .op_type = .return_op, .offset = 0, .size = 1024 }, // Large return
//         .{ .op_type = .revert, .offset = 0, .size = 1024 }, // Large revert
//         .{ .op_type = .return_op, .offset = 1000, .size = 24 }, // High offset
//         .{ .op_type = .revert, .offset = 1000, .size = 24 }, // High offset
//     };
//
//     try fuzz_control_operations(allocator, &operations);
// }

// test "fuzz_control_edge_cases" {
//     const allocator = std.testing.allocator;
//
//     const operations = [_]FuzzControlOperation{
//         // PC at different positions
//         .{ .op_type = .pc, .initial_pc = 0 },
//         .{ .op_type = .pc, .initial_pc = 100 },
//         .{ .op_type = .pc, .initial_pc = 255 },
//
//         // Jump edge cases
//         .{ .op_type = .jump, .destination = 0 }, // Jump to start
//         .{ .op_type = .jumpi, .destination = 0, .condition = 1 },
//         .{ .op_type = .jumpi, .destination = 0, .condition = 0 },
//
//         // Memory edge cases
//         .{ .op_type = .return_op, .offset = std.math.maxInt(u32), .size = 0 }, // Max offset
//         .{ .op_type = .revert, .offset = std.math.maxInt(u32), .size = 0 }, // Max offset
//
//         // Selfdestruct with different recipients
//         .{ .op_type = .selfdestruct, .recipient = 0 },
//         .{ .op_type = .selfdestruct, .recipient = std.math.maxInt(u256) },
//     };
//
//     try fuzz_control_operations(allocator, &operations);
// }

// test "fuzz_control_random_operations" {
//     const global = struct {
//         fn testControlRandomOperations(input: []const u8) anyerror!void {
//             if (input.len < 10) return;
//
//             const allocator = std.testing.allocator;
//             const op_types = [_]ControlOpType{ .stop, .jump, .jumpi, .pc, .jumpdest, .return_op, .revert, .invalid, .selfdestruct };
//
//             var operations = std.ArrayList(FuzzControlOperation).init(allocator);
//             defer operations.deinit();
//
//             // Generate multiple operations from fuzz input
//             const num_ops = @min((input.len / 10) + 1, 20); // 1-20 operations
//
//             for (0..num_ops) |i| {
//                 const base_idx = (i * 10) % input.len;
//                 if (base_idx + 9 >= input.len) break;
//
//                 const op_type_idx = input[base_idx] % op_types.len;
//                 const op_type = op_types[op_type_idx];
//
//                 const destination = std.mem.readInt(u16, input[base_idx+1..base_idx+3], .little); // Keep destinations reasonable
//                 const condition = std.mem.readInt(u64, input[base_idx+1..base_idx+9], .little);
//                 const offset = std.mem.readInt(u16, input[base_idx+3..base_idx+5], .little) % 2048; // Keep offsets reasonable
//                 const size = std.mem.readInt(u16, input[base_idx+5..base_idx+7], .little) % 1024; // Keep sizes reasonable
//                 const recipient = std.mem.readInt(u64, input[base_idx+1..base_idx+9], .little);
//
//                 try operations.append(.{
//                     .op_type = op_type,
//                     .destination = destination,
//                     .condition = condition,
//                     .offset = offset,
//                     .size = size,
//                     .recipient = recipient,
//                 });
//             }
//
//             try fuzz_control_operations(allocator, operations.items);
//         }
//     };
//     try std.testing.fuzz(global.testControlRandomOperations, .{});
// }
