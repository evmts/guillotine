const std = @import("std");
const Operation = @import("../opcodes/operation.zig");
const ExecutionError = @import("execution_error.zig");
const Stack = @import("../stack/stack.zig");
const Frame = @import("../frame/frame.zig");
const primitives = @import("primitives");

pub fn op_and(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    // Debug assertion: Jump table validation ensures we have >= 2 items
    std.debug.assert(frame.stack.size >= 2);

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    const result = a & b;

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_or(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    const result = a | b;

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_xor(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const b = frame.stack.pop_unsafe();
    const a = frame.stack.peek_unsafe().*;

    const result = a ^ b;

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_not(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    // Debug assertion: Jump table validation ensures we have >= 1 item
    std.debug.assert(frame.stack.size >= 1);

    const value = frame.stack.peek_unsafe().*;

    const result = ~value;

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_byte(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const i = frame.stack.pop_unsafe();
    const val = frame.stack.peek_unsafe().*;

    var result: u256 = undefined;

    if (i >= 32) {
        @branchHint(.unlikely);
        result = 0;
    } else {
        const i_usize = @as(usize, @intCast(i));
        // Byte 0 is MSB, byte 31 is LSB
        // To get byte i, we need to shift right by (31 - i) * 8 positions
        const shift_amount = (31 - i_usize) * 8;
        result = (val >> @intCast(shift_amount)) & 0xFF;
    }

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_shl(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const shift = frame.stack.pop_unsafe();
    const value = frame.stack.peek_unsafe().*;

    var result: u256 = undefined;

    if (shift >= 256) {
        @branchHint(.unlikely);
        result = 0;
    } else {
        result = value << @intCast(shift);
    }

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_shr(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const shift = frame.stack.pop_unsafe();
    const value = frame.stack.peek_unsafe().*;

    var result: u256 = undefined;

    if (shift >= 256) {
        @branchHint(.unlikely);
        result = 0;
    } else {
        result = value >> @intCast(shift);
    }

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

pub fn op_sar(pc: usize, interpreter: *Operation.Interpreter, state: *Operation.State) ExecutionError.Error!Operation.ExecutionResult {
    _ = pc;
    _ = interpreter;

    const frame = @as(*Frame, @ptrCast(@alignCast(state)));

    const shift = frame.stack.pop_unsafe();
    const value = frame.stack.peek_unsafe().*;

    var result: u256 = undefined;

    if (shift >= 256) {
        @branchHint(.unlikely);
        const sign_bit = value >> 255;
        if (sign_bit == 1) {
            result = std.math.maxInt(u256);
        } else {
            result = 0;
        }
    } else {
        // Arithmetic shift preserving sign
        const shift_amount = @as(u8, @intCast(shift));
        const value_i256 = @as(i256, @bitCast(value));
        const result_i256 = value_i256 >> shift_amount;
        result = @as(u256, @bitCast(result_i256));
    }

    frame.stack.set_top_unsafe(result);

    return Operation.ExecutionResult{};
}

// Fuzz testing functions for bitwise operations
pub fn fuzz_bitwise_operations(allocator: std.mem.Allocator, operations: []const FuzzBitwiseOperation) !void {
    const Vm = @import("evm").Evm;
    
    for (operations) |op| {
        var memory = try @import("evm").Memory.init_default(allocator);
        defer memory.deinit();
        
        var db = @import("evm").MemoryDatabase.init(allocator);
        defer db.deinit();
        
        var vm = try Vm.init(allocator, db.to_database_interface(), null, null);
        defer vm.deinit();
        
        var contract = try @import("evm").Contract.init(allocator, &[_]u8{0x01}, .{});
        defer contract.deinit(allocator, null);
        
        var frame = try Frame.init(allocator, &vm, 1000000, contract, primitives.Address.ZERO, &.{});
        defer frame.deinit();
        
        // Setup stack with test values based on operation type
        if (op.op_type == BitwiseOpType.not_op) {
            try frame.stack.append(op.a);
        } else {
            try frame.stack.append(op.a);
            try frame.stack.append(op.b);
        }
        
        // Execute the operation
        var result: Operation.ExecutionResult = undefined;
        if (op.op_type == BitwiseOpType.and_op) {
            result = try op_and(0, @ptrCast(&vm), @ptrCast(&frame));
        } else if (op.op_type == BitwiseOpType.or_op) {
            result = try op_or(0, @ptrCast(&vm), @ptrCast(&frame));
        } else if (op.op_type == BitwiseOpType.xor_op) {
            result = try op_xor(0, @ptrCast(&vm), @ptrCast(&frame));
        } else if (op.op_type == BitwiseOpType.not_op) {
            result = try op_not(0, @ptrCast(&vm), @ptrCast(&frame));
        } else if (op.op_type == BitwiseOpType.byte_op) {
            result = try op_byte(0, @ptrCast(&vm), @ptrCast(&frame));
        } else if (op.op_type == BitwiseOpType.shl_op) {
            result = try op_shl(0, @ptrCast(&vm), @ptrCast(&frame));
        } else if (op.op_type == BitwiseOpType.shr_op) {
            result = try op_shr(0, @ptrCast(&vm), @ptrCast(&frame));
        } else if (op.op_type == BitwiseOpType.sar_op) {
            result = try op_sar(0, @ptrCast(&vm), @ptrCast(&frame));
        }
        
        // Verify the result makes sense
        try validate_bitwise_result(&frame.stack, op);
    }
}

const FuzzBitwiseOperation = struct {
    op_type: BitwiseOpType,
    a: u256,
    b: u256 = 0,
};

const BitwiseOpType = enum {
    and_op,
    or_op,
    xor_op,
    not_op,
    byte_op,
    shl_op,
    shr_op,
    sar_op,
};

fn validate_bitwise_result(stack: *const Stack, op: FuzzBitwiseOperation) !void {
    const testing = std.testing;
    
    // Stack should have exactly one result
    try testing.expectEqual(@as(usize, 1), stack.size);
    
    const result = stack.data[0];
    
    // Verify specific bitwise properties
    switch (op.op_type) {
        .and_op => {
            const expected = op.a & op.b;
            try testing.expectEqual(expected, result);
            
            // AND properties
            try testing.expect(result <= op.a);
            try testing.expect(result <= op.b);
            if (op.a == 0 or op.b == 0) try testing.expectEqual(@as(u256, 0), result);
        },
        .or_op => {
            const expected = op.a | op.b;
            try testing.expectEqual(expected, result);
            
            // OR properties
            try testing.expect(result >= op.a);
            try testing.expect(result >= op.b);
            if (op.a == std.math.maxInt(u256) or op.b == std.math.maxInt(u256)) {
                try testing.expectEqual(std.math.maxInt(u256), result);
            }
        },
        .xor_op => {
            const expected = op.a ^ op.b;
            try testing.expectEqual(expected, result);
            
            // XOR properties
            if (op.a == op.b) try testing.expectEqual(@as(u256, 0), result);
            if (op.a == 0) try testing.expectEqual(op.b, result);
            if (op.b == 0) try testing.expectEqual(op.a, result);
        },
        .not_op => {
            const expected = ~op.a;
            try testing.expectEqual(expected, result);
            
            // NOT properties
            try testing.expectEqual(op.a, ~result);
        },
        .byte_op => {
            // Byte extraction
            if (op.b >= 32) {
                try testing.expectEqual(@as(u256, 0), result);
            } else {
                try testing.expect(result <= 0xFF);
                const byte_pos = @as(usize, @intCast(op.b));
                const shift_amount = (31 - byte_pos) * 8;
                const expected = (op.a >> @intCast(shift_amount)) & 0xFF;
                try testing.expectEqual(expected, result);
            }
        },
        .shl_op => {
            // Left shift
            if (op.b >= 256) {
                try testing.expectEqual(@as(u256, 0), result);
            } else {
                const expected = op.a << @intCast(op.b);
                try testing.expectEqual(expected, result);
            }
        },
        .shr_op => {
            // Right shift
            if (op.b >= 256) {
                try testing.expectEqual(@as(u256, 0), result);
            } else {
                const expected = op.a >> @intCast(op.b);
                try testing.expectEqual(expected, result);
                try testing.expect(result <= op.a);
            }
        },
        .sar_op => {
            // Arithmetic right shift
            if (op.b >= 256) {
                const sign_bit = op.a >> 255;
                if (sign_bit == 1) {
                    try testing.expectEqual(std.math.maxInt(u256), result);
                } else {
                    try testing.expectEqual(@as(u256, 0), result);
                }
            } else {
                const shift_amount = @as(u8, @intCast(op.b));
                const value_i256 = @as(i256, @bitCast(op.a));
                const expected_i256 = value_i256 >> shift_amount;
                const expected = @as(u256, @bitCast(expected_i256));
                try testing.expectEqual(expected, result);
            }
        },
    }
}

test "fuzz_bitwise_basic_operations" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzBitwiseOperation{
        .{ .op_type = .and_op, .a = 0xF0F0F0F0, .b = 0x0F0F0F0F },
        .{ .op_type = .or_op, .a = 0xF0F0F0F0, .b = 0x0F0F0F0F },
        .{ .op_type = .xor_op, .a = 0xF0F0F0F0, .b = 0x0F0F0F0F },
        .{ .op_type = .not_op, .a = 0xF0F0F0F0 },
        .{ .op_type = .byte_op, .a = 0x123456789ABCDEF0, .b = 0 },
        .{ .op_type = .shl_op, .a = 0x123456789ABCDEF0, .b = 4 },
        .{ .op_type = .shr_op, .a = 0x123456789ABCDEF0, .b = 4 },
        .{ .op_type = .sar_op, .a = 0x123456789ABCDEF0, .b = 4 },
    };
    
    try fuzz_bitwise_operations(allocator, &operations);
}

test "fuzz_bitwise_edge_cases" {
    const allocator = std.testing.allocator;
    
    const operations = [_]FuzzBitwiseOperation{
        .{ .op_type = .and_op, .a = 0, .b = std.math.maxInt(u256) },
        .{ .op_type = .or_op, .a = 0, .b = std.math.maxInt(u256) },
        .{ .op_type = .xor_op, .a = std.math.maxInt(u256), .b = std.math.maxInt(u256) },
        .{ .op_type = .not_op, .a = 0 },
        .{ .op_type = .not_op, .a = std.math.maxInt(u256) },
        .{ .op_type = .byte_op, .a = 0x123456789ABCDEF0, .b = 31 },
        .{ .op_type = .byte_op, .a = 0x123456789ABCDEF0, .b = 32 },
        .{ .op_type = .shl_op, .a = 1, .b = 255 },
        .{ .op_type = .shl_op, .a = 1, .b = 256 },
        .{ .op_type = .shr_op, .a = std.math.maxInt(u256), .b = 255 },
        .{ .op_type = .shr_op, .a = std.math.maxInt(u256), .b = 256 },
        .{ .op_type = .sar_op, .a = 1 << 255, .b = 255 },
        .{ .op_type = .sar_op, .a = 1 << 255, .b = 256 },
    };
    
    try fuzz_bitwise_operations(allocator, &operations);
}

test "fuzz_bitwise_random_operations" {
    const allocator = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    
    var operations = std.ArrayList(FuzzBitwiseOperation).init(allocator);
    defer operations.deinit();
    
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const op_type_idx = random.intRangeAtMost(usize, 0, 7);
        const op_types = [_]BitwiseOpType{ .and_op, .or_op, .xor_op, .not_op, .byte_op, .shl_op, .shr_op, .sar_op };
        const op_type = op_types[op_type_idx];
        
        const a = random.int(u256);
        const b = random.int(u256);
        
        try operations.append(.{ .op_type = op_type, .a = a, .b = b });
    }
    
    try fuzz_bitwise_operations(allocator, operations.items);
}

test "fuzz_bitwise_identity_properties" {
    const allocator = std.testing.allocator;
    
    const test_values = [_]u256{
        0,
        1,
        0xFF,
        0xFFFF,
        0xFFFFFFFF,
        0xFFFFFFFFFFFFFFFF,
        std.math.maxInt(u256),
        1 << 128,
        1 << 255,
        0x123456789ABCDEF0,
    };
    
    var operations = std.ArrayList(FuzzBitwiseOperation).init(allocator);
    defer operations.deinit();
    
    for (test_values) |value| {
        // Identity properties
        try operations.append(.{ .op_type = .and_op, .a = value, .b = std.math.maxInt(u256) });
        try operations.append(.{ .op_type = .or_op, .a = value, .b = 0 });
        try operations.append(.{ .op_type = .xor_op, .a = value, .b = 0 });
        try operations.append(.{ .op_type = .xor_op, .a = value, .b = value });
        
        // Complement properties
        try operations.append(.{ .op_type = .and_op, .a = value, .b = 0 });
        try operations.append(.{ .op_type = .or_op, .a = value, .b = std.math.maxInt(u256) });
        try operations.append(.{ .op_type = .xor_op, .a = value, .b = std.math.maxInt(u256) });
    }
    
    try fuzz_bitwise_operations(allocator, operations.items);
}
