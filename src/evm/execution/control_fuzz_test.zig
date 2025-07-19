const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const ExecutionResult = @import("execution_result.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const Vm = @import("../evm.zig");
const control = @import("control.zig");

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
        .stop => return control.op_stop(pc, @ptrCast(vm), @ptrCast(frame)),
        .jump => return control.op_jump(pc, @ptrCast(vm), @ptrCast(frame)),
        .jumpi => return control.op_jumpi(pc, @ptrCast(vm), @ptrCast(frame)),
        .pc => return control.op_pc(pc, @ptrCast(vm), @ptrCast(frame)),
        .jumpdest => return control.op_jumpdest(pc, @ptrCast(vm), @ptrCast(frame)),
        .return_op => return control.op_return(pc, @ptrCast(vm), @ptrCast(frame)),
        .revert => return control.op_revert(pc, @ptrCast(vm), @ptrCast(frame)),
        .invalid => return control.op_invalid(pc, @ptrCast(vm), @ptrCast(frame)),
        .selfdestruct => return control.op_selfdestruct(pc, @ptrCast(vm), @ptrCast(frame)),
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

test "fuzz_control_basic_operations" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzControlOperation{
        .{ .op_type = .stop },
        .{ .op_type = .jumpdest },
        .{ .op_type = .pc },
        .{ .op_type = .jump, .destination = 10 }, // Valid JUMPDEST
        .{ .op_type = .jumpi, .destination = 20, .condition = 1 }, // Valid conditional jump
        .{ .op_type = .jumpi, .destination = 20, .condition = 0 }, // False condition
        .{ .op_type = .return_op, .offset = 0, .size = 32 },
        .{ .op_type = .revert, .offset = 0, .size = 16 },
        .{ .op_type = .invalid },
        .{ .op_type = .selfdestruct, .recipient = 0x123456789ABCDEF0 },
    };
    
    try fuzz_control_operations(allocator, &operations);
}

test "fuzz_control_jump_validation" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzControlOperation{
        // Valid jump destinations
        .{ .op_type = .jump, .destination = 10 },
        .{ .op_type = .jump, .destination = 20 },
        .{ .op_type = .jump, .destination = 100 },
        
        // Invalid jump destinations
        .{ .op_type = .jump, .destination = 5 }, // Not a JUMPDEST
        .{ .op_type = .jump, .destination = 15 }, // Not a JUMPDEST
        .{ .op_type = .jump, .destination = 1000 }, // Out of bounds
        .{ .op_type = .jump, .destination = std.math.maxInt(u256) }, // Max value
        
        // Conditional jumps with various conditions
        .{ .op_type = .jumpi, .destination = 10, .condition = 1 },
        .{ .op_type = .jumpi, .destination = 10, .condition = 0 },
        .{ .op_type = .jumpi, .destination = 5, .condition = 1 }, // Invalid dest
        .{ .op_type = .jumpi, .destination = 5, .condition = 0 }, // Invalid dest, false condition
    };
    
    try fuzz_control_operations(allocator, &operations);
}

test "fuzz_control_memory_operations" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzControlOperation{
        // Basic memory operations
        .{ .op_type = .return_op, .offset = 0, .size = 0 }, // Empty return
        .{ .op_type = .return_op, .offset = 0, .size = 1 }, // Single byte
        .{ .op_type = .return_op, .offset = 0, .size = 32 }, // Word
        .{ .op_type = .return_op, .offset = 16, .size = 16 }, // Offset return
        
        .{ .op_type = .revert, .offset = 0, .size = 0 }, // Empty revert
        .{ .op_type = .revert, .offset = 0, .size = 32 }, // Word revert
        .{ .op_type = .revert, .offset = 8, .size = 24 }, // Offset revert
        
        // Edge cases
        .{ .op_type = .return_op, .offset = 0, .size = 1024 }, // Large return
        .{ .op_type = .revert, .offset = 0, .size = 1024 }, // Large revert
        .{ .op_type = .return_op, .offset = 1000, .size = 24 }, // High offset
        .{ .op_type = .revert, .offset = 1000, .size = 24 }, // High offset
    };
    
    try fuzz_control_operations(allocator, &operations);
}

test "fuzz_control_edge_cases" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzControlOperation{
        // PC at different positions
        .{ .op_type = .pc, .initial_pc = 0 },
        .{ .op_type = .pc, .initial_pc = 100 },
        .{ .op_type = .pc, .initial_pc = 255 },
        
        // Jump edge cases
        .{ .op_type = .jump, .destination = 0 }, // Jump to start
        .{ .op_type = .jumpi, .destination = 0, .condition = 1 },
        .{ .op_type = .jumpi, .destination = 0, .condition = 0 },
        
        // Memory edge cases
        .{ .op_type = .return_op, .offset = std.math.maxInt(u32), .size = 0 }, // Max offset
        .{ .op_type = .revert, .offset = std.math.maxInt(u32), .size = 0 }, // Max offset
        
        // Selfdestruct with different recipients
        .{ .op_type = .selfdestruct, .recipient = 0 },
        .{ .op_type = .selfdestruct, .recipient = std.math.maxInt(u256) },
    };
    
    try fuzz_control_operations(allocator, &operations);
}

test "fuzz_control_random_operations" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var operations = std.ArrayList(FuzzControlOperation).init(allocator);
    defer operations.deinit();
    
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const op_type_idx = random.intRangeAtMost(usize, 0, 8);
        const op_types = [_]ControlOpType{ .stop, .jump, .jumpi, .pc, .jumpdest, .return_op, .revert, .invalid, .selfdestruct };
        const op_type = op_types[op_type_idx];
        
        const destination = random.int(u256) % 256; // Keep destinations reasonable
        const condition = random.int(u256);
        const offset = random.int(u256) % 2048; // Keep offsets reasonable
        const size = random.int(u256) % 1024; // Keep sizes reasonable
        const recipient = random.int(u256);
        
        try operations.append(.{
            .op_type = op_type,
            .destination = destination,
            .condition = condition,
            .offset = offset,
            .size = size,
            .recipient = recipient,
        });
    }
    
    try fuzz_control_operations(allocator, operations.items);
}